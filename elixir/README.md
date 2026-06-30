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

Local daemon processes coordinate tracker reads through an operator-owned tracker coordinator state
file under the configured workspace root (`.symphony/tracker_coordinator.state`). Candidate issue
polls for equivalent targets are cached briefly, Linear rate-limit backoff is shared by local
daemons, and issue leases prevent two coordinated daemons from dispatching the same issue at the
same time. This state is runtime-owned and is not written to target repository `symphony.yml` files.

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
3. Build the Elixir escript and run `./bin/symphony setup init --repo /path/to/repo` to create
   `symphony.yml`.
4. Run `./bin/symphony setup check --repo /path/to/repo` to validate the setup-only manifest,
   repo docs, validation command shape, publish target defaults, and any configured harness CODEX_HOME.
5. Run `./bin/symphony setup preview --repo /path/to/repo --compiled` to inspect the resolved
   workflow config and prompt.
6. Customize the generated `symphony.yml` for your project.
   - Keep committed `symphony.yml` to durable repo setup fields. Put Linear project scope, workspace
     roots, polling, agent capacity, runner commands, and host deployment settings in local config
     or run setup.
   - For existing mixed manifests, run `./bin/symphony setup migrate --repo /path/to/repo --name <run-name> --dry-run`
     to preview the split, then rerun with `--apply` to write local files and remove runtime fields
     from `symphony.yml`.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
7. Follow the instructions below to install the required runtime dependencies and start the service.

The root [`../symphony.yml`](../symphony.yml) is this repository's dogfood repo setup manifest. It
contains this fork's public repository URL, docs, validation, delivery policy, required
capabilities, issue markers, and selected workflow module configuration. Local run targets,
workspace, polling, runner, and host settings are intentionally not committed there.

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
mise exec -- ./bin/symphony run --preview --workflow /path/to/local-symphony-runtime.yml
mise exec -- ./bin/symphony run --workflow /path/to/local-symphony-runtime.yml
```

From a checkout, the repository also provides a higher-level shell launcher at `../bin/symphony`.
It keeps local shell glue in this repo instead of dotfiles, resolves local runtime setup files,
optionally loads `~/.config/symphony/.env` through `op run`, rebuilds the escript before launching,
and passes the resolved run setup to the Elixir CLI.

For first-run local use, prefer the interactive builder:

```bash
export LINEAR_API_KEY=...
../bin/symphony run --repo /path/to/repo --no-env-file
../bin/symphony run SID-123 SID-124 --repo /path/to/repo --no-env-file
../bin/symphony run my-saved-setup --no-env-file
```

`symphony run` creates `~/.config/symphony/config.yml` if it is missing, using
`~/dev/symphony-workspaces` as the default workspace root and `light`, `normal`, and `swarm` capacity
profiles. The builder previews the resolved run setup before confirmation and can save named setups
to `~/.config/symphony/runs/<name>.yml`. Explicit issue IDs use issue-batch mode by default.

When no `--workflow` is passed, the launcher looks for `symphony.runtime.yml`; if only a checked-in
setup-only `symphony.yml` is present, bare `symphony` enters the interactive run path and fails
before side effects unless required local runtime scope and secrets are available.

The raw escript also supports saved run setups. `./bin/symphony run <name>` reads
`~/.config/symphony/runs/<name>.yml`, creates `~/.config/symphony/config.yml` with defaults if it is
missing, materializes a runtime manifest under the local config directory, and starts the daemon.
Use `--dry-run` to verify the resolved setup without starting the daemon; include the acknowledgement
flag for a real raw-escript start:

```bash
./bin/symphony run my-project --dry-run
./bin/symphony run my-project --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Use the current shell environment when secrets are already exported:

```bash
export LINEAR_API_KEY=...
../bin/symphony run --preview --no-env-file --workflow /path/to/local-symphony-runtime.yml
../bin/symphony run --no-env-file --workflow /path/to/local-symphony-runtime.yml
```

