defmodule SymphonyElixir.ExecutionContext do
  @moduledoc false

  alias SymphonyElixir.Codex.ExecutionProfile
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.SSH
  alias SymphonyElixir.TargetContext

  @id_regex ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
  @profile_regex ~r/^[a-z0-9](?:[a-z0-9_]*[a-z0-9])?$/
  @hash_regex ~r/^sha256:[0-9a-f]{64}$/
  @review_roles [
    :source_reviewer,
    :test_reviewer,
    :runtime_qa,
    :product_visual_review,
    :docs_reviewer,
    :security_reviewer
  ]

  @enforce_keys [
    :target,
    :issue_id,
    :issue_identifier,
    :workspace_path,
    :runner_name,
    :runner_config,
    :policy,
    :role,
    :execution_profile,
    :timeout_ms,
    :max_retries,
    :worker_host
  ]
  defstruct @enforce_keys

  @type implementation_role :: :implementation

  @type review_role ::
          :source_reviewer
          | :test_reviewer
          | :runtime_qa
          | :product_visual_review
          | :docs_reviewer
          | :security_reviewer

  @type role :: implementation_role() | review_role()

  @type constructor_options ::
          [{:policy, map()}]
          | [{:policy, map()}, {:worker_host, String.t() | nil}]
          | [{:worker_host, String.t() | nil}, {:policy, map()}]

  @type child_options ::
          []
          | [{:runner, String.t()}]
          | [{:profile, String.t()}]
          | [{:runner, String.t()}, {:profile, String.t()}]
          | [{:profile, String.t()}, {:runner, String.t()}]

  @type error ::
          :duplicate_option
          | :invalid_context
          | :invalid_issue
          | :invalid_options
          | :invalid_policy
          | :invalid_profile
          | :invalid_role
          | :invalid_runner
          | :invalid_runner_config
          | :invalid_runner_policy
          | :invalid_target
          | :invalid_worker_host
          | :invalid_workspace_path
          | :invalid_worktree_policy
          | :missing_policy
          | :profile_not_allowed
          | :runner_not_allowed
          | :runner_not_found
          | :unknown_option

  @type t :: %__MODULE__{
          target: TargetContext.t(),
          issue_id: String.t(),
          issue_identifier: String.t(),
          workspace_path: Path.t(),
          runner_name: String.t(),
          runner_config: map(),
          policy: map(),
          role: role(),
          execution_profile: ExecutionProfile.t(),
          timeout_ms: pos_integer(),
          max_retries: non_neg_integer(),
          worker_host: String.t() | nil
        }

  @spec new(TargetContext.t(), Issue.t(), constructor_options()) ::
          {:ok, t()} | {:error, error()}
  def new(%TargetContext{} = target, %Issue{} = issue, opts) do
    with {:ok, parsed_opts} <- parse_new_options(opts),
         :ok <- validate_target_identity(target),
         :ok <- validate_issue(issue),
         :ok <- validate_policy(parsed_opts.policy),
         :ok <- validate_worker_host(parsed_opts.worker_host),
         :ok <- validate_worktree_policy(target.worktree_policy),
         :ok <- validate_runner_policy(target.runner_policy),
         :ok <- validate_target_data(target) do
      build(target, issue, parsed_opts)
    end
  end

  def new(%TargetContext{}, _issue, _opts), do: {:error, :invalid_issue}
  def new(_target, _issue, _opts), do: {:error, :invalid_target}

  defp build(target, issue, opts) do
    policy = opts.policy
    runner_name = target.runner_policy["default"]
    runner_config = target.runner_policy["runners"][runner_name]

    with {:ok, profile_name} <- select_child_profile(runner_config, :implementation, nil),
         {:ok, profile} <- resolve_profile(runner_config, profile_name),
         {:ok, workspace_path} <- workspace_path(target, issue.identifier, opts.worker_host) do
      {:ok,
       %__MODULE__{
         target: own_target(target),
         issue_id: own_binary(issue.id),
         issue_identifier: own_binary(issue.identifier),
         workspace_path: own_binary(workspace_path),
         runner_name: own_binary(runner_name),
         runner_config: own_json(runner_config),
         policy: own_json(policy),
         role: :implementation,
         execution_profile: own_term(profile),
         timeout_ms: profile.timeout_ms,
         max_retries: profile.max_retries,
         worker_host: own_binary(opts.worker_host)
       }}
    end
  end

  @spec derive_child(t(), review_role(), child_options()) :: {:ok, t()} | {:error, error()}
  def derive_child(%__MODULE__{} = parent, role, opts) do
    with :ok <- validate_context(parent),
         :ok <- validate_review_role(role),
         {:ok, parsed_opts} <- parse_child_options(opts),
         {:ok, runner_name, runner} <- select_child_runner(parent, parsed_opts.runner),
         {:ok, profile_name} <- select_child_profile(runner, role, parsed_opts.profile),
         {:ok, profile} <- resolve_profile(runner, profile_name) do
      {:ok,
       %{
         parent
         | role: role,
           runner_name: own_binary(runner_name),
           runner_config: own_json(runner),
           execution_profile: own_term(profile),
           timeout_ms: profile.timeout_ms,
           max_retries: profile.max_retries
       }}
    end
  end

  def derive_child(_parent, _role, _opts), do: {:error, :invalid_context}

  @spec validate(t()) :: :ok | {:error, :invalid_context}
  def validate(%__MODULE__{} = context), do: validate_context(context)
  def validate(_context), do: {:error, :invalid_context}

  @spec safe_provenance(t()) :: {:ok, map()} | {:error, :invalid_context}
  def safe_provenance(%__MODULE__{} = context) do
    with :ok <- validate_context(context) do
      {:ok,
       %{
         target_id: context.target.target_id,
         registry_generation: context.target.registry_generation,
         policy_hash: context.target.policy_hash,
         issue_id: context.issue_id,
         issue_identifier: context.issue_identifier,
         role: Atom.to_string(context.role)
       }}
    end
  end

  def safe_provenance(_context), do: {:error, :invalid_context}

  defp validate_review_role(role) when role in @review_roles, do: :ok
  defp validate_review_role(_role), do: {:error, :invalid_role}

  defp validate_context(%__MODULE__{target: %TargetContext{} = target} = context) do
    with :ok <- validate_target_identity(target),
         :ok <- validate_target_data(target),
         :ok <- validate_worktree_policy(target.worktree_policy),
         :ok <- validate_runner_policy(target.runner_policy),
         :ok <- validate_context_issue(context),
         :ok <- validate_policy(context.policy),
         :ok <- validate_worker_host(context.worker_host),
         true <- context.role == :implementation or context.role in @review_roles,
         {:ok, expected_workspace_path} <-
           workspace_path(target, context.issue_identifier, context.worker_host),
         true <- context.workspace_path == expected_workspace_path,
         true <- current_execution_consistent?(context, target) do
      :ok
    else
      _invalid -> {:error, :invalid_context}
    end
  end

  defp validate_context(_context), do: {:error, :invalid_context}

  defp validate_context_issue(context) do
    if safe_identity?(context.issue_id) and safe_issue_segment?(context.issue_identifier),
      do: :ok,
      else: {:error, :invalid_context}
  end

  defp current_execution_consistent?(context, target) do
    with true <- valid_id?(context.runner_name),
         true <- context.runner_name in target.runner_policy["allowed"],
         {:ok, runner} <- Map.fetch(target.runner_policy["runners"], context.runner_name),
         true <- context.runner_config == runner,
         true <- is_map(context.execution_profile) and not is_struct(context.execution_profile),
         profile_name when is_binary(profile_name) <- Map.get(context.execution_profile, :name),
         {:ok, ^profile_name} <- select_child_profile(runner, context.role, profile_name),
         {:ok, expected_profile} <- resolve_profile(runner, profile_name) do
      context.execution_profile == expected_profile and
        context.timeout_ms == expected_profile.timeout_ms and
        context.max_retries == expected_profile.max_retries
    else
      _invalid -> false
    end
  end

  defp parse_child_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        Enum.any?(keys, &(&1 not in [:runner, :profile])) ->
          {:error, :unknown_option}

        length(keys) != length(Enum.uniq(keys)) ->
          {:error, :duplicate_option}

        true ->
          {:ok, %{runner: Keyword.get(opts, :runner), profile: Keyword.get(opts, :profile)}}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp parse_child_options(_opts), do: {:error, :invalid_options}

  defp select_child_runner(parent, requested_runner) do
    runner_name = requested_runner || parent.runner_name

    if not is_nil(requested_runner) and not valid_id?(requested_runner) do
      {:error, :invalid_runner}
    else
      if runner_name in parent.target.runner_policy["allowed"] do
        runner = parent.target.runner_policy["runners"][runner_name]
        {:ok, runner_name, runner}
      else
        {:error, :runner_not_allowed}
      end
    end
  end

  defp select_child_profile(_runner, role, nil), do: {:ok, Atom.to_string(role)}

  defp select_child_profile(_runner, role, profile_name) when is_binary(profile_name) do
    cond do
      not String.valid?(profile_name) or not Regex.match?(@profile_regex, profile_name) ->
        {:error, :invalid_profile}

      profile_name != Atom.to_string(role) ->
        {:error, :profile_not_allowed}

      true ->
        {:ok, profile_name}
    end
  end

  defp select_child_profile(_runner, _role, _profile_name), do: {:error, :invalid_profile}

  defp parse_new_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        Enum.any?(keys, &(&1 not in [:policy, :worker_host])) ->
          {:error, :unknown_option}

        length(keys) != length(Enum.uniq(keys)) ->
          {:error, :duplicate_option}

        not Keyword.has_key?(opts, :policy) ->
          {:error, :missing_policy}

        true ->
          {:ok, %{policy: Keyword.fetch!(opts, :policy), worker_host: Keyword.get(opts, :worker_host)}}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp parse_new_options(_opts), do: {:error, :invalid_options}

  defp validate_target_data(%TargetContext{} = target) do
    maps = [
      target.repo_policy,
      target.tracker_connection,
      target.run_target,
      target.worktree_policy,
      target.runner_policy,
      target.effective_checks,
      target.external_side_effect_gates,
      target.capacity_limits,
      target.budget_limits
    ]

    valid_dispatch_mode? =
      case target.state do
        :active -> target.dispatch_mode in [:explicit, :watch]
        state when state in [:paused, :draining, :retired] -> target.dispatch_mode in [:explicit, :watch, nil]
        _invalid -> false
      end

    if valid_dispatch_mode? and Enum.all?(maps, &(is_map(&1) and json_safe?(&1))) and
         valid_repo_policy?(target.repo_policy),
       do: :ok,
       else: {:error, :invalid_target}
  end

  defp validate_target_identity(target) do
    if valid_id?(target.target_id) and valid_hash?(target.registry_generation) and
         valid_hash?(target.policy_hash) and valid_hash?(target.repo_manifest_hash) do
      :ok
    else
      {:error, :invalid_target}
    end
  end

  defp valid_id?(value),
    do: is_binary(value) and String.valid?(value) and Regex.match?(@id_regex, value)

  defp valid_hash?(value),
    do: is_binary(value) and String.valid?(value) and Regex.match?(@hash_regex, value)

  defp validate_issue(%Issue{id: id, identifier: identifier}) do
    if safe_identity?(id) and safe_issue_segment?(identifier),
      do: :ok,
      else: {:error, :invalid_issue}
  end

  defp safe_issue_segment?(value) do
    safe_identity?(value) and value not in [".", ".."] and
      not String.contains?(value, ["/", "\\"])
  end

  defp safe_identity?(value) do
    is_binary(value) and String.valid?(value) and String.trim(value) != "" and
      not Regex.match?(~r/\p{Cc}/u, value)
  end

  defp validate_policy(policy) when is_map(policy) do
    if map_size(policy) > 0 and json_safe?(policy), do: :ok, else: {:error, :invalid_policy}
  end

  defp validate_policy(_policy), do: {:error, :invalid_policy}

  defp validate_worker_host(nil), do: :ok

  defp validate_worker_host(worker_host) when is_binary(worker_host) do
    case SSH.parse_target(worker_host) do
      {:ok, _target} -> :ok
      {:error, :invalid_target} -> {:error, :invalid_worker_host}
    end
  end

  defp validate_worker_host(_worker_host), do: {:error, :invalid_worker_host}

  defp validate_worktree_policy(
         %{
           "root" => root,
           "strategy" => "per_issue",
           "hooks" => hooks
         } = worktree_policy
       ) do
    if Enum.sort(Map.keys(worktree_policy)) == ~w(hooks root strategy) and
         valid_workspace_root?(root) and valid_hooks?(hooks),
       do: :ok,
       else: {:error, :invalid_worktree_policy}
  end

  defp validate_worktree_policy(_worktree_policy), do: {:error, :invalid_worktree_policy}

  defp valid_workspace_root?(root) do
    safe_identity?(root) and Path.type(root) == :absolute
  end

  defp valid_hooks?(hooks) when is_map(hooks) do
    command_keys = ~w(after_create after_run before_remove before_run)

    Enum.sort(Map.keys(hooks)) == ~w(after_create after_run before_remove before_run timeout_ms) and
      Enum.all?(command_keys, fn key ->
        case Map.fetch!(hooks, key) do
          nil -> true
          value -> is_binary(value) and String.valid?(value)
        end
      end) and is_integer(hooks["timeout_ms"]) and hooks["timeout_ms"] > 0
  end

  defp valid_hooks?(_hooks), do: false

  defp valid_repo_policy?(
         %{
           "manifest" => manifest,
           "manifest_source_dir" => source_dir,
           "workflow_module_resolution" => module_resolution
         } = repo_policy
       ) do
    Enum.sort(Map.keys(repo_policy)) ==
      ["manifest", "manifest_source_dir", "workflow_module_resolution"] and
      is_map(manifest) and is_map(module_resolution) and is_binary(source_dir) and
      String.valid?(source_dir) and Path.type(source_dir) == :absolute
  end

  defp valid_repo_policy?(_repo_policy), do: false

  defp json_safe?(value) when is_struct(value), do: false

  defp json_safe?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and String.valid?(key) and json_safe?(nested)
    end)
  end

  defp json_safe?([]), do: true
  defp json_safe?([_value | _rest] = values), do: json_safe_list?(values)
  defp json_safe?(value) when is_binary(value), do: String.valid?(value)
  defp json_safe?(value) when is_float(value), do: finite_float?(value)
  defp json_safe?(value) when is_integer(value) or is_boolean(value) or is_nil(value), do: true
  defp json_safe?(_value), do: false

  defp json_safe_list?([]), do: true
  defp json_safe_list?([value | rest]), do: json_safe?(value) and json_safe_list?(rest)
  defp json_safe_list?(_improper), do: false

  defp finite_float?(value) do
    <<_sign::1, exponent::11, _fraction::52>> = <<value::float-64>>
    exponent != 0x7FF
  end

  defp own_json(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {:binary.copy(key), own_json(nested)} end)
  end

  defp own_json(value) when is_list(value), do: Enum.map(value, &own_json/1)
  defp own_json(value) when is_binary(value), do: :binary.copy(value)
  defp own_json(value), do: value

  defp own_binary(nil), do: nil
  defp own_binary(value), do: :binary.copy(value)

  defp own_target(target) do
    fields =
      target
      |> Map.from_struct()
      |> Map.new(fn {key, value} -> {key, own_term(value)} end)

    struct!(TargetContext, fields)
  end

  defp own_term(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {own_term(key), own_term(nested)} end)
  end

  defp own_term([]), do: []
  defp own_term([value | rest]), do: [own_term(value) | own_term(rest)]
  defp own_term(value) when is_binary(value), do: :binary.copy(value)
  defp own_term(value), do: value

  defp validate_runner_policy(
         %{
           "default" => default,
           "allowed" => allowed,
           "runners" => runners
         } = policy
       )
       when is_list(allowed) and is_map(runners) do
    cond do
      Enum.sort(Map.keys(policy)) != ~w(allowed default runners) ->
        {:error, :invalid_runner_policy}

      not valid_id?(default) ->
        {:error, :invalid_runner_policy}

      not proper_unique_ids?(allowed) ->
        {:error, :invalid_runner_policy}

      default not in allowed ->
        {:error, :runner_not_allowed}

      not Map.has_key?(runners, default) ->
        {:error, :runner_not_found}

      Enum.sort(Map.keys(runners)) != Enum.sort(allowed) ->
        {:error, :invalid_runner_policy}

      true ->
        validate_runners(runners, allowed)
    end
  end

  defp validate_runner_policy(_policy), do: {:error, :invalid_runner_policy}

  defp proper_unique_ids?(values) do
    proper_id_list?(values) and values != [] and length(values) == length(Enum.uniq(values))
  end

  defp proper_id_list?([]), do: true
  defp proper_id_list?([value | rest]), do: valid_id?(value) and proper_id_list?(rest)
  defp proper_id_list?(_values), do: false

  defp validate_runners(runners, allowed) do
    if Enum.all?(allowed, &valid_runner_entry?(runners, &1)),
      do: :ok,
      else: {:error, :invalid_runner_config}
  end

  defp valid_runner_entry?(runners, runner_name) do
    runner = Map.fetch!(runners, runner_name)
    match?({:ok, _profile}, resolve_profile(runner, "implementation"))
  end

  defp resolve_profile(runner, name) when is_map(runner) and not is_struct(runner) do
    case ExecutionProfile.resolve_pinned(runner, name, runner["turn_timeout_ms"], 0) do
      {:ok, profile} -> {:ok, profile}
      {:error, _reason} -> {:error, :invalid_runner_config}
    end
  end

  defp resolve_profile(_runner, _name), do: {:error, :invalid_runner_config}

  defp workspace_path(%TargetContext{} = target, issue_identifier, worker_host) do
    root = Path.expand(target.worktree_policy["root"])

    candidate =
      if legacy_target?(target) or Path.basename(root) == target.target_id do
        Path.join(root, issue_identifier)
      else
        Path.join([root, target.target_id, issue_identifier])
      end

    case worker_host do
      nil -> canonical_workspace_path(root, candidate)
      worker_host when is_binary(worker_host) -> remote_workspace_path(root, candidate)
    end
  end

  defp remote_workspace_path(root, candidate) do
    if strict_descendant?(root, Path.dirname(root)) and strict_descendant?(candidate, root),
      do: {:ok, candidate},
      else: {:error, :invalid_workspace_path}
  end

  defp legacy_target?(%TargetContext{issue_policy_authority: authority}),
    do: is_map(authority)

  defp canonical_workspace_path(root, candidate) do
    with :ok <- reject_workspace_symlinks(root, candidate),
         {:ok, canonical_parent} <- PathSafety.canonicalize(Path.dirname(root)),
         {:ok, canonical_root} <- PathSafety.canonicalize(root),
         {:ok, canonical_candidate} <- PathSafety.canonicalize(candidate) do
      if strict_descendant?(canonical_root, canonical_parent) and
           strict_descendant?(canonical_candidate, canonical_root),
         do: {:ok, canonical_candidate},
         else: {:error, :invalid_workspace_path}
    else
      {:error, _reason} -> {:error, :invalid_workspace_path}
    end
  end

  defp reject_workspace_symlinks(root, candidate) do
    paths =
      candidate
      |> Path.relative_to(root)
      |> Path.split()
      |> Enum.scan(root, fn segment, parent -> Path.join(parent, segment) end)
      |> then(&[root | &1])

    if Enum.all?(paths, &not_symlink?/1),
      do: :ok,
      else: {:error, :invalid_workspace_path}
  end

  defp not_symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> false
      {:ok, %File.Stat{}} -> true
      {:error, :enoent} -> true
      {:error, _reason} -> false
    end
  end

  defp strict_descendant?(candidate, root) do
    candidate_segments = Path.split(candidate)
    root_segments = Path.split(root)

    candidate != root and Enum.take(candidate_segments, length(root_segments)) == root_segments
  end
end

defimpl Inspect, for: SymphonyElixir.ExecutionContext do
  @impl true
  def inspect(_context, _opts), do: "#SymphonyElixir.ExecutionContext<redacted>"
end
