defmodule SymphonyElixir.OperatorSnapshot do
  @moduledoc """
  Builds the complete, credential-safe read model for local operator clients.

  The projection uses only host-owned scheduler, orchestrator, and durable
  control-plane state. Unavailable sources remain explicit and do not become
  empty healthy collections.
  """

  alias SymphonyElixir.{ControlPlane, HostScheduler, Orchestrator}
  alias SymphonyElixir.ReviewRecords.Redaction
  alias SymphonyElixir.TargetRegistry.Schema

  @queue_stale_after_ms 5 * 60 * 1_000
  @slot_keys [:agents, :startups, :reviewers, :polls]
  @target_actions [:activate, :pause, :drain, :retire]

  @type source_result :: {:current, term()} | {:timeout, nil} | {:unavailable, nil}

  @spec build(GenServer.server(), GenServer.server() | nil, timeout(), map()) :: map()
  def build(scheduler, control_plane, snapshot_timeout_ms, marker) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    host_result = scheduler_snapshot(scheduler)

    case host_result do
      {:current, host} ->
        runtime_results = target_runtime_snapshots(host, snapshot_timeout_ms)
        durable_runs_result = control_plane_runs(control_plane)
        budgets_result = control_plane_budgets(control_plane)

        project(
          host_result,
          runtime_results,
          durable_runs_result,
          budgets_result,
          marker,
          generated_at
        )

      {_status, nil} ->
        project(host_result, %{}, {:unavailable, nil}, {:unavailable, nil}, marker, generated_at)
    end
  end

  @doc false
  @spec project(source_result(), map(), source_result(), source_result(), map(), DateTime.t()) :: map()
  def project(host_result, runtime_results, durable_runs_result, budgets_result, marker, generated_at)
      when is_map(runtime_results) and is_map(marker) do
    case host_result do
      {:current, host} when is_map(host) ->
        project_available_host(
          host,
          runtime_results,
          durable_runs_result,
          budgets_result,
          marker,
          generated_at
        )

      {status, nil} ->
        unavailable_snapshot(status, marker, generated_at)
    end
  end

  defp scheduler_snapshot(scheduler) do
    {:current, HostScheduler.snapshot(scheduler)}
  catch
    :exit, {:timeout, _reason} -> {:timeout, nil}
    :exit, _reason -> {:unavailable, nil}
  end

  defp target_runtime_snapshots(host, snapshot_timeout_ms) do
    host
    |> Map.get(:targets, %{})
    |> Map.new(fn {target_id, target} ->
      {target_id, target_runtime_snapshot(target, snapshot_timeout_ms)}
    end)
  end

  defp target_runtime_snapshot(%{pid: pid}, snapshot_timeout_ms) when is_pid(pid) do
    case Orchestrator.snapshot(pid, snapshot_timeout_ms) do
      %{} = snapshot -> {:current, snapshot}
      :timeout -> {:timeout, nil}
      :unavailable -> {:unavailable, nil}
    end
  end

  defp target_runtime_snapshot(_target, _snapshot_timeout_ms), do: {:unavailable, nil}

  defp control_plane_runs(nil), do: {:unavailable, nil}

  defp control_plane_runs(control_plane) do
    case ControlPlane.inspect_runs(control_plane) do
      {:ok, runs} when is_list(runs) -> {:current, runs}
      {:error, _reason} -> {:unavailable, nil}
    end
  catch
    :exit, _reason -> {:unavailable, nil}
  end

  defp control_plane_budgets(nil), do: {:unavailable, nil}

  defp control_plane_budgets(control_plane) do
    case ControlPlane.inspect_target_budgets(control_plane) do
      {:ok, budgets} when is_list(budgets) -> {:current, budgets}
      {:error, _reason} -> {:unavailable, nil}
    end
  catch
    :exit, _reason -> {:unavailable, nil}
  end

  defp project_available_host(
         host,
         runtime_results,
         durable_runs_result,
         budgets_result,
         marker,
         generated_at
       ) do
    budgets_by_target = budgets_by_target(budgets_result)

    targets =
      host
      |> Map.get(:targets, %{})
      |> Enum.map(fn {target_id, target} ->
        target_projection(
          target_id,
          target,
          Map.get(runtime_results, target_id, {:unavailable, nil}),
          budgets_result,
          Map.get(budgets_by_target, target_id),
          generated_at
        )
      end)
      |> Enum.sort_by(& &1.target_id)

    runs = runs_projection(durable_runs_result, runtime_results)
    warnings = warnings(host, runtime_results, durable_runs_result, budgets_result, targets)
    freshness_status = freshness_status(runtime_results, durable_runs_result, budgets_result, targets)

    %{
      interface_version: marker.interface_version,
      schema_version: marker.schema_version,
      snapshot: %{
        mode: "complete",
        replacement_required: false,
        event_cursor: marker.cursor
      },
      host: %{
        id: marker.host_id,
        started_at: marker.started_at,
        status: "available",
        registry: registry_projection(host),
        capacity: host_capacity(host),
        commands: host_commands(host, durable_runs_result)
      },
      freshness: %{
        status: freshness_status,
        generated_at: DateTime.to_iso8601(generated_at),
        age_ms: 0,
        stale_after_ms: @queue_stale_after_ms,
        sources: source_statuses(runtime_results, durable_runs_result, budgets_result)
      },
      aggregate: aggregate_projection(targets, host),
      targets: targets,
      runs: runs,
      warnings: warnings
    }
  end

  defp unavailable_snapshot(status, marker, generated_at) do
    source_status = source_status(status)

    %{
      interface_version: marker.interface_version,
      schema_version: marker.schema_version,
      snapshot: %{
        mode: "complete",
        replacement_required: false,
        event_cursor: marker.cursor
      },
      host: %{
        id: marker.host_id,
        started_at: marker.started_at,
        status: source_status,
        registry: %{status: source_status, generation: nil, verified: nil, error: nil},
        capacity: %{status: source_status, used: nil, limits: nil},
        commands:
          Enum.map(~w(refresh shutdown prune), fn action ->
            %{action: action, available: false, disabled_reason: "host_unavailable"}
          end)
      },
      freshness: %{
        status: source_status,
        generated_at: DateTime.to_iso8601(generated_at),
        age_ms: 0,
        stale_after_ms: @queue_stale_after_ms,
        sources: %{
          scheduler: source_status,
          control_plane: "unavailable",
          targets: %{},
          budgets: "unavailable"
        }
      },
      aggregate: %{
        status: source_status,
        capacity: %{status: source_status, used: nil, limits: nil},
        counts: %{status: source_status, queued: nil, running: nil, retrying: nil, blocked: nil}
      },
      targets: [],
      runs: %{status: "unavailable", entries: []},
      warnings: [warning("scheduler_#{source_status}", "error", "Host scheduler snapshot is #{source_status}.")]
    }
  end

  defp registry_projection(host) do
    registry = Map.get(host, :registry, %{})
    verified = Map.get(registry, :verified?)

    %{
      status: if(verified == true, do: "verified", else: "unverified"),
      generation: safe_string(Map.get(registry, :generation)),
      verified: if(is_boolean(verified), do: verified, else: nil),
      error: safe_error(Map.get(registry, :error))
    }
  end

  defp host_capacity(host) do
    %{
      status: "current",
      used: slot_projection(Map.get(host, :counts)),
      limits: host_limit_projection(Map.get(host, :limits))
    }
  end

  defp host_commands(host, durable_runs_result) do
    registry_verified = get_in(host, [:registry, :verified?]) == true
    shutdown = Map.get(host, :shutdown, %{ready?: false, reason: :host_unavailable})

    prune_disabled_reason =
      cond do
        not registry_verified -> "registry_unverified"
        not match?({:current, _}, durable_runs_result) -> "control_plane_unavailable"
        true -> nil
      end

    [
      %{
        action: "refresh",
        available: registry_verified,
        disabled_reason: if(registry_verified, do: nil, else: "registry_unverified")
      },
      %{
        action: "shutdown",
        available: registry_verified and shutdown.ready?,
        disabled_reason: if(registry_verified and shutdown.ready?, do: nil, else: token(shutdown.reason || :registry_unverified))
      },
      %{
        action: "prune",
        available: is_nil(prune_disabled_reason),
        disabled_reason: prune_disabled_reason
      }
    ]
  end

  defp target_projection(
         target_id,
         target,
         runtime_result,
         budgets_result,
         budget_usage,
         generated_at
       ) do
    runtime_status = source_result_status(runtime_result)
    queue = queue_projection(runtime_result, generated_at)
    operator = Map.get(target, :operator, %{})

    %{
      target_id: safe_string(target_id),
      repository: %{
        path: safe_string(get_in(operator, [:repository, :path]))
      },
      tracker: tracker_projection(get_in(operator, [:tracker])),
      configured_state: token(Map.get(target, :configured_state)),
      effective_state: token(Map.get(target, :effective_state)),
      eligibility_reason: token(Map.get(target, :eligibility_reason)),
      dispatch_mode: token(Map.get(operator, :dispatch_mode)),
      policy_hash: safe_string(Map.get(operator, :policy_hash)),
      registry_generation: safe_string(Map.get(target, :generation)),
      capacity: %{
        status: "current",
        used: slot_projection(Map.get(target, :counts)),
        limits: target_limit_projection(Map.get(target, :limits))
      },
      runtime: %{
        status: runtime_status,
        counts: runtime_counts(runtime_result)
      },
      budget: budget_projection(Map.get(target, :budget_limits), budgets_result, budget_usage),
      tracker_backoff: tracker_backoff_projection(Map.get(target, :tracker_backoff)),
      queue: queue,
      commands: target_commands(target_id, target, operator)
    }
  end

  defp tracker_projection(nil),
    do: %{status: "unavailable", connection_id: nil, kind: nil, scope: nil}

  defp tracker_projection(tracker) when is_map(tracker) do
    %{
      status: "current",
      connection_id: safe_string(Map.get(tracker, :connection_id)),
      kind: token(Map.get(tracker, :kind)),
      scope: safe_scope(Map.get(tracker, :scope))
    }
  end

  defp safe_scope(scope) when is_map(scope) do
    %{
      type: safe_string(field(scope, "type")),
      project_id: safe_string(field(scope, "project_id")),
      project_slug: safe_string(field(scope, "project_slug")),
      team_key: safe_string(field(scope, "team_key"))
    }
  end

  defp safe_scope(_scope), do: nil

  defp queue_projection({:current, runtime}, generated_at) when is_map(runtime) do
    entries = Map.get(runtime, :pending_queue)
    observed_at = iso8601(Map.get(runtime, :pending_queue_observed_at))

    cond do
      not is_list(entries) ->
        %{status: "unavailable", observed_at: observed_at, entries: []}

      stale?(observed_at, generated_at) ->
        %{status: "stale", observed_at: observed_at, entries: Enum.map(entries, &queue_entry/1)}

      true ->
        %{status: "current", observed_at: observed_at, entries: Enum.map(entries, &queue_entry/1)}
    end
  end

  defp queue_projection({status, nil}, _generated_at),
    do: %{status: source_status(status), observed_at: nil, entries: []}

  defp queue_entry(entry) when is_map(entry) do
    %{
      position: non_negative_integer(Map.get(entry, :position)),
      issue_id: safe_string(Map.get(entry, :issue_id)),
      issue_identifier: safe_string(Map.get(entry, :issue_identifier)),
      state: safe_string(Map.get(entry, :state)),
      priority: non_negative_integer(Map.get(entry, :priority)),
      status: token(Map.get(entry, :status)),
      reason: token(Map.get(entry, :reason))
    }
  end

  defp runtime_counts({:current, runtime}) when is_map(runtime) do
    %{
      running: list_count(Map.get(runtime, :running)),
      retrying: list_count(Map.get(runtime, :retrying)),
      blocked: list_count(Map.get(runtime, :blocked))
    }
  end

  defp runtime_counts({_status, nil}), do: nil

  defp budget_projection(nil, _budgets_result, _budget_usage) do
    %{
      status: "not_configured",
      configured: false,
      usage: nil,
      limits: nil,
      exhausted: nil
    }
  end

  defp budget_projection(limits, {:current, _budgets}, nil) when is_map(limits) do
    %{
      status: "missing",
      configured: true,
      usage: nil,
      limits: budget_limits(limits),
      exhausted: nil
    }
  end

  defp budget_projection(limits, {:current, _budgets}, usage)
       when is_map(limits) and is_map(usage) do
    daily_used = sum_known(Map.get(usage, :daily_charged_tokens), Map.get(usage, :daily_reserved_tokens))
    weekly_used = sum_known(Map.get(usage, :weekly_charged_tokens), Map.get(usage, :weekly_reserved_tokens))
    daily_limit = integer_or_nil(Map.get(limits, :daily_tokens))
    weekly_limit = integer_or_nil(Map.get(limits, :weekly_tokens))

    %{
      status: "current",
      configured: true,
      usage: %{
        reserved_tokens: integer_or_nil(Map.get(usage, :reserved_tokens)),
        daily_reserved_tokens: integer_or_nil(Map.get(usage, :daily_reserved_tokens)),
        weekly_reserved_tokens: integer_or_nil(Map.get(usage, :weekly_reserved_tokens)),
        charged_tokens: integer_or_nil(Map.get(usage, :charged_tokens)),
        daily_charged_tokens: integer_or_nil(Map.get(usage, :daily_charged_tokens)),
        weekly_charged_tokens: integer_or_nil(Map.get(usage, :weekly_charged_tokens))
      },
      limits: budget_limits(limits),
      exhausted: limit_reached?(daily_used, daily_limit) or limit_reached?(weekly_used, weekly_limit)
    }
  end

  defp budget_projection(limits, {status, nil}, _usage) when is_map(limits) do
    %{
      status: source_status(status),
      configured: true,
      usage: nil,
      limits: budget_limits(limits),
      exhausted: nil
    }
  end

  defp budget_limits(limits) do
    %{
      per_run_tokens: integer_or_nil(Map.get(limits, :per_run_tokens)),
      daily_tokens: integer_or_nil(Map.get(limits, :daily_tokens)),
      weekly_tokens: integer_or_nil(Map.get(limits, :weekly_tokens))
    }
  end

  defp tracker_backoff_projection(backoff) when is_map(backoff) do
    %{
      status: "current",
      active: if(is_boolean(Map.get(backoff, :active)), do: Map.get(backoff, :active), else: nil),
      remaining_ms: integer_or_nil(Map.get(backoff, :remaining_ms))
    }
  end

  defp tracker_backoff_projection(_backoff),
    do: %{status: "unavailable", active: nil, remaining_ms: nil}

  defp target_commands(target_id, target, operator) do
    configured = %{
      "state" => token(Map.get(target, :configured_state)),
      "dispatch_mode" => token(Map.get(operator, :dispatch_mode))
    }

    Enum.map(@target_actions, fn action ->
      case Schema.transition_target(configured, to_string(target_id), action, nil) do
        {:ok, _transitioned} ->
          %{action: Atom.to_string(action), available: true, disabled_reason: nil}

        {:error, %{code: code}} ->
          %{action: Atom.to_string(action), available: false, disabled_reason: token(code)}
      end
    end)
  end

  defp runs_projection({status, nil}, _runtime_results),
    do: %{status: source_status(status), entries: []}

  defp runs_projection({:current, durable_runs}, runtime_results) do
    runtime_by_run = runtime_entries(runtime_results)
    handoffs = handoff_entries(runtime_results)
    landings = landing_entries(runtime_results)

    entries =
      Enum.map(durable_runs, fn run ->
        run_key = {Map.get(run, :target_id), Map.get(run, :tracker_issue_id)}
        runtime = Map.get(runtime_by_run, run_key)
        handoff = Map.get(handoffs, run_key)
        landing = Map.get(landings, run_key)

        runtime_status =
          runtime_results
          |> Map.get(Map.get(run, :target_id), {:unavailable, nil})
          |> source_result_status()

        run_projection(run, runtime, handoff, landing, runtime_status)
      end)

    %{status: "current", entries: entries}
  end

  defp run_projection(run, runtime, handoff, landing, runtime_status) do
    lifecycle_state = safe_string(Map.get(run, :lifecycle_state))

    %{
      admitted_run_id: safe_string(Map.get(run, :admitted_run_id)),
      target_id: safe_string(Map.get(run, :target_id)),
      issue: %{
        id: safe_string(Map.get(run, :tracker_issue_id)),
        identifier: safe_string(Map.get(run, :issue_identifier))
      },
      stage: stage_projection(lifecycle_state, runtime, handoff, landing),
      lifecycle: %{
        state: lifecycle_state,
        sequence: integer_or_nil(Map.get(run, :lifecycle_sequence)),
        updated_at: safe_string(Map.get(run, :updated_at)),
        terminal_at: safe_string(Map.get(run, :terminal_at)),
        blocked_reason: safe_string(Map.get(run, :blocked_reason)),
        retry_attempt: integer_or_nil(Map.get(run, :retry_attempt)),
        retry_due_at_ms: integer_or_nil(Map.get(run, :retry_due_at_ms)),
        reconciliation_status: safe_string(Map.get(run, :reconciliation_status))
      },
      execution: execution_projection(runtime) |> with_source_status(runtime_status),
      lease: %{
        owner_id: safe_string(Map.get(run, :owner_id)),
        fencing_generation: integer_or_nil(Map.get(run, :fencing_generation)),
        expires_at_ms: integer_or_nil(Map.get(run, :lease_expires_at_ms))
      },
      handoff_state: handoff_projection(handoff) |> with_source_status(runtime_status),
      landing_state: landing_projection(landing) |> with_source_status(runtime_status),
      cleanup_state: cleanup_projection(lifecycle_state),
      commands: Enum.map(ControlPlane.operator_action_availability(run), &Map.update!(&1, :action, fn action -> action <> "_run" end))
    }
  end

  defp with_source_status(projection, "current"), do: projection
  defp with_source_status(projection, status), do: Map.put(projection, :status, status)

  defp execution_projection(nil) do
    %{
      status: "not_observed",
      attempt: nil,
      runner: nil,
      workspace: nil,
      worker_host: nil,
      last_activity_at: nil,
      last_event: nil
    }
  end

  defp execution_projection(%{kind: kind, entry: entry}) do
    %{
      status: kind,
      attempt: integer_or_nil(Map.get(entry, :attempt)),
      runner: safe_string(get_in(entry, [:adapter, :kind])),
      workspace: safe_string(Map.get(entry, :workspace_path)),
      worker_host: safe_string(Map.get(entry, :worker_host)),
      last_activity_at:
        iso8601(Map.get(entry, :last_runtime_progress_timestamp)) ||
          iso8601(Map.get(entry, :last_runtime_timestamp)) || iso8601(Map.get(entry, :started_at)),
      last_event: last_event_projection(entry)
    }
  end

  defp last_event_projection(entry) do
    case token(Map.get(entry, :last_runtime_event)) do
      nil -> nil
      event -> %{type: event, at: iso8601(Map.get(entry, :last_runtime_timestamp))}
    end
  end

  defp stage_projection("cleanup_pending", _runtime, _handoff, _landing),
    do: %{name: "cleanup", status: "pending"}

  defp stage_projection("cleaned", _runtime, _handoff, _landing),
    do: %{name: "cleanup", status: "complete"}

  defp stage_projection(_lifecycle, _runtime, _handoff, landing) when is_map(landing),
    do: %{name: "landing", status: token(Map.get(landing, :status)) || "pending"}

  defp stage_projection(_lifecycle, _runtime, handoff, _landing) when is_map(handoff),
    do: %{name: "handoff", status: token(field(handoff, :route)) || "recorded"}

  defp stage_projection(_lifecycle, %{kind: kind}, _handoff, _landing),
    do: %{name: "execution", status: kind}

  defp stage_projection(lifecycle, _runtime, _handoff, _landing),
    do: %{name: "lifecycle", status: lifecycle || "unknown"}

  defp handoff_projection(nil), do: %{status: "not_recorded", route: nil, target_state: nil}

  defp handoff_projection(handoff) do
    %{
      status: "recorded",
      route: token(field(handoff, :route)),
      target_state: safe_string(field(handoff, :target_state))
    }
  end

  defp landing_projection(nil),
    do: %{status: "not_queued", position: nil, reasons: [], wait_ms: nil}

  defp landing_projection(landing) do
    %{
      status: token(Map.get(landing, :status)) || "queued",
      position: integer_or_nil(Map.get(landing, :position)),
      reasons: Enum.map(Map.get(landing, :blocked_reasons, []), &token/1),
      wait_ms: integer_or_nil(Map.get(landing, :wait_ms))
    }
  end

  defp cleanup_projection("cleaned"), do: %{status: "complete"}
  defp cleanup_projection("cleanup_pending"), do: %{status: "pending"}
  defp cleanup_projection("completed"), do: %{status: "not_started"}
  defp cleanup_projection(_state), do: %{status: "not_applicable"}

  defp runtime_entries(runtime_results) do
    Enum.reduce(runtime_results, %{}, fn
      {_target_id, {:current, runtime}}, entries when is_map(runtime) ->
        entries
        |> put_runtime_entries(Map.get(runtime, :running), "running")
        |> put_runtime_entries(Map.get(runtime, :retrying), "retrying")
        |> put_runtime_entries(Map.get(runtime, :blocked), "blocked")

      {_target_id, _result}, entries ->
        entries
    end)
  end

  defp put_runtime_entries(entries, runtime_entries, kind) when is_list(runtime_entries) do
    Enum.reduce(runtime_entries, entries, fn entry, acc ->
      key = {Map.get(entry, :target_id), Map.get(entry, :issue_id)}
      if valid_run_key?(key), do: Map.put(acc, key, %{kind: kind, entry: entry}), else: acc
    end)
  end

  defp put_runtime_entries(entries, _runtime_entries, _kind), do: entries

  defp handoff_entries(runtime_results) do
    reduce_runtime_collection(runtime_results, :handoff_routes, fn target_id, entry ->
      {{target_id, field(entry, :issue_id)}, entry}
    end)
  end

  defp landing_entries(runtime_results) do
    reduce_runtime_collection(runtime_results, :landing_queue, fn target_id, entry ->
      {{target_id, Map.get(entry, :issue_id)}, entry}
    end)
  end

  defp reduce_runtime_collection(runtime_results, key, mapper) do
    Enum.reduce(runtime_results, %{}, fn
      {target_id, {:current, runtime}}, acc when is_map(runtime) ->
        runtime
        |> Map.get(key, [])
        |> Enum.reduce(acc, &put_runtime_collection_entry(&1, &2, target_id, mapper))

      {_target_id, _result}, acc ->
        acc
    end)
  end

  defp put_runtime_collection_entry(entry, entries, target_id, mapper) do
    {entry_key, value} = mapper.(target_id, entry)
    if valid_run_key?(entry_key), do: Map.put(entries, entry_key, value), else: entries
  end

  defp valid_run_key?({target_id, issue_id}), do: is_binary(target_id) and is_binary(issue_id)

  defp aggregate_projection(targets, host) do
    runtime_status = if(Enum.all?(targets, &(&1.runtime.status == "current")), do: "current", else: "partial")
    queue_status = if(Enum.all?(targets, &(&1.queue.status == "current")), do: "current", else: "partial")

    counts = %{
      status: aggregate_status(runtime_status, queue_status),
      queued: sum_target_queue_counts(targets),
      running: sum_target_runtime_count(targets, :running),
      retrying: sum_target_runtime_count(targets, :retrying),
      blocked: sum_target_runtime_count(targets, :blocked)
    }

    %{
      status: counts.status,
      capacity: host_capacity(host),
      counts: counts
    }
  end

  defp sum_target_queue_counts([]), do: 0

  defp sum_target_queue_counts(targets) do
    known = Enum.filter(targets, &(&1.queue.status in ["current", "stale"]))
    if known == [], do: nil, else: Enum.sum(Enum.map(known, &length(&1.queue.entries)))
  end

  defp sum_target_runtime_count([], _key), do: 0

  defp sum_target_runtime_count(targets, key) do
    known = Enum.filter(targets, &is_map(&1.runtime.counts))
    if known == [], do: nil, else: Enum.sum(Enum.map(known, &Map.get(&1.runtime.counts, key, 0)))
  end

  defp warnings(host, runtime_results, durable_runs_result, budgets_result, targets) do
    registry_warnings(host) ++
      source_warnings(runtime_results, durable_runs_result, budgets_result) ++
      queue_warnings(targets)
  end

  defp registry_warnings(host) do
    registry = Map.get(host, :registry, %{})

    if Map.get(registry, :verified?) == true do
      []
    else
      [warning("registry_unverified", "error", "Registry generation is not verified.")]
    end
  end

  defp source_warnings(runtime_results, durable_runs_result, budgets_result) do
    target_warnings =
      runtime_results
      |> Enum.reject(fn {_target_id, result} -> match?({:current, _}, result) end)
      |> Enum.map(fn {target_id, {status, nil}} ->
        warning(
          "target_snapshot_#{source_status(status)}",
          "warning",
          "Target runtime snapshot is #{source_status(status)}.",
          target_id
        )
      end)

    durable_warning =
      case durable_runs_result do
        {:current, _runs} -> []
        {status, nil} -> [warning("control_plane_#{source_status(status)}", "error", "Durable run state is unavailable.")]
      end

    budget_warning =
      case budgets_result do
        {:current, _budgets} -> []
        {status, nil} -> [warning("budgets_#{source_status(status)}", "warning", "Budget usage is unavailable.")]
      end

    target_warnings ++ durable_warning ++ budget_warning
  end

  defp queue_warnings(targets) do
    Enum.flat_map(targets, fn target ->
      case target.queue.status do
        "stale" -> [warning("queue_stale", "warning", "Pending queue state is stale.", target.target_id)]
        "unavailable" -> [warning("queue_unavailable", "warning", "Pending queue state is unavailable.", target.target_id)]
        _current -> []
      end
    end)
  end

  defp warning(code, severity, message, target_id \\ nil) do
    %{
      code: code,
      severity: severity,
      message: Redaction.redact_string(message),
      target_id: safe_string(target_id)
    }
  end

  defp source_statuses(runtime_results, durable_runs_result, budgets_result) do
    %{
      scheduler: "current",
      control_plane: source_result_status(durable_runs_result),
      budgets: source_result_status(budgets_result),
      targets: Map.new(runtime_results, fn {target_id, result} -> {target_id, source_result_status(result)} end)
    }
  end

  defp freshness_status(runtime_results, durable_runs_result, budgets_result, targets) do
    results = Map.values(runtime_results) ++ [durable_runs_result, budgets_result]

    if Enum.all?(results, &match?({:current, _}, &1)) and
         Enum.all?(targets, &(&1.queue.status == "current")),
       do: "live",
       else: "partial"
  end

  defp source_result_status({status, _value}), do: source_status(status)
  defp source_status(:current), do: "current"
  defp source_status(:timeout), do: "timeout"
  defp source_status(:unavailable), do: "unavailable"

  defp aggregate_status("current", "current"), do: "current"
  defp aggregate_status(_runtime, _queue), do: "partial"

  defp slot_projection(values) when is_map(values) do
    Map.new(@slot_keys, fn key -> {key, integer_or_nil(Map.get(values, key))} end)
  end

  defp slot_projection(_values), do: nil

  defp host_limit_projection(values) when is_map(values) do
    %{
      agents: integer_or_nil(Map.get(values, :agents)),
      startups: integer_or_nil(Map.get(values, :startups)),
      reviewers: integer_or_nil(Map.get(values, :reviewers)),
      polls: integer_or_nil(get_in(values, [:polls, :max_concurrent]))
    }
  end

  defp host_limit_projection(_values), do: nil

  defp target_limit_projection(values) when is_map(values) do
    %{
      agents: integer_or_nil(Map.get(values, :agents)),
      startups: integer_or_nil(Map.get(values, :startups)),
      reviewers: integer_or_nil(Map.get(values, :reviewers)),
      polls: nil
    }
  end

  defp target_limit_projection(_values), do: nil

  defp budgets_by_target({:current, budgets}), do: Map.new(budgets, &{Map.get(&1, :target_id), &1})
  defp budgets_by_target({_status, nil}), do: %{}

  defp stale?(nil, _generated_at), do: true

  defp stale?(observed_at, generated_at) do
    case DateTime.from_iso8601(observed_at) do
      {:ok, observed, _offset} -> DateTime.diff(generated_at, observed, :millisecond) > @queue_stale_after_ms
      _invalid -> true
    end
  end

  defp limit_reached?(used, limit) when is_integer(used) and is_integer(limit), do: used >= limit
  defp limit_reached?(_used, _limit), do: false

  defp sum_known(left, right) when is_integer(left) and is_integer(right), do: left + right
  defp sum_known(_left, _right), do: nil

  defp list_count(value) when is_list(value), do: length(value)
  defp list_count(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp integer_or_nil(value) when is_integer(value) and value >= 0, do: value
  defp integer_or_nil(_value), do: nil

  defp token(nil), do: nil
  defp token(value) when is_atom(value), do: Atom.to_string(value)
  defp token(value) when is_binary(value), do: redact_operator_value(value)
  defp token(_value), do: nil

  defp safe_string(value) when is_binary(value), do: redact_operator_value(value)
  defp safe_string(_value), do: nil

  defp redact_operator_value(value), do: Redaction.redact_operator_string(value)

  defp safe_error(nil), do: nil
  defp safe_error(value), do: value |> inspect() |> Redaction.redact_operator_string() |> Redaction.redact_string()

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value) when is_binary(value), do: safe_string(value)
  defp iso8601(_value), do: nil

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
end
