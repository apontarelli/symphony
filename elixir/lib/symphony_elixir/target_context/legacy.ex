defmodule SymphonyElixir.TargetContext.Legacy do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.RunSetup
  alias SymphonyElixir.TargetContext
  alias SymphonyElixir.TargetRegistry.Composition
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workflow.Manifest

  @module_resolution_fields [
    {"module_names", :module_names},
    {"module_refs", :module_refs},
    {"policy_hash", :policy_hash},
    {"rendered", :rendered}
  ]
  @tracker_target_fields [
    {"active_states", :active_states},
    {"assignee", :assignee},
    {"issue_ids", :issue_ids},
    {"project_id", :project_id},
    {"project_slug", :project_slug},
    {"query", :query},
    {"query_file", :query_file},
    {"required_labels", :required_labels},
    {"team_key", :team_key},
    {"terminal_states", :terminal_states},
    {"workspace_slug", :workspace_slug}
  ]
  @tracker_hash_fields ~w(endpoint kind workspace_slug)
  @target_fields [
    {"tracker", :tracker},
    {"type", :type},
    {"kind", :kind},
    {"project_id", :project_id},
    {"project_slug", :project_slug},
    {"project_slug_id", :project_slug_id},
    {"team_key", :team_key},
    {"filter", :filter},
    {"query", :query},
    {"query_file", :query_file},
    {"issue_ids", :issue_ids},
    {"issues", :issues},
    {"ids", :ids}
  ]
  @target_project_fields [{"id", :id}, {"slug", :slug}, {"slug_id", :slug_id}, {"slugId", :slugId}]
  @target_team_fields [{"key", :key}]
  @runner_hash_fields ~w(
    agent
    approval_policy
    command
    config_dir
    config_path
    execution_profiles
    permissions
    hostname
    kind
    max_concurrent_startups
    model
    port
    read_timeout_ms
    stall_timeout_ms
    startup_timeout_ms
    thread_sandbox
    turn_sandbox_policy
    turn_timeout_ms
  )
  @policy_hash_fields ~w(
    auto_land
    capabilities
    checks
    completion_requirements
    delivery
    handoff_route
    issue_markers
    project
    review
    review_requirements
    run_setup
    runners
  )
  @redacted_nested_policy_fields ~w(api_key credentials)
  @sensitive_key_regex ~r/(?:api[_ -]?key|authorization|credential|password|passwd|secret|token|connection[_ -]?string|private[_ -]?key)/i
  @manifest_policy_fields ~w(
    project
    docs
    vcs
    delivery
    validation
    automation
    workflow
    auto_land
    review_routing
    harness
    capabilities
    issue_markers
  )
  @publish_target_fields ~w(repository pr_target github_repository display)
  @turn_sandbox_policy_fields ~w(
    type
    writableRoots
    readOnlyAccess
    networkAccess
    excludeTmpdirEnvVar
    excludeSlashTmp
  )
  @execution_profile_hash_fields ~w(model reasoning_effort budget timeout_ms max_retries command)
  @review_hash_fields ~w(mode model reasoning_effort command timeout_ms max_retries required enabled)
  @budget_periods ~w(per_run daily weekly)

  @spec build_at_process_start(keyword()) :: {:ok, TargetContext.t()} | {:error, term()}
  def build_at_process_start(opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, %{config: config} = loaded_workflow} when is_map(config) <- Workflow.current(),
         {:ok, settings} <- Schema.parse(config),
         run_setup = RunSetup.current(),
         profile = Config.profile_override() || RunSetup.profile(run_setup),
         {:ok, target_id} <- target_id(opts, run_setup),
         {:ok, repo_manifest} <-
           Manifest.read(Workflow.selected_workflow_file_path(), repo_setup?: false),
         repo_manifest = normalize_json(repo_manifest),
         repo_manifest_identity = normalize_json(Map.fetch!(config, "manifest")),
         module_resolution = module_resolution(loaded_workflow),
         {:ok, manifest_source_dir} <- manifest_source_dir(loaded_workflow),
         {:ok, effective_policy} <- Config.effective_policy(settings, profile),
         effective_policy = RunSetup.apply_restrictive_policy(effective_policy, run_setup),
         manifest_authority = %{
           manifest: repo_manifest,
           identity: repo_manifest_identity,
           module_resolution: module_resolution,
           source_dir: manifest_source_dir
         },
         {:ok, context} <-
           build_context(
             target_id,
             settings,
             run_setup,
             profile,
             manifest_authority,
             effective_policy
           ) do
      {:ok, context}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def build_at_process_start(_opts), do: {:error, :invalid_options}

  defp build_context(
         target_id,
         settings,
         run_setup,
         profile,
         %{
           manifest: repo_manifest,
           identity: repo_manifest_identity,
           module_resolution: module_resolution,
           source_dir: manifest_source_dir
         },
         effective_policy
       ) do
    repo_policy = %{
      "manifest" => repo_manifest,
      "manifest_source_dir" => manifest_source_dir,
      "workflow_module_resolution" => module_resolution
    }

    tracker_connection = tracker_connection(settings)
    run_target = run_target(settings)
    worktree_policy = worktree_policy(settings)
    runner_policy = runner_policy(settings)
    capacity_limits = capacity_limits(settings, run_setup)
    budget_limits = budget_limits(effective_policy)
    {state, dispatch_mode} = target_state(RunSetup.mode(run_setup))

    with {:ok, authority_policy} <-
           issue_policy_authority_projection(effective_policy, repo_manifest_identity),
         issue_policy_authority = %{"policy" => authority_policy, "profile" => profile},
         effective_checks = effective_checks(repo_manifest_identity, authority_policy),
         external_side_effect_gates = external_side_effect_gates(authority_policy),
         policy_projection = %{
           budget_limits: budget_limits,
           capacity_limits: capacity_limits,
           effective_checks: effective_checks,
           external_side_effect_gates: external_side_effect_gates,
           repo_policy: %{repo_policy | "manifest" => repo_manifest_identity},
           run_target: run_target,
           tracker_connection: tracker_connection,
           runner_policy: runner_policy,
           worktree_policy: worktree_policy
         },
         {:ok, repo_manifest_hash} <-
           Composition.canonical_hash(repo_manifest_identity),
         {:ok, policy_hash} <- policy_hash(policy_projection, authority_policy),
         {:ok, registry_generation} <-
           Composition.canonical_hash(%{
             "dispatch_mode" => Atom.to_string(dispatch_mode),
             "policy_hash" => policy_hash,
             "profile" => profile,
             "repo_manifest_hash" => repo_manifest_hash,
             "state" => Atom.to_string(state),
             "target_id" => target_id
           }) do
      {:ok,
       struct!(TargetContext,
         target_id: target_id,
         state: state,
         dispatch_mode: dispatch_mode,
         registry_generation: registry_generation,
         policy_hash: policy_hash,
         repo_manifest_hash: repo_manifest_hash,
         issue_policy_authority: issue_policy_authority,
         repo_policy: repo_policy,
         tracker_connection: tracker_connection,
         run_target: run_target,
         worktree_policy: worktree_policy,
         runner_policy: runner_policy,
         effective_checks: effective_checks,
         external_side_effect_gates: external_side_effect_gates,
         capacity_limits: capacity_limits,
         budget_limits: budget_limits
       )}
    end
  end

  defp manifest_source_dir(%{manifest_source_dir: source_dir})
       when is_binary(source_dir) do
    if String.valid?(source_dir) and Path.type(source_dir) == :absolute,
      do: {:ok, source_dir},
      else: {:error, :invalid_manifest_source_dir}
  end

  defp manifest_source_dir(_loaded_workflow), do: {:error, :invalid_manifest_source_dir}

  defp worktree_policy(settings) do
    hooks = settings.hooks

    %{
      "root" => Path.expand(settings.workspace.root),
      "strategy" => "per_issue",
      "hooks" => %{
        "after_create" => hooks.after_create,
        "before_run" => hooks.before_run,
        "after_run" => hooks.after_run,
        "before_remove" => hooks.before_remove,
        "timeout_ms" => hooks.timeout_ms
      }
    }
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(opts, fn {key, _value} -> key == :saved_run_name end) and
         length(Keyword.get_values(opts, :saved_run_name)) <= 1,
       do: :ok,
       else: {:error, :invalid_options}
  end

  defp target_id(opts, run_setup) do
    explicit_name = Keyword.get(opts, :saved_run_name)
    saved_name = saved_run_name(run_setup)

    case explicit_name || saved_name || "legacy" do
      name when is_binary(name) ->
        case RunSetup.validate_name(name) do
          :ok -> {:ok, name}
          {:error, _reason} = error -> error
        end

      _invalid ->
        {:error, :invalid_target_id}
    end
  end

  defp saved_run_name(%{saved_run_name: name}), do: name
  defp saved_run_name(%{"saved_run_name" => name}), do: name
  defp saved_run_name(_run_setup), do: nil

  defp module_resolution(loaded_workflow) do
    projected =
      loaded_workflow
      |> Config.workflow_module_resolution()
      |> then(fn resolution ->
        Map.new(@module_resolution_fields, fn {string_key, atom_key} ->
          {string_key, resolution |> Map.fetch!(atom_key) |> normalize_json()}
        end)
      end)

    Map.update!(projected, "module_refs", fn refs ->
      Enum.map(refs, &Map.take(&1, ["name", "version"]))
    end)
  end

  defp tracker_connection(settings) do
    tracker = settings.tracker

    %{
      "id" => "legacy",
      "policy" => %{
        "api_key" => tracker.api_key,
        "endpoint" => tracker.endpoint,
        "kind" => tracker.kind,
        "workspace_slug" => tracker.workspace_slug
      }
    }
  end

  defp run_target(settings) do
    tracker =
      settings.tracker
      |> Map.from_struct()
      |> project_known_fields(@tracker_target_fields)

    target =
      case settings.target do
        target when is_map(target) ->
          target
          |> project_known_fields(@target_fields)
          |> project_nested_target(target, "project", :project, @target_project_fields)
          |> project_nested_target(target, "team", :team, @target_team_fields)

        _no_target ->
          %{}
      end

    Map.merge(tracker, target)
  end

  defp project_known_fields(map, fields) do
    Enum.reduce(fields, %{}, fn {string_key, atom_key}, projected ->
      case fetch_known_field(map, string_key, atom_key) do
        {:ok, nil} -> projected
        {:ok, value} -> Map.put(projected, string_key, normalize_json(value))
        :error -> projected
      end
    end)
  end

  defp project_nested_target(projected, source, string_key, atom_key, fields) do
    case fetch_known_field(source, string_key, atom_key) do
      {:ok, nested} when is_map(nested) ->
        Map.put(projected, string_key, project_known_fields(nested, fields))

      _missing_or_invalid ->
        projected
    end
  end

  defp fetch_known_field(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      :error -> Map.fetch(map, atom_key)
      result -> result
    end
  end

  defp runner_policy(settings) do
    default = Config.default_runner_name(settings)

    runners =
      settings.runners
      |> normalize_json()
      |> Map.update!(default, &Map.put(&1, "max_turns", settings.agent.max_turns))

    %{
      "allowed" => runners |> Map.keys() |> Enum.sort(),
      "default" => default,
      "runners" => runners
    }
  end

  defp effective_checks(repo_manifest, effective_policy) do
    %{
      "repository" => %{
        "auto_land" => get_in(repo_manifest, ["auto_land", "required_checks"]) || [],
        "validation" => get_in(repo_manifest, ["validation", "commands"]) || []
      },
      "target" => %{
        "checks" => Map.get(effective_policy, "checks", []),
        "completion_requirements" => Map.get(effective_policy, "completion_requirements", []),
        "review_requirements" => Map.get(effective_policy, "review_requirements", [])
      }
    }
  end

  defp external_side_effect_gates(effective_policy) do
    %{
      "tracker_write" => "allow",
      "vcs_publish" => "allow",
      "pull_request_write" => "allow",
      "merge" => legacy_merge_gate(effective_policy),
      "deployment" => "deny",
      "production_data" => "deny"
    }
  end

  defp legacy_merge_gate(effective_policy) do
    auto_land = Map.get(effective_policy, "auto_land")

    cond do
      no_land_restriction?(effective_policy) ->
        "deny"

      Map.get(effective_policy, "handoff_route") == "human_review" ->
        "manual_approval"

      is_map(auto_land) and
          (Map.get(auto_land, "posture") == "off" or Map.get(auto_land, "dry_run") == true) ->
        "deny"

      true ->
        "allow"
    end
  end

  defp no_land_restriction?(%{"run_setup" => %{"restrictive_flags" => flags}})
       when is_list(flags),
       do: "no_land" in flags

  defp no_land_restriction?(_effective_policy), do: false

  defp capacity_limits(settings, run_setup) do
    settings
    |> RunSetup.capacity(run_setup)
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
  end

  defp budget_limits(effective_policy) do
    case Map.get(effective_policy, "limits") do
      limits when is_map(limits) -> normalize_json(limits)
      _no_limits -> %{}
    end
  end

  defp policy_hash(context_policy, authority_policy) do
    with {:ok, runner_projection} <- runner_hash_projection(context_policy.runner_policy),
         {:ok, run_target_projection} <-
           run_target_hash_projection(context_policy.run_target) do
      Composition.canonical_hash(%{
        "budget_limits" => budget_limits_hash_projection(context_policy.budget_limits),
        "capacity_limits" => context_policy.capacity_limits,
        "effective_checks" => context_policy.effective_checks,
        "external_side_effect_gates" => context_policy.external_side_effect_gates,
        "legacy_policy" => authority_policy,
        "repo_policy" => context_policy.repo_policy,
        "run_target" => run_target_projection,
        "tracker_connection" => tracker_hash_projection(context_policy.tracker_connection),
        "runner_policy" => runner_projection,
        "worktree_policy" => context_policy.worktree_policy
      })
    end
  end

  defp issue_policy_authority_projection(policy, repo_manifest)
       when is_map(policy) and is_map(repo_manifest) do
    policy = normalize_json(policy)

    with {:ok, projected} <- project_authority_fields(policy),
         {:ok, projected} <- project_publish_target(projected, policy) do
      manifest = repo_manifest |> Map.take(@manifest_policy_fields) |> canonical_policy_manifest()
      {:ok, Map.put(projected, "manifest", manifest)}
    end
  end

  defp project_authority_fields(policy) do
    Enum.reduce_while(@policy_hash_fields, {:ok, %{}}, fn field, {:ok, projected} ->
      project_authority_field(policy, field, projected)
    end)
  end

  defp project_authority_field(policy, field, projected) do
    case Map.fetch(policy, field) do
      :error ->
        {:cont, {:ok, projected}}

      {:ok, value} ->
        field
        |> policy_field_value(value, [field])
        |> project_field_result(projected, field)
    end
  end

  defp project_field_result({:ok, value}, projected, field),
    do: {:cont, {:ok, Map.put(projected, field, value)}}

  defp project_field_result({:error, _reason} = error, _projected, _field),
    do: {:halt, error}

  defp project_publish_target(projected, policy) do
    case Map.fetch(policy, "publish_target") do
      :error ->
        {:ok, projected}

      {:ok, value} ->
        fields = Enum.map(@publish_target_fields, fn field -> {field, &binary_policy_value/2} end)

        with {:ok, target} <-
               project_policy_map(value, ["publish_target"], fields, []) do
          {:ok, Map.put(projected, "publish_target", target)}
        end
    end
  end

  defp policy_field_value("auto_land", value, path) do
    project_policy_map(value, path, [
      {"posture", &binary_policy_value/2},
      {"dry_run", &boolean_policy_value/2},
      {"required_checks", &string_list_policy_value/2},
      {"force_human_review_labels", &string_list_policy_value/2},
      {"blocked_state", &binary_policy_value/2}
    ])
  end

  defp policy_field_value("capabilities", value, path) do
    project_policy_map(value, path, [{"required", &string_list_policy_value/2}])
  end

  defp policy_field_value("checks", value, path), do: check_list_policy_value(value, path)

  defp policy_field_value(field, value, path)
       when field in ~w(completion_requirements review_requirements),
       do: string_list_policy_value(value, path)

  defp policy_field_value("delivery", value, path) do
    project_policy_map(value, path, [{"pr_target", &binary_policy_value/2}])
  end

  defp policy_field_value("handoff_route", value, path), do: binary_policy_value(value, path)

  defp policy_field_value("issue_markers", value, path) do
    project_policy_map(value, path, [
      {"labels", &string_list_policy_value/2},
      {"allowed_projects", &string_list_policy_value/2}
    ])
  end

  defp policy_field_value("project", value, path) do
    project_policy_map(value, path, [
      {"criticality", &binary_policy_value/2},
      {"deployment_coupling", &binary_policy_value/2}
    ])
  end

  defp policy_field_value("review", value, path) do
    fields =
      Enum.map(@review_hash_fields, fn field ->
        projector =
          case field do
            field when field in ~w(mode model reasoning_effort) -> &binary_policy_value/2
            "command" -> &binary_or_string_list_policy_value/2
            "timeout_ms" -> &positive_integer_policy_value/2
            "max_retries" -> &non_negative_integer_policy_value/2
            field when field in ~w(required enabled) -> &boolean_policy_value/2
          end

        {field, projector}
      end) ++
        [
          {"requirements", &string_list_policy_value/2},
          {"checks", &check_list_policy_value/2}
        ]

    project_policy_map(value, path, fields)
  end

  defp policy_field_value("run_setup", value, path) do
    project_policy_map(value, path, [
      {"restrictive_flags", &string_list_policy_value/2}
    ])
  end

  defp policy_field_value("runners", value, path), do: policy_runners_value(value, path)

  defp policy_runners_value(value, path) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {runner_name, runner}, {:ok, projected} ->
      case policy_runner_value(runner, path ++ [runner_name]) do
        {:ok, projected_runner} ->
          {:cont, {:ok, Map.put(projected, runner_name, projected_runner)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp policy_runners_value(_value, path), do: invalid_issue_policy(path, :expected_map)

  defp policy_runner_value(value, path) do
    project_policy_map(value, path, [
      {"approval_policy", &runner_approval_policy_value/2},
      {"thread_sandbox", &binary_policy_value/2},
      {"turn_sandbox_policy", &runner_turn_sandbox_policy_value/2}
    ])
  end

  defp runner_approval_policy_value(value, _path) when is_binary(value), do: {:ok, value}
  defp runner_approval_policy_value(value, path) when is_map(value), do: secret_safe_policy_value(value, path)

  defp runner_turn_sandbox_policy_value(value, path) do
    project_policy_map(value, path, [
      {"type", &binary_policy_value/2},
      {"writableRoots", &string_list_policy_value/2},
      {"readOnlyAccess", &runner_read_only_access_policy_value/2},
      {"networkAccess", &boolean_policy_value/2},
      {"excludeTmpdirEnvVar", &boolean_policy_value/2},
      {"excludeSlashTmp", &boolean_policy_value/2}
    ])
  end

  defp runner_read_only_access_policy_value(value, path) do
    project_policy_map(value, path, [{"type", &binary_policy_value/2}])
  end

  defp secret_safe_policy_value(value, path),
    do: semantic_projection(value, path, &invalid_issue_policy/2)

  defp semantic_projection(value, path, invalid) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {field, field_value}, {:ok, projected} ->
      project_semantic_field(field, field_value, path, projected, invalid)
    end)
  end

  defp semantic_projection(value, path, invalid) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, projected} ->
      case semantic_projection(item, path ++ [index], invalid) do
        {:ok, safe_value} -> {:cont, {:ok, [safe_value | projected]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, _reason} = error -> error
    end
  end

  defp semantic_projection(value, _path, _invalid)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp semantic_projection(_value, path, invalid),
    do: invalid.(path, :expected_json_value)

  defp project_semantic_field(field, value, path, projected, invalid) do
    if sensitive_key?(field) do
      {:cont, {:ok, projected}}
    else
      case semantic_projection(value, path ++ [field], invalid) do
        {:ok, safe_value} -> {:cont, {:ok, Map.put(projected, field, safe_value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end
  end

  defp project_policy_map(value, path, fields, redacted_fields \\ @redacted_nested_policy_fields)

  defp project_policy_map(value, path, fields, redacted_fields) when is_map(value) do
    allowed_fields =
      fields
      |> Enum.map(&elem(&1, 0))
      |> Kernel.++(redacted_fields)
      |> MapSet.new()

    case value
         |> Map.keys()
         |> Enum.map(&to_string/1)
         |> Enum.reject(&MapSet.member?(allowed_fields, &1))
         |> Enum.sort() do
      [unsupported | _rest] ->
        invalid_issue_policy(path ++ [unsupported], :unsupported_field)

      [] ->
        project_present_fields(value, path, fields)
    end
  end

  defp project_policy_map(_value, path, _fields, _redacted_fields),
    do: invalid_issue_policy(path, :expected_map)

  defp project_present_fields(value, path, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {field, projector}, {:ok, projected} ->
      project_present_field(value, path, field, projector, projected)
    end)
  end

  defp project_present_field(value, path, field, projector, projected) do
    case Map.fetch(value, field) do
      :error ->
        {:cont, {:ok, projected}}

      {:ok, field_value} ->
        field_value
        |> projector.(path ++ [field])
        |> project_field_result(projected, field)
    end
  end

  defp binary_policy_value(value, _path) when is_binary(value), do: {:ok, value}
  defp binary_policy_value(_value, path), do: invalid_issue_policy(path, :expected_string)

  defp boolean_policy_value(value, _path) when is_boolean(value), do: {:ok, value}
  defp boolean_policy_value(_value, path), do: invalid_issue_policy(path, :expected_boolean)

  defp positive_integer_policy_value(value, _path) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp positive_integer_policy_value(_value, path),
    do: invalid_issue_policy(path, :expected_positive_integer)

  defp non_negative_integer_policy_value(value, _path)
       when is_integer(value) and value >= 0,
       do: {:ok, value}

  defp non_negative_integer_policy_value(_value, path),
    do: invalid_issue_policy(path, :expected_non_negative_integer)

  defp string_list_policy_value(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {item, _index}, {:ok, acc} when is_binary(item) ->
        {:cont, {:ok, [item | acc]}}

      {_item, index}, _acc ->
        {:halt, invalid_issue_policy(path ++ [index], :expected_string)}
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, _reason} = error -> error
    end
  end

  defp string_list_policy_value(_value, path),
    do: invalid_issue_policy(path, :expected_list)

  defp binary_or_string_list_policy_value(value, _path) when is_binary(value),
    do: {:ok, value}

  defp binary_or_string_list_policy_value(value, path),
    do: string_list_policy_value(value, path)

  defp check_list_policy_value(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {check, index}, {:ok, acc} ->
      case check_policy_value(check, path ++ [index]) do
        {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, _reason} = error -> error
    end
  end

  defp check_list_policy_value(_value, path),
    do: invalid_issue_policy(path, :expected_list)

  defp check_policy_value(value, _path) when is_binary(value), do: {:ok, value}

  defp check_policy_value(value, path) when is_map(value) do
    with {:ok, projected} <-
           project_policy_map(value, path, [
             {"name", &binary_policy_value/2},
             {"command", &binary_policy_value/2}
           ]),
         true <- Map.has_key?(projected, "name") and Map.has_key?(projected, "command") do
      {:ok, projected}
    else
      false -> invalid_issue_policy(path, :expected_named_check)
      {:error, _reason} = error -> error
    end
  end

  defp check_policy_value(_value, path),
    do: invalid_issue_policy(path, :expected_check)

  defp sensitive_key?("max_total_tokens"), do: false

  defp sensitive_key?(key) when is_binary(key),
    do: String.valid?(key) and Regex.match?(@sensitive_key_regex, key)

  defp invalid_issue_policy(path, reason),
    do: {:error, {:invalid_issue_policy_authority, path, reason}}

  defp invalid_run_target_policy(path, reason),
    do: {:error, {:invalid_run_target_policy, path, reason}}

  defp budget_limits_hash_projection(limits) do
    Map.new(@budget_periods, fn period ->
      {period, budget_period_hash_projection(Map.get(limits, period))}
    end)
  end

  defp budget_period_hash_projection(%{"max_total_tokens" => tokens})
       when is_integer(tokens) and tokens > 0,
       do: %{"max_total_tokens" => tokens}

  defp budget_period_hash_projection(_period), do: %{}

  defp run_target_hash_projection(run_target) when is_map(run_target) do
    Enum.reduce_while(["filter", "query"], {:ok, run_target}, fn field, {:ok, projected} ->
      project_run_target_hash_field(run_target, field, projected)
    end)
  end

  defp project_run_target_hash_field(run_target, field, projected) do
    case Map.fetch(run_target, field) do
      :error ->
        {:cont, {:ok, projected}}

      {:ok, value} ->
        case semantic_projection(value, ["run_target", field], &invalid_run_target_policy/2) do
          {:ok, semantic_value} ->
            {:cont, {:ok, Map.put(projected, field, semantic_value)}}

          {:error, _reason} = error ->
            {:halt, error}
        end
    end
  end

  defp tracker_hash_projection(%{"id" => id, "policy" => policy}) when is_map(policy) do
    %{"id" => id, "policy" => Map.take(policy, @tracker_hash_fields)}
  end

  defp runner_hash_projection(%{"allowed" => allowed, "default" => default, "runners" => runners})
       when is_map(runners) do
    runners
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {name, runner}, {:ok, projected} ->
      case runner_hash_projection_entry(runner, ["runners", name]) do
        {:ok, entry} -> {:cont, {:ok, Map.put(projected, name, entry)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected_runners} ->
        {:ok, %{"allowed" => allowed, "default" => default, "runners" => projected_runners}}

      {:error, _reason} = error ->
        error
    end
  end

  defp runner_hash_projection_entry(runner, path) when is_map(runner) do
    projected =
      runner
      |> Map.take(
        @runner_hash_fields --
          ~w(approval_policy turn_sandbox_policy execution_profiles permissions)
      )
      |> Map.put(
        "execution_profiles",
        execution_profiles_hash_projection(Map.get(runner, "execution_profiles", %{}))
      )

    with {:ok, projected} <-
           project_runner_approval_policy(projected, runner, path ++ ["approval_policy"]),
         {:ok, projected} <-
           project_runner_turn_sandbox_policy(
             projected,
             runner,
             path ++ ["turn_sandbox_policy"]
           ) do
      project_runner_permissions(projected, runner, path ++ ["permissions"])
    end
  end

  defp project_runner_approval_policy(projected, runner, _path) do
    case Map.fetch(runner, "approval_policy") do
      :error ->
        {:ok, projected}

      {:ok, value} when is_binary(value) or (is_map(value) and not is_struct(value)) ->
        {:ok, Map.put(projected, "approval_policy", normalize_json(value))}
    end
  end

  defp project_runner_turn_sandbox_policy(projected, runner, path) do
    case Map.fetch(runner, "turn_sandbox_policy") do
      :error ->
        {:ok, projected}

      {:ok, value} ->
        with {:ok, sandbox} <- turn_sandbox_policy_hash_projection(value, path) do
          {:ok, Map.put(projected, "turn_sandbox_policy", sandbox)}
        end
    end
  end

  defp project_runner_permissions(projected, runner, path) do
    case Map.fetch(runner, "permissions") do
      :error ->
        {:ok, projected}

      {:ok, value} ->
        with {:ok, permissions} <-
               semantic_projection(value, path, &invalid_runner_policy/2) do
          {:ok, Map.put(projected, "permissions", permissions)}
        end
    end
  end

  defp turn_sandbox_policy_hash_projection(value, path) when is_map(value) do
    case value
         |> Map.keys()
         |> Enum.map(&to_string/1)
         |> Enum.reject(&(&1 in @turn_sandbox_policy_fields))
         |> Enum.sort() do
      [unsupported | _rest] ->
        invalid_runner_policy(path ++ [unsupported], :unsupported_field)

      [] ->
        sandbox_fields = [
          {"type", &runner_binary_value/2},
          {"writableRoots", &runner_string_list_value/2},
          {"readOnlyAccess", &runner_read_only_access_value/2},
          {"networkAccess", &runner_boolean_value/2},
          {"excludeTmpdirEnvVar", &runner_boolean_value/2},
          {"excludeSlashTmp", &runner_boolean_value/2}
        ]

        project_present_fields(value, path, sandbox_fields)
    end
  end

  defp runner_binary_value(value, _path) when is_binary(value), do: {:ok, value}
  defp runner_binary_value(_value, path), do: invalid_runner_policy(path, :expected_string)

  defp runner_boolean_value(value, _path) when is_boolean(value), do: {:ok, value}
  defp runner_boolean_value(_value, path), do: invalid_runner_policy(path, :expected_boolean)

  defp runner_string_list_value(value, path) when is_list(value) do
    case Enum.find_index(value, &(not is_binary(&1))) do
      nil -> {:ok, value}
      index -> invalid_runner_policy(path ++ [index], :expected_string)
    end
  end

  defp runner_string_list_value(_value, path),
    do: invalid_runner_policy(path, :expected_list)

  defp runner_read_only_access_value(value, path) when is_map(value) do
    case value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() do
      [] ->
        {:ok, %{}}

      ["type"] ->
        with {:ok, type} <- runner_binary_value(Map.fetch!(value, "type"), path ++ ["type"]) do
          {:ok, %{"type" => type}}
        end

      keys ->
        unsupported = Enum.find(keys, &(&1 != "type"))
        invalid_runner_policy(path ++ [unsupported], :unsupported_field)
    end
  end

  defp runner_read_only_access_value(_value, path),
    do: invalid_runner_policy(path, :expected_map)

  defp invalid_runner_policy(path, reason),
    do: {:error, {:invalid_runner_policy, path, reason}}

  defp execution_profiles_hash_projection(profiles) when is_map(profiles) do
    Map.new(profiles, fn {name, profile} -> {name, execution_profile_hash_projection(profile)} end)
  end

  defp execution_profile_hash_projection(profile) when is_map(profile) do
    Enum.reduce(@execution_profile_hash_fields, %{}, fn field, projected ->
      case execution_profile_hash_value(field, Map.get(profile, field)) do
        :ignore -> projected
        {:ok, value} -> Map.put(projected, field, value)
      end
    end)
  end

  defp execution_profile_hash_projection(_profile), do: %{}

  defp execution_profile_hash_value(_field, nil), do: :ignore

  defp execution_profile_hash_value(field, value)
       when field in ~w(model reasoning_effort budget) and is_binary(value),
       do: {:ok, value}

  defp execution_profile_hash_value("timeout_ms", value) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp execution_profile_hash_value("max_retries", value) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp execution_profile_hash_value("command", value) when is_binary(value), do: {:ok, value}

  defp execution_profile_hash_value("command", value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: {:ok, value}, else: :ignore
  end

  defp execution_profile_hash_value(_field, _value), do: :ignore

  defp target_state(:drain), do: {:draining, :watch}
  defp target_state(:issue_batch), do: {:active, :explicit}
  defp target_state(:watch), do: {:active, :watch}

  defp canonical_policy_manifest(value) when is_map(value) do
    value
    |> Enum.reject(fn {_key, field_value} -> is_nil(field_value) end)
    |> Map.new(fn {key, field_value} ->
      {to_string(key), canonical_policy_manifest(field_value)}
    end)
  end

  defp canonical_policy_manifest(value) when is_list(value),
    do: Enum.map(value, &canonical_policy_manifest/1)

  defp canonical_policy_manifest(value), do: value

  defp normalize_json(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, field_value} -> {to_string(key), normalize_json(field_value)} end)
  end

  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)
  defp normalize_json(value), do: value
end
