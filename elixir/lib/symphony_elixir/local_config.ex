defmodule SymphonyElixir.LocalConfig do
  @moduledoc false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow.Renderer

  @config_file "config.yml"
  @runs_dir "runs"
  @default_config_root "~/.config/symphony"
  @default_workspace_root "~/dev/symphony-workspaces"
  @runtime_keys ~w(
    tracker
    polling
    workspace
    worker
    agent
    hooks
    quality_gate
    observability
    server
    runners
    profiles
    workflow_modules
  )

  @type config :: map()
  @type capacity :: %{
          required(String.t()) => pos_integer()
        }

  @spec root(keyword()) :: Path.t()
  def root(opts \\ []) do
    opts
    |> Keyword.get(:config_root, @default_config_root)
    |> Path.expand()
  end

  @spec path(keyword()) :: Path.t()
  def path(opts \\ []), do: Path.join(root(opts), @config_file)

  @spec runs_dir(keyword()) :: Path.t()
  def runs_dir(opts \\ []), do: Path.join(root(opts), @runs_dir)

  @spec default_config() :: config()
  def default_config do
    %{
      "tracker" => %{
        "kind" => "linear",
        "endpoint" => "https://api.linear.app/graphql",
        "api_key" => "$LINEAR_API_KEY",
        "active_states" => ["Todo", "In Progress", "Merging", "Rework"],
        "terminal_states" => ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
      },
      "polling" => %{"interval_ms" => 30_000},
      "workspace" => %{"root" => @default_workspace_root},
      "agent" => %{
        "default_runner" => "codex",
        "max_turns" => 20,
        "max_retry_backoff_ms" => 300_000
      },
      "capacity_profiles" => %{
        "light" => %{"max_concurrent_agents" => 1, "max_concurrent_startups" => 1},
        "normal" => %{"max_concurrent_agents" => 4, "max_concurrent_startups" => 1},
        "swarm" => %{"max_concurrent_agents" => 10, "max_concurrent_startups" => 2}
      },
      "deployment" => %{
        "ceilings" => %{
          "max_concurrent_agents" => 10,
          "max_concurrent_startups" => 2
        }
      },
      "runners" => local_default_runners()
    }
  end

  defp local_default_runners do
    Schema.default_runners()
    |> put_in(["codex", "approval_policy"], "never")
  end

  @spec ensure(keyword()) :: {:ok, :created | :existing, config(), Path.t()} | {:error, term()}
  def ensure(opts \\ []) do
    config_path = path(opts)

    if File.regular?(config_path) do
      with {:ok, config} <- load(opts) do
        {:ok, :existing, config, config_path}
      end
    else
      config = default_config()

      with :ok <- File.mkdir_p(root(opts)),
           :ok <- File.write(config_path, Renderer.to_yaml(config)) do
        {:ok, :created, config, config_path}
      end
    end
  end

  @spec load(keyword()) :: {:ok, config()} | {:error, term()}
  def load(opts \\ []) do
    with {:ok, content} <- File.read(path(opts)),
         {:ok, decoded} <- decode_yaml(content) do
      config = drop_nil_values(decoded, preserve_nil_under: [["deployment", "ceilings"]])
      {:ok, deep_merge(default_config(), config)}
    end
  end

  @spec write(config(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def write(config, opts \\ []) when is_map(config) do
    config = deep_merge(default_config(), config |> normalize_keys() |> drop_nil_values())
    config_path = path(opts)

    with :ok <- File.mkdir_p(root(opts)),
         :ok <- File.write(config_path, Renderer.to_yaml(config)) do
      {:ok, config_path}
    end
  end

  @spec runtime_config(config()) :: map()
  def runtime_config(config) when is_map(config) do
    config
    |> normalize_keys()
    |> Map.take(@runtime_keys)
  end

  @spec resolve_capacity(config(), String.t() | map() | nil) :: {:ok, capacity()} | {:error, term()}
  def resolve_capacity(config, nil), do: resolve_capacity(config, "normal")

  def resolve_capacity(config, profile_name) when is_binary(profile_name) do
    profiles = config |> normalize_keys() |> Map.get("capacity_profiles", %{})

    case Map.fetch(profiles, profile_name) do
      {:ok, capacity} ->
        with {:ok, normalized} <- normalize_capacity(capacity) do
          enforce_capacity_ceiling(config, profile_name, normalized)
        end

      :error ->
        case parse_capacity(profile_name) do
          {:ok, capacity} -> enforce_capacity_ceiling(config, profile_name, capacity)
          :error -> {:error, {:unknown_capacity_profile, profile_name}}
        end
    end
  end

  def resolve_capacity(config, capacity) when is_map(capacity) do
    with {:ok, normalized} <- normalize_capacity(capacity) do
      enforce_capacity_ceiling(config, "inline", normalized)
    end
  end

  @spec deep_merge(term(), term()) :: term()
  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  def deep_merge(_left, right), do: right

  @spec normalize_keys(term()) :: term()
  def normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      {to_string(key), normalize_keys(nested)}
    end)
  end

  def normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  def normalize_keys(value), do: value

  @spec drop_nil_values(term()) :: term()
  def drop_nil_values(value) when is_map(value) do
    value
    |> Enum.reject(fn {_key, nested} -> is_nil(nested) end)
    |> Map.new(fn {key, nested} -> {key, drop_nil_values(nested)} end)
  end

  def drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  def drop_nil_values(value), do: value

  defp drop_nil_values(value, opts), do: drop_nil_values(value, opts, [])

  defp drop_nil_values(value, opts, path) when is_map(value) do
    value
    |> Enum.reject(fn {key, nested} ->
      is_nil(nested) and not preserve_nil_path?(path ++ [to_string(key)], opts)
    end)
    |> Map.new(fn {key, nested} ->
      child_path = path ++ [to_string(key)]
      {key, drop_nil_values(nested, opts, child_path)}
    end)
  end

  defp drop_nil_values(value, opts, path) when is_list(value) do
    Enum.map(value, &drop_nil_values(&1, opts, path))
  end

  defp drop_nil_values(value, _opts, _path), do: value

  defp preserve_nil_path?(path, opts) do
    opts
    |> Keyword.get(:preserve_nil_under, [])
    |> Enum.any?(fn prefix ->
      length(path) > length(prefix) and Enum.take(path, length(prefix)) == prefix
    end)
  end

  defp decode_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) -> {:ok, normalize_keys(decoded)}
      {:ok, decoded} -> {:error, {:invalid_local_config, decoded}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_capacity(value) do
    case String.split(value, "/", parts: 2) do
      [agents, startups] ->
        with {agents, ""} <- Integer.parse(agents),
             {startups, ""} <- Integer.parse(startups),
             true <- agents > 0 and startups > 0 do
          {:ok, %{"max_concurrent_agents" => agents, "max_concurrent_startups" => startups}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp normalize_capacity(capacity) when is_map(capacity) do
    capacity = normalize_keys(capacity)

    with agents when is_integer(agents) and agents > 0 <- Map.get(capacity, "max_concurrent_agents"),
         startups when is_integer(startups) and startups > 0 <- Map.get(capacity, "max_concurrent_startups") do
      {:ok, %{"max_concurrent_agents" => agents, "max_concurrent_startups" => startups}}
    else
      _ -> {:error, {:invalid_capacity, capacity}}
    end
  end

  defp normalize_capacity(capacity), do: {:error, {:invalid_capacity, capacity}}

  defp enforce_capacity_ceiling(config, label, capacity) do
    with {:ok, ceilings} <- deployment_ceilings(config) do
      if capacity["max_concurrent_agents"] <= ceilings["max_concurrent_agents"] and
           capacity["max_concurrent_startups"] <= ceilings["max_concurrent_startups"] do
        {:ok, capacity}
      else
        {:error, {:capacity_exceeds_deployment_ceiling, label, capacity, ceilings}}
      end
    end
  end

  defp deployment_ceilings(config) do
    config
    |> normalize_keys()
    |> get_in(["deployment", "ceilings"])
    |> case do
      ceilings when is_map(ceilings) ->
        default_config()
        |> get_in(["deployment", "ceilings"])
        |> deep_merge(normalize_keys(ceilings))
        |> normalize_deployment_ceilings()

      _ ->
        {:ok, get_in(default_config(), ["deployment", "ceilings"])}
    end
  end

  defp normalize_deployment_ceilings(ceilings) do
    case normalize_capacity(ceilings) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, {:invalid_deployment_ceilings, ceilings}}
    end
  end
end
