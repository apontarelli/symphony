defmodule SymphonyElixir.Config.ProfileBindingAdmin do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.ProfileBindings
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @spec facts() :: map()
  def facts do
    settings_result = Config.settings()
    bindings = ProfileBindings.current()

    %{
      workflow_path: Workflow.workflow_file_path(),
      binding_source: binding_source(),
      settings: settings_result,
      workflow: workflow_facts(settings_result, bindings),
      profiles: profile_facts(settings_result),
      bindings: bindings,
      validation: validation_result(settings_result, bindings)
    }
  end

  @spec discover_projects(module()) :: {:ok, [map()]} | {:error, term()}
  def discover_projects(client_module \\ SymphonyElixir.Linear.Client) do
    bindings = ProfileBindings.current()

    case ProfileBindings.team_fetch_selector(bindings) do
      %{team_id: team_id} when is_binary(team_id) ->
        client_module.fetch_active_projects(%{team_id: team_id})

      %{team_key: team_key} when is_binary(team_key) ->
        client_module.fetch_active_projects(%{team_key: team_key})

      _selector ->
        {:error, :missing_linear_project_discovery_team_selector}
    end
  end

  @spec save_project_bindings([map()]) :: {:ok, map()} | {:error, term()}
  def save_project_bindings(projects) when is_list(projects) do
    with {:ok, settings} <- Config.settings(),
         bindings <- next_bindings(projects),
         :ok <- ProfileBindings.validate(settings, bindings),
         :ok <- write_bindings(ProfileBindings.source_path(), bindings) do
      :ok = ProfileBindings.set(bindings)
      {:ok, bindings}
    end
  end

  @spec project_rows([map()]) :: [map()]
  def project_rows(discovered_projects) when is_list(discovered_projects) do
    bindings = ProfileBindings.current()
    bound_by_selector = Map.new(bindings.projects, &{project_selector_key(&1), &1})

    discovered_rows =
      discovered_projects
      |> Enum.map(fn project ->
        selector = project_selector(project)
        binding = Map.get(bound_by_selector, project_selector_key(selector))

        %{
          id: project[:id],
          name: project[:name],
          slug_id: project[:slug_id],
          status_name: project[:status_name],
          status_type: project[:status_type],
          selector_kind: selector_kind(selector),
          selector_value: selector_value(selector),
          bound?: not is_nil(binding),
          profile: (binding && binding.profile) || "default",
          pr_target: (binding && binding.pr_target) || nil
        }
      end)

    discovered_keys =
      discovered_rows
      |> Enum.map(&project_selector_key(%{String.to_atom(&1.selector_kind) => &1.selector_value}))
      |> MapSet.new()

    bound_only_rows =
      bindings.projects
      |> Enum.reject(&MapSet.member?(discovered_keys, project_selector_key(&1)))
      |> Enum.map(fn binding ->
        %{
          id: binding.project_id,
          name: binding.project_slug || binding.project_id || "Bound project",
          slug_id: binding.project_slug,
          status_name: "bound only",
          status_type: "unknown",
          selector_kind: selector_kind(binding),
          selector_value: selector_value(binding),
          bound?: true,
          profile: binding.profile || "default",
          pr_target: binding.pr_target
        }
      end)

    discovered_rows ++ bound_only_rows
  end

  @spec parse_project_params(map()) :: [map()]
  def parse_project_params(project_params) when is_map(project_params) do
    project_params
    |> Map.values()
    |> Enum.flat_map(fn params ->
      if truthy?(Map.get(params, "include")) do
        [
          %{
            selector_kind: normalized_string(Map.get(params, "selector_kind")),
            selector_value: normalized_string(Map.get(params, "selector_value")),
            profile: normalized_string(Map.get(params, "profile")),
            pr_target: normalized_string(Map.get(params, "pr_target"))
          }
        ]
      else
        []
      end
    end)
  end

  def parse_project_params(_params), do: []

  defp workflow_facts({:ok, settings}, bindings) do
    %{
      tracker_kind: settings.tracker.kind,
      active_states: settings.tracker.active_states,
      terminal_states: settings.tracker.terminal_states,
      team_selector: team_selector_label(bindings)
    }
  end

  defp workflow_facts({:error, reason}, bindings) do
    %{
      tracker_kind: "unavailable",
      active_states: [],
      terminal_states: [],
      team_selector: team_selector_label(bindings),
      error: inspect(reason)
    }
  end

  defp profile_facts({:ok, %Schema{} = settings}) do
    settings.profiles
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn name ->
      pr_target =
        case Schema.resolve_effective_policy(settings, name) do
          {:ok, policy} -> get_in(policy, ["delivery", "pr_target"])
          {:error, reason} -> inspect(reason)
        end

      %{name: name, pr_target: pr_target}
    end)
  end

  defp profile_facts(_settings_result), do: []

  defp validation_result({:ok, settings}, bindings) do
    case ProfileBindings.validate(settings, bindings) do
      :ok -> %{status: :ok, message: "valid"}
      {:error, reason} -> %{status: :error, message: inspect(reason)}
    end
  end

  defp validation_result({:error, reason}, _bindings), do: %{status: :error, message: inspect(reason)}

  defp binding_source do
    path = ProfileBindings.source_path()

    %{
      path: path,
      explicit?: ProfileBindings.source_explicit?(),
      exists?: File.regular?(path)
    }
  end

  defp next_bindings(projects) do
    current = ProfileBindings.current()

    %{
      team_id: current.team_id,
      team_key: current.team_key,
      projects: Enum.map(projects, &project_binding_from_params/1),
      labels: current.labels,
      catch_all: current.catch_all,
      allow_default: current.allow_default
    }
    |> ProfileBindings.normalize()
  end

  defp project_binding_from_params(%{selector_kind: "project_id", selector_value: value} = params) do
    %{project_id: value, profile: params.profile}
    |> maybe_put_pr_target(params.pr_target)
  end

  defp project_binding_from_params(%{selector_kind: "project_slug", selector_value: value} = params) do
    %{project_slug: value, profile: params.profile}
    |> maybe_put_pr_target(params.pr_target)
  end

  defp project_binding_from_params(params) do
    %{project_slug: params[:selector_value], profile: params[:profile]}
    |> maybe_put_pr_target(params[:pr_target])
  end

  defp maybe_put_pr_target(binding, nil), do: binding
  defp maybe_put_pr_target(binding, pr_target), do: Map.put(binding, :pr_target, pr_target)

  defp write_bindings(path, bindings) when is_binary(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, bindings_yaml(bindings))
    end
  end

  defp bindings_yaml(bindings) do
    [
      yaml_scalar("team_id", bindings.team_id),
      yaml_scalar("team_key", bindings.team_key),
      yaml_project_bindings(bindings.projects),
      yaml_label_bindings(bindings.labels),
      "catch_all:",
      "  enabled: #{yaml_value(bindings.catch_all.enabled)}",
      "  profile: #{yaml_value(bindings.catch_all.profile)}",
      "allow_default: #{yaml_value(bindings.allow_default)}"
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp yaml_project_bindings([]), do: ["projects: []"]

  defp yaml_project_bindings(projects) do
    ["projects:" | Enum.flat_map(projects, &yaml_project_binding/1)]
  end

  defp yaml_project_binding(binding) do
    [
      "  - #{project_selector_yaml(binding)}",
      "    profile: #{yaml_value(binding.profile)}",
      binding.pr_target && "    pr_target: #{yaml_value(binding.pr_target)}"
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp yaml_label_bindings([]), do: ["labels: []"]

  defp yaml_label_bindings(labels) do
    ["labels:" | Enum.flat_map(labels, &yaml_label_binding/1)]
  end

  defp yaml_label_binding(binding) do
    [
      "  - label: #{yaml_value(binding.label)}",
      "    profile: #{yaml_value(binding.profile)}"
    ]
  end

  defp project_selector_yaml(%{project_id: project_id}) when is_binary(project_id), do: "project_id: #{yaml_value(project_id)}"
  defp project_selector_yaml(%{project_slug: project_slug}), do: "project_slug: #{yaml_value(project_slug)}"

  defp yaml_scalar(_key, nil), do: nil
  defp yaml_scalar(key, value), do: "#{key}: #{yaml_value(value)}"

  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"
  defp yaml_value(value) when is_binary(value), do: inspect(value)
  defp yaml_value(value), do: inspect(to_string(value))

  defp project_selector(%{slug_id: slug_id}) when is_binary(slug_id), do: %{project_slug: slug_id}
  defp project_selector(%{id: id}), do: %{project_id: id}

  defp project_selector_key(%{project_id: project_id}) when is_binary(project_id), do: {:project_id, project_id}
  defp project_selector_key(%{project_slug: project_slug}) when is_binary(project_slug), do: {:project_slug, project_slug}
  defp project_selector_key(_selector), do: {:missing, nil}

  defp selector_kind(%{project_id: project_id}) when is_binary(project_id), do: "project_id"
  defp selector_kind(%{project_slug: project_slug}) when is_binary(project_slug), do: "project_slug"
  defp selector_kind(_binding), do: "project_slug"

  defp selector_value(%{project_id: project_id}) when is_binary(project_id), do: project_id
  defp selector_value(%{project_slug: project_slug}) when is_binary(project_slug), do: project_slug
  defp selector_value(_binding), do: nil

  defp team_selector_label(%{team_id: team_id}) when is_binary(team_id), do: "team_id=#{team_id}"
  defp team_selector_label(%{team_key: team_key}) when is_binary(team_key), do: "team_key=#{team_key}"
  defp team_selector_label(_bindings), do: "missing"

  defp normalized_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_string(_value), do: nil

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]
end
