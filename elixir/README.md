# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony in this fork, based on
[`SPEC.md`](../SPEC.md) at the repository root. The root [`PRODUCT.md`](../PRODUCT.md) owns product
posture and prioritization; the root [`README.md`](../README.md) is the public fork overview. This
file is the implementation setup and operation guide.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation in trusted environments. This fork
> is an independent public fork, not an official OpenAI distribution. Harden and operate it under
> your own policies before using it on sensitive repositories.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches the configured `AgentRuntime` runner inside the workspace
4. Sends a workflow prompt to the runner
5. Keeps the runner working on the issue until the work is done

The current production runner is the Codex app-server adapter.

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that
bundled workflow modules and agents can make raw Linear GraphQL calls when the direct tracker tool
surface is not enough.

The shared `SymphonyElixir.ProcessSupervisor` primitive supports argv launch, workspace cwd,
CODEX_HOME environment overlay, line buffering, startup timeout normalization, process identity,
stop/kill, and best-effort descendant cleanup through the host `ps`/`kill` process tree. Local
Codex runner commands are configured as argv lists under `runtime.runners.<name>.command`; Symphony
wraps that argv only to preserve app-server stdin and cleanup behavior. Remote worker launch converts
the argv into an explicit SSH shell command; Symphony supervises the local ssh port, but remote
process-group and descendant cleanup are not guaranteed by this local primitive.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If the selected runtime reports that operator input, approval, or MCP elicitation is required,
Symphony keeps the issue claimed and exposes it as blocked in the runtime state, JSON API, and
dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
Linear issue can become a dispatch candidate again after restart.

Completed or blocked worker runs also record a structured handoff route decision in runtime state.
The route captures the selected Linear target state, recommendation, evidence, and available
artifacts so operators can inspect why work is headed to Human Review, Rework, product review, or a
decision-needed handoff.

After a worker finishes source edits, Symphony runs a host-owned publish preflight before handoff
route classification. The preflight checks whether the workspace VCS metadata is available to the
host, whether the configured remote accepts a push dry-run, and whether the configured GitHub
repository/base branch can support PR creation. The checks return structured capability and failure
data without creating commits, branches, pushes, or pull requests.

When completion metadata includes `changed_files` or `change_manifest.changed_files`, Symphony
validates each path on the host before recording a publishable route. Paths must be relative,
normalized workspace paths. Absolute paths, traversal, symlink escapes, generated runtime state,
logs, caches, temporary app data, local secrets, and operator-local config are rejected with
structured route evidence.

When publish-target validation, host preflight, and changed-file manifest validation all pass,
Symphony publishes the completed workspace under host control. The host creates or updates a
deterministic `ticket/<issue-id>` branch or jj bookmark, pushes it to the resolved GitHub repository,
opens or updates a PR against the configured base branch, and records the PR URL, target repository,
base branch, branch or change id, validation summary, and Linear issue evidence in the handoff
route. The generated PR body includes a `Reviewer Testing` section that points a human reviewer to
the changed path, screen, command, or expected state without replacing validation evidence, quality
gates, or full UAT criteria. Publish failures are recorded as structured blocked evidence instead of
moving the issue as ready for merge.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Build the Elixir escript and run `./bin/symphony workflow init --repo /path/to/repo` to create
   `symphony.yml`.
4. Run `./bin/symphony workflow check --repo /path/to/repo` to validate the manifest, repo docs,
   runner config, and any configured harness CODEX_HOME.
5. Run `./bin/symphony workflow print --repo /path/to/repo --compiled` to inspect the resolved
   workflow config and prompt.
6. Customize the generated `symphony.yml` for your project.
   - Prefer the Linear project ID in committed `runtime.tracker.project_id`; add
     `runtime.tracker.project_slug` when the dashboard should render a project URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
7. Follow the instructions below to install the required runtime dependencies and start the service.

The root [`../symphony.yml`](../symphony.yml) is this repository's dogfood manifest. It
intentionally contains this fork's public repository URL, local workspace defaults, Linear project
scope, and Codex runner launch policy for running Symphony on itself. For another repository,
create a fresh manifest with `workflow init` and replace tracker, workspace, repository,
validation, delivery, and runner fields with that project's values.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/apontarelli/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
export LINEAR_API_KEY=...
mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails /path/to/project/symphony.yml
```

From a checkout, the repository also provides a higher-level shell launcher at `../bin/symphony`.
It keeps local shell glue in this repo instead of dotfiles, resolves project workflows, optionally
loads `~/.config/symphony/.env` through `op run`, rebuilds the escript before launching, and passes
the raw escript's local-run acknowledgement flag.

Use the current shell environment when secrets are already exported:

```bash
export LINEAR_API_KEY=...
../bin/symphony --no-env-file --workflow /path/to/project/symphony.yml
```

Use the launcher env file when you want the 1Password CLI to resolve `op://` secret references:

