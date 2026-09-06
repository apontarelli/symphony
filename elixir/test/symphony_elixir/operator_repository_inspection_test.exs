defmodule SymphonyElixir.OperatorRepositoryInspectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{OperatorRepositoryInspection, PathSafety}
  alias SymphonyElixir.TargetRegistry.{Schema, Yaml}
  alias SymphonyElixir.Workflow.Renderer

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main"])
    git!(repo, ["remote", "add", "origin", "https://github.com/example/inspection.git"])
    File.write!(Path.join(repo, "README.md"), "Repository documentation\n")
    manifest!(repo)
    %{repo: repo}
  end

  test "a Git repository returns canonical identity without running hooks or validation", %{repo: repo, tmp_dir: root} do
    marker = Path.join(root, "executed")
    hook = Path.join(repo, ".git/hooks/post-checkout")
    File.write!(hook, "#!/bin/sh\ntouch '#{marker}'\n")
    File.chmod!(hook, 0o755)
    manifest!(repo, %{"validation" => %{"commands" => [%{"name" => "danger", "command" => "touch '#{marker}'"}]}})
    alias_path = Path.join(root, "alias")
    File.ln_s!(repo, alias_path)
    before = File.read!(Path.join(repo, ".git/config"))

    result = OperatorRepositoryInspection.inspect(alias_path, inspection_opts())

    assert result.state == "ready"
    assert result.apply_allowed
    assert result.path == canonical!(repo)
    assert result.vcs == "git"
    assert result.project["slug"] == "inspection"
    assert result.default_branch == "main"
    assert is_binary(result.expected_repository)
    refute File.exists?(marker)
    assert File.read!(Path.join(repo, ".git/config")) == before
  end

  test "a Jujutsu repository is inspected without creating a working-copy snapshot", %{repo: repo} do
    jj_metadata!(repo, "../../../.git")
    manifest!(repo, %{"vcs" => %{"mode" => "jj", "default_branch" => "main"}})
    operation = File.read!(Path.join(repo, ".jj/working_copy/checkout"))

    result = OperatorRepositoryInspection.inspect(repo, jj_inspection_opts(%{"default_branch" => "trunk"}))

    assert result.state == "ready"
    assert result.vcs == "jj"
    assert result.default_branch == "trunk"
    assert File.read!(Path.join(repo, ".jj/working_copy/checkout")) == operation
  end

  test "standalone Jujutsu uses its own store rather than a parent Git repository", %{tmp_dir: root} do
    repo = Path.join(root, "standalone")
    store = Path.join(repo, ".jj/repo/store/git")
    File.mkdir_p!(store)
    git!(repo, ["init", "--bare", store])
    git!(repo, ["--git-dir", store, "remote", "add", "origin", "https://github.com/example/inspection.git"])
    jj_metadata!(repo, "git")
    File.write!(Path.join(repo, "README.md"), "Repository documentation\n")
    manifest!(repo, %{"vcs" => %{"mode" => "jj", "default_branch" => "main"}})
    operation = File.read!(Path.join(repo, ".jj/working_copy/checkout"))

    assert OperatorRepositoryInspection.inspect(repo, jj_inspection_opts()).state == "ready"
    assert File.read!(Path.join(repo, ".jj/working_copy/checkout")) == operation
  end

  test "a nested folder does not inherit a parent repository identity", %{repo: repo} do
    child = Path.join(repo, "child")
    File.mkdir_p!(child)
    File.write!(Path.join(child, "README.md"), "Documentation\n")
    manifest!(child)

    result = OperatorRepositoryInspection.inspect(child, inspection_opts())

    assert result.state == "needs_setup"
    refute result.apply_allowed
  end

  test "a directory without VCS remains visible but cannot be applied", %{tmp_dir: root} do
    path = Path.join(root, "plain")
    File.mkdir_p!(path)
    manifest!(path)
    result = OperatorRepositoryInspection.inspect(path, inspection_opts())
    assert result.state == "needs_setup"
    assert result.path == canonical!(path)
    assert is_binary(result.reason)
    refute result.apply_allowed
  end

  test "a missing repository manifest does not block configured readiness", %{repo: repo} do
    File.rm!(Path.join(repo, "symphony.yml"))
    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "ready"
    assert result.apply_allowed
  end

  test "invalid repository manifest is ignored by host readiness", %{repo: repo} do
    File.write!(Path.join(repo, "symphony.yml"), "project: [private-token-unclosed\n")
    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "ready"
    assert result.apply_allowed
    refute inspect(result) =~ "private-token-unclosed"
  end

  test "repository manifest module errors do not block host readiness", %{repo: repo} do
    manifest!(repo, %{"workflow" => %{"modules" => ["nonexistent-module"]}})
    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "ready"
    assert result.apply_allowed
  end

  test "missing and non-directory paths return Unreadable rather than raising", %{tmp_dir: root} do
    file = Path.join(root, "file")
    File.write!(file, "private-file-content")

    for path <- [Path.join(root, "missing"), file] do
      result = OperatorRepositoryInspection.inspect(path, inspection_opts())
      assert result.state == "unreadable"
      assert is_binary(result.reason)
      refute result.apply_allowed
      refute inspect(result) =~ "private-file-content"
    end
  end

  test "remote mismatch is distinct from invalid setup and does not expose credentials", %{repo: repo} do
    git!(repo, ["remote", "set-url", "origin", "https://user:private-token@github.com/other/repository.git"])
    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "identity_mismatch"
    refute result.apply_allowed
    refute inspect(result) =~ "private-token"
  end

  test "equivalent SSH and HTTPS remote identities agree", %{repo: repo} do
    git!(repo, ["remote", "set-url", "origin", "git@github.com:example/inspection.git"])
    assert OperatorRepositoryInspection.inspect(repo, inspection_opts()).state == "ready"
  end

  test "a repository without directory read permission is Unreadable", %{repo: repo} do
    File.chmod!(repo, 0o000)
    on_exit(fn -> File.chmod(repo, 0o755) end)

    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())

    assert result.state == "unreadable"
    refute result.apply_allowed
  end

  test "a manifest symlink is ignored by host readiness", %{repo: repo, tmp_dir: root} do
    manifest = Path.join(repo, "symphony.yml")
    outside = Path.join(root, "outside.yml")
    File.rename!(manifest, outside)
    File.ln_s!(outside, manifest)

    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "ready"
    assert result.apply_allowed
  end

  test "registry directory overlap is rejected through canonical symlink paths", %{repo: repo, tmp_dir: root} do
    config = Path.join(repo, "host-config")
    File.mkdir_p!(config)
    registry = registry!(config, Path.join(root, "state"))
    alias_path = Path.join(root, "repo-alias")
    File.ln_s!(repo, alias_path)

    result = OperatorRepositoryInspection.inspect(alias_path, inspection_opts(registry_path: registry))

    assert result.state == "invalid"
    assert is_binary(result.reason)
    refute result.apply_allowed
  end

  test "a separate host registry does not prevent admission", %{repo: repo, tmp_dir: root} do
    config = Path.join(root, "host-config")
    File.mkdir_p!(config)
    registry = registry!(config, Path.join(root, "state"))

    result = OperatorRepositoryInspection.inspect(repo, inspection_opts(registry_path: registry))

    assert result.state == "ready"
    assert result.apply_allowed
  end

  test "Git includes cannot supply an unbounded or external repository identity", %{repo: repo, tmp_dir: root} do
    included = Path.join(root, "included.config")
    File.write!(included, "[remote \"origin\"]\nurl = https://github.com/example/inspection.git\n")
    git!(repo, ["config", "include.path", included])

    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())

    assert result.state == "invalid"
    assert result.reason == "repository_git_config_unsupported"
    refute result.apply_allowed
  end

  test "worktree-specific Git configuration cannot silently override the inspected identity", %{repo: repo} do
    git!(repo, ["config", "extensions.worktreeConfig", "true"])
    git!(repo, ["config", "--worktree", "remote.origin.url", "https://github.com/other/repository.git"])

    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())

    assert result.state == "invalid"
    refute result.apply_allowed
  end

  test "a Git checkout ignores a repository manifest VCS mode", %{repo: repo} do
    manifest!(repo, %{"vcs" => %{"mode" => "jj", "default_branch" => "main"}})
    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "ready"
    assert result.apply_allowed
  end

  test "unreadable Git metadata is not reported as missing setup or an identity mismatch", %{repo: repo} do
    for name <- ["HEAD", "config"] do
      path = Path.join([repo, ".git", name])
      File.chmod!(path, 0o000)

      try do
        result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
        assert result.state == "unreadable"
        refute result.apply_allowed
      after
        File.chmod!(path, 0o644)
      end
    end
  end

  test "linked Git worktrees resolve their shared repository identity", %{repo: repo, tmp_dir: root} do
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=Inspection", "-c", "user.email=inspection@example.com", "commit", "-m", "fixture"])
    worktree = Path.join(root, "linked")
    git!(repo, ["worktree", "add", "-b", "linked", worktree])

    result = OperatorRepositoryInspection.inspect(worktree, inspection_opts())
    assert result.state == "ready"
    assert result.project["repository"] == "example/inspection"
  end

  test "colocated Jujutsu can use Git but standalone Jujutsu cannot", %{repo: repo} do
    jj_metadata!(repo, "../../../.git")
    assert OperatorRepositoryInspection.inspect(repo, inspection_opts()).state == "ready"
    File.rename!(Path.join(repo, ".git"), Path.join(repo, "git-store"))
    File.write!(Path.join(repo, ".jj/repo/store/git_target"), "../../../git-store")

    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "invalid"
    refute result.apply_allowed
  end

  test "missing and corrupt selected-host registries block readiness", %{repo: repo, tmp_dir: root} do
    registry = Path.join(root, "host/targets.yml")
    result = OperatorRepositoryInspection.inspect(repo, registry_path: registry)
    assert result.state == "invalid"
    refute result.apply_allowed

    File.mkdir_p!(Path.dirname(registry))
    File.write!(registry, "invalid: [")
    result = OperatorRepositoryInspection.inspect(repo, registry_path: registry)
    assert result.state == "invalid"
    refute result.apply_allowed
  end

  test "an unreadable repository manifest does not block host readiness", %{repo: repo} do
    manifest = Path.join(repo, "symphony.yml")
    File.chmod!(manifest, 0o000)
    on_exit(fn -> File.chmod(manifest, 0o644) end)
    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "ready"
    assert result.apply_allowed
  end

  test "special-file repository pointers and oversized metadata cannot be read", %{repo: repo} do
    pointer = Path.join(repo, ".git")
    File.rename!(pointer, pointer <> "-saved")
    {_, 0} = System.cmd("mkfifo", [pointer])
    assert OperatorRepositoryInspection.inspect(repo, inspection_opts()).state == "needs_setup"
    File.rm!(pointer)
    File.write!(pointer, String.duplicate("x", 1_048_577))
    assert OperatorRepositoryInspection.inspect(repo, inspection_opts()).state == "needs_setup"
  end

  test "an unreadable shared Git directory pointer cannot become Ready", %{repo: repo} do
    common = Path.join(repo, ".git/commondir")
    File.write!(common, ".")
    File.chmod!(common, 0o000)
    on_exit(fn -> File.chmod(common, 0o644) end)
    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "unreadable"
    refute result.apply_allowed
  end

  test "a quarantined target's stale worktree does not change repository admission", %{repo: repo, tmp_dir: root} do
    config = Path.join(root, "host-config")
    File.mkdir_p!(config)
    registry = registry!(config, Path.join(root, "state"))
    {:ok, document} = registry |> File.read!() |> Yaml.decode()
    document = put_in(document, ["targets"], %{"broken" => %{"worktree" => %{"root" => repo}, "state" => "invalid"}})
    File.write!(registry, Yaml.encode(document))

    result = OperatorRepositoryInspection.inspect(repo, inspection_opts(registry_path: registry))

    assert result.state == "ready"
    assert result.apply_allowed
  end

  test "a repository inside another target's worktree is blocked before branch discovery", %{repo: repo, tmp_dir: root} do
    b_worktree = Path.join(root, "b-worktree")
    a_repo = Path.join(b_worktree, "a-repo")
    File.mkdir_p!(a_repo)
    git!(a_repo, ["init", "--initial-branch=main"])
    git!(a_repo, ["remote", "add", "origin", "https://github.com/example/inspection.git"])
    File.write!(Path.join(a_repo, "README.md"), "Repository documentation\n")
    manifest!(a_repo)

    opts =
      inspection_opts(configured_targets: %{"b" => %{"repo" => %{"path" => repo}, "worktree" => %{"root" => b_worktree}}})

    result = OperatorRepositoryInspection.inspect(a_repo, opts)

    assert result.state == "invalid"
    refute result.apply_allowed

    assert Enum.any?(
             result.blockers,
             &(&1.path == "$.repo.path" and &1.message =~ "$.targets.b.worktree.root")
           )
  end

  test "a shared repository root with another target stays ready", %{repo: repo, tmp_dir: root} do
    opts =
      inspection_opts(configured_targets: %{"b" => %{"repo" => %{"path" => repo}, "worktree" => %{"root" => Path.join(root, "b-worktree")}}})

    result = OperatorRepositoryInspection.inspect(repo, opts)

    assert result.state == "ready"
    assert result.apply_allowed
  end

  test "a selected target's worktree inside another target's root is blocked", %{repo: repo, tmp_dir: root} do
    b_worktree = Path.join(root, "b-worktree")

    opts =
      inspection_opts()
      |> Keyword.put(:configured, %{
        "repo" => %{"path" => repo, "expected_repository" => "https://github.com/example/inspection"},
        "worktree" => %{"root" => Path.join(b_worktree, "selected")}
      })
      |> Keyword.put(:configured_targets, %{"b" => %{"worktree" => %{"root" => b_worktree}}})

    result = OperatorRepositoryInspection.inspect(repo, opts)

    assert result.state == "invalid"
    refute result.apply_allowed

    assert Enum.any?(
             result.blockers,
             &(&1.path == "$.target.worktree.root" and &1.message =~ "$.targets.b.worktree.root")
           )
  end

  test "all origin fetch and push URLs must identify the same repository", %{repo: repo} do
    git!(repo, ["config", "--add", "remote.origin.url", "https://github.com/other/repository.git"])
    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "identity_mismatch"
    refute result.apply_allowed

    git!(repo, ["config", "--unset-all", "remote.origin.url"])
    git!(repo, ["config", "remote.origin.pushurl", "https://github.com/example/inspection.git"])
    refute OperatorRepositoryInspection.inspect(repo, inspection_opts()).apply_allowed
  end

  test "repository-local URL rewrites cannot redirect an apparently matching origin", %{repo: repo} do
    git!(repo, ["config", "url.https://github.com/other/.insteadOf", "https://github.com/example/"])
    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "invalid"
    refute result.apply_allowed
  end

  test "an origin removed after setup cannot become Ready", %{repo: repo} do
    git!(repo, ["remote", "remove", "origin"])
    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "identity_mismatch"
    refute result.apply_allowed
  end

  test "a missing Git object store requires setup", %{repo: repo} do
    File.rename!(Path.join(repo, ".git/objects"), Path.join(repo, ".git/objects-saved"))
    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "needs_setup"
    refute result.apply_allowed
  end

  test "malformed Git configuration is invalid rather than an identity mismatch", %{repo: repo} do
    File.write!(Path.join(repo, ".git/config"), "[remote \"origin\"\nurl = private-token\n")
    result = OperatorRepositoryInspection.inspect(repo, inspection_opts())
    assert result.state == "invalid"
    refute result.apply_allowed
    refute inspect(result) =~ "private-token"
  end

  # These are the on-disk layouts produced by colocated and standalone `jj git init`.
  # Keep jj itself out of the test runtime: inspection must only read this metadata.
  test "missing required check files block a manifest-free repository", %{repo: repo} do
    opts =
      inspection_opts()
      |> Keyword.update!(:host, fn host ->
        put_in(host, ["repository_defaults", "validation", "required_files"], ["CI.md"])
      end)

    result = OperatorRepositoryInspection.inspect(repo, opts)

    assert result.state == "invalid"
    assert Enum.any?(result.blockers, &(&1.path == "$.repository.validation.required_files[0]"))
    refute result.apply_allowed
  end

  test "required capabilities must be provided by the host or every selected runner", %{repo: repo} do
    opts =
      inspection_opts()
      |> Keyword.update!(:host, fn host ->
        host
        |> put_in(["repository_defaults", "capabilities", "required"], ["git_metadata"])
        |> Map.put("runners", %{"codex" => %{"capabilities" => []}, "capable" => %{"capabilities" => ["git_metadata"]}})
      end)
      |> Keyword.update!(:configured, &put_in(&1, ["runners"], %{"allowed" => ["codex", "capable"], "default" => "capable"}))

    result = OperatorRepositoryInspection.inspect(repo, opts)

    # An incapable allowed runner blocks even when a capable runner is the default.
    assert result.state == "invalid"
    assert Enum.any?(result.blockers, &(&1.path == "$.repository.capabilities.required"))
    refute result.apply_allowed

    only_capable =
      Keyword.update!(opts, :configured, &put_in(&1, ["runners"], %{"allowed" => ["capable"], "default" => "capable"}))

    assert OperatorRepositoryInspection.inspect(repo, only_capable).state == "ready"

    host_capable = Keyword.update!(opts, :host, &Map.put(&1, "capabilities", ["git_metadata"]))
    assert OperatorRepositoryInspection.inspect(repo, host_capable).state == "ready"
  end

  # Pre-target Add/Import flow: a branch catalog is requested before the new
  # target exists, so inspection resolves complete host defaults with no
  # configured target. Identity, capability and file readiness still apply.
  test "complete host defaults inspect ready without a target for pre-target discovery", %{repo: repo} do
    result = OperatorRepositoryInspection.inspect(repo, pre_target_opts())

    assert result.state == "ready"
    assert result.apply_allowed
    assert result.project["repository"] == "example/inspection"
    assert result.default_branch == "main"
    assert result.configuration_sources["defaults"]["present"] == true
    assert result.configuration_sources["overrides"]["present"] == false
  end

  test "pre-target inspection still enforces remote identity and requested expectations", %{repo: repo} do
    git!(repo, ["remote", "set-url", "origin", "https://github.com/example/other.git"])
    assert OperatorRepositoryInspection.inspect(repo, pre_target_opts()).state == "identity_mismatch"

    git!(repo, ["remote", "set-url", "origin", "https://github.com/example/inspection.git"])

    mismatched =
      OperatorRepositoryInspection.inspect(
        repo,
        pre_target_opts(expected_repository: "https://github.com/example/other")
      )

    assert mismatched.state == "invalid"
    assert Enum.any?(mismatched.blockers, &(&1.path == "$.repository.expected_repository"))
    refute mismatched.apply_allowed
  end

  test "incomplete host defaults keep target-less inspection blocked", %{repo: repo} do
    identityless =
      pre_target_opts()
      |> Keyword.update!(:host, fn host ->
        {_removed, host} = pop_in(host, ["repository_defaults", "project", "repository"])
        host
      end)

    result = OperatorRepositoryInspection.inspect(repo, identityless)

    assert result.state == "invalid"
    assert Enum.any?(result.blockers, &String.ends_with?(&1.path, ".project.repository"))
    refute result.apply_allowed

    assert OperatorRepositoryInspection.inspect(repo, pre_target_opts(host: %{})).state == "invalid"
  end

  test "a named but unconfigured target is not treated as a pre-target request", %{repo: repo} do
    result = OperatorRepositoryInspection.inspect(repo, pre_target_opts(target_id: "unconfigured"))

    assert result.state == "configuration_required"
    assert result.reason == "repository_configuration_required"
    refute result.apply_allowed
  end

  defp jj_metadata!(repo, git_target) do
    store = Path.join(repo, ".jj/repo/store")
    File.mkdir_p!(store)
    File.write!(Path.join(store, "type"), "git")
    File.write!(Path.join(store, "git_target"), git_target)
    File.mkdir_p!(Path.join(repo, ".jj/working_copy"))
    File.write!(Path.join(repo, ".jj/working_copy/checkout"), "unchanged checkout state")
  end

  defp registry!(config, state_root) do
    host = %{
      "id" => "inspection-host",
      "state_root" => state_root,
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

    path = Path.join(config, "targets.yml")
    File.write!(path, Yaml.encode(%{"version" => 1, "host" => host, "targets" => %{}}))
    {:ok, document} = Yaml.decode(File.read!(path))
    {:ok, snapshot} = Schema.validate(document)
    assert snapshot.globally_valid?, inspect(snapshot.diagnostics)
    path
  end

  defp manifest!(repo, overrides \\ %{}) do
    document = %{
      "version" => 1,
      "project" => %{"slug" => "inspection", "repository" => "https://github.com/example/inspection"},
      "docs" => %{"entrypoints" => ["README.md"]},
      "vcs" => %{"mode" => "git", "default_branch" => "main"},
      "delivery" => %{"pr_target" => "main"}
    }

    File.write!(Path.join(repo, "symphony.yml"), Renderer.to_yaml(Map.merge(document, overrides)))
  end

  defp inspection_opts(registry_opts \\ []) do
    [
      host: %{
        "repository_defaults" => %{
          "project" => %{"slug" => "inspection", "repository" => "https://github.com/example/inspection"},
          "docs" => %{"entrypoints" => ["README.md"]},
          "validation" => %{"commands" => [], "required_files" => []},
          "vcs" => %{"mode" => "git", "default_branch" => "main"},
          "delivery" => %{"pr_target" => "main"},
          "capabilities" => %{"required" => []}
        }
      },
      configured: %{"repo" => %{"path" => "/tmp/inspection", "expected_repository" => "https://github.com/example/inspection"}}
    ]
    |> Keyword.merge(registry_opts)
  end

  defp pre_target_opts(registry_opts \\ []) do
    inspection_opts()
    |> Keyword.delete(:configured)
    |> Keyword.merge(registry_opts)
  end

  defp git!(repo, args) do
    {output, status} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  defp jj_inspection_opts(vcs_overrides \\ %{"mode" => "jj"}) do
    Keyword.update!(inspection_opts(), :host, fn host ->
      update_in(host, ["repository_defaults", "vcs"], &Map.merge(&1, vcs_overrides))
    end)
  end

  defp canonical!(path) do
    {:ok, path} = PathSafety.canonicalize(path)
    path
  end
end
