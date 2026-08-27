defmodule SymphonyElixir.AgentRuntimeCodexAppServerContractTest do
  use SymphonyElixir.AgentRuntimeContract,
    adapter: SymphonyElixir.AgentRuntime.CodexAppServer,
    expected_runtime: :codex_app_server,
    fake: SymphonyElixir.AgentRuntimeContract.FakeCodex

  alias SymphonyElixir.{Config, ExecutionContext, TargetContext}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  test "selected runner snapshot controls Codex launch policies", %{runtime_context: runtime_context} do
    runtime_context = @agent_runtime_fake.install!(runtime_context, :start_only)
    settings = Config.settings!()

    selected_runner =
      settings
      |> Schema.default_runner_config!()
      |> Map.merge(%{
        "approval_policy" => %{"selected" => %{"allow" => true}},
        "thread_sandbox" => "danger-full-access",
        "turn_sandbox_policy" => %{"type" => "readOnly"}
      })

    target = target_context(runtime_context, selected_runner)
    issue = %Issue{id: "selected-runner", identifier: runtime_context.issue_identifier}

    policy = %{
      "runners" => %{
        "codex" => %{
          "approval_policy" => %{"selected" => %{"allow" => true}},
          "thread_sandbox" => "danger-full-access",
          "turn_sandbox_policy" => %{"type" => "readOnly"}
        }
      }
    }

    assert {:ok, context} = ExecutionContext.new(target, issue, policy: policy)
    assert {:ok, session} = @agent_runtime_adapter.start(context, issue, [])

    try do
      assert session.runner_config == selected_runner
      assert session.approval_policy == %{"selected" => %{"allow" => true}}
      assert session.thread_sandbox == "danger-full-access"
      assert session.turn_sandbox_policy == %{"type" => "readOnly"}
    after
      assert :ok = @agent_runtime_adapter.stop(session)
    end
  end

  test "pinned context controls Codex launch after global workflow poisoning", %{
    runtime_context: runtime_context
  } do
    runtime_context = @agent_runtime_fake.install!(runtime_context, :start_only)
    settings = Config.settings!()

    runner =
      settings
      |> Schema.default_runner_config!()
      |> Map.put("model", "pinned-context-model")
      |> put_in(
        ["execution_profiles", "implementation"],
        %{
          "model" => "pinned-context-model",
          "timeout_ms" => 4_000,
          "max_retries" => 0
        }
      )

    target = target_context(runtime_context, runner)
    issue = %Issue{id: "context-codex", identifier: runtime_context.issue_identifier}

    policy = %{
      "runners" => %{
        "codex" => %{
          "approval_policy" => "never",
          "thread_sandbox" => "workspace-write",
          "turn_sandbox_policy" => %{"type" => "readOnly"}
        }
      }
    }

    assert {:ok, context} = ExecutionContext.new(target, issue, policy: policy)

    SymphonyElixir.TestSupport.write_workflow_file!(
      SymphonyElixir.Workflow.workflow_file_path(),
      workspace_root: Path.join(runtime_context.test_root, "poisoned-workspaces"),
      codex_command: "/definitely/missing/codex app-server"
    )

    assert {:ok, session} = @agent_runtime_adapter.start(context, issue, [])

    try do
      assert session.execution_context == context
      assert session.runner_config == runner
      assert session.approval_policy == "never"
      assert session.thread_sandbox == "workspace-write"
      assert session.turn_sandbox_policy == %{"type" => "readOnly"}
      assert session.metadata.codex_command =~ runtime_context.binary
      refute session.metadata.codex_command =~ "/definitely/missing"
    after
      assert :ok = @agent_runtime_adapter.stop(session)
    end
  end

  defp target_context(runtime_context, runner) do
    {:ok, workspace_root} =
      SymphonyElixir.PathSafety.canonicalize(runtime_context.workspace_root)

    %TargetContext{
      target_id: Path.basename(workspace_root),
      workspace_layout: :flat,
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: hash(),
      policy_hash: hash(),
      repo_manifest_hash: hash(),
      repo_policy: %{
        "manifest" => %{"harness" => %{"codex_home" => nil}},
        "manifest_source_dir" => runtime_context.test_root,
        "workflow_module_resolution" => %{}
      },
      tracker_connection: %{},
      run_target: %{},
      worktree_policy: %{
        "root" => workspace_root,
        "strategy" => "per_issue",
        "hooks" => %{
          "after_create" => nil,
          "after_run" => nil,
          "before_remove" => nil,
          "before_run" => nil,
          "timeout_ms" => 1_000
        }
      },
      runner_policy: %{
        "default" => "codex",
        "allowed" => ["codex"],
        "runners" => %{"codex" => runner}
      },
      effective_checks: %{},
      external_side_effect_gates: %{},
      capacity_limits: %{},
      budget_limits: %{}
    }
  end

  defp hash, do: "sha256:" <> String.duplicate("a", 64)
end
