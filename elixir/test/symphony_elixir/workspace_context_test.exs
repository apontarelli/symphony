defmodule SymphonyElixir.WorkspaceContextTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.{ExecutionContext, TargetContext, Workspace}
  alias SymphonyElixir.Linear.Issue

  @hash "sha256:" <> String.duplicate("a", 64)

  @tag :tmp_dir
  test "context creation isolates the same issue under pinned target roots", %{tmp_dir: tmp_dir} do
    context_a = context(Path.join(tmp_dir, "root-a"), "alpha", "SID-410")
    context_b = context(Path.join(tmp_dir, "root-b"), "beta", "SID-410")

    assert {:ok, workspace_a} = Workspace.create_for_issue(context_a)
    assert {:ok, workspace_b} = Workspace.create_for_issue(context_b)

    assert workspace_a == Path.join([tmp_dir, "root-a", "alpha", "SID-410"])
    assert workspace_b == Path.join([tmp_dir, "root-b", "beta", "SID-410"])
    assert File.dir?(workspace_a)
    assert File.dir?(workspace_b)
    refute workspace_a == workspace_b
  end

  @tag :tmp_dir
  test "context creation runs the pinned after-create hook", %{tmp_dir: tmp_dir} do
    hooks = %{
      "after_create" => "printf 'created\\n' > after-create.log",
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => nil,
      "timeout_ms" => 1_000
    }

    context = context(Path.join(tmp_dir, "root"), "alpha", "SID-410", hooks: hooks)

    assert {:ok, workspace} = Workspace.create_for_issue(context)
    assert File.read!(Path.join(workspace, "after-create.log")) == "created\n"
  end

  @tag :tmp_dir
  test "before-run uses the pinned hook and issue authority", %{tmp_dir: tmp_dir} do
    hooks = %{
      "after_create" => nil,
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => "printf 'before-run\\n' > before-run.log",
      "timeout_ms" => 1_000
    }

    context = context(Path.join(tmp_dir, "root"), "alpha", "SID-410", hooks: hooks)
    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}

    assert {:ok, workspace} = Workspace.create_for_issue(context)
    assert :ok = Workspace.run_before_run_hook(context, issue)
    assert File.read!(Path.join(workspace, "before-run.log")) == "before-run\n"
  end

  @tag :tmp_dir
  test "after-run ignores a pinned hook failure without exposing output", %{tmp_dir: tmp_dir} do
    secret = "secret-sentinel-after-run"

    hooks = %{
      "after_create" => nil,
      "after_run" => "after-run-command",
      "before_remove" => nil,
      "before_run" => nil,
      "timeout_ms" => 777
    }

    context = context(Path.join(tmp_dir, "root"), "alpha", "SID-410", hooks: hooks)
    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}
    assert {:ok, workspace} = Workspace.create_for_issue(context)
    parent = self()

    command_runner = fn command, hook_workspace, timeout_ms ->
      send(parent, {:after_run, command, hook_workspace, timeout_ms})
      {secret, 17}
    end

    assert :ok =
             Workspace.run_after_run_hook(context, issue, command_runner: command_runner)

    assert_receive {:after_run, "after-run-command", ^workspace, 777}
  end

  @tag :tmp_dir
  test "context removal runs only its pinned before-remove hook and leaves another workspace", %{
    tmp_dir: tmp_dir
  } do
    marker = Path.join(tmp_dir, "before-remove-a.log")

    hooks_a = %{
      "after_create" => nil,
      "after_run" => nil,
      "before_remove" => "printf 'A\\n' > #{marker}",
      "before_run" => nil,
      "timeout_ms" => 1_000
    }

    root = Path.join(tmp_dir, "root")
    context_a = context(root, "alpha", "SID-410-A", hooks: hooks_a)
    context_b = context(root, "alpha", "SID-410-B")

    assert {:ok, workspace_a} = Workspace.create_for_issue(context_a)
    assert {:ok, workspace_b} = Workspace.create_for_issue(context_b)
    assert {:ok, _removed} = Workspace.remove(context_a)

    refute File.exists?(workspace_a)
    assert File.dir?(workspace_b)
    assert File.read!(marker) == "A\n"
  end

  @tag :tmp_dir
  test "target cleanup deletes only the requested local issue workspace", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    context_a = context(root, "alpha", "SID-410-A")
    context_b = context(root, "alpha", "SID-410-B")

    assert {:ok, workspace_a} = Workspace.create_for_issue(context_a)
    assert {:ok, workspace_b} = Workspace.create_for_issue(context_b)

    assert :ok =
             Workspace.remove_issue_workspaces(context_a.target, context_a.issue_identifier, nil)

    refute File.exists?(workspace_a)
    assert File.dir?(workspace_b)
  end

  @tag :tmp_dir
  test "context paths reject forged identities before local effects", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    context = context(root, "alpha", "SID-410")

    hostile_contexts = [
      %{context | workspace_path: root},
      %{context | workspace_path: Path.join([root <> "-other", "alpha", "SID-410"])},
      %{context | issue_identifier: "."},
      %{context | issue_identifier: ".."},
      %{context | issue_identifier: "../SID-410"},
      %{context | issue_identifier: "SID/410"},
      %{context | issue_identifier: "SID\\410"},
      %{context | issue_identifier: "SID-\n410"},
      %{context | issue_identifier: <<0xFF>>},
      %{context | target: %{context.target | target_id: "alpha/other"}},
      %{
        context
        | target: %{
            context.target
            | worktree_policy: Map.put(context.target.worktree_policy, "unknown", "secret-sentinel-policy")
          }
      }
    ]

    for hostile_context <- hostile_contexts do
      assert {:error, :invalid_workspace_context} =
               Workspace.create_for_issue(hostile_context)
    end

    refute File.exists?(root)
    refute File.exists?(root <> "-other")
  end

  @tag :tmp_dir
  test "context paths reject root, target, and issue symlinks", %{tmp_dir: tmp_dir} do
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(outside)

    linked_root = Path.join(tmp_dir, "linked-root")
    File.ln_s!(outside, linked_root)
    root_context = context(linked_root, "alpha", "SID-410")

    assert {:error, :invalid_workspace_context} = Workspace.create_for_issue(root_context)

    target_root = Path.join(tmp_dir, "target-root")
    File.mkdir_p!(target_root)
    File.ln_s!(outside, Path.join(target_root, "alpha"))
    target_context = context(target_root, "alpha", "SID-410")

    assert {:error, :invalid_workspace_context} = Workspace.create_for_issue(target_context)

    issue_root = Path.join(tmp_dir, "issue-root")
    File.mkdir_p!(Path.join(issue_root, "alpha"))
    File.ln_s!(outside, Path.join([issue_root, "alpha", "SID-410"]))
    issue_context = context(issue_root, "alpha", "SID-410")

    assert {:error, :invalid_workspace_context} = Workspace.create_for_issue(issue_context)
    assert {:ok, []} = File.ls(outside)
  end

  @tag :tmp_dir
  test "context removal stops when the before-remove hook replaces its workspace with a symlink", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "root")
    context_a = context(root, "alpha", "SID-410-A")
    context_b = context(root, "alpha", "SID-410-B")
    assert {:ok, workspace_a} = Workspace.create_for_issue(context_a)
    assert {:ok, workspace_b} = Workspace.create_for_issue(context_b)

    command = "rm -rf -- #{workspace_a} && ln -s -- #{workspace_b} #{workspace_a}"
    hooks = %{context_a.target.worktree_policy["hooks"] | "before_remove" => command}

    forged_after_hook = %{
      context_a
      | target: %{
          context_a.target
          | worktree_policy: %{context_a.target.worktree_policy | "hooks" => hooks}
        }
    }

    assert {:error, :invalid_workspace_context} = Workspace.remove(forged_after_hook)
    assert File.dir?(workspace_b)
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(workspace_a)
  end

  @tag :tmp_dir
  test "context hook dependency failures return fixed secret-safe errors", %{tmp_dir: tmp_dir} do
    secret = "secret-sentinel-dependency"

    hooks = %{
      "after_create" => nil,
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => "secret-command",
      "timeout_ms" => 1_000
    }

    context = context(Path.join(tmp_dir, "root"), "alpha", "SID-410", hooks: hooks)
    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}
    assert {:ok, _workspace} = Workspace.create_for_issue(context)

    for failure <- [
          fn -> raise secret end,
          fn -> throw(secret) end,
          fn -> exit(secret) end
        ] do
      command_runner = fn _command, _workspace, _timeout_ms -> failure.() end

      log =
        capture_log(fn ->
          assert {:error, :workspace_hook_dependency_failed} =
                   Workspace.run_before_run_hook(
                     context,
                     issue,
                     command_runner: command_runner
                   )
        end)

      refute log =~ secret
    end
  end

  @tag :tmp_dir
  test "context lifecycle preserves pinned hook failure handling", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    issue = %Issue{id: "issue-410", identifier: "SID-410"}

    after_create_hooks = %{
      "after_create" => "after-create",
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => nil,
      "timeout_ms" => 1_000
    }

    after_create_context = context(root, "alpha", "SID-410", hooks: after_create_hooks)
    failing_runner = fn _command, _workspace, _timeout_ms -> {"private output", 19} end

    assert {:error, :workspace_hook_failed} =
             Workspace.create_for_issue(
               after_create_context,
               command_runner: failing_runner
             )

    before_run_hooks = %{after_create_hooks | "after_create" => nil, "before_run" => "before-run"}
    before_run_context = context(root, "beta", "SID-410", hooks: before_run_hooks)
    assert {:ok, workspace} = Workspace.create_for_issue(before_run_context)

    assert {:error, :workspace_hook_failed} =
             Workspace.run_before_run_hook(
               before_run_context,
               issue,
               command_runner: failing_runner
             )

    before_remove_hooks = %{
      before_run_hooks
      | "before_run" => nil,
        "before_remove" => "before-remove"
    }

    before_remove_context = %{
      before_run_context
      | target: %{
          before_run_context.target
          | worktree_policy: %{
              before_run_context.target.worktree_policy
              | "hooks" => before_remove_hooks
            }
        }
    }

    assert {:ok, _removed} =
             Workspace.remove(before_remove_context, command_runner: failing_runner)

    refute File.exists?(workspace)
  end

  @tag :tmp_dir
  test "concurrent context creation keeps pinned roots hooks and timeouts after globals change", %{
    tmp_dir: tmp_dir
  } do
    previous_path = Application.get_env(:symphony_elixir, :workflow_file_path)

    on_exit(fn ->
      if previous_path,
        do: Application.put_env(:symphony_elixir, :workflow_file_path, previous_path),
        else: Application.delete_env(:symphony_elixir, :workflow_file_path)
    end)

    context_a =
      context(Path.join(tmp_dir, "root-a"), "alpha", "SID-410",
        hooks: %{
          "after_create" => "hook-a",
          "after_run" => nil,
          "before_remove" => nil,
          "before_run" => nil,
          "timeout_ms" => 111
        }
      )

    context_b =
      context(Path.join(tmp_dir, "root-b"), "beta", "SID-410",
        hooks: %{
          "after_create" => "hook-b",
          "after_run" => nil,
          "before_remove" => nil,
          "before_run" => nil,
          "timeout_ms" => 222
        }
      )

    parent = self()

    runner = fn command, workspace, timeout_ms ->
      send(parent, {:ready, self(), command, workspace, timeout_ms})

      receive do
        :continue -> {"", 0}
      end
    end

    task_a = Task.async(fn -> Workspace.create_for_issue(context_a, command_runner: runner) end)
    task_b = Task.async(fn -> Workspace.create_for_issue(context_b, command_runner: runner) end)

    assert_receive {:ready, runner_a, "hook-a", workspace_a, 111}, 1_000
    assert_receive {:ready, runner_b, "hook-b", workspace_b, 222}, 1_000

    Application.put_env(
      :symphony_elixir,
      :workflow_file_path,
      Path.join(tmp_dir, "poisoned-symphony.yml")
    )

    send(runner_a, :continue)
    send(runner_b, :continue)

    assert {:ok, ^workspace_a} = Task.await(task_a)
    assert {:ok, ^workspace_b} = Task.await(task_b)
    assert File.dir?(workspace_a)
    assert File.dir?(workspace_b)
  end

  test "remote context creation uses one injected atomic SSH operation" do
    hooks = %{
      "after_create" => "printf after-create",
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => nil,
      "timeout_ms" => 1_000
    }

    context =
      context("/remote/workspaces-a", "alpha", "SID-410",
        hooks: hooks,
        worker_host: "worker.example"
      )

    parent = self()

    ssh_runner = fn host, script, timeout_ms ->
      send(parent, {:ssh, host, script, timeout_ms})

      output =
        context_remote_marker(
          script,
          "/remote/workspaces-a",
          "/remote/workspaces-a/alpha/SID-410",
          "created"
        )

      {output, 0}
    end

    assert {:ok, "/remote/workspaces-a/alpha/SID-410"} =
             Workspace.create_for_issue(context, ssh_runner: ssh_runner)

    assert_receive {:ssh, "worker.example", script, 7_000}
    assert script =~ "set -eu"
    assert script =~ "canonical_root"
    assert script =~ "canonical_workspace"
    assert script =~ "printf after-create"
    assert script =~ "mkdir"
    refute_receive {:ssh, _host, _script, _timeout_ms}
  end

  test "remote context hook revalidates and uses one SSH operation" do
    hooks = %{
      "after_create" => nil,
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => "printf pinned-hook",
      "timeout_ms" => 444
    }

    context =
      context("/remote/workspaces-a", "alpha", "SID-410",
        hooks: hooks,
        worker_host: "worker.example"
      )

    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}
    parent = self()

    ssh_runner = fn host, script, timeout_ms ->
      send(parent, {:ssh_hook, host, script, timeout_ms})

      {context_remote_marker(
         script,
         "/remote/workspaces-a",
         "/remote/workspaces-a/alpha/SID-410",
         "hooked"
       ), 0}
    end

    assert :ok =
             Workspace.run_before_run_hook(context, issue, ssh_runner: ssh_runner)

    assert_receive {:ssh_hook, "worker.example", script, 6_444}
    assert script =~ "set -eu"
    assert script =~ "printf pinned-hook"
    assert script =~ "[ ! -L"
    refute_receive {:ssh_hook, _host, _script, _timeout_ms}
  end

  test "remote context removal keeps before-remove and delete in one SSH operation" do
    hooks = %{
      "after_create" => nil,
      "after_run" => nil,
      "before_remove" => "printf before-remove",
      "before_run" => nil,
      "timeout_ms" => 555
    }

    context =
      context("/remote/workspaces-a", "alpha", "SID-410",
        hooks: hooks,
        worker_host: "worker.example"
      )

    parent = self()

    ssh_runner = fn host, script, timeout_ms ->
      send(parent, {:ssh_remove, host, script, timeout_ms})

      {context_remote_marker(
         script,
         "/remote/workspaces-a",
         "/remote/workspaces-a/alpha/SID-410",
         "deleted"
       ), 0}
    end

    assert {:ok, []} = Workspace.remove(context, ssh_runner: ssh_runner)

    assert_receive {:ssh_remove, "worker.example", script, 6_555}
    assert script =~ "printf before-remove"
    assert script =~ "rm -rf -- \"$canonical_workspace\""
    assert script =~ "canonical_workspace"
    refute_receive {:ssh_remove, _host, _script, _timeout_ms}
  end

  @tag :tmp_dir
  test "remote context removal succeeds repeatedly when the configured root is absent", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "missing-remote-root")
    context = context(root, "alpha", "SID-410", worker_host: "worker.example")
    parent = self()

    shell_runner = fn host, script, timeout_ms ->
      send(parent, {:missing_root_delete_ssh, host, script, timeout_ms})
      System.cmd("sh", ["-c", script], stderr_to_stdout: true)
    end

    assert {:ok, []} = Workspace.remove(context, ssh_runner: shell_runner)
    refute File.exists?(root)
    assert_receive {:missing_root_delete_ssh, "worker.example", first_script, 7_000}
    refute_receive {:missing_root_delete_ssh, _host, _script, _timeout_ms}

    assert {:ok, []} = Workspace.remove(context, ssh_runner: shell_runner)
    refute File.exists?(root)
    assert_receive {:missing_root_delete_ssh, "worker.example", second_script, 7_000}
    refute_receive {:missing_root_delete_ssh, _host, _script, _timeout_ms}

    for script <- [first_script, second_script] do
      assert script =~ "root_candidate"
      refute script =~ "mkdir -- \"$root_candidate\""
    end
  end

  @tag :tmp_dir
  test "remote context removal rejects a symlinked configured root", %{tmp_dir: tmp_dir} do
    outside = Path.join(tmp_dir, "outside-root")
    root = Path.join(tmp_dir, "linked-remote-root")
    File.mkdir!(outside)
    File.write!(Path.join(outside, "sentinel"), "unchanged")
    File.ln_s!(outside, root)

    context = context(root, "alpha", "SID-410", worker_host: "worker.example")
    parent = self()

    shell_runner = fn host, script, timeout_ms ->
      send(parent, {:linked_root_delete_ssh, host, script, timeout_ms})
      System.cmd("sh", ["-c", script], stderr_to_stdout: true)
    end

    assert {:error, :workspace_remote_output_invalid} =
             Workspace.remove(context, ssh_runner: shell_runner)

    assert_receive {:linked_root_delete_ssh, "worker.example", _script, 7_000}
    refute_receive {:linked_root_delete_ssh, _host, _script, _timeout_ms}
    assert File.read!(Path.join(outside, "sentinel")) == "unchanged"
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(root)
  end

  @tag :tmp_dir
  test "remote context removal is idempotent in one SSH call per request", %{tmp_dir: tmp_dir} do
    context =
      context(Path.join(tmp_dir, "remote-root"), "alpha", "SID-410", worker_host: "worker.example")

    parent = self()

    shell_runner = fn host, script, timeout_ms ->
      send(parent, {:idempotent_ssh, host, script, timeout_ms})
      System.cmd("sh", ["-c", script], stderr_to_stdout: true)
    end

    assert {:ok, workspace} = Workspace.create_for_issue(context, ssh_runner: shell_runner)
    assert {:ok, []} = Workspace.remove(context, ssh_runner: shell_runner)
    refute File.exists?(workspace)
    assert {:ok, []} = Workspace.remove(context, ssh_runner: shell_runner)

    assert_receive {:idempotent_ssh, "worker.example", create_script, 7_000}
    assert_receive {:idempotent_ssh, "worker.example", first_delete_script, 7_000}
    assert_receive {:idempotent_ssh, "worker.example", second_delete_script, 7_000}
    assert create_script =~ "mkdir -- \"$root_candidate\""
    assert first_delete_script =~ "rm -rf -- \"$canonical_workspace\""
    assert second_delete_script =~ "'deleted'"
    refute_receive {:idempotent_ssh, _host, _script, _timeout_ms}
  end

  @tag :tmp_dir
  test "remote context removal rejects symlink malformed and out-of-root workspaces", %{
    tmp_dir: tmp_dir
  } do
    outside = Path.join(tmp_dir, "outside")
    File.mkdir!(outside)
    parent = self()

    shell_runner = fn _host, script, _timeout_ms ->
      send(parent, :hostile_remove_ssh)
      System.cmd("sh", ["-c", script], stderr_to_stdout: true)
    end

    linked =
      context(Path.join(tmp_dir, "linked-root"), "alpha", "SID-LINK", worker_host: "worker.example")

    File.mkdir_p!(Path.dirname(linked.workspace_path))
    File.ln_s!(outside, linked.workspace_path)

    assert {:error, :workspace_remote_output_invalid} =
             Workspace.remove(linked, ssh_runner: shell_runner)

    assert_receive :hostile_remove_ssh
    assert File.dir?(outside)
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(linked.workspace_path)

    malformed =
      context(Path.join(tmp_dir, "malformed-root"), "alpha", "SID-FILE", worker_host: "worker.example")

    File.mkdir_p!(Path.dirname(malformed.workspace_path))
    File.write!(malformed.workspace_path, "unchanged")

    assert {:error, :workspace_remote_output_invalid} =
             Workspace.remove(malformed, ssh_runner: shell_runner)

    assert_receive :hostile_remove_ssh
    assert File.read!(malformed.workspace_path) == "unchanged"

    forged = %{malformed | workspace_path: Path.join(tmp_dir, "outside-workspace")}

    assert {:error, :invalid_workspace_context} =
             Workspace.remove(forged, ssh_runner: shell_runner)

    refute_receive :hostile_remove_ssh
  end

  test "remote target cleanup uses its explicit host without global fan-out" do
    context =
      context("/remote/workspaces-a", "alpha", "SID-410", worker_host: "worker.example")

    parent = self()

    ssh_runner = fn host, script, timeout_ms ->
      send(parent, {:ssh_target_remove, host, script, timeout_ms})

      {context_remote_marker(
         script,
         "/remote/workspaces-a",
         "/remote/workspaces-a/alpha/SID-410",
         "deleted"
       ), 0}
    end

    assert :ok =
             Workspace.remove_issue_workspaces(
               context.target,
               context.issue_identifier,
               context.worker_host,
               ssh_runner: ssh_runner
             )

    assert_receive {:ssh_target_remove, "worker.example", script, 7_000}
    assert script =~ "rm -rf -- \"$canonical_workspace\""
    refute_receive {:ssh_target_remove, _host, _script, _timeout_ms}
  end

  test "remote context rejects current markers bound to another canonical root" do
    hooks = %{
      "after_create" => nil,
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => "before-run",
      "timeout_ms" => 1_000
    }

    context =
      context("/remote/root-a", "alpha", "SID-410",
        hooks: hooks,
        worker_host: "worker.example"
      )

    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}
    other_root = "/remote/secret-sentinel-other-root"
    other_workspace = Path.join([other_root, "alpha", "SID-410"])
    parent = self()

    operations = [
      {"created", fn runner -> Workspace.create_for_issue(context, ssh_runner: runner) end},
      {"hooked", fn runner -> Workspace.run_before_run_hook(context, issue, ssh_runner: runner) end},
      {"deleted", fn runner -> Workspace.remove(context, ssh_runner: runner) end}
    ]

    for {marker_status, operation} <- operations do
      runner = fn _host, script, _timeout_ms ->
        raw_output =
          context_remote_marker(script, other_root, other_workspace, marker_status)

        send(parent, {:forged_remote_output, raw_output})
        {raw_output, 0}
      end

      log =
        capture_log(fn ->
          result = operation.(runner)
          assert result == {:error, :workspace_remote_output_invalid}
          refute inspect(result) =~ other_root
        end)

      assert_receive {:forged_remote_output, raw_output}
      refute log =~ other_root
      refute log =~ raw_output
    end
  end

  test "remote context rejects malformed canonical markers with fixed errors" do
    context =
      context("/remote/root-a", "alpha", "SID-410", worker_host: "worker.example")

    valid = fn nonce ->
      "__SYMPHONY_CONTEXT_WORKSPACE__\t#{nonce}\t/remote/root-a\t" <>
        "/remote/root-a/alpha/SID-410\tcreated\n"
    end

    hostile_outputs = [
      fn _nonce -> "" end,
      fn nonce -> valid.(nonce) <> valid.(nonce) end,
      fn _nonce ->
        "__SYMPHONY_CONTEXT_WORKSPACE__\t#{String.duplicate("z", 32)}\t/remote/root-a\t" <>
          "/remote/root-a/alpha/SID-410\tcreated\n"
      end,
      fn nonce -> "__SYMPHONY_CONTEXT_WORKSPACE__\t#{nonce}\t/remote/root-a\tcreated\n" end,
      fn nonce ->
        "__SYMPHONY_CONTEXT_WORKSPACE__\t#{nonce}\t/remote/root-a\t/remote/root-a\tcreated\n"
      end,
      fn nonce ->
        "__SYMPHONY_CONTEXT_WORKSPACE__\t#{nonce}\t/remote/root-a\t" <>
          "/remote/root-ab/alpha/SID-410\tcreated\n"
      end,
      fn nonce ->
        "__SYMPHONY_CONTEXT_WORKSPACE__\t#{nonce}\t/remote/root-a\t" <>
          "/remote/root-a/alpha/../escape\tcreated\n"
      end,
      fn nonce ->
        "__SYMPHONY_CONTEXT_WORKSPACE__\t#{nonce}\t/remote/root-a\t" <>
          "/remote/root-a/alpha/SID-410\tunknown\n"
      end,
      fn _nonce -> <<0xFF>> end
    ]

    for hostile_output <- hostile_outputs do
      ssh_runner = fn _host, script, _timeout_ms ->
        {hostile_output.(remote_marker_nonce(script)), 0}
      end

      assert {:error, :workspace_remote_output_invalid} =
               Workspace.create_for_issue(context, ssh_runner: ssh_runner)
    end
  end

  test "remote context rejects a marker replayed from a previous invocation" do
    context =
      context("/remote/root-a", "alpha", "SID-410", worker_host: "worker.example")

    {:ok, replay_state} = Agent.start_link(fn -> nil end)

    ssh_runner = fn _host, script, _timeout_ms ->
      nonce = remote_marker_nonce(script)

      current =
        "__SYMPHONY_CONTEXT_WORKSPACE__\t#{nonce}\t/remote/root-a\t" <>
          "/remote/root-a/alpha/SID-410\tcreated\n"

      output =
        Agent.get_and_update(replay_state, fn
          nil -> {current, current}
          stale -> {stale, stale}
        end)

      {output, 0}
    end

    assert {:ok, context.workspace_path} ==
             Workspace.create_for_issue(context, ssh_runner: ssh_runner)

    stale_nonce =
      replay_state
      |> Agent.get(& &1)
      |> String.split("\t")
      |> Enum.at(1)

    result = Workspace.create_for_issue(context, ssh_runner: ssh_runner)
    assert result == {:error, :workspace_remote_output_invalid}
    refute inspect(result) =~ stale_nonce
  end

  test "remote context rejects hostile logical authority before SSH" do
    valid =
      context("/remote/root-a", "alpha", "SID-410", worker_host: "worker.example")

    hostile_contexts = [
      %{valid | issue_identifier: "../SID-410"},
      %{valid | issue_identifier: "SID\n410"},
      %{valid | issue_identifier: <<0xFF>>},
      %{valid | target: %{valid.target | target_id: "alpha/other"}},
      %{
        valid
        | target: %{
            valid.target
            | worktree_policy: %{valid.target.worktree_policy | "root" => "relative/root"}
          }
      },
      %{valid | worker_host: "worker host"}
    ]

    parent = self()

    ssh_runner = fn _host, _script, _timeout_ms ->
      send(parent, :unexpected_ssh)
      {"", 0}
    end

    for hostile_context <- hostile_contexts do
      assert {:error, :invalid_workspace_context} =
               Workspace.create_for_issue(hostile_context, ssh_runner: ssh_runner)
    end

    refute_receive :unexpected_ssh
  end

  test "remote dependency failures and timeouts are fixed and secret-safe" do
    secret = "secret-sentinel-remote-dependency"

    hooks = %{
      "after_create" => nil,
      "after_run" => nil,
      "before_remove" => "blocked-hook",
      "before_run" => nil,
      "timeout_ms" => 1_000
    }

    context =
      context("/remote/root-a", "alpha", "SID-410",
        hooks: hooks,
        worker_host: "worker.example"
      )

    for failure <- [
          fn -> raise secret end,
          fn -> throw(secret) end,
          fn -> exit(secret) end
        ] do
      ssh_runner = fn _host, _script, _timeout_ms -> failure.() end

      log =
        capture_log(fn ->
          assert {:error, :workspace_remote_dependency_failed} =
                   Workspace.create_for_issue(context, ssh_runner: ssh_runner)
        end)

      refute log =~ secret
    end
  end

  @tag :tmp_dir
  test "remote before-remove timeout kills and reaps a TERM-resistant hook group", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "remote-root")
    workspace = Path.join([root, "alpha", "SID-TIMEOUT-GROUP"])
    release_fifo = Path.join(tmp_dir, "release.fifo")
    leader_pid_file = Path.join(tmp_dir, "leader.pid")
    descendant_pid_file = Path.join(tmp_dir, "descendant.pid")
    descendant_marker = Path.join(tmp_dir, "descendant-survived")

    File.mkdir_p!(workspace)
    assert {"", 0} = System.cmd("mkfifo", [release_fifo])
    {:ok, release} = File.open(release_fifo, [:read, :write])

    descendant_command = """
    trap '' TERM
    printf '%s\n' "$$" > #{SymphonyElixir.Shell.escape(descendant_pid_file)}
    IFS= read -r _ < #{SymphonyElixir.Shell.escape(release_fifo)}
    printf survived > #{SymphonyElixir.Shell.escape(descendant_marker)}
    """

    hook_command = """
    trap '' TERM
    printf '%s\n' "$$" > #{SymphonyElixir.Shell.escape(leader_pid_file)}
    sh -c #{SymphonyElixir.Shell.escape(descendant_command)} &
    wait "$!"
    """

    hooks = %{
      "after_create" => nil,
      "after_run" => nil,
      "before_remove" => hook_command,
      "before_run" => nil,
      "timeout_ms" => 250
    }

    context = context(root, "alpha", "SID-TIMEOUT-GROUP", hooks: hooks, worker_host: "worker")
    parent = self()

    on_exit(fn ->
      File.close(release)

      case SymphonyElixir.TestSupport.read_pid(leader_pid_file) do
        nil ->
          :ok

        leader_pid ->
          System.cmd("kill", ["-KILL", "-#{leader_pid}"], stderr_to_stdout: true)
      end
    end)

    runner = fn _host, script, timeout_ms ->
      nonce = remote_marker_nonce(script)
      send(parent, {:remote_deadline, timeout_ms})
      send(parent, {:remote_shell_script, script})
      {output, status} = result = System.cmd("/bin/sh", ["-c", script], stderr_to_stdout: true)
      send(parent, {:remote_shell_result, output, status, nonce})
      result
    end

    assert {:error, :workspace_remote_timeout} =
             Workspace.remove(context, ssh_runner: runner)

    assert_received {:remote_deadline, 6_250}
    assert_received {:remote_shell_script, script}
    assert script =~ "kill -TERM -- \"-$hook_pid\""
    assert script =~ "kill -KILL -- \"-$hook_pid\""
    refute script =~ "while kill -0 -- \"-$hook_pid\""
    assert_received {:remote_shell_result, output, 72, nonce}

    canonical_marker =
      "__SYMPHONY_CONTEXT_WORKSPACE__\t#{nonce}\t#{root}\t#{workspace}\ttimeout"

    assert output
           |> String.split("\n", trim: true)
           |> Enum.filter(&String.starts_with?(&1, "__SYMPHONY_CONTEXT_WORKSPACE__\t")) ==
             [canonical_marker]

    shell_tmp_dir =
      case System.get_env("TMPDIR") do
        value when is_binary(value) and value != "" -> value
        _unset -> "/tmp"
      end

    assert Path.wildcard(Path.join(shell_tmp_dir, ".symphony-hook-#{nonce}-*")) == []

    leader_pid = SymphonyElixir.TestSupport.read_pid(leader_pid_file)
    descendant_pid = SymphonyElixir.TestSupport.read_pid(descendant_pid_file)
    assert is_integer(leader_pid)
    assert is_integer(descendant_pid)

    assert :ok = IO.write(release, "release\n")

    assert :stopped =
             SymphonyElixir.TestSupport.eventually(fn ->
               if SymphonyElixir.TestSupport.os_pid_alive?(leader_pid),
                 do: nil,
                 else: :stopped
             end)

    assert :stopped =
             SymphonyElixir.TestSupport.eventually(fn ->
               if process_capable_of_mutating?(descendant_pid),
                 do: nil,
                 else: :stopped
             end)

    refute File.exists?(descendant_marker)
    assert File.dir?(workspace)
  end

  @tag :tmp_dir
  test "remote adapter timeout remains fixed after synchronous script execution", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "remote-root")
    context = context(root, "alpha", "SID-ADAPTER-TIMEOUT", worker_host: "worker")
    parent = self()

    runner = fn host, script, timeout_ms ->
      result = run_generated_shell(host, script, timeout_ms)
      send(parent, {:adapter_script_result, result})
      {:error, :timeout}
    end

    assert {:error, :workspace_remote_timeout} =
             Workspace.create_for_issue(context, ssh_runner: runner)

    assert_received {:adapter_script_result, {_output, 0}}
    assert File.dir?(context.workspace_path)
  end

  @tag :tmp_dir
  test "remote hook script preserves fast success", %{tmp_dir: tmp_dir} do
    marker = Path.join(tmp_dir, "fast-hook")

    hooks = %{
      "after_create" => nil,
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => "printf success > #{SymphonyElixir.Shell.escape(marker)}",
      "timeout_ms" => 1_000
    }

    context =
      context(Path.join(tmp_dir, "remote-root"), "alpha", "SID-FAST",
        hooks: hooks,
        worker_host: "worker"
      )

    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}
    runner = &run_generated_shell/3

    assert {:ok, workspace} = Workspace.create_for_issue(context, ssh_runner: runner)
    assert workspace == context.workspace_path

    assert :ok = Workspace.run_before_run_hook(context, issue, ssh_runner: runner)
    assert File.read!(marker) == "success"
  end

  @tag :tmp_dir
  test "remote hook script preserves nonzero hook failure", %{tmp_dir: tmp_dir} do
    hooks = %{
      "after_create" => nil,
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => "exit 23",
      "timeout_ms" => 1_000
    }

    context =
      context(Path.join(tmp_dir, "remote-root"), "alpha", "SID-FAILED",
        hooks: hooks,
        worker_host: "worker"
      )

    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}
    runner = &run_generated_shell/3

    assert {:ok, workspace} = Workspace.create_for_issue(context, ssh_runner: runner)
    assert workspace == context.workspace_path

    assert {:error, :workspace_hook_failed} =
             Workspace.run_before_run_hook(context, issue, ssh_runner: runner)
  end

  @tag :tmp_dir
  test "remote after-create timeout returns the fixed timeout error", %{tmp_dir: tmp_dir} do
    pid_file = Path.join(tmp_dir, "after-create.pid")

    hooks = %{
      "after_create" => resistant_hook_command(pid_file),
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => nil,
      "timeout_ms" => 100
    }

    context =
      context(Path.join(tmp_dir, "remote-root"), "alpha", "SID-CREATE-TIMEOUT",
        hooks: hooks,
        worker_host: "worker"
      )

    parent = self()
    on_exit(fn -> kill_test_process(pid_file) end)

    runner = fn host, script, timeout_ms ->
      send(parent, {:create_deadline, timeout_ms})
      run_generated_shell(host, script, timeout_ms)
    end

    assert {:error, :workspace_remote_timeout} =
             Workspace.create_for_issue(context, ssh_runner: runner)

    assert_received {:create_deadline, 6_100}
  end

  @tag :tmp_dir
  test "remote before-run timeout returns the fixed timeout error", %{tmp_dir: tmp_dir} do
    pid_file = Path.join(tmp_dir, "before-run.pid")

    hooks = %{
      "after_create" => nil,
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => resistant_hook_command(pid_file),
      "timeout_ms" => 100
    }

    context =
      context(Path.join(tmp_dir, "remote-root"), "alpha", "SID-BEFORE-TIMEOUT",
        hooks: hooks,
        worker_host: "worker"
      )

    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}
    parent = self()
    on_exit(fn -> kill_test_process(pid_file) end)

    runner = fn host, script, timeout_ms ->
      send(parent, {:before_run_deadline, timeout_ms})
      run_generated_shell(host, script, timeout_ms)
    end

    assert {:ok, workspace} = Workspace.create_for_issue(context, ssh_runner: runner)
    assert workspace == context.workspace_path

    assert {:error, :workspace_remote_timeout} =
             Workspace.run_before_run_hook(context, issue, ssh_runner: runner)

    assert_received {:before_run_deadline, 6_100}
    assert_received {:before_run_deadline, 6_100}
  end

  @tag :tmp_dir
  test "remote after-run timeout returns the fixed timeout error", %{tmp_dir: tmp_dir} do
    pid_file = Path.join(tmp_dir, "after-run.pid")

    hooks = %{
      "after_create" => nil,
      "after_run" => resistant_hook_command(pid_file),
      "before_remove" => nil,
      "before_run" => nil,
      "timeout_ms" => 100
    }

    context =
      context(Path.join(tmp_dir, "remote-root"), "alpha", "SID-AFTER-TIMEOUT",
        hooks: hooks,
        worker_host: "worker"
      )

    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}
    parent = self()
    on_exit(fn -> kill_test_process(pid_file) end)

    runner = fn host, script, timeout_ms ->
      send(parent, {:after_run_deadline, timeout_ms})
      run_generated_shell(host, script, timeout_ms)
    end

    assert {:ok, workspace} = Workspace.create_for_issue(context, ssh_runner: runner)
    assert workspace == context.workspace_path

    assert {:error, :workspace_remote_timeout} =
             Workspace.run_after_run_hook(context, issue, ssh_runner: runner)

    assert_received {:after_run_deadline, 6_100}
    assert_received {:after_run_deadline, 6_100}
  end

  @tag :tmp_dir
  test "remote context creates an absent validated root in its single SSH operation", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "remote-root")

    hooks = %{
      "after_create" => "printf 'created\\n' > after-create.log",
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => nil,
      "timeout_ms" => 1_000
    }

    context =
      context(root, "alpha", "SID-FIRST", hooks: hooks, worker_host: "worker.example")

    parent = self()

    shell_runner = fn host, script, timeout_ms ->
      send(parent, {:first_use_ssh, host, script, timeout_ms})
      System.cmd("sh", ["-c", script], stderr_to_stdout: true)
    end

    refute File.exists?(root)
    assert {:ok, workspace} = Workspace.create_for_issue(context, ssh_runner: shell_runner)
    assert File.dir?(root)
    assert File.read!(Path.join(workspace, "after-create.log")) == "created\n"

    assert_receive {:first_use_ssh, "worker.example", script, 7_000}
    assert script =~ "root_parent"
    assert script =~ "mkdir -- \"$root_candidate\""
    refute script =~ "mkdir -p"
    refute_receive {:first_use_ssh, _host, _script, _timeout_ms}
  end

  @tag :tmp_dir
  test "remote context rejects absent roots with missing malformed or symlinked authority", %{
    tmp_dir: tmp_dir
  } do
    outside = Path.join(tmp_dir, "outside")
    File.mkdir!(outside)

    symlinked_parent = Path.join(tmp_dir, "symlinked-parent")
    File.ln_s!(outside, symlinked_parent)

    malformed_parent = Path.join(tmp_dir, "malformed-parent")
    File.write!(malformed_parent, "unchanged")

    linked_root = Path.join(tmp_dir, "linked-root")
    File.ln_s!(outside, linked_root)

    malformed_root = Path.join(tmp_dir, "malformed-root")
    File.write!(malformed_root, "unchanged")

    hostile_roots = [
      Path.join([tmp_dir, "missing-parent", "root"]),
      Path.join(symlinked_parent, "root"),
      Path.join(malformed_parent, "root"),
      linked_root,
      malformed_root
    ]

    shell_runner = fn _host, script, _timeout_ms ->
      System.cmd("sh", ["-c", script], stderr_to_stdout: true)
    end

    for root <- hostile_roots do
      hostile = context(root, "alpha", "SID-HOSTILE", worker_host: "worker.example")

      assert {:error, :workspace_remote_output_invalid} =
               Workspace.create_for_issue(hostile, ssh_runner: shell_runner)
    end

    assert {:ok, []} = File.ls(outside)
    assert File.read!(malformed_parent) == "unchanged"
    assert File.read!(malformed_root) == "unchanged"
  end

  @tag :tmp_dir
  test "atomic remote script rejects root target and issue symlinks before effects", %{
    tmp_dir: tmp_dir
  } do
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(outside)

    root_link = Path.join(tmp_dir, "root-link")
    File.ln_s!(outside, root_link)

    target_root = Path.join(tmp_dir, "target-root")
    File.mkdir_p!(target_root)
    File.ln_s!(outside, Path.join(target_root, "alpha"))

    issue_root = Path.join(tmp_dir, "issue-root")
    File.mkdir_p!(Path.join(issue_root, "alpha"))
    File.ln_s!(outside, Path.join([issue_root, "alpha", "SID-410"]))

    contexts = [
      context(root_link, "alpha", "SID-410", worker_host: "worker.example"),
      context(target_root, "alpha", "SID-410", worker_host: "worker.example"),
      context(issue_root, "alpha", "SID-410", worker_host: "worker.example")
    ]

    shell_runner = fn _host, script, _timeout_ms ->
      System.cmd("sh", ["-c", script], stderr_to_stdout: true)
    end

    for context <- contexts do
      assert {:error, :workspace_remote_output_invalid} =
               Workspace.create_for_issue(context, ssh_runner: shell_runner)
    end

    assert {:ok, []} = File.ls(outside)
  end

  test "remote after-run ignores hook status after validated marker" do
    hooks = %{
      "after_create" => nil,
      "after_run" => "after-run",
      "before_remove" => nil,
      "before_run" => nil,
      "timeout_ms" => 1_000
    }

    context =
      context("/remote/root-a", "alpha", "SID-410",
        hooks: hooks,
        worker_host: "worker.example"
      )

    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}

    ssh_runner = fn _host, script, _timeout_ms ->
      {context_remote_marker(
         script,
         "/remote/root-a",
         "/remote/root-a/alpha/SID-410",
         "hooked"
       ), 23}
    end

    assert :ok =
             Workspace.run_after_run_hook(context, issue, ssh_runner: ssh_runner)
  end

  @tag :tmp_dir
  test "context workspace validates option and pinned authority shapes", %{tmp_dir: tmp_dir} do
    valid = context(Path.join(tmp_dir, "worktrees"), "alpha", "SID-410")

    duplicate_runner_options = [
      command_runner: fn _, _, _ -> {"", 0} end,
      command_runner: fn _, _, _ -> {"", 0} end
    ]

    assert {:error, :invalid_workspace_options} =
             Workspace.create_for_issue(valid, duplicate_runner_options)

    invalid_contexts = [
      %{valid | target: nil},
      %{valid | target: %{valid.target | target_id: :alpha}},
      %{
        valid
        | target: %{
            valid.target
            | worktree_policy: %{valid.target.worktree_policy | "root" => nil}
          }
      },
      %{
        valid
        | target: %{
            valid.target
            | worktree_policy: %{valid.target.worktree_policy | "hooks" => nil}
          }
      },
      %{
        valid
        | target: %{
            valid.target
            | worktree_policy: %{
                valid.target.worktree_policy
                | "hooks" => %{
                    "after_create" => nil,
                    "after_run" => nil,
                    "before_remove" => nil,
                    "before_run" => nil,
                    "timeout_ms" => 0
                  }
              }
          }
      }
    ]

    for invalid <- invalid_contexts do
      assert {:error, :invalid_workspace_context} = Workspace.create_for_issue(invalid, [])
    end

    scoped_root = Path.join(tmp_dir, "alpha")
    scoped = context(scoped_root, "alpha", "SID-410")
    scoped = %{scoped | workspace_path: Path.join(scoped_root, "SID-410")}

    assert {:ok, workspace} = Workspace.create_for_issue(scoped)
    assert workspace == scoped.workspace_path
  end

  @tag :tmp_dir
  test "context APIs reject non-list and unknown options before effects", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "worktrees")

    hooks = %{
      "after_create" => "printf created > created.log",
      "after_run" => "printf after > after.log",
      "before_remove" => "printf removed > removed.log",
      "before_run" => "printf before > before.log",
      "timeout_ms" => 1_000
    }

    context = context(root, "alpha", "SID-OPTIONS", hooks: hooks)
    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}
    invalid_options = [:invalid_options, %{}, [{:command_runner, nil} | :invalid_tail]]

    for opts <- invalid_options do
      assert {:error, :invalid_workspace_options} = Workspace.create_for_issue(context, opts)
      assert {:error, :invalid_workspace_options} = Workspace.remove(context, opts)

      assert {:error, :invalid_workspace_options} =
               Workspace.run_before_run_hook(context, issue, opts)

      assert {:error, :invalid_workspace_options} =
               Workspace.run_after_run_hook(context, issue, opts)

      assert {:error, :invalid_workspace_options} =
               Workspace.remove_issue_workspaces(
                 context.target,
                 context.issue_identifier,
                 nil,
                 opts
               )
    end

    unknown_options = [unknown: fn -> send(self(), :unexpected_callback) end]

    assert {:error, :invalid_workspace_options} =
             Workspace.create_for_issue(context, unknown_options)

    assert {:error, :invalid_workspace_options} = Workspace.remove(context, unknown_options)

    assert {:error, :invalid_workspace_options} =
             Workspace.run_before_run_hook(context, issue, unknown_options)

    assert {:error, :invalid_workspace_options} =
             Workspace.run_after_run_hook(context, issue, unknown_options)

    assert {:error, :invalid_workspace_options} =
             Workspace.remove_issue_workspaces(
               context.target,
               context.issue_identifier,
               nil,
               unknown_options
             )

    refute File.exists?(root)
    refute_receive :unexpected_callback
  end

  @tag :tmp_dir
  test "local context creation reuses directories and replaces stale files", %{tmp_dir: tmp_dir} do
    hooks = %{
      "after_create" => "bootstrap",
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => nil,
      "timeout_ms" => 1_000
    }

    reused = context(Path.join(tmp_dir, "reuse"), "alpha", "SID-REUSE", hooks: hooks)
    parent = self()

    runner = fn command, workspace, timeout_ms ->
      send(parent, {:bootstrap, command, workspace, timeout_ms})
      {:ok, {"", 0}}
    end

    assert {:ok, reused_path} = Workspace.create_for_issue(reused, command_runner: runner)
    assert_receive {:bootstrap, "bootstrap", ^reused_path, 1_000}
    assert {:ok, ^reused_path} = Workspace.create_for_issue(reused, command_runner: runner)
    refute_receive {:bootstrap, _, _, _}

    stale = context(Path.join(tmp_dir, "stale"), "alpha", "SID-STALE")
    File.mkdir_p!(Path.dirname(stale.workspace_path))
    File.write!(stale.workspace_path, "stale")

    assert {:ok, stale_path} = Workspace.create_for_issue(stale)
    assert stale_path == stale.workspace_path
    assert File.dir?(stale_path)
  end

  @tag :tmp_dir
  test "local context creation returns fixed filesystem errors", %{tmp_dir: tmp_dir} do
    create_context = context(Path.join(tmp_dir, "create"), "alpha", "SID-CREATE")
    create_parent = Path.dirname(create_context.workspace_path)
    File.mkdir_p!(create_parent)
    File.chmod!(create_parent, 0o500)

    assert {:error, :workspace_create_failed} = Workspace.create_for_issue(create_context)
    File.chmod!(create_parent, 0o700)

    replace_context = context(Path.join(tmp_dir, "replace"), "alpha", "SID-REPLACE")
    replace_parent = Path.dirname(replace_context.workspace_path)
    File.mkdir_p!(replace_parent)
    File.write!(replace_context.workspace_path, "stale")
    File.chmod!(replace_parent, 0o500)

    assert {:error, :workspace_create_failed} = Workspace.create_for_issue(replace_context)
    File.chmod!(replace_parent, 0o700)

    inaccessible_root = Path.join(tmp_dir, "inaccessible")
    File.mkdir!(inaccessible_root)
    File.chmod!(inaccessible_root, 0o000)

    assert {:error, :invalid_workspace_context} =
             inaccessible_root
             |> context("alpha", "SID-INACCESSIBLE")
             |> Workspace.create_for_issue()

    File.chmod!(inaccessible_root, 0o700)
  end

  test "remote context normalizes adapter results markers and statuses" do
    context = context("/remote/root", "alpha", "SID-410", worker_host: "worker.example")
    workspace = context.workspace_path

    assert {:ok, ^workspace} =
             Workspace.create_for_issue(
               context,
               ssh_runner: fn _, script, _ ->
                 {:ok, {context_remote_marker(script, "/remote/root", workspace, "created"), 0}}
               end
             )

    assert {:error, :workspace_remote_dependency_failed} =
             Workspace.create_for_issue(context, ssh_runner: fn _, _, _ -> :invalid end)

    assert {:error, :workspace_remote_dependency_failed} =
             Workspace.create_for_issue(context, ssh_runner: fn _, _, _ -> {nil, 0} end)

    assert {:error, :workspace_hook_failed} =
             Workspace.create_for_issue(
               context,
               ssh_runner: fn _, script, _ ->
                 {context_remote_marker(script, "/remote/root", workspace, "created"), 71}
               end
             )

    assert {:error, :workspace_remote_operation_failed} =
             Workspace.create_for_issue(
               context,
               ssh_runner: fn _, script, _ ->
                 {context_remote_marker(script, "/remote/root", workspace, "created"), 23}
               end
             )
  end

  test "remote context hook and removal require canonical marker outcomes" do
    hooks = %{
      "after_create" => nil,
      "after_run" => nil,
      "before_remove" => nil,
      "before_run" => "before-run",
      "timeout_ms" => 1_000
    }

    context =
      context("/remote/root", "alpha", "SID-410",
        hooks: hooks,
        worker_host: "worker.example"
      )

    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}

    assert {:error, :workspace_remote_output_invalid} =
             Workspace.run_before_run_hook(
               context,
               issue,
               ssh_runner: fn _, script, _ ->
                 {context_remote_marker(
                    script,
                    "/remote/root",
                    context.workspace_path,
                    "created"
                  ), 0}
               end
             )

    assert {:error, :workspace_remote_dependency_failed} =
             Workspace.run_before_run_hook(
               context,
               issue,
               ssh_runner: fn _, _, _ -> :invalid end
             )

    assert {:error, :workspace_remote_output_invalid} =
             Workspace.remove(
               context,
               ssh_runner: fn _, script, _ ->
                 {context_remote_marker(
                    script,
                    "/remote/root",
                    context.workspace_path,
                    "created"
                  ), 0}
               end
             )

    assert {:error, :workspace_remote_operation_failed} =
             Workspace.remove(
               context,
               ssh_runner: fn _, script, _ ->
                 {context_remote_marker(
                    script,
                    "/remote/root",
                    context.workspace_path,
                    "deleted"
                  ), 23}
               end
             )
  end

  @tag :tmp_dir
  test "remote context reports deterministic adapter and hook timeouts", %{tmp_dir: tmp_dir} do
    parent = self()

    remote =
      context("/remote/root", "alpha", "SID-TIMEOUT",
        hooks: %{
          "after_create" => nil,
          "after_run" => nil,
          "before_remove" => nil,
          "before_run" => nil,
          "timeout_ms" => 10
        },
        worker_host: "worker.example"
      )

    blocked_ssh = fn _, _, _ ->
      send(parent, :ssh_started)
      receive do: (:never -> :ok)
    end

    assert {:error, :workspace_remote_timeout} =
             Workspace.create_for_issue(remote, ssh_runner: blocked_ssh)

    assert_received :ssh_started

    local =
      context(Path.join(tmp_dir, "local-timeout"), "alpha", "SID-TIMEOUT",
        hooks: %{
          "after_create" => "blocked",
          "after_run" => nil,
          "before_remove" => nil,
          "before_run" => nil,
          "timeout_ms" => 10
        }
      )

    blocked_command = fn _, _, _ ->
      send(parent, :command_started)
      receive do: (:never -> :ok)
    end

    assert {:error, :workspace_hook_timeout} =
             Workspace.create_for_issue(local, command_runner: blocked_command)

    assert_received :command_started
    File.rm_rf(local.target.worktree_policy["root"])
  end

  @tag :tmp_dir
  test "context default SSH adapter accepts its exact canonical marker", %{tmp_dir: tmp_dir} do
    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    context =
      context(Path.join(tmp_dir, "remote-root"), "alpha", "SID-SSH", worker_host: "worker.example")

    fake_ssh = Path.join(tmp_dir, "ssh")

    File.write!(
      fake_ssh,
      "#!/bin/sh\nfor remote_command do :; done\nexec /bin/sh -c \"$remote_command\"\n"
    )

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", tmp_dir <> ":" <> (previous_path || ""))

    assert {:ok, workspace} = Workspace.create_for_issue(context)
    assert workspace == context.workspace_path
  end

  @tag :tmp_dir
  test "local context removal reports filesystem failures", %{tmp_dir: tmp_dir} do
    context = context(Path.join(tmp_dir, "worktrees"), "alpha", "SID-REMOVE")
    File.mkdir_p!(context.workspace_path)
    parent = Path.dirname(context.workspace_path)
    File.chmod!(parent, 0o500)

    assert {:error, :workspace_remove_failed} = Workspace.remove(context)

    assert {:error, :workspace_remove_failed} =
             Workspace.remove_issue_workspaces(
               context.target,
               context.issue_identifier,
               nil
             )

    File.chmod!(parent, 0o700)
  end

  @tag :tmp_dir
  test "target cleanup revalidates hook mutations and ignores hook status", %{tmp_dir: tmp_dir} do
    outside = Path.join(tmp_dir, "outside")
    File.mkdir!(outside)

    hooks = %{
      "after_create" => nil,
      "after_run" => nil,
      "before_remove" => "before-remove",
      "before_run" => nil,
      "timeout_ms" => 1_000
    }

    mutated =
      context(Path.join(tmp_dir, "mutated"), "alpha", "SID-MUTATED", hooks: hooks)

    File.mkdir_p!(mutated.workspace_path)

    mutating_runner = fn _, workspace, _ ->
      File.rm_rf!(workspace)
      File.ln_s!(outside, workspace)
      {"", 0}
    end

    assert {:error, :invalid_workspace_context} =
             Workspace.remove_issue_workspaces(
               mutated.target,
               mutated.issue_identifier,
               nil,
               command_runner: mutating_runner
             )

    assert File.dir?(outside)
    File.rm!(mutated.workspace_path)

    ignored =
      context(Path.join(tmp_dir, "ignored"), "alpha", "SID-IGNORED", hooks: hooks)

    File.mkdir_p!(ignored.workspace_path)

    assert :ok =
             Workspace.remove_issue_workspaces(
               ignored.target,
               ignored.issue_identifier,
               nil,
               command_runner: fn _, _, _ -> {"secret output", 23} end
             )

    refute File.exists?(ignored.workspace_path)
  end

  @tag :tmp_dir
  test "context hook wrappers validate issue authority and normalize invalid runners", %{
    tmp_dir: tmp_dir
  } do
    context = context(Path.join(tmp_dir, "worktrees"), "alpha", "SID-HOOKS")
    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}

    assert {:error, :invalid_workspace_issue} =
             Workspace.run_before_run_hook(context, %{issue | id: "forged"})

    assert :ok = Workspace.run_before_run_hook(context, issue)
    assert :ok = Workspace.run_after_run_hook(context, issue)

    invalid_runner_context =
      context(Path.join(tmp_dir, "invalid-runner"), "alpha", "SID-INVALID",
        hooks: %{
          "after_create" => "invalid",
          "after_run" => nil,
          "before_remove" => nil,
          "before_run" => nil,
          "timeout_ms" => 1_000
        }
      )

    assert {:error, :workspace_hook_dependency_failed} =
             Workspace.create_for_issue(
               invalid_runner_context,
               command_runner: fn _, _, _ -> :invalid end
             )
  end

  defp remote_marker_nonce(script) do
    [nonce] = Regex.run(~r/^marker_nonce='([0-9a-f]{32})'$/m, script, capture: :all_but_first)
    nonce
  end

  defp context_remote_marker(script, root, workspace, status) do
    "__SYMPHONY_CONTEXT_WORKSPACE__\t#{remote_marker_nonce(script)}\t#{root}\t#{workspace}\t#{status}\n"
  end

  defp run_generated_shell(_host, script, _timeout_ms) do
    System.cmd("/bin/sh", ["-c", script], stderr_to_stdout: true)
  end

  defp resistant_hook_command(pid_file) do
    """
    trap '' TERM
    printf '%s\n' "$$" > #{SymphonyElixir.Shell.escape(pid_file)}
    while :; do :; done
    """
  end

  defp kill_test_process(pid_file) do
    case SymphonyElixir.TestSupport.read_pid(pid_file) do
      nil -> :ok
      pid -> System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end
  end

  defp process_capable_of_mutating?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        case Regex.run(~r/^\d+\s+\(.*\)\s+([A-Za-z])\s/, stat, capture: :all_but_first) do
          ["Z"] -> false
          _state -> SymphonyElixir.TestSupport.os_pid_alive?(pid)
        end

      {:error, _reason} ->
        SymphonyElixir.TestSupport.os_pid_alive?(pid)
    end
  end

  defp context(root, target_id, issue_identifier, opts \\ []) do
    hooks =
      Keyword.get(opts, :hooks, %{
        "after_create" => nil,
        "after_run" => nil,
        "before_remove" => nil,
        "before_run" => nil,
        "timeout_ms" => 1_000
      })

    worker_host = Keyword.get(opts, :worker_host)
    workspace_path = Path.join([root, target_id, issue_identifier])

    target = %TargetContext{
      target_id: target_id,
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: @hash,
      policy_hash: @hash,
      repo_manifest_hash: @hash,
      repo_policy: %{},
      tracker_connection: %{},
      run_target: %{},
      worktree_policy: %{"root" => root, "strategy" => "per_issue", "hooks" => hooks},
      runner_policy: %{},
      effective_checks: %{},
      external_side_effect_gates: %{},
      capacity_limits: %{},
      budget_limits: %{}
    }

    %ExecutionContext{
      target: target,
      issue_id: "issue-410",
      issue_identifier: issue_identifier,
      workspace_path: workspace_path,
      runner_name: "codex",
      runner_config: %{"command" => ["codex", "app-server"], "kind" => "codex_app_server"},
      policy: %{"sandbox" => "restricted"},
      role: :implementation,
      execution_profile: %{
        name: "implementation",
        model: "context-model",
        reasoning_effort: "medium",
        budget: "standard",
        timeout_ms: 1_000,
        max_retries: 0,
        command: nil
      },
      timeout_ms: 1_000,
      max_retries: 0,
      worker_host: worker_host
    }
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
