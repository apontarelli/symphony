defmodule SymphonyElixir.WorkflowModuleRegistryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflow.ModuleRegistry

  @default_module_ids [
    "linear-operation",
    "implementation-loop",
    "vcs-commit-push",
    "pull-sync",
    "quality-gates",
    "automated-review",
    "auto-land-routing",
    "land-merge",
    "rework",
    "requirement-validation",
    "project-closeout",
    "debug-run-recovery"
  ]

  test "core module registry exposes v1 default modules with metadata" do
    assert length(ModuleRegistry.core_modules()) == length(@default_module_ids)
    assert Enum.map(ModuleRegistry.core_modules(), & &1.id) == @default_module_ids

    for workflow_module <- ModuleRegistry.core_modules() do
      assert workflow_module.id in @default_module_ids
      assert workflow_module.version == "v1"
      assert workflow_module.default? == true
      assert workflow_module.summary != ""
      assert workflow_module.content != ""
      assert workflow_module.compatibility.workflow_schema == "v1"
      assert workflow_module.pins.registry == "core-workflow-modules@v1"
      refute Regex.match?(~r/`symphony-[a-z-]+`/, workflow_module.content)
    end

    assert {:ok, linear_module} = ModuleRegistry.module_defaults("linear-operation", 0)
    assert linear_module.id == "linear-operation"
    assert linear_module.version == "v1"
    assert linear_module.default? == true
    assert linear_module.summary =~ "Linear"
    assert linear_module.compatibility.workflow_schema == "v1"
    assert linear_module.pins.registry == "core-workflow-modules@v1"
    assert linear_module.content =~ "Linear"
    refute linear_module.content =~ "symphony-linear"
  end

  test "core module registry resolves prompt metadata from the default preset" do
    assert {:ok, resolution} = ModuleRegistry.default_prompt_module_resolution()

    assert resolution.module_names == @default_module_ids
    assert resolution.policy_hash =~ ~r/^sha256:[a-f0-9]{64}$/
    assert %{name: "linear-operation", version: "v1"} in resolution.module_refs
    assert resolution.rendered =~ "Resolved modules: linear-operation@v1"
    assert resolution.rendered =~ "Policy hash: #{resolution.policy_hash}"
    assert resolution.rendered =~ "### Linear Operation"
    refute Regex.match?(~r/`symphony-[a-z-]+`/, resolution.rendered)
  end

  test "manifest prompt metadata does not require optional workflow modules" do
    assert {:ok, resolution} = ModuleRegistry.prompt_module_resolution(%{"workflow" => %{"preset" => "default"}})

    assert resolution.module_names == @default_module_ids
    assert resolution.rendered =~ "Resolved modules: linear-operation@v1"
    refute resolution.rendered =~ "product_visual_review@v1"
  end

  test "manifest prompt metadata reports selected prompt module config errors" do
    manifest = %{
      "workflow" => %{"preset" => "default", "modules" => ["product_visual_review"]},
      "runtime" => %{
        "workflow_modules" => %{
          "product_visual_review" => %{"route_policy" => "invalid"}
        }
      }
    }

    assert {:error, "route_policy is invalid"} = ModuleRegistry.prompt_module_resolution(manifest)
  end

  test "loaded workflows carry registry-backed prompt metadata" do
    assert {:ok, workflow} = Workflow.current()

    assert workflow.workflow_module_resolution.module_names == @default_module_ids
    assert workflow.workflow_module_resolution.rendered =~ "### Linear Operation"
    assert workflow.prompt_template =~ "You are an agent for this repository."
  end

  test "core module registry reports unknown module ids" do
    assert {:error, %{path: "workflow.modules[0]", message: "unknown module: missing-module"}} =
             ModuleRegistry.module_defaults("missing-module", 0)

    assert {:error, %{path: "workflow.modules[0]", message: "unknown module: missing-module"}} =
             ModuleRegistry.module_config("missing-module", 0, %{})
  end

  test "default preset compiles a self-contained core workflow prompt" do
    assert {:ok, prompt} = ModuleRegistry.compile_default_preset()

    assert prompt =~ "You are working on a Linear ticket `{{ issue.identifier }}`"
    assert prompt =~ "## Core Workflow Modules"
    assert prompt =~ "Module registry: core-workflow-modules@v1"
    assert prompt =~ "### Linear Operation"
    assert prompt =~ "### VCS Commit Push"
    assert prompt =~ "### Project Closeout"
    assert prompt =~ "### Auto Land Routing"
    assert prompt =~ "structured completion evidence"
    assert prompt =~ "<host>:<abs-workdir>@<short-sha>"
    assert prompt =~ "Use test-first development only when expected behavior is clear"
    assert prompt =~ "Do not force TDD for docs-only"
    assert prompt =~ "high-signal tests"
    assert prompt =~ "Commit and publish only after implementation validation"
    assert prompt =~ "A Requirement with no blocking implementation issue is a setup defect"
    assert prompt =~ "If unresolved Requirement issues remain"
    assert prompt =~ "### Acceptance Criteria"
    assert prompt =~ "### Confusions"
    assert prompt =~ "gh pr view --comments"
    assert prompt =~ "gh api repos/<owner>/<repo>/pulls/<pr>/comments"
    assert prompt =~ "gh pr view --json reviews"
    refute prompt =~ "## Related skills"
    refute prompt =~ ".codex/skills"
    refute Regex.match?(~r/`symphony-[a-z-]+`/, prompt)
  end

  test "core modules encode SDLC doctrine without global delivery skill dependencies" do
    assert {:ok, implementation_loop} = ModuleRegistry.module_defaults("implementation-loop", 0)
    assert implementation_loop.content =~ "Use test-first development only when expected behavior is clear"
    assert implementation_loop.content =~ "Do not force TDD for docs-only"
    assert implementation_loop.content =~ "high-signal tests"

    assert {:ok, vcs_commit_push} = ModuleRegistry.module_defaults("vcs-commit-push", 0)
    assert vcs_commit_push.content =~ "after implementation validation, required quality gates"
    assert vcs_commit_push.content =~ "no unresolved fix-required findings"

    assert {:ok, requirement_validation} = ModuleRegistry.module_defaults("requirement-validation", 0)
    assert requirement_validation.content =~ "validation artifacts, not implementation tickets"
    assert requirement_validation.content =~ "no blocking implementation issue is a setup defect"

    assert {:ok, project_closeout} = ModuleRegistry.module_defaults("project-closeout", 0)
    assert project_closeout.content =~ "durable repository docs"
    assert project_closeout.content =~ "If unresolved Requirement issues remain"

    for workflow_module <- [
          implementation_loop,
          vcs_commit_push,
          requirement_validation,
          project_closeout
        ] do
      refute Regex.match?(~r/`symphony-[a-z-]+`/, workflow_module.content)
      refute workflow_module.content =~ "WORKFLOW.md"
    end
  end

  test "preset compiler reports missing module ids" do
    preset = %{
      id: "custom",
      version: "v1",
      module_ids: ["linear-operation", "missing-module"]
    }

    assert {:error, {:unknown_core_workflow_module, "missing-module"}} =
             ModuleRegistry.compile_preset(preset)
  end

  test "preset compiler renders supplied core modules" do
    preset = %{
      id: "custom",
      version: "v1",
      module_ids: ["linear-operation"]
    }

    assert {:ok, prompt} = ModuleRegistry.compile_preset(preset)

    assert prompt =~ "Preset: custom@v1"
    assert prompt =~ "### Linear Operation"
    refute prompt =~ "### VCS Commit Push"
  end

  test "preset compiler rejects runtime config modules as core workflow modules" do
    preset = %{
      id: "custom",
      version: "v1",
      module_ids: ["repo.docs"]
    }

    assert {:error, {:not_core_workflow_module, "repo.docs"}} = ModuleRegistry.compile_preset(preset)
  end

  test "blank workflow prompt uses compiled default core modules" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "SID-292",
      title: "Create the v1 core workflow module registry",
      description: "Replace global skill dependencies.",
      state: "Todo",
      url: "https://linear.example/SID-292",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear ticket `SID-292`"
    assert prompt =~ "Identifier: SID-292"
    assert prompt =~ "## Core Workflow Modules"
    assert prompt =~ "### Linear Operation"
    assert prompt =~ "### Quality Gates"
    refute prompt =~ "## Related skills"
    refute Regex.match?(~r/`symphony-[a-z-]+`/, prompt)
  end
end
