# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
Linear issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Build the CLI and run `symphony workflow init` from the target repo root to create
   `symphony.yml`.
4. Run `symphony workflow check` to validate the manifest, repo docs, local binding file, and any
   configured harness CODEX_HOME.
5. Run `symphony workflow print --compiled` to inspect the resolved workflow config and prompt.
6. Ensure the global `symphony-linear`, `symphony-commit`, `symphony-pull`,
   `symphony-quality-gates`, `symphony-review`, `symphony-push`, `symphony-land`, and
   `symphony-debug` skills are available to Codex.
   - `symphony-linear` expects Symphony's `linear_graphql` app-server tool for raw Linear
     GraphQL operations such as comment editing or upload flows.
7. Customize the generated `symphony.yml` for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL. Keep operator-local project IDs in the local bindings file, not in committed manifests.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
8. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony
```

From a checkout, the repository also provides a higher-level shell launcher at `../bin/symphony`.
It keeps local shell glue in this repo instead of dotfiles, resolves project workflows, loads
`~/.config/symphony/.env` through `op run`, uses Portless by default, and rebuilds the escript
before launching:

```bash
cp ../symphony.env.example ~/.config/symphony/.env
../bin/symphony my-project
../bin/symphony --workflow /path/to/project/symphony.yml --no-portless
```

To make `symphony` available as a shell command, put the repository `bin/` directory on `PATH` or
symlink `../bin/symphony` into a directory already on `PATH`.

## Configuration

Target repos can use a committed `symphony.yml` manifest for setup and audit:

```bash
./bin/symphony workflow init --repo /path/to/repo
./bin/symphony workflow check --repo /path/to/repo
./bin/symphony workflow print --repo /path/to/repo --compiled
```

`init` inspects common repo files and creates `symphony.yml`. If the manifest already exists, it is
left unchanged unless `--force` is passed. `check` validates the manifest schema, selected modules,
repo doc entrypoints, validation command shape, local bindings, and a configured harness
`CODEX_HOME`. `print` shows the resolved preset/modules/defaults and can include the compiled
workflow config and prompt without writing generated prompt files into the target repo.

`symphony.yml` v1 contains:

```yaml
version: 1
project:
  name: my-repo
  kind: elixir
  app_kind: local
workflow:
  preset: default
  modules: []
docs:
  entrypoints:
    - AGENTS.md
    - README.md
validation:
  commands:
    - name: test
      command: mix test
vcs:
  mode: jj
delivery:
  pr_target: main
automation:
  posture: unattended
harness:
  codex_home: null
bindings:
  local_file: .symphony.local.yml
  require_local: false
```

`harness.codex_home: null` means Symphony derives a managed harness CODEX_HOME. If a path is set,
`workflow check` requires that directory and its `AGENTS.md` to exist. `bindings.local_file` is for
operator-local tracker/project data that should not be committed.

Pass a custom manifest path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/symphony.yml
```

If no path is passed, Symphony uses `./symphony.yml`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)
- `--linear-bindings` overrides the default local Linear profile binding file path
- `--profile` selects one workflow profile for the current process, before project/label bindings

The preferred `symphony.yml` file is a thin YAML manifest that selects Symphony-owned workflow
modules. The manifest compiles into the same runtime config/prompt shape used by the daemon.

Minimal manifest example:

```yaml
project:
  slug: "..."
  repository: git@github.com:your-org/your-repo.git
  kind: elixir
  app_kind: web
docs:
  entrypoints:
    - README.md
vcs:
  mode: git
  default_branch: main
validation:
  commands:
    - name: tests
      command: make test
automation:
  posture: unattended
  profile: default
workflow:
  preset: default
```

When `project.repository` is present, the default `workspace` module uses it to populate new issue
workspaces with `git clone --depth 1 <repository> .`.

Repository-owned profile overrides can live under `runtime.profiles` in committed `symphony.yml`.
They describe policy available to every run of the repo and should not contain Linear project IDs:

```yaml
runtime:
  profiles:
    project_integration:
      delivery:
        pr_target: project/integration
      checks:
        - make all
```

The `default` profile is compiled from manifest delivery, validation, and automation fields.
`delivery.pr_target` is the only v1 delivery selector: use `main` for normal mainline PRs, or a
non-main branch such as `project/integration` when work should open PRs against a project integration
branch. v1 does not automate promotion from a non-main target back to `main` after restart or
landing.

Notes:

- If a value is missing, defaults are used.
- `tracker.required_labels` is optional. When set, an issue must have every configured label to
  dispatch or continue running. Label matching ignores case and surrounding whitespace. A blank
  configured label matches no issue.
- `delivery.pr_target` names the Git PR target/base branch. Additional profiles may override the
  compiled `default` profile during effective-policy resolution.
