defmodule SymphonyElixir.ProcessSupervisorTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ProcessSupervisor
  import SymphonyElixir.TestSupport, only: [eventually: 1, os_pid_alive?: 1, read_pid: 1]

  test "spawns argv without shell and applies cwd env and line buffering" do
    test_root = Path.join(System.tmp_dir!(), "symphony-process-supervisor-argv-#{System.unique_integer([:positive])}")
    unlisted_key = "SYMP_PROCESS_SUPERVISOR_UNLISTED"
    previous_unlisted = System.get_env(unlisted_key)
    System.put_env(unlisted_key, "host-secret")

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
      printf 'PROVIDER:%s\\n' "$OPENAI_API_KEY"
      printf 'UNLISTED:%s\\n' "$SYMP_PROCESS_SUPERVISOR_UNLISTED"

      while IFS= read -r line; do
        printf 'INPUT:%s\\n' "$line"
        exit 0
      done
      """)

      File.chmod!(fake_binary, 0o755)
      expected_workspace_suffix = "/#{Path.basename(test_root)}/workspace"

      child_env =
        System.get_env()
        |> Map.new(fn {key, _value} -> {key, false} end)
        |> Map.merge(%{
          "OPENAI_API_KEY" => "provider-key",
          "PATH" => System.get_env("PATH"),
          "SYMP_PROCESS_SUPERVISOR_ENV" => "overlay"
        })

      assert {:ok, process} =
               ProcessSupervisor.start(
                 [fake_binary, "literal $SYMP_PROCESS_SUPERVISOR_ENV", "two words"],
                 cd: workspace,
                 env: child_env,
                 line: 1024
               )

      port = ProcessSupervisor.port(process)

      assert %{os_pid: process_group_id, process_group_id: process_group_id} =
               ProcessSupervisor.identity(process)

      assert is_integer(process_group_id)

      assert_receive {^port, {:data, {:eol, "ARGC:2"}}}, 1_000
      assert_receive {^port, {:data, {:eol, "ARG1:literal $SYMP_PROCESS_SUPERVISOR_ENV"}}}
      assert_receive {^port, {:data, {:eol, "ARG2:two words"}}}
      assert_receive {^port, {:data, {:eol, "PWD:" <> child_pwd}}}
      assert String.ends_with?(child_pwd, expected_workspace_suffix)
      assert_receive {^port, {:data, {:eol, "ENV:overlay"}}}
      assert_receive {^port, {:data, {:eol, "PROVIDER:provider-key"}}}
      assert_receive {^port, {:data, {:eol, "UNLISTED:"}}}

      Port.command(port, "hello\n")
      assert_receive {^port, {:data, {:eol, "INPUT:hello"}}}

      ProcessSupervisor.stop(process)
    after
      File.rm_rf(test_root)
      restore_env(unlisted_key, previous_unlisted)
    end
  end

  test "rejects invalid cleanup before spawning a process" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-process-supervisor-invalid-cleanup-#{System.unique_integer([:positive])}")

    try do
      fake_binary = Path.join(test_root, "fake-runner")
      started_file = Path.join(test_root, "started")

      File.mkdir_p!(test_root)

      File.write!(fake_binary, """
      #!/bin/sh
      touch "#{started_file}"
      while :; do
        sleep 1
      done
      """)

      File.chmod!(fake_binary, 0o755)

      assert {:error, {:invalid_cleanup, :invalid}} = ProcessSupervisor.start([fake_binary], cleanup: :invalid)
      refute File.exists?(started_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "from_port rejects invalid cleanup mode" do
    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :binary,
        :exit_status,
        args: [~c"-c", ~c"while :; do sleep 1; done"]
      ])

    try do
      assert_raise ArgumentError, "invalid cleanup mode: :invalid", fn ->
        ProcessSupervisor.from_port(port, cleanup: :invalid)
      end
    after
      Port.close(port)
    end
  end

  test "from_port transfers ownership from the caller and forwards commands and output" do
    caller = self()

    tracer =
      spawn(fn ->
        receive do
          message -> send(caller, message)
        end
      end)

    port = Port.open({:spawn_executable, ~c"/bin/cat"}, [:binary, :exit_status])

    :erlang.trace_pattern({:erlang, :port_connect, 2}, true, [])
    :erlang.trace(caller, true, [:call, {:tracer, tracer}])

    process =
      try do
        ProcessSupervisor.from_port(port)
      after
        :erlang.trace(caller, false, [:call])
        :erlang.trace_pattern({:erlang, :port_connect, 2}, false, [])
      end

    owner = process.owner

    try do
      assert_receive {:trace, ^caller, :call, {:erlang, :port_connect, [^port, ^owner]}}
      assert {:connected, ^owner} = Port.info(port, :connected)
      assert Port.command(port, "adopted\n")
      assert_receive {^port, {:data, "adopted\n"}}

      owner_monitor = Process.monitor(owner)
      assert :ok = ProcessSupervisor.stop(process)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _reason}
    after
      ProcessSupervisor.kill(process)
    end
  end

  test "forwards exit status and terminates lifecycle owner after normal exit" do
    assert {:ok, process} = ProcessSupervisor.start(["/bin/sh", "-c", "exit 7"])
    port = process.port
    owner = process.owner
    owner_monitor = Process.monitor(owner)
    on_exit(fn -> Process.exit(owner, :kill) end)

    assert_receive {^port, {:exit_status, 7}}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _reason}
  end

  test "runner exit reaps descendants before publishing exit status" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-process-supervisor-runner-exit-#{System.unique_integer([:positive])}"
      )

    try do
      fake_binary = Path.join(test_root, "fake-runner")
      child_pid_file = Path.join(test_root, "child.pid")
      File.mkdir_p!(test_root)

      File.write!(fake_binary, """
      #!/usr/bin/env python3
      import os
      import subprocess
      import sys

      child = subprocess.Popen(
          ["sleep", "60"],
          stdin=subprocess.DEVNULL,
          stdout=subprocess.DEVNULL,
          stderr=subprocess.DEVNULL,
          close_fds=True,
      )
      with open("#{child_pid_file}", "w", encoding="utf-8") as file:
          file.write(str(child.pid))
      sys.stdin.readline()
      os._exit(7)
      """)

      File.chmod!(fake_binary, 0o755)
      assert {:ok, process} = ProcessSupervisor.start([fake_binary])
      child_pid = eventually(fn -> read_pid(child_pid_file) end)
      assert os_pid_alive?(child_pid)

      port = process.port
      Port.command(port, "exit\n")
      assert_receive {^port, {:exit_status, 7}}, 3_000
      assert eventually(fn -> if os_pid_alive?(child_pid), do: nil, else: :stopped end) == :stopped
    after
      File.rm_rf(test_root)
    end
  end

  test "from_port reports adoption failure for a closed port" do
    port = Port.open({:spawn_executable, ~c"/bin/cat"}, [:binary, :exit_status])
    Port.close(port)

    assert_raise ArgumentError, ~r/failed to adopt port:/, fn ->
      ProcessSupervisor.from_port(port)
    end

    assert :undefined = :erlang.port_info(port)
  end

  test "from_port closes an adopted port when its caller exits" do
    parent = self()

    caller =
      spawn(fn ->
        port = Port.open({:spawn_executable, ~c"/bin/cat"}, [:binary, :exit_status])
        process = ProcessSupervisor.from_port(port, cleanup: :port_only)
        send(parent, {:adopted, port, process.owner})

        receive do
          :never -> :ok
        end
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:adopted, port, owner}
    on_exit(fn -> Process.exit(owner, :kill) end)
    assert {:connected, ^owner} = Port.info(port, :connected)

    Process.exit(caller, :kill)

    assert eventually(fn ->
             if :erlang.port_info(port) == :undefined and not Process.alive?(owner), do: :closed
           end) == :closed
  end

  test "await_startup normalizes response timeout and stops launched process" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-process-supervisor-startup-timeout-#{System.unique_integer([:positive])}")

    try do
      fake_binary = Path.join(test_root, "fake-runner")
      pid_file = Path.join(test_root, "runner.pid")
      child_pid_file = Path.join(test_root, "child.pid")

      File.mkdir_p!(test_root)

      File.write!(fake_binary, """
      #!/bin/sh
      printf '%s\\n' "$$" > "#{pid_file}"
      sleep 60 &
      printf '%s\\n' "$!" > "#{child_pid_file}"
      while :; do
        sleep 1
      done
      """)

      File.chmod!(fake_binary, 0o755)

      assert {:ok, process} = ProcessSupervisor.start([fake_binary])
      os_pid = eventually(fn -> read_pid(pid_file) end)
      child_pid = eventually(fn -> read_pid(child_pid_file) end)
      assert os_pid_alive?(os_pid)
      assert os_pid_alive?(child_pid)

      assert {:error, {:startup_failed, {:timeout, 20}}} =
               ProcessSupervisor.await_startup(process, 20, fn _process, timeout ->
                 receive do
                   :never -> :ok
                 after
                   timeout.() -> {:error, :response_timeout}
                 end
               end)

      assert eventually(fn -> if os_pid_alive?(os_pid), do: nil, else: :stopped end) == :stopped
      assert eventually(fn -> if os_pid_alive?(child_pid), do: nil, else: :stopped end) == :stopped
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

  test "await_startup preserves cleanup failure with the primary error" do
    port = Port.open({:spawn_executable, ~c"/bin/cat"}, [:binary, :exit_status])
    {:os_pid, wrapper_pid} = :erlang.port_info(port, :os_pid)

    process = %ProcessSupervisor{
      port: port,
      os_pid: wrapper_pid,
      process_group_id: nil,
      wrapper_pid: wrapper_pid,
      owner: nil,
      cleanup: :process_group
    }

    assert {:error, {:startup_failed, :not_ready, {:process_cleanup_failed, cleanup_evidence}}} =
             ProcessSupervisor.await_startup(process, 100, fn _process, _timeout ->
               {:error, :not_ready}
             end)

    assert cleanup_evidence == %{process_group_id: nil, reason: :group_identity_lost}

    assert :undefined = :erlang.port_info(port)
  end

  test "stop terminates descendant processes" do
    if ProcessSupervisor.descendant_cleanup_supported?() do
      do_descendant_cleanup_test()
    else
      assert ProcessSupervisor.descendant_cleanup_supported?() == false
    end
  end

  test "stop escalates from TERM to KILL while the port remains live" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-process-supervisor-stop-escalation-#{System.unique_integer([:positive])}")

    try do
      fake_binary = Path.join(test_root, "term-resistant-runner")
      pid_file = Path.join(test_root, "runner.pid")
      term_file = Path.join(test_root, "runner.term")

      File.mkdir_p!(test_root)

      File.write!(fake_binary, """
      #!/bin/sh
      trap 'printf "TERM\\n" > "#{term_file}"' TERM
      printf '%s\\n' "$$" > "#{pid_file}"

      remaining=30
      while [ "$remaining" -gt 0 ]; do
        sleep 1
        remaining=$((remaining - 1))
      done
      """)

      File.chmod!(fake_binary, 0o755)

      assert {:ok, process} = ProcessSupervisor.start([fake_binary])
      os_pid = eventually(fn -> read_pid(pid_file) end)
      assert os_pid_alive?(os_pid)

      assert :ok = ProcessSupervisor.stop(process)

      assert eventually(fn -> if File.exists?(term_file), do: :term_received end) == :term_received
      refute os_pid_alive?(os_pid)
    after
      File.rm_rf(test_root)
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

  test "kill ignores cached OS PID after port and owner terminate" do
    {stale_process, sentinel_port, sentinel_os_pid} = stale_process_with_sentinel()

    try do
      assert os_pid_alive?(sentinel_os_pid)

      ProcessSupervisor.kill(stale_process)

      assert os_pid_alive?(sentinel_os_pid)
    after
      close_live_port(sentinel_port)
    end
  end

  test "repeated stop ignores cached OS PID after port and owner terminate" do
    {stale_process, sentinel_port, sentinel_os_pid} = stale_process_with_sentinel()

    try do
      assert os_pid_alive?(sentinel_os_pid)

      ProcessSupervisor.stop(stale_process)
      assert os_pid_alive?(sentinel_os_pid)

      ProcessSupervisor.stop(stale_process)
      assert os_pid_alive?(sentinel_os_pid)
    after
      close_live_port(sentinel_port)
    end
  end

  test "stops the root and descendants when the launching process exits" do
    if ProcessSupervisor.descendant_cleanup_supported?() do
      test_root =
        Path.join(System.tmp_dir!(), "symphony-process-supervisor-owner-death-#{System.unique_integer([:positive])}")

      child_pid_file = Path.join(test_root, "child.pid")
      grandchild_pid_file = Path.join(test_root, "grandchild.pid")
      root_pid_file = Path.join(test_root, "root.pid")
      {:ok, cleanup_agent} = Agent.start(fn -> %{} end)

      on_exit(fn ->
        cleanup_supervisor_test_processes(cleanup_agent)
        Agent.stop(cleanup_agent)
        File.rm_rf(test_root)
      end)

      fake_binary = Path.join(test_root, "fake-runner")
      File.mkdir_p!(test_root)

      File.write!(fake_binary, """
      #!/bin/sh
      printf '%s\\n' "$$" > "#{root_pid_file}"
      /bin/sh -c 'sleep 60 & printf "%s\\n" "$!" > "$1"; wait' child "#{grandchild_pid_file}" &
      printf '%s\\n' "$!" > "#{child_pid_file}"

      while :; do
        sleep 1
      done
      """)

      File.chmod!(fake_binary, 0o755)
      parent = self()

      launcher =
        spawn(fn ->
          receive do
            :launch ->
              assert {:ok, process} = ProcessSupervisor.start([fake_binary])
              Agent.update(cleanup_agent, &Map.put(&1, :process, process))
              send(parent, {:launched, process})

              receive do
                :never -> :ok
              end
          end
        end)

      Agent.update(cleanup_agent, &Map.put(&1, :launcher, launcher))
      send(launcher, :launch)

      assert_receive {:launched, process}
      root_pid = ProcessSupervisor.identity(process).os_pid
      assert eventually(fn -> if read_pid(root_pid_file) == root_pid, do: root_pid, else: nil end) == root_pid
      child_pid = eventually(fn -> read_pid(child_pid_file) end)
      grandchild_pid = eventually(fn -> read_pid(grandchild_pid_file) end)
      assert os_pid_alive?(root_pid)
      assert os_pid_alive?(child_pid)
      assert os_pid_alive?(grandchild_pid)

      Process.exit(launcher, :kill)

      assert eventually(fn -> if os_pid_alive?(root_pid), do: nil, else: :stopped end) == :stopped
      assert eventually(fn -> if os_pid_alive?(child_pid), do: nil, else: :stopped end) == :stopped
      assert eventually(fn -> if os_pid_alive?(grandchild_pid), do: nil, else: :stopped end) == :stopped
    else
      assert ProcessSupervisor.descendant_cleanup_supported?() == false
    end
  end

  defp stale_process_with_sentinel do
    assert {:ok, process} = ProcessSupervisor.start(["/bin/cat"])
    owner_monitor = Process.monitor(process.owner)

    assert :ok = ProcessSupervisor.stop(process)
    assert_receive {:DOWN, ^owner_monitor, :process, owner, :normal}
    assert owner == process.owner
    assert :erlang.port_info(process.port) == :undefined

    sentinel_port = Port.open({:spawn_executable, ~c"/bin/cat"}, [:binary])
    on_exit(fn -> close_live_port(sentinel_port) end)
    assert {:os_pid, sentinel_os_pid} = :erlang.port_info(sentinel_port, :os_pid)

    {%{process | os_pid: sentinel_os_pid}, sentinel_port, sentinel_os_pid}
  end

  defp close_live_port(port) do
    if :erlang.port_info(port) != :undefined do
      Port.close(port)
    end
  end

  defp cleanup_supervisor_test_processes(cleanup_agent) do
    cleanup_state = Agent.get(cleanup_agent, & &1)

    case cleanup_state do
      %{process: %ProcessSupervisor{} = process} -> ProcessSupervisor.kill(process)
      _ -> :ok
    end

    cleanup_state
    |> Map.take([:launcher])
    |> Map.values()
    |> Enum.each(fn pid ->
      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end)
  end

  defp do_descendant_cleanup_test do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-process-supervisor-descendant-cleanup-#{System.unique_integer([:positive])}")

    child_pid_file = Path.join(test_root, "child.pid")
    grandchild_pid_file = Path.join(test_root, "grandchild.pid")

    try do
      fake_binary = Path.join(test_root, "fake-runner")

      File.mkdir_p!(test_root)

      File.write!(fake_binary, """
      #!/bin/sh
      /bin/sh -c 'sleep 60 & printf "%s\\n" "$!" > "$1"; wait' child "#{grandchild_pid_file}" &
      printf '%s\\n' "$!" > "#{child_pid_file}"

      while :; do
        sleep 1
      done
      """)

      File.chmod!(fake_binary, 0o755)

      assert {:ok, process} = ProcessSupervisor.start([fake_binary])
      on_exit(fn -> ProcessSupervisor.kill(process) end)
      root_pid = ProcessSupervisor.identity(process).os_pid
      child_pid = eventually(fn -> read_pid(child_pid_file) end)
      grandchild_pid = eventually(fn -> read_pid(grandchild_pid_file) end)
      assert os_pid_alive?(root_pid)
      assert os_pid_alive?(child_pid)
      assert os_pid_alive?(grandchild_pid)

      ProcessSupervisor.stop(process)

      assert eventually(fn -> if os_pid_alive?(root_pid), do: nil, else: :stopped end) == :stopped
      assert eventually(fn -> if os_pid_alive?(child_pid), do: nil, else: :stopped end) == :stopped
      assert eventually(fn -> if os_pid_alive?(grandchild_pid), do: nil, else: :stopped end) == :stopped
    after
      File.rm_rf(test_root)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