```bash
mkdir -p ~/.config/symphony
cp ../symphony.env.example ~/.config/symphony/.env
../bin/symphony my-project
../bin/symphony --workflow /path/to/project/symphony.yml
```

To make `symphony` available as a shell command, put the repository `bin/` directory on `PATH` or
symlink `../bin/symphony` into a directory already on `PATH`.

## Configuration

Target repos can use a committed `symphony.yml` manifest for setup and audit:

```bash
./bin/symphony workflow init --repo /path/to/repo
./bin/symphony workflow check --repo /path/to/repo
./bin/symphony workflow print --repo /path/to/repo --compiled
```

`init` inspects common repo files and creates `symphony.yml`. If the manifest already exists, it is
left unchanged unless `--force` is passed. `check` validates the manifest schema, selected modules,
repo doc entrypoints, validation command shape, runner config, and a configured harness
`CODEX_HOME`. `print` shows the resolved preset/modules/defaults and can include the compiled
workflow config and prompt without writing generated prompt files into the target repo.

`symphony.yml` v1 contains:

This is a neutral starting point for another repository, not a copy of this fork's dogfood
manifest:

```yaml
version: 1
project:
  name: my-repo
  kind: elixir
  app_kind: local
workflow:
  preset: default
  modules: []
docs:
  entrypoints:
    - AGENTS.md
    - README.md
validation:
  commands:
    - name: test
      command: mix test
vcs:
  mode: jj
delivery:
  pr_target: main
automation:
  posture: unattended
harness:
  codex_home: null
runtime:
  agent:
    default_runner: codex
    max_concurrent_startups: 2
  runners:
    codex:
      kind: codex_app_server
      command:
        - codex
        - app-server
```

`runtime.agent.default_runner` selects the runner config under `runtime.runners`. For the Codex
app-server adapter, `harness.codex_home: null` means Symphony derives a managed harness
`CODEX_HOME`; if a path is set, `workflow check` requires that directory and its `AGENTS.md` to
exist.

Pass a manifest path to `./bin/symphony` when starting the service directly:

```bash
./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ../symphony.yml
```

The raw escript requires the local-run acknowledgement flag. If no path is passed, it uses
`./symphony.yml` from the current directory. From this repository, prefer the higher-level
`../bin/symphony` launcher so local runs use the single root manifest and the launcher passes the
acknowledgement flag for you.

`project.criticality` and `project.deployment_coupling` describe how risky the project is to land
automatically. Local, prototype, and internal work default to permissive auto-land policy; production
or production-web coupled work defaults to strict policy.

`auto_land.posture` can be `off`, `permissive`, or `strict`. When omitted, Symphony derives the
posture from project criticality and deployment coupling. `auto_land.required_checks` adds evidence
requirements to the posture defaults: permissive policy requires tests, quality gates, automated
review, route classification, and sync evidence. Repos that opt into real landing with
`auto_land.dry_run: false` also must provide PR feedback sweep evidence before routing to `Merging`.
Strict policy also requires project-owned production recovery evidence: deployment status, rollback
or rollback-plan proof, monitoring source, and incident issue creation path. A generic `recovery`
check is not sufficient for strict or production-web auto-land.

`auto_land.force_human_review_labels` always routes matching issues to human review, even when
evidence is otherwise sufficient. `auto_land.dry_run` defaults to `true`, so Symphony classifies and
records an auto-land decision without merging. Setting `auto_land.dry_run: false` is the opt-in for
guarded real auto-land: the classifier can move eligible work to `Merging`, where the existing land
flow performs final check and review polling before merge. The project remains responsible for how
deployments are performed, how rollback or rollback-plan proof is generated, where monitoring
signals originate, and how incident intake creates tracker work.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)
- `--profile` selects one workflow profile for the current process

Quality-gate review records are stored under the same root selected by `--logs-root`, in
`review-records/quality-gates/<project-slug>/<issue-identifier>/<run-id>/`. The daemon derives this
root from the configured log file path, so records are host-owned runtime artifacts rather than files
written into the target repository workspace. Operators can inspect them without starting the daemon:

```bash
./bin/symphony review-records list --logs-root /path/to/logs-root
./bin/symphony review-records show <run-id> --logs-root /path/to/logs-root
./bin/symphony review-records export --since last --logs-root /path/to/logs-root
```

