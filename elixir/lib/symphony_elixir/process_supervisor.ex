defmodule SymphonyElixir.ProcessSupervisor do
  @moduledoc """
  Shared OS process primitive for local runner adapters.

  Local processes are launched from argv through a fixed, non-interpolating
  wrapper that creates one isolated process group. The lifecycle owner monitors
  the launch caller and terminates the whole group when the caller exits.
  Adopted and SSH-backed ports use `cleanup: :port_only`; they do not claim a
  local process-group guarantee.
  """

  require Logger

  @process_group_marker "__SYMPHONY_PROCESS_GROUP__:"
  @process_group_release "__SYMPHONY_PROCESS_GROUP_RELEASE__"
  @process_group_start_timeout_ms 1_000
  @termination_grace_ms 150
  @group_identity_attempts 50

  @process_group_child_wrapper """
  marker=$1
  release=$2
  shift 2
  printf '%s%s\n' "$marker" "$$"
  IFS= read -r received_release
  [ "$received_release" = "$release" ] || exit 126
  exec "$@"
  """

  @process_group_wrapper """
  marker=$1
  release=$2
  shift 2
  set -m 2>/dev/null || exit 125
  exec 3<&0

  (
    IFS= read -r received_release
    [ "$received_release" = "$release" ] || exit 126
    exec "$@"
  ) <&3 &
  group_pid=$!
  set +m 2>/dev/null || true

  printf '%s%s\n' "$marker" "$group_pid"
  wait "$group_pid"
  status=$?
  exec 3<&-

  if kill -0 "-$group_pid" 2>/dev/null; then
    kill -TERM "-$group_pid" 2>/dev/null || true
    sleep 0.15
    kill -KILL "-$group_pid" 2>/dev/null || true
  fi
  exit "$status"
  """

  defstruct [:port, :os_pid, :process_group_id, :wrapper_pid, :owner, cleanup: :process_group]
  @type cleanup_result :: :ok | {:error, {:process_cleanup_failed, map()}}

  @type argv :: [String.t()]
  @type cleanup :: :process_group | :port_only
  @type env_value :: String.t() | charlist() | false
  @type env_overlay ::
          %{optional(String.t()) => env_value()}
          | [
              {String.t() | charlist(), env_value()}
            ]
  @type identity :: %{
          os_pid: non_neg_integer() | nil,
          process_group_id: non_neg_integer() | nil
        }
  @type startup_timeout :: (-> non_neg_integer())
  @type startup_fun :: (t(), startup_timeout() -> :ok | {:ok, term()} | {:error, term()})
  @type recovery_identity :: %{
          required(String.t()) => pos_integer() | String.t()
        }
  @type recovery_outcome :: {:stopped | :unverifiable, map()}
  @type t :: %__MODULE__{
          port: port(),
          os_pid: non_neg_integer() | nil,
          process_group_id: non_neg_integer() | nil,
          wrapper_pid: non_neg_integer() | nil,
          owner: pid() | nil,
          cleanup: cleanup()
        }

  @spec start(argv(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(argv, opts \\ []) when is_list(argv) do
    with {:ok, cleanup} <- normalize_cleanup(Keyword.get(opts, :cleanup, :process_group)),
         :ok <- ensure_cleanup_supported(cleanup),
         {:ok, {executable, args}} <- resolve_argv(argv, Keyword.get(opts, :cd)),
         {:ok, {launch_executable, launch_args}} <-
           process_group_launch(executable, args, cleanup),
         {:ok, port_opts} <- port_options(launch_args, opts) do
      start_owned(launch_executable, port_opts, cleanup)
    end
  rescue
    error -> {:error, {:process_start_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:process_start_failed, {kind, reason}}}
  end

  @spec run(argv(), pos_integer()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run(argv, timeout_ms), do: run(argv, timeout_ms, [])

  @spec run(argv(), pos_integer(), keyword()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run(argv, timeout_ms, opts)
      when is_list(argv) and is_integer(timeout_ms) and timeout_ms > 0 and is_list(opts) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    with {:ok, process} <- start(argv, opts) do
      owner_monitor = Process.monitor(process.owner)
      await_run(process, owner_monitor, deadline_ms, [])
    end
  end

  def run(_argv, _timeout_ms, _opts), do: {:error, :invalid_process_timeout}

  defp await_run(%__MODULE__{port: port} = process, owner_monitor, deadline_ms, output) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        await_run(process, owner_monitor, deadline_ms, [run_output_chunk(chunk) | output])

      {^port, {:exit_status, status}} ->
        Process.demonitor(owner_monitor, [:flush])
        {:ok, {output |> Enum.reverse() |> IO.iodata_to_binary(), status}}

      {:DOWN, ^owner_monitor, :process, _owner, reason} ->
        {:error, {:process_owner_exit, reason}}
    after
      remaining_ms ->
        Process.demonitor(owner_monitor, [:flush])
        process_timeout(process)
    end
  end

  defp run_output_chunk({:eol, chunk}), do: [chunk, "\n"]
  defp run_output_chunk({:noeol, chunk}), do: chunk
  defp run_output_chunk(chunk), do: chunk

  defp process_timeout(process) do
    case kill(process) do
      :ok -> :ok
      {:error, _reason} = cleanup_error -> Logger.error("Timed-out process cleanup failed: #{inspect(cleanup_error)}")
    end

    {:error, :process_timeout}
  end

  @spec from_port(port(), keyword()) :: t()
  def from_port(port, opts \\ []) when is_port(port) do
    adopt_port(port, normalize_cleanup!(Keyword.get(opts, :cleanup, :port_only)))
  end

  @spec port(t()) :: port()
  def port(%__MODULE__{port: port}), do: port

  @spec identity(t() | port()) :: identity()
  def identity(%__MODULE__{os_pid: os_pid, process_group_id: process_group_id}),
    do: %{os_pid: os_pid, process_group_id: process_group_id}

  def identity(port) when is_port(port),
    do: %{os_pid: port_os_pid(port), process_group_id: nil}

  @doc """
  Captures the stable local identity required to reconcile this process group
  after a host-process restart.
  """
  @spec recovery_identity(t()) :: {:ok, recovery_identity()} | {:error, term()}
  def recovery_identity(%__MODULE__{cleanup: :process_group} = process) do
    with process_group_id when is_integer(process_group_id) <- owned_process_group(process),
         {:ok, parent_pid, ^process_group_id, started_at} <-
           process_identity_with_start(process_group_id),
         true <- parent_pid == process.wrapper_pid do
      {:ok,
       %{
         "os_pid" => process.os_pid,
         "process_group_id" => process_group_id,
         "wrapper_pid" => process.wrapper_pid,
         "started_at" => started_at
       }}
    else
      _invalid -> {:error, :process_identity_unverifiable}
    end
  end

  def recovery_identity(%__MODULE__{}), do: {:error, :process_group_not_owned}

  @doc """
  Terminates a process group only when its current leader still matches a
  previously captured recovery identity.
  """
  @spec terminate_recovered_group(map()) :: recovery_outcome()
  def terminate_recovered_group(identity) when is_map(identity) do
    with {:ok, normalized} <- normalize_recovery_identity(identity),
         :ok <- process_group_support() do
      reconcile_recovered_group(normalized)
    else
      {:error, reason} ->
        {:unverifiable, %{reason: inspect(reason), verified_by: "process_supervisor"}}
    end
  end

  def terminate_recovered_group(_identity) do
    {:unverifiable, %{reason: "invalid persisted process identity", verified_by: "process_supervisor"}}
  end

  @spec descendant_cleanup_supported?() :: boolean()
  def descendant_cleanup_supported?, do: process_group_supported?()

  @spec await_startup(t(), pos_integer(), startup_fun()) :: {:ok, term()} | {:error, term()}
  def await_startup(%__MODULE__{} = process, timeout_ms, startup_fun)
      when is_integer(timeout_ms) and timeout_ms > 0 and is_function(startup_fun, 2) do
    timeout = startup_timeout(timeout_ms)

    case startup_fun.(process, timeout) do
      :ok ->
        {:ok, :ok}

      {:ok, result} ->
        {:ok, result}

      {:error, {:startup_failed, reason}} ->
        startup_failure(process, reason)

      {:error, reason} ->
        startup_failure(process, normalize_startup_error(reason, timeout_ms))

      other ->
        startup_failure(process, {:unexpected_startup_result, other})
    end
  rescue
    error ->
      startup_failure(process, {:exception, error.__struct__, Exception.message(error)})
  catch
    kind, reason ->
      startup_failure(process, {kind, reason})
  end

  defp startup_failure(process, reason) do
    case stop(process) do
      :ok -> {:error, {:startup_failed, reason}}
      {:error, cleanup_reason} -> {:error, {:startup_failed, reason, cleanup_reason}}
    end
  end

  @spec stop(t()) :: cleanup_result()
  def stop(%__MODULE__{} = process), do: request_owner(process, :stop)

  @spec kill(t()) :: cleanup_result()
  def kill(%__MODULE__{} = process), do: request_owner(process, :kill)

  defp start_owned(executable, port_opts, cleanup) do
    caller = self()
    {owner, owner_monitor} = spawn_monitor(fn -> lifecycle_owner_open(caller, executable, port_opts, cleanup) end)
    await_owner_start(owner, owner_monitor, cleanup)
  end

  defp adopt_port(port, cleanup) do
    caller = self()
    adoption_ref = make_ref()

    {owner, owner_monitor} =
      spawn_monitor(fn -> lifecycle_owner_adopt(caller, port, cleanup, adoption_ref) end)

    await_owner_adoption(owner, owner_monitor, port, cleanup, adoption_ref)
  end

  defp lifecycle_owner_open(caller, executable, port_opts, cleanup) do
    caller_monitor = Process.monitor(caller)

    try do
      port = Port.open({:spawn_executable, String.to_charlist(executable)}, port_opts)
      wrapper_pid = port_os_pid(port)

      case initialize_owned_process(port, wrapper_pid, cleanup) do
        {:ok, os_pid, process_group_id} ->
          send(
            caller,
            {:process_supervisor_started, self(), port, os_pid, process_group_id, wrapper_pid}
          )

          lifecycle_owner_loop(%{
            caller: caller,
            caller_monitor: caller_monitor,
            port: port,
            os_pid: os_pid,
            process_group_id: process_group_id,
            wrapper_pid: wrapper_pid,
            cleanup: cleanup
          })

        {:error, reason} ->
          close_port(port)
          send(caller, {:process_supervisor_start_failed, self(), reason})
          Process.demonitor(caller_monitor, [:flush])
      end
    rescue
      error ->
        send(
          caller,
          {:process_supervisor_start_failed, self(), {:process_start_failed, Exception.message(error)}}
        )

        Process.demonitor(caller_monitor, [:flush])
    catch
      kind, reason ->
        send(
          caller,
          {:process_supervisor_start_failed, self(), {:process_start_failed, {kind, reason}}}
        )

        Process.demonitor(caller_monitor, [:flush])
    end
  end

  defp lifecycle_owner_adopt(caller, port, cleanup, adoption_ref) do
    caller_monitor = Process.monitor(caller)

    try do
      send(caller, {:process_supervisor_adoption_ready, self(), adoption_ref})

      receive do
        {:process_supervisor_port_adopted, ^caller, ^adoption_ref} ->
          os_pid = port_os_pid(port)
          send(caller, {:process_supervisor_adopted, self(), adoption_ref, port, os_pid})

          state = %{
            caller: caller,
            caller_monitor: caller_monitor,
            port: port,
            os_pid: os_pid,
            process_group_id: nil,
            wrapper_pid: os_pid,
            cleanup: cleanup
          }

          lifecycle_owner_loop(state)

        {:process_supervisor_adoption_aborted, ^caller, ^adoption_ref} ->
          Process.demonitor(caller_monitor, [:flush])

        {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
          :ok
      end
    rescue
      error ->
        send(caller, {:process_supervisor_adopt_failed, self(), adoption_ref, Exception.message(error)})
        Process.demonitor(caller_monitor, [:flush])
    catch
      kind, reason ->
        send(caller, {:process_supervisor_adopt_failed, self(), adoption_ref, {kind, reason}})
        Process.demonitor(caller_monitor, [:flush])
    end
  end

  defp await_owner_start(owner, owner_monitor, cleanup) do
    receive do
      {:process_supervisor_started, ^owner, port, os_pid, process_group_id, wrapper_pid} ->
        Process.demonitor(owner_monitor, [:flush])

        {:ok,
         %__MODULE__{
           port: port,
           os_pid: os_pid,
           process_group_id: process_group_id,
           wrapper_pid: wrapper_pid,
           owner: owner,
           cleanup: cleanup
         }}

      {:process_supervisor_start_failed, ^owner, reason} ->
        Process.demonitor(owner_monitor, [:flush])
        {:error, reason}

      {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
        {:error, {:process_start_failed, {:owner_exit, reason}}}
    end
  end

  defp await_owner_adoption(owner, owner_monitor, port, cleanup, adoption_ref) do
    receive do
      {:process_supervisor_adoption_ready, ^owner, ^adoption_ref} ->
        transfer_port_to_owner(owner, owner_monitor, port, cleanup, adoption_ref)

      {:process_supervisor_adopt_failed, ^owner, ^adoption_ref, reason} ->
        close_port(port)
        await_owner_exit(owner, owner_monitor)
        raise_adoption_failure(reason)

      {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
        close_port(port)
        raise_adoption_failure({:owner_exit, reason})
    end
  end

  defp transfer_port_to_owner(owner, owner_monitor, port, cleanup, adoption_ref) do
    case connect_port(port, owner) do
      :ok ->
        send(owner, {:process_supervisor_port_adopted, self(), adoption_ref})
        await_owner_adoption_complete(owner, owner_monitor, cleanup, adoption_ref)

      {:error, reason} ->
        send(owner, {:process_supervisor_adoption_aborted, self(), adoption_ref})
        close_port(port)
        await_owner_exit(owner, owner_monitor)
        raise_adoption_failure(reason)
    end
  end

  defp connect_port(port, owner) do
    true = Port.connect(port, owner)
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp await_owner_adoption_complete(owner, owner_monitor, cleanup, adoption_ref) do
    receive do
      {:process_supervisor_adopted, ^owner, ^adoption_ref, port, os_pid} ->
        Process.demonitor(owner_monitor, [:flush])

        %__MODULE__{
          port: port,
          os_pid: os_pid,
          process_group_id: nil,
          wrapper_pid: os_pid,
          owner: owner,
          cleanup: cleanup
        }

      {:process_supervisor_adopt_failed, ^owner, ^adoption_ref, reason} ->
        await_owner_exit(owner, owner_monitor)
        raise_adoption_failure(reason)

      {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
        raise_adoption_failure({:owner_exit, reason})
    end
  end

  defp await_owner_exit(owner, owner_monitor) do
    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> :ok
    end
  end

  defp raise_adoption_failure(reason) do
    raise ArgumentError, "failed to adopt port: #{inspect(reason)}"
  end

  defp lifecycle_owner_loop(%{port: port} = state) do
    receive do
      {^port, {:exit_status, status}} ->
        cleanup_exited_process_group(state_process(state))
        send(state.caller, {port, {:exit_status, status}})

      {^port, message} ->
        send(state.caller, {port, message})
        lifecycle_owner_loop(state)

      {:process_supervisor_stop, requester, request_ref} ->
        result = stop_owned_process(state_process(state))
        send(requester, {:process_supervisor_reply, request_ref, result})

      {:process_supervisor_kill, requester, request_ref} ->
        result = kill_owned_process(state_process(state))
        send(requester, {:process_supervisor_reply, request_ref, result})

      {:DOWN, caller_monitor, :process, caller, _reason}
      when caller_monitor == state.caller_monitor and caller == state.caller ->
        stop_owned_process(state_process(state))
    end
  end

  defp state_process(state) do
    %__MODULE__{
      port: state.port,
      os_pid: state.os_pid,
      process_group_id: state.process_group_id,
      wrapper_pid: state.wrapper_pid,
      owner: self(),
      cleanup: state.cleanup
    }
  end

  defp request_owner(%__MODULE__{owner: owner} = process, action) when is_pid(owner) do
    request_ref = make_ref()
    owner_monitor = Process.monitor(owner)
    send(owner, {request_message(action), self(), request_ref})

    receive do
      {:process_supervisor_reply, ^request_ref, result} ->
        Process.demonitor(owner_monitor, [:flush])
        result

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        fallback_request(process, action)
    end
  end

  defp request_owner(process, action), do: fallback_request(process, action)

  defp request_message(:stop), do: :process_supervisor_stop
  defp request_message(:kill), do: :process_supervisor_kill

  defp fallback_request(process, :stop), do: stop_owned_process(process)
  defp fallback_request(process, :kill), do: kill_owned_process(process)

  defp stop_owned_process(%__MODULE__{cleanup: :port_only} = process) do
    close_port(process.port)
    :ok
  end

  defp stop_owned_process(%__MODULE__{cleanup: :process_group} = process) do
    case owned_process_group(process) do
      nil ->
        cleanup_without_owned_group(process)

      process_group_id ->
        signal_process_group(process_group_id, "TERM")
        Process.sleep(@termination_grace_ms)

        if process_group_alive?(process_group_id) or
             owned_process_group(process) == process_group_id do
          signal_process_group(process_group_id, "KILL")
        end

        close_port(process.port)
        wait_for_process_group(process_group_id, 10)
        process_group_cleanup_result(process_group_id)
    end
  end

  defp kill_owned_process(%__MODULE__{cleanup: :port_only} = process) do
    close_port(process.port)
    :ok
  end

  defp kill_owned_process(%__MODULE__{cleanup: :process_group} = process) do
    case owned_process_group(process) do
      nil ->
        cleanup_without_owned_group(process)

      process_group_id ->
        signal_process_group(process_group_id, "KILL")
        close_port(process.port)
        wait_for_process_group(process_group_id, 10)
        process_group_cleanup_result(process_group_id)
    end
  end

  defp cleanup_without_owned_group(process) do
    wrapper_alive? = port_os_pid(process.port) != nil
    close_port(process.port)

    if wrapper_alive? do
      {:error,
       {:process_cleanup_failed,
        %{
          process_group_id: process.process_group_id,
          reason: :group_identity_lost
        }}}
    else
      :ok
    end
  end

  defp cleanup_exited_process_group(%__MODULE__{
         cleanup: :process_group,
         process_group_id: process_group_id
       })
       when is_integer(process_group_id) and process_group_id > 0 do
    if process_group_alive?(process_group_id) do
      signal_process_group(process_group_id, "TERM")
      Process.sleep(@termination_grace_ms)

      if process_group_alive?(process_group_id) do
        signal_process_group(process_group_id, "KILL")
      end

      wait_for_process_group(process_group_id, 10)
    end

    :ok
  end

  defp cleanup_exited_process_group(_process), do: :ok

  defp process_group_cleanup_result(process_group_id) do
    case process_group_members(process_group_id) do
      {:ok, []} ->
        :ok

      {:ok, remaining_pids} ->
        {:error,
         {:process_cleanup_failed,
          %{
            process_group_id: process_group_id,
            reason: :members_survived_kill,
            remaining_pids: Enum.sort(remaining_pids)
          }}}

      {:error, reason} ->
        {:error,
         {:process_cleanup_failed,
          %{
            process_group_id: process_group_id,
            reason: :group_inspection_failed,
            detail: reason
          }}}
    end
  end

  defp initialize_owned_process(_port, wrapper_pid, :port_only),
    do: {:ok, wrapper_pid, nil}

  defp initialize_owned_process(port, wrapper_pid, :process_group)
       when is_integer(wrapper_pid) and wrapper_pid > 0 do
    deadline_ms = System.monotonic_time(:millisecond) + @process_group_start_timeout_ms
    await_process_group_marker(port, wrapper_pid, deadline_ms, "")
  end

  defp initialize_owned_process(_port, _wrapper_pid, :process_group),
    do: {:error, {:process_group_start_failed, :missing_wrapper_pid}}

  defp await_process_group_marker(port, wrapper_pid, deadline_ms, buffered) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        parse_process_group_marker(buffered <> chunk, port, wrapper_pid)

      {^port, {:data, {:noeol, chunk}}} ->
        await_process_group_marker(port, wrapper_pid, deadline_ms, buffered <> chunk)

      {^port, {:data, chunk}} when is_binary(chunk) ->
        parse_raw_process_group_marker(buffered <> chunk, port, wrapper_pid, deadline_ms)

      {^port, {:exit_status, status}} ->
        {:error, {:process_group_start_failed, {:wrapper_exit, status}}}
    after
      remaining_ms ->
        {:error, {:process_group_start_failed, :marker_timeout}}
    end
  end

  defp parse_raw_process_group_marker(buffered, port, wrapper_pid, deadline_ms) do
    case String.split(buffered, "\n", parts: 2) do
      [line, ""] ->
        parse_process_group_marker(line, port, wrapper_pid)

      [_line, _unexpected_output] ->
        {:error, {:process_group_start_failed, :unexpected_wrapper_output}}

      [_partial] ->
        await_process_group_marker(port, wrapper_pid, deadline_ms, buffered)
    end
  end

  defp parse_process_group_marker(
         @process_group_marker <> process_group_text,
         port,
         wrapper_pid
       ) do
    with {process_group_id, ""} <- Integer.parse(process_group_text),
         true <- process_group_id > 0,
         :ok <-
           await_owned_group_leader(
             process_group_id,
             wrapper_pid,
             @group_identity_attempts
           ),
         true <- Port.command(port, @process_group_release <> "\n") do
      {:ok, process_group_id, process_group_id}
    else
      {:error, observed_identity} ->
        {:error,
         {:process_group_start_failed,
          {:invalid_group_identity,
           %{
             process_group_id: parse_positive_integer(process_group_text),
             wrapper_pid: wrapper_pid,
             observed_identity: observed_identity
           }}}}

      _invalid ->
        {:error, {:process_group_start_failed, :invalid_group_identity}}
    end
  end

  defp parse_process_group_marker(_line, _port, _wrapper_pid),
    do: {:error, {:process_group_start_failed, :invalid_marker}}

  defp await_owned_group_leader(process_group_id, wrapper_pid, attempts)
       when attempts > 0 do
    if owned_group_leader?(process_group_id, wrapper_pid) do
      :ok
    else
      Process.sleep(10)
      await_owned_group_leader(process_group_id, wrapper_pid, attempts - 1)
    end
  end

  defp await_owned_group_leader(process_group_id, _wrapper_pid, 0),
    do: {:error, process_identity(process_group_id)}

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _invalid -> nil
    end
  end

  defp process_group_launch(executable, args, :port_only),
    do: {:ok, {executable, args}}

  defp process_group_launch(executable, args, :process_group) do
    with shell when is_binary(shell) <- System.find_executable("sh"),
         {:ok, launcher} <- process_group_launcher() do
      {:ok, process_group_command(shell, launcher, executable, args)}
    else
      nil -> {:error, {:process_group_unsupported, :missing_shell}}
      {:error, _reason} = error -> error
    end
  end

  defp process_group_command(shell, "direct", executable, args) do
    {shell,
     [
       "-c",
       @process_group_wrapper,
       "symphony-process-group",
       @process_group_marker,
       @process_group_release,
       executable
       | args
     ]}
  end

  defp process_group_command(shell, setsid, executable, args) do
    {setsid,
     [
       "-f",
       "-w",
       shell,
       "-c",
       @process_group_child_wrapper,
       "symphony-process-group-child",
       @process_group_marker,
       @process_group_release,
       executable
       | args
     ]}
  end

  defp ensure_cleanup_supported(:port_only), do: :ok

  defp ensure_cleanup_supported(:process_group), do: process_group_support()

  defp process_group_supported?, do: process_group_support() == :ok

  defp process_group_support do
    with true <- :os.type() in [{:unix, :darwin}, {:unix, :linux}],
         true <- Enum.all?(["sh", "ps", "kill"], &is_binary(System.find_executable(&1))),
         {:ok, _launcher} <- process_group_launcher() do
      :ok
    else
      false -> {:error, {:process_group_unsupported, :os.type()}}
      {:error, _reason} = error -> error
    end
  end

  defp process_group_launcher do
    case :os.type() do
      {:unix, :darwin} ->
        {:ok, "direct"}

      {:unix, :linux} ->
        case System.find_executable("setsid") do
          setsid when is_binary(setsid) -> {:ok, setsid}
          nil -> {:error, {:process_group_unsupported, :missing_setsid}}
        end

      os_type ->
        {:error, {:process_group_unsupported, os_type}}
    end
  end

  defp resolve_argv([], _cwd), do: {:error, :empty_argv}

  defp resolve_argv([executable | args], cwd) when is_binary(executable) do
    with {:ok, resolved_executable} <- resolve_executable(String.trim(executable), cwd),
         {:ok, normalized_args} <- normalize_args(args) do
      {:ok, {resolved_executable, normalized_args}}
    end
  end

  defp resolve_argv(_argv, _cwd), do: {:error, :invalid_argv}

  defp resolve_executable("", _cwd), do: {:error, :empty_executable}

  defp resolve_executable(executable, cwd) when is_binary(executable) do
    if String.contains?(executable, "/") do
      resolve_executable_path(executable, cwd)
    else
      find_executable(executable)
    end
  end

  defp resolve_executable_path(executable, cwd) do
    path = expand_executable(executable, cwd)

    if File.regular?(path) do
      {:ok, path}
    else
      {:error, {:executable_not_found, executable}}
    end
  end

  defp find_executable(executable) do
    case System.find_executable(executable) do
      nil -> {:error, {:executable_not_found, executable}}
      path -> {:ok, path}
    end
  end

  defp expand_executable(executable, cwd) do
    if Path.type(executable) == :absolute do
      executable
    else
      Path.expand(executable, cwd || File.cwd!())
    end
  end

  defp normalize_args(args) do
    if Enum.all?(args, &is_binary/1) do
      {:ok, args}
    else
      {:error, :invalid_argv}
    end
  end

  defp port_options(args, opts) do
    with {:ok, env} <- normalize_env(Keyword.get(opts, :env, [])),
         {:ok, port_opts} <- maybe_put_line_option(base_port_options(args, opts), Keyword.get(opts, :line)) do
      port_opts =
        port_opts
        |> maybe_put_cd_option(Keyword.get(opts, :cd))
        |> maybe_put_env_option(env)

      {:ok, port_opts}
    end
  end

  defp base_port_options(args, opts) do
    base = [
      :binary,
      :exit_status,
      args: Enum.map(args, &String.to_charlist/1)
    ]

    if Keyword.get(opts, :stderr_to_stdout, true) do
      [:stderr_to_stdout | base]
    else
      base
    end
  end

  defp maybe_put_cd_option(port_opts, nil), do: port_opts
  defp maybe_put_cd_option(port_opts, cwd) when is_binary(cwd), do: Keyword.put(port_opts, :cd, String.to_charlist(cwd))

  defp maybe_put_env_option(port_opts, []), do: port_opts
  defp maybe_put_env_option(port_opts, env), do: Keyword.put(port_opts, :env, env)

  defp maybe_put_line_option(port_opts, nil), do: {:ok, port_opts}

  defp maybe_put_line_option(port_opts, line_bytes) when is_integer(line_bytes) and line_bytes > 0 do
    {:ok, Keyword.put(port_opts, :line, line_bytes)}
  end

  defp maybe_put_line_option(_port_opts, line_bytes), do: {:error, {:invalid_line, line_bytes}}

  defp normalize_env(nil), do: {:ok, []}

  defp normalize_env(env) when is_map(env) do
    env
    |> Enum.map(&normalize_env_entry/1)
    |> collect_results()
  end

  defp normalize_env(env) when is_list(env) do
    env
    |> Enum.map(&normalize_env_entry/1)
    |> collect_results()
  end

  defp normalize_env(_env), do: {:error, :invalid_env}

  defp normalize_env_entry({key, value}) do
    with {:ok, port_key} <- port_text(key),
         {:ok, port_value} <- port_env_value(value) do
      {:ok, {port_key, port_value}}
    end
  end

  defp normalize_env_entry(_entry), do: {:error, :invalid_env}

  defp port_env_value(false), do: {:ok, false}
  defp port_env_value(value), do: port_text(value)

  defp port_text(value) when is_binary(value), do: {:ok, String.to_charlist(value)}
  defp port_text(value) when is_list(value), do: {:ok, value}
  defp port_text(_value), do: {:error, :invalid_env}

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, values} -> {:cont, {:ok, [value | values]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp startup_timeout(timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    fn ->
      remaining_ms = deadline_ms - System.monotonic_time(:millisecond)
      max(remaining_ms, 0)
    end
  end

  defp normalize_startup_error(:response_timeout, timeout_ms), do: {:timeout, timeout_ms}
  defp normalize_startup_error(:timeout, timeout_ms), do: {:timeout, timeout_ms}
  defp normalize_startup_error({:timeout, _timeout_ms} = reason, _default_timeout_ms), do: reason
  defp normalize_startup_error(reason, _timeout_ms), do: reason

  defp normalize_cleanup(cleanup) when cleanup in [:process_group, :port_only],
    do: {:ok, cleanup}

  defp normalize_cleanup(cleanup), do: {:error, {:invalid_cleanup, cleanup}}

  defp normalize_cleanup!(cleanup) do
    case normalize_cleanup(cleanup) do
      {:ok, normalized} ->
        normalized

      {:error, {:invalid_cleanup, invalid}} ->
        raise ArgumentError, "invalid cleanup mode: #{inspect(invalid)}"
    end
  end

  defp owned_process_group(%__MODULE__{
         port: port,
         process_group_id: process_group_id,
         wrapper_pid: wrapper_pid
       })
       when is_integer(process_group_id) and process_group_id > 0 and
              is_integer(wrapper_pid) and wrapper_pid > 0 do
    if port_os_pid(port) == wrapper_pid and
         owned_group_leader?(process_group_id, wrapper_pid) do
      process_group_id
    end
  end

  defp owned_process_group(_process), do: nil

  defp owned_group_leader?(process_group_id, wrapper_pid) do
    case process_identity(process_group_id) do
      {:ok, ^wrapper_pid, ^process_group_id} -> true
      _invalid -> false
    end
  end

  defp process_identity(pid) when is_integer(pid) and pid > 0 do
    case process_identity_with_start(pid) do
      {:ok, parent_pid, process_group_id, _started_at} ->
        {:ok, parent_pid, process_group_id}

      :error ->
        :error
    end
  end

  defp process_identity_with_start(pid) when is_integer(pid) and pid > 0 do
    case System.cmd(
           "ps",
           ["-o", "ppid=,pgid=,lstart=", "-p", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {output, 0} -> parse_process_identity_with_start(output)
      _failed -> :error
    end
  rescue
    _exception -> :error
  end

  defp parse_process_identity_with_start(output) when is_binary(output) do
    with [parent_text, group_text, started_at] <-
           output |> String.trim() |> String.split(~r/\s+/, parts: 3, trim: true),
         {parent_pid, ""} <- Integer.parse(parent_text),
         {process_group_id, ""} <- Integer.parse(group_text),
         true <- started_at != "" do
      {:ok, parent_pid, process_group_id, started_at}
    else
      _invalid -> :error
    end
  end

  defp process_group_alive?(process_group_id) do
    case process_group_members(process_group_id) do
      {:ok, members} -> members != []
      {:error, _reason} -> false
    end
  end

  defp process_group_members(process_group_id)
       when is_integer(process_group_id) and process_group_id > 0 do
    case System.cmd("ps", ["-axo", "pid=,pgid=,stat="], stderr_to_stdout: true) do
      {output, 0} ->
        members =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce(
            [],
            &collect_process_group_member(&1, &2, process_group_id)
          )

        {:ok, members}

      {_output, status} ->
        {:error, {:ps_exit, status}}
    end
  rescue
    error -> {:error, {:ps_exception, error.__struct__, Exception.message(error)}}
  end

  defp collect_process_group_member(line, members, process_group_id) do
    case parse_process_group_member(line, process_group_id) do
      {:ok, pid} -> [pid | members]
      :skip -> members
    end
  end

  defp parse_process_group_member(line, expected_group_id) do
    with [pid_text, group_text, status] <-
           line |> String.trim() |> String.split(~r/\s+/, trim: true),
         false <- String.starts_with?(status, "Z"),
         {pid, ""} <- Integer.parse(pid_text),
         {^expected_group_id, ""} <- Integer.parse(group_text) do
      {:ok, pid}
    else
      _invalid -> :skip
    end
  end

  defp signal_process_group(process_group_id, signal) do
    System.cmd(
      "kill",
      process_group_signal_args(process_group_id, signal),
      stderr_to_stdout: true
    )

    :ok
  rescue
    _exception -> :ok
  end

  defp process_group_signal_args(process_group_id, signal) do
    case :os.type() do
      {:unix, :linux} -> ["-#{signal}", "--", "-#{process_group_id}"]
      _other -> ["-#{signal}", "-#{process_group_id}"]
    end
  end

  defp wait_for_process_group(_process_group_id, 0), do: :ok

  defp wait_for_process_group(process_group_id, attempts) do
    if process_group_alive?(process_group_id) do
      Process.sleep(50)
      wait_for_process_group(process_group_id, attempts - 1)
    else
      :ok
    end
  end

  defp normalize_recovery_identity(identity) do
    with {:ok, os_pid} <- fetch_identity_field(identity, "os_pid"),
         {:ok, process_group_id} <- fetch_identity_field(identity, "process_group_id"),
         {:ok, wrapper_pid} <- fetch_identity_field(identity, "wrapper_pid"),
         {:ok, started_at} <- fetch_identity_field(identity, "started_at"),
         true <- Enum.all?([os_pid, process_group_id, wrapper_pid], &(is_integer(&1) and &1 > 0)),
         true <- os_pid == process_group_id,
         true <- is_binary(started_at) and started_at != "" do
      {:ok,
       %{
         os_pid: os_pid,
         process_group_id: process_group_id,
         wrapper_pid: wrapper_pid,
         started_at: started_at
       }}
    else
      _invalid -> {:error, :invalid_persisted_process_identity}
    end
  end

  defp fetch_identity_field(identity, field) do
    atom_field = String.to_existing_atom(field)

    case {Map.fetch(identity, field), Map.fetch(identity, atom_field)} do
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      _missing_or_duplicate -> :error
    end
  end

  defp reconcile_recovered_group(identity) do
    case process_group_members(identity.process_group_id) do
      {:ok, []} ->
        {:stopped,
         %{
           result: "already_stopped",
           verified_by: "process_supervisor",
           process_group_id: identity.process_group_id
         }}

      {:ok, _members} ->
        terminate_matching_recovered_group(identity)

      {:error, reason} ->
        {:unverifiable,
         %{
           reason: inspect(reason),
           verified_by: "process_supervisor",
           process_group_id: identity.process_group_id
         }}
    end
  end

  defp terminate_matching_recovered_group(identity) do
    case process_identity_with_start(identity.os_pid) do
      {:ok, parent_pid, process_group_id, started_at}
      when parent_pid == identity.wrapper_pid and
             process_group_id == identity.process_group_id and
             started_at == identity.started_at ->
        terminate_verified_recovered_group(identity.process_group_id)

      observed ->
        {:unverifiable,
         %{
           reason: "persisted process identity does not match the live group leader",
           observed_identity: inspect(observed),
           verified_by: "process_supervisor",
           process_group_id: identity.process_group_id
         }}
    end
  end

  defp terminate_verified_recovered_group(process_group_id) do
    signal_process_group(process_group_id, "TERM")
    Process.sleep(@termination_grace_ms)

    if process_group_alive?(process_group_id) do
      signal_process_group(process_group_id, "KILL")
    end

    wait_for_process_group(process_group_id, 10)

    case process_group_cleanup_result(process_group_id) do
      :ok ->
        {:stopped,
         %{
           result: "terminated",
           verified_by: "process_supervisor",
           process_group_id: process_group_id
         }}

      {:error, {:process_cleanup_failed, detail}} ->
        {:unverifiable,
         %{
           reason: "verified process group survived termination",
           detail: inspect(detail),
           verified_by: "process_supervisor",
           process_group_id: process_group_id
         }}
    end
  end

  defp port_os_pid(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _ -> nil
    end
  end

  defp close_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end
end
