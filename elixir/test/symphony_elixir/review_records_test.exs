defmodule SymphonyElixir.ReviewRecordsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HandoffRoute
  alias SymphonyElixir.ReviewRecords

  test "writes deterministic quality-gate record files with immutable findings and mutable dispositions" do
    logs_root = tmp_root!("review-records-write")
    workspace = tmp_root!("review-records-workspace")

    on_exit(fn ->
      File.rm_rf(logs_root)
      File.rm_rf(workspace)
    end)

    File.mkdir_p!(Path.join(workspace, "lib"))

    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "quality_gates", status: :passed}],
        review: %{status: :clean},
        changed_surfaces: [:workflow],
        policy: %{auto_land: %{enabled: false}}
      })

    assert {:ok, %{record_dir: record_dir, files: files}} =
             ReviewRecords.write_quality_gate_run(%{
               logs_root: logs_root,
               project: %{
                 slug: "symphony",
                 name: "Symphony",
                 repository: "https://github.com/apontarelli/symphony"
               },
               issue: %{
                 id: "issue-320",
                 identifier: "SID-320",
                 title: "Persist quality-gate records",
                 url: "https://linear.app/example/issue/SID-320/example"
               },
               workflow: %{profile: "default", policy_ref: "640c639998cf", target: "main"},
               run: %{
                 id: "session/abc:123",
                 session_id: "session/abc:123",
                 started_at: "2026-06-11T16:00:00Z",
                 completed_at: "2026-06-11T16:05:00Z"
               },
               quality_gate: quality_gate_fixture(workspace),
               handoff_route: decision
             })

    assert record_dir ==
             Path.join([
               logs_root,
               "review-records",
               "quality-gates",
               "symphony",
               "SID-320",
               "session-abc-123"
             ])

    assert Map.keys(files) |> Enum.sort() ==
             [:disposition, :findings, :handoff_route, :metadata, :quality_gate]

    for file <- Map.values(files), do: assert(File.regular?(file))

    metadata = read_json!(files.metadata)
    quality_gate = read_json!(files.quality_gate)
    findings = read_json!(files.findings)
    disposition = read_json!(files.disposition)
    handoff_route = read_json!(files.handoff_route)

    assert metadata["schema"] == "symphony.quality_gate_review_record.metadata.v1"
    assert metadata["record_type"] == "symphony_quality_gate"
    assert metadata["project"]["slug"] == "symphony"
    assert metadata["issue"]["identifier"] == "SID-320"
    assert metadata["workflow"]["policy_ref"] == "640c639998cf"
    assert metadata["run"]["id"] == "session-abc-123"
    assert metadata["changed_files"] == ["lib/source.ex", "test/source_test.exs", "README.md"]
    assert metadata["artifact_paths"]["findings"] == "findings.json"
    refute inspect(metadata) =~ workspace

    assert quality_gate["schema"] == "symphony.quality_gate_review_record.quality_gate.v1"
    assert quality_gate["status"] == "passed"

    assert Enum.map(quality_gate["executed_jobs"], & &1["category"]) == [
             "test_quality",
             "docs_source_of_truth",
             "security_data_migration"
           ]

    assert [%{"category" => "scenario_qa"}] = quality_gate["blocked_jobs"]
    assert [%{"category" => "product_visual_review"}] = quality_gate["skipped_jobs"]
    assert [%{"attempt" => 1, "status" => "passed"}] = quality_gate["repair_passes"]
    refute inspect(quality_gate) =~ workspace

    assert findings["schema"] == "symphony.quality_gate_review_record.findings.v1"

    assert Enum.map(findings["findings"], & &1["category"]) == [
             "test_quality",
             "docs_source_of_truth",
             "security_data_migration",
             "scenario_qa",
             "product_visual_review"
           ]

    assert Enum.all?(findings["findings"], &String.starts_with?(&1["id"], "QG-"))
    assert Enum.find(findings["findings"], &(&1["category"] == "test_quality"))["repair"]
    assert Enum.find(findings["findings"], &(&1["category"] == "scenario_qa"))["recommended_disposition"] == "human_input_required"
    refute inspect(findings) =~ workspace

    assert disposition["schema"] == "symphony.quality_gate_review_record.disposition.v1"

    statuses =
      disposition["dispositions"]
      |> Map.new(fn entry -> {entry["category"], entry["status"]} end)

    assert statuses == %{
             "test_quality" => "fixed",
             "docs_source_of_truth" => "deferred_followup",
             "security_data_migration" => "rejected_false_positive",
             "scenario_qa" => "needs_user_decision",
             "product_visual_review" => "no_action"
           }

    assert handoff_route["schema"] == "symphony.quality_gate_review_record.handoff_route.v1"
    assert handoff_route["route"]["target_state"] == "Human Review"
  end

  test "does not overwrite immutable findings or existing disposition sidecar" do
    logs_root = tmp_root!("review-records-immutable")

    on_exit(fn -> File.rm_rf(logs_root) end)

    assert {:ok, %{files: files}} =
             ReviewRecords.write_quality_gate_run(minimal_record(logs_root, "SID-320", "run-1"))

    compatibility_findings = Path.join([logs_root, "review-records", "review", "symphony", "run-1", "findings.json"])
    compatibility_disposition = Path.join([logs_root, "review-records", "review", "symphony", "run-1", "disposition.json"])

    File.write!(files.findings, ~s({"schema":"custom.findings","findings":[]}))
    File.write!(files.disposition, ~s({"schema":"custom.disposition","dispositions":[]}))
    File.write!(compatibility_findings, ~s({"schema":"custom.review.findings","findings":[]}))
    File.write!(compatibility_disposition, ~s({"schema":"custom.review.disposition","dispositions":[{"finding_id":"QG-1","status":"fixed","rationale":"operator decision"}]}))

    assert {:ok, %{files: ^files}} =
             ReviewRecords.write_quality_gate_run(minimal_record(logs_root, "SID-320", "run-1"))

    assert read_json!(files.findings)["schema"] == "custom.findings"
    assert read_json!(files.disposition)["schema"] == "custom.disposition"
    assert read_json!(compatibility_findings)["schema"] == "custom.review.findings"
    assert [%{"status" => "fixed", "rationale" => "operator decision"}] = read_json!(compatibility_disposition)["dispositions"]
  end

  test "uses manifest repo slug before tracker project slug for review compatibility records" do
    logs_root = tmp_root!("review-records-repo-key")

    on_exit(fn -> File.rm_rf(logs_root) end)

    params =
      logs_root
      |> minimal_record("SID-320", "run-repo-key")
      |> Map.delete(:project)
      |> Map.put(:policy, %{
        "manifest" => %{"project" => %{"slug" => "symphony"}},
        "policy_metadata" => %{"project_slug" => "make-symphony-runner-agnostic-09b8dc46fe82"}
      })

    assert {:ok, _record} = ReviewRecords.write_quality_gate_run(params)

    assert File.regular?(Path.join([logs_root, "review-records", "review", "symphony", "run-repo-key", "metadata.json"]))
    refute File.exists?(Path.join([logs_root, "review-records", "review", "make-symphony-runner-agnostic-09b8dc46fe82", "run-repo-key"]))
  end

  test "ignores malformed repair rerun categories without crashing record writes" do
    logs_root = tmp_root!("review-records-malformed-repair")

    on_exit(fn -> File.rm_rf(logs_root) end)

    record =
      minimal_record(logs_root, "SID-320", "run-malformed-repair")
      |> put_in([:quality_gate, :repair_passes], [
        %{attempt: 1, status: :passed, rerun_categories: :test_quality, rerun_jobs: []}
      ])

    assert {:ok, %{files: files}} = ReviewRecords.write_quality_gate_run(record)

    findings = read_json!(files.findings)
    disposition = read_json!(files.disposition)

    refute Enum.find(findings["findings"], &(&1["category"] == "test_quality"))["repair"]
    assert [%{"category" => "test_quality", "status" => "accepted"}] = disposition["dispositions"]
  end

  test "persists findings with the same normalization rules as quality-gate synthesis" do
    logs_root = tmp_root!("review-records-synthesis-normalization")

    on_exit(fn -> File.rm_rf(logs_root) end)

    record =
      minimal_record(logs_root, "SID-320", "run-synthesis")
      |> put_in([:quality_gate, :status], :fix_required)
      |> put_in([:quality_gate, :jobs], [
        %{
          id: "test_quality:initial",
          category: :test_quality,
          status: :fix_required,
          execution: :executed,
          phase: :initial,
          findings: [],
          summary: "Reviewer marked this fix-required without structured findings."
        },
        %{
          id: "docs_source_of_truth:initial",
          category: :docs_source_of_truth,
          status: :passed,
          execution: :executed,
          phase: :initial,
          findings: [
            %{
              category: :unknown_category,
              severity: :not_a_severity,
              evidence: "Reviewer returned an unsupported disposition token.",
              recommended_disposition: :needs_input
            }
          ]
        }
      ])
      |> put_in([:quality_gate, :repair_passes], [])

    assert {:ok, %{files: files}} = ReviewRecords.write_quality_gate_run(record)

    findings = read_json!(files.findings)["findings"]
    disposition = read_json!(files.disposition)["dispositions"]

    assert %{
             "category" => "test_quality",
             "recommended_disposition" => "fix_required",
             "evidence" => "Reviewer marked this fix-required without structured findings."
           } = Enum.find(findings, &(&1["category"] == "test_quality"))

    assert %{
             "category" => "docs_source_of_truth",
             "severity" => "major",
             "recommended_disposition" => "human_input_required"
           } = Enum.find(findings, &(&1["source_job"] == "docs_source_of_truth:initial"))

    assert %{"category" => "test_quality", "status" => "accepted"} =
             Enum.find(disposition, &(&1["category"] == "test_quality"))

    assert %{"category" => "docs_source_of_truth", "status" => "needs_user_decision"} =
             Enum.find(disposition, &(&1["category"] == "docs_source_of_truth"))
  end

  test "lists, shows, and exports grouped retrospective input" do
    logs_root = tmp_root!("review-records-read")

    on_exit(fn -> File.rm_rf(logs_root) end)

    assert {:ok, first} = ReviewRecords.write_quality_gate_run(minimal_record(logs_root, "SID-320", "run-1"))
    assert {:ok, second} = ReviewRecords.write_quality_gate_run(minimal_record(logs_root, "SID-321", "run-2"))

    assert {:ok, [latest, older]} = ReviewRecords.list(logs_root, limit: 10)
    assert latest.run_id == "run-2"
    assert latest.issue_identifier == "SID-321"
    assert latest.record_path == "quality-gates/symphony/SID-321/run-2"
    assert older.run_id == "run-1"

    assert {:ok, record} = ReviewRecords.show(logs_root, "run-1")
    assert record.metadata["issue"]["identifier"] == "SID-320"
    assert record.record_dir == first.record_dir

    assert {:ok, export} = ReviewRecords.export(logs_root, format: :json)
    assert export["schema"] == "symphony.review_retrospective_input.v1"
    assert export["record_count"] == 2
    assert export["review_retrospective_compatibility"]["artifact_root"] == "review-records"
    assert export["review_retrospective_compatibility"]["review_path"] == "review/<project-slug>/<run-id>"
    assert export["review_retrospective_compatibility"]["legacy_repair_source_path"] == "parallel-review/<project-slug>/<run-id>"
    refute Map.has_key?(export["review_retrospective_compatibility"], "parallel_review_path")
    assert hd(export["records"])["record_path"] == "quality-gates/symphony/SID-321/run-2"
    assert Map.has_key?(export["groups"]["by_category"], "test_quality")
    assert Map.has_key?(export["groups"]["by_disposition"], "fixed")
    assert Map.has_key?(export["groups"]["by_surface"], "lib/source.ex")
    assert export["groups"]["follow_up_candidates"] == []

    assert {:ok, markdown} = ReviewRecords.export(logs_root, format: :markdown)
    assert markdown =~ "# Symphony Quality-Gate Retrospective Input"
    assert markdown =~ "## By Category"
    assert markdown =~ "test_quality"

    assert {:ok, since_last} = ReviewRecords.export(logs_root, format: :json, since: :last)
    assert since_last["record_count"] == 1
    assert hd(since_last["records"])["run_id"] == "run-2"

    assert File.regular?(Path.join([logs_root, "review-records", "review", "symphony", "run-1", "findings.json"]))
    assert File.regular?(Path.join([logs_root, "review-records", "review", "symphony", "run-2", "disposition.json"]))
    refute File.exists?(Path.join([logs_root, "review-records", "parallel-review", "symphony", "run-1"]))

    retrospective_metadata = read_json!(Path.join([logs_root, "review-records", "review", "symphony", "run-1", "metadata.json"]))
    assert retrospective_metadata["schema"] == "review.metadata.v1"
    assert retrospective_metadata["original_repo_key"] == "symphony"
    assert retrospective_metadata["provenance"]["source_record_path"] == "quality-gates/symphony/SID-320/run-1"
    assert File.dir?(Path.dirname(second.files.metadata))
  end

  test "review compatibility sidecar maps native no-action dispositions" do
    logs_root = tmp_root!("review-records-compatibility-disposition")
    workspace = tmp_root!("review-records-compatibility-workspace")

    on_exit(fn ->
      File.rm_rf(logs_root)
      File.rm_rf(workspace)
    end)

    assert {:ok, %{files: files}} =
             ReviewRecords.write_quality_gate_run(%{
               logs_root: logs_root,
               project: %{slug: "symphony"},
               issue: %{id: "issue-320", identifier: "SID-320"},
               workflow: %{profile: "default", policy_ref: "640c639998cf", target: "main"},
               run: %{id: "run-compatibility", session_id: "run-compatibility", completed_at: "2026-06-11T16:05:00Z"},
               quality_gate: quality_gate_fixture(workspace),
               handoff_route: %{route: "human_review", target_state: "Human Review", summary: "Ready for review."}
             })

    assert Enum.any?(read_json!(files.disposition)["dispositions"], &(&1["status"] == "no_action"))

    compatibility_disposition =
      [logs_root, "review-records", "review", "symphony", "run-compatibility", "disposition.json"]
      |> Path.join()
      |> read_json!()

    statuses = Enum.map(compatibility_disposition["dispositions"], & &1["status"])

    refute "no_action" in statuses
    assert "out_of_scope" in statuses

    no_action_entry =
      Enum.find(compatibility_disposition["dispositions"], &(&1["native_status"] == "no_action"))

    assert no_action_entry["status"] == "out_of_scope"
    assert no_action_entry["rationale"] =~ "Native Symphony disposition no_action"
  end

  test "backfills legacy parallel-review records into canonical review records once with provenance" do
    logs_root = tmp_root!("review-records-backfill")
    legacy_dir = Path.join([logs_root, "review-records", "parallel-review", "symphony-old-alias", "run-legacy"])
    canonical_dir = Path.join([logs_root, "review-records", "review", "symphony-old-alias", "run-legacy"])
    no_report_legacy_dir = Path.join([logs_root, "review-records", "parallel-review", "symphony-old-alias", "run-no-report"])
    no_report_canonical_dir = Path.join([logs_root, "review-records", "review", "symphony-old-alias", "run-no-report"])

    on_exit(fn -> File.rm_rf(logs_root) end)

    File.mkdir_p!(legacy_dir)
    File.mkdir_p!(no_report_legacy_dir)
    write_json!(Path.join(legacy_dir, "findings.json"), %{"schema" => "parallel-review.findings.v1", "findings" => [%{"id" => "F1", "category" => "docs", "evidence" => "Legacy finding."}]})

    write_json!(Path.join(legacy_dir, "disposition.json"), %{
      "schema" => "parallel-review.disposition.v1",
      "dispositions" => [%{"finding_id" => "F1", "status" => "no_action", "rationale" => "Already covered."}]
    })

    write_json!(Path.join(legacy_dir, "metadata.json"), %{
      "schema" => "parallel-review.metadata.v1",
      "review_id" => "run-legacy",
      "provenance" => %{"kept" => "yes"}
    })

    File.write!(Path.join(legacy_dir, "report.html"), "<html>leaked /private/tmp/symphony TOKEN=secret-value</html>")

    write_json!(Path.join(no_report_legacy_dir, "findings.json"), %{
      "schema" => "parallel-review.findings.v1",
      "findings" => [%{"id" => "F2", "category" => "docs", "evidence" => "Legacy finding without report."}]
    })

    write_json!(Path.join(no_report_legacy_dir, "disposition.json"), %{
      "schema" => "parallel-review.disposition.v1",
      "dispositions" => [%{"finding_id" => "F2", "status" => "accepted", "rationale" => "Accepted."}]
    })

    write_json!(Path.join(no_report_legacy_dir, "metadata.json"), %{
      "schema" => "parallel-review.metadata.v1",
      "review_id" => "run-no-report",
      "issue" => %{"identifier" => "SID-legacy"}
    })

    assert {:ok, %{backfilled: backfilled, skipped: [], errors: []}} =
             ReviewRecords.backfill_legacy_parallel_review(logs_root)

    backfilled = Enum.find(backfilled, &(&1.source == "parallel-review/symphony-old-alias/run-legacy"))
    assert backfilled.source == "parallel-review/symphony-old-alias/run-legacy"
    assert backfilled.target == "review/symphony-old-alias/run-legacy"

    metadata = read_json!(Path.join(canonical_dir, "metadata.json"))
    assert metadata["schema"] == "review.metadata.v1"
    assert metadata["original_repo_key"] == "symphony-old-alias"
    assert metadata["provenance"]["kept"] == "yes"
    assert metadata["provenance"]["source"] == "legacy_parallel_review"
    assert metadata["provenance"]["legacy_source_path"] == "parallel-review/symphony-old-alias/run-legacy"
    assert metadata["provenance"]["source_metadata_schema"] == "parallel-review.metadata.v1"
    canonical_report = File.read!(Path.join(canonical_dir, "report.html"))
    assert canonical_report =~ "Legacy finding."
    refute canonical_report =~ "/private/tmp/symphony"
    refute canonical_report =~ "secret-value"
    assert File.read!(Path.join(no_report_canonical_dir, "report.html")) =~ "Legacy finding without report."

    disposition = read_json!(Path.join(canonical_dir, "disposition.json"))
    assert [%{"native_status" => "no_action", "status" => "out_of_scope"}] = disposition["dispositions"]

    assert {:ok, %{backfilled: [], skipped: skipped, errors: []}} =
             ReviewRecords.backfill_legacy_parallel_review(logs_root)

    skipped = Enum.find(skipped, &(&1.source == "parallel-review/symphony-old-alias/run-legacy"))
    assert skipped.source == "parallel-review/symphony-old-alias/run-legacy"
    assert skipped.target == "review/symphony-old-alias/run-legacy"
  end

  test "redacts absolute paths and secret-shaped payloads from persisted records and read output" do
    logs_root = tmp_root!("review-records-redaction")
    workspace = tmp_root!("review-records-redaction-workspace")

    on_exit(fn ->
      File.rm_rf(logs_root)
      File.rm_rf(workspace)
    end)

    record =
      minimal_record(logs_root, "SID-322", "run-secret")
      |> put_in([:quality_gate, :planner, :workspace], workspace)
      |> put_in([:quality_gate, :jobs, Access.at(0), :raw_output], %{
        token: "raw-token",
        api_key: "raw-key",
        evidence: "Wrote #{Path.join(workspace, ".env")}"
      })

    assert {:ok, %{files: files}} = ReviewRecords.write_quality_gate_run(record)
    assert {:ok, shown} = ReviewRecords.show(logs_root, "run-secret")

    persisted = [
      read_json!(files.metadata),
      read_json!(files.quality_gate),
      read_json!(files.findings),
      shown.metadata,
      shown.quality_gate
    ]

    for payload <- persisted do
      refute inspect(payload) =~ workspace
      refute inspect(payload) =~ "raw-token"
      refute inspect(payload) =~ "raw-key"
    end
  end

  test "omits unsafe changed files and redacts free-form credential strings" do
    logs_root = tmp_root!("review-records-safe-payload")
    workspace = tmp_root!("review-records-safe-workspace")

    on_exit(fn ->
      File.rm_rf(logs_root)
      File.rm_rf(workspace)
    end)

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/source.ex"), "defmodule Source do\nend\n")

    record =
      minimal_record(logs_root, "SID-323", "run-safe-payload")
      |> Map.put(:workspace, workspace)
      |> put_in([:quality_gate, :planner, :changed_files], [
        "lib/source.ex",
        ".env",
        "tmp/cache.txt",
        "log/symphony.log",
        "../outside.ex"
      ])
      |> put_in([:quality_gate, :jobs, Access.at(0), :raw_output], %{
        evidence: "Authorization: Bearer raw-secret-token at /home/antonio/app/.env",
        detail: "api_key=raw-key-value"
      })
      |> put_in([:quality_gate, :jobs, Access.at(0), :findings, Access.at(0), :evidence], "See /home/antonio/app/.env and bearer raw-secret-token")
      |> put_in([:quality_gate, :jobs, Access.at(0), :findings, Access.at(0), :affected_files], [".env", "tmp/cache.txt", "lib/source.ex"])

    assert {:ok, %{files: files}} = ReviewRecords.write_quality_gate_run(record)
    assert {:ok, shown} = ReviewRecords.show(logs_root, "run-safe-payload")

    persisted = [
      read_json!(files.metadata),
      read_json!(files.quality_gate),
      read_json!(files.findings),
      shown.metadata,
      shown.quality_gate,
      shown.findings
    ]

    for payload <- persisted do
      inspected = inspect(payload)
      refute inspected =~ ".env"
      refute inspected =~ "tmp/cache.txt"
      refute inspected =~ "log/symphony.log"
      refute inspected =~ "../outside.ex"
      refute inspected =~ "/home/antonio"
      refute inspected =~ "raw-secret-token"
      refute inspected =~ "raw-key-value"
    end
  end

  test "fallback run ids include nested run timestamps" do
    logs_root = tmp_root!("review-records-fallback-run-id")

    on_exit(fn -> File.rm_rf(logs_root) end)

    first = fallback_run_record(logs_root, "2026-06-11T16:00:00Z", "2026-06-11T16:05:00Z")
    second = fallback_run_record(logs_root, "2026-06-11T16:10:00Z", "2026-06-11T16:15:00Z")

    assert {:ok, first_record} = ReviewRecords.write_quality_gate_run(first)
    assert {:ok, second_record} = ReviewRecords.write_quality_gate_run(second)

    refute first_record.record_dir == second_record.record_dir
    assert read_json!(first_record.files.metadata)["run"]["id"] != read_json!(second_record.files.metadata)["run"]["id"]
  end

  defp minimal_record(logs_root, issue_identifier, run_id) do
    %{
      logs_root: logs_root,
      project: %{slug: "symphony", repository: "https://github.com/apontarelli/symphony"},
      issue: %{id: "issue-#{issue_identifier}", identifier: issue_identifier, url: "https://linear.app/example/#{issue_identifier}"},
      workflow: %{profile: "default", policy_ref: "640c639998cf", target: "main"},
      run: %{id: run_id, session_id: run_id, completed_at: "2026-06-11T16:05:00Z"},
      quality_gate: %{
        status: :passed,
        planner: %{changed_files: ["lib/source.ex"], changed_surfaces: [:workflow], jobs: []},
        jobs: [
          %{
            id: "test_quality:initial",
            category: :test_quality,
            status: :fix_required,
            execution: :executed,
            phase: :initial,
            findings: [
              %{
                category: :test_quality,
                severity: :major,
                evidence: "Missing assertion.",
                affected_files: ["lib/source.ex"],
                recommended_disposition: :fix_required
              }
            ],
            raw_output: %{}
          }
        ],
        final_jobs: [%{id: "test_quality:repair_1", category: :test_quality, status: :passed}],
        synthesis: %{status: :passed, findings: []},
        repair_passes: [%{attempt: 1, status: :passed, rerun_categories: [:test_quality], rerun_jobs: []}],
        unresolved_human_review_reasons: []
      },
      handoff_route: %{
        route: "human_review",
        target_state: "Human Review",
        summary: "Human review required.",
        evidence: []
      }
    }
  end

  defp fallback_run_record(logs_root, started_at, completed_at) do
    minimal_record(logs_root, "SID-320", "unused-run-id")
    |> put_in([:run], %{started_at: started_at, completed_at: completed_at})
  end

  defp quality_gate_fixture(workspace) do
    %{
      status: :passed,
      planner: %{
        status: :planned,
        workspace: workspace,
        changed_files: ["lib/source.ex", "test/source_test.exs", "README.md"],
        changed_surfaces: [:workflow, :docs],
        jobs: [
          %{id: "test_quality", category: :test_quality, required?: true},
          %{id: "docs_source_of_truth", category: :docs_source_of_truth, required?: true},
          %{id: "scenario_qa", category: :scenario_qa, required?: true}
        ]
      },
      jobs: [
        %{
          id: "test_quality:initial",
          category: :test_quality,
          status: :fix_required,
          execution: :executed,
          phase: :initial,
          findings: [
            %{
              category: :test_quality,
              severity: :major,
              evidence: "New branch is not covered by assertions.",
              affected_files: ["test/source_test.exs"],
              recommended_disposition: :fix_required
            }
          ],
          raw_output: %{workspace_path: workspace}
        },
        %{
          id: "docs_source_of_truth:initial",
          category: :docs_source_of_truth,
          status: :passed,
          execution: :executed,
          phase: :initial,
          findings: [
            %{
              category: :docs_source_of_truth,
              severity: :minor,
              evidence: "Docs should mention the later operator flow.",
              affected_files: ["README.md"],
              recommended_disposition: :follow_up
            }
          ],
          raw_output: %{}
        },
        %{
          id: "security_data_migration:initial",
          category: :security_data_migration,
          status: :passed,
          execution: :executed,
          phase: :initial,
          findings: [
            %{
              category: :security_data_migration,
              severity: :minor,
              evidence: "Reviewer thought a local temp file was persisted.",
              affected_files: [Path.join(workspace, "tmp/secret.txt")],
              recommended_disposition: :rejected_false_positive
            }
          ],
          raw_output: %{}
        },
        %{
          id: "scenario_qa:initial",
          category: :scenario_qa,
          status: :blocked,
          execution: :blocked,
          blocked_reason: "runtime QA requires browser credentials",
          findings: [],
          raw_output: %{}
        },
        %{
          id: "product_visual_review:initial",
          category: :product_visual_review,
          status: :skipped,
          execution: :skipped,
          summary: "No product surface changed.",
          findings: [],
          raw_output: %{}
        }
      ],
      final_jobs: [
        %{id: "test_quality:repair_1", category: :test_quality, status: :passed}
      ],
      synthesis: %{status: :passed, findings: []},
      repair_passes: [
        %{
          attempt: 1,
          status: :passed,
          rerun_categories: [:test_quality],
          rerun_jobs: [%{id: "test_quality:repair_1", category: :test_quality, status: :passed}]
        }
      ],
      unresolved_human_review_reasons: []
    }
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp write_json!(path, payload), do: File.write!(path, Jason.encode!(payload, pretty: true) <> "\n")

  defp tmp_root!(name) do
    Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
  end
end
