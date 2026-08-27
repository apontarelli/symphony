defmodule SymphonyElixir.PublishPreflight do
  @moduledoc """
  Host-owned publish readiness checks for completed workspace work.

  The preflight is intentionally idempotent: it only reads local VCS metadata,
  performs a git push dry-run, and checks GitHub PR target accessibility.
  """

  alias SymphonyElixir.{Config, ExecutionContext, Shell, SSH}
  alias SymphonyElixir.Workflow.PublishTarget

  @preflight_branch "refs/heads/symphony/publish-preflight"
  @failure_summaries %{
    workspace_vcs_metadata_unavailable: "Workspace VCS metadata is unavailable to the host.",
    remote_push_unavailable: "Remote push dry-run is unavailable to the host.",
    pr_creation_unavailable: "PR creation preflight is unavailable for the configured repository/base branch.",
    delivery_not_allowed: "Pinned target policy does not allow publish preflight."
  }
  @failure_reasons %{
    workspace_vcs_metadata_unavailable: :git_metadata_denied,
    remote_push_unavailable: :github_publish_unavailable,
    pr_creation_unavailable: :github_publish_unavailable,
    delivery_not_allowed: :delivery_not_allowed
  }

  @type failure_class ::
          :workspace_vcs_metadata_unavailable
          | :remote_push_unavailable
          | :pr_creation_unavailable
          | :delivery_not_allowed
  @type capability_map :: %{
          workspace_vcs_metadata: boolean(),
          remote_push: boolean(),
          pr_creation: boolean()
        }
  @type failure :: %{
          class: failure_class(),
          reason: :git_metadata_denied | :github_publish_unavailable | :delivery_not_allowed,
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

  @spec run_context(ExecutionContext.t()) :: result() | {:error, atom()}
  def run_context(context), do: run_context(context, [])

  @spec run_context(ExecutionContext.t(), keyword()) :: result() | {:error, atom()}

  def run_context(%ExecutionContext{} = execution_context, opts) when is_list(opts) do
    with :ok <- validate_implementation_context(execution_context),
         :ok <- validate_context_options(opts),
         {:ok, provenance} <- ExecutionContext.safe_provenance(execution_context) do
      if publish_allowed?(execution_context) do
        execution_context.workspace_path
        |> run_preflight(
          execution_context.policy,
          opts
          |> Keyword.put(:worker_host, execution_context.worker_host)
          |> Keyword.put(:timeout_ms, execution_context.timeout_ms)
          |> Keyword.put(:provenance, provenance)
        )
        |> Map.put(:provenance, provenance)
      else
        blocked_by_delivery_policy(execution_context, provenance)
      end
    end
  end

  def run_context(%ExecutionContext{}, _opts),
    do: {:error, :invalid_publish_preflight_options}

  def run_context(_context, _opts),
    do: {:error, :invalid_publish_preflight_context}

  @doc false
  @spec run_for_test(Path.t() | nil, map(), keyword()) :: result()
  def run_for_test(workspace, policy, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:timeout_ms, Config.settings!().hooks.timeout_ms)
      |> Keyword.put_new_lazy(
        :runner,
        fn -> Application.get_env(:symphony_elixir, :publish_preflight_runner) end
      )

    run_preflight(workspace, policy, opts)
  end

  defp run_preflight(workspace, policy, opts) when is_map(policy) and is_list(opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)

    context = %{
      workspace: workspace,
      worker_host: Keyword.get(opts, :worker_host),
      timeout_ms: timeout_ms,
      runner: configured_runner(opts),
      env: Keyword.get(opts, :env, []),
      provenance: Keyword.get(opts, :provenance)
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
    |> maybe_put_command_provenance(context.provenance)
    |> Map.merge(%{step: step, command: command})
    |> runner.()
    |> normalize_command_result()
  end

  defp execute_command(%{workspace: workspace, worker_host: nil, timeout_ms: timeout_ms, env: env}, _step, command) do
    task =
      Task.async(fn ->
        {output, status} =
          System.cmd("/bin/sh", ["-c", command],
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

  defp maybe_put_command_provenance(command, provenance) when is_map(provenance),
    do: Map.put(command, :provenance, provenance)

  defp maybe_put_command_provenance(command, _provenance), do: command

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
      reason: Map.fetch!(@failure_reasons, class),
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

  defp configured_runner(opts), do: Keyword.get(opts, :runner)

  defp validate_implementation_context(%ExecutionContext{role: :implementation} = context) do
    case ExecutionContext.validate(context) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_publish_preflight_context}
    end
  end

  defp validate_implementation_context(_context),
    do: {:error, :invalid_publish_preflight_context}

  defp validate_context_options(opts) do
    if Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:env, :runner])),
       do: :ok,
       else: {:error, :invalid_publish_preflight_options}
  end

  defp publish_allowed?(%ExecutionContext{target: target}) do
    gates = target.external_side_effect_gates
    gates["vcs_publish"] == "allow" and gates["pull_request_write"] == "allow"
  end

  defp blocked_by_delivery_policy(context, provenance) do
    target = PublishTarget.resolve_policy(context.policy) || empty_publish_target()
    gates = Map.take(context.target.external_side_effect_gates, ["vcs_publish", "pull_request_write"])

    %{
      status: :blocked,
      repository: target.repository,
      base_branch: target.base_branch,
      capabilities: %{
        workspace_vcs_metadata: false,
        remote_push: false,
        pr_creation: false
      },
      failures: [
        failure(
          :delivery_not_allowed,
          nil,
          nil,
          "target delivery gates: #{inspect(gates)}"
        )
      ],
      provenance: provenance
    }
  end
end