- Profile overrides replace scalar, list, and map fields by default. Use `append_<field>` for list
  additions and `add_<field>` for map additions. The resolved policy includes a stable
  `policy_ref` short hash. Replacement fields are applied before additive directives when both
  appear in the same profile.
- Linear project-to-profile bindings live outside committed `symphony.yml`. Copy
`linear-profile-bindings.example.yml` to `linear-profile-bindings.local.yml` and fill in your
operator-local Linear project slug IDs and optional `pr_target` values. The local file is
gitignored and loads automatically when it sits next to the selected manifest. Use
`--linear-bindings /path/to/bindings.yml` only to override the default lookup path:

```yaml
team_key: SID
projects:
  - project_slug: linear-project-slug
    profile: default
    pr_target: project/integration
labels:
  - label: strict
    profile: strict
catch_all:
  enabled: false
  profile: default
allow_default: false
```

Use external bindings for operator-local Linear routing facts:

```yaml
team_key: SID
projects:
  - project_slug: project-alpha
    profile: project_integration
    pr_target: project/alpha
labels:
  - label: strict
    profile: strict_review
```

Selection precedence is CLI `--profile`, exact project binding, one matching label refinement within
that project, catch-all, then `default` only when `allow_default: true` or no external bindings are
configured. Multiple matches at the same precedence block dispatch. Label refinements can change
validation/review/prompt policy but cannot change the selected project delivery target. Each
project binding must use exactly one of `project_id` or `project_slug`. Project bindings may set
`pr_target`; when absent, Symphony uses the selected profile's `delivery.pr_target`.
- Ticket class labels have generic Symphony behavior independent of project profile routing:
  - `Requirement` issues are validation artifacts. They are dispatched from `Todo` only after
    all blocking implementation issues are terminal.
  - `Project Closeout` issues use the project closeout workflow and should be blocked by unresolved
    Requirement issues.
- Prompt templates receive the resolved policy as `{{ policy }}` and `{{ policy_json }}`,
  including `policy.policy_ref`, `delivery.pr_target`, and `policy.policy_metadata` when the
  runtime selected a binding. Delivery skills use `delivery.pr_target` for branch sync, PR base
  selection, review gates, and landing guardrails. Symphony also appends a compact
  selected-profile block to the first agent prompt with the exact workpad stamp, profile prompt
  rules (`prompt.rules`, `prompt_rules`, or `prompt_requirements`), validation requirements
  (`checks`, `validation`, or `validation_requirements`), and review requirements (`review` or
  `review_requirements`).
- The workpad stamp format is
  `Policy: profile=<name> target=<pr_target> policy_ref=<short-hash>`. Explicit CLI or override
  metadata appends `override=<source>`; normal project/profile binding selection does not.
- The v1 core delivery policy only supports `delivery.pr_target`; `delivery.mode`,
  `delivery.base_ref`, `delivery.allow_main_merge`, and `delivery.require_feature_flag` are not
  supported core fields.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- Profiles may include a `codex` object with `approval_policy`, `thread_sandbox`, and
  `turn_sandbox_policy` overrides. Use this sparingly for scoped work like repo skill authoring
  that needs to edit protected `.agents/` paths; keep the global `codex` defaults sandboxed.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony compiles the built-in v1 core workflow module preset into
  the prompt template. The default preset includes Symphony-owned modules for Linear operation,
  implementation, sync, quality gates, review, landing, rework, requirement validation, project
  closeout, and run recovery.
- Use `hooks.after_create` to bootstrap a fresh workspace. Prefer `jj git clone ... .` so Codex
  turns run in jj-native workspaces and do not need to write Git metadata directly. Use
  `git clone ... .` only for repos that cannot run under jj compatibility.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    if ! command -v jj >/dev/null 2>&1; then
      echo 'jj is required for this Symphony workflow' >&2
      exit 127
    fi
    jj git clone "$SOURCE_REPO_URL" .
  before_run: |
    jj status || true
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If the selected manifest is missing or invalid at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- A running or retrying issue keeps the resolved workflow profile policy selected at dispatch time.
  Hot-reloaded workflow/profile changes apply to future dispatches, not to the in-memory policy of
  already-running or already-retrying issues.
- v1 does not persist attempt policy in a durable store. After a process restart, any recovered
  future dispatch resolves policy from the current workflow/runtime config.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- A compact control panel overview for freshness, running/retrying work, work errors,
  config warnings, stale sessions, runtime, and token usage
- A primary project status table that includes active and idle bound projects
- Running session detail with issue state, profile/target, runtime, last Codex update,
  copyable session ID, and token split
- Optional Admin details for binding/profile metadata and rate-limit diagnostics only when
  upstream rate-limit data is present
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `symphony.yml`: in-repo manifest used by local runs
- `../symphony.yml`: dogfood target-repo manifest for CLI `workflow check`/`print`
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `symphony.yml`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
