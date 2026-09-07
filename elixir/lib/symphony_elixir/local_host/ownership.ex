defmodule SymphonyElixir.LocalHost.Ownership do
  @moduledoc """
  Holds the per-user lifetime host ownership lock.

  Ownership is an exclusive `flock` held on a file descriptor inside the
  BEAM process itself (see `SymphonyElixir.LocalHost.Lock`). The kernel
  releases it exactly when the BEAM exits, so a crashed or killed host
  never leaves stale ownership behind and no PID-based cleanup is ever
  performed. There is no helper process whose death could free the lock
  while the host is still running.

  The resource holding the descriptor is pinned in `persistent_term`,
  so the ownership outlives any single process inside the BEAM: if this
  GenServer is restarted by its supervisor, it reattaches to the
  existing BEAM-held lock without any reacquisition window during which
  a second host could start.

  The lock path is derived from the per-user local config root, never
  from a registry path or registry `state_root`, so registry aliases
  cannot evade the exclusion.

  Once the HTTP endpoint and the operator interface are ready, the
  private discovery record is published atomically. Publication never
  releases the BEAM-held lock: the record is re-derived on a slow tick
  and rewritten only when the current host identity, credential path,
  or bound endpoint actually changed, so discovery stays synchronized
  across supervised worker restarts (`:one_for_one` can replace the
  operator interface or the HTTP listener without touching this
  process). Lifecycle monitors cannot observe a listener rebinding
  under the endpoint supervisor, so every discovery field is polled
  instead. The record is removed again on graceful shutdown and never
  republished afterwards; a record left behind by a crashed host is
  rejected by `SymphonyElixir.LocalHost.discover/1` because the
  authenticated readiness check fails.
  """

  use GenServer

  import Bitwise, only: [&&&: 2]

  alias SymphonyElixir.{HttpServer, LocalConfig, LocalHost.Lock, OperatorInterface, OperatorSession}
  alias SymphonyElixir.TargetRegistry.FileStore

  require Logger

  @lock_file "host.lock"
  @discovery_dir "host"
  @discovery_file "discovery.json"
  @lock_key {__MODULE__, :host_lock}
  @ready_poll_ms 250
  @ready_slow_poll_ms 5_000
  @ready_deadline_ms 60_000
  @sync_poll_ms 1_000

  defmodule State do
    @moduledoc false
    @enforce_keys [:root, :lock_path, :record_path]
    defstruct @enforce_keys ++
                [
                  published: nil,
                  readiness_started_at: nil,
                  deadline_reported?: false,
                  undiscoverable_reported?: false,
                  unpublished?: false,
                  readiness: nil
                ]
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, SymphonyElixir.HostOwnership))
  end

  @doc """
  Claims per-user host ownership before any host side effects.

  Returns `{:error, :host_lock_held}` when another process owns the
  lock, or a `{:host_lock_*, _}` reason when ownership could not be
  established. Re-claiming inside the same BEAM is idempotent.
  """
  @spec claim(keyword()) :: {:ok, pid()} | {:error, term()}
  def claim(opts \\ []) do
    expected_lock_path =
      Keyword.get(opts, :lock_path) ||
        Path.join(LocalConfig.root(config_root: Keyword.get(opts, :config_root)), @lock_file)

    case GenServer.start(__MODULE__, opts, name: Keyword.get(opts, :name, SymphonyElixir.HostOwnership)) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        if owned_lock_path(pid) == expected_lock_path,
          do: {:ok, pid},
          else: {:error, {:host_lock_unavailable, :ownership_mismatch}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp owned_lock_path(pid) do
    GenServer.call(pid, :lock_path, 5_000)
  catch
    :exit, _reason -> nil
  end

  @doc """
  Reports whether another process currently owns the per-user lock.

  Never writes: the lock file is opened without creation, so a missing
  file proves that no holder exists.
  """
  @spec probe(keyword()) :: :free | :held | {:error, term()}
  def probe(opts \\ []) do
    with {:ok, executable} <- lock_executable(Keyword.get(opts, :lock_executable)) do
      lock_path = Keyword.get(opts, :lock_path) || lock_path(opts)

      try do
        case System.cmd(to_string(executable), ["probe", lock_path]) do
          {_output, 0} -> :free
          {_output, 2} -> :held
          _failure -> {:error, :host_lock_probe_failed}
        end
      rescue
        _exception -> {:error, :host_lock_unavailable}
      catch
        _kind, _reason -> {:error, :host_lock_unavailable}
      end
    end
  end

  @doc """
  Removes the published discovery record when this process owns it.

  Public so a supervisor-driven shutdown can request record removal
  without tearing the ownership process down first.
  """
  @spec unpublish(GenServer.server(), timeout()) :: :ok
  def unpublish(server \\ SymphonyElixir.HostOwnership, timeout \\ 5_000) do
    GenServer.call(server, :unpublish, timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Derives the reachable loopback discovery endpoint for a bound listener.

  IPv6 addresses are formatted with brackets. Wildcard binds map to the
  same-family loopback address, which the wildcard listener always
  serves. A listener bound to any other address is not discoverable
  through the loopback-only private discovery contract.
  """
  @spec loopback_endpoint(:inet.ip_address(), :inet.port_number()) ::
          {:ok, String.t()} | {:error, :non_loopback_listener}
  def loopback_endpoint(ip, port) when is_integer(port) and port > 0 do
    case loopback_host(ip) do
      {:ok, host} -> {:ok, "http://#{host}:#{port}"}
      :error -> {:error, :non_loopback_listener}
    end
  end

  defp loopback_host({127, 0, 0, 1}), do: {:ok, "127.0.0.1"}
  defp loopback_host({0, 0, 0, 0}), do: {:ok, "127.0.0.1"}
  defp loopback_host({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}), do: {:ok, "127.0.0.1"}
  defp loopback_host({0, 0, 0, 0, 0, 0, 0, 1}), do: {:ok, "[::1]"}
  defp loopback_host({0, 0, 0, 0, 0, 0, 0, 0}), do: {:ok, "[::1]"}
  defp loopback_host(_other), do: :error

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    root = LocalConfig.root(config_root: Keyword.get(opts, :config_root))
    lock_path = Keyword.get(opts, :lock_path) || Path.join(root, @lock_file)

    state = %State{
      root: root,
      lock_path: lock_path,
      record_path: Path.join([root, @discovery_dir, @discovery_file]),
      readiness_started_at: System.monotonic_time(:millisecond),
      readiness: Keyword.get(opts, :readiness)
    }

    case beam_held_lock(root, lock_path) do
      {:ok, _acquisition} ->
        {:ok, state, {:continue, :await_ready}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # The lock is held for the lifetime of the BEAM; a restarted ownership
  # process reattaches to the existing descriptor instead of racing for
  # a second flock, which could never succeed against this same BEAM.
  defp beam_held_lock(root, lock_path) do
    case :persistent_term.get(@lock_key, nil) do
      {^lock_path, _resource} ->
        {:ok, :attached}

      nil ->
        with :ok <- ensure_root(root) do
          acquire_lock(lock_path)
        end

      {_other_lock_path, _resource} ->
        {:error, {:host_lock_unavailable, :ownership_mismatch}}
    end
  end

  defp acquire_lock(lock_path) do
    case Lock.acquire(to_string(lock_path)) do
      {:ok, resource} ->
        :persistent_term.put(@lock_key, {lock_path, resource})
        {:ok, :acquired}

      {:error, :held} ->
        {:error, :host_lock_held}

      {:error, :nif_not_loaded} ->
        {:error, {:host_lock_unavailable, :nif_not_loaded}}

      {:error, reason} ->
        {:error, {:host_lock_failed, reason}}
    end
  rescue
    _exception -> {:error, {:host_lock_unavailable, :nif_load_failed}}
  catch
    _kind, _reason -> {:error, {:host_lock_unavailable, :nif_load_failed}}
  end

  @impl true
  def handle_continue(:await_ready, %State{} = state), do: {:noreply, await_ready(state)}

  @impl true
  def handle_info(:ready_tick, %State{} = state), do: {:noreply, await_ready(state)}

  def handle_info(_other, %State{} = state), do: {:noreply, state}

  @impl true
  def handle_call(:lock_path, _from, %State{} = state),
    do: {:reply, state.lock_path, state}

  @impl true
  def handle_call(:unpublish, _from, %State{} = state) do
    remove_published_record(state)
    # Once removal is requested, discovery must never reappear, even
    # though the sync tick keeps firing until this process stops.
    {:reply, :ok, %State{state | published: nil, unpublished?: true}}
  end

  @impl true
  def terminate(_reason, %State{} = state) do
    remove_published_record(state)
    :ok
  end

  # Shutdown was requested through `unpublish/1`: the record must never
  # reappear, so synchronization stops outright.
  defp await_ready(%State{unpublished?: true} = state), do: state

  defp await_ready(%State{} = state) do
    case host_readiness(state) do
      {:ok, info} ->
        record = discovery_record(info)

        if record == state.published do
          # Unchanged metadata: no file write, just the next sync tick.
          schedule_sync_tick(state)
        else
          publish_record(state, record)
        end

      {:error, :non_loopback_listener} ->
        report_undiscoverable(state)

      :pending when state.published == nil ->
        report_readiness_delay(state, :pending)

      :pending ->
        # A supervised worker (operator interface or HTTP listener) is
        # between restarts. Keep the last record in place — clients see
        # a consistent host, `discover/1` fails safely as `host_stale`
        # against it — and the next tick picks up the new metadata.
        schedule_sync_tick(state)
    end
  end

  defp publish_record(%State{} = state, record) do
    case write_discovery_record(state, record) do
      :ok ->
        verb = if state.published == nil, do: "published", else: "refreshed"
        Logger.info("Host discovery #{verb} host_id=#{record["host_id"]} endpoint=#{record["endpoint"]}")
        schedule_sync_tick(%State{state | published: record})

      {:error, reason} ->
        report_readiness_delay(state, {:publish_failed, reason})
    end
  end

  # A listener bound to a non-loopback address is an explicit
  # configuration choice: never publish an unreachable or non-private
  # endpoint for it. Report the rejection once instead of every tick.
  defp report_undiscoverable(%State{} = state) do
    if not state.undiscoverable_reported? do
      Logger.warning("Host discovery withheld: the HTTP listener is bound to a non-loopback address; bind server.host to a loopback address to publish discovery")
    end

    schedule_sync_tick(%State{state | undiscoverable_reported?: true})
  end

  defp report_readiness_delay(%State{} = state, _detail) do
    elapsed = System.monotonic_time(:millisecond) - state.readiness_started_at
    slow? = elapsed >= @ready_deadline_ms

    if slow? and not state.deadline_reported? do
      Logger.warning("Host discovery not ready yet elapsed_ms=#{elapsed}")
      %State{state | deadline_reported?: true}
    else
      state
    end
    |> schedule_ready_tick(slow?)
  end

  defp schedule_ready_tick(%State{} = state, slow?) do
    interval = if slow?, do: @ready_slow_poll_ms, else: @ready_poll_ms
    Process.send_after(self(), :ready_tick, interval)
    state
  end

  defp schedule_sync_tick(%State{} = state) do
    Process.send_after(self(), :ready_tick, @sync_poll_ms)
    state
  end

  defp host_readiness(%State{readiness: readiness}) when is_function(readiness, 0) do
    case readiness.() do
      {:ok, info} -> {:ok, info}
      _other -> :pending
    end
  end

  defp host_readiness(%State{} = _state) do
    with {:ok, endpoint} <- bound_endpoint(),
         {:ok, marker} <- safe_marker(),
         {:ok, credentials} <- safe_credentials() do
      {:ok,
       %{
         endpoint: endpoint,
         host_id: marker.host_id,
         started_at: marker.started_at,
         interface_version: marker.interface_version,
         schema_version: marker.schema_version,
         token_file: credentials.token_path
       }}
    else
      {:error, :non_loopback_listener} = rejected -> rejected
      _pending -> :pending
    end
  end

  defp bound_endpoint do
    case HttpServer.bound_address() do
      {:ok, {ip, port}} -> loopback_endpoint(ip, port)
      nil -> :pending
    end
  end

  defp safe_marker do
    OperatorInterface.marker()
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp safe_credentials do
    OperatorInterface.credentials()
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp discovery_record(info) do
    %{
      "endpoint" => info.endpoint,
      "host_id" => info.host_id,
      "started_at" => info.started_at,
      "interface_version" => info.interface_version,
      "schema_version" => info.schema_version,
      "token_file" => info.token_file
    }
  end

  defp write_discovery_record(%State{} = state, record) do
    with {:ok, bytes} <- Jason.encode(record),
         {:ok, _directory} <- private_directory(Path.join(state.root, @discovery_dir)),
         :ok <- write_record(state.record_path, bytes) do
      :ok
    else
      {:error, reason} -> {:error, {:discovery_publish_failed, reason}}
      :error -> {:error, {:discovery_publish_failed, :invalid_record}}
    end
  end

  defp write_record(path, bytes) do
    case FileStore.create_temp(path, bytes) do
      {:ok, temporary} ->
        try do
          File.rename(temporary.path, path)
        after
          FileStore.remove_temp(temporary)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_published_record(%State{published: nil}), do: :ok

  defp remove_published_record(%State{} = state) do
    with {:ok, bytes} <- File.read(state.record_path),
         {:ok, record} <- Jason.decode(bytes),
         true <- record_matches?(record, state.published) do
      File.rm(state.record_path)
    else
      _other -> :ok
    end
  end

  defp record_matches?(record, published) when is_map(record) and is_map(published) do
    Enum.all?(~w(endpoint host_id started_at token_file), fn key ->
      Map.get(record, key) == Map.get(published, key)
    end)
  end

  defp record_matches?(_record, _published), do: false

  defp lock_executable(nil) do
    case Lock.native_path("host_lock") do
      nil -> {:error, :host_lock_unavailable}
      executable -> {:ok, executable}
    end
  end

  defp lock_executable(executable) when is_binary(executable) do
    if File.regular?(executable), do: {:ok, executable}, else: {:error, :host_lock_unavailable}
  end

  defp lock_path(opts) do
    root = LocalConfig.root(config_root: Keyword.get(opts, :config_root))
    Path.join(root, @lock_file)
  end

  defp ensure_root(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory, uid: uid, mode: mode}} ->
        if OperatorSession.current_uid() == {:ok, uid} and (mode &&& 0o022) == 0,
          do: :ok,
          else: {:error, {:host_lock_unavailable, :insecure_config_root}}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(root),
             :ok <- File.chmod(root, 0o700) do
          :ok
        else
          {:error, reason} -> {:error, {:host_lock_unavailable, reason}}
          _failure -> {:error, {:host_lock_unavailable, :root_create_failed}}
        end

      _other ->
        {:error, {:host_lock_unavailable, :invalid_config_root}}
    end
  end

  defp private_directory(path) do
    current_uid = OperatorSession.current_uid()

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        if owned_private_directory?(stat, current_uid), do: {:ok, path}, else: {:error, :insecure_path}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(path),
             :ok <- File.chmod(path, 0o700),
             {:ok, %File.Stat{} = stat} <- File.lstat(path),
             true <- owned_private_directory?(stat, current_uid) do
          {:ok, path}
        else
          _failure -> {:error, :insecure_path}
        end

      _other ->
        {:error, :insecure_path}
    end
  end

  defp owned_private_directory?(%File.Stat{mode: mode} = stat, {:ok, current_uid}) do
    (mode &&& 0o077) == 0 and
      is_integer(stat.uid) and stat.uid == current_uid
  end

  defp owned_private_directory?(_stat, _current_uid), do: false
end
