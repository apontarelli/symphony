defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.{ExecutionContext, RunTarget, TargetContext, TrackerCoordinator}

  @callback resolve_candidate_issues(TargetContext.t(), RunTarget.t()) ::
              {:ok, RunTarget.Resolution.t()} | {:error, term()}
  @callback fetch_issues_by_states(TargetContext.t(), [String.t()]) ::
              {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids(TargetContext.t(), [String.t()]) ::
              {:ok, [term()]} | {:error, term()}
  @callback create_comment(TargetContext.t(), String.t(), String.t()) ::
              :ok | {:error, term()}
  @callback update_issue_state(TargetContext.t(), String.t(), String.t()) ::
              :ok | {:error, term()}

  @spec resolve_candidate_issues(TargetContext.t()) ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_candidate_issues(%TargetContext{} = context),
    do: resolve_candidate_issues(context, nil)

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

  @spec resolve_candidate_issues_uncached(TargetContext.t()) ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_candidate_issues_uncached(%TargetContext{} = context),
    do: resolve_candidate_issues_uncached(context, nil)

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

    cond do
      query_file_only?(scope) ->
        {:error, :query_file_not_materialized}

      memory_default_target?(scope, kind) ->
        {:ok, %RunTarget{tracker: kind}}

      true ->
        RunTarget.parse(scope, default_tracker: kind)
    end
  end

  defp context_run_target(%TargetContext{}, %RunTarget{} = target, kind) do
    if normalized_kind(target.tracker) == kind,
      do: {:ok, target},
      else: {:error, :invalid_tracker_adapter}
  end

  defp memory_default_target?(scope, "memory") when is_map(scope) do
    type = scope_value(scope, "type", :type) || scope_value(scope, "kind", :kind)
    normalized_kind(type) in [nil, "nil"]
  end

  defp memory_default_target?(_scope, _kind), do: false

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
    %{
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
  end

  defp context_token_fingerprint(token) when is_binary(token) do
    :crypto.hash(:sha256, "symphony:tracker-token:v1\u0000" <> token)
    |> Base.encode16(case: :lower)
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
end
