defmodule SymphonyElixir.SetupMigrationTest do
  use ExUnit.Case

  alias SymphonyElixir.LocalConfig
  alias SymphonyElixir.RunSetup
  alias SymphonyElixir.SetupMigration
  alias SymphonyElixir.Workflow.Manifest

  test "preview extracts runtime fields without writing files" do
    root = tmp_dir!("symphony-migration")
    repo = mixed_manifest_repo!()

    assert {:ok, plan} = SetupMigration.plan(repo, "dogfood", config_root: root)

    refute File.exists?(LocalConfig.path(config_root: root))
    assert {:ok, run_setup_path} = RunSetup.path("dogfood", config_root: root)
    refute File.exists?(run_setup_path)

    assert "runtime.tracker.project_slug" in plan.moved_fields
    assert "runtime.tracker.required_labels" in plan.moved_fields
    assert "runtime.workspace.root" in plan.moved_fields
    assert "runtime.polling.interval_ms" in plan.moved_fields
    assert "runtime.agent.max_concurrent_agents" in plan.moved_fields
    assert "runtime.agent.max_concurrent_startups" in plan.moved_fields
    assert "runtime.agent.max_turns" in plan.moved_fields
    assert "runtime.host.deployment_target" in plan.moved_fields
    assert "runtime.runners.codex.command" in plan.moved_fields
    assert "runtime.runners.codex.model" in plan.moved_fields
    assert "runtime.runners.codex.approval_policy" in plan.moved_fields
    assert "runtime.runners.codex.thread_sandbox" in plan.moved_fields

    refute Map.has_key?(plan.cleaned_manifest, "runtime")
    assert get_in(plan.local_config, ["workspace", "root"]) == "~/dogfood-workspaces"
    assert get_in(plan.local_config, ["polling", "interval_ms"]) == 12_000
    assert get_in(plan.local_config, ["agent", "max_turns"]) == 9
    assert get_in(plan.local_config, ["host", "deployment_target"]) == "local"
    assert get_in(plan.local_config, ["runners", "codex", "model"]) == "gpt-5.4"

    assert get_in(plan.run_setup, ["target", "tracker", "project_slug"]) == "symphony"
    assert get_in(plan.run_setup, ["restrictive_flags", "required_labels"]) == ["symphony"]

    assert plan.run_setup["capacity"] == %{
             "max_concurrent_agents" => 4,
             "max_concurrent_startups" => 1
           }
  end

  test "apply writes local files, rewrites symphony.yml, and leaves the manifest setup-valid" do
    root = tmp_dir!("symphony-migration")
    repo = mixed_manifest_repo!()

    assert {:ok, result} = SetupMigration.apply(repo, "dogfood", config_root: root)

    assert "runtime.tracker.project_slug" in result.moved_fields
    assert {:ok, config} = LocalConfig.load(config_root: root)
    assert get_in(config, ["workspace", "root"]) == "~/dogfood-workspaces"

    assert {:ok, setup, _path} = RunSetup.read("dogfood", config_root: root)
    assert get_in(setup, ["target", "tracker", "project_slug"]) == "symphony"

    assert {:ok, %{config: compiled}} = Manifest.load(Path.join(repo, "symphony.yml"))
    refute Map.has_key?(compiled["manifest"], "runtime")
    assert compiled["manifest"]["project"]["slug"] == "target-repo"
  end

  test "apply preserves unrelated existing local config settings" do
    root = tmp_dir!("symphony-migration")
    repo = mixed_manifest_repo!()
    File.mkdir_p!(root)

    File.write!(
      LocalConfig.path(config_root: root),
      """
      agent:
        max_retry_backoff_ms: 1234
      custom_operator:
        keep: true
      """
    )

    assert {:ok, _result} = SetupMigration.apply(repo, "dogfood", config_root: root)
    assert {:ok, config} = LocalConfig.load(config_root: root)

    assert get_in(config, ["workspace", "root"]) == "~/dogfood-workspaces"
    assert get_in(config, ["agent", "max_retry_backoff_ms"]) == 1234
    assert get_in(config, ["custom_operator", "keep"]) == true
  end

  test "apply rejects an existing saved run setup before writing" do
    root = tmp_dir!("symphony-migration")
    repo = mixed_manifest_repo!()
    manifest_path = Path.join(repo, "symphony.yml")
    original_manifest = File.read!(manifest_path)
    assert {:ok, run_setup_path} = RunSetup.path("dogfood", config_root: root)
    File.mkdir_p!(Path.dirname(run_setup_path))
    File.write!(run_setup_path, "sentinel: true\n")

    assert {:error, {:run_setup_exists, ^run_setup_path}} =
             SetupMigration.apply(repo, "dogfood", config_root: root)

    assert File.read!(run_setup_path) == "sentinel: true\n"
    refute File.exists?(LocalConfig.path(config_root: root))
    assert File.read!(manifest_path) == original_manifest
  end

  test "mixed top-level and runtime sections preserve both sources and source paths" do
    root = tmp_dir!("symphony-migration")

    repo =
      manifest_repo!("""
      version: 1
      project:
        slug: target-repo
      runtime:
        tracker:
          project_slug: runtime-project
        agent:
          max_turns: 7
      tracker:
        required_labels:
          - top-label
      agent:
        max_retry_backoff_ms: 1234
      """)

    assert {:ok, plan} = SetupMigration.plan(repo, "dogfood", config_root: root)

    assert "runtime.tracker.project_slug" in plan.moved_fields
    assert "tracker.required_labels" in plan.moved_fields
    assert "runtime.agent.max_turns" in plan.moved_fields
    assert "agent.max_retry_backoff_ms" in plan.moved_fields
    assert get_in(plan.run_setup, ["target", "tracker", "project_slug"]) == "runtime-project"
    assert get_in(plan.run_setup, ["restrictive_flags", "required_labels"]) == ["top-label"]
    assert get_in(plan.local_config, ["agent", "max_turns"]) == 7
    assert get_in(plan.local_config, ["agent", "max_retry_backoff_ms"]) == 1234
  end

  test "top-level target deep-merges with target fields derived from runtime tracker" do
    root = tmp_dir!("symphony-migration")

    repo =
      manifest_repo!("""
      version: 1
      project:
        slug: target-repo
      runtime:
        tracker:
          project_slug: runtime-project
      target:
        workspace_slug: top-workspace
        tracker:
          team_key: ENG
      """)

    assert {:ok, plan} = SetupMigration.plan(repo, "dogfood", config_root: root)

    assert get_in(plan.run_setup, ["target", "tracker"]) == %{
             "project_slug" => "runtime-project",
             "team_key" => "ENG",
             "workspace_slug" => "top-workspace"
           }

    assert "runtime.tracker.project_slug" in plan.moved_fields
    assert "target.workspace_slug" in plan.moved_fields
    assert "target.tracker.team_key" in plan.moved_fields
  end

  test "partial capacity override is completed from runtime defaults before apply" do
    root = tmp_dir!("symphony-migration")

    repo =
      manifest_repo!("""
      version: 1
      project:
        slug: target-repo
      runtime:
        agent:
          max_concurrent_agents: 3
      """)

    assert {:ok, result} = SetupMigration.apply(repo, "dogfood", config_root: root)
    assert "runtime.agent.max_concurrent_agents" in result.moved_fields
    refute "runtime.agent.max_concurrent_startups" in result.moved_fields

    assert {:ok, setup, _path} = RunSetup.read("dogfood", config_root: root)

    capacity = %{
      "max_concurrent_agents" => 3,
      "max_concurrent_startups" => 2
    }

    assert setup["capacity"] == capacity

    assert {:ok, config} = LocalConfig.load(config_root: root)
    assert get_in(config, ["deployment", "ceilings"]) == capacity
    assert {:ok, ^capacity} = LocalConfig.resolve_capacity(config, setup["capacity"])
  end

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp manifest_repo!(manifest) do
    repo = tmp_dir!("manifest-repo")
    File.write!(Path.join(repo, "README.md"), "docs\n")
    File.write!(Path.join(repo, "symphony.yml"), manifest)
    repo
  end

  defp mixed_manifest_repo! do
    repo = tmp_dir!("mixed-manifest-repo")
    File.write!(Path.join(repo, "README.md"), "docs\n")

    File.write!(
      Path.join(repo, "symphony.yml"),
      """
      version: 1
      project:
        slug: target-repo
        name: Target Repo
        repository: https://github.com/example/target-repo
        kind: elixir
        app_kind: web
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
          active_states:
            - Todo
            - In Progress
        polling:
          interval_ms: 12000
        workspace:
          root: ~/dogfood-workspaces
        agent:
          default_runner: codex
          max_concurrent_agents: 4
          max_concurrent_startups: 1
          max_turns: 9
        host:
          deployment_target: local
        runners:
          codex:
            kind: codex_app_server
            command:
              - codex
              - --config
              - model_reasoning_effort=high
              - app-server
            model: gpt-5.4
            approval_policy: never
            thread_sandbox: workspace-write
      """
    )

    repo
  end
end
