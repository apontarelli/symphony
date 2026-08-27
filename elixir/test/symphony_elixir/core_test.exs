defmodule SymphonyElixir.PromptBuilderAccessFailure do
  @behaviour Access

  defstruct [:mode, :secret]

  @impl Access
  def fetch(%__MODULE__{mode: :raise, secret: secret}, _key), do: raise(secret)
  def fetch(%__MODULE__{mode: :throw, secret: secret}, _key), do: throw(secret)
  def fetch(%__MODULE__{mode: :exit, secret: secret}, _key), do: exit(secret)

  @impl Access
  def get_and_update(_data, _key, _function), do: raise("not supported")

  @impl Access
  def pop(_data, _key), do: raise("not supported")
end

defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{ExecutionContext, TargetContext}
  alias SymphonyElixir.TargetAdmission
  alias SymphonyElixir.Workflow.Manifest

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress", "Merging", "Rework"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.agent.max_concurrent_startups == 2
    assert config.agent.max_turns == 20

    assert {:ok, policy} = Config.effective_policy()
    assert policy["delivery"]["pr_target"] == "main"
    assert policy["policy_ref"] =~ ~r/^[0-9a-f]{12}$/

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_run_target} = Config.validate!()

    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    System.put_env("LINEAR_API_KEY", "token")

    try do
      File.write!(Workflow.workflow_file_path(), """
      project:
        repository: https://github.com/apontarelli/symphony
      delivery:
        pr_target: main
      tracker:
        kind: linear
        api_key: "$LINEAR_API_KEY"
        project_slug: null
        query: " "
        query_file: null
      profiles:
        default:
          delivery:
            pr_target: main
      """)

      assert {:error, :missing_linear_run_target} = Config.validate!()
    after
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "runtime.runners.codex.command"
    assert message =~ "is required"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "runtime.runners.codex.command"
    assert message =~ "is required"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()
    assert Config.default_runner!()["command"] == ["/bin/sh", "app-server"]

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "runtime.runners.codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "runtime.runners.codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "config schema parses runtime setup fields outside repo manifests" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "linear",
                 "api_key" => "token",
                 "project_slug" => "runtime-project",
                 "required_labels" => [" Symphony ", "repo-setup"]
               },
               "workspace" => %{"root" => "/tmp/symphony-workspaces"},
               "polling" => %{"interval_ms" => 5_000},
               "agent" => %{"default_runner" => "codex", "max_concurrent_agents" => 3, "max_concurrent_startups" => 1},
               "runners" => %{
                 "codex" => %{
                   "kind" => "codex_app_server",
                   "command" => ["codex", "app-server"],
                   "model" => "gpt-5.4",
                   "approval_policy" => "never",
                   "thread_sandbox" => "workspace-write",
                   "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => true}
                 }
               },
               "hooks" => %{"before_run" => "jj status"},
               "quality_gate" => %{"enabled" => true},
               "profiles" => %{"default" => %{"delivery" => %{"pr_target" => "main"}}}
             })

    assert settings.tracker.project_slug == "runtime-project"
    assert settings.tracker.required_labels == ["symphony", "repo-setup"]
    assert settings.workspace.root == "/tmp/symphony-workspaces"
    assert settings.polling.interval_ms == 5_000
    assert settings.agent.max_concurrent_agents == 3
    assert Schema.default_runner_config!(settings)["model"] == "gpt-5.4"
    assert Schema.default_runner_config!(settings)["turn_sandbox_policy"] == %{"type" => "workspaceWrite", "networkAccess" => true}
    assert settings.hooks.before_run == "jj status"
    assert settings.quality_gate.enabled == true

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "profiles" => %{"default" => %{"delivery" => %{"pr_target" => "main"}}},
               "runners" => %{"codex" => %{"kind" => " "}}
             })

    assert message =~ "runtime.runners.codex.kind is required"
  end

  test "explicit runtime setup can be named symphony.yml" do
    root = Path.join(System.tmp_dir!(), "symphony-runtime-#{System.unique_integer([:positive])}")
    path = Path.join(root, "symphony.yml")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    write_workflow_file!(path, tracker_project_slug: "runtime-project")

    assert {:ok, %{config: config}} = Workflow.load(path)
    assert config["tracker"]["project_slug"] == "runtime-project"
    refute Map.has_key?(config["manifest"], "runtime")
  end

  test "workflow profiles require default profile and delivery target" do
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"profiles" => %{}})
    assert message =~ "profiles default profile is required"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{}
               }
             })

    assert message =~ "default.delivery.pr_target is required"
  end

  test "workflow profiles reject non-v1 delivery fields" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{
                   "delivery" => %{
                     "pr_target" => "main",
                     "mode" => "direct",
                     "base_ref" => "main",
                     "allow_main_merge" => true,
                     "require_feature_flag" => false
                   }
                 }
               }
             })

    assert message =~ "default.delivery.mode is not supported in v1"
    assert message =~ "default.delivery.base_ref is not supported in v1"
    assert message =~ "default.delivery.allow_main_merge is not supported in v1"
    assert message =~ "default.delivery.require_feature_flag is not supported in v1"
  end

  test "workflow profiles reject malformed profile policy shapes" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "policy_ref" => "manual"
                 },
                 "not_a_map" => "bad",
                 "non_string_pr_target" => %{"delivery" => %{"pr_target" => 123}},
                 "non_map_delivery" => %{"delivery" => "main"},
                 "legacy_codex" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "codex" => %{"command" => "codex app-server"}
                 },
                 "non_map_runners" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "runners" => "danger"
                 },
                 "malformed_runner_fields" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "runners" => %{
                     "codex" => %{
                       "approval_policy" => 123,
                       "thread_sandbox" => 123,
                       "turn_sandbox_policy" => "dangerFullAccess",
                       "command" => "codex app-server"
                     }
                   }
                 }
               }
             })

    assert message =~ "default.policy_ref is reserved"
    assert message =~ "not_a_map profile must be a map"
    assert message =~ "non_string_pr_target.delivery.pr_target must be a string"
    assert message =~ "non_map_delivery.delivery must be a map"
    assert message =~ "legacy_codex.codex is not supported in v1"
    assert message =~ "non_map_runners.runners must be a map"
    assert message =~ "malformed_runner_fields.runners.codex.command is not supported in v1"
    assert message =~ "malformed_runner_fields.runners.codex.approval_policy must be a string or map"
    assert message =~ "malformed_runner_fields.runners.codex.thread_sandbox must be a string"
    assert message =~ "malformed_runner_fields.runners.codex.turn_sandbox_policy must be a map"
  end

  test "workflow profile resolution replaces lists and maps by default while preserving untouched defaults" do
    assert {:ok, settings} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "checks" => ["format", "test"],
                   "labels" => %{"tier" => "standard", "team" => "platform"},
                   "limits" => %{"max_turns" => 20}
                 },
                 "expedite" => %{
                   "delivery" => %{"pr_target" => "project/integration"},
                   "checks" => ["smoke"],
                   "labels" => %{"tier" => "urgent"}
                 }
               }
             })

    assert {:ok, policy} = Schema.resolve_effective_policy(settings, "expedite")
    assert policy["delivery"] == %{"pr_target" => "project/integration"}
    assert policy["checks"] == ["smoke"]
    assert policy["labels"] == %{"tier" => "urgent"}
    assert policy["limits"] == %{"max_turns" => 20}
    assert policy["policy_ref"] =~ ~r/^[0-9a-f]{12}$/
  end

  test "workflow profile resolution recomputes publish target from effective delivery target" do
    assert {:ok, settings} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "manifest" => %{
                     "project" => %{"repository" => "https://github.com/example/target-repo"},
                     "workflow" => %{"modules" => ["delivery.github_pr"]}
                   },
                   "publish_target" => %{
                     "repository" => "https://github.com/example/target-repo",
                     "pr_target" => "main",
                     "github_repository" => "example/target-repo",
                     "display" => "example/target-repo:main"
                   }
                 },
                 "project_alpha" => %{
                   "delivery" => %{"pr_target" => "project/alpha"}
                 }
               }
             })

    assert {:ok, policy} = Schema.resolve_effective_policy(settings, "project_alpha")
    assert policy["delivery"] == %{"pr_target" => "project/alpha"}

    assert policy["publish_target"] == %{
             "repository" => "https://github.com/example/target-repo",
             "pr_target" => "project/alpha",
             "github_repository" => "example/target-repo",
             "display" => "example/target-repo:project/alpha"
           }

    assert policy["policy_ref"] =~ ~r/^[0-9a-f]{12}$/
  end

  test "workflow profile resolution rejects ambiguous publish delivery target overrides" do
    assert {:ok, settings} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "manifest" => %{
                     "project" => %{"repository" => "https://github.com/example/target-repo"},
                     "workflow" => %{"modules" => ["delivery.github_pr"]}
                   }
                 }
               }
             })

    assert {:error, {:ambiguous_delivery_pr_target, "default"}} =
             Schema.resolve_effective_policy(settings, "default", [], delivery_target_override: "origin/main")

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "manifest" => %{
                     "project" => %{"repository" => "https://github.com/example/target-repo"},
                     "workflow" => %{"modules" => ["delivery.github_pr"]}
                   }
                 },
                 "project_alpha" => %{"delivery" => %{"pr_target" => "refs/heads/main"}}
               }
             })

    assert message =~
             "project_alpha.delivery.pr_target must be an unambiguous branch name for publish handoff"
  end

  test "workflow profile resolution applies valid delivery target override to publish target" do
    assert {:ok, settings} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "manifest" => %{
                     "project" => %{"repository" => "https://github.com/example/target-repo"},
                     "workflow" => %{"modules" => ["delivery.github_pr"]}
                   }
                 }
               }
             })

    assert {:ok, policy} =
             Schema.resolve_effective_policy(settings, "default", [], delivery_target_override: " project/integration ")

    assert policy["delivery"] == %{"pr_target" => "project/integration"}

    assert policy["publish_target"] == %{
             "repository" => "https://github.com/example/target-repo",
             "pr_target" => "project/integration",
             "github_repository" => "example/target-repo",
             "display" => "example/target-repo:project/integration"
           }

    assert {:ok, unchanged_policy} =
             Schema.resolve_effective_policy(settings, "default", [], delivery_target_override: " ")

    assert unchanged_policy["delivery"] == %{"pr_target" => "main"}

    assert {:ok, unchanged_policy} =
             Schema.resolve_effective_policy(settings, "default", [], delivery_target_override: 123)

    assert unchanged_policy["delivery"] == %{"pr_target" => "main"}
  end

  test "workflow profile resolution rejects refinements that override a locked delivery target" do
    assert {:ok, settings} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "manifest" => %{
                     "project" => %{"repository" => "https://github.com/example/target-repo"},
                     "workflow" => %{"modules" => ["delivery.github_pr"]}
                   }
                 },
                 "strict_label" => %{
                   "delivery" => %{"pr_target" => "release/next"}
                 },
                 "same_target_label" => %{
                   "delivery" => %{"pr_target" => "project/integration"},
                   "checks" => ["smoke"]
                 }
               }
             })

    assert {:error, {:refinement_delivery_target_override, "strict_label", "project/integration", "release/next"}} =
             Schema.resolve_effective_policy(settings, "default", ["strict_label"], delivery_target_override: "project/integration")

    assert {:ok, policy} =
             Schema.resolve_effective_policy(settings, "default", ["same_target_label"], delivery_target_override: "project/integration")

    assert policy["delivery"] == %{"pr_target" => "project/integration"}
    assert policy["checks"] == ["smoke"]
  end

  test "workflow profile resolution keeps legacy targets when publish repository is not GitHub" do
    assert {:ok, settings} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "manifest" => %{
                     "project" => %{"repository" => "https://example.com/project.git"},
                     "workflow" => %{"modules" => ["delivery.github_pr"]}
                   }
                 },
                 "strict" => %{
                   "delivery" => %{"pr_target" => "Human Review"}
                 }
               }
             })

    assert {:ok, policy} = Schema.resolve_effective_policy(settings, "strict")
    assert policy["delivery"] == %{"pr_target" => "Human Review"}
    refute Map.has_key?(policy, "publish_target")
  end

  test "workflow profile resolution drops stale publish target when repository is not GitHub" do
    assert {:ok, settings} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "manifest" => %{
                     "project" => %{"repository" => "https://example.com/project.git"},
                     "workflow" => %{"modules" => []}
                   },
                   "publish_target" => %{
                     "repository" => "https://github.com/example/old-repo",
                     "pr_target" => "main",
                     "github_repository" => "example/old-repo",
                     "display" => "example/old-repo:main"
                   }
                 }
               }
             })

    assert {:ok, policy} = Schema.resolve_effective_policy(settings)
    assert policy["delivery"] == %{"pr_target" => "main"}
    refute Map.has_key?(policy, "publish_target")
  end

  test "workflow profile resolution ignores malformed policy metadata" do
    settings = %Schema{
      profiles: %{
        "default" => %{
          "delivery" => %{"pr_target" => "main"}
        }
      },
      policy_metadata: "not-a-map"
    }

    assert {:ok, policy} = Schema.resolve_effective_policy(settings)
    assert policy["delivery"] == %{"pr_target" => "main"}
    assert policy["policy_ref"] =~ ~r/^[0-9a-f]{12}$/
    refute Map.has_key?(policy, "policy_metadata")
  end

  test "workflow profile resolution applies add and append fields explicitly" do
    assert {:ok, settings} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "checks" => ["format"],
                   "labels" => %{"tier" => "standard"},
                   "metadata" => %{"owners" => ["platform"], "priority" => "normal"}
                 },
                 "strict" => %{
                   "append_checks" => ["dialyzer"],
                   "add_labels" => %{"profile" => "strict"},
                   "add_metadata" => %{
                     "append_owners" => ["security"],
                     "priority" => "high"
                   }
                 }
               }
             })

    assert {:ok, policy} = Schema.resolve_effective_policy(settings, "strict")
    assert policy["checks"] == ["format", "dialyzer"]
    assert policy["labels"] == %{"tier" => "standard", "profile" => "strict"}
    assert policy["metadata"] == %{"owners" => ["platform", "security"], "priority" => "high"}
    refute Map.has_key?(policy, "append_checks")
    refute Map.has_key?(policy, "add_labels")
  end

  test "prompt builder appends selected profile rules and workpad stamp to shared prompt" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Shared repository rule for {{ issue.identifier }}.",
      profiles: %{
        default: %{delivery: %{pr_target: "human-review"}},
        strict: %{
          delivery: %{pr_target: "merging"},
          prompt: %{rules: ["Use the strict profile harness."]},
          checks: ["mix test"],
          review: %{mode: "strict"}
        }
      }
    )

    issue = %Issue{
      id: "issue-prompt-policy",
      identifier: "SID-PROMPT",
      title: "Prompt policy",
      state: "Todo"
    }

    assert {:ok, policy} = Config.effective_policy("strict")

    policy =
      Map.put(policy, "policy_metadata", %{
        "source" => "profile_override",
        "profile" => "strict"
      })

    prompt = PromptBuilder.build_prompt(issue, policy: policy)

    assert prompt =~ "Shared repository rule for SID-PROMPT."
    assert prompt =~ "## Selected Workflow Profile"
    assert prompt =~ "Policy: profile=strict target=merging policy_ref=#{policy["policy_ref"]}"
    assert prompt =~ "before implementation work starts"
    assert prompt =~ "Use the strict profile harness."
    assert prompt =~ "Validation requirements:"
    assert prompt =~ "checks: mix test"
    assert prompt =~ "Review requirements:"
    assert prompt =~ "review:"
    assert prompt =~ "\"mode\":\"strict\""
  end

  test "workpad policy stamp stays concise unless an explicit override selected the policy" do
    base_policy = %{
      "delivery" => %{"pr_target" => "Human Review"},
      "policy_ref" => "abc123def456",
      "policy_metadata" => %{"source" => "default_profile", "profile" => "strict"}
    }

    assert PromptBuilder.workpad_policy_stamp(base_policy) ==
             "Policy: profile=strict target=Human Review policy_ref=abc123def456"

    override_policy =
      put_in(base_policy, ["policy_metadata"], %{
        "source" => "cli_override",
        "profile" => "strict",
        "cli_override" => true
      })

    assert PromptBuilder.workpad_policy_stamp(override_policy) ==
             "Policy: profile=strict target=Human Review policy_ref=abc123def456 override=cli_override"

    override_source_policy =
      put_in(base_policy, ["policy_metadata"], %{
        "profile" => "strict",
        "override_source" => "operator_override"
      })

    assert PromptBuilder.workpad_policy_stamp(override_source_policy) ==
             "Policy: profile=strict target=Human Review policy_ref=abc123def456 override=operator_override"

    legacy_override_policy =
      put_in(base_policy, ["policy_metadata"], %{
        "profile" => "strict",
        "override" => "env_override"
      })

    assert PromptBuilder.workpad_policy_stamp(legacy_override_policy) ==
             "Policy: profile=strict target=Human Review policy_ref=abc123def456 override=env_override"

    assert PromptBuilder.workpad_policy_stamp(%{"delivery" => "unsupported"}) ==
             "Policy: profile=default target=unknown policy_ref=unknown"
  end

  test "prompt builder renders alternate profile policy requirement shapes" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Shared body")

    policy = %{
      "delivery" => %{"pr_target" => "Human Review"},
      "policy_ref" => "def456abc123",
      "prompt_rules" => %{},
      "prompt_requirements" => :audit,
      "prompt" => %{"summary" => "Fallback prompt map"},
      "checks" => [123],
      "validation" => [],
      "validation_requirements" => %{},
      "review" => [],
      "review_requirements" => ["human signoff"]
    }

    prompt =
      PromptBuilder.build_prompt(%Issue{identifier: "SID-ALT", title: "Alt", state: "Todo"},
        policy: policy
      )

    assert prompt =~ "Shared body"
    assert prompt =~ "Policy: profile=default target=Human Review policy_ref=def456abc123"
    assert prompt =~ "summary: Fallback prompt map"
    assert prompt =~ "audit"
    assert prompt =~ "checks: 123"
    assert prompt =~ "review_requirements: human signoff"
  end

  test "workflow profile resolution applies replacements before additive fields" do
    assert {:ok, settings} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{
                   "delivery" => %{"pr_target" => "main"},
                   "checks" => ["format"],
                   "labels" => %{"tier" => "standard", "team" => "platform"}
                 },
                 "strict" => %{
                   "append_checks" => ["dialyzer"],
                   "checks" => ["smoke"],
                   "add_labels" => %{"profile" => "strict"},
                   "labels" => %{"tier" => "urgent"}
                 }
               }
             })

    assert {:ok, policy} = Schema.resolve_effective_policy(settings, "strict")
    assert policy["checks"] == ["smoke", "dialyzer"]
    assert policy["labels"] == %{"tier" => "urgent", "profile" => "strict"}
  end

  test "workflow profile resolution rejects unknown profile references" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}}
      }
    )

    assert {:error, {:unknown_workflow_profile, "missing", ["default"]}} =
             Config.effective_policy("missing")

    assert {:error, :missing_default_workflow_profile} =
             Schema.resolve_effective_policy(%Schema{profiles: %{}}, "default")

    assert {:ok, settings} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{"delivery" => %{"pr_target" => "main"}}
               }
             })

    assert {:ok, _policy} = Schema.resolve_effective_policy(settings)
    assert {:error, :blank_workflow_profile} = Schema.resolve_effective_policy(settings, "")
    assert {:error, {:invalid_workflow_profile_ref, 123}} = Schema.resolve_effective_policy(settings, 123)
  end

  test "workflow profile resolution rejects invalid additive directives" do
    baseline = %{
      "default" => %{
        "delivery" => %{"pr_target" => "main"},
        "checks" => ["format"],
        "labels" => %{"tier" => "standard"}
      }
    }

    cases = [
      {%{"bad" => %{"add_checks" => %{"extra" => "dialyzer"}}}, "bad.checks cannot be merged with add_* policy field; expected_existing_map"},
      {%{"bad" => %{"add_labels" => ["strict"]}}, "bad.labels cannot be merged with add_* policy field; expected_map"},
      {%{"bad" => %{"append_labels" => ["strict"]}}, "bad.labels cannot be merged with append_* policy field; expected_existing_list"},
      {%{"bad" => %{"append_checks" => "dialyzer"}}, "bad.checks cannot be merged with append_* policy field; expected_list"},
      {%{"bad" => %{"metadata" => %{"add_flags" => "strict"}}}, "bad.metadata.flags cannot be merged with add_* policy field; expected_map"},
      {%{"bad" => %{"append_items" => [%{"add_flags" => "strict"}]}}, "bad.items.0.flags cannot be merged with add_* policy field; expected_map"},
      {%{"bad" => %{"add_delivery" => %{"mode" => "direct"}}}, "bad.delivery.mode not supported in v1"},
      {%{"bad" => %{"delivery" => %{}}}, "bad.delivery.pr_target is required in resolved policy"},
      {%{"bad" => %{"add_policy_metadata" => %{"source" => "operator"}}}, "bad.add_policy_metadata targets reserved policy_metadata"},
      {%{"bad" => %{"append_policy_ref" => ["manual"]}}, "bad.append_policy_ref targets reserved policy_ref"}
    ]

    for {profile_override, expected_message} <- cases do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"profiles" => Map.merge(baseline, profile_override)})

      assert message =~ expected_message
    end
  end

  test "workflow policy refs are stable for equivalent effective policies" do
    left =
      %{
        "profiles" => %{
          "default" => %{
            "delivery" => %{"pr_target" => "main"},
            "labels" => %{"team" => "platform", "tier" => "standard"},
            "checks" => ["format", "test"]
          }
        }
      }

    right =
      %{
        "profiles" => %{
          "default" => %{
            "checks" => ["format", "test"],
            "labels" => %{"tier" => "standard", "team" => "platform"},
            "delivery" => %{"pr_target" => "main"}
          }
        }
      }

    assert {:ok, left_settings} = Schema.parse(left)
    assert {:ok, right_settings} = Schema.parse(right)
    assert {:ok, left_policy} = Schema.resolve_effective_policy(left_settings, "default")
    assert {:ok, right_policy} = Schema.resolve_effective_policy(right_settings, nil)

    assert left_policy["policy_ref"] == right_policy["policy_ref"]

    assert {:ok, changed_settings} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{
                   "delivery" => %{"pr_target" => "project/changed"},
                   "labels" => %{"team" => "platform", "tier" => "standard"},
                   "checks" => ["format", "test"]
                 }
               }
             })

    assert {:ok, changed_policy} = Schema.resolve_effective_policy(changed_settings, "default")
    refute changed_policy["policy_ref"] == left_policy["policy_ref"]
  end

  test "workflow profile refinements can be composed explicitly" do
    assert {:ok, settings} =
             Schema.parse(%{
               "profiles" => %{
                 "default" => %{"delivery" => %{"pr_target" => "main"}, "checks" => ["format"]},
                 "project_alpha" => %{"delivery" => %{"pr_target" => "project/alpha"}, "checks" => ["project"]},
                 "strict_label" => %{"append_checks" => ["dialyzer"]}
               }
             })

    assert {:ok, policy} =
             Schema.resolve_effective_policy(settings, "project_alpha", ["strict_label"], metadata: %{source: "test"})

    assert policy["delivery"]["pr_target"] == "project/alpha"
    assert policy["checks"] == ["project", "dialyzer"]
    assert policy["policy_metadata"] == %{"source" => "test"}

    assert {:error, {:invalid_workflow_profile_ref, 123}} =
             Schema.resolve_effective_policy(settings, "project_alpha", [123], [])
  end

  test "issue policy uses the default workflow profile and records tracker metadata" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_id: "project-id",
      tracker_project_slug: "project",
      profiles: %{
        default: %{delivery: %{pr_target: "main"}, checks: ["format"]},
        strict: %{delivery: %{pr_target: "human-review"}, checks: ["mix test"]}
      }
    )

    issue = %Issue{
      id: "issue-default-policy",
      identifier: "SID-101",
      title: "Default dispatch",
      state: "Todo",
      project_id: "project-id",
      project_slug: "project"
    }

    assert {:ok, policy} = Config.issue_policy(issue)
    assert policy["delivery"]["pr_target"] == "main"
    assert policy["checks"] == ["format"]
    assert policy["policy_metadata"]["source"] == "default_profile"
    assert policy["policy_metadata"]["profile"] == "default"
    assert policy["policy_metadata"]["project_id"] == "project-id"
    assert policy["policy_metadata"]["project_slug"] == "project"

    assert PromptBuilder.workpad_policy_stamp(policy) ==
             "Policy: profile=default target=main policy_ref=#{policy["policy_ref"]}"
  end

  test "workflow profile override wins for the current process and records metadata" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}},
        strict: %{delivery: %{pr_target: "human-review"}, checks: ["mix test"]}
      }
    )

    issue = %Issue{
      id: "issue-override",
      identifier: "SID-102",
      title: "Override profile",
      state: "Todo",
      project_slug: "project"
    }

    Config.set_profile_override("strict")
    assert {:ok, override_policy} = Config.issue_policy(issue)
    assert override_policy["delivery"]["pr_target"] == "human-review"
    assert override_policy["checks"] == ["mix test"]
    assert override_policy["policy_metadata"]["source"] == "profile_override"
    assert override_policy["policy_metadata"]["profile"] == "strict"

    Config.clear_profile_override()
    assert {:ok, default_policy} = Config.issue_policy(issue)
    assert default_policy["delivery"]["pr_target"] == "main"
    assert default_policy["policy_metadata"]["source"] == "default_profile"
  end

  test "workflow profile override validation rejects unknown profiles" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}}
      }
    )

    Config.set_profile_override("missing")

    assert {:error, {:unknown_workflow_profile_override, "missing", {:unknown_workflow_profile, "missing", ["default"]}}} =
             Config.validate!()
  end

  test "orchestrator fails startup when readiness validation fails" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    System.delete_env("LINEAR_API_KEY")
    previous_trap_exit = Process.flag(:trap_exit, true)

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      Process.flag(:trap_exit, previous_trap_exit)
    end)

    log =
      capture_log(fn ->
        assert {:error, {:invalid_startup_config, :missing_linear_api_token}} =
                 Orchestrator.start_link(name: SymphonyElixir.InvalidStartupProbe)
      end)

    assert log =~ "Startup config validation failed"
    assert log =~ "missing_linear_api_token"
  end

  test "orchestrator consumes a supplied target without rereading workflow config" do
    assert {:ok, target} = TargetAdmission.build_target([])

    original_workflow_path = Workflow.workflow_file_path()

    missing_workflow =
      Path.join(
        System.tmp_dir!(),
        "missing-pinned-startup-workflow-#{System.unique_integer([:positive])}.yml"
      )

    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.set_workflow_file_path(missing_workflow)
    assert_raise ArgumentError, fn -> Config.settings!() end

    name = Module.concat(__MODULE__, PinnedStartupProbe)

    assert {:ok, pid} =
             Orchestrator.start_link(
               name: name,
               target_context: target,
               control_plane: false
             )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert Process.alive?(pid)
  end

  test "current symphony.yml manifest is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)

    System.put_env("LINEAR_API_KEY", "manifest-token")
    Workflow.set_workflow_file_path(repo_manifest_path())

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert Map.get(tracker, "project_slug") == nil
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") == "git clone --depth 1 'https://github.com/apontarelli/symphony' ."
    assert Map.get(hooks, "before_run") == nil
    assert Map.get(hooks, "before_remove") == nil

    assert get_in(config, ["capabilities", "required"]) == ["linear", "github_pr", "browser"]
    assert get_in(config, ["issue_markers", "labels"]) == ["repo:symphony"]
    assert get_in(config, ["workflow_modules", "product_visual_review", "route_policy"]) == "auto"

    profiles = Map.get(config, "profiles", %{})
    assert get_in(profiles, ["default", "delivery", "pr_target"]) == "main"

    assert String.trim(prompt) != ""
    assert prompt =~ "Role: You are an autonomous software-engineering agent resolving Linear ticket `{{ issue.identifier }}`."
    assert prompt =~ "Project context:"
    assert prompt =~ "## Core Workflow Modules"
    assert prompt =~ "Validation commands:\n- all: cd elixir && mise exec -- make all"
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() =~ "## Core Workflow Modules"
    refute Config.workflow_prompt() =~ "## Related skills"

    assert {:ok, policy} = Config.effective_policy()
    assert is_binary(policy["policy_ref"])
    assert policy["checks"] == [%{"name" => "all", "command" => "cd elixir && mise exec -- make all"}]
    assert policy["completion_requirements"] == ["Run the strongest feasible validation gate before handoff."]
    assert policy["delivery"] == %{"pr_target" => "main"}
    assert policy["policy_metadata"]["project_slug"] == "symphony"
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "workflow file path uses configured default when runtime override is unset" do
    original_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    original_default_path = Application.get_env(:symphony_elixir, :default_workflow_file_path)

    on_exit(fn ->
      restore_app_env(:workflow_file_path, original_workflow_path)
      restore_app_env(:default_workflow_file_path, original_default_path)
    end)

    Application.delete_env(:symphony_elixir, :workflow_file_path)
    Application.put_env(:symphony_elixir, :default_workflow_file_path, repo_manifest_path())

    assert Workflow.manifest_file_path() == Path.join(File.cwd!(), "symphony.yml")
    assert Workflow.workflow_file_path() == repo_manifest_path()
  end

  test "workflow file path falls back to cwd symphony.yml when no default is configured" do
    original_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    original_default_path = Application.get_env(:symphony_elixir, :default_workflow_file_path)
    root = Path.join(System.tmp_dir!(), "symphony-elixir-workflow-md-default-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_app_env(:workflow_file_path, original_workflow_path)
      restore_app_env(:default_workflow_file_path, original_default_path)
      File.rm_rf(root)
    end)

    File.mkdir_p!(root)
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    Application.delete_env(:symphony_elixir, :default_workflow_file_path)

    File.cd!(root, fn ->
      assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "symphony.yml")
    end)
  end

  test "workflow load defaults to symphony.yml when app env is unset" do
    original_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    original_default_path = Application.get_env(:symphony_elixir, :default_workflow_file_path)

    on_exit(fn ->
      restore_app_env(:workflow_file_path, original_workflow_path)
      restore_app_env(:default_workflow_file_path, original_default_path)
    end)

    workflow_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-manifest-precedence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workflow_root)
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    Application.delete_env(:symphony_elixir, :default_workflow_file_path)

    try do
      File.write!(Path.join(workflow_root, "symphony.yml"), """
      version: 1
      project:
        slug: manifest-repo
        repository: github.com/example/manifest-repo
      delivery:
        pr_target: main
      """)

      File.cd!(workflow_root, fn ->
        assert {:ok, %{config: config}} = Workflow.load()
        assert config["tracker"]["project_slug"] == nil
        assert config["manifest"]["project"]["slug"] == "manifest-repo"
      end)
    after
      File.rm_rf(workflow_root)
    end
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/symphony.yml"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    assert Process.whereis(SymphonyElixir.Orchestrator) == nil
    assert {:ok, pid} = SymphonyElixir.start_link()

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)

    assert Process.whereis(SymphonyElixir.Orchestrator) == pid
    GenServer.stop(pid)
  end

  test "application callbacks validate target admission and render offline status" do
    previous_validate = Application.get_env(:symphony_elixir, :validate_startup)
    previous_control_plane = Application.get_env(:symphony_elixir, :start_control_plane)

    on_exit(fn ->
      restore_app_env(:validate_startup, previous_validate)
      restore_app_env(:start_control_plane, previous_control_plane)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :validate_startup, true)
    Application.put_env(:symphony_elixir, :start_control_plane, false)

    assert {:error, {:already_started, _pid}} = SymphonyElixir.Application.start(:normal, [])
    assert :ok = SymphonyElixir.Application.stop(:normal)
  end

  test "agent runner does not continue after a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue = %Issue{
      id: "issue-label-continuation",
      identifier: "MT-563",
      title: "Stop after opt-out",
      state: "In Progress",
      labels: ["symphony"]
    }

    refreshed_issue = %{issue | labels: []}

    fetcher = fn _target, ["issue-label-continuation"] ->
      {:ok, [refreshed_issue]}
    end

    assert {:ok, target} = TargetAdmission.build_target([])

    assert {:ok, policy} = Config.issue_policy(issue)

    assert {:ok, context} =
             ExecutionContext.new(target, issue, policy: policy)

    assert {:done, ^refreshed_issue} =
             AgentRunner.continue_with_issue_for_test(context, issue, fetcher)
  end

  test "agent runner does not continue when the pinned active-state set is empty" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: [])

    issue = %Issue{
      id: "issue-no-active-states",
      identifier: "MT-566",
      title: "Stop when no state is active",
      state: "In Progress",
      labels: []
    }

    fetcher = fn _target, ["issue-no-active-states"] -> {:ok, [issue]} end

    assert {:ok, target} = TargetAdmission.build_target([])
    assert {:ok, policy} = Config.issue_policy(issue)
    assert {:ok, context} = ExecutionContext.new(target, issue, policy: policy)

    assert {:done, ^issue} =
             AgentRunner.continue_with_issue_for_test(context, issue, fetcher)
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      runtime_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  test "select_worker_host_for_test observes per-host startup caps" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2,
      worker_max_concurrent_startups_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a", startup_slot?: true},
        "issue-2" => %{worker_host: "worker-b", startup_slot?: false}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-b"
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder resolves issue policy when no explicit policy option is provided" do
    workflow_prompt = "Target {{ policy.delivery.pr_target }} json={{ policy_json }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-2",
      title: "Render policy",
      description: "Use issue routing context",
      state: "Todo",
      url: "https://example.org/issues/S-2",
      project_slug: "project",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Target main"
    assert prompt =~ "target=main"
    assert prompt =~ ~s("pr_target": "main")
    assert prompt =~ ~s("policy_ref")
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue, policy: %{}) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses the generated manifest template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Role: You are an autonomous software-engineering agent resolving Linear ticket `MT-777`."
    assert prompt =~ "Project context:"
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "- PR target: main"
    assert prompt =~ "target=main"
    assert prompt =~ "Description:"
    assert prompt =~ "Include enough issue context to start working."
    assert prompt =~ "Selected Workflow Profile"
    assert prompt =~ "## Core Workflow Modules"
    assert prompt =~ "### Linear Operation"
    assert prompt =~ "Use Linear as the tracker"
    refute prompt =~ "## Related skills"
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "## Core Workflow Modules"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder exposes workflow module context to templates" do
    workflow_prompt = "modules={{ workflow.module_names }} hash={{ workflow.module_policy_hash }}\n{{ workflow.modules }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-779",
      title: "Render modules",
      description: "Expose workflow module context",
      state: "Todo",
      url: "https://example.org/issues/MT-779",
      labels: []
    }

    bundle = PromptBuilder.build_prompt_bundle(issue)

    assert bundle.workflow_module_resolution.policy_hash =~ ~r/^sha256:[a-f0-9]{64}$/
    assert bundle.prompt =~ "modules=linear-operation, implementation-loop"
    assert bundle.prompt =~ "hash=#{bundle.workflow_module_resolution.policy_hash}"
    assert bundle.prompt =~ "Resolved modules: linear-operation@v1"
    assert bundle.prompt =~ "### Linear Operation"
    refute bundle.prompt =~ ~r/symphony-(linear|commit|pull|quality-gates|review|push|land|debug|project-closeout)/
  end

  test "context prompt bundle renders only pinned template policy and module resolution" do
    issue = %Issue{id: "issue-410", identifier: "SID-410", title: "Pinned prompt"}

    context =
      prompt_execution_context(
        issue,
        "pinned={{ policy.profile }} issue={{ issue.identifier }} attempt={{ attempt }} modules={{ workflow.module_names }}",
        %{"profile" => "strict"}
      )

    pinned_resolution = context.target.repo_policy["workflow_module_resolution"]

    assert {:ok, bundle} = PromptBuilder.build_prompt_bundle(context, issue, attempt: 2)

    assert bundle.prompt =~
             "pinned=strict issue=SID-410 attempt=2 modules=#{Enum.join(pinned_resolution["module_names"], ", ")}"

    assert Map.take(
             bundle.workflow_module_resolution,
             [:module_names, :module_refs, :policy_hash, :rendered]
           ) == %{
             module_names: pinned_resolution["module_names"],
             module_refs:
               Enum.map(pinned_resolution["module_refs"], fn ref ->
                 %{name: ref["name"], version: ref["version"]}
               end),
             policy_hash: pinned_resolution["policy_hash"],
             rendered: pinned_resolution["rendered"]
           }

    assert is_list(bundle.workflow_module_resolution.modules)
  end

  test "context prompt bundle rejects policy overrides duplicate attempts and mismatched issues" do
    issue = %Issue{id: "issue-410", identifier: "SID-410"}
    context = prompt_execution_context(issue, "attempt={{ attempt }}", %{"profile" => "strict"})

    assert {:error, :prompt_policy_override_forbidden} =
             PromptBuilder.build_prompt_bundle(context, issue, policy: %{"profile" => "forged"})

    assert {:error, :duplicate_prompt_option} =
             PromptBuilder.build_prompt_bundle(context, issue,
               attempt: 1,
               attempt: 2
             )

    assert {:error, :unknown_prompt_option} =
             PromptBuilder.build_prompt_bundle(context, issue, unknown: true)

    assert {:error, :invalid_prompt_issue} =
             PromptBuilder.build_prompt_bundle(
               context,
               %{issue | identifier: "SID-OTHER"},
               []
             )
  end

  test "context prompt bundle returns fixed parse and render errors without secret content" do
    issue = %Issue{id: "issue-410", identifier: "SID-410"}
    secret = "secret-sentinel-prompt"

    parse_context =
      prompt_execution_context(issue, "{% if", %{"profile" => "strict"})

    assert {:error, :prompt_template_parse_failed} =
             PromptBuilder.build_prompt_bundle(parse_context, issue, [])

    render_context =
      prompt_execution_context(
        issue,
        "pinned",
        %{"profile" => "strict", "hostile" => fn -> secret end}
      )

    assert {:error, :prompt_render_failed} =
             PromptBuilder.build_prompt_bundle(render_context, issue, [])
  end

  test "context prompt bundle compiles only a pinned manifest and rejects resolution drift" do
    issue = %Issue{id: "issue-410", identifier: "SID-410", title: "Generated prompt"}
    assert {:ok, manifest} = Manifest.read(repo_manifest_path(), repo_setup?: false)
    compiled = Manifest.compile(manifest)
    resolution = prompt_resolution_projection(compiled.workflow_module_resolution)

    context =
      prompt_execution_context(issue, nil, %{"profile" => "strict"},
        manifest: manifest,
        resolution: resolution
      )

    assert {:ok, bundle} = PromptBuilder.build_prompt_bundle(context, issue, [])
    assert bundle.prompt =~ "SID-410"
    assert bundle.workflow_module_resolution.policy_hash == resolution["policy_hash"]

    mismatched_resolution =
      Map.put(resolution, "policy_hash", "sha256:" <> String.duplicate("f", 64))

    mismatched_context =
      prompt_execution_context(issue, nil, %{"profile" => "strict"},
        manifest: manifest,
        resolution: mismatched_resolution
      )

    assert {:error, :invalid_prompt_context} =
             PromptBuilder.build_prompt_bundle(mismatched_context, issue, [])
  end

  test "context prompt bundle rejects malformed public inputs before rendering" do
    issue = %Issue{id: "issue-410", identifier: "SID-410"}
    context = prompt_execution_context(issue, "attempt={{ attempt }}", %{"profile" => "strict"})

    for invalid_opts <- [:invalid_options, %{}, [{:attempt, 1} | :invalid_tail]] do
      assert {:error, :invalid_prompt_options} =
               PromptBuilder.build_prompt_bundle(context, issue, invalid_opts)
    end

    assert {:error, :invalid_prompt_options} =
             PromptBuilder.build_prompt_bundle(context, issue, attempt: -1)

    assert {:error, :invalid_prompt_context} =
             PromptBuilder.build_prompt_bundle(:invalid_context, issue, [])

    assert {:error, :invalid_prompt_context} =
             PromptBuilder.build_prompt_bundle(
               %{context | target: %{context.target | repo_policy: nil}},
               issue,
               []
             )

    malformed_manifest =
      context.target.repo_policy["manifest"]
      |> Map.put("workflow", :malformed)

    malformed_context =
      prompt_execution_context(issue, nil, %{"profile" => "strict"},
        manifest: malformed_manifest,
        resolution: context.target.repo_policy["workflow_module_resolution"]
      )

    assert {:error, :invalid_prompt_context} =
             PromptBuilder.build_prompt_bundle(malformed_context, issue, [])
  end

  test "context prompt bundle validates every pinned module resolution field" do
    issue = %Issue{id: "issue-410", identifier: "SID-410"}

    invalid_resolutions = [
      nil,
      %{
        "module_names" => ["linear-operation"],
        "module_refs" => "linear-operation@v1",
        "policy_hash" => "sha256:" <> String.duplicate("b", 64),
        "rendered" => "pinned module text"
      },
      %{
        "module_names" => ["linear-operation"],
        "module_refs" => ["linear-operation@v1"],
        "policy_hash" => "sha256:" <> String.duplicate("b", 64),
        "rendered" => "pinned module text"
      }
    ]

    for resolution <- invalid_resolutions do
      context =
        prompt_execution_context(issue, "pinned", %{"profile" => "strict"}, resolution: resolution)

      assert {:error, :invalid_prompt_context} =
               PromptBuilder.build_prompt_bundle(context, issue, [])
    end
  end

  test "context prompt rejects stale or forged resolution before parsing a pinned template" do
    issue = %Issue{id: "issue-410", identifier: "SID-410"}
    context = prompt_execution_context(issue, "{% if", %{"profile" => "strict"})
    resolution = context.target.repo_policy["workflow_module_resolution"]

    hostile_resolutions = [
      Map.put(resolution, "policy_hash", "sha256:" <> String.duplicate("f", 64)),
      Map.put(resolution, "rendered", "forged module text"),
      update_in(resolution, ["module_refs"], fn [first | rest] ->
        [Map.put(first, "forged", "secret-sentinel-resolution") | rest]
      end)
    ]

    for hostile_resolution <- hostile_resolutions do
      hostile_context =
        put_in(
          context.target.repo_policy["workflow_module_resolution"],
          hostile_resolution
        )

      assert {:error, :invalid_prompt_context} =
               PromptBuilder.build_prompt_bundle(hostile_context, issue, [])
    end
  end

  test "context prompt compilation maps manifest raise throw and exit to one fixed error" do
    issue = %Issue{id: "issue-410", identifier: "SID-410"}
    assert {:ok, manifest} = Manifest.read(repo_manifest_path(), repo_setup?: false)
    secret = "secret-sentinel-prompt-compile"

    valid_resolution =
      issue
      |> prompt_execution_context("pinned prompt", %{"profile" => "strict"})
      |> then(& &1.target.repo_policy["workflow_module_resolution"])

    for mode <- [:raise, :throw, :exit] do
      failing_manifest =
        Map.put(
          manifest,
          "validation",
          %SymphonyElixir.PromptBuilderAccessFailure{mode: mode, secret: secret}
        )

      context =
        prompt_execution_context(issue, "pinned prompt", %{"profile" => "strict"},
          manifest: failing_manifest,
          resolution: valid_resolution
        )

      assert {:error, :invalid_prompt_context} =
               PromptBuilder.build_prompt_bundle(context, issue, [])
    end
  end

  test "concurrent context prompt bundles remain isolated after workflow globals change" do
    issue_a = %Issue{id: "issue-a", identifier: "SID-A"}
    issue_b = %Issue{id: "issue-b", identifier: "SID-B"}
    context_a = prompt_execution_context(issue_a, "A={{ policy.profile }}", %{"profile" => "alpha"})
    context_b = prompt_execution_context(issue_b, "B={{ policy.profile }}", %{"profile" => "beta"})
    previous_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_profile = Application.get_env(:symphony_elixir, :workflow_profile_override)

    on_exit(fn ->
      restore_application_env(:workflow_file_path, previous_path)
      restore_application_env(:workflow_profile_override, previous_profile)
    end)

    parent = self()

    task_a =
      Task.async(fn ->
        send(parent, {:prompt_ready, self()})
        receive do: (:continue -> PromptBuilder.build_prompt_bundle(context_a, issue_a, []))
      end)

    task_b =
      Task.async(fn ->
        send(parent, {:prompt_ready, self()})
        receive do: (:continue -> PromptBuilder.build_prompt_bundle(context_b, issue_b, []))
      end)

    assert_receive {:prompt_ready, task_a_pid}
    assert_receive {:prompt_ready, task_b_pid}

    Application.put_env(:symphony_elixir, :workflow_file_path, "/poisoned/manifest")
    Config.set_profile_override("poisoned")
    send(task_a_pid, :continue)
    send(task_b_pid, :continue)

    assert {:ok, %{prompt: prompt_a}} = Task.await(task_a)
    assert {:ok, %{prompt: prompt_b}} = Task.await(task_b)
    assert prompt_a =~ "A=alpha"
    assert prompt_b =~ "B=beta"
    refute prompt_a =~ "beta"
    refute prompt_b =~ "alpha"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder falls back to no selected policy context when config policy is unavailable" do
    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0, prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-781",
      title: "Invalid policy",
      description: "Render without policy context",
      state: "Todo",
      url: "https://example.org/issues/MT-781",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt == "Ticket MT-781"
    refute prompt =~ "Selected Workflow Profile"
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing manifest",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder reports invalid manifests without recoverable prompt templates" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    invalid_manifest =
      Path.join(System.tmp_dir!(), "invalid-workflow-#{System.unique_integer([:positive])}.yml")

    File.write!(invalid_manifest, """
    version: 1
    project:
      slug: target-repo
      repository: github.com/example/target-repo
    delivery:
      pr_target: main
    runtime:
      codex:
        command: codex app-server
    """)

    Workflow.set_workflow_file_path(invalid_manifest)

    issue = %Issue{
      identifier: "MT-782",
      title: "Invalid workflow",
      description: "Manifest cannot provide fallback prompt",
      state: "Todo",
      url: "https://example.org/issues/MT-782",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable: \{:invalid_manifest,/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo symphony.yml renders generated prompt correctly" do
    workflow_path = Workflow.workflow_file_path()
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    Workflow.set_workflow_file_path(repo_manifest_path())
    System.put_env("LINEAR_API_KEY", "manifest-token")

    issue = %Issue{
      identifier: "MT-616",
      title: "Use generated manifests",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-generated-manifests",
      labels: ["templating", "workflow"]
    }

    on_exit(fn ->
      Workflow.set_workflow_file_path(workflow_path)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    prompt_bundle = PromptBuilder.build_prompt_bundle(issue, attempt: 2)
    prompt = prompt_bundle.prompt

    assert prompt =~ "Role: You are an autonomous software-engineering agent resolving Linear ticket `MT-616`."
    assert prompt =~ "Project slug: symphony"
    assert prompt =~ "Repository: https://github.com/apontarelli/symphony"
    assert prompt =~ "## Core Workflow Modules"
    assert prompt =~ "Use Linear as the tracker"
    assert prompt =~ "Run Codex with the configured runtime settings"
    assert prompt =~ "Validation commands:\n- all: cd elixir && mise exec -- make all"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use generated manifests"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-generated-manifests"
    assert prompt =~ "Final responses report completed actions and blockers only."
    assert prompt =~ "### Land Merge"
    assert prompt =~ "Merging, locate the attached PR"
    assert prompt =~ "Autonomy and boundaries:"
    assert prompt =~ "End the turn after reaching the workflow-defined handoff or terminal state."
    assert prompt =~ "Stop early only when required auth, permissions, secrets, or tools are unavailable"
    assert prompt =~ "Omit generic summaries and user follow-up steps."
    assert prompt_bundle.workflow_module_resolution.policy_hash =~ ~r/^sha256:[a-f0-9]{64}$/
    assert %{name: "linear-operation", version: "v1"} in prompt_bundle.workflow_module_resolution.module_refs
    refute prompt =~ ".codex/skills"
    refute prompt =~ "## Related skills"
    refute prompt =~ ~r/symphony-(linear|commit|pull|quality-gates|review|push|land|debug|project-closeout)/
    assert prompt =~ "never bypass it with a direct merge command"
    assert prompt =~ "Auto-land route classification"
    assert prompt =~ "structured completion evidence"
    assert prompt =~ "changed_files"
    assert prompt =~ "dry-run auto-land"
    assert prompt =~ "auto-land as guarded landing"
    assert prompt =~ "auto_land.dry_run: false"
    assert prompt =~ "route the issue to Merging"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt 2"
    assert prompt =~ "## Selected Workflow Profile"
    assert prompt =~ "Workpad stamp: `Policy: profile=default target=main policy_ref="
    assert prompt =~ "checks: {"
    assert prompt =~ "cd elixir && mise exec -- make all"
    assert prompt =~ "completion_requirements: Run the strongest feasible validation gate before handoff."
  end

  test "prompt renders non-main delivery policy context and gates" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(repo_manifest_path())

    issue = %Issue{
      identifier: "MT-617",
      title: "Use project branch target",
      description: "Render profile-specific policy",
      state: "In Progress",
      url: "https://example.org/issues/MT-617/use-project-branch-target",
      labels: ["workflow"]
    }

    policy = %{
      "policy_ref" => "abc123def456",
      "delivery" => %{"pr_target" => "project/integration"},
      "checks" => ["mix test", "mix credo"],
      "completion_requirements" => ["Attach PR to Linear", "Run profile gate"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, policy: policy)

    assert prompt =~ "Workpad stamp: `Policy: profile=default target=project/integration policy_ref=abc123def456`"
    assert prompt =~ "checks: mix test"
    assert prompt =~ "checks: mix credo"
    assert prompt =~ "completion_requirements: Attach PR to Linear"
    assert prompt =~ "completion_requirements: Run profile gate"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2, policy: %{})

    assert prompt == "Retry #2"
  end

  test "explicit config helpers use only supplied settings and loaded workflow" do
    assert {:ok, settings} =
             Schema.parse(%{
               "workspace" => %{"root" => "/tmp/explicit-workspaces"},
               "agent" => %{
                 "default_runner" => "explicit",
                 "max_concurrent_agents" => 7,
                 "max_concurrent_startups" => 5,
                 "max_concurrent_agents_by_state" => %{"In Progress" => 3}
               },
               "runners" => %{
                 "explicit" => %{
                   "kind" => "codex_app_server",
                   "command" => ["explicit-codex", "app-server"],
                   "approval_policy" => "never",
                   "thread_sandbox" => "workspace-write",
                   "turn_timeout_ms" => 111,
                   "read_timeout_ms" => 222,
                   "stall_timeout_ms" => 0,
                   "max_concurrent_startups" => 2
                 }
               },
               "profiles" => %{
                 "default" => %{"delivery" => %{"pr_target" => "main"}},
                 "strict" => %{
                   "delivery" => %{"pr_target" => "human-review"},
                   "checks" => ["mix test"]
                 }
               }
             })

    loaded = %{
      prompt_template: "Pinned prompt",
      workflow_module_resolution: %{
        module_names: ["base"],
        module_refs: [%{name: "base", version: 1}],
        policy_hash: "modules-hash",
        rendered: "Pinned prompt"
      }
    }

    issue = %Issue{
      id: "issue-explicit-config",
      identifier: "SID-EXPLICIT",
      title: "Use explicit config",
      state: "In Progress",
      project_id: "project-id",
      project_slug: "project-slug",
      labels: []
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/tmp/poisoned-workspaces",
      profiles: %{default: %{delivery: %{pr_target: "poisoned"}}}
    )

    Config.set_profile_override("poisoned")

    assert {:ok, explicit_policy} = Config.effective_policy(settings, "strict")
    assert explicit_policy["checks"] == ["mix test"]

    assert {:ok, issue_policy} =
             Config.issue_policy(settings, issue, profile_override: "strict")

    assert issue_policy["delivery"] == %{"pr_target" => "human-review"}
    assert get_in(issue_policy, ["policy_metadata", "profile"]) == "strict"
    assert Config.max_concurrent_agents_for_state(settings, "In Progress") == 3
    assert Config.max_concurrent_agents_for_state(settings, "Closed") == 7
    assert Config.default_runner_name(settings) == "explicit"
    assert Config.runner_turn_timeout_ms(settings) == 111
    assert Config.runner_read_timeout_ms(settings) == 222
    assert Config.runner_stall_timeout_ms(settings) == 0
    assert Config.max_concurrent_startups(settings) == 2

    assert [sandbox_root] =
             Config.codex_turn_sandbox_policy(settings, "/tmp/explicit-workspace")["writableRoots"]

    assert Path.basename(sandbox_root) == "explicit-workspace"

    assert {:ok, runtime} =
             Config.codex_runtime_settings(settings, "/tmp/explicit-workspace", [])

    assert runtime.approval_policy == "never"
    assert runtime.thread_sandbox == "workspace-write"
    assert Config.workflow_prompt(loaded) == "Pinned prompt"
    assert Config.workflow_module_resolution(loaded) == loaded.workflow_module_resolution
  end

  defp prompt_execution_context(issue, prompt_template, policy, opts \\ []) do
    hash = "sha256:" <> String.duplicate("a", 64)
    {:ok, base_manifest} = Manifest.read(repo_manifest_path(), repo_setup?: false)

    manifest =
      Keyword.get_lazy(opts, :manifest, fn ->
        Map.put(base_manifest, "prompt_template", prompt_template)
      end)

    resolution =
      Keyword.get_lazy(opts, :resolution, fn ->
        manifest
        |> Manifest.compile()
        |> Map.fetch!(:workflow_module_resolution)
        |> prompt_resolution_projection()
      end)

    target = %TargetContext{
      target_id: Keyword.get(opts, :target_id, "alpha"),
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: hash,
      policy_hash: hash,
      repo_manifest_hash: hash,
      repo_policy: %{
        "manifest" => manifest,
        "manifest_source_dir" => Path.expand("context-manifest"),
        "workflow_module_resolution" => resolution
      },
      tracker_connection: %{},
      run_target: %{},
      worktree_policy: %{
        "root" => Path.expand("context-worktrees"),
        "strategy" => "per_issue",
        "hooks" => %{
          "after_create" => nil,
          "after_run" => nil,
          "before_remove" => nil,
          "before_run" => nil,
          "timeout_ms" => 1_000
        }
      },
      runner_policy: %{},
      effective_checks: %{},
      external_side_effect_gates: %{},
      capacity_limits: %{},
      budget_limits: %{}
    }

    %ExecutionContext{
      target: target,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      workspace_path: Path.join([Path.expand("context-worktrees"), target.target_id, issue.identifier]),
      runner_name: "codex",
      runner_config: %{},
      policy: policy,
      role: :implementation,
      execution_profile: %{},
      timeout_ms: 1_000,
      max_retries: 0,
      worker_host: nil
    }
  end

  defp prompt_resolution_projection(resolution) do
    %{
      "module_names" => resolution.module_names,
      "module_refs" =>
        Enum.map(resolution.module_refs, fn ref ->
          %{"name" => ref.name, "version" => ref.version}
        end),
      "policy_hash" => resolution.policy_hash,
      "rendered" => resolution.rendered
    }
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp repo_manifest_path, do: Path.expand("../../../symphony.yml", __DIR__)
end
