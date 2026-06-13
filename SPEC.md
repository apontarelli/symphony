# Symphony Service Specification

Status: Draft v1 (language-agnostic)

Purpose: Define a service that orchestrates coding agents to get project work done.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and
`OPTIONAL` in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract, but this
specification does not prescribe one universal policy. Implementations MUST document the selected
behavior.

## 1. Problem Statement

Symphony is a long-running automation service that continuously reads work from an issue tracker
(Linear in this specification version), creates an isolated workspace for each issue, and runs a
coding agent session for that issue inside the workspace.

The service solves four operational problems:

- It turns issue execution into a repeatable daemon workflow instead of manual scripts.
- It isolates agent execution in per-issue workspaces so agent commands run only inside per-issue
  workspace directories.
- It lets target repositories commit a thin `symphony.yml` manifest while Symphony owns the
  workflow modules, compiled workflow generation, and harness runtime policy.
- It preserves project-specific documentation, setup, and style ownership in the target repository
  instead of copying Symphony orchestration policy into each repo.
- It provides enough observability to operate and debug multiple concurrent agent runs.

Implementations are expected to document their trust and safety posture explicitly. This
specification does not require a single approval, sandbox, or operator-confirmation policy; some
implementations target trusted environments with a high-trust configuration, while others require
stricter approvals or sandboxing.

Important boundary:

- Symphony is a scheduler/runner and tracker reader.
- Ticket writes (state transitions, comments, PR links) are typically performed by the coding agent
  using tools available in the compiled workflow runtime environment.
- A successful run can end at a workflow-defined handoff state (for example `Human Review`), not
  necessarily `Done`.

## 2. Goals and Non-Goals

### 2.1 Goals

- Poll the issue tracker on a fixed cadence and dispatch work with bounded concurrency.
- Maintain a single authoritative orchestrator state for dispatch, retries, and reconciliation.
- Create deterministic per-issue workspaces and preserve them across runs.
- Stop active runs when issue state changes make them ineligible.
- Recover from transient failures with exponential backoff.
- Resolve a repository-owned `symphony.yml` manifest through Symphony-owned workflow modules into a
  compiled workflow used at runtime.
- Launch Codex with a dedicated harness `CODEX_HOME` while layering target repo `AGENTS.md` and other
  repo-local docs after the harness global instructions.
- Expose operator-visible observability (at minimum structured logs).
- Support tracker/filesystem-driven restart recovery without requiring a persistent database; exact
  in-memory scheduler state is not restored.

### 2.2 Non-Goals

- Rich web UI or multi-tenant control plane.
- Prescribing a specific dashboard or terminal UI implementation.
- General-purpose workflow engine or distributed job scheduler.
- Built-in business logic for how to edit tickets, PRs, or comments. (That logic lives in the
  compiled workflow prompt and agent tooling.)
- Mandating strong sandbox controls beyond what the coding agent and host OS provide.
- Mandating a single default approval, sandbox, or operator-confirmation posture for all
  implementations.

## 3. System Overview

### 3.1 Main Components

1. `Manifest Loader`
   - Reads the target repository `symphony.yml`.
   - Parses the v1 manifest vocabulary.
   - Returns a normalized manifest object.

2. `Workflow Module Registry`
   - Owns Symphony workflow modules and presets.
   - Resolves preset-selected modules, explicitly selected modules, module pins, and module
     overrides.
   - Provides module schemas, prompt/policy renderers, checks, and workflow transition fragments.

3. `Workflow Compiler`
   - Compiles the normalized manifest plus selected workflow modules into a runtime compiled
     workflow.
   - Returns prompt templates, policies, checks, completion requirements, workflow transitions, tool
     guidance, and harness launch instructions.

4. `Config Layer`
   - Exposes typed getters for compiled workflow and deployment config values.
   - Applies defaults and environment variable indirection.
   - Performs validation used by the orchestrator before dispatch.

5. `Issue Tracker Client`
   - Fetches candidate issues in active states.
   - Fetches current states for specific issue IDs (reconciliation).
   - Fetches terminal-state issues during startup cleanup.
   - Normalizes tracker payloads into a stable issue model.

6. `Orchestrator`
   - Owns the poll tick.
   - Owns the in-memory runtime state.
   - Decides which issues to dispatch, retry, stop, or release.
   - Tracks session metrics and retry queue state.

7. `Workspace Manager`
   - Maps issue identifiers to workspace paths.
   - Ensures per-issue workspace directories exist.
   - Runs workspace lifecycle hooks.
   - Cleans workspaces for terminal issues.

8. `Agent Runner`
   - Creates workspace.
   - Builds prompt from issue + compiled workflow template.
   - Launches the coding agent app-server client with the harness `CODEX_HOME`.
   - Streams agent updates back to the orchestrator.

9. `Status Surface` (OPTIONAL)
   - Presents human-readable runtime status (for example terminal output, dashboard, or other
     operator-facing view).

10. `Logging`
   - Emits structured runtime logs to one or more configured sinks.

### 3.2 Abstraction Levels

Symphony is easiest to port when kept in these layers:

1. `Manifest Layer` (target repo-defined)
   - `symphony.yml` project identity, project/app kind, preset, selected modules, validation
     commands, VCS mode/posture, docs entrypoints, automation policy, and optional module
     pins/overrides.
   - Target repo docs, commands, setup, style, and domain conventions remain repo-owned.

2. `Module Policy Layer` (Symphony-defined)
   - Presets and workflow modules render prompt fragments, policies, tool-use guidance, CLI checks,
     completion requirements, and workflow transitions.
   - Modules are versioned and may be pinned by the manifest.

3. `Compilation Layer`
   - Combines the manifest, preset defaults, selected modules, service deployment config, and issue
     policy profile into one compiled workflow object.
   - Produces runtime/export artifacts. Rendered Markdown, when generated, is an output, not the
     committed source of truth.

4. `Configuration Layer` (typed getters)
   - Parses the compiled workflow and deployment config into typed runtime settings.
   - Handles defaults, environment tokens, and path normalization.

5. `Coordination Layer` (orchestrator)
   - Polling loop, issue eligibility, concurrency, retries, reconciliation.

6. `Execution Layer` (workspace + agent subprocess)
   - Filesystem lifecycle, workspace preparation, coding-agent protocol.

7. `Integration Layer` (Linear adapter)
   - API calls and normalization for tracker data.

8. `Observability Layer` (logs + OPTIONAL status surface)
   - Operator visibility into orchestrator and agent behavior.

### 3.3 External Dependencies

- Issue tracker API (Linear for `runtime.tracker.kind: linear` in this specification version).
- Local filesystem for workspaces and logs.
- OPTIONAL workspace population tooling (for example Git or Jujutsu CLI, if used).
- Coding-agent executable that supports the targeted Codex app-server mode.
- Host environment authentication for the issue tracker and coding agent.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Issue

Normalized issue record used by orchestration, prompt rendering, and observability output.

Fields:

- `id` (string)
  - Stable tracker-internal ID.
- `identifier` (string)
  - Human-readable ticket key (example: `ABC-123`).
- `title` (string)
- `description` (string or null)
- `priority` (integer or null)
  - Lower numbers are higher priority in dispatch sorting.
- `state` (string)
  - Current tracker state name.
- `branch_name` (string or null)
  - Tracker-provided branch metadata if available.
- `url` (string or null)
- `labels` (list of strings)
  - Normalized to lowercase.
- `blocked_by` (list of blocker refs)
  - Each blocker ref contains:
    - `id` (string or null)
    - `identifier` (string or null)
    - `state` (string or null)
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)

#### 4.1.2 Manifest

Parsed `symphony.yml` payload committed by the target repository.

Fields are defined in Section 5. The manifest selects project identity, project/app kind, preset,
modules, validation commands, VCS mode/posture, docs entrypoints, automation policy, and optional
module pins/overrides. It is intentionally thin and SHOULD NOT contain generated prompt text, copied
workflow policy, secrets, or host-specific runtime state.

#### 4.1.3 Workflow Module

Symphony-owned unit of reusable delivery behavior.

Logical fields:

- `id` (string)
- `version` or `ref` (string)
- `inputs_schema` (object, OPTIONAL)
- `provided_fragments` (set of fragment types)
  - Examples: prompt fragments, policy fragments, tool-use guidance, CLI checks, completion
    requirements, workflow transitions.
- `dependencies` (list of module IDs, OPTIONAL)
- `conflicts` (list of module IDs, OPTIONAL)

#### 4.1.4 Compiled Workflow

Runtime workflow object produced from the manifest and selected workflow modules.

Logical fields:

- `policy_ref` (string)
  - Stable digest or reference for the compiled policy.
- `policy_metadata` (map)
  - Includes source manifest path/ref, selected preset, selected modules, and profile metadata.
- `prompt_template` (string)
- `checks` (list of check objects)
- `completion_requirements` (list of requirement objects)
- `delivery` (map)
  - Example: `pr_target`.
- `transitions` (map)
  - Workflow state names and allowed handoff/land/rework behavior.
- `tools` (map/list)
  - Tool-use guidance and optional client-side tools.
- `harness` (map)
  - Harness `CODEX_HOME`, global instruction path, app-server launch policy, and instruction
    layering rules.
- `runtime` (map)
  - Typed runtime settings consumed by the scheduler, workspace manager, and agent runner.

#### 4.1.5 Service Config (Typed View)

Typed runtime values derived from the compiled workflow plus service deployment config and
environment resolution.

Examples:

- poll interval
- workspace root
- active and terminal issue states
- concurrency limits
- coding-agent executable/args/timeouts
- workspace hooks

#### 4.1.6 Workspace

Filesystem workspace assigned to one issue identifier.

Fields (logical):

- `path` (absolute workspace path)
- `workspace_key` (sanitized issue identifier)
- `created_now` (boolean, used to gate `after_create` hook)

#### 4.1.7 Run Attempt

One execution attempt for one issue.

Fields (logical):

- `issue_id`
- `issue_identifier`
- `attempt` (integer or null, `null` for first run, `>=1` for retries/continuation)
- `workspace_path`
- `started_at`
- `status`
- `error` (OPTIONAL)

#### 4.1.8 Live Session (Agent Session Metadata)

State tracked while a coding-agent subprocess is running.

Fields:

- `session_id` (string, `<thread_id>-<turn_id>`)
- `thread_id` (string)
- `turn_id` (string)
- `codex_app_server_pid` (string or null)
- `last_codex_event` (string/enum or null)
- `last_codex_timestamp` (timestamp or null)
- `last_codex_progress_timestamp` (timestamp or null)
- `last_codex_message` (summarized payload)
- `last_codex_error_signature` (compact string or null)
- `codex_input_tokens` (integer)
- `codex_output_tokens` (integer)
- `codex_total_tokens` (integer)
- `last_reported_input_tokens` (integer)
- `last_reported_output_tokens` (integer)
- `last_reported_total_tokens` (integer)
- `turn_count` (integer)
  - Number of coding-agent turns started within the current worker lifetime.

#### 4.1.9 Retry Entry

Scheduled retry state for an issue.

Fields:

- `issue_id`
- `identifier` (best-effort human ID for status surfaces/logs)
- `attempt` (integer, 1-based for retry queue)
- `due_at_ms` (monotonic clock timestamp)
- `timer_handle` (runtime-specific timer reference)
- `error` (string or null)

#### 4.1.10 Orchestrator Runtime State

Single authoritative in-memory state owned by the orchestrator.

Fields:

- `poll_interval_ms` (current effective poll interval)
- `max_concurrent_agents` (current effective global concurrency limit)
- `running` (map `issue_id -> running entry`)
- `claimed` (set of issue IDs reserved/running/retrying)
- `retry_attempts` (map `issue_id -> RetryEntry`)
- `completed` (set of issue IDs; bookkeeping only, not dispatch gating)
- `codex_totals` (aggregate tokens + runtime seconds)
- `codex_rate_limits` (latest rate-limit snapshot from agent events)

### 4.2 Stable Identifiers and Normalization Rules

- `Issue ID`
  - Use for tracker lookups and internal map keys.
- `Issue Identifier`
  - Use for human-readable logs and workspace naming.
- `Workspace Key`
  - Derive from `issue.identifier` by replacing any character not in `[A-Za-z0-9._-]` with `_`.
  - Use the sanitized value for the workspace directory name.
- `Normalized Issue State`
  - Compare states after `lowercase`.
- `Session ID`
  - Compose from coding-agent `thread_id` and `turn_id` as `<thread_id>-<turn_id>`.

## 5. Manifest and Workflow Module Specification

### 5.1 Source-of-Truth Model

Target repositories commit a thin `symphony.yml` manifest. Symphony owns presets, workflow modules,
compiled workflow generation, and the harness runtime policy.

Source-of-truth rules:

- `symphony.yml` is the committed target-repo entry point for Symphony v1.
- Workflow modules and presets are authored, versioned, and distributed by Symphony.
- The compiled workflow is a runtime artifact produced from the manifest, selected modules, service
  deployment config, and selected workflow profile.
- Target repo docs remain authoritative for project style, setup, domain language, app-specific
  commands, architecture, and design conventions.
- Target repo `AGENTS.md` layers after the harness global `AGENTS.md`; it does not replace or
  duplicate Symphony workflow modules.
- Rendered workflow exports are generated inspection/debugging artifacts. They MUST NOT be the setup
  path that target repos copy and customize.

### 5.2 Manifest Discovery and File Format

Manifest path precedence:

1. Explicit application/runtime setting, such as a CLI path argument or configured workflow path.
2. Default manifest: `symphony.yml` in the current process working directory.

Loader behavior:

- If the selected manifest file cannot be read, return `missing_manifest_file`.
- If no explicit path is configured, `symphony.yml` in the current process working directory is the
  only default.
- Every selected file is parsed as a `symphony.yml` manifest.

`symphony.yml` is a YAML manifest. It declares repository facts and selected Symphony-owned workflow
modules, then compiles to the runtime workflow object used by the daemon.

Manifest fields for the default preset:

- `version` (integer, default `1` when omitted)
  - Currently only version `1` is supported.
- `project.slug` (string)
  - Used by the default `tracker.linear` module as `runtime.tracker.project_slug` when present,
    except when `runtime.tracker.team_key` is configured without an explicit tracker project.
- `project.name` (string, defaults to `project.slug`)
- `project.repository` (string)
  - Used by the default `workspace` module to populate new issue workspaces with
    `git clone --depth 1 <repository> .` when present.
  - Required by publish-capable GitHub PR workflows and must resolve to the GitHub repository that
    host-owned publish will target.
- `project.kind` (string, default `generic`)
- `project.app_kind` (string, default `local`)
- `project.facts` (object, default `{}`)
- `docs.entrypoints` (list of strings, default `[]`)
- `vcs.mode` (string, default `git`)
- `vcs.default_branch` (string, default `main`)
- `vcs.posture` (string)
- `delivery.pr_target` (string, defaults to `vcs.default_branch`)
  - Publish-capable GitHub PR workflows must set this field explicitly to an unambiguous base branch
    name.
