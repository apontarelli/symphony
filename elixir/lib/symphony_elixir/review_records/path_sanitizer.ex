defmodule SymphonyElixir.ReviewRecords.PathSanitizer do
  @moduledoc """
  Filters review-record file paths down to durable workspace-relative paths.
  """

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.ReviewRecords.Redaction

  @runtime_state_segments MapSet.new([
                            ".cache",
                            ".elixir_ls",
                            ".git",
                            ".jj",
                            ".mix",
                            ".symphony",
                            "_build",
                            "cover",
                            "coverage",
                            "deps",
                            "log",
                            "logs",
                            "node_modules",
                            "tmp"
                          ])
  @runtime_state_root_segments MapSet.new(["cache", "temp"])
  @local_secret_paths MapSet.new([
                        ".env",
                        ".envrc",
                        ".netrc",
                        ".symphony.local.yml",
                        "linear-profile-bindings.local.yml",
                        "symphony.local.yml"
                      ])
  @local_secret_segments MapSet.new([".aws", ".gnupg", ".ssh"])
  @private_key_basenames MapSet.new(["id_dsa", "id_ecdsa", "id_ed25519", "id_rsa"])
  @local_secret_template_suffixes [".example", ".sample", ".template", ".dist"]

  @spec safe_file_list(term(), Path.t() | nil) :: [String.t()]
  def safe_file_list(values, workspace \\ nil) do
    values
    |> list_value()
    |> Enum.map(&path_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&validated_path(&1, workspace))
    |> Enum.uniq()
  end

  @spec sanitize_payload_paths(term(), Path.t() | nil) :: term()
  def sanitize_payload_paths(map, workspace) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if file_list_key?(key) do
        {key, safe_file_list(value, workspace)}
      else
        {key, sanitize_payload_paths(value, workspace)}
      end
    end)
  end

  def sanitize_payload_paths(values, workspace) when is_list(values) do
    Enum.map(values, &sanitize_payload_paths(&1, workspace))
  end

  def sanitize_payload_paths(value, _workspace), do: value

  defp validated_path(path, workspace) when is_binary(workspace) and workspace != "" do
    case PathSafety.validate_handoff_manifest(workspace, %{changed_files: [path]}) do
      {:ok, %{changed_files: [safe_path | _paths]}} ->
        [Redaction.redact_string(safe_path)]

      _error ->
        []
    end
  end

  defp validated_path(path, _workspace) do
    if safe_relative_path?(path) do
      [Redaction.redact_string(path)]
    else
      []
    end
  end

  defp safe_relative_path?(path) do
    normalized_path = normalized_relative_path(path)
    segments = Path.split(normalized_path)

    cond do
      Path.type(path) == :absolute -> false
      Enum.member?(Path.split(path), "..") -> false
      normalized_path != path -> false
      excluded_path?(segments) -> false
      true -> true
    end
  end

  defp excluded_path?(segments) do
    normalized_segments = Enum.map(segments, &String.downcase/1)
    basename = List.last(normalized_segments) || ""
    normalized_path = Path.join(normalized_segments)

    local_secret_path?(normalized_path, basename, normalized_segments) or
      runtime_state_path?(normalized_segments) or
      String.ends_with?(basename, ".log")
  end

  defp runtime_state_path?([segment | _rest] = segments) do
    MapSet.member?(@runtime_state_root_segments, segment) or
      Enum.any?(segments, &MapSet.member?(@runtime_state_segments, &1)) or
      Enum.any?(segments, &hidden_cache_segment?/1)
  end

  defp hidden_cache_segment?(segment) do
    segment == ".cache" or (String.starts_with?(segment, ".") and String.ends_with?(segment, "_cache"))
  end

  defp local_secret_path?(path, basename, segments) do
    MapSet.member?(@local_secret_paths, path) or
      MapSet.member?(@local_secret_paths, basename) or
      local_env_secret_path?(basename) or
      MapSet.member?(@private_key_basenames, basename) or
      Enum.any?(segments, &MapSet.member?(@local_secret_segments, &1))
  end

  defp local_env_secret_path?(basename) do
    String.starts_with?(basename, ".env.") and
      not Enum.any?(@local_secret_template_suffixes, &String.ends_with?(basename, &1))
  end

  defp normalized_relative_path(path) do
    path
    |> Path.split()
    |> Path.join()
  end

  defp path_string(%{} = entry) do
    entry
    |> Map.get(:path, Map.get(entry, "path"))
    |> optional_string()
  end

  defp path_string(value), do: optional_string(value)

  defp optional_string(nil), do: nil

  defp optional_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      string -> string
    end
  end

  defp list_value(values) when is_list(values), do: values
  defp list_value(_values), do: []

  defp file_list_key?(key) when key in [:changed_files, :changedFiles, :affected_files, :files], do: true
  defp file_list_key?(key) when key in ["changed_files", "changedFiles", "affected_files", "files"], do: true
  defp file_list_key?(_key), do: false
end
