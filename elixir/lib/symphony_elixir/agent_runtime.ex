defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Runtime seam consumed by orchestration code.

  `AgentRuntime` selects an adapter from a pinned execution context. Adapters own
  native protocol translation and emit `SymphonyElixir.AgentRuntime.Event`
  values to orchestration through the callback options they support.
  """
  require Logger

  alias SymphonyElixir.AgentRuntime.{CodexAppServer, Event, OpenCodeServer}
  alias SymphonyElixir.{ExecutionContext, ProcessSupervisor}

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

  defmodule Session do
    @moduledoc false

    @enforce_keys [:adapter, :adapter_session, :runner_name, :runner_kind, :runner_config]
    defstruct [:adapter, :adapter_session, :runner_name, :runner_kind, :runner_config, :context]

    @type t :: %__MODULE__{
            adapter: module(),
            adapter_session: term(),
            runner_name: String.t(),
            runner_kind: String.t(),
            runner_config: map(),
            context: ExecutionContext.t()
          }
  end

  @doc """
  Starts a runtime session in a prepared workspace for an issue.

  Adapters should return after the native session is ready to receive a turn.
  """
  @callback start(ExecutionContext.t(), issue(), [start_option()]) ::
              {:ok, session()} | {:error, reason()}

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
  @spec run(ExecutionContext.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def run(%ExecutionContext{} = context, prompt, issue),
    do: run(context, prompt, issue, [])

  @spec run(ExecutionContext.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(%ExecutionContext{} = context, prompt, issue, opts) do
    with {:ok, opts} <- validate_context_options(opts, context_run_options()) do
      run_with_session(
        context,
        prompt,
        issue,
        Keyword.take(opts, [:adapter_registry]),
        Keyword.drop(opts, [:adapter_registry])
      )
    end
  end

  defp run_with_session(%ExecutionContext{} = context, prompt, issue, start_opts, turn_opts) do
    with {:ok, session} <- start_session(context, issue, start_opts) do
      turn_result =
        try do
          {:returned, send_turn(session, prompt, issue, turn_opts)}
        rescue
          error -> {:raised, :error, error, __STACKTRACE__}
        catch
          kind, reason -> {:raised, kind, reason, __STACKTRACE__}
        end

      finish_run(turn_result, stop_session_safely(session))
    end
  end

  defp stop_session_safely(session) do
    case stop_session(session) do
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

  defp finish_run({:returned, result}, :ok), do: result

  defp finish_run(
         {:returned, {:error, primary_reason}},
         {:error, cleanup_reason}
       ) do
    {:error, {:agent_run_failed, primary_reason, {:runtime_cleanup_failed, cleanup_reason}}}
  end

  defp finish_run({:returned, _result}, {:error, cleanup_reason}),
    do: {:error, {:runtime_cleanup_failed, cleanup_reason}}

  defp finish_run({:raised, kind, reason, stacktrace}, cleanup_result) do
    if cleanup_result != :ok do
      Logger.error("Agent runtime cleanup failed while preserving raised failure: #{inspect(cleanup_result)}")
    end

    :erlang.raise(kind, reason, stacktrace)
  end

  @spec start_session(ExecutionContext.t(), map()) ::
          {:ok, Session.t()} | {:error, term()}
  def start_session(%ExecutionContext{} = context, issue),
    do: start_session(context, issue, [])

  @spec start_session(ExecutionContext.t(), map(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def start_session(%ExecutionContext{} = context, issue, opts) do
    with {:ok, opts} <- validate_context_options(opts, [:adapter_registry]),
         :ok <- validate_context_issue(context, issue),
         {:ok, adapter, runner_kind} <- resolve_context_dispatch(context, opts),
         {:ok, adapter_session} <- adapter.start(context, issue, []) do
      {:ok,
       %Session{
         adapter: adapter,
         adapter_session: adapter_session,
         runner_name: context.runner_name,
         runner_kind: runner_kind,
         runner_config: context.runner_config,
         context: context
       }}
    end
  end

  @doc """
  Returns the stable local process identity used for fenced restart recovery.
  """
  @spec recovery_identity(Session.t()) ::
          {:ok, ProcessSupervisor.recovery_identity()} | {:error, :recovery_identity_unavailable | term()}
  def recovery_identity(%Session{
        adapter_session: %{process: %ProcessSupervisor{} = process}
      }),
      do: ProcessSupervisor.recovery_identity(process)

  def recovery_identity(%Session{}), do: {:error, :recovery_identity_unavailable}

  @spec send_turn(Session.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def send_turn(session, prompt, issue), do: send_turn(session, prompt, issue, [])

  @spec send_turn(Session.t(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def send_turn(%Session{context: %ExecutionContext{} = context} = session, prompt, issue, opts) do
    with {:ok, opts} <- validate_context_options(opts, context_turn_options()),
         :ok <- ExecutionContext.validate(context),
         :ok <- validate_context_issue(context, issue) do
      session.adapter.send_turn(session.adapter_session, prompt, issue, opts)
    end
  end

  def send_turn(_session, _prompt, _issue, _opts),
    do: {:error, :invalid_agent_runtime_session}

  @spec stop_session(Session.t()) :: :ok | {:error, term()}
  def stop_session(%Session{
        context: %ExecutionContext{} = context,
        adapter: adapter,
        adapter_session: adapter_session
      }) do
    with :ok <- ExecutionContext.validate(context) do
      adapter.stop(adapter_session)
    end
  end

  def stop_session(_session), do: {:error, :invalid_agent_runtime_session}

  @spec capabilities(ExecutionContext.t()) :: map() | {:error, term()}
  def capabilities(%ExecutionContext{} = context), do: capabilities(context, [])

  @spec capabilities(ExecutionContext.t(), keyword()) :: map() | {:error, term()}
  def capabilities(%ExecutionContext{} = context, opts) do
    with {:ok, opts} <- validate_context_options(opts, [:adapter_registry]),
         {:ok, adapter, _runner_kind} <- resolve_context_dispatch(context, opts) do
      adapter.capabilities(context.runner_config)
    end
  end

  def capabilities(_context, _opts), do: {:error, :invalid_agent_runtime_context}

  defp resolve_context_dispatch(context, opts) do
    adapter_registry = Keyword.get(opts, :adapter_registry, default_adapter_registry())

    with :ok <- ExecutionContext.validate(context),
         {:ok, runner_kind} <- runner_kind(context.runner_name, context.runner_config),
         {:ok, adapter} <-
           fetch_adapter(adapter_registry, context.runner_name, runner_kind) do
      {:ok, adapter, runner_kind}
    else
      {:error, :invalid_context} -> {:error, :invalid_agent_runtime_context}
      {:error, _reason} = error -> error
    end
  end

  defp validate_context_issue(
         %ExecutionContext{issue_id: issue_id, issue_identifier: issue_identifier},
         %{id: issue_id, identifier: issue_identifier}
       ),
       do: :ok

  defp validate_context_issue(_context, _issue),
    do: {:error, :agent_runtime_issue_mismatch}

  defp validate_context_options(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) and length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      {:ok, opts}
    else
      {:error, :invalid_agent_runtime_options}
    end
  end

  defp validate_context_options(_opts, _allowed),
    do: {:error, :invalid_agent_runtime_options}

  defp context_run_options,
    do: [:adapter_registry | context_turn_options()]

  defp context_turn_options,
    do: [:on_event, :tool_executor, :on_turn_task_result_sent]

  defp runner_kind(_runner_name, %{"kind" => kind}) when is_binary(kind) and kind != "",
    do: {:ok, kind}

  defp runner_kind(runner_name, _runner_config),
    do: {:error, {:invalid_runner_kind, runner_name}}

  defp fetch_adapter(adapter_registry, runner_name, runner_kind) do
    case Map.fetch(adapter_registry, runner_kind) do
      {:ok, adapter} when is_atom(adapter) ->
        if Code.ensure_loaded?(adapter) and
             function_exported?(adapter, :start, 3) and
             function_exported?(adapter, :send_turn, 4) and
             function_exported?(adapter, :stop, 1) and
             function_exported?(adapter, :capabilities, 1) do
          {:ok, adapter}
        else
          {:error, {:invalid_runner_adapter, runner_name, runner_kind, adapter}}
        end

      _missing ->
        {:error, {:runner_adapter_unavailable, runner_name, runner_kind}}
    end
  end

  defp default_adapter_registry do
    %{"codex_app_server" => CodexAppServer, "opencode_server" => OpenCodeServer}
  end
end
