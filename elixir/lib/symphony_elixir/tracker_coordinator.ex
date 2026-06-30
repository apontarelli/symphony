defmodule SymphonyElixir.TrackerCoordinator do
  @moduledoc """
  Local tracker coordination boundary shared by local Symphony daemons.

  The default implementation uses an operator-owned file under the configured
  workspace root. The module API is intentionally small so a later process,
  SQLite, or cloud-backed coordinator can replace this storage without changing
  orchestrator dispatch semantics.
  """

  require Logger

  alias SymphonyElixir.{Config, RunTarget}
  alias SymphonyElixir.Linear.Issue

  @default_cache_ttl_ms 30_000
  @default_lease_ttl_ms 900_000
  @lock_retry_sleep_ms 10
  @lock_retry_attempts 50
  @lock_stale_ms 60_000
  @state_version 1

  @type coordinator_error ::
          {:coordinator_lock_unavailable, term()} | {:coordinator_write_failed, term()}
  @type lease_result :: :ok | {:error, :leased | :missing | coordinator_error()}

  @spec resolve_candidate_issues(
          RunTarget.t() | nil,
          (-> {:ok, RunTarget.Resolution.t()} | {:error, term()}),
          keyword()
        ) ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_candidate_issues(target, fetch_fun, opts \\ [])
      when is_function(fetch_fun, 0) and is_list(opts) do
    key = opts |> Keyword.get(:cache_key, target) |> target_key()
    now_ms = wall_clock_now_ms(opts)

    case cached_candidate_result(key, now_ms, opts) do
      :cache_miss ->
        fetch_and_cache_candidates(key, fetch_fun, opts)

      result ->
        result
    end
  end

  defp cached_candidate_result(key, now_ms, opts) do
    with_state_read(opts, fn state ->
      cond do
        rate_limit_active?(state, now_ms) ->
          {:error, {:linear_rate_limited, shared_rate_limit_details(state.rate_limit, now_ms)}}

        cached_resolution = fresh_cached_resolution(state, key, now_ms) ->
          {:ok, cached_resolution}

        true ->
          :cache_miss
      end
    end)
  end

  defp fetch_and_cache_candidates(key, fetch_fun, opts) do
    now_ms = wall_clock_now_ms(opts)

    case fetch_fun.() do
      {:ok, %RunTarget.Resolution{} = resolution} ->
        put_cached_candidate_result(key, resolution, now_ms, opts)

      {:error, {:linear_rate_limited, details}} ->
        put_candidate_rate_limit(details, :candidate_fetch, now_ms, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_cached_candidate_result(key, %RunTarget.Resolution{} = resolution, now_ms, opts) do
    with_state_write(opts, fn state ->
      {put_cached_resolution(state, key, resolution, now_ms, opts), {:ok, resolution}}
    end)
  end

  defp put_candidate_rate_limit(details, source, now_ms, opts) do
    with_state_write(opts, fn state ->
      updated_state = put_rate_limit(state, details, source, now_ms, opts)
      {updated_state, {:error, {:linear_rate_limited, shared_rate_limit_details(updated_state.rate_limit, now_ms)}}}
    end)
  end

  @spec claim_issue(Issue.t(), String.t(), keyword()) :: lease_result()
  def claim_issue(%Issue{id: issue_id} = issue, owner_id, opts \\ [])
      when is_binary(issue_id) and is_binary(owner_id) and is_list(opts) do
    now_ms = wall_clock_now_ms(opts)

    with_state_write(opts, fn state ->
      {state, result} = reclaim_expired_lease(state, issue_id, now_ms)

      case Map.get(state.leases, issue_id) do
        nil ->
          lease = %{
            issue_id: issue_id,
            identifier: issue.identifier,
            owner_id: owner_id,
            acquired_at_ms: now_ms,
            expires_at_ms: now_ms + lease_ttl_ms(opts)
          }

          {%{state | leases: Map.put(state.leases, issue_id, lease)}, :ok}

        %{owner_id: ^owner_id} = lease ->
          refreshed = refresh_lease(lease, now_ms, opts)
          {%{state | leases: Map.put(state.leases, issue_id, refreshed)}, :ok}

        _lease ->
          {state, result}
      end
    end)
  end

  @spec refresh_issue_lease(String.t(), String.t(), keyword()) :: lease_result()
  def refresh_issue_lease(issue_id, owner_id, opts \\ [])
      when is_binary(issue_id) and is_binary(owner_id) and is_list(opts) do
    now_ms = wall_clock_now_ms(opts)

    with_state_write(opts, fn state ->
      case Map.get(state.leases, issue_id) do
        nil ->
          {state, {:error, :missing}}

        %{owner_id: ^owner_id} = lease ->
          refreshed = refresh_lease(lease, now_ms, opts)
          {%{state | leases: Map.put(state.leases, issue_id, refreshed)}, :ok}

        _lease ->
          {state, {:error, :leased}}
      end
    end)
  end

  @spec release_issue(String.t(), String.t() | nil, keyword()) :: :ok | {:error, coordinator_error()}
  def release_issue(issue_id, owner_id \\ nil, opts \\ [])
      when is_binary(issue_id) and is_list(opts) do
    with_state_write(opts, fn state ->
      leases =
        case Map.get(state.leases, issue_id) do
          nil ->
            state.leases

          %{owner_id: ^owner_id} ->
            Map.delete(state.leases, issue_id)

          _lease when is_nil(owner_id) ->
            Map.delete(state.leases, issue_id)

          _lease ->
            state.leases
        end

      {%{state | leases: leases}, :ok}
    end)
  end

  @spec record_rate_limit(term(), atom(), keyword()) :: map() | {:error, coordinator_error()}
  def record_rate_limit(details, source, opts \\ []) when is_atom(source) and is_list(opts) do
    now_ms = wall_clock_now_ms(opts)

    with_state_write(opts, fn state ->
      updated_state = put_rate_limit(state, details, source, now_ms, opts)
      {updated_state, shared_rate_limit_details(updated_state.rate_limit, now_ms)}
    end)
  end

  @spec rate_limit(keyword()) :: map() | nil | {:error, coordinator_error()}
  def rate_limit(opts \\ []) when is_list(opts) do
    now_ms = wall_clock_now_ms(opts)

    with_state_write(opts, fn state ->
      state = clear_expired_rate_limit(state, now_ms)
      {state, rate_limit_snapshot(state.rate_limit, now_ms)}
    end)
  end

  @spec snapshot(keyword()) :: map() | {:error, coordinator_error()}
  def snapshot(opts \\ []) when is_list(opts) do
    now_ms = wall_clock_now_ms(opts)

    with_state_write(opts, fn state ->
      state = reclaim_expired_leases(state, now_ms) |> clear_expired_rate_limit(now_ms)

      {state,
       %{
         cache_entries: map_size(state.caches),
         leases: Map.values(state.leases),
         rate_limit: rate_limit_snapshot(state.rate_limit, now_ms)
       }}
    end)
  end

  @spec state_path() :: Path.t()
  def state_path do
    Application.get_env(:symphony_elixir, :tracker_coordinator_state_path) ||
      Config.settings!()
      |> Map.fetch!(:workspace)
      |> Map.fetch!(:root)
      |> Path.expand()
      |> Path.join(".symphony/tracker_coordinator.state")
  end

  defp with_state_read(opts, fun) when is_function(fun, 1) do
    path = state_path(opts)

    with_lock(path, opts, fn ->
      path
      |> read_state()
      |> fun.()
    end)
  end

  defp with_state_write(opts, fun) when is_function(fun, 1) do
    path = state_path(opts)

    with_lock(path, opts, fn ->
      state = read_state(path)
      {updated_state, result} = fun.(state)

      case write_state(path, updated_state) do
        :ok -> result
        {:error, reason} -> {:error, {:coordinator_write_failed, reason}}
      end
    end)
  end

  defp state_path(opts) do
    case Keyword.fetch(opts, :state_path) do
      {:ok, state_path} -> state_path
      :error -> state_path()
    end
  end

  defp with_lock(path, opts, fun) do
    lock_path = path <> ".lock"
    File.mkdir_p!(Path.dirname(lock_path))

    attempts = Keyword.get(opts, :lock_retry_attempts, @lock_retry_attempts)
    sleep_ms = Keyword.get(opts, :lock_retry_sleep_ms, @lock_retry_sleep_ms)

    case acquire_lock(lock_path, attempts, sleep_ms) do
      {:ok, file} ->
        try do
          fun.()
        after
          File.close(file)
          File.rm(lock_path)
        end

      {:error, reason} ->
        Logger.warning("Tracker coordinator lock unavailable path=#{lock_path}: #{inspect(reason)}")

        {:error, {:coordinator_lock_unavailable, reason}}
    end
  end

  defp acquire_lock(lock_path, attempts, sleep_ms) when attempts > 0 do
    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, file} ->
        IO.binwrite(
          file,
          :erlang.term_to_binary(%{pid: self(), acquired_at_ms: System.system_time(:millisecond)})
        )

        {:ok, file}

      {:error, _reason} ->
        maybe_remove_stale_lock(lock_path)
        Process.sleep(sleep_ms)
        acquire_lock(lock_path, attempts - 1, sleep_ms)
    end
  end

  defp acquire_lock(_lock_path, 0, _sleep_ms), do: {:error, :busy}

  defp maybe_remove_stale_lock(lock_path) do
    case File.read(lock_path) do
      {:ok, binary} ->
        with %{acquired_at_ms: acquired_at_ms} when is_integer(acquired_at_ms) <-
               decode_lock(binary),
             true <- System.system_time(:millisecond) - acquired_at_ms > @lock_stale_ms do
          File.rm(lock_path)
        else
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp decode_lock(binary) when is_binary(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    _ -> %{}
  end

  defp read_state(path) do
    case File.read(path) do
      {:ok, binary} ->
        decode_state(binary)

      {:error, :enoent} ->
        empty_state()

      {:error, reason} ->
        Logger.warning("Tracker coordinator state unreadable path=#{path}: #{inspect(reason)}")
        empty_state()
    end
  end

  defp decode_state(binary) when is_binary(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      %{version: @state_version, caches: caches, leases: leases, rate_limit: rate_limit}
      when is_map(caches) and is_map(leases) ->
        %{version: @state_version, caches: caches, leases: leases, rate_limit: rate_limit}

      _ ->
        empty_state()
    end
  rescue
    _ -> empty_state()
  end

  defp write_state(path, state) do
    File.mkdir_p!(Path.dirname(path))
    tmp_path = path <> ".tmp"
    binary = :erlang.term_to_binary(state)

    with :ok <- File.write(tmp_path, binary),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("Tracker coordinator state write failed path=#{path}: #{inspect(reason)}")
        error
    end
  end

  defp empty_state, do: %{version: @state_version, caches: %{}, leases: %{}, rate_limit: nil}

  defp fresh_cached_resolution(state, key, now_ms) do
    case Map.get(state.caches, key) do
      %{expires_at_ms: expires_at_ms, resolution: %RunTarget.Resolution{} = resolution}
      when is_integer(expires_at_ms) and expires_at_ms > now_ms ->
        resolution

      _ ->
        nil
    end
  end

  defp put_cached_resolution(state, key, %RunTarget.Resolution{} = resolution, now_ms, opts) do
    cache = %{
      cached_at_ms: now_ms,
      expires_at_ms: now_ms + cache_ttl_ms(opts),
      resolution: resolution
    }

    %{state | caches: Map.put(state.caches, key, cache), rate_limit: nil}
  end

  defp put_rate_limit(state, details, source, now_ms, opts) do
    delay_ms = rate_limit_delay_ms(details, opts)

    rate_limit =
      details
      |> normalize_rate_limit_details()
      |> Map.merge(%{
        reason: :tracker_rate_limited,
        source: source,
        limited_until_ms: now_ms + delay_ms,
        retry_after_ms: delay_ms
      })

    %{state | rate_limit: rate_limit}
  end

  defp shared_rate_limit_details(rate_limit, now_ms) when is_map(rate_limit) do
    remaining_ms = rate_limit_remaining_ms(rate_limit, now_ms)

    rate_limit
    |> Map.drop([:limited_until_ms])
    |> Map.put(:retry_after_ms, max(remaining_ms || 0, 1))
    |> Map.put(:remaining_ms, remaining_ms)
  end

  defp rate_limit_snapshot(rate_limit, now_ms) when is_map(rate_limit) do
    case rate_limit_remaining_ms(rate_limit, now_ms) do
      remaining_ms when is_integer(remaining_ms) and remaining_ms > 0 ->
        rate_limit
        |> Map.put(:remaining_ms, remaining_ms)

      _ ->
        nil
    end
  end

  defp rate_limit_snapshot(_rate_limit, _now_ms), do: nil

  defp rate_limit_active?(state, now_ms),
    do: not is_nil(rate_limit_snapshot(state.rate_limit, now_ms))

  defp clear_expired_rate_limit(state, now_ms) do
    if rate_limit_active?(state, now_ms), do: state, else: %{state | rate_limit: nil}
  end

  defp rate_limit_remaining_ms(%{limited_until_ms: limited_until_ms}, now_ms)
       when is_integer(limited_until_ms) and is_integer(now_ms) do
    max(0, limited_until_ms - now_ms)
  end

  defp rate_limit_remaining_ms(_rate_limit, _now_ms), do: nil

  defp normalize_rate_limit_details(details) when is_map(details) do
    Map.take(details, [:status, :retry_after_ms, :reset_at, :errors, :error])
  end

  defp normalize_rate_limit_details(details), do: %{error: inspect(details)}

  defp rate_limit_delay_ms(details, opts) when is_map(details) do
    positive_integer(Map.get(details, :retry_after_ms)) || reset_delay_ms(details) ||
      cache_ttl_ms(opts)
  end

  defp rate_limit_delay_ms(_details, opts), do: cache_ttl_ms(opts)

  defp reset_delay_ms(%{reset_at: reset_at}) when is_binary(reset_at) do
    case DateTime.from_iso8601(reset_at) do
      {:ok, reset_at, _offset} ->
        max(0, DateTime.diff(reset_at, DateTime.utc_now(), :millisecond))

      _ ->
        nil
    end
  end

  defp reset_delay_ms(_details), do: nil

  defp reclaim_expired_lease(state, issue_id, now_ms) do
    case Map.get(state.leases, issue_id) do
      %{expires_at_ms: expires_at_ms}
      when is_integer(expires_at_ms) and expires_at_ms <= now_ms ->
        {%{state | leases: Map.delete(state.leases, issue_id)}, :ok}

      _ ->
        {state, {:error, :leased}}
    end
  end

  defp reclaim_expired_leases(state, now_ms) do
    leases =
      Map.reject(state.leases, fn
        {_issue_id, %{expires_at_ms: expires_at_ms}} when is_integer(expires_at_ms) ->
          expires_at_ms <= now_ms

        _entry ->
          false
      end)

    %{state | leases: leases}
  end

  defp refresh_lease(lease, now_ms, opts) when is_map(lease) do
    %{lease | expires_at_ms: now_ms + lease_ttl_ms(opts)}
  end

  defp target_key(target) do
    target
    |> normalize_target()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_target(%RunTarget{} = target), do: Map.from_struct(target)
  defp normalize_target(nil), do: nil
  defp normalize_target(target), do: target

  defp cache_ttl_ms(opts), do: Keyword.get(opts, :cache_ttl_ms, @default_cache_ttl_ms)
  defp lease_ttl_ms(opts), do: Keyword.get(opts, :lease_ttl_ms, @default_lease_ttl_ms)
  defp wall_clock_now_ms(opts), do: Keyword.get(opts, :now_ms, System.system_time(:millisecond))

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
end
