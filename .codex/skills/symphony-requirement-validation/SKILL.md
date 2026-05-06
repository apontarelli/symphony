---
name: symphony-requirement-validation
description:
  Validate a Linear Requirement issue after its blocking implementation tickets
  are terminal. Use for issues labeled `Requirement`; verify outcome evidence
  before marking requirements done.
---

# Symphony Requirement Validation

Use this skill for Linear issues labeled `Requirement`.

Requirement issues are product/design validation artifacts. They are not
implementation tickets.

## Preconditions

- Current issue has label `Requirement`.
- Current issue is in `In Review`.
- Supporting implementation issues block this Requirement in Linear.
- All blocking implementation issues are terminal.

If any blocker is non-terminal, update the `## Codex Workpad` with the blocker
list and stop without changing code or moving the Requirement to `Done`.

If the Requirement has no blocking implementation issues but appears to have
supporting implementation work, treat that as a setup defect: record the missing
`blocks` relationship in the workpad and do not silently validate from prose
links alone.

## Workflow

1. Fetch the Requirement issue, its project, blocking implementation issues, and
   linked PRs or attachments.
2. Read the Linear Project PDR enough to understand project intent.
3. Reconcile the Requirement body:
   - Outcome
   - Acceptance Criteria
   - Measurement / Signal
   - Non-Goals
   - Dependencies
   - Validation Evidence
4. Inspect implementation evidence:
   - implementation issue workpads,
   - merged PRs,
   - tests and CI,
   - screenshots or manual QA notes,
   - docs or operator workflow updates when relevant.
5. Run only validation needed to prove the Requirement outcome.
6. Update the Requirement's `Validation Evidence` with concrete proof.
7. Move the Requirement to `Done` only when acceptance criteria are met.

## Failure Modes

- Evidence missing: keep or move to `In Review`, record exact missing evidence.
- Acceptance not met: move to `Rework` or leave in `In Review` with a concise
  workpad note, then create/identify follow-up implementation work.
- Scope changed: update the Requirement or Project PDR before validating a new
  interpretation.
- Deferred or dropped: require explicit reason before moving to `Canceled` or a
  project-defined deferred state.

## Guardrails

- Do not implement product code for a Requirement validation ticket.
- Do not open a normal feature PR for validation-only work.
- Do not treat merged implementation PRs as sufficient evidence by themselves.
- Do not invent new requirements; update the Requirement issue first when scope
  changes.
- Keep progress in the single `## Codex Workpad` comment.

## Output

Report:

- Requirement verdict: `validated`, `missing_evidence`, `not_satisfied`,
  `blocked`, or `deferred`.
- Evidence recorded.
- State transition made, if any.
- Follow-up issues created or linked, if any.
