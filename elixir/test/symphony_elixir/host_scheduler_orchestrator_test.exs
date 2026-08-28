defmodule SymphonyElixir.HostSchedulerOrchestratorTest.RuntimeAdapter do
  @behaviour SymphonyElixir.AgentRuntime

  @impl true
  def start(_context, issue, []) do
    recipient = Application.fetch_env!(:symphony_elixir, :host_scheduler_smoke_recipient)
    send(recipient, {:runtime_starting, self(), issue.identifier})

    receive do
      :continue -> {:ok, %{recipient: recipient}}
    end
  end

  @impl true
  def send_turn(%{recipient: recipient}, _prompt, issue, _opts) do
    send(recipient, {:runtime_turn, issue.identifier})
    {:ok, %{session_id: "sid-441-session"}}
  end

  @impl true
  def stop(%{recipient: recipient}) do
    send(recipient, :runtime_stopped)
    :ok
  end

  @impl true
  def capabilities(_runner_config), do: %{}
end

defmodule SymphonyElixir.HostSchedulerOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ControlPlane, HostScheduler, RunSetup, TargetAdmission, TargetSupervisor}
  alias SymphonyElixir.HostSchedulerOrchestratorTest.RuntimeAdapter

  @tag :tmp_dir
  test "explicit issue polls, admits, dispatches, and releases through one host grant", %{tmp_dir: tmp_dir} do
    issue = %Issue{
      id: "SID-441",
      identifier: "SID-441",
      title: "Scheduler smoke fixture",
      state: "Todo",
      priority: 2,
      labels: [],
      url: "https://linear.example/SID-441"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: "$MEMORY_TRACKER_KEY",
      tracker_project_slug: nil,
      target: %{"type" => "issues", "issue_ids" => [issue.id]},
      poll_interval_ms: 50_000,
      workspace_root: Path.join(tmp_dir, "workspaces"),
      max_concurrent_agents: 1,
      max_concurrent_startups: 1,
      max_turns: 1
    )

    RunSetup.put_current(%{
      mode: :issue_batch,
      issue_batch_limit: 1,
      capacity: %{max_concurrent_agents: 1, max_concurrent_startups: 1}
    })

    on_exit(&RunSetup.clear_current/0)
    previous_tracker_key = System.get_env("MEMORY_TRACKER_KEY")
    System.put_env("MEMORY_TRACKER_KEY", "memory-tracker-secret")
    on_exit(fn -> restore_env("MEMORY_TRACKER_KEY", previous_tracker_key) end)
    WorkflowStore.force_reload()
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :host_scheduler_smoke_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :host_scheduler_smoke_recipient) end)

    assert {:ok, target} = TargetAdmission.build_target([])
    assert target.dispatch_mode == :explicit
    assert target.run_target["issue_ids"] == [issue.id]

    eligibility_state = %Orchestrator.State{
      target_context: target,
      max_concurrent_agents: 1,
      max_concurrent_startups: 1,
      max_concurrent_agents_by_state: %{},
      running: %{},
      blocked: %{},
      retry_attempts: %{},
      claimed: MapSet.new()
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, eligibility_state)

    control_plane = unique_name(ControlPlane)
    target_supervisor = unique_name(TargetSupervisor)
    scheduler = unique_name(HostScheduler)
    orchestrator = unique_name(Orchestrator)

    start_supervised!({ControlPlane, name: control_plane, config_root: tmp_dir})
    start_supervised!({TargetSupervisor, name: target_supervisor})

    start_supervised!(
      {HostScheduler,
       name: scheduler,
       target_context: target,
       target_supervisor: target_supervisor,
       limits: %{agents: 1, startups: 1, reviewers: 1, polls: %{max_concurrent: 1, interval_ms: 50_000}},
       orchestrator_opts: [
         name: orchestrator,
         control_plane: control_plane,
         agent_runner_options: [adapter_registry: %{"codex_app_server" => RuntimeAdapter}]
       ]}
    )

    assert_receive {:memory_tracker_resolve_candidate_issues, _run_target}, 1_000

    assert_receive {:memory_tracker_fetch_issue_states_by_ids, ["SID-441"]}, 1_000
    assert_receive {:runtime_starting, worker, "SID-441"}, 1_000

    assert HostScheduler.snapshot(scheduler).counts == %{
             agents: 1,
             startups: 1,
             reviewers: 0,
             polls: 0
           }

    assert %{running: [%{identifier: "SID-441", startup: true}]} = Orchestrator.snapshot(orchestrator, 1_000)

    send(orchestrator, :run_poll_cycle)
    refute_receive {:memory_tracker_resolve_candidate_issues, _run_target}, 50

    send(worker, :continue)
    assert_receive {:runtime_turn, "SID-441"}, 1_000
    assert_receive :runtime_stopped, 1_000

    assert eventually(fn ->
             case HostScheduler.snapshot(scheduler) do
               %{counts: %{agents: 0, startups: 0, reviewers: 0, polls: 0}, grants: 0} = snapshot -> snapshot
               _other -> nil
             end
           end)

    assert eventually(fn ->
             case Orchestrator.snapshot(orchestrator, 1_000) do
               %{running: [], blocked: [%{identifier: "SID-441"}]} = snapshot -> snapshot
               _other -> nil
             end
           end)

    assert {:ok, [%{target_id: target_id, issue_identifier: "SID-441"}]} =
             ControlPlane.inspect_runs(control_plane)

    assert target_id == target.target_id
  end

  defp unique_name(suffix),
    do: Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
end
