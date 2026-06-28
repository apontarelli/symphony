defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.HandoffRoute
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    workflow_store = Process.whereis(WorkflowStore)
    assert is_pid(workflow_store)
    send(workflow_store, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "project: [\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "third-symphony.yml")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store keeps last good manifest when manifest reload fails" do
    ensure_workflow_store_running()
    manifest_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "symphony.yml")

    File.write!(
      manifest_path,
      "project:\n  slug: manifest-repo\n  repository: github.com/example/manifest-repo\ndelivery:\n  pr_target: main\n"
    )

    Workflow.set_workflow_file_path(manifest_path)

    assert {:ok, %{config: config}} = Workflow.current()
    assert config["tracker"]["project_slug"] == "manifest-repo"

    File.write!(manifest_path, "project: [\n")

    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{config: last_good_config}} = Workflow.current()
    assert last_good_config["tracker"]["project_slug"] == "manifest-repo"
  end

  test "workflow store keeps last good default manifest when the manifest disappears" do
    original_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    original_default_path = Application.get_env(:symphony_elixir, :default_workflow_file_path)

    on_exit(fn ->
      restore_app_env(:workflow_file_path, original_workflow_path)
      restore_app_env(:default_workflow_file_path, original_default_path)
    end)

    workflow_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-default-manifest-reload-#{System.unique_integer([:positive])}")

    manifest_path = Path.join(workflow_root, "symphony.yml")
    File.mkdir_p!(workflow_root)

    File.write!(
      manifest_path,
      "project:\n  slug: manifest-repo\n  repository: github.com/example/manifest-repo\ndelivery:\n  pr_target: main\n"
    )

    Application.delete_env(:symphony_elixir, :workflow_file_path)
    Application.delete_env(:symphony_elixir, :default_workflow_file_path)

    try do
      File.cd!(workflow_root, fn ->
        expected_manifest_path = Path.join(File.cwd!(), "symphony.yml")

        assert {:ok, state} = WorkflowStore.init([])
        assert state.path == expected_manifest_path
        assert state.workflow.config["tracker"]["project_slug"] == "manifest-repo"

        File.rm!(manifest_path)

        assert {:noreply, reloaded_state} = WorkflowStore.handle_info(:poll, state)
        assert reloaded_state.path == expected_manifest_path
        assert reloaded_state.workflow.config["tracker"]["project_slug"] == "manifest-repo"
      end)
    after
      File.rm_rf(workflow_root)
    end
  end

  test "workflow store init stops on missing manifest file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "missing-symphony.yml")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_manifest_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "manual-symphony.yml")
    missing_path = Path.join(Path.dirname(existing_path), "manual-missing-symphony.yml")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_manifest_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "project: [\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_500

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_500

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_500

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{
               "running" => 1,
               "retrying" => 1,
               "blocked" => 1,
               "work_errors" => 1,
               "config_warnings" => 0,
               "stale_warnings" => 0
             },
             "project_statuses" => [
               %{
                 "id" => "project",
                 "project" => "Project",
                 "project_id" => nil,
                 "project_slug" => "project",
                 "project_url" => "https://linear.app/project/project/issues",
                 "statuses" => ["work_error", "retrying", "active"],
                 "running" => 1,
                 "retrying" => 1,
                 "errors" => 1,
                 "stale_warnings" => 0,
                 "config_warnings" => 0,
                 "profile" => "default",
                 "pr_target" => "main",
                 "last_activity_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "actions" => [
                   %{"label" => "Open Linear", "href" => "https://linear.app/project/project/issues"}
                 ]
               }
             ],
             "work_errors" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "issue_url" => "https://example.org/issues/MT-RETRY",
                 "project_slug" => "project",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom"
               }
             ],
             "config_warnings" => [],
             "stale_warnings" => [],
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "issue_url" => "https://example.org/issues/MT-HTTP",
                 "project_id" => nil,
                 "project_slug" => "project",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "profile" => "default",
                 "target" => "Human Review",
                 "policy_ref" => "policy-http",
                 "policy" => %{
                   "delivery" => %{"pr_target" => "Human Review"},
                   "policy_ref" => "policy-http"
                 },
                 "session_id" => "thread-http",
                 "startup" => false,
                 "adapter" => nil,
                 "pr_target" => "main",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "issue_url" => "https://example.org/issues/MT-RETRY",
                 "project_id" => nil,
                 "project_slug" => "project",
                 "attempt" => 2,
                 "pr_target" => "main",
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "profile" => "strict",
                 "target" => "Merging",
                 "policy_ref" => "policy-retry",
                 "policy" => %{
                   "checks" => ["mix test"],
                   "delivery" => %{"pr_target" => "Merging"},
                   "policy_ref" => "policy-retry"
                 }
               }
             ],
             "blocked" => [
               %{
                 "issue_id" => "issue-blocked",
                 "issue_identifier" => "MT-BLOCKED",
                 "issue_url" => "https://example.org/issues/MT-BLOCKED",
                 "project_id" => nil,
                 "project_slug" => "project",
                 "state" => "In Progress",
                 "error" => "runtime turn requires operator input",
                 "worker_host" => "dm-dev2",
                 "workspace_path" => "/workspaces/MT-BLOCKED",
                 "profile" => "strict",
                 "target" => "Human Review",
                 "policy_ref" => "policy-blocked",
                 "policy" => %{
                   "delivery" => %{"pr_target" => "Human Review"},
                   "policy_ref" => "policy-blocked"
                 },
                 "session_id" => "thread-blocked",
                 "pr_target" => "main",
                 "blocked_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("blocked_at"),
                 "last_event" => "turn_input_required",
                 "last_message" => "turn blocked: waiting for user input",
                 "last_event_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("last_event_at")
               }
             ],
             "handoff_routes" => [
               %{
                 "issue_id" => "issue-http",
                 "route" => "human_review",
                 "target_state" => "Human Review",
                 "summary" => "Human review required for risky or policy-protected work.",
                 "recommendation" => "Review evidence, then approve for Merging or request Rework.",
                 "options" => [],
                 "evidence" => [],
                 "artifacts" => [],
                 "metadata" => %{}
               }
             ],
             "runtime_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "token_hotspot" => %{
               "issue_identifier" => "MT-HTTP",
               "session_id" => "thread-http",
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12
             },
             "rate_limits_available" => true,
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "profile" => "default",
               "target" => "Human Review",
               "policy_ref" => "policy-http",
               "policy" => %{
                 "delivery" => %{"pr_target" => "Human Review"},
                 "policy_ref" => "policy-http"
               },
               "session_id" => "thread-http",
               "startup" => false,
               "adapter" => nil,
               "project_slug" => "project",
               "pr_target" => "main",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "blocked" => nil,
             "logs" => %{"runtime_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{
             "status" => "retrying",
             "retry" => %{
               "attempt" => 2,
               "error" => "boom",
               "profile" => "strict",
               "target" => "Merging",
               "policy_ref" => "policy-retry",
               "policy" => %{
                 "checks" => ["mix test"],
                 "delivery" => %{"pr_target" => "Merging"},
                 "policy_ref" => "policy-retry"
               }
             }
           } =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-BLOCKED")

    assert %{
             "status" => "blocked",
             "last_error" => "runtime turn requires operator input",
             "blocked" => %{
               "session_id" => "thread-blocked",
               "state" => "In Progress",
               "profile" => "strict",
               "target" => "Human Review",
               "policy_ref" => "policy-blocked",
               "error" => "runtime turn requires operator input"
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ ~r|/dashboard\.css\?v=[0-9a-f]{12}|
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    assert html =~ "/favicon.ico"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ ".project-table"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ "text-decoration-thickness: 1px"

    favicon = response(get(build_conn(), "/favicon.ico"), 200)
    assert favicon =~ "<svg"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Project status"
    assert html =~ "Work errors"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "MT-BLOCKED"
    assert html =~ ~s(href="https://example.org/issues/MT-HTTP")
    assert html =~ ~s(href="https://example.org/issues/MT-RETRY")
    assert html =~ ~s(href="https://example.org/issues/MT-BLOCKED")
    assert html =~ ~s(aria-label="Open MT-HTTP in the issue tracker")
    assert html =~ "Human Review"
    assert html =~ "Merging"
    assert html =~ "rendered"
    assert html =~ "turn blocked: waiting for user input"
    assert html =~ "Runtime"
    assert html =~ "Token usage"
    assert html =~ "Highest active: MT-HTTP"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    assert html =~ "Profile / target"
    refute html =~ "Operations Dashboard"
    refute html =~ "Retry queue"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "javascript:alert('nope')",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_runtime_event: :notification,
          last_runtime_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_runtime_timestamp: DateTime.utc_now(),
          runtime_input_tokens: 10,
          runtime_output_tokens: 12,
          runtime_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)

    refute render(view) =~ "javascript:alert"
  end

  test "dashboard and state API expose durable visual QA artifact references" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "all", status: :passed}],
        review: %{status: :clean},
        product_visual_review: %{
          requirement: :required,
          status: :passed,
          reason: "changed files match product-facing routes",
          artifacts: [
            %{
              kind: :screenshot,
              label: "Desktop screenshot",
              url: "https://artifacts.example/SID-314/desktop.png"
            },
            %{
              kind: :screenshot,
              label: "Mobile screenshot",
              url: "/private/tmp/symphony/mobile.png"
            },
            %{
              kind: :product_design_notes,
              label: "Product design notes",
              summary: "Responsive states looked stable at narrow and wide widths."
            }
          ]
        }
      })

    snapshot =
      static_snapshot()
      |> Map.put(:handoff_routes, [
        decision
        |> HandoffRoute.to_map()
        |> Map.put(:issue_id, "issue-visual")
      ])

    orchestrator_name = Module.concat(__MODULE__, :VisualQaDashboardOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{queued: true, coalesced: true, requested_at: DateTime.utc_now(), operations: ["poll"]}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert [%{"route" => "product_visual_review", "artifacts" => artifacts, "evidence" => evidence}] = state_payload["handoff_routes"]
    assert Enum.any?(artifacts, &(&1["label"] == "Desktop screenshot" and &1["url"] == "https://artifacts.example/SID-314/desktop.png"))
    assert Enum.any?(artifacts, &(&1["label"] == "Product design notes" and &1["summary"] =~ "Responsive states"))
    assert Enum.any?(evidence, &(&1["kind"] == "product_visual_review" and &1["status"] == "passed" and &1["summary"] =~ "changed files match"))
    refute inspect(state_payload["handoff_routes"]) =~ "/private/tmp"

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Handoff routes"
    assert html =~ "Desktop screenshot"
    assert html =~ "Product design notes"
    assert html =~ "Product visual review required passed"
    refute html =~ "/private/tmp"
  end

  test "dashboard shows configured tracker project status and hides empty rate limits" do
    orchestrator_name = Module.concat(__MODULE__, :IdleDashboardOrchestrator)

    snapshot = %{
      running: [
        %{
          issue_id: "issue-active",
          identifier: "MT-ACTIVE",
          project_slug: "project",
          state: "In Progress",
          session_id: "thread-active",
          turn_count: 1,
          codex_app_server_pid: nil,
          last_runtime_message: "working",
          last_runtime_timestamp: DateTime.utc_now(),
          last_runtime_event: :notification,
          runtime_input_tokens: 1,
          runtime_output_tokens: 2,
          runtime_total_tokens: 3,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [],
      runtime_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 0},
      rate_limits: nil
    }

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll"]}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Project status"
    assert html =~ "project"
    assert html =~ "MT-ACTIVE"
    assert html =~ "Active"
    refute html =~ "Rate limits"
    refute html =~ "<pre class=\"code-panel\">n/a</pre>"
  end

  test "dashboard exposes configured Linear team status link when project scope is absent" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_id: nil,
      tracker_project_slug: nil,
      tracker_team_key: "HAR",
      tracker_workspace_slug: "antonio-pontarelli"
    )

    orchestrator_name = Module.concat(__MODULE__, :TeamScopeDashboardOrchestrator)

    snapshot = %{
      running: [],
      retrying: [],
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll"]}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert [
             %{
               "project" => "HAR",
               "project_url" => "https://linear.app/antonio-pontarelli/team/HAR/all",
               "actions" => [%{"label" => "Open Linear", "href" => "https://linear.app/antonio-pontarelli/team/HAR/all"}]
             }
           ] = state_payload["project_statuses"]

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ ~s(href="https://linear.app/antonio-pontarelli/team/HAR/all")
  end

  test "dashboard hides unavailable n/a rate limit snapshots" do
    orchestrator_name = Module.concat(__MODULE__, :UnavailableRateLimitDashboardOrchestrator)

    snapshot = %{
      running: [],
      retrying: [],
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: "n/a"
    }

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll"]}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"rate_limits_available" => false} = json_response(get(build_conn(), "/api/v1/state"), 200)

    {:ok, _view, html} = live(build_conn(), "/")
    refute html =~ "Rate limits"
    refute html =~ "<pre class=\"code-panel\">"
  end

  test "dashboard treats stale active sessions as warnings and hides identification-only rate limits" do
    orchestrator_name = Module.concat(__MODULE__, :StaleDashboardOrchestrator)
    stale_at = DateTime.utc_now() |> DateTime.add(-360, :second)
    started_at = DateTime.utc_now() |> DateTime.add(-420, :second)

    snapshot = %{
      running: [
        %{
          issue_id: "issue-stale",
          identifier: "MT-STALE",
          project_slug: "ops-project",
          state: "In Progress",
          profile: "incident",
          pr_target: "release",
          session_id: "thread-stale",
          turn_count: 3,
          codex_app_server_pid: nil,
          last_runtime_message: "still working",
          last_runtime_timestamp: stale_at,
          last_runtime_event: :notification,
          runtime_input_tokens: 5,
          runtime_output_tokens: 8,
          runtime_total_tokens: 13,
          started_at: started_at
        }
      ],
      retrying: [],
      runtime_totals: %{input_tokens: 5, output_tokens: 8, total_tokens: 13, seconds_running: 0},
      rate_limits: %{"limit_id" => "codex", "primary" => %{}, "secondary" => nil}
    }

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll"]}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert state_payload["counts"]["stale_warnings"] == 1
    assert state_payload["rate_limits_available"] == false

    project_status =
      Enum.find(state_payload["project_statuses"], fn status ->
        status["project_slug"] == "ops-project"
      end)

    assert %{"statuses" => statuses, "profile" => "incident", "pr_target" => "release"} = project_status

    assert "stale" in statuses
    assert "active" in statuses
    assert [%{"profile" => "incident", "pr_target" => "release"}] = state_payload["running"]

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "MT-STALE"
    assert html =~ "Stale"
    assert html =~ "incident"
    assert html =~ "release"
    refute html =~ "Rate limits"
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200

    assert response.body["counts"] == %{
             "running" => 1,
             "retrying" => 1,
             "blocked" => 1,
             "work_errors" => 1,
             "config_warnings" => 0,
             "stale_warnings" => 0
           }

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "https://example.org/issues/MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          profile: "default",
          target: "Human Review",
          policy_ref: "policy-http",
          policy: %{
            "delivery" => %{"pr_target" => "Human Review"},
            "policy_ref" => "policy-http"
          },
          codex_app_server_pid: nil,
          last_runtime_message: "rendered",
          last_runtime_timestamp: nil,
          last_runtime_event: :notification,
          runtime_input_tokens: 4,
          runtime_output_tokens: 8,
          runtime_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          issue_url: "https://example.org/issues/MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          profile: "strict",
          target: "Merging",
          policy_ref: "policy-retry",
          policy: %{
            "checks" => ["mix test"],
            "delivery" => %{"pr_target" => "Merging"},
            "policy_ref" => "policy-retry"
          },
          error: "boom"
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          issue_url: "https://example.org/issues/MT-BLOCKED",
          state: "In Progress",
          error: "runtime turn requires operator input",
          worker_host: "dm-dev2",
          workspace_path: "/workspaces/MT-BLOCKED",
          profile: "strict",
          target: "Human Review",
          policy_ref: "policy-blocked",
          policy: %{
            "delivery" => %{"pr_target" => "Human Review"},
            "policy_ref" => "policy-blocked"
          },
          session_id: "thread-blocked",
          blocked_at: DateTime.utc_now(),
          last_runtime_event: :turn_input_required,
          last_runtime_message: %{
            event: :turn_input_required,
            message: %{"method" => "turn/input_required"},
            timestamp: DateTime.utc_now()
          },
          last_runtime_timestamp: DateTime.utc_now()
        }
      ],
      handoff_routes: [
        %{
          issue_id: "issue-http",
          route: "human_review",
          target_state: "Human Review",
          summary: "Human review required for risky or policy-protected work.",
          recommendation: "Review evidence, then approve for Merging or request Rework.",
          options: [],
          evidence: [],
          artifacts: [],
          metadata: %{}
        }
      ],
      runtime_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
