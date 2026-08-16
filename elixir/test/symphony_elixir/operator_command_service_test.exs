defmodule SymphonyElixir.OperatorCommandServiceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OperatorCommandService
  alias SymphonyElixir.OperatorCommandService.Command
  alias SymphonyElixir.OperatorCommandService.PlanStore
  alias SymphonyElixir.TargetRegistry
  alias SymphonyElixir.TargetRegistry.Preview
  alias SymphonyElixir.TargetRegistry.Yaml
  @manifest_fixture_root Path.expand("../fixtures/target_registry/repos/symphony", __DIR__)

  test "rejects maps that masquerade as typed commands" do
    assert {:error, error} =
             OperatorCommandService.plan(%{"target_id" => "alpha", "target" => %{}},
               registry_path: "/tmp/targets.yml"
             )

    assert error.code == :invalid_command
    assert error.path == "$.command"
  end

  @tag :tmp_dir
  test "add plan requires an existing registry", %{tmp_dir: tmp_dir} do
    registry_path = Path.join(tmp_dir, "targets.yml")
    command = %Command.Add{target_id: "alpha", target: %{}}

    assert {:error, error} =
             OperatorCommandService.plan(command, registry_path: registry_path)

    assert error.code == :registry_not_found
    assert error.path == registry_path
    refute File.exists?(registry_path)
  end

  @tag :tmp_dir
  test "invalid host returns a non-applicable preview without a plan envelope", %{tmp_dir: tmp_dir} do
    registry_path = Path.join(tmp_dir, "targets.yml")
    File.write!(registry_path, Yaml.encode(%{"version" => 1, "host" => %{}, "targets" => %{}}))

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    refute plan.applicable?
    assert plan.id == nil
    assert Enum.any?(plan.preview["registry"]["diagnostics"], &(&1["scope"] == "host"))
    refute File.exists?(Path.join(tmp_dir, "target-plans"))
  end

  @tag :tmp_dir
  test "duplicate target ID is non-applicable and stores no envelope", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => %{"state" => "paused"}})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    refute plan.applicable?
    assert plan.id == nil

    assert Enum.any?(
             plan.preview["registry"]["diagnostics"],
             &(&1["code"] == "duplicate_target_id")
           )

    refute File.exists?(Path.join(tmp_dir, "target-plans"))
  end

  @tag :tmp_dir
  test "add forces requested active state to paused in the preview", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    original = File.read!(registry_path)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{"state" => "active"}},
               registry_path: registry_path
             )

    assert plan.applicable?
    assert is_binary(plan.id)

    assert Enum.any?(
             plan.preview["normalization"]["diff"],
             &(&1["path"] == "$.targets.alpha.state" and &1["after"] == "paused")
           )

    assert File.read!(registry_path) == original
  end

  @tag :tmp_dir
  test "add removes requested dispatch mode in the preview", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{
                 target_id: "alpha",
                 target: %{"state" => "paused", "dispatch_mode" => "watch"}
               },
               registry_path: registry_path
             )

    assert plan.applicable?

    assert Enum.any?(
             plan.preview["normalization"]["diff"],
             &(&1["path"] == "$.targets.alpha.dispatch_mode" and &1["after"] == nil)
           )
  end

  @tag :tmp_dir
  test "apply requires literal confirmation before plan or registry access", %{tmp_dir: tmp_dir} do
    parent = self()
    generation = "sha256:" <> String.duplicate("0", 64)
    plan_id = String.duplicate("0", 64)

    read_plan = fn _plan_dir, _id ->
      send(parent, :plan_read)
      flunk("plan reader must not run without confirmation")
    end

    assert {:error, error} =
             OperatorCommandService.apply(plan_id, generation, false,
               registry_path: Path.join(tmp_dir, "targets.yml"),
               read_plan: read_plan
             )

    assert error.code == :confirmation_required
    refute_received :plan_read
    refute File.exists?(tmp_dir |> Path.join("targets.yml.lock"))
  end

  @tag :tmp_dir
  test "confirmed add atomically publishes the exact generation and consumes its plan", %{
    tmp_dir: tmp_dir
  } do
    registry_path = write_registry(tmp_dir, %{})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{
                 target_id: "alpha",
                 target: %{"state" => "active", "dispatch_mode" => "watch"}
               },
               registry_path: registry_path
             )

    envelope_path = Path.join([tmp_dir, "target-plans", plan.id <> ".json"])
    assert File.exists?(envelope_path)

    assert {:ok, result} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true, registry_path: registry_path)

    assert result.old_generation == plan.expected_generation
    assert result.new_generation == plan.proposed_generation
    assert result.committed?
    assert result.plan_consumed?

    assert {:ok, document} = registry_path |> File.read!() |> Yaml.decode()
    assert get_in(document, ["targets", "alpha", "state"]) == "paused"
    refute get_in(document, ["targets", "alpha"]) |> Map.has_key?("dispatch_mode")
    assert Bitwise.band(File.stat!(registry_path).mode, 0o777) == 0o600
    refute File.exists?(envelope_path)
  end

  @tag :tmp_dir
  test "import host collision is non-applicable and leaves every input unchanged", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    workflow = Path.join(tmp_dir, "legacy.runtime.yml")

    source =
      Yaml.encode(%{
        "runtime" => %{
          "tracker" => %{
            "project_slug" => "symphony-fixture",
            "endpoint" => "https://different.example.test/graphql"
          }
        }
      })

    File.write!(workflow, source)
    manifest_path = Path.join(@manifest_fixture_root, "symphony.yml")
    registry_before = File.read!(registry_path)
    manifest_before = File.read!(manifest_path)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Import{
                 target_id: "imported",
                 workflow: workflow,
                 repo: @manifest_fixture_root,
                 connection_id: "linear-main"
               },
               registry_path: registry_path
             )

    refute plan.applicable?
    assert plan.id == nil

    assert Enum.any?(
             plan.preview["import"]["import_diagnostics"],
             &(&1["code"] == "import_conflict")
           )

    assert File.read!(registry_path) == registry_before
    assert File.read!(workflow) == source
    assert File.read!(manifest_path) == manifest_before
  end

  @tag :tmp_dir
  test "confirmed import atomically publishes paused target without mutating external state", %{
    tmp_dir: tmp_dir
  } do
    registry_path = write_registry(tmp_dir, %{})
    workflow = Path.join(tmp_dir, "legacy.runtime.yml")
    config_path = Path.join(tmp_dir, "config.yml")
    saved_run_path = Path.join([tmp_dir, "runs", "saved.yml"])
    File.mkdir_p!(Path.dirname(saved_run_path))

    source =
      Yaml.encode(%{
        "runtime" => %{
          "tracker" => %{
            "project_slug" => "symphony-fixture",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "$LINEAR_API_KEY"
          },
          "agent" => %{
            "default_runner" => "codex",
            "max_concurrent_agents" => 4,
            "max_concurrent_startups" => 2
          },
          "runners" => %{
            "codex" => %{
              "kind" => "codex_app_server",
              "command" => ["codex", "app-server"]
            }
          }
        }
      })

    File.write!(workflow, source)
    File.write!(config_path, "sentinel: config\n")
    File.write!(saved_run_path, "sentinel: run\n")

    manifest_path = Path.join(@manifest_fixture_root, "symphony.yml")
    manifest_before = File.read!(manifest_path)
    app_env_before = Application.get_all_env(:symphony_elixir)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Import{
                 target_id: "imported",
                 workflow: workflow,
                 repo: @manifest_fixture_root,
                 connection_id: "linear-main"
               },
               registry_path: registry_path
             )

    assert plan.applicable?
    encoded_plan = Jason.encode!(plan)
    refute encoded_plan =~ "$LINEAR_API_KEY"

    assert {:ok, result} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true, registry_path: registry_path)

    assert result.action == :import
    assert result.new_generation == plan.proposed_generation
    assert {:ok, document} = registry_path |> File.read!() |> Yaml.decode()
    assert get_in(document, ["targets", "imported", "state"]) == "paused"
    refute get_in(document, ["targets", "imported"]) |> Map.has_key?("dispatch_mode")

    assert File.read!(workflow) == source
    assert File.read!(manifest_path) == manifest_before
    assert File.read!(config_path) == "sentinel: config\n"
    assert File.read!(saved_run_path) == "sentinel: run\n"
    assert Application.get_all_env(:symphony_elixir) == app_env_before
  end

  @tag :tmp_dir
  test "stale current generation blocks apply and preserves the plan envelope", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    stale_bytes = File.read!(registry_path) <> "# changed\n"
    File.write!(registry_path, stale_bytes)
    envelope_path = Path.join([tmp_dir, "target-plans", plan.id <> ".json"])

    assert {:error, error} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true, registry_path: registry_path)

    assert error.code == :stale_generation
    assert File.read!(registry_path) == stale_bytes
    assert File.exists?(envelope_path)
  end

  @tag :tmp_dir
  test "changed import source blocks apply and keeps registry and plan unchanged", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    registry_before = File.read!(registry_path)
    workflow = Path.join(tmp_dir, "legacy.runtime.yml")
    source = applicable_import_source()
    File.write!(workflow, source)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Import{
                 target_id: "imported",
                 workflow: workflow,
                 repo: @manifest_fixture_root,
                 connection_id: "linear-main"
               },
               registry_path: registry_path
             )

    assert plan.applicable?
    File.write!(workflow, source <> "# changed\n")
    envelope_path = Path.join([tmp_dir, "target-plans", plan.id <> ".json"])

    assert {:error, error} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true, registry_path: registry_path)

    assert error.code == :import_source_changed
    assert File.read!(registry_path) == registry_before
    assert File.exists?(envelope_path)
  end

  defp applicable_import_source do
    Yaml.encode(%{
      "runtime" => %{
        "tracker" => %{
          "project_slug" => "symphony-fixture",
          "endpoint" => "https://api.linear.app/graphql",
          "api_key" => "$LINEAR_API_KEY"
        },
        "agent" => %{
          "default_runner" => "codex",
          "max_concurrent_agents" => 4,
          "max_concurrent_startups" => 2
        },
        "runners" => %{
          "codex" => %{
            "kind" => "codex_app_server",
            "command" => ["codex", "app-server"]
          }
        }
      }
    })
  end

  @tag :tmp_dir
  test "add rejects non-string target map keys at the service boundary", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})

    assert {:error, error} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{state: "active"}},
               registry_path: registry_path
             )

    assert error.code == :invalid_command
    refute File.exists?(Path.join(tmp_dir, "target-plans"))
  end

  @tag :tmp_dir
  test "confirm rejects a plan bound to another target without mutation", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    registry_before = File.read!(registry_path)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    envelope_path = Path.join([tmp_dir, "target-plans", plan.id <> ".json"])

    assert {:error, error} =
             OperatorCommandService.confirm("beta", plan.id, true, registry_path: registry_path)

    assert error.code == :plan_mismatch
    assert File.read!(registry_path) == registry_before
    assert File.exists?(envelope_path)
  end

  @tag :tmp_dir
  test "import maps source runner IDs without changing source bytes", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    workflow = Path.join(tmp_dir, "legacy.runtime.yml")
    source = applicable_import_source()
    File.write!(workflow, source)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Import{
                 target_id: "imported",
                 workflow: workflow,
                 repo: @manifest_fixture_root,
                 connection_id: "linear-main",
                 runner_ids: %{"codex" => "renamed"}
               },
               registry_path: registry_path
             )

    assert plan.applicable?

    assert {:ok, _result} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true, registry_path: registry_path)

    assert {:ok, document} = registry_path |> File.read!() |> Yaml.decode()
    assert get_in(document, ["targets", "imported", "runners", "allowed"]) == ["renamed"]
    assert get_in(document, ["targets", "imported", "runners", "default"]) == "renamed"
    assert is_map(get_in(document, ["host", "runners", "renamed"]))
    refute Map.has_key?(document["host"]["runners"], "codex")
    assert File.read!(workflow) == source
  end

  @tag :tmp_dir
  test "apply rejects proposed generation mismatch before registry publication", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    registry_before = File.read!(registry_path)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    plan_dir = Path.join(tmp_dir, "target-plans")
    assert {:ok, envelope} = PlanStore.read(plan_dir, plan.id)
    forged = Map.put(envelope, "proposed_generation", "sha256:" <> String.duplicate("0", 64))

    assert {:error, error} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true,
               registry_path: registry_path,
               read_plan: fn ^plan_dir, id when id == plan.id -> {:ok, forged} end
             )

    assert error.code == :proposed_generation_mismatch
    assert File.read!(registry_path) == registry_before
    assert File.exists?(Path.join(plan_dir, plan.id <> ".json"))
  end

  @tag :tmp_dir
  test "apply rejects envelope action target and registry path mismatches", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    registry_before = File.read!(registry_path)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    plan_dir = Path.join(tmp_dir, "target-plans")
    assert {:ok, envelope} = PlanStore.read(plan_dir, plan.id)

    for forged <- [
          Map.put(envelope, "action", "patch"),
          Map.put(envelope, "target_id", "beta"),
          Map.put(envelope, "registry_path", registry_path <> ".other")
        ] do
      assert {:error, error} =
               OperatorCommandService.apply(plan.id, plan.expected_generation, true,
                 registry_path: registry_path,
                 read_plan: fn ^plan_dir, id when id == plan.id -> {:ok, forged} end
               )

      assert error.code == :plan_mismatch
      assert File.read!(registry_path) == registry_before
    end
  end

  @tag :tmp_dir
  test "consume failure reports committed generation and leaves envelope present", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    consume_plan = fn _plan_dir, _id ->
      {:error,
       %OperatorCommandService.Error{
         code: :plan_consume_failed,
         message: "injected consume failure",
         path: "$.plan"
       }}
    end

    assert {:error, error} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true,
               registry_path: registry_path,
               consume_plan: consume_plan
             )

    assert error.code == :plan_consume_failed
    assert error.committed?
    assert error.expected_generation == plan.proposed_generation
    assert error.observed_generation == plan.proposed_generation
    assert File.exists?(Path.join([tmp_dir, "target-plans", plan.id <> ".json"]))
  end

  @tag :tmp_dir
  test "malformed options and exact generation mismatch return typed errors", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    command = %Command.Add{target_id: "alpha", target: %{}}

    for opts <- [
          %{},
          [registry_path: registry_path, config_root: tmp_dir],
          [registry_path: registry_path, unknown: true],
          [registry_path: registry_path, read_plan: :not_a_function]
        ] do
      assert {:error, %OperatorCommandService.Error{code: :invalid_options}} =
               OperatorCommandService.plan(command, opts)
    end

    assert {:ok, plan} = OperatorCommandService.plan(command, registry_path: registry_path)
    wrong_generation = "sha256:" <> String.duplicate("0", 64)

    assert {:error, %OperatorCommandService.Error{code: :plan_mismatch}} =
             OperatorCommandService.apply(plan.id, wrong_generation, true, registry_path: registry_path)
  end

  @tag :tmp_dir
  test "incomplete paused add draft remains applicable with target diagnostics", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    registry_before = File.read!(registry_path)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "draft", target: %{}},
               registry_path: registry_path
             )

    assert plan.applicable?

    assert Enum.any?(
             plan.preview["registry"]["diagnostics"],
             &(get_in(&1, ["scope", "id"]) == "draft")
           )

    assert File.read!(registry_path) == registry_before
  end

  @tag :tmp_dir
  test "confirm loads the bound generation and delegates to apply", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    assert {:ok, result} =
             OperatorCommandService.confirm("alpha", plan.id, true, registry_path: registry_path)

    assert result.plan_id == plan.id
    assert result.old_generation == plan.expected_generation
    assert result.new_generation == plan.proposed_generation
  end

  @tag :tmp_dir
  test "plan identity excludes display time and public structs are JSON-ready", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    command = %Command.Add{target_id: "alpha", target: %{}}
    store = fn _plan_dir, envelope -> {:ok, envelope} end

    assert {:ok, first} =
             OperatorCommandService.plan(command,
               registry_path: registry_path,
               now: fn -> "2026-08-16T00:00:00Z" end,
               store_plan: store
             )

    assert {:ok, second} =
             OperatorCommandService.plan(command,
               registry_path: registry_path,
               now: fn -> "2026-08-16T00:00:01Z" end,
               store_plan: store
             )

    assert first.id == second.id
    assert first.created_at != second.created_at
    assert {:ok, encoded} = Jason.encode(first)
    assert is_binary(encoded)
  end

  @tag :tmp_dir
  test "command and call boundaries reject malformed values without raising", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    generation = "sha256:" <> String.duplicate("0", 64)
    plan_id = String.duplicate("0", 64)
    deep = Enum.reduce(1..17, "leaf", fn _, nested -> %{"nested" => nested} end)
    oversized = Enum.map(1..4_097, & &1)
    improper = [1 | 2]
    invalid_utf8 = <<0xFF>>

    valid_target = %{
      "state" => "paused",
      "values" => [nil, true, 1, 1.5, "text", %{"nested" => false}]
    }

    assert {:ok, _plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "valid-json", target: valid_target},
               registry_path: registry_path
             )

    for target <- [
          DateTime.utc_now(),
          %{"bad" => {:tuple}},
          %{"bad" => improper},
          %{"bad" => deep},
          %{"bad" => oversized},
          %{"bad" => invalid_utf8},
          %{invalid_utf8 => "value"}
        ] do
      assert {:error, %OperatorCommandService.Error{code: :invalid_command}} =
               OperatorCommandService.plan(
                 %Command.Add{target_id: "invalid-json", target: target},
                 registry_path: registry_path
               )
    end

    for value <- ["bad", 1] do
      assert {:error, %OperatorCommandService.Error{code: :invalid_plan_id}} =
               OperatorCommandService.apply(value, generation, true, registry_path: registry_path)
    end

    for value <- ["bad", 1] do
      assert {:error, %OperatorCommandService.Error{code: :invalid_generation}} =
               OperatorCommandService.apply(plan_id, value, true, registry_path: registry_path)
    end

    assert {:error, %OperatorCommandService.Error{code: :invalid_target_id}} =
             OperatorCommandService.confirm(1, plan_id, true, registry_path: registry_path)
  end

  @tag :tmp_dir
  test "path defaults and every injected dependency keep strict option validation", %{tmp_dir: tmp_dir} do
    plan_id = String.duplicate("0", 64)
    generation = "sha256:" <> String.duplicate("0", 64)
    root = Path.join(tmp_dir, "config-root")

    assert {:error, %OperatorCommandService.Error{code: :plan_corrupt}} =
             OperatorCommandService.apply(plan_id, generation, true,
               config_root: root,
               read_plan: fn plan_dir, ^plan_id ->
                 assert plan_dir == SymphonyElixir.LocalConfig.target_plan_dir(config_root: root)
                 :invalid
               end
             )

    assert {:error, %OperatorCommandService.Error{code: :plan_corrupt}} =
             OperatorCommandService.apply(plan_id, generation, true,
               read_plan: fn plan_dir, ^plan_id ->
                 assert plan_dir == SymphonyElixir.LocalConfig.target_plan_dir()
                 :invalid
               end
             )

    all_dependencies = [
      registry_path: Path.join(tmp_dir, "targets.yml"),
      now: fn -> "2026-08-16T00:00:00Z" end,
      read_file: fn _ -> :unused end,
      load_manifest: fn _ -> :unused end,
      read_plan: fn _, _ -> :unused end,
      store_plan: fn _, _ -> :unused end,
      consume_plan: fn _, _ -> :unused end,
      replace_registry: fn _, _, _, _ -> :unused end
    ]

    assert {:error, %OperatorCommandService.Error{code: :confirmation_required}} =
             OperatorCommandService.apply(plan_id, generation, false, all_dependencies)

    assert {:error, %OperatorCommandService.Error{code: :invalid_options}} =
             OperatorCommandService.apply(plan_id, generation, false, config_root: " invalid ")
  end

  @tag :tmp_dir
  test "import validates source shape runner mappings and manifest dependencies", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    workflow = Path.join(tmp_dir, "legacy.runtime.yml")
    File.write!(workflow, applicable_import_source())

    base = %{
      target_id: "imported",
      workflow: workflow,
      repo: @manifest_fixture_root,
      connection_id: "linear-main"
    }

    for runner_ids <- [:invalid, %{"codex" => "same", "other" => "same"}] do
      assert {:error, %OperatorCommandService.Error{code: :invalid_command}} =
               OperatorCommandService.plan(
                 struct!(Command.Import, Map.put(base, :runner_ids, runner_ids)),
                 registry_path: registry_path
               )
    end

    cases = [
      {Yaml.encode(%{"runtime" => %{"runners" => %{}}}), %{"absent" => "renamed"}, :invalid_runner_mapping},
      {"not: [valid", %{"codex" => "renamed"}, :invalid_yaml},
      {Yaml.encode(%{"runtime" => %{}}), %{"codex" => "renamed"}, :invalid_runner_mapping}
    ]

    for {source, runner_ids, code} <- cases do
      File.write!(workflow, source)

      assert {:error, %OperatorCommandService.Error{code: ^code}} =
               OperatorCommandService.plan(
                 struct!(Command.Import, Map.put(base, :runner_ids, runner_ids)),
                 registry_path: registry_path
               )
    end

    File.write!(workflow, applicable_import_source())
    dependency_error = %OperatorCommandService.Error{code: :manifest_invalid, message: "injected"}

    assert {:error, ^dependency_error} =
             OperatorCommandService.plan(struct!(Command.Import, base),
               registry_path: registry_path,
               load_manifest: fn _ -> {:error, dependency_error} end
             )

    assert {:error, %OperatorCommandService.Error{code: :manifest_invalid}} =
             OperatorCommandService.plan(struct!(Command.Import, base),
               registry_path: registry_path,
               load_manifest: fn _ -> :invalid end
             )

    empty_repo = Path.join(tmp_dir, "empty-repo")
    File.mkdir_p!(empty_repo)
    File.write!(Path.join(empty_repo, "symphony.yml"), "invalid: [manifest")

    assert {:error, %OperatorCommandService.Error{code: :manifest_invalid}} =
             OperatorCommandService.plan(
               struct!(Command.Import, Map.put(base, :repo, empty_repo)),
               registry_path: registry_path
             )
  end

  @tag :tmp_dir
  test "source reads are exact and dependency exceptions stay typed", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    workflow = Path.join(tmp_dir, "legacy.runtime.yml")
    source = applicable_import_source()
    File.write!(workflow, source)

    command = %Command.Import{
      target_id: "imported",
      workflow: workflow,
      repo: @manifest_fixture_root,
      connection_id: "linear-main"
    }

    for reader <- [
          fn _ -> :invalid end,
          fn _ -> raise "read failed" end,
          fn _ -> throw(:read_failed) end
        ] do
      assert {:error, %OperatorCommandService.Error{code: :source_unreadable}} =
               OperatorCommandService.plan(command,
                 registry_path: registry_path,
                 read_file: reader
               )
    end

    reads = :counters.new(1, [])

    changing_reader = fn path ->
      if path == workflow do
        :counters.add(reads, 1, 1)
        sequence = :counters.get(reads, 1)
        if sequence == 1, do: {:ok, source}, else: {:ok, source <> "# changed\n"}
      else
        File.read(path)
      end
    end

    assert {:error, %OperatorCommandService.Error{code: :import_source_changed}} =
             OperatorCommandService.plan(command,
               registry_path: registry_path,
               read_file: changing_reader
             )
  end

  @tag :tmp_dir
  test "plan dependency errors remain typed and do not publish", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    registry_before = File.read!(registry_path)
    command = %Command.Add{target_id: "alpha", target: %{}}

    target_error = %TargetRegistry.Error{
      code: :plan_store_failed,
      message: "target registry error",
      path: "$.plan"
    }

    service_error = %OperatorCommandService.Error{
      code: :plan_store_failed,
      message: "service error",
      path: "$.plan"
    }

    for {store, expected} <- [
          {fn _, _ -> {:error, target_error} end, target_error.code},
          {fn _, _ -> {:error, service_error} end, service_error.code},
          {fn _, _ -> :invalid end, :plan_store_failed},
          {fn _, _ -> raise "store failed" end, :plan_store_failed}
        ] do
      assert {:error, %OperatorCommandService.Error{code: ^expected}} =
               OperatorCommandService.plan(command,
                 registry_path: registry_path,
                 store_plan: store
               )
    end

    assert File.read!(registry_path) == registry_before
  end

  @tag :tmp_dir
  test "apply normalizes plan and replacement dependency failures", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    generation = registry_path |> File.read!() |> Preview.generation()
    plan_id = String.duplicate("0", 64)

    target_error = %TargetRegistry.Error{
      code: :plan_corrupt,
      message: "target registry error",
      path: "$.plan"
    }

    service_error = %OperatorCommandService.Error{
      code: :plan_corrupt,
      message: "service error",
      path: "$.plan"
    }

    for {reader, expected} <- [
          {fn _, _ -> {:error, target_error} end, target_error.code},
          {fn _, _ -> {:error, service_error} end, service_error.code},
          {fn _, _ -> :invalid end, :plan_corrupt},
          {fn _, _ -> raise "read failed" end, :plan_corrupt},
          {fn _, _ -> throw(:read_failed) end, :plan_corrupt}
        ] do
      assert {:error, %OperatorCommandService.Error{code: ^expected}} =
               OperatorCommandService.apply(plan_id, generation, true,
                 registry_path: registry_path,
                 read_plan: reader
               )
    end

    invalid_envelope = %{
      "plan_id" => plan_id,
      "expected_generation" => generation,
      "registry_path" => registry_path,
      "action" => "add",
      "target_id" => "alpha",
      "proposed_generation" => "invalid",
      "source_hashes" => %{},
      "command" => %{"target_id" => "alpha", "target" => %{}}
    }

    assert {:error, %OperatorCommandService.Error{code: :invalid_generation}} =
             OperatorCommandService.apply(plan_id, generation, true,
               registry_path: registry_path,
               read_plan: fn _, _ -> {:ok, invalid_envelope} end
             )

    assert {:ok, plan} =
             OperatorCommandService.plan(%Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    for replacement <- [
          fn _, _, _, _ -> :invalid end,
          fn _, _, _, _ -> raise "replace failed" end
        ] do
      assert {:error, %OperatorCommandService.Error{code: :atomic_replace_failed}} =
               OperatorCommandService.apply(plan.id, plan.expected_generation, true,
                 registry_path: registry_path,
                 replace_registry: replacement
               )
    end
  end

  @tag :tmp_dir
  test "import blocks invalid registries and duplicate target IDs before source reads", %{tmp_dir: tmp_dir} do
    workflow = Path.join(tmp_dir, "absent.runtime.yml")
    command = %Command.Import{target_id: "alpha", workflow: workflow, repo: tmp_dir}
    invalid_registry = Path.join(tmp_dir, "invalid-targets.yml")
    File.write!(invalid_registry, Yaml.encode(%{"version" => 1, "host" => %{}, "targets" => %{}}))

    assert {:ok, plan} =
             OperatorCommandService.plan(command,
               registry_path: invalid_registry,
               now: fn -> :invalid end
             )

    refute plan.applicable?
    assert plan.created_at == ""

    duplicate_registry = write_registry(tmp_dir, %{"alpha" => %{"state" => "paused"}})

    assert {:error, %OperatorCommandService.Error{code: :duplicate_target_id}} =
             OperatorCommandService.plan(command, registry_path: duplicate_registry)
  end

  @tag :tmp_dir
  test "runner mapping handles absent defaults and non-map agents without changing its source", %{
    tmp_dir: tmp_dir
  } do
    registry_path = write_registry(tmp_dir, %{})
    workflow = Path.join(tmp_dir, "legacy.runtime.yml")

    for agent <- [%{}, "invalid-agent"] do
      source =
        Yaml.encode(%{
          "runtime" => %{
            "tracker" => %{
              "project_slug" => "symphony-fixture",
              "endpoint" => "https://api.linear.app/graphql",
              "api_key" => "$LINEAR_API_KEY"
            },
            "agent" => agent,
            "runners" => %{
              "codex" => %{"kind" => "codex_app_server", "command" => ["codex", "app-server"]}
            }
          }
        })

      File.write!(workflow, source)

      result =
        OperatorCommandService.plan(
          %Command.Import{
            target_id: "imported",
            workflow: workflow,
            repo: @manifest_fixture_root,
            connection_id: "linear-main",
            runner_ids: %{"codex" => "renamed"}
          },
          registry_path: registry_path,
          store_plan: fn _, envelope -> {:ok, envelope} end
        )

      assert match?({:ok, _plan}, result) or match?({:error, %OperatorCommandService.Error{}}, result)
      assert File.read!(workflow) == source
    end
  end

  @tag :tmp_dir
  test "apply rebuild rejects changed registry and import bindings", %{tmp_dir: tmp_dir} do
    add_dir = Path.join(tmp_dir, "add")
    File.mkdir_p!(add_dir)
    add_registry = write_registry(add_dir, %{})

    assert {:ok, add_plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: add_registry
             )

    add_current = File.read!(add_registry)
    {:ok, add_document} = Yaml.decode(add_current)
    duplicate_add = put_in(add_document, ["targets", "alpha"], %{"state" => "paused"}) |> Yaml.encode()
    invalid_add = Yaml.encode(%{"version" => 1, "host" => %{}, "targets" => %{}})

    for {changed, code} <- [
          {duplicate_add, :duplicate_target_id},
          {invalid_add, :plan_not_applicable}
        ] do
      replacer = fn _, _, _, rebuild -> rebuild.(changed) end

      assert {:error, %OperatorCommandService.Error{code: ^code}} =
               OperatorCommandService.apply(add_plan.id, add_plan.expected_generation, true,
                 registry_path: add_registry,
                 replace_registry: replacer
               )
    end

    import_dir = Path.join(tmp_dir, "import")
    File.mkdir_p!(import_dir)
    import_registry = write_registry(import_dir, %{})
    workflow = Path.join(import_dir, "legacy.runtime.yml")
    source = applicable_import_source()
    File.write!(workflow, source)

    import_command = %Command.Import{
      target_id: "imported",
      workflow: workflow,
      repo: @manifest_fixture_root,
      connection_id: "linear-main"
    }

    assert {:ok, import_plan} =
             OperatorCommandService.plan(import_command, registry_path: import_registry)

    plan_dir = Path.join(import_dir, "target-plans")
    assert {:ok, import_envelope} = PlanStore.read(plan_dir, import_plan.id)
    import_current = File.read!(import_registry)
    {:ok, import_document} = Yaml.decode(import_current)

    duplicate_import =
      put_in(import_document, ["targets", "imported"], %{"state" => "paused"}) |> Yaml.encode()

    cases = [
      {import_envelope, duplicate_import, :duplicate_target_id},
      {Map.put(import_envelope, "source_hashes", %{}), import_current, :plan_mismatch},
      {Map.put(
         import_envelope,
         "proposed_generation",
         "sha256:" <> String.duplicate("0", 64)
       ), import_current, :proposed_generation_mismatch}
    ]

    for {envelope, current, code} <- cases do
      assert {:error, %OperatorCommandService.Error{code: ^code}} =
               OperatorCommandService.apply(import_plan.id, import_plan.expected_generation, true,
                 registry_path: import_registry,
                 read_plan: fn _, _ -> {:ok, envelope} end,
                 replace_registry: fn _, _, _, rebuild -> rebuild.(current) end
               )
    end

    reads = :counters.new(1, [])

    changing_reader = fn path ->
      if path == workflow do
        :counters.add(reads, 1, 1)
        count = :counters.get(reads, 1)
        if count == 1, do: {:ok, source}, else: {:ok, source <> "# changed\n"}
      else
        File.read(path)
      end
    end

    assert {:error, %OperatorCommandService.Error{code: :import_source_changed}} =
             OperatorCommandService.apply(import_plan.id, import_plan.expected_generation, true,
               registry_path: import_registry,
               read_file: changing_reader,
               replace_registry: fn _, _, _, rebuild -> rebuild.(import_current) end
             )
  end

  @tag :tmp_dir
  test "replacement errors distinguish committed and unchanged registries", %{tmp_dir: tmp_dir} do
    for {index, source_code, commit?, expected_committed} <- [
          {1, :atomic_replace_failed, false, false},
          {2, :stale_generation, false, false},
          {3, :atomic_replace_failed, true, true}
        ] do
      case_dir = Path.join(tmp_dir, Integer.to_string(index))
      File.mkdir_p!(case_dir)
      registry_path = write_registry(case_dir, %{})

      assert {:ok, plan} =
               OperatorCommandService.plan(
                 %Command.Add{target_id: "alpha", target: %{}},
                 registry_path: registry_path
               )

      source_error = %TargetRegistry.Error{
        code: source_code,
        message: "injected replacement failure",
        path: registry_path
      }

      replacer = fn path, _, _, rebuild ->
        if commit? do
          {:ok, proposed_bytes} = path |> File.read!() |> rebuild.()
          File.write!(path, proposed_bytes)
        end

        {:error, source_error}
      end

      assert {:error, error} =
               OperatorCommandService.apply(plan.id, plan.expected_generation, true,
                 registry_path: registry_path,
                 replace_registry: replacer
               )

      assert error.code == source_code
      assert error.committed? == expected_committed
    end
  end

  @tag :tmp_dir
  test "apply rejects corrupt command bindings and a registry removed before replacement", %{
    tmp_dir: tmp_dir
  } do
    registry_path = write_registry(tmp_dir, %{})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    plan_dir = Path.join(tmp_dir, "target-plans")
    assert {:ok, envelope} = PlanStore.read(plan_dir, plan.id)
    invalid_command = Map.put(envelope, "command", :invalid)

    assert {:error, %OperatorCommandService.Error{code: :plan_mismatch}} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true,
               registry_path: registry_path,
               read_plan: fn _, _ -> {:ok, invalid_command} end
             )

    File.rm!(registry_path)

    assert {:error, %OperatorCommandService.Error{code: :registry_not_found}} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true, registry_path: registry_path)
  end

  @tag :tmp_dir
  test "add with a missing manifest produces a contained non-applicable proposal", %{tmp_dir: tmp_dir} do
    seed_dir = Path.join(tmp_dir, "seed")
    File.mkdir_p!(seed_dir)
    seed_registry = write_registry(seed_dir, %{})
    registry_path = write_registry(tmp_dir, %{})
    workflow = Path.join(tmp_dir, "legacy.runtime.yml")
    File.write!(workflow, applicable_import_source())

    assert {:ok, import_plan} =
             OperatorCommandService.plan(
               %Command.Import{
                 target_id: "seed",
                 workflow: workflow,
                 repo: @manifest_fixture_root,
                 connection_id: "linear-main"
               },
               registry_path: seed_registry
             )

    assert {:ok, _result} =
             OperatorCommandService.apply(
               import_plan.id,
               import_plan.expected_generation,
               true,
               registry_path: seed_registry
             )

    assert {:ok, imported_document} = seed_registry |> File.read!() |> Yaml.decode()
    target = put_in(imported_document, ["targets", "seed", "repo", "manifest"], "missing.yml")

    target =
      target["targets"]["seed"]
      |> Map.put("budgets", %{
        "per_run" => %{"max_total_tokens" => 1_000},
        "daily" => %{"max_total_tokens" => 10_000},
        "weekly" => %{"max_total_tokens" => 50_000}
      })
      |> Map.put("external_side_effects", %{
        "tracker_write" => "deny",
        "vcs_publish" => "deny",
        "pull_request_write" => "deny",
        "merge" => "deny",
        "production_data" => "deny"
      })
      |> Map.put("scheduling", %{"weight" => 1})
      |> Map.put("runners", %{
        "default" => "existing",
        "allowed" => ["existing"],
        "settings" => %{"existing" => %{}}
      })

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "blocked", target: target},
               registry_path: registry_path
             )

    refute plan.applicable?
    assert plan.id == nil
    assert plan.target_id == "blocked"

    assert Enum.any?(
             plan.preview["registry"]["diagnostics"],
             &(&1["code"] == "unsafe_path")
           )
  end

  test "non-binary import paths are rejected at the typed boundary" do
    assert {:error, %OperatorCommandService.Error{code: :invalid_command}} =
             OperatorCommandService.plan(
               %Command.Import{target_id: "imported", workflow: "/tmp/workflow.yml", repo: 1},
               registry_path: "/tmp/targets.yml"
             )
  end

  @tag :tmp_dir
  test "locked rebuild detects causally injected registry changes", %{tmp_dir: tmp_dir} do
    for {index, change, expected_code} <- [
          {1, :different_proposal, :proposed_generation_mismatch},
          {2, :duplicate_target, :duplicate_target_id},
          {3, :read_failure, :registry_unreadable}
        ] do
      case_dir = Path.join(tmp_dir, Integer.to_string(index))
      File.mkdir_p!(case_dir)
      registry_path = write_registry(case_dir, %{})

      assert {:ok, plan} =
               OperatorCommandService.plan(
                 %Command.Add{target_id: "alpha", target: %{}},
                 registry_path: registry_path
               )

      {:ok, document} = registry_path |> File.read!() |> Yaml.decode()

      locked_read =
        case change do
          :different_proposal ->
            changed = put_in(document, ["host", "polling", "interval_ms"], 31_000) |> Yaml.encode()
            fn ^registry_path -> {:ok, changed} end

          :duplicate_target ->
            changed = put_in(document, ["targets", "alpha"], %{"state" => "paused"}) |> Yaml.encode()
            fn ^registry_path -> {:ok, changed} end

          :read_failure ->
            fn ^registry_path -> {:error, :eio} end
        end

      assert {:error, %OperatorCommandService.Error{code: ^expected_code}} =
               OperatorCommandService.apply(plan.id, plan.expected_generation, true,
                 registry_path: registry_path,
                 read_file: locked_read
               )
    end
  end

  @tag :tmp_dir
  test "import serializer failure returns a safe non-applicable projection", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    workflow = Path.join(tmp_dir, "legacy.runtime.yml")
    File.write!(workflow, applicable_import_source())

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Import{
                 target_id: "imported",
                 workflow: workflow,
                 repo: @manifest_fixture_root,
                 connection_id: "linear-main"
               },
               registry_path: registry_path,
               encode_import_preview: fn _result -> "{" end
             )

    assert plan.preview["import"] == %{
             "applicable?" => false,
             "import_diagnostics" => [%{"code" => "preview_encoding_failed"}]
           }
  end

  @tag :tmp_dir
  test "import preview dependency errors stay typed while planning", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    workflow = Path.join(tmp_dir, "legacy.runtime.yml")
    File.write!(workflow, applicable_import_source())

    source_error = %TargetRegistry.Error{
      code: :import_conflict,
      message: "injected import conflict",
      path: "$.runtime"
    }

    assert {:error, %OperatorCommandService.Error{code: :import_conflict}} =
             OperatorCommandService.plan(
               %Command.Import{
                 target_id: "imported",
                 workflow: workflow,
                 repo: @manifest_fixture_root,
                 connection_id: "linear-main"
               },
               registry_path: registry_path,
               preview_import: fn _, _ -> {:error, source_error} end
             )
  end

  @tag :tmp_dir
  test "import preview dependency errors keep an existing plan during apply", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})
    workflow = Path.join(tmp_dir, "legacy.runtime.yml")
    File.write!(workflow, applicable_import_source())

    command = %Command.Import{
      target_id: "imported",
      workflow: workflow,
      repo: @manifest_fixture_root,
      connection_id: "linear-main"
    }

    assert {:ok, plan} = OperatorCommandService.plan(command, registry_path: registry_path)

    source_error = %TargetRegistry.Error{
      code: :import_conflict,
      message: "injected import conflict",
      path: "$.runtime"
    }

    assert {:error, %OperatorCommandService.Error{code: :import_conflict}} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true,
               registry_path: registry_path,
               preview_import: fn _, _ -> {:error, source_error} end
             )

    assert File.exists?(Path.join([tmp_dir, "target-plans", plan.id <> ".json"]))
  end

  @tag :tmp_dir
  test "registry missing a version returns a typed schema error", %{tmp_dir: tmp_dir} do
    registry_path = Path.join(tmp_dir, "targets.yml")
    File.write!(registry_path, Yaml.encode(%{}))

    assert {:error, %OperatorCommandService.Error{code: :missing_version}} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )
  end

  @tag :tmp_dir
  test "invalid display time cannot build a plan envelope", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})

    assert {:error, %OperatorCommandService.Error{code: :plan_corrupt}} =
             OperatorCommandService.plan(%Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path,
               now: fn -> "" end
             )
  end

  defp write_registry(tmp_dir, targets) do
    path = Path.join(tmp_dir, "targets.yml")

    document = %{
      "version" => 1,
      "host" => %{
        "id" => "test-host",
        "state_root" => Path.join(Path.dirname(tmp_dir), "state-" <> Path.basename(tmp_dir)),
        "polling" => %{"interval_ms" => 30_000, "max_concurrent_target_polls" => 1},
        "capacity" => %{
          "max_concurrent_agents" => 4,
          "max_concurrent_startups" => 2,
          "max_concurrent_reviewers" => 1
        },
        "scheduling" => %{
          "algorithm" => "weighted_deficit_round_robin",
          "max_credit_rounds" => 4
        },
        "tracker_connections" => %{
          "linear-main" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "$LINEAR_API_KEY"
          }
        },
        "runners" => %{
          "existing" => %{
            "kind" => "codex_app_server",
            "command" => ["existing", "app-server"],
            "max_concurrent_agents" => 4,
            "max_concurrent_startups" => 2
          }
        }
      },
      "targets" => targets
    }

    File.write!(path, Yaml.encode(document))
    path
  end
end
