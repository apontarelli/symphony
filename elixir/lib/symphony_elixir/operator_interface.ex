defmodule SymphonyElixir.OperatorInterface do
  @moduledoc """
  Owns operator previews, exact confirmations, and the bounded event cursor.

  A client must fetch a complete snapshot before it consumes events. The
  snapshot cursor is the lower bound for subsequent event reads. A host ID
  change or a cursor outside the retained range requires another complete
  snapshot.
  """

  use GenServer

  alias SymphonyElixir.{
    HostScheduler,
    LocalConfig,
    OperatorMutation,
    OperatorRepositoryBrowser,
    OperatorRepositorySources,
    OperatorSession,
    OperatorSnapshot
  }

  alias SymphonyElixir.ReviewRecords.Redaction

  @interface_version 1
  @schema_version 1
  @default_max_events 2_000
  @default_max_bytes 2 * 1024 * 1024
  @default_event_limit 200
  @maximum_event_limit 500
  @maximum_log_bytes 4_096
  @log_handler_id :symphony_operator_log
  @confirmation_ttl_ms 60_000
  @max_previews 128
  @max_command_results 100
  @repository_call_timeout_ms 5_000
  @repository_hard_timeout_ms 30_000
  @max_repository_events 200
  @max_repository_jobs 16
  @max_repository_errors 100

  defmodule State do
    @moduledoc false

    @derive {Inspect, only: [:host_id, :cursor, :event_count]}
    @enforce_keys [
      :host_id,
      :started_at,
      :cursor,
      :events,
      :event_count,
      :event_bytes,
      :max_events,
      :max_bytes,
      :dropped_events,
      :log_handler_installed?
    ]
    defstruct @enforce_keys ++
                [
                  :session,
                  :config_root,
                  :clock,
                  :confirmation_ttl_ms,
                  previews: %{},
                  command_results: [],
                  pending: nil,
                  repository_jobs: %{},
                  repository_order: [],
                  repository_active: nil
                ]
  end

  @type marker :: %{
          host_id: String.t(),
          started_at: String.t(),
          cursor: non_neg_integer(),
          interface_version: pos_integer(),
          schema_version: pos_integer(),
          command_results: [map()]
        }
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @spec marker(GenServer.server()) :: {:ok, marker()} | {:error, :unavailable}
  def marker(server \\ __MODULE__) do
    GenServer.call(server, :marker)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Returns local launcher metadata, never the session credential itself."
  @spec credentials(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def credentials(server \\ __MODULE__) do
    GenServer.call(server, :credentials)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec preview(GenServer.server(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def preview(server, credential, request, opts) do
    command_call(server, {:preview, credential, request, opts}, false)
  end

  @spec confirm(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, map()}
  def confirm(server, credential, request) do
    command_call(server, {:confirm, credential, request}, true)
  end

  @spec reject(GenServer.server(), atom()) :: {:error, map()}
  def reject(server, code), do: command_call(server, {:reject, code}, false)

  @spec snapshot(
          GenServer.server(),
          GenServer.server(),
          GenServer.server() | nil,
          timeout()
        ) :: {:ok, map()} | {:error, :unavailable}
  def snapshot(server \\ __MODULE__, scheduler, control_plane, timeout) do
    with {:ok, marker} <- marker(server) do
      payload =
        OperatorSnapshot.build(scheduler, control_plane, timeout, marker)
        |> Map.put(:command_results, marker.command_results)

      {:ok, payload}
    end
  end

  @doc "Returns authenticated settings catalogs without creating a mutation preview."
  @spec settings(GenServer.server(), String.t(), map(), GenServer.server()) :: {:ok, map()} | {:error, map()}
  def settings(server, credential, request, scheduler) do
    with {:ok, context} <- command_call(server, {:settings_context, credential}, false) do
      if is_map(request) and is_map(Map.get(request, "selections", %{})) and
           Enum.all?(Map.keys(request), &(&1 in ["target_id", "repository", "selections"])) and
           Enum.all?(["target_id", "repository"], &(is_nil(request[&1]) or is_binary(request[&1]))) do
        catalog = SymphonyElixir.OperatorSettings.build(scheduler, request, config_root: context.config_root)
        {:ok, Map.merge(catalog, Map.drop(context, [:config_root]))}
      else
        {:error, %{error: %{code: "invalid_inputs", message: "Settings inputs are invalid."}}}
      end
    end
  end

  @doc "Starts or polls an authenticated bounded repository discovery job."
  @spec repositories(GenServer.server(), String.t(), map(), GenServer.server()) ::
          {:ok, map()} | {:error, map()}
  def repositories(server, credential, request, scheduler) do
    deadline = System.monotonic_time(:millisecond) + @repository_call_timeout_ms

    GenServer.call(
      server,
      {:repositories, credential, request, scheduler, deadline},
      @repository_call_timeout_ms
    )
  catch
    :exit, _reason ->
      {:error,
       %{
         error: %{
           code: "operator_interface_unavailable",
           message: "Operator interface is unavailable."
         }
       }}
  end

  @spec events(String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, :invalid_cursor | :invalid_limit | :unavailable}
  def events(host_id, after_cursor),
    do: events(__MODULE__, host_id, after_cursor, @default_event_limit)

  @spec events(GenServer.server(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, :invalid_cursor | :invalid_limit | :unavailable}
  def events(server, host_id, after_cursor, limit) do
    cond do
      not is_binary(host_id) or host_id == "" -> {:error, :invalid_cursor}
      not is_integer(after_cursor) or after_cursor < 0 -> {:error, :invalid_cursor}
      not is_integer(limit) or limit < 1 or limit > @maximum_event_limit -> {:error, :invalid_limit}
      true -> call_events(server, host_id, after_cursor, limit)
    end
  end

  @spec publish_state_change(GenServer.server()) :: :ok
  def publish_state_change(server \\ __MODULE__) do
    cast_event(server, "snapshot_invalidated", "host", %{})
  end

  @spec publish_runtime_event(GenServer.server(), map()) :: :ok
  def publish_runtime_event(server \\ __MODULE__, attributes) when is_map(attributes) do
    data = %{
      target_id: safe_string(Map.get(attributes, :target_id)),
      issue_id: safe_string(Map.get(attributes, :issue_id)),
      issue_identifier: safe_string(Map.get(attributes, :issue_identifier)),
      admitted_run_id: safe_string(Map.get(attributes, :admitted_run_id)),
      event: safe_token(Map.get(attributes, :event)),
      at: iso8601(Map.get(attributes, :timestamp))
    }

    cast_event(server, "run_event", "runtime", data)
  end

  @spec publish_log(GenServer.server(), atom(), String.t(), String.t() | nil) :: :ok
  def publish_log(server \\ __MODULE__, level, message, source)
      when is_atom(level) and is_binary(message) do
    {message, truncation} = message |> redact_operator_log() |> truncate_log()

    data = %{
      level: Atom.to_string(level),
      message: message,
      source: safe_string(source),
      truncation: truncation
    }

    cast_event(server, "log", "host_log", data)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    started_at = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    log_handler_installed? = Keyword.get(opts, :install_log_handler, true)

    host_id = Keyword.get_lazy(opts, :host_id, &new_host_id/0)

    config_root =
      LocalConfig.root(config_root: Keyword.get(opts, :config_root) || Application.get_env(:symphony_elixir, :control_plane_config_root))

    {:ok, session} =
      OperatorSession.start_link(host_id: host_id, config_root: config_root)

    state = %State{
      host_id: host_id,
      started_at: started_at,
      cursor: 0,
      events: :queue.new(),
      event_count: 0,
      event_bytes: 0,
      max_events: positive_option(opts, :max_events, @default_max_events),
      max_bytes: positive_option(opts, :max_bytes, @default_max_bytes),
      dropped_events: 0,
      log_handler_installed?: log_handler_installed?,
      session: session,
      config_root: config_root,
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      confirmation_ttl_ms: min(positive_option(opts, :confirmation_ttl_ms, @confirmation_ttl_ms), @confirmation_ttl_ms)
    }

    if log_handler_installed?, do: install_log_handler(Keyword.fetch!(opts, :name))

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.log_handler_installed?, do: :logger.remove_handler(@log_handler_id)
    cancel_all_repository_jobs(state)
    if Process.alive?(state.session), do: GenServer.stop(state.session)
    :ok
  end

  @impl true
  def handle_call(:marker, _from, state) do
    {:reply, {:ok, marker_from_state(state)}, state}
  end

  def handle_call({:events, host_id, after_cursor, limit}, _from, state) do
    {:reply, {:ok, event_response(state, host_id, after_cursor, limit)}, state}
  end

  def handle_call(:credentials, _from, state) do
    {:reply, OperatorSession.credentials(state.session), state}
  end

  def handle_call({:settings_context, credential}, _from, state) do
    case OperatorSession.authenticate(state.session, credential) do
      :ok ->
        {:reply,
         {:ok,
          %{
            host_id: state.host_id,
            interface_version: @interface_version,
            schema_version: @schema_version,
            config_root: state.config_root
          }}, state}

      {:error, code} ->
        reject_reply(state, code)
    end
  end

  def handle_call({:repositories, credential, request, scheduler, deadline}, _from, state) do
    with false <- repository_request_expired?(deadline),
         :ok <- OperatorSession.authenticate(state.session, credential),
         false <- repository_request_expired?(deadline) do
      {reply, state} = handle_repository_request(state, request, scheduler)
      {:reply, reply, state}
    else
      true ->
        {:reply, {:error, repository_error(:operator_interface_unavailable)}, state}

      {:error, code} ->
        {:reply, {:error, repository_error(code)}, state}
    end
  end

  def handle_call({:reject, code}, _from, state), do: reject_reply(state, code)

  def handle_call({:preview, credential, request, opts}, _from, state) do
    with :ok <- OperatorSession.authenticate(state.session, credential),
         :ok <- validate_request(request, state, :preview),
         :ok <- mutation_idle(state),
         opts <- Keyword.merge(opts, host_id: state.host_id, config_root: state.config_root),
         :ok <- current_generation(%{request: request, opts: opts}),
         {:ok, prepared} <- safely_preview(request["command"], opts),
         :ok <- same_generation(request["registry_generation"], prepared.registry_generation) do
      issue_preview(state, request, prepared, opts)
    else
      {:error, reason} -> reject_reply(state, reason)
    end
  end

  def handle_call({:confirm, credential, request}, _from, state) do
    with :ok <- OperatorSession.authenticate(state.session, credential),
         :ok <- validate_request(request, state, :confirm) do
      consume_confirmation(state, request)
    else
      {:error, reason} -> reject_reply(state, reason)
    end
  end

  @impl true
  def handle_info({:repository_event, scan_id, event}, state) do
    {:noreply, record_repository_event(state, scan_id, event)}
  end

  def handle_info({:repository_timeout_config, scan_id, timeout_ms}, state) do
    {:noreply, configure_repository_timeout(state, scan_id, timeout_ms)}
  end

  def handle_info({:repository_complete, scan_id, outcome}, state) do
    {:noreply, complete_repository_job(state, scan_id, outcome)}
  end

  def handle_info({:repository_timeout, scan_id}, state) do
    {:noreply, timeout_repository_job(state, scan_id)}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    if repository_reference?(state, reference) do
      {:noreply, repository_worker_down(state, reference)}
    else
      handle_non_repository_down(reference, state)
    end
  end

  def handle_info({reference, result}, %{pending: %{reference: reference} = pending} = state) do
    Process.demonitor(reference, [:flush])

    outcome =
      case result do
        {:ok, payload} ->
          pending.result
          |> Map.merge(%{status: "completed", result: safe_projection(payload), state_may_have_changed: true})

        {:error, reason} ->
          command_error(reason, true)
          |> Map.merge(Map.take(pending.result, [:id, :action, :identity]))
          |> Map.put(:status, "failed")
      end

    if outcome.status == "completed" and outcome.action == "shutdown" do
      Process.send_after(self(), {:stop_host, pending.opts, outcome}, 250)
      {:noreply, state}
    else
      {:noreply, record_result(%{state | pending: nil}, outcome)}
    end
  end

  def handle_info({:EXIT, session, _reason}, %{session: session} = state),
    do: {:stop, :operator_session_unavailable, state}

  def handle_info({:EXIT, _worker, _reason}, state), do: {:noreply, state}

  def handle_info({:stop_host, opts, outcome}, state) do
    result =
      try do
        Keyword.get(opts, :shutdown, fn -> System.stop(0) end).()
      rescue
        _exception -> {:error, :shutdown_failed}
      catch
        _kind, _reason -> {:error, :shutdown_failed}
      end

    case result do
      :ok ->
        {:noreply, record_result(%{state | pending: nil}, outcome)}

      _other ->
        failed =
          command_error(:shutdown_failed, true)
          |> Map.merge(Map.take(outcome, [:id, :action, :identity]))
          |> Map.put(:status, "failed")

        {:noreply, record_result(%{state | pending: nil}, failed)}
    end
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, Map.take(status.state, [:host_id, :cursor, :event_count]))
    |> Map.put(:message, :redacted_operator_message)
    |> Map.put(:reason, :redacted_operator_reason)
  end

  @impl true
  def handle_cast({:publish, kind, source, data}, state) do
    {:noreply, append_event(state, kind, source, data)}
  end

  defp handle_repository_request(state, request, scheduler) do
    case normalize_repository_request(request) do
      {:ok, :start, normalized} ->
        start_repository_job(state, normalized, scheduler)

      {:ok, :poll, scan_id, after_cursor} ->
        {repository_poll(state, scan_id, after_cursor), state}

      {:ok, :cancel, scan_id} ->
        cancel_repository_request(state, scan_id)

      {:error, reason} ->
        {{:error, repository_error(reason)}, state}
    end
  end

  defp start_repository_job(state, request, scheduler) do
    state = cancel_active_repository(state)
    scan_id = random_id("scan-")
    parent = self()

    {pid, reference} =
      :erlang.spawn_opt(
        fn ->
          run_repository_job(parent, scan_id, request, scheduler, state.config_root)
        end,
        [:link, :monitor]
      )

    timer = Process.send_after(self(), {:repository_timeout, scan_id}, @repository_hard_timeout_ms)

    job = %{
      scan_id: scan_id,
      action: request["action"],
      status: "running",
      pid: pid,
      reference: reference,
      timer: timer,
      events: :queue.new(),
      event_count: 0,
      dropped_events: 0,
      cursor: 0,
      candidates: [],
      result: nil
    }

    state = put_repository_job(%{state | repository_active: scan_id}, job)
    {{:ok, repository_response(state, job, 0)}, state}
  end

  defp run_repository_job(parent, scan_id, request, scheduler, config_root) do
    outcome =
      try do
        case OperatorRepositorySources.load(scheduler, config_root: config_root) do
          {:ok, context} ->
            if is_integer(context[:timeout_ms]) and context[:timeout_ms] > 0 do
              send(parent, {:repository_timeout_config, scan_id, context[:timeout_ms]})
            end

            emit = fn event ->
              send(parent, {:repository_event, scan_id, event})

              receive do
                :cancel -> :cancel
              after
                0 -> :ok
              end
            end

            {:ok, OperatorRepositoryBrowser.run(request, context, emit)}

          {:error, reason} ->
            {:error, reason}
        end
      rescue
        _exception -> {:error, :repository_discovery_failed}
      catch
        _kind, _reason -> {:error, :repository_discovery_failed}
      end

    send(parent, {:repository_complete, scan_id, outcome})
  end

  defp normalize_repository_request(request) when is_map(request) do
    action = Map.get(request, "action")

    cond do
      action == "recent" and valid_recent_request?(request) ->
        {:ok, :start, request}

      action in ~w(browse scan manual) and valid_start_request?(request) ->
        {:ok, :start, request}

      action == "poll" ->
        normalize_repository_poll(request)

      action == "cancel" ->
        normalize_repository_cancel(request)

      true ->
        {:error, :invalid_repository_request}
    end
  end

  defp normalize_repository_request(_request), do: {:error, :invalid_repository_request}

  defp valid_recent_request?(request), do: Map.keys(request) == ["action"]

  defp valid_start_request?(%{"action" => action} = request) when action in ~w(browse manual) do
    Enum.all?(Map.keys(request), &(&1 in ["action", "path"])) and
      valid_absolute_repository_path?(Map.get(request, "path"))
  end

  defp valid_start_request?(%{"action" => "scan"} = request) do
    Enum.all?(Map.keys(request), &(&1 in ["action", "path"])) and
      (not Map.has_key?(request, "path") or is_nil(request["path"]) or
         valid_absolute_repository_path?(request["path"]))
  end

  defp valid_start_request?(_request), do: false

  defp normalize_repository_poll(request) do
    with true <- Enum.all?(Map.keys(request), &(&1 in ["action", "scan_id", "after"])),
         scan_id when is_binary(scan_id) <- Map.get(request, "scan_id"),
         true <- scan_id != "",
         after_cursor <- Map.get(request, "after", 0),
         true <- is_integer(after_cursor) and after_cursor >= 0 do
      {:ok, :poll, scan_id, after_cursor}
    else
      _invalid -> {:error, :invalid_repository_request}
    end
  end

  defp normalize_repository_cancel(request) do
    with true <- Enum.all?(Map.keys(request), &(&1 in ["action", "scan_id"])),
         scan_id when is_binary(scan_id) <- Map.get(request, "scan_id"),
         true <- scan_id != "" do
      {:ok, :cancel, scan_id}
    else
      _invalid -> {:error, :invalid_repository_request}
    end
  end

  defp valid_absolute_repository_path?(path),
    do: is_binary(path) and path != "" and Path.type(path) == :absolute

  defp repository_poll(state, scan_id, after_cursor) do
    case Map.get(state.repository_jobs, scan_id) do
      nil ->
        {:error, repository_error(:scan_not_found)}

      %{cursor: cursor} when after_cursor > cursor ->
        {:error, repository_error(:invalid_repository_request)}

      job ->
        {:ok, repository_response(state, job, after_cursor)}
    end
  end

  defp cancel_repository_request(state, scan_id) do
    case Map.get(state.repository_jobs, scan_id) do
      nil ->
        {{:error, repository_error(:scan_not_found)}, state}

      _job ->
        state = cancel_repository_job(state, scan_id, :cancelled)
        {:ok, cancelled_job} = repository_poll(state, scan_id, 0)
        {{:ok, cancelled_job}, state}
    end
  end

  defp cancel_active_repository(%{repository_active: nil} = state), do: state

  defp cancel_active_repository(%{repository_active: scan_id} = state),
    do: cancel_repository_job(state, scan_id, :replaced)

  defp cancel_repository_job(state, scan_id, reason) do
    case Map.get(state.repository_jobs, scan_id) do
      %{status: "running", pid: pid, timer: timer} = job ->
        send(pid, :cancel)
        Process.exit(pid, :kill)
        Process.cancel_timer(timer)
        Process.demonitor(job.reference, [:flush])

        result = %{
          status: "cancelled",
          candidates: Enum.reverse(job.candidates),
          errors: [%{code: Atom.to_string(reason)}],
          visited: nil
        }

        put_repository_job(
          %{state | repository_active: if(state.repository_active == scan_id, do: nil, else: state.repository_active)},
          %{job | status: "cancelled", pid: nil, reference: nil, timer: nil, result: result}
        )

      _job ->
        %{state | repository_active: if(state.repository_active == scan_id, do: nil, else: state.repository_active)}
    end
  end

  defp record_repository_event(state, scan_id, event) do
    case Map.get(state.repository_jobs, scan_id) do
      %{status: "running"} = job ->
        public_event = public_repository_event(event)
        cursor = job.cursor + 1
        entry = %{cursor: cursor, event: public_event}

        {events, count, dropped} =
          :queue.in(entry, job.events)
          |> trim_repository_events(job.event_count + 1, job.dropped_events)

        candidates =
          case public_event do
            %{type: "candidate", candidate: candidate} -> [candidate | job.candidates]
            _other -> job.candidates
          end

        put_repository_job(
          state,
          %{job | events: events, event_count: count, dropped_events: dropped, cursor: cursor, candidates: candidates}
        )

      _job ->
        state
    end
  end

  defp trim_repository_events(events, count, dropped)
       when count > @max_repository_events do
    case :queue.out(events) do
      {{:value, _entry}, remaining} ->
        trim_repository_events(remaining, count - 1, dropped + 1)

      {:empty, _events} ->
        {:queue.new(), 0, dropped}
    end
  end

  defp trim_repository_events(events, count, dropped), do: {events, count, dropped}

  defp complete_repository_job(state, scan_id, outcome) do
    case Map.get(state.repository_jobs, scan_id) do
      %{status: "running", reference: reference} = job ->
        Process.cancel_timer(job.timer)
        Process.demonitor(reference, [:flush])
        result = repository_result(outcome)

        put_repository_job(
          %{state | repository_active: if(state.repository_active == scan_id, do: nil, else: state.repository_active)},
          %{job | status: result.status, pid: nil, reference: nil, timer: nil, result: result}
        )

      _job ->
        state
    end
  end

  defp configure_repository_timeout(state, scan_id, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    case Map.get(state.repository_jobs, scan_id) do
      %{status: "running", timer: timer} = job ->
        Process.cancel_timer(timer)
        timer = Process.send_after(self(), {:repository_timeout, scan_id}, min(timeout_ms, @repository_hard_timeout_ms))
        put_repository_job(state, %{job | timer: timer})

      _job ->
        state
    end
  end

  defp configure_repository_timeout(state, _scan_id, _timeout_ms), do: state

  defp timeout_repository_job(state, scan_id) do
    case Map.get(state.repository_jobs, scan_id) do
      %{status: "running"} = job ->
        state = cancel_repository_job(state, scan_id, :timeout)

        timed_out = %{
          job
          | status: "timeout",
            pid: nil,
            reference: nil,
            timer: nil,
            result: %{
              status: "timeout",
              candidates: Enum.reverse(job.candidates),
              errors: [%{code: "timeout"}],
              visited: nil
            }
        }

        put_repository_job(state, timed_out)

      _job ->
        state
    end
  end

  defp repository_worker_down(state, reference) do
    case Enum.find(state.repository_jobs, fn {_scan_id, job} -> job.reference == reference and job.status == "running" end) do
      {scan_id, _job} ->
        complete_repository_job(state, scan_id, {:error, :repository_discovery_failed})

      nil ->
        state
    end
  end

  defp repository_reference?(state, reference) do
    Enum.any?(state.repository_jobs, fn {_scan_id, job} -> job.reference == reference end)
  end

  defp handle_non_repository_down(reference, %{pending: %{reference: reference} = pending} = state) do
    outcome =
      command_error(:mutation_failed, true)
      |> Map.merge(Map.take(pending.result, [:id, :action, :identity]))
      |> Map.put(:status, "failed")

    {:noreply, record_result(%{state | pending: nil}, outcome)}
  end

  defp handle_non_repository_down(_reference, state), do: {:noreply, state}

  defp public_repository_event(event) when is_map(event) do
    case Map.get(event, :type) do
      "candidate" ->
        %{type: "candidate", candidate: public_repository_candidate(Map.fetch!(event, :candidate))}

      "error" ->
        %{type: "error", error: public_repository_error(Map.fetch!(event, :error))}

      value when is_binary(value) ->
        %{type: value}

      _value ->
        %{type: "event"}
    end
  end

  defp public_repository_event(_event), do: %{type: "event"}

  defp public_repository_error(error) when is_map(error) do
    error
    |> Map.take([:path, :code, :message, :reason])
    |> Map.reject(fn {_key, value} -> not is_binary(value) and not is_atom(value) end)
    |> Map.new(fn {key, value} -> {key, if(is_atom(value), do: Atom.to_string(value), else: value)} end)
    |> case do
      empty when map_size(empty) == 0 -> %{code: "repository_discovery_failed"}
      value -> value
    end
  end

  defp public_repository_error(error) when is_atom(error), do: %{code: Atom.to_string(error)}
  defp public_repository_error(error) when is_binary(error), do: %{code: error}
  defp public_repository_error(_error), do: %{code: "repository_discovery_failed"}

  defp repository_result({:ok, result}) when is_map(result) do
    status = repository_status(Map.fetch!(result, :status))
    candidates = Map.fetch!(result, :candidates)
    errors = Map.fetch!(result, :errors)
    visited = Map.fetch!(result, :visited)

    %{
      status: status,
      candidates: Enum.map(candidates, &public_repository_candidate/1),
      errors: errors |> Enum.take(@max_repository_errors) |> Enum.map(&public_repository_error/1),
      visited: if(is_integer(visited) and visited >= 0, do: visited, else: nil)
    }
  end

  defp repository_result({:ok, _result}), do: repository_result({:error, :repository_discovery_failed})

  defp repository_result({:error, reason}) do
    %{
      status: "failed",
      candidates: [],
      errors: [public_repository_error(reason)],
      visited: 0
    }
  end

  defp public_repository_candidate(candidate) when is_map(candidate) do
    %{path: Map.fetch!(candidate, :path), kind: "directory"}
  end

  defp public_repository_candidate(_candidate), do: %{path: "", kind: "directory"}

  defp repository_status("ok"), do: "completed"
  defp repository_status("error"), do: "failed"

  defp repository_status(status)
       when status in ["partial", "limit", "timeout", "cancelled", "completed", "failed"],
       do: status

  defp repository_status(_status), do: "failed"

  defp repository_response(state, job, after_cursor) do
    available =
      job.events
      |> :queue.to_list()
      |> Enum.filter(&(&1.cursor > after_cursor))

    selected = Enum.take(available, @max_repository_events)

    next_cursor =
      case List.last(selected) do
        nil -> after_cursor
        event -> event.cursor
      end

    terminal? = job.status != "running"

    %{
      interface_version: @interface_version,
      schema_version: @schema_version,
      host_id: state.host_id,
      scan_id: job.scan_id,
      action: job.action,
      status: job.status,
      events: Enum.map(selected, fn entry -> Map.put(entry.event, :cursor, entry.cursor) end),
      next_cursor: next_cursor,
      latest_cursor: job.cursor,
      dropped_events: job.dropped_events,
      result: if(terminal?, do: job.result, else: nil)
    }
  end

  defp put_repository_job(state, job) do
    order =
      [job.scan_id | Enum.reject(state.repository_order, &(&1 == job.scan_id))]
      |> Enum.take(@max_repository_jobs)

    jobs = Map.put(state.repository_jobs, job.scan_id, job)
    retained = Map.take(jobs, order)
    %{state | repository_jobs: retained, repository_order: order}
  end

  defp cancel_all_repository_jobs(state) do
    Enum.each(state.repository_jobs, fn {_scan_id, job} ->
      if job.status == "running" and is_pid(job.pid) do
        send(job.pid, :cancel)
        Process.exit(job.pid, :kill)
      end
    end)
  end

  defp repository_error(:operator_interface_unavailable),
    do: repository_error_payload("operator_interface_unavailable", "Operator interface is unavailable.")

  defp repository_error(:unauthorized),
    do: repository_error_payload("unauthorized", "A valid local operator session credential is required.")

  defp repository_error(:invalid_repository_request),
    do: repository_error_payload("invalid_repository_request", "Repository discovery request fields are invalid.")

  defp repository_error(:scan_not_found),
    do: repository_error_payload("scan_not_found", "The repository discovery scan was not found.")

  defp repository_error(reason) when is_atom(reason),
    do: repository_error_payload(Atom.to_string(reason), "Repository discovery could not be started.")

  defp repository_error_payload(code, message), do: %{error: %{code: code, message: message}}

  defp repository_request_expired?(deadline) when is_integer(deadline),
    do: deadline <= System.monotonic_time(:millisecond)

  defp repository_request_expired?(_deadline), do: true

  defp call_events(server, host_id, after_cursor, limit) do
    GenServer.call(server, {:events, host_id, after_cursor, limit})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp cast_event(server, kind, source, data) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:publish, kind, source, data})
      _missing -> :ok
    end
  end

  defp append_event(state, kind, source, data) do
    cursor = state.cursor + 1

    event = %{
      cursor: cursor,
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      kind: kind,
      source: source,
      data: compact_map(data)
    }

    bytes = :erlang.external_size(event)

    %{
      state
      | cursor: cursor,
        events: :queue.in({event, bytes}, state.events),
        event_count: state.event_count + 1,
        event_bytes: state.event_bytes + bytes
    }
    |> trim_events()
  end

  defp trim_events(%State{} = state)
       when state.event_count > state.max_events or state.event_bytes > state.max_bytes do
    case :queue.out(state.events) do
      {{:value, {_event, bytes}}, events} ->
        %{
          state
          | events: events,
            event_count: state.event_count - 1,
            event_bytes: state.event_bytes - bytes,
            dropped_events: state.dropped_events + 1
        }
        |> trim_events()

      {:empty, _events} ->
        %{state | event_count: 0, event_bytes: 0}
    end
  end

  defp trim_events(state), do: state

  defp event_response(state, host_id, after_cursor, limit) do
    events = :queue.to_list(state.events)
    first_available_cursor = first_available_cursor(events, state.cursor)

    gap_reason =
      cond do
        host_id != state.host_id -> "host_restarted"
        after_cursor > state.cursor -> "cursor_ahead"
        after_cursor < first_available_cursor - 1 -> "cursor_before_retention"
        true -> nil
      end

    if gap_reason do
      response_base(state, after_cursor, first_available_cursor)
      |> Map.put(:events, [])
      |> Map.put(:next_cursor, after_cursor)
      |> Map.put(:gap, %{detected: true, reason: gap_reason})
      |> Map.put(:snapshot_replacement, %{required: true, reason: gap_reason})
      |> Map.put(:truncation, truncation_metadata(state, false, first_available_cursor))
    else
      available =
        events
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&(&1.cursor > after_cursor))

      selected = Enum.take(available, limit)
      response_limited = length(available) > length(selected)

      next_cursor =
        case List.last(selected) do
          nil -> after_cursor
          event -> event.cursor
        end

      response_base(state, after_cursor, first_available_cursor)
      |> Map.put(:events, selected)
      |> Map.put(:next_cursor, next_cursor)
      |> Map.put(:gap, %{detected: false, reason: nil})
      |> Map.put(:snapshot_replacement, %{required: false, reason: nil})
      |> Map.put(:truncation, truncation_metadata(state, response_limited, first_available_cursor))
    end
  end

  defp response_base(state, after_cursor, first_available_cursor) do
    %{
      interface_version: @interface_version,
      schema_version: @schema_version,
      host_id: state.host_id,
      requested_after_cursor: after_cursor,
      first_available_cursor: first_available_cursor,
      latest_cursor: state.cursor
    }
  end

  defp truncation_metadata(state, response_limited, first_available_cursor) do
    %{
      retention_truncated: state.dropped_events > 0,
      dropped_events: state.dropped_events,
      retained_from_cursor: first_available_cursor,
      retained_through_cursor: state.cursor,
      response_limited: response_limited
    }
  end

  defp first_available_cursor([], cursor), do: cursor + 1
  defp first_available_cursor([{%{cursor: cursor}, _bytes} | _rest], _latest), do: cursor

  defp marker_from_state(state) do
    %{
      host_id: state.host_id,
      started_at: state.started_at,
      cursor: state.cursor,
      interface_version: @interface_version,
      schema_version: @schema_version,
      command_results: Enum.reverse(state.command_results)
    }
  end

  defp install_log_handler(server) do
    _ = :logger.remove_handler(@log_handler_id)

    case :logger.add_handler(
           @log_handler_id,
           SymphonyElixir.OperatorLogHandler,
           %{level: :all, config: %{server: server}}
         ) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp truncate_log(message) do
    bytes = byte_size(message)

    if bytes > @maximum_log_bytes do
      prefix = binary_part(message, 0, @maximum_log_bytes)
      {String.replace_invalid(prefix), %{truncated: true, original_bytes: bytes}}
    else
      {message, %{truncated: false, original_bytes: bytes}}
    end
  end

  defp redact_operator_log(message) do
    message
    |> Redaction.redact_operator_string()
    |> Redaction.redact_string()
  end

  defp compact_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp safe_string(value) when is_binary(value), do: redact_operator_log(value)
  defp safe_string(_value), do: nil

  defp safe_token(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_token(value) when is_binary(value), do: redact_operator_log(value)
  defp safe_token(_value), do: nil

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value) when is_binary(value), do: redact_operator_log(value)
  defp iso8601(_value), do: nil

  defp new_host_id do
    "host-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp command_call(server, message, uncertain?) do
    GenServer.call(server, message, 60_000)
  catch
    :exit, _reason -> {:error, command_error(:operator_interface_unavailable, uncertain?)}
  end

  defp validate_request(request, state, kind) when is_map(request) do
    keys = ~w(interface_version host_id registry_generation command)
    keys = if kind == :confirm, do: ["confirmation_token" | keys], else: keys

    cond do
      Enum.sort(Map.keys(request)) != Enum.sort(keys) -> {:error, :invalid_command_request}
      request["interface_version"] != @interface_version -> {:error, :incompatible_interface}
      request["host_id"] != state.host_id -> {:error, :host_mismatch}
      not valid_request_payload?(request) -> {:error, :invalid_command_request}
      kind == :confirm and not is_binary(request["confirmation_token"]) -> {:error, :invalid_confirmation}
      true -> :ok
    end
  end

  defp validate_request(_request, _state, _kind), do: {:error, :invalid_command_request}

  defp valid_request_payload?(request) do
    is_binary(request["registry_generation"]) and is_map(request["command"]) and
      :erlang.external_size(request) <= 65_536
  end

  defp mutation_idle(%{pending: nil}), do: :ok
  defp mutation_idle(_state), do: {:error, :mutation_in_progress}

  defp same_generation(generation, generation), do: :ok
  defp same_generation(_expected, _observed), do: {:error, :stale_generation}

  defp safely_preview(command, opts) do
    OperatorMutation.preview(command, opts)
  rescue
    _exception -> {:error, :preview_failed}
  catch
    _kind, _reason -> {:error, :preview_failed}
  end

  defp issue_preview(state, request, prepared, opts) do
    now = state.clock.()
    previews = Map.reject(state.previews, fn {_token, entry} -> entry.deadline <= now end)
    id = random_id("command-")
    enabled? = is_nil(prepared.disabled_reason)

    if enabled? and map_size(previews) >= @max_previews do
      reject_reply(%{state | previews: previews}, :preview_capacity)
    else
      token = if enabled?, do: random_id("confirm-"), else: nil

      payload =
        prepared
        |> Map.take([:identity, :current_state, :proposed_state, :consequences, :warnings, :disabled_reason])
        |> safe_projection()
        |> Map.merge(%{
          id: id,
          interface_version: @interface_version,
          host_id: state.host_id,
          registry_generation: prepared.registry_generation,
          action: request["command"]["action"],
          confirmation_token: token,
          expires_at:
            if(enabled?,
              do: DateTime.utc_now() |> DateTime.add(state.confirmation_ttl_ms, :millisecond) |> DateTime.to_iso8601(),
              else: nil
            )
        })

      previews =
        if enabled? do
          Map.put(previews, token, %{
            id: id,
            request: request,
            prepared: prepared,
            opts: opts,
            deadline: now + state.confirmation_ttl_ms
          })
        else
          previews
        end

      {:reply, {:ok, payload}, %{state | previews: previews}}
    end
  end

  defp consume_confirmation(state, request) do
    {entry, previews} = Map.pop(state.previews, request["confirmation_token"])
    state = %{state | previews: previews}

    with %{deadline: deadline} <- entry,
         true <- deadline > state.clock.(),
         true <- entry.request == Map.delete(request, "confirmation_token"),
         :ok <- mutation_idle(state),
         :ok <- current_generation(entry) do
      accept_confirmation(state, entry)
    else
      nil ->
        reject_reply(state, :invalid_confirmation)

      false ->
        reason = if entry.deadline <= state.clock.(), do: :confirmation_expired, else: :confirmation_mismatch
        reject_reply(state, reason, entry)

      {:error, reason} ->
        reject_reply(state, reason, entry)
    end
  end

  defp current_generation(entry) do
    scheduler = Keyword.get(entry.opts, :host_scheduler, HostScheduler)
    snapshot = HostScheduler.snapshot(scheduler)

    if get_in(snapshot, [:registry, :verified?]) == true do
      same_generation(entry.request["registry_generation"], get_in(snapshot, [:registry, :generation]))
    else
      {:error, :registry_unverified}
    end
  catch
    :exit, _reason -> {:error, :host_unavailable}
  end

  defp accept_confirmation(state, entry) do
    result = %{
      id: entry.id,
      action: entry.request["command"]["action"],
      identity: safe_projection(entry.prepared.identity),
      status: "accepted",
      state_may_have_changed: true,
      snapshot_required: true
    }

    # The token is removed before a worker can mutate. A dropped HTTP connection
    # cannot repeat the operation; completion remains observable by command ID.
    parent = self()

    {pid, reference} =
      :erlang.spawn_opt(
        fn ->
          receive do
            {:confirm, reference} ->
              outcome =
                try do
                  OperatorMutation.confirm(entry.prepared, entry.opts)
                rescue
                  _exception -> {:error, %{code: :mutation_failed, state_may_have_changed: true}}
                catch
                  _kind, _reason -> {:error, %{code: :mutation_failed, state_may_have_changed: true}}
                end

              send(parent, {reference, outcome})
          end
        end,
        [:link, :monitor]
      )

    state = record_result(state, result)
    send(pid, {:confirm, reference})
    {:reply, {:ok, result}, %{state | pending: %{reference: reference, result: result, opts: entry.opts}}}
  end

  defp reject_reply(state, reason, entry \\ nil) do
    result =
      command_error(reason, false)
      |> Map.merge(%{
        id: if(entry, do: entry.id, else: random_id("command-")),
        action: if(entry, do: entry.request["command"]["action"], else: nil),
        identity: if(entry, do: safe_projection(entry.prepared.identity), else: nil)
      })

    {:reply, {:error, result}, record_result(state, result)}
  end

  defp command_error(reason, uncertain?) do
    {code, changed?} =
      case reason do
        %{code: code, state_may_have_changed: changed?} when is_atom(code) or is_binary(code) -> {code, changed?}
        %{code: code, committed?: changed?} when is_atom(code) -> {code, changed?}
        code when is_atom(code) -> {code, uncertain?}
        _other -> {:mutation_failed, uncertain?}
      end

    %{
      status: "rejected",
      error: %{code: safe_string(to_string(code)), message: error_message(code)},
      state_may_have_changed: changed?,
      snapshot_required: true,
      next_safe_action: "Fetch a complete snapshot. Inspect the result. Request a new preview."
    }
  end

  defp error_message(:unauthorized), do: "A valid local operator session credential is required."
  defp error_message(:loopback_required), do: "Operator commands require a loopback connection."
  defp error_message(:confirmation_expired), do: "The command preview has expired."
  defp error_message(:stale_generation), do: "The registry generation changed after the snapshot or preview."
  defp error_message(:confirmation_mismatch), do: "The confirmation does not match the exact previewed command."
  defp error_message(:invalid_confirmation), do: "The confirmation token is unknown or has already been used."
  defp error_message(_code), do: "The host could not perform the requested operator command."

  defp record_result(state, result) do
    results =
      [result | Enum.reject(state.command_results, &(&1.id == result.id))]
      |> Enum.take(@max_command_results)

    %{state | command_results: results}
    |> append_event("command_result", "operator", result)
    |> append_event("snapshot_invalidated", "host", %{})
  end

  defp safe_projection(%_{} = value), do: value |> Map.from_struct() |> safe_projection()

  defp safe_projection(value) when is_map(value) do
    value
    |> Redaction.redact_secrets([])
    |> Map.new(fn {key, value} ->
      safe_value =
        if to_string(key) in ["prompt", "input", "evidence", "binding", "command"] do
          "<redacted>"
        else
          safe_projection(value)
        end

      {key, safe_value}
    end)
  end

  defp safe_projection(value) when is_list(value), do: Enum.map(value, &safe_projection/1)
  defp safe_projection(value) when is_binary(value), do: Redaction.redact_operator_string(value)
  defp safe_projection(value) when is_atom(value) or is_number(value), do: value
  defp safe_projection(_value), do: nil

  defp random_id(prefix), do: prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
