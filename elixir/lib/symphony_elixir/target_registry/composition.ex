defmodule SymphonyElixir.TargetRegistry.Composition do
  @moduledoc false

  alias SymphonyElixir.TargetRegistry.Diagnostic
  alias SymphonyElixir.TargetRegistry.Schema
  alias SymphonyElixir.TargetRegistry.Snapshot
  alias SymphonyElixir.TargetRegistry.Target
  alias SymphonyElixir.TargetRegistry.Validation
  alias SymphonyElixir.Workflow.Manifest
  alias SymphonyElixir.Workflow.PublishTarget

  @composition_codes [
    :execution_profile_name_collision,
    :manifest_invalid,
    :manifest_not_found,
    :repository_mismatch
  ]
  @safe_runner_setting_keys ~w(model reasoning_effort max_turns)
  @safe_execution_profile_keys ~w(model reasoning_effort)
  @safe_reasoning_efforts ~w(minimal none low medium high xhigh max)
  @normalized_manifest_map_fields ~w(
    project
    workflow
    docs
    validation
    vcs
    delivery
    automation
    harness
    capabilities
    issue_markers
  )
  @module_resolution_projection_fields ~w(module_names module_refs policy_hash rendered)
  @normalized_validation_command_fields ~w(command name)

  @spec compose(Snapshot.t()) :: Snapshot.t()
  def compose(%Snapshot{} = snapshot), do: compose(snapshot, [])

  @spec compose(Snapshot.t(), keyword()) :: Snapshot.t()
  def compose(%Snapshot{globally_valid?: true, host: host, targets: targets} = snapshot, opts)
      when is_map(host) and is_map(targets) and is_list(opts) do
    manifest_adapter = Keyword.get(opts, :manifest, Manifest)
    targets = Map.new(targets, &compose_target_entry(&1, host, manifest_adapter))
    diagnostics = merge_diagnostics(snapshot.diagnostics, targets)
    %{snapshot | targets: targets, diagnostics: diagnostics}
  end

  def compose(%Snapshot{} = snapshot, _opts), do: snapshot

  @spec canonical_hash(term()) ::
          {:ok, SymphonyElixir.TargetRegistry.generation()} | {:error, :not_json_safe}
  def canonical_hash(term) do
    if json_safe_string_map?(term) do
      encoded = canonical_json(term)
      digest = :crypto.hash(:sha256, encoded)
      {:ok, "sha256:" <> Base.encode16(digest, case: :lower)}
    else
      {:error, :not_json_safe}
    end
  end

  @spec verify_composed_target(Snapshot.t(), String.t()) ::
          :ok | {:error, :invalid_composed_target}
  def verify_composed_target(snapshot, target_id) do
    case verify_composed_target_authority(snapshot, target_id) do
      :ok -> :ok
      _invalid -> {:error, :invalid_composed_target}
    end
  rescue
    _exception -> {:error, :invalid_composed_target}
  catch
    _kind, _reason -> {:error, :invalid_composed_target}
  end

  defp verify_composed_target_authority(
         %Snapshot{
           version: 1,
           globally_valid?: true,
           host: host,
           targets: targets,
           diagnostics: diagnostics
         } = snapshot,
         target_id
       )
       when is_binary(target_id) and is_map(host) and is_map(targets) do
    with true <- diagnostic_list_valid?(diagnostics),
         {:ok, configured_targets} <- configured_targets(targets),
         true <- target_diagnostic_lists_valid?(targets),
         {:ok, %Target{} = target} <- Map.fetch(targets, target_id),
         true <- selected_target_valid?(target),
         {:ok, structured} <-
           Schema.validate(
             %{"version" => 1, "host" => host, "targets" => configured_targets},
             home: "/"
           ),
         validated = Validation.validate(structured, registry_path: snapshot.path),
         true <- validated.globally_valid?,
         true <- validated.host == host,
         {:ok, %Target{} = validated_target} <- Map.fetch(validated.targets, target_id),
         true <- selected_target_parity?(target, validated_target),
         true <- selected_diagnostics_coherent?(diagnostics, target_id, target.diagnostics),
         true <- global_diagnostics_coherent?(diagnostics, validated.diagnostics),
         :ok <- validate_compiled_manifest(target.repo_manifest),
         {:ok, resolution} <- selected_module_resolution(target.effective_policy),
         {:ok, projected_resolution} <- project_module_resolution(resolution),
         true <- projected_resolution == resolution,
         {:ok, expected_policy} <-
           effective_policy(validated_target, host, target.repo_manifest, projected_resolution),
         true <- expected_policy == target.effective_policy,
         {:ok, expected_hash} <- policy_hash(expected_policy),
         true <- expected_hash == target.policy_hash do
      :ok
    else
      _invalid -> :error
    end
  end

  defp verify_composed_target_authority(_snapshot, _target_id), do: :error

  defp configured_targets(targets) do
    Enum.reduce_while(targets, {:ok, %{}}, fn
      {id, %Target{configured: configured}}, {:ok, document} when is_map(configured) ->
        {:cont, {:ok, Map.put(document, id, configured)}}

      _entry, _accumulator ->
        {:halt, :error}
    end)
  end

  defp target_diagnostic_lists_valid?(targets) do
    Enum.all?(targets, fn {_id, %Target{diagnostics: diagnostics}} ->
      diagnostic_list_valid?(diagnostics)
    end)
  end

  defp diagnostic_list_valid?([]), do: true

  defp diagnostic_list_valid?([%Diagnostic{} | rest]),
    do: diagnostic_list_valid?(rest)

  defp diagnostic_list_valid?(_diagnostics), do: false

  defp selected_target_valid?(%Target{valid?: valid?, diagnostics: diagnostics}) do
    valid? == true and not Enum.any?(diagnostics, &(&1.severity == :error))
  end

  defp selected_target_parity?(target, validated_target) do
    fields = [
      :id,
      :configured,
      :configured_state,
      :effective_state,
      :dispatch_mode,
      :valid?,
      :diagnostics
    ]

    Map.take(target, fields) == Map.take(validated_target, fields)
  end

  defp selected_diagnostics_coherent?(snapshot_diagnostics, target_id, target_diagnostics) do
    Enum.filter(snapshot_diagnostics, &(&1.scope == {:target, target_id})) == target_diagnostics
  end

  defp global_diagnostics_coherent?(snapshot_diagnostics, validated_diagnostics) do
    global = fn diagnostics -> Enum.filter(diagnostics, &(&1.scope in [:registry, :host])) end
    global.(snapshot_diagnostics) == global.(validated_diagnostics)
  end

  defp selected_module_resolution(%{
         "repo_policy" => %{"workflow_module_resolution" => resolution}
       })
       when is_map(resolution),
       do: {:ok, resolution}

  defp selected_module_resolution(_policy), do: :error

  defp compose_target_entry({id, %Target{} = target}, host, manifest_adapter) do
    case prepare_target(target) do
      {:ok, prepared} -> {id, compose_target(prepared, host, manifest_adapter)}
      :skip -> {id, target}
    end
  end

  defp compose_target_entry(entry, _host, _manifest_adapter), do: entry

  defp compose_target(target, host, manifest_adapter) do
    repo_path = get_in(target.configured, ["repo", "path"])
    manifest_name = get_in(target.configured, ["repo", "manifest"])
    manifest_path = Path.join(repo_path, manifest_name)

    with {:ok, manifest} <- read_manifest(manifest_adapter, manifest_path),
         :ok <- validate_manifest(manifest_adapter, repo_path, manifest),
         {:ok, compiled} <- compile_manifest(manifest_adapter, manifest),
         {:ok, repo_manifest, module_resolution} <- compiled_policy(compiled),
         :ok <- validate_target_policy_inputs(target),
         :ok <- validate_repository_identity(target, repo_manifest),
         {:ok, effective_policy} <- effective_policy(target, host, repo_manifest, module_resolution),
         {:ok, policy_hash} <- policy_hash(effective_policy) do
      %{
        target
        | repo_manifest: repo_manifest,
          effective_policy: effective_policy,
          policy_hash: policy_hash
      }
    else
      {:manifest_not_found, _path, _reason} ->
        quarantine(target, [
          manifest_diagnostic(
            target,
            :manifest_not_found,
            "current repository manifest #{manifest_name} is missing"
          )
        ])

      :manifest_parse_error ->
        quarantine(target, [manifest_diagnostic(target, :manifest_invalid, "current repository manifest is invalid YAML")])

      {:semantic_errors, stage, errors} ->
        case manifest_diagnostics(target, errors) do
          {:ok, diagnostics} ->
            quarantine(target, diagnostics)

          :error ->
            quarantine(target, [
              manifest_diagnostic(
                target,
                :manifest_invalid,
                "current repository manifest #{stage} returned malformed semantic errors"
              )
            ])
        end

      {:manifest_invalid, message} ->
        quarantine(target, [manifest_diagnostic(target, :manifest_invalid, message)])

      {:composition_error, path, code, message} ->
        quarantine(target, [target_diagnostic(target, path, code, message)])

      {:error, %Diagnostic{} = diagnostic} ->
        quarantine(target, [diagnostic])
    end
  end

  defp read_manifest(manifest_adapter, manifest_path) do
    case invoke_manifest(manifest_adapter, :read, [manifest_path, [repo_setup?: true]]) do
      {:ok, {:ok, manifest}} when is_map(manifest) ->
        if normalized_manifest?(manifest),
          do: {:ok, manifest},
          else: {:manifest_invalid, "current repository manifest read returned an invalid result"}

      {:ok, {:error, {:missing_manifest_file, path, reason}}} ->
        {:manifest_not_found, path, reason}

      {:ok, {:error, {:manifest_parse_error, _reason}}} ->
        :manifest_parse_error

      {:ok, {:error, {:invalid_manifest, errors}}} ->
        {:semantic_errors, "read", errors}

      {:ok, _unexpected} ->
        {:manifest_invalid, "current repository manifest read returned an invalid result"}

      :exception ->
        {:manifest_invalid, "current repository manifest read failed"}
    end
  end

  defp validate_manifest(manifest_adapter, repo_path, manifest) do
    case invoke_manifest(manifest_adapter, :validate, [repo_path, manifest]) do
      {:ok, %{errors: errors, modules: modules, preset: preset}}
      when is_list(errors) and is_list(modules) and is_binary(preset) ->
        if errors == [], do: :ok, else: {:semantic_errors, "validation", errors}

      {:ok, _unexpected} ->
        {:manifest_invalid, "current repository manifest validation returned an invalid result"}

      :exception ->
        {:manifest_invalid, "current repository manifest validation failed"}
    end
  end

  defp compile_manifest(manifest_adapter, manifest) do
    case invoke_manifest(manifest_adapter, :compile, [manifest]) do
      {:ok, compiled} when is_map(compiled) ->
        {:ok, compiled}

      {:ok, _unexpected} ->
        {:manifest_invalid, "current repository manifest compilation returned an invalid result"}

      :exception ->
        {:manifest_invalid, "current repository manifest compilation failed"}
    end
  end

  defp invoke_manifest(manifest_adapter, function, arguments) do
    {:ok, apply(manifest_adapter, function, arguments)}
  rescue
    _exception -> :exception
  end

  defp compiled_policy(%{
         config: %{"manifest" => repo_manifest},
         workflow_module_resolution: module_resolution
       })
       when is_map(repo_manifest) and is_map(module_resolution) do
    with :ok <- validate_compiled_manifest(repo_manifest),
         {:ok, projected_resolution} <- project_module_resolution(module_resolution) do
      {:ok, repo_manifest, projected_resolution}
    else
      _invalid -> invalid_compiled_policy()
    end
  end

  defp compiled_policy(_compiled), do: invalid_compiled_policy()

  defp invalid_compiled_policy do
    {:manifest_invalid, "current repository manifest compiled result has an invalid shape"}
  end

  defp normalized_manifest?(manifest), do: validate_compiled_manifest(manifest) == :ok

  defp validate_compiled_manifest(manifest) when is_map(manifest) do
    auto_land = Map.get(manifest, "auto_land")

    if is_integer(manifest["version"]) and manifest["version"] > 0 and
         Enum.all?(@normalized_manifest_map_fields, &is_map(manifest[&1])) and
         nonempty_string?(get_in(manifest, ["project", "repository"])) and
         string_list?(get_in(manifest, ["issue_markers", "labels"])) and
         valid_validation_commands?(get_in(manifest, ["validation", "commands"])) and
         valid_auto_land?(auto_land) and json_safe_string_map?(manifest) do
      :ok
    else
      :error
    end
  end

  defp valid_auto_land?(nil), do: true

  defp valid_auto_land?(auto_land) when is_map(auto_land) do
    string_list?(Map.get(auto_land, "required_checks", [])) and
      string_list?(Map.get(auto_land, "force_human_review_paths", []))
  end

  defp valid_auto_land?(_auto_land), do: false

  defp valid_validation_commands?([]), do: true

  defp valid_validation_commands?([command | rest]),
    do: valid_validation_command?(command) and valid_validation_commands?(rest)

  defp valid_validation_commands?(_commands), do: false

  defp valid_validation_command?(command) when is_map(command) do
    Enum.sort(Map.keys(command)) == @normalized_validation_command_fields and
      nonempty_string?(command["name"]) and
      nonempty_string?(command["command"]) and
      json_safe_string_map?(command)
  end

  defp valid_validation_command?(_command), do: false

  defp project_module_resolution(resolution) do
    with true <- json_key_domain?(resolution),
         {:ok, module_names} <- resolution_field(resolution, "module_names"),
         true <- string_list?(module_names),
         {:ok, module_refs} <- resolution_field(resolution, "module_refs"),
         {:ok, projected_refs} <- project_module_refs(module_refs),
         true <- Enum.map(projected_refs, & &1["name"]) == module_names,
         {:ok, policy_hash} <- resolution_field(resolution, "policy_hash"),
         true <- valid_utf8_binary?(policy_hash),
         {:ok, rendered} <- resolution_field(resolution, "rendered"),
         true <- valid_utf8_binary?(rendered) do
      values = [module_names, projected_refs, policy_hash, rendered]
      {:ok, Map.new(Enum.zip(@module_resolution_projection_fields, values))}
    else
      _invalid -> :error
    end
  end

  defp project_module_refs(refs) when is_list(refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, projected} ->
      case project_module_ref(ref) do
        {:ok, value} -> {:cont, {:ok, [value | projected]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      :error -> :error
    end
  end

  defp project_module_refs(_refs), do: :error

  defp project_module_ref(ref) when is_map(ref) do
    with true <- json_key_domain?(ref),
         {:ok, name} <- resolution_field(ref, "name"),
         true <- nonempty_string?(name),
         {:ok, version} <- resolution_field(ref, "version"),
         true <- nonempty_string?(version) do
      {:ok, %{"name" => name, "version" => version}}
    else
      _invalid -> :error
    end
  end

  defp project_module_ref(_ref), do: :error

  defp resolution_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, resolution_atom_key(key))
    end
  end

  defp resolution_atom_key("module_names"), do: :module_names
  defp resolution_atom_key("module_refs"), do: :module_refs
  defp resolution_atom_key("policy_hash"), do: :policy_hash
  defp resolution_atom_key("rendered"), do: :rendered
  defp resolution_atom_key("name"), do: :name
  defp resolution_atom_key("version"), do: :version

  defp validate_target_policy_inputs(target) do
    if string_list?(get_in(target.configured, ["linear", "required_labels"])) do
      :ok
    else
      {:composition_error, "linear.required_labels", :manifest_invalid, "current target policy inputs have an invalid shape"}
    end
  end

  defp validate_repository_identity(target, repo_manifest) do
    expected = get_in(target.configured, ["repo", "expected_repository"])

    if is_nil(expected) do
      :ok
    else
      actual = get_in(repo_manifest, ["project", "repository"])
      expected_slug = PublishTarget.github_repository_slug(expected)
      actual_slug = PublishTarget.github_repository_slug(actual)

      if is_binary(expected_slug) and is_binary(actual_slug) and
           String.downcase(expected_slug) == String.downcase(actual_slug) do
        :ok
      else
        {:error,
         target_diagnostic(
           target,
           "repo.expected_repository",
           :repository_mismatch,
           "expected repository #{expected_slug || "<unsupported>"} does not match current repository #{actual_slug || "<unsupported>"}"
         )}
      end
    end
  end

  defp effective_policy(target, host, repo_manifest, module_resolution) do
    configured = target.configured
    linear = configured["linear"]
    connection_id = linear["connection"]

    with {:ok, runner_policy} <- runner_policy(configured["runners"], host["runners"]) do
      {:ok,
       %{
         "repo_policy" => %{
           "manifest" => repo_manifest,
           "manifest_source_dir" => manifest_source_dir(configured),
           "workflow_module_resolution" => module_resolution
         },
         "tracker_connection" => %{
           "id" => connection_id,
           "policy" => get_in(host, ["tracker_connections", connection_id])
         },
         "run_target" =>
           Map.put(
             linear,
             "required_labels",
             union_labels(get_in(repo_manifest, ["issue_markers", "labels"]), linear["required_labels"])
           ),
         "worktree_policy" => configured["worktree"],
         "runner_policy" => runner_policy,
         "effective_checks" => %{
           "repository" => %{
             "validation" => get_in(repo_manifest, ["validation", "commands"]),
             "auto_land" => get_in(repo_manifest, ["auto_land", "required_checks"]) || []
           },
           "target" => configured["checks"]
         },
         "external_side_effect_gates" => configured["external_side_effects"],
         "capacity_limits" => configured["concurrency"],
         "budget_limits" => configured["budgets"],
         "scheduling" => configured["scheduling"]
       }}
    end
  end

  defp manifest_source_dir(configured) do
    configured
    |> get_in(["repo", "path"])
    |> Path.join(get_in(configured, ["repo", "manifest"]))
    |> Path.expand()
    |> Path.dirname()
  end

  defp runner_policy(target_runners, host_runners) do
    settings = target_runners["settings"]

    with {:ok, runners} <- compose_runners(target_runners["allowed"], settings, host_runners) do
      {:ok,
       %{
         "default" => target_runners["default"],
         "allowed" => target_runners["allowed"],
         "runners" => runners
       }}
    end
  end

  defp compose_runners(runner_ids, settings, host_runners) do
    Enum.reduce_while(runner_ids, {:ok, %{}}, fn id, {:ok, runners} ->
      target_settings = Map.get(settings, id, %{})

      case overlay_runner_policy(host_runners[id], target_settings, id) do
        {:ok, runner} -> {:cont, {:ok, Map.put(runners, id, runner)}}
        {:composition_error, _path, _code, _message} = error -> {:halt, error}
      end
    end)
  end

  defp overlay_runner_policy(host_runner, target_settings, runner_id)
       when is_map(host_runner) and is_map(target_settings) do
    runner = Map.merge(host_runner, safe_runner_tuning(target_settings))

    if is_map(host_runner["execution_profiles"]) or is_map(target_settings["execution_profiles"]) do
      with {:ok, profiles} <-
             overlay_execution_profiles(
               host_runner["execution_profiles"],
               target_settings["execution_profiles"],
               runner_id
             ) do
        {:ok, Map.put(runner, "execution_profiles", profiles)}
      end
    else
      {:ok, runner}
    end
  end

  defp overlay_runner_policy(_host_runner, _target_settings, runner_id) do
    {:composition_error, "runners.settings.#{runner_id}", :manifest_invalid, "current runner policy inputs have an invalid shape"}
  end

  defp safe_runner_tuning(settings) do
    settings
    |> Map.take(@safe_runner_setting_keys)
    |> Enum.filter(&safe_runner_setting?/1)
    |> Map.new()
  end

  defp safe_runner_setting?({"model", value}), do: nonempty_string?(value)
  defp safe_runner_setting?({"reasoning_effort", value}), do: value in @safe_reasoning_efforts
  defp safe_runner_setting?({"max_turns", value}), do: is_integer(value) and value > 0

  defp overlay_execution_profiles(host_profiles, target_profiles, runner_id) do
    host_profiles = if is_map(host_profiles), do: host_profiles, else: %{}
    target_profiles = if is_map(target_profiles), do: target_profiles, else: %{}

    with {:ok, canonical_host} <- canonical_profile_map(host_profiles, :host, runner_id),
         {:ok, canonical_target} <- canonical_profile_map(target_profiles, :target, runner_id) do
      safe_target = safe_execution_profiles(canonical_target)

      profiles = Map.merge(canonical_host, safe_target, &merge_execution_profile/3)

      {:ok, profiles}
    end
  end

  defp merge_execution_profile(_name, host_profile, target_tuning) when is_map(host_profile),
    do: Map.merge(host_profile, target_tuning)

  defp merge_execution_profile(_name, host_profile, _target_tuning), do: host_profile

  defp canonical_profile_map(profiles, source, runner_id) do
    with {:ok, entries} <- canonical_profile_entries(profiles),
         :ok <- reject_profile_collisions(entries, source, runner_id) do
      {:ok, Map.new(entries, fn {canonical, _original, profile} -> {canonical, profile} end)}
    else
      :error ->
        {:composition_error, "runners.settings.#{runner_id}.execution_profiles", :manifest_invalid, "#{source} runner #{runner_id} execution profile names are invalid"}

      {:composition_error, _path, _code, _message} = error ->
        error
    end
  end

  defp canonical_profile_entries(profiles) do
    profiles
    |> Enum.reduce_while({:ok, []}, fn {name, profile}, {:ok, entries} ->
      case canonical_profile_name(name) do
        {:ok, canonical, original} -> {:cont, {:ok, [{canonical, original, profile} | entries]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, fn {canonical, original, _profile} -> {canonical, original} end)}
      :error -> :error
    end
  end

  defp canonical_profile_name(name) when is_binary(name) or is_atom(name) or is_integer(name) do
    original = to_string(name)

    if String.valid?(original) do
      canonical =
        original
        |> String.trim()
        |> String.downcase()
        |> String.replace("-", "_")
        |> case do
          "" -> "implementation"
          normalized -> normalized
        end

      {:ok, canonical, original}
    else
      :error
    end
  end

  defp canonical_profile_name(_name), do: :error

  defp reject_profile_collisions(entries, _source, runner_id) do
    collision? =
      entries
      |> Enum.group_by(fn {canonical, _original, _profile} -> canonical end)
      |> Enum.any?(fn {_canonical, aliases} -> length(aliases) > 1 end)

    if collision? do
      {:composition_error, "runners.settings.#{runner_id}.execution_profiles", :execution_profile_name_collision, "execution profile names collide after normalization"}
    else
      :ok
    end
  end

  defp safe_execution_profiles(profiles) do
    profiles
    |> Enum.flat_map(fn
      {name, profile} when is_map(profile) ->
        tuning =
          profile
          |> Map.take(@safe_execution_profile_keys)
          |> Enum.filter(&safe_execution_profile_setting?/1)
          |> Map.new()

        [{name, tuning}]

      _invalid ->
        []
    end)
    |> Map.new()
  end

  defp safe_execution_profile_setting?({"model", value}), do: nonempty_string?(value)
  defp safe_execution_profile_setting?({"reasoning_effort", value}), do: value in @safe_reasoning_efforts

  defp nonempty_string?(value),
    do: valid_utf8_binary?(value) and String.trim(value) != ""

  defp valid_utf8_binary?(value), do: is_binary(value) and String.valid?(value)

  defp string_list?([]), do: true
  defp string_list?([value | rest]), do: valid_utf8_binary?(value) and string_list?(rest)
  defp string_list?(_value), do: false

  defp json_safe_string_map?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} ->
      valid_utf8_binary?(key) and json_safe_string_map?(nested)
    end)
  end

  defp json_safe_string_map?([]), do: true

  defp json_safe_string_map?([value | rest]),
    do: json_safe_string_map?(value) and json_safe_string_list?(rest)

  defp json_safe_string_map?(value), do: json_scalar?(value)

  defp json_safe_string_list?([]), do: true

  defp json_safe_string_list?([value | rest]),
    do: json_safe_string_map?(value) and json_safe_string_list?(rest)

  defp json_safe_string_list?(_improper_tail), do: false

  defp json_scalar?(value) when is_binary(value), do: String.valid?(value)
  defp json_scalar?(value) when is_float(value), do: finite_float?(value)
  defp json_scalar?(value), do: is_nil(value) or is_boolean(value) or is_integer(value)

  defp finite_float?(value) do
    <<_sign::1, exponent::11, _fraction::52>> = <<value::float-64>>
    exponent != 0x7FF
  end

  defp json_key_domain?(map) when is_map(map) do
    match?({:ok, _entries}, json_key_entries(map))
  end

  defp union_labels(repository_labels, target_labels) do
    (repository_labels ++ target_labels)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp policy_hash(policy) do
    case canonical_hash(policy) do
      {:ok, hash} ->
        {:ok, hash}

      {:error, :not_json_safe} ->
        {:manifest_invalid, "composed effective policy is not JSON-safe"}
    end
  end

  defp canonical_json(value) when is_map(value) do
    encoded =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, nested} ->
        [Jason.encode_to_iodata!(key), ?:, canonical_json(nested)]
      end)

    [?{, Enum.intersperse(encoded, ?,), ?}]
  end

  defp canonical_json(value) when is_list(value) do
    encoded = Enum.map(value, &canonical_json/1)
    [?[, Enum.intersperse(encoded, ?,), ?]]
  end

  defp canonical_json(value), do: Jason.encode_to_iodata!(value)

  defp json_key_entries(map) do
    map
    |> Enum.reduce_while({:ok, MapSet.new(), []}, fn {key, value}, {:ok, seen, entries} ->
      with {:ok, json_key} <- json_object_key(key),
           false <- MapSet.member?(seen, json_key) do
        {:cont, {:ok, MapSet.put(seen, json_key), [{json_key, value} | entries]}}
      else
        _invalid -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, _seen, entries} -> {:ok, Enum.sort_by(entries, &elem(&1, 0))}
      :error -> :error
    end
  end

  defp json_object_key(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: :error
  end

  defp json_object_key(key) when is_atom(key), do: key |> Atom.to_string() |> json_object_key()
  defp json_object_key(_key), do: :error

  defp prepare_target(%Target{configured: configured, valid?: true} = target) when is_map(configured) do
    {:ok, clear_composition(target)}
  end

  defp prepare_target(%Target{configured: configured, valid?: false} = target) when is_map(configured) do
    diagnostics =
      target.diagnostics
      |> diagnostic_list()
      |> Enum.filter(&is_struct(&1, Diagnostic))

    composition_errors =
      Enum.filter(diagnostics, &(&1.severity == :error and &1.code in @composition_codes))

    structural_errors =
      Enum.filter(diagnostics, &(&1.severity == :error and &1.code not in @composition_codes))

    if composition_errors != [] and structural_errors == [] and restorable_target?(target) do
      prepared =
        target
        |> clear_composition()
        |> Map.put(:valid?, true)
        |> Map.put(:effective_state, restored_effective_state(target))

      {:ok, prepared}
    else
      :skip
    end
  end

  defp prepare_target(_target), do: :skip

  defp restorable_target?(%Target{configured_state: state, dispatch_mode: mode}) do
    (state == :active and mode in [:explicit, :watch]) or state in [:paused, :draining, :retired]
  end

  defp restored_effective_state(%Target{configured_state: :active}), do: :active
  defp restored_effective_state(%Target{configured_state: state}), do: state

  defp clear_composition(target) do
    diagnostics =
      target.diagnostics
      |> diagnostic_list()
      |> Enum.filter(&is_struct(&1, Diagnostic))
      |> Enum.reject(&(&1.code in @composition_codes))

    %{target | repo_manifest: nil, effective_policy: nil, policy_hash: nil, diagnostics: diagnostics}
  end

  defp quarantine(target, diagnostics) do
    diagnostics = sort_diagnostics(diagnostic_list(target.diagnostics) ++ diagnostics)

    %{
      target
      | valid?: false,
        effective_state: :paused,
        repo_manifest: nil,
        effective_policy: nil,
        policy_hash: nil,
        diagnostics: diagnostics
    }
  end

  defp manifest_diagnostics(target, errors) when is_list(errors) and errors != [] do
    errors
    |> Enum.reduce_while({:ok, []}, &append_manifest_diagnostic(target, &1, &2))
    |> case do
      {:ok, diagnostics} -> {:ok, Enum.reverse(diagnostics)}
      :error -> :error
    end
  end

  defp manifest_diagnostics(_target, _errors), do: :error

  defp append_manifest_diagnostic(target, error, {:ok, diagnostics}) do
    with {:ok, path} <- semantic_error_field(error, :path),
         {:ok, message} <- semantic_error_field(error, :message) do
      suffix = if path == "$", do: "repo.manifest", else: "repo.manifest.#{path}"
      diagnostic = target_diagnostic(target, suffix, :manifest_invalid, "current repository manifest #{message}")
      {:cont, {:ok, [diagnostic | diagnostics]}}
    else
      :error -> {:halt, :error}
    end
  end

  defp semantic_error_field(error, field) when is_map(error) do
    value = Map.get(error, field, Map.get(error, Atom.to_string(field)))
    if is_binary(value), do: {:ok, value}, else: :error
  end

  defp semantic_error_field(_error, _field), do: :error

  defp manifest_diagnostic(target, code, message) do
    target_diagnostic(target, "repo.manifest", code, message)
  end

  defp target_diagnostic(target, suffix, code, message) do
    %Diagnostic{
      severity: :error,
      scope: {:target, target.id},
      path: "#{target_path(target.id)}.#{suffix}",
      code: code,
      message: message
    }
  end

  defp merge_diagnostics(existing, targets) do
    existing =
      existing
      |> diagnostic_list()
      |> Enum.filter(&is_struct(&1, Diagnostic))
      |> Enum.reject(&(&1.code in @composition_codes))

    target_diagnostics =
      Enum.flat_map(targets, fn
        {_id, %Target{diagnostics: diagnostics}} -> diagnostic_list(diagnostics)
        _entry -> []
      end)

    sort_diagnostics(existing ++ target_diagnostics)
  end

  defp diagnostic_list(diagnostics) when is_list(diagnostics), do: diagnostics
  defp diagnostic_list(_diagnostics), do: []

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

  defp target_path(id) when is_binary(id), do: "$.targets.#{id}"
  defp target_path(id), do: "$.targets[#{inspect(id)}]"
end
