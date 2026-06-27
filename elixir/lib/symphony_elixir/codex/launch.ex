defmodule SymphonyElixir.Codex.Launch do
  @moduledoc """
  Prepares the Codex harness home and starts the app-server process.
  """

  alias SymphonyElixir.{Codex.HarnessHome, ProcessSupervisor, Shell, SSH}

  @type command :: String.t() | [String.t()]
  @type result :: %{
          port: port(),
          process: ProcessSupervisor.t(),
          argv: [String.t()] | nil,
          codex_home: Path.t()
        }

  @spec start(Path.t(), String.t() | nil, command(), keyword()) :: {:ok, result()} | {:error, term()}
  def start(workspace, worker_host, codex_command, opts \\ [])
      when is_binary(workspace) and (is_binary(codex_command) or is_list(codex_command)) do
    line_bytes = Keyword.get(opts, :line)

    with {:ok, codex_home} <- prepare_harness_home(workspace, worker_host),
         {:ok, process, argv} <- start_port(workspace, worker_host, codex_home, codex_command, line_bytes) do
      {:ok, %{port: ProcessSupervisor.port(process), process: process, argv: argv, codex_home: codex_home}}
    end
  end

  defp prepare_harness_home(workspace, nil) do
    HarnessHome.ensure_local(workspace)
  end

  defp prepare_harness_home(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    {:ok, HarnessHome.path(workspace, remote: true)}
  end

  defp start_port(workspace, nil, codex_home, codex_command, line_bytes) when is_list(codex_command) do
    with {:ok, argv} <- command_argv(codex_command),
         {:ok, process} <-
           ProcessSupervisor.start(argv,
             cd: workspace,
             env: HarnessHome.local_port_env(codex_home),
             line: line_bytes
           ) do
      {:ok, process, argv}
    end
  end

  defp start_port(workspace, nil, codex_home, codex_command, line_bytes) when is_binary(codex_command) do
    with {:ok, process} <-
           ProcessSupervisor.start(["/bin/sh", "-lc", "exec #{codex_command}"],
             cd: workspace,
             env: HarnessHome.local_port_env(codex_home),
             line: line_bytes
           ) do
      {:ok, process, nil}
    end
  end

  defp start_port(workspace, worker_host, codex_home, codex_command, line_bytes)
       when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, codex_home, command_string(codex_command))

    with {:ok, port} <- SSH.start_port(worker_host, remote_command, line: line_bytes) do
      {:ok, ProcessSupervisor.from_port(port, cleanup: :port_only), nil}
    end
  end

  defp remote_launch_command(workspace, codex_home, codex_command) do
    [
      HarnessHome.remote_prepare_command(codex_home),
      "cd #{Shell.escape(workspace)}",
      "CODEX_HOME=#{Shell.escape(codex_home)} exec #{codex_command}"
    ]
    |> Enum.join(" && ")
  end

  defp command_argv(argv) when is_list(argv) do
    if Enum.all?(argv, &is_binary/1) and argv != [] do
      {:ok, argv}
    else
      {:error, :invalid_argv}
    end
  end

  defp command_argv(_command), do: {:error, :invalid_argv}

  defp command_string(command) when is_binary(command), do: command

  defp command_string(argv) when is_list(argv) do
    Enum.map_join(argv, " ", &Shell.escape/1)
  end
end
