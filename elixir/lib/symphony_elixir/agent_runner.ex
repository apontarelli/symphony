defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger

  alias SymphonyElixir.{
    AgentRuntime,
    CapabilityPreflight,
    Config,
    ExecutionContext,
    Linear.Issue,
    PromptBuilder,
    TargetContext,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.AgentRuntime.Event
  alias SymphonyElixir.TargetContext.Legacy

  @default_max_turns 20
  @type worker_host :: String.t() | nil
  @type result :: :ok | {:error, term()}

  @doc false
  @spec continue_with_issue_for_test(
          ExecutionContext.t(),
          Issue.t(),
          (TargetContext.t(), [String.t()] -> term())
        ) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(
        %ExecutionContext{} = context,
        %Issue{} = issue,
        issue_state_fetcher
      )
      when is_function(issue_state_fetcher, 2) do
    continue_with_issue?(context, issue, issue_state_fetcher)
  end

  @spec run(Issue.t()) :: :ok
  def run(%Issue{} = issue), do: run(issue, nil, [])

  @spec run_context(ExecutionContext.t(), Issue.t()) :: result()
  def run_context(%ExecutionContext{} = context, %Issue{} = issue),
    do: run_context(context, issue, nil, [])

  @spec run(Issue.t(), pid() | nil) :: :ok
  def run(%Issue{} = issue, codex_update_recipient),
    do: run(issue, codex_update_recipient, [])

  @spec run_context(ExecutionContext.t(), Issue.t(), pid() | nil) :: result()
  def run_context(%ExecutionContext{} = context, %Issue{} = issue, codex_update_recipient),
    do: run_context(context, issue, codex_update_recipient, [])

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok
  def run(%Issue{} = issue, codex_update_recipient, opts) when is_list(opts) do
    admitted_issue = ensure_legacy_issue_id(issue)

    case admit_execution_context(admitted_issue, opts) do
      {:ok, context} ->
        run_opts = legacy_context_run_options(opts, issue)

        case run_context(context, admitted_issue, codex_update_recipient, run_opts) do
          :ok ->
            :ok

          {:error, reason} ->
            raise_agent_run_failure(issue, legacy_failure_reason(context, reason))
        end

      {:error, reason} ->
        maybe_send_non_retryable_agent_blocker(codex_update_recipient, issue, reason)
        raise_agent_run_failure(issue, reason)
    end
  end

  @spec run_context(ExecutionContext.t(), Issue.t(), pid() | nil, keyword()) :: result()
  def run_context(
        %ExecutionContext{} = context,
        %Issue{} = issue,
        codex_update_recipient,
        opts
      )
      when is_list(opts) do
    with :ok <- validate_context_run(context, issue, opts) do
      Logger.info("Starting agent run for #{issue_context(issue)} target_id=#{context.target.target_id} worker_host=#{worker_host_for_log(context.worker_host)}")

      case run_in_context(context, issue, codex_update_recipient, opts) do
        :ok ->
          :ok

        {:error, reason} = error ->
          maybe_send_non_retryable_agent_blocker(codex_update_recipient, issue, reason)
          Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
          error
      end
    end
  end

  def run_context(%ExecutionContext{}, %Issue{}, _codex_update_recipient, _opts),
    do: {:error, :invalid_agent_runner_options}

  defp admit_execution_context(issue, opts) do
    worker_host =
      selected_worker_host(
        Keyword.get(opts, :worker_host),
        Config.settings!().worker.ssh_hosts
      )

    with {:ok, target} <- Legacy.build_at_process_start([]),
         {:ok, policy} <- admission_policy(target, issue, opts) do
      ExecutionContext.new(target, issue,
        policy: policy,
        worker_host: worker_host
      )
    end
  end

  defp admission_policy(target, issue, opts) do
    case Keyword.get(opts, :policy) do
      policy when is_map(policy) and map_size(policy) > 0 ->
        {:ok, policy}

      _no_override ->
        profile = get_in(target.issue_policy_authority, ["profile"]) || "default"

        case TargetContext.issue_policy(target, issue, profile: profile) do
          {:ok, policy} ->
            {:ok, policy}

          {:error, reason}
          when reason in [:forbidden_policy_broadening, :malformed_issue_metadata] ->
            Config.issue_policy(issue)

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp legacy_context_run_options(opts, %Issue{id: issue_id}) do
    context_opts = context_run_options(opts)

    if (is_nil(issue_id) or issue_id == "") and
         not Keyword.has_key?(context_opts, :issue_state_fetcher) do
      Keyword.put(context_opts, :issue_state_fetcher, fn _issue_ids -> {:ok, []} end)
    else
      context_opts
    end
  end

  defp ensure_legacy_issue_id(%Issue{id: id} = issue)
       when is_binary(id) and id != "",
       do: issue

  defp ensure_legacy_issue_id(%Issue{identifier: identifier} = issue)
       when is_binary(identifier) and identifier != "",
       do: %{issue | id: identifier}

  defp ensure_legacy_issue_id(%Issue{} = issue), do: issue

  defp legacy_failure_reason(
         %ExecutionContext{worker_host: worker_host},
         reason
       )
       when is_binary(worker_host) and
              reason in [
                :workspace_remote_operation_failed,
                :workspace_remote_output_invalid,
                :workspace_remote_timeout
              ],
       do: {:workspace_prepare_failed, worker_host, reason}

  defp legacy_failure_reason(_context, reason), do: reason

  defp raise_agent_run_failure(issue, reason) do
    Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
    raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
  end

  defp run_in_context(context, issue, codex_update_recipient, opts) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} target_id=#{context.target.target_id} worker_host=#{worker_host_for_log(context.worker_host)}")

    workspace_opts = workspace_opts(opts)

    case Workspace.create_for_issue(context, workspace_opts) do
      {:ok, workspace} ->
        send_worker_runtime_info(
          codex_update_recipient,
          issue,
          context.worker_host,
          workspace
        )

        try do
          with :ok <- Workspace.run_before_run_hook(context, issue, workspace_opts),
               :ok <- run_capability_preflight(context, issue, codex_update_recipient, opts) do
            run_agent_turns(context, issue, codex_update_recipient, opts)
          end
        after
          Workspace.run_after_run_hook(context, issue, workspace_opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp runtime_event_handler(recipient, issue) do
    fn %Event{} = event ->
      send_codex_update(recipient, issue, runtime_event_update(event))
    end
  end

  defp runtime_event_update(%Event{} = event) do
    payload = event.payload || %{}

    payload
    |> Map.put(:event, event.event)
    |> Map.put(:timestamp, event.timestamp)
    |> maybe_put_runtime_field(:session_id, event.session_id)
    |> maybe_put_runtime_field(:usage, event.usage)
    |> maybe_put_runtime_field(:native, event.native)
    |> maybe_put_runtime_field(:runtime, event.runtime)
    |> maybe_put_runtime_field(:reason, event.reason)
  end

  defp maybe_put_runtime_field(update, _key, nil), do: update
  defp maybe_put_runtime_field(update, key, value), do: Map.put(update, key, value)

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:runtime_event, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp maybe_send_non_retryable_agent_blocker(recipient, issue, reason) do
    case non_retryable_agent_blocker(reason) do
      nil ->
        :ok

      blocker ->
        send_codex_update(recipient, issue, %{
          event: :agent_blocked,
          timestamp: DateTime.utc_now(),
          completion: %{
            outcome: :blocked,
            blocker: blocker
          }
        })
    end
  end

  defp non_retryable_agent_blocker({:response_error, %{} = error}) do
    if codex_invalid_request_error?(error) do
      %{
        reason: codex_invalid_request_reason(error),
        required_action: "Update the workflow Codex configuration or Symphony Codex adapter to match the installed Codex app-server schema."
      }
    end
  end

  defp non_retryable_agent_blocker({:startup_failed, reason}), do: non_retryable_agent_blocker(reason)

  defp non_retryable_agent_blocker(_reason), do: nil

  defp codex_invalid_request_error?(error) do
    (Map.get(error, "code") || Map.get(error, :code)) in [-32_600, "-32600"]
  end

  defp codex_invalid_request_reason(error) do
    message =
      error
      |> Map.get("message", Map.get(error, :message))
      |> non_empty_string()

    case message do
      nil -> "Codex app-server rejected Symphony's request as invalid."
      message -> "Codex app-server rejected Symphony's request as invalid: #{message}"
    end
  end

  defp non_empty_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp non_empty_string(_value), do: nil

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_capability_preflight(context, issue, recipient, opts) do
    case CapabilityPreflight.run(context, capability_preflight_opts(opts)) do
      %{} = preflight ->
        case CapabilityPreflight.blocker(preflight) do
          nil ->
            :ok

          blocker ->
            send_capability_blocker(recipient, issue, blocker, preflight)
            {:error, {:capability_preflight_blocked, blocker}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_capability_blocker(recipient, issue, blocker, preflight) do
    send_codex_update(recipient, issue, %{
      event: :agent_blocked,
      timestamp: DateTime.utc_now(),
      completion: %{
        outcome: :blocked,
        blocker: blocker,
        capability_preflight: preflight
      }
    })
  end

  defp capability_preflight_opts(opts) do
    []
    |> maybe_put_opt(:adapter_registry, Keyword.get(opts, :adapter_registry))
    |> maybe_put_opt(:runner, Keyword.get(opts, :capability_preflight_runner))
    |> maybe_put_opt(:tcp_probe, Keyword.get(opts, :capability_tcp_probe))
  end

  defp workspace_opts(opts) do
    []
    |> maybe_put_opt(:command_runner, Keyword.get(opts, :workspace_command_runner))
    |> maybe_put_opt(:ssh_runner, Keyword.get(opts, :workspace_ssh_runner))
  end

  defp runtime_start_opts(opts) do
    []
    |> maybe_put_opt(:adapter_registry, Keyword.get(opts, :adapter_registry))
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp run_agent_turns(context, issue, codex_update_recipient, opts) do
    issue_state_fetcher = issue_state_fetcher(opts)

    with {:ok, max_turns} <- max_turns(context, opts),
         {:ok, session} <-
           AgentRuntime.start_session(context, issue, runtime_start_opts(opts)) do
      run_result =
        try do
          {:returned,
           do_run_agent_turns(
             context,
             session,
             issue,
             codex_update_recipient,
             opts,
             issue_state_fetcher,
             1,
             max_turns
           )}
        rescue
          error -> {:raised, :error, error, __STACKTRACE__}
        catch
          kind, reason -> {:raised, kind, reason, __STACKTRACE__}
        end

      finish_runtime_run(run_result, stop_runtime_session(session))
    end
  end

  defp stop_runtime_session(session) do
    case AgentRuntime.stop_session(session) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error ->
      {:error, {:runtime_cleanup_exception, error.__struct__, Exception.message(error)}}
  catch
    kind, reason ->
      {:error, {:runtime_cleanup_exit, kind, reason}}
  end

  defp finish_runtime_run({:returned, result}, :ok), do: result

  defp finish_runtime_run({:returned, :ok}, {:error, cleanup_reason}),
    do: {:error, {:runtime_cleanup_failed, cleanup_reason}}

  defp finish_runtime_run(
         {:returned, {:error, primary_reason}},
         {:error, cleanup_reason}
       ) do
    {:error, {:agent_run_failed, primary_reason, {:runtime_cleanup_failed, cleanup_reason}}}
  end

  defp finish_runtime_run({:raised, kind, reason, stacktrace}, cleanup_result) do
    if cleanup_result != :ok do
      Logger.error("Agent runtime cleanup failed while preserving raised failure: #{inspect(cleanup_result)}")
    end

    :erlang.raise(kind, reason, stacktrace)
  end

  defp do_run_agent_turns(
         context,
         app_session,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    with {:ok, prompt_bundle} <-
           build_turn_prompt(context, issue, opts, turn_number, max_turns),
         :ok <-
           report_workflow_module_resolution(
             context,
             issue,
             codex_update_recipient,
             prompt_bundle
           ),
         {:ok, turn_session} <-
           AgentRuntime.send_turn(
             app_session,
             prompt_bundle.prompt,
             issue,
             on_event: runtime_event_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{context.workspace_path} turn=#{turn_number}/#{max_turns}")

      continue_agent_turns(
        context,
        app_session,
        issue,
        codex_update_recipient,
        opts,
        issue_state_fetcher,
        turn_number,
        max_turns
      )
    end
  end

  defp report_workflow_module_resolution(context, issue, recipient, prompt_bundle) do
    log_workflow_module_resolution(issue, prompt_bundle)

    send_workflow_module_resolution(
      recipient,
      issue,
      event_workflow_module_resolution(
        context,
        prompt_bundle.workflow_module_resolution
      )
    )
  end

  defp continue_agent_turns(
         context,
         app_session,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    case continue_with_issue?(context, issue, issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

        do_run_agent_turns(
          context,
          app_session,
          refreshed_issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          turn_number + 1,
          max_turns
        )

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

        send_max_turns_exhausted(
          codex_update_recipient,
          refreshed_issue,
          turn_number,
          max_turns
        )

        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_turn_prompt(context, issue, opts, 1, _max_turns) do
    case Keyword.get(opts, :attempt) do
      nil -> PromptBuilder.build_prompt_bundle(context, issue, [])
      attempt -> PromptBuilder.build_prompt_bundle(context, issue, attempt: attempt)
    end
  end

  defp build_turn_prompt(_context, _issue, _opts, turn_number, max_turns) do
    {:ok,
     %{
       prompt: """
       Continue turn #{turn_number} of #{max_turns}.

       Goal: Finish the remaining ticket work and route the issue according to the original workflow contract.

       Resume from the current workspace, workpad, and thread context. Do not restate the task or repeat completed work unless later changes invalidate it.

       End the turn after reaching the workflow-defined handoff or terminal state.
       Stop early only when required auth, permissions, secrets, or tools are unavailable; record the exact blocker and unblock condition.
       """,
       workflow_module_resolution: nil
     }}
  end

  defp send_max_turns_exhausted(recipient, %Issue{} = issue, turn_number, max_turns) do
    send_codex_update(recipient, issue, %{
      event: :agent_max_turns_exhausted,
      timestamp: DateTime.utc_now(),
      completion: %{
        outcome: :blocked,
        blocker: %{
          reason: "agent.max_turns reached while issue remains active",
          required_action: "Review the workpad, resolve blockers or approve another run, then move the issue back to an active state if more agent work is appropriate."
        }
      },
      turn_count: turn_number,
      max_turns: max_turns
    })
  end

  defp log_workflow_module_resolution(issue, %{
         workflow_module_resolution: %{module_refs: refs, policy_hash: policy_hash}
       }) do
    module_refs = Enum.map_join(refs, ",", &"#{&1.name}@#{&1.version}")

    Logger.info("Resolved workflow modules for #{issue_context(issue)} workflow_module_policy_hash=#{policy_hash} workflow_modules=#{module_refs}")
  end

  defp log_workflow_module_resolution(_issue, _prompt_bundle) do
    :ok
  end

  defp event_workflow_module_resolution(_context, resolution), do: resolution

  defp send_workflow_module_resolution(recipient, %Issue{id: issue_id}, workflow_module_resolution)
       when is_binary(issue_id) and is_pid(recipient) and is_map(workflow_module_resolution) do
    send(recipient, {:workflow_module_resolution, issue_id, workflow_module_resolution})
    :ok
  end

  defp send_workflow_module_resolution(_recipient, _issue, _workflow_module_resolution), do: :ok

  defp continue_with_issue?(
         %ExecutionContext{target: target} = context,
         %Issue{id: issue_id} = issue,
         issue_state_fetcher
       )
       when is_binary(issue_id) do
    case issue_state_fetcher.(target, [issue_id]) do
      {:ok,
       [
         %Issue{id: ^issue_id, identifier: identifier} = refreshed_issue
         | _
       ]}
      when identifier == context.issue_identifier ->
        if active_issue_state?(context, refreshed_issue.state) and
             issue_routable?(context, refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, [%Issue{} | _]} ->
        {:error, {:issue_state_refresh_failed, :issue_mismatch}}

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}

      _invalid ->
        {:error, {:issue_state_refresh_failed, :invalid_tracker_result}}
    end
  end

  defp continue_with_issue?(_context, issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(
         %ExecutionContext{target: %TargetContext{run_target: run_target}},
         state_name
       )
       when is_map(run_target) and is_binary(state_name) do
    case Map.get(run_target, "active_states", []) do
      active_states when is_list(active_states) ->
        normalized_state = normalize_issue_state(state_name)

        Enum.any?(active_states, fn active_state ->
          is_binary(active_state) and normalize_issue_state(active_state) == normalized_state
        end)

      _invalid ->
        false
    end
  end

  defp active_issue_state?(_context, _state_name), do: false

  defp issue_routable?(
         %ExecutionContext{target: %TargetContext{run_target: run_target}},
         %Issue{} = issue
       )
       when is_map(run_target) do
    case Map.get(run_target, "required_labels", []) do
      required_labels when is_list(required_labels) ->
        Issue.routable?(issue, required_labels)

      _invalid ->
        false
    end
  end

  defp issue_routable?(_context, _issue), do: false

  defp max_turns(context, opts) do
    max_turns =
      Keyword.get(
        opts,
        :max_turns,
        Map.get(context.runner_config, "max_turns", @default_max_turns)
      )

    if is_integer(max_turns) and max_turns > 0,
      do: {:ok, max_turns},
      else: {:error, :invalid_agent_runner_max_turns}
  end

  defp issue_state_fetcher(opts) do
    case Keyword.get(opts, :issue_state_fetcher) do
      nil ->
        &Tracker.fetch_issue_states_by_ids/2

      fetcher when is_function(fetcher, 2) ->
        fetcher

      fetcher when is_function(fetcher, 1) ->
        fn _target, issue_ids -> fetcher.(issue_ids) end
    end
  end

  defp context_run_options(opts) do
    Keyword.take(opts, [
      :adapter_registry,
      :attempt,
      :capability_preflight_runner,
      :capability_tcp_probe,
      :issue_state_fetcher,
      :max_turns,
      :workspace_command_runner,
      :workspace_ssh_runner
    ])
  end

  defp validate_context_run(context, issue, opts) do
    if Keyword.keyword?(opts) do
      validate_context_run_options(context, issue, opts)
    else
      {:error, :invalid_agent_runner_options}
    end
  end

  defp validate_context_run_options(context, issue, opts) do
    with :ok <- validate_context_authority(context, issue),
         :ok <- validate_context_option_keys(opts),
         :ok <- validate_issue_state_fetcher(Keyword.get(opts, :issue_state_fetcher)),
         :ok <- validate_max_turns_option(Keyword.get(opts, :max_turns)),
         :ok <- validate_attempt_option(Keyword.get(opts, :attempt)) do
      validate_adapter_registry(Keyword.get(opts, :adapter_registry))
    end
  end

  defp validate_context_authority(context, issue) do
    cond do
      ExecutionContext.validate(context) != :ok ->
        {:error, :invalid_agent_runner_context}

      context.issue_id != issue.id or context.issue_identifier != issue.identifier ->
        {:error, :agent_runner_issue_mismatch}

      true ->
        :ok
    end
  end

  defp validate_context_option_keys(opts) do
    allowed_keys = Keyword.keys(context_run_options(opts))
    supplied_keys = Keyword.keys(opts)

    if length(supplied_keys) == length(Enum.uniq(supplied_keys)) and
         Enum.sort(allowed_keys) == Enum.sort(supplied_keys),
       do: :ok,
       else: {:error, :invalid_agent_runner_options}
  end

  defp validate_issue_state_fetcher(nil), do: :ok

  defp validate_issue_state_fetcher(fetcher)
       when is_function(fetcher, 1) or is_function(fetcher, 2),
       do: :ok

  defp validate_issue_state_fetcher(_fetcher),
    do: {:error, :invalid_agent_runner_options}

  defp validate_max_turns_option(nil), do: :ok
  defp validate_max_turns_option(max_turns) when is_integer(max_turns) and max_turns > 0, do: :ok

  defp validate_max_turns_option(_max_turns),
    do: {:error, :invalid_agent_runner_options}

  defp validate_attempt_option(nil), do: :ok
  defp validate_attempt_option(attempt) when is_integer(attempt) and attempt >= 0, do: :ok

  defp validate_attempt_option(_attempt),
    do: {:error, :invalid_agent_runner_options}

  defp validate_adapter_registry(nil), do: :ok
  defp validate_adapter_registry(adapter_registry) when is_map(adapter_registry), do: :ok

  defp validate_adapter_registry(_adapter_registry),
    do: {:error, :invalid_agent_runner_options}

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
