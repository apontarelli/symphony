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

Codex app-server and local `opencode serve` are production adapters. Codex remains the dogfood
default; OpenCode is local-worker only and does not yet receive Symphony's client-side
`linear_graphql` tool. Adapter boundaries and remaining hardening are recorded in
[`docs/agent_runtime_adapters.md`](docs/agent_runtime_adapters.md).

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
   - For existing mixed manifests, run `./bin/symphony setup migrate --repo /path/to/repo --name <run-name>`
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
mise exec -- ./bin/symphony run --workflow /path/to/local-symphony-runtime.yml
```

From a checkout, the repository also provides a higher-level shell launcher at `../bin/symphony`.
It keeps local shell glue in this repo instead of dotfiles, resolves local runtime setup files,
optionally loads `~/.config/symphony/.env` through `op run`, compiles the application, and launches
the CLI through Mix so native dependencies remain loadable.

For first-run local use, invoke bare `symphony` from a repository with a valid `symphony.yml`.
The launcher opens a picker showing saved `default`, then `main`, then other saved workflows,
followed by the recent unsaved `current` entry, plus “Create new workflow”.

```bash
export LINEAR_API_KEY=...
../bin/symphony
../bin/symphony run main --preview --no-env-file
../bin/symphony run main --no-env-file
../bin/symphony run SID-123 SID-124 --repo /path/to/repo --preview --no-env-file
../bin/symphony run SID-426 --repo /path/to/repo --preview --max-agents 1 --max-startups 1 --no-land --human-review-only --no-env-file
```

Creating a workflow writes `~/.config/symphony/config.yml` if missing, using
`~/dev/symphony-workspaces` as the default workspace root and `light`, `normal`, and `swarm`
capacity profiles. Saved names are lowercase slugs and live at
`~/.config/symphony/runs/<name>.yml`; saving fails rather than overwriting an existing name.
Explicit issue IDs use issue-batch mode with a limit of one by default. Explicit issue and
interactive local runs accept `--max-agents`, `--max-startups`, `--no-land`, and
`--human-review-only`. These options can only reduce selected capacity or add safety restrictions.
Phase 3 self-dogfood must use explicit issue batches with
`--max-agents 1 --max-startups 1 --no-land --human-review-only`; do not use a saved watch target.
Retain the resolved preview, run ID
and startup owner, post-restart control-plane inspection, repository validation output, and final
handoff route with the child issue. For an interrupted-run case, stop the Symphony host, restart the
same explicit batch, and confirm that the old fencing generation is stale before the retry starts.
If process ownership, credentials, or a delivery outcome cannot be verified, leave the run blocked
and use `control-plane inspect`, `resume`, or `abandon`; do not replay the external action.

Use `symphony list` for read-only catalog inspection:

```bash
../bin/symphony list --repo /path/to/repo --no-env-file
```

`symphony run <saved-name> --preview` is the canonical non-starting preflight. It composes repo
setup, local operator config, and the saved workflow; prints the resolved target, mode, capacity,
runner, safety/landing posture, provenance, eligible states, and offline tracker status; and does
not create config, materialize a runtime manifest, contact Linear, or start the daemon. Without
`--preview`, Symphony prints the same preview and asks for confirmation unless `--yes` is passed.

Explicit runtime files are a start-only escape hatch:

```bash
export LINEAR_API_KEY=...
../bin/symphony run --no-env-file --workflow /path/to/local-symphony-runtime.yml
```

Use the launcher env file when you want the 1Password CLI to resolve `op://` secret references:

```bash
mkdir -p ~/.config/symphony
cp ../symphony.env.example ~/.config/symphony/.env
../bin/symphony
../bin/symphony run main
```

To make `symphony` available as a shell command, put the repository `bin/` directory on `PATH` or
symlink `../bin/symphony` into a directory already on `PATH`.

## Target registry authoring and lifecycle

Operators can author and control local host target registry entries with these commands:

```text
symphony host run [--registry <path>]
symphony host target add <id> --input <target.yml> [--registry <path>] [--json]
symphony host target add <id> --confirm <plan-id> [--registry <path>] [--json]
symphony host target import <id> --workflow <path> --repo <path> [--connection <id>] [--runner <source>=<id>] [--registry <path>] [--json]
symphony host target import <id> --confirm <plan-id> [--registry <path>] [--json]
symphony host target plan <id> --patch <target-patch.yml> [--registry <path>] [--json]
symphony host target patch <id> --confirm <plan-id> [--registry <path>] [--json]
symphony host target activate <id> [--mode <watch|explicit>] [--registry <path>] [--json]
symphony host target activate <id> --confirm <plan-id> [--registry <path>] [--json]
symphony host target pause <id> [--registry <path>] [--json]
symphony host target pause <id> --confirm <plan-id> [--registry <path>] [--json]
symphony host target drain <id> [--registry <path>] [--json]
symphony host target drain <id> --confirm <plan-id> [--registry <path>] [--json]
symphony host target retire <id> [--registry <path>] [--json]
symphony host target retire <id> --confirm <plan-id> [--registry <path>] [--json]
```

