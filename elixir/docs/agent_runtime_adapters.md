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
  server exit, remote rejection, descendant cleanup, isolated config overlays, inherited environment,
  secret references, authentication failures, and unattended permission handling.
- OpenCode exposes the Symphony capability posture (`linear_graphql`, continuation turns, and
  explicit unattended permissions) through `OpenCodeServer.capabilities/1`. The adapter does not
  enable remote execution or the generic stall watchdog.

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
