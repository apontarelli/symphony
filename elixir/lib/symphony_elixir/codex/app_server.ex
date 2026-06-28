defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Compatibility facade for the Codex app-server AgentRuntime adapter.

  Orchestration code should use `SymphonyElixir.AgentRuntime`; Codex-specific
  protocol handling lives in `SymphonyElixir.AgentRuntime.CodexAppServer`.
  """

  alias SymphonyElixir.AgentRuntime.CodexAppServer

  @type session :: CodexAppServer.session()

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate run(workspace, prompt, issue, opts \\ []), to: CodexAppServer

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  defdelegate start_session(workspace, opts \\ []), to: CodexAppServer

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate run_turn(session, prompt, issue, opts \\ []), to: CodexAppServer

  @spec stop_session(session()) :: :ok
  defdelegate stop_session(session), to: CodexAppServer
end
