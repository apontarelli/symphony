defmodule SymphonyElixir.OperatorBranchCatalog do
  @moduledoc false

  alias SymphonyElixir.ProcessSupervisor

  @git_env [
    {"GIT_OPTIONAL_LOCKS", "0"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", false},
    {"GIT_CONFIG_COUNT", false},
    {"GIT_CONFIG_PARAMETERS", false},
    {"GIT_DIR", false},
    {"GIT_COMMON_DIR", false},
    {"GIT_WORK_TREE", false},
    {"GIT_INDEX_FILE", false},
    {"GIT_OBJECT_DIRECTORY", false},
    {"GIT_ALTERNATE_OBJECT_DIRECTORIES", false}
  ]

  @default_timeout_ms 2_000
  @max_timeout_ms 30_000
  @max_output_bytes 262_144

  @git_ref_format "%(refname)%00%(upstream:short)%00%(upstream:remotename)%00%(HEAD)%00%(objectname)"
  @jj_bookmark_template ~S|name ++ "\0" ++ remote ++ "\0" ++ if(present, "present", "absent") ++ "\0" ++ if(tracked, "tracked", "") ++ "\0" ++ if(tracking_present, "tracking", "") ++ "\n"|

  @type choice :: %{
          required(:value) => String.t(),
          required(:label) => String.t(),
          required(:status) => String.t(),
          required(:reason) => String.t() | nil,
          required(:current) => boolean(),
          required(:manifest_default) => boolean(),
          required(:configured) => boolean(),
          optional(:remote) => String.t() | nil,
          optional(:remote_ref) => String.t() | nil,
          optional(:remote_names) => [String.t()],
          optional(:remote_refs) => [String.t()],
          optional(:upstream) => String.t() | nil,
          optional(:remote_tracking) => boolean(),
          optional(:remote_default) => boolean()
        }

  @type catalog :: %{
          required(:repository) => String.t() | nil,
          required(:vcs) => String.t() | nil,
          required(:status) => String.t(),
          required(:reason) => String.t() | nil,
          required(:choices) => [choice()],
          required(:selected) => String.t() | nil,
          required(:apply_allowed) => boolean(),
          required(:typed_fallback) => boolean()
        }

  @spec discover(map(), keyword()) :: catalog()
  def discover(inspection, opts \\ [])

  @spec discover(map(), keyword()) :: catalog()
  def discover(inspection, opts) when is_map(inspection) and is_list(opts) do
    repository = value(inspection, :path)
    vcs = value(inspection, :vcs)
    selected = configured_target(opts)
    manifest_default = normalize_manifest_default(value(inspection, :default_branch))

    base = %{
      repository: repository,
      vcs: vcs,
      status: "unavailable",
      reason: "repository_not_ready",
      choices: [],
      selected: selected,
      apply_allowed: false,
      typed_fallback: false
    }

    cond do
      value(inspection, :state) != "ready" ->
        base

      not is_binary(repository) or not String.valid?(repository) ->
        %{base | reason: "repository_unavailable"}

      vcs not in ["git", "jj"] ->
        %{base | reason: "unsupported_vcs"}

      cancelled?(opts) ->
        %{base | reason: "discovery_cancelled"}

      true ->
        discover_ready(base, manifest_default, opts)
    end
  end

  def discover(_inspection, _opts),
    do: unavailable(%{repository: nil, vcs: nil, selected: nil}, :invalid_inspection, false)

  defp discover_ready(base, manifest_default, opts) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms(opts)

    result =
      discover_vcs(base.vcs, base.repository, base.selected, manifest_default, deadline_ms, command_runner(opts), opts)

    if cancelled?(opts) do
      unavailable(base, :cancelled, false)
    else
      finish_discovery(base, result)
    end
  end

  defp finish_discovery(base, {:ok, choices}), do: finish_current(base, choices, base.selected)
  defp finish_discovery(base, {:error, reason}), do: unavailable(base, reason, reason != :cancelled)

  defp discover_vcs("git", repository, selected, manifest_default, deadline_ms, runner, opts),
    do: discover_git(repository, selected, manifest_default, deadline_ms, runner, opts)

  defp discover_vcs("jj", repository, selected, manifest_default, deadline_ms, runner, opts),
    do: discover_jj(repository, selected, manifest_default, deadline_ms, runner, opts)

  defp discover_git(repository, selected, manifest_default, deadline_ms, runner, opts) do
    with :ok <- check_cancel(opts),
         {:ok, remote_output} <- run_command(runner, ["git", "remote"], repository, deadline_ms),
         {:ok, remotes} <- parse_git_remotes(remote_output),
         :ok <- check_cancel(opts),
         {:ok, output} <-
           run_command(
             runner,
             ["git", "for-each-ref", "--format=#{@git_ref_format}", "refs/heads", "refs/remotes"],
             repository,
             deadline_ms
           ),
         {:ok, rows} <- parse_git_rows(output, remotes),
         :ok <- check_cancel(opts),
         {:ok, remote_default} <- git_remote_default(repository, deadline_ms, runner),
         :ok <- check_cancel(opts) do
      {:ok, build_choices(rows, selected, manifest_default, remote_default)}
    end
  end

  defp discover_jj(repository, selected, manifest_default, deadline_ms, runner, opts) do
    with :ok <- check_cancel(opts),
         {:ok, output} <-
           run_command(
             runner,
             [
               "jj",
               "--ignore-working-copy",
               "--at-operation=@",
               "--repository",
               repository,
               "bookmark",
               "list",
               "--all-remotes",
               "--sort",
               "name",
               "--template",
               @jj_bookmark_template
             ],
             repository,
             deadline_ms
           ),
         {:ok, rows} <- parse_jj_rows(output),
         :ok <- check_cancel(opts) do
      {:ok, build_choices(rows, selected, manifest_default, nil)}
    end
  end

  defp git_remote_default(repository, deadline_ms, runner) do
    case run_command(
           runner,
           ["git", "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"],
           repository,
           deadline_ms
         ) do
      {:ok, output} ->
        parse_git_remote_default(output)

      # An absent origin or origin/HEAD is a valid repository state. Other
      # non-zero exits are deliberately treated the same way: branch refs are
      # still useful, and no command output is retained in the catalog.
      {:error, {:command_failed, _status}} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_git_remote_default(output) do
    case String.split(output, "\n", trim: true) do
      ["refs/remotes/origin/" <> branch] ->
        if valid_target?(branch), do: {:ok, branch}, else: {:error, :invalid_output}

      [] ->
        {:ok, nil}

      _ ->
        {:error, :invalid_output}
    end
  end

  defp parse_git_remotes(output) do
    remotes = String.split(output, "\n", trim: true)

    if Enum.all?(remotes, &valid_remote?/1),
      do: {:ok, Enum.sort_by(remotes, &byte_size/1, :desc)},
      else: {:error, :invalid_output}
  end

  defp parse_git_rows(output, remotes) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, rows} ->
      case parse_git_row(line, remotes) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        :skip -> {:cont, {:ok, rows}}
        :error -> {:halt, {:error, :invalid_output}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp parse_git_row(line, remotes) do
    case String.split(line, <<0>>, parts: 5) do
      [ref, upstream, upstream_remote, head, object] ->
        parse_git_row_fields(ref, upstream, upstream_remote, head, object, remotes)

      _ ->
        :error
    end
  end

  defp parse_git_row_fields(ref, upstream, upstream_remote, head, object, remotes) do
    if valid_object?(object) and head in ["", " ", "*"] do
      parse_git_ref(ref, upstream, upstream_remote, head == "*", remotes)
    else
      :error
    end
  end

  defp parse_git_ref("refs/heads/" <> branch, upstream, upstream_remote, current, _remotes) do
    with true <- valid_target?(branch),
         {:ok, upstream} <- parse_git_upstream(upstream),
         {:ok, upstream_remote} <- parse_git_upstream_remote(upstream_remote),
         true <- is_nil(upstream_remote) or is_binary(upstream) do
      {:ok,
       %{
         kind: :local,
         name: branch,
         current: current,
         upstream: upstream,
         upstream_remote: upstream_remote,
         remote: nil,
         ref: "refs/heads/" <> branch
       }}
    else
      _ -> :error
    end
  end

  defp parse_git_ref("refs/remotes/" <> remote_ref, "", "", false, remotes) do
    case split_remote_ref(remote_ref, remotes) do
      [remote, branch] ->
        cond do
          valid_remote?(remote) and valid_target?(branch) ->
            {:ok,
             %{
               kind: :remote,
               name: branch,
               current: false,
               upstream: nil,
               remote: remote,
               ref: "refs/remotes/" <> remote_ref
             }}

          valid_remote?(remote) and branch == "HEAD" ->
            :skip

          true ->
            :error
        end

      _ ->
        :error
    end
  end

  defp parse_git_ref(_ref, _upstream, _upstream_remote, _current, _remotes), do: :error

  defp split_remote_ref(ref, remotes) do
    case Enum.find(remotes, &String.starts_with?(ref, &1 <> "/")) do
      nil -> String.split(ref, "/", parts: 2)
      remote -> [remote, String.replace_prefix(ref, remote <> "/", "")]
    end
  end

  defp parse_git_upstream_remote(""), do: {:ok, nil}
  # Git uses "." as the remote name for an upstream in the same repository.
  # It is tracking metadata, not a fetch remote.
  defp parse_git_upstream_remote("."), do: {:ok, nil}

  defp parse_git_upstream_remote(remote) do
    if valid_remote?(remote), do: {:ok, remote}, else: :error
  end

  defp parse_git_upstream(""), do: {:ok, nil}

  defp parse_git_upstream(upstream) do
    if valid_target?(upstream), do: {:ok, upstream}, else: :error
  end

  defp parse_jj_rows(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, rows} ->
      case parse_jj_row(String.split(line, <<0>>, parts: 5)) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        :error -> {:halt, {:error, :invalid_output}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp parse_jj_row([name, remote, presence, tracked, tracking_present])
       when presence in ["present", "absent"] and tracked in ["", "tracked"] and
              tracking_present in ["", "tracking"] do
    if valid_target?(name) and valid_remote_or_empty?(remote) do
      {:ok,
       %{
         kind: if(remote == "", do: :local, else: :remote),
         name: name,
         current: false,
         upstream: nil,
         remote: if(remote == "", do: nil, else: remote),
         ref: if(remote == "", do: name, else: name <> "@" <> remote),
         present?: presence == "present",
         tracked?: tracked == "tracked",
         tracking_present?: tracking_present == "tracking"
       }}
    else
      :error
    end
  end

  defp parse_jj_row(_fields), do: :error

  defp build_choices(rows, selected, manifest_default, remote_default) do
    local_rows = Enum.filter(rows, &(&1.kind == :local and Map.get(&1, :present?, true)))
    remote_rows = Enum.filter(rows, &(&1.kind == :remote and Map.get(&1, :present?, true)))
    local_by_name = Map.new(local_rows, &{&1.name, &1})
    remote_by_name = Enum.group_by(remote_rows, & &1.name)

    names =
      (Map.keys(local_by_name) ++ Map.keys(remote_by_name))
      |> Enum.uniq()
      |> Enum.sort()

    choices =
      Enum.map(names, fn name ->
        local = Map.get(local_by_name, name, %{})
        remotes = Map.get(remote_by_name, name, [])
        upstream = Map.get(local, :upstream)
        upstream_remote = Map.get(local, :upstream_remote)
        remote_names = remotes |> Enum.map(& &1.remote) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
        remote_refs = remotes |> Enum.map(& &1.ref) |> Enum.uniq() |> Enum.sort()
        remote = List.first(remote_names)
        remote_ref = List.first(remote_refs)

        tracked? =
          is_binary(upstream_remote) or
            Enum.any?(remotes, &Map.get(&1, :tracked?, false))

        %{
          value: name,
          label: name,
          status: "available",
          reason: nil,
          current: Map.get(local, :current, false),
          manifest_default: name == manifest_default,
          remote_default: name == remote_default,
          configured: name == selected,
          remote: remote,
          remote_ref: remote_ref,
          remote_names: remote_names,
          remote_refs: remote_refs,
          upstream: upstream,
          remote_tracking: tracked?
        }
      end)

    if is_binary(selected) and valid_target?(selected) and not Enum.any?(choices, &(&1.value == selected)) do
      choices ++ [stale_choice(selected, manifest_default, remote_default)]
    else
      choices
    end
    |> Enum.sort_by(& &1.value)
  end

  defp stale_choice(selected, manifest_default, remote_default) do
    %{
      value: selected,
      label: selected,
      status: "stale",
      reason: "configured_target_unavailable",
      current: false,
      manifest_default: selected == manifest_default,
      remote_default: selected == remote_default,
      configured: true,
      remote: nil,
      remote_ref: nil,
      remote_names: [],
      remote_refs: [],
      upstream: nil,
      remote_tracking: false
    }
  end

  defp finish_current(base, choices, selected) do
    stale? = Enum.any?(choices, &(&1.status == "stale" and &1.configured))
    invalid_selected? = is_binary(selected) and not valid_target?(selected)

    %{
      base
      | status: "current",
        reason: nil,
        choices: choices,
        apply_allowed: choices != [] and not stale? and not invalid_selected?
    }
  end

  defp unavailable(base, reason, typed_fallback?) do
    selected = Map.get(base, :selected)
    typed_target? = typed_fallback? and is_binary(selected) and valid_target?(selected)

    Map.merge(base, %{
      status: "unavailable",
      reason: reason_string(reason),
      choices: [],
      apply_allowed: typed_target?,
      typed_fallback: typed_fallback?
    })
  end

  defp reason_string(:timeout), do: "discovery_timeout"
  defp reason_string(:cancelled), do: "discovery_cancelled"
  defp reason_string(:invalid_output), do: "discovery_output_invalid"
  defp reason_string({:command_failed, _status}), do: "discovery_command_failed"
  defp reason_string(:failed), do: "discovery_command_failed"
  defp reason_string(:invalid_inspection), do: "invalid_inspection"

  defp run_command(runner, argv, repository, deadline_ms) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, :timeout}
    else
      argv
      |> invoke_command(runner, remaining_ms, repository)
      |> command_result(deadline_ms)
    end
  end

  defp invoke_command(argv, runner, remaining_ms, repository) do
    runner.(argv, remaining_ms, command_options(repository))
  rescue
    _error -> {:error, :failed}
  catch
    _kind, _reason -> {:error, :failed}
  end

  defp command_result({:ok, {output, status}}, deadline_ms)
       when is_binary(output) and is_integer(status) and status >= 0 do
    cond do
      byte_size(output) > @max_output_bytes -> {:error, :invalid_output}
      not String.valid?(output) -> {:error, :invalid_output}
      System.monotonic_time(:millisecond) >= deadline_ms -> {:error, :timeout}
      status == 0 -> {:ok, output}
      true -> {:error, {:command_failed, status}}
    end
  end

  defp command_result({:error, reason}, _deadline_ms) when reason in [:timeout, :process_timeout],
    do: {:error, :timeout}

  defp command_result(_result, _deadline_ms), do: {:error, :failed}

  defp command_options(repository) do
    [
      cd: repository,
      cleanup: :process_group,
      env: @git_env,
      stderr_to_stdout: true,
      line: @max_output_bytes
    ]
  end

  defp default_command_runner(argv, timeout_ms, opts),
    do: ProcessSupervisor.run(argv, timeout_ms, opts)

  defp command_runner(opts) do
    case Keyword.get(opts, :command_runner) do
      runner when is_function(runner, 3) -> runner
      _ -> &default_command_runner/3
    end
  end

  defp check_cancel(opts) do
    if cancelled?(opts), do: {:error, :cancelled}, else: :ok
  end

  defp cancelled?(opts) do
    case Keyword.get(opts, :cancelled?) do
      callback when is_function(callback, 0) ->
        try do
          callback.() == true
        rescue
          _error -> true
        catch
          _kind, _reason -> true
        end

      _ ->
        false
    end
  end

  defp configured_target(opts) do
    case Keyword.get(opts, :configured_target) do
      target when is_binary(target) -> target
      _ -> nil
    end
  end

  defp normalize_manifest_default(branch) do
    if is_binary(branch) and valid_target?(branch), do: branch, else: nil
  end

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, @default_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> min(timeout, @max_timeout_ms)
      _ -> @default_timeout_ms
    end
  end

  defp value(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp valid_object?(object) do
    String.match?(object, ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
  end

  defp valid_remote_or_empty?(remote), do: remote == "" or valid_remote?(remote)

  defp valid_remote?(remote), do: valid_ref_name?(remote)

  @spec valid_target?(term()) :: boolean()
  def valid_target?(branch) do
    is_binary(branch) and byte_size(branch) <= 1024 and branch not in ["@", "HEAD"] and valid_ref_name?(branch)
  end

  defp valid_ref_name?(name) when is_binary(name) do
    String.valid?(name) and not String.starts_with?(name, "-") and
      not String.contains?(name, ["..", "@{"]) and
      not String.match?(name, ~r/[\x00-\x20\x7f~^:?*\[\\]/) and
      Enum.all?(String.split(name, "/"), &valid_ref_component?/1)
  end

  defp valid_ref_component?(component) do
    component != "" and not String.starts_with?(component, ".") and
      not String.ends_with?(component, [".", ".lock"])
  end
end
