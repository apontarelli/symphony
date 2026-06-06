defmodule SymphonyElixir.WorkflowManifestTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.Manifest
  alias SymphonyElixir.Workflow.ModuleRegistry

  test "valid manifest resolves registry defaults into a runtime workflow" do
    assert Manifest.manifest_file_name() == "symphony.yml"

    path =
      write_manifest!("""
      project:
        slug: target-repo
        name: Target Repo
        repository: github.com/example/target-repo
        facts:
          owner: platform
      app:
        kind: web
      docs:
        entry_points:
          - README.md
          - docs/ARCHITECTURE.md
      vcs:
        kind: jj
        default_branch: trunk
        posture: stacked
      delivery:
        pr_target: release/next
      validation:
        gates:
          - name: unit
            command: mix test
      autonomy:
        profile: default
        completion_requirements:
          - tests-green
        review:
          required: true
      workflow:
        preset: default
        modules:
          - observability
      """)

    assert {:ok, %{config: config, prompt: prompt, prompt_template: prompt}} = Manifest.load(path)

    assert config["tracker"]["kind"] == "linear"
    assert config["tracker"]["project_slug"] == "target-repo"
    assert config["tracker"]["active_states"] == ["Todo", "In Progress", "Merging", "Rework"]
    assert config["hooks"]["after_create"] == "git clone --depth 1 'github.com/example/target-repo' ."
    assert config["manifest"]["project"]["name"] == "Target Repo"
    assert config["manifest"]["project"]["repository"] == "github.com/example/target-repo"
    assert config["manifest"]["project"]["facts"] == %{"owner" => "platform"}
    assert config["manifest"]["app"]["kind"] == "web"
    assert config["manifest"]["docs"]["entry_points"] == ["README.md", "docs/ARCHITECTURE.md"]
    assert config["manifest"]["vcs"]["kind"] == "jj"
    assert config["manifest"]["vcs"]["posture"] == "stacked"
    assert config["manifest"]["workflow"]["modules"] == ["linear", "workspace", "codex", "observability"]
    assert config["observability"]["dashboard_enabled"] == true
    assert config["observability"]["refresh_ms"] == 1_000
    assert config["checks"] == [%{"name" => "unit", "command" => "mix test"}]
    assert config["completion_requirements"] == ["tests-green"]
    assert config["delivery"]["pr_target"] == "release/next"
    assert config["policy_metadata"]["profile"] == "default"
    assert config["policy_metadata"]["source"] == "symphony_manifest"

    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", "manifest-token")
    Workflow.set_workflow_file_path(path)

    assert {:ok, policy} = Config.effective_policy()
    assert is_binary(policy["policy_ref"])
    assert policy["checks"] == [%{"name" => "unit", "command" => "mix test"}]
    assert policy["completion_requirements"] == ["tests-green"]
    assert policy["delivery"]["pr_target"] == "release/next"
    assert policy["review"] == %{"required" => true}
    assert policy["policy_metadata"]["profile"] == "default"
    assert policy["policy_metadata"]["project_slug"] == "target-repo"
    assert policy["policy_metadata"]["source"] == "symphony_manifest"

    assert prompt =~ "Target Repo"
    assert prompt =~ "Repository: github.com/example/target-repo"
    assert prompt =~ "App kind: web"
    assert prompt =~ "Project facts:\n- owner: platform"
    assert prompt =~ "- Posture: stacked"
    assert prompt =~ "Delivery:\n- PR target: release/next"
    assert prompt =~ "mix test"
    assert prompt =~ "Completion requirements:\n- tests-green"
    assert prompt =~ "Review policy:\n- required: true"
    assert prompt =~ "Use the dashboard and status APIs as operator-visible evidence"
  end

  test "selected modules return path-specific requirement diagnostics" do
    path =
      write_manifest!("""
      project: {}
      """)

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)
    refute Enum.any?(diagnostics, &(&1.path == "project.slug"))
    assert %{path: "project.repository", message: "is required by selected workflow modules"} in diagnostics

    path = write_manifest!("app:\n  kind: web\n")

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)
    refute Enum.any?(diagnostics, &(&1.path == "project.slug"))
    assert %{path: "project.repository", message: "is required by selected workflow modules"} in diagnostics
  end

  test "present optional sections can omit list fields" do
    path =
      write_manifest!("""
      project:
        slug: target-repo
        repository: github.com/example/target-repo
      docs: {}
      workflow:
        preset: default
      """)

    assert {:ok, %{config: config}} = Manifest.load(path)
    assert config["manifest"]["docs"]["entry_points"] == []
    assert config["manifest"]["workflow"]["modules"] == ["linear", "workspace", "codex"]
  end

  test "missing file and non-map YAML return typed manifest errors" do
    missing_path = Path.join(System.tmp_dir!(), "missing-symphony-#{System.unique_integer([:positive])}.yml")
    assert {:error, {:missing_manifest_file, ^missing_path, :enoent}} = Manifest.load(missing_path)

    path =
      write_manifest!("""
      - not-a-map
      """)

    assert {:error, {:invalid_manifest, [%{path: "$", message: "must be a map"}]}} = Manifest.load(path)
  end

  test "invalid section types return section-level diagnostics" do
    path =
      write_manifest!("""
      project: 123
      app: []
      docs: no
      vcs: []
      delivery: bad
      validation: bad
      autonomy: bad
      workflow: bad
      runtime: bad
      """)

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)

    assert %{path: "project", message: "must be a map"} in diagnostics
    assert %{path: "app", message: "must be a map"} in diagnostics
    assert %{path: "docs", message: "must be a map"} in diagnostics
    assert %{path: "vcs", message: "must be a map"} in diagnostics
    assert %{path: "delivery", message: "must be a map"} in diagnostics
    assert %{path: "validation", message: "must be a map"} in diagnostics
    assert %{path: "autonomy", message: "must be a map"} in diagnostics
    assert %{path: "workflow", message: "must be a map"} in diagnostics
    assert %{path: "runtime", message: "must be a map"} in diagnostics
  end

  test "invalid nested field types return field-level diagnostics" do
    path =
      write_manifest!("""
      project:
        slug: 123
        name: 456
        repository: 789
        facts: "not-a-map"
      app:
        kind: 123
      docs:
        entry_points: README.md
      vcs:
        kind: 123
        default_branch: 456
        posture: 789
      delivery:
        pr_target: 123
      validation:
        gates: test
      autonomy:
        profile: 123
        completion_requirements: tests
        policy_ref: 456
        review: true
      workflow:
        preset: 123
        modules: codex
      """)

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)

    assert %{path: "project.slug", message: "must be a string"} in diagnostics
    assert %{path: "project.name", message: "must be a string"} in diagnostics
    assert %{path: "project.repository", message: "must be a string"} in diagnostics
    assert %{path: "project.facts", message: "must be a map"} in diagnostics
    assert %{path: "app.kind", message: "must be a string"} in diagnostics
    assert %{path: "docs.entry_points", message: "must be a list"} in diagnostics
    assert %{path: "vcs.kind", message: "must be a string"} in diagnostics
    assert %{path: "vcs.default_branch", message: "must be a string"} in diagnostics
    assert %{path: "vcs.posture", message: "must be a string"} in diagnostics
    assert %{path: "delivery.pr_target", message: "must be a string"} in diagnostics
    assert %{path: "validation.gates", message: "must be a list"} in diagnostics
    assert %{path: "autonomy.profile", message: "must be a string"} in diagnostics
    assert %{path: "autonomy.completion_requirements", message: "must be a list"} in diagnostics
    assert %{path: "autonomy.policy_ref", message: "is not supported; policy_ref is derived from the resolved policy"} in diagnostics
    assert %{path: "autonomy.review", message: "must be a map"} in diagnostics
    assert %{path: "workflow.preset", message: "must be a string"} in diagnostics
    assert %{path: "workflow.modules", message: "must be a list"} in diagnostics
  end

  test "invalid validation gates and list entries return indexed diagnostics" do
    path =
      write_manifest!("""
      project:
        slug: target-repo
        repository: github.com/example/target-repo
      docs:
        entry_points:
          - ""
          - 123
      validation:
        gates:
          - not-a-map
          - name: ""
            command: 123
          - command: mix test
          - name: unit
            command:
      """)

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)

    assert %{path: "docs.entry_points[0]", message: "must be a non-empty string"} in diagnostics
    assert %{path: "docs.entry_points[1]", message: "must be a non-empty string"} in diagnostics
    assert %{path: "validation.gates[0]", message: "must be a map"} in diagnostics
    assert %{path: "validation.gates[1].name", message: "is required"} in diagnostics
    assert %{path: "validation.gates[1].command", message: "must be a string"} in diagnostics
    assert %{path: "validation.gates[2].name", message: "is required"} in diagnostics
    assert %{path: "validation.gates[3].command", message: "is required"} in diagnostics
  end

  test "empty optional sections use defaults" do
    path =
      write_manifest!("""
      project:
        slug: target-repo
        repository: github.com/example/target-repo
        facts:
      docs:
      validation: {}
      autonomy:
        completion_requirements:
        review:
      workflow:
        preset: default
        modules:
      """)

    assert {:ok, %{config: config}} = Manifest.load(path)

    assert config["manifest"]["project"]["facts"] == %{}
    assert config["manifest"]["docs"]["entry_points"] == []
    assert config["checks"] == []
    assert config["completion_requirements"] == []
    assert config["manifest"]["workflow"]["modules"] == ["linear", "workspace", "codex"]
  end

  test "unknown preset and modules return path-specific diagnostics" do
    preset_path =
      write_manifest!("""
      project:
        slug: target-repo
        repository: github.com/example/target-repo
      workflow:
        preset: release-channel
      """)

    assert {:error, {:invalid_manifest, [%{path: "workflow.preset", message: "unknown preset: release-channel"}]}} =
             Manifest.load(preset_path)

    module_path =
      write_manifest!("""
      project:
        slug: target-repo
        repository: github.com/example/target-repo
      workflow:
        modules:
          - codex
          - unknown-module
      """)

    assert {:error, {:invalid_manifest, [%{path: "workflow.modules[1]", message: "unknown module: unknown-module"}]}} =
             Manifest.load(module_path)
  end

  test "unknown module diagnostics preserve original indexes after invalid list entries" do
    path =
      write_manifest!("""
      project:
        slug: target-repo
        repository: github.com/example/target-repo
      workflow:
        modules:
          - ""
          - 123
          - unknown-module
      """)

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)
    assert %{path: "workflow.modules[0]", message: "must be a non-empty string"} in diagnostics
    assert %{path: "workflow.modules[1]", message: "must be a non-empty string"} in diagnostics
    assert %{path: "workflow.modules[2]", message: "unknown module: unknown-module"} in diagnostics
  end

  test "module registry reports defensive diagnostics and optional workspace config" do
    assert ModuleRegistry.module_diagnostics("unknown-module", 2, %{}) == [
             %{path: "workflow.modules[2]", message: "unknown module: unknown-module"}
           ]

    assert {:ok, config} = ModuleRegistry.module_config("workspace", 0, %{"project" => %{}})
    assert config["hooks"]["timeout_ms"] == 60_000
    refute Map.has_key?(config["hooks"], "after_create")
  end

  test "default resolution does not require release-channel fields" do
    path =
      write_manifest!("""
      project:
        slug: target-repo
        repository: github.com/example/target-repo
      """)

    assert {:ok, %{config: config}} = Manifest.load(path)

    refute get_in(config, ["manifest", "release_channel"])
    refute get_in(config, ["manifest", "workflow", "release_channel"])
    assert config["manifest"]["workflow"]["preset"] == "default"
    assert config["manifest"]["workflow"]["modules"] == ["linear", "workspace", "codex"]
    assert config["manifest"]["app"]["kind"] == "local"
    assert config["delivery"]["pr_target"] == "main"
  end

  test "manifest defaults validate through typed daemon config and render retry context" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", "manifest-token")

    path =
      write_manifest!("""
      project:
        slug: target-repo
        name: Target Repo
        repository: github.com/example/target-repo
        facts:
          owner: platform
      vcs:
        kind: jj
        posture: stacked
      """)

    Workflow.set_workflow_file_path(path)

    assert :ok = Config.validate!()

    settings = Config.settings!()
    assert settings.tracker.kind == "linear"
    assert settings.tracker.api_key == "manifest-token"
    assert settings.tracker.project_slug == "target-repo"
    assert settings.tracker.active_states == ["Todo", "In Progress", "Merging", "Rework"]
    assert settings.workspace.root == "~/code/symphony-workspaces"
    assert settings.hooks.after_create == "git clone --depth 1 'github.com/example/target-repo' ."
    assert settings.agent.max_concurrent_agents == 10
    assert settings.codex.command == "codex app-server"
    assert settings.polling.interval_ms == 30_000

    prompt =
      PromptBuilder.build_prompt(
        %Issue{
          identifier: "SID-290",
          title: "Implement manifests",
          description: "Resolve symphony.yml",
          state: "Rework",
          labels: ["backend", "workflow"],
          url: "https://linear.app/example/SID-290"
        },
        attempt: 2
      )

    assert prompt =~ "This is retry attempt 2"
    assert prompt =~ "Current status: Rework"
    assert prompt =~ "Labels:"
    assert prompt =~ "backend"
    assert prompt =~ "workflow"
    assert prompt =~ "URL: https://linear.app/example/SID-290"
    assert prompt =~ "Project facts:\n- owner: platform"
    assert prompt =~ "VCS:\n- Kind: jj"
    assert prompt =~ "- Posture: stacked"
    assert prompt =~ "Route ticket states before acting"
  end

  test "config error formatter reports manifest diagnostics with paths" do
    assert Config.format_error({:invalid_manifest, [%{path: "project.slug", message: "is required"}]}) ==
             "Invalid symphony.yml manifest: project.slug is required"

    assert Config.format_error(:missing_linear_api_token) ==
             "Linear API token missing in selected workflow config"

    assert Config.format_error(:missing_linear_project_slug) ==
             "Linear project slug missing in selected workflow config"

    assert Config.format_error(:missing_tracker_kind) ==
             "Tracker kind missing in selected workflow config"

    assert Config.format_error({:unsupported_tracker_kind, "github"}) ==
             "Unsupported tracker kind in selected workflow config: \"github\""
  end

  defp write_manifest!(content) do
    dir = Path.join(System.tmp_dir!(), "symphony-manifest-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "symphony.yml")
    File.write!(path, content)
    path
  end
end
