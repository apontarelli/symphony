defmodule SymphonyElixir.ReviewRecords.RetrospectiveAdapter do
  @moduledoc """
  Writes review-retrospective-compatible projections of native Symphony review records.

  The canonical compatibility layout is `review/<repo-key>/<review-id>/`.
  Historical `parallel-review/` records are treated only as legacy backfill input.
  """

  alias SymphonyElixir.ReviewRecords
  alias SymphonyElixir.ReviewRecords.Redaction

  @review_findings_schema "review.findings.v1"
  @review_disposition_schema "review.disposition.v1"
  @review_metadata_schema "review.metadata.v1"
  @review_statuses MapSet.new([
                     "accepted",
                     "fixed",
                     "rejected_false_positive",
                     "deferred_followup",
                     "needs_user_decision",
                     "out_of_scope",
                     "duplicate",
                     "untriaged"
                   ])

  @type backfill_item :: %{
          required(:source) => String.t(),
          required(:target) => String.t() | nil,
          optional(:reason) => String.t()
        }

  @type backfill_summary :: %{
          required(:backfilled) => [backfill_item()],
          required(:skipped) => [backfill_item()],
          required(:errors) => [backfill_item()]
        }

  @spec write(map(), map()) :: :ok | {:error, term()}
  def write(normalized, files) when is_map(normalized) and is_map(files) do
    compatibility_dir = review_dir(ReviewRecords.records_root(normalized.logs_root), normalized.project.slug, normalized.run.id)

    with :ok <- File.mkdir_p(compatibility_dir) do
      findings = files.findings |> File.read!() |> Jason.decode!()
      disposition = files.disposition |> File.read!() |> Jason.decode!()
      metadata = files.metadata |> File.read!() |> Jason.decode!()

      review_findings = findings_payload(findings, normalized.project.slug, normalized.run.id)
      review_disposition = disposition_payload(disposition, normalized.project.slug, normalized.run.id)
      review_metadata = metadata_payload(metadata, normalized, source_record_path(normalized))

      with :ok <- write_json_once(Path.join(compatibility_dir, "findings.json"), review_findings),
           :ok <- write_json_once(Path.join(compatibility_dir, "disposition.json"), review_disposition),
           :ok <- write_json(Path.join(compatibility_dir, "metadata.json"), review_metadata) do
        write_html_report(Path.join(compatibility_dir, "report.html"), metadata, findings)
      end
    end
  rescue
    error -> {:error, error}
  end

  @spec backfill_legacy_parallel_review(Path.t() | nil) :: {:ok, backfill_summary()} | {:error, term()}
  def backfill_legacy_parallel_review(logs_root) do
    records_root = ReviewRecords.records_root(logs_root)

    summary =
      records_root
      |> Path.join("parallel-review/*/*/metadata.json")
      |> Path.wildcard()
      |> Enum.map(&backfill_legacy_record(records_root, &1))
      |> summarize_backfill()

    {:ok, summary}
  rescue
    error -> {:error, error}
  end

  defp backfill_legacy_record(records_root, metadata_path) do
    legacy_dir = Path.dirname(metadata_path)
    review_id = Path.basename(legacy_dir)
    repo_key = legacy_dir |> Path.dirname() |> Path.basename()
    canonical_dir = review_dir(records_root, repo_key, review_id)
    source = relative_path(legacy_dir, records_root)
    target = relative_path(canonical_dir, records_root)

    if File.regular?(Path.join(canonical_dir, "metadata.json")) do
      {:skipped, %{source: source, target: target, reason: "canonical review record already exists"}}
    else
      File.mkdir_p!(canonical_dir)

      findings = legacy_dir |> Path.join("findings.json") |> File.read!() |> Jason.decode!()
      disposition = legacy_dir |> Path.join("disposition.json") |> File.read!() |> Jason.decode!()
      metadata = metadata_path |> File.read!() |> Jason.decode!()

      review_findings = findings_payload(findings, repo_key, review_id)
      review_disposition = disposition_payload(disposition, repo_key, review_id)
      review_metadata = backfilled_metadata_payload(metadata, repo_key, review_id, source)

      :ok = write_json_once(Path.join(canonical_dir, "findings.json"), review_findings)
      :ok = write_json_once(Path.join(canonical_dir, "disposition.json"), review_disposition)
      :ok = write_json(Path.join(canonical_dir, "metadata.json"), review_metadata)
      :ok = write_backfilled_report(legacy_dir, canonical_dir, metadata, findings)

      {:backfilled, %{source: source, target: target}}
    end
  rescue
    error ->
      {:error,
       %{
         source: relative_path(Path.dirname(metadata_path), records_root),
         target: nil,
         reason: Exception.message(error)
       }}
  end

  defp summarize_backfill(results) do
    results
    |> Enum.reduce(%{backfilled: [], skipped: [], errors: []}, fn
      {:backfilled, item}, acc -> Map.update!(acc, :backfilled, &[item | &1])
      {:skipped, item}, acc -> Map.update!(acc, :skipped, &[item | &1])
      {:error, item}, acc -> Map.update!(acc, :errors, &[item | &1])
    end)
    |> Map.update!(:backfilled, &Enum.reverse/1)
    |> Map.update!(:skipped, &Enum.reverse/1)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  defp findings_payload(findings, repo_key, review_id) do
    %{
      schema: @review_findings_schema,
      review_id: review_id,
      repo_key: repo_key,
      original_repo_key: repo_key,
      findings: Map.get(findings, "findings", [])
    }
  end

  defp disposition_payload(disposition, repo_key, review_id) do
    %{
      schema: @review_disposition_schema,
      review_id: review_id,
      repo_key: repo_key,
      original_repo_key: repo_key,
      instruction:
        "When acting on these findings, update this file with each finding's accepted, fixed, rejected_false_positive, deferred_followup, needs_user_decision, out_of_scope, duplicate, or untriaged disposition.",
      dispositions: disposition |> Map.get("dispositions", []) |> Enum.map(&review_disposition/1)
    }
  end

  defp metadata_payload(metadata, normalized, source_path) do
    metadata
    |> canonical_metadata(normalized.project.slug, normalized.run.id)
    |> put_provenance(%{
      "source" => "symphony_quality_gate",
      "source_record_path" => source_path,
      "source_metadata_schema" => metadata["schema"],
      "original_repo_key" => normalized.project.slug
    })
  end

  defp backfilled_metadata_payload(metadata, repo_key, review_id, source_path) do
    metadata
    |> canonical_metadata(repo_key, review_id)
    |> put_provenance(%{
      "source" => "legacy_parallel_review",
      "legacy_source_path" => source_path,
      "source_metadata_schema" => metadata["schema"],
      "original_repo_key" => repo_key,
      "backfilled_at" => iso8601_now()
    })
  end

  defp canonical_metadata(metadata, repo_key, review_id) do
    metadata
    |> Map.put("schema", @review_metadata_schema)
    |> Map.put("review_id", review_id)
    |> Map.put("repo_key", repo_key)
    |> Map.put("original_repo_key", repo_key)
    |> Map.put("canonical_repo_key", repo_key)
    |> Map.put("target", "symphony-quality-gate")
    |> Map.put("artifact_paths", %{
      "findings" => "findings.json",
      "disposition" => "disposition.json",
      "metadata" => "metadata.json",
      "report" => "report.html"
    })
  end

  defp put_provenance(metadata, provenance) do
    existing =
      case Map.get(metadata, "provenance") do
        value when is_map(value) -> value
        _value -> %{}
      end

    Map.put(metadata, "provenance", Map.merge(existing, provenance))
  end

  defp review_disposition(disposition) when is_map(disposition) do
    native_status = Map.get(disposition, "status") || "untriaged"
    status = review_status(native_status)

    disposition
    |> Map.put("native_status", native_status)
    |> Map.put("status", status)
    |> Map.put("rationale", review_rationale(Map.get(disposition, "rationale", ""), native_status, status))
  end

  defp review_status(status) when status in ["no_action", "no_change"], do: "out_of_scope"

  defp review_status(status) when is_binary(status) do
    if MapSet.member?(@review_statuses, status), do: status, else: "untriaged"
  end

  defp review_status(_status), do: "untriaged"

  defp review_rationale(rationale, native_status, status) when native_status != status do
    [
      "Native Symphony disposition #{native_status} mapped to #{status} for review-retrospective compatibility.",
      rationale
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp review_rationale(rationale, _native_status, _status), do: rationale || ""

  defp source_record_path(%{record_dir: record_dir} = normalized) when is_binary(record_dir) do
    normalized.record_dir
    |> relative_path(ReviewRecords.records_root(normalized.logs_root))
  end

  defp source_record_path(_normalized), do: nil

  defp review_dir(records_root, repo_key, review_id) do
    Path.join([records_root, "review", repo_key, review_id])
  end

  defp relative_path(path, root) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Path.join()
  end

  defp write_json(path, payload), do: File.write(path, Jason.encode!(Redaction.json_ready(payload), pretty: true) <> "\n")

  defp write_json_once(path, payload) do
    if File.exists?(path) do
      :ok
    else
      write_json(path, payload)
    end
  end

  defp write_backfilled_report(_legacy_dir, canonical_dir, metadata, findings) do
    write_html_report(Path.join(canonical_dir, "report.html"), metadata, findings)
  end

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
    <head><meta charset="utf-8"><title>Symphony quality-gate record #{html_escape(review_id(metadata))}</title></head>
    <body>
    <h1>Symphony quality-gate record #{html_escape(review_id(metadata))}</h1>
    <p>Issue: #{html_escape(get_in(metadata, ["issue", "identifier"]))}</p>
    <ul>
    #{body}
    </ul>
    </body>
    </html>
    """

    File.write(path, html)
  end

  defp review_id(metadata), do: get_in(metadata, ["run", "id"]) || metadata["review_id"]

  defp iso8601_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
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
