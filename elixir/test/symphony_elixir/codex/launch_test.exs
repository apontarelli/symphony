defmodule SymphonyElixir.Codex.LaunchAccessFailure do
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

defmodule SymphonyElixir.Codex.LaunchTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias SymphonyElixir.Codex.{HarnessHome, Launch}
  alias SymphonyElixir.{ExecutionContext, ProcessSupervisor, Shell, TargetContext}
  @hash "sha256:" <> String.duplicate("a", 64)

  test "remote launch validates argv before starting ssh" do
    workspace = "/remote/workspaces/MT-INVALID-ARGV"

    assert {:error, :invalid_argv} = Launch.start(workspace, "worker-01", [])
    assert {:error, :invalid_argv} = Launch.start(workspace, "worker-01", ["codex", :app_server])
  end

  @tag :tmp_dir
  test "context HarnessHome resolves pinned relative configuration and ignores the override environment", %{
    tmp_dir: tmp_dir
  } do
    previous_home = System.get_env("SYMPHONY_CODEX_HOME")
    on_exit(fn -> restore_env("SYMPHONY_CODEX_HOME", previous_home) end)
    System.put_env("SYMPHONY_CODEX_HOME", "/poisoned/codex-home")

    context = execution_context(tmp_dir, codex_home: "runtime/codex")

    assert {:ok, result} = HarnessHome.path(context)
    assert result.path == Path.join([tmp_dir, "repo", "runtime", "codex"])

    assert result.provenance == %{
             target_id: "alpha",
             registry_generation: @hash,
             policy_hash: @hash
           }
  end

  @tag :tmp_dir
  test "context HarnessHome creates target-isolated local state with safe provenance", %{
    tmp_dir: tmp_dir
  } do
    secret = "secret-sentinel-harness"
    context = execution_context(tmp_dir, codex_home: nil)

    context = %{
      context
      | policy: %{"credential" => secret},
        target: %{
          context.target
          | worktree_policy:
              put_in(
                context.target.worktree_policy,
                ["hooks", "before_run"],
                "printf #{secret}"
              )
        }
    }

    assert {:ok, result} = HarnessHome.ensure_local(context)

    expected_home =
      Path.join([tmp_dir, "worktrees", "alpha", ".symphony", "codex_home"])

    assert result.path == expected_home
    agents = File.read!(Path.join(expected_home, "AGENTS.md"))
    assert agents =~ "target_id: alpha"
    assert agents =~ "registry_generation: #{@hash}"
    assert agents =~ "policy_hash: #{@hash}"
    refute agents =~ secret
    refute inspect(result) =~ secret
  end

  test "context HarnessHome remote prepare uses pinned absolute home and safe content" do
    secret = "secret-sentinel-remote-home"

    context =
      execution_context("/tmp",
        codex_home: "/remote/codex/alpha",
        worker_host: "worker.example"
      )

    context = %{context | policy: %{"credential" => secret}}

    assert {:ok, result} = HarnessHome.remote_prepare(context)
    assert result.path == "/remote/codex/alpha"
    assert result.command =~ "mv -- \"$temp_path\" \"$agents_path\""
    assert result.command =~ "target_id: alpha"
    assert result.command =~ "registry_generation: #{@hash}"
    assert result.command =~ "policy_hash: #{@hash}"
    refute result.command =~ "$HOME"
    refute result.command =~ secret
    refute inspect(result.provenance) =~ secret
  end

  @tag :tmp_dir
  test "context HarnessHome rejects hostile paths and symlinks before writes", %{tmp_dir: tmp_dir} do
    for hostile_home <- ["../escape", "runtime/../escape", "runtime\nhome", "/", <<0xFF>>] do
      context = execution_context(tmp_dir, codex_home: hostile_home)

      assert {:error, :invalid_harness_home_context} = HarnessHome.path(context)
      refute File.exists?(Path.join(tmp_dir, "escape"))
    end

    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(outside)
    linked_parent = Path.join(tmp_dir, "linked-parent")
    File.ln_s!(outside, linked_parent)

    linked_context =
      execution_context(tmp_dir, codex_home: Path.join(linked_parent, "codex-home"))

    assert {:error, :invalid_harness_home_path} =
             HarnessHome.ensure_local(linked_context)

    assert {:ok, []} = File.ls(outside)

    home = Path.join(tmp_dir, "configured-home")
    File.mkdir_p!(home)
    outside_agents = Path.join(outside, "AGENTS.md")
    File.write!(outside_agents, "unchanged")
    File.ln_s!(outside_agents, Path.join(home, "AGENTS.md"))
    agents_context = execution_context(tmp_dir, codex_home: home)

    assert {:error, :invalid_harness_home_path} =
             HarnessHome.ensure_local(agents_context)

    assert File.read!(outside_agents) == "unchanged"
  end

  test "legacy HarnessHome AGENTS bytes remain unchanged" do
    assert HarnessHome.agents_md() ==
             """
             # Symphony Harness

             Scope: global defaults for Symphony-managed unattended Codex sessions.

             - Treat this `CODEX_HOME` as Symphony-owned harness runtime state.
             - Use the session cwd as the target repository; repo-local `AGENTS.md` and docs layer after this file.
             - Do not rely on the operator's interactive `~/.codex/AGENTS.md`, prompts, hooks, or skills.
             - Do not copy Symphony skills into `~/.agents` or `~/.codex`; use the skills and tools available in the session.
             - Keep automation behavior deterministic and report only true blockers that require missing auth, secrets, or permissions.
             """
  end

  @tag :tmp_dir
  test "context Launch starts the pinned local Codex runner with safe provenance", %{tmp_dir: tmp_dir} do
    context =
      execution_context(tmp_dir,
        codex_home: nil,
        command: ["/pinned/codex", "app-server", "--stdio"],
        model: "pinned-model"
      )

    File.mkdir_p!(context.workspace_path)

    parent = self()

    process_starter = fn argv, opts ->
      send(parent, {:local_start, argv, opts})
      {:ok, %{port: :fake_port, process: :fake_process, argv: Enum.drop(argv, 4)}}
    end

    assert {:ok, result} =
             Launch.start(context, line: 8_192, process_starter: process_starter)

    assert_receive {:local_start, argv, opts}
    assert Enum.at(argv, 0) == "/bin/sh"
    assert Enum.at(argv, 1) == "-c"

    assert Enum.drop(argv, 4) == [
             "/pinned/codex",
             "app-server",
             "--stdio",
             "--config",
             "model=\"pinned-model\"",
             "--config",
             "model_reasoning_effort=medium"
           ]

    assert opts[:cd] == context.workspace_path
    assert opts[:line] == 8_192
    assert result.port == :fake_port
    assert result.process == :fake_process

    assert result.provenance == %{
             target_id: "alpha",
             registry_generation: @hash,
             policy_hash: @hash,
             runner_name: "codex",
             runner_kind: "codex_app_server",
             profile: "implementation",
             model: "pinned-model"
           }
  end

  @tag :tmp_dir
  test "context Launch accepts a root already scoped to its target", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "alpha")
    context = execution_context(tmp_dir, root: root, codex_home: nil)
    context = %{context | workspace_path: Path.join(root, context.issue_identifier)}
    File.mkdir_p!(context.workspace_path)
    parent = self()

    process_starter = fn _argv, opts ->
      send(parent, {:target_scoped_start, opts})
      {:ok, %{port: :fake_port, process: :fake_process}}
    end

    assert {:ok, result} = Launch.start(context, process_starter: process_starter)
    assert_receive {:target_scoped_start, opts}
    assert opts[:cd] == context.workspace_path
    assert result.codex_home == Path.join([root, ".symphony", "codex_home"])
  end

  test "context Launch starts one pinned remote transport with context HarnessHome" do
    context =
      execution_context("/tmp",
        codex_home: "/remote/codex/alpha",
        command: ["codex", "app-server", "--pinned"],
        worker_host: "worker.example"
      )

    parent = self()

    ssh_starter = fn host, command, opts ->
      send(parent, {:remote_start, host, command, opts})
      {:ok, %{port: :remote_port, process: :remote_process}}
    end

    assert {:ok, result} = Launch.start(context, ssh_starter: ssh_starter)
    assert_receive {:remote_start, "worker.example", command, [line: nil]}
    assert command =~ "home='/remote/codex/alpha'"
    assert command =~ "cd -- \"$canonical_workspace\""
    assert command =~ "CODEX_HOME='/remote/codex/alpha' exec codex app-server --pinned"
    refute command =~ "$HOME"
    refute_receive {:remote_start, _host, _command, _opts}
    assert result.port == :remote_port
    assert result.process == :remote_process
    assert result.argv == nil
  end

  test "context Launch prepends quoted remote workspace validation to the one start command" do
    context =
      execution_context("/tmp",
        root: "/remote/workspaces",
        issue_identifier: "SID-'410",
        codex_home: "/remote/codex/alpha",
        command: ["codex", "app-server", "--pinned"],
        worker_host: "worker.example"
      )

    parent = self()

    ssh_starter = fn host, command, opts ->
      send(parent, {:validated_remote_start, host, command, opts})
      {:ok, %{port: :remote_port, process: :remote_process}}
    end

    assert {:ok, _result} = Launch.start(context, ssh_starter: ssh_starter)

    assert_receive {:validated_remote_start, "worker.example", command, [line: nil]}
    assert command =~ "canonical_root_parent"
    assert command =~ "expected_workspace=#{Shell.escape(context.workspace_path)}"
    assert command =~ "[ ! -L \"$workspace_candidate\" ]"
    assert command =~ "[ -d \"$workspace_candidate\" ]"
    assert command =~ "canonical_workspace=$(cd -- \"$workspace_candidate\" && pwd -P)"

    {validation_offset, _length} = :binary.match(command, "canonical_root_parent")
    {harness_offset, _length} = :binary.match(command, "target_id: alpha")
    {cd_offset, _length} = :binary.match(command, "cd -- \"$canonical_workspace\"")
    assert validation_offset < harness_offset
    assert harness_offset < cd_offset
    refute_receive {:validated_remote_start, _host, _command, _opts}
  end

  @tag :tmp_dir
  test "context Launch rejects a forged workspace before local process effects", %{tmp_dir: tmp_dir} do
    context = execution_context(tmp_dir, codex_home: nil)
    forged = %{context | workspace_path: Path.join(tmp_dir, "forged-workspace")}
    parent = self()

    process_starter = fn _argv, _opts ->
      send(parent, :unexpected_forged_workspace_start)
      {:ok, %{port: :port, process: :process}}
    end

    assert {:error, :invalid_launch_context} =
             Launch.start(forged, process_starter: process_starter)

    refute_receive :unexpected_forged_workspace_start
  end

  @tag :tmp_dir
  test "context Launch rejects malformed workspace policy and path authority", %{tmp_dir: tmp_dir} do
    valid = execution_context(tmp_dir, codex_home: nil)
    policy = valid.target.worktree_policy
    secret = "secret-sentinel-malformed-launch-authority"
    parent = self()

    process_starter = fn _argv, _opts ->
      send(parent, :unexpected_malformed_authority_start)
      {:ok, %{port: :port, process: :process}}
    end

    invalid_contexts = [
      %{valid | target: %{valid.target | worktree_policy: %{}}},
      %{
        valid
        | target: %{
            valid.target
            | worktree_policy: Map.put(policy, "unexpected", secret)
          }
      },
      %{
        valid
        | target: %{
            valid.target
            | worktree_policy: Map.put(policy, "strategy", "shared")
          }
      },
      %{
        valid
        | workspace_path: nil,
          target: %{valid.target | worktree_policy: Map.put(policy, "root", nil)}
      },
      %{valid | issue_identifier: :invalid, workspace_path: nil}
    ]

    for invalid <- invalid_contexts do
      assert {:error, :invalid_launch_context} =
               Launch.start(invalid, process_starter: process_starter)
    end

    refute_receive :unexpected_malformed_authority_start
    refute inspect(Enum.map(invalid_contexts, &Launch.start(&1, []))) =~ secret
  end

  @tag :tmp_dir
  test "context Launch rejects a workspace replaced by a symlink before local start", %{
    tmp_dir: tmp_dir
  } do
    home = Path.join(tmp_dir, "harness-home")
    context = execution_context(tmp_dir, codex_home: home)
    refute File.exists?(home)
    outside = Path.join(tmp_dir, "outside-workspace")
    File.mkdir_p!(Path.dirname(context.workspace_path))
    File.mkdir!(outside)
    File.ln_s!(outside, context.workspace_path)
    parent = self()

    process_starter = fn _argv, _opts ->
      send(parent, :unexpected_symlink_workspace_start)
      {:ok, %{port: :port, process: :process}}
    end

    assert {:error, :invalid_launch_context} =
             Launch.start(context, process_starter: process_starter)

    refute_receive :unexpected_symlink_workspace_start
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(context.workspace_path)
    refute File.exists?(home)
    refute File.exists?(Path.join(home, "AGENTS.md"))
  end

  @tag :tmp_dir
  test "context Launch rejects missing and non-directory local workspace authority", %{
    tmp_dir: tmp_dir
  } do
    missing =
      execution_context(tmp_dir,
        root: Path.join(tmp_dir, "missing-root"),
        codex_home: Path.join(tmp_dir, "missing-home")
      )

    file_context =
      execution_context(tmp_dir,
        root: Path.join(tmp_dir, "file-root"),
        codex_home: Path.join(tmp_dir, "file-home")
      )

    File.mkdir_p!(Path.dirname(file_context.workspace_path))
    File.write!(file_context.workspace_path, "not a directory")

    outside = Path.join(tmp_dir, "outside-target")
    linked_root = Path.join(tmp_dir, "linked-root")
    File.mkdir!(outside)
    File.ln_s!(outside, linked_root)

    escaped_root =
      execution_context(tmp_dir,
        root: linked_root,
        codex_home: Path.join(tmp_dir, "linked-root-home")
      )

    target_root = Path.join(tmp_dir, "target-root")

    linked_target =
      execution_context(tmp_dir,
        root: target_root,
        codex_home: Path.join(tmp_dir, "linked-target-home")
      )

    File.mkdir!(target_root)
    File.ln_s!(outside, Path.join(target_root, "alpha"))
    parent = self()

    process_starter = fn _argv, _opts ->
      send(parent, :unexpected_invalid_workspace_start)
      {:ok, %{port: :port, process: :process}}
    end

    for context <- [missing, file_context, escaped_root, linked_target] do
      assert {:error, :invalid_launch_context} =
               Launch.start(context, process_starter: process_starter)
    end

    refute_receive :unexpected_invalid_workspace_start
  end

  @tag :tmp_dir
  test "context Launch rejects authority overrides and invalid runners before transport", %{
    tmp_dir: tmp_dir
  } do
    context = execution_context(tmp_dir, codex_home: nil)
    parent = self()

    process_starter = fn _argv, _opts ->
      send(parent, :unexpected_process_start)
      {:ok, %{port: :port, process: :process}}
    end

    for opts <- [
          [command: ["forged"]],
          [model: "forged"],
          [root: "/forged"],
          [worker_host: "forged.example"],
          [policy: %{"forged" => true}]
        ] do
      assert {:error, :launch_option_forbidden} = Launch.start(context, opts)
    end

    opencode = execution_context(tmp_dir, codex_home: nil, runner_kind: "opencode_server")

    assert {:error, :unsupported_runner_kind} =
             Launch.start(opencode, process_starter: process_starter)

    invalid_argv =
      execution_context(tmp_dir,
        codex_home: nil,
        command: ["codex", <<0xFF>>]
      )

    assert {:error, :invalid_argv} =
             Launch.start(invalid_argv, process_starter: process_starter)

    forged_runner = %{context | runner_config: Map.put(context.runner_config, "command", ["forged"])}

    assert {:error, :invalid_launch_context} =
             Launch.start(forged_runner, process_starter: process_starter)

    forged_profile = %{
      context
      | execution_profile: %{context.execution_profile | model: "forged-model"}
    }

    assert {:error, :invalid_launch_context} =
             Launch.start(forged_profile, process_starter: process_starter)

    refute_receive :unexpected_process_start
  end

  @tag :tmp_dir
  test "context Launch rejects non-list options before harness or transport effects", %{
    tmp_dir: tmp_dir
  } do
    home = Path.join(tmp_dir, "harness-home")
    context = execution_context(tmp_dir, codex_home: home)

    for invalid_opts <- [
          :invalid_options,
          %{},
          [{:process_starter, nil} | :invalid_tail]
        ] do
      assert {:error, :invalid_launch_options} = Launch.start(context, invalid_opts)
    end

    assert {:error, :launch_option_forbidden} =
             Launch.start(context, unknown: fn -> send(self(), :unexpected_transport) end)

    refute File.exists?(home)
    refute_receive :unexpected_transport
  end

  @tag :tmp_dir
  test "concurrent context Launch calls remain disjoint after globals change", %{tmp_dir: tmp_dir} do
    previous_home = System.get_env("SYMPHONY_CODEX_HOME")
    previous_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)

    on_exit(fn ->
      restore_env("SYMPHONY_CODEX_HOME", previous_home)

      if previous_workflow,
        do: Application.put_env(:symphony_elixir, :workflow_file_path, previous_workflow),
        else: Application.delete_env(:symphony_elixir, :workflow_file_path)
    end)

    context_a =
      execution_context(tmp_dir,
        root: Path.join(tmp_dir, "root-a"),
        target_id: "alpha",
        codex_home: Path.join(tmp_dir, "home-a"),
        command: ["/runner-a", "app-server"],
        model: "model-a"
      )

    context_b =
      execution_context(tmp_dir,
        root: Path.join(tmp_dir, "root-b"),
        target_id: "beta",
        codex_home: Path.join(tmp_dir, "home-b"),
        command: ["/runner-b", "app-server"],
        model: "model-b"
      )

    File.mkdir_p!(context_a.workspace_path)
    File.mkdir_p!(context_b.workspace_path)

    parent = self()

    process_starter = fn argv, opts ->
      send(parent, {:launch_ready, self(), argv, opts})

      receive do
        :continue ->
          {:ok, %{port: {:port, self()}, process: {:process, self()}}}
      end
    end

    task_a = Task.async(fn -> Launch.start(context_a, process_starter: process_starter) end)
    task_b = Task.async(fn -> Launch.start(context_b, process_starter: process_starter) end)

    assert_receive {:launch_ready, starter_a, argv_a, opts_a}, 1_000
    assert_receive {:launch_ready, starter_b, argv_b, opts_b}, 1_000

    System.put_env("SYMPHONY_CODEX_HOME", "/poisoned/home")
    Application.put_env(:symphony_elixir, :workflow_file_path, "/poisoned/manifest")
    send(starter_a, :continue)
    send(starter_b, :continue)

    assert {:ok, result_a} = Task.await(task_a)
    assert {:ok, result_b} = Task.await(task_b)

    launch_calls = [{argv_a, opts_a}, {argv_b, opts_b}]

    assert Enum.any?(launch_calls, fn {argv, opts} ->
             "/runner-a" in argv and opts[:cd] == context_a.workspace_path
           end)

    assert Enum.any?(launch_calls, fn {argv, opts} ->
             "/runner-b" in argv and opts[:cd] == context_b.workspace_path
           end)

    assert result_a.codex_home == Path.join(tmp_dir, "home-a")
    assert result_a.provenance.model == "model-a"
    assert result_b.codex_home == Path.join(tmp_dir, "home-b")
    assert result_b.provenance.model == "model-b"
  end

  @tag :tmp_dir
  test "context Launch maps dependency failures to fixed secret-safe errors", %{tmp_dir: tmp_dir} do
    context = execution_context(tmp_dir, codex_home: nil)
    File.mkdir_p!(context.workspace_path)
    secret = "secret-sentinel-launch-dependency"

    for failure <- [
          fn -> raise secret end,
          fn -> throw(secret) end,
          fn -> exit(secret) end
        ] do
      process_starter = fn _argv, _opts -> failure.() end

      log =
        capture_log(fn ->
          assert {:error, :launch_transport_failed} =
                   Launch.start(context, process_starter: process_starter)
        end)

      refute log =~ secret
    end
  end

  @tag :tmp_dir
  test "context Launch normalizes hostile pre-starter exceptions without effects", %{tmp_dir: tmp_dir} do
    secret = "secret-sentinel-hostile-context"
    context = execution_context(tmp_dir, codex_home: nil)
    hostile = %{context | execution_profile: secret}
    parent = self()

    process_starter = fn _argv, _opts ->
      send(parent, :unexpected_hostile_context_start)
      {:ok, %{port: :port, process: :process}}
    end

    log =
      capture_log(fn ->
        assert {:error, :invalid_launch_context} =
                 Launch.start(hostile, process_starter: process_starter)
      end)

    refute log =~ secret
    refute_receive :unexpected_hostile_context_start
  end

  @tag :tmp_dir
  test "context Launch contains hostile pre-starter throw and exit reasons", %{tmp_dir: tmp_dir} do
    secret = "secret-sentinel-hostile-control-flow"
    context = execution_context(tmp_dir, codex_home: nil)
    File.mkdir_p!(context.workspace_path)
    parent = self()

    process_starter = fn _argv, _opts ->
      send(parent, :unexpected_hostile_control_flow_start)
      {:ok, %{port: :port, process: :process}}
    end

    for mode <- [:throw, :exit] do
      failure = %SymphonyElixir.Codex.LaunchAccessFailure{mode: mode, secret: secret}
      manifest = Map.put(context.target.repo_policy["manifest"], "harness", failure)

      hostile = %{
        context
        | target: %{
            context.target
            | repo_policy: Map.put(context.target.repo_policy, "manifest", manifest)
          }
      }

      log =
        capture_log(fn ->
          assert {:error, :invalid_harness_home_context} =
                   Launch.start(hostile, process_starter: process_starter)
        end)

      refute log =~ secret
    end

    refute_receive :unexpected_hostile_control_flow_start
  end

  @tag :tmp_dir
  test "context Launch validates options context shape and pinned argv", %{tmp_dir: tmp_dir} do
    context = execution_context(tmp_dir, codex_home: nil)

    assert {:error, :invalid_launch_options} = Launch.start(context, :invalid)
    assert {:error, :invalid_launch_context} = Launch.start(:invalid, [])

    assert {:error, :duplicate_launch_option} =
             Launch.start(context, line: 1, line: 2)

    assert {:error, :invalid_launch_context} =
             Launch.start(%{context | target: nil}, [])

    invalid_runner = Map.put(context.runner_config, "command", nil)

    invalid_target = %{
      context.target
      | runner_policy: put_in(context.target.runner_policy, ["runners", "codex"], invalid_runner)
    }

    assert {:error, :invalid_argv} =
             Launch.start(
               %{context | target: invalid_target, runner_config: invalid_runner},
               []
             )
  end

  @tag :tmp_dir
  test "context Launch normalizes starter error and malformed success results", %{tmp_dir: tmp_dir} do
    context = execution_context(tmp_dir, codex_home: nil)
    File.mkdir_p!(context.workspace_path)

    assert {:error, :launch_transport_failed} =
             Launch.start(context, process_starter: fn _argv, _opts -> {:error, :secret} end)

    assert {:error, :launch_transport_failed} =
             Launch.start(context, process_starter: fn _argv, _opts -> :unexpected end)
  end

  @tag :tmp_dir
  test "context Launch default local starter owns a stoppable process", %{tmp_dir: tmp_dir} do
    runner = Path.join(tmp_dir, "local-runner")
    File.write!(runner, "#!/bin/sh\nexec /bin/cat\n")
    File.chmod!(runner, 0o755)

    context = execution_context(tmp_dir, codex_home: nil, command: [runner])
    File.mkdir_p!(context.workspace_path)

    assert {:ok, result} = Launch.start(context, [])
    assert is_port(result.port)
    assert %ProcessSupervisor{} = result.process
    assert result.argv |> List.first() == runner
    assert :ok = ProcessSupervisor.stop(result.process)
  end

  @tag :tmp_dir
  test "context Launch default remote starter owns a stoppable SSH port", %{tmp_dir: tmp_dir} do
    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    fake_ssh = Path.join(tmp_dir, "ssh")
    File.write!(fake_ssh, "#!/bin/sh\nexec /bin/cat\n")
    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", tmp_dir <> ":" <> (previous_path || ""))

    context =
      execution_context(tmp_dir,
        codex_home: "/remote/codex/alpha",
        command: ["codex", "app-server"],
        worker_host: "worker.example"
      )

    assert {:ok, result} = Launch.start(context, [])
    assert is_port(result.port)
    assert %ProcessSupervisor{} = result.process
    assert result.argv == nil
    assert :ok = ProcessSupervisor.stop(result.process)
  end

  @tag :tmp_dir
  test "legacy Launch preserves the empty runner command error", %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir!(workspace)

    assert {:error, :empty_runner_command} = Launch.start(workspace, nil, [""])
  end

  @tag :tmp_dir
  test "legacy Launch preserves argv override home and executable lookup contracts", %{tmp_dir: tmp_dir} do
    previous_home = System.get_env("SYMPHONY_CODEX_HOME")
    on_exit(fn -> restore_env("SYMPHONY_CODEX_HOME", previous_home) end)

    workspace = Path.join(tmp_dir, "workspace")
    runner = Path.join(tmp_dir, "legacy-runner")
    codex_home = Path.join(tmp_dir, "legacy-home")
    File.mkdir!(workspace)
    File.write!(runner, "#!/bin/sh\nexec /bin/cat\n")
    File.chmod!(runner, 0o755)
    System.put_env("SYMPHONY_CODEX_HOME", codex_home)

    assert {:error, {:executable_not_found, "missing-symphony-runner"}} =
             Launch.start(workspace, nil, ["missing-symphony-runner"])

    assert {:ok, result} = Launch.start(workspace, nil, [runner, "--pinned"])
    assert result.argv == [runner, "--pinned"]
    assert result.codex_home == codex_home
    assert :ok = ProcessSupervisor.stop(result.process)
  end

  @tag :tmp_dir
  test "legacy Launch starts remote argv through the SSH adapter", %{tmp_dir: tmp_dir} do
    previous_path = System.get_env("PATH")
    previous_home = System.get_env("SYMPHONY_CODEX_HOME")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_CODEX_HOME", previous_home)
    end)

    fake_ssh = Path.join(tmp_dir, "ssh")
    File.write!(fake_ssh, "#!/bin/sh\nexec /bin/cat\n")
    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", tmp_dir <> ":" <> (previous_path || ""))
    System.put_env("SYMPHONY_CODEX_HOME", "/remote/codex/home")

    assert {:ok, result} =
             Launch.start("/remote/workspace", "worker.example", ["codex", "app-server"])

    assert is_port(result.port)
    assert result.argv == nil
    assert result.codex_home == "/remote/codex/home"
    assert :ok = ProcessSupervisor.stop(result.process)
  end

  @tag :tmp_dir
  test "legacy Launch rejects a non-regular executable path", %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir!(workspace)

    assert {:error, {:executable_not_found, ^workspace}} =
             Launch.start(workspace, nil, [workspace])
  end

  defp execution_context(tmp_dir, opts) do
    source_dir = Path.join(tmp_dir, "repo")
    root = Keyword.get(opts, :root, Path.join(tmp_dir, "worktrees"))
    target_id = Keyword.get(opts, :target_id, "alpha")
    issue_identifier = Keyword.get(opts, :issue_identifier, "SID-410")
    codex_home = Keyword.get(opts, :codex_home)
    command = Keyword.get(opts, :command, ["codex", "app-server"])
    model = Keyword.get(opts, :model, "pinned-model")
    profile_command = Keyword.get(opts, :profile_command)

    profile_config = %{
      "model" => model,
      "reasoning_effort" => "medium",
      "budget" => "standard",
      "timeout_ms" => 1_000,
      "max_retries" => 0,
      "command" => profile_command
    }

    runner_config = %{
      "kind" => Keyword.get(opts, :runner_kind, "codex_app_server"),
      "command" => command,
      "execution_profiles" => %{"implementation" => profile_config}
    }

    target = %TargetContext{
      target_id: target_id,
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: @hash,
      policy_hash: @hash,
      repo_manifest_hash: @hash,
      repo_policy: %{
        "manifest" => %{"harness" => %{"codex_home" => codex_home}},
        "manifest_source_dir" => source_dir,
        "workflow_module_resolution" => %{}
      },
      tracker_connection: %{},
      run_target: %{},
      worktree_policy: %{
        "root" => root,
        "strategy" => "per_issue",
        "hooks" => %{
          "after_create" => nil,
          "after_run" => nil,
          "before_remove" => nil,
          "before_run" => nil,
          "timeout_ms" => 1_000
        }
      },
      runner_policy: %{
        "default" => "codex",
        "allowed" => ["codex"],
        "runners" => %{"codex" => runner_config}
      },
      effective_checks: %{},
      external_side_effect_gates: %{},
      capacity_limits: %{},
      budget_limits: %{}
    }

    %ExecutionContext{
      target: target,
      issue_id: "issue-410",
      issue_identifier: issue_identifier,
      workspace_path: Path.join([root, target_id, issue_identifier]),
      runner_name: "codex",
      runner_config: runner_config,
      policy: %{"sandbox" => "restricted"},
      role: :implementation,
      execution_profile: %{
        name: "implementation",
        model: model,
        reasoning_effort: "medium",
        budget: "standard",
        timeout_ms: 1_000,
        max_retries: 0,
        command: profile_command
      },
      timeout_ms: 1_000,
      max_retries: 0,
      worker_host: Keyword.get(opts, :worker_host)
    }
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
