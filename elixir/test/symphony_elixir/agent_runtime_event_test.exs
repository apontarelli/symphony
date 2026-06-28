defmodule SymphonyElixir.AgentRuntimeEventTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.AgentRuntime.Event

  test "AgentRuntime declares the adapter callbacks expected by orchestration" do
    assert {:start, 3} in AgentRuntime.behaviour_info(:callbacks)
    assert {:send_turn, 3} in AgentRuntime.behaviour_info(:callbacks)
    assert {:stop, 1} in AgentRuntime.behaviour_info(:callbacks)
    assert {:capabilities, 1} in AgentRuntime.behaviour_info(:callbacks)
  end

  test "constructors create normalized runtime events with common metadata" do
    timestamp = DateTime.utc_now()

    assert {:ok,
            %Event{
              event: :session_started,
              runtime: :codex_app_server,
              session_id: "thread-1-turn-1",
              timestamp: ^timestamp,
              native: %{"method" => "thread/start"},
              usage: %{input_tokens: 10},
              payload: %{thread_id: "thread-1"}
            }} =
             Event.session_started(
               runtime: :codex_app_server,
               session_id: "thread-1-turn-1",
               timestamp: timestamp,
               native: %{"method" => "thread/start"},
               usage: %{input_tokens: 10},
               payload: %{thread_id: "thread-1"}
             )
  end

  test "generic constructor normalizes string event names to atoms" do
    assert {:ok, %Event{event: :turn_completed, payload: %{result: :ok}}} =
             Event.new("turn_completed", payload: %{result: :ok})
  end

  test "named constructors cover the normalized event vocabulary" do
    constructors = [
      session_started: :session_started,
      turn_started: :turn_started,
      message_delta: :message_delta,
      tool_call: :tool_call,
      tool_result: :tool_result,
      turn_completed: :turn_completed,
      turn_failed: :turn_failed
    ]

    for {constructor, event_type} <- constructors do
      assert {:ok, %Event{event: ^event_type, timestamp: %DateTime{}, payload: %{}}} =
               apply(Event, constructor, [])
    end
  end

  test "blocked is represented as a runtime event with a required reason" do
    assert {:ok, %Event{event: :blocked, reason: :operator_input_requested} = event} =
             Event.blocked(:operator_input_requested,
               runtime: :codex_app_server,
               session_id: "thread-1-turn-2",
               payload: %{questions: [%{id: "operator-context"}]}
             )

    refute Map.has_key?(Map.from_struct(event), :tracker_state)
    assert :ok = Event.validate(event)

    assert {:ok, %Event{event: :blocked, reason: "operator_input_requested"} = minimal_event} =
             Event.blocked("operator_input_requested")

    assert :ok = Event.validate(minimal_event)
    assert {:error, :blocked_reason_required} = Event.new(:blocked)
    assert {:error, :blocked_reason_required} = Event.blocked("")
  end

  test "validation rejects unknown events and malformed optional fields" do
    assert {:error, {:invalid_event, "turn/completed"}} = Event.new("turn/completed")
    assert {:error, {:invalid_event, :approval_required}} = Event.new(:approval_required)
    assert {:error, {:invalid_attrs, [:not_keyword]}} = Event.new(:turn_started, [:not_keyword])
    assert {:error, {:invalid_attrs, "attrs"}} = Event.new(:turn_started, "attrs")
    timestamp = DateTime.utc_now()
    assert {:error, {:invalid_attrs, ^timestamp}} = Event.new(:turn_started, timestamp)
    assert {:error, {:invalid_payload, "hello"}} = Event.message_delta(payload: "hello")
    assert {:error, {:invalid_timestamp, "soon"}} = Event.turn_started(timestamp: "soon")
    assert {:error, {:invalid_runtime, 42}} = Event.turn_started(runtime: 42)
    assert {:error, {:invalid_session_id, :session}} = Event.turn_started(session_id: :session)
    assert {:error, {:invalid_native, []}} = Event.tool_call(native: [])
    assert {:error, {:invalid_usage, "many"}} = Event.tool_result(usage: "many")
    assert {:error, {:invalid_event_struct, %{}}} = Event.validate(%{})
    assert {:error, {:invalid_event, :unknown}} = Event.validate(%Event{event: :unknown})

    assert {:error, {:invalid_event, "turn_completed"}} =
             Event.validate(%Event{event: "turn_completed", timestamp: DateTime.utc_now(), payload: %{}})

    assert {:error, {:invalid_event, "blocked"}} =
             Event.validate(%Event{event: "blocked", timestamp: DateTime.utc_now(), payload: %{}})
  end

  test "validation accepts string-keyed attributes without atomizing unknown payload fields" do
    assert {:ok, %Event{event: :message_delta, runtime: "codex_app_server", session_id: "session-1"}} =
             Event.new("message_delta", %{
               "runtime" => "codex_app_server",
               "session_id" => "session-1",
               123 => "ignored by validation",
               "payload" => %{"delta" => "hello"}
             })
  end
end