Use the launcher env file when you want the 1Password CLI to resolve `op://` secret references.
Set `SYMPHONY_WORKFLOW` there to run the default local runtime setup, or use project-name shorthand
for `$SYMPHONY_DEV_ROOT/<project-name>/symphony.runtime.yml`:

```bash
mkdir -p ~/.config/symphony
cp ../symphony.env.example ~/.config/symphony/.env
../bin/symphony
../bin/symphony my-project
```

To make `symphony` available as a shell command, put the repository `bin/` directory on `PATH` or
symlink `../bin/symphony` into a directory already on `PATH`.

## Configuration

Target repos can use a committed `symphony.yml` manifest for setup and audit:

```bash
./bin/symphony setup init --repo /path/to/repo
./bin/symphony setup check --repo /path/to/repo
./bin/symphony setup preview --repo /path/to/repo --compiled
```

`init` inspects common repo files and creates `symphony.yml`. If the manifest already exists, it is
left unchanged unless `--force` is passed. `check` validates the setup-only manifest schema, selected
modules, repo doc entrypoints, validation command shape, required capability declarations, publish
target defaults, and configured harness `CODEX_HOME`. `preview` shows the resolved
preset/modules/defaults and can include the compiled workflow config and prompt without writing
generated prompt files into the target repo. `workflow init`, `workflow check`, and `workflow print`
remain one-release compatibility aliases; new docs and scripts should use `setup init`,
`setup check`, and `setup preview`.

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
capabilities:
  required: []
issue_markers:
  labels: []
  allowed_projects: []
harness:
  codex_home: null
```

For the Codex app-server adapter, `harness.codex_home: null` means Symphony derives a managed
harness `CODEX_HOME`; if a path is set, `setup check` requires that directory and its
`AGENTS.md` to exist. Runner selection and runner commands belong in the local runtime setup file,
not in the checked-in repo manifest.

Local operator config is stored at `~/.config/symphony/config.yml`. Defaults include workspace root
`~/dev/symphony-workspaces`, Linear active states `Todo`, `In Progress`, `Merging`, and `Rework`,
terminal states `Closed`, `Cancelled`, `Canceled`, `Duplicate`, and `Done`, polling interval
`30000`, Codex app-server runner defaults, and capacity profiles:

- `light`: 1 agent / 1 startup
- `normal`: 4 agents / 1 startup
- `swarm`: 10 agents / 2 startups

Deployment ceilings default to 10 agents and 2 startups. A saved run setup may choose a named
profile or an explicit capacity map, but the resolved capacity cannot exceed those ceilings.

Saved run setups live at `~/.config/symphony/runs/<name>.yml`. Names are limited to alphanumeric,
dot, underscore, and dash characters so setup files cannot escape the global runs directory. A setup
stores the target repo reference, tracker target, mode, capacity, and restrictive flags such as
required labels; app repositories are not used as saved run setup storage.

Run setup target examples:

```yaml
repo:
  path: /path/to/repo
target:
  type: project
  tracker:
    project_slug: symphony
mode: continuous
capacity: normal
```

```yaml
repo:
  path: /path/to/repo
target:
  type: team
  tracker:
    team_key: SID
mode: continuous
capacity:
  max_concurrent_agents: 2
  max_concurrent_startups: 1
```

```yaml
repo:
  path: /path/to/repo
target:
  type: query
  tracker:
    query_file: ~/.config/symphony/queries/ready.yml
mode: query
capacity: light
```

```yaml
repo:
  path: /path/to/repo
target:
  type: issues
  tracker:
    issue_ids:
      - SID-123
      - SID-124
