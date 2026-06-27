defmodule SymphonyElixir.ReviewRecords.HelpersTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HandoffRoute.Decision
  alias SymphonyElixir.ReviewRecords

  alias SymphonyElixir.ReviewRecords.{
    Command,
    PathSanitizer,
    Redaction,
    RetrospectiveAdapter
  }

  test "review-records command handles usage, empty lists, json exports, and read errors" do
    logs_root = tmp_root!("review-records-command")

    on_exit(fn -> File.rm_rf(logs_root) end)

    assert {:ok, "No quality-gate review records found."} =
             Command.evaluate(["list", "--logs-root", logs_root])

    assert {:error, usage} = Command.evaluate(["unknown"])
    assert usage =~ "Usage: symphony review-records"

    assert {:error, ^usage} = Command.evaluate(["list", "--logs-root", logs_root, "extra"])
    assert {:error, ^usage} = Command.evaluate(["list", "--limit", "not-an-integer"])
    assert {:error, ^usage} = Command.evaluate(["show", "--logs-root", logs_root])
    assert {:error, ^usage} = Command.evaluate(["export", "--logs-root", logs_root, "extra"])
    assert {:error, ^usage} = Command.evaluate(["export", "--unknown"])

    assert {:ok, _record} =
             ReviewRecords.write_quality_gate_run(command_record(logs_root, "SID-900", "run-command"))

    assert {:ok, show_output} = Command.evaluate(["show", "run-command", "--logs-root", logs_root])
    assert show_output =~ "Dispositions: accepted=1"

    assert {:ok, export_output} =
             Command.evaluate(["export", "--logs-root", logs_root, "--format", "json", "--since", "last"])

    assert Jason.decode!(export_output)["record_count"] == 1

    assert {:ok, backfill_output} = Command.evaluate(["backfill-review", "--logs-root", logs_root])
    assert backfill_output =~ "backfilled=0 skipped=0 errors=0"
    assert {:error, backfill_usage} = Command.evaluate(["backfill-review", "extra"])
    assert backfill_usage =~ "Usage: symphony review-records"
    assert backfill_usage =~ "backfill-review [--logs-root <path>]"
    refute backfill_usage =~ "backfill-review [--logs-root <path>] [--format"
    assert {:error, ^backfill_usage} = Command.evaluate(["backfill-review", "--unknown"])

    write_metadata_only!(logs_root, "SID-901", "run-same", ~s({"schema":"metadata"}))
    write_metadata_only!(logs_root, "SID-902", "run-same", ~s({"schema":"metadata"}))

    assert {:error, "Review record run id is ambiguous."} =
             Command.evaluate(["show", "run-same", "--logs-root", logs_root])

    write_metadata_only!(logs_root, "SID-903", "run-bad", "not-json")

    assert {:error, read_error} = Command.evaluate(["show", "run-bad", "--logs-root", logs_root])
    assert read_error =~ "Review record command failed:"

    assert {:error, "Review record not found."} =
             Command.evaluate(["show", "missing", "--logs-root", logs_root])
  end

  test "redaction handles structs, dates, and non-binary values" do
    assert Redaction.json_ready(~U[2026-06-11 18:00:00Z]) == "2026-06-11T18:00:00Z"
    assert Redaction.json_ready(~D[2026-06-11]) == "2026-06-11"

    assert %{"route" => "human_review", "target_state" => "Human Review"} =
             Redaction.json_ready(%Decision{
               route: :human_review,
               target_state: "Human Review",
               summary: "Needs review.",
               recommendation: "Review before handoff."
             })

    assert %{"scheme" => "https", "host" => "example.com"} =
             Redaction.json_ready(URI.parse("https://example.com/path"))

    assert Redaction.redact_string(12_345) == "12345"

    assert Redaction.json_ready(%{authorization: "Bearer token-value", count: 3}) == %{
             "authorization" => "<redacted:secret>",
             "count" => 3
           }
  end

  test "path sanitizer handles fallback payload path variants" do
    assert PathSanitizer.safe_file_list("README.md") == []

    assert PathSanitizer.safe_file_list([
             nil,
             "",
             %{path: "lib/source.ex"},
             %{"path" => "README.md"},
             "symphony.local.yml",
             ".env.production",
             ".env.example",
             "/tmp/secret.txt",
             "cache/file.txt",
             "foo/.bar_cache/file.txt",
             "docs/guide.md"
           ]) == ["lib/source.ex", "README.md", ".env.example", "docs/guide.md"]

    payload =
      PathSanitizer.sanitize_payload_paths(
        %{
          "changed_files" => ["README.md", ".env"],
          :affected_files => ["docs/guide.md", "id_rsa"],
          "nested" => [%{"files" => ["test/source_test.exs", "temp/out.txt"]}]
        },
        nil
      )

    assert payload["changed_files"] == ["README.md"]
    assert payload[:affected_files] == ["docs/guide.md"]
    assert [%{"files" => ["test/source_test.exs"]}] = payload["nested"]
  end

  test "retrospective adapter maps non-string statuses and reports read errors" do
    logs_root = tmp_root!("review-records-adapter")
    source_dir = tmp_root!("review-records-adapter-source")

    on_exit(fn ->
      File.rm_rf(logs_root)
      File.rm_rf(source_dir)
    end)

    File.mkdir_p!(source_dir)

    files = %{
      findings: Path.join(source_dir, "findings.json"),
      disposition: Path.join(source_dir, "disposition.json"),
      metadata: Path.join(source_dir, "metadata.json")
    }

    write_json!(files.findings, %{"findings" => [%{"category" => nil, "evidence" => nil}]})

    write_json!(files.disposition, %{
      "dispositions" => [
        %{"finding_id" => "F1", "status" => 123, "rationale" => ""},
        %{"finding_id" => "F2", "status" => "no_change", "rationale" => "No code change."}
      ]
    })

    write_json!(files.metadata, %{"run" => %{}, "issue" => %{}})

    normalized = %{logs_root: logs_root, project: %{slug: "symphony"}, run: %{id: "run-adapter"}}

    assert :ok = RetrospectiveAdapter.write(normalized, files)

    disposition =
      [logs_root, "review-records", "review", "symphony", "run-adapter", "disposition.json"]
      |> Path.join()
      |> read_json!()

    assert [
             %{"native_status" => 123, "status" => "untriaged"},
             %{"native_status" => "no_change", "status" => "out_of_scope"}
           ] = disposition["dispositions"]

    refute disposition["instruction"] =~ "no_change"

    assert {:error, %File.Error{}} =
             RetrospectiveAdapter.write(normalized, %{
               files
               | findings: Path.join(source_dir, "missing.json")
             })
  end

  test "retrospective backfill reports malformed legacy records" do
    logs_root = tmp_root!("review-records-backfill-errors")
    legacy_dir = Path.join([logs_root, "review-records", "parallel-review", "symphony", "run-bad"])

    on_exit(fn -> File.rm_rf(logs_root) end)

    File.mkdir_p!(legacy_dir)
    write_json!(Path.join(legacy_dir, "metadata.json"), %{"schema" => "parallel-review.metadata.v1"})

    assert {:ok, output} = Command.evaluate(["backfill-review", "--logs-root", logs_root])
    assert output =~ "backfilled=0 skipped=0 errors=1"
    assert output =~ "parallel-review/symphony/run-bad"
    assert output =~ "no such file"

    assert {:error, %FunctionClauseError{}} = RetrospectiveAdapter.backfill_legacy_parallel_review(:invalid_logs_root)
  end

  defp command_record(logs_root, issue_identifier, run_id) do
    %{
      logs_root: logs_root,
      project: %{slug: "symphony"},
      issue: %{id: "issue-#{issue_identifier}", identifier: issue_identifier},
      workflow: %{profile: "default", policy_ref: "640c639998cf", target: "main"},
      run: %{id: run_id, session_id: run_id, completed_at: "2026-06-11T16:05:00Z"},
      quality_gate: %{
        status: :fix_required,
        planner: %{changed_files: ["lib/source.ex"], changed_surfaces: [:workflow], jobs: []},
        jobs: [
          %{
            id: "test_quality:initial",
            category: :test_quality,
            status: :fix_required,
            execution: :executed,
            findings: [
              %{
                category: :test_quality,
                severity: :major,
                evidence: "Missing assertion.",
                affected_files: ["lib/source.ex"],
                recommended_disposition: :fix_required
              }
            ]
          }
        ],
        repair_passes: []
      },
      handoff_route: %{route: "human_review", target_state: "Human Review", evidence: []}
    }
  end

  defp write_metadata_only!(logs_root, issue_identifier, run_id, payload) do
    path =
      [
        logs_root,
        "review-records",
        "quality-gates",
        "symphony",
        issue_identifier,
        run_id,
        "metadata.json"
      ]
      |> Path.join()

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, payload)
  end

  defp write_json!(path, payload) do
    File.write!(path, Jason.encode!(payload, pretty: true) <> "\n")
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp tmp_root!(name) do
    Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
  end
end
