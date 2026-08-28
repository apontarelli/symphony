defmodule SymphonyElixir.TargetSupervisorTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.TargetSupervisor

  test "starts target orchestrators as dynamic children" do
    supervisor = Module.concat(__MODULE__, "Supervisor#{System.unique_integer([:positive])}")
    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!({TargetSupervisor, name: supervisor})

    assert {:ok, pid} =
             TargetSupervisor.start_target(supervisor,
               name: orchestrator,
               validate_startup: false,
               target_context: nil,
               control_plane: false
             )

    assert Process.whereis(orchestrator) == pid

    assert [{:undefined, ^pid, :worker, [SymphonyElixir.Orchestrator]}] =
             DynamicSupervisor.which_children(supervisor)

    assert :ok = DynamicSupervisor.terminate_child(supervisor, pid)
  end

  test "default APIs use the application target supervisor" do
    assert {:error, {:already_started, global_supervisor}} = TargetSupervisor.start_link()
    assert global_supervisor == Process.whereis(TargetSupervisor)

    orchestrator = Module.concat(__MODULE__, "DefaultOrchestrator#{System.unique_integer([:positive])}")

    assert {:ok, pid} =
             TargetSupervisor.start_target(
               name: orchestrator,
               validate_startup: false,
               target_context: nil,
               control_plane: false
             )

    assert :ok = DynamicSupervisor.terminate_child(TargetSupervisor, pid)
  end
end
