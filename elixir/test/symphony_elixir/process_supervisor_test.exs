defmodule SymphonyElixir.ProcessSupervisorTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ProcessSupervisor

  test "spawns argv without shell and applies cwd env and line buffering" do
    test_root = Path.join(System.tmp_dir!(), "symphony-process-supervisor-argv-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      fake_binary = Path.join(test_root, "fake-runner")

      File.mkdir_p!(workspace)

      File.write!(fake_binary, """
      #!/bin/sh
      printf 'ARGC:%s\\n' "$#"
      printf 'ARG1:%s\\n' "$1"
      printf 'ARG2:%s\\n' "$2"
      printf 'PWD:%s\\n' "$PWD"
      printf 'ENV:%s\\n' "$SYMP_PROCESS_SUPERVISOR_ENV"

      while IFS= read -r line; do
        printf 'INPUT:%s\\n' "$line"
        exit 0
      done
      """)

      File.chmod!(fake_binary, 0o755)
      expected_workspace_suffix = "/#{Path.basename(test_root)}/workspace"

      assert {:ok, process} =
               ProcessSupervisor.start(
                 [fake_binary, "literal $SYMP_PROCESS_SUPERVISOR_ENV", "two words"],
                 cd: workspace,
                 env: [{"SYMP_PROCESS_SUPERVISOR_ENV", "overlay"}],
                 line: 1024
               )

      port = ProcessSupervisor.port(process)

      assert_receive {^port, {:data, {:eol, "ARGC:2"}}}
      assert_receive {^port, {:data, {:eol, "ARG1:literal $SYMP_PROCESS_SUPERVISOR_ENV"}}}
      assert_receive {^port, {:data, {:eol, "ARG2:two words"}}}
      assert_receive {^port, {:data, {:eol, "PWD:" <> child_pwd}}}
      assert String.ends_with?(child_pwd, expected_workspace_suffix)
      assert_receive {^port, {:data, {:eol, "ENV:overlay"}}}

      Port.command(port, "hello\n")
      assert_receive {^port, {:data, {:eol, "INPUT:hello"}}}

      ProcessSupervisor.stop(process)
    after
      File.rm_rf(test_root)
    end
  end

  test "await_startup normalizes response timeout and stops launched process" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-process-supervisor-startup-timeout-#{System.unique_integer([:positive])}")

    try do
      fake_binary = Path.join(test_root, "fake-runner")
      pid_file = Path.join(test_root, "runner.pid")

      File.mkdir_p!(test_root)

      File.write!(fake_binary, """
      #!/bin/sh
      printf '%s\\n' "$$" > "#{pid_file}"
      while :; do
        sleep 1
      done
      """)

      File.chmod!(fake_binary, 0o755)

      assert {:ok, process} = ProcessSupervisor.start([fake_binary])
      os_pid = eventually(fn -> read_pid(pid_file) end)
      assert os_pid_alive?(os_pid)

      assert {:error, {:startup_failed, {:timeout, 20}}} =
               ProcessSupervisor.await_startup(process, 20, fn _process, timeout ->
                 receive do
                   :never -> :ok
                 after
                   timeout.() -> {:error, :response_timeout}
                 end
               end)

      assert eventually(fn -> if os_pid_alive?(os_pid), do: nil, else: :stopped end) == :stopped
    after
      File.rm_rf(test_root)
    end
  end

  test "await_startup exposes a decreasing startup deadline" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-process-supervisor-startup-deadline-#{System.unique_integer([:positive])}")

    try do
      fake_binary = Path.join(test_root, "fake-runner")
      pid_file = Path.join(test_root, "runner.pid")

      File.mkdir_p!(test_root)

      File.write!(fake_binary, """
      #!/bin/sh
      printf '%s\\n' "$$" > "#{pid_file}"
      while :; do
        sleep 1
      done
      """)

      File.chmod!(fake_binary, 0o755)

      assert {:ok, process} = ProcessSupervisor.start([fake_binary])
      os_pid = eventually(fn -> read_pid(pid_file) end)
      assert os_pid_alive?(os_pid)

      assert {:error, {:startup_failed, {:timeout, 80}}} =
               ProcessSupervisor.await_startup(process, 80, fn _process, timeout ->
                 first_timeout = timeout.()
                 Process.sleep(50)
                 second_timeout = timeout.()

                 assert first_timeout in 1..80
                 assert second_timeout < first_timeout

                 receive do
                   :never -> :ok
                 after
                   second_timeout -> {:error, :response_timeout}
                 end
               end)

      assert eventually(fn -> if os_pid_alive?(os_pid), do: nil, else: :stopped end) == :stopped
    after
      File.rm_rf(test_root)
    end
  end

  test "stop terminates descendant processes" do
    if ProcessSupervisor.descendant_cleanup_supported?() do
      do_descendant_cleanup_test()
    else
      assert ProcessSupervisor.descendant_cleanup_supported?() == false
    end
  end

  test "kill terminates launched process" do
    test_root = Path.join(System.tmp_dir!(), "symphony-process-supervisor-kill-#{System.unique_integer([:positive])}")

    try do
      fake_binary = Path.join(test_root, "fake-runner")
      pid_file = Path.join(test_root, "runner.pid")

      File.mkdir_p!(test_root)

      File.write!(fake_binary, """
      #!/bin/sh
      printf '%s\\n' "$$" > "#{pid_file}"
      while :; do
        sleep 1
      done
      """)

      File.chmod!(fake_binary, 0o755)

      assert {:ok, process} = ProcessSupervisor.start([fake_binary])
      os_pid = eventually(fn -> read_pid(pid_file) end)
      assert os_pid_alive?(os_pid)

      ProcessSupervisor.kill(process)

      assert eventually(fn -> if os_pid_alive?(os_pid), do: nil, else: :stopped end) == :stopped
    after
      File.rm_rf(test_root)
    end
  end

  defp do_descendant_cleanup_test do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-process-supervisor-descendant-cleanup-#{System.unique_integer([:positive])}")

    child_pid_file = Path.join(test_root, "child.pid")

    try do
      fake_binary = Path.join(test_root, "fake-runner")

      File.mkdir_p!(test_root)

      File.write!(fake_binary, """
      #!/bin/sh
      sleep 60 &
      printf '%s\\n' "$!" > "#{child_pid_file}"

      while :; do
        sleep 1
      done
      """)

      File.chmod!(fake_binary, 0o755)

      assert {:ok, process} = ProcessSupervisor.start([fake_binary])
      child_pid = eventually(fn -> read_pid(child_pid_file) end)
      assert os_pid_alive?(child_pid)

      ProcessSupervisor.stop(process)

      assert eventually(fn -> if os_pid_alive?(child_pid), do: nil, else: :stopped end) == :stopped
    after
      case File.read(child_pid_file) do
        {:ok, pid_text} ->
          pid_text
          |> String.trim()
          |> Integer.parse()
          |> case do
            {pid, ""} -> System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
            _ -> :ok
          end

        _ ->
          :ok
      end

      File.rm_rf(test_root)
    end
  end

  defp read_pid(path) do
    case File.read(path) do
      {:ok, pid_text} ->
        case Integer.parse(String.trim(pid_text)) do
          {pid, ""} -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp os_pid_alive?(nil), do: false

  defp os_pid_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(50)
        eventually(fun, attempts - 1)

      false ->
        Process.sleep(50)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  defp eventually(_fun, 0), do: false
end
