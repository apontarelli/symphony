defmodule SymphonyElixir.ReviewRecords.ParallelReviewAdapter do
  @moduledoc """
  Writes parallel-review-compatible projections of native Symphony review records.
  """

  alias SymphonyElixir.ReviewRecords
  alias SymphonyElixir.ReviewRecords.Redaction

  @parallel_findings_schema "parallel-review.findings.v1"
  @parallel_disposition_schema "parallel-review.disposition.v1"
  @parallel_statuses MapSet.new([
                       "accepted",
                       "fixed",
                       "rejected_false_positive",
                       "deferred_followup",
                       "needs_user_decision",
                       "out_of_scope",
                       "duplicate",
                       "untriaged"
                     ])

  @spec write(map(), map()) :: :ok | {:error, term()}
  def write(normalized, files) when is_map(normalized) and is_map(files) do
    compatibility_dir =
      Path.join([
        ReviewRecords.records_root(normalized.logs_root),
        "parallel-review",
        normalized.project.slug,
        normalized.run.id
      ])

    with :ok <- File.mkdir_p(compatibility_dir) do
      findings = files.findings |> File.read!() |> Jason.decode!()
      disposition = files.disposition |> File.read!() |> Jason.decode!()
      metadata = files.metadata |> File.read!() |> Jason.decode!()

      parallel_findings = %{
        schema: @parallel_findings_schema,
        review_id: normalized.run.id,
        findings: findings["findings"]
      }

      parallel_disposition = %{
        schema: @parallel_disposition_schema,
        review_id: normalized.run.id,
        instruction:
          "When acting on these findings, update this file with each finding's accepted, fixed, rejected_false_positive, deferred_followup, needs_user_decision, out_of_scope, duplicate, or untriaged disposition.",
        dispositions: disposition |> Map.get("dispositions", []) |> Enum.map(&parallel_disposition/1)
      }

      parallel_metadata =
        metadata
        |> Map.put("schema", "parallel-review.metadata.v1")
        |> Map.put("review_id", normalized.run.id)
        |> Map.put("target", "symphony-quality-gate")
        |> Map.put("artifact_paths", %{
          "findings" => "findings.json",
          "disposition" => "disposition.json",
          "metadata" => "metadata.json",
          "report" => "report.html"
        })

      with :ok <- write_json(Path.join(compatibility_dir, "findings.json"), parallel_findings),
           :ok <- write_json(Path.join(compatibility_dir, "disposition.json"), parallel_disposition),
           :ok <- write_json(Path.join(compatibility_dir, "metadata.json"), parallel_metadata) do
        write_html_report(Path.join(compatibility_dir, "report.html"), metadata, findings)
      end
    end
  rescue
    error -> {:error, error}
  end

  defp parallel_disposition(disposition) when is_map(disposition) do
    native_status = Map.get(disposition, "status") || "untriaged"
    status = parallel_status(native_status)

    disposition
    |> Map.put("native_status", native_status)
    |> Map.put("status", status)
    |> Map.put("rationale", parallel_rationale(Map.get(disposition, "rationale", ""), native_status, status))
  end

  defp parallel_status("no_action"), do: "out_of_scope"

  defp parallel_status(status) when is_binary(status) do
    if MapSet.member?(@parallel_statuses, status), do: status, else: "untriaged"
  end

  defp parallel_status(_status), do: "untriaged"

  defp parallel_rationale(rationale, native_status, status) when native_status != status do
    [
      "Native Symphony disposition #{native_status} mapped to #{status} for parallel-review compatibility.",
      rationale
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp parallel_rationale(rationale, _native_status, _status), do: rationale || ""

  defp write_json(path, payload), do: File.write(path, Jason.encode!(Redaction.json_ready(payload), pretty: true) <> "\n")

  defp write_html_report(path, metadata, findings) do
    body =
      findings
      |> Map.get("findings", [])
      |> Enum.map_join("\n", fn finding ->
        "<li><strong>#{html_escape(finding["category"])}</strong>: #{html_escape(finding["evidence"])}</li>"
      end)

    html = """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Symphony quality-gate record #{html_escape(get_in(metadata, ["run", "id"]))}</title></head>
    <body>
    <h1>Symphony quality-gate record #{html_escape(get_in(metadata, ["run", "id"]))}</h1>
    <p>Issue: #{html_escape(get_in(metadata, ["issue", "identifier"]))}</p>
    <ul>
    #{body}
    </ul>
    </body>
    </html>
    """

    File.write(path, html)
  end

  defp html_escape(nil), do: ""

  defp html_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
