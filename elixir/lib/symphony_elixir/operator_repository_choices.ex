defmodule SymphonyElixir.OperatorRepositoryChoices do
  @moduledoc false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{LocalConfig, ProjectWorkflows}
  alias SymphonyElixir.Workflow.Manifest
  alias SymphonyElixir.Workflow.ModuleRegistry

  @config_options [:config_root]

  @type choice :: %{
          required(:value) => String.t(),
          required(:status) => String.t(),
          required(:reason) => String.t() | nil
        }
  @type field :: %{
          required(:cardinality) => String.t(),
          required(:choices) => [choice()],
          required(:status) => String.t(),
          required(:reason) => String.t() | nil
        }

  @spec build(nil | String.t(), keyword()) :: %{String.t() => field()}
  def build(nil, opts) when is_list(opts), do: repository_required_catalog(load_config(opts))

  def build(repo, opts) when is_binary(repo) and is_list(opts) do
    if String.trim(repo) == "" do
      repository_required_catalog(load_config(opts))
    else
      build_for_repository(Path.expand(repo), opts)
    end
  end

  defp build_for_repository(repo, opts) do
    config_opts = Keyword.take(opts, @config_options)

    case Manifest.read(repo, repo_setup?: true) do
      {:ok, manifest} ->
        config_state = load_config(config_opts)
        compiled_state = compile_catalog(manifest, config_state)

        workflow =
          case ProjectWorkflows.list(repo, config_opts) do
            {:ok, workflows, warnings} ->
              workflow_field(workflows, warnings)

            {:error, _reason} ->
              unavailable_field("scalar", "incompatible_workflow_definition")
          end

        %{
          "workflow" => workflow,
          "profile" => profile_field(manifest, config_state, compiled_state),
          "workflow.modules" => modules_field(manifest, config_state, compiled_state),
          "capacity" => capacity_field(config_state)
        }

      {:error, _reason} ->
        repository_unavailable_catalog(load_config(config_opts))
    end
  end

  defp workflow_field(workflows, warnings) do
    valid_names = MapSet.new(workflows, & &1.name)

    valid_choices =
      Enum.map(workflows, fn workflow ->
        available_choice(workflow.name)
      end)

    invalid_choices =
      warnings
      |> invalid_workflow_names()
      |> Enum.reject(&MapSet.member?(valid_names, &1))
      |> Enum.map(&invalid_choice(&1, "incompatible_workflow_definition"))

    current_field("scalar", valid_choices ++ invalid_choices)
  end

  defp profile_field(_manifest, :invalid, _compiled_state),
    do: unavailable_field("scalar", "invalid_local_config")

  defp profile_field(_manifest, {:ok, _config}, {:ok, settings, _base}) do
    choices =
      settings.profiles
      |> Map.keys()
      |> Enum.map(&available_choice(to_string(&1)))
      |> Enum.sort_by(& &1.value)

    current_field("scalar", choices)
  end

  defp profile_field(_manifest, {:ok, config}, {:error, _reason, base}) do
    profile_choices(base, config, "incompatible_profile_definition")
  end

  defp profile_choices(base, config, reason) do
    choices =
      manifest_profile_names(base, config)
      |> Enum.map(&invalid_choice(&1, reason))

    if choices == [] do
      unavailable_field("scalar", reason)
    else
      current_field("scalar", choices)
    end
  end

  defp modules_field(manifest, config_state, compiled_state) do
    configured = configured_module_names(config_state)
    builtin = builtin_module_names()
    selected = get_in(manifest, ["workflow", "modules"])

    module_names = Enum.uniq(builtin ++ configured ++ selected)
    config_valid? = match?({:ok, _settings, _base}, compiled_state)

    choices =
      module_names
      |> Enum.with_index()
      |> Enum.map(fn {module_name, index} ->
        module_choice(module_name, index, manifest, module_name in configured and not config_valid?)
      end)
      |> Enum.sort_by(& &1.value)

    current_field("list", choices)
  end

  defp module_choice(name, _index, _manifest, true), do: invalid_choice(name, "incompatible_workflow_module")

  defp module_choice(name, index, manifest, false) do
    case ModuleRegistry.module_diagnostics(name, index, manifest) do
      [] -> available_choice(name)
      _diagnostics -> invalid_choice(name, "incompatible_workflow_module")
    end
  end

  defp capacity_field({:ok, config}) do
    profiles = config |> LocalConfig.normalize_keys() |> Map.get("capacity_profiles", %{})

    if is_map(profiles) do
      choices =
        profiles
        |> Map.keys()
        |> Enum.map(&capacity_choice(&1, config))
        |> Enum.sort_by(& &1.value)

      current_field("scalar", choices)
    else
      unavailable_field("scalar", "invalid_local_config")
    end
  end

  defp capacity_field(:invalid), do: unavailable_field("scalar", "invalid_local_config")

  defp capacity_choice(name, config) do
    value = to_string(name)

    case LocalConfig.resolve_capacity(config, value) do
      {:ok, _capacity} -> available_choice(value)
      {:error, _reason} -> invalid_choice(value, "invalid_capacity_profile")
    end
  end

  defp load_config(opts) do
    case LocalConfig.load(opts) do
      {:ok, config} -> {:ok, config}
      {:error, :enoent} -> {:ok, LocalConfig.default_config()}
      {:error, _reason} -> :invalid
    end
  end

  defp compile_catalog(manifest, {:ok, config}) do
    case compiled_manifest_config(manifest) do
      {:ok, base} ->
        merged = LocalConfig.deep_merge(base, LocalConfig.runtime_config(config))

        case Schema.parse(merged) do
          {:ok, settings} -> {:ok, settings, base}
          {:error, reason} -> {:error, reason, base}
        end

      {:error, reason} ->
        {:error, reason, nil}
    end
  end

  defp compile_catalog(_manifest, :invalid), do: {:error, :invalid_local_config, nil}

  defp compiled_manifest_config(manifest) do
    {:ok, Manifest.compile(manifest).config}
  rescue
    _error -> {:error, :invalid_workflow_definition}
  end

  defp manifest_profile_names(base, config) when is_map(base) do
    base
    |> LocalConfig.deep_merge(LocalConfig.runtime_config(config))
    |> LocalConfig.normalize_keys()
    |> Map.get("profiles", %{})
    |> map_keys()
  end

  defp manifest_profile_names(_base, _config), do: []

  defp configured_module_names({:ok, config}) do
    config
    |> LocalConfig.runtime_config()
    |> Map.get("workflow_modules", %{})
    |> map_keys()
  end

  defp configured_module_names(:invalid), do: []

  defp builtin_module_names, do: ModuleRegistry.module_names()
  defp map_keys(value) when is_map(value), do: value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
  defp map_keys(_value), do: []

  defp invalid_workflow_names(warnings) do
    warnings
    |> Enum.map(fn warning ->
      [path] = Regex.run(~r/^Skipped saved workflow (.+?\.yml): /, warning, capture: :all_but_first)
      Path.basename(path, ".yml")
    end)
    |> Enum.uniq()
  end

  defp repository_required_catalog(config_state) do
    %{
      "workflow" => unavailable_field("scalar", "repository_required"),
      "profile" => unavailable_field("scalar", "repository_required"),
      "workflow.modules" => unavailable_field("list", "repository_required"),
      "capacity" => capacity_field(config_state)
    }
  end

  defp repository_unavailable_catalog(config_state) do
    %{
      "workflow" => unavailable_field("scalar", "repository_unavailable"),
      "profile" => unavailable_field("scalar", "repository_unavailable"),
      "workflow.modules" => unavailable_field("list", "repository_unavailable"),
      "capacity" => capacity_field(config_state)
    }
  end

  defp current_field(cardinality, choices), do: field(cardinality, choices, "current", nil)
  defp unavailable_field(cardinality, reason), do: field(cardinality, [], "unavailable", reason)

  defp field(cardinality, choices, status, reason) do
    %{cardinality: cardinality, choices: choices, status: status, reason: reason}
  end

  defp available_choice(value), do: %{value: value, status: "available", reason: nil}
  defp invalid_choice(value, reason), do: %{value: value, status: "invalid", reason: reason}
end
