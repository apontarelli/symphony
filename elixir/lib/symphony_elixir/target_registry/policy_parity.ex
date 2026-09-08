defmodule SymphonyElixir.TargetRegistry.PolicyParity do
  @moduledoc """
  Before/after restriction comparison for configuration imports.

  `compare/3` proves that a proposed host-owned policy preserves every
  validation, capability, protected-path, budget, side-effect, and landing
  restriction of the legacy policy it replaces. Any weakening returns
  diagnostics; the caller blocks the import rather than dropping fields.
  """

  alias SymphonyElixir.TargetRegistry.Diagnostic
  alias SymphonyElixir.Workflow.Manifest

  @gate_operations ~w(tracker_write vcs_publish pull_request_write merge deployment production_data)
  @gate_ranks %{"deny" => 3, "manual_approval" => 2, "allow" => 1}
  # Legacy admission treated an absent gate as allowed, and the registry
  # normalizes absent gates to deny, so both defaults are explicit here.
  @before_gate_default "allow"
  @after_gate_default "deny"

  @posture_ranks %{"off" => 3, "strict" => 2, "permissive" => 1}
  @budget_periods ~w(per_run daily weekly)
  @check_phases ~w(pre_dispatch pre_handoff pre_publish pre_merge)

  @type side :: %{optional(String.t()) => map() | nil}

  @type finding :: Diagnostic.t()

  @spec compare(side(), side(), String.t()) :: :ok | {:weakened, [finding()]}
  def compare(before, after_, target_id) when is_binary(target_id) do
    findings =
      manifest_findings(before["manifest"], after_["manifest"], target_id) ++
        target_findings(before["target"], after_["target"], target_id)

    if findings == [], do: :ok, else: {:weakened, findings}
  end

  defp manifest_findings(before_manifest, after_manifest, target_id) do
    before_side = comparison_side(before_manifest)
    after_side = comparison_side(after_manifest)

    validation_findings(canonical(before_side), canonical(after_side), target_id) ++
      docs_findings(canonical(before_side), canonical(after_side), target_id) ++
      capability_findings(canonical(before_side), canonical(after_side), target_id) ++
      auto_land_findings(canonical(before_side), canonical(after_side), target_id) ++
      automation_findings(canonical(before_side), canonical(after_side), target_id) ++
      retained_policy_findings(before_side, after_side, target_id)
  end

  # Both sides compare one canonical representation: Manifest normalization
  # applies the trimming and workflow expansion that compilation applies, so
  # a raw " README.md " entrypoint compares equal to its compiled
  # "README.md" spelling. A side that fails normalization falls back to its
  # raw document; callers fail closed on invalid raw fields separately.
  # Runtime setup is out of scope for policy comparison, so normalization
  # tolerates a runtime section.
  defp comparison_side(manifest) do
    manifest = map(manifest)

    case Manifest.normalize_map(manifest, repo_setup?: false) do
      {:ok, normalized} ->
        {manifest, Map.update(normalized, "workflow", %{}, &Map.delete(&1, "_module_requests"))}

      _invalid ->
        {manifest, nil}
    end
  end

  defp canonical({%{} = raw, nil}), do: raw
  defp canonical({_raw, %{} = normalized}), do: normalized

  defp target_findings(before_target, after_target, target_id) do
    before_target = map(before_target)
    after_target = map(after_target)

    budget_findings(before_target, after_target, target_id) ++
      gate_findings(before_target, after_target, target_id) ++
      check_findings(before_target, after_target, target_id) ++
      routing_findings(before_target, after_target, target_id) ++
      identity_findings(before_target, after_target, target_id)
  end

  defp validation_findings(before, after_, target_id) do
    command_findings(before, after_, target_id) ++ required_file_findings(before, after_, target_id)
  end

  defp command_findings(before, after_, target_id) do
    before_commands = commands_by_name(validation_commands(before))
    after_commands = commands_by_name(validation_commands(after_))

    dropped_command_findings(before_commands, after_commands, target_id) ++
      changed_command_findings(before_commands, after_commands, target_id)
  end

  defp validation_commands(manifest) do
    manifest
    |> get_in(["validation", "commands"])
    |> list()
    |> Enum.flat_map(fn
      %{"name" => name, "command" => command}
      when is_binary(name) and is_binary(command) and name != "" ->
        [{name, command}]

      _invalid ->
        []
    end)
  end

  # Manifest normalization keeps every command entry, duplicate names
  # included, and prompt rendering emits each one, so a name maps to a
  # multiset of required commands rather than a single spelling.
  defp commands_by_name(commands) do
    commands
    |> Enum.group_by(fn {name, _command} -> name end, fn {_name, command} -> command end)
    |> Map.new(fn {name, commands} -> {name, Enum.sort(commands)} end)
  end

  defp dropped_command_findings(before_commands, after_commands, target_id) do
    before_commands
    |> Map.keys()
    |> Enum.filter(&(not Map.has_key?(after_commands, &1)))
    |> Enum.sort()
    |> Enum.map(fn name ->
      path = "$.targets.#{target_id}.repository_policy.validation.commands.#{name}"

      finding(target_id, path, :validation_command_dropped, "#{path} is dropped by the import")
    end)
  end

  defp changed_command_findings(before_commands, after_commands, target_id) do
    before_commands
    |> Enum.filter(fn {name, _commands} -> Map.has_key?(after_commands, name) end)
    |> Enum.sort()
    |> Enum.flat_map(fn {name, before_set} ->
      after_set = Map.fetch!(after_commands, name)

      if before_set -- after_set == [] do
        []
      else
        path = "$.targets.#{target_id}.repository_policy.validation.commands.#{name}"

        [
          finding(
            target_id,
            path,
            :validation_command_changed,
            "#{path} changes from #{inspect(command_spelling(before_set))} to #{inspect(command_spelling(after_set))}"
          )
        ]
      end
    end)
  end

  defp command_spelling([command]), do: command
  defp command_spelling(commands), do: commands

  defp required_file_findings(before, after_, target_id) do
    before_files = string_set(get_in(before, ["validation", "required_files"]))
    after_files = string_set(get_in(after_, ["validation", "required_files"]))

    missing_set_findings(
      before_files,
      after_files,
      target_id,
      "$.validation.required_files",
      :validation_required_file_dropped
    )
  end

  defp docs_findings(before, after_, target_id) do
    before_docs = string_set(get_in(before, ["docs", "entrypoints"]))
    after_docs = string_set(get_in(after_, ["docs", "entrypoints"]))

    missing_set_findings(before_docs, after_docs, target_id, "$.docs.entrypoints", :docs_entrypoint_dropped)
  end

  defp capability_findings(before, after_, target_id) do
    before_caps = string_set(get_in(before, ["capabilities", "required"]))
    after_caps = string_set(get_in(after_, ["capabilities", "required"]))

    missing_set_findings(
      before_caps,
      after_caps,
      target_id,
      "$.capabilities.required",
      :required_capability_dropped
    )
  end

  defp auto_land_findings(before, after_, target_id) do
    before_auto_land = map(get_in(before, ["auto_land"]))
    after_auto_land = map(get_in(after_, ["auto_land"]))

    posture_findings(before_auto_land, after_auto_land, target_id) ++
      dry_run_findings(before_auto_land, after_auto_land, target_id) ++
      missing_set_findings(
        string_set(before_auto_land["force_human_review_paths"]),
        string_set(after_auto_land["force_human_review_paths"]),
        target_id,
        "$.auto_land.force_human_review_paths",
        :protected_path_dropped
      ) ++
      missing_set_findings(
        string_set(before_auto_land["force_human_review_labels"]),
        string_set(after_auto_land["force_human_review_labels"]),
        target_id,
        "$.auto_land.force_human_review_labels",
        :protected_label_dropped
      ) ++
      missing_set_findings(
        string_set(before_auto_land["required_checks"]),
        string_set(after_auto_land["required_checks"]),
        target_id,
        "$.auto_land.required_checks",
        :landing_required_check_dropped
      )
  end

  defp posture_findings(before_auto_land, after_auto_land, target_id) do
    before_rank = posture_rank(before_auto_land["posture"])
    after_rank = posture_rank(after_auto_land["posture"])

    if after_rank >= before_rank do
      []
    else
      path = "$.targets.#{target_id}.repository_policy.auto_land.posture"

      [
        finding(
          target_id,
          path,
          :landing_posture_weakened,
          "#{path} moves from #{before_auto_land["posture"] || "off"} to #{after_auto_land["posture"] || "off"}"
        )
      ]
    end
  end

  defp dry_run_findings(%{"dry_run" => true}, after_auto_land, target_id) do
    if after_auto_land["dry_run"] == true do
      []
    else
      path = "$.targets.#{target_id}.repository_policy.auto_land.dry_run"

      [finding(target_id, path, :landing_dry_run_disabled, "#{path} turns off landing simulation")]
    end
  end

  defp dry_run_findings(_before_auto_land, _after_auto_land, _target_id), do: []

  defp automation_findings(before, after_, target_id) do
    missing_set_findings(
      string_set(get_in(before, ["automation", "completion_requirements"])),
      string_set(get_in(after_, ["automation", "completion_requirements"])),
      target_id,
      "$.automation.completion_requirements",
      :completion_requirement_dropped
    )
  end

  # These fields have no safe ordering. Import must preserve their meaning
  # exactly; a settings change is a separate operation, not a migration.
  # Manifest normalization expands a workflow preset into its bundled
  # modules and trims raw spelling, so retained fields compare that resolved
  # representation on both sides. A field absent from the raw document
  # declares no restriction and stays nil: Manifest fills defaults for
  # absent sections, and those defaults must not become restrictions the
  # import has to defend.
  defp retained_policy_findings(before, after_, target_id) do
    paths =
      Enum.map(~w(project vcs delivery workflow review_routing harness issue_markers prompt_template), &[&1]) ++
        Enum.map(~w(posture profile review), &["automation", &1]) ++
        [["auto_land", "blocked_state"]]

    Enum.flat_map(paths, fn keys ->
      retained_value_findings(
        retained_policy_value(before, keys),
        retained_policy_value(after_, keys),
        target_id,
        "$.targets.#{target_id}.repository_policy." <> Enum.join(keys, ".")
      )
    end)
  end

  defp retained_policy_value({raw, nil}, keys), do: get_in(raw, keys)

  defp retained_policy_value({raw, normalized}, keys) do
    if get_in(raw, keys) == nil, do: nil, else: get_in(normalized, keys)
  end

  defp retained_value_findings(nil, _after, _target_id, _path), do: []

  defp retained_value_findings(before, after_, target_id, path) when is_map(before) and is_map(after_) do
    before
    |> Enum.sort()
    |> Enum.flat_map(fn {key, value} ->
      retained_value_findings(value, after_[key], target_id, path <> "." <> key)
    end)
  end

  defp retained_value_findings(value, value, _target_id, _path), do: []

  defp retained_value_findings(_before, _after, target_id, path) do
    [finding(target_id, path, :policy_changed, "#{path} is removed or changed by the import")]
  end

  defp budget_findings(before, after_, target_id) do
    @budget_periods
    |> Enum.flat_map(fn period ->
      before_budget = get_in(before, ["budgets", period, "max_total_tokens"])
      after_budget = get_in(after_, ["budgets", period, "max_total_tokens"])
      path = "$.targets.#{target_id}.budgets.#{period}.max_total_tokens"

      cond do
        not is_integer(before_budget) or before_budget <= 0 ->
          []

        is_integer(after_budget) and after_budget > 0 and after_budget <= before_budget ->
          []

        true ->
          [finding(target_id, path, :budget_raised, "#{path} is removed or raised above #{before_budget}")]
      end
    end)
  end

  defp gate_findings(before, after_, target_id) do
    before_gates = map(before["external_side_effects"])
    after_gates = map(after_["external_side_effects"])

    @gate_operations
    |> Enum.flat_map(fn operation ->
      before_rank = gate_rank(before_gates[operation], @before_gate_default)
      after_rank = gate_rank(after_gates[operation], @after_gate_default)
      path = "$.targets.#{target_id}.external_side_effects.#{operation}"

      if after_rank >= before_rank do
        []
      else
        [
          finding(
            target_id,
            path,
            :side_effect_gate_weakened,
            "#{path} moves from #{before_gates[operation] || @before_gate_default} to #{after_gates[operation] || @after_gate_default}"
          )
        ]
      end
    end)
  end

  defp check_findings(before, after_, target_id) do
    before_checks = map(before["checks"])
    after_checks = map(after_["checks"])

    @check_phases
    |> Enum.flat_map(fn phase ->
      missing_set_findings(
        string_set(before_checks[phase]),
        string_set(after_checks[phase]),
        target_id,
        "$.checks.#{phase}",
        :check_dropped
      )
    end)
  end

  defp routing_findings(before, after_, target_id) do
    before_linear = map(before["linear"])
    after_linear = map(after_["linear"])

    label_findings(before_linear, after_linear, target_id) ++
      scope_findings(before_linear, after_linear, target_id)
  end

  defp label_findings(before_linear, after_linear, target_id) do
    missing_set_findings(
      string_set(before_linear["required_labels"]),
      string_set(after_linear["required_labels"]),
      target_id,
      "$.linear.required_labels",
      :required_label_dropped
    )
  end

  defp scope_findings(before_linear, after_linear, target_id) do
    before_scope = map(before_linear["scope"])
    after_scope = map(after_linear["scope"])

    scope_type_findings(before_scope, after_scope, target_id) ++
      scope_selector_findings(before_scope, after_scope, target_id)
  end

  defp scope_type_findings(before_scope, after_scope, target_id) do
    if before_scope == %{} or before_scope["type"] == after_scope["type"] do
      []
    else
      path = "$.targets.#{target_id}.linear.scope.type"

      [
        finding(
          target_id,
          path,
          :tracker_scope_changed,
          "#{path} moves from #{inspect(before_scope["type"])} to #{inspect(after_scope["type"])}"
        )
      ]
    end
  end

  defp scope_selector_findings(before_scope, after_scope, target_id) do
    selector_findings = selector_changed_findings(before_scope, after_scope, target_id)
    selector_findings ++ issue_scope_findings(before_scope, after_scope, target_id)
  end

  defp selector_changed_findings(before_scope, after_scope, target_id) do
    before_scope
    |> Map.take(~w(project_id project_slug team_key query_file))
    |> Enum.sort()
    |> Enum.flat_map(fn {selector, value} ->
      if after_scope[selector] == value do
        []
      else
        path = "$.targets.#{target_id}.linear.scope.#{selector}"

        [
          finding(
            target_id,
            path,
            :tracker_scope_changed,
            "#{path} moves from #{inspect(value)} to #{inspect(after_scope[selector])}"
          )
        ]
      end
    end)
  end

  defp issue_scope_findings(%{"type" => "issues"} = before_scope, after_scope, target_id) do
    if after_scope["type"] == "issues" do
      missing_set_findings(
        string_set(after_scope["issue_ids"]),
        string_set(before_scope["issue_ids"]),
        target_id,
        "$.linear.scope.issue_ids",
        :tracker_scope_widened
      )
    else
      []
    end
  end

  defp issue_scope_findings(_before_scope, _after_scope, _target_id), do: []

  defp identity_findings(before, after_, target_id) do
    before_repo = map(before["repo"])
    after_repo = map(after_["repo"])

    identity_field_findings(before_repo, after_repo, target_id, "path", &expanded/1) ++
      identity_field_findings(before_repo, after_repo, target_id, "expected_repository", & &1)
  end

  defp identity_field_findings(before_repo, after_repo, target_id, field, normalizer) do
    before_value = normalize_optional(before_repo[field], normalizer)
    after_value = normalize_optional(after_repo[field], normalizer)

    if before_value in [nil, ""] or before_value == after_value do
      []
    else
      path = "$.targets.#{target_id}.repo.#{field}"

      [
        finding(
          target_id,
          path,
          :repository_identity_changed,
          "#{path} moves from #{inspect(before_value)} to #{inspect(after_value)}"
        )
      ]
    end
  end

  defp missing_set_findings(before_set, after_set, target_id, relative_path, code) do
    before_set
    |> MapSet.difference(after_set)
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.map(fn dropped ->
      field_path = String.trim_leading(relative_path, "$.")
      prefix = if String.starts_with?(field_path, ["checks.", "linear."]), do: "", else: "repository_policy."
      path = "$.targets.#{target_id}.#{prefix}#{field_path}"

      finding(target_id, path, code, "#{path} drops #{inspect(dropped)}")
    end)
  end

  defp finding(target_id, path, code, message) do
    %Diagnostic{
      severity: :error,
      scope: {:target, target_id},
      path: path,
      code: code,
      message: message
    }
  end

  defp posture_rank(posture) when is_binary(posture), do: Map.get(@posture_ranks, posture, 3)
  defp posture_rank(_posture), do: Map.get(@posture_ranks, "off")

  defp gate_rank(value, default) when is_binary(value), do: Map.get(@gate_ranks, value, Map.get(@gate_ranks, default))
  defp gate_rank(_value, default), do: Map.get(@gate_ranks, default)

  defp normalize_optional(value, normalizer) when is_binary(value), do: normalizer.(value)
  defp normalize_optional(_value, _normalizer), do: nil

  defp expanded(path), do: Path.expand(path)

  defp string_set(values) when is_list(values),
    do: values |> Enum.filter(&is_binary/1) |> MapSet.new()

  defp string_set(_values), do: MapSet.new()

  defp list(values) when is_list(values), do: values
  defp list(_values), do: []

  defp map(value) when is_map(value) and not is_struct(value), do: value
  defp map(_value), do: %{}
end
