defmodule SymphonyElixir.WorkflowModulesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflow.ModuleRegistry

  @default_module_ids [
    "linear-operation",
    "implementation-loop",
    "vcs-commit-push",
    "pull-sync",
    "quality-gates",
    "automated-review",
    "land-merge",
    "rework",
    "requirement-validation",
    "project-closeout",
    "debug-run-recovery"
  ]

  test "core module registry exposes v1 default modules with metadata" do
    assert length(ModuleRegistry.core_modules()) == 11
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

  test "core module registry reports unknown module ids" do
    assert {:error, %{path: "workflow.modules[0]", message: "unknown module: missing-module"}} =
             ModuleRegistry.module_defaults("missing-module", 0)
  end

  test "default preset compiles a self-contained core workflow prompt" do
    assert {:ok, prompt} = ModuleRegistry.compile_default_preset()

    assert prompt =~ "You are working on a Linear ticket `{{ issue.identifier }}`"
    assert prompt =~ "## Core Workflow Modules"
    assert prompt =~ "Module registry: core-workflow-modules@v1"
    assert prompt =~ "### Linear Operation"
    assert prompt =~ "### VCS Commit Push"
    assert prompt =~ "### Project Closeout"
    assert prompt =~ "<host>:<abs-workdir>@<short-sha>"
    assert prompt =~ "### Acceptance Criteria"
    assert prompt =~ "### Confusions"
    assert prompt =~ "gh pr view --comments"
    assert prompt =~ "gh api repos/<owner>/<repo>/pulls/<pr>/comments"
    assert prompt =~ "gh pr view --json reviews"
    refute prompt =~ "## Related skills"
    refute prompt =~ ".codex/skills"
    refute Regex.match?(~r/`symphony-[a-z-]+`/, prompt)
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
