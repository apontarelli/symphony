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

defmodule SymphonyElixir.HostSchedulerOrchestratorTest.OwnedRuntimeAdapter do
  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.ProcessSupervisor

  @impl true
  def start(_context, issue, []) do
    recipient = Application.fetch_env!(:symphony_elixir, :host_scheduler_smoke_recipient)
    {:ok, process} = ProcessSupervisor.start(["/bin/cat"])
    send(recipient, {:owned_runtime_started, self(), issue.identifier})
    {:ok, %{process: process, recipient: recipient}}
  end

  @impl true
  def send_turn(%{recipient: recipient}, _prompt, issue, _opts) do
    send(recipient, {:owned_runtime_waiting, self(), issue.identifier})

    receive do
      :finish -> {:ok, %{session_id: "sid-443-session"}}
    end
  end

  @impl true
  def stop(%{process: process, recipient: recipient}) do
    _ = ProcessSupervisor.stop(process)
    send(recipient, :owned_runtime_stopped)
    :ok
  end

  @impl true
  def capabilities(_runner_config), do: %{}
end

defmodule SymphonyElixir.HostSchedulerOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{
    ControlPlane,
    HostScheduler,
    RunSetup,
    TargetAdmission,
    TargetSupervisor
  }

  alias SymphonyElixir.HostSchedulerOrchestratorTest.{
    OwnedRuntimeAdapter,
    RuntimeAdapter
  }

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

  @tag :tmp_dir
  test "pause fences an owned run and reactivation resumes it before candidate polling", %{
    tmp_dir: tmp_dir
  } do
    issue = %Issue{
      id: "SID-443",
      identifier: "SID-443",
      title: "Lifecycle transition fixture",
      state: "Todo",
      priority: 2,
      labels: [],
      url: "https://linear.example/SID-443"
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

    assert {:ok, base_target} = TargetAdmission.build_target([])
    active = %{base_target | registry_generation: lifecycle_hash("active")}
    paused = %{active | state: :paused, registry_generation: lifecycle_hash("paused")}
    reactivated = %{active | registry_generation: lifecycle_hash("reactivated")}

    {:ok, registry} =
      Agent.start_link(fn -> {:ok, lifecycle_registry(active)} end)

    control_plane = unique_name(ControlPlane)
    target_supervisor = unique_name(TargetSupervisor)
    scheduler = unique_name(HostScheduler)

    start_supervised!({ControlPlane, name: control_plane, config_root: tmp_dir})
    start_supervised!({TargetSupervisor, name: target_supervisor})

    start_supervised!(
      {HostScheduler,
       name: scheduler,
       registry_path: "/synthetic/sid-443-registry.yml",
       registry_loader: fn _path -> Agent.get(registry, & &1) end,
       registry_reload_interval_ms: 10,
       target_supervisor: target_supervisor,
       orchestrator_opts: [
         control_plane: control_plane,
         agent_runner_options: [adapter_registry: %{"codex_app_server" => OwnedRuntimeAdapter}]
       ]}
    )

    assert_receive {:memory_tracker_resolve_candidate_issues, _run_target}, 1_000
    assert_receive {:memory_tracker_fetch_issue_states_by_ids, ["SID-443"]}, 1_000
    assert_receive {:owned_runtime_started, first_worker, "SID-443"}, 1_000
    assert_receive {:owned_runtime_waiting, ^first_worker, "SID-443"}, 1_000

    orchestrator = HostScheduler.snapshot(scheduler).targets[active.target_id].pid

    assert eventually(fn ->
             case :sys.get_state(orchestrator).running |> Map.values() do
               [%{durable_process_identity: %{"process_group_id" => process_group_id}}]
               when is_integer(process_group_id) ->
                 process_group_id

               _other ->
                 nil
             end
           end)

    Agent.update(registry, fn _current -> {:ok, lifecycle_registry(paused)} end)

    assert eventually(fn ->
             case :sys.get_state(orchestrator) do
               %{running: running, blocked: blocked} = state
               when map_size(running) == 0 and map_size(blocked) == 1 ->
                 case Map.values(blocked) do
                   [%{identifier: "SID-443", error: "target_paused"}] -> state
                   _other -> nil
                 end

               _other ->
                 nil
             end
           end)

    assert eventually(fn ->
             case HostScheduler.snapshot(scheduler) do
               %{counts: %{agents: 0, startups: 0, polls: 0}} = snapshot -> snapshot
               _other -> nil
             end
           end)

    assert {:ok, [%{admitted_run_id: admitted_run_id}]} =
             ControlPlane.inspect_runs(control_plane)

    assert {:ok, %{state: :blocked, blocked_reason: "target_paused"}} =
             ControlPlane.fetch_lifecycle(control_plane, admitted_run_id)

    Agent.update(registry, fn _current -> {:ok, lifecycle_registry(reactivated)} end)

    assert_receive {:memory_tracker_fetch_issue_states_by_ids, ["SID-443"]}, 1_000
    refute_receive {:memory_tracker_resolve_candidate_issues, _run_target}, 0
    assert_receive {:owned_runtime_started, second_worker, "SID-443"}, 1_000
    assert_receive {:owned_runtime_waiting, ^second_worker, "SID-443"}, 1_000

    send(second_worker, :finish)
    assert_receive :owned_runtime_stopped, 1_000
  end

  defp lifecycle_registry(target) do
    %{
      snapshot: %{
        generation: target.registry_generation,
        host: %{
          "polling" => %{
            "interval_ms" => 50_000,
            "max_concurrent_target_polls" => 1
          },
          "capacity" => %{
            "max_concurrent_agents" => 1,
            "max_concurrent_startups" => 1,
            "max_concurrent_reviewers" => 1
          },
          "scheduling" => %{
            "algorithm" => "weighted_deficit_round_robin",
            "max_credit_rounds" => 2
          }
        }
      },
      contexts: %{target.target_id => target},
      weights: [{target.target_id, 1}]
    }
  end

  defp lifecycle_hash(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp unique_name(suffix),
    do: Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
end
