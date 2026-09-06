defmodule SymphonyElixir.OperatorApiControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias SymphonyElixir.Linear.MetadataCache
  alias SymphonyElixir.OperatorInterface
  alias SymphonyElixir.TargetRegistry.{FileStore, Yaml}

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticHost do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}

    def handle_call({:replace, replacement}, _from, _snapshot), do: {:reply, :ok, replacement}

    def handle_call({:refresh, _generation}, _from, snapshot) do
      snapshot = Map.update(snapshot, :refresh_count, 1, &(&1 + 1))

      if snapshot[:fail_refresh] do
        changed = put_in(snapshot, [:registry, :generation], "sha256:changed-before-error")
        {:reply, {:error, :registry_reload_failed}, changed}
      else
        {:reply, {:ok, snapshot}, snapshot}
      end
    end
  end

  defmodule StaticControlPlane do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call(:inspect_runs, _from, state), do: {:reply, {:ok, []}, state}

    def handle_call(:inspect_target_budgets, _from, state), do: {:reply, {:ok, []}, state}
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "operator-http-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    clock = start_supervised!({Agent, fn -> 0 end})
    previous = Application.get_env(:symphony_elixir, @endpoint, [])

    interface = Module.concat(__MODULE__, "Interface#{System.unique_integer([:positive])}")

    interface_opts = [
      name: interface,
      host_id: "host-http",
      install_log_handler: false,
      config_root: root,
      clock: fn -> Agent.get(clock, & &1) end
    ]

    interface_pid = start_supervised!({OperatorInterface, interface_opts})

    {:ok, %{token_path: token_path}} = OperatorInterface.credentials(interface)
    credential = File.read!(token_path)

    host = %{
      counts: %{agents: 0, startups: 0, reviewers: 0, polls: 0},
      limits: %{agents: 4, startups: 2, reviewers: 2, polls: %{max_concurrent: 2}},
      registry: %{generation: "sha256:http", verified?: true, error: nil},
      targets: %{}
    }

    host_scheduler = start_supervised!({StaticHost, host})
    control_plane = start_supervised!(StaticControlPlane)

    configured_interface =
      if context[:missing_interface], do: unique_name(:missing_interface), else: interface

    configured_scheduler =
      if context[:missing_scheduler], do: unique_name(:missing_scheduler), else: host_scheduler

    Application.put_env(
      :symphony_elixir,
      @endpoint,
      previous
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(
        operator_interface: configured_interface,
        host_scheduler: configured_scheduler,
        control_plane: control_plane,
        snapshot_timeout_ms: 50
      )
    )

    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    on_exit(fn -> Application.put_env(:symphony_elixir, @endpoint, previous) end)

    %{
      interface: interface,
      interface_pid: interface_pid,
      credential: credential,
      scheduler: host_scheduler,
      clock: clock
    }
  end

  test "HTTP snapshot and cursor feed expose one versioned contract", %{interface: interface} do
    snapshot = build_conn() |> get("/api/v1/operator/snapshot") |> json_response(200)

    assert snapshot["interface_version"] == 1
    assert snapshot["schema_version"] == 1
    assert snapshot["host"]["id"] == "host-http"
    assert snapshot["snapshot"]["mode"] == "complete"
    assert snapshot["snapshot"]["event_cursor"] == 0
    assert snapshot["freshness"]["status"] == "live"

    OperatorInterface.publish_state_change(interface)

    events =
      build_conn()
      |> get("/api/v1/operator/events?host_id=host-http&after=0")
      |> json_response(200)

    assert events["host_id"] == "host-http"
    assert events["latest_cursor"] == 1
    assert [%{"cursor" => 1, "kind" => "snapshot_invalidated"}] = events["events"]
    assert events["snapshot_replacement"] == %{"required" => false, "reason" => nil}
  end

  test "HTTP cursor validation is explicit" do
    invalid_cursor =
      build_conn()
      |> get("/api/v1/operator/events?host_id=host-http&after=bad")
      |> json_response(400)

    assert invalid_cursor["error"]["code"] == "invalid_event_cursor"

    invalid_limit =
      build_conn()
      |> get("/api/v1/operator/events?host_id=host-http&after=0&limit=501")
      |> json_response(400)

    assert invalid_limit["error"]["code"] == "invalid_event_limit"
  end

  @tag missing_scheduler: true
  test "HTTP source failures remain explicit" do
    unavailable_snapshot =
      build_conn()
      |> get("/api/v1/operator/snapshot")
      |> json_response(200)

    assert unavailable_snapshot["host"]["status"] == "unavailable"
    assert unavailable_snapshot["aggregate"]["counts"]["running"] == nil
    assert unavailable_snapshot["warnings"] != []
  end

  @tag missing_interface: true
  test "HTTP interface failures return a stable service error" do
    snapshot_error = build_conn() |> get("/api/v1/operator/snapshot") |> json_response(503)

    event_error =
      build_conn()
      |> get("/api/v1/operator/events?host_id=host-http&after=0")
      |> json_response(503)

    assert snapshot_error["error"]["code"] == "operator_interface_unavailable"
    assert event_error["error"]["code"] == "operator_interface_unavailable"
  end

  test "HTTP event feed requires a host identifier" do
    error = build_conn() |> get("/api/v1/operator/events?after=0") |> json_response(400)
    assert error["error"]["code"] == "invalid_event_cursor"
  end

  test "settings choices reject remote callers and malformed authenticated inputs", context do
    remote =
      build_conn()
      |> Map.put(:remote_ip, {192, 0, 2, 1})
      |> Plug.Conn.put_req_header("authorization", "Bearer #{context.credential}")
      |> post("/api/v1/operator/settings/choices", %{})
      |> json_response(403)

    assert remote["error"]["code"] == "loopback_required"

    for request <- [%{"selections" => []}, %{"repository" => 42}, %{"linear_revision" => []}, %{"unknown" => true}] do
      invalid =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{context.credential}")
        |> post("/api/v1/operator/settings/choices", request)
        |> json_response(400)

      assert invalid["error"]["code"] == "invalid_inputs"
    end
  end

  test "settings choices require authentication and retain invalid draft selections", context do
    path = Path.join(System.tmp_dir!(), "settings-registry-#{System.unique_integer([:positive])}.yml")
    on_exit(fn -> File.rm(path) end)

    document = %{
      "version" => 1,
      "host" => %{
        "id" => "catalog-host",
        "state_root" => "/tmp/catalog-state",
        "polling" => %{"interval_ms" => 1_000, "max_concurrent_target_polls" => 2},
        "capacity" => %{"max_concurrent_agents" => 4, "max_concurrent_startups" => 1, "max_concurrent_reviewers" => 1},
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 3},
        "tracker_connections" => %{"linear-main" => %{"kind" => "linear", "endpoint" => "https://api.linear.app/graphql", "api_key" => "$CATALOG_SECRET"}},
        "runners" => %{"codex" => %{"kind" => "codex_app_server", "command" => ["codex", "app-server"], "max_concurrent_agents" => 4, "max_concurrent_startups" => 1}}
      },
      "targets" => %{}
    }

    File.write!(path, Yaml.encode(document))
    {:ok, %{generation: generation}} = FileStore.read(path)
    GenServer.call(context.scheduler, {:replace, %{registry: %{path: path, generation: generation, verified?: true}}})

    request = %{"selections" => %{"runners.allowed" => ["codex"], "runners.default" => "codex", "state" => "paused", "checks.pre_dispatch" => ["capability_preflight", "repo_validation"]}}
    unauthorized = build_conn() |> post("/api/v1/operator/settings/choices", request) |> json_response(401)
    assert unauthorized["error"]["code"] == "unauthorized"
    bad_token = build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer wrong") |> post("/api/v1/operator/settings/choices", request) |> json_response(401)
    assert bad_token["error"]["code"] == "unauthorized"

    catalog = build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer #{context.credential}") |> post("/api/v1/operator/settings/choices", request) |> json_response(200)
    refute catalog["apply_blocked"]
    assert catalog["fields"]["state"]["cardinality"] == "scalar"
    assert catalog["fields"]["checks.pre_dispatch"]["cardinality"] == "list"

    assert [%{"value" => "codex", "kind" => "codex_app_server", "status" => "current"}] =
             catalog["fields"]["runners.allowed"]["choices"]

    refute Jason.encode!(catalog) =~ "CATALOG_SECRET"

    invalid =
      put_in(request, ["selections", "runners.allowed"], ["removed"])
      |> put_in(["selections", "state"], ["paused", "active"])

    blocked = build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer #{context.credential}") |> post("/api/v1/operator/settings/choices", invalid) |> json_response(200)
    assert blocked["apply_blocked"]
    assert blocked["fields"]["state"]["reason"] == "invalid_cardinality"
    assert blocked["fields"]["runners.default"]["reason"] == "default_runner_not_allowed"

    assert Enum.any?(blocked["fields"]["runners.allowed"]["choices"], fn choice ->
             choice["value"] == "removed" and choice["status"] == "stale" and choice["selected"]
           end)

    File.write!(path, Yaml.encode(put_in(document, ["host", "id"], "changed-host")))
    stale = build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer #{context.credential}") |> post("/api/v1/operator/settings/choices", request) |> json_response(200)
    assert stale["apply_blocked"]
    assert stale["reason"] == "registry_stale"

    assert [%{"value" => "codex", "status" => "unavailable", "selected" => true}] =
             stale["fields"]["runners.allowed"]["choices"]
  end

  test "settings choices retain configured target selections", context do
    target = catalog_target()
    path = install_catalog_registry!(context.scheduler, catalog_document(%{"alpha" => target}))
    on_exit(fn -> File.rm(path) end)

    request = %{"target_id" => "alpha", "repository" => "", "selections" => %{}}

    catalog =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> context.credential)
      |> post("/api/v1/operator/settings/choices", request)
      |> json_response(200)

    assert catalog["apply_blocked"]
    refute catalog["fields"]["linear.active_states"]["valid"]
    assert catalog["status"] == "current"
    assert catalog["fields"]["state"]["selected"] == "active"
    assert catalog["fields"]["dispatch_mode"]["selected"] == "watch"
    assert catalog["fields"]["worktree.strategy"]["selected"] == "per_issue"
    assert catalog["fields"]["linear.connection"]["selected"] == "linear-main"
    assert catalog["fields"]["linear.scope.type"]["selected"] == "team"
    assert catalog["fields"]["runners.allowed"]["selected"] == ["codex"]
    assert catalog["fields"]["runners.default"]["selected"] == "codex"
    assert catalog["fields"]["checks.pre_dispatch"]["selected"] == ["repo_validation"]
    assert catalog["fields"]["external_side_effects.tracker_write"]["selected"] == "deny"
  end

  test "Linear settings scope choices by identity and retain removed filters", context do
    {opts, revision} = linear_catalog_fixture(context)
    request = %{"target_id" => "alpha", "repository" => "", "selections" => %{}}
    catalog = SymphonyElixir.OperatorSettings.build(context.scheduler, request, opts)
    refute catalog.apply_blocked
    assert catalog.linear.connection_revision == revision

    assert [%{value: "Todo", members: [%{id: "todo-eng", team_id: "eng"}]}] =
             catalog.fields["linear.active_states"].choices
             |> Enum.filter(&(&1.value == "Todo"))

    assert Enum.map(catalog.fields["linear.required_labels"].choices, & &1.value) == ["shared", "team only"]
    assert Enum.map(catalog.fields["linear.scope.project_id"].choices, & &1.value) == ["project-a", "project-b"]

    project =
      put_in(request, ["selections"], %{
        "linear.scope.type" => "project",
        "linear.scope.project_id" => "project-b",
        "linear.scope.team_key" => nil,
        "linear.active_states" => ["Removed"],
        "linear.required_labels" => ["team only"]
      })

    blocked = SymphonyElixir.OperatorSettings.build(context.scheduler, project, opts)
    assert blocked.apply_blocked

    assert Enum.any?(blocked.fields["linear.active_states"].choices, fn choice ->
             choice.value == "Removed" and choice.selected and choice.reason == "selection_removed"
           end)

    assert Enum.any?(blocked.fields["linear.required_labels"].choices, fn choice ->
             choice.value == "team only" and choice.selected and choice.reason == "selection_removed"
           end)

    assert Enum.any?(blocked.fields["linear.active_states"].choices, fn choice ->
             choice.value == "Todo" and Enum.map(choice.members, & &1.team_id) == ["ops"]
           end)
  end

  test "saved required labels retain their case-insensitive catalog identity", context do
    target = put_in(catalog_target(), ["linear", "required_labels"], ["Team only", "Shared"])
    {opts, _revision} = linear_catalog_fixture(context, target)
    request = %{"target_id" => "alpha", "repository" => "", "selections" => %{}}
    catalog = SymphonyElixir.OperatorSettings.build(context.scheduler, request, opts)

    refute catalog.apply_blocked
    assert catalog.fields["linear.required_labels"].selected == ["team only", "shared"]

    assert %{selected: true, status: "current", members: members} =
             Enum.find(catalog.fields["linear.required_labels"].choices, &(&1.value == "shared"))

    assert Enum.map(members, & &1.id) == ["global", "global-case"]
  end

  test "invalid stored Linear scope remains inspectable for correction", context do
    target = put_in(catalog_target(), ["linear", "scope"], "invalid")
    {opts, _revision} = linear_catalog_fixture(context, target)

    catalog =
      SymphonyElixir.OperatorSettings.build(
        context.scheduler,
        %{"target_id" => "alpha", "repository" => ""},
        opts
      )

    assert catalog.apply_blocked
    assert catalog.fields["linear.scope.type"].reason == "selection_required"
  end

  test "connection changes require a current revision and explicit dependent selections", context do
    {opts, _revision} = linear_catalog_fixture(context)
    request = %{"target_id" => "alpha", "repository" => "", "selections" => %{"linear.connection" => "linear-other"}}
    first = SymphonyElixir.OperatorSettings.build(context.scheduler, request, opts)
    assert first.apply_blocked
    assert first.fields["linear.active_states"].reason == "connection_changed"
    await_linear_catalog(opts, "linear-other")
    fresh = SymphonyElixir.OperatorSettings.build(context.scheduler, request, opts)

    acknowledged = Map.put(request, "linear_revision", fresh.linear.connection_revision)
    assert SymphonyElixir.OperatorSettings.build(context.scheduler, acknowledged, opts).apply_blocked

    corrected =
      Map.put(acknowledged, "selections", %{
        "linear.connection" => "linear-other",
        "linear.scope.type" => "team",
        "linear.scope.team_key" => "ENG",
        "linear.active_states" => ["Todo"],
        "linear.terminal_states" => ["Done"],
        "linear.required_labels" => []
      })

    refute SymphonyElixir.OperatorSettings.build(context.scheduler, corrected, opts).apply_blocked

    inherited =
      update_in(corrected, ["selections"], fn selections ->
        selections |> Map.delete("linear.scope.team_key") |> Map.put("linear.scope.project_id", nil)
      end)

    assert SymphonyElixir.OperatorSettings.build(context.scheduler, inherited, opts).apply_blocked
    no_scope = %{"repository" => "", "selections" => %{"linear.connection" => "linear-main"}}
    assert SymphonyElixir.OperatorSettings.build(context.scheduler, no_scope, opts).apply_blocked
    stale = Map.put(corrected, "linear_revision", "old-revision")
    assert SymphonyElixir.OperatorSettings.build(context.scheduler, stale, opts).apply_blocked
  end

  test "stale Linear choices retain selected identities but block Apply", context do
    clock = start_supervised!({Agent, fn -> 0 end}, id: :metadata_clock)
    {opts, _revision} = linear_catalog_fixture(context, catalog_target(), now_fun: fn -> Agent.get(clock, & &1) end, fresh_ttl_ms: 10)
    Agent.update(clock, fn _ -> 11 end)
    catalog = SymphonyElixir.OperatorSettings.build(context.scheduler, %{"target_id" => "alpha", "repository" => ""}, opts)

    assert catalog.linear.status == "stale_cache"
    assert catalog.apply_blocked

    assert %{selected: true, status: "unavailable", members: [%{id: "todo-eng"}]} =
             Enum.find(catalog.fields["linear.active_states"].choices, &(&1.value == "Todo"))
  end

  test "connection changes preserve explicit query and issue scope modes after reselection", context do
    {opts, _revision} = linear_catalog_fixture(context)
    revision = await_linear_catalog(opts, "linear-other").connection_revision

    for {type, path, value} <- [
          {"query", "linear.scope.query_file", "/tmp/linear-query.json"},
          {"issues", "linear.scope.issue_ids", ["SID-486", "SID-463"]}
        ] do
      request = %{
        "target_id" => "alpha",
        "linear_revision" => revision,
        "repository" => "",
        "selections" => %{
          "linear.connection" => "linear-other",
          "linear.active_states" => ["Todo"],
          "linear.terminal_states" => ["Done"],
          "linear.required_labels" => [],
          "linear.scope.type" => type,
          "linear.scope.team_key" => nil,
          path => value
        }
      }

      catalog = SymphonyElixir.OperatorSettings.build(context.scheduler, request, opts)
      refute catalog.apply_blocked
      assert catalog.fields[path].selected == value
      assert catalog.fields[path].input == "explicit"
      refute catalog.fields["linear.scope.project_id"].applicable

      assert Enum.any?(catalog.fields["linear.active_states"].choices, fn choice ->
               choice.value == "Todo" and Enum.map(choice.members, & &1.team_id) == ["eng", "ops"]
             end)
    end
  end

  defp linear_catalog_fixture(context, target \\ catalog_target(), overrides \\ []) do
    document = catalog_document(%{"alpha" => target})
    connection = document["host"]["tracker_connections"]["linear-main"]
    document = put_in(document, ["host", "tracker_connections", "linear-other"], connection)
    path = install_catalog_registry!(context.scheduler, document)
    on_exit(fn -> File.rm(path) end)

    data = %{
      teams: [%{id: "eng", key: "ENG", name: "Engineering"}, %{id: "ops", key: "OPS", name: "Engineering"}],
      projects: [
        %{id: "project-a", slug_id: "a", name: "Duplicate", team_ids: ["eng"]},
        %{id: "project-b", slug_id: "b", name: "Duplicate", team_ids: ["ops"]}
      ],
      states: [
        %{id: "todo-eng", name: "Todo", type: "unstarted", team_id: "eng"},
        %{id: "done-eng", name: "Done", type: "completed", team_id: "eng"},
        %{id: "todo-ops", name: "Todo", type: "unstarted", team_id: "ops"},
        %{id: "done-ops", name: "Done", type: "completed", team_id: "ops"}
      ],
      labels: [
        %{id: "global", name: "Shared", team_id: nil},
        %{id: "global-case", name: "shared", team_id: nil},
        %{id: "team", name: "Team only", team_id: "eng"}
      ]
    }

    cache_opts = [name: nil, fetch_fun: fn _ -> {:ok, data} end, env_fetcher: fn _ -> "fixture-key" end]
    cache = start_supervised!({MetadataCache, Keyword.merge(cache_opts, overrides)})
    opts = [metadata_cache: [server: cache]]
    result = await_linear_catalog(opts, "linear-main")
    {opts, result.connection_revision}
  end

  defp await_linear_catalog(opts, id, attempts \\ 100)
  defp await_linear_catalog(_opts, _id, 0), do: flunk("Linear catalog did not finish")

  defp await_linear_catalog(opts, id, attempts) do
    connection = %{"id" => id, "policy" => catalog_document()["host"]["tracker_connections"]["linear-main"]}
    result = MetadataCache.get(connection, opts[:metadata_cache])

    if result.status == "loading" do
      receive do
      after
        1 -> await_linear_catalog(opts, id, attempts - 1)
      end
    else
      assert result.status == "current"
      result
    end
  end

  test "settings choices block unknown targets and unknown draft fields", context do
    path = install_catalog_registry!(context.scheduler, catalog_document())
    on_exit(fn -> File.rm(path) end)

    request = %{
      "target_id" => "missing-target",
      "repository" => "",
      "selections" => %{"unknown.field" => "submitted"}
    }

    catalog =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> context.credential)
      |> post("/api/v1/operator/settings/choices", request)
      |> json_response(200)

    assert catalog["status"] == "unavailable"
    assert catalog["reason"] == "target_not_found"
    assert catalog["apply_blocked"]
    assert catalog["errors"] == [%{"field" => "unknown.field", "reason" => "unknown_field"}]
  end

  test "settings choices fail closed for absent and unverified registries", context do
    request = %{"repository" => "", "selections" => %{}}

    absent =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> context.credential)
      |> post("/api/v1/operator/settings/choices", request)
      |> json_response(200)

    assert absent["status"] == "unavailable"
    assert absent["reason"] == "registry_unavailable"
    assert absent["apply_blocked"]
    assert get_in(absent, ["fields", "runners.allowed", "choices"]) == []
    assert get_in(absent, ["fields", "linear.connection", "choices"]) == []

    :ok =
      GenServer.call(
        context.scheduler,
        {:replace, %{registry: %{generation: "sha256:http", verified?: false, path: "/gone"}}}
      )

    unverified =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> context.credential)
      |> post("/api/v1/operator/settings/choices", request)
      |> json_response(200)

    assert unverified["status"] == "unavailable"
    assert unverified["reason"] == "registry_unavailable"
    assert unverified["apply_blocked"]
    assert get_in(unverified, ["fields", "runners.allowed", "choices"]) == []
    assert get_in(unverified, ["fields", "linear.connection", "choices"]) == []
  end

  @tag missing_scheduler: true
  test "settings choices fail closed when the host is unavailable", context do
    catalog =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> context.credential)
      |> post("/api/v1/operator/settings/choices", %{"repository" => "", "selections" => %{}})
      |> json_response(200)

    assert catalog["status"] == "unavailable"
    assert catalog["reason"] == "host_unavailable"
    assert catalog["apply_blocked"]
    assert get_in(catalog, ["fields", "runners.allowed", "choices"]) == []
    assert get_in(catalog, ["fields", "linear.connection", "choices"]) == []
  end

  test "invalid host runner and tracker definitions are never available or reflected", context do
    document =
      catalog_document()
      |> put_in(["host", "runners", "unsafe"], %{
        "kind" => %{"credential" => "RUNNER_SECRET"},
        "max_concurrent_agents" => 1,
        "max_concurrent_startups" => 1
      })
      |> put_in(["host", "tracker_connections", "unsafe"], %{
        "kind" => ["TRACKER_SECRET"],
        "endpoint" => "https://tracker.example.invalid/graphql",
        "api_key" => "$TRACKER_KEY"
      })

    path = install_catalog_registry!(context.scheduler, document)
    on_exit(fn -> File.rm(path) end)

    catalog =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> context.credential)
      |> post("/api/v1/operator/settings/choices", %{"repository" => "", "selections" => %{}})
      |> json_response(200)

    assert catalog["status"] == "unavailable"
    assert catalog["reason"] == "registry_invalid"

    runner = Enum.find(catalog["fields"]["runners.allowed"]["choices"], &(&1["value"] == "unsafe"))
    tracker = Enum.find(catalog["fields"]["linear.connection"]["choices"], &(&1["value"] == "unsafe"))

    assert runner["status"] == "invalid"
    assert runner["reason"] == "configuration_invalid"
    assert runner["kind"] == nil
    assert tracker["status"] == "invalid"
    assert tracker["reason"] == "configuration_invalid"
    assert tracker["kind"] == nil
    refute Jason.encode!(catalog) =~ "RUNNER_SECRET"
    refute Jason.encode!(catalog) =~ "TRACKER_SECRET"
  end

  test "preview and navigation never mutate; exact confirmation publishes accepted and completed results", context do
    request = command_request()
    preview = authorized_post(context, "preview", request) |> json_response(200)
    assert is_binary(preview["confirmation_token"])
    assert preview["disabled_reason"] == nil
    assert Map.has_key?(preview, "current_state")
    assert Map.has_key?(preview, "proposed_state")
    assert Map.has_key?(preview, "consequences")
    assert Map.has_key?(preview, "warnings")

    get(build_conn(), "/api/v1/operator/snapshot")
    get(build_conn(), "/api/v1/operator/events?host_id=host-http&after=0")
    assert SymphonyElixir.HostScheduler.snapshot(context.scheduler)[:refresh_count] == nil
    assert get(build_conn(), "/api/v1/operator/commands/confirm") |> response(405)

    confirmation = Map.put(request, "confirmation_token", preview["confirmation_token"])
    accepted = authorized_post(context, "confirm", confirmation) |> json_response(202)
    assert accepted["status"] == "accepted"
    completed = await_result(context.interface, accepted["id"])
    assert completed.status == "completed"
    assert SymphonyElixir.HostScheduler.snapshot(context.scheduler).refresh_count == 1

    snapshot = get(build_conn(), "/api/v1/operator/snapshot") |> json_response(200)
    assert Enum.any?(snapshot["command_results"], &(&1["id"] == accepted["id"] and &1["status"] == "completed"))
    events = get(build_conn(), "/api/v1/operator/events?host_id=host-http&after=0") |> json_response(200)

    statuses =
      events["events"]
      |> Enum.filter(&(&1["kind"] == "command_result" and &1["data"]["id"] == accepted["id"]))
      |> Enum.map(& &1["data"]["status"])

    assert statuses == ["accepted", "completed"]

    replay = authorized_post(context, "confirm", confirmation) |> json_response(409)
    assert replay["error"]["code"] == "invalid_confirmation"
    assert SymphonyElixir.HostScheduler.snapshot(context.scheduler).refresh_count == 1
  end

  test "authentication and loopback checks apply to preview and confirmation", context do
    request = command_request()
    assert post(build_conn(), "/api/v1/operator/commands/preview", request) |> response(401)
    assert authorized_post(%{context | credential: "wrong"}, "preview", request) |> response(401)

    remote = %{build_conn() | remote_ip: {203, 0, 113, 1}}

    assert remote
           |> Plug.Conn.put_req_header("authorization", "Bearer " <> context.credential)
           |> post("/api/v1/operator/commands/preview", request)
           |> response(403)

    preview = authorized_post(context, "preview", request) |> json_response(200)
    confirmation = Map.put(request, "confirmation_token", preview["confirmation_token"])
    assert authorized_post(%{context | credential: "wrong"}, "confirm", confirmation) |> response(401)
    assert SymphonyElixir.HostScheduler.snapshot(context.scheduler)[:refresh_count] == nil
    assert authorized_post(context, "confirm", confirmation) |> response(202)
  end

  test "Bearer authentication accepts case-insensitive schemes without changing credential bytes", context do
    preview =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "bEaReR " <> context.credential)
      |> post("/api/v1/operator/commands/preview", command_request())
      |> json_response(200)

    confirmation = Map.put(command_request(), "confirmation_token", preview["confirmation_token"])

    assert build_conn()
           |> Plug.Conn.put_req_header("authorization", "bearer " <> context.credential)
           |> post("/api/v1/operator/commands/confirm", confirmation)
           |> response(202)
  end

  test "confirmation binds host identity, version, action, identity, and every input", context do
    request = command_request()

    changes = [
      fn body -> Map.put(body, "host_id", "other-host") end,
      fn body -> Map.put(body, "interface_version", 2) end,
      fn body -> put_in(body, ["command", "action"], "shutdown") end,
      fn body -> put_in(body, ["command", "target_id"], "other-target") end,
      fn body -> put_in(body, ["command", "inputs"], %{"unexpected" => "secret://operator/private"}) end
    ]

    for change <- changes do
      preview = authorized_post(context, "preview", request) |> json_response(200)
      confirmation = Map.put(request, "confirmation_token", preview["confirmation_token"])
      conn = authorized_post(context, "confirm", change.(confirmation))
      assert conn.status in [400, 409]
    end

    assert SymphonyElixir.HostScheduler.snapshot(context.scheduler)[:refresh_count] == nil
    events = get(build_conn(), "/api/v1/operator/events?host_id=host-http&after=0") |> json_response(200)
    refute Jason.encode!(events) =~ "secret://operator/private"
    refute Jason.encode!(events) =~ context.credential
  end

  @tag :tmp_dir
  test "a restarted host cannot accept an earlier host session or confirmation", context do
    request = command_request()
    preview = authorized_post(context, "preview", request) |> json_response(200)
    confirmation = Map.put(request, "confirmation_token", preview["confirmation_token"])

    replacement_opts = [
      name: unique_name(:replacement),
      host_id: "host-replacement",
      config_root: context.tmp_dir,
      install_log_handler: false
    ]

    replacement = start_supervised!({OperatorInterface, replacement_opts}, id: :replacement)

    {:ok, metadata} = OperatorInterface.credentials(replacement)
    replacement_credential = File.read!(metadata.token_path)

    assert {:error, %{error: %{code: "unauthorized"}}} =
             OperatorInterface.confirm(replacement, context.credential, confirmation)

    assert {:error, %{error: %{code: "host_mismatch"}}} =
             OperatorInterface.confirm(replacement, replacement_credential, confirmation)

    assert {:error, %{error: %{code: "invalid_confirmation"}}} =
             OperatorInterface.confirm(
               replacement,
               replacement_credential,
               Map.put(confirmation, "host_id", "host-replacement")
             )

    assert SymphonyElixir.HostScheduler.snapshot(context.scheduler)[:refresh_count] == nil
  end

  test "simultaneous confirmations consume a token only once", context do
    request = command_request()
    preview = authorized_post(context, "preview", request) |> json_response(200)
    confirmation = Map.put(request, "confirmation_token", preview["confirmation_token"])

    tasks =
      for _ <- 1..2,
          do: Task.async(fn -> OperatorInterface.confirm(context.interface, context.credential, confirmation) end)

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, %{status: "accepted"}}, &1)) == 1
    assert Enum.count(results, &match?({:error, %{error: %{code: "invalid_confirmation"}}}, &1)) == 1
    assert await_result(context.interface, preview["id"]).status == "completed"
    assert SymphonyElixir.HostScheduler.snapshot(context.scheduler).refresh_count == 1
  end

  test "stale registry and expired previews fail closed", context do
    request = command_request()
    preview = authorized_post(context, "preview", request) |> json_response(200)
    host = SymphonyElixir.HostScheduler.snapshot(context.scheduler)
    :ok = GenServer.call(context.scheduler, {:replace, put_in(host, [:registry, :generation], "sha256:new")})
    confirmation = Map.put(request, "confirmation_token", preview["confirmation_token"])
    error = authorized_post(context, "confirm", confirmation) |> json_response(409)
    assert error["error"]["code"] == "stale_generation"
    refute error["state_may_have_changed"]

    :ok = GenServer.call(context.scheduler, {:replace, host})
    preview = authorized_post(context, "preview", request) |> json_response(200)
    Agent.update(context.clock, fn _ -> 60_000 end)
    confirmation = Map.put(request, "confirmation_token", preview["confirmation_token"])
    error = authorized_post(context, "confirm", confirmation) |> json_response(409)
    assert error["error"]["code"] == "confirmation_expired"
    assert SymphonyElixir.HostScheduler.snapshot(context.scheduler)[:refresh_count] == nil
  end

  test "a failed mutation reports changed state through results and events", context do
    host = SymphonyElixir.HostScheduler.snapshot(context.scheduler)
    :ok = GenServer.call(context.scheduler, {:replace, Map.put(host, :fail_refresh, true)})

    request = command_request()
    preview = authorized_post(context, "preview", request) |> json_response(200)
    confirmation = Map.put(request, "confirmation_token", preview["confirmation_token"])
    accepted = authorized_post(context, "confirm", confirmation) |> json_response(202)
    failed = await_result(context.interface, accepted["id"])
    assert failed.status == "failed"
    assert failed.state_may_have_changed
    assert failed.snapshot_required
    assert SymphonyElixir.HostScheduler.snapshot(context.scheduler).registry.generation == "sha256:changed-before-error"
  end

  defp install_catalog_registry!(scheduler, document) do
    path =
      Path.join(
        System.tmp_dir!(),
        "operator-settings-registry-#{System.unique_integer([:positive])}.yml"
      )

    File.write!(path, Yaml.encode(document))
    {:ok, %{generation: generation}} = FileStore.read(path)

    :ok =
      GenServer.call(
        scheduler,
        {:replace, %{registry: %{path: path, generation: generation, verified?: true}}}
      )

    path
  end

  defp catalog_document(targets \\ %{}) do
    %{
      "version" => 1,
      "host" => %{
        "id" => "catalog-host",
        "state_root" => "/tmp/catalog-state",
        "polling" => %{"interval_ms" => 1_000, "max_concurrent_target_polls" => 2},
        "capacity" => %{
          "max_concurrent_agents" => 4,
          "max_concurrent_startups" => 1,
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
            "api_key" => "$CATALOG_SECRET"
          }
        },
        "runners" => %{
          "codex" => %{
            "kind" => "codex_app_server",
            "command" => ["codex", "app-server"],
            "max_concurrent_agents" => 4,
            "max_concurrent_startups" => 1
          }
        }
      },
      "targets" => targets
    }
  end

  defp catalog_target do
    %{
      "display_name" => "Catalog target",
      "state" => "active",
      "dispatch_mode" => "watch",
      "repo" => %{"path" => "/tmp/catalog-repo"},
      "worktree" => %{
        "root" => "/tmp/catalog-worktrees",
        "strategy" => "per_issue",
        "hooks" => %{}
      },
      "linear" => %{
        "connection" => "linear-main",
        "scope" => %{"type" => "team", "team_key" => "ENG"},
        "active_states" => ["Todo"],
        "terminal_states" => ["Done"],
        "required_labels" => []
      },
      "runners" => %{
        "allowed" => ["codex"],
        "default" => "codex",
        "settings" => %{"codex" => %{"reasoning_effort" => "high"}}
      },
      "concurrency" => %{
        "max_concurrent_agents" => 1,
        "max_concurrent_startups" => 1,
        "max_concurrent_reviewers" => 1,
        "by_linear_state" => %{}
      },
      "budgets" => %{
        "per_run" => %{"max_total_tokens" => 1_000},
        "daily" => %{"max_total_tokens" => 10_000},
        "weekly" => %{"max_total_tokens" => 50_000}
      },
      "checks" => %{
        "pre_dispatch" => ["repo_validation"],
        "pre_handoff" => [],
        "pre_publish" => [],
        "pre_merge" => []
      },
      "external_side_effects" => %{
        "tracker_write" => "deny",
        "vcs_publish" => "deny",
        "pull_request_write" => "deny",
        "merge" => "deny",
        "deployment" => "deny",
        "production_data" => "deny"
      },
      "scheduling" => %{"weight" => 1}
    }
  end

  test "old HTTP mutation routes cannot bypass the authenticated contract" do
    for path <- [
          "/api/v1/refresh",
          "/api/v1/control-plane/runs/run-1/resume",
          "/api/v1/control-plane/runs/run-1/abandon",
          "/api/v1/control-plane/prune"
        ] do
      result = post(build_conn(), path, %{"confirmation" => "old-token"}) |> json_response(410)
      assert result["error"]["code"] == "operator_confirmation_required"
    end
  end

  defp command_request do
    %{
      "interface_version" => 1,
      "host_id" => "host-http",
      "registry_generation" => "sha256:http",
      "command" => %{"action" => "refresh", "inputs" => %{}}
    }
  end

  defp authorized_post(context, operation, body) do
    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> context.credential)
    |> post("/api/v1/operator/commands/" <> operation, body)
  end

  defp await_result(interface, id, attempts \\ 100) do
    {:ok, marker} = OperatorInterface.marker(interface)
    result = Enum.find(marker.command_results, &(&1.id == id))

    if result && result.status != "accepted" do
      result
    else
      assert attempts > 0, "command did not complete"
      Process.sleep(5)
      await_result(interface, id, attempts - 1)
    end
  end

  @tag :tmp_dir
  test "durable commits invalidate snapshots but failed transactions do not", %{tmp_dir: tmp_dir} do
    control_plane =
      start_supervised!({SymphonyElixir.ControlPlane, name: unique_name(:durable_events), config_root: tmp_dir})

    assert {:ok, marker} = OperatorInterface.marker()
    assert {:ok, :committed} = SymphonyElixir.ControlPlane.transaction(control_plane, fn _ -> {:ok, :committed} end)
    assert {:ok, feed} = OperatorInterface.events(marker.host_id, marker.cursor)
    assert Enum.any?(feed.events, &(&1.kind == "snapshot_invalidated"))

    assert {:ok, marker} = OperatorInterface.marker()
    assert {:error, :rejected} = SymphonyElixir.ControlPlane.transaction(control_plane, fn _ -> {:error, :rejected} end)
    assert {:ok, feed} = OperatorInterface.events(marker.host_id, marker.cursor)
    refute Enum.any?(feed.events, &(&1.kind == "snapshot_invalidated"))
  end

  defp unique_name(suffix),
    do: Module.concat(__MODULE__, "#{suffix}_#{System.unique_integer([:positive])}")
end
