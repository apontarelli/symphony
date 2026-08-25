defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to agent runtime workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    Config,
    ExecutionContext,
    HandoffRoute,
    HandoffRouteRecorder,
    PublishHandoff,
    PublishPreflight,
    QualityGate,
    ReviewRecords,
    RunSetup,
    RunTarget,
    StatusDashboard,
    TargetContext,
    Tracker,
    TrackerCoordinator,
    Workspace
  }

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TargetContext.Legacy
  alias SymphonyElixir.Workflow.PublishTarget

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @typep dispatch_block_reason :: :blocked_by_non_terminal | :unsupported_requirement_issue
  @empty_runtime_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    @type t :: %__MODULE__{}

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :max_concurrent_startups,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :run_mode,
      :issue_batch_limit,
      dispatched_issue_count: 0,
      running: %{},
      completed: MapSet.new(),
      handoff_routes: %{},
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      runtime_totals: nil,
      runtime_rate_limits: nil,
      tracker_rate_limit: nil,
      coordinator_owner_id: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    validate_startup? = Keyword.get(opts, :validate_startup, true)

    case startup_validation(validate_startup?) do
      :ok ->
        now_ms = System.monotonic_time(:millisecond)
        config = Config.settings!()
        capacity = RunSetup.capacity(config)

        state = %State{
          poll_interval_ms: config.polling.interval_ms,
          max_concurrent_agents: capacity.max_concurrent_agents,
          max_concurrent_startups: capacity.max_concurrent_startups,
          next_poll_due_at_ms: now_ms,
          poll_check_in_progress: false,
          tick_timer_ref: nil,
          tick_token: nil,
          run_mode: RunSetup.mode(),
          issue_batch_limit: RunSetup.issue_batch_limit(),
          runtime_totals: @empty_runtime_totals,
          runtime_rate_limits: nil,
          tracker_rate_limit: nil,
          coordinator_owner_id:
            Keyword.get(opts, :coordinator_owner_id) ||
              default_coordinator_owner_id(Keyword.get(opts, :name, __MODULE__))
        }

        if validate_startup?, do: run_terminal_workspace_cleanup()
        state = schedule_tick(state, 0)

        {:ok, state}

      {:error, reason} ->
        Logger.error("Startup config validation failed: #{inspect(reason)}")
        {:stop, {:invalid_startup_config, reason}}
    end
  end

  defp startup_validation(true), do: Config.validate!()
  defp startup_validation(false), do: :ok

  defp default_coordinator_owner_id(name) do
    "#{node()}:#{inspect(name)}:#{System.unique_integer([:positive])}"
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = %{state | poll_check_in_progress: false}
    state = maybe_schedule_next_poll(state)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      run_id ->
        {running_entry, state} = pop_running_entry(state, run_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state = handle_agent_down(reason, state, run_id, running_entry, session_id)

        Logger.info("Agent task finished #{run_log_context(run_id, running_entry)} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, run_id, runtime_info}, %{running: running} = state)
      when is_map(runtime_info) do
    case Map.get(running, run_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, run_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:workflow_module_resolution, run_id, workflow_module_resolution},
        %{running: running} = state
      )
      when is_map(workflow_module_resolution) do
    case Map.get(running, run_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          Map.put(running_entry, :workflow_module_resolution, workflow_module_resolution)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, run_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:runtime_event, run_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, run_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_runtime_event(running_entry, update)

        state =
          state
          |> apply_runtime_token_delta(token_delta)
          |> apply_runtime_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, run_id, updated_running_entry)}}
    end
  end

  def handle_info({:runtime_event, _run_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, run_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, run_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, run_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _run_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_agent_down(:normal, state, run_id, running_entry, session_id) do
    if agent_blocker?(running_entry) do
      block_agent_down(state, run_id, running_entry, session_id, :normal)
    else
      Logger.info("Agent task completed #{run_log_context(run_id, running_entry)} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> complete_issue(run_id, running_entry)
      |> schedule_issue_retry(
        run_id,
        1,
        retry_metadata_from_running(running_entry, %{
          identifier: running_entry.identifier,
          issue_url: issue_url_from_running(running_entry),
          delay_type: :continuation,
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        })
      )
    end
  end

  defp handle_agent_down(reason, state, run_id, running_entry, session_id) do
    if agent_blocker?(running_entry) do
      block_agent_down(state, run_id, running_entry, session_id, reason)
    else
      retry_agent_down(state, run_id, running_entry, session_id, reason)
    end
  end

  defp block_agent_down(state, run_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked #{run_log_context(run_id, running_entry)} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, run_id, running_entry, error)
  end

  defp retry_agent_down(state, run_id, running_entry, session_id, reason) do
    Logger.warning("Agent task exited #{run_log_context(run_id, running_entry)} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    schedule_issue_retry(
      state,
      run_id,
      next_attempt,
      retry_metadata_from_running(running_entry, %{
        identifier: running_entry.identifier,
        issue_url: issue_url_from_running(running_entry),
        error: "agent exited: #{inspect(reason)}",
        session_id: running_entry_session_id(running_entry),
        last_error_signature: Map.get(running_entry, :last_runtime_error_signature),
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    )
  end

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> sync_shared_tracker_rate_limit()
      |> refresh_coordinator_leases()
      |> reconcile_stalled_running_issues()
      |> maybe_reconcile_tracker_state()

    with false <- tracker_backoff_active?(state),
         :ok <- Config.validate!(),
         true <- dispatch_budget_available?(state),
         {:ok, resolution} <- Tracker.resolve_candidate_issues(),
         true <- available_slots(state) > 0 do
      resolution
      |> log_target_resolution_warnings()
      |> then(&choose_issues(&1, clear_tracker_rate_limit(state)))
    else
      {:error, reason} ->
        handle_tracker_fetch_error(state, reason, :candidate_fetch, fn ->
          Logger.error(dispatch_error_message(reason))
        end)

      false ->
        state

      true ->
        state
    end
  end

  defp maybe_reconcile_tracker_state(%State{} = state) do
    if tracker_backoff_active?(state) do
      state
    else
      state
      |> clear_tracker_rate_limit()
      |> reconcile_running_issues()
      |> maybe_reconcile_blocked_issues()
    end
  end

  defp maybe_reconcile_blocked_issues(%State{} = state) do
    if tracker_backoff_active?(state), do: state, else: reconcile_blocked_issues(state)
  end

  defp dispatch_error_message(reason) do
    cond do
      Config.config_error?(reason) ->
        Config.format_error(reason)

      tracker_rate_limited_error?(reason) ->
        "Tracker rate limited: #{inspect(reason)}"

      true ->
        "Failed to fetch from Linear: #{inspect(reason)}"
    end
  end

  defp handle_tracker_fetch_error(%State{} = state, reason, source, fallback_log_fun)
       when is_atom(source) and is_function(fallback_log_fun, 0) do
    if tracker_rate_limited_error?(reason) do
      record_tracker_rate_limit(state, reason, source)
    else
      fallback_log_fun.()
      state
    end
  end

  defp tracker_rate_limited_error?({:linear_rate_limited, _details}), do: true
  defp tracker_rate_limited_error?(_reason), do: false

  defp record_tracker_rate_limit(%State{} = state, {:linear_rate_limited, details}, source)
       when is_map(details) do
    now_ms = System.monotonic_time(:millisecond)
    tracker_rate_limit = shared_recorded_tracker_rate_limit(details, source)

    delay_ms =
      positive_integer(tracker_rate_limit[:remaining_ms]) ||
        positive_integer(tracker_rate_limit[:retry_after_ms]) ||
        tracker_backoff_delay_ms(details)

    limited_until_ms = now_ms + delay_ms

    limited_until =
      DateTime.utc_now() |> DateTime.add(delay_ms, :millisecond) |> DateTime.truncate(:second)

    tracker_rate_limit =
      tracker_rate_limit
      |> Map.take([:status, :retry_after_ms, :reset_at, :errors, :error])
      |> Map.merge(%{
        reason: :tracker_rate_limited,
        source: source,
        limited_until_ms: limited_until_ms,
        limited_until: DateTime.to_iso8601(limited_until),
        retry_after_ms: delay_ms
      })

    Logger.warning("Tracker rate limited source=#{source} retry_after_ms=#{delay_ms} limited_until=#{tracker_rate_limit.limited_until}; skipping tracker reads until backoff elapses")

    %{state | tracker_rate_limit: tracker_rate_limit}
  end

  defp record_tracker_rate_limit(%State{} = state, reason, source) do
    record_tracker_rate_limit(state, {:linear_rate_limited, %{error: inspect(reason)}}, source)
  end

  defp shared_recorded_tracker_rate_limit(details, source) do
    case TrackerCoordinator.record_rate_limit(details, source) do
      rate_limit when is_map(rate_limit) ->
        rate_limit

      {:error, reason} ->
        Logger.warning("Tracker coordinator rate-limit write failed source=#{source}: #{inspect(reason)}")
        Map.take(details, [:status, :retry_after_ms, :reset_at, :errors, :error])
    end
  end

  defp tracker_backoff_delay_ms(details) when is_map(details) do
    positive_integer(Map.get(details, :retry_after_ms)) || reset_delay_ms(details) ||
      Config.settings!().polling.interval_ms
  end

  defp reset_delay_ms(%{reset_at: reset_at}) when is_binary(reset_at) do
    case DateTime.from_iso8601(reset_at) do
      {:ok, reset_at, _offset} ->
        max(0, DateTime.diff(reset_at, DateTime.utc_now(), :millisecond))

      _ ->
        nil
    end
  end

  defp reset_delay_ms(_details), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp tracker_backoff_active?(%State{tracker_rate_limit: %{limited_until_ms: limited_until_ms}})
       when is_integer(limited_until_ms) do
    limited_until_ms > System.monotonic_time(:millisecond)
  end

  defp tracker_backoff_active?(_state), do: false

  defp clear_tracker_rate_limit(%State{} = state) do
    if tracker_backoff_active?(state), do: state, else: %{state | tracker_rate_limit: nil}
  end

  defp sync_shared_tracker_rate_limit(%State{} = state) do
    case TrackerCoordinator.rate_limit() do
      nil ->
        clear_tracker_rate_limit(state)

      {:error, reason} ->
        Logger.warning("Tracker coordinator rate-limit read failed: #{inspect(reason)}")
        state

      rate_limit when is_map(rate_limit) ->
        %{state | tracker_rate_limit: local_tracker_rate_limit(rate_limit)}
    end
  end

  defp local_tracker_rate_limit(rate_limit) when is_map(rate_limit) do
    remaining_ms =
      positive_integer(rate_limit[:remaining_ms]) || positive_integer(rate_limit[:retry_after_ms]) ||
        Config.settings!().polling.interval_ms

    rate_limit
    |> Map.drop([:remaining_ms, :limited_until_ms])
    |> Map.put(:limited_until_ms, System.monotonic_time(:millisecond) + remaining_ms)
    |> Map.put(:retry_after_ms, remaining_ms)
  end

  defp refresh_coordinator_leases(%State{} = state) do
    owner_id = coordinator_owner_id(state)

    state
    |> coordinator_lease_entries()
    |> Enum.each(fn {run_id, issue, context} ->
      refresh_coordinator_lease(run_id, owner_id, issue, context)
    end)

    state
  end

  defp coordinator_lease_entries(%State{} = state) do
    running_entries =
      Enum.map(state.running, fn {run_id, running_entry} ->
        {run_id, Map.get(running_entry, :issue), Map.get(running_entry, :execution_context)}
      end)

    blocked_entries =
      Enum.map(state.blocked, fn {run_id, blocked_entry} ->
        {run_id, Map.get(blocked_entry, :issue), Map.get(blocked_entry, :execution_context)}
      end)

    retry_entries =
      Enum.map(state.retry_attempts, fn {run_id, entry} ->
        {run_id, nil, Map.get(entry, :execution_context)}
      end)

    claimed_entries = Enum.map(state.claimed, fn run_id -> {run_id, nil, nil} end)

    (running_entries ++ blocked_entries ++ retry_entries ++ claimed_entries)
    |> Enum.reduce(%{}, fn {run_id, issue, context}, acc ->
      Map.update(acc, run_id, {issue, context}, fn
        {nil, nil} -> {issue, context}
        existing -> existing
      end)
    end)
    |> Enum.map(fn {run_id, {issue, context}} -> {run_id, issue, context} end)
  end

  defp refresh_coordinator_lease(
         run_id,
         owner_id,
         issue,
         %ExecutionContext{} = context
       ) do
    case TrackerCoordinator.refresh_issue_lease(context.target, context.issue_id, owner_id, []) do
      :ok ->
        :ok

      {:error, :missing} ->
        reclaim_missing_coordinator_lease(run_id, owner_id, issue, context)

      {:error, :leased} ->
        Logger.warning("Tracker coordinator lease owned by another daemon while issue is locally active: #{execution_context_log(context)}")
        :ok

      {:error, reason} ->
        Logger.warning("Tracker coordinator lease refresh failed #{execution_context_log(context)}: #{inspect(reason)}")
        :ok
    end
  end

  defp refresh_coordinator_lease(issue_id, owner_id, issue, _context)
       when is_binary(issue_id) do
    case TrackerCoordinator.refresh_issue_lease(issue_id, owner_id) do
      :ok ->
        :ok

      {:error, :missing} ->
        reclaim_missing_coordinator_lease(issue_id, owner_id, issue, nil)

      {:error, :leased} ->
        Logger.warning("Tracker coordinator lease owned by another daemon while issue is locally active: issue_id=#{issue_id}")
        :ok

      {:error, reason} ->
        Logger.warning("Tracker coordinator lease refresh failed issue_id=#{issue_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp refresh_coordinator_lease(_run_id, _owner_id, _issue, _context), do: :ok

  defp reclaim_missing_coordinator_lease(
         _run_id,
         owner_id,
         %Issue{} = issue,
         %ExecutionContext{} = context
       ) do
    case TrackerCoordinator.claim_issue(context.target, issue, owner_id, []) do
      :ok ->
        :ok

      {:error, :leased} ->
        Logger.warning("Tracker coordinator lease was reclaimed by another daemon while issue is locally active: #{execution_context_log(context)}")
        :ok

      {:error, reason} ->
        Logger.warning("Tracker coordinator missing lease reclaim failed for #{execution_context_log(context)}: #{inspect(reason)}")
        :ok
    end
  end

  defp reclaim_missing_coordinator_lease(_run_id, owner_id, %Issue{} = issue, _context) do
    case TrackerCoordinator.claim_issue(issue, owner_id) do
      :ok ->
        :ok

      {:error, :leased} ->
        Logger.warning("Tracker coordinator lease was reclaimed by another daemon while issue is locally active: #{issue_context(issue)}")
        :ok

      {:error, reason} ->
        Logger.warning("Tracker coordinator missing lease reclaim failed for #{issue_context(issue)}: #{inspect(reason)}")
        :ok
    end
  end

  defp reclaim_missing_coordinator_lease(_run_id, _owner_id, _issue, _context), do: :ok

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)

    reconcile_entry_groups(state, state.running, :running)
  end

  defp reconcile_blocked_issues(%State{} = state) do
    reconcile_entry_groups(state, state.blocked, :blocked)
  end

  defp reconcile_entry_groups(%State{} = state, entries, _kind) when map_size(entries) == 0,
    do: state

  defp reconcile_entry_groups(%State{} = state, entries, kind) do
    entries
    |> Enum.group_by(fn {_run_id, entry} -> context_group_key(entry) end)
    |> Enum.reduce(state, fn {_group_key, grouped_entries}, state_acc ->
      reconcile_entry_group(state_acc, grouped_entries, kind)
    end)
  end

  defp reconcile_entry_group(state, grouped_entries, kind) do
    context =
      Enum.find_value(grouped_entries, fn {_run_id, entry} ->
        Map.get(entry, :execution_context)
      end)

    run_ids_by_issue =
      Map.new(grouped_entries, fn {run_id, _entry} ->
        {issue_id_from_run_id(run_id), run_id}
      end)

    issue_ids = Map.keys(run_ids_by_issue)

    case fetch_issue_states(context, issue_ids) do
      {:ok, issues} ->
        state
        |> clear_tracker_rate_limit()
        |> reconcile_visible_entry_group(issues, run_ids_by_issue, context, kind)
        |> reconcile_missing_entry_group(issues, run_ids_by_issue, context, kind)

      {:error, reason} ->
        source = if kind == :running, do: :running_refresh, else: :blocked_refresh

        handle_tracker_fetch_error(state, reason, source, fn ->
          Logger.debug("Failed to refresh #{kind} issue states: #{inspect(reason)}; keeping local state")
        end)
    end
  end

  defp fetch_issue_states(%ExecutionContext{target: target}, issue_ids),
    do: Tracker.fetch_issue_states_by_ids(target, issue_ids)

  defp fetch_issue_states(_context, issue_ids),
    do: Tracker.fetch_issue_states_by_ids(issue_ids)

  defp reconcile_visible_entry_group(state, issues, run_ids_by_issue, context, kind) do
    active_states = active_state_set(context)
    terminal_states = terminal_state_set(context)

    Enum.reduce(issues, state, fn
      %Issue{id: issue_id} = issue, state_acc ->
        case Map.get(run_ids_by_issue, issue_id) do
          nil ->
            state_acc

          run_id when kind == :running ->
            reconcile_issue_state_for_run(
              issue,
              run_id,
              state_acc,
              active_states,
              terminal_states
            )

          run_id ->
            reconcile_blocked_issue_state_for_run(
              issue,
              run_id,
              state_acc,
              active_states,
              terminal_states
            )
        end

      _invalid, state_acc ->
        state_acc
    end)
  end

  defp reconcile_missing_entry_group(state, issues, run_ids_by_issue, context, kind) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(run_ids_by_issue, state, fn {issue_id, run_id}, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        reconcile_missing_run(kind, state_acc, run_id, context)
      end
    end)
  end

  defp reconcile_missing_run(:running, state, run_id, _context) do
    log_missing_running_issue(state, run_id)
    terminate_running_issue(state, run_id, false)
  end

  defp reconcile_missing_run(:blocked, state, run_id, context) do
    Logger.info("Blocked issue no longer visible during state refresh: #{retry_log_context(run_id, context, nil)}; releasing block")
    release_issue_claim(state, run_id, context)
  end

  defp context_group_key(%{execution_context: %ExecutionContext{} = context}) do
    {
      context.target.target_id,
      context.target.registry_generation,
      context.target.policy_hash
    }
  end

  defp context_group_key(_entry), do: :legacy

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(
          Issue.t(),
          term(),
          String.t(),
          non_neg_integer(),
          map()
        ) ::
          term()
  def handle_retry_issue_lookup_for_test(
        %Issue{} = issue,
        %State{} = state,
        issue_id,
        attempt,
        metadata
      )
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    {:noreply, updated_state} =
      handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)

    updated_state
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec dispatch_block_reason_for_test(Issue.t()) :: dispatch_block_reason() | nil
  def dispatch_block_reason_for_test(%Issue{} = issue) do
    issue_dispatch_block_reason(issue, terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()}
          | {:skip, Issue.t(), dispatch_block_reason() | nil}
          | {:skip, :missing}
          | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec record_tracker_rate_limit_for_test(State.t(), term(), atom()) :: State.t()
  def record_tracker_rate_limit_for_test(%State{} = state, reason, source) when is_atom(source) do
    record_tracker_rate_limit(state, reason, source)
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec order_candidate_issues_for_test(RunTarget.Resolution.t()) :: [Issue.t()]
  def order_candidate_issues_for_test(%RunTarget.Resolution{} = resolution) do
    order_candidate_issues(resolution)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) ::
          String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec schedule_issue_retry_for_test(State.t(), ExecutionContext.t(), pos_integer(), map()) ::
          State.t()
  def schedule_issue_retry_for_test(
        %State{} = state,
        %ExecutionContext{} = context,
        attempt,
        metadata
      )
      when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    schedule_issue_retry(
      state,
      ExecutionContext.run_id(context),
      attempt,
      Map.put(metadata, :execution_context, context)
    )
  end

  @doc false
  @spec terminate_running_issue_for_test(State.t(), ExecutionContext.run_id()) :: State.t()
  def terminate_running_issue_for_test(%State{} = state, run_id) do
    terminate_running_issue(state, run_id, false)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    case find_run_id_for_issue(state.running, issue.id) do
      nil ->
        state

      run_id ->
        reconcile_issue_state_for_run(issue, run_id, state, active_states, terminal_states)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_issue_state_for_run(
         %Issue{} = issue,
         run_id,
         state,
         active_states,
         terminal_states
       ) do
    context =
      state.running
      |> Map.get(run_id, %{})
      |> Map.get(:execution_context)

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{run_log_context(run_id, state.running[run_id])} state=#{issue.state}; stopping active agent")
        terminate_running_issue(state, run_id, true)

      !issue_routable?(issue, context) ->
        Logger.info("Issue no longer routed to this worker: #{run_log_context(run_id, state.running[run_id])} assignee=#{inspect(issue.assignee_id)}; stopping active agent")
        terminate_running_issue(state, run_id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, run_id, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{run_log_context(run_id, state.running[run_id])} state=#{issue.state}; stopping active agent")
        terminate_running_issue(state, run_id, false)
    end
  end

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    case find_run_id_for_issue(state.blocked, issue.id) do
      nil ->
        state

      run_id ->
        reconcile_blocked_issue_state_for_run(
          issue,
          run_id,
          state,
          active_states,
          terminal_states
        )
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states),
    do: state

  defp reconcile_blocked_issue_state_for_run(
         %Issue{} = issue,
         run_id,
         state,
         active_states,
         terminal_states
       ) do
    blocked_entry = Map.get(state.blocked, run_id, %{})
    context = Map.get(blocked_entry, :execution_context)

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{retry_log_context(run_id, context, issue.identifier)} state=#{issue.state}; releasing block")
        cleanup_issue_workspace(context, issue.identifier, Map.get(blocked_entry, :worker_host))
        release_issue_claim(state, run_id, context)

      !issue_routable?(issue, context) ->
        Logger.info("Blocked issue no longer routed to this worker: #{retry_log_context(run_id, context, issue.identifier)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, run_id, context)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, run_id, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{retry_log_context(run_id, context, issue.identifier)} state=#{issue.state}; releasing block")
        release_issue_claim(state, run_id, context)
    end
  end

  defp find_run_id_for_issue(entries, issue_id) when is_map(entries) and is_binary(issue_id) do
    Enum.find_value(entries, fn {run_id, entry} ->
      if issue_id_from_entry(run_id, entry) == issue_id, do: run_id
    end)
  end

  defp find_run_id_for_issue(_entries, _issue_id), do: nil

  defp issue_id_from_entry(_run_id, %{execution_context: %ExecutionContext{issue_id: issue_id}}),
    do: issue_id

  defp issue_id_from_entry(_run_id, %{issue: %Issue{id: issue_id}}), do: issue_id
  defp issue_id_from_entry(run_id, _entry), do: issue_id_from_run_id(run_id)

  defp log_missing_running_issue(%State{} = state, run_id) do
    Logger.info("Issue no longer visible during running-state refresh: #{run_log_context(run_id, Map.get(state.running, run_id))}; stopping active agent")
  end

  defp refresh_running_issue_state(%State{} = state, run_id, %Issue{} = issue) do
    case Map.get(state.running, run_id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, run_id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, run_id, %Issue{} = issue) do
    case Map.get(state.blocked, run_id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, run_id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, run_id, cleanup_workspace) do
    case Map.get(state.running, run_id) do
      nil ->
        release_issue_claim(state, run_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        context = Map.get(running_entry, :execution_context)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(context, identifier, worker_host)
        end

        stop_running_task(pid, ref)

        %{
          state
          | running: Map.delete(state.running, run_id),
            claimed: MapSet.delete(state.claimed, run_id),
            blocked: Map.delete(state.blocked, run_id),
            retry_attempts: Map.delete(state.retry_attempts, run_id)
        }

      _ ->
        release_issue_claim(state, run_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{running: running} = state)
       when map_size(running) == 0,
       do: state

  defp reconcile_stalled_running_issues(%State{} = state) do
    now = DateTime.utc_now()

    Enum.reduce(state.running, state, fn running, state_acc ->
      reconcile_stalled_running_entry(running, state_acc, now)
    end)
  end

  defp reconcile_stalled_running_entry(
         {run_id, %{stall_timeout_ms: timeout_ms} = running_entry},
         state,
         now
       )
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: maybe_restart_stalled_issue(state, run_id, running_entry, now, timeout_ms)

  defp reconcile_stalled_running_entry(_running, state, _now), do: state

  defp maybe_restart_stalled_issue(state, run_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, run_id) do
      state
    else
      restart_stalled_issue(state, run_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, run_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id_from_run_id(run_id))
      session_id = running_entry_session_id(running_entry)

      if agent_blocker?(running_entry) do
        error =
          blocker_error(
            running_entry,
            "stalled for #{elapsed_ms}ms after the runtime reported a blocker"
          )

        Logger.warning("Issue blocked: #{run_log_context(run_id, running_entry)} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(run_id, running_entry, error)
      else
        Logger.warning("Issue stalled: #{run_log_context(run_id, running_entry)} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

        next_attempt = next_retry_attempt_from_running(running_entry)

        state
        |> terminate_running_issue(run_id, false)
        |> schedule_issue_retry(
          run_id,
          next_attempt,
          retry_metadata_from_running(running_entry, %{
            identifier: identifier,
            issue_url: issue_url_from_running(running_entry),
            error: "stalled for #{elapsed_ms}ms without runtime progress",
            session_id: running_entry_session_id(running_entry),
            last_error_signature: Map.get(running_entry, :last_runtime_error_signature)
          })
        )
      end
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_runtime_progress_timestamp) ||
      Map.get(running_entry, :last_runtime_timestamp) ||
      Map.get(running_entry, :started_at)
  end

  defp agent_blocker?(running_entry) when is_map(running_entry) do
    input_required_blocker?(running_entry) or
      Map.get(running_entry, :last_runtime_event) in [
        :blocked,
        :agent_max_turns_exhausted,
        :max_turns_exhausted
      ] or
      blocked_completion?(Map.get(running_entry, :completion))
  end

  defp agent_blocker?(_running_entry), do: false

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_runtime_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      runtime_message_method(Map.get(running_entry, :last_runtime_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp blocked_completion?(completion) when is_map(completion) do
    not is_nil(blocked_completion_outcome(completion)) or
      not is_nil(completion_blocker_metadata(completion))
  end

  defp blocked_completion?(_completion), do: false

  defp blocked_completion_outcome(completion) when is_map(completion) do
    completion
    |> completion_field(:outcome)
    |> normalize_blocked_completion_outcome()
  end

  defp blocked_completion_outcome(_completion), do: nil

  defp normalize_blocked_completion_outcome(outcome)
       when outcome in [:blocked, :agent_blocked, :human_input_required, :max_turns_exhausted],
       do: outcome

  defp normalize_blocked_completion_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "blocked" -> :blocked
      "agent_blocked" -> :agent_blocked
      "human_input_required" -> :human_input_required
      "max_turns_exhausted" -> :max_turns_exhausted
      _ -> nil
    end
  end

  defp normalize_blocked_completion_outcome(_outcome), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    completion_blocker_error(Map.get(running_entry, :completion)) ||
      runtime_event_blocker_error(Map.get(running_entry, :last_runtime_event)) ||
      runtime_message_blocker_error(Map.get(running_entry, :last_runtime_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp runtime_event_blocker_error(:turn_input_required),
    do: "runtime turn requires operator input"

  defp runtime_event_blocker_error(:approval_required), do: "runtime turn requires approval"

  defp runtime_event_blocker_error(:blocked), do: "runtime turn is blocked"

  defp runtime_event_blocker_error(event)
       when event in [:agent_max_turns_exhausted, :max_turns_exhausted],
       do: "agent.max_turns reached while issue remains active"

  defp runtime_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case completion_blocker_metadata(completion) do
      %{reason: reason} ->
        reason

      _ ->
        completion_outcome_blocker_error(completion) ||
          input_required_completion_blocker_error(completion)
    end
  end

  defp completion_outcome_blocker_error(completion) do
    case blocked_completion_outcome(completion) do
      :max_turns_exhausted -> "agent.max_turns reached while issue remains active"
      outcome when not is_nil(outcome) -> "agent reported an unfixable blocker"
      nil -> nil
    end
  end

  defp input_required_completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] ->
        "runtime turn requires operator input"

      :approval_required ->
        "runtime turn requires approval"

      nil ->
        nil
    end
  end

  defp blocker_metadata(running_entry, fallback) when is_map(running_entry) do
    case completion_blocker_metadata(Map.get(running_entry, :completion)) do
      %{reason: reason} = blocker when is_binary(reason) and reason != "" ->
        blocker

      %{required_action: _} = blocker ->
        Map.put(blocker, :reason, fallback)

      _ ->
        %{reason: fallback}
    end
  end

  defp blocker_metadata(_running_entry, fallback), do: %{reason: fallback}

  defp completion_blocker_metadata(completion) when is_map(completion) do
    completion
    |> map_field([:blocker, "blocker"])
    |> normalize_completion_blocker()
  end

  defp completion_blocker_metadata(_completion), do: nil

  defp normalize_completion_blocker(%{} = blocker) do
    reason =
      blocker
      |> map_field([:reason, "reason", :message, "message", :summary, "summary"])
      |> non_empty_string()

    required_action =
      blocker
      |> map_field([:required_action, "required_action", :requiredAction, "requiredAction"])
      |> non_empty_string()

    case {reason, required_action} do
      {nil, nil} -> nil
      {reason, nil} -> %{reason: reason}
      {nil, required_action} -> %{required_action: required_action}
      {reason, required_action} -> %{reason: reason, required_action: required_action}
    end
  end

  defp normalize_completion_blocker(blocker) when is_binary(blocker) do
    case non_empty_string(blocker) do
      nil -> nil
      reason -> %{reason: reason}
    end
  end

  defp normalize_completion_blocker(_blocker), do: nil

  defp map_field(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp non_empty_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp non_empty_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> non_empty_string()

  defp non_empty_string(value) when is_number(value),
    do: value |> to_string() |> non_empty_string()

  defp non_empty_string(_value), do: nil

  defp runtime_message_blocker_error(message) do
    if runtime_message_method(message) == "mcpServer/elicitation/request" do
      "runtime MCP elicitation requires operator input"
    end
  end

  defp runtime_message_method(%{message: %{"method" => method}}) when is_binary(method),
    do: method

  defp runtime_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp runtime_message_method(%{"method" => method}) when is_binary(method), do: method
  defp runtime_message_method(%{method: method}) when is_binary(method), do: method
  defp runtime_message_method(_message), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp stop_running_task(pid, ref) do
    if is_pid(pid) do
      terminate_task(pid)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, run_id, running_entry, error) do
    stop_running_task(Map.get(running_entry, :pid), Map.get(running_entry, :ref))
    block_issue_from_entry(state, run_id, running_entry, error)
  end

  defp block_issue_from_entry(%State{} = state, run_id, running_entry, error) do
    handoff_route =
      handoff_decision_for_running_entry(running_entry, blocker_metadata(running_entry, error))

    maybe_persist_handoff_route(running_entry, handoff_route)

    blocked_entry =
      running_entry
      |> policy_tracking_fields_from_running()
      |> Map.merge(%{
        issue_id: issue_id_from_run_id(run_id),
        identifier: Map.get(running_entry, :identifier, issue_id_from_run_id(run_id)),
        issue: Map.get(running_entry, :issue),
        execution_context: Map.get(running_entry, :execution_context),
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        session_id: running_entry_session_id(running_entry),
        error: error,
        blocked_at: DateTime.utc_now(),
        last_runtime_message: Map.get(running_entry, :last_runtime_message),
        last_runtime_event: Map.get(running_entry, :last_runtime_event),
        last_runtime_timestamp: Map.get(running_entry, :last_runtime_timestamp)
      })

    %{
      state
      | running: Map.delete(state.running, run_id),
        retry_attempts: Map.delete(state.retry_attempts, run_id),
        claimed: MapSet.put(state.claimed, run_id),
        blocked: Map.put(state.blocked, run_id, blocked_entry),
        handoff_routes:
          Map.put(
            state.handoff_routes,
            run_id,
            HandoffRoute.to_map(handoff_route)
          )
    }
  end

  defp choose_issues(%RunTarget.Resolution{} = resolution, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    resolution
    |> order_candidate_issues()
    |> Enum.reduce_while(state, fn issue, state_acc ->
      maybe_choose_issue(issue, state_acc, active_states, terminal_states)
    end)
  end

  defp maybe_choose_issue(issue, state, active_states, terminal_states) do
    if should_dispatch_issue?(issue, state, active_states, terminal_states) do
      state
      |> dispatch_issue(issue)
      |> continue_or_halt_dispatch()
    else
      {:cont, state}
    end
  end

  defp continue_or_halt_dispatch(state) do
    if tracker_backoff_active?(state) or not dispatch_budget_available?(state) do
      {:halt, state}
    else
      {:cont, state}
    end
  end

  defp order_candidate_issues(%RunTarget.Resolution{ordering: :target, issues: issues})
       when is_list(issues), do: issues

  defp order_candidate_issues(%RunTarget.Resolution{issues: issues}) when is_list(issues),
    do: sort_issues_for_dispatch(issues)

  defp log_target_resolution_warnings(%RunTarget.Resolution{warnings: warnings} = resolution)
       when is_list(warnings) do
    Enum.each(warnings, fn warning ->
      Logger.warning(
        "Run target warning code=#{inspect(Map.get(warning, :code))} issue_id=#{inspect(Map.get(warning, :issue_id))} issue_identifier=#{inspect(Map.get(warning, :issue_identifier))} message=#{inspect(Map.get(warning, :message))}"
      )
    end)

    resolution
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      is_nil(issue_dispatch_block_reason(issue, terminal_states)) and
      issue_not_tracked?(issue, state) and
      issue_policy_allows_dispatch?(issue) and
      dispatch_capacity_available?(issue, state, running)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp dispatch_capacity_available?(issue, state, running) do
    available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp issue_not_tracked?(%Issue{id: issue_id}, %State{} = state) do
    Enum.all?(
      [state.running, state.blocked, state.retry_attempts],
      fn entries -> is_map(entries) and is_nil(find_run_id_for_issue(entries, issue_id)) end
    ) and
      Enum.all?(state.claimed, &(issue_id_from_run_id(&1) != issue_id))
  end

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp issue_routable?(
         %Issue{} = issue,
         %ExecutionContext{target: %TargetContext{run_target: run_target}}
       )
       when is_map(run_target) do
    required_labels =
      case Map.get(run_target, "required_labels") do
        labels when is_list(labels) -> labels
        _missing -> []
      end

    Issue.routable?(issue, required_labels)
  end

  defp issue_routable?(%Issue{} = issue, _context), do: issue_routable?(issue)

  defp issue_dispatch_block_reason(%Issue{} = issue, terminal_states) do
    cond do
      Issue.requirement?(issue) ->
        :unsupported_requirement_issue

      todo_issue_blocked_by_non_terminal?(issue, terminal_states) ->
        :blocked_by_non_terminal

      true ->
        nil
    end
  end

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set(%ExecutionContext{target: target}),
    do: target_state_set(target, "terminal_states", terminal_state_set())

  defp terminal_state_set(_context), do: terminal_state_set()

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set(%ExecutionContext{target: target}),
    do: target_state_set(target, "active_states", active_state_set())

  defp active_state_set(_context), do: active_state_set()

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp target_state_set(%TargetContext{run_target: run_target}, key, fallback)
       when is_map(run_target) do
    case Map.get(run_target, key) do
      states when is_list(states) ->
        states
        |> Enum.map(&normalize_issue_state/1)
        |> Enum.filter(&(&1 != ""))
        |> MapSet.new()

      _missing ->
        fallback
    end
  end

  defp target_state_set(_target, _key, fallback), do: fallback

  defp dispatch_issue(
         %State{} = state,
         issue,
         attempt \\ nil,
         preferred_worker_host \\ nil,
         pinned_context \\ nil
       ) do
    case execution_context_for_dispatch(
           state,
           issue,
           preferred_worker_host,
           pinned_context
         ) do
      {:ok, context} ->
        owner_id = coordinator_owner_id(state)

        case TrackerCoordinator.claim_issue(context.target, issue, owner_id, []) do
          :ok ->
            dispatch_claimed_issue(state, issue, attempt, context, owner_id)

          {:error, :leased} ->
            Logger.debug("Skipping dispatch; issue already leased by another local daemon: #{execution_context_log(context)}")
            state

          {:error, reason} ->
            Logger.warning("Skipping dispatch; tracker coordinator claim failed for #{execution_context_log(context)}: #{inspect(reason)}")
            state
        end

      :no_worker_capacity ->
        Logger.debug("No worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      {:error, reason} ->
        Logger.error("Skipping dispatch; execution context admission failed for #{issue_context(issue)} reason=#{inspect(reason)}")
        state
    end
  end

  defp execution_context_for_dispatch(
         %State{},
         %Issue{id: issue_id, identifier: identifier},
         _preferred_worker_host,
         %ExecutionContext{issue_id: issue_id, issue_identifier: identifier} = context
       ) do
    case ExecutionContext.validate(context) do
      :ok -> {:ok, context}
      {:error, _reason} -> {:error, :invalid_execution_context}
    end
  end

  defp execution_context_for_dispatch(
         %State{} = state,
         %Issue{} = issue,
         preferred_worker_host,
         nil
       ) do
    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        :no_worker_capacity

      worker_host ->
        with {:ok, target} <- Legacy.build_at_process_start([]),
             {:ok, policy} <- policy_for_dispatch(target, issue) do
          ExecutionContext.new(target, issue, policy: policy, worker_host: worker_host)
        end
    end
  end

  defp execution_context_for_dispatch(_state, _issue, _preferred_worker_host, _context),
    do: {:error, :invalid_execution_context}

  defp policy_for_dispatch(%TargetContext{} = target, %Issue{} = issue) do
    profile = get_in(target.issue_policy_authority, ["profile"]) || "default"

    case TargetContext.issue_policy(target, issue, profile: profile) do
      {:ok, policy} ->
        {:ok, policy}

      {:error, reason}
      when reason in [:forbidden_policy_broadening, :malformed_issue_metadata] ->
        Config.issue_policy(issue)

      {:error, _reason} = error ->
        error
    end
  end

  defp dispatch_claimed_issue(
         %State{} = state,
         issue,
         attempt,
         %ExecutionContext{} = context,
         owner_id
       ) do
    case revalidate_issue_for_dispatch(
           issue,
           fn issue_ids -> Tracker.fetch_issue_states_by_ids(context.target, issue_ids) end,
           terminal_state_set(context),
           context
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        state
        |> spawn_issue_in_context(refreshed_issue, attempt, context)
        |> release_untracked_lease(context, owner_id)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{execution_context_log(context)}")
        release_coordinator_lease(context, owner_id)
        state

      {:skip, %Issue{} = refreshed_issue, reason} ->
        Logger.info(
          "Skipping stale dispatch after issue refresh: #{execution_context_log(context)} reason=#{inspect(reason)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}"
        )

        release_coordinator_lease(context, owner_id)
        state

      {:error, reason} ->
        release_coordinator_lease(context, owner_id)

        handle_tracker_fetch_error(state, reason, :dispatch_revalidation, fn ->
          Logger.warning("Skipping dispatch; issue refresh failed for #{execution_context_log(context)}: #{inspect(reason)}")
        end)
    end
  end

  defp release_untracked_lease(%State{} = state, %ExecutionContext{} = context, owner_id) do
    run_id = ExecutionContext.run_id(context)

    if MapSet.member?(state.claimed, run_id) or Map.has_key?(state.running, run_id) or
         Map.has_key?(state.blocked, run_id) or Map.has_key?(state.retry_attempts, run_id) do
      state
    else
      release_coordinator_lease(context, owner_id)
      state
    end
  end

  defp release_coordinator_lease(%ExecutionContext{} = context, owner_id) do
    case TrackerCoordinator.release_issue(context.target, context.issue_id, owner_id, []) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Tracker coordinator lease release failed #{execution_context_log(context)}: #{inspect(reason)}")
        :ok
    end
  end

  defp release_coordinator_lease(issue_id, owner_id) when is_binary(issue_id) do
    case TrackerCoordinator.release_issue(issue_id, owner_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Tracker coordinator lease release failed issue_id=#{issue_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp release_coordinator_lease(_context_or_issue_id, _owner_id), do: :ok

  defp coordinator_owner_id(%State{coordinator_owner_id: owner_id})
       when is_binary(owner_id) and owner_id != "",
       do: owner_id

  defp coordinator_owner_id(_state), do: default_coordinator_owner_id(__MODULE__)

  defp spawn_issue_in_context(
         %State{} = state,
         issue,
         attempt,
         %ExecutionContext{} = context
       ) do
    recipient = self()
    run_id = ExecutionContext.run_id(context)

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run_context(context, issue, recipient, attempt: attempt)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{execution_context_log(context)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{context.worker_host || "local"}")

        running_entry =
          %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            execution_context: context,
            worker_host: context.worker_host,
            workspace_path: context.workspace_path,
            stall_timeout_ms: context.runner_config["stall_timeout_ms"],
            runtime: nil,
            session_id: nil,
            last_runtime_message: nil,
            last_runtime_timestamp: nil,
            last_runtime_progress_timestamp: nil,
            last_runtime_event: nil,
            last_runtime_error_signature: nil,
            startup_slot?: true,
            codex_app_server_pid: nil,
            codex_command: nil,
            codex_home: nil,
            codex_workspace: nil,
            codex_execution_profile: nil,
            codex_execution_profile_model: nil,
            codex_execution_profile_reasoning_effort: nil,
            codex_execution_profile_budget: nil,
            codex_execution_profile_timeout_ms: nil,
            workflow_file_path: nil,
            workflow_config_sha256: nil,
            runtime_input_tokens: 0,
            runtime_output_tokens: 0,
            runtime_total_tokens: 0,
            runtime_last_reported_input_tokens: 0,
            runtime_last_reported_output_tokens: 0,
            runtime_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            workflow_module_resolution: nil,
            started_at: DateTime.utc_now()
          }
          |> Map.merge(policy_tracking_fields(context.policy))

        running = Map.put(state.running, run_id, running_entry)

        %{
          state
          | running: running,
            dispatched_issue_count: increment_dispatched_issue_count(state, attempt),
            claimed: MapSet.put(state.claimed, run_id),
            handoff_routes: Map.delete(state.handoff_routes, run_id),
            retry_attempts: Map.delete(state.retry_attempts, run_id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{execution_context_log(context)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(
          state,
          run_id,
          next_attempt,
          %{
            execution_context: context,
            identifier: issue.identifier,
            issue_url: issue.url,
            error: "failed to spawn agent: #{inspect(reason)}",
            worker_host: context.worker_host
          }
        )
    end
  end

  defp revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_states),
    do: revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_states, nil)

  defp revalidate_issue_for_dispatch(
         %Issue{id: issue_id},
         issue_fetcher,
         terminal_states,
         context
       )
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states, context) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue, issue_dispatch_block_reason(refreshed_issue, terminal_states)}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states, _context),
    do: {:ok, issue}

  defp complete_issue(%State{} = state, run_id, running_entry) do
    running_entry =
      running_entry
      |> run_quality_gate()
      |> run_publish_steps_if_allowed()

    handoff_route = handoff_decision_for_running_entry(running_entry, nil)

    maybe_persist_quality_gate_review_record(running_entry, handoff_route)

    if HandoffRouteRecorder.completion_metadata?(Map.get(running_entry, :completion)) do
      maybe_persist_handoff_route(running_entry, handoff_route)
    end

    %{
      state
      | completed: MapSet.put(state.completed, run_id),
        handoff_routes:
          Map.put(
            state.handoff_routes,
            run_id,
            HandoffRoute.to_map(handoff_route)
          ),
        retry_attempts: Map.delete(state.retry_attempts, run_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, run_id, attempt, metadata)
       when is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, run_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(run_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    session_id = pick_retry_session_id(previous_retry, metadata)
    last_error_signature = pick_retry_last_error_signature(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    context = metadata[:execution_context] || Map.get(previous_retry, :execution_context)
    policy_fields = context_policy_tracking_fields(context)
    profile = pick_retry_profile(previous_retry, metadata, policy_fields)
    target = pick_retry_target(previous_retry, metadata, policy_fields)
    policy_ref = pick_retry_policy_ref(previous_retry, metadata, policy_fields)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, run_id, retry_token}, delay_ms)
    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying #{retry_log_context(run_id, context, identifier)} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    retry_entry =
      %{
        attempt: next_attempt,
        timer_ref: timer_ref,
        retry_token: retry_token,
        due_at_ms: due_at_ms,
        identifier: identifier,
        issue_url: issue_url,
        error: error,
        session_id: session_id,
        last_error_signature: last_error_signature,
        worker_host: worker_host,
        workspace_path: workspace_path,
        execution_context: context,
        profile: profile,
        target: target,
        policy_ref: policy_ref
      }

    %{state | retry_attempts: Map.put(state.retry_attempts, run_id, retry_entry)}
  end

  defp pop_retry_attempt_state(%State{} = state, run_id, retry_token)
       when is_reference(retry_token) do
    case Map.get(state.retry_attempts, run_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          session_id: Map.get(retry_entry, :session_id),
          last_error_signature: Map.get(retry_entry, :last_error_signature),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          execution_context: Map.get(retry_entry, :execution_context),
          profile: Map.get(retry_entry, :profile),
          target: Map.get(retry_entry, :target),
          policy_ref: Map.get(retry_entry, :policy_ref)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, run_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, run_id, attempt, metadata) do
    state = sync_shared_tracker_rate_limit(state)

    if tracker_backoff_active?(state) do
      retry_tracker_backoff_issue(state, run_id, attempt, metadata)
    else
      fetch_and_handle_retry_issue(state, run_id, attempt, metadata)
    end
  end

  defp fetch_and_handle_retry_issue(state, run_id, attempt, metadata) do
    context = metadata[:execution_context]

    case resolve_retry_candidates(context) do
      {:ok, %RunTarget.Resolution{issues: issues}} ->
        state = clear_tracker_rate_limit(state)
        issue_id = issue_id_from_run_id(run_id)

        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, run_id, attempt, metadata)

      {:error, reason} ->
        updated_state =
          handle_tracker_fetch_error(state, reason, :retry_poll, fn ->
            Logger.warning("Retry poll failed for #{retry_log_context(run_id, context, metadata[:identifier])}: #{inspect(reason)}")
          end)

        {:noreply,
         schedule_issue_retry(
           updated_state,
           run_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp resolve_retry_candidates(%ExecutionContext{target: target}),
    do: Tracker.resolve_candidate_issues_uncached(target)

  defp resolve_retry_candidates(_context), do: Tracker.resolve_candidate_issues_uncached()

  defp retry_tracker_backoff_issue(%State{} = state, run_id, attempt, metadata) do
    remaining_ms =
      tracker_rate_limit_remaining_ms(
        state.tracker_rate_limit,
        System.monotonic_time(:millisecond)
      )

    Logger.warning("Retry poll skipped for #{retry_log_context(run_id, metadata[:execution_context], metadata[:identifier])}; tracker_rate_limited retry_after_ms=#{remaining_ms}")

    {:noreply,
     schedule_issue_retry(
       state,
       run_id,
       attempt,
       metadata
       |> Map.merge(%{error: "tracker rate limited", retry_delay_ms: max(remaining_ms || 0, 1)})
       |> Map.delete(:delay_type)
     )}
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, run_id, attempt, metadata) do
    context = metadata[:execution_context]
    terminal_states = terminal_state_set(context)

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: #{retry_log_context(run_id, context, issue.identifier)} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(context, issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, run_id, context)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, run_id, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim #{retry_log_context(run_id, context, issue.identifier)}")
        {:noreply, release_issue_claim(state, run_id, context)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, run_id, _attempt, metadata) do
    Logger.debug("Issue no longer visible, removing claim #{retry_log_context(run_id, metadata[:execution_context], metadata[:identifier])}")
    {:noreply, release_issue_claim(state, run_id, metadata[:execution_context])}
  end

  defp cleanup_issue_workspace(%ExecutionContext{} = context, _identifier, _worker_host),
    do: Workspace.remove(context)

  defp cleanup_issue_workspace(_context, identifier, worker_host) when is_binary(identifier),
    do: Workspace.remove_issue_workspaces(identifier, worker_host)

  defp cleanup_issue_workspace(_context, _identifier, _worker_host), do: :ok

  defp cleanup_issue_workspace(identifier, worker_host \\ nil),
    do: cleanup_issue_workspace(nil, identifier, worker_host)

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, run_id, issue, attempt, metadata) do
    context = metadata[:execution_context]

    if retry_candidate_issue?(issue, terminal_state_set(context), context) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host], context)}
    else
      Logger.debug("No available slots for retrying #{retry_log_context(run_id, context, issue.identifier)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         run_id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           issue_url: issue.url,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, run_id, context \\ nil) do
    case context do
      %ExecutionContext{} -> release_coordinator_lease(context, coordinator_owner_id(state))
      _legacy -> release_coordinator_lease(run_id, coordinator_owner_id(state))
    end

    %{
      state
      | claimed: MapSet.delete(state.claimed, run_id),
        blocked: Map.delete(state.blocked, run_id),
        retry_attempts: Map.delete(state.retry_attempts, run_id)
    }
  end

  defp retry_delay(attempt, metadata)
       when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    cond do
      is_integer(metadata[:retry_delay_ms]) and metadata[:retry_delay_ms] > 0 ->
        metadata[:retry_delay_ms]

      metadata[:delay_type] == :continuation and attempt == 1 ->
        @continuation_retry_delay_ms

      true ->
        failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)

    min(
      @failure_retry_base_ms * (1 <<< max_delay_power),
      Config.settings!().agent.max_retry_backoff_ms
    )
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(run_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id_from_run_id(run_id)
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_session_id(previous_retry, metadata) do
    metadata[:session_id] || Map.get(previous_retry, :session_id)
  end

  defp pick_retry_last_error_signature(previous_retry, metadata) do
    metadata[:last_error_signature] || Map.get(previous_retry, :last_error_signature)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_profile(previous_retry, metadata, policy_fields) do
    metadata[:profile] || Map.get(previous_retry, :profile) || policy_fields[:profile]
  end

  defp pick_retry_target(previous_retry, metadata, policy_fields) do
    metadata[:target] || Map.get(previous_retry, :target) || policy_fields[:target]
  end

  defp pick_retry_policy_ref(previous_retry, metadata, policy_fields) do
    metadata[:policy_ref] || Map.get(previous_retry, :policy_ref) || policy_fields[:policy_ref]
  end

  defp retry_metadata_from_running(running_entry, metadata)
       when is_map(running_entry) and is_map(metadata) do
    metadata
    |> Map.put(:execution_context, Map.get(running_entry, :execution_context))
    |> Map.merge(policy_tracking_fields_from_running(running_entry))
  end

  defp retry_metadata_from_running(_running_entry, metadata) when is_map(metadata), do: metadata

  defp issue_url_from_running(%{issue: %Issue{url: url}}), do: url
  defp issue_url_from_running(_running_entry), do: nil

  defp policy_tracking_fields_from_running(running_entry) when is_map(running_entry) do
    running_entry
    |> Map.take([:profile, :target, :policy_ref])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp policy_tracking_fields(policy) when is_map(policy) do
    %{
      profile: get_in(policy, ["policy_metadata", "profile"]),
      target: get_in(policy, ["delivery", "pr_target"]),
      policy_ref: Map.get(policy, "policy_ref")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp policy_tracking_fields(_policy), do: %{}

  defp context_policy_tracking_fields(%ExecutionContext{policy: policy}),
    do: policy_tracking_fields(policy)

  defp context_policy_tracking_fields(_context), do: %{}

  defp run_quality_gate(
         %{
           execution_context: %ExecutionContext{} = context,
           issue: %Issue{} = issue,
           completion: completion
         } = running_entry
       )
       when is_map(completion) do
    if quality_gate_needed?(context, completion) do
      quality_gate =
        QualityGate.run_context(
          context,
          issue,
          completion,
          maybe_put_quality_gate_runner([])
        )

      put_completion_result(running_entry, :quality_gate, quality_gate)
    else
      running_entry
    end
  end

  defp run_quality_gate(%{completion: completion} = running_entry) when is_map(completion) do
    if quality_gate_needed?(completion) do
      quality_gate =
        QualityGate.run(
          Map.get(running_entry, :workspace_path),
          Map.get(running_entry, :policy, %{}),
          Map.get(running_entry, :issue),
          completion,
          quality_gate_opts(Map.get(running_entry, :worker_host))
        )

      Map.update(running_entry, :completion, %{quality_gate: quality_gate}, fn
        completion when is_map(completion) -> Map.put(completion, :quality_gate, quality_gate)
        _completion -> %{quality_gate: quality_gate}
      end)
    else
      running_entry
    end
  end

  defp run_quality_gate(running_entry), do: running_entry

  defp quality_gate_needed?(%ExecutionContext{} = context, completion)
       when is_map(completion) do
    get_in(context.target.repo_policy, ["manifest", "quality_gate", "enabled"]) == true and
      HandoffRouteRecorder.completion_metadata?(completion)
  end

  defp quality_gate_needed?(completion) when is_map(completion) do
    Config.settings!().quality_gate.enabled and
      HandoffRouteRecorder.completion_metadata?(completion)
  end

  defp quality_gate_opts(worker_host) do
    []
    |> maybe_put_quality_gate_runner()
    |> maybe_put_worker_host(worker_host)
  end

  defp maybe_put_quality_gate_runner(opts) do
    case Application.get_env(:symphony_elixir, :quality_gate_runner) do
      nil -> opts
      runner -> Keyword.put(opts, :runner, runner)
    end
  end

  defp maybe_put_worker_host(opts, worker_host) when is_binary(worker_host) and worker_host != "",
    do: Keyword.put(opts, :worker_host, worker_host)

  defp maybe_put_worker_host(opts, _worker_host), do: opts

  defp run_publish_preflight(%{execution_context: %ExecutionContext{} = context} = running_entry) do
    if publish_handoff_policy?(context.policy) and
         HandoffRouteRecorder.completion_metadata?(Map.get(running_entry, :completion)) do
      put_completion_result(
        running_entry,
        :publish_preflight,
        PublishPreflight.run_context(context)
      )
    else
      running_entry
    end
  end

  defp run_publish_preflight(%{policy: policy} = running_entry) when is_map(policy) do
    if publish_handoff_policy?(policy) and
         HandoffRouteRecorder.completion_metadata?(Map.get(running_entry, :completion)) do
      preflight =
        running_entry
        |> Map.get(:workspace_path)
        |> PublishPreflight.run(policy, worker_host: Map.get(running_entry, :worker_host))

      Map.update(running_entry, :completion, %{publish_preflight: preflight}, fn
        completion when is_map(completion) -> Map.put(completion, :publish_preflight, preflight)
        _completion -> %{publish_preflight: preflight}
      end)
    else
      running_entry
    end
  end

  defp run_publish_preflight(running_entry), do: running_entry

  defp run_publish_handoff(
         %{
           execution_context: %ExecutionContext{} = context,
           issue: %Issue{} = issue,
           completion: completion
         } = running_entry
       )
       when is_map(completion) do
    if publish_handoff_policy?(context.policy) and publish_handoff_needed?(completion) do
      context
      |> PublishHandoff.run_context(issue, completion)
      |> maybe_store_publish_handoff(running_entry)
    else
      running_entry
    end
  end

  defp run_publish_handoff(%{policy: policy, completion: completion} = running_entry)
       when is_map(policy) and is_map(completion) do
    if publish_handoff_policy?(policy) and publish_handoff_needed?(completion) do
      running_entry
      |> run_publish_handoff(policy, completion)
      |> maybe_store_publish_handoff(running_entry)
    else
      running_entry
    end
  end

  defp run_publish_handoff(running_entry), do: running_entry

  defp run_publish_steps_if_allowed(running_entry) do
    if quality_gate_allows_publish?(Map.get(running_entry, :completion)) do
      running_entry
      |> run_publish_preflight()
      |> run_publish_handoff()
    else
      running_entry
    end
  end

  defp quality_gate_allows_publish?(completion) when is_map(completion) do
    case completion |> completion_field(:quality_gate) |> QualityGate.normalize_result() do
      nil -> true
      %{status: :passed} -> true
      _quality_gate -> false
    end
  end

  defp quality_gate_allows_publish?(_completion), do: true

  defp publish_handoff_policy?(policy) when is_map(policy),
    do: not is_nil(PublishTarget.resolve_policy(policy))

  defp publish_handoff_needed?(completion) do
    HandoffRouteRecorder.completion_metadata?(completion) and
      is_nil(completion_field(completion, :publish_handoff))
  end

  defp run_publish_handoff(running_entry, policy, completion) do
    PublishHandoff.run(
      Map.get(running_entry, :workspace_path),
      policy,
      Map.get(running_entry, :issue),
      completion,
      worker_host: Map.get(running_entry, :worker_host)
    )
  end

  defp maybe_store_publish_handoff(%{status: :passed} = publish_handoff, running_entry) do
    put_publish_handoff(running_entry, publish_handoff)
  end

  defp maybe_store_publish_handoff(%{attempted: true} = publish_handoff, running_entry) do
    put_publish_handoff(running_entry, publish_handoff)
  end

  defp maybe_store_publish_handoff(_publish_handoff, running_entry), do: running_entry

  defp put_completion_result(running_entry, key, result) do
    Map.update(running_entry, :completion, %{key => result}, fn
      completion when is_map(completion) -> Map.put(completion, key, result)
      _completion -> %{key => result}
    end)
  end

  defp put_publish_handoff(running_entry, publish_handoff) do
    Map.update(running_entry, :completion, %{publish_handoff: publish_handoff}, fn
      completion when is_map(completion) ->
        Map.put(completion, :publish_handoff, publish_handoff)

      _completion ->
        %{publish_handoff: publish_handoff}
    end)
  end

  defp completion_field(completion, key) when is_map(completion) do
    Map.get(completion, key, Map.get(completion, to_string(key)))
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    if startup_slots_available?(state) do
      select_worker_host_with_startup_capacity(state, preferred_worker_host)
    else
      :no_worker_capacity
    end
  end

  defp select_worker_host_with_startup_capacity(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] -> nil
      hosts -> select_available_worker_host(state, preferred_worker_host, hosts)
    end
  end

  defp select_available_worker_host(%State{} = state, preferred_worker_host, hosts) do
    available_hosts =
      Enum.filter(hosts, fn host ->
        worker_host_slots_available?(state, host) and
          worker_host_startup_slots_available?(state, host)
      end)

    cond do
      available_hosts == [] ->
        :no_worker_capacity

      preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
        preferred_worker_host

      true ->
        least_loaded_worker_host(state, available_hosts)
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host)
       when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp running_startup_count(running) when is_map(running) do
    Enum.count(running, fn
      {_issue_id, %{startup_slot?: true}} -> true
      _ -> false
    end)
  end

  defp startup_slots_available?(%State{} = state) do
    limit = state.max_concurrent_startups || Config.settings!().agent.max_concurrent_startups
    running_startup_count(state.running) < limit
  end

  defp running_worker_host_startup_count(running, worker_host)
       when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host, startup_slot?: true}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp issue_policy_allows_dispatch?(issue) do
    case Config.issue_policy(issue) do
      {:ok, _policy} ->
        true

      {:error, reason} ->
        Logger.error("Skipping dispatch; workflow policy failed for #{issue_context(issue)} reason=#{inspect(reason)}")

        false
    end
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp worker_host_startup_slots_available?(%State{} = state, worker_host)
       when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_startups_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_startup_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp running_entry_issue_identifier(%{issue: %Issue{identifier: identifier}})
       when is_binary(identifier),
       do: identifier

  defp running_entry_issue_identifier(%{issue: %{identifier: identifier}})
       when is_binary(identifier),
       do: identifier

  defp running_entry_issue_identifier(%{identifier: identifier}) when is_binary(identifier),
    do: identifier

  defp running_entry_issue_identifier(_running_entry), do: "n/a"

  defp issue_id_from_run_id({_target_id, issue_id}) when is_binary(issue_id), do: issue_id
  defp issue_id_from_run_id(issue_id) when is_binary(issue_id), do: issue_id
  defp issue_id_from_run_id(_run_id), do: nil

  defp execution_context_log(%ExecutionContext{} = context) do
    "target_id=#{context.target.target_id} issue_id=#{context.issue_id} issue_identifier=#{context.issue_identifier} registry_generation=#{context.target.registry_generation} policy_hash=#{context.target.policy_hash}"
  end

  defp run_log_context(_run_id, %{execution_context: %ExecutionContext{} = context}),
    do: execution_context_log(context)

  defp run_log_context(run_id, running_entry) do
    identifier = running_entry_issue_identifier(running_entry || %{})
    "issue_id=#{issue_id_from_run_id(run_id)} issue_identifier=#{identifier}"
  end

  defp retry_log_context(_run_id, %ExecutionContext{} = context, _identifier),
    do: execution_context_log(context)

  defp retry_log_context(run_id, _context, identifier) do
    "issue_id=#{issue_id_from_run_id(run_id)} issue_identifier=#{identifier || "n/a"}"
  end

  defp safe_context_status_fields(%{execution_context: %ExecutionContext{} = context}) do
    case ExecutionContext.safe_provenance(context) do
      {:ok, provenance} ->
        Map.take(provenance, [:target_id, :registry_generation, :policy_hash])

      {:error, _reason} ->
        %{}
    end
  end

  defp safe_context_status_fields(_entry), do: %{}

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  defp increment_dispatched_issue_count(%State{dispatched_issue_count: count}, nil)
       when is_integer(count),
       do: count + 1

  defp increment_dispatched_issue_count(%State{dispatched_issue_count: count}, _attempt)
       when is_integer(count),
       do: count

  defp increment_dispatched_issue_count(_state, nil), do: 1
  defp increment_dispatched_issue_count(_state, _attempt), do: 0

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {run_id, metadata} ->
        %{
          issue_id: issue_id_from_run_id(run_id),
          identifier: metadata.identifier,
          issue_url: issue_url_from_running(metadata),
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          profile: Map.get(metadata, :profile),
          target: Map.get(metadata, :target),
          policy_ref: Map.get(metadata, :policy_ref),
          workflow_module_policy_hash: workflow_module_policy_hash(Map.get(metadata, :workflow_module_resolution)),
          workflow_modules: workflow_module_refs(Map.get(metadata, :workflow_module_resolution)),
          session_id: metadata.session_id,
          last_runtime_progress_timestamp: Map.get(metadata, :last_runtime_progress_timestamp),
          startup: Map.get(metadata, :startup_slot?) == true,
          adapter: runtime_adapter_diagnostics(metadata),
          workflow_file_path: Map.get(metadata, :workflow_file_path),
          workflow_config_sha256: Map.get(metadata, :workflow_config_sha256),
          runtime_input_tokens: metadata.runtime_input_tokens,
          runtime_output_tokens: metadata.runtime_output_tokens,
          runtime_total_tokens: metadata.runtime_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_runtime_timestamp: metadata.last_runtime_timestamp,
          last_runtime_message: metadata.last_runtime_message,
          last_runtime_event: metadata.last_runtime_event,
          last_runtime_error_signature: Map.get(metadata, :last_runtime_error_signature),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
        |> Map.merge(safe_context_status_fields(metadata))
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {run_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id_from_run_id(run_id),
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          session_id: Map.get(retry, :session_id),
          last_error_signature: Map.get(retry, :last_error_signature),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path),
          profile: Map.get(retry, :profile),
          target: Map.get(retry, :target),
          policy_ref: Map.get(retry, :policy_ref)
        }
        |> Map.merge(safe_context_status_fields(retry))
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {run_id, metadata} ->
        %{
          issue_id: issue_id_from_run_id(run_id),
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          profile: Map.get(metadata, :profile),
          target: Map.get(metadata, :target),
          policy_ref: Map.get(metadata, :policy_ref),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_runtime_timestamp: Map.get(metadata, :last_runtime_timestamp),
          last_runtime_message: Map.get(metadata, :last_runtime_message),
          last_runtime_event: Map.get(metadata, :last_runtime_event)
        }
        |> Map.merge(safe_context_status_fields(metadata))
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       handoff_routes: handoff_route_entries(state.handoff_routes),
       runtime_totals: state.runtime_totals,
       rate_limits: Map.get(state, :runtime_rate_limits),
       tracker: %{
         limited?: tracker_backoff_active?(state),
         rate_limit: tracker_rate_limit_snapshot(state, now_ms)
       },
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp tracker_rate_limit_snapshot(%State{tracker_rate_limit: nil}, _now_ms), do: nil

  defp tracker_rate_limit_snapshot(%State{tracker_rate_limit: tracker_rate_limit}, now_ms)
       when is_map(tracker_rate_limit) do
    case tracker_rate_limit_remaining_ms(tracker_rate_limit, now_ms) do
      remaining_ms when is_integer(remaining_ms) and remaining_ms > 0 ->
        tracker_rate_limit
        |> Map.drop([:limited_until_ms])
        |> Map.put(:remaining_ms, remaining_ms)

      _remaining_ms ->
        nil
    end
  end

  defp tracker_rate_limit_remaining_ms(%{limited_until_ms: limited_until_ms}, now_ms)
       when is_integer(limited_until_ms) and is_integer(now_ms) do
    max(0, limited_until_ms - now_ms)
  end

  defp tracker_rate_limit_remaining_ms(_tracker_rate_limit, _now_ms), do: nil

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp runtime_adapter_diagnostics(metadata) when is_map(metadata) do
    %{
      kind: "codex",
      diagnostics: %{
        app_server_pid: Map.get(metadata, :codex_app_server_pid),
        command: Map.get(metadata, :codex_command),
        home: Map.get(metadata, :codex_home),
        workspace: Map.get(metadata, :codex_workspace),
        execution_profile: %{
          name: Map.get(metadata, :codex_execution_profile),
          model: Map.get(metadata, :codex_execution_profile_model),
          reasoning_effort: Map.get(metadata, :codex_execution_profile_reasoning_effort),
          budget: Map.get(metadata, :codex_execution_profile_budget),
          timeout_ms: Map.get(metadata, :codex_execution_profile_timeout_ms)
        }
      }
    }
  end

  defp handoff_route_entries(handoff_routes) when is_map(handoff_routes) do
    Enum.map(handoff_routes, fn {run_id, decision} ->
      Map.put(decision, :issue_id, issue_id_from_run_id(run_id))
    end)
  end

  defp handoff_route_entries(_handoff_routes), do: []

  defp handoff_decision_for_running_entry(
         %{
           execution_context: %ExecutionContext{} = context,
           issue: %Issue{} = issue
         } = running_entry,
         blocker
       ) do
    HandoffRouteRecorder.classify_completion_context(
      context,
      issue,
      Map.get(running_entry, :completion, %{}),
      blocker
    )
  end

  defp handoff_decision_for_running_entry(running_entry, blocker) when is_map(running_entry) do
    running_entry
    |> Map.get(:completion, %{})
    |> HandoffRouteRecorder.classify_completion(
      blocker,
      Map.get(running_entry, :workspace_path),
      Map.get(running_entry, :worker_host),
      %{
        policy: Map.get(running_entry, :policy),
        labels: running_entry_labels(running_entry),
        workflow_module_resolution: Map.get(running_entry, :workflow_module_resolution)
      },
      Map.get(running_entry, :issue)
    )
  end

  defp handoff_decision_for_running_entry(_running_entry, blocker) do
    HandoffRouteRecorder.classify_completion(%{}, blocker)
  end

  defp running_entry_labels(%{issue: %{labels: labels}}) when is_list(labels), do: labels
  defp running_entry_labels(_running_entry), do: []

  defp workflow_module_policy_hash(%{policy_hash: policy_hash}) when is_binary(policy_hash),
    do: policy_hash

  defp workflow_module_policy_hash(%{"policy_hash" => policy_hash}) when is_binary(policy_hash),
    do: policy_hash

  defp workflow_module_policy_hash(_resolution), do: nil

  defp workflow_module_refs(%{module_refs: refs}) when is_list(refs), do: refs
  defp workflow_module_refs(%{"module_refs" => refs}) when is_list(refs), do: refs
  defp workflow_module_refs(_resolution), do: []

  defp maybe_persist_handoff_route(
         %{execution_context: %ExecutionContext{} = context},
         %HandoffRoute.Decision{} = decision
       ) do
    case HandoffRouteRecorder.record(context, decision) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Unable to persist handoff route for #{execution_context_log(context)}: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_persist_handoff_route(running_entry, %HandoffRoute.Decision{} = decision)
       when is_map(running_entry) do
    maybe_persist_handoff_route(
      issue_id_from_entry(nil, running_entry),
      decision
    )
  end

  defp maybe_persist_handoff_route(issue_id, %HandoffRoute.Decision{} = decision)
       when is_binary(issue_id) do
    case HandoffRouteRecorder.record(issue_id, decision) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Unable to persist handoff route for issue_id=#{issue_id}: #{inspect(reason)}")

        :ok
    end
  end

  defp maybe_persist_quality_gate_review_record(
         %{
           execution_context: %ExecutionContext{} = context,
           issue: %Issue{} = issue
         } = running_entry,
         %HandoffRoute.Decision{} = decision
       ) do
    completion = Map.get(running_entry, :completion, %{})

    case completion_field(completion, :quality_gate) do
      quality_gate when is_map(quality_gate) ->
        params = %{
          logs_root: context_logs_root(context),
          policy: context.policy,
          issue: issue,
          workflow: %{
            profile: Map.get(running_entry, :profile),
            target: Map.get(running_entry, :target),
            policy_ref: Map.get(running_entry, :policy_ref)
          },
          run: %{
            session_id: Map.get(running_entry, :session_id),
            started_at: Map.get(running_entry, :started_at),
            completed_at: DateTime.utc_now()
          },
          workspace: context.workspace_path,
          quality_gate: quality_gate,
          handoff_route: decision
        }

        case ReviewRecords.write_quality_gate_run(context, params) do
          {:ok, _record} ->
            :ok

          {:error, reason} ->
            Logger.warning("Unable to persist quality-gate review record for #{execution_context_log(context)} session_id=#{running_entry_session_id(running_entry)}: #{inspect(reason)}")
            :ok
        end

      _quality_gate ->
        :ok
    end
  end

  defp maybe_persist_quality_gate_review_record(
         running_entry,
         %HandoffRoute.Decision{} = decision
       )
       when is_map(running_entry) do
    issue_id = issue_id_from_entry(nil, running_entry)
    completion = Map.get(running_entry, :completion, %{})

    case completion_field(completion, :quality_gate) do
      quality_gate when is_map(quality_gate) and is_binary(issue_id) ->
        params = %{
          policy: Map.get(running_entry, :policy, %{}),
          issue:
            Map.get(running_entry, :issue, %{
              id: issue_id,
              identifier: Map.get(running_entry, :identifier)
            }),
          workflow: %{
            profile: Map.get(running_entry, :profile),
            target: Map.get(running_entry, :target),
            policy_ref: Map.get(running_entry, :policy_ref)
          },
          run: %{
            session_id: Map.get(running_entry, :session_id),
            started_at: Map.get(running_entry, :started_at),
            completed_at: DateTime.utc_now()
          },
          workspace: Map.get(running_entry, :workspace_path),
          quality_gate: quality_gate,
          handoff_route: decision
        }

        case ReviewRecords.write_quality_gate_run(params) do
          {:ok, _record} ->
            :ok

          {:error, reason} ->
            Logger.warning("Unable to persist quality-gate review record for issue_id=#{issue_id}: #{inspect(reason)}")
            :ok
        end

      _quality_gate ->
        :ok
    end
  end

  defp maybe_persist_quality_gate_review_record(_running_entry, _decision), do: :ok

  defp context_logs_root(%ExecutionContext{target: %{worktree_policy: %{"root" => root}}})
       when is_binary(root),
       do: Path.dirname(root)

  defp maybe_put_completion(running_entry, update) do
    case completion_for_update(update) do
      %{} = completion -> Map.put(running_entry, :completion, completion)
      _ -> running_entry
    end
  end

  defp completion_for_update(%{completion: completion}) when is_map(completion), do: completion

  defp completion_for_update(%{"completion" => completion}) when is_map(completion),
    do: completion

  defp completion_for_update(%{payload: payload}) when is_map(payload) do
    completion_from_payload(payload)
  end

  defp completion_for_update(%{"payload" => payload}) when is_map(payload) do
    completion_from_payload(payload)
  end

  defp completion_for_update(_update), do: nil

  defp completion_from_payload(payload) when is_map(payload) do
    map_at_path(payload, ["params", "completion"]) ||
      map_at_path(payload, [:params, :completion]) ||
      map_at_path(payload, ["params", "turn", "completion"]) ||
      map_at_path(payload, [:params, :turn, :completion])
  end

  defp integrate_runtime_event(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    runtime_input_tokens = Map.get(running_entry, :runtime_input_tokens, 0)
    runtime_output_tokens = Map.get(running_entry, :runtime_output_tokens, 0)
    runtime_total_tokens = Map.get(running_entry, :runtime_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :runtime_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :runtime_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :runtime_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)
    last_progress_timestamp = progress_timestamp_for_update(running_entry, update, token_delta)
    last_error_signature = runtime_error_signature_for_event(running_entry, update)
    provenance = &provenance_value_for_update(running_entry, update, &1)
    profile_model = provenance.(:codex_execution_profile_model)
    profile_reasoning_effort = provenance.(:codex_execution_profile_reasoning_effort)
    profile_budget = provenance.(:codex_execution_profile_budget)
    profile_timeout_ms = provenance.(:codex_execution_profile_timeout_ms)

    {
      Map.merge(running_entry, %{
        last_runtime_timestamp: timestamp,
        last_runtime_message: summarize_runtime_event(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        runtime: Map.get(update, :runtime, Map.get(running_entry, :runtime)),
        last_runtime_progress_timestamp: last_progress_timestamp,
        last_runtime_event: event,
        last_runtime_error_signature: last_error_signature,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_command: provenance.(:codex_command),
        codex_home: provenance.(:codex_home),
        codex_workspace: provenance.(:codex_workspace),
        codex_execution_profile: provenance.(:codex_execution_profile),
        codex_execution_profile_model: profile_model,
        codex_execution_profile_reasoning_effort: profile_reasoning_effort,
        codex_execution_profile_budget: profile_budget,
        codex_execution_profile_timeout_ms: profile_timeout_ms,
        workflow_file_path: provenance.(:workflow_file_path),
        workflow_config_sha256: provenance.(:workflow_config_sha256),
        runtime_input_tokens: runtime_input_tokens + token_delta.input_tokens,
        runtime_output_tokens: runtime_output_tokens + token_delta.output_tokens,
        runtime_total_tokens: runtime_total_tokens + token_delta.total_tokens,
        runtime_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        runtime_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        runtime_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      })
      |> maybe_release_startup_slot(event)
      |> maybe_put_completion(update),
      token_delta
    }
  end

  defp maybe_release_startup_slot(running_entry, event)
       when event in [:session_started, :startup_failed] do
    Map.put(running_entry, :startup_slot?, false)
  end

  defp maybe_release_startup_slot(running_entry, _event), do: running_entry

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp provenance_value_for_update(running_entry, update, key) do
    case Map.fetch(update, key) do
      {:ok, value} -> value
      :error -> Map.get(running_entry, key)
    end
  end

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_runtime_event(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:native] || update[:raw] || error_message_from_update(update),
      timestamp: update[:timestamp]
    }
  end

  defp progress_timestamp_for_update(running_entry, update, token_delta) do
    if runtime_progress_event?(update, token_delta) do
      update[:timestamp]
    else
      Map.get(running_entry, :last_runtime_progress_timestamp)
    end
  end

  defp runtime_progress_event?(%{event: event}, _token_delta)
       when event in [
              :session_started,
              :turn_progress,
              :turn_completed,
              :turn_failed,
              :turn_cancelled,
              :turn_ended_with_error,
              :turn_input_required,
              :approval_auto_approved,
              :approval_required,
              :tool_input_auto_answered,
              :tool_call_completed,
              :tool_call_failed,
              :unsupported_tool_call,
              :codex_error_loop,
              :startup_failed
            ],
       do: true

  defp runtime_progress_event?(update, token_delta) do
    token_delta_has_progress?(token_delta) or
      runtime_progress_method?(update_payload_method(update))
  end

  defp token_delta_has_progress?(%{
         input_tokens: input,
         output_tokens: output,
         total_tokens: total
       }) do
    Enum.any?([input, output, total], &(&1 > 0))
  end

  defp runtime_progress_method?(method)
       when method in [
              "thread/started",
              "turn/started",
              "turn/completed",
              "turn/failed",
              "turn/cancelled",
              "item/completed",
              "item/tool/call",
              "item/commandExecution/requestApproval",
              "item/fileChange/requestApproval",
              "item/tool/requestUserInput",
              "codex/event/task_started",
              "codex/event/exec_command_begin",
              "codex/event/exec_command_end",
              "codex/event/agent_message_delta",
              "thread/tokenUsage/updated"
            ],
       do: true

  defp runtime_progress_method?(_method), do: false

  defp update_payload_method(update) when is_map(update) do
    payload = update[:payload] || Map.get(update, "payload") || update

    if is_map(payload) do
      Map.get(payload, "method") || Map.get(payload, :method)
    else
      nil
    end
  end

  defp runtime_error_signature_for_event(running_entry, update) do
    runtime_error_context_from_event(update)
    |> case do
      %{signature: signature} when is_binary(signature) ->
        signature

      %{"signature" => signature} when is_binary(signature) ->
        signature

      _ ->
        update[:signature] || Map.get(update, :signature) ||
          Map.get(running_entry, :last_runtime_error_signature)
    end
  end

  defp runtime_error_context_from_event(%{reason: {:codex_error_loop, context}})
       when is_map(context), do: context

  defp runtime_error_context_from_event(%{details: {:codex_error_loop, context}})
       when is_map(context), do: context

  defp runtime_error_context_from_event(%{event: :codex_error_loop} = update), do: update
  defp runtime_error_context_from_event(_update), do: nil

  defp error_message_from_update(update) do
    case runtime_error_context_from_event(update) do
      nil ->
        update[:reason]

      context ->
        %{reason: update[:reason], signature: context[:signature] || context["signature"]}
    end
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp maybe_schedule_next_poll(%State{} = state) do
    if continue_polling?(state) do
      schedule_tick(state, state.poll_interval_ms)
    else
      %{state | tick_timer_ref: nil, tick_token: nil, next_poll_due_at_ms: nil}
    end
  end

  defp continue_polling?(%State{run_mode: :watch}), do: true

  defp continue_polling?(%State{run_mode: :drain} = state) do
    runtime_active?(state)
  end

  defp continue_polling?(%State{run_mode: :issue_batch} = state) do
    runtime_active?(state) or dispatch_budget_available?(state)
  end

  defp continue_polling?(_state), do: true

  defp runtime_active?(%State{} = state) do
    map_size(state.running) > 0 or map_size(state.retry_attempts) > 0
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    runtime_totals =
      apply_token_delta(
        state.runtime_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | runtime_totals: runtime_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()
    capacity = RunSetup.capacity(config)

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: capacity.max_concurrent_agents,
        max_concurrent_startups: capacity.max_concurrent_startups,
        run_mode: RunSetup.mode(),
        issue_batch_limit: RunSetup.issue_batch_limit()
    }
  end

  defp retry_candidate_issue?(
         %Issue{id: id, identifier: identifier, title: title, state: state_name} = issue,
         terminal_states,
         context
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and
              is_binary(state_name) do
    issue_routable?(issue, context) and
      active_issue_state?(state_name, active_state_set(context)) and
      !terminal_issue_state?(state_name, terminal_states) and
      is_nil(issue_dispatch_block_reason(issue, terminal_states))
  end

  defp retry_candidate_issue?(_issue, _terminal_states, _context), do: false

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      is_nil(issue_dispatch_block_reason(issue, terminal_states))
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and startup_slots_available?(state) and
      state_slots_available?(issue, state.running)
  end

  defp dispatch_budget_available?(%State{
         run_mode: :issue_batch,
         issue_batch_limit: limit,
         dispatched_issue_count: count
       })
       when is_integer(limit) and limit > 0 and is_integer(count) do
    count < limit
  end

  defp dispatch_budget_available?(%State{run_mode: :issue_batch, issue_batch_limit: nil}),
    do: false

  defp dispatch_budget_available?(_state), do: true

  defp apply_runtime_token_delta(
         %{runtime_totals: runtime_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | runtime_totals: apply_token_delta(runtime_totals, token_delta)}
  end

  defp apply_runtime_token_delta(state, _token_delta), do: state

  defp apply_runtime_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | runtime_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_runtime_rate_limits(state, _update), do: state

  defp apply_token_delta(runtime_totals, token_delta) do
    input_tokens = Map.get(runtime_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(runtime_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(runtime_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(runtime_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :runtime_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :runtime_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :runtime_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    if integer_token_map?(payload) do
      payload
    else
      absolute_paths = [
        ["params", "msg", "payload", "info", "total_token_usage"],
        [:params, :msg, :payload, :info, :total_token_usage],
        ["params", "msg", "info", "total_token_usage"],
        [:params, :msg, :info, :total_token_usage],
        ["params", "tokenUsage", "total"],
        [:params, :tokenUsage, :total],
        ["tokenUsage", "total"],
        [:tokenUsage, :total]
      ]

      explicit_map_at_paths(payload, absolute_paths)
    end
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
