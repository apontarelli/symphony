defmodule SymphonyElixir.PublishPreflight do
  @moduledoc """
  Host-owned publish readiness checks for completed workspace work.

  The preflight is intentionally idempotent: it only reads local VCS metadata,
  performs a git push dry-run, and checks GitHub PR target accessibility.
  """

  alias SymphonyElixir.{Config, Shell, SSH}
  alias SymphonyElixir.Workflow.PublishTarget

  @preflight_branch "refs/heads/symphony/publish-preflight"
  @failure_summaries %{
    workspace_vcs_metadata_unavailable: "Workspace VCS metadata is unavailable to the host.",
    remote_push_unavailable: "Remote push dry-run is unavailable to the host.",
    pr_creation_unavailable: "PR creation preflight is unavailable for the configured repository/base branch."
  }

  @type failure_class ::
          :workspace_vcs_metadata_unavailable | :remote_push_unavailable | :pr_creation_unavailable
  @type capability_map :: %{
          workspace_vcs_metadata: boolean(),
          remote_push: boolean(),
          pr_creation: boolean()
        }
  @type failure :: %{
          class: failure_class(),
          summary: String.t(),
          command: String.t() | nil,
          exit_status: non_neg_integer() | nil,
          details: String.t() | nil
        }
  @type result :: %{
          status: :passed | :blocked,
          repository: String.t() | nil,
          base_branch: String.t() | nil,
          capabilities: capability_map(),
          failures: [failure()]
        }

  @spec run(Path.t() | nil, map(), keyword()) :: result()
  def run(workspace, policy, opts \\ []) when is_map(policy) and is_list(opts) do
    context = %{
      workspace: workspace,
      worker_host: Keyword.get(opts, :worker_host),
      timeout_ms: Keyword.get(opts, :timeout_ms, default_timeout_ms()),
      runner: Keyword.get(opts, :runner) || Application.get_env(:symphony_elixir, :publish_preflight_runner),
      env: Keyword.get(opts, :env, [])
    }

    publish_target = PublishTarget.resolve_policy(policy) || empty_publish_target()
    repository = publish_target.repository
    base_branch = publish_target.base_branch

    {metadata_capable?, metadata_failures} = workspace_vcs_metadata_result(context)
    {remote_capable?, remote_failures} = remote_push_result(context, metadata_capable?)
    {pr_capable?, pr_failures} = pr_creation_result(context, publish_target)

    failures = metadata_failures ++ remote_failures ++ pr_failures

    %{
      status: if(failures == [], do: :passed, else: :blocked),
      repository: repository,
      base_branch: base_branch,
      capabilities: %{
        workspace_vcs_metadata: metadata_capable?,
        remote_push: remote_capable?,
        pr_creation: pr_capable?
      },
      failures: failures
    }
  end

  defp workspace_vcs_metadata_result(%{workspace: workspace} = context) do
    cond do
      not valid_workspace_path?(workspace) ->
        {false, [failure(:workspace_vcs_metadata_unavailable, nil, nil, "workspace path is missing")]}

      is_nil(context.worker_host) and not File.dir?(workspace) ->
        {false, [failure(:workspace_vcs_metadata_unavailable, nil, nil, "workspace path does not exist")]}

      true ->
        run_step(
          context,
          :workspace_vcs_metadata,
          "git rev-parse --git-dir >/dev/null 2>&1 || jj root >/dev/null 2>&1",
          :workspace_vcs_metadata_unavailable
        )
    end
  end

  defp remote_push_result(_context, false), do: {false, []}

  defp remote_push_result(context, true) do
    run_step(
      context,
      :remote_push,
      "(" <>
        "git remote get-url --push origin >/dev/null 2>&1 && " <>
        "git push --dry-run --porcelain origin HEAD:#{@preflight_branch} >/dev/null" <>
        ") || (" <>
        "jj git remote list | grep -E '^origin[[:space:]]' >/dev/null && " <>
        "jj git push --dry-run --remote origin --change @ >/dev/null" <>
        ")",
      :remote_push_unavailable
    )
  end

  defp pr_creation_result(_context, %{repository: nil}) do
    {false, [failure(:pr_creation_unavailable, nil, nil, "publish repository is missing")]}
  end

  defp pr_creation_result(_context, %{base_branch: nil}) do
    {false, [failure(:pr_creation_unavailable, nil, nil, "publish base branch is missing")]}
  end

  defp pr_creation_result(_context, %{github_repository: nil}) do
    {false, [failure(:pr_creation_unavailable, nil, nil, "publish repository is not a GitHub repository")]}
  end

  defp pr_creation_result(context, %{github_repository: slug, base_branch: base_branch}) do
    branch = URI.encode_www_form(base_branch)

    run_step(
      context,
      :pr_creation,
      "gh api #{Shell.escape("repos/#{slug}/branches/#{branch}")} >/dev/null",
      :pr_creation_unavailable
    )
  end

  defp run_step(context, step, command, failure_class) do
    case execute_command(context, step, command) do
      {:ok, %{status: 0}} ->
        {true, []}

      {:ok, %{status: status, output: output}} ->
        {false, [failure(failure_class, command, status, sanitize_output(output))]}

      {:error, reason} ->
        {false, [failure(failure_class, command, nil, inspect(reason))]}
    end
  end

  defp execute_command(%{runner: runner} = context, step, command) when is_function(runner, 1) do
    context
    |> Map.take([:workspace, :worker_host, :timeout_ms, :env])
    |> Map.merge(%{step: step, command: command})
    |> runner.()
    |> normalize_command_result()
  end

  defp execute_command(%{workspace: workspace, worker_host: nil, timeout_ms: timeout_ms, env: env}, _step, command) do
    task =
      Task.async(fn ->
        {output, status} =
          System.cmd("/bin/sh", ["-lc", command],
            cd: workspace,
            env: env,
            stderr_to_stdout: true
          )

        {:ok, %{status: status, output: output}}
      end)

    yield_command(task, timeout_ms)
  end

  defp execute_command(%{workspace: workspace, worker_host: worker_host, timeout_ms: timeout_ms}, _step, command)
       when is_binary(worker_host) do
    task =
      Task.async(fn ->
        case SSH.run(worker_host, "cd #{Shell.escape(workspace)} && #{command}", stderr_to_stdout: true) do
          {:ok, {output, status}} -> {:ok, %{status: status, output: output}}
          {:error, reason} -> {:error, reason}
        end
      end)

    yield_command(task, timeout_ms)
  end

  defp yield_command(task, timeout_ms) do
    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        normalize_command_result(result)

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:publish_preflight_timeout, timeout_ms}}
    end
  end

  defp normalize_command_result({:ok, %{status: status, output: output}})
       when is_integer(status) and is_binary(output) do
    {:ok, %{status: status, output: output}}
  end

  defp normalize_command_result({:error, reason}), do: {:error, reason}

  defp failure(class, command, exit_status, details) do
    %{
      class: class,
      summary: Map.fetch!(@failure_summaries, class),
      command: command,
      exit_status: exit_status,
      details: details
    }
  end

  defp empty_publish_target, do: %{repository: nil, base_branch: nil, github_repository: nil}

  defp valid_workspace_path?(workspace), do: is_binary(workspace) and String.trim(workspace) != ""

  defp sanitize_output(output) do
    output
    |> IO.iodata_to_binary()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> binary_part(trimmed, 0, min(byte_size(trimmed), 2_048))
    end
  end

  defp default_timeout_ms do
    Config.settings!().hooks.timeout_ms
  end
end
