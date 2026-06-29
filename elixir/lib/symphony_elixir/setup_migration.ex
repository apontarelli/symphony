defmodule SymphonyElixir.SetupMigration do
  @moduledoc false

  alias SymphonyElixir.LocalConfig
  alias SymphonyElixir.RunSetup
  alias SymphonyElixir.Workflow.Manifest
  alias SymphonyElixir.Workflow.Renderer

  defstruct [
    :manifest_path,
    :config_path,
    :run_setup_path,
    :local_config,
    :run_setup,
    :local_config_fragment,
    :cleaned_manifest,
    :moved_fields,
    :moves
  ]

  @type move :: %{required(:path) => String.t(), required(:destination) => String.t()}
  @type t :: %__MODULE__{
          manifest_path: Path.t(),
          config_path: Path.t(),
          run_setup_path: Path.t(),
          local_config: map(),
          local_config_fragment: map(),
          run_setup: map(),
          cleaned_manifest: map(),
          moved_fields: [String.t()],
          moves: [move()]
        }

  @tracker_config_keys ~w(kind endpoint api_key active_states terminal_states)
  @tracker_restrictive_keys ~w(required_labels)
  @tracker_target_keys ~w(project_id project_slug team_key workspace_slug assignee)
  @agent_capacity_keys ~w(max_concurrent_agents max_concurrent_startups)
  @runtime_agent_capacity_defaults %{
    "max_concurrent_agents" => 10,
    "max_concurrent_startups" => 2
  }
  @runtime_config_sections ~w(
    polling
    workspace
    worker
    hooks
    quality_gate
    observability
    server
    runners
    profiles
    workflow_modules
  )
  @classified_runtime_sections ["tracker", "agent", "codex" | @runtime_config_sections]
  @runtime_setup_top_level_fields ~w(
    agent
    codex
    deployment
    hooks
    host
    logs
    logs_root
    observability
    polling
    profiles
    quality_gate
    run_setup
    run_setups
    runners
    saved_run_setup
    saved_run_setups
    server
    target
    tracker
    worker
    workflow_modules
    workspace
  )

  @spec plan(Path.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def plan(repo_or_manifest, name, opts \\ []) do
    manifest_path = manifest_path(repo_or_manifest)

    with {:ok, raw} <- read_raw_manifest(manifest_path),
         {:ok, run_setup_path} <- RunSetup.path(name, opts),
         {:ok, local_fragment, run_setup_fragment, moves} <- migration_fragments(raw) do
      config_path = LocalConfig.path(opts)
      cleaned_manifest = clean_manifest(raw)
      repo_root = Path.dirname(manifest_path)

      local_config =
        LocalConfig.default_config()
        |> LocalConfig.deep_merge(local_fragment)

      run_setup =
        default_run_setup(name, repo_root, manifest_path)
        |> LocalConfig.deep_merge(run_setup_fragment)

      moves = Enum.sort_by(moves, & &1.path)

      {:ok,
       %__MODULE__{
         manifest_path: manifest_path,
         config_path: config_path,
         run_setup_path: run_setup_path,
         local_config: local_config,
         local_config_fragment: local_fragment,
         run_setup: run_setup,
         cleaned_manifest: cleaned_manifest,
         moved_fields: Enum.map(moves, & &1.path),
         moves: moves
       }}
    end
  end

  @spec apply(Path.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def apply(repo_or_manifest, name, opts \\ []) do
    with {:ok, plan} <- plan(repo_or_manifest, name, opts),
         :ok <- reject_existing_run_setup(plan.run_setup_path),
         {:ok, existing_config_fragment} <- load_existing_config_fragment(opts),
         {:ok, merged_config_fragment} <-
           merge_no_conflict(existing_config_fragment, plan.local_config_fragment, ["local config"]),
         applied_plan = apply_local_config_fragment(plan, merged_config_fragment),
         {:ok, staged} <- stage_plan(applied_plan),
         :ok <- commit_staged(staged) do
      {:ok, applied_plan}
    end
  end

  @spec format(t(), :dry_run | :apply) :: String.t()
  def format(%__MODULE__{} = plan, mode) do
    title =
      case mode do
        :dry_run -> "Migration dry run"
        :apply -> "Migration applied"
      end

    suffix =
      case mode do
        :dry_run -> ["No files changed."]
        :apply -> ["Files written."]
      end

    [
      title,
      "manifest: #{plan.manifest_path}",
      "local config: #{plan.config_path}",
      "run setup: #{plan.run_setup_path}",
      "moved fields:",
      move_lines(plan.moves),
      suffix
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp manifest_path(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      Manifest.manifest_path(expanded)
    else
      expanded
    end
  end

  defp read_raw_manifest(path) do
    with {:ok, content} <- File.read(path) do
      case YamlElixir.read_from_string(content) do
        {:ok, decoded} when is_map(decoded) -> {:ok, LocalConfig.normalize_keys(decoded)}
        {:ok, decoded} -> {:error, {:invalid_manifest, decoded}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp reject_existing_run_setup(path) do
    if File.exists?(path) do
      {:error, {:run_setup_exists, path}}
    else
      :ok
    end
  end

  defp load_existing_config_fragment(opts) do
    config_path = LocalConfig.path(opts)

    if File.regular?(config_path) do
      case File.read(config_path) do
        {:ok, content} -> decode_yaml_map(content, :invalid_local_config)
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, %{}}
    end
  end

  defp decode_yaml_map(content, error_tag) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded |> LocalConfig.normalize_keys() |> LocalConfig.drop_nil_values()}

      {:ok, decoded} ->
        {:error, {error_tag, decoded}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_local_config_fragment(plan, fragment) do
    local_config =
      LocalConfig.default_config()
      |> LocalConfig.deep_merge(fragment)

    %{plan | local_config: local_config, local_config_fragment: fragment}
  end

  defp stage_plan(plan) do
    with {:ok, config_stage} <- stage_yaml(plan.config_path, plan.local_config),
         {:ok, setup_stage} <-
           stage_yaml(plan.run_setup_path, LocalConfig.normalize_keys(plan.run_setup)),
         {:ok, manifest_stage} <- stage_yaml(plan.manifest_path, plan.cleaned_manifest) do
      {:ok, [config_stage, setup_stage, manifest_stage]}
    else
      error ->
        error
    end
  end

  defp stage_yaml(path, value) do
    tmp_path = temporary_path(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp_path, Renderer.to_yaml(value)) do
      {:ok, {tmp_path, path}}
    end
  end

  defp temporary_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{suffix}.tmp")
  end

  defp commit_staged(staged), do: commit_staged(staged, [])

  defp commit_staged([], committed) do
    Enum.each(committed, fn {_final_path, backup_path} -> cleanup_backup(backup_path) end)
    :ok
  end

  defp commit_staged([{tmp_path, final_path} | rest], committed) do
    backup_path = temporary_path(final_path)

    case backup_existing(final_path, backup_path) do
      {:ok, backup} ->
        case File.rename(tmp_path, final_path) do
          :ok ->
            commit_staged(rest, [{final_path, backup} | committed])

          {:error, reason} ->
            rollback_committed([{final_path, backup} | committed])
            cleanup_staged([{tmp_path, final_path} | rest])
            {:error, {:commit_failed, tmp_path, final_path, reason}}
        end

      {:error, reason} ->
        rollback_committed(committed)
        cleanup_staged([{tmp_path, final_path} | rest])
        {:error, {:commit_failed, tmp_path, final_path, reason}}
    end
  end

  defp backup_existing(final_path, backup_path) do
    if File.exists?(final_path) do
      case File.rename(final_path, backup_path) do
        :ok -> {:ok, backup_path}
        {:error, reason} -> {:error, {:backup_failed, reason}}
      end
    else
      {:ok, nil}
    end
  end

  defp rollback_committed(committed) do
    Enum.each(committed, fn
      {final_path, nil} ->
        File.rm(final_path)

      {final_path, backup_path} ->
        File.rm(final_path)
        File.rename(backup_path, final_path)
    end)
  end

  defp cleanup_backup(nil), do: :ok
  defp cleanup_backup(path), do: File.rm(path)

  defp cleanup_staged(staged) do
    Enum.each(staged, fn {tmp_path, _final_path} -> File.rm(tmp_path) end)
  end

  defp default_run_setup(name, repo_root, manifest_path) do
    %{
      "repo" => %{"path" => repo_root, "manifest" => manifest_path},
      "target" => %{},
      "mode" => "unattended",
      "capacity" => "normal",
      "restrictive_flags" => %{},
      "name" => name
    }
  end

  defp migration_fragments(raw) do
    nested_runtime = Map.get(raw, "runtime", %{})
    top_level_runtime = Map.take(raw, @runtime_setup_top_level_fields -- ["target"])

    {nested_local, nested_setup, nested_moves} = runtime_fragments(nested_runtime, "runtime")
    {top_level_local, top_level_setup, top_level_moves} = runtime_fragments(top_level_runtime, nil)

    with {:ok, local_fragment} <-
           merge_no_conflict(nested_local, top_level_local, ["local config"]),
         {:ok, run_setup_fragment} <-
           merge_no_conflict(nested_setup, top_level_setup, ["run setup"]),
         {:ok, run_setup_fragment, capacity_fragment} <-
           complete_capacity_fragment(run_setup_fragment),
         {:ok, local_fragment} <- put_completed_capacity_ceilings(local_fragment, capacity_fragment),
         {:ok, run_setup_fragment, target_moves} <- put_target(run_setup_fragment, raw) do
      moves = nested_moves ++ top_level_moves ++ target_moves
      {:ok, local_fragment, run_setup_fragment, moves}
    end
  end

  defp runtime_fragments(runtime, source_prefix) when is_map(runtime) do
    {tracker_config, tracker_setup, tracker_restrictive, tracker_moves} =
      runtime
      |> Map.get("tracker", %{})
      |> split_tracker(source_prefix)

    {agent_config, capacity, agent_moves} =
      runtime
      |> Map.get("agent", %{})
      |> split_agent(source_prefix)

    local_fragment =
      %{}
      |> put_non_empty("tracker", tracker_config)
      |> put_runtime_sections(runtime)
      |> put_non_empty("agent", agent_config)
      |> put_legacy_codex(runtime)
      |> put_unclassified_runtime_sections(runtime)
      |> put_capacity_ceilings(capacity)

    run_setup_fragment =
      %{}
      |> put_in_path(["target", "tracker"], tracker_setup)
      |> put_in_path(["restrictive_flags"], tracker_restrictive)
      |> put_capacity(capacity)

    moves =
      tracker_moves ++
        agent_moves ++
        runtime_section_moves(runtime, source_prefix) ++
        legacy_codex_moves(runtime, source_prefix) ++
        unclassified_runtime_moves(runtime, source_prefix)

    {local_fragment, run_setup_fragment, moves}
  end

  defp runtime_fragments(_runtime, _source_prefix), do: {%{}, %{}, []}

  defp split_tracker(tracker, source_prefix) when is_map(tracker) do
    Enum.reduce(tracker, {%{}, %{}, %{}, []}, fn {key, value}, {config, target, restrictive, moves} ->
      path = source_path(source_prefix, ["tracker", key])

      cond do
        key in @tracker_config_keys ->
          {Map.put(config, key, value), target, restrictive, [move(path, "local config") | moves]}

        key in @tracker_restrictive_keys ->
          {config, target, Map.put(restrictive, key, value), [move(path, "run setup restrictive_flags") | moves]}

        key in @tracker_target_keys ->
          {config, Map.put(target, key, value), restrictive, [move(path, "run setup target") | moves]}

        true ->
          {config, Map.put(target, key, value), restrictive, [move(path, "run setup target") | moves]}
      end
    end)
  end

  defp split_tracker(_tracker, _source_prefix), do: {%{}, %{}, %{}, []}

  defp split_agent(agent, source_prefix) when is_map(agent) do
    Enum.reduce(agent, {%{}, %{}, []}, fn {key, value}, {config, capacity, moves} ->
      path = source_path(source_prefix, ["agent", key])

      if key in @agent_capacity_keys do
        {config, Map.put(capacity, key, value), [move(path, "run setup capacity/local config ceiling") | moves]}
      else
        {Map.put(config, key, value), capacity, [move(path, "local config") | moves]}
      end
    end)
  end

  defp split_agent(_agent, _source_prefix), do: {%{}, %{}, []}

  defp put_runtime_sections(local_fragment, runtime) do
    Enum.reduce(@runtime_config_sections, local_fragment, fn section, acc ->
      put_non_empty(acc, section, Map.get(runtime, section, %{}))
    end)
  end

  defp put_legacy_codex(local_fragment, %{"codex" => codex}) when is_map(codex) do
    put_in_path(local_fragment, ["runners", "codex"], codex)
  end

  defp put_legacy_codex(local_fragment, _runtime), do: local_fragment

  defp put_unclassified_runtime_sections(local_fragment, runtime) do
    runtime
    |> Map.drop(@classified_runtime_sections)
    |> Enum.reduce(local_fragment, fn {section, value}, acc ->
      put_non_empty(acc, section, value)
    end)
  end

  defp put_capacity_ceilings(local_fragment, capacity) when map_size(capacity) > 0 do
    put_in_path(local_fragment, ["deployment", "ceilings"], capacity)
  end

  defp put_capacity_ceilings(local_fragment, _capacity), do: local_fragment

  defp put_capacity(run_setup_fragment, capacity) when map_size(capacity) > 0 do
    Map.put(run_setup_fragment, "capacity", capacity)
  end

  defp put_capacity(run_setup_fragment, _capacity), do: run_setup_fragment

  defp put_target(run_setup_fragment, %{"target" => target}) when is_map(target) do
    with {:ok, normalized_target} <- normalize_target(target),
         {:ok, merged} <-
           merge_no_conflict(
             run_setup_fragment,
             %{"target" => normalized_target},
             ["run setup"]
           ) do
      {:ok, merged, target_moves(%{"target" => target})}
    end
  end

  defp put_target(run_setup_fragment, _raw), do: {:ok, run_setup_fragment, []}

  defp runtime_section_moves(runtime, source_prefix) do
    runtime
    |> Map.take(@runtime_config_sections)
    |> Enum.flat_map(fn {section, value} ->
      leaf_moves(source_path(source_prefix, [section]), value, "local config")
    end)
  end

  defp legacy_codex_moves(%{"codex" => codex}, source_prefix),
    do: leaf_moves(source_path(source_prefix, ["codex"]), codex, "local config")

  defp legacy_codex_moves(_runtime, _source_prefix), do: []

  defp unclassified_runtime_moves(runtime, source_prefix) do
    runtime
    |> Map.drop(@classified_runtime_sections)
    |> Enum.flat_map(fn {section, value} ->
      leaf_moves(source_path(source_prefix, [section]), value, "local config")
    end)
  end

  defp target_moves(%{"target" => target}), do: leaf_moves("target", target, "run setup target")
  defp target_moves(_raw), do: []

  defp complete_capacity_fragment(%{"capacity" => capacity} = run_setup_fragment) when is_map(capacity) do
    completed = Map.merge(@runtime_agent_capacity_defaults, capacity)

    if valid_capacity?(completed) do
      {:ok, Map.put(run_setup_fragment, "capacity", completed), completed}
    else
      {:error, {:invalid_capacity, capacity}}
    end
  end

  defp complete_capacity_fragment(run_setup_fragment), do: {:ok, run_setup_fragment, %{}}

  defp put_completed_capacity_ceilings(local_fragment, capacity) when map_size(capacity) > 0 do
    merge_no_conflict(local_fragment, %{"deployment" => %{"ceilings" => capacity}}, ["local config"])
  end

  defp put_completed_capacity_ceilings(local_fragment, _capacity), do: {:ok, local_fragment}

  defp valid_capacity?(capacity) do
    Enum.all?(@agent_capacity_keys, fn key ->
      value = Map.get(capacity, key)
      is_integer(value) and value > 0
    end)
  end

  defp normalize_target(target) do
    {direct_tracker, target} = Map.split(target, @tracker_target_keys)
    nested_tracker = Map.get(target, "tracker", %{})
    target_without_tracker = Map.delete(target, "tracker")

    cond do
      nested_tracker in [%{}, nil] ->
        {:ok, put_non_empty(target_without_tracker, "tracker", direct_tracker)}

      is_map(nested_tracker) ->
        with {:ok, tracker} <-
               merge_no_conflict(nested_tracker, direct_tracker, ["run setup", "target", "tracker"]) do
          {:ok, Map.put(target_without_tracker, "tracker", tracker)}
        end

      true ->
        {:error, {:invalid_target_tracker, nested_tracker}}
    end
  end

  defp merge_no_conflict(left, right, path) when is_map(left) and is_map(right) do
    Enum.reduce_while(right, {:ok, left}, fn entry, acc ->
      merge_map_entry(entry, acc, path)
    end)
  end

  defp merge_no_conflict(left, right, _path) when left == right, do: {:ok, left}

  defp merge_no_conflict(left, right, path) do
    {:error, {:migration_conflict, Enum.join(path, "."), left, right}}
  end

  defp merge_map_entry({key, right_value}, {:ok, acc}, path) do
    child_path = path ++ [key]

    case Map.fetch(acc, key) do
      :error ->
        {:cont, {:ok, Map.put(acc, key, right_value)}}

      {:ok, left_value} ->
        merge_existing_value(acc, key, left_value, right_value, child_path)
    end
  end

  defp merge_existing_value(acc, key, left_value, right_value, child_path) do
    case merge_no_conflict(left_value, right_value, child_path) do
      {:ok, merged_value} -> {:cont, {:ok, Map.put(acc, key, merged_value)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp source_path(nil, parts), do: Enum.join(parts, ".")
  defp source_path(prefix, parts), do: Enum.join([prefix | parts], ".")

  defp clean_manifest(raw) do
    Map.drop(raw, ["runtime" | @runtime_setup_top_level_fields])
  end

  defp put_non_empty(map, _key, value) when value in [%{}, nil], do: map
  defp put_non_empty(map, key, value), do: Map.put(map, key, value)

  defp put_in_path(map, _path, value) when value in [%{}, nil], do: map

  defp put_in_path(map, [key], value), do: Map.put(map, key, value)

  defp put_in_path(map, [key | rest], value) do
    nested = Map.get(map, key, %{})
    Map.put(map, key, put_in_path(nested, rest, value))
  end

  defp leaf_moves(path, value, destination) when is_map(value) and map_size(value) > 0 do
    Enum.flat_map(value, fn {key, nested} ->
      leaf_moves("#{path}.#{key}", nested, destination)
    end)
  end

  defp leaf_moves(path, _value, destination), do: [move(path, destination)]

  defp move(path, destination), do: %{path: path, destination: destination}

  defp move_lines([]), do: ["  - none"]

  defp move_lines(moves) do
    Enum.map(moves, fn %{path: path, destination: destination} ->
      "  - #{path} -> #{destination}"
    end)
  end
end
