defmodule SymphonyElixir.OperatorRepositoryApiTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Plug.Conn
  alias SymphonyElixir.{LocalConfig, OperatorInterface, PathSafety}

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticScheduler do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)

    @impl true
    def init(snapshot), do: {:ok, %{snapshot: snapshot, blocked?: false, waiter: nil}}

    @impl true
    def handle_call(:snapshot, from, %{blocked?: true, waiter: nil} = state),
      do: {:noreply, %{state | waiter: from}}

    def handle_call(:snapshot, _from, %{snapshot: snapshot} = state), do: {:reply, snapshot, state}

    def handle_call(:block, _from, state), do: {:reply, :ok, %{state | blocked?: true}}

    def handle_call(:release, _from, %{waiter: nil} = state), do: {:reply, :ok, %{state | blocked?: false}}

    def handle_call(:release, _from, %{snapshot: snapshot, waiter: waiter} = state) do
      GenServer.reply(waiter, snapshot)
      {:reply, :ok, %{state | blocked?: false, waiter: nil}}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "operator-repository-api-#{System.unique_integer([:positive])}")
    config_root = Path.join(root, "config")
    repositories = Path.join(root, "repositories")
    File.mkdir_p!(Path.join(repositories, "alpha"))
    File.mkdir_p!(Path.join(repositories, "beta"))
    manual = Path.join(root, "manual")
    File.mkdir_p!(manual)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, _path} =
      LocalConfig.write(
        %{
          "repository_browser" => %{
            "roots" => [repositories],
            "max_depth" => 2,
            "max_results" => 100,
            "max_entries" => 100_000,
            "timeout_ms" => 5_000
          }
        },
        config_root: config_root
      )

    scheduler =
      start_supervised!(
        {StaticScheduler,
         %{
           registry: %{}
         }}
      )

    interface_name = Module.concat(__MODULE__, "Interface#{System.unique_integer([:positive])}")
    interface_opts = [name: interface_name, config_root: config_root, install_log_handler: false]
    interface = start_supervised!({OperatorInterface, interface_opts})
    {:ok, %{token_path: token_path}} = OperatorInterface.credentials(interface)
    credential = File.read!(token_path)

    previous = Application.get_env(:symphony_elixir, @endpoint, [])

    Application.put_env(
      :symphony_elixir,
      @endpoint,
      Keyword.merge(previous,
        server: false,
        secret_key_base: String.duplicate("s", 64),
        operator_interface: interface,
        host_scheduler: scheduler
      )
    )

    start_supervised!({@endpoint, []})
    on_exit(fn -> Application.put_env(:symphony_elixir, @endpoint, previous) end)

    %{
      credential: credential,
      interface: interface,
      root: root,
      config_root: config_root,
      repositories: repositories,
      manual: manual,
      scheduler: scheduler
    }
  end

  test "repository discovery requires local authentication", _context do
    response = post(build_conn(), "/api/v1/operator/repositories", %{"action" => "recent"})
    assert response.status == 401
    assert json_response(response, 401)["error"]["code"] == "unauthorized"
  end

  test "start and poll expose incremental candidates and a bounded terminal result", context do
    response = authorized_post(context, %{"action" => "browse", "path" => context.repositories})
    assert response.status == 202
    started = json_response(response, 202)
    assert is_binary(started["scan_id"])

    terminal = await_scan(context, started["scan_id"])
    assert terminal["status"] == "completed"

    assert Enum.map(terminal["result"]["candidates"], & &1["path"]) |> Enum.sort() ==
             [Path.join(context.repositories, "alpha"), Path.join(context.repositories, "beta")]
             |> Enum.map(&canonical!/1)
             |> Enum.sort()

    assert Enum.any?(terminal["events"], fn event ->
             event["type"] == "candidate" and is_binary(event["candidate"]["path"])
           end)

    assert terminal["result"]["visited"] == 3
  end

  test "cancellation retains a terminal bounded scan state", context do
    :ok = GenServer.call(context.scheduler, :block)
    response = authorized_post(context, %{"action" => "scan", "path" => context.repositories})
    started = json_response(response, 202)

    cancelled =
      context
      |> authorized_post(%{"action" => "cancel", "scan_id" => started["scan_id"]})
      |> json_response(200)

    assert cancelled["status"] == "cancelled"
    assert cancelled["result"]["status"] == "cancelled"
    assert is_nil(cancelled["result"]["visited"])
    assert :ok = GenServer.call(context.scheduler, :release)
  end

  test "action-specific validation rejects malformed requests before replacing an active scan", context do
    :ok = GenServer.call(context.scheduler, :block)
    started = authorized_post(context, %{"action" => "scan", "path" => context.repositories}) |> json_response(202)

    for request <- [
          %{"action" => "recent", "path" => context.repositories},
          %{"action" => "browse", "path" => "relative"},
          %{"action" => "manual", "path" => ""},
          %{"action" => "scan", "path" => "relative"}
        ] do
      response = authorized_post(context, request)
      assert response.status == 400
      assert json_response(response, 400)["error"]["code"] == "invalid_repository_request"
    end

    active = authorized_post(context, %{"action" => "poll", "scan_id" => started["scan_id"]}) |> json_response(200)
    assert active["status"] == "running"

    _cancelled =
      authorized_post(context, %{"action" => "cancel", "scan_id" => started["scan_id"]})
      |> json_response(200)

    assert :ok = GenServer.call(context.scheduler, :release)
  end

  test "poll rejects a cursor ahead of the repository job", context do
    :ok = GenServer.call(context.scheduler, :block)
    started = authorized_post(context, %{"action" => "scan", "path" => context.repositories}) |> json_response(202)

    response =
      authorized_post(context, %{"action" => "poll", "scan_id" => started["scan_id"], "after" => 1})

    assert response.status == 400
    assert json_response(response, 400)["error"]["code"] == "invalid_repository_request"

    _cancelled =
      authorized_post(context, %{"action" => "cancel", "scan_id" => started["scan_id"]})
      |> json_response(200)

    assert :ok = GenServer.call(context.scheduler, :release)
  end

  test "forced timeout reports an unavailable visited count", context do
    :ok = GenServer.call(context.scheduler, :block)
    started = authorized_post(context, %{"action" => "scan", "path" => context.repositories}) |> json_response(202)
    send(context.interface, {:repository_timeout, started["scan_id"]})

    timed_out = await_scan(context, started["scan_id"])
    assert timed_out["status"] == "timeout"
    assert timed_out["result"]["status"] == "timeout"
    assert is_nil(timed_out["result"]["visited"])

    assert :ok = GenServer.call(context.scheduler, :release)
  end

  test "an expired queued repository request does not cancel the active scan", context do
    :ok = GenServer.call(context.scheduler, :block)
    started = authorized_post(context, %{"action" => "scan", "path" => context.repositories}) |> json_response(202)
    :ok = :sys.suspend(context.interface)
    request = %{"action" => "cancel", "scan_id" => started["scan_id"]}
    expires_at = System.monotonic_time(:millisecond) + 1

    assert catch_exit(
             GenServer.call(
               context.interface,
               {:repositories, context.credential, request, context.scheduler, expires_at},
               20
             )
           )

    assert :ok = :sys.resume(context.interface)

    active = authorized_post(context, %{"action" => "poll", "scan_id" => started["scan_id"]}) |> json_response(200)
    assert active["status"] == "running"

    _cancelled =
      authorized_post(context, %{"action" => "cancel", "scan_id" => started["scan_id"]})
      |> json_response(200)

    assert :ok = GenServer.call(context.scheduler, :release)
  end

  test "a request that expires during authentication cannot cancel a scan", context do
    :ok = GenServer.call(context.scheduler, :block)
    started = authorized_post(context, %{"action" => "scan", "path" => context.repositories}) |> json_response(202)
    session = :sys.get_state(context.interface).session
    :ok = :sys.suspend(session)
    expires_at = System.monotonic_time(:millisecond) + 1_000
    request = %{"action" => "cancel", "scan_id" => started["scan_id"]}

    task =
      Task.async(fn ->
        GenServer.call(context.interface, {:repositories, context.credential, request, context.scheduler, expires_at})
      end)

    try do
      assert SymphonyElixir.TestSupport.eventually(fn ->
               {:message_queue_len, queued} = Process.info(session, :message_queue_len)
               queued > 0
             end)

      Process.sleep(max(expires_at - System.monotonic_time(:millisecond) + 10, 0))
    after
      :sys.resume(session)
    end

    assert {:error, %{error: %{code: "operator_interface_unavailable"}}} = Task.await(task)
    active = authorized_post(context, %{"action" => "poll", "scan_id" => started["scan_id"]}) |> json_response(200)
    assert active["status"] == "running"
    authorized_post(context, %{"action" => "cancel", "scan_id" => started["scan_id"]}) |> json_response(200)
    assert :ok = GenServer.call(context.scheduler, :release)
  end

  test "refresh starts a fresh scan and manual paths work outside configured roots", context do
    first =
      authorized_post(context, %{"action" => "scan", "path" => context.repositories})
      |> json_response(202)
      |> then(&await_scan(context, &1["scan_id"]))

    gamma = Path.join(context.repositories, "gamma")
    File.mkdir_p!(gamma)

    second =
      authorized_post(context, %{"action" => "scan", "path" => context.repositories})
      |> json_response(202)
      |> then(&await_scan(context, &1["scan_id"]))

    assert second["scan_id"] != first["scan_id"]
    assert Enum.any?(second["result"]["candidates"], &(&1["path"] == canonical!(gamma)))

    manual =
      authorized_post(context, %{"action" => "manual", "path" => context.manual})
      |> json_response(202)
      |> then(&await_scan(context, &1["scan_id"]))

    assert manual["status"] == "completed"
    assert manual["result"]["candidates"] == [%{"path" => canonical!(context.manual), "kind" => "directory"}]
  end

  defp authorized_post(context, body) do
    build_conn()
    |> Conn.put_req_header("authorization", "Bearer " <> context.credential)
    |> post("/api/v1/operator/repositories", body)
  end

  defp await_scan(context, scan_id, after_cursor \\ 0, events \\ [], attempts \\ 100)

  defp await_scan(_context, _scan_id, _after_cursor, _events, 0),
    do: flunk("repository scan did not finish")

  defp await_scan(context, scan_id, after_cursor, events, attempts) do
    response =
      authorized_post(context, %{"action" => "poll", "scan_id" => scan_id, "after" => after_cursor})
      |> json_response(200)

    events = events ++ response["events"]

    if response["status"] == "running" do
      Process.sleep(10)
      await_scan(context, scan_id, response["next_cursor"], events, attempts - 1)
    else
      Map.put(response, "events", events)
    end
  end

  defp canonical!(path) do
    {:ok, canonical} = PathSafety.canonicalize(path)
    canonical
  end
end
