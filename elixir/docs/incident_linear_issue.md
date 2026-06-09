# Incident-Triggered Linear Issues

Symphony Elixir includes a bounded intake path for turning project-owned production failure signals
into Linear issues. The intake command is an explicit operator or monitoring-integration entrypoint;
it is not part of the orchestrator polling loop and it does not automatically change production
posture.

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
- `failing_signal`: concise name of the monitor assertion or signal that failed
- `evidence_links`: non-empty list of nonblank URL or source-reference strings
- `source_payload`: source-specific evidence object; required fields are documented below
- `reproduction`: concise reproduction notes or operator-visible failure path
- `diagnostics`: diagnostic notes from the monitor or script
- `suggested_owner`: suggested human or team owner
- `suggested_validation`: concrete validation command, check, or operator action to prove recovery
- `suggested_agent_route`: suggested route before any agent pickup

Optional fields:

- `source_id`: source-native event, run, alert, or incident identifier string
- `fingerprint`: preferred correlation key string when the source provides a stable fingerprint
- `team_key`: Linear team key when the target project has multiple teams or the monitor needs an
  explicit team route

Example:

```json
{
  "title": "Checkout deploy is returning 500s",
  "severity": "critical",
  "affected_project": "checkout-web",
  "signal_source": "github_actions",
  "failing_signal": "deploy smoke check returned HTTP 500",
  "source_id": "run-123",
  "fingerprint": "deploy-main-500",
  "source_payload": {
    "repository": "acme/checkout",
    "workflow": "Deploy",
    "run_id": "123",
    "run_url": "https://github.com/acme/checkout/actions/runs/123"
  },
  "evidence_links": ["https://github.com/acme/checkout/actions/runs/123"],
  "reproduction": "Open /checkout after deploy.",
  "diagnostics": "Smoke test failed after release 2026.06.06.",
  "suggested_owner": "web-platform",
  "suggested_validation": "Rerun deploy smoke checks and verify /checkout returns 200.",
  "suggested_agent_route": "ticket/production-incident"
}
```

## Source Evidence Payloads

`source_payload` is normalized evidence, not a raw provider webhook body. All values must be strings.
Additional string fields are allowed and are copied into the generated issue body, but these fields
are required for each supported source:

| `signal_source` | Required `source_payload` fields |
| --- | --- |
| `github_actions` | `repository`, `workflow`, `run_id`, `run_url` |
| `sentry` | `organization`, `project`, `issue_url`, `event_id` |
| `posthog` | `project`, `alert_name`, `alert_url`, `metric` |
| `project_webhook` | `webhook_name`, `event_id`, `event_url` |

Use `fingerprint` when a source can provide a stable correlation key that survives retries or
renamed alerts. If no fingerprint is present, Symphony falls back to `source_id` and then the
normalized title.

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
wants newly created incident issues to enter an active dispatch state. If the Linear project has
multiple teams, the payload must include `team_key`; otherwise create mode rejects the ambiguous
route instead of guessing. Labels default to:

- `incident`
- `production-failure`
- `source:<signal_source>`
- `severity:<severity>`

Use `--labels incident,production-failure,<project-label>` to replace the base labels while keeping
the source and severity labels. Create mode requires the target project to resolve to exactly one
Linear team unless `team_key` selects a team, and it requires the target state and every target label
to already exist in Linear. The payload `affected_project` must match the selected workflow
`runtime.tracker.project_slug`; create mode rejects a mismatched target before calling Linear.
Missing state, label, or team metadata fails the command instead of silently creating unlabelled or
misrouted active work.

Severity maps to Linear priority during create mode:

| Severity | Linear priority |
| --- | --- |
| `critical` | `1` (`P1 urgent`) |
| `high` | `2` (`P2 high`) |
| `medium` | `3` (`P3 medium`) |
| `low` | `4` (`P4 low`) |

## Duplicate Suppression

Every issue body includes a hidden correlation marker derived from:

1. `fingerprint`, when present
2. `source_id`, when present
3. normalized title as a fallback

Create mode scans at most the 50 most recently updated issues in the target project for the same
marker before creating new work. Programmatic callers can lower the candidate limit with a positive
integer, but values above 50 are capped at 50. A non-terminal match suppresses creation and reports
the existing issue. Terminal matches are treated as stale so recurring failures can create fresh
work. This is bounded correlation, not a global incident database.

## Ownership Boundary

Project monitoring belongs with the project that owns the production surface. That includes GitHub
Actions workflows, Sentry/PostHog alert configuration, webhook hosting, source credentials, and
threshold decisions.

Symphony orchestration begins after a normalized signal is handed to this prototype. No production
posture-changing automation ships through this path unless the project explicitly opts into create
mode and chooses states/labels that route the resulting Linear issue.
