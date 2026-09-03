defmodule SymphonyElixir.LandingRevalidation do
  @moduledoc """
  Reads the current pull-request and target state before a landing worker starts.

  The landing worker remains responsible for refresh, conflict resolution, final
  checks, and the merge. This gate prevents known-blocked work from occupying the
  single target landing slot and records the target revision used for selection.
  """

  alias SymphonyElixir.LandingQueue.Entry

  @json_fields Enum.join(
                 ~w(baseRefName baseRefOid headRefName headRefOid isDraft mergeable mergeStateStatus reviewDecision state statusCheckRollup url),
                 ","
               )
  @successful_check_values ~w(SUCCESS NEUTRAL SKIPPED)
  @refresh_states ~w(BEHIND DIRTY)
  @command_timeout_ms 30_000

  @type result :: %{
          required(:status) => :ready | :refresh_required | :blocked | :failed,
          required(:checked_at) => String.t(),
          optional(atom()) => term()
        }

  @spec check(Entry.t(), keyword()) :: result()
  def check(entry, opts \\ []) do
    if match?(%Entry{}, entry) and is_list(opts) do
      check_entry(entry, opts)
    else
      failed_result(DateTime.utc_now(), :invalid_landing_queue_entry)
    end
  end

  defp check_entry(%Entry{} = entry, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    runner = Keyword.get(opts, :runner, &run_command/3)

    with :ok <- validate_entry_identity(entry),
         true <- match?(%DateTime{}, now),
         true <- is_function(runner, 3),
         {:ok, output} <- run_pr_view(entry, runner),
         {:ok, payload} <- Jason.decode(output),
         :ok <- validate_payload_identity(payload, entry) do
      classify(payload, now)
    else
      {:error, reason} -> failed_result(now, reason)
      false -> failed_result(now, :invalid_revalidation_options)
    end
  end

  defp validate_entry_identity(%Entry{} = entry) do
    if Enum.all?([entry.pr_url, entry.repository, entry.base_branch, entry.branch], &present?/1) do
      :ok
    else
      {:error, :publish_evidence_missing}
    end
  end

  defp run_pr_view(entry, runner) do
    args = [
      "pr",
      "view",
      entry.pr_url,
      "--repo",
      entry.repository,
      "--json",
      @json_fields
    ]

    case runner.("gh", args, []) do
      {:ok, %{status: 0, output: output}} when is_binary(output) ->
        {:ok, output}

      {:ok, %{status: status, output: output}} when is_integer(status) and is_binary(output) ->
        {:error, {:github_revalidation_failed, status, sanitize(output)}}

      {:error, reason} ->
        {:error, {:github_revalidation_failed, reason}}

      other ->
        {:error, {:github_revalidation_invalid_result, other}}
    end
  end

  defp validate_payload_identity(payload, entry) when is_map(payload) do
    with true <- present?(payload["url"]),
         true <- payload["url"] == entry.pr_url,
         true <- payload["baseRefName"] == entry.base_branch,
         true <- payload["headRefName"] == entry.branch,
         true <- present?(payload["baseRefOid"]),
         true <- present?(payload["headRefOid"]),
         true <- is_boolean(payload["isDraft"]),
         true <- payload["state"] in ["OPEN", "CLOSED", "MERGED"],
         true <- payload["mergeable"] in ["MERGEABLE", "CONFLICTING", "UNKNOWN"],
         true <- is_binary(payload["mergeStateStatus"]),
         true <- is_list(payload["statusCheckRollup"]) do
      :ok
    else
      _invalid -> {:error, :github_revalidation_identity_mismatch}
    end
  end

  defp validate_payload_identity(_payload, _entry), do: {:error, :github_revalidation_payload_invalid}

  defp classify(payload, now) do
    evidence = %{
      checked_at: DateTime.to_iso8601(now),
      pr_url: payload["url"],
      target_branch: payload["baseRefName"],
      target_revision: payload["baseRefOid"],
      head_branch: payload["headRefName"],
      head_revision: payload["headRefOid"],
      mergeable: payload["mergeable"],
      merge_state: payload["mergeStateStatus"],
      review_decision: payload["reviewDecision"],
      checks: summarize_checks(payload["statusCheckRollup"])
    }

    cond do
      payload["state"] != "OPEN" ->
        Map.merge(evidence, %{status: :blocked, reason: :pull_request_not_open})

      payload["isDraft"] ->
        Map.merge(evidence, %{status: :blocked, reason: :pull_request_draft})

      payload["mergeable"] == "CONFLICTING" ->
        Map.merge(evidence, %{status: :refresh_required, reason: :merge_conflict})

      payload["mergeStateStatus"] in @refresh_states ->
        Map.merge(evidence, %{status: :refresh_required, reason: :target_refresh_required})

      payload["mergeable"] == "MERGEABLE" and payload["mergeStateStatus"] == "CLEAN" and
          checks_passed?(payload["statusCheckRollup"]) ->
        Map.merge(evidence, %{status: :ready, reason: :merge_gate_clear})

      true ->
        Map.merge(evidence, %{status: :blocked, reason: blocked_reason(payload)})
    end
  end

  defp blocked_reason(%{"mergeable" => "UNKNOWN"}), do: :mergeability_unknown

  defp blocked_reason(%{"statusCheckRollup" => checks}) do
    if checks_passed?(checks), do: :merge_policy_blocked, else: :required_checks_not_passed
  end

  defp checks_passed?(checks) when is_list(checks), do: Enum.all?(checks, &check_passed?/1)
  defp checks_passed?(_checks), do: false

  defp check_passed?(check) when is_map(check) do
    case check["__typename"] do
      "CheckRun" -> check["status"] == "COMPLETED" and check["conclusion"] in @successful_check_values
      "StatusContext" -> check["state"] in @successful_check_values
      _unknown -> false
    end
  end

  defp check_passed?(_check), do: false

  defp summarize_checks(checks) when is_list(checks) do
    %{
      total: length(checks),
      passed: Enum.count(checks, &check_passed?/1),
      blocking: Enum.count(checks, &(not check_passed?(&1)))
    }
  end

  defp failed_result(%DateTime{} = now, reason) do
    %{status: :failed, checked_at: DateTime.to_iso8601(now), reason: reason}
  end

  defp failed_result(_now, reason), do: failed_result(DateTime.utc_now(), reason)

  defp run_command(command, args, opts) do
    case System.find_executable(command) do
      nil ->
        {:error, {:command_not_found, command}}

      executable ->
        task =
          Task.async(fn ->
            try do
              {output, status} =
                System.cmd(executable, args, Keyword.merge([stderr_to_stdout: true], opts))

              {:ok, %{status: status, output: output}}
            rescue
              exception -> {:error, {:command_failed, Exception.message(exception)}}
            end
          end)

        case Task.yield(task, @command_timeout_ms) do
          {:ok, result} ->
            result

          nil ->
            Task.shutdown(task, :brutal_kill)
            {:error, {:command_timeout, @command_timeout_ms}}
        end
    end
  end

  defp sanitize(output) when is_binary(output) do
    output
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
