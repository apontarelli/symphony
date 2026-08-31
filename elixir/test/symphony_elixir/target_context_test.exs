defmodule SymphonyElixir.TargetContextTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.TargetContext
  alias SymphonyElixir.TargetRegistry.Composition
  alias SymphonyElixir.TargetRegistry.Preview
  alias SymphonyElixir.TargetRegistry.Schema
  alias SymphonyElixir.TargetRegistry.Target

  @repo_fixture_root Path.expand("../fixtures/target_registry/repos", __DIR__)

  defmodule DeterministicManifestAdapter do
    @moduledoc false

    def read(_path, _opts), do: {:ok, manifest()}

    def validate(_repo_path, _manifest),
      do: %{errors: [], modules: [], preset: "default"}

    def compile(_manifest) do
      %{
        config: %{"manifest" => manifest()},
        workflow_module_resolution: %{
          module_names: ["quality"],
          module_refs: [%{name: "quality", version: "v1"}],
          policy_hash: "sha256:" <> String.duplicate("d", 64),
          rendered: "quality policy"
        }
      }
    end

    def manifest do
      %{
        "version" => 1,
        "project" => %{"repository" => "https://github.com/example/repo"},
        "workflow" => %{},
        "docs" => %{},
        "validation" => %{"commands" => [%{"command" => "mix test", "name" => "test"}]},
        "vcs" => %{},
        "delivery" => %{},
        "automation" => %{},
        "harness" => %{},
        "capabilities" => %{},
        "issue_markers" => %{"labels" => ["repo:required"]}
      }
    end
  end

  defmodule TwoTargetManifestAdapter do
    @moduledoc false

    def read(path, _opts) do
      target_id = if Path.basename(Path.dirname(path)) == "other", do: "beta", else: "alpha"
      {:ok, manifest(target_id)}
    end

    def validate(_repo_path, _manifest),
      do: %{errors: [], modules: [], preset: "default"}

    def compile(manifest) do
      target_id = manifest["project"]["name"]
      module_name = "quality-#{target_id}"

      %{
        config: %{"manifest" => manifest},
        workflow_module_resolution: %{
          module_names: [module_name],
          module_refs: [%{name: module_name, version: "v1"}],
          policy_hash: "sha256:" <> String.duplicate(if(target_id == "alpha", do: "a", else: "e"), 64),
          rendered: "#{target_id} quality policy"
        }
      }
    end

    def manifest(target_id) do
      %{
        "version" => 1,
        "project" => %{
          "name" => target_id,
          "repository" => "https://github.com/example/#{target_id}"
        },
        "workflow" => %{},
        "docs" => %{},
        "validation" => %{
          "commands" => [%{"command" => "mix test #{target_id}", "name" => "test-#{target_id}"}]
        },
        "vcs" => %{},
        "delivery" => %{},
        "automation" => %{},
        "harness" => %{},
        "capabilities" => %{},
        "issue_markers" => %{"labels" => ["repo:#{target_id}"]}
      }
    end
  end

  test "constructs a runtime context from a composed registry target" do
    snapshot = valid_snapshot()

    assert {:ok, %TargetContext{} = context} =
             TargetContext.from_registry(snapshot, "alpha", env_fetcher: fn "TRACKER_KEY" -> {:ok, "credential"} end)

    assert context.target_id == "alpha"
    assert context.registry_generation == hash("b")
    assert context.tracker_connection["policy"]["api_key"] == "credential"
  end

  test "pins validated tracker references without resolving credentials" do
    assert {:ok, %TargetContext{} = context} =
             TargetContext.pin_from_registry(valid_snapshot(), "alpha")

    assert get_in(context.tracker_connection, ["policy", "api_key"]) == "$TRACKER_KEY"
    refute inspect(context) =~ "TRACKER_KEY"
  end

  test "derives every runtime field from the real Phase 1 schema and composition pipeline" do
    assert {:ok, schema_snapshot} = Schema.validate(registry_document(), home: "/tmp")
    assert schema_snapshot.globally_valid?
    assert schema_snapshot.targets["alpha"].valid?

    composed =
      Composition.compose(schema_snapshot, manifest: DeterministicManifestAdapter)

    generation = Preview.generation("deterministic loaded registry bytes")

    loaded = %{
      composed
      | path: "/tmp/registry/targets.yml",
        source_hash: generation,
        generation: generation
    }

    target = loaded.targets["alpha"]
    assert target.valid?, inspect(target.diagnostics)
    assert target.effective_policy["scheduling"] == %{"weight" => 7}
    assert get_in(target.effective_policy, ["repo_policy", "manifest"]) == target.repo_manifest
    assert {:ok, repo_manifest_hash} = Composition.canonical_hash(target.repo_manifest)
    assert {:ok, target.policy_hash} == Composition.canonical_hash(target.effective_policy)

    assert {:ok, context} =
             TargetContext.from_registry(loaded, "alpha",
               env_fetcher: fn variable ->
                 assert variable == "TRACKER_KEY"
                 {:ok, "resolved-api-key"}
               end
             )

    expected_tracker =
      target.effective_policy["tracker_connection"]
      |> put_in(["policy", "api_key"], "resolved-api-key")
      |> Map.put(
        "coordinator_state_path",
        Path.join([
          loaded.host["state_root"],
          "tracker-connections",
          target.effective_policy["tracker_connection"]["id"] <> ".state"
        ])
      )

    assert context == %TargetContext{
             target_id: "alpha",
             state: :active,
             dispatch_mode: :watch,
             registry_generation: generation,
             policy_hash: target.policy_hash,
             repo_manifest_hash: repo_manifest_hash,
             issue_policy_authority: nil,
             workspace_layout: :flat,
             repo_policy: target.effective_policy["repo_policy"],
             tracker_connection: expected_tracker,
             run_target: target.effective_policy["run_target"],
             worktree_policy: target.effective_policy["worktree_policy"],
             runner_policy: target.effective_policy["runner_policy"],
             effective_checks: target.effective_policy["effective_checks"],
             external_side_effect_gates: target.effective_policy["external_side_effect_gates"],
             capacity_limits: target.effective_policy["capacity_limits"],
             budget_limits: target.effective_policy["budget_limits"]
           }

    context_fields = Map.from_struct(context)
    refute Map.has_key?(context_fields, :configured)
    refute Map.has_key?(context_fields, :diagnostics)
    refute Map.has_key?(context_fields, :scheduling)
  end

  test "rejects a self-consistently rehashed policy forgery before secret resolution" do
    snapshot = valid_snapshot()
    target = snapshot.targets["alpha"]
    private_value = "attacker-private-capacity"
    policy = put_in(target.effective_policy, ["capacity_limits", "max_concurrent_agents"], private_value)
    forged_target = %{target | effective_policy: policy, policy_hash: canonical_hash(policy)}
    forged_snapshot = %{snapshot | targets: %{"alpha" => forged_target}}

    result =
      TargetContext.from_registry(forged_snapshot, "alpha", env_fetcher: fn _variable -> flunk("resolver must not be invoked") end)

    assert result == {:error, :invalid_composed_target}
    refute inspect(result) =~ private_value
  end

  test "isolates two real composed target contexts under causally synchronized concurrency" do
    snapshot = two_target_snapshot()
    parent = self()

    tasks =
      for {target_id, variable, credential} <- [
            {"alpha", "ALPHA_KEY", "alpha-credential"},
            {"beta", "BETA_KEY", "beta-credential"}
          ],
          into: %{} do
        task =
          Task.async(fn ->
            send(parent, {:context_ready, target_id, self()})

            receive do
              {:build_context, ^target_id} ->
                TargetContext.from_registry(snapshot, target_id,
                  env_fetcher: fn resolved_variable ->
                    send(parent, {:secret_resolved, target_id, resolved_variable})
                    {:ok, credential}
                  end
                )
            end
          end)

        {target_id, {task, variable, credential}}
      end

    task_pids =
      for target_id <- ["alpha", "beta"], into: %{} do
        assert_receive {:context_ready, ^target_id, task_pid}
        {target_id, task_pid}
      end

    Enum.each(task_pids, fn {target_id, task_pid} ->
      send(task_pid, {:build_context, target_id})
    end)

    contexts =
      Map.new(tasks, fn {target_id, {task, variable, credential}} ->
        assert {:ok, context} = Task.await(task)
        assert_receive {:secret_resolved, ^target_id, ^variable}
        assert context.tracker_connection["policy"]["api_key"] == credential
        {target_id, context}
      end)

    for {target_id, context} <- contexts do
      target = snapshot.targets[target_id]
      policy = target.effective_policy
      assert {:ok, manifest_hash} = Composition.canonical_hash(target.repo_manifest)

      assert context.target_id == target_id
      assert context.state == target.effective_state
      assert context.dispatch_mode == target.dispatch_mode
      assert context.registry_generation == snapshot.generation
      assert context.policy_hash == target.policy_hash
      assert context.repo_manifest_hash == manifest_hash
      assert context.repo_policy == policy["repo_policy"]
      assert context.run_target == policy["run_target"]
      assert context.worktree_policy == policy["worktree_policy"]
      assert context.runner_policy == policy["runner_policy"]
      assert context.effective_checks == policy["effective_checks"]
      assert context.external_side_effect_gates == policy["external_side_effect_gates"]
      assert context.capacity_limits == policy["capacity_limits"]
      assert context.budget_limits == policy["budget_limits"]
    end

    alpha = contexts["alpha"]
    beta = contexts["beta"]

    for field <- [
          :target_id,
          :state,
          :dispatch_mode,
          :policy_hash,
          :repo_manifest_hash,
          :repo_policy,
          :tracker_connection,
          :run_target,
          :worktree_policy,
          :runner_policy,
          :effective_checks,
          :external_side_effect_gates,
          :capacity_limits,
          :budget_limits
        ] do
      refute Map.fetch!(alpha, field) == Map.fetch!(beta, field)
    end
  end

  test "ignores poisoned process-global configuration when an explicit resolver is supplied" do
    keys = [
      :workflow_file_path,
      :default_workflow_file_path,
      :workflow_profile_override,
      :linear_client_module,
      :memory_tracker_issues
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:symphony_elixir, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
        {key, :error} -> Application.delete_env(:symphony_elixir, key)
      end)
    end)

    Enum.each(keys, fn key ->
      Application.put_env(:symphony_elixir, key, {:poisoned, key, "global-secret"})
    end)

    snapshot = valid_snapshot()
    target = snapshot.targets["alpha"]

    assert {:ok, context} =
             TargetContext.from_registry(snapshot, "alpha",
               env_fetcher: fn variable ->
                 assert variable == "TRACKER_KEY"
                 {:ok, "explicit-credential"}
               end
             )

    assert context.tracker_connection["policy"]["api_key"] == "explicit-credential"
    assert context.worktree_policy == target.effective_policy["worktree_policy"]
    assert context.runner_policy == target.effective_policy["runner_policy"]
    refute inspect(context) =~ "global-secret"
  end

  test "rejects snapshots outside global validity and generation authority" do
    assert {:error, :invalid_snapshot} = TargetContext.from_registry(%{}, "alpha")

    assert {:error, :invalid_snapshot} =
             TargetContext.from_registry(%{valid_snapshot() | globally_valid?: false}, "alpha")

    for generation <- [nil, "", "sha256:ABC", "sha256:" <> String.duplicate("a", 63)] do
      assert {:error, :invalid_registry_generation} =
               TargetContext.from_registry(%{valid_snapshot() | generation: generation}, "alpha")
    end
  end

  test "requires a Phase 1 version 1 snapshot" do
    assert {:error, :invalid_snapshot} =
             TargetContext.from_registry(%{valid_snapshot() | version: 2}, "alpha", env_fetcher: fn "TRACKER_KEY" -> {:ok, "credential"} end)
  end

  test "requires the loaded snapshot host and containers to retain their shapes" do
    snapshots = [
      %{valid_snapshot() | host: nil},
      %{valid_snapshot() | targets: []},
      %{valid_snapshot() | diagnostics: :invalid},
      %{valid_snapshot() | diagnostics: [:valid | :invalid]}
    ]

    for snapshot <- snapshots do
      assert {:error, :invalid_snapshot} =
               TargetContext.from_registry(snapshot, "alpha", env_fetcher: fn "TRACKER_KEY" -> {:ok, "credential"} end)
    end
  end

  test "requires a nonblank UTF-8 loaded registry path" do
    for path <- [nil, "", " \t\n", <<0xFF>>, :path] do
      assert {:error, :invalid_snapshot} =
               TargetContext.from_registry(%{valid_snapshot() | path: path}, "alpha", env_fetcher: fn "TRACKER_KEY" -> {:ok, "credential"} end)
    end
  end

  test "requires source hash and generation to be the same valid loaded-file hash" do
    snapshots = [
      %{valid_snapshot() | source_hash: nil},
      %{valid_snapshot() | source_hash: hash("c")},
      %{valid_snapshot() | source_hash: "sha256:ABC"}
    ]

    for snapshot <- snapshots do
      assert {:error, :invalid_registry_generation} =
               TargetContext.from_registry(snapshot, "alpha", env_fetcher: fn "TRACKER_KEY" -> {:ok, "credential"} end)
    end
  end

  test "requires an exact string identifier and an existing valid target" do
    assert {:error, :invalid_target_id} = TargetContext.from_registry(valid_snapshot(), :alpha)
    assert {:error, :target_not_found} = TargetContext.from_registry(valid_snapshot(), "missing")

    invalid_targets = [
      %{valid_target() | valid?: false},
      %{valid_target() | id: "other"},
      :forged
    ]

    for target <- invalid_targets do
      assert {:error, :invalid_target} =
               TargetContext.from_registry(valid_snapshot(target), "alpha")
    end
  end

  test "requires target IDs to match the authoritative Phase 1 grammar" do
    for id <- ["", "-alpha", "alpha-", "Alpha", "alpha_beta", <<0xFF>>] do
      target = %{valid_target() | id: id}
      snapshot = %{valid_snapshot(target) | targets: %{id => target}}

      assert {:error, :invalid_target_id} =
               TargetContext.from_registry(snapshot, id, env_fetcher: fn "TRACKER_KEY" -> {:ok, "credential"} end)
    end
  end

  test "rejects malformed effective target states" do
    for state <- [nil, :unknown, "active"] do
      target = %{valid_target() | effective_state: state}

      assert {:error, :invalid_target_state} =
               TargetContext.from_registry(valid_snapshot(target), "alpha")
    end
  end

  test "rejects malformed dispatch modes" do
    for mode <- [:unknown, "explicit", 1] do
      target = %{valid_target() | dispatch_mode: mode}

      assert {:error, :invalid_dispatch_mode} =
               TargetContext.from_registry(valid_snapshot(target), "alpha")
    end
  end

  test "requires active targets to retain an explicit or watch dispatch mode" do
    target = %{valid_target() | effective_state: :active, dispatch_mode: nil}

    assert {:error, :invalid_dispatch_mode} =
             TargetContext.from_registry(valid_snapshot(target), "alpha", env_fetcher: fn "TRACKER_KEY" -> {:ok, "credential"} end)
  end

  test "allows nil dispatch mode only for valid non-active states" do
    for state <- [:paused, :draining, :retired] do
      base = valid_target()

      configured =
        base.configured
        |> Map.put("state", Atom.to_string(state))
        |> Map.delete("dispatch_mode")

      target = %{
        base
        | configured: configured,
          configured_state: state,
          effective_state: state,
          dispatch_mode: nil
      }

      assert {:ok, %TargetContext{state: ^state, dispatch_mode: nil}} =
               TargetContext.from_registry(valid_snapshot(target), "alpha", env_fetcher: fn "TRACKER_KEY" -> {:ok, "credential"} end)
    end
  end

  test "rejects target policy hashes outside the generation domain" do
    for policy_hash <- [nil, "sha256:ABC", "sha256:" <> String.duplicate("0", 65)] do
      target = %{valid_target() | policy_hash: policy_hash}

      assert {:error, :invalid_policy_hash} =
               TargetContext.from_registry(valid_snapshot(target), "alpha")
    end
  end

  test "rejects a syntactically valid policy hash that does not authenticate the policy" do
    target = %{valid_target() | policy_hash: hash("f")}

    assert {:error, :policy_hash_mismatch} =
             TargetContext.from_registry(valid_snapshot(target), "alpha")
  end

  test "requires a map repository manifest" do
    for manifest <- [nil, [], "manifest"] do
      target = %{valid_target() | repo_manifest: manifest}

      assert {:error, :invalid_repo_manifest} =
               TargetContext.from_registry(valid_snapshot(target), "alpha")
    end
  end

  test "rejects a repository manifest copy that differs from composed policy" do
    target = %{valid_target() | repo_manifest: %{"project" => %{"repository" => "other/repo"}}}

    assert {:error, :repo_manifest_mismatch} =
             TargetContext.from_registry(valid_snapshot(target), "alpha")
  end

  test "rejects effective policies that are not recursively JSON-safe string maps" do
    unsafe_values = [
      %{"safe" => true, unsafe: true},
      fn -> :private end,
      ["valid" | :invalid],
      <<0xFF>>,
      %{1 => "invalid"},
      %{"key" => 1, key: 2}
    ]

    for unsafe <- unsafe_values do
      policy = put_in(effective_policy(), ["scheduling", "unsafe"], unsafe)
      target = %{valid_target() | effective_policy: policy}

      assert {:error, :effective_policy_not_json_safe} =
               TargetContext.from_registry(valid_snapshot(target), "alpha")
    end
  end

  test "requires the exact Phase 1 effective-policy top-level key set" do
    policies = [
      Map.delete(effective_policy(), "scheduling"),
      Map.put(effective_policy(), "forged", %{})
    ]

    for policy <- policies do
      target = %{valid_target() | effective_policy: policy}

      assert {:error, :invalid_policy_projection} =
               TargetContext.from_registry(valid_snapshot(target), "alpha")
    end
  end

  test "requires exact composed repository policy linkage and provenance" do
    repo_policy = effective_policy()["repo_policy"]

    malformed_repo_policies = [
      Map.delete(repo_policy, "workflow_module_resolution"),
      Map.delete(repo_policy, "manifest_source_dir"),
      Map.put(repo_policy, "unknown", "forged"),
      Map.put(repo_policy, "manifest_source_dir", "relative/source"),
      Map.put(repo_policy, "manifest_source_dir", <<0xFF>>),
      Map.put(repo_policy, "manifest_source_dir", 42)
    ]

    for malformed_repo_policy <- malformed_repo_policies do
      policy = put_in(effective_policy(), ["repo_policy"], malformed_repo_policy)
      target = %{valid_target() | effective_policy: policy}

      assert {:error, :invalid_policy_projection} =
               TargetContext.from_registry(valid_snapshot(target), "alpha")
    end
  end

  test "rejects a repository policy missing its manifest before secret resolution" do
    policy = update_in(effective_policy(), ["repo_policy"], &Map.delete(&1, "manifest"))
    target = %{valid_target() | effective_policy: policy}

    assert {:error, :invalid_policy_projection} =
             TargetContext.from_registry(valid_snapshot(target), "alpha", env_fetcher: fn _variable -> flunk("resolver must not be invoked") end)
  end

  test "rejects malformed nested tracker policy before secret resolution" do
    policy =
      put_in(effective_policy(), ["tracker_connection", "policy", "unsafe"], ["valid" | :invalid])

    target = %{valid_target() | effective_policy: policy}

    assert {:error, :effective_policy_not_json_safe} =
             TargetContext.from_registry(valid_snapshot(target), "alpha", env_fetcher: fn _variable -> flunk("resolver must not be invoked") end)
  end

  test "requires every projected effective policy subtree to be a map" do
    assert {:error, :invalid_policy_projection} =
             TargetContext.from_registry(
               valid_snapshot(%{valid_target() | effective_policy: nil}),
               "alpha"
             )

    for key <- Map.keys(effective_policy()) do
      missing = Map.delete(effective_policy(), key)
      malformed = Map.put(effective_policy(), key, :invalid)

      for policy <- [missing, malformed] do
        target = %{valid_target() | effective_policy: policy}

        assert {:error, :invalid_policy_projection} =
                 TargetContext.from_registry(valid_snapshot(target), "alpha")
      end
    end
  end

  test "rejects non-JSON-safe repository manifests" do
    manifests = [
      %{"unsafe" => fn -> :secret end},
      %{"unsafe" => ["valid" | :invalid]},
      %{"key" => 1, key: 2},
      %{42 => "invalid key"},
      %{<<0xFF>> => "invalid UTF-8 key"}
    ]

    for manifest <- manifests do
      policy = put_in(effective_policy(), ["repo_policy", "manifest"], manifest)
      target = %{valid_target() | repo_manifest: manifest, effective_policy: policy}

      assert {:error, :repo_manifest_not_json_safe} =
               TargetContext.from_registry(valid_snapshot(target), "alpha")
    end
  end

  test "reports missing secrets for absent or blank environment values" do
    for result <- [:error, {:ok, ""}, {:ok, " \t\n"}] do
      assert {:error, :missing_secret} =
               TargetContext.from_registry(valid_snapshot(), "alpha", env_fetcher: fn "TRACKER_KEY" -> result end)
    end
  end

  test "contains malformed environment resolver contracts" do
    malformed_results = [nil, :unexpected, {:error, :private_reason}, {:ok, 42}, {:ok, <<0xFF>>}]

    for result <- malformed_results do
      assert {:error, :secret_resolution_failed} =
               TargetContext.from_registry(valid_snapshot(), "alpha", env_fetcher: fn "TRACKER_KEY" -> result end)
    end

    assert {:error, :secret_resolution_failed} =
             TargetContext.from_registry(valid_snapshot(), "alpha", env_fetcher: :not_a_function)
  end

  test "contains malformed options without invoking secret resolution" do
    assert {:error, :invalid_options} =
             TargetContext.from_registry(valid_snapshot(), "alpha", [:not_a_keyword])

    assert {:error, :invalid_options} =
             TargetContext.from_registry(valid_snapshot(), "alpha", %{env_fetcher: fn _ -> :error end})
  end

  test "rejects unknown options before invoking secret resolution" do
    assert {:error, :invalid_options} =
             TargetContext.from_registry(valid_snapshot(), "alpha",
               unknown: true,
               env_fetcher: fn _variable -> flunk("resolver must not be invoked") end
             )
  end

  test "rejects duplicate environment resolvers before invoking either" do
    resolver = fn _variable -> flunk("resolver must not be invoked") end

    assert {:error, :invalid_options} =
             TargetContext.from_registry(valid_snapshot(), "alpha",
               env_fetcher: resolver,
               env_fetcher: resolver
             )
  end

  test "contains raised, thrown, and exited environment resolvers" do
    private_reason = "private-resolver-reason"

    resolvers = [
      fn "TRACKER_KEY" -> raise private_reason end,
      fn "TRACKER_KEY" -> throw(private_reason) end,
      fn "TRACKER_KEY" -> exit(private_reason) end
    ]

    for resolver <- resolvers do
      result = TargetContext.from_registry(valid_snapshot(), "alpha", env_fetcher: resolver)
      assert result == {:error, :secret_resolution_failed}
      refute inspect(result) =~ private_reason
    end
  end

  test "rejects unsupported secret providers without invoking the resolver" do
    for reference <- ["secret://vault/tracker", "secret://vault/tracker/key-1"] do
      target = target_with_secret_reference(reference)

      assert {:error, :unsupported_secret_provider} =
               TargetContext.from_registry(valid_snapshot(target), "alpha", env_fetcher: fn _variable -> flunk("resolver must not be invoked") end)
    end
  end

  test "rejects malformed secret-provider references without invoking the resolver" do
    references = [
      "secret://",
      "secret://vault",
      "secret:///tracker",
      "secret://vault/",
      "secret://vault//tracker",
      "secret://vault/tracker/",
      "secret://vault/tracker key",
      "secret://vault/tracker\nkey",
      "secret://vault/tracker\0key"
    ]

    for reference <- references do
      target = target_with_secret_reference(reference)

      assert {:error, :invalid_secret_reference} =
               TargetContext.from_registry(valid_snapshot(target), "alpha", env_fetcher: fn _variable -> flunk("resolver must not be invoked") end)
    end
  end

  test "resolves both environment reference forms using only the bare variable name" do
    for reference <- ["$TRACKER_KEY", "${TRACKER_KEY}"] do
      policy =
        effective_policy()
        |> put_in(["tracker_connection", "policy", "api_key"], reference)

      target = target_with_policy(policy)

      assert {:ok, context} =
               TargetContext.from_registry(valid_snapshot(target), "alpha",
                 env_fetcher: fn variable ->
                   assert variable == "TRACKER_KEY"
                   {:ok, "resolved-value"}
                 end
               )

      assert context.tracker_connection["policy"]["api_key"] == "resolved-value"
    end
  end

  test "resolves every Phase 1 environment name using the full bare name" do
    for {reference, expected_name} <- [
          {"$A.B", "A.B"},
          {"$1PASSWORD", "1PASSWORD"},
          {"${API-KEY}", "API-KEY"}
        ] do
      target = target_with_secret_reference(reference)

      assert {:ok, context} =
               TargetContext.from_registry(valid_snapshot(target), "alpha",
                 env_fetcher: fn variable ->
                   assert variable == expected_name
                   {:ok, "resolved-value"}
                 end
               )

      assert context.tracker_connection["policy"]["api_key"] == "resolved-value"
    end
  end

  test "rejects malformed secret references without invoking the resolver" do
    references = ["", "$", "${}", "$BAD/NAME", "${BAD NAME}", "$TRACKER_KEY trailing", "$TRACKER_KEY\n", "literal"]

    for reference <- references do
      target = target_with_secret_reference(reference)

      assert {:error, :invalid_secret_reference} =
               TargetContext.from_registry(valid_snapshot(target), "alpha", env_fetcher: fn _variable -> flunk("resolver must not be invoked") end)
    end
  end

  test "rejects malformed nested tracker projections" do
    malformed_connections = [
      %{},
      %{"policy" => nil},
      %{"policy" => %{}},
      %{"policy" => %{"api_key" => 42}}
    ]

    for tracker_connection <- malformed_connections do
      policy = Map.put(effective_policy(), "tracker_connection", tracker_connection)
      target = %{valid_target() | effective_policy: policy}

      assert {:error, :invalid_policy_projection} =
               TargetContext.from_registry(valid_snapshot(target), "alpha")
    end
  end

  test "projects only runtime policy subtrees without configured YAML or diagnostics" do
    target = valid_target()

    assert {:ok, context} = context_for(target)

    assert context.repo_policy == target.effective_policy["repo_policy"]
    assert context.run_target == target.effective_policy["run_target"]
    assert context.worktree_policy == target.effective_policy["worktree_policy"]
    assert context.runner_policy == target.effective_policy["runner_policy"]
    assert context.effective_checks == target.effective_policy["effective_checks"]
    assert context.external_side_effect_gates == target.effective_policy["external_side_effect_gates"]
    assert context.capacity_limits == target.effective_policy["capacity_limits"]
    assert context.budget_limits == target.effective_policy["budget_limits"]
    refute Map.has_key?(Map.from_struct(context), :configured)
    refute Map.has_key?(Map.from_struct(context), :diagnostics)
  end

  test "uses System.fetch_env directly when no resolver is supplied" do
    target = target_with_secret_reference("$SYMPHONY_TARGET_CONTEXT_TEST_MISSING_SID_407")
    assert {:error, :missing_secret} = TargetContext.from_registry(valid_snapshot(target), "alpha")
  end

  test "hashes only the repository manifest with canonical map ordering" do
    manifest = repo_manifest()
    reordered = manifest |> Enum.reverse() |> Map.new()

    base = target_with_manifest(manifest)

    restricted_policy =
      put_in(base.effective_policy, ["run_target", "required_labels"], ["repo:required", "restricted"])

    restricted = %{
      base
      | configured: put_in(base.configured, ["linear", "required_labels"], ["restricted"]),
        effective_policy: restricted_policy,
        policy_hash: canonical_hash(restricted_policy)
    }

    reordered_target = target_with_manifest(reordered)
    changed = target_with_manifest(put_in(manifest, ["version"], 2))

    assert {:ok, base_context} = context_for(base)
    assert {:ok, restricted_context} = context_for(restricted)
    assert {:ok, reordered_context} = context_for(reordered_target)
    assert {:ok, changed_context} = context_for(changed)
    assert {:ok, expected_hash} = Composition.canonical_hash(manifest)

    assert base_context.repo_manifest_hash == expected_hash
    assert restricted_context.repo_manifest_hash == base_context.repo_manifest_hash
    assert reordered_context.repo_manifest_hash == base_context.repo_manifest_hash
    refute changed_context.repo_manifest_hash == base_context.repo_manifest_hash
    refute restricted_context.policy_hash == base_context.policy_hash
  end

  test "redacts secret references and credentials from inspection" do
    reference = "${TRACKER_KEY}"
    credential = "credential-that-must-not-appear"
    target = target_with_secret_reference(reference)

    assert {:ok, context} = context_for(target, credential)

    rendered = inspect(context)
    assert rendered =~ "SymphonyElixir.TargetContext"
    assert rendered =~ "alpha"
    assert rendered =~ context.policy_hash
    assert rendered =~ context.repo_manifest_hash
    refute rendered =~ reference
    refute rendered =~ credential
    refute rendered =~ "tracker_connection"
  end

  test "issue_policy derives a restrictive issue policy only from the pinned context" do
    assert {:ok, context} = context_for(valid_target())

    manifest = %{
      "version" => 1,
      "project" => %{
        "repository" => "https://github.com/example/repo",
        "slug" => "alpha",
        "criticality" => "production",
        "deployment_coupling" => "production"
      },
      "workflow" => %{"modules" => ["delivery.github_pr"]},
      "docs" => %{},
      "validation" => %{"commands" => [%{"name" => "test", "command" => "mix test"}]},
      "vcs" => %{},
      "delivery" => %{"pr_target" => "main"},
      "automation" => %{
        "profile" => "strict",
        "completion_requirements" => ["tests-green"],
        "review" => %{"mode" => "required"}
      },
      "auto_land" => %{"posture" => "strict", "dry_run" => false, "required_checks" => ["ci"]},
      "harness" => %{},
      "capabilities" => %{"required" => ["github_pr"]},
      "issue_markers" => %{"labels" => ["repo:required"], "allowed_projects" => []}
    }

    context = put_in(context.repo_policy["manifest"], manifest)

    issue = %SymphonyElixir.Linear.Issue{
      id: "issue-policy",
      identifier: "SID-POLICY",
      title: "Pinned policy",
      state: "Todo",
      project_slug: "alpha",
      labels: ["repo:required", "target:required"]
    }

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :workflow_profile_override)
      Application.delete_env(:symphony_elixir, :run_setup)
      Application.delete_env(:symphony_elixir, :workflow_file_path)
    end)

    Application.put_env(:symphony_elixir, :workflow_profile_override, "poisoned")
    Application.put_env(:symphony_elixir, :run_setup, %{restrictive_flags: [:human_review_only]})
    Application.put_env(:symphony_elixir, :workflow_file_path, "/private/poisoned-workflow.yml")

    assert {:ok, policy} =
             TargetContext.issue_policy(context, issue,
               profile: "strict",
               restrictive_flags: [:no_land, :require_review]
             )

    assert policy["delivery"] == %{"pr_target" => "main"}

    assert policy["publish_target"] == %{
             "repository" => "https://github.com/example/repo",
             "pr_target" => "main",
             "github_repository" => "example/repo",
             "display" => "example/repo:main"
           }

    assert policy["checks"] == [%{"name" => "test", "command" => "mix test"}]
    assert policy["completion_requirements"] == ["tests-green"]
    assert policy["auto_land"]["posture"] == "off"
    assert policy["auto_land"]["dry_run"]
    assert policy["review_requirements"] == ["Run setup requires review evidence before handoff."]
    assert policy["run_setup"]["restrictive_flags"] == ["no_land", "require_review"]
    assert policy["target_restrictions"]["run_target"] == context.run_target
    assert policy["target_restrictions"]["external_side_effect_gates"] == context.external_side_effect_gates
    assert get_in(policy, ["policy_metadata", "profile"]) == "strict"
    assert get_in(policy, ["policy_metadata", "project_slug"]) == "alpha"
    assert get_in(policy, ["policy_metadata", "labels"]) == ["repo:required", "target:required"]
    assert get_in(policy, ["policy_metadata", "state"]) == "todo"
    assert policy["policy_ref"] =~ ~r/^[0-9a-f]{12}$/
  end

  test "issue_policy enforces repository labels independently of target labels" do
    context = issue_policy_context()
    context = put_in(context.repo_policy["manifest"]["issue_markers"]["labels"], ["manifest:required"])

    issue = %SymphonyElixir.Linear.Issue{
      id: "repo-label-policy",
      identifier: "SID-REPO-LABEL",
      title: "Repository label policy",
      state: "Todo",
      project_slug: "alpha",
      labels: ["repo:required", "target:required"]
    }

    assert {:error, :forbidden_policy_broadening} =
             TargetContext.issue_policy(context, issue, [])
  end

  test "issue_policy normalizes repository allowed projects before enforcing them" do
    context = issue_policy_context()
    context = put_in(context.repo_policy["manifest"]["issue_markers"]["allowed_projects"], [" alpha "])

    issue = %SymphonyElixir.Linear.Issue{
      id: "repo-project-policy",
      identifier: "SID-REPO-PROJECT",
      title: "Repository project policy",
      state: "Todo",
      project_slug: "alpha",
      labels: ["repo:required", "target:required"]
    }

    assert {:ok, _policy} = TargetContext.issue_policy(context, issue, [])

    outside_context =
      put_in(context.repo_policy["manifest"]["issue_markers"]["allowed_projects"], [" outside "])

    assert {:error, :forbidden_policy_broadening} =
             TargetContext.issue_policy(outside_context, issue, [])
  end

  test "issue_policy enforces the pinned issue identifier scope" do
    context = issue_policy_context()

    context =
      put_in(
        context.run_target["scope"],
        %{"type" => "issues", "issue_ids" => ["SID-POLICY-COVERAGE", "SID-OTHER"]}
      )

    assert {:ok, _policy} = TargetContext.issue_policy(context, issue_policy_issue(), [])

    assert {:error, :forbidden_policy_broadening} =
             TargetContext.issue_policy(
               context,
               issue_policy_issue(%{identifier: "SID-OUTSIDE"}),
               []
             )
  end

  test "issue_policy enforces the pinned team scope" do
    context = issue_policy_context()
    context = put_in(context.run_target["scope"], %{"type" => "team", "team_key" => "SID"})

    assert {:ok, _policy} =
             TargetContext.issue_policy(context, issue_policy_issue(%{team_key: "sid"}), [])

    assert {:error, :forbidden_policy_broadening} =
             TargetContext.issue_policy(
               context,
               issue_policy_issue(%{team_key: "OTHER"}),
               []
             )
  end

  test "issue_policy enforces the pinned project scope" do
    context = issue_policy_context()

    assert {:ok, _policy} = TargetContext.issue_policy(context, issue_policy_issue(), [])

    assert {:error, :forbidden_policy_broadening} =
             TargetContext.issue_policy(
               context,
               issue_policy_issue(%{project_slug: "outside"}),
               []
             )
  end

  test "issue_policy accepts explicit legacy issue, team, and project scopes" do
    context = issue_policy_context()
    issue = issue_policy_issue(%{team_key: "sid"})

    for scope <- [
          %{"type" => "issues", "issue_ids" => ["SID-POLICY-COVERAGE"]},
          %{"type" => "team", "team_key" => "SID"},
          %{"type" => "project", "project_slug" => "alpha"}
        ] do
      legacy_run_target =
        context.run_target
        |> Map.delete("scope")
        |> Map.merge(scope)

      assert {:ok, _policy} =
               TargetContext.issue_policy(%{context | run_target: legacy_run_target}, issue, [])
    end
  end

  test "issue_policy infers legacy issue, team, and project scopes" do
    context = issue_policy_context()
    issue = issue_policy_issue(%{team_key: "sid"})

    for scope <- [
          %{"issue_ids" => ["SID-POLICY-COVERAGE"]},
          %{"team_key" => "SID"},
          %{"project_slug" => "alpha"}
        ] do
      legacy_run_target =
        context.run_target
        |> Map.delete("scope")
        |> Map.merge(scope)

      assert {:ok, _policy} =
               TargetContext.issue_policy(%{context | run_target: legacy_run_target}, issue, [])
    end
  end

  test "issue_policy rejects malformed or unverifiable target scopes" do
    context = issue_policy_context()
    issue = issue_policy_issue()

    for scope <- [
          %{},
          %{"type" => "project"},
          %{"type" => "team"},
          %{"type" => "issues", "issue_ids" => []},
          %{"type" => "issues", "issue_ids" => "SID-POLICY-COVERAGE"},
          %{"type" => "query", "query_file" => "private-query.graphql"},
          %{"type" => "unsupported", "team_key" => "SID"},
          %{"type" => "team", "team_key" => "SID", "project_slug" => "alpha"}
        ] do
      assert TargetContext.issue_policy(put_in(context.run_target["scope"], scope), issue, []) ==
               {:error, :malformed_composed_policy}
    end

    assert TargetContext.issue_policy(put_in(context.run_target["scope"], "team"), issue, []) ==
             {:error, :malformed_composed_policy}
  end

  test "issue_policy rejects malformed legacy scopes with typed secret-safe errors" do
    context = issue_policy_context()
    issue = issue_policy_issue()
    private_scope_type = "private-unsupported-scope"
    private_scope_field = "private-unrecognized-scope-field"
    private_run_target = "private-non-map-run-target"

    malformed_run_targets = [
      {context.run_target
       |> Map.delete("scope")
       |> Map.put("type", private_scope_type), private_scope_type},
      {context.run_target
       |> Map.delete("scope")
       |> Map.put("private", private_scope_field), private_scope_field},
      {private_run_target, private_run_target}
    ]

    for {run_target, private_value} <- malformed_run_targets do
      result = TargetContext.issue_policy(%{context | run_target: run_target}, issue, [])

      assert result == {:error, :malformed_composed_policy}
      refute inspect(result) =~ private_value
    end
  end

  test "issue_policy requires canonical repository issue marker fields" do
    context = issue_policy_context()
    issue = issue_policy_issue()

    for markers <- [
          %{"labels" => []},
          %{"allowed_projects" => []},
          %{"labels" => "repo:required", "allowed_projects" => []},
          %{"labels" => [], "allowed_projects" => "alpha"},
          %{"labels" => [], "allowed_projects" => [], "unsupported" => []}
        ] do
      malformed = put_in(context.repo_policy["manifest"]["issue_markers"], markers)

      assert TargetContext.issue_policy(malformed, issue, []) ==
               {:error, :malformed_composed_policy}
    end
  end

  test "issue_policy accepts absent issue state only without an active-state constraint" do
    context = issue_policy_context()
    unconstrained_context = put_in(context.run_target["active_states"], [])

    issue = %SymphonyElixir.Linear.Issue{
      id: "nil-state-policy",
      identifier: "SID-NIL-STATE",
      title: "Absent issue state",
      state: nil,
      project_slug: "alpha",
      labels: ["repo:required", "target:required"]
    }

    assert {:ok, policy} = TargetContext.issue_policy(unconstrained_context, issue, [])
    assert get_in(policy, ["policy_metadata", "state"]) == nil

    assert {:error, :forbidden_policy_broadening} =
             TargetContext.issue_policy(context, issue, [])
  end

  test "issue_policy emits deterministic normalized policy metadata" do
    context = issue_policy_context()

    issue = %SymphonyElixir.Linear.Issue{
      id: "normalized-metadata-policy",
      identifier: "SID-NORMALIZED-METADATA",
      title: "Normalized policy metadata",
      state: " TODO ",
      project_id: " project-id ",
      project_slug: " ALPHA ",
      labels: [" Target:Required ", "repo:REQUIRED", " extra ", "EXTRA"]
    }

    canonical = %{
      issue
      | state: "todo",
        project_id: "project-id",
        project_slug: "alpha",
        labels: ["extra", "repo:required", "target:required"]
    }

    assert {:ok, normalized_policy} =
             TargetContext.issue_policy(context, issue, profile: " strict ")

    assert {:ok, canonical_policy} =
             TargetContext.issue_policy(context, canonical, profile: "strict")

    assert normalized_policy == canonical_policy

    assert normalized_policy["policy_metadata"] == %{
             "labels" => ["extra", "repo:required", "target:required"],
             "profile" => "strict",
             "project_id" => "project-id",
             "project_slug" => "alpha",
             "source" => "target_context",
             "state" => "todo"
           }
  end

  test "issue_policy rejects invalid profile and label source values with typed errors" do
    context = issue_policy_context()

    issue = %SymphonyElixir.Linear.Issue{
      id: "invalid-metadata-policy",
      identifier: "SID-INVALID-METADATA",
      title: "Invalid policy metadata",
      state: "Todo",
      project_slug: "alpha",
      labels: ["repo:required", "target:required"]
    }

    for invalid_profile <- [nil, "", "   ", "private-profile\nvalue", <<255>>] do
      result = TargetContext.issue_policy(context, issue, profile: invalid_profile)
      assert result == {:error, :invalid_issue_policy_options}
      refute inspect(result) =~ "private-profile"
    end

    for invalid_label <- [nil, "", "   ", "private-label\tvalue", <<255>>] do
      result = TargetContext.issue_policy(context, %{issue | labels: issue.labels ++ [invalid_label]}, [])
      assert result == {:error, :malformed_issue_metadata}
      refute inspect(result) =~ "private-label"
    end
  end

  test "issue_policy distinguishes a missing automation profile from malformed pinned values" do
    context = issue_policy_context()
    issue = issue_policy_issue()

    missing =
      update_in(
        context.repo_policy["manifest"]["automation"],
        &Map.delete(&1, "profile")
      )

    assert {:ok, _policy} = TargetContext.issue_policy(missing, issue, [])

    for malformed <- [nil, "", "   ", <<255>>, 42] do
      malformed_context =
        put_in(
          context.repo_policy["manifest"]["automation"]["profile"],
          malformed
        )

      assert TargetContext.issue_policy(malformed_context, issue, []) ==
               {:error, :malformed_composed_policy}
    end
  end

  test "issue_policy rejects broadening and returns typed secret-safe errors" do
    context = issue_policy_context()

    issue = %SymphonyElixir.Linear.Issue{
      id: "issue-policy-errors",
      identifier: "SID-POLICY-ERRORS",
      title: "Reject broadening",
      state: "Todo",
      project_slug: "alpha",
      labels: ["repo:required", "target:required"]
    }

    assert {:ok, intersected_policy} = TargetContext.issue_policy(context, issue, [])

    assert intersected_policy["auto_land"] == %{
             "posture" => "off",
             "dry_run" => true,
             "required_checks" => ["ci"]
           }

    assert {:error, :unknown_profile} =
             TargetContext.issue_policy(context, issue, profile: "missing")

    assert {:error, :forbidden_policy_broadening} =
             TargetContext.issue_policy(context, issue, restrictive_flags: [:auto_land])

    for outside_issue <- [
          %{issue | project_slug: "outside"},
          %{issue | labels: ["repo:required"]},
          %{issue | state: "Done"}
        ] do
      assert {:error, :forbidden_policy_broadening} =
               TargetContext.issue_policy(context, outside_issue, [])
    end

    private_issue_value = "private-issue-value"
    malformed_issue = %{issue | labels: [private_issue_value | :malformed]}
    malformed_issue_result = TargetContext.issue_policy(context, malformed_issue, [])
    assert malformed_issue_result == {:error, :malformed_issue_metadata}
    refute inspect(malformed_issue_result) =~ private_issue_value

    private_policy_value = "private-policy-value"

    malformed_context =
      put_in(
        context.repo_policy,
        Map.put(context.repo_policy, "private", private_policy_value)
      )

    malformed_policy_result = TargetContext.issue_policy(malformed_context, issue, [])
    assert malformed_policy_result == {:error, :malformed_composed_policy}
    refute inspect(malformed_policy_result) =~ private_policy_value

    private_state_value = "private-state-value"
    malformed_state_context = put_in(context.run_target["active_states"], private_state_value)
    malformed_state_result = TargetContext.issue_policy(malformed_state_context, issue, [])
    assert malformed_state_result == {:error, :malformed_composed_policy}
    refute inspect(malformed_state_result) =~ private_state_value
  end

  test "issue_policy rejects malformed public arguments and restrictive options" do
    context = issue_policy_context()
    issue = issue_policy_issue()

    assert TargetContext.issue_policy(context, :not_an_issue, []) ==
             {:error, :malformed_issue_metadata}

    assert TargetContext.issue_policy(:not_a_context, issue, []) ==
             {:error, :malformed_composed_policy}

    assert TargetContext.issue_policy(context, issue, %{}) ==
             {:error, :invalid_issue_policy_options}

    assert TargetContext.issue_policy(
             context,
             issue,
             restrictive_flags: [:no_land | :invalid_tail]
           ) == {:error, :invalid_issue_policy_options}

    assert TargetContext.issue_policy(context, issue, restrictive_flags: [:future_restriction]) ==
             {:error, :invalid_issue_policy_options}

    assert TargetContext.issue_policy(context, issue, restrictive_flags: "no_land") ==
             {:error, :invalid_issue_policy_options}

    assert TargetContext.issue_policy(context, %{issue | labels: "repo:required"}, []) ==
             {:error, :malformed_issue_metadata}
  end

  test "issue_policy rejects malformed composed scope fields through typed errors" do
    context = issue_policy_context()
    issue = issue_policy_issue()

    assert TargetContext.issue_policy(%{context | repo_policy: %{}}, issue, []) ==
             {:error, :malformed_composed_policy}

    missing_markers =
      update_in(context.repo_policy["manifest"], &Map.delete(&1, "issue_markers"))

    assert TargetContext.issue_policy(missing_markers, issue, []) ==
             {:error, :malformed_composed_policy}

    invalid_projects =
      put_in(
        context.repo_policy["manifest"]["issue_markers"]["allowed_projects"],
        "alpha"
      )

    assert TargetContext.issue_policy(invalid_projects, issue, []) ==
             {:error, :malformed_composed_policy}

    invalid_automation = put_in(context.repo_policy["manifest"]["automation"], nil)

    assert TargetContext.issue_policy(invalid_automation, issue, []) ==
             {:error, :malformed_composed_policy}

    invalid_required_labels = put_in(context.run_target["required_labels"], "target:required")

    assert TargetContext.issue_policy(invalid_required_labels, issue, []) ==
             {:error, :malformed_composed_policy}

    invalid_project_scope = put_in(context.run_target["scope"]["project_slug"], 42)

    assert TargetContext.issue_policy(invalid_project_scope, issue, []) ==
             {:error, :malformed_composed_policy}
  end

  test "issue_policy rejects nil or blank project constraints" do
    context = issue_policy_context()
    issue = issue_policy_issue()

    for invalid_value <- [nil, "   "] do
      invalid_scope = put_in(context.run_target["scope"]["project_slug"], invalid_value)

      assert TargetContext.issue_policy(invalid_scope, issue, []) ==
               {:error, :malformed_composed_policy}
    end
  end

  test "issue_policy rejects malformed auto-land for no-land without exposing its value" do
    private_value = "tracker-api-key=private-no-land-value"
    context = put_in(issue_policy_context().repo_policy["manifest"]["auto_land"], private_value)

    result =
      TargetContext.issue_policy(context, issue_policy_issue(), restrictive_flags: [:no_land])

    assert result == {:error, :malformed_composed_policy}
    refute inspect(result) =~ private_value
  end

  test "issue_policy rejects malformed auto-land for human-review-only without exposing its value" do
    private_value = "tracker-api-key=private-human-review-value"
    context = put_in(issue_policy_context().repo_policy["manifest"]["auto_land"], private_value)

    result =
      TargetContext.issue_policy(context, issue_policy_issue(), restrictive_flags: [:human_review_only])

    assert result == {:error, :malformed_composed_policy}
    refute inspect(result) =~ private_value
  end

  test "issue_policy treats explicit null auto-land as absent" do
    context = put_in(issue_policy_context().repo_policy["manifest"]["auto_land"], nil)

    assert {:ok, policy} = TargetContext.issue_policy(context, issue_policy_issue(), [])
    refute Map.has_key?(policy, "auto_land")
  end

  test "issue_policy applies every restrictive evidence requirement without requiring auto-land" do
    context = issue_policy_context()
    context = update_in(context.repo_policy["manifest"], &Map.delete(&1, "auto_land"))
    issue = issue_policy_issue()
    restrictive_flags = [:human_review_only, :require_validation, :require_review]

    assert {:ok, policy} =
             TargetContext.issue_policy(context, issue, restrictive_flags: restrictive_flags)

    assert policy["auto_land"] == %{"posture" => "off", "dry_run" => true}
    assert policy["handoff_route"] == "human_review"

    assert policy["completion_requirements"] == [
             "tests-green",
             "Run setup requires validation evidence before handoff."
           ]

    assert policy["review_requirements"] == [
             "Run setup requires review evidence before handoff."
           ]

    assert policy["run_setup"]["restrictive_flags"] == [
             "human_review_only",
             "require_validation",
             "require_review"
           ]
  end

  test "issue_policy requires exact repository authority provenance" do
    context = issue_policy_context()
    issue = issue_policy_issue()

    assert {:ok, _policy} = TargetContext.issue_policy(context, issue, [])

    repo_policy = context.repo_policy

    malformed_repo_policies = [
      Map.delete(repo_policy, "manifest_source_dir"),
      Map.delete(repo_policy, "workflow_module_resolution"),
      Map.put(repo_policy, "unknown", "forged"),
      Map.put(repo_policy, "manifest_source_dir", "relative/source"),
      Map.put(repo_policy, "manifest_source_dir", <<0xFF>>),
      Map.put(repo_policy, "manifest_source_dir", 42),
      Map.put(repo_policy, "manifest", []),
      Map.put(repo_policy, "workflow_module_resolution", [])
    ]

    for malformed_repo_policy <- malformed_repo_policies do
      result =
        TargetContext.issue_policy(
          %{context | repo_policy: malformed_repo_policy},
          issue,
          []
        )

      assert result == {:error, :malformed_composed_policy}
      refute inspect(result) =~ "forged"
    end
  end

  test "issue_policy accepts only the pinned authority profile and exact authority shape" do
    context = issue_policy_context()
    issue = issue_policy_issue()

    authority = %{
      "profile" => "strict",
      "policy" => %{"handoff_route" => "human_review"}
    }

    assert {:ok, policy} =
             TargetContext.issue_policy(
               %{context | issue_policy_authority: authority},
               issue,
               profile: "strict"
             )

    assert policy["handoff_route"] == "human_review"

    assert TargetContext.issue_policy(
             %{context | issue_policy_authority: authority},
             issue,
             profile: "default"
           ) == {:error, :unknown_profile}

    for malformed_authority <- [
          Map.put(authority, "private", "must-not-expand-authority"),
          %{},
          "must-not-be-an-authority"
        ] do
      result =
        TargetContext.issue_policy(
          %{context | issue_policy_authority: malformed_authority},
          issue,
          profile: "strict"
        )

      assert result == {:error, :malformed_composed_policy}
      refute inspect(result) =~ "must-not"
    end
  end

  test "issue_policy rejects malformed authority fields before every restrictive flag path" do
    context = issue_policy_context()
    issue = issue_policy_issue()

    for {flag, field} <- [
          {:no_land, "auto_land"},
          {:human_review_only, "auto_land"},
          {:require_validation, "completion_requirements"},
          {:require_review, "review_requirements"}
        ] do
      private_value = "private-#{flag}-authority-value"

      authority = %{
        "profile" => "strict",
        "policy" => %{field => private_value}
      }

      result =
        TargetContext.issue_policy(
          %{context | issue_policy_authority: authority},
          issue,
          profile: "strict",
          restrictive_flags: [flag]
        )

      assert result == {:error, :malformed_composed_policy}
      refute inspect(result) =~ private_value
    end
  end

  defp issue_policy_issue(overrides \\ %{}) do
    struct!(
      SymphonyElixir.Linear.Issue,
      Map.merge(
        %{
          id: "issue-policy-coverage",
          identifier: "SID-POLICY-COVERAGE",
          title: "Policy coverage",
          state: "Todo",
          project_slug: "alpha",
          labels: ["repo:required", "target:required"]
        },
        overrides
      )
    )
  end

  defp issue_policy_context do
    assert {:ok, context} = context_for(valid_target())

    manifest = %{
      "version" => 1,
      "project" => %{
        "repository" => "https://github.com/example/repo",
        "slug" => "alpha",
        "criticality" => "production",
        "deployment_coupling" => "production"
      },
      "workflow" => %{"modules" => []},
      "docs" => %{},
      "validation" => %{"commands" => [%{"name" => "test", "command" => "mix test"}]},
      "vcs" => %{},
      "delivery" => %{"pr_target" => "main"},
      "automation" => %{
        "profile" => "strict",
        "completion_requirements" => ["tests-green"]
      },
      "auto_land" => %{"posture" => "strict", "dry_run" => false, "required_checks" => ["ci"]},
      "harness" => %{},
      "capabilities" => %{"required" => ["github_pr"]},
      "issue_markers" => %{"labels" => ["repo:required"], "allowed_projects" => []}
    }

    put_in(context.repo_policy["manifest"], manifest)
  end

  defp valid_snapshot(target \\ nil) do
    snapshot = phase1_snapshot()

    case target do
      nil ->
        snapshot

      %Target{} ->
        host = synchronize_tracker_policy(snapshot.host, target.effective_policy)
        %{snapshot | host: host, targets: %{"alpha" => target}, diagnostics: target.diagnostics}

      other ->
        %{snapshot | targets: %{"alpha" => other}}
    end
  end

  defp phase1_snapshot do
    {:ok, structured} = Schema.validate(registry_document(), home: "/tmp")
    composed = Composition.compose(structured, manifest: DeterministicManifestAdapter)
    generation = hash("b")

    %{
      composed
      | path: "/tmp/registry/targets.yml",
        source_hash: generation,
        generation: generation
    }
  end

  defp two_target_snapshot do
    {:ok, structured} = Schema.validate(two_target_registry_document(), home: "/tmp")
    assert structured.globally_valid?, inspect(structured.diagnostics)
    assert Enum.all?(structured.targets, fn {_id, target} -> target.valid? end)

    composed = Composition.compose(structured, manifest: TwoTargetManifestAdapter)
    assert Enum.all?(composed.targets, fn {_id, target} -> target.valid? end)
    generation = hash("9")

    %{
      composed
      | path: "/tmp/registry/two-targets.yml",
        source_hash: generation,
        generation: generation
    }
  end

  defp two_target_registry_document do
    base = registry_document()
    base_target = base["targets"]["alpha"]

    alpha =
      base_target
      |> put_in(["repo", "path"], Path.join(@repo_fixture_root, "symphony"))
      |> put_in(["repo", "expected_repository"], "https://github.com/example/alpha")
      |> put_in(["worktree", "root"], "/tmp/worktrees/alpha-only")
      |> put_in(["linear", "connection"], "linear-alpha")
      |> put_in(["linear", "scope"], %{"type" => "project", "project_slug" => "alpha-scope"})
      |> put_in(["linear", "required_labels"], ["target:alpha"])
      |> put_in(["runners"], %{
        "default" => "runner-alpha",
        "allowed" => ["runner-alpha"],
        "settings" => %{
          "runner-alpha" => %{
            "model" => "alpha-target-model",
            "reasoning_effort" => "high",
            "max_turns" => 11,
            "execution_profiles" => %{
              "implementation" => %{"model" => "alpha-profile-model", "reasoning_effort" => "xhigh"}
            }
          }
        }
      })
      |> put_in(["checks"], %{
        "pre_dispatch" => ["capability_preflight"],
        "pre_handoff" => ["quality_gate"]
      })
      |> put_in(["external_side_effects"], %{
        "tracker_write" => "allow",
        "vcs_publish" => "allow",
        "pull_request_write" => "allow",
        "merge" => "manual_approval",
        "deployment" => "deny",
        "production_data" => "deny"
      })
      |> put_in(["concurrency"], %{
        "max_concurrent_agents" => 2,
        "max_concurrent_startups" => 1,
        "max_concurrent_reviewers" => 1
      })
      |> put_in(["budgets"], %{
        "per_run" => %{"max_total_tokens" => 1_000},
        "daily" => %{"max_total_tokens" => 10_000},
        "weekly" => %{"max_total_tokens" => 50_000}
      })
      |> put_in(["scheduling", "weight"], 3)

    beta =
      base_target
      |> Map.put("display_name", "Beta")
      |> Map.put("state", "draining")
      |> Map.delete("dispatch_mode")
      |> put_in(["repo", "path"], Path.join(@repo_fixture_root, "other"))
      |> put_in(["repo", "expected_repository"], "https://github.com/example/beta")
      |> put_in(["worktree", "root"], "/tmp/worktrees/beta-only")
      |> put_in(["linear", "connection"], "linear-beta")
      |> put_in(["linear", "scope"], %{"type" => "team", "team_key" => "BETA"})
      |> put_in(["linear", "active_states"], ["Backlog", "Started"])
      |> put_in(["linear", "terminal_states"], ["Canceled", "Completed"])
      |> put_in(["linear", "required_labels"], ["target:beta"])
      |> put_in(["runners"], %{
        "default" => "runner-beta",
        "allowed" => ["runner-beta"],
        "settings" => %{
          "runner-beta" => %{
            "model" => "beta-target-model",
            "reasoning_effort" => "low",
            "max_turns" => 5,
            "execution_profiles" => %{
              "source-reviewer" => %{"model" => "beta-profile-model", "reasoning_effort" => "medium"}
            }
          }
        }
      })
      |> put_in(["checks"], %{
        "pre_publish" => ["publish_preflight"],
        "pre_merge" => ["review_feedback_sweep"]
      })
      |> put_in(["external_side_effects"], %{
        "tracker_write" => "manual_approval",
        "vcs_publish" => "deny",
        "pull_request_write" => "manual_approval",
        "merge" => "deny",
        "deployment" => "manual_approval",
        "production_data" => "manual_approval"
      })
      |> put_in(["concurrency"], %{
        "max_concurrent_agents" => 3,
        "max_concurrent_startups" => 2,
        "max_concurrent_reviewers" => 2,
        "by_linear_state" => %{"started" => 2}
      })
      |> put_in(["budgets"], %{
        "per_run" => %{"max_total_tokens" => 2_000},
        "daily" => %{"max_total_tokens" => 20_000},
        "weekly" => %{"max_total_tokens" => 80_000}
      })
      |> put_in(["scheduling", "weight"], 9)

    host =
      base["host"]
      |> Map.put("tracker_connections", %{
        "linear-alpha" => %{
          "kind" => "linear",
          "endpoint" => "https://alpha.tracker.example.invalid/graphql",
          "api_key" => "$ALPHA_KEY"
        },
        "linear-beta" => %{
          "kind" => "linear",
          "endpoint" => "https://beta.tracker.example.invalid/graphql",
          "api_key" => "${BETA_KEY}"
        }
      })
      |> Map.put("runners", %{
        "runner-alpha" => host_runner("alpha", 4, 2),
        "runner-beta" => host_runner("beta", 8, 3)
      })

    %{"version" => 1, "host" => host, "targets" => %{"alpha" => alpha, "beta" => beta}}
  end

  defp host_runner(target_id, max_agents, max_startups) do
    %{
      "kind" => "codex_app_server",
      "command" => ["codex", "#{target_id}-app-server"],
      "approval_policy" => "never",
      "thread_sandbox" => "workspace-write",
      "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => false},
      "max_concurrent_agents" => max_agents,
      "max_concurrent_startups" => max_startups,
      "model" => "#{target_id}-host-model",
      "execution_profiles" => %{
        "implementation" => %{"model" => "#{target_id}-host-profile", "reasoning_effort" => "medium"}
      }
    }
  end

  defp synchronize_tracker_policy(host, %{
         "tracker_connection" => %{"id" => connection_id, "policy" => policy}
       })
       when is_binary(connection_id) and is_map(policy) do
    put_in(host, ["tracker_connections", connection_id], policy)
  end

  defp synchronize_tracker_policy(host, _effective_policy), do: host

  defp registry_document do
    %{
      "version" => 1,
      "host" => %{
        "id" => "fixture-host",
        "state_root" => "/tmp/state",
        "polling" => %{"interval_ms" => 1_000, "max_concurrent_target_polls" => 2},
        "capacity" => %{
          "max_concurrent_agents" => 4,
          "max_concurrent_startups" => 2,
          "max_concurrent_reviewers" => 2
        },
        "scheduling" => %{
          "algorithm" => "weighted_deficit_round_robin",
          "max_credit_rounds" => 2
        },
        "tracker_connections" => %{
          "linear-primary" => %{
            "kind" => "linear",
            "endpoint" => "https://tracker.example.invalid/graphql",
            "api_key" => "$TRACKER_KEY"
          }
        },
        "runners" => %{
          "codex" => %{
            "kind" => "codex_app_server",
            "command" => ["codex", "app-server"],
            "approval_policy" => "never",
            "thread_sandbox" => "workspace-write",
            "turn_sandbox_policy" => %{
              "type" => "workspaceWrite",
              "networkAccess" => false
            },
            "max_concurrent_agents" => 4,
            "max_concurrent_startups" => 2
          }
        }
      },
      "targets" => %{
        "alpha" => %{
          "display_name" => "Alpha",
          "state" => "active",
          "dispatch_mode" => "watch",
          "repo" => %{
            "path" => Path.join(@repo_fixture_root, "symphony"),
            "manifest" => "symphony.yml",
            "expected_repository" => "git@github.com:example/repo.git"
          },
          "worktree" => %{
            "root" => "/tmp/worktrees/alpha",
            "strategy" => "per_issue",
            "hooks" => %{}
          },
          "linear" => %{
            "connection" => "linear-primary",
            "scope" => %{"type" => "project", "project_slug" => "alpha"},
            "active_states" => ["Todo", "In Progress"],
            "terminal_states" => ["Done"],
            "required_labels" => ["target:required"]
          },
          "runners" => %{
            "default" => "codex",
            "allowed" => ["codex"],
            "settings" => %{"codex" => %{"model" => "test-model"}}
          },
          "concurrency" => %{
            "max_concurrent_agents" => 2,
            "max_concurrent_startups" => 1,
            "max_concurrent_reviewers" => 1
          },
          "budgets" => %{
            "per_run" => %{"max_total_tokens" => 1_000},
            "daily" => %{"max_total_tokens" => 10_000},
            "weekly" => %{"max_total_tokens" => 50_000}
          },
          "checks" => %{"pre_dispatch" => ["capability_preflight"]},
          "external_side_effects" => %{
            "tracker_write" => "allow",
            "vcs_publish" => "allow",
            "pull_request_write" => "allow",
            "merge" => "manual_approval",
            "deployment" => "deny",
            "production_data" => "deny"
          },
          "scheduling" => %{"weight" => 7}
        }
      }
    }
  end

  defp valid_target do
    phase1_snapshot().targets["alpha"]
  end

  defp target_with_secret_reference(reference) do
    policy = put_in(effective_policy(), ["tracker_connection", "policy", "api_key"], reference)
    target_with_policy(policy)
  end

  defp target_with_manifest(manifest) do
    manifest
    |> effective_policy()
    |> target_with_policy()
  end

  defp target_with_policy(policy) do
    %{
      valid_target()
      | repo_manifest: get_in(policy, ["repo_policy", "manifest"]),
        effective_policy: policy,
        policy_hash: canonical_hash(policy)
    }
  end

  defp context_for(target, credential \\ "credential") do
    TargetContext.from_registry(valid_snapshot(target), "alpha", env_fetcher: fn "TRACKER_KEY" -> {:ok, credential} end)
  end

  defp effective_policy(repo_manifest \\ repo_manifest()) do
    phase1_snapshot().targets["alpha"].effective_policy
    |> put_in(["repo_policy", "manifest"], repo_manifest)
  end

  defp repo_manifest, do: DeterministicManifestAdapter.manifest()

  defp canonical_hash(term) do
    {:ok, digest} = Composition.canonical_hash(term)
    digest
  end

  defp hash(character), do: "sha256:" <> String.duplicate(character, 64)
end
