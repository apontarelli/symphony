defmodule SymphonyElixir.WorkflowModuleRegistryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflow.{LandingAuthority, ModuleRegistry}

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
    "project-closeout",
    "debug-run-recovery"
  ]

  test "landing authority owns the auto-land and merge workflow modules" do
    modules = LandingAuthority.modules(%{workflow_schema: "v1"}, "registry@v1")

    assert Enum.map(modules, & &1.id) == ["auto-land-routing", "land-merge"]
    assert Enum.all?(modules, &(&1.compatibility == %{workflow_schema: "v1"}))
    assert Enum.all?(modules, &(&1.pins.registry == "registry@v1"))

    assert Enum.find(modules, &(&1.id == "auto-land-routing")).content =~
             "The host validates the evidence, publishes and links the pull request"

    land_merge = Enum.find(modules, &(&1.id == "land-merge"))
    assert land_merge.content =~ "Current status` is `Merging`"
    assert land_merge.content =~ "Do not create a new branch, bookmark, or pull request"
    assert land_merge.content =~ "Merge only when checks are green"
    assert land_merge.content =~ "Immediately before merge, read the delivery-target revision"
    assert land_merge.content =~ "If target changes after validation"
  end

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

  test "codex harness routes GPT-5.6 models by workload" do
    assert {:ok, harness_module} = ModuleRegistry.module_defaults("codex.harness", 0)
    runner = get_in(harness_module, [:config, "runners", "codex"])
    profiles = runner["execution_profiles"]

    assert runner["model"] == "gpt-5.6-sol"

    assert Map.new(profiles, fn {name, profile} -> {name, profile["model"]} end) == %{
             "docs_reviewer" => "gpt-5.6-luna",
             "product_visual_review" => "gpt-5.6-sol",
             "runtime_qa" => "gpt-5.6-terra",
             "security_reviewer" => "gpt-5.6-sol",
             "source_reviewer" => "gpt-5.6-sol",
             "test_reviewer" => "gpt-5.6-terra"
           }
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

    assert resolution.rendered =~
             "If Human Review has no branch, PR, or implementation diff"
  end

  test "manifest prompt metadata does not require optional workflow modules" do
    assert {:ok, resolution} = ModuleRegistry.prompt_module_resolution(%{"workflow" => %{"preset" => "default"}})

    assert resolution.module_names == @default_module_ids
    assert resolution.rendered =~ "Resolved modules: linear-operation@v1"
    refute resolution.rendered =~ "product_visual_review@v1"
  end

  test "manifest prompt metadata reports selected prompt module config errors" do
    manifest = %{
      "workflow" => %{
        "preset" => "default",
        "modules" => ["product_visual_review"],
        "config" => %{
          "product_visual_review" => %{"route_policy" => "invalid"}
        }
      }
    }

    assert {:error, "route_policy is invalid"} = ModuleRegistry.prompt_module_resolution(manifest)
  end

  test "product visual review module config defaults when selected without explicit config" do
    manifest = %{"workflow" => %{"preset" => "default", "modules" => ["product_visual_review"]}}

    assert {:ok, config} = ModuleRegistry.module_config("product_visual_review", 0, manifest)
    assert get_in(config, ["workflow_modules", "product_visual_review", "enabled"]) == true
    assert get_in(config, ["workflow_modules", "product_visual_review", "route_policy"]) == "auto"
  end

  test "workspace module clone hook checks out the selected branch" do
    root = Path.join(System.tmp_dir!(), "symphony-generated-hook-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    destination = Path.join(root, "destination")
    git_config = Path.join(root, "gitconfig")
    File.mkdir_p!(source)
    File.mkdir_p!(destination)
    on_exit(fn -> File.rm_rf!(root) end)

    {_, 0} = System.cmd("git", ["init", "-b", "main", source], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", source, "config", "user.name", "Symphony Test"], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", source, "config", "user.email", "symphony@example.test"], stderr_to_stdout: true)
    File.write!(Path.join(source, "README.md"), "main\n")
    {_, 0} = System.cmd("git", ["-C", source, "add", "README.md"], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", source, "commit", "-m", "main"], stderr_to_stdout: true)
    main_head = git_revision!(source, ["main"])

    {_, 0} = System.cmd("git", ["-C", source, "switch", "-c", "release/2026"], stderr_to_stdout: true)
    File.write!(Path.join(source, "README.md"), "release\n")
    {_, 0} = System.cmd("git", ["-C", source, "commit", "-am", "release"], stderr_to_stdout: true)
    release_head = git_revision!(source, ["release/2026"])

    manifest = %{
      "project" => %{"repository" => "https://github.com/example/repo"},
      "vcs" => %{"default_branch" => "release/2026"}
    }

    assert {:ok, config} = ModuleRegistry.module_config("workspace", 0, manifest)
    hook = config["hooks"]["after_create"]
    assert hook =~ "--branch 'release/2026'"

    File.write!(git_config, "[url \"#{source}\"]\ninsteadOf = https://github.com/example/repo\n")

    assert {_, 0} =
             System.cmd(
               "sh",
               ["-lc", hook],
               cd: destination,
               env: [{"GIT_CONFIG_GLOBAL", git_config}, {"GIT_CONFIG_NOSYSTEM", "1"}],
               stderr_to_stdout: true
             )

    assert git_revision!(destination, ["HEAD"]) == release_head
    refute git_revision!(destination, ["HEAD"]) == main_head
  end

  defp git_revision!(directory, args) do
    {output, 0} = System.cmd("git", ["-C", directory, "rev-parse" | args], stderr_to_stdout: true)
    String.trim(output)
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

    assert prompt =~ "Role: You are an autonomous software-engineering agent resolving Linear ticket `{{ issue.identifier }}`."
    assert prompt =~ "Goal: Complete the ticket in the assigned workspace"
    assert prompt =~ "End the turn after reaching the workflow-defined handoff or terminal state."
    assert prompt =~ "Stop early only when required auth, permissions, secrets, or tools are unavailable; record the exact blocker and unblock condition."
    assert prompt =~ "Success criteria:"
    assert prompt =~ "Autonomy and boundaries:"
    refute prompt =~ "Metadata:"
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
    assert prompt =~ "Prefer simple, obvious designs"
    assert prompt =~ "plan runtime QA against the changed journey"
    assert prompt =~ "Do not create, move, push, or delete a branch or bookmark."
    assert prompt =~ "Do not create, update, merge, or close a pull request."
    assert prompt =~ "Leave validated implementation changes for the host to publish."
    assert prompt =~ "Run this module only when the prompt's `Current status` is `Merging`."
    assert prompt =~ "Required gates are changed-scope by default"
    assert prompt =~ "scenario QA to"
    assert prompt =~ "Review the changed scope with these lenses"
    assert prompt =~ "Fix-required findings start another repair pass"
    assert prompt =~ "Read the Linear"
    assert prompt =~ "Project PDR"
    assert prompt =~ "validate each one with concrete"
    assert prompt =~ "Story Validation Matrix"
    assert prompt =~ "future host-owned"
    assert prompt =~ "### Acceptance Criteria"
    assert prompt =~ "### Confusions"
    assert prompt =~ "For implementation states, read an attached PR's"
    assert prompt =~ "Do not post replies or modify the PR from an implementation worker."
    assert prompt =~ "Merge only when checks are green"
    refute prompt =~ "## Related skills"
    refute prompt =~ ".codex/skills"
    refute Regex.match?(~r/`symphony-[a-z-]+`/, prompt)
  end

  test "core modules encode SDLC doctrine without global delivery skill dependencies" do
    assert {:ok, implementation_loop} = ModuleRegistry.module_defaults("implementation-loop", 0)
    assert implementation_loop.content =~ "Use test-first development only when expected behavior is clear"
    assert implementation_loop.content =~ "Do not force TDD for docs-only"
    assert implementation_loop.content =~ "high-signal tests"
    assert implementation_loop.content =~ "Prefer simple, obvious designs"
    assert implementation_loop.content =~ "plan runtime QA against the changed journey"

    assert {:ok, quality_gates} = ModuleRegistry.module_defaults("quality-gates", 0)
    assert quality_gates.content =~ "Required gates are changed-scope by default"
    assert quality_gates.content =~ "scenario QA to"
    assert quality_gates.content =~ "product visual review when that module is selected"

    assert {:ok, automated_review} = ModuleRegistry.module_defaults("automated-review", 0)
    assert automated_review.content =~ "Review the changed scope with these lenses"
    assert automated_review.content =~ "Fix-required findings start another repair pass"

    assert {:ok, vcs_commit_push} = ModuleRegistry.module_defaults("vcs-commit-push", 0)
    assert vcs_commit_push.content =~ "implementation validation"
    assert vcs_commit_push.content =~ "required quality gates"
    assert vcs_commit_push.content =~ "no unresolved"
    assert vcs_commit_push.content =~ "Leave validated implementation changes for the host"
    assert vcs_commit_push.content =~ "Do not create, move, push, or"
    assert vcs_commit_push.content =~ "Do not create, update, merge, or close a pull request"
    assert vcs_commit_push.content =~ "Current status` is `Merging`"

    assert {:ok, project_closeout} = ModuleRegistry.module_defaults("project-closeout", 0)
    assert project_closeout.content =~ "durable repository docs"
    assert project_closeout.content =~ "in-scope user story/problem"
    assert project_closeout.content =~ "Story Validation Matrix"
    assert project_closeout.content =~ "validated, failed, deferred, and blocked"
    assert project_closeout.content =~ "future host-owned"
    assert project_closeout.content =~ "unresolved implementation blockers"

    for workflow_module <- [
          implementation_loop,
          quality_gates,
          automated_review,
          vcs_commit_push,
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

    assert prompt =~ "Role: You are an autonomous software-engineering agent resolving Linear ticket `SID-292`."
    assert prompt =~ "Identifier: SID-292"
    assert prompt =~ "## Core Workflow Modules"
    assert prompt =~ "Execution role: `implementation`."
    assert prompt =~ "### Linear Operation"
    assert prompt =~ "### Quality Gates"
    refute prompt =~ "### Land Merge"
    assert prompt =~ "Keep the host-owned deterministic branch and pull request for routine rework"
    assert prompt =~ "do not push, create or mutate pull requests, merge, deploy"
    refute prompt =~ "## Related skills"
    refute Regex.match?(~r/`symphony-[a-z-]+`/, prompt)

    default_state_prompt = PromptBuilder.build_prompt(%{issue | state: nil})
    assert default_state_prompt =~ "Execution role: `implementation`."
    refute default_state_prompt =~ "### Land Merge"
  end

  test "Merging issues render only landing core modules" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "SID-293",
      title: "Land the approved pull request",
      description: "Complete guarded landing.",
      state: "Merging",
      url: "https://linear.example/SID-293",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Execution role: `landing`."
    assert prompt =~ "Goal: Land the existing approved pull request"
    assert prompt =~ "Active landing module set:"
    assert prompt =~ "### Linear Operation"
    assert prompt =~ "### Land Merge"
    assert prompt =~ "You may perform only the remote delivery writes required to land that pull request"
    assert prompt =~ "### Debug Run Recovery"
    refute prompt =~ "### Implementation Loop"
    refute prompt =~ "### VCS Commit Push"
    refute prompt =~ "### Pull Sync"
    refute prompt =~ "### Quality Gates"
    refute prompt =~ "### Automated Review"
    refute prompt =~ "### Auto Land Routing"
    refute prompt =~ "### Rework"
    refute prompt =~ "### Project Closeout"
  end
end
