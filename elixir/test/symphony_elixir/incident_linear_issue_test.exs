defmodule SymphonyElixir.IncidentLinearIssueTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias Mix.Tasks.Incident.LinearIssue, as: IncidentLinearIssueTask
  alias SymphonyElixir.IncidentLinearIssue

  defmodule FakeLinearClient do
    @moduledoc false

    def graphql(query, variables) do
      send(self(), {:linear_query, query, variables})

      case Process.get(:linear_responses, []) do
        [response | remaining] ->
          Process.put(:linear_responses, remaining)
          response

        [] ->
          raise "unexpected Linear GraphQL call"
      end
    end
  end

  @payload %{
    "title" => "Checkout deploy is returning 500s",
    "severity" => "critical",
    "affected_project" => "checkout-web",
    "signal_source" => "github_actions",
    "failing_signal" => "deploy smoke check returned HTTP 500",
    "source_id" => "run-123",
    "fingerprint" => "deploy-main-500",
    "source_payload" => %{
      "repository" => "acme/checkout",
      "workflow" => "Deploy",
      "run_id" => "123",
      "run_url" => "https://github.com/acme/checkout/actions/runs/123"
    },
    "evidence_links" => ["https://github.com/acme/checkout/actions/runs/123"],
    "reproduction" => "Open /checkout after deploy.",
    "diagnostics" => "Smoke test failed after release 2026.06.06.",
    "suggested_owner" => "web-platform",
    "suggested_validation" => "Rerun deploy smoke checks and verify /checkout returns 200.",
    "suggested_agent_route" => "ticket/production-incident"
  }
  @default_label_names ["incident", "production-failure", "source:github_actions", "severity:critical"]

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

  test "builds a bounded dry-run issue payload from a production failure signal" do
    assert {:ok, plan} = IncidentLinearIssue.plan(@payload)

    assert plan.title == "[critical] Checkout deploy is returning 500s"
    assert plan.target_project == "checkout-web"
    assert plan.target_team_key == nil
    assert plan.target_state == "Backlog"
    assert plan.priority == 1
    assert plan.labels == ["incident", "production-failure", "source:github_actions", "severity:critical"]
    assert plan.signal_source == "github_actions"
    assert plan.failing_signal == "deploy smoke check returned HTTP 500"
    assert plan.source_id == "run-123"
    assert plan.source_payload["workflow"] == "Deploy"
    assert plan.suggested_validation == "Rerun deploy smoke checks and verify /checkout returns 200."
    assert plan.dedupe.candidate_limit == 50
    assert plan.dedupe.correlation_key == "symphony-incident:github_actions:checkout-web:deploy-main-500"
    assert plan.dedupe.marker == "<!-- symphony-incident-correlation: a269320ade43d8a7 -->"

    assert plan.body =~ "## Production Failure Signal"
    assert plan.body =~ "- Severity: critical"
    assert plan.body =~ "- Linear priority: P1 urgent"
    assert plan.body =~ "- Affected project: checkout-web"
    assert plan.body =~ "- Monitor source: github_actions"
    assert plan.body =~ "- Failing signal: deploy smoke check returned HTTP 500"
    assert plan.body =~ "- Suggested owner: web-platform"
    assert plan.body =~ "- Suggested agent route: ticket/production-incident"
    assert plan.body =~ "## Source Evidence"
    assert plan.body =~ "- repository: acme/checkout"
    assert plan.body =~ "## Suggested Validation"
    assert plan.body =~ "Rerun deploy smoke checks and verify /checkout returns 200."
    assert plan.body =~ "https://github.com/acme/checkout/actions/runs/123"
    assert plan.body =~ "This issue was generated from a project-specific monitoring signal."
    assert plan.body =~ "It is not a universal Symphony runtime assumption"
  end

  test "lists the supported first signal sources" do
    assert IncidentLinearIssue.supported_sources() == [
             "github_actions",
             "sentry",
             "posthog",
             "project_webhook"
           ]

    assert IncidentLinearIssue.source_payload_required_fields() == %{
             "github_actions" => ["repository", "workflow", "run_id", "run_url"],
             "sentry" => ["organization", "project", "issue_url", "event_id"],
             "posthog" => ["project", "alert_name", "alert_url", "metric"],
             "project_webhook" => ["webhook_name", "event_id", "event_url"]
           }
  end

  test "normalizes atom-key payloads with custom labels, team routing, and source-id correlation fallback" do
    payload =
      @payload
      |> Map.delete("fingerprint")
      |> Map.put("team_key", " WEB ")
      |> Map.new(fn {key, value} -> {String.to_atom(key), value} end)

    assert {:ok, plan} =
             IncidentLinearIssue.plan(payload,
               target_state: "Todo",
               labels: [" Incident ", "", "Ops"],
               candidate_limit: 7
             )

    assert plan.target_state == "Todo"
    assert plan.target_team_key == "WEB"
    assert plan.source_id == "run-123"
    assert plan.labels == ["incident", "ops", "source:github_actions", "severity:critical"]
    assert plan.dedupe.candidate_limit == 7
    assert plan.dedupe.correlation_key == "symphony-incident:github_actions:checkout-web:run-123"
  end

  test "falls back to normalized title correlation and source-id body placeholder" do
    payload =
      @payload
      |> Map.put("fingerprint", " ")
      |> Map.delete("source_id")

    assert {:ok, plan} = IncidentLinearIssue.plan(payload)

    assert plan.dedupe.correlation_key ==
             "symphony-incident:github_actions:checkout-web:checkout deploy is returning 500s"

    assert plan.body =~ "- Source ID: not provided"
  end

  test "maps medium and low severities to Linear priority labels and preserves extra source evidence" do
    assert {:ok, medium_plan} =
             IncidentLinearIssue.plan(%{
               @payload
               | "severity" => "medium",
                 "source_payload" => Map.put(@payload["source_payload"], "environment", "production")
             })

    assert medium_plan.priority == 3
    assert IncidentLinearIssue.format_dry_run(medium_plan) =~ "Linear priority: P3 medium"
    assert medium_plan.body =~ "- environment: production"

    assert {:ok, low_plan} = IncidentLinearIssue.plan(%{@payload | "severity" => "low"})
    assert low_plan.priority == 4
    assert IncidentLinearIssue.format_dry_run(low_plan) =~ "Linear priority: P4 low"
  end

  test "validates optional identity fields and keeps candidate scans bounded" do
    assert {:error, {:invalid_optional_field, "source_id"}} =
             IncidentLinearIssue.plan(%{@payload | "source_id" => %{"id" => "run-123"}})

    assert {:error, {:invalid_optional_field, "fingerprint"}} =
             IncidentLinearIssue.plan(%{@payload | "fingerprint" => 123})

    assert {:error, {:invalid_optional_field, "team_key"}} =
             IncidentLinearIssue.plan(Map.put(@payload, "team_key", 123))

    assert {:error, {:invalid_candidate_limit, 0, 50}} =
             IncidentLinearIssue.plan(@payload, candidate_limit: 0)

    assert {:error, {:invalid_candidate_limit, "50", 50}} =
             IncidentLinearIssue.plan(@payload, candidate_limit: "50")

    assert {:ok, plan} = IncidentLinearIssue.plan(@payload, candidate_limit: 500)
    assert plan.dedupe.candidate_limit == 50

    assert {:ok, plan} =
             IncidentLinearIssue.plan(%{@payload | "source_id" => nil, "fingerprint" => nil})

    assert plan.source_id == nil
    assert plan.body =~ "- Source ID: not provided"
  end

  test "requires the minimal signal contract before issue planning" do
    payload = Map.delete(@payload, "affected_project")

    assert {:error, {:missing_required_fields, ["affected_project"]}} =
             IncidentLinearIssue.plan(payload)

    assert {:error, {:missing_required_fields, ["source_payload"]}} =
             @payload
             |> Map.delete("source_payload")
             |> IncidentLinearIssue.plan()
  end

  test "requires text contract fields to stay strings and target state to stay bounded" do
    assert {:error, {:missing_required_fields, ["title"]}} =
             IncidentLinearIssue.plan(%{@payload | "title" => nil})

    assert {:error, {:invalid_required_fields, ["title"]}} =
             IncidentLinearIssue.plan(%{@payload | "title" => 123})

    assert {:error, {:missing_required_fields, ["suggested_validation"]}} =
             IncidentLinearIssue.plan(%{@payload | "suggested_validation" => " "})

    assert {:error, {:invalid_required_fields, ["failing_signal"]}} =
             IncidentLinearIssue.plan(%{@payload | "failing_signal" => 500})

    assert {:error, {:unsupported_target_state, "Done", ["Backlog", "Todo"]}} =
             IncidentLinearIssue.plan(@payload, target_state: "Done")

    assert {:error, {:unsupported_target_state, :done, ["Backlog", "Todo"]}} =
             IncidentLinearIssue.plan(@payload, target_state: :done)
  end

  test "rejects unsupported severities, sources, and missing evidence" do
    assert {:error, {:unsupported_severity, "urgent", ["critical", "high", "medium", "low"]}} =
             IncidentLinearIssue.plan(%{@payload | "severity" => "urgent"})

    assert {:error, {:unsupported_severity, 1, ["critical", "high", "medium", "low"]}} =
             IncidentLinearIssue.plan(%{@payload | "severity" => 1})

    assert {:error, {:unsupported_signal_source, "pagerduty", sources}} =
             IncidentLinearIssue.plan(%{@payload | "signal_source" => "pagerduty"})

    assert "github_actions" in sources

    assert {:error, {:unsupported_signal_source, 1, sources}} =
             IncidentLinearIssue.plan(%{@payload | "signal_source" => 1})

    assert "sentry" in sources

    assert {:error, :missing_evidence_links} =
             IncidentLinearIssue.plan(%{@payload | "evidence_links" => [" ", ""]})

    assert {:error, :missing_evidence_links} =
             IncidentLinearIssue.plan(%{@payload | "evidence_links" => "https://example.test"})

    assert {:error, {:invalid_evidence_links, [1]}} =
             IncidentLinearIssue.plan(%{@payload | "evidence_links" => ["https://example.test", %{"url" => "bad"}]})
  end

  test "rejects malformed source-specific evidence payloads" do
    assert {:error, {:missing_source_payload_fields, "github_actions", ["run_url"]}} =
             IncidentLinearIssue.plan(%{
               @payload
               | "source_payload" => Map.delete(@payload["source_payload"], "run_url")
             })

    assert {:error, {:invalid_source_payload_fields, "github_actions", ["run_id"]}} =
             IncidentLinearIssue.plan(%{
               @payload
               | "source_payload" => Map.put(@payload["source_payload"], "run_id", 123)
             })

    assert {:error, {:invalid_source_payload, "github_actions", ["repository", "workflow", "run_id", "run_url"]}} =
             IncidentLinearIssue.plan(%{@payload | "source_payload" => []})

    assert {:ok, plan} =
             IncidentLinearIssue.plan(%{
               @payload
               | "signal_source" => "sentry",
                 "source_payload" => %{
                   "organization" => "acme",
                   "project" => "checkout-web",
                   "issue_url" => "https://sentry.test/issues/1",
                   "event_id" => "event-1"
                 }
             })

    assert plan.body =~ "- issue_url: https://sentry.test/issues/1"
  end

  test "detects duplicates by bounded correlation marker scans" do
    assert {:ok, plan} = IncidentLinearIssue.plan(@payload)

    candidates = [
      %{"identifier" => "SID-1", "description" => "unrelated", "url" => "https://linear.app/unrelated"},
      %{
        "identifier" => "SID-2",
        "description" => "Prior issue\n\n#{plan.dedupe.marker}",
        "url" => "https://linear.app/matching",
        "state" => %{"name" => "Backlog"}
      }
    ]

    assert {:duplicate, duplicate} = IncidentLinearIssue.find_duplicate(plan, candidates)
    assert duplicate.identifier == "SID-2"
    assert duplicate.url == "https://linear.app/matching"
    assert duplicate.state == "Backlog"
  end

  test "ignores terminal incidents when checking duplicate markers" do
    assert {:ok, plan} = IncidentLinearIssue.plan(@payload)

    assert :none =
             IncidentLinearIssue.find_duplicate(plan, [
               %{
                 "identifier" => "SID-2",
                 "description" => "Prior issue\n\n#{plan.dedupe.marker}",
                 "state" => %{"name" => "Done", "type" => "completed"}
               },
               %{
                 "identifier" => "SID-3",
                 "description" => "Prior canceled issue\n\n#{plan.dedupe.marker}",
                 "state" => "Canceled"
               }
             ])
  end

  test "returns none when no candidate contains the correlation marker" do
    assert {:ok, plan} = IncidentLinearIssue.plan(@payload)

    assert :none =
             IncidentLinearIssue.find_duplicate(plan, [
               %{description: nil, state: "Backlog"},
               %{description: "unrelated", state: %{name: "Todo"}}
             ])
  end

  test "keeps duplicate state strings when candidates are already normalized" do
    assert {:ok, plan} = IncidentLinearIssue.plan(@payload)

    assert {:duplicate, duplicate} =
             IncidentLinearIssue.find_duplicate(plan, [
               %{description: plan.dedupe.marker, state: "Backlog"}
             ])

    assert duplicate.state == "Backlog"
  end

  test "refuses create mode without explicit project opt-in" do
    assert {:error, :project_opt_in_required} = IncidentLinearIssue.create(@payload)
  end

  test "create mode suppresses duplicates before target resolution" do
    assert {:ok, plan} = IncidentLinearIssue.plan(@payload)

    responses = [
      recent_response([
        %{
          "identifier" => "SID-100",
          "description" => "Prior incident\n\n#{plan.dedupe.marker}",
          "url" => "https://linear.app/example/issue/SID-100",
          "state" => %{"name" => "Backlog"}
        }
      ])
    ]

    assert {:duplicate, duplicate} = create_with_responses(responses)
    assert duplicate.identifier == "SID-100"
    assert duplicate.url == "https://linear.app/example/issue/SID-100"

    assert_receive {:linear_query, recent_query, %{projectSlug: "checkout-web", first: 50}}
    assert recent_query =~ "orderBy: updatedAt"
    refute_receive {:linear_query, _query, _variables}
  end

  test "create mode treats terminal duplicate markers as stale" do
    assert {:ok, plan} = IncidentLinearIssue.plan(@payload)

    responses = [
      recent_response([
        %{
          "identifier" => "SID-100",
          "description" => "Prior incident\n\n#{plan.dedupe.marker}",
          "url" => "https://linear.app/example/issue/SID-100",
          "state" => %{"name" => "Done", "type" => "completed"}
        }
      ]),
      project_response([team_response()]),
      labels_response(@default_label_names),
      create_response(%{
        "id" => "issue-created",
        "identifier" => "SID-303",
        "title" => "[critical] Checkout deploy is returning 500s",
        "url" => "https://linear.app/example/issue/SID-303"
      })
    ]

    assert {:ok, %{"identifier" => "SID-303"}} = create_with_responses(responses)

    assert_receive {:linear_query, _recent_query, %{projectSlug: "checkout-web", first: 50}}
    assert_receive {:linear_query, _target_query, %{projectSlug: "checkout-web"}}
    assert_receive {:linear_query, _labels_query, %{teamId: "team-checkout"}}
    assert_receive {:linear_query, _create_mutation, %{input: %{title: "[critical] Checkout deploy is returning 500s"}}}
  end

  test "create mode rejects payload projects outside the selected workflow scope" do
    payload = %{@payload | "affected_project" => "billing-api"}

    assert {:error, {:incident_project_scope_mismatch, "billing-api", "checkout-web"}} =
             create_with_responses([], payload: payload, tracker_project_slug: "checkout-web")

    refute_receive {:linear_query, _query, _variables}
  end

  test "create mode builds the Linear mutation payload after resolving project state and labels" do
    responses = [
      recent_response([]),
      project_response([team_response()]),
      labels_response(@default_label_names),
      create_response(%{
        "id" => "issue-created",
        "identifier" => "SID-301",
        "title" => "[critical] Checkout deploy is returning 500s",
        "url" => "https://linear.app/example/issue/SID-301"
      })
    ]

    assert {:ok, %{"identifier" => "SID-301"}} = create_with_responses(responses)

    assert_receive {:linear_query, recent_query, %{projectSlug: "checkout-web", first: 50}}
    assert recent_query =~ "orderBy: updatedAt"
    assert_receive {:linear_query, _target_query, %{projectSlug: "checkout-web"}}
    assert_receive {:linear_query, _labels_query, %{teamId: "team-checkout", names: @default_label_names, first: 4}}
    assert_receive {:linear_query, _create_mutation, %{input: input}}

    assert input.teamId == "team-checkout"
    assert input.projectId == "project-checkout"
    assert input.stateId == "state-backlog"
    assert input.labelIds == ["label-incident", "label-production-failure", "label-source-github-actions", "label-severity-critical"]
    assert input.priority == 1
    assert input.title == "[critical] Checkout deploy is returning 500s"
    assert input.description =~ "<!-- symphony-incident-correlation: a269320ade43d8a7 -->"
    assert input.description =~ "## Suggested Validation"
  end

  test "create mode routes high-priority production failures to the requested team and active state" do
    payload =
      @payload
      |> Map.put("severity", "high")
      |> Map.put("team_key", "WEB")

    responses = [
      recent_response([]),
      project_response([
        team_response(id: "team-checkout", key: "CHK"),
        team_response(id: "team-web", key: "WEB", states: [state_response("Todo", "unstarted", "state-web-todo")])
      ]),
      labels_response(["incident", "production-failure", "source:github_actions", "severity:high"]),
      create_response(%{
        "id" => "issue-created",
        "identifier" => "SID-302",
        "title" => "[high] Checkout deploy is returning 500s",
        "url" => "https://linear.app/example/issue/SID-302"
      })
    ]

    assert {:ok, %{"identifier" => "SID-302"}} =
             create_with_responses(responses, payload: payload, target_state: "Todo")

    assert_receive {:linear_query, _recent_query, %{projectSlug: "checkout-web", first: 50}}
    assert_receive {:linear_query, _target_query, %{projectSlug: "checkout-web"}}
    assert_receive {:linear_query, _labels_query, %{teamId: "team-web", names: label_names, first: 4}}
    assert label_names == ["incident", "production-failure", "source:github_actions", "severity:high"]
    assert_receive {:linear_query, _create_mutation, %{input: input}}

    assert input.teamId == "team-web"
    assert input.projectId == "project-checkout"
    assert input.stateId == "state-web-todo"
    assert input.priority == 2
    assert input.title == "[high] Checkout deploy is returning 500s"
    assert input.description =~ "- Target team: WEB"
    assert input.description =~ "- Linear priority: P2 high"
  end

  test "create mode rejects unsafe or incomplete Linear metadata" do
    assert {:error, {:ambiguous_project_teams, "checkout-web"}} =
             create_with_responses([
               recent_response([]),
               project_response([team_response(), team_response(id: "team-second", key: "SEC")])
             ])

    assert {:error, {:target_state_not_found, "Backlog"}} =
             create_with_responses([
               recent_response([]),
               project_response([team_response(states: [state_response("Todo", "unstarted", "state-todo")])])
             ])

    assert {:error, {:target_state_not_allowed, "Backlog", "completed"}} =
             create_with_responses([
               recent_response([]),
               project_response([team_response(states: [state_response("Backlog", "completed", "state-backlog")])])
             ])

    assert {:error, {:missing_linear_labels, ["production-failure", "source:github_actions", "severity:critical"]}} =
             create_with_responses([
               recent_response([]),
               project_response([team_response()]),
               labels_response(["incident"])
             ])

    assert {:error, {:target_team_not_found, "WEB", "checkout-web"}} =
             create_with_responses(
               [
                 recent_response([]),
                 project_response([team_response(key: "CHK")])
               ],
               payload: Map.put(@payload, "team_key", "WEB")
             )
  end

  test "create mode surfaces Linear GraphQL errors before partial data" do
    errors = [%{"message" => "partial failure"}]

    assert {:error, {:linear_graphql_errors, ^errors}} =
             create_with_responses([with_errors(recent_response([]), errors)])

    assert {:error, {:linear_graphql_errors, ^errors}} =
             create_with_responses([
               recent_response([]),
               with_errors(project_response([team_response()]), errors)
             ])

    assert {:error, {:linear_graphql_errors, ^errors}} =
             create_with_responses([
               recent_response([]),
               project_response([team_response()]),
               with_errors(labels_response(@default_label_names), errors)
             ])

    assert {:error, {:linear_graphql_errors, ^errors}} =
             create_with_responses([
               recent_response([]),
               project_response([team_response()]),
               labels_response(@default_label_names),
               with_errors(
                 create_response(%{
                   "id" => "issue-created",
                   "identifier" => "SID-304",
                   "title" => "[critical] Checkout deploy is returning 500s",
                   "url" => "https://linear.app/example/issue/SID-304"
                 }),
                 errors
               )
             ])
  end

  @tag :tmp_dir
  test "mix task dry-runs a fake signal payload for manual issue-body inspection", %{tmp_dir: tmp_dir} do
    payload_path = Path.join(tmp_dir, "incident.json")
    File.write!(payload_path, Jason.encode!(@payload))

    output =
      capture_io(fn ->
        IncidentLinearIssueTask.run(["--payload", payload_path])
      end)

    assert output =~ "DRY RUN: no Linear issue was created"
    assert output =~ "Target state: Backlog"
    assert output =~ "Linear priority: P1 urgent"
    assert output =~ "Labels: incident, production-failure, source:github_actions, severity:critical"
    assert output =~ "<!-- symphony-incident-correlation: a269320ade43d8a7 -->"
    assert output =~ "## Production Failure Signal"
    assert output =~ "## Source Evidence"
    assert output =~ "- workflow: Deploy"
    assert output =~ "## Suggested Validation"
    assert output =~ "Manual inspection: review the issue body below before using --create"
  end

  @tag :tmp_dir
  test "mix task create mode uses the configured local runtime setup", %{tmp_dir: tmp_dir} do
    payload_path = Path.join(tmp_dir, "incident.json")
    File.write!(payload_path, Jason.encode!(@payload))
    runtime_setup_path = Path.join(tmp_dir, "symphony.runtime.yml")
    write_workflow_file!(runtime_setup_path, tracker_project_slug: "checkout-web")
    Workflow.set_workflow_file_path(runtime_setup_path)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    responses = [
      recent_response([]),
      project_response([team_response()]),
      labels_response(@default_label_names),
      create_response(%{
        "id" => "issue-created",
        "identifier" => "SID-301",
        "title" => "[critical] Checkout deploy is returning 500s",
        "url" => "https://linear.app/example/issue/SID-301"
      })
    ]

    output =
      File.cd!(tmp_dir, fn ->
        with_linear_responses(responses, fn ->
          capture_io(fn ->
            IncidentLinearIssueTask.run([
              "--payload",
              payload_path,
              "--workflow",
              runtime_setup_path,
              "--create",
              "--acknowledge-project-opt-in"
            ])
          end)
        end)
      end)

    assert output =~ "Created Linear issue: SID-301 https://linear.app/example/issue/SID-301"
    assert Workflow.workflow_file_path() == runtime_setup_path
  end

  defp create_with_responses(responses, opts \\ []) do
    payload = Keyword.get(opts, :payload, @payload)
    tracker_project_slug = Keyword.get(opts, :tracker_project_slug, payload_project_slug(payload))
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: tracker_project_slug)

    create_opts = Keyword.merge([project_opt_in: true, client: FakeLinearClient], opts)
    create_opts = Keyword.drop(create_opts, [:payload, :tracker_project_slug])

    with_linear_responses(responses, fn ->
      IncidentLinearIssue.create(payload, create_opts)
    end)
  end

  defp payload_project_slug(payload) do
    Map.get(payload, "affected_project") || Map.get(payload, :affected_project)
  end

  defp with_linear_responses(responses, fun) do
    Process.put(:linear_responses, responses)

    try do
      fun.()
    after
      Process.delete(:linear_responses)
    end
  end

  defp recent_response(nodes) do
    {:ok, %{"data" => %{"issues" => %{"nodes" => nodes}}}}
  end

  defp project_response(teams) do
    {:ok,
     %{
       "data" => %{
         "projects" => %{
           "nodes" => [
             %{
               "id" => "project-checkout",
               "name" => "Checkout",
               "slugId" => "checkout-web",
               "teams" => %{"nodes" => teams}
             }
           ]
         }
       }
     }}
  end

  defp team_response(opts \\ []) do
    states =
      Keyword.get(opts, :states, [
        state_response("Backlog", "backlog", "state-backlog"),
        state_response("Todo", "unstarted", "state-todo")
      ])

    %{
      "id" => Keyword.get(opts, :id, "team-checkout"),
      "key" => Keyword.get(opts, :key, "CHK"),
      "name" => Keyword.get(opts, :name, "Checkout"),
      "states" => %{"nodes" => states}
    }
  end

  defp state_response(name, type, id), do: %{"id" => id, "name" => name, "type" => type}

  defp labels_response(names) do
    nodes =
      Enum.map(names, fn name ->
        %{"id" => "label-" <> String.replace(name, [":", "_"], "-"), "name" => name}
      end)

    {:ok, %{"data" => %{"issueLabels" => %{"nodes" => nodes}}}}
  end

  defp create_response(issue) do
    {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}}
  end

  defp with_errors({:ok, body}, errors) do
    {:ok, Map.put(body, "errors", errors)}
  end
end
