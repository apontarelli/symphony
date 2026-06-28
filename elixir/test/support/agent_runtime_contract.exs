defmodule SymphonyElixir.AgentRuntimeContract do
  @moduledoc false
  # credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting

  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    fake = Keyword.fetch!(opts, :fake)
    expected_runtime = Keyword.fetch!(opts, :expected_runtime)

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote bind_quoted: [adapter: adapter, fake: fake, expected_runtime: expected_runtime] do
      use SymphonyElixir.TestSupport

      alias SymphonyElixir.AgentRuntime.Event

      @agent_runtime_adapter adapter
      @agent_runtime_fake fake
      @agent_runtime_expected_runtime expected_runtime
      @normalized_event_types [
        :session_started,
        :turn_started,
        :message_delta,
        :tool_call,
        :tool_result,
        :turn_completed,
        :turn_failed,
        :blocked
      ]

      setup context do
        previous_codex_home = System.get_env("SYMPHONY_CODEX_HOME")
        System.delete_env("SYMPHONY_CODEX_HOME")
        runtime_context = @agent_runtime_fake.setup!(context)

        on_exit(fn ->
          restore_env("SYMPHONY_CODEX_HOME", previous_codex_home)
          @agent_runtime_fake.cleanup!(runtime_context)
        end)

        {:ok, runtime_context: runtime_context}
      end

      test "starts a session and preserves workspace and harness isolation", %{runtime_context: runtime_context} do
        runtime_context = @agent_runtime_fake.install!(runtime_context, :start_only)

        assert {:ok, session} =
                 @agent_runtime_adapter.start(runtime_context.workspace, runtime_issue(runtime_context), startup_timeout_ms: 1_000)

        try do
          assert @agent_runtime_fake.session_thread_id(session) == "thread-contract-start"
          {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(runtime_context.workspace)
          expected_codex_home = Path.join([Path.dirname(canonical_workspace), ".symphony", "codex_home"])

          assert @agent_runtime_fake.trace_value(runtime_context, "PWD:") == canonical_workspace
          assert @agent_runtime_fake.trace_value(runtime_context, "ENV_CODEX_HOME:") == expected_codex_home
          assert @agent_runtime_fake.trace_value(runtime_context, "AGENTS:") == "# Symphony Harness"
          refute File.exists?(Path.join(runtime_context.workspace, ".symphony"))
        after
          assert :ok = @agent_runtime_adapter.stop(session)
        end
      end

      test "emits normalized events for a successful turn", %{runtime_context: runtime_context} do
        runtime_context = @agent_runtime_fake.install!(runtime_context, :successful_turn)
        test_pid = self()
        on_event = fn event -> send(test_pid, {:runtime_event, event}) end

        assert {:ok, session} =
                 @agent_runtime_adapter.start(runtime_context.workspace, runtime_issue(runtime_context), startup_timeout_ms: 1_000)

        try do
          assert {:ok, %{session_id: "thread-contract-success-turn-contract-success"}} =
                   @agent_runtime_adapter.send_turn(
                     session,
                     "Complete the contract turn",
                     runtime_issue(runtime_context),
                     on_event: on_event,
                     turn_timeout_ms: 1_000
                   )

          events = received_runtime_events()
          assert Enum.map(events, & &1.event) == [:session_started, :turn_completed]
          assert Enum.all?(events, &(Event.validate(&1) == :ok))
          assert_no_native_event_names_leak(events)
          assert Enum.all?(events, &(&1.runtime == @agent_runtime_expected_runtime))
          assert Enum.all?(events, &(&1.event in @normalized_event_types))
        after
          assert :ok = @agent_runtime_adapter.stop(session)
        end
      end

      test "emits normalized tool call and result events", %{runtime_context: runtime_context} do
        runtime_context = @agent_runtime_fake.install!(runtime_context, :tool_call)
        test_pid = self()
        on_event = fn event -> send(test_pid, {:runtime_event, event}) end

        tool_executor = fn tool, arguments ->
          send(test_pid, {:tool_called, tool, arguments})

          %{
            "success" => true,
            "contentItems" => [
              %{"type" => "inputText", "text" => ~s({"ok":true})}
            ]
          }
        end

        assert {:ok, session} =
                 @agent_runtime_adapter.start(runtime_context.workspace, runtime_issue(runtime_context), startup_timeout_ms: 1_000)

        try do
          assert {:ok, _result} =
                   @agent_runtime_adapter.send_turn(
                     session,
                     "Exercise a tool call",
                     runtime_issue(runtime_context),
                     on_event: on_event,
                     tool_executor: tool_executor,
                     turn_timeout_ms: 1_000
                   )

          assert_received {:tool_called, "linear_graphql",
                           %{
                             "query" => "query Contract { viewer { id } }",
                             "variables" => %{"includeTeams" => false}
                           }}

          events = received_runtime_events()
          assert [:session_started, :tool_call, :tool_result, :turn_completed] = Enum.map(events, & &1.event)
          assert_no_native_event_names_leak(events)
        after
          assert :ok = @agent_runtime_adapter.stop(session)
        end
      end

      test "emits normalized tool result for tool failures", %{runtime_context: runtime_context} do
        runtime_context = @agent_runtime_fake.install!(runtime_context, :tool_failure)
        test_pid = self()
        on_event = fn event -> send(test_pid, {:runtime_event, event}) end

        tool_executor = fn tool, arguments ->
          send(test_pid, {:tool_called, tool, arguments})

          %{
            "success" => false,
            "contentItems" => [
              %{"type" => "inputText", "text" => ~s({"error":"boom"})}
            ]
          }
        end

        assert {:ok, session} =
                 @agent_runtime_adapter.start(runtime_context.workspace, runtime_issue(runtime_context), startup_timeout_ms: 1_000)

        try do
          assert {:ok, _result} =
                   @agent_runtime_adapter.send_turn(
                     session,
                     "Exercise a failed tool call",
                     runtime_issue(runtime_context),
                     on_event: on_event,
                     tool_executor: tool_executor,
                     turn_timeout_ms: 1_000
                   )

          assert_received {:tool_called, "linear_graphql", %{"query" => "query ContractFailure"}}

          events = received_runtime_events()
          assert [:session_started, :tool_call, :tool_result, :turn_completed] = Enum.map(events, & &1.event)
          assert_no_native_event_names_leak(events)
        after
          assert :ok = @agent_runtime_adapter.stop(session)
        end
      end

      test "maps operator input requests to blocked runtime events", %{runtime_context: runtime_context} do
        runtime_context = @agent_runtime_fake.install!(runtime_context, :operator_input)
        test_pid = self()
        on_event = fn event -> send(test_pid, {:runtime_event, event}) end

        assert {:ok, session} =
                 @agent_runtime_adapter.start(runtime_context.workspace, runtime_issue(runtime_context), startup_timeout_ms: 1_000)

        try do
          assert {:error, {:turn_input_required, input_payload}} =
                   @agent_runtime_adapter.send_turn(
                     session,
                     "Ask for operator input",
                     runtime_issue(runtime_context),
                     on_event: on_event,
                     turn_timeout_ms: 1_000
                   )

          assert input_payload["method"] == "turn/input_required"

          events = received_runtime_events()
          assert [:session_started, :blocked, :turn_failed] = Enum.map(events, & &1.event)
          assert %Event{event: :blocked, reason: :operator_input_requested} = Enum.at(events, 1)

          assert %Event{event: :turn_failed, payload: %{reason: {:turn_input_required, ^input_payload}}} =
                   List.last(events)

          assert_no_native_event_names_leak(events)
        after
          assert :ok = @agent_runtime_adapter.stop(session)
        end
      end

      test "times out startup when the fake binary never becomes ready", %{runtime_context: runtime_context} do
        runtime_context = @agent_runtime_fake.install!(runtime_context, :startup_timeout)

        assert {:error, {:startup_failed, {:timeout, 80}}} =
                 @agent_runtime_adapter.start(runtime_context.workspace, runtime_issue(runtime_context), startup_timeout_ms: 80)
      end

      test "stops the runtime process and descendant processes where supported", %{runtime_context: runtime_context} do
        if SymphonyElixir.ProcessSupervisor.descendant_cleanup_supported?() do
          runtime_context = @agent_runtime_fake.install!(runtime_context, :descendant_cleanup)

          assert {:ok, session} =
                   @agent_runtime_adapter.start(runtime_context.workspace, runtime_issue(runtime_context), startup_timeout_ms: 1_000)

          child_pid = eventually(fn -> @agent_runtime_fake.child_pid(runtime_context) end)
          assert os_pid_alive?(child_pid)
          assert :ok = @agent_runtime_adapter.stop(session)
          assert eventually(fn -> stopped_when_not_alive(child_pid) end) == :stopped
        else
          assert SymphonyElixir.ProcessSupervisor.descendant_cleanup_supported?() == false
        end
      end

      defp stopped_when_not_alive(os_pid) do
        if os_pid_alive?(os_pid), do: nil, else: :stopped
      end

      defp runtime_issue(runtime_context) do
        %SymphonyElixir.Linear.Issue{
          id: "issue-agent-runtime-contract",
          identifier: runtime_context.issue_identifier,
          title: "AgentRuntime contract",
          description: "Shared adapter contract test issue",
          state: "In Progress",
          url: "https://example.org/issues/#{runtime_context.issue_identifier}",
          labels: ["runtime"]
        }
      end

      defp received_runtime_events do
        receive_runtime_events([])
      end

      defp receive_runtime_events(events) do
        receive do
          {:runtime_event, %Event{} = event} -> receive_runtime_events(events ++ [event])
        after
          0 -> events
        end
      end

      defp assert_no_native_event_names_leak(events) do
        leaked_event_names = [
          :"thread/start",
          :"turn/start",
          :"turn/completed",
          :"turn/failed",
          :"turn/input_required",
          :"item/tool/call",
          "thread/start",
          "turn/start",
          "turn/completed",
          "turn/failed",
          "turn/input_required",
          "item/tool/call"
        ]

        refute Enum.any?(events, &(&1.event in leaked_event_names))
        refute Enum.any?(events, &(to_string(&1.event) =~ "/"))
      end
    end
  end
end

defmodule SymphonyElixir.AgentRuntimeContract.FakeCodex do
  @moduledoc false

  def setup!(_context) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runtime-contract-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "SID-351")
    trace_file = Path.join(test_root, "fake-codex.trace")
    child_pid_file = Path.join(test_root, "child.pid")
    binary = Path.join(test_root, "fake-codex")

    File.mkdir_p!(workspace)

    %{
      test_root: test_root,
      workspace_root: workspace_root,
      workspace: workspace,
      trace_file: trace_file,
      child_pid_file: child_pid_file,
      binary: binary,
      issue_identifier: "SID-351"
    }
  end

  def cleanup!(context) do
    context
    |> child_pid()
    |> kill_os_pid()

    File.rm_rf(context.test_root)
  end

  def install!(context, scenario) do
    write_fake_binary!(context, scenario)

    SymphonyElixir.TestSupport.write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      workspace_root: context.workspace_root,
      codex_command: "#{context.binary} app-server"
    )

    context
  end

  def session_thread_id(%{thread_id: thread_id}), do: thread_id

  def trace_value(context, prefix) do
    context
    |> trace_lines()
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, prefix) do
        String.trim_leading(line, prefix)
      end
    end)
  end

  def trace_decoded_message?(context, predicate) when is_function(predicate, 1) do
    context
    |> trace_lines()
    |> Enum.any?(fn line ->
      with "JSON:" <> json <- line,
           {:ok, payload} <- Jason.decode(json) do
        predicate.(payload)
      else
        _ -> false
      end
    end)
  end

  def child_pid(context) do
    case File.read(context.child_pid_file) do
      {:ok, pid_text} ->
        case Integer.parse(String.trim(pid_text)) do
          {pid, ""} -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp write_fake_binary!(context, scenario) do
    File.write!(context.binary, fake_binary_script(context, scenario))
    File.chmod!(context.binary, 0o755)
  end

  defp fake_binary_script(context, :start_only) do
    base_script(context, "thread-contract-start", """
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      trace_json "$line"
      case "$count" in
        1)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-contract-start"}}}'
          sleep 60
          ;;
        *)
          sleep 60
          ;;
      esac
    done
    """)
  end

  defp fake_binary_script(context, :successful_turn) do
    base_script(context, "thread-contract-success", """
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      trace_json "$line"
      case "$count" in
        1)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-contract-success"}}}'
          ;;
        3)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-contract-success"}}}'
          printf '%s\n' '{"method":"turn/completed","usage":{"input_tokens":1,"output_tokens":2}}'
          sleep 60
          ;;
        *)
          sleep 60
          ;;
      esac
    done
    """)
  end

  defp fake_binary_script(context, :tool_call) do
    base_script(
      context,
      "thread-contract-tool",
      tool_script_body(
        "thread-contract-tool",
        101,
        "turn-contract-tool",
        ~s({"query":"query Contract { viewer { id } }","variables":{"includeTeams":false}})
      )
    )
  end

  defp fake_binary_script(context, :tool_failure) do
    base_script(
      context,
      "thread-contract-tool-failure",
      tool_script_body(
        "thread-contract-tool-failure",
        102,
        "turn-contract-tool-failure",
        ~s({"query":"query ContractFailure"})
      )
    )
  end

  defp fake_binary_script(context, :operator_input) do
    base_script(context, "thread-contract-input", """
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      trace_json "$line"
      case "$count" in
        1)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-contract-input"}}}'
          ;;
        3)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-contract-input"}}}'
          printf '%s\n' '{"method":"turn/input_required","id":"input-1","params":{"requiresInput":true,"reason":"operator"}}'
          sleep 60
          ;;
        *)
          sleep 60
          ;;
      esac
    done
    """)
  end

  defp fake_binary_script(context, :startup_timeout) do
    base_script(context, "thread-timeout", """
    while IFS= read -r line; do
      trace_json "$line"
      printf '%s\n' '{"method":"noise"}'
      sleep 1
    done
    """)
  end

  defp fake_binary_script(context, :descendant_cleanup) do
    base_script(context, "thread-contract-descendant", """
    child_pid=""
    sleep 60 &
    child_pid="$!"
    printf '%s\n' "$child_pid" > "#{shell_escape(context.child_pid_file)}"

    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      trace_json "$line"
      case "$count" in
        1)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-contract-descendant"}}}'
          wait "$child_pid"
          ;;
        *)
          sleep 60
          ;;
      esac
    done
    """)
  end

  defp tool_script_body(thread_id, request_id, turn_id, arguments_json) do
    """
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      trace_json "$line"
      case "$count" in
        1)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"#{thread_id}"}}}'
          ;;
        3)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"#{turn_id}"}}}'
          printf '%s\n' '{"id":#{request_id},"method":"item/tool/call","params":{"tool":"linear_graphql","callId":"call-#{request_id}","threadId":"#{thread_id}","turnId":"#{turn_id}","arguments":#{arguments_json}}}'
          ;;
        4)
          printf '%s\n' '{"method":"turn/completed"}'
          sleep 60
          ;;
        *)
          sleep 60
          ;;
      esac
    done
    """
  end

  defp base_script(context, _thread_id, body) do
    """
    #!/bin/sh
    trace_file="#{shell_escape(context.trace_file)}"
    trace_json() {
      printf 'JSON:%s\n' "$1" >> "$trace_file"
    }
    printf 'PWD:%s\n' "$PWD" >> "$trace_file"
    printf 'ENV_CODEX_HOME:%s\n' "${CODEX_HOME:-}" >> "$trace_file"
    if [ -n "${CODEX_HOME:-}" ] && [ -f "$CODEX_HOME/AGENTS.md" ]; then
      first_agents_line=$(sed -n '1p' "$CODEX_HOME/AGENTS.md")
      printf 'AGENTS:%s\n' "$first_agents_line" >> "$trace_file"
    else
      printf 'AGENTS:MISSING\n' >> "$trace_file"
    fi

    #{body}
    """
  end

  defp trace_text(context) do
    case File.read(context.trace_file) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp trace_lines(context) do
    context
    |> trace_text()
    |> String.split("\n", trim: true)
  end

  defp shell_escape(path) do
    String.replace(path, "\"", "\\\"")
  end

  defp kill_os_pid(nil), do: :ok

  defp kill_os_pid(pid) when is_integer(pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end
end
