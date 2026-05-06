---
name: symphony-project-closeout
description:
  Complete a PDR Project closeout ticket by verifying requirements, updating
  durable repo docs, creating follow-ups, and summarizing shipped/deferred work.
---

# Symphony Project Closeout

Use this skill for project closeout issues, usually labeled `Project Closeout`.

Project closeout is the bridge from active Linear project work back to durable
repo knowledge.

## Preconditions

- Closeout ticket belongs to a Linear Project.
- Closeout ticket has label `Project Closeout`.
- Requirement issues for the project are `Done`, `Canceled`, or explicitly
  deferred with reason.
- Closeout ticket is blocked by unresolved Requirement issues when possible.

If Requirements are still unresolved, update the workpad with the blocking list
and stop.

If unresolved Requirement issues are present but do not block the closeout
ticket, treat that as a setup defect: record the missing `blocks` relationship
in the workpad before stopping.

## Workflow

1. Fetch the Linear Project PDR, Requirement issues, implementation issues, and
   existing closeout checklist.
2. Verify every Requirement has a final disposition:
   - `Done` with validation evidence,
   - `Canceled` with reason,
   - deferred with linked follow-up.
3. Audit durable docs for shipped behavior:
   - product strategy if priorities, roadmap, audience, or risks changed,
   - architecture docs for boundary or domain changes,
   - runbooks/operator workflow docs for operational changes,
   - README/setup docs when user-facing workflow changed.
4. Make the smallest repo-doc changes needed for durable accuracy.
5. Create follow-up Linear issues for deferred work, known risks, or gaps.
6. Update the closeout issue summary:
   - Shipped
   - Changed
   - Deferred
   - Learned
7. If docs changed, run relevant validation and publish the PR through normal
   Symphony delivery.
8. Move the closeout ticket to `Done` only after requirements and docs are
   reconciled.

## Guardrails

- Do not re-open product scope during closeout unless a Requirement is false.
- Do not use closeout to hide missing validation.
- Do not update strategy for minor ticket-local changes.
- Do not create placeholder follow-ups; every follow-up needs concrete scope and
  acceptance criteria.
- Keep progress in the single `## Codex Workpad` comment.

## Output

Report:

- Closeout verdict: `complete`, `requirements_unresolved`, `docs_updated`,
  `followups_needed`, or `blocked`.
- Requirement disposition summary.
- Durable docs changed, if any.
- Follow-up issues created or linked.
