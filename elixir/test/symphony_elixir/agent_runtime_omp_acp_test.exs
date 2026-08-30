defmodule SymphonyElixir.AgentRuntimeOmpAcpTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.AgentRuntime.Event
  alias SymphonyElixir.AgentRuntime.OmpAcp
  alias SymphonyElixir.AgentRuntime.OmpMcpBridge
  alias SymphonyElixir.CapabilityPreflight
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TargetContext

  @live_omp_skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_OMP_ACP") != "1",
                          do: "set SYMPHONY_RUN_LIVE_OMP_ACP=1 to enable the installed OMP ACP smoke turn"
                        )

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-omp-acp-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "SID-452")
    binary = Path.join(root, "fake-omp")
    trace = Path.join(root, "fake-omp.trace")
    child_pid_file = Path.join(root, "child.pid")

    File.mkdir_p!(workspace)
    write_fake_omp!(binary)

    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      workspace_root: workspace_root,
      workspace: workspace,
      binary: binary,
      trace: trace,
      child_pid_file: child_pid_file
    }
  end

  test "registered adapter runs ACP turns and normalizes updates", context do
    execution_context = execution_context(context, "success")
    issue = issue()
    test_pid = self()
    on_event = fn event -> send(test_pid, {:event, event}) end

    assert AgentRuntime.capabilities(execution_context) == %{
             adapter: "omp_acp",
             client_tools: ["linear_graphql"],
             global_extensions: false,
             global_skills: false,
             local_only: true,
             model: "openai/gpt-5.6-sol",
             permission_policy: true,
             pinned: true,
             protocol: "acp-v1",
             session_resume: false
           }

    assert %{status: :passed, failures: []} = CapabilityPreflight.run(execution_context)

    assert {:ok, session} = AgentRuntime.start_session(execution_context, issue)

    try do
      assert session.adapter == OmpAcp
      adapter_session = session.adapter_session
      refute inside_path?(adapter_session.session_dir, context.workspace)
      refute File.exists?(Path.join(context.workspace, ".symphony"))

      assert {:ok,
              %{
                session_id: "omp-session",
                stop_reason: "end_turn",
                usage: %{"cost" => 0.01, "size" => 100, "used" => 10}
              }} =
               AgentRuntime.send_turn(
                 session,
                 "Implement the ticket",
                 issue,
                 on_event: on_event,
                 tool_executor: fn _tool, _arguments -> %{"success" => true, "output" => "ok"} end
               )

      events = receive_events()

      assert Enum.map(events, & &1.event) == [
               :session_started,
               :turn_started,
               :message_delta,
               :turn_progress,
               :tool_call,
               :tool_result,
               :turn_progress,
               :turn_progress,
               :turn_completed
             ]

      assert Enum.all?(events, &(Event.validate(&1) == :ok))
      assert Enum.all?(events, &(&1.runtime == :omp_acp))
      assert %Event{payload: %{channel: :assistant, text: "done"}} = Enum.at(events, 2)
      assert %Event{payload: %{channel: :reasoning, text: "thinking"}} = Enum.at(events, 3)
      assert %Event{event: :tool_result, payload: %{status: "completed"}} = Enum.at(events, 5)
      assert %Event{payload: %{kind: :plan}} = Enum.at(events, 6)
      assert %Event{usage: %{"used" => 10}} = Enum.at(events, 7)

      assert {:ok, %{stop_reason: "end_turn"}} =
               AgentRuntime.send_turn(session, "Continue", issue, on_event: on_event)

      continuation_events = receive_events()
      refute Enum.any?(continuation_events, &(&1.event == :session_started))
      assert hd(continuation_events).event == :turn_started
    after
      assert :ok = AgentRuntime.stop_session(session)
    end

    trace = File.read!(context.trace)
    assert trace =~ "ENV_OMP_PROFILE:symphony-test"
    assert trace =~ "ENV_LINEAR_API_KEY:"
    assert trace =~ "PI_CODING_AGENT_SESSION_DIR:#{session.adapter_session.session_dir}"
    assert trace =~ "ARG:--no-extensions"
    assert trace =~ "ARG:--no-skills"
    assert trace =~ "PWD:#{session.adapter_session.workspace}"

    assert trace_request?(trace, "session/set_config_option", fn request ->
             request["params"] == %{
               "sessionId" => "omp-session",
               "configId" => "model",
               "value" => "openai/gpt-5.6-sol"
             }
           end)

    assert trace_request?(trace, "session/set_config_option", fn request ->
             request["params"]["configId"] == "thinking" and request["params"]["value"] == "high"
           end)
  end

  test "pinned permission policy denies an ACP request with stable evidence", context do
    execution_context = execution_context(context, "permission", %{"edit" => "deny"})
    issue = issue()
    test_pid = self()

    assert {:ok, session} = OmpAcp.start(execution_context, issue, [])

    try do
      assert {:error, {:permission_denied, "edit"}} =
               OmpAcp.send_turn(session, "Request permission", issue, on_event: fn event -> send(test_pid, {:event, event}) end)

      events = receive_events()
      assert Enum.map(events, & &1.event) == [:session_started, :turn_started, :blocked, :turn_failed]

      assert %Event{
               reason: :permission_denied,
               payload: %{
                 call_id: "permission-call",
                 decision: :deny,
                 policy_key: "edit",
                 tool_kind: "edit"
               }
             } = Enum.at(events, 2)
    after
      assert :ok = OmpAcp.stop(session)
    end

    assert eventually(fn ->
             case File.read(context.trace) do
               {:ok, trace} ->
                 trace_request?(trace, nil, fn request ->
                   request["id"] == 999 and
                     request["result"] == %{
                       "outcome" => %{"outcome" => "selected", "optionId" => "reject"}
                     }
                 end)

               _missing ->
                 false
             end
           end)
  end

  test "pinned permission policy allows only the requested operation once", context do
    execution_context = execution_context(context, "permission", %{"edit" => "allow", "*" => "deny"})
    test_pid = self()

    assert {:ok, session} = OmpAcp.start(execution_context, issue(), [])

    try do
      assert {:ok, %{stop_reason: "end_turn"}} =
               OmpAcp.send_turn(session, "Request permission", issue(), on_event: fn event -> send(test_pid, {:event, event}) end)

      events = receive_events()

      assert %Event{
               event: :turn_progress,
               payload: %{decision: :allow, option_id: "allow", policy_key: "edit"}
             } = Enum.at(events, 2)

      refute Enum.any?(events, &(&1.event == :blocked))
    after
      assert :ok = OmpAcp.stop(session)
    end

    assert eventually(fn ->
             context.trace
             |> File.read!()
             |> trace_request?(nil, fn request ->
               request["id"] == 999 and
                 request["result"] == %{
                   "outcome" => %{"outcome" => "selected", "optionId" => "allow"}
                 }
             end)
           end)
  end

  test "missing permission policy blocks without approving the operation", context do
    execution_context = execution_context(context, "permission", %{})
    test_pid = self()

    assert {:ok, session} = OmpAcp.start(execution_context, issue(), [])

    try do
      assert {:error, {:permission_policy_missing, "edit"}} =
               OmpAcp.send_turn(session, "Request permission", issue(), on_event: fn event -> send(test_pid, {:event, event}) end)

      assert %Event{reason: :permission_policy_missing, payload: %{decision: :missing}} =
               receive_events() |> Enum.at(2)
    after
      assert :ok = OmpAcp.stop(session)
    end
  end

  test "interactive elicitation becomes an actionable blocked event", context do
    execution_context = execution_context(context, "question")
    test_pid = self()

    assert {:ok, session} = OmpAcp.start(execution_context, issue(), [])

    try do
      assert {:error, {:operator_input_required, "session/request_input"}} =
               OmpAcp.send_turn(session, "Ask a question", issue(), on_event: fn event -> send(test_pid, {:event, event}) end)

      assert %Event{
               event: :blocked,
               reason: :operator_input_required,
               payload: %{action: action, method: "session/request_input"}
             } = receive_events() |> Enum.at(2)

      assert action =~ "outside the unattended run"
    after
      assert :ok = OmpAcp.stop(session)
    end
  end

  test "events and turn results redact the per-session bridge token", context do
    execution_context = execution_context(context, "secret")
    test_pid = self()

    assert {:ok, session} = OmpAcp.start(execution_context, issue(), [])
    bridge_token = session.bridge.token

    try do
      assert {:ok, result} =
               OmpAcp.send_turn(session, "Echo the bridge secret", issue(), on_event: fn event -> send(test_pid, {:event, event}) end)

      persisted =
        Jason.encode!(%{events: Enum.map(receive_events(), &Map.from_struct/1), result: result})

      refute persisted =~ bridge_token
      assert persisted =~ "<redacted:secret>"
    after
      assert :ok = OmpAcp.stop(session)
    end
  end

  test "concurrent runs use separate session directories and ACP identities", context do
    first_context = execution_context(context, "identity")
    second_context = execution_context(context, "identity")

    assert {:ok, first} = OmpAcp.start(first_context, issue(), [])
    assert {:ok, second} = OmpAcp.start(second_context, issue(), [])

    try do
      refute first.session_dir == second.session_dir
      refute first.session_id == second.session_id
      refute first.process.os_pid == second.process.os_pid
    after
      assert :ok = OmpAcp.stop(first)
      assert :ok = OmpAcp.stop(second)
    end
  end

  test "recovery identity fences the prior process before a fresh ACP session", context do
    if SymphonyElixir.ProcessSupervisor.descendant_cleanup_supported?() do
      execution_context = execution_context(context, "identity")
      assert {:ok, prior} = OmpAcp.start(execution_context, issue(), [])
      assert {:ok, identity} = SymphonyElixir.ProcessSupervisor.recovery_identity(prior.process)

      assert {:stopped, evidence} =
               SymphonyElixir.ProcessSupervisor.terminate_recovered_group(identity)

      assert evidence.result == "terminated"
      assert {:ok, fresh} = OmpAcp.start(execution_context, issue(), [])

      try do
        refute fresh.session_id == prior.session_id
        refute fresh.session_dir == prior.session_dir
      after
        assert :ok = OmpAcp.stop(prior)
        assert :ok = OmpAcp.stop(fresh)
      end
    end
  end

  test "malformed ACP output fails the turn and cancels the session", context do
    execution_context = execution_context(context, "malformed")
    issue = issue()
    test_pid = self()

    assert {:ok, session} = OmpAcp.start(execution_context, issue, [])

    try do
      assert {:error, :malformed_acp_message} =
               OmpAcp.send_turn(session, "Break the protocol", issue, on_event: fn event -> send(test_pid, {:event, event}) end)

      assert List.last(receive_events()).event == :turn_failed
    after
      assert :ok = OmpAcp.stop(session)
    end

    assert eventually(fn ->
             context.trace
             |> File.read!()
             |> trace_request?("session/cancel", fn _request -> true end)
           end)
  end

  test "unsupported ACP protocol fails startup and stops the process", context do
    execution_context = execution_context(context, "unsupported")

    assert {:error, {:startup_failed, {:unsupported_acp_protocol, 2}}} =
             OmpAcp.start(execution_context, issue(), [])
  end

  test "startup read timeout stops an unresponsive ACP process", context do
    execution_context = execution_context(context, "startup_timeout")

    assert {:error, {:startup_failed, :timeout}} =
             OmpAcp.start(execution_context, issue(), [])
  end

  test "stop cleans a descendant process owned by OMP", context do
    if SymphonyElixir.ProcessSupervisor.descendant_cleanup_supported?() do
      execution_context = execution_context(context, "descendant")
      assert {:ok, session} = OmpAcp.start(execution_context, issue(), [])
      child_pid = eventually(fn -> read_pid(context.child_pid_file) end)
      assert os_pid_alive?(child_pid)

      assert :ok = OmpAcp.stop(session)
      assert eventually(fn -> not os_pid_alive?(child_pid) end)
    end
  end

  test "loopback MCP bridge requires its bearer token and delegates only linear_graphql" do
    assert {:ok, bridge} = OmpMcpBridge.start()

    try do
      request = rpc_request(1, "initialize", %{"protocolVersion" => "2025-03-26"})
      assert {:ok, %{status: 401}} = Req.post(bridge.url, json: request)

      headers = [{"authorization", "Bearer " <> bridge.token}]

      assert {:ok, %{status: 200, body: %{"result" => %{"serverInfo" => %{"name" => "symphony-linear"}}}}} =
               Req.post(bridge.url, headers: headers, json: request)

      assert :ok =
               OmpMcpBridge.set_tool_executor(bridge, fn tool, arguments ->
                 assert tool == "linear_graphql"
                 assert arguments == %{"query" => "query Bridge { viewer { id } }"}
                 %{"success" => true, "output" => ~s({"ok":true})}
               end)

      call =
        rpc_request(2, "tools/call", %{
          "name" => "linear_graphql",
          "arguments" => %{"query" => "query Bridge { viewer { id } }"}
        })

      assert {:ok,
              %{
                status: 200,
                body: %{
                  "result" => %{
                    "content" => [%{"type" => "text", "text" => ~s({"ok":true})}],
                    "isError" => false
                  }
                }
              }} = Req.post(bridge.url, headers: headers, json: call)

      unsupported = rpc_request(3, "tools/call", %{"name" => "shell", "arguments" => %{}})

      assert {:ok, %{body: %{"result" => %{"isError" => true}}}} =
               Req.post(bridge.url, headers: headers, json: unsupported)
    after
      assert :ok = OmpMcpBridge.stop(bridge)
    end
  end

  @tag skip: @live_omp_skip_reason
  @tag timeout: 180_000
  test "installed OMP ACP completes a guarded turn with repository rules and usage", context do
    profile = System.fetch_env!("SYMPHONY_OMP_PROFILE")
    model = System.fetch_env!("SYMPHONY_OMP_MODEL")
    thinking = System.get_env("SYMPHONY_OMP_THINKING", "high")

    File.write!(
      Path.join(context.workspace, "AGENTS.md"),
      "For this repository, reply with exactly SYMPHONY_OMP_LIVE_OK when the user asks for the live marker.\n"
    )

    runner = %{
      "kind" => "omp_acp",
      "command" => ["omp", "--no-extensions", "--no-skills", "acp"],
      "model" => model,
      "permissions" => %{"*" => "deny"},
      "profile" => profile,
      "thinking" => thinking,
      "turn_timeout_ms" => 120_000,
      "read_timeout_ms" => 30_000,
      "stall_timeout_ms" => 60_000,
      "startup_timeout_ms" => 30_000,
      "execution_profiles" => %{}
    }

    execution_context = execution_context_with_runner(context, runner)
    test_pid = self()

    assert {:ok, session} = AgentRuntime.start_session(execution_context, issue())
    os_pid = session.adapter_session.process.os_pid

    try do
      assert {:ok, %{stop_reason: "end_turn", usage: usage}} =
               AgentRuntime.send_turn(session, "Return the live marker.", issue(), on_event: fn event -> send(test_pid, {:event, event}) end)

      events = receive_events()
      text = events |> Enum.map(& &1.payload[:text]) |> Enum.reject(&is_nil/1) |> Enum.join()

      assert text =~ "SYMPHONY_OMP_LIVE_OK"
      assert is_map(usage) and map_size(usage) > 0
      assert Enum.any?(events, &(&1.event == :turn_completed))
    after
      assert :ok = AgentRuntime.stop_session(session)
    end

    assert eventually(fn -> not os_pid_alive?(os_pid) end)
  end

  test "runner catalog normalizes OMP defaults and rejects unpinned settings" do
    assert {:ok, %{"omp" => runner}} =
             Schema.validate_runner_catalog(%{
               "omp" => %{
                 "kind" => "omp_acp",
                 "model" => "openai/gpt-5.6-sol",
                 "permissions" => %{"read" => "allow"},
                 "profile" => "symphony",
                 "thinking" => "high"
               }
             })

    assert runner["command"] == ["omp", "--no-extensions", "--no-skills", "acp"]
    assert runner["permissions"] == %{"read" => "allow"}
    assert runner["startup_timeout_ms"] == 30_000

    assert {:error, errors} =
             Schema.validate_runner_catalog(%{
               "omp" => %{
                 "kind" => "omp_acp",
                 "model" => "missing-provider",
                 "profile" => "",
                 "thinking" => "extreme"
               }
             })

    assert Enum.any?(errors, &String.contains?(&1, ".model must use provider/model"))
    assert Enum.any?(errors, &String.contains?(&1, ".profile must be a non-empty string"))
    assert Enum.any?(errors, &String.contains?(&1, ".thinking must be one of:"))

    assert {:error, thinking_errors} =
             Schema.validate_runner_catalog(%{
               "omp" => %{
                 "kind" => "omp_acp",
                 "model" => "openai/gpt-5.6-sol",
                 "profile" => "symphony",
                 "thinking" => true
               }
             })

    assert Enum.any?(thinking_errors, &String.contains?(&1, ".thinking must be a string"))

    assert {:error, hardening_errors} =
             Schema.validate_runner_catalog(%{
               "omp" => %{
                 "kind" => "omp_acp",
                 "command" => ["omp", "acp"],
                 "model" => "openai/gpt-5.6-sol",
                 "permissions" => %{"edit" => "ask"},
                 "profile" => "symphony",
                 "thinking" => "high"
               }
             })

    assert Enum.any?(hardening_errors, &String.contains?(&1, ".command must include --no-extensions and --no-skills"))
    assert Enum.any?(hardening_errors, &String.contains?(&1, ".permissions.edit must be one of: allow, block, deny"))

    assert {:error, type_errors} =
             Schema.validate_runner_catalog(%{
               "omp" => %{
                 "kind" => "omp_acp",
                 "command" => "omp acp",
                 "model" => "openai/gpt-5.6-sol",
                 "permissions" => [],
                 "profile" => "symphony",
                 "thinking" => "high"
               }
             })

    assert Enum.any?(type_errors, &String.contains?(&1, ".command must be a list"))
    assert Enum.any?(type_errors, &String.contains?(&1, ".permissions must be a map"))

    assert {:error, blank_key_errors} =
             Schema.validate_runner_catalog(%{
               "omp" => %{
                 "kind" => "omp_acp",
                 "model" => "openai/gpt-5.6-sol",
                 "permissions" => %{" " => "allow"},
                 "profile" => "symphony",
                 "thinking" => "high"
               }
             })

    assert Enum.any?(blank_key_errors, &String.contains?(&1, ".permissions keys must be non-empty strings"))
  end

  defp execution_context(context, scenario, permissions \\ %{"*" => "deny"}) do
    runner = %{
      "kind" => "omp_acp",
      "command" => [
        context.binary,
        "--no-extensions",
        "--no-skills",
        scenario,
        context.trace,
        context.child_pid_file
      ],
      "model" => "openai/gpt-5.6-sol",
      "permissions" => permissions,
      "profile" => "symphony-test",
      "thinking" => "high",
      "turn_timeout_ms" => 1_000,
      "read_timeout_ms" => 1_000,
      "stall_timeout_ms" => 500,
      "startup_timeout_ms" => 1_500,
      "execution_profiles" => %{}
    }

    execution_context_with_runner(context, runner)
  end

  defp execution_context_with_runner(context, runner) do
    target = %TargetContext{
      target_id: "omp-test",
      workspace_layout: :flat,
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: hash(),
      policy_hash: hash(),
      repo_manifest_hash: hash(),
      repo_policy: %{
        "manifest" => %{"harness" => %{"codex_home" => nil}},
        "manifest_source_dir" => context.root,
        "workflow_module_resolution" => %{}
      },
      tracker_connection: %{},
      run_target: %{},
      worktree_policy: %{
        "root" => context.workspace_root,
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
        "default" => "omp",
        "allowed" => ["omp"],
        "runners" => %{"omp" => runner}
      },
      effective_checks: %{},
      external_side_effect_gates: %{},
      capacity_limits: %{},
      budget_limits: %{}
    }

    assert {:ok, execution_context} =
             ExecutionContext.new(target, issue(),
               policy: %{
                 "policy_ref" => "omp-test",
                 "policy_metadata" => %{"profile" => "implementation"}
               }
             )

    execution_context
  end

  defp issue do
    %Issue{
      id: "issue-omp-acp",
      identifier: "SID-452",
      title: "OMP ACP adapter",
      description: "Contract fixture",
      state: "In Progress",
      url: "https://example.org/SID-452",
      labels: []
    }
  end

  defp write_fake_omp!(path) do
    File.write!(path, fake_omp_script())
    File.chmod!(path, 0o755)
  end

  defp fake_omp_script do
    ~S"""
    #!/bin/sh
    printf 'ARG:%s\n' "$1" >> "$4"
    printf 'ARG:%s\n' "$2" >> "$4"
    shift 2
    scenario="$1"
    trace="$2"
    child_pid_file="$3"
    prompt_id=""
    permission_pending=0
    session_id="omp-session"
    bridge_token=""

    if [ "$scenario" = "identity" ]; then
      session_id="omp-session-$$"
    fi

    printf 'PWD:%s\n' "$PWD" >> "$trace"
    printf 'ENV_OMP_PROFILE:%s\n' "${OMP_PROFILE:-}" >> "$trace"
    printf 'ENV_LINEAR_API_KEY:%s\n' "${LINEAR_API_KEY:-}" >> "$trace"
    printf 'PI_CODING_AGENT_SESSION_DIR:%s\n' "${PI_CODING_AGENT_SESSION_DIR:-}" >> "$trace"

    if [ "$scenario" = "descendant" ]; then
      sleep 60 &
      printf '%s\n' "$!" > "$child_pid_file"
    fi

    while IFS= read -r line; do
      printf 'JSON:%s\n' "$line" >> "$trace"
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')

      if [ "$permission_pending" = "1" ]; then
        permission_pending=0
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$prompt_id,\"result\":{\"stopReason\":\"end_turn\"}}"
        continue
      fi

      case "$line" in
        *'"method":"initialize"'*)
          if [ "$scenario" = "startup_timeout" ]; then
            sleep 5
          elif [ "$scenario" = "unsupported" ]; then
            printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":2,\"agentCapabilities\":{\"mcpCapabilities\":{\"http\":true}}}}"
          else
            printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"mcpCapabilities\":{\"http\":true},\"sessionCapabilities\":{\"close\":true}}}}"
          fi
          ;;
        *'"method":"session/new"'*)
          bridge_token=$(printf '%s' "$line" | sed -n 's/.*Bearer \([^"]*\).*/\1/p')
          printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"$session_id\",\"configOptions\":[]}}"
          ;;
        *'"method":"session/set_config_option"'*)
          printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"configOptions\":[]}}"
          ;;
        *'"method":"session/prompt"'*)
          prompt_id="$id"
          case "$scenario" in
            malformed)
              printf '%s\n' 'not-json'
              ;;
            permission)
              permission_pending=1
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":999,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"$session_id\",\"toolCall\":{\"toolCallId\":\"permission-call\",\"title\":\"write\",\"kind\":\"edit\"},\"options\":[{\"optionId\":\"allow\",\"name\":\"Allow\",\"kind\":\"allow_once\"},{\"optionId\":\"reject\",\"name\":\"Reject\",\"kind\":\"reject_once\"}]}}"
              ;;
            question)
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":998,\"method\":\"session/request_input\",\"params\":{\"sessionId\":\"$session_id\",\"question\":\"Choose a deployment\"}}"
              ;;
            secret)
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"$session_id\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Authorization: Bearer $bridge_token\"},\"messageId\":\"message-secret\"}}}"
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"stopReason\":\"end_turn\",\"credential\":\"$bridge_token\"}}"
              ;;
            *)
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"omp-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"},"messageId":"message-1"}}}'
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"omp-session","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking"},"messageId":"message-1"}}}'
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"omp-session","update":{"sessionUpdate":"tool_call","toolCallId":"call-1","title":"Read file","kind":"read","status":"pending"}}}'
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"omp-session","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"ok"}}]}}}'
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"omp-session","update":{"sessionUpdate":"plan","entries":[{"content":"Implement","priority":"high","status":"in_progress"}]}}}'
              printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"omp-session","update":{"sessionUpdate":"usage_update","used":10,"size":100,"cost":0.01}}}'
              printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"stopReason\":\"end_turn\"}}"
              ;;
          esac
          ;;
        *'"method":"session/cancel"'*)
          ;;
        *'"method":"session/close"'*)
          printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{}}"
          ;;
      esac
    done
    """
  end

  defp receive_events(events \\ []) do
    receive do
      {:event, %Event{} = event} -> receive_events([event | events])
    after
      20 -> Enum.reverse(events)
    end
  end

  defp trace_request?(trace, method, predicate) do
    trace
    |> String.split("\n", trim: true)
    |> Enum.any?(fn
      "JSON:" <> json ->
        with {:ok, request} <- Jason.decode(json),
             true <- is_nil(method) or request["method"] == method do
          predicate.(request)
        else
          _other -> false
        end

      _line ->
        false
    end)
  end

  defp rpc_request(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp inside_path?(path, root) do
    case Path.relative_to(path, root) do
      "." -> true
      ".." <> _rest -> false
      relative -> Path.type(relative) != :absolute
    end
  end

  defp hash, do: "sha256:" <> String.duplicate("a", 64)
end
