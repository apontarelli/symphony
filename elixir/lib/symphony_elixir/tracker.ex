defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.{Config, RunTarget, TrackerCoordinator}

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback resolve_candidate_issues(RunTarget.t() | nil) ::
              {:ok, RunTarget.Resolution.t()} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, %RunTarget.Resolution{issues: issues}} <- resolve_candidate_issues() do
      {:ok, issues}
    end
  end

  @spec resolve_candidate_issues(RunTarget.t() | nil) ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_candidate_issues(target \\ nil) do
    TrackerCoordinator.resolve_candidate_issues(
      target,
      fn -> adapter().resolve_candidate_issues(target) end,
      cache_key: candidate_cache_key(target)
    )
  end

  @spec resolve_candidate_issues_uncached(RunTarget.t() | nil) ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_candidate_issues_uncached(target \\ nil) do
    adapter().resolve_candidate_issues(target)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  defp candidate_cache_key(target) do
    settings = Config.settings!()
    tracker = settings.tracker

    %{
      adapter: adapter(),
      target: configured_cache_target(target, settings),
      tracker:
        Map.take(tracker, [
          :kind,
          :endpoint,
          :project_id,
          :project_slug,
          :team_key,
          :issue_ids,
          :active_states,
          :required_labels,
          :assignee,
          :workspace_slug
        ]),
      api_key_hash: secret_fingerprint(Map.get(tracker, :api_key)),
      repo_markers: RunTarget.repo_markers(settings),
      memory_tracker: memory_tracker_cache_scope(tracker.kind)
    }
  end

  defp configured_cache_target(%RunTarget{} = target, _settings), do: target

  defp configured_cache_target(nil, settings) do
    case RunTarget.from_settings(settings) do
      {:ok, %RunTarget{} = target} -> target
      {:error, reason} -> {:unresolved, reason}
    end
  end

  defp memory_tracker_cache_scope("memory") do
    %{
      issues: Application.get_env(:symphony_elixir, :memory_tracker_issues, []),
      errors: Application.get_env(:symphony_elixir, :memory_tracker_errors, %{})
    }
  end

  defp memory_tracker_cache_scope(_kind), do: nil

  defp secret_fingerprint(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
  end

  defp secret_fingerprint(_secret), do: nil

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
