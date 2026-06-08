defmodule SymphonyElixir.CLITest do
  use ExUnit.Case

  alias SymphonyElixir.CLI
  alias SymphonyElixir.Workflow.{Manifest, Renderer}

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

  test "workflow init creates a thin manifest from repo inspection" do
    repo = tmp_repo!("symphony-elixir-init")
    File.write!(Path.join(repo, "README.md"), "repo docs\n")
    File.write!(Path.join(repo, "AGENTS.md"), "repo instructions\n")
    File.write!(Path.join(repo, "mix.exs"), "defmodule Example.MixProject do\nend\n")

    assert {:ok, output} = CLI.evaluate(["workflow", "init", "--repo", repo])
    assert output =~ "Created symphony.yml"

    manifest_path = Path.join(repo, "symphony.yml")
    assert File.regular?(manifest_path)
    assert {:ok, manifest} = YamlElixir.read_from_file(manifest_path)
    assert manifest["version"] == 1
    assert manifest["project"]["kind"] == "elixir"
    assert manifest["workflow"]["preset"] == "default"
    assert manifest["workflow"]["modules"] == []
    assert manifest["docs"]["entrypoints"] == ["AGENTS.md", "README.md"]
    assert [%{"name" => "test", "command" => "mix test"}] = manifest["validation"]["commands"]
  end

  test "workflow init preserves an intentional existing manifest unless forced" do
    repo = tmp_repo!("symphony-elixir-init-existing")
    manifest_path = Path.join(repo, "symphony.yml")
    existing_manifest = "version: 1\nproject:\n  name: custom-name\nworkflow:\n  preset: default\n"
    File.write!(manifest_path, existing_manifest)

    assert {:ok, output} = CLI.evaluate(["workflow", "init", "--repo", repo])
    assert output =~ "left unchanged"
    assert File.read!(manifest_path) == existing_manifest

    assert {:ok, output} = CLI.evaluate(["workflow", "init", "--repo", repo, "--force"])
    assert output =~ "Replaced symphony.yml"
    refute File.read!(manifest_path) == existing_manifest
  end

  test "workflow check fails with actionable module and harness problems" do
    repo = tmp_repo!("symphony-elixir-check-failure")

    File.write!(Path.join(repo, "symphony.yml"), """
    version: 1
    project:
      name: broken
      kind: elixir
      app_kind: local
    workflow:
      preset: default
      modules:
        - missing.module
    docs:
      entrypoints:
        - AGENTS.md
    validation:
      commands:
        - name: test
          command: mix test
    vcs:
      mode: jj
    delivery:
      pr_target: main
    automation:
      posture: unattended
    harness:
      codex_home: .symphony/codex-home
    bindings:
      local_file: .symphony.local.yml
      require_local: true
    """)

    assert {:error, output} = CLI.evaluate(["workflow", "check", "--repo", repo])
    assert output =~ "Workflow check failed"
    assert output =~ "workflow.modules[0]"
    assert output =~ "missing.module"
    assert output =~ "docs.entrypoints[0]"
    assert output =~ "AGENTS.md"
    assert output =~ "harness.codex_home"
    assert output =~ ".symphony/codex-home"
    assert output =~ "bindings.local_file"
  end

  test "workflow check rejects docs and binding paths that escape the repo" do
    repo = tmp_repo!("symphony-elixir-check-path-escape")
    File.write!(Path.join(repo, "AGENTS.md"), "repo instructions\n")

    File.write!(Path.join(repo, "symphony.yml"), """
    version: 1
    project:
      name: escaping
      kind: generic
      app_kind: local
    workflow:
      preset: default
      modules: []
    docs:
      entrypoints:
        - ../AGENTS.md
    validation:
      commands: []
    vcs:
      mode: none
    delivery:
      pr_target: main
    automation:
      posture: unattended
    harness:
      codex_home: null
    bindings:
      local_file: ../.symphony.local.yml
      require_local: false
    """)

    assert {:error, output} = CLI.evaluate(["workflow", "check", "--repo", repo])
    assert output =~ "docs.entrypoints[0]"
    assert output =~ "must stay inside the repo"
    assert output =~ "bindings.local_file"
  end

  test "workflow check gives setup remediation when manifest is missing or malformed" do
    repo = tmp_repo!("symphony-elixir-check-missing")

    assert {:error, output} = CLI.evaluate(["workflow", "check", "--repo", repo])
    assert output =~ "symphony.yml not found"
    assert output =~ "symphony workflow init --repo"

    File.write!(Path.join(repo, "symphony.yml"), "version: [\n")

    assert {:error, output} = CLI.evaluate(["workflow", "check", "--repo", repo])
    assert output =~ "Failed to parse symphony.yml"
    assert output =~ "symphony workflow init --force"
  end

  test "workflow check passes for a ready manifest and local binding file" do
    repo = tmp_repo!("symphony-elixir-check-success")
    File.write!(Path.join(repo, "README.md"), "repo docs\n")
    File.write!(Path.join(repo, "AGENTS.md"), "repo instructions\n")
    File.mkdir_p!(Path.join([repo, ".symphony", "codex-home"]))
    File.write!(Path.join([repo, ".symphony", "codex-home", "AGENTS.md"]), "harness\n")
    File.write!(Path.join(repo, ".symphony.local.yml"), "linear:\n  project_slug: local-project\n")

    assert {:ok, _output} = CLI.evaluate(["workflow", "init", "--repo", repo])
    assert {:ok, output} = CLI.evaluate(["workflow", "check", "--repo", repo])

    assert output =~ "Workflow check passed"
    assert output =~ "preset: default"
    assert output =~ "modules:"
    assert output =~ "tracker.linear"
    assert output =~ "harness.codex_home: managed default"
  end

  test "committed root symphony.yml validates and compiles through the daemon loader" do
    repo = repo_root!()

    assert {:ok, output} = CLI.evaluate(["workflow", "check", "--repo", repo])
    assert output =~ "Workflow check passed"

    assert {:ok, %{config: config, prompt: prompt}} = Manifest.load(Path.join(repo, "symphony.yml"))
    assert config["manifest"]["project"]["name"] == "Symphony"
    assert config["checks"] == [%{"name" => "all", "command" => "cd elixir && mise exec -- make all"}]
    assert config["policy_metadata"]["source"] == "symphony_manifest"
    assert prompt =~ "You are working on a Linear ticket"
    assert prompt =~ "## Core Workflow Modules"
  end

  test "workflow print shows resolved modules and can include compiled workflow output" do
    repo = tmp_repo!("symphony-elixir-print")
    File.write!(Path.join(repo, "README.md"), "repo docs\n")
    File.write!(Path.join(repo, "AGENTS.md"), "repo instructions\n")

    assert {:ok, _output} = CLI.evaluate(["workflow", "init", "--repo", repo])

    assert {:ok, output} = CLI.evaluate(["workflow", "print", "--repo", repo])
    assert output =~ "Resolved workflow"
    assert output =~ "preset: default"
    assert output =~ "repo.docs"

    assert {:ok, compiled_output} = CLI.evaluate(["workflow", "print", "--repo", repo, "--compiled"])
    assert compiled_output =~ "Compiled workflow"
    assert compiled_output =~ "tracker:"
    assert compiled_output =~ "You are working on a Linear ticket"
    assert compiled_output =~ "## Core Workflow Modules"
    assert compiled_output =~ "Docs entrypoints:"
    refute compiled_output =~ "harness_codex_home"
  end

  test "workflow print compiled renders the real compiled workflow for the repo manifest" do
    repo = repo_root!()

    assert {:ok, compiled} = Manifest.load(Path.join(repo, "symphony.yml"))
    assert {:ok, output} = CLI.evaluate(["workflow", "print", "--repo", repo, "--compiled"])

    assert output =~ "Compiled workflow"
    assert output =~ Renderer.to_yaml(compiled.config)
    assert output =~ compiled.prompt
    refute output =~ "$LINEAR_PROJECT_SLUG"
  end

  defp tmp_repo!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp repo_root!, do: Path.expand("../../..", __DIR__)
end
