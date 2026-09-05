defmodule SymphonyElixir.OperatorInterface do
  @moduledoc """
  Owns the versioned operator event cursor and bounded event retention.

  A client must fetch a complete snapshot before it consumes events. The
  snapshot cursor is the lower bound for subsequent event reads. A host ID
  change or a cursor outside the retained range requires another complete
  snapshot.
  """

  use GenServer

  alias SymphonyElixir.OperatorSnapshot
  alias SymphonyElixir.ReviewRecords.Redaction

  @interface_version 1
  @schema_version 1
  @default_max_events 2_000
  @default_max_bytes 2 * 1024 * 1024
  @default_event_limit 200
  @maximum_event_limit 500
  @maximum_log_bytes 4_096
  @log_handler_id :symphony_operator_log

  defmodule State do
    @moduledoc false

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
    defstruct @enforce_keys
  end

  @type marker :: %{
          host_id: String.t(),
          started_at: String.t(),
          cursor: non_neg_integer(),
          interface_version: pos_integer(),
          schema_version: pos_integer()
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

  @spec snapshot(
          GenServer.server(),
          GenServer.server(),
          GenServer.server() | nil,
          timeout()
        ) :: {:ok, map()} | {:error, :unavailable}
  def snapshot(server \\ __MODULE__, scheduler, control_plane, timeout) do
    with {:ok, marker} <- marker(server) do
      {:ok, OperatorSnapshot.build(scheduler, control_plane, timeout, marker)}
    end
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
    started_at = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    log_handler_installed? = Keyword.get(opts, :install_log_handler, true)

    state = %State{
      host_id: Keyword.get_lazy(opts, :host_id, &new_host_id/0),
      started_at: started_at,
      cursor: 0,
      events: :queue.new(),
      event_count: 0,
      event_bytes: 0,
      max_events: positive_option(opts, :max_events, @default_max_events),
      max_bytes: positive_option(opts, :max_bytes, @default_max_bytes),
      dropped_events: 0,
      log_handler_installed?: log_handler_installed?
    }

    if log_handler_installed?, do: install_log_handler(Keyword.fetch!(opts, :name))

    {:ok, state}
  end

  @impl true
  def terminate(_reason, %State{log_handler_installed?: true}) do
    _ = :logger.remove_handler(@log_handler_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call(:marker, _from, state) do
    {:reply, {:ok, marker_from_state(state)}, state}
  end

  def handle_call({:events, host_id, after_cursor, limit}, _from, state) do
    {:reply, {:ok, event_response(state, host_id, after_cursor, limit)}, state}
  end

  @impl true
  def handle_cast({:publish, kind, source, data}, state) do
    {:noreply, append_event(state, kind, source, data)}
  end

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
      schema_version: @schema_version
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
end