mode: issue-batch
capacity: normal
```

Run setup may make a launch stricter with lower capacity, marker intersections, required labels, or
human-review-only flags. It cannot weaken repo-owned safety: validation commands, delivery target,
required capabilities, workflow modules, and checked-in policy come from repo setup.

For migration, `setup migrate` requires an explicit `--repo`, reads that repo's existing mixed
`symphony.yml`, reports every runtime/target field it will move, and leaves a setup-only manifest after apply:

```bash
./bin/symphony setup migrate --repo /path/to/repo --name my-project --dry-run
./bin/symphony setup migrate --repo /path/to/repo --name my-project --apply
```

Preview the resolved run setup before side effects, then pass a local runtime setup path to
`./bin/symphony run` when starting the service directly:

```bash
./bin/symphony run --preview --workflow /path/to/local-symphony-runtime.yml
./bin/symphony run --workflow /path/to/local-symphony-runtime.yml
```

Interactive `run` prints the same preview and requires a TTY confirmation before starting. A
checked-in repo `symphony.yml` contains setup and audit data only; direct daemon runs still need
local runtime setup for tracker scope, workspace roots, runner commands, and host settings.

Shared cloud/team run setup import is intentionally deferred. Today, operator defaults and saved run
setups are local files under `~/.config/symphony`; future shared import must compose with repo setup
under the same rule that launch-time setup can restrict but not weaken repo-owned policy.

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

The preferred `symphony.yml` file is a thin YAML repo setup manifest that selects Symphony-owned
workflow modules. The manifest compiles into the policy/config fragment and prompt shape consumed by
the daemon, while local runtime setup supplies active targets and host settings.
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
`setup check` also validates that `project.repository` is a GitHub repository URL and that
`delivery.pr_target` is explicitly set; `setup preview` shows the resolved publish target as
`owner/repo:branch`.

The `default` profile is compiled from manifest delivery, validation, and automation fields.
`delivery.pr_target` is the only v1 delivery selector: use `main` for normal mainline PRs, or a
non-main branch such as `project/integration` when work should open PRs against a project integration
branch. v1 does not automate promotion from a non-main target back to `main` after restart or
landing.

Notes:

- If a value is missing, defaults are used unless a selected workflow module documents a stricter
  validation requirement, such as the default GitHub PR publish target checks.
- `capabilities.required` declares runner capability names the repo needs without selecting a
  concrete runner, model, sandbox, or command.
- `issue_markers.labels` and `issue_markers.allowed_projects` declare durable issue markers for
  preview and policy checks. They do not select the active Linear polling target.
- Runtime `tracker.required_labels` remains available in local config or run setup. When set, an
  issue must have every configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace.
- Runtime `target.issue_ids` limits dispatch to explicit Linear issue identifiers or internal IDs.
  Runtime `target.filter` supplies a Linear-native issue filter object for query targets.
- `delivery.pr_target` names the Git PR target/base branch. Additional profiles may override the
  compiled `default` profile during effective-policy resolution.
- Profile overrides replace scalar, list, and map fields by default. Use `append_<field>` for list
  additions and `add_<field>` for map additions. The resolved policy includes a stable
  `policy_ref` short hash. Replacement fields are applied before additive directives when both
  appear in the same profile.
- Linear run target is runtime setup, not repo setup. Prefer `runtime.target`; legacy
  `runtime.tracker.project_id`, `runtime.tracker.project_slug`, `runtime.tracker.team_key`, and
  `runtime.tracker.issue_ids` remain as compatibility fallbacks only:

```yaml
runtime:
  target:
    tracker: linear
    type: project
    project_slug: my-linear-project-slug
