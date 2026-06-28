defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Runtime seam consumed by orchestration code.

  `AgentRuntime` is the internal boundary between orchestration and a concrete
  coding-agent runner. Adapters own native protocol translation and emit
  `SymphonyElixir.AgentRuntime.Event` values to orchestration through the
  callback options they support.

  The current implementation has one real adapter, Codex app-server. This module
  keeps callers on the runner-agnostic boundary while `CodexAppServer` owns the
  native Codex protocol and launch details.
  """

  alias SymphonyElixir.AgentRuntime.{CodexAppServer, Event}

  @type adapter_config :: term()
  @type capabilities :: map()
  @type event_handler :: (Event.t() -> term())
  @type issue :: term()
  @type prompt :: String.t()
  @type reason :: term()
  @type session :: map() | term()
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

  The issue is passed per turn so orchestration can use refreshed tracker
  metadata for continuation turns without restarting the native runtime session.
  Adapters should translate native runner messages into normalized
  `AgentRuntime.Event` values and deliver them to `opts[:on_event]` when the
  option is present.
  """
  @callback send_turn(session(), prompt(), issue(), [send_turn_option()]) ::
              {:ok, turn_result()} | {:error, reason()}

  @doc """
  Stops an active runtime session and releases adapter-owned resources.
  """
  @callback stop(session()) :: :ok | {:error, reason()}

  @doc """
  Returns adapter capabilities that orchestration can use for policy decisions.
  """
  @callback capabilities(adapter_config()) :: capabilities()

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    CodexAppServer.run(workspace, prompt, issue, opts)
  end

  @spec start_session(Path.t(), map(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, _issue, opts \\ []) do
    CodexAppServer.start_session(workspace, opts)
  end

  @spec send_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_turn(session, prompt, issue, opts \\ []) do
    CodexAppServer.send_turn(session, prompt, issue, opts)
  end

  @spec stop_session(session()) :: :ok
  def stop_session(session) do
    CodexAppServer.stop_session(session)
  end

  @spec capabilities() :: map()
  def capabilities do
    CodexAppServer.capabilities()
  end
end
