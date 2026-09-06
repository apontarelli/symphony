defmodule SymphonyElixir.OperatorLinearChoices do
  @moduledoc "Linear settings choices, scoped to a credential-safe connection revision."

  alias SymphonyElixir.Linear.MetadataCache

  @filters ~w(linear.active_states linear.terminal_states linear.required_labels)
  @scope_fields ~w(project_id project_slug team_key query_file issue_ids)

  @spec build(map() | nil, map(), map(), keyword()) :: map()
  def build(registry, configured, request, opts) do
    selections = request["selections"] || %{}
    selected = fn path -> Map.get(selections, path, get_in(configured, String.split(path, "."))) end
    connection_id = selected.("linear.connection")
    connection = if registry, do: get_in(registry.host, ["tracker_connections", connection_id])

    catalog =
      if is_map(connection) and connection["kind"] == "linear" do
        MetadataCache.get(%{"id" => connection_id, "policy" => connection}, Keyword.get(opts, :metadata_cache, []))
      else
        %{status: "unavailable", reason: "connection_required", connection_revision: nil, data: %{teams: [], projects: [], states: [], labels: []}}
      end

    type = selected.("linear.scope.type")
    scope = Map.new(@scope_fields, &{&1, selected.("linear.scope." <> &1)})
    team_ids = applicable_teams(type, scope, catalog.data)
    changed = connection_changed?(configured, request, catalog.connection_revision, connection_id)
    states = grouped_field(catalog.data.states, team_ids, catalog)
    source_reason = connection_reason(changed, connection_id, catalog)

    fields = %{
      "linear.scope.project_id" => catalog_field("scalar", catalog.data.projects, :id, catalog),
      "linear.scope.project_slug" => catalog_field("scalar", catalog.data.projects, :slug_id, catalog),
      "linear.scope.team_key" => catalog_field("scalar", catalog.data.teams, :key, catalog),
      "linear.scope.query_file" => explicit_field("scalar", scope["query_file"]),
      "linear.scope.issue_ids" => explicit_field("list", scope["issue_ids"]),
      "linear.active_states" => states,
      "linear.terminal_states" => states,
      "linear.required_labels" => grouped_field(catalog.data.labels, team_ids, catalog)
    }

    fields =
      Map.new(fields, fn {path, field} ->
        applicable = applicable?(path, type)
        value = selected.(path)

        reason = selection_reason(path, value, type, scope, source_reason)

        field =
          if reason do
            choices = Enum.map(field.choices, &Map.merge(&1, %{status: "unavailable", reason: reason}))
            Map.merge(field, %{choices: choices, validation_reason: reason, reason: reason})
          else
            field
          end

        {path, Map.put(field, :applicable, applicable)}
      end)

    %{fields: fields, connection_revision: catalog.connection_revision, status: catalog.status, reason: catalog.reason}
  end

  defp connection_reason(true, _connection_id, _catalog), do: "connection_changed"
  defp connection_reason(false, nil, _catalog), do: nil
  defp connection_reason(false, _id, %{status: status}) when status in ["current", "empty"], do: nil
  defp connection_reason(false, _id, catalog), do: catalog.reason || catalog.status

  defp selection_reason(path, value, type, scope, source_reason) do
    if applicable?(path, type) do
      source_reason || scope_reason(path, value, type, scope)
    else
      if value not in [nil, []], do: "scope_type_mismatch"
    end
  end

  defp scope_reason(path, value, type, scope) do
    cond do
      required?(path, type, scope) and value in [nil, [], ""] -> "selection_required"
      multiple_project_selectors?(path, type, scope) -> "multiple_project_selectors"
      true -> nil
    end
  end

  defp multiple_project_selectors?(path, "project", scope)
       when path in ["linear.scope.project_id", "linear.scope.project_slug"],
       do: scope["project_id"] != nil and scope["project_slug"] != nil

  defp multiple_project_selectors?(_path, _type, _scope), do: false

  # A patch must not inherit scope or filters from another connection. This also
  # protects non-settings clients at preview and under the registry write lock.
  @spec complete_connection_change?(map(), map()) :: boolean()
  def complete_connection_change?(current, patch) do
    linear = patch["linear"]

    if is_map(linear) and Map.has_key?(linear, "connection") and
         linear["connection"] != get_in(current, ["linear", "connection"]) do
      Enum.all?(~w(scope active_states terminal_states required_labels), &Map.has_key?(linear, &1)) and
        is_map(linear["scope"]) and Map.has_key?(linear["scope"], "type") and
        complete_scope?(linear["scope"]) and
        Enum.all?(Map.keys(get_in(current, ["linear", "scope"]) || %{}), &Map.has_key?(linear["scope"], &1))
    else
      true
    end
  end

  defp complete_scope?(%{"type" => "project"} = scope),
    do: is_binary(scope["project_id"]) or is_binary(scope["project_slug"])

  defp complete_scope?(%{"type" => "team"} = scope), do: is_binary(scope["team_key"])
  defp complete_scope?(%{"type" => "query"} = scope), do: is_binary(scope["query_file"])
  defp complete_scope?(%{"type" => "issues"} = scope), do: is_list(scope["issue_ids"])
  defp complete_scope?(_scope), do: false

  defp connection_changed?(configured, request, revision, id) do
    previous = request["linear_revision"]
    selections = request["selections"] || %{}
    changed = id != get_in(configured, ["linear", "connection"])
    changed_revision = not is_nil(previous) and previous != revision

    explicit_scope =
      Map.new(["type" | @scope_fields], &{&1, selections["linear.scope." <> &1]})

    incomplete =
      not Enum.all?(["linear.scope.type" | @filters], &Map.has_key?(selections, &1)) or
        not complete_scope?(explicit_scope)

    changed_revision or (changed and (previous != revision or is_nil(revision) or incomplete))
  end

  defp applicable_teams("team", scope, data) do
    data.teams |> Enum.filter(&(&1.key == scope["team_key"])) |> Enum.map(& &1.id)
  end

  defp applicable_teams("project", scope, data) do
    data.projects
    |> Enum.filter(fn project ->
      if scope["project_id"], do: project.id == scope["project_id"], else: project.slug_id == scope["project_slug"]
    end)
    |> Enum.flat_map(& &1.team_ids)
    |> Enum.uniq()
  end

  defp applicable_teams(_type, _scope, data), do: Enum.map(data.teams, & &1.id)

  defp applicable?(path, type) when path in @filters, do: type in ~w(project team query issues)
  defp applicable?("linear.scope.project_id", type), do: type == "project"
  defp applicable?("linear.scope.project_slug", type), do: type == "project"
  defp applicable?("linear.scope.team_key", type), do: type == "team"
  defp applicable?("linear.scope.query_file", type), do: type == "query"
  defp applicable?("linear.scope.issue_ids", type), do: type == "issues"

  defp required?("linear.required_labels", _type, _scope), do: false
  defp required?("linear.scope.project_id", _type, scope), do: is_nil(scope["project_slug"])
  defp required?("linear.scope.project_slug", _type, scope), do: is_nil(scope["project_id"])
  defp required?(_path, _type, _scope), do: true

  defp catalog_field(cardinality, entries, key, catalog) do
    choices =
      Enum.map(entries, fn entry ->
        Map.merge(entry, %{value: Map.fetch!(entry, key), status: choice_status(catalog), reason: catalog.reason})
      end)

    field(cardinality, choices, catalog.status, catalog.reason)
  end

  # Registry filters match names across teams. Keep one selectable name with all
  # matching identities rather than silently choosing one of several equal names.
  defp grouped_field(entries, team_ids, catalog) do
    choices =
      entries
      |> Enum.filter(&(is_nil(&1.team_id) or &1.team_id in team_ids))
      |> Enum.group_by(& &1.name)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {name, members} ->
        %{value: name, name: name, members: Enum.sort_by(members, & &1.id), status: choice_status(catalog), reason: catalog.reason}
      end)

    field("list", choices, catalog.status, catalog.reason)
  end

  defp explicit_field(cardinality, value) do
    valid = Enum.all?(List.wrap(value), &(is_binary(&1) and String.trim(&1) != ""))
    reason = if valid, do: nil, else: "invalid_value"
    choices = Enum.map(List.wrap(value), &%{value: &1, status: if(valid, do: "available", else: "unavailable"), reason: reason})

    field(cardinality, choices, "current", reason)
    |> Map.merge(%{input: "explicit", validation_reason: reason})
  end

  defp choice_status(%{status: status}) when status in ["current", "empty"], do: "available"
  defp choice_status(_catalog), do: "unavailable"

  defp field(cardinality, choices, status, reason),
    do: %{cardinality: cardinality, choices: choices, status: status, reason: reason}
end
