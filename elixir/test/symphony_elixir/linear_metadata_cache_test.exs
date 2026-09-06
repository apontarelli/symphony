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
