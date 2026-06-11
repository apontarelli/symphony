defmodule SymphonyElixir.HandoffManifest do
  @moduledoc false

  @change_manifest_keys [:change_manifest, "change_manifest", :changeManifest, "changeManifest"]
  @changed_file_keys [:changed_files, "changed_files", :changedFiles, "changedFiles", :files, "files"]

  @type source_result :: :absent | {:present, term()} | {:failed, map()}

  @spec source(term()) :: source_result()
  def source(completion) when is_map(completion) do
    manifest_keys = present_keys(completion, @change_manifest_keys)
    changed_file_keys = present_keys(completion, @changed_file_keys)

    cond do
      length(manifest_keys) > 1 ->
        {:failed, source_failure(:duplicate_change_manifest_aliases, manifest_keys)}

      length(changed_file_keys) > 1 ->
        {:failed, source_failure(:duplicate_changed_file_aliases, changed_file_keys)}

      manifest_keys != [] and changed_file_keys != [] ->
        {:failed, source_failure(:conflicting_manifest_sources, manifest_keys ++ changed_file_keys)}

      manifest_keys != [] ->
        {:present, Map.fetch!(completion, hd(manifest_keys))}

      changed_file_keys != [] ->
        changed_files = Map.fetch!(completion, hd(changed_file_keys))
        {:present, %{changed_files: changed_files, validation: completion_field(completion, :checks, [])}}

      true ->
        :absent
    end
  end

  def source(_completion), do: :absent

  @spec source_failure(atom(), [term()]) :: map()
  def source_failure(reason, keys) when is_atom(reason) and is_list(keys) do
    %{
      path: "<manifest>",
      reason: reason,
      message: "Completion metadata must provide one unambiguous changed-file manifest source.",
      metadata: %{sources: Enum.map(keys, &manifest_key_name/1)}
    }
  end

  defp completion_field(completion, key, default) do
    Map.get(completion, key, Map.get(completion, to_string(key), default))
  end

  defp present_keys(map, keys), do: Enum.filter(keys, &Map.has_key?(map, &1))

  defp manifest_key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp manifest_key_name(key), do: to_string(key)
end
