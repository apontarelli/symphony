defmodule SymphonyElixir.Codex.Launch do
  @moduledoc """
  Prepares the Codex harness home and starts the app-server process.
  """

  alias SymphonyElixir.{Codex.HarnessHome, Shell, SSH}

  @type result :: %{
          port: port(),
          codex_home: Path.t()
        }

  @spec start(Path.t(), String.t() | nil, String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def start(workspace, worker_host, codex_command, opts \\ [])
      when is_binary(workspace) and is_binary(codex_command) do
    line_bytes = Keyword.get(opts, :line)

    with {:ok, codex_home} <- prepare_harness_home(workspace, worker_host),
         {:ok, port} <- start_port(workspace, worker_host, codex_home, codex_command, line_bytes) do
      {:ok, %{port: port, codex_home: codex_home}}
    end
  end

  defp prepare_harness_home(workspace, nil) do
    HarnessHome.ensure_local(workspace)
  end

  defp prepare_harness_home(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    {:ok, HarnessHome.path(workspace, remote: true)}
  end

  defp start_port(workspace, nil, codex_home, codex_command, line_bytes) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(codex_command)],
            cd: String.to_charlist(workspace),
            env: HarnessHome.local_port_env(codex_home),
            line: line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, codex_home, codex_command, line_bytes)
       when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, codex_home, codex_command)
    SSH.start_port(worker_host, remote_command, line: line_bytes)
  end

  defp remote_launch_command(workspace, codex_home, codex_command) do
    [
      HarnessHome.remote_prepare_command(codex_home),
      "cd #{Shell.escape(workspace)}",
      "CODEX_HOME=#{Shell.escape(codex_home)} exec #{codex_command}"
    ]
    |> Enum.join(" && ")
  end
end
