defmodule SymphonyElixir.TargetRegistry.CompositionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OperatorRepositoryInspection
  alias SymphonyElixir.TargetRegistry.Composition
  alias SymphonyElixir.TargetRegistry.RepositoryPolicy
  alias SymphonyElixir.TargetRegistry.Schema
  alias SymphonyElixir.TargetRegistry.Snapshot
  alias SymphonyElixir.TargetRegistry.Target
  alias SymphonyElixir.TargetRegistry.Validation

  @fixture_root Path.expand("../../fixtures/target_registry/repos", __DIR__)
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    repos = Path.join(tmp_dir, "repos")
    File.mkdir_p!(repos)
    symphony = Path.join(repos, "symphony")
    other = Path.join(repos, "other")
    File.cp_r!(Path.join(@fixture_root, "symphony"), symphony)
    File.cp_r!(Path.join(@fixture_root, "other"), other)
    init_repo!(symphony, "git@github.com:example/symphony-fixture.git")
    init_repo!(other, "git@github.com:example/other-fixture.git")

    {:ok,
     paths: %{
       symphony: symphony,
       other: other,
       worktree: Path.join(tmp_dir, "worktrees")
     }}
  end

  @tag :tmp_dir
  test "composes solely from host repository policy and never reads repository symphony.yml", %{paths: paths} do
    File.write!(Path.join(paths.symphony, "symphony.yml"), "this is not repository policy")

    composed =
      Composition.compose(snapshot(%{"alpha" => target("alpha", paths.symphony, paths.worktree)})).targets["alpha"]

    assert composed.valid?
    assert composed.repo_manifest["project"]["repository"] == "https://github.com/example/symphony-fixture"
    assert composed.repo_manifest["issue_markers"]["labels"] == ["repo:symphony-fixture", "needs-review"]
    assert get_in(composed.effective_policy, ["repo_policy", "manifest"]) == composed.repo_manifest
    assert get_in(composed.effective_policy, ["repo_policy", "manifest_source_dir"]) == Path.expand(paths.symphony)
    assert get_in(composed.effective_policy, ["repo_policy", "configuration_sources", "defaults", "present"])
    assert get_in(composed.effective_policy, ["repo_policy", "configuration_revision"]) =~ ~r/^sha256:[0-9a-f]{64}$/
    assert composed.policy_hash =~ ~r/^sha256:[0-9a-f]{64}$/
  end

  @tag :tmp_dir
  test "resolves defaults, flat profile, and target override precedence with replacing lists", %{paths: paths} do
    host =
      host()
      |> put_in(["repository_profiles", "release"], %{
        "issue_markers" => %{"labels" => ["profile-label"]},
        "docs" => %{"entrypoints" => []}
      })

    configured =
      target("alpha", paths.symphony, paths.worktree).configured
      |> Map.merge(%{
        "repository_profile" => "release",
        "repository_policy" => %{
          "issue_markers" => %{"labels" => ["target-label"]},
          "docs" => %{"entrypoints" => []}
        }
      })

    assert {:ok, normalized, sources} = RepositoryPolicy.resolve(host, configured)
    assert normalized["issue_markers"]["labels"] == ["target-label"]
    assert normalized["docs"]["entrypoints"] == []
    assert sources["defaults"]["present"]
    assert sources["profile"]["present"]
    assert sources["profile"]["name"] == "release"
    assert sources["profile"]["revision"] =~ ~r/^sha256:[0-9a-f]{64}$/
    assert sources["overrides"]["present"]
  end

  @tag :tmp_dir
  test "omitted host defaults stay absent in admitted configuration provenance", %{paths: paths} do
    {normalized_host, composed} =
      composed_target_only(paths, &Map.drop(&1, ["repository_defaults", "repository_profiles"]))

    refute Map.has_key?(normalized_host, "repository_defaults")
    refute Map.has_key?(normalized_host, "repository_profiles")
    assert composed.valid?, inspect(composed.diagnostics)

    assert get_in(composed.effective_policy, ["repo_policy", "configuration_sources", "defaults"]) ==
             %{"present" => false, "revision" => nil}
  end

  @tag :tmp_dir
  test "explicitly empty host defaults stay present with their own revision", %{paths: paths} do
    {normalized_host, composed} =
      composed_target_only(paths, &Map.put(&1, "repository_defaults", %{}))

    assert normalized_host["repository_defaults"] == %{}
    assert composed.valid?, inspect(composed.diagnostics)

    defaults = get_in(composed.effective_policy, ["repo_policy", "configuration_sources", "defaults"])
    assert defaults["present"] == true
    assert {:ok, empty_revision} = Composition.canonical_hash(%{})
    assert defaults["revision"] == empty_revision
    assert defaults["revision"] =~ ~r/^sha256:[0-9a-f]{64}$/
  end

  @tag :tmp_dir
  test "rejects unknown profiles and profile inheritance", %{paths: paths} do
    unknown =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{"repository_profile" => "missing"}
      })

    assert %Target{valid?: false, effective_state: :paused} =
             Composition.compose(snapshot(%{"alpha" => unknown})).targets["alpha"]

    chained =
      host()
      |> put_in(["repository_profiles", "release"], %{
        "repository_profile" => "base"
      })

    assert [%{code: :unknown_key}] =
             RepositoryPolicy.validate_raw_policy(
               chained["repository_profiles"]["release"],
               "$.host.repository_profiles.release"
             )
  end

  @tag :tmp_dir
  test "preserves raw policy while applying a target branch only to effective policy", %{paths: paths} do
    target =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{"repo" => %{"branch" => "release/2026"}}
      })

    composed = Composition.compose(snapshot(%{"alpha" => target})).targets["alpha"]

    assert composed.valid?
    assert get_in(composed.repo_manifest, ["vcs", "default_branch"]) == "main"
    assert get_in(composed.effective_policy, ["repo_policy", "manifest", "vcs", "default_branch"]) == "release/2026"
    assert get_in(composed.effective_policy, ["repo_policy", "manifest", "delivery", "pr_target"]) == "main"
  end

  @tag :tmp_dir
  test "requires configured repository identity", %{paths: paths} do
    document =
      snapshot(%{
        "alpha" =>
          target("alpha", paths.symphony, paths.worktree, %{
            configured: %{"repo" => %{"expected_repository" => nil}}
          })
      })

    composed = Composition.compose(document).targets["alpha"]
    refute composed.valid?
    assert Enum.any?(composed.diagnostics, &(&1.path == "$.targets.alpha.repo.expected_repository"))
  end

  @tag :tmp_dir
  test "verification independently recomputes host policy authority", %{paths: paths} do
    composed = validated_composed_snapshot(paths)
    assert :ok = Composition.verify_composed_target(composed, "alpha")

    forged_manifest =
      put_in(
        composed.targets["alpha"].repo_manifest,
        ["project", "repository"],
        "https://github.com/example/other-fixture"
      )

    forged_target = %{composed.targets["alpha"] | repo_manifest: forged_manifest}

    refute Composition.verify_composed_target(
             %{composed | targets: %{"alpha" => forged_target}},
             "alpha"
           ) == :ok
  end

  @tag :tmp_dir
  test "repository readiness checks host policy documentation and required files", %{paths: paths} do
    host = put_in(host(), ["repository_defaults", "docs", "entrypoints"], ["missing.md"])
    configured = target("alpha", paths.symphony, paths.worktree).configured

    inspection = OperatorRepositoryInspection.inspect(paths.symphony, host: host, configured: configured)
    assert inspection.state == "invalid"
    assert Enum.any?(inspection.blockers, &String.ends_with?(&1.path, "docs.entrypoints[0]"))
  end

  @tag :tmp_dir
  test "schema rejects runtime policy fields and preserves new target fields", %{paths: paths} do
    configured =
      target("alpha", paths.symphony, paths.worktree).configured
      |> Map.put("repository_profile", "release")
      |> Map.put("repository_policy", %{"runtime" => %{"runner" => "unsafe"}})

    document = %{"version" => 1, "host" => schema_host(paths.worktree), "targets" => %{"alpha" => configured}}
    assert {:ok, snapshot} = Schema.validate(document, home: "/deterministic-home")
    refute snapshot.targets["alpha"].valid?
    assert Enum.any?(snapshot.targets["alpha"].diagnostics, &(&1.path == "$.targets.alpha.repository_policy.runtime"))
    assert snapshot.targets["alpha"].configured["repository_profile"] == "release"
    assert snapshot.targets["alpha"].configured["repository_policy"] == %{"runtime" => %{"runner" => "unsafe"}}
  end

  defp validated_composed_snapshot(paths) do
    document = %{
      "version" => 1,
      "host" => schema_host(paths.worktree),
      "targets" => %{"alpha" => target("alpha", paths.symphony, paths.worktree).configured}
    }

    assert {:ok, structured} = Schema.validate(document, home: "/deterministic-home")
    assert structured.globally_valid?
    assert structured.targets["alpha"].valid?

    registry_path = Path.join([Path.dirname(paths.worktree), "registry", "targets.yml"])
    validated = Validation.validate(%{structured | path: registry_path}, registry_path: registry_path)
    assert validated.globally_valid?
    assert validated.targets["alpha"].valid?

    composed = Composition.compose(validated)
    assert composed.targets["alpha"].valid?, inspect(composed.targets["alpha"].diagnostics)
    composed
  end

  defp composed_target_only(paths, host_transform) do
    host = host_transform.(schema_host(paths.worktree))

    configured =
      target("alpha", paths.symphony, paths.worktree).configured
      |> Map.put("repository_policy", host()["repository_defaults"])

    document = %{"version" => 1, "host" => host, "targets" => %{"alpha" => configured}}

    assert {:ok, structured} = Schema.validate(document, home: "/deterministic-home")
    assert structured.globally_valid?
    assert structured.targets["alpha"].valid?

    registry_path = Path.join([Path.dirname(paths.worktree), "registry", "targets.yml"])
    validated = Validation.validate(%{structured | path: registry_path}, registry_path: registry_path)
    assert validated.globally_valid?
    assert validated.targets["alpha"].valid?

    composed = Composition.compose(validated)
    {structured.host, composed.targets["alpha"]}
  end

  test "canonical policy hashes are deterministic and reject unsafe maps" do
    assert {:ok, first} = Composition.canonical_hash(%{"z" => [1, true], "a" => %{"n" => nil}})
    assert {:ok, ^first} = Composition.canonical_hash(%{"a" => %{"n" => nil}, "z" => [1, true]})
    assert {:error, :not_json_safe} = Composition.canonical_hash(%{unsafe: true})
  end

  @tag :tmp_dir
  test "runner allowlists and execution profile collisions remain enforced", %{paths: paths} do
    disallowed =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{"runners" => %{"allowed" => ["unknown-runner"]}}
      })

    refute Composition.compose(snapshot(%{"alpha" => disallowed})).targets["alpha"].valid?

    colliding_host =
      put_in(host(), ["runners", "codex", "execution_profiles"], %{
        "safe-profile" => %{},
        "safe_profile" => %{}
      })

    colliding =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{
          "runners" => %{
            "settings" => %{"codex" => %{"execution_profiles" => %{"safe-profile" => %{}}}}
          }
        }
      })

    refute Composition.compose(snapshot(%{"alpha" => colliding}, colliding_host)).targets["alpha"].valid?
  end

  @tag :tmp_dir
  test "validation bounds target capacity requests by host ceilings", %{paths: paths} do
    configured =
      target("alpha", paths.symphony, paths.worktree).configured
      |> put_in(["concurrency", "max_concurrent_agents"], 100)
      |> put_in(["concurrency", "max_concurrent_startups"], 100)
      |> put_in(["concurrency", "max_concurrent_reviewers"], 100)

    document = %{
      "version" => 1,
      "host" => schema_host(paths.worktree),
      "targets" => %{"alpha" => configured}
    }

    assert {:ok, structured} = Schema.validate(document, home: "/deterministic-home")
    registry_path = Path.join([Path.dirname(paths.worktree), "registry", "targets.yml"])
    validated = Validation.validate(%{structured | path: registry_path}, registry_path: registry_path)
    refute validated.targets["alpha"].valid?
    assert Enum.any?(validated.targets["alpha"].diagnostics, &(&1.code == :capacity_exceeded))
  end

  defp snapshot(targets), do: snapshot(targets, host())

  defp snapshot(targets, host_config) do
    %Snapshot{
      version: 1,
      path: nil,
      source_hash: nil,
      generation: nil,
      globally_valid?: true,
      host: host_config,
      targets: targets,
      diagnostics: []
    }
  end

  defp target(id, repo_path, worktree_root, overrides \\ %{}) do
    configured = %{
      "display_name" => String.upcase(id),
      "state" => "active",
      "dispatch_mode" => "explicit",
      "repo" => %{
        "path" => repo_path,
        "expected_repository" => "git@github.com:example/symphony-fixture.git"
      },
      "worktree" => %{
        "root" => Path.join(worktree_root, id),
        "strategy" => "per_issue",
        "hooks" => %{
          "after_create" => nil,
          "before_run" => nil,
          "after_run" => nil,
          "before_remove" => nil,
          "timeout_ms" => 60_000
        }
      },
      "linear" => %{
        "connection" => "linear-primary",
        "scope" => %{"type" => "project", "project_slug" => id},
        "active_states" => ["Todo", "In Progress"],
        "terminal_states" => ["Done"],
        "required_labels" => ["host:required"]
      },
      "runners" => %{
        "default" => "codex",
        "allowed" => ["codex"],
        "settings" => %{
          "codex" => %{"model" => "test-model", "reasoning_effort" => "high", "max_turns" => 10}
        }
      },
      "concurrency" => %{
        "max_concurrent_agents" => 2,
        "max_concurrent_startups" => 1,
        "max_concurrent_reviewers" => 1,
        "by_linear_state" => %{"in progress" => 1}
      },
      "budgets" => %{
        "per_run" => %{"max_total_tokens" => 1_000},
        "daily" => %{"max_total_tokens" => 10_000},
        "weekly" => %{"max_total_tokens" => 50_000}
      },
      "checks" => %{
        "pre_dispatch" => ["capability_preflight"],
        "pre_handoff" => ["quality_gate"],
        "pre_publish" => ["publish_preflight"],
        "pre_merge" => ["pr_checks"]
      },
      "external_side_effects" => %{
        "tracker_write" => "allow",
        "vcs_publish" => "allow",
        "pull_request_write" => "allow",
        "merge" => "manual_approval",
        "deployment" => "deny",
        "production_data" => "deny"
      },
      "scheduling" => %{"weight" => 2}
    }

    %Target{
      id: id,
      configured: deep_merge(configured, Map.get(overrides, :configured, %{})),
      configured_state: Map.get(overrides, :configured_state, :active),
      effective_state: Map.get(overrides, :effective_state, :active),
      dispatch_mode: Map.get(overrides, :dispatch_mode, :explicit),
      valid?: Map.get(overrides, :valid?, true),
      repo_manifest: Map.get(overrides, :repo_manifest),
      effective_policy: Map.get(overrides, :effective_policy),
      policy_hash: Map.get(overrides, :policy_hash),
      diagnostics: Map.get(overrides, :diagnostics, [])
    }
  end

  defp host do
    %{
      "repository_defaults" => %{
        "version" => 1,
        "project" => %{
          "slug" => "symphony-fixture",
          "name" => "Symphony Fixture",
          "repository" => "https://github.com/example/symphony-fixture",
          "kind" => "elixir",
          "app_kind" => "web"
        },
        "workflow" => %{
          "preset" => "default",
          "modules" => ["product_visual_review"],
          "config" => %{
            "product_visual_review" => %{
              "enabled" => true,
              "project_kind" => "web",
              "route_policy" => "auto"
            }
          }
        },
        "docs" => %{"entrypoints" => ["README.md"]},
        "validation" => %{"commands" => [%{"name" => "focused", "command" => "mix test"}]},
        "vcs" => %{"mode" => "git", "default_branch" => "main"},
        "delivery" => %{"pr_target" => "main"},
        "automation" => %{
          "posture" => "unattended",
          "profile" => "default",
          "completion_requirements" => ["Run repository validation."]
        },
        "auto_land" => %{
          "posture" => "permissive",
          "required_checks" => ["fixture-ci"],
          "force_human_review_labels" => ["human-review"],
          "blocked_state" => "Human Review",
          "dry_run" => true
        },
        "capabilities" => %{"required" => ["github_pr", "browser"]},
        "issue_markers" => %{
          "labels" => ["repo:symphony-fixture", "needs-review"],
          "allowed_projects" => ["fixture-project"]
        },
        "harness" => %{"codex_home" => nil}
      },
      "repository_profiles" => %{},
      "capabilities" => ["github_pr", "browser"],
      "tracker_connections" => %{
        "linear-primary" => %{
          "kind" => "linear",
          "endpoint" => "https://tracker.example.invalid/graphql",
          "api_key" => "$LINEAR_API_KEY"
        }
      },
      "runners" => %{
        "codex" => %{
          "kind" => "codex_app_server",
          "command" => ["codex", "app-server"],
          "approval_policy" => "never",
          "thread_sandbox" => "workspace-write",
          "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => false},
          "max_concurrent_agents" => 4,
          "max_concurrent_startups" => 2,
          "capabilities" => ["github_pr", "browser"]
        }
      }
    }
  end

  defp schema_host(root) do
    Map.merge(host(), %{
      "id" => "fixture-host",
      "state_root" => Path.join(root, "state"),
      "polling" => %{"interval_ms" => 1_000, "max_concurrent_target_polls" => 2},
      "capacity" => %{
        "max_concurrent_agents" => 4,
        "max_concurrent_startups" => 2,
        "max_concurrent_reviewers" => 2
      },
      "scheduling" => %{
        "algorithm" => "weighted_deficit_round_robin",
        "max_credit_rounds" => 2
      }
    })
  end

  defp init_repo!(path, origin) do
    {_, 0} = System.cmd("git", ["init", "--quiet", path], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", path, "remote", "add", "origin", origin], stderr_to_stdout: true)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value), do: deep_merge(left_value, right_value), else: right_value
    end)
  end

  defp deep_merge(_left, right), do: right
end
