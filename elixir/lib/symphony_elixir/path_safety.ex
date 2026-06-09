defmodule SymphonyElixir.PathSafety do
  @moduledoc false

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
  @max_symlink_resolution_depth 40
  @changed_file_alias_keys [:changed_files, "changed_files", :changedFiles, "changedFiles", :files, "files"]

  @type handoff_manifest_result :: %{
          changed_files: [String.t()],
          validation: term()
        }

  @type handoff_manifest_failure :: %{
          path: String.t(),
          reason: atom(),
          message: String.t(),
          metadata: map()
        }

  @type handoff_manifest_error :: %{
          status: :failed,
          summary: String.t(),
          failures: [handoff_manifest_failure()]
        }

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  @spec validate_handoff_manifest(Path.t(), map()) ::
          {:ok, handoff_manifest_result()} | {:error, handoff_manifest_error()}
  def validate_handoff_manifest(workspace, manifest) when is_binary(workspace) and is_map(manifest) do
    normalized_manifest = normalize_manifest_keys(manifest)
    validation = Map.get(normalized_manifest, :validation, Map.get(normalized_manifest, :checks, []))

    with :ok <- validate_changed_file_aliases(manifest),
         {:ok, changed_files} <- extract_changed_files(normalized_manifest),
         {:ok, canonical_workspace} <- canonicalize_workspace(workspace) do
      failures = Enum.flat_map(changed_files, &validate_changed_file(&1, canonical_workspace))

      case failures do
        [] -> {:ok, %{changed_files: changed_files, validation: validation}}
        failures -> {:error, handoff_manifest_error(failures)}
      end
    else
      {:error, %{} = error} ->
        {:error, error}

      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error,
         handoff_manifest_error([
           failure(
             "<workspace>",
             :workspace_unreadable,
             "Workspace path could not be resolved for handoff manifest validation.",
             %{workspace: path, error: inspect(reason)}
           )
         ])}
    end
  end

  def validate_handoff_manifest(_workspace, _manifest) do
    {:error,
     handoff_manifest_error([
       failure(
         "<manifest>",
         :invalid_manifest,
         "Handoff manifest must be a map with a changed_files list.",
         %{}
       )
     ])}
  end

  defp normalize_manifest_keys(manifest) do
    Map.new(manifest, fn {key, value} ->
      {normalize_manifest_key(key), value}
    end)
  end

  defp normalize_manifest_key(key) when key in [:changed_files, :changedFiles, :files],
    do: :changed_files

  defp normalize_manifest_key(key) when key in ["changed_files", "changedFiles", "files"],
    do: :changed_files

  defp normalize_manifest_key(key) when key in [:validation, "validation"], do: :validation
  defp normalize_manifest_key(key) when key in [:checks, "checks"], do: :checks
  defp normalize_manifest_key(key), do: key

  defp validate_changed_file_aliases(manifest) do
    case present_keys(manifest, @changed_file_alias_keys) do
      [] ->
        :ok

      [_alias_key] ->
        :ok

      alias_keys ->
        {:error,
         handoff_manifest_error([
           failure(
             "<manifest.changed_files>",
             :invalid_manifest,
             "Handoff manifest must use only one changed-file list field.",
             %{aliases: Enum.map(alias_keys, &manifest_key_name/1)}
           )
         ])}
    end
  end

  defp present_keys(map, keys), do: Enum.filter(keys, &Map.has_key?(map, &1))

  defp manifest_key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp manifest_key_name(key), do: to_string(key)

  defp extract_changed_files(%{changed_files: changed_files}) when is_list(changed_files) do
    changed_files
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> changed_file_path(entry, index) end)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, path}, {:ok, paths} ->
        {:cont, {:ok, [path | paths]}}

      {:error, failure}, {:ok, _paths} ->
        {:halt, {:error, handoff_manifest_error([failure])}}
    end)
    |> case do
      {:ok, []} ->
        {:error,
         handoff_manifest_error([
           failure(
             "<manifest.changed_files>",
             :empty_changed_files,
             "Handoff manifest must include at least one changed file path.",
             %{}
           )
         ])}

      {:ok, paths} ->
        {:ok, Enum.reverse(paths)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp extract_changed_files(%{changed_files: changed_files}) do
    {:error,
     handoff_manifest_error([
       failure(
         "<manifest.changed_files>",
         :invalid_manifest,
         "Handoff manifest changed_files field must be a list.",
         %{type: value_type(changed_files)}
       )
     ])}
  end

  defp extract_changed_files(_manifest) do
    {:error,
     handoff_manifest_error([
       failure(
         "<manifest.changed_files>",
         :missing_changed_files,
         "Handoff manifest must include a changed_files list.",
         %{}
       )
     ])}
  end

  defp changed_file_path(path, _index) when is_binary(path), do: {:ok, path}

  defp changed_file_path(%{} = entry, index) do
    case Map.get(entry, :path, Map.get(entry, "path")) do
      path when is_binary(path) ->
        {:ok, path}

      _path ->
        {:error, invalid_manifest_entry_failure(index, entry)}
    end
  end

  defp changed_file_path(entry, index) do
    {:error, invalid_manifest_entry_failure(index, entry)}
  end

  defp invalid_manifest_entry_failure(index, entry) do
    failure(
      "<manifest.changed_files[#{index}]>",
      :invalid_path,
      "Changed-file manifest entries must be strings or maps with a string path.",
      %{index: index, type: value_type(entry)}
    )
  end

  defp value_type(value) when is_binary(value), do: "string"
  defp value_type(value) when is_boolean(value), do: "boolean"
  defp value_type(value) when is_atom(value), do: "atom"
  defp value_type(value) when is_integer(value), do: "integer"
  defp value_type(value) when is_float(value), do: "float"
  defp value_type(value) when is_list(value), do: "list"
  defp value_type(value) when is_map(value), do: "map"
  defp value_type(_value), do: "term"

  defp canonicalize_workspace(workspace) do
    workspace
    |> String.trim()
    |> case do
      "" ->
        {:error, {:path_canonicalize_failed, workspace, :empty_workspace}}

      trimmed ->
        with {:ok, canonical_workspace} <- canonicalize(trimmed),
             :ok <- existing_workspace_directory(canonical_workspace) do
          {:ok, canonical_workspace}
        end
    end
  end

  defp existing_workspace_directory(canonical_workspace) do
    case File.stat(canonical_workspace) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, {:path_canonicalize_failed, canonical_workspace, {:not_directory, type}}}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, canonical_workspace, reason}}
    end
  end

  defp validate_changed_file(path, canonical_workspace) do
    cond do
      String.trim(path) == "" ->
        [failure(path, :empty_path, "Changed file path must not be blank.", %{})]

      String.contains?(path, [<<0>>, "\n", "\r"]) ->
        [
          failure(
            path,
            :invalid_path,
            "Changed file path contains unsupported control characters.",
            %{}
          )
        ]

      Path.type(path) == :absolute ->
        [failure(path, :absolute_path, "Changed file path must be relative to the workspace.", %{})]

      path_traversal?(path) ->
        [failure(path, :path_traversal, "Changed file path must not contain `..` traversal.", %{})]

      not normalized_relative_path?(path) ->
        [
          failure(
            path,
            :not_normalized,
            "Changed file path must be normalized before handoff.",
            %{normalized_path: normalized_relative_path(path)}
          )
        ]

      excluded = excluded_handoff_path(path) ->
        [excluded_failure(path, excluded)]

      true ->
        validate_workspace_containment(path, canonical_workspace)
    end
  end

  defp path_traversal?(path) do
    path
    |> Path.split()
    |> Enum.member?("..")
  end

  defp normalized_relative_path?(path), do: normalized_relative_path(path) == path

  defp normalized_relative_path(path) do
    path
    |> Path.split()
    |> Path.join()
  end

  defp validate_workspace_containment(path, canonical_workspace) do
    candidate = Path.join(canonical_workspace, path)

    case canonicalize(candidate) do
      {:ok, canonical_candidate} ->
        if inside_path?(canonical_candidate, canonical_workspace) do
          validate_resolved_workspace_path(path, canonical_candidate, canonical_workspace)
        else
          [
            failure(
              path,
              :outside_workspace,
              "Changed file path resolves outside the workspace.",
              %{workspace: canonical_workspace, resolved_path: canonical_candidate}
            )
          ]
        end

      {:error, {:path_canonicalize_failed, expanded_path, reason}} ->
        [
          path_resolution_failure(path, expanded_path, reason)
        ]
    end
  end

  defp path_resolution_failure(path, expanded_path, :symlink_loop) do
    failure(
      path,
      :symlink_loop,
      "Changed file path could not be resolved because it contains a symlink cycle.",
      %{expanded_path: expanded_path}
    )
  end

  defp path_resolution_failure(path, expanded_path, reason) do
    failure(
      path,
      :path_unreadable,
      "Changed file path could not be resolved for handoff manifest validation.",
      %{expanded_path: expanded_path, error: inspect(reason)}
    )
  end

  defp validate_resolved_workspace_path(path, canonical_candidate, canonical_workspace) do
    resolved_relative_path = String.replace_prefix(canonical_candidate, canonical_workspace <> "/", "")

    cond do
      existing_directory?(canonical_candidate) ->
        [
          failure(
            path,
            :not_file,
            "Changed file path must name a file path, not a directory.",
            %{resolved_path: canonical_candidate, resolved_relative_path: resolved_relative_path}
          )
        ]

      excluded = excluded_handoff_path(resolved_relative_path) ->
        [
          excluded_failure(path, excluded, %{
            resolved_path: canonical_candidate,
            resolved_relative_path: resolved_relative_path
          })
        ]

      true ->
        []
    end
  end

  defp existing_directory?(canonical_candidate) do
    case File.stat(canonical_candidate) do
      {:ok, %File.Stat{type: :directory}} -> true
      _stat -> false
    end
  end

  defp excluded_handoff_path(path) do
    segments = Path.split(path)
    normalized_segments = Enum.map(segments, &String.downcase/1)
    basename = List.last(normalized_segments)
    normalized_path = Path.join(normalized_segments)

    cond do
      local_secret_path?(normalized_path, basename, normalized_segments) ->
        :local_secret

      runtime_state_path?(normalized_segments, basename) ->
        :generated_runtime_state

      String.ends_with?(basename || "", ".log") ->
        :generated_runtime_state

      true ->
        nil
    end
  end

  defp runtime_state_path?(segments, _basename) do
    Enum.any?(segments, &MapSet.member?(@runtime_state_segments, &1)) or
      root_runtime_state_path?(segments) or
      Enum.any?(segments, &hidden_cache_segment?/1)
  end

  defp root_runtime_state_path?([segment | _rest]), do: MapSet.member?(@runtime_state_root_segments, segment)

  defp hidden_cache_segment?(segment) do
    segment == ".cache" or (String.starts_with?(segment, ".") and String.ends_with?(segment, "_cache"))
  end

  defp inside_path?(path, root) do
    path != root and String.starts_with?(path <> "/", root <> "/")
  end

  defp local_secret_path?(path, basename, segments) do
    MapSet.member?(@local_secret_paths, path) or
      MapSet.member?(@local_secret_paths, basename || "") or
      local_env_secret_path?(basename || "") or
      private_key_path?(basename || "") or
      Enum.any?(segments, &MapSet.member?(@local_secret_segments, &1))
  end

  defp local_env_secret_path?(basename) do
    String.starts_with?(basename, ".env.") and
      not Enum.any?(@local_secret_template_suffixes, &String.ends_with?(basename, &1))
  end

  defp private_key_path?(basename), do: MapSet.member?(@private_key_basenames, basename)

  defp excluded_failure(path, reason, metadata \\ %{})

  defp excluded_failure(path, :generated_runtime_state, metadata) do
    failure(
      path,
      :generated_runtime_state,
      "Changed file path points at generated runtime state, logs, caches, or temporary local data.",
      metadata
    )
  end

  defp excluded_failure(path, :local_secret, metadata) do
    failure(
      path,
      :local_secret,
      "Changed file path points at local secret or operator-local configuration data.",
      metadata
    )
  end

  defp handoff_manifest_error(failures) do
    %{
      status: :failed,
      summary: "Changed-file manifest rejected: #{failure_count_summary(failures)}",
      failures: failures
    }
  end

  defp failure(path, reason, message, metadata) do
    %{
      path: path,
      reason: reason,
      message: message,
      metadata: metadata
    }
  end

  defp failure_count_summary(failures) do
    reasons =
      failures
      |> Enum.map(& &1.reason)
      |> Enum.uniq()
      |> Enum.map_join(", ", &Atom.to_string/1)

    "#{length(failures)} failure(s): #{reasons}"
  end

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  defp resolve_segments(root, resolved_segments, segments) do
    resolve_segments(root, resolved_segments, segments, 0)
  end

  defp resolve_segments(root, resolved_segments, [], _symlink_depth),
    do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(_root, _resolved_segments, _segments, symlink_depth)
       when symlink_depth >= @max_symlink_resolution_depth do
    {:error, :symlink_loop}
  end

  defp resolve_segments(root, resolved_segments, [segment | rest], symlink_depth) do
    candidate_path = join_path(root, resolved_segments ++ [segment])

    case File.lstat(candidate_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        resolve_symlink_segment(candidate_path, join_path(root, resolved_segments), rest, symlink_depth)

      {:ok, _stat} ->
        resolve_segments(root, resolved_segments ++ [segment], rest, symlink_depth)

      {:error, :enoent} ->
        {:ok, join_path(root, resolved_segments ++ [segment | rest])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_symlink_segment(candidate_path, parent_path, rest, symlink_depth) do
    with {:ok, target} <- :file.read_link_all(String.to_charlist(candidate_path)) do
      resolved_target = Path.expand(IO.chardata_to_string(target), parent_path)
      {target_root, target_segments} = split_absolute_path(resolved_target)

      resolve_segments(
        target_root,
        [],
        target_segments ++ rest,
        symlink_depth + 1
      )
    end
  end

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end
end