The default registry is `~/.config/symphony/targets.yml`, with private plan envelopes in the
sibling `target-plans/` directory. `--registry` selects another local registry and its sibling plan
directory. Preview commands do not mutate the registry and emit deterministic, redacted text;
`--json` emits machine-readable output and errors.

For a dedicated single-repository Linear Project target, repository identity comes from the project
binding and the target may omit required labels and repository issue markers. Team and query/file
targets require nonempty issue markers. A project shared by multiple repositories must use separate
targets per repository or explicit marker policy; do not activate one unmarked target across the
mixed project. Planning, implementation, and closeout workflows add execution labels only when the
selected target policy requires them.

After this change is merged, save and start the unlabeled Symphony project target:

1. From the Symphony repository root, run `symphony`.
2. Select `Create new workflow`, `Linear project`, the `Symphony` project with slug `symphony`,
   `watch` mode, and the required capacity. Save the workflow as `main`. Do not add a required
   label.
3. Run `symphony run main --preview --no-env-file`. Confirm the target is project `symphony` and
   required labels are `none`.
4. Run `symphony run main --no-env-file` to confirm and start it, or add `--yes` for unattended
   activation. Do not change an issue state or merge a pull request as part of this activation.

Confirmation requires the exact generated plan ID. It rebinds the action, target, and registry and
validates bound sources and the registry generation before replacement. Stale, corrupt, or
mismatched plans, and a locked registry, do not write. Registry replacement is atomic and writes
deterministic YAML; plan consumption happens afterward. If post-commit verification or plan
consumption fails, confirmation can report an error after the registry has changed, so inspect the
registry before retrying.

Add and import always create paused targets with no dispatch mode. Import reads the source runtime
and repository without modifying either; the current committed repository manifest remains
authoritative. Patch input is a target-only recursive schema patch, not JSON Patch or JSON Merge
Patch, and general patch operations cannot change lifecycle state or dispatch mode.

Activation requires `explicit` or `watch` dispatch mode and reuses an existing valid mode when
`--mode` is omitted. The lifecycle graph is `paused -> active`, `active -> draining`,
`active|draining -> paused`, and `paused -> retired`. Retired is terminal: it cannot reactivate or
accept general patches. A configured active state does not bypass registry validation or enable
dispatch by itself.

`symphony host run` reads and composes one registry generation, resolves each valid target into an
immutable `TargetContext`, and starts one target orchestrator for every active or draining target.
Only active targets receive new grants. The default registry is used when `--registry` is omitted.
If a later reload fails, the daemon keeps the last verified generation visible but blocks new grants
until it can verify the current file generation again.

## Execution context isolation (Phase 2)

Every accepted run now pins one immutable `TargetContext` and one issue-specific
`ExecutionContext`. Tracker resolution, workspace paths and hooks, compiled prompts and modules,
runner and model selection, capability preflight, quality checks, publish and handoff policy,
tracker writes, retry state, and cleanup use that pinned authority. Reloading the selected workflow
or changing process-global configuration affects later admissions only.

Active-run identity is `{target_id, issue_id}`. Two targets can therefore retain overlapping Linear
issue IDs and identifiers without sharing tracker cache entries, workspaces, runtime events, retry
state, review records, publish decisions, handoff evidence, or cleanup. Safe status projections
include target ID, registry generation, and policy hash, but do not include credentials or raw policy
data.

The public `symphony run <saved-name>`, `symphony run --workflow <path>`, and explicit-issue
commands are single-target admission forms. They build the canonical `TargetContext`, start its
orchestrator under `SymphonyElixir.TargetSupervisor`, and register that target with
`SymphonyElixir.HostScheduler`. Preview, restrictive overrides, issue-batch, watch, and drain
semantics remain target-scoped and unchanged.

