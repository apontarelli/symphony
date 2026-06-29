defmodule SymphonyElixir.RunSetup do
  @moduledoc false

  alias SymphonyElixir.LocalConfig
  alias SymphonyElixir.Workflow.Manifest
  alias SymphonyElixir.Workflow.Renderer

  @name_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @tracker_target_keys ~w(project_id project_slug team_key workspace_slug assignee)

  @type setup :: map()

  @spec path(String.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def path(name, opts \\ []) when is_binary(name) do
    if valid_name?(name) do
      {:ok, Path.join(LocalConfig.runs_dir(opts), name <> ".yml")}
    else
      {:error, {:invalid_run_setup_name, name}}
    end
  end

  @spec read(String.t(), keyword()) :: {:ok, setup(), Path.t()} | {:error, term()}
  def read(name, opts \\ []) do
    with {:ok, setup_path} <- path(name, opts),
         {:ok, content} <- File.read(setup_path),
         {:ok, setup} <- decode_yaml(content) do
      {:ok, setup, setup_path}
    end
  end

  @spec write(String.t(), setup(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def write(name, setup, opts \\ []) when is_map(setup) do
    with {:ok, setup_path} <- path(name, opts),
         :ok <- File.mkdir_p(Path.dirname(setup_path)),
         :ok <- File.write(setup_path, Renderer.to_yaml(LocalConfig.normalize_keys(setup))) do
      {:ok, setup_path}
    end
  end

  @spec runtime_manifest(map(), setup()) :: {:ok, map()} | {:error, term()}
  def runtime_manifest(local_config, setup) when is_map(local_config) and is_map(setup) do
    setup = LocalConfig.normalize_keys(setup)

    with {:ok, manifest} <- repo_manifest(setup),
         {:ok, capacity} <- LocalConfig.resolve_capacity(local_config, Map.get(setup, "capacity")),
         {:ok, runtime} <- runtime_config(local_config, setup, capacity),
         runtime_manifest = Map.put(public_manifest(manifest), "runtime", runtime),
         :ok <- validate_runtime_manifest(runtime_manifest) do
      {:ok, runtime_manifest}
    end
  end

  @spec materialize_runtime_manifest(String.t(), map(), setup(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def materialize_runtime_manifest(name, local_config, setup, opts \\ []) do
    with {:ok, runtime_manifest} <- runtime_manifest(local_config, setup),
         {:ok, runtime_path} <- runtime_path(name, opts),
         :ok <- File.mkdir_p(Path.dirname(runtime_path)),
         :ok <- File.write(runtime_path, Renderer.to_yaml(runtime_manifest)) do
      {:ok, runtime_path}
    end
  end

  defp validate_runtime_manifest(runtime_manifest) do
    runtime_path = Path.join(System.tmp_dir!(), "symphony-runtime-#{System.unique_integer([:positive])}.yml")

    try do
      with :ok <- File.write(runtime_path, Renderer.to_yaml(runtime_manifest)),
           {:ok, _loaded} <- Manifest.load(runtime_path, repo_setup?: false) do
        :ok
      end
    after
      File.rm(runtime_path)
    end
  end

  @spec capacity_label(setup()) :: String.t()
  def capacity_label(setup) when is_map(setup) do
    case Map.get(LocalConfig.normalize_keys(setup), "capacity") do
      value when is_binary(value) -> value
      %{} = value -> "#{value["max_concurrent_agents"]}/#{value["max_concurrent_startups"]}"
      _ -> "normal"
    end
  end

  defp valid_name?(name) do
    Regex.match?(@name_pattern, name) and not String.contains?(name, "..")
  end

  defp decode_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) -> {:ok, LocalConfig.normalize_keys(decoded)}
      {:ok, decoded} -> {:error, {:invalid_run_setup, decoded}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo_manifest(setup) do
    case repo_manifest_path(setup) do
      path when is_binary(path) -> Manifest.read(path, repo_setup?: true)
      _ -> {:error, :missing_run_setup_repo}
    end
  end

  defp repo_manifest_path(%{"repo" => %{"manifest" => manifest}}) when is_binary(manifest), do: Path.expand(manifest)

  defp repo_manifest_path(%{"repo" => %{"path" => repo_path}}) when is_binary(repo_path) do
    repo_path
    |> Path.expand()
    |> Manifest.manifest_path()
  end

  defp repo_manifest_path(_setup), do: nil

  defp public_manifest(manifest) do
    manifest
    |> Map.delete("_field_sources")
    |> Map.delete("_runtime_allowed?")
    |> Map.delete("runtime")
    |> update_in(["workflow"], fn
      workflow when is_map(workflow) -> Map.delete(workflow, "_module_requests")
      workflow -> workflow
    end)
  end

  defp runtime_config(local_config, setup, capacity) do
    runtime =
      local_config
      |> LocalConfig.runtime_config()
      |> LocalConfig.deep_merge(%{"agent" => capacity})
      |> LocalConfig.deep_merge(%{"tracker" => target_tracker(setup)})
      |> LocalConfig.deep_merge(%{"tracker" => restrictive_tracker_flags(setup)})

    {:ok, runtime}
  end

  defp target_tracker(setup) do
    target = Map.get(setup, "target", %{})

    case Map.get(target, "tracker") do
      tracker when is_map(tracker) ->
        Map.take(tracker, @tracker_target_keys)

      _ ->
        Map.take(target, @tracker_target_keys)
    end
  end

  defp restrictive_tracker_flags(setup) do
    flags = Map.get(setup, "restrictive_flags", %{})

    case Map.get(flags, "required_labels") do
      labels when is_list(labels) -> %{"required_labels" => labels}
      _ -> %{}
    end
  end

  defp runtime_path(name, opts) do
    if valid_name?(name) do
      {:ok, Path.join([LocalConfig.root(opts), "runtime", name <> ".runtime.yml"])}
    else
      {:error, {:invalid_run_setup_name, name}}
    end
  end
end
