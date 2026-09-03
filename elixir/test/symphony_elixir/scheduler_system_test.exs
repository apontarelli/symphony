defmodule SymphonyElixir.SchedulerSystemTest.TargetDouble do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def set_snapshot(server, snapshot), do: GenServer.call(server, {:set_snapshot, snapshot})

  @impl true
  def init(opts), do: {:ok, %{recipient: Keyword.fetch!(opts, :recipient), snapshot: Keyword.fetch!(opts, :snapshot)}}

  @impl true
  def handle_cast({:dispatch_grant, grant}, state) do
    send(state.recipient, {:scheduler_grant, grant})
    {:noreply, state}
  end

  def handle_cast({:apply_target_context, _context}, state), do: {:noreply, state}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  def handle_call({:set_snapshot, snapshot}, _from, state),
    do: {:reply, :ok, %{state | snapshot: snapshot}}
end

defmodule SymphonyElixir.SchedulerSystemTest.ControlPlaneDouble do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def set_runs(server, runs), do: GenServer.call(server, {:set_runs, runs})

  @impl true
  def init(opts), do: {:ok, %{runs: Keyword.fetch!(opts, :runs), budgets: Keyword.fetch!(opts, :budgets)}}

  @impl true
  def handle_call(:inspect_runs, _from, state), do: {:reply, {:ok, state.runs}, state}
  def handle_call(:inspect_target_budgets, _from, state), do: {:reply, {:ok, state.budgets}, state}

  def handle_call({:set_runs, runs}, _from, state),
    do: {:reply, :ok, %{state | runs: runs}}
end

