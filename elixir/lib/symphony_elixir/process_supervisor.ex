defmodule SymphonyElixir.ProcessSupervisor do
  @moduledoc """
  Shared OS process primitive for local runner adapters.

  Local processes are launched from argv without an intermediate shell and can be
  stopped with descendant cleanup when the host `ps`/`kill` tools expose the
  process tree. SSH-backed launches should wrap the local ssh port with
  `cleanup: :port_only`; remote process-group cleanup is intentionally outside
  this primitive's current guarantee.
  The launch/adoption caller is monitored by a lifecycle owner, which cleans up the process tree when the caller goes down.
  """

  defstruct [:port, :os_pid, :owner, cleanup: :descendants]

  @type argv :: [String.t()]
  @type cleanup :: :descendants | :port_only
  @type env_value :: String.t() | charlist() | false
  @type env_overlay ::
          %{optional(String.t()) => env_value()}
          | [
              {String.t() | charlist(), env_value()}
            ]
  @type identity :: %{os_pid: non_neg_integer() | nil}
  @type startup_timeout :: (-> non_neg_integer())
  @type startup_fun :: (t(), startup_timeout() -> :ok | {:ok, term()} | {:error, term()})
  @type t :: %__MODULE__{
          port: port(),
          os_pid: non_neg_integer() | nil,
          owner: pid() | nil,
          cleanup: cleanup()
        }

  @spec start(argv(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(argv, opts \\ []) when is_list(argv) do
    with {:ok, cleanup} <- normalize_cleanup(Keyword.get(opts, :cleanup, :descendants)),
         {:ok, {executable, args}} <- resolve_argv(argv, Keyword.get(opts, :cd)),
         {:ok, port_opts} <- port_options(args, opts) do
      start_owned(executable, port_opts, cleanup)
    end
  rescue
    error -> {:error, {:process_start_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:process_start_failed, {kind, reason}}}
  end

  @spec from_port(port(), keyword()) :: t()
  def from_port(port, opts \\ []) when is_port(port) do
    adopt_port(port, normalize_cleanup!(Keyword.get(opts, :cleanup, :descendants)))
  end

  @spec port(t()) :: port()
  def port(%__MODULE__{port: port}), do: port

  @spec identity(t() | port()) :: identity()
  def identity(%__MODULE__{os_pid: os_pid}), do: %{os_pid: os_pid}
  def identity(port) when is_port(port), do: %{os_pid: port_os_pid(port)}

  @spec descendant_cleanup_supported?() :: boolean()
  def descendant_cleanup_supported? do
    match?({_output, 0}, process_list())
  end

  @spec await_startup(t(), pos_integer(), startup_fun()) :: {:ok, term()} | {:error, {:startup_failed, term()}}
  def await_startup(%__MODULE__{} = process, timeout_ms, startup_fun)
      when is_integer(timeout_ms) and timeout_ms > 0 and is_function(startup_fun, 2) do
    timeout = startup_timeout(timeout_ms)

    case startup_fun.(process, timeout) do
      :ok ->
        {:ok, :ok}

      {:ok, result} ->
        {:ok, result}

      {:error, {:startup_failed, _reason} = reason} ->
        stop(process)
        {:error, reason}

      {:error, reason} ->
        stop(process)
        {:error, {:startup_failed, normalize_startup_error(reason, timeout_ms)}}

      other ->
        stop(process)
        {:error, {:startup_failed, {:unexpected_startup_result, other}}}
    end
  rescue
    error ->
      stop(process)
      {:error, {:startup_failed, {:exception, error.__struct__, Exception.message(error)}}}
  catch
    kind, reason ->
      stop(process)
      {:error, {:startup_failed, {kind, reason}}}
  end

  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = process), do: request_owner(process, :stop)

  @spec kill(t()) :: :ok
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
      os_pid = port_os_pid(port)
      send(caller, {:process_supervisor_started, self(), port, os_pid})

      state = %{
        caller: caller,
        caller_monitor: caller_monitor,
        port: port,
        os_pid: os_pid,
        cleanup: cleanup
      }

      lifecycle_owner_loop(state)
    rescue
      error ->
        send(caller, {:process_supervisor_start_failed, self(), {:process_start_failed, Exception.message(error)}})
        Process.demonitor(caller_monitor, [:flush])
    catch
      kind, reason ->
        send(caller, {:process_supervisor_start_failed, self(), {:process_start_failed, {kind, reason}}})
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
      {:process_supervisor_started, ^owner, port, os_pid} ->
        Process.demonitor(owner_monitor, [:flush])
        {:ok, %__MODULE__{port: port, os_pid: os_pid, owner: owner, cleanup: cleanup}}

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
        %__MODULE__{port: port, os_pid: os_pid, owner: owner, cleanup: cleanup}

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
        send(state.caller, {port, {:exit_status, status}})

      {^port, message} ->
        send(state.caller, {port, message})
        lifecycle_owner_loop(state)

      {:process_supervisor_stop, requester, request_ref} ->
        stop_owned_process(state_process(state))
        send(requester, {:process_supervisor_reply, request_ref})

      {:process_supervisor_kill, requester, request_ref} ->
        kill_owned_process(state_process(state))
        send(requester, {:process_supervisor_reply, request_ref})

      {:DOWN, caller_monitor, :process, caller, _reason}
      when caller_monitor == state.caller_monitor and caller == state.caller ->
        stop_owned_process(state_process(state))
    end
  end

  defp state_process(state) do
    %__MODULE__{
      port: state.port,
      os_pid: state.os_pid,
      owner: self(),
      cleanup: state.cleanup
    }
  end

  defp request_owner(%__MODULE__{owner: owner} = process, action) when is_pid(owner) do
    request_ref = make_ref()
    owner_monitor = Process.monitor(owner)
    send(owner, {request_message(action), self(), request_ref})

    receive do
      {:process_supervisor_reply, ^request_ref} ->
        Process.demonitor(owner_monitor, [:flush])
        :ok

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        fallback_request(process, action)
    end
  end

  defp request_owner(process, action), do: fallback_request(process, action)

  defp request_message(:stop), do: :process_supervisor_stop
  defp request_message(:kill), do: :process_supervisor_kill

  defp fallback_request(process, :stop), do: stop_owned_process(process)
  defp fallback_request(process, :kill), do: kill_owned_process(process)

  defp stop_owned_process(%__MODULE__{} = process) do
    signal_os_pids(termination_targets(process), "TERM")
    Process.sleep(150)
    kill_targets = termination_targets(process)
    signal_os_pids(kill_targets, "KILL")
    close_port(process.port)
    wait_for_os_pids(kill_targets, 10)
    :ok
  end

  defp kill_owned_process(%__MODULE__{} = process) do
    signal_os_pids(termination_targets(process), "KILL")
    close_port(process.port)
    :ok
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

  defp normalize_cleanup(cleanup) when cleanup in [:descendants, :port_only], do: {:ok, cleanup}

  defp normalize_cleanup(cleanup), do: {:error, {:invalid_cleanup, cleanup}}

  defp normalize_cleanup!(cleanup) do
    case normalize_cleanup(cleanup) do
      {:ok, normalized} -> normalized
      {:error, {:invalid_cleanup, invalid}} -> raise ArgumentError, "invalid cleanup mode: #{inspect(invalid)}"
    end
  end

  defp termination_targets(%__MODULE__{} = process) do
    os_pid = current_os_pid(process)

    descendants =
      case process.cleanup do
        :descendants -> os_pid_descendants(os_pid)
        :port_only -> []
      end

    [os_pid | descendants]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp current_os_pid(%__MODULE__{port: port}), do: port_os_pid(port)

  defp port_os_pid(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _ -> nil
    end
  end

  defp os_pid_descendants(nil), do: []

  defp os_pid_descendants(pid) when is_integer(pid) do
    case process_list() do
      {output, 0} ->
        output
        |> parent_index()
        |> collect_descendant_pids(pid)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp parent_index(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, &put_parent_index_entry/2)
  end

  defp put_parent_index_entry(line, by_parent) do
    case parse_pid_pair(line) do
      {:ok, child, parent} -> Map.update(by_parent, parent, [child], &[child | &1])
      :error -> by_parent
    end
  end

  defp parse_pid_pair(line) do
    with [child_text, parent_text] <- line |> String.trim() |> String.split(~r/\s+/, trim: true),
         {child, ""} <- Integer.parse(child_text),
         {parent, ""} <- Integer.parse(parent_text) do
      {:ok, child, parent}
    else
      _ -> :error
    end
  end

  defp process_list do
    System.cmd("ps", ["-axo", "pid=,ppid="], stderr_to_stdout: true)
  rescue
    _ -> {"", 1}
  end

  defp collect_descendant_pids(by_parent, pid) do
    children = Map.get(by_parent, pid, [])
    Enum.flat_map(children, &collect_descendant_pids(by_parent, &1)) ++ children
  end

  defp signal_os_pids(pids, signal) do
    pids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn pid ->
      System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp wait_for_os_pids(_pids, 0), do: :ok

  defp wait_for_os_pids(pids, attempts) do
    if Enum.any?(pids, &os_pid_running?/1) do
      Process.sleep(50)
      wait_for_os_pids(pids, attempts - 1)
    else
      :ok
    end
  end

  defp os_pid_running?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
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
