defmodule SymphonyElixir.HostScheduler.RegistryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HostScheduler.Registry
  alias SymphonyElixir.TargetRegistry.Yaml
  @manifest_fixture_root Path.expand("../../fixtures/target_registry/repos/symphony", __DIR__)

  @tag :tmp_dir
  test "loads one verified file generation for host scheduling", %{tmp_dir: tmp_dir} do
    registry_path = Path.join(tmp_dir, "targets.yml")
    state_root = Path.join(Path.dirname(tmp_dir), Path.basename(tmp_dir) <> "-state")

    document = %{
      "version" => 1,
      "host" => %{
        "id" => "test-host",
        "state_root" => state_root,
        "polling" => %{"interval_ms" => 25, "max_concurrent_target_polls" => 2},
        "capacity" => %{
          "max_concurrent_agents" => 3,
          "max_concurrent_startups" => 2,
          "max_concurrent_reviewers" => 1
        },
        "scheduling" => %{
          "algorithm" => "weighted_deficit_round_robin",
          "max_credit_rounds" => 3
        },
        "tracker_connections" => %{
          "linear" => %{
            "kind" => "linear",
            "endpoint" => "https://tracker.example.invalid/graphql",
            "api_key" => "$LINEAR_API_KEY"
          }
        },
        "runners" => %{
          "codex" => %{
            "kind" => "codex_app_server",
            "command" => ["codex", "app-server"],
            "max_concurrent_agents" => 3,
            "max_concurrent_startups" => 2
          }
        }
      },
      "targets" => %{"alpha" => target(tmp_dir)}
    }

    bytes = Yaml.encode(document)
    File.write!(registry_path, bytes)

    assert {:ok, %{snapshot: snapshot, contexts: %{"alpha" => context}}} =
             Registry.load(registry_path)

    assert snapshot.globally_valid?
    assert snapshot.path == registry_path
    assert snapshot.generation == hash(bytes)
    assert snapshot.source_hash == snapshot.generation
    assert snapshot.host["state_root"] == state_root
    assert get_in(context.tracker_connection, ["policy", "api_key"]) == "$LINEAR_API_KEY"
  end

  defp target(tmp_dir) do
    %{
      "display_name" => "Alpha",
      "state" => "active",
      "dispatch_mode" => "watch",
      "repo" => %{"path" => @manifest_fixture_root, "manifest" => "symphony.yml"},
      "worktree" => %{
        "root" => Path.join(Path.dirname(tmp_dir), "worktrees-" <> Path.basename(tmp_dir)),
        "strategy" => "per_issue",
        "hooks" => %{}
      },
      "linear" => %{
        "connection" => "linear",
        "scope" => %{"type" => "project", "project_id" => "project-1"},
        "active_states" => ["Todo"],
        "terminal_states" => ["Done"],
        "required_labels" => []
      },
      "runners" => %{
        "allowed" => ["codex"],
        "default" => "codex",
        "settings" => %{"codex" => %{"model" => "gpt-5.6-sol"}}
      },
      "concurrency" => %{
        "max_concurrent_agents" => 1,
        "max_concurrent_startups" => 1,
        "max_concurrent_reviewers" => 1,
        "by_linear_state" => %{}
      },
      "budgets" => %{
        "per_run" => %{"max_total_tokens" => 1_000},
        "daily" => %{"max_total_tokens" => 10_000},
        "weekly" => %{"max_total_tokens" => 50_000}
      },
      "checks" => %{
        "pre_dispatch" => [],
        "pre_handoff" => [],
        "pre_publish" => [],
        "pre_merge" => []
      },
      "external_side_effects" => %{
        "tracker_write" => "deny",
        "vcs_publish" => "deny",
        "pull_request_write" => "deny",
        "merge" => "deny",
        "deployment" => "deny",
        "production_data" => "deny"
      },
      "scheduling" => %{"weight" => 1}
    }
  end

  defp hash(bytes),
    do: "sha256:" <> (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))
end
