defmodule SymphonyElixir.Workflow.ModuleRegistry do
  @moduledoc false

  @type workflow_module :: %{
          id: String.t(),
          path: Path.t(),
          version: pos_integer(),
          summary: String.t(),
          config: map(),
          prompt: String.t()
        }

  @spec default_root() :: Path.t()
  def default_root do
    candidates = [
      Application.get_env(:symphony_elixir, :workflow_modules_root),
      priv_dir_candidate(),
      Path.expand("elixir/priv/workflow_modules", File.cwd!()),
      Path.expand("priv/workflow_modules", File.cwd!()),
      Path.expand("../../../priv/workflow_modules", __DIR__)
    ]

    candidates
    |> Enum.reject(&is_nil/1)
    |> then(fn paths -> Enum.find(paths, &File.dir?/1) || List.last(paths) end)
  end

  defp priv_dir_candidate do
    case :code.priv_dir(:symphony_elixir) do
      {:error, _reason} -> nil
      priv_dir -> priv_dir |> List.to_string() |> Path.join("workflow_modules")
    end
  end

  @spec resolve([String.t()], keyword()) :: {:ok, [workflow_module()]} | {:error, term()}
  def resolve(module_ids, opts \\ []) when is_list(module_ids) do
    root = Keyword.get(opts, :root, default_root())

    module_ids
    |> Enum.reduce_while({:ok, []}, fn module_id, {:ok, modules} ->
      case load(module_id, root) do
        {:ok, workflow_module} -> {:cont, {:ok, [workflow_module | modules]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, modules} -> {:ok, Enum.reverse(modules)}
      error -> error
    end
  end

  @spec load(String.t(), Path.t()) :: {:ok, workflow_module()} | {:error, term()}
  def load(module_id, root) when is_binary(module_id) and is_binary(root) do
    path = root |> Path.expand() |> Path.join(module_id <> ".yml")

    with {:ok, content} <- read_module_file(path),
         {:ok, decoded} <- decode_module_file(path, content) do
      parse_module(module_id, path, decoded)
    end
  end

  defp read_module_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:missing_workflow_module, path, reason}}
    end
  end

  defp decode_module_file(path, content) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) -> {:ok, normalize_keys(decoded)}
      {:ok, _other} -> {:error, {:invalid_workflow_module, path, "module YAML must decode to a map"}}
      {:error, reason} -> {:error, {:invalid_workflow_module, path, inspect(reason)}}
    end
  end

  defp parse_module(expected_id, path, decoded) do
    module_id = Map.get(decoded, "id")
    version = Map.get(decoded, "version")
    summary = Map.get(decoded, "summary")
    config = Map.get(decoded, "config", %{})
    prompt = Map.get(decoded, "prompt", "")

    validations = [
      {module_id == expected_id, "id must be #{inspect(expected_id)}"},
      {is_integer(version) and version >= 1, "version must be a positive integer"},
      {is_binary(summary) and String.trim(summary) != "", "summary must be a non-empty string"},
      {is_map(config), "config must be a map"},
      {is_binary(prompt) and String.trim(prompt) != "", "prompt must be a non-empty string"}
    ]

    case Enum.find(validations, fn {valid?, _message} -> not valid? end) do
      nil ->
        {:ok, %{id: module_id, path: path, version: version, summary: summary, config: config, prompt: prompt}}

      {_valid?, message} ->
        {:error, {:invalid_workflow_module, path, message}}
    end
  end

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
