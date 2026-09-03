defmodule SymphonyElixir.RunAuthorityTest.FailingLifecycleControlPlane do
  use GenServer

  @spec start_link(pid()) :: GenServer.on_start()
  def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

  @impl true
  def init(test_pid), do: {:ok, test_pid}

  @impl true
  def handle_call({:acquire_lease, admitted_run_id, owner_id}, _from, test_pid) do
    lease = %{
      admitted_run_id: admitted_run_id,
      owner_id: owner_id,
      fencing_token: 2
    }

    {:reply, {:ok, lease}, test_pid}
  end

  def handle_call({:fetch_lifecycle, _admitted_run_id}, _from, test_pid),
    do: {:reply, {:error, :lifecycle_read_failed}, test_pid}

  def handle_call({:release_lease, lease}, _from, test_pid) do
    send(test_pid, {:released_reacquired_lease, lease})
    {:reply, :ok, test_pid}
  end

  def handle_call({:fetch_token_budget, _admitted_run_id}, _from, test_pid),
    do: {:reply, {:error, :budget_store_failed}, test_pid}
end

defmodule SymphonyElixir.RunAuthorityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime.Event
  alias SymphonyElixir.ControlPlane
  alias SymphonyElixir.ControlPlane.{SideEffect, TokenBudget}
  alias SymphonyElixir.{ExecutionContext, Orchestrator, RunAuthority, RunTarget, TargetContext}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.RunAuthorityTest.FailingLifecycleControlPlane

  test "token budget fetch returns durable store errors" do
    {:ok, server} = FailingLifecycleControlPlane.start_link(self())

    authority = %RunAuthority{
      server: server,
      owner_id: "owner",
      admission: %{admitted_run_id: "run"},
      lease: %{},
      lifecycle: %{}
    }

    assert {:error, :budget_store_failed} = RunAuthority.fetch_token_budget(authority)
  end

  test "owns lifecycle process and side-effect ordering through one fenced lease" do
    config_root = tmp_root!("run-authority")
    server = start_control_plane!(config_root)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-433")

    assert {:ok, admitted} = RunAuthority.admit(server, "owner-a", context)
    assert admitted.lifecycle.state == :admitted
    assert {:ok, ^admitted} = RunAuthority.transition(admitted, :admitted, %{})
    assert {:ok, running} = RunAuthority.transition(admitted, :running, %{})
    assert running.lifecycle.state == :running
    assert {:ok, renewed} = RunAuthority.renew(running)
    assert renewed.lease.deadline_ms >= running.lease.deadline_ms

    identity = process_identity(61_001)
    assert {:ok, registered} = RunAuthority.register_process(renewed, identity)

    operation = fn -> {:ok, %{status: "published"}} end

    assert {:ok, %{status: "published"}, %SideEffect{state: :succeeded} = completed} =
             RunAuthority.run_side_effect(
               registered,
               :publish_handoff,
               "delivery-1",
               %{commit: "abc"},
               operation
             )

    assert {:completed, ^completed} =
             RunAuthority.run_side_effect(
               registered,
               :publish_handoff,
               "delivery-1",
               %{commit: "abc"},
               operation
             )

    assert {:failed, %SideEffect{state: :failed}} =
             RunAuthority.run_side_effect(
               registered,
               :publish_preflight,
               "preflight-1",
               %{},
               fn -> {:failed, %{reason: "not clean"}} end
             )

    assert {:failed, %SideEffect{state: :failed}} =
             RunAuthority.run_side_effect(
               registered,
               :publish_preflight,
               "preflight-1",
               %{},
               fn -> {:failed, %{reason: "not clean"}} end
             )

    assert {:blocked, %SideEffect{state: :reconciliation_required}} =
             RunAuthority.run_side_effect(
               registered,
               :tracker_write,
               "invalid-result",
               %{},
               fn -> :invalid end
             )

    assert {:blocked, %SideEffect{state: :reconciliation_required}} =
             RunAuthority.run_side_effect(
               registered,
               :tracker_write,
               "invalid-result",
               %{},
               fn -> {:ok, %{status: "must not run"}} end
             )

    assert {:blocked, %SideEffect{state: :reconciliation_required}} =
             RunAuthority.run_side_effect(
               registered,
               :tracker_write,
               "raised-result",
               %{},
               fn -> raise "boom" end
             )

    assert {:blocked, %SideEffect{state: :reconciliation_required}} =
             RunAuthority.run_side_effect(
               registered,
               :tracker_write,
               "thrown-result",
               %{},
               fn -> throw(:boom) end
             )

    assert {:ok, stopped} =
             RunAuthority.record_process_stopped(
               registered,
               identity["process_group_id"],
               %{verified_by: "test"}
             )

    assert {:error, :illegal_transition} =
             RunAuthority.transition(stopped, :cleaned, %{})

    assert {:error, :process_ownership_conflict} =
             RunAuthority.register_process(stopped, process_identity(61_002))

    assert {:error, :process_ownership_conflict} =
             RunAuthority.record_process_stopped(
               stopped,
               61_002,
               %{verified_by: "wrong-process"}
             )

    assert {:error, :stale_lease} =
             RunAuthority.run_side_effect(
               stopped,
               :tracker_write,
               "release-before-finish",
               %{},
               fn ->
                 assert :ok = RunAuthority.release(stopped)
                 {:ok, %{status: "released"}}
               end
             )

    assert {:error, :stale_lease} = RunAuthority.renew(stopped)
    assert {:error, :stale_lease} = RunAuthority.register_process(stopped, identity)

    assert {:error, :stale_lease} =
             RunAuthority.record_process_stopped(
               stopped,
               identity["process_group_id"],
               %{verified_by: "stale-owner"}
             )

    assert {:error, :stale_lease} =
             RunAuthority.run_side_effect(
               stopped,
               :tracker_write,
               "stale-write",
               %{},
               operation
             )
  end

  test "unverifiable process ownership blocks without retiring its lease or reservation" do
    config_root = tmp_root!("run-authority-unverifiable")
    server = start_control_plane!(config_root)
    context = execution_context!(config_root, "alpha", "uncertain", "SID-443-U")

    assert {:ok, admitted} = RunAuthority.admit(server, "owner-uncertain", context)
    assert {:ok, running} = RunAuthority.transition(admitted, :running, %{})
    identity = process_identity(61_050)
    assert {:ok, registered} = RunAuthority.register_process(running, identity)

    assert {:ok, blocked} =
             RunAuthority.record_process_unverifiable(
               registered,
               identity["process_group_id"],
               %{verified_by: "sid-443-test"}
             )

    assert blocked.lifecycle.state == :blocked
    assert blocked.lifecycle.blocked_reason == "process group termination is unverifiable"
    assert {:error, :process_termination_unverified} = RunAuthority.release(blocked)
    assert {:ok, renewed} = RunAuthority.renew(blocked)
    assert renewed.lease.fencing_token == blocked.lease.fencing_token
  end

  test "lease loss returns the local slot and fences the old owner" do
    config_root = tmp_root!("run-authority-lease-loss")
    server = start_control_plane!(config_root)
    context = execution_context!(config_root, "alpha", "lease-loss", "SID-443-L")
    run_id = ExecutionContext.run_id(context)

    assert {:ok, admitted} = RunAuthority.admit(server, "owner-lost", context)
    assert {:ok, running} = RunAuthority.transition(admitted, :running, %{})
    assert :ok = RunAuthority.release(running)

    worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(worker), do: send(worker, :stop) end)
    monitor = Process.monitor(worker)

    state = %State{
      control_plane: server,
      coordinator_owner_id: "owner-lost",
      running: %{
        run_id => %{
          pid: worker,
          ref: monitor,
          identifier: context.issue_identifier,
          execution_context: context,
          durable_authority: running
        }
      },
      retry_attempts: %{},
      due_host_retries: %{},
      blocked: %{},
      claimed: MapSet.new([run_id])
    }

    fenced = Orchestrator.renew_durable_leases_for_test(state)

    assert fenced.running == %{}
    assert fenced.claimed == MapSet.new()
    assert %{error: error} = fenced.blocked[run_id]
    assert error =~ "durable lease lost"
    assert Process.alive?(worker)

    assert {:error, :stale_lease} =
             RunAuthority.transition(running, :blocked, %{reason: "old owner mutation"})
  end

  test "pause during unverifiable startup blocks without signaling the task" do
    config_root = tmp_root!("run-authority-pause-startup")
    server = start_control_plane!(config_root)
    context = execution_context!(config_root, "alpha", "startup", "SID-443-S")
    run_id = ExecutionContext.run_id(context)

    assert {:ok, admitted} = RunAuthority.admit(server, "owner-startup", context)
    assert {:ok, running} = RunAuthority.transition(admitted, :running, %{})

    worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(worker), do: send(worker, :stop) end)
    monitor = Process.monitor(worker)

    state = %State{
      target_context: context.target,
      control_plane: server,
      coordinator_owner_id: "owner-startup",
      running: %{
        run_id => %{
          pid: worker,
          ref: monitor,
          identifier: context.issue_identifier,
          execution_context: context,
          durable_authority: running
        }
      },
      retry_attempts: %{},
      due_host_retries: %{},
      blocked: %{},
      claimed: MapSet.new([run_id])
    }

    paused_target = %{
      context.target
      | state: :paused,
        registry_generation: hash("paused-startup")
    }

    assert {:noreply, paused} =
             Orchestrator.handle_cast({:apply_target_context, paused_target}, state)

    assert paused.target_context.state == :paused
    assert %{pause_fenced?: true, ref: nil} = paused.running[run_id]
    assert %{error: "process group termination is unverifiable"} = paused.blocked[run_id]
    assert Process.alive?(worker)

    assert {:ok, %{state: :blocked, blocked_reason: blocked_reason}} =
             ControlPlane.fetch_lifecycle(server, running.admission.admitted_run_id)

    assert blocked_reason == "process group termination is unverifiable"
  end

  test "pause blocks durable retry and activation queues its pinned context first" do
    config_root = tmp_root!("run-authority-pause-retry")
    server = start_control_plane!(config_root)
    context = execution_context!(config_root, "alpha", "retry", "SID-443-R")
    run_id = ExecutionContext.run_id(context)

    assert {:ok, admitted} = RunAuthority.admit(server, "owner-retry", context)
    assert {:ok, running} = RunAuthority.transition(admitted, :running, %{})

    assert {:ok, retrying} =
             RunAuthority.transition(running, :retrying, %{
               attempt: 2,
               due_at_ms: System.system_time(:millisecond) + 60_000,
               failure: %{code: "retry", message: "retry later"}
             })

    retry_token = make_ref()
    timer_ref = Process.send_after(self(), {:retry_issue, run_id, retry_token}, 60_000)

    state = %State{
      target_context: context.target,
      control_plane: server,
      coordinator_owner_id: "owner-retry",
      running: %{},
      retry_attempts: %{
        run_id => %{
          attempt: 2,
          timer_ref: timer_ref,
          retry_token: retry_token,
          identifier: context.issue_identifier,
          execution_context: context,
          durable_authority: retrying
        }
      },
      due_host_retries: %{},
      blocked: %{},
      claimed: MapSet.new([run_id])
    }

    paused_target = %{
      context.target
      | state: :paused,
        registry_generation: hash("paused-retry")
    }

    assert {:noreply, paused} =
             Orchestrator.handle_cast({:apply_target_context, paused_target}, state)

    assert paused.retry_attempts == %{}
    assert paused.claimed == MapSet.new()
    assert %{error: "target_paused"} = paused.blocked[run_id]

    reactivated_target = %{
      context.target
      | registry_generation: hash("reactivated-retry")
    }

    assert {:noreply, reactivated} =
             Orchestrator.handle_cast(
               {:apply_target_context, reactivated_target},
               paused
             )

    assert reactivated.blocked == %{}

    assert %{execution_context: ^context, durable_authority: resumed_authority} =
             reactivated.retry_attempts[run_id]

    assert resumed_authority.admission.context == context
    assert Map.has_key?(reactivated.due_host_retries, run_id)
  end

  test "restart restores a paused admission for active-target resume" do
    config_root = tmp_root!("run-authority-pause-restart")
    server = start_control_plane!(config_root)
    context = execution_context!(config_root, "alpha", "restart", "SID-443-P")
    run_id = ExecutionContext.run_id(context)

    assert {:ok, admitted} = RunAuthority.admit(server, "owner-before-restart", context)
    assert {:ok, running} = RunAuthority.transition(admitted, :running, %{})
    identity = process_identity(61_150)
    assert {:ok, registered} = RunAuthority.register_process(running, identity)

    assert {:ok, stopped} =
             RunAuthority.record_process_stopped(
               registered,
               identity["process_group_id"],
               %{verified_by: "pause-restart-test"}
             )

    assert {:ok, paused} =
             RunAuthority.transition(stopped, :blocked, %{reason: "target_paused"})

    assert :ok = RunAuthority.release(paused)
    stop_process(server)
    reopened = start_control_plane!(config_root)

    assert {:ok, [%{action: :blocked, authority: recovered} = recovery]} =
             RunAuthority.recover(reopened, "owner-after-restart", target_id: "alpha")

    assert recovered.lifecycle.blocked_reason == "target_paused"

    state = %State{
      target_context: context.target,
      control_plane: reopened,
      coordinator_owner_id: "owner-after-restart",
      running: %{},
      retry_attempts: %{},
      due_host_retries: %{},
      blocked: %{},
      claimed: MapSet.new()
    }

    integrated = Orchestrator.integrate_durable_recovery_for_test(recovery, state)
    assert Map.has_key?(integrated.blocked, run_id)

    active_target = %{
      context.target
      | registry_generation: hash("restart-active")
    }

    assert {:noreply, resumed} =
             Orchestrator.handle_cast(
               {:apply_target_context, active_target},
               integrated
             )

    assert resumed.blocked == %{}
    assert Map.has_key?(resumed.retry_attempts, run_id)
    assert Map.has_key?(resumed.due_host_retries, run_id)
  end

  test "owns fenced token usage pause release and reactivation" do
    config_root = tmp_root!("run-authority-token-budget")
    server = start_control_plane!(config_root)

    context =
      execution_context!(config_root, "alpha", "issue-budget", "SID-440",
        budget_limits: %{
          "per_run" => %{"max_total_tokens" => 100},
          "daily" => %{"max_total_tokens" => 500},
          "weekly" => %{"max_total_tokens" => 1_000}
        }
      )

    assert {:ok, admitted} = RunAuthority.admit(server, "owner-budget", context)
    assert {:ok, running} = RunAuthority.transition(admitted, :running, %{})

    assert {:ok, ^running, %TokenBudget{charged_tokens: 25, reserved_tokens: 75}} =
             RunAuthority.record_token_usage(running, 25)

    assert {:ok, %TokenBudget{cumulative_tokens: 25}} =
             RunAuthority.fetch_token_budget(running)

    assert {:error, :process_termination_unverified} =
             RunAuthority.release_token_reservation(running)

    identity = process_identity(61_101)
    assert {:ok, registered} = RunAuthority.register_process(running, identity)

    assert {:ok, stopped} =
             RunAuthority.record_process_stopped(
               registered,
               identity["process_group_id"],
               %{verified_by: "budget-test"}
             )

    assert {:ok, ^stopped, %TokenBudget{state: :released, reserved_tokens: 0}} =
             RunAuthority.release_token_reservation(stopped)

    assert {:ok, ^stopped, %TokenBudget{state: :active, reserved_tokens: 75}} =
             RunAuthority.acquire_token_reservation(stopped)

    assert {:ok, paused} =
             RunAuthority.transition(stopped, :blocked, %{reason: "target_paused"})

    assert :ok = RunAuthority.release(paused)

    assert {:ok, %TokenBudget{state: :released, reserved_tokens: 0}} =
             RunAuthority.fetch_token_budget(paused)

    assert {:ok, reactivated} = RunAuthority.reacquire(paused, "owner-reactivated")
    assert reactivated.lease.fencing_token > paused.lease.fencing_token

    assert {:ok, %TokenBudget{state: :active, reserved_tokens: 75}} =
             RunAuthority.fetch_token_budget(reactivated)

    assert {:ok, resumed} = RunAuthority.transition(reactivated, :running, %{})
    assert resumed.lifecycle.blocked_reason == nil
    assert {:error, :stale_lease} = RunAuthority.record_token_usage(paused, 30)
    assert {:error, :stale_lease} = RunAuthority.acquire_token_reservation(paused)
  end

  test "OMP cumulative events advance the durable budget once" do
    config_root = tmp_root!("run-authority-omp-token-usage")
    server = start_control_plane!(config_root)

    context =
      execution_context!(config_root, "alpha", "issue-omp-budget", "SID-466",
        budget_limits: %{
          "per_run" => %{"max_total_tokens" => 1_000},
          "daily" => %{"max_total_tokens" => 5_000},
          "weekly" => %{"max_total_tokens" => 10_000}
        }
      )

    assert {:ok, admitted} = RunAuthority.admit(server, "owner-omp-budget", context)
    assert {:ok, authority} = RunAuthority.transition(admitted, :running, %{})

    issue = %Issue{
      id: context.issue_id,
      identifier: context.issue_identifier,
      state: "In Progress"
    }

    run_id = ExecutionContext.run_id(context)

    running_entry = %{
      codex_app_server_pid: nil,
      durable_authority: authority,
      durable_token_usage_baseline: 0,
      execution_context: context,
      host_grant: nil,
      identifier: issue.identifier,
      issue: issue,
      last_runtime_error_signature: nil,
      last_runtime_progress_timestamp: nil,
      runtime_input_tokens: 0,
      runtime_last_reported_input_tokens: 0,
      runtime_last_reported_output_tokens: 0,
      runtime_last_reported_total_tokens: 0,
      runtime_output_tokens: 0,
      runtime_token_usage: %{status: :supported},
      runtime_total_tokens: 0,
      session_id: "omp-session",
      startup_slot?: false,
      turn_count: 0
    }

    state = %State{
      running: %{run_id => running_entry},
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      runtime_rate_limits: nil
    }

    event = %Event{
      event: :turn_progress,
      payload: %{kind: :usage},
      runtime: :omp_acp,
      session_id: "omp-session",
      timestamp: DateTime.utc_now(),
      usage: %{"input_tokens" => 6, "output_tokens" => 7, "total_tokens" => 864}
    }

    assert {:noreply, first} = Orchestrator.handle_info({:runtime_event, run_id, event}, state)
    assert first.runtime_totals == %{input_tokens: 6, output_tokens: 7, total_tokens: 864, seconds_running: 0}
    assert first.running[run_id].runtime_total_tokens == 864

    assert {:ok, %TokenBudget{cumulative_tokens: 864, charged_tokens: 864}} =
             RunAuthority.fetch_token_budget(authority)

    assert {:noreply, repeated} =
             Orchestrator.handle_info({:runtime_event, run_id, event}, first)

    assert repeated.runtime_totals == first.runtime_totals
    assert repeated.running[run_id].runtime_total_tokens == 864

    assert {:ok, %TokenBudget{cumulative_tokens: 864, charged_tokens: 864}} =
             RunAuthority.fetch_token_budget(authority)
  end

  test "failed paused resume releases its newly acquired lease" do
    config_root = tmp_root!("run-authority-resume-budget")
    server = start_control_plane!(config_root)

    budget_limits = %{
      "per_run" => %{"max_total_tokens" => 100},
      "daily" => %{"max_total_tokens" => 100},
      "weekly" => %{"max_total_tokens" => 100}
    }

    paused_context =
      execution_context!(config_root, "alpha", "paused-budget", "SID-443-B1", budget_limits: budget_limits)

    assert {:ok, admitted} = RunAuthority.admit(server, "owner-paused", paused_context)
    assert {:ok, running} = RunAuthority.transition(admitted, :running, %{})
    identity = process_identity(61_102)
    assert {:ok, registered} = RunAuthority.register_process(running, identity)

    assert {:ok, stopped} =
             RunAuthority.record_process_stopped(
               registered,
               identity["process_group_id"],
               %{verified_by: "resume-budget-test"}
             )

    assert {:ok, paused} =
             RunAuthority.transition(stopped, :blocked, %{reason: "target_paused"})

    assert :ok = RunAuthority.release(paused)
    assert {:error, :invalid_owner} = RunAuthority.reacquire(paused, nil)

    competing_context =
      execution_context!(config_root, "alpha", "competing-budget", "SID-443-B2", budget_limits: budget_limits)

    assert {:ok, competing} =
             RunAuthority.admit(server, "owner-competing", competing_context)

    assert {:error, :daily_token_budget_exceeded} =
             RunAuthority.reacquire(paused, "owner-resume-failed")

    assert :ok = RunAuthority.release(competing)
    assert {:ok, resumed} = RunAuthority.reacquire(paused, "owner-resume-retried")
    assert resumed.lease.fencing_token > paused.lease.fencing_token
  end

  test "paused resume releases its lease when lifecycle loading fails" do
    server =
      start_supervised!({SymphonyElixir.RunAuthorityTest.FailingLifecycleControlPlane, self()})

    authority = %RunAuthority{
      server: server,
      owner_id: "owner-before-resume",
      admission: %{admitted_run_id: "admitted-run"},
      lease: %{fencing_token: 1},
      lifecycle: %{state: :blocked, blocked_reason: "target_paused"}
    }

    assert {:error, :lifecycle_read_failed} =
             RunAuthority.reacquire(authority, "owner-after-resume")

    assert_receive {:released_reacquired_lease,
                    %{
                      admitted_run_id: "admitted-run",
                      owner_id: "owner-after-resume",
                      fencing_token: 2
                    }}
  end

  test "replays the persisted completion result without changing a block to a pass" do
    config_root = tmp_root!("run-authority-completion-replay")
    server = start_control_plane!(config_root)

    context = execution_context!(config_root, "alpha", "issue-replay", "SID-433-REPLAY")

    assert {:ok, admitted} = RunAuthority.admit(server, "owner-replay", context)
    assert {:ok, running} = RunAuthority.transition(admitted, :running, %{})
    assert {:ok, provenance} = ExecutionContext.safe_provenance(context)

    blocked_result = %{
      status: :blocked,
      attempted: false,
      provenance: provenance,
      capabilities: %{
        workspace_vcs_metadata: true,
        remote_push: false,
        pr_creation: true
      },
      failures: [
        %{
          class: :remote_push_unavailable,
          reason: :github_publish_unavailable,
          summary: "Remote push is unavailable."
        }
      ]
    }

    assert {:ok, ^blocked_result, %SideEffect{} = effect} =
             RunAuthority.run_side_effect(
               running,
               :publish_preflight,
               "run-completion",
               %{issue_identifier: context.issue_identifier},
               fn -> {:ok, blocked_result} end
             )

    assert {:completed, ^effect} =
             RunAuthority.run_side_effect(
               running,
               :publish_preflight,
               "run-completion",
               %{issue_identifier: context.issue_identifier},
               fn -> flunk("completed side effect must not run again") end
             )

    replayed = Orchestrator.fenced_external_result_for_test(effect)

    assert replayed.status == :blocked
    assert replayed.attempted == false
    assert replayed.provenance == provenance
    assert replayed.durable_replay == :completed
    assert replayed.artifact_path == effect.artifact_path
  end

  test "retains the pinned context for a recovery blocked by missing credentials" do
    config_root = tmp_root!("run-authority-blocked-recovery")
    server = start_control_plane!(config_root)

    context =
      execution_context!(
        config_root,
        "alpha",
        "shared-issue",
        "SID-433-BLOCKED",
        tracker_key: "$MISSING_RECOVERY_TRACKER_KEY"
      )

    assert {:ok, admitted} = RunAuthority.admit(server, "owner-old", context)
    assert {:ok, running} = RunAuthority.transition(admitted, :running, %{})
    assert {:ok, _registered} = RunAuthority.register_process(running, process_identity(62_101))
    stop_process(server)
    reopened = start_control_plane!(config_root)

    assert {:ok, [%{action: :blocked, execution_context: nil} = recovery]} =
             RunAuthority.recover(reopened, "owner-new",
               process_terminator: fn _ownership ->
                 {:stopped, %{verified_by: "test"}}
               end,
               env_fetcher: fn "MISSING_RECOVERY_TRACKER_KEY" -> :error end
             )

    state = %State{control_plane: reopened, coordinator_owner_id: "owner-new"}
    integrated = Orchestrator.integrate_durable_recovery_for_test(recovery, state)
    run_id = ExecutionContext.run_id(context)

    assert %{
             execution_context: pinned_context,
             durable_authority: %RunAuthority{},
             error: "recovery credentials are missing"
           } = integrated.blocked[run_id]

    assert pinned_context == recovery.authority.admission.context
    assert pinned_context.target.target_id == "alpha"
    assert MapSet.member?(integrated.claimed, run_id)
  end

  test "recovers an empty store through the default options interface" do
    server = start_control_plane!(tmp_root!("run-authority-empty-recovery"))
    assert {:ok, []} = RunAuthority.recover(server, "owner-empty")
  end

  test "recovers interrupted work into a new authority without exposing credentials" do
    config_root = tmp_root!("run-authority-recovery")
    server = start_control_plane!(config_root)

    context =
      execution_context!(config_root, "alpha", "issue-1", "SID-433-R", tracker_key: "$RECOVERY_TRACKER_KEY")

    assert {:ok, admitted} = RunAuthority.admit(server, "owner-old", context)
    assert {:ok, running} = RunAuthority.transition(admitted, :running, %{})
    assert {:ok, _registered} = RunAuthority.register_process(running, process_identity(62_001))
    stop_process(server)
    reopened = start_control_plane!(config_root)

    assert {:ok,
            [
              %{
                action: :retry,
                authority: recovered,
                execution_context: recovered_context,
                blocked_reason: nil
              }
            ]} =
             RunAuthority.recover(reopened, "owner-new",
               process_terminator: fn _ownership ->
                 {:stopped, %{verified_by: "test"}}
               end,
               env_fetcher: fn "RECOVERY_TRACKER_KEY" -> {:ok, "rotated-secret"} end
             )

    assert recovered.lifecycle.state == :retrying
    assert recovered.lease.fencing_token > running.lease.fencing_token
    assert recovered_context.target.target_id == "alpha"
    refute inspect(recovered_context) =~ "rotated-secret"
  end

  test "landing selection uses retained publish evidence and persists its decision" do
    config_root = tmp_root!("landing-queue-evidence")
    server = start_control_plane!(config_root)
    context = execution_context!(config_root, "alpha", "issue-landing", "SID-462-A")

    assert {:ok, admitted} = RunAuthority.admit(server, "landing-owner", context)
    assert {:ok, running} = RunAuthority.transition(admitted, :running, %{})

    publish_outcome = %{
      pr_url: "https://github.com/example/repo/pull/462",
      github_repository: "example/repo",
      base_branch: "main",
      branch: "ticket/sid-462-a",
      changed_files: ["lib/landing.ex"]
    }

    assert {:ok, ^publish_outcome, %SideEffect{state: :succeeded}} =
             RunAuthority.run_side_effect(
               running,
               :publish_handoff,
               "run-completion",
               %{issue_identifier: "SID-462-A"},
               fn -> {:ok, publish_outcome} end
             )

    assert {:ok, retrying} =
             RunAuthority.transition(running, :retrying, %{
               attempt: 1,
               due_at_ms: System.system_time(:millisecond) + 1_000,
               failure: %{code: "continuation", message: "checking landing queue"}
             })

    issue = %Issue{
      id: "issue-landing",
      identifier: "SID-462-A",
      title: "Land retained change",
      state: "Merging",
      priority: 2,
      assigned_to_worker: true,
      created_at: ~U[2026-09-03 10:00:00Z],
      updated_at: ~U[2026-09-03 11:00:00Z]
    }

    revalidator = fn entry ->
      assert entry.pr_url == publish_outcome.pr_url
      assert entry.changed_files == publish_outcome.changed_files

      %{
        status: :ready,
        reason: :merge_gate_clear,
        checked_at: "2026-09-03T12:00:00Z",
        target_revision: "target-sha",
        head_revision: "head-sha"
      }
    end

    state = %State{
      target_context: context.target,
      control_plane: server,
      delivery: %Orchestrator.DeliveryState{landing_revalidator: revalidator},
      running: %{}
    }

    resolution = %RunTarget.Resolution{issues: [issue], ordering: :priority}

    assert {[%Issue{id: "issue-landing"}], planned_state} =
             Orchestrator.prepare_candidate_issues_for_test(resolution, state)

    assert [%{identifier: "SID-462-A", status: :selected, freshness: :ready}] =
             planned_state.delivery.landing_queue

    landing_context = %{context | role: :landing}
    start_evidence = Orchestrator.durable_start_evidence_for_test(planned_state, landing_context)

    assert get_in(start_evidence, [:landing_queue, :revalidation, :target_revision]) ==
             "target-sha"

    assert {:ok, started_landing} = RunAuthority.transition(retrying, :running, start_evidence)
    assert {:ok, history} = ControlPlane.lifecycle_history(server, started_landing.admission.admitted_run_id)

    assert get_in(List.last(history).evidence, ["landing_queue", "revalidation", "target_revision"]) ==
             "target-sha"

    assert :ok = RunAuthority.release(started_landing)
  end

  defp execution_context!(config_root, target_id, issue_id, issue_identifier, opts \\ []) do
    workspace_root = Path.join(config_root, "worktrees")
    File.mkdir_p!(workspace_root)

    runner = %{
      "kind" => "codex_app_server",
      "command" => ["codex", "app-server"],
      "turn_timeout_ms" => 30_000,
      "execution_profiles" => %{
        "implementation" => %{
          "model" => "model-#{target_id}",
          "timeout_ms" => 30_000,
          "max_retries" => 1
        }
      }
    }

    target = %TargetContext{
      target_id: target_id,
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: hash("generation-#{target_id}"),
      policy_hash: hash("policy-#{target_id}"),
      repo_manifest_hash: hash("manifest-#{target_id}"),
      repo_policy: %{
        "manifest" => %{"version" => 1},
        "manifest_source_dir" => config_root,
        "workflow_module_resolution" => %{}
      },
      tracker_connection: %{
        "id" => "linear",
        "policy" => %{
          "kind" => "linear",
          "endpoint" => "https://tracker.example.invalid/graphql",
          "api_key" => Keyword.get(opts, :tracker_key, "$TRACKER_KEY")
        }
      },
      run_target: %{},
      worktree_policy: %{
        "root" => workspace_root,
        "strategy" => "per_issue",
        "hooks" => %{
          "after_create" => nil,
          "after_run" => nil,
          "before_remove" => nil,
          "before_run" => nil,
          "timeout_ms" => 5_000
        }
      },
      runner_policy: %{
        "default" => "runner",
        "allowed" => ["runner"],
        "runners" => %{"runner" => runner}
      },
      effective_checks: %{"pre_handoff" => ["mix test"]},
      external_side_effect_gates: %{
        "tracker_write" => "allow",
        "vcs_publish" => "allow",
        "pull_request_write" => "allow"
      },
      capacity_limits: %{"max_concurrent_agents" => 1},
      budget_limits: Keyword.get(opts, :budget_limits, %{})
    }

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      title: "Run authority fixture",
      state: "In Progress"
    }

    assert {:ok, context} =
             ExecutionContext.new(target, issue,
               policy: %{
                 "delivery" => %{"pr_target" => "main"},
                 "target" => target_id
               }
             )

    context
  end

  defp process_identity(process_group_id) do
    %{
      "os_pid" => process_group_id,
      "process_group_id" => process_group_id,
      "wrapper_pid" => process_group_id - 1,
      "started_at" => "Wed Aug 26 17:00:00 2026"
    }
  end

  defp hash(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end

  defp start_control_plane!(config_root) do
    start_supervised!(
      {ControlPlane, config_root: config_root, name: {:global, {__MODULE__, make_ref()}}},
      restart: :temporary
    )
  end

  defp stop_process(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end

  defp tmp_root!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
