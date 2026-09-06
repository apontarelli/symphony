defmodule SymphonyElixir.OperatorRepositoryInspection do
  @moduledoc false

  alias SymphonyElixir.{PathSafety, ProcessSupervisor}
  alias SymphonyElixir.TargetRegistry.{FileStore, Schema, Validation, Yaml}
  alias SymphonyElixir.Workflow.{Manifest, PublishTarget}

  @max_metadata_bytes 1_048_576
  @git_env [
    {"GIT_OPTIONAL_LOCKS", "0"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_COUNT", false},
    {"GIT_CONFIG_PARAMETERS", false}
  ]

  @type result :: %{
          path: String.t() | nil,
          state: String.t(),
          reason: String.t() | nil,
          vcs: String.t() | nil,
          project: map() | nil,
          default_branch: String.t() | nil,
          expected_repository: String.t() | nil,
          warnings: [map()],
          apply_allowed: boolean()
        }

  @spec inspect(Path.t(), keyword()) :: result()
  def inspect(path, opts \\ []) do
    base = %{
      path: if(is_binary(path) and String.valid?(path), do: path),
      state: "unreadable",
      reason: "repository_unreadable",
      vcs: nil,
      project: nil,
      default_branch: nil,
      expected_repository: nil,
      warnings: [],
      apply_allowed: false
    }

    inspect_path(base, path, opts)
  end

  defp inspect_path(base, path, opts) do
    with true <- is_binary(path) and String.valid?(path) and Path.type(path) == :absolute,
         {:ok, canonical} <- PathSafety.canonicalize(path),
         {:ok, %File.Stat{type: :directory, access: access}} when access in [:read, :read_write] <- File.stat(canonical) do
      inspect_repository(%{base | path: canonical}, opts)
    else
      _ -> base
    end
  end

  defp inspect_repository(base, opts) do
    case vcs_metadata(base.path) do
      {:ok, vcs, git_dir} -> inspect_manifest(%{base | vcs: vcs}, git_dir, opts)
      {:error, reason} when reason in [:eacces, :eperm] -> base
      _ -> fail(%{base | vcs: "unsupported"}, "needs_setup", "repository_vcs_required")
    end
  end

  defp inspect_manifest(base, git_dir, opts) do
    manifest_name = Keyword.get(opts, :manifest, "symphony.yml")
    manifest_path = Path.join(base.path, manifest_name)

    with {:ok, _bytes} <- read_metadata(manifest_path),
         {:ok, snapshot} <- registry(Keyword.get(opts, :registry_path)),
         [] <- Validation.repository_diagnostics(base.path, manifest_name, snapshot),
         {:ok, manifest} <- Manifest.read(manifest_path, repo_setup?: true) do
      project = Map.take(manifest["project"], ~w(slug name repository))
      repository = canonical_repository(project["repository"])
      project = Map.put(project, "repository", repository)
      expected = expected_repository(snapshot, opts) || repository

      base = %{
        base
        | project: project,
          default_branch: manifest["vcs"]["default_branch"],
          expected_repository: if(is_binary(expected), do: expected)
      }

      validate_manifest(base, manifest, git_dir, repository, expected)
    else
      {:error, :enoent} -> fail(base, "needs_setup", "repository_manifest_missing")
      {:error, reason} when reason in [:eacces, :eperm] -> fail(base, "unreadable", "repository_manifest_unreadable")
      {:error, :registry_unavailable} -> fail(base, "invalid", "registry_unavailable")
      [_ | _] -> fail(base, "invalid", "repository_path_invalid")
      _ -> fail(base, "invalid", "repository_manifest_invalid")
    end
  end

  defp validate_manifest(base, manifest, git_dir, repository, expected) do
    report = Manifest.validate(base.path, manifest)

    case report.errors do
      [] ->
        warnings = Map.get(report, :warnings, [])
        base = %{base | warnings: Enum.map(warnings, &Map.take(&1, [:path, :message, :remediation]))}

        cond do
          not vcs_mode_available?(base, manifest["vcs"]["mode"]) -> fail(base, "invalid", "repository_vcs_mode_mismatch")
          not is_binary(repository) or not is_binary(expected) -> fail(base, "invalid", "repository_identity_invalid")
          repository != expected -> fail(base, "identity_mismatch", "repository_identity_mismatch")
          true -> validate_remote(base, git_dir, expected)
        end

      _ ->
        fail(base, "invalid", "repository_manifest_invalid")
    end
  end

  defp vcs_mode_available?(%{vcs: vcs}, vcs), do: true

  defp vcs_mode_available?(%{path: path, vcs: "jj"}, "git") do
    with {:ok, git_dir} <- metadata_directory(Path.join(path, ".git"), "gitdir: "),
         :ok <- valid_git_directory(git_dir) do
      true
    else
      _ -> false
    end
  end

  defp vcs_mode_available?(_base, _mode), do: false

  defp validate_remote(base, git_dir, expected) do
    case remote_identity(git_dir) do
      {:ok, ^expected} -> %{base | state: "ready", reason: nil, apply_allowed: true}
      {:error, :unsupported_config} -> fail(base, "invalid", "repository_git_config_unsupported")
      {:error, :invalid_metadata} -> fail(base, "invalid", "repository_git_config_invalid")
      {:error, reason} when reason in [:eacces, :eperm] -> fail(base, "unreadable", "repository_metadata_unreadable")
      _ -> fail(base, "identity_mismatch", "repository_remote_mismatch")
    end
  end

  defp expected_repository(snapshot, opts) do
    configured =
      if snapshot do
        case Map.get(snapshot.targets, Keyword.get(opts, :target_id)) do
          nil -> nil
          target -> get_in(target.configured, ["repo", "expected_repository"])
        end
      end

    case Keyword.get(opts, :expected_repository, configured) do
      nil -> nil
      value -> canonical_repository(value) || :invalid
    end
  end

  defp registry(nil), do: {:ok, nil}

  defp registry(path) do
    with {:ok, %{bytes: bytes}} <- FileStore.read(path),
         {:ok, document} when is_map(document) <- Yaml.decode(bytes),
         {:ok, snapshot} <- Schema.validate(document),
         snapshot = Validation.validate(%{snapshot | path: path}),
         true <- snapshot.globally_valid? do
      {:ok, snapshot}
    else
      _ ->
        {:error, :registry_unavailable}
    end
  end

  # Metadata reads do not invoke jj, which can snapshot or repair a working copy.
  defp vcs_metadata(path) do
    jj_repo = Path.join(path, ".jj/repo")

    if File.exists?(jj_repo) do
      with {:ok, repo} <- metadata_directory(jj_repo, ""),
           store = Path.join(repo, "store"),
           {:ok, "git" <> _} <- read_metadata(Path.join(store, "type")),
           {:ok, target} <- read_metadata(Path.join(store, "git_target")),
           git_dir = Path.expand(String.trim(target), store),
           :ok <- valid_git_directory(git_dir) do
        {:ok, "jj", git_dir}
      end
    else
      with {:ok, git_dir} <- metadata_directory(Path.join(path, ".git"), "gitdir: "),
           :ok <- valid_git_directory(git_dir) do
        {:ok, "git", git_dir}
      end
    end
  end

  defp metadata_directory(path, prefix) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, path}

      {:ok, %File.Stat{type: :regular}} ->
        with {:ok, contents} <- read_metadata(path),
             true <- String.starts_with?(contents, prefix) do
          {:ok, Path.expand(contents |> String.replace_prefix(prefix, "") |> String.trim(), Path.dirname(path))}
        else
          _ -> {:error, :invalid_metadata}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_metadata}
    end
  end

  defp valid_git_directory(path) do
    with {:ok, _head} <- read_metadata(Path.join(path, "HEAD")),
         {:ok, common} <- common_directory(path),
         true <- File.dir?(Path.join(common, "objects")) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_metadata}
    end
  end

  defp common_directory(git_dir) do
    case read_metadata(Path.join(git_dir, "commondir")) do
      {:ok, relative} -> {:ok, Path.expand(String.trim(relative), git_dir)}
      {:error, :enoent} -> {:ok, git_dir}
      error -> error
    end
  end

  defp remote_identity(git_dir) do
    with {:ok, common} <- common_directory(git_dir),
         config = Path.join(common, "config"),
         {:ok, _bytes} <- read_metadata(config),
         {:ok, {output, 0}} <-
           ProcessSupervisor.run(
             ["git", "config", "--file", config, "--no-includes", "--null", "--list"],
             1_000,
             env: @git_env,
             cleanup: :port_only
           ) do
      configured_remote_identity(output)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_metadata}
    end
  end

  defp configured_remote_identity(output) do
    entries =
      output
      |> String.split(<<0>>, trim: true)
      |> Enum.map(&String.split(&1, "\n", parts: 2))

    if Enum.any?(entries, &unsupported_git_config?/1) do
      {:error, :unsupported_config}
    else
      identities =
        for [key, value] <- entries, key in ["remote.origin.url", "remote.origin.pushurl"] do
          canonical_repository(value)
        end

      case {Enum.any?(entries, &match?(["remote.origin.url", _], &1)), Enum.uniq(identities)} do
        {true, [identity]} when is_binary(identity) -> {:ok, identity}
        _ -> {:error, :remote_unavailable}
      end
    end
  end

  defp unsupported_git_config?([key | _]) do
    key = String.downcase(key)

    key == "include.path" or String.starts_with?(key, "includeif.") or
      key == "extensions.worktreeconfig" or
      (String.starts_with?(key, "url.") and
         (String.ends_with?(key, ".insteadof") or String.ends_with?(key, ".pushinsteadof")))
  end

  defp read_metadata(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_metadata_bytes <- File.stat(path),
         {:ok, contents} <- File.read(path),
         true <- String.valid?(contents) do
      {:ok, contents}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_metadata}
    end
  end

  defp canonical_repository(value) do
    case PublishTarget.github_repository_slug(value) do
      slug when is_binary(slug) -> String.downcase(slug)
      _ -> nil
    end
  end

  defp fail(base, state, reason), do: %{base | state: state, reason: reason, apply_allowed: false}
end
