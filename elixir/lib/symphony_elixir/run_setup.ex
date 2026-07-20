defmodule SymphonyElixir.RunSetup do
  @moduledoc false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.LocalConfig
  alias SymphonyElixir.Workflow.Manifest
  alias SymphonyElixir.Workflow.Renderer

  @app :symphony_elixir
  @current_key :run_setup
  @name_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @tracker_target_keys ~w(project_id project_slug team_key workspace_slug assignee issue_ids query query_file)
  @modes [:watch, :drain, :issue_batch]
  @restrictive_flags [:human_review_only, :no_land, :require_review, :require_validation]
  @weakening_flags [:allow_missing_capabilities, :auto_land, :ignore_markers, :skip_review, :skip_validation]

  defstruct [
    :repo_setup_path,
    :repo_setup_source,
    :runtime_setup_path,
    :runtime_setup_source,
    :manifest,
    :repo_manifest,
    :settings,
    :mode,
    :issue_batch_limit,
    :profile,
    :capacity,
    :restrictive_flags,
    :cli_overrides,
    :source_provenance,
    warnings: []
  ]

  @type mode :: :watch | :drain | :issue_batch
  @type capacity :: %{
          max_concurrent_agents: pos_integer(),
          max_concurrent_agents_ceiling: pos_integer(),
          max_concurrent_startups: pos_integer(),
          max_concurrent_startups_ceiling: pos_integer()
        }
  @type t :: %__MODULE__{
          repo_setup_path: Path.t() | nil,
          repo_setup_source: String.t(),
          runtime_setup_path: Path.t(),
          runtime_setup_source: String.t(),
          manifest: map(),
          repo_manifest: map() | nil,
          settings: Schema.t(),
          mode: mode(),
          issue_batch_limit: pos_integer() | nil,
          profile: String.t(),
          capacity: capacity(),
          restrictive_flags: [atom()],
          cli_overrides: map(),
          source_provenance: map(),
          warnings: [String.t()]
        }

  @spec resolve(keyword()) :: {:ok, t()} | {:error, String.t()}
  def resolve(opts) when is_list(opts) do
    cwd = opts |> Keyword.get(:cwd, File.cwd!()) |> Path.expand()

    with :ok <- reject_weakening_flags(opts),
         {:ok, mode, issue_batch_limit} <- resolve_mode(opts),
         {:ok, runtime_setup_path, runtime_source} <- resolve_runtime_setup_path(opts, cwd),
         {:ok, %{config: config}, manifest} <- load_runtime_setup(runtime_setup_path),
         {:ok, settings} <- Schema.parse(config),
         {:ok, repo_setup_path, repo_source, repo_manifest} <- resolve_repo_setup(opts, cwd, runtime_setup_path),
         {:ok, capacity} <- resolve_capacity(settings, opts),
         restrictive_flags <- selected_flags(opts, @restrictive_flags),
         profile <- normalized_string(Keyword.get(opts, :profile)) || policy_profile(settings) || "default" do
      setup = %__MODULE__{
        repo_setup_path: repo_setup_path,
        repo_setup_source: repo_source,
        runtime_setup_path: runtime_setup_path,
        runtime_setup_source: runtime_source,
        manifest: manifest,
        repo_manifest: repo_manifest,
        settings: settings,
        mode: mode,
        issue_batch_limit: issue_batch_limit,
        profile: profile,
        capacity: capacity,
        restrictive_flags: restrictive_flags,
        cli_overrides: cli_overrides(opts),
        source_provenance: source_provenance(repo_source, runtime_source, opts),
        warnings: marker_warnings(repo_manifest || manifest, settings)
      }

      {:ok, setup}
    else
      {:error, reason} -> {:error, if(is_binary(reason), do: reason, else: inspect(reason))}
    end
  end

  @type setup :: map()

  @spec path(String.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def path(name, opts \\ []) when is_binary(name) do
    if valid_name?(name) do
      {:ok, Path.join(LocalConfig.runs_dir(opts), name <> ".yml")}
    else
      {:error, {:invalid_run_setup_name, name}}
    end
  end

  @spec read(String.t(), keyword()) :: {:ok, setup(), Path.t()} | {:error, term()}
  def read(name, opts \\ []) do
    with {:ok, setup_path} <- path(name, opts),
         {:ok, content} <- File.read(setup_path),
         {:ok, setup} <- decode_yaml(content) do
      {:ok, setup, setup_path}
    end
  end

  @spec write(String.t(), setup(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def write(name, setup, opts \\ []) when is_map(setup) do
    with {:ok, setup_path} <- path(name, opts),
         :ok <- File.mkdir_p(Path.dirname(setup_path)),
         :ok <- File.write(setup_path, Renderer.to_yaml(LocalConfig.normalize_keys(setup))) do
      {:ok, setup_path}
    end
  end

  @spec runtime_manifest(map(), setup()) :: {:ok, map()} | {:error, term()}
  def runtime_manifest(local_config, setup) when is_map(local_config) and is_map(setup) do
    setup = LocalConfig.normalize_keys(setup)

    with {:ok, manifest} <- repo_manifest(setup),
         {:ok, capacity} <- LocalConfig.resolve_capacity(local_config, Map.get(setup, "capacity")),
         {:ok, runtime} <- runtime_config(local_config, setup, capacity),
         runtime_manifest = Map.put(public_manifest(manifest), "runtime", runtime),
         :ok <- validate_runtime_manifest(runtime_manifest) do
      {:ok, runtime_manifest}
    end
  end

  @spec materialize_runtime_manifest(String.t(), map(), setup(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def materialize_runtime_manifest(name, local_config, setup, opts \\ []) do
    with {:ok, runtime_manifest} <- runtime_manifest(local_config, setup),
         {:ok, runtime_path} <- runtime_path(name, opts),
         :ok <- File.mkdir_p(Path.dirname(runtime_path)),
         :ok <- File.write(runtime_path, Renderer.to_yaml(runtime_manifest)) do
      {:ok, runtime_path}
    end
  end

  @spec capacity_label(setup()) :: String.t()
  def capacity_label(setup) when is_map(setup) do
    case Map.get(LocalConfig.normalize_keys(setup), "capacity") do
      value when is_binary(value) -> value
      %{} = value -> "#{value["max_concurrent_agents"]}/#{value["max_concurrent_startups"]}"
      _ -> "normal"
    end
  end

  @spec run_target(setup()) :: map()
  def run_target(setup) when is_map(setup) do
    setup = LocalConfig.normalize_keys(setup)
    target = map_value(setup, "target")
    tracker = map_value(target, "tracker")

    target
    |> Map.drop(["tracker"])
    |> Map.merge(Map.take(tracker, @tracker_target_keys))
    |> Map.put("mode", persisted_mode_label(setup))
    |> Map.put("capacity", capacity_label(setup))
  end

  @spec persisted_mode_label(setup()) :: term()
  def persisted_mode_label(setup) when is_map(setup) do
    setup = LocalConfig.normalize_keys(setup)
    Map.get(setup, "mode", default_mode_for_target(map_value(setup, "target")))
  end

  @spec target_summary(setup()) :: String.t()
  def target_summary(setup) when is_map(setup) do
    setup
    |> run_target()
    |> summarize_target()
  end

  defp default_mode_for_target(%{"type" => type}) when type in ["query", "query_file", "query_manual"], do: "query"
  defp default_mode_for_target(%{"type" => "issues"}), do: "issue-batch"
  defp default_mode_for_target(_target), do: "continuous"

  defp summarize_target(%{"type" => "issues", "issue_ids" => issue_ids}) do
    "Issues #{Enum.join(issue_ids || [], ", ")}"
  end

  defp summarize_target(%{"type" => "project", "name" => name, "project_id" => project_id})
       when is_binary(name) and is_binary(project_id) do
    "Linear project #{name} (#{project_id})"
  end

  defp summarize_target(%{"type" => "project", "project_id" => project_id}), do: "Linear project #{project_id}"
  defp summarize_target(%{"type" => "project", "project_slug" => slug}), do: "Linear project #{slug}"
  defp summarize_target(%{"type" => "project", "name" => name}), do: "Linear project #{name}"
  defp summarize_target(%{"type" => "project"}), do: "Linear project"
  defp summarize_target(%{"type" => "team", "team_key" => key}), do: "Linear team #{key}"
  defp summarize_target(%{"type" => "query", "query_file" => path}), do: "Linear query filter file #{path}"
  defp summarize_target(%{"type" => "query"}), do: "Linear query filter"
  defp summarize_target(%{"type" => "query_file", "query_file" => path}), do: "Linear query file #{path}"
  defp summarize_target(%{"type" => "query_manual"}), do: "Manual Linear query"
  defp summarize_target(_target), do: "Unknown target"

  defp map_value(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  @spec repo_setup_valid?(Path.t()) :: boolean()
  def repo_setup_valid?(cwd) when is_binary(cwd) do
    repo_root = Path.expand(cwd)
    path = Path.join(repo_root, Manifest.manifest_file_name())

    with true <- File.regular?(path),
         {:ok, manifest} <- Manifest.read(path, repo_setup?: true),
         %{errors: []} <- Manifest.validate(repo_root, manifest) do
      true
    else
      _ -> false
    end
  end

  @spec preview(t()) :: String.t()
  def preview(%__MODULE__{} = setup) do
    settings = setup.settings
    runner_name = Schema.default_runner_name(settings)
    runner = Schema.default_runner_config!(settings)
    tracker = settings.tracker
    capacity = setup.capacity

    [
      "Run preview",
      "repo setup: #{path_or_none(setup.repo_setup_path)} (source: #{setup.repo_setup_source})",
      "runtime setup: #{setup.runtime_setup_path} (source: #{setup.runtime_setup_source})",
      "run target:",
      "  tracker: #{tracker_target(tracker)}",
      "  delivery target: #{delivery_target(setup)}",
      "marker intersection: #{marker_intersection(setup.repo_manifest || setup.manifest, tracker)}",
      "eligible states: #{Enum.join(tracker.active_states, ", ")}",
      "mode: #{mode_label(setup)}",
      "capacity:",
      "  max agents: #{capacity.max_concurrent_agents} (ceiling: #{capacity.max_concurrent_agents_ceiling})",
      "  max startups: #{capacity.max_concurrent_startups} (ceiling: #{capacity.max_concurrent_startups_ceiling})",
      "runner/deployment:",
      "  runner: #{runner_name} (#{Map.get(runner, "kind")})",
      "  command: #{Enum.join(Map.get(runner, "command", []), " ")}",
      "  model: #{Map.get(runner, "model")}",
      "  worker: #{worker_summary(settings)}",
      "  server port: #{server_port_summary(settings)}",
      "workspace root: #{settings.workspace.root}",
      "restrictive flags: #{flags_summary(setup.restrictive_flags)}",
      warning_section(setup.warnings),
      "source provenance:",
      "  repo setup: #{setup.source_provenance.repo_setup}",
      "  runtime setup: #{setup.source_provenance.runtime_setup}",
      "  profile: #{setup.source_provenance.profile}",
      "  CLI overrides: #{cli_override_summary(setup.cli_overrides)}"
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @spec startup_error(t()) :: String.t() | nil
  def startup_error(%__MODULE__{settings: settings}) do
    cond do
      is_nil(settings.tracker.kind) ->
        "Tracker kind missing in selected workflow config"

      settings.tracker.kind not in ["linear", "memory"] ->
        "Unsupported tracker kind in selected workflow config: #{inspect(settings.tracker.kind)}"

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        "Linear API token missing in selected workflow config"

      settings.tracker.kind == "linear" and not linear_scope_configured?(settings.tracker) ->
        "Linear project_id, project_slug, team_key, issue_ids, query, or query_file missing in selected workflow config"

      true ->
        nil
    end
  end

  @spec put_current(t() | map() | nil) :: :ok
  def put_current(nil), do: clear_current()

  def put_current(setup) when is_map(setup) do
    Application.put_env(@app, @current_key, setup)
    :ok
  end

  @spec clear_current() :: :ok
  def clear_current do
    Application.delete_env(@app, @current_key)
    :ok
  end

  @spec current() :: t() | map() | nil
  def current, do: Application.get_env(@app, @current_key)

  @spec capacity(Schema.t()) :: capacity()
  def capacity(%Schema{} = settings) do
    case current() do
      %{capacity: %{} = capacity} -> normalize_capacity(capacity, settings)
      %{"capacity" => %{} = capacity} -> normalize_capacity(capacity, settings)
      _ -> default_capacity(settings)
    end
  end

  @spec mode() :: mode()
  def mode do
    case current() do
      %{mode: mode} -> normalize_mode_value(mode) || :watch
      %{"mode" => mode} -> normalize_mode_value(mode) || :watch
      _ -> :watch
    end
  end

  @spec issue_batch_limit() :: pos_integer() | nil
  def issue_batch_limit do
    case current() do
      %{issue_batch_limit: limit} when is_integer(limit) and limit > 0 -> limit
      %{"issue_batch_limit" => limit} when is_integer(limit) and limit > 0 -> limit
      _ -> nil
    end
  end

  @spec apply_restrictive_policy(map()) :: map()
  def apply_restrictive_policy(policy) when is_map(policy) do
    current_flags()
    |> Enum.reduce(policy, &apply_restrictive_flag/2)
  end

  def apply_restrictive_policy(policy), do: policy

  defp current_flags do
    case current() do
      %{restrictive_flags: flags} when is_list(flags) -> flags
      %{"restrictive_flags" => flags} when is_list(flags) -> flags
      _ -> []
    end
  end

  defp apply_restrictive_flag(:no_land, policy) do
    policy
    |> put_run_setup_flag(:no_land)
    |> put_in(["auto_land"], Map.merge(Map.get(policy, "auto_land", %{}), %{"posture" => "off", "dry_run" => true}))
  end

  defp apply_restrictive_flag(:human_review_only, policy) do
    policy
    |> put_run_setup_flag(:human_review_only)
    |> put_in(["auto_land"], Map.merge(Map.get(policy, "auto_land", %{}), %{"posture" => "off", "dry_run" => true}))
    |> Map.put("handoff_route", "human_review")
  end

  defp apply_restrictive_flag(:require_validation, policy) do
    append_unique(policy, "completion_requirements", "Run setup requires validation evidence before handoff.")
    |> put_run_setup_flag(:require_validation)
  end

  defp apply_restrictive_flag(:require_review, policy) do
    append_unique(policy, "review_requirements", "Run setup requires review evidence before handoff.")
    |> put_run_setup_flag(:require_review)
  end

  defp apply_restrictive_flag(_flag, policy), do: policy

  defp put_run_setup_flag(policy, flag) do
    update_in(policy, ["run_setup"], fn
      value when is_map(value) ->
        flags = value |> Map.get("restrictive_flags", []) |> List.wrap()
        Map.put(value, "restrictive_flags", Enum.uniq(flags ++ [to_string(flag)]))

      _ ->
        %{"restrictive_flags" => [to_string(flag)]}
    end)
  end

  defp append_unique(policy, key, value) do
    Map.update(policy, key, [value], fn
      values when is_list(values) -> Enum.uniq(values ++ [value])
      _ -> [value]
    end)
  end

  defp reject_weakening_flags(opts) do
    case selected_flags(opts, @weakening_flags) do
      [] ->
        :ok

      flags ->
        flag_text = Enum.map_join(flags, ", ", &("--" <> String.replace(to_string(&1), "_", "-")))
        {:error, "refusing to weaken repo safety policy with #{flag_text}"}
    end
  end

  defp resolve_mode(opts) do
    mode = Keyword.get(opts, :mode, "watch")

    with {:ok, normalized_mode} <- normalize_mode(mode),
         {:ok, limit} <- normalize_issue_batch_limit(normalized_mode, Keyword.get(opts, :limit)) do
      {:ok, normalized_mode, limit}
    end
  end

  defp normalize_mode(mode) when is_atom(mode) do
    if mode in @modes, do: {:ok, mode}, else: {:error, "unsupported run mode: #{mode}"}
  end

  defp normalize_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "watch" -> {:ok, :watch}
      "drain" -> {:ok, :drain}
      "issue_batch" -> {:ok, :issue_batch}
      "issue-batch" -> {:ok, :issue_batch}
      other -> {:error, "unsupported run mode: #{other}"}
    end
  end

  defp normalize_mode(_mode), do: {:error, "unsupported run mode"}

  defp normalize_mode_value(value) do
    case normalize_mode(value) do
      {:ok, mode} -> mode
      {:error, _reason} -> nil
    end
  end

  defp normalize_issue_batch_limit(:issue_batch, nil), do: {:ok, 1}

  defp normalize_issue_batch_limit(:issue_batch, limit) when is_integer(limit) and limit > 0, do: {:ok, limit}

  defp normalize_issue_batch_limit(:issue_batch, _limit),
    do: {:error, "issue_batch mode requires --limit to be a positive integer when provided"}

  defp normalize_issue_batch_limit(_mode, nil), do: {:ok, nil}
  defp normalize_issue_batch_limit(_mode, limit) when is_integer(limit) and limit > 0, do: {:ok, limit}
  defp normalize_issue_batch_limit(_mode, _limit), do: {:error, "--limit must be a positive integer"}

  defp resolve_runtime_setup_path(opts, cwd) do
    cond do
      path = normalized_string(Keyword.get(opts, :workflow)) ->
        {:ok, Path.expand(path, cwd), "cli --workflow"}

      File.regular?(Path.join(cwd, "symphony.runtime.yml")) ->
        {:ok, Path.join(cwd, "symphony.runtime.yml"), "cwd symphony.runtime.yml"}

      File.regular?(Path.join(cwd, Manifest.manifest_file_name())) ->
        {:ok, Path.join(cwd, Manifest.manifest_file_name()), "cwd repo setup fallback"}

      true ->
        {:error, "local runtime setup not found; pass --workflow /path/to/symphony.runtime.yml"}
    end
  end

  defp load_runtime_setup(path) do
    with true <- File.regular?(path),
         {:ok, loaded} <- Manifest.load(path),
         {:ok, manifest} <- Manifest.read(path) do
      {:ok, loaded, manifest}
    else
      false -> {:error, "runtime setup file not found: #{path}"}
      {:error, reason} -> {:error, format_manifest_error(path, reason)}
    end
  end

  defp resolve_repo_setup(opts, cwd, runtime_setup_path) do
    path_and_source =
      cond do
        repo = normalized_string(Keyword.get(opts, :repo)) ->
          {repo_path(repo, cwd), "cli --repo"}

        File.regular?(Path.join(cwd, Manifest.manifest_file_name())) ->
          {Path.join(cwd, Manifest.manifest_file_name()), "cwd symphony.yml"}

        Path.basename(runtime_setup_path) == Manifest.manifest_file_name() ->
          {runtime_setup_path, "runtime setup path"}

        true ->
          {nil, "not found"}
      end

    case path_and_source do
      {nil, source} ->
        {:ok, nil, source, nil}

      {path, source} ->
        case Manifest.read(path, repo_setup?: true) do
          {:ok, manifest} -> {:ok, path, source, manifest}
          {:error, reason} -> {:error, format_manifest_error(path, reason)}
        end
    end
  end

  defp repo_path(path, cwd) do
    expanded = Path.expand(path, cwd)
    if File.dir?(expanded), do: Path.join(expanded, Manifest.manifest_file_name()), else: expanded
  end

  defp resolve_capacity(settings, opts) do
    ceiling = default_capacity(settings)
    max_agents = Keyword.get(opts, :max_agents) || ceiling.max_concurrent_agents_ceiling
    max_startups = Keyword.get(opts, :max_startups) || ceiling.max_concurrent_startups_ceiling

    cond do
      not positive_integer?(max_agents) ->
        {:error, "--max-agents must be a positive integer"}

      not positive_integer?(max_startups) ->
        {:error, "--max-startups must be a positive integer"}

      max_agents > ceiling.max_concurrent_agents_ceiling ->
        {:error, "capacity override exceeds deployment ceiling: max agents #{max_agents} > ceiling #{ceiling.max_concurrent_agents_ceiling}"}

      max_startups > ceiling.max_concurrent_startups_ceiling ->
        {:error, "capacity override exceeds deployment ceiling: max startups #{max_startups} > ceiling #{ceiling.max_concurrent_startups_ceiling}"}

      true ->
        {:ok, %{ceiling | max_concurrent_agents: max_agents, max_concurrent_startups: max_startups}}
    end
  end

  defp default_capacity(%Schema{} = settings) do
    runner = Schema.default_runner_config!(settings)
    startup_ceiling = min_positive(settings.agent.max_concurrent_startups, Map.get(runner, "max_concurrent_startups"))

    %{
      max_concurrent_agents: settings.agent.max_concurrent_agents,
      max_concurrent_agents_ceiling: settings.agent.max_concurrent_agents,
      max_concurrent_startups: startup_ceiling,
      max_concurrent_startups_ceiling: startup_ceiling
    }
  end

  defp normalize_capacity(capacity, settings) do
    ceiling = default_capacity(settings)
    agents = positive_map_integer(capacity, :max_concurrent_agents)
    agent_ceiling = positive_map_integer(capacity, :max_concurrent_agents_ceiling)
    startups = positive_map_integer(capacity, :max_concurrent_startups)
    startup_ceiling = positive_map_integer(capacity, :max_concurrent_startups_ceiling)

    %{
      max_concurrent_agents: agents || ceiling.max_concurrent_agents,
      max_concurrent_agents_ceiling: agent_ceiling || ceiling.max_concurrent_agents_ceiling,
      max_concurrent_startups: startups || ceiling.max_concurrent_startups,
      max_concurrent_startups_ceiling: startup_ceiling || ceiling.max_concurrent_startups_ceiling
    }
  end

  defp positive_map_integer(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp min_positive(left, right) when is_integer(left) and left > 0 and is_integer(right) and right > 0,
    do: min(left, right)

  defp min_positive(left, _right) when is_integer(left) and left > 0, do: left
  defp min_positive(_left, right) when is_integer(right) and right > 0, do: right
  defp min_positive(_left, _right), do: 1

  defp selected_flags(opts, flags) do
    Enum.filter(flags, &Keyword.get(opts, &1, false))
  end

  defp cli_overrides(opts) do
    opts
    |> Keyword.take([:limit, :logs_root, :max_agents, :max_startups, :mode, :port, :profile])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp source_provenance(repo_source, runtime_source, opts) do
    %{
      repo_setup: repo_source,
      runtime_setup: runtime_source,
      profile: if(Keyword.has_key?(opts, :profile), do: "cli --profile", else: "workflow policy metadata")
    }
  end

  defp marker_warnings(manifest, settings) do
    markers = Map.get(manifest, "issue_markers", %{})
    marker_labels = Map.get(markers, "labels", [])
    required_labels = settings.tracker.required_labels || []
    allowed_projects = Map.get(markers, "allowed_projects", [])
    tracker_project = settings.tracker.project_slug || settings.tracker.project_id

    label_warnings =
      case marker_labels -- required_labels do
        [] -> []
        missing -> ["repo marker labels not required by runtime target: #{Enum.join(missing, ", ")}"]
      end

    project_warnings =
      if allowed_projects != [] and is_binary(tracker_project) and tracker_project not in allowed_projects do
        ["runtime project #{tracker_project} is outside repo allowed_projects: #{Enum.join(allowed_projects, ", ")}"]
      else
        []
      end

    label_warnings ++ project_warnings
  end

  defp tracker_target(tracker) do
    selector =
      cond do
        is_binary(tracker.project_slug) -> "project_slug=#{tracker.project_slug}"
        is_binary(tracker.project_id) -> "project_id=#{tracker.project_id}"
        is_binary(tracker.team_key) -> "team_key=#{tracker.team_key}"
        true -> "missing Linear scope"
      end

    labels = if tracker.required_labels == [], do: "none", else: Enum.join(tracker.required_labels, ", ")
    "#{tracker.kind || "missing"} #{selector}; required labels: #{labels}"
  end

  defp delivery_target(%__MODULE__{settings: %{policy_metadata: _metadata}, manifest: manifest}) do
    get_in(manifest, ["delivery", "pr_target"]) || "missing"
  end

  defp marker_intersection(manifest, tracker) do
    markers = Map.get(manifest, "issue_markers", %{})
    labels = Map.get(markers, "labels", [])
    required = tracker.required_labels || []
    intersection = labels |> Enum.map(&String.downcase/1) |> Enum.filter(&(&1 in required)) |> Enum.uniq()

    cond do
      labels == [] and Map.get(markers, "allowed_projects", []) == [] ->
        "none"

      intersection == [] ->
        "no label overlap"

      true ->
        Enum.join(intersection, ", ")
    end
  end

  defp mode_label(%__MODULE__{mode: :issue_batch, issue_batch_limit: limit}), do: "issue_batch (limit: #{limit})"
  defp mode_label(%__MODULE__{mode: mode}), do: to_string(mode)

  defp worker_summary(%Schema{worker: %{ssh_hosts: []}}), do: "local"
  defp worker_summary(%Schema{worker: %{ssh_hosts: hosts}}), do: "ssh hosts: #{Enum.join(hosts, ", ")}"

  defp server_port_summary(%Schema{server: %{port: port}}) when is_integer(port), do: Integer.to_string(port)
  defp server_port_summary(_settings), do: "disabled"

  defp flags_summary([]), do: "none"
  defp flags_summary(flags), do: flags |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")

  defp warning_section([]), do: "warnings: none"
  defp warning_section(warnings), do: ["warnings:" | Enum.map(warnings, &"  - #{&1}")]

  defp cli_override_summary(overrides) when map_size(overrides) == 0, do: "none"

  defp cli_override_summary(overrides) do
    overrides
    |> Enum.sort()
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp path_or_none(nil), do: "none"
  defp path_or_none(path), do: path

  defp valid_name?(name) do
    Regex.match?(@name_pattern, name) and not String.contains?(name, "..")
  end

  defp decode_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) -> {:ok, LocalConfig.normalize_keys(decoded)}
      {:ok, decoded} -> {:error, {:invalid_run_setup, decoded}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo_manifest(setup) do
    case repo_manifest_path(setup) do
      path when is_binary(path) -> Manifest.read(path, repo_setup?: true)
      _ -> {:error, :missing_run_setup_repo}
    end
  end

  defp repo_manifest_path(%{"repo" => %{"manifest" => manifest}}) when is_binary(manifest), do: Path.expand(manifest)

  defp repo_manifest_path(%{"repo" => %{"path" => repo_path}}) when is_binary(repo_path) do
    repo_path
    |> Path.expand()
    |> Manifest.manifest_path()
  end

  defp repo_manifest_path(_setup), do: nil

  defp public_manifest(manifest) do
    manifest
    |> Map.delete("_field_sources")
    |> Map.delete("_runtime_allowed?")
    |> Map.delete("runtime")
    |> update_in(["workflow"], fn
      workflow when is_map(workflow) -> Map.delete(workflow, "_module_requests")
      workflow -> workflow
    end)
  end

  defp runtime_config(local_config, setup, capacity) do
    runtime =
      local_config
      |> LocalConfig.runtime_config()
      |> LocalConfig.deep_merge(%{"agent" => capacity})
      |> LocalConfig.deep_merge(%{"tracker" => legacy_target_tracker(setup)})
      |> LocalConfig.deep_merge(%{"target" => runtime_target(setup)})
      |> LocalConfig.deep_merge(%{"tracker" => restrictive_tracker_flags(setup)})

    {:ok, runtime}
  end

  defp legacy_target_tracker(setup) do
    target = Map.get(setup, "target", %{})

    case Map.get(target, "tracker") do
      tracker when is_map(tracker) ->
        Map.take(tracker, @tracker_target_keys)

      _ ->
        Map.take(target, @tracker_target_keys)
    end
  end

  defp runtime_target(setup) do
    target = Map.get(setup, "target", %{})

    tracker =
      case Map.get(target, "tracker") do
        tracker when is_map(tracker) -> tracker
        _ -> %{}
      end

    target
    |> Map.drop(["tracker"])
    |> Map.merge(Map.take(tracker, @tracker_target_keys))
  end

  defp restrictive_tracker_flags(setup) do
    flags = Map.get(setup, "restrictive_flags", %{})

    case Map.get(flags, "required_labels") do
      labels when is_list(labels) -> %{"required_labels" => labels}
      _ -> %{}
    end
  end

  defp validate_runtime_manifest(runtime_manifest) do
    runtime_path = Path.join(System.tmp_dir!(), "symphony-runtime-#{System.unique_integer([:positive])}.yml")

    try do
      with :ok <- File.write(runtime_path, Renderer.to_yaml(runtime_manifest)),
           {:ok, _loaded} <- Manifest.load(runtime_path, repo_setup?: false) do
        :ok
      end
    after
      File.rm(runtime_path)
    end
  end

  defp runtime_path(name, opts) do
    if valid_name?(name) do
      {:ok, Path.join([LocalConfig.root(opts), "runtime", name <> ".runtime.yml"])}
    else
      {:error, {:invalid_run_setup_name, name}}
    end
  end

  defp format_manifest_error(path, {:missing_manifest_file, _path, _reason}), do: "manifest file not found: #{path}"

  defp format_manifest_error(path, {:manifest_parse_error, reason}),
    do: "failed to parse manifest #{path}: #{inspect(reason)}"

  defp format_manifest_error(_path, {:invalid_manifest, diagnostics}) do
    "invalid manifest: " <>
      Enum.map_join(diagnostics, ", ", fn %{path: path, message: message} -> "#{path} #{message}" end)
  end

  defp policy_profile(%Schema{policy_metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("profile")
    |> normalized_string()
  end

  defp linear_scope_configured?(tracker) do
    is_binary(tracker.project_id) or is_binary(tracker.project_slug) or is_binary(tracker.team_key) or
      tracker.issue_ids != [] or non_empty_string?(tracker.query) or non_empty_string?(tracker.query_file)
  end

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp normalized_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalized_string(_value), do: nil
end
