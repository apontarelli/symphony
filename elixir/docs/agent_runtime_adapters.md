# AgentRuntime Adapter Planning

This document records production adapter planning for the Elixir implementation.
[`../SPEC.md`](../../SPEC.md) owns the generic `AgentRuntime` contract; this file records the
current adapter decision and the first implementation wave that follows the runner-agnostic Codex
work closed by SID-344.

## Current Posture

- Codex app-server and local OpenCode server are production adapters; Codex remains the dogfood
  default.
- `SymphonyElixir.Config.Schema` accepts `codex_app_server` and `opencode_server` runner kinds.
- `SymphonyElixir.AgentRuntime` selects start, turn, stop, and capability callbacks from
  `runtime.agent.default_runner` and its runner `kind`.
- `opencode_server` is local-worker only. Remote selection fails before launch with
  `{:unsupported_remote_runner, "opencode_server", worker_host}`.
- SID-382 closed runner schema and dispatch. SID-383 added the local HTTP lifecycle, normalized
  events, blocking/timeout handling, and fake-server contract coverage.

## Decision

OpenCode is the next approved production adapter target.

Rationale:

- OpenCode has documented programmatic interfaces that can support an unattended adapter:
  `opencode run` for non-interactive prompts, `opencode serve` for a headless HTTP/OpenAPI server,
  and `opencode acp` for a JSON-RPC stdio protocol.
- The headless server surface exposes session, message, permission, abort, diff, health, event, and
  dispose operations, which maps better to Symphony's long-running worker model than a single
  command invocation.
- OpenCode's permission model is explicit (`allow`, `ask`, `deny`) and can be configured through
  project or injected config, giving Symphony a concrete surface for unattended policy mapping.
- OpenCode reads project `AGENTS.md`, so it preserves the repo-grounded instruction model Symphony
  already relies on.

Oh My Pi remains deferred. There is no checked-in runtime contract, executable protocol, auth model,
or operator value statement in this repository comparable to the OpenCode surfaces above. Revisit it
after the OpenCode adapter proves the second-runtime path or after a concrete Oh My Pi protocol doc
exists.

Reference sources for the OpenCode assessment:

- https://opencode.ai/docs/cli/
- https://opencode.ai/docs/server/
- https://opencode.ai/docs/acp/
- https://opencode.ai/docs/permissions/
- https://opencode.ai/docs/config/

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
  assistant failures, process exits, permission requests, and question requests. Native payloads
  remain in `Event.native` and are preserved in blocked orchestration evidence.
- Fake-server coverage for startup, continuation, tools, failures, operator input, timeout/abort,
  server exit, remote rejection, and descendant cleanup.
- No Symphony-provided client-side tools for OpenCode. Codex's `linear_graphql` integration remains
  Codex-specific.

## Remaining Runtime Contract Gaps

The unattended hardening wave still needs to:

- Create a Symphony-owned OpenCode config overlay without replacing the target workspace cwd.
  Worker machines still provide the `opencode` executable and provider credentials.
- Resolve environment-backed server auth, fail clearly when configured secrets are absent, and map
  provider authentication failures to stable blocked evidence.
- Inject an explicit unattended permission policy so normal runs avoid `ask`; unresolved permission
  and question requests already map to normalized `blocked` events.
- Consume OpenCode SSE progress before enabling the generic stall watchdog. Until then, synchronous
  OpenCode turns are governed by `turn_timeout_ms`; `stall_timeout_ms` remains schema-compatible but
  is not enforced for this adapter because no trustworthy in-turn progress signal is available.

Remote workers remain intentionally unsupported until Symphony can either tunnel the HTTP server
over SSH or use an stdio protocol such as ACP.

## Launch And Auth Assumptions
- The adapter appends `--hostname` and `--port` to configured command argv. In automatic mode,
  Symphony reserves an available concrete loopback port before launch and confirms it from the
  startup banner.
- The adapter accepts loopback hosts only. Static ports are suitable for local development; automatic
  ports avoid collisions across concurrent issue runs. Startup waits for the launched process's
  bound-port banner before health checks, so it cannot attach to a stale daemon on a configured port.
- Direct `server_auth.password` values enable server Basic auth;
  `server_auth.username` is optional and defaults to `opencode`. When auth is omitted, the adapter
  clears inherited OpenCode server-auth variables. Environment references and missing-secret
  handling belong to the unattended hardening wave.
- `OPENCODE_CONFIG_DIR`, `OPENCODE_CONFIG`, or `OPENCODE_CONFIG_CONTENT` must be isolated per run.
  The current adapter does not apply the staged config overlay fields yet and never writes
  operator-global OpenCode config.
- Provider credentials remain host-owned. Missing provider auth is currently a turn failure; the
  hardening wave will normalize it to `auth_missing` or `blocked`.
- Unresolved permission or question requests are polled during each turn, normalized to `blocked`,
  aborted, and returned as an error.

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

- Run one OpenCode server process per active Symphony worker run unless a later design proves safe
  server sharing.
- Keep the OpenCode server alive across continuation turns for the same issue so session context is
  preserved.
- Observe only response parts and pending permission/question requests for the session owned by the
  worker run; do not let one issue consume another issue's signals.
- On timeout, call the OpenCode abort endpoint when a session/message is active, then stop the
  supervised process.
- On normal completion, dispose the OpenCode instance if supported, then stop the supervised process
  and rely on `ProcessSupervisor` for descendant cleanup.
- Startup is complete only after health and session creation succeed. A started OS process without a
  usable OpenCode session is still startup failure.
- First-wave production support is local-worker only unless SSH port forwarding or ACP stdio support
  is implemented in the same change.

## Implementation Wave

The schema/dispatch and local adapter issues are implemented. The remaining wave hardens unattended
config isolation, permissions, authentication, and operator docs before any dogfood default switch.
Keep the dogfood default runner on Codex until that hardening passes its live smoke path.
