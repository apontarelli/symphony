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

    result = OperatorRepositoryInspection.inspect(alias_path)

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
    manifest!(repo, %{"vcs" => %{"mode" => "jj", "default_branch" => "trunk"}})
    operation = File.read!(Path.join(repo, ".jj/working_copy/checkout"))

    result = OperatorRepositoryInspection.inspect(repo)

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

    assert OperatorRepositoryInspection.inspect(repo).state == "ready"
    assert File.read!(Path.join(repo, ".jj/working_copy/checkout")) == operation
  end

  test "a nested folder does not inherit a parent repository identity", %{repo: repo} do
    child = Path.join(repo, "child")
    File.mkdir_p!(child)
    File.write!(Path.join(child, "README.md"), "Documentation\n")
    manifest!(child)

    result = OperatorRepositoryInspection.inspect(child)

    assert result.state == "needs_setup"
    refute result.apply_allowed
  end

  test "a directory without VCS remains visible but cannot be applied", %{tmp_dir: root} do
    path = Path.join(root, "plain")
    File.mkdir_p!(path)
    manifest!(path)
    result = OperatorRepositoryInspection.inspect(path)
    assert result.state == "needs_setup"
    assert result.path == canonical!(path)
    assert is_binary(result.reason)
    refute result.apply_allowed
  end

  test "a missing manifest requires setup", %{repo: repo} do
    File.rm!(Path.join(repo, "symphony.yml"))
    result = OperatorRepositoryInspection.inspect(repo)
    assert result.state == "needs_setup"
    assert is_binary(result.reason)
    refute result.apply_allowed
  end

  test "invalid manifest input cannot become Ready or expose its contents", %{repo: repo} do
    File.write!(Path.join(repo, "symphony.yml"), "project: [private-token-unclosed\n")
    result = OperatorRepositoryInspection.inspect(repo)
    assert result.state == "invalid"
    refute result.apply_allowed
    refute inspect(result) =~ "private-token-unclosed"
  end

  test "semantic manifest errors block Apply", %{repo: repo} do
    manifest!(repo, %{"workflow" => %{"modules" => ["nonexistent-module"]}})
    result = OperatorRepositoryInspection.inspect(repo)
    assert result.state == "invalid"
    refute result.apply_allowed
  end

  test "missing and non-directory paths return Unreadable rather than raising", %{tmp_dir: root} do
    file = Path.join(root, "file")
    File.write!(file, "private-file-content")

    for path <- [Path.join(root, "missing"), file] do
      result = OperatorRepositoryInspection.inspect(path)
      assert result.state == "unreadable"
      assert is_binary(result.reason)
      refute result.apply_allowed
      refute inspect(result) =~ "private-file-content"
    end
  end

  test "remote mismatch is distinct from invalid setup and does not expose credentials", %{repo: repo} do
    git!(repo, ["remote", "set-url", "origin", "https://user:private-token@github.com/other/repository.git"])
    result = OperatorRepositoryInspection.inspect(repo)
    assert result.state == "identity_mismatch"
    refute result.apply_allowed
    refute inspect(result) =~ "private-token"
  end

  test "equivalent SSH and HTTPS remote identities agree", %{repo: repo} do
    git!(repo, ["remote", "set-url", "origin", "git@github.com:example/inspection.git"])
    assert OperatorRepositoryInspection.inspect(repo).state == "ready"
  end

  test "a repository without directory read permission is Unreadable", %{repo: repo} do
    File.chmod!(repo, 0o000)
    on_exit(fn -> File.chmod(repo, 0o755) end)

    result = OperatorRepositoryInspection.inspect(repo)

    assert result.state == "unreadable"
    refute result.apply_allowed
  end

  test "a manifest symlink outside the repository cannot be admitted", %{repo: repo, tmp_dir: root} do
    manifest = Path.join(repo, "symphony.yml")
    outside = Path.join(root, "outside.yml")
    File.rename!(manifest, outside)
    File.ln_s!(outside, manifest)

    result = OperatorRepositoryInspection.inspect(repo)

    assert result.state == "invalid"
    refute result.apply_allowed
  end

  test "registry directory overlap is rejected through canonical symlink paths", %{repo: repo, tmp_dir: root} do
    config = Path.join(repo, "host-config")
    File.mkdir_p!(config)
    registry = registry!(config, Path.join(root, "state"))
    alias_path = Path.join(root, "repo-alias")
    File.ln_s!(repo, alias_path)

    result = OperatorRepositoryInspection.inspect(alias_path, registry_path: registry)

    assert result.state == "invalid"
    assert is_binary(result.reason)
    refute result.apply_allowed
  end

  test "a separate host registry does not prevent admission", %{repo: repo, tmp_dir: root} do
    config = Path.join(root, "host-config")
    File.mkdir_p!(config)
    registry = registry!(config, Path.join(root, "state"))

    result = OperatorRepositoryInspection.inspect(repo, registry_path: registry)

    assert result.state == "ready"
    assert result.apply_allowed
  end

  test "Git includes cannot supply an unbounded or external repository identity", %{repo: repo, tmp_dir: root} do
    included = Path.join(root, "included.config")
    File.write!(included, "[remote \"origin\"]\nurl = https://github.com/example/inspection.git\n")
    git!(repo, ["config", "include.path", included])

    result = OperatorRepositoryInspection.inspect(repo)

    assert result.state == "invalid"
    assert result.reason == "repository_git_config_unsupported"
    refute result.apply_allowed
  end

  test "worktree-specific Git configuration cannot silently override the inspected identity", %{repo: repo} do
    git!(repo, ["config", "extensions.worktreeConfig", "true"])
    git!(repo, ["config", "--worktree", "remote.origin.url", "https://github.com/other/repository.git"])

    result = OperatorRepositoryInspection.inspect(repo)

    assert result.state == "invalid"
    refute result.apply_allowed
  end

  test "a Git checkout cannot declare a Jujutsu execution mode", %{repo: repo} do
    manifest!(repo, %{"vcs" => %{"mode" => "jj", "default_branch" => "main"}})
    result = OperatorRepositoryInspection.inspect(repo)
    assert result.state == "invalid"
    refute result.apply_allowed
  end

  test "unreadable Git metadata is not reported as missing setup or an identity mismatch", %{repo: repo} do
    for name <- ["HEAD", "config"] do
      path = Path.join([repo, ".git", name])
      File.chmod!(path, 0o000)

      try do
        result = OperatorRepositoryInspection.inspect(repo)
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

    result = OperatorRepositoryInspection.inspect(worktree)
    assert result.state == "ready"
    assert result.project["repository"] == "example/inspection"
  end

  test "colocated Jujutsu can use Git but standalone Jujutsu cannot", %{repo: repo} do
    jj_metadata!(repo, "../../../.git")
    assert OperatorRepositoryInspection.inspect(repo).state == "ready"
    File.rename!(Path.join(repo, ".git"), Path.join(repo, "git-store"))
    File.write!(Path.join(repo, ".jj/repo/store/git_target"), "../../../git-store")

    result = OperatorRepositoryInspection.inspect(repo)
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

  test "an unreadable manifest requires permission repair rather than setup", %{repo: repo} do
    manifest = Path.join(repo, "symphony.yml")
    File.chmod!(manifest, 0o000)
    on_exit(fn -> File.chmod(manifest, 0o644) end)
    result = OperatorRepositoryInspection.inspect(repo)
    assert result.state == "unreadable"
    refute result.apply_allowed
  end

  test "special-file repository pointers and oversized metadata cannot be read", %{repo: repo} do
    pointer = Path.join(repo, ".git")
    File.rename!(pointer, pointer <> "-saved")
    {_, 0} = System.cmd("mkfifo", [pointer])
    assert OperatorRepositoryInspection.inspect(repo).state == "needs_setup"
    File.rm!(pointer)
    File.write!(pointer, String.duplicate("x", 1_048_577))
    assert OperatorRepositoryInspection.inspect(repo).state == "needs_setup"
  end

  test "an unreadable shared Git directory pointer cannot become Ready", %{repo: repo} do
    common = Path.join(repo, ".git/commondir")
    File.write!(common, ".")
    File.chmod!(common, 0o000)
    on_exit(fn -> File.chmod(common, 0o644) end)
    result = OperatorRepositoryInspection.inspect(repo)
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

    result = OperatorRepositoryInspection.inspect(repo, registry_path: registry)

    assert result.state == "ready"
    assert result.apply_allowed
  end

  test "all origin fetch and push URLs must identify the same repository", %{repo: repo} do
    git!(repo, ["config", "--add", "remote.origin.url", "https://github.com/other/repository.git"])
    result = OperatorRepositoryInspection.inspect(repo)
    assert result.state == "identity_mismatch"
    refute result.apply_allowed

    git!(repo, ["config", "--unset-all", "remote.origin.url"])
    git!(repo, ["config", "remote.origin.pushurl", "https://github.com/example/inspection.git"])
    refute OperatorRepositoryInspection.inspect(repo).apply_allowed
  end

  test "repository-local URL rewrites cannot redirect an apparently matching origin", %{repo: repo} do
    git!(repo, ["config", "url.https://github.com/other/.insteadOf", "https://github.com/example/"])
    result = OperatorRepositoryInspection.inspect(repo)
    assert result.state == "invalid"
    refute result.apply_allowed
  end

  test "an origin removed after setup cannot become Ready", %{repo: repo} do
    git!(repo, ["remote", "remove", "origin"])
    result = OperatorRepositoryInspection.inspect(repo)
    assert result.state == "identity_mismatch"
    refute result.apply_allowed
  end

  test "a missing Git object store requires setup", %{repo: repo} do
    File.rename!(Path.join(repo, ".git/objects"), Path.join(repo, ".git/objects-saved"))
    result = OperatorRepositoryInspection.inspect(repo)
    assert result.state == "needs_setup"
    refute result.apply_allowed
  end

  test "malformed Git configuration is invalid rather than an identity mismatch", %{repo: repo} do
    File.write!(Path.join(repo, ".git/config"), "[remote \"origin\"\nurl = private-token\n")
    result = OperatorRepositoryInspection.inspect(repo)
    assert result.state == "invalid"
    refute result.apply_allowed
    refute inspect(result) =~ "private-token"
  end

  # These are the on-disk layouts produced by colocated and standalone `jj git init`.
  # Keep jj itself out of the test runtime: inspection must only read this metadata.
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

  defp git!(repo, args) do
    {output, status} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  defp canonical!(path) do
    {:ok, path} = PathSafety.canonicalize(path)
    path
  end
end
