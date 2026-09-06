defmodule SymphonyElixir.OperatorMutation do
  @moduledoc """
  Host-owned preview and exact confirmation for operator mutations.

  This module is deliberately the boundary between an operator transport and
  the durable authorities. Registry paths, run owners, generations, and
  backend confirmation tokens are all derived or retained here; none are
  accepted from a client command.
  """

  alias SymphonyElixir.ControlPlane
  alias SymphonyElixir.HostScheduler
  alias SymphonyElixir.LocalConfig
  alias SymphonyElixir.OperatorCommandService
  alias SymphonyElixir.OperatorCommandService.Command
  alias SymphonyElixir.TargetRegistry.FileStore

  @target_actions ~w(activate pause drain retire patch)
  @run_actions ~w(resume_run abandon_run)
  @actions @target_actions ++ @run_actions ++ ~w(refresh shutdown prune)
  @disabled_target_codes [
    :invalid_transition,
    :plan_not_applicable,
    :target_not_found,
    :target_retired,
    :invalid_lifecycle_target,
    :dispatch_mode_required
  ]
  @disabled_run_codes [:operator_action_not_allowed, :reconciliation_required, :lease_held]

  @type prepared :: %{
          required(:identity) => map(),
          required(:current_state) => map(),
          required(:proposed_state) => map(),
          required(:consequences) => [String.t()],
          required(:warnings) => [String.t()],
          required(:disabled_reason) => String.t() | nil,
          required(:registry_generation) => String.t(),
          required(:binding) => map(),
          required(:command) => map()
        }

  @spec preview(map(), keyword()) :: {:ok, prepared()} | {:error, term()}
  def preview(command, opts) when is_map(command) and is_list(opts) do
    with :ok <- validate_command(command),
         {:ok, authorities} <- authorities(opts) do
      safe_call(fn -> do_preview(command, opts, authorities) end)
    end
  end

  def preview(_command, _opts), do: {:error, :invalid_command}

  @spec confirm(prepared(), keyword()) :: {:ok, map()} | {:error, term()}
  def confirm(prepared, opts) when is_map(prepared) and is_list(opts) do
    with :ok <- validate_prepared(prepared),
         {:ok, authorities} <- authorities(opts),
         :ok <- bind_confirmation(prepared, opts) do
      safe_call(fn -> do_confirm(prepared, opts, authorities) end)
    end
  end

  def confirm(_prepared, _opts), do: {:error, :invalid_confirmation}

  defp authorities(opts) do
    scheduler = Keyword.get(opts, :host_scheduler)
    control_plane = Keyword.get(opts, :control_plane)
    host_id = Keyword.get(opts, :host_id)

    cond do
      is_nil(scheduler) -> {:error, :scheduler_unavailable}
      not valid_host_id?(host_id) -> {:error, :invalid_host_id}
      true -> {:ok, %{scheduler: scheduler, control_plane: control_plane, host_id: host_id}}
    end
  end

  defp validate_command(%{"action" => action, "inputs" => inputs} = command)
       when action in @actions and is_map(inputs) do
    with true <- exact_command_keys?(command, action),
         :ok <- validate_identity(command, action) do
      validate_inputs(action, inputs)
    else
      false -> {:error, :invalid_command}
      {:error, _reason} = error -> error
    end
  end

  defp validate_command(%{"action" => action}) when action in @actions,
    do: {:error, :invalid_inputs}

  defp validate_command(_command), do: {:error, :invalid_action}

  defp validate_identity(command, action) do
    cond do
      action in @target_actions and not valid_id?(command["target_id"]) -> {:error, :invalid_target_id}
      action in @run_actions and not valid_id?(command["run_id"]) -> {:error, :invalid_run_id}
      true -> :ok
    end
  end

  defp validate_inputs("activate", %{"dispatch_mode" => mode} = inputs)
       when map_size(inputs) == 1 and mode in ["explicit", "watch"], do: :ok

  defp validate_inputs("patch", %{"changes" => changes} = inputs)
       when map_size(inputs) == 1 and is_map(changes), do: :ok

  defp validate_inputs(action, inputs)
       when action not in ["activate", "patch"] and map_size(inputs) == 0, do: :ok

  defp validate_inputs(_action, _inputs), do: {:error, :invalid_inputs}

  defp exact_command_keys?(command, action) when action in @target_actions,
    do: Map.keys(command) |> Enum.sort() == ["action", "inputs", "target_id"]

  defp exact_command_keys?(command, action) when action in @run_actions,
    do: Map.keys(command) |> Enum.sort() == ["action", "inputs", "run_id"]

  defp exact_command_keys?(command, _action),
    do: Map.keys(command) |> Enum.sort() == ["action", "inputs"]

  defp do_preview(command, opts, %{scheduler: scheduler, control_plane: control_plane, host_id: host_id}) do
    snapshot = HostScheduler.snapshot(scheduler)
    generation = registry_generation(snapshot)

    case command["action"] do
      action when action in @target_actions ->
        preview_target(command, opts, snapshot, generation, host_id)

      action when action in @run_actions ->
        preview_run(command, snapshot, generation, control_plane, host_id)

      "prune" ->
        preview_prune(command, opts, snapshot, generation, control_plane, host_id)

      "refresh" ->
        preview_refresh(command, snapshot, generation, host_id)

      "shutdown" ->
        preview_shutdown(command, snapshot, generation, host_id)
    end
  end

  defp preview_target(command, _opts, snapshot, generation, host_id) do
    with {:ok, registry_path} <- registry_path(snapshot),
         {:ok, typed_command} <- target_command(command),
         {:ok, plan} <-
           OperatorCommandService.plan(
             typed_command,
             registry_path: registry_path
           ),
         true <- plan.expected_generation == generation do
      current_target = current_target_state(snapshot, command["target_id"])
      registry_preview = safe_term(Map.get(plan.preview, "registry", %{}))
      proposed_target = proposed_target_state(registry_preview, current_target)
      warnings = target_warnings(registry_preview, plan.applicable?)
      disabled_reason = if plan.applicable?, do: nil, else: "plan_not_applicable"

      {:ok,
       prepared_target(
         command,
         host_id,
         generation,
         %{target: current_target, registry: %{generation: generation}},
         %{target: proposed_target, registry: registry_preview, preview: safe_term(plan.preview)},
         warnings,
         disabled_reason,
         if(
           plan.applicable?,
           do: registry_binding(command, host_id, registry_path, plan),
           else: disabled_binding(command, host_id, generation, disabled_reason)
         )
       )}
    else
      false ->
        {:error, :stale_generation}

      {:error, %OperatorCommandService.Error{} = error} ->
        target_disabled_or_error(command, snapshot, generation, host_id, error)

      {:error, reason} ->
        {:error, public_code(reason)}
    end
  end

  defp target_disabled_or_error(command, snapshot, generation, host_id, %OperatorCommandService.Error{} = error) do
    if error.code in @disabled_target_codes do
      current_target = current_target_state(snapshot, command["target_id"])
      reason = Atom.to_string(error.code)

      {:ok,
       prepared_target(
         command,
         host_id,
         generation,
         %{target: current_target, registry: %{generation: generation}},
         %{target: current_target, registry: %{}, preview: %{}},
         [error_message(error.code)],
         reason,
         disabled_binding(command, host_id, generation, reason)
       )}
    else
      {:error, public_backend_error(error)}
    end
  end

  defp prepared_target(
         command,
         host_id,
         generation,
         current_state,
         proposed_state,
         warnings,
         disabled_reason,
         binding
       ) do
    consequences =
      target_consequences(command["action"], current_state.target, proposed_state.target, proposed_state.registry)

    %{
      identity: %{action: command["action"], target_id: command["target_id"], host_id: host_id},
      current_state: current_state,
      proposed_state: proposed_state,
      consequences: consequences,
      warnings: warnings,
      disabled_reason: disabled_reason,
      registry_generation: generation,
      binding: binding,
      command: command
    }
  end

  defp preview_run(_command, _snapshot, _generation, nil, _host_id),
    do: {:error, :control_plane_unavailable}

  defp preview_run(command, _snapshot, generation, control_plane, host_id) do
    action = run_action(command["action"])
    run_id = command["run_id"]

    case ControlPlane.preview_run_action(control_plane, action, run_id) do
      {:ok, preview} ->
        run = safe_term(preview.run)
        availability = run_availability(preview.run, action)
        disabled_reason = availability && availability.disabled_reason
        proposed = proposed_run_state(run, action)

        binding =
          if is_nil(disabled_reason) do
            %{
              kind: :run,
              action: action,
              run_id: run_id,
              host_id: host_id,
              registry_generation: generation,
              confirmation: preview.confirmation,
              lifecycle_sequence: Map.get(preview.run, :lifecycle_sequence),
              lifecycle_state: Map.get(preview.run, :lifecycle_state),
              fencing_generation: Map.get(preview.run, :fencing_generation),
              command: command
            }
          else
            disabled_binding(command, host_id, generation, disabled_reason)
          end

        {:ok,
         %{
           identity: %{action: command["action"], run_id: run_id, host_id: host_id},
           current_state: %{run: run},
           proposed_state: %{run: proposed},
           consequences: run_consequences(action, run),
           warnings: if(is_nil(disabled_reason), do: [], else: [error_message(disabled_reason)]),
           disabled_reason: disabled_reason,
           registry_generation: generation,
           binding: binding,
           command: command
         }}

      {:error, reason} when reason in @disabled_run_codes ->
        disabled_run_preview(command, control_plane, generation, host_id, reason)

      {:error, reason} ->
        {:error, public_code(reason)}
    end
  end

  defp disabled_run_preview(command, control_plane, generation, host_id, reason) do
    with {:ok, runs} <- ControlPlane.inspect_runs(control_plane),
         %{} = run <- Enum.find(runs, &(&1.admitted_run_id == command["run_id"])) do
      {:ok,
       %{
         identity: %{action: command["action"], run_id: command["run_id"], target_id: run.target_id, host_id: host_id},
         current_state: %{run: run},
         proposed_state: %{run: run},
         consequences: [],
         warnings: [error_message(reason)],
         disabled_reason: Atom.to_string(reason),
         registry_generation: generation,
         binding: disabled_binding(command, host_id, generation, Atom.to_string(reason)),
         command: command
       }}
    else
      _ -> {:error, :run_unavailable}
    end
  end

  defp preview_prune(command, opts, _snapshot, generation, control_plane, host_id) do
    if is_nil(control_plane) do
      {:error, :control_plane_unavailable}
    else
      with {:ok, config} <- LocalConfig.load(config_root: Keyword.get(opts, :config_root) || LocalConfig.root()),
           {:ok, retention_days} <- LocalConfig.terminal_retention_days(config),
           {:ok, preview} <- ControlPlane.preview_prune(control_plane, retention_days) do
        safe_preview = safe_term(preview)

        {:ok,
         %{
           identity: %{action: "prune", host_id: host_id},
           current_state: %{runs: Map.get(safe_preview, :eligible_runs, [])},
           proposed_state: %{
             prune: Map.take(safe_preview, [:eligible_count, :preserved_terminal_count, :retention_days])
           },
           consequences: [
             "prune #{Map.get(safe_preview, :eligible_count, 0)} terminal runs older than #{retention_days} days"
           ],
           warnings: [],
           disabled_reason: nil,
           registry_generation: generation,
           binding: %{
             kind: :prune,
             host_id: host_id,
             registry_generation: generation,
             retention_days: retention_days,
             confirmation: preview.confirmation,
             command: command
           },
           command: command
         }}
      else
        {:error, reason} -> {:error, public_code(reason)}
      end
    end
  end

  defp preview_refresh(command, snapshot, generation, host_id) do
    {:ok,
     %{
       identity: %{action: "refresh", host_id: host_id},
       current_state: safe_scheduler_state(snapshot),
       proposed_state: %{operations: ["registry_reload", "poll", "reconcile"], status: "queued"},
       consequences: ["reload the registry and request tracker polling and reconciliation"],
       warnings: [],
       disabled_reason: nil,
       registry_generation: generation,
       binding: %{kind: :refresh, host_id: host_id, registry_generation: generation, command: command},
       command: command
     }}
  end

  defp preview_shutdown(command, snapshot, generation, host_id) do
    status = Map.get(snapshot, :shutdown, %{ready?: false, reason: :targets_not_drained})
    disabled_reason = if status.ready?, do: nil, else: Atom.to_string(status.reason || :shutdown_unavailable)

    {:ok,
     %{
       identity: %{action: "shutdown", host_id: host_id},
       current_state: safe_scheduler_state(snapshot),
       proposed_state: %{shutdown: true},
       consequences: ["stop the host after new admissions and tracked work have stopped"],
       warnings: if(is_nil(disabled_reason), do: [], else: [error_message(disabled_reason)]),
       disabled_reason: disabled_reason,
       registry_generation: generation,
       binding:
         if(is_nil(disabled_reason),
           do: %{kind: :shutdown, host_id: host_id, registry_generation: generation, command: command},
           else: disabled_binding(command, host_id, generation, disabled_reason)
         ),
       command: command
     }}
  end

  defp do_confirm(prepared, opts, %{scheduler: scheduler, control_plane: control_plane}) do
    binding = prepared.binding

    with :ok <- revalidate_generation(scheduler, prepared.registry_generation) do
      case binding.kind do
        :registry -> confirm_registry(prepared, opts, scheduler, binding)
        :run -> confirm_run(prepared, control_plane, binding)
        :refresh -> confirm_refresh(scheduler, binding.registry_generation)
        :prune -> confirm_prune(control_plane, binding)
        :shutdown -> confirm_shutdown(scheduler, prepared.registry_generation)
        :disabled -> {:error, disabled_error(prepared.disabled_reason)}
        _ -> {:error, :invalid_confirmation}
      end
    end
  end

  defp confirm_registry(prepared, _opts, scheduler, binding) do
    result =
      OperatorCommandService.confirm(
        binding.target_id,
        binding.plan_id,
        true,
        registry_path: binding.registry_path
      )

    case result do
      {:ok, %OperatorCommandService.ApplyResult{} = applied} ->
        case HostScheduler.reload(scheduler) do
          {:ok, _snapshot} ->
            {:ok,
             %{
               action: prepared.command["action"],
               target_id: binding.target_id,
               committed?: applied.committed?,
               old_generation: applied.old_generation,
               new_generation: applied.new_generation,
               scheduler_reloaded?: true
             }}

          {:error, _reason} ->
            {:error, %{code: :scheduler_reload_failed, state_may_have_changed: true}}
        end

      {:error, %OperatorCommandService.Error{} = error} ->
        if error.committed?, do: HostScheduler.reload(scheduler)
        {:error, public_backend_error(error)}
    end
  end

  defp confirm_shutdown(scheduler, generation) do
    case HostScheduler.begin_shutdown(scheduler, generation) do
      :ok ->
        {:ok, %{action: "shutdown", shutdown_requested?: true}}

      {:error, reason} ->
        {:error, %{code: public_code(reason), state_may_have_changed: false}}
    end
  end

  defp confirm_run(_prepared, control_plane, binding) do
    if is_nil(control_plane) do
      {:error, :control_plane_unavailable}
    else
      case ControlPlane.confirm_run_action(
             control_plane,
             binding.action,
             binding.run_id,
             binding.host_id,
             binding.confirmation
           ) do
        {:ok, %{run: run} = result} ->
          {:ok,
           %{
             action: Atom.to_string(binding.action),
             run_id: binding.run_id,
             run: safe_term(run),
             fencing_generation: result.lease.fencing_token
           }}

        {:error, reason} ->
          {:error,
           %{
             code: public_code(reason),
             state_may_have_changed: state_may_have_changed?(reason)
           }}
      end
    end
  end

  defp confirm_refresh(scheduler, generation) do
    case HostScheduler.refresh(scheduler, generation) do
      {:ok, snapshot} ->
        for {_target_id, %{pid: pid}} <- snapshot.targets, is_pid(pid), do: GenServer.call(pid, :request_refresh)

        {:ok, %{action: "refresh", registry_generation: registry_generation(snapshot), scheduler_reloaded?: true}}

      {:error, reason} ->
        {:error, %{code: public_code(reason), state_may_have_changed: refresh_state_may_have_changed?(reason)}}
    end
  end

  defp confirm_prune(control_plane, binding) do
    if is_nil(control_plane) do
      {:error, :control_plane_unavailable}
    else
      case ControlPlane.prune(control_plane, binding.retention_days, binding.confirmation) do
        {:ok, result} ->
          {:ok, %{action: "prune", retention_days: binding.retention_days, result: safe_term(result)}}

        {:error, reason} ->
          {:error, %{code: public_code(reason), state_may_have_changed: state_may_have_changed?(reason)}}
      end
    end
  end

  defp validate_prepared(prepared) do
    required = [
      :identity,
      :current_state,
      :proposed_state,
      :consequences,
      :warnings,
      :disabled_reason,
      :registry_generation,
      :binding,
      :command
    ]

    if Enum.all?(required, &Map.has_key?(prepared, &1)) and
         is_map(prepared.command) and is_map(prepared.binding) and is_binary(prepared.registry_generation) do
      :ok
    else
      {:error, :invalid_confirmation}
    end
  end

  defp bind_confirmation(prepared, opts) do
    host_id = Keyword.get(opts, :host_id)

    if valid_host_id?(host_id) and
         get_in(prepared, [:identity, :host_id]) == host_id and
         get_in(prepared, [:binding, :host_id]) == host_id and
         get_in(prepared, [:binding, :command]) == prepared.command do
      :ok
    else
      {:error, :confirmation_binding_mismatch}
    end
  end

  defp revalidate_generation(scheduler, generation) do
    case HostScheduler.snapshot(scheduler) do
      %{shutdown: %{requested?: true}} ->
        {:error, %{code: :shutdown_requested, state_may_have_changed: false}}

      %{registry: %{generation: ^generation, verified?: true, path: path}} when is_binary(path) ->
        case FileStore.read(path) do
          {:ok, %{generation: ^generation}} -> :ok
          _ -> {:error, %{code: :stale_generation, state_may_have_changed: false}}
        end

      %{registry: %{generation: ^generation, verified?: true}} ->
        :ok

      %{registry: %{verified?: false}} ->
        {:error, %{code: :registry_unverified, state_may_have_changed: false}}

      _ ->
        {:error, %{code: :stale_generation, state_may_have_changed: false}}
    end
  end

  defp target_command(%{"action" => action, "target_id" => target_id, "inputs" => inputs}) do
    case action do
      "activate" ->
        {:ok, %Command.Activate{target_id: target_id, dispatch_mode: dispatch_mode(Map.get(inputs, "dispatch_mode"))}}

      "pause" ->
        {:ok, %Command.Pause{target_id: target_id}}

      "drain" ->
        {:ok, %Command.Drain{target_id: target_id}}

      "retire" ->
        {:ok, %Command.Retire{target_id: target_id}}

      "patch" ->
        patch_command(target_id, inputs)
    end
  end

  defp patch_command(target_id, %{"changes" => changes}),
    do: {:ok, %Command.Patch{target_id: target_id, changes: changes}}

  defp dispatch_mode("explicit"), do: :explicit
  defp dispatch_mode("watch"), do: :watch
  defp run_action("resume_run"), do: :resume
  defp run_action("abandon_run"), do: :abandon

  defp registry_binding(command, host_id, registry_path, plan) do
    binding = %{
      kind: :registry,
      action: command["action"],
      target_id: command["target_id"],
      host_id: host_id,
      plan_id: plan.id,
      registry_path: registry_path,
      expected_generation: plan.expected_generation,
      proposed_generation: plan.proposed_generation,
      command: command
    }

    case Map.get(plan.preview, "branch_selection") do
      selection when is_map(selection) -> Map.put(binding, :branch_selection, selection)
      _missing -> binding
    end
  end

  defp disabled_binding(command, host_id, generation, reason) do
    %{kind: :disabled, host_id: host_id, registry_generation: generation, reason: reason, command: command}
  end

  defp current_target_state(snapshot, target_id) do
    snapshot
    |> Map.get(:targets, %{})
    |> Map.get(target_id, %{target_id: target_id, configured_state: :unknown, effective_state: :unknown})
    |> Map.put(:target_id, target_id)
    |> safe_term()
  end

  defp proposed_target_state(registry_preview, current_target) do
    registry_preview
    |> Map.fetch!("targets")
    |> Enum.find(fn summary -> summary["id"] == current_target.target_id end)
    |> safe_term()
  end

  defp target_warnings(registry_preview, applicable?) do
    impact_warning =
      case get_in(registry_preview, ["impact", "overall"]) do
        value when value in ["broadened", "mixed", "unknown", :broadened, :mixed, :unknown] ->
          ["registry preview includes #{value} policy impact"]

        _ ->
          []
      end

    impact_warning ++ if(applicable?, do: [], else: ["mutation is not applicable to the current registry"])
  end

  defp target_consequences(action, current, proposed, registry_preview) do
    state_before = Map.get(current, :configured_state, Map.get(current, "configured_state"))
    state_after = Map.get(proposed, :configured_state, Map.get(proposed, "configured_state"))

    state_change =
      "target #{action} changes configured state from #{format_value(state_before)} to #{format_value(state_after)}; existing runs retain their admitted policy"

    diff = Map.get(registry_preview, "diff", [])
    changes = Enum.map(diff, &format_change/1)
    [state_change | changes]
  end

  defp run_consequences(:resume, run) do
    [
      "resume run #{run.admitted_run_id} from #{run.lifecycle_state} to running",
      "acquire a new host-owned lease and retain the pinned admission policy"
    ]
  end

  defp run_consequences(:abandon, run) do
    [
      "abandon run #{run.admitted_run_id} as completed",
      "acquire a new host-owned lease before recording abandonment"
    ]
  end

  defp proposed_run_state(run, action) do
    run
    |> Map.take([:admitted_run_id, :target_id, :issue_identifier])
    |> Map.put(:lifecycle_state, if(action == :resume, do: "running", else: "completed"))
  end

  defp run_availability(run, action) do
    ControlPlane.operator_action_availability(run)
    |> Enum.find(&(&1.action == Atom.to_string(action)))
    |> case do
      %{available: false} = disabled -> disabled
      _ -> nil
    end
  end

  defp safe_scheduler_state(snapshot) do
    snapshot
    |> Map.drop([:policy])
    |> Map.update(:registry, %{}, &Map.delete(&1, :path))
    |> safe_term()
  end

  defp registry_path(%{registry: %{path: path}}) when is_binary(path) and path != "", do: {:ok, path}
  defp registry_path(_snapshot), do: {:error, :registry_not_configured}

  defp registry_generation(%{registry: %{generation: generation}}) when is_binary(generation), do: generation
  defp registry_generation(_snapshot), do: "unknown"

  defp safe_call(fun) do
    fun.()
  rescue
    _exception -> {:error, %{code: :authority_unavailable, state_may_have_changed: true}}
  catch
    _kind, _reason -> {:error, %{code: :authority_unavailable, state_may_have_changed: true}}
  end

  defp state_may_have_changed?(reason) do
    public_code(reason) not in [
      :invalid_confirmation,
      :invalid_operator_action,
      :operator_action_not_allowed,
      :admission_not_found,
      :reconciliation_required,
      :lease_held,
      :invalid_lease,
      :invalid_retention
    ]
  end

  defp refresh_state_may_have_changed?(reason), do: public_code(reason) != :stale_generation

  defp public_backend_error(error), do: %{code: error.code, state_may_have_changed: error.committed?}
  defp public_code(%{code: code}) when is_atom(code), do: code
  defp public_code(code) when is_atom(code), do: code
  defp public_code(_code), do: :backend_failed

  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason) when is_binary(reason), do: reason
  defp disabled_error(reason), do: %{code: :mutation_disabled, disabled_reason: reason, state_may_have_changed: false}

  defp format_change(change) do
    path = Map.get(change, "path", Map.get(change, :path, "registry"))
    before = Map.get(change, "before", Map.get(change, :before))
    after_value = Map.get(change, "after", Map.get(change, :after))
    "#{path}: #{format_value(before)} -> #{format_value(after_value)}"
  end

  defp format_value(nil), do: "nil"
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(safe_term(value), limit: 20, printable_limit: 200)

  defp safe_term(%_{} = struct), do: struct |> Map.from_struct() |> safe_term()

  defp safe_term(map) when is_map(map) do
    map
    |> Map.drop([:pid, :monitor, :registry_path, "pid", "monitor", "registry_path"])
    |> Map.new(fn {key, value} -> {key, safe_term(value)} end)
  end

  defp safe_term(list) when is_list(list), do: Enum.map(list, &safe_term/1)
  defp safe_term(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&safe_term/1)
  defp safe_term(value), do: value

  defp valid_id?(value) when is_binary(value), do: value != "" and String.valid?(value)
  defp valid_id?(_value), do: false
  defp valid_host_id?(value), do: valid_id?(value)
end
