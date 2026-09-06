defmodule SymphonyElixir.OperatorRepositoryInspection do
  @moduledoc false

  alias SymphonyElixir.{PathSafety, ProcessSupervisor}
  alias SymphonyElixir.TargetRegistry.{FileStore, RepositoryPolicy, Schema, Validation, Yaml}
  alias SymphonyElixir.Workflow.PublishTarget

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
          blockers: [map()],
          configuration_sources: map() | nil,
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
      blockers: [],
      configuration_sources: nil,
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
      {:ok, vcs, git_dir} ->
        case repository_policy(opts) do
          {:ok, policy, sources, host, configured} ->
            inspect_configured_repository(%{base | vcs: vcs}, git_dir, policy, sources, host, configured, opts)

          {:error, :registry_unavailable} ->
            fail(base, "invalid", "registry_unavailable")

          {:error, :configuration_required} ->
            fail(base, "configuration_required", "repository_configuration_required")

          {:error, diagnostics} when is_list(diagnostics) ->
            fail_with_blockers(base, "invalid", "repository_policy_invalid", diagnostics)

          {:error, _reason} ->
            fail(base, "invalid", "repository_policy_invalid")
        end

      {:error, reason} when reason in [:eacces, :eperm] ->
        base

      _ ->
        fail(base |> Map.put(:vcs, "unsupported"), "needs_setup", "repository_vcs_required")
    end
  end

  defp inspect_configured_repository(base, git_dir, policy, sources, host, configured, opts) do
    project =
      case Map.get(policy, "project", %{}) do
        project when is_map(project) -> Map.take(project, ~w(slug name repository))
        _ -> %{}
      end

    repository = canonical_repository(project["repository"])
    mode = get_in(policy, ["vcs", "mode"])
    default_branch = get_in(policy, ["vcs", "default_branch"])
    expected = repository

    base = %{
      base
      | project: Map.put(project, "repository", repository),
        default_branch: if(is_binary(default_branch), do: default_branch),
        expected_repository: if(is_binary(expected), do: expected),
        configuration_sources: sources
    }

    blockers =
      policy_identity_blockers(repository, configured, opts) ++
        policy_vcs_blockers(base, mode) ++
        policy_file_blockers(base.path, policy) ++
        runner_capability_blockers(policy, host, configured) ++
        validation_blockers(base.path, host, configured, opts)

    if blockers != [] do
      fail_with_blockers(base, "invalid", blocker_reason(blockers), blockers)
    else
      validate_remote(base, git_dir, expected)
    end
  end

  defp repository_policy(opts) do
    case {Keyword.get(opts, :host), Keyword.get(opts, :configured), Keyword.get(opts, :target_id)} do
      {host, configured, _target_id} when is_map(host) and is_map(configured) ->
        resolve_policy(host, configured)

      {host, nil, nil} when is_map(host) ->
        # Before target creation, only host defaults provide policy. Admission
        # repeats readiness with the configured target's identity and runners.
        resolve_policy(host, %{})

      {host, nil, _target_id} when is_map(host) ->
        {:error, :configuration_required}

      _ ->
        with {:ok, snapshot} <- registry(Keyword.get(opts, :registry_path)),
             host when is_map(host) <- snapshot.host,
             target_id when is_binary(target_id) <- Keyword.get(opts, :target_id),
             target when is_map(target) <- Map.get(snapshot.targets, target_id),
             configured when is_map(configured) <- Map.get(target, :configured) do
          resolve_policy(host, configured)
        else
          {:error, :registry_unavailable} -> {:error, :registry_unavailable}
          nil -> {:error, :configuration_required}
          _ -> {:error, :configuration_required}
        end
    end
  end

  defp resolve_policy(host, configured) do
    case RepositoryPolicy.resolve(host, configured) do
      {:ok, policy, sources} when is_map(policy) and is_map(sources) -> {:ok, policy, sources, host, configured}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      _ -> {:error, [%{path: "$.target.repository_policy", message: "repository policy could not be resolved"}]}
    end
  rescue
    _error -> {:error, [%{path: "$.target.repository_policy", message: "repository policy could not be resolved"}]}
  catch
    _kind, _reason -> {:error, [%{path: "$.target.repository_policy", message: "repository policy could not be resolved"}]}
  end

  defp policy_identity_blockers(repository, configured, opts) do
    policy_blockers =
      if is_binary(repository),
        do: [],
        else: [blocker("$.repository.project.repository", "repository identity is required")]

    requested_expected = Keyword.get(opts, :expected_repository)

    policy_blockers ++
      target_expected_identity_blockers(repository, configured, opts) ++
      identity_comparison_blocker(repository, requested_expected, "$.repository.expected_repository")
  end

  # Pre-target discovery still requires host policy and matching remote identity.
  defp target_expected_identity_blockers(repository, configured, opts) do
    if pre_target_request?(opts) do
      []
    else
      configured_expected = get_in(configured, ["repo", "expected_repository"])

      if is_nil(configured_expected),
        do: [blocker("$.target.repo.expected_repository", "expected repository identity is required")],
        else: identity_comparison_blocker(repository, configured_expected, "$.target.repo.expected_repository")
    end
  end

  defp pre_target_request?(opts),
    do: is_nil(Keyword.get(opts, :configured)) and is_nil(Keyword.get(opts, :target_id))

  defp identity_comparison_blocker(_repository, nil, _path), do: []

  defp identity_comparison_blocker(repository, expected, path) do
    normalized = canonical_repository(expected)

    cond do
      not is_binary(normalized) ->
        [blocker(path, "expected repository identity is invalid")]

      normalized != repository ->
        [blocker(path, "expected repository identity does not match the host policy")]

      true ->
        []
    end
  end

  defp policy_vcs_blockers(base, mode) do
    cond do
      mode not in ["git", "jj"] ->
        [blocker("$.repository.vcs.mode", "configured VCS mode must be git or jj")]

      not vcs_mode_available?(base, mode) ->
        [blocker("$.repository.vcs.mode", "configured VCS mode is unavailable in this checkout")]

      true ->
        []
    end
  end

  defp policy_file_blockers(repo, policy) do
    docs = get_in(policy, ["docs", "entrypoints"]) || []
    required_files = get_in(policy, ["validation", "required_files"]) || []

    doc_blockers =
      if is_list(docs) do
        docs
        |> Enum.with_index()
        |> Enum.flat_map(fn {entrypoint, index} ->
          validate_policy_file(repo, entrypoint, "$.repository.docs.entrypoints[#{index}]")
        end)
      else
        [blocker("$.repository.docs.entrypoints", "required documentation references must be a list")]
      end

    check_blockers =
      if is_list(required_files) do
        required_files
        |> Enum.with_index()
        |> Enum.flat_map(fn {file, index} ->
          validate_policy_file(repo, file, "$.repository.validation.required_files[#{index}]")
        end)
      else
        [blocker("$.repository.validation.required_files", "required check file references must be a list")]
      end

    doc_blockers ++ check_blockers
  end

  defp validate_policy_file(repo, file, path) do
    cond do
      not is_binary(file) or not safe_relative_path?(file) ->
        [blocker(path, "required file reference must stay inside the repository")]

      not readable_repository_file?(repo, file) ->
        [blocker(path, "required file is missing or unreadable")]

      true ->
        []
    end
  end

  defp readable_repository_file?(repo, file) do
    with {:ok, canonical_repo} <- PathSafety.canonicalize(repo),
         {:ok, candidate} <- PathSafety.canonicalize(Path.join(repo, file)),
         true <- strict_descendant?(candidate, canonical_repo),
         {:ok, %File.Stat{type: :regular, access: access}} <- File.stat(candidate),
         true <- access in [:read, :read_write] do
      true
    else
      _ -> false
    end
  end

  defp strict_descendant?(path, root) do
    path != root and path_prefix?(Path.split(path), Path.split(root))
  end

  defp path_prefix?(_segments, []), do: true
  defp path_prefix?([segment | segments], [segment | prefix]), do: path_prefix?(segments, prefix)
  defp path_prefix?(_segments, _prefix), do: false

  defp runner_capability_blockers(_policy, host, _configured) when not is_map(host), do: []

  defp runner_capability_blockers(policy, host, configured) do
    required = capability_values(get_in(policy, ["capabilities", "required"]))
    selected = selected_runner_ids(Map.get(configured, "runners"))

    host_runners = if is_map(Map.get(host, "runners")), do: Map.get(host, "runners"), else: %{}
    host_capabilities = capability_values(Map.get(host, "capabilities", %{}))

    required
    |> Enum.uniq()
    |> Enum.reject(fn capability ->
      capability in host_capabilities or
        (selected != [] and
           Enum.all?(selected, fn runner ->
             runner
             |> then(&Map.get(host_runners, &1, %{}))
             |> capability_values()
             |> Enum.member?(capability)
           end))
    end)
    |> Enum.map(
      &blocker(
        "$.repository.capabilities.required",
        "required runner capability #{Kernel.inspect(&1)} is unavailable on the selected host runners"
      )
    )
  end

  defp selected_runner_ids(%{"allowed" => [_ | _] = allowed}), do: Enum.filter(allowed, &is_binary/1)
  defp selected_runner_ids(%{"default" => default}) when is_binary(default), do: [default]
  defp selected_runner_ids(_runners), do: []

  defp capability_values(values) when is_list(values), do: Enum.filter(values, &is_binary/1)

  defp capability_values(%{"capabilities" => capabilities}), do: capability_values(capabilities)
  defp capability_values(%{"provided" => provided}), do: capability_values(provided)

  defp capability_values(values) when is_map(values) do
    for {key, true} when is_binary(key) <- values, do: key
  end

  defp capability_values(_values), do: []

  defp blocker(path, message), do: %{path: path, message: message}

  defp blocker_reason(blockers) do
    if Enum.any?(blockers, &String.ends_with?(&1.path, ".repository")) do
      "repository_identity_invalid"
    else
      "repository_policy_invalid"
    end
  end

  defp validation_blockers(repo, host, configured, opts) do
    siblings =
      opts
      |> Keyword.get(:configured_targets)
      |> sibling_targets(Keyword.get(opts, :target_id))

    repo
    |> then(
      &Validation.repository_diagnostics(
        &1,
        host,
        configured,
        Keyword.get(opts, :registry_path),
        siblings
      )
    )
    |> Enum.map(fn diagnostic ->
      %{path: diagnostic.path, message: diagnostic.message}
    end)
  rescue
    _error -> [blocker("$.repository", "repository path policy is invalid")]
  end

  defp sibling_targets(configured_targets, target_id) when is_map(configured_targets) do
    if is_binary(target_id), do: Map.drop(configured_targets, [target_id]), else: configured_targets
  end

  defp sibling_targets(_configured_targets, _target_id), do: nil

  defp fail_with_blockers(base, state, reason, blockers),
    do: %{fail(base, state, reason) | blockers: Enum.map(blockers, &public_blocker/1)}

  defp public_blocker(%{path: path, message: message}), do: %{path: path, message: message}
  defp public_blocker(_invalid), do: %{path: "$.repository", message: "repository policy is invalid"}

  defp safe_relative_path?(path) do
    Path.type(path) == :relative and path != "" and not Enum.any?(Path.split(path), &(&1 in [".", ".."]))
  end

  defp validate_remote(base, git_dir, expected) do
    case remote_identity(git_dir) do
      {:ok, ^expected} -> %{base | state: "ready", reason: nil, apply_allowed: true}
      {:error, :unsupported_config} -> fail(base, "invalid", "repository_git_config_unsupported")
      {:error, :invalid_metadata} -> fail(base, "invalid", "repository_git_config_invalid")
      {:error, reason} when reason in [:eacces, :eperm] -> fail(base, "unreadable", "repository_metadata_unreadable")
      _ -> fail(base, "identity_mismatch", "repository_remote_mismatch")
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

  defp registry(nil), do: {:error, :configuration_required}

  defp registry(path) do
    with {:ok, %{bytes: bytes}} <- FileStore.read(path),
         {:ok, document} when is_map(document) <- Yaml.decode(bytes),
         {:ok, snapshot} <- Schema.validate(document),
         snapshot = Validation.validate(%{snapshot | path: path}),
         true <- snapshot.globally_valid? do
      {:ok, snapshot}
    else
      _ -> {:error, :registry_unavailable}
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
