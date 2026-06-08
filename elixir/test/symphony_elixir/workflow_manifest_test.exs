defmodule SymphonyElixir.WorkflowManifestTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.Manifest
  alias SymphonyElixir.Workflow.ModuleRegistry

  test "valid manifest resolves registry defaults into a runtime workflow" do
    assert Manifest.manifest_file_name() == "symphony.yml"

    path =
      write_manifest!("""
      version: 1
      project:
        slug: target-repo
        name: Target Repo
        repository: github.com/example/target-repo
        kind: elixir
        app_kind: web
        facts:
          owner: platform
      docs:
        entrypoints:
          - README.md
          - docs/ARCHITECTURE.md
      vcs:
        mode: jj
        default_branch: trunk
        posture: stacked
      delivery:
        pr_target: release/next
      validation:
        commands:
          - name: unit
            command: mix test
      automation:
        posture: unattended
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
    assert config["manifest"]["project"]["kind"] == "elixir"
    assert config["manifest"]["project"]["app_kind"] == "web"
    assert config["manifest"]["project"]["facts"] == %{"owner" => "platform"}
    assert config["manifest"]["docs"]["entrypoints"] == ["README.md", "docs/ARCHITECTURE.md"]
    assert config["manifest"]["vcs"]["mode"] == "jj"
    assert config["manifest"]["vcs"]["posture"] == "stacked"

    assert config["manifest"]["workflow"]["modules"] == [
             "repo.docs",
             "validation.commands",
             "tracker.linear",
             "workspace",
             "codex.harness",
             "delivery.github_pr",
             "observability"
           ]

    refute Map.has_key?(config["manifest"]["workflow"], "_module_requests")
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
    if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()

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
    assert prompt =~ "Project kind: elixir"
    assert prompt =~ "App kind: web"
    assert prompt =~ "Project facts:\n- owner: platform"
    assert prompt =~ "VCS:\n- Mode: jj"
    assert prompt =~ "- Posture: stacked"
    assert prompt =~ "Delivery:\n- PR target: release/next"
    assert prompt =~ "mix test"
    assert prompt =~ "Completion requirements:\n- tests-green"
    assert prompt =~ "Review policy:\n- required: true"
    assert prompt =~ "Use the dashboard and status APIs as operator-visible evidence"
  end

  test "product visual review module compiles through registry-backed workflow modules" do
    path =
      write_manifest!("""
      version: 1
      project:
        slug: target-repo
        name: Target Repo
        repository: github.com/example/target-repo
        kind: elixir
        app_kind: web
      workflow:
        preset: default
        modules:
          - product_visual_review
      runtime:
        workflow_modules:
          product_visual_review:
            enabled: true
            project_kind: web
            route_policy: required
      """)

    assert {:ok, %{config: config, prompt: prompt, workflow_module_resolution: resolution}} = Manifest.load(path)

    assert get_in(config, ["workflow_modules", "product_visual_review", "enabled"]) == true
    assert %{name: "product_visual_review", version: "v1"} in resolution.module_refs
    assert "product_visual_review" in resolution.module_names
    assert resolution.rendered =~ "### Product Visual Review"
    assert resolution.rendered =~ "Route policy: `required`"
    assert prompt =~ "### Product Visual Review"
    assert prompt =~ "Artifact evidence:"
  end

  test "disabled product visual review module compiles explicit disabled content" do
    path =
      write_manifest!("""
      version: 1
      project:
        slug: target-repo
        name: Target Repo
      workflow:
        preset: default
        modules:
          - product_visual_review
      runtime:
        workflow_modules:
          product_visual_review:
            enabled: false
      """)

    assert {:ok, %{config: config, prompt: prompt, workflow_module_resolution: resolution}} = Manifest.load(path)

    assert get_in(config, ["workflow_modules", "product_visual_review", "enabled"]) == false
    assert %{name: "product_visual_review", version: "v1"} in resolution.module_refs
    assert "product_visual_review" in resolution.module_names
    assert resolution.rendered =~ "### Product Visual Review"
    assert resolution.rendered =~ "Product visual review is disabled by workflow module configuration."
    assert prompt =~ "Product visual review is disabled by workflow module configuration."
  end

  test "review routing compiles into resolved policy and prompt context" do
    path =
      write_manifest!("""
      version: 1
      project:
        slug: target-repo
        name: Target Repo
      delivery:
        pr_target: main
      review_routing:
        project_criticality: local_non_production
        autonomy_posture: balanced
        auto_land:
          enabled: true
          max_risk_class: low
        product_visual_review:
          required_artifacts:
            - screenshots_or_recording
            - manual_qa_notes
      """)

    assert {:ok, %{config: config, prompt: compiled_prompt}} = Manifest.load(path)

    expected_review_routing = %{
      "project_criticality" => "local_non_production",
      "autonomy_posture" => "balanced",
      "auto_land" => %{"enabled" => true, "max_risk_class" => "low"},
      "product_visual_review" => %{
        "required_artifacts" => ["screenshots_or_recording", "manual_qa_notes"]
      }
    }

    assert config["manifest"]["review_routing"] == expected_review_routing
    assert get_in(config, ["profiles", "default", "review_routing"]) == expected_review_routing
    assert compiled_prompt =~ "Review routing:"
    assert compiled_prompt =~ "autonomy_posture: balanced"

    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", "manifest-token")
    Workflow.set_workflow_file_path(path)
    if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()

    assert {:ok, policy} = Config.effective_policy()
    assert policy["review_routing"] == expected_review_routing
    assert is_binary(policy["policy_ref"])

    prompt =
      PromptBuilder.build_prompt(%Issue{
        identifier: "SID-295",
        title: "Specify review routing contracts",
        description: "Route evidence",
        state: "In Progress",
        labels: ["workflow"],
        url: "https://linear.app/example/SID-295"
      })

    assert prompt =~ "review_routing:"
    assert prompt =~ "autonomy_posture: balanced"
    assert prompt =~ "max_risk_class: low"
  end

  test "auto-land policy compiles from symphony manifest fields" do
    path =
      write_manifest!("""
      version: 1
      project:
        slug: target-repo
        name: Target Repo
        criticality: prototype
        deployment_coupling: none
      auto_land:
        posture: permissive
        required_checks:
          - security-review
        force_human_review_labels:
          - manual-review
        failure_state: Rework
        blocked_state: Human Review
        dry_run: true
      """)

    assert {:ok, %{config: config}} = Manifest.load(path)

    expected_auto_land = %{
      "posture" => "permissive",
      "required_checks" => ["security-review"],
      "force_human_review_labels" => ["manual-review"],
      "failure_state" => "Rework",
      "blocked_state" => "Human Review",
      "dry_run" => true
    }

    assert config["manifest"]["project"]["criticality"] == "prototype"
    assert config["manifest"]["project"]["deployment_coupling"] == "none"
    assert config["manifest"]["auto_land"] == expected_auto_land
    assert config["project"]["criticality"] == "prototype"
    assert config["project"]["deployment_coupling"] == "none"
    assert config["auto_land"] == expected_auto_land
    assert get_in(config, ["profiles", "default", "auto_land"]) == expected_auto_land

    workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)
    Workflow.set_workflow_file_path(path)
    if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()

    settings = Config.settings!()
    assert settings.project.criticality == "prototype"
    assert settings.project.deployment_coupling == "none"
    assert settings.auto_land.posture == "permissive"
    assert settings.auto_land.required_checks == ["security-review"]
    assert settings.auto_land.force_human_review_labels == ["manual-review"]
  end

  test "auto-land policy compiles documented default force-human-review labels" do
    path =
      write_manifest!("""
      version: 1
      auto_land:
        posture: permissive
        dry_run: true
      """)

    assert {:ok, %{config: config}} = Manifest.load(path)

    assert config["auto_land"]["force_human_review_labels"] == [
             "force-human-review",
             "human-review",
             "manual-review",
             "no-auto-land"
           ]
  end

  test "legacy manifest vocabulary is rejected instead of translated" do
    path =
      write_manifest!("""
      project:
        slug: target-repo
        repository: github.com/example/target-repo
      app:
        kind: web
      docs:
        entry_points:
          - README.md
      vcs:
        kind: jj
      validation:
        gates:
          - name: unit
            command: mix test
      autonomy:
        profile: default
      """)

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)
    assert %{path: "app", message: "is not supported; use project.app_kind"} in diagnostics
    assert %{path: "docs.entry_points", message: "is not supported; use docs.entrypoints"} in diagnostics
    assert %{path: "vcs.kind", message: "is not supported; use vcs.mode"} in diagnostics
    assert %{path: "validation.gates", message: "is not supported; use validation.commands"} in diagnostics
    assert %{path: "autonomy", message: "is not supported; use automation"} in diagnostics
  end

  test "present optional sections can omit list fields" do
    path =
      write_manifest!("""
      project:
        slug: target-repo
        repository: github.com/example/target-repo
      docs: {}
      validation: {}
      workflow:
        preset: default
      """)

    assert {:ok, %{config: config}} = Manifest.load(path)
    assert config["manifest"]["docs"]["entrypoints"] == []

    assert config["manifest"]["workflow"]["modules"] == [
             "repo.docs",
             "validation.commands",
             "tracker.linear",
             "workspace",
             "codex.harness",
             "delivery.github_pr"
           ]
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
      docs: no
      vcs: []
      delivery: bad
      validation: bad
      automation: bad
      workflow: bad
      runtime: bad
      harness: bad
      bindings: bad
      """)

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)

    assert %{path: "project", message: "must be a map"} in diagnostics
    assert %{path: "docs", message: "must be a map"} in diagnostics
    assert %{path: "vcs", message: "must be a map"} in diagnostics
    assert %{path: "delivery", message: "must be a map"} in diagnostics
    assert %{path: "validation", message: "must be a map"} in diagnostics
    assert %{path: "automation", message: "must be a map"} in diagnostics
    assert %{path: "workflow", message: "must be a map"} in diagnostics
    assert %{path: "runtime", message: "must be a map"} in diagnostics
    assert %{path: "harness", message: "must be a map"} in diagnostics
    assert %{path: "bindings", message: "must be a map"} in diagnostics
  end

  test "invalid nested field types return field-level diagnostics" do
    path =
      write_manifest!("""
      version: "1"
      project:
        slug: 123
        name: 456
        repository: 789
        kind: []
        app_kind: 123
        facts: "not-a-map"
      docs:
        entrypoints: README.md
      vcs:
        mode: 123
        default_branch: 456
        posture: 789
      delivery:
        pr_target: 123
      validation:
        commands: test
      automation:
        posture: 123
        profile: 456
        completion_requirements: tests
        policy_ref: old
        review: true
      workflow:
        preset: 123
        modules: codex
      review_routing: true
      harness:
        codex_home: []
      bindings:
        local_file: []
        require_local: yes
      """)

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)

    assert %{path: "version", message: "must be an integer"} in diagnostics
    assert %{path: "project.slug", message: "must be a string"} in diagnostics
    assert %{path: "project.name", message: "must be a string"} in diagnostics
    assert %{path: "project.repository", message: "must be a string"} in diagnostics
    assert %{path: "project.kind", message: "must be a string"} in diagnostics
    assert %{path: "project.app_kind", message: "must be a string"} in diagnostics
    assert %{path: "project.facts", message: "must be a map"} in diagnostics
    assert %{path: "docs.entrypoints", message: "must be a list"} in diagnostics
    assert %{path: "vcs.mode", message: "must be a string"} in diagnostics
    assert %{path: "vcs.default_branch", message: "must be a string"} in diagnostics
    assert %{path: "vcs.posture", message: "must be a string"} in diagnostics
    assert %{path: "delivery.pr_target", message: "must be a string"} in diagnostics
    assert %{path: "validation.commands", message: "must be a list"} in diagnostics
    assert %{path: "automation.posture", message: "must be a string"} in diagnostics
    assert %{path: "automation.profile", message: "must be a string"} in diagnostics
    assert %{path: "automation.completion_requirements", message: "must be a list"} in diagnostics
    assert %{path: "automation.policy_ref", message: "is not supported; policy_ref is derived from the resolved policy"} in diagnostics
    assert %{path: "automation.review", message: "must be a map"} in diagnostics
    assert %{path: "workflow.preset", message: "must be a string"} in diagnostics
    assert %{path: "workflow.modules", message: "must be a list"} in diagnostics
    assert %{path: "review_routing", message: "must be a map"} in diagnostics
    assert %{path: "harness.codex_home", message: "must be a string"} in diagnostics
    assert %{path: "bindings.local_file", message: "must be a string"} in diagnostics
    assert %{path: "bindings.require_local", message: "must be a boolean"} in diagnostics
  end

  test "invalid validation commands and list entries return indexed diagnostics" do
    path =
      write_manifest!("""
      project:
        slug: target-repo
        repository: github.com/example/target-repo
      docs:
        entrypoints:
          - ""
          - 123
      validation:
        commands:
          - not-a-map
          - name: ""
            command: 123
          - command: mix test
          - name: unit
            command:
      """)

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)

    assert %{path: "docs.entrypoints[0]", message: "must be a non-empty string"} in diagnostics
    assert %{path: "docs.entrypoints[1]", message: "must be a non-empty string"} in diagnostics
    assert %{path: "validation.commands[0]", message: "must be a map"} in diagnostics
    assert %{path: "validation.commands[1].name", message: "is required"} in diagnostics
    assert %{path: "validation.commands[1].command", message: "must be a string"} in diagnostics
    assert %{path: "validation.commands[2].name", message: "is required"} in diagnostics
    assert %{path: "validation.commands[3].command", message: "is required"} in diagnostics
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
      automation:
        completion_requirements:
        review:
      workflow:
        preset: default
        modules:
      harness: {}
      bindings: {}
      """)

    assert {:ok, %{config: config}} = Manifest.load(path)

    assert config["manifest"]["project"]["facts"] == %{}
    assert config["manifest"]["docs"]["entrypoints"] == []
    assert config["checks"] == []
    assert config["completion_requirements"] == []
    assert config["manifest"]["harness"]["codex_home"] == nil
    assert config["manifest"]["bindings"] == %{"local_file" => ".symphony.local.yml", "require_local" => false}

    assert config["manifest"]["workflow"]["modules"] == [
             "repo.docs",
             "validation.commands",
             "tracker.linear",
             "workspace",
             "codex.harness",
             "delivery.github_pr"
           ]
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
          - observability
          - unknown-module
      """)

    assert {:error, {:invalid_manifest, [%{path: "workflow.modules[1]", message: "unknown module: unknown-module"}]}} =
             Manifest.load(module_path)
  end

  test "invalid module list entries preserve their original indexes" do
    path =
      write_manifest!("""
      project:
        slug: target-repo
        repository: github.com/example/target-repo
      workflow:
        modules:
          - ""
          - 123
      """)

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)
    assert %{path: "workflow.modules[0]", message: "must be a non-empty string"} in diagnostics
    assert %{path: "workflow.modules[1]", message: "must be a non-empty string"} in diagnostics
  end

  test "module registry reports defensive diagnostics and optional workspace config" do
    assert ModuleRegistry.module_diagnostics("unknown-module", 2, %{}) == [
             %{path: "workflow.modules[2]", message: "unknown module: unknown-module"}
           ]

    assert ModuleRegistry.module_description("unknown-module") == "unknown module"

    assert {:ok, config} = ModuleRegistry.module_config("workspace", 0, %{"project" => %{}})
    assert config["hooks"]["timeout_ms"] == 60_000
    refute Map.has_key?(config["hooks"], "after_create")

    invalid_product_visual_review_manifest = %{
      "runtime" => %{
        "workflow_modules" => %{
          "product_visual_review" => %{"route_policy" => "invalid"}
        }
      }
    }

    assert {:error, %{path: "runtime.workflow_modules.product_visual_review", message: "route_policy is invalid"}} =
             ModuleRegistry.module_config("product_visual_review", 0, invalid_product_visual_review_manifest)
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

    assert config["manifest"]["workflow"]["modules"] == [
             "repo.docs",
             "validation.commands",
             "tracker.linear",
             "workspace",
             "codex.harness",
             "delivery.github_pr"
           ]

    assert config["manifest"]["project"]["app_kind"] == "local"
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
        kind: elixir
        app_kind: web
        facts:
          owner: platform
      vcs:
        mode: jj
        posture: stacked
      """)

    Workflow.set_workflow_file_path(path)
    if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()

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
    assert prompt =~ "VCS:\n- Mode: jj"
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
