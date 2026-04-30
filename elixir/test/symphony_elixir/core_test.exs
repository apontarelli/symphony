defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Config.ProfileBindingAdmin
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
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
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

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

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
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
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
                 "non_map_delivery" => %{"delivery" => "main"}
               }
             })

    assert message =~ "default.policy_ref is reserved"
    assert message =~ "not_a_map profile must be a map"
    assert message =~ "non_string_pr_target.delivery.pr_target must be a string"
    assert message =~ "non_map_delivery.delivery must be a map"
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
        default: %{delivery: %{pr_target: "Human Review"}},
        strict: %{
          delivery: %{pr_target: "Merging"},
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
        "source" => "project_binding",
        "profile" => "strict"
      })

    prompt = PromptBuilder.build_prompt(issue, policy: policy)

    assert prompt =~ "Shared repository rule for SID-PROMPT."
    assert prompt =~ "## Selected Workflow Profile"
    assert prompt =~ "Policy: profile=strict target=Merging policy_ref=#{policy["policy_ref"]}"
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
      "policy_metadata" => %{"source" => "project_binding", "profile" => "strict"}
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

  test "external Linear project binding selects policy and allows label refinement without changing delivery" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}, checks: ["format"]},
        project_alpha: %{delivery: %{pr_target: "project/alpha"}, checks: ["project"]},
        catch_all: %{delivery: %{pr_target: "main"}, checks: ["catch-all"]},
        strict_label: %{append_checks: ["dialyzer"], add_review: %{mode: "strict"}}
      }
    )

    ProfileBindings.set(%{
      team_key: "SID",
      projects: [%{project_slug: "project-a", profile: "project_alpha", pr_target: "project/binding-alpha"}],
      labels: [%{label: "Strict", profile: "strict_label"}],
      catch_all: %{enabled: true, profile: "catch_all"},
      allow_default: true
    })

    issue = %Issue{
      id: "issue-project-a",
      identifier: "SID-101",
      title: "Project-bound dispatch",
      state: "Todo",
      project_slug: "project-a",
      labels: ["strict"]
    }

    assert {:ok, policy} = Config.issue_policy(issue)
    assert policy["delivery"]["pr_target"] == "project/binding-alpha"
    assert policy["checks"] == ["project", "dialyzer"]
    assert policy["review"] == %{"mode" => "strict"}
    assert policy["policy_metadata"]["source"] == "project_binding"
    assert policy["policy_metadata"]["profile"] == "project_alpha"
    assert policy["policy_metadata"]["label_refinement"] == %{"label" => "strict", "profile" => "strict_label"}

    assert PromptBuilder.workpad_policy_stamp(policy) ==
             "Policy: profile=project_alpha target=project/binding-alpha policy_ref=#{policy["policy_ref"]}"
  end

  test "project binding delivery target falls back to selected profile when binding target is absent" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}},
        project_alpha: %{delivery: %{pr_target: "project/alpha"}}
      }
    )

    ProfileBindings.set(%{
      projects: [%{project_slug: "project-a", profile: "project_alpha"}]
    })

    issue = %Issue{
      id: "issue-project-a-fallback",
      identifier: "SID-101B",
      title: "Project-bound fallback dispatch",
      state: "Todo",
      project_slug: "project-a"
    }

    assert {:ok, policy} = Config.issue_policy(issue)
    assert policy["delivery"]["pr_target"] == "project/alpha"
    assert policy["policy_metadata"]["profile"] == "project_alpha"
  end

  test "unprojected Linear issues require explicit catch-all binding" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}},
        project_alpha: %{delivery: %{pr_target: "project/alpha"}},
        catch_all: %{delivery: %{pr_target: "main"}, checks: ["triage"]}
      }
    )

    issue = %Issue{
      id: "issue-unprojected",
      identifier: "SID-102",
      title: "Unprojected issue",
      state: "Todo",
      team_key: "SID",
      labels: []
    }

    ProfileBindings.set(%{
      projects: [%{project_slug: "project-a", profile: "project_alpha"}]
    })

    assert {:skip, :no_matching_linear_profile_binding} = Config.issue_policy(issue)

    ProfileBindings.set(%{
      projects: [%{project_slug: "project-a", profile: "project_alpha"}],
      allow_default: true
    })

    assert {:skip, :no_matching_linear_profile_binding} = Config.issue_policy(issue)

    projected_issue = %{issue | project_slug: "project-b"}
    assert {:ok, default_policy} = Config.issue_policy(projected_issue)
    assert default_policy["policy_metadata"]["source"] == "default"

    ProfileBindings.set(%{
      team_key: "SID",
      projects: [%{project_slug: "project-a", profile: "project_alpha"}],
      catch_all: %{enabled: true, profile: "catch_all"}
    })

    assert {:ok, policy} = Config.issue_policy(issue)
    assert policy["checks"] == ["triage"]
    assert policy["policy_metadata"]["source"] == "catch_all"

    assert {:skip, :linear_catch_all_team_mismatch} =
             Config.issue_policy(%{issue | id: "issue-other-team", team_key: "OTHER"})
  end

  test "legacy Linear default only applies to the configured tracker project" do
    issue = %Issue{
      id: "issue-default",
      identifier: "SID-DEFAULT",
      title: "Default project",
      state: "Todo",
      project_slug: "project"
    }

    assert {:ok, policy} = Config.issue_policy(issue)
    assert policy["policy_metadata"]["source"] == "default"

    assert {:skip, :no_matching_linear_profile_binding} =
             Config.issue_policy(%{issue | id: "issue-other-project", project_slug: "other-project"})

    assert {:skip, :no_matching_linear_profile_binding} =
             Config.issue_policy(%{issue | id: "issue-no-project", project_slug: nil})
  end

  test "loaded empty external bindings do not silently fall back to default" do
    ProfileBindings.set(%{})

    issue = %Issue{
      id: "issue-empty-bindings",
      identifier: "SID-EMPTY",
      title: "Loaded empty bindings",
      state: "Todo",
      project_slug: "project"
    }

    assert {:skip, :no_matching_linear_profile_binding} = Config.issue_policy(issue)
  end

  test "CLI profile override wins for the current process and records metadata" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}},
        project_alpha: %{delivery: %{pr_target: "project/alpha"}},
        override_profile: %{delivery: %{pr_target: "main"}, checks: ["override"]}
      }
    )

    ProfileBindings.set(%{
      projects: [%{project_slug: "project-a", profile: "project_alpha"}]
    })

    issue = %Issue{
      id: "issue-override",
      identifier: "SID-103",
      title: "Override profile",
      state: "Todo",
      project_slug: "project-a",
      labels: []
    }

    ProfileBindings.set_profile_override("override_profile")
    assert {:ok, override_policy} = Config.issue_policy(issue)
    assert override_policy["checks"] == ["override"]
    assert override_policy["policy_metadata"]["source"] == "cli_override"
    assert override_policy["policy_metadata"]["cli_override"] == true

    ProfileBindings.clear_profile_override()
    assert {:ok, project_policy} = Config.issue_policy(issue)
    assert project_policy["delivery"]["pr_target"] == "project/alpha"
    assert project_policy["policy_metadata"]["source"] == "project_binding"
  end

  test "ambiguous same-precedence bindings block policy selection and dispatch logs an actionable signal" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}},
        project_alpha: %{delivery: %{pr_target: "project/alpha"}},
        project_beta: %{delivery: %{pr_target: "main"}}
      }
    )

    issue = %Issue{
      id: "issue-ambiguous",
      identifier: "SID-104",
      title: "Ambiguous project",
      state: "Todo",
      project_slug: "project-a",
      labels: []
    }

    ProfileBindings.set(%{
      projects: [
        %{project_slug: "project-a", profile: "project_alpha"},
        %{project_slug: "project-a", profile: "project_beta"}
      ]
    })

    assert {:error, {:ambiguous_linear_project_profile_binding, _project, _matches}} = Config.issue_policy(issue)

    state = %Orchestrator.State{running: %{}, claimed: MapSet.new(), max_concurrent_agents: 1}

    log =
      capture_log(fn ->
        refute Orchestrator.should_dispatch_issue_for_test(issue, state)
      end)

    assert log =~ "Linear profile binding failed"
    assert log =~ "ambiguous_linear_project_profile_binding"
  end

  test "ambiguous label refinements block policy selection" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}},
        project_alpha: %{delivery: %{pr_target: "project/alpha"}},
        strict_label: %{append_checks: ["dialyzer"]},
        urgent_label: %{append_checks: ["smoke"]}
      }
    )

    ProfileBindings.set(%{
      projects: [%{project_slug: "project-a", profile: "project_alpha"}],
      labels: [
        %{label: "strict", profile: "strict_label"},
        %{label: "urgent", profile: "urgent_label"}
      ]
    })

    issue = %Issue{
      id: "issue-labels",
      identifier: "SID-105",
      title: "Ambiguous labels",
      state: "Todo",
      project_slug: "project-a",
      labels: ["strict", "urgent"]
    }

    assert {:error, {:ambiguous_linear_label_profile_binding, ["strict", "urgent"], _matches}} =
             Config.issue_policy(issue)
  end

  test "project bindings referencing unknown profiles fail validation" do
    ProfileBindings.set(%{
      projects: [%{project_slug: "project-a", profile: "missing"}]
    })

    assert {:error, {:unknown_linear_profile_binding, :project, "missing", {:unknown_workflow_profile, "missing", ["default"]}}} =
             Config.validate!()
  end

  test "duplicate external Linear bindings fail readiness validation" do
    cases = [
      {
        %{
          projects: [
            %{project_slug: "project-a", profile: "default"},
            %{project_slug: "project-a", profile: "strict"}
          ]
        },
        "project bindings contain duplicate selectors: project_slug=project-a"
      },
      {
        %{
          projects: [
            %{project_id: "project-id", profile: "default"},
            %{project_id: "project-id", profile: "strict"}
          ]
        },
        "project bindings contain duplicate selectors: project_id=project-id"
      },
      {
        %{
          labels: [
            %{label: "Strict", profile: "default"},
            %{label: "strict", profile: "strict"}
          ]
        },
        "label bindings contain duplicate selectors: label=strict"
      }
    ]

    for {bindings, expected_message} <- cases do
      ProfileBindings.set(bindings)

      assert {:error, {:invalid_linear_profile_bindings, message}} = Config.validate!()
      assert message =~ expected_message
    end
  end

  test "binding admin saves valid project edits while preserving non-project routing" do
    source_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "ops/bindings.yml")
    ProfileBindings.set_source_path(source_path, true)

    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}},
        strict: %{delivery: %{pr_target: "project/strict"}}
      }
    )

    File.mkdir_p!(Path.dirname(source_path))
    File.write!(source_path, "original: true\n")

    ProfileBindings.set(%{
      team_key: "SID",
      projects: [%{project_slug: "alpha", profile: "default"}],
      labels: [%{label: "Strict", profile: "strict"}],
      catch_all: %{enabled: true, profile: "default"},
      allow_default: true
    })

    assert {:error, {:unknown_linear_profile_binding, :project, "missing", _reason}} =
             ProfileBindingAdmin.save_project_bindings([
               %{selector_kind: "project_slug", selector_value: "beta", profile: "missing", pr_target: nil}
             ])

    assert File.read!(source_path) == "original: true\n"
    assert [%{project_slug: "alpha"}] = ProfileBindings.current().projects

    assert {:ok, bindings} =
             ProfileBindingAdmin.save_project_bindings([
               %{
                 selector_kind: "project_slug",
                 selector_value: "beta",
                 profile: "strict",
                 pr_target: "project/beta"
               }
             ])

    assert bindings.team_key == "SID"
    assert [%{project_slug: "beta", profile: "strict", pr_target: "project/beta"}] = bindings.projects
    assert [%{label: "strict", profile: "strict"}] = bindings.labels
    assert bindings.catch_all == %{enabled: true, profile: "default"}
    assert bindings.allow_default == true

    persisted = File.read!(source_path)
    assert persisted =~ ~s(team_key: "SID")
    assert persisted =~ ~s(project_slug: "beta")
    assert persisted =~ ~s(pr_target: "project/beta")
    assert persisted =~ ~s(label: "strict")

    assert ProfileBindings.current().projects == bindings.projects
  end

  test "linear active project discovery filters project status and deleted records" do
    page_one = %{
      "data" => %{
        "team" => %{
          "projects" => %{
            "nodes" => [
              project_node("active-started", "Active started", "started"),
              project_node("active-planned", "Active planned", "planned"),
              project_node("paused", "Paused", "paused"),
              Map.put(project_node("deleted", "Deleted", "started"), "deletedAt", "2026-04-30T00:00:00Z")
            ],
            "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-2"}
          }
        }
      }
    }

    page_two = %{
      "data" => %{
        "team" => %{
          "projects" => %{
            "nodes" => [
              project_node("active-backlog", "Active backlog", "backlog"),
              project_node("completed", "Completed", "completed")
            ],
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      }
    }

    {:ok, projects} =
      Client.fetch_active_projects_for_test(%{team_id: "team-1"}, fn _query, variables ->
        case variables do
          %{after: nil} -> {:ok, page_one}
          %{after: "cursor-2"} -> {:ok, page_two}
        end
      end)

    assert Enum.map(projects, & &1.slug_id) == ["active-started", "active-planned", "active-backlog"]
    assert Enum.map(projects, & &1.status_type) == ["started", "planned", "backlog"]
  end

  test "malformed external Linear bindings fail validation" do
    cases = [
      {%{projects: [%{project_id: "project-id", project_slug: "project-a", profile: "default"}]}, "project bindings require exactly one of project_id or project_slug"},
      {%{projects: %{}}, "projects must be a list"},
      {%{projects: ["project-a"]}, "projects[0] must be a map"},
      {%{projects: [%{project_slug: "project-a", profile: "default", pr_target: 123}]}, "projects[0] pr_target must be a string"},
      {%{labels: %{}}, "labels must be a list"},
      {%{labels: ["strict"]}, "labels[0] must be a map"},
      {%{catch_all: []}, "catch_all must be a map or profile string"},
      {%{catch_all: %{enabled: true, profile: "default"}}, "catch_all requires exactly one of team_id or team_key"},
      {%{team_id: "team-id", team_key: "SID", catch_all: %{enabled: true, profile: "default"}}, "catch_all requires exactly one of team_id or team_key"}
    ]

    for {bindings, expected_message} <- cases do
      ProfileBindings.set(bindings)

      assert {:error, {:invalid_linear_profile_bindings, message}} = Config.validate!()
      assert message =~ expected_message
    end
  end

  test "label refinement cannot override project delivery target" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}},
        project_alpha: %{delivery: %{pr_target: "project/alpha"}},
        strict_label: %{delivery: %{pr_target: "main"}}
      }
    )

    ProfileBindings.set(%{
      projects: [%{project_slug: "project-a", profile: "project_alpha", pr_target: "project/binding-alpha"}],
      labels: [%{label: "strict", profile: "strict_label"}]
    })

    issue = %Issue{
      id: "issue-delivery-override",
      identifier: "SID-106",
      title: "Unsafe label delivery override",
      state: "Todo",
      project_slug: "project-a",
      labels: ["strict"]
    }

    assert {:error, {:refinement_delivery_target_override, "strict_label", "project/binding-alpha", "main"}} =
             Config.issue_policy(issue)
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

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert is_binary(Map.get(tracker, "project_slug"))
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "git clone --depth 1 https://github.com/openai/symphony ."
    assert Map.get(hooks, "after_create") =~ "cd elixir && mise trust"
    assert Map.get(hooks, "after_create") =~ "mise exec -- mix deps.get"
    assert Map.get(hooks, "before_remove") =~ "cd elixir && mise exec -- mix workspace.before_remove"

    profiles = Map.get(config, "profiles", %{})
    assert get_in(profiles, ["default", "delivery", "pr_target"]) == "main"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
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

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
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
        tracker_active_states: ["Todo", "In Progress", "In Review"],
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
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
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
        tracker_active_states: ["Todo", "In Progress", "In Review"],
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
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
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
        tracker_active_states: ["Todo", "In Progress", "In Review"],
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
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
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
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
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
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, sent_at_ms, 500, 1_100)
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
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
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

  defp assert_due_in_range(due_at_ms, sent_at_ms, min_delay_ms, max_remaining_ms) do
    delay_ms = due_at_ms - sent_at_ms
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert delay_ms >= min_delay_ms
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

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
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

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Resolved workflow policy:"
    assert prompt =~ ~s("pr_target": "main")
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ policy_json }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
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
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on a Linear ticket `MT-616`"
    assert prompt =~ "Resolved workflow policy:"
    assert prompt =~ ~s("pr_target": "main")
    assert prompt =~ "Delivery target rules:"
    assert prompt =~ "Treat `policy.delivery.pr_target` as the Git PR base branch"
    assert prompt =~ "If the target is `main`, preserve the existing mainline pull/push/review/land behavior."
    assert prompt =~ "If the target is not `main`, pull from `origin/<target>`"
    assert prompt =~ "profile-specific gates and completion requirements"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "This is an unattended orchestration session."
    assert prompt =~ "Only stop early for a true blocker"
    assert prompt =~ "Do not include \"next steps for user\""
    assert prompt =~ "open and follow `.codex/skills/land/SKILL.md`"
    assert prompt =~ "Do not call `gh pr merge` directly"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
  end

  test "in-repo WORKFLOW.md renders non-main delivery policy context and gates" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

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

    assert prompt =~ ~s("pr_target": "project/integration")
    assert prompt =~ ~s("mix test")
    assert prompt =~ ~s("Run profile gate")
    assert prompt =~ "If the target is not `main`, pull from `origin/<target>`"
    assert prompt =~ "never merge or promote anything to `main` in v1"
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

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
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

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
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
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
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
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
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

  defp project_node(slug_id, name, status_type) do
    %{
      "id" => "project-#{slug_id}",
      "name" => name,
      "slugId" => slug_id,
      "archivedAt" => nil,
      "deletedAt" => nil,
      "status" => %{
        "name" => name,
        "type" => status_type
      }
    }
  end
end
