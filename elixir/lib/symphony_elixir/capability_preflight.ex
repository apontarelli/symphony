defmodule SymphonyElixir.CapabilityPreflight do
  @moduledoc """
  Host-owned capability checks that run before a Codex implementation turn.

  These checks are opt-in through `capabilities.required` in the resolved policy.
  Restricted coding runs that do not declare the trusted-local or publish
  capabilities are left unchanged.
  """

  alias SymphonyElixir.{Config, Shell, SSH}
  alias SymphonyElixir.Workflow.PublishTarget

  @tcp_capabilities MapSet.new(["localhost_tcp", "local_tcp", "mix_pubsub_tcp"])
  @git_capabilities MapSet.new(["git_metadata", "git_metadata_write", "git_fetch"])
  @github_capabilities MapSet.new(["github_pr", "github_publish"])
  @git_probe_file "symphony-capability-preflight"
  @github_publish_permission_jq ".permissions.push == true or .permissions.admin == true or .permissions.maintain == true"

  @type reason :: :sandbox_tcp_denied | :git_metadata_denied | :github_publish_unavailable
  @type failure :: %{
          reason: reason(),
          summary: String.t(),
          required_action: String.t(),
          details: String.t() | nil
        }
  @type result :: %{status: :passed | :blocked, failures: [failure()]}

  @spec run(Path.t(), map(), keyword()) :: result()
  def run(workspace, policy, opts \\ []) when is_binary(workspace) and is_map(policy) and is_list(opts) do
    required = required_capabilities(policy)

    failures =
      []
      |> maybe_check(required, @tcp_capabilities, fn -> localhost_tcp_result(workspace, policy, opts) end)
      |> maybe_check(required, @git_capabilities, fn -> git_metadata_result(workspace, opts) end)
      |> maybe_check(required, @github_capabilities, fn -> github_publish_result(workspace, policy, opts) end)

    %{status: if(failures == [], do: :passed, else: :blocked), failures: Enum.reverse(failures)}
  end

  @spec blocker(result()) :: map() | nil
  def blocker(%{failures: []}), do: nil

  def blocker(%{failures: failures}) do
    %{
      reason: failures |> Enum.map(& &1.reason) |> Enum.uniq() |> Enum.map_join(", ", &Atom.to_string/1),
      required_action: failures |> Enum.map(& &1.required_action) |> Enum.uniq() |> Enum.join(" ")
    }
  end

  defp maybe_check(failures, required, supported, fun) do
    if Enum.any?(supported, &MapSet.member?(required, &1)) do
      case fun.() do
        :ok -> failures
        %{reason: _reason} = failure -> [failure | failures]
      end
    else
      failures
    end
  end

  defp localhost_tcp_result(workspace, policy, opts) do
    if Keyword.has_key?(opts, :tcp_probe) do
      opts |> Keyword.fetch!(:tcp_probe) |> run_tcp_probe()
    else
      default_localhost_tcp_result(workspace, policy, opts)
    end
  end

  defp default_localhost_tcp_result(workspace, policy, opts) do
    with :ok <- turn_sandbox_tcp_result(workspace, policy, opts) do
      tcp_result_to_failure(default_tcp_probe(workspace, opts))
    end
  end

  defp tcp_result_to_failure(:ok), do: :ok
  defp tcp_result_to_failure({:error, reason}), do: localhost_tcp_failure(reason)

  defp run_tcp_probe(tcp_probe) do
    case tcp_probe.() do
      :ok -> :ok
      {:error, reason} -> localhost_tcp_failure(reason)
    end
  end

  defp turn_sandbox_tcp_result(workspace, policy, opts) do
    case turn_sandbox_policy(workspace, policy, opts) do
      {:ok, turn_sandbox_policy} ->
        if turn_sandbox_allows_tcp?(turn_sandbox_policy) do
          :ok
        else
          localhost_tcp_failure("turn_sandbox_policy.networkAccess is false")
        end

      {:error, reason} ->
        localhost_tcp_failure(reason)
    end
  end

  defp turn_sandbox_policy(workspace, policy, opts) do
    case Keyword.fetch(opts, :turn_sandbox_policy) do
      {:ok, turn_sandbox_policy} when is_map(turn_sandbox_policy) ->
        {:ok, turn_sandbox_policy}

      {:ok, other} ->
        {:error, {:invalid_turn_sandbox_policy, other}}

      :error ->
        runtime_opts =
          if is_binary(Keyword.get(opts, :worker_host)) do
            [policy: policy, remote: true]
          else
            [policy: policy]
          end

        case Config.codex_runtime_settings(workspace, runtime_opts) do
          {:ok, %{turn_sandbox_policy: turn_sandbox_policy}} -> {:ok, turn_sandbox_policy}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp turn_sandbox_allows_tcp?(%{} = policy) do
    policy_type = Map.get(policy, "type", Map.get(policy, :type))
    network_access = Map.get(policy, "networkAccess", Map.get(policy, :networkAccess))

    policy_type in ["dangerFullAccess", :dangerFullAccess, "danger-full-access", :danger_full_access] or network_access == true
  end

  defp default_tcp_probe(workspace, opts) do
    if is_function(Keyword.get(opts, :runner), 1) or is_binary(Keyword.get(opts, :worker_host)) do
      case run_command(workspace, Keyword.get(opts, :worker_host), Keyword.get(opts, :runner), :localhost_tcp, tcp_probe_command(), opts) do
        {:ok, %{status: 0}} -> :ok
        {:ok, %{output: output}} -> {:error, output}
        {:error, reason} -> {:error, reason}
      end
    else
      local_tcp_probe(
        Keyword.get(opts, :tcp_listen, &:gen_tcp.listen/2),
        Keyword.get(opts, :tcp_close, &:gen_tcp.close/1)
      )
    end
  end

  defp local_tcp_probe(tcp_listen, tcp_close) do
    case tcp_listen.(0, [:binary, ip: {127, 0, 0, 1}, active: false]) do
      {:ok, socket} ->
        tcp_close.(socket)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tcp_probe_command do
    elixir_probe =
      ":gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false]) " <>
        "|> case do {:ok, socket} -> :gen_tcp.close(socket); {:error, reason} -> IO.puts(:stderr, inspect(reason)); System.halt(1) end"

    "elixir -e #{Shell.escape(elixir_probe)}"
  end

  defp localhost_tcp_failure(details) do
    failure(
      :sandbox_tcp_denied,
      "Localhost TCP listen capability is unavailable.",
      "Run trusted-local validation with localhost TCP enabled for Mix/Phoenix PubSub checks.",
      sanitize_output(inspect_details(details))
    )
  end

  defp git_metadata_result(workspace, opts) do
    case run_command(workspace, Keyword.get(opts, :worker_host), Keyword.get(opts, :runner), :git_metadata, git_metadata_command(), opts) do
      {:ok, %{status: 0}} ->
        :ok

      {:ok, %{output: output}} ->
        git_metadata_failure(output)

      {:error, reason} ->
        git_metadata_failure(inspect(reason))
    end
  end

  defp git_metadata_command do
    git_probe =
      [
        "git_dir=$(git rev-parse --git-dir)",
        "test -n \"$git_dir\"",
        "touch \"$git_dir/#{@git_probe_file}\"",
        "rm -f \"$git_dir/#{@git_probe_file}\"",
        "(git fetch --dry-run origin HEAD >/dev/null 2>&1 || git fetch --dry-run >/dev/null)"
      ]
      |> Enum.join(" && ")

    jj_probe =
      [
        "jj root >/dev/null 2>&1",
        "jj git remote list | grep -E '^origin[[:space:]]' >/dev/null"
      ]
      |> Enum.join(" && ")

    "(#{git_probe}) || (#{jj_probe})"
  end

  defp git_metadata_failure(details) do
    failure(
      :git_metadata_denied,
      "Git metadata write/fetch capability is unavailable.",
      "Run trusted-local validation or host-owned delivery with permission to write Git metadata and fetch the target remote.",
      sanitize_output(details)
    )
  end

  defp github_publish_result(workspace, policy, opts) do
    case PublishTarget.resolve_policy(policy) do
      %{github_repository: github_repository, base_branch: base_branch}
      when is_binary(github_repository) and is_binary(base_branch) ->
        command = github_publish_command(github_repository, base_branch)

        case run_command(workspace, Keyword.get(opts, :worker_host), Keyword.get(opts, :runner), :github_publish, command, opts) do
          {:ok, %{status: 0}} -> :ok
          {:ok, %{output: output}} -> github_publish_failure(output)
          {:error, reason} -> github_publish_failure(inspect(reason))
        end

      _target ->
        github_publish_failure("publish target is missing a GitHub repository or base branch")
    end
  end

  defp github_publish_command(github_repository, base_branch) do
    branch_probe = "gh api #{Shell.escape("repos/#{github_repository}/branches/#{URI.encode_www_form(base_branch)}")} >/dev/null"

    permission_probe =
      "test \"$(gh api #{Shell.escape("repos/#{github_repository}")} --jq #{Shell.escape(@github_publish_permission_jq)})\" = true"

    "#{branch_probe} && #{permission_probe}"
  end

  defp github_publish_failure(details) do
    failure(
      :github_publish_unavailable,
      "GitHub publish capability is unavailable.",
      "Authenticate GitHub CLI/API access and remote publish permission for the configured repository before PR handoff.",
      sanitize_output(details)
    )
  end

  defp run_command(workspace, worker_host, runner, step, command, opts) do
    timeout_ms = timeout_ms(opts)

    task =
      Task.async(fn ->
        safe_execute_command(workspace, worker_host, runner, step, command, timeout_ms, Keyword.get(opts, :env, []))
      end)

    yield_command(task, timeout_ms, step)
  end

  defp safe_execute_command(workspace, worker_host, runner, step, command, timeout_ms, env) do
    execute_command(workspace, worker_host, runner, step, command, timeout_ms, env)
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute_command(workspace, worker_host, runner, step, command, timeout_ms, env) when is_function(runner, 1) do
    %{
      workspace: workspace,
      worker_host: worker_host,
      step: step,
      command: command,
      timeout_ms: timeout_ms,
      env: env
    }
    |> runner.()
    |> normalize_command_result()
  end

  defp execute_command(workspace, nil, _runner, _step, command, _timeout_ms, env) do
    if File.dir?(workspace) do
      {output, status} = System.cmd("/bin/sh", ["-c", command], cd: workspace, env: env, stderr_to_stdout: true)
      {:ok, %{status: status, output: output}}
    else
      {:error, {:workspace_not_found, workspace}}
    end
  end

  defp execute_command(workspace, worker_host, _runner, _step, command, _timeout_ms, _env) when is_binary(worker_host) do
    case SSH.run(worker_host, "cd #{Shell.escape(workspace)} && #{command}", stderr_to_stdout: true) do
      {:ok, {output, status}} -> {:ok, %{status: status, output: output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp yield_command(task, timeout_ms, step) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> normalize_command_result(result)
      nil -> {:error, {:capability_preflight_timeout, step, timeout_ms}}
    end
  end

  defp normalize_command_result({:ok, %{status: status, output: output}})
       when is_integer(status) and is_binary(output) do
    {:ok, %{status: status, output: output}}
  end

  defp normalize_command_result({:error, reason}), do: {:error, reason}
  defp normalize_command_result(other), do: {:error, {:invalid_preflight_result, other}}

  defp required_capabilities(policy) do
    policy
    |> capability_list()
    |> Enum.map(&normalize_capability/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp capability_list(policy) do
    direct = get_in(policy, ["capabilities", "required"]) || get_in(policy, [:capabilities, :required])
    manifest = get_in(policy, ["manifest", "capabilities", "required"]) || get_in(policy, [:manifest, :capabilities, :required])

    case direct do
      nil -> List.wrap(manifest)
      capabilities -> List.wrap(capabilities)
    end
  end

  defp normalize_capability(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp failure(reason, summary, required_action, details) do
    %{
      reason: reason,
      summary: summary,
      required_action: required_action,
      details: details
    }
  end

  defp sanitize_output(output) do
    output
    |> IO.iodata_to_binary()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> binary_part(trimmed, 0, min(byte_size(trimmed), 2_048))
    end
  end

  defp inspect_details(details) when is_binary(details), do: details
  defp inspect_details(details), do: inspect(details)

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _timeout -> Config.settings!().hooks.timeout_ms
    end
  end
end