`HostScheduler` owns registry reload, poll timing, weighted-deficit credit and cursor state, and host
and target agent, startup, reviewer, runner, and poll counts. It binds each poll grant to one target
process and the exact verified registry generation. One current grant can reserve at most one
dispatch attempt, and an agent does not start until the durable target budget reservation is
confirmed. The target orchestrator retains issue lifecycle, Linear-state capacity checks, runtime
events, retries, quality, delivery, and fenced side effects. Grant release is idempotent across
dispatch rejection, startup failure, worker exit, cancellation, and lease loss.

Weighted dispatch uses stable target ID order and positive integer target weights. Saved credit is
capped at `weight * max_credit_rounds`. A continuously eligible target receives a grant within
`max_credit_rounds * sum(all configured target weights)` successful grant decisions after host
capacity becomes available. Draining targets receive only grants for pinned durable retry work.
Paused, retired, invalid, stale-generation, rate-limited, and policy-denied targets receive no
grant.

Tracker rate-limit backoff is keyed by registry tracker connection. Targets that share a connection
share its backoff; targets on another connection remain eligible. Active-run identity remains
`{target_id, issue_id}`, so overlapping tracker issue IDs stay distinct in admissions, leases,
workspaces, reservations, retries, artifacts, and status.
Registry lifecycle changes apply to the existing target orchestrator. Pause invalidates pending
polls and grants first, terminates only a verified owned process group, records `target_paused`, and
releases claims, slots, reservations, and leases after fenced stop evidence. Unverifiable ownership
leaves stop-dependent resources fenced and does not signal the uncertain process. Activation
reacquires each paused admission's lease and token reservation from its pinned context before the
scheduler enables new candidate polling.

The host scheduler projection is shared by the dashboard, `GET /api/v1/state`, and stable
`Scheduler host status` / `Scheduler target status` log records. It reports each target's
configured/effective state, eligibility reason, queue count, scheduling weight and deficit,
host/target capacity use, durable token reservation and charged use, tracker backoff, and
running/retrying/blocked counts. Durable run identities use
`target_id / issue_identifier / admitted_run_id`, so overlapping identifiers remain distinct.
The projection omits raw policy, credentials, secret references, prompts, and transition evidence.


For each runtime dispatch, the orchestrator commits the pinned admission and acquires its durable
lease before it resolves current credentials or revalidates tracker state. It renews the lease every
10 seconds, records the adapter process identity before the first turn, and persists running,
retrying, blocked, completion, and cleanup transitions. Publish preflight, publish handoff,
handoff-route tracker writes, and workspace cleanup start only through the current fenced side-effect
intent. Startup recovery fences the prior owner, verifies or terminates its recorded process group,
releases the target-scoped coordinator lease, and retries from the pinned admission.

The Phase 3 crash/restart contract is
`test/symphony_elixir/control_plane_test.exs` test
`two-target crash recovery preserves pinned authority and fenced side effects`. It admits two
targets with one tracker issue identity, interrupts both while they own processes, poisons mutable
registry and workflow files, rotates or removes recovery credentials, and reopens the durable store.
The test proves deterministic retry and blocked recovery, stale-owner rejection, no replay of an
interrupted delivery intent, idempotent recovered delivery, target-scoped artifacts, and fenced
cleanup.

The multi-repository system contract is
`test/symphony_elixir/multi_repository_system_test.exs`. It creates and commits two independent
repository manifests, clones both repositories into separate project-bound workspace roots, and
runs their distinct validation commands through different runners and landing routes. Both runs
overlap under one host ceiling. One target is blocked and resumed while the other stays active.
The test then restarts the control plane and verifies target-scoped admission, policy, budget,
handoff, terminal completion, and workspace-cleanup evidence:

```bash
mix test test/symphony_elixir/multi_repository_system_test.exs
```

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
generated prompt files into the target repo. The legacy `workflow` command has been removed; use
`setup init`, `setup check`, and `setup preview`.

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
`30000`, 30-day terminal control-plane retention, Codex app-server runner defaults, and capacity
profiles:

- `light`: 1 agent / 1 startup
- `normal`: 4 agents / 1 startup
- `swarm`: 10 agents / 2 startups

Deployment ceilings default to 10 agents and 2 startups. A saved run setup may choose a named
profile or an explicit capacity map, but the resolved capacity cannot exceed those ceilings.

The runtime owns a local SQLite control-plane store at
`~/.config/symphony/control-plane.sqlite3` (or the selected `SYMPHONY_CONFIG_ROOT` /
`--config-root`). Startup creates and migrates the schema in one transaction, enables WAL mode,
uses a bounded five-second busy timeout, and runs SQLite and schema health checks. The config root
is mode `0700`; the database and SQLite auxiliary files are mode `0600`. An unsupported schema,
failed migration, corrupt database, or unusable root stops runtime startup with the database path
and failure reason. Preview and list commands do not start the runtime or create this database.

