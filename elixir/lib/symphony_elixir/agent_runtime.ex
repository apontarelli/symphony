defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Behaviour for coding-agent runtime adapters.

  `AgentRuntime` is the internal seam between orchestration and a concrete
  coding-agent runner. Adapters own native protocol translation and emit
  `SymphonyElixir.AgentRuntime.Event` values to orchestration through the
  callback options they support.

  This contract is additive; the current Codex app-server path is not switched
  to this behaviour until orchestration is ready to consume normalized events.
  """

  alias SymphonyElixir.AgentRuntime.Event

  @type adapter_config :: term()
  @type capabilities :: map()
  @type event_handler :: (Event.t() -> term())
  @type issue :: term()
  @type prompt :: String.t()
  @type reason :: term()
  @type session :: term()
  @type start_option :: {:on_event, event_handler()} | {atom(), term()}
  @type send_turn_option :: {:on_event, event_handler()} | {atom(), term()}
  @type turn_result :: term()

  @doc """
  Starts a runtime session in a prepared workspace for an issue.

  Adapters should return after the native session is ready to receive a turn.
  """
  @callback start(Path.t(), issue(), [start_option()]) :: {:ok, session()} | {:error, reason()}

  @doc """
  Sends one prompt turn to an active runtime session.

  Adapters should translate native runner messages into normalized
  `AgentRuntime.Event` values and deliver them to `opts[:on_event]` when the
  option is present.
  """
  @callback send_turn(session(), prompt(), [send_turn_option()]) ::
              {:ok, turn_result()} | {:error, reason()}

  @doc """
  Stops an active runtime session and releases adapter-owned resources.
  """
  @callback stop(session()) :: :ok | {:error, reason()}

  @doc """
  Returns adapter capabilities that orchestration can use for policy decisions.
  """
  @callback capabilities(adapter_config()) :: capabilities()
end
