defmodule SymphonyElixir.TargetRegistry.ImportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TargetRegistry.Diagnostic
  alias SymphonyElixir.TargetRegistry.Import
  alias SymphonyElixir.TargetRegistry.Yaml

  @fixture_root Path.expand("../../fixtures/target_registry/imports", __DIR__)
  @current_repo_manifest %{
    "version" => 1,
    "project" => %{
      "slug" => "symphony",
      "repository" => "https://github.com/example/symphony"
    },
    "workflow" => %{"preset" => "default", "modules" => []},
    "docs" => %{"entrypoints" => ["README.md"]},
    "validation" => %{"commands" => [%{"name" => "all", "command" => "make all"}]},
    "vcs" => %{"mode" => "jj", "default_branch" => "main"},
    "delivery" => %{"pr_target" => "main"},
    "automation" => %{"posture" => "unattended"},
    "capabilities" => %{"required" => ["linear"]},
    "issue_markers" => %{
      "labels" => ["repo:symphony"],
      "allowed_projects" => []
    },
    "harness" => %{"codex_home" => nil}
  }

  describe "tracker and scope mapping" do
    test "maps the tracker connection, states, labels, and each typed scope" do
      scopes = [
        {%{"project_id" => "project-001"}, %{"type" => "project", "project_id" => "project-001"}},
        {%{"project_slug" => "project-one"}, %{"type" => "project", "project_slug" => "project-one"}},
        {%{"team_key" => "SYN"}, %{"type" => "team", "team_key" => "SYN"}},
        {%{"query_file" => "queries/ready.json"}, %{"type" => "query", "query_file" => "queries/ready.json"}},
        {%{"issue_ids" => ["SYN-8", "SYN-9"]}, %{"type" => "issues", "issue_ids" => ["SYN-8", "SYN-9"]}}
      ]

      for {selector, expected_scope} <- scopes do
        tracker =
          Map.merge(
            %{
              "kind" => "linear",
              "endpoint" => "https://linear.example.test/graphql",
              "api_key" => "$LINEAR_API_KEY",
              "active_states" => ["Todo", "In Progress"],
              "terminal_states" => ["Done", "Canceled"],
              "required_labels" => ["ready", "safe"]
            },
            selector
          )

        assert {:ok, result} = preview(%{"tracker" => tracker})

        assert get_in(result.proposal, ["host", "tracker_connections", "linear"]) == %{
                 "kind" => "linear",
                 "endpoint" => "https://linear.example.test/graphql",
                 "api_key" => "$LINEAR_API_KEY"
               }

        target = get_in(result.proposal, ["targets", "imported"])
        assert target["linear"]["connection"] == "linear"
        assert target["linear"]["scope"] == expected_scope
        assert target["linear"]["active_states"] == ["Todo", "In Progress"]
        assert target["linear"]["terminal_states"] == ["Done", "Canceled"]
        assert target["linear"]["required_labels"] == ["ready", "safe"]
      end
    end

    test "accepts an equivalent typed runtime target but blocks ambiguous selectors" do
      assert {:ok, equivalent} =
               preview(%{
                 "tracker" => %{"project_slug" => "project-one"},
                 "target" => %{"type" => "project", "project_slug" => "project-one"}
               })

      assert get_in(equivalent.proposal, ["targets", "imported", "linear", "scope"]) == %{
               "type" => "project",
               "project_slug" => "project-one"
             }

      assert {:ok, ambiguous} =
               preview(%{
                 "tracker" => %{"project_slug" => "project-one", "team_key" => "SYN"}
               })

      refute ambiguous.applicable?

      assert Enum.map(ambiguous.import_diagnostics, &{&1.code, &1.path}) == [
               {:ambiguous_import_scope, "$.runtime.tracker"}
             ]
    end

    test "maps target display name and unions restrictive runtime labels" do
      assert {:ok, result} =
               preview(%{
                 "tracker" => %{
                   "required_labels" => [" Zebra ", "alpha"],
                   "project_slug" => "project-one"
                 },
                 "target" => %{
                   "type" => "project",
                   "project_slug" => "project-one",
                   "display_name" => "Imported Project",
                   "required_labels" => ["Beta", "zebra"]
                 }
               })

      target = get_in(result.proposal, ["targets", "imported"])
      assert target["display_name"] == "Imported Project"
      assert target["linear"]["required_labels"] == ["alpha", "beta", "zebra"]
    end

    test "maps typed runtime target scopes and the legacy target name" do
      scopes = [
        {%{"type" => "team", "team_key" => "SYN"}, %{"type" => "team", "team_key" => "SYN"}},
        {%{"type" => "query", "query_file" => "queries/ready.json"}, %{"type" => "query", "query_file" => "queries/ready.json"}},
        {%{"type" => "issues", "issue_ids" => ["SYN-8"]}, %{"type" => "issues", "issue_ids" => ["SYN-8"]}}
      ]

      for {runtime_target, expected_scope} <- scopes do
        assert {:ok, result} =
                 preview(%{"target" => Map.put(runtime_target, "name", "Imported Target")})

        target = get_in(result.proposal, ["targets", "imported"])
        assert target["display_name"] == "Imported Target"
        assert target["linear"]["scope"] == expected_scope
      end

      assert {:ok, unsupported} = preview(%{"target" => %{"type" => "unknown"}})
      refute unsupported.applicable?
      assert hd(unsupported.import_diagnostics).code == :invalid_scope
    end
  end

  describe "polling and workspace mapping" do
    test "keeps host polling conflicts visible and isolates the worktree root by target ID" do
      assert {:ok, result} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "polling" => %{"interval_ms" => 15_000},
                 "workspace" => %{"root" => "/fixtures/worktrees"}
               })

      assert get_in(result.proposal, ["host", "polling", "interval_ms"]) == 30_000

      assert result.source_differences == [
               %{
                 source_path: "$.runtime.polling.interval_ms",
                 destination_path: "$.host.polling.interval_ms",
                 classification: :source_difference,
                 source: 15_000,
                 effective: 30_000,
                 reason: "existing host polling remains unchanged"
               }
             ]

      assert get_in(result.proposal, ["targets", "imported", "worktree"]) == %{
               "root" => "/fixtures/worktrees/imported",
               "strategy" => "per_issue",
               "hooks" => %{}
             }
    end

    test "reports matching polling as consumed without a source difference" do
      assert {:ok, result} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "polling" => %{"interval_ms" => 30_000},
                 "workspace" => %{"root" => "/fixtures/worktrees"}
               })

      assert result.source_differences == []

      assert Enum.any?(result.field_dispositions, fn disposition ->
               disposition == %{
                 source_path: "$.runtime.polling.interval_ms",
                 destination_path: "$.host.polling.interval_ms",
                 action: :matched
               }
             end)
    end
  end

  describe "hooks, runners, and target settings" do
    test "maps hooks exactly and splits host adapter policy from target tuning" do
      hooks = %{
        "after_create" => "jj git clone https://example.test/repo.git .",
        "before_run" => "mise exec -- jj status",
        "after_run" => "jj status",
        "before_remove" => "mise exec -- make clean",
        "timeout_ms" => 90_000
      }

      profiles = %{
        "source_reviewer" => %{
          "model" => "gpt-5.5-review",
          "reasoning_effort" => "high",
          "timeout_ms" => 120_000
        }
      }

      assert {:ok, result} =
               preview(%{
                 "tracker" => %{"project_slug" => "project-one"},
                 "hooks" => hooks,
                 "agent" => %{"default_runner" => "codex", "max_turns" => 17},
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => ["/opt/synthetic/bin/codex", "app-server"],
                     "model" => "gpt-5.5",
                     "approval_policy" => "never",
                     "thread_sandbox" => "workspace-write",
                     "turn_sandbox_policy" => %{
                       "type" => "workspaceWrite",
                       "networkAccess" => true
                     },
                     "turn_timeout_ms" => 600_000,
                     "read_timeout_ms" => 30_000,
                     "stall_timeout_ms" => 120_000,
                     "execution_profiles" => profiles
                   }
                 }
               })

      assert get_in(result.proposal, ["targets", "imported", "worktree", "hooks"]) == hooks

      host_runner = get_in(result.proposal, ["host", "runners", "codex"])

      assert Map.take(host_runner, [
               "kind",
               "command",
               "approval_policy",
               "thread_sandbox",
               "turn_sandbox_policy",
               "turn_timeout_ms",
               "read_timeout_ms",
               "stall_timeout_ms"
             ]) == %{
               "kind" => "codex_app_server",
               "command" => ["/opt/synthetic/bin/codex", "app-server"],
               "approval_policy" => "never",
               "thread_sandbox" => "workspace-write",
               "turn_sandbox_policy" => %{
                 "type" => "workspaceWrite",
                 "networkAccess" => true
               },
               "turn_timeout_ms" => 600_000,
               "read_timeout_ms" => 30_000,
               "stall_timeout_ms" => 120_000
             }

      refute Map.has_key?(host_runner, "model")
      assert host_runner["execution_profiles"] == profiles

      assert get_in(result.proposal, ["targets", "imported", "runners"]) == %{
               "default" => "codex",
               "allowed" => ["codex"],
               "settings" => %{
                 "codex" => %{
                   "model" => "gpt-5.5",
                   "max_turns" => 17,
                   "execution_profiles" => %{
                     "source_reviewer" => %{
                       "model" => "gpt-5.5-review",
                       "reasoning_effort" => "high"
                     }
                   }
                 }
               }
             }
    end

    test "keeps the required OMP model in the host runner catalog" do
      assert {:ok, result} =
               preview(%{
                 "tracker" => %{"project_slug" => "project-one"},
                 "agent" => %{"default_runner" => "omp"},
                 "runners" => %{
                   "omp" => %{
                     "kind" => "omp_acp",
                     "model" => "openai-codex/gpt-5.6-sol",
                     "profile" => "default",
                     "thinking" => "high",
                     "permissions" => %{
                       "read" => "allow",
                       "edit" => "allow",
                       "execute" => "allow"
                     }
                   }
                 }
               })

      assert result.applicable?

      assert get_in(result.proposal, ["host", "runners", "omp", "model"]) ==
               "openai-codex/gpt-5.6-sol"

      assert get_in(result.proposal, [
               "targets",
               "imported",
               "runners",
               "settings",
               "omp",
               "model"
             ]) == "openai-codex/gpt-5.6-sol"
    end
  end

  describe "capacity and quality-gate mapping" do
    test "maps target and runner ceilings plus the equivalent quality check phase" do
      assert {:ok, result} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{
                   "default_runner" => "codex",
                   "max_concurrent_agents" => 10,
                   "max_concurrent_startups" => 2,
                   "max_concurrent_agents_by_state" => %{"Todo" => 3}
                 },
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => ["codex", "app-server"]
                   }
                 },
                 "quality_gate" => %{
                   "enabled" => true,
                   "source_max_concurrency" => 3,
                   "max_repair_passes" => 2
                 }
               })

      assert get_in(result.proposal, ["targets", "imported", "concurrency"]) == %{
               "max_concurrent_agents" => 10,
               "max_concurrent_startups" => 2,
               "max_concurrent_reviewers" => 3,
               "by_linear_state" => %{"Todo" => 3}
             }

      assert Map.take(get_in(result.proposal, ["host", "runners", "codex"]), [
               "max_concurrent_agents",
               "max_concurrent_startups"
             ]) == %{
               "max_concurrent_agents" => 10,
               "max_concurrent_startups" => 2
             }

      assert get_in(result.proposal, ["targets", "imported", "checks"]) == %{
               "pre_dispatch" => [],
               "pre_handoff" => ["quality_gate"],
               "pre_publish" => [],
               "pre_merge" => []
             }
    end

    test "blocks capacity that exceeds an existing host ceiling" do
      assert {:ok, result} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{
                   "default_runner" => "codex",
                   "max_concurrent_agents" => 21,
                   "max_concurrent_startups" => 2
                 },
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => ["codex", "app-server"]
                   }
                 },
                 "quality_gate" => %{"enabled" => true, "source_max_concurrency" => 3}
               })

      refute result.applicable?

      path = "$.targets.imported.concurrency.max_concurrent_agents"

      assert Enum.map(result.import_diagnostics, &diagnostic_projection/1) == [
               %{
                 code: :capacity_exceeded,
                 path: path,
                 message: "#{path} must not exceed effective ceiling 20"
               }
             ]

      assert hd(result.import_diagnostics).scope == {:target, "imported"}

      assert {:ok, runner_limited} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{
                   "default_runner" => "codex",
                   "max_concurrent_agents" => 4,
                   "max_concurrent_startups" => 3
                 },
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => ["codex", "app-server"],
                     "max_concurrent_startups" => 1
                   }
                 }
               })

      runner_path = "$.targets.imported.concurrency.max_concurrent_startups"

      assert Enum.map(runner_limited.import_diagnostics, &diagnostic_projection/1) == [
               %{
                 code: :capacity_exceeded,
                 path: runner_path,
                 message: "#{runner_path} must not exceed effective ceiling 1"
               }
             ]

      assert hd(runner_limited.import_diagnostics).scope == {:target, "imported"}

      runner_only_host =
        update_in(host(), ["capacity"], &Map.delete(&1, "max_concurrent_agents"))

      assert {:ok, runner_only_ceiling} =
               preview(
                 %{
                   "tracker" => %{"project_id" => "project-001"},
                   "agent" => %{
                     "default_runner" => "codex",
                     "max_concurrent_agents" => 4
                   },
                   "runners" => %{
                     "codex" => %{
                       "kind" => "codex_app_server",
                       "command" => ["codex", "app-server"]
                     }
                   }
                 },
                 host: runner_only_host
               )

      assert runner_only_ceiling.import_diagnostics == []
    end

    test "reports imported worker ceilings without replacing existing host capacity" do
      assert {:ok, result} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "worker" => %{
                   "max_concurrent_agents_per_host" => 12,
                   "max_concurrent_startups_per_host" => 3
                 }
               })

      assert result.proposal["host"]["capacity"] == host()["capacity"]

      assert Enum.map(
               Enum.filter(
                 result.source_differences,
                 &String.starts_with?(&1.source_path, "$.runtime.worker.")
               ),
               &{&1.source_path, &1.source, &1.effective}
             ) == [
               {"$.runtime.worker.max_concurrent_agents_per_host", 12, 20},
               {"$.runtime.worker.max_concurrent_startups_per_host", 3, 4}
             ]
    end

    test "adds absent host ceilings and reports exact host ceiling matches" do
      missing_capacity_host =
        update_in(host(), ["capacity"], &Map.delete(&1, "max_concurrent_agents"))

      assert {:ok, added} =
               preview(
                 %{
                   "tracker" => %{"project_id" => "project-001"},
                   "worker" => %{"max_concurrent_agents_per_host" => 12}
                 },
                 host: missing_capacity_host
               )

      assert get_in(added.proposal, ["host", "capacity", "max_concurrent_agents"]) == 12
      assert added.source_differences == []

      assert {:ok, matched} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "worker" => %{
                   "max_concurrent_agents_per_host" => 20,
                   "max_concurrent_startups_per_host" => 4
                 }
               })

      assert Enum.count(matched.field_dispositions, &(&1.action == :matched)) == 2
      assert matched.source_differences == []
    end
  end

  describe "exact reasoning argv extraction" do
    test "extracts only one exact known -c pair with optional matching quotes" do
      for {argument, expected} <- [
            {"model_reasoning_effort=high", "high"},
            {"model_reasoning_effort=\"xhigh\"", "xhigh"},
            {"model_reasoning_effort='minimal'", "minimal"}
          ] do
        assert {:ok, result} =
                 preview(%{
                   "tracker" => %{"project_id" => "project-001"},
                   "agent" => %{"default_runner" => "codex"},
                   "runners" => %{
                     "codex" => %{
                       "kind" => "codex_app_server",
                       "command" => ["codex", "-c", argument, "app-server"]
                     }
                   }
                 })

        assert get_in(result.proposal, ["host", "runners", "codex", "command"]) == [
                 "codex",
                 "app-server"
               ]

        assert get_in(
                 result.proposal,
                 ["targets", "imported", "runners", "settings", "codex", "reasoning_effort"]
               ) == expected
      end
    end

    test "blocks multiple, unknown, mismatched, shell-string, and alternate forms" do
      cases = [
        ["codex", "-c", "model_reasoning_effort=high", "-c", "model_reasoning_effort=low", "app-server"],
        ["codex", "-c", "model_reasoning_effort=extreme", "app-server"],
        ["codex", "-c", "model_reasoning_effort=\"high'", "app-server"],
        "codex -c model_reasoning_effort=high app-server",
        ["codex", "--config", "model_reasoning_effort=high", "app-server"],
        ["codex", 42, "app-server"],
        42
      ]

      for command <- cases do
        assert {:ok, result} =
                 preview(%{
                   "tracker" => %{"project_id" => "project-001"},
                   "agent" => %{"default_runner" => "codex"},
                   "runners" => %{
                     "codex" => %{
                       "kind" => "codex_app_server",
                       "command" => command
                     }
                   }
                 })

        refute result.applicable?

        assert Enum.any?(result.import_diagnostics, fn diagnostic ->
                 {diagnostic.code, diagnostic.path} ==
                   {:unsupported_reasoning_argument, "$.runtime.runners.codex.command"}
               end)

        if command in [["codex", 42, "app-server"], 42] do
          assert {:ok, _preview} = result |> Import.encode_preview() |> Jason.decode()
          assert Import.encode_repo_policy_preview(result) =~ "\"policy_hash\": null"
        end
      end

      assert {:ok, alternate_field} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{"default_runner" => "codex"},
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => ["codex", "app-server"],
                     "reasoning_effort" => "high"
                   }
                 }
               })

      refute alternate_field.applicable?

      assert hd(alternate_field.import_diagnostics).code ==
               :unsupported_reasoning_argument
    end

    test "leaves unrelated reasoning text byte-identical without diagnostics" do
      command = [
        "codex",
        "--label=model_reasoning_effort-doc",
        "-c",
        "othermodel_reasoning_effort=high",
        "app-server"
      ]

      assert {:ok, result} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{"default_runner" => "codex"},
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => command
                   }
                 }
               })

      assert result.applicable?
      assert get_in(result.proposal, ["host", "runners", "codex", "command"]) == command

      refute Enum.any?(
               result.import_diagnostics,
               &(&1.code == :unsupported_reasoning_argument)
             )

      opencode_command = ["opencode", "-c", "model_reasoning_effort=high", "serve"]

      assert {:ok, opencode} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{"default_runner" => "opencode"},
                 "runners" => %{
                   "opencode" => %{
                     "kind" => "opencode_server",
                     "command" => opencode_command
                   }
                 }
               })

      assert opencode.applicable?
      assert get_in(opencode.proposal, ["host", "runners", "opencode", "command"]) == opencode_command

      refute get_in(
               opencode.proposal,
               ["targets", "imported", "runners", "settings", "opencode", "reasoning_effort"]
             )

      refute Enum.any?(
               opencode.import_diagnostics,
               &(&1.code == :unsupported_reasoning_argument)
             )
    end
  end

  describe "repository authority and ignored host fields" do
    test "uses the current prevalidated manifest without composing the incomplete target" do
      document = %{
        "project" => %{"slug" => "stale-project"},
        "workflow" => %{"preset" => "stale"},
        "issue_markers" => %{"labels" => ["repo:stale"]},
        "runtime" => %{
          "tracker" => %{
            "project_id" => "project-001",
            "required_labels" => ["ready"]
          },
          "agent" => %{"default_runner" => "codex"},
          "runners" => %{
            "codex" => %{
              "kind" => "codex_app_server",
              "command" => ["codex", "app-server"]
            }
          }
        }
      }

      assert {:ok, result} = preview_document(document)
      target = result.snapshot.targets["imported"]

      assert result.applicable?
      assert result.current_repo_manifest == @current_repo_manifest
      assert target.valid? == false
      assert target.effective_state == :paused
      assert target.repo_manifest == nil
      assert target.effective_policy == nil
      assert target.policy_hash == nil

      assert get_in(result.effective_preview_target, ["linear", "required_labels"]) == [
               "ready",
               "repo:symphony"
             ]

      assert Enum.any?(result.source_differences, fn difference ->
               difference.source_path == "$.issue_markers.labels" and
                 difference.source == ["repo:stale"] and
                 difference.effective == ["repo:symphony"]
             end)

      assert get_in(result.current_repo_manifest, ["project", "slug"]) == "symphony"
      assert get_in(result.current_repo_manifest, ["workflow", "preset"]) == "default"
      refute result.current_repo_manifest == Map.take(document, Map.keys(@current_repo_manifest))

      assert {:ok, import_preview} =
               result
               |> Import.encode_preview()
               |> Jason.decode()

      assert Enum.any?(
               import_preview["source_differences"],
               &(&1["source_path"] == "$.issue_markers.labels")
             )

      assert {:ok, repo_preview} =
               result
               |> Import.encode_repo_policy_preview()
               |> Jason.decode()

      assert [%{"source_path" => "$.issue_markers.labels"}] =
               repo_preview["source_differences"]
    end

    test "enforces bounded Composition manifest shape parity before mapping" do
      source = Yaml.encode(%{"runtime" => %{"tracker" => %{"project_id" => "project-001"}}})

      deep_value =
        Enum.reduce(1..65, "leaf", fn index, nested ->
          %{"node-#{index}" => nested}
        end)

      invalid_manifests = [
        nil,
        Map.put(@current_repo_manifest, "version", 2),
        Map.delete(@current_repo_manifest, "workflow"),
        update_in(@current_repo_manifest, ["project"], &Map.delete(&1, "repository")),
        put_in(@current_repo_manifest, ["project", "repository"], " "),
        put_in(
          @current_repo_manifest,
          ["validation", "commands"],
          [%{"name" => "all", "command" => "make all", "unknown" => true}]
        ),
        put_in(
          @current_repo_manifest,
          ["validation", "commands"],
          [%{"name" => "all"}]
        ),
        put_in(
          @current_repo_manifest,
          ["validation", "commands"],
          [%{"name" => " ", "command" => "make all"}]
        ),
        put_in(@current_repo_manifest, ["validation", "commands"], "make all"),
        put_in(@current_repo_manifest, ["validation", "commands"], [42]),
        Map.put(@current_repo_manifest, "auto_land", "enabled"),
        Map.put(@current_repo_manifest, "auto_land", %{"required_checks" => "all"}),
        Map.put(@current_repo_manifest, "auto_land", %{"required_checks" => [42]}),
        Map.put(@current_repo_manifest, "auto_land", %{"force_human_review_paths" => "lib/authority/**"}),
        Map.put(@current_repo_manifest, "auto_land", %{"force_human_review_paths" => [42]}),
        put_in(@current_repo_manifest, ["issue_markers", "labels"], [42]),
        put_in(@current_repo_manifest, ["issue_markers", "labels"], "repo:symphony"),
        Map.put(@current_repo_manifest, "invalid_utf8", <<0xFF>>),
        Map.put(@current_repo_manifest, "invalid_key", %{42 => "value"}),
        Map.put(@current_repo_manifest, "unsupported_value", :atom),
        Map.put(@current_repo_manifest, "deep_value", deep_value),
        Map.put(@current_repo_manifest, "wide_value", List.duplicate(0, 10_000))
      ]

      for manifest <- invalid_manifests do
        assert {:error, error} =
                 Import.preview(source,
                   target_id: "imported",
                   source_path: "/private/import.runtime.yml",
                   repo_path: "/fixtures/repo",
                   host: host(),
                   current_repo_manifest: manifest
                 )

        assert error.path == "$.current_repo_manifest"
      end

      assert {:ok, _result} =
               Import.preview(source,
                 target_id: "imported",
                 source_path: "/private/import.runtime.yml",
                 repo_path: "/fixtures/repo",
                 host: host(),
                 current_repo_manifest: Map.put(@current_repo_manifest, "finite_float", 1.5)
               )
    end

    test "reapplies current repo policy and reports every non-authoritative source section" do
      authority_sections = %{
        "project" => %{"slug" => "stale-project"},
        "workflow" => %{"preset" => "stale"},
        "docs" => %{"entrypoints" => ["STALE.md"]},
        "validation" => %{"commands" => []},
        "vcs" => %{"mode" => "git"},
        "delivery" => %{"pr_target" => "stale"},
        "automation" => %{"posture" => "legacy"},
        "capabilities" => %{"required" => []},
        "issue_markers" => %{"labels" => ["repo:stale"]},
        "harness" => %{"codex_home" => "/stale/harness"}
      }

      runtime = %{
        "tracker" => %{
          "project_id" => "project-001",
          "required_labels" => ["ready"]
        },
        "agent" => %{"default_runner" => "codex"},
        "runners" => %{
          "codex" => %{
            "kind" => "codex_app_server",
            "command" => ["codex", "app-server"]
          }
        },
        "server" => %{"host" => "0.0.0.0", "port" => 4000},
        "observability" => %{"dashboard_enabled" => true},
        "quality_gate" => %{
          "enabled" => true,
          "source_max_concurrency" => 2,
          "max_repair_passes" => 3,
          "runtime_isolation" => "serialized"
        }
      }

      assert {:ok, result} =
               authority_sections
               |> Map.put("runtime", runtime)
               |> preview_document()

      target = get_in(result.proposal, ["targets", "imported"])

      for section <- Map.keys(authority_sections) do
        refute Map.has_key?(target, section)

        assert Enum.any?(result.field_dispositions, fn disposition ->
                 disposition.source_path == "$.#{section}" and
                   disposition.action == :reapplied_from_current_repo
               end)
      end

      refute Map.has_key?(result.proposal["host"], "server")
      refute Map.has_key?(result.proposal["host"], "observability")

      assert get_in(result.effective_preview_target, ["linear", "required_labels"]) == [
               "ready",
               "repo:symphony"
             ]

      assert Enum.any?(result.source_differences, fn difference ->
               difference.source_path == "$.issue_markers.labels" and
                 difference.source == ["repo:stale"] and
                 difference.effective == ["repo:symphony"]
             end)

      for path <- [
            "$.runtime.server",
            "$.runtime.observability",
            "$.runtime.quality_gate.max_repair_passes",
            "$.runtime.quality_gate.runtime_isolation"
          ] do
        assert Enum.any?(result.source_differences, &(&1.source_path == path))
      end
    end
  end

  describe "pure paused preview" do
    test "never infers dispatch and leaves selected source bytes unchanged" do
      source =
        Yaml.encode(%{
          "runtime" => %{
            "mode" => "watch",
            "target" => %{
              "type" => "project",
              "project_slug" => "project-one",
              "mode" => "watch"
            },
            "agent" => %{"default_runner" => "codex"},
            "runners" => %{
              "codex" => %{
                "kind" => "codex_app_server",
                "command" => ["codex", "app-server"]
              }
            }
          }
        })

      checksum_before = :crypto.hash(:sha256, source)
      source_before = source
      process_before = Process.get()

      assert {:ok, result} =
               Import.preview(source,
                 target_id: "imported",
                 source_path: "/path/that/does/not/exist.runtime.yml",
                 repo_path: "/fixtures/repo",
                 host: host(),
                 current_repo_manifest: @current_repo_manifest
               )

      target = get_in(result.proposal, ["targets", "imported"])
      assert target["state"] == "paused"
      refute Map.has_key?(target, "dispatch_mode")
      assert target["budgets"] == %{}
      assert target["scheduling"] == %{}
      refute Map.has_key?(target, "external_side_effects")

      snapshot_target = result.snapshot.targets["imported"]
      assert snapshot_target.valid? == false
      assert snapshot_target.effective_state == :paused
      assert snapshot_target.dispatch_mode == nil
      assert snapshot_target.repo_manifest == nil
      assert snapshot_target.effective_policy == nil
      assert snapshot_target.policy_hash == nil

      assert Enum.map(snapshot_target.diagnostics, &{&1.code, &1.path}) == [
               {:missing_required_field, "$.targets.imported.budgets.daily"},
               {:missing_required_field, "$.targets.imported.budgets.per_run"},
               {:missing_required_field, "$.targets.imported.budgets.weekly"},
               {:incomplete_policy, "$.targets.imported.external_side_effects"},
               {:missing_required_field, "$.targets.imported.scheduling.weight"}
             ]

      assert result.applicable?
      assert result.import_diagnostics == []
      assert hd(result.registry_preview.targets).dispatch_mode == nil
      assert hd(result.registry_preview.targets).policy_hash == nil

      assert source == source_before
      assert :crypto.hash(:sha256, source) == checksum_before
      assert result.source.checksum == "sha256:" <> Base.encode16(checksum_before, case: :lower)
      assert Process.get() == process_before
    end

    test "public output preserves the complete Task7 first-install preview" do
      assert {:ok, result} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{"default_runner" => "codex"},
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => ["codex", "app-server"]
                   }
                 }
               })

      assert {:ok, encoded} = Jason.decode(Import.encode_preview(result))
      public = encoded["registry_preview"]

      assert public["expected_generation"] == nil
      assert public["source_changed?"] == true
      assert length(public["diff"]) == length(result.registry_preview.diff)

      assert Enum.map(public["diff"], & &1["classification"]) ==
               Enum.map(result.registry_preview.diff, &Atom.to_string(&1.classification))

      for {public_change, task7_change} <-
            Enum.zip(public["diff"], result.registry_preview.diff) do
        assert Map.has_key?(public_change, "before") == Map.has_key?(task7_change, :before)
        assert Map.has_key?(public_change, "after") == Map.has_key?(task7_change, :after)
      end

      assert [%{"dispatch_mode" => nil}] =
               Enum.map(public["targets"], &Map.take(&1, ["dispatch_mode"]))

      for category <- ~w(
            state dispatch_mode scope runners capacity budgets checks external_side_effects
          ) do
        task7_category =
          Map.fetch!(result.registry_preview.impact, String.to_atom(category))

        assert public["impact"][category]["classification"] ==
                 Atom.to_string(task7_category.classification)

        assert length(public["impact"][category]["changes"]) ==
                 length(task7_category.changes)
      end
    end
  end

  describe "invalid import inputs" do
    test "rejects duplicate YAML, malformed YAML, and unsupported source versions deterministically" do
      duplicate = """
      version: 1
      runtime:
        tracker:
          project_id: project-001
          project_id: project-002
      """

      malformed = "runtime: ["
      unsupported = "version: 2\nruntime: {}\n"

      assert {:error, duplicate_error} = import_source(duplicate)
      assert duplicate_error.code == :duplicate_key
      assert duplicate_error.path == "$.runtime.tracker.project_id"
      assert import_source(duplicate) == {:error, duplicate_error}

      assert {:error, malformed_error} = import_source(malformed)
      assert malformed_error.code == :invalid_yaml
      assert import_source(malformed) == {:error, malformed_error}

      assert {:error, version_error} = import_source(unsupported)
      assert version_error.code == :unsupported_version
      assert version_error.path == "$.version"
      assert import_source(unsupported) == {:error, version_error}
    end

    test "rejects unsupported tracker values and resolved credentials without exposing them" do
      assert {:ok, unsupported_tracker} =
               preview(%{
                 "tracker" => %{
                   "kind" => "unsupported",
                   "project_id" => "project-001"
                 }
               })

      refute unsupported_tracker.applicable?

      assert Enum.map(unsupported_tracker.import_diagnostics, &{&1.code, &1.path}) == [
               {:invalid_value, "$.runtime.tracker.kind"}
             ]

      resolved_secret = "synthetic-secret-token-never-render"

      source =
        Yaml.encode(%{
          "runtime" => %{
            "tracker" => %{
              "project_id" => "project-001",
              "api_key" => resolved_secret
            }
          }
        })

      assert {:error, credential_error} = import_source(source)
      assert credential_error.code == :invalid_value
      assert credential_error.path == "$.runtime.tracker.api_key"
      refute inspect(credential_error) =~ resolved_secret
    end

    test "rejects missing selection data, invalid runtime shapes, and unsafe API-key references" do
      assert {:error, source_error} = Import.preview(:not_source_bytes, [])
      assert source_error.path == "$.source"

      source = Yaml.encode(%{"runtime" => %{"tracker" => %{"project_id" => "project-001"}}})

      assert {:error, missing_path} = Import.preview(source, [])
      assert missing_path.path == "$.source_path"

      assert {:error, missing_maps} =
               Import.preview(source,
                 source_path: "/fixtures/import.runtime.yml",
                 target_id: "imported",
                 repo_path: "/fixtures/repo"
               )

      assert missing_maps.path == "$.host"

      assert {:error, invalid_runtime} =
               import_source(Yaml.encode(%{"runtime" => ["not", "a", "map"]}))

      assert invalid_runtime.path == "$.runtime"

      assert {:error, missing_runtime} = import_source(Yaml.encode(%{"version" => 1}))
      assert missing_runtime.path == "$.runtime"

      unsafe_reference =
        Yaml.encode(%{
          "runtime" => %{
            "tracker" => %{
              "project_id" => "project-001",
              "api_key" => "$lowercase_reference"
            }
          }
        })

      assert {:error, unsafe_key} = import_source(unsafe_reference)
      assert unsafe_key.path == "$.runtime.tracker.api_key"
    end

    test "validates identifiers, selectors, labels, runners, and explicit host authority" do
      source =
        Yaml.encode(%{
          "runtime" => %{
            "tracker" => %{"project_id" => "project-001"},
            "agent" => %{"default_runner" => "codex"},
            "runners" => %{
              "codex" => %{
                "kind" => "codex_app_server",
                "command" => ["codex", "app-server"]
              }
            }
          }
        })

      base_opts = [
        target_id: "imported",
        source_path: "/fixtures/import.runtime.yml",
        repo_path: "/fixtures/repo",
        host: host(),
        current_repo_manifest: @current_repo_manifest
      ]

      for {option, value, path} <- [
            {:target_id, "../escape", "$.target_id"},
            {:target_id, <<0xFF>>, "$.target_id"},
            {:connection_id, "../linear", "$.connection_id"},
            {:connection_id, <<0xFF>>, "$.connection_id"}
          ] do
        opts = Keyword.put(base_opts, option, value)
        assert {:error, error} = Import.preview(source, opts)
        assert {error.code, error.path} == {:invalid_id, path}
      end

      assert {:error, invalid_repo_path} =
               Import.preview(source, Keyword.put(base_opts, :repo_path, " "))

      assert {invalid_repo_path.code, invalid_repo_path.path} ==
               {:invalid_type, "$.repo_path"}

      assert {:ok, malformed_lists} =
               preview(%{
                 "tracker" => %{
                   "issue_ids" => [42],
                   "active_states" => [42],
                   "terminal_states" => [42],
                   "required_labels" => [42]
                 },
                 "target" => %{
                   "type" => "issues",
                   "issue_ids" => [42],
                   "required_labels" => [42]
                 }
               })

      refute malformed_lists.applicable?

      assert Enum.map(malformed_lists.import_diagnostics, &{&1.code, &1.path}) == [
               {:invalid_type, "$.runtime.target.issue_ids[0]"},
               {:invalid_type, "$.runtime.target.required_labels[0]"},
               {:invalid_type, "$.runtime.tracker.active_states[0]"},
               {:invalid_type, "$.runtime.tracker.issue_ids[0]"},
               {:invalid_type, "$.runtime.tracker.required_labels[0]"},
               {:invalid_type, "$.runtime.tracker.terminal_states[0]"}
             ]

      assert {:ok, malformed_shapes} =
               preview(%{
                 "tracker" => %{
                   "project_id" => 42,
                   "project_slug" => " ",
                   "issue_ids" => [],
                   "active_states" => "Open"
                 },
                 "target" => %{
                   "type" => "issues",
                   "issue_ids" => "ISS-1",
                   "required_labels" => [""]
                 }
               })

      assert MapSet.subset?(
               MapSet.new([
                 {:invalid_type, "$.runtime.tracker.project_id"},
                 {:invalid_value, "$.runtime.tracker.project_slug"},
                 {:invalid_value, "$.runtime.tracker.issue_ids"},
                 {:invalid_type, "$.runtime.tracker.active_states"},
                 {:invalid_type, "$.runtime.target.issue_ids"},
                 {:invalid_value, "$.runtime.target.required_labels[0]"}
               ]),
               MapSet.new(Enum.map(malformed_shapes.import_diagnostics, &{&1.code, &1.path}))
             )

      assert {:ok, blank_issue_id} =
               preview(%{"tracker" => %{"issue_ids" => [""]}})

      assert Enum.any?(
               blank_issue_id.import_diagnostics,
               &({&1.code, &1.path} == {:invalid_value, "$.runtime.tracker.issue_ids[0]"})
             )

      assert {:ok, malformed_runtime_sections} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => "codex",
                 "runners" => "codex"
               })

      assert MapSet.subset?(
               MapSet.new([
                 {:invalid_type, "$.runtime.agent"},
                 {:invalid_type, "$.runtime.runners"}
               ]),
               MapSet.new(Enum.map(malformed_runtime_sections.import_diagnostics, &{&1.code, &1.path}))
             )

      assert {:ok, invalid_default_runner} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{"default_runner" => 42},
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => ["codex", "app-server"]
                   }
                 }
               })

      assert Enum.any?(
               invalid_default_runner.import_diagnostics,
               &({&1.code, &1.path} ==
                   {:invalid_type, "$.runtime.agent.default_runner"})
             )

      invalid_runner_key_source = """
      version: 1
      runtime:
        tracker:
          project_id: project-001
        runners:
          42:
            kind: codex_app_server
          codex:
            42: invalid-field
            kind: codex_app_server
      """

      assert {:error, invalid_runner_keys} = import_source(invalid_runner_key_source)
      assert invalid_runner_keys.code == :non_string_key
      assert invalid_runner_keys.path == "$.runtime.runners"

      host_without_catalogs = Map.drop(host(), ["tracker_connections", "runners"])

      assert {:error, missing_host_containers} =
               preview(
                 %{
                   "tracker" => %{"project_id" => "project-001"},
                   "runners" => %{
                     "codex" => %{
                       "kind" => "codex_app_server",
                       "command" => ["codex", "app-server"]
                     }
                   }
                 },
                 host: host_without_catalogs
               )

      assert {missing_host_containers.code, missing_host_containers.path} ==
               {:invalid_type, "$.host"}

      assert {:ok, malformed_runners} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{"default_runner" => "../runner"},
                 "runners" => %{
                   "../runner" => %{
                     "kind" => "codex_app_server",
                     "command" => ["codex", "app-server"]
                   }
                 }
               })

      refute malformed_runners.applicable?

      assert Enum.map(malformed_runners.import_diagnostics, &{&1.code, &1.path}) == [
               {:invalid_id, "$.runtime.agent.default_runner"},
               {:invalid_id, "$.runtime.runners.../runner"}
             ]

      invalid_host = Map.put(host(), "runners", "invalid")

      assert {:error, blocked_host} =
               preview(
                 %{
                   "tracker" => %{"project_id" => "project-001"},
                   "agent" => %{"default_runner" => "codex"},
                   "runners" => %{
                     "codex" => %{
                       "kind" => "codex_app_server",
                       "command" => ["codex", "app-server"]
                     }
                   }
                 },
                 host: invalid_host
               )

      assert {blocked_host.code, blocked_host.path} == {:invalid_type, "$.host"}
    end

    test "redacts malformed runner values in non-applicable mapped previews" do
      assert {:ok, malformed_sandbox} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{"default_runner" => "codex"},
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => ["codex", "app-server"],
                     "turn_sandbox_policy" => %{"readOnlyAccess" => "invalid"}
                   }
                 }
               })

      sandbox_json = Import.encode_preview(malformed_sandbox)
      refute sandbox_json =~ "\"readOnlyAccess\": \"invalid\""
    end

    test "blocks conflicting existing host connection and runner IDs without overwriting them" do
      existing_connection = %{
        "kind" => "linear",
        "endpoint" => "https://existing.example.test/graphql",
        "api_key" => "$EXISTING_LINEAR_API_KEY"
      }

      existing_runner = %{
        "kind" => "codex_app_server",
        "command" => ["existing-codex", "app-server"],
        "max_concurrent_agents" => 20,
        "max_concurrent_startups" => 4
      }

      conflicting_host =
        host()
        |> put_in(["tracker_connections", "linear"], existing_connection)
        |> put_in(["runners", "codex"], existing_runner)

      assert {:ok, result} =
               preview(
                 %{
                   "tracker" => %{
                     "project_id" => "project-001",
                     "endpoint" => "https://new.example.test/graphql"
                   },
                   "agent" => %{"default_runner" => "codex"},
                   "runners" => %{
                     "codex" => %{
                       "kind" => "codex_app_server",
                       "command" => ["new-codex", "app-server"]
                     }
                   }
                 },
                 host: conflicting_host
               )

      refute result.applicable?
      assert get_in(result.proposal, ["host", "tracker_connections", "linear"]) == existing_connection
      assert get_in(result.proposal, ["host", "runners", "codex"]) == existing_runner

      assert Enum.map(result.import_diagnostics, &{&1.code, &1.path}) == [
               {:import_conflict, "$.host.runners.codex"},
               {:import_conflict, "$.host.tracker_connections.linear"}
             ]
    end

    test "accepts identical existing host entries without merging or conflict diagnostics" do
      runtime = %{
        "tracker" => %{"project_id" => "project-001"},
        "agent" => %{"default_runner" => "codex"},
        "runners" => %{
          "codex" => %{
            "kind" => "codex_app_server",
            "command" => ["codex", "app-server"]
          }
        }
      }

      assert {:ok, first} = preview(runtime)
      assert {:ok, repeated} = preview(runtime, host: first.proposal["host"])
      assert repeated.applicable?
      assert repeated.import_diagnostics == []
      assert repeated.proposal["host"] == first.proposal["host"]
    end
  end

  describe "second review regressions" do
    test "splits complete OpenCode host authority from Task6-safe target tuning" do
      source_profile = %{
        "model" => "openai/gpt-5.6-sol",
        "reasoning_effort" => "high",
        "timeout_ms" => 180_000,
        "max_retries" => 2,
        "command" => ["opencode", "run", "--profile", "review"],
        "control" => %{"interactive" => false}
      }

      assert {:ok, result} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{
                   "default_runner" => "opencode",
                   "max_concurrent_agents" => 6,
                   "max_concurrent_startups" => 2,
                   "max_turns" => 19
                 },
                 "runners" => %{
                   "opencode" => %{
                     "kind" => "opencode_server",
                     "command" => ["opencode", "serve"],
                     "model" => "openai/gpt-5.6-sol",
                     "turn_timeout_ms" => 900_000,
                     "read_timeout_ms" => 30_000,
                     "stall_timeout_ms" => 120_000,
                     "max_concurrent_startups" => 2,
                     "agent" => "review",
                     "hostname" => "127.0.0.1",
                     "port" => 4_096,
                     "config_dir" => "/fixtures/opencode",
                     "config_path" => "/fixtures/opencode/config.json",
                     "config_content" => %{"theme" => "system"},
                     "server_auth" => %{
                       "username" => "local-reviewer",
                       "password" => "synthetic-password"
                     },
                     "permissions" => %{
                       "bash" => "deny",
                       "edit" => "deny",
                       "webfetch" => "deny"
                     },
                     "startup_timeout_ms" => 45_000,
                     "execution_profiles" => %{
                       " Source-Reviewer " => source_profile,
                       "test-reviewer" => %{
                         "model" => "openai/gpt-5.6-terra",
                         "reasoning_effort" => "xhigh",
                         "timeout_ms" => 240_000,
                         "max_retries" => 0
                       }
                     }
                   }
                 }
               })

      assert result.applicable?
      host_runner = get_in(result.proposal, ["host", "runners", "opencode"])

      assert Map.drop(host_runner, [
               "max_concurrent_agents",
               "max_concurrent_startups",
               "execution_profiles"
             ]) == %{
               "kind" => "opencode_server",
               "command" => ["opencode", "serve"],
               "turn_timeout_ms" => 900_000,
               "read_timeout_ms" => 30_000,
               "stall_timeout_ms" => 120_000,
               "agent" => "review",
               "hostname" => "127.0.0.1",
               "port" => 4_096,
               "config_dir" => "/fixtures/opencode",
               "config_path" => "/fixtures/opencode/config.json",
               "config_content" => %{"theme" => "system"},
               "server_auth" => %{
                 "username" => "local-reviewer",
                 "password" => "synthetic-password"
               },
               "permissions" => %{
                 "bash" => "deny",
                 "edit" => "deny",
                 "webfetch" => "deny"
               },
               "startup_timeout_ms" => 45_000
             }

      assert host_runner["max_concurrent_agents"] == 6
      assert host_runner["max_concurrent_startups"] == 2
      refute Map.has_key?(host_runner, "model")

      assert host_runner["execution_profiles"] == %{
               "source_reviewer" => source_profile,
               "test_reviewer" => %{
                 "model" => "openai/gpt-5.6-terra",
                 "reasoning_effort" => "xhigh",
                 "timeout_ms" => 240_000,
                 "max_retries" => 0
               }
             }

      assert get_in(
               result.proposal,
               ["targets", "imported", "runners", "settings", "opencode"]
             ) == %{
               "model" => "openai/gpt-5.6-sol",
               "max_turns" => 19,
               "execution_profiles" => %{
                 "source_reviewer" => %{
                   "model" => "openai/gpt-5.6-sol",
                   "reasoning_effort" => "high"
                 },
                 "test_reviewer" => %{
                   "model" => "openai/gpt-5.6-terra",
                   "reasoning_effort" => "xhigh"
                 }
               }
             }

      assert Enum.any?(result.field_dispositions, fn disposition ->
               disposition == %{
                 source_path: "$.runtime.runners.opencode.max_concurrent_startups",
                 destination_path: "$.host.runners.opencode.max_concurrent_startups",
                 action: :mapped
               }
             end)

      assert Enum.any?(result.field_dispositions, fn disposition ->
               disposition == %{
                 source_path: "$.runtime.runners.opencode.execution_profiles. Source-Reviewer .timeout_ms",
                 destination_path: "$.host.runners.opencode.execution_profiles.source_reviewer.timeout_ms",
                 action: :normalized
               }
             end)

      assert {:ok, compact_codex} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{"default_runner" => "codex"},
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => ["codex", "app-server"]
                   }
                 }
               })

      assert get_in(compact_codex.proposal, ["host", "runners", "codex"]) == %{
               "kind" => "codex_app_server",
               "command" => ["codex", "app-server"],
               "approval_policy" => "never",
               "thread_sandbox" => "workspace-write",
               "turn_timeout_ms" => 3_600_000,
               "read_timeout_ms" => 30_000,
               "stall_timeout_ms" => 300_000,
               "execution_profiles" => %{},
               "max_concurrent_agents" => 10,
               "max_concurrent_startups" => 2
             }

      assert get_in(
               compact_codex.proposal,
               ["targets", "imported", "runners", "settings", "codex"]
             ) == %{
               "model" => "gpt-5.6-sol",
               "max_turns" => 20,
               "execution_profiles" => %{}
             }

      assert {:ok, compact_opencode} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{"default_runner" => "opencode"},
                 "runners" => %{
                   "opencode" => %{
                     "kind" => "opencode_server",
                     "command" => ["opencode", "serve"]
                   }
                 }
               })

      assert get_in(compact_opencode.proposal, ["host", "runners", "opencode"]) == %{
               "kind" => "opencode_server",
               "command" => ["opencode", "serve"],
               "hostname" => "127.0.0.1",
               "port" => "auto",
               "turn_timeout_ms" => 3_600_000,
               "read_timeout_ms" => 30_000,
               "stall_timeout_ms" => 300_000,
               "startup_timeout_ms" => 30_000,
               "execution_profiles" => %{},
               "permissions" => %{},
               "max_concurrent_agents" => 10,
               "max_concurrent_startups" => 2
             }

      assert {:ok, mismatched} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "runners" => %{
                   "opencode" => %{
                     "kind" => "opencode_server",
                     "command" => ["opencode", "serve"],
                     "approval_policy" => "never"
                   }
                 }
               })

      refute mismatched.applicable?

      assert Enum.map(mismatched.import_diagnostics, &{&1.code, &1.path}) == [
               {:unknown_key, "$.runtime.runners.opencode.approval_policy"}
             ]
    end

    test "runs pure applicability preflight for states, query paths, and profile aliases" do
      assert {:ok, state_overlap} =
               preview(%{
                 "tracker" => %{
                   "project_id" => "project-001",
                   "active_states" => ["Todo", " Ready "],
                   "terminal_states" => ["ready", "Done"]
                 }
               })

      refute state_overlap.applicable?

      assert Enum.map(state_overlap.import_diagnostics, &diagnostic_projection/1) == [
               %{
                 path: "$.targets.imported.linear.terminal_states",
                 code: :state_overlap,
                 message: "$.targets.imported.linear.terminal_states overlaps active states: ready"
               }
             ]

      assert {:ok, unsafe_query} =
               preview(%{"tracker" => %{"query_file" => "../../private/query.json"}})

      refute unsafe_query.applicable?

      assert Enum.map(unsafe_query.import_diagnostics, &diagnostic_projection/1) == [
               %{
                 path: "$.targets.imported.linear.scope.query_file",
                 code: :unsafe_path,
                 message: "$.targets.imported.linear.scope.query_file must be a traversal-free relative path"
               }
             ]

      assert {:ok, profile_collision} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => ["codex", "app-server"],
                     "execution_profiles" => %{
                       "Source-Reviewer" => %{"model" => "gpt-5.6-sol"},
                       "source_reviewer" => %{"reasoning_effort" => "high"}
                     }
                   }
                 }
               })

      refute profile_collision.applicable?

      assert Enum.map(profile_collision.import_diagnostics, &diagnostic_projection/1) == [
               %{
                 path: "$.runtime.runners.codex.execution_profiles",
                 code: :execution_profile_name_collision,
                 message: "execution profile names collide after normalization"
               }
             ]

      assert {:ok, safe_query} =
               preview(%{
                 "tracker" => %{
                   "query_file" => "queries/ready.json"
                 }
               })

      refute Enum.any?(safe_query.import_diagnostics, &(&1.code == :unsafe_path))

      assert get_in(safe_query.proposal, ["targets", "imported", "linear", "scope", "query_file"]) ==
               "queries/ready.json"

      assert {:ok, path_overlap} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "workspace" => %{"root" => "/fixtures/repo"}
               })

      refute path_overlap.applicable?

      assert Enum.map(path_overlap.import_diagnostics, &{&1.code, &1.path}) == [
               {:path_overlap, "$.targets.imported.worktree.root"}
             ]

      assert {:ok, state_capacity} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{
                   "max_concurrent_agents" => 2,
                   "max_concurrent_agents_by_state" => %{"Todo" => 3}
                 }
               })

      refute state_capacity.applicable?

      state_path = "$.targets.imported.concurrency.by_linear_state.todo"

      assert Enum.map(state_capacity.import_diagnostics, &diagnostic_projection/1) == [
               %{
                 code: :capacity_exceeded,
                 path: state_path,
                 message: "#{state_path} must not exceed $.targets.imported.concurrency.max_concurrent_agents (2)"
               }
             ]

      assert hd(state_capacity.import_diagnostics).scope == {:target, "imported"}
    end

    test "blocks every present malformed mapped section and field without coercion" do
      base = %{
        "tracker" => %{"project_id" => "project-001"},
        "target" => %{"type" => "project", "project_id" => "project-001"}
      }

      for section <- ~w(tracker target hooks worker workspace polling agent runners quality_gate) do
        assert {:ok, result} = preview(Map.put(base, section, "malformed"))
        refute result.applicable?

        assert Enum.map(result.import_diagnostics, &{&1.code, &1.path}) == [
                 {:invalid_type, "$.runtime.#{section}"}
               ]
      end

      assert {:ok, fields} =
               preview(%{
                 "tracker" => %{
                   "project_id" => "project-001",
                   "kind" => 42,
                   "endpoint" => 42
                 },
                 "target" => %{"display_name" => 42},
                 "workspace" => %{"root" => 42},
                 "polling" => %{"interval_ms" => "fast"},
                 "hooks" => %{
                   "after_run" => 42,
                   "timeout_ms" => "slow",
                   "during_run" => "unsupported"
                 },
                 "worker" => %{
                   "max_concurrent_agents_per_host" => 0,
                   "max_concurrent_startups_per_host" => "two"
                 },
                 "agent" => %{
                   "default_runner" => 42,
                   "max_concurrent_agents" => 0,
                   "max_concurrent_startups" => "two",
                   "max_turns" => 0,
                   "max_concurrent_agents_by_state" => %{"Todo" => 0}
                 },
                 "quality_gate" => %{
                   "enabled" => "false",
                   "source_max_concurrency" => 0
                 }
               })

      refute fields.applicable?

      assert Enum.map(fields.import_diagnostics, &{&1.code, &1.path}) == [
               {:invalid_type, "$.runtime.agent.default_runner"},
               {:invalid_value, "$.runtime.agent.max_concurrent_agents"},
               {:invalid_value, "$.runtime.agent.max_concurrent_agents_by_state.Todo"},
               {:invalid_type, "$.runtime.agent.max_concurrent_startups"},
               {:invalid_value, "$.runtime.agent.max_turns"},
               {:invalid_type, "$.runtime.hooks.after_run"},
               {:unknown_key, "$.runtime.hooks.during_run"},
               {:invalid_type, "$.runtime.hooks.timeout_ms"},
               {:invalid_type, "$.runtime.polling.interval_ms"},
               {:invalid_type, "$.runtime.quality_gate.enabled"},
               {:invalid_value, "$.runtime.quality_gate.source_max_concurrency"},
               {:invalid_type, "$.runtime.target.display_name"},
               {:invalid_type, "$.runtime.tracker.endpoint"},
               {:invalid_type, "$.runtime.tracker.kind"},
               {:invalid_value, "$.runtime.worker.max_concurrent_agents_per_host"},
               {:invalid_type, "$.runtime.worker.max_concurrent_startups_per_host"},
               {:invalid_type, "$.runtime.workspace.root"}
             ]

      assert {:ok, invalid_state_capacities} =
               preview(Map.put(base, "agent", %{"max_concurrent_agents_by_state" => "malformed"}))

      assert Enum.map(invalid_state_capacities.import_diagnostics, &{&1.code, &1.path}) == [
               {:invalid_type, "$.runtime.agent.max_concurrent_agents_by_state"}
             ]

      assert {:ok, explicit_null} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{"default_runner" => "opencode"},
                 "runners" => %{
                   "opencode" => %{
                     "kind" => "opencode_server",
                     "command" => ["opencode", "serve"],
                     "hostname" => nil
                   }
                 }
               })

      refute explicit_null.applicable?

      assert Enum.map(explicit_null.import_diagnostics, &diagnostic_projection/1) == [
               %{
                 code: :invalid_type,
                 path: "$.runtime.runners.opencode.hostname",
                 message: "runner defaulted field must not be null when present"
               }
             ]

      assert {:ok, null_command} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{"default_runner" => "codex"},
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => nil
                   }
                 }
               })

      refute null_command.applicable?

      assert Enum.map(null_command.import_diagnostics, &diagnostic_projection/1) == [
               %{
                 code: :invalid_type,
                 path: "$.runtime.runners.codex.command",
                 message: "runner defaulted field must not be null when present"
               }
             ]

      assert get_in(null_command.proposal, ["host", "runners", "codex", "command"]) == [
               "codex",
               "app-server"
             ]

      assert {:ok, malformed_profiles} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => ["codex", "app-server"],
                     "execution_profiles" => %{
                       "   " => %{"model" => "gpt-5.6-sol"},
                       "bad-profile" => "malformed",
                       "controls" => %{
                         "command" => "codex",
                         "max_retries" => "one"
                       }
                     }
                   }
                 }
               })

      refute malformed_profiles.applicable?

      assert Enum.any?(
               malformed_profiles.import_diagnostics,
               &(&1.code == :invalid_type and
                   &1.path == "$.runtime.runners.codex.execution_profiles.bad-profile")
             )

      assert {:ok, malformed_profile_collection} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => ["codex", "app-server"],
                     "execution_profiles" => "malformed"
                   }
                 }
               })

      refute malformed_profile_collection.applicable?

      assert {:ok, malformed_labels} =
               preview(%{"tracker" => %{"project_id" => "project-001", "required_labels" => 42}})

      refute malformed_labels.applicable?
    end

    test "rejects malformed state keys and lexical worktree paths" do
      assert {:ok, malformed_keys_and_paths} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "workspace" => %{"root" => "relative/worktrees"},
                 "agent" => %{
                   "max_concurrent_agents" => 2,
                   "max_concurrent_agents_by_state" => %{" " => 1}
                 }
               })

      refute malformed_keys_and_paths.applicable?

      assert Enum.any?(
               malformed_keys_and_paths.import_diagnostics,
               &(&1.code == :unsafe_path and &1.path == "$.targets.imported.worktree.root")
             )

      assert Enum.any?(
               malformed_keys_and_paths.import_diagnostics,
               &(&1.code == :invalid_type and
                   &1.path == "$.runtime.agent.max_concurrent_agents_by_state. ")
             )

      assert {:ok, blank_workspace} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "workspace" => %{"root" => " "}
               })

      refute blank_workspace.applicable?
    end

    test "treats options and explicit host input as bounded strict JSON data" do
      source = Yaml.encode(%{"runtime" => %{"tracker" => %{"project_id" => "project-001"}}})

      assert {:error, options_error} = Import.preview(source, [42])
      assert {options_error.code, options_error.path} == {:invalid_type, "$.options"}

      assert {:error, non_list_options_error} = Import.preview(source, :malformed)
      assert {non_list_options_error.code, non_list_options_error.path} == {:invalid_type, "$.options"}

      deep_host =
        Enum.reduce(1..65, "leaf", fn index, nested ->
          %{"level-#{index}" => nested}
        end)

      wide_host = Map.new(1..12_000, &{"entry-#{&1}", &1})

      improper_list_host =
        put_in(host(), ["polling", "values"], ["safe" | "malformed-tail"])

      invalid_utf8_host =
        put_in(host(), ["polling", "value"], <<0xFF>>)

      invalid_hosts = [
        %{id: "atom-key"},
        %{"id" => "string-key", id: "atom-alias"},
        %{42 => "non-string-key"},
        %{<<0xFF>> => "invalid-key"},
        %{"unsupported" => {:tuple, "value"}},
        deep_host,
        wide_host,
        improper_list_host,
        invalid_utf8_host
      ]

      invalid_hosts =
        case maybe_put_non_finite_float(%{"id" => "host"}) do
          %{"nonfinite" => _value} = nonfinite -> [nonfinite | invalid_hosts]
          _finite_runtime -> invalid_hosts
        end

      for invalid_host <- invalid_hosts do
        assert {:error, host_error} =
                 Import.preview(source,
                   source_path: "/fixtures/import.runtime.yml",
                   target_id: "imported",
                   repo_path: "/fixtures/repo",
                   host: invalid_host,
                   current_repo_manifest: @current_repo_manifest
                 )

        assert {host_error.code, host_error.path, host_error.message} ==
                 {:invalid_type, "$.host", "host must be bounded strict JSON with required map containers"}
      end

      for container <- ~w(polling capacity scheduling tracker_connections runners),
          invalid_host <- [Map.delete(host(), container), Map.put(host(), container, "malformed")] do
        assert {:error, host_error} =
                 Import.preview(source,
                   source_path: "/fixtures/import.runtime.yml",
                   target_id: "imported",
                   repo_path: "/fixtures/repo",
                   host: invalid_host,
                   current_repo_manifest: @current_repo_manifest
                 )

        assert host_error.path == "$.host"
      end
    end
  end

  describe "public encoding totality" do
    test "redacts every branch and deterministically bounds unsupported values" do
      assert {:ok, result} =
               preview(%{
                 "tracker" => %{"project_id" => "project-001"},
                 "agent" => %{"default_runner" => "codex"},
                 "runners" => %{
                   "codex" => %{
                     "kind" => "codex_app_server",
                     "command" => ["codex", "app-server"]
                   }
                 }
               })

      branch_values = %{
        source: "/private/source-branch-value",
        effective: "effective-secret-value",
        disposition: "disposition-secret-value",
        difference_before: "difference-secret-before-value",
        difference_effective: "difference-secret-effective-value",
        difference_reason: "difference-secret-reason-value",
        diagnostic: "diagnostic-secret-branch-value",
        connection_id: "connection-secret-identifier",
        connection: "connection-secret-policy-value",
        runner_id: "runner-secret-identifier",
        command: "opaque-argv-value",
        sandbox: "/private/sandbox/root-value",
        target_id: "target-secret-identifier",
        invalid_utf8_context: "invalid-utf8-secret-neighbor-value",
        collision_atom: "collision-secret-atom-value",
        collision_string: "collision-secret-string-value",
        deep: "deep-secret-terminal-value",
        wide: "wide-secret-terminal-value"
      }

      deep =
        Enum.reduce(1..80, branch_values.deep, fn index, nested ->
          %{"level-#{index}" => nested}
        end)

      wide = Map.new(1..10_001, &{"entry-#{&1}", branch_values.wide})

      unsafe_policy =
        %{
          "private_policy" => branch_values.effective,
          "invalid_utf8" => <<0xFF>>,
          "invalid_utf8_context" => branch_values.invalid_utf8_context,
          "aliases" => %{
            "source" => branch_values.collision_string,
            source: branch_values.collision_atom
          },
          "unsupported_keys" => %{42 => branch_values.effective},
          "deep" => deep,
          "wide" => wide
        }
        |> maybe_put_non_finite_float()

      proposal =
        result.proposal
        |> put_in(
          ["host", "tracker_connections"],
          %{
            branch_values.connection_id => %{
              "kind" => "linear",
              "endpoint" => "https://linear.example.test/graphql",
              "api_key" => branch_values.connection
            }
          }
        )
        |> put_in(
          ["host", "runners"],
          %{
            branch_values.runner_id => %{
              "kind" => "codex_app_server",
              "command" => ["codex", branch_values.command, "app-server"],
              "turn_sandbox_policy" => %{
                "type" => "workspaceWrite",
                "writableRoots" => [branch_values.sandbox]
              }
            }
          }
        )

      registry_preview =
        %{
          result.registry_preview
          | targets: [
              %{
                id: branch_values.target_id,
                configured_state: :paused,
                effective_state: :paused,
                dispatch_mode: nil,
                valid?: true,
                policy_hash: nil
              }
            ],
            diff: [
              %{
                path: "$.host.runners.codex.command",
                before: nil,
                after: ["codex", branch_values.command, "app-server"],
                classification: :added
              }
            ]
        }

      malicious =
        %{
          result
          | source: %{path: branch_values.source, checksum: result.source.checksum},
            current_repo_manifest: unsafe_policy,
            effective_preview_target: %{
              "repo" => unsafe_policy,
              "linear" => %{"required_labels" => ["safe"]}
            },
            proposal: proposal,
            registry_preview: registry_preview,
            field_dispositions: [
              %{
                source_path: "$.runtime.#{branch_values.disposition}",
                destination_path: "$.targets.imported.#{branch_values.disposition}",
                action: :mapped
              }
            ],
            import_diagnostics: [
              %Diagnostic{
                severity: :error,
                scope: :registry,
                path: "$.runtime.diagnostic",
                code: :invalid_value,
                message: branch_values.diagnostic
              }
            ],
            source_differences: [
              %{
                source_path: 42,
                destination_path: "$.targets.imported.policy",
                classification: :source_difference,
                source: branch_values.difference_before,
                effective: branch_values.difference_effective,
                reason: branch_values.difference_reason
              }
            ]
        }

      for encode <- [&Import.encode_preview/1, &Import.encode_repo_policy_preview/1] do
        encoded = encode.(malicious)

        assert {:ok, _decoded} = Jason.decode(encoded)
        assert encoded == encode.(malicious)
        assert byte_size(encoded) < 1_000_000

        for value <- Map.values(branch_values) do
          refute encoded =~ value
        end

        refute encoded =~ <<0xFF>>
      end

      assert Import.encode_preview(malicious) =~ "[REDACTED]"
    end

    test "encoders never raise or expose malformed result branches" do
      assert {:ok, result} = preview(%{"tracker" => %{"project_id" => "project-001"}})
      secret = "malformed-result-secret-never-render"

      preview = result.registry_preview
      proposal = result.proposal

      malformed_results = [
        %{result | registry_preview: %{"private_preview" => secret}},
        %{result | registry_preview: %{preview | impact: :malformed}},
        %{result | registry_preview: %{preview | diff: :malformed}},
        %{result | registry_preview: %{preview | diff: [:malformed]}},
        %{result | field_dispositions: [secret | :malformed_tail]},
        %{result | field_dispositions: :malformed},
        %{result | field_dispositions: [:malformed]},
        %{result | source_differences: [%{"private_difference" => secret}]},
        %{result | source_differences: :malformed},
        %{result | source_differences: [:malformed]},
        %{result | source: :malformed},
        %{result | proposal: :malformed},
        %{result | proposal: Map.put(proposal, "host", :malformed)},
        %{
          result
          | proposal: put_in(proposal, ["host", "tracker_connections"], :malformed)
        },
        %{
          result
          | proposal:
              put_in(proposal, ["host", "tracker_connections"], %{
                "without-api-key" => %{"kind" => "linear"},
                "malformed" => :malformed
              })
        },
        %{result | proposal: put_in(proposal, ["host", "runners"], :malformed)},
        %{
          result
          | proposal:
              put_in(proposal, ["host", "runners"], %{
                "malformed" => :malformed,
                "policy-map" => %{"turn_sandbox_policy" => %{}},
                "policy-term" => %{"turn_sandbox_policy" => :malformed}
              })
        },
        %{
          result
          | import_diagnostics: [
              %Diagnostic{
                severity: :error,
                scope: :malformed,
                path: secret,
                code: :malformed,
                message: secret
              }
            ]
        },
        %{result | effective_preview_target: %URI{path: secret}},
        %{result | effective_preview_target: {:tuple, secret}},
        %{result | effective_preview_target: 1.5},
        %{result | effective_preview_target: fn -> secret end},
        %{result | effective_preview_target: List.duplicate(%{"value" => 1}, 10_001)},
        %{
          result
          | current_repo_manifest: %{"private_manifest" => secret},
            effective_preview_target: %{"private_target" => secret}
        }
      ]

      for malformed <- malformed_results,
          encode <- [&Import.encode_preview/1, &Import.encode_repo_policy_preview/1] do
        encoded = encode.(malformed)
        assert {:ok, _decoded} = Jason.decode(encoded)
        assert encoded == encode.(malformed)
        refute encoded =~ secret
      end

      for encode <- [&Import.encode_preview/1, &Import.encode_repo_policy_preview/1] do
        assert encode.(:malformed) == "\"[REDACTED]\""
      end
    end
  end

  describe "sanitized import goldens" do
    test "main and direct Codex fixtures produce exact isolated paused previews" do
      {main, main_source, main_checksum} = import_fixture("main.runtime.yml", "main")

      {direct, direct_source, direct_checksum} =
        import_fixture("direct_codex.runtime.yml", "direct-codex")

      main_target = get_in(main.proposal, ["targets", "main"])
      direct_target = get_in(direct.proposal, ["targets", "direct-codex"])

      assert Map.keys(main.proposal["targets"]) == ["main"]
      assert Map.keys(direct.proposal["targets"]) == ["direct-codex"]
      refute main.source.checksum == direct.source.checksum

      assert main_target["state"] == "paused"
      refute Map.has_key?(main_target, "dispatch_mode")

      for {result, target_id, target} <- [
            {main, "main", main_target},
            {direct, "direct-codex", direct_target}
          ] do
        assert target["budgets"] == %{}
        assert target["scheduling"] == %{}
        refute Map.has_key?(target, "external_side_effects")

        snapshot_target = result.snapshot.targets[target_id]
        refute snapshot_target.valid?
        assert snapshot_target.effective_state == :paused
        assert snapshot_target.repo_manifest == nil
        assert snapshot_target.effective_policy == nil
        assert snapshot_target.policy_hash == nil
        assert length(snapshot_target.diagnostics) == 5
        assert result.applicable?
      end

      assert main_target["linear"]["scope"] == %{
               "type" => "project",
               "project_id" => "project-main-001"
             }

      assert main_target["worktree"]["root"] == "/fixtures/main-worktrees/main"
      assert get_in(main_target, ["runners", "settings", "codex", "model"]) == "gpt-5.5"
      assert main_target["concurrency"]["max_concurrent_agents"] == 3
      assert main_target["concurrency"]["max_concurrent_startups"] == 2

      assert direct_target["state"] == "paused"
      refute Map.has_key?(direct_target, "dispatch_mode")

      assert direct_target["linear"]["scope"] == %{
               "type" => "project",
               "project_slug" => "direct-project"
             }

      assert direct_target["worktree"]["root"] ==
               "/fixtures/direct-worktrees/direct-codex"

      assert direct_target["worktree"]["hooks"]["before_run"] == "mise exec -- jj status"

      assert get_in(direct.proposal, ["host", "runners", "codex", "command"]) == [
               "/opt/synthetic/bin/codex",
               "--fixture-flag",
               "direct",
               "app-server"
             ]

      assert get_in(
               direct.proposal,
               ["host", "runners", "codex", "turn_sandbox_policy", "networkAccess"]
             )

      assert get_in(
               direct_target,
               ["runners", "settings", "codex", "reasoning_effort"]
             ) == "xhigh"

      assert map_size(
               get_in(
                 direct_target,
                 ["runners", "settings", "codex", "execution_profiles"]
               )
             ) == 2

      assert direct_target["checks"]["pre_handoff"] == ["quality_gate"]
      assert direct_target["concurrency"]["max_concurrent_agents"] == 10
      assert direct_target["concurrency"]["max_concurrent_startups"] == 2

      assert get_in(main.proposal, ["host", "tracker_connections", "linear", "api_key"]) ==
               "$LINEAR_API_KEY"

      main_json = Import.encode_preview(main)
      direct_json = Import.encode_preview(direct)
      stale_json = Import.encode_repo_policy_preview(main)

      assert main_json == Import.encode_preview(main)
      assert direct_json == Import.encode_preview(direct)
      assert stale_json == Import.encode_repo_policy_preview(main)

      assert {:ok, stale_preview} = Jason.decode(stale_json)
      assert "repo:symphony" in stale_preview["effective_required_labels"]

      assert get_in(stale_preview, ["current_repo_manifest", "issue_markers", "labels"]) == [
               "repo:symphony"
             ]

      assert stale_preview["policy_hash"] == nil
      refute stale_json =~ "sha256:"

      assert_golden("expected/main_preview.json", main_json)
      assert_golden("expected/direct_codex_preview.json", direct_json)
      assert_golden("expected/stale_repo_policy_preview.json", stale_json)

      for json <- [main_json, direct_json, stale_json] do
        refute json =~ "$LINEAR_API_KEY"
        refute json =~ "synthetic-secret"
        refute json =~ "/Users/"
      end

      assert main_json =~ "[REDACTED]"
      assert direct_json =~ "[REDACTED]"
      assert main_json =~ "\"dispatch_mode\": null"
      assert direct_json =~ "\"dispatch_mode\": null"
      refute direct_json =~ "/fixtures/direct-worktrees"
      refute direct_json =~ "\"source_reviewer\""

      assert File.read!(fixture_path("main.runtime.yml")) == main_source
      assert File.read!(fixture_path("direct_codex.runtime.yml")) == direct_source
      assert :crypto.hash(:sha256, main_source) == main_checksum
      assert :crypto.hash(:sha256, direct_source) == direct_checksum
    end

    test "ambiguous fixture has one exact blocking diagnostic and remains unchanged" do
      {result, source, checksum} =
        import_fixture("ambiguous_scope.runtime.yml", "ambiguous")

      refute result.applicable?

      assert Enum.map(result.import_diagnostics, fn diagnostic ->
               %{
                 severity: diagnostic.severity,
                 scope: diagnostic.scope,
                 path: diagnostic.path,
                 code: diagnostic.code,
                 message: diagnostic.message
               }
             end) == [
               %{
                 severity: :error,
                 scope: :registry,
                 path: "$.runtime.tracker",
                 code: :ambiguous_import_scope,
                 message: "runtime selects more than one tracker scope"
               }
             ]

      assert File.read!(fixture_path("ambiguous_scope.runtime.yml")) == source
      assert :crypto.hash(:sha256, source) == checksum
    end
  end

  defp import_fixture(name, target_id) do
    path = fixture_path(name)
    source = File.read!(path)
    checksum = :crypto.hash(:sha256, source)

    assert {:ok, result} =
             Import.preview(source,
               target_id: target_id,
               source_path: Path.relative_to_cwd(path),
               repo_path: "/fixtures/repo",
               host: host(),
               current_repo_manifest: @current_repo_manifest
             )

    {result, source, checksum}
  end

  defp assert_golden(relative_path, actual) do
    path = fixture_path(relative_path)

    assert File.read!(path) == actual
  end

  defp fixture_path(relative_path), do: Path.join(@fixture_root, relative_path)

  defp import_source(source) do
    Import.preview(source,
      target_id: "imported",
      source_path: "/fixtures/import.runtime.yml",
      repo_path: "/fixtures/repo",
      host: host(),
      current_repo_manifest: @current_repo_manifest
    )
  end

  defp preview(runtime, opts \\ []) do
    preview_document(%{"runtime" => runtime}, opts)
  end

  defp preview_document(document, opts \\ []) do
    source = Yaml.encode(document)

    Import.preview(source,
      target_id: "imported",
      source_path: "/fixtures/import.runtime.yml",
      repo_path: "/fixtures/repo",
      host: Keyword.get(opts, :host, host()),
      connection_id: Keyword.get(opts, :connection_id, "linear"),
      current_repo_manifest: Keyword.get(opts, :current_repo_manifest, @current_repo_manifest)
    )
  end

  defp diagnostic_projection(diagnostic) do
    %{path: diagnostic.path, code: diagnostic.code, message: diagnostic.message}
  end

  defp maybe_put_non_finite_float(policy) do
    external_positive_infinity = <<131, 70, 0x7F, 0xF0, 0, 0, 0, 0, 0, 0>>

    try do
      Map.put(policy, "nonfinite", :erlang.binary_to_term(external_positive_infinity))
    rescue
      ArgumentError -> policy
    end
  end

  defp host do
    %{
      "id" => "fixture-host",
      "state_root" => "/fixtures/state",
      "polling" => %{"interval_ms" => 30_000, "max_concurrent_target_polls" => 1},
      "capacity" => %{
        "max_concurrent_agents" => 20,
        "max_concurrent_startups" => 4,
        "max_concurrent_reviewers" => 4
      },
      "scheduling" => %{
        "algorithm" => "weighted_deficit_round_robin",
        "max_credit_rounds" => 4
      },
      "tracker_connections" => %{},
      "runners" => %{}
    }
  end
end
