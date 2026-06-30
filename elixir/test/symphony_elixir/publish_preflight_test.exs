defmodule SymphonyElixir.PublishPreflightTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PublishPreflight

  test "uses the resolved publish target when manifest delivery internals are absent" do
    workspace = preflight_workspace!()

    result =
      PublishPreflight.run(
        workspace,
        %{
          "publish_target" => %{
            "repository" => "git@github.com:example/project.git",
            "pr_target" => "release/next",
            "github_repository" => "example/project",
            "display" => "example/project:release/next"
          }
        },
        runner:
          preflight_runner(%{
            workspace_vcs_metadata: {0, "ok"},
            remote_push: {0, "ok"},
            pr_creation: {0, "ok"}
          })
      )

    assert result.status == :passed
    assert result.repository == "git@github.com:example/project.git"
    assert result.base_branch == "release/next"
    assert result.capabilities.pr_creation
    assert result.failures == []
  end

  test "reports workspace VCS metadata unavailable" do
    result =
      PublishPreflight.run("/tmp/missing-workspace", publish_policy(),
        runner:
          preflight_runner(%{
            workspace_vcs_metadata: {1, "not a repository"},
            pr_creation: {0, "ok"}
          })
      )

    assert result.status == :blocked
    assert result.repository == "https://github.com/example/project"
    assert result.base_branch == "release/next"
    refute result.capabilities.workspace_vcs_metadata
    refute result.capabilities.remote_push
    assert result.capabilities.pr_creation
    assert Enum.map(result.failures, & &1.class) == [:workspace_vcs_metadata_unavailable]
    assert Enum.map(result.failures, & &1.reason) == [:git_metadata_denied]
  end

  test "reports missing workspace and publish repository" do
    result = PublishPreflight.run(nil, %{"delivery" => %{"pr_target" => "main"}})

    assert result.status == :blocked
    assert result.repository == nil
    assert result.base_branch == nil
    assert Enum.map(result.failures, & &1.class) == [:workspace_vcs_metadata_unavailable, :pr_creation_unavailable]
  end

  test "reports remote push unavailable separately from PR creation" do
    workspace = preflight_workspace!()

    result =
      PublishPreflight.run(workspace, publish_policy(),
        runner:
          preflight_runner(%{
            workspace_vcs_metadata: {0, "ok"},
            remote_push: {128, "permission denied"},
            pr_creation: {0, "ok"}
          })
      )

    assert result.status == :blocked
    assert result.capabilities.workspace_vcs_metadata
    refute result.capabilities.remote_push
    assert result.capabilities.pr_creation
    assert Enum.map(result.failures, & &1.class) == [:remote_push_unavailable]
    assert Enum.map(result.failures, & &1.reason) == [:github_publish_unavailable]
  end

  test "uses jj remote push dry-run when git compatibility commands are unavailable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-publish-preflight-jj-push-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      fake_bin = Path.join(test_root, "bin")
      command_log = Path.join(test_root, "commands.log")

      File.mkdir_p!(workspace)
      File.mkdir_p!(fake_bin)

      File.write!(Path.join(fake_bin, "git"), """
      #!/bin/sh
      printf 'git %s\\n' "$*" >> "$COMMAND_LOG"
      exit 1
      """)

      File.write!(Path.join(fake_bin, "jj"), """
      #!/bin/sh
      printf 'jj %s\\n' "$*" >> "$COMMAND_LOG"
      if [ "$1" = "root" ]; then
        exit 0
      fi
      if [ "$1" = "git" ] && [ "$2" = "remote" ] && [ "$3" = "list" ]; then
        printf 'origin https://github.com/example/project\\n'
        exit 0
      fi
      if [ "$1" = "git" ] && [ "$2" = "push" ]; then
        exit 0
      fi
      exit 1
      """)

      File.write!(Path.join(fake_bin, "gh"), "#!/bin/sh\nexit 0\n")

      Enum.each(["git", "jj", "gh"], &File.chmod!(Path.join(fake_bin, &1), 0o755))

      result =
        PublishPreflight.run(workspace, publish_policy(), env: [{"PATH", fake_bin <> ":" <> System.get_env("PATH", "")}, {"COMMAND_LOG", command_log}])

      assert result.status == :passed
      assert result.capabilities.workspace_vcs_metadata
      assert result.capabilities.remote_push
      assert result.capabilities.pr_creation
      assert result.failures == []

      commands = File.read!(command_log)
      assert commands =~ "jj git remote list"
      assert commands =~ "jj git push --dry-run --remote origin --change @"
    after
      File.rm_rf(test_root)
    end
  end

  test "reports PR creation unavailable separately from remote push" do
    workspace = preflight_workspace!()

    result =
      PublishPreflight.run(workspace, publish_policy(),
        runner:
          preflight_runner(%{
            workspace_vcs_metadata: {0, "ok"},
            remote_push: {0, "ok"},
            pr_creation: {1, "gh auth failed"}
          })
      )

    assert result.status == :blocked
    assert result.capabilities.workspace_vcs_metadata
    assert result.capabilities.remote_push
    refute result.capabilities.pr_creation
    assert Enum.map(result.failures, & &1.class) == [:pr_creation_unavailable]
    assert Enum.map(result.failures, & &1.reason) == [:github_publish_unavailable]
  end

  test "reports missing and malformed PR target configuration" do
    workspace = preflight_workspace!()

    missing_base =
      PublishPreflight.run(
        workspace,
        %{"manifest" => %{"project" => %{"repository" => "https://github.com/example/project"}}},
        runner:
          preflight_runner(%{
            workspace_vcs_metadata: {0, "ok"},
            remote_push: {0, "ok"}
          })
      )

    assert missing_base.base_branch == nil
    assert Enum.map(missing_base.failures, & &1.class) == [:pr_creation_unavailable]

    malformed_repo =
      PublishPreflight.run(
        workspace,
        %{
          "manifest" => %{"project" => %{"repository" => "https://example.com/project"}},
          "delivery" => %{"pr_target" => "main"}
        },
        runner:
          preflight_runner(%{
            workspace_vcs_metadata: {0, "ok"},
            remote_push: {0, "ok"}
          })
      )

    assert Enum.map(malformed_repo.failures, & &1.class) == [:pr_creation_unavailable]

    blank_values =
      PublishPreflight.run(
        workspace,
        %{"manifest" => %{"project" => %{"repository" => " "}}, "delivery" => %{"pr_target" => " "}},
        runner:
          preflight_runner(%{
            workspace_vcs_metadata: {0, "ok"},
            remote_push: {0, "ok"}
          })
      )

    assert blank_values.repository == nil
    assert blank_values.base_branch == nil
    assert Enum.map(blank_values.failures, & &1.class) == [:pr_creation_unavailable]
  end

  test "reports incomplete resolved publish targets before PR capability checks" do
    workspace = preflight_workspace!()

    missing_base =
      PublishPreflight.run(
        workspace,
        %{
          "publish_target" => %{
            "repository" => "https://github.com/example/project.git",
            "github_repository" => "example/project"
          }
        },
        runner:
          preflight_runner(%{
            workspace_vcs_metadata: {0, "ok"},
            remote_push: {0, "ok"}
          })
      )

    assert missing_base.status == :blocked
    assert [%{class: :pr_creation_unavailable, details: "publish base branch is missing"}] = missing_base.failures

    invalid_repository =
      PublishPreflight.run(
        workspace,
        %{
          "publish_target" => %{
            "repository" => "https://example.com/project.git",
            "pr_target" => "main",
            "github_repository" => "example/project"
          }
        },
        runner:
          preflight_runner(%{
            workspace_vcs_metadata: {0, "ok"},
            remote_push: {0, "ok"}
          })
      )

    assert invalid_repository.status == :blocked

    assert [%{class: :pr_creation_unavailable, details: "publish repository is not a GitHub repository"}] =
             invalid_repository.failures
  end

  test "reports command runner errors" do
    workspace = preflight_workspace!()

    result =
      PublishPreflight.run(workspace, publish_policy(),
        runner: fn
          %{step: :workspace_vcs_metadata} -> {:error, :boom}
          %{step: :pr_creation} -> {:ok, %{status: 0, output: "ok"}}
        end
      )

    assert result.status == :blocked
    assert [%{class: :workspace_vcs_metadata_unavailable, details: ":boom"}] = result.failures
  end

  test "trims blank command failure output" do
    workspace = preflight_workspace!()

    result =
      PublishPreflight.run(workspace, publish_policy(),
        runner: fn
          %{step: :workspace_vcs_metadata} -> {:ok, %{status: 1, output: " \n\t "}}
          %{step: :pr_creation} -> {:ok, %{status: 0, output: "ok"}}
        end
      )

    assert [%{class: :workspace_vcs_metadata_unavailable, details: nil}] = result.failures
  end

  test "reports command timeouts without mutating workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-publish-preflight-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      fake_bin = Path.join(test_root, "bin")

      File.mkdir_p!(workspace)
      File.mkdir_p!(fake_bin)
      File.write!(Path.join(fake_bin, "git"), "#!/bin/sh\nsleep 1\n")
      File.chmod!(Path.join(fake_bin, "git"), 0o755)
      File.write!(Path.join(workspace, "worker-edit.txt"), "still here\n")

      result =
        PublishPreflight.run(workspace, %{"delivery" => %{"pr_target" => "main"}},
          env: [{"PATH", fake_bin <> ":" <> System.get_env("PATH", "")}],
          timeout_ms: 1
        )

      assert result.status == :blocked
      assert [%{class: :workspace_vcs_metadata_unavailable} | _] = result.failures
      assert File.read!(Path.join(workspace, "worker-edit.txt")) == "still here\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "supports remote worker command execution" do
    previous_path = System.get_env("PATH")

    test_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-publish-preflight-ssh-#{System.unique_integer([:positive])}")

    try do
      fake_bin = Path.join(test_root, "bin")
      File.mkdir_p!(fake_bin)
      File.write!(Path.join(fake_bin, "ssh"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(fake_bin, "ssh"), 0o755)
      System.put_env("PATH", fake_bin)

      assert %{status: :passed, failures: []} =
               PublishPreflight.run("/remote/workspace", publish_policy(), worker_host: "worker.example")
    after
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end
  end

  test "reports remote SSH execution failures" do
    previous_path = System.get_env("PATH")

    test_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-publish-preflight-no-ssh-#{System.unique_integer([:positive])}")

    try do
      fake_bin = Path.join(test_root, "bin")
      File.mkdir_p!(fake_bin)
      System.put_env("PATH", fake_bin)

      result =
        PublishPreflight.run(
          "/remote/workspace",
          %{"delivery" => %{"pr_target" => "main"}},
          worker_host: "worker.example"
        )

      assert result.status == :blocked
      assert [%{class: :workspace_vcs_metadata_unavailable, details: ":ssh_not_found"} | _] = result.failures
    after
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end
  end

  test "leaves git state unchanged while worker edits remain source-owned" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-publish-preflight-idempotent-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      remote = Path.join(test_root, "remote.git")
      fake_bin = Path.join(test_root, "bin")

      File.mkdir_p!(workspace)
      File.mkdir_p!(fake_bin)
      File.write!(Path.join(fake_bin, "gh"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(fake_bin, "gh"), 0o755)

      git!(["init", "-b", "main"], workspace)
      git!(["config", "user.name", "Test User"], workspace)
      git!(["config", "user.email", "test@example.com"], workspace)
      File.write!(Path.join(workspace, "README.md"), "initial\n")
      git!(["add", "README.md"], workspace)
      git!(["commit", "-m", "initial"], workspace)
      git!(["init", "--bare", remote], test_root)
      git!(["remote", "add", "origin", remote], workspace)
      git!(["push", "-u", "origin", "main"], workspace)

      File.write!(Path.join(workspace, "worker-edit.txt"), "worker source edit\n")

      before_head = git_output!(["rev-parse", "HEAD"], workspace)
      before_status = git_output!(["status", "--porcelain=v1"], workspace)
      before_refs = git_output!(["ls-remote", "--heads", "origin"], workspace)

      result =
        PublishPreflight.run(workspace, publish_policy(), env: [{"PATH", fake_bin <> ":" <> System.get_env("PATH", "")}])

      assert result.status == :passed
      assert result.capabilities.workspace_vcs_metadata
      assert result.capabilities.remote_push
      assert result.capabilities.pr_creation
      assert result.failures == []
      assert File.read!(Path.join(workspace, "worker-edit.txt")) == "worker source edit\n"
      assert git_output!(["rev-parse", "HEAD"], workspace) == before_head
      assert git_output!(["status", "--porcelain=v1"], workspace) == before_status
      assert git_output!(["ls-remote", "--heads", "origin"], workspace) == before_refs
    after
      File.rm_rf(test_root)
    end
  end

  defp publish_policy do
    %{
      "publish_target" => %{
        "repository" => "https://github.com/example/project",
        "pr_target" => "release/next",
        "github_repository" => "example/project",
        "display" => "example/project:release/next"
      },
      "manifest" => %{"project" => %{"repository" => "https://github.com/example/project"}},
      "delivery" => %{"pr_target" => "release/next"}
    }
  end

  defp preflight_workspace! do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-preflight-workspace-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(workspace) end)
    workspace
  end

  defp preflight_runner(results) do
    fn %{step: step} ->
      {status, output} = Map.fetch!(results, step)
      {:ok, %{status: status, output: output}}
    end
  end

  defp git!(args, cwd) do
    {_output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    :ok
  end

  defp git_output!(args, cwd) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end
end
