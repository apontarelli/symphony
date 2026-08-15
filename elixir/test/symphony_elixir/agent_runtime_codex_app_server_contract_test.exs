defmodule SymphonyElixir.AgentRuntimeCodexAppServerContractTest do
  use SymphonyElixir.AgentRuntimeContract,
    adapter: SymphonyElixir.AgentRuntime.CodexAppServer,
    expected_runtime: :codex_app_server,
    fake: SymphonyElixir.AgentRuntimeContract.FakeCodex

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema

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

    assert {:ok, session} =
             @agent_runtime_adapter.start(
               runtime_context.workspace,
               %{identifier: runtime_context.issue_identifier},
               runtime_settings: settings,
               runner_name: "selected",
               runner_config: selected_runner,
               startup_timeout_ms: 1_000
             )

    try do
      assert session.runner_config == selected_runner
      assert session.approval_policy == %{"selected" => %{"allow" => true}}
      assert session.thread_sandbox == "danger-full-access"
      assert session.turn_sandbox_policy == %{"type" => "readOnly"}
    after
      assert :ok = @agent_runtime_adapter.stop(session)
    end
  end

  test "workspace validation uses the selected runtime settings root", %{runtime_context: runtime_context} do
    runtime_context = @agent_runtime_fake.install!(runtime_context, :start_only)
    global_root = runtime_context.workspace_root
    selected_root = Path.join(runtime_context.test_root, "selected-workspaces")
    selected_workspace = Path.join(selected_root, "SID-351")
    File.mkdir_p!(selected_workspace)
    settings = put_in(Config.settings!().workspace.root, selected_root)

    assert {:ok, session} =
             @agent_runtime_adapter.start(
               selected_workspace,
               %{identifier: runtime_context.issue_identifier},
               runtime_settings: settings,
               startup_timeout_ms: 1_000
             )

    try do
      {:ok, canonical_selected_workspace} = SymphonyElixir.PathSafety.canonicalize(selected_workspace)
      assert session.workspace == canonical_selected_workspace
    after
      assert :ok = @agent_runtime_adapter.stop(session)
    end

    assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, canonical_root}} =
             @agent_runtime_adapter.start(
               runtime_context.workspace,
               %{identifier: runtime_context.issue_identifier},
               runtime_settings: settings,
               startup_timeout_ms: 1_000
             )

    {:ok, canonical_selected_root} = SymphonyElixir.PathSafety.canonicalize(selected_root)
    assert canonical_root == canonical_selected_root
    assert canonical_root != Path.expand(global_root)
  end
end
