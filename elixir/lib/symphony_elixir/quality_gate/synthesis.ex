defmodule SymphonyElixir.QualityGate.Synthesis do
  @moduledoc """
  Normalizes reviewer output into actionable quality-gate dispositions.
  """

  @type finding :: %{
          severity: atom(),
          category: atom(),
          evidence: String.t(),
          affected_files: [String.t()],
          reproducibility_notes: String.t() | nil,
          recommended_disposition: atom()
        }

  @type result :: %{
          status: atom(),
          summary: String.t(),
          findings: [finding()],
          unresolved_human_review_reasons: [String.t()]
        }

  @dispositions MapSet.new([
                  :fix_required,
                  :human_input_required,
                  :follow_up,
                  :no_action,
                  :rejected_false_positive
                ])
  @categories MapSet.new([
                :source_correctness,
                :test_quality,
                :scenario_qa,
                :product_visual_review,
                :docs_source_of_truth,
                :security_data_migration
              ])
  @severities MapSet.new([:critical, :major, :minor, :trivial])
  @token_map %{
    "critical" => :critical,
    "major" => :major,
    "minor" => :minor,
    "trivial" => :trivial,
    "source_correctness" => :source_correctness,
    "test_quality" => :test_quality,
    "scenario_qa" => :scenario_qa,
    "product_visual_review" => :product_visual_review,
    "docs_source_of_truth" => :docs_source_of_truth,
    "security_data_migration" => :security_data_migration,
    "fix_required" => :fix_required,
    "human_input_required" => :human_input_required,
    "follow_up" => :follow_up,
    "no_action" => :no_action,
    "rejected_false_positive" => :rejected_false_positive
  }

  @spec synthesize([map()]) :: result()
  def synthesize(job_results) when is_list(job_results) do
    findings =
      job_results
      |> Enum.flat_map(&findings_for_job/1)
      |> dedupe_findings()

    unresolved_human_review_reasons =
      job_results
      |> Enum.filter(&(Map.get(&1, :status) == :blocked))
      |> Enum.map(&blocked_reason/1)
      |> Enum.reject(&(&1 == ""))

    status = synthesis_status(job_results, findings, unresolved_human_review_reasons)

    %{
      status: status,
      summary: summary(status, findings, unresolved_human_review_reasons),
      findings: findings,
      unresolved_human_review_reasons: unresolved_human_review_reasons
    }
  end

  @spec affected_categories(result(), [map()]) :: [atom()]
  def affected_categories(%{findings: findings}, job_results) when is_list(findings) do
    finding_categories =
      findings
      |> Enum.filter(&(Map.get(&1, :recommended_disposition) == :fix_required))
      |> Enum.flat_map(fn finding ->
        case Map.get(finding, :category) do
          category when is_atom(category) -> [category]
          _ -> []
        end
      end)

    status_categories =
      job_results
      |> Enum.filter(&(Map.get(&1, :status) == :fix_required))
      |> Enum.flat_map(fn job ->
        case Map.get(job, :category) do
          category when is_atom(category) -> [category]
          _ -> []
        end
      end)

    (finding_categories ++ status_categories)
    |> Enum.uniq()
  end

  defp findings_for_job(%{findings: findings} = job) when is_list(findings) do
    normalized_findings =
      findings
      |> Enum.flat_map(&normalize_finding(&1, job))

    if normalized_findings == [] and Map.get(job, :status) == :fix_required do
      [synthetic_finding(job, :fix_required)]
    else
      normalized_findings
    end
  end

  defp findings_for_job(%{status: :fix_required} = job), do: [synthetic_finding(job, :fix_required)]
  defp findings_for_job(_job), do: []

  defp normalize_finding(finding, job) when is_map(finding) do
    [
      %{
        severity: normalize_severity(value_at(finding, :severity), :major),
        category: normalize_category(value_at(finding, :category), Map.get(job, :category, :source_correctness)),
        evidence:
          string_value(
            value_at(finding, :evidence) || value_at(finding, :summary),
            "Reviewer reported an actionable finding."
          ),
        affected_files: string_list(value_at(finding, :affected_files) || value_at(finding, :files)),
        reproducibility_notes:
          optional_string(
            value_at(finding, :reproducibility_notes) ||
              value_at(finding, :reproducibility)
          ),
        recommended_disposition:
          normalize_disposition(
            value_at(finding, :recommended_disposition) ||
              value_at(finding, :disposition)
          )
      }
      |> Map.put(:source_job_id, Map.get(job, :id))
    ]
  end

  defp normalize_finding(_finding, _job), do: []

  defp synthetic_finding(job, disposition) do
    %{
      severity: :major,
      category: Map.get(job, :category, :source_correctness),
      evidence: Map.get(job, :summary) || "Reviewer job requires follow-up.",
      affected_files: [],
      reproducibility_notes: nil,
      recommended_disposition: disposition,
      source_job_id: Map.get(job, :id)
    }
  end

  defp synthesis_status(job_results, findings, unresolved_human_review_reasons) do
    cond do
      unresolved_human_review_reasons != [] or Enum.any?(job_results, &(Map.get(&1, :status) == :blocked)) ->
        :blocked

      Enum.any?(findings, &(Map.get(&1, :recommended_disposition) == :human_input_required)) ->
        :human_input_required

      Enum.any?(findings, &(Map.get(&1, :recommended_disposition) == :fix_required)) or
          Enum.any?(job_results, &(Map.get(&1, :status) == :fix_required)) ->
        :fix_required

      true ->
        :passed
    end
  end

  defp summary(:passed, _findings, _reasons), do: "Quality gate passed with no fix-required findings."
  defp summary(:blocked, _findings, reasons), do: "Quality gate blocked: #{Enum.join(reasons, "; ")}"
  defp summary(:human_input_required, _findings, _reasons), do: "Quality gate requires human input before handoff."
  defp summary(:fix_required, findings, _reasons), do: "Quality gate requires fixes: #{length(findings)} finding(s)."

  defp blocked_reason(job) do
    Map.get(job, :blocked_reason) ||
      Map.get(job, :summary) ||
      "#{Map.get(job, :category, :review)} blocked"
  end

  defp dedupe_findings(findings) do
    findings
    |> Enum.reduce({MapSet.new(), []}, fn finding, {seen, acc} ->
      key = {finding.category, finding.evidence, finding.affected_files, finding.recommended_disposition}

      if MapSet.member?(seen, key) do
        {seen, acc}
      else
        {MapSet.put(seen, key), [finding | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp normalize_category(value, default) do
    token = normalize_token(value)
    if MapSet.member?(@categories, token), do: token, else: default
  end

  defp normalize_severity(value, default) do
    token = normalize_token(value)
    if MapSet.member?(@severities, token), do: token, else: default
  end

  defp normalize_token(value) when is_atom(value), do: value

  defp normalize_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> then(&Map.get(@token_map, &1, :unknown))
  end

  defp normalize_token(_value), do: :unknown

  defp normalize_disposition(value) do
    disposition = normalize_token(value)
    if MapSet.member?(@dispositions, disposition), do: disposition, else: :human_input_required
  end

  defp string_value(value, default) do
    value
    |> optional_string()
    |> case do
      nil -> default
      string -> string
    end
  end

  defp optional_string(nil), do: nil

  defp optional_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      string -> string
    end
  end

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&optional_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp string_list(_values), do: []

  defp value_at(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
end