- `validation.commands` (list of `{name, command}` objects, default `[]`)
- `automation.posture` (string, default `unattended`)
- `automation.profile` (string, default `default`)
- `automation.completion_requirements` (list of strings, default `[]`)
- `automation.review` (object)
- `workflow.preset` (string, default `default`)
- `workflow.modules` (list of strings, appended to preset modules)
- `project.criticality` (string, default `internal`)
- `project.deployment_coupling` (string, default `local`)
- `auto_land.posture` (string, default derived from project criticality and deployment coupling)
- `auto_land.required_checks` (list of strings, default `[]`)
- `auto_land.force_human_review_labels` (list of strings, default includes `force-human-review`,
  `human-review`, `manual-review`, and `no-auto-land`)
- `auto_land.blocked_state` (string, default `Human Review`)
- `auto_land.dry_run` (boolean, default `true`)
- `review_routing` (object)

Manifest resolution rules:

- YAML MUST decode to a map/object.
- Missing or invalid fields return typed diagnostics with manifest paths such as `project.repository`,
  `workflow.preset`, or `workflow.modules[1]`.
- Presets and modules resolve from the installed Symphony module registry.
- The default preset installs the `repo.docs`, `validation.commands`, `tracker.linear`,
  `workspace`, `codex.harness`, and `delivery.github_pr` modules.
- The default `workspace` module compiles `project.repository` into an `after_create` hook when the
  repository field is present.
- The resolved runtime `config` includes daemon config plus manifest metadata, `checks`,
  `completion_requirements`, `delivery`, `profiles`, and `policy_metadata`.
- The resolved `prompt_template` is generated from registry-owned prompt sections and manifest
  facts; target repositories do not commit full prompt prose in the manifest.

Minimal manifest example:

```yaml
version: 1
project:
  slug: hard-sets
  name: Hard Sets
  repository: git@github.com:example/hard-sets.git
  kind: javascript
  app_kind: web
docs:
  entrypoints:
    - AGENTS.md
    - README.md
vcs:
  mode: jj
  default_branch: main
delivery:
  pr_target: main
validation:
  commands:
    - name: check
      command: bun run check
automation:
  posture: unattended
  profile: default
  completion_requirements:
    - Run the strongest feasible validation gate before handoff.
workflow:
  preset: default
  modules:
    - observability
review_routing:
  project_criticality: local_non_production
  autonomy_posture: balanced
  auto_land:
    enabled: true
    max_risk_class: low
```

### 5.3 Manifest Field Semantics

#### 5.3.1 `project`

- `slug` (string)
  - OPTIONAL.
  - Stable Symphony-facing project key.
  - Used by the default `tracker.linear` module as the tracker project slug when present, except
    when `runtime.tracker.team_key` is configured without explicit tracker project scope.
- `repository` (string)
  - OPTIONAL.
  - Repository URL used to populate new issue workspaces when present.
- `name` (string)
  - OPTIONAL human-readable name.
  - Defaults to `slug`.
- `kind` (string)
  - OPTIONAL.
  - Default: `generic`.
- `app_kind` (string)
  - OPTIONAL.
  - Default: `local`.
  - Examples include `web`, `mobile`, `desktop`, `local/internal`, and `production-facing`.
- `facts` (object)
  - OPTIONAL prompt facts rendered by registry-owned modules.
- `criticality` (string)
  - OPTIONAL.
  - Default: `internal`.
  - Supported values: `local`, `prototype`, `internal`, `production`.
  - Used to derive the default auto-land posture when `auto_land.posture` is omitted.
- `deployment_coupling` (string)
  - OPTIONAL.
  - Default: `local`.
  - Supported values: `none`, `local`, `preview`, `staging`, `production`, `production_web`.
  - `production` and `production_web` require strict auto-land evidence even when other project
    metadata is lower criticality.

The manifest MAY identify tracker routing by project slug, but it MUST NOT contain tracker API
tokens.

`project.app_kind` is an input to preset/module defaults; target repository docs remain the authority for
exact setup commands and architectural style.

#### 5.3.2 `docs`

- `entrypoints` (list of strings)
  - OPTIONAL.
  - Default: `[]`.
- Values are repo-relative paths.

The manifest points to docs; it does not copy their content. Repo-local docs remain authoritative for
project style, setup, command syntax, domain language, product/design constraints, and architecture.

#### 5.3.3 `vcs`

- `mode` (string)
  - OPTIONAL.
  - Default: `git`.
- `default_branch` (string)
  - OPTIONAL.
  - Default: `main`.
- `posture` (string)
  - OPTIONAL implementation-defined VCS guidance.

#### 5.3.4 `delivery`

- `pr_target` (string)
  - OPTIONAL.
  - Defaults to `vcs.default_branch`.

The compiled workflow uses `delivery.pr_target` as the PR base branch for a run. Publish-capable
GitHub PR workflows MUST set this field explicitly; defaulting to `vcs.default_branch` is only for
non-publish workflow compatibility. When the target is not `main`, implementations MUST avoid
merging or promoting anything to `main` as part of v1.

#### 5.3.5 `validation`

- `commands` (list of objects)
  - OPTIONAL.
  - Default: `[]`.
  - Each command object contains `name` and `command` strings.

Validation commands are project-specific command facts. Symphony modules decide when those commands are
required by a workflow profile.

#### 5.3.6 `automation`

- `posture` (string)
  - OPTIONAL.
  - Default: `unattended`.
- `profile` (string)
  - OPTIONAL.
  - Default: `default`.
- `completion_requirements` (list of strings)
  - OPTIONAL.
  - Default: `[]`.
- `review` (object)
  - OPTIONAL implementation-defined review policy.

Automation policy constrains workflow modules and prompt rendering. It does not override stricter
service deployment, Codex approval, sandbox, or host controls. `policy_ref` is derived from the
resolved effective policy and MUST NOT be supplied by the manifest.

#### 5.3.7 `workflow`

- `preset` (string)
  - OPTIONAL.
  - Default: `default`.
- `modules` (list of strings)
  - OPTIONAL.
  - Default: `[]`.
  - Entries are appended to preset modules.

A preset is a Symphony-owned bundle of default workflow modules, module ordering, policy defaults,
checks, completion requirements, and transition defaults for a common app/workflow shape. Presets
MUST be deterministic for a given preset ref and implementation version.

#### 5.3.8 `auto_land` (object, OPTIONAL extension)

`auto_land` describes the classification policy used before final handoff. It can select dry-run
auto-land, guarded real auto-land, human review, rework, or blocked routing. Real auto-land MUST use
the configured land/merge flow for the final merge; classifiers MUST NOT bypass that flow with a
direct merge command.

Fields:

- `posture` (string, OPTIONAL)
  - Supported values: `off`, `permissive`, `strict`.
  - When omitted, local/prototype/internal projects default to `permissive`; production or
    production-web coupled projects default to `strict`.
- `required_checks` (list of strings)
  - Default: `[]`.
  - Adds project-specific required evidence checks to the posture defaults.
- `force_human_review_labels` (list of strings)
  - Default: `force-human-review`, `human-review`, `manual-review`, `no-auto-land`.
  - Any matching issue label forces the route to human review.
- `blocked_state` (string)
  - Default: `Human Review`.
  - Target tracker state for missing required evidence when the workflow applies the decision.
- `dry_run` (boolean)
  - Default: `true`.
  - When true, Symphony may classify and record an `auto_land` decision but MUST NOT merge or land
    the PR; the selected tracker state remains the human-review visibility state.
  - When false, the repository has explicitly opted into guarded real auto-land. A successful
    `auto_land` decision MAY move the issue to `Merging`, where the land flow performs final
    check/review polling and the merge.

Default required evidence:

- `permissive`: `tests`, `quality_gates`, `automated_review`, `route_classification`, `sync`.
- Real auto-land (`dry_run: false`) additionally requires `pr_feedback` evidence proving top-level
  PR comments, inline review comments, and review summaries were swept with no unresolved
  actionable feedback.
- `strict`: permissive checks plus explicit production recovery evidence:
  `deployment_status`, `rollback_plan`, `monitoring_source`, and `incident_issue_creation`.
  `rollback`, `rollback-plan`, or `rollback_path` evidence may satisfy `rollback_plan` when the
  implementation normalizes check names, but a generic `recovery` check alone is not sufficient.

For strict policy, the project that owns the production surface owns the deployment status,
rollback or rollback-plan proof, monitoring source, and incident issue creation path. Symphony's
auto-land classifier only verifies that this evidence was recorded before selecting `auto_land`;
Symphony MUST NOT infer deployments from `main` or create a rollback path on behalf of the project.

Decision routes:

- `auto_land`: all required evidence passed and no force-human-review override matched. Dry-run
  auto-land targets the human-review visibility state; real auto-land targets `Merging`.
- `human_review`: posture is `off`, or a force-human-review label matched.
- `rework`: one or more required evidence checks failed.
- `blocked`: one or more required evidence checks are missing.

#### 5.3.9 `review_routing` (object, OPTIONAL extension)

`review_routing` describes the policy used by the workflow prompt and agent tooling to choose a
completion route after implementation and validation. It compiles into the resolved profile policy
and therefore participates in prompt rendering, `policy_ref`, and policy tests. It is not part of
the scheduler's dispatch eligibility rules unless an implementation explicitly promotes it into
typed runtime config.

Fields:

- `project_criticality` (string)
  - Default: `local_non_production`.
  - Allowed values:
    - `local_non_production`: local tools, prototypes, internal docs, or work whose failure does not
      affect production users.
    - `internal_production`: production automation or operator tooling that affects internal users
      or durable internal state.
    - `production_web`: shipped web/product surfaces visible to external users.
    - `regulated_or_high_risk`: auth, billing, payments, permissions, security, migrations, data
      integrity, or other work where an incorrect merge can create external harm.
- `autonomy_posture` (string)
  - Default: `balanced`.
  - Allowed values:
    - `auto_land_allowed`: low-risk validated changes MAY choose `auto_land` without human review.
    - `balanced`: low-risk `local_non_production` changes MAY choose `auto_land`; production or
      high-risk changes require a review route.
    - `review_required`: completed work MUST route to `human_review` or
      `product_visual_review`.
    - `decision_required`: completed work MUST route to `decision_needed` unless it is blocked.
- `default_route` (string, OPTIONAL)
  - One of the route types in Section 11.7.
  - If absent, route selection is derived from `project_criticality`, `autonomy_posture`, risk class,
    changed surfaces, validation evidence, and reviewer feedback.
- `auto_land` (object, OPTIONAL)
  - `enabled` (boolean, default `true` when `autonomy_posture == "auto_land_allowed"` or when
    `project_criticality == "local_non_production"` and `autonomy_posture == "balanced"`;
    otherwise `false`)
  - `max_risk_class` (string, default `low`)
  - `allowed_surfaces` (list of strings, OPTIONAL)
  - `blocked_surfaces` (list of strings, default includes `auth`, `billing`, `payments`,
    `permissions`, `security`, `migrations`, `production_data`, and `external_user_ui`)
- `product_visual_review` (object, OPTIONAL)
  - `required_for_surfaces` (list of strings, default includes `external_user_ui`, `visual_design`,
    and `production_web`)
  - `required_artifacts` (list of strings, default includes `screenshots_or_recording`,
    `viewport_coverage`, and `manual_qa_notes`)
- `human_review` (object, OPTIONAL)
  - `required_for_risk_classes` (list of strings, default includes `medium`, `high`)
- `decision_needed` (object, OPTIONAL)
  - `max_options` (integer, default `3`)
  - `require_recommended_option` (boolean, default `true`)

Auto-land must not be impossible by default. A conforming default policy allows `auto_land` for a
validated, low-risk `local_non_production` change when checks pass, automated review finds no
blocking issues, no product/visual review is required, and no required external permission is
missing. Production web and high-risk projects can still opt into stricter routing through
`project_criticality`, `autonomy_posture`, or explicit route requirements.

### 5.4 Workflow Module Semantics

A workflow module is a Symphony-owned unit of delivery behavior. Modules use existing agentic
runtime terms directly: they may render prompt fragments, policies, tool-use guidance, CLI checks,
completion requirements, and workflow transitions.

Module outputs MAY include:

- `prompt_fragments`
  - Text or template fragments used to build `compiled_workflow.prompt_template`.
- `policies`
  - Structured rules for workpad handling, VCS posture, validation requirements, review, handoff,
    or landing.
- `tool_guidance`
  - Tool preference, tool prohibition, or tool-specific operating rules.
- `checks`
  - CLI checks and classification rules such as docs-only gates or test-change gates.
- `completion_requirements`
  - Required evidence before handoff.
- `transitions`
  - State routing and handoff/merge/rework rules.
- `harness`
  - Harness `CODEX_HOME` files, global instructions, or Codex launch policy fragments.

Module resolution rules:

- The selected preset contributes an ordered module set.
- Manifest `modules` entries add, configure, disable, or replace modules according to module
  contracts.
- Module dependencies are resolved before dependents.
- Module conflicts fail compilation unless a preset or override defines a deterministic resolution.
- Module pins select the exact module ref used for compilation.
- Module output order MUST be deterministic and recorded in compiled workflow metadata.

### 5.5 Compiled Workflow Generation

Compilation pipeline:

1. Select and parse the manifest.
2. Validate the manifest schema.
3. Resolve the preset.
4. Resolve preset modules, manifest-selected modules, pins, dependencies, conflicts, and overrides.
5. Load service deployment config needed for host-specific runtime values.
6. Render module fragments into a compiled workflow.
7. Validate the compiled workflow schema.
8. Compute `policy_ref` from the normalized manifest, module refs, deployment profile inputs, and
   rendered policy content.
9. Write OPTIONAL runtime/export artifacts if configured.

Rendered Markdown:

- A compiler MAY render Markdown for debugging or human inspection.
- Rendered Markdown MUST include provenance showing the manifest path/ref, preset, module refs, and
  `policy_ref`.
- Rendered Markdown MUST be treated as generated output. Target repos MUST NOT copy it as their
  committed Symphony source of truth.

### 5.6 Manifest and Module Error Surface

Error classes:

- `missing_manifest_file`
- `manifest_parse_error`
- `manifest_root_not_a_map`
- `unsupported_manifest_version`
- `invalid_manifest_config`
- `preset_not_found`
- `module_not_found`
- `module_pin_not_found`
- `module_dependency_error`
- `module_conflict_error`
- `module_config_error`
- `compiled_workflow_error`
- `template_parse_error`
- `template_render_error`

Dispatch gating behavior:

- Manifest read/YAML/schema errors block new dispatches until fixed.
- Preset/module resolution and compilation errors block new dispatches until fixed.
- Template rendering errors fail only the affected run attempt unless they are detected during
  compiled workflow validation.

## 6. Compiled Workflow and Runtime Configuration

### 6.1 Compiled Workflow Contract

