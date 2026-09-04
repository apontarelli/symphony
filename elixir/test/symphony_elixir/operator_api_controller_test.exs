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
    previous = Application.get_env(:symphony_elixir, @endpoint, [])

    interface = Module.concat(__MODULE__, "Interface#{System.unique_integer([:positive])}")
    interface_pid = start_supervised!({OperatorInterface, name: interface, host_id: "host-http", install_log_handler: false})

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

    %{interface: interface, interface_pid: interface_pid}
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
