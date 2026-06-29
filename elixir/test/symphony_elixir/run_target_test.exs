defmodule SymphonyElixir.RunTargetTest do
  use SymphonyElixir.TestSupport

  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema.IssueMarkers
  alias SymphonyElixir.Linear.Filter
  alias SymphonyElixir.RunTarget
  alias SymphonyElixir.Tracker.Memory

  test "runtime target envelope parses without legacy tracker project scope" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_id: nil,
      tracker_project_slug: nil,
      tracker_team_key: nil,
      issue_markers: %{
        "labels" => [" Symphony ", "SYMPHONY"],
        "allowed_projects" => ["symphony-project", " symphony-project "]
      },
      target: %{"tracker" => "linear", "type" => "team", "team_key" => " SID "}
    )

    settings = Config.settings!()

    assert settings.issue_markers.labels == ["symphony"]
    assert settings.issue_markers.allowed_projects == ["symphony-project"]

    assert {:ok, %RunTarget{tracker: "linear", type: :team, team_key: "SID"}} =
             RunTarget.from_settings(settings)

    assert :ok = Config.validate!()
  end

  test "legacy tracker selectors still parse as project or team targets" do
    assert {:ok, %RunTarget{tracker: "linear", type: :project, project_id: "project-id"}} =
             RunTarget.from_settings(%{
               tracker: %{"kind" => "linear", "project_id" => " project-id "}
             })

    assert {:ok, %RunTarget{tracker: "linear", type: :project, project_slug: "repo-project"}} =
             RunTarget.from_settings(%{
               target: nil,
               tracker: %{kind: :linear, project_slug: " repo-project "}
             })

    assert {:ok, %RunTarget{tracker: "linear", type: :team, team_key: "SID"}} =
             RunTarget.from_settings(%{tracker: %{kind: "linear", team_key: " SID "}})

    assert {:ok, %RunTarget{tracker: "linear", type: :issues, issue_ids: ["SID-1", "SID-2"]}} =
             RunTarget.from_settings(%{tracker: %{kind: "linear", issue_ids: [" SID-1 ", "", "SID-2"]}})

    assert {:error, :missing_run_target} = RunTarget.from_settings(%{})
    assert {:error, :missing_linear_run_target} = RunTarget.from_settings(%{target: nil, tracker: nil})

    assert {:error, {:unsupported_run_target_type, "unknown"}} =
             RunTarget.from_settings(%{
               target: %{"type" => "unknown"},
               tracker: %{kind: "linear", project_slug: "repo-project"}
             })
  end

  test "runtime target parser accepts supported target shapes" do
    assert {:ok, %RunTarget{tracker: "linear", type: :project, project_id: "project-id"}} =
             RunTarget.parse(%{"type" => :project, "project" => %{"id" => " project-id "}})

    assert {:ok, %RunTarget{type: :project, project_slug: "repo-project"}} =
             RunTarget.parse(%{
               "type" => "project",
               "project" => %{"slugId" => " repo-project "}
             })

    assert {:ok, %RunTarget{type: :query, filter: filter}} =
             RunTarget.parse(%{
               "type" => "query",
               "query" => %{
                 priority: %{lte: 2},
                 labels: [%{name: "Symphony"}]
               }
             })

    assert filter == %{
             "priority" => %{"lte" => 2},
             "labels" => [%{"name" => "Symphony"}]
           }

    assert {:ok, %RunTarget{type: :issues, issue_ids: ["SID-1"]}} =
             RunTarget.parse(%{"type" => "issue", "issues" => [" SID-1 ", "", "SID-1", 42]})

    assert {:ok, %RunTarget{type: :issues, issue_ids: ["SID-2"]}} =
             RunTarget.parse(%{"type" => "issue_ids", "ids" => ["SID-2"]})
  end

  test "runtime target parser reports invalid or incomplete target shapes" do
    assert {:error, :invalid_run_target} = RunTarget.parse("team SID")
    assert {:error, :missing_run_target_type} = RunTarget.parse(%{"type" => " "})
    assert {:error, :missing_run_target_type} = RunTarget.parse(%{"type" => 42})
    assert {:error, {:unsupported_run_target_type, "unknown"}} = RunTarget.parse(%{"type" => "unknown"})
    assert {:error, :missing_project_target} = RunTarget.parse(%{"type" => "project"})
    assert {:error, :missing_team_target} = RunTarget.parse(%{"type" => "team"})
    assert {:error, :missing_query_filter} = RunTarget.parse(%{"type" => "query"})
    assert {:error, :missing_issue_ids} = RunTarget.parse(%{"type" => "issues"})
  end

  test "repo marker helpers normalize supported shapes" do
    assert RunTarget.repo_markers(%RunTarget.RepoMarkers{
             labels: [" Symphony ", "SYMPHONY"],
             allowed_projects: [" repo-project ", "repo-project"]
           }) == %RunTarget.RepoMarkers{
             labels: ["symphony"],
             allowed_projects: ["repo-project"]
           }

    assert RunTarget.repo_markers(%{labels: nil, allowed_projects: nil}) == RunTarget.RepoMarkers.empty()
    assert RunTarget.repo_markers(nil) == RunTarget.RepoMarkers.empty()

    assert {:ok, %IssueMarkers{labels: [], allowed_projects: []}} =
             IssueMarkers.changeset(%IssueMarkers{}, %{labels: nil, allowed_projects: nil})
             |> Changeset.apply_action(:validate)

    assert {:ok, %IssueMarkers{labels: [], allowed_projects: []}} =
             IssueMarkers.changeset(%IssueMarkers{}, %{labels: [" "], allowed_projects: [nil]})
             |> Changeset.apply_action(:validate)
  end

  test "broad team and query targets require repo issue markers" do
    markers = RunTarget.RepoMarkers.empty()

    assert {:error, :run_target_requires_issue_markers} =
             RunTarget.validate_marker_safety(%RunTarget{tracker: "linear", type: :team, team_key: "SID"}, markers)

    assert {:error, :run_target_requires_issue_markers} =
             RunTarget.validate_marker_safety(
               %RunTarget{tracker: "linear", type: :query, filter: %{"priority" => %{"lte" => 2}}},
               markers
             )

    assert :ok =
             RunTarget.validate_marker_safety(
               %RunTarget{tracker: "linear", type: :project, project_slug: "repo-project"},
               markers
             )
  end

  test "marker safety intersects broad targets and keeps unmarked project targets intact" do
    matching = %Issue{
      id: "issue-1",
      identifier: "SID-1",
      title: "Repo issue",
      state: "Todo",
      labels: ["Symphony"],
      project_id: "project-id"
    }

    mismatch = %Issue{
      id: "issue-2",
      identifier: "SID-2",
      title: "Other issue",
      state: "Todo",
      labels: nil,
      project_slug: "other-project"
    }

    markers = %RunTarget.RepoMarkers{labels: ["symphony"], allowed_projects: ["project-id"]}
    query_target = %RunTarget{tracker: "linear", type: :query, filter: %{"priority" => %{"lte" => 2}}}

    assert %RunTarget.Resolution{issues: [^matching], warnings: [], ordering: :priority} =
             RunTarget.apply_marker_safety(query_target, [matching, mismatch], markers)

    project_target = %RunTarget{tracker: "linear", type: :project, project_slug: "repo-project"}

    assert %RunTarget.Resolution{issues: [^matching, ^mismatch], warnings: [], ordering: :priority} =
             RunTarget.apply_marker_safety(project_target, [matching, mismatch], RunTarget.RepoMarkers.empty())

    assert RunTarget.marker_match?(matching, markers)
    refute RunTarget.marker_match?(mismatch, markers)
    assert RunTarget.marker_match?(mismatch, RunTarget.RepoMarkers.empty())
  end

  test "explicit issue target keeps marker mismatches and returns warnings" do
    markers = %RunTarget.RepoMarkers{
      labels: ["symphony"],
      allowed_projects: ["repo-project"]
    }

    matching = %Issue{
      id: "issue-1",
      identifier: "SID-1",
      title: "Repo issue",
      state: "Todo",
      labels: ["Symphony"],
      project_slug: "repo-project"
    }

    mismatched = %Issue{
      id: "issue-2",
      identifier: "SID-2",
      title: "Other repo issue",
      state: "Todo",
      labels: ["other"],
      project_slug: "other-project"
    }

    target = %RunTarget{tracker: "linear", type: :issues, issue_ids: ["issue-1", "issue-2"]}

    assert %RunTarget.Resolution{issues: [^matching, ^mismatched], warnings: [warning]} =
             RunTarget.apply_marker_safety(target, [matching, mismatched], markers)

    assert warning.code == :repo_marker_mismatch
    assert warning.issue_id == "issue-2"
    assert warning.issue_identifier == "SID-2"
  end

  test "linear query filters compose target, state, and marker filters only when present" do
    empty_query = %RunTarget{tracker: "linear", type: :query, filter: %{}}
    markers = %RunTarget.RepoMarkers{labels: ["symphony"], allowed_projects: []}

    assert Filter.issue_filter(empty_query, [], RunTarget.RepoMarkers.empty()) == %{}

    assert Filter.issue_filter(empty_query, [" Todo ", " ", nil], RunTarget.RepoMarkers.empty()) == %{
             "state" => %{"name" => %{"in" => ["Todo"]}}
           }

    assert Filter.issue_filter(empty_query, [], markers) == %{
             "labels" => %{"name" => %{"in" => ["symphony"]}}
           }

    assert Filter.issue_filter(empty_query, ["Todo"], markers) == %{
             "and" => [
               %{"state" => %{"name" => %{"in" => ["Todo"]}}},
               %{"labels" => %{"name" => %{"in" => ["symphony"]}}}
             ]
           }

    project_markers = %RunTarget.RepoMarkers{labels: [], allowed_projects: ["repo-project"]}
    priority_query = %RunTarget{tracker: "linear", type: :query, filter: %{"priority" => %{"lte" => 2}}}

    assert Filter.issue_filter(priority_query, ["Todo"], project_markers) == %{
             "and" => [
               %{"priority" => %{"lte" => 2}},
               %{"state" => %{"name" => %{"in" => ["Todo"]}}},
               %{
                 "or" => [
                   %{"project" => %{"slugId" => %{"in" => ["repo-project"]}}},
                   %{"project" => %{"id" => %{"in" => ["repo-project"]}}}
                 ]
               }
             ]
           }

    project_target = %RunTarget{tracker: "linear", type: :project, project_slug: "repo-project"}
    assert Filter.issue_filter(project_target, ["Todo"], markers) == %{}
  end

  test "resolution ordering is target order only for explicit issue targets" do
    issue = %Issue{id: "issue-1", identifier: "SID-1", title: "Issue", state: "Todo"}

    assert %RunTarget.Resolution{ordering: :priority} =
             RunTarget.Resolution.new(
               %RunTarget{tracker: "linear", type: :project, project_slug: "repo-project"},
               [issue]
             )

    assert %RunTarget.Resolution{ordering: :target} =
             RunTarget.Resolution.new(
               %RunTarget{tracker: "linear", type: :issues, issue_ids: ["issue-1"]},
               [issue]
             )
  end

  test "memory tracker resolves explicit issue targets in requested order" do
    issue_1 = %Issue{id: "issue-1", identifier: "SID-1", title: "First", state: "Todo"}
    issue_2 = %Issue{id: "issue-2", identifier: "SID-2", title: "Second", state: "Todo"}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue_1, %{id: "ignored"}, issue_2])

    target = %RunTarget{tracker: "memory", type: :issues, issue_ids: ["issue-2", "issue-1"]}

    assert {:ok, %RunTarget.Resolution{issues: [^issue_2, ^issue_1], ordering: :target}} =
             Memory.resolve_candidate_issues(target)

    assert {:ok, [^issue_1, ^issue_2]} = Memory.fetch_candidate_issues()
  end
end
