defmodule SymphonyElixir.ProductVisualReviewTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflow.Manifest
  alias SymphonyElixir.WorkflowModules.ProductVisualReview
  alias SymphonyElixir.WorkflowModules.ProductVisualReview.Config, as: ProductVisualReviewConfig

  test "classify requires visual QA when changed files touch web product surfaces" do
    config = %ProductVisualReviewConfig{enabled: true}

    decision =
      ProductVisualReview.classify(config, [
        "packages/web/src/components/WorkoutEditor.tsx",
        "packages/web/src/components/WorkoutEditor.module.css"
      ])

    assert decision.module == "product_visual_review"
    assert decision.requirement == :required
    assert decision.reason == "changed files match product-facing routes"
    assert "packages/web/src/components/WorkoutEditor.tsx" in decision.matched_files
    assert "viewport_screenshots" in decision.checks
    assert "visual_qa_manifest" in decision.artifacts
  end

  test "classify skips backend-only changes by default" do
    config = %ProductVisualReviewConfig{enabled: true}

    decision =
      ProductVisualReview.classify(config, [
        "elixir/lib/symphony_elixir/orchestrator.ex",
        "elixir/test/symphony_elixir/orchestrator_status_test.exs"
      ])

    assert decision.requirement == :skip
    assert decision.reason == "no product-facing route trigger matched"
    assert decision.checks == []
    assert decision.artifacts == []
    assert decision.matched_files == []
  end

  test "classify recognizes nested Phoenix web surfaces" do
    config = %ProductVisualReviewConfig{enabled: true}

    decision =
      ProductVisualReview.classify(config, [
        "elixir/lib/symphony_elixir_web/live/dashboard_live.ex"
      ])

    assert decision.requirement == :required
    assert decision.matched_files == ["elixir/lib/symphony_elixir_web/live/dashboard_live.ex"]
  end

  test "classify recommends visual QA when issue labels indicate product work" do
    config = %ProductVisualReviewConfig{enabled: true}
    issue = %Issue{identifier: "SID-1", labels: ["backend", "frontend"]}

    decision = ProductVisualReview.classify(config, [], issue)

    assert decision.requirement == :recommended
    assert decision.reason == "issue labels indicate product-facing work"
    assert decision.matched_labels == ["frontend"]
  end

  test "classify honors explicit route policy overrides" do
    required = %ProductVisualReviewConfig{enabled: true, route_policy: "required"}
    recommended = %ProductVisualReviewConfig{enabled: true, route_policy: "recommended"}
    off = %ProductVisualReviewConfig{enabled: true, route_policy: "off"}
    disabled = %ProductVisualReviewConfig{enabled: false}

    assert %{requirement: :required, reason: "route policy required"} =
             ProductVisualReview.classify(required, [])

    assert %{requirement: :recommended, reason: "route policy recommended"} =
             ProductVisualReview.classify(recommended, [])

    assert %{requirement: :skip, reason: "route policy off", checks: []} =
             ProductVisualReview.classify(off, ["packages/web/src/App.tsx"])

    assert %{requirement: :skip, reason: "module disabled", checks: []} =
             ProductVisualReview.classify(disabled, ["packages/web/src/App.tsx"])
  end

  test "prompt section handles disabled, off, empty, custom, and portable paths" do
    assert ProductVisualReview.prompt_section(nil) == nil
    assert ProductVisualReview.prompt_section(%ProductVisualReviewConfig{enabled: false}) == nil
    assert ProductVisualReview.prompt_section(%ProductVisualReviewConfig{enabled: true, route_policy: "off"}) == nil

    web_prompt =
      ProductVisualReview.prompt_section(%ProductVisualReviewConfig{
        enabled: true,
        changed_file_triggers: [],
        artifacts: [],
        checks: ["custom_check"]
      })

    assert web_prompt =~ "Changed-file triggers:\n- none"
    assert web_prompt =~ "Artifact evidence:\n- none"
    assert web_prompt =~ "- `custom_check`"

    mobile_prompt =
      ProductVisualReview.prompt_section(%ProductVisualReviewConfig{
        enabled: true,
        project_kind: "mobile",
        checks: ["viewport_screenshots"]
      })

    assert mobile_prompt =~ "run the mobile equivalent"

    no_checks_prompt = ProductVisualReview.prompt_section(%ProductVisualReviewConfig{enabled: true, checks: []})

    assert no_checks_prompt =~ "Checks:\n- none"
  end

  test "classify tolerates missing changed-file trigger config" do
    config = %ProductVisualReviewConfig{enabled: true, changed_file_triggers: nil}

    decision = ProductVisualReview.classify(config, ["packages/web/src/App.tsx"])

    assert decision.requirement == :skip
    assert decision.matched_files == []
  end

  test "prompt builder renders product visual review through workflow module context" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_module_ids: ["product_visual_review"],
      workflow_modules_product_visual_review: %{
        enabled: true,
        project_kind: "web",
        route_policy: "auto"
      },
      prompt: "Ticket {{ issue.identifier }}\n\n{{ workflow.modules }}"
    )

    issue = %Issue{
      identifier: "SID-297",
      title: "Add visual QA workflow module",
      description: "Route product work to visual review",
      state: "Todo",
      url: "https://example.org/SID-297",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket SID-297"
    assert prompt =~ "## Workflow Module: product_visual_review"
    assert prompt =~ "Resolved modules: linear-operation@v1"
    assert prompt =~ "product_visual_review@v1"
    assert prompt =~ "Project kind: `web`"
    assert prompt =~ "Route policy: `auto`"
    assert prompt =~ "`viewport_screenshots`: capture Browser/Playwright screenshots"
    assert prompt =~ "tell Antonio which route/screen/state changed"
  end

  test "selected product visual review module rejects invalid config before prompt rendering" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_module_ids: ["product_visual_review"],
      workflow_modules_product_visual_review: %{
        enabled: true,
        route_policy: "invalid"
      },
      prompt: "Ticket {{ issue.identifier }}"
    )

    assert {:error, {:invalid_manifest, diagnostics}} = Manifest.load(Workflow.workflow_file_path())

    assert %{path: "runtime.workflow_modules.product_visual_review", message: "route_policy is invalid"} in diagnostics
  end

  test "workflow module config normalizes values from selected manifest module config" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_module_ids: ["product_visual_review"],
      workflow_modules_product_visual_review: %{
        enabled: true,
        project_kind: " MOBILE ",
        route_policy: " Recommended ",
        changed_file_triggers: [" app/**/* ", "", "app/**/*"],
        issue_label_triggers: [" UI ", "ui", ""],
        checks: [" viewport_screenshots ", "", "viewport_screenshots"],
        artifacts: [" manifest ", "", "manifest"]
      }
    )

    config = Config.settings!().workflow_modules.product_visual_review

    assert config.enabled == true
    assert config.project_kind == "mobile"
    assert config.route_policy == "recommended"
    assert config.changed_file_triggers == ["app/**/*"]
    assert config.issue_label_triggers == ["ui"]
    assert config.checks == ["viewport_screenshots"]
    assert config.artifacts == ["manifest"]
  end

  test "route evidence records required, recommended, skipped, and malformed payload states" do
    recommended = %ProductVisualReviewConfig{enabled: true, route_policy: "recommended"}

    assert %{
             requirement: :recommended,
             status: :missing,
             reason: "route policy recommended",
             required_action: nil
           } = ProductVisualReview.route_evidence(recommended, [], nil, nil)

    required = %ProductVisualReviewConfig{enabled: true, route_policy: "required"}

    assert %{
             requirement: :required,
             status: :blocked,
             required_action: "Run product visual QA or attach structured desktop/mobile evidence before handoff."
           } = ProductVisualReview.route_evidence(required, [], nil, %{})

    assert %{
             status: :blocked,
             checks: [],
             artifacts: [],
             required_action: "Run product visual QA or attach structured desktop/mobile evidence before handoff."
           } =
             ProductVisualReview.route_evidence(required, "not a file list", nil, %{
               status: :passed,
               checks: "not a list",
               artifacts: "not a list",
               reason: " "
             })

    assert %{status: :blocked, reason: "numeric status"} =
             ProductVisualReview.route_evidence(required, [], nil, %{status: 123, reason: "numeric status"})

    assert %{status: :blocked, reason: "visual diffs remain"} =
             ProductVisualReview.route_evidence(required, [], nil, %{status: "fix_required", reason: "visual diffs remain"})

    assert %{status: :blocked, reason: "agent skipped required visual QA"} =
             ProductVisualReview.route_evidence(required, [], nil, %{status: "skipped", reason: "agent skipped required visual QA"})

    assert %{status: :skipped, reason: "route policy off"} =
             ProductVisualReview.route_evidence(%ProductVisualReviewConfig{enabled: false}, [], nil, %{status: 123})
  end
end
