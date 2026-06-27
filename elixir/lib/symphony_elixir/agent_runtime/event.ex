defmodule SymphonyElixir.AgentRuntime.Event do
  @moduledoc """
  Normalized runtime event emitted by an `AgentRuntime` adapter.

  The event vocabulary is intentionally runner-neutral. Native Codex app-server
  messages or future runner payloads belong in `native`; orchestration-facing
  information belongs in the normalized event fields and `payload`.
  """

  @type event_type ::
          :session_started
          | :turn_started
          | :message_delta
          | :tool_call
          | :tool_result
          | :turn_completed
          | :turn_failed
          | :blocked

  @type runtime :: atom() | String.t()
  @type blocked_reason :: atom() | String.t()
  @type attrs :: keyword() | map()

  @type t :: %__MODULE__{
          event: event_type(),
          timestamp: DateTime.t(),
          runtime: runtime() | nil,
          session_id: String.t() | nil,
          native: map() | nil,
          usage: map() | nil,
          payload: map(),
          reason: blocked_reason() | nil
        }

  defstruct [:event, :timestamp, :runtime, :session_id, :native, :usage, :reason, payload: %{}]

  @event_types [
    :session_started,
    :turn_started,
    :message_delta,
    :tool_call,
    :tool_result,
    :turn_completed,
    :turn_failed,
    :blocked
  ]

  @event_type_by_name Map.new(@event_types, &{Atom.to_string(&1), &1})
  @attr_keys %{
    "event" => :event,
    "timestamp" => :timestamp,
    "runtime" => :runtime,
    "session_id" => :session_id,
    "native" => :native,
    "usage" => :usage,
    "payload" => :payload,
    "reason" => :reason
  }

  @doc """
  Builds and validates a normalized runtime event.
  """
  @spec new(event_type() | String.t(), attrs()) :: {:ok, t()} | {:error, term()}
  def new(event, attrs \\ []) do
    with {:ok, event_type} <- normalize_event(event),
         {:ok, attrs} <- normalize_attrs(attrs),
         :ok <- validate_timestamp(attrs),
         :ok <- validate_runtime(attrs),
         :ok <- validate_session_id(attrs),
         :ok <- validate_native(attrs),
         :ok <- validate_usage(attrs),
         :ok <- validate_payload(attrs),
         :ok <- validate_reason(event_type, attrs) do
      {:ok,
       %__MODULE__{
         event: event_type,
         timestamp: Map.get(attrs, :timestamp, DateTime.utc_now()),
         runtime: Map.get(attrs, :runtime),
         session_id: Map.get(attrs, :session_id),
         native: Map.get(attrs, :native),
         usage: Map.get(attrs, :usage),
         payload: Map.get(attrs, :payload, %{}),
         reason: Map.get(attrs, :reason)
       }}
    end
  end

  @doc """
  Builds a `session_started` event.
  """
  @spec session_started(attrs()) :: {:ok, t()} | {:error, term()}
  def session_started(attrs \\ []), do: new(:session_started, attrs)

  @doc """
  Builds a `turn_started` event.
  """
  @spec turn_started(attrs()) :: {:ok, t()} | {:error, term()}
  def turn_started(attrs \\ []), do: new(:turn_started, attrs)

  @doc """
  Builds a `message_delta` event.
  """
  @spec message_delta(attrs()) :: {:ok, t()} | {:error, term()}
  def message_delta(attrs \\ []), do: new(:message_delta, attrs)

  @doc """
  Builds a `tool_call` event.
  """
  @spec tool_call(attrs()) :: {:ok, t()} | {:error, term()}
  def tool_call(attrs \\ []), do: new(:tool_call, attrs)

  @doc """
  Builds a `tool_result` event.
  """
  @spec tool_result(attrs()) :: {:ok, t()} | {:error, term()}
  def tool_result(attrs \\ []), do: new(:tool_result, attrs)

  @doc """
  Builds a `turn_completed` event.
  """
  @spec turn_completed(attrs()) :: {:ok, t()} | {:error, term()}
  def turn_completed(attrs \\ []), do: new(:turn_completed, attrs)

  @doc """
  Builds a `turn_failed` event.
  """
  @spec turn_failed(attrs()) :: {:ok, t()} | {:error, term()}
  def turn_failed(attrs \\ []), do: new(:turn_failed, attrs)

  @doc """
  Builds a `blocked` event with a required machine-readable reason.
  """
  @spec blocked(blocked_reason(), attrs()) :: {:ok, t()} | {:error, term()}
  def blocked(reason, attrs \\ []) do
    with {:ok, attrs} <- normalize_attrs(attrs) do
      new(:blocked, Map.put(attrs, :reason, reason))
    end
  end

  @doc """
  Validates an existing event struct.
  """
  @spec validate(t() | term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = event) do
    with {:ok, attrs} <- event |> Map.from_struct() |> normalize_attrs(),
         :ok <- validate_event_type(event.event),
         :ok <- validate_timestamp(attrs),
         :ok <- validate_runtime(attrs),
         :ok <- validate_session_id(attrs),
         :ok <- validate_native(attrs),
         :ok <- validate_usage(attrs),
         :ok <- validate_payload(attrs) do
      validate_reason(event.event, attrs)
    end
  end

  def validate(value), do: {:error, {:invalid_event_struct, value}}

  defp validate_event_type(event) when event in @event_types, do: :ok
  defp validate_event_type(event), do: {:error, {:invalid_event, event}}

  defp normalize_event(event) when event in @event_types, do: {:ok, event}

  defp normalize_event(event) when is_binary(event) do
    event
    |> String.trim()
    |> then(&Map.fetch(@event_type_by_name, &1))
    |> case do
      {:ok, event_type} -> {:ok, event_type}
      :error -> {:error, {:invalid_event, event}}
    end
  end

  defp normalize_event(event), do: {:error, {:invalid_event, event}}

  defp normalize_attrs(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      {:ok, Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)}
    else
      {:error, {:invalid_attrs, attrs}}
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs) and not is_struct(attrs) do
    {:ok, Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)}
  end

  defp normalize_attrs(attrs), do: {:error, {:invalid_attrs, attrs}}

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: Map.get(@attr_keys, key, key)
  defp normalize_key(key), do: key

  defp validate_timestamp(%{timestamp: %DateTime{}}), do: :ok
  defp validate_timestamp(%{timestamp: timestamp}), do: {:error, {:invalid_timestamp, timestamp}}
  defp validate_timestamp(_attrs), do: :ok

  defp validate_runtime(%{runtime: nil}), do: :ok
  defp validate_runtime(%{runtime: runtime}) when is_atom(runtime) or is_binary(runtime), do: :ok
  defp validate_runtime(%{runtime: runtime}), do: {:error, {:invalid_runtime, runtime}}
  defp validate_runtime(_attrs), do: :ok

  defp validate_session_id(%{session_id: nil}), do: :ok
  defp validate_session_id(%{session_id: session_id}) when is_binary(session_id), do: :ok
  defp validate_session_id(%{session_id: session_id}), do: {:error, {:invalid_session_id, session_id}}
  defp validate_session_id(_attrs), do: :ok

  defp validate_native(%{native: nil}), do: :ok
  defp validate_native(%{native: native}) when is_map(native), do: :ok
  defp validate_native(%{native: native}), do: {:error, {:invalid_native, native}}
  defp validate_native(_attrs), do: :ok

  defp validate_usage(%{usage: nil}), do: :ok
  defp validate_usage(%{usage: usage}) when is_map(usage), do: :ok
  defp validate_usage(%{usage: usage}), do: {:error, {:invalid_usage, usage}}
  defp validate_usage(_attrs), do: :ok

  defp validate_payload(%{payload: payload}) when is_map(payload), do: :ok
  defp validate_payload(%{payload: payload}), do: {:error, {:invalid_payload, payload}}
  defp validate_payload(_attrs), do: :ok

  defp validate_reason(:blocked, %{reason: reason}) when is_atom(reason) and not is_nil(reason), do: :ok

  defp validate_reason(:blocked, %{reason: reason}) when is_binary(reason) do
    if String.trim(reason) == "" do
      {:error, :blocked_reason_required}
    else
      :ok
    end
  end

  defp validate_reason(:blocked, _attrs), do: {:error, :blocked_reason_required}
  defp validate_reason(_event, _attrs), do: :ok
end
