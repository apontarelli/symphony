defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Codex.ExecutionProfile, Codex.Launch, Config, PathSafety, Workflow}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @error_loop_threshold 3
  @error_loop_message_bytes 240
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          codex_home: Path.t(),
          worker_host: String.t() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    settings = Config.settings!()
    execution_profile = ExecutionProfile.resolve(settings, Keyword.get(opts, :execution_profile, "implementation"))
    codex_command = ExecutionProfile.command(settings.codex.command, execution_profile, settings.codex.model)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, launch} <- Launch.start(expanded_workspace, worker_host, codex_command, line: @port_line_bytes) do
      port = launch.port

      metadata =
        port
        |> port_metadata(worker_host)
        |> Map.merge(launch_provenance(expanded_workspace, launch.codex_home, codex_command, execution_profile))

      Logger.info("Codex app-server launched cwd=#{expanded_workspace} codex_home=#{launch.codex_home} execution_profile=#{execution_profile.name} command=#{codex_command}")

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host, opts),
           {:ok, thread_id} <- do_start_session(port, expanded_workspace, session_policies) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           codex_home: launch.codex_home,
           worker_host: worker_host
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    workflow_module_resolution = Keyword.get(opts, :workflow_module_resolution)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments)
      end)

    timeout_ms = Keyword.get(opts, :turn_timeout_ms, Config.settings!().codex.turn_timeout_ms)

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          session_started_details(session_id, thread_id, turn_id, workflow_module_resolution),
          metadata
        )

        turn_context = %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          session_id: session_id,
          thread_id: thread_id,
          turn_id: turn_id
        }

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests, turn_context, timeout_ms) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil, opts) do
    Config.codex_runtime_settings(workspace, opts)
  end

  defp session_policies(workspace, worker_host, opts) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, Keyword.put(opts, :remote, true))
  end

  defp do_start_session(port, workspace, session_policies) do
    case send_initialize(port) do
      :ok -> start_thread(port, workspace, session_policies)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(port, workspace, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox}) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => DynamicTool.tool_specs()
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests, turn_context, timeout_ms) do
    receive_loop(
      %{
        port: port,
        on_message: on_message,
        timeout_ms: timeout_ms,
        tool_executor: tool_executor,
        auto_approve_requests: auto_approve_requests,
        turn_context: turn_context,
        error_loop_state: initial_error_loop_state()
      },
      ""
    )
  end

  defp receive_loop(%{port: port, timeout_ms: timeout_ms} = context, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(context, complete_line)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(context, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(context, data) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(context.on_message, :turn_completed, payload, payload_string, context.port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          context.on_message,
          :turn_failed,
          payload,
          payload_string,
          context.port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          context.on_message,
          :turn_cancelled,
          payload,
          payload_string,
          context.port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(context, payload, payload_string, method)

      {:ok, payload} ->
        emit_message(
          context.on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(context.port, payload)
        )

        receive_next(context, maybe_reset_error_loop_state(context.error_loop_state, payload))

      {:error, _reason} ->
        handle_non_json_turn_line(context, payload_string)
    end
  end

  defp handle_non_json_turn_line(context, payload_string) do
    log_non_json_stream_line(payload_string, "turn stream")

    case record_error_loop_candidate(
           :stream,
           payload_string,
           nil,
           context.error_loop_state,
           context.turn_context
         ) do
      {:error, reason, details} ->
        emit_message(
          context.on_message,
          :codex_error_loop,
          details,
          metadata_from_message(context.port, %{raw: payload_string})
        )

        {:error, reason}

      {:cont, next_error_loop_state} ->
        emit_malformed_candidate(context, payload_string)
        receive_next(context, next_error_loop_state)
    end
  end

  defp emit_malformed_candidate(context, payload_string) do
    if protocol_message_candidate?(payload_string) do
      emit_message(
        context.on_message,
        :malformed,
        %{
          payload: payload_string,
          raw: payload_string
        },
        metadata_from_message(context.port, %{raw: payload_string})
      )
    end
  end

  defp receive_next(context, error_loop_state) do
    context
    |> Map.put(:error_loop_state, error_loop_state)
    |> receive_loop("")
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(context, payload, payload_string, method) do
    metadata = metadata_from_message(context.port, payload)

    case record_error_loop_candidate(
           :notification,
           payload_string,
           payload,
           context.error_loop_state,
           context.turn_context
         ) do
      {:error, reason, details} ->
        emit_message(context.on_message, :codex_error_loop, details, metadata)
        {:error, reason}

      {:cont, error_loop_state} ->
        context
        |> Map.put(:error_loop_state, error_loop_state)
        |> do_handle_turn_method(payload, payload_string, method, metadata)
    end
  end

  defp do_handle_turn_method(context, payload, payload_string, method, metadata) do
    case maybe_handle_approval_request(
           context.port,
           method,
           payload,
           payload_string,
           context.on_message,
           metadata,
           context.tool_executor,
           context.auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          context.on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_next(context, initial_error_loop_state())

      :approval_required ->
        emit_message(
          context.on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        handle_unhandled_turn_method(context, payload, payload_string, method, metadata)
    end
  end

  defp handle_unhandled_turn_method(context, payload, payload_string, method, metadata) do
    if needs_input?(method, payload) do
      emit_message(
        context.on_message,
        :turn_input_required,
        %{payload: payload, raw: payload_string},
        metadata
      )

      {:error, {:turn_input_required, payload}}
    else
      emit_message(
        context.on_message,
        :notification,
        %{
          payload: payload,
          raw: payload_string
        },
        metadata
      )

      Logger.debug("Codex notification: #{inspect(method)}")
      receive_next(context, maybe_reset_error_loop_state(context.error_loop_state, payload))
    end
  end

  defp initial_error_loop_state, do: %{signature: nil, count: 0}

  defp record_error_loop_candidate(source, payload_string, payload, error_loop_state, turn_context) do
    case error_loop_signature(source, payload_string, payload) do
      nil ->
        {:cont, error_loop_state}

      signature ->
        count =
          if Map.get(error_loop_state, :signature) == signature do
            Map.get(error_loop_state, :count, 0) + 1
          else
            1
          end

        details =
          turn_context
          |> Map.put(:signature, signature)
          |> Map.put(:count, count)
          |> Map.put(:source, source)
          |> Map.put(:last_message, compact_error_loop_message(payload_string))

        if count >= @error_loop_threshold do
          {:error, {:codex_error_loop, details}, details}
        else
          {:cont,
           %{
             signature: signature,
             count: count,
             source: source,
             last_message: details.last_message
           }}
        end
    end
  end

  defp error_loop_signature(source, payload_string, payload) do
    text = payload_string |> to_string() |> String.downcase()
    method = payload_method(payload)

    compaction_error_signature(text) || fatal_error_signature(source, method, text)
  end

  defp compaction_error_signature(text) do
    if Enum.any?(
         [
           "remote compaction failed",
           "failed to run pre-sampling compact",
           "property_name_above_max_length",
           "invalid property name in"
         ],
         &String.contains?(text, &1)
       ) do
      "remote_compaction_failed:property_name_above_max_length"
    end
  end

  defp fatal_error_signature(source, method, text) do
    cond do
      source == :stream and fatal_non_progress_text?(text) ->
        "fatal_stream:" <> compact_error_signature(text)

      method == "error" and fatal_non_progress_text?(text) ->
        "fatal_notification:" <> compact_error_signature(text)

      true ->
        nil
    end
  end

  defp payload_method(%{} = payload), do: Map.get(payload, "method") || Map.get(payload, :method)
  defp payload_method(_payload), do: nil

  defp fatal_non_progress_text?(text) when is_binary(text) do
    String.match?(text, ~r/\b(error|failed|fatal|panic|exception)\b/i)
  end

  defp compact_error_signature(text) when is_binary(text) do
    text
    |> String.replace(~r/input\[\d+\]/i, "input[*]")
    |> String.replace(~r/[^a-z0-9\*\[\]]+/i, "_")
    |> String.trim("_")
    |> String.slice(0, 80)
  end

  defp compact_error_loop_message(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @error_loop_message_bytes)
  end

  defp maybe_reset_error_loop_state(error_loop_state, payload) do
    if turn_progress_payload?(payload) do
      initial_error_loop_state()
    else
      error_loop_state
    end
  end

  defp turn_progress_payload?(%{} = payload) do
    method = payload_method(payload)

    method in [
      "thread/started",
      "turn/started",
      "turn/completed",
      "turn/failed",
      "turn/cancelled",
      "item/completed",
      "item/tool/call",
      "item/commandExecution/requestApproval",
      "item/fileChange/requestApproval",
      "item/tool/requestUserInput",
      "codex/event/task_started",
      "codex/event/exec_command_begin",
      "codex/event/exec_command_end",
      "codex/event/agent_message_delta",
      "thread/tokenUsage/updated"
    ] or is_map(Map.get(payload, "usage") || Map.get(payload, :usage))
  end

  defp turn_progress_payload?(_payload), do: false

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "mcpServer/elicitation/request",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         true
       ) do
    if mcp_tool_call_approval_elicitation?(params) do
      send_message(port, %{"id" => id, "result" => %{"action" => "accept", "content" => %{}}})

      emit_message(
        on_message,
        :approval_auto_approved,
        %{payload: payload, raw: payload_string, decision: "accept"},
        metadata
      )

      :approved
    else
      :unhandled
    end
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp mcp_tool_call_approval_elicitation?(params) when is_map(params) do
    meta = Map.get(params, "_meta") || Map.get(params, :_meta)

    is_map(meta) and
      (Map.get(meta, "codex_approval_kind") || Map.get(meta, :codex_approval_kind)) == "mcp_tool_call"
  end

  defp mcp_tool_call_approval_elicitation?(_params), do: false

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp launch_provenance(workspace, codex_home, codex_command, execution_profile) do
    workflow_file_path = Workflow.selected_workflow_file_path()

    %{
      codex_command: codex_command,
      codex_home: codex_home,
      codex_workspace: workspace,
      codex_execution_profile: execution_profile.name,
      codex_execution_profile_model: execution_profile.model,
      codex_execution_profile_reasoning_effort: execution_profile.reasoning_effort,
      codex_execution_profile_budget: execution_profile.budget,
      codex_execution_profile_timeout_ms: execution_profile.timeout_ms,
      workflow_file_path: workflow_file_path,
      workflow_config_sha256: workflow_file_sha256(workflow_file_path)
    }
  end

  defp workflow_file_sha256(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        :crypto.hash(:sha256, contents)
        |> Base.encode16(case: :lower)

      {:error, _reason} ->
        nil
    end
  end

  defp session_started_details(session_id, thread_id, turn_id, workflow_module_resolution) do
    %{
      session_id: session_id,
      thread_id: thread_id,
      turn_id: turn_id
    }
    |> maybe_put_workflow_module_resolution(workflow_module_resolution)
  end

  defp maybe_put_workflow_module_resolution(details, %{module_refs: refs, policy_hash: policy_hash}) do
    details
    |> Map.put(:workflow_module_policy_hash, policy_hash)
    |> Map.put(:workflow_modules, Enum.map(refs, &Map.take(&1, [:name, :version])))
  end

  defp maybe_put_workflow_module_resolution(details, _workflow_module_resolution), do: details

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
