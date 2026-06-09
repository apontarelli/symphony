defmodule SymphonyElixir.PublishHandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{HandoffManifest, HandoffRoute, HandoffRouteRecorder, PublishHandoff}
  alias SymphonyElixir.HandoffRoute.PublishHandoffEvidence

  test "builds explicit jj publish commands from resolved target and issue" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")
    parent = self()

    issue = issue("SID-309")
    completion = completion_for(["lib/source.ex"])
    policy = publish_policy(vcs_mode: "jj", repository: "https://github.com/apontarelli/symphony", github_repository: "apontarelli/symphony")

    result =
      PublishHandoff.run(workspace, policy, issue, completion,
        runner: fn %{step: step, command: command, args: args} ->
          send(parent, {:publish_command, step, command, args})

          output =
            case step do
              :jj_remote_list -> "origin https://github.com/apontarelli/symphony.git\n"
              :jj_changed_files -> "lib/source.ex\n"
              :pr_view -> "no pull request found"
              :pr_create -> "https://github.com/apontarelli/symphony/pull/309\n"
              :jj_current -> "abcdefgh 1234567\n"
              _step -> "ok\n"
            end

          status = if step == :pr_view, do: 1, else: 0
          {:ok, %{status: status, output: output}}
        end
      )

    assert result.status == :passed
    assert result.repository == "https://github.com/apontarelli/symphony"
    assert result.github_repository == "apontarelli/symphony"
    assert result.base_branch == "main"
    assert result.branch == "ticket/sid-309"
    assert result.pr_url == "https://github.com/apontarelli/symphony/pull/309"
    assert result.linear_issue == %{id: "issue-SID-309", identifier: "SID-309", url: "https://linear.example/SID-309"}

    assert_receive {:publish_command, :jj_describe, "jj", ["describe", "-m", "chore(SID-309): publish Symphony workspace changes"]}
    assert_receive {:publish_command, :jj_bookmark, "jj", ["bookmark", "set", "ticket/sid-309", "-r", "@"]}
    assert_receive {:publish_command, :jj_push, "jj", ["git", "push", "--remote", "origin", "-b", "ticket/sid-309", "--allow-new"]}

    assert_receive {:publish_command, :pr_view, "gh", ["pr", "view", "--repo", "apontarelli/symphony", "--head", "apontarelli:ticket/sid-309", "--json", "url", "--jq", ".url"]}

    assert_receive {:publish_command, :pr_create, "gh", pr_create_args}
    assert ["pr", "create", "--repo", "apontarelli/symphony", "--head", "apontarelli:ticket/sid-309", "--base", "main", "--title", title | rest] = pr_create_args
    assert title == "SID-309: Publish validated workspace changes"
    assert "--body" in rest

    assert_receive {:publish_command, :jj_current, "jj", ["log", "-r", "@", "--no-graph", "--template", "change_id.short() ++ \" \" ++ commit_id.short() ++ \"\\n\""]}
  end

  test "publishes through local executables when no test runner is configured" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-publish-handoff-bin-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      fake_bin = Path.join(test_root, "bin")
      shadow_bin = Path.join(test_root, "shadow-bin")
      command_log = Path.join(test_root, "commands.log")

      File.mkdir_p!(Path.join(workspace, "lib"))
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(shadow_bin)
      File.write!(Path.join(workspace, "lib/source.ex"), "defmodule Source do\nend\n")
      File.write!(Path.join(shadow_bin, "jj"), "#!/bin/sh\nexit 127\n")

      File.write!(Path.join(fake_bin, "jj"), """
      #!/bin/sh
      printf 'jj %s\\n' "$*" >> "$COMMAND_LOG"
      if [ "$1" = "git" ] && [ "$2" = "remote" ] && [ "$3" = "list" ]; then
        printf 'origin https://github.com/example/project.git\\n'
        exit 0
      fi
      if [ "$1" = "diff" ]; then
        printf 'lib/source.ex\\n'
        exit 0
      fi
      if [ "$1" = "log" ]; then
        printf 'realchange realcommit\\n'
        exit 0
      fi
      exit 0
      """)

      File.write!(Path.join(fake_bin, "gh"), """
      #!/bin/sh
      printf 'gh %s\\n' "$*" >> "$COMMAND_LOG"
      if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
        exit 1
      fi
      if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
        printf 'https://github.com/example/project/pull/309\\n'
        exit 0
      fi
      exit 0
      """)

      Enum.each(["jj", "gh"], &File.chmod!(Path.join(fake_bin, &1), 0o755))

      result =
        PublishHandoff.run(
          workspace,
          publish_policy(vcs_mode: "jj"),
          issue("SID-309"),
          completion_for(["lib/source.ex"]),
          env: [{"NOISE", "ignored"}, {"PATH", shadow_bin <> ":" <> fake_bin}, {"COMMAND_LOG", command_log}],
          timeout_ms: 5_000
        )

      assert result.status == :passed
      assert result.change_id == "realchange"
      assert result.commit_sha == "realcommit"

      commands = File.read!(command_log)
      assert commands =~ "jj git remote list"
      assert commands =~ "jj git push --remote origin -b ticket/sid-309 --allow-new"
      assert commands =~ "gh pr create --repo example/project --head example:ticket/sid-309"
    after
      File.rm_rf(test_root)
    end
  end

  test "publishes validated git workspace changes to the configured remote and PR target" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")
    parent = self()

    result =
      PublishHandoff.run(
        workspace,
        publish_policy(vcs_mode: "git", repository: "https://github.com/example/project", github_repository: "example/project"),
        issue("SID-309"),
        completion_for(["lib/source.ex"]),
        runner: fn %{step: step, command: command, args: args} ->
          send(parent, {:publish_command, step, command, args})

          output =
            case step do
              :git_remote_get_url -> "git@github.com:example/project.git\n"
              :git_committed_changed_files -> "lib/old_source.ex -> lib/source.ex\n"
              :git_unstaged_changed_files -> ""
              :git_staged_changed_files -> ""
              :git_untracked_files -> ""
              :git_diff_cached -> ""
              :git_current -> "1234567890abcdef\n"
              :pr_view -> "no pull request found"
              :pr_create -> "https://github.com/example/project/pull/42\n"
              _step -> "ok\n"
            end

          status =
            case step do
              :git_diff_cached -> 1
              :pr_view -> 1
              _step -> 0
            end

          {:ok, %{status: status, output: output}}
        end
      )

    assert result.status == :passed
    assert result.branch == "ticket/sid-309"
    assert result.base_branch == "main"
    assert result.github_repository == "example/project"
    assert result.pr_url == "https://github.com/example/project/pull/42"
    assert result.commit_sha == "1234567890abcdef"

    assert_receive {:publish_command, :git_remote_get_url, "git", ["remote", "get-url", "--push", "origin"]}
    assert_receive {:publish_command, :git_unstaged_changed_files, "git", ["diff", "--name-only"]}
    assert_receive {:publish_command, :git_push, "git", ["push", "-u", "origin", "HEAD:ticket/sid-309"]}
    assert_receive {:publish_command, :pr_create, "gh", pr_create_args}
    assert ["pr", "create", "--repo", "example/project", "--head", "example:ticket/sid-309", "--base", "main" | _rest] = pr_create_args
  end

  test "updates an existing PR and skips empty git commits when there are no staged changes" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")
    parent = self()

    result =
      PublishHandoff.run(
        workspace,
        publish_policy(vcs_mode: "git", repository: "https://github.com/example/project", github_repository: "example/project"),
        issue("SID-309"),
        completion_for(["lib/source.ex"]),
        runner: fn %{step: step, command: command, args: args} ->
          send(parent, {:publish_command, step, command, args})

          output =
            case step do
              :git_remote_get_url -> "https://github.com/example/project.git\n"
              :git_unstaged_changed_files -> "lib/source.ex\n"
              :git_current -> "feedbeef\n"
              :pr_view -> "https://github.com/example/project/pull/42\n"
              _step -> ""
            end

          {:ok, %{status: 0, output: output}}
        end
      )

    assert result.status == :passed
    assert result.pr_url == "https://github.com/example/project/pull/42"
    assert_receive {:publish_command, :git_diff_cached, "git", ["diff", "--cached", "--quiet"]}
    refute_receive {:publish_command, :git_commit, _command, _args}, 50
    assert_receive {:publish_command, :pr_edit, "gh", ["pr", "edit", "https://github.com/example/project/pull/42" | _rest]}
  end

  test "blocks when git staged-change detection fails" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")

    status_failure =
      PublishHandoff.run(
        workspace,
        publish_policy(vcs_mode: "git", repository: "https://github.com/example/project", github_repository: "example/project"),
        issue("SID-309"),
        completion_for(["lib/source.ex"]),
        runner: fn %{step: step} ->
          output =
            case step do
              :git_remote_get_url -> "https://github.com/example/project.git\n"
              :git_unstaged_changed_files -> "lib/source.ex\n"
              :git_diff_cached -> " \n"
              _step -> ""
            end

          status = if step == :git_diff_cached, do: 2, else: 0
          {:ok, %{status: status, output: output}}
        end
      )

    assert status_failure.status == :blocked
    assert status_failure.failure.reason == :git_diff_cached_failed
    assert status_failure.failure.details == nil

    command_error =
      PublishHandoff.run(
        workspace,
        publish_policy(vcs_mode: "git", repository: "https://github.com/example/project", github_repository: "example/project"),
        issue("SID-309"),
        completion_for(["lib/source.ex"]),
        runner: fn
          %{step: :git_remote_get_url} -> {:ok, %{status: 0, output: "https://github.com/example/project.git\n"}}
          %{step: :git_unstaged_changed_files} -> {:ok, %{status: 0, output: "lib/source.ex\n"}}
          %{step: :git_diff_cached} -> {:error, :git_diff_boom}
          %{step: _step} -> {:ok, %{status: 0, output: ""}}
        end
      )

    assert command_error.status == :blocked
    assert command_error.failure.reason == :git_diff_cached_failed
    assert command_error.failure.details == ":git_diff_boom"
  end

  test "does not execute publish commands unless preflight and manifest safety passed" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")
    parent = self()

    runner = fn %{step: step} ->
      send(parent, {:unexpected_publish_command, step})
      {:ok, %{status: 0, output: "ok"}}
    end

    preflight_blocked =
      completion_for(["lib/source.ex"])
      |> Map.put(:publish_preflight, %{status: :blocked, repository: "https://github.com/example/project", base_branch: "main", failures: []})

    assert %{status: :blocked, failure: %{reason: :publish_preflight_not_passed}} =
             PublishHandoff.run(workspace, publish_policy(), issue("SID-309"), preflight_blocked, runner: runner)

    invalid_manifest =
      completion_for(["../secret.txt"])

    assert %{status: :blocked, failure: %{reason: :change_manifest_failed}} =
             PublishHandoff.run(workspace, publish_policy(), issue("SID-309"), invalid_manifest, runner: runner)

    ambiguous_manifest =
      completion_for(["lib/source.ex"])
      |> Map.put("change_manifest", %{changed_files: ["lib/source.ex"]})

    assert %{status: :blocked, failure: %{reason: :change_manifest_failed}} =
             PublishHandoff.run(workspace, publish_policy(), issue("SID-309"), ambiguous_manifest, runner: runner)

    invalid_pr_body =
      completion_for(["lib/source.ex"])
      |> Map.put(:checks, [%{name: "all", status: :passed, summary: "<!-- pending -->"}])

    assert %{status: :blocked, failure: %{reason: :pr_body_invalid, details: details}} =
             PublishHandoff.run(workspace, publish_policy(), issue("SID-309"), invalid_pr_body, runner: runner)

    assert details =~ "PR description still contains template placeholder comments"

    refute_receive {:unexpected_publish_command, _step}, 50
  end

  test "blocks before publish when required local inputs are unavailable" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")

    assert %{status: :blocked, attempted: false, failure: %{reason: :remote_publish_unavailable}} =
             PublishHandoff.run(workspace, publish_policy(), issue("SID-309"), completion_for(["lib/source.ex"]), worker_host: "worker.example")

    assert %{status: :blocked, attempted: false, failure: %{reason: :workspace_unavailable}} =
             PublishHandoff.run(nil, publish_policy(), issue("SID-309"), completion_for(["lib/source.ex"]))

    assert %{status: :blocked, attempted: false, failure: %{reason: :publish_preflight_missing}} =
             PublishHandoff.run(workspace, publish_policy(), issue("SID-309"), %{change_manifest: %{changed_files: ["lib/source.ex"]}})

    assert %{status: :blocked, attempted: false, failure: %{reason: :change_manifest_missing}} =
             PublishHandoff.run(
               workspace,
               publish_policy(),
               issue("SID-309"),
               %{publish_preflight: %{status: :passed}, checks: [%{name: "all", status: :passed}]}
             )

    assert %{status: :blocked, branch: "ticket/sid-map", linear_issue: %{id: "issue-map", identifier: "SID-MAP", url: "https://linear.example/SID-MAP"}} =
             PublishHandoff.run(
               nil,
               publish_policy(),
               %{"id" => "issue-map", "identifier" => "SID-MAP", "url" => "https://linear.example/SID-MAP"},
               completion_for(["lib/source.ex"])
             )

    assert %{status: :blocked, attempted: false, failure: %{reason: :publish_preflight_not_passed}} =
             PublishHandoff.run(
               workspace,
               publish_policy(),
               issue("SID-309"),
               %{change_manifest: %{changed_files: ["lib/source.ex"]}, publish_preflight: %{"status" => "not a status", "custom-key" => true, 123 => true}}
             )

    assert %{status: :blocked, attempted: false, failure: %{reason: :publish_preflight_not_passed}} =
             PublishHandoff.run(
               workspace,
               publish_policy(),
               issue("SID-309"),
               %{change_manifest: %{changed_files: ["lib/source.ex"]}, publish_preflight: %{status: 123}}
             )
  end

  test "does not publish without a resolved publish target" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")
    parent = self()

    result =
      PublishHandoff.run(
        workspace,
        %{"manifest" => %{"project" => %{"repository" => "https://github.com/example/project"}}, "delivery" => %{"pr_target" => "main"}},
        issue("SID-309"),
        completion_for(["lib/source.ex"]),
        runner: fn %{step: step} ->
          send(parent, {:unexpected_publish_command, step})
          {:ok, %{status: 0, output: "ok"}}
        end
      )

    assert result.status == :blocked
    assert result.attempted == false
    assert result.failure.reason == :publish_target_invalid
    refute_receive {:unexpected_publish_command, _step}, 50
  end

  test "blocks unsupported VCS modes before publish commands run" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")
    parent = self()

    result =
      PublishHandoff.run(
        workspace,
        publish_policy(vcs_mode: "hg"),
        issue("SID-309"),
        completion_for(["lib/source.ex"]),
        runner: fn %{step: step} ->
          send(parent, {:unexpected_publish_command, step})
          {:ok, %{status: 0, output: "ok"}}
        end
      )

    assert result.status == :blocked
    assert result.failure.reason == :unsupported_vcs_mode
    refute_receive {:unexpected_publish_command, _step}, 50
  end

  test "blocks when origin remote does not match the resolved publish target" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")
    parent = self()

    result =
      PublishHandoff.run(
        workspace,
        publish_policy(vcs_mode: "jj", repository: "https://github.com/example/project", github_repository: "example/project"),
        issue("SID-309"),
        completion_for(["lib/source.ex"]),
        runner: fn %{step: step, command: command, args: args} ->
          send(parent, {:publish_command, step, command, args})
          {:ok, %{status: 0, output: "origin https://github.com/other/project.git\n"}}
        end
      )

    assert result.status == :blocked
    assert result.failure.reason == :publish_remote_mismatch
    assert_receive {:publish_command, :jj_remote_list, "jj", ["git", "remote", "list"]}
    refute_receive {:publish_command, :jj_push, _command, _args}, 50
  end

  test "blocks when origin remote is missing or the remote check command fails" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")

    missing_origin =
      PublishHandoff.run(
        workspace,
        publish_policy(vcs_mode: "jj"),
        issue("SID-309"),
        completion_for(["lib/source.ex"]),
        runner: fn %{step: :jj_remote_list} -> {:ok, %{status: 0, output: "upstream https://github.com/example/project.git\n"}} end
      )

    assert missing_origin.status == :blocked
    assert missing_origin.failure.reason == :origin_remote_missing

    command_failure =
      PublishHandoff.run(
        workspace,
        publish_policy(vcs_mode: "jj"),
        issue("SID-309"),
        completion_for(["lib/source.ex"]),
        runner: fn %{step: :jj_remote_list} -> {:ok, %{status: 2, output: "remote failed\n"}} end
      )

    assert command_failure.status == :blocked
    assert command_failure.failure.reason == :jj_remote_list_failed
    assert command_failure.failure.details == "remote failed"

    command_error =
      PublishHandoff.run(
        workspace,
        publish_policy(vcs_mode: "jj"),
        issue("SID-309"),
        completion_for(["lib/source.ex"]),
        runner: fn %{step: :jj_remote_list} -> {:error, :boom} end
      )

    assert command_error.status == :blocked
    assert command_error.failure.reason == :jj_remote_list_failed
    assert command_error.failure.details == ":boom"
  end

  test "blocks when manifest paths do not match the jj change payload" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")
    parent = self()

    result =
      PublishHandoff.run(
        workspace,
        publish_policy(vcs_mode: "jj"),
        issue("SID-309"),
        completion_for(["lib/source.ex"]),
        runner: fn %{step: step, command: command, args: args} ->
          send(parent, {:publish_command, step, command, args})

          output =
            case step do
              :jj_remote_list -> "origin https://github.com/example/project.git\n"
              :jj_changed_files -> "lib/source.ex\n.env\n"
              _step -> "ok\n"
            end

          {:ok, %{status: 0, output: output}}
        end
      )

    assert result.status == :blocked
    assert result.failure.reason == :change_manifest_mismatch
    assert result.failure.metadata.vcs_only == [".env"]
    assert_receive {:publish_command, :jj_changed_files, "jj", ["diff", "--name-only", "-r", "@"]}
    refute_receive {:publish_command, :jj_push, _command, _args}, 50
  end

  test "blocks when PR creation succeeds without returning a URL" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")

    result =
      PublishHandoff.run(
        workspace,
        publish_policy(vcs_mode: "jj"),
        issue("SID-309"),
        completion_for(["lib/source.ex"]),
        runner: fn %{step: step} ->
          output =
            case step do
              :jj_remote_list -> "origin https://github.com/example/project.git\n"
              :jj_changed_files -> "lib/source.ex\n"
              :pr_view -> ""
              :pr_create -> " \n"
              :jj_current -> "abcdefgh 1234567\n"
              _step -> "ok\n"
            end

          status = if step == :pr_view, do: 1, else: 0
          {:ok, %{status: status, output: output}}
        end
      )

    assert result.status == :blocked
    assert result.failure.reason == :pr_create_missing_pr_url
  end

  test "falls back to PR creation when PR view errors" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")

    result =
      PublishHandoff.run(
        workspace,
        publish_policy(vcs_mode: "jj"),
        issue("SID-309"),
        completion_for(["lib/source.ex"]),
        runner: fn
          %{step: :jj_remote_list} -> {:ok, %{status: 0, output: "origin https://github.com/example/project.git\n"}}
          %{step: :jj_changed_files} -> {:ok, %{status: 0, output: "lib/source.ex\n"}}
          %{step: :pr_view} -> {:error, :gh_unavailable}
          %{step: :pr_create} -> {:ok, %{status: 0, output: "https://github.com/example/project/pull/309\n"}}
          %{step: :jj_current} -> {:ok, %{status: 0, output: "onlychange\n"}}
          %{step: _step} -> {:ok, %{status: 0, output: "ok\n"}}
        end
      )

    assert result.status == :passed
    assert result.change_id == "onlychange"
    assert result.commit_sha == nil
    assert result.pr_url == "https://github.com/example/project/pull/309"
  end

  test "uses fallback issue metadata when Linear issue details are absent" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")
    parent = self()

    result =
      PublishHandoff.run(
        workspace,
        publish_policy(vcs_mode: "jj"),
        nil,
        completion_for(["lib/source.ex"])
        |> Map.put(:checks, ["raw check entry", %{name: "all", status: "passed"}]),
        runner: fn %{step: step, command: command, args: args} ->
          send(parent, {:publish_command, step, command, args})

          output =
            case step do
              :jj_remote_list -> "origin https://github.com/example/project.git\n"
              :jj_changed_files -> "lib/source.ex\n"
              :pr_view -> "no pull request found"
              :pr_create -> "https://github.com/example/project/pull/1\n"
              :jj_current -> "\n"
              _step -> "ok\n"
            end

          status = if step == :pr_view, do: 1, else: 0
          {:ok, %{status: status, output: output}}
        end
      )

    assert result.status == :passed
    assert result.branch == "ticket/issue"
    assert result.change_id == nil
    assert result.commit_sha == nil
    assert result.linear_issue == %{id: nil, identifier: nil, url: nil}
    assert_receive {:publish_command, :jj_describe, "jj", ["describe", "-m", "chore: publish Symphony workspace changes"]}
    assert_receive {:publish_command, :pr_create, "gh", pr_create_args}
    assert ["pr", "create", "--repo", "example/project", "--head", "example:ticket/issue", "--base", "main", "--title", "Publish Symphony workspace changes" | _rest] = pr_create_args
  end

  test "blocks when a local publish command times out" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-publish-handoff-timeout-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      fake_bin = Path.join(test_root, "bin")

      File.mkdir_p!(Path.join(workspace, "lib"))
      File.mkdir_p!(fake_bin)
      File.write!(Path.join(workspace, "lib/source.ex"), "defmodule Source do\nend\n")
      File.write!(Path.join(fake_bin, "jj"), "#!/bin/sh\nsleep 1\n")
      File.chmod!(Path.join(fake_bin, "jj"), 0o755)

      result =
        PublishHandoff.run(
          workspace,
          publish_policy(vcs_mode: "jj"),
          issue("SID-309"),
          completion_for(["lib/source.ex"]),
          env: [{"PATH", fake_bin}],
          timeout_ms: 1
        )

      assert result.status == :blocked
      assert result.failure.reason == :jj_remote_list_failed
      assert result.failure.details =~ "publish_handoff_timeout"
    after
      File.rm_rf(test_root)
    end
  end

  test "blocks when required local publish executables are missing" do
    previous_path = System.get_env("PATH")
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")

    try do
      System.put_env("PATH", "")

      result =
        PublishHandoff.run(
          workspace,
          publish_policy(vcs_mode: "jj"),
          issue("SID-309"),
          completion_for(["lib/source.ex"]),
          env: [],
          timeout_ms: 100
        )

      assert result.status == :blocked
      assert result.failure.reason == :jj_remote_list_failed
      assert result.failure.details =~ "command_not_found"
    after
      restore_env("PATH", previous_path)
    end
  end

  test "normalizes publish evidence fallback shapes" do
    assert PublishHandoffEvidence.normalize(nil) == nil
    assert PublishHandoffEvidence.evidence(%{}) == []
    assert HandoffManifest.source(nil) == :absent

    string_failure_blocker =
      PublishHandoffEvidence.blocker(%{
        status: :blocked,
        failure: %{"summary" => "String-key failure summary"}
      })

    assert string_failure_blocker.reason == "String-key failure summary"

    unknown_status =
      PublishHandoffEvidence.normalize(%{
        "status" => "not a known status",
        "pr_url" => " ",
        "linear_issue" => "not a map",
        "failure" => "plain failure",
        123 => [%{"summary" => "nested"}]
      })

    assert unknown_status.status == :unknown
    assert unknown_status.pr_url == nil
    assert unknown_status.linear_issue == %{}
    assert unknown_status.failure == %{summary: "plain failure"}

    blocked =
      PublishHandoffEvidence.normalize(%{
        status: 123,
        repository: "https://github.com/example/project.git",
        base_branch: "main",
        failure: %{}
      })
      |> Map.put(:status, :blocked)

    assert [%{summary: "Host publish failed for https://github.com/example/project.git:main."}] =
             PublishHandoffEvidence.evidence(blocked)

    unknown_target =
      PublishHandoffEvidence.normalize(%{status: :blocked, failure: %{}})

    assert [%{summary: "Host publish failed for unknown target."}] =
             PublishHandoffEvidence.evidence(unknown_target)
  end

  test "handoff route exposes publish evidence for Linear status recording" do
    workspace = workspace_with_file!("lib/source.ex", "defmodule Source do\nend\n")

    decision =
      HandoffRouteRecorder.classify_completion(
        completion_for(["lib/source.ex"])
        |> Map.put(:changed_surfaces, ["workflow"])
        |> Map.put(:publish_handoff, %{
          status: :passed,
          pr_url: "https://github.com/apontarelli/symphony/pull/309",
          repository: "https://github.com/apontarelli/symphony",
          github_repository: "apontarelli/symphony",
          base_branch: "main",
          branch: "ticket/sid-309",
          change_id: "abcdefgh",
          commit_sha: "1234567",
          validation_summary: "all passed",
          linear_issue: %{id: "issue-SID-309", identifier: "SID-309", url: "https://linear.example/SID-309"}
        }),
        nil,
        workspace,
        nil
      )

    assert decision.route == :human_review

    assert Enum.any?(decision.evidence, fn evidence ->
             evidence.kind == :publish and evidence.status == :passed and
               evidence.metadata.pr_url == "https://github.com/apontarelli/symphony/pull/309" and
               evidence.metadata.target == "apontarelli/symphony:main" and
               evidence.metadata.linear_issue.identifier == "SID-309"
           end)

    assert HandoffRoute.format_comment(decision) =~
             "publish/passed: Published PR https://github.com/apontarelli/symphony/pull/309 targeting apontarelli/symphony:main."

    blocked =
      HandoffRouteRecorder.classify_completion(
        completion_for(["lib/source.ex"])
        |> Map.put(:publish_handoff, %{
          status: :blocked,
          repository: "https://github.com/apontarelli/symphony",
          github_repository: "apontarelli/symphony",
          base_branch: "main",
          branch: "ticket/sid-309",
          failure: %{reason: :pr_create_failed, summary: "GitHub PR creation failed.", details: "permission denied"}
        }),
        nil,
        workspace,
        nil
      )

    assert blocked.route == :blocked
    assert Enum.any?(blocked.evidence, &(&1.kind == :publish and &1.status == :blocked))
  end

  defp completion_for(changed_files) do
    %{
      checks: [%{name: "all", status: :passed, summary: "all passed"}],
      review: %{status: :clean, summary: "automated review passed"},
      change_manifest: %{changed_files: changed_files, validation: [%{name: "all", status: "passed"}]},
      publish_preflight: %{
        status: :passed,
        repository: "https://github.com/example/project",
        base_branch: "main",
        capabilities: %{workspace_vcs_metadata: true, remote_push: true, pr_creation: true},
        failures: []
      }
    }
  end

  defp issue(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Publish validated workspace changes",
      state: "In Progress",
      url: "https://linear.example/#{identifier}"
    }
  end

  defp publish_policy(overrides \\ []) do
    repository = Keyword.get(overrides, :repository, "https://github.com/example/project")
    github_repository = Keyword.get(overrides, :github_repository, "example/project")
    vcs_mode = Keyword.get(overrides, :vcs_mode, "jj")

    %{
      "publish_target" => %{
        "repository" => repository,
        "pr_target" => "main",
        "github_repository" => github_repository,
        "display" => "#{github_repository}:main"
      },
      "manifest" => %{
        "project" => %{"repository" => repository},
        "vcs" => %{"mode" => vcs_mode}
      },
      "delivery" => %{"pr_target" => "main"}
    }
  end

  defp workspace_with_file!(relative_path, contents) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-publish-handoff-#{System.unique_integer([:positive])}"
      )

    absolute_path = Path.join(workspace, relative_path)
    File.mkdir_p!(Path.dirname(absolute_path))
    File.write!(absolute_path, contents)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(workspace) end)
    workspace
  end
end
