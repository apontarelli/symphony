# AgentRuntime Adapters

This document records production adapter planning for the Elixir implementation.
[`../SPEC.md`](../../SPEC.md) owns the generic `AgentRuntime` contract; this file records the
current adapter decision and the first implementation wave that follows the runner-agnostic Codex
work closed by SID-344.

## Current Posture

- Codex app-server, local OpenCode server, and local Oh My Pi ACP are production adapters; Codex
  remains the default.
- `SymphonyElixir.Config.Schema` accepts `codex_app_server`, `opencode_server`, and `omp_acp`
  runner kinds.
- `SymphonyElixir.AgentRuntime` selects the adapter from a validated `ExecutionContext`, and each
  session retains that exact runner, profile, model, worker, timeout, and policy snapshot.
- Runtime adapters expose context-only start, turn, stop, and capability entry points. Adapter
  selection never returns to `runtime.agent.default_runner` after admission.
- `opencode_server` and `omp_acp` are local-worker only. Remote selection fails before launch.
- SID-382 and SID-383 established OpenCode schema, lifecycle, event mapping, and contract coverage.
  SID-452 added the OMP ACP v1 transport and its authenticated Linear tool bridge.

## Adapter Decisions

OpenCode uses `opencode serve` over loopback HTTP. Its native session, permission, event, and
dispose APIs fit Symphony's long-running worker lifecycle.

Oh My Pi uses `omp acp` over newline-delimited JSON-RPC on stdio. Symphony implements the stable
ACP protocol version `1` directly and keeps the adapter private instead of adding a generic ACP
framework. Reference protocol and implementation sources:

- https://agentclientprotocol.com/
- https://github.com/agentclientprotocol/agent-client-protocol
- https://github.com/can1357/oh-my-pi
- https://opencode.ai/docs/server/
- https://opencode.ai/docs/permissions/

## OMP ACP Runner

An `omp_acp` runner requires an operator-owned named OMP profile, an explicit `provider/model`
selector, an explicit thinking selector, and a pinned permission map. Keep profile credentials in
OMP. Workflow and target state contain only the profile name.

```yaml
runtime:
  agent:
    default_runner: omp
  runners:
    omp:
      kind: omp_acp
      version: "18.1.5"
      profile: symphony
      model: openai/gpt-5.6-sol
      thinking: high
      permissions:
        "*": block
        read: allow
        edit: allow
        execute: deny
```

The command defaults to `["omp", "--no-extensions", "--no-skills", "acp"]`. Custom commands must
contain both isolation flags. OMP therefore does not discover global extensions or skills.
Symphony does not pass `--no-rules`; OMP still loads repository `AGENTS.md` rules from the canonical
workspace.

`version` pins the OMP runtime contract. Symphony supports billable token telemetry only for
explicitly validated versions; the current supported versions are `18.0.11` and `18.1.5`. For
those versions, Symphony adds its own `--extension` path while `--no-extensions` continues to
disable ambient discovery. The extension consumes OMP's typed `message_end` and assistant `Usage`
contracts and
atomically publishes Symphony schema `1` cumulative input, output, and total counts in the
session directory. Symphony never parses OMP's native transcript. Other or missing versions report
token usage as `unavailable`; a configured token budget blocks in capability preflight because it
cannot be enforced.

Before activation, create and authenticate the named OMP profile outside the repository. Symphony
sets `OMP_PROFILE` to the configured reference. It stores each run in a mode-`0700` directory below
`<workspace-root>/.symphony/omp_sessions/<issue>-<session>` and never writes runner state into the
checkout. Concurrent runs have separate directories, OMP processes, and ACP session identities.
`LINEAR_API_KEY` is removed from the OMP child environment.

Each adapter session owns one `omp acp` process group, one ACP session, and one loopback HTTP MCP
bridge. The bridge binds only to `127.0.0.1` on an ephemeral port and requires a random bearer token.
It exposes only `linear_graphql` and delegates calls to Symphony's host-owned `tool_executor`.
The bearer token is passed as an ACP MCP-server header; the Linear credential remains inside
Symphony.

Startup performs ACP `initialize`, requires protocol version `1` and HTTP MCP support, creates a
new session with the canonical workspace, and sets the pinned `model` and `thinking` configuration
options. Continuation turns reuse that live ACP session. Symphony does not persist ACP resume data.
Recovery verifies and terminates the recorded process group before it creates a new OMP process and
ACP session. An unverifiable process identity blocks recovery instead of reattaching.

ACP permission requests use the pinned runner `permissions` map. The exact ACP tool kind takes
precedence over `"*"`. `allow` selects only an `allow_once` option. `deny` selects only
`reject_once`, emits `blocked`, cancels the prompt, and fails the turn. `block`, a missing policy,
or an unavailable one-time option returns a cancelled permission response and the same fail-closed
lifecycle. Symphony never selects `allow_always` or `reject_always`.

