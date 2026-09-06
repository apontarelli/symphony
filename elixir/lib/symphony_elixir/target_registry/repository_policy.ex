defmodule SymphonyElixir.TargetRegistry.RepositoryPolicy do
  @moduledoc false

  alias SymphonyElixir.TargetRegistry.Composition
  alias SymphonyElixir.Workflow.Manifest

  @id_regex ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
  @policy_keys ~w(
    version
    project
    docs
    vcs
    delivery
    validation
    workflow
    automation
    auto_land
    review_routing
    harness
    capabilities
    issue_markers
    prompt_template
  )

  @type diagnostic :: %{
          required(:path) => String.t(),
          required(:code) => atom(),
          required(:message) => String.t()
        }

  @spec resolve(map(), map()) ::
          {:ok, map(), map()} | {:error, [diagnostic()]} | {:error, diagnostic()}
  def resolve(host, configured) when is_map(host) and is_map(configured) do
    defaults_present = Map.has_key?(host, "repository_defaults")
    overrides_present = Map.has_key?(configured, "repository_policy")

    with {:ok, defaults} <- policy_layer(Map.get(host, "repository_defaults", %{}), "repository_defaults"),
         {:ok, profiles} <- profile_layers(Map.get(host, "repository_profiles", %{})),
         {:ok, selected_name} <- selected_profile(configured),
         {:ok, profile} <- selected_profile_layer(profiles, selected_name),
         {:ok, overrides} <- policy_layer(Map.get(configured, "repository_policy", %{}), "repository_policy"),
         merged = deep_merge(deep_merge(defaults, profile), overrides),
         {:ok, normalized} <- compile_policy(merged) do
      {:ok, normalized,
       %{
         "defaults" => source_descriptor(defaults, defaults_present),
         "profile" => profile_source_descriptor(profiles, selected_name, profile),
         "overrides" => source_descriptor(overrides, overrides_present)
       }}
    else
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, diagnostic} when is_map(diagnostic) -> {:error, [diagnostic]}
    end
  end

  def resolve(_host, _configured) do
    {:error, [diagnostic("repository_policy", :invalid_type, "repository policy inputs must be maps")]}
  end

  @doc false
  @spec validate_raw_policy(term(), String.t()) :: [diagnostic()]
  def validate_raw_policy(policy, path \\ "repository_policy") do
    with :ok <- validate_policy_shape(policy, path),
         {:ok, _normalized} <- Manifest.normalize_map(policy, repo_setup?: true) do
      []
    else
      {:error, {:invalid_manifest, diagnostics}} when is_list(diagnostics) ->
        manifest_diagnostics(diagnostics, path)

      {:error, diagnostics} when is_list(diagnostics) ->
        if Enum.all?(diagnostics, &Map.has_key?(&1, :code)) do
          diagnostics
        else
          manifest_diagnostics(diagnostics, path)
        end

      {:error, reason} ->
        [diagnostic(path, :manifest_invalid, "#{path} is invalid: #{inspect(reason)}")]
    end
  end

  @doc false
  @spec valid_profile_name?(term()) :: boolean()
  def valid_profile_name?(name), do: is_binary(name) and Regex.match?(@id_regex, name)

  defp policy_layer(policy, path) do
    case validate_policy_shape(policy, path) do
      :ok -> {:ok, policy}
      {:error, diagnostics} -> {:error, diagnostics}
    end
  end

  defp profile_layers(profiles) when is_map(profiles) do
    profiles
    |> Enum.sort_by(fn {name, _policy} -> {inspect(name), :erlang.term_to_binary(name, [:deterministic])} end)
    |> Enum.reduce_while({:ok, %{}}, fn {name, policy}, {:ok, normalized} ->
      name_path = "repository_profiles.#{name}"

      with true <- valid_profile_name?(name),
           {:ok, policy} <- policy_layer(policy, name_path) do
        {:cont, {:ok, Map.put(normalized, name, policy)}}
      else
        false ->
          {:halt, {:error, [diagnostic(name_path, :invalid_id, "#{name_path} must be a valid profile name")]}}

        {:error, diagnostics} ->
          {:halt, {:error, diagnostics}}
      end
    end)
  end

  defp profile_layers(_profiles) do
    {:error, [diagnostic("repository_profiles", :invalid_type, "repository_profiles must be a map")]}
  end

  defp selected_profile(configured) do
    case Map.fetch(configured, "repository_profile") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:error, [diagnostic("repository_profile", :invalid_type, "repository_profile must be a string")]}

      {:ok, name} when is_binary(name) ->
        if valid_profile_name?(name) do
          {:ok, name}
        else
          {:error, [diagnostic("repository_profile", :invalid_value, "repository_profile must be a valid profile name")]}
        end

      {:ok, _name} ->
        {:error, [diagnostic("repository_profile", :invalid_value, "repository_profile must be a valid profile name")]}
    end
  end

  defp selected_profile_layer(_profiles, nil), do: {:ok, %{}}

  defp selected_profile_layer(profiles, name) do
    case Map.fetch(profiles, name) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, [diagnostic("repository_profile", :unknown_profile, "repository profile #{name} is not configured on the host")]}
    end
  end

  defp compile_policy(raw) do
    case Manifest.load_map(raw, repo_setup?: true) do
      {:ok, %{config: %{"manifest" => normalized}}} when is_map(normalized) ->
        {:ok, normalized}

      {:ok, _compiled} ->
        {:error, [diagnostic("repository_policy", :manifest_invalid, "compiled repository policy has an invalid shape")]}

      {:error, {:invalid_manifest, diagnostics}} when is_list(diagnostics) ->
        {:error, manifest_diagnostics(diagnostics, "repository_policy")}

      {:error, {:manifest_parse_error, reason}} ->
        {:error, [diagnostic("repository_policy", :manifest_invalid, "repository policy could not be parsed: #{inspect(reason)}")]}

      {:error, reason} ->
        {:error, [diagnostic("repository_policy", :manifest_invalid, "repository policy could not be compiled: #{inspect(reason)}")]}
    end
  end

  defp validate_policy_shape(policy, path) when is_map(policy) do
    key_diagnostics =
      policy
      |> Enum.sort_by(fn {key, _value} -> {inspect(key), :erlang.term_to_binary(key, [:deterministic])} end)
      |> Enum.flat_map(fn {key, _value} ->
        cond do
          not is_binary(key) -> [diagnostic("#{path}[key]", :invalid_type, "#{path} policy keys must be strings")]
          key in @policy_keys -> []
          true -> [diagnostic("#{path}.#{key}", :unknown_key, "#{path}.#{key} is not supported in repository policy")]
        end
      end)

    nested_diagnostics =
      policy
      |> Enum.flat_map(fn {key, value} -> validate_json_keys(value, "#{path}.#{key}") end)

    field_diagnostics = validate_section_fields(policy, path)

    diagnostics = key_diagnostics ++ nested_diagnostics ++ field_diagnostics
    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  defp validate_policy_shape(_policy, path), do: {:error, [diagnostic(path, :invalid_type, "#{path} must be a map")]}

  defp validate_section_fields(policy, path) do
    sections =
      policy
      |> Enum.sort_by(fn {key, _value} -> {inspect(key), :erlang.term_to_binary(key, [:deterministic])} end)
      |> Enum.flat_map(fn {section, value} ->
        case {Manifest.repository_policy_section_fields()[section], value} do
          {nil, _value} ->
            []

          {_fields, non_map} when not is_map(non_map) ->
            []

          {fields, section_map} when is_binary(section) ->
            unknown_section_field_diagnostics(section_map, fields, "#{path}.#{section}")

          {_fields, _section_map} ->
            []
        end
      end)

    commands =
      case policy do
        %{"validation" => %{"commands" => commands}} when is_list(commands) ->
          fields = Manifest.repository_policy_section_fields()["validation.commands"]

          commands
          |> Enum.with_index()
          |> Enum.flat_map(fn
            {command, index} when is_map(command) ->
              unknown_section_field_diagnostics(command, fields, "#{path}.validation.commands[#{index}]")

            _invalid_command ->
              []
          end)

        _no_commands ->
          []
      end

    sections ++ commands
  end

  defp unknown_section_field_diagnostics(section_map, fields, section_path) do
    section_map
    |> Enum.sort_by(fn {key, _nested} -> {inspect(key), :erlang.term_to_binary(key, [:deterministic])} end)
    |> Enum.flat_map(fn {key, _nested} ->
      if is_binary(key) and key not in fields do
        [
          diagnostic(
            "#{section_path}.#{key}",
            :unknown_key,
            "#{section_path}.#{key} is not a supported field (supported: #{Enum.join(fields, ", ")})"
          )
        ]
      else
        []
      end
    end)
  end

  defp validate_json_keys(value, path) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _nested} -> {inspect(key), :erlang.term_to_binary(key, [:deterministic])} end)
    |> Enum.flat_map(fn {key, nested} ->
      key_diagnostics =
        if is_binary(key), do: [], else: [diagnostic("#{path}[key]", :invalid_type, "#{path} policy keys must be strings")]

      key_diagnostics ++ validate_json_keys(nested, "#{path}.#{key}")
    end)
  end

  defp validate_json_keys(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {nested, index} -> validate_json_keys(nested, "#{path}[#{index}]") end)
  end

  defp validate_json_keys(_value, _path), do: []

  defp manifest_diagnostics(diagnostics, prefix) do
    Enum.map(diagnostics, fn
      %{path: path, message: message} when is_binary(path) ->
        diagnostic(join_path(prefix, path), :manifest_invalid, message)

      %{"path" => path, "message" => message} when is_binary(path) ->
        diagnostic(join_path(prefix, path), :manifest_invalid, message)

      other ->
        diagnostic(prefix, :manifest_invalid, inspect(other))
    end)
  end

  defp join_path(prefix, path) when path in ["", "$"], do: prefix
  defp join_path(prefix, "$" <> rest), do: prefix <> rest
  defp join_path(prefix, path), do: prefix <> "." <> path

  defp source_descriptor(policy, present?) do
    %{"present" => present?, "revision" => if(present?, do: configuration_revision(policy), else: nil)}
  end

  defp profile_source_descriptor(_profiles, nil, _profile), do: %{"present" => false, "name" => nil, "revision" => nil}

  defp profile_source_descriptor(_profiles, name, profile) do
    %{"present" => true, "name" => name, "revision" => configuration_revision(profile)}
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value -> deep_merge(left_value, right_value) end)
  end

  defp deep_merge(_left, right), do: right

  defp diagnostic(path, code, message), do: %{path: path, code: code, message: message}

  defp configuration_revision(policy) do
    case Composition.canonical_hash(policy) do
      {:ok, revision} -> revision
      {:error, :not_json_safe} -> nil
    end
  end
end
