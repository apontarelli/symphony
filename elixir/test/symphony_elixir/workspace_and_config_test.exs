defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{AutoLand, StringOrMap}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.{LocalConfig, RunTarget}

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear issue routing requires worker assignment and every configured label" do
    issue = %Issue{labels: [" Symphony ", "JavaScript"], assigned_to_worker: true}

    assert Issue.routable?(issue, [])
    assert Issue.routable?(issue, ["symphony"])
    assert Issue.routable?(issue, ["SYMPHONY", "javascript"])
    refute Issue.routable?(issue, ["symph"])
    refute Issue.routable?(issue, [" "])
    refute Issue.routable?(issue, ["symphony", "security"])
    refute Issue.routable?(%{issue | assigned_to_worker: false}, ["symphony"])
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "team" => %{
        "id" => "team-id",
        "key" => "SID",
        "name" => "Side Projects"
      },
      "project" => %{
        "id" => "project-id",
        "slugId" => "project-slug",
        "name" => "Project Name"
      },
      "labels" => %{"nodes" => [%{"name" => " Backend "}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
    assert issue.team_id == "team-id"
    assert issue.team_key == "SID"
    assert issue.team_name == "Side Projects"
    assert issue.project_id == "project-id"
    assert issue.project_slug == "project-slug"
    assert issue.project_name == "Project Name"
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client fetches issue state identifiers without invalid IssueFilter fields" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_state, query, variables})

      {:ok, %{"data" => %{"issue" => raw_issue.(variables.id)}}}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_state, query, %{id: "issue-1", relationFirst: 50}}
    assert query =~ "SymphonyLinearIssueById"
    refute query =~ "identifier: {in: $identifiers}"
    refute query =~ "IssueFilter"

    assert_receive {:fetch_issue_state, ^query, %{id: "issue-2", relationFirst: 50}}
  end

  test "linear client sends UUIDs as ids and issue keys as identifiers" do
    uuid = "11111111-1111-1111-1111-111111111111"

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      case variables do
        %{ids: [^uuid]} ->
          {:ok,
           %{
             "data" => %{
               "issues" => %{
                 "nodes" => [
                   %{
                     "id" => uuid,
                     "identifier" => "SID-999",
                     "title" => "Internal ID lookup",
                     "description" => "Use Linear UUID.",
                     "state" => %{"name" => "Todo"},
                     "labels" => %{"nodes" => []},
                     "inverseRelations" => %{"nodes" => []}
                   }
                 ]
               }
             }
           }}

        %{id: "SID-374"} ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "issue-374",
                 "identifier" => "SID-374",
                 "title" => "Identifier lookup",
                 "description" => "Use issue identifier.",
                 "state" => %{"name" => "Todo"},
                 "labels" => %{"nodes" => []},
                 "inverseRelations" => %{"nodes" => []}
               }
             }
           }}
      end
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test([uuid, "SID-374"], graphql_fun)

    assert Enum.map(issues, & &1.id) == [uuid, "issue-374"]

    assert_receive {:fetch_issue_states_page, uuid_query,
                    %{
                      ids: [^uuid],
                      first: 1,
                      relationFirst: 50
                    }}

    assert uuid_query =~ "SymphonyLinearIssuesByUuid"
    refute uuid_query =~ "identifier: {in: $identifiers}"

    assert_receive {:fetch_issue_states_page, identifier_query,
                    %{
                      id: "SID-374",
                      relationFirst: 50
                    }}

    assert identifier_query =~ "SymphonyLinearIssueById"
  end

  test "linear client fetches URL-style project slugs by Linear slugId suffix" do
    graphql_fun = fn query, variables ->
      send(self(), {:fetch_project_page, query, variables})

      nodes =
        case variables.projectSlug do
          "72083cd8c253" ->
            [
              %{
                "id" => "issue-1",
                "identifier" => "SID-305",
                "title" => "Publish through host-owned VCS handoff",
                "description" => "Use the host repository target.",
                "priority" => 2,
                "state" => %{"name" => "Todo"},
                "labels" => %{"nodes" => []},
                "inverseRelations" => %{"nodes" => []},
                "project" => %{
                  "id" => "project-1",
                  "slugId" => "72083cd8c253",
                  "name" => "Symphony Self-Contained Workflow Modules"
                }
              }
            ]

          _slug ->
            []
        end

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => nodes,
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end

    assert {:ok, [issue]} =
             Client.fetch_by_project_selector_for_test(
               %{project_slug: "symphony-self-contained-workflow-modules-72083cd8c253"},
               ["Todo"],
               graphql_fun
             )

    assert issue.identifier == "SID-305"
    assert issue.project_slug == "72083cd8c253"

    assert_receive {:fetch_project_page, query,
                    %{
                      projectSlug: "symphony-self-contained-workflow-modules-72083cd8c253",
                      stateNames: ["Todo"],
                      first: 50,
                      relationFirst: 50,
                      after: nil
                    }}

    assert query =~ "SymphonyLinearPoll"

    assert_receive {:fetch_project_page, ^query,
                    %{
                      projectSlug: "72083cd8c253",
                      stateNames: ["Todo"],
                      first: 50,
                      relationFirst: 50,
                      after: nil
                    }}
  end

  test "linear client fetches issues by team key when no project scope is configured" do
    graphql_fun = fn query, variables ->
      send(self(), {:fetch_team_page, query, variables})

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{
                 "id" => "issue-1",
                 "identifier" => "HAR-701",
                 "title" => "Pick up unprojected team work",
                 "description" => "Use team scope when no project is set.",
                 "priority" => 2,
                 "state" => %{"name" => "Todo"},
                 "team" => %{"id" => "team-har", "key" => "HAR", "name" => "Hard Sets Solid"},
                 "labels" => %{"nodes" => []},
                 "inverseRelations" => %{"nodes" => []}
               }
             ],
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end

    assert {:ok, [issue]} =
             Client.fetch_by_project_selector_for_test(%{team_key: "HAR"}, ["Todo"], graphql_fun)

    assert issue.identifier == "HAR-701"
    assert issue.team_key == "HAR"
    assert issue.project_slug == nil

    assert_receive {:fetch_team_page, query,
                    %{
                      teamKey: "HAR",
                      stateNames: ["Todo"],
                      first: 50,
                      relationFirst: 50,
                      after: nil
                    }}

    assert query =~ "SymphonyLinearPollByTeamKey"
    assert query =~ "team: {key: {eq: $teamKey}}"
  end

  test "linear client resolves project run target through existing project selector" do
    target = %RunTarget{tracker: "linear", type: :project, project_slug: "repo-project"}

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_project_page, query, variables})

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{
                 "id" => "issue-project",
                 "identifier" => "SID-701",
                 "title" => "Project target",
                 "description" => "Resolve from run target.",
                 "priority" => 2,
                 "state" => %{"name" => "Todo"},
                 "team" => %{"id" => "team-sid", "key" => "SID", "name" => "Side Projects"},
                 "project" => %{"id" => "project-id", "slugId" => "repo-project", "name" => "Repo Project"},
                 "labels" => %{"nodes" => []},
                 "inverseRelations" => %{"nodes" => []}
               }
             ],
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end

    assert {:ok, %RunTarget.Resolution{issues: [issue], warnings: []}} =
             Client.resolve_run_target_for_test(target, ["Todo"], RunTarget.RepoMarkers.empty(), graphql_fun)

    assert issue.identifier == "SID-701"

    assert_receive {:fetch_project_page, query,
                    %{
                      projectSlug: "repo-project",
                      stateNames: ["Todo"],
                      first: 50,
                      relationFirst: 50,
                      after: nil
                    }}

    assert query =~ "SymphonyLinearPoll"
  end

  test "linear client resolves query run target with state and repo marker filters" do
    target = %RunTarget{
      tracker: "linear",
      type: :query,
      filter: %{"priority" => %{"lte" => 2}}
    }

    markers = %RunTarget.RepoMarkers{
      labels: ["symphony"],
      allowed_projects: ["repo-project"]
    }

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_query_page, query, variables})

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{
                 "id" => "issue-query",
                 "identifier" => "SID-702",
                 "title" => "Query target",
                 "description" => "Resolve from Linear-native filter.",
                 "priority" => 1,
                 "state" => %{"name" => "Todo"},
                 "team" => %{"id" => "team-sid", "key" => "SID", "name" => "Side Projects"},
                 "project" => %{"id" => "project-id", "slugId" => "repo-project", "name" => "Repo Project"},
                 "labels" => %{"nodes" => [%{"name" => "Symphony"}]},
                 "inverseRelations" => %{"nodes" => []}
               }
             ],
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end

    assert {:ok, %RunTarget.Resolution{issues: [issue], warnings: []}} =
             Client.resolve_run_target_for_test(target, ["Todo", "In Progress"], markers, graphql_fun)

    assert issue.identifier == "SID-702"

    assert_receive {:fetch_query_page, query,
                    %{
                      filter: %{"and" => filters},
                      first: 50,
                      relationFirst: 50,
                      after: nil
                    }}

    assert query =~ "SymphonyLinearPollByFilter"
    assert %{"priority" => %{"lte" => 2}} in filters
    assert %{"state" => %{"name" => %{"in" => ["Todo", "In Progress"]}}} in filters
    assert inspect(filters) =~ "symphony"
    assert inspect(filters) =~ "repo-project"
  end

  test "linear client resolves explicit issue target in requested order with marker warnings" do
    target = %RunTarget{tracker: "linear", type: :issues, issue_ids: ["issue-2", "issue-1"]}

    markers = %RunTarget.RepoMarkers{
      labels: ["symphony"],
      allowed_projects: ["repo-project"]
    }

    raw_issues = %{
      "issue-1" => %{
        "id" => "issue-1",
        "identifier" => "SID-701",
        "title" => "First issue",
        "description" => "Linear returned this first.",
        "priority" => 1,
        "state" => %{"name" => "Todo"},
        "team" => %{"id" => "team-sid", "key" => "SID", "name" => "Side Projects"},
        "project" => %{"id" => "project-id", "slugId" => "other-project", "name" => "Other"},
        "labels" => %{"nodes" => [%{"name" => "other"}]},
        "inverseRelations" => %{"nodes" => []}
      },
      "issue-2" => %{
        "id" => "issue-2",
        "identifier" => "SID-702",
        "title" => "Second issue",
        "description" => "Requested first.",
        "priority" => 2,
        "state" => %{"name" => "Todo"},
        "team" => %{"id" => "team-sid", "key" => "SID", "name" => "Side Projects"},
        "project" => %{"id" => "project-id", "slugId" => "repo-project", "name" => "Repo Project"},
        "labels" => %{"nodes" => [%{"name" => "Symphony"}]},
        "inverseRelations" => %{"nodes" => []}
      }
    }

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issues, query, variables})

      {:ok, %{"data" => %{"issue" => Map.fetch!(raw_issues, variables.id)}}}
    end

    assert {:ok, %RunTarget.Resolution{issues: issues, warnings: [warning]}} =
             Client.resolve_run_target_for_test(target, ["Todo"], markers, graphql_fun)

    assert Enum.map(issues, & &1.id) == ["issue-2", "issue-1"]
    assert warning.code == :repo_marker_mismatch
    assert warning.issue_id == "issue-1"

    assert_receive {:fetch_issues, query,
                    %{
                      id: "issue-2",
                      relationFirst: 50
                    }}

    assert_receive {:fetch_issues, ^query,
                    %{
                      id: "issue-1",
                      relationFirst: 50
                    }}

    assert query =~ "SymphonyLinearIssueById"
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400, [%{code: "BAD_USER_INPUT", message: "Variable \"$ids\" got invalid value"}]}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "linear client classifies RATELIMITED graphql responses distinctly" do
    request_fun = fn _payload, _headers ->
      {:ok,
       %{
         status: 400,
         headers: [{"X-RateLimit-Requests-Reset", "1893456000000"}],
         body: %{
           "errors" => [
             %{
               "message" => "Rate limit exhausted",
               "extensions" => %{"code" => "RATELIMITED"}
             }
           ]
         }
       }}
    end

    assert {:error, {:linear_rate_limited, details}} =
             Client.graphql("query Viewer { viewer { id } }", %{}, request_fun: request_fun)

    assert details.status == 400
    refute Map.has_key?(details, :retry_after_ms)
    assert details.reset_at == "2030-01-01T00:00:00.000Z"
    assert details.errors == [%{code: "RATELIMITED", message: "Rate limit exhausted"}]
  end

  test "linear client prefers endpoint-specific rate limit reset headers" do
    request_fun = fn _payload, _headers ->
      {:ok,
       %{
         status: 400,
         headers: [
           {"X-RateLimit-Requests-Reset", "1893456000000"},
           {"X-RateLimit-Endpoint-Requests-Reset", "1893455940000"}
         ],
         body: %{
           "errors" => [
             %{
               "message" => "Endpoint rate limit exhausted",
               "extensions" => %{"code" => "RATELIMITED"}
             }
           ]
         }
       }}
    end

    assert {:error, {:linear_rate_limited, details}} =
             Client.graphql("query Viewer { viewer { id } }", %{}, request_fun: request_fun)

    assert details.reset_at == "2029-12-31T23:59:00.000Z"
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "orchestrator preserves explicit issue target order for dispatch" do
    requested_first = %Issue{
      id: "issue-low-priority",
      identifier: "MT-250",
      title: "Requested first",
      state: "Todo",
      priority: 4,
      created_at: ~U[2026-01-03 00:00:00Z]
    }

    requested_second = %Issue{
      id: "issue-high-priority",
      identifier: "MT-251",
      title: "Requested second",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    resolution =
      RunTarget.Resolution.new(
        %RunTarget{tracker: "linear", type: :issues, issue_ids: ["issue-low-priority", "issue-high-priority"]},
        [requested_first, requested_second],
        []
      )

    assert Orchestrator.order_candidate_issues_for_test(resolution) == [requested_first, requested_second]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue without every required label is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: ["symphony", "javascript"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "unlabeled-1",
      identifier: "MT-1008",
      title: "Not opted in",
      state: "Todo",
      project_slug: "project",
      labels: ["symphony"]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(%{issue | labels: ["Symphony", "JavaScript"]}, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      project_slug: "project",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "startup concurrency cap blocks dispatch separately from active agent capacity" do
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_startups: 1)

    candidate = %Issue{
      id: "issue-startup-candidate",
      identifier: "MT-START-2",
      title: "Candidate",
      state: "Todo",
      project_slug: "project"
    }

    starting_issue = %Issue{
      id: "issue-starting",
      identifier: "MT-START-1",
      title: "Starting",
      state: "Todo"
    }

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      max_concurrent_startups: 1,
      running: %{
        "issue-starting" => %{issue: starting_issue, startup_slot?: true}
      },
      claimed: MapSet.new(),
      blocked: %{},
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    refute Orchestrator.should_dispatch_issue_for_test(candidate, state)

    state_with_released_startup = %{
      state
      | running: %{
          "issue-starting" => %{issue: starting_issue, startup_slot?: false}
        }
    }

    assert Orchestrator.should_dispatch_issue_for_test(candidate, state_with_released_startup)
  end

  test "drain mode leaves the scheduler idle after an empty poll" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 3,
      max_concurrent_startups: 1,
      run_mode: :drain,
      running: %{},
      claimed: MapSet.new(),
      blocked: %{},
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    assert {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)
    refute is_reference(updated.tick_timer_ref)
    assert updated.next_poll_due_at_ms == nil
    refute updated.poll_check_in_progress
  end

  test "issue_batch mode stops polling when its dispatch limit is already reached and idle" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 3,
      max_concurrent_startups: 1,
      run_mode: :issue_batch,
      issue_batch_limit: 1,
      running: %{},
      claimed: MapSet.new(),
      blocked: %{},
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{},
      dispatched_issue_count: 1
    }

    assert {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)
    refute is_reference(updated.tick_timer_ref)
    assert updated.next_poll_due_at_ms == nil
    refute updated.poll_check_in_progress
  end

  test "issue ticket kind is derived from generic Symphony labels" do
    assert Issue.ticket_kind(%Issue{labels: [" Requirement "]}) == :requirement
    assert Issue.requirement?(%Issue{labels: ["requirement"]})

    assert Issue.ticket_kind(%Issue{labels: ["Project Closeout"]}) == :project_closeout
    assert Issue.ticket_kind(%Issue{labels: ["project-closeout"]}) == :project_closeout
    assert Issue.ticket_kind(%Issue{labels: ["project_closeout"]}) == :project_closeout

    assert Issue.ticket_kind(%Issue{labels: ["backend", nil, ""]}) == :implementation
    assert Issue.ticket_kind(%Issue{labels: nil}) == :implementation
  end

  test "legacy requirement issues are not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"])

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "requirement-1",
      identifier: "MT-1100",
      title: "Validate legacy requirement workflow",
      state: "Todo",
      labels: ["Requirement"],
      project_slug: "project",
      blocked_by: [%{id: "implementation-1", identifier: "MT-1101", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    assert Orchestrator.dispatch_block_reason_for_test(issue) == :unsupported_requirement_issue
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue, :blocked_by_non_terminal} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "dispatch revalidation skips an issue after a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    stale_issue = %Issue{
      id: "unlabeled-2",
      identifier: "MT-1009",
      title: "Initially opted in",
      state: "Todo",
      labels: ["symphony"]
    }

    refreshed_issue = %{stale_issue | labels: []}
    fetcher = fn ["unlabeled-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, ^refreshed_issue, nil} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)
  end

  test "local config target paths follow existing config-root conventions without creating files" do
    config_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-local-config-paths-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(config_root) end)
    File.rm_rf!(config_root)

    opts = [config_root: config_root]

    assert LocalConfig.path(opts) == Path.join(config_root, "config.yml")
    assert LocalConfig.runs_dir(opts) == Path.join(config_root, "runs")
    assert LocalConfig.target_registry_path(opts) == Path.join(config_root, "targets.yml")
    assert LocalConfig.target_plan_dir(opts) == Path.join(config_root, "target-plans")
    refute File.exists?(config_root)
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.tracker.required_labels == []
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.default_runner == "codex"
    assert config.agent.max_concurrent_agents == 10
    assert config.agent.max_concurrent_startups == 2
    assert Config.max_concurrent_startups() == 2

    runner = Config.default_runner!()
    assert runner["kind"] == "codex_app_server"
    assert runner["command"] == ["codex", "app-server"]
    assert runner["model"] == "gpt-5.6-sol"
    assert runner["approval_policy"] == "never"

    assert runner["thread_sandbox"] == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert runner["turn_timeout_ms"] == 3_600_000
    assert runner["read_timeout_ms"] == 30_000
    assert runner["stall_timeout_ms"] == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: [" Symphony ", "SYMPHONY", "JavaScript"]
    )

    assert Config.settings!().tracker.required_labels == ["symphony", "javascript"]

    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: [" "])
    assert Config.settings!().tracker.required_labels == [""]

    assert {:ok, selector_settings} =
             Schema.parse(%{
               tracker: %{
                 kind: "linear",
                 api_key: "token",
                 issue_ids: [" SID-374 ", "", "SID-374", "SID-375"],
                 query: "query { issues { nodes { id } } }",
                 query_file: "linear-query.graphql"
               },
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    assert selector_settings.tracker.issue_ids == ["SID-374", "SID-375"]
    assert selector_settings.tracker.query == "query { issues { nodes { id } } }"
    assert selector_settings.tracker.query_file == "linear-query.graphql"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

    assert Config.default_runner!()["command"] == ["codex", "--config", "model=\"gpt-5.5\"", "app-server"]

    write_workflow_file!(Workflow.workflow_file_path(), codex_model: "gpt-5.4")
    assert Config.default_runner!()["model"] == "gpt-5.4"

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "never",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    runner = Config.default_runner!(config)
    assert runner["approval_policy"] == "never"
    assert runner["thread_sandbox"] == "workspace-write"

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [explicit_workspace, explicit_cache]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: %{bad: "shape"})
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.kind"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_startups: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_startups"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_startups_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_startups_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "runtime.runners.codex.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "runtime.runners.codex.read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "runtime.runners.codex.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.default_runner!()["approval_policy"] == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "on-request")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "runtime.runners.codex.approval_policy on-request is not supported"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.default_runner!()["thread_sandbox"] == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "runtime.runners.codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    runner = Config.default_runner!(config)
    assert runner["approval_policy"] == "future-policy"
    assert runner["thread_sandbox"] == "future-sandbox"

    assert :ok = Config.validate!()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.default_runner!()["command"] == ["codex", "app-server"]
  end

  test "config accepts Linear team scope when project scope is absent" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_id: nil,
      tracker_project_slug: nil,
      tracker_team_key: "HAR",
      tracker_workspace_slug: "antonio-pontarelli",
      issue_markers: %{"labels" => ["symphony"], "allowed_projects" => []}
    )

    assert :ok = Config.validate!()

    config = Config.settings!()
    assert config.tracker.project_id == nil
    assert config.tracker.project_slug == nil
    assert config.tracker.team_key == "HAR"
    assert config.tracker.workspace_slug == "antonio-pontarelli"
  end

  test "auto-land config normalizes optional tokens and token lists" do
    changeset =
      AutoLand.changeset(%AutoLand{}, %{
        "posture" => " ",
        "required_checks" => [nil, " Tests ", "tests", ""],
        "force_human_review_labels" => [" Manual-Review ", "manual-review", ""],
        "force_human_review_paths" => [nil, " lib/Authority/** ", "lib/Authority/**", ""]
      })

    assert {:ok, auto_land} = Changeset.apply_action(changeset, :validate)
    assert auto_land.posture == nil
    assert auto_land.required_checks == ["tests"]
    assert auto_land.force_human_review_labels == ["manual-review"]
    assert auto_land.force_human_review_paths == ["lib/Authority/**"]
  end

  test "auto-land config accepts explicit real landing opt-in" do
    changeset = AutoLand.changeset(%AutoLand{}, %{"dry_run" => false})

    assert {:ok, auto_land} = Changeset.apply_action(changeset, :validate)
    assert auto_land.dry_run == false
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.workspace.root == Path.expand(workspace_root)
    assert Config.default_runner!(config)["command"] == [codex_bin, "app-server"]
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_agents: 10,
      max_concurrent_startups: 2,
      max_concurrent_agents_by_state: %{
        "todo" => 1,
        "In Progress" => 4,
        "Merging" => 2
      }
    )

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.settings!().agent.max_concurrent_startups == 2
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("Merging") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(),
      worker_max_concurrent_agents_per_host: 2,
      worker_max_concurrent_startups_per_host: 1
    )

    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
    assert Config.settings!().worker.max_concurrent_startups_per_host == 1
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               runners: %{codex: %{approval_policy: %{custom_policy: %{sandbox_approval: true}}}},
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert Schema.default_runner_config!(settings)["approval_policy"] == %{
             "custom_policy" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""},
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema rejects legacy top-level codex config" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               codex: %{command: "codex app-server"},
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    assert message =~ "runtime.codex is not supported"
    assert message =~ "runtime.runners.codex"
  end

  test "shell splitting covers escaped arguments and malformed quotes" do
    assert SymphonyElixir.Shell.split("codex\\ app-server --flag") == {:ok, ["codex app-server", "--flag"]}
    assert SymphonyElixir.Shell.split("'unterminated") == {:error, {:unterminated_quote, "'"}}
  end

  test "runner catalog validation reuses parse normalization and exact errors" do
    catalog = %{
      codex: %{
        kind: " codex_app_server ",
        command: ["codex", "app-server"],
        approval_policy: %{"custom" => %{"sandbox_approval" => true}},
        thread_sandbox: "workspace-write",
        turn_sandbox_policy: %{type: "workspaceWrite", networkAccess: false},
        execution_profiles: %{review: %{sandbox: "read-only"}},
        turn_timeout_ms: 1,
        read_timeout_ms: 2,
        stall_timeout_ms: 0,
        max_concurrent_startups: 3
      },
      open: %{
        kind: "opencode_server",
        command: ["opencode", "serve"],
        model: "anthropic/claude-sonnet-4-5",
        execution_profiles: %{review: %{permissions: %{bash: "deny"}}},
        startup_timeout_ms: 4
      }
    }

    assert {:ok, normalized} = Schema.validate_runner_catalog(catalog)
    assert normalized["codex"]["kind"] == "codex_app_server"

    assert normalized["codex"]["turn_sandbox_policy"] == %{
             "type" => "workspaceWrite",
             "networkAccess" => false
           }

    assert normalized["open"]["kind"] == "opencode_server"
    assert normalized["open"]["startup_timeout_ms"] == 4

    config = %{
      runners: catalog,
      profiles: %{default: %{delivery: %{pr_target: "main"}}}
    }

    assert {:ok, settings} = Schema.parse(config)
    assert settings.runners == normalized

    null_catalog = %{
      codex: %{
        command: nil,
        approval_policy: %{"custom" => %{"sandbox_approval" => nil}},
        turn_sandbox_policy: %{"type" => nil, "networkAccess" => false}
      },
      discarded: nil
    }

    assert {:ok, null_normalized} = Schema.validate_runner_catalog(null_catalog)
    assert Map.keys(null_normalized) == ["codex"]
    assert null_normalized["codex"]["command"] == ["codex", "app-server"]
    assert null_normalized["codex"]["approval_policy"] == %{"custom" => %{}}
    assert null_normalized["codex"]["turn_sandbox_policy"] == %{"networkAccess" => false}

    assert {:ok, null_settings} =
             Schema.parse(%{
               runners: null_catalog,
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    assert null_settings.runners == null_normalized

    null_auth_catalog = %{
      open: %{
        kind: "opencode_server",
        command: ["opencode", "serve"],
        config_content: nil,
        server_auth: %{username: "runner", password: nil}
      },
      discarded: nil
    }

    null_auth_errors = [
      "runtime.runners.open.server_auth.password is required when server_auth is configured"
    ]

    assert {:error, ^null_auth_errors} = Schema.validate_runner_catalog(null_auth_catalog)

    assert {:error,
            [
              %Schema.RunnerCatalogError{
                path: "runtime.runners.open.server_auth.password",
                code: :missing_required_field,
                detail: "is required when server_auth is configured",
                message: "runtime.runners.open.server_auth.password is required when server_auth is configured"
              }
            ]} = Schema.validate_runner_catalog_detailed(null_auth_catalog)

    assert Schema.parse(%{
             agent: %{default_runner: "open"},
             runners: null_auth_catalog,
             profiles: %{default: %{delivery: %{pr_target: "main"}}}
           }) ==
             {:error, {:invalid_workflow_config, "runners runtime.runners.open.server_auth.password is required when server_auth is configured"}}

    invalid_catalogs = [
      {%{codex: %{kind: "other", command: ["runner"]}},
       [
         "runtime.runners.codex.kind \"other\" is not supported; supported kinds: codex_app_server, opencode_server",
         "runtime.runners.codex.stall_timeout_ms must be a non-negative integer"
       ]},
      {%{codex: %{command: ["codex", " "]}}, ["runtime.runners.codex.command[1] must be a non-empty string"]},
      {%{codex: %{approval_policy: "on-request"}}, ["runtime.runners.codex.approval_policy on-request is not supported; Symphony agents are unattended"]},
      {%{codex: %{thread_sandbox: %{}}}, ["runtime.runners.codex.thread_sandbox must be a string"]},
      {%{codex: %{turn_sandbox_policy: []}}, ["runtime.runners.codex.turn_sandbox_policy must be a map"]},
      {%{codex: %{execution_profiles: []}}, ["runtime.runners.codex.execution_profiles must be a map"]},
      {%{codex: %{unexpected: true}}, ["runtime.runners.codex.unexpected is not supported in v1"]},
      {%{codex: %{turn_timeout_ms: 0}}, ["runtime.runners.codex.turn_timeout_ms must be a positive integer"]},
      {%{codex: %{max_concurrent_startups: 0}}, ["runtime.runners.codex.max_concurrent_startups must be a positive integer"]}
    ]

    for {invalid_catalog, expected_errors} <- invalid_catalogs do
      assert {:error, ^expected_errors} = Schema.validate_runner_catalog(invalid_catalog)

      assert {:error, detailed_errors} = Schema.validate_runner_catalog_detailed(invalid_catalog)
      assert Enum.map(detailed_errors, & &1.message) == expected_errors

      invalid_config = %{
        runners: invalid_catalog,
        profiles: %{default: %{delivery: %{pr_target: "main"}}}
      }

      expected_parse_error =
        expected_errors
        |> Enum.reverse()
        |> Enum.map_join(", ", &"runners #{&1}")

      assert Schema.parse(invalid_config) ==
               {:error, {:invalid_workflow_config, expected_parse_error}}
    end
  end

  test "schema validates runner defaults, references, and malformed runner fields" do
    assert {:ok, settings} =
             Schema.parse(%{
               agent: %{default_runner: " custom "},
               runners: %{custom: %{kind: "codex_app_server", command: ["custom-runner"]}},
               profiles: %{default: %{delivery: %{pr_target: "main"}, runners: %{custom: %{}}}}
             })

    assert settings.agent.default_runner == "custom"
    assert Schema.default_runner_name(settings) == "custom"
    assert Schema.default_runner_config!(settings)["kind"] == "codex_app_server"
    assert Schema.default_runner_config!(settings)["command"] == ["custom-runner"]

    assert {:ok, defaulted_settings} =
             Schema.parse(%{
               runners: %{},
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    assert Schema.default_runner_config!(defaulted_settings)["command"] == ["codex", "app-server"]
    assert Schema.default_runner_config!(defaulted_settings)["approval_policy"] == "never"
    assert Schema.default_runner_name(%Schema{agent: nil}) == "codex"
    assert {:error, {:unknown_default_runner, "codex"}} = Schema.default_runner_config(%Schema{runners: %{}})

    assert_raise ArgumentError, ~r/Invalid default runner config/, fn ->
      Schema.default_runner_config!(%Schema{runners: %{}})
    end

    invalid_configs = [
      {%{runners: "bad"}, "runners is invalid"},
      {%{runners: %{" " => %{command: ["runner"]}}}, "runtime.runners runner names must not be blank"},
      {%{agent: %{default_runner: " "}}, "runtime.agent.default_runner is required"},
      {%{agent: %{default_runner: "missing"}}, "runtime.agent.default_runner \"missing\" must reference runtime.runners.missing"},
      {%{runners: %{codex: "bad"}}, "runtime.runners.codex must be a map"},
      {%{runners: %{codex: %{kind: 123}}}, "runtime.runners.codex.kind must be a string"},
      {%{runners: %{custom: %{kind: %{}, command: ["runner"], agent: "build"}}}, "runtime.runners.custom.kind must be a string"},
      {%{runners: %{codex: %{kind: "typo_runner"}}}, "runtime.runners.codex.kind \"typo_runner\" is not supported"},
      {%{runners: %{codex: %{command: ["codex", " "]}}}, "runtime.runners.codex.command[1] must be a non-empty string"},
      {%{runners: %{codex: %{command: ["codex", 123]}}}, "runtime.runners.codex.command[1] must be a non-empty string"},
      {%{runners: %{codex: %{command: []}}}, "runtime.runners.codex.command is required"},
      {%{runners: %{codex: %{command: "codex app-server"}}}, "runtime.runners.codex.command must be a list"},
      {%{runners: %{codex: %{model: 123}}}, "runtime.runners.codex.model must be a string"},
      {%{runners: %{codex: %{approval_policy: 123}}}, "runtime.runners.codex.approval_policy must be a string or map"},
      {%{runners: %{codex: %{approval_policy: "on-request"}}}, "runtime.runners.codex.approval_policy on-request is not supported"},
      {%{runners: %{codex: %{approval_policy: %{"on-request" => %{}}}}}, "runtime.runners.codex.approval_policy on-request is not supported"},
      {%{runners: %{codex: %{execution_profiles: "bad"}}}, "runtime.runners.codex.execution_profiles must be a map"},
      {%{runners: %{codex: %{stall_timeout_ms: -1}}}, "runtime.runners.codex.stall_timeout_ms must be a non-negative integer"},
      {%{runners: %{codex: %{unexpected: true}}}, "runtime.runners.codex.unexpected is not supported in v1"},
      {%{profiles: %{default: %{delivery: %{pr_target: "main"}, runners: %{codex: "bad"}}}}, "default.runners.codex must be a map"},
      {%{profiles: %{default: %{delivery: %{pr_target: "main"}, runners: %{codex: %{approval_policy: "on-request"}}}}}, "default.runners.codex.approval_policy on-request is not supported"},
      {%{profiles: %{default: %{delivery: %{pr_target: "main"}, add_runners: %{codex: %{approval_policy: "on-request"}}}}}, "default.runners.codex.approval_policy on-request is not supported"},
      {%{profiles: %{default: %{delivery: %{pr_target: "main"}, add_runners: %{codex: %{approval_policy: %{"on-request" => %{}}}}}}},
       "default.runners.codex.approval_policy on-request is not supported"},
      {%{profiles: %{default: %{delivery: %{pr_target: "main"}, add_runners: %{codex: %{thread_sandbox: 123}}}}}, "default.runners.codex.thread_sandbox must be a string"},
      {%{profiles: %{default: %{delivery: %{pr_target: "main"}, add_runners: %{codex: %{turn_sandbox_policy: "bad"}}}}}, "default.runners.codex.turn_sandbox_policy must be a map"},
      {%{profiles: %{default: %{delivery: %{pr_target: "main"}, add_runners: %{codex: %{unexpected: true}}}}}, "default.runners.codex.unexpected is not supported in v1"},
      {%{profiles: %{default: %{delivery: %{pr_target: "main"}, add_runners: %{codex: "bad"}}}}, "default.runners.codex must be a map"}
    ]

    for {config, expected_message} <- invalid_configs do
      config = Map.put_new(config, :profiles, %{default: %{delivery: %{pr_target: "main"}}})
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
      assert message =~ expected_message
    end

    assert {:ok, _settings} =
             Schema.parse(%{
               profiles: %{
                 default: %{
                   delivery: %{pr_target: "main"},
                   runners: %{codex: %{approval_policy: "never"}}
                 }
               }
             })

    for approval_policy <- ["on-request", %{"on-request" => %{}}] do
      assert {:error, {:invalid_policy_runner_approval_policy, :on_request}} =
               Config.codex_runtime_settings(nil,
                 policy: %{"runners" => %{"codex" => %{"approval_policy" => approval_policy}}}
               )
    end
  end

  test "schema accepts OpenCode runner fields and rejects malformed values" do
    assert {:ok, settings} =
             Schema.parse(%{
               agent: %{default_runner: "open"},
               runners: %{
                 open: %{
                   kind: "opencode_server",
                   command: ["opencode", "serve"],
                   model: "anthropic/claude-sonnet-4-5",
                   agent: "build",
                   hostname: "127.0.0.1",
                   port: 4_321,
                   config_dir: "/tmp/opencode",
                   config_path: "/tmp/opencode/config.json",
                   config_content: %{permission: %{bash: "allow"}},
                   server_auth: %{username: "symphony", password: "$OPENCODE_PASSWORD"},
                   permissions: %{bash: "allow"},
                   startup_timeout_ms: 5_000,
                   turn_timeout_ms: 60_000,
                   read_timeout_ms: 1_000,
                   stall_timeout_ms: 0
                 }
               },
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    runner = Schema.default_runner_config!(settings)
    assert runner["kind"] == "opencode_server"
    assert runner["command"] == ["opencode", "serve"]
    assert runner["model"] == "anthropic/claude-sonnet-4-5"
    assert runner["agent"] == "build"
    assert runner["hostname"] == "127.0.0.1"
    assert runner["port"] == 4_321
    assert runner["config_content"] == %{"permission" => %{"bash" => "allow"}}
    assert runner["server_auth"] == %{"username" => "symphony", "password" => "$OPENCODE_PASSWORD"}
    assert runner["permissions"] == %{"bash" => "allow"}

    assert {:ok, defaulted_settings} =
             Schema.parse(%{
               agent: %{default_runner: "open"},
               runners: %{open: %{kind: "opencode_server", command: ["opencode", "serve"]}},
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    assert %{
             "hostname" => "127.0.0.1",
             "port" => "auto",
             "permissions" => %{},
             "execution_profiles" => %{},
             "startup_timeout_ms" => 30_000,
             "turn_timeout_ms" => 3_600_000,
             "read_timeout_ms" => 30_000,
             "stall_timeout_ms" => 300_000
           } = Schema.default_runner_config!(defaulted_settings)

    for hostname <- ["localhost", "::1"] do
      assert {:ok, _settings} =
               Schema.parse(%{
                 agent: %{default_runner: "open"},
                 runners: %{
                   open: %{kind: "opencode_server", command: ["opencode", "serve"], hostname: hostname}
                 },
                 profiles: %{default: %{delivery: %{pr_target: "main"}}}
               })
    end

    assert {:ok, null_defaulted_settings} =
             Schema.parse(%{
               agent: %{default_runner: "open"},
               runners: %{
                 open: %{
                   kind: "opencode_server",
                   command: ["opencode", "serve"],
                   startup_timeout_ms: nil,
                   turn_timeout_ms: nil,
                   read_timeout_ms: nil,
                   stall_timeout_ms: nil
                 }
               },
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    assert %{
             "startup_timeout_ms" => 30_000,
             "turn_timeout_ms" => 3_600_000,
             "read_timeout_ms" => 30_000,
             "stall_timeout_ms" => 300_000
           } = Schema.default_runner_config!(null_defaulted_settings)

    assert {:error, {:invalid_workflow_config, missing_command_message}} =
             Schema.parse(%{
               agent: %{default_runner: "open"},
               runners: %{open: %{kind: "opencode_server"}},
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    assert missing_command_message =~ "runtime.runners.open.command is required"

    malformed_fields = [
      {%{model: " "}, "runtime.runners.open.model must be a non-empty string"},
      {%{model: "claude-sonnet"}, "runtime.runners.open.model must use provider/model"},
      {%{model: 123}, "runtime.runners.open.model must be a non-empty string"},
      {%{agent: 123}, "runtime.runners.open.agent must be a non-empty string"},
      {%{hostname: " "}, "runtime.runners.open.hostname must be a non-empty string"},
      {%{hostname: "0.0.0.0"}, "runtime.runners.open.hostname must be a loopback hostname (127.0.0.1, localhost, or ::1)"},
      {%{hostname: " localhost "}, "runtime.runners.open.hostname must be a loopback hostname (127.0.0.1, localhost, or ::1)"},
      {%{port: 0}, "runtime.runners.open.port must be \"auto\" or an integer between 1 and 65535"},
      {%{port: 65_536}, "runtime.runners.open.port must be \"auto\" or an integer between 1 and 65535"},
      {%{config_dir: []}, "runtime.runners.open.config_dir must be a non-empty string"},
      {%{config_path: " "}, "runtime.runners.open.config_path must be a non-empty string"},
      {%{config_content: []}, "runtime.runners.open.config_content must be a non-empty string or map"},
      {%{config_content: " "}, "runtime.runners.open.config_content must be a non-empty string or map"},
      {%{server_auth: "bad"}, "runtime.runners.open.server_auth must be a map"},
      {%{server_auth: %{token: "bad"}}, "runtime.runners.open.server_auth.token is not supported"},
      {%{server_auth: %{username: " "}}, "runtime.runners.open.server_auth.username must be a non-empty string"},
      {%{server_auth: %{username: "symphony"}}, "runtime.runners.open.server_auth.password is required when server_auth is configured"},
      {%{server_auth: %{}}, "runtime.runners.open.server_auth.password is required when server_auth is configured"},
      {%{permissions: []}, "runtime.runners.open.permissions must be a map"},
      {%{startup_timeout_ms: 0}, "runtime.runners.open.startup_timeout_ms must be a positive integer"},
      {%{approval_policy: "never"}, "runtime.runners.open.approval_policy is not supported for opencode_server"}
    ]

    for {overrides, expected_message} <- malformed_fields do
      runner =
        %{kind: "opencode_server", command: ["opencode", "serve"]}
        |> Map.merge(overrides)

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 agent: %{default_runner: "open"},
                 runners: %{open: runner},
                 profiles: %{default: %{delivery: %{pr_target: "main"}}}
               })

      assert message =~ expected_message
    end
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             runners: %{"codex" => %{"turn_sandbox_policy" => explicit_policy}},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             runners: Schema.default_runners(),
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               runners: Schema.default_runners(),
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "codex runtime settings honor selected profile sandbox overrides" do
    write_workflow_file!(Workflow.workflow_file_path(),
      profiles: %{
        default: %{delivery: %{pr_target: "main"}},
        skill_authoring: %{
          delivery: %{pr_target: "main"},
          runners: %{
            codex: %{
              approval_policy: %{custom_policy: %{sandbox_approval: false}},
              thread_sandbox: "danger-full-access",
              turn_sandbox_policy: %{type: "dangerFullAccess"}
            }
          }
        }
      }
    )

    assert {:ok, policy} = Config.effective_policy("skill_authoring")

    assert {:ok, runtime_settings} =
             Config.codex_runtime_settings(nil, policy: policy)

    assert runtime_settings == %{
             approval_policy: %{"custom_policy" => %{"sandbox_approval" => false}},
             thread_sandbox: "danger-full-access",
             turn_sandbox_policy: %{"type" => "dangerFullAccess"}
           }
  end

  test "codex runtime settings use the selected runner snapshot" do
    assert {:ok, settings} =
             Schema.parse(%{profiles: %{default: %{delivery: %{pr_target: "main"}}}})

    selected_runner =
      Schema.default_runner_config!(settings)
      |> Map.merge(%{
        "approval_policy" => "never",
        "thread_sandbox" => "read-only",
        "turn_sandbox_policy" => %{"type" => "readOnly"}
      })

    policy = %{
      "runners" => %{
        "snapshot" => %{"approval_policy" => %{"selected" => %{"allow" => true}}}
      }
    }

    assert {:ok, runtime_settings} =
             Config.codex_runtime_settings(nil,
               runtime_settings: settings,
               runner_name: "snapshot",
               runner_config: selected_runner,
               policy: policy
             )

    assert runtime_settings == %{
             approval_policy: %{"selected" => %{"allow" => true}},
             thread_sandbox: "read-only",
             turn_sandbox_policy: %{"type" => "readOnly"}
           }
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"},
               runners: %{codex: %{kind: "codex_app_server", command: ["codex", "app-server"]}},
               profiles: %{default: %{delivery: %{pr_target: "main"}}}
             })

    assert settings.workspace.root == "~/.symphony-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.symphony-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.symphony-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "runtime sandbox policy resolution passes explicit policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | runners: put_in(settings.runners, ["codex", "turn_sandbox_policy"], %{"type" => "readOnly", "networkAccess" => true})
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | runners:
            put_in(settings.runners, ["codex", "turn_sandbox_policy"], %{
              "type" => "futureSandbox",
              "nested" => %{"flag" => true}
            })
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "trusted-local profile can enable localhost network without changing default sandbox posture" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-trusted-local-profile-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-TRUSTED")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        profiles: %{
          default: %{
            delivery: %{pr_target: "main"},
            capabilities: %{required: []}
          },
          trusted_local: %{
            capabilities: %{required: ["localhost_tcp", "git_metadata", "github_pr"]},
            runners: %{
              codex: %{
                turn_sandbox_policy: %{
                  type: "workspaceWrite",
                  writableRoots: [issue_workspace],
                  networkAccess: true,
                  readOnlyAccess: %{type: "fullAccess"},
                  excludeTmpdirEnvVar: false,
                  excludeSlashTmp: false
                }
              }
            }
          }
        }
      )

      settings = Config.settings!()

      assert {:ok, default_policy} = Schema.resolve_effective_policy(settings, "default")
      assert {:ok, default_runtime} = Config.codex_runtime_settings(issue_workspace, policy: default_policy)
      assert default_runtime.turn_sandbox_policy["type"] == "workspaceWrite"
      assert default_runtime.turn_sandbox_policy["networkAccess"] == false

      assert {:ok, trusted_policy} = Schema.resolve_effective_policy(settings, "trusted_local")
      assert get_in(trusted_policy, ["capabilities", "required"]) == ["localhost_tcp", "git_metadata", "github_pr"]

      assert {:ok, trusted_runtime} = Config.codex_runtime_settings(issue_workspace, policy: trusted_policy)
      assert trusted_runtime.turn_sandbox_policy["type"] == "workspaceWrite"
      assert trusted_runtime.turn_sandbox_policy["networkAccess"] == true
      assert trusted_runtime.turn_sandbox_policy["writableRoots"] == [issue_workspace]
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end
end