The compiled workflow is the runtime object consumed by the orchestrator, workspace manager, agent
runner, and publishing/review/landing modules. It is generated by Symphony and is not edited by the
target repository.

Required top-level fields:

- `policy_ref` (string)
- `policy_metadata` (object)
- `prompt_template` (string)
- `checks` (list)
- `completion_requirements` (list)
- `delivery` (object)
- `publish_target` (object, OPTIONAL)
- `transitions` (object)
- `tools` (object or list)
- `harness` (object)
- `runtime` (object)
- `docs` (object)

Minimal shape:

```json
{
  "policy_ref": "883bf519122b",
  "policy_metadata": {
    "source": "manifest",
    "manifest_path": "symphony.yml",
    "preset": "default",
    "modules": [
      {"id": "tracker.linear", "ref": "883bf519122b"}
    ]
  },
  "prompt_template": "You are working on a Linear ticket `{{ issue.identifier }}`...",
  "checks": [],
  "completion_requirements": [],
  "delivery": {"pr_target": "main"},
  "publish_target": {
    "repository": "https://github.com/example/project",
    "pr_target": "main",
    "github_repository": "example/project",
    "display": "example/project:main"
  },
  "transitions": {},
  "tools": {},
  "harness": {
    "codex_home": "/path/to/symphony/harness/codex-home",
    "global_agents_md": "AGENTS.md",
    "instruction_layers": ["harness_global", "target_repo", "compiled_workflow", "issue"]
  },
  "runtime": {},
  "docs": {
    "entrypoints": ["AGENTS.md", "README.md"]
  }
}
```

### 6.2 Runtime Configuration Resolution Pipeline

Configuration is resolved in this order:

1. Select the target repo manifest path.
2. Parse and validate the manifest.
3. Resolve presets, modules, pins, and overrides.
4. Merge service deployment config for host-specific values such as workspace root, credentials,
   Codex executable, harness `CODEX_HOME`, logs, ports, and worker hosts.
5. Compile the workflow.
6. Resolve `$VAR_NAME` indirection only for config values that explicitly contain `$VAR_NAME`.
7. Coerce and validate typed runtime values.

Environment variables do not globally override manifest or compiled workflow values. They are used
only when a config value explicitly references them or when service deployment config declares them
as the source for secrets.

Value coercion semantics:

- Path fields support:
  - `~` home expansion
  - `$VAR` expansion for env-backed path values
  - Relative target-repo doc paths resolve relative to the target repo root
  - Relative runtime paths resolve according to the owning field contract
- Shell command strings remain shell command strings. Do not rewrite URIs or arbitrary command text
  as paths.

### 6.3 Runtime Config Fields Summary

This section is intentionally redundant so a coding agent can implement the config layer quickly.
Extension fields are documented in the extension section that defines them. Core conformance does
not require recognizing or validating extension fields unless that extension is implemented.

Tracker:

- `runtime.tracker.kind`: string, REQUIRED for dispatch, currently `linear`
- `runtime.tracker.endpoint`: string, default `https://api.linear.app/graphql` when
  `runtime.tracker.kind=linear`
- `runtime.tracker.api_key`: string or `$VAR`, canonical env `LINEAR_API_KEY` when
  `runtime.tracker.kind=linear`
- `runtime.tracker.project_id`: string, optional Linear project ID.
- `runtime.tracker.project_slug`: string, optional Linear project `slugId`.
- `runtime.tracker.team_key`: string, optional Linear team key used when no project scope is set.
- `runtime.tracker.workspace_slug`: string, optional Linear workspace URL slug used to render team
  links such as `https://linear.app/<workspace_slug>/team/<team_key>/all`.
- `runtime.tracker.required_labels`: list of strings, default `[]`
- `runtime.tracker.active_states`: list of strings, default
  `["Todo", "In Progress", "Merging", "Rework"]`
- `runtime.tracker.terminal_states`: list of strings, default
  `["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]`

Scheduler and workspace:

- `runtime.polling.interval_ms`: integer, default `30000`
- `runtime.workspace.root`: path resolved to absolute, default `<system-temp>/symphony_workspaces`
- `runtime.hooks.after_create`: shell script or null
- `runtime.hooks.before_run`: shell script or null
- `runtime.hooks.after_run`: shell script or null
- `runtime.hooks.before_remove`: shell script or null
- `runtime.hooks.timeout_ms`: integer, default `60000`
- `runtime.agent.max_concurrent_agents`: integer, default `10`
- `runtime.agent.max_turns`: integer, default `20`
- `runtime.agent.max_retry_backoff_ms`: integer, default `300000` (5m)
- `runtime.agent.max_concurrent_agents_by_state`: map of positive integers, default `{}`

Codex:

For Codex-owned config values such as `approval_policy`, `thread_sandbox`, and
`turn_sandbox_policy`, supported values are defined by the targeted Codex app-server version.
Implementors SHOULD treat them as pass-through Codex config values rather than relying on a
hand-maintained enum in this spec. To inspect the installed Codex schema, run
`codex app-server generate-json-schema --out <dir>` and inspect the relevant definitions referenced
by `v2/ThreadStartParams.json` and `v2/TurnStartParams.json`. Implementations MAY validate these
fields locally if they want stricter startup checks.

- `runtime.codex.command`: shell command string, default `codex app-server`
- `runtime.codex.model`: Codex model name, default implementation-defined
- `runtime.codex.approval_policy`: Codex `AskForApproval` value, default implementation-defined
- `runtime.codex.thread_sandbox`: Codex `SandboxMode` value, default implementation-defined
- `runtime.codex.turn_sandbox_policy`: Codex `SandboxPolicy` value, default implementation-defined
- `runtime.codex.turn_timeout_ms`: integer, default `3600000`
- `runtime.codex.read_timeout_ms`: integer, default `5000`
- `runtime.codex.stall_timeout_ms`: integer, default `300000`
  - If `<= 0`, stall detection is disabled.
- `runtime.codex.execution_profiles`: map of named Codex job profiles, default implementation-defined
  conservative profiles for `implementation`, `planner`, `source_reviewer`, `test_reviewer`,
  `runtime_qa`, `product_visual_review`, `docs_reviewer`, `security_reviewer`, and `synthesis`.
  Profiles MAY set `model`, `reasoning_effort`, `budget`, `timeout_ms`, `max_retries`, or an
  explicit `command`. When `command` is omitted, implementations SHOULD derive common model and
  reasoning settings without requiring operators to edit the raw `runtime.codex.command` string.

Quality gate:

- `runtime.quality_gate.enabled`: boolean, default `true`
- `runtime.quality_gate.source_max_concurrency`: positive integer, default `3`
- `runtime.quality_gate.max_repair_passes`: non-negative integer, default `1`
- `runtime.quality_gate.runtime_isolation`: `serialized`, `isolated_workspace`, or `blocked`,
  default `serialized`. `isolated_workspace` is conservative-blocked until the runtime can provision
  disposable reviewer workspaces.
- `runtime.quality_gate.reviewer_timeout_ms`: positive integer, default `1200000`
- `runtime.quality_gate.reviewer_max_retries`: non-negative integer, default `0`

Implementations that run host-owned quality gates SHOULD persist each completed quality-gate run as a
host-owned review record after synthesis and handoff-route classification. The default records root
SHOULD be derived from the implementation's logs root, for example
`<logs-root>/review-records/quality-gates/<project-slug>/<issue-identifier>/<run-id>/`, unless an
operator explicitly configures a different runtime records root. Implementations MUST NOT write these
records into the target repository workspace by default.

The stable record files are:

- `metadata.json`: schema version, project/repository identity, issue id/identifier/url, workflow
  profile, policy ref, run/session ids, timestamps, changed files/surfaces, and record-relative
  artifact paths.
- `quality_gate.json`: planner decision, requested/executed/blocked/skipped jobs, normalized
  reviewer outputs, synthesis, repair passes, and unresolved human-review reasons.
- `findings.json`: immutable normalized findings with stable ids, category, severity, evidence,
  affected files, source job, recommended disposition, and repair/rerun linkage when known.
- `handoff_route.json`: final route decision and the quality-gate evidence consumed by routing.

`disposition.json` is the mutable sidecar. It SHOULD be initialized from synthesis and repair
evidence using statuses suitable for later mining, including `accepted`, `fixed`,
`rejected_false_positive`, `deferred_followup`, `needs_user_decision`, `no_action`, and
`untriaged`. Repair-loop fixes SHOULD be represented as `fixed` or linked to the repair/rerun
evidence. Follow-up, human-input-required, rejected-false-positive, blocked, and skipped review
outcomes MUST remain distinguishable instead of being flattened into pass/fail summaries.

Operator read surfaces SHOULD support listing records, showing a single run, and exporting
retrospective input grouped by finding category, disposition, affected files/surfaces,
false-positive patterns, and follow-up candidates. Exports MAY include a compatibility adapter for a
shared retrospective workflow, but MUST stop at evidence and proposals; they MUST NOT automatically
edit workflow modules, instructions, skills, repo docs, or tracker issues.

Review-record payloads and read surfaces MUST redact or omit raw credentials, secret-shaped fields,
local temp paths, unsafe absolute workspace paths, caches, logs, and operator-local configuration
paths. Changed-file and affected-file references exposed to operators SHOULD be repo-relative,
normalized paths whenever possible.

Delivery and docs:

- `delivery.pr_target`: string, default `main`
- `checks`: list of compiled validation checks
- `completion_requirements`: list of compiled handoff requirements
- `docs.entrypoints`: resolved repo-relative doc paths from the manifest

Profile policy:

- `automation.profile`: string, default `default`
- Resolved profile policy MUST include `delivery.pr_target`.
- `review_routing`: object, OPTIONAL route policy compiled from the manifest into the resolved
  profile policy.
- Selected-profile `codex` overrides MAY set `approval_policy`, `thread_sandbox`, and
  `turn_sandbox_policy` before the Codex thread/turn starts.
- Implementations MUST compute a stable `policy_ref` hash from the resolved effective policy.
- When `delivery.pr_target` is not `main`, v1 MUST NOT automate promotion or merge-forward from that
  target branch to `main`.

### 6.4 Harness `CODEX_HOME` and Instruction Layering

Symphony MUST launch Codex with a dedicated harness `CODEX_HOME` for unattended workflow runs.

Harness model:

- The harness `CODEX_HOME` is owned by Symphony, not by the target repository and not by the
  operator's ambient `~/.codex`.
- The harness contains Symphony global `AGENTS.md`, runtime config, hooks, prompts, module-rendered
  support files, and any implementation-bundled skills/plugins required by selected extensions. The
  core delivery lifecycle MUST NOT depend on globally installed `symphony-*` delivery skills.
- Generated harness files SHOULD be outside the target repo workspace or in an implementation-owned
  runtime directory inside the workspace root. They MUST NOT be committed as target repo source.
- The target repo remains readable/writable as the issue workspace according to sandbox policy.

Instruction layering order:

1. Harness global `AGENTS.md`
   - Defines Symphony workflow obligations, unattended behavior, Linear workpad policy, module
     policy, and tool/runtime guardrails.
2. Target repo instructions
   - Repo-local `AGENTS.md` and project docs define project style, setup, commands, domain language,
     product/design constraints, and architecture.
3. Compiled workflow prompt
   - Per-run workflow prompt rendered from selected modules and manifest data.
4. Issue context
   - Tracker issue title, description, labels, policy profile, and run metadata.

Layering invariants:

- Harness instructions own orchestration behavior.
- Target repo docs own project-specific engineering behavior.
- Modules SHOULD route agents to target repo docs instead of duplicating those docs in generated
  workflow text.
- Target repo `AGENTS.md` can be stricter about repo commands and style, but it MUST NOT be required
  to carry Symphony workpad, handoff, or lifecycle doctrine.

### 6.5 Prompt Template Contract

The compiled workflow provides the per-issue `prompt_template`. Symphony generates it from
registry-owned module sections and manifest facts.

Rendering requirements:

- Use a strict template engine (Liquid-compatible semantics are sufficient).
- Unknown variables MUST fail rendering.
- Unknown filters MUST fail rendering.

Template input variables:

- `issue` (object)
  - Includes all normalized issue fields, including labels and blockers.
- `attempt` (integer or null)
  - `null`/absent on first attempt.
  - Integer on retry or continuation run.
- `policy` (object)
  - Resolved effective workflow policy for the issue.
- `policy_json` (string)
  - JSON rendering of `policy` for prompt templates that need to expose arbitrary profile-specific
    gates or completion requirements without knowing every policy key.
- `compiled_workflow` (object, OPTIONAL)
  - Implementations MAY expose selected metadata such as `policy_ref`, `delivery`, `checks`, and
    `completion_requirements`.

Fallback prompt behavior:

- If the compiled workflow prompt template is empty, the runtime SHOULD compile a default prompt from its
  built-in core workflow module registry.
- The default compiled prompt SHOULD include enough issue context and workflow policy for an agent
  to execute the run without requiring globally installed workflow skills.
- Manifest, module, compile, or template errors are configuration/validation errors and SHOULD NOT silently fall
  back to a prompt.

### 6.6 Internal Workflow Module Registry

Implementations MAY provide an internal workflow module registry for reusable prompt policy.

Core module requirements:

- Modules SHOULD be versioned and owned by the Symphony implementation.
- Each module SHOULD include `id`, `summary`, `version`, default-inclusion metadata,
  compatibility constraints, optional pins, and Markdown content.
- The default preset SHOULD be compiled from modules marked for default inclusion.
- Missing module IDs or malformed registry entries SHOULD be caught by unit tests or workflow
  validation before handoff.
- Adding future non-default modules SHOULD NOT require editing target repository manifests. Target
  repositories should only need manifest changes when they explicitly opt in to non-default module
  selections or versions.

The default module set SHOULD cover Linear operation, implementation loop, VCS/commit/push,
pull/sync, quality gates, automated review, land/merge, rework, requirement validation, project
closeout, and debugging/run recovery.

### 6.7 Runtime Workflow Validation Error Surface

Error classes:

- `missing_manifest_file`
- `manifest_parse_error`
- `manifest_root_not_a_map`
- `manifest_validation_error`
- `module_resolution_error`
- `template_parse_error` (during prompt rendering)
- `template_render_error` (unknown variable/filter, invalid interpolation)

Dispatch gating behavior:

- Manifest read/YAML/module errors block new dispatches until fixed.
- Template errors fail only the affected run attempt.

### 6.8 Target Repo Manifest CLI Contract

Implementations MAY expose a target-repo manifest named `symphony.yml` as the operator-facing setup
contract. The manifest records durable repo facts and workflow selections, while the implementation
resolves presets/modules into a compiled workflow config and prompt when an operator asks to inspect
it.

`symphony.yml` v1 fields:

- `version` (integer): OPTIONAL, defaults to `1` when omitted; currently only `1` is supported.
- `project` (object): `name`, `kind`, and `app_kind`.
- `workflow` (object): `preset` plus optional extra `modules`.
- `docs` (object): repo-relative `entrypoints` that agents should read for repo instructions and
  durable product/architecture context.
