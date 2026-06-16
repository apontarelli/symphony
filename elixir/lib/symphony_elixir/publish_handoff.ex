defmodule SymphonyElixir.PublishHandoff do
  @moduledoc """
  Host-owned publication for completed workspace changes.

  Publish handoff is intentionally narrower than the preflight. It only runs
  after the completed turn supplied a safe changed-file manifest and preflight
  proved that the host can push and create a PR for the resolved target.
  """

  import Bitwise, only: [&&&: 2]

  alias SymphonyElixir.{Config, HandoffManifest, PathSafety, PrBody}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.PublishTarget

  @passed_statuses MapSet.new([:passed, :pass, :success, :clean, :ok])
  @known_keys %{
    "base_branch" => :base_branch,
    "capabilities" => :capabilities,
    "failures" => :failures,
    "name" => :name,
    "publish_preflight" => :publish_preflight,
    "status" => :status,
    "summary" => :summary
  }
  @status_tokens %{
    "clean" => :clean,
    "ok" => :ok,
    "pass" => :pass,
    "passed" => :passed,
    "success" => :success,
    "unknown" => :unknown
  }

  @type command_result :: %{status: non_neg_integer(), output: String.t()}
  @type failure :: %{
          reason: atom(),
          summary: String.t(),
          step: atom() | nil,
          command: String.t() | nil,
          args: [String.t()],
          exit_status: non_neg_integer() | nil,
          details: String.t() | nil,
          metadata: map()
        }
  @type result :: %{
          status: :passed | :blocked,
          attempted: boolean(),
          repository: String.t() | nil,
          github_repository: String.t() | nil,
          base_branch: String.t() | nil,
          branch: String.t() | nil,
          pr_url: String.t() | nil,
          change_id: String.t() | nil,
          commit_sha: String.t() | nil,
          validation_summary: String.t() | nil,
          linear_issue: map(),
          failure: failure() | nil
        }

  @spec run(Path.t() | nil, map(), Issue.t() | map() | nil, map(), keyword()) :: result()
  def run(workspace, policy, issue, completion, opts \\ [])
      when is_map(policy) and is_map(completion) and is_list(opts) do
    env = Keyword.get(opts, :env, [])

    context = %{
      workspace: workspace,
      worker_host: Keyword.get(opts, :worker_host),
      timeout_ms: Keyword.get(opts, :timeout_ms, default_timeout_ms()),
      runner: Keyword.get(opts, :runner) || Application.get_env(:symphony_elixir, :publish_handoff_runner),
      env: if(is_list(env), do: env, else: [])
    }

    target = PublishTarget.resolve_policy(policy) || empty_publish_target()
    branch = branch_name(issue)
    linear_issue = linear_issue(issue)
    validation_summary = validation_summary(completion)
    mode = vcs_mode(policy)

    result_base = %{
      status: :blocked,
      attempted: false,
      repository: target.repository,
      github_repository: target.github_repository,
      base_branch: target.base_branch,
      branch: branch,
      pr_url: nil,
      change_id: nil,
      commit_sha: nil,
      validation_summary: validation_summary,
      linear_issue: linear_issue,
      failure: nil
    }

    with :ok <- require_publish_target(target),
         :ok <- require_supported_vcs_mode(mode),
         :ok <- validate_local_workspace(context),
         :ok <- require_preflight_passed(completion),
         {:ok, manifest_result} <- validate_change_manifest(completion, workspace),
         pr_body <- pr_body(issue, target, branch, validation_summary, manifest_result.changed_files),
         :ok <- validate_pr_body(pr_body) do
      publish_context =
        Map.merge(context, %{
          target: target,
          vcs_mode: mode,
          branch: branch,
          issue: issue,
          linear_issue: linear_issue,
          validation_summary: validation_summary,
          changed_files: manifest_result.changed_files,
          commit_message: commit_message(issue),
          pr_title: pr_title(issue),
          pr_body: pr_body
        })

      with :ok <- verify_publish_remote(mode, publish_context),
           :ok <- validate_vcs_payload(mode, publish_context) do
        publish_with_vcs(mode, publish_context)
      end
      |> merge_result(result_base)
    else
      {:blocked, failure} -> %{result_base | failure: failure}
    end
  end

  defp validate_local_workspace(%{worker_host: worker_host}) when is_binary(worker_host) and worker_host != "" do
    {:blocked,
     failure(
       :remote_publish_unavailable,
       "Host publish is unavailable for remote worker workspaces.",
       nil,
       nil,
       [],
       nil,
       nil,
       %{worker_host: worker_host}
     )}
  end

  defp validate_local_workspace(%{workspace: workspace}) when is_binary(workspace) do
    if String.trim(workspace) != "" and File.dir?(workspace) do
      :ok
    else
      {:blocked, failure(:workspace_unavailable, "Workspace path is unavailable for host publish.", nil, nil, [], nil, nil, %{})}
    end
  end

  defp validate_local_workspace(_context) do
    {:blocked, failure(:workspace_unavailable, "Workspace path is unavailable for host publish.", nil, nil, [], nil, nil, %{})}
  end

  defp require_preflight_passed(completion) do
    case fetch(completion, :publish_preflight, nil) do
      preflight when is_map(preflight) ->
        preflight = normalize_map(preflight)

        if MapSet.member?(@passed_statuses, normalize_status(fetch(preflight, :status, :unknown))) do
          :ok
        else
          {:blocked,
           failure(
             :publish_preflight_not_passed,
             "Publish preflight must pass before host publish runs.",
             nil,
             nil,
             [],
             nil,
             nil,
             %{publish_preflight: preflight}
           )}
        end

      _preflight ->
        {:blocked, failure(:publish_preflight_missing, "Publish preflight evidence is required before host publish runs.", nil, nil, [], nil, nil, %{})}
    end
  end

  defp validate_change_manifest(completion, workspace) do
    case HandoffManifest.source(completion) do
      {:present, manifest} ->
        do_validate_change_manifest(manifest, workspace)

      {:failed, failure} ->
        {:blocked,
         failure(
           :change_manifest_failed,
           "Completion metadata must provide one unambiguous changed-file manifest source.",
           nil,
           nil,
           [],
           nil,
           nil,
           %{failures: [failure]}
         )}

      :absent ->
        {:blocked, failure(:change_manifest_missing, "Changed-file manifest is required before host publish runs.", nil, nil, [], nil, nil, %{})}
    end
  end

  defp do_validate_change_manifest(manifest, workspace) do
    case PathSafety.validate_handoff_manifest(workspace, manifest) do
      {:ok, result} ->
        {:ok, result}

      {:error, %{summary: summary, failures: failures}} ->
        {:blocked, failure(:change_manifest_failed, summary, nil, nil, [], nil, nil, %{failures: failures})}
    end
  end

  defp require_publish_target(%{repository: repository, base_branch: base_branch, github_repository: github_repository} = target) do
    if present?(repository) and present?(base_branch) and present?(github_repository) do
      :ok
    else
      {:blocked, failure(:publish_target_invalid, "Publish target must include repository, GitHub repository, and base branch.", nil, nil, [], nil, nil, target)}
    end
  end

  defp require_supported_vcs_mode(mode) when mode in ["git", "jj"], do: :ok

  defp require_supported_vcs_mode(mode) do
    {:blocked,
     failure(
       :unsupported_vcs_mode,
       "Publish handoff supports only git and jj workspaces.",
       nil,
       nil,
       [],
       nil,
       nil,
       %{vcs_mode: mode}
     )}
  end

  defp validate_pr_body(body) do
    case PrBody.validate_body(body) do
      :ok ->
        :ok

      {:error, message} ->
        {:blocked, failure(:pr_body_invalid, "Generated PR body does not match the repository template.", nil, nil, [], nil, message, %{})}
    end
  end

  defp publish_with_vcs("jj", context), do: publish_with_jj(context)
  defp publish_with_vcs("git", context), do: publish_with_git(context)

  defp publish_with_jj(context) do
    with {:ok, _output} <- command_ok(context, :jj_describe, "jj", ["describe", "-m", context.commit_message]),
         {:ok, _output} <- command_ok(context, :jj_bookmark, "jj", ["bookmark", "set", context.branch, "-r", "@"]),
         {:ok, _output} <- command_ok(context, :jj_push, "jj", ["git", "push", "--remote", "origin", "-b", context.branch, "--allow-new"]),
         {:ok, pr_url} <- create_or_update_pr(context),
         {:ok, current} <-
           command_ok(context, :jj_current, "jj", [
             "log",
             "-r",
             "@",
             "--no-graph",
             "--template",
             "change_id.short() ++ \" \" ++ commit_id.short() ++ \"\\n\""
           ]) do
      {change_id, commit_sha} = parse_jj_current(current)

      {:ok,
       %{
         pr_url: pr_url,
         change_id: change_id,
         commit_sha: commit_sha
       }}
    end
  end

  defp publish_with_git(context) do
    with {:ok, _output} <- command_ok(context, :git_checkout_branch, "git", ["checkout", "-B", context.branch]),
         {:ok, _output} <- command_ok(context, :git_add, "git", ["add", "--"] ++ context.changed_files),
         {:ok, staged?} <- git_staged_changes?(context),
         {:ok, _output} <- maybe_git_commit(context, staged?),
         {:ok, _output} <- command_ok(context, :git_push, "git", ["push", "-u", "origin", "HEAD:#{context.branch}"]),
         {:ok, commit_sha} <- command_ok(context, :git_current, "git", ["rev-parse", "HEAD"]),
         {:ok, pr_url} <- create_or_update_pr(context) do
      {:ok,
       %{
         pr_url: pr_url,
         change_id: nil,
         commit_sha: String.trim(commit_sha)
       }}
    end
  end

  defp git_staged_changes?(context) do
    case execute_command(context, :git_diff_cached, "git", ["diff", "--cached", "--quiet"]) do
      {:ok, %{status: 0}} ->
        {:ok, false}

      {:ok, %{status: 1}} ->
        {:ok, true}

      {:ok, %{status: status, output: output}} ->
        {:blocked, command_failure(:git_diff_cached, "git", ["diff", "--cached", "--quiet"], status, output)}

      {:error, reason} ->
        {:blocked, command_error(:git_diff_cached, "git", ["diff", "--cached", "--quiet"], reason)}
    end
  end

  defp maybe_git_commit(_context, false), do: {:ok, ""}

  defp maybe_git_commit(context, true) do
    command_ok(context, :git_commit, "git", ["commit", "-m", context.commit_message])
  end

  defp verify_publish_remote("jj", context) do
    with {:ok, output} <- command_ok(context, :jj_remote_list, "jj", ["git", "remote", "list"]),
         {:ok, remote_url} <- origin_remote_url(output, :jj_remote_list, "jj", ["git", "remote", "list"]) do
      require_publish_remote_match(context, remote_url)
    end
  end

  defp verify_publish_remote("git", context) do
    with {:ok, output} <- command_ok(context, :git_remote_get_url, "git", ["remote", "get-url", "--push", "origin"]) do
      require_publish_remote_match(context, String.trim(output))
    end
  end

  defp origin_remote_url(output, step, command, args) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, ~r/\s+/, parts: 2, trim: true) do
        ["origin", remote_url] -> remote_url
        _parts -> nil
      end
    end)
    |> case do
      nil -> {:blocked, failure(:origin_remote_missing, "Workspace origin remote is required for host publish.", step, command, args, 0, nil, %{})}
      remote_url -> {:ok, remote_url}
    end
  end

  defp require_publish_remote_match(context, remote_url) do
    if PublishTarget.remote_matches?(context.target, remote_url) do
      :ok
    else
      {:blocked,
       failure(
         :publish_remote_mismatch,
         "Workspace origin remote does not match the resolved publish target.",
         nil,
         nil,
         [],
         nil,
         nil,
         %{
           remote_url: remote_url,
           repository: context.target.repository,
           github_repository: context.target.github_repository
         }
       )}
    end
  end

  defp validate_vcs_payload("jj", context) do
    with {:ok, output} <- command_ok(context, :jj_changed_files, "jj", ["diff", "--name-only", "-r", "@"]) do
      compare_changed_files(context, changed_files_from_output(output))
    end
  end

  defp validate_vcs_payload("git", context) do
    base_ref = "origin/#{context.target.base_branch}"

    with {:ok, committed} <- command_ok(context, :git_committed_changed_files, "git", ["diff", "--name-only", "#{base_ref}...HEAD"]),
         {:ok, unstaged} <- command_ok(context, :git_unstaged_changed_files, "git", ["diff", "--name-only"]),
         {:ok, staged} <- command_ok(context, :git_staged_changed_files, "git", ["diff", "--name-only", "--cached"]),
         {:ok, untracked} <- command_ok(context, :git_untracked_files, "git", ["ls-files", "--others", "--exclude-standard"]) do
      actual_changed_files =
        [committed, unstaged, staged, untracked]
        |> Enum.flat_map(&changed_files_from_output/1)

      compare_changed_files(context, actual_changed_files)
    end
  end

  defp compare_changed_files(context, actual_changed_files) do
    actual = normalized_file_set(actual_changed_files)
    expected = normalized_file_set(context.changed_files)

    if MapSet.equal?(actual, expected) do
      :ok
    else
      {:blocked,
       failure(
         :change_manifest_mismatch,
         "Changed-file manifest does not match the actual VCS payload.",
         nil,
         nil,
         [],
         nil,
         nil,
         %{
           manifest_only: MapSet.difference(expected, actual) |> Enum.sort(),
           vcs_only: MapSet.difference(actual, expected) |> Enum.sort()
         }
       )}
    end
  end

  defp changed_files_from_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&git_path_from_status_line/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp git_path_from_status_line(line) do
    case String.split(line, " -> ", parts: 2) do
      [_old_path, new_path] -> new_path
      [path] -> path
    end
  end

  defp normalized_file_set(paths) do
    paths
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp create_or_update_pr(context) do
    view_args = ["pr", "view", "--repo", context.target.github_repository, "--head", pr_head(context), "--json", "url", "--jq", ".url"]

    case execute_command(context, :pr_view, "gh", view_args) do
      {:ok, %{status: 0, output: output}} ->
        pr_url = pr_url_from_output(output)

        with :ok <- require_pr_url(pr_url, :pr_view, "gh", view_args),
             {:ok, _output} <-
               command_ok(context, :pr_edit, "gh", [
                 "pr",
                 "edit",
                 pr_url,
                 "--repo",
                 context.target.github_repository,
                 "--base",
                 context.target.base_branch,
                 "--title",
                 context.pr_title,
                 "--body",
                 context.pr_body
               ]) do
          {:ok, pr_url}
        end

      {:ok, %{status: _status}} ->
        create_pr(context)

      {:error, _reason} ->
        create_pr(context)
    end
  end

  defp create_pr(context) do
    args = [
      "pr",
      "create",
      "--repo",
      context.target.github_repository,
      "--head",
      pr_head(context),
      "--base",
      context.target.base_branch,
      "--title",
      context.pr_title,
      "--body",
      context.pr_body
    ]

    with {:ok, output} <- command_ok(context, :pr_create, "gh", args) do
      pr_url = pr_url_from_output(output)

      with :ok <- require_pr_url(pr_url, :pr_create, "gh", args) do
        {:ok, pr_url}
      end
    end
  end

  defp pr_head(context) do
    [owner, _repo] = String.split(context.target.github_repository, "/", parts: 2)
    "#{owner}:#{context.branch}"
  end

  defp command_ok(context, step, command, args) do
    case execute_command(context, step, command, args) do
      {:ok, %{status: 0, output: output}} ->
        {:ok, output}

      {:ok, %{status: status, output: output}} ->
        {:blocked, command_failure(step, command, args, status, output)}

      {:error, reason} ->
        {:blocked, command_error(step, command, args, reason)}
    end
  end

  defp execute_command(%{runner: runner} = context, step, command, args) when is_function(runner, 1) do
    %{
      step: step,
      command: command,
      args: args,
      cwd: context.workspace,
      env: context.env
    }
    |> runner.()
    |> normalize_command_result()
  end

  defp execute_command(context, _step, command, args) do
    task =
      Task.async(fn ->
        case executable_path(command, context.env) do
          nil ->
            {:error, {:command_not_found, command}}

          executable ->
            {output, status} =
              System.cmd(executable, args,
                cd: context.workspace,
                env: context.env,
                stderr_to_stdout: true
              )

            {:ok, %{status: status, output: output}}
        end
      end)

    yield_command(task, context.timeout_ms)
  end

  defp executable_path(command, env) do
    env
    |> path_value()
    |> find_executable_in_path(command)
    |> Kernel.||(System.find_executable(command))
  end

  defp path_value(env) when is_list(env) do
    Enum.find_value(env, fn
      {"PATH", value} when is_binary(value) -> value
      _entry -> nil
    end)
  end

  defp find_executable_in_path(nil, _command), do: nil

  defp find_executable_in_path(path, command) do
    path
    |> String.split(":", trim: true)
    |> Enum.find_value(fn directory ->
      candidate = Path.join(directory, command)

      if executable_file?(candidate) do
        candidate
      end
    end)
  end

  defp executable_file?(path) do
    File.regular?(path) and (File.stat!(path).mode &&& 0o111) != 0
  end

  defp yield_command(task, timeout_ms) do
    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        normalize_command_result(result)

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:publish_handoff_timeout, timeout_ms}}
    end
  end

  defp normalize_command_result({:ok, %{status: status, output: output}})
       when is_integer(status) and is_binary(output) do
    {:ok, %{status: status, output: output}}
  end

  defp normalize_command_result({:error, reason}), do: {:error, reason}

  defp merge_result({:ok, publish_result}, result_base) do
    result_base
    |> Map.merge(publish_result)
    |> Map.merge(%{status: :passed, attempted: true, failure: nil})
  end

  defp merge_result({:blocked, failure}, result_base) do
    %{result_base | attempted: true, failure: failure}
  end

  defp command_failure(step, command, args, status, output) do
    failure(
      :"#{step}_failed",
      "#{step} failed during host publish.",
      step,
      command,
      args,
      status,
      sanitize_output(output),
      %{}
    )
  end

  defp command_error(step, command, args, reason) do
    failure(
      :"#{step}_failed",
      "#{step} failed during host publish.",
      step,
      command,
      args,
      nil,
      inspect(reason),
      %{}
    )
  end

  defp failure(reason, summary, step, command, args, exit_status, details, metadata) do
    %{
      reason: reason,
      summary: summary,
      step: step,
      command: command,
      args: args,
      exit_status: exit_status,
      details: details,
      metadata: metadata
    }
  end

  defp require_pr_url(nil, step, command, args) do
    {:blocked, failure(:"#{step}_missing_pr_url", "#{step} did not return a PR URL.", step, command, args, 0, nil, %{})}
  end

  defp require_pr_url(_url, _step, _command, _args), do: :ok

  defp empty_publish_target, do: %{repository: nil, base_branch: nil, github_repository: nil}

  defp vcs_mode(policy) do
    (get_in(policy, ["manifest", "vcs", "mode"]) || get_in(policy, ["vcs", "mode"]) || "git")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp branch_name(issue) do
    token =
      issue
      |> issue_field(:identifier)
      |> Kernel.||(issue_field(issue, :id))
      |> Kernel.||("issue")
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]+/, "-")
      |> String.trim(".-_/")

    "ticket/#{if token == "", do: "issue", else: token}"
  end

  defp commit_message(issue) do
    case issue_field(issue, :identifier) |> optional_trimmed_string() do
      nil -> "chore: publish Symphony workspace changes"
      identifier -> "chore(#{identifier}): publish Symphony workspace changes"
    end
  end

  defp pr_title(issue) do
    title = issue_field(issue, :title) |> optional_trimmed_string()

    case issue_field(issue, :identifier) |> optional_trimmed_string() do
      nil -> title || "Publish Symphony workspace changes"
      identifier -> "#{identifier}: #{title || "Publish Symphony workspace changes"}"
    end
  end

  defp pr_body(issue, target, branch, validation_summary, changed_files) do
    identifier = issue_field(issue, :identifier) || "issue"
    issue_url = issue_field(issue, :url) || "not supplied"
    target_display = "#{target.github_repository}:#{target.base_branch}"
    validation_line = validation_summary || "worker supplied validation checks"
    reviewer_testing_lines = reviewer_testing_lines(identifier, changed_files)

    """
    #### Context

    Symphony host-owned publish for #{identifier}. Linear: #{issue_url}

    #### TL;DR

    *Publish validated Symphony workspace changes.*

    #### Summary

    - Publish branch `#{branch}` from host-validated workspace changes.
    - Target `#{target_display}`.
    - Linear issue `#{identifier}`: #{issue_url}.

    #### Alternatives

    - Keep VCS mutation host-owned instead of relying on worker-side commits.

    #### Reviewer Testing

    #{reviewer_testing_lines}

    #### Test Plan

    - [x] #{validation_line}
    """
    |> String.trim_trailing()
  end

  defp validation_summary(completion) do
    case fetch(completion, :checks, []) do
      checks when is_list(checks) and checks != [] ->
        Enum.map_join(checks, "; ", fn check ->
          check = normalize_map(check)
          name = fetch(check, :name, "check")
          status = fetch(check, :status, :unknown)
          summary = fetch(check, :summary, nil)

          [name, status_label(status), summary]
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join(": ", &to_string/1)
        end)

      _checks ->
        nil
    end
  end

  defp status_label(status) when is_atom(status), do: Atom.to_string(status)
  defp status_label(status), do: to_string(status)

  defp reviewer_testing_lines(identifier, changed_files) do
    [
      "- Review the affected workflow or surface from Linear issue `#{identifier}`.",
      "- Start from the changed scope: #{changed_file_summary(changed_files)}.",
      "- Confirm the primary changed behavior works before approval; leave exhaustive edge cases to the Test Plan and quality gates."
    ]
    |> Enum.join("\n")
  end

  defp changed_file_summary(changed_files) do
    visible_files =
      changed_files
      |> Enum.take(5)
      |> Enum.map_join(", ", &"`#{&1}`")

    remaining_count = length(changed_files) - 5

    if remaining_count > 0 do
      "#{visible_files}, and #{remaining_count} more"
    else
      visible_files
    end
  end

  defp linear_issue(issue) do
    %{
      id: issue_field(issue, :id),
      identifier: issue_field(issue, :identifier),
      url: issue_field(issue, :url)
    }
  end

  defp issue_field(%Issue{} = issue, field), do: Map.get(issue, field)
  defp issue_field(issue, field) when is_map(issue), do: Map.get(issue, field, Map.get(issue, to_string(field)))
  defp issue_field(_issue, _field), do: nil

  defp parse_jj_current(output) do
    case output |> String.trim() |> String.split(~r/\s+/, trim: true) do
      [change_id, commit_sha | _rest] -> {change_id, commit_sha}
      [change_id] -> {change_id, nil}
      _parts -> {nil, nil}
    end
  end

  defp pr_url_from_output(output) do
    output
    |> to_string()
    |> String.split("\n", trim: true)
    |> List.first()
    |> optional_trimmed_string()
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp fetch(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_map(_map), do: %{}

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    Map.get(@known_keys, normalize_string_token(key), key)
  end

  defp normalize_key(key), do: key

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    Map.get(@status_tokens, normalize_string_token(status), :unknown)
  end

  defp normalize_status(_status), do: :unknown

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
