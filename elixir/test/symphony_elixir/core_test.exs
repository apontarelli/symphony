defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Config.Schema

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
    assert get_in(config, ["issue_markers", "labels"]) == []
    assert get_in(config, ["workflow_modules", "product_visual_review", "route_policy"]) == "auto"

    profiles = Map.get(config, "profiles", %{})
    assert get_in(profiles, ["default", "delivery", "pr_target"]) == "main"

    assert String.trim(prompt) != ""
    assert prompt =~ "You are working on a Linear ticket `{{ issue.identifier }}`"
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
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile stops running issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "issue-unlabeled"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-562",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-562",
            state: "In Progress",
            labels: ["symphony"]
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-562",
      state: "In Progress",
      title: "Opted out active issue",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile releases a blocked issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "blocked-unlabeled"

    state = %Orchestrator.State{
      blocked: %{
        issue_id => %{
          identifier: "MT-564",
          error: "operator input required",
          worker_host: nil
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-564",
      title: "Blocked but opted out",
      state: "In Progress",
      labels: []
    }

    updated_state = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.blocked, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
  end

  test "retry releases its claim when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "retry-unlabeled"

    state = %Orchestrator.State{
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-565",
      title: "Retry opted out",
      state: "In Progress",
      labels: []
    }

    updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
        identifier: issue.identifier,
        error: "agent exited"
      })

    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
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
    fetcher = fn ["issue-label-continuation"] -> {:ok, [refreshed_issue]} end

    assert {:done, ^refreshed_issue} =
             AgentRunner.continue_with_issue_for_test(issue, fetcher)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    sent_at_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)

    assert %{
             route: "human_review",
             target_state: "Human Review",
             summary: "Human review required for risky or policy-protected work."
           } = state.handoff_routes[issue_id]

    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, sent_at_ms, 500, 1_100)
  end

  test "normal worker exit with blocked completion records blocker without retrying" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue_id = "issue-blocked-completion"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :BlockedCompletionOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-723",
      issue: %Issue{id: issue_id, identifier: "MT-723", state: "In Progress"},
      session_id: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:runtime_event, issue_id,
       %{
         event: :turn_completed,
         timestamp: DateTime.utc_now(),
         completion: %{
           outcome: :blocked,
           blocker: %{
             reason: "Stripe and Cloudflare staging access are required.",
             required_action: "Provide Stripe test credentials and Cloudflare Access authorization."
           }
         }
       }}
    )

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{
             route: "blocked",
             target_state: "Human Review",
             recommendation: "Provide Stripe test credentials and Cloudflare Access authorization."
           } = state.handoff_routes[issue_id]

    assert_receive {:memory_tracker_comment, ^issue_id, route_comment}
    assert route_comment =~ "blocked"
    assert route_comment =~ "Stripe and Cloudflare staging access are required."
    assert route_comment =~ "Provide Stripe test credentials and Cloudflare Access authorization."
    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}
  end

  test "failed worker exit with blocked completion records blocker without retrying" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue_id = "issue-blocked-failed-exit"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :BlockedFailedExitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-724",
      issue: %Issue{id: issue_id, identifier: "MT-724", state: "In Progress"},
      session_id: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:runtime_event, issue_id,
       %{
         event: :agent_blocked,
         timestamp: DateTime.utc_now(),
         completion: %{
           outcome: :blocked,
           blocker: %{
             reason: "Codex app-server rejected Symphony's request as invalid: unknown variant `reject`.",
             required_action: "Update Codex configuration for the installed app-server schema."
           }
         }
       }}
    )

    send(pid, {:DOWN, ref, :process, self(), {%RuntimeError{message: "Agent run failed"}, []}})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{
             route: "blocked",
             target_state: "Human Review",
             recommendation: "Update Codex configuration for the installed app-server schema."
           } = state.handoff_routes[issue_id]

    assert_receive {:memory_tracker_comment, ^issue_id, route_comment}
    assert route_comment =~ "unknown variant `reject`"
    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}
  end

  test "normal worker exit persists route decision from completion metadata" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue_id = "issue-route-completion"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :RouteCompletionOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    workspace_root = Path.join(System.tmp_dir!(), "symphony-elixir-route-completion-#{System.unique_integer([:positive])}")
    workspace = Path.join(workspace_root, "MT-ROUTE")
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join([workspace, "lib", "route.ex"]), "defmodule Route, do: nil\n")

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(workspace_root)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-ROUTE",
      issue: %Issue{id: issue_id, identifier: "MT-ROUTE", state: "In Progress"},
      session_id: nil,
      workspace_path: workspace,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:runtime_event, issue_id,
       %{
         event: :turn_completed,
         timestamp: DateTime.utc_now(),
         payload: %{
           "params" => %{
             "completion" => %{
               checks: [%{name: "mix test", status: :passed}],
               review: %{status: :decision_needed},
               changed_surfaces: [:domain],
               changed_files: ["lib/route.ex"],
               decision: %{
                 question: "Choose handoff route",
                 recommendation: "Keep Human Review for v1",
                 options: [
                   %{id: "hold", label: "Keep Human Review", description: "Conservative route."}
                 ]
               }
             }
           }
         }
       }}
    )

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{
             route: "decision_needed",
             target_state: "Human Review",
             summary: "Choose handoff route",
             recommendation: "Keep Human Review for v1",
             options: [%{id: "hold", label: "Keep Human Review"}]
           } = state.handoff_routes[issue_id]

    assert_receive {:memory_tracker_comment, ^issue_id, route_comment}
    assert route_comment =~ "### Handoff Route"
    assert route_comment =~ "decision_needed"
    assert route_comment =~ "change_manifest"
    assert route_comment =~ "Keep Human Review"
    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}
  end

  test "normal worker exit uses host policy and issue labels for auto-land routing" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue_id = "issue-route-host-policy"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :RouteHostPolicyOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    workspace_root = Path.join(System.tmp_dir!(), "symphony-elixir-route-host-policy-#{System.unique_integer([:positive])}")
    workspace = Path.join(workspace_root, "MT-HOST")
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join([workspace, "lib", "route.ex"]), "defmodule Route, do: nil\n")

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(workspace_root)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-HOST",
      issue: %Issue{id: issue_id, identifier: "MT-HOST", state: "In Progress", labels: ["no-auto-land"]},
      session_id: nil,
      workspace_path: workspace,
      policy: %{
        project: %{criticality: "prototype", deployment_coupling: "none"},
        auto_land: %{posture: "permissive", dry_run: false}
      },
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:runtime_event, issue_id,
       %{
         event: :turn_completed,
         timestamp: DateTime.utc_now(),
         completion: %{
           checks: auto_land_checks(),
           pr_feedback: clean_pr_feedback(),
           review: %{status: :clean},
           changed_surfaces: [:docs],
           changed_files: ["lib/route.ex"],
           policy: %{
             project: %{criticality: "prototype", deployment_coupling: "none"},
             auto_land: %{posture: "permissive", dry_run: false}
           }
         }
       }}
    )

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{
             route: "human_review",
             target_state: "Human Review"
           } = state.handoff_routes[issue_id]

    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    sent_at_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, sent_at_ms, 39_500, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    sent_at_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, sent_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
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

  defp assert_due_in_range(due_at_ms, sent_at_ms, min_delay_ms, max_remaining_ms) do
    delay_ms = due_at_ms - sent_at_ms
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)
    measured_min_remaining_ms = max(1, min_delay_ms - 500)

    assert delay_ms >= min_delay_ms
    assert remaining_ms >= measured_min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

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

    assert prompt =~ "You are working on a Linear ticket `MT-777`"
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

    assert prompt =~ "You are working on a Linear ticket `MT-616`"
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
    assert prompt =~ "This is an unattended orchestration session."
    assert prompt =~ "Only stop early for a true blocker"
    assert prompt =~ "Do not include next steps for the user."
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

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        project_slug: "project",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        project_slug: "project",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:workflow_module_resolution, "issue-live-updates",
                      %{
                        policy_hash: workflow_module_policy_hash,
                        module_refs: workflow_module_refs,
                        modules: workflow_modules_with_config
                      }},
                     500

      assert workflow_module_policy_hash =~ ~r/^sha256:[a-f0-9]{64}$/
      assert %{name: "linear-operation", version: "v1"} in workflow_module_refs
      assert Enum.any?(workflow_modules_with_config, &(&1.id == "linear-operation" and is_map(&1.config)))

      assert_receive {:runtime_event, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id,
                        workflow_module_policy_hash: workflow_module_policy_hash,
                        workflow_modules: workflow_modules
                      }},
                     500

      assert session_id == "thread-live-turn-live"
      assert workflow_module_policy_hash =~ ~r/^sha256:[a-f0-9]{64}$/
      assert %{name: "linear-operation", version: "v1"} in workflow_modules
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner reports codex invalid request schema errors as blocked completion" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-invalid-codex-schema-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          3)
            printf '%s\\n' '{"id":2,"error":{"code":-32600,"message":"Invalid request: unknown variant `reject`, expected one of `untrusted`, `on-failure`, `on-request`, `granular`, `never`"}}'
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: %{"reject" => %{"sandbox_approval" => true}}
      )

      issue = %Issue{
        id: "issue-invalid-codex-schema",
        identifier: "MT-32600",
        title: "Invalid Codex schema",
        description: "Codex rejects a deterministic app-server request schema.",
        state: "In Progress",
        url: "https://example.org/issues/MT-32600",
        project_slug: "project",
        labels: []
      }

      assert_raise RuntimeError, ~r/unknown variant `reject`/, fn ->
        AgentRunner.run(issue, self())
      end

      assert_received {:runtime_event, "issue-invalid-codex-schema",
                       %{
                         event: :agent_blocked,
                         timestamp: %DateTime{},
                         completion: %{
                           outcome: :blocked,
                           blocker: %{
                             reason: reason,
                             required_action: required_action
                           }
                         }
                       }}

      assert reason =~ "Codex app-server rejected Symphony's request as invalid"
      assert reason =~ "unknown variant `reject`"
      assert required_action =~ "installed Codex app-server schema"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner completes with empty CODEX_HOME and bundled workflow modules" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-no-global-skills-#{System.unique_integer([:positive])}"
      )

    previous_codex_home = System.get_env("CODEX_HOME")
    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

    on_exit(fn ->
      restore_env("CODEX_HOME", previous_codex_home)
      restore_env("SYMP_TEST_CODEx_TRACE", previous_trace)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      empty_codex_home = Path.join(test_root, "codex-home")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-no-global-skills.trace")

      File.mkdir_p!(empty_codex_home)
      System.put_env("CODEX_HOME", empty_codex_home)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-no-global-skills.trace}"
      printf 'CODEX_HOME:%s\\n' "${CODEX_HOME:-}" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-no-skills"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-no-skills"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        prompt: "Harness proof\n{{ workflow.modules }}"
      )

      issue = %Issue{
        id: "issue-no-global-skills",
        identifier: "MT-283",
        title: "Run without external delivery skills",
        description: "Prove bundled workflow modules compile into the prompt",
        state: "In Progress",
        url: "https://example.org/issues/MT-283",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 policy: %{},
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      trace = File.read!(trace_file)
      {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)
      expected_codex_home = Path.join([canonical_workspace_root, ".symphony", "codex_home"])

      assert trace =~ "CODEX_HOME:#{expected_codex_home}"
      assert trace =~ "Resolved modules: linear-operation@v1"
      assert trace =~ "Policy hash: sha256:"

      refute trace =~
               ~r/symphony-(linear|commit|pull|quality-gates|review|push|land|debug|project-closeout)/

      refute File.exists?(Path.join(empty_codex_home, "skills"))
      refute File.exists?(Path.join(expected_codex_home, "skills"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state,
             project_slug: "project"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        project_slug: "project",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress",
             project_slug: "project"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        project_slug: "project",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2

      assert_received {:runtime_event, "issue-max-turns",
                       %{
                         event: :agent_max_turns_exhausted,
                         completion: %{
                           outcome: :blocked,
                           blocker: %{
                             reason: "agent.max_turns reached while issue remains active",
                             required_action: required_action
                           }
                         }
                       }}

      assert required_action =~ "Review the workpad"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  defp auto_land_checks do
    ~w(tests quality_gates automated_review route_classification sync)
    |> Enum.map(&%{name: &1, status: :passed})
  end

  defp clean_pr_feedback do
    %{
      status: :none,
      top_level_comments: %{checked: true, source: "gh pr view --comments", unresolved_actionable_count: 0},
      inline_review_comments: %{
        checked: true,
        source: "gh api repos/example/project/pulls/1/comments",
        unresolved_actionable_count: 0
      },
      review_summaries: %{checked: true, source: "gh pr view --json reviews", unresolved_actionable_count: 0}
    }
  end

  defp repo_manifest_path, do: Path.expand("../../../symphony.yml", __DIR__)
end
