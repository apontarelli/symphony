defmodule SymphonyElixir.TargetRegistry.RevisionsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HostCLI
  alias SymphonyElixir.HostScheduler.Registry
  alias SymphonyElixir.TargetRegistry.{Composition, Revisions, Yaml}

  @tag :tmp_dir
  test "history preserves replaced configuration and exports references without resolving them", %{tmp_dir: root} do
    path = Path.join(root, "targets.yml")
    first = document("mix test")
    second = document("mix test --warnings-as-errors")
    File.write!(path, Yaml.encode(first))
    File.chmod!(path, 0o600)
    assert :ok = Revisions.archive(path, File.read!(path))
    File.write!(path, Yaml.encode(second))
    assert {:ok, history} = Revisions.history(path)
    assert {:ok, revision} = Composition.canonical_hash(first)
    assert {:ok, next_revision} = Composition.canonical_hash(second)
    assert MapSet.new(Enum.map(history, & &1["revision"])) == MapSet.new([revision, next_revision])

    assert {:ok, exported} = HostCLI.evaluate(["config", "export", "--registry", path, "--revision", revision])
    assert {:ok, ^first} = Yaml.decode(exported)
    assert {:ok, backup} = HostCLI.evaluate(["config", "backup", "--registry", path])
    assert {:ok, records} = Jason.decode(backup)
    assert Enum.any?(records, &(&1["configuration"] == first))
    assert Enum.any?(records, &(&1["configuration"] == second))
    assert exported =~ "$SID494_TRACKER_KEY"
  end

  @tag :tmp_dir
  test "inline credentials cannot enter revision storage or export", %{tmp_dir: root} do
    path = Path.join(root, "targets.yml")
    unsafe = put_in(document("mix test"), ["host", "tracker_connections", "linear", "api_key"], "live-secret-value")
    bytes = Yaml.encode(unsafe)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    assert {:error, _} = Revisions.archive(path, bytes)
    assert {:error, _} = Revisions.export(path)
    refute File.exists?(path <> ".revisions")
  end

  @tag :tmp_dir
  test "credentials in endpoint userinfo and query values cannot enter exports", %{tmp_dir: root} do
    path = Path.join(root, "targets.yml")

    for endpoint <- ["https://live-secret@example.com/graphql", "https://example.com/graphql?access_token=live-secret"] do
      unsafe = put_in(document("mix test"), ["host", "tracker_connections", "linear", "endpoint"], endpoint)
      bytes = Yaml.encode(unsafe)
      File.write!(path, bytes)
      File.chmod!(path, 0o600)
      assert {:error, _} = Revisions.archive(path, bytes)
      assert {:error, _} = Revisions.export(path)
      refute File.exists?(path <> ".revisions")
    end
  end

  @tag :tmp_dir
  test "symlinked history and changed archived contents are rejected", %{tmp_dir: root} do
    path = Path.join(root, "targets.yml")
    bytes = Yaml.encode(document("mix test"))
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    elsewhere = Path.join(root, "elsewhere")
    File.mkdir!(elsewhere)
    File.ln_s!(elsewhere, path <> ".revisions")
    assert {:error, _} = Revisions.archive(path, bytes)
    assert File.ls!(elsewhere) == []
    File.rm!(path <> ".revisions")

    assert :ok = Revisions.archive(path, bytes)
    assert {:ok, [%{"revision" => "sha256:" <> digest}]} = Revisions.history(path)
    File.write!(Path.join(path <> ".revisions", digest <> ".json"), "{}")
    assert {:error, _} = Revisions.export(path, "sha256:" <> digest)
    assert {:error, _} = Revisions.backup(path)
  end

  @tag :tmp_dir
  test "dynamic IDs that resemble credential names round-trip through revision storage", %{tmp_dir: root} do
    path = Path.join(root, "targets.yml")
    document = dynamic_id_document()
    bytes = Yaml.encode(document)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)

    assert :ok = Revisions.archive(path, bytes)
    assert {:ok, revision} = Composition.canonical_hash(document)
    assert {:ok, exported} = Revisions.export(path, revision)
    assert {:ok, ^document} = Yaml.decode(exported)
    assert {:ok, [record]} = Revisions.backup(path)
    assert record["configuration"] == document
    assert {:ok, [%{"revision" => ^revision}]} = Revisions.history(path)
  end

  @tag :tmp_dir
  test "inline credentials under dynamic IDs cannot enter revision storage", %{tmp_dir: root} do
    path = Path.join(root, "targets.yml")

    unsafe =
      put_in(dynamic_id_document(), ["host", "tracker_connections", "token", "api_key"], "live-secret-value")

    bytes = Yaml.encode(unsafe)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    assert {:error, _} = Revisions.archive(path, bytes)
    assert {:error, _} = Revisions.export(path)
    refute File.exists?(path <> ".revisions")
  end

  @manifest_fixture_root Path.expand("../../fixtures/target_registry/repos/symphony", __DIR__)

  @tag :tmp_dir
  test "host load and config commands accept a profile named like a credential", %{tmp_dir: tmp_dir} do
    registry_path = Path.join(tmp_dir, "targets.yml")
    state_root = Path.join(Path.dirname(tmp_dir), Path.basename(tmp_dir) <> "-state")
    {repo, policy} = SymphonyElixir.TestSupport.host_repository_fixture(tmp_dir, @manifest_fixture_root)

    token_profile = %{"validation" => %{"commands" => [%{"name" => "test", "command" => "mix test"}]}}

    document = %{
      "version" => 1,
      "host" => %{
        "id" => "test-host",
        "capabilities" => ["github_pr", "browser"],
        "state_root" => state_root,
        "polling" => %{"interval_ms" => 25, "max_concurrent_target_polls" => 2},
        "capacity" => %{
          "max_concurrent_agents" => 3,
          "max_concurrent_startups" => 2,
          "max_concurrent_reviewers" => 1
        },
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 3},
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
        },
        "repository_profiles" => %{"token" => token_profile}
      },
      "targets" => %{"alpha" => load_target(tmp_dir, repo, policy)}
    }

    bytes = Yaml.encode(document)
    File.write!(registry_path, bytes)
    File.chmod!(registry_path, 0o600)

    assert {:ok, %{snapshot: snapshot, contexts: %{"alpha" => _context}}} = Registry.load(registry_path)
    assert snapshot.globally_valid?
    assert snapshot.host["repository_profiles"] == %{"token" => token_profile}

    assert {:ok, [record]} = Revisions.backup(registry_path)
    assert get_in(record, ["configuration", "host", "repository_profiles"]) == %{"token" => token_profile}

    assert {:ok, exported} = HostCLI.evaluate(["config", "export", "--registry", registry_path])
    assert {:ok, %{"host" => %{"repository_profiles" => profiles}}} = Yaml.decode(exported)
    assert profiles == %{"token" => token_profile}
  end

  defp dynamic_id_document do
    %{
      "version" => 1,
      "host" => %{
        "tracker_connections" => %{"token" => %{"kind" => "linear", "api_key" => "$TOKEN_KEY"}},
        "runners" => %{
          "token" => %{
            "kind" => "codex_app_server",
            "command" => ["codex", "app-server"],
            "execution_profiles" => %{"token" => %{"model" => "gpt-5.6-sol", "budget" => "standard"}}
          }
        },
        "repository_profiles" => %{
          "token" => %{"validation" => %{"commands" => [%{"name" => "test", "command" => "mix test"}]}}
        },
        "repository_defaults" => %{"validation" => %{"commands" => [%{"name" => "test", "command" => "mix test"}]}}
      },
      "targets" => %{
        "token" => %{
          "runners" => %{
            "allowed" => ["token"],
            "default" => "token",
            "settings" => %{"token" => %{"execution_profiles" => %{"token" => %{"model" => "gpt-5.6-sol"}}}}
          },
          "concurrency" => %{"by_linear_state" => %{"token" => 1}}
        }
      }
    }
  end

  defp load_target(tmp_dir, repo, policy) do
    %{
      "display_name" => "Alpha",
      "state" => "active",
      "dispatch_mode" => "watch",
      "repo" => %{"path" => repo, "expected_repository" => policy["project"]["repository"]},
      "repository_policy" => policy,
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

  defp document(command) do
    %{
      "version" => 1,
      "host" => %{
        "tracker_connections" => %{"linear" => %{"kind" => "linear", "api_key" => "$SID494_TRACKER_KEY"}},
        "repository_defaults" => %{"validation" => %{"commands" => [%{"name" => "test", "command" => command}]}}
      },
      "targets" => %{}
    }
  end
end