- `validation` (object): named validation `commands` that the workflow expects before handoff.
- `vcs` (object): `mode`, currently `jj`, `git`, or `none`.
- `delivery` (object): delivery defaults such as `pr_target`.
- `automation` (object): automation posture, currently `unattended` or `manual`.
- `harness` (object): optional `codex_home`; `null` means the implementation derives a managed
  harness CODEX_HOME.
- `recovery` and `deployment` (objects): optional implementation metadata.

CLI commands:

- `symphony workflow init` creates `symphony.yml` from repo inspection. It MUST NOT overwrite an
  existing manifest unless the operator passes an explicit replacement flag.
- `symphony workflow check` validates manifest schema, selected preset/modules, repo doc
  entrypoints, validation command shape, VCS/delivery defaults, configured harness CODEX_HOME
  readiness, and tracker project scope.
- `symphony workflow print` prints the resolved preset/modules/defaults. It MAY include the
  compiled workflow config and prompt without writing generated prompt files into the target repo.

CLI validation failures MUST exit nonzero and point to the manifest field or missing repo/harness
evidence with concise remediation.

### 6.9 Dynamic Runtime Configuration

Dynamic runtime configuration uses the resolution pipeline in Section 6.2. Reloaded config MUST be
the fully parsed, module-resolved, deployment-merged, compiled, environment-resolved, and coerced
runtime workflow before it can affect dispatch.

#### 6.9.1 Dynamic Reload Semantics

Dynamic reload is REQUIRED:

- The software MUST detect manifest, selected module, and relevant deployment config changes.
- On change, it MUST recompile and re-apply the compiled workflow without restart.
- The software MUST attempt to adjust live behavior to the new compiled workflow (for example
  polling cadence, concurrency limits, active/terminal states, codex settings, workspace
  paths/hooks, checks, and prompt content for future runs).
- Reloaded config applies to future dispatch, retry scheduling, reconciliation decisions, hook
  execution, and agent launches.
- Once an issue dispatch resolves workflow profile policy, that resolved policy MUST be carried by
  the in-memory running/retry entry for current-process stability. Later reloads MUST NOT mutate an
  already-running or already-retrying issue's resolved policy.
- Implementations are not REQUIRED to restart in-flight agent sessions automatically when compiled
  workflow changes.
- Extensions that manage their own listeners/resources (for example an HTTP server port change) MAY
  require restart unless the implementation explicitly supports live rebind.
- Implementations SHOULD also re-validate/reload defensively during runtime operations (for example
  before dispatch) in case filesystem watch events are missed.
- Invalid reloads MUST NOT crash the service; keep operating with the last known good compiled
  workflow and emit an operator-visible error.

#### 6.9.2 Dispatch Preflight Validation

This validation is a scheduler preflight run before attempting to dispatch new work. It validates
the manifest, compiled workflow, and runtime config needed to poll and launch workers, not a full
audit of all possible workflow behavior.

Startup validation:

- Validate manifest and compiled workflow before starting the scheduling loop.
- If startup validation fails, fail startup and emit an operator-visible error.

Per-tick dispatch validation:

- Re-validate before each dispatch cycle.
- If validation fails, skip dispatch for that tick, keep reconciliation active, and emit an
  operator-visible error.

Validation checks:

- Manifest can be loaded and parsed.
- Preset and selected modules can resolve.
- Compiled workflow can be produced and validated.
- `runtime.tracker.kind` is present and supported.
- `runtime.tracker.api_key` is present after `$` resolution.
- `runtime.tracker.project_id`, `runtime.tracker.project_slug`, or `runtime.tracker.team_key` is
  present when required by the selected tracker kind. Linear polling prefers `project_id`, then
  `project_slug`, then `team_key`.
- `runtime.codex.command` is present and non-empty.
- `harness.codex_home` and harness global instructions are available.
- Every selected workflow profile resolves to an effective policy with a string
  `delivery.pr_target`.
- Unknown or malformed workflow profile references fail validation, including CLI/runtime overrides.

## 7. Orchestration State Machine

The orchestrator is the only component that mutates scheduling state. All worker outcomes are
reported back to it and converted into explicit state transitions.

### 7.1 Issue Orchestration States

This is not the same as tracker states (`Todo`, `In Progress`, etc.). This is the service's internal
claim state.

1. `Unclaimed`
   - Issue is not running and has no retry scheduled.

2. `Claimed`
   - Orchestrator has reserved the issue to prevent duplicate dispatch.
   - In practice, claimed issues are either `Running` or `RetryQueued`.

3. `Running`
   - Worker task exists and the issue is tracked in `running` map.

4. `RetryQueued`
   - Worker is not running, but a retry timer exists in `retry_attempts`.

5. `Released`
   - Claim removed because issue is terminal, non-active, missing, or retry path completed without
     re-dispatch.

Important nuance:

- A successful worker exit does not mean the issue is done forever.
- The worker MAY continue through multiple back-to-back coding-agent turns before it exits.
- After each normal turn completion, the worker re-checks the tracker issue state.
- If the issue is still in an active state, the worker SHOULD start another turn on the same live
  coding-agent thread in the same workspace, up to `runtime.agent.max_turns`.
- The first turn SHOULD use the full rendered task prompt.
- Continuation turns SHOULD send only continuation guidance to the existing thread, not resend the
  original task prompt that is already present in thread history.
- Once the worker exits normally, the orchestrator still schedules a short continuation retry
  (about 1 second) so it can re-check whether the issue remains active and needs another worker
  session.

### 7.2 Run Attempt Lifecycle

A run attempt transitions through these phases:

1. `PreparingWorkspace`
2. `BuildingPrompt`
3. `LaunchingAgentProcess`
4. `InitializingSession`
5. `StreamingTurn`
6. `Finishing`
7. `Succeeded`
8. `Failed`
9. `TimedOut`
10. `Stalled`
11. `CanceledByReconciliation`

Distinct terminal reasons are important because retry logic and logs differ.

### 7.3 Transition Triggers

- `Poll Tick`
  - Reconcile active runs.
  - Validate config.
  - Fetch candidate issues.
  - Dispatch until slots are exhausted.

