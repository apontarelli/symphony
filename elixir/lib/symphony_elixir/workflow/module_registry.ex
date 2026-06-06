defmodule SymphonyElixir.Workflow.ModuleRegistry do
  @moduledoc false

  @terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]

  @type diagnostic :: %{path: String.t(), message: String.t()}
  @type module_defaults :: %{
          config: map(),
          prompt_sections: [String.t()]
        }
  @type preset_defaults :: %{
          modules: [String.t()],
          config: map(),
          prompt_sections: [String.t()]
        }

  @presets %{
    "default" => %{
      modules: ["repo.docs", "validation.commands", "tracker.linear", "workspace", "codex.harness", "delivery.github_pr"],
      config: %{
        "checks" => [],
        "completion_requirements" => [],
        "delivery" => %{"pr_target" => "main"},
        "polling" => %{"interval_ms" => 30_000}
      },
      prompt_sections: [
        "This is an unattended orchestration session; never ask a human to perform follow-up actions.",
        "Route ticket states before acting: `Todo` starts work, `In Progress` continues work, `Rework` resets from review feedback, `Merging` runs the land flow, and terminal states stop.",
        "Maintain exactly one active `## Codex Workpad` comment as the source of truth for plan, acceptance criteria, validation, review evidence, and blockers.",
        "Before implementation, reproduce the current behavior, refine the plan, and sync the delivery target.",
        "Execute ticket-provided validation and the strongest feasible quality gate before handoff.",
        "Before Human Review, publish the PR, link it to the issue, ensure required PR metadata, sweep top-level and inline PR feedback, and confirm checks are green.",
        "Stop early only for missing required auth, permissions, or secrets; document the blocker and unblock action in the workpad.",
        "Final responses report completed actions and blockers only."
      ]
    }
  }

  @modules %{
    "repo.docs" => %{
      config: %{},
      prompt_sections: [
        "Treat the manifest docs entrypoints as the first repo-specific instructions to read before changing code."
      ],
      description: "repo instruction and durable docs routing"
    },
    "validation.commands" => %{
      config: %{},
      prompt_sections: [
        "Use the manifest validation commands as the repo-owned quality gates for touched surfaces."
      ],
      description: "operator-defined validation gates"
    },
    "tracker.linear" => %{
      config: %{
        "tracker" => %{
          "kind" => "linear",
          "endpoint" => "https://api.linear.app/graphql",
          "api_key" => "$LINEAR_API_KEY",
          "project_slug" => nil,
          "active_states" => ["Todo", "In Progress", "Merging", "Rework"],
          "terminal_states" => @terminal_states
        }
      },
      prompt_sections: [
        "Use Linear as the tracker and keep issue state, links, and the single workpad aligned with Symphony policy.",
        "`Human Review` means validated work is waiting for human approval; do not code while the issue is in that state.",
        "`Merging` means approval was granted; run the configured land skill/flow and never bypass it with a direct merge command.",
        "`Rework` means reviewer feedback requires a fresh planning pass, explicit feedback triage, implementation, validation, and republish."
      ],
      description: "Linear tracker issue context and handoff states"
    },
    "workspace" => %{
      config: %{
        "workspace" => %{"root" => "~/code/symphony-workspaces"},
        "hooks" => %{"timeout_ms" => 60_000}
      },
      prompt_sections: [
        "Work only inside the assigned repository workspace."
      ],
      description: "workspace checkout and lifecycle hooks"
    },
    "codex.harness" => %{
      config: %{
        "agent" => %{
          "max_concurrent_agents" => 10,
          "max_turns" => 20,
          "max_retry_backoff_ms" => 300_000
        },
        "codex" => %{
          "command" => "codex app-server",
          "approval_policy" => %{
            "reject" => %{
              "sandbox_approval" => true,
              "rules" => true,
              "mcp_elicitations" => true
            }
          },
          "thread_sandbox" => "workspace-write",
          "turn_timeout_ms" => 3_600_000,
          "read_timeout_ms" => 5_000,
          "stall_timeout_ms" => 300_000
        }
      },
      prompt_sections: [
        "Run Codex with the configured runtime settings for implementation turns."
      ],
      description: "isolated Codex harness CODEX_HOME policy"
    },
    "delivery.github_pr" => %{
      config: %{},
      prompt_sections: [
        "Use GitHub pull requests as the delivery artifact when handing work to human review."
      ],
      description: "GitHub pull request delivery defaults"
    },
    "observability" => %{
      config: %{
        "observability" => %{
          "dashboard_enabled" => true,
          "refresh_ms" => 1_000,
          "render_interval_ms" => 16
        }
      },
      prompt_sections: [
        "Use the dashboard and status APIs as operator-visible evidence when relevant."
      ],
      description: "operator-visible status and dashboard evidence"
    }
  }

  @spec preset(String.t()) :: {:ok, preset_defaults()} | {:error, diagnostic()}
  def preset(name) when is_binary(name) do
    case Map.fetch(@presets, name) do
      {:ok, defaults} -> {:ok, defaults}
      :error -> {:error, %{path: "workflow.preset", message: "unknown preset: #{name}"}}
    end
  end

  @spec default_modules(String.t()) :: {:ok, [String.t()]} | {:error, diagnostic()}
  def default_modules(preset_name) when is_binary(preset_name) do
    with {:ok, preset_defaults} <- preset(preset_name) do
      {:ok, preset_defaults.modules}
    end
  end

  @spec module_defaults(String.t(), non_neg_integer()) :: {:ok, module_defaults()} | {:error, diagnostic()}
  def module_defaults(name, index) when is_binary(name) and is_integer(index) and index >= 0 do
    case Map.fetch(@modules, name) do
      {:ok, defaults} -> {:ok, defaults}
      :error -> {:error, %{path: "workflow.modules[#{index}]", message: "unknown module: #{name}"}}
    end
  end

  @spec module_description(String.t()) :: String.t()
  def module_description(name) when is_binary(name) do
    case Map.fetch(@modules, name) do
      {:ok, defaults} -> Map.fetch!(defaults, :description)
      :error -> "unknown module"
    end
  end

  @spec module_diagnostics(String.t(), non_neg_integer(), map()) :: [diagnostic()]
  def module_diagnostics(name, index, manifest) when is_binary(name) and is_integer(index) and index >= 0 do
    case module_defaults(name, index) do
      {:ok, _defaults} -> module_manifest_diagnostics(name, manifest)
      {:error, diagnostic} -> [diagnostic]
    end
  end

  @spec module_config(String.t(), non_neg_integer(), map()) :: {:ok, map()} | {:error, diagnostic()}
  def module_config(name, index, manifest) when is_binary(name) and is_integer(index) and index >= 0 do
    with {:ok, defaults} <- module_defaults(name, index) do
      {:ok, deep_merge(defaults.config, module_manifest_config(name, manifest))}
    end
  end

  @spec module_prompt_sections(String.t(), non_neg_integer()) :: {:ok, [String.t()]} | {:error, diagnostic()}
  def module_prompt_sections(name, index) when is_binary(name) and is_integer(index) and index >= 0 do
    with {:ok, defaults} <- module_defaults(name, index) do
      {:ok, defaults.prompt_sections}
    end
  end

  defp module_manifest_diagnostics(_name, _manifest), do: []

  defp module_manifest_config("tracker.linear", manifest) do
    case get_in(manifest, ["project", "slug"]) do
      slug when is_binary(slug) -> %{"tracker" => %{"project_slug" => slug}}
      _slug -> %{}
    end
  end

  defp module_manifest_config("workspace", manifest) do
    case get_in(manifest, ["project", "repository"]) do
      repository when is_binary(repository) -> %{"hooks" => %{"after_create" => "git clone --depth 1 #{shell_quote(repository)} ."}}
      _repository -> %{}
    end
  end

  defp module_manifest_config(_name, _manifest), do: %{}

  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
