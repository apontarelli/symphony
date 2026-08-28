defmodule SymphonyElixir.SchedulerStatus do
  @moduledoc """
  Builds the credential-safe scheduler projection used by the API, dashboard,
  and scheduler status logs.
  """

  require Logger

  @slot_keys [:agents, :startups, :reviewers, :polls]

  @spec project(map(), %{optional(String.t()) => map()}, [map()], [map()]) :: map()
  def project(host_snapshot, runtime_snapshots, durable_runs, budget_snapshots)
      when is_map(host_snapshot) and is_map(runtime_snapshots) and is_list(durable_runs) and
             is_list(budget_snapshots) do
    budgets_by_target = Map.new(budget_snapshots, &{&1.target_id, &1})
    runs_by_target = group_observable_runs(durable_runs)

    targets =
      host_snapshot
      |> Map.get(:targets, %{})
      |> Enum.map(fn {target_id, target} ->
        target_projection(
          target_id,
          target,
          Map.get(runtime_snapshots, target_id, %{}),
          Map.get(runs_by_target, target_id, []),
          Map.get(budgets_by_target, target_id)
        )
      end)
      |> Enum.sort_by(& &1.target_id)

    projection = %{
      counts: sum_runtime_counts(targets),
      host: %{
        queue_count: Enum.sum(Enum.map(targets, & &1.queue_count)),
        capacity: %{
          used: slot_projection(Map.get(host_snapshot, :counts, %{})),
          limits: host_limit_projection(Map.get(host_snapshot, :limits, %{}))
        }
      },
      targets: targets
    }

    log_projection(projection)
    projection
  end

  defp target_projection(target_id, target, runtime, durable_runs, budget_usage) do
    %{
      target_id: target_id,
      configured_state: Map.get(target, :configured_state, :unavailable),
      effective_state: Map.get(target, :effective_state, :unavailable),
      eligibility_reason: Map.get(target, :eligibility_reason, :target_process_unavailable),
      queue_count: Map.get(target, :queue_count, 0),
      scheduling: scheduling_projection(Map.get(target, :scheduling, %{})),
      capacity: %{
        used: slot_projection(Map.get(target, :counts, %{})),
        limits: target_limit_projection(Map.get(target, :limits, %{}))
      },
      budget: budget_projection(Map.get(target, :budget_limits), budget_usage),
      tracker_backoff: tracker_backoff_projection(Map.get(target, :tracker_backoff, %{})),
      counts: runtime_counts(runtime),
      runs: Enum.map(durable_runs, &run_identity_projection/1)
    }
  end

  defp scheduling_projection(scheduling) do
    %{
      weight: non_negative_integer(Map.get(scheduling, :weight)),
      deficit: non_negative_integer(Map.get(scheduling, :deficit))
    }
  end

  defp slot_projection(values) do
    Map.new(@slot_keys, &{&1, non_negative_integer(Map.get(values, &1))})
  end

  defp host_limit_projection(limits) do
    %{
      agents: non_negative_integer(Map.get(limits, :agents)),
      startups: non_negative_integer(Map.get(limits, :startups)),
      reviewers: non_negative_integer(Map.get(limits, :reviewers)),
      polls: non_negative_integer(get_in(limits, [:polls, :max_concurrent]))
    }
  end

  defp target_limit_projection(limits) do
    %{
      agents: non_negative_integer(Map.get(limits, :agents)),
      startups: non_negative_integer(Map.get(limits, :startups)),
      reviewers: non_negative_integer(Map.get(limits, :reviewers))
    }
  end

  defp budget_projection(nil, _usage) do
    %{
      configured: false,
      exhausted: false,
      reserved_tokens: 0,
      daily_reserved_tokens: 0,
      weekly_reserved_tokens: 0,
      charged_tokens: 0,
      daily_charged_tokens: 0,
      weekly_charged_tokens: 0,
      limits: nil
    }
  end

  defp budget_projection(limits, usage) do
    usage = usage || %{}
    reserved = non_negative_integer(Map.get(usage, :reserved_tokens))
    daily_reserved = non_negative_integer(Map.get(usage, :daily_reserved_tokens))
    weekly_reserved = non_negative_integer(Map.get(usage, :weekly_reserved_tokens))
    charged = non_negative_integer(Map.get(usage, :charged_tokens))
    daily_charged = non_negative_integer(Map.get(usage, :daily_charged_tokens))
    weekly_charged = non_negative_integer(Map.get(usage, :weekly_charged_tokens))
    daily_limit = non_negative_integer(Map.get(limits, :daily_tokens))
    weekly_limit = non_negative_integer(Map.get(limits, :weekly_tokens))

    %{
      configured: true,
      exhausted:
        daily_charged + daily_reserved >= daily_limit or
          weekly_charged + weekly_reserved >= weekly_limit,
      reserved_tokens: reserved,
      daily_reserved_tokens: daily_reserved,
      weekly_reserved_tokens: weekly_reserved,
      charged_tokens: charged,
      daily_charged_tokens: daily_charged,
      weekly_charged_tokens: weekly_charged,
      limits: %{
        per_run_tokens: non_negative_integer(Map.get(limits, :per_run_tokens)),
        daily_tokens: daily_limit,
        weekly_tokens: weekly_limit
      }
    }
  end

  defp tracker_backoff_projection(backoff) do
    %{
      active: Map.get(backoff, :active) == true,
      remaining_ms: optional_non_negative_integer(Map.get(backoff, :remaining_ms))
    }
  end

  defp runtime_counts(runtime) do
    %{
      running: runtime |> Map.get(:running, []) |> length(),
      retrying: runtime |> Map.get(:retrying, []) |> length(),
      blocked: runtime |> Map.get(:blocked, []) |> length()
    }
  end

  defp sum_runtime_counts(targets) do
    Enum.reduce(targets, %{running: 0, retrying: 0, blocked: 0}, fn target, counts ->
      %{
        running: counts.running + target.counts.running,
        retrying: counts.retrying + target.counts.retrying,
        blocked: counts.blocked + target.counts.blocked
      }
    end)
  end

  defp group_observable_runs(durable_runs) do
    durable_runs
    |> Enum.reduce(%{}, fn run, runs_by_target ->
      if Map.get(run, :lifecycle_state) in ["completed", "cleaned"] do
        runs_by_target
      else
        Map.update(
          runs_by_target,
          Map.get(run, :target_id),
          [run],
          &[run | &1]
        )
      end
    end)
    |> Map.new(fn {target_id, runs} -> {target_id, Enum.reverse(runs)} end)
  end

  defp run_identity_projection(run) do
    %{
      admitted_run_id: Map.get(run, :admitted_run_id),
      target_id: Map.get(run, :target_id),
      issue_id: Map.get(run, :tracker_issue_id),
      issue_identifier: Map.get(run, :issue_identifier),
      state: Map.get(run, :lifecycle_state),
      blocked_reason: Map.get(run, :blocked_reason)
    }
  end

  defp log_projection(%{host: host, targets: targets}) do
    Logger.info(
      "Scheduler host status queue_count=#{host.queue_count} " <>
        "capacity_used=#{format_slots(host.capacity.used)} " <>
        "capacity_limits=#{format_slots(host.capacity.limits)}"
    )

    Enum.each(targets, fn target ->
      Logger.info(
        "Scheduler target status target_id=#{target.target_id} " <>
          "configured_state=#{target.configured_state} effective_state=#{target.effective_state} " <>
          "eligibility_reason=#{target.eligibility_reason} queue_count=#{target.queue_count} " <>
          "weight=#{target.scheduling.weight} deficit=#{target.scheduling.deficit} " <>
          "capacity_used=#{format_slots(target.capacity.used)} " <>
          "capacity_limits=#{format_slots(target.capacity.limits)} " <>
          "budget_reserved_tokens=#{target.budget.reserved_tokens} " <>
          "budget_daily_reserved_tokens=#{target.budget.daily_reserved_tokens} " <>
          "budget_weekly_reserved_tokens=#{target.budget.weekly_reserved_tokens} " <>
          "budget_charged_tokens=#{target.budget.charged_tokens} " <>
          "budget_daily_charged_tokens=#{target.budget.daily_charged_tokens} " <>
          "budget_weekly_charged_tokens=#{target.budget.weekly_charged_tokens} " <>
          "budget_exhausted=#{target.budget.exhausted} " <>
          "tracker_backoff_ms=#{target.tracker_backoff.remaining_ms || 0} " <>
          "running=#{target.counts.running} retrying=#{target.counts.retrying} " <>
          "blocked=#{target.counts.blocked} runs=#{format_run_identities(target.runs)}"
      )
    end)
  end

  defp format_slots(slots) do
    Enum.map_join(@slot_keys, ",", &"#{&1}:#{Map.get(slots, &1, 0)}")
  end

  defp format_run_identities([]), do: "none"

  defp format_run_identities(runs) do
    Enum.map_join(runs, ",", fn run ->
      "#{run.target_id}/#{run.issue_identifier}/#{run.admitted_run_id}"
    end)
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp optional_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp optional_non_negative_integer(_value), do: nil
end
