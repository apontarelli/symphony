# Symphony

Symphony is an experimental service for turning issue-tracker work into isolated,
autonomous coding-agent runs. It polls Linear, creates a per-issue workspace, launches the
configured `AgentRuntime` runner, and records validation, review, publish, and handoff evidence
back to the tracker. The current production adapter targets Codex app-server.

This is my personal, independent public fork of the
[OpenAI Symphony](https://github.com/openai/symphony) prototype. It is not an official OpenAI
distribution. This fork preserves the Apache 2.0 license and OpenAI attribution from the original
project, with fork-specific changes summarized below.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a
Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and
provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos.
When accepted, the agents land the PR safely._

> [!WARNING]
> Symphony is prototype automation for trusted engineering environments. It can run unattended
> agents that execute commands, edit files, create branches or jj bookmarks, open PRs, and update
> Linear issues. Review the manifest and runtime policy before using it on a repository.

## What changed in this fork

This fork keeps the language-agnostic service contract in [`SPEC.md`](SPEC.md) and evolves the
Elixir reference implementation under [`elixir/`](elixir/). Material changes since the upstream
OpenAI project include:

- Manifest-first setup: target repositories commit a thin [`symphony.yml`](symphony.yml) manifest
  with project facts, docs entrypoints, validation commands, VCS mode, delivery target, and selected
  workflow modules.
- Self-contained workflow modules: the default workflow is compiled from bundled modules for
  Linear operation, implementation, pull sync, validation, quality gates, review, publish/handoff,
  landing, rework, requirement validation, project closeout, and run recovery.
- No copied runtime prompt requirement: public runtime behavior no longer depends on target repos
  copying `WORKFLOW.md` files or globally installing private `symphony-*` skills.
- Runner-agnostic runtime seam: unattended runs dispatch through an `AgentRuntime` adapter. The
  current production adapter uses a Symphony-owned Codex `CODEX_HOME` and then layers target-repo
  `AGENTS.md` and docs after the harness instructions.
- Repo setup inspection commands: the Elixir CLI can initialize, validate, and preview compiled
  setup policy with `setup init`, `setup check`, and `setup preview --compiled`. The legacy
  `workflow` command remains as a one-release compatibility alias with deprecation guidance.
- Host-owned quality gates: completed implementation turns can fan out deterministic reviewer jobs
  for source correctness, tests, scenario QA, product visual review, docs alignment, and risky
  security/data/migration seams, then synthesize findings before handoff.
- Publish and handoff evidence: completed workspaces are checked for publishability, pushed under a
  deterministic branch or jj bookmark, attached to a GitHub PR, and routed with structured handoff
  evidence.
- Dashboard and observability: the Elixir app can expose a Phoenix LiveView dashboard and JSON API
  for running, retrying, blocked, token-usage, and handoff-route state.
- Product visual review routing: the optional `product_visual_review` workflow module can require
  or recommend visual QA evidence for UI-facing diffs.

## Current architecture

Product posture and prioritization live in [`PRODUCT.md`](PRODUCT.md). The durable architecture
contract lives in [`SPEC.md`](SPEC.md). The current implementation is the Elixir/OTP service in
[`elixir/`](elixir/), with local setup and commands documented in [`elixir/README.md`](elixir/README.md).

The root [`symphony.yml`](symphony.yml) is this fork's dogfood repo setup manifest. It intentionally
contains durable repository facts, validation, delivery policy, required capabilities, and selected
workflow module configuration. Local Linear target scope, workspace roots, runner commands, polling,
and host runtime settings belong in local config or run setup instead of the checked-in manifest.

## Run the Elixir implementation

```bash
git clone https://github.com/apontarelli/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
```

Create a manifest for a target repository, then inspect it before starting unattended runs:

```bash
mise exec -- ./bin/symphony setup init --repo /path/to/target-repo
mise exec -- ./bin/symphony setup check --repo /path/to/target-repo
mise exec -- ./bin/symphony setup preview --repo /path/to/target-repo --compiled
```

For local solo runs, use `symphony run` to build or load a saved local run setup instead of
hand-writing runtime YAML. First use creates `~/.config/symphony/config.yml` with operator defaults
such as workspace root, capacity profiles, deployment ceilings, polling, and runner settings. Saved
named setups live under `~/.config/symphony/runs/<name>.yml`.

```bash
export LINEAR_API_KEY=...
../bin/symphony run --repo /path/to/target-repo --no-env-file --dry-run
../bin/symphony run SID-123 SID-124 --repo /path/to/target-repo --no-env-file --dry-run
../bin/symphony run my-saved-setup --no-env-file --dry-run
```

`setup migrate` can convert an existing checked-in runtime setup into local config plus a saved run
setup. It intentionally requires an explicit `--repo` so the target repository never depends on the
launcher's working directory.

```bash
mise exec -- ./bin/symphony setup migrate --repo /path/to/target-repo --name my-repo --dry-run
mise exec -- ./bin/symphony setup migrate --repo /path/to/target-repo --name my-repo --apply
mise exec -- ./bin/symphony run my-repo --dry-run
```

You can also start from an explicit local runtime setup file. Either export required secrets in the
current environment and skip the launcher env file:

```bash
export LINEAR_API_KEY=...
../bin/symphony run --preview --no-env-file --workflow /path/to/local-symphony-runtime.yml
../bin/symphony run --no-env-file --workflow /path/to/local-symphony-runtime.yml
```

or copy [`symphony.env.example`](symphony.env.example) to `~/.config/symphony/.env`, set
`SYMPHONY_WORKFLOW` to a local `symphony.runtime.yml`, and use the default launcher behavior, which
resolves that env file through the 1Password CLI:

```bash
mkdir -p ~/.config/symphony
cp ../symphony.env.example ~/.config/symphony/.env
../bin/symphony
```

The root launcher rebuilds the Elixir escript before launch unless `--skip-build` is passed. A
workflow can enable the dashboard/API with `runtime.server.port`; `--port <port>` or
`SYMPHONY_PORT` overrides that value for one process. Use `--profile <name>` to select a workflow
profile.

## Implement your own

Symphony is intentionally specified at the service boundary. You can implement another runtime in a
different language from the contract in [`SPEC.md`](SPEC.md):

```text
Implement Symphony according to the service specification in:
https://github.com/apontarelli/symphony/blob/main/SPEC.md
```

## License and attribution

This project is licensed under the [Apache License 2.0](LICENSE). See [`NOTICE`](NOTICE) for
OpenAI attribution and the fork modification notice.
