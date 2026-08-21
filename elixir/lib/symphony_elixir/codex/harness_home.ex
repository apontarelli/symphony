defmodule SymphonyElixir.Codex.HarnessHome do
  @moduledoc """
  Builds the Symphony-owned Codex home used by unattended app-server sessions.
  """

  alias SymphonyElixir.{ExecutionContext, PathSafety, Shell, TargetContext, Workflow}

  @override_env "SYMPHONY_CODEX_HOME"

  @agents_md """
  # Symphony Harness

  Scope: global defaults for Symphony-managed unattended Codex sessions.

  - Treat this `CODEX_HOME` as Symphony-owned harness runtime state.
  - Use the session cwd as the target repository; repo-local `AGENTS.md` and docs layer after this file.
  - Do not rely on the operator's interactive `~/.codex/AGENTS.md`, prompts, hooks, or skills.
  - Do not copy Symphony skills into `~/.agents` or `~/.codex`; use the skills and tools available in the session.
  - Keep automation behavior deterministic and report only true blockers that require missing auth, secrets, or permissions.
  """

  @spec agents_md() :: String.t()
  def agents_md, do: @agents_md

  @type provenance :: %{
          target_id: String.t(),
          registry_generation: String.t(),
          policy_hash: String.t()
        }

  @type context_path_result :: %{path: Path.t(), provenance: provenance()}

  @spec path(ExecutionContext.t()) :: {:ok, context_path_result()} | {:error, atom()}
  def path(%ExecutionContext{} = context) do
    safe_context_result(:invalid_harness_home_context, fn -> context_path(context) end)
  end

  @spec path(Path.t()) :: Path.t()
  def path(workspace) when is_binary(workspace), do: path(workspace, [])

  @spec path(Path.t(), keyword()) :: Path.t()
  def path(workspace, opts) when is_binary(workspace) do
    remote? = Keyword.get(opts, :remote, false)

    case System.get_env(@override_env) do
      override when is_binary(override) and override != "" ->
        maybe_expand(override, remote?)

      _ ->
        configured_path(remote?) || managed_path(workspace, remote?)
    end
  end

  defp context_path(%ExecutionContext{
         target: %TargetContext{
           target_id: target_id,
           registry_generation: registry_generation,
           policy_hash: policy_hash,
           repo_policy: repo_policy,
           worktree_policy: worktree_policy
         },
         issue_identifier: issue_identifier,
         workspace_path: workspace_path
       }) do
    with true <- valid_context_id?(target_id),
         true <- valid_context_hash?(registry_generation),
         true <- valid_context_hash?(policy_hash),
         :ok <-
           validate_context_workspace(
             worktree_policy,
             target_id,
             issue_identifier,
             workspace_path
           ),
         {:ok, manifest, source_dir} <- context_repo_policy(repo_policy),
         {:ok, codex_home} <-
           context_codex_home(manifest, source_dir, workspace_path),
         true <- safe_context_path?(codex_home) do
      {:ok,
       %{
         path: codex_home,
         provenance: %{
           target_id: target_id,
           registry_generation: registry_generation,
           policy_hash: policy_hash
         }
       }}
    else
      _invalid -> {:error, :invalid_harness_home_context}
    end
  end

  defp context_path(_context), do: {:error, :invalid_harness_home_context}

  defp validate_context_workspace(
         %{"root" => root, "strategy" => "per_issue", "hooks" => hooks} = worktree_policy,
         target_id,
         issue_identifier,
         workspace_path
       ) do
    expanded_root = if is_binary(root), do: Path.expand(root), else: nil

    expected_workspace =
      if is_binary(expanded_root) and Path.basename(expanded_root) == target_id,
        do: Path.join(expanded_root, issue_identifier),
        else: context_workspace_join(expanded_root, target_id, issue_identifier)

    if Enum.sort(Map.keys(worktree_policy)) == ~w(hooks root strategy) and
         safe_context_path?(expanded_root) and valid_issue_segment?(issue_identifier) and
         is_map(hooks) and workspace_path == expected_workspace,
       do: :ok,
       else: {:error, :invalid_harness_home_context}
  end

  defp validate_context_workspace(
         _worktree_policy,
         _target_id,
         _issue_identifier,
         _workspace_path
       ),
       do: {:error, :invalid_harness_home_context}

  defp context_workspace_join(root, target_id, issue_identifier)
       when is_binary(root) and is_binary(target_id) and is_binary(issue_identifier),
       do: Path.join([root, target_id, issue_identifier])

  defp context_workspace_join(_root, _target_id, _issue_identifier), do: nil

  defp context_repo_policy(
         %{
           "manifest" => manifest,
           "manifest_source_dir" => source_dir,
           "workflow_module_resolution" => resolution
         } = repo_policy
       ) do
    expected_keys = ~w(manifest manifest_source_dir workflow_module_resolution)

    if Enum.sort(Map.keys(repo_policy)) == expected_keys and
         is_map(manifest) and not is_struct(manifest) and is_map(resolution) and
         safe_context_path?(source_dir),
       do: {:ok, manifest, source_dir},
       else: {:error, :invalid_harness_home_context}
  end

  defp context_repo_policy(_repo_policy), do: {:error, :invalid_harness_home_context}

  defp context_codex_home(manifest, source_dir, workspace_path) do
    case get_in(manifest, ["harness", "codex_home"]) do
      nil ->
        {:ok, Path.join([Path.dirname(workspace_path), ".symphony", "codex_home"])}

      configured when is_binary(configured) ->
        configured_context_codex_home(configured, source_dir)

      _invalid ->
        {:error, :invalid_harness_home_context}
    end
  end

  defp configured_context_codex_home(configured, source_dir) do
    cond do
      not String.valid?(configured) or String.trim(configured) == "" ->
        {:error, :invalid_harness_home_context}

      Regex.match?(~r/\p{Cc}/u, configured) or String.starts_with?(configured, "~") ->
        {:error, :invalid_harness_home_context}

      unsafe_path_segments?(configured) ->
        {:error, :invalid_harness_home_context}

      Path.type(configured) == :absolute ->
        {:ok, configured}

      true ->
        {:ok, Path.expand(configured, source_dir)}
    end
  end

  defp unsafe_path_segments?(path) do
    Enum.any?(Path.split(path), &(&1 in [".", ".."]))
  end

  defp safe_context_path?(path) do
    is_binary(path) and String.valid?(path) and String.trim(path) != "" and
      Path.type(path) == :absolute and Path.expand(path) == path and path != "/" and
      not Regex.match?(~r/\p{Cc}/u, path)
  end

  defp valid_context_id?(value) do
    is_binary(value) and String.valid?(value) and
      Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, value)
  end

  defp valid_context_hash?(value) do
    is_binary(value) and String.valid?(value) and
      Regex.match?(~r/^sha256:[0-9a-f]{64}$/, value)
  end

  defp valid_issue_segment?(value) do
    is_binary(value) and String.valid?(value) and String.trim(value) != "" and
      value not in [".", ".."] and not String.contains?(value, ["/", "\\"]) and
      not Regex.match?(~r/\p{Cc}/u, value)
  end

  @spec ensure_local(ExecutionContext.t()) ::
          {:ok, context_path_result()} | {:error, atom()}
  def ensure_local(%ExecutionContext{worker_host: nil} = context) do
    with {:ok, result} <- path(context) do
      ensure_context_local_home(result)
    end
  end

  def ensure_local(%ExecutionContext{}), do: {:error, :harness_home_requires_local_context}
  @spec ensure_local(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def ensure_local(workspace) when is_binary(workspace) do
    codex_home = path(workspace)
    agents_path = Path.join(codex_home, "AGENTS.md")

    with :ok <- File.mkdir_p(codex_home),
         :ok <- File.write(agents_path, agents_md()),
         :ok <- ensure_local_auth_link(codex_home) do
      {:ok, codex_home}
    else
      {:error, reason} -> {:error, {:codex_harness_home_failed, codex_home, reason}}
    end
  end

  defp ensure_context_local_home(result) do
    safe_context_result(:harness_home_prepare_failed, fn ->
      agents_path = Path.join(result.path, "AGENTS.md")

      with :ok <- validate_context_home_components(result.path, :allow_missing),
           :ok <- File.mkdir_p(result.path),
           :ok <- validate_context_home_components(result.path, :require_directories),
           :ok <- validate_context_agents_path(agents_path),
           :ok <- write_context_agents_atomically(result.path, agents_path, result.provenance) do
        {:ok, result}
      else
        {:error, :invalid_harness_home_path} = error -> error
        {:error, _reason} -> {:error, :harness_home_prepare_failed}
      end
    end)
  end

  defp validate_context_home_components(path, mode) do
    path
    |> context_path_components()
    |> Enum.reduce_while(:ok, fn component, :ok ->
      case validate_context_home_component(component, mode) do
        :ok -> {:cont, :ok}
        {:error, :invalid_harness_home_path} = error -> {:halt, error}
      end
    end)
  end

  defp validate_context_home_component(component, mode) do
    with :ok <- validate_canonical_context_home_component(component) do
      case File.lstat(component) do
        {:ok, %File.Stat{type: :directory}} ->
          :ok

        {:error, :enoent} when mode == :allow_missing ->
          :ok

        _invalid ->
          {:error, :invalid_harness_home_path}
      end
    end
  end

  defp validate_canonical_context_home_component(component) do
    case PathSafety.canonicalize(component) do
      {:ok, ^component} -> :ok
      _invalid -> {:error, :invalid_harness_home_path}
    end
  end

  defp context_path_components(path) do
    path
    |> Path.split()
    |> Enum.scan(fn segment, parent -> Path.join(parent, segment) end)
  end

  defp validate_context_agents_path(path) do
    validate_context_agents_stat(File.lstat(path), [:regular])
  end

  defp write_context_agents_atomically(home, agents_path, provenance) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    temp_path = Path.join(home, ".AGENTS.md.symphony-#{nonce}.tmp")

    result =
      with {:ok, file} <- File.open(temp_path, [:write, :exclusive]) do
        write_result =
          try do
            with :ok <- File.chmod(temp_path, 0o600) do
              IO.binwrite(file, context_agents_md(provenance))
            end
          after
            File.close(file)
          end

        with :ok <- write_result,
             :ok <- validate_context_home_components(home, :require_directories),
             :ok <- validate_context_agents_rename_destination(agents_path) do
          File.rename(temp_path, agents_path)
        end
      end

    _cleanup_result = File.rm(temp_path)
    result
  end

  defp validate_context_agents_rename_destination(path) do
    validate_context_agents_stat(File.lstat(path), [:regular, :symlink])
  end

  defp validate_context_agents_stat({:ok, %File.Stat{type: type}}, allowed_types) do
    if type in allowed_types, do: :ok, else: {:error, :invalid_harness_home_path}
  end

  defp validate_context_agents_stat({:error, :enoent}, _allowed_types), do: :ok

  defp validate_context_agents_stat(_invalid, _allowed_types),
    do: {:error, :invalid_harness_home_path}

  defp context_agents_md(provenance) do
    @agents_md <>
      """

      Context provenance:
      - target_id: #{provenance.target_id}
      - registry_generation: #{provenance.registry_generation}
      - policy_hash: #{provenance.policy_hash}
      """
  end

  defp safe_context_result(error, fun) when is_atom(error) and is_function(fun, 0) do
    fun.()
  rescue
    _exception -> {:error, error}
  catch
    _kind, _reason -> {:error, error}
  end

  @spec local_port_env(Path.t()) :: [{charlist(), charlist()}]
  def local_port_env(codex_home) when is_binary(codex_home) do
    [{~c"CODEX_HOME", String.to_charlist(codex_home)}]
  end

  @type remote_prepare_result :: %{
          path: Path.t(),
          command: String.t(),
          provenance: provenance()
        }

  @spec remote_prepare(ExecutionContext.t()) ::
          {:ok, remote_prepare_result()} | {:error, atom()}
  def remote_prepare(%ExecutionContext{worker_host: worker_host} = context)
      when is_binary(worker_host) do
    with {:ok, result} <- path(context) do
      {:ok,
       %{
         path: result.path,
         command: context_remote_prepare_command(result.path, result.provenance),
         provenance: result.provenance
       }}
    end
  end

  def remote_prepare(%ExecutionContext{}),
    do: {:error, :harness_home_requires_remote_context}

  def remote_prepare(_context), do: {:error, :invalid_harness_home_context}

  defp context_remote_prepare_command(codex_home, provenance) do
    [root | home_segments] = Path.split(codex_home)
    agents_path = Path.join(codex_home, "AGENTS.md")
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    temp_path = Path.join(codex_home, ".AGENTS.md.symphony-#{nonce}.tmp")
    agents_md = context_agents_md(provenance)

    ([
       "set -eu",
       remote_context_assign("home", codex_home),
       remote_context_assign("agents_path", agents_path),
       remote_context_assign("temp_path", temp_path),
       remote_context_assign("canonical_parent", root),
       remote_context_canonical_validator(),
       "[ ! -L \"$canonical_parent\" ] || exit 70",
       "[ -d \"$canonical_parent\" ] || exit 70"
     ] ++
       remote_home_component_lines(home_segments) ++
       [
         "canonical_home=\"$canonical_parent\"",
         "validate_canonical \"$canonical_home\"",
         "[ \"$canonical_home\" = \"$home\" ] || exit 70",
         "[ ! -e \"$temp_path\" ] || exit 70",
         "[ ! -L \"$temp_path\" ] || exit 70",
         "trap 'rm -f -- \"$temp_path\"' EXIT",
         "(umask 077; set -C; : > \"$temp_path\")",
         "chmod 600 \"$temp_path\"",
         "[ ! -L \"$temp_path\" ] || exit 70",
         "[ -f \"$temp_path\" ] || exit 70",
         "printf %b #{Shell.escape(shell_printf_escape(agents_md))} > \"$temp_path\"",
         "[ ! -L \"$canonical_home\" ] || exit 70",
         "rechecked_home=$(cd -- \"$canonical_home\" && pwd -P)",
         "validate_canonical \"$rechecked_home\"",
         "[ \"$rechecked_home\" = \"$home\" ] || exit 70",
         "[ ! -L \"$temp_path\" ] || exit 70",
         "[ -f \"$temp_path\" ] || exit 70",
         "if [ -e \"$agents_path\" ] && [ ! -f \"$agents_path\" ]; then exit 70; fi",
         "mv -- \"$temp_path\" \"$agents_path\"",
         "[ ! -L \"$agents_path\" ] || exit 70",
         "[ -f \"$agents_path\" ] || exit 70",
         "trap - EXIT"
       ])
    |> Enum.join("\n")
  end

  defp remote_home_component_lines(segments) do
    Enum.flat_map(segments, fn segment ->
      [
        remote_context_assign("segment", segment),
        "if [ \"$canonical_parent\" = / ]; then next_path=\"/$segment\"; else next_path=\"$canonical_parent/$segment\"; fi",
        "[ ! -L \"$next_path\" ] || exit 70",
        "if [ ! -d \"$next_path\" ]; then",
        "  [ ! -e \"$next_path\" ] || exit 70",
        "  mkdir -- \"$next_path\"",
        "fi",
        "[ ! -L \"$next_path\" ] || exit 70",
        "[ -d \"$next_path\" ] || exit 70",
        "next_canonical=$(cd -- \"$next_path\" && pwd -P)",
        "validate_canonical \"$next_canonical\"",
        "[ \"$next_canonical\" = \"$next_path\" ] || exit 70",
        "canonical_parent=\"$next_canonical\""
      ]
    end)
  end

  defp remote_context_assign(name, value), do: "#{name}=#{Shell.escape(value)}"

  defp remote_context_canonical_validator do
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

  @spec remote_prepare_command(Path.t()) :: String.t()
  def remote_prepare_command(codex_home) when is_binary(codex_home) do
    agents_path = Path.join(codex_home, "AGENTS.md")
    auth_path = Path.join(codex_home, "auth.json")

    [
      "mkdir -p #{Shell.escape(codex_home)}",
      "printf %b #{Shell.escape(shell_printf_escape(agents_md()))} > #{Shell.escape(agents_path)}",
      "if [ ! -e #{Shell.escape(auth_path)} ] && [ ! -L #{Shell.escape(auth_path)} ] && [ -f \"$HOME/.codex/auth.json\" ]; then ln -s \"$HOME/.codex/auth.json\" #{Shell.escape(auth_path)}; fi"
    ]
    |> Enum.join(" && ")
  end

  defp configured_path(remote?) do
    with {:ok, %{config: config}} <- Workflow.current(),
         path when is_binary(path) <- get_in(config, ["manifest", "harness", "codex_home"]),
         trimmed when trimmed != "" <- String.trim(path) do
      maybe_expand_configured_path(trimmed, remote?)
    else
      _ -> nil
    end
  end

  defp maybe_expand_configured_path(path, true), do: path

  defp maybe_expand_configured_path(path, false) do
    path
    |> Path.expand(Path.dirname(Workflow.selected_workflow_file_path()))
  end

  defp managed_path(workspace, remote?) do
    workspace
    |> Path.dirname()
    |> Path.join(Path.join([".symphony", "codex_home"]))
    |> maybe_expand(remote?)
  end

  defp maybe_expand(path, true), do: path
  defp maybe_expand(path, false), do: Path.expand(path)

  defp ensure_local_auth_link(codex_home) do
    source = Path.expand("~/.codex/auth.json")
    destination = Path.join(codex_home, "auth.json")

    cond do
      path_exists_or_symlink?(destination) ->
        :ok

      File.exists?(source) ->
        File.ln_s(source, destination)

      true ->
        :ok
    end
  end

  defp path_exists_or_symlink?(path) do
    File.exists?(path) or match?({:ok, _stat}, File.lstat(path))
  end

  defp shell_printf_escape(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
  end
end