The store retains immutable target generations and issue-specific admissions keyed by target ID
and tracker issue ID. Each admission receives one immutable run ID and pins its registry, policy,
manifest, issue, workspace, runner/model, check, delivery-gate, and provenance authority. Repeated
admission of the same envelope returns the original run ID; changed hashes or authority conflict
without replacement. Only validated tracker and runner secret references are stored. Credential
values resolve only after a fenced owner acquires the run.

Admission also reserves the run's full remaining per-run token ceiling against the target's UTC
admission day and ISO week. Daily and weekly checks run inside the same immediate transaction, so
concurrent admissions cannot overdraw either balance. Runtime usage writes carry the current lease
and fencing token and store only the monotonic cumulative token total. Charged usage increases while
the unused reservation decreases, which keeps active allocation constant and makes duplicate or
out-of-order reports idempotent. Terminal completion retains charged usage and releases unused
capacity. Lease or explicit reservation release requires verified process-stop evidence; a later
running transition must reacquire the remaining ceiling. Reservations, charged totals, and balances
survive restart and backup restore without storing raw runtime payloads.

Each admitted run has one exclusive durable lease. A lease lasts 30 seconds and the owner should
renew it every 10 seconds. Acquire, renew, transfer, release, and expiry use immediate SQLite
transactions. Every new owner receives a fencing token greater than all prior tokens for that run;
the current owner ID and token are required for renew, transfer, and release. A lease expires at its
exact stored deadline. A backward wall-clock change of at most one second is tolerated without
shortening the lease; larger clock changes and clock or store failures fail closed. Target-scoped
runs lease independently when tracker issue IDs overlap.

Each admission also owns an authoritative durable lifecycle: admitted, running, retrying, blocked,
completed, cleanup pending, and cleaned. A transition atomically updates current state and appends
its evidence to immutable history. Each mutation names the observed state and sequence, so a stale
observation cannot mutate a later cycle that returned to the same state. New transitions require
the current owner and fencing token. Retry attempt, durable due time, normalized failure, blocked
reason, completion disposition, and pinned cleanup authority survive reopen. Exact completion and
cleanup duplicates remain idempotent after later transitions or lease release when their original
owner, token, sequence, and evidence match. Illegal, conflicting duplicate, stale-token, and
out-of-order transitions leave both records unchanged. Completed, cleanup-pending, and cleaned
timestamps provide later retention boundaries.
Delivery and cleanup calls can use the same control plane as a fenced side-effect seam. Before a
tracker write, publish preflight, publish handoff, handoff-route record, or workspace cleanup starts,
the current lease records a target-scoped intent with a stable idempotency key and derived artifact
path. Known success and failure outcomes are idempotent. A pending intent found after interruption
or an explicitly ambiguous external result becomes reconciliation-required and is not replayed
automatically. Intent and outcome evidence is secret-redacted. New intents also enforce the pinned
delivery gates; cleanup requires cleanup-pending lifecycle authority.

Local process-group ownership is stored with its lease token. Transfer, release, and later
acquisition remain blocked until that process group has a verified stopped result. An unverifiable
termination blocks a running or retrying lifecycle for operator reconciliation.

On restart, `ControlPlane.recover_runs/3` loads admitted, running, retrying, blocked, and
cleanup-pending rows in deterministic admission order. It issues the startup owner a new fencing
token before process inspection, so the old owner can no longer renew or mutate. A process group is
terminated only when its stored leader PID, group ID, wrapper PID, and OS start identity match the
live leader. A missing or mismatched identity blocks that run without signaling the uncertain
process. Verified interrupted running work becomes an immediate durable `host_restart` retry;
existing retry deadlines, blocked reasons, completion disposition, and cleanup authority are
restored unchanged.

Recovery resolves current credentials only from the pinned admission references after fencing.
Missing credentials block only the affected run. Resolved values are returned in memory for admitted
or retrying work and are omitted from durable state and recovery inspection output. Recovered
dispatch and retry policy comes from the pinned admission, not the mutable workflow or target
registry.

Operators can inspect the same credential-safe durable run projection through
`symphony control-plane inspect`, `GET /api/v1/control-plane/runs`, the dashboard durable
control-plane table, and structured `control_plane_snapshot` debug logs. The projection includes
target and issue identity, lifecycle state and sequence, current owner and lease expiry, fencing
generation, retry timing, blocked reason, and reconciliation status. It omits pinned policy,
execution context, credentials, and raw transition evidence.

