defmodule SymphonyElixir.TargetRouting do
  @moduledoc """
  Host-owned single-repository routing rules.

  Every admitted issue must resolve to one repository through an explicit
  target binding. Project and issue selections bind directly; broad scopes
  also use the repository policy's issue markers.

  Resolution never guesses. When more than one target matches an issue, or a
  target has no repository identity, the outcome is a blocking, actionable
  reason owned by this module.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunTarget
  alias SymphonyElixir.TargetContext
  alias SymphonyElixir.TargetRegistry.Snapshot
  alias SymphonyElixir.TargetRegistry.Target
  alias SymphonyElixir.Workflow.PublishTarget

  @type entry :: %{
          required(:target_id) => String.t(),
          required(:connection_id) => String.t() | nil,
          required(:scope) => map() | nil,
          required(:scope_type) => String.t() | nil,
          required(:repository) => String.t() | nil,
          required(:repository_key) => String.t() | nil,
          required(:active?) => boolean()
        }

  @tracker_issue_uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @type routing_error ::
          :routing_missing
          | {:routing_owner, entry()}
          | {:routing_ambiguous, [entry()]}
          | {:routing_missing_repository, entry()}

  @spec snapshot_entries(Snapshot.t() | nil) :: [entry()]
  def snapshot_entries(nil), do: []

  def snapshot_entries(%Snapshot{targets: targets}) when is_map(targets) do
    targets
    |> Enum.filter(fn {_id, target} -> is_struct(target, Target) and target.valid? end)
    |> Enum.sort_by(fn {id, _target} -> id end)
    |> Enum.map(fn {id, target} -> snapshot_entry(id, target) end)
  end

  def snapshot_entries(_snapshot), do: []

  @doc """
  Replaces one registry entry with a draft, keeping routing previews honest
  while settings are still a proposal.
  """
  @spec with_draft([entry()], entry()) :: [entry()]
  def with_draft(entries, %{target_id: target_id} = draft) do
    (Enum.reject(entries, &(&1.target_id == target_id)) ++ [draft])
    |> Enum.sort_by(& &1.target_id)
  end

  @spec snapshot_entry(String.t(), Target.t()) :: entry()
  defp snapshot_entry(target_id, %Target{configured: configured} = target)
       when is_binary(target_id) and is_map(configured) do
    target_id
    |> configured_entry(configured, target.configured_state == :active)
    |> Map.put(:markers, RunTarget.repo_markers(get_in(target.repo_manifest || %{}, ["issue_markers"])))
  end

  defp snapshot_entry(_target_id, _target), do: nil

  @doc """
  Builds a routing entry from a raw configured document, for drafts and
  proposals that do not exist as registry targets yet.
  """
  @spec configured_entry(String.t(), map(), boolean()) :: entry()
  def configured_entry(target_id, configured, active?) when is_map(configured) do
    %{
      target_id: target_id,
      connection_id: connection_identity(get_in(configured, ["linear", "connection"])),
      markers: RunTarget.repo_markers(get_in(configured, ["repository_policy", "issue_markers"])),
      scope: scope_map(get_in(configured, ["linear", "scope"])),
      scope_type: nil,
      repository: nil,
      repository_key: nil,
      active?: active?
    }
    |> put_repository(get_in(configured, ["repo", "expected_repository"]), get_in(configured, ["repo", "path"]))
    |> put_scope_type()
  end

  @spec context_entry(TargetContext.t()) :: entry() | nil
  def context_entry(%TargetContext{} = context) do
    scope = scope_map(get_in(context.run_target || %{}, ["scope"]))

    %{
      target_id: context.target_id,
      connection_id: connection_identity(get_in(context.tracker_connection || %{}, ["id"])),
      markers: RunTarget.repo_markers(get_in(context.repo_policy || %{}, ["manifest", "issue_markers"])),
      scope: scope,
      scope_type: nil,
      repository: nil,
      repository_key: nil,
      active?: context.state == :active
    }
    |> put_repository(
      get_in(context.repo_policy || %{}, ["manifest", "project", "repository"]),
      get_in(context.repo_policy || %{}, ["manifest", "project", "repository"])
    )
    |> put_scope_type()
  end

  def context_entry(_context), do: nil

  @doc """
  Resolves an issue against admission-eligible entries on its connection.

  Returns the single matching target, or a blocking reason. Broad scopes also
  require explicit repository issue markers.
  """
  @spec resolve_issue([entry()], Issue.t()) :: {:ok, entry()} | {:error, routing_error()}
  def resolve_issue(entries, %Issue{} = issue) when is_list(entries) do
    case Enum.filter(entries, &issue_matches?(&1, issue)) do
      [entry] ->
        if entry.repository_key,
          do: {:ok, entry},
          else: {:error, {:routing_missing_repository, entry}}

      [] ->
        {:error, :routing_missing}

      matches ->
        {:error, {:routing_ambiguous, Enum.sort_by(matches, & &1.target_id)}}
    end
  end

  @doc """
  Resolves one issue for a specific target, naming every competing target.
  """
  @spec resolve_issue_for([entry()], String.t(), Issue.t()) :: :ok | {:error, routing_error()}
  def resolve_issue_for(entries, target_id, %Issue{} = issue) when is_binary(target_id) do
    case Enum.find(entries, &(&1.target_id == target_id)) do
      # Legacy single-run targets carry no registry scope, so the host has no
      # routing decision to make for them; their own scope rules still apply.
      nil ->
        {:error, :routing_missing}

      %{scope: scope} when not is_map(scope) ->
        :ok

      %{scope: scope} when is_map(scope) and not is_map_key(scope, "type") ->
        :ok

      requesting ->
        entries
        |> Enum.filter(&(&1.connection_id == requesting.connection_id))
        |> resolve_issue_for_scoped(target_id, issue)
    end
  end

  defp resolve_issue_for_scoped(entries, target_id, issue) do
    case resolve_issue(entries, issue) do
      {:ok, %{target_id: ^target_id}} ->
        :ok

      {:ok, entry} ->
        {:error, {:routing_owner, entry}}

      {:error, {:routing_missing_repository, _entry}} = missing ->
        missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec issue_matches?(entry(), Issue.t()) :: boolean()
  def issue_matches?(%{active?: false}, _issue), do: false

  def issue_matches?(entry, issue) do
    markers = Map.get(entry, :markers, RunTarget.RepoMarkers.empty())

    scope_matches?(entry.scope, issue) and
      (entry.scope_type not in ["team", "query"] or
         (not RunTarget.empty_markers?(markers) and RunTarget.marker_match?(issue, markers)))
  end

  defp scope_matches?(%{"type" => "issues", "issue_ids" => ids}, issue) do
    ids = normalized_identifiers(ids)
    Enum.any?([normalize_identifier(issue.identifier), issue.id], &(&1 != nil and &1 in ids))
  end

  defp scope_matches?(%{"type" => "project"} = scope, issue), do: project_matches?(scope, issue)
  defp scope_matches?(%{"type" => "team"} = scope, issue), do: team_matches?(scope, issue)
  defp scope_matches?(%{"type" => "query"}, _issue), do: true
  defp scope_matches?(_scope, _issue), do: false

  @doc """
  Statically decidable overlap: both scopes are guaranteed to match a common
  issue (shared identifier, same project, same team, or two broad scopes).
  """
  @spec scopes_exactly_overlap?(map() | nil, map() | nil) :: boolean()
  def scopes_exactly_overlap?(%{"type" => "issues"} = left, %{"type" => "issues"} = right) do
    MapSet.disjoint?(MapSet.new(normalized_identifiers(left["issue_ids"])), MapSet.new(normalized_identifiers(right["issue_ids"])))
    |> Kernel.not()
  end

  def scopes_exactly_overlap?(%{"type" => "project"} = left, %{"type" => "project"} = right) do
    same_selector?(left["project_id"], right["project_id"], & &1) or
      same_selector?(left["project_slug"], right["project_slug"], &String.downcase/1)
  end

  def scopes_exactly_overlap?(%{"type" => "team"} = left, %{"type" => "team"} = right),
    do: same_selector?(left["team_key"], right["team_key"], &String.downcase/1)

  def scopes_exactly_overlap?(%{"type" => "query"}, %{"type" => "query"}),
    do: true

  def scopes_exactly_overlap?(_left, _right), do: false

  @doc """
  Conservative potential overlap: the scopes could match a common issue but
  static configuration cannot decide (broad versus narrow, project versus
  team, or UUID-versus-identifier issue selections). Exact runtime resolution
  still blocks such admissions.
  """
  @spec scopes_potentially_overlap?(map() | nil, map() | nil) :: boolean()
  def scopes_potentially_overlap?(%{"type" => "issues"} = left, %{"type" => "issues"} = right),
    do: scopes_exactly_overlap?(left, right) or unresolved_issue_aliases?(left, right)

  def scopes_potentially_overlap?(%{"type" => "team"} = left, %{"type" => "team"} = right),
    do: scopes_exactly_overlap?(left, right)

  def scopes_potentially_overlap?(%{"type" => "project"} = left, %{"type" => "project"} = right) do
    cond do
      is_binary(left["project_id"]) and is_binary(right["project_id"]) ->
        left["project_id"] == right["project_id"]

      is_binary(left["project_slug"]) and is_binary(right["project_slug"]) ->
        String.downcase(left["project_slug"]) == String.downcase(right["project_slug"])

      true ->
        true
    end
  end

  def scopes_potentially_overlap?(left, right),
    do: valid_scope?(left) and valid_scope?(right) and not scopes_exactly_overlap?(left, right)

  @doc """
  Per-target routing preview: repository, conflicts, and an actionable reason.
  """
  @spec preview([entry()]) :: [map()]
  def preview(entries) when is_list(entries) do
    entries
    |> Enum.sort_by(& &1.target_id)
    |> Enum.map(fn entry ->
      conflicts =
        entries
        |> Enum.reject(&(&1.target_id == entry.target_id))
        |> Enum.filter(&entries_conflict?(entry, &1))
        |> Enum.sort_by(& &1.target_id)

      {status, reason} =
        cond do
          is_nil(entry.repository_key) ->
            {"missing", "repository_routing_missing"}

          entry.scope_type in ["team", "query"] and
              RunTarget.empty_markers?(Map.get(entry, :markers, RunTarget.RepoMarkers.empty())) ->
            {"missing", "repository_issue_markers_required"}

          conflicts != [] ->
            {"ambiguous", "routing_ambiguous"}

          true ->
            {"routed", nil}
        end

      %{
        target_id: entry.target_id,
        connection_id: entry.connection_id,
        scope: public_scope(entry),
        repository: entry.repository,
        status: status,
        reason: reason,
        conflicts:
          Enum.map(conflicts, fn conflict ->
            %{target_id: conflict.target_id, repository: conflict.repository, scope: public_scope(conflict)}
          end)
      }
    end)
  end

  defp entries_conflict?(left, right) do
    same_connection?(left, right) and
      (scopes_exactly_overlap?(left.scope, right.scope) or
         scopes_potentially_overlap?(left.scope, right.scope))
  end

  defp same_connection?(left, right),
    do: is_binary(left.connection_id) and left.connection_id == right.connection_id

  defp put_repository(entry, expected, path) do
    case repository_key(expected, path) do
      nil ->
        entry

      key ->
        %{entry | repository: repository_display(expected, path), repository_key: key}
    end
  end

  defp repository_key(expected, path) do
    slug = canonical_slug(expected)

    cond do
      slug -> "slug:" <> slug
      is_binary(path) and path != "" and Path.type(path) == :absolute -> "path:" <> Path.expand(path)
      true -> nil
    end
  end

  defp repository_display(expected, path) do
    if is_binary(expected) and expected != "", do: expected, else: path
  end

  defp canonical_slug(value) when is_binary(value) do
    case PublishTarget.github_repository_slug(value) do
      slug when is_binary(slug) -> String.downcase(slug)
      _unparsed -> nil
    end
  end

  defp canonical_slug(_value), do: nil

  defp connection_identity(connection_id) when is_binary(connection_id),
    do: if(String.trim(connection_id) == "", do: nil, else: connection_id)

  defp connection_identity(_connection), do: nil

  defp scope_map(scope) when is_map(scope), do: scope
  defp scope_map(_scope), do: nil

  defp put_scope_type(entry), do: %{entry | scope_type: scope_type(entry.scope)}

  defp scope_type(%{"type" => type}) when is_binary(type), do: String.trim(type)
  defp scope_type(_scope), do: nil

  defp valid_scope?(scope), do: scope_type(scope) in ~w(issues project team query)

  defp public_scope(entry) do
    case entry.scope_type do
      "issues" -> %{"type" => "issues", "issue_ids" => normalized_identifiers(entry.scope["issue_ids"])}
      "project" -> %{"type" => "project"} |> put_selector("project_id", entry.scope) |> put_selector("project_slug", entry.scope)
      "team" -> %{"type" => "team", "team_key" => entry.scope["team_key"]}
      "query" -> %{"type" => "query", "query_file" => entry.scope["query_file"]}
      _missing -> nil
    end
  end

  defp put_selector(scope, key, source) do
    case Map.get(source || %{}, key) do
      value when is_binary(value) -> Map.put(scope, key, value)
      _missing -> scope
    end
  end

  defp project_matches?(scope, issue) do
    expected_id = normalize_selector(scope["project_id"])
    expected_slug = downcase_selector(scope["project_slug"])

    (expected_id != nil and expected_id == normalize_selector(issue.project_id)) or
      (expected_slug != nil and expected_slug == downcase_selector(issue.project_slug))
  end

  defp team_matches?(scope, issue) do
    expected = downcase_selector(scope["team_key"])
    expected != nil and expected == downcase_selector(issue.team_key)
  end

  defp same_selector?(left, right, normalizer) do
    left = normalize_optional(left, normalizer)
    right = normalize_optional(right, normalizer)
    left != nil and left == right
  end

  defp normalize_optional(value, normalizer) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> normalizer.(trimmed)
    end
  end

  defp normalize_optional(_value, _normalizer), do: nil

  defp normalize_selector(value), do: normalize_optional(value, & &1)
  defp downcase_selector(value), do: normalize_optional(value, &String.downcase/1)

  defp normalized_identifiers(values) when is_list(values),
    do: values |> Enum.map(&normalize_identifier/1) |> Enum.reject(&is_nil/1)

  defp normalized_identifiers(_values), do: []

  defp normalize_identifier(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      identifier -> identifier
    end
  end

  defp normalize_identifier(_value), do: nil

  # Runtime matches an issues scope by either the tracker UUID or the human
  # identifier, so string-disjoint selections can still name the same issue
  # when one side selects by UUID and the other by identifier. Only
  # same-shape selections are provably distinct.
  defp unresolved_issue_aliases?(left, right) do
    left_ids = normalized_identifiers(left["issue_ids"])
    right_ids = normalized_identifiers(right["issue_ids"])

    alias_selection_pair?(left_ids, right_ids) or alias_selection_pair?(right_ids, left_ids)
  end

  defp alias_selection_pair?(ids, other_ids) do
    Enum.any?(ids, &tracker_issue_uuid?/1) and Enum.any?(other_ids, &(!tracker_issue_uuid?(&1)))
  end

  defp tracker_issue_uuid?(value) do
    is_binary(value) and Regex.match?(@tracker_issue_uuid, value)
  end
end
