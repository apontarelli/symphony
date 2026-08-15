defmodule SymphonyElixir.TargetRegistry.Validation do
  @moduledoc false

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.TargetRegistry.Diagnostic
  alias SymphonyElixir.TargetRegistry.Snapshot
  alias SymphonyElixir.TargetRegistry.Target

  @gate_operations ~w(tracker_write vcs_publish pull_request_write merge deployment production_data)
  @gate_values ~w(deny manual_approval allow)
  @spec validate(Snapshot.t(), keyword()) :: Snapshot.t()
  def validate(snapshot, opts \\ []) do
    case snapshot do
      %Snapshot{} when is_list(opts) -> validate_snapshot(snapshot, opts)
      _malformed -> snapshot
    end
  end

  defp validate_snapshot(snapshot, opts) do
    {source_targets, target_container_diagnostics} = snapshot_targets(snapshot.targets)
    {host, host_container_diagnostics} = validation_host(snapshot.host)
    context = path_context(snapshot, host, opts)
    eligible_targets = eligible_targets(source_targets)

    targets =
      Map.new(source_targets, fn {id, target} ->
        {id, validate_target(target, host, context)}
      end)

    targets = validate_cross_target_paths(targets)

    global_diagnostics =
      target_container_diagnostics ++
        host_container_diagnostics ++ host_path_diagnostics(context, eligible_targets)

    diagnostics =
      snapshot.diagnostics
      |> diagnostic_list()
      |> Kernel.++(global_diagnostics)
      |> Kernel.++(Enum.flat_map(targets, fn {_id, target} -> target_diagnostic_list(target) end))
      |> sort_diagnostics()

    globally_valid? =
      snapshot.globally_valid? and not error_diagnostic?(global_diagnostics)

    %{snapshot | globally_valid?: globally_valid?, targets: targets, diagnostics: diagnostics}
  end

  @spec effective_gate(Target.t() | map(), String.t()) :: String.t()
  def effective_gate(%Target{configured: configured}, operation),
    do: effective_gate(configured, operation)

  def effective_gate(configured, operation) when is_map(configured) and operation in @gate_operations do
    gates = Map.get(configured, "external_side_effects")

    case if(is_map(gates), do: Map.get(gates, operation), else: nil) do
      value when value in @gate_values -> value
      _missing_or_invalid -> "deny"
    end
  end

  def effective_gate(_configured, _operation), do: "deny"
  defp snapshot_targets(targets) when is_map(targets), do: {targets, []}

  defp snapshot_targets(_targets) do
    path = "$.targets"

    {%{},
     [
       diagnostic(
         :registry,
         path,
         :invalid_snapshot,
         "#{path} must be a map before cross-field validation"
       )
     ]}
  end

  defp validation_host(host) when is_map(host) do
    Enum.reduce(~w(capacity tracker_connections runners), {host, []}, fn field, {validated, diagnostics} ->
      case Map.fetch(validated, field) do
        {:ok, value} when not is_map(value) ->
          path = "$.host.#{field}"

          diagnostic =
            diagnostic(
              :host,
              path,
              :invalid_snapshot,
              "#{path} must contain structurally normalized host data"
            )

          {Map.put(validated, field, %{}), [diagnostic | diagnostics]}

        _missing_or_map ->
          {validated, diagnostics}
      end
    end)
  end

  defp validation_host(_host) do
    path = "$.host"

    {%{},
     [
       diagnostic(
         :host,
         path,
         :invalid_snapshot,
         "#{path} must be a map before cross-field validation"
       )
     ]}
  end

  defp validate_target(%Target{configured: configured} = target, _host, _context)
       when not is_map(configured) do
    path = target_path(target.id)

    add_target_diagnostics(
      target,
      [
        diagnostic(
          {:target, target.id},
          path,
          :invalid_snapshot,
          "#{path} must contain structurally normalized target data"
        )
      ]
    )
  end

  defp validate_target(%Target{} = target, host, context) do
    if normalized_target_maps?(target.configured) do
      diagnostics =
        diagnostic_list(target.diagnostics)
        |> Kernel.++(tracker_reference_diagnostics(target, host))
        |> Kernel.++(runner_reference_diagnostics(target, host))
        |> Kernel.++(linear_scope_diagnostics(target))
        |> Kernel.++(linear_state_diagnostics(target))
        |> Kernel.++(capacity_diagnostics(target, host))
        |> Kernel.++(budget_diagnostics(target))
        |> Kernel.++(target_path_diagnostics(target, context))
        |> sort_diagnostics()

      valid? = target.valid? and not error_diagnostic?(diagnostics)
      effective_state = if valid?, do: target.effective_state, else: :paused

      %{target | valid?: valid?, effective_state: effective_state, diagnostics: diagnostics}
    else
      path = target_path(target.id)

      add_target_diagnostics(
        target,
        [
          diagnostic(
            {:target, target.id},
            path,
            :invalid_snapshot,
            "#{path} must contain structurally normalized target maps"
          )
        ]
      )
    end
  end

  defp validate_target(target, _host, _context), do: target

  defp normalized_target_maps?(configured) do
    top_level_maps? =
      Enum.all?(~w(repo worktree linear runners concurrency budgets), fn field ->
        absent_or_map?(configured, field)
      end)

    top_level_maps? and
      absent_nested_or_map?(configured, "linear", "scope") and
      absent_nested_or_map?(configured, "runners", "settings") and
      absent_nested_or_map?(configured, "concurrency", "by_linear_state") and
      Enum.all?(~w(per_run daily weekly), fn period ->
        absent_nested_or_map?(configured, "budgets", period)
      end)
  end

  defp absent_or_map?(map, field) do
    case Map.fetch(map, field) do
      :error -> true
      {:ok, value} -> is_map(value)
    end
  end

  defp absent_nested_or_map?(map, parent, field) do
    case Map.get(map, parent) do
      parent_map when is_map(parent_map) -> absent_or_map?(parent_map, field)
      _missing_or_invalid -> true
    end
  end

  defp tracker_reference_diagnostics(%Target{id: id, configured: configured}, host)
       when is_map(configured) do
    connection = get_in(configured, ["linear", "connection"])
    connections = Map.get(host, "tracker_connections", %{})

    if is_binary(connection) and is_map(connections) and not Map.has_key?(connections, connection) do
      path = "#{target_path(id)}.linear.connection"
      [diagnostic({:target, id}, path, :unknown_reference, "#{path} must reference a host tracker connection")]
    else
      []
    end
  end

  defp runner_reference_diagnostics(%Target{id: id, configured: configured}, host)
       when is_map(configured) do
    runners = Map.get(configured, "runners", %{})
    host_runners = Map.get(host, "runners", %{})

    if is_map(runners) and is_map(host_runners) do
      scope = {:target, id}
      path = "#{target_path(id)}.runners"
      allowed = Map.get(runners, "allowed", [])
      default = Map.get(runners, "default")
      settings = Map.get(runners, "settings", %{})

      allowed_reference_diagnostics(allowed, host_runners, scope, path) ++
        default_runner_diagnostics(default, allowed, host_runners, scope, path) ++
        setting_reference_diagnostics(settings, allowed, host_runners, scope, path)
    else
      []
    end
  end

  defp allowed_reference_diagnostics(allowed, host_runners, scope, path) when is_list(allowed) do
    allowed
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {runner, index} when is_binary(runner) ->
        if Map.has_key?(host_runners, runner) do
          []
        else
          item_path = "#{path}.allowed[#{index}]"
          [diagnostic(scope, item_path, :unknown_reference, "#{item_path} must reference a host runner")]
        end

      _invalid ->
        []
    end)
  end

  defp allowed_reference_diagnostics(_allowed, _host_runners, _scope, _path), do: []

  defp default_runner_diagnostics(default, allowed, host_runners, scope, path)
       when is_binary(default) and is_list(allowed) do
    not_allowed =
      if default in allowed do
        []
      else
        default_path = "#{path}.default"

        [
          diagnostic(
            scope,
            default_path,
            :runner_not_allowed,
            "#{default_path} must be a member of #{path}.allowed"
          )
        ]
      end

    unknown =
      if Map.has_key?(host_runners, default) do
        []
      else
        default_path = "#{path}.default"
        [diagnostic(scope, default_path, :unknown_reference, "#{default_path} must reference a host runner")]
      end

    not_allowed ++ unknown
  end

  defp default_runner_diagnostics(_default, _allowed, _host_runners, _scope, _path), do: []

  defp setting_reference_diagnostics(settings, allowed, host_runners, scope, path)
       when is_map(settings) and is_list(allowed) and is_map(host_runners) do
    settings
    |> ordered_map_entries()
    |> Enum.with_index()
    |> Enum.flat_map(fn {{runner, _setting}, index} ->
      setting_path = dynamic_key_path("#{path}.settings", runner, index)

      not_allowed =
        if runner in allowed do
          []
        else
          [
            diagnostic(
              scope,
              setting_path,
              :runner_not_allowed,
              "#{setting_path} is only valid for a runner in #{path}.allowed"
            )
          ]
        end

      unknown =
        if Map.has_key?(host_runners, runner) do
          []
        else
          [
            diagnostic(
              scope,
              setting_path,
              :unknown_reference,
              "#{setting_path} must reference a host runner"
            )
          ]
        end

      not_allowed ++ unknown
    end)
  end

  defp setting_reference_diagnostics(_settings, _allowed, _host_runners, _scope, _path), do: []

  defp ordered_map_entries(map) do
    Enum.sort_by(map, fn {key, _value} ->
      {key, :erlang.term_to_binary(key, [:deterministic])}
    end)
  end

  defp dynamic_key_path(path, key, _index) when is_binary(key), do: "#{path}.#{key}"
  defp dynamic_key_path(path, key, index), do: "#{path}[key:#{index}:#{key_type(key)}]"

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

  defp linear_scope_diagnostics(%Target{id: id, configured: configured}) when is_map(configured) do
    scope_map = get_in(configured, ["linear", "scope"])

    if is_map(scope_map) do
      scope = {:target, id}
      path = "#{target_path(id)}.linear.scope"
      type = Map.get(scope_map, "type")
      project_selectors = present_fields(scope_map, ~w(project_id project_slug))

      cond do
        length(project_selectors) > 1 ->
          selector_path = "#{path}.project_slug"

          [
            diagnostic(
              scope,
              selector_path,
              :scope_exclusivity,
              "#{selector_path} cannot be combined with #{path}.project_id"
            )
          ]

        length(selector_families(scope_map)) != 1 ->
          [
            diagnostic(
              scope,
              path,
              :scope_exclusivity,
              "#{path} must contain exactly one selector family"
            )
          ]

        scope_family(scope_map) != type ->
          type_path = "#{path}.type"

          [
            diagnostic(
              scope,
              type_path,
              :scope_mismatch,
              "#{type_path} must match the configured selector family"
            )
          ]

        true ->
          []
      end
    else
      []
    end
  end

  defp selector_families(scope) do
    [
      {"project", ~w(project_id project_slug)},
      {"team", ["team_key"]},
      {"query", ["query_file"]},
      {"issues", ["issue_ids"]}
    ]
    |> Enum.filter(fn {_family, fields} -> present_fields(scope, fields) != [] end)
  end

  defp scope_family(scope) do
    [{family, _fields}] = selector_families(scope)
    family
  end

  defp present_fields(map, fields) do
    Enum.filter(fields, fn
      "issue_ids" -> valid_issue_ids?(Map.get(map, "issue_ids"))
      field -> valid_selector_string?(Map.get(map, field))
    end)
  end

  defp valid_selector_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_selector_string?(_value), do: false

  defp valid_issue_ids?([]), do: false
  defp valid_issue_ids?(values) when is_list(values), do: Enum.all?(values, &valid_selector_string?/1)
  defp valid_issue_ids?(_value), do: false

  defp linear_state_diagnostics(%Target{id: id, configured: configured}) when is_map(configured) do
    linear = Map.get(configured, "linear", %{})
    active = Map.get(linear, "active_states")
    terminal = Map.get(linear, "terminal_states")

    if is_list(active) and is_list(terminal) do
      overlap =
        active
        |> normalized_strings()
        |> MapSet.intersection(normalized_strings(terminal))
        |> MapSet.to_list()
        |> Enum.sort()

      if overlap == [] do
        []
      else
        path = "#{target_path(id)}.linear.terminal_states"

        [
          diagnostic(
            {:target, id},
            path,
            :state_overlap,
            "#{path} overlaps active states: #{Enum.join(overlap, ", ")}"
          )
        ]
      end
    else
      []
    end
  end

  defp normalized_strings(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp capacity_diagnostics(%Target{id: id, configured: configured}, host)
       when is_map(configured) and is_map(host) do
    concurrency = Map.get(configured, "concurrency", %{})
    target_runners = Map.get(configured, "runners", %{})
    host_capacity = Map.get(host, "capacity", %{})
    host_runners = Map.get(host, "runners", %{})
    runner_capacities = selectable_runner_capacities(target_runners, host_runners)
    capacities = [host_capacity | runner_capacities]
    scope = {:target, id}
    path = "#{target_path(id)}.concurrency"

    if is_map(concurrency) do
      ceiling_diagnostic(
        concurrency,
        "max_concurrent_agents",
        integer_ceiling(capacities, "max_concurrent_agents"),
        scope,
        path
      ) ++
        ceiling_diagnostic(
          concurrency,
          "max_concurrent_startups",
          integer_ceiling(capacities, "max_concurrent_startups"),
          scope,
          path
        ) ++
        ceiling_diagnostic(
          concurrency,
          "max_concurrent_reviewers",
          positive_integer(Map.get(host_capacity, "max_concurrent_reviewers")),
          scope,
          path
        ) ++
        state_ceiling_diagnostics(concurrency, scope, path)
    else
      []
    end
  end

  defp selectable_runner_capacities(target_runners, host_runners) do
    case Map.get(target_runners, "allowed") do
      allowed when is_list(allowed) ->
        Enum.flat_map(allowed, &runner_capacity(&1, host_runners))

      _missing_or_invalid ->
        []
    end
  end

  defp runner_capacity(runner, host_runners) when is_binary(runner) do
    case Map.fetch(host_runners, runner) do
      {:ok, capacity} when is_map(capacity) -> [capacity]
      _missing_or_invalid -> []
    end
  end

  defp runner_capacity(_structurally_invalid, _host_runners), do: []

  defp integer_ceiling(capacities, field) do
    Enum.reduce(capacities, nil, fn capacity, ceiling ->
      case positive_integer(Map.get(capacity, field)) do
        nil -> ceiling
        value when is_nil(ceiling) or value < ceiling -> value
        _value -> ceiling
      end
    end)
  end

  defp ceiling_diagnostic(concurrency, field, ceiling, scope, path)
       when is_integer(ceiling) do
    value = Map.get(concurrency, field)

    if is_integer(value) and value > ceiling do
      field_path = "#{path}.#{field}"

      [
        diagnostic(
          scope,
          field_path,
          :capacity_exceeded,
          "#{field_path} must not exceed effective ceiling #{ceiling}"
        )
      ]
    else
      []
    end
  end

  defp ceiling_diagnostic(_concurrency, _field, _ceiling, _scope, _path), do: []

  defp state_ceiling_diagnostics(concurrency, scope, path) do
    limit = positive_integer(Map.get(concurrency, "max_concurrent_agents"))
    state_limits = Map.get(concurrency, "by_linear_state", %{})

    if is_integer(limit) and is_map(state_limits) do
      state_limits
      |> Enum.sort_by(fn {state, _value} -> inspect(state) end)
      |> Enum.flat_map(fn
        {state, value} when is_binary(state) and is_integer(value) and value > limit ->
          state_path = "#{path}.by_linear_state.#{state}"

          [
            diagnostic(
              scope,
              state_path,
              :capacity_exceeded,
              "#{state_path} must not exceed #{path}.max_concurrent_agents (#{limit})"
            )
          ]

        _valid_or_structurally_invalid ->
          []
      end)
    else
      []
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp budget_diagnostics(%Target{id: id, configured: configured}) when is_map(configured) do
    budgets = Map.get(configured, "budgets", %{})

    if is_map(budgets) do
      scope = {:target, id}
      path = "#{target_path(id)}.budgets"

      budget_order_diagnostic(budgets, "per_run", "daily", scope, path) ++
        budget_order_diagnostic(budgets, "daily", "weekly", scope, path)
    else
      []
    end
  end

  defp budget_order_diagnostic(budgets, lower_period, upper_period, scope, path) do
    lower = get_in(budgets, [lower_period, "max_total_tokens"])
    upper = get_in(budgets, [upper_period, "max_total_tokens"])

    if is_integer(lower) and is_integer(upper) and lower > upper do
      upper_path = "#{path}.#{upper_period}.max_total_tokens"

      [
        diagnostic(
          scope,
          upper_path,
          :budget_order,
          "#{upper_path} must be at least #{path}.#{lower_period}.max_total_tokens (#{lower})"
        )
      ]
    else
      []
    end
  end

  defp path_context(snapshot, host, opts) do
    registry_path = snapshot.path || Keyword.get(opts, :registry_path)
    state_root = Map.get(host, "state_root")

    %{
      registry_dir: registry_path |> parent_path() |> canonical_path(),
      state_path: state_root,
      state_root: canonical_path(state_root)
    }
  end

  defp parent_path(path) when is_binary(path), do: Path.dirname(Path.expand(path))
  defp parent_path(_path), do: nil

  defp eligible_targets(targets) when is_map(targets) do
    targets
    |> Enum.filter(fn {_id, target} ->
      is_struct(target, Target) and target.valid? and is_map(target.configured)
    end)
    |> Map.new()
  end

  defp host_path_diagnostics(context, eligible_targets) do
    path = "$.host.state_root"

    cond do
      not is_binary(context.state_path) or Path.type(context.state_path) != :absolute ->
        [diagnostic(:host, path, :unsafe_path, "#{path} must be absolute")]

      not is_binary(context.state_root) ->
        [diagnostic(:host, path, :unsafe_path, "#{path} could not be canonicalized")]

      true ->
        overlaps =
          [{"registry directory", context.registry_dir} | target_root_entries(eligible_targets)]
          |> Enum.filter(fn {_name, root} ->
            is_binary(root) and paths_overlap?(context.state_root, root)
          end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort()

        if overlaps == [] do
          []
        else
          [
            diagnostic(
              :host,
              path,
              :path_overlap,
              "#{path} overlaps #{Enum.join(overlaps, ", ")}"
            )
          ]
        end
    end
  end

  defp target_root_entries(targets) do
    targets
    |> Enum.sort_by(fn {id, _target} -> id end)
    |> Enum.flat_map(fn {id, target} ->
      [
        {"#{target_path(id)}.repo.path", safe_absolute_canonical(get_in(target.configured, ["repo", "path"]))},
        {"#{target_path(id)}.worktree.root", safe_absolute_canonical(get_in(target.configured, ["worktree", "root"]))}
      ]
    end)
  end

  defp safe_absolute_canonical(path) when is_binary(path) do
    if Path.type(path) == :absolute, do: canonical_path(path), else: nil
  end

  defp safe_absolute_canonical(_path), do: nil

  defp target_path_diagnostics(%Target{id: id, configured: configured}, context)
       when is_map(configured) do
    repo_path = get_in(configured, ["repo", "path"])
    worktree_path = get_in(configured, ["worktree", "root"])
    manifest = get_in(configured, ["repo", "manifest"])
    query_file = get_in(configured, ["linear", "scope", "query_file"])
    repo = canonical_path(repo_path)
    worktree = canonical_path(worktree_path)
    scope = {:target, id}
    root_path = target_path(id)

    root_path_diagnostics(repo_path, repo, true, scope, "#{root_path}.repo.path") ++
      root_path_diagnostics(
        worktree_path,
        worktree,
        false,
        scope,
        "#{root_path}.worktree.root"
      ) ++
      contained_file_diagnostics(
        repo_path,
        repo,
        manifest,
        scope,
        "#{root_path}.repo.manifest"
      ) ++
      contained_file_diagnostics(
        repo_path,
        repo,
        query_file,
        scope,
        "#{root_path}.linear.scope.query_file"
      ) ++
      overlap_diagnostics(
        worktree,
        [
          {"repository root", repo},
          {"host state root", context.state_root},
          {"registry directory", context.registry_dir}
        ],
        scope,
        "#{root_path}.worktree.root"
      ) ++
      overlap_diagnostics(
        repo,
        [
          {"host state root", context.state_root},
          {"registry directory", context.registry_dir}
        ],
        scope,
        "#{root_path}.repo.path"
      )
  end

  defp root_path_diagnostics(raw_path, canonical, require_directory?, scope, path) do
    cond do
      is_nil(raw_path) ->
        []

      not is_binary(raw_path) ->
        [diagnostic(scope, path, :unsafe_path, "#{path} must be an absolute path string")]

      Path.type(raw_path) != :absolute ->
        [diagnostic(scope, path, :unsafe_path, "#{path} must be absolute")]

      not is_binary(canonical) ->
        [diagnostic(scope, path, :unsafe_path, "#{path} could not be canonicalized")]

      require_directory? and not File.dir?(canonical) ->
        [diagnostic(scope, path, :unsafe_path, "#{path} must name an existing directory")]

      true ->
        []
    end
  end

  defp contained_file_diagnostics(_repo_path, _repo, nil, _scope, _path), do: []

  defp contained_file_diagnostics(repo_path, repo, relative_path, scope, path)
       when is_binary(repo_path) and is_binary(repo) and is_binary(relative_path) do
    if safe_relative_path?(relative_path) do
      candidate = canonical_path(Path.join(repo_path, relative_path))

      cond do
        not is_binary(candidate) ->
          [diagnostic(scope, path, :unsafe_path, "#{path} could not be canonicalized")]

        not strict_descendant?(candidate, repo) ->
          [diagnostic(scope, path, :unsafe_path, "#{path} resolves outside the repository root")]

        not File.regular?(candidate) ->
          [diagnostic(scope, path, :unsafe_path, "#{path} must name an existing regular file")]

        true ->
          []
      end
    else
      [diagnostic(scope, path, :unsafe_path, "#{path} must be a traversal-free relative path")]
    end
  end

  defp contained_file_diagnostics(_repo_path, _repo, _relative_path, _scope, _path), do: []

  defp safe_relative_path?(path) do
    Path.type(path) == :relative and
      path != "" and
      not Enum.any?(Path.split(path), &(&1 in [".", ".."]))
  end

  defp strict_descendant?(path, root) do
    path != root and prefix?(Path.split(path), Path.split(root))
  end

  defp overlap_diagnostics(path, candidates, scope, diagnostic_path) when is_binary(path) do
    overlaps =
      candidates
      |> Enum.filter(fn {_name, candidate} -> is_binary(candidate) and paths_overlap?(path, candidate) end)
      |> Enum.map(&elem(&1, 0))

    if overlaps == [] do
      []
    else
      [
        diagnostic(
          scope,
          diagnostic_path,
          :path_overlap,
          "#{diagnostic_path} overlaps #{Enum.join(overlaps, ", ")}"
        )
      ]
    end
  end

  defp overlap_diagnostics(_path, _candidates, _scope, _diagnostic_path), do: []

  defp paths_overlap?(left, right) do
    left_segments = Path.split(left)
    right_segments = Path.split(right)
    prefix?(left_segments, right_segments) or prefix?(right_segments, left_segments)
  end

  defp prefix?(_segments, []), do: true
  defp prefix?([], _prefix), do: false
  defp prefix?([segment | segments], [segment | prefix]), do: prefix?(segments, prefix)
  defp prefix?(_segments, _prefix), do: false

  defp canonical_path(path) when is_binary(path) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical} -> canonical
      {:error, _reason} -> nil
    end
  end

  defp canonical_path(_path), do: nil

  defp validate_cross_target_paths(targets) do
    entries =
      targets
      |> Enum.filter(fn {_id, target} -> is_struct(target, Target) and target.valid? end)
      |> Enum.map(fn {id, target} ->
        repo = canonical_path(get_in(target.configured, ["repo", "path"]))
        worktree = canonical_path(get_in(target.configured, ["worktree", "root"]))
        {id, target, repo, worktree}
      end)
      |> Enum.sort_by(fn {id, _target, _repo, _worktree} -> id end)

    diagnostics_by_target = cross_target_diagnostics(entries, %{})

    Map.new(targets, fn {id, target} ->
      diagnostics = Map.get(diagnostics_by_target, id, [])
      {id, add_target_diagnostics(target, diagnostics)}
    end)
  end

  defp cross_target_diagnostics([], diagnostics), do: diagnostics

  defp cross_target_diagnostics([entry | rest], diagnostics) do
    diagnostics =
      Enum.reduce(rest, diagnostics, fn other_entry, acc ->
        pair_path_diagnostics(entry, other_entry, acc)
      end)

    cross_target_diagnostics(rest, diagnostics)
  end

  defp pair_path_diagnostics({left_id, _left, left_repo, left_worktree}, {right_id, _right, right_repo, right_worktree}, diagnostics) do
    diagnostics
    |> add_pair_overlap(left_id, left_worktree, "worktree.root", right_id, right_worktree, "worktree.root")
    |> add_pair_overlap(left_id, left_worktree, "worktree.root", right_id, right_repo, "repo.path")
    |> add_pair_overlap(left_id, left_repo, "repo.path", right_id, right_worktree, "worktree.root")
  end

  defp add_pair_overlap(diagnostics, left_id, left_path, left_field, right_id, right_path, right_field)
       when is_binary(left_path) and is_binary(right_path) do
    if paths_overlap?(left_path, right_path) do
      diagnostics
      |> add_cross_target_diagnostic(left_id, left_field, right_id, right_field)
      |> add_cross_target_diagnostic(right_id, right_field, left_id, left_field)
    else
      diagnostics
    end
  end

  defp add_cross_target_diagnostic(diagnostics, id, field, other_id, other_field) do
    path = "#{target_path(id)}.#{field}"

    diagnostic =
      diagnostic(
        {:target, id},
        path,
        :path_overlap,
        "#{path} overlaps #{target_path(other_id)}.#{other_field}"
      )

    Map.update(diagnostics, id, [diagnostic], &[diagnostic | &1])
  end

  defp add_target_diagnostics(%Target{} = target, []), do: target

  defp add_target_diagnostics(%Target{} = target, diagnostics) do
    diagnostics = sort_diagnostics(diagnostic_list(target.diagnostics) ++ diagnostics)
    %{target | valid?: false, effective_state: :paused, diagnostics: diagnostics}
  end

  defp add_target_diagnostics(target, _diagnostics), do: target

  defp diagnostic(scope, path, code, message) do
    %Diagnostic{severity: :error, scope: scope, path: path, code: code, message: message}
  end

  defp target_path(id) when is_binary(id), do: "$.targets.#{id}"
  defp target_path(id), do: "$.targets[#{inspect(id)}]"

  defp diagnostic_list(diagnostics) when is_list(diagnostics), do: diagnostics
  defp diagnostic_list(_diagnostics), do: []

  defp target_diagnostic_list(%Target{diagnostics: diagnostics}), do: diagnostic_list(diagnostics)
  defp target_diagnostic_list(_target), do: []

  defp error_diagnostic?(diagnostics), do: Enum.any?(diagnostics, &(&1.severity == :error))

  defp sort_diagnostics(diagnostics) do
    diagnostics
    |> Enum.filter(&is_struct(&1, Diagnostic))
    |> Enum.sort_by(fn diagnostic ->
      {scope_sort_key(diagnostic.scope), diagnostic.path, diagnostic.code, diagnostic.message}
    end)
    |> Enum.uniq()
  end

  defp scope_sort_key(:registry), do: {0, ""}
  defp scope_sort_key(:host), do: {1, ""}
  defp scope_sort_key({:target, id}), do: {2, id}
  defp scope_sort_key(scope), do: {3, inspect(scope)}
end
