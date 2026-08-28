defmodule SymphonyElixir.TargetRegistry.Schema do
  @moduledoc false

  alias SymphonyElixir.Config.Schema, as: ConfigSchema
  alias SymphonyElixir.Config.Schema.RunnerCatalogError
  alias SymphonyElixir.TargetRegistry.Diagnostic
  alias SymphonyElixir.TargetRegistry.Error
  alias SymphonyElixir.TargetRegistry.Snapshot
  alias SymphonyElixir.TargetRegistry.Target

  @id_regex ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
  @runner_validation_catalog_id "registry-runner-validation"
  @root_keys ~w(version host targets)
  @host_keys ~w(id state_root polling capacity scheduling tracker_connections runners)
  @polling_keys ~w(interval_ms max_concurrent_target_polls)
  @capacity_keys ~w(max_concurrent_agents max_concurrent_startups max_concurrent_reviewers)
  @host_scheduling_keys ~w(algorithm max_credit_rounds)
  @connection_keys ~w(kind endpoint api_key)
  @target_keys ~w(display_name state dispatch_mode repo worktree linear runners concurrency budgets checks external_side_effects scheduling)
  @target_map_keys ~w(repo worktree linear runners concurrency budgets checks external_side_effects scheduling)
  @repo_keys ~w(path manifest expected_repository)
  @worktree_keys ~w(root strategy hooks)
  @hook_keys ~w(after_create before_run after_run before_remove timeout_ms)
  @linear_keys ~w(connection scope active_states terminal_states required_labels)
  @scope_keys ~w(type project_id project_slug team_key query_file issue_ids)
  @runner_target_keys ~w(allowed default settings)
  @runner_setting_keys ~w(model reasoning_effort max_turns execution_profiles)
  @host_runner_limit_keys ~w(max_concurrent_agents max_concurrent_startups)
  @concurrency_keys ~w(max_concurrent_agents max_concurrent_startups max_concurrent_reviewers by_linear_state)
  @budget_periods ~w(per_run daily weekly)
  @check_phases ~w(pre_dispatch pre_handoff pre_publish pre_merge)
  @check_ids ~w(capability_preflight repo_validation quality_gate publish_preflight pr_checks review_feedback_sweep)
  @gate_operations ~w(tracker_write vcs_publish pull_request_write merge deployment production_data)
  @gate_values ~w(deny manual_approval allow)
  @target_scheduling_keys ~w(weight)

  @type lifecycle_action :: :activate | :pause | :drain | :retire

  @spec transition_target(map(), String.t(), lifecycle_action(), :explicit | :watch | nil) ::
          {:ok, map()} | {:error, Error.t()}
  def transition_target(configured, target_id, action, requested_mode \\ nil)

  def transition_target(configured, target_id, action, requested_mode)
      when is_map(configured) and is_binary(target_id) do
    path = "$.targets.#{target_id}"

    state =
      case Map.fetch(configured, "state") do
        :error -> :paused
        {:ok, configured_state_value} -> configured_state(configured_state_value)
      end

    with :ok <- validate_lifecycle_transition(state, action, path),
         {:ok, dispatch_mode} <- lifecycle_dispatch_mode(configured, action, requested_mode, path) do
      transitioned =
        configured
        |> Map.put("state", lifecycle_state(action))
        |> put_lifecycle_dispatch_mode(action, dispatch_mode)

      {:ok, transitioned}
    end
  end

  def transition_target(_configured, target_id, _action, _requested_mode) do
    path = if is_binary(target_id), do: "$.targets.#{target_id}", else: "$.targets"

    {:error,
     %Error{
       code: :invalid_lifecycle_target,
       message: "target lifecycle input is invalid",
       path: path
     }}
  end

  @spec validate(map(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def validate(document, opts \\ []) when is_map(document) and is_list(opts) do
    case Map.fetch(document, "version") do
      :error ->
        {:error,
         %Error{
           code: :missing_version,
           path: "$.version",
           message: "registry version is required"
         }}

      {:ok, 1} ->
        validate_version_one(document, opts)

      {:ok, _version} ->
        {:error,
         %Error{
           code: :unsupported_version,
           path: "$.version",
           message: "registry version must be integer 1"
         }}
    end
  end

  defp validate_version_one(document, opts) do
    root_diagnostics =
      unknown_key_diagnostics(document, @root_keys, :registry, "$") ++
        required_map_diagnostics(document, ["host", "targets"], :registry, "$")

    {host, host_diagnostics} =
      case Map.get(document, "host") do
        host when is_map(host) -> validate_host(host, opts)
        _missing_or_invalid -> {nil, []}
      end

    {targets, target_diagnostics} =
      case Map.get(document, "targets") do
        targets when is_map(targets) -> validate_targets(targets, opts)
        _missing_or_invalid -> {%{}, []}
      end

    global_diagnostics = sort_diagnostics(root_diagnostics ++ host_diagnostics)
    diagnostics = sort_diagnostics(global_diagnostics ++ target_diagnostics)

    {:ok,
     %Snapshot{
       version: 1,
       globally_valid?: not error_diagnostic?(global_diagnostics),
       host: host,
       targets: targets,
       diagnostics: diagnostics
     }}
  end

  defp validate_targets(targets, opts) do
    targets
    |> ordered_map_entries()
    |> Enum.with_index()
    |> Enum.map(fn {{id, configured}, index} -> validate_target(id, configured, opts, index) end)
    |> Enum.reduce({%{}, []}, fn {id, target}, {target_map, diagnostics} ->
      {Map.put(target_map, id, target), target.diagnostics ++ diagnostics}
    end)
  end

  defp validate_target(id, configured, opts, index) when is_map(configured) do
    scope = {:target, id}
    path = dynamic_key_path("$.targets", id, index)

    diagnostics =
      validate_dynamic_id(id, scope, path) ++
        unknown_key_diagnostics(configured, @target_keys, scope, path) ++
        required_target_map_diagnostics(configured, scope, path) ++
        validate_display_name(configured, scope, "#{path}.display_name") ++
        validate_target_state(configured, scope, path) ++
        validate_dispatch_mode(configured, scope, path) ++
        validate_repo(configured["repo"], scope, "#{path}.repo") ++
        validate_worktree(configured["worktree"], scope, "#{path}.worktree") ++
        validate_linear(configured["linear"], scope, "#{path}.linear") ++
        validate_target_runners(configured["runners"], scope, "#{path}.runners") ++
        validate_concurrency(configured["concurrency"], scope, "#{path}.concurrency") ++
        validate_budgets(configured["budgets"], scope, "#{path}.budgets") ++
        validate_checks(configured["checks"], scope, "#{path}.checks") ++
        validate_gates(
          configured["external_side_effects"],
          scope,
          "#{path}.external_side_effects"
        ) ++
        validate_target_scheduling(configured["scheduling"], scope, "#{path}.scheduling")

    diagnostics = sort_diagnostics(diagnostics)
    configured_state = configured_state(configured["state"])
    dispatch_mode = dispatch_mode(configured["dispatch_mode"])
    valid? = not error_diagnostic?(diagnostics)

    target = %Target{
      id: id,
      configured: normalize_target(configured, opts),
      configured_state: configured_state,
      effective_state: effective_state(configured_state, valid?),
      dispatch_mode: dispatch_mode,
      valid?: valid?,
      diagnostics: diagnostics
    }

    {id, target}
  end

  defp validate_target(id, _configured, _opts, index) do
    scope = {:target, id}
    path = dynamic_key_path("$.targets", id, index)

    diagnostics =
      sort_diagnostics(
        validate_dynamic_id(id, scope, path) ++
          [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a map")]
      )

    {id,
     %Target{
       id: id,
       configured: %{},
       configured_state: nil,
       effective_state: :paused,
       dispatch_mode: nil,
       valid?: false,
       diagnostics: diagnostics
     }}
  end

  defp validate_display_name(configured, scope, path) do
    case Map.fetch(configured, "display_name") do
      :error ->
        []

      {:ok, value} when is_binary(value) ->
        if value != "" and String.trim(value) == value do
          []
        else
          [diagnostic(:error, scope, path, :invalid_value, "#{path} must be a non-empty trimmed string")]
        end

      {:ok, _invalid} ->
        [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a string")]
    end
  end

  defp validate_target_state(configured, scope, path) do
    state_path = "#{path}.state"

    case Map.fetch(configured, "state") do
      :error ->
        [
          diagnostic(
            :warning,
            scope,
            state_path,
            :missing_state,
            "#{state_path} is missing; effective state is paused"
          )
        ]

      {:ok, state} when state in ["paused", "active", "draining", "retired"] ->
        []

      {:ok, state} when is_binary(state) ->
        [diagnostic(:error, scope, state_path, :unknown_state, "#{state_path} is unknown")]

      {:ok, _invalid} ->
        [diagnostic(:error, scope, state_path, :invalid_type, "#{state_path} must be a string")]
    end
  end

  defp validate_dispatch_mode(configured, scope, path) do
    mode_path = "#{path}.dispatch_mode"

    mode_diagnostics =
      case Map.fetch(configured, "dispatch_mode") do
        :error ->
          []

        {:ok, mode} when mode in ["explicit", "watch"] ->
          []

        {:ok, mode} when is_binary(mode) ->
          [
            diagnostic(
              :error,
              scope,
              mode_path,
              :unknown_dispatch_mode,
              "#{mode_path} is unknown"
            )
          ]

        {:ok, _invalid} ->
          [diagnostic(:error, scope, mode_path, :invalid_type, "#{mode_path} must be a string")]
      end

    active_mode_diagnostics =
      if configured["state"] == "active" and not Map.has_key?(configured, "dispatch_mode") do
        [
          diagnostic(
            :error,
            scope,
            mode_path,
            :missing_dispatch_mode,
            "#{mode_path} must be explicit or watch for an active target"
          )
        ]
      else
        []
      end

    mode_diagnostics ++ active_mode_diagnostics
  end

  defp configured_state("paused"), do: :paused
  defp configured_state("active"), do: :active
  defp configured_state("draining"), do: :draining
  defp configured_state("retired"), do: :retired
  defp configured_state(state) when is_binary(state), do: {:unknown, state}
  defp configured_state(_state), do: nil

  defp dispatch_mode("explicit"), do: :explicit
  defp dispatch_mode("watch"), do: :watch
  defp dispatch_mode(mode) when is_binary(mode), do: {:unknown, mode}
  defp dispatch_mode(_mode), do: nil

  defp effective_state(_configured_state, false), do: :paused
  defp effective_state(nil, true), do: :paused
  defp effective_state(configured_state, true), do: configured_state

  defp validate_lifecycle_transition(:retired, _action, path) do
    {:error,
     %Error{
       code: :target_retired,
       message: "retired target is terminal",
       path: path <> ".state"
     }}
  end

  defp validate_lifecycle_transition(:paused, action, _path)
       when action in [:activate, :retire],
       do: :ok

  defp validate_lifecycle_transition(:active, action, _path)
       when action in [:pause, :drain],
       do: :ok

  defp validate_lifecycle_transition(:draining, :pause, _path), do: :ok

  defp validate_lifecycle_transition(state, action, path) do
    {:error,
     %Error{
       code: :invalid_transition,
       message: "target lifecycle transition from #{lifecycle_state_name(state)} by #{lifecycle_action_name(action)} is invalid",
       path: path <> ".state"
     }}
  end

  defp lifecycle_dispatch_mode(configured, :activate, requested_mode, path) do
    mode =
      case requested_mode do
        nil -> dispatch_mode(configured["dispatch_mode"])
        requested -> requested
      end

    if mode in [:explicit, :watch] do
      {:ok, mode}
    else
      {:error,
       %Error{
         code: :dispatch_mode_required,
         message: "activation requires dispatch mode explicit or watch",
         path: path <> ".dispatch_mode"
       }}
    end
  end

  defp lifecycle_dispatch_mode(_configured, action, nil, _path)
       when action in [:pause, :drain, :retire],
       do: {:ok, nil}

  defp lifecycle_dispatch_mode(_configured, _action, _requested_mode, path) do
    {:error,
     %Error{
       code: :invalid_dispatch_mode,
       message: "dispatch mode is invalid for target lifecycle action",
       path: path <> ".dispatch_mode"
     }}
  end

  defp lifecycle_state(:activate), do: "active"
  defp lifecycle_state(:pause), do: "paused"
  defp lifecycle_state(:drain), do: "draining"
  defp lifecycle_state(:retire), do: "retired"
  defp lifecycle_state(_action), do: "unknown"

  defp put_lifecycle_dispatch_mode(configured, :activate, mode),
    do: Map.put(configured, "dispatch_mode", Atom.to_string(mode))

  defp put_lifecycle_dispatch_mode(configured, _action, _mode), do: configured

  defp lifecycle_state_name(state) when state in [:paused, :active, :draining, :retired],
    do: Atom.to_string(state)

  defp lifecycle_state_name(_state), do: "unknown"

  defp lifecycle_action_name(action) when action in [:activate, :pause, :drain, :retire],
    do: Atom.to_string(action)

  defp lifecycle_action_name(_action), do: "unknown action"

  defp normalize_target(configured, opts) do
    home = Keyword.get(opts, :home)

    configured
    |> Map.take(@target_keys)
    |> normalize_repo()
    |> normalize_worktree()
    |> normalize_linear()
    |> normalize_target_runners()
    |> normalize_concurrency()
    |> normalize_checks()
    |> normalize_gates()
    |> update_nested_path("repo", "path", home)
    |> update_nested_path("worktree", "root", home)
  end

  defp update_nested_path(configured, map_key, field, home) do
    case configured[map_key] do
      nested when is_map(nested) ->
        case Map.fetch(nested, field) do
          {:ok, value} ->
            Map.put(configured, map_key, Map.put(nested, field, expand_home_path(value, home)))

          :error ->
            configured
        end

      _missing_or_invalid ->
        configured
    end
  end

  defp expand_home_path("~/", home) when is_binary(home), do: home
  defp expand_home_path("~/" <> rest, home) when is_binary(home), do: Path.join(home, rest)
  defp expand_home_path(value, _home), do: value

  defp required_target_map_diagnostics(configured, scope, path) do
    regular_fields = Enum.reject(@target_map_keys, &(&1 == "external_side_effects"))

    required_map_diagnostics(configured, regular_fields, scope, path) ++
      case Map.fetch(configured, "external_side_effects") do
        :error ->
          gate_path = "#{path}.external_side_effects"

          [
            diagnostic(
              :error,
              scope,
              gate_path,
              :incomplete_policy,
              "#{gate_path} is required; omitted operations default to deny"
            )
          ]

        {:ok, gates} when is_map(gates) ->
          []

        {:ok, _invalid} ->
          gate_path = "#{path}.external_side_effects"
          [diagnostic(:error, scope, gate_path, :invalid_type, "#{gate_path} must be a map")]
      end
  end

  defp validate_repo(repo, scope, path) when is_map(repo) do
    unknown_key_diagnostics(repo, @repo_keys, scope, path) ++
      required_field_diagnostics(repo, ["path"], scope, path) ++
      validate_nonempty_string_field(repo, "path", scope, "#{path}.path") ++
      validate_optional_nonempty_string_field(repo, "manifest", scope, "#{path}.manifest") ++
      validate_optional_nonempty_string_field(
        repo,
        "expected_repository",
        scope,
        "#{path}.expected_repository"
      )
  end

  defp validate_repo(_repo, _scope, _path), do: []

  defp validate_worktree(worktree, scope, path) when is_map(worktree) do
    unknown_key_diagnostics(worktree, @worktree_keys, scope, path) ++
      required_field_diagnostics(worktree, ["root", "strategy"], scope, path) ++
      validate_nonempty_string_field(worktree, "root", scope, "#{path}.root") ++
      validate_enum_field(worktree, "strategy", ["per_issue"], scope, "#{path}.strategy") ++
      validate_hooks(worktree, scope, "#{path}.hooks")
  end

  defp validate_worktree(_worktree, _scope, _path), do: []

  defp validate_hooks(worktree, scope, path) do
    case Map.fetch(worktree, "hooks") do
      :error ->
        []

      {:ok, hooks} when is_map(hooks) ->
        unknown_key_diagnostics(hooks, @hook_keys, scope, path) ++
          Enum.flat_map(~w(after_create before_run after_run before_remove), fn field ->
            validate_nullable_nonempty_string_field(hooks, field, scope, "#{path}.#{field}")
          end) ++
          validate_optional_positive_integer_field(hooks, "timeout_ms", scope, "#{path}.timeout_ms")

      {:ok, _invalid} ->
        [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a map")]
    end
  end

  defp validate_linear(linear, scope, path) when is_map(linear) do
    unknown_key_diagnostics(linear, @linear_keys, scope, path) ++
      required_field_diagnostics(
        linear,
        ["connection", "scope", "active_states", "terminal_states"],
        scope,
        path
      ) ++
      validate_id_field(linear, "connection", scope, "#{path}.connection") ++
      validate_scope(linear, scope, "#{path}.scope") ++
      validate_nonempty_string_list(linear, "active_states", scope, "#{path}.active_states") ++
      validate_nonempty_string_list(linear, "terminal_states", scope, "#{path}.terminal_states") ++
      validate_optional_string_list(linear, "required_labels", scope, "#{path}.required_labels")
  end

  defp validate_linear(_linear, _scope, _path), do: []

  defp validate_scope(linear, scope, path) do
    case Map.fetch(linear, "scope") do
      :error ->
        []

      {:ok, scope_map} when is_map(scope_map) ->
        unknown_key_diagnostics(scope_map, @scope_keys, scope, path) ++
          required_field_diagnostics(scope_map, ["type"], scope, path) ++
          validate_enum_field(
            scope_map,
            "type",
            ~w(project team query issues),
            scope,
            "#{path}.type"
          ) ++
          Enum.flat_map(~w(project_id project_slug team_key query_file), fn field ->
            validate_optional_nonempty_string_field(scope_map, field, scope, "#{path}.#{field}")
          end) ++
          validate_optional_nonempty_string_list(scope_map, "issue_ids", scope, "#{path}.issue_ids")

      {:ok, _invalid} ->
        [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a map")]
    end
  end

  defp validate_target_runners(runners, scope, path) when is_map(runners) do
    unknown_key_diagnostics(runners, @runner_target_keys, scope, path) ++
      required_field_diagnostics(runners, ["allowed", "default"], scope, path) ++
      validate_id_list(runners, "allowed", scope, "#{path}.allowed") ++
      validate_id_field(runners, "default", scope, "#{path}.default") ++
      validate_runner_settings(runners, scope, "#{path}.settings")
  end

  defp validate_target_runners(_runners, _scope, _path), do: []

  defp validate_id_list(map, field, scope, path) do
    case Map.fetch(map, field) do
      :error ->
        []

      {:ok, []} ->
        [diagnostic(:error, scope, path, :invalid_value, "#{path} must not be empty")]

      {:ok, values} when is_list(values) ->
        Enum.with_index(values)
        |> Enum.flat_map(fn
          {value, index} when is_binary(value) ->
            validate_dynamic_id(value, scope, "#{path}[#{index}]")

          {_value, index} ->
            item_path = "#{path}[#{index}]"
            [diagnostic(:error, scope, item_path, :invalid_type, "#{item_path} must be a string")]
        end)

      {:ok, _invalid} ->
        [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a list")]
    end
  end

  defp validate_runner_settings(runners, scope, path) do
    case Map.fetch(runners, "settings") do
      :error ->
        []

      {:ok, settings} when is_map(settings) ->
        settings
        |> ordered_map_entries()
        |> Enum.with_index()
        |> Enum.flat_map(fn {{id, setting}, index} ->
          setting_path = dynamic_key_path(path, id, index)

          validate_dynamic_id(id, scope, setting_path) ++
            validate_runner_setting(setting, scope, setting_path)
        end)

      {:ok, _invalid} ->
        [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a map")]
    end
  end

  defp validate_runner_setting(setting, scope, path) when is_map(setting) do
    unknown_key_diagnostics(setting, @runner_setting_keys, scope, path) ++
      validate_optional_nonempty_string_field(setting, "model", scope, "#{path}.model") ++
      validate_optional_enum_field(
        setting,
        "reasoning_effort",
        ~w(minimal low medium high xhigh),
        scope,
        "#{path}.reasoning_effort"
      ) ++
      validate_optional_positive_integer_field(setting, "max_turns", scope, "#{path}.max_turns") ++
      validate_optional_map_field(
        setting,
        "execution_profiles",
        scope,
        "#{path}.execution_profiles"
      )
  end

  defp validate_runner_setting(_setting, scope, path) do
    [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a map")]
  end

  defp validate_concurrency(concurrency, scope, path) when is_map(concurrency) do
    required_fields = ~w(max_concurrent_agents max_concurrent_startups max_concurrent_reviewers)

    unknown_key_diagnostics(concurrency, @concurrency_keys, scope, path) ++
      required_field_diagnostics(concurrency, required_fields, scope, path) ++
      Enum.flat_map(required_fields, fn field ->
        validate_positive_integer_field(concurrency, field, scope, "#{path}.#{field}")
      end) ++
      validate_state_limits(concurrency, scope, "#{path}.by_linear_state")
  end

  defp validate_concurrency(_concurrency, _scope, _path), do: []

  defp validate_state_limits(concurrency, scope, path) do
    case Map.fetch(concurrency, "by_linear_state") do
      :error ->
        []

      {:ok, limits} when is_map(limits) ->
        entries =
          limits
          |> ordered_map_entries()
          |> Enum.with_index()

        entry_diagnostics =
          Enum.flat_map(entries, fn {{state, limit}, index} ->
            state_path = state_limit_key_path(path, state, index)

            cond do
              not is_binary(state) ->
                [
                  diagnostic(
                    :error,
                    scope,
                    state_path,
                    :invalid_type,
                    "#{state_path} state name must be a string"
                  )
                ]

              String.trim(state) == "" ->
                [
                  diagnostic(
                    :error,
                    scope,
                    state_path,
                    :invalid_value,
                    "#{state_path} state name must not be blank"
                  )
                ]

              not is_integer(limit) or limit <= 0 ->
                [
                  diagnostic(
                    :error,
                    scope,
                    state_path,
                    :invalid_type,
                    "#{state_path} must be a positive integer"
                  )
                ]

              true ->
                []
            end
          end)

        entry_diagnostics ++ normalized_state_collision_diagnostics(entries, scope, path)

      {:ok, _invalid} ->
        [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a map")]
    end
  end

  defp validate_budgets(budgets, scope, path) when is_map(budgets) do
    unknown_key_diagnostics(budgets, @budget_periods, scope, path) ++
      required_map_diagnostics(budgets, @budget_periods, scope, path) ++
      Enum.flat_map(@budget_periods, fn period ->
        validate_budget_period(budgets[period], scope, "#{path}.#{period}")
      end)
  end

  defp validate_budgets(_budgets, _scope, _path), do: []

  defp validate_budget_period(period, scope, path) when is_map(period) do
    fields = ["max_total_tokens"]

    unknown_key_diagnostics(period, fields, scope, path) ++
      required_field_diagnostics(period, fields, scope, path) ++
      validate_positive_integer_field(period, "max_total_tokens", scope, "#{path}.max_total_tokens")
  end

  defp validate_budget_period(_period, _scope, _path), do: []

  defp validate_checks(checks, scope, path) when is_map(checks) do
    unknown_key_diagnostics(checks, @check_phases, scope, path) ++
      Enum.flat_map(@check_phases, fn phase ->
        validate_check_list(checks, phase, scope, "#{path}.#{phase}")
      end)
  end

  defp validate_checks(_checks, _scope, _path), do: []

  defp validate_check_list(checks, phase, scope, path) do
    case Map.fetch(checks, phase) do
      :error ->
        []

      {:ok, values} when is_list(values) ->
        values
        |> Enum.with_index()
        |> Enum.flat_map(&validate_check(&1, scope, path))

      {:ok, _invalid} ->
        [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a list")]
    end
  end

  defp validate_check({value, _index}, _scope, _path) when value in @check_ids, do: []

  defp validate_check({value, index}, scope, path) when is_binary(value) do
    item_path = "#{path}[#{index}]"

    [
      diagnostic(
        :error,
        scope,
        item_path,
        :unknown_check,
        "#{item_path} is not a known check"
      )
    ]
  end

  defp validate_check({_value, index}, scope, path) do
    item_path = "#{path}[#{index}]"
    [diagnostic(:error, scope, item_path, :invalid_type, "#{item_path} must be a string")]
  end

  defp validate_gates(gates, scope, path) when is_map(gates) do
    unknown_gate_diagnostics(gates, scope, path) ++
      Enum.flat_map(@gate_operations, fn operation ->
        gate_path = "#{path}.#{operation}"

        case Map.fetch(gates, operation) do
          :error ->
            []

          {:ok, value} when value in @gate_values ->
            []

          {:ok, value} when is_binary(value) ->
            [diagnostic(:error, scope, gate_path, :unknown_gate, "#{gate_path} is not a known gate value")]

          {:ok, _invalid} ->
            [diagnostic(:error, scope, gate_path, :invalid_type, "#{gate_path} must be a string")]
        end
      end)
  end

  defp validate_gates(_gates, _scope, _path), do: []

  defp unknown_gate_diagnostics(gates, scope, path) do
    gates
    |> ordered_map_entries()
    |> Enum.with_index()
    |> Enum.reject(fn {{operation, _value}, _index} -> operation in @gate_operations end)
    |> Enum.map(fn {{operation, _value}, index} ->
      gate_path = dynamic_key_path(path, operation, index)
      diagnostic(:error, scope, gate_path, :unknown_gate, "#{gate_path} is not a known gate operation")
    end)
  end

  defp validate_target_scheduling(scheduling, scope, path) when is_map(scheduling) do
    unknown_key_diagnostics(scheduling, @target_scheduling_keys, scope, path) ++
      required_field_diagnostics(scheduling, @target_scheduling_keys, scope, path) ++
      case Map.fetch(scheduling, "weight") do
        :error ->
          []

        {:ok, weight} when is_integer(weight) and weight in 1..100 ->
          []

        {:ok, weight} when is_integer(weight) ->
          weight_path = "#{path}.weight"

          [
            diagnostic(
              :error,
              scope,
              weight_path,
              :invalid_value,
              "#{weight_path} must be from 1 through 100"
            )
          ]

        {:ok, _invalid} ->
          weight_path = "#{path}.weight"
          [diagnostic(:error, scope, weight_path, :invalid_type, "#{weight_path} must be an integer")]
      end
  end

  defp validate_target_scheduling(_scheduling, _scope, _path), do: []

  defp validate_nonempty_string_field(map, field, scope, path) do
    case Map.fetch(map, field) do
      :error -> []
      {:ok, value} -> validate_nonempty_string(value, scope, path)
    end
  end

  defp validate_optional_nonempty_string_field(map, field, scope, path) do
    validate_nonempty_string_field(map, field, scope, path)
  end

  defp validate_nullable_nonempty_string_field(map, field, scope, path) do
    case Map.fetch(map, field) do
      :error -> []
      {:ok, nil} -> []
      {:ok, value} -> validate_nonempty_string(value, scope, path)
    end
  end

  defp validate_nonempty_string(value, scope, path) when is_binary(value) do
    if String.trim(value) == "" do
      [diagnostic(:error, scope, path, :invalid_value, "#{path} must not be empty")]
    else
      []
    end
  end

  defp validate_nonempty_string(_value, scope, path) do
    [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a string")]
  end

  defp validate_optional_enum_field(map, field, allowed, scope, path) do
    validate_enum_field(map, field, allowed, scope, path)
  end

  defp validate_optional_positive_integer_field(map, field, scope, path) do
    validate_positive_integer_field(map, field, scope, path)
  end

  defp validate_optional_map_field(map, field, scope, path) do
    case Map.fetch(map, field) do
      :error -> []
      {:ok, value} when is_map(value) -> []
      {:ok, _invalid} -> [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a map")]
    end
  end

  defp validate_nonempty_string_list(map, field, scope, path) do
    validate_string_list(map, field, scope, path, true)
  end

  defp validate_optional_nonempty_string_list(map, field, scope, path) do
    validate_string_list(map, field, scope, path, true)
  end

  defp validate_optional_string_list(map, field, scope, path) do
    validate_string_list(map, field, scope, path, false)
  end

  defp validate_string_list(map, field, scope, path, require_nonempty?) do
    case Map.fetch(map, field) do
      :error ->
        []

      {:ok, []} when require_nonempty? ->
        [diagnostic(:error, scope, path, :invalid_value, "#{path} must not be empty")]

      {:ok, values} when is_list(values) ->
        values
        |> Enum.with_index()
        |> Enum.flat_map(&validate_string_list_item(&1, scope, path))

      {:ok, _invalid} ->
        [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a list")]
    end
  end

  defp validate_string_list_item({value, index}, scope, path) when is_binary(value) do
    if String.trim(value) == "" do
      item_path = "#{path}[#{index}]"
      [diagnostic(:error, scope, item_path, :invalid_value, "#{item_path} must not be empty")]
    else
      []
    end
  end

  defp validate_string_list_item({_value, index}, scope, path) do
    item_path = "#{path}[#{index}]"
    [diagnostic(:error, scope, item_path, :invalid_type, "#{item_path} must be a string")]
  end

  defp normalize_repo(configured) do
    normalize_nested_map(configured, "repo", @repo_keys, %{"manifest" => "symphony.yml"})
  end

  defp normalize_worktree(configured) do
    case configured["worktree"] do
      worktree when is_map(worktree) ->
        normalized =
          worktree
          |> Map.take(@worktree_keys)
          |> normalize_hooks()

        Map.put(configured, "worktree", normalized)

      _missing_or_invalid ->
        configured
    end
  end

  defp normalize_hooks(worktree) do
    hooks =
      case Map.fetch(worktree, "hooks") do
        :error -> default_hooks()
        {:ok, configured} when is_map(configured) -> Map.merge(default_hooks(), Map.take(configured, @hook_keys))
        {:ok, invalid} -> invalid
      end

    Map.put(worktree, "hooks", hooks)
  end

  defp default_hooks do
    defaults = %ConfigSchema.Hooks{}

    %{
      "after_create" => defaults.after_create,
      "before_run" => defaults.before_run,
      "after_run" => defaults.after_run,
      "before_remove" => defaults.before_remove,
      "timeout_ms" => defaults.timeout_ms
    }
  end

  defp normalize_linear(configured) do
    case configured["linear"] do
      linear when is_map(linear) ->
        linear =
          linear
          |> Map.take(@linear_keys)
          |> Map.put_new("required_labels", [])
          |> normalize_list_field("active_states", false)
          |> normalize_list_field("terminal_states", false)
          |> normalize_list_field("required_labels", true)
          |> normalize_scope()

        Map.put(configured, "linear", linear)

      _missing_or_invalid ->
        configured
    end
  end

  defp normalize_scope(linear) do
    case linear["scope"] do
      scope when is_map(scope) ->
        normalized_scope =
          scope
          |> Map.take(@scope_keys)
          |> normalize_list_field("issue_ids", false)

        Map.put(linear, "scope", normalized_scope)

      _missing_or_invalid ->
        linear
    end
  end

  defp normalize_target_runners(configured) do
    case configured["runners"] do
      runners when is_map(runners) ->
        normalized =
          runners
          |> Map.take(@runner_target_keys)
          |> Map.put_new("settings", %{})
          |> update_present_field("allowed", &normalize_id_list/1)
          |> Map.update("settings", %{}, &normalize_runner_setting_maps/1)

        Map.put(configured, "runners", normalized)

      _missing_or_invalid ->
        configured
    end
  end

  defp normalize_runner_setting_maps(settings) when is_map(settings) do
    Map.new(settings, fn
      {id, setting} when is_map(setting) -> {id, Map.take(setting, @runner_setting_keys)}
      entry -> entry
    end)
  end

  defp normalize_runner_setting_maps(settings), do: settings

  defp normalize_concurrency(configured) do
    case configured["concurrency"] do
      concurrency when is_map(concurrency) ->
        normalized =
          concurrency
          |> Map.take(@concurrency_keys)
          |> Map.put_new("by_linear_state", %{})
          |> Map.update("by_linear_state", %{}, &normalize_state_limit_map/1)

        Map.put(configured, "concurrency", normalized)

      _missing_or_invalid ->
        configured
    end
  end

  defp normalize_state_limit_map(limits) when is_map(limits) do
    entries = ordered_map_entries(limits)

    if normalized_state_collision?(entries) do
      limits
    else
      Map.new(entries, &normalize_state_limit_entry/1)
    end
  end

  defp normalize_state_limit_map(limits), do: limits

  defp normalize_state_limit_entry({state, limit}) when is_binary(state) do
    {state |> String.trim() |> String.downcase(), limit}
  end

  defp normalize_state_limit_entry(entry), do: entry

  defp normalize_checks(configured) do
    case configured["checks"] do
      checks when is_map(checks) ->
        normalized =
          @check_phases
          |> Map.new(&{&1, []})
          |> Map.merge(Map.take(checks, @check_phases))
          |> Map.new(fn {phase, values} -> {phase, normalize_id_list(values)} end)

        Map.put(configured, "checks", normalized)

      _missing_or_invalid ->
        configured
    end
  end

  defp normalize_gates(configured) do
    case configured["external_side_effects"] do
      gates when is_map(gates) ->
        normalized =
          @gate_operations
          |> Map.new(&{&1, "deny"})
          |> Map.merge(Map.take(gates, @gate_operations))

        Map.put(configured, "external_side_effects", normalized)

      _missing_or_invalid ->
        configured
    end
  end

  defp normalize_nested_map(configured, field, known_keys, defaults) do
    case configured[field] do
      nested when is_map(nested) ->
        normalized = defaults |> Map.merge(Map.take(nested, known_keys))
        Map.put(configured, field, normalized)

      _missing_or_invalid ->
        configured
    end
  end

  defp normalize_list_field(map, field, downcase?) do
    update_present_field(map, field, &normalize_display_list(&1, downcase?))
  end

  defp normalize_display_list(values, downcase?) when is_list(values) do
    {normalized, _seen} =
      Enum.reduce(
        values,
        {[], MapSet.new()},
        &normalize_display_value(&1, &2, downcase?)
      )

    Enum.reverse(normalized)
  end

  defp normalize_display_list(values, _downcase?), do: values

  defp normalize_display_value(value, {items, seen}, downcase?) when is_binary(value) do
    trimmed = String.trim(value)
    comparison = String.downcase(trimmed)

    if MapSet.member?(seen, comparison) do
      {items, seen}
    else
      output = if downcase?, do: comparison, else: trimmed
      {[output | items], MapSet.put(seen, comparison)}
    end
  end

  defp normalize_display_value(value, {items, seen}, _downcase?), do: {[value | items], seen}

  defp normalize_id_list(values) when is_list(values), do: Enum.uniq(values)
  defp normalize_id_list(values), do: values

  defp validate_host(host, opts) do
    diagnostics =
      unknown_key_diagnostics(host, @host_keys, :host, "$.host") ++
        required_field_diagnostics(host, ["id", "state_root"], :host, "$.host") ++
        required_map_diagnostics(
          host,
          ["polling", "capacity", "scheduling", "tracker_connections", "runners"],
          :host,
          "$.host"
        ) ++
        validate_id_field(host, "id", :host, "$.host.id") ++
        validate_nonempty_string_field(host, "state_root", :host, "$.host.state_root") ++
        validate_positive_integer_map(
          host["polling"],
          @polling_keys,
          :host,
          "$.host.polling"
        ) ++
        validate_host_capacity(host["capacity"]) ++
        validate_host_scheduling(host["scheduling"]) ++
        validate_tracker_connections(host["tracker_connections"]) ++
        validate_host_runners(host["runners"])

    normalized_host =
      host
      |> Map.take(@host_keys)
      |> expand_state_root(Keyword.get(opts, :home))

    {normalized_host, diagnostics}
  end

  defp validate_host_capacity(capacity) when is_map(capacity) do
    validate_positive_integer_map(capacity, @capacity_keys, :host, "$.host.capacity")
  end

  defp validate_host_capacity(_capacity), do: []

  defp validate_host_scheduling(scheduling) when is_map(scheduling) do
    path = "$.host.scheduling"

    unknown_key_diagnostics(scheduling, @host_scheduling_keys, :host, path) ++
      required_field_diagnostics(scheduling, @host_scheduling_keys, :host, path) ++
      validate_enum_field(
        scheduling,
        "algorithm",
        ["weighted_deficit_round_robin"],
        :host,
        "#{path}.algorithm"
      ) ++
      validate_positive_integer_field(
        scheduling,
        "max_credit_rounds",
        :host,
        "#{path}.max_credit_rounds"
      )
  end

  defp validate_host_scheduling(_scheduling), do: []

  defp validate_tracker_connections(connections) when is_map(connections) do
    empty_map_diagnostics(connections, :host, "$.host.tracker_connections") ++
      (connections
       |> ordered_map_entries()
       |> Enum.with_index()
       |> Enum.flat_map(fn {{id, connection}, index} ->
         path = dynamic_key_path("$.host.tracker_connections", id, index)

         validate_dynamic_id(id, :host, path) ++
           validate_tracker_connection(connection, path)
       end))
  end

  defp validate_tracker_connections(_connections), do: []

  defp validate_tracker_connection(connection, path) when is_map(connection) do
    unknown_key_diagnostics(connection, @connection_keys, :host, path) ++
      required_field_diagnostics(connection, @connection_keys, :host, path) ++
      validate_enum_field(connection, "kind", ["linear"], :host, "#{path}.kind") ++
      validate_https_endpoint(connection, "endpoint", :host, "#{path}.endpoint") ++
      validate_secret_reference(connection, "api_key", :host, "#{path}.api_key")
  end

  defp validate_tracker_connection(_connection, path) do
    [diagnostic(:error, :host, path, :invalid_type, "#{path} must be a map")]
  end

  defp validate_host_runners(runners) when is_map(runners) do
    empty_map_diagnostics(runners, :host, "$.host.runners") ++
      (runners
       |> ordered_map_entries()
       |> Enum.with_index()
       |> Enum.flat_map(fn {{id, runner}, index} ->
         path = dynamic_key_path("$.host.runners", id, index)

         validate_dynamic_id(id, :host, path) ++ validate_host_runner(id, runner, path)
       end))
  end

  defp validate_host_runners(_runners), do: []

  defp validate_host_runner(id, runner, path) when is_map(runner) do
    required_field_diagnostics(runner, @host_runner_limit_keys, :host, path) ++
      Enum.flat_map(@host_runner_limit_keys, fn field ->
        validate_positive_integer_field(runner, field, :host, "#{path}.#{field}")
      end) ++
      config_runner_diagnostics(id, runner, path)
  end

  defp validate_host_runner(_id, _runner, path) do
    [diagnostic(:error, :host, path, :invalid_type, "#{path} must be a map")]
  end

  defp config_runner_diagnostics(id, runner, path) do
    {safe_runner, key_diagnostics} = sanitize_runner_map_keys(runner, path)

    catalog_id =
      if is_binary(id) and Regex.match?(@id_regex, id),
        do: id,
        else: @runner_validation_catalog_id

    config_runner = Map.drop(safe_runner, @host_runner_limit_keys)

    config_diagnostics =
      case ConfigSchema.validate_runner_catalog_detailed(%{catalog_id => config_runner}) do
        {:ok, _normalized_catalog} ->
          []

        {:error, errors} ->
          Enum.map(errors, &translate_config_runner_error(&1, catalog_id, path))
      end

    key_diagnostics ++ config_diagnostics
  end

  defp translate_config_runner_error(%RunnerCatalogError{} = error, catalog_id, path) do
    source_prefix = "runtime.runners.#{catalog_id}"
    path_suffix = String.replace_prefix(error.path, source_prefix, "")
    registry_path = path <> path_suffix

    diagnostic(
      :error,
      :host,
      registry_path,
      error.code,
      "#{registry_path} #{error.detail}"
    )
  end

  defp sanitize_runner_map_keys(value, path) when is_map(value) do
    value
    |> ordered_map_entries()
    |> Enum.with_index()
    |> Enum.reduce({%{}, []}, fn {{key, nested}, index}, {safe_map, diagnostics} ->
      key_path = dynamic_key_path(path, key, index)
      {safe_nested, nested_diagnostics} = sanitize_runner_map_keys(nested, key_path)

      if is_binary(key) do
        {Map.put(safe_map, key, safe_nested), nested_diagnostics ++ diagnostics}
      else
        key_diagnostic =
          diagnostic(
            :error,
            :host,
            key_path,
            :invalid_type,
            "#{key_path} map keys must be strings"
          )

        {safe_map, [key_diagnostic | nested_diagnostics] ++ diagnostics}
      end
    end)
  end

  defp sanitize_runner_map_keys(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {nested, index}, {safe_values, diagnostics} ->
      {safe_nested, nested_diagnostics} = sanitize_runner_map_keys(nested, "#{path}[#{index}]")
      {[safe_nested | safe_values], nested_diagnostics ++ diagnostics}
    end)
    |> then(fn {safe_values, diagnostics} -> {Enum.reverse(safe_values), diagnostics} end)
  end

  defp sanitize_runner_map_keys(value, _path), do: {value, []}

  defp validate_positive_integer_map(map, fields, scope, path) when is_map(map) do
    unknown_key_diagnostics(map, fields, scope, path) ++
      required_field_diagnostics(map, fields, scope, path) ++
      Enum.flat_map(fields, fn field ->
        validate_positive_integer_field(map, field, scope, "#{path}.#{field}")
      end)
  end

  defp validate_positive_integer_map(_map, _fields, _scope, _path), do: []

  defp validate_positive_integer_field(map, field, scope, path) do
    case Map.fetch(map, field) do
      {:ok, value} when is_integer(value) and value > 0 ->
        []

      {:ok, _invalid} ->
        [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a positive integer")]

      :error ->
        []
    end
  end

  defp validate_id_field(map, field, scope, path) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) ->
        if Regex.match?(@id_regex, value) do
          []
        else
          [invalid_id_diagnostic(scope, path)]
        end

      {:ok, _invalid} ->
        [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a string")]

      :error ->
        []
    end
  end

  defp validate_dynamic_id(id, scope, path) when is_binary(id) do
    if Regex.match?(@id_regex, id), do: [], else: [invalid_id_diagnostic(scope, path)]
  end

  defp validate_dynamic_id(_id, scope, path) do
    [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a string")]
  end

  defp validate_enum_field(map, field, allowed, scope, path) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) ->
        if value in allowed do
          []
        else
          allowed_text = Enum.join(allowed, ", ")
          [diagnostic(:error, scope, path, :invalid_value, "#{path} must be one of: #{allowed_text}")]
        end

      {:ok, _invalid} ->
        [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a string")]

      :error ->
        []
    end
  end

  defp validate_https_endpoint(map, field, scope, path) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) ->
        case URI.parse(value) do
          %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> []
          _invalid -> [diagnostic(:error, scope, path, :invalid_value, "#{path} must be an HTTPS URI with a host")]
        end

      {:ok, _invalid} ->
        [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a string")]

      :error ->
        []
    end
  end

  defp validate_secret_reference(map, field, scope, path) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) ->
        if valid_secret_reference?(value) do
          []
        else
          [
            diagnostic(
              :error,
              scope,
              path,
              :invalid_value,
              "#{path} must be an environment or secret-provider reference"
            )
          ]
        end

      {:ok, _invalid} ->
        [diagnostic(:error, scope, path, :invalid_type, "#{path} must be a string")]

      :error ->
        []
    end
  end

  defp valid_secret_reference?(value) do
    Regex.match?(~r/^\$[A-Za-z0-9._-]+$/, value) or
      Regex.match?(~r/^\$\{[A-Za-z0-9._-]+\}$/, value) or
      Regex.match?(
        ~r|^secret://[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$|,
        value
      )
  end

  defp required_map_diagnostics(map, fields, scope, path) do
    Enum.flat_map(fields, fn field ->
      field_path = "#{path}.#{field}"

      case Map.fetch(map, field) do
        :error ->
          [missing_field_diagnostic(scope, field_path)]

        {:ok, value} when is_map(value) ->
          []

        {:ok, _invalid} ->
          [diagnostic(:error, scope, field_path, :invalid_type, "#{field_path} must be a map")]
      end
    end)
  end

  defp required_field_diagnostics(map, fields, scope, path) do
    Enum.flat_map(fields, fn field ->
      if Map.has_key?(map, field) do
        []
      else
        [missing_field_diagnostic(scope, "#{path}.#{field}")]
      end
    end)
  end

  defp unknown_key_diagnostics(map, allowed, scope, path) do
    map
    |> ordered_map_entries()
    |> Enum.with_index()
    |> Enum.reject(fn {{key, _value}, _index} -> key in allowed end)
    |> Enum.map(fn {{key, _value}, index} ->
      key_path = dynamic_key_path(path, key, index)
      diagnostic(:error, scope, key_path, :unknown_key, "#{key_path} is not supported")
    end)
  end

  defp empty_map_diagnostics(map, scope, path) do
    if map_size(map) == 0 do
      [diagnostic(:error, scope, path, :invalid_value, "#{path} must not be empty")]
    else
      []
    end
  end

  defp invalid_id_diagnostic(scope, path) do
    diagnostic(
      :error,
      scope,
      path,
      :invalid_id,
      "#{path} must match ^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"
    )
  end

  defp missing_field_diagnostic(scope, path) do
    diagnostic(:error, scope, path, :missing_required_field, "#{path} is required")
  end

  defp diagnostic(severity, scope, path, code, message) do
    %Diagnostic{
      severity: severity,
      scope: scope,
      path: path,
      code: code,
      message: message
    }
  end

  defp sort_diagnostics(diagnostics) do
    diagnostics
    |> Enum.sort_by(fn diagnostic ->
      {scope_sort_key(diagnostic.scope), diagnostic.path, diagnostic.code, diagnostic.message}
    end)
    |> Enum.uniq()
  end

  defp scope_sort_key(:registry), do: {0, ""}
  defp scope_sort_key(:host), do: {1, ""}
  defp scope_sort_key({:target, id}), do: {2, id}

  defp normalized_state_collision_diagnostics(entries, scope, path) do
    {_seen, diagnostics} =
      Enum.reduce(entries, {MapSet.new(), []}, fn
        {{state, _limit}, index}, {seen, diagnostics} when is_binary(state) ->
          normalized_state = state |> String.trim() |> String.downcase()

          cond do
            normalized_state == "" ->
              {seen, diagnostics}

            MapSet.member?(seen, normalized_state) ->
              state_path = dynamic_key_path(path, state, index)

              diagnostic =
                diagnostic(
                  :error,
                  scope,
                  state_path,
                  :duplicate_key,
                  "#{state_path} collides after trim and lowercase normalization"
                )

              {seen, [diagnostic | diagnostics]}

            true ->
              {MapSet.put(seen, normalized_state), diagnostics}
          end

        _entry, accumulator ->
          accumulator
      end)

    Enum.reverse(diagnostics)
  end

  defp normalized_state_collision?(entries) do
    {_seen, collision?} =
      Enum.reduce(entries, {MapSet.new(), false}, fn
        {state, _limit}, {seen, collision?} when is_binary(state) ->
          normalized_state = state |> String.trim() |> String.downcase()

          if normalized_state == "" do
            {seen, collision?}
          else
            {MapSet.put(seen, normalized_state), collision? or MapSet.member?(seen, normalized_state)}
          end

        _entry, accumulator ->
          accumulator
      end)

    collision?
  end

  defp update_present_field(map, field, fun) do
    case Map.fetch(map, field) do
      {:ok, value} -> Map.put(map, field, fun.(value))
      :error -> map
    end
  end

  defp ordered_map_entries(map) do
    Enum.sort_by(map, fn {key, _value} ->
      {key, :erlang.term_to_binary(key, [:deterministic])}
    end)
  end

  defp state_limit_key_path(path, state, index) when is_binary(state) do
    if String.trim(state) == "", do: indexed_key_path(path, state, index), else: dynamic_key_path(path, state, index)
  end

  defp state_limit_key_path(path, state, index), do: dynamic_key_path(path, state, index)

  defp dynamic_key_path(path, key, _index) when is_binary(key), do: "#{path}.#{key}"
  defp dynamic_key_path(path, key, index), do: indexed_key_path(path, key, index)

  defp indexed_key_path(path, key, index), do: "#{path}[key:#{index}:#{key_type(key)}]"

  defp key_type(key) when is_binary(key), do: "string"
  defp key_type(key) when is_integer(key), do: "integer"
  defp key_type(key) when is_float(key), do: "float"
  defp key_type(key) when is_atom(key), do: "atom"
  defp key_type(key) when is_tuple(key), do: "tuple"
  defp key_type(key) when is_map(key), do: "map"
  defp key_type(key) when is_list(key), do: "list"
  defp key_type(key) when is_pid(key), do: "pid"
  defp key_type(key) when is_reference(key), do: "reference"
  defp key_type(key) when is_function(key), do: "function"
  defp key_type(key) when is_port(key), do: "port"
  defp key_type(key) when is_bitstring(key), do: "bitstring"

  defp error_diagnostic?(diagnostics), do: Enum.any?(diagnostics, &(&1.severity == :error))

  defp expand_state_root(%{"state_root" => "~/"} = host, home) when is_binary(home) do
    Map.put(host, "state_root", home)
  end

  defp expand_state_root(%{"state_root" => "~/" <> rest} = host, home) when is_binary(home) do
    Map.put(host, "state_root", Path.join(home, rest))
  end

  defp expand_state_root(host, _home), do: host
end
