# AgentRuntime Adapter Planning

This document records production adapter planning for the Elixir implementation.
[`../SPEC.md`](../../SPEC.md) owns the generic `AgentRuntime` contract; this file records the
current adapter decision and the first implementation wave that follows the runner-agnostic Codex
work closed by SID-344.

## Current Posture

- Codex app-server is the only production adapter today.
- `SymphonyElixir.Config.Schema` currently accepts only `codex_app_server` runner kinds.
- `SymphonyElixir.AgentRuntime` still exposes convenience functions that delegate directly to
  `AgentRuntime.CodexAppServer`; adapter selection by runner kind is a required next step before a
  second production adapter can run.
- SID-344 intentionally deferred Oh My Pi and OpenCode until the Codex adapter proved the runtime
  boundary.

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

The first production adapter should target `opencode serve` over localhost HTTP.

Use `opencode run` only for smoke tests or diagnostics. It is useful for single prompt execution but
does not expose enough session and permission lifecycle surface for Symphony's normal continuation,
blocked, and stop semantics. Keep `opencode acp` as the fallback investigation path if the HTTP
server cannot provide stable turn completion or event mapping.

## Runtime Contract Gaps

The first OpenCode wave should close these gaps:

- Adapter dispatch: route `AgentRuntime` calls through the selected `runtime.agent.default_runner`
  and runner `kind`, instead of hard-coding Codex.
- Config schema: add an OpenCode runner kind, likely `opencode_server`, with adapter-owned fields
  for command argv, model, agent, hostname, port allocation, config directory/content, server auth,
  and permission policy.
- OpenCode launch isolation: create a Symphony-owned OpenCode config overlay without replacing the
  target workspace cwd. Worker machines still provide the `opencode` executable and provider
  credentials.
- Server lifecycle: allocate a local port, launch `opencode serve`, wait for `/global/health`,
  create a session, submit prompts, consume events, abort on timeout, dispose the instance, and stop
  the supervised process.
- Remote workers: block or explicitly defer remote OpenCode runs until Symphony can either tunnel
  the HTTP server over SSH or use an stdio protocol such as ACP. The current SSH worker path is
  sufficient for stdio app-server traffic, not for host-local HTTP callbacks without extra plumbing.
- Permission and input handling: decide how `ask` maps in unattended mode. The safe default is to
  avoid prompts through injected permissions and map any unresolved permission or question event to a
  normalized `blocked` event.
- Client-side tools: Codex exposes a dynamic `linear_graphql` tool today. OpenCode does not get that
  integration automatically, so the first adapter must either configure an OpenCode MCP/custom-tool
  equivalent or explicitly document that the OpenCode implementation profile starts without
  Symphony-provided client-side tools.
- Contract tests: extend the shared fake-binary adapter contract with a fake OpenCode server covering
  startup readiness, normalized events, permission blocking, timeout/abort, and process cleanup.

## Launch And Auth Assumptions

- The default command should be an argv list similar to
  `["opencode", "serve", "--hostname", "127.0.0.1", "--port", "<allocated>"]`.
- Symphony should allocate the port; static manifest ports are acceptable only for local
  development because concurrent issue runs can collide.
- Bind to `127.0.0.1` by default. Do not expose the server externally unless the manifest opts into
  that and supplies authentication.
- If server auth is enabled, inject `OPENCODE_SERVER_USERNAME` and `OPENCODE_SERVER_PASSWORD` from
  runner config or environment references.
- Prefer `OPENCODE_CONFIG_DIR`, `OPENCODE_CONFIG`, or `OPENCODE_CONFIG_CONTENT` for Symphony-owned
  per-run config. Do not write operator-global OpenCode config during unattended runs.
- Provider credentials remain host-owned. The adapter may rely on OpenCode's existing auth file or
  environment-based provider keys, but missing provider auth must normalize to `auth_missing` or
  `blocked`.
- Set permissions explicitly for unattended work. Avoid `ask` defaults unless the adapter is prepared
  to answer permission requests or convert them to `blocked`.

## Event Mapping

The OpenCode adapter should translate native server events and message parts into
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

OpenCode-specific payloads belong in the event `native` field. Usage metadata should be filled only
when the server exposes reliable token or cost counters.

## Process Lifecycle Constraints

- Run one OpenCode server process per active Symphony worker run unless a later design proves safe
  server sharing.
- Keep the OpenCode server alive across continuation turns for the same issue so session context is
  preserved.
- Subscribe to server events only for the session owned by the worker run; do not let one issue
  consume another issue's events.
- On timeout, call the OpenCode abort endpoint when a session/message is active, then stop the
  supervised process.
- On normal completion, dispose the OpenCode instance if supported, then stop the supervised process
  and rely on `ProcessSupervisor` for descendant cleanup.
- Startup is complete only after health and session creation succeed. A started OS process without a
  usable OpenCode session is still startup failure.
- First-wave production support is local-worker only unless SSH port forwarding or ACP stdio support
  is implemented in the same change.

## Implementation Wave

Create the next implementation wave as normal Linear issues in Backlog:

1. Add OpenCode runner schema and adapter dispatch.
2. Implement a local OpenCode server adapter with normalized events.
3. Harden OpenCode unattended config, permissions, auth, and docs.

Each issue should link back to SID-371 and SID-344. Keep dogfood default runner on Codex until the
OpenCode adapter has fake-server contract coverage and at least one explicit live smoke path.
