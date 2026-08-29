defmodule SymphonyElixir.HandoffRoute.AuthorityPolicy do
  @moduledoc false

  alias SymphonyElixir.HandoffRoute.Evidence

  defstruct evidence_complete?: false,
            requires_human_review?: false,
            policy_changed?: false,
            matched_files: [],
            matched_patterns: [],
            missing_evidence: [],
            evidence: []

  @type t :: %__MODULE__{
          evidence_complete?: boolean(),
          requires_human_review?: boolean(),
          policy_changed?: boolean(),
          matched_files: [String.t()],
          matched_patterns: [String.t()],
          missing_evidence: [atom()],
          evidence: [Evidence.t()]
        }

  @spec evaluate(map()) :: t()
  def evaluate(input) when is_map(input) do
    changed_files = normalize_string_list(fetch(input, :changed_files, []))
    patterns = configured_patterns(fetch(input, :policy, %{}))
    changed_files_status = normalize_status(fetch(input, :changed_files_status, :unverified))
    policy_change_status = normalize_status(fetch(input, :policy_change_status, :unverified))
    matches = matching_pairs(changed_files, patterns)
    matched_files = matches |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    matched_patterns = matches |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    missing_evidence = missing_evidence(changed_files_status, policy_change_status)
    policy_changed? = policy_change_status == :changed
    evidence_complete? = missing_evidence == []
    requires_human_review? = policy_changed? or matched_files != []

    %__MODULE__{
      evidence_complete?: evidence_complete?,
      requires_human_review?: requires_human_review?,
      policy_changed?: policy_changed?,
      matched_files: matched_files,
      matched_patterns: matched_patterns,
      missing_evidence: missing_evidence,
      evidence:
        evidence(
          evidence_complete?,
          requires_human_review?,
          changed_files,
          matched_files,
          matched_patterns,
          policy_changed?,
          missing_evidence
        )
    }
  end

  def evaluate(_input), do: evaluate(%{})

  defp configured_patterns(policy) do
    policy
    |> fetch(:auto_land, %{})
    |> fetch(:force_human_review_paths, [])
    |> normalize_string_list()
  end

  defp missing_evidence(changed_files_status, policy_change_status) do
    []
    |> maybe_add_missing(changed_files_status != :verified, :changed_files_unverified)
    |> maybe_add_missing(policy_change_status == :unverified, :auto_land_policy_change_unverified)
  end

  defp maybe_add_missing(missing, true, reason), do: missing ++ [reason]
  defp maybe_add_missing(missing, false, _reason), do: missing

  defp evidence(false, _requires_human_review?, _changed_files, _matched_files, _matched_patterns, _policy_changed?, missing_evidence) do
    [
      %Evidence{
        kind: :authority_policy,
        status: :missing,
        summary: "Host could not prove complete authority-routing evidence.",
        metadata: %{missing_evidence: missing_evidence}
      }
    ]
  end

  defp evidence(true, true, _changed_files, matched_files, matched_patterns, policy_changed?, _missing_evidence) do
    [
      %Evidence{
        kind: :authority_policy,
        status: :applied,
        summary: authority_match_summary(matched_files, policy_changed?),
        metadata: %{
          matched_files: matched_files,
          matched_patterns: matched_patterns,
          auto_land_policy_changed: policy_changed?
        }
      }
    ]
  end

  defp evidence(true, false, changed_files, _matched_files, _matched_patterns, _policy_changed?, _missing_evidence) do
    [
      %Evidence{
        kind: :authority_policy,
        status: :passed,
        summary: "Authority exclusions checked #{length(changed_files)} changed file(s); no protected change matched.",
        metadata: %{changed_file_count: length(changed_files)}
      }
    ]
  end

  defp authority_match_summary(matched_files, true) when matched_files != [] do
    "Human review required: protected paths matched and the repository auto-land policy changed."
  end

  defp authority_match_summary(_matched_files, true) do
    "Human review required: the repository auto-land policy changed."
  end

  defp authority_match_summary(_matched_files, false) do
    "Human review required: changed files matched repository authority exclusions."
  end

  defp matching_pairs(changed_files, patterns) do
    for file <- changed_files,
        pattern <- patterns,
        path_matches?(file, pattern),
        do: {file, pattern}
  end

  defp path_matches?(file, pattern) do
    pattern
    |> glob_regex()
    |> Regex.match?(file)
  end

  defp glob_regex(pattern) do
    pattern
    |> Regex.escape()
    |> String.replace("\\*\\*/", "(?:.*/)?")
    |> String.replace("\\*\\*", ".*")
    |> String.replace("\\*", "[^/]*")
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_path/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_string_list(_values), do: []

  defp normalize_path(value) do
    value
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
  end

  defp normalize_status(status) when status in [:verified, :changed, :unchanged, :unverified], do: status
  defp normalize_status("verified"), do: :verified
  defp normalize_status("changed"), do: :changed
  defp normalize_status("unchanged"), do: :unchanged
  defp normalize_status(_status), do: :unverified

  defp fetch(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key), default))
  defp fetch(_map, _key, default), do: default
end
