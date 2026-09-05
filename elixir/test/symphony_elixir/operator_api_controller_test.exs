defmodule SymphonyElixir.OperatorApiControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias SymphonyElixir.OperatorInterface

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