Scheduler inspection uses the same redaction boundary. `GET /api/v1/state` returns a `scheduler`
object with host capacity and target rows. `GET /api/v1/<issue_identifier>` returns
`409 ambiguous_issue` when more than one target has the identifier; add
`?target_id=<target-id>` to select the durable run.

The production terminal client reads `GET /api/v1/operator/snapshot` and
`GET /api/v1/operator/events?host_id=<host-id>&after=<cursor>`. The snapshot is a complete
versioned replacement with host identity, registry generation, freshness, aggregate and target
capacity, ordered pending queues, durable run stage, landing and cleanup state, warnings, and
host-owned command availability. Missing, stale, partial, timed-out, and unavailable sources remain
explicit.

The event feed returns ordered structured runtime events and redacted host logs. Cursors increase
within one host identity. A host identity change, a cursor before retained history, or a cursor ahead
of the host returns `snapshot_replacement.required = true`; clients must discard domain state and
fetch a complete snapshot. Retention and per-response truncation are separate metadata. The
interface omits credentials, credential references, raw runtime payloads, and prompts.
`snapshot_invalidated` means that a snapshot-owning process changed; fetch another complete
snapshot rather than reconstructing domain state from logs. Aggregate capacity uses host limits,
not the sum of target limits. A stale or missing queue makes overall freshness partial.
Known raw runtime output is tagged `operator_payload: :unsafe` by its producer. The operator
log handler omits these bodies and OTP report bodies while preserving level and source; normal
host log text passes through the shared credential and multiline-prompt redaction boundary.

Operator mutations use `POST /api/v1/operator/commands/preview` followed by
`POST /api/v1/operator/commands/confirm`. Both require a loopback connection and
`Authorization: Bearer <operator-session-token>`. The host creates a new session credential on
each interface start. `OperatorInterface.credentials/0` returns local launcher metadata containing
the host ID and token file path, not the token value. The file is
`<config-root>/.credentials/operator/<host-id>/token`, with mode `0600` inside `0700`
credential directories. It is not part of the HTTP snapshot. Insecure paths fail closed.
The interface resolves this root once at startup: an explicit interface `config_root`, then the
selected control-plane root (`--config-root` or registry `host.state_root`), then the local config
root. Credentials and pruning policy use this same root; HTTP transport options cannot replace it.

Settings clients use `POST /api/v1/operator/settings/choices` with the same loopback and
bearer-token requirements. This is a read-only request; it does not create a preview or
change configuration. Its optional inputs are `target_id`, an explicit `repository` path,
and `selections`, a map from catalog field paths to draft values:

```json
{
  "target_id": "alpha",
  "selections": {
    "state": "paused",
    "runners.allowed": ["codex"],
    "runners.default": "codex",
    "checks.pre_dispatch": ["capability_preflight", "repo_validation"]
  }
}
```

The response includes interface and schema versions, host identity, registry generation,
and `fields`. Each field declares `cardinality` (`scalar` or `list`), its `selected` value,
`valid`, and choices with `value`, `selected`, `status`, and a stable `reason` code.
Choice status is `available`, `current` (selected and available), `unavailable`, `stale`,
or `invalid`. Scalar fields accept one value; list fields accept an array. Omitted draft
fields retain configured target values where available. Wildcard paths such as
`runners.*.kind` describe schema choices, not a particular configured runner.

Catalogs come from schema-owned enums, validated host runner and tracker definitions,
local capacity profiles, and repository-compatible saved workflows. Repository profiles
and workflow modules require a known repository; the service does not discover repositories
or query Linear. Runner entries include their kind, but not commands or credentials.
OMP thinking and permission choices apply to `omp_acp` runners.
Loopback hostname choices apply to `opencode_server` runners. Target runner settings expose
their schema-owned reasoning-effort choices; provider-defined model names are not finite catalogs.

Clients must keep their draft selections when they request fresh choices. Removed selections
remain visible with `selection_removed`; incompatible definitions carry explicit reason codes.
`invalid_cardinality` and `default_runner_not_allowed` block invalid drafts. A registry file
that differs from the scheduler generation reports `registry_stale` and blocks Apply.
`apply_blocked` and `errors` describe catalog constraints only: an unblocked catalog is not
authorization to mutate. Apply still requires the existing validated preview and exact
confirmation flow.

