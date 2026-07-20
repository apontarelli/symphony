defmodule SymphonyElixir.AgentRuntimeDispatchTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.AgentRuntime.Session
  alias SymphonyElixir.Config.Schema

  defmodule CaptureAdapter do
    @behaviour AgentRuntime

    @impl true
    def start(workspace, issue, opts) do
      send(Keyword.fetch!(opts, :probe), {:started, workspace, issue, opts})
      {:ok, %{probe: Keyword.fetch!(opts, :probe), id: "native-session"}}
    end

    @impl true
    def send_turn(session, prompt, issue, opts) do
      send(session.probe, {:turn, session, prompt, issue, opts})
      {:ok, %{session_id: session.id, result: :completed}}
    end

    @impl true
    def stop(session) do
      send(session.probe, {:stopped, session})
      :ok
    end

    @impl true
    def capabilities(config), do: %{kind: config["kind"], command: config["command"]}
  end

  test "dispatches start, turn, stop, and capabilities through the selected runner kind" do
    assert {:ok, settings} =
             Schema.parse(%{
               agent: %{default_runner: "open"},
               runners: %{
                 open: %{
                   kind: "opencode_server",
                   command: ["opencode", "serve"],
                   model: "anthropic/claude-sonnet-4-5",
                   agent: "build"
                 }
               },
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    registry = %{"opencode_server" => CaptureAdapter}
    issue = %{id: "issue-1"}

    assert {:ok,
            %Session{
              adapter: CaptureAdapter,
              adapter_session: %{id: "native-session"},
              runner_name: "open",
              runner_kind: "opencode_server",
              runner_config: %{"kind" => "opencode_server"}
            } = session} =
             AgentRuntime.start_session("/tmp/workspace", issue,
               settings: settings,
               adapter_registry: registry,
               probe: self()
             )

    assert_receive {:started, "/tmp/workspace", ^issue, start_opts}
    assert start_opts[:runner_name] == "open"
    assert start_opts[:runner_config]["kind"] == "opencode_server"
    assert start_opts[:runner_config]["hostname"] == "127.0.0.1"
    assert start_opts[:runner_config]["port"] == "auto"
    assert start_opts[:runtime_settings] == settings
    refute Keyword.has_key?(start_opts, :settings)
    refute Keyword.has_key?(start_opts, :adapter_registry)

    assert {:ok, %{session_id: "native-session", result: :completed}} =
             AgentRuntime.send_turn(session, "continue", issue,
               settings: :must_not_reselect,
               adapter_registry: :must_not_reselect,
               on_event: fn _event -> :ok end
             )

    assert_receive {:turn, %{id: "native-session"}, "continue", ^issue, turn_opts}
    assert is_function(turn_opts[:on_event], 1)
    assert turn_opts[:runner_name] == "open"
    assert turn_opts[:runner_config]["kind"] == "opencode_server"
    refute Keyword.has_key?(turn_opts, :settings)
    refute Keyword.has_key?(turn_opts, :adapter_registry)

    assert :ok = AgentRuntime.stop_session(session)
    assert_receive {:stopped, %{id: "native-session"}}

    assert %{kind: "opencode_server", command: ["opencode", "serve"]} =
             AgentRuntime.capabilities(settings: settings, adapter_registry: registry)
  end

  test "preserves the Codex default and reports an unavailable selected adapter" do
    assert {:ok, codex_settings} =
             Schema.parse(%{profiles: %{default: %{delivery: %{pr_target: "main"}}}})

    assert {:ok, CaptureAdapter, "codex", %{"kind" => "codex_app_server"}} =
             AgentRuntime.resolve_adapter(codex_settings, %{"codex_app_server" => CaptureAdapter})

    assert {:ok, opencode_settings} =
             Schema.parse(%{
               agent: %{default_runner: "open"},
               runners: %{open: %{kind: "opencode_server", command: ["opencode", "serve"]}},
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    assert %{adapter: :opencode_server, client_side_tools: [], continuation_turns: true} =
             AgentRuntime.capabilities(settings: opencode_settings)

    assert {:error, {:runner_adapter_unavailable, "open", "opencode_server"}} =
             AgentRuntime.start_session("/tmp/workspace", %{},
               settings: opencode_settings,
               adapter_registry: %{}
             )
  end
end
