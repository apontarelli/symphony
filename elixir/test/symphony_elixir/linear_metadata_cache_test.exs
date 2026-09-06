defmodule SymphonyElixir.Linear.MetadataCacheTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.MetadataCache

  @metadata %{
    teams: [%{id: "team-1", name: "Platform", key: "PLAT"}],
    projects: [%{id: "project-1", name: "Symphony", slug_id: "symphony", team_ids: ["team-1"]}],
    states: [%{id: "state-1", name: "Started", type: "started", team_id: "team-1"}],
    labels: [%{id: "label-1", name: "Bug", team_id: "team-1"}]
  }
  @empty %{teams: [], projects: [], states: [], labels: []}

  test "returns loading asynchronously and distinguishes a successful empty catalog" do
    opts = [name: nil, fetch_fun: fn _ -> {:ok, @empty} end, env_fetcher: fn _ -> "fixture-key" end]
    {:ok, server} = start_supervised({MetadataCache, opts})

    connection = connection("loading", "$LINEAR_KEY")
    assert %{status: "loading", data: @empty, connection_revision: revision} = MetadataCache.get(connection, server: server)
    assert is_binary(revision) and byte_size(revision) == 64

    assert eventually(fn ->
             case MetadataCache.get(connection, server: server) do
               %{status: "empty", data: @empty} = result -> result
               _other -> false
             end
           end)
  end

  test "keeps an unexpired stale catalog fail-closed on an offline refresh" do
    {:ok, calls} = start_supervised({Agent, fn -> 0 end}, id: :calls)
    {:ok, clock} = start_supervised({Agent, fn -> 0 end}, id: :clock)

    fetch_fun = fn _connection ->
      Agent.get_and_update(calls, fn
        0 -> {{:ok, @metadata}, 1}
        _ -> {{:error, :offline}, 2}
      end)
    end

    {:ok, server} =
      start_supervised({MetadataCache, name: nil, fetch_fun: fetch_fun, now_fun: fn -> Agent.get(clock, & &1) end, fresh_ttl_ms: 10, stale_age_ms: 100, env_fetcher: fn _variable -> "fixture-key" end})

    connection = connection("offline", "$LINEAR_KEY")
    assert %{status: "loading"} = MetadataCache.get(connection, server: server)

    assert eventually(fn ->
             case MetadataCache.get(connection, server: server) do
               %{status: "current"} = result -> result
               _other -> false
             end
           end)

    Agent.update(clock, &(&1 + 11))

    assert %{status: "stale_cache", reason: "refreshing", data: @metadata} =
             MetadataCache.get(connection, server: server)

    assert eventually(fn ->
             case MetadataCache.get(connection, server: server) do
               %{status: "stale_cache", reason: "offline", data: @metadata} = result -> result
               _other -> false
             end
           end)
  end

  test "authentication failure erases a previously cached catalog" do
    {:ok, calls} = start_supervised({Agent, fn -> 0 end}, id: :calls)
    {:ok, clock} = start_supervised({Agent, fn -> 0 end}, id: :clock)

    fetch_fun = fn _connection ->
      Agent.get_and_update(calls, fn
        0 -> {{:ok, @metadata}, 1}
        _ -> {{:error, :authentication_failed}, 2}
      end)
    end

    {:ok, server} =
      start_supervised({MetadataCache, name: nil, fetch_fun: fetch_fun, now_fun: fn -> Agent.get(clock, & &1) end, fresh_ttl_ms: 10, stale_age_ms: 100, env_fetcher: fn _variable -> "fixture-key" end})

    connection = connection("authentication", "$LINEAR_KEY")

    assert eventually(fn ->
             case MetadataCache.get(connection, server: server) do
               %{status: "current"} = result -> result
               _other -> false
             end
           end)

    Agent.update(clock, &(&1 + 11))
    assert %{status: "stale_cache", reason: "refreshing"} = MetadataCache.get(connection, server: server)

    assert eventually(fn ->
             case MetadataCache.get(connection, server: server) do
               %{status: "authentication_failed", data: @empty} = result -> result
               _other -> false
             end
           end)
  end

  test "surfaces rate limiting without retaining empty or partial data" do
    opts = [name: nil, fetch_fun: fn _ -> {:error, :rate_limited} end, env_fetcher: fn _ -> "fixture-key" end]
    {:ok, server} = start_supervised({MetadataCache, opts})

    connection = connection("rate-limit", "$LINEAR_KEY")
    assert %{status: "loading", data: @empty} = MetadataCache.get(connection, server: server)

    assert eventually(fn ->
             case MetadataCache.get(connection, server: server) do
               %{status: "rate_limited", data: @empty} = result -> result
               _other -> false
             end
           end)
  end

  test "isolates revisions across endpoint, connection, braced reference, and key rotation" do
    {:ok, key} = start_supervised({Agent, fn -> "first-key" end}, id: :key)

    fetch_fun = fn connection ->
      id = connection["id"]
      {:ok, %{@metadata | teams: [%{id: id, name: id, key: String.upcase(id)}]}}
    end

    {:ok, server} =
      start_supervised({MetadataCache, name: nil, fetch_fun: fetch_fun, max_entries: 8, env_fetcher: fn _variable -> Agent.get(key, & &1) end})

    first = connection("one", "${LINEAR_KEY}")

    assert eventually(fn ->
             case MetadataCache.get(first, server: server) do
               %{status: "current"} = result -> result
               _other -> false
             end
           end)

    first_revision = MetadataCache.get(first, server: server).connection_revision
    Agent.update(key, fn _ -> "rotated-key" end)
    rotated = MetadataCache.get(first, server: server)
    assert rotated.status == "loading"
    assert rotated.connection_revision != first_revision

    assert eventually(fn ->
             case MetadataCache.get(first, server: server) do
               %{status: "current", data: %{teams: [%{id: "one"}]}} = result -> result
               _other -> false
             end
           end)

    second = connection("two", "${LINEAR_KEY}")

    assert eventually(fn ->
             case MetadataCache.get(second, server: server) do
               %{status: "current", data: %{teams: [%{id: "two"}]}} = result -> result
               _other -> false
             end
           end)

    endpoint_variant = put_in(first, ["policy", "endpoint"], "https://other.example/graphql")
    assert MetadataCache.get(endpoint_variant, server: server).status == "loading"
    refute MetadataCache.get(endpoint_variant, server: server).connection_revision == first_revision
  end

  test "bounds concurrent jobs and expires timed out work" do
    parent = self()

    fetch_fun = fn connection ->
      send(parent, {:fetch_started, connection["id"], self()})

      receive do
        :release -> {:ok, @metadata}
      end
    end

    opts = [name: nil, fetch_fun: fetch_fun, max_entries: 1, max_concurrent_jobs: 1, job_timeout_ms: 200]
    opts = Keyword.put(opts, :env_fetcher, fn _ -> "fixture-key" end)
    {:ok, server} = start_supervised({MetadataCache, opts})

    first = connection("bounded-one", "$LINEAR_KEY")
    second = connection("bounded-two", "$LINEAR_KEY")
    assert %{status: "loading"} = MetadataCache.get(first, server: server)
    assert_receive {:fetch_started, "bounded-one", worker}, 1_000
    assert %{status: "unavailable", reason: "capacity"} = MetadataCache.get(second, server: server)
    send(worker, :release)

    assert eventually(fn ->
             case MetadataCache.get(first, server: server) do
               %{status: "current"} = result -> result
               _other -> false
             end
           end)

    assert eventually(fn ->
             case MetadataCache.get(second, server: server) do
               %{status: "offline", data: @empty} = result -> result
               _other -> false
             end
           end)
  end

  test "missing or unsupported secret references fail closed" do
    opts = [name: nil, fetch_fun: fn _ -> raise "must not be called" end, env_fetcher: fn _ -> nil end]
    {:ok, server} = start_supervised({MetadataCache, opts})

    assert %{status: "authentication_failed", data: @empty} =
             MetadataCache.get(connection("missing", "${LINEAR_KEY}"), server: server)

    assert %{status: "authentication_failed", data: @empty} =
             MetadataCache.get(connection("unsupported", "secret://vault/path"), server: server)

    assert %{status: "authentication_failed", data: @empty} = MetadataCache.get(%{}, server: server)
  end

  test "expires stale data and recovers from failure after the retry cooldown" do
    clock = start_supervised!({Agent, fn -> 0 end}, id: :clock)
    remote = start_supervised!({Agent, fn -> {:ok, @metadata} end}, id: :remote)

    server =
      start_supervised!(
        {MetadataCache,
         name: nil,
         fresh_ttl_ms: 10,
         stale_age_ms: 20,
         failure_retry_ms: 10,
         now_fun: fn -> Agent.get(clock, & &1) end,
         fetch_fun: fn _ -> Agent.get(remote, & &1) end,
         env_fetcher: fn _ -> "fixture-key" end}
      )

    connection = connection("recovery", "$LINEAR_KEY")
    assert eventually(fn -> MetadataCache.get(connection, server: server).status == "current" end)
    Agent.update(remote, fn _ -> {:error, :offline} end)
    Agent.update(clock, fn _ -> 11 end)
    assert eventually(fn -> MetadataCache.get(connection, server: server).reason == "offline" end)
    assert %{status: "stale_cache", data: @metadata} = MetadataCache.get(connection, server: server)
    Agent.update(clock, fn _ -> 31 end)
    assert %{data: @empty} = MetadataCache.get(connection, server: server)
    assert eventually(fn -> MetadataCache.get(connection, server: server).status == "offline" end)
    Agent.update(remote, fn _ -> {:ok, @metadata} end)
    Agent.update(clock, fn _ -> 41 end)
    assert eventually(fn -> MetadataCache.get(connection, server: server).status == "current" end)
    assert %{data: @metadata} = MetadataCache.get(connection, server: server)
  end

  test "a nullable refresh option preserves the available catalog" do
    opts = [name: nil, fetch_fun: fn _ -> {:ok, @metadata} end, env_fetcher: fn _ -> "fixture-key" end]
    server = start_supervised!({MetadataCache, opts})
    connection = connection("nullable-refresh", "$LINEAR_KEY")
    assert eventually(fn -> MetadataCache.get(connection, server: server).status == "current" end)

    assert %{status: "current", data: @metadata} = MetadataCache.get(connection, server: server, refresh: nil)
    assert %{status: "current", data: @metadata} = MetadataCache.get(connection, server: server)
  end

  test "forces a refresh while serving the previous catalog" do
    {:ok, calls} = start_supervised({Agent, fn -> 0 end}, id: :refresh_calls)

    refreshed = %{
      @metadata
      | teams: [%{id: "team-2", name: "Operations", key: "OPS"}]
    }

    fetch_fun = fn _connection ->
      Agent.get_and_update(calls, fn
        0 -> {{:ok, @metadata}, 1}
        _ -> {{:ok, refreshed}, 2}
      end)
    end

    server =
      start_supervised!({MetadataCache, name: nil, fetch_fun: fetch_fun, env_fetcher: fn _variable -> "fixture-key" end})

    connection = connection("forced-refresh", "$LINEAR_KEY")
    assert eventually(fn -> MetadataCache.get(connection, server: server).data == @metadata end)

    assert %{status: "stale_cache", reason: "refreshing", data: @metadata} =
             MetadataCache.get(connection, server: server, refresh: true)

    assert eventually(fn ->
             case MetadataCache.get(connection, server: server) do
               %{status: "current", data: ^refreshed} -> true
               _other -> false
             end
           end)
  end

  test "evicts idle entries but retains entries with running jobs" do
    parent = self()

    fetch_fun = fn connection ->
      id = connection["id"]
      send(parent, {:cache_fetch_started, id, self()})

      receive do
        {:release, ^id} -> {:ok, @metadata}
      end
    end

    opts = [name: nil, fetch_fun: fetch_fun, max_entries: 2, max_concurrent_jobs: 2]
    server = start_supervised!({MetadataCache, Keyword.put(opts, :env_fetcher, fn _ -> "fixture-key" end)})

    first = connection("eviction-one", "$LINEAR_KEY")
    second = connection("eviction-two", "$LINEAR_KEY")
    third = connection("eviction-three", "$LINEAR_KEY")

    assert %{status: "loading"} = MetadataCache.get(first, server: server)
    assert_receive {:cache_fetch_started, "eviction-one", first_worker}, 1_000
    assert %{status: "loading"} = MetadataCache.get(second, server: server)
    assert_receive {:cache_fetch_started, "eviction-two", second_worker}, 1_000

    send(first_worker, {:release, "eviction-one"})

    assert eventually(fn -> MetadataCache.get(first, server: server).status == "current" end)

    assert %{status: "loading"} = MetadataCache.get(third, server: server)
    assert_receive {:cache_fetch_started, "eviction-three", third_worker}, 1_000

    assert %{status: "unavailable", reason: "capacity"} = MetadataCache.get(first, server: server)

    send(second_worker, {:release, "eviction-two"})
    send(third_worker, {:release, "eviction-three"})

    assert eventually(fn -> MetadataCache.get(second, server: server).status == "current" end)
    assert eventually(fn -> MetadataCache.get(third, server: server).status == "current" end)

    assert %{status: "loading"} = MetadataCache.get(first, server: server)
    assert_receive {:cache_fetch_started, "eviction-one", retry_worker}, 1_000
    send(retry_worker, {:release, "eviction-one"})
    assert eventually(fn -> MetadataCache.get(first, server: server).status == "current" end)
  end

  test "stale catalogs report job capacity without hiding usable data" do
    parent = self()
    clock = start_supervised!({Agent, fn -> 0 end}, id: :stale_capacity_clock)

    fetch_fun = fn connection ->
      case connection["id"] do
        "stale-capacity-one" ->
          {:ok, @metadata}

        "stale-capacity-two" ->
          send(parent, {:stale_capacity_fetch_started, self()})

          receive do
            :release -> {:ok, @metadata}
          end
      end
    end

    server =
      start_supervised!(
        {MetadataCache,
         name: nil, fetch_fun: fetch_fun, max_entries: 2, max_concurrent_jobs: 1, fresh_ttl_ms: 10, now_fun: fn -> Agent.get(clock, & &1) end, env_fetcher: fn _variable -> "fixture-key" end}
      )

    first = connection("stale-capacity-one", "$LINEAR_KEY")
    second = connection("stale-capacity-two", "$LINEAR_KEY")

    assert eventually(fn -> MetadataCache.get(first, server: server).status == "current" end)
    Agent.update(clock, &(&1 + 11))

    assert %{status: "loading"} = MetadataCache.get(second, server: server)
    assert_receive {:stale_capacity_fetch_started, second_worker}, 1_000

    assert %{status: "stale_cache", reason: "capacity", data: @metadata} =
             MetadataCache.get(first, server: server)

    send(second_worker, :release)
    assert eventually(fn -> MetadataCache.get(second, server: server).status == "current" end)
  end

  test "reports running-job capacity without dropping a waiting connection" do
    parent = self()

    fetch_fun = fn connection ->
      id = connection["id"]
      send(parent, {:capacity_fetch_started, id, self()})

      receive do
        {:release, ^id} -> {:ok, @metadata}
      end
    end

    opts = [name: nil, fetch_fun: fetch_fun, max_entries: 2, max_concurrent_jobs: 1]
    server = start_supervised!({MetadataCache, Keyword.put(opts, :env_fetcher, fn _ -> "fixture-key" end)})

    first = connection("job-capacity-one", "$LINEAR_KEY")
    second = connection("job-capacity-two", "$LINEAR_KEY")

    assert %{status: "loading"} = MetadataCache.get(first, server: server)
    assert_receive {:capacity_fetch_started, "job-capacity-one", first_worker}, 1_000
    assert %{status: "unavailable", reason: "capacity"} = MetadataCache.get(second, server: server)

    send(first_worker, {:release, "job-capacity-one"})
    assert eventually(fn -> MetadataCache.get(first, server: server).status == "current" end)

    assert %{status: "loading"} = MetadataCache.get(second, server: server)
    assert_receive {:capacity_fetch_started, "job-capacity-two", second_worker}, 1_000
    send(second_worker, {:release, "job-capacity-two"})
    assert eventually(fn -> MetadataCache.get(second, server: server).status == "current" end)
  end

  test "deadline cleanup frees a job slot for retry" do
    parent = self()
    clock = start_supervised!({Agent, fn -> 0 end}, id: :deadline_clock)
    calls = start_supervised!({Agent, fn -> 0 end}, id: :deadline_calls)

    fetch_fun = fn _connection ->
      attempt = Agent.get_and_update(calls, fn count -> {count, count + 1} end)

      if attempt == 0 do
        send(parent, {:deadline_fetch_started, self()})

        receive do
          :release -> {:ok, @metadata}
        end
      else
        {:ok, @metadata}
      end
    end

    server =
      start_supervised!(
        {MetadataCache,
         name: nil, fetch_fun: fetch_fun, max_concurrent_jobs: 1, job_timeout_ms: 20, failure_retry_ms: 10, now_fun: fn -> Agent.get(clock, & &1) end, env_fetcher: fn _variable -> "fixture-key" end}
      )

    connection = connection("deadline", "$LINEAR_KEY")
    assert %{status: "loading"} = MetadataCache.get(connection, server: server)
    assert_receive {:deadline_fetch_started, _worker}, 1_000
    assert eventually(fn -> MetadataCache.get(connection, server: server).status == "offline" end)

    Agent.update(clock, &(&1 + 10))
    assert %{status: "loading"} = MetadataCache.get(connection, server: server)
    assert eventually(fn -> MetadataCache.get(connection, server: server).status == "current" end)
  end

  test "crashed fetch jobs are cleaned up and can recover" do
    parent = self()
    clock = start_supervised!({Agent, fn -> 0 end}, id: :crash_clock)
    calls = start_supervised!({Agent, fn -> 0 end}, id: :crash_calls)

    fetch_fun = fn _connection ->
      attempt = Agent.get_and_update(calls, fn count -> {count, count + 1} end)

      if attempt == 0 do
        send(parent, {:crash_fetch_started, self()})
        Process.exit(self(), :kill)
      else
        {:ok, @metadata}
      end
    end

    server =
      start_supervised!(
        {MetadataCache, name: nil, fetch_fun: fetch_fun, max_concurrent_jobs: 1, failure_retry_ms: 10, now_fun: fn -> Agent.get(clock, & &1) end, env_fetcher: fn _variable -> "fixture-key" end}
      )

    connection = connection("crash", "$LINEAR_KEY")
    assert %{status: "loading"} = MetadataCache.get(connection, server: server)
    assert_receive {:crash_fetch_started, _worker}, 1_000
    assert eventually(fn -> MetadataCache.get(connection, server: server).status == "offline" end)

    Agent.update(clock, &(&1 + 10))
    assert %{status: "loading"} = MetadataCache.get(connection, server: server)
    assert eventually(fn -> MetadataCache.get(connection, server: server).status == "current" end)
  end

  test "fails closed when the cache service is unavailable" do
    connection = connection("service-unavailable", "$LINEAR_KEY")

    result =
      MetadataCache.get(connection,
        server: :metadata_cache_service_unavailable,
        env_fetcher: fn _variable -> "fixture-key" end
      )

    assert %{
             status: "unavailable",
             reason: "service_unavailable",
             data: @empty,
             connection_revision: revision
           } = result

    assert is_binary(revision) and byte_size(revision) == 64
    refute inspect(result) =~ "fixture-key"
  end

  test "credential resolver failures become authentication failures" do
    opts = [
      name: nil,
      fetch_fun: fn _ -> raise "transport must not run" end,
      env_fetcher: fn _ -> raise "resolver failed" end
    ]

    server = start_supervised!({MetadataCache, opts})
    result = MetadataCache.get(connection("resolver-failure", "$LINEAR_KEY"), server: server)
    assert %{status: "authentication_failed", data: @empty} = result

    assert %{status: "authentication_failed", data: @empty} =
             MetadataCache.get(connection("resolver-exit", "$LINEAR_KEY"), server: server, env_fetcher: fn _ -> throw(:missing) end)
  end

  test "stopping the cache cancels outstanding metadata fetches" do
    parent = self()

    fetch = fn _ ->
      send(parent, {:blocking_fetch, self()})

      receive do
        :release -> {:ok, @empty}
      end
    end

    opts = [name: nil, fetch_fun: fetch, env_fetcher: fn _ -> "fixture-key" end]
    server = start_supervised!({MetadataCache, opts}, id: :shutdown_cache)
    assert %{status: "loading"} = MetadataCache.get(connection("shutdown", "$LINEAR_KEY"), server: server)
    assert_receive {:blocking_fetch, worker}
    monitor = Process.monitor(worker)
    stop_supervised!(:shutdown_cache)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
  end

  test "delayed cache scheduling does not let obsolete completion or timeout events replace the result" do
    parent = self()

    fetch = fn _ ->
      send(parent, {:pending_fetch, self()})

      receive do
        :release -> {:ok, @metadata}
      end
    end

    for outcome <- [:completed_first, :expired_first] do
      opts = [name: nil, fetch_fun: fetch, job_timeout_ms: 100, env_fetcher: fn _ -> "fixture-key" end]
      server = start_supervised!({MetadataCache, opts}, id: outcome)
      source = connection("delayed-result", "$LINEAR_KEY")
      assert %{status: "loading"} = MetadataCache.get(source, server: server)
      assert_receive {:pending_fetch, worker}
      monitor = Process.monitor(worker)
      :ok = :sys.suspend(server)

      if outcome == :expired_first, do: Process.sleep(150)
      send(worker, :release)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
      if outcome == :completed_first, do: Process.sleep(150)
      :ok = :sys.resume(server)

      result = MetadataCache.get(source, server: server)

      if outcome == :completed_first do
        assert %{status: "current", data: @metadata} = result
      else
        assert %{status: "offline", data: @empty} = result
      end

      stop_supervised!(outcome)
    end
  end

  test "the cache and metadata transport use one credential snapshot across key rotation" do
    parent = self()
    key = start_supervised!({Agent, fn -> "first-key" end})

    request = fn _endpoint, payload, headers ->
      if payload["operationName"] == "SymphonyMetadataTeams" do
        send(parent, {:transport_started, self()})

        receive do
          :continue -> :ok
        end
      end

      if {"Authorization", "first-key"} in headers do
        root =
          %{
            "SymphonyMetadataTeams" => "teams",
            "SymphonyMetadataProjects" => "projects",
            "SymphonyMetadataStates" => "workflowStates",
            "SymphonyMetadataLabels" => "issueLabels"
          }[payload["operationName"]]

        {:ok, %{status: 200, body: %{"data" => %{root => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}}}
      else
        {:ok, %{status: 401, body: %{}}}
      end
    end

    opts = [name: nil, fetch_opts: [request_fun: request], env_fetcher: fn _ -> {:ok, Agent.get(key, & &1)} end]
    server = start_supervised!({MetadataCache, opts})
    source = connection("transport", "$LINEAR_KEY")
    assert %{status: "loading", connection_revision: initial_revision} = MetadataCache.get(source, server: server)
    assert_receive {:transport_started, worker}
    Agent.update(key, fn _ -> "rotated-key" end)
    send(worker, :continue)

    # Reading with the old credential selects the original in-flight revision.
    assert eventually(fn ->
             MetadataCache.get(source, server: server, env_fetcher: fn _ -> "first-key" end).status == "empty"
           end)

    assert %{status: "loading", connection_revision: rotated_revision} = MetadataCache.get(source, server: server)
    refute rotated_revision == initial_revision
    assert_receive {:transport_started, rotated_worker}
    send(rotated_worker, :continue)
    assert eventually(fn -> MetadataCache.get(source, server: server).status == "authentication_failed" end)
  end

  test "unexpected fetch failures do not expose credentials in results or logs" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for {id, fetch} <- [
              {:raised, fn _ -> raise "private-api-key" end},
              {:thrown, fn _ -> throw("private-api-key") end}
            ] do
          opts = [name: nil, fetch_fun: fetch, env_fetcher: fn _ -> "fixture-key" end]
          server = start_supervised!({MetadataCache, opts}, id: id)
          source = connection("failed-fetch", "$LINEAR_KEY")
          assert eventually(fn -> MetadataCache.get(source, server: server).status == "offline" end)
          refute inspect(MetadataCache.get(source, server: server)) =~ "private-api-key"
        end
      end)

    refute log =~ "private-api-key"
  end

  test "oversized upstream catalogs stay unavailable instead of exposing a partial catalog" do
    request = fn _endpoint, _payload, _headers ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "teams" => %{
               "nodes" => [%{"id" => "one", "key" => "ONE", "name" => "One"}, %{"id" => "two", "key" => "TWO", "name" => "Two"}],
               "pageInfo" => %{"hasNextPage" => false}
             }
           }
         }
       }}
    end

    opts = [name: nil, fetch_opts: [request_fun: request, max_entries: 1], env_fetcher: fn _ -> "fixture-key" end]
    server = start_supervised!({MetadataCache, opts})
    source = connection("oversized", "$LINEAR_KEY")
    assert eventually(fn -> MetadataCache.get(source, server: server).status == "unavailable" end)
    assert %{reason: "catalog_limit", data: @empty} = MetadataCache.get(source, server: server)
  end

  defp connection(id, api_key) do
    %{
      "id" => id,
      "policy" => %{
        "kind" => "linear",
        "endpoint" => "https://api.linear.app/graphql",
        "api_key" => api_key
      }
    }
  end

  defp eventually(fun, attempts \\ 40)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      false ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  defp eventually(_fun, 0), do: false
end
