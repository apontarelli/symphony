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

  alias SymphonyElixir.LocalHost.Ownership

  @impl true
  def start(_type, _args) do
    registry_path = Application.get_env(:symphony_elixir, :host_registry_path)

    with :ok <- prepare_host_ownership(registry_path) do
      start_runtime(registry_path)
    end
  end

  defp start_runtime(registry_path) do
    :ok = SymphonyElixir.LogFile.configure()

    validate_startup? =
      if is_binary(registry_path),
        do: false,
        else: Application.get_env(:symphony_elixir, :validate_startup, true)

    :ok = maybe_default_server_port(registry_path)

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
        host_ownership_children(registry_path) ++
          control_plane_children() ++
          [
            {Phoenix.PubSub, name: SymphonyElixir.PubSub},
            SymphonyElixir.Linear.MetadataCache,
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

  # Registry hosts must publish discovery, so they always serve a local
  # endpoint; an unconfigured port binds ephemerally instead of silently
  # leaving the host undiscoverable.
  defp maybe_default_server_port(registry_path) when is_binary(registry_path) do
    if Application.get_env(:symphony_elixir, :server_port_override) do
      :ok
    else
      case SymphonyElixir.Config.server_port() do
        nil -> Application.put_env(:symphony_elixir, :server_port_override, 0)
        _configured -> :ok
      end

      :ok
    end
  rescue
    _exception -> :ok
  end

  defp maybe_default_server_port(_registry_path), do: :ok

  # The BEAM resource remains pinned while the preflight publisher is
  # replaced by the supervised ownership process. There is no lock gap.
  defp prepare_host_ownership(registry_path) when is_binary(registry_path) do
    with {:ok, pid} <- Ownership.claim(), do: GenServer.stop(pid, :normal)
  end

  defp prepare_host_ownership(_registry_path), do: :ok

  defp host_ownership_children(registry_path) when is_binary(registry_path), do: [Ownership]

  defp host_ownership_children(_registry_path), do: []

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
  def prep_stop(state) do
    Ownership.unpublish()
    state
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
