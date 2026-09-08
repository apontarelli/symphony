defmodule SymphonyElixir.TargetRegistry.LegacyImportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TargetRegistry.LegacyImport
  alias SymphonyElixir.TargetRegistry.Yaml
  alias SymphonyElixir.Workflow.Manifest

  @manifest_fixture_source Path.expand("../../fixtures/target_registry/repos/symphony", __DIR__)
  @manifest_fixture_root Path.join(System.tmp_dir!(), "legacy-import-repo-#{System.unique_integer([:positive])}")

  setup_all do
    File.cp_r!(@manifest_fixture_source, @manifest_fixture_root)
    git!(@manifest_fixture_root, ["init", "--initial-branch=main"])
    git!(@manifest_fixture_root, ["remote", "add", "origin", "https://github.com/example/symphony-fixture.git"])
    git!(@manifest_fixture_root, ["add", "."])
    git!(@manifest_fixture_root, ["-c", "user.name=Legacy Import Tests", "-c", "user.email=legacy-import-tests@example.invalid", "commit", "-m", "fixture"])
    on_exit(fn -> File.rm_rf!(@manifest_fixture_root) end)
    :ok
  end

  describe "manifest_bindings/2" do
    test "binds only explicit repo.manifest references" do
      legacy = %{
        "targets" => %{
          "legacy-app" => %{"repo" => %{"path" => "/repos/app", "manifest" => "symphony.yml"}},
          "custom" => %{"repo" => %{"path" => "/repos/other", "manifest" => "policy.yml"}},
          "inlined" => %{"repo" => %{"path" => "/repos/inline"}, "repository_policy" => %{}},
          "profile-only" => %{"repo" => %{"path" => "/repos/profile", "expected_repository" => "https://example/profile"}}
        }
      }

      current = %{"targets" => %{"current-legacy" => %{"repo" => %{"path" => "/repos/current", "manifest" => "symphony.yml"}}}}

      assert [
               %{target_id: "current-legacy", repo_path: "/repos/current", manifest_path: "/repos/current/symphony.yml"},
               %{target_id: "custom", repo_path: "/repos/other", manifest_path: "/repos/other/policy.yml"},
               %{target_id: "legacy-app", repo_path: "/repos/app", manifest_path: "/repos/app/symphony.yml"}
             ] = LegacyImport.manifest_bindings(current, legacy)
    end

    test "returns nothing for current-format registries" do
      current = %{"targets" => %{"app" => %{"repo" => %{"path" => "/repos/app"}, "repository_policy" => %{}}}}

      assert [] = LegacyImport.manifest_bindings(current, nil)
    end

    test "malformed target entries bind no manifests instead of raising" do
      legacy = %{
        "targets" => %{
          "scalar" => 42,
          "listed" => ["invalid"],
          "app" => %{"repo" => %{"path" => "/repos/app", "manifest" => "symphony.yml"}}
        }
      }

      current = %{"targets" => %{"string" => "invalid", "null" => nil}}

      assert [%{target_id: "app", repo_path: "/repos/app", manifest_path: "/repos/app/symphony.yml"}] =
               LegacyImport.manifest_bindings(current, legacy)
    end
  end

  describe "preview/1 with a local config source" do
    test "maps tracker connection and runners; equal host values are unchanged" do
      {:ok, result} =
        LegacyImport.preview(
          current_document: current_registry(),
          current_bytes: Yaml.encode(current_registry()),
          local_config: %{
            path: "~/.config/symphony/config.yml",
            document: local_config()
          },
          connection_id: "linear-main",
          registry_path: "/registry/targets.yml"
        )

      host = result.proposal["host"]

      assert host["tracker_connections"]["linear-main"]["api_key"] == "$LINEAR_API_KEY"
      assert host["tracker_connections"]["linear-main"]["endpoint"] == "https://api.linear.app/graphql"
      assert host["runners"]["codex"]["command"] == ["codex", "app-server"]
      assert host["runners"]["codex"]["max_concurrent_agents"] == 1
      assert host["runners"]["codex"]["max_concurrent_startups"] == 1
      assert host["polling"]["interval_ms"] == 45_000
      assert host["capacity"]["max_concurrent_agents"] == 20
      # Field-wise application never removes registry fields the fragment
      # does not carry.
      assert host["capacity"]["max_concurrent_reviewers"] == 1

      assert result.applicable?

      actions = disposition_actions(result)
      assert :mapped in actions
      assert :defaulted_restrictive in actions
      assert :unchanged in actions
      refute :host_entry_conflict in actions

      assert [%{kind: "local_config", path: "~/.config/symphony/config.yml", checksum: nil}] = result.sources
    end

    test "any unmappable local configuration field blocks instead of being dropped" do
      for key <- ["agent", "workspace", "capacity_profiles", "repository_browser", "totally_unknown"] do
        {:ok, result} =
          LegacyImport.preview(
            current_document: current_registry(),
            current_bytes: Yaml.encode(current_registry()),
            local_config: %{path: "/config.yml", document: Map.put(local_config(), key, %{})},
            registry_path: "/registry/targets.yml"
          )

        refute result.applicable?, "expected #{key} to block the import"

        assert Enum.any?(
                 result.import_diagnostics,
                 &(&1.code == :unsupported_field and &1.path == "$.#{key}")
               )

        assert Enum.any?(result.source_differences, &(&1.source_path == "$.#{key}" and &1.classification == "unsupported"))
      end
    end

    test "unknown nested fields inside mappable sections block" do
      config =
        local_config()
        |> put_in(["tracker", "assignee"], "me")
        |> put_in(["polling", "jitter_ms"], 10)
        |> Map.put("deployment", %{"strategy" => "rolling"})

      {:ok, result} =
        LegacyImport.preview(
          current_document: current_registry(),
          current_bytes: Yaml.encode(current_registry()),
          local_config: %{path: "/config.yml", document: config},
          registry_path: "/registry/targets.yml"
        )

      refute result.applicable?

      for path <- ["$.tracker.assignee", "$.polling.jitter_ms", "$.deployment.strategy"] do
        assert Enum.any?(result.import_diagnostics, &(&1.code == :unsupported_field and &1.path == path))
      end
    end

    test "rejects inline credentials instead of copying them" do
      config = put_in(local_config(), ["tracker", "api_key"], "lin_api_supersecret")

      {:ok, result} =
        LegacyImport.preview(
          current_document: current_registry(),
          current_bytes: Yaml.encode(current_registry()),
          local_config: %{path: "/config.yml", document: config},
          registry_path: "/registry/targets.yml"
        )

      refute result.applicable?
      assert Enum.any?(result.import_diagnostics, &(&1.code == :inline_credential_rejected))
    end

    test "blocks unmappable tracker policy rather than dropping it" do
      config =
        local_config()
        |> put_in(["tracker", "active_states"], ["Todo"])
        |> put_in(["tracker", "required_labels"], ["ready"])

      {:ok, result} =
        LegacyImport.preview(
          current_document: current_registry(),
          current_bytes: Yaml.encode(current_registry()),
          local_config: %{path: "/config.yml", document: config},
          registry_path: "/registry/targets.yml"
        )

      refute result.applicable?

      assert Enum.any?(
               result.import_diagnostics,
               &(&1.code == :unmapped_tracker_policy and &1.path == "$.tracker.active_states")
             )
    end

    test "a local config value differing from the registry blocks" do
      conflicting = put_in(local_config(), ["polling", "interval_ms"], 61_000)

      {:ok, result} =
        LegacyImport.preview(
          current_document: current_registry(),
          current_bytes: Yaml.encode(current_registry()),
          local_config: %{path: "/config.yml", document: conflicting},
          registry_path: "/registry/targets.yml"
        )

      refute result.applicable?

      assert Enum.any?(
               result.import_diagnostics,
               &(&1.code == :host_entry_conflict and &1.path == "$.host.polling.interval_ms")
             )
    end
  end

  describe "preview/1 with a legacy registry source" do
    test "migrates manifest-backed targets paused with inlined repository policy" do
      legacy = legacy_registry()

      {:ok, result} =
        LegacyImport.preview(
          current_document: current_registry(),
          current_bytes: Yaml.encode(current_registry()),
          legacy_registry: %{path: "/legacy/targets.yml", document: legacy},
          manifests: manifest_fixture(),
          registry_path: "/registry/targets.yml"
        )

      assert result.applicable?, inspect(result.snapshot.diagnostics)
      assert result.import_diagnostics == []

      target = result.proposal["targets"]["legacy-app"]
      assert target["state"] == "paused"
      refute Map.has_key?(target, "dispatch_mode")
      refute Map.has_key?(target["repo"], "manifest")
      assert target["repo"]["path"] == @manifest_fixture_root
      assert target["repo"]["expected_repository"] == "https://github.com/example/symphony-fixture"

      inlined = target["repository_policy"]
      assert %{} = inlined
      assert get_in(inlined, ["validation", "commands"]) |> hd() == %{"name" => "focused", "command" => "mix test"}
      assert get_in(inlined, ["auto_land", "force_human_review_labels"]) == ["human-review"]
      assert get_in(inlined, ["capabilities", "required"]) == ["github_pr", "browser"]

      assert [%{verdict: :preserved, findings: []}] = result.parity

      actions = disposition_actions(result)
      assert :forced_paused in actions
      assert :inlined_repository_policy in actions

      host = result.proposal["host"]
      assert host["tracker_connections"]["linear-main"]["kind"] == "linear"
      assert host["runners"]["legacy-codex"]["max_concurrent_agents"] == 1
      # Supported shared repository policy layers carry into the proposal.
      assert host["repository_profiles"]["reviewed"]["auto_land"]["posture"] == "off"
      assert host["repository_defaults"]["delivery"]["pr_target"] == "main"
    end

    test "an in-place legacy registry migrates through the same contract" do
      legacy = legacy_registry()

      {:ok, result} =
        LegacyImport.preview(
          current_document: legacy,
          current_bytes: Yaml.encode(legacy),
          legacy_registry: %{path: "/registry/targets.yml", document: legacy},
          manifests: manifest_fixture(),
          registry_path: "/registry/targets.yml"
        )

      assert result.applicable?
      assert result.import_diagnostics == []

      target = result.proposal["targets"]["legacy-app"]
      assert target["state"] == "paused"
      refute Map.has_key?(target["repo"], "manifest")
      assert target["repository_policy"]["project"]["slug"] == "symphony-fixture"
    end

    test "a repeated import of the migrated registry is an explicit no-op" do
      legacy = legacy_registry()

      {:ok, first} =
        LegacyImport.preview(
          current_document: current_registry(),
          current_bytes: Yaml.encode(current_registry()),
          legacy_registry: %{path: "/legacy/targets.yml", document: legacy},
          manifests: manifest_fixture(),
          registry_path: "/registry/targets.yml"
        )

      migrated = first.proposal

      {:ok, again} =
        LegacyImport.preview(
          current_document: migrated,
          current_bytes: first.proposed_bytes,
          legacy_registry: %{path: "/legacy/targets.yml", document: legacy},
          manifests: manifest_fixture(),
          registry_path: "/registry/targets.yml"
        )

      assert again.applicable?
      assert again.proposal == migrated
      assert Enum.any?(again.field_dispositions, &(&1.action == :unchanged))
    end

    test "a registry target that differs from the legacy target is a blocking conflict" do
      legacy = legacy_registry()

      diverged =
        current_registry()
        |> put_in(["targets", "legacy-app"], legacy_target() |> Map.put("display_name", "Diverged"))

      {:ok, result} =
        LegacyImport.preview(
          current_document: diverged,
          current_bytes: Yaml.encode(diverged),
          legacy_registry: %{path: "/legacy/targets.yml", document: legacy},
          manifests: manifest_fixture(),
          registry_path: "/registry/targets.yml"
        )

      refute result.applicable?

      assert Enum.any?(
               result.import_diagnostics,
               &(&1.code == :target_conflict and &1.path == "$.targets.legacy-app")
             )
    end

    test "profile-only targets are carried paused without rereading a manifest" do
      legacy =
        legacy_registry()
        |> put_in(["targets", "legacy-app"], profile_only_target())

      assert [] = LegacyImport.manifest_bindings(current_registry(), legacy)

      {:ok, result} =
        LegacyImport.preview(
          current_document: current_registry(),
          current_bytes: Yaml.encode(current_registry()),
          legacy_registry: %{path: "/legacy/targets.yml", document: legacy},
          manifests: %{},
          registry_path: "/registry/targets.yml"
        )

      target = result.proposal["targets"]["legacy-app"]
      assert target["state"] == "paused"
      refute Map.has_key?(target, "dispatch_mode")
      refute Map.has_key?(target, "repository_policy")
      assert Enum.any?(result.field_dispositions, &(&1.action == :forced_paused))
    end

    test "weakened restrictions block the import with parity findings" do
      legacy = legacy_registry()
      weakened = weakened_manifest()

      {:ok, result} =
        LegacyImport.preview(
          current_document: current_registry(),
          current_bytes: Yaml.encode(current_registry()),
          legacy_registry: %{path: "/legacy/targets.yml", document: legacy},
          manifests: weakened,
          registry_path: "/registry/targets.yml"
        )

      refute result.applicable?

      assert [%{verdict: :weakened, findings: findings}] = result.parity
      codes = Enum.map(findings, & &1.code)
      assert :validation_command_dropped in codes
      assert :required_capability_dropped in codes
    end

    test "local config and legacy registry disagreements block instead of guessing" do
      legacy = legacy_registry()

      conflicting_config =
        put_in(
          local_config(),
          ["polling", "interval_ms"],
          61_000
        )

      {:ok, result} =
        LegacyImport.preview(
          current_document: current_registry(),
          current_bytes: Yaml.encode(current_registry()),
          local_config: %{path: "/config.yml", document: conflicting_config},
          legacy_registry: %{path: "/legacy/targets.yml", document: legacy},
          manifests: manifest_fixture(),
          registry_path: "/registry/targets.yml"
        )

      refute result.applicable?

      assert Enum.any?(
               result.import_diagnostics,
               &(&1.code == :import_source_conflict and &1.path == "$.host.polling.interval_ms")
             )
    end

    test "disagreeing connection entries between the two legacy sources block" do
      legacy = legacy_registry()

      conflicting_config =
        put_in(
          local_config(),
          ["tracker", "endpoint"],
          "https://linear.conflicting.example/graphql"
        )

      {:ok, result} =
        LegacyImport.preview(
          current_document: current_registry(),
          current_bytes: Yaml.encode(current_registry()),
          local_config: %{path: "/config.yml", document: conflicting_config},
          legacy_registry: %{path: "/legacy/targets.yml", document: legacy},
          connection_id: "linear-main",
          manifests: manifest_fixture(),
          registry_path: "/registry/targets.yml"
        )

      refute result.applicable?

      assert Enum.any?(
               result.import_diagnostics,
               &(&1.code == :import_source_conflict and &1.path == "$.host.tracker_connections.linear-main")
             )
    end

    test "unknown legacy host fields block instead of being dropped" do
      legacy = put_in(legacy_registry(), ["host", "mystery_section"], %{"policy" => true})

      {:ok, result} =
        LegacyImport.preview(
          current_document: current_registry(),
          current_bytes: Yaml.encode(current_registry()),
          legacy_registry: %{path: "/legacy/targets.yml", document: legacy},
          manifests: manifest_fixture(),
          registry_path: "/registry/targets.yml"
        )

      refute result.applicable?

      assert Enum.any?(
               result.import_diagnostics,
               &(&1.code == :unsupported_host_field and &1.path == "$.host.mystery_section")
             )
    end

    test "malformed target entries block with typed diagnostics instead of raising" do
      current = put_in(current_registry(), ["targets"], %{"scalar" => 42, "null" => nil})
      legacy = put_in(legacy_registry(), ["targets", "string-entry"], "invalid")

      {:ok, result} =
        LegacyImport.preview(
          current_document: current,
          current_bytes: Yaml.encode(current),
          legacy_registry: %{path: "/legacy/targets.yml", document: legacy},
          manifests: manifest_fixture(),
          registry_path: "/registry/targets.yml"
        )

      refute result.applicable?

      for path <- ["$.targets.scalar", "$.targets.null", "$.targets.string-entry"] do
        assert Enum.any?(
                 result.import_diagnostics,
                 &(&1.code == :invalid_type and &1.path == path and &1.severity == :error and
                     &1.scope == {:target, String.trim_leading(path, "$.targets.")})
               )
      end

      # Registry entries are neither dropped nor rewritten, and malformed
      # legacy entries never reach the proposal.
      assert result.proposal["targets"]["scalar"] == 42
      assert result.proposal["targets"]["null"] == nil
      refute Map.has_key?(result.proposal["targets"], "string-entry")
    end

    test "a registry missing its host section is rejected" do
      assert {:error, :current_registry_missing_host} =
               LegacyImport.preview(
                 current_document: %{"version" => 1, "targets" => %{}},
                 current_bytes: "version: 1\ntargets: {}\n",
                 legacy_registry: %{path: "/legacy/targets.yml", document: legacy_registry()},
                 manifests: manifest_fixture(),
                 registry_path: "/registry/targets.yml"
               )
    end
  end

  defp disposition_actions(result), do: Enum.map(result.field_dispositions, & &1.action)

  defp current_registry do
    %{
      "version" => 1,
      "host" => %{
        "id" => "current-host",
        "capabilities" => ["github_pr", "browser"],
        "state_root" => "/registry-state",
        "polling" => %{"interval_ms" => 45_000, "max_concurrent_target_polls" => 1},
        "capacity" => %{
          "max_concurrent_agents" => 20,
          "max_concurrent_startups" => 1,
          "max_concurrent_reviewers" => 1
        },
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 4},
        "tracker_connections" => %{},
        "runners" => %{}
      },
      "targets" => %{}
    }
  end

  # Only fields the cutover can place on the host; every other legacy field
  # blocks, so the fixture must stay minimal.
  defp local_config do
    %{
      "version" => 1,
      "tracker" => %{
        "kind" => "linear",
        "endpoint" => "https://api.linear.app/graphql",
        "api_key" => "$LINEAR_API_KEY"
      },
      "polling" => %{"interval_ms" => 45_000},
      "capacity_ceiling" => 20,
      "runners" => %{
        "codex" => %{
          "kind" => "codex_app_server",
          "command" => ["codex", "app-server"],
          "approval_policy" => "never"
        }
      }
    }
  end

  defp legacy_registry do
    %{
      "version" => 1,
      "host" => %{
        "id" => "legacy-host",
        "capabilities" => ["github_pr", "browser"],
        "state_root" => "/legacy-state",
        "polling" => %{"interval_ms" => 45_000, "max_concurrent_target_polls" => 1},
        "capacity" => %{
          "max_concurrent_agents" => 20,
          "max_concurrent_startups" => 1,
          "max_concurrent_reviewers" => 1
        },
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 4},
        "tracker_connections" => %{
          "linear-main" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "$LINEAR_API_KEY"
          }
        },
        "runners" => %{
          "legacy-codex" => %{
            "kind" => "codex_app_server",
            "command" => ["codex", "app-server"],
            "approval_policy" => "never",
            "max_concurrent_agents" => 1,
            "max_concurrent_startups" => 1
          }
        },
        "repository_defaults" => %{"delivery" => %{"pr_target" => "main"}},
        "repository_profiles" => %{
          "reviewed" => %{"auto_land" => %{"posture" => "off", "dry_run" => true}}
        }
      },
      "targets" => %{"legacy-app" => legacy_target()}
    }
  end

  defp legacy_target do
    %{
      "state" => "active",
      "dispatch_mode" => "watch",
      "repo" => %{"path" => @manifest_fixture_root, "manifest" => "symphony.yml"},
      "worktree" => %{
        "root" => Path.join(System.tmp_dir!(), "legacy-import-worktrees"),
        "strategy" => "per_issue"
      },
      "linear" => %{
        "connection" => "linear-main",
        "scope" => %{"type" => "project", "project_id" => "legacy-project-001"},
        "active_states" => ["Todo", "In Progress"],
        "terminal_states" => ["Done", "Canceled"],
        "required_labels" => []
      },
      "runners" => %{"allowed" => ["legacy-codex"], "default" => "legacy-codex", "settings" => %{}},
      "concurrency" => %{
        "max_concurrent_agents" => 1,
        "max_concurrent_startups" => 1,
        "max_concurrent_reviewers" => 1
      },
      "budgets" => %{
        "per_run" => %{"max_total_tokens" => 500_000},
        "daily" => %{"max_total_tokens" => 5_000_000},
        "weekly" => %{"max_total_tokens" => 20_000_000}
      },
      "checks" => %{"pre_dispatch" => []},
      "external_side_effects" => %{
        "tracker_write" => "allow",
        "vcs_publish" => "manual_approval",
        "pull_request_write" => "manual_approval",
        "merge" => "deny",
        "deployment" => "deny",
        "production_data" => "deny"
      },
      "scheduling" => %{"weight" => 10}
    }
  end

  defp profile_only_target do
    legacy_target()
    |> put_in(["repo"], %{
      "path" => @manifest_fixture_root,
      "expected_repository" => "https://github.com/example/symphony-fixture"
    })
    |> Map.put("repository_profile", "reviewed")
  end

  defp manifest_fixture do
    manifest_path = Path.join(@manifest_fixture_root, "symphony.yml")

    {:ok, raw} = manifest_path |> File.read!() |> Yaml.decode()
    {:ok, manifest} = Manifest.read(manifest_path, repo_setup?: true)
    %{config: %{"manifest" => compiled}} = Manifest.compile(manifest)
    %{manifest_path => %{raw: raw, compiled: compiled}}
  end

  defp weakened_manifest do
    manifest_path = Path.join(@manifest_fixture_root, "symphony.yml")
    %{^manifest_path => %{raw: raw, compiled: compiled}} = manifest_fixture()

    weakened =
      compiled
      |> put_in(["validation", "commands"], [])
      |> put_in(["capabilities", "required"], [])

    %{manifest_path => %{raw: raw, compiled: weakened}}
  end

  defp git!(repo, args) do
    {output, status} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    assert status == 0, output
  end
end
