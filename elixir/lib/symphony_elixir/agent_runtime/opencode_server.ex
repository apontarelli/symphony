defmodule SymphonyElixir.AgentRuntime.OpenCodeServer do
  @moduledoc """
  Local HTTP adapter for `opencode serve`.

  The adapter owns one supervised server process and one OpenCode session. Turns
  use the synchronous message endpoint while polling OpenCode's permission and
  question queues so unattended blocking requests become runner-neutral events.
  """

  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.AgentRuntime.Event
  alias SymphonyElixir.{ExecutionContext, PathSafety, ProcessSupervisor}

  @runtime :opencode_server
  @line_bytes 16_384
  @blocking_poll_interval_ms 50
  @blocking_poll_max_retries 2
  @blocking_poll_retry_delay_ms 20
  @stop_request_timeout_ms 250
  @output_drain_batch_size 64
  @turn_output_drain_ms 50
  @loopback_hosts ["127.0.0.1", "localhost", "::1"]

  @type client :: %{
          base_url: String.t(),
          headers: [{String.t(), String.t()}],
          read_timeout_ms: pos_integer(),
          workspace: Path.t()
        }

  @type execution_profile :: %{
          name: String.t(),
          command: [String.t()],
          model: %{String.t() => String.t()} | nil
        }

  @type session :: %{
          client: client(),
          execution_profile: execution_profile(),
          process: ProcessSupervisor.t(),
          runner_config: map(),
          session_id: String.t(),
          state: pid(),
          turn_timeout_ms: pos_integer(),
          workspace: Path.t(),
          config_overlay: Path.t() | nil
        }

  @inherited_env_keys ~w(PATH HOME TMPDIR TEMP LANG LC_ALL LC_CTYPE TERM)
  @provider_env_keys ~w(OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_API_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY)
  @secret_ref_pattern ~r/^env:([A-Z][A-Z0-9_]*)$/

  @impl true
  @spec start(ExecutionContext.t() | Path.t(), map(), keyword()) ::
          {:ok, session()} | {:error, term()}
  def start(%ExecutionContext{} = context, issue, opts) do
    with :ok <- validate_context_start_options(opts),
         :ok <- ExecutionContext.validate(context),
         %{"kind" => "opencode_server"} = runner <- context.runner_config,
         {:ok, execution_profile} <-
           resolve_execution_profile(runner, context.execution_profile.name),
         {:ok, server_auth} <- resolve_server_auth(runner["server_auth"]),
         :ok <- ensure_local_worker(context.worker_host),
         {:ok, workspace} <- PathSafety.canonicalize(context.workspace_path),
         true <- workspace == context.workspace_path,
         :ok <- validate_loopback_hostname(runner["hostname"]),
         {:ok, {process, config_overlay}} <-
           launch(workspace, runner, execution_profile, server_auth),
         {:ok, session} <-
           start_launched_session(
             process,
             config_overlay,
             workspace,
             issue,
             runner,
             execution_profile,
             server_auth,
             startup_timeout_ms: runner["startup_timeout_ms"],
             turn_timeout_ms: context.timeout_ms
           ) do
      {:ok, Map.put(session, :execution_context, context)}
    else
      %{"kind" => _other_kind} -> {:error, :unsupported_runner_kind}
      false -> {:error, :invalid_agent_runtime_context}
      {:error, :invalid_context} -> {:error, :invalid_agent_runtime_context}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_agent_runtime_context}
    end
  end

  def start(workspace, issue, opts) do
    runner = Keyword.get(opts, :runner_config, %{})
    profile_ref = Keyword.get(opts, :execution_profile, "implementation")

    with {:ok, execution_profile} <- resolve_execution_profile(runner, profile_ref),
         {:ok, server_auth} <- resolve_server_auth(runner["server_auth"]),
         :ok <- ensure_local_worker(Keyword.get(opts, :worker_host)),
         {:ok, workspace} <- PathSafety.canonicalize(workspace),
         :ok <- validate_loopback_hostname(runner["hostname"]),
         {:ok, {process, config_overlay}} <-
           launch(workspace, runner, execution_profile, server_auth) do
      start_launched_session(
        process,
        config_overlay,
        workspace,
        issue,
        runner,
        execution_profile,
        server_auth,
        opts
      )
    end
  end

  defp start_launched_session(
         process,
         config_overlay,
         workspace,
         issue,
         runner,
         execution_profile,
         server_auth,
         opts
       ) do
    with {:ok, client, session_info} <-
           await_ready(process, workspace, issue, runner, server_auth, opts),
         {:ok, state} <- Agent.start_link(fn -> initial_state() end) do
      {:ok,
       %{
         client: client,
         config_overlay: config_overlay,
         process: process,
         runner_config: runner,
         execution_profile: execution_profile,
         session_id: session_info["id"],
         state: state,
         turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms, runner["turn_timeout_ms"]),
         workspace: workspace
       }}
    else
      {:error, reason} ->
        cleanup_failed_start(process, config_overlay, reason)
    end
  end

  defp initial_state do
    %{
      session_started?: false,
      usage: %{
        "cache_read_tokens" => 0,
        "cache_write_tokens" => 0,
        "cost" => 0,
        "input_tokens" => 0,
        "output_tokens" => 0,
        "reasoning_tokens" => 0,
        "total_tokens" => 0
      }
    }
  end

  defp cleanup_failed_start(process, config_overlay, primary_reason) do
    process_cleanup = ProcessSupervisor.stop(process)
    File.rm_rf(config_overlay)

    case process_cleanup do
      :ok ->
        {:error, primary_reason}

      {:error, cleanup_reason} ->
        {:error, {:agent_runtime_start_failed, primary_reason, {:runtime_cleanup_failed, cleanup_reason}}}
    end
  end

  defp validate_context_start_options([]), do: :ok

  defp validate_context_start_options(_opts),
    do: {:error, :invalid_agent_runtime_options}

  defp session_turn_timeout(
         %{execution_context: %ExecutionContext{timeout_ms: timeout_ms}},
         _opts
       ),
       do: timeout_ms

  defp session_turn_timeout(session, opts),
    do: Keyword.get(opts, :turn_timeout_ms, session.turn_timeout_ms)

  defp resolve_execution_profile(runner, profile_ref) do
    profile_name = normalize_profile_name(profile_ref)

    with {:ok, profiles} <- profile_map(runner["execution_profiles"], profile_name),
         {:ok, profile} <- selected_profile(profiles, profile_name),
         {:ok, command} <- profile_command(profile, runner["command"], profile_name),
         {:ok, model} <- profile_model(profile, runner["model"], profile_name) do
      {:ok, %{name: profile_name, command: command, model: model}}
    end
  end

  defp normalize_profile_name(nil), do: "implementation"

  defp normalize_profile_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> "implementation"
      normalized -> normalized
    end
  end

  defp profile_map(nil, _profile_name), do: {:ok, %{}}

  defp profile_map(profiles, profile_name) when is_map(profiles) do
    {:ok,
     Map.new(profiles, fn {name, profile} ->
       {normalize_profile_name(name), profile}
     end)}
  rescue
    _error -> {:error, {:invalid_opencode_execution_profiles, profile_name}}
  end

  defp profile_map(_profiles, profile_name),
    do: {:error, {:invalid_opencode_execution_profiles, profile_name}}

  defp selected_profile(profiles, profile_name) do
    case Map.fetch(profiles, profile_name) do
      :error -> {:ok, %{}}
      {:ok, profile} when is_map(profile) -> {:ok, profile}
      {:ok, _profile} -> {:error, {:invalid_opencode_execution_profile, profile_name}}
    end
  end

  defp profile_command(profile, base_command, profile_name) do
    command = Map.get(profile, "command", base_command)

    cond do
      not is_list(command) ->
        {:error, {:invalid_opencode_profile_command, profile_name, command}}

      command == [] ->
        {:error, {:invalid_opencode_profile_command, profile_name, command}}

      Enum.all?(command, &(is_binary(&1) and String.trim(&1) != "")) ->
        {:ok, command}

      true ->
        {:error, {:invalid_opencode_profile_command, profile_name, command}}
    end
  end

  defp profile_model(profile, base_model, profile_name) do
    case prompt_model(Map.get(profile, "model", base_model)) do
      {:ok, model} ->
        {:ok, model}

      {:error, {:invalid_opencode_model, model}} ->
        {:error, {:invalid_opencode_profile_model, profile_name, model}}
    end
  end

  @impl true
  @spec send_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_turn(session, prompt, _issue, opts) when is_binary(prompt) do
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)

    with {:ok, body} <- prompt_body(prompt, session.runner_config, session.execution_profile),
         {:ok, progress_stream} <- start_progress_stream(session) do
      timeout_ms = session_turn_timeout(session, opts)
      request_timeout_ms = timeout_ms + session.client.read_timeout_ms

      emit_session_started_once(session, on_event)
      emit_event(on_event, :turn_started, session, %{prompt: prompt})

      task = start_turn_task(session, body, request_timeout_ms, progress_stream, opts)

      await_turn(session, task, on_event, timeout_ms)
    else
      {:error, {:progress_stream_failed, _reason} = reason} ->
        fail_turn(session, on_event, reason)
    end
  end

  defp start_turn_task(session, body, request_timeout_ms, progress_stream, opts) do
    owner = self()
    ref = make_ref()
    on_result_sent = Keyword.get(opts, :on_turn_task_result_sent)

    {:ok, pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        receive do
          {:start_turn_request, ^ref} ->
            result =
              request(
                session.client,
                :post,
                "/session/#{session.session_id}/message",
                body,
                request_timeout_ms
              )

            send(owner, {ref, result})
            notify_turn_task_result_sent(on_result_sent, ref)
        end
      end)

    monitor_ref = Process.monitor(pid)
    send(pid, {:start_turn_request, ref})
    %{pid: pid, ref: ref, monitor_ref: monitor_ref, progress_stream: progress_stream}
  end

  defp notify_turn_task_result_sent(callback, ref) when is_function(callback, 1), do: callback.(ref)
  defp notify_turn_task_result_sent(_callback, _ref), do: :ok

  defp start_progress_stream(session) do
    owner = self()
    ref = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        run_progress_stream(session.client, session.session_id, owner, ref)
      end)

    stream = %{pid: pid, ref: ref, monitor_ref: Process.monitor(pid)}
    await_progress_stream_start(stream, session.client.read_timeout_ms)
  end

  defp await_progress_stream_start(stream, timeout_ms) do
    receive do
      {stream_ref, :ready} when stream_ref == stream.ref ->
        {:ok, stream}

      {stream_ref, {:error, reason}} when stream_ref == stream.ref ->
        await_progress_stream_shutdown(stream)
        {:error, {:progress_stream_failed, reason}}

      {:DOWN, monitor_ref, :process, pid, reason}
      when monitor_ref == stream.monitor_ref and pid == stream.pid ->
        drain_progress_stream_messages(stream)
        {:error, {:progress_stream_failed, {:stream_process_exit, reason}}}
    after
      timeout_ms ->
        shutdown_progress_stream(stream)
        {:error, {:progress_stream_failed, :connect_timeout}}
    end
  end

  defp run_progress_stream(client, session_id, owner, ref) do
    initial_state = %{
      assistant_message_ids: MapSet.new(),
      buffer: "",
      ready?: false,
      session_id: session_id,
      workspace: client.workspace
    }

    into = fn chunk, request_response ->
      stream_progress_chunk(chunk, request_response, initial_state, owner, ref)
    end

    result =
      Req.get(
        client.base_url <> "/global/event",
        headers: [{"accept", "text/event-stream"} | client.headers],
        params: [directory: client.workspace],
        retry: false,
        receive_timeout: :infinity,
        connect_options: [timeout: client.read_timeout_ms],
        into: into
      )

    case result do
      {:ok, %Req.Response{status: status, private: private}} when status in 200..299 ->
        unless Map.has_key?(private, :symphony_progress_stream_error) do
          send(owner, {ref, {:error, :stream_closed}})
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        send(owner, {ref, {:error, {:http_error, status, body}}})

      {:error, reason} ->
        send(owner, {ref, {:error, {:http_request_failed, reason}}})
    end
  end

  defp stream_progress_chunk(
         {:data, data},
         {request, response},
         initial_state,
         owner,
         ref
       ) do
    state = Map.get(response.private, :symphony_progress_stream, initial_state)

    case consume_progress_data(state, data) do
      {:ok, next_state, progress_events} ->
        if not state.ready? and next_state.ready?, do: send(owner, {ref, :ready})

        Enum.each(progress_events, fn {native, payload} ->
          send(owner, {ref, {:progress, native, payload}})
        end)

        response =
          %{response | private: Map.put(response.private, :symphony_progress_stream, next_state)}

        {:cont, {request, response}}

      {:error, reason} ->
        send(owner, {ref, {:error, reason}})

        response =
          %{response | private: Map.put(response.private, :symphony_progress_stream_error, reason)}

        {:halt, {request, response}}
    end
  end

  defp consume_progress_data(state, data) when is_binary(data) do
    parts =
      (state.buffer <> data)
      |> String.replace("\r\n", "\n")
      |> String.split("\n\n")

    buffer = List.last(parts)
    frames = Enum.drop(parts, -1)
    state = %{state | buffer: buffer}

    Enum.reduce_while(frames, {:ok, state, []}, fn frame, {:ok, state, progress_events} ->
      case consume_progress_frame(state, frame) do
        {:ok, next_state, nil} ->
          {:cont, {:ok, next_state, progress_events}}

        {:ok, next_state, progress_event} ->
          {:cont, {:ok, next_state, [progress_event | progress_events]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, next_state, progress_events} ->
        {:ok, next_state, Enum.reverse(progress_events)}

      {:error, _reason} = error ->
        error
    end
  end

  defp consume_progress_frame(state, frame) do
    data =
      frame
      |> String.split("\n")
      |> Enum.flat_map(fn
        "data:" <> line -> [String.trim_leading(line)]
        _other -> []
      end)
      |> Enum.join("\n")

    case data do
      "" -> {:ok, state, nil}
      data -> decode_progress_frame(state, data)
    end
  end

  defp decode_progress_frame(state, data) do
    case Jason.decode(data) do
      {:ok, %{"payload" => %{"type" => type} = native_payload} = native}
      when is_binary(type) ->
        state = %{state | ready?: true}
        {next_state, payload} = progress_payload(state, native, native_payload)
        {:ok, next_state, if(payload, do: {native, payload})}

      {:ok, _invalid} ->
        {:error, :invalid_event_envelope}

      {:error, _reason} ->
        {:error, :invalid_event_json}
    end
  end

  defp progress_payload(
         state,
         %{"directory" => workspace},
         %{
           "type" => "message.updated",
           "properties" => %{
             "info" => %{
               "id" => message_id,
               "role" => "assistant",
               "sessionID" => session_id
             }
           }
         }
       )
       when workspace == state.workspace and session_id == state.session_id and
              is_binary(message_id) do
    next_state = %{
      state
      | assistant_message_ids: MapSet.put(state.assistant_message_ids, message_id)
    }

    {next_state,
     %{
       kind: :assistant_message,
       message_id: message_id,
       source: :opencode_global_event
     }}
  end

  defp progress_payload(
         state,
         %{"directory" => workspace},
         %{
           "type" => "message.part.updated",
           "properties" => %{
             "part" =>
               %{
                 "id" => part_id,
                 "messageID" => message_id,
                 "sessionID" => session_id,
                 "type" => part_type
               } = part
           }
         }
       )
       when workspace == state.workspace and session_id == state.session_id and
              is_binary(part_id) and is_binary(message_id) and is_binary(part_type) do
    if MapSet.member?(state.assistant_message_ids, message_id) and
         part_type in [
           "text",
           "reasoning",
           "tool",
           "step-start",
           "step-finish",
           "retry",
           "patch"
         ] do
      {state, progress_part_payload(part, part_id, message_id, part_type)}
    else
      {state, nil}
    end
  end

  defp progress_payload(
         state,
         %{"directory" => workspace},
         %{
           "type" => "session.status",
           "properties" => %{
             "sessionID" => session_id,
             "status" => %{"type" => "retry", "attempt" => attempt}
           }
         }
       )
       when workspace == state.workspace and session_id == state.session_id and
              is_integer(attempt) do
    {state,
     %{
       attempt: attempt,
       kind: :session_retry,
       source: :opencode_global_event
     }}
  end

  defp progress_payload(state, _native, _native_payload), do: {state, nil}

  defp progress_part_payload(part, part_id, message_id, "tool") do
    state = Map.get(part, "state", %{})

    %{
      call_id: Map.get(part, "callID"),
      kind: :tool_activity,
      message_id: message_id,
      part_id: part_id,
      source: :opencode_global_event,
      status: Map.get(state, "status"),
      tool: Map.get(part, "tool")
    }
  end

  defp progress_part_payload(_part, part_id, message_id, part_type) do
    %{
      kind: :message_part,
      message_id: message_id,
      part_id: part_id,
      part_type: part_type,
      source: :opencode_global_event
    }
  end

  @impl true
  @spec stop(session()) :: :ok | {:error, term()}
  def stop(session) do
    abort_session(session)
    request_for_stop(session, :delete, "/session/#{session.session_id}")
    request_for_stop(session, :post, "/instance/dispose")
    process_cleanup = ProcessSupervisor.stop(session.process)
    stop_state(session.state)
    if session.config_overlay, do: File.rm_rf(session.config_overlay)
    process_cleanup
  end

  @impl true
  @spec capabilities(term()) :: map()
  def capabilities(_runner_config) do
    %{
      adapter: @runtime,
      client_side_tools: ["linear_graphql"],
      continuation_turns: true,
      unattended_permissions: true
    }
  end

  defp ensure_local_worker(nil), do: :ok
  defp ensure_local_worker(""), do: :ok

  defp ensure_local_worker(worker_host) do
    {:error, {:unsupported_remote_runner, "opencode_server", worker_host}}
  end

  defp validate_loopback_hostname(hostname) when hostname in @loopback_hosts, do: :ok
  defp validate_loopback_hostname(hostname), do: {:error, {:unsupported_opencode_hostname, hostname}}

  defp launch(workspace, runner, execution_profile, server_auth) do
    with {:ok, port_argument} <- launch_port(runner["hostname"], runner["port"]),
         {:ok, config_overlay} <- prepare_config_overlay(workspace, runner) do
      case ProcessSupervisor.start(
             execution_profile.command ++
               ["--hostname", runner["hostname"], "--port", port_argument],
             cd: workspace,
             env: launch_env(runner, server_auth, config_overlay),
             line: @line_bytes
           ) do
        {:ok, process} ->
          {:ok, {process, config_overlay}}

        {:error, _reason} = error ->
          File.rm_rf(config_overlay)
          error
      end
    end
  end

  defp launch_env(runner, server_auth, config_overlay) do
    allowed =
      inherited_env()
      |> Map.merge(%{
        "OPENCODE_CONFIG_DIR" => config_overlay,
        "OPENCODE_SERVER_PASSWORD" => Map.get(server_auth, "password") || false,
        "OPENCODE_SERVER_USERNAME" => Map.get(server_auth, "username") || false
      })
      |> Map.merge(provider_env(runner))

    System.get_env()
    |> Map.new(fn {key, _value} -> {key, false} end)
    |> Map.merge(allowed)
  end

  defp inherited_env do
    Enum.reduce(@inherited_env_keys, %{}, fn key, env ->
      case System.get_env(key) do
        value when is_binary(value) and value != "" -> Map.put(env, key, value)
        _missing -> env
      end
    end)
  end

  defp provider_env(_runner) do
    Enum.reduce(@provider_env_keys, %{}, fn key, env ->
      case System.get_env(key) do
        value when is_binary(value) and value != "" -> Map.put(env, key, value)
        _missing -> env
      end
    end)
  end

  defp prepare_config_overlay(workspace, runner) do
    overlay_root = Path.join(workspace, ".symphony")
    overlay_parent = Path.join(overlay_root, "opencode")
    overlay = Path.join(overlay_parent, "config-#{System.unique_integer([:positive])}")
    source = runner["config_path"]

    with :ok <- ensure_overlay_directory(overlay_root),
         :ok <- ensure_overlay_directory(overlay_parent),
         :ok <- ensure_overlay_directory(overlay),
         {:ok, content} <- config_content(runner["config_content"], source),
         {:ok, rendered} <- render_config(content, runner["permissions"]),
         :ok <- File.write(Path.join(overlay, "opencode.json"), rendered) do
      {:ok, overlay}
    else
      {:error, reason} -> {:error, {:opencode_config_overlay_failed, reason}}
    end
  end

  defp ensure_overlay_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, _stat} ->
        {:error, {:unsafe_config_overlay_parent, path}}

      {:error, :enoent} ->
        case File.mkdir(path) do
          :ok -> :ok
          {:error, :eexist} -> ensure_overlay_directory(path)
          {:error, reason} -> {:error, {:config_overlay_directory_create_failed, path, reason}}
        end

      {:error, reason} ->
        {:error, {:config_overlay_directory_check_failed, path, reason}}
    end
  end

  defp config_content(nil, nil), do: {:ok, %{}}
  defp config_content(nil, path) when is_binary(path), do: File.read(path)
  defp config_content(content, _path), do: {:ok, content}

  defp render_config(content, permissions) when is_map(content) do
    Jason.encode(Map.put(content, "permission", permissions || %{*: "deny"}))
  end

  defp render_config(content, permissions) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} when is_map(decoded) -> render_config(decoded, permissions)
      _invalid -> {:ok, content}
    end
  end

  defp render_config(_content, _permissions), do: {:error, :invalid_config_content}

  defp launch_port(_hostname, port) when is_integer(port), do: {:ok, Integer.to_string(port)}

  defp launch_port(hostname, "auto") do
    options =
      case hostname do
        "::1" -> [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}]
        _ipv4_loopback -> [ip: {127, 0, 0, 1}]
      end

    case :gen_tcp.listen(0, [:binary, active: false] ++ options) do
      {:ok, socket} ->
        result =
          case :inet.sockname(socket) do
            {:ok, {_address, port}} -> {:ok, Integer.to_string(port)}
            {:error, reason} -> {:error, {:port_allocation_failed, reason}}
          end

        :ok = :gen_tcp.close(socket)
        result

      {:error, reason} ->
        {:error, {:port_allocation_failed, reason}}
    end
  end

  defp resolve_server_auth(nil), do: {:ok, %{}}

  defp resolve_server_auth(%{"password" => password} = auth) when is_binary(password) do
    with {:ok, resolved_password} <- resolve_secret(password) do
      {:ok, Map.put(auth, "password", resolved_password)}
    end
  end

  defp resolve_server_auth(_auth), do: {:ok, %{}}

  defp resolve_secret("env:" <> variable) do
    case Regex.run(@secret_ref_pattern, "env:" <> variable, capture: :all_but_first) do
      [^variable] ->
        case System.get_env(variable) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _missing -> {:error, {:auth_missing, variable}}
        end

      _invalid ->
        {:error, {:invalid_secret_reference, "env:" <> variable}}
    end
  end

  defp resolve_secret(value) when is_binary(value) and value != "", do: {:ok, value}
  defp resolve_secret(_value), do: {:ok, nil}

  defp await_ready(process, workspace, issue, runner, server_auth, opts) do
    startup_timeout_ms = Keyword.get(opts, :startup_timeout_ms, runner["startup_timeout_ms"])

    case ProcessSupervisor.await_startup(process, startup_timeout_ms, fn process, timeout ->
           initialize_server(process, workspace, issue, runner, server_auth, timeout)
         end) do
      {:ok, {client, %{"id" => session_id} = session_info}} when is_binary(session_id) ->
        {:ok, client, session_info}

      {:ok, {_client, session_info}} ->
        {:error, {:startup_failed, {:invalid_session_response, session_info}}}

      {:error, _reason} = error ->
        error
    end
  end

  defp initialize_server(process, workspace, issue, runner, server_auth, timeout) do
    with {:ok, client} <- await_health(process, workspace, runner, server_auth, timeout),
         {:ok, session_info} <-
           request(client, :post, "/session", %{"title" => session_title(issue)}, timeout.()) do
      {:ok, {client, session_info}}
    end
  end

  defp session_title(%{identifier: identifier}) when is_binary(identifier), do: "Symphony #{identifier}"
  defp session_title(_issue), do: "Symphony"

  defp await_health(process, workspace, runner, server_auth, timeout) do
    await_health_loop(process, nil, workspace, runner, server_auth, timeout, "")
  end

  defp await_health_loop(process, client, workspace, runner, server_auth, timeout, pending_output) do
    remaining_ms = timeout.()

    cond do
      remaining_ms <= 0 ->
        {:error, :response_timeout}

      client ->
        case health_check(client, min(remaining_ms, client.read_timeout_ms)) do
          :ok ->
            {:ok, client}

          {:error, {:http_error, 401, _body}} ->
            {:error, {:auth_missing, :server}}

          _retry ->
            receive_startup_output(
              process,
              client,
              workspace,
              runner,
              server_auth,
              timeout,
              pending_output,
              remaining_ms
            )
        end

      true ->
        receive_startup_output(process, client, workspace, runner, server_auth, timeout, pending_output, remaining_ms)
    end
  end

  defp receive_startup_output(
         process,
         client,
         workspace,
         runner,
         server_auth,
         timeout,
         pending_output,
         remaining_ms
       ) do
    port = ProcessSupervisor.port(process)

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        output = pending_output <> to_string(chunk)
        client = client || client_from_output(output, workspace, runner, server_auth)
        await_health_loop(process, client, workspace, runner, server_auth, timeout, "")

      {^port, {:data, {:noeol, chunk}}} ->
        output = pending_output <> to_string(chunk)
        client = client || client_from_output(output, workspace, runner, server_auth)
        await_health_loop(process, client, workspace, runner, server_auth, timeout, output)

      {^port, {:exit_status, status}} ->
        {:error, {:server_exit, status}}
    after
      min(remaining_ms, @blocking_poll_interval_ms) ->
        await_health_loop(process, client, workspace, runner, server_auth, timeout, pending_output)
    end
  end

  defp client_from_output(output, workspace, runner, server_auth) do
    case Regex.run(~r/opencode server listening on http:\/\/(?:\[[^\]]+\]|[^:\s]+):(\d+)/, output, capture: :all_but_first) do
      [port_text] ->
        port = String.to_integer(port_text)

        if runner["port"] in ["auto", port] do
          build_client(runner["hostname"], port, workspace, server_auth, runner)
        end

      _no_port ->
        nil
    end
  end

  defp build_client(hostname, port, workspace, server_auth, runner) do
    base_url = "http://#{url_hostname(hostname)}:#{port}"

    %{
      base_url: base_url,
      headers: client_headers(workspace, server_auth),
      read_timeout_ms: runner["read_timeout_ms"],
      workspace: workspace
    }
  end

  defp url_hostname(hostname) when is_binary(hostname) do
    if String.contains?(hostname, ":"), do: "[#{hostname}]", else: hostname
  end

  defp client_headers(workspace, server_auth) do
    [{"accept", "application/json"}, {"x-opencode-directory", workspace}]
    |> maybe_put_authorization(server_auth)
  end

  defp maybe_put_authorization(headers, %{"password" => password} = auth)
       when is_binary(password) and password != "" do
    username = Map.get(auth, "username") || "opencode"
    [{"authorization", "Basic " <> Base.encode64("#{username}:#{password}")} | headers]
  end

  defp maybe_put_authorization(headers, _server_auth), do: headers

  defp health_check(client, timeout_ms) do
    case request(client, :get, "/global/health", :no_body, timeout_ms) do
      {:ok, %{"healthy" => true}} -> :ok
      other -> other
    end
  end

  defp prompt_body(prompt, runner, execution_profile) do
    body = %{"parts" => [%{"type" => "text", "text" => prompt}]}
    body = if execution_profile.model, do: Map.put(body, "model", execution_profile.model), else: body
    body = if is_binary(runner["agent"]), do: Map.put(body, "agent", runner["agent"]), else: body
    {:ok, body}
  end

  defp prompt_model(nil), do: {:ok, nil}

  defp prompt_model(model) when is_binary(model) do
    case model |> String.trim() |> String.split("/", parts: 2) do
      [provider_id, model_id] when provider_id != "" and model_id != "" ->
        {:ok, %{"providerID" => provider_id, "modelID" => model_id}}

      _invalid ->
        {:error, {:invalid_opencode_model, model}}
    end
  end

  defp prompt_model(model), do: {:error, {:invalid_opencode_model, model}}

  defp await_turn(session, task, on_event, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    await_turn_loop(session, task, on_event, deadline_ms)
  end

  defp await_turn_loop(session, task, on_event, deadline_ms),
    do: await_turn_loop(session, task, on_event, deadline_ms, 0)

  defp await_turn_loop(session, task, on_event, deadline_ms, drain_count) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      case receive_turn_task(task, 0) do
        :pending -> finish_timed_out_turn(session, task, on_event)
        task_result -> handle_turn_task(session, task, on_event, task_result)
      end
    else
      port = ProcessSupervisor.port(session.process)
      wait_ms = min(remaining_ms, @blocking_poll_interval_ms)
      task_ref = task.ref
      monitor_ref = task.monitor_ref
      progress_ref = task.progress_stream.ref
      progress_monitor_ref = task.progress_stream.monitor_ref
      progress_pid = task.progress_stream.pid

      receive do
        {^task_ref, result} ->
          Process.demonitor(monitor_ref, [:flush])
          finish_turn_response(session, task, on_event, result)

        {:DOWN, ^monitor_ref, :process, _pid, reason} ->
          shutdown_progress_stream(task.progress_stream)
          fail_turn(session, on_event, {:request_process_exit, reason})

        {^progress_ref, {:progress, native, payload}} ->
          emit_event(on_event, :turn_progress, session, payload, native)
          continue_after_turn_activity(session, task, on_event, deadline_ms, drain_count + 1)

        {^progress_ref, {:error, reason}} ->
          shutdown_turn_task(task)
          fail_turn(session, on_event, {:progress_stream_failed, reason})

        {:DOWN, ^progress_monitor_ref, :process, ^progress_pid, reason} ->
          shutdown_request_task(task)
          drain_progress_stream_messages(task.progress_stream)
          fail_turn(session, on_event, {:progress_stream_failed, {:stream_process_exit, reason}})

        {^port, {:data, {:eol, _chunk}}} ->
          continue_after_turn_activity(session, task, on_event, deadline_ms, drain_count + 1)

        {^port, {:data, {:noeol, _chunk}}} ->
          continue_after_turn_activity(session, task, on_event, deadline_ms, drain_count + 1)

        {^port, {:exit_status, status}} ->
          shutdown_turn_task(task)
          fail_turn(session, on_event, {:server_exit, status})
      after
        wait_ms ->
          poll_blocking_request(session, task, on_event, deadline_ms)
      end
    end
  end

  defp continue_after_turn_activity(session, task, on_event, deadline_ms, drain_count)
       when drain_count < @output_drain_batch_size do
    await_turn_loop(session, task, on_event, deadline_ms, drain_count)
  end

  defp continue_after_turn_activity(session, task, on_event, deadline_ms, _drain_count) do
    service_turn_control(session, task, on_event, deadline_ms)
  end

  defp service_turn_control(session, task, on_event, deadline_ms) do
    port = ProcessSupervisor.port(session.process)
    task_ref = task.ref
    monitor_ref = task.monitor_ref

    receive do
      {^task_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        finish_turn_response(session, task, on_event, result)

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        shutdown_progress_stream(task.progress_stream)
        fail_turn(session, on_event, {:request_process_exit, reason})

      {^port, {:exit_status, status}} ->
        shutdown_turn_task(task)
        fail_turn(session, on_event, {:server_exit, status})
    after
      0 -> poll_blocking_request(session, task, on_event, deadline_ms)
    end
  end

  defp receive_turn_task(task, wait_ms) do
    task_ref = task.ref
    monitor_ref = task.monitor_ref

    receive do
      {^task_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        {:turn_task_completed, result}

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        {:turn_task_exited, reason}
    after
      wait_ms -> :pending
    end
  end

  defp handle_turn_task(session, task, on_event, {:turn_task_completed, result}),
    do: finish_turn_response(session, task, on_event, result)

  defp handle_turn_task(session, task, on_event, {:turn_task_exited, reason}) do
    shutdown_progress_stream(task.progress_stream)
    fail_turn(session, on_event, {:request_process_exit, reason})
  end

  defp finish_turn_response(session, task, on_event, result) do
    shutdown_progress_stream(task.progress_stream)
    drain_turn_output(session, System.monotonic_time(:millisecond) + @turn_output_drain_ms)
    handle_turn_response(session, on_event, result)
  end

  defp drain_turn_output(session, deadline_ms) do
    port = ProcessSupervisor.port(session.process)
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, _output}} -> drain_turn_output(session, deadline_ms)
    after
      remaining_ms -> :ok
    end
  end

  defp poll_blocking_request(session, task, on_event, deadline_ms) do
    case blocking_request(session, task, deadline_ms) do
      {:ok, nil} ->
        await_turn_loop(session, task, on_event, deadline_ms)

      {:ok, {reason, native_request}} ->
        finish_blocked_turn(session, task, on_event, reason, native_request)

      {:error, path, raw_reason} ->
        finish_blocking_poll_failed(session, task, on_event, path, raw_reason)

      task_result ->
        handle_turn_task(session, task, on_event, task_result)
    end
  end

  defp finish_timed_out_turn(session, task, on_event) do
    abort_session(session)
    shutdown_turn_task(task)
    fail_turn(session, on_event, :turn_timeout)
  end

  defp finish_blocked_turn(session, task, on_event, reason, native_request) do
    case receive_turn_task(task, 0) do
      :pending ->
        emit_event(on_event, :blocked, session, %{request: native_request}, native_request, nil, reason)
        abort_session(session)
        shutdown_turn_task(task)

        error =
          case reason do
            :operator_input_requested -> {:turn_input_required, native_request}
            :approval_required -> {:approval_required, native_request}
          end

        {:error, error}

      task_result ->
        handle_turn_task(session, task, on_event, task_result)
    end
  end

  defp finish_blocking_poll_failed(session, task, on_event, path, raw_reason) do
    case receive_turn_task(task, 0) do
      :pending ->
        abort_session(session)
        shutdown_turn_task(task)
        fail_turn(session, on_event, {:blocking_poll_failed, path, raw_reason})

      task_result ->
        handle_turn_task(session, task, on_event, task_result)
    end
  end

  defp shutdown_turn_task(task) do
    shutdown_request_task(task)
    shutdown_progress_stream(task.progress_stream)
  end

  defp shutdown_request_task(task) do
    Process.exit(task.pid, :kill)
    await_turn_task_shutdown(task)
  end

  defp await_turn_task_shutdown(task) do
    task_ref = task.ref
    monitor_ref = task.monitor_ref

    receive do
      {^task_ref, _result} -> await_turn_task_shutdown(task)
      {:DOWN, ^monitor_ref, :process, _pid, _reason} -> drain_turn_task_messages(task)
    end
  end

  defp drain_turn_task_messages(task) do
    task_ref = task.ref
    monitor_ref = task.monitor_ref

    receive do
      {^task_ref, _result} -> drain_turn_task_messages(task)
      {:DOWN, ^monitor_ref, :process, _pid, _reason} -> drain_turn_task_messages(task)
    after
      0 -> :ok
    end
  end

  defp shutdown_progress_stream(stream) do
    Process.exit(stream.pid, :kill)
    await_progress_stream_shutdown(stream)
  end

  defp await_progress_stream_shutdown(stream) do
    receive do
      {stream_ref, _message} when stream_ref == stream.ref ->
        await_progress_stream_shutdown(stream)

      {:DOWN, monitor_ref, :process, pid, _reason}
      when monitor_ref == stream.monitor_ref and pid == stream.pid ->
        drain_progress_stream_messages(stream)
    end
  end

  defp drain_progress_stream_messages(stream) do
    receive do
      {stream_ref, _message} when stream_ref == stream.ref ->
        drain_progress_stream_messages(stream)

      {:DOWN, monitor_ref, :process, pid, _reason}
      when monitor_ref == stream.monitor_ref and pid == stream.pid ->
        drain_progress_stream_messages(stream)
    after
      0 -> :ok
    end
  end

  defp blocking_request(session, task, deadline_ms) do
    case pending_request(session, "/question", task, deadline_ms) do
      {:ok, nil} ->
        pending_permission_request(session, task, deadline_ms)

      {:ok, request} ->
        {:ok, {:operator_input_requested, request}}

      {:error, raw_reason} ->
        {:error, "/question", raw_reason}

      task_result ->
        task_result
    end
  end

  defp pending_permission_request(session, task, deadline_ms) do
    case pending_request(session, "/permission", task, deadline_ms) do
      {:ok, nil} -> {:ok, nil}
      {:ok, request} -> {:ok, {:approval_required, request}}
      {:error, raw_reason} -> {:error, "/permission", raw_reason}
      task_result -> task_result
    end
  end

  defp poll_timeout(session, deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)
    min(remaining_ms, min(session.client.read_timeout_ms, @stop_request_timeout_ms))
  end

  defp pending_request(session, path, task, deadline_ms),
    do: pending_request(session, path, task, deadline_ms, 0)

  defp pending_request(session, path, task, deadline_ms, retries) do
    case receive_turn_task(task, 0) do
      :pending ->
        case poll_timeout(session, deadline_ms) do
          0 ->
            {:ok, nil}

          timeout_ms ->
            session.client
            |> request(:get, path, :no_body, timeout_ms)
            |> handle_pending_response(session, path, task, deadline_ms, retries)
        end

      task_result ->
        task_result
    end
  end

  defp handle_pending_response({:ok, requests}, session, _path, _task, _deadline_ms, _retries)
       when is_list(requests) do
    if valid_blocking_queue?(requests) do
      {:ok, Enum.find(requests, &(Map.get(&1, "sessionID") == session.session_id))}
    else
      {:error, {:invalid_blocking_queue_response, requests}}
    end
  end

  defp handle_pending_response({:ok, response}, _session, _path, _task, _deadline_ms, _retries),
    do: {:error, {:invalid_blocking_queue_response, response}}

  defp handle_pending_response({:error, reason}, session, path, task, deadline_ms, retries) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    cond do
      remaining_ms == 0 ->
        {:ok, nil}

      not transient_poll_error?(reason) or retries >= @blocking_poll_max_retries ->
        {:error, reason}

      true ->
        case receive_turn_task(task, min(@blocking_poll_retry_delay_ms, remaining_ms)) do
          :pending -> pending_request(session, path, task, deadline_ms, retries + 1)
          task_result -> task_result
        end
    end
  end

  defp transient_poll_error?({:http_error, status, _response}) when status in 500..599, do: true
  defp transient_poll_error?({:http_request_failed, reason}), do: transient_connection_error?(reason)
  defp transient_poll_error?(_reason), do: false

  defp transient_connection_error?(reason) when is_map(reason) do
    case Map.get(reason, :reason) do
      nil -> false
      nested_reason -> transient_connection_error?(nested_reason)
    end
  end

  defp transient_connection_error?(reason)
       when reason in [
              :closed,
              :econnaborted,
              :econnrefused,
              :econnreset,
              :enetunreach,
              :etimedout,
              :nxdomain,
              :timeout
            ],
       do: true

  defp transient_connection_error?({tag, _reason}) when tag in [:failed_connect, :shutdown], do: true

  defp transient_connection_error?(_reason), do: false

  defp valid_blocking_queue?(requests) when is_list(requests) do
    Enum.all?(requests, &(is_map(&1) and is_binary(Map.get(&1, "sessionID"))))
  end

  defp handle_turn_response(
         %{session_id: session_id} = session,
         on_event,
         {:ok,
          %{
            "info" =>
              %{
                "id" => message_id,
                "role" => "assistant",
                "sessionID" => session_id
              } = info,
            "parts" => parts
          } = response}
       )
       when is_binary(message_id) and is_list(parts) do
    usage = cumulative_usage(session, info)

    case info["error"] do
      %{} = error ->
        fail_turn(session, on_event, {:turn_failed, error}, response, usage)

      _no_error ->
        Enum.each(parts, &emit_part(on_event, session, &1, usage))

        emit_event(
          on_event,
          :turn_completed,
          session,
          %{finish: info["finish"], message_id: message_id},
          response,
          usage
        )

        {:ok,
         %{
           response: response,
           session_id: "#{session.session_id}-#{message_id}",
           usage: usage
         }}
    end
  end

  defp handle_turn_response(session, on_event, {:ok, response}) do
    fail_turn(session, on_event, {:invalid_turn_response, response}, native_map(response))
  end

  defp handle_turn_response(session, on_event, {:error, reason}) do
    if auth_error?(reason) do
      emit_event(on_event, :blocked, session, %{reason: :auth_missing}, nil, nil, :auth_missing)
      {:error, {:auth_missing, :provider}}
    else
      fail_turn(session, on_event, reason)
    end
  end

  defp auth_error?({:http_error, 401, _body}), do: true
  defp auth_error?({:auth_missing, _source}), do: true
  defp auth_error?(_reason), do: false

  defp emit_part(on_event, session, %{"type" => "text", "text" => text} = part, usage)
       when is_binary(text) and text != "" do
    emit_event(on_event, :message_delta, session, %{text: text}, part, usage)
  end

  defp emit_part(on_event, session, %{"type" => "tool", "state" => state} = part, usage)
       when is_map(state) do
    payload = %{
      call_id: part["callID"],
      input: state["input"],
      status: state["status"],
      tool: part["tool"]
    }

    emit_event(on_event, :tool_call, session, payload, part, usage)

    case state["status"] do
      "completed" ->
        emit_event(
          on_event,
          :tool_result,
          session,
          Map.merge(payload, %{output: state["output"], success: true}),
          part,
          usage
        )

      "error" ->
        emit_event(
          on_event,
          :tool_result,
          session,
          Map.merge(payload, %{error: state["error"], success: false}),
          part,
          usage
        )

      _in_progress ->
        :ok
    end
  end

  defp emit_part(_on_event, _session, _part, _usage), do: :ok

  defp cumulative_usage(session, info) do
    case info["tokens"] do
      %{} = tokens ->
        input_tokens = usage_integer(tokens["input"])
        output_tokens = usage_integer(tokens["output"])
        reasoning_tokens = usage_integer(tokens["reasoning"])
        cache_tokens = tokens["cache"] || %{}
        cache_read_tokens = usage_integer(cache_tokens["read"])
        cache_write_tokens = usage_integer(cache_tokens["write"])
        total_tokens = input_tokens + output_tokens
        cost = usage_number(info["cost"])

        Agent.get_and_update(session.state, fn state ->
          usage = state.usage

          cumulative = %{
            "cache_read_tokens" => usage["cache_read_tokens"] + cache_read_tokens,
            "cache_write_tokens" => usage["cache_write_tokens"] + cache_write_tokens,
            "cost" => usage["cost"] + cost,
            "input_tokens" => usage["input_tokens"] + input_tokens,
            "output_tokens" => usage["output_tokens"] + output_tokens,
            "reasoning_tokens" => usage["reasoning_tokens"] + reasoning_tokens,
            "total_tokens" => usage["total_tokens"] + total_tokens
          }

          {cumulative, %{state | usage: cumulative}}
        end)

      _no_usage ->
        nil
    end
  end

  defp usage_integer(value) when is_integer(value) and value >= 0, do: value
  defp usage_integer(_value), do: 0

  defp usage_number(value) when is_number(value) and value >= 0, do: value
  defp usage_number(_value), do: 0

  defp emit_session_started_once(session, on_event) do
    should_emit? =
      Agent.get_and_update(session.state, fn state ->
        {not state.session_started?, %{state | session_started?: true}}
      end)

    if should_emit? do
      emit_event(on_event, :session_started, session, %{workspace: session.workspace})
    end
  end

  defp fail_turn(session, on_event, reason, native \\ nil, usage \\ nil) do
    emit_event(on_event, :turn_failed, session, %{reason: reason}, native, usage)
    {:error, reason}
  end

  defp emit_event(on_event, event_type, session, payload, native \\ nil, usage \\ nil, reason \\ nil) do
    {:ok, event} =
      Event.new(event_type,
        runtime: @runtime,
        session_id: session.session_id,
        native: native,
        usage: usage,
        payload: payload,
        reason: reason
      )

    on_event.(event)
  end

  defp native_map(value) when is_map(value), do: value
  defp native_map(_value), do: nil

  defp abort_session(session) do
    request_for_stop(session, :post, "/session/#{session.session_id}/abort")
  end

  defp request_for_stop(session, method, path) do
    request(session.client, method, path, :no_body, @stop_request_timeout_ms)
    :ok
  end

  defp stop_state(state) when is_pid(state) do
    if Process.alive?(state), do: Agent.stop(state, :normal, @stop_request_timeout_ms)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp request(client, method, path, body, timeout_ms) do
    timeout_ms = max(timeout_ms, 1)

    options = [
      method: method,
      url: client.base_url <> path,
      headers: client.headers,
      params: [directory: client.workspace],
      retry: false,
      receive_timeout: timeout_ms,
      connect_options: [timeout: timeout_ms]
    ]

    options = if body == :no_body, do: options, else: Keyword.put(options, :json, body)

    case Req.request(options) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        {:error, {:http_request_failed, reason}}
    end
  end
end
