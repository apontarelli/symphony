defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, ExecutionContext, PathSafety, Shell, SSH, TargetContext}
  alias SymphonyElixir.Linear.Issue

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @context_remote_marker "__SYMPHONY_CONTEXT_WORKSPACE__"
  # SSH setup is outside the pinned hook execution budget. Once the remote shell starts the hook,
  # it owns the exact hook deadline and TERM/KILL cleanup; the caller then keeps one additional
  # second for cleanup and transport completion.
  @remote_transport_setup_timeout_ms 5_000
  @remote_cleanup_transport_grace_ms 1_000
  @remote_hook_termination_grace_ms 100

  @type worker_host :: String.t() | nil

  @spec create_for_issue(ExecutionContext.t()) :: {:ok, Path.t()} | {:error, atom()}
  def create_for_issue(%ExecutionContext{} = context), do: create_for_issue(context, [])

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier), do: create_for_issue(issue_or_identifier, nil)

  @spec create_for_issue(ExecutionContext.t(), keyword()) ::
          {:ok, Path.t()} | {:error, atom()}
  def create_for_issue(%ExecutionContext{} = context, opts) when is_list(opts) do
    with :ok <- validate_context_options(opts),
         {:ok, workspace} <- context_workspace_path(context),
         {:ok, created?} <- ensure_context_workspace(context, workspace, opts),
         :ok <- maybe_run_context_after_create_hook(context, workspace, created?, opts) do
      {:ok, workspace}
    end
  end

  def create_for_issue(%ExecutionContext{}, _opts),
    do: {:error, :invalid_workspace_options}

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp validate_context_options(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        length(keys) != length(Enum.uniq(keys)) ->
          {:error, :invalid_workspace_options}

        Enum.any?(keys, &(&1 not in [:command_runner, :ssh_runner])) ->
          {:error, :invalid_workspace_options}

        not valid_context_runner?(Keyword.get(opts, :command_runner), 3) ->
          {:error, :invalid_workspace_options}

        not valid_context_runner?(Keyword.get(opts, :ssh_runner), 3) ->
          {:error, :invalid_workspace_options}

        true ->
          :ok
      end
    else
      {:error, :invalid_workspace_options}
    end
  end

  defp valid_context_runner?(nil, _arity), do: true
  defp valid_context_runner?(runner, arity), do: is_function(runner, arity)

  defp context_workspace_path(%ExecutionContext{
         target: %TargetContext{
           target_id: target_id,
           worktree_policy:
             %{
               "root" => root,
               "strategy" => "per_issue",
               "hooks" => hooks
             } = worktree_policy
         },
         issue_identifier: issue_identifier,
         workspace_path: pinned_workspace,
         worker_host: worker_host
       }) do
    with true <- Enum.sort(Map.keys(worktree_policy)) == ~w(hooks root strategy),
         true <- valid_context_segment?(target_id, :target),
         true <- valid_context_segment?(issue_identifier, :issue),
         true <- valid_context_root?(root),
         true <- valid_context_hooks?(hooks),
         true <- valid_context_worker_host?(worker_host),
         expanded_root = Path.expand(root),
         expected_workspace = expected_context_workspace(expanded_root, target_id, issue_identifier),
         true <- pinned_workspace == expected_workspace,
         {:ok, validated_workspace} <-
           validate_context_workspace_location(expanded_root, expected_workspace, worker_host) do
      {:ok, validated_workspace}
    else
      _invalid -> {:error, :invalid_workspace_context}
    end
  end

  defp context_workspace_path(_context), do: {:error, :invalid_workspace_context}

  defp validate_context_workspace_location(root, workspace, nil) do
    with :ok <- reject_context_symlinks(root, workspace),
         {:ok, canonical_parent} <- PathSafety.canonicalize(Path.dirname(root)),
         {:ok, canonical_root} <- PathSafety.canonicalize(root),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         true <- strict_context_descendant?(canonical_root, canonical_parent),
         true <- strict_context_descendant?(canonical_workspace, canonical_root),
         true <- canonical_workspace == workspace do
      {:ok, canonical_workspace}
    else
      _invalid -> {:error, :invalid_workspace_context}
    end
  end

  defp validate_context_workspace_location(_root, workspace, worker_host)
       when is_binary(worker_host),
       do: {:ok, workspace}

  defp valid_context_segment?(value, :target) when is_binary(value) do
    String.valid?(value) and
      Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, value)
  end

  defp valid_context_segment?(value, :issue) when is_binary(value) do
    String.valid?(value) and String.trim(value) != "" and
      value not in [".", ".."] and not String.contains?(value, ["/", "\\"]) and
      not Regex.match?(~r/\p{Cc}/u, value)
  end

  defp valid_context_segment?(_value, _kind), do: false

  defp valid_context_root?(root) when is_binary(root) do
    String.valid?(root) and String.trim(root) != "" and
      Path.type(root) == :absolute and Path.expand(root) != Path.dirname(Path.expand(root)) and
      not Regex.match?(~r/\p{Cc}/u, root)
  end

  defp valid_context_root?(_root), do: false

  defp valid_context_hooks?(hooks) when is_map(hooks) and not is_struct(hooks) do
    command_keys = ~w(after_create after_run before_remove before_run)
    expected_keys = command_keys ++ ["timeout_ms"]
    valid_keys? = Enum.sort(Map.keys(hooks)) == expected_keys

    valid_commands? =
      Enum.all?(command_keys, fn key ->
        case Map.fetch!(hooks, key) do
          nil -> true
          value -> is_binary(value) and String.valid?(value)
        end
      end)

    valid_timeout? = is_integer(hooks["timeout_ms"]) and hooks["timeout_ms"] > 0
    valid_keys? and valid_commands? and valid_timeout?
  end

  defp valid_context_hooks?(_hooks), do: false

  defp valid_context_worker_host?(nil), do: true

  defp valid_context_worker_host?(worker_host) do
    match?({:ok, _target}, SSH.parse_target(worker_host))
  end

  defp expected_context_workspace(root, target_id, issue_identifier) do
    if Path.basename(root) == target_id,
      do: Path.join(root, issue_identifier),
      else: Path.join([root, target_id, issue_identifier])
  end

  defp reject_context_symlinks(root, workspace) do
    paths =
      workspace
      |> Path.relative_to(root)
      |> Path.split()
      |> Enum.scan(root, fn segment, parent -> Path.join(parent, segment) end)
      |> then(&[root | &1])

    if Enum.all?(paths, &context_path_not_symlink?/1),
      do: :ok,
      else: {:error, :invalid_workspace_context}
  end

  defp context_path_not_symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> false
      {:ok, %File.Stat{}} -> true
      {:error, :enoent} -> true
      {:error, _reason} -> false
    end
  end

  defp strict_context_descendant?(candidate, root) do
    candidate_segments = Path.split(candidate)
    root_segments = Path.split(root)

    candidate != root and Enum.take(candidate_segments, length(root_segments)) == root_segments
  end

  defp ensure_context_workspace(
         %ExecutionContext{worker_host: nil} = context,
         workspace,
         _opts
       ) do
    safe_context_call(:workspace_create_failed, fn ->
      ensure_local_context_workspace(context, workspace)
    end)
  end

  defp ensure_context_workspace(%ExecutionContext{} = context, _workspace, opts) do
    nonce = context_remote_nonce()
    script = remote_context_create_script(context, nonce)

    with {:ok, output, status} <- run_context_ssh(context, script, opts),
         {:ok, marker_status} <- parse_context_remote_output(context, output, nonce),
         :ok <- context_create_status(status, marker_status) do
      {:ok, marker_status == "created"}
    end
  end

  defp ensure_local_context_workspace(context, workspace) do
    cond do
      File.dir?(workspace) ->
        {:ok, false}

      File.exists?(workspace) ->
        replace_context_workspace(context, workspace)

      true ->
        create_context_workspace(context, workspace)
    end
  end

  defp replace_context_workspace(context, workspace) do
    result =
      with :ok <- revalidate_context_workspace(context, workspace),
           {:ok, _removed} <- File.rm_rf(workspace),
           :ok <- revalidate_context_workspace(context, workspace),
           :ok <- File.mkdir_p(workspace) do
        {:ok, true}
      end

    normalize_context_workspace_create_result(result)
  end

  defp create_context_workspace(context, workspace) do
    result =
      with :ok <- revalidate_context_workspace(context, workspace),
           :ok <- File.mkdir_p(workspace) do
        {:ok, true}
      end

    normalize_context_workspace_create_result(result)
  end

  defp normalize_context_workspace_create_result({:ok, true} = result), do: result

  defp normalize_context_workspace_create_result(result)
       when is_tuple(result) and tuple_size(result) >= 2 do
    reason = elem(result, 1)

    {:error,
     Map.get(
       %{invalid_workspace_context: :invalid_workspace_context},
       reason,
       :workspace_create_failed
     )}
  end

  defp remote_context_create_script(context, nonce) do
    root = Path.expand(context.target.worktree_policy["root"])
    root_parent = Path.dirname(root)
    root_name = Path.basename(root)
    relative_segments = context_relative_segments(context)
    issue_segment = List.last(relative_segments)
    parent_segments = Enum.drop(relative_segments, -1)
    after_create = context.target.worktree_policy["hooks"]["after_create"]
    timeout_ms = context.target.worktree_policy["hooks"]["timeout_ms"]

    ([
       "set -eu",
       remote_context_assign("root", root),
       remote_context_assign("root_parent", root_parent),
       remote_context_assign("root_name", root_name),
       remote_context_assign("issue", issue_segment),
       remote_context_assign("marker_nonce", nonce),
       remote_canonical_validator(),
       "[ ! -L \"$root_parent\" ] || exit 70",
       "[ -d \"$root_parent\" ] || exit 70",
       "canonical_root_parent=$(cd -- \"$root_parent\" && pwd -P)",
       "validate_canonical \"$canonical_root_parent\"",
       "[ \"$canonical_root_parent\" = \"$root_parent\" ] || exit 70",
       "root_candidate=\"$canonical_root_parent/$root_name\"",
       "[ \"$root_candidate\" = \"$root\" ] || exit 70",
       "[ ! -L \"$root_candidate\" ] || exit 70",
       "if [ ! -d \"$root_candidate\" ]; then",
       "  [ ! -e \"$root_candidate\" ] || exit 70",
       "  mkdir -- \"$root_candidate\"",
       "fi",
       "[ ! -L \"$root_candidate\" ] || exit 70",
       "[ -d \"$root_candidate\" ] || exit 70",
       "canonical_root=$(cd -- \"$root_candidate\" && pwd -P)",
       "validate_canonical \"$canonical_root\"",
       "[ \"$canonical_root\" = \"$root_candidate\" ] || exit 70",
       "case \"$canonical_root\" in \"$canonical_root_parent\"/*) ;; *) exit 70 ;; esac",
       "canonical_parent=\"$canonical_root\""
     ] ++
       remote_parent_segment_lines(parent_segments) ++
       [
         "workspace_candidate=\"$canonical_parent/$issue\"",
         "[ ! -L \"$workspace_candidate\" ] || exit 70",
         "created=0",
         "if [ -d \"$workspace_candidate\" ]; then",
         "  created=0",
         "elif [ -e \"$workspace_candidate\" ]; then",
         "  rm -rf -- \"$workspace_candidate\"",
         "  mkdir -- \"$workspace_candidate\"",
         "  created=1",
         "else",
         "  mkdir -- \"$workspace_candidate\"",
         "  created=1",
         "fi",
         "[ ! -L \"$workspace_candidate\" ] || exit 70",
         "canonical_workspace=$(cd -- \"$workspace_candidate\" && pwd -P)",
         "validate_canonical \"$canonical_workspace\"",
         "[ \"$canonical_workspace\" = \"$canonical_parent/$issue\" ] || exit 70",
         "case \"$canonical_workspace\" in \"$canonical_root\"/*) ;; *) exit 70 ;; esac"
       ] ++
       remote_after_create_lines(after_create, timeout_ms) ++
       [
         "if [ \"$hook_timed_out\" -eq 1 ]; then marker_status=timeout; elif [ \"$created\" -eq 1 ]; then marker_status=created; else marker_status=existing; fi",
         "printf '\\n%s\\t%s\\t%s\\t%s\\t%s\\n' '#{@context_remote_marker}' \"$marker_nonce\" \"$canonical_root\" \"$canonical_workspace\" \"$marker_status\"",
         "[ \"$hook_timed_out\" -eq 0 ] || exit 72",
         "[ \"$hook_status\" -eq 0 ] || exit 71"
       ])
    |> Enum.join("\n")
  end

  defp remote_parent_segment_lines(segments) do
    Enum.flat_map(segments, fn segment ->
      [
        remote_context_assign("segment", segment),
        "next_path=\"$canonical_parent/$segment\"",
        "[ ! -L \"$next_path\" ] || exit 70",
        "if [ ! -d \"$next_path\" ]; then",
        "  [ ! -e \"$next_path\" ] || exit 70",
        "  mkdir -- \"$next_path\"",
        "fi",
        "[ ! -L \"$next_path\" ] || exit 70",
        "canonical_parent=$(cd -- \"$next_path\" && pwd -P)",
        "validate_canonical \"$canonical_parent\"",
        "[ \"$canonical_parent\" = \"$next_path\" ] || exit 70"
      ]
    end)
  end

  defp remote_after_create_lines(nil, _timeout_ms), do: ["hook_status=0", "hook_timed_out=0"]

  defp remote_after_create_lines(command, timeout_ms) when is_binary(command) do
    hook_lines =
      command
      |> remote_timed_hook_lines(timeout_ms)
      |> Enum.map(&"  #{&1}")

    ["if [ \"$created\" -eq 1 ]; then"] ++
      hook_lines ++ ["else", "  hook_status=0", "  hook_timed_out=0", "fi"]
  end

  defp remote_canonical_validator do
    """
    validate_canonical() {
      value=$1
      case "$value" in /*) ;; *) exit 70 ;; esac
      case "$value" in *'
    '*|*'\r'*) exit 70 ;; esac
      cleaned=$(printf '%s' "$value" | LC_ALL=C tr -d '[:cntrl:]')
      [ "$cleaned" = "$value" ] || exit 70
    }
    """
    |> String.trim()
  end

  defp remote_context_assign(name, value), do: "#{name}=#{Shell.escape(value)}"

  defp context_relative_segments(context) do
    root = Path.expand(context.target.worktree_policy["root"])
    Path.relative_to(context.workspace_path, root) |> Path.split()
  end

  defp run_context_ssh(context, script, opts) do
    hook_timeout_ms = context.target.worktree_policy["hooks"]["timeout_ms"]

    outer_timeout_ms =
      hook_timeout_ms + @remote_transport_setup_timeout_ms + @remote_cleanup_transport_grace_ms

    runner = Keyword.get(opts, :ssh_runner, &default_context_ssh_runner/3)

    task =
      Task.async(fn ->
        safe_context_call(:workspace_remote_dependency_failed, fn ->
          normalize_context_ssh_result(runner.(context.worker_host, script, outer_timeout_ms))
        end)
      end)

    case Task.yield(task, outer_timeout_ms) do
      {:ok, {:ok, {output, status}}} ->
        {:ok, output, status}

      {:ok, {:error, :timeout}} ->
        {:error, :workspace_remote_timeout}

      {:ok, {:error, _reason}} ->
        {:error, :workspace_remote_dependency_failed}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :workspace_remote_timeout}
    end
  end

  defp default_context_ssh_runner(worker_host, script, _timeout_ms) do
    SSH.run(worker_host, script, stderr_to_stdout: true)
  end

  defp normalize_context_ssh_result({output, status})
       when is_binary(output) and is_integer(status) and status >= 0,
       do: {:ok, {output, status}}

  defp normalize_context_ssh_result({:ok, {output, status}})
       when is_binary(output) and is_integer(status) and status >= 0,
       do: {:ok, {output, status}}

  defp normalize_context_ssh_result({:error, :timeout}), do: {:error, :timeout}

  defp normalize_context_ssh_result(_result), do: {:error, :invalid_result}

  defp parse_context_remote_output(context, output, expected_nonce)
       when is_binary(output) and is_binary(expected_nonce) do
    with true <- valid_context_remote_nonce?(expected_nonce),
         true <- String.valid?(output),
         marker_lines <-
           output
           |> String.split("\n", trim: true)
           |> Enum.filter(&String.starts_with?(&1, @context_remote_marker <> "\t")),
         [marker_line] <- marker_lines,
         [@context_remote_marker, marker_nonce, canonical_root, canonical_workspace, marker_status] <-
           String.split(marker_line, "\t", trim: false),
         true <- marker_nonce == expected_nonce,
         true <- valid_context_remote_nonce?(marker_nonce),
         true <- valid_remote_canonical_path?(canonical_root),
         true <- canonical_root == Path.expand(context.target.worktree_policy["root"]),
         true <- valid_remote_canonical_path?(canonical_workspace),
         true <- strict_context_descendant?(canonical_workspace, canonical_root),
         true <-
           canonical_workspace ==
             Path.join([canonical_root | context_relative_segments(context)]) do
      {:ok, marker_status}
    else
      _invalid -> {:error, :workspace_remote_output_invalid}
    end
  end

  defp valid_context_remote_nonce?(nonce), do: Regex.match?(~r/^[0-9a-f]{32}$/, nonce)

  defp valid_remote_canonical_path?(path) do
    String.valid?(path) and Path.type(path) == :absolute and
      Path.expand(path) == path and not Regex.match?(~r/\p{Cc}/u, path)
  end

  defp context_create_status(72, "timeout"), do: {:error, :workspace_remote_timeout}

  defp context_create_status(0, marker_status) when marker_status in ["created", "existing"],
    do: :ok

  defp context_create_status(71, marker_status) when marker_status in ["created", "existing"],
    do: {:error, :workspace_hook_failed}

  defp context_create_status(_status, marker_status)
       when marker_status in ["created", "existing"],
       do: {:error, :workspace_remote_operation_failed}

  defp context_create_status(_status, _marker_status),
    do: {:error, :workspace_remote_output_invalid}

  defp remote_context_hook_script(context, command, nonce) do
    timeout_ms = context.target.worktree_policy["hooks"]["timeout_ms"]

    (remote_context_existing_lines(context) ++
       [remote_context_assign("marker_nonce", nonce)] ++
       remote_timed_hook_lines(command, timeout_ms) ++
       [
         "if [ \"$hook_timed_out\" -eq 1 ]; then marker_status=timeout; else marker_status=hooked; fi",
         "printf '\\n%s\\t%s\\t%s\\t%s\\t%s\\n' '#{@context_remote_marker}' \"$marker_nonce\" \"$canonical_root\" \"$canonical_workspace\" \"$marker_status\"",
         "[ \"$hook_timed_out\" -eq 0 ] || exit 72",
         "exit \"$hook_status\""
       ])
    |> Enum.join("\n")
  end

  defp remote_context_existing_lines(context) do
    remote_context_parent_authority_lines(context) ++
      [
        "workspace_candidate=\"$canonical_parent/$issue\"",
        "[ ! -L \"$workspace_candidate\" ] || exit 70",
        "[ -d \"$workspace_candidate\" ] || exit 70",
        "canonical_workspace=$(cd -- \"$workspace_candidate\" && pwd -P)",
        "validate_canonical \"$canonical_workspace\"",
        "[ \"$canonical_workspace\" = \"$canonical_parent/$issue\" ] || exit 70",
        "case \"$canonical_workspace\" in \"$canonical_root\"/*) ;; *) exit 70 ;; esac"
      ]
  end

  defp remote_context_parent_authority_lines(context) do
    root = Path.expand(context.target.worktree_policy["root"])
    root_parent = Path.dirname(root)
    root_name = Path.basename(root)
    relative_segments = context_relative_segments(context)
    issue_segment = List.last(relative_segments)
    parent_segments = Enum.drop(relative_segments, -1)

    [
      "set -eu",
      remote_context_assign("root", root),
      remote_context_assign("root_parent", root_parent),
      remote_context_assign("root_name", root_name),
      remote_context_assign("issue", issue_segment),
      remote_canonical_validator(),
      "[ ! -L \"$root_parent\" ] || exit 70",
      "[ -d \"$root_parent\" ] || exit 70",
      "canonical_root_parent=$(cd -- \"$root_parent\" && pwd -P)",
      "validate_canonical \"$canonical_root_parent\"",
      "[ \"$canonical_root_parent\" = \"$root_parent\" ] || exit 70",
      "root_candidate=\"$canonical_root_parent/$root_name\"",
      "[ \"$root_candidate\" = \"$root\" ] || exit 70",
      "[ ! -L \"$root_candidate\" ] || exit 70",
      "[ -d \"$root_candidate\" ] || exit 70",
      "canonical_root=$(cd -- \"$root_candidate\" && pwd -P)",
      "validate_canonical \"$canonical_root\"",
      "[ \"$canonical_root\" = \"$root_candidate\" ] || exit 70",
      "case \"$canonical_root\" in \"$canonical_root_parent\"/*) ;; *) exit 70 ;; esac",
      "canonical_parent=\"$canonical_root\""
    ] ++ remote_existing_parent_segment_lines(parent_segments)
  end

  defp remote_context_delete_authority_lines(context, nonce) do
    root = Path.expand(context.target.worktree_policy["root"])
    root_parent = Path.dirname(root)
    root_name = Path.basename(root)
    relative_segments = context_relative_segments(context)
    issue_segment = List.last(relative_segments)
    parent_segments = Enum.drop(relative_segments, -1)
    workspace_relative = Path.join(relative_segments)

    [
      "set -eu",
      remote_context_assign("root", root),
      remote_context_assign("root_parent", root_parent),
      remote_context_assign("root_name", root_name),
      remote_context_assign("issue", issue_segment),
      remote_context_assign("expected_workspace", context.workspace_path),
      remote_context_assign("workspace_relative", workspace_relative),
      remote_context_assign("marker_nonce", nonce),
      remote_canonical_validator(),
      "[ ! -L \"$root_parent\" ] || exit 70",
      "[ -d \"$root_parent\" ] || exit 70",
      "canonical_root_parent=$(cd -- \"$root_parent\" && pwd -P)",
      "validate_canonical \"$canonical_root_parent\"",
      "[ \"$canonical_root_parent\" = \"$root_parent\" ] || exit 70",
      "root_candidate=\"$canonical_root_parent/$root_name\"",
      "[ \"$root_candidate\" = \"$root\" ] || exit 70",
      "[ ! -L \"$root_candidate\" ] || exit 70",
      "if [ ! -e \"$root_candidate\" ]; then",
      "  canonical_root=\"$root_candidate\"",
      "  canonical_workspace=\"$expected_workspace\"",
      "  validate_canonical \"$canonical_root\"",
      "  validate_canonical \"$canonical_workspace\"",
      "  [ \"$canonical_workspace\" = \"$canonical_root/$workspace_relative\" ] || exit 70",
      "  case \"$canonical_workspace\" in \"$canonical_root\"/*) ;; *) exit 70 ;; esac",
      "  printf '\\n%s\\t%s\\t%s\\t%s\\t%s\\n' '#{@context_remote_marker}' \"$marker_nonce\" \"$canonical_root\" \"$canonical_workspace\" 'deleted'",
      "  exit 0",
      "fi",
      "[ -d \"$root_candidate\" ] || exit 70",
      "canonical_root=$(cd -- \"$root_candidate\" && pwd -P)",
      "validate_canonical \"$canonical_root\"",
      "[ \"$canonical_root\" = \"$root_candidate\" ] || exit 70",
      "case \"$canonical_root\" in \"$canonical_root_parent\"/*) ;; *) exit 70 ;; esac",
      "canonical_parent=\"$canonical_root\""
    ] ++ remote_existing_parent_segment_lines(parent_segments)
  end

  defp remote_existing_parent_segment_lines(segments) do
    Enum.flat_map(segments, fn segment ->
      [
        remote_context_assign("segment", segment),
        "next_path=\"$canonical_parent/$segment\"",
        "[ ! -L \"$next_path\" ] || exit 70",
        "[ -d \"$next_path\" ] || exit 70",
        "canonical_parent=$(cd -- \"$next_path\" && pwd -P)",
        "validate_canonical \"$canonical_parent\"",
        "[ \"$canonical_parent\" = \"$next_path\" ] || exit 70"
      ]
    end)
  end

  defp run_context_remote_hook(context, command, opts) do
    nonce = context_remote_nonce()
    script = remote_context_hook_script(context, command, nonce)

    with {:ok, output, status} <- run_context_ssh(context, script, opts),
         {:ok, marker_status} <- parse_context_remote_output(context, output, nonce) do
      context_hook_status(status, marker_status)
    end
  end

  defp context_hook_status(72, "timeout"), do: {:error, :workspace_remote_timeout}
  defp context_hook_status(0, "hooked"), do: :ok
  defp context_hook_status(_status, "hooked"), do: {:error, :workspace_hook_failed}
  defp context_hook_status(_status, _marker_status), do: {:error, :workspace_remote_output_invalid}

  defp remote_context_delete_script(context, nonce) do
    before_remove = context.target.worktree_policy["hooks"]["before_remove"]
    timeout_ms = context.target.worktree_policy["hooks"]["timeout_ms"]

    (remote_context_delete_authority_lines(context, nonce) ++
       [
         "workspace_candidate=\"$canonical_parent/$issue\"",
         "[ ! -L \"$workspace_candidate\" ] || exit 70",
         "canonical_workspace=\"$workspace_candidate\"",
         "validate_canonical \"$canonical_workspace\"",
         "[ \"$canonical_workspace\" = \"$canonical_parent/$issue\" ] || exit 70",
         "case \"$canonical_workspace\" in \"$canonical_root\"/*) ;; *) exit 70 ;; esac",
         "if [ ! -e \"$workspace_candidate\" ]; then",
         "  printf '\\n%s\\t%s\\t%s\\t%s\\t%s\\n' '#{@context_remote_marker}' \"$marker_nonce\" \"$canonical_root\" \"$canonical_workspace\" 'deleted'",
         "  exit 0",
         "fi",
         "[ -d \"$workspace_candidate\" ] || exit 70",
         "canonical_workspace=$(cd -- \"$workspace_candidate\" && pwd -P)",
         "validate_canonical \"$canonical_workspace\"",
         "[ \"$canonical_workspace\" = \"$canonical_parent/$issue\" ] || exit 70",
         "case \"$canonical_workspace\" in \"$canonical_root\"/*) ;; *) exit 70 ;; esac"
       ] ++
       remote_before_remove_lines(before_remove, timeout_ms) ++
       [
         "if [ \"$hook_timed_out\" -eq 1 ]; then",
         "  printf '\\n%s\\t%s\\t%s\\t%s\\t%s\\n' '#{@context_remote_marker}' \"$marker_nonce\" \"$canonical_root\" \"$canonical_workspace\" 'timeout'",
         "  exit 72",
         "fi"
       ] ++
       remote_context_existing_lines(context) ++
       [
         "[ \"$canonical_workspace\" != \"$canonical_root\" ] || exit 70",
         "rm -rf -- \"$canonical_workspace\"",
         "[ ! -L \"$canonical_workspace\" ] || exit 70",
         "[ ! -e \"$canonical_workspace\" ] || exit 70",
         "printf '\\n%s\\t%s\\t%s\\t%s\\t%s\\n' '#{@context_remote_marker}' \"$marker_nonce\" \"$canonical_root\" \"$canonical_workspace\" 'deleted'"
       ])
    |> Enum.join("\n")
  end

  defp remote_before_remove_lines(nil, _timeout_ms), do: ["hook_status=0", "hook_timed_out=0"]

  defp remote_before_remove_lines(command, timeout_ms) when is_binary(command),
    do: remote_timed_hook_lines(command, timeout_ms)

  defp remote_timed_hook_lines(command, timeout_ms) do
    [
      "hook_status=0",
      "hook_timed_out=0",
      "hook_lifecycle_status=0",
      "hook_state_dir=\"${TMPDIR:-/tmp}/.symphony-hook-${marker_nonce}-$$\"",
      "hook_timeout_marker=\"$hook_state_dir/timeout\"",
      "hook_outcome_lock=\"$hook_state_dir/outcome\"",
      "(umask 077 && mkdir -- \"$hook_state_dir\") || exit 70",
      "hook_cleanup() { rm -rf -- \"$hook_state_dir\"; }",
      "trap 'hook_cleanup' 0",
      "trap 'exit 70' 1 2 15",
      "set +e",
      "set -m",
      "(cd -- \"$canonical_workspace\" && exec sh -lc #{Shell.escape(command)}) &",
      "hook_pid=$!",
      "set +m",
      "set -m",
      "(",
      "  trap - 0 1 2 15",
      "  sleep #{remote_timeout_seconds(timeout_ms)}",
      "  if mkdir -- \"$hook_outcome_lock\" 2>/dev/null; then",
      "    if ! : > \"$hook_timeout_marker\"; then",
      "      kill -KILL -- \"-$hook_pid\" 2>/dev/null",
      "      while kill -0 -- \"-$hook_pid\" 2>/dev/null; do sleep 0.010; done",
      "      exit 73",
      "    fi",
      "    kill -TERM -- \"-$hook_pid\" 2>/dev/null",
      "    sleep #{remote_timeout_seconds(@remote_hook_termination_grace_ms)}",
      "    if kill -0 -- \"-$hook_pid\" 2>/dev/null; then",
      "      kill -KILL -- \"-$hook_pid\" 2>/dev/null",
      "    fi",
      "    while kill -0 -- \"-$hook_pid\" 2>/dev/null; do sleep 0.010; done",
      "    exit 72",
      "  fi",
      "  exit 0",
      ") &",
      "timer_pid=$!",
      "set +m",
      "wait \"$hook_pid\"",
      "hook_status=$?",
      "if mkdir -- \"$hook_outcome_lock\" 2>/dev/null; then",
      "  if kill -0 -- \"-$timer_pid\" 2>/dev/null; then",
      "    kill -TERM -- \"-$timer_pid\" 2>/dev/null",
      "  fi",
      "  wait \"$timer_pid\"",
      "  if kill -0 -- \"-$hook_pid\" 2>/dev/null; then",
      "    kill -TERM -- \"-$hook_pid\" 2>/dev/null",
      "    sleep #{remote_timeout_seconds(@remote_hook_termination_grace_ms)}",
      "    if kill -0 -- \"-$hook_pid\" 2>/dev/null; then",
      "      kill -KILL -- \"-$hook_pid\" 2>/dev/null",
      "    fi",
      "    while kill -0 -- \"-$hook_pid\" 2>/dev/null; do sleep 0.010; done",
      "  fi",
      "else",
      "  wait \"$timer_pid\"",
      "  timer_status=$?",
      "  if [ \"$timer_status\" -eq 72 ] && [ -f \"$hook_timeout_marker\" ]; then",
      "    hook_timed_out=1",
      "  else",
      "    hook_lifecycle_status=70",
      "  fi",
      "fi",
      "rm -rf -- \"$hook_state_dir\"",
      "trap - 0 1 2 15",
      "set -e",
      "[ \"$hook_lifecycle_status\" -eq 0 ] || exit 70"
    ]
  end

  defp remote_timeout_seconds(timeout_ms) do
    whole_seconds = div(timeout_ms, 1_000)
    milliseconds = timeout_ms |> rem(1_000) |> Integer.to_string() |> String.pad_leading(3, "0")
    "#{whole_seconds}.#{milliseconds}"
  end

  defp remove_context_remote_workspace(context, opts) do
    nonce = context_remote_nonce()
    script = remote_context_delete_script(context, nonce)

    with {:ok, output, status} <- run_context_ssh(context, script, opts),
         {:ok, marker_status} <- parse_context_remote_output(context, output, nonce),
         :ok <- validate_context_delete_status(status, marker_status) do
      {:ok, []}
    end
  end

  defp validate_context_delete_status(72, "timeout"),
    do: {:error, :workspace_remote_timeout}

  defp validate_context_delete_status(0, "deleted"), do: :ok

  defp validate_context_delete_status(_status, "deleted"),
    do: {:error, :workspace_remote_operation_failed}

  defp validate_context_delete_status(_status, _marker_status),
    do: {:error, :workspace_remote_output_invalid}

  defp context_remote_nonce do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp revalidate_context_workspace(context, workspace) do
    case context_workspace_path(context) do
      {:ok, ^workspace} -> :ok
      _invalid -> {:error, :invalid_workspace_context}
    end
  end

  defp maybe_run_context_after_create_hook(
         %ExecutionContext{worker_host: worker_host},
         _workspace,
         _created?,
         _opts
       )
       when is_binary(worker_host),
       do: :ok

  defp maybe_run_context_after_create_hook(
         %ExecutionContext{target: %{worktree_policy: %{"hooks" => %{"after_create" => nil}}}},
         _workspace,
         _created?,
         _opts
       ),
       do: :ok

  defp maybe_run_context_after_create_hook(_context, _workspace, false, _opts), do: :ok

  defp maybe_run_context_after_create_hook(context, workspace, true, opts) do
    command = context.target.worktree_policy["hooks"]["after_create"]
    run_context_local_hook(context, workspace, command, "after_create", opts)
  end

  defp run_context_local_hook(context, workspace, command, _hook_name, opts)
       when is_binary(command) do
    timeout_ms = context.target.worktree_policy["hooks"]["timeout_ms"]

    with :ok <- revalidate_context_workspace(context, workspace) do
      run_context_command(command, workspace, timeout_ms, opts)
    end
  end

  defp run_context_command(command, workspace, timeout_ms, opts) do
    runner = Keyword.get(opts, :command_runner, &default_context_command_runner/3)

    task =
      Task.async(fn ->
        safe_context_call(:workspace_hook_dependency_failed, fn ->
          normalize_context_command_result(runner.(command, workspace, timeout_ms))
        end)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:ok, {_output, 0}}} ->
        :ok

      {:ok, {:ok, {_output, _status}}} ->
        {:error, :workspace_hook_failed}

      {:ok, {:error, _reason}} ->
        {:error, :workspace_hook_dependency_failed}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :workspace_hook_timeout}
    end
  end

  defp default_context_command_runner(command, workspace, _timeout_ms) do
    System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
  end

  defp normalize_context_command_result({output, status})
       when is_binary(output) and is_integer(status) and status >= 0 do
    {:ok, {output, status}}
  end

  defp normalize_context_command_result({:ok, {output, status}})
       when is_binary(output) and is_integer(status) and status >= 0 do
    {:ok, {output, status}}
  end

  defp normalize_context_command_result(_result), do: {:error, :invalid_result}

  defp safe_context_call(error, fun) when is_atom(error) and is_function(fun, 0) do
    fun.()
  rescue
    _exception -> {:error, error}
  catch
    _kind, _reason -> {:error, error}
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(ExecutionContext.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def remove(%ExecutionContext{} = context), do: remove(context, [])

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(ExecutionContext.t(), keyword()) :: {:ok, [String.t()]} | {:error, atom()}
  def remove(%ExecutionContext{} = context, opts) when is_list(opts) do
    with :ok <- validate_context_options(opts),
         {:ok, workspace} <- context_workspace_path(context) do
      remove_context_workspace(context, workspace, opts)
    end
  end

  def remove(%ExecutionContext{}, _opts),
    do: {:error, :invalid_workspace_options}

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  defp remove_context_workspace(%ExecutionContext{worker_host: nil} = context, workspace, opts) do
    safe_context_call(:workspace_remove_failed, fn ->
      remove_local_context_workspace(context, workspace, opts)
    end)
  end

  defp remove_context_workspace(%ExecutionContext{} = context, _workspace, opts),
    do: remove_context_remote_workspace(context, opts)

  defp remove_local_context_workspace(context, workspace, opts) do
    if File.exists?(workspace),
      do: remove_existing_context_workspace(context, workspace, opts),
      else: {:ok, []}
  end

  defp remove_existing_context_workspace(context, workspace, opts) do
    with :ok <- revalidate_context_workspace(context, workspace),
         :ok <- run_context_before_remove_hook(context, workspace, opts),
         :ok <- revalidate_context_workspace(context, workspace) do
      remove_context_workspace_path(workspace)
    end
  end

  defp remove_context_workspace_path(workspace) do
    case File.rm_rf(workspace) do
      {:ok, removed} -> {:ok, removed}
      {:error, _reason, _path} -> {:error, :workspace_remove_failed}
    end
  end

  defp run_context_before_remove_hook(context, workspace, opts) do
    if File.dir?(workspace) do
      context
      |> run_context_hook(workspace, "before_remove", opts)
      |> ignore_context_hook_failure()
    else
      :ok
    end
  end

  @spec remove_issue_workspaces(TargetContext.t(), String.t(), worker_host()) ::
          :ok | {:error, atom()}
  def remove_issue_workspaces(%TargetContext{} = target, identifier, worker_host),
    do: remove_issue_workspaces(target, identifier, worker_host, [])

  @spec remove_issue_workspaces(TargetContext.t(), String.t(), worker_host(), keyword()) ::
          :ok | {:error, atom()}
  def remove_issue_workspaces(%TargetContext{} = target, identifier, worker_host, opts)
      when is_list(opts) do
    with :ok <- validate_context_options(opts),
         {:ok, workspace} <- target_context_workspace_path(target, identifier, worker_host) do
      remove_target_context_workspace(target, identifier, worker_host, workspace, opts)
    end
  end

  def remove_issue_workspaces(%TargetContext{}, _identifier, _worker_host, _opts),
    do: {:error, :invalid_workspace_options}

  defp target_context_workspace_path(
         %TargetContext{
           target_id: target_id,
           worktree_policy:
             %{
               "root" => root,
               "strategy" => "per_issue",
               "hooks" => hooks
             } = worktree_policy
         },
         identifier,
         worker_host
       ) do
    with true <- Enum.sort(Map.keys(worktree_policy)) == ~w(hooks root strategy),
         true <- valid_context_segment?(target_id, :target),
         true <- valid_context_segment?(identifier, :issue),
         true <- valid_context_root?(root),
         true <- valid_context_hooks?(hooks),
         true <- valid_context_worker_host?(worker_host),
         expanded_root = Path.expand(root),
         expected_workspace = expected_context_workspace(expanded_root, target_id, identifier),
         {:ok, validated_workspace} <-
           validate_context_workspace_location(expanded_root, expected_workspace, worker_host) do
      {:ok, validated_workspace}
    else
      _invalid -> {:error, :invalid_workspace_context}
    end
  end

  defp target_context_workspace_path(_target, _identifier, _worker_host),
    do: {:error, :invalid_workspace_context}

  defp remove_target_context_workspace(target, identifier, nil, workspace, opts) do
    safe_context_call(:workspace_remove_failed, fn ->
      remove_local_target_workspace(target, identifier, workspace, opts)
    end)
  end

  defp remove_target_context_workspace(
         target,
         _identifier,
         worker_host,
         workspace,
         opts
       )
       when is_binary(worker_host) do
    authority = %{target: target, workspace_path: workspace, worker_host: worker_host}

    case remove_context_remote_workspace(authority, opts) do
      {:ok, []} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp remove_local_target_workspace(target, identifier, workspace, opts) do
    if File.exists?(workspace),
      do: remove_existing_target_workspace(target, identifier, workspace, opts),
      else: :ok
  end

  defp remove_existing_target_workspace(target, identifier, workspace, opts) do
    with :ok <- revalidate_target_workspace(target, identifier, nil, workspace),
         :ok <- run_target_before_remove_hook(target, identifier, workspace, opts),
         :ok <- revalidate_target_workspace(target, identifier, nil, workspace) do
      remove_target_workspace_path(workspace)
    end
  end

  defp remove_target_workspace_path(workspace) do
    case File.rm_rf(workspace) do
      {:ok, _removed} -> :ok
      {:error, _reason, _path} -> {:error, :workspace_remove_failed}
    end
  end

  defp revalidate_target_workspace(target, identifier, worker_host, workspace) do
    case target_context_workspace_path(target, identifier, worker_host) do
      {:ok, ^workspace} -> :ok
      _invalid -> {:error, :invalid_workspace_context}
    end
  end

  defp run_target_before_remove_hook(target, identifier, workspace, opts) do
    case target.worktree_policy["hooks"]["before_remove"] do
      nil ->
        :ok

      command ->
        with :ok <- revalidate_target_workspace(target, identifier, nil, workspace) do
          command
          |> run_context_command(
            workspace,
            target.worktree_policy["hooks"]["timeout_ms"],
            opts
          )
          |> ignore_context_hook_failure()
        end
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    {:ok, workspace} = workspace_path_for_issue(safe_id, worker_host)
    remove(workspace, worker_host)

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(ExecutionContext.t(), Issue.t()) :: :ok | {:error, atom()}
  def run_before_run_hook(%ExecutionContext{} = context, %Issue{} = issue),
    do: run_before_run_hook(context, issue, [])

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier) when is_binary(workspace),
    do: run_before_run_hook(workspace, issue_or_identifier, nil)

  @spec run_before_run_hook(ExecutionContext.t(), Issue.t(), keyword()) ::
          :ok | {:error, atom()}
  def run_before_run_hook(%ExecutionContext{} = context, %Issue{} = issue, opts)
      when is_list(opts) do
    with :ok <- validate_context_options(opts),
         :ok <- validate_context_issue(context, issue),
         {:ok, workspace} <- context_workspace_path(context) do
      run_context_hook(context, workspace, "before_run", opts)
    end
  end

  def run_before_run_hook(%ExecutionContext{}, %Issue{}, _opts),
    do: {:error, :invalid_workspace_options}

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  defp validate_context_issue(
         %ExecutionContext{issue_id: issue_id, issue_identifier: issue_identifier},
         %Issue{id: issue_id, identifier: issue_identifier}
       )
       when is_binary(issue_id) and is_binary(issue_identifier),
       do: :ok

  defp validate_context_issue(_context, _issue), do: {:error, :invalid_workspace_issue}

  defp run_context_hook(context, workspace, hook_name, opts) do
    command = context.target.worktree_policy["hooks"][hook_name]

    case {command, context.worker_host} do
      {nil, _worker_host} ->
        :ok

      {command, nil} ->
        run_context_local_hook(context, workspace, command, hook_name, opts)

      {command, worker_host} when is_binary(worker_host) ->
        run_context_remote_hook(context, command, opts)
    end
  end

  @spec run_after_run_hook(ExecutionContext.t(), Issue.t()) :: :ok | {:error, atom()}
  def run_after_run_hook(%ExecutionContext{} = context, %Issue{} = issue),
    do: run_after_run_hook(context, issue, [])

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier) when is_binary(workspace),
    do: run_after_run_hook(workspace, issue_or_identifier, nil)

  @spec run_after_run_hook(ExecutionContext.t(), Issue.t(), keyword()) ::
          :ok | {:error, atom()}
  def run_after_run_hook(%ExecutionContext{} = context, %Issue{} = issue, opts)
      when is_list(opts) do
    with :ok <- validate_context_options(opts),
         :ok <- validate_context_issue(context, issue),
         {:ok, workspace} <- context_workspace_path(context) do
      context
      |> run_context_hook(workspace, "after_run", opts)
      |> ignore_context_hook_failure()
    end
  end

  def run_after_run_hook(%ExecutionContext{}, %Issue{}, _opts),
    do: {:error, :invalid_workspace_options}

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp ignore_context_hook_failure(:ok), do: :ok
  defp ignore_context_hook_failure({:error, :workspace_remote_timeout} = error), do: error
  defp ignore_context_hook_failure({:error, _reason}), do: :ok

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{Shell.escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    if String.contains?(workspace, ["\n", "\r", <<0>>]),
      do: {:error, {:workspace_path_unreadable, workspace, :invalid_characters}},
      else: :ok
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{Shell.escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp worker_host_for_log(worker_host), do: worker_host || "local"

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
