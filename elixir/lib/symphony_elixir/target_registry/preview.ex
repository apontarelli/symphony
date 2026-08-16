defmodule SymphonyElixir.TargetRegistry.Preview do
  @moduledoc false

  alias SymphonyElixir.TargetRegistry.Diagnostic
  alias SymphonyElixir.TargetRegistry.Snapshot
  alias SymphonyElixir.TargetRegistry.Target

  @impact_categories [
    :state,
    :dispatch_mode,
    :scope,
    :runners,
    :capacity,
    :budgets,
    :checks,
    :external_side_effects
  ]
  @check_ids ~w(
    capability_preflight repo_validation quality_gate publish_preflight
    pr_checks review_feedback_sweep
  )

  @redaction_marker "[REDACTED]"
  @redaction_max_depth 64
  @redaction_max_nodes 10_000
  @sensitive_key_regex ~r/(?:api[_ -]?key|authorization|credential|password|passwd|secret|token|connection[_ -]?string|private[_ -]?key)/i
  @generation_regex ~r/^sha256:[0-9a-f]{64}$/
  @target_id_regex ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
  @public_path_max_bytes 1_024
  @dot_path_segment_regex ~r/^\.([a-z0-9](?:[a-z0-9_-]*[a-z0-9])?)/
  @indexed_path_segment_regex ~r/^\[\d+\]/
  @typed_path_segment_regex ~r/^\[key:\d+:(?:atom|string|integer|float|tuple|map|list|term|pid)\]/
  @capacity_path_regex ~r/^(?:\$\.host\.capacity\.max_concurrent_(?:agents|startups|reviewers)|\$\.targets\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.concurrency\.max_concurrent_(?:agents|startups|reviewers))$/
  @target_by_linear_state_path_regex ~r/^\$\.targets\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.concurrency\.by_linear_state$/
  @target_state_path_regex ~r/^\$\.targets\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.(?:state|effective_state)$/
  @target_dispatch_path_regex ~r/^\$\.targets\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.dispatch_mode$/
  @target_valid_path_regex ~r/^\$\.targets\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.valid$/
  @target_gate_path_regex ~r/^\$\.targets\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.external_side_effects\.(?:tracker_write|vcs_publish|pull_request_write|merge|deployment|production_data)$/
  @budget_path_regex ~r/^\$\.targets\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.budgets\.(?:per_run|daily|weekly)\.max_total_tokens$/
  @runner_set_path_regex ~r/^\$\.targets\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.runners\.allowed$/
  @required_label_set_path_regex ~r/^\$\.targets\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.linear\.required_labels$/
  @check_set_path_regex ~r/^\$\.targets\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.checks\.(?:pre_dispatch|pre_handoff|pre_publish|pre_merge)$/
  @private_key_regex ~r/-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----/is
  @authorization_assignment_regex ~r/(\bauthorization\s*[:=]\s*)(?:bearer|basic)\s+[A-Za-z0-9._~+\/=-]+/i
  @authorization_regex ~r/\b(bearer|basic)\s+[A-Za-z0-9._~+\/=-]+/i
  @secret_assignment_regex ~r/(\b(?:api[_ -]?key|authorization|credential|password|passwd|secret|token|connection[_ -]?string|private[_ -]?key)\s*[:=]\s*)([^&,\s;]+)/i
  @uri_userinfo_regex ~r{([a-z][a-z0-9+.-]*://)[^/\s@]+@}i
  @uri_regex ~r{[a-z][a-z0-9+.-]*://[^\s<>"']+}i
  @secret_token_regex ~r/\b(?:[A-Za-z0-9.]+[-_])?(?:token|secret|password|credential|api[_-]?key)[-_][A-Za-z0-9._~+\/=-]{4,}/i
  @resolved_env_regex ~r/\b(?:resolved[-_](?:env|environment)|(?:env|environment)[-_]resolved)[-_A-Za-z0-9._~+\/=-]{4,}/i
  @safe_path_keys ~w(
    version globally_valid host targets
    id state_root polling capacity scheduling tracker_connections runners
    interval_ms max_concurrent_target_polls max_concurrent_agents
    max_concurrent_startups max_concurrent_reviewers algorithm max_credit_rounds
    kind endpoint api_key command args env cwd adapter
    display_name state dispatch_mode repo worktree linear concurrency budgets checks
    external_side_effects path manifest expected_repository root strategy hooks
    after_create before_run after_run before_remove timeout_ms connection scope
    active_states terminal_states required_labels type project_id project_slug team_key
    query_file issue_ids allowed default settings model reasoning_effort max_turns
    execution_profiles by_linear_state per_run daily weekly max_total_tokens
    pre_dispatch pre_handoff pre_publish pre_merge capability_preflight repo_validation
    quality_gate publish_preflight pr_checks review_feedback_sweep tracker_write
    vcs_publish pull_request_write merge deployment production_data weight
    effective_state policy_hash valid
  )
  @safe_redacted_keys @safe_path_keys ++
                        ~w(
                          nested plain uri message database_connection_string private_key
                          authorization credential password invalid_utf8 before after
                          classification overall runtime changes host_dispatch
                          legacy_single_target configured_state source_changed
                          expected_generation proposed_generation diagnostics valid?
                        )
  @dynamic_path_suffixes [
    "$.targets",
    ".tracker_connections",
    ".runners",
    ".settings",
    ".by_linear_state"
  ]
  @safe_dynamic_key_regex ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/

  @enforce_keys [
    :expected_generation,
    :proposed_generation,
    :source_changed?,
    :globally_valid?,
    :targets,
    :diff,
    :impact,
    :diagnostics
  ]
  defstruct [
    :expected_generation,
    :proposed_generation,
    :source_changed?,
    :globally_valid?,
    targets: [],
    diff: [],
    impact: %{},
    diagnostics: []
  ]

  @type change_classification ::
          :added
          | :removed
          | :changed
          | :restricted
          | :broadened
          | :forced_paused
          | :source_difference

  @type change :: %{
          path: String.t(),
          before: term(),
          after: term(),
          classification: change_classification()
        }

  @type target_summary :: %{
          id: term(),
          configured_state: Target.configured_state(),
          effective_state: :paused | :active | :draining | :retired,
          dispatch_mode: Target.dispatch_mode(),
          valid?: boolean(),
          policy_hash: String.t() | nil
        }

  @type impact_classification ::
          :unchanged | :restricted | :broadened | :mixed | :unknown | :forced_paused

  @type impact_category :: %{
          classification: impact_classification(),
          changes: [change()]
        }

  @type impact :: %{
          overall: impact_classification(),
          state: impact_category(),
          dispatch_mode: impact_category(),
          scope: impact_category(),
          runners: impact_category(),
          capacity: impact_category(),
          budgets: impact_category(),
          checks: impact_category(),
          external_side_effects: impact_category(),
          runtime: %{
            host_dispatch: :unavailable_in_phase_1,
            legacy_single_target: :unchanged
          }
        }

  @type t :: %__MODULE__{
          expected_generation: SymphonyElixir.TargetRegistry.generation() | nil,
          proposed_generation: SymphonyElixir.TargetRegistry.generation(),
          source_changed?: boolean(),
          globally_valid?: boolean(),
          targets: [target_summary()],
          diff: [change()],
          impact: impact(),
          diagnostics: [Diagnostic.t()]
        }
  @spec preview(Snapshot.t(), binary()) :: t()
  def preview(%Snapshot{} = proposed, proposed_source) when is_binary(proposed_source) do
    preview(nil, proposed, proposed_source)
  end

  @spec preview(Snapshot.t() | nil, Snapshot.t(), binary()) :: t()
  def preview(current, %Snapshot{} = proposed, proposed_source)
      when (is_nil(current) or is_struct(current, Snapshot)) and is_binary(proposed_source) do
    expected_generation = current |> current_generation() |> public_expected_generation()
    current_source_generation = current_source_generation(current)
    proposed_generation = generation(proposed_source)
    source_changed? = is_nil(current) or current_source_generation != proposed_generation

    source_diff =
      if is_nil(current) or not source_changed? do
        []
      else
        [
          %{
            path: "$.generation",
            before: current_source_generation,
            after: proposed_generation,
            classification: :source_difference
          }
        ]
      end

    raw_diff = build_diff(current, proposed, source_diff)
    raw_impact = build_impact(raw_diff)

    raw_preview = %__MODULE__{
      expected_generation: expected_generation,
      proposed_generation: proposed_generation,
      source_changed?: source_changed?,
      globally_valid?: public_boolean(proposed.globally_valid?),
      targets: target_summaries(proposed.targets),
      diff: raw_diff,
      impact: raw_impact,
      diagnostics: proposed.diagnostics
    }

    secret_sources = {
      if(is_nil(current), do: %{}, else: snapshot_projection(current)),
      snapshot_projection(proposed),
      proposed.diagnostics
    }

    redact_preview(raw_preview, preview_secret_values(secret_sources))
  end

  defp redact_preview(%__MODULE__{} = preview, secrets) do
    %{
      preview
      | targets: Enum.map(preview.targets, &redact_target_summary(&1, secrets)),
        diff: Enum.map(preview.diff, &redact_change(&1, secrets)),
        impact: redact_impact(preview.impact, secrets),
        diagnostics: redact_with_secrets(preview.diagnostics, secrets)
    }
  end

  defp redact_impact(impact, secrets) do
    public = impact |> public_impact() |> redact_with_secrets(secrets)

    Enum.reduce(@impact_categories, public, fn category, redacted ->
      changes = Enum.map(impact[category].changes, &redact_change(&1, secrets))
      put_in(redacted, [category, :changes], changes)
    end)
  end

  defp redact_change(%{path: "$.generation"} = change, _secrets) do
    change
    |> Map.update!(:before, &public_generation/1)
    |> Map.update!(:after, &public_generation/1)
    |> public_change()
  end

  defp redact_change(change, secrets) do
    redacted =
      change
      |> public_change()
      |> redact_with_secrets(secrets)
      |> Map.put(:path, public_generated_path(change.path, secrets))

    if change[:sensitive?] do
      redacted
      |> redact_present_change_value(:before, change[:before_present?])
      |> redact_present_change_value(:after, change[:after_present?])
    else
      redacted
    end
  end

  defp redact_present_change_value(change, key, true),
    do: Map.put(change, key, @redaction_marker)

  defp redact_present_change_value(change, _key, false), do: change

  defp redact_target_summary(summary, secrets) do
    %{
      id: public_target_id(summary.id, secrets),
      configured_state: public_configured_state(summary.configured_state),
      effective_state: public_effective_state(summary.effective_state),
      dispatch_mode: public_dispatch_mode(summary.dispatch_mode),
      valid?: public_boolean(summary.valid?),
      policy_hash: public_policy_hash(summary.policy_hash)
    }
  end

  defp public_target_id(id, secrets) when is_binary(id) do
    if String.valid?(id) and Regex.match?(@target_id_regex, id) and
         replace_known_secrets(id, secrets) == id,
       do: id,
       else: @redaction_marker
  end

  defp public_target_id(_id, _secrets), do: @redaction_marker

  defp public_configured_state(state) when state in [:paused, :active, :draining, :retired, nil],
    do: state

  defp public_configured_state({:unknown, value}) when is_binary(value),
    do: {:unknown, @redaction_marker}

  defp public_configured_state(_state), do: @redaction_marker

  defp public_effective_state(state) when state in [:paused, :active, :draining, :retired],
    do: state

  defp public_effective_state(_state), do: @redaction_marker

  defp public_dispatch_mode(mode) when mode in [:explicit, :watch, nil], do: mode

  defp public_dispatch_mode({:unknown, value}) when is_binary(value),
    do: {:unknown, @redaction_marker}

  defp public_dispatch_mode(_mode), do: @redaction_marker

  defp public_policy_hash(nil), do: nil
  defp public_policy_hash(hash), do: public_generation(hash)

  defp public_generation(generation) when is_binary(generation) do
    if String.valid?(generation) and Regex.match?(@generation_regex, generation),
      do: generation,
      else: @redaction_marker
  end

  defp public_generation(_generation), do: @redaction_marker

  defp public_expected_generation(nil), do: nil
  defp public_expected_generation(generation), do: public_generation(generation)

  defp public_boolean(value) when is_boolean(value), do: value
  defp public_boolean(_value), do: false

  defp redact_diagnostic(%Diagnostic{} = diagnostic, secrets) do
    %{diagnostic | scope: public_diagnostic_scope(diagnostic.scope, secrets), path: public_generated_path(diagnostic.path, secrets), message: scrub_public_string(diagnostic.message, secrets)}
  end

  defp public_diagnostic_scope(scope, _secrets) when scope in [:registry, :host], do: scope

  defp public_diagnostic_scope({:target, id}, secrets),
    do: {:target, public_target_id(id, secrets)}

  defp public_diagnostic_scope(_scope, _secrets), do: @redaction_marker

  defp scrub_public_string(value, secrets) when is_binary(value) do
    if String.valid?(value), do: scrub_string(value, secrets), else: @redaction_marker
  end

  defp scrub_public_string(_value, _secrets), do: @redaction_marker

  defp public_generated_path(path, secrets) do
    if valid_generated_path?(path) and replace_known_secrets(path, secrets) == path,
      do: path,
      else: @redaction_marker
  end

  defp valid_generated_path?(path)
       when is_binary(path) and byte_size(path) <= @public_path_max_bytes do
    String.valid?(path) and path_segments_valid?(path)
  end

  defp valid_generated_path?(_path), do: false

  defp path_segments_valid?("$"), do: true
  defp path_segments_valid?("$" <> segments), do: path_segments_valid?(segments, "$")
  defp path_segments_valid?(_path), do: false

  defp path_segments_valid?("", _path), do: true

  defp path_segments_valid?(segments, path) do
    case Regex.run(@dot_path_segment_regex, segments) do
      [segment, key] ->
        if safe_path_key?(path, key) do
          path_segments_valid?(remove_path_prefix(segments, segment), path <> segment)
        else
          false
        end

      nil ->
        indexed_or_typed_path_segments_valid?(segments, path)
    end
  end

  defp indexed_or_typed_path_segments_valid?(segments, path) do
    case Regex.run(@indexed_path_segment_regex, segments) ||
           Regex.run(@typed_path_segment_regex, segments) do
      [segment] -> path_segments_valid?(remove_path_prefix(segments, segment), path <> segment)
      nil -> false
    end
  end

  defp remove_path_prefix(value, prefix) do
    binary_part(value, byte_size(prefix), byte_size(value) - byte_size(prefix))
  end

  defp current_generation(nil), do: nil
  defp current_generation(%Snapshot{generation: generation}) when is_binary(generation), do: generation
  defp current_generation(%Snapshot{source_hash: source_hash}), do: source_hash

  defp current_source_generation(%Snapshot{source_hash: source_hash})
       when is_binary(source_hash),
       do: source_hash

  defp current_source_generation(%Snapshot{generation: generation}), do: generation
  defp current_source_generation(nil), do: nil

  defp build_diff(current, proposed, source_diff) do
    current_projection = if is_nil(current), do: %{}, else: snapshot_projection(current)
    proposed_projection = snapshot_projection(proposed)

    (source_diff ++ map_diff("$", current_projection, proposed_projection))
    |> mark_forced_pauses(current, proposed)
    |> Enum.sort_by(& &1.path)
  end

  defp mark_forced_pauses(changes, current, %Snapshot{targets: proposed_targets})
       when is_map(proposed_targets) do
    current_targets = snapshot_targets(current)

    forced_changes =
      current_targets
      |> Map.keys()
      |> Kernel.++(Map.keys(proposed_targets))
      |> Enum.uniq()
      |> Enum.sort_by(&term_order/1)
      |> Enum.with_index()
      |> Enum.flat_map(fn {id, index} ->
        case Map.fetch(proposed_targets, id) do
          {:ok,
           %Target{
             configured_state: :active,
             effective_state: :paused,
             valid?: false
           }} ->
            path = "$.targets" <> path_segment("$.targets", id, index) <> ".effective_state"
            before = target_effective_state(Map.get(current_targets, id))

            [
              %{
                path: path,
                before: before,
                after: :paused,
                semantic_hint: :state,
                classification: :forced_paused
              }
            ]

          _other ->
            []
        end
      end)

    forced_by_path = Map.new(forced_changes, &{&1.path, &1})

    {changes, seen_paths} =
      Enum.map_reduce(changes, MapSet.new(), fn change, seen ->
        case Map.fetch(forced_by_path, change.path) do
          {:ok, forced} -> {forced, MapSet.put(seen, change.path)}
          :error -> {change, seen}
        end
      end)

    missing =
      Enum.reject(forced_changes, &MapSet.member?(seen_paths, &1.path))

    changes ++ missing
  end

  defp mark_forced_pauses(changes, _current, _proposed), do: changes

  defp snapshot_targets(%Snapshot{targets: targets}) when is_map(targets), do: targets
  defp snapshot_targets(_current), do: %{}

  defp target_effective_state(%Target{effective_state: effective_state}), do: effective_state
  defp target_effective_state(_target), do: nil

  defp snapshot_projection(%Snapshot{} = snapshot) do
    %{
      "globally_valid" => public_boolean(snapshot.globally_valid?),
      "host" => snapshot.host,
      "targets" => target_projection_map(snapshot.targets),
      "version" => snapshot.version
    }
  end

  defp target_projection_map(targets) when is_map(targets) do
    Map.new(targets, fn
      {id, %Target{} = target} -> {id, target_projection(target)}
      entry -> entry
    end)
  end

  defp target_projection_map(targets), do: targets

  defp target_projection(%Target{configured: configured} = target) when is_map(configured) do
    configured
    |> put_projected_target_value("state", target.configured_state)
    |> put_projected_target_value("dispatch_mode", target.dispatch_mode)
    |> Map.put("effective_state", target.effective_state)
    |> Map.put("policy_hash", target.policy_hash)
    |> Map.put("valid", target.valid?)
  end

  defp target_projection(%Target{} = target) do
    %{}
    |> put_projected_target_value("state", target.configured_state)
    |> put_projected_target_value("dispatch_mode", target.dispatch_mode)
    |> Map.put("effective_state", target.effective_state)
    |> Map.put("policy_hash", target.policy_hash)
    |> Map.put("valid", target.valid?)
  end

  defp put_projected_target_value(configured, "state", value)
       when value in [:paused, :active, :draining, :retired],
       do: Map.put(configured, "state", Atom.to_string(value))

  defp put_projected_target_value(configured, "dispatch_mode", value)
       when value in [:explicit, :watch],
       do: Map.put(configured, "dispatch_mode", Atom.to_string(value))

  defp put_projected_target_value(configured, key, {:unknown, value}) when is_binary(value),
    do: Map.put(configured, key, value)

  defp put_projected_target_value(configured, key, nil) do
    case Map.fetch(configured, key) do
      :error -> Map.put(configured, key, nil)
      {:ok, nil} -> configured
      {:ok, _malformed} -> configured
    end
  end

  defp put_projected_target_value(configured, _key, _malformed), do: configured

  defp map_diff(path, before, proposed, sensitive? \\ false)

  defp map_diff(path, before, proposed, sensitive?)
       when is_map(before) and is_map(proposed) do
    before
    |> Map.keys()
    |> Kernel.++(Map.keys(proposed))
    |> Enum.uniq()
    |> Enum.sort_by(&term_order/1)
    |> Enum.with_index()
    |> Enum.flat_map(fn {key, index} ->
      nested_path = path <> path_segment(path, key, index)
      before_value = Map.fetch(before, key)
      proposed_value = Map.fetch(proposed, key)
      key_sensitive? = sensitive? or sensitive_key?(key) or not preview_known_key?(path, key)
      semantic_hint = map_semantic_hint(path, key, before_value, proposed_value)

      value_diff(
        nested_path,
        before_value,
        proposed_value,
        key_sensitive?,
        semantic_hint
      )
    end)
  end

  defp value_diff(_path, {:ok, value}, {:ok, value}, _sensitive?, _semantic_hint), do: []

  defp value_diff(path, {:ok, before}, {:ok, proposed}, sensitive?, _semantic_hint)
       when is_map(before) and is_map(proposed),
       do: map_diff(path, before, proposed, sensitive?)

  defp value_diff(path, :error, {:ok, proposed}, sensitive?, semantic_hint)
       when is_map(proposed) and map_size(proposed) == 0,
       do: value_change(path, :error, {:ok, proposed}, sensitive?, semantic_hint)

  defp value_diff(path, {:ok, before}, :error, sensitive?, semantic_hint)
       when is_map(before) and map_size(before) == 0,
       do: value_change(path, {:ok, before}, :error, sensitive?, semantic_hint)

  defp value_diff(path, :error, {:ok, proposed}, sensitive?, _semantic_hint)
       when is_map(proposed),
       do: map_diff(path, %{}, proposed, sensitive?)

  defp value_diff(path, {:ok, before}, :error, sensitive?, _semantic_hint)
       when is_map(before),
       do: map_diff(path, before, %{}, sensitive?)

  defp value_diff(path, before, proposed, sensitive?, semantic_hint),
    do: value_change(path, before, proposed, sensitive?, semantic_hint)

  defp value_change(path, before, proposed, sensitive?, semantic_hint) do
    {before_present?, before_value} = fetched_value(before)
    {proposed_present?, proposed_value} = fetched_value(proposed)

    [
      %{
        path: path,
        before: before_value,
        after: proposed_value,
        before_present?: before_present?,
        after_present?: proposed_present?,
        sensitive?: sensitive?,
        semantic_hint: semantic_hint,
        classification:
          change_classification(
            path,
            before_present?,
            before_value,
            proposed_present?,
            proposed_value,
            semantic_hint
          )
      }
    ]
  end

  defp fetched_value({:ok, value}), do: {true, value}
  defp fetched_value(:error), do: {false, nil}

  defp change_classification(path, true, before, true, proposed, semantic_hint) do
    semantic_classification(path, semantic_hint, before, proposed) || :changed
  end

  defp change_classification(path, false, _before, true, proposed, _semantic_hint) do
    gate_change_classification(path, "deny", proposed) || :added
  end

  defp change_classification(path, true, before, false, _proposed, _semantic_hint) do
    gate_change_classification(path, before, "deny") || :removed
  end

  defp gate_change_classification(path, before, proposed) do
    if gate_path?(path) do
      rank_classification(gate_rank(before), gate_rank(proposed))
    end
  end

  defp semantic_classification(path, semantic_hint, before, proposed) do
    path
    |> semantic_category(semantic_hint)
    |> classify_semantic_change(before, proposed)
  end

  defp semantic_category(path, semantic_hint),
    do: semantic_hint || scalar_semantic_category(path) || set_semantic_category(path) || :unknown

  defp map_semantic_hint(path, key, {:ok, before}, {:ok, proposed}) do
    if target_by_linear_state_path?(path) and valid_linear_state_name?(key) and
         positive_integer?(before) and positive_integer?(proposed) do
      :capacity
    end
  end

  defp map_semantic_hint(_path, _key, _before, _proposed), do: nil

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp scalar_semantic_category(path) do
    cond do
      capacity_path?(path) -> :capacity
      budget_path?(path) -> :budget
      state_path?(path) -> :state
      dispatch_path?(path) -> :dispatch_mode
      gate_path?(path) -> :gate
      true -> nil
    end
  end

  defp set_semantic_category(path) do
    cond do
      runner_set_path?(path) -> :runner_set
      required_label_set_path?(path) -> :required_label_set
      check_set_path?(path) -> :check_set
      true -> nil
    end
  end

  defp classify_semantic_change(category, before, proposed)
       when category in [:capacity, :budget] and
              is_integer(before) and before > 0 and
              is_integer(proposed) and proposed > 0,
       do: ordered_classification(before, proposed)

  defp classify_semantic_change(:state, before, proposed),
    do: rank_classification(state_rank(before), state_rank(proposed))

  defp classify_semantic_change(:dispatch_mode, before, proposed),
    do: rank_classification(dispatch_rank(before), dispatch_rank(proposed))

  defp classify_semantic_change(:gate, before, proposed),
    do: rank_classification(gate_rank(before), gate_rank(proposed))

  defp classify_semantic_change(:runner_set, before, proposed),
    do: set_classification(before, proposed, :narrower_restricts, :runner)

  defp classify_semantic_change(:required_label_set, before, proposed),
    do: set_classification(before, proposed, :broader_restricts, :required_label)

  defp classify_semantic_change(:check_set, before, proposed),
    do: set_classification(before, proposed, :broader_restricts, :check)

  defp classify_semantic_change(_category, _before, _proposed), do: nil

  defp ordered_classification(before, proposed) when proposed < before, do: :restricted
  defp ordered_classification(before, proposed) when proposed > before, do: :broadened
  defp ordered_classification(_before, _proposed), do: nil

  defp rank_classification(nil, _proposed), do: nil
  defp rank_classification(_before, nil), do: nil
  defp rank_classification(before, proposed), do: ordered_classification(before, proposed)

  defp state_rank(state) when state in [:retired, "retired"], do: 0
  defp state_rank(state) when state in [:paused, "paused"], do: 1
  defp state_rank(state) when state in [:draining, "draining"], do: 2
  defp state_rank(state) when state in [:active, "active"], do: 3
  defp state_rank(_state), do: nil

  defp dispatch_rank(mode) when mode in [nil], do: 0
  defp dispatch_rank(mode) when mode in [:explicit, "explicit"], do: 1
  defp dispatch_rank(mode) when mode in [:watch, "watch"], do: 2
  defp dispatch_rank(_mode), do: nil

  defp gate_rank(gate) when gate in [:deny, "deny"], do: 0
  defp gate_rank(gate) when gate in [:manual_approval, "manual_approval"], do: 1
  defp gate_rank(gate) when gate in [:allow, "allow"], do: 2
  defp gate_rank(_gate), do: nil

  defp set_classification(before, proposed, direction, category) do
    with {:ok, before_set} <- semantic_set(before, category),
         {:ok, proposed_set} <- semantic_set(proposed, category) do
      cond do
        MapSet.subset?(proposed_set, before_set) and before_set != proposed_set ->
          set_direction(direction, :narrower)

        MapSet.subset?(before_set, proposed_set) and before_set != proposed_set ->
          set_direction(direction, :broader)

        true ->
          nil
      end
    else
      :error -> nil
    end
  end

  defp semantic_set(values, category) when is_list(values) do
    if Enum.all?(values, &valid_set_value?(&1, category)) do
      normalized = Enum.map(values, &normalize_set_value(&1, category))

      if length(normalized) == length(Enum.uniq(normalized)) do
        {:ok, MapSet.new(normalized)}
      else
        :error
      end
    else
      :error
    end
  end

  defp semantic_set(_values, _category), do: :error

  defp valid_set_value?(value, :runner) when is_binary(value),
    do: String.valid?(value) and Regex.match?(@safe_dynamic_key_regex, value)

  defp valid_set_value?(value, :required_label) when is_binary(value),
    do: String.valid?(value) and String.trim(value) != ""

  defp valid_set_value?(value, :check) when is_binary(value), do: value in @check_ids
  defp valid_set_value?(_value, _category), do: false

  defp normalize_set_value(value, :required_label),
    do: value |> String.trim() |> String.downcase()

  defp normalize_set_value(value, _category), do: value

  defp set_direction(:narrower_restricts, :narrower), do: :restricted
  defp set_direction(:narrower_restricts, :broader), do: :broadened
  defp set_direction(:broader_restricts, :narrower), do: :broadened
  defp set_direction(:broader_restricts, :broader), do: :restricted

  defp build_impact(diff) do
    categorized =
      Map.new(@impact_categories, fn category ->
        changes = Enum.filter(diff, &(change_category(&1) == category))
        {category, %{classification: aggregate_impact(changes), changes: changes}}
      end)

    overall =
      categorized
      |> Map.values()
      |> Enum.map(& &1.classification)
      |> aggregate_classifications()

    categorized
    |> Map.put(:overall, overall)
    |> Map.put(:runtime, %{
      host_dispatch: :unavailable_in_phase_1,
      legacy_single_target: :unchanged
    })
  end

  defp aggregate_impact(changes) do
    changes
    |> Enum.map(&impact_classification/1)
    |> aggregate_classifications()
  end

  defp impact_classification(
         %{
           path: path,
           classification: classification
         } = change
       )
       when is_binary(path) do
    if gate_path?(path) do
      gate_impact_classification(change)
    else
      classification
    end
  end

  defp gate_impact_classification(%{
         before_present?: before_present?,
         before: before,
         after_present?: after_present?,
         after: proposed
       }) do
    before_rank = effective_gate_rank(before_present?, before)
    proposed_rank = effective_gate_rank(after_present?, proposed)

    if is_integer(before_rank) and is_integer(proposed_rank) do
      rank_classification(before_rank, proposed_rank) || :unchanged
    else
      :unknown
    end
  end

  defp effective_gate_rank(false, _gate), do: gate_rank("deny")
  defp effective_gate_rank(true, gate), do: gate_rank(gate)

  defp aggregate_classifications(classifications) do
    classifications =
      classifications
      |> Enum.reject(&(&1 in [:unchanged, :source_difference]))
      |> Enum.map(fn
        classification
        when classification in [:restricted, :broadened, :mixed, :forced_paused] ->
          classification

        _conservative ->
          :unknown
      end)
      |> MapSet.new()

    cond do
      MapSet.size(classifications) == 0 -> :unchanged
      MapSet.member?(classifications, :forced_paused) -> :forced_paused
      MapSet.member?(classifications, :unknown) -> :unknown
      MapSet.size(classifications) > 1 -> :mixed
      true -> classifications |> MapSet.to_list() |> hd()
    end
  end

  defp public_impact(impact) do
    Enum.reduce(@impact_categories, impact, fn category, public ->
      changes = Enum.map(impact[category].changes, &public_change/1)
      put_in(public, [category, :changes], changes)
    end)
  end

  defp public_change(change),
    do:
      Map.drop(change, [
        :before_present?,
        :after_present?,
        :sensitive?,
        :semantic_hint
      ])

  defp change_category(%{semantic_hint: :capacity}), do: :capacity
  defp change_category(%{semantic_hint: :state}), do: :state
  defp change_category(%{path: path}), do: path_category(path)

  defp path_category("$.generation"), do: nil

  defp path_category(path) do
    primary_path_category(path) || secondary_path_category(path)
  end

  defp primary_path_category(path) do
    cond do
      dispatch_path?(path) -> :dispatch_mode
      state_path?(path) -> :state
      target_valid_path?(path) -> :state
      capacity_path?(path) -> :capacity
      budget_path?(path) -> :budgets
      true -> nil
    end
  end

  defp secondary_path_category(path) do
    cond do
      String.contains?(path, ".runners") -> :runners
      String.contains?(path, ".checks.") -> :checks
      gate_path?(path) -> :external_side_effects
      true -> :scope
    end
  end

  defp runner_set_path?(path), do: Regex.match?(@runner_set_path_regex, path)

  defp required_label_set_path?(path), do: Regex.match?(@required_label_set_path_regex, path)

  defp check_set_path?(path), do: Regex.match?(@check_set_path_regex, path)

  defp gate_path?(path), do: Regex.match?(@target_gate_path_regex, path)
  defp budget_path?(path), do: Regex.match?(@budget_path_regex, path)
  defp capacity_path?(path), do: Regex.match?(@capacity_path_regex, path)
  defp state_path?(path), do: Regex.match?(@target_state_path_regex, path)
  defp dispatch_path?(path), do: Regex.match?(@target_dispatch_path_regex, path)
  defp target_valid_path?(path), do: Regex.match?(@target_valid_path_regex, path)

  defp target_by_linear_state_path?(path),
    do: Regex.match?(@target_by_linear_state_path_regex, path)

  defp valid_linear_state_name?(key) when is_binary(key),
    do: String.valid?(key) and String.trim(key) != ""

  defp valid_linear_state_name?(_key), do: false

  defp path_segment(path, key, index) when is_binary(key) do
    if safe_path_key?(path, key) do
      "." <> key
    else
      "[key:#{index}:string]"
    end
  end

  defp path_segment(_path, key, index), do: "[key:#{index}:#{key_type(key)}]"

  defp safe_path_key?(path, key) do
    key in @safe_path_keys or
      (dynamic_path?(path) and Regex.match?(@safe_dynamic_key_regex, key))
  end

  defp dynamic_path?(path) do
    Enum.any?(@dynamic_path_suffixes, fn
      "$.targets" -> path == "$.targets"
      suffix -> String.ends_with?(path, suffix)
    end)
  end

  defp key_type(key) when is_atom(key), do: "atom"
  defp key_type(key) when is_binary(key), do: "string"
  defp key_type(key) when is_integer(key), do: "integer"
  defp key_type(key) when is_float(key), do: "float"
  defp key_type(key) when is_tuple(key), do: "tuple"
  defp key_type(key) when is_map(key), do: "map"
  defp key_type(key) when is_list(key), do: "list"
  defp key_type(_key), do: "term"

  defp term_order(term), do: :erlang.term_to_binary(term, [:deterministic])

  defp target_summaries(targets) when is_map(targets) do
    targets
    |> Enum.flat_map(fn
      {_id, %Target{} = target} ->
        [
          %{
            id: target.id,
            configured_state: target.configured_state,
            effective_state: target.effective_state,
            dispatch_mode: target.dispatch_mode,
            valid?: target.valid?,
            policy_hash: target.policy_hash
          }
        ]

      _malformed ->
        []
    end)
    |> Enum.sort_by(&summary_order/1)
  end

  defp target_summaries(_targets), do: []
  defp summary_order(%{id: id}) when is_binary(id), do: {0, id}
  defp summary_order(%{id: id}), do: {1, term_order(id)}

  @spec redact(term()) :: term()
  def redact(value), do: redact_with_secrets(value, secret_values(value))

  defp secret_values(value) do
    {secrets, _remaining} =
      collect_secrets(
        value,
        false,
        @redaction_max_depth,
        @redaction_max_nodes,
        MapSet.new()
      )

    sort_secrets(secrets)
  end

  defp preview_secret_values(value) do
    {secrets, _remaining} =
      collect_preview_secrets(
        value,
        "$",
        false,
        @redaction_max_depth,
        @redaction_max_nodes,
        MapSet.new()
      )

    sort_secrets(secrets)
  end

  defp sort_secrets(secrets) do
    secrets
    |> MapSet.to_list()
    |> Enum.sort_by(&{-byte_size(&1), &1})
  end

  defp collect_preview_secrets(_value, _path, _sensitive?, _depth, remaining, secrets)
       when remaining <= 0,
       do: {secrets, 0}

  defp collect_preview_secrets(_value, _path, _sensitive?, depth, remaining, secrets)
       when depth <= 0,
       do: {secrets, remaining - 1}

  defp collect_preview_secrets(value, _path, true, _depth, remaining, secrets)
       when is_binary(value) and byte_size(value) > 0,
       do: {MapSet.put(secrets, value), remaining - 1}

  defp collect_preview_secrets(
         %Diagnostic{message: message},
         path,
         _sensitive?,
         depth,
         remaining,
         secrets
       ),
       do: collect_preview_secrets(message, path, false, depth - 1, remaining - 1, secrets)

  defp collect_preview_secrets(value, path, sensitive?, depth, remaining, secrets)
       when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _nested} -> term_order(key) end)
    |> Enum.with_index()
    |> Enum.reduce({secrets, remaining - 1}, fn
      _entry, {collected, left} when left <= 0 ->
        {collected, 0}

      {{key, nested}, index}, {collected, left} ->
        key_sensitive? = sensitive? or sensitive_key?(key) or not preview_known_key?(path, key)
        nested_path = path <> path_segment(path, key, index)

        collect_preview_secrets(
          nested,
          nested_path,
          key_sensitive?,
          depth - 1,
          left,
          collected
        )
    end)
  end

  defp collect_preview_secrets(value, path, sensitive?, depth, remaining, secrets)
       when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> collect_preview_secrets(path, sensitive?, depth - 1, remaining - 1, secrets)
  end

  defp collect_preview_secrets([], _path, _sensitive?, _depth, remaining, secrets),
    do: {secrets, remaining - 1}

  defp collect_preview_secrets([head | tail], path, sensitive?, depth, remaining, secrets) do
    {secrets, remaining} =
      collect_preview_secrets(head, path, sensitive?, depth - 1, remaining - 1, secrets)

    collect_preview_secrets(tail, path, sensitive?, depth - 1, remaining, secrets)
  end

  defp collect_preview_secrets(_value, _path, _sensitive?, _depth, remaining, secrets),
    do: {secrets, remaining - 1}

  defp preview_known_key?(path, key) when is_binary(key) do
    String.valid?(key) and
      (safe_path_key?(path, key) or
         (target_by_linear_state_path?(path) and valid_linear_state_name?(key)))
  end

  defp preview_known_key?(_path, _key), do: false

  defp redact_with_secrets(value, secrets) do
    {redacted, _remaining} =
      redact_term(
        value,
        false,
        secrets,
        @redaction_max_depth,
        @redaction_max_nodes
      )

    redacted
  end

  defp collect_secrets(_value, _sensitive?, _depth, remaining, secrets)
       when remaining <= 0,
       do: {secrets, 0}

  defp collect_secrets(_value, _sensitive?, depth, remaining, secrets)
       when depth <= 0,
       do: {secrets, remaining - 1}

  defp collect_secrets(value, true, _depth, remaining, secrets)
       when is_binary(value) and byte_size(value) > 0 do
    {MapSet.put(secrets, value), remaining - 1}
  end

  defp collect_secrets(%Diagnostic{message: message}, _sensitive?, depth, remaining, secrets) do
    collect_secrets(message, false, depth - 1, remaining - 1, secrets)
  end

  defp collect_secrets(value, sensitive?, depth, remaining, secrets) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _nested} -> term_order(key) end)
    |> Enum.reduce({secrets, remaining - 1}, fn
      _entry, {collected, left} when left <= 0 ->
        {collected, 0}

      {key, nested}, {collected, left} ->
        collect_secrets(
          nested,
          sensitive? or sensitive_map_value?(key),
          depth - 1,
          left,
          collected
        )
    end)
  end

  defp collect_secrets(value, sensitive?, depth, remaining, secrets) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> collect_secrets(sensitive?, depth - 1, remaining - 1, secrets)
  end

  defp collect_secrets([], _sensitive?, _depth, remaining, secrets),
    do: {secrets, remaining - 1}

  defp collect_secrets([head | tail], sensitive?, depth, remaining, secrets) do
    {secrets, remaining} =
      collect_secrets(head, sensitive?, depth - 1, remaining - 1, secrets)

    collect_secrets(tail, sensitive?, depth - 1, remaining, secrets)
  end

  defp collect_secrets(_value, _sensitive?, _depth, remaining, secrets),
    do: {secrets, remaining - 1}

  defp redact_term(_value, _sensitive?, _secrets, _depth, remaining) when remaining <= 0,
    do: {@redaction_marker, 0}

  defp redact_term(_value, _sensitive?, _secrets, depth, remaining) when depth <= 0,
    do: {@redaction_marker, remaining - 1}

  defp redact_term(%Diagnostic{} = diagnostic, _sensitive?, secrets, _depth, remaining) do
    {redact_diagnostic(diagnostic, secrets), remaining - 1}
  end

  defp redact_term(value, sensitive?, secrets, _depth, remaining) when is_binary(value) do
    redacted =
      cond do
        sensitive? -> @redaction_marker
        not String.valid?(value) -> @redaction_marker
        true -> scrub_string(value, secrets)
      end

    {redacted, remaining - 1}
  end

  defp redact_term(value, sensitive?, secrets, depth, remaining) when is_map(value) do
    {entries, remaining} =
      value
      |> Enum.sort_by(fn {key, _nested} -> term_order(key) end)
      |> Enum.with_index()
      |> Enum.reduce({[], remaining - 1}, fn
        _entry, {redacted, left} when left <= 0 ->
          {redacted, 0}

        {{key, nested}, index}, {redacted, left} ->
          safe_key? = safe_redacted_key?(key)

          {nested, left} =
            redact_term(
              nested,
              sensitive? or sensitive_map_value?(key),
              secrets,
              depth - 1,
              left
            )

          key = if safe_key?, do: key, else: "<key:#{index}:#{key_type(key)}>"
          {[{key, nested} | redacted], left}
      end)

    {Map.new(Enum.reverse(entries)), remaining}
  end

  defp redact_term(value, sensitive?, secrets, depth, remaining) when is_tuple(value) do
    {items, remaining} =
      value
      |> Tuple.to_list()
      |> redact_term(sensitive?, secrets, depth - 1, remaining - 1)

    if is_list(items) do
      {List.to_tuple(items), remaining}
    else
      {@redaction_marker, remaining}
    end
  end

  defp redact_term([], _sensitive?, _secrets, _depth, remaining), do: {[], remaining - 1}

  defp redact_term([head | tail], sensitive?, secrets, depth, remaining) do
    {head, remaining} =
      redact_term(head, sensitive?, secrets, depth - 1, remaining - 1)

    {tail, remaining} =
      redact_term(tail, sensitive?, secrets, depth - 1, remaining)

    {[head | tail], remaining}
  end

  defp redact_term(_value, true, _secrets, _depth, remaining),
    do: {@redaction_marker, remaining - 1}

  defp redact_term(value, false, _secrets, _depth, remaining), do: {value, remaining - 1}

  defp safe_redacted_key?(key) when is_binary(key),
    do: String.valid?(key) and key in @safe_redacted_keys

  defp safe_redacted_key?(key) when is_atom(key),
    do: key |> Atom.to_string() |> safe_redacted_key?()

  defp safe_redacted_key?(_key), do: false

  defp sensitive_map_value?(key),
    do: sensitive_key?(key) or not safe_redacted_key?(key) or path_key?(key)

  defp path_key?(:path), do: true
  defp path_key?("path"), do: true
  defp path_key?(_key), do: false

  defp sensitive_key?(key) when is_binary(key),
    do:
      String.valid?(key) and key != "max_total_tokens" and
        Regex.match?(@sensitive_key_regex, key)

  defp sensitive_key?(key) when is_atom(key), do: key |> Atom.to_string() |> sensitive_key?()
  defp sensitive_key?(_key), do: false

  defp scrub_string(value, secrets) do
    value = replace_known_secrets(value, secrets)
    value = Regex.replace(@private_key_regex, value, @redaction_marker)
    value = Regex.replace(@uri_userinfo_regex, value, "\\1#{@redaction_marker}@")
    value = scrub_uri_secrets(value, secrets)
    value = Regex.replace(@authorization_assignment_regex, value, "\\1#{@redaction_marker}")
    value = Regex.replace(@authorization_regex, value, "\\1 #{@redaction_marker}")
    value = Regex.replace(@secret_assignment_regex, value, "\\1#{@redaction_marker}")
    value = Regex.replace(@secret_token_regex, value, @redaction_marker)
    Regex.replace(@resolved_env_regex, value, @redaction_marker)
  end

  defp replace_known_secrets(value, secrets) do
    Enum.reduce(secrets, value, fn secret, redacted ->
      if byte_size(secret) >= 4 or not String.valid?(secret) do
        String.replace(redacted, secret, @redaction_marker)
      else
        redacted
      end
    end)
  end

  defp scrub_uri_secrets(value, secrets) do
    Regex.replace(@uri_regex, value, &scrub_uri(&1, secrets))
  end

  defp scrub_uri(value, secrets) do
    uri = URI.parse(value)

    %{
      uri
      | query: scrub_uri_parameters(uri.query, secrets),
        fragment: scrub_uri_parameters(uri.fragment, secrets)
    }
    |> URI.to_string()
  end

  defp scrub_uri_parameters(nil, _secrets), do: nil

  defp scrub_uri_parameters(parameters, secrets) do
    parameters
    |> String.split("&")
    |> Enum.map_join("&", fn parameter ->
      case String.split(parameter, "=", parts: 2) do
        [encoded_key, encoded_value] ->
          scrub_uri_parameter(encoded_key, encoded_value, parameter, secrets)

        [encoded_key] ->
          scrub_uri_parameter(encoded_key, parameter)
      end
    end)
  end

  defp scrub_uri_parameter(encoded_key, encoded_value, parameter, secrets) do
    key = decode_www_form(encoded_key)
    value = decode_www_form(encoded_value)

    if sensitive_key?(key) or sensitive_assignment?(value) or
         replace_known_secrets(value, secrets) != value do
      encoded_key <> "=" <> @redaction_marker
    else
      parameter
    end
  end

  defp scrub_uri_parameter(encoded_key, parameter) do
    if encoded_key |> decode_www_form() |> sensitive_key?(),
      do: @redaction_marker,
      else: parameter
  end

  defp sensitive_assignment?(value) do
    Regex.match?(@secret_assignment_regex, value) or
      Regex.match?(@authorization_assignment_regex, value)
  end

  defp decode_www_form(value), do: URI.decode_www_form(value)

  @spec generation(binary()) :: SymphonyElixir.TargetRegistry.generation()
  def generation(source) when is_binary(source) do
    digest = :crypto.hash(:sha256, source)
    "sha256:" <> Base.encode16(digest, case: :lower)
  end
end
