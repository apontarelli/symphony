# Incident-Triggered Linear Issues

Symphony Elixir includes a bounded prototype for turning project-owned production failure signals
into Linear issues. The prototype is an explicit operator or monitoring-integration command; it is
not part of the orchestrator polling loop and it does not automatically change production posture.

## Supported Signal Sources

The first supported `signal_source` values are:

- `github_actions`
- `sentry`
- `posthog`
- `project_webhook`

Project-specific monitoring owns source configuration, alert thresholds, authentication, payload
delivery, and any source-specific normalization before calling Symphony. Symphony owns only the
shared payload contract, issue body formatting, bounded duplicate suppression, and Linear issue
creation after explicit project opt-in.

## Payload Contract

The JSON payload must be an object with these fields:

- `title`: short issue title without severity prefix
- `severity`: one of `critical`, `high`, `medium`, or `low`
- `affected_project`: Linear project slug that should receive the issue
- `signal_source`: one of the supported source values
- `evidence_links`: non-empty list of nonblank URL or source-reference strings
- `reproduction`: concise reproduction notes or operator-visible failure path
- `diagnostics`: diagnostic notes from the monitor or script
- `suggested_owner`: suggested human or team owner
- `suggested_agent_route`: suggested route before any agent pickup

Optional fields:

- `source_id`: source-native event, run, alert, or incident identifier string
- `fingerprint`: preferred correlation key string when the source provides a stable fingerprint

Example:

```json
{
  "title": "Checkout deploy is returning 500s",
  "severity": "critical",
  "affected_project": "checkout-web",
  "signal_source": "github_actions",
  "source_id": "run-123",
  "fingerprint": "deploy-main-500",
  "evidence_links": ["https://github.com/acme/checkout/actions/runs/123"],
  "reproduction": "Open /checkout after deploy.",
  "diagnostics": "Smoke test failed after release 2026.06.06.",
  "suggested_owner": "web-platform",
  "suggested_agent_route": "ticket/production-incident"
}
```

## Dry-Run

Dry-run is the default and does not call Linear:

```bash
mix incident.linear_issue --payload /path/to/signal.json
```

The command prints the target project, target state, labels, correlation key, and full Linear issue
body for manual inspection.

## Create Mode

Create mode requires explicit project opt-in:

```bash
mix incident.linear_issue \
  --payload /path/to/signal.json \
  --workflow /path/to/symphony.yml \
  --create \
  --acknowledge-project-opt-in
```

The default target state is `Backlog`. `Todo` is the only supported `--state` override, and create
mode rejects terminal target states. Use `--state Todo` only when the target project intentionally
wants newly created incident issues to enter an active dispatch state. Labels default to:

- `incident`
- `production-failure`
- `source:<signal_source>`
- `severity:<severity>`

Use `--labels incident,production-failure,<project-label>` to replace the base labels while keeping
the source and severity labels. Create mode requires the target project to resolve to exactly one
Linear team, and it requires the target state and every target label to already exist in Linear.
Missing state, label, or single-team metadata fails the command instead of silently creating
unlabelled or misrouted active work.

## Duplicate Suppression

Every issue body includes a hidden correlation marker derived from:

1. `fingerprint`, when present
2. `source_id`, when present
3. normalized title as a fallback

Create mode scans at most the 50 most recently updated issues in the target project for the same
marker before creating new work. Programmatic callers can lower the candidate limit with a positive
integer, but values above 50 are capped at 50. A match suppresses creation and reports the existing
issue. This is bounded correlation, not a global incident database.

## Ownership Boundary

Project monitoring belongs with the project that owns the production surface. That includes GitHub
Actions workflows, Sentry/PostHog alert configuration, webhook hosting, source credentials, and
threshold decisions.

Symphony orchestration begins after a normalized signal is handed to this prototype. No production
posture-changing automation ships through this path unless the project explicitly opts into create
mode and chooses states/labels that route the resulting Linear issue.
