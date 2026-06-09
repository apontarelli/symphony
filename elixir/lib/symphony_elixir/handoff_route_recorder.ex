defmodule SymphonyElixir.HandoffRouteRecorder do
  @moduledoc """
  Records structured handoff route decisions to the configured tracker.
  """

  alias SymphonyElixir.{HandoffManifest, HandoffRoute, PathSafety, Tracker}

  @completion_keys [
    :checks,
    "checks",
    :changed_files,
    "changed_files",
    :changedFiles,
    "changedFiles",
    :change_manifest,
    "change_manifest",
    :changeManifest,
    "changeManifest",
    :review,
    "review",
    :changed_surfaces,
    "changed_surfaces",
    :policy,
    "policy",
    :artifacts,
    "artifacts",
    :decision,
    "decision",
    :publish_preflight,
    "publish_preflight",
    :publish_handoff,
    "publish_handoff",
    :publishHandoff,
    "publishHandoff"
  ]

  @spec classify_completion(term(), map() | nil, Path.t() | nil, String.t() | nil) ::
          HandoffRoute.Decision.t()
  def classify_completion(completion, blocker \\ nil, workspace \\ nil, worker_host \\ nil) do
    completion = if is_map(completion), do: completion, else: %{}

    checks =
      completion_field(completion, :checks, [])
      |> add_handoff_manifest_check(completion, workspace, worker_host)

    %{
      checks: checks,
      review: completion_field(completion, :review, %{}),
      changed_surfaces: completion_field(completion, :changed_surfaces, []),
      policy: completion_field(completion, :policy, %{}),
      artifacts: completion_field(completion, :artifacts, []),
      decision: completion_field(completion, :decision, %{}),
      publish_preflight: completion_field(completion, :publish_preflight, nil),
      publish_handoff: completion_field(completion, :publish_handoff, nil),
      blocker: blocker
    }
    |> HandoffRoute.classify()
  end

  @spec completion_metadata?(term()) :: boolean()
  def completion_metadata?(completion) when is_map(completion) do
    Enum.any?(@completion_keys, &Map.has_key?(completion, &1))
  end

  def completion_metadata?(_completion), do: false

  @spec record(String.t(), HandoffRoute.Decision.t()) :: :ok | {:error, term()}
  def record(issue_id, %HandoffRoute.Decision{} = decision) when is_binary(issue_id) do
    with :ok <- Tracker.create_comment(issue_id, HandoffRoute.format_comment(decision)) do
      Tracker.update_issue_state(issue_id, decision.target_state)
    end
  end

  defp completion_field(completion, key, default) do
    Map.get(completion, key, Map.get(completion, to_string(key), default))
  end

  defp add_handoff_manifest_check(checks, completion, workspace, worker_host) do
    checks = if is_list(checks), do: checks, else: []

    case HandoffManifest.source(completion) do
      :absent ->
        if completion_metadata?(completion) do
          checks ++ [handoff_manifest_check(%{}, workspace, worker_host)]
        else
          checks
        end

      {:present, manifest} ->
        checks ++ [handoff_manifest_check(manifest, workspace, worker_host)]

      {:failed, failure} ->
        checks ++ [failed_handoff_manifest_check(failure)]
    end
  end

  defp handoff_manifest_check(_manifest, _workspace, worker_host)
       when is_binary(worker_host) and worker_host != "" do
    %{
      name: "change_manifest",
      status: :failed,
      summary: "Changed-file manifest rejected: remote workspace validation is unavailable.",
      metadata: %{
        failures: [
          %{
            path: "<workspace>",
            reason: :remote_workspace_validation_unavailable,
            message: "Host-side changed-file manifest validation cannot resolve remote workspace paths or symlinks.",
            metadata: %{worker_host: worker_host}
          }
        ]
      }
    }
  end

  defp handoff_manifest_check(_manifest, workspace, _worker_host) when not is_binary(workspace) do
    %{
      name: "change_manifest",
      status: :failed,
      summary: "Changed-file manifest rejected: workspace path is unavailable for host validation.",
      metadata: %{
        failures: [
          %{
            path: "<workspace>",
            reason: :missing_workspace,
            message: "Workspace path is required to validate changed-file manifest containment.",
            metadata: %{}
          }
        ]
      }
    }
  end

  defp handoff_manifest_check(manifest, workspace, _worker_host) do
    case PathSafety.validate_handoff_manifest(workspace, manifest) do
      {:ok, %{changed_files: changed_files, validation: validation}} ->
        %{
          name: "change_manifest",
          status: :passed,
          summary: "Changed-file manifest validated: #{length(changed_files)} file(s).",
          metadata: %{changed_files: changed_files, validation: validation}
        }

      {:error, %{summary: summary, failures: failures}} ->
        %{
          name: "change_manifest",
          status: :failed,
          summary: summary,
          metadata: %{failures: failures}
        }
    end
  end

  defp failed_handoff_manifest_check(failure) do
    %{
      name: "change_manifest",
      status: :failed,
      summary: "Changed-file manifest rejected: 1 failure(s): #{failure.reason}",
      metadata: %{failures: [failure]}
    }
  end
end
