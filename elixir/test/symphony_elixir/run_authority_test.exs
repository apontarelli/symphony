defmodule SymphonyElixir.RunAuthorityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ControlPlane
  alias SymphonyElixir.ControlPlane.SideEffect
  alias SymphonyElixir.{ExecutionContext, Orchestrator, RunAuthority, TargetContext}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.State

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
      budget_limits: %{}
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
