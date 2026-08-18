defmodule SymphonyElixir.TrackerContextTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ExecutionContext, RunTarget, TargetContext, Tracker}
  alias SymphonyElixir.Linear.{Client, Issue}

  defmodule RecordingContextLinearClient do
    alias SymphonyElixir.RunTarget
    alias SymphonyElixir.TargetContext

    def resolve_run_target(%TargetContext{} = context, %RunTarget{} = target) do
      Process.put(
        {__MODULE__, :resolve_calls},
        Process.get({__MODULE__, :resolve_calls}, 0) + 1
      )

      send(self(), {:context_resolve_run_target, context, target})
      Process.get({__MODULE__, :resolve_result}, {:ok, RunTarget.Resolution.new(target, [])})
    end

    def fetch_issues_by_states(%TargetContext{} = context, states) do
      increment(:state_reads)
      send(self(), {:context_fetch_issues_by_states, context, states})
      Process.get({__MODULE__, :fetch_issues_result}, {:ok, []})
    end

    def fetch_issue_states_by_ids(%TargetContext{} = context, issue_ids) do
      increment(:id_reads)
      send(self(), {:context_fetch_issue_states_by_ids, context, issue_ids})
      Process.get({__MODULE__, :fetch_issue_states_result}, {:ok, []})
    end

    def graphql(%TargetContext{} = context, query, variables, opts) do
      send(self(), {:context_graphql, context, query, variables, opts})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _no_queue ->
          Process.get({__MODULE__, :graphql_result})
      end
    end

    defp increment(operation) do
      Process.put(
        {__MODULE__, operation},
        Process.get({__MODULE__, operation}, 0) + 1
      )
    end
  end

  defmodule HostileContextLinearClient do
    alias SymphonyElixir.{RunTarget, TargetContext}

    def resolve_run_target(%TargetContext{}, %RunTarget{}), do: hostile_result()

    def fetch_issues_by_states(%TargetContext{}, _states), do: hostile_result()

    def fetch_issue_states_by_ids(%TargetContext{}, _issue_ids), do: hostile_result()

    def graphql(%TargetContext{}, _query, _variables, _opts), do: hostile_result()

    defp hostile_result, do: hostile_result(Process.get({__MODULE__, :action}))

    defp hostile_result({:return, result}), do: result

    defp hostile_result(action) do
      case action do
        :raise ->
          raise "secret-state-read-raise"

        :throw ->
          throw(:secret_state_read_throw)

        :exit ->
          exit(:secret_state_read_exit)

        :error ->
          {:error, :secret_state_read_reason}

        :malformed ->
          :secret_state_read_malformed

        :nested_malformed ->
          {:ok, %{"data" => :secret_nested_malformed}}

        :rate_limit ->
          {:error,
           {:linear_rate_limited,
            %{
              status: 429,
              retry_after_ms: 500,
              reset_at: "secret-hostile-reset",
              reason: "secret-hostile-reason"
            }}}

        :rate_limit_valid ->
          {:error,
           {:linear_rate_limited,
            %{
              status: 429,
              retry_after_ms: 500,
              reset_at: "2029-12-31T23:59:00.000Z",
              reason: "secret-hostile-reason"
            }}}
      end
    end
  end

  setup do
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if previous_client do
        Application.put_env(:symphony_elixir, :linear_client_module, previous_client)
      else
        Application.delete_env(:symphony_elixir, :linear_client_module)
      end
    end)

    :ok
  end

  test "context GraphQL requests keep endpoint token and payload pinned under concurrency" do
    parent = self()

    contexts = [
      target_context("alpha", "connection-a", "https://alpha.example/graphql", "token-alpha"),
      target_context("beta", "connection-b", "https://beta.example/graphql", "token-beta")
    ]

    tasks =
      Enum.map(contexts, fn context ->
        Task.async(fn ->
          request_fun = fn endpoint, payload, headers ->
            send(parent, {:context_request, self(), endpoint, payload, headers})

            receive do
              :respond -> {:ok, %{status: 200, body: %{"data" => %{"ok" => true}}}}
            end
          end

          Client.graphql(
            context,
            "query Pinned($target: String!) { pinned(target: $target) }",
            %{target: context.target_id},
            request_fun: request_fun
          )
        end)
      end)

    requests =
      for _ <- contexts do
        assert_receive {:context_request, pid, endpoint, payload, headers}
        {pid, endpoint, payload, headers}
      end

    request_details =
      Map.new(requests, fn {_pid, endpoint, payload, headers} ->
        {endpoint, {payload, headers}}
      end)

    assert request_details == %{
             "https://alpha.example/graphql" => {
               %{
                 "query" => "query Pinned($target: String!) { pinned(target: $target) }",
                 "variables" => %{target: "alpha"}
               },
               [{"Authorization", "token-alpha"}, {"Content-Type", "application/json"}]
             },
             "https://beta.example/graphql" => {
               %{
                 "query" => "query Pinned($target: String!) { pinned(target: $target) }",
                 "variables" => %{target: "beta"}
               },
               [{"Authorization", "token-beta"}, {"Content-Type", "application/json"}]
             }
           }

    Enum.each(tasks, &send(&1.pid, :respond))

    assert Enum.map(tasks, &Task.await/1) ==
             [
               {:ok, %{"data" => %{"ok" => true}}},
               {:ok, %{"data" => %{"ok" => true}}}
             ]
  end

  test "tracker normalizes registry scopes and explicit overrides without consulting global tracker config" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: "poison-global-token"
    )

    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      RecordingContextLinearClient
    )

    scopes = [
      {%{"type" => "project", "project" => %{"id" => "project-1"}}, %RunTarget{type: :project, project_id: "project-1"}},
      {%{"type" => "team", "team" => %{"key" => "SID"}}, %RunTarget{type: :team, team_key: "SID"}},
      {%{"type" => "issues", "issues" => ["issue-2", "issue-1"]}, %RunTarget{type: :issues, issue_ids: ["issue-2", "issue-1"]}},
      {%{"type" => "query", "filter" => %{"priority" => %{"gte" => 2}}}, %RunTarget{type: :query, filter: %{"priority" => %{"gte" => 2}}}}
    ]

    Enum.each(scopes, fn {scope, expected_target} ->
      context =
        target_context(
          "scope-#{expected_target.type}",
          "connection-#{expected_target.type}",
          "https://scope.example/graphql",
          "scope-token",
          %{
            "scope" => scope,
            "active_states" => ["Todo"],
            "required_labels" => ["symphony"],
            "assignee" => "worker-1"
          }
        )

      assert {:ok, %RunTarget.Resolution{target: ^expected_target}} =
               Tracker.resolve_candidate_issues_uncached(context)

      assert_receive {:context_resolve_run_target, ^context, ^expected_target}
    end)

    context =
      target_context(
        "override",
        "connection-override",
        "https://override.example/graphql",
        "override-token",
        %{"scope" => %{"type" => "project", "project" => %{"id" => "ignored-project"}}}
      )

    explicit_target = %RunTarget{type: :issues, issue_ids: ["explicit-issue"]}

    assert {:ok, %RunTarget.Resolution{target: ^explicit_target}} =
             Tracker.resolve_candidate_issues_uncached(context, explicit_target)

    assert_receive {:context_resolve_run_target, ^context, ^explicit_target}

    incompatible_target = %RunTarget{
      tracker: "memory",
      type: :issues,
      issue_ids: ["wrong-tracker"]
    }

    assert {:error, :invalid_tracker_adapter} =
             Tracker.resolve_candidate_issues_uncached(context, incompatible_target)

    query_file_context =
      target_context(
        "query-file",
        "connection-query-file",
        "https://query-file.example/graphql",
        "query-file-token",
        %{"scope" => %{"type" => "query", "query_file" => "/tmp/must-not-be-read.json"}}
      )

    assert {:error, :query_file_not_materialized} =
             Tracker.resolve_candidate_issues_uncached(query_file_context)
  end

  test "context candidate reads preserve marker safety errors" do
    Application.put_env(:symphony_elixir, :linear_client_module, Client)

    context =
      target_context(
        "marker-safety",
        "connection-marker-safety",
        "https://marker-safety.example/graphql",
        "marker-safety-token",
        %{
          "scope" => %{"type" => "team", "team" => %{"key" => "SID"}},
          "active_states" => ["Todo"],
          "required_labels" => [],
          "assignee" => nil
        }
      )

    assert {:error, :run_target_requires_issue_markers} =
             Tracker.resolve_candidate_issues_uncached(context)
  end

  test "Linear context resolution uses pinned states labels and assignee routing" do
    context =
      target_context(
        "routed",
        "connection-routed",
        "https://routed.example/graphql",
        "routed-token",
        %{
          "active_states" => ["Todo", "In Progress"],
          "required_labels" => ["required-a", "required-b"],
          "assignee" => "worker-1"
        }
      )

    target = %RunTarget{type: :project, project_id: "project-routed"}
    parent = self()

    request_fun = fn endpoint, payload, headers ->
      send(parent, {:routed_request, endpoint, payload, headers})

      {:ok,
       %{
         status: 200,
         body:
           linear_issue_page([
             linear_issue("issue-routable", "worker-1", ["required-a", "required-b"]),
             linear_issue("issue-missing-label", "worker-1", ["required-a"]),
             linear_issue("issue-wrong-assignee", "worker-2", ["required-a", "required-b"])
           ])
       }}
    end

    assert {:ok, %RunTarget.Resolution{issues: [%Issue{id: "issue-routable"}]}} =
             Client.resolve_run_target(context, target, request_fun: request_fun)

    assert_receive {:routed_request, "https://routed.example/graphql", payload, headers}
    assert payload["variables"].stateNames == ["Todo", "In Progress"]
    assert payload["variables"].projectId == "project-routed"
    assert headers == [{"Authorization", "routed-token"}, {"Content-Type", "application/json"}]
  end

  test "'me' assignee lookup uses the same pinned context GraphQL closure" do
    context =
      target_context(
        "viewer",
        "connection-viewer",
        "https://viewer.example/graphql",
        "viewer-token",
        %{"active_states" => ["Todo"], "required_labels" => [], "assignee" => "me"}
      )

    target = %RunTarget{type: :project, project_id: "project-viewer"}
    parent = self()

    request_fun = fn endpoint, payload, headers ->
      send(parent, {:viewer_request, endpoint, payload, headers})

      body =
        if payload["query"] =~ "SymphonyLinearViewer" do
          %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}
        else
          linear_issue_page([linear_issue("issue-viewer", "viewer-1", [])])
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, %RunTarget.Resolution{issues: [%Issue{id: "issue-viewer"}]}} =
             Client.resolve_run_target(context, target, request_fun: request_fun)

    assert_receive {:viewer_request, "https://viewer.example/graphql", viewer_payload, [{"Authorization", "viewer-token"}, {"Content-Type", "application/json"}]}

    assert viewer_payload["query"] =~ "SymphonyLinearViewer"

    assert_receive {:viewer_request, "https://viewer.example/graphql", issue_payload, [{"Authorization", "viewer-token"}, {"Content-Type", "application/json"}]}

    assert issue_payload["variables"].projectId == "project-viewer"
  end

  test "candidate cache normalizes equivalent routing labels before keying" do
    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      RecordingContextLinearClient
    )

    run_target = %{
      "scope" => %{"type" => "issues", "issue_ids" => ["normalized-issue"]},
      "active_states" => ["Todo"],
      "required_labels" => ["Required", "required"],
      "assignee" => "worker-1"
    }

    context =
      target_context(
        "normalized-target",
        "normalized-connection",
        "https://normalized.example/graphql",
        "normalized-token",
        run_target
      )

    normalized_context =
      %{context | run_target: %{run_target | "required_labels" => ["required"]}}

    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(context)
    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(normalized_context)
    assert Process.get({RecordingContextLinearClient, :resolve_calls}) == 1
  end

  test "candidate cache isolates pinned connections and tokens without persisting secrets" do
    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      RecordingContextLinearClient
    )

    scope = %{
      "scope" => %{"type" => "issues", "issue_ids" => ["shared-issue"]},
      "active_states" => ["Todo"],
      "required_labels" => ["required"],
      "assignee" => "worker-1"
    }

    context_a =
      target_context(
        "shared-target",
        "connection-a",
        "https://cache.example/graphql",
        "cache-token-a",
        scope
      )
      |> Map.put(:repo_policy, %{"manifest" => %{"secret" => "manifest-secret-a"}})

    context_b =
      target_context(
        "shared-target",
        "connection-b",
        "https://cache.example/graphql",
        "cache-token-a",
        scope
      )

    context_c =
      target_context(
        "shared-target",
        "connection-a",
        "https://cache.example/graphql",
        "cache-token-c",
        scope
      )

    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(context_a)
    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(context_a)

    regenerated_context = %{context_a | registry_generation: "unrelated-generation"}
    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(regenerated_context)

    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(context_b)
    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(context_b)
    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(context_c)
    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(context_c)

    assert Process.get({RecordingContextLinearClient, :resolve_calls}) == 3

    state_bytes = File.read!(context_tracker_state_path(context_a))

    refute state_bytes =~ "cache-token-a"
    refute state_bytes =~ "cache-token-c"
    refute state_bytes =~ "manifest-secret-a"
    refute state_bytes =~ "TargetContext"
  end

  test "candidate cache uses pinned state path on cold and warm reads without ambient config" do
    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      RecordingContextLinearClient
    )

    unique = System.unique_integer([:positive])
    pinned_root = Path.join(System.tmp_dir!(), "tracker-context-pinned-#{unique}")
    poisoned_root = Path.join(System.tmp_dir!(), "tracker-context-poisoned-#{unique}")
    pinned_state_path = Path.join([pinned_root, ".symphony", "tracker_coordinator.state"])
    poisoned_state_path = Path.join(poisoned_root, "ambient.state")
    missing_workflow = Path.join(poisoned_root, "missing.yml")

    on_exit(fn ->
      File.rm_rf(pinned_root)
      File.rm_rf(poisoned_root)
    end)

    context =
      target_context(
        "pinned-state-path",
        "connection-pinned-state-path",
        "https://pinned-state-path.example/graphql",
        "pinned-state-path-token",
        %{
          "scope" => %{"type" => "issues", "issue_ids" => ["pinned-state-path"]},
          "active_states" => ["Todo"],
          "required_labels" => [],
          "assignee" => nil
        }
      )
      |> Map.put(:worktree_policy, %{
        "root" => pinned_root,
        "strategy" => "per_issue",
        "hooks" => %{}
      })

    Workflow.set_workflow_file_path(missing_workflow)
    assert_raise ArgumentError, fn -> Config.settings!() end

    Application.put_env(
      :symphony_elixir,
      :tracker_coordinator_state_path,
      {:poisoned_ambient_state_path, poisoned_state_path}
    )

    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(context)
    assert File.exists?(pinned_state_path)

    Application.put_env(
      :symphony_elixir,
      :tracker_coordinator_state_path,
      poisoned_state_path
    )

    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(context)
    refute File.exists?(poisoned_state_path)
    refute pinned_state_path =~ context.target_id
    refute pinned_state_path =~ context.tracker_connection["policy"]["api_key"]
    assert Process.get({RecordingContextLinearClient, :resolve_calls}) == 1
  end

  test "candidate cache rejects malformed worktree policy before lookup" do
    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      RecordingContextLinearClient
    )

    context =
      target_context(
        "malformed-worktree-policy",
        "connection-malformed-worktree-policy",
        "https://malformed-worktree-policy.example/graphql",
        "malformed-worktree-policy-token",
        %{
          "scope" => %{"type" => "issues", "issue_ids" => ["malformed-worktree-policy"]},
          "active_states" => ["Todo"],
          "required_labels" => [],
          "assignee" => nil
        }
      )

    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(context)

    malformed_policies = [
      :invalid,
      %{},
      %{"root" => nil},
      %{"root" => ""},
      %{"root" => " "},
      %{root: context.worktree_policy["root"]},
      %{"worktree" => %{"root" => context.worktree_policy["root"]}}
    ]

    Enum.each(malformed_policies, fn worktree_policy ->
      assert {:error, :invalid_tracker_context} =
               Tracker.resolve_candidate_issues(%{context | worktree_policy: worktree_policy})
    end)

    assert Process.get({RecordingContextLinearClient, :resolve_calls}) == 1
  end

  test "candidate cache rejects noncanonical context tracker kinds before cache lookup" do
    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      RecordingContextLinearClient
    )

    context =
      target_context(
        "canonical-kind",
        "connection-canonical-kind",
        "https://canonical-kind.example/graphql",
        "canonical-kind-token",
        %{
          "scope" => %{"type" => "issues", "issue_ids" => ["canonical-kind"]},
          "active_states" => ["Todo"],
          "required_labels" => [],
          "assignee" => nil
        }
      )

    state_path = context_tracker_state_path(context)
    Application.put_env(:symphony_elixir, :tracker_coordinator_state_path, state_path)

    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(context)

    uppercase =
      put_in(context, [Access.key!(:tracker_connection), "policy", "kind"], "LINEAR")

    assert {:error, :invalid_tracker_adapter} =
             Tracker.resolve_candidate_issues(uppercase)

    Application.put_env(
      :symphony_elixir,
      :tracker_coordinator_state_path,
      {:poisoned_ambient_state_path, state_path}
    )

    for kind <- [" linear", "linear ", " linear "] do
      whitespace =
        put_in(context, [Access.key!(:tracker_connection), "policy", "kind"], kind)

      assert {:error, :invalid_tracker_adapter} =
               Tracker.resolve_candidate_issues(whitespace)
    end

    assert Process.get({RecordingContextLinearClient, :resolve_calls}) == 1
  end

  test "context adapter rejects hostile tracker values before return or persistence" do
    Application.put_env(:symphony_elixir, :linear_client_module, HostileContextLinearClient)

    token = "secret-hostile-result-token"

    context =
      target_context(
        "hostile-result",
        "connection-hostile-result",
        "https://hostile-result.example/graphql",
        token,
        %{
          "scope" => %{"type" => "issues", "issue_ids" => ["hostile-result"]},
          "active_states" => ["Todo"],
          "required_labels" => [],
          "assignee" => nil
        }
      )

    target = %RunTarget{tracker: "linear", type: :issues, issue_ids: ["hostile-result"]}

    extra_key_resolution =
      Map.put(
        %RunTarget.Resolution{
          target: target,
          issues: [],
          warnings: [],
          ordering: :target
        },
        :extra,
        context
      )

    malformed_resolutions = [
      extra_key_resolution,
      %RunTarget.Resolution{
        target: %{target | issue_ids: ["other-result"]},
        issues: [],
        warnings: [],
        ordering: :target
      },
      :not_a_resolution,
      %RunTarget.Resolution{
        target: target,
        issues: :not_an_issue_list,
        warnings: [],
        ordering: :target
      },
      %RunTarget.Resolution{
        target: target,
        issues: [context],
        warnings: [],
        ordering: :target
      },
      %RunTarget.Resolution{
        target: target,
        issues: [],
        warnings: :not_a_warning_list,
        ordering: :target
      },
      %RunTarget.Resolution{
        target: target,
        issues: [],
        warnings: [context],
        ordering: :target
      },
      %RunTarget.Resolution{
        target: target,
        issues: [],
        warnings: [:not_a_warning],
        ordering: :target
      },
      %RunTarget.Resolution{
        target: target,
        issues: [],
        warnings: [%{message: "missing code"}],
        ordering: :target
      },
      %RunTarget.Resolution{
        target: target,
        issues: [],
        warnings: [%{code: :repo_marker_mismatch, unsafe: context}],
        ordering: :target
      },
      %RunTarget.Resolution{
        target: target,
        issues: [],
        warnings: [%{code: token}],
        ordering: :target
      },
      %RunTarget.Resolution{
        target: target,
        issues: [],
        warnings: [%{code: :repo_marker_mismatch, issue_id: context}],
        ordering: :target
      },
      %RunTarget.Resolution{
        target: target,
        issues: [],
        warnings: [%{code: :repo_marker_mismatch, issue_identifier: context}],
        ordering: :target
      },
      %RunTarget.Resolution{
        target: target,
        issues: [],
        warnings: [%{code: :repo_marker_mismatch, message: context}],
        ordering: :target
      },
      %RunTarget.Resolution{
        target: target,
        issues: [],
        warnings: [],
        ordering: token
      }
    ]

    log =
      capture_log(fn ->
        Enum.each(malformed_resolutions, fn resolution ->
          Process.put(
            {HostileContextLinearClient, :action},
            {:return, {:ok, resolution}}
          )

          assert {:error, :invalid_tracker_adapter_result} =
                   Tracker.resolve_candidate_issues(context, target)
        end)

        safe_resolution = %RunTarget.Resolution{
          target: target,
          issues: [%Issue{id: "safe-result", identifier: "SID-409"}],
          warnings: [
            %{
              code: :repo_marker_mismatch,
              issue_id: nil,
              issue_identifier: "SID-409",
              message: "Explicit issue does not match repository issue markers."
            }
          ],
          ordering: :target
        }

        Process.put(
          {HostileContextLinearClient, :action},
          {:return, {:ok, safe_resolution}}
        )

        assert {:ok, ^safe_resolution} = Tracker.resolve_candidate_issues(context, target)

        Process.put(
          {HostileContextLinearClient, :action},
          {:return, {:ok, [context]}}
        )

        assert {:error, :invalid_tracker_adapter_result} =
                 Tracker.fetch_issues_by_states(context, ["Todo"])

        assert {:error, :invalid_tracker_adapter_result} =
                 Tracker.fetch_issue_states_by_ids(context, ["hostile-result"])
      end)

    state_bytes =
      case File.read(SymphonyElixir.TrackerCoordinator.state_path()) do
        {:ok, bytes} -> bytes
        {:error, :enoent} -> ""
      end

    refute log =~ token
    refute state_bytes =~ token
    refute state_bytes =~ "TargetContext"
  end

  test "context candidate reads reject malformed tagged issues before caching" do
    Application.put_env(:symphony_elixir, :linear_client_module, HostileContextLinearClient)

    token = "secret-malformed-candidate-token"

    context =
      target_context(
        "malformed-candidate",
        "connection-malformed-candidate",
        "https://malformed-candidate.example/graphql",
        token,
        %{
          "scope" => %{"type" => "issues", "issue_ids" => ["malformed-candidate"]},
          "active_states" => ["Todo"],
          "required_labels" => [],
          "assignee" => nil
        }
      )

    target = %RunTarget{tracker: "linear", type: :issues, issue_ids: ["malformed-candidate"]}

    Enum.each(malformed_tagged_issues(context), fn {_field, issue} ->
      resolution = %RunTarget.Resolution{
        target: target,
        issues: [issue],
        warnings: [],
        ordering: :target
      }

      Process.put(
        {HostileContextLinearClient, :action},
        {:return, {:ok, resolution}}
      )

      assert {:error, :invalid_tracker_adapter_result} =
               Tracker.resolve_candidate_issues(context, target)
    end)

    safe_resolution = %RunTarget.Resolution{
      target: target,
      issues: [normalized_issue()],
      warnings: [],
      ordering: :target
    }

    Process.put(
      {HostileContextLinearClient, :action},
      {:return, {:ok, safe_resolution}}
    )

    assert {:ok, ^safe_resolution} = Tracker.resolve_candidate_issues(context, target)

    state_bytes = File.read!(SymphonyElixir.TrackerCoordinator.state_path())
    refute state_bytes =~ token
    refute state_bytes =~ "TargetContext"
  end

  test "context state reads reject every malformed tagged Issue field" do
    Application.put_env(:symphony_elixir, :linear_client_module, HostileContextLinearClient)

    context =
      target_context(
        "malformed-state-read",
        "connection-malformed-state-read",
        "https://malformed-state-read.example/graphql",
        "secret-malformed-state-read-token",
        %{"scope" => %{"type" => "issues", "issue_ids" => ["malformed-state-read"]}}
      )

    Enum.each(malformed_tagged_issues(context), fn {_field, issue} ->
      Process.put(
        {HostileContextLinearClient, :action},
        {:return, {:ok, [issue]}}
      )

      assert {:error, :invalid_tracker_adapter_result} =
               Tracker.fetch_issues_by_states(context, ["Todo"])

      assert {:error, :invalid_tracker_adapter_result} =
               Tracker.fetch_issue_states_by_ids(context, ["malformed-state-read"])
    end)

    Process.put(
      {HostileContextLinearClient, :action},
      {:return, {:ok, [normalized_issue()]}}
    )

    assert {:ok, [_issue]} = Tracker.fetch_issues_by_states(context, ["Todo"])
    assert {:ok, [_issue]} = Tracker.fetch_issue_states_by_ids(context, ["malformed-state-read"])
  end

  test "context issue results accept only canonical parsed UTC datetimes" do
    Application.put_env(:symphony_elixir, :linear_client_module, HostileContextLinearClient)

    context =
      target_context(
        "canonical-datetime",
        "connection-canonical-datetime",
        "https://canonical-datetime.example/graphql",
        "secret-canonical-datetime-token"
      )

    assert {:ok, %DateTime{} = whole_seconds, 0} =
             DateTime.from_iso8601("2026-08-18T12:00:00Z")

    assert {:ok, %DateTime{} = milliseconds, 0} =
             DateTime.from_iso8601("2026-08-18T12:00:00.123Z")

    Enum.each([whole_seconds, milliseconds], fn datetime ->
      issue = %{normalized_issue() | created_at: datetime, updated_at: datetime}
      Process.put({HostileContextLinearClient, :action}, {:return, {:ok, [issue]}})

      assert {:ok, [^issue]} = Tracker.fetch_issues_by_states(context, ["Todo"])
    end)

    rejected_datetimes = [
      %DateTime{whole_seconds | microsecond: {1, 0}},
      %DateTime{milliseconds | microsecond: {123_456, 3}},
      %DateTime{milliseconds | time_zone: "UTC"}
    ]

    Enum.each(rejected_datetimes, fn datetime ->
      issue = %{normalized_issue() | created_at: datetime}
      Process.put({HostileContextLinearClient, :action}, {:return, {:ok, [issue]}})

      assert {:error, :invalid_tracker_adapter_result} =
               Tracker.fetch_issues_by_states(context, ["Todo"])
    end)
  end

  test "candidate cache rejects malformed routing before cache lookup" do
    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      RecordingContextLinearClient
    )

    routing_secret = "secret-improper-routing-tail"

    missing_workflow =
      Path.join(
        System.tmp_dir!(),
        "missing-routing-workflow-#{System.unique_integer([:positive])}.yml"
      )

    Workflow.set_workflow_file_path(missing_workflow)
    assert_raise ArgumentError, fn -> Config.settings!() end

    valid_routing = %{
      "scope" => %{"type" => "issues", "issue_ids" => ["cache-routing"]},
      "active_states" => ["Todo"],
      "required_labels" => ["required"],
      "assignee" => nil
    }

    cases = [
      {"active-states", "active_states", ["Todo", " "]},
      {"active-states-type", "active_states", :invalid},
      {"active-states-improper", "active_states", ["Todo" | {:secret, routing_secret}]},
      {"required-labels", "required_labels", ["required", 123]},
      {"required-labels-improper", "required_labels", ["required" | {:secret, routing_secret}]},
      {"assignee", "assignee", 123},
      {"assignee-blank", "assignee", " "}
    ]

    log =
      capture_log(fn ->
        cases
        |> Enum.with_index(1)
        |> Enum.each(fn {{suffix, field, malformed_value}, expected_calls} ->
          context =
            target_context(
              "cache-routing-#{suffix}",
              "connection-cache-routing-#{suffix}",
              "https://cache-routing.example/graphql",
              "cache-routing-token",
              valid_routing
            )

          assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(context)
          assert Process.get({RecordingContextLinearClient, :resolve_calls}) == expected_calls

          malformed_context = put_in(context.run_target[field], malformed_value)

          assert {:error, :invalid_tracker_context} =
                   Tracker.resolve_candidate_issues(malformed_context)

          assert Process.get({RecordingContextLinearClient, :resolve_calls}) == expected_calls
        end)

        malformed_context =
          target_context(
            "cache-routing-invalid-run-target",
            "connection-cache-routing-invalid-run-target",
            "https://cache-routing.example/graphql",
            "cache-routing-token",
            :invalid
          )

        assert {:error, :invalid_tracker_context} =
                 Tracker.resolve_candidate_issues(malformed_context)
      end)

    assert Process.get({RecordingContextLinearClient, :resolve_calls}) == 7
    refute log =~ routing_secret
  end

  test "Linear context routing rejects improper state and label lists before requests" do
    routing_secret = "secret-improper-client-routing-tail"

    missing_workflow =
      Path.join(
        System.tmp_dir!(),
        "missing-client-routing-workflow-#{System.unique_integer([:positive])}.yml"
      )

    Workflow.set_workflow_file_path(missing_workflow)
    assert_raise ArgumentError, fn -> Config.settings!() end

    valid_routing = %{
      "scope" => %{"type" => "issues", "issue_ids" => ["client-routing"]},
      "active_states" => ["Todo"],
      "required_labels" => ["required"],
      "assignee" => nil
    }

    target = %RunTarget{tracker: "linear", type: :issues, issue_ids: ["client-routing"]}

    request_fun = fn _endpoint, _payload, _headers ->
      Process.put(:improper_routing_request_calls, Process.get(:improper_routing_request_calls, 0) + 1)
      {:error, {:secret, routing_secret}}
    end

    contexts = [
      target_context(
        "client-active-states-improper",
        "connection-client-active-states-improper",
        "https://client-routing.example/graphql",
        "client-routing-token",
        %{valid_routing | "active_states" => ["Todo" | {:secret, routing_secret}]}
      ),
      target_context(
        "client-required-labels-improper",
        "connection-client-required-labels-improper",
        "https://client-routing.example/graphql",
        "client-routing-token",
        %{valid_routing | "required_labels" => ["required" | {:secret, routing_secret}]}
      )
    ]

    log =
      capture_log(fn ->
        Enum.each(contexts, fn context ->
          assert {:error, :invalid_tracker_context} =
                   Client.resolve_run_target(context, target, request_fun: request_fun)
        end)
      end)

    assert Process.get(:improper_routing_request_calls, 0) == 0
    refute log =~ routing_secret
  end

  test "context state reads use pinned adapter paths and empty lists are no-ops" do
    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      RecordingContextLinearClient
    )

    context =
      target_context(
        "state-reads",
        "connection-state-reads",
        "https://state-reads.example/graphql",
        "state-reads-token",
        %{
          "scope" => %{"type" => "project", "project" => %{"id" => "project-state"}},
          "active_states" => ["Todo"],
          "terminal_states" => ["Done"],
          "required_labels" => [],
          "assignee" => nil
        }
      )

    state_issue = %Issue{id: "state-issue", state: "Done"}
    Process.put({RecordingContextLinearClient, :fetch_issues_result}, {:ok, [state_issue]})
    Process.put({RecordingContextLinearClient, :fetch_issue_states_result}, {:ok, [state_issue]})

    assert {:ok, [^state_issue]} = Tracker.fetch_issues_by_states(context, ["Done"])
    assert_receive {:context_fetch_issues_by_states, ^context, ["Done"]}

    assert {:ok, [^state_issue]} =
             Tracker.fetch_issue_states_by_ids(context, ["state-issue"])

    assert_receive {:context_fetch_issue_states_by_ids, ^context, ["state-issue"]}

    assert {:ok, []} = Tracker.fetch_issues_by_states(context, [])
    assert {:ok, []} = Tracker.fetch_issue_states_by_ids(context, [])
    assert Process.get({RecordingContextLinearClient, :state_reads}) == 1
    assert Process.get({RecordingContextLinearClient, :id_reads}) == 1
  end

  test "Linear context state reads keep transport pinned" do
    context =
      target_context(
        "client-state-reads",
        "connection-client-state",
        "https://client-state.example/graphql",
        "client-state-token",
        %{
          "scope" => %{"type" => "project", "project" => %{"id" => "project-state"}},
          "active_states" => ["Todo"],
          "terminal_states" => ["Done"],
          "required_labels" => [],
          "assignee" => nil
        }
      )

    parent = self()

    request_fun = fn endpoint, payload, headers ->
      send(parent, {:client_state_request, endpoint, payload, headers})

      body =
        if payload["query"] =~ "SymphonyLinearIssueById" do
          %{"data" => %{"issue" => linear_issue("state-by-id", nil, [])}}
        else
          linear_issue_page([linear_issue("state-by-name", nil, [])])
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, [%Issue{id: "state-by-name"}]} =
             Client.fetch_issues_by_states(context, ["Done"], request_fun: request_fun)

    assert {:ok, [%Issue{id: "state-by-id"}]} =
             Client.fetch_issue_states_by_ids(context, ["SID-1"], request_fun: request_fun)

    for _ <- 1..2 do
      assert_receive {:client_state_request, "https://client-state.example/graphql", _payload, [{"Authorization", "client-state-token"}, {"Content-Type", "application/json"}]}
    end
  end

  test "context state reads contain hostile client modules and malformed results" do
    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      HostileContextLinearClient
    )

    context =
      target_context(
        "hostile-state",
        "connection-hostile-state",
        "https://hostile-state.example/graphql",
        "secret-hostile-state-token",
        %{"scope" => %{"type" => "issues", "issue_ids" => ["hostile-state"]}}
      )

    expectations = [
      {:raise, {:error, :linear_request_failed}},
      {:throw, {:error, :linear_request_failed}},
      {:exit, {:error, :linear_request_failed}},
      {:error, {:error, :invalid_tracker_adapter_result}},
      {:malformed, {:error, :invalid_tracker_adapter_result}}
    ]

    log =
      capture_log(fn ->
        Enum.each(expectations, fn {action, expected} ->
          Process.put({HostileContextLinearClient, :action}, action)
          assert Tracker.fetch_issue_states_by_ids(context, ["hostile-state"]) == expected
        end)

        Process.put({HostileContextLinearClient, :action}, :error)

        assert {:error, :invalid_tracker_adapter_result} =
                 Tracker.fetch_issues_by_states(context, ["Todo"])
      end)

    refute log =~ "secret-state"
    refute log =~ "secret_state"
    assert {:ok, []} = Tracker.fetch_issue_states_by_ids(context, [])
  end

  test "context adapters reject invalid injected client modules" do
    context =
      target_context(
        "invalid-client",
        "connection-invalid-client",
        "https://invalid-client.example/graphql",
        "invalid-client-token",
        %{}
      )

    Application.put_env(:symphony_elixir, :linear_client_module, "not-a-module")
    assert {:error, :invalid_tracker_adapter} = Tracker.fetch_issue_states_by_ids(context, ["issue"])

    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      SymphonyElixir.MissingContextLinearClient
    )

    assert {:error, :invalid_tracker_adapter} = Tracker.fetch_issue_states_by_ids(context, ["issue"])
  end

  test "ExecutionContext writes pin comment and state mutation GraphQL calls" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "https://poisoned-global.example/graphql",
      tracker_api_token: "poisoned-global-token"
    )

    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      RecordingContextLinearClient
    )

    context =
      target_context(
        "writes",
        "connection-writes",
        "https://writes.example/graphql",
        "writes-token",
        %{"active_states" => ["Todo"], "required_labels" => [], "assignee" => nil}
      )

    execution_context = execution_context(context)

    Process.put(
      {RecordingContextLinearClient, :graphql_results},
      [{:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}]
    )

    assert :ok = Tracker.create_comment(execution_context, "issue-write", "Pinned comment")

    assert_receive {:context_graphql, ^context, comment_query, %{issueId: "issue-write", body: "Pinned comment"}, []}

    assert comment_query =~ "commentCreate"

    Process.put(
      {RecordingContextLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{"states" => %{"nodes" => [%{"id" => "state-done"}]}}
             }
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Tracker.update_issue_state(execution_context, "issue-write", "Done")

    assert_receive {:context_graphql, ^context, state_query, %{issueId: "issue-write", stateName: "Done"}, []}

    assert state_query =~ "states"

    assert_receive {:context_graphql, ^context, update_query, %{issueId: "issue-write", stateId: "state-done"}, []}

    assert update_query =~ "issueUpdate"
  end

  test "ExecutionContext memory writes preserve legacy event tuples" do
    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      HostileContextLinearClient
    )

    context =
      target_context(
        "memory-writes",
        "connection-memory-writes",
        "https://must-not-run.example/graphql",
        "must-not-run-token",
        %{}
      )
      |> put_in(
        [Access.key!(:tracker_connection), "policy", "kind"],
        "memory"
      )

    execution_context = execution_context(context)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

    assert :ok = Tracker.create_comment(execution_context, "memory-issue", "Memory comment")
    assert_receive {:memory_tracker_comment, "memory-issue", "Memory comment"}

    assert :ok = Tracker.update_issue_state(execution_context, "memory-issue", "Done")
    assert_receive {:memory_tracker_state_update, "memory-issue", "Done"}
  end

  test "context memory reads preserve legacy results and explicit overloads" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issues = [
      %Issue{id: "memory-1", state: "Todo"},
      %Issue{id: "memory-2", state: "Done"}
    ]

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)

    context =
      target_context(
        "memory-reads",
        "connection-memory-reads",
        "https://unused-memory.example/graphql",
        "unused-memory-token",
        %{
          "scope" => %{"type" => "issues", "issue_ids" => ["memory-2", "memory-1"]},
          "active_states" => ["Todo"],
          "required_labels" => [],
          "assignee" => nil
        }
      )
      |> put_in([Access.key!(:tracker_connection), "policy", "kind"], "memory")
      |> put_in([Access.key!(:tracker_connection), "policy", "endpoint"], nil)
      |> put_in([Access.key!(:tracker_connection), "policy", "api_key"], nil)

    assert {:ok, %RunTarget.Resolution{issues: [%Issue{id: "memory-2"}, %Issue{id: "memory-1"}]}} =
             Tracker.resolve_candidate_issues_uncached(context)

    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(context)
    assert {:ok, [%Issue{id: "memory-2"}]} = Tracker.fetch_issues_by_states(context, ["Done"])
    assert {:ok, [%Issue{id: "memory-1"}]} = Tracker.fetch_issue_states_by_ids(context, ["memory-1"])

    legacy_target = %RunTarget{tracker: "memory", type: :issues, issue_ids: ["memory-1"]}
    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues(nil)
    assert {:ok, %RunTarget.Resolution{}} = Tracker.resolve_candidate_issues_uncached(nil)

    assert {:ok, %RunTarget.Resolution{target: ^legacy_target}} =
             Tracker.resolve_candidate_issues_uncached(legacy_target)
  end

  test "context memory candidate cache follows configured issue identity" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    context =
      target_context(
        "memory-cache",
        "connection-memory-cache",
        "https://unused-memory-cache.example/graphql",
        "unused-memory-cache-token",
        %{
          "scope" => %{"type" => "issues", "issue_ids" => ["memory-a", "memory-b"]},
          "active_states" => ["Todo"],
          "required_labels" => [],
          "assignee" => nil
        }
      )
      |> put_in([Access.key!(:tracker_connection), "policy", "kind"], "memory")
      |> put_in([Access.key!(:tracker_connection), "policy", "endpoint"], nil)
      |> put_in([Access.key!(:tracker_connection), "policy", "api_key"], nil)

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_issues,
      [%Issue{id: "memory-a", state: "Todo"}]
    )

    assert {:ok, %RunTarget.Resolution{issues: [%Issue{id: "memory-a"}]}} =
             Tracker.resolve_candidate_issues(context)

    assert_receive {:memory_tracker_resolve_candidate_issues, %RunTarget{}}

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_issues,
      [%Issue{id: "memory-b", state: "Todo"}]
    )

    assert {:ok, %RunTarget.Resolution{issues: [%Issue{id: "memory-b"}]}} =
             Tracker.resolve_candidate_issues(context)

    assert_receive {:memory_tracker_resolve_candidate_issues, %RunTarget{}}
  end

  test "context Tracker APIs reject malformed public inputs" do
    context =
      target_context(
        "malformed",
        "connection-malformed",
        "https://malformed.example/graphql",
        "malformed-token",
        %{"scope" => %{"type" => "issues", "issue_ids" => ["issue"]}}
      )

    assert {:error, :invalid_tracker_context} = Tracker.resolve_candidate_issues(context, :invalid)
    assert {:error, :invalid_tracker_context} = Tracker.resolve_candidate_issues_uncached(context, :invalid)
    assert {:error, :invalid_tracker_context} = Tracker.fetch_issues_by_states(context, :invalid)
    assert {:error, :invalid_tracker_context} = Tracker.fetch_issue_states_by_ids(context, :invalid)

    invalid_execution_context = %{execution_context(context) | target: nil}

    assert {:error, :invalid_tracker_context} =
             Tracker.create_comment(invalid_execution_context, "issue", "body")

    assert {:error, :invalid_tracker_context} =
             Tracker.update_issue_state(invalid_execution_context, "issue", "Done")

    malformed_connection = %{context | tracker_connection: %{}}

    assert {:error, :invalid_tracker_context} =
             Tracker.resolve_candidate_issues_uncached(malformed_connection)

    unsupported =
      put_in(context, [Access.key!(:tracker_connection), "policy", "kind"], "unsupported")

    assert {:error, :invalid_tracker_adapter} =
             Tracker.resolve_candidate_issues_uncached(unsupported)

    nonmaterialized = %{context | run_target: %{"scope" => "not-a-materialized-scope"}}
    assert {:error, :invalid_run_target} = Tracker.resolve_candidate_issues_uncached(nonmaterialized)

    trackerless = %RunTarget{tracker: nil, type: :issues, issue_ids: []}

    assert {:error, :invalid_tracker_adapter} =
             Tracker.resolve_candidate_issues_uncached(context, trackerless)
  end

  test "ExecutionContext writes contain hostile client callbacks and malformed results" do
    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      HostileContextLinearClient
    )

    context =
      target_context(
        "hostile-writes",
        "connection-hostile-writes",
        "https://hostile-writes.example/graphql",
        "secret-hostile-writes-token",
        %{}
      )

    execution_context = execution_context(context)

    expectations = [
      {:raise, {:error, :linear_request_failed}},
      {:throw, {:error, :linear_request_failed}},
      {:exit, {:error, :linear_request_failed}},
      {:error, {:error, :invalid_tracker_adapter_result}},
      {:malformed, {:error, :invalid_tracker_adapter_result}},
      {:nested_malformed, {:error, :invalid_tracker_adapter_result}},
      {:rate_limit, {:error, {:linear_rate_limited, %{status: 429, retry_after_ms: 500}}}},
      {:rate_limit_valid,
       {:error,
        {:linear_rate_limited,
         %{
           status: 429,
           retry_after_ms: 500,
           reset_at: "2029-12-31T23:59:00.000Z"
         }}}}
    ]

    log =
      capture_log(fn ->
        Enum.each(expectations, fn {action, expected} ->
          Process.put({HostileContextLinearClient, :action}, action)

          assert Tracker.create_comment(
                   execution_context,
                   "hostile-issue",
                   "hostile body"
                 ) == expected

          assert Tracker.update_issue_state(
                   execution_context,
                   "hostile-issue",
                   "Done"
                 ) == expected
        end)
      end)

    refute log =~ "secret-hostile"
    refute log =~ "secret_hostile"
  end

  test "ExecutionContext state writes return stable domain failures" do
    Application.put_env(
      :symphony_elixir,
      :linear_client_module,
      RecordingContextLinearClient
    )

    context =
      target_context(
        "write-failures",
        "connection-write-failures",
        "https://write-failures.example/graphql",
        "write-failures-token",
        %{}
      )

    execution_context = execution_context(context)

    Process.put(
      {RecordingContextLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => []}}}
           }
         }}
      ]
    )

    assert {:error, :state_not_found} =
             Tracker.update_issue_state(execution_context, "issue", "Missing")

    state_lookup =
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{"states" => %{"nodes" => [%{"id" => "state-done"}]}}
           }
         }
       }}

    Process.put(
      {RecordingContextLinearClient, :graphql_results},
      [state_lookup, {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}]
    )

    assert {:error, :issue_update_failed} =
             Tracker.update_issue_state(execution_context, "issue", "Done")

    Process.put(
      {RecordingContextLinearClient, :graphql_results},
      [state_lookup, {:error, :secret_write_failure}]
    )

    assert {:error, :invalid_tracker_adapter_result} =
             Tracker.update_issue_state(execution_context, "issue", "Done")
  end

  test "context GraphQL transport contains hostile callback failures and secrets" do
    context =
      target_context(
        "hostile",
        "connection-hostile",
        "https://hostile.example/graphql",
        "secret-hostile-token"
      )

    cases = [
      {fn _, _, _ -> raise "secret-hostile-raise" end, {:error, :linear_request_failed}},
      {fn _, _, _ -> throw(:secret_hostile_throw) end, {:error, :linear_request_failed}},
      {fn _, _, _ -> exit(:secret_hostile_exit) end, {:error, :linear_request_failed}},
      {fn _, _, _ -> {:error, :secret_hostile_reason} end, {:error, :linear_request_failed}},
      {fn _, _, _ -> :secret_hostile_malformed end, {:error, :invalid_linear_request_result}},
      {fn _, _, _ -> {:ok, :secret_hostile_body} end, {:error, :invalid_linear_request_result}}
    ]

    log =
      capture_log(fn ->
        Enum.each(cases, fn {request_fun, expected} ->
          assert Client.graphql(context, "query Hostile { hostile }", %{}, request_fun: request_fun) == expected
        end)
      end)

    refute log =~ "secret-hostile"
    refute log =~ "secret_hostile"
  end

  test "context GraphQL validates complete hostile response matrices" do
    token = "secret-hostile-response-token"

    context =
      target_context(
        "hostile-response",
        "connection-hostile-response",
        "https://hostile-response.example/graphql",
        token
      )

    valid_body = %{"data" => %{"viewer" => %{"id" => "viewer-id"}}}

    cases = [
      {fn _, _, _ -> {:ok, %{status: 200, body: valid_body}} end, {:ok, valid_body}},
      {fn _, _, _ -> {:ok, %{status: 200, body: %{"hostile" => token}}} end, {:error, :invalid_linear_request_result}},
      {fn _, _, _ -> {:ok, %{status: 200, body: %{context => token}}} end, {:error, :invalid_linear_request_result}},
      {fn _, _, _ -> {:ok, %{status: token, body: valid_body}} end, {:error, :invalid_linear_request_result}},
      {fn _, _, _ ->
         {:ok,
          %{
            status: 400,
            headers: %{context => token},
            body: %{
              "errors" => [
                %{
                  "message" => "Rate limited",
                  "extensions" => %{"code" => "RATELIMITED"}
                }
              ]
            }
          }}
       end, {:error, :invalid_linear_request_result}},
      {fn _, _, _ -> {:ok, %{status: 400, body: %{"errors" => []}}} end, {:error, :linear_request_failed}},
      {fn _, _, _ -> {:error, token} end, {:error, :linear_request_failed}},
      {fn _, _, _ ->
         {:ok,
          %{
            status: 400,
            headers: [{"retry-after", "2"}],
            body: %{
              "errors" => [
                %{
                  "message" => "Rate limited",
                  "extensions" => %{"code" => "RATELIMITED"}
                }
              ]
            }
          }}
       end, {:error, {:linear_rate_limited, %{status: 400, retry_after_ms: 2_000}}}}
    ]

    log =
      capture_log(fn ->
        Enum.each(cases, fn {request_fun, expected} ->
          assert Client.graphql(
                   context,
                   "query HostileResponse { viewer { id } }",
                   %{},
                   request_fun: request_fun
                 ) == expected
        end)
      end)

    refute log =~ token
  end

  test "context resolve arity rejects malformed arguments without ambient config" do
    missing_workflow =
      Path.join(
        System.tmp_dir!(),
        "missing-context-workflow-#{System.unique_integer([:positive])}.yml"
      )

    Workflow.set_workflow_file_path(missing_workflow)
    assert_raise ArgumentError, fn -> Config.settings!() end

    context =
      target_context(
        "arity-context",
        "connection-arity-context",
        "https://arity-context.example/graphql",
        "arity-context-token",
        %{
          "scope" => %{"type" => "issues", "issue_ids" => ["arity-context"]},
          "active_states" => ["Todo"],
          "required_labels" => [],
          "assignee" => nil
        }
      )

    target = %RunTarget{tracker: "linear", type: :issues, issue_ids: ["arity-context"]}

    assert {:error, :invalid_tracker_context} = Client.resolve_run_target(context, [])

    assert {:error, :invalid_tracker_context} =
             Client.resolve_run_target(%{context | run_target: :invalid}, target)
  end

  test "context GraphQL rejects malformed pinned tracker policy before transport" do
    valid =
      target_context(
        "invalid",
        "connection-invalid",
        "https://invalid.example/graphql",
        "secret-invalid-token"
      )

    contexts = [
      put_in(valid, [Access.key!(:tracker_connection), "policy", "endpoint"], nil),
      put_in(valid, [Access.key!(:tracker_connection), "policy", "endpoint"], " "),
      put_in(valid, [Access.key!(:tracker_connection), "policy", "api_key"], " "),
      put_in(valid, [Access.key!(:tracker_connection), "id"], " ")
    ]

    Enum.each(contexts, fn context ->
      assert {:error, :invalid_tracker_context} =
               Client.graphql(context, "query Invalid { invalid }", %{}, request_fun: fn _, _, _ -> flunk("transport must not run") end)
    end)
  end

  defp normalized_issue do
    %Issue{
      id: "normalized-id",
      identifier: "SID-409",
      title: "Normalized issue",
      description: "Normalized description",
      priority: 1,
      state: "Todo",
      branch_name: "sid-409-normalized",
      url: "https://linear.example/SID-409",
      assignee_id: "worker-id",
      team_id: "team-id",
      team_key: "SID",
      team_name: "Symphony",
      project_id: "project-id",
      project_slug: "symphony",
      project_name: "Symphony",
      blocked_by: [%{id: "blocker-id", identifier: "SID-408", state: "Done"}],
      labels: ["required"],
      assigned_to_worker: true,
      created_at: ~U[2026-08-18 12:00:00.000000Z],
      updated_at: ~U[2026-08-18 13:00:00.000000Z]
    }
  end

  defp malformed_tagged_issues(context) do
    issue = normalized_issue()

    scalar_fields = [
      :id,
      :identifier,
      :title,
      :description,
      :state,
      :branch_name,
      :url,
      :assignee_id,
      :team_id,
      :team_key,
      :team_name,
      :project_id,
      :project_slug,
      :project_name
    ]

    Enum.map(scalar_fields, &{&1, Map.put(issue, &1, context)}) ++
      [
        {:priority, %{issue | priority: context}},
        {:labels, %{issue | labels: ["required", context]}},
        {:assigned_to_worker, %{issue | assigned_to_worker: context}},
        {:blocked_by_entry, %{issue | blocked_by: [context]}},
        {:blocked_by_value, %{issue | blocked_by: [%{id: context, identifier: "SID-408", state: "Done"}]}},
        {:blocked_by_tail,
         %{
           issue
           | blocked_by: [
               %{id: "blocker-id", identifier: "SID-408", state: "Done"} | context
             ]
         }},
        {:blocked_by_extra,
         %{
           issue
           | blocked_by: [
               %{id: "blocker-id", identifier: "SID-408", state: "Done", extra: context}
             ]
         }},
        {:created_at_value, %{issue | created_at: context}},
        {:created_at_forged, %{issue | created_at: %DateTime{issue.created_at | year: context}}},
        {:created_at_extra, %{issue | created_at: Map.put(issue.created_at, :extra, context)}},
        {:updated_at_forged, %{issue | updated_at: %DateTime{issue.updated_at | time_zone: context}}},
        {:updated_at_forged_microsecond,
         %{
           issue
           | updated_at: %DateTime{issue.updated_at | microsecond: {0, context}}
         }},
        {:issue_extra, Map.put(issue, :extra, context)}
      ]
  end

  defp execution_context(target) do
    %ExecutionContext{
      target: target,
      issue_id: "context-issue",
      issue_identifier: "SID-409",
      workspace_path: "/tmp/context-workspace",
      runner_name: "runner",
      runner_config: %{},
      policy: %{},
      role: :implementation,
      execution_profile: nil,
      timeout_ms: 1,
      max_retries: 0,
      worker_host: nil
    }
  end

  defp linear_issue_page(issues) do
    %{
      "data" => %{
        "issues" => %{
          "nodes" => issues,
          "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
        }
      }
    }
  end

  defp linear_issue(id, assignee_id, labels) do
    %{
      "id" => id,
      "identifier" => String.upcase(id),
      "title" => id,
      "state" => %{"name" => "Todo"},
      "assignee" => %{"id" => assignee_id},
      "team" => %{"id" => "team-1", "key" => "SID", "name" => "SID"},
      "project" => %{"id" => "project-routed", "slugId" => "routed", "name" => "Routed"},
      "labels" => %{"nodes" => Enum.map(labels, &%{"name" => &1})},
      "inverseRelations" => %{"nodes" => []}
    }
  end

  defp context_tracker_state_path(%TargetContext{
         worktree_policy: %{"root" => root}
       }) do
    root
    |> Path.expand()
    |> Path.join(".symphony/tracker_coordinator.state")
  end

  defp context_worktree_root do
    :symphony_elixir
    |> Application.fetch_env!(:tracker_coordinator_state_path)
    |> Path.dirname()
    |> Path.dirname()
  end

  defp target_context(target_id, connection_id, endpoint, token, run_target \\ %{}) do
    %TargetContext{
      target_id: target_id,
      state: :active,
      dispatch_mode: :watch,
      registry_generation: "generation",
      policy_hash: "policy-hash",
      repo_manifest_hash: "manifest-hash",
      repo_policy: %{},
      tracker_connection: %{
        "id" => connection_id,
        "policy" => %{
          "kind" => "linear",
          "endpoint" => endpoint,
          "api_key" => token
        }
      },
      run_target: run_target,
      worktree_policy: %{"root" => context_worktree_root()},
      runner_policy: %{},
      effective_checks: %{},
      external_side_effect_gates: %{},
      capacity_limits: %{},
      budget_limits: %{}
    }
  end
end
