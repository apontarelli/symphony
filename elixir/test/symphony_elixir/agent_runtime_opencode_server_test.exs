defmodule SymphonyElixir.AgentRuntimeOpenCodeServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.AgentRuntime.{Event, OpenCodeServer}
  alias SymphonyElixir.{ExecutionContext, PathSafety, ProcessSupervisor, TargetContext}
  alias SymphonyElixir.Linear.Issue

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-opencode-server-test-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-opencode.py")
    trace = Path.join(test_root, "requests.trace")
    contract_trace = Path.join(test_root, "contract.trace")
    child_pid_file = Path.join(test_root, "child.pid")
    grandchild_pid_file = Path.join(test_root, "grandchild.pid")
    python = System.find_executable("python3") || flunk("python3 is required for the fake OpenCode server")

    provider_key =
      Enum.find(
        ~w(OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_API_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY),
        &is_nil(System.get_env(&1))
      ) || flunk("one supported provider key must be unset for environment isolation coverage")

    File.mkdir_p!(workspace)
    File.write!(script, fake_server_script())
    File.chmod!(script, 0o755)

    on_exit(fn ->
      [child_pid_file, grandchild_pid_file]
      |> Enum.map(&read_child_pid/1)
      |> Enum.each(&kill_pid/1)

      File.rm_rf(test_root)
    end)

    {:ok,
     context: %{
       child_pid_file: child_pid_file,
       grandchild_pid_file: grandchild_pid_file,
       contract_trace: contract_trace,
       python: python,
       provider_key: provider_key,
       script: script,
       trace: trace,
       workspace: workspace
     }}
  end

  test "context facade pins OpenCode profile after global workflow poisoning", %{
    context: context
  } do
    runner =
      context
      |> runner_config(:success)
      |> Map.put("model", "anthropic/global-fallback")
      |> Map.put("execution_profiles", %{
        "implementation" => %{
          "model" => "anthropic/pinned-opencode",
          "timeout_ms" => 750,
          "max_retries" => 0
        }
      })

    issue = %Issue{
      id: "issue-opencode-context",
      identifier: "SID-383",
      title: "Pinned OpenCode context"
    }

    target = context_target(context, runner)
    assert {:ok, execution_context} = ExecutionContext.new(target, issue, policy: %{"capabilities" => %{"required" => []}})
    File.mkdir_p!(execution_context.workspace_path)

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      codex_command: "/definitely/missing/codex app-server"
    )

    assert {:ok, session} = AgentRuntime.start_session(execution_context, issue)

    try do
      assert session.context == execution_context
      assert session.runner_kind == "opencode_server"
      assert session.adapter_session.execution_context == execution_context

      assert session.adapter_session.execution_profile.model == %{
               "modelID" => "pinned-opencode",
               "providerID" => "anthropic"
             }

      assert session.adapter_session.turn_timeout_ms == 750

      assert {:ok, %{session_id: "session-contract-message-success"}} =
               AgentRuntime.send_turn(session, "Pinned facade prompt", issue)
    after
      assert :ok = AgentRuntime.stop_session(session)
    end
  end

  test "starts locally, reuses the OpenCode session, and emits normalized successful turns", %{
    context: context
  } do
    assert {:ok, session} = start_adapter(context, :success)
    os_pid = ProcessSupervisor.identity(session.process).os_pid
    state_pid = session.state
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    try do
      assert is_integer(os_pid)
      assert os_pid_alive?(os_pid)
      assert session.session_id == "session-contract"

      assert {:ok, %{session_id: "session-contract-message-success", usage: usage}} =
               OpenCodeServer.send_turn(session, "First prompt", issue(), on_event: on_event)

      assert usage == %{
               "cache_read_tokens" => 3,
               "cache_write_tokens" => 0,
               "cost" => 0.01,
               "input_tokens" => 11,
               "output_tokens" => 7,
               "reasoning_tokens" => 2,
               "total_tokens" => 18
             }

      first_events = received_events()

      assert Enum.map(first_events, & &1.event) == [
               :session_started,
               :turn_started,
               :message_delta,
               :turn_completed
             ]

      assert Enum.all?(first_events, &(Event.validate(&1) == :ok))
      assert Enum.all?(first_events, &(&1.runtime == :opencode_server))
      assert Enum.all?(first_events, &(not String.contains?(Atom.to_string(&1.event), "/")))

      assert {:ok,
              %{
                session_id: "session-contract-message-success",
                usage: %{
                  "cache_read_tokens" => 6,
                  "cache_write_tokens" => 0,
                  "cost" => 0.02,
                  "input_tokens" => 22,
                  "output_tokens" => 14,
                  "reasoning_tokens" => 4,
                  "total_tokens" => 36
                }
              }} =
               OpenCodeServer.send_turn(session, "Continuation", issue(), on_event: on_event)

      assert Enum.map(received_events(), & &1.event) == [
               :turn_started,
               :message_delta,
               :turn_completed
             ]

      assert %{
               adapter: :opencode_server,
               client_side_tools: ["linear_graphql"],
               continuation_turns: true,
               unattended_permissions: true
             } =
               OpenCodeServer.capabilities(session.runner_config)
    after
      assert :ok = OpenCodeServer.stop(session)
    end

    assert eventually(fn -> if os_pid_alive?(os_pid), do: nil, else: :stopped end) == :stopped
    refute Process.alive?(state_pid)

    lifecycle_paths =
      context
      |> request_paths()
      |> Enum.filter(
        &(&1 in [
            "POST /session/session-contract/abort",
            "DELETE /session/session-contract",
            "POST /instance/dispose"
          ])
      )

    assert lifecycle_paths == [
             "POST /session/session-contract/abort",
             "DELETE /session/session-contract",
             "POST /instance/dispose"
           ]
  end

  test "streams authoritative assistant and tool progress for each continuation turn", %{
    context: context
  } do
    assert {:ok, session} = start_adapter(context, :progress_slow)
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    try do
      assert {:ok, _result} =
               OpenCodeServer.send_turn(session, "Long turn", issue(), on_event: on_event)

      first_events = received_events()
      first_progress = Enum.filter(first_events, &(&1.event == :turn_progress))

      assert Enum.map(first_progress, & &1.payload.kind) == [
               :assistant_message,
               :message_part,
               :tool_activity
             ]

      assert Enum.any?(first_progress, fn event ->
               event.payload.kind == :message_part and
                 Jason.encode!(event.native) =~ "secret-progress-text" and
                 not String.contains?(inspect(event.payload), "secret-progress-text")
             end)

      assert List.last(first_events).event == :turn_completed

      assert {:ok, _result} =
               OpenCodeServer.send_turn(session, "Continuation", issue(), on_event: on_event)

      continuation_events = received_events()
      assert Enum.count(continuation_events, &(&1.event == :turn_progress)) == 3
      assert List.first(continuation_events).event == :turn_started
      assert List.last(continuation_events).event == :turn_completed
    after
      OpenCodeServer.stop(session)
    end
  end

  test "bounded progress draining cannot starve completion", %{context: context} do
    assert {:ok, session} = start_adapter(context, :progress_flood)
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    try do
      assert {:ok, _result} =
               OpenCodeServer.send_turn(session, "Flood progress", issue(),
                 on_event: on_event,
                 turn_timeout_ms: 1_000
               )

      events = received_events()
      assert Enum.count(events, &(&1.event == :turn_progress)) >= 64
      assert List.last(events).event == :turn_completed
    after
      OpenCodeServer.stop(session)
    end
  end

  test "ignores progress from unrelated sessions and workspaces", %{context: context} do
    assert {:ok, session} = start_adapter(context, :unrelated_progress)
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    try do
      assert {:ok, _result} =
               OpenCodeServer.send_turn(session, "Ignore unrelated progress", issue(), on_event: on_event)

      events = received_events()
      refute Enum.any?(events, &(&1.event == :turn_progress))
      assert List.last(events).event == :turn_completed
    after
      OpenCodeServer.stop(session)
    end
  end

  test "fails before prompt submission when the progress stream is unavailable", %{
    context: context
  } do
    assert {:ok, session} = start_adapter(context, :progress_stream_http_error)

    try do
      assert {:error, {:progress_stream_failed, {:http_error, 500, ""}}} =
               OpenCodeServer.send_turn(session, "Do not submit", issue(), [])

      refute "POST /session/session-contract/message" in request_paths(context)
    after
      OpenCodeServer.stop(session)
    end
  end

  test "maps completed native tool parts to tool call and result events", %{context: context} do
    assert {:ok, session} = start_adapter(context, :tool)
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    try do
      assert {:ok, _result} =
               OpenCodeServer.send_turn(session, "Use a tool", issue(), on_event: on_event)

      events = received_events()

      assert Enum.map(events, & &1.event) == [
               :session_started,
               :turn_started,
               :tool_call,
               :tool_result,
               :turn_completed
             ]

      assert %Event{
               event: :tool_call,
               payload: %{tool: "read", input: %{"path" => "README.md"}}
             } = Enum.at(events, 2)

      assert %Event{event: :tool_result, payload: %{success: true, output: "contents"}} =
               Enum.at(events, 3)
    after
      OpenCodeServer.stop(session)
    end
  end

  test "applies the selected OpenCode profile command and model request shape", %{context: context} do
    base_runner = runner_config(context, :failure)
    profile_runner = runner_config(context, :success)

    runner =
      Map.merge(base_runner, %{
        "agent" => "contract-agent",
        "model" => "base/provider",
        "execution_profiles" => %{
          "implementation" => %{
            "command" => profile_runner["command"],
            "model" => "profile/model"
          }
        }
      })

    assert {:ok, session} =
             start_opencode_context(context.workspace, issue(),
               runner_config: runner,
               execution_profile: "implementation",
               startup_timeout_ms: 1_000
             )

    try do
      assert {:ok, _result} =
               OpenCodeServer.send_turn(session, "Complete profile prompt", issue(), [])

      [startup | requests] = contract_records(context)
      assert Enum.at(startup["argv"], 0) == "success"

      assert [
               %{
                 "body" => %{
                   "agent" => "contract-agent",
                   "model" => %{"modelID" => "model", "providerID" => "profile"},
                   "parts" => [%{"text" => "Complete profile prompt", "type" => "text"}]
                 },
                 "method" => "POST",
                 "path" => "/session/session-contract/message"
               }
             ] = requests
    after
      OpenCodeServer.stop(session)
    end
  end

  test "creates and removes a private config overlay for each run", %{context: context} do
    runner =
      runner_config(context, :success)
      |> Map.merge(%{
        "config_content" => %{"theme" => "dark"},
        "permissions" => %{"bash" => "deny"},
        "server_auth" => %{"password" => "env:OPENCODE_TEST_PASSWORD"}
      })

    System.put_env("OPENCODE_TEST_PASSWORD", "overlay-secret")

    try do
      assert {:ok, session} =
               start_opencode_context(context.workspace, issue(),
                 runner_config: runner,
                 startup_timeout_ms: 1_000
               )

      overlay = session.config_overlay
      assert File.exists?(Path.join(overlay, "opencode.json"))
      refute File.read!(Path.join(overlay, "opencode.json")) =~ "overlay-secret"
      assert Jason.decode!(File.read!(Path.join(overlay, "opencode.json")))["permission"] == %{"bash" => "deny"}
      assert :ok = OpenCodeServer.stop(session)
      refute File.exists?(overlay)
    after
      System.delete_env("OPENCODE_TEST_PASSWORD")
    end
  end

  test "fails before launch when an auth secret reference is absent", %{context: context} do
    System.delete_env("OPENCODE_TEST_PASSWORD")

    assert {:error, {:auth_missing, "OPENCODE_TEST_PASSWORD"}} =
             start_opencode_context(context.workspace, issue(),
               runner_config:
                 Map.put(runner_config(context, :success), "server_auth", %{
                   "password" => "env:OPENCODE_TEST_PASSWORD"
                 })
             )
  end

  test "rejects malformed OpenCode profile command and model values", %{context: context} do
    runner = runner_config(context, :success)

    assert {:error, {:invalid_opencode_profile_command, "implementation", "not-an-argv"}} =
             start_opencode_context(context.workspace, issue(),
               runner_config:
                 Map.put(runner, "execution_profiles", %{
                   "implementation" => %{"command" => "not-an-argv"}
                 })
             )

    assert {:error, {:invalid_opencode_profile_model, "implementation", 42}} =
             start_opencode_context(context.workspace, issue(),
               runner_config:
                 Map.put(runner, "execution_profiles", %{
                   "implementation" => %{"model" => 42}
                 })
             )
  end

  test "fails a blocking queue HTTP error after bounded retries", %{context: context} do
    assert {:ok, session} = start_adapter(context, :poll_http_500)
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    try do
      assert {:error, {:blocking_poll_failed, "/question", {:http_error, 500, %{"error" => "queue unavailable"}}}} =
               OpenCodeServer.send_turn(session, "Poll failure", issue(),
                 on_event: on_event,
                 turn_timeout_ms: 1_000
               )

      assert Enum.count(request_paths(context), &(&1 == "GET /question")) == 3

      assert %Event{
               event: :turn_failed,
               payload: %{
                 reason: {:blocking_poll_failed, "/question", {:http_error, 500, %{"error" => "queue unavailable"}}}
               }
             } = List.last(received_events())
    after
      OpenCodeServer.stop(session)
    end
  end

  test "drains a task result sent while aborting after a blocking poll failure", %{
    context: context
  } do
    assert {:ok, session} = start_adapter(context, :abort_result_race)

    test_pid = self()
    unrelated_message = {make_ref(), :keep}
    send(self(), unrelated_message)

    on_result_sent = fn task_ref ->
      send(test_pid, {:turn_task_result_sent, task_ref})
      turn_task_result_ack(session).(task_ref)
    end

    try do
      assert {:error, {:blocking_poll_failed, "/question", {:http_error, 500, %{"error" => "queue unavailable"}}}} =
               OpenCodeServer.send_turn(session, "Abort completion race", issue(),
                 on_turn_task_result_sent: on_result_sent,
                 turn_timeout_ms: 1_000
               )

      assert "POST /test/turn-task-result-sent" in request_paths(context)
      assert_receive {:turn_task_result_sent, task_ref}
      refute_receive {^task_ref, {:ok, %{"info" => %{"id" => "message-success"}}}}
      assert_receive ^unrelated_message
    after
      OpenCodeServer.stop(session)
    end
  end

  test "completed turn wins when the first blocking queue poll fails", %{context: context} do
    assert {:ok, session} = start_adapter(context, :completion_poll_race)
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    try do
      assert {:ok, %{session_id: "session-contract-message-success"}} =
               OpenCodeServer.send_turn(session, "Complete during queue poll", issue(),
                 on_event: on_event,
                 on_turn_task_result_sent: turn_task_result_ack(session),
                 turn_timeout_ms: 1_000
               )

      assert %Event{event: :turn_completed} = List.last(received_events())

      paths = request_paths(context)
      assert Enum.count(paths, &(&1 == "GET /question")) == 1
      assert "POST /test/turn-task-result-sent" in paths
      refute "POST /session/session-contract/abort" in paths
    after
      OpenCodeServer.stop(session)
    end
  end

  test "completed turn wins when the permission poll reaches the turn deadline", %{context: context} do
    assert {:ok, session} = start_adapter(context, :completion_permission_deadline_race)
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    try do
      assert {:ok, %{session_id: "session-contract-message-success"}} =
               OpenCodeServer.send_turn(session, "Complete at permission deadline", issue(),
                 on_event: on_event,
                 on_turn_task_result_sent: turn_task_result_ack(session),
                 turn_timeout_ms: 300
               )

      assert %Event{event: :turn_completed} = List.last(received_events())
      refute "POST /session/session-contract/abort" in request_paths(context)
      assert "POST /test/turn-task-result-sent" in request_paths(context)
    after
      OpenCodeServer.stop(session)
    end
  end

  test "fails a malformed blocking queue response without retrying", %{context: context} do
    assert {:ok, session} = start_adapter(context, :poll_malformed)

    try do
      assert {:error, {:blocking_poll_failed, "/question", {:invalid_blocking_queue_response, %{"not" => "a queue"}}}} =
               OpenCodeServer.send_turn(session, "Malformed queue", issue(), turn_timeout_ms: 1_000)

      assert Enum.count(request_paths(context), &(&1 == "GET /question")) == 1
    after
      OpenCodeServer.stop(session)
    end
  end

  test "retains failed-turn usage in the next successful cumulative total", %{context: context} do
    assert {:ok, session} = start_adapter(context, :failure_then_success)
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    try do
      assert {:error, {:turn_failed, _error}} =
               OpenCodeServer.send_turn(session, "First failed turn", issue(), on_event: on_event)

      assert %Event{event: :turn_failed, usage: failed_usage} = List.last(received_events())
      assert failed_usage["total_tokens"] == 18
      assert failed_usage["cost"] == 0.01

      assert {:ok, %{usage: cumulative_usage}} =
               OpenCodeServer.send_turn(session, "Second successful turn", issue(), on_event: on_event)

      assert cumulative_usage["total_tokens"] == 36
      assert cumulative_usage["cost"] == 0.02
    after
      OpenCodeServer.stop(session)
    end
  end

  test "maps OpenCode assistant errors to normalized turn failures", %{context: context} do
    assert {:ok, session} = start_adapter(context, :failure)
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    try do
      assert {:error, {:turn_failed, %{"name" => "UnknownError"} = error}} =
               OpenCodeServer.send_turn(session, "Fail", issue(), on_event: on_event)

      assert error["data"]["message"] == "provider exploded"

      events = received_events()
      assert Enum.map(events, & &1.event) == [:session_started, :turn_started, :turn_failed]
      assert %Event{native: %{"info" => %{"error" => ^error}}} = List.last(events)
    after
      OpenCodeServer.stop(session)
    end
  end

  test "maps pending questions to blocked evidence and aborts the turn", %{context: context} do
    assert {:ok, session} = start_adapter(context, :operator_input)
    process_group_id = ProcessSupervisor.identity(session.process).process_group_id
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    try do
      assert {:error, {:turn_input_required, %{"id" => "question-contract"} = request}} =
               OpenCodeServer.send_turn(session, "Ask me", issue(),
                 on_event: on_event,
                 turn_timeout_ms: 1_000
               )

      assert request["sessionID"] == session.session_id

      events = received_events()

      assert Enum.map(events, & &1.event) == [
               :session_started,
               :turn_started,
               :blocked
             ]

      assert %Event{event: :blocked, reason: :operator_input_requested} = List.last(events)
      assert eventually(fn -> Enum.member?(request_paths(context), "POST /session/session-contract/abort") end)
      assert os_pid_alive?(process_group_id)
      assert :ok = OpenCodeServer.stop(session)
      assert eventually(fn -> if os_pid_alive?(process_group_id), do: nil, else: :stopped end) == :stopped
    after
      OpenCodeServer.stop(session)
    end
  end

  test "maps pending permissions to approval blocking evidence", %{context: context} do
    assert {:ok, session} = start_adapter(context, :permission_input)
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    try do
      assert {:error, {:approval_required, %{"id" => "permission-contract"}}} =
               OpenCodeServer.send_turn(session, "Use a protected tool", issue(),
                 on_event: on_event,
                 turn_timeout_ms: 1_000
               )

      events = received_events()
      assert Enum.map(events, & &1.event) == [:session_started, :turn_started, :blocked]
      assert %Event{event: :blocked, reason: :approval_required} = List.last(events)
    after
      OpenCodeServer.stop(session)
    end
  end

  test "aborts timed out turns and emits normalized timeout failure", %{context: context} do
    assert {:ok, session} = start_adapter(context, :timeout)
    process_group_id = ProcessSupervisor.identity(session.process).process_group_id
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    try do
      assert {:error, :turn_timeout} =
               OpenCodeServer.send_turn(session, "Wait forever", issue(),
                 on_event: on_event,
                 turn_timeout_ms: 80
               )

      events = received_events()
      assert Enum.map(events, & &1.event) == [:session_started, :turn_started, :turn_failed]
      assert %Event{payload: %{reason: :turn_timeout}} = List.last(events)
      assert eventually(fn -> Enum.member?(request_paths(context), "POST /session/session-contract/abort") end)
      assert os_pid_alive?(process_group_id)
      assert :ok = OpenCodeServer.stop(session)
      assert eventually(fn -> if os_pid_alive?(process_group_id), do: nil, else: :stopped end) == :stopped
    after
      OpenCodeServer.stop(session)
    end
  end

  test "rejects incomplete assistant message responses", %{context: context} do
    assert {:ok, session} = start_adapter(context, :incomplete_response)

    try do
      assert {:error, {:invalid_turn_response, %{"info" => info}}} =
               OpenCodeServer.send_turn(session, "Incomplete", issue(), [])

      refute Map.has_key?(info, "id")
    after
      OpenCodeServer.stop(session)
    end
  end

  test "drains supervised server output while a turn is active", %{context: context} do
    assert {:ok, session} = start_adapter(context, :turn_stdout)
    port = ProcessSupervisor.port(session.process)

    try do
      assert {:ok, _result} = OpenCodeServer.send_turn(session, "Noisy", issue(), [])
      refute_receive {^port, {:data, _output}}
    after
      OpenCodeServer.stop(session)
    end
  end

  test "services turn completion while server output is continuous", %{context: context} do
    assert {:ok, session} = start_adapter(context, :output_flood)

    try do
      assert {:ok, _result} =
               OpenCodeServer.send_turn(session, "Flood", issue(), turn_timeout_ms: 1_000)
    after
      OpenCodeServer.stop(session)
    end
  end

  test "normalizes a server exit during an active turn", %{context: context} do
    assert {:ok, session} = start_adapter(context, :server_exit)
    test_pid = self()
    on_event = fn event -> send(test_pid, {:runtime_event, event}) end

    assert {:error, _reason} =
             OpenCodeServer.send_turn(session, "Exit", issue(),
               on_event: on_event,
               turn_timeout_ms: 1_000
             )

    assert %Event{event: :turn_failed} = List.last(received_events())
    assert :ok = OpenCodeServer.stop(session)
  end

  test "startup timeout tears down the launched process group before returning", %{
    context: context
  } do
    assert {:error, {:startup_failed, {:timeout, 500}}} =
             start_adapter(context, :startup_timeout, startup_timeout_ms: 500)

    child_pid = eventually(fn -> read_child_pid(context.child_pid_file) end)
    grandchild_pid = eventually(fn -> read_child_pid(context.grandchild_pid_file) end)
    assert is_integer(child_pid)
    assert is_integer(grandchild_pid)
    assert eventually(fn -> if os_pid_alive?(child_pid), do: nil, else: :stopped end) == :stopped
    assert eventually(fn -> if os_pid_alive?(grandchild_pid), do: nil, else: :stopped end) == :stopped
    assert config_overlays(context) == []

    runner = runner_config(context, :success)

    assert {:error, {:unsupported_remote_runner, "opencode_server", "worker.example"}} =
             start_opencode_context(context.workspace, issue(),
               runner_config: runner,
               worker_host: "worker.example"
             )
  end

  test "removes the config overlay when local process launch fails", %{context: context} do
    missing_executable = Path.join(context.workspace, "missing-opencode")
    runner = context |> runner_config(:success) |> Map.put("command", [missing_executable])

    assert {:error, {:executable_not_found, ^missing_executable}} =
             start_opencode_context(context.workspace, issue(), runner_config: runner)

    assert config_overlays(context) == []
  end

  test "allocates a concrete local port for automatic mode", %{context: context} do
    assert {:ok, session} = start_adapter(context, :require_dynamic_port)
    assert URI.parse(session.client.base_url).port > 0
    assert :ok = OpenCodeServer.stop(session)
  end

  test "does not attach a configured port to an unrelated healthy server", %{context: context} do
    assert {:ok, owner_session} = start_adapter(context, :success)
    port = URI.parse(owner_session.client.base_url).port
    contender_runner = context |> runner_config(:success) |> Map.put("port", port)

    try do
      assert {:error, {:startup_failed, {:server_exit, _status}}} =
               start_opencode_context(context.workspace, issue(),
                 runner_config: contender_runner,
                 startup_timeout_ms: 1_000
               )
    after
      OpenCodeServer.stop(owner_session)
    end
  end

  test "clears inherited OpenCode server credentials when auth is not configured", %{context: context} do
    password = System.get_env("OPENCODE_SERVER_PASSWORD")
    username = System.get_env("OPENCODE_SERVER_USERNAME")
    System.put_env("OPENCODE_SERVER_PASSWORD", "inherited-secret")
    System.put_env("OPENCODE_SERVER_USERNAME", "inherited-user")

    on_exit(fn ->
      restore_env("OPENCODE_SERVER_PASSWORD", password)
      restore_env("OPENCODE_SERVER_USERNAME", username)
    end)

    assert {:ok, session} = start_adapter(context, :reject_inherited_auth)
    assert :ok = OpenCodeServer.stop(session)
  end

  test "forwards only declared provider environment variables", %{context: context} do
    unlisted_key = "SYMPHONY_OPENCODE_UNLISTED_SECRET"
    provider_key = context.provider_key
    previous_unlisted = System.get_env(unlisted_key)
    previous_provider = System.get_env(provider_key)

    System.put_env(unlisted_key, "host-secret")
    System.put_env(provider_key, "provider-key")

    on_exit(fn ->
      restore_env(unlisted_key, previous_unlisted)
      restore_env(provider_key, previous_provider)
    end)

    assert {:ok, session} = start_adapter(context, :environment_allowlist)
    assert :ok = OpenCodeServer.stop(session)
  end

  test "separates implementation and landing delivery authentication", %{context: context} do
    previous_token = System.get_env("GH_TOKEN")
    previous_socket = System.get_env("SSH_AUTH_SOCK")

    on_exit(fn ->
      restore_env("GH_TOKEN", previous_token)
      restore_env("SSH_AUTH_SOCK", previous_socket)
    end)

    System.put_env("GH_TOKEN", "landing-token")
    System.put_env("SSH_AUTH_SOCK", "/tmp/landing-agent.sock")

    assert {:ok, implementation} = start_adapter(context, :delivery_auth_denied)
    assert :ok = OpenCodeServer.stop(implementation)

    landing_issue = Map.put(issue(), :state, "Merging")
    landing_runner = runner_config(context, :delivery_auth_allowed)

    assert {:ok, landing} =
             start_opencode_context(context.workspace, landing_issue, runner_config: landing_runner)

    assert :ok = OpenCodeServer.stop(landing)
  end

  test "fails closed when config overlay parents are symlinks", %{context: context} do
    workspace_root = Path.dirname(context.workspace)

    for {component, index} <- Enum.with_index([".symphony", "opencode"]) do
      workspace = Path.join(workspace_root, "symlink-workspace-#{index}")
      outside = Path.join(workspace_root, "symlink-outside-#{index}")

      File.mkdir_p!(workspace)
      {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      link =
        case component do
          ".symphony" ->
            Path.join(canonical_workspace, ".symphony")

          "opencode" ->
            parent = Path.join(canonical_workspace, ".symphony")
            File.mkdir_p!(parent)
            Path.join(parent, "opencode")
        end

      File.mkdir_p!(outside)
      File.ln_s!(outside, link)

      assert {:error, {:opencode_config_overlay_failed, {:unsafe_config_overlay_parent, ^link}}} =
               start_opencode_context(workspace, issue(), runner_config: runner_config(context, :success))

      assert File.ls!(outside) == []
    end
  end

  test "defaults a null auth username consistently", %{context: context} do
    runner =
      context
      |> runner_config(:auth_default_username)
      |> Map.put("server_auth", %{"password" => "secret", "username" => nil})

    assert {:ok, session} =
             start_opencode_context(context.workspace, issue(),
               runner_config: runner,
               startup_timeout_ms: 1_000
             )

    assert :ok = OpenCodeServer.stop(session)
  end

  test "stops the complete process group with the supervised local server", %{context: context} do
    if ProcessSupervisor.descendant_cleanup_supported?() do
      assert {:ok, session} = start_adapter(context, :descendant)
      child_pid = eventually(fn -> read_child_pid(context.child_pid_file) end)
      grandchild_pid = eventually(fn -> read_child_pid(context.grandchild_pid_file) end)
      assert os_pid_alive?(child_pid)
      assert os_pid_alive?(grandchild_pid)

      assert :ok = OpenCodeServer.stop(session)
      assert eventually(fn -> if os_pid_alive?(child_pid), do: nil, else: :stopped end) == :stopped
      assert eventually(fn -> if os_pid_alive?(grandchild_pid), do: nil, else: :stopped end) == :stopped
    else
      assert ProcessSupervisor.descendant_cleanup_supported?() == false
    end
  end

  defp context_target(context, runner) do
    {:ok, root} = PathSafety.canonicalize(context.workspace)

    %TargetContext{
      target_id: Path.basename(root),
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: context_hash(),
      policy_hash: context_hash(),
      repo_manifest_hash: context_hash(),
      repo_policy: %{
        "manifest" => %{},
        "manifest_source_dir" => context.workspace |> Path.dirname() |> Path.expand(),
        "workflow_module_resolution" => %{}
      },
      tracker_connection: %{},
      run_target: %{},
      worktree_policy: %{
        "root" => root,
        "strategy" => "per_issue",
        "hooks" => %{
          "after_create" => nil,
          "after_run" => nil,
          "before_remove" => nil,
          "before_run" => nil,
          "timeout_ms" => 1_000
        }
      },
      runner_policy: %{
        "default" => "open",
        "allowed" => ["open"],
        "runners" => %{"open" => runner}
      },
      effective_checks: %{},
      external_side_effect_gates: %{},
      capacity_limits: %{},
      budget_limits: %{}
    }
  end

  defp context_hash, do: "sha256:" <> String.duplicate("a", 64)

  defp start_adapter(context, scenario, opts \\ []) do
    start_opencode_context(
      context.workspace,
      issue(),
      Keyword.merge(
        [runner_config: runner_config(context, scenario), startup_timeout_ms: 1_000],
        opts
      )
    )
  end

  defp runner_config(context, scenario) do
    %{
      "kind" => "opencode_server",
      "command" => [
        context.python,
        context.script,
        Atom.to_string(scenario),
        context.trace,
        context.child_pid_file,
        context.grandchild_pid_file,
        context.contract_trace,
        context.provider_key
      ],
      "hostname" => "127.0.0.1",
      "port" => "auto",
      "permissions" => %{},
      "read_timeout_ms" => 500,
      "startup_timeout_ms" => 1_000,
      "turn_timeout_ms" => 1_000,
      "stall_timeout_ms" => 500,
      "execution_profiles" => %{}
    }
  end

  defp start_opencode_context(workspace, issue, opts) do
    runner =
      opts
      |> Keyword.fetch!(:runner_config)
      |> maybe_override_runner_timeout("startup_timeout_ms", opts[:startup_timeout_ms])
      |> maybe_override_runner_timeout("turn_timeout_ms", opts[:turn_timeout_ms])

    target =
      %{workspace: Path.dirname(workspace)}
      |> context_target(runner)
      |> Map.put(:workspace_layout, :flat)

    context_issue = %Issue{
      id: Map.get(issue, :id, "issue-opencode-contract"),
      identifier: Path.basename(workspace),
      title: Map.get(issue, :title, "OpenCode contract"),
      state: Map.get(issue, :state)
    }

    with {:ok, execution_context} <-
           ExecutionContext.new(
             target,
             context_issue,
             policy: %{"test" => "opencode-context"},
             worker_host: opts[:worker_host]
           ) do
      OpenCodeServer.start(execution_context, issue, [])
    end
  end

  defp maybe_override_runner_timeout(runner, _key, nil), do: runner
  defp maybe_override_runner_timeout(runner, key, value), do: Map.put(runner, key, value)

  defp issue do
    %{id: "issue-opencode-contract", identifier: "SID-383", title: "OpenCode contract"}
  end

  defp received_events, do: receive_events([])

  defp receive_events(events) do
    receive do
      {:runtime_event, %Event{} = event} -> receive_events(events ++ [event])
    after
      0 -> events
    end
  end

  defp request_paths(context) do
    case File.read(context.trace) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp config_overlays(context) do
    Path.wildcard(Path.join([context.workspace, ".symphony", "opencode", "config-*"]))
  end

  defp contract_records(context) do
    context.contract_trace
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp turn_task_result_ack(session) do
    fn _task_ref ->
      assert {:ok, %Req.Response{status: 200}} =
               Req.post(session.client.base_url <> "/test/turn-task-result-sent",
                 retry: false,
                 receive_timeout: session.client.read_timeout_ms,
                 connect_options: [timeout: session.client.read_timeout_ms]
               )
    end
  end

  defp read_child_pid(nil), do: nil

  defp read_child_pid(path) do
    with {:ok, contents} <- File.read(path),
         {pid, ""} <- Integer.parse(String.trim(contents)) do
      pid
    else
      _invalid -> nil
    end
  end

  defp kill_pid(nil), do: :ok

  defp kill_pid(pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp fake_server_script do
    ~S"""
    #!/usr/bin/env python3
    import json
    import queue
    import os
    import subprocess
    import sys
    import threading
    import time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import urlparse

    scenario, trace_path, child_pid_path, grandchild_pid_path, contract_trace_path, provider_key = sys.argv[1:7]

    def contract(record):
        with open(contract_trace_path, "a", encoding="utf-8") as file:
            file.write(json.dumps(record) + "\n")
            file.flush()

    contract({"argv": sys.argv[1:]})

    def option(name, default):
        try:
            return sys.argv[sys.argv.index(name) + 1]
        except (ValueError, IndexError):
            return default

    hostname = option("--hostname", "127.0.0.1")
    port = int(option("--port", "0"))

    if scenario == "require_dynamic_port" and port == 0:
        raise SystemExit(12)

    if scenario == "reject_inherited_auth" and (
        os.environ.get("OPENCODE_SERVER_PASSWORD") or
        os.environ.get("OPENCODE_SERVER_USERNAME")
    ):
        raise SystemExit(11)
    if scenario == "environment_allowlist" and os.environ.get("SYMPHONY_OPENCODE_UNLISTED_SECRET"):
        raise SystemExit(13)
    if scenario == "environment_allowlist" and os.environ.get(provider_key) != "provider-key":
        raise SystemExit(14)
    if scenario == "delivery_auth_denied" and (
        os.environ.get("GH_TOKEN") or
        os.environ.get("SSH_AUTH_SOCK") or
        os.environ.get("GIT_TERMINAL_PROMPT") != "0" or
        os.environ.get("GIT_CONFIG_KEY_0") != "credential.helper" or
        os.environ.get("GIT_SSH_COMMAND") != "false"
    ):
        raise SystemExit(15)
    if scenario == "delivery_auth_allowed" and (
        os.environ.get("GH_TOKEN") != "landing-token" or
        os.environ.get("SSH_AUTH_SOCK") != "/tmp/landing-agent.sock" or
        os.environ.get("GIT_TERMINAL_PROMPT") or
        os.environ.get("GIT_CONFIG_KEY_0") or
        os.environ.get("GIT_SSH_COMMAND")
    ):
        raise SystemExit(16)


    if scenario in ("startup_timeout", "descendant"):
        child = subprocess.Popen([
            "/bin/sh",
            "-c",
            'sleep 30 & printf "%s\\n" "$!" > "$1"; wait',
            "child",
            grandchild_pid_path,
        ])
        with open(child_pid_path, "w", encoding="utf-8") as file:
            file.write(str(child.pid))

    if scenario == "startup_timeout":
        time.sleep(30)

    state = {
        "aborted": False,
        "pending_question": False,
        "pending_permission": False,
        "message_count": 0,
    }
    event_queues = []
    event_queues_lock = threading.Lock()
    queue_request_held = threading.Event()
    permission_request_held = threading.Event()
    turn_task_result_sent = threading.Event()
    abort_request_started = threading.Event()
    progress_flood_poll_observed = threading.Event()

    def trace(method, path):
        with open(trace_path, "a", encoding="utf-8") as file:
            file.write(f"{method} {path}\n")
            file.flush()

    def publish_event(event_type, properties, directory=None):
        envelope = {
            "directory": directory or os.getcwd(),
            "payload": {
                "id": f"event-{time.time_ns()}",
                "type": event_type,
                "properties": properties,
            },
        }
        with event_queues_lock:
            subscribers = list(event_queues)
        for subscriber in subscribers:
            subscriber.put(envelope)

    class QuietThreadingHTTPServer(ThreadingHTTPServer):
        def handle_error(self, _request, _client_address):
            pass

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, _format, *_args):
            pass

        def body(self):
            length = int(self.headers.get("content-length", "0"))
            if length == 0:
                return {}
            return json.loads(self.rfile.read(length).decode("utf-8"))

        def reply(self, status, payload):
            encoded = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(encoded)))
            self.end_headers()
            try:
                self.wfile.write(encoded)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

        def stream_events(self):
            events = queue.Queue()
            with event_queues_lock:
                event_queues.append(events)

            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("cache-control", "no-cache")
            self.send_header("transfer-encoding", "chunked")
            self.send_header("connection", "keep-alive")
            self.end_headers()

            connected = {
                "payload": {
                    "id": "event-connected",
                    "type": "server.connected",
                    "properties": {},
                },
            }

            try:
                connected_payload = f"data: {json.dumps(connected)}\n\n".encode("utf-8")
                self.wfile.write(f"{len(connected_payload):x}\r\n".encode("ascii"))
                self.wfile.write(connected_payload + b"\r\n")
                self.wfile.flush()

                while True:
                    try:
                        event = events.get(timeout=0.05)
                        payload = f"data: {json.dumps(event)}\n\n".encode("utf-8")
                    except queue.Empty:
                        payload = b": heartbeat\n\n"

                    self.wfile.write(f"{len(payload):x}\r\n".encode("ascii"))
                    self.wfile.write(payload + b"\r\n")
                    self.wfile.flush()
            except Exception:
                pass
            finally:
                with event_queues_lock:
                    if events in event_queues:
                        event_queues.remove(events)

        def do_GET(self):
            path = urlparse(self.path).path
            trace("GET", path)

            if path == "/global/health":
                if (
                    scenario == "auth_default_username" and
                    self.headers.get("authorization") != "Basic b3BlbmNvZGU6c2VjcmV0"
                ):
                    self.reply(401, {"error": "bad auth"})
                else:
                    self.reply(200, {"healthy": True, "version": "fake"})
            elif path == "/global/event" and scenario == "progress_stream_http_error":
                self.reply(500, {"error": "event stream unavailable"})
            elif path == "/global/event":
                self.stream_events()
            elif path == "/question" and scenario == "completion_poll_race":
                queue_request_held.set()
                turn_task_result_sent.wait()
                self.reply(500, {"error": "queue unavailable"})
                return
            elif path == "/question" and scenario == "progress_flood":
                progress_flood_poll_observed.set()
                self.reply(200, [])
                return
            elif path == "/question" and scenario in ("poll_http_500", "abort_result_race"):
                self.reply(500, {"error": "queue unavailable"})
                return
            elif path == "/question" and scenario == "poll_malformed":
                self.reply(200, {"not": "a queue"})
                return
            elif path == "/question":
                if scenario == "slow_block_poll":
                    time.sleep(1)
                requests = []
                if state["pending_question"] and not state["aborted"]:
                    requests.append({
                        "id": "question-contract",
                        "sessionID": "session-contract",
                        "questions": [{"header": "Choice", "question": "Continue?"}],
                    })
                self.reply(200, requests)
            elif path == "/permission":
                if scenario == "completion_permission_deadline_race":
                    permission_request_held.set()
                    turn_task_result_sent.wait()
                    time.sleep(1)
                    self.reply(200, [])
                    return
                requests = []
                if state["pending_permission"] and not state["aborted"]:
                    requests.append({
                        "id": "permission-contract",
                        "sessionID": "session-contract",
                        "permission": "bash",
                    })
                self.reply(200, requests)
            else:
                self.reply(404, {"error": "not found"})

        def do_POST(self):
            path = urlparse(self.path).path
            trace("POST", path)
            payload = self.body()
            if path == "/session/session-contract/message":
                contract({"method": "POST", "path": path, "body": payload})

            if path == "/test/turn-task-result-sent":
                turn_task_result_sent.set()
                self.reply(200, True)
                return

            if path == "/session":
                self.reply(200, {
                    "id": "session-contract",
                    "title": payload.get("title", "Symphony"),
                })
                return

            if path == "/session/session-contract/abort":
                state["aborted"] = True
                if scenario == "abort_result_race":
                    abort_request_started.set()
                    turn_task_result_sent.wait()
                self.reply(200, True)
                return

            if path == "/instance/dispose":
                self.reply(200, True)
                return

            if path != "/session/session-contract/message":
                self.reply(404, {"error": "not found"})
                return
            state["message_count"] += 1

            if scenario in ("progress_slow", "progress_flood"):
                publish_event("message.updated", {
                    "info": {
                        "id": "message-success",
                        "sessionID": "session-contract",
                        "role": "assistant",
                    },
                })

                progress_count = 200 if scenario == "progress_flood" else 1
                for index in range(progress_count):
                    publish_event("message.part.updated", {
                        "part": {
                            "id": f"part-progress-{index}",
                            "sessionID": "session-contract",
                            "messageID": "message-success",
                            "type": "text",
                            "text": "secret-progress-text",
                        },
                        "delta": "secret-progress-text",
                    })

                if scenario == "progress_flood":
                    progress_flood_poll_observed.wait()

                if scenario == "progress_slow":
                    time.sleep(0.08)
                    publish_event("message.part.updated", {
                        "part": {
                            "id": "part-progress-tool",
                            "sessionID": "session-contract",
                            "messageID": "message-success",
                            "type": "tool",
                            "callID": "call-progress",
                            "tool": "read",
                            "state": {
                                "status": "running",
                                "input": {"path": "README.md"},
                                "time": {"start": 1},
                            },
                        },
                    })
                    time.sleep(0.08)

            if scenario == "unrelated_progress":
                publish_event("message.updated", {
                    "info": {
                        "id": "message-other-session",
                        "sessionID": "session-other",
                        "role": "assistant",
                    },
                })
                publish_event("message.updated", {
                    "info": {
                        "id": "message-other-workspace",
                        "sessionID": "session-contract",
                        "role": "assistant",
                    },
                }, directory="/tmp/other-workspace")
                publish_event("message.part.updated", {
                    "part": {
                        "id": "part-other-session",
                        "sessionID": "session-other",
                        "messageID": "message-other-session",
                        "type": "text",
                        "text": "unrelated",
                    },
                    "delta": "unrelated",
                })

            if scenario == "server_exit":
                os._exit(7)

            if scenario == "timeout":
                time.sleep(30)
            if scenario in ("poll_http_500", "poll_malformed"):
                time.sleep(30)
            if scenario == "abort_result_race":
                abort_request_started.wait()

            if scenario == "operator_input":
                state["pending_question"] = True
                while not state["aborted"]:
                    time.sleep(0.01)

            if scenario == "permission_input":
                state["pending_permission"] = True
                while not state["aborted"]:
                    time.sleep(0.01)

            if scenario == "slow_block_poll":
                time.sleep(30)

            if scenario == "turn_stdout":
                print("x" * 5000, flush=True)

            if scenario == "output_flood":
                for _index in range(100):
                    print("prefill", flush=True)

                def flood_output():
                    while not state["aborted"]:
                        print("flood", flush=True)

                threading.Thread(target=flood_output, daemon=True).start()

            if scenario == "completion_poll_race":
                queue_request_held.wait()
            if scenario == "completion_permission_deadline_race":
                permission_request_held.wait()

            info = {
                "id": "message-success",
                "sessionID": "session-contract",
                "role": "assistant",
                "finish": "stop",
                "cost": 0.01,
                "tokens": {
                    "input": 11,
                    "output": 7,
                    "reasoning": 2,
                    "cache": {"read": 3, "write": 0},
                },
            }

            if scenario == "incomplete_response":
                info.pop("id")
            if scenario == "failure" or (
                scenario == "failure_then_success" and state["message_count"] == 1
            ):
                info["error"] = {
                    "name": "UnknownError",
                    "data": {"message": "provider exploded"},
                }
                self.reply(200, {"info": info, "parts": []})
                return

            if scenario == "tool":
                parts = [{
                    "id": "part-tool",
                    "sessionID": "session-contract",
                    "messageID": "message-success",
                    "type": "tool",
                    "callID": "call-contract",
                    "tool": "read",
                    "state": {
                        "status": "completed",
                        "input": {"path": "README.md"},
                        "output": "contents",
                        "title": "Read README.md",
                        "metadata": {},
                        "time": {"start": 1, "end": 2},
                    },
                }]
            else:
                parts = [{
                    "id": "part-text",
                    "sessionID": "session-contract",
                    "messageID": "message-success",
                    "type": "text",
                    "text": "done",
                }]

            response = {"info": info, "parts": parts}
            self.reply(200, response)

        def do_DELETE(self):
            path = urlparse(self.path).path
            trace("DELETE", path)
            if path == "/session/session-contract":
                self.reply(200, True)
            else:
                self.reply(404, {"error": "not found"})

    server = QuietThreadingHTTPServer((hostname, port), Handler)
    actual_port = server.server_address[1]
    print(f"opencode server listening on http://{hostname}:{actual_port}", flush=True)
    server.serve_forever()
    """
  end
end
