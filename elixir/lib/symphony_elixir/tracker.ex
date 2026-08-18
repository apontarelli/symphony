defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.{Config, ExecutionContext, RunTarget, TargetContext, TrackerCoordinator}

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback resolve_candidate_issues(RunTarget.t() | nil) ::
              {:ok, RunTarget.Resolution.t()} | {:error, term()}
  @callback resolve_candidate_issues(TargetContext.t(), RunTarget.t()) ::
              {:ok, RunTarget.Resolution.t()} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states(TargetContext.t(), [String.t()]) ::
              {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids(TargetContext.t(), [String.t()]) ::
              {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback create_comment(TargetContext.t(), String.t(), String.t()) ::
              :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(TargetContext.t(), String.t(), String.t()) ::
              :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, %RunTarget.Resolution{issues: issues}} <- resolve_candidate_issues() do
      {:ok, issues}
    end
  end

  @spec resolve_candidate_issues() ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_candidate_issues, do: resolve_legacy_candidates(nil)

  @spec resolve_candidate_issues(TargetContext.t() | RunTarget.t() | nil) ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_candidate_issues(%TargetContext{} = context),
    do: resolve_candidate_issues(context, nil)

  def resolve_candidate_issues(%RunTarget{} = target),
    do: resolve_legacy_candidates(target)

  def resolve_candidate_issues(nil), do: resolve_legacy_candidates(nil)

  @spec resolve_candidate_issues(TargetContext.t(), RunTarget.t() | nil) ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_candidate_issues(%TargetContext{} = context, target)
      when is_struct(target, RunTarget) or is_nil(target) do
    with {:ok, routing} <- context_routing(context),
         {:ok, state_path} <- context_coordinator_state_path(context),
         {:ok, adapter, tracker} <- context_adapter(context),
         {:ok, normalized_target} <- context_run_target(context, target, tracker.kind) do
      TrackerCoordinator.resolve_candidate_issues(
        normalized_target,
        fn -> adapter.resolve_candidate_issues(context, normalized_target) end,
        cache_key: context_candidate_cache_key(context, adapter, tracker, normalized_target, routing),
        state_path: state_path
      )
    end
  end

  def resolve_candidate_issues(%TargetContext{}, _target),
    do: {:error, :invalid_tracker_context}

  @spec resolve_candidate_issues_uncached() ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_candidate_issues_uncached, do: adapter().resolve_candidate_issues(nil)

  @spec resolve_candidate_issues_uncached(TargetContext.t() | RunTarget.t() | nil) ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_candidate_issues_uncached(%TargetContext{} = context),
    do: resolve_candidate_issues_uncached(context, nil)

  def resolve_candidate_issues_uncached(%RunTarget{} = target),
    do: adapter().resolve_candidate_issues(target)

  def resolve_candidate_issues_uncached(nil), do: adapter().resolve_candidate_issues(nil)

  @spec resolve_candidate_issues_uncached(TargetContext.t(), RunTarget.t() | nil) ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_candidate_issues_uncached(%TargetContext{} = context, target)
      when is_struct(target, RunTarget) or is_nil(target) do
    with {:ok, _routing} <- context_routing(context),
         {:ok, adapter, tracker} <- context_adapter(context),
         {:ok, normalized_target} <- context_run_target(context, target, tracker.kind) do
      adapter.resolve_candidate_issues(context, normalized_target)
    end
  end

  def resolve_candidate_issues_uncached(%TargetContext{}, _target),
    do: {:error, :invalid_tracker_context}

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issues_by_states(TargetContext.t(), [String.t()]) ::
          {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(%TargetContext{}, []), do: {:ok, []}

  def fetch_issues_by_states(%TargetContext{} = context, states) when is_list(states) do
    with {:ok, adapter, _tracker} <- context_adapter(context) do
      adapter.fetch_issues_by_states(context, states)
    end
  end

  def fetch_issues_by_states(%TargetContext{}, _states),
    do: {:error, :invalid_tracker_context}

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec fetch_issue_states_by_ids(TargetContext.t(), [String.t()]) ::
          {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(%TargetContext{}, []), do: {:ok, []}

  def fetch_issue_states_by_ids(%TargetContext{} = context, issue_ids)
      when is_list(issue_ids) do
    with {:ok, adapter, _tracker} <- context_adapter(context) do
      adapter.fetch_issue_states_by_ids(context, issue_ids)
    end
  end

  def fetch_issue_states_by_ids(%TargetContext{}, _issue_ids),
    do: {:error, :invalid_tracker_context}

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec create_comment(ExecutionContext.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def create_comment(
        %ExecutionContext{target: %TargetContext{} = context},
        issue_id,
        body
      )
      when is_binary(issue_id) and is_binary(body) do
    with {:ok, adapter, _tracker} <- context_adapter(context) do
      adapter.create_comment(context, issue_id, body)
    end
  end

  def create_comment(%ExecutionContext{}, _issue_id, _body),
    do: {:error, :invalid_tracker_context}

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec update_issue_state(ExecutionContext.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def update_issue_state(
        %ExecutionContext{target: %TargetContext{} = context},
        issue_id,
        state_name
      )
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, adapter, _tracker} <- context_adapter(context) do
      adapter.update_issue_state(context, issue_id, state_name)
    end
  end

  def update_issue_state(%ExecutionContext{}, _issue_id, _state_name),
    do: {:error, :invalid_tracker_context}

  defp resolve_legacy_candidates(target) do
    TrackerCoordinator.resolve_candidate_issues(
      target,
      fn -> adapter().resolve_candidate_issues(target) end,
      cache_key: candidate_cache_key(target)
    )
  end

  defp context_adapter(%TargetContext{
         target_id: target_id,
         tracker_connection: %{
           "id" => connection_id,
           "policy" => %{"kind" => kind, "endpoint" => endpoint, "api_key" => api_key}
         },
         run_target: run_target
       })
       when is_binary(kind) do
    tracker = %{
      kind: kind,
      connection_id: connection_id,
      endpoint: endpoint,
      api_key: api_key
    }

    if valid_context_adapter?(target_id, connection_id, run_target) do
      context_adapter_for_kind(tracker)
    else
      {:error, :invalid_tracker_context}
    end
  end

  defp context_adapter(%TargetContext{}), do: {:error, :invalid_tracker_context}

  defp context_coordinator_state_path(%TargetContext{
         worktree_policy: %{"root" => root}
       })
       when is_binary(root) do
    if nonblank_string?(root) do
      {:ok,
       root
       |> Path.expand()
       |> Path.join(".symphony/tracker_coordinator.state")}
    else
      {:error, :invalid_tracker_context}
    end
  end

  defp context_coordinator_state_path(%TargetContext{}),
    do: {:error, :invalid_tracker_context}

  defp valid_context_adapter?(target_id, connection_id, run_target),
    do: nonblank_string?(target_id) and nonblank_string?(connection_id) and is_map(run_target)

  defp context_adapter_for_kind(%{kind: "linear", endpoint: endpoint, api_key: api_key} = tracker) do
    if nonblank_string?(endpoint) and nonblank_string?(api_key),
      do: {:ok, SymphonyElixir.Linear.Adapter, tracker},
      else: {:error, :invalid_tracker_context}
  end

  defp context_adapter_for_kind(%{kind: "memory"} = tracker),
    do: {:ok, SymphonyElixir.Tracker.Memory, tracker}

  defp context_adapter_for_kind(_tracker), do: {:error, :invalid_tracker_adapter}

  defp context_run_target(%TargetContext{run_target: run_target}, nil, kind) do
    scope = Map.get(run_target, "scope", run_target)

    if query_file_only?(scope),
      do: {:error, :query_file_not_materialized},
      else: RunTarget.parse(scope, default_tracker: kind)
  end

  defp context_run_target(%TargetContext{}, %RunTarget{} = target, kind) do
    if normalized_kind(target.tracker) == kind,
      do: {:ok, target},
      else: {:error, :invalid_tracker_adapter}
  end

  defp query_file_only?(scope) when is_map(scope) do
    type = scope_value(scope, "type", :type) || scope_value(scope, "kind", :kind)
    query = scope_value(scope, "query", :query)
    filter = scope_value(scope, "filter", :filter)
    query_file = scope_value(scope, "query_file", :query_file)

    normalized_kind(type) == "query" and not is_map(query) and not is_map(filter) and
      nonblank_string?(query_file)
  end

  defp query_file_only?(_scope), do: false

  defp scope_value(scope, string_key, atom_key),
    do: Map.get(scope, string_key) || Map.get(scope, atom_key)

  defp context_routing(%TargetContext{run_target: run_target}) when is_map(run_target) do
    with {:ok, active_states} <-
           context_string_list(Map.get(run_target, "active_states", [])),
         {:ok, required_labels} <-
           context_string_list(Map.get(run_target, "required_labels", [])),
         {:ok, assignee} <- context_optional_string(Map.get(run_target, "assignee")) do
      {:ok,
       %{
         active_states: active_states,
         required_labels: required_labels |> Enum.map(&String.downcase/1) |> Enum.uniq(),
         assignee: assignee
       }}
    end
  end

  defp context_routing(%TargetContext{}), do: {:error, :invalid_tracker_context}

  defp context_string_list(values) when is_list(values) do
    if List.improper?(values) do
      {:error, :invalid_tracker_context}
    else
      normalized = Enum.map(values, &normalized_optional_string/1)

      if Enum.all?(normalized, &is_binary/1),
        do: {:ok, Enum.uniq(normalized)},
        else: {:error, :invalid_tracker_context}
    end
  end

  defp context_string_list(_values), do: {:error, :invalid_tracker_context}

  defp context_optional_string(nil), do: {:ok, nil}

  defp context_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_tracker_context}
      normalized -> {:ok, normalized}
    end
  end

  defp context_optional_string(_value), do: {:error, :invalid_tracker_context}

  defp context_candidate_cache_key(context, adapter, tracker, target, routing) do
    key = %{
      version: 1,
      target_id: context.target_id,
      adapter: adapter,
      kind: tracker.kind,
      connection_id: tracker.connection_id,
      endpoint: tracker.endpoint,
      token_fingerprint: context_token_fingerprint(tracker.api_key),
      target: target,
      active_states: routing.active_states,
      required_labels: routing.required_labels,
      assignee: routing.assignee
    }

    if tracker.kind == "memory",
      do: Map.put(key, :memory_tracker, memory_tracker_cache_scope(tracker.kind)),
      else: key
  end

  defp context_token_fingerprint(token) when is_binary(token) do
    secret_fingerprint("symphony:tracker-token:v1\u0000" <> token)
  end

  defp context_token_fingerprint(_token), do: nil

  defp normalized_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_optional_string(_value), do: nil

  defp normalized_kind(value) do
    case normalized_optional_string(value) do
      nil -> nil
      kind -> String.downcase(kind)
    end
  end

  defp nonblank_string?(value), do: not is_nil(normalized_optional_string(value))

  defp candidate_cache_key(target) do
    settings = Config.settings!()
    tracker = settings.tracker

    %{
      adapter: adapter(),
      target: configured_cache_target(target, settings),
      tracker:
        Map.take(tracker, [
          :kind,
          :endpoint,
          :project_id,
          :project_slug,
          :team_key,
          :issue_ids,
          :active_states,
          :required_labels,
          :assignee,
          :workspace_slug
        ]),
      api_key_hash: secret_fingerprint(Map.get(tracker, :api_key)),
      repo_markers: RunTarget.repo_markers(settings),
      memory_tracker: memory_tracker_cache_scope(tracker.kind)
    }
  end

  defp configured_cache_target(%RunTarget{} = target, _settings), do: target

  defp configured_cache_target(nil, settings) do
    case RunTarget.from_settings(settings) do
      {:ok, %RunTarget{} = target} -> target
      {:error, reason} -> {:unresolved, reason}
    end
  end

  defp memory_tracker_cache_scope("memory") do
    %{
      issues: Application.get_env(:symphony_elixir, :memory_tracker_issues, []),
      errors: Application.get_env(:symphony_elixir, :memory_tracker_errors, %{})
    }
  end

  defp memory_tracker_cache_scope(_kind), do: nil

  defp secret_fingerprint(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
  end

  defp secret_fingerprint(_secret), do: nil

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
