# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

Workflow behavior is versioned in [`elixir/symphony.yml`](elixir/symphony.yml). The manifest selects
Symphony-owned workflow modules, repository facts, validation gates, and delivery policy. Operator
local Linear project bindings can select profiles at runtime without committing project-specific IDs
to the manifest. The selected profile and delivery target are surfaced in agent prompts, workpads,
and dashboards so each run has a compact policy audit trail.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

If you want a shell command, put this repository's `bin/` directory on your `PATH` or symlink
`bin/symphony` into a directory already on your `PATH`. The repo-owned launcher resolves workflow
paths, wraps the service with `op run` and Portless by default, and rebuilds the Elixir escript
before launch:

```bash
symphony my-project
symphony --workflow /path/to/project/symphony.yml
symphony --workflow /path/to/project/symphony.yml --no-portless
```

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