A preview request contains exactly these fields:

```json
{
  "interface_version": 1,
  "host_id": "<host ID from snapshot>",
  "registry_generation": "<generation from snapshot>",
  "command": {
    "action": "activate",
    "target_id": "alpha",
    "inputs": {"dispatch_mode": "explicit"}
  }
}
```

Supported commands:

| Action | Identity field | Inputs |
| --- | --- | --- |
| `activate` | `target_id` | `{"dispatch_mode":"explicit"}` or `{"dispatch_mode":"watch"}` |
| `pause`, `drain`, `retire` | `target_id` | `{}` |
| `patch` | `target_id` | `{"changes":{...}}`, using `OperatorCommandService` patch fields |
| `resume_run`, `abandon_run` | `run_id` | `{}` |
| `refresh`, `shutdown`, `prune` | none | `{}` |

The host returns affected identity, current and proposed state, consequences, warnings,
`disabled_reason`, `confirmation_token`, and `expires_at`. A disabled preview has no token.
Confirmation submits the exact original request plus `confirmation_token`; it does not submit
an edited preview. Tokens expire after 60 seconds and are single-use. They bind the session,
host identity, registry generation, action, target or run identity, and exact inputs. Run recovery
also checks the durable lifecycle and fencing generation. Target changes use the registry
service's compare-and-swap commit. Navigation, snapshot reads, and disconnects never confirm.

Confirmation returns `202` with a command `id` and `status: "accepted"`. This is not proof of
completion. Observe `command_result` events and the snapshot's `command_results` collection for
`completed`, `rejected`, or `failed`. The snapshot retains the latest result for up to 100 command
IDs; the event feed retains transitions within its normal bounded history. Every result invalidates
the snapshot. Errors include a stable code, `state_may_have_changed`, `snapshot_required`, and the
next safe action. A failed operation can have committed a registry change or acquired a lease;
fetch a complete snapshot before requesting another preview. Never retry an old token.

`refresh` reloads the registry and requests tracker polling and reconciliation. `shutdown` is
disabled until all targets are paused, draining, or retired and tracked work is empty. Confirmation
atomically prevents new grants and then requests host shutdown. The command remains `accepted`
until shutdown initiation succeeds or fails. A `completed` result means initiation succeeded, not
that an offline host acknowledged exit. Initiation failure produces `failed`, never an earlier
`completed` result for the same command.

The old HTTP resume, abandon, prune, and refresh routes return
`410 operator_confirmation_required`; they cannot bypass session authorization. Read routes and
local CLI automation remain available. Browser mutation controls must use the new contract before
they can be enabled.

`symphony control-plane resume <run-id>` and `abandon <run-id>` first return a confirmation token
bound to the current lifecycle sequence and fencing generation. Supplying that token with
`--confirm` and `--owner` acquires a new lease before the mutation; active leases, changed state,
running process ownership, and unresolved side-effect reconciliation fail closed. The HTTP
equivalents are `resume_run` and `abandon_run` through the authenticated operator command contract.
The HTTP host supplies the run owner; clients cannot choose one.

`control_plane.terminal_retention_days` defaults to `30` and must be a positive integer.
`symphony control-plane prune` and the operator API's `prune` command return a preview token before
deleting anything. HTTP retention comes from host configuration, not client inputs.
Confirmation recomputes eligibility, then atomically removes only old completed
or cleaned runs. Blocked and other nonterminal runs, active leases, uncertain process ownership,
pending or reconciliation-required side effects, and runs linked to durable publish-handoff or
handoff-route artifacts are preserved.


Saved run setups live at `~/.config/symphony/runs/<lowercase-slug>.yml`. Names may contain lowercase
letters, digits, and interior dashes; collisions fail without overwriting. A setup stores the target
repo reference, tracker target, mode, capacity, and restrictive flags such as required labels; app
repositories are not used as saved run setup storage.

Run setup target examples:

```yaml
repo:
  path: /path/to/repo
target:
  type: project
  tracker:
    project_slug: symphony
mode: watch
capacity: normal
```

```yaml
repo:
  path: /path/to/repo
target:
  type: team
  tracker:
    team_key: SID
mode: watch
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
mode: watch
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
./bin/symphony setup migrate --repo /path/to/repo --name my-project
./bin/symphony setup migrate --repo /path/to/repo --name my-project --apply
```

`setup migrate` is an offline compatibility reader. It does not supply runtime authority and is not
called after admission.

Preview a saved workflow before side effects. Explicit local runtime paths are start-only:

