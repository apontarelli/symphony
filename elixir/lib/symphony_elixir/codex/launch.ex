defmodule SymphonyElixir.Codex.Launch do
  @moduledoc """
  Prepares the Codex harness home and starts the app-server process.
  """

  alias SymphonyElixir.Codex.{ExecutionProfile, HarnessHome}
  alias SymphonyElixir.{ExecutionContext, PathSafety, ProcessSupervisor, Shell, SSH, TargetContext}

  @type command :: [String.t()]
  @type result :: %{
          port: port(),
          process: ProcessSupervisor.t(),
          argv: [String.t()] | nil,
          codex_home: Path.t()
        }

  @type launch_provenance :: %{
          target_id: String.t(),
          registry_generation: String.t(),
          policy_hash: String.t(),
          runner_name: String.t(),
          runner_kind: String.t(),
          profile: String.t(),
          model: String.t() | nil
        }

  @type context_result :: %{
          port: term(),
          process: term(),
          argv: [String.t()] | nil,
          codex_home: Path.t(),
          provenance: launch_provenance()
        }

  @spec start(ExecutionContext.t(), keyword()) ::
          {:ok, context_result()} | {:error, atom()}
  def start(%ExecutionContext{} = context, opts) when is_list(opts) do
    safe_context_launch(fn ->
      with {:ok, transport} <- parse_context_launch_options(opts),
           {:ok, authority} <- context_launch_authority(context),
           :ok <- validate_local_launch_workspace_before_harness(authority),
           {:ok, harness} <- prepare_context_harness(context),
           {:ok, started} <-
             start_context_transport(authority, harness, transport) do
        {:ok,
         %{
           port: started.port,
           process: started.process,
           argv: started.argv,
           codex_home: harness.path,
           provenance: authority.provenance
         }}
      end
    end)
  end

  def start(%ExecutionContext{}, _opts), do: {:error, :invalid_launch_options}
  def start(_context, _opts), do: {:error, :invalid_launch_context}

  defp parse_context_launch_options(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        length(keys) != length(Enum.uniq(keys)) ->
          {:error, :duplicate_launch_option}

        Enum.any?(keys, &(&1 not in [:line, :process_starter, :ssh_starter])) ->
          {:error, :launch_option_forbidden}

        not valid_line_option?(Keyword.get(opts, :line)) ->
          {:error, :invalid_launch_options}

        not valid_transport_starter?(Keyword.get(opts, :process_starter), 2) ->
          {:error, :invalid_launch_options}

        not valid_transport_starter?(Keyword.get(opts, :ssh_starter), 3) ->
          {:error, :invalid_launch_options}

        true ->
          {:ok,
           %{
             line: Keyword.get(opts, :line),
             process_starter: Keyword.get(opts, :process_starter, &default_context_process_starter/2),
             ssh_starter: Keyword.get(opts, :ssh_starter, &default_context_ssh_starter/3)
           }}
      end
    else
      {:error, :invalid_launch_options}
    end
  end

  defp valid_line_option?(nil), do: true
  defp valid_line_option?(line), do: is_integer(line) and line > 0
  defp valid_transport_starter?(nil, _arity), do: true
  defp valid_transport_starter?(starter, arity), do: is_function(starter, arity)

  defp context_launch_authority(%ExecutionContext{
         target: %TargetContext{
           target_id: target_id,
           registry_generation: registry_generation,
           policy_hash: policy_hash,
           worktree_policy: worktree_policy,
           runner_policy: runner_policy
         },
         issue_identifier: issue_identifier,
         workspace_path: workspace_path,
         runner_name: runner_name,
         runner_config: runner_config,
         execution_profile: execution_profile,
         timeout_ms: timeout_ms,
         max_retries: max_retries,
         worker_host: worker_host
       }) do
    with true <- valid_launch_id?(target_id),
         true <- valid_launch_hash?(registry_generation),
         true <- valid_launch_hash?(policy_hash),
         true <- valid_launch_id?(runner_name),
         {:ok, workspace_authority} <-
           validate_context_workspace_authority(
             worktree_policy,
             target_id,
             issue_identifier,
             workspace_path
           ),
         true <- is_map(runner_policy) and not is_struct(runner_policy),
         allowed when is_list(allowed) <- Map.get(runner_policy, "allowed"),
         true <- runner_name in allowed,
         runners when is_map(runners) <- Map.get(runner_policy, "runners"),
         {:ok, pinned_runner} <- Map.fetch(runners, runner_name),
         true <- pinned_runner == runner_config,
         %{"kind" => "codex_app_server"} <- runner_config,
         {:ok, _base_argv} <- validate_context_argv(Map.get(runner_config, "command")),
         {:ok, expected_profile} <-
           ExecutionProfile.resolve_pinned(
             runner_config,
             Map.get(execution_profile, :name),
             timeout_ms,
             max_retries
           ),
         true <- expected_profile == execution_profile,
         argv <-
           ExecutionProfile.command(
             Map.get(runner_config, "command"),
             execution_profile,
             Map.get(runner_config, "model")
           ),
         {:ok, argv} <- validate_context_argv(argv),
         {:ok, profile, model} <- pinned_context_profile(execution_profile),
         true <- valid_worker_host?(worker_host) do
      {:ok,
       %{
         argv: argv,
         workspace: workspace_path,
         worker_host: worker_host,
         root: workspace_authority.root,
         target_root: workspace_authority.target_root,
         issue_identifier: issue_identifier,
         provenance: %{
           target_id: target_id,
           registry_generation: registry_generation,
           policy_hash: policy_hash,
           runner_name: runner_name,
           runner_kind: "codex_app_server",
           profile: profile,
           model: model
         }
       }}
    else
      %{"kind" => _other_kind} -> {:error, :unsupported_runner_kind}
      {:error, :invalid_argv} = error -> error
      _invalid -> {:error, :invalid_launch_context}
    end
  end

  defp context_launch_authority(_context), do: {:error, :invalid_launch_context}

  defp validate_context_workspace_authority(
         %{"root" => root, "strategy" => "per_issue", "hooks" => hooks} = worktree_policy,
         target_id,
         issue_identifier,
         workspace_path
       ) do
    expanded_root = if is_binary(root), do: Path.expand(root), else: nil

    target_root =
      if is_binary(expanded_root) and Path.basename(expanded_root) == target_id,
        do: expanded_root,
        else: context_workspace_join(expanded_root, target_id)

    expected_workspace = context_workspace_join(target_root, issue_identifier)

    if valid_context_workspace_authority?(
         worktree_policy,
         hooks,
         root,
         expanded_root,
         issue_identifier,
         workspace_path,
         expected_workspace
       ) do
      {:ok, %{root: expanded_root, target_root: target_root}}
    else
      {:error, :invalid_launch_context}
    end
  end

  defp validate_context_workspace_authority(
         _worktree_policy,
         _target_id,
         _issue_identifier,
         _workspace_path
       ),
       do: {:error, :invalid_launch_context}

  defp valid_context_workspace_authority?(
         worktree_policy,
         hooks,
         root,
         expanded_root,
         issue_identifier,
         workspace_path,
         expected_workspace
       ) do
    Enum.sort(Map.keys(worktree_policy)) == ~w(hooks root strategy) and
      valid_workspace_root?(root, expanded_root) and is_map(hooks) and not is_struct(hooks) and
      valid_issue_identifier?(issue_identifier) and workspace_path == expected_workspace
  end

  defp context_workspace_join(left, right) when is_binary(left) and is_binary(right),
    do: Path.join(left, right)

  defp context_workspace_join(_left, _right), do: nil

  defp valid_workspace_root?(root, expanded_root) do
    is_binary(root) and String.valid?(root) and root == expanded_root and root != "/" and
      Path.type(root) == :absolute and not Regex.match?(~r/\p{Cc}/u, root)
  end

  defp valid_issue_identifier?(value) do
    is_binary(value) and String.valid?(value) and String.trim(value) != "" and
      value not in [".", ".."] and not String.contains?(value, ["/", "\\"]) and
      not Regex.match?(~r/\p{Cc}/u, value)
  end

  defp validate_context_argv(argv) when is_list(argv) and argv != [] do
    if Enum.all?(argv, &valid_argv_value?/1),
      do: {:ok, argv},
      else: {:error, :invalid_argv}
  end

  defp validate_context_argv(_argv), do: {:error, :invalid_argv}

  defp valid_argv_value?(value) do
    is_binary(value) and String.valid?(value) and String.trim(value) != "" and
      not Regex.match?(~r/\p{Cc}/u, value)
  end

  defp pinned_context_profile(%{name: profile, model: model}) do
    if valid_launch_scalar?(profile) and (is_nil(model) or valid_launch_scalar?(model)),
      do: {:ok, profile, model},
      else: {:error, :invalid_launch_context}
  end

  defp valid_launch_id?(value) do
    is_binary(value) and String.valid?(value) and
      Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, value)
  end

  defp valid_launch_hash?(value) do
    is_binary(value) and String.valid?(value) and
      Regex.match?(~r/^sha256:[0-9a-f]{64}$/, value)
  end

  defp valid_launch_scalar?(value) do
    is_binary(value) and String.valid?(value) and String.trim(value) != "" and
      not Regex.match?(~r/\p{Cc}/u, value)
  end

  defp valid_worker_host?(nil), do: true
  defp valid_worker_host?(worker_host), do: match?({:ok, _target}, SSH.parse_target(worker_host))

  defp validate_local_launch_workspace_before_harness(%{worker_host: nil} = authority),
    do: validate_local_launch_workspace(authority)

  defp validate_local_launch_workspace_before_harness(%{worker_host: worker_host})
       when is_binary(worker_host),
       do: :ok

  defp prepare_context_harness(%ExecutionContext{worker_host: nil} = context),
    do: HarnessHome.ensure_local(context)

  defp prepare_context_harness(%ExecutionContext{} = context),
    do: HarnessHome.remote_prepare(context)

  defp start_context_transport(%{worker_host: nil} = authority, harness, transport) do
    opts = [
      cd: authority.workspace,
      env: HarnessHome.local_port_env(harness.path),
      line: transport.line
    ]

    with :ok <- validate_local_launch_workspace(authority),
         {:ok, started} <-
           invoke_context_starter(fn -> transport.process_starter.(authority.argv, opts) end) do
      {:ok, %{port: started.port, process: started.process, argv: authority.argv}}
    end
  end

  defp start_context_transport(authority, harness, transport) do
    command = context_remote_launch_command(authority, harness)
    opts = [line: transport.line]

    with {:ok, started} <-
           invoke_context_starter(fn -> transport.ssh_starter.(authority.worker_host, command, opts) end) do
      {:ok, %{port: started.port, process: started.process, argv: nil}}
    end
  end

  defp validate_local_launch_workspace(authority) do
    root_parent = Path.dirname(authority.root)

    with :ok <- reject_launch_symlink_components(authority.workspace),
         :ok <- validate_launch_directory(root_parent),
         :ok <- validate_launch_directory(authority.root),
         :ok <- validate_launch_directory(authority.target_root),
         :ok <- validate_launch_directory(authority.workspace),
         true <- strict_launch_descendant?(authority.root, root_parent),
         true <-
           authority.target_root == authority.root or
             strict_launch_descendant?(authority.target_root, authority.root),
         true <- strict_launch_descendant?(authority.workspace, authority.target_root) do
      :ok
    else
      _invalid -> {:error, :invalid_launch_context}
    end
  end

  defp reject_launch_symlink_components(path) do
    path
    |> Path.split()
    |> Enum.scan(fn segment, parent -> Path.join(parent, segment) end)
    |> Enum.reduce_while(:ok, fn component, :ok ->
      case File.lstat(component) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, :invalid_launch_context}}

        {:ok, %File.Stat{}} ->
          {:cont, :ok}

        {:error, _reason} ->
          {:halt, {:error, :invalid_launch_context}}
      end
    end)
  end

  defp validate_launch_directory(path) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         {:ok, ^path} <- PathSafety.canonicalize(path) do
      :ok
    else
      _invalid -> {:error, :invalid_launch_context}
    end
  end

  defp strict_launch_descendant?(candidate, root) do
    candidate_segments = Path.split(candidate)
    root_segments = Path.split(root)

    candidate != root and Enum.take(candidate_segments, length(root_segments)) == root_segments
  end

  defp invoke_context_starter(starter) do
    case starter.() do
      {:ok, %{port: port, process: process}} ->
        {:ok, %{port: port, process: process}}

      {:error, _reason} ->
        {:error, :launch_transport_failed}

      _unexpected ->
        {:error, :launch_transport_failed}
    end
  rescue
    _exception -> {:error, :launch_transport_failed}
  catch
    _kind, _reason -> {:error, :launch_transport_failed}
  end

  defp default_context_process_starter(argv, opts) do
    with {:ok, process} <- ProcessSupervisor.start(argv, opts) do
      {:ok, %{port: ProcessSupervisor.port(process), process: process}}
    end
  end

  defp default_context_ssh_starter(worker_host, command, opts) do
    with {:ok, port} <- SSH.start_port(worker_host, command, opts) do
      {:ok,
       %{
         port: port,
         process: ProcessSupervisor.from_port(port, cleanup: :port_only)
       }}
    end
  end

  defp context_remote_launch_command(authority, harness) do
    root_parent = Path.dirname(authority.root)
    root_name = Path.basename(authority.root)
    target_name = Path.basename(authority.target_root)

    [
      "set -eu",
      remote_launch_assign("root", authority.root),
      remote_launch_assign("root_parent", root_parent),
      remote_launch_assign("root_name", root_name),
      remote_launch_assign("expected_target", authority.target_root),
      remote_launch_assign("target_name", target_name),
      remote_launch_assign("expected_workspace", authority.workspace),
      remote_launch_assign("issue", authority.issue_identifier),
      remote_launch_canonical_validator(),
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
      "if [ \"$expected_target\" = \"$canonical_root\" ]; then",
      "  target_candidate=\"$canonical_root\"",
      "else",
      "  target_candidate=\"$canonical_root/$target_name\"",
      "fi",
      "[ \"$target_candidate\" = \"$expected_target\" ] || exit 70",
      "[ ! -L \"$target_candidate\" ] || exit 70",
      "[ -d \"$target_candidate\" ] || exit 70",
      "canonical_target=$(cd -- \"$target_candidate\" && pwd -P)",
      "validate_canonical \"$canonical_target\"",
      "[ \"$canonical_target\" = \"$target_candidate\" ] || exit 70",
      "workspace_candidate=\"$canonical_target/$issue\"",
      "[ \"$workspace_candidate\" = \"$expected_workspace\" ] || exit 70",
      "[ ! -L \"$workspace_candidate\" ] || exit 70",
      "[ -d \"$workspace_candidate\" ] || exit 70",
      "canonical_workspace=$(cd -- \"$workspace_candidate\" && pwd -P)",
      "validate_canonical \"$canonical_workspace\"",
      "[ \"$canonical_workspace\" = \"$workspace_candidate\" ] || exit 70",
      "case \"$canonical_workspace\" in \"$canonical_target\"/*) ;; *) exit 70 ;; esac",
      harness.command,
      "cd -- \"$canonical_workspace\"",
      "CODEX_HOME=#{Shell.escape(harness.path)} exec #{Shell.argv_to_command(authority.argv)}"
    ]
    |> Enum.join("\n")
  end

  defp remote_launch_assign(name, value), do: "#{name}=#{Shell.escape(value)}"

  defp remote_launch_canonical_validator do
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

  defp safe_context_launch(fun) do
    fun.()
  rescue
    _exception -> {:error, :invalid_launch_context}
  end

  @spec start(Path.t(), String.t() | nil, command(), keyword()) :: {:ok, result()} | {:error, term()}
  def start(workspace, worker_host, codex_command, opts \\ [])
      when is_binary(workspace) and is_list(codex_command) do
    line_bytes = Keyword.get(opts, :line)

    with {:ok, codex_home} <- prepare_harness_home(workspace, worker_host),
         {:ok, process, argv} <- start_port(workspace, worker_host, codex_home, codex_command, line_bytes) do
      {:ok, %{port: ProcessSupervisor.port(process), process: process, argv: argv, codex_home: codex_home}}
    end
  end

  defp prepare_harness_home(workspace, nil) do
    HarnessHome.ensure_local(workspace)
  end

  defp prepare_harness_home(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    {:ok, HarnessHome.path(workspace, remote: true)}
  end

  defp start_port(workspace, nil, codex_home, codex_command, line_bytes)
       when is_list(codex_command) do
    with {:ok, argv} <- command_argv(codex_command),
         {:ok, executable, args} <- local_command(workspace, argv),
         {:ok, process} <-
           ProcessSupervisor.start([executable | args],
             cd: workspace,
             env: HarnessHome.local_port_env(codex_home),
             line: line_bytes
           ) do
      {:ok, process, argv}
    end
  end

  defp start_port(workspace, worker_host, codex_home, codex_command, line_bytes)
       when is_binary(worker_host) do
    with {:ok, codex_command_string} <- command_string(codex_command),
         remote_command = remote_launch_command(workspace, codex_home, codex_command_string),
         {:ok, port} <- SSH.start_port(worker_host, remote_command, line: line_bytes) do
      {:ok, ProcessSupervisor.from_port(port, cleanup: :port_only), nil}
    end
  end

  defp local_command(_workspace, ["" | _args]), do: {:error, :empty_runner_command}

  defp local_command(workspace, [command | args]) when is_binary(command) and command != "" do
    case resolve_local_executable(workspace, command) do
      nil -> {:error, {:executable_not_found, command}}
      executable -> {:ok, executable, args}
    end
  end

  defp resolve_local_executable(workspace, command) do
    if Path.type(command) == :absolute or String.contains?(command, "/") do
      command
      |> Path.expand(workspace)
      |> executable_file()
    else
      System.find_executable(command)
    end
  end

  defp executable_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) != 0, do: path

      _stat ->
        nil
    end
  end

  defp remote_launch_command(workspace, codex_home, codex_command) when is_binary(codex_command) do
    [
      HarnessHome.remote_prepare_command(codex_home),
      "cd #{Shell.escape(workspace)}",
      "CODEX_HOME=#{Shell.escape(codex_home)} exec #{codex_command}"
    ]
    |> Enum.join(" && ")
  end

  defp command_argv(argv) when is_list(argv) do
    if Enum.all?(argv, &is_binary/1) and argv != [] do
      {:ok, argv}
    else
      {:error, :invalid_argv}
    end
  end

  defp command_string(argv) when is_list(argv) do
    with {:ok, argv} <- command_argv(argv) do
      {:ok, Shell.argv_to_command(argv)}
    end
  end
end