Each record directory contains stable `metadata.json`, `quality_gate.json`, `findings.json`, and
`handoff_route.json` files plus a mutable `disposition.json` sidecar. `findings.json` is not rewritten
after creation; update `disposition.json` when a finding is accepted, fixed, rejected as a false
positive, deferred, or left for operator decision. The export command groups findings by category,
disposition, file/surface, false-positive pattern, and follow-up candidate. It also writes
review-retrospective-compatible sidecars under `review-records/review/<project-slug>/<run-id>/`
so the shared `review-retrospective` workflow can mine Symphony quality-gate records by pointing
`AGENT_RECORDS_HOME` at the `review-records` root. Historical
`review-records/parallel-review/<project-slug>/<run-id>/` sidecars are legacy input only; run
`./bin/symphony review-records backfill-review --logs-root /path/to/logs-root` once to copy them
into canonical `review/` records while preserving the original legacy path in metadata provenance.

The preferred `symphony.yml` file is a thin YAML manifest that selects Symphony-owned workflow
modules. The manifest compiles into the same runtime config/prompt shape used by the daemon.
`version` defaults to `1` when omitted, but examples include it explicitly for clarity.

Minimal manifest example:

```yaml
version: 1
project:
  slug: "..."
  repository: git@github.com:your-org/your-repo.git
  kind: elixir
  app_kind: web
docs:
  entrypoints:
    - README.md
vcs:
  mode: git
  default_branch: main
validation:
  commands:
    - name: tests
      command: make test
delivery:
  pr_target: main
automation:
  posture: unattended
  profile: default
workflow:
  preset: default
```

When `project.repository` is present, the default `workspace` module uses it to populate new issue
workspaces with `git clone --depth 1 <repository> .`. For the default GitHub PR delivery workflow,
`workflow check` also validates that `project.repository` is a GitHub repository URL and that
`delivery.pr_target` is explicitly set; `workflow print` shows the resolved publish target as
`owner/repo:branch`.

Repository-owned profile overrides can live under `runtime.profiles` in committed `symphony.yml`.
They describe policy available to every run of the repo and should not contain Linear project IDs:

```yaml
runtime:
  profiles:
    project_integration:
      delivery:
        pr_target: project/integration
      checks:
        - make all
```

The `default` profile is compiled from manifest delivery, validation, and automation fields.
`delivery.pr_target` is the only v1 delivery selector: use `main` for normal mainline PRs, or a
non-main branch such as `project/integration` when work should open PRs against a project integration
branch. v1 does not automate promotion from a non-main target back to `main` after restart or
landing.

Notes:

- If a value is missing, defaults are used unless a selected workflow module documents a stricter
  validation requirement, such as the default GitHub PR publish target checks.
- `tracker.required_labels` is optional. When set, an issue must have every configured label to
  dispatch or continue running. Label matching ignores case and surrounding whitespace. A blank
  configured label matches no issue.
- `delivery.pr_target` names the Git PR target/base branch. Additional profiles may override the
  compiled `default` profile during effective-policy resolution.
- Profile overrides replace scalar, list, and map fields by default. Use `append_<field>` for list
  additions and `add_<field>` for map additions. The resolved policy includes a stable
  `policy_ref` short hash. Replacement fields are applied before additive directives when both
  appear in the same profile.
- Linear polling scope lives in committed `symphony.yml` under `runtime.tracker`. Prefer
  `project_id`; include `project_slug` when a human-readable Linear project URL/display fallback is
  useful. The project scope is repository automation policy, not a local operator preference:

```yaml
runtime:
  tracker:
    project_id: 00000000-0000-0000-0000-000000000000
    project_slug: my-linear-project-slug
```

- Candidate polling filters by `runtime.tracker.project_id` when present and falls back to
  `runtime.tracker.project_slug`. Workflow profiles do not choose which Linear project is polled.
  `--profile` is a process-wide override for policy selection; otherwise the `default` profile is
  used.
- Ticket class labels have generic Symphony behavior independent of tracker project scope:
  - `Requirement` issues are validation artifacts. They require at least one blocking
    implementation issue and are dispatched from `Todo` only after all blockers are terminal.
    Zero blockers is a setup defect, not a dispatchable state.
  - `Project Closeout` issues use the project closeout workflow and should be blocked by unresolved
    Requirement issues.
