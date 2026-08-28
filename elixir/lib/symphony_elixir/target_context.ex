defmodule SymphonyElixir.TargetContext do
  @moduledoc false

  alias SymphonyElixir.Linear.Issue
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
  @issue_restrictive_flags [:human_review_only, :no_land, :require_review, :require_validation]
  @issue_weakening_flags [:allow_missing_capabilities, :auto_land, :ignore_markers, :skip_review, :skip_validation]

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
  defstruct @enforce_keys ++ [issue_policy_authority: nil, workspace_layout: :target_scoped]

  @type state :: :paused | :active | :draining | :retired
  @type dispatch_mode :: :explicit | :watch | nil
  @type workspace_layout :: :flat | :target_scoped
  @type t :: %__MODULE__{
          target_id: String.t(),
          state: state(),
          dispatch_mode: dispatch_mode(),
          registry_generation: TargetRegistry.generation(),
          policy_hash: TargetRegistry.generation(),
          repo_manifest_hash: TargetRegistry.generation(),
          issue_policy_authority: map() | nil,
          repo_policy: map(),
          tracker_connection: map(),
          run_target: map(),
          worktree_policy: map(),
          workspace_layout: workspace_layout(),
          runner_policy: map(),
          effective_checks: map(),
          external_side_effect_gates: map(),
          capacity_limits: map(),
          budget_limits: map()
        }

  @spec from_registry(Snapshot.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, atom()}
  def from_registry(snapshot, target_id, opts \\ []),
    do: build_context(snapshot, target_id, opts, :resolved)

  @doc """
  Builds a validated target context that retains credential references.

  The returned context is safe to persist but must not be used for tracker or
  runner I/O until a fenced owner resolves its current credentials.
  """
  @spec pin_from_registry(Snapshot.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def pin_from_registry(snapshot, target_id),
    do: build_context(snapshot, target_id, [], :pinned)

  @type issue_policy_error ::
          :forbidden_policy_broadening
          | :invalid_issue_policy_options
          | :malformed_composed_policy
          | :malformed_issue_metadata
          | :unknown_profile

  @spec issue_policy(t(), Issue.t(), keyword()) ::
          {:ok, map()} | {:error, issue_policy_error()}
  def issue_policy(%__MODULE__{} = context, %Issue{} = issue, opts) do
    with {:ok, profile, restrictive_flags} <- issue_policy_options(opts),
         {:ok, issue} <- normalize_issue_metadata(issue),
         {:ok, manifest} <- issue_policy_manifest(context),
         :ok <- validate_issue_policy_context(context),
         :ok <- validate_issue_scope(manifest, context.run_target, issue),
         {:ok, policy} <- issue_policy_base(context, manifest, profile),
         :ok <- validate_issue_restriction_fields(policy),
         policy <- apply_issue_restrictions(policy, context, restrictive_flags),
         {:ok, policy_ref} <- issue_policy_ref(policy) do
      {:ok,
       policy
       |> Map.put("policy_ref", policy_ref)
       |> Map.put("policy_metadata", issue_policy_metadata(issue, profile))}
    end
  end

  def issue_policy(%__MODULE__{}, _issue, _opts), do: {:error, :malformed_issue_metadata}
  def issue_policy(_context, _issue, _opts), do: {:error, :malformed_composed_policy}

  defp issue_policy_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)
      profile = Keyword.get(opts, :profile, "default")
      flags = Keyword.get(opts, :restrictive_flags, [])

      with :ok <- validate_issue_policy_option_keys(keys),
           {:ok, profile} <- normalize_issue_policy_profile(profile),
           :ok <- validate_issue_policy_flags(flags) do
        {:ok, profile, flags}
      end
    else
      {:error, :invalid_issue_policy_options}
    end
  end

  defp issue_policy_options(_opts), do: {:error, :invalid_issue_policy_options}

  defp validate_issue_policy_option_keys(keys) do
    if Enum.any?(keys, &(&1 not in [:profile, :restrictive_flags])) or
         length(keys) != length(Enum.uniq(keys)),
       do: {:error, :invalid_issue_policy_options},
       else: :ok
  end

  defp normalize_issue_policy_profile(profile) do
    if nonblank_string?(profile),
      do: {:ok, String.trim(profile)},
      else: {:error, :invalid_issue_policy_options}
  end

  defp validate_issue_policy_flags(flags) when is_list(flags) do
    cond do
      not proper_list?(flags) ->
        {:error, :invalid_issue_policy_options}

      Enum.any?(flags, &(&1 in @issue_weakening_flags)) ->
        {:error, :forbidden_policy_broadening}

      length(flags) != length(Enum.uniq(flags)) ->
        {:error, :invalid_issue_policy_options}

      Enum.all?(flags, &(&1 in @issue_restrictive_flags)) ->
        :ok

      true ->
        {:error, :invalid_issue_policy_options}
    end
  end

  defp validate_issue_policy_flags(_flags), do: {:error, :invalid_issue_policy_options}

  defp normalize_issue_metadata(
         %Issue{
           identifier: identifier,
           project_id: project_id,
           project_slug: project_slug,
           team_key: team_key,
           labels: labels,
           state: state
         } = issue
       ) do
    with true <-
           optional_nonblank_string?(identifier) and optional_nonblank_string?(project_id) and
             optional_nonblank_string?(project_slug) and optional_nonblank_string?(team_key) and
             optional_nonblank_string?(state),
         {:ok, labels} <- normalize_issue_labels(labels) do
      {:ok,
       %{
         issue
         | identifier: normalized_optional_string(identifier),
           project_id: normalized_optional_string(project_id),
           project_slug: normalized_optional_downcase(project_slug),
           team_key: normalized_optional_downcase(team_key),
           labels: labels,
           state: normalized_optional_downcase(state)
       }}
    else
      _invalid -> {:error, :malformed_issue_metadata}
    end
  end

  defp normalize_issue_labels(labels) when is_list(labels) do
    if proper_list?(labels) and Enum.all?(labels, &nonblank_string?/1) do
      {:ok,
       labels
       |> Enum.map(&(String.trim(&1) |> String.downcase()))
       |> Enum.uniq()
       |> Enum.sort()}
    else
      {:error, :malformed_issue_metadata}
    end
  end

  defp normalize_issue_labels(_labels), do: {:error, :malformed_issue_metadata}

  defp issue_policy_manifest(%__MODULE__{
         repo_policy:
           %{
             "manifest" => manifest,
             "manifest_source_dir" => source_dir,
             "workflow_module_resolution" => module_resolution
           } = repo_policy
       })
       when is_map(manifest) and is_map(module_resolution) do
    if Enum.sort(Map.keys(repo_policy)) ==
         ["manifest", "manifest_source_dir", "workflow_module_resolution"] and
         valid_manifest_source_dir?(source_dir) do
      {:ok, manifest}
    else
      {:error, :malformed_composed_policy}
    end
  end

  defp issue_policy_manifest(_context), do: {:error, :malformed_composed_policy}

  defp validate_issue_policy_context(context) do
    values = [
      context.repo_policy,
      context.run_target,
      context.worktree_policy,
      context.runner_policy,
      context.effective_checks,
      context.external_side_effect_gates,
      context.capacity_limits,
      context.budget_limits
    ]

    if Enum.all?(values, &(is_map(&1) and json_safe_policy_value?(&1))),
      do: :ok,
      else: {:error, :malformed_composed_policy}
  end

  defp validate_issue_scope(manifest, run_target, issue) do
    with :ok <- validate_target_scope(run_target, issue),
         :ok <- validate_required_labels(run_target, issue.labels),
         :ok <- validate_repository_issue_markers(manifest, issue) do
      validate_active_state(run_target, issue.state)
    end
  end

  defp validate_target_scope(%{"scope" => scope}, issue) when is_map(scope) do
    case Map.get(scope, "type") do
      "issues" -> validate_issue_identity(scope, issue)
      "team" -> validate_team_identity(scope, issue)
      "project" -> validate_project_identity(scope, issue)
      _unsupported_or_missing -> {:error, :malformed_composed_policy}
    end
  end

  defp validate_target_scope(%{"scope" => _invalid_scope}, _issue),
    do: {:error, :malformed_composed_policy}

  defp validate_target_scope(run_target, issue) when is_map(run_target) do
    scope =
      run_target
      |> Map.take(["type", "project_id", "project_slug", "team_key", "issue_ids"])
      |> then(fn scope ->
        if Map.get(scope, "issue_ids") == [], do: Map.delete(scope, "issue_ids"), else: scope
      end)

    case Map.get(scope, "type") do
      "issues" -> validate_issue_identity(scope, issue)
      "team" -> validate_team_identity(scope, issue)
      "project" -> validate_project_identity(scope, issue)
      nil -> validate_inferred_target_scope(scope, issue)
      _unsupported -> {:error, :malformed_composed_policy}
    end
  end

  defp validate_project_identity(scope, issue) do
    keys = Enum.sort(Map.keys(scope))

    with true <-
           keys in [
             ["project_id", "type"],
             ["project_slug", "type"],
             ["project_id", "project_slug", "type"]
           ],
         {:ok, expected_id} <- composed_optional_string(scope, "project_id"),
         {:ok, expected_slug} <- composed_optional_string(scope, "project_slug"),
         true <- not is_nil(expected_id) or not is_nil(expected_slug) do
      cond do
        expected_id && expected_id != normalized_optional_string(issue.project_id) ->
          {:error, :forbidden_policy_broadening}

        expected_slug && String.downcase(expected_slug) != normalized_downcase(issue.project_slug) ->
          {:error, :forbidden_policy_broadening}

        true ->
          :ok
      end
    else
      false -> {:error, :malformed_composed_policy}
      {:error, _reason} = error -> error
    end
  end

  defp validate_issue_identity(scope, issue) do
    issue_ids = Map.get(scope, "issue_ids")

    cond do
      Enum.sort(Map.keys(scope)) != ["issue_ids", "type"] or issue_ids == [] or
          not string_list?(issue_ids) ->
        {:error, :malformed_composed_policy}

      not nonblank_string?(issue.identifier) ->
        {:error, :malformed_issue_metadata}

      normalized_optional_string(issue.identifier) in Enum.map(issue_ids, &String.trim/1) ->
        :ok

      true ->
        {:error, :forbidden_policy_broadening}
    end
  end

  defp validate_team_identity(scope, issue) do
    expected_team = Map.get(scope, "team_key")

    cond do
      Enum.sort(Map.keys(scope)) != ["team_key", "type"] or
          not nonblank_string?(expected_team) ->
        {:error, :malformed_composed_policy}

      not nonblank_string?(issue.team_key) ->
        {:error, :malformed_issue_metadata}

      normalized_downcase(expected_team) == normalized_downcase(issue.team_key) ->
        :ok

      true ->
        {:error, :forbidden_policy_broadening}
    end
  end

  defp validate_inferred_target_scope(scope, issue) do
    cond do
      Map.has_key?(scope, "issue_ids") ->
        scope |> Map.put("type", "issues") |> validate_issue_identity(issue)

      Map.has_key?(scope, "project_id") or Map.has_key?(scope, "project_slug") ->
        scope |> Map.put("type", "project") |> validate_project_identity(issue)

      Map.has_key?(scope, "team_key") ->
        scope |> Map.put("type", "team") |> validate_team_identity(issue)

      true ->
        {:error, :malformed_composed_policy}
    end
  end

  defp validate_required_labels(run_target, issue_labels) do
    validate_required_label_values(Map.get(run_target, "required_labels", []), issue_labels)
  end

  defp validate_repository_issue_markers(%{"issue_markers" => markers}, issue) when is_map(markers) do
    if Enum.sort(Map.keys(markers)) == ["allowed_projects", "labels"] do
      with :ok <- validate_required_label_values(markers["labels"], issue.labels) do
        validate_allowed_projects(markers["allowed_projects"], issue)
      end
    else
      {:error, :malformed_composed_policy}
    end
  end

  defp validate_repository_issue_markers(_manifest, _issue),
    do: {:error, :malformed_composed_policy}

  defp validate_required_label_values(required, issue_labels) do
    if string_list?(required) and proper_list?(required) do
      issue_label_set = MapSet.new(issue_labels)

      if Enum.all?(required, &MapSet.member?(issue_label_set, normalized_downcase(&1))),
        do: :ok,
        else: {:error, :forbidden_policy_broadening}
    else
      {:error, :malformed_composed_policy}
    end
  end

  defp validate_allowed_projects([], _issue), do: :ok

  defp validate_allowed_projects(allowed_projects, issue) when is_list(allowed_projects) do
    if string_list?(allowed_projects) and proper_list?(allowed_projects) do
      issue_projects =
        [issue.project_id, issue.project_slug]
        |> Enum.map(&normalized_optional_string/1)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      if Enum.any?(allowed_projects, &MapSet.member?(issue_projects, normalized_optional_string(&1))),
        do: :ok,
        else: {:error, :forbidden_policy_broadening}
    else
      {:error, :malformed_composed_policy}
    end
  end

  defp validate_allowed_projects(_allowed_projects, _issue),
    do: {:error, :malformed_composed_policy}

  defp validate_active_state(run_target, issue_state) do
    case Map.get(run_target, "active_states", []) do
      [] ->
        :ok

      states when is_list(states) ->
        validate_configured_active_states(states, issue_state)

      _invalid ->
        {:error, :malformed_composed_policy}
    end
  end

  defp validate_configured_active_states(states, issue_state) do
    cond do
      not string_list?(states) or not proper_list?(states) ->
        {:error, :malformed_composed_policy}

      Enum.any?(states, &(normalized_downcase(&1) == normalized_downcase(issue_state))) ->
        :ok

      true ->
        {:error, :forbidden_policy_broadening}
    end
  end

  defp issue_policy_base(%__MODULE__{issue_policy_authority: nil}, manifest, profile) do
    with :ok <- validate_issue_profile(manifest, profile) do
      manifest_issue_policy(manifest)
    end
  end

  defp issue_policy_base(
         %__MODULE__{
           issue_policy_authority: %{"profile" => configured, "policy" => policy} = authority
         },
         manifest,
         profile
       ) do
    cond do
      Enum.sort(Map.keys(authority)) != ["policy", "profile"] ->
        {:error, :malformed_composed_policy}

      not nonblank_string?(configured) or not is_map(policy) or
          not json_safe_policy_value?(policy) ->
        {:error, :malformed_composed_policy}

      profile == configured ->
        with {:ok, manifest_policy} <- manifest_issue_policy(manifest) do
          {:ok, Map.merge(manifest_policy, policy)}
        end

      true ->
        {:error, :unknown_profile}
    end
  end

  defp issue_policy_base(%__MODULE__{}, _manifest, _profile),
    do: {:error, :malformed_composed_policy}

  defp validate_issue_profile(manifest, profile) do
    case Map.get(manifest, "automation") do
      automation when is_map(automation) ->
        validate_pinned_automation_profile(automation, profile)

      _invalid ->
        {:error, :malformed_composed_policy}
    end
  end

  defp validate_pinned_automation_profile(automation, profile) do
    case Map.fetch(automation, "profile") do
      :error ->
        if profile == "default", do: :ok, else: {:error, :unknown_profile}

      {:ok, configured} ->
        validate_present_pinned_profile(configured, profile)
    end
  end

  defp validate_present_pinned_profile(configured, profile) do
    cond do
      not nonblank_string?(configured) -> {:error, :malformed_composed_policy}
      profile in ["default", String.trim(configured)] -> :ok
      true -> {:error, :unknown_profile}
    end
  end

  defp manifest_issue_policy(manifest) do
    with %{} = project <- Map.get(manifest, "project"),
         %{} <- Map.get(manifest, "workflow"),
         %{} = validation <- Map.get(manifest, "validation"),
         commands when is_list(commands) <- Map.get(validation, "commands"),
         %{} = delivery <- Map.get(manifest, "delivery"),
         pr_target when is_binary(pr_target) <- Map.get(delivery, "pr_target"),
         %{} = automation <- Map.get(manifest, "automation"),
         requirements when is_list(requirements) <- Map.get(automation, "completion_requirements"),
         %{} = capabilities <- Map.get(manifest, "capabilities"),
         %{} = issue_markers <- Map.get(manifest, "issue_markers"),
         :ok <- validate_optional_auto_land(manifest),
         true <- json_safe_policy_value?(manifest) do
      manifest_projection =
        Map.take(manifest, [
          "project",
          "docs",
          "vcs",
          "delivery",
          "validation",
          "automation",
          "workflow",
          "auto_land",
          "review_routing",
          "harness",
          "capabilities",
          "issue_markers"
        ])

      policy = %{
        "capabilities" => capabilities,
        "checks" => commands,
        "completion_requirements" => requirements,
        "delivery" => delivery,
        "issue_markers" => issue_markers,
        "manifest" => manifest_projection,
        "project" => Map.take(project, ["criticality", "deployment_coupling"])
      }

      {:ok,
       policy
       |> maybe_put_policy("auto_land", Map.get(manifest, "auto_land"))
       |> maybe_put_policy("review", Map.get(automation, "review"))
       |> maybe_put_policy("review_routing", Map.get(manifest, "review_routing"))}
    else
      _invalid -> {:error, :malformed_composed_policy}
    end
  end

  defp validate_optional_auto_land(manifest) do
    case Map.fetch(manifest, "auto_land") do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, auto_land} when is_map(auto_land) -> :ok
      {:ok, _invalid} -> {:error, :malformed_composed_policy}
    end
  end

  defp validate_issue_restriction_fields(policy) when is_map(policy) do
    with :ok <- validate_auto_land_policy_field(policy),
         :ok <- validate_requirement_policy_field(policy, "completion_requirements", required?: true) do
      validate_requirement_policy_field(policy, "review_requirements", required?: false)
    end
  end

  defp validate_auto_land_policy_field(policy) do
    case Map.fetch(policy, "auto_land") do
      :error ->
        :ok

      {:ok, auto_land} when is_map(auto_land) ->
        validate_auto_land_policy_values(auto_land)

      {:ok, _invalid} ->
        {:error, :malformed_composed_policy}
    end
  end

  defp validate_auto_land_policy_values(auto_land) do
    validators = %{
      "blocked_state" => &nonblank_string?/1,
      "dry_run" => &is_boolean/1,
      "force_human_review_labels" => &string_list?/1,
      "posture" => &nonblank_string?/1,
      "required_checks" => &string_list?/1
    }

    if Enum.all?(validators, fn {field, validator} ->
         valid_optional_policy_value?(auto_land, field, validator)
       end),
       do: :ok,
       else: {:error, :malformed_composed_policy}
  end

  defp valid_optional_policy_value?(policy, field, validator) do
    case Map.fetch(policy, field) do
      :error -> true
      {:ok, value} -> validator.(value)
    end
  end

  defp validate_requirement_policy_field(policy, field, opts) do
    case Map.fetch(policy, field) do
      {:ok, requirements} ->
        if string_list?(requirements),
          do: :ok,
          else: {:error, :malformed_composed_policy}

      :error ->
        if Keyword.fetch!(opts, :required?),
          do: {:error, :malformed_composed_policy},
          else: :ok
    end
  end

  defp apply_issue_restrictions(policy, context, restrictive_flags) do
    restrictions = %{
      "budget_limits" => context.budget_limits,
      "capacity_limits" => context.capacity_limits,
      "effective_checks" => context.effective_checks,
      "external_side_effect_gates" => context.external_side_effect_gates,
      "run_target" => context.run_target,
      "worktree_policy" => context.worktree_policy
    }

    policy
    |> intersect_external_side_effect_gates(context.external_side_effect_gates)
    |> Map.put("target_restrictions", restrictions)
    |> then(fn restricted ->
      Enum.reduce(restrictive_flags, restricted, &apply_issue_restrictive_flag/2)
    end)
  end

  defp intersect_external_side_effect_gates(policy, gates) do
    automatic_side_effects = ~w(vcs_publish pull_request_write merge)

    if Enum.all?(automatic_side_effects, &(Map.get(gates, &1) == "allow")) do
      policy
    else
      case Map.get(policy, "auto_land") do
        auto_land when is_map(auto_land) ->
          Map.put(policy, "auto_land", Map.merge(auto_land, %{"posture" => "off", "dry_run" => true}))

        _no_auto_land ->
          policy
      end
    end
  end

  defp apply_issue_restrictive_flag(:no_land, policy) do
    policy
    |> put_issue_restrictive_flag(:no_land)
    |> put_in(["auto_land"], Map.merge(Map.get(policy, "auto_land", %{}), %{"posture" => "off", "dry_run" => true}))
  end

  defp apply_issue_restrictive_flag(:human_review_only, policy) do
    policy
    |> put_issue_restrictive_flag(:human_review_only)
    |> put_in(["auto_land"], Map.merge(Map.get(policy, "auto_land", %{}), %{"posture" => "off", "dry_run" => true}))
    |> Map.put("handoff_route", "human_review")
  end

  defp apply_issue_restrictive_flag(:require_validation, policy) do
    append_issue_requirement(policy, "completion_requirements", "Run setup requires validation evidence before handoff.")
    |> put_issue_restrictive_flag(:require_validation)
  end

  defp apply_issue_restrictive_flag(:require_review, policy) do
    append_issue_requirement(policy, "review_requirements", "Run setup requires review evidence before handoff.")
    |> put_issue_restrictive_flag(:require_review)
  end

  defp put_issue_restrictive_flag(policy, flag) do
    update_in(policy, ["run_setup"], fn
      value when is_map(value) ->
        flags = value |> Map.get("restrictive_flags", []) |> List.wrap()
        Map.put(value, "restrictive_flags", Enum.uniq(flags ++ [to_string(flag)]))

      _ ->
        %{"restrictive_flags" => [to_string(flag)]}
    end)
  end

  defp append_issue_requirement(policy, key, value) do
    Map.update(policy, key, [value], &Enum.uniq(&1 ++ [value]))
  end

  defp issue_policy_ref(policy) do
    {:ok, "sha256:" <> digest} = Composition.canonical_hash(policy)
    {:ok, binary_part(digest, 0, 12)}
  end

  defp issue_policy_metadata(issue, profile) do
    %{
      "labels" => issue.labels,
      "profile" => profile,
      "project_id" => issue.project_id,
      "project_slug" => issue.project_slug,
      "source" => "target_context",
      "state" => issue.state
    }
  end

  defp maybe_put_policy(policy, _key, nil), do: policy
  defp maybe_put_policy(policy, key, value), do: Map.put(policy, key, value)

  defp json_safe_policy_value?(value) do
    match?({:ok, _hash}, Composition.canonical_hash(value))
  end

  defp optional_nonblank_string?(nil), do: true
  defp optional_nonblank_string?(value), do: nonblank_string?(value)

  defp nonblank_string?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != "" and not Regex.match?(~r/\p{Cc}/u, value)

  defp normalized_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_optional_string(_value), do: nil

  defp normalized_optional_downcase(nil), do: nil
  defp normalized_optional_downcase(value), do: normalized_downcase(value)

  defp normalized_downcase(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalized_downcase(_value), do: ""

  defp composed_optional_string(map, key) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        case normalized_optional_string(value) do
          nil -> {:error, :malformed_composed_policy}
          normalized -> {:ok, normalized}
        end

      {:ok, _invalid} ->
        {:error, :malformed_composed_policy}
    end
  end

  defp string_list?(values) when is_list(values),
    do: proper_list?(values) and Enum.all?(values, &nonblank_string?/1)

  defp string_list?(_values), do: false

  defp build_context(%Snapshot{} = snapshot, target_id, opts, credential_mode)
       when is_binary(target_id) and is_list(opts) and
              credential_mode in [:pinned, :resolved] do
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
         {:ok, tracker_connection} <-
           project_tracker_secret(policy.tracker_connection, credential_mode, opts),
         {:ok, tracker_connection} <-
           attach_tracker_coordinator_path(snapshot.host, tracker_connection) do
      {:ok,
       struct!(__MODULE__,
         target_id: target_id,
         state: target.effective_state,
         dispatch_mode: target.dispatch_mode,
         registry_generation: generation,
         policy_hash: target.policy_hash,
         workspace_layout: registry_workspace_layout(policy.worktree_policy, target_id),
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

  defp build_context(%Snapshot{}, target_id, _opts, _credential_mode)
       when is_binary(target_id),
       do: {:error, :invalid_options}

  defp build_context(%Snapshot{}, _target_id, _opts, _credential_mode),
    do: {:error, :invalid_target_id}

  defp build_context(_snapshot, _target_id, _opts, _credential_mode),
    do: {:error, :invalid_snapshot}

  defp attach_tracker_coordinator_path(
         %{"state_root" => state_root},
         %{"id" => connection_id} = tracker_connection
       )
       when is_binary(state_root) and is_binary(connection_id) do
    if nonblank_string?(state_root) and Regex.match?(@target_id_regex, connection_id) do
      path =
        state_root
        |> Path.expand()
        |> Path.join("tracker-connections")
        |> Path.join(connection_id <> ".state")

      {:ok, Map.put(tracker_connection, "coordinator_state_path", path)}
    else
      {:error, :invalid_tracker_connection}
    end
  end

  defp attach_tracker_coordinator_path(_host, _tracker_connection),
    do: {:error, :invalid_tracker_connection}

  defp registry_workspace_layout(%{"root" => root}, target_id)
       when is_binary(root) and is_binary(target_id) do
    if Path.basename(Path.expand(root)) == target_id, do: :flat, else: :target_scoped
  end

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
        if Enum.sort(Map.keys(repo_policy)) ==
             ["manifest", "manifest_source_dir", "workflow_module_resolution"] and
             is_map(repo_policy["workflow_module_resolution"]) and
             valid_manifest_source_dir?(repo_policy["manifest_source_dir"]) do
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

  defp valid_manifest_source_dir?(source_dir) when is_binary(source_dir),
    do: String.valid?(source_dir) and Path.type(source_dir) == :absolute

  defp valid_manifest_source_dir?(_source_dir), do: false

  defp validate_tracker_secret_reference(%{
         "tracker_connection" => %{"policy" => %{"api_key" => reference}}
       })
       when is_binary(reference) do
    case secret_variable(reference) do
      {:ok, _variable} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp project_tracker_secret(connection, :pinned, _opts), do: {:ok, connection}
  defp project_tracker_secret(connection, :resolved, opts), do: resolve_tracker_secret(connection, opts)

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
