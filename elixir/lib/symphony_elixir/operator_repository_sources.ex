defmodule SymphonyElixir.OperatorRepositorySources do
  @moduledoc false

  alias SymphonyElixir.{DirectoryEntries, HostScheduler, LocalConfig, PathSafety}
  alias SymphonyElixir.TargetRegistry.{FileStore, Yaml}

  @max_source_bytes 1_048_576

  @spec load(GenServer.server(), keyword()) :: {:ok, map()} | {:error, atom()}
  def load(scheduler, opts) do
    with {:ok, config} <- local_config(opts),
         {:ok, settings} <- LocalConfig.repository_browser(config),
         {:ok, registry, registry_path} <- registry(scheduler, opts),
         {:ok, workflows} <- workflows(opts, settings["max_entries"], settings["timeout_ms"]) do
      targets = registry |> Map.get("targets", %{}) |> Map.values()
      recent_values = Enum.map(targets, &repository_path/1) ++ Enum.map(workflows, &repository_path/1)
      recent = recent_values |> paths() |> Enum.uniq_by(&canonical/1)
      home = canonical(System.user_home!())

      seeded =
        recent
        |> Enum.map(&Path.dirname/1)
        |> Enum.reject(fn parent -> canonical(parent) in ["/", home] end)

      root_values = settings["roots"] ++ seeded

      excluded_values =
        [LocalConfig.root(opts), Path.dirname(registry_path), get_in(registry, ["host", "state_root"]), get_in(config, ["workspace", "root"])] ++
          settings["worktree_roots"] ++
          Enum.map(targets, &nested_path(&1, "worktree", "root")) ++
          Enum.flat_map(workflows, fn workflow ->
            [nested_path(workflow, "workspace", "root"), nested_path(workflow, "worktree", "root"), nested_path(Map.get(workflow, "runtime"), "workspace", "root")]
          end)

      excluded_values = Enum.filter(excluded_values, &(is_binary(&1) and &1 != "")) |> Enum.map(&Path.expand/1)

      {:ok,
       %{
         roots: paths(root_values),
         recent: recent,
         excluded_roots: paths(excluded_values),
         exclusions: settings["exclusions"],
         max_depth: settings["max_depth"],
         max_results: settings["max_results"],
         max_entries: settings["max_entries"],
         timeout_ms: settings["timeout_ms"]
       }}
    end
  catch
    :exit, _ -> {:error, :host_unavailable}
  end

  defp local_config(opts) do
    case LocalConfig.load(opts) do
      {:error, :enoent} -> {:ok, LocalConfig.default_config()}
      {:ok, config} -> {:ok, config}
      _ -> {:error, :invalid_local_config}
    end
  end

  defp registry(scheduler, opts) do
    host = HostScheduler.snapshot(scheduler)

    case host[:registry] do
      %{verified?: true, path: path, generation: generation} when is_binary(path) ->
        with {:ok, %{bytes: bytes, generation: ^generation}} <- FileStore.read(path),
             {:ok, document} <- Yaml.decode(bytes),
             true <- is_map(document["targets"]) and is_map(document["host"]) do
          {:ok, document, path}
        else
          _ -> {:error, :registry_unavailable}
        end

      %{path: path} when is_binary(path) ->
        {:error, :registry_unavailable}

      _ ->
        # A host without a registry still supports configured roots and manual entry.
        {:ok, %{}, LocalConfig.target_registry_path(opts)}
    end
  end

  defp workflows(opts, limit, timeout_ms) do
    root = LocalConfig.runs_dir(opts)

    case File.stat(root) do
      {:error, :enoent} -> {:ok, []}
      _ -> read_workflows(root, limit, System.monotonic_time(:millisecond) + timeout_ms)
    end
  end

  defp read_workflows(root, limit, deadline) do
    root = canonical(root)

    result =
      DirectoryEntries.reduce_while(root, {limit, []}, deadline, fn
        _name, {0, _documents} ->
          {:halt, :limit}

        name, {remaining, documents} ->
          result =
            if String.valid?(name) and Path.extname(name) == ".yml" do
              read_workflow(Path.join(root, name))
            else
              {:ok, []}
            end

          case result do
            {:ok, found} -> {:cont, {remaining - 1, found ++ documents}}
            {:error, _reason} -> {:halt, :unavailable}
          end
      end)

    case result do
      {:ok, :limit} ->
        {:error, :repository_sources_limit}

      {:ok, :unavailable} ->
        {:error, :repository_sources_unavailable}

      {:ok, {_remaining, documents}} ->
        {:ok, documents |> Enum.sort_by(&elem(&1, 0), :desc) |> Enum.map(&elem(&1, 1))}

      {:error, _reason, _accumulator} ->
        {:error, :repository_sources_unavailable}
    end
  end

  defp read_workflow(path) do
    with {:ok, %{type: :regular, mtime: mtime}} <- File.lstat(path),
         {:ok, file} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, bytes} <- :file.read(file, @max_source_bytes + 1),
             true <- byte_size(bytes) <= @max_source_bytes,
             {:ok, document} when is_map(document) <- YamlElixir.read_from_string(bytes) do
          {:ok, [{mtime, document}]}
        else
          _ -> {:error, :repository_sources_unavailable}
        end
      after
        :file.close(file)
      end
    else
      _ -> {:error, :repository_sources_unavailable}
    end
  end

  defp repository_path(document) do
    nested_path(document, "repo", "path") ||
      case nested_path(document, "repo", "manifest") do
        path when is_binary(path) -> Path.dirname(path)
        _ -> nil
      end
  end

  defp nested_path(document, section, key) when is_map(document) do
    case document[section] do
      map when is_map(map) -> map[key]
      _ -> nil
    end
  end

  defp nested_path(_document, _section, _key), do: nil

  defp paths(values) do
    values
    |> valid_paths()
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp valid_paths(values) do
    Enum.filter(values, &(is_binary(&1) and &1 != "" and (&1 == "~" or Path.type(&1) == :absolute or String.starts_with?(&1, "~/"))))
  end

  defp canonical(path) do
    case PathSafety.canonicalize(path) do
      {:ok, resolved} -> resolved
      {:error, _} -> Path.expand(path)
    end
  end
end
