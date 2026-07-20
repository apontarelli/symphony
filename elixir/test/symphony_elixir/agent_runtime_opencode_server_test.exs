defmodule SymphonyElixir.AgentRuntimeOpenCodeServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.AgentRuntime.{Event, OpenCodeServer}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ProcessSupervisor

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-opencode-server-test-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-opencode.py")
    trace = Path.join(test_root, "requests.trace")
    child_pid_file = Path.join(test_root, "child.pid")
    python = System.find_executable("python3") || flunk("python3 is required for the fake OpenCode server")

    File.mkdir_p!(workspace)
    File.write!(script, fake_server_script())
    File.chmod!(script, 0o755)

    on_exit(fn ->
      child_pid_file
      |> read_child_pid()
      |> kill_pid()

      File.rm_rf(test_root)
    end)

    {:ok,
     context: %{
       child_pid_file: child_pid_file,
       python: python,
       script: script,
       trace: trace,
       workspace: workspace
     }}
  end

  test "runs the selected OpenCode adapter through the AgentRuntime facade", %{context: context} do
    assert {:ok, settings} =
             Schema.parse(%{
               agent: %{default_runner: "open"},
               runners: %{open: runner_config(context, :success)},
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    assert {:ok, session} =
             AgentRuntime.start_session(context.workspace, issue(),
               settings: settings,
               startup_timeout_ms: 1_000
             )

    try do
      assert session.runner_name == "open"
      assert session.runner_kind == "opencode_server"

      assert {:ok, %{session_id: "session-contract-message-success"}} =
               AgentRuntime.send_turn(session, "Facade prompt", issue())
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

      assert %{adapter: :opencode_server, client_side_tools: [], continuation_turns: true} =
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
    after
      OpenCodeServer.stop(session)
    end
  end

  test "bounds blocking-request polling by the turn deadline", %{context: context} do
    assert {:ok, session} = start_adapter(context, :slow_block_poll)
    started_at = System.monotonic_time(:millisecond)

    try do
      assert {:error, :turn_timeout} =
               OpenCodeServer.send_turn(session, "Do not overrun", issue(), turn_timeout_ms: 80)

      assert System.monotonic_time(:millisecond) - started_at < 400
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

  test "times out startup and rejects remote execution before launch", %{context: context} do
    assert {:error, {:startup_failed, {:timeout, 80}}} =
             start_adapter(context, :startup_timeout, startup_timeout_ms: 80)

    runner = runner_config(context, :success)

    assert {:error, {:unsupported_remote_runner, "opencode_server", "worker.example"}} =
             OpenCodeServer.start(context.workspace, issue(),
               runner_config: runner,
               worker_host: "worker.example"
             )
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
               OpenCodeServer.start(context.workspace, issue(),
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

  test "defaults a null auth username consistently", %{context: context} do
    runner =
      context
      |> runner_config(:auth_default_username)
      |> Map.put("server_auth", %{"password" => "secret", "username" => nil})

    assert {:ok, session} =
             OpenCodeServer.start(context.workspace, issue(),
               runner_config: runner,
               startup_timeout_ms: 1_000
             )

    assert :ok = OpenCodeServer.stop(session)
  end

  test "stops descendant processes with the supervised local server", %{context: context} do
    if ProcessSupervisor.descendant_cleanup_supported?() do
      assert {:ok, session} = start_adapter(context, :descendant)
      child_pid = eventually(fn -> read_child_pid(context.child_pid_file) end)
      assert os_pid_alive?(child_pid)

      assert :ok = OpenCodeServer.stop(session)
      assert eventually(fn -> if os_pid_alive?(child_pid), do: nil, else: :stopped end) == :stopped
    else
      assert ProcessSupervisor.descendant_cleanup_supported?() == false
    end
  end

  defp start_adapter(context, scenario, opts \\ []) do
    OpenCodeServer.start(
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
        context.child_pid_file
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
    import os
    import subprocess
    import sys
    import threading
    import time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import urlparse

    scenario, trace_path, child_pid_path = sys.argv[1:4]

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

    if scenario == "startup_timeout":
        time.sleep(30)
        raise SystemExit(0)

    if scenario == "descendant":
        child = subprocess.Popen(["sleep", "30"])
        with open(child_pid_path, "w", encoding="utf-8") as file:
            file.write(str(child.pid))

    state = {"aborted": False, "pending_question": False, "pending_permission": False}

    def trace(method, path):
        with open(trace_path, "a", encoding="utf-8") as file:
            file.write(f"{method} {path}\n")
            file.flush()

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

            if path == "/session":
                self.reply(200, {
                    "id": "session-contract",
                    "title": payload.get("title", "Symphony"),
                })
                return

            if path == "/session/session-contract/abort":
                state["aborted"] = True
                self.reply(200, True)
                return

            if path == "/instance/dispose":
                self.reply(200, True)
                return

            if path != "/session/session-contract/message":
                self.reply(404, {"error": "not found"})
                return

            if scenario == "server_exit":
                os._exit(7)

            if scenario == "timeout":
                time.sleep(30)

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

            if scenario == "failure":
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

            self.reply(200, {"info": info, "parts": parts})

        def do_DELETE(self):
            path = urlparse(self.path).path
            trace("DELETE", path)
            if path == "/session/session-contract":
                self.reply(200, True)
            else:
                self.reply(404, {"error": "not found"})

    server = ThreadingHTTPServer((hostname, port), Handler)
    actual_port = server.server_address[1]
    print(f"opencode server listening on http://{hostname}:{actual_port}", flush=True)
    server.serve_forever()
    """
  end
end
