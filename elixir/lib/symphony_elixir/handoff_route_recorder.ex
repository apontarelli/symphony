defmodule SymphonyElixir.HandoffRouteRecorder do
  @moduledoc """
  Records structured handoff route decisions to the configured tracker.
  """

  alias SymphonyElixir.{HandoffRoute, Tracker}

  @completion_keys [
    :checks,
    "checks",
    :review,
    "review",
    :changed_surfaces,
    "changed_surfaces",
    :policy,
    "policy",
    :artifacts,
    "artifacts",
    :decision,
    "decision"
  ]

  @spec classify_completion(map(), map() | nil) :: HandoffRoute.Decision.t()
  def classify_completion(completion, blocker \\ nil) do
    completion = if is_map(completion), do: completion, else: %{}

    %{
      checks: completion_field(completion, :checks, []),
      review: completion_field(completion, :review, %{}),
      changed_surfaces: completion_field(completion, :changed_surfaces, []),
      policy: completion_field(completion, :policy, %{}),
      artifacts: completion_field(completion, :artifacts, []),
      decision: completion_field(completion, :decision, %{}),
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
end
