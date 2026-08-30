defmodule SymphonyElixir.AgentRuntime.OmpAcp do
  @moduledoc """
  ACP v1 adapter for the local `omp acp` server.

  One adapter session owns one OMP process, one ACP session, and one authenticated
  loopback MCP bridge. The OMP process receives no Linear credential.
  """

  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.AgentRuntime.{Event, OmpMcpBridge}
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{ExecutionContext, PathSafety, ProcessSupervisor}
  alias SymphonyElixir.ReviewRecords.Redaction

  @runtime :omp_acp
  @protocol_version 1
  @line_bytes 1_048_576
  @close_timeout_ms 250
  @thinking_values MapSet.new(~w(inherit off minimal low medium high xhigh max auto))

  @type session :: %{
          optional(:execution_context) => ExecutionContext.t(),
          bridge: OmpMcpBridge.t(),
          process: ProcessSupervisor.t(),
          runner_config: map(),
          session_dir: Path.t(),
          session_id: String.t(),
          state: pid(),
          turn_timeout_ms: pos_integer(),
          workspace: Path.t()
        }

  @impl true
  @spec start(ExecutionContext.t(), map(), keyword()) :: {:ok, session()} | {:error, term()}
  def start(%ExecutionContext{} = context, _issue, opts) do
    with :ok <- validate_start_options(opts),
         :ok <- validate_context(context),
         %{"kind" => "omp_acp"} = runner <- context.runner_config,
         :ok <- ensure_local_worker(context.worker_host),
         {:ok, workspace} <- canonical_workspace(context.workspace_path),
         {:ok, settings} <- resolve_settings(context, runner),
         {:ok, session_dir} <- create_session_dir(workspace, context.issue_identifier),
         {:ok, bridge} <- OmpMcpBridge.start(),
         {:ok, session} <-
           launch_session(
             bridge,
             workspace,
             session_dir,
             runner,
             settings,
             context.timeout_ms
           ) do
      {:ok, Map.put(session, :execution_context, context)}
    else
      %{"kind" => _other_kind} -> {:error, :unsupported_runner_kind}
      {:error, :invalid_context} -> {:error, :invalid_agent_runtime_context}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_agent_runtime_context}
    end
  end

  def start(_context, _issue, _opts), do: {:error, :invalid_agent_runtime_context}

  @impl true
  @spec send_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_turn(session, prompt, _issue, opts)
      when is_map(session) and is_binary(prompt) and is_list(opts) do
    with :ok <- validate_turn_options(opts),
         :ok <- validate_session(session),
         {:ok, on_event} <- event_handler(opts),
         {:ok, tool_executor} <- tool_executor(opts) do
      timeout_ms = turn_timeout(session, opts)
      OmpMcpBridge.set_tool_executor(session.bridge, tool_executor)

      emit_session_started_once(session, on_event)
      emit_event(on_event, :turn_started, session, %{prompt_bytes: byte_size(prompt)})
      prompt_turn(session, prompt, on_event, timeout_ms)
    end
  end

  def send_turn(_session, _prompt, _issue, _opts), do: {:error, :invalid_agent_runtime_options}

  @impl true
  @spec stop(session()) :: :ok | {:error, term()}
  def stop(%{process: process, bridge: bridge, state: state} = session) do
    close_session(session)

    [
      ProcessSupervisor.stop(process),
      OmpMcpBridge.stop(bridge),
      stop_state(state)
    ]
    |> Enum.reject(&(&1 == :ok))
    |> case do
      [] -> :ok
      [{:error, reason}] -> {:error, reason}
      errors -> {:error, {:agent_runtime_cleanup_failed, errors}}
    end
  end

  def stop(_session), do: {:error, :invalid_agent_runtime_session}

  @impl true
  @spec capabilities(map()) :: map()
  def capabilities(config) when is_map(config) do
    %{
      adapter: "omp_acp",
      client_tools: ["linear_graphql"],
      global_extensions: false,
      global_skills: false,
      local_only: true,
      model: config["model"],
      permission_policy: true,
      pinned: true,
      protocol: "acp-v1",
      session_resume: false
    }
  end

  def capabilities(_config), do: %{adapter: "omp_acp", local_only: true, pinned: true, protocol: "acp-v1"}

  defp validate_start_options([]), do: :ok
  defp validate_start_options(_opts), do: {:error, :invalid_agent_runtime_options}

  defp validate_turn_options(opts) do
    allowed = [:on_event, :tool_executor, :turn_timeout_ms]

    if Keyword.keyword?(opts) and length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         Enum.all?(Keyword.keys(opts), &(&1 in allowed)) and
         valid_turn_timeout?(Keyword.get(opts, :turn_timeout_ms)) do
      :ok
    else
      {:error, :invalid_agent_runtime_options}
    end
  end

  defp valid_turn_timeout?(nil), do: true
  defp valid_turn_timeout?(value), do: is_integer(value) and value > 0

  defp validate_context(context) do
    case ExecutionContext.validate(context) do
      :ok -> :ok
      {:error, :invalid_context} -> {:error, :invalid_context}
    end
  end

  defp validate_session(%{
         bridge: %OmpMcpBridge{},
         process: %ProcessSupervisor{},
         session_id: session_id,
         state: state,
         workspace: workspace
       })
       when is_binary(session_id) and session_id != "" and is_pid(state) and is_binary(workspace),
       do: :ok

  defp validate_session(_session), do: {:error, :invalid_agent_runtime_session}

  defp ensure_local_worker(nil), do: :ok
  defp ensure_local_worker(_worker_host), do: {:error, :remote_worker_not_supported}

  defp canonical_workspace(path) do
    with {:ok, canonical} <- PathSafety.canonicalize(path),
         true <- canonical == path do
      {:ok, canonical}
    else
      false -> {:error, :invalid_agent_runtime_context}
      {:error, _reason} -> {:error, :invalid_agent_runtime_context}
    end
  end

  defp resolve_settings(context, runner) do
    profile_name = context.execution_profile.name
    profile = get_in(runner, ["execution_profiles", profile_name]) || %{}
    command = context.execution_profile.command || runner["command"]
    model = context.execution_profile.model || runner["model"]
    thinking = normalize_thinking(context.execution_profile.reasoning_effort || profile["thinking"] || runner["thinking"])
    omp_profile = profile["profile"] || runner["profile"]

    with :ok <- validate_command(command),
         :ok <- validate_model(model),
         :ok <- validate_thinking(thinking),
         :ok <- validate_profile(omp_profile) do
      {:ok, %{command: command, model: model, thinking: thinking, profile: omp_profile}}
    end
  end

  defp validate_command(command) do
    cond do
      not valid_command?(command) -> {:error, {:invalid_omp_command, command}}
      "--no-extensions" not in command -> {:error, :omp_global_extensions_not_disabled}
      "--no-skills" not in command -> {:error, :omp_global_skills_not_disabled}
      true -> :ok
    end
  end

  defp validate_model(model) do
    if provider_model?(model), do: :ok, else: {:error, {:invalid_omp_model, model}}
  end

  defp validate_thinking(thinking) do
    if MapSet.member?(@thinking_values, thinking), do: :ok, else: {:error, {:invalid_omp_thinking, thinking}}
  end

  defp validate_profile(profile) do
    if non_empty_string?(profile), do: :ok, else: {:error, {:invalid_omp_profile, profile}}
  end

  defp valid_command?(command),
    do: is_list(command) and command != [] and Enum.all?(command, &non_empty_string?/1)

  defp provider_model?(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider, name] -> provider != "" and name != ""
      _invalid -> false
    end
  end

  defp provider_model?(_model), do: false
  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp normalize_thinking("none"), do: "off"
  defp normalize_thinking(value), do: value

  defp create_session_dir(workspace, issue_identifier) do
    session_segment =
      "#{String.downcase(issue_identifier)}-#{System.unique_integer([:positive, :monotonic])}"

    session_dir =
      Path.join([
        Path.dirname(workspace),
        ".symphony",
        "omp_sessions",
        session_segment
      ])

    with :ok <- File.mkdir_p(session_dir),
         :ok <- File.chmod(session_dir, 0o700),
         {:ok, canonical} <- PathSafety.canonicalize(session_dir),
         :ok <- validate_session_dir(canonical, workspace) do
      {:ok, canonical}
    else
      {:error, reason} -> {:error, {:omp_session_dir_failed, reason}}
    end
  end

  defp validate_session_dir(session_dir, workspace) do
    if inside_path?(session_dir, Path.dirname(workspace)) and not inside_path?(session_dir, workspace),
      do: :ok,
      else: {:error, :unsafe_path}
  end

  defp launch(command, workspace, session_dir, profile) do
    ProcessSupervisor.start(command,
      cd: workspace,
      env: %{
        "LINEAR_API_KEY" => false,
        "OMP_PROFILE" => profile,
        "PI_CODING_AGENT_SESSION_DIR" => session_dir
      },
      line: @line_bytes,
      stderr_to_stdout: false
    )
  end

  defp launch_session(bridge, workspace, session_dir, runner, settings, turn_timeout_ms) do
    case launch(settings.command, workspace, session_dir, settings.profile) do
      {:ok, process} ->
        initialize_session(
          process,
          bridge,
          workspace,
          session_dir,
          runner,
          settings,
          turn_timeout_ms
        )

      {:error, reason} ->
        case OmpMcpBridge.stop(bridge) do
          :ok -> {:error, {:startup_failed, reason}}
          {:error, cleanup_reason} -> {:error, {:startup_failed, reason, {:cleanup_failed, cleanup_reason}}}
        end
    end
  end

  defp inside_path?(path, root) do
    case Path.relative_to(path, root) do
      "." -> true
      ".." <> _rest -> false
      relative -> Path.type(relative) != :absolute
    end
  end

  defp initialize_session(process, bridge, workspace, session_dir, runner, settings, turn_timeout_ms) do
    deadline = monotonic_deadline(runner["startup_timeout_ms"])

    result =
      with {:ok, initialize} <-
             rpc_call(
               process,
               "initialize",
               %{
                 "protocolVersion" => @protocol_version,
                 "clientCapabilities" => %{
                   "fs" => %{"readTextFile" => false, "writeTextFile" => false},
                   "terminal" => false,
                   "auth" => %{"terminal" => false}
                 },
                 "clientInfo" => %{"name" => "symphony", "version" => "1"}
               },
               request_deadline(deadline, runner["read_timeout_ms"])
             ),
           :ok <- validate_initialize(initialize),
           {:ok, new_session} <-
             rpc_call(
               process,
               "session/new",
               %{
                 "cwd" => workspace,
                 "mcpServers" => [OmpMcpBridge.mcp_server(bridge)]
               },
               request_deadline(deadline, runner["read_timeout_ms"])
             ),
           {:ok, session_id} <- session_id(new_session),
           :ok <- configure_session(process, session_id, settings, deadline, runner["read_timeout_ms"]),
           {:ok, state} <- Agent.start_link(fn -> %{session_started?: false, usage: nil} end) do
        {:ok,
         %{
           bridge: bridge,
           process: process,
           runner_config: runner,
           session_dir: session_dir,
           session_id: session_id,
           state: state,
           turn_timeout_ms: turn_timeout_ms,
           workspace: workspace
         }}
      end

    case result do
      {:ok, _session} = ok -> ok
      {:error, reason} -> cleanup_failed_start(process, bridge, reason)
    end
  end

  defp validate_initialize(%{
         "protocolVersion" => @protocol_version,
         "agentCapabilities" => %{"mcpCapabilities" => %{"http" => true}}
       }),
       do: :ok

  defp validate_initialize(%{"protocolVersion" => version}),
    do: {:error, {:unsupported_acp_protocol, version}}

  defp validate_initialize(_response), do: {:error, :invalid_acp_initialize_response}

  defp session_id(%{"sessionId" => value}) when is_binary(value) and value != "", do: {:ok, value}
  defp session_id(_response), do: {:error, :invalid_acp_new_session_response}

  defp configure_session(process, session_id, settings, deadline, read_timeout_ms) do
    with {:ok, _model_response} <-
           set_config_option(process, session_id, "model", settings.model, request_deadline(deadline, read_timeout_ms)),
         {:ok, _thinking_response} <-
           set_config_option(process, session_id, "thinking", settings.thinking, request_deadline(deadline, read_timeout_ms)) do
      :ok
    end
  end

  defp set_config_option(process, session_id, config_id, value, deadline) do
    rpc_call(
      process,
      "session/set_config_option",
      %{"sessionId" => session_id, "configId" => config_id, "value" => value},
      deadline
    )
  end

  defp cleanup_failed_start(process, bridge, primary_reason) do
    primary_reason = Redaction.redact_secrets(primary_reason, [bridge.token])

    cleanup_errors =
      [ProcessSupervisor.stop(process), OmpMcpBridge.stop(bridge)]
      |> Enum.reject(&(&1 == :ok))

    case cleanup_errors do
      [] -> {:error, {:startup_failed, primary_reason}}
      errors -> {:error, {:startup_failed, primary_reason, {:cleanup_failed, errors}}}
    end
  end

  defp rpc_call(process, method, params, deadline) do
    request_id = System.unique_integer([:positive, :monotonic])

    with :ok <- send_message(process.port, rpc_request(request_id, method, params)) do
      await_response(process.port, request_id, deadline, "")
    end
  end

  defp await_response(port, request_id, deadline, buffered) do
    timeout = remaining_ms(deadline)

    if timeout == 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, {:eol, chunk}}} ->
          case decode_line(buffered <> chunk) do
            {:ok, %{"id" => ^request_id, "result" => result}} ->
              {:ok, result}

            {:ok, %{"id" => ^request_id, "error" => error}} ->
              {:error, {:response_error, error}}

            {:ok, %{"id" => _other_id}} ->
              await_response(port, request_id, deadline, "")

            {:ok, %{"method" => method, "id" => id}} ->
              send_rpc_error(port, id, -32_601, "Method not found")
              {:error, {:unsupported_acp_request, method}}

            {:ok, %{"method" => _notification}} ->
              await_response(port, request_id, deadline, "")

            {:error, reason} ->
              {:error, reason}
          end

        {^port, {:data, {:noeol, chunk}}} ->
          await_response(port, request_id, deadline, buffered <> chunk)

        {^port, {:exit_status, status}} ->
          {:error, {:runtime_exited, status}}
      after
        timeout -> {:error, :timeout}
      end
    end
  end

  defp prompt_turn(session, prompt, on_event, timeout_ms) do
    request_id = System.unique_integer([:positive, :monotonic])

    params = %{
      "sessionId" => session.session_id,
      "prompt" => [%{"type" => "text", "text" => prompt}]
    }

    case send_message(session.process.port, rpc_request(request_id, "session/prompt", params)) do
      :ok ->
        now = System.monotonic_time(:millisecond)
        turn_deadline = now + timeout_ms
        stall_timeout_ms = session.runner_config["stall_timeout_ms"]
        stall_deadline = if stall_timeout_ms == 0, do: turn_deadline, else: min(turn_deadline, now + stall_timeout_ms)

        await_turn(session, request_id, on_event, turn_deadline, stall_deadline, "")

      {:error, reason} ->
        fail_turn(session, on_event, reason)
    end
  end

  defp await_turn(session, request_id, on_event, turn_deadline, stall_deadline, buffered) do
    now = System.monotonic_time(:millisecond)
    deadline = min(turn_deadline, stall_deadline)
    timeout = max(deadline - now, 0)

    if timeout == 0 do
      reason = if turn_deadline <= stall_deadline, do: :turn_timeout, else: :stall_timeout
      cancel_session(session)
      fail_turn(session, on_event, {reason, session.session_id})
    else
      port = session.process.port

      receive do
        {^port, {:data, {:eol, chunk}}} ->
          handle_turn_line(
            session,
            request_id,
            on_event,
            turn_deadline,
            stall_deadline,
            buffered <> chunk
          )

        {^port, {:data, {:noeol, chunk}}} ->
          await_turn(
            session,
            request_id,
            on_event,
            turn_deadline,
            stall_deadline,
            buffered <> chunk
          )

        {^port, {:exit_status, status}} ->
          fail_turn(session, on_event, {:runtime_exited, status})
      after
        timeout ->
          reason = if turn_deadline <= stall_deadline, do: :turn_timeout, else: :stall_timeout
          cancel_session(session)
          fail_turn(session, on_event, {reason, session.session_id})
      end
    end
  end

  defp handle_turn_line(session, request_id, on_event, turn_deadline, stall_deadline, line) do
    case decode_line(line) do
      {:ok, %{"id" => ^request_id, "result" => result} = native} ->
        complete_turn(session, on_event, result, native)

      {:ok, %{"id" => ^request_id, "error" => error} = native} ->
        fail_turn(session, on_event, {:response_error, error}, native)

      {:ok, %{"method" => "session/update", "params" => params} = native} ->
        map_session_update(session, on_event, params, native)
        next_stall = reset_stall_deadline(session, turn_deadline)
        await_turn(session, request_id, on_event, turn_deadline, next_stall, "")

      {:ok, %{"method" => "session/request_permission", "id" => id, "params" => params} = native} ->
        handle_permission_request(
          session,
          request_id,
          on_event,
          turn_deadline,
          stall_deadline,
          id,
          params,
          native
        )

      {:ok, %{"method" => method, "id" => id} = native} ->
        handle_required_request(session, on_event, id, method, native)

      {:ok, %{"method" => _notification}} ->
        await_turn(session, request_id, on_event, turn_deadline, stall_deadline, "")

      {:ok, %{"id" => _other_id}} ->
        await_turn(session, request_id, on_event, turn_deadline, stall_deadline, "")

      {:error, reason} ->
        cancel_session(session)
        fail_turn(session, on_event, reason, %{"line" => line})
    end
  end

  defp complete_turn(session, on_event, %{"stopReason" => stop_reason} = result, native)
       when stop_reason in ["end_turn", "max_tokens", "max_turn_requests"] do
    usage = current_usage(session)
    safe_result = redact(session, result)
    emit_event(on_event, :turn_completed, session, %{stop_reason: stop_reason}, native, usage)
    {:ok, %{session_id: session.session_id, stop_reason: stop_reason, usage: usage, native: safe_result}}
  end

  defp complete_turn(session, on_event, %{"stopReason" => stop_reason}, native),
    do: fail_turn(session, on_event, {:turn_stopped, stop_reason}, native)

  defp complete_turn(session, on_event, _result, native),
    do: fail_turn(session, on_event, :invalid_acp_prompt_response, native)

  defp map_session_update(session, on_event, %{"sessionId" => session_id, "update" => update}, native)
       when session_id == session.session_id and is_map(update) do
    emit_acp_update(update["sessionUpdate"], session, on_event, update, native)
  end

  defp map_session_update(session, on_event, params, native) do
    emit_event(on_event, :turn_progress, session, %{kind: :invalid_acp_update, update: params}, native)
  end

  defp emit_acp_update("agent_message_chunk", session, on_event, update, native),
    do: emit_event(on_event, :message_delta, session, content_payload(update, :assistant), native)

  defp emit_acp_update("agent_thought_chunk", session, on_event, update, native),
    do: emit_event(on_event, :turn_progress, session, content_payload(update, :reasoning), native)

  defp emit_acp_update("tool_call", session, on_event, update, native),
    do: emit_event(on_event, :tool_call, session, tool_payload(update), native)

  defp emit_acp_update("tool_call_update", session, on_event, update, native) do
    event = if update["status"] in ["completed", "failed"], do: :tool_result, else: :turn_progress
    emit_event(on_event, event, session, tool_payload(update), native)
  end

  defp emit_acp_update("plan", session, on_event, update, native),
    do: emit_event(on_event, :turn_progress, session, %{kind: :plan, entries: update["entries"] || []}, native)

  defp emit_acp_update("usage_update", session, on_event, update, native) do
    usage = update |> Map.delete("sessionUpdate") |> then(&redact(session, &1))
    Agent.update(session.state, &Map.put(&1, :usage, usage))
    emit_event(on_event, :turn_progress, session, %{kind: :usage}, native, usage)
  end

  defp emit_acp_update(update_type, session, on_event, update, native)
       when update_type in [
              "available_commands_update",
              "config_option_update",
              "current_mode_update",
              "session_info_update"
            ],
       do: emit_event(on_event, :turn_progress, session, %{kind: update_type, update: update}, native)

  defp emit_acp_update(unknown, session, on_event, _update, native),
    do: emit_event(on_event, :turn_progress, session, %{kind: :unknown_acp_update, update_type: unknown}, native)

  defp content_payload(update, channel) do
    content = update["content"] || %{}

    %{
      channel: channel,
      content: content,
      message_id: update["messageId"],
      text: if(content["type"] == "text", do: content["text"])
    }
  end

  defp tool_payload(update) do
    %{
      call_id: update["toolCallId"],
      content: update["content"],
      kind: update["kind"],
      locations: update["locations"],
      status: update["status"],
      title: update["title"]
    }
  end

  defp handle_permission_request(
         session,
         request_id,
         on_event,
         turn_deadline,
         _stall_deadline,
         rpc_id,
         params,
         native
       ) do
    evidence = permission_evidence(session.runner_config["permissions"] || %{}, params)

    case evidence do
      %{decision: :allow, option_id: option_id} ->
        case respond_to_permission(session.process.port, rpc_id, option_id) do
          :ok ->
            emit_event(on_event, :turn_progress, session, evidence, native)

            await_turn(
              session,
              request_id,
              on_event,
              turn_deadline,
              reset_stall_deadline(session, turn_deadline),
              ""
            )

          {:error, reason} ->
            fail_turn(session, on_event, reason, native)
        end

      %{decision: decision, option_id: option_id} ->
        respond_to_permission(session.process.port, rpc_id, option_id)
        reason = permission_failure(decision, evidence.tool_kind)

        emit_event(
          on_event,
          :blocked,
          session,
          Map.put(evidence, :action, "Change the pinned OMP permission policy, then retry the run."),
          native,
          nil,
          elem(reason, 0)
        )

        cancel_session(session)
        fail_turn(session, on_event, reason, native)
    end
  end

  defp permission_evidence(policy, params) do
    tool_call = Map.get(params, "toolCall", %{})
    tool_kind = Map.get(tool_call, "kind")
    options = Map.get(params, "options", [])
    {policy_decision, policy_key} = permission_policy_decision(policy, tool_kind)
    option_id = permission_option_id(options, policy_decision)
    decision = if policy_decision == :allow and is_nil(option_id), do: :unavailable, else: policy_decision

    %{
      call_id: Map.get(tool_call, "toolCallId"),
      decision: decision,
      option_id: option_id,
      policy_key: policy_key,
      title: Map.get(tool_call, "title"),
      tool_kind: tool_kind
    }
  end

  defp permission_policy_decision(policy, tool_kind) when is_binary(tool_kind) do
    cond do
      Map.has_key?(policy, tool_kind) -> {permission_decision(policy[tool_kind]), tool_kind}
      Map.has_key?(policy, "*") -> {permission_decision(policy["*"]), "*"}
      true -> {:missing, nil}
    end
  end

  defp permission_policy_decision(_policy, _tool_kind), do: {:missing, nil}

  defp permission_decision("allow"), do: :allow
  defp permission_decision("deny"), do: :deny
  defp permission_decision("block"), do: :block
  defp permission_decision(_invalid), do: :missing

  defp permission_option_id(options, :allow), do: option_id(options, "allow_once")
  defp permission_option_id(options, :deny), do: option_id(options, "reject_once")
  defp permission_option_id(_options, _decision), do: nil

  defp option_id(options, kind) when is_list(options) do
    Enum.find_value(options, fn
      %{"kind" => ^kind, "optionId" => option_id} when is_binary(option_id) and option_id != "" ->
        option_id

      _other ->
        nil
    end)
  end

  defp option_id(_options, _kind), do: nil

  defp permission_failure(:deny, tool_kind), do: {:permission_denied, tool_kind}
  defp permission_failure(:block, tool_kind), do: {:permission_blocked, tool_kind}
  defp permission_failure(:missing, tool_kind), do: {:permission_policy_missing, tool_kind}
  defp permission_failure(:unavailable, tool_kind), do: {:permission_option_unavailable, tool_kind}

  defp respond_to_permission(port, id, option_id) do
    outcome =
      if is_binary(option_id) and option_id != "" do
        %{"outcome" => "selected", "optionId" => option_id}
      else
        %{"outcome" => "cancelled"}
      end

    send_message(port, rpc_result(id, %{"outcome" => outcome}))
  end

  defp cancel_session(session) do
    send_message(
      session.process.port,
      %{
        "jsonrpc" => "2.0",
        "method" => "session/cancel",
        "params" => %{"sessionId" => session.session_id}
      }
    )

    :ok
  end

  defp close_session(session) do
    if Port.info(session.process.port) do
      deadline = monotonic_deadline(@close_timeout_ms)
      rpc_call(session.process, "session/close", %{"sessionId" => session.session_id}, deadline)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp send_rpc_error(port, id, code, message),
    do: send_message(port, %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})

  defp send_message(port, message) do
    payload = Jason.encode!(message) <> "\n"
    Port.command(port, payload)
    :ok
  rescue
    ArgumentError -> {:error, :runtime_port_closed}
  end

  defp rpc_request(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp rpc_result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _other} -> {:error, :invalid_acp_message}
      {:error, _reason} -> {:error, :malformed_acp_message}
    end
  end

  defp event_handler(opts) do
    case Keyword.get(opts, :on_event, fn _event -> :ok end) do
      handler when is_function(handler, 1) -> {:ok, handler}
      _invalid -> {:error, :invalid_agent_runtime_options}
    end
  end

  defp tool_executor(opts) do
    case Keyword.get(opts, :tool_executor) do
      nil -> {:ok, &DynamicTool.execute/2}
      executor when is_function(executor, 2) -> {:ok, executor}
      _invalid -> {:error, :invalid_agent_runtime_options}
    end
  end

  defp turn_timeout(%{execution_context: %ExecutionContext{timeout_ms: timeout_ms}}, _opts), do: timeout_ms
  defp turn_timeout(session, opts), do: Keyword.get(opts, :turn_timeout_ms, session.turn_timeout_ms)

  defp reset_stall_deadline(session, turn_deadline) do
    case session.runner_config["stall_timeout_ms"] do
      0 -> turn_deadline
      timeout_ms -> min(turn_deadline, System.monotonic_time(:millisecond) + timeout_ms)
    end
  end

  defp emit_session_started_once(session, on_event) do
    emit? =
      Agent.get_and_update(session.state, fn state ->
        {not state.session_started?, %{state | session_started?: true}}
      end)

    if emit?, do: emit_event(on_event, :session_started, session, %{workspace: session.workspace})
  end

  defp current_usage(session), do: Agent.get(session.state, & &1.usage)

  defp fail_turn(session, on_event, reason, native \\ nil) do
    safe_reason = redact(session, reason)
    emit_event(on_event, :turn_failed, session, %{reason: safe_reason}, native, current_usage(session))
    {:error, safe_reason}
  end

  defp emit_event(on_event, event_type, session, payload, native \\ nil, usage \\ nil, reason \\ nil) do
    {:ok, event} =
      Event.new(event_type,
        runtime: @runtime,
        session_id: session.session_id,
        native: redact(session, native),
        usage: redact(session, usage),
        payload: redact(session, payload),
        reason: redact(session, reason)
      )

    on_event.(event)
  end

  defp handle_required_request(session, on_event, id, method, native) do
    if elicitation_method?(method) do
      reason = {:operator_input_required, method}

      emit_event(
        on_event,
        :blocked,
        session,
        %{
          action: "Resolve the requested input outside the unattended run, then retry.",
          method: method
        },
        native,
        nil,
        :operator_input_required
      )

      send_rpc_error(session.process.port, id, -32_603, "Interactive input is unavailable")
      cancel_session(session)
      fail_turn(session, on_event, reason, native)
    else
      reason = {:unsupported_acp_request, method}
      emit_event(on_event, :blocked, session, %{method: method}, native, nil, :unsupported_acp_request)
      send_rpc_error(session.process.port, id, -32_601, "Method not found")
      cancel_session(session)
      fail_turn(session, on_event, reason, native)
    end
  end

  defp elicitation_method?(method) when is_binary(method) do
    method == "session/request_input" or
      String.contains?(method, "question") or
      String.contains?(method, "elicitation")
  end

  defp elicitation_method?(_method), do: false

  defp redact(session, value),
    do: Redaction.redact_secrets(value, [session.bridge.token])

  defp request_deadline(overall_deadline, timeout_ms),
    do: min(overall_deadline, monotonic_deadline(timeout_ms))

  defp monotonic_deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms
  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp stop_state(state) when is_pid(state) do
    if Process.alive?(state), do: Agent.stop(state, :normal, @close_timeout_ms)
    :ok
  catch
    :exit, reason -> {:error, reason}
  end
end