- `Worker Exit (normal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule continuation retry (attempt `1`) after the worker exhausts or finishes its in-process
    turn loop.

- `Worker Exit (abnormal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule exponential-backoff retry.

- `Codex Update Event`
  - Update live session fields, token counters, and rate limits.

- `Retry Timer Fired`
  - Re-fetch active candidates and attempt re-dispatch, or release claim if no longer eligible.

- `Reconciliation State Refresh`
  - Stop runs whose issue states are terminal or no longer active.

- `Stall Timeout`
  - Kill worker and schedule retry.

### 7.4 Idempotency and Recovery Rules

- The orchestrator serializes state mutations through one authority to avoid duplicate dispatch.
- `claimed` and `running` checks are REQUIRED before launching any worker.
- Reconciliation runs before dispatch on every tick.
- Restart recovery is tracker-driven and filesystem-driven (without a durable orchestrator DB).
- v1 does not require recovery of the resolved per-attempt workflow policy after process restart;
  a recovered future dispatch MAY resolve policy from the current compiled workflow and runtime
  config.
- Startup terminal cleanup removes stale workspaces for issues already in terminal states.

## 8. Polling, Scheduling, and Reconciliation

### 8.1 Poll Loop

At startup, the service validates config, performs startup cleanup, schedules an immediate tick, and
then repeats every `polling.interval_ms`.

The effective poll interval SHOULD be updated when compiled workflow config changes are re-applied.

Tick sequence:

1. Reconcile running issues.
2. Run dispatch preflight validation.
3. Fetch candidate issues from tracker using active states.
4. Sort issues by dispatch priority.
5. Dispatch eligible issues while slots remain.
6. Notify observability/status consumers of state changes.

If per-tick validation fails, dispatch is skipped for that tick, but reconciliation still happens
first.

### 8.2 Candidate Selection Rules

An issue is dispatch-eligible only if all are true:

- It has `id`, `identifier`, `title`, and `state`.
- Its state is in `runtime.tracker.active_states` and not in `runtime.tracker.terminal_states`.
- It is routed to this worker by the configured assignee and contains every label in
  `runtime.tracker.required_labels`.
- It is not already in `running`.
- It is not already in `claimed`.
- Global concurrency slots are available.
- Per-state concurrency slots are available.
- Blocker rule for `Todo` state passes:
  - If the issue state is `Todo`, do not dispatch when any blocker is non-terminal.
- Blocker rule for Requirement issues passes:
  - Requirement issues require at least one blocking implementation issue.
  - All blockers must be terminal.
  - Zero blockers is a plan/setup defect, not dispatch-eligible.

Sorting order (stable intent):

1. `priority` ascending (1..4 are preferred; null/unknown sorts last)
2. `created_at` oldest first
3. `identifier` lexicographic tie-breaker

### 8.3 Concurrency Control

Global limit:

- `available_slots = max(max_concurrent_agents - running_count, 0)`

Per-state limit:

- `runtime.agent.max_concurrent_agents_by_state[state]` if present (state key normalized)
- otherwise fallback to global limit

The runtime counts issues by their current tracked state in the `running` map.

### 8.4 Retry and Backoff

Retry entry creation:

- Cancel any existing retry timer for the same issue.
- Store `attempt`, `identifier`, `error`, `due_at_ms`, and new timer handle.
- Preserve the resolved workflow policy metadata from the running attempt when available:
  `profile`, `target`, `policy_ref`, and the resolved `policy` object.

Backoff formula:

- Normal continuation retries after a clean worker exit use a short fixed delay of `1000` ms.
- Failure-driven retries use `delay = min(10000 * 2^(attempt - 1), runtime.agent.max_retry_backoff_ms)`.
- Power is capped by the configured max retry backoff (default `300000` / 5m).

Retry handling behavior:

1. Fetch active candidate issues (not all issues).
2. Find the specific issue by `issue_id`.
3. If not found, release claim.
4. If found and still candidate-eligible:
   - Dispatch if slots are available.
   - Otherwise requeue with error `no available orchestrator slots`.
5. If found but no longer active, release claim.

Note:

- Terminal-state workspace cleanup is handled by startup cleanup and active-run reconciliation
  (including terminal transitions for currently running issues).
- Retry handling mainly operates on active candidates and releases claims when the issue is absent,
  rather than performing terminal cleanup itself.

### 8.5 Active Run Reconciliation

Reconciliation runs every tick and has two parts.

Part A: Stall detection

- For each running issue, compute `elapsed_ms` since:
  - `last_codex_progress_timestamp` if meaningful progress has been seen,
  - otherwise `last_codex_timestamp` if any event has been seen, else
  - `started_at`
- Generic non-progress notifications such as repeated `error` or `item/started` frames update
  `last_codex_timestamp` for observability but MUST NOT refresh
  `last_codex_progress_timestamp`.
- If `elapsed_ms > runtime.codex.stall_timeout_ms`, terminate the worker and queue a retry.
- If `runtime.codex.stall_timeout_ms <= 0`, skip stall detection entirely.

Part B: Tracker state refresh

- Fetch current issue states for all running issue IDs.
- For each running issue:
  - If tracker state is terminal: terminate worker and clean workspace.
  - If tracker state is still active: update the in-memory issue snapshot.
  - If tracker state is neither active nor terminal: terminate worker without workspace cleanup.
- If state refresh fails, keep workers running and try again on the next tick.

### 8.6 Startup Terminal Workspace Cleanup

When the service starts:

1. Query tracker for issues in terminal states.
2. For each returned issue identifier, remove the corresponding workspace directory.
3. If the terminal-issues fetch fails, log a warning and continue startup.

This prevents stale terminal workspaces from accumulating after restarts.

## 9. Workspace Management and Safety

### 9.1 Workspace Layout

Workspace root:

- `runtime.workspace.root` (normalized absolute path)

Per-issue workspace path:

- `<runtime.workspace.root>/<sanitized_issue_identifier>`

Workspace persistence:

- Workspaces are reused across runs for the same issue.
- Successful runs do not auto-delete workspaces.

### 9.2 Workspace Creation and Reuse

Input: `issue.identifier`

Algorithm summary:

1. Sanitize identifier to `workspace_key`.
2. Compute workspace path under workspace root.
3. Ensure the workspace path exists as a directory.
4. Mark `created_now=true` only if the directory was created during this call; otherwise
   `created_now=false`.
5. If `created_now=true`, run `after_create` hook if configured.

Notes:

- This section does not assume any specific repository/VCS workflow outside manifest mode.
- Workspace preparation beyond directory creation (for example dependency bootstrap, checkout/sync,
  code generation) is implementation-defined and is typically handled via hooks.

### 9.3 OPTIONAL Workspace Population (Implementation-Defined)

Implementations MAY populate or synchronize the workspace using implementation-defined logic and/or
hooks (for example `after_create` and/or `before_run`).

The default registry-owned `workspace` module uses `project.repository` to compile an `after_create`
clone hook. Implementations MAY provide additional presets or modules for other population
strategies.

Failure handling:

- Workspace population/synchronization failures return an error for the current attempt.
- If failure happens while creating a brand-new workspace, implementations MAY remove the partially
  prepared directory.
- Reused workspaces SHOULD NOT be destructively reset on population failure unless that policy is
  explicitly chosen and documented.

### 9.4 Workspace Hooks

Supported hooks:

- `runtime.hooks.after_create`
- `runtime.hooks.before_run`
- `runtime.hooks.after_run`
- `runtime.hooks.before_remove`

Execution contract:

- Execute in a local shell context appropriate to the host OS, with the workspace directory as
  `cwd`.
- On POSIX systems, `sh -lc <script>` (or a stricter equivalent such as `bash -lc <script>`) is a
  conforming default.
- Hook timeout uses `runtime.hooks.timeout_ms`; default: `60000 ms`.
- Log hook start, failures, and timeouts.

Failure semantics:

- `after_create` failure or timeout is fatal to workspace creation.
- `before_run` failure or timeout is fatal to the current run attempt.
- `after_run` failure or timeout is logged and ignored.
- `before_remove` failure or timeout is logged and ignored.

### 9.5 Safety Invariants

This is the most important portability constraint.

Invariant 1: Run the coding agent only in the per-issue workspace path.

- Before launching the coding-agent subprocess, validate:
  - `cwd == workspace_path`

Invariant 2: Workspace path MUST stay inside workspace root.

- Normalize both paths to absolute.
- Require `workspace_path` to have `workspace_root` as a prefix directory.
- Reject any path outside the workspace root.

Invariant 3: Workspace key is sanitized.

- Only `[A-Za-z0-9._-]` allowed in workspace directory names.
- Replace all other characters with `_`.

## 10. Agent Runner Protocol (Coding Agent Integration)

This section defines Symphony's language-neutral responsibilities when integrating a Codex
app-server. The Codex app-server protocol for the targeted Codex version is the source of truth for
protocol schemas, message payloads, transport framing, and method names.

Protocol source of truth:

- Implementations MUST send messages that are valid for the targeted Codex app-server version.
- Implementations MUST consult the targeted Codex app-server documentation or generated schema
  instead of treating this specification as a protocol schema.
- If this specification appears to conflict with the targeted Codex app-server protocol, the Codex
  protocol controls protocol shape and transport behavior.
- Symphony-specific requirements in this section still control orchestration behavior, workspace
  selection, prompt construction, continuation handling, and observability extraction.

### 10.1 Launch Contract

Subprocess launch parameters:

- Command: `runtime.codex.command`
- Invocation: `bash -lc <runtime.codex.command>`
- Working directory: workspace path
- Environment: `CODEX_HOME` points at the Symphony-owned harness Codex home for the session.
- Transport/framing: the protocol transport required by the targeted Codex app-server version

Notes:

- The default command is `codex app-server`.
- Implementations MAY derive model and reasoning flags from typed runtime config. The default model
  is `runtime.codex.model`; profile `model` values override it for that launch; explicit model
  flags already present in `runtime.codex.command` control the command unchanged.
- Non-implementation Codex jobs MAY run through `runtime.codex.execution_profiles`; when a profile
  supplies model or reasoning settings and no explicit command, the implementation derives a launch
  command from `runtime.codex.command`.
- Approval policy, sandbox policy, cwd, prompt input, and OPTIONAL tool declarations are supplied
  using fields supported by the targeted Codex app-server version.
- The harness Codex home contains Symphony-owned global instructions. It MUST NOT replace the target
  workspace cwd, so repository-local `AGENTS.md` files and docs can still layer after the harness
  global instructions.
- Worker machines still provide machine-global dependencies such as the Codex executable and
  authentication material. The harness home isolates automation instructions; it does not require
  copying Symphony skills into user-global homes.

RECOMMENDED additional process settings:

- Max line size: 10 MB (for safe buffering)

### 10.2 Session Startup Responsibilities

Reference: https://developers.openai.com/codex/app-server/

Startup MUST follow the targeted Codex app-server contract. Symphony additionally requires the
client to:

- Create or update the Symphony-owned harness Codex home before launching the app-server
  subprocess.
- Start the app-server subprocess in the per-issue workspace.
- Initialize the app-server session using the targeted Codex app-server protocol.
- Create or resume a coding-agent thread according to the targeted protocol.
- Supply the absolute per-issue workspace path as the thread/turn working directory wherever the
  targeted protocol accepts cwd.
- Start the first turn with the rendered issue prompt.
- Start later in-worker continuation turns on the same live thread with continuation guidance rather
  than resending the original issue prompt.
- Supply the implementation's documented approval and sandbox policy using fields supported by the
  targeted protocol.
- Include issue-identifying metadata, such as `<issue.identifier>: <issue.title>`, when the targeted
  protocol supports turn or session titles.
- Advertise implemented client-side tools using the targeted protocol.

Session identifiers:

- Extract `thread_id` from the thread identity returned by the targeted Codex app-server protocol.
- Extract `turn_id` from each turn identity returned by the targeted Codex app-server protocol.
- Emit `session_id = "<thread_id>-<turn_id>"`
- Reuse the same `thread_id` for all continuation turns inside one worker run

### 10.3 Streaming Turn Processing

The client processes app-server updates according to the targeted Codex app-server protocol until
the active turn terminates.

Completion conditions:

- Targeted-protocol turn completion signal -> success
- Targeted-protocol turn failure signal -> failure
- Targeted-protocol turn cancellation signal -> failure
- turn timeout (`turn_timeout_ms`) -> failure
- subprocess exit -> failure

Continuation processing:

- If the worker decides to continue after a successful turn, it SHOULD start another turn on the same
  live thread using the targeted protocol.
- The app-server subprocess SHOULD remain alive across those continuation turns and be stopped only
  when the worker run is ending.

Transport handling requirements:

- Follow the transport and framing rules of the targeted Codex app-server version.
- For stdio-based transports, keep protocol stream handling separate from diagnostic stderr
  handling unless the targeted protocol specifies otherwise.

### 10.4 Emitted Runtime Events (Upstream to Orchestrator)

The app-server client emits structured events to the orchestrator callback. Each event SHOULD
include:

- `event` (enum/string)
- `timestamp` (UTC timestamp)
- `codex_app_server_pid` (if available)
- OPTIONAL `usage` map (token counts)
- payload fields as needed

Important emitted events include, for example:

- `session_started`
- `startup_failed`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_ended_with_error`
- `codex_error_loop`
- `turn_input_required`
- `approval_auto_approved`
- `unsupported_tool_call`
- `notification`
- `other_message`
- `malformed`

### 10.5 Approval, Tool Calls, and User Input Policy

Approval, sandbox, and user-input behavior is implementation-defined.

Policy requirements:

- Each implementation MUST document its chosen approval, sandbox, and operator-confirmation
  posture.
- Approval requests and user-input-required events MUST NOT leave a run stalled indefinitely. An
  implementation MAY either satisfy them, surface them to an operator, auto-resolve them, or
  fail the run according to its documented policy.

Example high-trust behavior:

- Auto-approve command execution approvals for the session.
- Auto-approve file-change approvals for the session.
- Treat user-input-required turns as hard failure.

Unsupported dynamic tool calls:

- Supported dynamic tool calls that are explicitly implemented and advertised by the runtime SHOULD
  be handled according to their extension contract.
- If the agent requests a dynamic tool call that is not supported, return a tool failure response
  using the targeted protocol and continue the session.
- This prevents the session from stalling on unsupported tool execution paths.

Optional client-side tool extension:

- An implementation MAY expose a limited set of client-side tools to the app-server session.
- Current standardized optional tool: `linear_graphql`.
- If implemented, supported tools SHOULD be advertised to the app-server session during startup
  using the protocol mechanism supported by the targeted Codex app-server version.
- Unsupported tool names SHOULD still return a failure result using the targeted protocol and
  continue the session.

`linear_graphql` extension contract:

- Purpose: execute a raw GraphQL query or mutation against Linear using Symphony's configured
  tracker auth for the current session.
- Availability: only meaningful when `runtime.tracker.kind == "linear"` and valid Linear auth is
  configured.
- Preferred input shape:

  ```json
  {
    "query": "single GraphQL query or mutation document",
    "variables": {
      "optional": "graphql variables object"
    }
  }
  ```

- `query` MUST be a non-empty string.
- `query` MUST contain exactly one GraphQL operation.
- `variables` is OPTIONAL and, when present, MUST be a JSON object.
- Implementations MAY additionally accept a raw GraphQL query string as shorthand input.
- Execute one GraphQL operation per tool call.
- If the provided document contains multiple operations, reject the tool call as invalid input.
- `operationName` selection is intentionally out of scope for this extension.
- Reuse the configured Linear endpoint and auth from the active Symphony runtime config; do not
  require the coding agent to read raw tokens from disk.
- Tool result semantics:
  - transport success + no top-level GraphQL `errors` -> `success=true`
  - top-level GraphQL `errors` present -> `success=false`, but preserve the GraphQL response body
    for debugging
  - invalid input, missing auth, or transport failure -> `success=false` with an error payload
- Return the GraphQL response or error payload as structured tool output that the model can inspect
  in-session.

User-input-required policy:

- Implementations MUST document how targeted-protocol user-input-required signals are handled.
- A run MUST NOT stall indefinitely waiting for user input.
- A conforming implementation MAY fail the run, surface the request to an operator, satisfy it
  through an approved operator channel, or auto-resolve it according to its documented policy.
- The example high-trust behavior above fails user-input-required turns immediately.

### 10.6 Timeouts and Error Mapping

Timeouts:

- `runtime.codex.read_timeout_ms`: request/response timeout during startup and sync requests
- `runtime.codex.turn_timeout_ms`: total turn stream timeout
- execution-profile `timeout_ms`: total turn timeout for that reviewer, QA, visual review, planner,
  repair, or synthesis job when supplied
- `runtime.codex.stall_timeout_ms`: enforced by orchestrator based on event inactivity

Error mapping (RECOMMENDED normalized categories):

- `codex_not_found`
- `invalid_workspace_cwd`
- `response_timeout`
- `turn_timeout`
- `port_exit`
- `response_error`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`

### 10.7 Agent Runner Contract

The `Agent Runner` wraps workspace + prompt + app-server client.

Behavior:

1. Create/reuse workspace for issue.
2. Build prompt from the compiled workflow template.
3. Start app-server session.
4. Forward app-server events to orchestrator.
5. On any error, fail the worker attempt (the orchestrator will retry).

Note:

- Workspaces are intentionally preserved after successful runs.

## 11. Issue Tracker Integration Contract (Linear-Compatible)

### 11.1 REQUIRED Operations

An implementation MUST support these tracker adapter operations:

1. `fetch_candidate_issues()`
   - Return issues in configured active states for a configured project.

2. `fetch_issues_by_states(state_names)`
   - Used for startup terminal cleanup.

3. `fetch_issue_states_by_ids(issue_ids)`
   - Used for active-run reconciliation.

### 11.2 Query Semantics (Linear)

Linear-specific requirements for `runtime.tracker.kind == "linear"`:

- `runtime.tracker.kind == "linear"`
- GraphQL endpoint (default `https://api.linear.app/graphql`)
- Auth token sent in `Authorization` header
- `runtime.tracker.project_id` maps to Linear project `id` and is the preferred candidate polling
  selector.
- `runtime.tracker.project_slug` maps to Linear project `slugId` and is used only when
  `project_id` is absent.
- `runtime.tracker.team_key` maps to Linear team `key` and is used only when project scope is
  absent.
- Candidate and issue-state refresh queries include issue labels. Required label filtering happens
  after normalization so refresh can observe label removal and stop or release existing work.
- Candidate issue query filters by `project: { id: { eq: $projectId } }` when `project_id` is set,
  by `project: { slugId: { eq: $projectSlug } }` when only `project_slug` is set, or by
  `team: { key: { eq: $teamKey } }` when only team scope is set.
- Issue-state refresh query uses GraphQL issue IDs with variable type `[ID!]`
- Pagination REQUIRED for candidate issues
- Page size default: `50`
- Network timeout: `30000 ms`

Important:

- Linear GraphQL schema details can drift. Keep query construction isolated and test the exact query
  fields/types REQUIRED by this specification.

A non-Linear implementation MAY change transport details, but the normalized outputs MUST match the
domain model in Section 4.

### 11.3 Normalization Rules

Candidate issue normalization SHOULD produce fields listed in Section 4.1.1.

Additional normalization details:

- Label names are trimmed and lowercased.
- `labels` -> lowercase strings
- `project_id`, `project_slug`, and `project_name` -> copied from the Linear `project` object when
  present
- `blocked_by` -> derived from inverse relations where relation type is `blocks`
- `priority` -> integer only (non-integers become null)
- `created_at` and `updated_at` -> parse ISO-8601 timestamps

### 11.4 Error Handling Contract

RECOMMENDED error categories:

- `unsupported_tracker_kind`
- `missing_tracker_api_key`
- `missing_tracker_project_scope`
- `linear_api_request` (transport failures)
- `linear_api_status` (non-200 HTTP)
- `linear_graphql_errors`
- `linear_unknown_payload`
- `linear_missing_end_cursor` (pagination integrity error)

Orchestrator behavior on tracker errors:

- Candidate fetch failure: log and skip dispatch for this tick.
- Running-state refresh failure: log and keep active workers running.
- Startup terminal cleanup failure: log warning and continue startup.

### 11.5 Tracker Writes (Important Boundary)

Symphony does not require first-class tracker write APIs in the orchestrator.

- Ticket mutations (state transitions, comments, PR metadata) are typically handled by the coding
  agent using tools defined by the compiled workflow prompt.
- The service remains a scheduler/runner and tracker reader.
- Compiled workflow-specific success often means "reached the next handoff state" (for example
  `Human Review`) rather than tracker terminal state `Done`.
- If the `linear_graphql` client-side tool extension is implemented, it is still part of the agent
  toolchain rather than orchestrator business logic.

### 11.6 Workflow Profile Resolution

Workflow profiles are repository-owned policy. Linear project scope is configured separately under
`runtime.tracker` and does not select profiles.

Selection precedence:

1. CLI/runtime profile override for the current process.
2. `default` profile from the selected workflow config.

Unknown profile overrides MUST fail startup/readiness validation. Resolved policies MUST include a
stable `policy_ref`, `policy_metadata.profile`, and `delivery.pr_target`. The `default` profile uses
`policy_metadata.source == "default_profile"`; explicit process overrides use
`policy_metadata.source == "profile_override"`.

### 11.7 Completion Route Contract

After implementation, validation, and automated review, the workflow MUST choose exactly one
completion route. Route selection is agent/tooling policy, not scheduler dispatch policy, unless an
implementation explicitly moves it into runtime code.

Route types:

- `auto_land`
  - Use when policy allows the agent to publish, merge/land, and complete the ticket without
    additional human approval.
  - Allowed only when all required checks pass, automated review has no blocking findings, PR or
    merge checks are green if a PR is used, no actionable reviewer feedback is outstanding, and the
    risk/surface evidence stays within the configured auto-land envelope.
  - Dry-run auto-land records eligibility without merging. Real auto-land requires explicit
    repository opt-in and should transition to `Merging` so the land flow owns final polling and
    merge execution.
- `human_review`
  - Use when work is complete and validated, but policy or risk requires Antonio or another human to
    review before merge/land.
  - This is one route, not the universal default.
- `decision_needed`
  - Use when implementation can proceed only after a product, architecture, policy, or tradeoff
    decision that the agent cannot safely infer.
  - The agent MUST present two or three mutually exclusive options, put the recommended option
    first, state the impact/tradeoff of each option in one short sentence, and keep any free-form
    escape hatch separate from the option list.
- `product_visual_review`
  - Use when the changed surface needs product or visual approval after technical validation,
    especially production web UI, branding, interaction design, visual regressions, or user-facing
    copy where screenshots/recordings materially affect review.
  - The route MUST include the relevant visual QA artifacts or explain why they cannot be captured.
- `blocked`
  - Use when a true blocker prevents completion: missing required auth, permissions, secrets,
    unavailable required tools, impossible repository state, or required external context after
    documented fallbacks are exhausted.
  - The route MUST state the exact missing item, why it blocks acceptance/validation, and the
    smallest unblock action.

Required route evidence payload:

```json
{
  "route": {
    "type": "auto_land | human_review | decision_needed | product_visual_review | blocked",
    "selected_at": "ISO-8601 timestamp",
    "policy_ref": "implementation-defined policy id or digest",
    "reason": "short route rationale"
  },
  "risk": {
    "class": "low | medium | high | critical",
    "project_criticality": "local_non_production | internal_production | production_web | regulated_or_high_risk",
    "changed_surfaces": ["docs", "workflow", "backend", "external_user_ui"],
    "external_side_effects": false
  },
  "evidence": {
    "checks": [
      {"name": "mix test", "status": "passed", "details": "summary or artifact ref"}
    ],
    "change_manifest": {
      "changed_files": ["lib/example.ex"],
      "validation": "same validation evidence represented by checks, or an implementation-defined artifact ref"
    },
    "code_review": {
      "mode": "automated | human | mixed | not_applicable",
      "status": "passed | fix_required | comments_addressed | blocked",
      "findings": []
    },
    "pr": {
      "url": "optional",
      "base": "main",
      "checks_status": "passed | failed | pending | not_applicable"
    },
    "pr_feedback": {
      "status": "none | addressed | pushback_posted | outstanding | not_applicable",
      "pr_number": 123,
      "checked_at": "ISO-8601 timestamp",
      "top_level_comments": {
        "checked": true,
        "source": "gh pr view --comments",
        "unresolved_actionable_count": 0
      },
      "inline_review_comments": {
        "checked": true,
        "source": "gh api repos/<owner>/<repo>/pulls/<pr>/comments",
        "unresolved_actionable_count": 0
      },
      "review_summaries": {
        "checked": true,
        "source": "gh pr view --json reviews",
        "unresolved_actionable_count": 0
      }
    },
    "visual_qa": {
      "required": false,
      "artifacts": [],
      "notes": "optional"
    },
    "escalation_reason": "required for non-auto_land routes",
    "unblock_action": "required for blocked"
  }
}
```

Evidence rules:

- `checks` MUST name every required ticket/workflow validation gate that was run or explain why it
  could not run.
- `change_manifest.changed_files` MUST list the files the completed workspace intends to publish.
  Each path MUST be relative, normalized, and contained by the workspace root after symlink
  resolution. Implementations MUST fail closed for absolute paths, traversal, generated runtime
  state, logs, caches, temporary app data, local secrets, and operator-local config.
- `code_review.status` MUST be `passed` or `comments_addressed` before `auto_land`,
  `human_review`, or `product_visual_review`.
- `risk.changed_surfaces` MUST be concrete enough for tests to assert route decisions, for example
  `docs`, `tests`, `workflow`, `backend`, `auth`, `billing`, `database`, `external_user_ui`,
  `visual_design`, `deployment`, or `operator_runbook`.
- `pr_feedback` MUST record whether top-level PR comments, inline review comments, and review
  summaries were checked. When a PR exists, each channel MUST include source evidence and unresolved
  actionable counts before route completion.
- `pr_feedback.status` MUST be `none`, `addressed`, or `pushback_posted` before `auto_land`,
  `human_review`, or `product_visual_review`.
- `visual_qa.required` MUST be true for `product_visual_review` and for production web UI changes
  unless the policy explicitly exempts that surface.
- `escalation_reason` is REQUIRED for `human_review`, `decision_needed`,
  `product_visual_review`, and `blocked`.

Baseline route decision matrix:

| Project criticality | Low-risk docs/tests/local tooling | Backend/workflow behavior | Production web UI | Auth/billing/data/security |
|---|---|---|---|---|
| `local_non_production` | `auto_land` when checks/review pass | `human_review` for medium+ risk | `product_visual_review` if user-facing | `human_review` or `blocked` |
| `internal_production` | `human_review` unless explicitly auto-land allowed | `human_review` | `product_visual_review` | `human_review` or `blocked` |
| `production_web` | `human_review` | `human_review` | `product_visual_review` | `human_review` or `blocked` |
| `regulated_or_high_risk` | `human_review` | `human_review` | `product_visual_review` | `human_review` or `blocked` |

Reviewer feedback re-entry:

- When a PR or review surface has actionable comments, the route is not complete until every
  comment is addressed in code/docs/tests or receives an explicit justified pushback.
- If new reviewer feedback arrives after `human_review` or `product_visual_review`, the tracker
  issue SHOULD move to `Rework`.
- A Rework run MUST read top-level PR comments, inline review comments, and review summaries before
  editing, then update the single workpad checklist with each actionable item and its disposition.
- Antonio does not need to take over locally for PR-style feedback loops; the next agent run owns
  applying changes, replying with justified pushback when appropriate, revalidating, pushing, and
  selecting a new completion route.

### 11.8 Incident Signal Intake Extension (OPTIONAL)

Implementations MAY provide an explicit project-owned path for turning external production failure
signals into tracker issues. This extension is outside the orchestrator polling loop.

If implemented:

- Supported sources SHOULD be enumerated rather than accepting arbitrary source names. The Elixir
  implementation supports `github_actions`, `sentry`, `posthog`, and `project_webhook`.
- The normalized payload SHOULD include title, severity, affected project, signal source, failing
  signal, non-empty evidence-link strings, source-specific evidence payload, reproduction notes,
  diagnostic notes, suggested owner, suggested validation, and suggested agent route.
- Supported sources SHOULD document required normalized evidence payload fields. The Elixir
  implementation requires `repository`, `workflow`, `run_id`, and `run_url` for GitHub Actions;
  `organization`, `project`, `issue_url`, and `event_id` for Sentry; `project`, `alert_name`,
  `alert_url`, and `metric` for PostHog; and `webhook_name`, `event_id`, and `event_url` for
  project webhooks.
- Issue creation MUST be opt-in and MUST NOT be enabled by merely starting the orchestrator.
- Dry-run SHOULD be the default so operators can inspect the generated issue body without tracker
  writes.
- Duplicate suppression SHOULD use a deterministic source/project correlation key and a bounded
  tracker scan. Terminal matching issues SHOULD NOT suppress a newly observed incident. Candidate
  scan limits MUST stay positive and bounded. It MUST NOT require a universal incident database.
- Created issues SHOULD target `Backlog` by default, MAY target `Todo` only through explicit
  configuration, MUST reject terminal states, SHOULD map severity to tracker priority, SHOULD route
  by configured project/team evidence, MUST reject payload target projects outside the selected
  workflow tracker scope, and SHOULD include explicit labels before any agent dispatch path can pick
  them up.
- Project-specific monitoring remains responsible for alert thresholds, source credentials,
  webhook hosting, and source-specific payload normalization. Symphony owns only the shared intake
  contract and bounded tracker issue creation behavior.

## 12. Prompt Construction and Context Assembly

### 12.1 Inputs

Inputs to prompt rendering:

- `compiled_workflow.prompt_template`
- normalized `issue` object
- resolved `policy` object, including `policy_ref` and selection metadata when available
- `policy_json` JSON string containing the same resolved policy object
- OPTIONAL `attempt` integer (retry/continuation metadata)
- resolved bundled workflow module context:
  - `workflow.modules` Markdown
  - `workflow.module_policy_hash`
  - `workflow.module_names`
  - `workflow.module_refs`

### 12.2 Rendering Rules

- Render with strict variable checking.
- Render with strict filter checking.
- Convert issue object keys to strings for template compatibility.
- Convert policy object keys to strings for template compatibility.
- Preserve nested arrays/maps (labels, blockers, policy metadata) so templates can iterate.
- Resolve bundled workflow modules from the implementation-owned workflow module registry before
  rendering. Module resolution MUST record module names, versions, and a deterministic policy hash
  for each agent run.
- Core delivery prompts MUST use bundled registry modules for tracker, workpad, sync, validation,
  review, publish, merge, debug, requirement-validation, and closeout behavior rather than requiring
  globally installed delivery skills.

### 12.3 Retry/Continuation Semantics

`attempt` SHOULD be passed to the template because the compiled workflow prompt can provide different
instructions for:

- first run (`attempt` null or absent)
- continuation run after a successful prior session
- retry after error/timeout/stall

### 12.4 Failure Semantics

If prompt rendering fails:

- Fail the run attempt immediately.
- Let the orchestrator treat it like any other worker failure and decide retry behavior.

## 13. Logging, Status, and Observability

### 13.1 Logging Conventions

REQUIRED context fields for issue-related logs:

- `issue_id`
- `issue_identifier`

REQUIRED context for coding-agent session lifecycle logs:

- `session_id`

When bundled workflow modules are resolved for a run, session lifecycle metadata SHOULD include:

- `workflow_module_policy_hash`
- `workflow_modules` as name/version pairs

Message formatting requirements:

- Use stable `key=value` phrasing.
- Include action outcome (`completed`, `failed`, `retrying`, etc.).
- Include concise failure reason when present.
- Avoid logging large raw payloads unless necessary.

### 13.2 Logging Outputs and Sinks

The spec does not prescribe where logs are written (stderr, file, remote sink, etc.).

Requirements:

- Operators MUST be able to see startup/validation/dispatch failures without attaching a debugger.
- Implementations MAY write to one or more sinks.
- If a configured log sink fails, the service SHOULD continue running when possible and emit an
  operator-visible warning through any remaining sink.

### 13.3 Runtime Snapshot / Monitoring Interface (OPTIONAL but RECOMMENDED)

If the implementation exposes a synchronous runtime snapshot (for dashboards or monitoring), it
SHOULD return:

- `running` (list of running session rows)
- each running row SHOULD include `turn_count`
- running and retry rows SHOULD include resolved workflow policy metadata when available:
  `profile`, `target`, `policy_ref`, and the resolved `policy` object
- `retrying` (list of retry queue rows)
- session and retry rows SHOULD include the tracker-provided issue URL when available
- `codex_totals`
  - `input_tokens`
  - `output_tokens`
  - `total_tokens`
  - `seconds_running` (aggregate runtime seconds as of snapshot time, including active sessions)
- `rate_limits` (latest coding-agent rate limit payload, if available)

RECOMMENDED snapshot error modes:

- `timeout`
- `unavailable`

### 13.4 OPTIONAL Human-Readable Status Surface

A human-readable status surface (terminal output, dashboard, etc.) is OPTIONAL and
implementation-defined.

If present, it SHOULD draw from orchestrator state/metrics only and MUST NOT be REQUIRED for
correctness.

### 13.5 Session Metrics and Token Accounting

Token accounting rules:

- Agent events can include token counts in multiple payload shapes.
- Prefer absolute thread totals when available, such as:
  - `thread/tokenUsage/updated` payloads
  - `total_token_usage` within token-count wrapper events
- Ignore delta-style payloads such as `last_token_usage` for dashboard/API totals.
- Extract input/output/total token counts leniently from common field names within the selected
  payload.
- For absolute totals, track deltas relative to last reported totals to avoid double-counting.
- Do not treat generic `usage` maps as cumulative totals unless the event type defines them that
  way.
- Accumulate aggregate totals in orchestrator state.

Runtime accounting:

- Runtime SHOULD be reported as a live aggregate at snapshot/render time.
- Implementations MAY maintain a cumulative counter for ended sessions and add active-session
  elapsed time derived from `running` entries (for example `started_at`) when producing a
  snapshot/status view.
- Add run duration seconds to the cumulative ended-session runtime when a session ends (normal exit
  or cancellation/termination).
- Continuous background ticking of runtime totals is not REQUIRED.

Rate-limit tracking:

- Track the latest rate-limit payload seen in any agent update.
- Any human-readable presentation of rate-limit data is implementation-defined.

### 13.6 Humanized Agent Event Summaries (OPTIONAL)

Humanized summaries of raw agent protocol events are OPTIONAL.

If implemented:

- Treat them as observability-only output.
- Do not make orchestrator logic depend on humanized strings.

### 13.7 OPTIONAL HTTP Server Extension

This section defines an OPTIONAL HTTP interface for observability and operational control.

If implemented:

- The HTTP server is an extension and is not REQUIRED for conformance.
- The implementation MAY serve server-rendered HTML or a client-side application for the dashboard.
- The dashboard/API MUST be observability/control surfaces only and MUST NOT become REQUIRED for
  orchestrator correctness.

Extension config:

- `runtime.server.port` (integer, OPTIONAL)
  - Enables the HTTP server extension.
  - `0` requests an ephemeral port for local development and tests.
  - CLI `--port` overrides `runtime.server.port` when both are present.

Enablement (extension):

- Start the HTTP server when a CLI `--port` argument is provided.
- Start the HTTP server when `runtime.server.port` is present in the compiled workflow.
- The `runtime.server` key is owned by this extension.
- Positive `runtime.server.port` values bind that port.
- Implementations SHOULD bind loopback by default (`127.0.0.1` or host equivalent) unless explicitly
  configured otherwise.
- Changes to HTTP listener settings (for example `runtime.server.port`) do not need to hot-rebind;
  restart-required behavior is conformant.

#### 13.7.1 Human-Readable Dashboard (`/`)

- Host a human-readable dashboard at `/`.
- The returned document SHOULD depict the current state of the system (for example active sessions,
  retry delays, token consumption, runtime totals, recent events, and health/error indicators).
- Issue identifiers SHOULD link to tracker-provided issue URLs when those URLs use `http` or `https`.
- It is up to the implementation whether this is server-generated HTML or a client-side app that
  consumes the JSON API below.

#### 13.7.2 JSON REST API (`/api/v1/*`)

Provide a JSON REST API under `/api/v1/*` for current runtime state and operational debugging.

Minimum endpoints:

- `GET /api/v1/state`
  - Returns a summary view of the current system state (running sessions, retry queue/delays,
    aggregate token/runtime totals, latest rate limits, and any additional tracked summary fields).
  - Suggested response shape:

    ```json
    {
      "generated_at": "2026-02-24T20:15:30Z",
      "counts": {
        "running": 2,
        "retrying": 1
      },
      "running": [
        {
          "issue_id": "abc123",
          "issue_identifier": "MT-649",
          "issue_url": "https://tracker.example/issues/MT-649",
          "state": "In Progress",
          "session_id": "thread-1-turn-1",
          "turn_count": 7,
          "last_event": "turn_completed",
          "last_message": "",
          "started_at": "2026-02-24T20:10:12Z",
          "last_event_at": "2026-02-24T20:14:59Z",
          "tokens": {
            "input_tokens": 1200,
            "output_tokens": 800,
            "total_tokens": 2000
          }
        }
      ],
      "retrying": [
        {
          "issue_id": "def456",
          "issue_identifier": "MT-650",
          "issue_url": "https://tracker.example/issues/MT-650",
          "attempt": 3,
          "due_at": "2026-02-24T20:16:00Z",
          "error": "no available orchestrator slots"
        }
      ],
      "codex_totals": {
        "input_tokens": 5000,
        "output_tokens": 2400,
        "total_tokens": 7400,
        "seconds_running": 1834.2
      },
      "rate_limits": null
    }
    ```

- `GET /api/v1/<issue_identifier>`
  - Returns issue-specific runtime/debug details for the identified issue, including any information
    the implementation tracks that is useful for debugging.
  - Suggested response shape:

    ```json
    {
      "issue_identifier": "MT-649",
      "issue_id": "abc123",
      "status": "running",
      "workspace": {
        "path": "/tmp/symphony_workspaces/MT-649"
      },
      "attempts": {
        "restart_count": 1,
        "current_retry_attempt": 2
      },
      "running": {
        "session_id": "thread-1-turn-1",
        "turn_count": 7,
        "state": "In Progress",
        "started_at": "2026-02-24T20:10:12Z",
        "last_event": "notification",
        "last_message": "Working on tests",
        "last_event_at": "2026-02-24T20:14:59Z",
        "tokens": {
          "input_tokens": 1200,
          "output_tokens": 800,
          "total_tokens": 2000
        }
      },
      "retry": null,
      "logs": {
        "codex_session_logs": [
          {
            "label": "latest",
            "path": "/var/log/symphony/codex/MT-649/latest.log",
            "url": null
          }
        ]
      },
      "recent_events": [
        {
          "at": "2026-02-24T20:14:59Z",
          "event": "notification",
          "message": "Working on tests"
        }
      ],
      "last_error": null,
      "tracked": {}
    }
    ```

  - If the issue is unknown to the current in-memory state, return `404` with an error response (for
    example `{\"error\":{\"code\":\"issue_not_found\",\"message\":\"...\"}}`).

- `POST /api/v1/refresh`
  - Queues an immediate tracker poll + reconciliation cycle (best-effort trigger; implementations
    MAY coalesce repeated requests).
  - Suggested request body: empty body or `{}`.
  - Suggested response (`202 Accepted`) shape:

    ```json
    {
      "queued": true,
      "coalesced": false,
      "requested_at": "2026-02-24T20:15:30Z",
      "operations": ["poll", "reconcile"]
    }
    ```

API design notes:

- The JSON shapes above are the RECOMMENDED baseline for interoperability and debugging ergonomics.
- Implementations MAY add fields, but SHOULD avoid breaking existing fields within a version.
- Endpoints SHOULD be read-only except for operational triggers like `/refresh`.
- Unsupported methods on defined routes SHOULD return `405 Method Not Allowed`.
- API errors SHOULD use a JSON envelope such as `{"error":{"code":"...","message":"..."}}`.
- If the dashboard is a client-side app, it SHOULD consume this API rather than duplicating state
  logic.

### 13.8 OPTIONAL Workflow Modules Extension

Implementations MAY support prompt-level workflow modules that add specialized handoff or
validation routing without changing the core orchestration state machine. These modules are selected
through `workflow.modules` and configured through `runtime.workflow_modules`.

Extension config:

- `runtime.workflow_modules.product_visual_review.enabled` (boolean, default `false`)
  - When true and `product_visual_review` is selected in `workflow.modules`, the first-turn agent
    prompt includes the `product_visual_review` module and completed runs record structured
    product visual review evidence in the handoff route.
- `runtime.workflow_modules.product_visual_review.project_kind` (`web`, `mobile`, or `desktop`, default
  `web`)
  - Selects the app family used to phrase visual QA evidence instructions.
- `runtime.workflow_modules.product_visual_review.route_policy` (`auto`, `required`, `recommended`, or
  `off`, default `auto`)
  - `auto` routes when changed files or issue labels indicate product-facing work.
  - `required` always requires the visual QA checks before handoff.
  - `recommended` asks the agent to consider the module but allows explicit skip evidence.
  - `off` disables the module.
- `runtime.workflow_modules.product_visual_review.changed_file_triggers` (list of glob-like strings,
  OPTIONAL)
  - Matching final-diff paths require product visual review in `auto`.
- `runtime.workflow_modules.product_visual_review.issue_label_triggers` (list of strings, OPTIONAL)
  - Matching issue labels recommend product visual review in `auto`.
- `runtime.workflow_modules.product_visual_review.checks` (list of check ids, OPTIONAL)
  - Check ids SHOULD be stable across app kinds, for example `viewport_screenshots`,
    `responsive_states`, `interaction_smoke`, and `product_design_notes`.
- `runtime.workflow_modules.product_visual_review.artifacts` (list of artifact ids, OPTIONAL)
  - Artifact ids describe handoff evidence such as screenshot/media references, interaction notes,
    and product/design review notes.

When this extension is enabled, backend, infra, docs, or test-only work SHOULD record that
`product_visual_review` was skipped rather than paying visual QA runtime cost by default.
Required or recommended product-facing routes SHOULD record desktop/mobile screenshot or media
links, interaction smoke notes, responsive-state evidence, and product/design notes when available.
Implementations MUST NOT expose local temp/file paths as visual QA artifact links in dashboard or
API output; missing or unavailable capture tooling MUST be represented as structured blocked or
human-review evidence.

## 14. Failure Model and Recovery Strategy

### 14.1 Failure Classes

1. `Manifest/Module/Config Failures`
   - Missing `symphony.yml`
   - Invalid manifest YAML
   - Missing preset or workflow module
   - Compiled workflow validation failure
   - Unsupported tracker kind or missing tracker credentials/scope
   - Missing harness `CODEX_HOME` or harness global instructions
   - Missing coding-agent executable

2. `Workspace Failures`
   - Workspace directory creation failure
   - Workspace population/synchronization failure (implementation-defined; can come from hooks)
   - Invalid workspace path configuration
   - Hook timeout/failure

3. `Agent Session Failures`
   - Startup handshake failure
   - Turn failed/cancelled
   - Turn timeout
   - User input requested and handled as failure by the implementation's documented policy
   - Subprocess exit
   - Stalled session (no activity)

4. `Tracker Failures`
   - API transport errors
   - Non-200 status
   - GraphQL errors
   - malformed payloads

5. `Observability Failures`
   - Snapshot timeout
   - Dashboard render errors
   - Log sink configuration failure

### 14.2 Recovery Behavior

- Dispatch validation failures:
  - Skip new dispatches.
  - Keep service alive.
  - Continue reconciliation where possible.

- Worker failures:
  - Convert to retries with exponential backoff.

- Tracker candidate-fetch failures:
  - Skip this tick.
  - Try again on next tick.

- Reconciliation state-refresh failures:
  - Keep current workers.
  - Retry on next tick.

- Dashboard/log failures:
  - Do not crash the orchestrator.

### 14.3 Partial State Recovery (Restart)

Current design is intentionally in-memory for scheduler state.
Restart recovery means the service can resume useful operation by polling tracker state and reusing
preserved workspaces. It does not mean retry timers, running sessions, or live worker state survive
process restart.

After restart:

- No retry timers are restored from prior process memory.
- No running sessions are assumed recoverable.
- Service recovers by:
  - startup terminal workspace cleanup
  - fresh polling of active issues
  - re-dispatching eligible work

### 14.4 Operator Intervention Points

Operators can control behavior by:

- Editing target repo `symphony.yml` for project-owned manifest selections.
- Updating Symphony workflow modules, presets, or service deployment config for Symphony-owned
  runtime policy and host-specific settings.
- Manifest, module, and relevant deployment config changes are detected and recompiled/re-applied
  automatically without restart according to Section 6.6.
- Changing issue states in the tracker:
  - terminal state -> running session is stopped and workspace cleaned when reconciled
  - non-active state -> running session is stopped without cleanup
- Restarting the service for process recovery or deployment (not as the normal path for applying
  manifest or compiled workflow changes).

## 15. Security and Operational Safety

### 15.1 Trust Boundary Assumption

Each implementation defines its own trust boundary.

Operational safety requirements:

- Implementations SHOULD state clearly whether they are intended for trusted environments, more
  restrictive environments, or both.
- Implementations SHOULD state clearly whether they rely on auto-approved actions, operator
  approvals, stricter sandboxing, or some combination of those controls.
- Workspace isolation and path validation are important baseline controls, but they are not a
  substitute for whatever approval and sandbox policy an implementation chooses.

### 15.2 Filesystem Safety Requirements

Mandatory:

- Workspace path MUST remain under configured workspace root.
- Coding-agent cwd MUST be the per-issue workspace path for the current run.
- Workspace directory names MUST use sanitized identifiers.

RECOMMENDED additional hardening for ports:

- Run under a dedicated OS user.
- Restrict workspace root permissions.
- Mount workspace root on a dedicated volume if possible.

### 15.3 Secret Handling

- Support `$VAR` indirection in manifest, compiled workflow, and deployment config fields that
  explicitly allow environment-backed values.
- Do not log API tokens or secret env values.
- Validate presence of secrets without printing them.

### 15.4 Hook Script Safety

Workspace hooks are arbitrary shell scripts from the compiled workflow.

Implications:

- Hooks are fully trusted configuration.
- Hooks run inside the workspace directory.
- Hook output SHOULD be truncated in logs.
- Hook timeouts are REQUIRED to avoid hanging the orchestrator.

### 15.5 Harness Hardening Guidance

Running Codex agents against repositories, issue trackers, and other inputs that can contain
sensitive data or externally-controlled content can be dangerous. A permissive deployment can lead
to data leaks, destructive mutations, or full machine compromise if the agent is induced to execute
harmful commands or use overly-powerful integrations.

Implementations SHOULD explicitly evaluate their own risk profile and harden the execution harness
where appropriate. This specification intentionally does not mandate a single hardening posture, but
implementations SHOULD NOT assume that tracker data, repository contents, prompt inputs, or tool
arguments are fully trustworthy just because they originate inside a normal workflow.

Possible hardening measures include:

- Tightening Codex approval and sandbox settings described elsewhere in this specification instead
  of running with a maximally permissive configuration.
- Adding external isolation layers such as OS/container/VM sandboxing, network restrictions, or
  separate credentials beyond the built-in Codex policy controls.
- Filtering which Linear issues, projects, teams, labels, or other tracker sources are eligible for
  dispatch so untrusted or out-of-scope tasks do not automatically reach the agent.
- Narrowing the `linear_graphql` tool so it can only read or mutate data inside the
  intended project scope, rather than exposing general workspace-wide tracker access.
- Reducing the set of client-side tools, credentials, filesystem paths, and network destinations
  available to the agent to the minimum needed for the workflow.

The correct controls are deployment-specific, but implementations SHOULD document them clearly and
treat harness hardening as part of the core safety model rather than an optional afterthought.

## 16. Reference Algorithms (Language-Agnostic)

### 16.1 Service Startup

```text
function start_service():
  configure_logging()
  start_observability_outputs()
  start_manifest_watch(on_change=recompile_and_reapply_workflow)
  start_module_watch(on_change=recompile_and_reapply_workflow)

  state = {
    poll_interval_ms: get_config_poll_interval_ms(),
    max_concurrent_agents: get_config_max_concurrent_agents(),
    running: {},
    claimed: set(),
    retry_attempts: {},
    completed: set(),
    codex_totals: {input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    codex_rate_limits: null
  }

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    fail_startup(validation)

  startup_terminal_workspace_cleanup()
  schedule_tick(delay_ms=0)

  event_loop(state)
```

### 16.2 Poll-and-Dispatch Tick

```text
on_tick(state):
  state = reconcile_running_issues(state)

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  issues = tracker.fetch_candidate_issues()
  if issues failed:
    log_tracker_error()
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  for issue in sort_for_dispatch(issues):
    if no_available_slots(state):
      break

    if should_dispatch(issue, state):
      state = dispatch_issue(issue, state, attempt=null)

  notify_observers()
  schedule_tick(state.poll_interval_ms)
  return state
```

### 16.3 Reconcile Active Runs

```text
function reconcile_running_issues(state):
  state = reconcile_stalled_runs(state)

  running_ids = keys(state.running)
  if running_ids is empty:
    return state

  refreshed = tracker.fetch_issue_states_by_ids(running_ids)
  if refreshed failed:
    log_debug("keep workers running")
    return state

  for issue in refreshed:
    if issue.state in terminal_states:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=true)
    else if issue.state in active_states:
      state.running[issue.id].issue = issue
    else:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=false)

  return state
```

### 16.4 Dispatch One Issue

```text
function dispatch_issue(issue, state, attempt):
  worker = spawn_worker(
    fn -> run_agent_attempt(issue, attempt, parent_orchestrator_pid) end
  )

  if worker spawn failed:
    return schedule_retry(state, issue.id, next_attempt(attempt), {
      identifier: issue.identifier,
      error: "failed to spawn agent"
    })

  state.running[issue.id] = {
    worker_handle,
    monitor_handle,
    identifier: issue.identifier,
    issue,
    session_id: null,
    codex_app_server_pid: null,
    last_codex_message: null,
    last_codex_event: null,
    last_codex_timestamp: null,
    last_codex_progress_timestamp: null,
    last_codex_error_signature: null,
    codex_input_tokens: 0,
    codex_output_tokens: 0,
    codex_total_tokens: 0,
    last_reported_input_tokens: 0,
    last_reported_output_tokens: 0,
    last_reported_total_tokens: 0,
    retry_attempt: normalize_attempt(attempt),
    started_at: now_utc()
  }

  state.claimed.add(issue.id)
  state.retry_attempts.remove(issue.id)
  return state
```

### 16.5 Worker Attempt (Workspace + Prompt + Agent)

```text
function run_agent_attempt(issue, attempt, orchestrator_channel):
  workspace = workspace_manager.create_for_issue(issue.identifier)
  if workspace failed:
    fail_worker("workspace error")

  if run_hook("before_run", workspace.path) failed:
    fail_worker("before_run hook error")

  session = app_server.start_session(
    workspace=workspace.path,
    codex_home=compiled_workflow.harness.codex_home
  )
  if session failed:
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("agent session startup error")

  max_turns = compiled_workflow.runtime.agent.max_turns
  turn_number = 1

  while true:
    prompt = build_turn_prompt(compiled_workflow.prompt_template, issue, attempt, turn_number, max_turns)
    if prompt failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("prompt error")

    turn_result = app_server.run_turn(
      session=session,
      prompt=prompt,
      issue=issue,
      on_message=(msg) -> send(orchestrator_channel, {codex_update, issue.id, msg})
    )

    if turn_result failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("agent turn error")

    refreshed_issue = tracker.fetch_issue_states_by_ids([issue.id])
    if refreshed_issue failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("issue state refresh error")

    issue = refreshed_issue[0] or issue

    if issue.state is not active:
      break

    if turn_number >= max_turns:
      break

    turn_number = turn_number + 1

  app_server.stop_session(session)
  run_hook_best_effort("after_run", workspace.path)

  exit_normal()
```

### 16.6 Worker Exit and Retry Handling

```text
on_worker_exit(issue_id, reason, state):
  running_entry = state.running.remove(issue_id)
  state = add_runtime_seconds_to_totals(state, running_entry)

  if reason == normal:
    state.completed.add(issue_id)  # bookkeeping only
    state = schedule_retry(state, issue_id, 1, {
      identifier: running_entry.identifier,
      delay_type: continuation
    })
  else:
    state = schedule_retry(state, issue_id, next_attempt_from(running_entry), {
      identifier: running_entry.identifier,
      error: format("worker exited: %reason")
    })

  notify_observers()
  return state
```

```text
on_retry_timer(issue_id, state):
  retry_entry = state.retry_attempts.pop(issue_id)
  if missing:
    return state

  candidates = tracker.fetch_candidate_issues()
  if fetch failed:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: retry_entry.identifier,
      error: "retry poll failed"
    })

  issue = find_by_id(candidates, issue_id)
  if issue is null:
    state.claimed.remove(issue_id)
    return state

  if available_slots(state) == 0:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: issue.identifier,
      error: "no available orchestrator slots"
    })

  return dispatch_issue(issue, state, attempt=retry_entry.attempt)
```

## 17. Test and Validation Matrix

A conforming implementation SHOULD include tests that cover the behaviors defined in this
specification.

Validation profiles:

- `Core Conformance`: deterministic tests REQUIRED for all conforming implementations.
- `Extension Conformance`: REQUIRED only for OPTIONAL features that an implementation chooses to
  ship.
- `Real Integration Profile`: environment-dependent smoke/integration checks RECOMMENDED before
  production use.

Unless otherwise noted, Sections 17.1 through 17.7 are `Core Conformance`. Bullets that begin with
`If ... is implemented` are `Extension Conformance`.

### 17.1 Manifest, Module, and Config Parsing

- Manifest path precedence:
  - explicit manifest path is used when provided
  - cwd default is `symphony.yml` when no explicit manifest path is provided
- Manifest, module, and relevant deployment config changes trigger recompile/re-apply without
  restart
- Invalid manifest/module reload keeps the last known good compiled workflow and emits an
  operator-visible error
- Missing `symphony.yml` returns typed error
- Invalid manifest YAML returns typed error
- Manifest root non-map returns typed error
- Default selected modules report a path-specific diagnostic when `project.repository` is missing
- Preset resolution is deterministic
- `symphony.yml` manifest defaults resolve from installed presets/modules without release-channel
  fields
- `symphony.yml` default workspace resolution compiles a repository population hook from
  `project.repository`
- Unknown manifest presets/modules return path-specific diagnostics
- `policy_ref` changes when normalized manifest, selected module refs, profile inputs, or rendered
  policy content change
- Config defaults apply when OPTIONAL values are missing
- `runtime.tracker.kind` validation enforces currently supported kind (`linear`)
- `runtime.tracker.api_key` works (including `$VAR` indirection)
- `$VAR` resolution works for tracker API key and path values
- `~` path expansion works for fields that explicitly allow path expansion
- `runtime.codex.command` is preserved as a shell command string
- Per-state concurrency override map normalizes state names and rejects invalid values
- Compiled prompt template renders `issue` and `attempt`
- Prompt template can render bundled workflow module context
- Workflow module resolution records module names, versions, and a policy hash
- Missing external delivery skills does not block workflow startup or agent execution
- Prompt rendering fails on unknown variables (strict mode)
- If rendered Markdown export is implemented, it is generated from the compiled workflow and is not
  required as target repo source

### 17.2 Workspace Manager and Safety

- Deterministic workspace path per issue identifier
- Missing workspace directory is created
- Existing workspace directory is reused
- Existing non-directory path at workspace location is handled safely (replace or fail per
  implementation policy)
- OPTIONAL workspace population/synchronization errors are surfaced
- `after_create` hook runs only on new workspace creation
- `before_run` hook runs before each attempt and failure/timeouts abort the current attempt
- `after_run` hook runs after each attempt and failure/timeouts are logged and ignored
- `before_remove` hook runs on cleanup and failures/timeouts are ignored
- Workspace path sanitization and root containment invariants are enforced before agent launch
- Agent launch uses the per-issue workspace path as cwd and rejects out-of-root paths

### 17.3 Issue Tracker Client

- Candidate issue fetch uses active states and configured project or team scope
- Linear query uses the specified project filter field (`id`/`slugId`) or team key filter
- Empty `fetch_issues_by_states([])` returns empty without API call
- Pagination preserves order across multiple pages
- Blockers are normalized from inverse relations of type `blocks`
- Labels are normalized to lowercase
- Issue state refresh by ID returns minimal normalized issues
- Issue state refresh query uses GraphQL ID typing (`[ID!]`) as specified in Section 11.2
- Error mapping for request errors, non-200, GraphQL errors, malformed payloads
- If incident signal intake is implemented, dry-run validates the normalized fake payload, generated
  issue body, labels, target state, source-specific evidence, suggested validation, priority
  mapping, and correlation marker without creating tracker work
- If incident signal intake is implemented, duplicate suppression detects a matching bounded
  non-terminal correlation marker before create mode attempts a new issue, and terminal matches are
  treated as stale

### 17.4 Orchestrator Dispatch, Reconciliation, and Retry

- Dispatch sort order is priority then oldest creation time
- `Todo` issue with non-terminal blockers is not eligible
- `Todo` issue with terminal blockers is eligible
- Requirement issues are eligible from `Todo` only when they have at least one blocking
  implementation issue and all blockers are terminal
- Active-state issue refresh updates running entry state
- Non-active state stops running agent without workspace cleanup
- Terminal state stops running agent and cleans workspace
- Reconciliation with no running issues is a no-op
- Normal worker exit schedules a short continuation retry (attempt 1)
- Abnormal worker exit increments retries with 10s-based exponential backoff
- Retry backoff cap uses configured `runtime.agent.max_retry_backoff_ms`
- Retry queue entries include attempt, due time, identifier, and error
- Stall detection kills stalled sessions and schedules retry
- Slot exhaustion requeues retries with explicit error reason
- If a snapshot API is implemented, it returns running rows, retry rows, token totals, and rate
  limits
- If a snapshot API is implemented, timeout/unavailable cases are surfaced

### 17.5 Coding-Agent App-Server Client

- Launch command uses workspace cwd and invokes `bash -lc <runtime.codex.command>`
- Launch uses the harness `CODEX_HOME` and does not rely on the operator's ambient `~/.codex`
- Session startup follows the targeted Codex app-server protocol.
- Client identity/capability payloads are valid when the targeted Codex app-server protocol requires
  them.
- Policy-related startup payloads use the implementation's documented approval/sandbox settings
- Thread and turn identities exposed by the targeted protocol are extracted and used to emit
  `session_started`
- Request/response read timeout is enforced
- Turn timeout is enforced
- Transport framing required by the targeted protocol is handled correctly
- For stdio-based transports, diagnostic stderr handling is kept separate from the protocol stream
- Command/file-change approvals are handled according to the implementation's documented policy
- Unsupported dynamic tool calls are rejected without stalling the session
- User input requests are handled according to the implementation's documented policy and do not
  stall indefinitely
- Usage and rate-limit telemetry exposed by the targeted protocol is extracted
- Approval, user-input-required, usage, and rate-limit signals are interpreted according to the
  targeted protocol
- If client-side tools are implemented, session startup advertises the supported tool specs
  using the targeted app-server protocol
- If the `linear_graphql` client-side tool extension is implemented:
  - the tool is advertised to the session
  - valid `query` / `variables` inputs execute against configured Linear auth
  - top-level GraphQL `errors` produce `success=false` while preserving the GraphQL body
  - invalid arguments, missing auth, and transport failures return structured failure payloads
  - unsupported tool names still fail without stalling the session

### 17.6 Observability

- Validation failures are operator-visible
- Structured logging includes issue/session context fields
- Logging sink failures do not crash orchestration
- Token/rate-limit aggregation remains correct across repeated agent updates
- If a human-readable status surface is implemented, it is driven from orchestrator state and does
  not affect correctness
- If humanized event summaries are implemented, they cover key wrapper/agent event classes without
  changing orchestrator behavior

### 17.7 CLI and Host Lifecycle

- CLI or host config accepts an explicit manifest path argument (`path-to-symphony.yml`) or
  equivalent setting
- CLI accepts a positional manifest path argument
- CLI uses `./symphony.yml` when no manifest path argument is provided
- CLI errors on nonexistent explicit manifest path or missing default manifest
- CLI or host config accepts or derives the harness `CODEX_HOME`
- CLI can initialize a target repo `symphony.yml` without overwriting an existing manifest unless
  explicitly forced
- CLI can check a target repo manifest and fail nonzero with field-level remediation for schema,
  module, doc, tracker scope, or configured harness problems
- CLI can print the resolved workflow preset/modules/defaults and optionally include the compiled
  workflow config/prompt
- CLI surfaces startup failure cleanly
- CLI exits with success when application starts and shuts down normally
- CLI exits nonzero when startup fails or the host process exits abnormally

### 17.8 Real Integration Profile (RECOMMENDED)

These checks are RECOMMENDED for production readiness and MAY be skipped in CI when credentials,
network access, or external service permissions are unavailable.

- A real tracker smoke test can be run with valid credentials supplied by `LINEAR_API_KEY` or a
  documented local bootstrap mechanism (for example `~/.linear_api_key`).
- Real integration tests SHOULD use isolated test identifiers/workspaces and clean up tracker
  artifacts when practical.
- A skipped real-integration test SHOULD be reported as skipped, not silently treated as passed.
- If a real-integration profile is explicitly enabled in CI or release validation, failures SHOULD
  fail that job.

## 18. Implementation Checklist (Definition of Done)

Use the same validation profiles as Section 17:

- Section 18.1 = `Core Conformance`
- Section 18.2 = `Extension Conformance`
- Section 18.3 = `Real Integration Profile`

### 18.1 REQUIRED for Conformance

- Manifest path selection supports explicit runtime path and target repo root default
- `symphony.yml` loader with v1 YAML object schema
- Workflow module registry with presets and selected modules
- Workflow compiler that produces `policy_ref`, prompt template, checks, completion requirements,
  transitions, tools, delivery config, harness config, runtime config, and docs routing
- Typed config layer with defaults and `$` resolution
- Dynamic manifest/module/deployment config watch/recompile/re-apply
- Dedicated harness `CODEX_HOME` with harness global `AGENTS.md`
- Target repo `AGENTS.md` and docs layering after harness global instructions
- Polling orchestrator with single-authority mutable state
- Issue tracker client with candidate fetch + state refresh + terminal fetch
- Workspace manager with sanitized per-issue workspaces
- Workspace lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`)
- Hook timeout config (`runtime.hooks.timeout_ms`, default `60000`)
- Coding-agent app-server subprocess client with JSON line protocol
- Codex launch command config (`runtime.codex.command`, default `codex app-server`)
- Strict prompt rendering with `issue` and `attempt` variables
- Exponential retry queue with continuation retries after normal exit
- Configurable retry backoff cap (`runtime.agent.max_retry_backoff_ms`, default 5m)
- Reconciliation that stops runs on terminal/non-active tracker states
- Workspace cleanup for terminal issues (startup sweep + active transition)
- Structured logs with `issue_id`, `issue_identifier`, and `session_id`
- Operator-visible observability (structured logs; OPTIONAL snapshot/status surface)

### 18.2 RECOMMENDED Extensions (Not REQUIRED for Conformance)

- HTTP server extension honors CLI `--port` over `runtime.server.port`, uses a safe default bind
  host, and exposes the baseline endpoints/error semantics in Section 13.7 if shipped.
- `linear_graphql` client-side tool extension exposes raw Linear GraphQL access through the
  app-server session using configured Symphony auth.
- `review_routing` policy extension compiles into resolved profile policy, produces route evidence
  from Section 11.7, and covers auto-land, human-review, decision, product/visual-review, blocked,
  and PR-feedback Rework paths in tests.
- `product_visual_review` selected through `workflow.modules` adds product/design QA routing to
  first-turn prompts and keeps the classification testable through route policy, project kind,
  changed-file triggers, issue-label triggers, checks, and artifact ids.
- Incident signal intake extension defaults to dry-run, requires explicit project opt-in for create
  mode, documents project-monitoring ownership, binds create mode to the selected workflow tracker
  project, and performs bounded non-terminal duplicate suppression.
- TODO: Persist retry queue and session metadata across process restarts.
- TODO: Make observability settings configurable in compiled runtime config without prescribing UI
  implementation details.
- TODO: Add first-class tracker write APIs (comments/state transitions) in the orchestrator instead
  of only via agent tools.
- TODO: Add pluggable issue tracker adapters beyond Linear.

### 18.3 Operational Validation Before Production (RECOMMENDED)

- Run the `Real Integration Profile` from Section 17.8 with valid credentials and network access.
- Verify hook execution, manifest path resolution, module resolution, and harness `CODEX_HOME` on
  the target host OS/shell environment.
- If the OPTIONAL HTTP server is shipped, verify the configured port behavior and loopback/default
  bind expectations on the target environment.

## Appendix A. SSH Worker Extension (OPTIONAL)

This appendix describes a common extension profile in which Symphony keeps one central
orchestrator but executes worker runs on one or more remote hosts over SSH.

Extension config:

- `worker.ssh_hosts` (list of SSH host strings, OPTIONAL)
  - When omitted, work runs locally.
- `worker.max_concurrent_agents_per_host` (positive integer, OPTIONAL)
  - Shared per-host cap applied across configured SSH hosts.

### A.1 Execution Model

- The orchestrator remains the single source of truth for polling, claims, retries, and
  reconciliation.
- `worker.ssh_hosts` provides the candidate SSH destinations for remote execution.
- Each worker run is assigned to one host at a time, and that host becomes part of the run's
  effective execution identity along with the issue workspace.
- `runtime.workspace.root` is interpreted on the remote host, not on the orchestrator host.
- The coding-agent app-server is launched over SSH stdio instead of as a local subprocess, so the
  orchestrator still owns the session lifecycle even though commands execute remotely.
- Continuation turns inside one worker lifetime SHOULD stay on the same host and workspace.
- A remote host SHOULD satisfy the same basic contract as a local worker environment: reachable
  shell, writable workspace root, coding-agent executable, and any required auth or repository
  prerequisites.

### A.2 Scheduling Notes

- SSH hosts MAY be treated as a pool for dispatch.
- Implementations MAY prefer the previously used host on retries when that host is still
  available.
- `worker.max_concurrent_agents_per_host` is an OPTIONAL shared per-host cap across configured SSH
  hosts.
- When all SSH hosts are at capacity, dispatch SHOULD wait rather than silently falling back to a
  different execution mode.
- Implementations MAY fail over to another host when the original host is unavailable before work
  has meaningfully started.
- Once a run has already produced side effects, a transparent rerun on another host SHOULD be
  treated as a new attempt, not as invisible failover.

### A.3 Problems to Consider

- Remote environment drift:
  - Each host needs the expected shell environment, coding-agent executable, auth, and repository
    prerequisites.
- Workspace locality:
  - Workspaces are usually host-local, so moving an issue to a different host is typically a cold
    restart unless shared storage exists.
- Path and command safety:
  - Remote path resolution, shell quoting, and workspace-boundary checks matter more once execution
    crosses a machine boundary.
- Startup and failover semantics:
  - Implementations SHOULD distinguish host-connectivity/startup failures from in-workspace agent
    failures so the same ticket is not accidentally re-executed on multiple hosts.
- Host health and saturation:
  - A dead or overloaded host SHOULD reduce available capacity, not cause duplicate execution or an
    accidental fallback to local work.
- Cleanup and observability:
  - Operators need to know which host owns a run, where its workspace lives, and whether cleanup
    happened on the right machine.
