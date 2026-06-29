defmodule SymphonyElixir.CLITest do
  use ExUnit.Case

  alias SymphonyElixir.CLI
  alias SymphonyElixir.Workflow.{Manifest, Renderer}

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  setup do
    SymphonyElixir.RunSetup.clear_current()
    on_exit(fn -> SymphonyElixir.RunSetup.clear_current() end)
    :ok
  end

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

  test "run command uses the local setup builder without starting the daemon on dry-run" do
    repo = tmp_repo!("symphony-elixir-run")

    File.write!(Path.join(repo, "symphony.yml"), """
    version: 1
    project:
      slug: symphony
      name: Symphony
      repository: https://github.com/apontarelli/symphony
    delivery:
      pr_target: main
    """)

    config_root = Path.join(repo, ".local-symphony")

    deps = %{
      file_regular?: fn _path -> flunk("dry-run local setup should not check a runtime manifest") end,
      set_workflow_file_path: fn _path -> flunk("dry-run local setup should not start the daemon") end,
      set_logs_root: fn _path -> flunk("dry-run local setup should not set logs") end,
      set_server_port_override: fn _port -> flunk("dry-run local setup should not set ports") end,
      set_profile_override: fn _profile -> flunk("dry-run local setup should not set profiles") end,
      ensure_all_started: fn -> flunk("dry-run local setup should not start applications") end,
      local_run_deps: %{home: fn -> repo end, cwd: fn -> repo end}
    }

    assert {:ok, output} =
             CLI.evaluate(["run", "SID-374", "--repo", repo, "--config-root", config_root, "--dry-run"], deps)

    assert output =~ "Run preview"
    assert output =~ "Target: Issues SID-374"
    assert output =~ "Mode: issue-batch"
  end

  test "run command with only repo uses the interactive local setup builder" do
    repo = tmp_repo!("symphony-elixir-run-repo-interactive")

    File.write!(Path.join(repo, "symphony.yml"), """
    version: 1
    project:
      slug: symphony
      name: Symphony
      repository: https://github.com/apontarelli/symphony
    delivery:
      pr_target: main
    """)

    parent = self()
    {:ok, answers} = Agent.start_link(fn -> ["1", "SID-374", "1", "", "n", "n"] end)

    deps = %{
      file_regular?: fn _path -> flunk("interactive local setup should not check a runtime manifest") end,
      set_workflow_file_path: fn _path -> flunk("cancelled local setup should not start the daemon") end,
      set_logs_root: fn _path -> flunk("cancelled local setup should not set logs") end,
      set_server_port_override: fn _port -> flunk("cancelled local setup should not set ports") end,
      set_profile_override: fn _profile -> flunk("cancelled local setup should not set profiles") end,
      ensure_all_started: fn -> flunk("cancelled local setup should not start applications") end,
      local_run_deps: %{
        home: fn -> repo end,
        cwd: fn -> repo end,
        prompt: fn prompt ->
          send(parent, {:prompt, prompt})
          Agent.get_and_update(answers, fn [answer | rest] -> {answer, rest} end)
        end
      }
    }

    assert {:ok, output} = CLI.evaluate(["run", "--repo", repo], deps)
    assert output =~ "Run preview"
    assert output =~ "Target: Issues SID-374"
    assert_received {:prompt, prompt}
    assert prompt =~ "Target type:"
  end

  test "local run startup requires the guardrail acknowledgement" do
    repo = tmp_repo!("symphony-elixir-run-ack")

    File.write!(Path.join(repo, "symphony.yml"), """
    version: 1
    project:
      slug: symphony
      name: Symphony
      repository: https://github.com/apontarelli/symphony
    delivery:
      pr_target: main
    """)

    deps = %{
      file_regular?: fn _path -> flunk("unacknowledged local run should not check a runtime manifest") end,
      set_workflow_file_path: fn _path -> flunk("unacknowledged local run should not start the daemon") end,
      set_logs_root: fn _path -> flunk("unacknowledged local run should not set logs") end,
      set_server_port_override: fn _port -> flunk("unacknowledged local run should not set ports") end,
      set_profile_override: fn _profile -> flunk("unacknowledged local run should not set profiles") end,
      ensure_all_started: fn -> flunk("unacknowledged local run should not start applications") end,
      local_run_deps: %{home: fn -> repo end, cwd: fn -> repo end}
    }

    assert {:error, banner} =
             CLI.evaluate(["run", "SID-374", "--repo", repo, "--config-root", Path.join(repo, ".local-symphony"), "--yes"], deps)

    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ @ack_flag
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

  test "run command resolves a saved setup and creates missing local config on dry run" do
    root = tmp_repo!("symphony-cli-run-config")
    repo = tmp_repo!("symphony-cli-run-target")
    write_cli_repo_manifest!(repo)
    runs_dir = Path.join(root, "runs")
    File.mkdir_p!(runs_dir)

    File.write!(
      Path.join(runs_dir, "dogfood.yml"),
      Renderer.to_yaml(%{
        "repo" => %{"path" => repo},
        "target" => %{"tracker" => %{"project_slug" => "symphony"}},
        "mode" => "unattended",
        "capacity" => "light",
        "restrictive_flags" => %{"required_labels" => ["symphony"]}
      })
    )

    assert {:ok, output} = CLI.evaluate(["run", "dogfood", "--config-root", root, "--dry-run"], daemon_forbidden_deps())
    assert output =~ "Resolved saved run setup dogfood"
    assert output =~ Path.join([root, "runs", "dogfood.yml"])
    assert output =~ "capacity: light"
    assert File.regular?(Path.join(root, "config.yml"))
  end

  test "saved-run dry-run rejects invalid composed runtime config" do
    root = tmp_repo!("symphony-cli-run-config")
    repo = tmp_repo!("symphony-cli-run-target")
    write_cli_repo_manifest!(repo)

    File.mkdir_p!(Path.join(root, "runs"))

    File.write!(
      Path.join(root, "config.yml"),
      SymphonyElixir.LocalConfig.default_config()
      |> put_in(["polling", "interval_ms"], 0)
      |> Renderer.to_yaml()
    )

    File.write!(
      Path.join([root, "runs", "dogfood.yml"]),
      Renderer.to_yaml(%{
        "repo" => %{"path" => repo},
        "target" => %{"tracker" => %{"project_slug" => "symphony"}},
        "mode" => "unattended",
        "capacity" => "light"
      })
    )

    assert {:error, output} = CLI.evaluate(["run", "dogfood", "--config-root", root, "--dry-run"], daemon_forbidden_deps())
    assert output =~ "invalid_manifest"
    assert output =~ "runtime"
    assert output =~ "interval_ms"
  end

  test "usage documents run forms, explicit migration repo, and saved-run acknowledgement" do
    assert {:error, usage} = CLI.evaluate(["--unknown"], daemon_forbidden_deps())
    assert usage =~ "symphony run [target...]"
    assert usage =~ "symphony run <name>"
    assert usage =~ @ack_flag
    assert usage =~ "symphony setup migrate --repo <path>"
    refute usage =~ "setup migrate [--repo"
  end

  test "setup migrate requires an explicit repo" do
    root = tmp_repo!("symphony-cli-migrate")

    assert {:error, message} =
             CLI.evaluate(["setup", "migrate", "--name", "dogfood", "--config-root", root, "--dry-run"], daemon_forbidden_deps())

    assert message == "setup migrate requires --repo <path>."
    refute File.exists?(Path.join(root, "config.yml"))
    refute File.exists?(Path.join([root, "runs", "dogfood.yml"]))
  end

  test "setup migrate dry-run reports moved fields without writing files" do
    root = tmp_repo!("symphony-cli-migrate")
    repo = mixed_manifest_repo!("symphony-cli-migrate-repo")

    assert {:ok, output} =
             CLI.evaluate(["setup", "migrate", "--repo", repo, "--name", "dogfood", "--config-root", root, "--dry-run"], daemon_forbidden_deps())

    assert output =~ "Migration dry run"
    assert output =~ "runtime.tracker.project_slug -> run setup target"
    assert output =~ "runtime.runners.codex.command -> local config"
    refute File.exists?(Path.join(root, "config.yml"))
    refute File.exists?(Path.join([root, "runs", "dogfood.yml"]))
  end

  test "setup migrate apply writes local config and run setup" do
    root = tmp_repo!("symphony-cli-migrate")
    repo = mixed_manifest_repo!("symphony-cli-migrate-repo")

    assert {:ok, output} =
             CLI.evaluate(["setup", "migrate", "--repo", repo, "--name", "dogfood", "--config-root", root, "--apply"], daemon_forbidden_deps())

    assert output =~ "Migration applied"
    assert output =~ Path.join(root, "config.yml")
    assert output =~ Path.join([root, "runs", "dogfood.yml"])
    assert File.regular?(Path.join(root, "config.yml"))
    assert File.regular?(Path.join([root, "runs", "dogfood.yml"]))

    assert {:ok, _workflow} = Manifest.load(Path.join(repo, "symphony.yml"))
  end

  test "setup commands use repo setup language" do
    repo = tmp_repo!("symphony-elixir-setup")
    File.write!(Path.join(repo, "README.md"), "repo docs
")
    File.write!(Path.join(repo, "AGENTS.md"), "repo instructions
")

    assert {:ok, init_output} = CLI.evaluate(["setup", "init", "--repo", repo])
    assert init_output =~ "Created symphony.yml"

    set_publish_repository!(repo, "https://github.com/example/setup-repo")

    assert {:ok, check_output} = CLI.evaluate(["setup", "check", "--repo", repo])
    assert check_output =~ "Repo setup check passed"
    assert check_output =~ "setup: #{Path.join(repo, "symphony.yml")}"
    refute check_output =~ "Workflow check passed"

    assert {:ok, preview_output} = CLI.evaluate(["setup", "preview", "--repo", repo])
    assert preview_output =~ "Resolved repo setup"
    assert preview_output =~ "publish target:"
  end

  test "setup preview relabels only the human summary before compiled workflow output" do
    repo = tmp_repo!("symphony-elixir-setup-compiled")
    File.write!(Path.join(repo, "README.md"), "repo docs\n")
    File.write!(Path.join(repo, "AGENTS.md"), "repo instructions\n")

    assert {:ok, _init_output} = CLI.evaluate(["setup", "init", "--repo", repo])
    set_publish_repository!(repo, "https://github.com/example/setup-compiled-repo")

    assert {:ok, %{config: config}} = Manifest.load(Path.join(repo, "symphony.yml"))
    assert {:ok, output} = CLI.evaluate(["setup", "preview", "--repo", repo, "--compiled"])

    assert output =~ "Resolved repo setup"
    assert output =~ "setup: #{Path.join(repo, "symphony.yml")}"
    assert output =~ "Compiled workflow"
    assert output =~ Renderer.to_yaml(config)
  end

  test "setup preview usage keeps the public preview command spelling" do
    assert {:error, usage} = CLI.evaluate(["setup", "preview", "--unknown"])
    assert usage =~ "symphony setup preview"
    refute usage =~ "symphony setup print"
  end

  test "workflow commands remain available with deprecation guidance" do
    repo = tmp_repo!("symphony-elixir-workflow-deprecated")
    File.write!(Path.join(repo, "README.md"), "repo docs
")
    File.write!(Path.join(repo, "AGENTS.md"), "repo instructions
")

    assert {:ok, _init_output} = CLI.evaluate(["setup", "init", "--repo", repo])
    set_publish_repository!(repo, "https://github.com/example/workflow-repo")

    assert {:ok, output} = CLI.evaluate(["workflow", "check", "--repo", repo])
    assert output =~ "`symphony workflow` is deprecated; use `symphony setup`."
    assert output =~ "Workflow check passed"
  end

  test "run preview renders resolved setup without starting the daemon" do
    runtime_path = tmp_runtime_setup!("symphony-elixir-run-preview", max_concurrent_agents: 4)
    parent = self()

    deps =
      cli_deps(%{
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    assert {:ok, output} =
             CLI.evaluate(
               [
                 "run",
                 "--preview",
                 "--workflow",
                 runtime_path,
                 "--mode",
                 "drain",
                 "--max-agents",
                 "2",
                 "--no-land",
                 "--human-review-only"
               ],
               deps
             )

    assert output =~ "Run preview"
    assert output =~ "repo setup:"
    assert output =~ "runtime setup: #{runtime_path}"
    assert output =~ "run target:"
    assert output =~ "marker intersection:"
    assert output =~ "eligible states: Todo, In Progress, Merging, Rework"
    assert output =~ "mode: drain"
    assert output =~ "max agents: 2 (ceiling: 4)"
    assert output =~ "runner: codex (codex_app_server)"
    assert output =~ "workspace root:"
    assert output =~ "restrictive flags: human_review_only, no_land"
    assert output =~ "source provenance:"
    refute_received :started
  end

  test "run shared runtime switches dispatch to runtime setup when no local target is provided" do
    runtime_path = tmp_runtime_setup!("symphony-elixir-run-shared-switch")
    cwd = Path.dirname(runtime_path)
    parent = self()

    deps =
      cli_deps(%{
        cwd: fn -> cwd end,
        tty?: fn -> true end,
        confirm: fn preview ->
          send(parent, {:previewed, preview})
          true
        end,
        set_server_port_override: fn port ->
          send(parent, {:port, port})
          :ok
        end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    assert :ok = CLI.evaluate(["run", "--port", "4001"], deps)
    assert_received {:previewed, preview}
    assert preview =~ "runtime setup: #{runtime_path}"
    assert_received {:port, 4001}
    assert_received :started
  end

  test "interactive run requires a TTY confirmation after preview" do
    runtime_path = tmp_runtime_setup!("symphony-elixir-run-confirm")
    parent = self()

    deps =
      cli_deps(%{
        tty?: fn -> true end,
        confirm: fn preview ->
          send(parent, {:previewed, preview})
          true
        end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    assert :ok = CLI.evaluate(["run", "--workflow", runtime_path], deps)
    assert_received {:previewed, preview}
    assert preview =~ "Run preview"
    assert_received :started
  end

  test "cancelled interactive run does not apply setup side effects" do
    runtime_path = tmp_runtime_setup!("symphony-elixir-run-cancel")

    deps =
      cli_deps(%{
        tty?: fn -> true end,
        confirm: fn preview ->
          assert preview =~ "Run preview"
          false
        end,
        set_workflow_file_path: fn _path -> flunk("cancelled run should not set workflow path") end,
        set_logs_root: fn _path -> flunk("cancelled run should not set logs root") end,
        set_server_port_override: fn _port -> flunk("cancelled run should not set port") end,
        set_profile_override: fn _profile -> flunk("cancelled run should not set profile") end,
        ensure_all_started: fn -> flunk("cancelled run should not start") end
      })

    assert {:error, output} = CLI.evaluate(["run", "--workflow", runtime_path], deps)
    assert output =~ "Run cancelled."
    assert SymphonyElixir.RunSetup.current() == nil
  after
    SymphonyElixir.RunSetup.clear_current()
  end

  test "non-TTY run refuses to start after rendering preview" do
    runtime_path = tmp_runtime_setup!("symphony-elixir-run-nontty")

    deps =
      cli_deps(%{
        tty?: fn -> false end,
        confirm: fn _preview -> flunk("non-TTY run should not ask for confirmation") end,
        ensure_all_started: fn -> flunk("non-TTY run should not start") end
      })

    assert {:error, output} = CLI.evaluate(["run", "--workflow", runtime_path], deps)
    assert output =~ "Run preview"
    assert output =~ "Interactive confirmation requires a TTY"
  end

  test "capacity overrides above deployment ceilings fail before startup" do
    runtime_path = tmp_runtime_setup!("symphony-elixir-run-capacity", max_concurrent_agents: 2)

    deps =
      cli_deps(%{
        ensure_all_started: fn -> flunk("invalid capacity should not start") end
      })

    assert {:error, output} =
             CLI.evaluate(["run", "--preview", "--workflow", runtime_path, "--max-agents", "3"], deps)

    assert output =~ "capacity override exceeds deployment ceiling"
    assert output =~ "max agents 3 > ceiling 2"
  end

  test "weakening safety flags fail before startup" do
    runtime_path = tmp_runtime_setup!("symphony-elixir-run-weaken")

    deps =
      cli_deps(%{
        ensure_all_started: fn -> flunk("weakening flags should not start") end
      })

    assert {:error, output} =
             CLI.evaluate(["run", "--preview", "--workflow", runtime_path, "--skip-validation"], deps)

    assert output =~ "refusing to weaken repo safety policy"
    assert output =~ "--skip-validation"
  end

  test "bare invocation outside a repo setup directory prints help" do
    cwd = tmp_repo!("symphony-elixir-no-setup")

    assert {:ok, output} = CLI.evaluate([], cli_deps(%{cwd: fn -> cwd end}))
    assert output =~ "Usage:"
    assert output =~ "symphony setup"
    assert output =~ "symphony run"
  end

  test "workflow init creates a thin manifest from repo inspection" do
    repo = tmp_repo!("symphony-elixir-init")
    File.write!(Path.join(repo, "README.md"), "repo docs\n")
    File.write!(Path.join(repo, "PRODUCT.md"), "product doctrine\n")
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
    assert manifest["docs"]["entrypoints"] == ["AGENTS.md", "README.md", "PRODUCT.md"]
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

  test "workflow check rejects legacy runtime codex config" do
    repo = tmp_repo!("symphony-elixir-check-runtime-codex")

    File.write!(Path.join(repo, "symphony.yml"), """
    version: 1
    project:
      name: legacy-runtime
      repository: https://github.com/example/legacy-runtime
    delivery:
      pr_target: main
    runtime:
      codex:
        command: codex app-server
    """)

    assert {:error, output} = CLI.evaluate(["workflow", "check", "--repo", repo])
    assert output =~ "Workflow check failed"
    assert output =~ "runtime.codex"
    assert output =~ "is runtime setup, not repo setup"
    assert output =~ "Move this field to local config or run setup"
  end

  test "workflow check rejects invalid runtime runner schema" do
    repo = tmp_repo!("symphony-elixir-check-runtime-runners")

    File.write!(Path.join(repo, "symphony.yml"), """
    version: 1
    project:
      name: invalid-runtime-runner
      repository: https://github.com/example/invalid-runtime-runner
    delivery:
      pr_target: main
    runtime:
      runners:
        codex:
          kind: codex_app_server
          command: "codex app-server"
    """)

    assert {:error, output} = CLI.evaluate(["workflow", "check", "--repo", repo])
    assert output =~ "Workflow check failed"
    assert output =~ "runtime.runners"
    assert output =~ "is runtime setup, not repo setup"
    assert output =~ "Move this field to local config or run setup"
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
    assert config["agent"]["default_runner"] == "codex"
    assert config["agent"]["max_concurrent_startups"] == 2
    assert get_in(config, ["runners", "codex", "kind"]) == "codex_app_server"

    assert get_in(config, ["runners", "codex", "command"]) == ["codex", "app-server"]

    refute Map.has_key?(config, "codex")
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
    assert compiled_output =~ "default_runner: \"codex\""
    assert compiled_output =~ "runners:"
    assert compiled_output =~ "kind: \"codex_app_server\""
    assert compiled_output =~ "command:"
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

  defp daemon_forbidden_deps do
    %{
      file_regular?: fn _path -> flunk("command should not check daemon manifest paths") end,
      set_workflow_file_path: fn _path -> flunk("command should not set daemon workflow paths") end,
      set_logs_root: fn _path -> flunk("command should not set daemon logs") end,
      set_server_port_override: fn _port -> flunk("command should not set daemon ports") end,
      set_profile_override: fn _profile -> flunk("command should not set daemon profiles") end,
      ensure_all_started: fn -> flunk("command should not start the daemon") end
    }
  end

  defp write_cli_repo_manifest!(repo) do
    File.write!(Path.join(repo, "README.md"), "docs\n")

    File.write!(
      Path.join(repo, "symphony.yml"),
      """
      version: 1
      project:
        slug: target-repo
        repository: https://github.com/example/target-repo
      docs:
        entrypoints:
          - README.md
      delivery:
        pr_target: main
      workflow:
        preset: default
      """
    )
  end

  defp mixed_manifest_repo!(name) do
    repo = tmp_repo!(name)
    File.write!(Path.join(repo, "README.md"), "docs\n")

    File.write!(
      Path.join(repo, "symphony.yml"),
      """
      version: 1
      project:
        slug: target-repo
        repository: https://github.com/example/target-repo
      docs:
        entrypoints:
          - README.md
      delivery:
        pr_target: main
      workflow:
        preset: default
      runtime:
        tracker:
          project_slug: symphony
          required_labels:
            - symphony
        workspace:
          root: ~/dogfood-workspaces
        agent:
          max_concurrent_agents: 4
          max_concurrent_startups: 1
          max_turns: 9
        runners:
          codex:
            kind: codex_app_server
            command:
              - codex
              - app-server
      """
    )

    repo
  end

  defp repo_root!, do: Path.expand("../../..", __DIR__)

  defp tmp_runtime_setup!(prefix, overrides \\ []) do
    root = tmp_repo!(prefix)
    runtime_path = Path.join(root, "symphony.runtime.yml")
    SymphonyElixir.TestSupport.write_manifest_file!(runtime_path, overrides)
    runtime_path
  end

  defp cli_deps(overrides) do
    Map.merge(
      %{
        file_regular?: &File.regular?/1,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        set_profile_override: fn _profile -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
        cwd: fn -> File.cwd!() end,
        tty?: fn -> false end,
        confirm: fn _preview -> false end
      },
      overrides
    )
  end
end
