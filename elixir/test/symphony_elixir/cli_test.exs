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
      set_profile_override: fn _profile ->
        send(parent, :profile_set)
        :ok
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
    refute_received :profile_set
    refute_received :started
  end

  test "defaults to symphony.yml when manifest path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "symphony.yml" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_profile_override: fn _profile -> :ok end,
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
      set_profile_override: fn _profile -> :ok end,
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
      set_profile_override: fn _profile -> :ok end,
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
      set_profile_override: fn _profile -> :ok end,
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
      set_profile_override: fn _profile -> :ok end,
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
      set_profile_override: fn _profile -> :ok end,
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
      set_profile_override: fn _profile -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "symphony.yml"], deps)
  end

  test "accepts one-process profile override" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_profile_override: fn profile ->
        send(parent, {:profile, profile})
        :ok
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--profile", "strict", "symphony.yml"], deps)
    assert_received {:profile, "strict"}
  end

  test "review-records commands list, show, and export without starting the daemon" do
    logs_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-cli-review-records-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(logs_root) end)

    assert {:ok, _record} =
             SymphonyElixir.ReviewRecords.write_quality_gate_run(%{
               logs_root: logs_root,
               project: %{slug: "symphony"},
               issue: %{id: "issue-320", identifier: "SID-320"},
               workflow: %{profile: "default", policy_ref: "640c639998cf", target: "main"},
               run: %{id: "run-320", session_id: "run-320", completed_at: "2026-06-11T16:05:00Z"},
               quality_gate: %{
                 status: :passed,
                 planner: %{changed_files: ["lib/source.ex"], changed_surfaces: [:workflow], jobs: []},
                 jobs: [
                   %{
                     id: "source_correctness:initial",
                     category: :source_correctness,
                     status: :passed,
                     execution: :executed,
                     findings: []
                   }
                 ],
                 synthesis: %{status: :passed, findings: []},
                 repair_passes: []
               },
               handoff_route: %{route: "human_review", target_state: "Human Review", summary: "Ready for review."}
             })

    deps = %{
      file_regular?: fn _path -> flunk("review-records should not check manifest files") end,
      set_workflow_file_path: fn _path -> flunk("review-records should not set workflow files") end,
      set_logs_root: fn _path -> flunk("review-records should not start daemon logging") end,
      set_server_port_override: fn _port -> flunk("review-records should not set server ports") end,
      set_profile_override: fn _profile -> flunk("review-records should not set profiles") end,
      ensure_all_started: fn -> flunk("review-records should not start the application") end
    }

    assert {:ok, list_output} = CLI.evaluate(["review-records", "list", "--logs-root", logs_root], deps)
    assert list_output =~ "SID-320"
    assert list_output =~ "run-320"

    assert {:ok, show_output} = CLI.evaluate(["review-records", "show", "run-320", "--logs-root", logs_root], deps)
    assert show_output =~ "Review record run-320"
    assert show_output =~ "Quality gate: passed"
    refute show_output =~ System.tmp_dir!()

    assert {:ok, export_output} = CLI.evaluate(["review-records", "export", "--logs-root", logs_root], deps)
    assert export_output =~ "# Symphony Quality-Gate Retrospective Input"
    assert export_output =~ "Records: 1"
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
    """)

    assert {:error, output} = CLI.evaluate(["workflow", "check", "--repo", repo])
    assert output =~ "Workflow check failed"
    assert output =~ "workflow.modules[0]"
    assert output =~ "missing.module"
    assert output =~ "docs.entrypoints[0]"
    assert output =~ "AGENTS.md"
    assert output =~ "harness.codex_home"
    assert output =~ ".symphony/codex-home"
  end

  test "workflow check rejects docs paths that escape the repo" do
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
    """)

    assert {:error, output} = CLI.evaluate(["workflow", "check", "--repo", repo])
    assert output =~ "docs.entrypoints[0]"
    assert output =~ "must stay inside the repo"
  end

  test "workflow check rejects missing publish repository and explicit PR target" do
    repo = tmp_repo!("symphony-elixir-check-missing-publish-target")

    File.write!(Path.join(repo, "symphony.yml"), """
    version: 1
    project:
      name: missing-publish-target
      kind: elixir
      app_kind: web
    workflow:
      preset: default
    vcs:
      mode: jj
      default_branch: main
    automation:
      posture: unattended
    """)

    assert {:error, output} = CLI.evaluate(["workflow", "check", "--repo", repo])
    assert output =~ "Workflow check failed"
    assert output =~ "project.repository"
    assert output =~ "is required for publish handoff"
    assert output =~ "delivery.pr_target"
    assert output =~ "Set `delivery.pr_target` to the PR base branch"
  end

  test "workflow check rejects incompatible publish repository and ambiguous PR target" do
    repo = tmp_repo!("symphony-elixir-check-bad-publish-target")

    File.write!(Path.join(repo, "symphony.yml"), """
    version: 1
    project:
      name: bad-publish-target
      repository: https://gitlab.com/example/target-repo
      kind: elixir
      app_kind: web
    workflow:
      preset: default
    delivery:
      pr_target: origin/main
    automation:
      posture: unattended
    """)

    assert {:error, output} = CLI.evaluate(["workflow", "check", "--repo", repo])
    assert output =~ "project.repository"
    assert output =~ "must be a GitHub repository URL for publish handoff"
    assert output =~ "delivery.pr_target"
    assert output =~ "must be an unambiguous branch name for publish handoff"
    assert output =~ "origin/main"
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

  test "workflow check passes for a ready manifest" do
    repo = tmp_repo!("symphony-elixir-check-success")
    File.write!(Path.join(repo, "README.md"), "repo docs\n")
    File.write!(Path.join(repo, "AGENTS.md"), "repo instructions\n")
    File.mkdir_p!(Path.join([repo, ".symphony", "codex-home"]))
    File.write!(Path.join([repo, ".symphony", "codex-home", "AGENTS.md"]), "harness\n")

    assert {:ok, _output} = CLI.evaluate(["workflow", "init", "--repo", repo])
    set_publish_repository!(repo, "https://github.com/example/ready-repo")
    assert {:ok, output} = CLI.evaluate(["workflow", "check", "--repo", repo])

    assert output =~ "Workflow check passed"
    assert output =~ "preset: default"
    assert output =~ "modules:"
    assert output =~ "tracker.linear"
    assert output =~ "publish target:"
    assert output =~ "repository: https://github.com/example/ready-repo"
    assert output =~ "resolved: example/ready-repo:main"
    assert output =~ "harness.codex_home: managed default"
  end

  test "committed root symphony.yml validates and compiles through the daemon loader" do
    repo = repo_root!()

    assert {:ok, output} = CLI.evaluate(["workflow", "check", "--repo", repo])
    assert output =~ "Workflow check passed"
    assert output =~ "resolved: apontarelli/symphony:main"

    assert {:ok, %{config: config, prompt: prompt}} = Manifest.load(Path.join(repo, "symphony.yml"))
    assert config["manifest"]["project"]["name"] == "Symphony"
    assert config["publish_target"]["display"] == "apontarelli/symphony:main"
    refute config["publish_target"]["display"] == "openai/symphony:main"
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
    set_publish_repository!(repo, "https://github.com/example/print-repo")

    assert {:ok, output} = CLI.evaluate(["workflow", "print", "--repo", repo])
    assert output =~ "Resolved workflow"
    assert output =~ "preset: default"
    assert output =~ "repo.docs"
    assert output =~ "publish target:"
    assert output =~ "resolved: example/print-repo:main"

    assert {:ok, compiled_output} = CLI.evaluate(["workflow", "print", "--repo", repo, "--compiled"])
    assert compiled_output =~ "Compiled workflow"
    assert compiled_output =~ "publish_target:"
    assert compiled_output =~ "display: \"example/print-repo:main\""
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

  defp set_publish_repository!(repo, repository) do
    manifest_path = Path.join(repo, "symphony.yml")
    {:ok, manifest} = YamlElixir.read_from_file(manifest_path)
    manifest = put_in(manifest, ["project", "repository"], repository)
    File.write!(manifest_path, Renderer.to_yaml(manifest))
  end

  defp repo_root!, do: Path.expand("../../..", __DIR__)
end