OMP ACP assistant chunks become `message_delta`; reasoning, plans, configuration, mode, session, and
legacy ACP usage updates become `turn_progress`; tool calls and terminal tool updates become
`tool_call` and `tool_result`; prompt stop reasons become `turn_completed` or `turn_failed`.
Supported versioned telemetry is attached as cumulative usage to normalized events. Orchestration
deduplicates repeated absolute totals and charges OMP's authoritative `totalTokens`, which already
includes cache read/write and provider orchestration tokens. Questions, `session/request_input`, and
elicitation requests emit actionable `blocked` evidence and fail the turn. Other unknown required
requests, malformed messages, unsupported protocol versions, stalls, timeouts, and process exits
also fail closed.

Before an OMP event or turn result leaves the adapter, the shared redaction policy removes
secret-bearing map values, labeled bearer or credential strings, and the exact per-session MCP
token. This applies to native ACP envelopes, normalized payloads, usage, reasons, startup errors,
and returned native results. Stop requests `session/close`, then terminates the owned process group
and loopback bridge.

Run the installed-runtime smoke after the profile is authenticated:

```bash
SYMPHONY_OMP_VERSION=18.1.5 \
SYMPHONY_OMP_PROFILE=symphony \
SYMPHONY_OMP_MODEL=openai/gpt-5.6-sol \
SYMPHONY_OMP_THINKING=high \
make -C elixir omp-live
```

The smoke creates a temporary repository rule, starts the real installed `omp acp`, completes one
model turn, verifies the rule marker and ACP usage, and verifies process cleanup. If ACP reports an
unknown model, refresh the isolated profile catalog with
`omp --profile symphony --no-extensions models refresh`, then list exact selectors with
`omp --profile symphony --no-extensions models openai --json`. Do not place tokens, API keys, or
profile database content in workflow files or test output.

## Selected OpenCode Surface

The production adapter targets `opencode serve` over localhost HTTP.

Use `opencode run` only for smoke tests or diagnostics. It is useful for single prompt execution but
does not expose enough session and permission lifecycle surface for Symphony's normal continuation,
blocked, and stop semantics. Keep `opencode acp` as a future option if remote execution needs a stdio
transport.

## Completed Implementation

The OpenCode waves established:

- The `opencode_server` config schema for required command argv; optional model and agent selectors;
  hostname and automatic or static port allocation; config directory, path, or content overlays;
  server basic auth; permissions; execution profiles; per-runner startup limits; and startup, turn,
  read, and stall timeouts. Defaults are loopback hostname, automatic port allocation, empty
  permissions and execution profiles, 30-second startup/read timeouts, a 5-minute stall timeout,
  and a 1-hour turn timeout.
- A local `opencode serve` lifecycle: append loopback host and port flags, launch through
  `ProcessSupervisor`, wait for `/global/health`, create one session, reuse it across turns, abort on
  timeout or blocking requests, delete the session, dispose the instance, and stop the process.
- Response mapping for assistant text, native tool parts, cumulative runner-neutral token/cost usage,
  assistant failures, process exits, permission requests, and question requests. During an active
  turn, the adapter subscribes to OpenCode's `GET /global/event` SSE stream before sending the
  synchronous message request. Matching-workspace `message.updated` events for the owned assistant
  message, its `message.part.updated` text/reasoning/tool/step/retry/patch events, and owned-session
  retry status become normalized `turn_progress` events. Native envelopes remain in `Event.native`;
  orchestration status uses the redaction-safe normalized payload.
- Fake-server coverage includes streamed progress, progress floods, startup, continuation, tools,
  failures, operator input, timeout/abort, server exit, remote rejection, descendant cleanup,
  isolated config overlays, inherited environment, secret references, authentication failures, and
  unattended permission handling.
- OpenCode exposes the Symphony capability posture (`linear_graphql`, continuation turns, and
  explicit unattended permissions) through `OpenCodeServer.capabilities/1`. The adapter does not
  enable remote execution.

## Unattended Hardening

- Every run gets a unique `OPENCODE_CONFIG_DIR` below the issue workspace. `config_content` or
  `config_path` is rendered to that overlay as `opencode.json`; the adapter never writes
  `~/.config/opencode` and concurrent runs do not share an overlay.
- The overlay contains the configured `permissions` map, or `* => deny` when no policy is
  supplied. Pending permission and question requests are not answered automatically. They are
  emitted as `blocked` evidence, the session is aborted, and the turn returns an error.
- `server_auth.password` may use exactly `env:VAR_NAME`. Symphony resolves the reference at launch,
  passes the value only to the launched server/client path, and returns `{:auth_missing, VAR_NAME}`
  when it is absent. The reference and resolved value are not persisted in the overlay or logs.
  Basic authorization is sent only to the loopback server launched for that run.
- The child environment is controlled. Symphony forwards the execution path, locale, terminal,
  temporary directory, home, and supported provider credential variables; unrelated inherited
  variables are not forwarded.
