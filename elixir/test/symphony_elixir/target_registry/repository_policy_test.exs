defmodule SymphonyElixir.TargetRegistry.RepositoryPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OperatorRepositoryInspection
  alias SymphonyElixir.TargetRegistry.{RepositoryPolicy, Schema}

  describe "closed nested policy fields" do
    test "misspelled docs file references in defaults are rejected with the supported field named" do
      host = %{"repository_defaults" => %{"docs" => %{"entrypoint" => ["README.md"]}}}

      assert {:error, [%{path: path, code: :unknown_key}]} =
               RepositoryPolicy.resolve(host, %{})

      assert path == "repository_defaults.docs.entrypoint"
    end

    test "misspelled validation file references in a profile are rejected with the profile path" do
      host = %{"repository_profiles" => %{"release" => %{"validation" => %{"required_file" => ["check.sh"]}}}}
      configured = %{"repository_profile" => "release"}

      assert {:error, [%{path: path, code: :unknown_key}]} =
               RepositoryPolicy.resolve(host, configured)

      assert path == "repository_profiles.release.validation.required_file"
    end

    test "misspelled docs file references in target overrides are rejected" do
      configured = %{"repository_policy" => %{"docs" => %{"entrypoint" => ["README.md"]}}}

      assert {:error, [%{path: "repository_policy.docs.entrypoint", code: :unknown_key}]} =
               RepositoryPolicy.resolve(%{}, configured)
    end

    test "unknown validation command fields are rejected before normalization" do
      policy = %{
        "validation" => %{
          "commands" => [%{"name" => "check", "command" => "mix test", "timeout_ms" => 10}]
        }
      }

      assert [%{path: "repository_policy.validation.commands[0].timeout_ms", code: :unknown_key}] =
               RepositoryPolicy.validate_raw_policy(policy)
    end

    test "unknown nested fields report host schema paths for defaults and profiles" do
      assert [%{path: "$.host.repository_defaults.docs.entrypoint", code: :unknown_key}] =
               RepositoryPolicy.validate_raw_policy(
                 %{"docs" => %{"entrypoint" => []}},
                 "$.host.repository_defaults"
               )

      assert [%{path: "$.host.repository_profiles.release.validation.required_file", code: :unknown_key}] =
               RepositoryPolicy.validate_raw_policy(
                 %{"validation" => %{"required_file" => []}},
                 "$.host.repository_profiles.release"
               )
    end

    test "valid closed policy fields remain accepted" do
      policy = supported_field_policy()

      assert {:ok, normalized, _sources} = RepositoryPolicy.resolve(%{}, %{"repository_policy" => policy})

      assert normalized["docs"]["entrypoints"] == ["README.md"]
      assert normalized["validation"]["required_files"] == ["README.md"]
      assert normalized["vcs"]["posture"] == "reviewed"
      assert normalized["automation"]["review"]["require_issue_link"]
    end

    test "open configuration maps keep arbitrary keys" do
      policy = %{
        "project" => %{
          "repository" => "https://github.com/example/fixture",
          "facts" => %{"arbitrary" => "fact", "nested" => %{"deep" => true}}
        },
        "delivery" => %{"pr_target" => "main"},
        "workflow" => %{"config" => %{"product_visual_review" => %{"enabled" => true, "route_policy" => "auto"}}},
        "automation" => %{"review" => %{"require_issue_link" => true}},
        "review_routing" => %{"custom_route" => "policy-extension"}
      }

      assert {:ok, normalized, _sources} = RepositoryPolicy.resolve(%{}, %{"repository_policy" => policy})

      assert normalized["project"]["facts"]["arbitrary"] == "fact"
      assert normalized["project"]["facts"]["nested"]["deep"]
      assert normalized["workflow"]["config"]["product_visual_review"]["route_policy"] == "auto"
      assert normalized["automation"]["review"]["require_issue_link"]
      assert normalized["review_routing"]["custom_route"] == "policy-extension"
    end

    test "sections that reject unknown fields during normalization stay single-diagnostic" do
      assert [%{path: "repository_policy.capabilities.requird", code: :manifest_invalid}] =
               RepositoryPolicy.validate_raw_policy(%{"capabilities" => %{"required" => [], "requird" => []}})

      assert [%{path: "repository_policy.issue_markers.label", code: :manifest_invalid}] =
               RepositoryPolicy.validate_raw_policy(%{"issue_markers" => %{"label" => []}})

      assert [%{path: "repository_policy.automation.policy_ref", code: :manifest_invalid}] =
               RepositoryPolicy.validate_raw_policy(%{"automation" => %{"policy_ref" => "auto"}})
    end
  end

  describe "readiness and admission" do
    @tag :tmp_dir
    test "misspelled docs references cannot yield readiness", %{tmp_dir: root} do
      repo = Path.join(root, "repo")
      File.mkdir_p!(repo)
      git!(repo, ["init", "--initial-branch=main"])

      host = %{"repository_defaults" => %{"docs" => %{"entrypoint" => ["README.md"]}}}
      configured = %{"repo" => %{"path" => repo, "expected_repository" => "https://github.com/example/fixture"}}

      result = OperatorRepositoryInspection.inspect(repo, host: host, configured: configured)

      assert result.state == "invalid"
      assert result.reason == "repository_policy_invalid"
      refute result.apply_allowed
      assert Enum.any?(result.blockers, &(&1.path == "repository_defaults.docs.entrypoint"))
    end

    @tag :tmp_dir
    test "misspelled policy fields block target admission and host validity", %{tmp_dir: root} do
      document = %{"version" => 1, "host" => valid_host(root), "targets" => %{"alpha" => valid_target()}}

      assert {:ok, snapshot} = Schema.validate(document, home: "/tmp/schema-home")
      assert snapshot.globally_valid?
      assert snapshot.targets["alpha"].valid?
      assert snapshot.targets["alpha"].effective_state == :active

      typo_target = put_in(valid_target(), ["repository_policy"], %{"docs" => %{"entrypoint" => ["README.md"]}})
      typo_target_document = %{"version" => 1, "host" => valid_host(root), "targets" => %{"alpha" => typo_target}}

      assert {:ok, snapshot} = Schema.validate(typo_target_document, home: "/tmp/schema-home")
      refute snapshot.targets["alpha"].valid?
      assert snapshot.targets["alpha"].effective_state == :paused

      assert Enum.any?(
               snapshot.targets["alpha"].diagnostics,
               &(&1.path == "$.targets.alpha.repository_policy.docs.entrypoint" and &1.code == :unknown_key)
             )

      typo_host = put_in(valid_host(root), ["repository_defaults", "validation"], %{"required_file" => ["SPEC.md"]})
      typo_host_document = %{"version" => 1, "host" => typo_host, "targets" => %{"alpha" => valid_target()}}

      assert {:ok, snapshot} = Schema.validate(typo_host_document, home: "/tmp/schema-home")
      refute snapshot.globally_valid?

      assert Enum.any?(
               snapshot.diagnostics,
               &(&1.path == "$.host.repository_defaults.validation.required_file" and &1.code == :unknown_key)
             )
    end
  end

  defp supported_field_policy do
    %{
      "project" => %{
        "slug" => "fixture",
        "name" => "Fixture",
        "repository" => "https://github.com/example/fixture",
        "kind" => "generic",
        "app_kind" => "local",
        "facts" => %{"language" => "Elixir"},
        "criticality" => "internal",
        "deployment_coupling" => "local"
      },
      "docs" => %{"entrypoints" => ["README.md"]},
      "vcs" => %{"mode" => "git", "default_branch" => "main", "posture" => "reviewed"},
      "delivery" => %{"pr_target" => "main"},
      "validation" => %{
        "commands" => [%{"name" => "test", "command" => "mix test"}],
        "required_files" => ["README.md"]
      },
      "automation" => %{
        "posture" => "unattended",
        "profile" => "default",
        "completion_requirements" => ["Run repository validation."],
        "review" => %{"require_issue_link" => true}
      },
      "workflow" => %{"preset" => "default", "modules" => [], "config" => %{}},
      "auto_land" => %{
        "posture" => "permissive",
        "required_checks" => ["fixture-ci"],
        "force_human_review_labels" => ["human-review"],
        "force_human_review_paths" => [],
        "blocked_state" => "Human Review",
        "dry_run" => true
      },
      "harness" => %{"codex_home" => nil}
    }
  end

  defp valid_target do
    %{
      "display_name" => "Alpha",
      "state" => "active",
      "dispatch_mode" => "explicit",
      "repo" => %{
        "path" => "~/repo",
        "expected_repository" => "https://github.com/example/symphony-fixture"
      },
      "worktree" => %{"root" => "~/worktrees", "strategy" => "per_issue", "hooks" => %{}},
      "linear" => %{
        "connection" => "linear-main",
        "scope" => %{"type" => "project", "project_id" => "project-1"},
        "active_states" => ["Todo", "In Progress"],
        "terminal_states" => ["Done"],
        "required_labels" => []
      },
      "runners" => %{"allowed" => ["codex"], "default" => "codex", "settings" => %{"codex" => %{}}},
      "concurrency" => %{
        "max_concurrent_agents" => 4,
        "max_concurrent_startups" => 2,
        "max_concurrent_reviewers" => 1,
        "by_linear_state" => %{}
      },
      "budgets" => %{
        "per_run" => %{"max_total_tokens" => 1_000},
        "daily" => %{"max_total_tokens" => 10_000},
        "weekly" => %{"max_total_tokens" => 50_000}
      },
      "checks" => %{
        "pre_dispatch" => ["capability_preflight"],
        "pre_handoff" => ["repo_validation", "quality_gate"],
        "pre_publish" => ["publish_preflight"],
        "pre_merge" => ["pr_checks", "review_feedback_sweep"]
      },
      "external_side_effects" => %{
        "tracker_write" => "deny",
        "vcs_publish" => "deny",
        "pull_request_write" => "deny",
        "merge" => "deny",
        "deployment" => "deny",
        "production_data" => "deny"
      },
      "scheduling" => %{"weight" => 10}
    }
  end

  defp valid_host(root) do
    %{
      "id" => "local-host",
      "state_root" => Path.join(root, "state"),
      "repository_defaults" => %{
        "project" => %{"repository" => "https://github.com/example/symphony-fixture"}
      },
      "repository_profiles" => %{},
      "polling" => %{"interval_ms" => 1_000, "max_concurrent_target_polls" => 2},
      "capacity" => %{
        "max_concurrent_agents" => 4,
        "max_concurrent_startups" => 2,
        "max_concurrent_reviewers" => 1
      },
      "scheduling" => %{
        "algorithm" => "weighted_deficit_round_robin",
        "max_credit_rounds" => 3
      },
      "tracker_connections" => %{
        "linear-main" => %{
          "kind" => "linear",
          "endpoint" => "https://api.linear.app/graphql",
          "api_key" => "$LINEAR_API_KEY"
        }
      },
      "runners" => %{
        "codex" => %{
          "kind" => "codex_app_server",
          "command" => ["codex", "app-server"],
          "max_concurrent_agents" => 4,
          "max_concurrent_startups" => 2
        }
      }
    }
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo | args])
    output
  end
end
