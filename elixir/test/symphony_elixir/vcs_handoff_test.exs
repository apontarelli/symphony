defmodule SymphonyElixir.VcsHandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.VcsHandoff

  test "builds fixed Git command templates" do
    assert VcsHandoff.git_command(:fetch, %{"remote" => "origin"}) ==
             {"git", ["fetch", "origin"]}

    assert VcsHandoff.git_command(:add, %{"paths" => ["lib/a.ex", "test/a_test.exs"]}) ==
             {"git", ["add", "--", "lib/a.ex", "test/a_test.exs"]}

    assert VcsHandoff.git_command(:commit, %{"messageFile" => "/tmp/msg"}) ==
             {"git", ["commit", "-F", "/tmp/msg"]}

    assert VcsHandoff.git_command(:push, %{"remote" => "origin", "taskBranch" => "feature/sid-115"}) ==
             {"git", ["push", "origin", "HEAD:feature/sid-115"]}
  end

  test "generates deterministic Conventional Commit messages with Linear issue and validation evidence" do
    assert {:ok, message} =
             VcsHandoff.build_commit_message(%{
               "issueIdentifier" => "SID-115",
               "commitSummary" => "move Git handoff out of Codex sandbox",
               "commitType" => "feat",
               "commitScope" => "vcs",
               "validationEvidence" => ["cd elixir && mix test"],
               "changedFiles" => ["elixir/lib/symphony_elixir/vcs_handoff.ex"]
             })

    assert message == """
           feat(vcs): move Git handoff out of Codex sandbox

           Linear-Issue: SID-115

           Validation:
           - cd elixir && mix test

           Changed-files:
           - elixir/lib/symphony_elixir/vcs_handoff.ex
           """
  end

  test "validates manifests against git status and rejects unsafe paths" do
    repo = init_repo!("manifest")
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join(repo, "lib/runner.ex"), "defmodule Runner do\nend\n")
    File.write!(Path.join(repo, ".gitignore"), "ignored.txt\n")

    assert {:ok, ["lib/runner.ex"], evidence} = VcsHandoff.validate_manifest(repo, ["lib/runner.ex"])
    assert evidence["status"]["manifestPaths"] == ["lib/runner.ex"]

    assert {:error, %{"code" => "unsafe_manifest_path", "reason" => "path_traversal"}} =
             VcsHandoff.validate_manifest(repo, ["../outside.ex"])

    assert {:error, %{"code" => "unsafe_manifest_path", "reason" => "absolute_path"}} =
             VcsHandoff.validate_manifest(repo, [Path.join(repo, "lib/runner.ex")])

    assert {:error, %{"code" => "unsafe_manifest_path", "reason" => "generated_log_temp_or_secret_path"}} =
             VcsHandoff.validate_manifest(repo, ["tmp/proof.log"])

    assert {:error, %{"code" => "manifest_path_not_changed", "path" => "missing.ex"}} =
             VcsHandoff.validate_manifest(repo, ["missing.ex"])

    assert {:error, %{"code" => "unsafe_manifest_path", "reason" => "ignored_path"}} =
             VcsHandoff.validate_manifest(repo, ["ignored.txt"])
  end

  test "classifies SID-111 git metadata write failures as actionable blockers" do
    output = "fatal: Unable to create '/workspace/.git/index.lock': Permission denied"

    assert %{
             "code" => "command_failed",
             "capability" => "git_metadata_write",
             "status" => 128,
             "output" => ^output
           } = VcsHandoff.classify_command_failure("git", ["add", "--", "file.txt"], 128, output)
  end

  test "preflight names the failed capability when host cannot write git metadata" do
    repo = init_repo!("preflight")
    git_dir = String.trim(git!(repo, ["rev-parse", "--absolute-git-dir"]))
    File.chmod!(git_dir, 0o555)

    try do
      assert {:error, %{"code" => "preflight_failed", "capability" => "git_metadata_write"}} =
               VcsHandoff.preflight(repo)
    after
      File.chmod!(git_dir, 0o755)
    end
  end

  test "preflight mode only checks host capabilities" do
    repo = init_repo!("preflight-mode")

    assert {:ok, %{"mode" => "preflight", "preflight" => %{"gitMetadataWrite" => %{"capability" => "git_metadata_write"}}}} =
             VcsHandoff.run(%{"mode" => "preflight"}, workspace: repo)
  end

  test "runs host-owned fetch, stage, commit, and push when a sandboxed git add is denied" do
    root = tmp_dir("handoff")
    remote = Path.join(root, "remote.git")
    seed = Path.join(root, "seed")
    workspace = Path.join(root, "workspace")

    File.mkdir_p!(root)
    git!(root, ["init", "--bare", remote])

    File.mkdir_p!(seed)
    git!(seed, ["init", "-b", "main"])
    git!(seed, ["config", "user.name", "Test User"])
    git!(seed, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(seed, "README.md"), "# fixture\n")
    git!(seed, ["add", "README.md"])
    git!(seed, ["commit", "-m", "initial"])
    git!(seed, ["remote", "add", "origin", remote])
    git!(seed, ["push", "origin", "main"])

    git!(root, ["clone", remote, workspace])
    git!(workspace, ["config", "user.name", "Test User"])
    git!(workspace, ["config", "user.email", "test@example.com"])

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/feature.ex"), "defmodule Feature do\nend\n")
    fake_gh = write_fake_gh!(root)
    test_pid = self()

    blocked_parent = Path.join(workspace, ".git/blocked-index-parent")
    File.write!(blocked_parent, "not a directory")

    {_output, status} =
      System.cmd(
        "git",
        ["add", "lib/feature.ex"],
        cd: workspace,
        env: [{"GIT_INDEX_FILE", Path.join(blocked_parent, "index")}],
        stderr_to_stdout: true
      )

    assert status != 0

    assert {:ok, result} =
             VcsHandoff.run(
               %{
                 "changedFiles" => ["lib/feature.ex"],
                 "validationEvidence" => ["fixture: sandboxed git add denied; host handoff committed and pushed"],
                 "issueIdentifier" => "SID-115",
                 "commitSummary" => "move Git handoff out of Codex sandbox",
                 "commitType" => "feat",
                 "commitScope" => "vcs",
                 "taskBranch" => "feature/sid-115-host-handoff",
                 "baseBranch" => "main",
                 "linearIssueId" => "linear-issue-115",
                 "publishPr" => true,
                 "prTitle" => "Move Git handoff out of Codex sandbox",
                 "prBody" => "## Summary\n\nHost-owned handoff fixture.\n"
               },
               workspace: workspace,
               github_cli: fake_gh,
               linear_client: fn query, variables, opts ->
                 send(test_pid, {:linear_attachment, query, variables, opts})

                 {:ok,
                  %{
                    "data" => %{
                      "attachmentLinkGitHubPR" => %{
                        "success" => true,
                        "attachment" => %{
                          "id" => "attachment-115",
                          "title" => variables["title"],
                          "url" => variables["url"]
                        }
                      }
                    }
                  }}
               end
             )

    assert result["pushedBranch"] == "feature/sid-115-host-handoff"
    assert result["prUrl"] == "https://github.com/example/symphony/pull/115"
    assert String.length(result["commitSha"]) == 40

    assert_received {:linear_attachment, query, variables, []}
    assert query =~ "attachmentLinkGitHubPR"
    assert variables["issueId"] == "linear-issue-115"
    assert variables["url"] == "https://github.com/example/symphony/pull/115"
    assert variables["title"] == "Move Git handoff out of Codex sandbox"

    pushed_sha =
      remote
      |> then(&git!(root, ["--git-dir", &1, "rev-parse", "refs/heads/feature/sid-115-host-handoff"]))
      |> String.trim()

    assert pushed_sha == result["commitSha"]

    commit_message = git!(workspace, ["log", "-1", "--pretty=%B"])
    assert commit_message =~ "Linear-Issue: SID-115"
    assert commit_message =~ "fixture: sandboxed git add denied"
  end

  defp init_repo!(name) do
    repo = tmp_dir(name)
    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "# #{name}\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    repo
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "symphony-vcs-handoff-#{name}-#{System.unique_integer([:positive])}")
  end

  defp write_fake_gh!(root) do
    path = Path.join(root, "fake-gh")

    File.write!(path, """
    #!/bin/sh
    if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
      exit 1
    fi
    if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
      printf '%s\\n' 'https://github.com/example/symphony/pull/115'
      exit 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
      exit 0
    fi
    exit 2
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
