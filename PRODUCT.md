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
- [`symphony.yml`](symphony.yml) is this fork's dogfood manifest and an example of manifest shape,
  not a reusable template.
- Linear owns active PDRs, Requirement issues, implementation tickets, acceptance criteria, and
  project closeout state.

## Operator

The primary operator is a technical repository owner running Symphony on repositories they can safely
administer. Operators are expected to own repository docs, validation commands, tracker workflow,
secrets, host permissions, and review or landing policy.

Symphony should help that operator run more work through agents while preserving host-owned control
over workspace boundaries, publishing, quality gates, and handoff decisions.

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

- Bootstrap a target repository by committing a thin `symphony.yml` manifest and validating the
  compiled workflow before running unattended automation.
- Poll Linear for eligible issue work and dispatch bounded concurrent agent sessions.
- Launch the configured coding-agent runtime with Symphony-owned harness isolation, then layer target
  repo instructions and docs after harness policy. The current reference implementation launches
  Codex, but the product direction is runner-agnostic.
- Validate completed work with repo-declared commands and host-owned quality gates.
- Publish reviewable workspace changes under host control and route the result to auto-land,
  human review, product visual review, rework, decision-needed, or blocked handoff.
- Expose current runtime state through structured logs, the optional dashboard, and JSON API
  surfaces.

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
- Manifest and docs inspection that keeps target repo setup obvious and avoids copied workflow
  prompt files.

Public reusable automation remains experimental until these operational surfaces are dependable.

## Boundaries and Non-Goals

- Symphony is not a multi-tenant SaaS control plane.
- Symphony is not a general-purpose workflow engine or distributed job scheduler.
- Symphony does not replace target repo docs, validation commands, design rules, or architecture
  contracts.
- Symphony does not require target repositories to copy generated workflow prompts or install
  private global workflow skills.
- Symphony does not default to production auto-land without explicit repository policy and
  evidence.
- Linear is the current issue-tracker integration. Additional tracker adapters should not outrank
  operator reliability and host-owned write semantics.
