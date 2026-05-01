defmodule SymphonyElixir.Config.ProfileBindingAdmin do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.ProfileBindings
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow
  @active_project_status_types MapSet.new(["backlog", "planned", "started"])

  @spec facts() :: map()
  def facts do
    settings_result = Config.settings()
    bindings = ProfileBindings.current()

    %{
      workflow_path: Workflow.workflow_file_path(),
      binding_source: binding_source(),
      settings: settings_result,
      workflow: workflow_facts(settings_result, bindings),
      profiles: profile_facts(settings_result),
      bindings: bindings,
      validation: validation_result(settings_result, bindings)
    }
  end

  @spec discover_projects(module()) :: {:ok, [map()]} | {:error, term()}
  def discover_projects(client_module \\ SymphonyElixir.Linear.Client) do
    bindings = ProfileBindings.current()

    case ProfileBindings.team_fetch_selector(bindings) do
      %{team_id: team_id} when is_binary(team_id) ->
        client_module.fetch_active_projects(%{team_id: team_id})

      %{team_key: team_key} when is_binary(team_key) ->
        client_module.fetch_active_projects(%{team_key: team_key})

      _selector ->
        {:error, :missing_linear_project_discovery_team_selector}
    end
  end

  @spec save_project_bindings([map()]) :: {:ok, map()} | {:error, term()}
  def save_project_bindings(projects) when is_list(projects) do
    with {:ok, settings} <- Config.settings(),
         bindings <- next_bindings(projects),
         :ok <- ProfileBindings.validate(settings, bindings),
         :ok <- write_bindings(ProfileBindings.source_path(), bindings) do
      :ok = ProfileBindings.set(bindings)
      {:ok, bindings}
    end
  end

  @spec project_rows([map()]) :: [map()]
  def project_rows(discovered_projects), do: project_rows(discovered_projects, nil)

  @spec project_rows([map()], [map()] | nil) :: [map()]
  def project_rows(discovered_projects, draft_projects) when is_list(discovered_projects) do
    current_bindings = ProfileBindings.current()
    project_bindings = draft_projects || current_bindings.projects
    bindings = Map.put(current_bindings, :projects, project_bindings)

    bound_by_selector =
      project_bindings
      |> Enum.flat_map(&project_binding_selector_entries/1)
      |> Map.new()

    discovered_rows =
      Enum.map(discovered_projects, &discovered_project_row(&1, bound_by_selector))

    discovered_keys =
      discovered_projects
      |> Enum.flat_map(&discovered_project_keys/1)
      |> MapSet.new()

    bound_only_rows =
      bindings.projects
      |> Enum.reject(&binding_discovered?(&1, discovered_keys))
      |> Enum.map(&bound_only_project_row/1)

    discovered_rows ++ bound_only_rows
  end

  @spec parse_project_params(map()) :: [map()]
  def parse_project_params(project_params) when is_map(project_params) do
    project_params
    |> Map.values()
    |> Enum.flat_map(fn params ->
      if truthy?(Map.get(params, "include")) do
        [
          %{
            selector_kind: normalized_string(Map.get(params, "selector_kind")),
            selector_value: normalized_string(Map.get(params, "selector_value")),
            profile: normalized_string(Map.get(params, "profile")),
            pr_target: pr_target_from_params(params)
          }
        ]
      else
        []
      end
    end)
  end

  def parse_project_params(_params), do: []

  defp discovered_project_row(project, bound_by_selector) do
    selector = project_selector(project)

    binding =
      Map.get(bound_by_selector, project_selector_key(selector)) ||
        binding_by_project_id(project, bound_by_selector) ||
        binding_by_linear_slug_id(project, bound_by_selector)

    slug = project[:slug_id]

    %{
      id: project[:id],
      name: project_name(project, slug),
      slug_id: slug,
      project_url: project[:url],
      status_label: project_status_label(project, binding),
      status_detail: project_status_detail(project),
      status_type: normalized_string(project[:status_type]),
      active?: active_project?(project),
      deleted?: project[:deleted?] == true,
      selector_kind: selector_kind(selector),
      selector_value: selector_value(selector),
      selector_key: project_selector_key(selector),
      bound?: not is_nil(binding),
      profile: (binding && binding.profile) || "default",
      pr_target: (binding && binding.pr_target) || nil
    }
    |> put_pr_target_fields()
  end

  defp bound_only_project_row(binding) do
    slug_or_id = binding.project_slug || binding.project_id

    %{
      id: binding.project_id,
      name: human_project_name(slug_or_id) || "Bound project",
      slug_id: binding.project_slug,
      project_url: nil,
      status_label: "Needs attention",
      status_detail: "Saved locally but not returned by Linear discovery.",
      status_type: "unknown",
      active?: true,
      deleted?: false,
      selector_kind: selector_kind(binding),
      selector_value: selector_value(binding),
      selector_key: project_selector_key(binding),
      bound?: true,
      profile: binding.profile || "default",
      pr_target: binding.pr_target
    }
    |> put_pr_target_fields()
  end

  defp workflow_facts({:ok, settings}, bindings) do
    %{
      tracker_kind: settings.tracker.kind,
      active_states: settings.tracker.active_states,
      terminal_states: settings.tracker.terminal_states,
      team_selector: team_selector_label(bindings)
    }
  end

  defp workflow_facts({:error, reason}, bindings) do
    %{
      tracker_kind: "unavailable",
      active_states: [],
      terminal_states: [],
      team_selector: team_selector_label(bindings),
      error: inspect(reason)
    }
  end

  defp profile_facts({:ok, %Schema{} = settings}) do
    settings.profiles
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn name ->
      pr_target =
        case Schema.resolve_effective_policy(settings, name) do
          {:ok, policy} -> get_in(policy, ["delivery", "pr_target"])
          {:error, reason} -> inspect(reason)
        end

      %{name: name, pr_target: pr_target}
    end)
  end

  defp profile_facts(_settings_result), do: []

  defp validation_result({:ok, settings}, bindings) do
    case ProfileBindings.validate(settings, bindings) do
      :ok -> %{status: :ok, message: "valid"}
      {:error, reason} -> %{status: :error, message: inspect(reason)}
    end
  end

  defp validation_result({:error, reason}, _bindings), do: %{status: :error, message: inspect(reason)}

  defp binding_source do
    path = ProfileBindings.source_path()

    %{
      path: path,
      explicit?: ProfileBindings.source_explicit?(),
      exists?: File.regular?(path)
    }
  end

  defp next_bindings(projects) do
    current = ProfileBindings.current()

    %{
      team_id: current.team_id,
      team_key: current.team_key,
      projects: Enum.map(projects, &project_binding_from_params/1),
      labels: current.labels,
      catch_all: current.catch_all,
      allow_default: current.allow_default
    }
    |> ProfileBindings.normalize()
  end

  defp project_binding_from_params(%{selector_kind: "project_id", selector_value: value} = params) do
    %{project_id: value, profile: params.profile}
    |> maybe_put_pr_target(params.pr_target)
  end

  defp project_binding_from_params(%{selector_kind: "project_slug", selector_value: value} = params) do
    %{project_slug: value, profile: params.profile}
    |> maybe_put_pr_target(params.pr_target)
  end

  defp project_binding_from_params(params) do
    %{project_slug: params[:selector_value], profile: params[:profile]}
    |> maybe_put_pr_target(params[:pr_target])
  end

  defp maybe_put_pr_target(binding, nil), do: binding
  defp maybe_put_pr_target(binding, pr_target), do: Map.put(binding, :pr_target, pr_target)

  defp project_status_label(_project, binding) when not is_nil(binding), do: "Automated"
  defp project_status_label(_project, _binding), do: "Not automated"

  defp project_status_detail(%{status_name: status_name, status_type: status_type}) do
    [status_name, status_type]
    |> Enum.map(&normalized_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> "Linear status unavailable."
      values -> "Linear: #{Enum.join(values, " / ")}"
    end
  end

  defp project_status_detail(_project), do: "Linear status unavailable."

  defp project_name(project, slug) do
    raw_name = normalized_string(project[:name])
    slug_name = human_project_name(slug)

    if project_name_needs_slug?(raw_name, project[:id], slug) do
      slug_name || slug || raw_name || project[:id] || "Linear project"
    else
      raw_name
    end
  end

  defp project_name_needs_slug?(nil, _id, _slug), do: true
  defp project_name_needs_slug?(name, id, slug), do: name in [id, slug] or opaque_project_name?(name)

  defp opaque_project_name?(value) when is_binary(value), do: Regex.match?(~r/^[0-9a-f-]{8,}$/i, value)

  defp active_project?(%{archived?: true}), do: false
  defp active_project?(%{deleted?: true}), do: false

  defp active_project?(%{status_type: status_type}) do
    MapSet.member?(@active_project_status_types, normalized_string(status_type))
  end

  defp active_project?(_project), do: false

  defp put_pr_target_fields(row) do
    generated_target = generated_pr_target(row.selector_kind, row.selector_value)
    {mode, custom_value} = pr_target_mode(row.pr_target, generated_target)

    row
    |> Map.put(:generated_pr_target, generated_target)
    |> Map.put(:pr_target_mode, mode)
    |> Map.put(:pr_target_custom, custom_value)
  end

  defp pr_target_from_params(params) do
    selector_kind = normalized_string(Map.get(params, "selector_kind"))
    selector_value = normalized_string(Map.get(params, "selector_value"))

    case normalized_string(Map.get(params, "pr_target_mode")) do
      "profile" -> nil
      "main" -> "main"
      "generated" -> generated_pr_target(selector_kind, selector_value)
      "custom" -> normalized_string(Map.get(params, "pr_target_custom")) || normalized_string(Map.get(params, "pr_target"))
      _mode -> normalized_string(Map.get(params, "pr_target"))
    end
  end

  defp pr_target_mode(nil, _generated_target), do: {"profile", nil}
  defp pr_target_mode("main", _generated_target), do: {"main", nil}
  defp pr_target_mode(target, target), do: {"generated", nil}
  defp pr_target_mode(target, _generated_target), do: {"custom", target}

  defp generated_pr_target("project_slug", selector_value) when is_binary(selector_value), do: "project/#{selector_value}"
  defp generated_pr_target(_selector_kind, _selector_value), do: nil

  defp human_project_name(nil), do: nil

  defp human_project_name(value) when is_binary(value) do
    value
    |> String.replace(~r/-[0-9a-f]{8,}$/i, "")
    |> String.replace(["-", "_"], " ")
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> String.capitalize(normalized)
    end
  end

  defp write_bindings(path, bindings) when is_binary(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, bindings_yaml(bindings))
    end
  end

  defp bindings_yaml(bindings) do
    [
      yaml_scalar("team_id", bindings.team_id),
      yaml_scalar("team_key", bindings.team_key),
      yaml_project_bindings(bindings.projects),
      yaml_label_bindings(bindings.labels),
      "catch_all:",
      "  enabled: #{yaml_value(bindings.catch_all.enabled)}",
      "  profile: #{yaml_value(bindings.catch_all.profile)}",
      "allow_default: #{yaml_value(bindings.allow_default)}"
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp yaml_project_bindings([]), do: ["projects: []"]

  defp yaml_project_bindings(projects) do
    ["projects:" | Enum.flat_map(projects, &yaml_project_binding/1)]
  end

  defp yaml_project_binding(binding) do
    [
      "  - #{project_selector_yaml(binding)}",
      "    profile: #{yaml_value(binding.profile)}",
      binding.pr_target && "    pr_target: #{yaml_value(binding.pr_target)}"
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp yaml_label_bindings([]), do: ["labels: []"]

  defp yaml_label_bindings(labels) do
    ["labels:" | Enum.flat_map(labels, &yaml_label_binding/1)]
  end

  defp yaml_label_binding(binding) do
    [
      "  - label: #{yaml_value(binding.label)}",
      "    profile: #{yaml_value(binding.profile)}"
    ]
  end

  defp project_selector_yaml(%{project_id: project_id}) when is_binary(project_id), do: "project_id: #{yaml_value(project_id)}"
  defp project_selector_yaml(%{project_slug: project_slug}), do: "project_slug: #{yaml_value(project_slug)}"

  defp yaml_scalar(_key, nil), do: nil
  defp yaml_scalar(key, value), do: "#{key}: #{yaml_value(value)}"

  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"
  defp yaml_value(value) when is_binary(value), do: inspect(value)
  defp yaml_value(value), do: inspect(to_string(value))

  defp project_binding_selector_entries(binding) do
    [{project_selector_key(binding), binding}]
  end

  defp binding_discovered?(binding, discovered_keys) do
    binding
    |> project_binding_selector_entries()
    |> Enum.any?(fn {key, _binding} -> MapSet.member?(discovered_keys, key) end)
  end

  defp discovered_project_keys(project) do
    [
      project_selector_key(project_selector(project)),
      project_selector_key(%{project_id: project[:id]}),
      project_selector_key(%{project_slug: project[:linear_slug_id]})
    ]
    |> Enum.reject(&(&1 == {:missing, nil}))
  end

  defp binding_by_project_id(%{id: id}, bound_by_selector) when is_binary(id) do
    Map.get(bound_by_selector, project_selector_key(%{project_id: id}))
  end

  defp binding_by_project_id(_project, _bound_by_selector), do: nil

  defp binding_by_linear_slug_id(%{linear_slug_id: slug_id}, bound_by_selector) when is_binary(slug_id) do
    Map.get(bound_by_selector, project_selector_key(%{project_slug: slug_id}))
  end

  defp binding_by_linear_slug_id(_project, _bound_by_selector), do: nil

  defp project_selector(%{slug_id: slug_id}) when is_binary(slug_id), do: %{project_slug: slug_id}
  defp project_selector(%{id: id}), do: %{project_id: id}

  defp project_selector_key(%{project_id: project_id}) when is_binary(project_id), do: {:project_id, project_id}
  defp project_selector_key(%{project_slug: project_slug}) when is_binary(project_slug), do: {:project_slug, project_slug}
  defp project_selector_key(_selector), do: {:missing, nil}

  defp selector_kind(%{project_id: project_id}) when is_binary(project_id), do: "project_id"
  defp selector_kind(%{project_slug: project_slug}) when is_binary(project_slug), do: "project_slug"
  defp selector_kind(_binding), do: "project_slug"

  defp selector_value(%{project_id: project_id}) when is_binary(project_id), do: project_id
  defp selector_value(%{project_slug: project_slug}) when is_binary(project_slug), do: project_slug
  defp selector_value(_binding), do: nil

  defp team_selector_label(%{team_id: team_id}) when is_binary(team_id), do: "team_id=#{team_id}"
  defp team_selector_label(%{team_key: team_key}) when is_binary(team_key), do: "team_key=#{team_key}"
  defp team_selector_label(_bindings), do: "missing"

  defp normalized_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_string(_value), do: nil

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]
end
