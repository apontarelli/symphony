defmodule SymphonyElixir.Linear.MetadataCache do
  @moduledoc """
  Bounded, asynchronous cache for the read-only Linear metadata catalogs.

  A cache entry is keyed by a SHA-256 revision of the complete connection and the
  resolved environment secret. Secrets and fetch failures are kept out of the
  entry state; they only exist in the short-lived fetch process.
  """

  use GenServer

  alias SymphonyElixir.Linear.Metadata

  @default_max_entries 64
  @default_max_concurrent_jobs 4
  @default_job_timeout_ms 30_000
  @default_fresh_ttl_ms 300_000
  @default_stale_age_ms 900_000
  @default_call_timeout_ms 1_000
  @metadata_keys [:teams, :projects, :states, :labels]
  @empty_metadata %{teams: [], projects: [], states: [], labels: []}
  @known_errors [:authentication_failed, :rate_limited, :offline, :invalid_response, :catalog_limit]

  defmodule State do
    @moduledoc false
    defstruct [
      :name,
      :fetch_fun,
      :fetch_fun_arity,
      :fetch_opts,
      :env_fetcher,
      :now_fun,
      :max_entries,
      :max_concurrent_jobs,
      :job_timeout_ms,
      :fresh_ttl_ms,
      :stale_age_ms,
      :failure_retry_ms,
      entries: %{},
      jobs: %{}
    ]
  end

  @type metadata :: %{
          teams: [map()],
          projects: [map()],
          states: [map()],
          labels: [map()]
        }

  @type result :: %{
          status: String.t(),
          reason: String.t() | nil,
          data: metadata(),
          connection_revision: String.t()
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Return the current view of a connection's catalog and, when needed, start a
  bounded asynchronous refresh. The call itself only performs in-memory work.
  """
  @spec get(map(), keyword()) :: result()
  def get(connection, opts \\ [])

  @spec get(map(), keyword()) :: result()
  def get(connection, opts) when is_map(connection) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    request_opts = Keyword.take(opts, [:env_fetcher, :fetch_opts, :refresh])
    timeout = valid_timeout(Keyword.get(opts, :call_timeout, @default_call_timeout_ms))

    try do
      GenServer.call(server, {:get, connection, request_opts}, timeout)
    catch
      :exit, _reason -> unavailable_result(connection, opts)
    end
  end

  def get(connection, _opts) when is_map(connection), do: unavailable_result(connection, [])
  def get(_connection, opts), do: unavailable_result(%{}, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    env_fetcher =
      case Keyword.get(opts, :env_fetcher, &System.get_env/1) do
        fun when is_function(fun, 1) -> fun
        _other -> &System.get_env/1
      end

    {fetch_fun, fetch_fun_arity} = normalize_fetch_fun(Keyword.get(opts, :fetch_fun))

    {:ok,
     %State{
       name: Keyword.get(opts, :name, __MODULE__),
       fetch_fun: fetch_fun,
       fetch_fun_arity: fetch_fun_arity,
       fetch_opts: normalize_fetch_opts(Keyword.get(opts, :fetch_opts, [])),
       env_fetcher: env_fetcher,
       now_fun: normalize_now_fun(Keyword.get(opts, :now_fun)),
       max_entries: bounded_option(opts, :max_entries, @default_max_entries, 1),
       max_concurrent_jobs: bounded_option(opts, :max_concurrent_jobs, @default_max_concurrent_jobs, 0),
       job_timeout_ms: bounded_option(opts, :job_timeout_ms, @default_job_timeout_ms, 1),
       fresh_ttl_ms: bounded_option(opts, :fresh_ttl_ms, @default_fresh_ttl_ms, 0),
       stale_age_ms:
         bounded_option(
           opts,
           :stale_age_ms,
           @default_stale_age_ms,
           0
         ),
       failure_retry_ms:
         bounded_option(
           opts,
           :failure_retry_ms,
           5_000,
           0
         )
     }}
  end

  @impl true
  def handle_call({:get, connection, request_opts}, _from, state) do
    now = now(state)
    env_fetcher = Keyword.get(request_opts, :env_fetcher, state.env_fetcher)
    env_fetcher = if is_function(env_fetcher, 1), do: env_fetcher, else: state.env_fetcher
    identity = connection_identity(connection, env_fetcher)

    {state, entry, stored?} = ensure_entry(state, identity.revision, now)
    entry = expire_entry(entry, now, state)
    state = if stored?, do: put_entry(state, identity.revision, entry), else: state

    force_refresh? = Keyword.get(request_opts, :refresh, false) == true

    cond do
      not stored? ->
        {:reply, response_for(entry, identity.revision, now, state, :capacity), state}

      identity.secret_status != :ok ->
        entry = authenticate_failure(entry, now)
        state = put_entry(state, identity.revision, entry)
        {:reply, response_for(entry, identity.revision, now, state), state}

      should_schedule?(entry, now, state, force_refresh?) ->
        case schedule_job(state, identity, connection, env_fetcher, request_opts, now) do
          {:ok, state} ->
            entry = Map.fetch!(state.entries, identity.revision)
            {:reply, response_for(entry, identity.revision, now, state), state}

          {:error, :capacity, state} ->
            {:reply, response_for(entry, identity.revision, now, state, :capacity), state}
        end

      true ->
        {:reply, response_for(entry, identity.revision, now, state), state}
    end
  end

  @impl true
  def handle_info({:metadata_cache_result, ref, result}, state) do
    {:noreply, settle_job(state, ref, result)}
  end

  @impl true
  def handle_info({:metadata_cache_timeout, ref}, state) do
    case Map.get(state.jobs, ref) do
      %{pid: pid} ->
        Process.exit(pid, :kill)
        {:noreply, settle_job(state, ref, {:error, :offline})}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    case Enum.find(state.jobs, fn {_job_ref, job} -> job.pid == pid end) do
      {job_ref, _job} -> {:noreply, settle_job(state, job_ref, {:error, :offline})}
      nil -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Enum.find(state.jobs, fn {_job_ref, job} -> job.monitor_ref == monitor_ref end) do
      {job_ref, _job} -> {:noreply, settle_job(state, job_ref, {:error, :offline})}
      nil -> {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.jobs, fn {_ref, %{pid: pid}} ->
      Process.exit(pid, :kill)
    end)

    :ok
  end

  defp normalize_fetch_fun(nil), do: {:default, 2}
  defp normalize_fetch_fun(fun) when is_function(fun, 1), do: {fun, 1}
  defp normalize_fetch_fun(fun) when is_function(fun, 2), do: {fun, 2}
  defp normalize_fetch_fun(_other), do: {:invalid, 0}

  defp normalize_fetch_opts(opts) when is_list(opts), do: opts
  defp normalize_fetch_opts(_opts), do: []

  defp normalize_now_fun(fun) when is_function(fun, 0), do: fun
  defp normalize_now_fun(_fun), do: fn -> System.monotonic_time(:millisecond) end

  defp bounded_option(opts, key, default, minimum) do
    value = Keyword.get(opts, key, default)
    if is_integer(value) and value >= minimum, do: value, else: default
  end

  defp valid_timeout(value) when is_integer(value) and value > 0, do: value
  defp valid_timeout(_value), do: @default_call_timeout_ms

  defp now(%State{now_fun: now_fun}) do
    case safe_call(now_fun, []) do
      value when is_integer(value) -> value
      _other -> System.monotonic_time(:millisecond)
    end
  end

  defp connection_identity(connection, env_fetcher) do
    policy = value(connection, "policy")
    reference = value(policy, "api_key")
    {secret_status, secret, environment_name} = resolve_secret(reference, env_fetcher)
    identity = %{connection: connection, resolved_secret: secret}
    revision = :crypto.hash(:sha256, :erlang.term_to_binary(identity)) |> Base.encode16(case: :lower)

    %{
      revision: revision,
      secret_status: secret_status,
      secret: secret,
      environment_name: environment_name
    }
  end

  defp resolve_secret(reference, env_fetcher) do
    case secret_variable(reference) do
      {:ok, variable} ->
        result = safe_call(env_fetcher, [variable])
        secret = unwrap_secret(result)

        if is_binary(secret) and String.trim(secret) != "" do
          {:ok, secret, variable}
        else
          {:missing, nil, variable}
        end

      :error ->
        {:missing, nil, nil}
    end
  end

  defp secret_variable(reference) when is_binary(reference) do
    case Regex.run(~r/\A\$([A-Za-z0-9._-]+)\z/, reference, capture: :all_but_first) do
      [variable] ->
        {:ok, variable}

      _other ->
        case Regex.run(~r/\A\$\{([A-Za-z0-9._-]+)\}\z/, reference, capture: :all_but_first) do
          [variable] -> {:ok, variable}
          _invalid -> :error
        end
    end
  end

  defp secret_variable(_reference), do: :error

  defp unwrap_secret({:ok, secret}), do: secret
  defp unwrap_secret(secret), do: secret

  defp safe_call(fun, args) when is_function(fun, length(args)) do
    apply(fun, args)
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp safe_call(_fun, _args), do: nil

  defp ensure_entry(state, revision, now) do
    case Map.get(state.entries, revision) do
      nil ->
        entry = new_entry(now)

        case evict_for_insert(state) do
          {:ok, state} ->
            state = put_entry(state, revision, entry)
            {state, entry, true}

          :full ->
            {state, entry, false}
        end

      entry ->
        entry = %{entry | last_access_at_ms: now}
        {state, entry, true}
    end
  end

  defp new_entry(now) do
    %{
      data: nil,
      fetched_at_ms: nil,
      last_access_at_ms: now,
      last_error: nil,
      last_error_at_ms: nil,
      job_ref: nil
    }
  end

  defp put_entry(state, revision, entry), do: %{state | entries: Map.put(state.entries, revision, entry)}

  defp evict_for_insert(state) do
    if map_size(state.entries) < state.max_entries do
      {:ok, state}
    else
      candidates =
        state.entries
        |> Enum.reject(fn {_revision, entry} -> not is_nil(entry.job_ref) end)
        |> Enum.sort_by(fn {_revision, entry} -> entry.last_access_at_ms end)

      case candidates do
        [{revision, _entry} | _rest] -> {:ok, %{state | entries: Map.delete(state.entries, revision)}}
        [] -> :full
      end
    end
  end

  defp expire_entry(%{data: nil} = entry, _now, _state), do: entry

  defp expire_entry(entry, now, state) do
    if stale_expired?(entry, now, state) do
      %{entry | data: nil, fetched_at_ms: nil}
    else
      entry
    end
  end

  defp should_schedule?(%{job_ref: job_ref}, _now, _state, _force_refresh?) when not is_nil(job_ref), do: false
  defp should_schedule?(_entry, _now, _state, true), do: true

  defp should_schedule?(%{last_error_at_ms: failed_at}, now, state, false) when is_integer(failed_at),
    do: max(now - failed_at, 0) >= state.failure_retry_ms

  defp should_schedule?(entry, now, state, false),
    do: is_nil(entry.data) or stale?(entry, now, state)

  defp stale?(entry, now, state) do
    is_integer(entry.fetched_at_ms) and max(now - entry.fetched_at_ms, 0) > state.fresh_ttl_ms
  end

  defp stale_expired?(entry, now, state) do
    is_integer(entry.fetched_at_ms) and
      max(now - entry.fetched_at_ms, 0) > state.fresh_ttl_ms + state.stale_age_ms
  end

  defp schedule_job(state, identity, connection, env_fetcher, request_opts, now) do
    if map_size(state.jobs) >= state.max_concurrent_jobs do
      {:error, :capacity, state}
    else
      parent = self()
      job_ref = make_ref()
      fetch_opts = effective_fetch_opts(state, request_opts, env_fetcher, identity)
      fetch_fun = state.fetch_fun
      fetch_fun_arity = state.fetch_fun_arity

      pid =
        spawn_link(fn ->
          receive do
            {:metadata_cache_bind, ^job_ref} ->
              result = run_fetch(fetch_fun, fetch_fun_arity, connection, fetch_opts)
              send(parent, {:metadata_cache_result, job_ref, result})
          end
        end)

      monitor_ref = Process.monitor(pid)
      timer_ref = Process.send_after(self(), {:metadata_cache_timeout, job_ref}, state.job_timeout_ms)
      entry = Map.fetch!(state.entries, identity.revision)
      entry = %{entry | job_ref: job_ref, last_access_at_ms: now}
      state = put_entry(state, identity.revision, entry)

      state = %{
        state
        | jobs:
            Map.put(state.jobs, job_ref, %{
              pid: pid,
              monitor_ref: monitor_ref,
              revision: identity.revision,
              timer_ref: timer_ref
            })
      }

      send(pid, {:metadata_cache_bind, job_ref})
      {:ok, state}
    end
  end

  defp effective_fetch_opts(state, request_opts, env_fetcher, identity) do
    configured = Keyword.get(request_opts, :fetch_opts, state.fetch_opts)
    configured = if is_list(configured), do: configured, else: state.fetch_opts
    environment_name = identity.environment_name
    resolved_secret = identity.secret

    bound_env_fetcher = fn variable ->
      if environment_name != nil and variable == environment_name do
        resolved_secret
      else
        safe_call(env_fetcher, [variable])
      end
    end

    Keyword.put(configured, :env_fetcher, bound_env_fetcher)
  end

  defp run_fetch(fetch_fun, 1, connection, _fetch_opts) when is_function(fetch_fun, 1) do
    invoke_fetch(fetch_fun, [connection])
  end

  defp run_fetch(fetch_fun, 2, connection, fetch_opts) when is_function(fetch_fun, 2) do
    invoke_fetch(fetch_fun, [connection, fetch_opts])
  end

  defp run_fetch(:default, 2, connection, fetch_opts) do
    invoke_fetch(&Metadata.fetch/2, [connection, fetch_opts])
  end

  defp run_fetch(_fetch_fun, _arity, _connection, _fetch_opts), do: {:error, :unavailable}

  defp invoke_fetch(fun, args) do
    fun
    |> apply(args)
    |> normalize_fetch_result()
  rescue
    _error -> {:error, :offline}
  catch
    _kind, _reason -> {:error, :offline}
  end

  defp normalize_fetch_result({:ok, metadata}) do
    case normalize_metadata(metadata) do
      {:ok, data} -> {:ok, data}
      {:error, _reason} -> {:error, :invalid_response}
    end
  end

  defp normalize_fetch_result({:error, reason}), do: {:error, normalize_error(reason)}
  defp normalize_fetch_result(_other), do: {:error, :invalid_response}

  defp normalize_metadata(metadata) when is_map(metadata) do
    values = Map.take(metadata, @metadata_keys)
    valid = map_size(values) == length(@metadata_keys) and Enum.all?(values, &metadata_rows?/1)
    if valid, do: {:ok, values}, else: {:error, :invalid_response}
  end

  defp normalize_metadata(_metadata), do: {:error, :invalid_response}

  defp metadata_rows?({_key, rows}) when is_list(rows), do: Enum.all?(rows, &is_map/1)
  defp metadata_rows?(_entry), do: false

  defp normalize_error(reason) when reason in @known_errors, do: reason
  defp normalize_error({reason, _details}) when reason in @known_errors, do: reason
  defp normalize_error({:http_error, status}) when status in [401, 403], do: :authentication_failed
  defp normalize_error({:http_error, 429}), do: :rate_limited
  defp normalize_error(:timeout), do: :offline
  defp normalize_error(:closed), do: :offline
  defp normalize_error(:econnrefused), do: :offline
  defp normalize_error(_reason), do: :invalid_response

  defp settle_job(state, job_ref, result) do
    case Map.pop(state.jobs, job_ref) do
      {nil, _jobs} ->
        state

      {%{revision: revision, timer_ref: timer_ref, monitor_ref: monitor_ref}, jobs} ->
        Process.cancel_timer(timer_ref)
        Process.demonitor(monitor_ref, [:flush])
        state = %{state | jobs: jobs}
        now = now(state)

        case Map.get(state.entries, revision) do
          %{job_ref: ^job_ref} = entry ->
            entry = apply_fetch_result(entry, result, now, state)
            put_entry(state, revision, entry)

          _other ->
            state
        end
    end
  end

  defp apply_fetch_result(entry, {:ok, data}, now, _state) do
    %{
      entry
      | data: data,
        fetched_at_ms: now,
        last_error: nil,
        last_error_at_ms: nil,
        job_ref: nil,
        last_access_at_ms: now
    }
  end

  defp apply_fetch_result(entry, {:error, :authentication_failed}, now, _state) do
    %{
      entry
      | data: nil,
        fetched_at_ms: nil,
        last_error: :authentication_failed,
        last_error_at_ms: now,
        job_ref: nil,
        last_access_at_ms: now
    }
  end

  defp apply_fetch_result(entry, {:error, reason}, now, state) do
    reason = normalize_error(reason)
    keep_data? = not is_nil(entry.data) and not stale_expired?(entry, now, state)

    %{
      entry
      | data: if(keep_data?, do: entry.data, else: nil),
        fetched_at_ms: if(keep_data?, do: entry.fetched_at_ms, else: nil),
        last_error: reason,
        last_error_at_ms: now,
        job_ref: nil,
        last_access_at_ms: now
    }
  end

  defp authenticate_failure(entry, now) do
    %{
      entry
      | data: nil,
        fetched_at_ms: nil,
        last_error: :authentication_failed,
        last_error_at_ms: now,
        job_ref: nil
    }
  end

  defp response_for(entry, revision, now, state, capacity \\ nil) do
    cond do
      entry.data != nil and refresh_required?(entry, now, state) ->
        %{
          status: "stale_cache",
          reason: stale_reason(entry, capacity),
          data: entry.data,
          connection_revision: revision
        }

      entry.data != nil ->
        %{
          status: if(metadata_empty?(entry.data), do: "empty", else: "current"),
          reason: nil,
          data: entry.data,
          connection_revision: revision
        }

      entry.job_ref != nil ->
        %{status: "loading", reason: nil, data: @empty_metadata, connection_revision: revision}

      entry.last_error != nil ->
        %{
          status: status_for_error(entry.last_error),
          reason: format_reason(entry.last_error),
          data: @empty_metadata,
          connection_revision: revision
        }

      capacity != nil ->
        %{status: "unavailable", reason: format_reason(capacity), data: @empty_metadata, connection_revision: revision}

      true ->
        %{status: "loading", reason: nil, data: @empty_metadata, connection_revision: revision}
    end
  end

  defp refresh_required?(entry, now, state),
    do: stale?(entry, now, state) or not is_nil(entry.job_ref) or not is_nil(entry.last_error)

  defp stale_reason(entry, capacity) do
    cond do
      capacity != nil -> format_reason(capacity)
      entry.job_ref != nil -> "refreshing"
      entry.last_error != nil -> format_reason(entry.last_error)
      true -> "stale"
    end
  end

  defp metadata_empty?(metadata), do: Enum.all?(@metadata_keys, &(Map.get(metadata, &1) == []))

  defp status_for_error(:authentication_failed), do: "authentication_failed"
  defp status_for_error(:rate_limited), do: "rate_limited"
  defp status_for_error(:offline), do: "offline"
  defp status_for_error(_reason), do: "unavailable"

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(_reason), do: "unavailable"

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp value(_map, _key), do: nil

  defp unavailable_result(connection, opts) do
    env_fetcher = Keyword.get(opts, :env_fetcher, &System.get_env/1)
    identity = connection_identity(connection, env_fetcher)

    %{
      status: "unavailable",
      reason: "service_unavailable",
      data: @empty_metadata,
      connection_revision: identity.revision
    }
  end
end
