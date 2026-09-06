defmodule SymphonyElixir.TargetRegistry.Revisions do
  @moduledoc false

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.TargetRegistry.{Composition, Error, FileStore, Yaml}

  @revision ~r/^sha256:[0-9a-f]{64}$/
  @credential_key ~r/(?:^|_)(?:api_key|authorization|credential|credentials|password|passwd|secret|token|access_token|refresh_token|private_key|connection_string)$/i
  @reference ~r/^(?:\$[A-Za-z0-9._-]+|\$\{[A-Za-z0-9._-]+\}|env:[A-Za-z_][A-Za-z0-9_]*|secret:\/\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*)$/
  @uri ~r{[a-z][a-z0-9+.-]*://[^\s<>"']+}i

  # Dynamic IDs are not credential field names; their value fields still need
  # credential checks.
  @dynamic_key_paths MapSet.new([
                       ["targets"],
                       ["host", "repository_profiles"],
                       ["host", "runners"],
                       ["host", "tracker_connections"],
                       ["host", "runners", :id, "execution_profiles"],
                       ["targets", :id, "runners", "settings"],
                       ["targets", :id, "runners", "settings", :id, "execution_profiles"],
                       ["targets", :id, "concurrency", "by_linear_state"]
                     ])

  @spec archive(Path.t(), binary()) :: :ok | {:error, Error.t()}
  def archive(registry_path, bytes) do
    with {:ok, document} <- safe_document(bytes),
         {:ok, revision} <- Composition.canonical_hash(document),
         {:ok, directory} <- directory(registry_path, true),
         record = %{"revision" => revision, "recorded_at" => DateTime.to_iso8601(DateTime.utc_now()), "configuration" => document},
         {:ok, encoded} <- Jason.encode(record, pretty: true),
         :ok <- persist(Path.join(directory, filename(revision)), encoded) do
      :ok
    else
      _ -> failure()
    end
  end

  @spec export(Path.t(), String.t() | nil) :: {:ok, binary()} | {:error, Error.t()}
  def export(registry_path, revision \\ nil) do
    with {:ok, document} <- configuration(registry_path, revision) do
      {:ok, Yaml.encode(document)}
    end
  end

  @spec history(Path.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def history(registry_path) do
    with {:ok, records} <- backup(registry_path) do
      {:ok, Enum.map(records, &Map.drop(&1, ["configuration"]))}
    end
  end

  @spec backup(Path.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def backup(registry_path) do
    with {:ok, %{bytes: bytes}} <- FileStore.read(registry_path),
         :ok <- archive(registry_path, bytes),
         {:ok, directory} <- directory(registry_path, false),
         {:ok, names} <- File.ls(directory) do
      names
      |> Enum.filter(&Regex.match?(~r/^[0-9a-f]{64}\.json$/, &1))
      |> Enum.sort()
      |> read_records(directory, [])
    else
      _ -> failure()
    end
  end

  defp read_records([], _directory, records) do
    {:ok, Enum.sort_by(records, &{&1["recorded_at"], &1["revision"]})}
  end

  defp read_records([name | names], directory, records) do
    with {:ok, record} <- read_record(directory, "sha256:" <> Path.rootname(name)) do
      read_records(names, directory, [record | records])
    end
  end

  defp configuration(registry_path, nil) do
    with {:ok, %{bytes: bytes}} <- FileStore.read(registry_path), do: safe_document(bytes)
  end

  defp configuration(registry_path, revision) do
    with true <- is_binary(revision) and Regex.match?(@revision, revision),
         {:ok, directory} <- directory(registry_path, false),
         {:ok, record} <- read_record(directory, revision) do
      {:ok, record["configuration"]}
    else
      _ -> failure()
    end
  end

  defp safe_document(bytes) do
    with {:ok, %{"version" => 1, "host" => host, "targets" => targets} = document} <- Yaml.decode(bytes),
         true <- is_map(host) and is_map(targets) and credential_safe?(document) do
      {:ok, document}
    else
      _ -> failure()
    end
  end

  defp credential_safe?(value, path \\ [])

  defp credential_safe?(map, path) when is_map(map) do
    dynamic_keys? = MapSet.member?(@dynamic_key_paths, path)

    Enum.all?(map, fn {key, value} ->
      is_binary(key) and
        cond do
          dynamic_keys? ->
            credential_safe?(value, path ++ [:id])

          Regex.match?(@credential_key, key) ->
            is_nil(value) or (is_binary(value) and Regex.match?(@reference, value))

          true ->
            credential_safe?(value, path ++ [key])
        end
    end)
  end

  defp credential_safe?(list, path) when is_list(list), do: Enum.all?(list, &credential_safe?(&1, path))

  defp credential_safe?(value, _path) when is_binary(value) do
    Enum.all?(Regex.scan(@uri, value), fn [url] ->
      uri = URI.parse(url)
      safe_user = is_nil(uri.userinfo) or (uri.scheme == "ssh" and not String.contains?(uri.userinfo, ":"))
      safe_user and credential_safe?(URI.decode_query(uri.query || ""))
    end)
  rescue
    ArgumentError -> false
  end

  defp credential_safe?(_value, _path), do: true

  defp directory(registry_path, create?) do
    path = Path.expand(registry_path) <> ".revisions"

    with {:ok, canonical_parent} <- PathSafety.canonicalize(Path.dirname(path)),
         path = Path.join(canonical_parent, Path.basename(path)),
         :ok <- maybe_create(path, create?),
         {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o700 do
      {:ok, path}
    else
      _ -> failure()
    end
  end

  defp maybe_create(_path, false), do: :ok

  defp maybe_create(path, true) do
    case File.mkdir(path) do
      :ok -> File.chmod(path, 0o700)
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  defp persist(path, bytes) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> verify_existing(path, bytes)
      {:error, :enoent} -> persist_new(path, bytes)
      _ -> failure()
    end
  end

  defp persist_new(path, bytes) do
    with {:ok, ownership} <- FileStore.create_temp(path, bytes) do
      try do
        case File.ln(ownership.path, path) do
          :ok -> FileStore.sync_directory(Path.dirname(path))
          {:error, :eexist} -> verify_existing(path, bytes)
          _ -> failure()
        end
      after
        FileStore.remove_temp(ownership)
      end
    end
  end

  defp verify_existing(path, expected) do
    with {:ok, %{bytes: bytes}} <- FileStore.read(path),
         {:ok, %{"revision" => _, "configuration" => _, "recorded_at" => recorded_at} = stored} <- Jason.decode(bytes),
         true <- is_binary(recorded_at),
         {:ok, _time, _offset} <- DateTime.from_iso8601(recorded_at),
         {:ok, proposed} <- Jason.decode(expected),
         true <- Map.delete(stored, "recorded_at") == Map.delete(proposed, "recorded_at") do
      :ok
    else
      _ -> failure()
    end
  end

  defp read_record(directory, revision) do
    path = Path.join(directory, filename(revision))

    with {:ok, %{bytes: bytes}} <- FileStore.read(path),
         {:ok, %{"revision" => ^revision, "configuration" => document} = record} <- Jason.decode(bytes),
         recorded_at when is_binary(recorded_at) <- record["recorded_at"],
         {:ok, _time, _offset} <- DateTime.from_iso8601(recorded_at),
         true <- map_size(record) == 3,
         true <- credential_safe?(document),
         {:ok, ^revision} <- Composition.canonical_hash(document) do
      {:ok, record}
    else
      _ -> failure()
    end
  end

  defp filename("sha256:" <> digest), do: digest <> ".json"

  defp failure do
    {:error,
     %Error{
       code: :configuration_revision_unavailable,
       message: "configuration revision is unavailable, unsafe, or cannot be stored privately",
       path: nil
     }}
  end
end
