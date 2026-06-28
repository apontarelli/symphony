defmodule SymphonyElixir.Codex.Launch do
  @moduledoc """
  Prepares the Codex harness home and starts the app-server process.
  """

  alias SymphonyElixir.{Codex.HarnessHome, ProcessSupervisor, Shell, SSH}

  @local_runner_wrapper """
  set -m 2>/dev/null || true
  exec 3<&0

  cleanup() {
    kill -TERM "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
    sleep 0.1
    kill -KILL "-$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null || true
  }

  "$@" <&3 &
  child=$!
  trap 'cleanup; exit 143' TERM INT HUP
  wait "$child"
  status=$?
  trap - TERM INT HUP
  exec 3<&-
  exit "$status"
  """

  @type command :: [String.t()]
  @type result :: %{
          port: port(),
          process: ProcessSupervisor.t(),
          argv: [String.t()] | nil,
          codex_home: Path.t()
        }

  @spec start(Path.t(), String.t() | nil, command(), keyword()) :: {:ok, result()} | {:error, term()}
  def start(workspace, worker_host, codex_command, opts \\ [])
      when is_binary(workspace) and is_list(codex_command) do
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

  defp start_port(workspace, nil, codex_home, codex_command, line_bytes)
       when is_list(codex_command) do
    runner_argv = [
      System.find_executable("sh") || "/bin/sh",
      "-c",
      @local_runner_wrapper,
      "symphony-runner"
    ]

    with {:ok, argv} <- command_argv(codex_command),
         {:ok, executable, args} <- local_command(workspace, argv),
         {:ok, process} <-
           ProcessSupervisor.start(runner_argv ++ [executable | args],
             cd: workspace,
             env: HarnessHome.local_port_env(codex_home),
             line: line_bytes
           ) do
      {:ok, process, argv}
    end
  end

  defp start_port(workspace, worker_host, codex_home, codex_command, line_bytes)
       when is_binary(worker_host) do
    with {:ok, codex_command_string} <- command_string(codex_command),
         remote_command = remote_launch_command(workspace, codex_home, codex_command_string),
         {:ok, port} <- SSH.start_port(worker_host, remote_command, line: line_bytes) do
      {:ok, ProcessSupervisor.from_port(port, cleanup: :port_only), nil}
    end
  end

  defp local_command(workspace, [command | args]) when is_binary(command) and command != "" do
    case resolve_local_executable(workspace, command) do
      nil -> {:error, {:executable_not_found, command}}
      executable -> {:ok, executable, args}
    end
  end

  defp local_command(_workspace, _command), do: {:error, :empty_runner_command}

  defp resolve_local_executable(workspace, command) do
    if Path.type(command) == :absolute or String.contains?(command, "/") do
      command
      |> Path.expand(workspace)
      |> executable_file()
    else
      System.find_executable(command)
    end
  end

  defp executable_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) != 0, do: path

      _stat ->
        nil
    end
  end

  defp remote_launch_command(workspace, codex_home, codex_command) when is_binary(codex_command) do
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

  defp command_string(command) when is_binary(command), do: {:ok, command}

  defp command_string(argv) when is_list(argv) do
    with {:ok, argv} <- command_argv(argv) do
      {:ok, Shell.argv_to_command(argv)}
    end
  end

  defp command_string(_command), do: {:error, :invalid_argv}
end
