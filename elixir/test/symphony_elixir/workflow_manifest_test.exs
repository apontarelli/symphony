defmodule SymphonyElixir.WorkflowManifestTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.Manifest
  alias SymphonyElixir.Workflow.ModuleRegistry
  alias SymphonyElixir.Workflow.PublishTarget

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

    assert config["publish_target"] == %{
             "repository" => "github.com/example/target-repo",
             "pr_target" => "release/next",
             "github_repository" => "example/target-repo",
             "display" => "example/target-repo:release/next"
           }

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
    assert policy["publish_target"]["display"] == "example/target-repo:release/next"
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

    assert prompt =~
             "`Merging` means human approval or guarded auto-land approval was granted; run the configured land flow and never bypass it with a direct merge command."

    refute prompt =~ "skill/flow"
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
      delivery:
        pr_target: main
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
        repository: github.com/example/target-repo
      delivery:
        pr_target: main
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

  test "runtime runners codex config validates and compiles into daemon settings" do
    path =
      write_manifest!("""
      version: 1
      project:
        slug: target-repo
        name: Target Repo
        repository: github.com/example/target-repo
      delivery:
        pr_target: main
      runtime:
        agent:
          default_runner: codex
          max_concurrent_startups: 2
        runners:
          codex:
            kind: codex_app_server
            command:
              - codex
              - --config
              - model_reasoning_effort=high
              - app-server
            model: gpt-5.4
            max_concurrent_startups: 1
      """)

    assert {:ok, %{config: config}} = Manifest.load(path)
    assert get_in(config, ["agent", "default_runner"]) == "codex"
    assert get_in(config, ["agent", "max_concurrent_startups"]) == 2
    assert get_in(config, ["runners", "codex", "kind"]) == "codex_app_server"
    assert get_in(config, ["runners", "codex", "command"]) == ["codex", "--config", "model_reasoning_effort=high", "app-server"]

    workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)
    Workflow.set_workflow_file_path(path)
    if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()

    assert Config.default_runner!()["command"] == ["codex", "--config", "model_reasoning_effort=high", "app-server"]
    assert Config.default_runner!()["model"] == "gpt-5.4"
    assert Config.max_concurrent_startups() == 1
  end

  test "runtime codex config is rejected with runner remediation" do
    path =
      write_manifest!("""
      version: 1
      project:
        slug: target-repo
        repository: github.com/example/target-repo
      delivery:
        pr_target: main
      runtime:
        codex:
          command: codex app-server
      """)

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)

    assert %{
             path: "runtime.codex",
             message: "is not supported; use runtime.runners.<name> (for Codex use runtime.runners.codex)"
           } in diagnostics
  end

  test "runtime runner kind rejects blank values" do
    path =
      write_manifest!("""
      version: 1
      project:
        slug: target-repo
        repository: github.com/example/target-repo
      delivery:
        pr_target: main
      runtime:
        agent:
          default_runner: codex
        runners:
          codex:
            kind: "   "
            command:
              - codex
              - app-server
      """)

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)

    assert [%{path: "runtime", message: message}] = diagnostics
    assert message =~ "runtime.runners.codex.kind is required"
  end

  test "review routing compiles into resolved policy and prompt context" do
    path =
      write_manifest!("""
      version: 1
      project:
        slug: target-repo
        name: Target Repo
        repository: github.com/example/target-repo
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
        repository: github.com/example/target-repo
        criticality: prototype
        deployment_coupling: none
      delivery:
        pr_target: main
      auto_land:
        posture: permissive
        required_checks:
          - security-review
        force_human_review_labels:
          - manual-review
        blocked_state: Human Review
        dry_run: true
      """)

    assert {:ok, %{config: config}} = Manifest.load(path)

    expected_auto_land = %{
      "posture" => "permissive",
      "required_checks" => ["security-review"],
      "force_human_review_labels" => ["manual-review"],
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
      project:
        repository: github.com/example/target-repo
      delivery:
        pr_target: main
      auto_land:
        posture: permissive
      """)

    assert {:ok, %{config: config}} = Manifest.load(path)
    assert config["auto_land"]["dry_run"] == true

    assert config["auto_land"]["force_human_review_labels"] == [
             "force-human-review",
             "human-review",
             "manual-review",
             "no-auto-land"
           ]
  end

  test "auto-land failure_state is rejected instead of accepted as a no-op" do
    path =
      write_manifest!("""
      version: 1
      project:
        repository: github.com/example/target-repo
      delivery:
        pr_target: main
      auto_land:
        posture: permissive
        failure_state: Needs Fix
      """)

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(path)
    assert %{path: "auto_land.failure_state", message: "is not supported; failed auto-land evidence routes to Rework"} in diagnostics
  end

  test "auto-land policy compiles explicit real landing opt-in" do
    path =
      write_manifest!("""
      version: 1
      project:
        repository: github.com/example/target-repo
        criticality: prototype
        deployment_coupling: none
      delivery:
        pr_target: main
      auto_land:
        posture: permissive
        dry_run: false
      """)

    assert {:ok, %{config: config}} = Manifest.load(path)
    assert config["auto_land"]["dry_run"] == false

    workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)
    Workflow.set_workflow_file_path(path)
    if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()

    settings = Config.settings!()
    assert settings.auto_land.dry_run == false
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
      delivery:
        pr_target: main
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
      delivery:
        pr_target: main
      docs:
      validation: {}
      automation:
        completion_requirements:
        review:
      workflow:
        preset: default
        modules:
      harness: {}
      """)

    assert {:ok, %{config: config}} = Manifest.load(path)

    assert config["manifest"]["project"]["facts"] == %{}
    assert config["manifest"]["docs"]["entrypoints"] == []
    assert config["checks"] == []
    assert config["completion_requirements"] == []
    assert config["manifest"]["harness"]["codex_home"] == nil

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
      delivery:
        pr_target: main
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
      delivery:
        pr_target: main
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

  test "module registry owns GitHub PR delivery publish target diagnostics and config" do
    invalid_publish_manifest = %{
      "project" => %{"repository" => "https://gitlab.com/example/target-repo"},
      "delivery" => %{"pr_target" => "origin/main"},
      "_field_sources" => %{"delivery_pr_target_explicit" => true}
    }

    assert ModuleRegistry.module_diagnostics("delivery.github_pr", 0, invalid_publish_manifest) == [
             %{
               path: "project.repository",
               message: "must be a GitHub repository URL for publish handoff",
               remediation: "Set `project.repository` to a GitHub HTTPS or SSH URL."
             },
             %{
               path: "delivery.pr_target",
               message: "must be an unambiguous branch name for publish handoff",
               remediation: "Use a branch name such as `main`, not `origin/main`."
             }
           ]

    valid_publish_manifest = %{
      "project" => %{"repository" => "git@github.com:example/target-repo.git"},
      "delivery" => %{"pr_target" => "project/integration"},
      "_field_sources" => %{"delivery_pr_target_explicit" => true}
    }

    assert {:ok, config} = ModuleRegistry.module_config("delivery.github_pr", 0, valid_publish_manifest)

    assert config["publish_target"] == %{
             "repository" => "git@github.com:example/target-repo.git",
             "pr_target" => "project/integration",
             "github_repository" => "example/target-repo",
             "display" => "example/target-repo:project/integration"
           }
  end

  test "publish target accepts supported GitHub URL forms and rejects defensive invalids" do
    assert PublishTarget.build("ssh://git@github.com/example/target-repo.git", "main") == %{
             "repository" => "ssh://git@github.com/example/target-repo.git",
             "pr_target" => "main",
             "github_repository" => "example/target-repo",
             "display" => "example/target-repo:main"
           }

    assert PublishTarget.resolve_policy(%{
             publish_target: %{
               repository: " https://github.com/example/target-repo.git ",
               pr_target: " main ",
               github_repository: "stale/wrong"
             }
           }) == %{
             repository: "https://github.com/example/target-repo.git",
             base_branch: "main",
             github_repository: "example/target-repo"
           }

    assert PublishTarget.resolve_policy(nil) == nil

    assert PublishTarget.resolve_policy(%{"publish_target" => %{"repository" => " ", "pr_target" => " "}}) == %{
             repository: nil,
             base_branch: nil,
             github_repository: nil
           }

    assert PublishTarget.github_repository_slug(123) == nil
    assert PublishTarget.github_repository_slug("https://gitlab.com/example/target-repo") == nil
    assert PublishTarget.remote_matches?(%{github_repository: "example/target-repo"}, "git@github.com:example/target-repo.git")
    refute PublishTarget.remote_matches?(%{github_repository: nil}, "git@github.com:example/target-repo.git")
    refute PublishTarget.remote_matches?(%{github_repository: "example/target-repo"}, "https://gitlab.com/example/target-repo")

    assert PublishTarget.build(123, "main") == nil
    assert PublishTarget.build("https://github.com/example", "main") == nil
    assert PublishTarget.config(%{"project" => %{"repository" => "https://github.com/example"}}) == %{}
    assert PublishTarget.ambiguous_pr_target?(123)
  end

  test "module registry prompt omits optional repository context when absent" do
    path =
      write_manifest!("""
      project:
        slug: no-repo
      delivery:
        pr_target: main
      """)

    assert {:ok, manifest} = Manifest.read(path)
    assert {:ok, %{prompt: prompt}} = ModuleRegistry.compile_manifest(manifest)

    assert prompt =~ "Project slug: no-repo"
    refute prompt =~ "Repository:"
  end

  test "default resolution does not require release-channel fields" do
    path =
      write_manifest!("""
      project:
        slug: target-repo
        repository: github.com/example/target-repo
      delivery:
        pr_target: main
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

  test "publish validation is skipped when GitHub PR delivery is not enabled" do
    repo_root = Path.join(System.tmp_dir!(), "symphony-non-publish-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_root)

    manifest =
      Manifest.default(repo_root, [])
      |> put_in(["workflow", "modules"], ["repo.docs", "validation.commands"])

    report = Manifest.validate(repo_root, manifest)

    refute Enum.any?(report.errors, &(&1.path == "project.repository"))
    refute Enum.any?(report.errors, &(&1.path == "delivery.pr_target"))
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
      delivery:
        pr_target: main
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
    assert settings.agent.default_runner == "codex"
    assert settings.agent.max_concurrent_agents == 10
    assert settings.agent.max_concurrent_startups == 2
    assert Config.default_runner!(settings)["kind"] == "codex_app_server"
    assert Config.default_runner!(settings)["command"] == ["codex", "app-server"]
    assert Config.default_runner!(settings)["model"] == "gpt-5.5"
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

  test "manifest team scope does not inherit repository slug as Linear project scope" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", "manifest-token")

    path =
      write_manifest!("""
      version: 1
      project:
        slug: hard-sets-solid
        name: Hard Sets Solid
        repository: github.com/example/hard-sets-solid
      delivery:
        pr_target: main
      runtime:
        tracker:
          team_key: HAR
          workspace_slug: antonio-pontarelli
      """)

    assert {:ok, %{config: config}} = Manifest.load(path)
    assert config["tracker"]["project_slug"] == nil
    assert config["tracker"]["team_key"] == "HAR"

    Workflow.set_workflow_file_path(path)
    if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()

    assert :ok = Config.validate!()

    settings = Config.settings!()
    assert settings.tracker.project_id == nil
    assert settings.tracker.project_slug == nil
    assert settings.tracker.team_key == "HAR"
    assert settings.tracker.workspace_slug == "antonio-pontarelli"
  end

  test "config error formatter reports manifest diagnostics with paths" do
    assert Config.format_error({:invalid_manifest, [%{path: "project.slug", message: "is required"}]}) ==
             "Invalid symphony.yml manifest: project.slug is required"

    assert Config.format_error(:missing_linear_api_token) ==
             "Linear API token missing in selected workflow config"

    assert Config.format_error(:missing_linear_project_scope) ==
             "Linear project_id, project_slug, or team_key missing in selected workflow config"

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