```

- Supported Linear target types are `project`, `team`, `query`, and `issues`. Query targets use a
  Linear-native issue filter object under `runtime.target.filter`; explicit issue targets use
  `runtime.target.issue_ids`. Team and query targets require repo `issue_markers.labels` or
  `issue_markers.allowed_projects`, and marker filters are intersected with project, team, and query
  targets. Explicit issue targets keep mismatched issues but return preview warnings.
- Workflow profiles do not choose which Linear issues are polled. `--profile` is a process-wide
  override for policy selection; otherwise the `default` profile is used.
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
- Unattended Codex defaults are used when runner policy fields are omitted:
  - `runtime.agent.default_runner` defaults to `codex`
  - `runtime.agent.max_concurrent_startups` defaults to `2`
  - `runtime.runners.codex.approval_policy` defaults to `never`
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
- `runtime.runners.codex.approval_policy` controls Codex host action approvals for command execution
  and file changes; it is separate from the model deciding that an issue needs a human/product
  decision and updating the workpad or issue state. Symphony rejects `on-request` string and
  object-form approval policies even when the targeted Codex app-server version supports them,
  because unattended agents cannot service host action approval prompts. Other string or object-form
  values depend on the targeted Codex app-server version; legacy object-form `reject` is not accepted
  by Codex CLI 0.128.0.
- Supported `runtime.runners.codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `runtime.runners.codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `runtime.runners.codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- Elixir/Phoenix validation that starts Mix/Phoenix PubSub also needs localhost TCP listen
  capability. Keep the normal implementation profile restricted, and add an explicit trusted-local
  profile in local config or a saved run setup for validation or host-owned delivery:

```yaml
runtime:
  profiles:
    default:
      delivery:
        pr_target: main
    trusted_local:
      capabilities:
        required:
          - localhost_tcp
          - git_metadata
          - github_pr
      runners:
        codex:
          turn_sandbox_policy:
            type: workspaceWrite
            writableRoots:
              - /path/to/workspace/root
            readOnlyAccess:
              type: fullAccess
            networkAccess: true
            excludeTmpdirEnvVar: false
            excludeSlashTmp: false
```

  Select it for a trusted local run with `--profile trusted_local`. Symphony preflights declared
  capabilities before the implementation turn starts: Codex turn-sandbox or worker localhost TCP
  denial routes `sandbox_tcp_denied`, Git or jj metadata/fetch denial routes `git_metadata_denied`,
  and missing GitHub repository/base-branch API access or publish permission routes
  `github_publish_unavailable`. This is narrower than making `dangerFullAccess` the global default
  because only the named local runtime profile expands the Codex turn sandbox and only runs that
  declare the capability names are blocked by these checks.
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
  `workflow.config.product_visual_review` to adjust product/design QA prompts and durable handoff
  route evidence. When selected without explicit config, it defaults to `enabled: true`. Set
  `enabled: false` to disable it, choose `project_kind: web | mobile | desktop`, and use
  `route_policy: auto | required | recommended | off`. In `auto`, Symphony classifies the final
  validated changed-file manifest against configured `changed_file_triggers` and issue labels,
  records whether visual QA was required, recommended, skipped, or blocked, and keeps durable
  screenshot/media links plus interaction, responsive-state, and product/design notes in the
  handoff route. Local temp/file paths are rejected instead of being exposed as dashboard/API
  artifact links.
- Use `runtime.hooks.after_create` to bootstrap a fresh workspace. Prefer `jj git clone ... .` so
  Codex turns run in jj-native workspaces and do not need to write Git metadata directly. Use
  `git clone ... .` only for repos that cannot run under jj compatibility.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch the
  project dependencies in `runtime.hooks.after_create` before invoking `mise` later from other hooks.
- `runtime.tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is
  `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `runtime.workspace.root` resolves `$VAR` before path
  handling. `runtime.runners.<name>.command` is an argv list, so use explicit argv elements rather
  than shell expansion in the command field.

```yaml
runtime:
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
  config warnings, stale sessions, runtime, token usage, and tracker availability
- A primary project status table for the configured tracker project plus runtime project rows
- Running session detail with issue state, profile/target, runtime, last Codex update,
  copyable session ID, and token split
- Handoff route detail with completion route, target state, product visual review evidence, and
  durable artifact references
- Tracker-limited status in the dashboard, terminal status, and `/api/v1/state` when Linear
  rate-limits GraphQL reads; `tracker.status = "tracker_rate_limited"` means Symphony is
  preserving running work and pausing new tracker reads until the recorded backoff expires
- Optional Admin details for runtime metadata and rate-limit diagnostics only when upstream
  runtime rate-limit data is present
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `../symphony.yml`: root dogfood repo setup manifest used by CLI `setup check`/`preview`
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