- Prompt templates receive the resolved policy as `{{ policy }}` and `{{ policy_json }}`,
  including `policy.policy_ref`, `delivery.pr_target`, and `policy.policy_metadata` when the
  runtime attaches metadata. Delivery workflow modules use `delivery.pr_target` for branch sync, PR
  base selection, review gates, and landing guardrails. Symphony also appends a compact
  selected-profile block to the first agent prompt with the exact workpad stamp, profile prompt
  rules (`prompt.rules`, `prompt_rules`, or `prompt_requirements`), validation requirements
  (`checks`, `validation`, or `validation_requirements`), and review requirements (`review` or
  `review_requirements`).
- The workpad stamp format is
  `Policy: profile=<name> target=<pr_target> policy_ref=<short-hash>`. Explicit `--profile`
  metadata appends `override=profile_override`; default profile selection does not.
- The v1 core delivery policy only supports `delivery.pr_target`; `delivery.mode`,
  `delivery.base_ref`, `delivery.allow_main_merge`, and `delivery.require_feature_flag` are not
  supported core fields.
- Safer Codex defaults are used when runner policy fields are omitted:
  - `runtime.agent.default_runner` defaults to `codex`
  - `runtime.agent.max_concurrent_startups` defaults to `2`
  - `runtime.runners.codex.approval_policy` defaults to `on-request`
  - `runtime.runners.codex.thread_sandbox` defaults to `workspace-write`
  - `runtime.runners.codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Codex app-server sessions run with a Symphony-owned `CODEX_HOME`. By default, Symphony generates
  it as a sibling to issue workspaces at `<workspace.root>/.symphony/codex_home`.
  - Symphony owns the generated harness `AGENTS.md` in that home.
  - The target repository cwd is still the issue workspace, so repo-local `AGENTS.md` files and docs
    layer after the harness global instructions.
  - `SYMPHONY_CODEX_HOME` overrides the generated path for local development and tests.
  - Worker machines still provide the Codex executable and authentication material. When
    `~/.codex/auth.json` exists for the worker user, Symphony links it into the harness home; it does
    not copy Symphony skills into `~/.agents` or `~/.codex`.
- Supported `runtime.runners.codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, `granular`, and `never`; legacy object-form `reject` is not accepted by Codex CLI 0.128.0.
- Supported `runtime.runners.codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `runtime.runners.codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `runtime.runners.codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `runtime.runners.codex.execution_profiles` lets the host run implementation, planner, reviewer,
  runtime QA, product visual review, security review, and synthesis jobs with typed reasoning,
  timeout, retry, budget, model, or command settings. `runtime.runners.codex.model` is the default
  launch model. Profile `model` values override it for that launch, and explicit model flags already
  present in `runtime.runners.codex.command` control the command unchanged. Operators do not need to
  rewrite the argv list for normal profile tuning.
- Workflow profiles may include `runners.codex` with `approval_policy`, `thread_sandbox`, and
  `turn_sandbox_policy` overrides. Use this sparingly for scoped, interactive work like repo skill
  authoring that needs to edit protected repo-local skill or tooling paths. Profile overrides do
  not make globally installed `symphony-*` skills part of unattended runtime execution; keep the
  default Codex runner sandboxed.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `quality_gate.enabled` controls the host-owned post-implementation review fanout. When enabled,
  Symphony plans required source, test-quality, scenario QA, product visual, docs/source-of-truth,
  and security/data/migration review jobs from changed files, changed surfaces, policy, and issue
  labels. Source/test/docs/security review jobs run with a read-only Codex turn policy. Scenario QA
  remains browser-backed: it runs with a browser-capable `workspaceWrite` policy with network access
  unless the selected policy already grants `dangerFullAccess`. Before those jobs run, Symphony
  checks for an executable Chrome/Chromium browser through `BROWSER_QA_CHROME_PATH`, the macOS
  Google Chrome path, or common Linux Chrome/Chromium executable names; remote worker runs perform
  the same check over SSH on the worker. Product visual review can instead use the host-owned
  `quality_gate.host_visual_qa.command` runner. That command runs outside the reviewer sandbox with
  `SYMPHONY_VISUAL_QA_ARTIFACT_DIR`, `SYMPHONY_VISUAL_QA_MANIFEST`,
  `SYMPHONY_VISUAL_QA_CATEGORY`, and `SYMPHONY_ISSUE_IDENTIFIER` env vars; on success the reviewer
  receives the manifest/artifact package under a read-only policy and does not need to launch a
  browser. If no host visual QA command is configured, product visual review falls back to the
  browser-capable reviewer path. Missing browser launch or host visual QA infrastructure blocks the
  affected job as infrastructure evidence instead of reporting a product failure. Source-only jobs
  run under `quality_gate.source_max_concurrency`; runtime QA and product visual review use
  `quality_gate.runtime_isolation` and default to serialized execution. `isolated_workspace`
  conservative-blocks until disposable reviewer workspaces are available. Fix-required findings
  trigger up to `quality_gate.max_repair_passes` bounded repair turns, followed by replanning from
  repair completion scope and rerunning the affected reviewer subset. The final `quality_gate`
  bundle is recorded as handoff evidence and can route work to Rework or Blocked before
  publish/human-review routing. After route classification, Symphony writes the same quality-gate
  bundle to the host-owned review-record directory so later retrospectives can distinguish fixed,
  rejected false-positive, deferred, no-action, and operator-decision findings.
- If the Markdown body is blank, Symphony compiles the built-in v1 core workflow module preset into
  the prompt template. The default preset includes Symphony-owned modules for Linear operation,
  implementation, sync, quality gates, review, landing, rework, requirement validation, project
  closeout, and run recovery.
- Bundled core workflow modules resolve through `SymphonyElixir.Workflow.ModuleRegistry` during
  prompt compilation. A custom workflow prompt can render them with `{{ workflow.modules }}`, and
  each run records module names, versions, and a policy hash. The default delivery workflow is
  self-contained in bundled modules selected through `workflow.modules`; runtime behavior comes from
  the registry, manifest, and recorded module policy hash.
- `product_visual_review` can be selected in `workflow.modules` and configured under
  `runtime.workflow_modules.product_visual_review` to enable product/design QA prompts and durable
  handoff-route evidence. Set `enabled: true`, choose `project_kind: web | mobile | desktop`, and
  use `route_policy: auto | required | recommended | off`. In `auto`, Symphony classifies the final
  validated changed-file manifest against configured `changed_file_triggers` and issue labels,
  records whether visual QA was required, recommended, skipped, or blocked, and keeps durable
  screenshot/media links plus interaction, responsive-state, and product/design notes in the
  handoff route. Local temp/file paths are rejected instead of being exposed as dashboard/API
  artifact links.
- Use `hooks.after_create` to bootstrap a fresh workspace. Prefer `jj git clone ... .` so Codex
  turns run in jj-native workspaces and do not need to write Git metadata directly. Use
  `git clone ... .` only for repos that cannot run under jj compatibility.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling.
  `runtime.runners.<name>.command` is an argv list, so use explicit argv elements rather than shell
  expansion in the command field.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    if ! command -v jj >/dev/null 2>&1; then
      echo 'jj is required for this Symphony workflow' >&2
      exit 127
    fi
    jj git clone "$SOURCE_REPO_URL" .
  before_run: |
    jj status || true
agent:
  default_runner: codex
  max_concurrent_startups: 2
runners:
  codex:
    kind: codex_app_server
    command:
      - codex
      - app-server
```

