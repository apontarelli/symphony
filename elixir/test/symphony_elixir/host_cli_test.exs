defmodule SymphonyElixir.HostCLITest do
  use ExUnit.Case

  alias SymphonyElixir.HostCLI
  alias SymphonyElixir.OperatorCommandService
  alias SymphonyElixir.OperatorCommandService.Command
  alias SymphonyElixir.OperatorCommandService.PlanStore
  alias SymphonyElixir.TargetRegistry.Yaml

  @max_preview_key_bytes 512
  @max_preview_string_leaf_bytes 262_144
  @max_preview_aggregate_bytes 1_048_576

  @host_usage """
  Usage:
    symphony host run [--registry <path>]
    symphony host target add <id> --input <target.yml> [--registry <path>] [--json]
    symphony host target add <id> --confirm <plan-id> [--registry <path>] [--json]
    symphony host target import <id> --workflow <path> --repo <path> [--connection <id>] [--runner <source>=<id>] [--registry <path>] [--json]
    symphony host target import <id> --confirm <plan-id> [--registry <path>] [--json]
    symphony host target plan <id> --patch <target-patch.yml> [--registry <path>] [--json]
    symphony host target patch <id> --confirm <plan-id> [--registry <path>] [--json]
    symphony host target activate <id> [--mode <watch|explicit>] [--registry <path>] [--json]
    symphony host target activate <id> --confirm <plan-id> [--registry <path>] [--json]
    symphony host target pause <id> [--registry <path>] [--json]
    symphony host target pause <id> --confirm <plan-id> [--registry <path>] [--json]
    symphony host target drain <id> [--registry <path>] [--json]
    symphony host target drain <id> --confirm <plan-id> [--registry <path>] [--json]
    symphony host target retire <id> [--registry <path>] [--json]
    symphony host target retire <id> --confirm <plan-id> [--registry <path>] [--json]
  """

  defp host_usage do
    @host_usage |> String.trim()
  end

  test "bare host invocation returns host usage" do
    assert {:error, usage} = HostCLI.evaluate([])
    assert usage == host_usage()
  end

  test "host --help returns host usage as success without invoking dependencies" do
    deps = forbidden_deps()
    assert {:ok, usage} = HostCLI.evaluate(["--help"], deps)
    assert usage == host_usage()
    refute_received :plan_called
    refute_received :confirm_action_called
    refute_received :read_file_called
  end

  test "host target --help returns host usage as success" do
    assert {:ok, usage} = HostCLI.evaluate(["target", "--help"])
    assert usage == host_usage()
  end

  test "unknown host subcommand returns host usage without invoking dependencies" do
    parent = self()

    deps = %{
      plan: fn _cmd, _opts ->
        send(parent, :plan_called)
        flunk("plan should not be called for unknown subcommand")
      end,
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        send(parent, :confirm_action_called)
        flunk("confirm_action should not be called for unknown subcommand")
      end,
      read_file: fn _path ->
        send(parent, :read_file_called)
        flunk("read_file should not be called for unknown subcommand")
      end
    }

    assert {:error, usage} = HostCLI.evaluate(["unknown"], deps)
    assert usage == host_usage()
    refute_received :plan_called
    refute_received :confirm_action_called
    refute_received :read_file_called
  end

  test "host run loads one registry snapshot and starts the daemon" do
    parent = self()
    registry_path = Path.expand("runtime-registry.yml")
    loaded = %{snapshot: %{host: %{"state_root" => "/runtime-state"}}, contexts: %{}}

    deps = %{
      load_registry: fn path ->
        send(parent, {:registry_loaded, path})
        {:ok, loaded}
      end,
      start_host: fn path, snapshot ->
        send(parent, {:host_started, path, snapshot})
        :ok
      end
    }

    assert :ok = HostCLI.evaluate(["run", "--registry", registry_path], deps)
    assert_received {:registry_loaded, ^registry_path}
    assert_received {:host_started, ^registry_path, ^loaded}
  end

  test "host run help and invalid repeated registry are side-effect free" do
    deps = %{
      load_registry: fn _path -> flunk("registry must not load") end,
      start_host: fn _path, _loaded -> flunk("host must not start") end
    }

    assert {:ok, usage} = HostCLI.evaluate(["run", "--help"], deps)
    assert usage == "Usage:\n  symphony host run [--registry <path>]"

    assert {:error, repeated_usage} =
             HostCLI.evaluate(
               ["run", "--registry", "/one.yml", "--registry", "/two.yml"],
               deps
             )

    assert repeated_usage == usage
  end

  test "target add without id returns command-specific usage" do
    deps = forbidden_deps()
    assert {:error, usage} = HostCLI.evaluate(["target", "add"], deps)
    assert usage =~ "symphony host target add"
    assert usage =~ "--input"
    assert usage =~ "--confirm"
  end

  test "target add with missing required option returns usage" do
    deps = forbidden_deps()
    assert {:error, usage} = HostCLI.evaluate(["target", "add", "my-target"], deps)
    assert usage =~ "symphony host target add"
  end

  test "target add with both --input and --confirm returns usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "t.yml", "--confirm", "abc123"], deps)

    assert usage =~ "symphony host target add"
    refute_received :plan_called
  end

  test "target add with repeated singleton option returns usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "t.yml", "--input", "t2.yml"], deps)

    assert usage =~ "symphony host target add"
    refute_received :plan_called
  end

  test "target add with repeated registry returns usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(
               ["target", "add", "my-target", "--input", "t.yml", "--registry", "/r1", "--registry", "/r2"],
               deps
             )

    assert usage =~ "symphony host target add"
    refute_received :plan_called
  end

  test "target add with repeated json returns command-specific usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json", "--json"], deps)

    assert usage =~ "symphony host target add"
    refute_received :plan_called
    refute_received :read_file_called
    refute_received :json_encode_called
  end

  test "target add with negated json returns command-specific usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--no-json"], deps)

    assert usage =~ "symphony host target add"
    refute_received :plan_called
    refute_received :read_file_called
    refute_received :json_encode_called
  end

  test "target add with json assignment form returns command-specific usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json=true"], deps)

    assert usage =~ "symphony host target add"
    refute_received :plan_called
    refute_received :read_file_called
    refute_received :json_encode_called
  end

  test "target add with extra positional argument returns usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(["target", "add", "my-target", "extra", "--input", "t.yml"], deps)

    assert usage =~ "symphony host target add"
    refute_received :plan_called
  end

  test "target add with unknown option returns usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "t.yml", "--unknown"], deps)

    assert usage =~ "symphony host target add"
    refute_received :plan_called
  end

  test "target import without id returns import usage" do
    deps = forbidden_deps()
    assert {:error, usage} = HostCLI.evaluate(["target", "import"], deps)
    assert usage =~ "symphony host target import"
    assert usage =~ "--workflow"
    assert usage =~ "--repo"
  end

  test "target import with missing workflow or repo returns usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(["target", "import", "my-target", "--workflow", "w.yml"], deps)

    assert usage =~ "symphony host target import"
    refute_received :plan_called

    assert {:error, usage} =
             HostCLI.evaluate(["target", "import", "my-target", "--repo", "/repo"], deps)

    assert usage =~ "symphony host target import"
    refute_received :plan_called
  end

  test "target import with both preview and confirm options returns usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--confirm",
                 "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1",
                 "--workflow",
                 "w.yml"
               ],
               deps
             )

    assert usage =~ "symphony host target import"
    refute_received :confirm_action_called
  end

  test "target import with repeated workflow returns usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(
               ["target", "import", "my-target", "--workflow", "w.yml", "--workflow", "w2.yml", "--repo", "/repo"],
               deps
             )

    assert usage =~ "symphony host target import"
    refute_received :plan_called
  end

  test "target import with repeated json returns command-specific usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--workflow",
                 "w.yml",
                 "--repo",
                 "/repo",
                 "--json",
                 "--json"
               ],
               deps
             )

    assert usage =~ "symphony host target import"
    refute_received :plan_called
    refute_received :json_encode_called
  end

  test "target import with negated json returns command-specific usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--workflow",
                 "w.yml",
                 "--repo",
                 "/repo",
                 "--no-json"
               ],
               deps
             )

    assert usage =~ "symphony host target import"
    refute_received :plan_called
    refute_received :json_encode_called
  end

  test "target import with repeated connection returns usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--workflow",
                 "w.yml",
                 "--repo",
                 "/repo",
                 "--connection",
                 "c1",
                 "--connection",
                 "c2"
               ],
               deps
             )

    assert usage =~ "symphony host target import"
    refute_received :plan_called
  end

  test "target import confirm with repo option returns usage" do
    deps = forbidden_deps()
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    assert {:error, usage} =
             HostCLI.evaluate(
               ["target", "import", "my-target", "--confirm", plan_id, "--repo", "/repo"],
               deps
             )

    assert usage =~ "symphony host target import"
    refute_received :confirm_action_called
  end

  test "target import confirm with connection option returns usage" do
    deps = forbidden_deps()
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    assert {:error, usage} =
             HostCLI.evaluate(
               ["target", "import", "my-target", "--confirm", plan_id, "--connection", "c1"],
               deps
             )

    assert usage =~ "symphony host target import"
    refute_received :confirm_action_called
  end

  test "target import confirm with runner option returns usage" do
    deps = forbidden_deps()
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    assert {:error, usage} =
             HostCLI.evaluate(
               ["target", "import", "my-target", "--confirm", plan_id, "--runner", "a=b"],
               deps
             )

    assert usage =~ "symphony host target import"
    refute_received :confirm_action_called
  end

  test "target import with confirm and preview options returns usage" do
    deps = forbidden_deps()
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    assert {:error, usage} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--confirm",
                 plan_id,
                 "--workflow",
                 "w.yml",
                 "--repo",
                 "/repo"
               ],
               deps
             )

    assert usage =~ "symphony host target import"
    refute_received :confirm_action_called
    refute_received :plan_called
  end

  test "target plan without id returns plan usage" do
    deps = forbidden_deps()
    assert {:error, usage} = HostCLI.evaluate(["target", "plan"], deps)
    assert usage =~ "symphony host target plan"
    assert usage =~ "--patch"
  end

  test "target plan with missing patch returns usage" do
    deps = forbidden_deps()
    assert {:error, usage} = HostCLI.evaluate(["target", "plan", "my-target"], deps)
    assert usage =~ "symphony host target plan"
    refute_received :plan_called
  end

  test "target plan with repeated json returns command-specific usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(
               ["target", "plan", "my-target", "--patch", "p.yml", "--json", "--json"],
               deps
             )

    assert usage =~ "symphony host target plan"
    refute_received :plan_called
    refute_received :json_encode_called
  end

  test "target plan with negated json returns command-specific usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(
               ["target", "plan", "my-target", "--patch", "p.yml", "--no-json"],
               deps
             )

    assert usage =~ "symphony host target plan"
    refute_received :plan_called
    refute_received :json_encode_called
  end

  test "target patch without id returns patch usage" do
    deps = forbidden_deps()
    assert {:error, usage} = HostCLI.evaluate(["target", "patch"], deps)
    assert usage =~ "symphony host target patch"
    assert usage =~ "--confirm"
  end

  test "target patch with missing confirm returns usage" do
    deps = forbidden_deps()
    assert {:error, usage} = HostCLI.evaluate(["target", "patch", "my-target"], deps)
    assert usage =~ "symphony host target patch"
    refute_received :confirm_action_called
  end

  test "target patch with repeated confirm returns usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(
               [
                 "target",
                 "patch",
                 "my-target",
                 "--confirm",
                 "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1",
                 "--confirm",
                 "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"
               ],
               deps
             )

    assert usage =~ "symphony host target patch"
    refute_received :confirm_action_called
  end

  test "target patch with repeated json returns command-specific usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(
               [
                 "target",
                 "patch",
                 "my-target",
                 "--confirm",
                 "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1",
                 "--json",
                 "--json"
               ],
               deps
             )

    assert usage =~ "symphony host target patch"
    refute_received :confirm_action_called
    refute_received :json_encode_called
  end

  test "target patch with negated json returns command-specific usage" do
    deps = forbidden_deps()

    assert {:error, usage} =
             HostCLI.evaluate(
               [
                 "target",
                 "patch",
                 "my-target",
                 "--confirm",
                 "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1",
                 "--no-json"
               ],
               deps
             )

    assert usage =~ "symphony host target patch"
    refute_received :confirm_action_called
    refute_received :json_encode_called
  end

  test "target add preview invokes plan dependency with typed command" do
    parent = self()

    deps = %{
      plan: fn cmd, opts ->
        send(parent, {:plan, cmd, opts})

        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: default_registry_path(),
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"registry" => %{"diff" => [], "diagnostics" => [], "impact" => %{"overall" => "unchanged"}}},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn path ->
        send(parent, {:read_file, path})
        {:ok, "display_name: test"}
      end,
      yaml_decode: fn content ->
        send(parent, {:yaml_decode, content})
        {:ok, %{"display_name" => "test"}}
      end
    }

    assert {:ok, output} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert_received {:read_file, "target.yml"}
    assert_received {:yaml_decode, "display_name: test"}
    assert_received {:plan, cmd, opts}
    assert %Command.Add{target_id: "my-target", target: %{"display_name" => "test"}} = cmd
    assert opts == []
    assert output =~ "Plan add for my-target"
    assert output =~ "plan ID: (not applicable)"
    assert output =~ "applicable: false"
    assert output =~ "expected generation: sha256:0000000000000000000000000000000000000000000000000000000000000000"
    assert output =~ "proposed generation: sha256:1111111111111111111111111111111111111111111111111111111111111111"
    assert output =~ "confirmation changes registry state"
    assert output =~ "running hosts adopt"
    assert output =~ "fully verified generation"
  end

  test "target add preview with --registry passes registry_path in opts" do
    parent = self()
    registry_arg = "custom/registry.yml"
    registry_path = Path.expand(registry_arg)

    deps = %{
      plan: fn _cmd, opts ->
        send(parent, {:plan_opts, opts})
        {:ok, sample_plan(:add, "my-target", registry_path)}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:ok, _output} =
             HostCLI.evaluate(
               ["target", "add", "my-target", "--input", "target.yml", "--registry", registry_arg],
               deps
             )

    assert_received {:plan_opts, opts}
    assert opts == [registry_path: registry_arg]
  end

  test "target add preview with --json returns encoded plan" do
    parent = self()

    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: default_registry_path(),
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end,
      json_encode: fn value ->
        send(parent, {:json_encode, value})
        {:ok, Jason.encode!(value)}
      end
    }

    assert {:ok, json} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert_received {:json_encode, plan}
    assert plan["action"] == "add"
    assert plan["id"] == nil
    assert is_binary(json)
    decoded = Jason.decode!(json)
    assert decoded["action"] == "add"
    assert decoded["target_id"] == "my-target"
    assert decoded["applicable?"] == false
  end

  test "target add confirm invokes confirm dependency with add action binding" do
    parent = self()
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn tid, pid, action, conf, opts ->
        send(parent, {:confirm_action, tid, pid, action, conf, opts})

        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: pid,
           action: :add,
           target_id: tid,
           registry_path: default_registry_path(),
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:ok, output} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert_received {:confirm_action, "my-target", ^plan_id, :add, true, []}
    assert output =~ "Apply add for my-target"
    assert output =~ "committed: true"
    assert output =~ "plan consumed: true"
    assert output =~ "old generation: sha256:0000000000000000000000000000000000000000000000000000000000000000"
    assert output =~ "new generation: sha256:1111111111111111111111111111111111111111111111111111111111111111"
  end

  test "target add confirm with --json returns encoded apply result" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: pid,
           action: :add,
           target_id: "my-target",
           registry_path: Path.expand("custom/registry.yml"),
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end,
      json_encode: fn value ->
        {:ok, Jason.encode!(value)}
      end
    }

    assert {:ok, json} =
             HostCLI.evaluate(
               [
                 "target",
                 "add",
                 "my-target",
                 "--confirm",
                 plan_id,
                 "--registry",
                 "custom/registry.yml",
                 "--json"
               ],
               deps
             )

    decoded = Jason.decode!(json)
    assert decoded["action"] == "add"
    assert decoded["committed?"] == true
    assert decoded["plan_consumed?"] == true
    assert decoded["plan_id"] == plan_id
  end

  test "target import preview invokes plan with import command and runner ids" do
    parent = self()

    deps = %{
      plan: fn cmd, _opts ->
        send(parent, {:plan, cmd})
        {:ok, sample_plan(:import, cmd.target_id)}
      end
    }

    assert {:ok, _output} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--workflow",
                 "/wf.yml",
                 "--repo",
                 "/repo",
                 "--connection",
                 "linear",
                 "--runner",
                 "codex=custom-codex"
               ],
               deps
             )

    assert_received {:plan, cmd}
    assert %Command.Import{} = cmd
    assert cmd.target_id == "my-target"
    assert cmd.workflow == "/wf.yml"
    assert cmd.repo == "/repo"
    assert cmd.connection_id == "linear"
    assert cmd.runner_ids == %{"codex" => "custom-codex"}
  end

  test "target import preview with malformed runner mapping returns error without calling plan" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--workflow",
                 "/wf.yml",
                 "--repo",
                 "/repo",
                 "--runner",
                 "bad-mapping"
               ],
               deps
             )

    assert error =~ "invalid runner mapping"
    refute_received :plan_called
  end

  test "target import preview with duplicate runner source returns error" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--workflow",
                 "/wf.yml",
                 "--repo",
                 "/repo",
                 "--runner",
                 "codex=a",
                 "--runner",
                 "codex=b"
               ],
               deps
             )

    assert error =~ "duplicate runner source"
    refute_received :plan_called
  end

  test "target import confirm invokes confirm_action with import action binding" do
    parent = self()
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn tid, pid, action, conf, opts ->
        send(parent, {:confirm_action, tid, pid, action, conf, opts})

        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: pid,
           action: :import,
           target_id: tid,
           registry_path: default_registry_path(),
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:ok, _output} =
             HostCLI.evaluate(["target", "import", "my-target", "--confirm", plan_id], deps)

    assert_received {:confirm_action, "my-target", ^plan_id, :import, true, []}
  end

  test "target plan preview invokes plan with patch command" do
    parent = self()

    deps = %{
      plan: fn cmd, _opts ->
        send(parent, {:plan, cmd})
        {:ok, sample_plan(:patch, cmd.target_id)}
      end,
      read_file: fn _path -> {:ok, "display_name: Updated"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "Updated"}} end
    }

    assert {:ok, output} =
             HostCLI.evaluate(["target", "plan", "my-target", "--patch", "patch.yml"], deps)

    assert_received {:plan, cmd}
    assert %Command.Patch{} = cmd
    assert cmd.target_id == "my-target"
    assert cmd.changes == %{"display_name" => "Updated"}
    assert output =~ "Plan patch for my-target"
  end

  test "target patch confirm invokes confirm_action with patch action binding" do
    parent = self()
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn tid, pid, action, conf, opts ->
        send(parent, {:confirm_action, tid, pid, action, conf, opts})

        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: pid,
           action: :patch,
           target_id: tid,
           registry_path: default_registry_path(),
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:ok, _output} =
             HostCLI.evaluate(["target", "patch", "my-target", "--confirm", plan_id], deps)

    assert_received {:confirm_action, "my-target", ^plan_id, :patch, true, []}
  end

  test "lifecycle previews invoke typed commands and activation parses dispatch mode" do
    parent = self()

    deps = %{
      plan: fn command, _opts ->
        action =
          case command do
            %Command.Activate{} -> :activate
            %Command.Pause{} -> :pause
            %Command.Drain{} -> :drain
            %Command.Retire{} -> :retire
          end

        send(parent, {:lifecycle_plan, action, command})
        {:ok, sample_plan(action, command.target_id)}
      end
    }

    assert {:ok, _output} =
             HostCLI.evaluate(
               ["target", "activate", "my-target", "--mode", "watch"],
               deps
             )

    assert_received {:lifecycle_plan, :activate, %Command.Activate{target_id: "my-target", dispatch_mode: :watch}}

    for {action, module} <- [
          {:pause, Command.Pause},
          {:drain, Command.Drain},
          {:retire, Command.Retire}
        ] do
      assert {:ok, _output} =
               HostCLI.evaluate(["target", Atom.to_string(action), "my-target"], deps)

      assert_received {:lifecycle_plan, ^action, command}
      assert command.__struct__ == module
      assert command.target_id == "my-target"
    end
  end

  test "lifecycle confirmations bind the exact action" do
    parent = self()
    plan_id = String.duplicate("a", 64)

    for action <- [:activate, :pause, :drain, :retire] do
      deps = %{
        confirm_action: fn target_id, supplied_id, supplied_action, confirmation, opts ->
          send(
            parent,
            {:lifecycle_confirm, target_id, supplied_id, supplied_action, confirmation, opts}
          )

          {:ok, sample_apply_result(action, supplied_id, default_registry_path())}
        end
      }

      assert {:ok, output} =
               HostCLI.evaluate(
                 ["target", Atom.to_string(action), "my-target", "--confirm", plan_id],
                 deps
               )

      assert_received {:lifecycle_confirm, "my-target", ^plan_id, ^action, true, []}
      assert output =~ "Apply #{action} for my-target"
    end
  end

  test "lifecycle grammar rejects invalid mode and mixed preview confirmation" do
    plan_id = String.duplicate("a", 64)
    deps = forbidden_deps()

    for args <- [
          ["target", "activate", "my-target", "--mode", "automatic"],
          ["target", "activate", "my-target", "--mode", "watch", "--confirm", plan_id],
          ["target", "pause", "my-target", "--mode", "watch"]
        ] do
      assert {:error, usage} = HostCLI.evaluate(args, deps)
      assert usage =~ "Usage:"
      refute_received :plan_called
      refute_received :confirm_action_called
    end
  end

  test "lifecycle preview output is deterministic and redacted in text and json" do
    secret = "ghp_1234567890abcdef"

    plan = %{
      sample_plan(:activate, "my-target")
      | id: String.duplicate("a", 64),
        applicable?: true,
        preview: %{"registry" => %{"token" => secret, "state" => "active"}}
    }

    for json? <- [false, true] do
      args = ["target", "activate", "my-target", "--mode", "watch"]
      args = if json?, do: args ++ ["--json"], else: args

      assert {:ok, first} = HostCLI.evaluate(args, preview_deps(plan))
      assert {:ok, second} = HostCLI.evaluate(args, preview_deps(plan))
      assert first == second
      refute first =~ secret
      assert first =~ "[REDACTED]"
      if json?, do: assert(valid_json?(first))
    end
  end

  test "all preview commands reject a plan bound to another registry in text and json" do
    wrong_path = "/wrong-registry-secret.yml"

    for {action, args} <- preview_cases(), json? <- [false, true] do
      plan = %{sample_plan(action, "my-target") | registry_path: wrong_path}
      args = if json?, do: args ++ ["--json"], else: args

      assert {:error, error} = HostCLI.evaluate(args, preview_deps(plan))

      if json? do
        assert valid_json?(error)
        assert Jason.decode!(error)["code"] == "plan_validation_failed"
      else
        assert error == "plan_validation_failed"
      end

      refute error =~ wrong_path
      refute error =~ "Plan #{action}"
    end
  end

  test "all confirmations reject an apply result bound to another registry in text and json" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"
    wrong_path = "/wrong-registry-secret.yml"

    for {action, args} <- confirm_cases(plan_id), json? <- [false, true] do
      deps = %{
        confirm_action: fn _target_id, _plan_id, _action, _confirmation, _opts ->
          {:ok, sample_apply_result(action, plan_id, wrong_path)}
        end
      }

      args = if json?, do: args ++ ["--json"], else: args
      assert {:error, error} = HostCLI.evaluate(args, deps)

      if json? do
        assert valid_json?(error)
        assert Jason.decode!(error)["code"] == "apply_result_validation_failed"
      else
        assert error == "apply_result_validation_failed"
      end

      refute error =~ wrong_path
      refute error =~ "Apply #{action}"
    end
  end

  test "apply results require committed and consumed success invariants in text and json" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"
    args = ["target", "add", "my-target", "--confirm", plan_id]

    for field <- [:committed?, :plan_consumed?], json? <- [false, true] do
      result = Map.put(sample_apply_result(:add, plan_id, default_registry_path()), field, false)

      deps = %{
        confirm_action: fn _target_id, _plan_id, _action, _confirmation, _opts ->
          {:ok, result}
        end
      }

      public_args = if json?, do: args ++ ["--json"], else: args
      assert {:error, error} = HostCLI.evaluate(public_args, deps)

      if json? do
        assert valid_json?(error)
        assert Jason.decode!(error)["code"] == "apply_result_validation_failed"
      else
        assert error == "apply_result_validation_failed"
      end

      refute error =~ "committed:"
      refute error =~ "plan consumed:"
    end
  end

  test "injected preview and apply results accept default and expanded custom registry paths" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"
    custom_arg = "custom/registry.yml"

    for {registry_args, registry_path} <- [
          {[], default_registry_path()},
          {["--registry", custom_arg], Path.expand(custom_arg)}
        ] do
      plan_args = ["target", "add", "my-target", "--input", "target.yml"] ++ registry_args
      plan = sample_plan(:add, "my-target", registry_path)
      assert {:ok, plan_output} = HostCLI.evaluate(plan_args, preview_deps(plan))
      assert plan_output =~ "registry path: #{registry_path}"

      apply_args = ["target", "add", "my-target", "--confirm", plan_id] ++ registry_args

      deps = %{
        confirm_action: fn _target_id, _plan_id, _action, _confirmation, _opts ->
          {:ok, sample_apply_result(:add, plan_id, registry_path)}
        end
      }

      assert {:ok, apply_output} = HostCLI.evaluate(apply_args, deps)
      assert apply_output =~ "registry path: #{registry_path}"
    end
  end

  test "confirm_action mismatch error propagates without reaching mutation" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:error,
         %OperatorCommandService.Error{
           code: :plan_mismatch,
           message: "plan action does not match command",
           path: "$.plan"
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error =~ "plan_mismatch"
    assert error =~ "action does not match"
  end

  test "malformed yaml decode returns stable error" do
    deps = %{
      read_file: fn _path -> {:ok, "bad yaml"} end,
      yaml_decode: fn _content ->
        {:error, %{code: :invalid_yaml, message: "invalid YAML"}}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error =~ "invalid_yaml"
    assert error =~ "invalid YAML"
  end

  test "plan dependency raise is contained as fixed error without leaking exception text" do
    deps = %{
      plan: fn _cmd, _opts -> raise "secret_boom_token=sk-abc123" end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    refute error =~ "secret_boom_token"
    refute error =~ "sk-abc123"
    refute error =~ "raise"
    refute error =~ "%RuntimeError"
    assert error == "plan_dependency_failed"
  end

  test "plan dependency throw is contained as fixed error without leak" do
    deps = %{
      plan: fn _cmd, _opts -> throw({:bad, "secret"}) end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    refute error =~ "secret"
    assert error == "plan_dependency_failed"
  end

  test "plan dependency malformed return is contained as fixed error" do
    deps = %{
      plan: fn _cmd, _opts -> :ok end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_dependency_failed"
    refute_received :plan_called
  end

  test "plan dependency non-struct success is contained as fixed error" do
    deps = %{
      plan: fn _cmd, _opts -> {:ok, %{}} end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_dependency_failed"
  end

  test "confirm_action dependency raise is contained as fixed error without leaking exception text" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts -> raise "confirm_secret_boom" end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    refute error =~ "confirm_secret_boom"
    refute error =~ "raise"
    assert error == "confirm_action_failed"
  end

  test "confirm_action dependency throw is contained as fixed error without leak" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts -> throw({:bad, "secret"}) end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    refute error =~ "secret"
    assert error == "confirm_action_failed"
  end

  test "confirm_action dependency malformed return is contained as fixed error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts -> :ok end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "confirm_action_failed"
  end

  test "confirm_action dependency non-struct success is contained as fixed error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts -> {:ok, %{}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "confirm_action_failed"
  end

  test "read_file failures are fixed and sentinel-free at text and json public boundaries" do
    sentinel = "api_key=sk-SID406-READER-SENTINEL"

    outcomes = [
      binary_reason: fn -> {:error, sentinel} end,
      non_binary_reason: fn -> {:error, %{credential: sentinel}} end,
      raise: fn -> raise sentinel end,
      throw: fn -> throw({:credential, sentinel}) end,
      malformed: fn -> {:ok, sentinel, :unexpected} end
    ]

    for {_name, outcome} <- outcomes, json? <- [false, true] do
      deps = %{read_file: fn _path -> outcome.() end}
      args = ["target", "add", "my-target", "--input", "target.yml"]
      args = if json?, do: args ++ ["--json"], else: args

      assert {:error, error} = HostCLI.evaluate(args, deps)
      refute error =~ sentinel

      if json? do
        assert valid_json?(error)
        decoded = Jason.decode!(error)
        assert decoded["code"] == "file_read_failed"
        assert decoded["message"] == "File read failed"
        assert decoded["usage"] =~ "symphony host target add"
      else
        assert error == "file_read_failed"
      end
    end
  end

  test "ordinary missing file is a stable safe error in text and json modes" do
    missing_path =
      Path.join(System.tmp_dir!(), "missing-host-cli-#{System.unique_integer([:positive])}.yml")

    for json? <- [false, true] do
      args = ["target", "add", "my-target", "--input", missing_path]
      args = if json?, do: args ++ ["--json"], else: args

      assert {:error, error} = HostCLI.evaluate(args)

      if json? do
        assert valid_json?(error)
        assert Jason.decode!(error)["code"] == "file_read_failed"
      else
        assert error == "file_read_failed"
      end
    end
  end

  test "yaml_decode raise is contained as fixed error without leaking reason" do
    deps = %{
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> raise "secret_yaml" end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    refute error =~ "secret_yaml"
    refute error =~ "raise"
    assert error == "yaml_decode_failed"
  end

  test "yaml_decode throw is contained as fixed error without leaking reason" do
    deps = %{
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> throw({:bad, "secret"}) end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    refute error =~ "secret"
    assert error == "yaml_decode_failed"
  end

  test "yaml_decode malformed return is contained as fixed error" do
    deps = %{
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> :ok end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "yaml_decode_failed"
  end

  test "invalid plan id returns error without calling confirm" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", "short-id"], deps)

    assert error =~ "invalid plan ID"
    refute_received :confirm_action_called
  end

  test "target add command-specific help returns add usage as success without deps" do
    deps = forbidden_deps()
    assert {:ok, usage} = HostCLI.evaluate(["target", "add", "--help"], deps)
    assert usage =~ "symphony host target add"
    assert usage =~ "--input"
    assert usage =~ "--confirm"
    refute_received :plan_called
    refute_received :confirm_action_called
  end

  test "target import command-specific help returns import usage as success without deps" do
    deps = forbidden_deps()
    assert {:ok, usage} = HostCLI.evaluate(["target", "import", "--help"], deps)
    assert usage =~ "symphony host target import"
    assert usage =~ "--workflow"
    assert usage =~ "--repo"
    refute_received :plan_called
    refute_received :confirm_action_called
  end

  test "target plan command-specific help returns plan usage as success without deps" do
    deps = forbidden_deps()
    assert {:ok, usage} = HostCLI.evaluate(["target", "plan", "--help"], deps)
    assert usage =~ "symphony host target plan"
    assert usage =~ "--patch"
    refute_received :plan_called
    refute_received :confirm_action_called
  end

  test "target patch command-specific help returns patch usage as success without deps" do
    deps = forbidden_deps()
    assert {:ok, usage} = HostCLI.evaluate(["target", "patch", "--help"], deps)
    assert usage =~ "symphony host target patch"
    assert usage =~ "--confirm"
    refute_received :plan_called
    refute_received :confirm_action_called
  end

  test "add preview with non-map yaml root returns fixed error" do
    deps = %{
      read_file: fn _path -> {:ok, "- a\n- b"} end,
      yaml_decode: fn _content -> {:ok, ["a", "b"]} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "yaml_decode_failed"
  end

  test "add preview rejects full registry envelope keys without calling plan" do
    deps = %{
      read_file: fn _path -> {:ok, "version: 1\nhost: {}"} end,
      yaml_decode: fn _content -> {:ok, %{"version" => 1, "host" => %{}}} end,
      plan: fn _cmd, _opts ->
        send(self(), :plan_called)
        {:ok, sample_plan(:add, "my-target")}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "invalid_target_input"
    refute_received :plan_called
  end

  test "add preview rejects unknown root key without calling plan" do
    deps = %{
      read_file: fn _path -> {:ok, "unknown: value"} end,
      yaml_decode: fn _content -> {:ok, %{"unknown" => "value"}} end,
      plan: fn _cmd, _opts ->
        send(self(), :plan_called)
        {:ok, sample_plan(:add, "my-target")}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "invalid_target_input"
    refute_received :plan_called
  end

  test "add preview rejects non-string key without calling plan" do
    deps = %{
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test", :bad => 1}} end,
      plan: fn _cmd, _opts ->
        send(self(), :plan_called)
        {:ok, sample_plan(:add, "my-target")}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    # Non-string keys are caught by the total yaml_decode adapter
    assert error == "yaml_decode_failed"
    refute_received :plan_called
  end

  test "add preview accepts valid target root keys" do
    parent = self()

    deps = %{
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content ->
        {:ok,
         %{
           "display_name" => "test",
           "repo" => %{"path" => "/repo"},
           "worktree" => %{"root" => "/wt"},
           "linear" => %{"connection" => "conn"},
           "runners" => %{"allowed" => ["codex"]},
           "concurrency" => %{"max_concurrent_agents" => 2},
           "budgets" => %{"per_run" => %{"max_total_tokens" => 1000}},
           "checks" => %{"pre_dispatch" => []},
           "external_side_effects" => %{"tracker_write" => "deny"},
           "scheduling" => %{"weight" => 1}
         }}
      end,
      plan: fn cmd, _opts ->
        send(parent, {:plan, cmd})
        {:ok, sample_plan(:add, "my-target")}
      end
    }

    assert {:ok, _output} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert_received {:plan, cmd}
    assert %Command.Add{target: target} = cmd
    assert target["display_name"] == "test"
  end

  test "plan preview rejects host-shaped map without calling plan" do
    deps = %{
      read_file: fn _path -> {:ok, "id: host-1"} end,
      yaml_decode: fn _content -> {:ok, %{"id" => "host-1"}} end,
      plan: fn _cmd, _opts ->
        send(self(), :plan_called)
        {:ok, sample_plan(:patch, "my-target")}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "plan", "my-target", "--patch", "patch.yml"], deps)

    assert error == "invalid_target_input"
    refute_received :plan_called
  end

  test "apply failure returns concise stable error without inspect on secrets" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:error,
         %OperatorCommandService.Error{
           code: :plan_mismatch,
           message: "plan envelope does not match",
           path: "$.plan"
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error =~ "plan_mismatch"
    assert error =~ "plan envelope does not match"
    refute error =~ "%SymphonyElixir.OperatorCommandService.Error"
  end

  test "json encode failure at public boundary returns valid json error envelope" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok, sample_plan(:add, "my-target")}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end,
      json_encode: fn _value ->
        {:error, :encoding_failed}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "json_encoding_failed"
    refute error =~ "inspect"
  end

  test "json encode raise returns valid json hardcoded fallback without secret leak" do
    deps = %{
      plan: fn _cmd, _opts -> {:ok, sample_plan(:add, "my-target")} end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end,
      json_encode: fn _value -> raise "secret_token=sk-proj-abc123xyz" end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "json_encoding_failed"
    refute error =~ "sk-proj-abc123xyz"
    refute error =~ "secret_token"
    refute error =~ "raise"
    refute error =~ "%RuntimeError"
  end

  test "json encode throw returns valid json hardcoded fallback without secret leak" do
    deps = %{
      plan: fn _cmd, _opts -> {:ok, sample_plan(:add, "my-target")} end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end,
      json_encode: fn _value -> throw({:bad, "secret=ghp_abcdef123456"}) end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "json_encoding_failed"
    refute error =~ "ghp_abcdef123456"
    refute error =~ "bad"
    refute error =~ "throw"
  end

  test "json encode malformed return returns valid json hardcoded fallback" do
    deps = %{
      plan: fn _cmd, _opts -> {:ok, sample_plan(:add, "my-target")} end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end,
      json_encode: fn _value -> :ok end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "json_encoding_failed"
  end

  test "json encode with credential-shaped reason returns valid json hardcoded fallback" do
    deps = %{
      plan: fn _cmd, _opts -> {:ok, sample_plan(:add, "my-target")} end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end,
      json_encode: fn _value ->
        {:error, %{secret: "bearer ghp_xxxxxxxxxxxx", password: "hunter2"}}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "json_encoding_failed"
    refute error =~ "ghp_xxxxxxxxxxxx"
    refute error =~ "hunter2"
    refute error =~ "bearer"
    refute error =~ "password"
  end

  test "target add parse error in json mode returns valid json envelope with usage" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "invalid_arguments"
    assert decoded["usage"] =~ "symphony host target add"
  end

  test "target add invalid plan id in json mode returns valid json envelope" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", "short-id", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "invalid plan ID"
    assert decoded["message"] =~ "Invalid plan ID"
  end

  test "target add file read failure in json mode returns valid json envelope" do
    deps = %{
      read_file: fn _path -> raise "secret" end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end,
      plan: fn _cmd, _opts -> {:ok, sample_plan(:add, "my-target")} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "file_read_failed"
  end

  test "target add service error in json mode returns valid json envelope with redacted message" do
    deps = %{
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end,
      plan: fn _cmd, _opts ->
        {:error,
         %OperatorCommandService.Error{
           code: :plan_mismatch,
           message: "plan envelope does not match",
           path: "$.plan"
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "plan_mismatch"
    assert decoded["message"] =~ "plan envelope does not match"
    assert decoded["usage"] =~ "symphony host target add"
  end

  test "target add yaml decode failure in json mode returns valid json envelope" do
    deps = %{
      read_file: fn _path -> {:ok, "bad yaml"} end,
      yaml_decode: fn _content ->
        {:error, %{code: :invalid_yaml, message: "invalid YAML"}}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "invalid_yaml"
    assert decoded["message"] =~ "invalid YAML"
  end

  test "target patch confirm with missing confirm in json mode returns valid json envelope" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(["target", "patch", "my-target", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "invalid_arguments"
    assert decoded["usage"] =~ "symphony host target patch"
  end

  test "target plan parse error in json mode returns valid json envelope with usage" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(["target", "plan", "my-target", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "invalid_arguments"
    assert decoded["usage"] =~ "symphony host target plan"
  end

  test "plan with mismatched action returns fixed redacted error without crash or leak" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :patch,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    refute error =~ "patch"
    refute error =~ "plan-id-1"
    assert error == "plan_validation_failed"
  end

  test "plan with mismatched target returns fixed redacted error without leak" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "wrong-target",
           registry_path: "/registry.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    refute error =~ "wrong-target"
    assert error == "plan_validation_failed"
  end

  test "plan with malformed generation returns fixed redacted error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "bad-gen",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    refute error =~ "bad-gen"
    assert error == "plan_validation_failed"
  end

  test "plan with nil expected_generation returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: nil,
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with pid expected_generation returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: self(),
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with function expected_generation returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: fn -> :ok end,
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with reference expected_generation returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: make_ref(),
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with malformed binary expected_generation returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "bad-gen",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with nil proposed_generation returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: nil,
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with pid proposed_generation returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: self(),
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "apply result with nil old_generation returns fixed validation error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: plan_id,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: nil,
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "apply_result_validation_failed"
  end

  test "apply result with pid old_generation returns fixed validation error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: plan_id,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: self(),
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "apply_result_validation_failed"
  end

  test "apply result with function old_generation returns fixed validation error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: plan_id,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: fn -> :ok end,
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "apply_result_validation_failed"
  end

  test "apply result with reference old_generation returns fixed validation error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: plan_id,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: make_ref(),
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "apply_result_validation_failed"
  end

  test "apply result with malformed binary old_generation returns fixed validation error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: plan_id,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: "bad-gen",
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "apply_result_validation_failed"
  end

  test "apply result with nil new_generation returns fixed validation error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: plan_id,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: nil,
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "apply_result_validation_failed"
  end

  test "apply result with pid new_generation returns fixed validation error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: plan_id,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: self(),
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "apply_result_validation_failed"
  end

  test "apply result with function new_generation returns fixed validation error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: plan_id,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: fn -> :ok end,
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "apply_result_validation_failed"
  end

  test "apply result with reference new_generation returns fixed validation error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: plan_id,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: make_ref(),
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "apply_result_validation_failed"
  end

  test "apply result with malformed binary new_generation returns fixed validation error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: plan_id,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: "bad-gen",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "apply_result_validation_failed"
  end

  test "plan with uppercase plan id returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: "ABC123ABC123ABC123ABC123ABC123ABC123ABC123ABC123ABC123ABC123ABC1",
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with short plan id returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: "short-id",
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "apply result with short plan id returns fixed validation error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: "short-id",
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "apply_result_validation_failed"
  end

  test "apply result with uppercase plan id returns fixed validation error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: "ABC123ABC123ABC123ABC123ABC123ABC123ABC123ABC123ABC123ABC123ABC1",
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "apply_result_validation_failed"
  end

  test "apply result with non-binary plan id returns fixed validation error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: self(),
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "apply_result_validation_failed"
  end

  test "plan with nil registry path returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: nil,
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with empty registry path returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with relative registry path returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "relative/path.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with trimmed registry path returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: " /absolute/path.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with invalid utf8 created_at returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: <<0xFF, 0xFE>>
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with non-utc offset created_at returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00+01:00"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with malformed created_at returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "not-a-date"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "text error with bearer-shaped message is redacted before interpolation" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:error,
         %OperatorCommandService.Error{
           code: :auth_failed,
           message: "bearer ghp_abcdef123456"
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error =~ "auth_failed"
    refute error =~ "ghp_abcdef123456"
  end

  test "text error with password-shaped message is redacted before interpolation" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:error,
         %OperatorCommandService.Error{
           code: :auth_failed,
           message: "password: hunter2"
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error =~ "auth_failed"
    refute error =~ "hunter2"
  end

  test "text error with private key message is redacted before interpolation" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:error,
         %OperatorCommandService.Error{
           code: :auth_failed,
           message: "-----BEGIN PRIVATE KEY-----\nMIIE...\n-----END PRIVATE KEY-----"
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error =~ "auth_failed"
    refute error =~ "PRIVATE KEY"
    refute error =~ "MIIE"
  end

  test "text error with invalid utf8 message uses fixed safe message" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:error,
         %OperatorCommandService.Error{
           code: :auth_failed,
           message: <<0xFF, 0xFE>>
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error == "auth_failed: [REDACTED]"
  end

  test "json error with bearer-shaped message is redacted in valid json envelope" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:error,
         %OperatorCommandService.Error{
           code: :auth_failed,
           message: "bearer ghp_abcdef123456"
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id, "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "auth_failed"
    refute decoded["message"] =~ "ghp_abcdef123456"
  end

  test "json error with invalid utf8 message produces valid json envelope" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:error,
         %OperatorCommandService.Error{
           code: :auth_failed,
           message: <<0xFF, 0xFE>>
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id, "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "auth_failed"
    assert decoded["message"] == "[REDACTED]"
  end

  test "json error envelope normalizes unknown binary reason to stable code" do
    deps = %{
      plan: fn _cmd, _opts -> raise "secret" end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "plan_dependency_failed"
    assert decoded["message"] == "Plan dependency failed"
  end

  test "json error envelope preserves known reason as stable code and message" do
    deps = %{
      read_file: fn _path -> raise "secret" end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "file_read_failed"
    assert decoded["message"] == "File read failed"
  end

  test "whole projection redacts secrets in non-preview fields" do
    parent = self()

    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: default_registry_path(),
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"message" => "ok"},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end,
      json_encode: fn value ->
        send(parent, {:json_encode, value})
        Jason.encode(value)
      end
    }

    assert {:ok, json} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert_received {:json_encode, payload}
    assert payload["target_id"] == "my-target"
    assert payload["preview"]["message"] == "ok"
    decoded = Jason.decode!(json)
    assert decoded["target_id"] == "my-target"
  end

  test "target add with invalid runner assignment form returns usage without calling plan" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--workflow",
                 "/wf.yml",
                 "--repo",
                 "/repo",
                 "--runner=a=b"
               ],
               deps
             )

    assert error =~ "symphony host target import"
    refute_received :plan_called
    refute_received :read_file_called
    refute_received :yaml_decode_called
  end

  test "target add with multiple separate runner flags is allowed" do
    parent = self()

    deps = %{
      plan: fn cmd, _opts ->
        send(parent, {:plan, cmd})
        {:ok, sample_plan(:import, cmd.target_id)}
      end
    }

    assert {:ok, _output} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--workflow",
                 "/wf.yml",
                 "--repo",
                 "/repo",
                 "--runner",
                 "a=b",
                 "--runner",
                 "c=d"
               ],
               deps
             )

    assert_received {:plan, cmd}
    assert cmd.runner_ids == %{"a" => "b", "c" => "d"}
  end

  test "plan with non-boolean applicable returns fixed redacted error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: "yes",
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "apply result with mismatched plan id returns fixed redacted error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: "wrong-plan-id",
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    refute error =~ "wrong-plan-id"
    assert error == "apply_result_validation_failed"
  end

  test "text plan output includes all public fields in fixed order" do
    registry_path = default_registry_path()

    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: registry_path,
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:ok, output} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    expected =
      """
      Plan add for my-target
        operation: add
        target: my-target
        plan ID: (not applicable)
        applicable: false
        expected generation: sha256:0000000000000000000000000000000000000000000000000000000000000000
        proposed generation: sha256:1111111111111111111111111111111111111111111111111111111111111111
        registry path: #{registry_path}
        created at: 2026-01-01T00:00:00Z
        Note: confirmation changes registry state; running hosts adopt only a later fully verified generation.
      """
      |> String.trim()

    assert output == expected
  end

  test "text plan output for nil id shows not applicable" do
    registry_path = default_registry_path()

    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :patch,
           target_id: "my-target",
           registry_path: registry_path,
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:ok, output} =
             HostCLI.evaluate(["target", "plan", "my-target", "--patch", "patch.yml"], deps)

    assert output =~ "plan ID: (not applicable)"
    assert output =~ "registry path: #{registry_path}"
    assert output =~ "created at: 2026-01-01T00:00:00Z"
  end

  test "text apply output includes all public fields in fixed order" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"
    registry_path = default_registry_path()

    deps = %{
      confirm_action: fn _tid, pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: pid,
           action: :add,
           target_id: "my-target",
           registry_path: registry_path,
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:ok, output} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    expected =
      """
      Apply add for my-target
        plan ID: #{plan_id}
        registry path: #{registry_path}
        action: add
        target: my-target
        committed: true
        plan consumed: true
        old generation: sha256:0000000000000000000000000000000000000000000000000000000000000000
        new generation: sha256:1111111111111111111111111111111111111111111111111111111111111111
      """
      |> String.trim()

    assert output == expected
  end

  test "json success output is redacted before encoding" do
    parent = self()

    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: default_registry_path(),
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"message" => "bearer ghp_abcdef123"},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end,
      json_encode: fn value ->
        send(parent, {:json_encode, value})
        Jason.encode(value)
      end
    }

    assert {:ok, json} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert_received {:json_encode, payload}
    assert is_map(payload)
    assert payload["preview"]["message"] == "bearer [REDACTED]"
    decoded = Jason.decode!(json)
    assert decoded["preview"]["message"] == "bearer [REDACTED]"
  end

  test "runner mapping errors use fixed indexed messages without leaking raw values" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--workflow",
                 "/wf.yml",
                 "--repo",
                 "/repo",
                 "--runner",
                 "bad-mapping"
               ],
               deps
             )

    assert error =~ "invalid runner mapping at occurrence 1"
    refute error =~ "bad-mapping"
  end

  test "runner source validation uses fixed indexed message without leaking raw value" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--workflow",
                 "/wf.yml",
                 "--repo",
                 "/repo",
                 "--runner",
                 "bad_source=valid"
               ],
               deps
             )

    assert error =~ "invalid runner source at occurrence 1"
    refute error =~ "bad_source"
  end

  test "apply json encode raise returns valid json hardcoded fallback without leak" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: plan_id,
           action: :add,
           target_id: "my-target",
           registry_path: default_registry_path(),
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end,
      json_encode: fn _value -> raise "apply secret" end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id, "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "json_encoding_failed"
    refute error =~ "apply secret"
  end

  test "unknown target subcommand returns host usage without invoking dependencies" do
    deps = forbidden_deps()

    assert {:error, usage} = HostCLI.evaluate(["target", "unknown"], deps)
    assert usage == host_usage()
    refute_received :plan_called
    refute_received :confirm_action_called
  end

  test "target add parse error with --json returns json error envelope" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--json", "--unknown"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "invalid_arguments"
    assert decoded["usage"] =~ "symphony host target add"
  end

  test "target import parse error with --json returns json error envelope" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(
               ["target", "import", "my-target", "--workflow", "w.yml", "--repo", "/repo", "--json", "--unknown"],
               deps
             )

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "invalid_arguments"
    assert decoded["usage"] =~ "symphony host target import"
  end

  test "target import invalid mode with --json returns json error envelope" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(["target", "import", "my-target", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "invalid_arguments"
    assert decoded["usage"] =~ "symphony host target import"
  end

  test "target import confirm error path invokes format_host_error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:error,
         %OperatorCommandService.Error{
           code: :plan_not_found,
           message: "plan not found",
           path: "$.plan"
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "import", "my-target", "--confirm", plan_id], deps)

    assert error =~ "plan_not_found"
    assert error =~ "plan not found"
  end

  test "target patch confirm error path invokes format_host_error" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:error,
         %OperatorCommandService.Error{
           code: :plan_not_found,
           message: "plan not found",
           path: "$.plan"
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "patch", "my-target", "--confirm", plan_id], deps)

    assert error =~ "plan_not_found"
    assert error =~ "plan not found"
  end

  test "runner mapping with invalid id returns fixed indexed message" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--workflow",
                 "/wf.yml",
                 "--repo",
                 "/repo",
                 "--runner",
                 "valid=bad_id"
               ],
               deps
             )

    assert error =~ "invalid runner id at occurrence 1"
    refute error =~ "bad_id"
  end

  test "runner mapping with duplicate id returns fixed indexed message" do
    deps = forbidden_deps()

    assert {:error, error} =
             HostCLI.evaluate(
               [
                 "target",
                 "import",
                 "my-target",
                 "--workflow",
                 "/wf.yml",
                 "--repo",
                 "/repo",
                 "--runner",
                 "a=x",
                 "--runner",
                 "b=x"
               ],
               deps
             )

    assert error =~ "duplicate runner id at occurrence 2"
    refute error =~ "x"
  end

  test "preview with nested list renders deterministically" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: default_registry_path(),
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"diagnostics" => [%{"message" => "a"}, %{"message" => "b"}]},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:ok, output} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert output =~ "preview:"
    assert output =~ "[0]:"
    assert output =~ "[1]:"
    assert output =~ "message: \"a\""
    assert output =~ "message: \"b\""
  end

  test "preview with pid value returns fixed validation error in text mode" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/r.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"message" => self()},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
    refute error =~ "(unformattable)"
  end

  test "preview with pid value returns fixed validation error in json mode" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/r.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"message" => self()},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "plan_validation_failed"
  end

  test "preview with function value returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/r.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"message" => fn -> :ok end},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "preview with reference value returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/r.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"message" => make_ref()},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "preview with tuple value returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/r.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"message" => {1, 2}},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "preview with improper list returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/r.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"items" => [1 | 2]},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "preview with atom key returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/r.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{:bad => "value"},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "preview with invalid utf8 map key returns fixed validation error" do
    invalid_key = <<0xFF, 0xFE>>

    deps =
      preview_deps(%{
        sample_plan(:add, "my-target")
        | preview: %{invalid_key => "value"}
      })

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "preview with invalid utf8 string returns fixed validation error" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/r.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"message" => <<0xFF, 0xFE>>},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "preview list item with nested map renders with newline split" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: default_registry_path(),
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"diagnostics" => [%{"id" => "1", "state" => "ok"}]},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:ok, output} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert output =~ "[0]:"
    assert output =~ "id: \"1\""
    assert output =~ "state: \"ok\""
  end

  test "default confirm action with missing plan file returns error via public api" do
    tmp_dir = Path.join(System.tmp_dir!(), "host_cli_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    plan_dir = Path.join(tmp_dir, "target-plans")
    registry_path = Path.join(tmp_dir, "registry.yml")
    File.mkdir_p!(plan_dir)
    File.chmod!(plan_dir, 0o700)
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(
               ["target", "add", "my-target", "--confirm", plan_id, "--registry", registry_path],
               deps
             )

    assert error =~ "plan_not_found"
    refute error =~ "confirm_action_failed"
    refute error =~ File.cwd!()
    refute error =~ System.tmp_dir!()
  end

  test "default confirm action with mismatched envelope action returns plan mismatch" do
    tmp_dir = Path.join(System.tmp_dir!(), "host_cli_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    plan_dir = Path.join(tmp_dir, "target-plans")
    registry_path = Path.join(tmp_dir, "registry.yml")
    File.mkdir_p!(plan_dir)
    File.chmod!(plan_dir, 0o700)

    fields = %{
      "action" => "import",
      "command" => %{},
      "created_at" => "2026-01-01T00:00:00Z",
      "envelope_version" => 1,
      "expected_generation" => "sha256:0000000000000000000000000000000000000000000000000000000000000000",
      "registry_path" => registry_path,
      "source_hashes" => %{},
      "target_id" => "my-target"
    }

    {:ok, envelope} = PlanStore.build(fields, "dummy")
    plan_id = envelope["plan_id"]

    {:ok, _} = PlanStore.store(plan_dir, envelope)

    deps = %{
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(
               ["target", "add", "my-target", "--confirm", plan_id, "--registry", registry_path],
               deps
             )

    assert error =~ "plan_mismatch"
    assert error =~ "plan envelope does not match command"
  end

  test "default confirm action with mismatched target_id returns plan mismatch" do
    tmp_dir = Path.join(System.tmp_dir!(), "host_cli_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    plan_dir = Path.join(tmp_dir, "target-plans")
    registry_path = Path.join(tmp_dir, "registry.yml")
    File.mkdir_p!(plan_dir)
    File.chmod!(plan_dir, 0o700)

    fields = %{
      "action" => "add",
      "command" => %{},
      "created_at" => "2026-01-01T00:00:00Z",
      "envelope_version" => 1,
      "expected_generation" => "sha256:0000000000000000000000000000000000000000000000000000000000000000",
      "registry_path" => registry_path,
      "source_hashes" => %{},
      "target_id" => "wrong-target"
    }

    {:ok, envelope} = PlanStore.build(fields, "dummy")
    plan_id = envelope["plan_id"]

    {:ok, _} = PlanStore.store(plan_dir, envelope)

    deps = %{
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(
               ["target", "add", "my-target", "--confirm", plan_id, "--registry", registry_path],
               deps
             )

    assert error =~ "plan_mismatch"
    assert error =~ "plan envelope does not match command"
  end

  test "default confirm action rejects a plan bound to another registry before confirmation" do
    tmp_dir = Path.join(System.tmp_dir!(), "host_cli_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    plan_dir = Path.join(tmp_dir, "target-plans")
    requested_registry_path = Path.join(tmp_dir, "registry.yml")
    other_registry_path = Path.join(tmp_dir, "other.yml")
    File.mkdir_p!(plan_dir)
    File.chmod!(plan_dir, 0o700)

    fields = %{
      "action" => "add",
      "command" => %{},
      "created_at" => "2026-01-01T00:00:00Z",
      "envelope_version" => 1,
      "expected_generation" => "sha256:0000000000000000000000000000000000000000000000000000000000000000",
      "registry_path" => other_registry_path,
      "source_hashes" => %{},
      "target_id" => "my-target"
    }

    {:ok, envelope} = PlanStore.build(fields, "dummy")
    plan_id = envelope["plan_id"]
    {:ok, _} = PlanStore.store(plan_dir, envelope)
    parent = self()

    deps = %{
      confirm: fn _target_id, _plan_id, _confirmation, _opts ->
        send(parent, :confirm_called)
        {:error, %OperatorCommandService.Error{code: :plan_expired, message: "plan expired"}}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(
               [
                 "target",
                 "add",
                 "my-target",
                 "--confirm",
                 plan_id,
                 "--registry",
                 requested_registry_path
               ],
               deps
             )

    assert error =~ "plan_mismatch"
    assert error =~ "plan envelope does not match command"
    refute_received :confirm_called
  end

  test "default confirm action with real plan applies patch and consumes envelope" do
    tmp_dir = Path.join(System.tmp_dir!(), "host_cli_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    File.mkdir_p!(tmp_dir)

    registry_path = Path.join(tmp_dir, "registry.yml")
    plan_dir = Path.join(tmp_dir, "target-plans")
    File.mkdir_p!(plan_dir)
    File.chmod!(plan_dir, 0o700)

    fixture_root = Path.expand("../fixtures/target_registry/repos/symphony", __DIR__)
    wt_dir = Path.join(System.tmp_dir!(), "host_cli_wt_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(wt_dir) end)
    File.mkdir_p!(wt_dir)

    document = %{
      "version" => 1,
      "host" => %{
        "id" => "test-host",
        "state_root" => "/tmp/state",
        "polling" => %{"interval_ms" => 30_000, "max_concurrent_target_polls" => 1},
        "capacity" => %{"max_concurrent_agents" => 4, "max_concurrent_startups" => 2, "max_concurrent_reviewers" => 1},
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 4},
        "tracker_connections" => %{
          "linear-main" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "$LINEAR_API_KEY"
          }
        },
        "runners" => %{
          "codex" => %{
            "kind" => "codex_app_server",
            "command" => ["codex", "app-server"],
            "max_concurrent_agents" => 4,
            "max_concurrent_startups" => 2
          }
        }
      },
      "targets" => %{
        "my-target" => %{
          "display_name" => "Original",
          "state" => "paused",
          "dispatch_mode" => "explicit",
          "repo" => %{"path" => fixture_root, "manifest" => "symphony.yml"},
          "worktree" => %{"root" => wt_dir, "strategy" => "per_issue", "hooks" => %{}},
          "linear" => %{
            "connection" => "linear-main",
            "scope" => %{"type" => "project", "project_id" => "project-1"},
            "active_states" => ["Todo"],
            "terminal_states" => ["Done"],
            "required_labels" => []
          },
          "runners" => %{"allowed" => ["codex"], "default" => "codex", "settings" => %{}},
          "concurrency" => %{"max_concurrent_agents" => 4, "max_concurrent_startups" => 2, "max_concurrent_reviewers" => 1, "by_linear_state" => %{}},
          "budgets" => %{"per_run" => %{"max_total_tokens" => 1000}, "daily" => %{"max_total_tokens" => 10_000}, "weekly" => %{"max_total_tokens" => 50_000}},
          "checks" => %{"pre_dispatch" => [], "pre_handoff" => [], "pre_publish" => [], "pre_merge" => []},
          "external_side_effects" => %{"tracker_write" => "deny", "vcs_publish" => "deny", "pull_request_write" => "deny", "merge" => "deny", "deployment" => "deny", "production_data" => "deny"},
          "scheduling" => %{"weight" => 10}
        }
      }
    }

    File.write!(registry_path, Yaml.encode(document))

    command = %Command.Patch{
      target_id: "my-target",
      changes: %{"display_name" => "Updated"}
    }

    assert {:ok, plan} = OperatorCommandService.plan(command, registry_path: registry_path)
    assert plan.action == :patch
    assert plan.applicable?
    assert plan.id != nil

    plan_id = plan.id

    # Invoke HostCLI default confirm with no injected confirmer
    assert {:ok, output} =
             HostCLI.evaluate(
               ["target", "patch", "my-target", "--confirm", plan_id, "--registry", registry_path],
               %{}
             )

    assert output =~ "Apply patch for my-target"
    assert output =~ "plan ID: #{plan_id}"
    assert output =~ "committed: true"
    assert output =~ "plan consumed: true"
    assert output =~ "old generation: #{plan.expected_generation}"
    assert output =~ "new generation: #{plan.proposed_generation}"

    # Assert registry mutation
    assert {:ok, updated_document} = registry_path |> File.read!() |> Yaml.decode()
    assert updated_document["targets"]["my-target"]["display_name"] == "Updated"

    # Assert plan consumption
    refute File.exists?(Path.join(plan_dir, plan_id <> ".json"))
  end

  test "default confirm action with invalid registry path returns confirm_action_failed" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, "confirm_action_failed"} =
             HostCLI.evaluate(
               ["target", "add", "my-target", "--confirm", plan_id, "--registry", ""],
               deps
             )
  end

  test "default confirm action without registry path uses LocalConfig defaults" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(
               ["target", "add", "my-target", "--confirm", plan_id],
               deps
             )

    assert error =~ "plan_corrupt"
    refute error =~ "confirm_action_failed"
    refute error =~ File.cwd!()
  end

  test "preview plan with non-binary plan_id fails validation" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok, %{sample_plan(:add, "my-target") | id: 12_345}}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error =~ "plan_validation_failed"
  end

  test "confirm action with non-binary plan_id in apply result fails validation" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:ok,
         %OperatorCommandService.ApplyResult{
           plan_id: 12_345,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           committed?: true,
           plan_consumed?: true
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id], deps)

    assert error =~ "apply_result_validation_failed"
  end

  test "preview plan with invalid utf8 registry_path fails validation" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok, %{sample_plan(:add, "my-target") | registry_path: <<0xFF, 0xFE>>}}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error =~ "plan_validation_failed"
  end

  test "preview plan with non-binary created_at fails validation" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok, %{sample_plan(:add, "my-target") | created_at: 12_345}}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error =~ "plan_validation_failed"
  end

  test "preview plan with deeply nested preview fails validation" do
    deep = Enum.reduce(1..35, "leaf", fn _, acc -> %{"k" => acc} end)

    deps = %{
      plan: fn _cmd, _opts ->
        {:ok, %{sample_plan(:add, "my-target") | preview: deep}}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error =~ "plan_validation_failed"
  end

  test "preview plan with too many preview nodes fails validation" do
    many = List.duplicate(true, 10_001)

    deps = %{
      plan: fn _cmd, _opts ->
        {:ok, %{sample_plan(:add, "my-target") | preview: many}}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error =~ "plan_validation_failed"
  end

  test "preview plan rejects scalar roots at text and json public boundaries" do
    for scalar <- [nil, true, false, 42, 3.14], json? <- [false, true] do
      deps = preview_deps(%{sample_plan(:add, "my-target") | preview: scalar})
      args = ["target", "add", "my-target", "--input", "target.yml"]
      args = if json?, do: args ++ ["--json"], else: args

      assert {:error, error} = HostCLI.evaluate(args, deps)

      if json? do
        assert valid_json?(error)
        assert Jason.decode!(error)["code"] == "plan_validation_failed"
      else
        assert error == "plan_validation_failed"
      end
    end
  end

  test "preview map keys accept the byte limit and reject one byte over" do
    valid_key = String.duplicate("k", @max_preview_key_bytes)
    oversized_key = valid_key <> "k"

    assert_preview_boundary(%{valid_key => true}, :accepted)
    assert_preview_boundary(%{oversized_key => true}, :rejected)
  end

  test "preview string leaves accept the byte limit and reject one byte over" do
    valid_leaf = String.duplicate("v", @max_preview_string_leaf_bytes)
    oversized_leaf = valid_leaf <> "v"

    assert_preview_boundary(%{"value" => valid_leaf}, :accepted)
    assert_preview_boundary(%{"value" => oversized_leaf}, :rejected)
  end

  test "preview aggregate bytes use one global budget across map branches" do
    value = String.duplicate("v", div(@max_preview_aggregate_bytes - 12, 4))

    at_limit = %{
      "a" => value,
      "b" => value,
      "c" => value,
      "d" => value
    }

    one_byte_over = Map.update!(at_limit, "d", &(&1 <> "v"))

    assert_preview_boundary(at_limit, :accepted)
    assert_preview_boundary(one_byte_over, :rejected)
  end

  test "preview rejects attacker-sized integers before text or json output" do
    huge_integer = :binary.decode_unsigned(:binary.copy(<<255>>, 450_000))

    assert_preview_boundary(%{"value" => huge_integer}, :rejected)
  end

  test "preview integer rendered bytes accept the aggregate boundary and reject one over" do
    value = String.duplicate("v", div(@max_preview_aggregate_bytes - 12, 4))
    integer_bytes_at_limit = 19
    at_limit = -Integer.pow(10, integer_bytes_at_limit - 2)

    preview = %{
      "a" => value,
      "b" => value,
      "c" => value,
      "d" => String.slice(value, 0, byte_size(value) - integer_bytes_at_limit - 1),
      "n" => at_limit
    }

    assert byte_size(Integer.to_string(at_limit)) == integer_bytes_at_limit
    assert_preview_boundary(preview, :accepted)
    assert_preview_boundary(Map.put(preview, "n", at_limit * 10), :rejected)
  end

  test "default confirm action with OperatorCommandService.Error returns stable error" do
    tmp_dir = Path.join(System.tmp_dir!(), "host_cli_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    plan_dir = Path.join(tmp_dir, "target-plans")
    registry_path = Path.join(tmp_dir, "registry.yml")
    File.mkdir_p!(plan_dir)
    File.chmod!(plan_dir, 0o700)

    fields = %{
      "action" => "add",
      "command" => %{},
      "created_at" => "2026-01-01T00:00:00Z",
      "envelope_version" => 1,
      "expected_generation" => "sha256:0000000000000000000000000000000000000000000000000000000000000000",
      "registry_path" => registry_path,
      "source_hashes" => %{},
      "target_id" => "my-target"
    }

    {:ok, envelope} = PlanStore.build(fields, "dummy")
    plan_id = envelope["plan_id"]

    {:ok, _} = PlanStore.store(plan_dir, envelope)

    deps = %{
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end,
      confirm: fn _tid, _pid, _conf, _opts ->
        {:error, %OperatorCommandService.Error{code: :plan_expired, message: "plan expired"}}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(
               ["target", "add", "my-target", "--confirm", plan_id, "--registry", registry_path],
               deps
             )

    assert error =~ "plan_expired"
    assert error =~ "plan expired"
  end

  test "json error envelope encoding fallback on error path" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok, %{sample_plan(:add, "my-target") | id: 12_345}}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end,
      json_encode: fn _value -> {:error, :encoding_failed} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "json_encoding_failed"
  end

  test "safe json encode with invalid json string returns hardcoded fallback" do
    deps = %{
      plan: fn _cmd, _opts -> {:ok, sample_plan(:add, "my-target")} end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end,
      json_encode: fn _value -> {:ok, "not json"} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "json_encoding_failed"
  end

  test "json error with non-binary message uses safe fallback" do
    plan_id = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1"

    deps = %{
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        {:error,
         %OperatorCommandService.Error{
           code: :auth_failed,
           message: 12_345
         }}
      end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--confirm", plan_id, "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "auth_failed"
    assert decoded["message"] == "error message redacted"
  end

  test "plan with applicable true and nil id fails validation" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: true,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with applicable false and valid id fails validation" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1",
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "plan with applicable true and malformed id fails validation" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: "short-id",
           action: :add,
           target_id: "my-target",
           registry_path: "/registry.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: true,
           preview: %{},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "preview plan with wide map exceeding global node budget fails validation" do
    wide = Map.new(1..15_000, fn i -> {"key#{i}", true} end)

    deps = %{
      plan: fn _cmd, _opts ->
        {:ok, %{sample_plan(:add, "my-target") | preview: wide}}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error =~ "plan_validation_failed"
  end

  test "preview map with scalar values renders deterministically" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: default_registry_path(),
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{
             "message" => nil,
             "plain" => true,
             "uri" => false,
             "nested" => 42,
             "overall" => 3.14,
             "before" => "test\n" <> <<0>> <> "\"\\"
           },
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:ok, output} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert output =~ "preview:"
    assert output =~ "message: null"
    assert output =~ "plain: true"
    assert output =~ "uri: false"
    assert output =~ "nested: 42"
    assert output =~ "overall: 3.14"
    assert output =~ ~S|before: "test\n\u0000\"\\"|
  end

  test "text malformed preview with invalid value inside list returns plan_validation_failed" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/r.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"items" => [self()]},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml"], deps)

    assert error == "plan_validation_failed"
  end

  test "json malformed preview with invalid value inside list returns plan_validation_failed" do
    deps = %{
      plan: fn _cmd, _opts ->
        {:ok,
         %OperatorCommandService.Plan{
           id: nil,
           action: :add,
           target_id: "my-target",
           registry_path: "/r.yml",
           expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
           proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
           applicable?: false,
           preview: %{"items" => [self()]},
           created_at: "2026-01-01T00:00:00Z"
         }}
      end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "plan_validation_failed"
  end

  test "json error envelope with injected encoder raise returns valid json fallback" do
    deps = %{
      json_encode: fn _value -> raise "secret_boom" end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "json_encoding_failed"
    refute error =~ "secret_boom"
  end

  test "json error envelope with injected encoder throw returns valid json fallback" do
    deps = %{
      json_encode: fn _value -> throw({:bad, "secret"}) end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "json_encoding_failed"
    refute error =~ "secret"
  end

  test "json error envelope with injected encoder malformed return returns valid json fallback" do
    deps = %{
      json_encode: fn _value -> :ok end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "json_encoding_failed"
  end

  test "json file read error normalizes unknown binary reason to file_read_failed" do
    deps = %{
      read_file: fn _path -> {:error, "custom_unknown_reason"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "file_read_failed"
    assert decoded["message"] == "File read failed"
  end

  test "json file read error rejects JSON-shaped binary reason without leak" do
    deps = %{
      read_file: fn _path ->
        {:error, ~s|{"code":"injected","message":"secret"}|}
      end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }

    assert {:error, error} =
             HostCLI.evaluate(["target", "add", "my-target", "--input", "target.yml", "--json"], deps)

    assert valid_json?(error)
    decoded = Jason.decode!(error)
    assert decoded["code"] == "file_read_failed"
    refute decoded["message"] =~ "secret"
  end

  defp assert_preview_boundary(preview, expectation) do
    for json? <- [false, true] do
      args = ["target", "add", "my-target", "--input", "target.yml"]
      args = if json?, do: args ++ ["--json"], else: args
      result = HostCLI.evaluate(args, preview_deps(%{sample_plan(:add, "my-target") | preview: preview}))

      case {expectation, json?, result} do
        {:accepted, false, {:ok, output}} ->
          assert output =~ "Plan add for my-target"

        {:accepted, true, {:ok, output}} ->
          assert valid_json?(output)

        {:rejected, false, {:error, error}} ->
          assert error == "plan_validation_failed"

        {:rejected, true, {:error, error}} ->
          assert valid_json?(error)
          assert Jason.decode!(error)["code"] == "plan_validation_failed"

        other ->
          flunk("unexpected preview boundary result: #{inspect(other)}")
      end
    end
  end

  defp preview_cases do
    [
      {:add, ["target", "add", "my-target", "--input", "target.yml"]},
      {:import, ["target", "import", "my-target", "--workflow", "/wf.yml", "--repo", "/repo"]},
      {:patch, ["target", "plan", "my-target", "--patch", "patch.yml"]},
      {:activate, ["target", "activate", "my-target", "--mode", "watch"]},
      {:pause, ["target", "pause", "my-target"]},
      {:drain, ["target", "drain", "my-target"]},
      {:retire, ["target", "retire", "my-target"]}
    ]
  end

  defp confirm_cases(plan_id) do
    [
      {:add, ["target", "add", "my-target", "--confirm", plan_id]},
      {:import, ["target", "import", "my-target", "--confirm", plan_id]},
      {:patch, ["target", "patch", "my-target", "--confirm", plan_id]},
      {:activate, ["target", "activate", "my-target", "--confirm", plan_id]},
      {:pause, ["target", "pause", "my-target", "--confirm", plan_id]},
      {:drain, ["target", "drain", "my-target", "--confirm", plan_id]},
      {:retire, ["target", "retire", "my-target", "--confirm", plan_id]}
    ]
  end

  defp preview_deps(plan) do
    %{
      plan: fn _command, _opts -> {:ok, plan} end,
      read_file: fn _path -> {:ok, "display_name: test"} end,
      yaml_decode: fn _content -> {:ok, %{"display_name" => "test"}} end
    }
  end

  defp sample_apply_result(action, plan_id, registry_path) do
    %OperatorCommandService.ApplyResult{
      plan_id: plan_id,
      action: action,
      target_id: "my-target",
      registry_path: registry_path,
      old_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
      new_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      committed?: true,
      plan_consumed?: true
    }
  end

  defp default_registry_path do
    SymphonyElixir.LocalConfig.target_registry_path()
  end

  defp forbidden_deps do
    parent = self()

    %{
      plan: fn _cmd, _opts ->
        send(parent, :plan_called)
        flunk("plan should not be called for invalid grammar")
      end,
      confirm_action: fn _tid, _pid, _action, _conf, _opts ->
        send(parent, :confirm_action_called)
        flunk("confirm_action should not be called for invalid grammar")
      end,
      read_file: fn _path ->
        send(parent, :read_file_called)
        flunk("read_file should not be called for invalid grammar")
      end,
      yaml_decode: fn _content ->
        send(parent, :yaml_decode_called)
        flunk("yaml_decode should not be called for invalid grammar")
      end,
      json_encode: fn value ->
        send(parent, :json_encode_called)
        Jason.encode(value)
      end
    }
  end

  defp valid_json?(string) when is_binary(string) do
    match?({:ok, _}, Jason.decode(string))
  end

  defp sample_plan(action, target_id, registry_path \\ nil) do
    %OperatorCommandService.Plan{
      id: nil,
      action: action,
      target_id: target_id,
      registry_path: registry_path || SymphonyElixir.LocalConfig.target_registry_path(),
      expected_generation: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
      proposed_generation: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      applicable?: false,
      preview: %{"registry" => %{"diff" => [], "diagnostics" => [], "impact" => %{"overall" => "unchanged"}}},
      created_at: "2026-01-01T00:00:00Z"
    }
  end
end
