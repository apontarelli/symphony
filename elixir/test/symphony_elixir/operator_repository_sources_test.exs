defmodule SymphonyElixir.OperatorRepositorySourcesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{LocalConfig, OperatorRepositoryBrowser, OperatorRepositorySources, PathSafety}
  alias SymphonyElixir.TargetRegistry.{FileStore, Yaml}
  alias SymphonyElixir.Workflow.Renderer

  defmodule Host do
    use GenServer
    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)
    def init(snapshot), do: {:ok, snapshot}
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "repository-sources-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, root} = PathSafety.canonicalize(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, config_root: Path.join(root, "config")}
  end

  test "empty host does not seed HOME or the worktree root", %{config_root: config_root} do
    host = start_supervised!({Host, %{registry: %{}}})
    assert {:ok, context} = OperatorRepositorySources.load(host, config_root: config_root)
    assert context.roots == []
    assert context.recent == []
    assert config_root in context.excluded_roots
  end

  test "retains lexical forms alongside physically deduplicated paths", %{root: root, config_root: config_root} do
    outside = Path.join(root, "outside")
    lexical = Path.join(root, "state/.hidden/link")
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.dirname(lexical))
    File.ln_s!(outside, lexical)

    {:ok, _} =
      LocalConfig.write(
        %{"repository_browser" => %{"roots" => [lexical]}},
        config_root: config_root
      )

    File.mkdir_p!(LocalConfig.runs_dir(config_root: config_root))
    File.write!(Path.join(LocalConfig.runs_dir(config_root: config_root), "recent.yml"), Renderer.to_yaml(%{"repo" => %{"path" => lexical}}))
    host = start_supervised!({Host, %{registry: %{}}})

    assert {:ok, context} = OperatorRepositorySources.load(host, config_root: config_root)
    assert Path.join(root, "state/.hidden") in context.roots
    assert context.recent == [lexical]

    recent_result = OperatorRepositoryBrowser.run(%{"action" => "recent"}, context, fn _event -> :ok end)
    assert recent_result.candidates == []
    assert recent_result.errors == []

    scan_result = OperatorRepositoryBrowser.run(%{"action" => "scan"}, context, fn _event -> :ok end)
    assert scan_result.candidates == []
    assert scan_result.errors == []
  end

  test "local policy rejects unsafe or unbounded settings" do
    for patch <- [
          %{"max_depth" => -1},
          %{"max_depth" => 33},
          %{"max_results" => 0},
          %{"max_results" => 1001},
          %{"max_entries" => 0},
          %{"timeout_ms" => 30_001},
          %{"roots" => ["relative"]},
          %{"worktree_roots" => [42]},
          %{"exclusions" => ["../private"]},
          %{"unknown" => true}
        ] do
      assert {:error, :invalid_repository_browser} = LocalConfig.repository_browser(%{"repository_browser" => patch})
    end
  end

  test "seeds explicit roots and recent repository parents while excluding all host-owned roots", %{root: root, config_root: config_root} do
    repo = Path.join(root, "projects/repo")
    alias_path = Path.join(root, "repo-alias")
    explicit = Path.join(root, "explicit")
    worktrees = Path.join(root, "worktrees")
    state = Path.join(root, "state")
    registry_dir = Path.join(root, "registry")
    for path <- [repo, explicit, registry_dir], do: File.mkdir_p!(path)
    File.ln_s!(repo, alias_path)

    {:ok, _} =
      LocalConfig.write(%{"workspace" => %{"root" => worktrees}, "repository_browser" => %{"roots" => [explicit, explicit], "worktree_roots" => [Path.join(root, "extra-worktrees")]}},
        config_root: config_root
      )

    File.mkdir_p!(LocalConfig.runs_dir(config_root: config_root))
    File.write!(Path.join(LocalConfig.runs_dir(config_root: config_root), ".current.yml"), Renderer.to_yaml(%{"repo" => %{"path" => alias_path}}))
    File.write!(Path.join(LocalConfig.runs_dir(config_root: config_root), "home.yml"), Renderer.to_yaml(%{"repo" => %{"path" => Path.join(System.user_home!(), "recent-repo")}}))
    registry_path = Path.join(registry_dir, "targets.yml")

    File.write!(
      registry_path,
      Renderer.to_yaml(%{"version" => 1, "host" => %{"state_root" => state}, "targets" => %{"repo" => %{"repo" => %{"path" => repo}, "worktree" => %{"root" => Path.join(root, "target-worktrees")}}}})
    )

    {:ok, %{generation: generation}} = FileStore.read(registry_path)
    host = start_supervised!({Host, %{registry: %{verified?: true, path: registry_path, generation: generation}}})

    assert {:ok, context} = OperatorRepositorySources.load(host, config_root: config_root)
    assert context.roots == [explicit, Path.dirname(repo)]
    assert Enum.count(context.recent, &(&1 == repo)) == 1

    for excluded <- [config_root, registry_dir, worktrees, state, Path.join(root, "target-worktrees"), Path.join(root, "extra-worktrees")] do
      assert excluded in context.excluded_roots
    end
  end

  test "a bounded workflow catalog cannot silently omit worktree exclusions", %{root: root, config_root: config_root} do
    host = start_supervised!({Host, %{registry: %{}}})
    {:ok, _} = LocalConfig.write(%{"repository_browser" => %{"max_entries" => 1}}, config_root: config_root)
    runs = LocalConfig.runs_dir(config_root: config_root)
    File.mkdir_p!(runs)

    for name <- ["one", "two"] do
      File.write!(Path.join(runs, name <> ".yml"), Renderer.to_yaml(%{"workspace" => %{"root" => Path.join(root, name)}}))
    end

    assert {:error, :repository_sources_limit} = OperatorRepositorySources.load(host, config_root: config_root)
  end

  test "unreadable workflow storage cannot silently omit worktree exclusions", %{config_root: config_root} do
    host = start_supervised!({Host, %{registry: %{}}})
    runs = LocalConfig.runs_dir(config_root: config_root)
    File.mkdir_p!(runs)
    File.chmod!(runs, 0o000)

    try do
      assert {:error, :repository_sources_unavailable} = OperatorRepositorySources.load(host, config_root: config_root)
    after
      File.chmod!(runs, 0o700)
    end
  end

  test "malformed local configuration and unavailable hosts fail closed", %{config_root: config_root} do
    host = start_supervised!({Host, %{registry: %{}}})
    File.mkdir_p!(config_root)
    File.write!(Path.join(config_root, "config.yml"), "repository_browser: [")
    assert {:error, :invalid_local_config} = OperatorRepositorySources.load(host, config_root: config_root)

    File.rm!(Path.join(config_root, "config.yml"))
    GenServer.stop(host)
    assert {:error, :host_unavailable} = OperatorRepositorySources.load(host, config_root: config_root)
  end

  test "workflow catalog accepts repository paths without repository manifests", %{root: root, config_root: config_root} do
    repo = Path.join(root, "project")
    File.mkdir_p!(repo)
    runs = LocalConfig.runs_dir(config_root: config_root)
    File.mkdir_p!(runs)
    File.write!(Path.join(runs, "valid.yml"), Renderer.to_yaml(%{"repo" => %{"path" => repo}}))
    File.write!(Path.join(runs, "empty.yml"), "{}")
    File.write!(Path.join(runs, "invalid.yml"), "repo: [")
    File.write!(Path.join(runs, "notes.txt"), "not a workflow")
    host = start_supervised!({Host, %{registry: %{}}})

    assert {:error, :repository_sources_unavailable} = OperatorRepositorySources.load(host, config_root: config_root)
    File.rm!(Path.join(runs, "invalid.yml"))

    assert {:ok, context} = OperatorRepositorySources.load(host, config_root: config_root)
    result = OperatorRepositoryBrowser.run(%{"action" => "recent"}, context, fn _event -> :ok end)
    assert result.candidates == [%{path: repo, kind: "directory"}]
  end

  test "symlink loops do not become implicit scan roots outside their lexical scope", %{root: root, config_root: config_root} do
    loop = Path.join(root, "loop")
    File.ln_s!(loop, loop)
    {:ok, _} = LocalConfig.write(%{"repository_browser" => %{"roots" => [loop]}}, config_root: config_root)
    host = start_supervised!({Host, %{registry: %{}}})

    assert {:ok, context} = OperatorRepositorySources.load(host, config_root: config_root)
    result = OperatorRepositoryBrowser.run(%{"action" => "scan"}, context, fn _event -> :ok end)
    assert result.candidates == []
    assert result.status == "partial"
    assert [%{path: ^loop, reason: :unreadable}] = result.errors
  end

  test "unreadable and oversized workflow documents cannot remove worktree exclusions", %{config_root: config_root} do
    host = start_supervised!({Host, %{registry: %{}}})
    runs = LocalConfig.runs_dir(config_root: config_root)
    File.mkdir_p!(runs)
    path = Path.join(runs, "saved.yml")
    File.write!(path, "{}")
    File.chmod!(path, 0o000)

    try do
      assert {:error, :repository_sources_unavailable} = OperatorRepositorySources.load(host, config_root: config_root)
    after
      File.chmod!(path, 0o600)
    end

    File.write!(path, String.duplicate(" ", 1_048_577))
    assert {:error, :repository_sources_unavailable} = OperatorRepositorySources.load(host, config_root: config_root)
  end

  test "an excluded alias cannot hide an explicitly configured valid root", %{root: root, config_root: config_root} do
    real = Path.join(root, "projects")
    hidden_alias = Path.join(root, ".hidden/alias")
    File.mkdir_p!(real)
    File.mkdir_p!(Path.dirname(hidden_alias))
    File.ln_s!(real, hidden_alias)
    host = start_supervised!({Host, %{registry: %{}}})

    for roots <- [[hidden_alias, real], [real, hidden_alias]] do
      {:ok, _} = LocalConfig.write(%{"repository_browser" => %{"roots" => roots, "max_depth" => 0}}, config_root: config_root)
      assert {:ok, context} = OperatorRepositorySources.load(host, config_root: config_root)
      result = OperatorRepositoryBrowser.run(%{"action" => "scan"}, context, fn _ -> :ok end)
      assert result.candidates == [%{path: real, kind: "directory"}]
    end
  end

  test "a recent repository with an unresolvable alias remains visible as a diagnostic", %{root: root, config_root: config_root} do
    alias_path = Path.join(root, "loop")
    File.ln_s!(alias_path, alias_path)
    runs = LocalConfig.runs_dir(config_root: config_root)
    File.mkdir_p!(runs)
    File.write!(Path.join(runs, "recent.yml"), Renderer.to_yaml(%{"repo" => %{"path" => alias_path}}))
    host = start_supervised!({Host, %{registry: %{}}})

    assert {:ok, context} = OperatorRepositorySources.load(host, config_root: config_root)
    result = OperatorRepositoryBrowser.run(%{"action" => "recent"}, context, fn _ -> :ok end)
    assert result.candidates == []
    assert result.errors == [%{path: alias_path, reason: :unreadable}]
  end

  test "an unverified registry cannot omit its privacy exclusions", %{root: root, config_root: config_root} do
    host = start_supervised!({Host, %{registry: %{verified?: false, path: Path.join(root, "targets.yml")}}})
    assert {:error, :registry_unavailable} = OperatorRepositorySources.load(host, config_root: config_root)
  end

  test "registry context exposes only admission-valid targets for isolation checks", %{root: root} do
    config = Path.join(root, "host-config")
    File.mkdir_p!(config)
    registry = Path.join(config, "targets.yml")
    state = Path.join(root, "state")
    repo = Path.join(root, "repos/main")
    File.mkdir_p!(repo)

    document = %{
      "version" => 1,
      "host" => registry_host(state),
      "targets" => %{
        "alpha" => registry_target(repo, Path.join(root, "worktrees/alpha")),
        "broken" => registry_target(Path.join(root, "repos/missing"), Path.join(root, "worktrees/broken"))
      }
    }

    File.write!(registry, Yaml.encode(document))
    {:ok, %{generation: generation}} = FileStore.read(registry)
    host = start_supervised!({Host, %{registry: %{verified?: true, path: registry, generation: generation}}})

    assert {:ok, host_map, configured, verified_targets, ^registry} =
             OperatorRepositorySources.registry_context(host, "alpha")

    assert host_map == document["host"]
    assert configured["repo"]["path"] == repo
    assert Map.keys(verified_targets) == ["alpha"]
    assert verified_targets["alpha"]["repo"]["path"] == repo
    assert verified_targets["alpha"]["worktree"]["root"] == Path.join(root, "worktrees/alpha")

    assert {:ok, ^host_map, nil, ^verified_targets, ^registry} =
             OperatorRepositorySources.registry_context(host, nil)
  end

  test "registry context requires a configured registry before inspection", _context do
    host = start_supervised!({Host, %{registry: %{}}})

    assert {:error, :configuration_required} = OperatorRepositorySources.registry_context(host, "alpha")
  end

  test "registry context fails closed when a verified-marked registry cannot be revalidated", %{root: root} do
    config = Path.join(root, "host-config")
    File.mkdir_p!(config)
    registry = Path.join(config, "targets.yml")

    # Structurally decodable but admission-invalid: a registry that cannot run
    # through the admission pipeline must not silently change eligibility.
    File.write!(registry, Yaml.encode(%{"host" => registry_host(Path.join(root, "state")), "targets" => %{"alpha" => %{}}}))
    {:ok, %{generation: generation}} = FileStore.read(registry)
    host = start_supervised!({Host, %{registry: %{verified?: true, path: registry, generation: generation}}})

    assert {:error, :registry_unavailable} = OperatorRepositorySources.registry_context(host, "alpha")
    assert {:error, :registry_unavailable} = OperatorRepositorySources.registry_context(host, nil)
  end

  defp registry_host(state) do
    %{
      "id" => "sources-host",
      "state_root" => state,
      "polling" => %{"interval_ms" => 30_000, "max_concurrent_target_polls" => 1},
      "capacity" => %{"max_concurrent_agents" => 4, "max_concurrent_startups" => 2, "max_concurrent_reviewers" => 1},
      "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 4},
      "tracker_connections" => %{
        "linear-main" => %{"kind" => "linear", "endpoint" => "https://api.linear.app/graphql", "api_key" => "$LINEAR_API_KEY"}
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

  defp registry_target(repo, worktree) do
    %{
      "display_name" => "Target",
      "state" => "active",
      "dispatch_mode" => "explicit",
      "repo" => %{"path" => repo, "expected_repository" => "https://github.com/example/sources"},
      "worktree" => %{"root" => worktree, "strategy" => "per_issue", "hooks" => %{}},
      "linear" => %{
        "connection" => "linear-main",
        "scope" => %{"type" => "project", "project_id" => "project-1"},
        "active_states" => ["Todo", "In Progress"],
        "terminal_states" => ["Done"],
        "required_labels" => []
      },
      "runners" => %{"allowed" => ["codex"], "default" => "codex", "settings" => %{}},
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
      "checks" => %{},
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
end
