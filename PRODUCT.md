# Product Doctrine

Symphony is prototype automation for trusted engineering environments. It turns tracker work into
isolated coding-agent runs across configurable agent runtimes that can be validated, reviewed,
published, and handed off without making the agent the final authority.

## Source of Truth

This file owns Symphony's product posture, operator promise, prioritization principles, and durable
product boundaries.

- [`SPEC.md`](SPEC.md) owns the language-agnostic service and architecture contract.
- [`README.md`](README.md) is the public repo front door and quickstart.
- [`elixir/README.md`](elixir/README.md) owns setup, configuration, and operation for the Elixir
  reference implementation.
- [`symphony.yml`](symphony.yml) is this fork's pre-cutover dogfood manifest, not a required
  artifact in the approved host-owned configuration model.
- Linear owns active PDRs, Requirement issues, implementation tickets, acceptance criteria, and
  project closeout state.

## Operator

The primary operator is a technical repository owner running Symphony on repositories they can safely
administer. Operators are expected to own repository docs, validation commands, tracker workflow,
secrets, host permissions, and review or landing policy.

Symphony should help that operator run more work through agents while preserving host-owned control
over workspace boundaries, publishing, quality gates, and handoff decisions.

## Configuration Ownership and Domain Language

Approved product direction (2026-09-06): one local host, host-owned Symphony configuration,
explicit single-repository routing, and one terminal-first operator surface. This changes the
product contract; it does not claim the runtime cutover has shipped. Current setup commands still
require the pre-cutover manifest path. The active design and delivery criteria live in
[SID-463](https://linear.app/antonio-pontarelli/issue/SID-463) and its
[terminal operator design](https://linear.app/antonio-pontarelli/document/technical-design-terminal-operator-ux-and-opentui-575d2710661e).

- **Host:** the one local runtime that owns connections, runners, credentials, capacity, and all
  configured targets. A registry is internal storage, not a normal operator selection.
- **Repository:** an execution location with verified identity, validation references, and
  workspace preparation. Existing repository docs, scripts, and CI remain project-owned inputs.
- **Target:** a work selection bound to an explicit repository and execution policy.
- **Run:** one admitted execution with a pinned configuration revision.
- **Profile:** optional reusable policy for targets. Profiles are not required for onboarding
  and do not form inheritance chains.

Symphony-specific repository configuration, automation policy, and target settings live with the
host. Target repositories need no `symphony.yml` or generated Symphony files after cutover.
Store confirmed references to repository commands and docs rather than duplicate their contents.
Keep host configuration revisioned, inspectable, exportable, and backed up without resolved secrets.

Each admitted issue resolves to exactly one repository. Dedicated project bindings need no extra
labels. Broad team, project, and query selections require explicit host-owned routing; missing or
ambiguous routing blocks admission with a reason. Agents do not guess the repository.

Configuration resolves from host defaults through explicit target overrides into a pinned run
configuration. Show inherited values and sources; shared-profile edits preview all affected targets.
Deployment ceilings and explicit safety constraints remain enforced. Changes affect future
admissions, not active runs. Apply saves configuration and creates new targets paused; Activate
requires a separate preview and confirmation.

Legacy manifests and saved setups are explicit import sources, not a second live authority.
Migration previews preserve validation, capabilities, protected paths, review/landing restrictions,
and repository identity. Conflicts or unsupported policy block import rather than weaken it.
Do not delete user repository files automatically.

## Product Promise

Symphony should make autonomous engineering work:

- Isolated: each issue runs in a deterministic per-issue workspace under a configured workspace
  root.
- Repo-grounded: target repositories keep their own docs, commands, domain language, and
  architecture authority.
- Inspectable: operators can see what is running, retrying, blocked, reviewed, published, or handed
  off.
- Evidence-driven: validation, review, publishability, visual QA, and handoff decisions are recorded
  as structured evidence.
- Conservatively automated: agents can propose and execute work, but host-owned policy controls
  publish, review, merge, retry, and blocked routes.

## Core Workflows

- Run `symphony` from any directory to attach to the local host or create host configuration and
  the registry through first-use setup. No normal registry picker or required YAML editing.
- Configure tracker connections and runners, select work and a repository, inspect existing
  validation inputs without executing repository code, and Apply a paused target.
- Preview and confirm activation separately. Explicit issue batches use an existing target policy
  and the same host, not another daemon or saved-workflow format.
- Poll Linear for eligible, unambiguously routed work and dispatch bounded concurrent sessions.
- Launch the selected runtime with Symphony-owned harness isolation and pinned execution policy;
  preserve target repository instructions, documentation, and architecture ownership.
- Validate completed work with confirmed repository commands and host-owned quality gates.
- Publish under host control and route to auto-land, human review, product visual review, rework,
  decision-needed, or blocked handoff according to policy and evidence.
- Monitor actionable blockers, active progress, capacity, and targets from one keyboard-first
  terminal. Drill into runs for meaningful activity, logs, landing, and safe recovery.
- Keep non-interactive commands for automation on the same host-owned contracts, not as competing
  primary operator workflows.

## Execution Isolation Posture

An admitted run owns an immutable target and execution context. All reusable run-path operations
use that context, so workflow reloads and process-global configuration changes affect only later
admissions. Active-run and artifact identity includes the target ID; identical Linear issue IDs or
identifiers under two targets do not share tracker, filesystem, runner, check, delivery, retry,
handoff, or cleanup state.

The current registry-backed implementation starts active or draining targets from one verified
generation and applies host scheduling, capacity, budgets, and fencing. Its saved-workflow and
explicit-runtime launch paths are pre-cutover behavior, not separate product models to preserve.
The approved cutover keeps this execution isolation while moving configuration authority to the host.

## Near-Term Horizon

The near-term product horizon is operator-grade dogfood reliability for trusted repositories before
broader public platform packaging.

Roadmap work should prioritize:

- Runner-agnostic orchestration through a real runner seam, normalized runtime events, and adapter
  contracts for multiple coding-agent runtimes.
- Current-session and recent-event visibility for debugging active runs.
- Stall, retry, continuation, and blocked-state semantics that distinguish real progress from noisy
  tool output.
- Restart durability for retry queues, session metadata, and attempt policy where unattended
  reliability depends on it.
- Host-owned evidence for quality gates, publishability, handoff routing, and retrospective review.
- Host-owned repository setup that uses existing project docs and validation commands without
  requiring Symphony files in target repositories.

Public reusable automation remains experimental until these operational surfaces are dependable.

## Boundaries and Non-Goals

- Symphony is not a multi-tenant SaaS control plane.
- Symphony is not a general-purpose workflow engine or distributed job scheduler.
- Symphony does not replace target repo docs, validation commands, design rules, or architecture
  contracts.
- Symphony does not require target repositories to copy generated workflow prompts or install
  private global workflow skills.
- Symphony does not coordinate one issue across multiple repositories or infer repository routing.
- Symphony does not expose presets, modules, compiled manifests, or saved runtime files as
  competing primary ways to start work.
- Symphony does not default to production auto-land without explicit host-owned repository-specific
  policy and evidence.
- Linear is the current issue-tracker integration. Additional tracker adapters should not outrank
  operator reliability and host-owned write semantics.
