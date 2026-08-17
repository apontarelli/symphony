defmodule SymphonyElixir.TargetContext do
  @moduledoc false

  alias SymphonyElixir.TargetRegistry
  alias SymphonyElixir.TargetRegistry.Composition
  alias SymphonyElixir.TargetRegistry.Snapshot
  alias SymphonyElixir.TargetRegistry.Target

  @target_id_regex ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
  @secret_provider_regex ~r|^secret://[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$|
  @effective_policy_keys ~w(
    budget_limits
    capacity_limits
    effective_checks
    external_side_effect_gates
    repo_policy
    run_target
    runner_policy
    scheduling
    tracker_connection
    worktree_policy
  )

  @enforce_keys [
    :target_id,
    :state,
    :dispatch_mode,
    :registry_generation,
    :policy_hash,
    :repo_manifest_hash,
    :repo_policy,
    :tracker_connection,
    :run_target,
    :worktree_policy,
    :runner_policy,
    :effective_checks,
    :external_side_effect_gates,
    :capacity_limits,
    :budget_limits
  ]
  defstruct @enforce_keys

  @type state :: :paused | :active | :draining | :retired
  @type dispatch_mode :: :explicit | :watch | nil
  @type t :: %__MODULE__{
          target_id: String.t(),
          state: state(),
          dispatch_mode: dispatch_mode(),
          registry_generation: TargetRegistry.generation(),
          policy_hash: TargetRegistry.generation(),
          repo_manifest_hash: TargetRegistry.generation(),
          repo_policy: map(),
          tracker_connection: map(),
          run_target: map(),
          worktree_policy: map(),
          runner_policy: map(),
          effective_checks: map(),
          external_side_effect_gates: map(),
          capacity_limits: map(),
          budget_limits: map()
        }

  @spec from_registry(Snapshot.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, atom()}
  def from_registry(snapshot, target_id, opts \\ []), do: build_context(snapshot, target_id, opts)

  defp build_context(%Snapshot{} = snapshot, target_id, opts)
       when is_binary(target_id) and is_list(opts) do
    with :ok <- validate_options(opts),
         :ok <- validate_target_id(target_id),
         {:ok, generation, targets} <- validate_snapshot(snapshot),
         {:ok, target} <- fetch_target(targets, target_id),
         :ok <- validate_state(target.effective_state),
         :ok <- validate_dispatch_mode(target.effective_state, target.dispatch_mode),
         :ok <- validate_policy_hash(target.policy_hash),
         :ok <- validate_repo_manifest(target.repo_manifest),
         :ok <- validate_policy_projection(target.effective_policy, target.repo_manifest),
         {:ok, repo_manifest_hash} <- hash_repo_manifest(target.repo_manifest),
         :ok <- verify_policy_integrity(target.effective_policy, target.policy_hash),
         :ok <- validate_tracker_secret_reference(target.effective_policy),
         :ok <- Composition.verify_composed_target(snapshot, target_id),
         {:ok, policy} <- policy_projection(target.effective_policy, target.repo_manifest),
         {:ok, tracker_connection} <- resolve_tracker_secret(policy.tracker_connection, opts) do
      {:ok,
       struct!(__MODULE__,
         target_id: target_id,
         state: target.effective_state,
         dispatch_mode: target.dispatch_mode,
         registry_generation: generation,
         policy_hash: target.policy_hash,
         repo_manifest_hash: repo_manifest_hash,
         repo_policy: policy.repo_policy,
         tracker_connection: tracker_connection,
         run_target: policy.run_target,
         worktree_policy: policy.worktree_policy,
         runner_policy: policy.runner_policy,
         effective_checks: policy.effective_checks,
         external_side_effect_gates: policy.external_side_effect_gates,
         capacity_limits: policy.capacity_limits,
         budget_limits: policy.budget_limits
       )}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_context(%Snapshot{}, target_id, _opts) when is_binary(target_id),
    do: {:error, :invalid_options}

  defp build_context(%Snapshot{}, _target_id, _opts), do: {:error, :invalid_target_id}
  defp build_context(_snapshot, _target_id, _opts), do: {:error, :invalid_snapshot}

  defp validate_options(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(opts, fn {key, _value} -> key == :env_fetcher end) and
         length(Keyword.get_values(opts, :env_fetcher)) <= 1,
       do: :ok,
       else: {:error, :invalid_options}
  end

  defp validate_target_id(target_id) do
    if String.valid?(target_id) and Regex.match?(@target_id_regex, target_id),
      do: :ok,
      else: {:error, :invalid_target_id}
  end

  defp validate_snapshot(%Snapshot{
         version: 1,
         path: path,
         source_hash: source_hash,
         generation: generation,
         globally_valid?: true,
         host: host,
         targets: targets,
         diagnostics: diagnostics
       })
       when is_map(host) and is_map(targets) and is_list(diagnostics) do
    cond do
      not proper_list?(diagnostics) ->
        {:error, :invalid_snapshot}

      not valid_nonblank_string?(path) ->
        {:error, :invalid_snapshot}

      not valid_hash?(generation) or source_hash != generation ->
        {:error, :invalid_registry_generation}

      true ->
        {:ok, generation, targets}
    end
  end

  defp validate_snapshot(_snapshot), do: {:error, :invalid_snapshot}

  defp fetch_target(targets, target_id) do
    case Map.fetch(targets, target_id) do
      {:ok, %Target{valid?: true, id: ^target_id} = target} -> {:ok, target}
      {:ok, _invalid} -> {:error, :invalid_target}
      :error -> {:error, :target_not_found}
    end
  end

  defp validate_state(state) when state in [:paused, :active, :draining, :retired], do: :ok
  defp validate_state(_state), do: {:error, :invalid_target_state}

  defp validate_dispatch_mode(:active, mode) when mode in [:explicit, :watch], do: :ok

  defp validate_dispatch_mode(state, mode)
       when state in [:paused, :draining, :retired] and mode in [:explicit, :watch, nil],
       do: :ok

  defp validate_dispatch_mode(_state, _mode), do: {:error, :invalid_dispatch_mode}

  defp validate_policy_hash(hash) do
    if valid_hash?(hash), do: :ok, else: {:error, :invalid_policy_hash}
  end

  defp validate_repo_manifest(manifest) when is_map(manifest), do: :ok
  defp validate_repo_manifest(_manifest), do: {:error, :invalid_repo_manifest}

  defp hash_repo_manifest(manifest) do
    case Composition.canonical_hash(manifest) do
      {:ok, hash} -> {:ok, hash}
      {:error, :not_json_safe} -> {:error, :repo_manifest_not_json_safe}
    end
  end

  defp verify_policy_integrity(policy, expected_hash) do
    case Composition.canonical_hash(policy) do
      {:ok, ^expected_hash} -> :ok
      {:ok, _other_hash} -> {:error, :policy_hash_mismatch}
      {:error, :not_json_safe} -> {:error, :effective_policy_not_json_safe}
    end
  end

  defp validate_policy_projection(
         %{
           "repo_policy" => repo_policy,
           "tracker_connection" => %{"policy" => %{"api_key" => api_key}} = tracker_connection,
           "run_target" => run_target,
           "worktree_policy" => worktree_policy,
           "runner_policy" => runner_policy,
           "effective_checks" => effective_checks,
           "external_side_effect_gates" => external_side_effect_gates,
           "capacity_limits" => capacity_limits,
           "budget_limits" => budget_limits,
           "scheduling" => scheduling
         } = policy,
         repo_manifest
       ) do
    values = [
      repo_policy,
      tracker_connection,
      run_target,
      worktree_policy,
      runner_policy,
      effective_checks,
      external_side_effect_gates,
      capacity_limits,
      budget_limits
    ]

    if Enum.sort(Map.keys(policy)) == @effective_policy_keys and
         Enum.all?(values, &is_map/1) and is_map(scheduling) and is_binary(api_key) do
      validate_linked_policy(repo_policy, repo_manifest)
    else
      {:error, :invalid_policy_projection}
    end
  end

  defp validate_policy_projection(_policy, _repo_manifest),
    do: {:error, :invalid_policy_projection}

  defp policy_projection(policy, repo_manifest) do
    with :ok <- validate_policy_projection(policy, repo_manifest) do
      {:ok,
       %{
         repo_policy: policy["repo_policy"],
         tracker_connection: policy["tracker_connection"],
         run_target: policy["run_target"],
         worktree_policy: policy["worktree_policy"],
         runner_policy: policy["runner_policy"],
         effective_checks: policy["effective_checks"],
         external_side_effect_gates: policy["external_side_effect_gates"],
         capacity_limits: policy["capacity_limits"],
         budget_limits: policy["budget_limits"]
       }}
    end
  end

  defp validate_linked_policy(repo_policy, repo_manifest) do
    case Map.fetch(repo_policy, "manifest") do
      {:ok, ^repo_manifest} ->
        if is_map(repo_policy["workflow_module_resolution"]) do
          :ok
        else
          {:error, :invalid_policy_projection}
        end

      {:ok, _other_manifest} ->
        {:error, :repo_manifest_mismatch}

      :error ->
        {:error, :invalid_policy_projection}
    end
  end

  defp validate_tracker_secret_reference(%{
         "tracker_connection" => %{"policy" => %{"api_key" => reference}}
       })
       when is_binary(reference) do
    case secret_variable(reference) do
      {:ok, _variable} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_tracker_secret(%{"policy" => %{"api_key" => reference} = tracker_policy} = connection, opts)
       when is_binary(reference) do
    with {:ok, variable} <- secret_variable(reference),
         {:ok, fetcher} <- env_fetcher(opts),
         {:ok, value} <- fetch_secret(fetcher, variable) do
      {:ok, put_in(connection, ["policy"], Map.put(tracker_policy, "api_key", value))}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp env_fetcher(opts) do
    case Keyword.get(opts, :env_fetcher, &System.fetch_env/1) do
      fetcher when is_function(fetcher, 1) -> {:ok, fetcher}
      _invalid -> {:error, :secret_resolution_failed}
    end
  end

  defp fetch_secret(fetcher, variable) do
    case invoke_fetcher(fetcher, variable) do
      {:ok, :error} ->
        {:error, :missing_secret}

      {:ok, {:ok, value}} when is_binary(value) ->
        cond do
          not String.valid?(value) -> {:error, :secret_resolution_failed}
          String.trim(value) == "" -> {:error, :missing_secret}
          true -> {:ok, value}
        end

      _malformed ->
        {:error, :secret_resolution_failed}
    end
  end

  defp invoke_fetcher(fetcher, variable) do
    {:ok, fetcher.(variable)}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp secret_variable(reference) do
    if Regex.run(@secret_provider_regex, reference) == [reference] do
      {:error, :unsupported_secret_provider}
    else
      case Regex.run(~r/\A\$([A-Za-z0-9._-]+)\z/, reference, capture: :all_but_first) do
        [variable] -> {:ok, variable}
        _no_match -> braced_secret_variable(reference)
      end
    end
  end

  defp braced_secret_variable(reference) do
    case Regex.run(~r/\A\$\{([A-Za-z0-9._-]+)\}\z/, reference, capture: :all_but_first) do
      [variable] -> {:ok, variable}
      _no_match -> {:error, :invalid_secret_reference}
    end
  end

  defp valid_hash?(value),
    do: is_binary(value) and Regex.match?(~r/^sha256:[0-9a-f]{64}$/, value)

  defp valid_nonblank_string?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp proper_list?([]), do: true
  defp proper_list?([_value | rest]), do: proper_list?(rest)
  defp proper_list?(_value), do: false
end

defimpl Inspect, for: SymphonyElixir.TargetContext do
  import Inspect.Algebra

  @impl true
  def inspect(context, opts) do
    safe =
      Map.take(context, [
        :target_id,
        :state,
        :dispatch_mode,
        :registry_generation,
        :policy_hash,
        :repo_manifest_hash
      ])

    concat(["#SymphonyElixir.TargetContext<", to_doc(safe, opts), ">"])
  end
end
