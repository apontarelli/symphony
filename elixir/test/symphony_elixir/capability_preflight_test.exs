defmodule SymphonyElixir.CapabilityPreflightTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CapabilityPreflight

  test "passes without probes when no trusted-local capabilities are required" do
    result =
      CapabilityPreflight.run("/tmp/workspace", %{},
        tcp_probe: fn -> flunk("TCP probe should not run") end,
        runner: fn _context -> flunk("command probe should not run") end
      )

    assert result == %{status: :passed, failures: []}
  end

  test "profile capabilities replace manifest capabilities" do
    result =
      CapabilityPreflight.run(
        "/tmp/workspace",
        %{
          "capabilities" => %{"required" => []},
          "manifest" => %{"capabilities" => %{"required" => ["localhost_tcp", "git_metadata", "github_pr"]}}
        },
        tcp_probe: fn -> flunk("manifest capabilities should not run when profile capabilities are explicit") end,
        runner: fn _context -> flunk("manifest capabilities should not run when profile capabilities are explicit") end
      )

    assert result == %{status: :passed, failures: []}
  end

  test "detects localhost TCP denial before Mix PubSub validation" do
    result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["localhost_tcp"]}}, tcp_probe: fn -> {:error, :eperm} end)

    assert result.status == :blocked
    assert [%{reason: :sandbox_tcp_denied, details: ":eperm"}] = result.failures
    assert CapabilityPreflight.blocker(result).reason == "sandbox_tcp_denied"
  end

  test "passes explicit localhost TCP probe success" do
    result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["localhost_tcp"]}}, tcp_probe: fn -> :ok end)

    assert result == %{status: :passed, failures: []}
  end

  test "detects localhost TCP denial from resolved default sandbox policy" do
    result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["localhost_tcp"]}},
        tcp_listen: fn _port, _opts -> flunk("TCP listen should not run when resolved turn sandbox denies network access") end
      )

    assert [%{reason: :sandbox_tcp_denied, details: details}] = result.failures
    assert details =~ "networkAccess"
  end

  test "reports invalid localhost TCP sandbox policy configuration" do
    invalid_explicit =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["localhost_tcp"]}}, turn_sandbox_policy: "bad")

    invalid_resolved =
      CapabilityPreflight.run(
        "/tmp/workspace",
        %{"capabilities" => %{"required" => ["localhost_tcp"]}, "runners" => "bad"}
      )

    assert [%{reason: :sandbox_tcp_denied, details: explicit_details}] = invalid_explicit.failures
    assert explicit_details =~ "invalid_turn_sandbox_policy"
    assert [%{reason: :sandbox_tcp_denied, details: resolved_details}] = invalid_resolved.failures
    assert resolved_details =~ "invalid_policy_runners"
  end

  test "detects localhost TCP denial from turn sandbox policy" do
    result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["localhost_tcp"]}},
        turn_sandbox_policy: %{"type" => "workspaceWrite", "networkAccess" => false},
        tcp_listen: fn _port, _opts -> flunk("TCP listen should not run when the turn sandbox denies network access") end
      )

    assert result.status == :blocked
    assert [%{reason: :sandbox_tcp_denied, details: details}] = result.failures
    assert details =~ "networkAccess"
  end

  test "runs localhost TCP command probe on the selected worker host" do
    result =
      CapabilityPreflight.run("/remote/workspace", %{"capabilities" => %{"required" => ["localhost_tcp"]}},
        worker_host: "worker.example",
        turn_sandbox_policy: tcp_enabled_policy(),
        runner: fn %{step: :localhost_tcp, worker_host: worker_host, command: command} ->
          assert worker_host == "worker.example"
          assert command =~ "elixir -e"
          {:ok, %{status: 1, output: ":eperm"}}
        end,
        tcp_listen: fn _port, _opts -> flunk("controller TCP probe should not run for worker-host probes") end
      )

    assert result.status == :blocked
    assert [%{reason: :sandbox_tcp_denied, details: ":eperm"}] = result.failures
  end

  test "reports worker localhost TCP runner errors" do
    result =
      CapabilityPreflight.run("/remote/workspace", %{"capabilities" => %{"required" => ["localhost_tcp"]}},
        worker_host: "worker.example",
        turn_sandbox_policy: tcp_enabled_policy(),
        runner: fn %{step: :localhost_tcp} -> {:error, :worker_probe_failed} end
      )

    assert [%{reason: :sandbox_tcp_denied, details: ":worker_probe_failed"}] = result.failures
  end

  test "detects Git metadata write or fetch denial with VCS-aware probes" do
    result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["git_metadata"]}},
        runner: fn %{step: :git_metadata, command: command} ->
          assert command =~ "git fetch --dry-run"
          assert command =~ "jj root"
          {:ok, %{status: 1, output: "cannot open .git/FETCH_HEAD: Operation not permitted"}}
        end
      )

    assert result.status == :blocked
    assert [%{reason: :git_metadata_denied, details: details}] = result.failures
    assert details =~ ".git/FETCH_HEAD"
    assert CapabilityPreflight.blocker(result).required_action =~ "write Git metadata"
  end

  test "detects missing GitHub publish capability when PR handoff is required" do
    policy = publish_policy(%{"capabilities" => %{"required" => ["github_pr"]}})

    result =
      CapabilityPreflight.run("/tmp/workspace", policy,
        runner: fn %{step: :github_publish, command: command} ->
          assert command =~ "gh api"
          assert command =~ "permissions.push"
          {:ok, %{status: 1, output: "gh auth failed"}}
        end
      )

    assert result.status == :blocked
    assert [%{reason: :github_publish_unavailable, details: "gh auth failed"}] = result.failures
  end

  test "passes all required probes when capabilities are available" do
    policy = publish_policy(%{"capabilities" => %{"required" => ["localhost_tcp", "git_metadata", "github_pr"]}})

    result =
      CapabilityPreflight.run("/tmp/workspace", policy,
        turn_sandbox_policy: tcp_enabled_policy(),
        runner: fn %{step: step} when step in [:localhost_tcp, :git_metadata, :github_publish] ->
          {:ok, %{status: 0, output: ""}}
        end
      )

    assert result == %{status: :passed, failures: []}
    assert CapabilityPreflight.blocker(result) == nil
  end

  test "supports atom-keyed manifest capability requirements and default options" do
    result =
      CapabilityPreflight.run(
        "/tmp/workspace",
        %{manifest: %{capabilities: %{required: [" local_tcp "]}}},
        turn_sandbox_policy: tcp_enabled_policy(),
        tcp_listen: fn _port, _opts -> {:ok, :fake_socket} end,
        tcp_close: fn :fake_socket -> :ok end
      )

    assert result == %{status: :passed, failures: []}
  end

  test "detects TCP denial from default probe dependencies" do
    result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["localhost_tcp"]}},
        turn_sandbox_policy: tcp_enabled_policy(),
        tcp_listen: fn _port, _opts -> {:error, :eperm} end,
        tcp_close: fn _socket -> flunk("TCP close should not run after listen failure") end
      )

    assert result.status == :blocked
    assert [%{reason: :sandbox_tcp_denied, details: ":eperm"}] = result.failures
  end

  test "normalizes runner errors invalid runner results timeouts and exits" do
    error_result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["git_metadata"]}}, runner: fn _context -> {:error, :runner_failed} end)

    invalid_result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["git_metadata"]}}, runner: fn _context -> :unexpected_result end)

    timeout_result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["git_metadata"]}},
        runner: fn _context -> Process.sleep(:infinity) end,
        timeout_ms: 5
      )

    exit_result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["git_metadata"]}}, runner: fn _context -> raise "runner boom" end)

    throw_result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["git_metadata"]}}, runner: fn _context -> throw(:runner_threw) end)

    assert [%{reason: :git_metadata_denied, details: ":runner_failed"}] = error_result.failures
    assert [%{reason: :git_metadata_denied, details: invalid_details}] = invalid_result.failures
    assert invalid_details =~ "invalid_preflight_result"
    assert [%{reason: :git_metadata_denied, details: timeout_details}] = timeout_result.failures
    assert timeout_details =~ "capability_preflight_timeout"
    assert [%{reason: :git_metadata_denied, details: exit_details}] = exit_result.failures
    assert exit_details =~ "runner boom"
    assert [%{reason: :git_metadata_denied, details: throw_details}] = throw_result.failures
    assert throw_details =~ "runner_threw"
  end

  test "detects missing publish target and runner-level GitHub failure" do
    missing_target_result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["github_pr"]}}, runner: fn _context -> flunk("missing publish target should not run command probe") end)

    runner_error_result =
      CapabilityPreflight.run(
        "/tmp/workspace",
        publish_policy(%{"capabilities" => %{"required" => ["github_pr"]}}),
        runner: fn _context -> {:error, :gh_missing} end
      )

    assert [%{reason: :github_publish_unavailable, details: missing_details}] = missing_target_result.failures
    assert missing_details =~ "publish target is missing"
    assert [%{reason: :github_publish_unavailable, details: ":gh_missing"}] = runner_error_result.failures
  end

  test "blocker surfaces all failed capability reasons" do
    result =
      CapabilityPreflight.run(
        "/tmp/workspace",
        publish_policy(%{"capabilities" => %{"required" => ["localhost_tcp", "git_metadata", "github_pr"]}}),
        turn_sandbox_policy: %{"type" => "workspaceWrite", "networkAccess" => false},
        runner: fn
          %{step: :git_metadata} -> {:ok, %{status: 1, output: "git denied"}}
          %{step: :github_publish} -> {:ok, %{status: 1, output: "gh denied"}}
        end
      )

    assert Enum.map(result.failures, & &1.reason) == [
             :sandbox_tcp_denied,
             :git_metadata_denied,
             :github_publish_unavailable
           ]

    blocker = CapabilityPreflight.blocker(result)
    assert blocker.reason =~ "sandbox_tcp_denied"
    assert blocker.reason =~ "git_metadata_denied"
    assert blocker.reason =~ "github_publish_unavailable"
    assert blocker.required_action =~ "localhost TCP"
    assert blocker.required_action =~ "GitHub"
  end

  test "sanitizes empty and long command output details" do
    empty_output_result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["git_metadata"]}}, runner: fn _context -> {:ok, %{status: 1, output: "  \n"}} end)

    long_output = String.duplicate("x", 2_100)

    long_output_result =
      CapabilityPreflight.run("/tmp/workspace", %{"capabilities" => %{"required" => ["git_metadata"]}}, runner: fn _context -> {:ok, %{status: 1, output: long_output}} end)

    assert [%{details: nil}] = empty_output_result.failures
    assert [%{details: details}] = long_output_result.failures
    assert byte_size(details) == 2_048
  end

  test "local command runner reports command failures and cd errors" do
    git_failure_result =
      CapabilityPreflight.run(tmp_dir!("capability-preflight-local"), %{"capabilities" => %{"required" => ["git_metadata"]}})

    cd_failure_result =
      CapabilityPreflight.run("/tmp/symphony-missing-#{System.unique_integer([:positive])}", %{
        "capabilities" => %{"required" => ["git_metadata"]}
      })

    assert [%{reason: :git_metadata_denied}] = git_failure_result.failures
    assert [%{reason: :git_metadata_denied, details: cd_details}] = cd_failure_result.failures
    assert cd_details =~ "workspace_not_found"
  end

  test "ssh command runner returns command status and missing ssh errors" do
    previous_path = System.get_env("PATH")
    test_root = tmp_dir!("capability-preflight-ssh")

    try do
      fake_bin = Path.join(test_root, "bin")
      File.mkdir_p!(fake_bin)
      File.write!(Path.join(fake_bin, "ssh"), "#!/bin/sh\nprintf 'remote denied\\n'\nexit 7\n")
      File.chmod!(Path.join(fake_bin, "ssh"), 0o755)
      System.put_env("PATH", fake_bin)

      ssh_status_result =
        CapabilityPreflight.run("/remote/workspace", %{"capabilities" => %{"required" => ["git_metadata"]}}, worker_host: "worker.example")

      assert [%{reason: :git_metadata_denied, details: "remote denied"}] = ssh_status_result.failures

      System.put_env("PATH", "")

      ssh_missing_result =
        CapabilityPreflight.run("/remote/workspace", %{"capabilities" => %{"required" => ["git_metadata"]}}, worker_host: "worker.example")

      assert [%{reason: :git_metadata_denied, details: ":ssh_not_found"}] = ssh_missing_result.failures
    after
      restore_path(previous_path)
    end
  end

  defp publish_policy(extra) do
    Map.merge(
      %{
        "publish_target" => %{
          "repository" => "https://github.com/example/project",
          "github_repository" => "example/project",
          "pr_target" => "main"
        }
      },
      extra
    )
  end

  defp tcp_enabled_policy do
    %{"type" => "workspaceWrite", "networkAccess" => true}
  end

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end
