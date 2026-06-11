defmodule SymphonyElixir.Workflow.ModuleRegistry do
  @moduledoc false

  alias SymphonyElixir.Workflow.PublishTarget
  alias SymphonyElixir.WorkflowModules.ProductVisualReview
  alias SymphonyElixir.WorkflowModules.ProductVisualReview.Config, as: ProductVisualReviewConfig

  @terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @registry_pin "core-workflow-modules@v1"
  @compatibility %{
    workflow_schema: "v1",
    codex_app_server: "app-server",
    delivery_targets: ["main", "non-main"]
  }

  @type diagnostic :: %{
          required(:path) => String.t(),
          required(:message) => String.t(),
          optional(:remediation) => String.t()
        }
  @type workflow_module :: %{
          id: String.t(),
          version: String.t(),
          summary: String.t(),
          default?: boolean(),
          compatibility: map(),
          pins: map(),
          config: map(),
          prompt_sections: [String.t()],
          content: String.t() | nil,
          description: String.t()
        }
  @type preset_defaults :: %{
          id: String.t(),
          version: String.t(),
          modules: [String.t()],
          core_modules: [String.t()],
          config: map(),
          prompt_sections: [String.t()]
        }
  @type module_ref :: %{
          name: String.t(),
          version: String.t()
        }
  @type prompt_module_resolution :: %{
          modules: [workflow_module()],
          module_refs: [module_ref()],
          module_names: [String.t()],
          policy_hash: String.t(),
          rendered: String.t()
        }

  @runtime_module_ids ["repo.docs", "validation.commands", "tracker.linear", "workspace", "codex.harness", "delivery.github_pr"]
  @manifest_prompt_module_ids ["product_visual_review"]

  @core_module_ids [
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

  @presets %{
    "default" => %{
      id: "default",
      version: "v1",
      modules: @runtime_module_ids,
      core_modules: @core_module_ids,
      config: %{
        "checks" => [],
        "completion_requirements" => [],
        "delivery" => %{"pr_target" => "main"},
        "polling" => %{"interval_ms" => 30_000}
      },
      prompt_sections: [
        "This is an unattended orchestration session; never ask a human to perform follow-up actions.",
        "Route ticket states before acting: `Todo` starts work, `In Progress` continues work, `Rework` resets from review feedback, `Merging` runs the land flow, and terminal states stop.",
        "Maintain exactly one active `## Codex Workpad` comment as the source of truth for plan, acceptance criteria, validation, review evidence, and blockers.",
        "Before implementation, reproduce the current behavior, refine the plan, and sync the delivery target.",
        "Execute ticket-provided validation and the strongest feasible quality gate before handoff.",
        "Before Human Review or guarded auto-land routing, publish the PR, link it to the issue, ensure required PR metadata, sweep top-level and inline PR feedback, and confirm checks are green.",
        "Stop early only for missing required auth, permissions, or secrets; document the blocker and unblock action in the workpad.",
        "Final responses report completed actions and blockers only."
      ]
    }
  }

  @modules [
    %{
      id: "repo.docs",
      version: "v1",
      summary: "Repo instruction and durable docs routing.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "repo.docs@v1"},
      config: %{},
      prompt_sections: [
        "Treat the manifest docs entrypoints as the first repo-specific instructions to read before changing code."
      ],
      content: nil,
      description: "repo instruction and durable docs routing"
    },
    %{
      id: "validation.commands",
      version: "v1",
      summary: "Operator-defined validation gates.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "validation.commands@v1"},
      config: %{},
      prompt_sections: [
        "Use the manifest validation commands as the repo-owned quality gates for touched surfaces."
      ],
      content: nil,
      description: "operator-defined validation gates"
    },
    %{
      id: "tracker.linear",
      version: "v1",
      summary: "Linear tracker issue context and handoff states.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "tracker.linear@v1"},
      config: %{
        "tracker" => %{
          "kind" => "linear",
          "endpoint" => "https://api.linear.app/graphql",
          "api_key" => "$LINEAR_API_KEY",
          "project_id" => nil,
          "project_slug" => nil,
          "active_states" => ["Todo", "In Progress", "Merging", "Rework"],
          "terminal_states" => @terminal_states
        }
      },
      prompt_sections: [
        "Use Linear as the tracker and keep issue state, links, and the single workpad aligned with Symphony policy.",
        "`Human Review` means validated work is waiting for human approval; do not code while the issue is in that state.",
        "`Merging` means human approval or guarded auto-land approval was granted; run the configured land flow and never bypass it with a direct merge command.",
        "`Rework` means reviewer feedback requires a fresh planning pass, explicit feedback triage, implementation, validation, and republish."
      ],
      content: nil,
      description: "Linear tracker issue context and handoff states"
    },
    %{
      id: "workspace",
      version: "v1",
      summary: "Workspace checkout and lifecycle hooks.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "workspace@v1"},
      config: %{
        "workspace" => %{"root" => "~/code/symphony-workspaces"},
        "hooks" => %{"timeout_ms" => 60_000}
      },
      prompt_sections: [
        "Work only inside the assigned repository workspace."
      ],
      content: nil,
      description: "workspace checkout and lifecycle hooks"
    },
    %{
      id: "codex.harness",
      version: "v1",
      summary: "Isolated Codex harness CODEX_HOME policy.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "codex.harness@v1"},
      config: %{
        "agent" => %{
          "max_concurrent_agents" => 10,
          "max_turns" => 20,
          "max_retry_backoff_ms" => 300_000
        },
        "codex" => %{
          "command" => "codex app-server",
          "approval_policy" => %{
            "reject" => %{
              "sandbox_approval" => true,
              "rules" => true,
              "mcp_elicitations" => true
            }
          },
          "thread_sandbox" => "workspace-write",
          "turn_timeout_ms" => 3_600_000,
          "read_timeout_ms" => 5_000,
          "stall_timeout_ms" => 300_000,
          "execution_profiles" => %{
            "planner" => %{"reasoning_effort" => "high", "budget" => "standard"},
            "source_reviewer" => %{"reasoning_effort" => "medium", "budget" => "standard"},
            "test_reviewer" => %{"reasoning_effort" => "medium", "budget" => "standard"},
            "runtime_qa" => %{"reasoning_effort" => "medium", "budget" => "standard"},
            "product_visual_review" => %{"reasoning_effort" => "high", "budget" => "standard"},
            "docs_reviewer" => %{"reasoning_effort" => "medium", "budget" => "standard"},
            "security_reviewer" => %{"reasoning_effort" => "high", "budget" => "standard"},
            "synthesis" => %{"reasoning_effort" => "high", "budget" => "standard"}
          }
        },
        "quality_gate" => %{
          "enabled" => true,
          "source_max_concurrency" => 3,
          "max_repair_passes" => 1,
          "runtime_isolation" => "serialized",
          "reviewer_timeout_ms" => 1_200_000,
          "reviewer_max_retries" => 0
        }
      },
      prompt_sections: [
        "Run Codex with the configured runtime settings for implementation turns."
      ],
      content: nil,
      description: "isolated Codex harness CODEX_HOME policy"
    },
    %{
      id: "delivery.github_pr",
      version: "v1",
      summary: "GitHub pull request delivery defaults.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "delivery.github_pr@v1"},
      config: %{},
      prompt_sections: [
        "Use GitHub pull requests as the delivery artifact when handing work to human review."
      ],
      content: nil,
      description: "GitHub pull request delivery defaults"
    },
    %{
      id: "observability",
      version: "v1",
      summary: "Operator-visible status and dashboard evidence.",
      default?: false,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "observability@v1"},
      config: %{
        "observability" => %{
          "dashboard_enabled" => true,
          "refresh_ms" => 1_000,
          "render_interval_ms" => 16
        }
      },
      prompt_sections: [
        "Use the dashboard and status APIs as operator-visible evidence when relevant."
      ],
      content: nil,
      description: "operator-visible status and dashboard evidence"
    },
    %{
      id: "product_visual_review",
      version: "v1",
      summary: "Product-facing visual QA routing and evidence.",
      default?: false,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "product_visual_review@v1"},
      config: %{},
      prompt_sections: [],
      content: nil,
      description: "product-facing visual QA routing and evidence"
    },
    %{
      id: "linear-operation",
      version: "v1",
      summary: "Linear issue state, metadata, workpad, attachment, and comment operation.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "linear-operation@v1"},
      config: %{},
      prompt_sections: [],
      content: """
      Use Linear as the source of truth for issue state and review handoff.

      Start by fetching the explicit issue identifier. Route by the current state: Backlog is
      ineligible, Todo moves to In Progress before implementation, In Progress continues execution,
      Human Review waits for review, Rework restarts the implementation loop, Merging runs the
      land loop, and terminal states stop.

      Maintain exactly one active issue comment headed `## Codex Workpad`. Reuse that comment for
      plan, acceptance criteria, validation, blocker notes, and handoff evidence. Keep issue
      metadata current, attach the PR as a first-class issue link when possible, and avoid extra
      progress-summary comments.

      Prefer structured Linear tools when available. Use the runtime `linear_graphql` client for raw
      GraphQL operations when a structured tool does not expose the needed field or mutation. Do not
      use a Linear CLI fallback.
      """,
      description: "Linear issue state, metadata, workpad, attachment, and comment operation"
    },
    %{
      id: "implementation-loop",
      version: "v1",
      summary: "Planning, reproduction, implementation, validation, and workpad execution loop.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "implementation-loop@v1"},
      config: %{},
      prompt_sections: [],
      content: """
      Before implementation, reconcile the workpad with a hierarchical plan, explicit acceptance
      criteria, validation commands, and a compact environment stamp. Mirror ticket-authored
      Validation, Test Plan, or Testing sections as required checklist items.

      Use this required workpad template and keep it updated in place:

      ````md
      ## Codex Workpad

      ```text
      <host>:<abs-workdir>@<short-sha>
      ```

      ### Plan

      - [ ] 1. Parent task
        - [ ] 1.1 Child task

      ### Acceptance Criteria

      - [ ] Criterion

      ### Validation

      - [ ] targeted tests: `<command>`

      ### Notes

      - <timestamped progress note>

      ### Confusions

      - None.
      ````

      Reproduce the current behavior before source edits. The reproduction can be a command,
      deterministic rendered output, screenshot, or failing test. Record the signal in the workpad.

      Use test-first development only when expected behavior is clear and the change has a
      meaningful public seam, such as bug reproduction, domain rules, storage behavior, API or
      workflow contracts, permission logic, or non-trivial refactors.

      Do not force TDD for docs-only, harness/config, cosmetic, prototype, mechanical, or unclear
      product work; record the reason briefly in the workpad when skipping it.

      Implement the smallest change that satisfies the issue. Keep the workpad checklist current
      after each meaningful milestone. If tests are added or changed, use high-signal tests that
      protect observable behavior and avoid framework or wiring assertions.

      Prefer simple, obvious designs. Treat wrappers, pass-through helpers, generic interfaces,
      compatibility layers, and speculative abstractions as liabilities unless they remove real
      complexity, encode a useful boundary, or protect shipped behavior.

      For app, CLI, UI, or operator workflow changes, plan runtime QA against the changed journey
      before handoff. If the journey cannot run because of required external systems, record the
      exact blocked leg and human-verification need instead of calling the work complete.

      Only stop early for missing required auth, permissions, secrets, or unavailable required tools.
      For meaningful out-of-scope work, create a separate Backlog issue instead of expanding scope.
      """,
      description: "Planning, reproduction, implementation, validation, and workpad execution loop"
    },
    %{
      id: "vcs-commit-push",
      version: "v1",
      summary: "Version-control inspection, commit description, branch publication, and PR creation.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "vcs-commit-push@v1"},
      config: %{},
      prompt_sections: [],
      content: """
      Prefer Jujutsu when the workspace is a jj repository. Use git only when the repository is not
      jj-backed or a tool explicitly requires git compatibility. Inspect status and diff before
      committing or publishing.

      Commit and publish only after implementation validation, required quality gates, and automated review
      have no unresolved fix-required findings. Keep PR link evidence in Linear or the workpad before
      final handoff routing.

      Describe the current change with a Conventional Commit subject that includes the ticket ID,
      for example `feat(SID-292): create core workflow modules`. Commit only intended files and
      leave unrelated workspace changes untouched.

      Publish one bookmark or branch per ticket. Create or update the PR against the workflow policy
      delivery target. If the target is not main, set the PR base to that target and do not merge or
      promote work to main in v1. Ensure the PR title, body, labels, and Linear attachment reflect
      the current scope.
      """,
      description: "Version-control inspection, commit description, branch publication, and PR creation"
    },
    %{
      id: "pull-sync",
      version: "v1",
      summary: "Mainline sync, merge conflict handling, and workpad sync evidence.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "pull-sync@v1"},
      config: %{},
      prompt_sections: [],
      content: """
      Before implementation and before handoff, fetch the delivery target from origin. If the current
      change has no meaningful edits, start from the latest target. If it has edits, merge the latest
      target into the current change and resolve conflicts by preserving repo contracts.

      Record sync evidence in the workpad: merge or fetch source, clean versus conflicts-resolved
      result, and resulting short change or commit ID. After conflict resolution, rerun affected
      validation before publishing.
      """,
      description: "Mainline sync, merge conflict handling, and workpad sync evidence"
    },
    %{
      id: "quality-gates",
      version: "v1",
      summary: "Conditional validation gates before handoff.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "quality-gates@v1"},
      config: %{},
      prompt_sections: [],
      content: """
      After implementation validation, classify the diff before handoff. Run expensive gates only
      when the issue, labels, touched files, or risk profile require them.

      Required gates are changed-scope by default. Tests added or changed require a test-quality
      review of the touched scope. App, CLI, UI, or operator workflow changes require scenario QA to
      the true end state when runtime evidence is feasible. Product-facing UI changes require
      product visual review when that module is selected. Docs, commands, setup, CI, deployment,
      architecture, workflow, or runbooks require a touched-scope document alignment check.
      Security, auth, billing, persistence, migrations, external side effects, data integrity, or
      shared architecture seams require deeper automated review.

      Record the classifier result, required gates, command evidence, and pass/fix/block decision in
      the workpad. Do not move to Human Review while a required gate has unresolved fix-required
      findings.
      """,
      description: "Conditional validation gates before handoff"
    },
    %{
      id: "automated-review",
      version: "v1",
      summary: "Pre-handoff automated review and finding triage.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "automated-review@v1"},
      config: %{},
      prompt_sections: [],
      content: """
      Before handoff, run an independent automated review over the current diff, issue context,
      workpad, validation evidence, and relevant repo instructions. Prefer read-only reviewers for
      correctness, validation gaps, and maintainability when those resources are available.

      Review the changed scope with these lenses when relevant: correctness/regression risk,
      tests and validation quality, API/contracts/data flow, security and external side effects,
      performance or migrations, maintainability/code-quality/deslop, and source-of-truth drift.
      Verify surprising claims against the code before keeping them.

      Classify findings as fix-required, human-input-required, follow-up, or no-action.
      Fix-required findings block handoff until addressed and revalidated. Human-input-required
      findings are only for decisions or access that cannot be resolved autonomously. Follow-up
      findings must not expand the current ticket unless they invalidate acceptance criteria.

      Fix-required findings start another repair pass: fix the root cause, update or add honest
      regression coverage when behavior changed, rerun affected validation, and repeat review on the
      touched scope until no fix-required findings remain. Record review mode, reviewers, findings,
      fixes, rejected false positives, follow-ups, and final decision in the workpad.

      Before moving to Human Review, run a PR feedback sweep when a PR is attached or exists for the
      current branch. Identify the PR number, read top-level PR comments with `gh pr view --comments`,
      read inline review comments with `gh api repos/<owner>/<repo>/pulls/<pr>/comments`, and read
      review summaries/states with `gh pr view --json reviews`. Treat every actionable human or bot
      comment as blocking until code, tests, or docs are updated to address it, or an explicit
      justified pushback reply is posted on the thread. Update the workpad with each feedback item
      and resolution, rerun validation after feedback-driven changes, and repeat until no
      outstanding actionable feedback remains.
      """,
      description: "Pre-handoff automated review and finding triage"
    },
    %{
      id: "auto-land-routing",
      version: "v1",
      summary: "Guarded auto-land classification before final ticket routing.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "auto-land-routing@v1"},
      config: %{},
      prompt_sections: [],
      content: """
      Before final routing, run Auto-land route classification with the current workflow policy,
      issue labels, validation evidence, PR checks, structured PR feedback sweep, automated review result, and
      sync result.

      Record structured completion evidence for the handoff route classifier: validation checks,
      quality gates, scenario QA or blocked human-verification notes when relevant, product visual
      review evidence when selected, automated review, structured PR feedback sweep, route
      classification, sync evidence, issue labels, changed_files or change_manifest.changed_files,
      and any project-specific required auto-land checks. Changed file paths must be relative,
      normalized workspace paths; host validation rejects absolute paths, traversal, symlink escapes,
      generated runtime state, caches, logs, temporary app data, local secret files, and
      operator-local config. Record the selected handoff route in the workpad. When a PR exists, also
      record the decision in a PR handoff comment or existing PR handoff location.

      Treat dry-run auto-land as a visibility route: record that Symphony selected dry-run
      auto-land, move the issue to Human Review for visibility, and do not merge. Treat real
      auto-land as guarded landing only when the project explicitly sets `auto_land.dry_run: false`
      and all required evidence is present; route the issue to Merging so the existing land flow
      performs final check/review polling and the merge. If the decision selects human_review,
      rework, or blocked, move the issue to the selected state after recording diagnostics.
      """,
      description: "Guarded auto-land classification before final ticket routing"
    },
    %{
      id: "land-merge",
      version: "v1",
      summary: "Approved PR landing and merge loop.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "land-merge@v1"},
      config: %{},
      prompt_sections: [],
      content: """
      When the issue reaches Merging, locate the attached PR, confirm local validation is green, and
      inspect mergeability. If the PR conflicts with the delivery target, sync, resolve conflicts,
      revalidate, and push the update.

      Poll checks and review feedback until all blocking signals are clear. If checks fail, inspect
      logs, fix the issue, commit, push, and restart the watch. Merge only when checks are green,
      actionable feedback is resolved, and the target policy allows the merge. After merge, move the
      issue to Done.
      """,
      description: "Approved PR landing and merge loop"
    },
    %{
      id: "rework",
      version: "v1",
      summary: "Reviewer-requested rework reset flow.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "rework@v1"},
      config: %{},
      prompt_sections: [],
      content: """
      Treat Rework as a full approach reset. Re-read the issue, workpad, PR feedback, inline review
      comments, and human comments. Identify what will change in this attempt before editing code.

      Close or supersede the prior PR when workflow policy requires a fresh attempt. Create a fresh
      branch or bookmark from the delivery target, create a new workpad if the prior one is removed,
      rebuild the plan, reproduce the issue again when needed, and run the complete
      implement-validate-review-publish loop.
      """,
      description: "Reviewer-requested rework reset flow"
    },
    %{
      id: "requirement-validation",
      version: "v1",
      summary: "Requirement issue validation after implementation blockers finish.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "requirement-validation@v1"},
      config: %{},
      prompt_sections: [],
      content: """
      Issues labeled Requirement are validation artifacts, not implementation tickets. Do not create
      code or docs PRs directly from a Requirement issue.

      On dispatch, verify that blocking implementation issues are terminal and that their shipped
      work satisfies the requirement outcome. Record validation evidence, gaps, and the final
      requirement decision in the workpad. If a requirement gap needs implementation, create or link
      a separate implementation issue instead of editing from the Requirement.

      A Requirement with no blocking implementation issue is a setup defect unless the project has
      explicitly deferred or canceled it. Record the missing blocker relationship in the workpad and
      do not validate it as standalone prose or docs-only scope.
      """,
      description: "Requirement issue validation after implementation blockers finish"
    },
    %{
      id: "project-closeout",
      version: "v1",
      summary: "Project closeout validation, durable docs reconciliation, and follow-up creation.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "project-closeout@v1"},
      config: %{},
      prompt_sections: [],
      content: """
      Issues labeled Project Closeout run after the project's requirements are resolved. Verify the
      shipped outcome, reconcile durable repository docs when strategy, runbooks, or operator
      workflow changed, and create follow-up issues for deferred gaps.

      Closeout may edit repo docs when needed, but it should not reopen solved implementation scope.
      Summarize shipped, deferred, and blocked items in the workpad with validation evidence.

      If unresolved Requirement issues remain, or if unresolved Requirements are not linked as
      blockers, record that relationship gap in the workpad and stop closeout until every
      Requirement has a final disposition.
      """,
      description: "Project closeout validation, durable docs reconciliation, and follow-up creation"
    },
    %{
      id: "debug-run-recovery",
      version: "v1",
      summary: "Runtime incident diagnosis, stuck-run recovery, and blocker handling.",
      default?: true,
      compatibility: @compatibility,
      pins: %{registry: @registry_pin, module: "debug-run-recovery@v1"},
      config: %{},
      prompt_sections: [],
      content: """
      For stuck runs, retries, daemon failures, app-server failures, or infrastructure hangs, collect
      diagnostics before retrying broad operations. Capture affected tool, arguments, repo root,
      issue or session id, timestamp, process count when relevant, and log evidence.

      Correlate Linear issue identifiers, thread IDs, turn IDs, and session IDs across runtime logs.
      Classify failures as startup, turn failure, timeout, stall, unsupported tool call, or missing
      access. Prefer fixing the failing runtime wrapper or workflow contract over routing around it.
      Use the blocked-access path only for true missing required tools, auth, permissions, or
      secrets.
      """,
      description: "Runtime incident diagnosis, stuck-run recovery, and blocker handling"
    }
  ]

  @module_by_id Map.new(@modules, &{&1.id, &1})

  @spec preset(String.t()) :: {:ok, preset_defaults()} | {:error, diagnostic()}
  def preset(name) when is_binary(name) do
    case Map.fetch(@presets, name) do
      {:ok, defaults} -> {:ok, defaults}
      :error -> {:error, %{path: "workflow.preset", message: "unknown preset: #{name}"}}
    end
  end

  @spec core_modules() :: [workflow_module()]
  def core_modules do
    Enum.map(@core_module_ids, &Map.fetch!(@module_by_id, &1))
  end

  @spec default_modules(String.t()) :: {:ok, [String.t()]} | {:error, diagnostic()}
  def default_modules(preset_name) when is_binary(preset_name) do
    with {:ok, preset_defaults} <- preset(preset_name) do
      {:ok, preset_defaults.modules}
    end
  end

  @spec module_defaults(String.t(), non_neg_integer()) :: {:ok, workflow_module()} | {:error, diagnostic()}
  def module_defaults(name, index) when is_binary(name) and is_integer(index) and index >= 0 do
    case Map.fetch(@module_by_id, name) do
      {:ok, defaults} -> {:ok, defaults}
      :error -> {:error, %{path: "workflow.modules[#{index}]", message: "unknown module: #{name}"}}
    end
  end

  @spec module_description(String.t()) :: String.t()
  def module_description(name) when is_binary(name) do
    case Map.fetch(@module_by_id, name) do
      {:ok, defaults} -> Map.fetch!(defaults, :description)
      :error -> "unknown module"
    end
  end

  @spec module_diagnostics(String.t(), non_neg_integer(), map()) :: [diagnostic()]
  def module_diagnostics(name, index, manifest) when is_binary(name) and is_integer(index) and index >= 0 do
    case module_defaults(name, index) do
      {:ok, _defaults} -> module_manifest_diagnostics(name, manifest)
      {:error, diagnostic} -> [diagnostic]
    end
  end

  @spec module_config(String.t(), non_neg_integer(), map()) :: {:ok, map()} | {:error, diagnostic()}
  def module_config(name, index, manifest) when is_binary(name) and is_integer(index) and index >= 0 do
    with {:ok, defaults} <- module_defaults(name, index),
         [] <- module_manifest_diagnostics(name, manifest) do
      {:ok, deep_merge(defaults.config, module_manifest_config(name, manifest))}
    else
      {:error, diagnostic} -> {:error, diagnostic}
      [diagnostic | _rest] -> {:error, diagnostic}
    end
  end

  @spec module_prompt_sections(String.t(), non_neg_integer()) :: {:ok, [String.t()]} | {:error, diagnostic()}
  def module_prompt_sections(name, index) when is_binary(name) and is_integer(index) and index >= 0 do
    with {:ok, defaults} <- module_defaults(name, index) do
      {:ok, defaults.prompt_sections}
    end
  end

  @spec compile_default_preset() :: {:ok, String.t()} | {:error, term()}
  def compile_default_preset do
    with {:ok, resolution} <- default_prompt_module_resolution() do
      {:ok, render_core_prompt(%{id: "default", version: "v1"}, resolution.modules)}
    end
  end

  @spec compile_preset(%{
          id: String.t(),
          version: String.t(),
          module_ids: [String.t()]
        }) :: {:ok, String.t()} | {:error, term()}
  def compile_preset(%{id: id, version: version, module_ids: module_ids})
      when is_binary(id) and is_binary(version) and is_list(module_ids) do
    with {:ok, resolution} <- prompt_module_resolution_for_core_modules(module_ids) do
      {:ok, render_core_prompt(%{id: id, version: version}, resolution.modules)}
    end
  end

  @spec compile_manifest(map()) ::
          {:ok, %{prompt: String.t(), workflow_module_resolution: prompt_module_resolution()}} | {:error, term()}
  def compile_manifest(%{"workflow" => %{"preset" => preset_name}} = manifest) do
    with {:ok, preset_defaults} <- preset(preset_name),
         {:ok, resolution} <- prompt_module_resolution_for_manifest(preset_defaults, manifest) do
      {:ok,
       %{
         prompt: render_core_prompt(preset_defaults, resolution.modules, manifest),
         workflow_module_resolution: resolution
       }}
    end
  end

  @spec default_prompt_module_resolution() :: {:ok, prompt_module_resolution()} | {:error, term()}
  def default_prompt_module_resolution, do: prompt_module_resolution_for_core_modules(@core_module_ids)

  @spec prompt_module_resolution(map()) :: {:ok, prompt_module_resolution()} | {:error, term()}
  def prompt_module_resolution(%{"workflow" => %{"preset" => preset_name}} = manifest) do
    with {:ok, preset_defaults} <- preset(preset_name) do
      prompt_module_resolution_for_manifest(preset_defaults, manifest)
    end
  end

  defp prompt_module_resolution_for_manifest(%{core_modules: module_ids}, manifest) when is_list(module_ids) do
    module_ids = module_ids ++ manifest_prompt_module_ids(manifest)

    with {:ok, modules} <- fetch_prompt_modules(module_ids, manifest) do
      {:ok, build_prompt_module_resolution(modules)}
    end
  end

  defp prompt_module_resolution_for_core_modules(module_ids) do
    with {:ok, modules} <- fetch_core_modules(module_ids) do
      {:ok, build_prompt_module_resolution(modules)}
    end
  end

  defp manifest_prompt_module_ids(%{"workflow" => %{"modules" => modules}}) when is_list(modules) do
    Enum.filter(modules, &(&1 in @manifest_prompt_module_ids))
  end

  defp manifest_prompt_module_ids(_manifest), do: []

  defp fetch_core_modules(module_ids) do
    Enum.reduce_while(module_ids, {:ok, []}, fn module_id, {:ok, modules} ->
      case Map.fetch(@module_by_id, module_id) do
        {:ok, %{content: content} = module} when is_binary(content) ->
          {:cont, {:ok, [module | modules]}}

        {:ok, _module} ->
          {:halt, {:error, {:not_core_workflow_module, module_id}}}

        :error ->
          {:halt, {:error, {:unknown_core_workflow_module, module_id}}}
      end
    end)
    |> case do
      {:ok, modules} -> {:ok, Enum.reverse(modules)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_prompt_modules(module_ids, manifest) do
    Enum.reduce_while(module_ids, {:ok, []}, fn module_id, {:ok, modules} ->
      case fetch_prompt_module(module_id, manifest) do
        {:ok, module} -> {:cont, {:ok, [module | modules]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, modules} -> {:ok, Enum.reverse(modules)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_prompt_module("product_visual_review", manifest) do
    @module_by_id
    |> Map.fetch!("product_visual_review")
    |> product_visual_review_module(manifest)
  end

  defp fetch_prompt_module(module_id, _manifest) do
    {:ok, Map.fetch!(@module_by_id, module_id)}
  end

  defp product_visual_review_module(module, manifest) do
    with {:ok, config} <- product_visual_review_config(manifest) do
      content =
        ProductVisualReview.prompt_section(config) ||
          "Product visual review is disabled by workflow module configuration."

      {:ok, %{module | config: product_visual_review_config_map(config), content: content}}
    end
  end

  defp build_prompt_module_resolution(modules) do
    refs = Enum.map(modules, &module_ref/1)
    policy_hash = policy_hash(modules)

    %{
      modules: modules,
      module_refs: refs,
      module_names: Enum.map(refs, & &1.name),
      policy_hash: policy_hash,
      rendered: render_resolved_modules(modules, refs, policy_hash)
    }
  end

  defp module_ref(module), do: %{name: module.id, version: module.version}

  defp render_resolved_modules(modules, refs, policy_hash) do
    module_index = Enum.map_join(refs, ", ", &"#{&1.name}@#{&1.version}")
    rendered_modules = Enum.map_join(modules, "\n\n", &render_core_module/1)

    """
    Resolved modules: #{module_index}
    Policy hash: #{policy_hash}

    #{rendered_modules}
    """
    |> String.trim()
  end

  defp policy_hash(modules) do
    material =
      Enum.map_join(modules, "\n", fn module ->
        "#{module.id}@#{module.version}:#{hash(module.content)}"
      end)

    "sha256:" <> hash(material)
  end

  defp hash(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp render_core_prompt(preset, modules, manifest \\ nil) do
    module_index =
      modules
      |> Enum.map_join("\n", fn module ->
        "- #{module.id}@#{module.version}: #{module.summary}"
      end)

    rendered_modules = Enum.map_join(modules, "\n\n", &render_core_module/1)

    [
      "You are working on a Linear ticket `{{ issue.identifier }}`",
      "",
      manifest_context(manifest),
      "{% if attempt %}",
      "Continuation context:",
      "",
      "- This is retry attempt {{ attempt }} because the ticket is still in an active state.",
      "- Resume from the current workspace state instead of restarting from scratch.",
      "- Do not repeat already-completed investigation or validation unless needed for new code changes.",
      "- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.",
      "{% endif %}",
      "",
      "Issue context:",
      "Identifier: {{ issue.identifier }}",
      "Title: {{ issue.title }}",
      "Current status: {{ issue.state }}",
      "Labels: {{ issue.labels }}",
      "URL: {{ issue.url }}",
      "",
      "Description:",
      "{% if issue.description %}",
      "{{ issue.description }}",
      "{% else %}",
      "No description provided.",
      "{% endif %}",
      "",
      "Instructions:",
      "",
      "1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.",
      "2. Only stop early for a true blocker: missing required auth, permissions, secrets, or unavailable required tools.",
      "3. Final message must report completed actions and blockers only. Do not include next steps for the user.",
      "4. Work only in the provided repository copy. Do not touch any other path.",
      "",
      "## Core Workflow Modules",
      "",
      "Module registry: #{@registry_pin}",
      "Preset: #{preset.id}@#{preset.version}",
      "",
      "Default module set:",
      module_index,
      "",
      rendered_modules
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp manifest_context(nil), do: []

  defp manifest_context(manifest) do
    project = manifest["project"]
    docs = manifest["docs"]["entrypoints"]
    facts = project["facts"]
    validation_commands = manifest["validation"]["commands"]
    automation = manifest["automation"]
    completion_requirements = automation["completion_requirements"]
    review = Map.get(automation, "review")
    review_routing = Map.get(manifest, "review_routing")
    vcs = manifest["vcs"]
    delivery = manifest["delivery"]
    workflow = manifest["workflow"]

    [
      "Project context:",
      "Project: #{project["name"]}",
      "Project slug: #{project["slug"]}",
      maybe_line("Repository", project["repository"]),
      "Project kind: #{project["kind"]}",
      "App kind: #{project["app_kind"]}",
      "Automation posture: #{automation["posture"]}",
      prompt_map_section("Project facts", facts),
      prompt_list_section("Docs entrypoints", docs),
      prompt_vcs_section(vcs),
      prompt_delivery_section(delivery),
      prompt_command_section(validation_commands),
      prompt_list_section("Completion requirements", completion_requirements),
      prompt_review_section(review),
      prompt_review_routing_section(review_routing),
      prompt_manifest_module_section(workflow),
      ""
    ]
  end

  defp render_core_module(module) do
    """
    ### #{module_title(module.id)}

    Metadata:
    - id: `#{module.id}`
    - version: `#{module.version}`
    - summary: #{module.summary}
    - default inclusion: #{module.default?}
    - compatibility: #{inspect(module.compatibility)}
    - pins: #{inspect(module.pins)}

    #{String.trim(module.content)}
    """
    |> String.trim()
  end

  defp prompt_manifest_module_section(%{"preset" => preset_name, "modules" => modules}) do
    {:ok, preset} = preset(preset_name)

    module_sections =
      modules
      |> Enum.with_index()
      |> Enum.flat_map(fn {name, index} ->
        {:ok, prompt_sections} = module_prompt_sections(name, index)
        Enum.map(prompt_sections, &"- #{&1}")
      end)

    ["Manifest modules:" | Enum.map(preset.prompt_sections, &"- #{&1}") ++ module_sections]
  end

  defp module_title(id) do
    id
    |> String.split(~r/[-_]/)
    |> Enum.map_join(" ", &title_word/1)
  end

  defp title_word("vcs"), do: "VCS"
  defp title_word(word), do: String.capitalize(word)

  defp maybe_line(_label, nil), do: nil
  defp maybe_line(label, value), do: "#{label}: #{value}"

  defp prompt_list_section(_title, []), do: []

  defp prompt_list_section(title, values) do
    [title <> ":" | Enum.map(values, &"- #{&1}")]
  end

  defp prompt_map_section(_title, values) when values == %{}, do: []

  defp prompt_map_section(title, values) do
    lines =
      values
      |> prompt_map_entries()
      |> Enum.map(fn {key, value} -> "- #{key}: #{prompt_value(value)}" end)

    [title <> ":" | lines]
  end

  defp prompt_map_entries(values, prefix \\ nil) do
    values
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.flat_map(fn {key, value} ->
      path = if prefix, do: "#{prefix}.#{key}", else: to_string(key)

      case value do
        map when is_map(map) and map_size(map) > 0 -> prompt_map_entries(map, path)
        _value -> [{path, value}]
      end
    end)
  end

  defp prompt_value(value) when is_binary(value), do: value
  defp prompt_value(value), do: inspect(value)

  defp prompt_vcs_section(vcs) do
    [
      "VCS:",
      "- Mode: #{vcs["mode"]}",
      "- Default branch: #{vcs["default_branch"]}"
    ]
    |> maybe_append("posture", vcs["posture"])
  end

  defp maybe_append(lines, _label, nil), do: lines
  defp maybe_append(lines, label, value), do: lines ++ ["- #{String.capitalize(label)}: #{value}"]

  defp prompt_delivery_section(%{"pr_target" => pr_target}) do
    [
      "Delivery:",
      "- PR target: #{pr_target}"
    ]
  end

  defp prompt_review_section(nil), do: []

  defp prompt_review_section(review) do
    [
      "Review policy:"
      | review
        |> Enum.sort_by(fn {key, _value} -> key end)
        |> Enum.map(fn {key, value} -> "- #{key}: #{prompt_value(value)}" end)
    ]
  end

  defp prompt_review_routing_section(nil), do: []

  defp prompt_review_routing_section(review_routing) do
    prompt_map_section("Review routing", review_routing)
  end

  defp prompt_command_section([]), do: ["Validation commands:", "- Use the repo-local validation gate that matches the changed surface."]

  defp prompt_command_section(commands) do
    ["Validation commands:" | Enum.map(commands, &"- #{&1["name"]}: #{&1["command"]}")]
  end

  defp module_manifest_diagnostics("product_visual_review", manifest) do
    case product_visual_review_config(manifest) do
      {:ok, _config} -> []
      {:error, message} -> [%{path: "runtime.workflow_modules.product_visual_review", message: message}]
    end
  end

  defp module_manifest_diagnostics("delivery.github_pr", manifest), do: PublishTarget.diagnostics(manifest)

  defp module_manifest_diagnostics(_name, _manifest), do: []

  defp module_manifest_config("tracker.linear", manifest) do
    project = Map.get(manifest, "project", %{})

    %{}
    |> maybe_put_tracker_value("project_id", Map.get(project, "id"))
    |> maybe_put_tracker_value("project_slug", Map.get(project, "slug"))
    |> case do
      tracker when map_size(tracker) > 0 -> %{"tracker" => tracker}
      _tracker -> %{}
    end
  end

  defp module_manifest_config("workspace", manifest) do
    case get_in(manifest, ["project", "repository"]) do
      repository when is_binary(repository) -> %{"hooks" => %{"after_create" => "git clone --depth 1 #{shell_quote(repository)} ."}}
      _repository -> %{}
    end
  end

  defp module_manifest_config("delivery.github_pr", manifest), do: PublishTarget.config(manifest)

  defp module_manifest_config("product_visual_review", manifest) do
    {:ok, config} = product_visual_review_config(manifest)
    %{"workflow_modules" => %{"product_visual_review" => product_visual_review_config_map(config)}}
  end

  defp module_manifest_config(_name, _manifest), do: %{}

  defp maybe_put_tracker_value(config, key, value) when is_binary(value) and value != "", do: Map.put(config, key, value)
  defp maybe_put_tracker_value(config, _key, _value), do: config

  defp product_visual_review_config(manifest) do
    attrs =
      %{"enabled" => true}
      |> deep_merge(get_in(manifest, ["runtime", "workflow_modules", "product_visual_review"]) || %{})

    %ProductVisualReviewConfig{}
    |> ProductVisualReviewConfig.changeset(attrs)
    |> Ecto.Changeset.apply_action(:validate)
    |> case do
      {:ok, config} -> {:ok, config}
      {:error, changeset} -> {:error, format_changeset_errors(changeset)}
    end
  end

  defp product_visual_review_config_map(%ProductVisualReviewConfig{} = config) do
    config
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join(", ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
