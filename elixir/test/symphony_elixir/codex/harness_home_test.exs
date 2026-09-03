defmodule SymphonyElixir.Codex.HarnessHomeAccessFailure do
  @behaviour Access

  defstruct [:mode, :secret]

  @impl Access
  def fetch(%__MODULE__{mode: :throw, secret: secret}, _key), do: throw(secret)
  def fetch(%__MODULE__{mode: :exit, secret: secret}, _key), do: exit(secret)

  @impl Access
  def get_and_update(_data, _key, _function), do: raise("not supported")

  @impl Access
  def pop(_data, _key), do: raise("not supported")
end

defmodule SymphonyElixir.Codex.HarnessHomeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.HarnessHome
  alias SymphonyElixir.{ExecutionContext, Shell, TargetContext}

  @hash "sha256:" <> String.duplicate("a", 64)

  @tag :tmp_dir
  test "context path accepts a root already scoped to its target", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "alpha")
    context = context(tmp_dir, root: root)

    assert {:ok, result} = HarnessHome.path(context)
    assert context.workspace_path == Path.join(root, "SID-410")
    assert result.path == Path.join([root, ".symphony", "codex_home"])
  end

  @tag :tmp_dir
  test "context path rejects malformed workspace and repository authority", %{tmp_dir: tmp_dir} do
    valid = context(tmp_dir)

    invalid_contexts = [
      %{valid | target: nil},
      %{valid | target: %{valid.target | worktree_policy: %{}}},
      %{
        valid
        | workspace_path: nil,
          target: %{
            valid.target
            | worktree_policy: %{
                "root" => nil,
                "strategy" => "per_issue",
                "hooks" => %{}
              }
          }
      },
      %{valid | target: %{valid.target | repo_policy: nil}},
      %{
        valid
        | target: %{
            valid.target
            | repo_policy: %{
                "manifest" => %{"harness" => %{"codex_home" => 42}},
                "manifest_source_dir" => Path.join(tmp_dir, "repo"),
                "workflow_module_resolution" => %{}
              }
          }
      }
    ]

    for invalid <- invalid_contexts do
      assert {:error, :invalid_harness_home_context} = HarnessHome.path(invalid)
    end
  end

  @tag :tmp_dir
  test "context local preparation mirrors operator auth", %{tmp_dir: tmp_dir} do
    assert {:ok, result} = tmp_dir |> context() |> HarnessHome.ensure_local()
    source = Path.expand("~/.codex/auth.json")
    destination = Path.join(result.path, "auth.json")

    if File.exists?(source) do
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(destination)
      assert File.read_link!(destination) == source
    else
      assert {:error, :enoent} = File.lstat(destination)
    end
  end

  @tag :tmp_dir
  test "context local and remote entry points enforce worker locality", %{tmp_dir: tmp_dir} do
    local = context(tmp_dir)
    remote = %{local | worker_host: "worker.example"}

    assert {:error, :harness_home_requires_local_context} = HarnessHome.ensure_local(remote)
    assert {:error, :harness_home_requires_remote_context} = HarnessHome.remote_prepare(local)
    assert {:error, :invalid_harness_home_context} = HarnessHome.remote_prepare(:invalid)
  end

  @tag :tmp_dir
  test "legacy local preparation returns its concrete filesystem error", %{tmp_dir: tmp_dir} do
    previous_home = System.get_env("SYMPHONY_CODEX_HOME")
    on_exit(fn -> restore_env("SYMPHONY_CODEX_HOME", previous_home) end)

    occupied = Path.join(tmp_dir, "occupied")
    File.write!(occupied, "not a directory")
    System.put_env("SYMPHONY_CODEX_HOME", occupied)

    assert {:error, {:codex_harness_home_failed, ^occupied, :enotdir}} =
             HarnessHome.ensure_local(Path.join(tmp_dir, "workspace"))
  end

  @tag :tmp_dir
  test "context preparation atomically replaces a read-only AGENTS file", %{tmp_dir: tmp_dir} do
    readonly_home = Path.join(tmp_dir, "readonly-home")
    readonly_agents = Path.join(readonly_home, "AGENTS.md")
    File.mkdir_p!(readonly_home)
    File.write!(readonly_agents, "unchanged")
    File.chmod!(readonly_agents, 0o400)

    on_exit(fn -> File.chmod(readonly_agents, 0o600) end)

    assert {:ok, result} =
             tmp_dir
             |> context(codex_home: readonly_home)
             |> HarnessHome.ensure_local()

    assert File.read!(readonly_agents) =~ "target_id: alpha"
    assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.lstat(readonly_agents)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert result.path == readonly_home
    File.chmod!(readonly_agents, 0o600)
    File.rm!(readonly_agents)
    File.mkdir!(readonly_agents)

    assert {:error, :invalid_harness_home_path} =
             tmp_dir
             |> context(codex_home: readonly_home)
             |> HarnessHome.ensure_local()
  end

  @tag :tmp_dir
  test "context preparation maps inaccessible path components without writing", %{tmp_dir: tmp_dir} do
    restricted_parent = Path.join(tmp_dir, "restricted-parent")
    File.mkdir!(restricted_parent)
    File.chmod!(restricted_parent, 0o000)

    on_exit(fn -> File.chmod(restricted_parent, 0o700) end)

    assert {:error, :invalid_harness_home_path} =
             tmp_dir
             |> context(codex_home: Path.join(restricted_parent, "codex-home"))
             |> HarnessHome.ensure_local()

    File.chmod!(restricted_parent, 0o700)

    restricted_home = Path.join(tmp_dir, "restricted-home")
    File.mkdir!(restricted_home)
    File.chmod!(restricted_home, 0o000)

    on_exit(fn -> File.chmod(restricted_home, 0o700) end)

    assert {:error, :invalid_harness_home_path} =
             tmp_dir
             |> context(codex_home: restricted_home)
             |> HarnessHome.ensure_local()
  end

  @tag :tmp_dir
  test "context preparation rejects a symlinked home component without writing", %{tmp_dir: tmp_dir} do
    outside = Path.join(tmp_dir, "outside-home")
    linked_parent = Path.join(tmp_dir, "linked-parent")
    File.mkdir!(outside)
    File.ln_s!(outside, linked_parent)

    assert {:error, :invalid_harness_home_path} =
             tmp_dir
             |> context(codex_home: Path.join(linked_parent, "codex-home"))
             |> HarnessHome.ensure_local()

    assert {:ok, []} = File.ls(outside)
  end

  @tag :tmp_dir
  test "context preparation normalizes an exclusive temporary file open failure", %{
    tmp_dir: tmp_dir
  } do
    unwritable_home = Path.join(tmp_dir, "unwritable-home")
    File.mkdir!(unwritable_home)
    File.chmod!(unwritable_home, 0o500)
    on_exit(fn -> File.chmod(unwritable_home, 0o700) end)

    assert {:error, :harness_home_prepare_failed} =
             tmp_dir
             |> context(codex_home: unwritable_home)
             |> HarnessHome.ensure_local()

    refute File.exists?(Path.join(unwritable_home, "AGENTS.md"))
    assert Path.wildcard(Path.join(unwritable_home, ".AGENTS.md.symphony-*.tmp")) == []
  end

  @tag :tmp_dir
  test "context preparation rejects a regular file as its home", %{tmp_dir: tmp_dir} do
    occupied_home = Path.join(tmp_dir, "occupied-context-home")
    File.write!(occupied_home, "unchanged")

    assert {:error, :invalid_harness_home_path} =
             tmp_dir
             |> context(codex_home: occupied_home)
             |> HarnessHome.ensure_local()

    assert File.read!(occupied_home) == "unchanged"
  end

  @tag :tmp_dir
  test "context path maps calculation raise throw and exit to one fixed error", %{tmp_dir: tmp_dir} do
    raising = context(tmp_dir, root: Path.join(tmp_dir, "alpha"))
    raising = %{raising | issue_identifier: :invalid}
    assert {:error, :invalid_harness_home_context} = HarnessHome.path(raising)

    secret = "secret-sentinel-harness-path"

    for mode <- [:throw, :exit] do
      failure = %SymphonyElixir.Codex.HarnessHomeAccessFailure{mode: mode, secret: secret}
      valid = context(tmp_dir)

      hostile_manifest =
        Map.put(valid.target.repo_policy["manifest"], "harness", failure)

      hostile = %{
        valid
        | target: %{
            valid.target
            | repo_policy: Map.put(valid.target.repo_policy, "manifest", hostile_manifest)
          }
      }

      assert {:error, :invalid_harness_home_context} = HarnessHome.path(hostile)
    end
  end

  @tag :tmp_dir
  test "legacy path honors environment configured and managed precedence", %{tmp_dir: tmp_dir} do
    previous_home = System.get_env("SYMPHONY_CODEX_HOME")
    on_exit(fn -> restore_env("SYMPHONY_CODEX_HOME", previous_home) end)

    System.put_env("SYMPHONY_CODEX_HOME", "relative/env-home")
    assert HarnessHome.path("/remote/workspace", remote: true) == "relative/env-home"
    assert HarnessHome.path("/local/workspace") == Path.expand("relative/env-home")

    System.delete_env("SYMPHONY_CODEX_HOME")
    write_workflow_file!(Workflow.workflow_file_path(), harness_codex_home: "relative/manifest-home")

    assert HarnessHome.path("/remote/workspace", remote: true) == "relative/manifest-home"

    assert HarnessHome.path("/local/workspace") ==
             Path.expand("relative/manifest-home", Path.dirname(Workflow.workflow_file_path()))

    write_workflow_file!(Workflow.workflow_file_path(), harness_codex_home: nil)

    assert HarnessHome.path(Path.join(tmp_dir, "workspaces/SID-410")) ==
             Path.join([tmp_dir, "workspaces", ".symphony", "codex_home"])
  end

  @tag :tmp_dir
  test "legacy local preparation mirrors operator auth availability", %{tmp_dir: tmp_dir} do
    previous_override = System.get_env("SYMPHONY_CODEX_HOME")
    on_exit(fn -> restore_env("SYMPHONY_CODEX_HOME", previous_override) end)

    codex_home = Path.join(tmp_dir, "managed-home")
    System.delete_env("SYMPHONY_CODEX_HOME")
    write_workflow_file!(Workflow.workflow_file_path(), harness_codex_home: codex_home)

    assert {:ok, ^codex_home} = HarnessHome.ensure_local(Path.join(tmp_dir, "workspace"))
    assert File.read!(Path.join(codex_home, "AGENTS.md")) == HarnessHome.agents_md()

    source = Path.expand("~/.codex/auth.json")
    destination = Path.join(codex_home, "auth.json")

    if File.exists?(source) do
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(destination)
      assert File.read_link!(destination) == source
    else
      assert {:error, :enoent} = File.lstat(destination)
    end

    system_home = Path.expand("~")

    temporary_home? =
      Enum.any?(["/tmp/", "/private/tmp/", "/var/folders/"], &String.starts_with?(system_home, &1))

    if not File.exists?(source) and temporary_home? do
      File.mkdir_p!(Path.dirname(source))
      File.write!(source, "{}")
      on_exit(fn -> File.rm(source) end)
    end

    if File.exists?(source) do
      linked_home = Path.join(tmp_dir, "linked-home")
      write_workflow_file!(Workflow.workflow_file_path(), harness_codex_home: linked_home)
      assert {:ok, ^linked_home} = HarnessHome.ensure_local(Path.join(tmp_dir, "workspace"))
      assert File.read_link!(Path.join(linked_home, "auth.json")) == source
    end

    occupied_home = Path.join(tmp_dir, "occupied-home")
    occupied_auth = Path.join(occupied_home, "auth.json")
    File.mkdir_p!(occupied_home)
    File.write!(occupied_auth, "keep")
    write_workflow_file!(Workflow.workflow_file_path(), harness_codex_home: occupied_home)
    assert {:ok, ^occupied_home} = HarnessHome.ensure_local(Path.join(tmp_dir, "workspace"))
    assert File.read!(occupied_auth) == "keep"
  end

  @tag :tmp_dir
  test "context remote preparation validates components and atomically installs AGENTS", %{
    tmp_dir: tmp_dir
  } do
    codex_home = Path.join([tmp_dir, "remote parent", "codex-home"])
    remote = context(tmp_dir, codex_home: codex_home, worker_host: "worker.example")

    assert {:ok, result} = HarnessHome.remote_prepare(remote)
    assert result.command =~ "set -eu"
    assert result.command =~ "next_path="
    assert result.command =~ "[ ! -L \"$next_path\" ]"
    assert result.command =~ "temp_path="
    assert result.command =~ "umask 077"
    assert result.command =~ "mv -- \"$temp_path\" \"$agents_path\""
    refute result.command =~ "mkdir -p"
    refute result.command =~ "> #{Shell.escape(Path.join(codex_home, "AGENTS.md"))}"

    assert {_, 0} = System.cmd("sh", ["-c", result.command], stderr_to_stdout: true)

    agents_path = Path.join(codex_home, "AGENTS.md")
    assert File.read!(agents_path) =~ "target_id: alpha"
    assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.lstat(agents_path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert Path.wildcard(Path.join(codex_home, ".AGENTS.md.symphony-*.tmp")) == []
  end

  @tag :tmp_dir
  test "context remote preparation rejects linked homes and safely replaces linked AGENTS", %{
    tmp_dir: tmp_dir
  } do
    outside_home = Path.join(tmp_dir, "outside-home")
    linked_parent = Path.join(tmp_dir, "linked-parent")
    File.mkdir!(outside_home)
    File.ln_s!(outside_home, linked_parent)

    linked_home = Path.join(linked_parent, "codex-home")
    linked_context = context(tmp_dir, codex_home: linked_home, worker_host: "worker.example")
    assert {:ok, linked_result} = HarnessHome.remote_prepare(linked_context)

    assert {_output, status} =
             System.cmd("sh", ["-c", linked_result.command], stderr_to_stdout: true)

    assert status != 0
    assert {:ok, []} = File.ls(outside_home)

    safe_home = Path.join(tmp_dir, "safe-home")
    outside_agents = Path.join(tmp_dir, "outside-AGENTS.md")
    agents_path = Path.join(safe_home, "AGENTS.md")
    File.mkdir!(safe_home)
    File.write!(outside_agents, "unchanged")
    File.ln_s!(outside_agents, agents_path)

    safe_context = context(tmp_dir, codex_home: safe_home, worker_host: "worker.example")
    assert {:ok, safe_result} = HarnessHome.remote_prepare(safe_context)
    assert {_, 0} = System.cmd("sh", ["-c", safe_result.command], stderr_to_stdout: true)
    assert File.read!(outside_agents) == "unchanged"
    assert {:ok, %File.Stat{type: :regular}} = File.lstat(agents_path)
    assert File.read!(agents_path) =~ "target_id: alpha"

    File.rm!(agents_path)
    File.mkdir!(agents_path)
    assert {:ok, directory_result} = HarnessHome.remote_prepare(safe_context)

    assert {_output, directory_status} =
             System.cmd("sh", ["-c", directory_result.command], stderr_to_stdout: true)

    assert directory_status != 0
    assert Path.wildcard(Path.join(safe_home, ".AGENTS.md.symphony-*.tmp")) == []
  end

  @tag :tmp_dir
  test "legacy remote preparation command creates harness files and auth link", %{tmp_dir: tmp_dir} do
    operator_home = Path.join(tmp_dir, "operator-home")
    auth_path = Path.join([operator_home, ".codex", "auth.json"])
    codex_home = Path.join(tmp_dir, "remote home")
    File.mkdir_p!(Path.dirname(auth_path))
    File.write!(auth_path, "{}")

    command = HarnessHome.remote_prepare_command(codex_home)
    assert {_, 0} = System.cmd("sh", ["-c", command], env: [{"HOME", operator_home}])
    assert File.read!(Path.join(codex_home, "AGENTS.md")) == HarnessHome.agents_md()
    assert File.read_link!(Path.join(codex_home, "auth.json")) == auth_path
  end

  defp context(tmp_dir, opts \\ []) do
    target_id = Keyword.get(opts, :target_id, "alpha")
    issue_identifier = Keyword.get(opts, :issue_identifier, "SID-410")
    root = Keyword.get(opts, :root, Path.join(tmp_dir, "worktrees"))

    workspace_path =
      if Path.basename(root) == target_id,
        do: Path.join(root, issue_identifier),
        else: Path.join([root, target_id, issue_identifier])

    manifest = %{
      "harness" => %{"codex_home" => Keyword.get(opts, :codex_home)}
    }

    target = %TargetContext{
      target_id: target_id,
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: @hash,
      policy_hash: @hash,
      repo_manifest_hash: @hash,
      repo_policy: %{
        "manifest" => manifest,
        "manifest_source_dir" => Path.join(tmp_dir, "repo"),
        "workflow_module_resolution" => %{}
      },
      tracker_connection: %{},
      run_target: %{},
      worktree_policy: %{
        "root" => root,
        "strategy" => "per_issue",
        "hooks" => %{}
      },
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
      runner_config: %{},
      policy: %{"sandbox" => "restricted"},
      role: :implementation,
      execution_profile: %{},
      timeout_ms: 1_000,
      max_retries: 0,
      worker_host: Keyword.get(opts, :worker_host)
    }
  end
end
