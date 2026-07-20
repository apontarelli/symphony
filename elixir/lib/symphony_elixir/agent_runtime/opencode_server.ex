defmodule SymphonyElixir.AgentRuntime.OpenCodeServer do
  @moduledoc """
  Local HTTP adapter for `opencode serve`.

  The adapter owns one supervised server process and one OpenCode session. Turns
  use the synchronous message endpoint while polling OpenCode's permission and
  question queues so unattended blocking requests become runner-neutral events.
  """

  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.AgentRuntime.Event
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.ProcessSupervisor

  @runtime :opencode_server
  @line_bytes 16_384
  @blocking_poll_interval_ms 50
  @stop_request_timeout_ms 250
  @output_drain_batch_size 64
  @loopback_hosts ["127.0.0.1", "localhost", "::1"]

  @type client :: %{
          base_url: String.t(),
          headers: [{String.t(), String.t()}],
          read_timeout_ms: pos_integer(),
          workspace: Path.t()
        }

  @type session :: %{
          client: client(),
          process: ProcessSupervisor.t(),
          runner_config: map(),
          session_id: String.t(),
          state: pid(),
          turn_timeout_ms: pos_integer(),
          workspace: Path.t()
        }

  @impl true
  @spec start(Path.t(), map(), keyword()) :: {:ok, session()} | {:error, term()}
  def start(workspace, issue, opts) do
    runner = Keyword.get(opts, :runner_config, %{})

    with :ok <- ensure_local_worker(Keyword.get(opts, :worker_host)),
         {:ok, workspace} <- PathSafety.canonicalize(workspace),
         :ok <- validate_loopback_hostname(runner["hostname"]),
         {:ok, process} <- launch(workspace, runner),
         {:ok, client, session_info} <- await_ready(process, workspace, issue, runner, opts),
         {:ok, state} <-
           Agent.start_link(fn ->
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
           end) do
      {:ok,
       %{
         client: client,
         process: process,
         runner_config: runner,
         session_id: session_info["id"],
         state: state,
         turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms, runner["turn_timeout_ms"]),
         workspace: workspace
       }}
    end
  end

  @impl true
  @spec send_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_turn(session, prompt, _issue, opts) when is_binary(prompt) do
    with {:ok, body} <- prompt_body(prompt, session.runner_config) do
      on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
      timeout_ms = Keyword.get(opts, :turn_timeout_ms, session.turn_timeout_ms)
      request_timeout_ms = timeout_ms + session.client.read_timeout_ms

      emit_session_started_once(session, on_event)
      emit_event(on_event, :turn_started, session, %{prompt: prompt})

      task =
        Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
          request(
            session.client,
            :post,
            "/session/#{session.session_id}/message",
            body,
            request_timeout_ms
          )
        end)

      await_turn(session, task, on_event, timeout_ms)
    end
  end

  @impl true
  @spec stop(session()) :: :ok
  def stop(session) do
    abort_session(session)
    request_for_stop(session, :delete, "/session/#{session.session_id}")
    request_for_stop(session, :post, "/instance/dispose")
    ProcessSupervisor.stop(session.process)
    stop_state(session.state)
    :ok
  end

  @impl true
  @spec capabilities(term()) :: map()
  def capabilities(_runner_config) do
    %{
      adapter: @runtime,
      client_side_tools: [],
      continuation_turns: true
    }
  end

  defp ensure_local_worker(nil), do: :ok
  defp ensure_local_worker(""), do: :ok

  defp ensure_local_worker(worker_host) do
    {:error, {:unsupported_remote_runner, "opencode_server", worker_host}}
  end

  defp validate_loopback_hostname(hostname) when hostname in @loopback_hosts, do: :ok
  defp validate_loopback_hostname(hostname), do: {:error, {:unsupported_opencode_hostname, hostname}}

  defp launch(workspace, runner) do
    with {:ok, port_argument} <- launch_port(runner["hostname"], runner["port"]) do
      argv =
        runner
        |> Map.fetch!("command")
        |> Kernel.++([
          "--hostname",
          runner["hostname"],
          "--port",
          port_argument
        ])

      ProcessSupervisor.start(argv,
        cd: workspace,
        env: server_auth_env(runner["server_auth"]),
        line: @line_bytes
      )
    end
  end

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

  defp server_auth_env(%{"password" => password} = auth) when is_binary(password) and password != "" do
    %{
      "OPENCODE_SERVER_PASSWORD" => password,
      "OPENCODE_SERVER_USERNAME" => Map.get(auth, "username") || "opencode"
    }
  end

  defp server_auth_env(_auth),
    do: %{"OPENCODE_SERVER_PASSWORD" => false, "OPENCODE_SERVER_USERNAME" => false}

  defp await_ready(process, workspace, issue, runner, opts) do
    startup_timeout_ms = Keyword.get(opts, :startup_timeout_ms, runner["startup_timeout_ms"])

    case ProcessSupervisor.await_startup(process, startup_timeout_ms, fn process, timeout ->
           initialize_server(process, workspace, issue, runner, timeout)
         end) do
      {:ok, {client, %{"id" => session_id} = session_info}} when is_binary(session_id) ->
        {:ok, client, session_info}

      {:ok, {_client, session_info}} ->
        ProcessSupervisor.stop(process)
        {:error, {:startup_failed, {:invalid_session_response, session_info}}}

      {:error, _reason} = error ->
        error
    end
  end

  defp initialize_server(process, workspace, issue, runner, timeout) do
    with {:ok, client} <- await_health(process, workspace, runner, timeout),
         {:ok, session_info} <-
           request(client, :post, "/session", %{"title" => session_title(issue)}, timeout.()) do
      {:ok, {client, session_info}}
    end
  end

  defp session_title(%{identifier: identifier}) when is_binary(identifier), do: "Symphony #{identifier}"
  defp session_title(_issue), do: "Symphony"

  defp await_health(process, workspace, runner, timeout) do
    await_health_loop(process, nil, workspace, runner, timeout, "")
  end

  defp await_health_loop(process, client, workspace, runner, timeout, pending_output) do
    remaining_ms = timeout.()

    cond do
      remaining_ms <= 0 ->
        {:error, :response_timeout}

      client && healthy?(client, min(remaining_ms, client.read_timeout_ms)) ->
        {:ok, client}

      true ->
        receive_startup_output(process, client, workspace, runner, timeout, pending_output, remaining_ms)
    end
  end

  defp receive_startup_output(process, client, workspace, runner, timeout, pending_output, remaining_ms) do
    port = ProcessSupervisor.port(process)

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        output = pending_output <> to_string(chunk)
        client = client || client_from_output(output, workspace, runner)
        await_health_loop(process, client, workspace, runner, timeout, "")

      {^port, {:data, {:noeol, chunk}}} ->
        output = pending_output <> to_string(chunk)
        client = client || client_from_output(output, workspace, runner)
        await_health_loop(process, client, workspace, runner, timeout, output)

      {^port, {:exit_status, status}} ->
        {:error, {:server_exit, status}}
    after
      min(remaining_ms, @blocking_poll_interval_ms) ->
        await_health_loop(process, client, workspace, runner, timeout, pending_output)
    end
  end

  defp client_from_output(output, workspace, runner) do
    case Regex.run(~r/opencode server listening on http:\/\/(?:\[[^\]]+\]|[^:\s]+):(\d+)/, output, capture: :all_but_first) do
      [port_text] ->
        port = String.to_integer(port_text)

        if runner["port"] in ["auto", port] do
          build_client(runner["hostname"], port, workspace, runner)
        end

      _no_port ->
        nil
    end
  end

  defp build_client(hostname, port, workspace, runner) do
    base_url = "http://#{url_hostname(hostname)}:#{port}"

    %{
      base_url: base_url,
      headers: client_headers(workspace, runner["server_auth"]),
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

  defp healthy?(client, timeout_ms) do
    match?({:ok, %{"healthy" => true}}, request(client, :get, "/global/health", :no_body, timeout_ms))
  end

  defp prompt_body(prompt, runner) do
    with {:ok, model} <- prompt_model(runner["model"]) do
      body = %{"parts" => [%{"type" => "text", "text" => prompt}]}
      body = if model, do: Map.put(body, "model", model), else: body
      body = if is_binary(runner["agent"]), do: Map.put(body, "agent", runner["agent"]), else: body
      {:ok, body}
    end
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

  defp await_turn(session, task, on_event, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    await_turn_loop(session, task, on_event, deadline_ms)
  end

  defp await_turn_loop(session, task, on_event, deadline_ms),
    do: await_turn_loop(session, task, on_event, deadline_ms, 0)

  defp await_turn_loop(session, task, on_event, deadline_ms, output_count) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      finish_timed_out_turn(session, task, on_event)
    else
      port = ProcessSupervisor.port(session.process)
      wait_ms = min(remaining_ms, @blocking_poll_interval_ms)
      task_reference = task.ref

      receive do
        {^task_reference, result} ->
          Process.demonitor(task.ref, [:flush])
          handle_turn_response(session, on_event, result)

        {:DOWN, ^task_reference, :process, _pid, reason} ->
          fail_turn(session, on_event, {:request_process_exit, reason})

        {^port, {:data, {:eol, _chunk}}} ->
          continue_after_server_output(session, task, on_event, deadline_ms, output_count + 1)

        {^port, {:data, {:noeol, _chunk}}} ->
          continue_after_server_output(session, task, on_event, deadline_ms, output_count + 1)

        {^port, {:exit_status, status}} ->
          Task.shutdown(task, :brutal_kill)
          fail_turn(session, on_event, {:server_exit, status})
      after
        wait_ms ->
          poll_blocking_request(session, task, on_event, deadline_ms)
      end
    end
  end

  defp continue_after_server_output(session, task, on_event, deadline_ms, output_count)
       when output_count < @output_drain_batch_size do
    await_turn_loop(session, task, on_event, deadline_ms, output_count)
  end

  defp continue_after_server_output(session, task, on_event, deadline_ms, _output_count) do
    service_turn_control(session, task, on_event, deadline_ms)
  end

  defp service_turn_control(session, task, on_event, deadline_ms) do
    port = ProcessSupervisor.port(session.process)
    task_reference = task.ref

    receive do
      {^task_reference, result} ->
        Process.demonitor(task.ref, [:flush])
        handle_turn_response(session, on_event, result)

      {:DOWN, ^task_reference, :process, _pid, reason} ->
        fail_turn(session, on_event, {:request_process_exit, reason})

      {^port, {:exit_status, status}} ->
        Task.shutdown(task, :brutal_kill)
        fail_turn(session, on_event, {:server_exit, status})
    after
      0 -> poll_blocking_request(session, task, on_event, deadline_ms)
    end
  end

  defp poll_blocking_request(session, task, on_event, deadline_ms) do
    case blocking_request(session, deadline_ms) do
      nil -> await_turn_loop(session, task, on_event, deadline_ms)
      {reason, native_request} -> finish_blocked_turn(session, task, on_event, reason, native_request)
    end
  end

  defp finish_timed_out_turn(session, task, on_event) do
    abort_session(session)
    Task.shutdown(task, :brutal_kill)
    fail_turn(session, on_event, :turn_timeout)
  end

  defp finish_blocked_turn(session, task, on_event, reason, native_request) do
    emit_event(on_event, :blocked, session, %{request: native_request}, native_request, nil, reason)
    abort_session(session)
    Task.shutdown(task, :brutal_kill)

    error =
      case reason do
        :operator_input_requested -> {:turn_input_required, native_request}
        :approval_required -> {:approval_required, native_request}
      end

    {:error, error}
  end

  defp blocking_request(session, deadline_ms) do
    case pending_request(session, "/question", poll_timeout(session, deadline_ms)) do
      nil ->
        pending_permission_request(session, deadline_ms)

      request ->
        {:operator_input_requested, request}
    end
  end

  defp pending_permission_request(session, deadline_ms) do
    case poll_timeout(session, deadline_ms) do
      0 -> nil
      timeout_ms -> pending_permission_request(session, timeout_ms, :poll)
    end
  end

  defp pending_permission_request(session, timeout_ms, :poll) do
    case pending_request(session, "/permission", timeout_ms) do
      nil -> nil
      request -> {:approval_required, request}
    end
  end

  defp poll_timeout(session, deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)
    min(remaining_ms, min(session.client.read_timeout_ms, @stop_request_timeout_ms))
  end

  defp pending_request(session, path, timeout_ms) do
    case request(session.client, :get, path, :no_body, timeout_ms) do
      {:ok, requests} when is_list(requests) ->
        Enum.find(requests, &(Map.get(&1, "sessionID") == session.session_id))

      _unavailable ->
        nil
    end
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
    case info["error"] do
      %{} = error ->
        fail_turn(session, on_event, {:turn_failed, error}, response)

      _no_error ->
        usage = cumulative_usage(session, info)
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
    fail_turn(session, on_event, reason)
  end

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

  defp fail_turn(session, on_event, reason, native \\ nil) do
    emit_event(on_event, :turn_failed, session, %{reason: reason}, native)
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