```bash
./bin/symphony run my-project --preview
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
evidence is otherwise sufficient. `auto_land.force_human_review_paths` is a list of
repository-relative path patterns. `*` matches within one path segment and `**` matches across path
segments. If a host-verified changed file matches a configured pattern, Symphony routes the complete
change to `Human Review`. A semantic change to the `auto_land` section is also protected. A change
elsewhere in `symphony.yml` is not protected when the host proves that the effective `auto_land`
policy is unchanged. Missing or inconsistent host changed-file evidence blocks auto-land.

`auto_land.dry_run` defaults to `true`, so Symphony classifies and records an auto-land decision
without merging. Setting `auto_land.dry_run: false` opts into guarded real auto-land. After an
implementation worker completes, the host validates its evidence, publishes and links the pull
request, and moves eligible work to `Merging`. That state causes a fresh, dedicated landing worker to
revalidate checks, reviews, sync state, and mergeability before merge. An implementation worker does
not publish its own branch or pull request and cannot enter the landing flow by changing issue state
during its session; the prompt's dispatch-time `Current status` must already be `Merging`.

Symphony uses three separate delivery terms:

- **Publication** is the host-owned creation or update of the deterministic `ticket/<issue-id>`
  branch and its pull request after implementation evidence passes.
- **Landing** is a dedicated `:landing` execution role. It operates only on that existing pull
  request and branch after the issue enters `Merging`.
- **Branch cleanup** removes stale remote state after a terminal outcome. Routine `Rework` keeps the
  same deterministic branch and pull request. GitHub's `deleteBranchOnMerge` setting removes merged
  branches. For a terminal closed-unmerged pull request, the host deletes the deterministic branch
  only after GitHub returns the exact repository and head ref and confirms that no matching pull
  request is open or merged. An already absent branch is a successful cleanup result.

Implementation and review worker processes do not receive the standard GitHub token or SSH
authentication environment. Symphony also disables interactive Git authentication and credential
helpers for those roles. The landing role receives delivery authentication and is the only worker
role permitted to make the remote writes needed for the existing pull request. Host-side delivery
gates remain authoritative for publication and terminal branch cleanup.

For protected changes, a human authorizes landing by moving the Linear issue from `Human Review` to
`Merging`. The host then dispatches the same dedicated landing flow. The project remains responsible
for deployment, rollback evidence, monitoring signals, and incident intake.

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

Historical review-record backfill is an offline artifact conversion. It does not participate in
runtime compatibility or execution authority.

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

- Manifest issue markers narrow an already selected target; they are not a substitute for target
  scope. A dedicated single-repository project target can leave both `issue_markers.labels` and
  `issue_markers.allowed_projects` empty. Team and query/file targets require at least one marker.
  A project shared by multiple repositories must use separate targets or explicit repository
  markers. Dispatch fails closed when a broad target has no markers.
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
- `opencode_server` launches a supervised localhost `opencode serve` process, waits for health,
  creates and reuses a session, submits prompts, maps messages/tools/failures/blocking requests into
  normalized runtime events, aborts timed-out turns, and disposes the server during stop. Remote
  OpenCode workers fail before launch. Each run receives a unique `OPENCODE_CONFIG_DIR` overlay under
  the issue workspace; Symphony never mutates `~/.config/opencode` or the target workspace config.
  On Darwin and Linux, every local runner gets a verified isolated process group owned by the
  worker lifecycle. Stop sends TERM to the group, waits 150 ms, then sends KILL to survivors.
  Worker/startup failure uses the same cleanup path. Unsupported hosts or missing local `sh`, `ps`,
  or `kill` tools fail before launch; Linux also requires `setsid -f -w`. Adopted SSH ports remain
  port-only cleanup.
  The overlay injects an explicit noninteractive permission policy (`permissions`, default deny) and
  is removed during stop. Its schema supports `model`, `agent`, `hostname`, automatic or static
  `port`, `config_dir`, `config_path`, string/map `config_content`, `server_auth`, `permissions`,
  `execution_profiles`, `max_concurrent_startups`, and startup/turn/read/stall timeouts.
  `server_auth.password` accepts direct local-test values or an exact `env:VAR_NAME` reference;
  references resolve only at launch and missing values return `auth_missing`. Basic auth is sent only
  to the launched loopback server. OpenCode advertises the `linear_graphql` Symphony capability and
  continuation turns; unresolved permissions/questions become blocked evidence. Each active turn
  subscribes to `GET /global/event` before prompt submission. Only owned assistant/message/tool
  activity refreshes the generic stall watchdog; health checks, blocker polls, heartbeats, unrelated
  events, and raw process output do not. `turn_timeout_ms` remains the hard turn deadline.
- `omp_acp` launches `omp --no-extensions --no-skills acp` through the same owned process-group
  lifecycle and speaks stable ACP protocol version `1` over stdio. It requires an operator-owned
  named `profile`, an explicit `provider/model`, a thinking selector such as `high`, and a pinned
  `permissions` map. An optional exact `version` selects a validated runtime compatibility contract.
  OMP versions `18.0.11` and `18.1.5` support token telemetry through a Symphony-owned explicit
  extension using OMP's typed `message_end` and assistant `Usage` contracts. The extension writes
  atomic Symphony schema `1` cumulative usage beside the private OMP session, not in the checkout;
  Symphony does not parse OMP transcripts. Missing and other OMP versions expose token usage as
  `unavailable`, and
  capability preflight blocks them when a token budget is configured. Global extension and skill
  discovery remains disabled while repository `AGENTS.md` rules remain active. Each run gets a
  mode-`0700` OMP session directory outside the checkout at
  `<workspace.root>/.symphony/omp_sessions/<issue>-<session>`, a new process, and a new ACP identity.
  It removes `LINEAR_API_KEY` from the OMP child environment. A per-session loopback HTTP MCP bridge
  uses a random bearer token and exposes only `linear_graphql`; Symphony retains and uses the Linear
  credential. Permission policy resolves exact ACP tool kinds before `"*"` and permits only
  one-request approvals. Denied, blocked, missing, or unsupported permissions and interactive
  questions become actionable blocked evidence. Native ACP data, normalized events, errors, usage,
  and results redact secret keys, labeled secrets, and the exact bridge token. Recovery fences the
  recorded process group and always creates a fresh ACP session; it never reattaches. Unsupported ACP
  versions or required requests, malformed messages, timeouts, stalls, and process exits fail closed.
  See [`docs/agent_runtime_adapters.md`](docs/agent_runtime_adapters.md) for configuration, live-smoke
  commands, recovery, event mapping, and token accounting.
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
- `runtime.runners.codex.execution_profiles` covers the production-selected implementation and
  landing workloads plus six reviewer/runtime QA workloads: `source_reviewer`, `test_reviewer`,
  `runtime_qa`, `product_visual_review`, `docs_reviewer`, and `security_reviewer`. The `landing`
  profile is selected only for `Merging`; every other top-level active state uses `implementation`.
  Each profile supports typed reasoning, timeout, retry, budget, model, or command settings. Planning
  remains in the implementation session, and quality-gate synthesis is host-owned Elixir rather
  than a launched Codex profile. `runtime.runners.codex.model` is the default launch model. Profile
  `model` values
  override it for that launch, and explicit model flags already present in
  `runtime.runners.codex.command` control the command unchanged. Operators do not need to rewrite
  the argv list for normal profile tuning.
  The bundled default uses GPT-5.6 Sol for implementation and source, visual, and security review;
  GPT-5.6 Terra for test review and runtime QA; and GPT-5.6 Luna for docs review. Supported Codex
  reasoning efforts are `none`, `low`, `medium`, `high`, `xhigh`, and `max`; the bundled profiles
  preserve their pre-5.6 effort levels.
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
  The compiled prompt keeps a stable outcome-first prefix—role, goal, success criteria, autonomy
  boundaries, and output contract—while module bodies contain the detailed workflow invariants.
  Resolution versions and policy hashes remain recorded without repeating module metadata inside
  the agent-facing prompt.
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
- Durably admitted work persists its resolved policy in the pinned execution context. Restart
  recovery uses that context; later workflow, profile, and target-registry changes apply only to new
  admissions.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/operator/snapshot`, `/api/v1/operator/events`,
  `/api/v1/<issue_identifier>`, and `/api/v1/operator/commands/{preview,confirm}`. Add
  `?target_id=<target-id>` to the issue route when registry targets overlap.

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
- Host scheduler cards for target state and eligibility, queue pressure, weight/deficit,
  host/target capacity, durable token budgets, tracker backoff, and running/retrying/blocked counts
- Safe durable run identity as `target / issue / admitted run`, including duplicate issue
  identifiers under different targets
- Empty, active, limited, paused, draining, and blocked target states with responsive narrow and
  wide layouts
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
- `docs/agent_runtime_adapters.md`: production `AgentRuntime` adapter planning and OpenCode scope
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
