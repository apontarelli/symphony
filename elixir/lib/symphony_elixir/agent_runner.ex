defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.{AgentRuntime, Config, Linear.Issue, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.AgentRuntime.Event

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        maybe_send_non_retryable_agent_blocker(codex_update_recipient, issue, reason)
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
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
    |> maybe_put_runtime_field(:reason, event.reason)
  end

  defp maybe_put_runtime_field(update, _key, nil), do: update
  defp maybe_put_runtime_field(update, key, value), do: Map.put(update, key, value)

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
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

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, policy} <- policy_for_issue(issue, opts),
         {:ok, session} <- AgentRuntime.start_session(workspace, issue, worker_host: worker_host, policy: policy) do
      try do
        opts = Keyword.put(opts, :policy, policy)
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AgentRuntime.stop_session(session)
      end
    end
  end

  defp policy_for_issue(issue, opts) do
    case Keyword.fetch(opts, :policy) do
      {:ok, policy} when is_map(policy) -> {:ok, policy}
      _ -> resolve_policy_for_issue(issue)
    end
  end

  defp resolve_policy_for_issue(issue) do
    case Config.issue_policy(issue) do
      {:ok, policy} -> {:ok, policy}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt_bundle = build_turn_prompt(issue, opts, turn_number, max_turns)
    log_workflow_module_resolution(issue, prompt_bundle)
    send_workflow_module_resolution(codex_update_recipient, issue, prompt_bundle.workflow_module_resolution)

    with {:ok, turn_session} <-
           AgentRuntime.send_turn(
             app_session,
             prompt_bundle.prompt,
             issue,
             on_event: runtime_event_handler(codex_update_recipient, issue),
             workflow_module_resolution: prompt_bundle.workflow_module_resolution
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
          send_max_turns_exhausted(codex_update_recipient, refreshed_issue, turn_number, max_turns)

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt_bundle(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    %{
      prompt: """
      Continuation guidance:

      - The previous Codex turn completed normally, but the Linear issue is still in an active state.
      - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
      - Resume from the current workspace and workpad state instead of restarting from scratch.
      - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
      - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
      """,
      workflow_module_resolution: nil
    }
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

  defp log_workflow_module_resolution(issue, %{workflow_module_resolution: %{module_refs: refs, policy_hash: policy_hash}}) do
    module_refs = Enum.map_join(refs, ",", &"#{&1.name}@#{&1.version}")

    Logger.info("Resolved workflow modules for #{issue_context(issue)} workflow_module_policy_hash=#{policy_hash} workflow_modules=#{module_refs}")
  end

  defp log_workflow_module_resolution(_issue, _prompt_bundle) do
    :ok
  end

  defp send_workflow_module_resolution(recipient, %Issue{id: issue_id}, workflow_module_resolution)
       when is_binary(issue_id) and is_pid(recipient) and is_map(workflow_module_resolution) do
    send(recipient, {:workflow_module_resolution, issue_id, workflow_module_resolution})
    :ok
  end

  defp send_workflow_module_resolution(_recipient, _issue, _workflow_module_resolution), do: :ok

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

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
