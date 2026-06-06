defmodule SymphonyElixir.Workflow.Manifest do
  @moduledoc false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow.ModuleRegistry

  @manifest_file_name "symphony.yml"
  @workflow_version 1

  @type resolved_module :: %{
          id: String.t(),
          version: pos_integer(),
          summary: String.t()
        }

  @type resolved :: %{
          manifest_path: Path.t(),
          project_name: String.t(),
          preset: String.t(),
          modules: [resolved_module()],
          config: map(),
          prompt: String.t(),
          prompt_template: String.t(),
          source_paths: [Path.t()],
          policy_hash: String.t()
        }

  @spec default_path() :: Path.t()
  def default_path, do: Path.join(File.cwd!(), @manifest_file_name)

  @spec compile(Path.t(), keyword()) :: {:ok, resolved()} | {:error, term()}
  def compile(path \\ default_path(), opts \\ []) when is_binary(path) do
    expanded_path = Path.expand(path)

    with {:ok, manifest} <- load(expanded_path),
         :ok <- validate_manifest(expanded_path, manifest),
         {:ok, workflow_modules} <- resolve_modules(manifest, opts),
         {:ok, config} <- compile_config(workflow_modules, manifest),
         {:ok, prompt} <- compile_prompt(workflow_modules),
         {:ok, _settings} <- Schema.parse(config),
         :ok <- validate_docs(expanded_path, manifest) do
      modules = Enum.map(workflow_modules, &module_metadata/1)
      source_paths = [expanded_path | Enum.map(workflow_modules, & &1.path)]
      policy_hash = policy_hash(%{manifest: manifest, modules: modules, config: config, prompt: prompt})

      {:ok,
       %{
         manifest_path: expanded_path,
         project_name: get_in(manifest, ["project", "name"]),
         preset: get_in(manifest, ["workflow", "preset"]),
         modules: modules,
         config: config,
         prompt: prompt,
         prompt_template: prompt,
         source_paths: source_paths,
         policy_hash: policy_hash
       }}
    end
  end

  @spec load(Path.t()) :: {:ok, map()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        decode_manifest(path, content)

      {:error, reason} ->
        {:error, {:missing_manifest, path, reason}}
    end
  end

  @spec format_error(term()) :: String.t()
  def format_error(reason) do
    case reason do
      {:missing_manifest, path, raw_reason} ->
        "Missing symphony.yml at #{path}: #{inspect(raw_reason)}"

      {:invalid_manifest, path, message} ->
        "Invalid symphony.yml at #{path}: #{message}"

      {:missing_workflow_module, path, raw_reason} ->
        "Missing workflow module at #{path}: #{inspect(raw_reason)}"

      {:invalid_workflow_module, path, message} ->
        "Invalid workflow module at #{path}: #{message}"

      {:invalid_workflow_config, message} ->
        "Compiled workflow config is invalid: #{message}"

      other ->
        "Invalid workflow manifest: #{inspect(other)}"
    end
  end

  defp decode_manifest(path, content) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) -> {:ok, normalize_keys(decoded)}
      {:ok, _other} -> {:error, {:invalid_manifest, path, "manifest YAML must decode to a map"}}
      {:error, reason} -> {:error, {:invalid_manifest, path, inspect(reason)}}
    end
  end

  defp validate_manifest(path, manifest) do
    cond do
      Map.get(manifest, "version") != @workflow_version ->
        {:error, {:invalid_manifest, path, "version must be #{@workflow_version}"}}

      not non_empty_string?(get_in(manifest, ["project", "name"])) ->
        {:error, {:invalid_manifest, path, "project.name must be a non-empty string"}}

      not non_empty_string?(get_in(manifest, ["workflow", "preset"])) ->
        {:error, {:invalid_manifest, path, "workflow.preset must be a non-empty string"}}

      not module_ids?(get_in(manifest, ["workflow", "modules"])) ->
        {:error, {:invalid_manifest, path, "workflow.modules must be a non-empty list of module ids"}}

      not is_map(Map.get(manifest, "runtime", %{})) ->
        {:error, {:invalid_manifest, path, "runtime must be a map when present"}}

      true ->
        :ok
    end
  end

  defp resolve_modules(manifest, opts) do
    manifest
    |> get_in(["workflow", "modules"])
    |> ModuleRegistry.resolve(opts)
  end

  defp compile_config(workflow_modules, manifest) do
    config =
      workflow_modules
      |> Enum.map(&Map.get(&1, :config, %{}))
      |> Enum.reduce(%{}, &deep_merge/2)
      |> deep_merge(Map.get(manifest, "runtime", %{}))

    {:ok, config}
  end

  defp compile_prompt(workflow_modules) do
    prompt =
      workflow_modules
      |> Enum.map(&String.trim(Map.get(&1, :prompt, "")))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    if prompt == "" do
      {:error, {:invalid_manifest, "symphony.yml", "resolved workflow prompt must not be empty"}}
    else
      {:ok, prompt}
    end
  end

  defp validate_docs(manifest_path, manifest) do
    manifest_dir = Path.dirname(manifest_path)
    docs = get_in(manifest, ["docs", "entrypoints"]) || []

    if is_list(docs) and Enum.all?(docs, &is_binary/1) do
      missing = Enum.reject(docs, fn doc_path -> File.regular?(Path.expand(doc_path, manifest_dir)) end)

      case missing do
        [] -> :ok
        [first_missing | _rest] -> {:error, {:invalid_manifest, manifest_path, "docs.entrypoints contains missing file #{inspect(first_missing)}"}}
      end
    else
      {:error, {:invalid_manifest, manifest_path, "docs.entrypoints must be a list of file paths when present"}}
    end
  end

  defp module_metadata(workflow_module) do
    %{
      id: workflow_module.id,
      version: workflow_module.version,
      summary: workflow_module.summary
    }
  end

  defp policy_hash(payload) do
    payload
    |> canonicalize()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} -> {to_string(key), canonicalize(nested_value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Map.new()
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp module_ids?(module_ids) when is_list(module_ids) do
    Enum.any?(module_ids) and Enum.all?(module_ids, &non_empty_string?/1)
  end

  defp module_ids?(_module_ids), do: false

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(nested_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)
end
