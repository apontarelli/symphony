defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      set_linear_profile_bindings: fn _bindings ->
        send(parent, :bindings_set)
        :ok
      end,
      set_linear_profile_bindings_source_path: fn _path, _explicit? ->
        send(parent, :bindings_source_set)
        :ok
      end,
      set_profile_override: fn _profile ->
        send(parent, :profile_set)
        :ok
      end,
      load_linear_profile_bindings: fn _path ->
        send(parent, :bindings_loaded)
        {:ok, %{}}
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["symphony.yml"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :bindings_set
    refute_received :bindings_source_set
    refute_received :profile_set
    refute_received :bindings_loaded
    refute_received :started
  end

  test "defaults to symphony.yml when manifest path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "symphony.yml" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_linear_profile_bindings: fn _bindings -> :ok end,
      set_linear_profile_bindings_source_path: fn _path, _explicit? -> :ok end,
      set_profile_override: fn _profile -> :ok end,
      load_linear_profile_bindings: fn _path -> {:ok, %{}} end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses symphony.yml as the only default manifest" do
    parent = self()
    manifest_path = Path.expand("symphony.yml")

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == manifest_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_linear_profile_bindings: fn _bindings -> :ok end,
      set_linear_profile_bindings_source_path: fn _path, _explicit? -> :ok end,
      set_profile_override: fn _profile -> :ok end,
      load_linear_profile_bindings: fn _path -> {:ok, %{}} end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
    assert_received {:workflow_checked, ^manifest_path}
    assert_received {:workflow_set, ^manifest_path}
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/symphony.yml"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_linear_profile_bindings: fn _bindings -> :ok end,
      set_linear_profile_bindings_source_path: fn _path, _explicit? -> :ok end,
      set_profile_override: fn _profile -> :ok end,
      load_linear_profile_bindings: fn _path -> {:ok, %{}} end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      set_linear_profile_bindings: fn _bindings -> :ok end,
      set_linear_profile_bindings_source_path: fn _path, _explicit? -> :ok end,
      set_profile_override: fn _profile -> :ok end,
      load_linear_profile_bindings: fn _path -> {:ok, %{}} end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "symphony.yml"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when manifest file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_linear_profile_bindings: fn _bindings -> :ok end,
      set_linear_profile_bindings_source_path: fn _path, _explicit? -> :ok end,
      set_profile_override: fn _profile -> :ok end,
      load_linear_profile_bindings: fn _path -> {:ok, %{}} end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "symphony.yml"], deps)
    assert message =~ "Manifest file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_linear_profile_bindings: fn _bindings -> :ok end,
      set_linear_profile_bindings_source_path: fn _path, _explicit? -> :ok end,
      set_profile_override: fn _profile -> :ok end,
      load_linear_profile_bindings: fn _path -> {:ok, %{}} end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "symphony.yml"], deps)
    assert message =~ "Failed to start Symphony with manifest"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_linear_profile_bindings: fn _bindings -> :ok end,
      set_linear_profile_bindings_source_path: fn _path, _explicit? -> :ok end,
      set_profile_override: fn _profile -> :ok end,
      load_linear_profile_bindings: fn _path -> {:ok, %{}} end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "symphony.yml"], deps)
  end

  test "accepts external Linear bindings and one-process profile override" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_linear_profile_bindings: fn bindings ->
        send(parent, {:bindings, bindings})
        :ok
      end,
      set_linear_profile_bindings_source_path: fn path, explicit? ->
        send(parent, {:bindings_source, path, explicit?})
        :ok
      end,
      set_profile_override: fn profile ->
        send(parent, {:profile, profile})
        :ok
      end,
      load_linear_profile_bindings: fn path ->
        send(parent, {:bindings_path, path})
        {:ok, %{"projects" => [%{"project_slug" => "project-a", "profile" => "strict"}]}}
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok =
             CLI.evaluate(
               [@ack_flag, "--linear-bindings", "ops/bindings.yml", "--profile", "strict", "symphony.yml"],
               deps
             )

    assert_received {:bindings_path, expanded_path}
    assert expanded_path == Path.expand("ops/bindings.yml")
    assert_received {:bindings_source, ^expanded_path, true}
    assert_received {:bindings, %{"projects" => [%{"project_slug" => "project-a", "profile" => "strict"}]}}
    assert_received {:profile, "strict"}
  end

  test "loads default local Linear bindings next to the manifest" do
    parent = self()
    workflow_path = Path.expand("tmp/project/symphony.yml")
    default_bindings_path = Path.expand("tmp/project/linear-profile-bindings.local.yml")

    deps = %{
      file_regular?: fn path ->
        path in [workflow_path, default_bindings_path]
      end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_linear_profile_bindings: fn bindings ->
        send(parent, {:bindings, bindings})
        :ok
      end,
      set_linear_profile_bindings_source_path: fn path, explicit? ->
        send(parent, {:bindings_source, path, explicit?})
        :ok
      end,
      set_profile_override: fn _profile -> :ok end,
      load_linear_profile_bindings: fn path ->
        send(parent, {:bindings_path, path})
        {:ok, %{"projects" => [%{"project_slug" => "project-a", "profile" => "default"}]}}
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:bindings_source, ^default_bindings_path, false}
    assert_received {:bindings_path, ^default_bindings_path}
    assert_received {:bindings, %{"projects" => [%{"project_slug" => "project-a", "profile" => "default"}]}}
  end

  test "skips default local Linear bindings when the file is absent" do
    parent = self()
    workflow_path = Path.expand("tmp/project/symphony.yml")

    deps = %{
      file_regular?: fn path -> path == workflow_path end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_linear_profile_bindings: fn _bindings ->
        send(parent, :bindings_set)
        :ok
      end,
      set_linear_profile_bindings_source_path: fn path, explicit? ->
        send(parent, {:bindings_source, path, explicit?})
        :ok
      end,
      set_profile_override: fn _profile -> :ok end,
      load_linear_profile_bindings: fn _path ->
        send(parent, :bindings_loaded)
        {:ok, %{}}
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    default_bindings_path = Path.expand("tmp/project/linear-profile-bindings.local.yml")
    assert_received {:bindings_source, ^default_bindings_path, false}
    refute_received :bindings_loaded
    refute_received :bindings_set
  end

  test "explicit Linear bindings override the default local bindings path" do
    parent = self()
    workflow_path = Path.expand("tmp/project/symphony.yml")
    explicit_path = Path.expand("tmp/ops/bindings.yml")
    default_bindings_path = Path.expand("tmp/project/linear-profile-bindings.local.yml")

    deps = %{
      file_regular?: fn path ->
        path in [workflow_path, default_bindings_path]
      end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_linear_profile_bindings: fn bindings ->
        send(parent, {:bindings, bindings})
        :ok
      end,
      set_linear_profile_bindings_source_path: fn path, explicit? ->
        send(parent, {:bindings_source, path, explicit?})
        :ok
      end,
      set_profile_override: fn _profile -> :ok end,
      load_linear_profile_bindings: fn path ->
        send(parent, {:bindings_path, path})
        {:ok, %{"projects" => [%{"project_slug" => "project-explicit", "profile" => "strict"}]}}
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--linear-bindings", explicit_path, workflow_path], deps)
    assert_received {:bindings_source, ^explicit_path, true}
    assert_received {:bindings_path, ^explicit_path}
    assert_received {:bindings, %{"projects" => [%{"project_slug" => "project-explicit", "profile" => "strict"}]}}
    refute_received {:bindings_path, ^default_bindings_path}
  end
end
