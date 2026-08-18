defmodule SymphonyElixir.OperatorCommandServiceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OperatorCommandService
  alias SymphonyElixir.OperatorCommandService.Command
  alias SymphonyElixir.OperatorCommandService.PlanStore
  alias SymphonyElixir.TargetRegistry
  alias SymphonyElixir.TargetRegistry.{FileStore, Preview, Yaml}
  @manifest_fixture_root Path.expand("../fixtures/target_registry/repos/symphony", __DIR__)

  test "rejects maps that masquerade as typed commands" do
    assert {:error, error} =
             OperatorCommandService.plan(%{"target_id" => "alpha", "target" => %{}},
               registry_path: "/tmp/targets.yml"
             )

    assert error.code == :invalid_command
    assert error.path == "$.command"
  end

  test "patch command is typed and rejects non-string patch keys" do
    assert %Command.Patch{target_id: "alpha", changes: %{"display_name" => "Alpha"}}

    assert {:error, %OperatorCommandService.Error{code: :invalid_command}} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: %{display_name: "Alpha"}},
               registry_path: "/tmp/targets.yml"
             )
  end

  test "add and patch reject common raw provider credentials at the typed boundary" do
    for credential <- ["sk-proj-1234567890abcdef", "ghp_1234567890abcdef"],
        command <- [
          %Command.Add{target_id: "alpha", target: %{"display_name" => credential}},
          %Command.Patch{target_id: "alpha", changes: %{"display_name" => credential}}
        ] do
      assert {:error, %OperatorCommandService.Error{code: :invalid_command}} =
               OperatorCommandService.plan(command,
                 registry_path: "/tmp/definitely-missing-targets.yml"
               )
    end
  end

  test "add and patch reject common credential-key variants at the typed boundary" do
    for key <- ["client_secret", "clientSecret", "access_token", "accessToken", "bearer"],
        command <- [
          %Command.Add{target_id: "alpha", target: %{key => "ordinary-looking-value"}},
          %Command.Patch{target_id: "alpha", changes: %{key => "ordinary-looking-value"}}
        ] do
      assert {:error, %OperatorCommandService.Error{code: :invalid_command}} =
               OperatorCommandService.plan(command,
                 registry_path: "/tmp/definitely-missing-targets.yml"
               )
    end
  end

  test "add and patch allow benign credential-key near-collisions" do
    for key <- ["client_secretary", "access_tokenizer", "bearer_mode"],
        command <- [
          %Command.Add{target_id: "alpha", target: %{key => "ordinary-looking-value"}},
          %Command.Patch{target_id: "alpha", changes: %{key => "ordinary-looking-value"}}
        ] do
      assert {:error, %OperatorCommandService.Error{code: :registry_not_found}} =
               OperatorCommandService.plan(command,
                 registry_path: "/tmp/definitely-missing-targets.yml"
               )
    end
  end

  test "sensitive keys accept only structured secret references" do
    for value <- [nil, ["$PRIMARY", "${SECONDARY}"], %{"primary" => "$PRIMARY"}] do
      assert {:error, %OperatorCommandService.Error{code: :registry_not_found}} =
               OperatorCommandService.plan(
                 %Command.Add{target_id: "alpha", target: %{"authorization" => value}},
                 registry_path: "/tmp/definitely-missing-targets.yml"
               )
    end

    assert {:error, %OperatorCommandService.Error{code: :invalid_command}} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: %{"authorization" => 42}},
               registry_path: "/tmp/definitely-missing-targets.yml"
             )
  end

  test "patch allows benign keys containing sensitive substrings" do
    changes = %{
      "runners" => %{
        "settings" => %{
          "existing" => %{
            "execution_profiles" => %{
              "review" => %{"command" => [%{"tokenizer" => "bert"}]}
            }
          }
        }
      }
    }

    assert {:error, %OperatorCommandService.Error{code: :registry_not_found}} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: changes},
               registry_path: "/tmp/definitely-missing-targets.yml"
             )
  end

  test "add and patch allow benign secret-like labels" do
    for command <- [
          %Command.Add{target_id: "alpha", target: %{"display_name" => "token-based worker"}},
          %Command.Patch{
            target_id: "alpha",
            changes: %{"display_name" => "secret-santa worker"}
          }
        ] do
      assert {:error, %OperatorCommandService.Error{code: :registry_not_found}} =
               OperatorCommandService.plan(command,
                 registry_path: "/tmp/definitely-missing-targets.yml"
               )
    end
  end

  @tag :tmp_dir
  test "patch recursively merges known fixed target maps without writing", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => patch_target(tmp_dir)})
    registry_before = File.read!(registry_path)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Patch{
                 target_id: "alpha",
                 changes: %{
                   "linear" => %{"scope" => %{"project_id" => "project-2"}},
                   "worktree" => %{"hooks" => %{"timeout_ms" => 60_000}}
                 }
               },
               registry_path: registry_path
             )

    assert plan.action == :patch
    assert plan.applicable?

    assert Enum.any?(
             plan.preview["registry"]["diff"],
             &(&1["path"] == "$.targets.alpha.linear.scope.project_id" and
                 &1["after"] == "project-2")
           )

    refute Enum.any?(
             plan.preview["registry"]["diff"],
             &(&1["path"] == "$.targets.alpha.worktree.hooks.timeout_ms")
           )

    assert File.read!(registry_path) == registry_before
  end

  @tag :tmp_dir
  test "patch merges and removes exact named-map entries", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => patch_target(tmp_dir)})

    patch = %{
      "runners" => %{
        "settings" => %{
          "existing" => %{"max_turns" => 20},
          "obsolete" => nil
        }
      },
      "concurrency" => %{"by_linear_state" => %{"in-progress" => nil, "todo" => 2}}
    }

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: patch},
               registry_path: registry_path
             )

    diff = plan.preview["registry"]["diff"]

    assert Enum.any?(
             diff,
             &(&1["path"] == "$.targets.alpha.runners.settings.existing.max_turns" and
                 &1["after"] == 20)
           )

    refute Enum.any?(
             diff,
             &(&1["path"] == "$.targets.alpha.runners.settings.existing.model")
           )

    assert Enum.any?(
             diff,
             &(&1["path"] == "$.targets.alpha.runners.settings.obsolete.model" and
                 &1["after"] == nil)
           )

    assert Enum.any?(
             diff,
             &(&1["path"] == "$.targets.alpha.concurrency.by_linear_state.in-progress" and
                 &1["after"] == nil)
           )

    assert Enum.any?(
             diff,
             &(&1["path"] == "$.targets.alpha.concurrency.by_linear_state.todo" and
                 &1["after"] == 2)
           )

    assert {:ok, result} =
             OperatorCommandService.confirm("alpha", plan.id, true, registry_path: registry_path)

    assert result.action == :patch
    assert {:ok, document} = registry_path |> File.read!() |> Yaml.decode()
    target = document["targets"]["alpha"]
    assert get_in(target, ["runners", "settings", "existing", "model"]) == "base-model"
    assert get_in(target, ["runners", "settings", "existing", "max_turns"]) == 20
    refute Map.has_key?(target["runners"]["settings"], "obsolete")
    assert target["concurrency"]["by_linear_state"] == %{"todo" => 2}
  end

  @tag :tmp_dir
  test "patch replaces scalar and list fields instead of combining them", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => patch_target(tmp_dir)})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Patch{
                 target_id: "alpha",
                 changes: %{
                   "display_name" => "Renamed",
                   "linear" => %{"active_states" => ["Backlog"]}
                 }
               },
               registry_path: registry_path
             )

    assert plan.applicable?, inspect(plan.preview["registry"]["diagnostics"])

    assert {:ok, _result} =
             OperatorCommandService.confirm("alpha", plan.id, true, registry_path: registry_path)

    assert {:ok, document} = registry_path |> File.read!() |> Yaml.decode()
    target = document["targets"]["alpha"]
    assert target["display_name"] == "Renamed"
    assert target["linear"]["active_states"] == ["Backlog"]
  end

  @tag :tmp_dir
  test "patch null removes an optional known target field", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => patch_target(tmp_dir)})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: %{"display_name" => nil}},
               registry_path: registry_path
             )

    assert Enum.any?(
             plan.preview["registry"]["diff"],
             &(&1["path"] == "$.targets.alpha.display_name" and &1["after"] == nil)
           )

    assert {:ok, _result} =
             OperatorCommandService.confirm("alpha", plan.id, true, registry_path: registry_path)

    assert {:ok, document} = registry_path |> File.read!() |> Yaml.decode()
    refute Map.has_key?(document["targets"]["alpha"], "display_name")
  end

  @tag :tmp_dir
  test "patch may remove a required field only as an effectively paused draft", %{tmp_dir: tmp_dir} do
    active_target =
      tmp_dir
      |> patch_target()
      |> Map.put("state", "active")
      |> Map.put("dispatch_mode", "explicit")

    registry_path = write_registry(tmp_dir, %{"alpha" => active_target})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: %{"repo" => %{"path" => nil}}},
               registry_path: registry_path
             )

    assert plan.applicable?

    assert Enum.any?(
             plan.preview["registry"]["diagnostics"],
             &(get_in(&1, ["scope", "id"]) == "alpha" and
                 &1["path"] == "$.targets.alpha.repo.path" and
                 &1["code"] == "missing_required_field")
           )

    assert Enum.any?(
             plan.preview["registry"]["targets"],
             &(&1["id"] == "alpha" and &1["effective_state"] == "paused")
           )

    assert {:ok, _result} =
             OperatorCommandService.confirm("alpha", plan.id, true, registry_path: registry_path)

    assert {:ok, document} = registry_path |> File.read!() |> Yaml.decode()
    refute Map.has_key?(document["targets"]["alpha"]["repo"], "path")
  end

  @tag :tmp_dir
  test "patch rejects unknown target paths before storing a plan", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => patch_target(tmp_dir)})
    registry_before = File.read!(registry_path)

    for {patch, path} <- [
          {%{"unknown" => true}, "$.command.changes.unknown"},
          {%{"repo" => %{"unknown" => true}}, "$.command.changes.repo.unknown"},
          {%{"host" => %{}}, "$.command.changes.host"},
          {%{"version" => 2}, "$.command.changes.version"},
          {%{"targets" => %{"beta" => %{}}}, "$.command.changes.targets"}
        ] do
      assert {:error, error} =
               OperatorCommandService.plan(
                 %Command.Patch{target_id: "alpha", changes: patch},
                 registry_path: registry_path
               )

      assert error.code == :unknown_key
      assert error.path == path
    end

    assert File.read!(registry_path) == registry_before
    refute File.exists?(Path.join(tmp_dir, "target-plans"))
  end

  @tag :tmp_dir
  test "patch rejects state and dispatch mode keys at every depth", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => patch_target(tmp_dir)})

    cases = [
      {%{"state" => "active"}, "$.command.changes.state"},
      {%{"dispatch_mode" => "watch"}, "$.command.changes.dispatch_mode"},
      {
        %{
          "runners" => %{
            "settings" => %{
              "existing" => %{
                "execution_profiles" => %{
                  "review" => %{"command" => [%{"state" => "active"}]}
                }
              }
            }
          }
        },
        "$.command.changes.runners.settings.existing.execution_profiles.review.command[0].state"
      }
    ]

    for {patch, path} <- cases do
      assert {:error, error} =
               OperatorCommandService.plan(
                 %Command.Patch{target_id: "alpha", changes: patch},
                 registry_path: registry_path
               )

      assert error.code == :unknown_key
      assert error.path == path
    end
  end

  @tag :tmp_dir
  test "patch requires an exact non-retired target", %{tmp_dir: tmp_dir} do
    retired = tmp_dir |> patch_target() |> Map.put("state", "retired")
    registry_path = write_registry(tmp_dir, %{"retired" => retired})

    for {target_id, code} <- [
          {"absent", :target_not_found},
          {"retired", :target_retired}
        ] do
      assert {:error, error} =
               OperatorCommandService.plan(
                 %Command.Patch{target_id: target_id, changes: %{"display_name" => "Renamed"}},
                 registry_path: registry_path
               )

      assert error.code == code
    end

    refute File.exists?(Path.join(tmp_dir, "target-plans"))
  end

  @tag :tmp_dir
  test "patch planning contains globally invalid registries and invalid known-field replacements", %{
    tmp_dir: tmp_dir
  } do
    global_dir = Path.join(tmp_dir, "global")
    File.mkdir_p!(global_dir)
    globally_invalid_path = write_registry(global_dir, %{"alpha" => patch_target(tmp_dir)})
    {:ok, document} = globally_invalid_path |> File.read!() |> Yaml.decode()
    File.write!(globally_invalid_path, Yaml.encode(put_in(document, ["host"], %{})))

    assert {:error, %OperatorCommandService.Error{code: :plan_not_applicable}} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: %{"display_name" => "Renamed"}},
               registry_path: globally_invalid_path
             )

    for {index, changes} <- [
          {1, %{"concurrency" => %{"max_concurrent_agents" => 0}}},
          {2, %{"repo" => "not-a-map"}},
          {3, %{"runners" => %{"settings" => "not-a-map"}}},
          {4,
           %{
             "repo" => nil,
             "concurrency" => %{"max_concurrent_agents" => 0}
           }}
        ] do
      case_dir = Path.join(tmp_dir, "invalid-#{index}")
      File.mkdir_p!(case_dir)
      registry_path = write_registry(case_dir, %{"alpha" => patch_target(case_dir)})

      assert {:ok, plan} =
               OperatorCommandService.plan(
                 %Command.Patch{target_id: "alpha", changes: changes},
                 registry_path: registry_path
               )

      refute plan.applicable?
      assert plan.id == nil
    end
  end

  @tag :tmp_dir
  test "required patch removal permits warnings and checks later required paths", %{tmp_dir: tmp_dir} do
    target = patch_target(tmp_dir) |> Map.delete("state")
    registry_path = write_registry(tmp_dir, %{"alpha" => target})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Patch{
                 target_id: "alpha",
                 changes: %{"budgets" => %{"weekly" => %{"max_total_tokens" => nil}}}
               },
               registry_path: registry_path
             )

    assert plan.applicable?
  end

  @tag :tmp_dir
  test "patch locked rebuild contains target lifecycle and malformed-current failures", %{
    tmp_dir: tmp_dir
  } do
    for {index, mutate, expected_code} <- [
          {1, fn document -> update_in(document, ["targets"], &Map.delete(&1, "alpha")) end, :target_not_found},
          {2, fn document -> put_in(document, ["targets", "alpha", "state"], "retired") end, :target_retired},
          {3,
           fn document ->
             put_in(document, ["targets", "alpha", "concurrency", "max_concurrent_agents"], 0)
           end, :plan_not_applicable},
          {4, fn _document -> :malformed end, :invalid_yaml}
        ] do
      case_dir = Path.join(tmp_dir, "rebuild-#{index}")
      File.mkdir_p!(case_dir)
      registry_path = write_registry(case_dir, %{"alpha" => patch_target(case_dir)})

      assert {:ok, plan} =
               OperatorCommandService.plan(
                 %Command.Patch{target_id: "alpha", changes: %{"display_name" => "Renamed"}},
                 registry_path: registry_path
               )

      {:ok, document} = registry_path |> File.read!() |> Yaml.decode()

      current_bytes =
        case mutate.(document) do
          :malformed -> "["
          changed -> Yaml.encode(changed)
        end

      assert {:error, %OperatorCommandService.Error{code: ^expected_code}} =
               OperatorCommandService.apply(plan.id, plan.expected_generation, true,
                 registry_path: registry_path,
                 replace_registry: fn _path, _expected, _proposed, rebuild ->
                   rebuild.(current_bytes)
                 end
               )
    end
  end

  @tag :tmp_dir
  test "patch preview marks every policy broadening category", %{tmp_dir: tmp_dir} do
    cases = [
      {%{"external_side_effects" => %{"tracker_write" => "allow"}}, "external_side_effects"},
      {%{"runners" => %{"allowed" => ["existing", "obsolete", "other"]}}, "runners"},
      {%{"linear" => %{"required_labels" => []}}, "scope"},
      {%{"concurrency" => %{"max_concurrent_agents" => 3}}, "capacity"},
      {%{"budgets" => %{"per_run" => %{"max_total_tokens" => 2_000}}}, "budgets"}
    ]

    for {{patch, category}, index} <- Enum.with_index(cases, 1) do
      case_dir = Path.join(tmp_dir, Integer.to_string(index))
      File.mkdir_p!(case_dir)

      target =
        if category == "scope",
          do: put_in(patch_target(case_dir), ["linear", "required_labels"], ["restricted"]),
          else: patch_target(case_dir)

      registry_path = write_registry(case_dir, %{"alpha" => target})

      result =
        OperatorCommandService.plan(
          %Command.Patch{target_id: "alpha", changes: patch},
          registry_path: registry_path
        )

      plan =
        case result do
          {:ok, plan} -> plan
          error -> flunk("failed broadening category #{category}: #{inspect(error)}")
        end

      assert get_in(plan.preview, ["registry", "impact", category, "classification"]) ==
               "broadened"

      assert plan.preview["registry"]["impact"]["overall"] == "broadened",
             "failed overall broadening category #{category}: #{inspect(Enum.map(plan.preview["registry"]["impact"]["scope"]["changes"], &Map.take(&1, ["path", "classification"])))}"
    end
  end

  @tag :tmp_dir
  test "patch plan binds canonical source hash and rejects raw secrets without leakage", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => patch_target(tmp_dir)})
    fixed_now = fn -> "2026-08-16T00:00:00Z" end

    patch =
      Map.new([
        {"linear", Map.new([{"required_labels", ["safe"]}])},
        {"display_name", "Renamed"}
      ])

    assert {:ok, first} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: patch},
               registry_path: registry_path,
               now: fixed_now
             )

    reordered = %{"display_name" => "Renamed", "linear" => %{"required_labels" => ["safe"]}}

    assert {:ok, second} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: reordered},
               registry_path: registry_path,
               now: fixed_now
             )

    assert first.id == second.id
    plan_dir = Path.join(tmp_dir, "target-plans")
    assert {:ok, envelope} = PlanStore.read(plan_dir, first.id)
    patch_input = envelope["command"]["changes"]
    assert Jason.decode!(patch_input) == patch
    assert envelope["source_hashes"] == %{registry_path => Preview.generation(patch_input)}

    secret = "ghp_1234567890abcdef"
    stored_before = Path.wildcard(Path.join(plan_dir, "*.json"))

    secret_patch = %{
      "runners" => %{
        "settings" => %{
          "existing" => %{
            "execution_profiles" => %{
              "review" => %{"command" => ["tool", secret]}
            }
          }
        }
      }
    }

    assert {:error, %OperatorCommandService.Error{code: :invalid_command} = public_error} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: secret_patch},
               registry_path: registry_path
             )

    refute Jason.encode!(public_error) =~ secret
    assert Path.wildcard(Path.join(plan_dir, "*.json")) == stored_before

    Enum.each(stored_before, fn stored_path ->
      refute File.read!(stored_path) =~ secret
    end)
  end

  @tag :tmp_dir
  test "patch confirmation rejects target and action mismatches", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => patch_target(tmp_dir)})
    registry_before = File.read!(registry_path)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: %{"display_name" => "Renamed"}},
               registry_path: registry_path
             )

    assert {:error, %OperatorCommandService.Error{code: :plan_mismatch}} =
             OperatorCommandService.confirm("beta", plan.id, true, registry_path: registry_path)

    plan_dir = Path.join(tmp_dir, "target-plans")
    assert {:ok, envelope} = PlanStore.read(plan_dir, plan.id)
    forged = envelope |> Map.put("action", "add") |> rebind_plan_identity()

    assert {:error, %OperatorCommandService.Error{code: :plan_mismatch}} =
             OperatorCommandService.apply(forged["plan_id"], plan.expected_generation, true,
               registry_path: registry_path,
               read_plan: fn ^plan_dir, _id -> {:ok, forged} end
             )

    assert File.read!(registry_path) == registry_before
    assert File.exists?(Path.join(plan_dir, plan.id <> ".json"))
  end

  @tag :tmp_dir
  test "apply rejects forged envelope identity and shape before replacement", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => patch_target(tmp_dir)})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: %{"display_name" => "Renamed"}},
               registry_path: registry_path
             )

    plan_dir = Path.join(tmp_dir, "target-plans")
    assert {:ok, envelope} = PlanStore.read(plan_dir, plan.id)
    unrelated_id = String.duplicate("0", 64)

    for {forged, supplied_id} <- [
          {Map.put(envelope, "envelope_version", 999), plan.id},
          {Map.put(envelope, "created_at", "not-a-time"), plan.id},
          {Map.put(envelope, "created_at", 42), plan.id},
          {Map.put(envelope, "source_hashes", "bad"), plan.id},
          {Map.put(envelope, "unexpected", true), plan.id},
          {Map.put(envelope, "action", {:malformed, :action}), plan.id},
          {Map.put(envelope, "plan_id", unrelated_id), unrelated_id}
        ] do
      caller = self()

      assert {:error, error} =
               OperatorCommandService.apply(supplied_id, envelope["expected_generation"], true,
                 registry_path: registry_path,
                 read_plan: fn _dir, _id -> {:ok, forged} end,
                 replace_registry: fn _path, _expected, proposed, _rebuild ->
                   send(caller, :replacement_called)
                   {:ok, %{generation: proposed}}
                 end,
                 consume_plan: fn _dir, _id ->
                   send(caller, :consume_called)
                   {:ok, forged}
                 end
               )

      assert error.code in [:plan_corrupt, :plan_mismatch]
      refute_received :replacement_called
      refute_received :consume_called
    end
  end

  @tag :tmp_dir
  test "apply rejects a self-consistent add envelope containing a raw credential", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    plan_dir = Path.join(tmp_dir, "target-plans")
    assert {:ok, envelope} = PlanStore.read(plan_dir, plan.id)

    forged =
      envelope
      |> put_in(["command", "target", "clientSecret"], "ordinary-looking-value")
      |> rebind_plan_identity()

    caller = self()

    assert {:error, %OperatorCommandService.Error{code: :plan_mismatch}} =
             OperatorCommandService.apply(forged["plan_id"], plan.expected_generation, true,
               registry_path: registry_path,
               read_plan: fn _dir, _id -> {:ok, forged} end,
               replace_registry: fn _path, _expected, _proposed, _rebuild ->
                 send(caller, :replacement_called)
                 {:ok, %{generation: forged["proposed_generation"]}}
               end
             )

    refute_received :replacement_called
  end

  @tag :tmp_dir
  test "apply rejects self-consistent invalid source and patch-command bindings", %{tmp_dir: tmp_dir} do
    add_dir = Path.join(tmp_dir, "add")
    File.mkdir_p!(add_dir)
    add_registry = write_registry(add_dir, %{})

    assert {:ok, add_plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: add_registry
             )

    assert {:ok, add_envelope} =
             PlanStore.read(Path.join(add_dir, "target-plans"), add_plan.id)

    forged_add =
      add_envelope
      |> Map.put("source_hashes", %{add_registry => add_plan.expected_generation})
      |> rebind_plan_identity()

    assert {:error, %OperatorCommandService.Error{code: :plan_mismatch}} =
             OperatorCommandService.confirm(
               "alpha",
               forged_add["plan_id"],
               true,
               registry_path: add_registry,
               read_plan: fn _dir, _id -> {:ok, forged_add} end
             )

    assert {:error, %OperatorCommandService.Error{code: :plan_mismatch}} =
             OperatorCommandService.apply(
               forged_add["plan_id"],
               add_plan.expected_generation,
               true,
               registry_path: add_registry,
               read_plan: fn _dir, _id -> {:ok, forged_add} end
             )

    patch_dir = Path.join(tmp_dir, "patch")
    File.mkdir_p!(patch_dir)
    patch_registry = write_registry(patch_dir, %{"alpha" => patch_target(patch_dir)})

    assert {:ok, patch_plan} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: %{"display_name" => "Renamed"}},
               registry_path: patch_registry
             )

    assert {:ok, patch_envelope} =
             PlanStore.read(Path.join(patch_dir, "target-plans"), patch_plan.id)

    forged_patch =
      patch_envelope
      |> put_in(["command", "changes"], "{")
      |> rebind_plan_identity()

    assert {:error, %OperatorCommandService.Error{code: :plan_mismatch}} =
             OperatorCommandService.apply(
               forged_patch["plan_id"],
               patch_plan.expected_generation,
               true,
               registry_path: patch_registry,
               read_plan: fn _dir, _id -> {:ok, forged_patch} end
             )
  end

  @tag :tmp_dir
  test "patch apply rejects a stale canonical patch source", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => patch_target(tmp_dir)})
    registry_before = File.read!(registry_path)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: %{"display_name" => "Renamed"}},
               registry_path: registry_path
             )

    plan_dir = Path.join(tmp_dir, "target-plans")
    assert {:ok, envelope} = PlanStore.read(plan_dir, plan.id)

    forged =
      envelope
      |> put_in(
        ["source_hashes", registry_path],
        "sha256:" <> String.duplicate("0", 64)
      )
      |> rebind_plan_identity()

    assert {:error, error} =
             OperatorCommandService.apply(forged["plan_id"], plan.expected_generation, true,
               registry_path: registry_path,
               read_plan: fn ^plan_dir, _id -> {:ok, forged} end
             )

    assert error.code == :patch_source_changed
    assert File.read!(registry_path) == registry_before
    assert File.exists?(Path.join(plan_dir, plan.id <> ".json"))
  end

  @tag :tmp_dir
  test "patch apply rejects a stale registry generation", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => patch_target(tmp_dir)})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: %{"display_name" => "Renamed"}},
               registry_path: registry_path
             )

    changed = File.read!(registry_path) <> "# causally changed\n"
    File.write!(registry_path, changed)
    plan_path = Path.join([tmp_dir, "target-plans", plan.id <> ".json"])

    assert {:error, error} =
             OperatorCommandService.confirm("alpha", plan.id, true, registry_path: registry_path)

    assert error.code == :stale_generation
    assert File.read!(registry_path) == changed
    assert File.exists?(plan_path)
  end

  @tag :tmp_dir
  test "two concurrent patch confirmations causally produce one complete commit", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => patch_target(tmp_dir)})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: %{"display_name" => "Winner"}},
               registry_path: registry_path
             )

    parent = self()

    replace_registry = fn path, expected_generation, _proposed_generation, rebuild ->
      with {:ok, current_bytes} <- File.read(path),
           {:ok, proposed_bytes} <- rebuild.(current_bytes) do
        first_locked_read = {__MODULE__, :first_locked_read}

        guarded_read = fn ^path ->
          with {:ok, locked_bytes} <- File.read(path),
               {:ok, ^proposed_bytes} <- rebuild.(locked_bytes) do
            unless Process.get(first_locked_read) do
              Process.put(first_locked_read, true)
              send(parent, {:patch_lock_acquired, self()})

              receive do
                :release_patch_lock -> :ok
              end
            end

            {:ok, locked_bytes}
          else
            _changed -> {:error, :proposal_changed}
          end
        end

        FileStore.replace(
          path,
          proposed_bytes,
          expected_generation,
          file_ops: %{read: guarded_read}
        )
      end
    end

    confirm = fn ->
      OperatorCommandService.confirm("alpha", plan.id, true,
        registry_path: registry_path,
        replace_registry: replace_registry
      )
    end

    winner = Task.async(confirm)
    assert_receive {:patch_lock_acquired, winner_pid}, 1_000
    loser = Task.async(confirm)

    assert {:error, loser_error} = Task.await(loser)
    assert loser_error.code in [:registry_locked, :stale_generation]
    send(winner_pid, :release_patch_lock)

    assert {:ok, winner_result} = Task.await(winner)
    assert winner_result.new_generation == plan.proposed_generation

    assert {:ok, final_file} = FileStore.read(registry_path)
    assert final_file.generation == plan.proposed_generation
    assert {:ok, document} = Yaml.decode(final_file.bytes)
    assert document["targets"]["alpha"]["display_name"] == "Winner"
  end

  @tag :tmp_dir
  test "failed patch replacement leaves no partial mutation or output", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{"alpha" => patch_target(tmp_dir)})
    registry_before = File.read!(registry_path)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Patch{target_id: "alpha", changes: %{"display_name" => "Never Written"}},
               registry_path: registry_path
             )

    replace_registry = fn path, expected, _proposed, rebuild ->
      with {:ok, %{bytes: current_bytes}} <- FileStore.read(path),
           {:ok, proposed_bytes} <- rebuild.(current_bytes) do
        FileStore.replace(path, proposed_bytes, expected,
          file_ops: %{
            rename: fn temp_path, destination ->
              send(self(), {:rename_attempt, temp_path, destination})
              {:error, :injected_pre_rename_failure}
            end
          }
        )
      end
    end

    assert {:error, error} =
             OperatorCommandService.confirm("alpha", plan.id, true,
               registry_path: registry_path,
               replace_registry: replace_registry
             )

    refute error.committed?
    assert error.code == :atomic_replace_failed
    assert File.read!(registry_path) == registry_before
    assert_receive {:rename_attempt, temp_path, ^registry_path}
    assert Path.dirname(temp_path) == Path.dirname(registry_path)
    refute File.exists?(temp_path)
    assert Path.wildcard(Path.join(tmp_dir, ".targets.yml.tmp-*")) == []
    assert File.exists?(Path.join([tmp_dir, "target-plans", plan.id <> ".json"]))
    refute File.exists?(registry_path <> ".lock")
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

    forged =
      envelope
      |> Map.put("proposed_generation", "sha256:" <> String.duplicate("0", 64))
      |> rebind_plan_identity()

    assert {:error, error} =
             OperatorCommandService.apply(forged["plan_id"], plan.expected_generation, true,
               registry_path: registry_path,
               read_plan: fn ^plan_dir, _id -> {:ok, forged} end
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
          envelope |> Map.put("action", "patch") |> rebind_plan_identity(),
          envelope |> Map.put("target_id", "beta") |> rebind_plan_identity(),
          envelope |> Map.put("registry_path", registry_path <> ".other") |> rebind_plan_identity()
        ] do
      assert {:error, error} =
               OperatorCommandService.apply(forged["plan_id"], plan.expected_generation, true,
                 registry_path: registry_path,
                 read_plan: fn ^plan_dir, _id -> {:ok, forged} end
               )

      assert error.code == :plan_mismatch
      assert File.read!(registry_path) == registry_before
    end
  end

  @tag :tmp_dir
  test "normal commits preserve typed plan-consumption dependency errors", %{tmp_dir: tmp_dir} do
    failures = [
      %OperatorCommandService.Error{
        code: :plan_consume_failed,
        message: "injected service consume failure",
        path: "$.plan"
      },
      %TargetRegistry.Error{
        code: :plan_store_unavailable,
        message: "injected registry consume failure",
        path: "$.plan"
      }
    ]

    for {failure, index} <- Enum.with_index(failures, 1) do
      case_dir = Path.join(tmp_dir, "consume-#{index}")
      File.mkdir_p!(case_dir)
      registry_path = write_registry(case_dir, %{})

      assert {:ok, plan} =
               OperatorCommandService.plan(
                 %Command.Add{target_id: "alpha", target: %{}},
                 registry_path: registry_path
               )

      assert {:error, %OperatorCommandService.Error{committed?: true}} =
               OperatorCommandService.apply(plan.id, plan.expected_generation, true,
                 registry_path: registry_path,
                 consume_plan: fn _dir, _id -> {:error, failure} end
               )
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

    assert {:error, %OperatorCommandService.Error{code: :plan_corrupt}} =
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
      {import_envelope |> Map.put("source_hashes", %{}) |> rebind_plan_identity(), import_current, :plan_mismatch},
      {import_envelope
       |> Map.put("proposed_generation", "sha256:" <> String.duplicate("0", 64))
       |> rebind_plan_identity(), import_current, :proposed_generation_mismatch}
    ]

    for {envelope, current, code} <- cases do
      assert {:error, %OperatorCommandService.Error{code: ^code}} =
               OperatorCommandService.apply(envelope["plan_id"], import_plan.expected_generation, true,
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

      plan_path = Path.join([case_dir, "target-plans", plan.id <> ".json"])

      if expected_committed,
        do: refute(File.exists?(plan_path)),
        else: assert(File.exists?(plan_path))
    end
  end

  @tag :tmp_dir
  test "committed replacement reports a subsequent plan-consumption failure", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    replacer = fn path, _, _, rebuild ->
      {:ok, proposed_bytes} = path |> File.read!() |> rebuild.()
      File.write!(path, proposed_bytes)

      {:error,
       %TargetRegistry.Error{
         code: :atomic_replace_failed,
         message: "injected post-commit failure",
         path: path
       }}
    end

    consume_error = %OperatorCommandService.Error{
      code: :plan_consume_failed,
      message: "injected consume failure",
      path: "$.plan"
    }

    assert {:error, error} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true,
               registry_path: registry_path,
               replace_registry: replacer,
               consume_plan: fn _dir, _id -> {:error, consume_error} end
             )

    assert error.code == :plan_consume_failed
    assert error.committed?
    assert File.exists?(Path.join([tmp_dir, "target-plans", plan.id <> ".json"]))
  end

  @tag :tmp_dir
  test "committed replacement normalizes plan-consumption exceptions", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    replacer = fn path, _, _, rebuild ->
      {:ok, proposed_bytes} = path |> File.read!() |> rebuild.()
      File.write!(path, proposed_bytes)

      {:error,
       %TargetRegistry.Error{
         code: :atomic_replace_failed,
         message: "injected post-commit failure",
         path: path
       }}
    end

    assert {:error, error} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true,
               registry_path: registry_path,
               replace_registry: replacer,
               consume_plan: fn _dir, _id -> raise "consume failed" end
             )

    assert error.code == :plan_consume_failed
    assert error.committed?
  end

  @tag :tmp_dir
  test "normal commit rejects malformed plan-consumption success maps", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    assert {:error, error} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true,
               registry_path: registry_path,
               consume_plan: fn _dir, _id -> {:ok, %{}} end
             )

    assert error.code == :plan_consume_failed
    assert error.committed?
    assert error.observed_generation
  end

  @tag :tmp_dir
  test "commit reconciliation rejects malformed plan-consumption success maps", %{tmp_dir: tmp_dir} do
    registry_path = write_registry(tmp_dir, %{})

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.Add{target_id: "alpha", target: %{}},
               registry_path: registry_path
             )

    replacer = fn path, _, _, rebuild ->
      {:ok, proposed_bytes} = path |> File.read!() |> rebuild.()
      File.write!(path, proposed_bytes)

      {:error,
       %TargetRegistry.Error{
         code: :atomic_replace_failed,
         message: "injected post-commit failure",
         path: path
       }}
    end

    assert {:error, error} =
             OperatorCommandService.apply(plan.id, plan.expected_generation, true,
               registry_path: registry_path,
               replace_registry: replacer,
               consume_plan: fn _dir, _id -> {:ok, %{}} end
             )

    assert error.code == :plan_consume_failed
    assert error.committed?
    assert error.observed_generation
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

    assert {:error, %OperatorCommandService.Error{code: :plan_corrupt}} =
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

    assert {:ok, raised_plan} =
             OperatorCommandService.plan(
               %Command.Import{
                 target_id: "imported",
                 workflow: workflow,
                 repo: @manifest_fixture_root,
                 connection_id: "linear-main"
               },
               registry_path: registry_path,
               encode_import_preview: fn _result -> raise "encoding failed" end
             )

    assert raised_plan.preview["import"] == plan.preview["import"]
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

    service_error = %OperatorCommandService.Error{
      code: :import_preview_failed,
      message: "injected service preview failure",
      path: "$.command.workflow"
    }

    assert {:error, ^service_error} =
             OperatorCommandService.plan(
               %Command.Import{
                 target_id: "imported",
                 workflow: workflow,
                 repo: @manifest_fixture_root,
                 connection_id: "linear-main"
               },
               registry_path: registry_path,
               preview_import: fn _, _ -> {:error, service_error} end
             )

    assert {:error, %OperatorCommandService.Error{code: :import_preview_failed}} =
             OperatorCommandService.plan(
               %Command.Import{
                 target_id: "imported",
                 workflow: workflow,
                 repo: @manifest_fixture_root,
                 connection_id: "linear-main"
               },
               registry_path: registry_path,
               preview_import: fn _, _ -> raise "preview failed" end
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

  defp rebind_plan_identity(envelope) do
    identity_keys =
      ~w(action command envelope_version expected_generation proposed_generation registry_path source_hashes target_id)

    plan_id =
      envelope
      |> Map.take(identity_keys)
      |> canonical_identity_json()
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Map.put(envelope, "plan_id", plan_id)
  end

  defp canonical_identity_json(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonical_identity_json(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical_identity_json(list) when is_list(list), do: Enum.map(list, &canonical_identity_json/1)
  defp canonical_identity_json(value), do: value

  defp patch_target(tmp_dir) do
    %{
      "display_name" => "Alpha",
      "state" => "paused",
      "repo" => %{"path" => @manifest_fixture_root, "manifest" => "symphony.yml"},
      "worktree" => %{
        "root" => Path.join(Path.dirname(tmp_dir), "worktrees-" <> Path.basename(tmp_dir)),
        "strategy" => "per_issue",
        "hooks" => %{}
      },
      "linear" => %{
        "connection" => "linear-main",
        "scope" => %{"type" => "project", "project_id" => "project-1"},
        "active_states" => ["Todo", "In Progress"],
        "terminal_states" => ["Done"],
        "required_labels" => []
      },
      "runners" => %{
        "allowed" => ["existing", "obsolete"],
        "default" => "existing",
        "settings" => %{
          "existing" => %{"model" => "base-model", "max_turns" => 10},
          "obsolete" => %{"model" => "old-model"}
        }
      },
      "concurrency" => %{
        "max_concurrent_agents" => 2,
        "max_concurrent_startups" => 1,
        "max_concurrent_reviewers" => 1,
        "by_linear_state" => %{"in-progress" => 1}
      },
      "budgets" => %{
        "per_run" => %{"max_total_tokens" => 1_000},
        "daily" => %{"max_total_tokens" => 10_000},
        "weekly" => %{"max_total_tokens" => 50_000}
      },
      "checks" => %{
        "pre_dispatch" => ["capability_preflight"],
        "pre_handoff" => ["repo_validation", "quality_gate"],
        "pre_publish" => ["publish_preflight"],
        "pre_merge" => ["pr_checks", "review_feedback_sweep"]
      },
      "external_side_effects" => %{
        "tracker_write" => "deny",
        "vcs_publish" => "deny",
        "pull_request_write" => "deny",
        "merge" => "deny",
        "deployment" => "deny",
        "production_data" => "deny"
      },
      "scheduling" => %{"weight" => 10}
    }
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
          },
          "other" => %{
            "kind" => "codex_app_server",
            "command" => ["other", "app-server"],
            "max_concurrent_agents" => 4,
            "max_concurrent_startups" => 2
          },
          "obsolete" => %{
            "kind" => "codex_app_server",
            "command" => ["obsolete", "app-server"],
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
