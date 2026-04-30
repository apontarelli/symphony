defmodule SymphonyElixir.VcsHandoff do
  @moduledoc """
  Host-owned Git handoff runner for completed Symphony work.
  """

  alias SymphonyElixir.{Linear.Client, PathSafety}

  @max_manifest_files 200
  @default_timeout_ms 120_000
  @preflight_prefix ".symphony-git-handoff-preflight-"
  @commit_message_prefix "symphony-git-handoff-"
  @github_pr_attachment_mutation """
  mutation AttachGitHubPR($issueId: String!, $url: String!, $title: String) {
    attachmentLinkGitHubPR(
      issueId: $issueId
      url: $url
      title: $title
      linkKind: links
    ) {
      success
      attachment {
        id
        title
        url
      }
    }
  }
  """

  @type command :: {String.t(), [String.t()]}

  @spec preflight(Path.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def preflight(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    with {:ok, canonical_workspace} <- canonical_workspace(workspace),
         {:ok, source_probe} <- verify_source_tree_write(canonical_workspace),
         {:ok, git_dir, git_dir_command} <- absolute_git_dir(canonical_workspace, opts),
         {:ok, git_probe} <- verify_git_metadata_write(git_dir) do
      {:ok,
       %{
         "sourceTreeWrite" => source_probe,
         "gitMetadataWrite" => git_probe,
         "gitDir" => git_dir,
         "commands" => [git_dir_command]
       }}
    end
  end

  @spec validate_manifest(Path.t(), [String.t()], keyword()) :: {:ok, [String.t()], map()} | {:error, map()}
  def validate_manifest(workspace, manifest, opts \\ []) do
    if is_binary(workspace) and is_list(manifest) and is_list(opts) do
      status_args = ["status", "--porcelain=v1", "-z", "--untracked-files=all"]

      with {:ok, canonical_workspace} <- canonical_workspace(workspace),
           {:ok, manifest_paths} <- normalize_manifest(manifest, canonical_workspace),
           {:ok, status_output, status_command} <- git_output(canonical_workspace, status_args, opts),
           {:ok, status_entries} <- parse_porcelain_z(status_output),
           {:ok, validated_paths} <-
             validate_manifest_entries(canonical_workspace, manifest_paths, status_entries, opts) do
        changed_paths = Enum.map(status_entries, & &1.path)
        unstaged_paths = changed_paths -- validated_paths

        {:ok, validated_paths,
         %{
           "status" => %{
             "changedPaths" => changed_paths,
             "manifestPaths" => validated_paths,
             "unstagedPaths" => unstaged_paths
           },
           "commands" => [status_command]
         }}
      end
    else
      {:error, failure("invalid_manifest", "changedFiles must be a non-empty list of relative paths.")}
    end
  end

  @spec build_commit_message(map()) :: {:ok, String.t()} | {:error, map()}
  def build_commit_message(attrs) when is_map(attrs) do
    with {:ok, issue_identifier} <- required_string(attrs, "issueIdentifier"),
         {:ok, summary} <- required_string(attrs, "commitSummary"),
         {:ok, validation_evidence} <- required_string_list(attrs, "validationEvidence"),
         {:ok, changed_files} <- required_string_list(attrs, "changedFiles"),
         {:ok, commit_type} <- commit_type(attrs),
         {:ok, commit_scope} <- commit_scope(attrs) do
      subject = commit_subject(commit_type, commit_scope, summary)

      {:ok,
       [
         subject,
         "",
         "Linear-Issue: #{issue_identifier}",
         "",
         "Validation:",
         Enum.map(validation_evidence, &"- #{&1}"),
         "",
         "Changed-files:",
         Enum.map(changed_files, &"- #{&1}")
       ]
       |> List.flatten()
       |> Enum.join("\n")
       |> Kernel.<>("\n")}
    end
  end

  @spec git_command(atom(), map()) :: command() | {:error, map()}
  def git_command(:fetch, %{"remote" => remote}) when is_binary(remote) do
    {"git", ["fetch", remote]}
  end

  def git_command(:verify_base, %{"remote" => remote, "baseBranch" => base_branch})
      when is_binary(remote) and is_binary(base_branch) do
    {"git", ["rev-parse", "--verify", "--quiet", "refs/remotes/#{remote}/#{base_branch}"]}
  end

  def git_command(:check_branch, %{"taskBranch" => task_branch}) when is_binary(task_branch) do
    {"git", ["check-ref-format", "--branch", task_branch]}
  end

  def git_command(:add, %{"paths" => paths}) when is_list(paths) do
    {"git", ["add", "--" | paths]}
  end

  def git_command(:cached_check, _attrs) do
    {"git", ["diff", "--cached", "--check"]}
  end

  def git_command(:cached_quiet, _attrs) do
    {"git", ["diff", "--cached", "--quiet", "--exit-code"]}
  end

  def git_command(:commit, %{"messageFile" => message_file}) when is_binary(message_file) do
    {"git", ["commit", "-F", message_file]}
  end

  def git_command(:head_sha, _attrs) do
    {"git", ["rev-parse", "HEAD"]}
  end

  def git_command(:push, %{"remote" => remote, "taskBranch" => task_branch})
      when is_binary(remote) and is_binary(task_branch) do
    {"git", ["push", remote, "HEAD:#{task_branch}"]}
  end

  def git_command(_name, _attrs) do
    {:error, failure("invalid_command_template", "Unsupported Git command template.")}
  end

  @spec classify_command_failure(String.t(), [String.t()], non_neg_integer(), String.t()) :: map()
  def classify_command_failure(executable, args, status, output)
      when is_binary(executable) and is_list(args) and is_integer(status) and is_binary(output) do
    command_name = List.first(args) || executable

    failure(
      "command_failed",
      "#{executable} #{Enum.join(args, " ")} failed with status #{status}.",
      %{
        "capability" => failure_capability(executable, command_name, output),
        "command" => %{"executable" => executable, "args" => args},
        "status" => status,
        "output" => output
      }
    )
  end

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(arguments, opts \\ []) do
    with :ok <- validate_run_arguments(arguments, opts),
         {:ok, mode} <- normalize_mode(arguments) do
      run_mode(mode, arguments, opts)
    end
  end

  defp failure_capability("git", command_name, output) do
    normalized_output = String.downcase(output)

    cond do
      String.contains?(normalized_output, ".git/index.lock") ->
        "git_metadata_write"

      String.contains?(normalized_output, "unable to create") and String.contains?(normalized_output, "permission denied") ->
        "git_metadata_write"

      true ->
        git_command_capability(command_name)
    end
  end

  defp failure_capability(executable, command_name, output) do
    if String.contains?(String.downcase(output), "permission denied") do
      "host_command_permission"
    else
      "#{executable}_#{command_name}"
    end
  end

  defp git_command_capability("fetch"), do: "git_fetch"
  defp git_command_capability("push"), do: "git_push"
  defp git_command_capability("commit"), do: "git_commit"
  defp git_command_capability(_command_name), do: "git_command"

  defp validate_run_arguments(arguments, opts) do
    if is_map(arguments) and is_list(opts) do
      :ok
    else
      {:error, failure("invalid_arguments", "symphony_git_handoff expects a JSON object.")}
    end
  end

  defp run_mode("preflight", arguments, opts) do
    workspace = first_present([get_value(arguments, "workspace"), Keyword.get(opts, :workspace)])

    with {:ok, workspace} <- normalize_required_path(workspace, "workspace"),
         {:ok, preflight_result} <- preflight(workspace, opts) do
      {:ok, %{"mode" => "preflight", "preflight" => preflight_result}}
    end
  end

  defp run_mode("handoff", arguments, opts) do
    with {:ok, input} <- normalize_input(arguments, opts),
         {:ok, preflight_result} <- preflight(input.workspace, opts),
         {:ok, paths, manifest_result} <- validate_manifest(input.workspace, input.changed_files, opts),
         {:ok, message} <- build_commit_message(commit_message_attrs(input, paths)),
         {:ok, handoff_result} <- run_git_handoff(input, paths, message, opts),
         {:ok, pr_result} <- maybe_publish_pr(input, opts),
         {:ok, linear_result} <- maybe_attach_linear(input, pr_result, opts) do
      {:ok,
       %{
         "mode" => "handoff",
         "issueIdentifier" => input.issue_identifier,
         "commitSha" => handoff_result.commit_sha,
         "pushedBranch" => input.task_branch,
         "baseBranch" => input.base_branch,
         "remote" => input.remote,
         "validatedPaths" => paths,
         "preflight" => preflight_result,
         "manifest" => manifest_result,
         "commands" => handoff_result.commands ++ pr_result.commands,
         "prUrl" => pr_result.url,
         "linearAttachment" => linear_result
       }}
    end
  end

  defp normalize_mode(arguments) do
    case get_value(arguments, "mode") || "handoff" do
      mode when mode in ["preflight", "handoff"] ->
        {:ok, mode}

      _ ->
        {:error, failure("invalid_mode", "mode must be either preflight or handoff.")}
    end
  end

  defp normalize_input(arguments, opts) do
    attrs = raw_input_attrs(arguments, opts)

    with {:ok, workspace} <- normalize_required_path(attrs.workspace, "workspace"),
         {:ok, issue_identifier} <- normalize_required_text(attrs.issue_identifier, "issueIdentifier"),
         {:ok, changed_files} <- normalize_string_list(attrs.changed_files, "changedFiles"),
         {:ok, validation_evidence} <- normalize_string_list(attrs.validation_evidence, "validationEvidence"),
         {:ok, commit_summary} <- normalize_required_text(attrs.commit_summary, "commitSummary"),
         {:ok, task_branch} <- normalize_required_text(attrs.task_branch, "taskBranch"),
         {:ok, base_branch} <- normalize_required_text(attrs.base_branch, "baseBranch"),
         {:ok, remote} <- normalize_required_text(attrs.remote, "remote"),
         {:ok, commit_type} <- normalize_required_text(attrs.commit_type, "commitType"),
         {:ok, commit_scope} <- normalize_optional_text(attrs.commit_scope),
         {:ok, pr_title} <- normalize_optional_text(attrs.pr_title),
         {:ok, pr_body} <- normalize_optional_text(attrs.pr_body),
         {:ok, publish_pr} <- normalize_boolean(attrs.publish_pr, "publishPr") do
      {:ok,
       %{
         workspace: workspace,
         issue_identifier: issue_identifier,
         issue_id: normalize_optional_binary(attrs.issue_id),
         title: normalize_optional_binary(attrs.title),
         changed_files: changed_files,
         validation_evidence: validation_evidence,
         commit_summary: commit_summary,
         commit_type: commit_type,
         commit_scope: commit_scope,
         task_branch: task_branch,
         base_branch: base_branch,
         remote: remote,
         publish_pr: publish_pr,
         pr_title: pr_title || commit_summary,
         pr_body: pr_body
       }}
    end
  end

  defp raw_input_attrs(arguments, opts) do
    issue = Keyword.get(opts, :issue)

    %{
      workspace: first_present([get_value(arguments, "workspace"), Keyword.get(opts, :workspace)]),
      issue_identifier: first_present([get_value(arguments, "issueIdentifier"), issue_value(issue, :identifier)]),
      issue_id: first_present([get_value(arguments, "linearIssueId"), issue_value(issue, :id)]),
      title: first_present([get_value(arguments, "prTitle"), issue_value(issue, :title)]),
      changed_files: first_present([get_value(arguments, "changedFiles"), get_value(arguments, "changed_files")]),
      validation_evidence:
        first_present([
          get_value(arguments, "validationEvidence"),
          get_value(arguments, "validation"),
          get_value(arguments, "validation_evidence")
        ]),
      commit_summary:
        first_present([
          get_value(arguments, "commitSummary"),
          get_value(arguments, "commit_summary"),
          issue_value(issue, :title)
        ]),
      commit_type: first_present([get_value(arguments, "commitType"), get_value(arguments, "commit_type"), "feat"]),
      commit_scope: first_present([get_value(arguments, "commitScope"), get_value(arguments, "commit_scope")]),
      task_branch:
        first_present([
          get_value(arguments, "taskBranch"),
          get_value(arguments, "task_branch"),
          issue_value(issue, :branch_name)
        ]),
      base_branch: first_present([get_value(arguments, "baseBranch"), get_value(arguments, "base_branch"), "main"]),
      remote: first_present([get_value(arguments, "remote"), "origin"]),
      publish_pr: first_present([get_value(arguments, "publishPr"), get_value(arguments, "publish_pr"), false]),
      pr_title:
        first_present([
          get_value(arguments, "prTitle"),
          get_value(arguments, "pr_title"),
          issue_value(issue, :title)
        ]),
      pr_body: first_present([get_value(arguments, "prBody"), get_value(arguments, "pr_body")])
    }
  end

  defp run_git_handoff(input, paths, message, opts) do
    with {:ok, commands, message_file} <- write_commit_message(message) do
      try do
        base_attrs = %{"remote" => input.remote, "baseBranch" => input.base_branch}
        branch_attrs = %{"taskBranch" => input.task_branch}
        push_attrs = %{"remote" => input.remote, "taskBranch" => input.task_branch}

        with {:ok, commands} <- run_git_template(:fetch, %{"remote" => input.remote}, input.workspace, opts, commands),
             {:ok, commands} <- run_git_template(:verify_base, base_attrs, input.workspace, opts, commands),
             {:ok, commands} <- run_git_template(:check_branch, branch_attrs, input.workspace, opts, commands),
             {:ok, commands} <- run_git_template(:add, %{"paths" => paths}, input.workspace, opts, commands),
             {:ok, commands} <- run_git_template(:cached_check, %{}, input.workspace, opts, commands),
             {:ok, commands} <- ensure_cached_diff(input.workspace, opts, commands),
             {:ok, commands} <- run_git_template(:commit, %{"messageFile" => message_file}, input.workspace, opts, commands),
             {:ok, commit_sha, commands} <- capture_git_template(:head_sha, %{}, input.workspace, opts, commands),
             {:ok, commands} <- run_git_template(:push, push_attrs, input.workspace, opts, commands) do
          {:ok, %{commit_sha: String.trim(commit_sha), commands: commands}}
        end
      after
        File.rm(message_file)
      end
    end
  end

  defp ensure_cached_diff(workspace, opts, commands) do
    case git_command(:cached_quiet, %{}) do
      {"git", args} ->
        case run_command(workspace, "git", args, opts) do
          {:ok, %{"status" => 0} = command} ->
            {:error, failure("empty_staged_diff", "Validated manifest did not produce a staged diff.", %{"commands" => commands ++ [command]})}

          {:ok, %{"status" => 1} = command} ->
            {:ok, commands ++ [command]}

          {:ok, %{"status" => status, "output" => output} = command} ->
            {:error, Map.put(classify_command_failure("git", args, status, output), "commands", commands ++ [command])}
        end
    end
  end

  defp maybe_publish_pr(%{publish_pr: false}, _opts), do: {:ok, %{url: nil, commands: []}}

  defp maybe_publish_pr(%{publish_pr: true, pr_body: nil}, _opts) do
    {:error, failure("missing_pr_body", "prBody is required when publishPr is true.")}
  end

  defp maybe_publish_pr(%{publish_pr: true} = input, opts) do
    with {:ok, body_file} <- write_pr_body(input.pr_body) do
      try do
        view_args = ["pr", "view", "--head", input.task_branch, "--json", "url", "--jq", ".url"]

        with {:ok, view_result} <- run_gh_status(input.workspace, view_args, opts),
             {:ok, create_or_update_commands, pr_url} <- create_or_update_pr(input, body_file, view_result, opts),
             {:ok, label_command} <- run_gh(input.workspace, ["pr", "edit", pr_url, "--add-label", "symphony"], opts) do
          {:ok, %{url: pr_url, commands: [view_result] ++ create_or_update_commands ++ [label_command]}}
        end
      after
        File.rm(body_file)
      end
    end
  end

  defp create_or_update_pr(input, body_file, %{"status" => 0, "output" => output}, opts) do
    pr_url = String.trim(output)

    if pr_url == "" do
      create_pr(input, body_file, opts)
    else
      edit_args = [
        "pr",
        "edit",
        pr_url,
        "--base",
        input.base_branch,
        "--title",
        input.pr_title,
        "--body-file",
        body_file
      ]

      with {:ok, edit_result} <-
             run_gh(input.workspace, edit_args, opts) do
        {:ok, [edit_result], pr_url}
      end
    end
  end

  defp create_or_update_pr(input, body_file, %{"status" => _status}, opts) do
    create_pr(input, body_file, opts)
  end

  defp create_pr(input, body_file, opts) do
    args = [
      "pr",
      "create",
      "--base",
      input.base_branch,
      "--head",
      input.task_branch,
      "--title",
      input.pr_title,
      "--body-file",
      body_file
    ]

    with {:ok, %{"status" => 0, "output" => output} = create_result} <- run_gh(input.workspace, args, opts) do
      {:ok, [create_result], String.trim(output)}
    end
  end

  defp maybe_attach_linear(_input, %{url: nil}, _opts), do: {:ok, nil}
  defp maybe_attach_linear(%{issue_id: nil}, _pr_result, _opts), do: {:ok, nil}

  defp maybe_attach_linear(input, %{url: pr_url}, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    variables = %{
      "issueId" => input.issue_id,
      "url" => pr_url,
      "title" => input.pr_title
    }

    case linear_client.(@github_pr_attachment_mutation, variables, []) do
      {:ok, response} ->
        if get_in(response, ["data", "attachmentLinkGitHubPR", "success"]) == true do
          {:ok, response}
        else
          {:error,
           failure("linear_attachment_failed", "Linear did not confirm GitHub PR attachment.", %{
             "response" => inspect(response),
             "prUrl" => pr_url
           })}
        end

      {:error, reason} ->
        {:error,
         failure("linear_attachment_failed", "Unable to attach GitHub PR to Linear.", %{
           "reason" => inspect(reason),
           "prUrl" => pr_url
         })}
    end
  end

  defp run_git_template(name, attrs, workspace, opts, commands) do
    case git_command(name, attrs) do
      {"git", args} ->
        case run_command(workspace, "git", args, opts) do
          {:ok, %{"status" => 0} = command} ->
            {:ok, commands ++ [command]}

          {:ok, %{"status" => status, "output" => output} = command} ->
            {:error, Map.put(classify_command_failure("git", args, status, output), "commands", commands ++ [command])}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp capture_git_template(name, attrs, workspace, opts, commands) do
    case git_command(name, attrs) do
      {"git", args} ->
        case run_command(workspace, "git", args, opts) do
          {:ok, %{"status" => 0, "output" => output} = command} ->
            {:ok, output, commands ++ [command]}

          {:ok, %{"status" => status, "output" => output} = command} ->
            {:error, Map.put(classify_command_failure("git", args, status, output), "commands", commands ++ [command])}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp git_output(workspace, args, opts) do
    case run_command(workspace, "git", args, opts) do
      {:ok, %{"status" => 0, "output" => output} = command} ->
        {:ok, output, command}

      {:ok, %{"status" => status, "output" => output}} ->
        {:error, classify_command_failure("git", args, status, output)}
    end
  end

  defp absolute_git_dir(workspace, opts) do
    args = ["rev-parse", "--absolute-git-dir"]

    case git_output(workspace, args, opts) do
      {:ok, output, command} ->
        {:ok, String.trim(output), command}

      {:error, error} ->
        {:error, Map.put(error, "capability", "git_metadata_discovery")}
    end
  end

  defp run_gh(workspace, args, opts) do
    executable = Keyword.get(opts, :github_cli, "gh")

    case run_command(workspace, executable, args, opts) do
      {:ok, %{"status" => 0} = command} ->
        {:ok, command}

      {:ok, %{"status" => status, "output" => output} = command} ->
        {:error, Map.put(classify_command_failure(executable, args, status, output), "commands", [command])}
    end
  end

  defp run_gh_status(workspace, args, opts) do
    executable = Keyword.get(opts, :github_cli, "gh")
    run_command(workspace, executable, args, opts)
  end

  defp run_command(workspace, executable, args, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    env = Keyword.get(opts, :env, [])

    task =
      Task.async(fn ->
        {output, status} = System.cmd(executable, args, cd: workspace, env: env, stderr_to_stdout: true)

        %{
          "executable" => executable,
          "args" => args,
          "status" => status,
          "output" => output
        }
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, command} ->
        {:ok, command}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:ok, %{"executable" => executable, "args" => args, "status" => 124, "output" => "command timed out after #{timeout_ms}ms"}}
    end
  rescue
    error in ErlangError ->
      {:ok, %{"executable" => executable, "args" => args, "status" => 127, "output" => Exception.message(error)}}
  end

  defp canonical_workspace(workspace) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         true <- File.dir?(canonical_workspace) do
      {:ok, canonical_workspace}
    else
      false ->
        {:error, failure("workspace_not_found", "Workspace must be an existing directory.", %{"workspace" => workspace})}

      {:error, reason} ->
        {:error, failure("workspace_unreadable", "Workspace path could not be canonicalized.", %{"reason" => inspect(reason)})}
    end
  end

  defp verify_source_tree_write(workspace) do
    probe_path = Path.join(workspace, @preflight_prefix <> unique_token())

    case File.write(probe_path, "preflight\n", [:exclusive]) do
      :ok ->
        File.rm(probe_path)
        {:ok, %{"capability" => "source_tree_write", "path" => Path.basename(probe_path)}}

      {:error, reason} ->
        {:error,
         failure("preflight_failed", "Host process cannot write the source tree.", %{
           "capability" => "source_tree_write",
           "reason" => inspect(reason)
         })}
    end
  end

  defp verify_git_metadata_write(git_dir) do
    probe_path = Path.join(git_dir, @preflight_prefix <> unique_token())

    case File.write(probe_path, "preflight\n", [:exclusive]) do
      :ok ->
        File.rm(probe_path)
        {:ok, %{"capability" => "git_metadata_write", "path" => Path.basename(probe_path)}}

      {:error, reason} ->
        {:error,
         failure("preflight_failed", "Host process cannot write Git metadata.", %{
           "capability" => "git_metadata_write",
           "gitDir" => git_dir,
           "reason" => inspect(reason)
         })}
    end
  end

  defp normalize_manifest(manifest, workspace) do
    cond do
      manifest == [] ->
        {:error, failure("empty_manifest", "changedFiles must include at least one path.")}

      length(manifest) > @max_manifest_files ->
        {:error, failure("manifest_too_large", "changedFiles exceeds the #{@max_manifest_files}-file limit.")}

      true ->
        collect_manifest_paths(manifest, workspace)
    end
  end

  defp collect_manifest_paths(manifest, workspace) do
    manifest
    |> Enum.reduce_while({:ok, []}, fn raw_path, {:ok, paths} ->
      case normalize_manifest_path(raw_path, workspace) do
        {:ok, path} -> {:cont, {:ok, [path | paths]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> finalize_manifest_paths()
  end

  defp finalize_manifest_paths({:ok, paths}), do: {:ok, Enum.reverse(paths) |> Enum.uniq()}
  defp finalize_manifest_paths(error), do: error

  defp normalize_manifest_path(raw_path, workspace) when is_binary(raw_path) do
    path = String.trim(raw_path)
    expanded_path = Path.expand(path, workspace)
    workspace_prefix = workspace <> "/"

    cond do
      path == "" ->
        {:error, unsafe_path_error(raw_path, "empty_path")}

      String.contains?(path, [<<0>>, "\n", "\r"]) ->
        {:error, unsafe_path_error(raw_path, "invalid_characters")}

      Path.type(path) == :absolute ->
        {:error, unsafe_path_error(raw_path, "absolute_path")}

      path_segments(path) |> Enum.member?("..") ->
        {:error, unsafe_path_error(raw_path, "path_traversal")}

      not String.starts_with?(expanded_path <> "/", workspace_prefix) ->
        {:error, unsafe_path_error(raw_path, "outside_workspace")}

      unsafe_artifact_path?(path) ->
        {:error, unsafe_path_error(raw_path, "generated_log_temp_or_secret_path")}

      true ->
        {:ok, path}
    end
  end

  defp normalize_manifest_path(raw_path, _workspace) do
    {:error, unsafe_path_error(inspect(raw_path), "invalid_path")}
  end

  defp validate_manifest_entries(workspace, paths, status_entries, opts) do
    status_by_path = Map.new(status_entries, &{&1.path, &1})

    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case validate_manifest_path_entry(workspace, path, status_by_path, opts) do
        :ok -> {:cont, {:ok, [path | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  defp validate_manifest_path_entry(workspace, path, status_by_path, opts) do
    case Map.fetch(status_by_path, path) do
      {:ok, status_entry} -> validate_status_entry(path, status_entry)
      :error -> missing_manifest_path_error(workspace, path, opts)
    end
  end

  defp missing_manifest_path_error(workspace, path, opts) do
    if ignored_path?(workspace, path, opts) do
      {:error, unsafe_path_error(path, "ignored_path")}
    else
      {:error, failure("manifest_path_not_changed", "Manifest path is not present in git status.", %{"path" => path})}
    end
  end

  defp validate_status_entry(path, %{status: status}) do
    cond do
      String.starts_with?(status, "!!") ->
        {:error, unsafe_path_error(path, "ignored_path")}

      String.starts_with?(status, "??") and unsafe_artifact_path?(path) ->
        {:error, unsafe_path_error(path, "untracked_generated_log_temp_or_secret_path")}

      true ->
        :ok
    end
  end

  defp ignored_path?(workspace, path, opts) do
    case run_command(workspace, "git", ["check-ignore", "--quiet", "--", path], opts) do
      {:ok, %{"status" => 0}} -> true
      _ -> false
    end
  end

  defp parse_porcelain_z(output) when is_binary(output) do
    entries =
      output
      |> String.split(<<0>>, trim: true)
      |> do_parse_porcelain_z([])

    {:ok, entries}
  end

  defp do_parse_porcelain_z([], acc), do: Enum.reverse(acc)

  defp do_parse_porcelain_z([entry | rest], acc) do
    case byte_size(entry) >= 4 do
      true ->
        status = binary_part(entry, 0, 2)
        path = binary_part(entry, 3, byte_size(entry) - 3)
        next_rest = if String.starts_with?(status, ["R", "C"]), do: Enum.drop(rest, 1), else: rest
        do_parse_porcelain_z(next_rest, [%{status: status, path: path} | acc])

      false ->
        do_parse_porcelain_z(rest, acc)
    end
  end

  defp write_commit_message(message) do
    dir = Path.join(System.tmp_dir!(), "symphony_git_handoff")
    File.mkdir_p!(dir)
    path = Path.join(dir, @commit_message_prefix <> unique_token() <> ".txt")

    case File.write(path, message, [:exclusive]) do
      :ok -> {:ok, [], path}
      {:error, reason} -> {:error, failure("commit_message_write_failed", "Unable to write commit message file.", %{"reason" => inspect(reason)})}
    end
  end

  defp write_pr_body(body) do
    dir = Path.join(System.tmp_dir!(), "symphony_git_handoff")
    File.mkdir_p!(dir)
    path = Path.join(dir, "pr-body-" <> unique_token() <> ".md")

    case File.write(path, body, [:exclusive]) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, failure("pr_body_write_failed", "Unable to write PR body file.", %{"reason" => inspect(reason)})}
    end
  end

  defp commit_message_attrs(input, paths) do
    %{
      "issueIdentifier" => input.issue_identifier,
      "commitSummary" => input.commit_summary,
      "validationEvidence" => input.validation_evidence,
      "changedFiles" => paths,
      "commitType" => input.commit_type,
      "commitScope" => input.commit_scope
    }
  end

  defp required_string(attrs, key) do
    normalize_required_text(get_value(attrs, key), key)
  end

  defp required_string_list(attrs, key) do
    normalize_string_list(get_value(attrs, key), key)
  end

  defp commit_type(attrs) do
    with {:ok, value} <- normalize_required_text(get_value(attrs, "commitType") || "feat", "commitType") do
      if String.match?(value, ~r/^[a-z]+$/) do
        {:ok, value}
      else
        {:error, failure("invalid_commit_type", "commitType must be lowercase letters.")}
      end
    end
  end

  defp commit_scope(attrs) do
    case normalize_optional_text(get_value(attrs, "commitScope")) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} ->
        if String.match?(value, ~r/^[a-z0-9_-]+$/) do
          {:ok, value}
        else
          {:error, failure("invalid_commit_scope", "commitScope must contain lowercase letters, numbers, underscores, or dashes.")}
        end

      error ->
        error
    end
  end

  defp commit_subject(commit_type, nil, summary), do: "#{commit_type}: #{normalize_subject(summary)}"
  defp commit_subject(commit_type, scope, summary), do: "#{commit_type}(#{scope}): #{normalize_subject(summary)}"

  defp normalize_subject(summary) do
    summary
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.slice(0, 90)
  end

  defp normalize_required_path(value, key) do
    with {:ok, path} <- normalize_required_text(value, key) do
      {:ok, Path.expand(path)}
    end
  end

  defp normalize_required_text(value, key) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, failure("missing_#{key}", "#{key} is required.")}
      text -> {:ok, text}
    end
  end

  defp normalize_required_text(_value, key), do: {:error, failure("missing_#{key}", "#{key} is required.")}

  defp normalize_optional_text(nil), do: {:ok, nil}

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      text -> {:ok, text}
    end
  end

  defp normalize_optional_text(_value), do: {:error, failure("invalid_optional_text", "Optional text fields must be strings.")}

  defp normalize_string_list(values, key) when is_list(values) do
    normalized =
      values
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      length(normalized) != length(values) ->
        {:error, failure("invalid_#{key}", "#{key} must contain only non-empty strings.")}

      normalized == [] ->
        {:error, failure("missing_#{key}", "#{key} must include at least one value.")}

      true ->
        {:ok, normalized}
    end
  end

  defp normalize_string_list(value, key) when is_binary(value), do: normalize_string_list([value], key)
  defp normalize_string_list(_value, key), do: {:error, failure("invalid_#{key}", "#{key} must be a string list.")}

  defp normalize_boolean(value, _key) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean(nil, _key), do: {:ok, false}
  defp normalize_boolean(_value, key), do: {:error, failure("invalid_#{key}", "#{key} must be a boolean.")}

  defp normalize_optional_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_optional_binary(_value), do: nil

  defp issue_value(nil, _key), do: nil

  defp issue_value(issue, key) when is_map(issue) do
    Map.get(issue, key) || Map.get(issue, Atom.to_string(key))
  end

  defp get_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, Macro.underscore(key))
  end

  defp first_present(values) do
    Enum.find(values, fn
      nil -> false
      _value -> true
    end)
  end

  defp unsafe_artifact_path?(path) do
    components = path_segments(path)
    basename = Path.basename(path)
    extension = Path.extname(path)

    Enum.any?(components, &(&1 in ["_build", "deps", "node_modules", "coverage", "cover", "tmp", "temp", "log", "logs", ".elixir_ls"])) or
      basename in [".env", ".env.local", ".env.test", ".DS_Store", "id_rsa", "id_ed25519"] or
      String.starts_with?(basename, ".env.") or
      extension in [".log", ".tmp", ".temp", ".pid", ".beam", ".ez", ".dump", ".pem", ".key", ".p12", ".pfx"]
  end

  defp path_segments(path) do
    path
    |> Path.split()
    |> Enum.reject(&(&1 in [".", "/"]))
  end

  defp unsafe_path_error(path, reason) do
    failure("unsafe_manifest_path", "Manifest path is not safe to stage.", %{"path" => path, "reason" => reason})
  end

  defp failure(code, message, extra \\ %{}) do
    Map.merge(%{"code" => code, "message" => message}, extra)
  end

  defp unique_token do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
  end
end