- Provider HTTP 401 responses become stable `auth_missing` blocked evidence. Codex remains the
  dogfood default until the guarded live OpenCode smoke path is available.
- The generic stall watchdog is enabled for OpenCode. Only owned assistant/message/tool events from
  `GET /global/event` refresh stall activity. Server heartbeat/connection events, health checks,
  permission/question polling, arbitrary process stdout, malformed envelopes, and other sessions or
  workspaces do not count as progress. Stream connection/protocol failure fails the active turn
  instead of silently disabling stall protection. Event and stdout drains are bounded so completion,
  blocker polling, and turn deadlines remain authoritative.

Remote workers remain intentionally unsupported until Symphony can either tunnel the HTTP server
over SSH or use an stdio protocol such as ACP.

## Launch And Auth Assumptions
- The adapter appends `--hostname` and `--port` to configured command argv. In automatic mode,
  Symphony reserves an available concrete loopback port before launch and confirms it from the
  startup banner.
- The adapter accepts loopback hosts only. Static ports are suitable for local development; automatic
  ports avoid collisions across concurrent issue runs. Startup waits for the launched process's
  bound-port banner before health checks, so it cannot attach to a stale daemon on a configured port.
- `server_auth.password` direct values are retained for local tests; unattended deployments use
  `env:VAR_NAME`. When auth is omitted, inherited OpenCode server-auth variables are cleared.
- Provider credentials remain host-owned and are passed through only for the supported provider key
  allowlist. Missing provider auth returns stable `auth_missing` blocked evidence.
- Unresolved permission or question requests are polled during each turn, normalized to `blocked`,
  aborted, and returned as an error.

Example unattended runner:

```yaml
runtime:
  runners:
    opencode:
      kind: opencode_server
      command: ["opencode", "serve"]
      server_auth:
        username: symphony
        password: env:OPENCODE_SERVER_PASSWORD
      permissions:
        "*": deny
        read: allow
        edit: allow
```

Keep `env:OPENCODE_SERVER_PASSWORD` as the reference. Do not place the password value in workflow
files, `config_content`, or generated artifacts.

## Event Mapping

The OpenCode adapter translates native server responses and message parts into
`SymphonyElixir.AgentRuntime.Event` values:

| OpenCode signal | Symphony event |
| --- | --- |
| Server health plus session creation succeeds | `session_started` |
| Message submission is accepted for a session | `turn_started` |
| Assistant text or streaming message part | `message_delta` |
| Tool invocation part or event | `tool_call` |
| Tool result part or event | `tool_result` |
| Message completes and the session becomes idle | `turn_completed` |
| Message fails, aborts, server exits, or HTTP/SSE protocol breaks | `turn_failed` |
| Permission request, question request, missing auth, or unsupported required capability | `blocked` |

OpenCode-specific payloads belong in the event `native` field. Per-message OpenCode counters are
accumulated into runner-neutral usage totals before orchestration consumes them.

## Process Lifecycle Constraints

- Run one OpenCode server process group per active Symphony worker run. Local runner argv is passed
  through a fixed Symphony wrapper as positional arguments; runner values are never interpolated
  into shell source.
- On Darwin, the wrapper uses local job control; on Linux, it launches the guarded runner directly
  through `setsid -f -w`. `ProcessSupervisor` releases the runner only after its PID equals its PGID
  and its parent PID equals the live wrapper PID. A lifecycle owner monitors the worker process that
  launched the group.
- Normal stop keeps protocol shutdown first: abort an active turn, delete the OpenCode session,
  dispose the instance, then send TERM to the owned process group. After a bounded 150 ms grace,
  any surviving group receives KILL. The wrapper applies the same escalation to descendants left
  behind when the runner exits.
- Startup failure, worker failure, explicit stop, and orchestrator task termination all converge on
  the same lifecycle owner. Repeated cleanup checks the live wrapper and group-leader parent
  relationship before signaling, so a stale cached PID cannot target a reused unrelated process.
- Process-group launch fails closed with `{:process_group_unsupported, reason}` outside Darwin/Linux
  or when required local `sh`, `ps`, or `kill` tools are unavailable. Linux also requires
  `setsid -f -w`. Adopted ports and SSH-backed launches use `cleanup: :port_only` and do not claim
  local descendant cleanup.
- Keep the OpenCode server alive across continuation turns for the same issue so session context is
  preserved.
- Observe only response parts and pending permission/question requests for the session owned by the
  worker run; do not let one issue consume another issue's signals.
- Startup is complete only after health and session creation succeed. A started OS process without a
  usable OpenCode session is still startup failure.
- First-wave production support is local-worker only unless SSH port forwarding or ACP stdio support
  is implemented in the same change.

## Implementation Wave

The schema/dispatch and local adapter issues are implemented. The remaining wave hardens unattended
config isolation, permissions, authentication, and operator docs before any dogfood default switch.
Keep the dogfood default runner on Codex until that hardening passes its live smoke path.