- If the selected manifest is missing or invalid at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- A running or retrying issue keeps the resolved workflow profile policy selected at dispatch time.
  Hot-reloaded workflow/profile changes apply to future dispatches, not to the in-memory policy of
  already-running or already-retrying issues.
- v1 does not persist attempt policy in a durable store. After a process restart, any recovered
  future dispatch resolves policy from the current workflow/runtime config.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Incident-triggered issues

Project-owned monitoring can hand normalized production failure signals to Symphony with
`mix incident.linear_issue`. Dry-run is the default and prints the proposed Linear issue body for
inspection without calling Linear:

```bash
mix incident.linear_issue --payload /path/to/signal.json
```

Create mode requires `--create --acknowledge-project-opt-in`, resolves a `Backlog` or explicit
`Todo` Linear state plus labels, and scans a bounded set of recently updated project issues for the
correlation marker before creating new work. See
[`docs/incident_linear_issue.md`](docs/incident_linear_issue.md) for the payload contract, supported
signal sources, dedupe behavior, and monitoring ownership boundary.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- A compact control panel overview for freshness, running/retrying work, work errors,
  config warnings, stale sessions, runtime, and token usage
- A primary project status table for the configured tracker project plus runtime project rows
- Running session detail with issue state, profile/target, runtime, last Codex update,
  copyable session ID, and token split
- Handoff route detail with completion route, target state, product visual review evidence, and
  durable artifact references
- Optional Admin details for runtime metadata and rate-limit diagnostics only when upstream
  rate-limit data is present
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `../symphony.yml`: root dogfood manifest used by local runs and CLI `workflow check`/`print`
- `../.codex/`: repo-local Codex/Symphony helpers used by this fork's own automation runs; target
  repos do not need to install these globally for bundled workflow modules to run

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `symphony.yml`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it this fork's URL, and ask it to create and check a local
`symphony.yml` for that repository.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
