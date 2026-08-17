defmodule SymphonyElixir.SSHTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SSH

  test "parse_target/1 preserves every supported SSH destination form" do
    assert SSH.parse_target("worker.example") ==
             {:ok, %{destination: "worker.example", port: nil}}

    assert SSH.parse_target(" worker.example ") ==
             {:ok, %{destination: "worker.example", port: nil}}

    assert SSH.parse_target("worker.example:2200") ==
             {:ok, %{destination: "worker.example", port: "2200"}}

    assert SSH.parse_target("build+gpu") ==
             {:ok, %{destination: "build+gpu", port: nil}}

    assert SSH.parse_target("_worker") ==
             {:ok, %{destination: "_worker", port: nil}}

    assert SSH.parse_target("_deploy@worker") ==
             {:ok, %{destination: "_deploy@worker", port: nil}}

    assert SSH.parse_target("build+gpu:2200") ==
             {:ok, %{destination: "build+gpu", port: "2200"}}

    assert SSH.parse_target("build+ci@worker.example") ==
             {:ok, %{destination: "build+ci@worker.example", port: nil}}

    assert SSH.parse_target("worker.example.") ==
             {:ok, %{destination: "worker.example.", port: nil}}

    assert SSH.parse_target("worker.example.:2200") ==
             {:ok, %{destination: "worker.example.", port: "2200"}}

    assert SSH.parse_target("root@127.0.0.1:2200") ==
             {:ok, %{destination: "root@127.0.0.1", port: "2200"}}

    assert SSH.parse_target("ssh://root@worker.example:2200") ==
             {:ok, %{destination: "root@worker.example", port: "2200"}}

    assert SSH.parse_target("root@[::1]:2200") ==
             {:ok, %{destination: "root@[::1]", port: "2200"}}

    assert SSH.parse_target("root@[::1]") ==
             {:ok, %{destination: "root@[::1]", port: nil}}

    assert SSH.parse_target("root@2001:db8::1") ==
             {:ok, %{destination: "root@2001:db8::1", port: nil}}
  end

  test "parse_target/1 rejects unsafe destinations and invalid ports secret-safely" do
    secret = "ssh-secret-407"

    for target <- [
          "",
          " ",
          "-oProxyCommand=#{secret}",
          "-F::",
          "-E::",
          "root@-F::",
          "worker host",
          "worker;#{secret}",
          "worker\n#{secret}",
          ".worker.example.",
          "worker..example.",
          "worker.example..",
          "worker.-example.",
          "worker.example-.",
          "worker:0",
          "worker:65536",
          "worker:notaport",
          "root@[::1]:0",
          "root@[not-ipv6]",
          "[2001:db8:::1]",
          "fe80::1%lo0%eth0",
          "fe80::1%bad/zone",
          "fe80::1%#{String.duplicate("a", 64)}",
          <<0xFF>>,
          "ssh://",
          "ssh://-F::",
          "ssh://root@-E::",
          "ssh://root:password@worker.example:2200",
          "ssh://root@worker.example:0",
          "ssh://root@worker.example:65536",
          "ssh://root@worker.example:notaport",
          "ssh://root@worker.example/path",
          "ssh://root@worker.example?proxy=#{secret}",
          "ssh://root@worker.example##{secret}",
          "http://root@worker.example:2200",
          407
        ] do
      result = SSH.parse_target(target)
      assert result == {:error, :invalid_target}
      refute inspect(result) =~ secret
    end
  end

  test "parse_target/1 preserves scoped IPv6 destinations" do
    assert SSH.parse_target("fe80::1%lo0") ==
             {:ok, %{destination: "fe80::1%lo0", port: nil}}

    assert SSH.parse_target("[fe80::1%lo0]:2200") ==
             {:ok, %{destination: "[fe80::1%lo0]", port: "2200"}}
  end

  test "run/3 rejects option-shaped destinations before invoking ssh" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-option-target-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    for target <- ["-F::", "-E::"] do
      assert {:error, :invalid_target} = SSH.run(target, "printf should-not-run")
      refute File.exists?(trace_file)
    end
  end

  test "run/3 passes an opaque destination as one argument" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-opaque-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGC:%s\n' "$#" >> "#{trace_file}"
    index=1
    for arg do
      printf 'ARG%s:%s\n' "$index" "$arg" >> "#{trace_file}"
      index=$((index + 1))
    done
    exit 0
    """)

    System.delete_env("SYMPHONY_SSH_CONFIG")

    for target <- ["build+ci@worker.example", "_worker", "_deploy@worker"] do
      assert {:ok, {"", 0}} = SSH.run(target, "printf ok", stderr_to_stdout: true)
    end

    trace = File.read!(trace_file)
    assert trace =~ "ARGC:3\n"
    assert trace =~ "ARG1:-T\nARG2:build+ci@worker.example\nARG3:bash -lc"
    assert trace =~ "ARG1:-T\nARG2:_worker\nARG3:bash -lc"
    assert trace =~ "ARG1:-T\nARG2:_deploy@worker\nARG3:bash -lc"
  end

  test "run/3 keeps bracketed IPv6 host:port targets intact" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@[::1]:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@[::1] bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 leaves unbracketed IPv6-style targets unchanged" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-raw-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("::1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T ::1:2200 bash -lc"
    refute trace =~ "-p 2200"
  end

  test "run/3 passes host:port targets through ssh -p" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)
    System.put_env("SYMPHONY_SSH_CONFIG", "/tmp/symphony-test-ssh-config")

    assert {:ok, {"", 0}} =
             SSH.run("localhost:2222", "echo ready", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-F /tmp/symphony-test-ssh-config"
    assert trace =~ "-T -p 2222 localhost bash -lc"
    assert trace =~ "echo ready"
  end

  test "run/3 normalizes an SSH URI into separate destination and port arguments" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-uri-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)
    System.delete_env("SYMPHONY_SSH_CONFIG")

    assert {:ok, {"", 0}} =
             SSH.run("ssh://root@worker.example:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "ARGV:-T -p 2200 root@worker.example bash -lc"
    refute trace =~ "ssh://"
    refute trace =~ "-F"
    refute trace =~ "-E"
  end

  test "run/3 keeps the user prefix when parsing user@host:port targets" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-user-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@127.0.0.1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@127.0.0.1 bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 returns an error when ssh is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-missing-test-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("PATH", test_root)

    assert {:error, :ssh_not_found} = SSH.run("localhost", "printf ok")
  end

  test "start_port/3 supports binary output without line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    System.delete_env("SYMPHONY_SSH_CONFIG")

    assert {:ok, port} = SSH.start_port("localhost", "printf ok")
    assert is_port(port)
    wait_for_trace!(trace_file)

    trace = File.read!(trace_file)
    assert trace =~ "-T localhost bash -lc"
    refute trace =~ " -F "
  end

  test "start_port/3 supports line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-line-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    assert {:ok, port} = SSH.start_port("localhost:2222", "printf ok", line: 256)
    assert is_port(port)
    wait_for_trace!(trace_file)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2222 localhost bash -lc"
  end

  test "remote_shell_command/1 escapes embedded single quotes" do
    assert SSH.remote_shell_command("printf 'hello'") ==
             "bash -lc 'printf '\"'\"'hello'\"'\"''"
  end

  defp install_fake_ssh!(test_root, trace_file, script \\ nil) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")

    File.mkdir_p!(fake_bin_dir)

    File.write!(
      fake_ssh,
      script ||
        """
        #!/bin/sh
        printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
        exit 0
        """
    )

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end

  defp wait_for_trace!(trace_file, attempts \\ 20)
  defp wait_for_trace!(trace_file, 0), do: flunk("timed out waiting for fake ssh trace at #{trace_file}")

  defp wait_for_trace!(trace_file, attempts) do
    if File.exists?(trace_file) and File.read!(trace_file) != "" do
      :ok
    else
      Process.sleep(25)
      wait_for_trace!(trace_file, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
