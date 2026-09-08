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
  alias SymphonyElixir.OperatorSettingsApply
  alias SymphonyElixir.TargetContext
  alias SymphonyElixir.TargetRegistry.Composition
  alias SymphonyElixir.TargetRegistry.FileStore
  alias SymphonyElixir.TargetRegistry.Schema
  alias SymphonyElixir.TargetRegistry.Snapshot
  alias SymphonyElixir.TargetRegistry.Validation
  alias SymphonyElixir.TargetRegistry.Yaml
  alias SymphonyElixir.TargetRouting
  alias SymphonyElixir.Tracker

  @target_actions ~w(activate pause drain retire patch settings_apply batch)
  @run_actions ~w(resume_run abandon_run)
  @actions @target_actions ++ @run_actions ++ ~w(legacy_import refresh shutdown prune)
  @settings_input_keys ~w(selections repository linear_revision scope)
  @legacy_import_input_keys ~w(local_config legacy_registry connection_id)
  @max_batch_issues 100
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

  defp validate_inputs("settings_apply", inputs) do
    if Enum.all?(Map.keys(inputs), &(&1 in @settings_input_keys)) and
         optional_selections?(inputs, "selections") and optional_binary?(inputs, "repository") and
         optional_binary?(inputs, "linear_revision") and Map.get(inputs, "scope") in [nil, "host", "target"] do
      :ok
    else
      {:error, :invalid_inputs}
    end
  end

  defp validate_inputs("batch", %{"issue_ids" => issue_ids} = inputs)
       when map_size(inputs) == 1 and is_list(issue_ids) and issue_ids != [] and
              length(issue_ids) <= @max_batch_issues do
    if Enum.all?(issue_ids, &(is_binary(&1) and String.valid?(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, :invalid_inputs}
    end
  end

  defp validate_inputs("legacy_import", inputs) do
    if Enum.all?(Map.keys(inputs), &(&1 in @legacy_import_input_keys)) and
         optional_binary?(inputs, "local_config") and optional_binary?(inputs, "legacy_registry") and
         optional_binary?(inputs, "connection_id") and
         (is_binary(inputs["local_config"]) or is_binary(inputs["legacy_registry"])) do
      :ok
    else
      {:error, :invalid_inputs}
    end
  end

  defp validate_inputs(action, inputs)
       when action not in ["activate", "patch", "settings_apply", "batch", "legacy_import"] and
              map_size(inputs) == 0,
       do: :ok

  defp validate_inputs(_action, _inputs), do: {:error, :invalid_inputs}

  defp exact_command_keys?(command, action) when action in @target_actions,
    do: Map.keys(command) |> Enum.sort() == ["action", "inputs", "target_id"]

  defp exact_command_keys?(command, action) when action in @run_actions,
    do: Map.keys(command) |> Enum.sort() == ["action", "inputs", "run_id"]

  defp exact_command_keys?(command, _action),
    do: Map.keys(command) |> Enum.sort() == ["action", "inputs"]

  defp optional_selections?(inputs, key) do
    case Map.fetch(inputs, key) do
      :error -> true
      {:ok, nil} -> true
      {:ok, selections} when is_map(selections) -> json_safe?(selections)
      {:ok, _invalid} -> false
    end
  end

  defp optional_binary?(inputs, key) do
    case Map.fetch(inputs, key) do
      :error -> true
      {:ok, nil} -> true
      {:ok, value} -> is_binary(value) and String.valid?(value)
    end
  end

  defp json_safe?(value) do
    match?({:ok, _encoded}, Jason.encode(value))
  end

  defp do_preview(command, opts, %{scheduler: scheduler, control_plane: control_plane, host_id: host_id}) do
    snapshot = HostScheduler.snapshot(scheduler)
    generation = registry_generation(snapshot)

    case command["action"] do
      "legacy_import" ->
        preview_legacy_import(command, snapshot, generation, host_id)

      "settings_apply" ->
        preview_settings_apply(command, opts, snapshot, generation, host_id, scheduler)

      "batch" ->
        preview_batch(command, opts, snapshot, generation, host_id)

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

  # Settings Apply: host-owned conversion of field selections into a paused
  # Add (creation) or a settings-only Patch (update). Lifecycle fields never
  # pass through; activation stays a separate preview and confirm.
  defp preview_settings_apply(command, opts, snapshot, generation, host_id, scheduler) do
    with {:ok, registry_path} <- registry_path(snapshot),
         {:ok, applied} <-
           OperatorSettingsApply.build(scheduler, command["target_id"], command["inputs"], opts),
         {:ok, plan} <- OperatorCommandService.plan(applied.command, registry_path: registry_path),
         true <- plan.expected_generation == generation do
      registry_preview = safe_term(Map.get(plan.preview, "registry", %{}))
      applicable? = plan.applicable?
      disabled_reason = if(applicable?, do: nil, else: "plan_not_applicable")

      binding =
        if applicable? do
          # Settings keeps its own repository verification: the host derives
          # identity and the command envelope re-checks readiness under the
          # registry lock, so no client branch-discovery scan is required.
          command
          |> registry_binding(host_id, registry_path, plan)
          |> Map.drop([:branch_selection])
          |> Map.put(:kind, :settings)
          |> Map.put(:settings, applied)
        else
          disabled_binding(command, host_id, generation, disabled_reason)
        end

      {current_state, proposed_state} = settings_states(applied, command, snapshot, registry_preview, generation)

      {:ok,
       %{
         identity: %{
           action: command["action"],
           target_id: command["target_id"],
           host_id: host_id,
           mode: mode_name(applied.mode)
         },
         current_state: current_state,
         proposed_state: proposed_state,
         consequences: settings_consequences(applied, registry_preview),
         warnings: target_warnings(registry_preview, applicable?),
         disabled_reason: disabled_reason,
         registry_generation: generation,
         binding: binding,
         command: command
       }}
    else
      false ->
        {:error, :stale_generation}

      {:error, %OperatorCommandService.Error{} = error} ->
        target_disabled_or_error(command, snapshot, generation, host_id, error)

      {:error, %{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, public_code(reason)}
    end
  end

  # Legacy cutover import: host-scope preview/confirm of the migration of
  # legacy local configuration and legacy registries into the host registry.
  # The registry is the only authority afterward; imported targets are paused.
  defp preview_legacy_import(command, snapshot, generation, host_id) do
    inputs = command["inputs"]

    with {:ok, registry_path} <- registry_path(snapshot),
         typed_command <-
           %Command.LegacyImport{
             local_config: inputs["local_config"],
             legacy_registry: inputs["legacy_registry"],
             connection_id: inputs["connection_id"]
           },
         {:ok, plan} <- OperatorCommandService.plan(typed_command, registry_path: registry_path),
         true <- plan.expected_generation == generation do
      registry_preview = safe_term(Map.get(plan.preview, "registry", %{}))
      applicable? = plan.applicable?
      disabled_reason = if(applicable?, do: nil, else: "plan_not_applicable")

      binding =
        if applicable? do
          %{
            kind: :registry,
            action: "legacy_import",
            host_id: host_id,
            registry_generation: generation,
            plan_id: plan.id,
            registry_path: registry_path,
            target_id: "host",
            command: command
          }
        else
          disabled_binding(command, host_id, generation, disabled_reason)
        end

      {:ok,
       %{
         identity: %{action: command["action"], target_id: "host", host_id: host_id},
         current_state: %{registry: %{generation: generation}},
         proposed_state: %{
           registry: registry_preview,
           legacy_import: safe_term(Map.get(plan.preview, "legacy_import", %{}))
         },
         consequences: [
           "migrate the legacy configuration into the host registry; repository manifests and saved setups stop being runtime authority",
           "imported targets enter paused state without a dispatch mode; activation is a separate confirmed command",
           "the pre-cutover registry is archived as a source revision for recovery"
         ],
         warnings: target_warnings(registry_preview, applicable?),
         disabled_reason: disabled_reason,
         registry_generation: generation,
         binding: binding,
         command: command
       }}
    else
      false ->
        {:error, :stale_generation}

      {:error, %OperatorCommandService.Error{} = error} ->
        {:error, public_backend_error(error)}

      {:error, reason} ->
        {:error, public_code(reason)}
    end
  end

  # A host-scope Apply shares policy across every target; there is no single
  # current or proposed target, so the preview describes the shared edit and
  # the affected-target projection instead.
  defp settings_states(%{mode: :host} = applied, _command, _snapshot, registry_preview, generation) do
    {
      %{registry: %{generation: generation}},
      %{
        registry: registry_preview,
        settings: %{mode: "host", values: applied.values, affected_targets: applied.affected}
      }
    }
  end

  defp settings_states(applied, command, snapshot, registry_preview, generation) do
    current_target = current_target_state(snapshot, command["target_id"])
    proposed_target = proposed_target_state(registry_preview, current_target)

    {
      %{target: current_target, registry: %{generation: generation}},
      %{
        target: proposed_target,
        registry: registry_preview,
        settings: %{
          mode: mode_name(applied.mode),
          values: applied.values,
          affected_targets: affected_targets(registry_preview)
        }
      }
    }
  end

  # Explicit issue batch: previews the exact issues, repository, pinned
  # policy, and limits, then confirms as a scope patch on the existing target.
  # No second daemon and no new saved-workflow format are involved.
  defp preview_batch(command, opts, snapshot, generation, host_id) do
    with {:ok, registry_path} <- registry_path(snapshot),
         {:ok, registry_snapshot} <- registry_snapshot(registry_path) do
      issue_ids = command["inputs"]["issue_ids"]

      case batch_context(registry_snapshot, command["target_id"]) do
        {:ok, context} ->
          preview_admissible_batch(
            command,
            opts,
            context,
            registry_snapshot,
            registry_path,
            issue_ids,
            generation,
            host_id
          )

        {:error, reason} ->
          {:ok,
           %{
             identity: %{action: command["action"], target_id: command["target_id"], host_id: host_id},
             current_state: %{target: current_target_state(snapshot, command["target_id"])},
             proposed_state: %{},
             consequences: [],
             warnings: [error_message(reason)],
             disabled_reason: Atom.to_string(reason),
             registry_generation: generation,
             binding: disabled_binding(command, host_id, generation, Atom.to_string(reason)),
             command: command
           }}
      end
    end
  end

  defp preview_admissible_batch(
         command,
         opts,
         context,
         registry_snapshot,
         registry_path,
         issue_ids,
         generation,
         host_id
       ) do
    with {:ok, issues} <- fetch_batch_issues(context, issue_ids, opts),
         :ok <- require_known_issues(issue_ids, issues),
         entries = TargetRouting.snapshot_entries(registry_snapshot),
         draft = batch_draft_entry(registry_snapshot, context, issue_ids),
         :ok <- validate_batch_routing(entries, draft, issues),
         patch = %Command.Patch{target_id: command["target_id"], changes: batch_scope_patch(issue_ids)},
         {:ok, plan} <- OperatorCommandService.plan(patch, registry_path: registry_path),
         true <- plan.expected_generation == generation,
         {:ok, proposed} <-
           proposed_batch_context(registry_snapshot, patch, plan.proposed_generation) do
      batch = batch_projection(proposed, issues, draft)
      registry_preview = safe_term(Map.get(plan.preview, "registry", %{}))
      proposed_target = proposed_target_state(registry_preview, batch_current_target(context))
      applicable? = plan.applicable?
      disabled_reason = if(applicable?, do: nil, else: "plan_not_applicable")

      binding =
        if applicable? do
          command
          |> registry_binding(host_id, registry_path, plan)
          |> Map.put(:kind, :batch)
          |> Map.put(:batch, %{
            issue_ids: issue_ids,
            issues: Enum.map(issues, &batch_issue_identity/1),
            fingerprint: batch_fingerprint(issues)
          })
        else
          disabled_binding(command, host_id, generation, disabled_reason)
        end

      {:ok,
       %{
         identity: %{action: command["action"], target_id: command["target_id"], host_id: host_id},
         current_state: %{
           target: batch_current_target(context),
           registry: %{generation: generation}
         },
         proposed_state: %{
           target: proposed_target,
           registry: registry_preview,
           batch: batch
         },
         consequences: [
           "queue #{length(issue_ids)} issues on target #{command["target_id"]} in repository #{batch.repository}"
           | batch_consequences(context, command["target_id"])
         ],
         warnings: batch_warnings(context, issues),
         disabled_reason: disabled_reason,
         registry_generation: generation,
         binding: binding,
         command: command
       }}
    else
      false -> {:error, :stale_generation}
      {:error, %OperatorCommandService.Error{} = error} -> {:error, public_backend_error(error)}
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, public_code(reason)}
    end
  end

  defp batch_context(registry_snapshot, target_id) do
    with {:ok, context} <- TargetContext.pin_from_registry(registry_snapshot, target_id) do
      cond do
        context.dispatch_mode != :explicit -> {:error, :explicit_target_required}
        context.state in [:retired, :draining] -> {:error, :invalid_lifecycle_target}
        true -> {:ok, context}
      end
    end
  end

  defp fetch_batch_issues(context, issue_ids, opts) do
    fetcher = Keyword.get(opts, :fetch_issues, &Tracker.fetch_issue_states_by_ids/2)

    case invoke_fetch(fetcher, context, issue_ids) do
      {:ok, issues} when is_list(issues) -> {:ok, issues}
      {:error, reason} -> {:error, %{code: public_code(reason), state_may_have_changed: false}}
      _failed -> {:error, %{code: :tracker_unavailable, state_may_have_changed: false}}
    end
  end

  defp invoke_fetch(fetcher, context, issue_ids) when is_function(fetcher, 2),
    do: fetcher.(context, issue_ids)

  defp invoke_fetch(_fetcher, _context, _issue_ids), do: {:error, :tracker_unavailable}

  # Every requested identifier must resolve; unknown issues fail the batch.
  defp require_known_issues(issue_ids, issues) do
    resolved = MapSet.new(Enum.flat_map(issues, &[normalize_batch_identifier(&1.identifier), &1.id]))

    unknown =
      issue_ids
      |> Enum.reject(&MapSet.member?(resolved, normalize_batch_identifier(&1)))

    cond do
      unknown != [] ->
        {:error, %{code: :issues_not_found, detail: Enum.sort(unknown), state_may_have_changed: false}}

      length(issue_ids) != length(issues) or MapSet.size(MapSet.new(issues, & &1.id)) != length(issues) ->
        {:error, %{code: :duplicate_batch_issue, state_may_have_changed: false}}

      true ->
        :ok
    end
  end

  defp normalize_batch_identifier(value) when is_binary(value), do: String.trim(value)
  defp normalize_batch_identifier(_value), do: nil

  defp validate_batch_routing(entries, draft, issues) do
    entries = TargetRouting.with_draft(entries, %{draft | active?: true})

    Enum.reduce_while(issues, :ok, fn issue, :ok ->
      case TargetRouting.resolve_issue_for(entries, draft.target_id, issue) do
        :ok ->
          {:cont, :ok}

        {:error, {code, _detail}} ->
          {:halt, {:error, %{code: code, issue_identifier: issue.identifier, state_may_have_changed: false}}}

        {:error, code} ->
          {:halt, {:error, %{code: code, issue_identifier: issue.identifier, state_may_have_changed: false}}}
      end
    end)
  end

  defp batch_draft_entry(registry_snapshot, context, issue_ids) do
    scope = get_in(context.run_target || %{}, ["scope"]) || %{}

    TargetRouting.configured_entry(
      context.target_id,
      %{
        "linear" => %{
          "connection" => get_in(context.tracker_connection || %{}, ["id"]),
          "scope" => Map.merge(scope, %{"type" => "issues", "issue_ids" => issue_ids})
        },
        "repo" => %{
          "path" => batch_repository_path(registry_snapshot, context),
          "expected_repository" => batch_repository_identity(registry_snapshot, context)
        }
      },
      context.state == :active
    )
  end

  defp batch_repository_path(registry_snapshot, context) do
    get_in(registry_snapshot.targets, [context.target_id, Access.key!(:configured), "repo", "path"])
  rescue
    _error -> nil
  end

  defp batch_repository_identity(registry_snapshot, context) do
    get_in(registry_snapshot.targets, [context.target_id, Access.key!(:configured), "repo", "expected_repository"])
  rescue
    _error -> nil
  end

  defp batch_current_target(context) do
    context
    |> Map.take([:target_id, :state, :dispatch_mode, :policy_hash])
    |> safe_term()
  end

  defp batch_projection(context, issues, draft) do
    %{
      issues:
        Enum.map(issues, fn issue ->
          %{
            id: issue.id,
            identifier: issue.identifier,
            title: issue.title,
            state: issue.state,
            team_key: issue.team_key,
            project_id: issue.project_id,
            labels: issue.labels
          }
        end),
      repository: draft.repository,
      policy: %{
        policy_hash: context.policy_hash,
        configuration_revision: get_in(context.repo_policy || %{}, ["configuration_revision"]),
        repository_profile: get_in(context.repo_policy || %{}, ["configuration_sources", "profile", "name"])
      },
      limits: %{
        capacity_limits: context.capacity_limits,
        budget_limits: context.budget_limits,
        issue_batch_limit: length(Map.get(draft.scope || %{}, "issue_ids") || [])
      }
    }
  end

  defp batch_consequences(context, target_id) do
    [
      "the batch runs on this host under target #{target_id}'s newly composed policy; each dispatched run pins it at admission",
      "issue_batch_limit equals the batch size; each issue dispatches once",
      "state #{context.state} target: #{if(context.state == :active, do: "admission starts on confirm", else: "admission starts when the target is activated")}"
    ]
  end

  defp batch_warnings(%TargetContext{state: :paused}, _issues),
    do: ["target is paused; the batch is admitted only after activation"]

  defp batch_warnings(_context, _issues), do: []

  defp batch_issue_identity(issue),
    do: %{id: issue.id, identifier: issue.identifier, state: issue.state}

  defp batch_fingerprint(issues) do
    issues
    |> Enum.map(&{&1.id, &1.identifier, &1.project_id, &1.team_key, &1.labels})
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # The scope patch replaces every selector explicitly; leaving a stale
  # team or project selector behind would make the composed scope invalid.
  defp batch_scope_patch(issue_ids) do
    %{
      "linear" => %{
        "scope" => %{
          "type" => "issues",
          "issue_ids" => issue_ids,
          "project_id" => nil,
          "project_slug" => nil,
          "team_key" => nil,
          "query_file" => nil
        }
      }
    }
  end

  # Revalidate the scope replacement so overlap diagnostics and policy authority
  # describe the proposal rather than the previous registry target.
  defp proposed_batch_context(
         %Snapshot{} = snapshot,
         %Command.Patch{target_id: target_id, changes: %{"linear" => %{"scope" => scope}}},
         generation
       ) do
    scope = Map.reject(scope, fn {_key, value} -> is_nil(value) end)

    targets =
      snapshot.targets
      |> Map.new(fn {id, target} -> {id, target.configured} end)
      |> Map.update!(target_id, &put_in(&1, ["linear", "scope"], scope))

    document = %{"version" => snapshot.version, "host" => snapshot.host, "targets" => targets}

    with {:ok, proposed} <- Schema.validate(document, registry_path: snapshot.path) do
      proposed =
        proposed
        |> Map.merge(%{path: snapshot.path, source_hash: generation, generation: generation})
        |> Validation.validate(registry_path: snapshot.path)
        |> Composition.compose()

      TargetContext.pin_from_registry(proposed, target_id)
    end
  end

  defp settings_consequences(applied, registry_preview) do
    mode_line =
      case applied.mode do
        :create ->
          "create target #{applied.target_id} as paused; activation is a separate preview and confirm"

        :update ->
          "save settings for target #{applied.target_id}; the lifecycle state does not change"

        :host ->
          "save shared host repository policy layers; lifecycle states never change"
      end

    diff_lines =
      registry_preview
      |> Map.get("diff", [])
      |> Enum.map(&format_change/1)

    [mode_line, "admitted runs keep their pinned admission policy"] ++
      host_affected_lines(applied.affected) ++ diff_lines
  end

  defp host_affected_lines([]), do: []

  defp host_affected_lines(affected) do
    Enum.flat_map(affected, fn target ->
      profile = target.repository_profile || "none"

      [
        "target #{target.target_id} (profile #{profile}, #{target.state}): #{length(target.changes)} repository policy field(s) change effective value from shared layers on its next admission"
      ]
    end)
  end

  defp affected_targets(registry_preview) do
    registry_preview
    |> Map.get("diff", [])
    |> Enum.flat_map(fn change ->
      case Regex.run(~r{^\$\.targets\.([a-z0-9-]+)\.}, Map.get(change, "path", "")) do
        [_, target_id] -> [target_id]
        _other -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp mode_name(:create), do: "create"
  defp mode_name(:update), do: "update"
  defp mode_name(:host), do: "host"

  defp registry_snapshot(registry_path) do
    case SymphonyElixir.HostScheduler.Registry.load(registry_path) do
      {:ok, %{snapshot: snapshot}} -> {:ok, snapshot}
      _invalid -> {:error, :registry_unavailable}
    end
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

  defp do_confirm(%{binding: %{kind: :disabled}} = prepared, _opts, _authorities),
    do: {:error, disabled_error(prepared.disabled_reason)}

  defp do_confirm(prepared, opts, %{scheduler: scheduler, control_plane: control_plane}) do
    binding = prepared.binding

    with :ok <- revalidate_generation(scheduler, prepared.registry_generation) do
      case binding.kind do
        :registry -> confirm_registry(prepared, opts, scheduler, binding)
        :settings -> confirm_settings(prepared, opts, scheduler, binding)
        :batch -> confirm_batch(prepared, opts, scheduler, binding)
        :run -> confirm_run(prepared, control_plane, binding)
        :refresh -> confirm_refresh(scheduler, binding.registry_generation)
        :prune -> confirm_prune(control_plane, binding)
        :shutdown -> confirm_shutdown(scheduler, prepared.registry_generation)
        _ -> {:error, :invalid_confirmation}
      end
    end
  end

  defp confirm_registry(prepared, _opts, scheduler, binding),
    do: apply_registry_binding(prepared, scheduler, binding)

  # Settings Apply confirms only after the rebuilt catalog reproduces the
  # previewed command exactly; stale catalogs fail closed with nothing
  # committed, and the result carries authoritative post-Apply values.
  defp confirm_settings(prepared, opts, scheduler, binding) do
    with :ok <- OperatorSettingsApply.verify(scheduler, binding.settings, opts),
         {:ok, result} <- apply_registry_binding(prepared, scheduler, binding) do
      case OperatorSettingsApply.readback(scheduler, binding.settings, opts) do
        {:ok, settings} ->
          {:ok, result |> Map.put(:mode, mode_name(binding.settings.mode)) |> Map.put(:settings, settings)}

        {:error, %{code: code, reason: reason}} ->
          # The registry commit stands; only the readback is unavailable, and
          # the result says so instead of implying failure.
          {:ok,
           result
           |> Map.put(:mode, mode_name(binding.settings.mode))
           |> Map.put(:settings, %{status: "unavailable", code: code, reason: reason})}
      end
    end
  end

  # Batch confirmation re-resolves every issue identity and re-runs the
  # single-repository routing rules before the scope patch commits.
  defp confirm_batch(prepared, opts, scheduler, binding) do
    with :ok <- verify_batch(prepared, scheduler, binding, opts),
         {:ok, result} <- apply_registry_binding(prepared, scheduler, binding) do
      {:ok, Map.put(result, :batch, batch_readback(scheduler, binding))}
    end
  end

  defp verify_batch(_prepared, scheduler, binding, opts) do
    snapshot = HostScheduler.snapshot(scheduler)

    with %{registry: %{verified?: true, path: path}} <- snapshot,
         {:ok, registry_snapshot} <- registry_snapshot(path),
         {:ok, context} <- batch_context(registry_snapshot, binding.target_id),
         {:ok, issues} <- fetch_batch_issues(context, binding.batch.issue_ids, opts),
         :ok <- require_known_issues(binding.batch.issue_ids, issues),
         :ok <- require_pinned_issues(binding.batch, issues),
         entries = TargetRouting.snapshot_entries(registry_snapshot),
         draft = batch_draft_entry(registry_snapshot, context, binding.batch.issue_ids),
         :ok <- validate_batch_routing(entries, draft, issues) do
      :ok
    else
      {:error, %{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, %{code: public_code(reason), state_may_have_changed: false}}

      _unavailable ->
        {:error, %{code: :registry_unverified, state_may_have_changed: false}}
    end
  end

  # Identity, not state, is pinned: an issue may move between preview and
  # confirm, but it may not become a different issue.
  defp require_pinned_issues(%{fingerprint: fingerprint}, issues) do
    if batch_fingerprint(issues) == fingerprint,
      do: :ok,
      else: {:error, %{code: :batch_issues_changed, state_may_have_changed: false}}
  end

  defp batch_readback(scheduler, binding) do
    snapshot = HostScheduler.snapshot(scheduler)

    with %{registry: %{verified?: true, path: path}} <- snapshot,
         {:ok, %{bytes: bytes}} <- FileStore.read(path),
         {:ok, document} <- Yaml.decode(bytes),
         {:ok, validated} <- Schema.validate(document, registry_path: path),
         {:ok, target} <- Map.fetch(validated.targets, binding.target_id),
         configured <- target.configured do
      %{
        issue_ids: get_in(configured, ["linear", "scope", "issue_ids"]),
        repository: get_in(configured, ["repo", "expected_repository"]) || get_in(configured, ["repo", "path"])
      }
    else
      _unavailable -> %{status: "unavailable", reason: "batch_readback_unavailable"}
    end
  end

  defp apply_registry_binding(prepared, scheduler, binding) do
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
            {:error, %{code: :scheduler_reload_failed, committed?: true, state_may_have_changed: true}}
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

  defp public_backend_error(error), do: %{code: error.code, committed?: error.committed?, state_may_have_changed: error.committed?}
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
