# Logging Best Practices

This guide defines logging conventions for Symphony so Codex can diagnose failures quickly.

## Goals

- Make logs searchable by issue and session.
- Capture enough execution context to identify root cause without reruns.
- Keep messages stable so dashboards/alerts are reliable.

## Required Context Fields

When logging issue-related work, include both identifiers:

- `issue_id`: Linear internal UUID (stable foreign key).
- `issue_identifier`: human ticket key (for example `MT-620`).

When logging Codex execution lifecycle events, include:

- `session_id`: combined Codex thread/turn identifier.

When an issue can exist under more than one registry target, include:

- `target_id`: registry target identity.
- `admitted_run_id`: durable run identity.

The stable identity is `target_id / issue_identifier / admitted_run_id`. Do not log an issue
identifier alone when it can refer to more than one target.

## Message Design

- Use explicit `key=value` pairs in message text for high-signal fields.
- Prefer deterministic wording for recurring lifecycle events.
- Include the action outcome (`completed`, `failed`, `retrying`) and the reason/error when available.
- Avoid logging large payloads unless required for debugging.

## Scheduler Status Records

`Scheduler host status` and `Scheduler target status` use the same projection as the dashboard and
`GET /api/v1/state`.

The host record includes queue count and host agent, startup, reviewer, and poll capacity.
Each target record includes target ID, configured/effective state, eligibility reason, queue count,
weight/deficit, target capacity, reserved and charged token use, tracker backoff, runtime counts, and
safe durable run identities.

Do not add raw policy, credentials, secret references, prompts, or transition evidence to this
projection or to scheduler log text.

## Scope Guidance

- `AgentRunner`: log start/completion/failure with issue context, plus `session_id` when known.
- `Orchestrator`: log dispatch, retry, terminal/non-active transitions, and worker exits with issue context. Include `session_id` whenever running-entry data has it.
- `AgentRuntime.CodexAppServer`: log session start/completion/error with issue context and `session_id`.
- `SchedulerStatus`: log host and target projections after a dashboard or API snapshot. Use only
  fields from the credential-safe scheduler projection.

## Checklist For New Logs

- Is this event tied to a Linear issue? Include `issue_id` and `issue_identifier`.
- Is this event tied to a Codex session? Include `session_id`.
- Is the failure reason present and concise?
- Is the message format consistent with existing lifecycle logs?
- For overlapping issue identity, are `target_id` and `admitted_run_id` present?
- Does the record omit raw policy, credentials, secret references, prompts, and transition evidence?
