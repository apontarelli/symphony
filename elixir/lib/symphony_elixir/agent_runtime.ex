defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Runtime seam consumed by orchestration code.

  `AgentRuntime` selects an adapter from the configured default runner kind.
  Adapters own native protocol translation and emit
  `SymphonyElixir.AgentRuntime.Event` values to orchestration through the
  callback options they support.
  """

  alias SymphonyElixir.AgentRuntime.{CodexAppServer, Event, OpenCodeServer}
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema

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
    defstruct [:adapter, :adapter_session, :runner_name, :runner_kind, :runner_config]

    @type t :: %__MODULE__{
            adapter: module(),
            adapter_session: term(),
            runner_name: String.t(),
            runner_kind: String.t(),
            runner_config: map()
          }
  end

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
    with {:ok, session} <- start_session(workspace, issue, opts) do
      try do
        send_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), map(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def start_session(workspace, issue, opts \\ []) do
    with {:ok, adapter, runner_name, runner_config, settings} <- resolve_dispatch(opts),
         {:ok, adapter_session} <-
           adapter.start(
             workspace,
             issue,
             start_adapter_opts(opts, runner_name, runner_config, settings)
           ) do
      {:ok,
       %Session{
         adapter: adapter,
         adapter_session: adapter_session,
         runner_name: runner_name,
         runner_kind: runner_config["kind"],
         runner_config: runner_config
       }}
    end
  end

  @spec send_turn(Session.t(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def send_turn(session, prompt, issue, opts \\ []) do
    case session do
      %Session{
        adapter: adapter,
        adapter_session: adapter_session,
        runner_name: runner_name,
        runner_config: runner_config
      } ->
        adapter.send_turn(
          adapter_session,
          prompt,
          issue,
          adapter_opts(opts, runner_name, runner_config)
        )

      _invalid_session ->
        {:error, :invalid_agent_runtime_session}
    end
  end

  @spec stop_session(Session.t()) :: :ok | {:error, term()}
  def stop_session(%Session{adapter: adapter, adapter_session: adapter_session}) do
    adapter.stop(adapter_session)
  end

  def stop_session(_session), do: {:error, :invalid_agent_runtime_session}

  @spec capabilities(keyword()) :: map() | {:error, term()}
  def capabilities(opts \\ []) do
    with {:ok, adapter, _runner_name, runner_config, _settings} <- resolve_dispatch(opts) do
      adapter.capabilities(runner_config)
    end
  end

  @doc false
  @spec resolve_adapter(Schema.t(), %{optional(String.t()) => module()}) ::
          {:ok, module(), String.t(), map()} | {:error, term()}
  def resolve_adapter(%Schema{} = settings, adapter_registry \\ default_adapter_registry())
      when is_map(adapter_registry) do
    runner_name = Schema.default_runner_name(settings)

    with {:ok, runner_config} <- Schema.default_runner_config(settings),
         {:ok, runner_kind} <- runner_kind(runner_name, runner_config),
         {:ok, adapter} <- fetch_adapter(adapter_registry, runner_name, runner_kind) do
      {:ok, adapter, runner_name, runner_config}
    end
  end

  defp resolve_dispatch(opts) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)
    adapter_registry = Keyword.get(opts, :adapter_registry, default_adapter_registry())

    with {:ok, adapter, runner_name, runner_config} <- resolve_adapter(settings, adapter_registry) do
      {:ok, adapter, runner_name, runner_config, settings}
    end
  end

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

  defp start_adapter_opts(opts, runner_name, runner_config, settings) do
    opts
    |> adapter_opts(runner_name, runner_config)
    |> Keyword.put(:runtime_settings, settings)
  end

  defp adapter_opts(opts, runner_name, runner_config) do
    opts
    |> strip_dispatch_opts()
    |> Keyword.put(:runner_name, runner_name)
    |> Keyword.put(:runner_config, runner_config)
  end

  defp strip_dispatch_opts(opts), do: Keyword.drop(opts, [:settings, :adapter_registry])
end
