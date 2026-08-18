defmodule SymphonyElixir.TargetContextLegacyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunSetup
  alias SymphonyElixir.TargetContext
  alias SymphonyElixir.TargetContext.Legacy
  alias SymphonyElixir.Workflow

  @hash_regex ~r/^sha256:[0-9a-f]{64}$/

  setup do
    on_exit(fn -> RunSetup.clear_current() end)
    :ok
  end

  test "build_at_process_start snapshots the selected workflow and saved run without secret-derived hashes" do
    workspace_root = Path.join(System.tmp_dir!(), "legacy-context-workspaces")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "resolved-secret-one",
      workspace_root: workspace_root,
      max_concurrent_agents: 6,
      max_concurrent_startups: 3,
      runner_max_concurrent_startups: 2,
      profiles: %{default: %{delivery: %{pr_target: "main"}}}
    )

    RunSetup.put_current(%{
      saved_run_name: "saved-run",
      mode: :issue_batch,
      issue_batch_limit: 2,
      profile: "default",
      capacity: %{
        max_concurrent_agents: 4,
        max_concurrent_agents_ceiling: 6,
        max_concurrent_startups: 1,
        max_concurrent_startups_ceiling: 2
      },
      restrictive_flags: [:no_land]
    })

    assert {:ok, %TargetContext{} = context} = Legacy.build_at_process_start([])
    assert context.target_id == "saved-run"
    assert context.state == :active
    assert context.dispatch_mode == :explicit

    assert context.worktree_policy == %{
             "root" => workspace_root,
             "strategy" => "per_issue",
             "hooks" => %{
               "after_create" => nil,
               "before_run" => nil,
               "after_run" => nil,
               "before_remove" => nil,
               "timeout_ms" => 60_000
             }
           }

    assert context.capacity_limits["max_concurrent_agents"] == 4
    assert context.tracker_connection["policy"]["api_key"] == "resolved-secret-one"
    assert Regex.match?(@hash_regex, context.registry_generation)
    assert Regex.match?(@hash_regex, context.policy_hash)
    assert Regex.match?(@hash_regex, context.repo_manifest_hash)

    assert Map.keys(context.repo_policy) |> Enum.sort() == [
             "manifest",
             "manifest_source_dir",
             "workflow_module_resolution"
           ]

    assert context.repo_policy["manifest_source_dir"] ==
             Path.dirname(Path.expand(Workflow.workflow_file_path()))

    module_resolution = context.repo_policy["workflow_module_resolution"]

    assert Map.keys(module_resolution) |> Enum.sort() == [
             "module_names",
             "module_refs",
             "policy_hash",
             "rendered"
           ]

    assert Enum.all?(module_resolution["module_refs"], fn ref ->
             Map.keys(ref) |> Enum.sort() == ["name", "version"]
           end)

    refute inspect(context) =~ "resolved-secret-one"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "resolved-secret-two",
      workspace_root: workspace_root,
      max_concurrent_agents: 6,
      max_concurrent_startups: 3,
      runner_max_concurrent_startups: 2,
      profiles: %{default: %{delivery: %{pr_target: "main"}}}
    )

    assert {:ok, changed_secret} = Legacy.build_at_process_start([])
    assert changed_secret.tracker_connection["policy"]["api_key"] == "resolved-secret-two"
    assert changed_secret.registry_generation == context.registry_generation
    assert changed_secret.policy_hash == context.policy_hash
    assert changed_secret.repo_manifest_hash == context.repo_manifest_hash

    RunSetup.put_current(%{saved_run_name: "poisoned", mode: :drain})

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "poisoned-secret",
      workspace_root: Path.join(System.tmp_dir!(), "poisoned-workspaces"),
      max_concurrent_agents: 1
    )

    assert context.target_id == "saved-run"
    assert context.worktree_policy["root"] == workspace_root
    assert context.capacity_limits["max_concurrent_agents"] == 4
    refute inspect(context) =~ "poisoned-secret"
  end

  test "legacy authority preserves hooks, expands worktree root, and tracks manifest source" do
    relative_root = "tmp/legacy-context-relative-workspaces"
    hook_sentinel = "printf 'token=sk-test-legacy-hook'\nprintf done"
    source_path = Workflow.workflow_file_path()

    write_workflow_file!(source_path,
      workspace_root: relative_root,
      hook_after_create: "",
      hook_before_run: hook_sentinel,
      hook_after_run: " ",
      hook_before_remove: nil,
      hook_timeout_ms: 12_345
    )

    assert {:ok, first} = Legacy.build_at_process_start([])

    assert first.worktree_policy == %{
             "root" => Path.expand(relative_root),
             "strategy" => "per_issue",
             "hooks" => %{
               "after_create" => "",
               "before_run" => hook_sentinel <> "\n",
               "after_run" => "",
               "before_remove" => nil,
               "timeout_ms" => 12_345
             }
           }

    first_source_dir = Path.dirname(Path.expand(source_path))
    assert first.repo_policy["manifest_source_dir"] == first_source_dir
    refute inspect(first) =~ hook_sentinel
    refute inspect(first) =~ first_source_dir

    nested_dir = Path.join(first_source_dir, "nested")
    nested_path = Path.join(nested_dir, "symphony.yml")
    File.mkdir_p!(nested_dir)
    File.cp!(source_path, nested_path)
    Workflow.set_workflow_file_path(nested_path)

    assert {:ok, moved} = Legacy.build_at_process_start([])
    assert moved.repo_policy["manifest_source_dir"] == Path.expand(nested_dir)
    assert moved.repo_manifest_hash == first.repo_manifest_hash
    refute moved.policy_hash == first.policy_hash
    refute moved.registry_generation == first.registry_generation
  end

  test "legacy construction rejects source-less loaded workflow authority" do
    write_workflow_file!(Workflow.workflow_file_path())
    workflow_store = Process.whereis(WorkflowStore)
    assert is_pid(workflow_store)
    original_state = :sys.get_state(workflow_store)

    try do
      :sys.replace_state(workflow_store, fn state ->
        %{state | workflow: Map.delete(state.workflow, :manifest_source_dir)}
      end)

      assert Legacy.build_at_process_start([]) == {:error, :invalid_manifest_source_dir}
    after
      if Process.alive?(workflow_store) do
        :sys.replace_state(workflow_store, fn _state -> original_state end)
      end
    end
  end

  test "saved strict profile remains authoritative after global mutation" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}, checks: ["format"]},
        strict: %{delivery: %{pr_target: "human-review"}, checks: ["mix test"]}
      }
    )

    assert {:ok, %{config: config}} = Workflow.current()
    assert {:ok, settings} = Schema.parse(config)

    issue = %Issue{
      id: "legacy-strict-policy",
      identifier: "SID-LEGACY-STRICT",
      title: "Pinned strict policy",
      state: "Todo",
      project_slug: "project",
      labels: []
    }

    assert {:ok, expected} =
             Config.issue_policy(settings, issue, profile_override: "strict")

    RunSetup.put_current(%{saved_run_name: "strict-run", profile: "strict"})
    assert {:ok, context} = Legacy.build_at_process_start([])

    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "changed-default"}},
        strict: %{delivery: %{pr_target: "changed-strict"}, checks: ["changed"]}
      }
    )

    RunSetup.put_current(%{saved_run_name: "changed-run", profile: "default"})
    Config.set_profile_override("default")
    on_exit(&Config.clear_profile_override/0)

    assert {:ok, actual} = TargetContext.issue_policy(context, issue, profile: "strict")

    expected_base = Map.drop(expected, ["policy_metadata", "policy_ref"])
    assert Map.take(actual, Map.keys(expected_base)) == expected_base
    assert actual["delivery"]["pr_target"] == "human-review"
    assert actual["checks"] == ["mix test"]
    assert actual["policy_metadata"]["profile"] == "strict"

    assert Map.keys(context.repo_policy) |> Enum.sort() == [
             "manifest",
             "manifest_source_dir",
             "workflow_module_resolution"
           ]
  end

  test "saved profile runner restrictions remain authoritative after global mutation" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}},
        strict: %{
          delivery: %{pr_target: "human-review"},
          runners: %{
            codex: %{
              approval_policy: %{
                custom: %{sandbox_approval: false, credentials: %{token: "approval-secret"}}
              },
              thread_sandbox: "workspace-write",
              turn_sandbox_policy: %{
                type: "workspaceWrite",
                networkAccess: false,
                credentials: %{token: "sandbox-secret"}
              }
            }
          }
        }
      }
    )

    RunSetup.put_current(%{saved_run_name: "strict-runners", profile: "strict"})
    assert {:ok, context} = Legacy.build_at_process_start([])

    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}},
        strict: %{
          delivery: %{pr_target: "human-review"},
          runners: %{
            codex: %{
              approval_policy: "never",
              thread_sandbox: "danger-full-access",
              turn_sandbox_policy: %{type: "dangerFullAccess", networkAccess: true}
            }
          }
        }
      }
    )

    assert {:ok, changed_context} = Legacy.build_at_process_start([])
    refute changed_context.policy_hash == context.policy_hash
    refute changed_context.registry_generation == context.registry_generation

    assert {:ok, policy} = issue_policy(context, profile: "strict")

    assert policy["runners"] == %{
             "codex" => %{
               "approval_policy" => %{"custom" => %{"sandbox_approval" => false}},
               "thread_sandbox" => "workspace-write",
               "turn_sandbox_policy" => %{
                 "type" => "workspaceWrite",
                 "networkAccess" => false
               }
             }
           }

    refute inspect(context.issue_policy_authority) =~ "approval-secret"
    refute inspect(context.issue_policy_authority) =~ "sandbox-secret"

    assert {:ok, runtime_settings} =
             Config.codex_runtime_settings(nil, policy: policy)

    assert runtime_settings == %{
             approval_policy: %{"custom" => %{"sandbox_approval" => false}},
             thread_sandbox: "workspace-write",
             turn_sandbox_policy: %{"type" => "workspaceWrite", "networkAccess" => false}
           }
  end

  test "legacy authority returns typed errors for malformed profile runner restrictions" do
    malformed_sandboxes = [
      {%{"type" => 1}, ["type"], :expected_string},
      {%{"networkAccess" => 1}, ["networkAccess"], :expected_boolean},
      {%{"writableRoots" => "/tmp"}, ["writableRoots"], :expected_list},
      {%{"writableRoots" => ["/tmp", 1]}, ["writableRoots", 1], :expected_string},
      {%{"readOnlyAccess" => "fullAccess"}, ["readOnlyAccess"], :expected_map},
      {%{"readOnlyAccess" => %{"type" => 1}}, ["readOnlyAccess", "type"], :expected_string},
      {%{"future" => true}, ["future"], :unsupported_field}
    ]

    for {sandbox, suffix, reason} <- malformed_sandboxes do
      write_workflow_file!(Workflow.workflow_file_path(),
        profiles: %{
          default: %{
            delivery: %{pr_target: "main"},
            runners: %{codex: %{turn_sandbox_policy: sandbox}}
          }
        }
      )

      path = ["runners", "codex", "turn_sandbox_policy" | suffix]

      assert {:error, {:invalid_issue_policy_authority, ^path, ^reason}} =
               Legacy.build_at_process_start([])
    end
  end

  test "legacy authority recursively projects secret-safe approval policy lists" do
    secret = "profile-list-secret"

    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{
          delivery: %{pr_target: "main"},
          runners: %{
            codex: %{
              approval_policy: %{
                custom: %{
                  steps: [
                    %{action: "read", credentials: %{token: secret}},
                    ["nested", %{api_key: secret, enabled: true}]
                  ]
                }
              }
            }
          }
        }
      }
    )

    assert {:ok, context} = Legacy.build_at_process_start([])
    assert {:ok, policy} = issue_policy(context)

    expected_steps = [%{"action" => "read"}, ["nested", %{"enabled" => true}]]

    assert get_in(
             context.issue_policy_authority,
             ["policy", "runners", "codex", "approval_policy", "custom", "steps"]
           ) == expected_steps

    assert get_in(policy, ["runners", "codex", "approval_policy", "custom", "steps"]) ==
             expected_steps

    refute inspect(context) =~ secret
    refute inspect(policy) =~ secret
  end

  test "legacy authority returns typed errors for malformed recursive runner values" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{
          delivery: %{pr_target: "main"},
          append_runners: ["not-a-map"]
        }
      }
    )

    assert {:error, {:invalid_issue_policy_authority, ["runners"], :expected_map}} =
             Legacy.build_at_process_start([])

    malformed_approval_policies = [
      {%{custom: %{rules: ["safe", "__non_json_value__"]}}, ["custom", "rules", 1]},
      {%{custom: %{nested: %{value: "__non_json_value__"}}}, ["custom", "nested", "value"]}
    ]

    for {approval_policy, suffix} <- malformed_approval_policies do
      path = Workflow.workflow_file_path()

      write_workflow_file!(path,
        profiles: %{
          default: %{
            delivery: %{pr_target: "main"},
            runners: %{codex: %{approval_policy: approval_policy}}
          }
        }
      )

      path
      |> File.read!()
      |> String.replace(~s("__non_json_value__"), ".nan")
      |> then(&File.write!(path, &1))

      assert :ok = SymphonyElixir.WorkflowStore.force_reload()

      error_path = ["runners", "codex", "approval_policy" | suffix]

      assert {:error, {:invalid_issue_policy_authority, ^error_path, :expected_json_value}} =
               Legacy.build_at_process_start([])
    end
  end

  test "legacy authority and hashes exclude nested profile runner secrets" do
    build_with_secret = fn secret ->
      write_workflow_file!(Workflow.workflow_file_path(),
        profiles: %{
          default: %{
            delivery: %{pr_target: "main"},
            runners: %{
              codex: %{
                approval_policy: %{
                  custom: %{
                    sandbox_approval: false,
                    nested: %{api_key: secret, credentials: %{token: secret}}
                  }
                },
                thread_sandbox: "workspace-write",
                turn_sandbox_policy: %{
                  type: "workspaceWrite",
                  networkAccess: false,
                  credentials: %{token: secret}
                }
              }
            }
          }
        }
      )

      assert {:ok, context} = Legacy.build_at_process_start([])
      context
    end

    first = build_with_secret.("profile-runner-secret-one")
    rotated = build_with_secret.("profile-runner-secret-two")

    assert rotated.issue_policy_authority == first.issue_policy_authority
    assert rotated.policy_hash == first.policy_hash
    assert rotated.registry_generation == first.registry_generation

    for secret <- ["profile-runner-secret-one", "profile-runner-secret-two"] do
      refute inspect(first.issue_policy_authority) =~ secret
      refute inspect(rotated.issue_policy_authority) =~ secret
    end
  end

  test "legacy approval maps exclude the complete sensitive key family from policy identity" do
    build_with_secret = fn secret ->
      approval_policy = %{
        "custom" => %{
          "rule" => "require-review",
          "max_total_tokens" => 1_000,
          "Api-Key" => secret,
          "AUTHORIZATION" => secret,
          "credential" => %{"nested" => secret},
          "password" => secret,
          "passwd" => secret,
          "secret" => secret,
          "token" => secret,
          "connection string" => secret,
          "private-key" => secret
        }
      }

      write_workflow_file!(Workflow.workflow_file_path(),
        profiles: %{
          default: %{
            delivery: %{pr_target: "main"},
            runners: %{codex: %{approval_policy: approval_policy}}
          }
        }
      )

      assert {:ok, context} = Legacy.build_at_process_start([])
      assert {:ok, policy} = issue_policy(context)
      {context, policy}
    end

    {first, first_policy} = build_with_secret.("approval-family-secret-one")
    {rotated, rotated_policy} = build_with_secret.("approval-family-secret-two")

    expected = %{"custom" => %{"rule" => "require-review", "max_total_tokens" => 1_000}}

    assert get_in(first.issue_policy_authority, ["policy", "runners", "codex", "approval_policy"]) ==
             expected

    assert get_in(first_policy, ["runners", "codex", "approval_policy"]) == expected
    assert rotated.issue_policy_authority == first.issue_policy_authority
    assert rotated_policy == first_policy
    assert rotated.policy_hash == first.policy_hash
    assert rotated.registry_generation == first.registry_generation

    for secret <- ["approval-family-secret-one", "approval-family-secret-two"],
        value <- [first, rotated, first_policy, rotated_policy] do
      refute inspect(value) =~ secret
    end
  end

  test "build_at_process_start accepts a valid policy without a publish target" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{
          delivery: %{pr_target: "main"},
          manifest: %{
            project: %{repository: "https://example.com/project.git"},
            workflow: %{modules: ["delivery.github_pr"]}
          }
        },
        strict: %{delivery: %{pr_target: "Human Review"}}
      }
    )

    RunSetup.put_current(%{profile: "strict"})
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, context} = Legacy.build_at_process_start([])
    refute Map.has_key?(context.issue_policy_authority["policy"], "publish_target")
  end

  test "legacy canonical gates preserve unrestricted issue auto-land posture" do
    assert {:ok, context} = Legacy.build_at_process_start([])

    assert context.external_side_effect_gates == %{
             "tracker_write" => "allow",
             "vcs_publish" => "allow",
             "pull_request_write" => "allow",
             "merge" => "allow",
             "deployment" => "deny",
             "production_data" => "deny"
           }

    context =
      put_in(
        context.repo_policy["manifest"]["auto_land"],
        %{"posture" => "permissive", "dry_run" => false}
      )

    issue = %SymphonyElixir.Linear.Issue{
      id: "legacy-gates",
      identifier: "SID-LEGACY-GATES",
      title: "Legacy side-effect gates",
      state: "Todo",
      project_slug: "project",
      labels: []
    }

    assert {:ok, policy} = TargetContext.issue_policy(context, issue, [])
    assert policy["auto_land"] == %{"posture" => "permissive", "dry_run" => false}
  end

  test "legacy restrictive settings reduce the canonical merge gate" do
    RunSetup.put_current(%{restrictive_flags: [:no_land]})
    assert {:ok, denied} = Legacy.build_at_process_start([])
    assert denied.external_side_effect_gates["merge"] == "deny"

    RunSetup.put_current(%{restrictive_flags: [:human_review_only]})
    assert {:ok, manual} = Legacy.build_at_process_start([])
    assert manual.external_side_effect_gates["merge"] == "manual_approval"

    assert Map.drop(manual.external_side_effect_gates, ["merge"]) ==
             Map.drop(denied.external_side_effect_gates, ["merge"])
  end

  test "no-land overrides human-review-only merge approval" do
    RunSetup.put_current(%{restrictive_flags: [:no_land, :human_review_only]})

    assert {:ok, context} = Legacy.build_at_process_start([])
    assert context.external_side_effect_gates["merge"] == "deny"
  end

  test "no-land overrides a pre-existing human-review route" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{
          delivery: %{pr_target: "main"},
          handoff_route: "human_review"
        }
      }
    )

    RunSetup.put_current(%{restrictive_flags: [:no_land]})

    assert {:ok, context} = Legacy.build_at_process_start([])
    assert context.external_side_effect_gates["merge"] == "deny"
  end

  test "legacy run target projects only known JSON-safe scope fields" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      target: %{
        tracker: "linear",
        type: "query",
        filter: %{priority: %{lte: 2}},
        token: "private-target-token",
        password: "private-target-password",
        unsupported: %{nested: "private-target-value"}
      }
    )

    assert {:ok, context} = Legacy.build_at_process_start([])

    assert context.run_target["tracker"] == "linear"
    assert context.run_target["type"] == "query"
    assert context.run_target["filter"] == %{"priority" => %{"lte" => 2}}
    refute Map.has_key?(context.run_target, "token")
    refute Map.has_key?(context.run_target, "password")
    refute Map.has_key?(context.run_target, "unsupported")
    refute inspect(context.run_target) =~ "private-target"
    assert Enum.all?(Map.keys(context.run_target), &is_binary/1)
  end

  test "legacy policy hash changes with an allowed explicit target scope" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      target: %{tracker: "linear", type: "query", filter: %{priority: %{lte: 2}}}
    )

    assert {:ok, first} = Legacy.build_at_process_start([])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      target: %{tracker: "linear", type: "query", filter: %{priority: %{lte: 1}}}
    )

    assert {:ok, second} = Legacy.build_at_process_start([])
    refute second.run_target == first.run_target
    refute second.policy_hash == first.policy_hash
  end

  test "legacy hashes include the tracker kind" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "https://tracker.example.invalid/graphql"
    )

    assert {:ok, first} = Legacy.build_at_process_start([])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear-enterprise",
      tracker_endpoint: "https://tracker.example.invalid/graphql"
    )

    assert {:ok, second} = Legacy.build_at_process_start([])
    refute second.tracker_connection == first.tracker_connection
    refute second.policy_hash == first.policy_hash
    refute second.registry_generation == first.registry_generation
  end

  test "legacy hashes include the tracker endpoint" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_endpoint: "https://tracker-one.example.invalid/graphql"
    )

    assert {:ok, first} = Legacy.build_at_process_start([])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_endpoint: "https://tracker-two.example.invalid/graphql"
    )

    assert {:ok, second} = Legacy.build_at_process_start([])
    refute second.tracker_connection == first.tracker_connection
    refute second.policy_hash == first.policy_hash
    refute second.registry_generation == first.registry_generation
  end

  test "legacy hashes include allowlisted runner behavior settings" do
    write_secret_workflow!(
      "tracker-secret",
      "target-secret",
      "runner-secret",
      %{"config_path" => "/tmp/opencode-one.json"}
    )

    assert {:ok, first} = Legacy.build_at_process_start([])

    write_secret_workflow!(
      "tracker-secret",
      "target-secret",
      "runner-secret",
      %{"config_path" => "/tmp/opencode-two.json"}
    )

    assert {:ok, second} = Legacy.build_at_process_start([])
    refute second.runner_policy == first.runner_policy
    refute second.policy_hash == first.policy_hash
    refute second.registry_generation == first.registry_generation
  end

  test "legacy hashes OpenCode permission semantics without secret-derived identity" do
    build_with_permissions = fn secret, effect ->
      permissions = %{
        "bash" => %{
          "rules" => [
            "read",
            %{"effect" => effect, "authorization" => secret, "private_key" => secret}
          ]
        },
        "future" => [true, 7, nil]
      }

      write_secret_workflow!(
        "tracker-secret",
        "target-secret",
        secret,
        %{"permissions" => permissions}
      )

      assert {:ok, context} = Legacy.build_at_process_start([])
      context
    end

    first = build_with_permissions.("permission-secret-one", "allow")
    rotated_secret = build_with_permissions.("permission-secret-two", "allow")

    assert rotated_secret.policy_hash == first.policy_hash
    assert rotated_secret.registry_generation == first.registry_generation

    changed_semantics = build_with_permissions.("permission-secret-two", "deny")
    refute changed_semantics.policy_hash == first.policy_hash
    refute changed_semantics.registry_generation == first.registry_generation
  end

  test "legacy runner hashes use nested semantic policy projections" do
    sandbox = %{
      "type" => "workspaceWrite",
      "writableRoots" => ["/tmp/workspace"],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "never",
      codex_turn_sandbox_policy: sandbox
    )

    assert {:ok, first} = Legacy.build_at_process_start([])

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "unless-trusted",
      codex_turn_sandbox_policy: sandbox
    )

    assert {:ok, changed_approval} = Legacy.build_at_process_start([])
    refute changed_approval.policy_hash == first.policy_hash
    refute changed_approval.registry_generation == first.registry_generation

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "never",
      codex_turn_sandbox_policy: Map.put(sandbox, "networkAccess", true)
    )

    assert {:ok, changed_sandbox} = Legacy.build_at_process_start([])
    refute changed_sandbox.policy_hash == first.policy_hash
    refute changed_sandbox.registry_generation == first.registry_generation
  end

  test "legacy construction rejects arbitrary nested runner policy maps with typed errors" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: %{"selected" => %{"allow" => true}}
    )

    assert {:error, {:invalid_runner_policy, ["runners", "codex", "approval_policy"], :unsupported_map}} = Legacy.build_at_process_start([])

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "never",
      codex_turn_sandbox_policy: %{
        "type" => "workspaceWrite",
        "credentials" => %{"token" => "runner-secret"}
      }
    )

    assert {:error, {:invalid_runner_policy, ["runners", "codex", "turn_sandbox_policy", "credentials"], :unsupported_field}} = Legacy.build_at_process_start([])
  end

  test "legacy construction returns typed errors for malformed nested runner sandbox fields" do
    malformed_sandboxes = [
      {%{"type" => 1}, ["type"], :expected_string},
      {%{"type" => "workspaceWrite", "networkAccess" => 1}, ["networkAccess"], :expected_boolean},
      {%{"type" => "workspaceWrite", "writableRoots" => ["/tmp", 1]}, ["writableRoots", 1], :expected_string},
      {%{"type" => "workspaceWrite", "writableRoots" => "/tmp"}, ["writableRoots"], :expected_list},
      {%{"type" => "workspaceWrite", "readOnlyAccess" => %{"type" => "fullAccess", "future" => true}}, ["readOnlyAccess", "future"], :unsupported_field},
      {%{"type" => "workspaceWrite", "readOnlyAccess" => "fullAccess"}, ["readOnlyAccess"], :expected_map}
    ]

    for {sandbox, suffix, reason} <- malformed_sandboxes do
      write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: sandbox)
      path = ["runners", "codex", "turn_sandbox_policy" | suffix]

      assert {:error, {:invalid_runner_policy, ^path, ^reason}} =
               Legacy.build_at_process_start([])
    end
  end

  test "legacy runner projection accepts empty read-only access policy" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{
        "type" => "workspaceWrite",
        "readOnlyAccess" => %{}
      }
    )

    assert {:ok, context} = Legacy.build_at_process_start([])
    assert Regex.match?(@hash_regex, context.policy_hash)
  end

  test "legacy hashes exclude tracker, target, and runner secret content" do
    write_secret_workflow!("tracker-secret-one", "target-secret-one", "runner-secret-one")
    assert {:ok, first} = Legacy.build_at_process_start([])

    write_secret_workflow!("tracker-secret-two", "target-secret-two", "runner-secret-two")
    assert {:ok, second} = Legacy.build_at_process_start([])

    assert second.policy_hash == first.policy_hash
    assert second.registry_generation == first.registry_generation
    assert second.repo_manifest_hash == first.repo_manifest_hash
    assert second.run_target == first.run_target

    assert first.tracker_connection["policy"]["api_key"] == "tracker-secret-one"
    assert second.tracker_connection["policy"]["api_key"] == "tracker-secret-two"
    assert get_in(first.runner_policy, ["runners", "open", "server_auth", "password"]) == "runner-secret-one"
    assert get_in(second.runner_policy, ["runners", "open", "server_auth", "password"]) == "runner-secret-two"
    assert get_in(first.runner_policy, ["runners", "open", "config_content", "private"]) == "runner-secret-one"
    assert get_in(second.runner_policy, ["runners", "open", "config_content", "private"]) == "runner-secret-two"
    refute Map.has_key?(first.run_target, "token")
    refute Map.has_key?(first.run_target, "password")

    for secret <- [
          "tracker-secret-one",
          "target-secret-one",
          "runner-secret-one",
          "tracker-secret-two",
          "target-secret-two",
          "runner-secret-two"
        ] do
      refute inspect(first) =~ secret
      refute inspect(second) =~ secret
    end
  end

  test "legacy hashes project nested target filters and execution profiles" do
    write_nested_hash_workflow!("nested-secret-one", 2, "review/model-one")
    assert {:ok, first} = Legacy.build_at_process_start([])

    write_nested_hash_workflow!("nested-secret-two", 2, "review/model-one")
    assert {:ok, rotated_secret} = Legacy.build_at_process_start([])

    assert rotated_secret.policy_hash == first.policy_hash
    assert rotated_secret.registry_generation == first.registry_generation

    refute get_in(rotated_secret.run_target, ["filter", "priority", "credentials", "token"]) ==
             get_in(first.run_target, ["filter", "priority", "credentials", "token"])

    refute get_in(
             rotated_secret.runner_policy,
             ["runners", "codex", "execution_profiles", "source_reviewer", "private", "token"]
           ) ==
             get_in(
               first.runner_policy,
               ["runners", "codex", "execution_profiles", "source_reviewer", "private", "token"]
             )

    write_nested_hash_workflow!("nested-secret-two", 1, "review/model-one")
    assert {:ok, changed_filter} = Legacy.build_at_process_start([])
    refute changed_filter.policy_hash == first.policy_hash
    refute changed_filter.registry_generation == first.registry_generation

    write_nested_hash_workflow!("nested-secret-two", 2, "review/model-two")
    assert {:ok, changed_profile} = Legacy.build_at_process_start([])
    refute changed_profile.policy_hash == first.policy_hash
    refute changed_profile.registry_generation == first.registry_generation
  end

  test "legacy hashes complete query semantics without secret-derived identity" do
    build_with_query = fn secret, threshold, steps ->
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: nil,
        target: %{
          tracker: "linear",
          type: "query",
          filter: %{
            future_predicate: %{
              threshold: threshold,
              steps: steps,
              authorization: secret
            }
          },
          query: %{
            custom_relation: [
              %{enabled: true, private_key: secret},
              %{"connection-string" => secret, "weight" => 3.5}
            ]
          }
        }
      )

      assert {:ok, context} = Legacy.build_at_process_start([])
      context
    end

    first = build_with_query.("query-secret-one", 2, ["read", "write"])
    rotated_secret = build_with_query.("query-secret-two", 2, ["read", "write"])

    assert rotated_secret.policy_hash == first.policy_hash
    assert rotated_secret.registry_generation == first.registry_generation

    changed_unknown_scalar = build_with_query.("query-secret-two", 1, ["read", "write"])
    refute changed_unknown_scalar.policy_hash == first.policy_hash
    refute changed_unknown_scalar.registry_generation == first.registry_generation

    changed_list_order = build_with_query.("query-secret-two", 2, ["write", "read"])
    refute changed_list_order.policy_hash == first.policy_hash
    refute changed_list_order.registry_generation == first.registry_generation
  end

  test "legacy returns a typed error for non-JSON query semantics" do
    path = Workflow.workflow_file_path()

    write_workflow_file!(path,
      tracker_project_slug: nil,
      target: %{
        tracker: "linear",
        type: "query",
        filter: %{future_predicate: "__non_json_value__"}
      }
    )

    path
    |> File.read!()
    |> String.replace(~s("__non_json_value__"), ".nan")
    |> then(&File.write!(path, &1))

    assert :ok = WorkflowStore.force_reload()

    error_path = ["run_target", "filter", "future_predicate"]

    assert {:error, {:invalid_run_target_policy, ^error_path, :expected_json_value}} =
             Legacy.build_at_process_start([])
  end

  test "legacy authority projects nested policy semantics without secret-derived identity" do
    write_policy_hash_workflow!("nested-policy-secret-one")
    assert {:ok, first} = Legacy.build_at_process_start([])
    assert {:ok, first_issue_policy} = issue_policy(first)

    write_policy_hash_workflow!("nested-policy-secret-two")
    assert {:ok, rotated_secrets} = Legacy.build_at_process_start([])
    assert {:ok, rotated_issue_policy} = issue_policy(rotated_secrets)

    assert rotated_secrets.policy_hash == first.policy_hash
    assert rotated_secrets.registry_generation == first.registry_generation
    assert rotated_secrets.repo_manifest_hash == first.repo_manifest_hash
    assert rotated_issue_policy["policy_ref"] == first_issue_policy["policy_ref"]

    for secret <- ["nested-policy-secret-one", "nested-policy-secret-two"],
        value <- [
          first.issue_policy_authority,
          rotated_secrets.issue_policy_authority,
          first_issue_policy,
          rotated_issue_policy
        ] do
      refute inspect(value) =~ secret
    end

    for overrides <- [
          %{review: %{mode: "advisory"}},
          %{auto_land: %{posture: "strict", dry_run: false}},
          %{delivery: %{pr_target: "human-review"}},
          %{checks: ["mix test"]},
          %{completion_requirements: ["tests-green"]},
          %{review: %{mode: "strict", timeout_ms: 120_000}},
          %{review: %{mode: "strict", max_retries: 0}},
          %{review: %{mode: "strict", command: "review"}},
          %{checks: [%{name: "format", command: "mix format --check-formatted"}]},
          %{review: %{mode: "strict", command: ["review", "--source"]}}
        ] do
      write_policy_hash_workflow!("nested-policy-secret-two", overrides)
      assert {:ok, changed_behavior} = Legacy.build_at_process_start([])
      refute changed_behavior.policy_hash == first.policy_hash
      refute changed_behavior.registry_generation == first.registry_generation
    end
  end

  test "legacy construction returns typed errors for malformed behavior policy fields" do
    malformed_policies = [
      {%{auto_land: "permissive"}, ["auto_land"], :expected_map},
      {%{auto_land: %{posture: "permissive", dry_run: "false"}}, ["auto_land", "dry_run"], :expected_boolean},
      {%{review: %{mode: 1}}, ["review", "mode"], :expected_string},
      {%{checks: 1}, ["checks"], :expected_list},
      {%{checks: [%{name: "format"}]}, ["checks", 0], :expected_named_check},
      {%{checks: [1]}, ["checks", 0], :expected_check},
      {%{checks: [%{name: "format", command: "mix format", future: true}]}, ["checks", 0, "future"], :unsupported_field},
      {%{completion_requirements: 1}, ["completion_requirements"], :expected_list},
      {%{completion_requirements: ["workpad-current", %{future: true}]}, ["completion_requirements", 1], :expected_string},
      {%{review_requirements: [1]}, ["review_requirements", 0], :expected_string},
      {%{review: %{mode: "strict", timeout_ms: 0}}, ["review", "timeout_ms"], :expected_positive_integer},
      {%{review: %{mode: "strict", max_retries: -1}}, ["review", "max_retries"], :expected_non_negative_integer},
      {%{review: %{mode: "strict", future: true}}, ["review", "future"], :unsupported_field}
    ]

    for {overrides, path, reason} <- malformed_policies do
      write_policy_hash_workflow!("private", overrides)

      assert {:error, {:invalid_issue_policy_authority, ^path, ^reason}} =
               Legacy.build_at_process_start([])
    end
  end

  test "legacy registry generation includes state, dispatch mode, and pinned profile" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}},
        strict: %{delivery: %{pr_target: "main"}}
      }
    )

    RunSetup.put_current(%{saved_run_name: "generation-run", mode: :watch, profile: "default"})
    assert {:ok, watch_default} = Legacy.build_at_process_start([])

    RunSetup.put_current(%{saved_run_name: "generation-run", mode: :drain, profile: "default"})
    assert {:ok, drain_default} = Legacy.build_at_process_start([])

    RunSetup.put_current(%{saved_run_name: "generation-run", mode: :issue_batch, profile: "default"})
    assert {:ok, batch_default} = Legacy.build_at_process_start([])

    RunSetup.put_current(%{saved_run_name: "generation-run", mode: :watch, profile: "strict"})
    assert {:ok, watch_strict} = Legacy.build_at_process_start([])

    assert drain_default.dispatch_mode == watch_default.dispatch_mode
    assert batch_default.state == watch_default.state

    assert Enum.uniq([
             watch_default.policy_hash,
             drain_default.policy_hash,
             batch_default.policy_hash,
             watch_strict.policy_hash
           ]) == [watch_default.policy_hash]

    assert MapSet.size(
             MapSet.new([
               watch_default.registry_generation,
               drain_default.registry_generation,
               batch_default.registry_generation,
               watch_strict.registry_generation
             ])
           ) == 4
  end

  test "legacy policy hash follows complete JSON filter semantics without secrets" do
    write_filter_hash_workflow!("private-filter-one", 2)
    assert {:ok, first} = Legacy.build_at_process_start([])

    write_filter_hash_workflow!("private-filter-two", 2)
    assert {:ok, rotated_sensitive_values} = Legacy.build_at_process_start([])
    assert rotated_sensitive_values.policy_hash == first.policy_hash

    write_filter_hash_workflow!("private-filter-two", 1)
    assert {:ok, changed_operator_value} = Legacy.build_at_process_start([])
    refute changed_operator_value.policy_hash == first.policy_hash

    write_filter_hash_workflow!("private-filter-two", 1)
    assert {:ok, map_filter} = Legacy.build_at_process_start([])

    write_filter_hash_workflow!("private-filter-two", 1, filter: 1)
    assert {:ok, first_scalar_filter} = Legacy.build_at_process_start([])

    write_filter_hash_workflow!("private-filter-two", 1, filter: 2)
    assert {:ok, second_scalar_filter} = Legacy.build_at_process_start([])
    refute second_scalar_filter.policy_hash == first_scalar_filter.policy_hash
    refute first_scalar_filter.policy_hash == map_filter.policy_hash

    write_filter_hash_workflow!("private-filter-two", 1, filter: "priority <= 2")
    assert {:ok, first_string_filter} = Legacy.build_at_process_start([])

    write_filter_hash_workflow!("private-filter-two", 1, filter: "priority <= 1")
    assert {:ok, second_string_filter} = Legacy.build_at_process_start([])
    refute second_string_filter.policy_hash == first_string_filter.policy_hash
  end

  test "legacy policy hash includes supported execution profile controls" do
    write_execution_profile_hash_workflow!("private-profile-one")
    assert {:ok, first} = Legacy.build_at_process_start([])

    write_execution_profile_hash_workflow!("private-profile-two")
    assert {:ok, rotated_private_values} = Legacy.build_at_process_start([])
    assert rotated_private_values.policy_hash == first.policy_hash

    for changed <- [
          %{"timeout_ms" => 120_001},
          %{"max_retries" => 3},
          %{"command" => "review --strict"}
        ] do
      write_execution_profile_hash_workflow!("private-profile-two", changed)
      assert {:ok, changed_context} = Legacy.build_at_process_start([])
      refute changed_context.policy_hash == first.policy_hash
    end
  end

  test "explicit saved-run name overrides current setup and invalid names fail closed" do
    RunSetup.put_current(%{saved_run_name: "saved-run"})

    assert {:ok, explicit} =
             Legacy.build_at_process_start(saved_run_name: "explicit-run")

    assert explicit.target_id == "explicit-run"

    assert {:error, {:invalid_run_setup_name, "../private"}} =
             Legacy.build_at_process_start(saved_run_name: "../private")

    RunSetup.put_current(%{saved_run_name: "../poisoned"})

    assert {:error, {:invalid_run_setup_name, "../poisoned"}} =
             Legacy.build_at_process_start([])

    RunSetup.clear_current()
    assert {:ok, legacy} = Legacy.build_at_process_start([])
    assert legacy.target_id == "legacy"
  end

  test "build_at_process_start rejects malformed options and target names without raising" do
    assert Legacy.build_at_process_start(%{}) == {:error, :invalid_options}

    assert Legacy.build_at_process_start(saved_run_name: :not_a_name) ==
             {:error, :invalid_target_id}

    RunSetup.put_current(%{"saved_run_name" => "string-key-run"})

    assert {:ok, context} = Legacy.build_at_process_start([])
    assert context.target_id == "string-key-run"
  end

  test "legacy context projects nested target scope and profile limits in drain mode" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_id: nil,
      tracker_project_slug: nil,
      target: %{
        tracker: "linear",
        type: "query",
        project: %{id: "project-id", slug: "project-slug"},
        team: %{key: "TEAM"}
      },
      profiles: %{
        default: %{
          delivery: %{pr_target: "main"},
          auto_land: %{posture: "permissive", dry_run: true},
          limits: %{daily: %{max_total_tokens: 1000}}
        }
      }
    )

    RunSetup.put_current(%{mode: :drain})

    assert {:ok, context} = Legacy.build_at_process_start([])
    assert context.state == :draining
    assert context.dispatch_mode == :watch
    assert context.run_target["project"] == %{"id" => "project-id", "slug" => "project-slug"}
    assert context.run_target["team"] == %{"key" => "TEAM"}
    assert context.budget_limits == %{"daily" => %{"max_total_tokens" => 1000}}
    assert context.external_side_effect_gates["merge"] == "deny"
  end

  defp write_policy_hash_workflow!(secret, overrides \\ %{}) do
    default_policy = %{
      private: %{credentials: %{token: secret}},
      review: %{mode: "strict", api_key: secret, credentials: %{token: secret}},
      auto_land: %{posture: "permissive", dry_run: false, credentials: %{token: secret}},
      delivery: %{pr_target: "main"},
      capabilities: %{required: ["github_pr"], credentials: %{token: secret}},
      checks: ["format"],
      completion_requirements: ["workpad-current"],
      review_requirements: ["review-clean"],
      issue_markers: %{
        labels: ["ready"],
        allowed_projects: ["project"],
        credentials: %{token: secret}
      },
      project: %{
        criticality: "production",
        deployment_coupling: "none",
        credentials: %{token: secret}
      },
      run_setup: %{restrictive_flags: [], credentials: %{token: secret}}
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{default: Map.merge(default_policy, overrides)}
    )
  end

  defp issue_policy(context, opts \\ []) do
    issue = %Issue{
      id: "legacy-policy",
      identifier: "SID-LEGACY-POLICY",
      title: "Legacy policy",
      state: "Todo",
      project_slug: "project",
      labels: []
    }

    TargetContext.issue_policy(context, issue, opts)
  end

  defp write_filter_hash_workflow!(secret, priority, opts \\ []) do
    filter =
      Keyword.get(opts, :filter, %{
        and: [
          %{priority: %{lte: priority}},
          %{project: %{id: %{eq: "project-id"}}}
        ],
        or: [
          %{state: %{eq: "Todo"}},
          %{labels: %{in: ["coverage", "ready"]}}
        ],
        estimate: %{
          eq: %{authorization: secret},
          in: ["safe", %{private_key: secret}]
        },
        project: %{slug: %{connection_string: secret}},
        token: secret
      })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      target: %{tracker: "linear", type: "query", filter: filter}
    )
  end

  defp write_execution_profile_hash_workflow!(secret, overrides \\ %{}) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path)
    assert {:ok, workflow} = YamlElixir.read_from_file(path)

    source_reviewer =
      Map.merge(
        %{
          "model" => "review/model",
          "reasoning_effort" => "high",
          "budget" => "review",
          "timeout_ms" => 120_000,
          "max_retries" => 2,
          "command" => ["review", "--source"]
        },
        overrides
      )

    execution_profiles = %{
      "source_reviewer" => source_reviewer,
      "command_string" => %{"command" => "review"},
      "ignored_profile" => secret,
      "ignored_values" => %{
        "model" => %{"private" => secret},
        "timeout_ms" => 0,
        "max_retries" => -1,
        "command" => ["review", %{"private" => secret}]
      }
    }

    workflow =
      put_in(
        workflow,
        ["runtime", "runners", "codex", "execution_profiles"],
        execution_profiles
      )

    File.write!(path, Workflow.Renderer.to_yaml(workflow))
    assert :ok = SymphonyElixir.WorkflowStore.force_reload()
  end

  defp write_secret_workflow!(tracker_secret, target_secret, runner_secret, runner_behavior \\ %{}) do
    path = Workflow.workflow_file_path()

    write_workflow_file!(path,
      tracker_api_token: tracker_secret,
      tracker_project_slug: nil,
      target: %{
        tracker: "linear",
        type: "query",
        filter: %{priority: %{lte: 2}},
        token: target_secret,
        password: target_secret
      }
    )

    assert {:ok, workflow} = YamlElixir.read_from_file(path)

    runner =
      Map.merge(
        %{
          "kind" => "opencode_server",
          "command" => ["opencode", "serve"],
          "model" => "open/model",
          "hostname" => "127.0.0.1",
          "port" => "auto",
          "config_content" => %{"private" => runner_secret},
          "server_auth" => %{"username" => "user-#{runner_secret}", "password" => runner_secret}
        },
        runner_behavior
      )

    workflow =
      workflow
      |> put_in(["runtime", "agent", "default_runner"], "open")
      |> put_in(["runtime", "runners"], %{"open" => runner})

    File.write!(path, Workflow.Renderer.to_yaml(workflow))
    assert :ok = SymphonyElixir.WorkflowStore.force_reload()
  end

  defp write_nested_hash_workflow!(secret, priority, profile_model) do
    path = Workflow.workflow_file_path()

    write_workflow_file!(path,
      tracker_project_slug: nil,
      target: %{
        tracker: "linear",
        type: "query",
        filter: %{priority: %{lte: priority, credentials: %{token: secret}}},
        query: %{priority: %{lte: priority, auth: %{password: secret}}}
      }
    )

    assert {:ok, workflow} = YamlElixir.read_from_file(path)

    workflow =
      put_in(
        workflow,
        ["runtime", "runners", "codex", "execution_profiles"],
        %{
          "source_reviewer" => %{
            "model" => profile_model,
            "private" => %{"token" => secret}
          }
        }
      )

    File.write!(path, Workflow.Renderer.to_yaml(workflow))
    assert :ok = SymphonyElixir.WorkflowStore.force_reload()
  end
end
