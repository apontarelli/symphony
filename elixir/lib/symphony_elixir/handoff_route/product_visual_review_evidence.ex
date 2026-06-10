defmodule SymphonyElixir.HandoffRoute.ProductVisualReviewEvidence do
  @moduledoc false

  alias SymphonyElixir.HandoffRoute.{Artifact, Evidence}

  @known_keys %{
    "artifacts" => :artifacts,
    "checks" => :checks,
    "expected_artifacts" => :expected_artifacts,
    "expected_checks" => :expected_checks,
    "href" => :href,
    "kind" => :kind,
    "label" => :label,
    "matched_files" => :matched_files,
    "matched_labels" => :matched_labels,
    "metadata" => :metadata,
    "project_kind" => :project_kind,
    "reason" => :reason,
    "reference" => :reference,
    "required_action" => :required_action,
    "requirement" => :requirement,
    "route_policy" => :route_policy,
    "status" => :status,
    "summary" => :summary,
    "url" => :url
  }
  @status_tokens %{
    "blocked" => :blocked,
    "clean" => :passed,
    "error" => :blocked,
    "failed" => :blocked,
    "failure" => :blocked,
    "fix_required" => :blocked,
    "missing" => :missing,
    "ok" => :passed,
    "pass" => :passed,
    "passed" => :passed,
    "skipped" => :skipped,
    "success" => :passed,
    "unknown" => :unknown
  }
  @artifact_kind_tokens %{
    "artifact" => :artifact,
    "interaction_notes" => :interaction_notes,
    "product_design_notes" => :product_design_notes,
    "recording" => :recording,
    "responsive_state" => :responsive_state,
    "screenshot" => :screenshot,
    "video" => :video,
    "viewport_screenshot" => :viewport_screenshot,
    "visual_qa_manifest" => :visual_qa_manifest
  }
  @requirement_tokens %{
    "recommended" => :recommended,
    "required" => :required,
    "skip" => :skip,
    "skipped" => :skip
  }

  @spec normalize(term()) :: map() | nil
  def normalize(nil), do: nil

  def normalize(review) when is_map(review) do
    review = normalize_map(review)
    {artifacts, rejected_artifacts} = review |> fetch(:artifacts, []) |> normalize_artifacts_with_rejections()
    requirement = review |> fetch(:requirement, :skip) |> normalize_requirement()
    checks = review |> fetch(:checks, []) |> normalize_checks()
    status = review |> fetch(:status, :unknown) |> normalize_status()
    status = final_status(requirement, status, artifacts, checks, rejected_artifacts)

    %{
      requirement: requirement,
      status: status,
      reason: review |> fetch(:reason, fetch(review, :summary, nil)) |> optional_trimmed_string(),
      required_action: review |> fetch(:required_action, nil) |> optional_trimmed_string(),
      project_kind: review |> fetch(:project_kind, nil) |> optional_trimmed_string(),
      route_policy: review |> fetch(:route_policy, nil) |> optional_trimmed_string(),
      checks: checks,
      expected_checks: review |> fetch(:expected_checks, []) |> normalize_string_list(),
      expected_artifacts: review |> fetch(:expected_artifacts, []) |> normalize_string_list(),
      matched_files: review |> fetch(:matched_files, []) |> normalize_string_list(),
      matched_labels: review |> fetch(:matched_labels, []) |> normalize_string_list(),
      artifacts: artifacts,
      rejected_artifacts: rejected_artifacts
    }
  end

  def normalize(_review), do: nil

  @spec artifacts(map() | nil) :: [Artifact.t()]
  def artifacts(nil), do: []
  def artifacts(%{artifacts: artifacts}) when is_list(artifacts), do: artifacts
  def artifacts(_review), do: []

  @spec blocker(map() | nil) :: map() | nil
  def blocker(%{requirement: :required, status: status} = product_visual_review)
      when status in [:blocked, :failed, :failure, :error, :missing] do
    %{
      reason: summary(product_visual_review),
      required_action:
        product_visual_review.required_action ||
          "Run product visual QA or attach structured desktop/mobile evidence before handoff."
    }
  end

  def blocker(_product_visual_review), do: nil

  @spec evidence(map() | nil) :: [Evidence.t()]
  def evidence(nil), do: []

  def evidence(product_visual_review) do
    [
      %Evidence{
        kind: :product_visual_review,
        status: product_visual_review.status,
        summary: summary(product_visual_review),
        metadata: metadata(product_visual_review)
      }
    ]
  end

  defp final_status(:required, :passed, artifacts, checks, _rejected_artifacts) do
    if artifacts != [] or passed_checks?(checks), do: :passed, else: :blocked
  end

  defp final_status(:required, :skipped, _artifacts, _checks, _rejected_artifacts), do: :blocked
  defp final_status(:required, :unknown, _artifacts, _checks, _rejected_artifacts), do: :blocked

  defp final_status(:required, status, [], _checks, rejected_artifacts)
       when rejected_artifacts != [] and status in [:passed, :blocked] do
    :blocked
  end

  defp final_status(_requirement, status, _artifacts, _checks, _rejected_artifacts), do: status

  defp passed_checks?(checks) when is_list(checks) do
    Enum.any?(checks, &(&1.status == :passed))
  end

  defp summary(%{status: :skipped} = product_visual_review) do
    "Product visual review skipped: #{product_visual_review.reason || "not required for this change"}."
  end

  defp summary(%{status: :blocked} = product_visual_review) do
    "Product visual review #{product_visual_review.requirement} blocked: #{product_visual_review.reason || "required evidence is unavailable"}."
  end

  defp summary(%{status: :missing} = product_visual_review) do
    "Product visual review #{product_visual_review.requirement} missing: #{product_visual_review.reason || "no visual QA evidence was supplied"}."
  end

  defp summary(product_visual_review) do
    "Product visual review #{product_visual_review.requirement} #{product_visual_review.status}: #{product_visual_review.reason || "evidence recorded"}."
  end

  defp metadata(product_visual_review) do
    %{
      requirement: product_visual_review.requirement,
      reason: product_visual_review.reason,
      required_action: product_visual_review.required_action,
      project_kind: product_visual_review.project_kind,
      route_policy: product_visual_review.route_policy,
      checks: product_visual_review.checks,
      expected_checks: product_visual_review.expected_checks,
      expected_artifacts: product_visual_review.expected_artifacts,
      matched_files: product_visual_review.matched_files,
      matched_labels: product_visual_review.matched_labels,
      artifacts: Enum.map(product_visual_review.artifacts, &artifact_to_map/1),
      rejected_artifacts: product_visual_review.rejected_artifacts
    }
  end

  defp normalize_checks(checks) when is_list(checks) do
    Enum.map(checks, fn check ->
      check = normalize_map(check)

      %{
        name: check |> fetch(:name, "unnamed visual QA check") |> to_string(),
        status: check |> fetch(:status, :unknown) |> normalize_status(),
        summary: optional_string(fetch(check, :summary, nil)),
        metadata: check |> fetch(:metadata, %{}) |> normalize_map()
      }
    end)
  end

  defp normalize_checks(_checks), do: []

  defp normalize_artifacts_with_rejections(artifacts) when is_list(artifacts) do
    {artifacts, rejected_artifacts} =
      Enum.reduce(artifacts, {[], []}, fn artifact, {accepted, rejected} ->
        case normalize_artifact(artifact) do
          {:ok, artifact} -> {[artifact | accepted], rejected}
          {:error, rejection} -> {accepted, [rejection | rejected]}
        end
      end)

    {Enum.reverse(artifacts), Enum.reverse(rejected_artifacts)}
  end

  defp normalize_artifacts_with_rejections(_artifacts), do: {[], []}

  defp normalize_artifact(artifact) when is_map(artifact) do
    artifact = normalize_map(artifact)
    kind = artifact |> fetch(:kind, :artifact) |> normalize_artifact_kind()
    label = artifact |> fetch(:label, "artifact") |> to_string()
    summary = artifact |> fetch(:summary, nil) |> optional_string()
    metadata = artifact |> fetch(:metadata, %{}) |> normalize_map()

    artifact
    |> artifact_reference()
    |> normalize_artifact_reference()
    |> case do
      {:ok, url} ->
        {:ok, %Artifact{kind: kind, label: label, url: url, summary: summary, metadata: metadata}}

      {:error, reason} ->
        {:error, %{kind: kind, label: label, reason: reason}}
    end
  end

  defp normalize_artifact(artifact) do
    artifact
    |> to_string()
    |> optional_trimmed_string()
    |> case do
      nil -> {:error, %{kind: :artifact, label: "artifact", reason: :invalid_artifact}}
      summary -> {:ok, %Artifact{kind: :artifact, label: "artifact", summary: summary, metadata: %{}}}
    end
  end

  defp artifact_reference(artifact) do
    fetch(artifact, :url, fetch(artifact, :href, fetch(artifact, :reference, nil)))
  end

  defp normalize_artifact_reference(nil), do: {:ok, nil}

  defp normalize_artifact_reference(reference) do
    reference
    |> optional_trimmed_string()
    |> case do
      nil ->
        {:ok, nil}

      reference ->
        if durable_artifact_url?(reference) do
          {:ok, reference}
        else
          {:error, :local_artifact_path}
        end
    end
  end

  defp durable_artifact_url?(reference) when is_binary(reference) do
    case URI.parse(reference) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> true
      _uri -> false
    end
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&optional_trimmed_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_values), do: []

  defp artifact_to_map(%Artifact{} = artifact) do
    %{
      kind: Atom.to_string(artifact.kind),
      label: artifact.label,
      url: artifact.url,
      summary: artifact.summary,
      metadata: artifact.metadata
    }
  end

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_map(_map), do: %{}

  defp fetch(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp normalize_status(status) when is_atom(status) do
    status
    |> Atom.to_string()
    |> normalize_status()
  end

  defp normalize_status(status) when is_binary(status) do
    Map.get(@status_tokens, normalize_string_token(status), :unknown)
  end

  defp normalize_status(_status), do: :unknown

  defp normalize_artifact_kind(kind), do: normalize_token(kind, @artifact_kind_tokens, :artifact)
  defp normalize_requirement(requirement), do: normalize_token(requirement, @requirement_tokens, :skip)

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: Map.get(@known_keys, normalize_string_token(key), key)
  defp normalize_key(key), do: key

  defp normalize_token(value, tokens, default) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_string_token()
    |> then(&Map.get(tokens, &1, default))
  end

  defp normalize_token(value, tokens, default) when is_binary(value) do
    Map.get(tokens, normalize_string_token(value), default)
  end

  defp normalize_token(_value, _tokens, default), do: default

  defp normalize_string_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
  end

  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)

  defp optional_trimmed_string(nil), do: nil

  defp optional_trimmed_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