defmodule SymphonyElixir.SchedulerSystemTest do
  use ExUnit.Case, async: false

  import SymphonyElixir.TestSupport, only: [eventually: 1]

  alias SymphonyElixir.HostScheduler
  alias SymphonyElixir.HostScheduler.Grant
  alias SymphonyElixir.SchedulerSystemTest.{ControlPlaneDouble, TargetDouble}
  alias SymphonyElixir.TargetContext
  alias SymphonyElixirWeb.Presenter

  test "two targets prove fairness, ceilings, budgets, rate limits, pause, drain, cancellation, restart, and lease loss" do
    generation_one = hash("generation-one")
    alpha = target_context("alpha", :active, generation_one, 2, "runner-alpha", "tracker-alpha", true)
    beta = target_context("beta", :active, generation_one, 1, "runner-beta", "tracker-beta", false)

    {:ok, registry} = Agent.start_link(fn -> loaded_registry(alpha, beta, generation_one) end)

    alpha_snapshot = runtime_snapshot(:running, "alpha-session")
    beta_snapshot = runtime_snapshot(:blocked, "beta-session")
    {:ok, alpha_pid} = TargetDouble.start_link(recipient: self(), snapshot: alpha_snapshot)
    {:ok, beta_pid} = TargetDouble.start_link(recipient: self(), snapshot: beta_snapshot)

    runs = [
      durable_run("alpha-run", "alpha", "running", nil),
      durable_run("beta-run", "beta", "blocked", "operator_cancelled")
    ]

    budgets = [
      %{
        target_id: "alpha",
        reserved_tokens: 10,
        daily_reserved_tokens: 10,
        weekly_reserved_tokens: 10,
        charged_tokens: 90,
        daily_charged_tokens: 90,
        weekly_charged_tokens: 90,
        daily_limit: 100,
        weekly_limit: 100
      }
    ]

    {:ok, control_plane} = ControlPlaneDouble.start_link(runs: runs, budgets: budgets)
    scheduler = unique_name(HostScheduler)

    start_supervised!(
      {HostScheduler,
       name: scheduler, registry_path: "/deterministic/sid-444.yml", registry_loader: fn _path -> Agent.get(registry, &{:ok, &1}) end, registry_reload_interval_ms: 10, target_supervisor: false}
    )

    HostScheduler.register_target(scheduler, alpha, alpha_pid)
    HostScheduler.register_target(scheduler, beta, beta_pid)

    first = receive_grant()
    assert first.target_id == "alpha"
    assert :ok = HostScheduler.reserve_dispatch(first)
    assert :ok = HostScheduler.finish_poll(first, true)

    second = receive_grant()
    assert second.target_id == "beta"
    assert {:error, :capacity} = HostScheduler.reserve_dispatch(second)
    assert :ok = HostScheduler.release_dispatch(first)
    assert :ok = HostScheduler.finish_poll(second, true)

    grants = collect_fairness_grants([first.target_id, second.target_id], scheduler, 4)
    assert Enum.frequencies(grants) == %{"alpha" => 4, "beta" => 2}

    defer_alpha_grant(scheduler)

    payload = Presenter.host_state_payload(scheduler, control_plane, 1_000)
    alpha_status = Enum.find(payload.scheduler.targets, &(&1.target_id == "alpha"))
    beta_status = Enum.find(payload.scheduler.targets, &(&1.target_id == "beta"))

    assert alpha_status.effective_state == :limited
    assert alpha_status.eligibility_reason == :tracker_backoff
    assert alpha_status.scheduling.weight == 2
    assert alpha_status.budget.exhausted
    assert alpha_status.counts.running == 1
    assert beta_status.scheduling.weight == 1
    assert beta_status.counts.blocked == 1

    assert [%{target_id: "alpha", admitted_run_id: "alpha-run", issue_identifier: "SID-DUP"}] =
             payload.running

    assert [%{target_id: "beta", admitted_run_id: "beta-run", issue_identifier: "SID-DUP"}] =
             payload.blocked

    assert {:error, :ambiguous_issue} =
             Presenter.host_issue_payload(
               "SID-DUP",
               nil,
               scheduler,
               control_plane,
               1_000
             )

    assert {:ok, %{target_id: "alpha", admitted_run_id: "alpha-run", status: "running"}} =
             Presenter.host_issue_payload(
               "SID-DUP",
               "alpha",
               scheduler,
               control_plane,
               1_000
             )

    projection = inspect(payload)
    refute projection =~ "alpha-credential"
    refute projection =~ "beta-credential"
    refute projection =~ "raw-policy"
    refute projection =~ "transition-proof"
    refute projection =~ "prompt-secret"

    generation_two = hash("generation-two")
    paused_alpha = %{alpha | state: :paused, registry_generation: generation_two}
    draining_beta = %{beta | state: :draining, registry_generation: generation_two}
    Agent.update(registry, fn _ -> loaded_registry(paused_alpha, draining_beta, generation_two) end)

    assert eventually(fn ->
             case HostScheduler.snapshot(scheduler).targets do
               %{
                 "alpha" => %{configured_state: :paused, effective_state: :paused},
                 "beta" => %{configured_state: :draining, effective_state: :draining}
               } ->
                 true

               _other ->
                 false
             end
           end)

    assert %{coalesced: true} = HostScheduler.request_poll(scheduler, "alpha")
    HostScheduler.register_target(scheduler, draining_beta, beta_pid)
    assert %{queued: true} = HostScheduler.request_retry(scheduler, "beta")
    draining_grant = receive_grant()
    assert draining_grant.target_id == "beta"

    generation_three = hash("generation-three")
    restarted_beta = %{beta | registry_generation: generation_three}
    Agent.update(registry, fn _ -> loaded_registry(paused_alpha, restarted_beta, generation_three) end)

    assert eventually(fn ->
             HostScheduler.snapshot(scheduler).registry.generation == generation_three
           end)

    assert {:error, :stale_grant} = HostScheduler.reserve_dispatch(draining_grant)
    assert :ok = HostScheduler.finish_poll(draining_grant, false)

    {:ok, restarted_beta_pid} = TargetDouble.start_link(recipient: self(), snapshot: beta_snapshot)
    HostScheduler.register_target(scheduler, restarted_beta, restarted_beta_pid)
    restart_grant = receive_grant()
    assert restart_grant.target_id == "beta"
    assert :ok = HostScheduler.finish_poll(restart_grant, false)

    :ok =
      ControlPlaneDouble.set_runs(control_plane, [
        durable_run("alpha-run", "alpha", "blocked", "lease_lost"),
        durable_run("beta-run", "beta", "blocked", "operator_cancelled")
      ])

    final_payload = Presenter.host_state_payload(scheduler, control_plane, 1_000)
    final_runs = Enum.flat_map(final_payload.scheduler.targets, & &1.runs)

    assert Enum.any?(final_runs, &(&1.admitted_run_id == "alpha-run" and &1.blocked_reason == "lease_lost"))
    assert Enum.any?(final_runs, &(&1.admitted_run_id == "beta-run" and &1.blocked_reason == "operator_cancelled"))
  end

  defp collect_fairness_grants(grants, _scheduler, 0), do: grants

  defp collect_fairness_grants(grants, scheduler, remaining) do
    grant = receive_grant()
    assert :ok = HostScheduler.finish_poll(grant, true)
    collect_fairness_grants(grants ++ [grant.target_id], scheduler, remaining - 1)
  end

  defp defer_alpha_grant(scheduler) do
    grant = receive_grant()

    if grant.target_id == "alpha" do
      assert :ok = HostScheduler.finish_poll(grant, {:defer, 5_000})
    else
      assert :ok = HostScheduler.finish_poll(grant, true)
      defer_alpha_grant(scheduler)
    end
  end

  defp receive_grant do
    assert_receive {:scheduler_grant, %Grant{} = grant}, 1_000
    grant
  end

  defp loaded_registry(alpha, beta, generation) do
    %{
      snapshot: %{
        generation: generation,
        host: %{
          "polling" => %{"interval_ms" => 1, "max_concurrent_target_polls" => 1},
          "capacity" => %{
            "max_concurrent_agents" => 1,
            "max_concurrent_startups" => 1,
            "max_concurrent_reviewers" => 1
          },
          "scheduling" => %{
            "algorithm" => "weighted_deficit_round_robin",
            "max_credit_rounds" => 4
          }
        }
      },
      contexts: %{"alpha" => alpha, "beta" => beta},
      weights: [{"alpha", 2}, {"beta", 1}]
    }
  end

  defp target_context(target_id, state, generation, _weight, runner_id, tracker_id, budget?) do
    budget_limits =
      if budget?,
        do: %{
          "per_run" => %{"max_total_tokens" => 100},
          "daily" => %{"max_total_tokens" => 100},
          "weekly" => %{"max_total_tokens" => 100}
        },
        else: %{}

    struct!(TargetContext,
      target_id: target_id,
      state: state,
      dispatch_mode: :watch,
      registry_generation: generation,
      policy_hash: hash("policy-#{target_id}"),
      repo_manifest_hash: hash("manifest-#{target_id}"),
      repo_policy: %{"raw-policy" => "#{target_id}-credential"},
      tracker_connection: %{"id" => tracker_id, "secret_ref" => "secret://tracker/#{target_id}"},
      run_target: %{"scope" => %{"type" => "team", "id" => target_id}},
      worktree_policy: %{"root" => "/tmp/#{target_id}"},
      runner_policy: %{"default" => runner_id},
      effective_checks: %{"validation" => ["test-#{target_id}"]},
      external_side_effect_gates: %{},
      capacity_limits: %{
        "max_concurrent_agents" => 1,
        "max_concurrent_startups" => 1,
        "max_concurrent_reviewers" => 1,
        "poll_interval_ms" => 1
      },
      budget_limits: budget_limits
    )
  end

  defp runtime_snapshot(state, session_id) do
    base = %{
      issue_id: "shared-issue-id",
      identifier: "SID-DUP",
      issue_url: "https://linear.example/SID-DUP",
      state: "In Progress",
      worker_host: nil,
      workspace_path: nil,
      profile: "default",
      target: "Merging",
      policy_ref: "safe-policy-ref",
      policy: %{"prompt" => "prompt-secret"},
      session_id: session_id,
      last_runtime_timestamp: nil,
      last_runtime_message: nil,
      last_runtime_event: nil
    }

    {running, blocked} =
      case state do
        :running ->
          {[
             Map.merge(base, %{
               startup: false,
               adapter: nil,
               turn_count: 1,
               started_at: DateTime.utc_now(),
               runtime_input_tokens: 1,
               runtime_output_tokens: 2,
               runtime_total_tokens: 3,
               last_runtime_progress_timestamp: nil,
               last_runtime_error_signature: nil
             })
           ], []}

        :blocked ->
          {[],
           [
             Map.merge(base, %{
               error: "lease_lost",
               transition_evidence: "transition-proof",
               blocked_at: DateTime.utc_now()
             })
           ]}
      end

    %{
      running: running,
      retrying: [],
      blocked: blocked,
      handoff_routes: [],
      runtime_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 1},
      rate_limits: nil,
      tracker: %{limited?: false, rate_limit: nil}
    }
  end

  defp durable_run(admitted_run_id, target_id, state, blocked_reason) do
    %{
      admitted_run_id: admitted_run_id,
      target_id: target_id,
      tracker_issue_id: "shared-issue-id",
      issue_identifier: "SID-DUP",
      lifecycle_state: state,
      lifecycle_sequence: 1,
      owner_id: nil,
      lease_expires_at_ms: nil,
      fencing_generation: 1,
      retry_attempt: nil,
      retry_due_at_ms: nil,
      blocked_reason: blocked_reason,
      reconciliation_status: "clear",
      terminal_at: nil,
      updated_at: "2026-08-28T00:00:00Z"
    }
  end

  defp hash(value), do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  defp unique_name(suffix), do: Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
end
