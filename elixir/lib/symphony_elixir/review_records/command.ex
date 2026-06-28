defmodule SymphonyElixir.ReviewRecords.Command do
  @moduledoc """
  CLI command implementation for quality-gate review records.
  """

  alias SymphonyElixir.ReviewRecords

  @type result :: {:ok, String.t()} | {:error, String.t()}

  @spec evaluate([String.t()]) :: result()
  def evaluate(["list" | args]) do
    with {:ok, opts, []} <- parse_opts(args, limit: :integer),
         {:ok, records} <- ReviewRecords.list(Keyword.get(opts, :logs_root), limit: Keyword.get(opts, :limit, 20)) do
      {:ok, format_list(records)}
    else
      {:ok, _opts, _argv} -> {:error, usage_message()}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  def evaluate(["show" | args]) do
    with {:ok, opts, [run_id]} <- parse_opts(args),
         {:ok, record} <- ReviewRecords.show(Keyword.get(opts, :logs_root), run_id) do
      {:ok, format_show(record)}
    else
      {:ok, _opts, _argv} -> {:error, usage_message()}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  def evaluate(["export" | args]) do
    with {:ok, opts, []} <- parse_opts(args, since: :string, format: :string),
         {:ok, export} <-
           ReviewRecords.export(
             Keyword.get(opts, :logs_root),
             since: since(Keyword.get(opts, :since)),
             format: format(Keyword.get(opts, :format, "markdown"))
           ) do
      {:ok, format_export(export)}
    else
      {:ok, _opts, _argv} -> {:error, usage_message()}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  def evaluate(["backfill-review" | args]) do
    with {:ok, opts, []} <- parse_opts(args),
         {:ok, summary} <- ReviewRecords.backfill_legacy_parallel_review(Keyword.get(opts, :logs_root)) do
      {:ok, format_backfill(summary)}
    else
      {:ok, _opts, _argv} -> {:error, usage_message()}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  def evaluate(_args), do: {:error, usage_message()}

  defp usage_message do
    [
      "Usage: symphony review-records",
      "  symphony review-records list [--logs-root <path>] [--limit <n>]",
      "  symphony review-records show <run-id> [--logs-root <path>]",
      "  symphony review-records export [--logs-root <path>] [--since <date|last>] [--format markdown|json]",
      "  symphony review-records backfill-review [--logs-root <path>]"
    ]
    |> Enum.join("\n")
  end

  defp parse_opts(args, extra_switches \\ []) do
    switches = Keyword.merge([logs_root: :string], extra_switches)

    case OptionParser.parse(args, strict: switches) do
      {opts, argv, []} -> {:ok, opts, argv}
      _parsed -> {:error, usage_message()}
    end
  end

  defp format_list([]), do: "No quality-gate review records found."

  defp format_list(records) do
    Enum.map_join(records, "\n", fn record ->
      Enum.map_join(list_fields(record), "\t", &to_string(&1 || ""))
    end)
  end

  defp list_fields(record) do
    [
      record.run_id,
      record.issue_identifier,
      record.project_slug,
      record.quality_gate_status,
      record.route,
      record.record_path
    ]
  end

  defp format_show(record) do
    metadata = record.metadata
    dispositions = Map.get(record.disposition, "dispositions", [])

    disposition_summary =
      dispositions
      |> Enum.frequencies_by(&(&1["status"] || "untriaged"))
      |> Enum.map_join(", ", fn {status, count} -> "#{status}=#{count}" end)
      |> case do
        "" -> "none"
        summary -> summary
      end

    [
      "Review record #{get_in(metadata, ["run", "id"])}",
      "Issue: #{get_in(metadata, ["issue", "identifier"])}",
      "Project: #{get_in(metadata, ["project", "slug"])}",
      "Quality gate: #{record.quality_gate["status"]}",
      "Route: #{get_in(record.handoff_route, ["route", "route"])} -> #{get_in(record.handoff_route, ["route", "target_state"])}",
      "Findings: #{length(Map.get(record.findings, "findings", []))}",
      "Dispositions: #{disposition_summary}",
      "Record: #{get_in(metadata, ["project", "slug"])}/#{get_in(metadata, ["issue", "identifier"])}/#{get_in(metadata, ["run", "id"])}"
    ]
    |> Enum.join("\n")
  end

  defp format_export(export) when is_binary(export), do: export
  defp format_export(export), do: Jason.encode!(export, pretty: true)

  defp format_backfill(summary) do
    errors = Map.get(summary, :errors, [])

    [
      "Backfill complete: backfilled=#{length(Map.get(summary, :backfilled, []))} skipped=#{length(Map.get(summary, :skipped, []))} errors=#{length(errors)}",
      backfill_errors(errors)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp backfill_errors([]), do: ""

  defp backfill_errors(errors) do
    Enum.map_join(errors, "\n", fn error ->
      "- #{error.source}: #{error.reason}"
    end)
  end

  defp format("json"), do: :json
  defp format(_format), do: :markdown

  defp since("last"), do: :last
  defp since(value), do: value

  defp format_error(:not_found), do: "Review record not found."
  defp format_error({:ambiguous_run_id, _paths}), do: "Review record run id is ambiguous."
  defp format_error(message) when is_binary(message), do: message
  defp format_error(reason), do: "Review record command failed: #{inspect(reason)}"
end
