defmodule SymphonyElixir.OperatorRepositoryApiTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Plug.Conn
  alias SymphonyElixir.{LocalConfig, OperatorInterface, PathSafety}
  alias SymphonyElixir.TargetRegistry.Yaml

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

    def handle_call({:registry, registry}, _from, state),
      do: {:reply, :ok, put_in(state, [:snapshot, :registry], registry)}

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

  test "inspection returns a host error if the selected scheduler has stopped", context do
    GenServer.stop(context.scheduler)
    response = authorized_post(context, %{"action" => "inspect", "path" => context.manual})
    refute response.status == 200
    assert Jason.decode!(response.resp_body)["error"]["code"] == "host_unavailable"
    assert Process.alive?(context.interface)
  end

  test "repository inspection requires local authentication", context do
    response =
      post(build_conn(), "/api/v1/operator/repositories", %{
        "action" => "inspect",
        "path" => context.manual
      })

    assert response.status == 401
    assert json_response(response, 401)["error"]["code"] == "unauthorized"
  end

  test "repository inspection rejects malformed or authority-injecting requests", context do
    for request <- [
          %{"action" => "inspect", "path" => "relative"},
          %{"action" => "inspect", "path" => context.manual, "target_id" => 42},
          %{"action" => "inspect", "path" => context.manual, "registry_path" => "/tmp/other-targets.yml"},
          %{"action" => "inspect", "path" => context.manual, "config_root" => "/tmp/other-config"}
        ] do
      response = authorized_post(context, request)
      assert response.status == 400
      assert json_response(response, 400)["error"]["code"] == "invalid_repository_request"
    end
  end

  test "repository inspection returns readiness fields and keeps non-ready paths visible", context do
    File.write!(Path.join(context.manual, "README.md"), "Repository documentation\n")

    File.write!(
      Path.join(context.manual, "symphony.yml"),
      """
      version: 1
      project:
        slug: api-manual
        repository: https://github.com/example/api-manual
      docs:
        entrypoints:
          - README.md
      vcs:
        mode: git
        default_branch: main
      delivery:
        pr_target: main
      """
    )

    response = authorized_post(context, %{"action" => "inspect", "path" => context.manual})
    assert response.status == 200
    payload = json_response(response, 200)

    assert payload["path"] == canonical!(context.manual)
    assert payload["state"] == "needs_setup"
    assert payload["apply_allowed"] == false
    assert is_binary(payload["reason"])
    {:ok, identity} = OperatorInterface.credentials(context.interface)
    assert payload["host_id"] == identity.host_id
  end

  test "inspection fails closed when the selected host registry is unavailable", context do
    :ok = GenServer.call(context.scheduler, {:registry, %{path: Path.join(context.root, "host-targets.yml"), verified?: false}})

    response = authorized_post(context, %{"action" => "inspect", "path" => context.manual})

    assert response.status != 200
    assert Jason.decode!(response.resp_body)["error"]["code"] == "registry_unavailable"
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

  test "an expired queued inspection does not cancel the active branch scan", context do
    :ok = GenServer.call(context.scheduler, :block)
    started = authorized_post(context, %{"action" => "branches", "path" => context.manual}) |> json_response(202)
    expires_at = System.monotonic_time(:millisecond) - 1

    assert {:error, %{error: %{code: "operator_interface_unavailable"}}} =
             GenServer.call(
               context.interface,
               {:repositories, context.credential, %{"action" => "inspect", "path" => context.manual}, context.scheduler, expires_at}
             )

    active =
      authorized_post(context, %{"action" => "poll", "scan_id" => started["scan_id"]})
      |> json_response(200)

    assert active["status"] == "running"
    authorized_post(context, %{"action" => "cancel", "scan_id" => started["scan_id"]}) |> json_response(200)
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

  test "branch catalogs refresh on the selected host and retain deleted targets", context do
    repo = context.manual

    registry = %{
      "version" => 1,
      "host" => %{
        "id" => "branch-host",
        "state_root" => Path.join(context.root, "state"),
        "polling" => %{"interval_ms" => 30_000, "max_concurrent_target_polls" => 1},
        "capacity" => %{"max_concurrent_agents" => 4, "max_concurrent_startups" => 2, "max_concurrent_reviewers" => 1},
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 4},
        "tracker_connections" => %{
          "linear-main" => %{"kind" => "linear", "endpoint" => "https://api.linear.app/graphql", "api_key" => "$LINEAR_API_KEY"}
        },
        "runners" => %{
          "codex" => %{"kind" => "codex_app_server", "command" => ["codex", "app-server"], "max_concurrent_agents" => 4, "max_concurrent_startups" => 2}
        }
      },
      "targets" => %{}
    }

    File.write!(
      LocalConfig.target_registry_path(config_root: context.config_root),
      Yaml.encode(registry)
    )

    for args <- [
          ["init", "--initial-branch=main"],
          ["remote", "add", "origin", "https://github.com/example/api-manual.git"],
          ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial"],
          ["branch", "topic"]
        ] do
      {output, status} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
      assert status == 0, output
    end

    File.write!(Path.join(repo, "README.md"), "Repository documentation\n")

    File.write!(Path.join(repo, "symphony.yml"), """
    version: 1
    project:
      slug: api-manual
      repository: https://github.com/example/api-manual
    docs:
      entrypoints:
        - README.md
    vcs:
      mode: git
      default_branch: main
    delivery:
      pr_target: main
    """)

    request = %{"action" => "branches", "path" => repo, "configured_target" => "topic"}
    first = authorized_post(context, request) |> json_response(202) |> then(&await_scan(context, &1["scan_id"]))
    assert first["status"] == "completed"
    assert first["result"]["repository"] == canonical!(repo)
    assert first["result"]["apply_allowed"]
    assert Enum.any?(first["result"]["choices"], &(&1["value"] == "topic" and &1["configured"]))

    inherited =
      authorized_post(context, %{"action" => "branches", "path" => repo})
      |> json_response(202)
      |> then(&await_scan(context, &1["scan_id"]))

    assert inherited["result"]["selected"] == "main"
    assert inherited["result"]["apply_allowed"]

    changed =
      authorized_post(context, %{"action" => "branches", "path" => context.repositories})
      |> json_response(202)
      |> then(&await_scan(context, &1["scan_id"]))

    refute changed["result"]["apply_allowed"]

    old_after_path_change =
      authorized_post(context, %{"action" => "poll", "scan_id" => first["scan_id"]})
      |> json_response(200)

    assert old_after_path_change["result"]["reason"] == "repository_selection_changed"

    {_, 0} = System.cmd("git", ["branch", "-D", "topic"], cd: repo)
    second = authorized_post(context, request) |> json_response(202) |> then(&await_scan(context, &1["scan_id"]))
    refute second["scan_id"] == first["scan_id"]
    refute second["result"]["apply_allowed"]
    assert Enum.find(second["result"]["choices"], &(&1["value"] == "topic"))["status"] == "stale"
    old = authorized_post(context, %{"action" => "poll", "scan_id" => first["scan_id"]}) |> json_response(200)
    refute old["result"]["apply_allowed"]

    cancelled =
      authorized_post(context, %{"action" => "cancel", "scan_id" => second["scan_id"]})
      |> json_response(200)

    assert cancelled["status"] == "cancelled"
    refute cancelled["result"]["apply_allowed"]
  end

  test "branch discovery rejects client host authority and requires authentication", context do
    request = %{"action" => "branches", "path" => context.manual}
    assert post(build_conn(), "/api/v1/operator/repositories", request).status == 401
    assert authorized_post(context, Map.put(request, "command_runner", "injected")).status == 400
    assert authorized_post(context, Map.put(request, "path", "relative")).status == 400
  end

  test "changing repository cancels the previous branch discovery", context do
    :ok = GenServer.call(context.scheduler, :block)
    old = authorized_post(context, %{"action" => "branches", "path" => context.manual}) |> json_response(202)
    new = authorized_post(context, %{"action" => "branches", "path" => context.repositories}) |> json_response(202)
    previous = authorized_post(context, %{"action" => "poll", "scan_id" => old["scan_id"]}) |> json_response(200)
    assert previous["status"] == "cancelled"
    refute previous["result"]["apply_allowed"]
    assert new["scan_id"] != old["scan_id"]
    authorized_post(context, %{"action" => "cancel", "scan_id" => new["scan_id"]}) |> json_response(200)
    :ok = GenServer.call(context.scheduler, :release)
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
