defmodule SymphonyElixir.TestSupportTest do
  use SymphonyElixir.TestSupport

  test "setup stops the default orchestrator before tests publish global state" do
    assert Process.whereis(SymphonyElixir.Orchestrator) == nil
  end
end

defmodule SymphonyElixir.RestartingOrchestratorTestSupportTest do
  use SymphonyElixir.TestSupport

  setup_all do
    SymphonyElixir.TestSupport.ensure_application_started!()

    :ok =
      Supervisor.terminate_child(
        SymphonyElixir.Supervisor,
        SymphonyElixir.HostScheduler
      )

    mark_host_scheduler_restarting()

    assert restarting_child(Supervisor.which_children(SymphonyElixir.Supervisor))

    Workflow.set_workflow_file_path("/tmp/pre-fixture-workflow.yml")
    Application.put_env(:symphony_elixir, :tracker_coordinator_state_path, "/tmp/pre-fixture-state")

    :ok
  end

  test "setup cancels a restarting host scheduler before publishing global state" do
    assert stopped_child(Supervisor.which_children(SymphonyElixir.Supervisor))

    refute Process.whereis(SymphonyElixir.Orchestrator)
    refute Workflow.workflow_file_path() == "/tmp/pre-fixture-workflow.yml"

    refute Application.get_env(:symphony_elixir, :tracker_coordinator_state_path) ==
             "/tmp/pre-fixture-state"
  end

  defp restarting_child(children) do
    {SymphonyElixir.HostScheduler, :restarting, :worker, [SymphonyElixir.HostScheduler]} in children
  end

  defp stopped_child(children) do
    {SymphonyElixir.HostScheduler, :undefined, :worker, [SymphonyElixir.HostScheduler]} in children
  end

  defp mark_host_scheduler_restarting do
    :sys.replace_state(SymphonyElixir.Supervisor, fn state ->
      children_state = elem(state, 3)
      children = elem(children_state, 1)
      child = Map.fetch!(children, SymphonyElixir.HostScheduler)
      restarting_child = put_elem(child, 1, :restarting)
      restarting_children = Map.put(children, SymphonyElixir.HostScheduler, restarting_child)

      put_elem(state, 3, put_elem(children_state, 1, restarting_children))
    end)
  end
end
