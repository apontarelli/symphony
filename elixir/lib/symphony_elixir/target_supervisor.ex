defmodule SymphonyElixir.TargetSupervisor do
  @moduledoc """
  Dynamic supervisor for target-scoped orchestrators.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_target(GenServer.server(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_target(supervisor \\ __MODULE__, opts) when is_list(opts) do
    spec = %{
      id: {SymphonyElixir.Orchestrator, Keyword.get(opts, :name, SymphonyElixir.Orchestrator)},
      start: {SymphonyElixir.Orchestrator, :start_link, [opts]},
      restart: :permanent,
      shutdown: 30_000,
      type: :worker
    }

    DynamicSupervisor.start_child(supervisor, spec)
  end
end
