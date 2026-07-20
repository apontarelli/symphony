defmodule SymphonyElixir.RunSetupTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LocalConfig
  alias SymphonyElixir.RunSetup
  alias SymphonyElixir.Workflow.{Manifest, Renderer}

  setup do
    on_exit(fn -> RunSetup.clear_current() end)
    :ok
  end

  test "run setup names cannot escape the global runs directory" do
    root = tmp_repo!("symphony-run-setup")

    assert {:ok, path} = RunSetup.path("daily-local-1", config_root: root)
    assert path == Path.join([root, "runs", "daily-local-1.yml"])

    for unsafe <- ["", ".", "..", "../daily", "daily/name", "daily name", ".hidden", "Main", "daily_run", "daily.local"] do
      assert {:error, {:invalid_run_setup_name, ^unsafe}} = RunSetup.path(unsafe, config_root: root)
    end
  end

  test "write and read round trips repo reference, target, mode, capacity, and restrictive flags" do
    root = tmp_repo!("symphony-run-setup")
    repo = tmp_repo!("target-repo")

    setup = %{
      "repo" => %{"path" => repo},
      "target" => %{"tracker" => %{"project_slug" => "symphony"}},
      "mode" => "unattended",
      "capacity" => "light",
      "restrictive_flags" => %{"required_labels" => ["symphony"]}
    }

    assert {:ok, path} = RunSetup.write("dogfood", setup, config_root: root)
    assert path == Path.join([root, "runs", "dogfood.yml"])

    assert {:ok, ^setup, ^path} = RunSetup.read("dogfood", config_root: root)
  end

  test "runtime manifest composition overlays local config and saved run setup on repo setup" do
    root = tmp_repo!("symphony-run-setup")
    repo = repo_setup!("target-repo")

    config =
      LocalConfig.default_config()
      |> put_in(["workspace", "root"], "~/custom-workspaces")

    setup = %{
      "repo" => %{"path" => repo},
      "target" => %{"tracker" => %{"project_slug" => "symphony"}},
      "mode" => "unattended",
      "capacity" => "light",
      "restrictive_flags" => %{"required_labels" => ["symphony"]}
    }

    assert {:ok, runtime_manifest} = RunSetup.runtime_manifest(config, setup)

    assert get_in(runtime_manifest, ["project", "slug"]) =~ "target-repo"
    assert get_in(runtime_manifest, ["runtime", "workspace", "root"]) == "~/custom-workspaces"
    assert get_in(runtime_manifest, ["runtime", "tracker", "project_slug"]) == "symphony"
    assert get_in(runtime_manifest, ["runtime", "tracker", "required_labels"]) == ["symphony"]
    assert get_in(runtime_manifest, ["runtime", "agent", "max_concurrent_agents"]) == 1
    assert get_in(runtime_manifest, ["runtime", "agent", "max_concurrent_startups"]) == 1
    assert get_in(runtime_manifest, ["runtime", "runners", "codex", "command"]) == ["codex", "app-server"]

    runtime_path = Path.join(root, "runtime.yml")
    File.write!(runtime_path, Renderer.to_yaml(runtime_manifest))
    assert {:ok, %{config: compiled}} = Manifest.load(runtime_path, repo_setup?: false)
    assert compiled["tracker"]["project_slug"] == "symphony"
    assert compiled["workspace"]["root"] == "~/custom-workspaces"
  end

  test "target tracker keys cannot override operator tracker defaults" do
    repo = repo_setup!("target-repo")

    config =
      LocalConfig.default_config()
      |> put_in(["tracker", "api_key"], "$LOCAL_LINEAR_API_KEY")
      |> put_in(["tracker", "active_states"], ["Ready", "Building"])

    setup = %{
      "repo" => %{"path" => repo},
      "target" => %{
        "tracker" => %{
          "project_slug" => "symphony",
          "api_key" => "$RUN_SETUP_LINEAR_API_KEY",
          "active_states" => ["Hijacked"]
        }
      },
      "mode" => "unattended",
      "capacity" => "light"
    }

    assert {:ok, runtime_manifest} = RunSetup.runtime_manifest(config, setup)

    assert get_in(runtime_manifest, ["runtime", "tracker", "project_slug"]) == "symphony"
    assert get_in(runtime_manifest, ["runtime", "tracker", "api_key"]) == "$LOCAL_LINEAR_API_KEY"
    assert get_in(runtime_manifest, ["runtime", "tracker", "active_states"]) == ["Ready", "Building"]
  end

  test "repo_setup_valid? accepts a valid repo setup manifest" do
    repo = repo_setup!("symphony-run-setup-valid")

    assert RunSetup.repo_setup_valid?(repo)
  end

  test "preview renders cwd runtime setup, repo setup provenance, warnings, and issue batch mode" do
    repo =
      repo_setup!("symphony-run-setup-preview",
        labels: ["symphony", "frontend"],
        allowed_projects: ["allowed-project"]
      )

    runtime_path = Path.join(repo, "symphony.runtime.yml")

    write_workflow_file!(runtime_path,
      tracker_project_id: "project-id",
      tracker_project_slug: nil,
      tracker_required_labels: ["symphony"],
      worker_ssh_hosts: ["worker-a"],
      server_port: 4000,
      max_concurrent_agents: 4,
      max_concurrent_startups: 3,
      runner_max_concurrent_startups: 1
    )

    assert {:ok, setup} =
             RunSetup.resolve(
               cwd: repo,
               mode: "issue_batch",
               limit: 2,
               max_agents: 3,
               max_startups: 1,
               no_land: true,
               profile: "  "
             )

    preview = RunSetup.preview(setup)

    assert preview =~ "repo setup: #{Path.join(repo, "symphony.yml")} (source: cwd symphony.yml)"
    assert preview =~ "runtime setup: #{runtime_path} (source: cwd symphony.runtime.yml)"
    assert preview =~ "tracker: linear project_id=project-id; required labels: symphony"
    assert preview =~ "marker intersection: symphony"
    assert preview =~ "mode: issue-batch (limit: 2)"
    assert preview =~ "max agents: 3 (ceiling: 4)"
    assert preview =~ "max startups: 1 (ceiling: 1)"
    assert preview =~ "worker: ssh hosts: worker-a"
    assert preview =~ "server port: 4000"
    assert preview =~ "restrictive flags: no_land"
    assert preview =~ "repo marker labels not required by runtime target: frontend"
    assert preview =~ "runtime project project-id is outside repo allowed_projects: allowed-project"
  end

  test "preview can use symphony.yml as the runtime fallback" do
    repo = repo_setup!("symphony-run-setup-repo-fallback")
    runtime_path = Path.join(repo, "symphony.yml")

    assert {:ok, setup} = RunSetup.resolve(cwd: repo)

    preview = RunSetup.preview(setup)

    assert preview =~ "repo setup: #{runtime_path} (source: cwd symphony.yml)"
    assert preview =~ "runtime setup: #{runtime_path} (source: cwd repo setup fallback)"
  end

  test "preview can use an explicit symphony.yml runtime path as the repo setup path" do
    repo = repo_setup!("symphony-run-setup-runtime-path")
    runtime_path = Path.join(repo, "symphony.yml")
    cwd = tmp_repo!("symphony-run-setup-runtime-path-cwd")

    assert {:ok, setup} = RunSetup.resolve(cwd: cwd, workflow: runtime_path)

    assert RunSetup.preview(setup) =~ "repo setup: #{runtime_path} (source: runtime setup path)"
  end

  test "preview renders alternate tracker selectors and marker intersections" do
    team_key_path =
      runtime_setup!("symphony-run-setup-team-key",
        tracker_project_id: nil,
        tracker_project_slug: nil,
        tracker_team_key: "SID",
        tracker_required_labels: ["frontend"]
      )

    put_issue_markers!(team_key_path, labels: ["backend"], allowed_projects: [])

    assert {:ok, team_key_setup} = RunSetup.resolve(workflow: team_key_path)
    team_key_preview = RunSetup.preview(team_key_setup)

    assert team_key_preview =~ "tracker: linear team_key=SID; required labels: frontend"
    assert team_key_preview =~ "marker intersection: no label overlap"
    assert team_key_preview =~ "repo marker labels not required by runtime target: backend"

    missing_scope_path =
      runtime_setup!("symphony-run-setup-missing-scope",
        tracker_project_id: nil,
        tracker_project_slug: nil,
        tracker_team_key: nil,
        tracker_required_labels: []
      )

    assert {:ok, missing_scope_setup} = RunSetup.resolve(workflow: missing_scope_path)

    assert RunSetup.preview(missing_scope_setup) =~ "tracker: linear missing Linear scope; required labels: none"
  end

  test "mode and limit validation accepts run modes and rejects invalid inputs" do
    runtime_path = runtime_setup!("symphony-run-setup-modes")

    assert {:ok, issue_batch_setup} = RunSetup.resolve(workflow: runtime_path, mode: "issue-batch")
    assert issue_batch_setup.mode == :issue_batch
    assert issue_batch_setup.issue_batch_limit == 1

    assert {:ok, drain_setup} = RunSetup.resolve(workflow: runtime_path, mode: "drain", limit: 2)
    assert drain_setup.mode == :drain
    assert drain_setup.issue_batch_limit == 2

    assert {:error, issue_batch_error} = RunSetup.resolve(workflow: runtime_path, mode: "issue_batch", limit: 0)
    assert issue_batch_error =~ "issue_batch mode requires --limit"

    assert {:error, limit_error} = RunSetup.resolve(workflow: runtime_path, mode: "drain", limit: 0)
    assert limit_error =~ "--limit must be a positive integer"

    assert {:error, mode_error} = RunSetup.resolve(workflow: runtime_path, mode: "later")
    assert mode_error =~ "unsupported run mode: later"

    assert {:error, non_string_mode_error} = RunSetup.resolve(workflow: runtime_path, mode: 123)
    assert non_string_mode_error =~ "unsupported run mode"
  end

  test "capacity validation enforces positive values and deployment startup ceilings" do
    runtime_path =
      runtime_setup!("symphony-run-setup-capacity",
        max_concurrent_agents: 5,
        max_concurrent_startups: 2
      )

    assert {:error, agents_error} = RunSetup.resolve(workflow: runtime_path, max_agents: 0)
    assert agents_error =~ "--max-agents must be a positive integer"

    assert {:error, startup_error} = RunSetup.resolve(workflow: runtime_path, max_startups: 0)
    assert startup_error =~ "--max-startups must be a positive integer"

    assert {:error, ceiling_error} = RunSetup.resolve(workflow: runtime_path, max_startups: 3)
    assert ceiling_error =~ "max startups 3 > ceiling 2"

    runner_limited_path =
      runtime_setup!("symphony-run-setup-runner-capacity",
        max_concurrent_startups: 4,
        runner_max_concurrent_startups: 2
      )

    assert {:ok, runner_limited_setup} = RunSetup.resolve(workflow: runner_limited_path)
    assert runner_limited_setup.capacity.max_concurrent_startups == 2
  end

  test "scheduler-facing accessors accept stored setup maps and fallback defaults" do
    runtime_path = runtime_setup!("symphony-run-setup-current-map")
    assert {:ok, setup} = RunSetup.resolve(workflow: runtime_path)

    RunSetup.put_current(%{capacity: %{max_concurrent_agents: 4}})
    assert RunSetup.capacity(setup.settings).max_concurrent_agents == 4

    RunSetup.put_current(%{
      "capacity" => %{
        "max_concurrent_agents" => 3,
        "max_concurrent_agents_ceiling" => 8,
        "max_concurrent_startups" => 2,
        "max_concurrent_startups_ceiling" => 4
      },
      "mode" => "issue-batch",
      "issue_batch_limit" => 5
    })

    assert RunSetup.capacity(setup.settings) == %{
             max_concurrent_agents: 3,
             max_concurrent_agents_ceiling: 8,
             max_concurrent_startups: 2,
             max_concurrent_startups_ceiling: 4
           }

    assert RunSetup.mode() == :issue_batch
    assert RunSetup.issue_batch_limit() == 5

    RunSetup.put_current(%{"mode" => "bogus"})
    assert RunSetup.mode() == :watch

    RunSetup.put_current(nil)
    assert RunSetup.current() == nil
    assert RunSetup.mode() == :watch
  end

  test "default capacity handles runner-only and missing startup ceilings" do
    runtime_path = runtime_setup!("symphony-run-setup-capacity-defaults")
    assert {:ok, setup} = RunSetup.resolve(workflow: runtime_path)

    runner_only_settings =
      setup.settings
      |> put_agent_startups(nil)
      |> put_runner_startups(3)

    assert RunSetup.capacity(runner_only_settings).max_concurrent_startups == 3

    fallback_settings =
      setup.settings
      |> put_agent_startups(nil)
      |> put_runner_startups(nil)

    assert RunSetup.capacity(fallback_settings).max_concurrent_startups == 1
  end

  test "restrictive policy flags tighten active policy without weakening repo policy" do
    RunSetup.put_current(%{
      restrictive_flags: [:no_land, :human_review_only, :require_validation, :require_review, :unknown]
    })

    policy =
      RunSetup.apply_restrictive_policy(%{
        "auto_land" => %{"posture" => "candidate", "dry_run" => false},
        "completion_requirements" => "legacy",
        "review_requirements" => ["existing"],
        "run_setup" => %{"restrictive_flags" => ["existing"]}
      })

    assert policy["auto_land"] == %{"posture" => "off", "dry_run" => true}
    assert policy["handoff_route"] == "human_review"
    assert policy["completion_requirements"] == ["Run setup requires validation evidence before handoff."]
    assert policy["review_requirements"] == ["existing", "Run setup requires review evidence before handoff."]

    assert policy["run_setup"]["restrictive_flags"] == [
             "existing",
             "no_land",
             "human_review_only",
             "require_validation",
             "require_review"
           ]

    RunSetup.put_current(%{"restrictive_flags" => [:require_review]})

    assert RunSetup.apply_restrictive_policy(%{}) == %{
             "review_requirements" => ["Run setup requires review evidence before handoff."],
             "run_setup" => %{"restrictive_flags" => ["require_review"]}
           }

    RunSetup.clear_current()

    assert RunSetup.apply_restrictive_policy(%{"auto_land" => %{"posture" => "candidate"}}) == %{
             "auto_land" => %{"posture" => "candidate"}
           }

    assert RunSetup.apply_restrictive_policy(:unchanged) == :unchanged
  end

  test "startup_error reports tracker startup blockers before side effects" do
    runtime_path = runtime_setup!("symphony-run-setup-startup-errors")
    assert {:ok, setup} = RunSetup.resolve(workflow: runtime_path)

    assert RunSetup.startup_error(setup) == nil

    assert RunSetup.startup_error(update_tracker(setup, kind: nil)) ==
             "Tracker kind missing in selected workflow config"

    assert RunSetup.startup_error(update_tracker(setup, kind: "jira")) ==
             ~s(Unsupported tracker kind in selected workflow config: "jira")

    assert RunSetup.startup_error(update_tracker(setup, api_key: nil)) ==
             "Linear API token missing in selected workflow config"

    issue_scope_setup =
      update_tracker(setup,
        project_id: nil,
        project_slug: nil,
        team_key: nil,
        issue_ids: ["SID-123"]
      )

    assert RunSetup.startup_error(issue_scope_setup) == nil

    missing_scope_setup =
      update_tracker(setup,
        project_id: nil,
        project_slug: nil,
        team_key: nil,
        issue_ids: [],
        query: " "
      )

    assert RunSetup.startup_error(missing_scope_setup) ==
             "Linear project_id, project_slug, team_key, issue_ids, query, or query_file missing in selected workflow config"
  end

  test "resolve reports setup path, parse, invalid manifest, and missing setup errors" do
    cwd = tmp_repo!("symphony-run-setup-empty")
    runtime_path = runtime_setup!("symphony-run-setup-errors")

    assert {:error, cwd_error} = RunSetup.resolve(cwd: cwd, workflow: " ")
    assert cwd_error =~ "local runtime setup not found"

    assert {:error, missing_runtime_error} =
             RunSetup.resolve(workflow: Path.join(cwd, "missing-runtime.yml"))

    assert missing_runtime_error =~ "runtime setup file not found"

    assert {:error, missing_repo_error} =
             RunSetup.resolve(workflow: runtime_path, repo: Path.join(cwd, "missing-repo.yml"))

    assert missing_repo_error =~ "manifest file not found"

    parse_error_path = Path.join(cwd, "parse-error.runtime.yml")
    File.write!(parse_error_path, "runtime: [")

    assert {:error, parse_error} = RunSetup.resolve(workflow: parse_error_path)
    assert parse_error =~ "failed to parse manifest"

    invalid_path = Path.join(cwd, "invalid.runtime.yml")

    File.write!(invalid_path, """
    project:
      slug: target-repo
      repository: github.com/example/target-repo
    delivery:
      pr_target: main
    workflow:
      preset: release-channel
    """)

    assert {:error, invalid_error} = RunSetup.resolve(workflow: invalid_path)
    assert invalid_error =~ "invalid manifest: workflow.preset unknown preset: release-channel"
  end

  defp runtime_setup!(prefix, overrides \\ []) do
    root = tmp_repo!(prefix)
    runtime_path = Path.join(root, "symphony.runtime.yml")
    write_workflow_file!(runtime_path, overrides)
    runtime_path
  end

  defp repo_setup!(prefix, opts \\ []) do
    repo = tmp_repo!(prefix)
    File.write!(Path.join(repo, "README.md"), "repo docs\n")
    File.write!(Path.join(repo, "AGENTS.md"), "repo instructions\n")

    manifest =
      repo
      |> Manifest.default([])
      |> put_in(["project", "repository"], "https://github.com/example/#{prefix}.git")
      |> put_in(["issue_markers", "labels"], Keyword.get(opts, :labels, []))
      |> put_in(["issue_markers", "allowed_projects"], Keyword.get(opts, :allowed_projects, []))

    File.write!(Path.join(repo, "symphony.yml"), Renderer.to_yaml(manifest))
    repo
  end

  defp put_issue_markers!(path, opts) do
    {:ok, manifest} = YamlElixir.read_from_file(path)

    manifest =
      manifest
      |> put_in(["issue_markers"], %{
        "labels" => Keyword.get(opts, :labels, []),
        "allowed_projects" => Keyword.get(opts, :allowed_projects, [])
      })

    File.write!(path, Renderer.to_yaml(manifest))
  end

  defp tmp_repo!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp put_agent_startups(settings, value) do
    %{settings | agent: %{settings.agent | max_concurrent_startups: value}}
  end

  defp put_runner_startups(settings, value) do
    %{settings | runners: put_in(settings.runners, ["codex", "max_concurrent_startups"], value)}
  end

  defp update_tracker(setup, attrs) do
    tracker = struct(setup.settings.tracker, attrs)
    settings = %{setup.settings | tracker: tracker}
    %{setup | settings: settings}
  end
end
