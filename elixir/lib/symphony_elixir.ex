defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()
    registry_path = Application.get_env(:symphony_elixir, :host_registry_path)

    validate_startup? =
      if is_binary(registry_path),
        do: false,
        else: Application.get_env(:symphony_elixir, :validate_startup, true)

    with {:ok, target_context} <- application_target_context(validate_startup?) do
      scheduler_options =
        if is_binary(registry_path) do
          [
            registry_path: registry_path,
            orchestrator_opts: [validate_startup: false]
          ]
        else
          [
            target_context: target_context,
            orchestrator_opts: [
              validate_startup: validate_startup?,
              target_context: target_context
            ]
          ]
        end

      children =
        control_plane_children() ++
          [
            {Phoenix.PubSub, name: SymphonyElixir.PubSub},
            SymphonyElixir.OperatorInterface,
            {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
            SymphonyElixir.WorkflowStore,
            SymphonyElixir.TargetSupervisor,
            {SymphonyElixir.HostScheduler, scheduler_options},
            SymphonyElixir.HttpServer,
            SymphonyElixir.StatusDashboard
          ]

      Supervisor.start_link(
        children,
        strategy: :one_for_one,
        name: SymphonyElixir.Supervisor
      )
    end
  end

  defp application_target_context(true) do
    with :ok <- SymphonyElixir.Config.validate!(),
         do: SymphonyElixir.TargetAdmission.build_target([])
  end

  defp application_target_context(false), do: {:ok, nil}

  defp control_plane_children do
    if Application.get_env(:symphony_elixir, :start_control_plane, true),
      do: [SymphonyElixir.ControlPlane],
      else: []
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
