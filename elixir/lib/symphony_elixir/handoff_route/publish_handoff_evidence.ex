defmodule SymphonyElixir.HandoffRoute.PublishHandoffEvidence do
  @moduledoc false

  @known_keys %{
    "args" => :args,
    "base_branch" => :base_branch,
    "branch" => :branch,
    "change_id" => :change_id,
    "command" => :command,
    "commit_sha" => :commit_sha,
    "details" => :details,
    "exit_status" => :exit_status,
    "failure" => :failure,
    "github_repository" => :github_repository,
    "id" => :id,
    "identifier" => :identifier,
    "linear_issue" => :linear_issue,
    "metadata" => :metadata,
    "pr_url" => :pr_url,
    "reason" => :reason,
    "repository" => :repository,
    "status" => :status,
    "step" => :step,
    "summary" => :summary,
    "url" => :url,
    "validation_summary" => :validation_summary
  }

  @type normalized :: %{
          status: atom(),
          pr_url: String.t() | nil,
          repository: String.t() | nil,
          github_repository: String.t() | nil,
          base_branch: String.t() | nil,
          branch: String.t() | nil,
          change_id: String.t() | nil,
          commit_sha: String.t() | nil,
          validation_summary: String.t() | nil,
          linear_issue: map(),
          failure: map() | nil
        }

  @spec normalize(term()) :: normalized() | nil
  def normalize(publish_handoff) when is_map(publish_handoff) do
    publish_handoff = normalize_map(publish_handoff)

    %{
      status: publish_handoff |> fetch(:status, :unknown) |> normalize_status(),
      pr_url: publish_handoff |> fetch(:pr_url, nil) |> optional_trimmed_string(),
      repository: publish_handoff |> fetch(:repository, nil) |> optional_trimmed_string(),
      github_repository: publish_handoff |> fetch(:github_repository, nil) |> optional_trimmed_string(),
      base_branch: publish_handoff |> fetch(:base_branch, nil) |> optional_trimmed_string(),
      branch: publish_handoff |> fetch(:branch, nil) |> optional_trimmed_string(),
      change_id: publish_handoff |> fetch(:change_id, nil) |> optional_trimmed_string(),
      commit_sha: publish_handoff |> fetch(:commit_sha, nil) |> optional_trimmed_string(),
      validation_summary: publish_handoff |> fetch(:validation_summary, nil) |> optional_trimmed_string(),
      linear_issue: publish_handoff |> fetch(:linear_issue, %{}) |> normalize_map(),
      failure: publish_handoff |> fetch(:failure, nil) |> normalize_failure()
    }
  end

  def normalize(_publish_handoff), do: nil

  @spec blocker(normalized() | nil) :: map() | nil
  def blocker(%{status: status} = publish_handoff) when status in [:blocked, :failed, :failure, :error] do
    %{
      reason: failure_summary(publish_handoff) || "Host publish failed before PR handoff.",
      required_action: "Restore host VCS/GitHub publish capability before Human Review."
    }
  end

  def blocker(_publish_handoff), do: nil

  @spec evidence(normalized() | nil) :: [SymphonyElixir.HandoffRoute.Evidence.t()]
  def evidence(nil), do: []

  def evidence(%{status: :passed} = publish_handoff) do
    [
      %SymphonyElixir.HandoffRoute.Evidence{
        kind: :publish,
        status: :passed,
        summary: "Published PR #{publish_handoff.pr_url || "unknown PR"} targeting #{target(publish_handoff)}.",
        metadata: metadata(publish_handoff)
      }
    ]
  end

  def evidence(%{status: status} = publish_handoff) when status in [:blocked, :failed, :failure, :error] do
    [
      %SymphonyElixir.HandoffRoute.Evidence{
        kind: :publish,
        status: :blocked,
        summary: failure_summary(publish_handoff) || "Host publish failed for #{target(publish_handoff)}.",
        metadata: metadata(publish_handoff)
      }
    ]
  end

  def evidence(%{}), do: []

  defp metadata(publish_handoff) do
    %{
      pr_url: publish_handoff.pr_url,
      repository: publish_handoff.repository,
      github_repository: publish_handoff.github_repository,
      base_branch: publish_handoff.base_branch,
      target: target(publish_handoff),
      branch: publish_handoff.branch,
      change_id: publish_handoff.change_id,
      commit_sha: publish_handoff.commit_sha,
      validation_summary: publish_handoff.validation_summary,
      linear_issue: publish_handoff.linear_issue,
      failure: publish_handoff.failure
    }
  end

  defp target(%{github_repository: github_repository, base_branch: base_branch})
       when is_binary(github_repository) and is_binary(base_branch) do
    "#{github_repository}:#{base_branch}"
  end

  defp target(%{repository: repository, base_branch: base_branch})
       when is_binary(repository) and is_binary(base_branch) do
    "#{repository}:#{base_branch}"
  end

  defp target(_publish_handoff), do: "unknown target"

  defp failure_summary(%{failure: %{summary: summary}}) when is_binary(summary), do: summary
  defp failure_summary(%{failure: %{"summary" => summary}}) when is_binary(summary), do: summary
  defp failure_summary(_publish_handoff), do: nil

  defp normalize_failure(nil), do: nil
  defp normalize_failure(failure) when is_map(failure), do: normalize_map(failure)
  defp normalize_failure(failure), do: %{summary: to_string(failure)}

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), normalize_value(value)} end)
  end

  defp normalize_map(_map), do: %{}

  defp normalize_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp fetch(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    Map.get(@known_keys, normalize_string_token(key), key)
  end

  defp normalize_key(key), do: key

  defp normalize_status(status), do: normalize_token(status, :unknown)

  defp normalize_token(value, _default) when is_atom(value), do: value

  defp normalize_token(value, default) when is_binary(value) do
    value
    |> normalize_string_token()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> default
  end

  defp normalize_token(_value, default), do: default

  defp normalize_string_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
  end

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
