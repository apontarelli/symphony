defmodule SymphonyElixir.HandoffRoute.PublishPreflightEvidence do
  @moduledoc false

  alias SymphonyElixir.HandoffRoute.Evidence

  @known_keys %{
    "base_branch" => :base_branch,
    "capabilities" => :capabilities,
    "class" => :class,
    "command" => :command,
    "details" => :details,
    "exit_status" => :exit_status,
    "failure_class" => :failure_class,
    "failures" => :failures,
    "pr_creation" => :pr_creation,
    "remote_push" => :remote_push,
    "repository" => :repository,
    "status" => :status,
    "summary" => :summary,
    "workspace_vcs_metadata" => :workspace_vcs_metadata
  }
  @failure_tokens %{
    "workspace_vcs_metadata_unavailable" => :workspace_vcs_metadata_unavailable,
    "remote_push_unavailable" => :remote_push_unavailable,
    "pr_creation_unavailable" => :pr_creation_unavailable
  }
  @status_tokens %{
    "blocked" => :blocked,
    "clean" => :clean,
    "decision_needed" => :decision_needed,
    "error" => :error,
    "failed" => :failed,
    "failure" => :failure,
    "fix_required" => :fix_required,
    "needs_decision" => :needs_decision,
    "needs_input" => :needs_input,
    "ok" => :ok,
    "pass" => :pass,
    "passed" => :passed,
    "success" => :success,
    "unknown" => :unknown
  }

  @spec normalize(term()) :: map() | nil
  def normalize(nil), do: nil

  def normalize(preflight) when is_map(preflight) do
    preflight = normalize_map(preflight)
    capabilities = fetch(preflight, :capabilities, %{}) |> normalize_map()
    failures = fetch(preflight, :failures, []) |> normalize_failures()

    %{
      status: fetch(preflight, :status, status(failures)) |> normalize_status(),
      repository: fetch(preflight, :repository, nil) |> optional_trimmed_string(),
      base_branch: fetch(preflight, :base_branch, nil) |> optional_trimmed_string(),
      capabilities: %{
        workspace_vcs_metadata: fetch(capabilities, :workspace_vcs_metadata, false) == true,
        remote_push: fetch(capabilities, :remote_push, false) == true,
        pr_creation: fetch(capabilities, :pr_creation, false) == true
      },
      failures: failures
    }
  end

  def normalize(_preflight), do: nil

  @spec blocker(map() | nil) :: map() | nil
  def blocker(nil), do: nil
  def blocker(%{failures: []}), do: nil

  def blocker(%{failures: failures}) do
    classes =
      failures
      |> Enum.map(& &1.class)
      |> Enum.map_join(", ", &Atom.to_string/1)

    %{
      reason: "Publish preflight failed: #{classes}",
      required_action: "Restore host VCS/GitHub publish capability before commit, push, or PR creation."
    }
  end

  @spec evidence(map() | nil) :: [Evidence.t()]
  def evidence(nil), do: []

  def evidence(%{failures: []} = preflight) do
    [
      %Evidence{
        kind: :publish_preflight,
        status: :passed,
        summary: "Publish preflight passed for #{preflight.repository || "unknown repository"} targeting #{preflight.base_branch || "unknown base"}.",
        metadata: metadata(preflight)
      }
    ]
  end

  def evidence(%{failures: failures} = preflight) do
    Enum.map(failures, fn failure ->
      %Evidence{
        kind: :publish_preflight,
        status: :blocked,
        summary: failure.summary,
        metadata:
          preflight
          |> metadata()
          |> Map.merge(%{
            failure_class: failure.class,
            command: failure.command,
            exit_status: failure.exit_status,
            details: failure.details
          })
      }
    end)
  end

  defp normalize_failures(failures) when is_list(failures) do
    failures
    |> Enum.map(&normalize_failure/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_failures(_failures), do: []

  defp normalize_failure(failure) when is_map(failure) do
    failure = normalize_map(failure)

    case fetch(failure, :class, fetch(failure, :failure_class, nil)) do
      nil ->
        nil

      class ->
        %{
          class: normalize_token(class, @failure_tokens, :unknown),
          summary: fetch(failure, :summary, "Publish preflight failed.") |> to_string(),
          command: fetch(failure, :command, nil) |> optional_string(),
          exit_status: fetch(failure, :exit_status, nil),
          details: fetch(failure, :details, nil) |> optional_string()
        }
    end
  end

  defp normalize_failure(_failure), do: nil

  defp status([]), do: :passed
  defp status(_failures), do: :blocked

  defp metadata(preflight) do
    %{
      repository: preflight.repository,
      base_branch: preflight.base_branch,
      capabilities: preflight.capabilities
    }
  end

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_map(_map), do: %{}

  defp fetch(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp normalize_status(status), do: normalize_token(status, @status_tokens, :unknown)

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: Map.get(@known_keys, normalize_string_token(key), key)
  defp normalize_key(key), do: key

  defp normalize_token(value, _tokens, _default) when is_atom(value), do: value

  defp normalize_token(value, tokens, default) when is_binary(value) do
    Map.get(tokens, normalize_string_token(value), default)
  end

  defp normalize_token(_value, _tokens, default), do: default

  defp normalize_string_token(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_string(_value), do: nil

  defp optional_trimmed_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_trimmed_string(_value), do: nil
end
