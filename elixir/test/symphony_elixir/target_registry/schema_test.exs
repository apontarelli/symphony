defmodule SymphonyElixir.TargetRegistry.SchemaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TargetRegistry
  alias SymphonyElixir.TargetRegistry.Error
  alias SymphonyElixir.TargetRegistry.Schema
  alias SymphonyElixir.TargetRegistry.Snapshot
  alias SymphonyElixir.TargetRegistry.Target

  test "version failures are global structured errors" do
    assert {:error,
            %Error{
              code: :missing_version,
              path: "$.version",
              message: "registry version is required"
            }} = Schema.validate(%{})

    for version <- [2, "1", nil] do
      assert {:error,
              %Error{
                code: :unsupported_version,
                path: "$.version",
                message: "registry version must be integer 1"
              }} = Schema.validate(%{"version" => version})
    end
  end

  test "a version 1 document produces the public snapshot shape" do
    document = %{"version" => 1, "host" => valid_host(), "targets" => %{}}

    assert {:ok,
            %Snapshot{
              version: 1,
              path: nil,
              source_hash: nil,
              generation: nil,
              globally_valid?: true,
              host: host,
              targets: %{},
              diagnostics: []
            }} = Schema.validate(document, home: "/tmp/schema-home")

    assert host["state_root"] == "/tmp/schema-home/state"

    assert %TargetRegistry.Diagnostic{} =
             %TargetRegistry.Diagnostic{
               severity: :info,
               scope: :registry,
               path: "$",
               code: :example,
               message: "example"
             }
  end

  test "root and host maps reject unknown keys" do
    document =
      valid_document()
      |> Map.put("extra", true)
      |> put_in(["host", "extra"], true)
      |> put_in(["host", "polling", "extra"], true)
      |> put_in(["host", "capacity", "extra"], true)
      |> put_in(["host", "scheduling", "extra"], true)
      |> put_in(["host", "tracker_connections", "linear-main", "extra"], true)

    assert {:ok, snapshot} = Schema.validate(document, home: "/tmp/schema-home")
    refute snapshot.globally_valid?

    assert Enum.map(snapshot.diagnostics, &{&1.scope, &1.path, &1.code}) == [
             {:registry, "$.extra", :unknown_key},
             {:host, "$.host.capacity.extra", :unknown_key},
             {:host, "$.host.extra", :unknown_key},
             {:host, "$.host.polling.extra", :unknown_key},
             {:host, "$.host.scheduling.extra", :unknown_key},
             {:host, "$.host.tracker_connections.linear-main.extra", :unknown_key}
           ]
  end

  test "non-string dynamic and unknown map keys produce deterministic scoped diagnostics" do
    tracker_connection = get_in(valid_host(), ["tracker_connections", "linear-main"])
    host_runner = get_in(valid_host(), ["runners", "codex"])

    host =
      valid_host()
      |> Map.put(:extra, true)
      |> Map.put("tracker_connections", %{11 => tracker_connection})
      |> Map.put("runners", %{{:runner} => host_runner})

    main_target =
      valid_target()
      |> update_in(["repo"], &Map.put(&1, {:extra}, true))
      |> put_in(["runners", "settings"], %{17 => %{"model" => "gpt-5.6"}})

    document = %{
      19 => true,
      "version" => 1,
      "host" => host,
      "targets" => %{7 => valid_target(), "main" => main_target}
    }

    assert {:ok, snapshot} = Schema.validate(document, home: "/tmp/schema-home")
    refute snapshot.globally_valid?

    expected = [
      {:registry, "$[key:0:integer]", :unknown_key, "$[key:0:integer] is not supported"},
      {:host, "$.host.runners[key:0:tuple]", :invalid_type, "$.host.runners[key:0:tuple] must be a string"},
      {:host, "$.host.tracker_connections[key:0:integer]", :invalid_type, "$.host.tracker_connections[key:0:integer] must be a string"},
      {:host, "$.host[key:0:atom]", :unknown_key, "$.host[key:0:atom] is not supported"},
      {{:target, 7}, "$.targets[key:0:integer]", :invalid_type, "$.targets[key:0:integer] must be a string"},
      {{:target, "main"}, "$.targets.main.repo[key:0:tuple]", :unknown_key, "$.targets.main.repo[key:0:tuple] is not supported"},
      {{:target, "main"}, "$.targets.main.runners.settings[key:0:integer]", :invalid_type, "$.targets.main.runners.settings[key:0:integer] must be a string"}
    ]

    diagnostics =
      Enum.map(snapshot.diagnostics, &{&1.scope, &1.path, &1.code, &1.message})

    assert diagnostics == expected
    assert diagnostics == Enum.map(snapshot.diagnostics, &{&1.scope, &1.path, &1.code, &1.message})

    assert %Target{valid?: false, effective_state: :paused} = snapshot.targets[7]
    assert %Target{valid?: false, effective_state: :paused} = snapshot.targets["main"]
  end

  test "exact numeric target keys use insertion-independent diagnostic indexes" do
    entries =
      [{1, valid_target()}, {1.0, valid_target()}] ++
        Enum.map(1..31, &{"k#{&1}", valid_target()})

    targets_by_insertion = [Map.new(entries), entries |> Enum.reverse() |> Map.new()]
    assert Enum.at(targets_by_insertion, 0) === Enum.at(targets_by_insertion, 1)

    diagnostics_by_insertion =
      Enum.map(targets_by_insertion, fn targets ->
        document = valid_document() |> Map.put("targets", targets)
        assert {:ok, snapshot} = Schema.validate(document, home: "/tmp/schema-home")

        Enum.map(snapshot.diagnostics, &{&1.scope, &1.path, &1.code, &1.message})
      end)

    expected = [
      {{:target, 1.0}, "$.targets[key:0:float]", :invalid_type, "$.targets[key:0:float] must be a string"},
      {{:target, 1}, "$.targets[key:1:integer]", :invalid_type, "$.targets[key:1:integer] must be a string"}
    ]

    assert diagnostics_by_insertion == [expected, expected]
  end

  test "safe key notation names every non-string key type" do
    cat_path = System.find_executable("cat") || raise "cat executable is required"
    port = Port.open({:spawn_executable, cat_path}, [])

    key_types = [
      {1.5, "float"},
      {%{nested: true}, "map"},
      {[:nested], "list"},
      {self(), "pid"},
      {make_ref(), "reference"},
      {fn -> :ok end, "function"},
      {port, "port"},
      {<<1::1>>, "bitstring"}
    ]

    for {key, type} <- key_types do
      document = Map.put(valid_document(), key, true)
      assert {:ok, snapshot} = Schema.validate(document, home: "/tmp/schema-home")

      assert [diagnostic] =
               Enum.filter(
                 snapshot.diagnostics,
                 &(&1.scope == :registry and &1.code == :unknown_key)
               )

      assert String.starts_with?(diagnostic.path, "$[key:")
      assert String.ends_with?(diagnostic.path, ":#{type}]")
      assert diagnostic.message == "#{diagnostic.path} is not supported"
    end
  end

  test "root and host required fields produce local diagnostics" do
    cases = [
      {["host"], :registry, "$.host"},
      {["targets"], :registry, "$.targets"},
      {["host", "id"], :host, "$.host.id"},
      {["host", "state_root"], :host, "$.host.state_root"},
      {["host", "polling"], :host, "$.host.polling"},
      {["host", "polling", "interval_ms"], :host, "$.host.polling.interval_ms"},
      {["host", "polling", "max_concurrent_target_polls"], :host, "$.host.polling.max_concurrent_target_polls"},
      {["host", "capacity"], :host, "$.host.capacity"},
      {["host", "capacity", "max_concurrent_agents"], :host, "$.host.capacity.max_concurrent_agents"},
      {["host", "capacity", "max_concurrent_startups"], :host, "$.host.capacity.max_concurrent_startups"},
      {["host", "capacity", "max_concurrent_reviewers"], :host, "$.host.capacity.max_concurrent_reviewers"},
      {["host", "scheduling"], :host, "$.host.scheduling"},
      {["host", "scheduling", "algorithm"], :host, "$.host.scheduling.algorithm"},
      {["host", "scheduling", "max_credit_rounds"], :host, "$.host.scheduling.max_credit_rounds"},
      {["host", "tracker_connections"], :host, "$.host.tracker_connections"},
      {["host", "tracker_connections", "linear-main", "kind"], :host, "$.host.tracker_connections.linear-main.kind"},
      {["host", "tracker_connections", "linear-main", "endpoint"], :host, "$.host.tracker_connections.linear-main.endpoint"},
      {["host", "tracker_connections", "linear-main", "api_key"], :host, "$.host.tracker_connections.linear-main.api_key"},
      {["host", "runners"], :host, "$.host.runners"},
      {["host", "runners", "codex", "max_concurrent_agents"], :host, "$.host.runners.codex.max_concurrent_agents"},
      {["host", "runners", "codex", "max_concurrent_startups"], :host, "$.host.runners.codex.max_concurrent_startups"}
    ]

    for {keys, scope, diagnostic_path} <- cases do
      {_, document} = pop_in(valid_document(), keys)
      assert_diagnostic(document, scope, diagnostic_path, :missing_required_field)
    end
  end

  test "root and host fields reject wrong types" do
    cases = [
      {["host"], []},
      {["targets"], []},
      {["host", "id"], 1},
      {["host", "state_root"], true},
      {["host", "polling"], []},
      {["host", "capacity"], []},
      {["host", "scheduling"], []},
      {["host", "tracker_connections"], []},
      {["host", "tracker_connections", "linear-main"], []},
      {["host", "runners"], []},
      {["host", "runners", "codex"], []}
    ]

    for {keys, value} <- cases do
      document = put_in(valid_document(), keys, value)
      assert_diagnostic(document, scope_for(keys), path_for(keys), :invalid_type)
    end

    integer_paths = [
      ["host", "polling", "interval_ms"],
      ["host", "polling", "max_concurrent_target_polls"],
      ["host", "capacity", "max_concurrent_agents"],
      ["host", "capacity", "max_concurrent_startups"],
      ["host", "capacity", "max_concurrent_reviewers"],
      ["host", "scheduling", "max_credit_rounds"],
      ["host", "runners", "codex", "max_concurrent_agents"],
      ["host", "runners", "codex", "max_concurrent_startups"]
    ]

    for keys <- integer_paths, value <- [0, -1, 1.5, "1", true] do
      document = put_in(valid_document(), keys, value)
      assert_diagnostic(document, :host, path_for(keys), :invalid_type)
    end
  end

  test "host runner catalog accepts the supported Config.Schema runner fields" do
    codex =
      valid_host()
      |> get_in(["runners", "codex"])
      |> Map.merge(%{
        "command" => nil,
        "approval_policy" => %{"custom" => %{"sandbox_approval" => nil}},
        "thread_sandbox" => "workspace-write",
        "turn_sandbox_policy" => %{"type" => nil, "networkAccess" => false},
        "execution_profiles" => %{"review" => nil},
        "turn_timeout_ms" => 1,
        "read_timeout_ms" => 2,
        "stall_timeout_ms" => 0
      })

    open = %{
      "kind" => "opencode_server",
      "command" => ["opencode", "serve"],
      "model" => "anthropic/claude-sonnet-4-5",
      "execution_profiles" => %{"review" => %{"permissions" => %{"bash" => "deny"}}},
      "startup_timeout_ms" => 4,
      "max_concurrent_agents" => 2,
      "max_concurrent_startups" => 1
    }

    document = put_in(valid_document(), ["host", "runners"], %{"codex" => codex, "open" => open})

    assert {:ok, %Snapshot{globally_valid?: true, diagnostics: []}} =
             Schema.validate(document, home: "/tmp/schema-home")
  end

  test "host runner errors retain exact Config.Schema semantics at registry paths" do
    cases = [
      {%{"command" => ["codex", " "]}, "command[1]", :invalid_type, "must be a non-empty string"},
      {%{"approval_policy" => "on-request"}, "approval_policy", :invalid_value, "on-request is not supported; Symphony agents are unattended"},
      {%{"thread_sandbox" => %{}}, "thread_sandbox", :invalid_type, "must be a string"},
      {%{"turn_sandbox_policy" => []}, "turn_sandbox_policy", :invalid_type, "must be a map"},
      {%{"execution_profiles" => []}, "execution_profiles", :invalid_type, "must be a map"},
      {%{"unexpected" => true}, "unexpected", :unknown_key, "is not supported in v1"},
      {%{"unsupported field" => true}, "unsupported field", :unknown_key, "is not supported in v1"},
      {%{"kind" => "opencode_server", "approval_policy" => "never"}, "approval_policy", :unknown_key, "is not supported for opencode_server"},
      {%{"kind" => "opencode_server", "server_auth" => %{"username" => "runner"}}, "server_auth.password", :missing_required_field, "is required when server_auth is configured"},
      {%{"turn_timeout_ms" => 0}, "turn_timeout_ms", :invalid_type, "must be a positive integer"}
    ]

    for {overrides, suffix, code, detail} <- cases do
      runner =
        valid_host()
        |> get_in(["runners", "codex"])
        |> Map.merge(overrides)

      document = put_in(valid_document(), ["host", "runners", "codex"], runner)
      path = "$.host.runners.codex.#{suffix}"

      assert {:ok, %Snapshot{globally_valid?: false, diagnostics: diagnostics}} =
               Schema.validate(document, home: "/tmp/schema-home")

      assert diagnostic_values(diagnostics) == [{:host, path, code, "#{path} #{detail}"}]
    end
  end

  test "invalid runner IDs retain exact nested shared diagnostics" do
    runner =
      valid_host()
      |> get_in(["runners", "codex"])
      |> Map.merge(%{"command" => [], "unsupported field" => true})

    cases = [
      {"Bad ID", "$.host.runners.Bad ID", :invalid_id, "$.host.runners.Bad ID must match ^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"},
      {42, "$.host.runners[key:0:integer]", :invalid_type, "$.host.runners[key:0:integer] must be a string"}
    ]

    for {id, path, id_code, id_message} <- cases do
      document = put_in(valid_document(), ["host", "runners"], %{id => runner})

      assert {:ok, %Snapshot{globally_valid?: false, diagnostics: diagnostics}} =
               Schema.validate(document, home: "/tmp/schema-home")

      assert diagnostic_values(diagnostics) == [
               {:host, path, id_code, id_message},
               {:host, "#{path}.command", :missing_required_field, "#{path}.command is required"},
               {:host, "#{path}.unsupported field", :unknown_key, "#{path}.unsupported field is not supported in v1"}
             ]
    end
  end

  test "runner map keys receive exact recursive bounded diagnostics without crashes" do
    codex =
      valid_host()
      |> get_in(["runners", "codex"])
      |> Map.merge(%{
        "approval_policy" => %{42 => "never"},
        "execution_profiles" => %{"review" => %{"permissions" => %{[] => "deny"}}},
        "turn_sandbox_policy" => %{"nested" => %{{:bad} => true}}
      })

    open = %{
      "kind" => "opencode_server",
      "command" => ["opencode", "serve"],
      "server_auth" => %{%{} => "bad", "password" => "secret"},
      "max_concurrent_agents" => 2,
      "max_concurrent_startups" => 1
    }

    document = put_in(valid_document(), ["host", "runners"], %{"codex" => codex, "open" => open})

    assert {:ok, %Snapshot{globally_valid?: false, diagnostics: diagnostics}} =
             Schema.validate(document, home: "/tmp/schema-home")

    assert diagnostic_values(diagnostics) == [
             {:host, "$.host.runners.codex.approval_policy[key:0:integer]", :invalid_type, "$.host.runners.codex.approval_policy[key:0:integer] map keys must be strings"},
             {:host, "$.host.runners.codex.execution_profiles.review.permissions[key:0:list]", :invalid_type,
              "$.host.runners.codex.execution_profiles.review.permissions[key:0:list] map keys must be strings"},
             {:host, "$.host.runners.codex.turn_sandbox_policy.nested[key:0:tuple]", :invalid_type, "$.host.runners.codex.turn_sandbox_policy.nested[key:0:tuple] map keys must be strings"},
             {:host, "$.host.runners.open.server_auth[key:0:map]", :invalid_type, "$.host.runners.open.server_auth[key:0:map] map keys must be strings"}
           ]
  end

  test "multiple host runner failures produce the exact complete ordered diagnostics" do
    runner =
      valid_host()
      |> get_in(["runners", "codex"])
      |> Map.merge(%{
        "command" => [],
        "max_concurrent_agents" => 0,
        "thread_sandbox" => %{},
        "unsupported field" => true
      })

    document = put_in(valid_document(), ["host", "runners", "codex"], runner)

    assert {:ok, %Snapshot{globally_valid?: false, diagnostics: diagnostics}} =
             Schema.validate(document, home: "/tmp/schema-home")

    assert diagnostic_values(diagnostics) == [
             {:host, "$.host.runners.codex.command", :missing_required_field, "$.host.runners.codex.command is required"},
             {:host, "$.host.runners.codex.max_concurrent_agents", :invalid_type, "$.host.runners.codex.max_concurrent_agents must be a positive integer"},
             {:host, "$.host.runners.codex.thread_sandbox", :invalid_type, "$.host.runners.codex.thread_sandbox must be a string"},
             {:host, "$.host.runners.codex.unsupported field", :unknown_key, "$.host.runners.codex.unsupported field is not supported in v1"}
           ]
  end

  test "host enums, IDs, endpoints, secret references, and non-empty catalogs are strict" do
    invalid_values = [
      {["host", "id"], " Local-Host ", :invalid_id},
      {["host", "id"], "-host", :invalid_id},
      {["host", "scheduling", "algorithm"], "round_robin", :invalid_value},
      {["host", "tracker_connections", "linear-main", "kind"], "github", :invalid_value},
      {["host", "tracker_connections", "linear-main", "endpoint"], "http://linear.app", :invalid_value},
      {["host", "tracker_connections", "linear-main", "endpoint"], "https:///graphql", :invalid_value},
      {["host", "tracker_connections", "linear-main", "api_key"], "literal-token", :invalid_value},
      {["host", "tracker_connections", "linear-main", "api_key"], "$", :invalid_value},
      {["host", "tracker_connections", "linear-main", "api_key"], "${BAD NAME}", :invalid_value},
      {["host", "tracker_connections", "linear-main", "api_key"], "secret://vault/", :invalid_value}
    ]

    for {keys, value, code} <- invalid_values do
      assert_diagnostic(put_in(valid_document(), keys, value), :host, path_for(keys), code)
    end

    for {catalog, path} <- [
          {"tracker_connections", "$.host.tracker_connections"},
          {"runners", "$.host.runners"}
        ] do
      assert_diagnostic(put_in(valid_document(), ["host", catalog], %{}), :host, path, :invalid_value)
    end

    for {catalog, id} <- [{"tracker_connections", "Bad ID"}, {"runners", "-runner"}] do
      entry = get_in(valid_document(), ["host", catalog]) |> Map.values() |> hd()

      document =
        valid_document()
        |> put_in(["host", catalog], %{id => entry})

      assert_diagnostic(document, :host, "$.host.#{catalog}.#{id}", :invalid_id)
    end

    for reference <- ["$TOKEN", "${TOKEN.NAME}", "secret://vault/team/key"] do
      document =
        put_in(
          valid_document(),
          ["host", "tracker_connections", "linear-main", "api_key"],
          reference
        )

      assert {:ok, %Snapshot{globally_valid?: true}} =
               Schema.validate(document, home: "/tmp/schema-home")
    end
  end

  test "blank host state roots are host-local global errors" do
    for state_root <- ["", " ", "\t\n"] do
      document = put_in(valid_document(), ["host", "state_root"], state_root)

      assert {:ok, %Snapshot{globally_valid?: false, diagnostics: diagnostics}} =
               Schema.validate(document, home: "/tmp/schema-home")

      assert Enum.any?(
               diagnostics,
               &(&1.scope == :host and &1.path == "$.host.state_root" and
                   &1.code == :invalid_value and
                   &1.message == "$.host.state_root must not be empty")
             )
    end
  end

  test "a valid target produces the public target result without changing global validity" do
    document = put_in(valid_document(), ["targets"], %{"main" => valid_target()})

    assert {:ok, %Snapshot{globally_valid?: true, diagnostics: [], targets: %{"main" => target}}} =
             Schema.validate(document, home: "/tmp/schema-home")

    assert %Target{
             id: "main",
             configured_state: :paused,
             effective_state: :paused,
             dispatch_mode: nil,
             valid?: true,
             repo_manifest: nil,
             effective_policy: nil,
             policy_hash: nil,
             diagnostics: []
           } = target

    assert target.configured["repo"]["path"] == "/tmp/schema-home/repo"
    assert target.configured["worktree"]["root"] == "/tmp/schema-home/worktrees"
  end

  test "target maps and target IDs are strict but remain visible" do
    cases = [
      {"Bad ID", valid_target(), "$.targets.Bad ID", :invalid_id},
      {"-main", valid_target(), "$.targets.-main", :invalid_id},
      {"main", [], "$.targets.main", :invalid_type},
      {"main", Map.put(valid_target(), "extra", true), "$.targets.main.extra", :unknown_key}
    ]

    for {id, configured, path, code} <- cases do
      document = put_in(valid_document(), ["targets"], %{id => configured})

      assert {:ok, %Snapshot{globally_valid?: true, targets: %{^id => target}}} =
               Schema.validate(document, home: "/tmp/schema-home")

      refute target.valid?
      assert target.effective_state == :paused
      assert Enum.any?(target.diagnostics, &(&1.path == path and &1.code == code))
    end
  end

  test "target policy maps are required and must be maps" do
    fields = ~w(repo worktree linear runners concurrency budgets checks external_side_effects scheduling)

    for field <- fields do
      {_, target} = Map.pop(valid_target(), field)
      document = put_in(valid_document(), ["targets"], %{"main" => target})

      code = if field == "external_side_effects", do: :incomplete_policy, else: :missing_required_field
      assert_target_diagnostic(document, "$.targets.main.#{field}", code)

      target = Map.put(valid_target(), field, [])
      document = put_in(valid_document(), ["targets"], %{"main" => target})
      assert_target_diagnostic(document, "$.targets.main.#{field}", :invalid_type)
    end
  end

  test "display name must be a non-empty trimmed string" do
    for value <- ["", "  ", " Main", "Main ", 1, nil] do
      target = Map.put(valid_target(), "display_name", value)
      document = put_in(valid_document(), ["targets"], %{"main" => target})

      code = if is_binary(value), do: :invalid_value, else: :invalid_type
      assert_target_diagnostic(document, "$.targets.main.display_name", code)
    end
  end

  test "every nested policy map rejects unknown keys" do
    target =
      valid_target()
      |> put_in(["repo", "extra"], true)
      |> put_in(["worktree", "extra"], true)
      |> put_in(["worktree", "hooks", "extra"], true)
      |> put_in(["linear", "extra"], true)
      |> put_in(["linear", "scope", "extra"], true)
      |> put_in(["runners", "extra"], true)
      |> put_in(["runners", "settings"], %{
        "codex" => %{"model" => "gpt", "extra" => true}
      })
      |> put_in(["concurrency", "extra"], true)
      |> put_in(["budgets", "extra"], true)
      |> put_in(["budgets", "per_run", "extra"], true)
      |> put_in(["checks", "extra"], [])
      |> put_in(["external_side_effects", "extra"], "deny")
      |> put_in(["scheduling", "extra"], true)

    document = put_in(valid_document(), ["targets"], %{"main" => target})

    assert {:ok, %Snapshot{targets: %{"main" => result}}} =
             Schema.validate(document, home: "/tmp/schema-home")

    assert Enum.map(result.diagnostics, &{&1.path, &1.code}) == [
             {"$.targets.main.budgets.extra", :unknown_key},
             {"$.targets.main.budgets.per_run.extra", :unknown_key},
             {"$.targets.main.checks.extra", :unknown_key},
             {"$.targets.main.concurrency.extra", :unknown_key},
             {"$.targets.main.external_side_effects.extra", :unknown_gate},
             {"$.targets.main.linear.extra", :unknown_key},
             {"$.targets.main.linear.scope.extra", :unknown_key},
             {"$.targets.main.repo.extra", :unknown_key},
             {"$.targets.main.runners.extra", :unknown_key},
             {"$.targets.main.runners.settings.codex.extra", :unknown_key},
             {"$.targets.main.scheduling.extra", :unknown_key},
             {"$.targets.main.worktree.extra", :unknown_key},
             {"$.targets.main.worktree.hooks.extra", :unknown_key}
           ]
  end

  test "nested required fields report exact local paths" do
    cases = [
      {["repo", "path"], "$.targets.main.repo.path"},
      {["worktree", "root"], "$.targets.main.worktree.root"},
      {["worktree", "strategy"], "$.targets.main.worktree.strategy"},
      {["linear", "connection"], "$.targets.main.linear.connection"},
      {["linear", "scope"], "$.targets.main.linear.scope"},
      {["linear", "scope", "type"], "$.targets.main.linear.scope.type"},
      {["linear", "active_states"], "$.targets.main.linear.active_states"},
      {["linear", "terminal_states"], "$.targets.main.linear.terminal_states"},
      {["runners", "allowed"], "$.targets.main.runners.allowed"},
      {["runners", "default"], "$.targets.main.runners.default"},
      {["concurrency", "max_concurrent_agents"], "$.targets.main.concurrency.max_concurrent_agents"},
      {["concurrency", "max_concurrent_startups"], "$.targets.main.concurrency.max_concurrent_startups"},
      {["concurrency", "max_concurrent_reviewers"], "$.targets.main.concurrency.max_concurrent_reviewers"},
      {["budgets", "per_run"], "$.targets.main.budgets.per_run"},
      {["budgets", "daily"], "$.targets.main.budgets.daily"},
      {["budgets", "weekly"], "$.targets.main.budgets.weekly"},
      {["budgets", "per_run", "max_total_tokens"], "$.targets.main.budgets.per_run.max_total_tokens"},
      {["budgets", "daily", "max_total_tokens"], "$.targets.main.budgets.daily.max_total_tokens"},
      {["budgets", "weekly", "max_total_tokens"], "$.targets.main.budgets.weekly.max_total_tokens"},
      {["scheduling", "weight"], "$.targets.main.scheduling.weight"}
    ]

    for {keys, path} <- cases do
      {_, target} = pop_in(valid_target(), keys)
      assert_target_diagnostic(target_document(target), path, :missing_required_field)
    end

    {_, target} = Map.pop(valid_target(), "external_side_effects")

    assert_target_diagnostic(
      target_document(target),
      "$.targets.main.external_side_effects",
      :incomplete_policy
    )
  end

  test "optional maps and list-like values normalize deterministically" do
    target =
      valid_target()
      |> update_in(["repo"], &Map.delete(&1, "manifest"))
      |> update_in(["worktree"], &Map.delete(&1, "hooks"))
      |> put_in(["linear", "scope"], %{
        "type" => "issues",
        "issue_ids" => [" ENG-1 ", "eng-1", "ENG-2"]
      })
      |> put_in(["linear", "active_states"], [" Todo ", "todo", "In Progress"])
      |> put_in(["linear", "terminal_states"], [" Done ", "done"])
      |> update_in(["linear"], &Map.delete(&1, "required_labels"))
      |> put_in(["linear", "required_labels"], [" Bug ", "BUG", "ready"])
      |> put_in(["runners", "allowed"], ["codex", "codex"])
      |> update_in(["runners"], &Map.delete(&1, "settings"))
      |> put_in(["concurrency", "by_linear_state"], %{" Todo " => 2, "IN PROGRESS" => 1})
      |> put_in(["checks"], %{
        "pre_dispatch" => ["capability_preflight", "capability_preflight"]
      })
      |> put_in(["external_side_effects"], %{"tracker_write" => "allow"})

    assert {:ok, %Snapshot{targets: %{"main" => %Target{valid?: true, configured: configured}}}} =
             Schema.validate(target_document(target), home: "/tmp/schema-home")

    assert configured["repo"]["manifest"] == "symphony.yml"

    assert configured["worktree"]["hooks"] == %{
             "after_create" => nil,
             "before_run" => nil,
             "after_run" => nil,
             "before_remove" => nil,
             "timeout_ms" => 60_000
           }

    assert configured["linear"]["scope"]["issue_ids"] == ["ENG-1", "ENG-2"]
    assert configured["linear"]["active_states"] == ["Todo", "In Progress"]
    assert configured["linear"]["terminal_states"] == ["Done"]
    assert configured["linear"]["required_labels"] == ["bug", "ready"]
    assert configured["runners"]["allowed"] == ["codex"]
    assert configured["runners"]["settings"] == %{}

    assert configured["concurrency"]["by_linear_state"] == %{
             "in progress" => 1,
             "todo" => 2
           }

    assert configured["checks"] == %{
             "pre_dispatch" => ["capability_preflight"],
             "pre_handoff" => [],
             "pre_publish" => [],
             "pre_merge" => []
           }

    assert configured["external_side_effects"] == %{
             "tracker_write" => "allow",
             "vcs_publish" => "deny",
             "pull_request_write" => "deny",
             "merge" => "deny",
             "deployment" => "deny",
             "production_data" => "deny"
           }
  end

  test "worktree hook normalization preserves commands and explicit timeout" do
    hooks = %{
      "after_create" => "printf 'token=sk-test-after-create'",
      "before_run" => "printf 'before'\nprintf 'run'",
      "after_run" => nil,
      "before_remove" => "printf 'remove'",
      "timeout_ms" => 12_345
    }

    target = put_in(valid_target(), ["worktree", "hooks"], hooks)

    assert {:ok, %Snapshot{targets: %{"main" => %Target{valid?: true, configured: configured}}}} =
             Schema.validate(target_document(target), home: "/tmp/schema-home")

    assert configured["worktree"]["hooks"] == hooks
  end

  test "repository, worktree, Linear, and runner fields enforce local types and enums" do
    cases = [
      {["repo", "path"], 1, :invalid_type},
      {["repo", "manifest"], "", :invalid_value},
      {["repo", "expected_repository"], "", :invalid_value},
      {["worktree", "root"], false, :invalid_type},
      {["worktree", "strategy"], "shared", :invalid_value},
      {["worktree", "hooks"], [], :invalid_type},
      {["worktree", "hooks", "after_create"], "", :invalid_value},
      {["worktree", "hooks", "timeout_ms"], 0, :invalid_type},
      {["linear", "connection"], 1, :invalid_type},
      {["linear", "scope"], [], :invalid_type},
      {["linear", "scope", "type"], "workspace", :invalid_value},
      {["linear", "scope", "project_id"], 1, :invalid_type},
      {["linear", "scope", "project_slug"], "", :invalid_value},
      {["linear", "scope", "team_key"], "", :invalid_value},
      {["linear", "scope", "query_file"], "", :invalid_value},
      {["linear", "scope", "issue_ids"], [], :invalid_value},
      {["linear", "active_states"], [], :invalid_value},
      {["linear", "terminal_states"], "Done", :invalid_type},
      {["linear", "required_labels"], [1], :invalid_type},
      {["runners", "allowed"], [], :invalid_value},
      {["runners", "allowed"], ["Bad Runner"], :invalid_id},
      {["runners", "default"], "Bad Runner", :invalid_id},
      {["runners", "settings"], [], :invalid_type}
    ]

    for {keys, value, code} <- cases do
      target = put_in(valid_target(), keys, value)
      item_path? = keys in [["linear", "required_labels"], ["runners", "allowed"]] and value != []
      path = if item_path?, do: target_path(keys) <> "[0]", else: target_path(keys)
      assert_target_diagnostic(target_document(target), path, code)
    end

    for hook <- ~w(after_create before_run after_run before_remove) do
      target = put_in(valid_target(), ["worktree", "hooks", hook], nil)

      assert {:ok, %Snapshot{targets: %{"main" => %Target{valid?: true}}}} =
               Schema.validate(target_document(target), home: "/tmp/schema-home")
    end
  end

  test "runner settings enforce local fields without runner-catalog validation" do
    valid_settings = %{
      "model" => "gpt-5.6",
      "reasoning_effort" => "xhigh",
      "max_turns" => 20,
      "execution_profiles" => %{"default" => %{"sandbox" => "workspace-write"}}
    }

    target = put_in(valid_target(), ["runners", "settings"], %{"codex" => valid_settings})

    assert {:ok, %Snapshot{targets: %{"main" => %Target{valid?: true}}}} =
             Schema.validate(target_document(target), home: "/tmp/schema-home")

    cases = [
      {["runners", "settings", "Bad Runner"], valid_settings, :invalid_id},
      {["runners", "settings", "codex"], [], :invalid_type},
      {["runners", "settings", "codex", "model"], "", :invalid_value},
      {["runners", "settings", "codex", "reasoning_effort"], "extreme", :invalid_value},
      {["runners", "settings", "codex", "max_turns"], 0, :invalid_type},
      {["runners", "settings", "codex", "execution_profiles"], [], :invalid_type}
    ]

    for {keys, value, code} <- cases do
      target =
        valid_target()
        |> put_in(["runners", "settings"], %{"codex" => valid_settings})
        |> put_in(keys, value)

      assert_target_diagnostic(target_document(target), target_path(keys), code)
    end
  end

  test "concurrency, budgets, checks, gates, and scheduling are strict" do
    positive_paths = [
      ["concurrency", "max_concurrent_agents"],
      ["concurrency", "max_concurrent_startups"],
      ["concurrency", "max_concurrent_reviewers"],
      ["budgets", "per_run", "max_total_tokens"],
      ["budgets", "daily", "max_total_tokens"],
      ["budgets", "weekly", "max_total_tokens"]
    ]

    for keys <- positive_paths, value <- [0, -1, 1.5, "1"] do
      target = put_in(valid_target(), keys, value)
      assert_target_diagnostic(target_document(target), target_path(keys), :invalid_type)
    end

    state_limit_path = "$.targets.main.concurrency.by_linear_state"

    for {value, path, code} <- [
          {[], state_limit_path, :invalid_type},
          {%{"Todo" => 0}, state_limit_path <> ".Todo", :invalid_type},
          {%{"" => 1}, state_limit_path <> "[key:0:string]", :invalid_value}
        ] do
      target = put_in(valid_target(), ["concurrency", "by_linear_state"], value)
      assert_target_diagnostic(target_document(target), path, code)
    end

    target = put_in(valid_target(), ["checks", "pre_dispatch"], "capability_preflight")
    assert_target_diagnostic(target_document(target), "$.targets.main.checks.pre_dispatch", :invalid_type)

    target = put_in(valid_target(), ["checks", "pre_dispatch"], ["unknown"])
    assert_target_diagnostic(target_document(target), "$.targets.main.checks.pre_dispatch[0]", :unknown_check)

    target = put_in(valid_target(), ["checks", "pre_dispatch"], [1])
    assert_target_diagnostic(target_document(target), "$.targets.main.checks.pre_dispatch[0]", :invalid_type)

    target = put_in(valid_target(), ["external_side_effects", "merge"], "sometimes")
    assert_target_diagnostic(target_document(target), "$.targets.main.external_side_effects.merge", :unknown_gate)

    for {weight, code} <- [{0, :invalid_value}, {101, :invalid_value}, {1.5, :invalid_type}] do
      target = put_in(valid_target(), ["scheduling", "weight"], weight)
      assert_target_diagnostic(target_document(target), "$.targets.main.scheduling.weight", code)
    end
  end

  test "normalized Linear state limit key collisions quarantine the target without data loss" do
    limits = %{" Todo " => 2, "todo" => 3}

    target =
      valid_target()
      |> Map.put("state", "active")
      |> Map.put("dispatch_mode", "explicit")
      |> put_in(["concurrency", "by_linear_state"], limits)

    assert {:ok, %Snapshot{globally_valid?: true, targets: %{"main" => result}}} =
             Schema.validate(target_document(target), home: "/tmp/schema-home")

    refute result.valid?
    assert result.configured_state == :active
    assert result.effective_state == :paused
    assert result.configured["concurrency"]["by_linear_state"] == limits

    assert Enum.map(result.diagnostics, &{&1.path, &1.code, &1.message}) == [
             {"$.targets.main.concurrency.by_linear_state.todo", :duplicate_key, "$.targets.main.concurrency.by_linear_state.todo collides after trim and lowercase normalization"}
           ]
  end

  test "state limit diagnostics identify each invalid entry once and deterministically" do
    limits = %{7 => 0, "" => 1, "Blocked" => 0, "Todo" => "many"}
    target = put_in(valid_target(), ["concurrency", "by_linear_state"], limits)
    document = target_document(target)

    assert {:ok, %Snapshot{targets: %{"main" => first}}} =
             Schema.validate(document, home: "/tmp/schema-home")

    assert {:ok, %Snapshot{targets: %{"main" => second}}} =
             Schema.validate(document, home: "/tmp/schema-home")

    expected = [
      {"$.targets.main.concurrency.by_linear_state.Blocked", :invalid_type, "$.targets.main.concurrency.by_linear_state.Blocked must be a positive integer"},
      {"$.targets.main.concurrency.by_linear_state.Todo", :invalid_type, "$.targets.main.concurrency.by_linear_state.Todo must be a positive integer"},
      {"$.targets.main.concurrency.by_linear_state[key:0:integer]", :invalid_type, "$.targets.main.concurrency.by_linear_state[key:0:integer] state name must be a string"},
      {"$.targets.main.concurrency.by_linear_state[key:1:string]", :invalid_value, "$.targets.main.concurrency.by_linear_state[key:1:string] state name must not be blank"}
    ]

    diagnostics = Enum.map(first.diagnostics, &{&1.path, &1.code, &1.message})
    assert diagnostics == expected
    assert diagnostics == Enum.map(second.diagnostics, &{&1.path, &1.code, &1.message})
    assert diagnostics == Enum.uniq(diagnostics)
  end

  test "exact numeric Linear state keys use insertion-independent diagnostic indexes" do
    entries =
      [{1, 1}, {1.0, 1}] ++
        Enum.map(1..31, &{"k#{&1}", 1})

    limits_by_insertion = [Map.new(entries), entries |> Enum.reverse() |> Map.new()]
    assert Enum.at(limits_by_insertion, 0) === Enum.at(limits_by_insertion, 1)

    diagnostics_by_insertion =
      Enum.map(limits_by_insertion, fn limits ->
        target = put_in(valid_target(), ["concurrency", "by_linear_state"], limits)
        assert {:ok, %Snapshot{targets: %{"main" => result}}} = Schema.validate(target_document(target))

        Enum.map(result.diagnostics, &{&1.path, &1.code, &1.message})
      end)

    expected = [
      {"$.targets.main.concurrency.by_linear_state[key:0:float]", :invalid_type, "$.targets.main.concurrency.by_linear_state[key:0:float] state name must be a string"},
      {"$.targets.main.concurrency.by_linear_state[key:1:integer]", :invalid_type, "$.targets.main.concurrency.by_linear_state[key:1:integer] state name must be a string"}
    ]

    assert diagnostics_by_insertion == [expected, expected]
  end

  defp target_document(target) do
    put_in(valid_document(), ["targets"], %{"main" => target})
  end

  defp target_path(keys), do: "$.targets.main." <> Enum.join(keys, ".")

  test "optional omissions and boundary path expansion remain deterministic" do
    host = Map.put(valid_host(), "state_root", "~/")

    target =
      valid_target()
      |> Map.delete("display_name")
      |> put_in(["repo", "path"], "~/")
      |> put_in(["worktree", "root"], "~/")
      |> update_in(["concurrency"], &Map.delete(&1, "by_linear_state"))

    document =
      valid_document()
      |> Map.put("host", host)
      |> put_in(["targets"], %{"main" => target})

    assert {:ok, %Snapshot{host: configured_host, targets: %{"main" => result}}} =
             Schema.validate(document, home: "/tmp/schema-home")

    assert result.valid?
    assert configured_host["state_root"] == "/tmp/schema-home"
    assert result.configured["repo"]["path"] == "/tmp/schema-home"
    assert result.configured["worktree"]["root"] == "/tmp/schema-home"
    assert result.configured["concurrency"]["by_linear_state"] == %{}
  end

  test "normalization preserves omitted fields and explicit nulls on invalid targets" do
    omitted =
      valid_target()
      |> update_in(["repo"], &Map.delete(&1, "path"))
      |> update_in(["worktree"], &Map.delete(&1, "root"))
      |> update_in(["linear"], &Map.delete(&1, "active_states"))
      |> update_in(["linear"], &Map.delete(&1, "terminal_states"))
      |> update_in(["runners"], &Map.delete(&1, "allowed"))

    explicit_null =
      valid_target()
      |> put_in(["repo", "path"], nil)
      |> put_in(["worktree", "root"], nil)
      |> put_in(["linear", "active_states"], nil)
      |> put_in(["linear", "terminal_states"], nil)
      |> put_in(["linear", "scope", "issue_ids"], nil)
      |> put_in(["runners", "allowed"], nil)

    document =
      valid_document()
      |> put_in(["targets"], %{"null" => explicit_null, "omitted" => omitted})

    assert {:ok, %Snapshot{targets: %{"null" => null_result, "omitted" => omitted_result}}} =
             Schema.validate(document, home: "/tmp/schema-home")

    refute null_result.valid?
    refute omitted_result.valid?

    refute Map.has_key?(omitted_result.configured["repo"], "path")
    refute Map.has_key?(omitted_result.configured["worktree"], "root")
    refute Map.has_key?(omitted_result.configured["linear"], "active_states")
    refute Map.has_key?(omitted_result.configured["linear"], "terminal_states")
    refute Map.has_key?(omitted_result.configured["linear"]["scope"], "issue_ids")
    refute Map.has_key?(omitted_result.configured["runners"], "allowed")

    assert Map.fetch!(null_result.configured["repo"], "path") == nil
    assert Map.fetch!(null_result.configured["worktree"], "root") == nil
    assert Map.fetch!(null_result.configured["linear"], "active_states") == nil
    assert Map.fetch!(null_result.configured["linear"], "terminal_states") == nil
    assert Map.fetch!(null_result.configured["linear"]["scope"], "issue_ids") == nil
    assert Map.fetch!(null_result.configured["runners"], "allowed") == nil
  end

  test "remaining nested wrong types produce field-local diagnostics" do
    host_cases = [
      {["host", "scheduling", "algorithm"], 1, "$.host.scheduling.algorithm"},
      {["host", "tracker_connections", "linear-main", "kind"], 1, "$.host.tracker_connections.linear-main.kind"},
      {["host", "tracker_connections", "linear-main", "endpoint"], 1, "$.host.tracker_connections.linear-main.endpoint"},
      {["host", "tracker_connections", "linear-main", "api_key"], 1, "$.host.tracker_connections.linear-main.api_key"}
    ]

    for {keys, value, path} <- host_cases do
      assert_diagnostic(put_in(valid_document(), keys, value), :host, path, :invalid_type)
    end

    target_cases = [
      {["runners", "allowed"], 1, "$.targets.main.runners.allowed", :invalid_type},
      {["runners", "allowed"], [1], "$.targets.main.runners.allowed[0]", :invalid_type},
      {["linear", "active_states"], [" "], "$.targets.main.linear.active_states[0]", :invalid_value},
      {["external_side_effects", "merge"], 1, "$.targets.main.external_side_effects.merge", :invalid_type},
      {["concurrency", "by_linear_state"], %{1 => 1}, "$.targets.main.concurrency.by_linear_state[key:0:integer]", :invalid_type}
    ]

    for {keys, value, path, code} <- target_cases do
      target = put_in(valid_target(), keys, value)
      assert_target_diagnostic(target_document(target), path, code)
    end
  end

  test "missing and unknown state are explicit and fail closed" do
    target = Map.delete(valid_target(), "state")

    assert {:ok, %Snapshot{targets: %{"main" => missing}}} =
             Schema.validate(target_document(target), home: "/tmp/schema-home")

    assert %Target{
             configured_state: nil,
             effective_state: :paused,
             valid?: true,
             diagnostics: [
               %TargetRegistry.Diagnostic{
                 severity: :warning,
                 code: :missing_state,
                 path: "$.targets.main.state"
               }
             ]
           } = missing

    for {state, configured_state, code} <- [
          {"sleeping", {:unknown, "sleeping"}, :unknown_state},
          {1, nil, :invalid_type}
        ] do
      target = Map.put(valid_target(), "state", state)

      assert {:ok, %Snapshot{targets: %{"main" => result}}} =
               Schema.validate(target_document(target), home: "/tmp/schema-home")

      assert result.configured_state == configured_state
      assert result.effective_state == :paused
      refute result.valid?
      assert Enum.any?(result.diagnostics, &(&1.code == code and &1.path == "$.targets.main.state"))
    end
  end

  test "known states and dispatch modes retain configured intent" do
    cases = [
      {"paused", nil, :paused, nil},
      {"paused", "watch", :paused, :watch},
      {"active", "explicit", :active, :explicit},
      {"active", "watch", :active, :watch},
      {"draining", "explicit", :draining, :explicit},
      {"retired", "watch", :retired, :watch}
    ]

    for {state, mode, effective_state, dispatch_mode} <- cases do
      target =
        valid_target()
        |> Map.put("state", state)
        |> then(fn target ->
          if is_nil(mode), do: Map.delete(target, "dispatch_mode"), else: Map.put(target, "dispatch_mode", mode)
        end)

      assert {:ok, %Snapshot{targets: %{"main" => result}}} =
               Schema.validate(target_document(target), home: "/tmp/schema-home")

      assert result.valid?
      assert result.configured_state == String.to_existing_atom(state)
      assert result.effective_state == effective_state
      assert result.dispatch_mode == dispatch_mode
    end
  end

  test "active without a known mode and invalid modes are quarantined" do
    active_without_mode = valid_target() |> Map.put("state", "active") |> Map.delete("dispatch_mode")

    assert {:ok, %Snapshot{targets: %{"main" => missing_mode}}} =
             Schema.validate(target_document(active_without_mode), home: "/tmp/schema-home")

    assert Enum.map(missing_mode.diagnostics, & &1.code) == [:missing_dispatch_mode]

    for {mode, configured_mode, code} <- [
          {"automatic", {:unknown, "automatic"}, :unknown_dispatch_mode},
          {1, nil, :invalid_type}
        ] do
      target = valid_target() |> Map.put("state", "active") |> Map.put("dispatch_mode", mode)

      assert {:ok, %Snapshot{targets: %{"main" => result}}} =
               Schema.validate(target_document(target), home: "/tmp/schema-home")

      assert result.dispatch_mode == configured_mode
      assert result.effective_state == :paused
      refute result.valid?
      assert Enum.map(result.diagnostics, & &1.code) == [code]
    end
  end

  test "any target error forces paused state without hiding configured state" do
    for state <- ~w(active draining retired) do
      target =
        valid_target()
        |> Map.put("state", state)
        |> Map.put("dispatch_mode", "explicit")
        |> put_in(["scheduling", "weight"], 0)

      assert {:ok, %Snapshot{globally_valid?: true, targets: %{"main" => result}}} =
               Schema.validate(target_document(target), home: "/tmp/schema-home")

      assert result.configured_state == String.to_existing_atom(state)
      assert result.effective_state == :paused
      refute result.valid?
    end
  end

  test "diagnostics sort by scope, path, code, and message" do
    target_a =
      valid_target()
      |> Map.put("zeta", true)
      |> Map.put("alpha", true)

    target_b =
      valid_target()
      |> put_in(["scheduling", "weight"], 0)

    document =
      %{
        "targets" => %{"z-target" => target_a, "a-target" => target_b},
        "host" => Map.put(valid_host(), "zeta", true),
        "version" => 1,
        "zeta" => true
      }

    assert {:ok, snapshot} = Schema.validate(document, home: "/tmp/schema-home")

    assert Enum.map(snapshot.diagnostics, &{&1.scope, &1.path, &1.code}) == [
             {:registry, "$.zeta", :unknown_key},
             {:host, "$.host.zeta", :unknown_key},
             {{:target, "a-target"}, "$.targets.a-target.scheduling.weight", :invalid_value},
             {{:target, "z-target"}, "$.targets.z-target.alpha", :unknown_key},
             {{:target, "z-target"}, "$.targets.z-target.zeta", :unknown_key}
           ]
  end

  defp assert_target_diagnostic(document, path, code) do
    assert {:ok, %Snapshot{globally_valid?: true, targets: %{"main" => target}}} =
             Schema.validate(document, home: "/tmp/schema-home")

    refute target.valid?
    assert target.effective_state == :paused
    assert Enum.any?(target.diagnostics, &(&1.path == path and &1.code == code))
  end

  defp assert_diagnostic(document, scope, path, code) do
    assert {:ok, snapshot} = Schema.validate(document, home: "/tmp/schema-home")
    assert Enum.any?(snapshot.diagnostics, &(&1.scope == scope and &1.path == path and &1.code == code))
  end

  defp diagnostic_values(diagnostics) do
    Enum.map(diagnostics, &{&1.scope, &1.path, &1.code, &1.message})
  end

  defp path_for(keys), do: "$." <> Enum.join(keys, ".")
  defp scope_for([field]) when field in ["host", "targets"], do: :registry
  defp scope_for(["host" | _rest]), do: :host
  defp scope_for(_keys), do: :registry

  defp valid_document do
    %{"version" => 1, "host" => valid_host(), "targets" => %{}}
  end

  defp valid_target do
    %{
      "display_name" => "Main",
      "state" => "paused",
      "repo" => %{"path" => "~/repo", "manifest" => "symphony.yml"},
      "worktree" => %{"root" => "~/worktrees", "strategy" => "per_issue", "hooks" => %{}},
      "linear" => %{
        "connection" => "linear-main",
        "scope" => %{"type" => "project", "project_id" => "project-1"},
        "active_states" => ["Todo", "In Progress"],
        "terminal_states" => ["Done"],
        "required_labels" => []
      },
      "runners" => %{"allowed" => ["codex"], "default" => "codex", "settings" => %{}},
      "concurrency" => %{
        "max_concurrent_agents" => 4,
        "max_concurrent_startups" => 2,
        "max_concurrent_reviewers" => 1,
        "by_linear_state" => %{}
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

  defp valid_host do
    %{
      "id" => "local-host",
      "state_root" => "~/state",
      "polling" => %{"interval_ms" => 1_000, "max_concurrent_target_polls" => 2},
      "capacity" => %{
        "max_concurrent_agents" => 4,
        "max_concurrent_startups" => 2,
        "max_concurrent_reviewers" => 1
      },
      "scheduling" => %{
        "algorithm" => "weighted_deficit_round_robin",
        "max_credit_rounds" => 3
      },
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
    }
  end
end
