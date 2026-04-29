defmodule SymphonyElixir.Config.ProfileBindings do
  @moduledoc false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @bindings_env_key :linear_profile_bindings
  @profile_override_env_key :workflow_profile_override

  @type binding_config :: %{
          projects: [map()],
          labels: [map()],
          catch_all: map(),
          allow_default: boolean(),
          team_id: String.t() | nil,
          team_key: String.t() | nil,
          loaded: boolean(),
          errors: [String.t()]
        }

  @spec current() :: binding_config()
  def current do
    case Application.fetch_env(:symphony_elixir, @bindings_env_key) do
      {:ok, bindings} -> normalize(bindings, true)
      :error -> empty_config(false)
    end
  end

  @spec set(map() | nil) :: :ok
  def set(nil), do: clear()

  def set(bindings) when is_map(bindings) do
    Application.put_env(:symphony_elixir, @bindings_env_key, bindings)
    :ok
  end

  @spec clear() :: :ok
  def clear do
    Application.delete_env(:symphony_elixir, @bindings_env_key)
    :ok
  end

  @spec set_profile_override(String.t() | nil) :: :ok
  def set_profile_override(nil), do: clear_profile_override()

  def set_profile_override(profile) when is_binary(profile) do
    Application.put_env(:symphony_elixir, @profile_override_env_key, profile)
    :ok
  end

  @spec clear_profile_override() :: :ok
  def clear_profile_override do
    Application.delete_env(:symphony_elixir, @profile_override_env_key)
    :ok
  end

  @spec profile_override() :: String.t() | nil
  def profile_override do
    Application.get_env(:symphony_elixir, @profile_override_env_key)
    |> normalized_string()
  end

  @spec load_file(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_file(path) when is_binary(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :linear_profile_bindings_not_a_map}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize(map() | nil) :: binding_config()
  def normalize(raw_bindings), do: normalize(raw_bindings, true)

  defp normalize(nil, loaded), do: empty_config(loaded)

  defp normalize(raw_bindings, loaded) when is_map(raw_bindings) do
    bindings =
      raw_bindings
      |> normalize_keys()
      |> unwrap_bindings_root()

    {projects, project_errors} =
      normalize_project_bindings(Map.get(bindings, "projects") || Map.get(bindings, "project_bindings"))

    {labels, label_errors} =
      normalize_label_bindings(Map.get(bindings, "labels") || Map.get(bindings, "label_bindings"))

    {catch_all, catch_all_errors} =
      normalize_catch_all(Map.get(bindings, "catch_all") || Map.get(bindings, "catchall"))

    %{
      projects: projects,
      labels: labels,
      catch_all: catch_all,
      allow_default: truthy?(Map.get(bindings, "allow_default", false)),
      team_id: normalized_string(Map.get(bindings, "team_id")),
      team_key: normalized_string(Map.get(bindings, "team_key")),
      loaded: loaded,
      errors: project_errors ++ label_errors ++ catch_all_errors
    }
  end

  @spec configured?(binding_config()) :: boolean()
  def configured?(%{loaded: loaded} = bindings) do
    loaded or selectors_configured?(bindings)
  end

  @spec dispatch_scope_configured?(binding_config()) :: boolean()
  def dispatch_scope_configured?(%{projects: projects, catch_all: catch_all}) do
    projects != [] or catch_all.enabled
  end

  @spec project_fetch_selectors(binding_config()) :: [map()]
  def project_fetch_selectors(%{projects: projects}) do
    projects
    |> Enum.map(&Map.take(&1, [:project_id, :project_slug]))
    |> Enum.uniq()
  end

  @spec team_fetch_selector(binding_config()) :: map() | nil
  def team_fetch_selector(%{team_id: team_id}) when is_binary(team_id), do: %{team_id: team_id}
  def team_fetch_selector(%{team_key: team_key}) when is_binary(team_key), do: %{team_key: team_key}
  def team_fetch_selector(_bindings), do: nil

  @spec catch_all_enabled?(binding_config()) :: boolean()
  def catch_all_enabled?(%{catch_all: %{enabled: enabled}}), do: enabled == true

  @spec validate(Schema.t(), binding_config()) :: :ok | {:error, term()}
  def validate(%Schema{} = settings, bindings) when is_map(bindings) do
    with :ok <- validate_binding_shapes(bindings),
         :ok <- validate_linear_fetch_scope(settings, bindings),
         :ok <- validate_bound_profiles(settings, bindings) do
      validate_profile_override(settings)
    end
  end

  @spec select_policy(Schema.t(), Issue.t(), binding_config(), keyword()) ::
          {:ok, map()} | {:skip, term()} | {:error, term()}
  def select_policy(%Schema{} = settings, %Issue{} = issue, bindings, opts \\ [])
      when is_map(bindings) and is_list(opts) do
    case normalized_string(Keyword.get(opts, :profile_override) || profile_override()) do
      nil ->
        select_bound_policy(settings, issue, bindings)

      profile ->
        resolve_policy(settings, profile, [], %{
          source: "cli_override",
          profile: profile,
          cli_override: true
        })
    end
  end

  defp empty_config(loaded) do
    %{
      projects: [],
      labels: [],
      catch_all: %{enabled: false, profile: "default"},
      allow_default: false,
      team_id: nil,
      team_key: nil,
      loaded: loaded,
      errors: []
    }
  end

  defp select_bound_policy(settings, issue, bindings) do
    case matching_project_bindings(issue, bindings.projects) do
      [binding] ->
        select_project_policy(settings, issue, bindings, binding)

      [] ->
        select_fallback_policy(settings, issue, bindings)

      matches ->
        {:error, {:ambiguous_linear_project_profile_binding, project_identity(issue), binding_summaries(matches)}}
    end
  end

  defp select_project_policy(settings, issue, bindings, binding) do
    with {:ok, refinement} <- matching_label_refinement(issue, bindings.labels) do
      refinement_profiles = if is_nil(refinement), do: [], else: [refinement.profile]

      metadata =
        %{
          source: "project_binding",
          profile: binding.profile,
          project_id: binding.project_id,
          project_slug: binding.project_slug
        }
        |> maybe_put_refinement_metadata(refinement)

      resolve_policy(settings, binding.profile, refinement_profiles, metadata)
    end
  end

  defp select_fallback_policy(settings, issue, %{catch_all: %{enabled: true, profile: profile}} = bindings) do
    if catch_all_scope_matches?(settings, issue, bindings) do
      resolve_policy(settings, profile, [], %{
        source: "catch_all",
        profile: profile,
        team_id: bindings.team_id,
        team_key: bindings.team_key,
        project_id: issue.project_id,
        project_slug: issue.project_slug
      })
    else
      {:skip, :linear_catch_all_team_mismatch}
    end
  end

  defp select_fallback_policy(settings, issue, bindings) do
    cond do
      issue_unprojected?(issue) and configured?(bindings) ->
        {:skip, :no_matching_linear_profile_binding}

      default_allowed?(settings, issue, bindings) ->
        resolve_policy(settings, "default", [], %{source: "default", profile: "default"})

      true ->
        {:skip, :no_matching_linear_profile_binding}
    end
  end

  defp resolve_policy(settings, profile, refinement_profiles, metadata) do
    lock_delivery_target = if refinement_profiles == [], do: nil, else: base_delivery_target(settings, profile)

    Schema.resolve_effective_policy(settings, profile, refinement_profiles,
      metadata: metadata,
      lock_delivery_target: lock_delivery_target
    )
  end

  defp base_delivery_target(settings, profile) do
    case Schema.resolve_effective_policy(settings, profile) do
      {:ok, policy} -> get_in(policy, ["delivery", "pr_target"])
      {:error, _reason} -> nil
    end
  end

  defp default_allowed?(settings, issue, bindings) do
    cond do
      settings.tracker.kind != "linear" ->
        true

      bindings.allow_default ->
        true

      not bindings.loaded and not selectors_configured?(bindings) ->
        legacy_project_scope_matches?(settings, issue)

      true ->
        false
    end
  end

  defp selectors_configured?(%{projects: projects, labels: labels, catch_all: catch_all, allow_default: allow_default}) do
    projects != [] or labels != [] or catch_all.enabled or allow_default
  end

  defp legacy_project_scope_matches?(%Schema{tracker: %{project_slug: project_slug}}, %Issue{project_slug: issue_project_slug})
       when is_binary(project_slug) and is_binary(issue_project_slug) do
    project_slug == issue_project_slug
  end

  defp legacy_project_scope_matches?(_settings, _issue), do: false

  defp catch_all_scope_matches?(%Schema{tracker: %{kind: kind}}, _issue, _bindings) when kind != "linear", do: true

  defp catch_all_scope_matches?(_settings, %Issue{team_id: team_id}, %{team_id: team_id})
       when is_binary(team_id),
       do: true

  defp catch_all_scope_matches?(_settings, %Issue{team_key: team_key}, %{team_key: team_key})
       when is_binary(team_key),
       do: true

  defp catch_all_scope_matches?(_settings, _issue, _bindings), do: false

  defp matching_project_bindings(%Issue{} = issue, project_bindings) when is_list(project_bindings) do
    Enum.filter(project_bindings, &project_binding_matches_issue?(&1, issue))
  end

  defp project_binding_matches_issue?(binding, issue) do
    id_match? =
      is_binary(binding.project_id) and is_binary(issue.project_id) and binding.project_id == issue.project_id

    slug_match? =
      is_binary(binding.project_slug) and is_binary(issue.project_slug) and binding.project_slug == issue.project_slug

    id_match? or slug_match?
  end

  defp issue_unprojected?(%Issue{project_id: project_id, project_slug: project_slug}) do
    is_nil(project_id) and is_nil(project_slug)
  end

  defp matching_label_refinement(issue, label_bindings) do
    issue_labels = issue_labels(issue)
    matches = Enum.filter(label_bindings, &(&1.label in issue_labels))

    case matches do
      [] -> {:ok, nil}
      [binding] -> {:ok, binding}
      _ -> {:error, {:ambiguous_linear_label_profile_binding, Enum.map(matches, & &1.label), binding_summaries(matches)}}
    end
  end

  defp issue_labels(%Issue{labels: labels}) when is_list(labels) do
    labels
    |> Enum.map(&normalize_label/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp issue_labels(_issue), do: []

  defp validate_binding_shapes(bindings) do
    [
      &validate_normalized_binding_errors/1,
      &validate_project_binding_shapes/1,
      &validate_label_binding_shapes/1,
      &validate_catch_all_binding_shape/1
    ]
    |> Enum.reduce_while(:ok, fn validator, :ok ->
      case validator.(bindings) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_normalized_binding_errors(%{errors: []}), do: :ok

  defp validate_normalized_binding_errors(%{errors: errors}) do
    {:error, {:invalid_linear_profile_bindings, Enum.join(errors, "; ")}}
  end

  defp validate_project_binding_shapes(%{projects: projects}) do
    cond do
      Enum.any?(projects, &(is_binary(&1.project_id) and is_binary(&1.project_slug))) ->
        {:error, {:invalid_linear_profile_bindings, "project bindings require exactly one of project_id or project_slug"}}

      Enum.any?(projects, &(is_nil(&1.profile) or (is_nil(&1.project_id) and is_nil(&1.project_slug)))) ->
        {:error, {:invalid_linear_profile_bindings, "project bindings require profile and project_id or project_slug"}}

      true ->
        :ok
    end
  end

  defp validate_label_binding_shapes(%{labels: labels}) do
    if Enum.any?(labels, &(is_nil(&1.profile) or is_nil(&1.label))) do
      {:error, {:invalid_linear_profile_bindings, "label bindings require profile and label"}}
    else
      :ok
    end
  end

  defp validate_catch_all_binding_shape(%{catch_all: %{enabled: false}}), do: :ok

  defp validate_catch_all_binding_shape(%{catch_all: %{enabled: true, profile: nil}}) do
    {:error, {:invalid_linear_profile_bindings, "catch_all requires profile when enabled"}}
  end

  defp validate_catch_all_binding_shape(%{catch_all: %{enabled: true}} = bindings) do
    if catch_all_team_selector_count(bindings) == 1 do
      :ok
    else
      {:error, {:invalid_linear_profile_bindings, "catch_all requires exactly one of team_id or team_key"}}
    end
  end

  defp validate_linear_fetch_scope(%Schema{tracker: %{kind: "linear"}}, bindings) do
    if bindings.catch_all.enabled and is_nil(team_fetch_selector(bindings)) do
      {:error, :missing_linear_catch_all_team_selector}
    else
      :ok
    end
  end

  defp validate_linear_fetch_scope(_settings, _bindings), do: :ok

  defp validate_bound_profiles(settings, bindings) do
    bindings
    |> bound_profiles()
    |> Enum.reduce_while(:ok, fn {source, profile}, :ok ->
      case Schema.resolve_effective_policy(settings, profile) do
        {:ok, _policy} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:unknown_linear_profile_binding, source, profile, reason}}}
      end
    end)
  end

  defp validate_profile_override(settings) do
    case profile_override() do
      nil ->
        :ok

      profile ->
        case Schema.resolve_effective_policy(settings, profile) do
          {:ok, _policy} -> :ok
          {:error, reason} -> {:error, {:unknown_linear_profile_binding, :cli_override, profile, reason}}
        end
    end
  end

  defp bound_profiles(bindings) do
    project_profiles = Enum.map(bindings.projects, &{:project, &1.profile})
    label_profiles = Enum.map(bindings.labels, &{:label, &1.profile})

    catch_all_profiles =
      if bindings.catch_all.enabled do
        [{:catch_all, bindings.catch_all.profile}]
      else
        []
      end

    project_profiles ++ label_profiles ++ catch_all_profiles
  end

  defp project_identity(issue) do
    %{
      team_id: issue.team_id,
      team_key: issue.team_key,
      team_name: issue.team_name,
      project_id: issue.project_id,
      project_slug: issue.project_slug,
      project_name: issue.project_name
    }
  end

  defp catch_all_team_selector_count(bindings) do
    [bindings.team_id, bindings.team_key]
    |> Enum.count(&is_binary/1)
  end

  defp binding_summaries(bindings) do
    Enum.map(bindings, fn binding ->
      Map.take(binding, [:project_id, :project_slug, :label, :profile])
    end)
  end

  defp maybe_put_refinement_metadata(metadata, nil), do: metadata

  defp maybe_put_refinement_metadata(metadata, refinement) do
    Map.put(metadata, :label_refinement, %{
      label: refinement.label,
      profile: refinement.profile
    })
  end

  defp normalize_project_bindings(nil), do: {[], []}

  defp normalize_project_bindings(bindings) when is_list(bindings) do
    bindings
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {binding, index}, {normalized, errors} ->
      case normalize_project_binding(binding) do
        {:ok, project_binding} -> {[project_binding | normalized], errors}
        {:error, message} -> {normalized, ["projects[#{index}] #{message}" | errors]}
      end
    end)
    |> then(fn {normalized, errors} -> {Enum.reverse(normalized), Enum.reverse(errors)} end)
  end

  defp normalize_project_bindings(_bindings), do: {[], ["projects must be a list"]}

  defp normalize_project_binding(binding) when is_map(binding) do
    binding = normalize_keys(binding)

    {:ok,
     %{
       project_id: normalized_string(Map.get(binding, "project_id") || Map.get(binding, "id")),
       project_slug: normalized_string(Map.get(binding, "project_slug") || Map.get(binding, "slug") || Map.get(binding, "slug_id")),
       profile: normalized_string(Map.get(binding, "profile") || Map.get(binding, "profile_name"))
     }}
  end

  defp normalize_project_binding(_binding), do: {:error, "must be a map"}

  defp normalize_label_bindings(nil), do: {[], []}

  defp normalize_label_bindings(bindings) when is_list(bindings) do
    bindings
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {binding, index}, {normalized, errors} ->
      case normalize_label_binding(binding) do
        {:ok, label_binding} -> {[label_binding | normalized], errors}
        {:error, message} -> {normalized, ["labels[#{index}] #{message}" | errors]}
      end
    end)
    |> then(fn {normalized, errors} -> {Enum.reverse(normalized), Enum.reverse(errors)} end)
  end

  defp normalize_label_bindings(_bindings), do: {[], ["labels must be a list"]}

  defp normalize_label_binding(binding) when is_map(binding) do
    binding = normalize_keys(binding)

    {:ok,
     %{
       label: normalize_label(Map.get(binding, "label") || Map.get(binding, "name")),
       profile: normalized_string(Map.get(binding, "profile") || Map.get(binding, "profile_name"))
     }}
  end

  defp normalize_label_binding(_binding), do: {:error, "must be a map"}

  defp normalize_catch_all(nil), do: {%{enabled: false, profile: "default"}, []}

  defp normalize_catch_all(profile) when is_binary(profile) do
    {%{enabled: true, profile: normalized_string(profile)}, []}
  end

  defp normalize_catch_all(catch_all) when is_map(catch_all) do
    catch_all = normalize_keys(catch_all)

    {
      %{
        enabled: truthy?(Map.get(catch_all, "enabled", false)),
        profile: normalized_string(Map.get(catch_all, "profile") || Map.get(catch_all, "profile_name") || "default")
      },
      []
    }
  end

  defp normalize_catch_all(_catch_all), do: {%{enabled: false, profile: "default"}, ["catch_all must be a map or profile string"]}

  defp unwrap_bindings_root(%{"linear_profile_bindings" => bindings}) when is_map(bindings), do: bindings
  defp unwrap_bindings_root(%{"profile_bindings" => bindings}) when is_map(bindings), do: bindings
  defp unwrap_bindings_root(%{"linear" => %{"profile_bindings" => bindings}}) when is_map(bindings), do: bindings
  defp unwrap_bindings_root(bindings), do: bindings

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, raw_value} -> {normalize_key(key), normalize_keys(raw_value)} end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp normalized_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_string(_value), do: nil

  defp normalize_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      label -> label
    end
  end

  defp normalize_label(_value), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false
end
