defmodule SymphonyElixir.LocalRun do
  @moduledoc """
  Builds local runtime setup files for operator-driven `symphony run` flows.
  """

  alias SymphonyElixir.{LocalConfig, RunSetup}
  alias SymphonyElixir.Workflow.Renderer

  @default_workspace_root "~/dev/symphony-workspaces"
  @default_config_dir "~/.config/symphony"
  @local_config_file "config.yml"
  @runs_dir "runs"
  @current_run_file ".current.yml"
  @tracker_target_keys ~w(project_id project_slug team_key workspace_slug assignee issue_ids query query_file)
  @capacity_ceiling 20
  @target_choices %{
    "1" => :issues,
    "2" => :project,
    "3" => :team,
    "4" => :query_file,
    "5" => :query_manual
  }

  @switches [
    repo: :string,
    config_root: :string,
    setup: :string,
    save: :string,
    yes: :boolean,
    dry_run: :boolean
  ]

  @type setup :: map()
  @type result :: %{
          required(:setup) => setup(),
          required(:workflow_path) => Path.t(),
          required(:preview) => String.t(),
          required(:start?) => boolean(),
          required(:source) => :interactive | :issues | :saved,
          optional(:saved_path) => Path.t() | nil
        }
  @type deps :: map()

  @spec evaluate([String.t()]) :: {:ok, result()} | {:error, String.t()}
  def evaluate(args), do: evaluate(args, runtime_deps())

  @spec evaluate([String.t()], deps()) :: {:ok, result()} | {:error, String.t()}
  def evaluate(args, deps) when is_list(args) and is_map(deps) do
    deps = Map.merge(runtime_deps(), deps)

    with {:ok, opts, rest} <- parse_args(args),
         {:ok, local_config, config_root} <- ensure_local_config(opts, deps),
         {:ok, setup, source, workflow_path} <- resolve_setup(rest, opts, local_config, config_root, deps),
         preview = preview(setup, workflow_path),
         {:ok, saved_path, workflow_path} <-
           maybe_save_setup(setup, workflow_path, source, opts, config_root, preview, deps),
         :ok <- persist_current_setup(setup, workflow_path, source, opts, deps),
         {:ok, start?} <- confirm_start?(opts, preview, deps) do
      {:ok,
       %{
         setup: setup,
         workflow_path: workflow_path,
         preview: preview(setup, workflow_path),
         start?: start?,
         source: source,
         saved_path: saved_path
       }}
    end
  end

  @spec preview(setup(), Path.t()) :: String.t()
  def preview(setup, workflow_path) when is_map(setup) and is_binary(workflow_path) do
    runtime = Map.get(setup, "runtime", %{})
    target = Map.get(runtime, "target") || Map.get(runtime, "run_target", %{})
    tracker = Map.get(runtime, "tracker", %{})
    agent = Map.get(runtime, "agent", %{})
    workspace = Map.get(runtime, "workspace", %{})
    capacity_name = Map.get(target, "capacity", "custom")
    max_agents = Map.get(agent, "max_concurrent_agents")
    max_startups = Map.get(agent, "max_concurrent_startups")

    [
      "Run preview",
      "Runtime setup: #{workflow_path}",
      "Target: #{RunSetup.target_summary(%{"target" => Map.put(target, "tracker", tracker)})}",
      "Mode: #{Map.get(target, "mode", "continuous")}",
      "Workspace root: #{Map.get(workspace, "root", @default_workspace_root)}",
      "Capacity: #{capacity_name} (agents=#{max_agents}, startups=#{max_startups})",
      "Tracker auth: LINEAR_API_KEY",
      discovery_summary(target)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @spec default_local_config() :: map()
  def default_local_config, do: LocalConfig.default_config()

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, rest, []} -> {:ok, opts, rest}
      {_opts, _rest, _invalid} -> {:error, usage()}
    end
  end

  defp resolve_setup(rest, opts, local_config, config_root, deps) do
    cond do
      setup_ref = Keyword.get(opts, :setup) ->
        load_setup(setup_ref, config_root, local_config, deps)

      rest == [] ->
        interactive_setup(opts, local_config, config_root, deps)

      explicit_issue_ids?(rest) ->
        issue_setup(rest, opts, local_config, config_root, deps)

      length(rest) == 1 ->
        load_setup(List.first(rest), config_root, local_config, deps)

      true ->
        {:error, usage()}
    end
  end

  defp interactive_setup(opts, local_config, config_root, deps) do
    with {:ok, target} <- prompt_target(deps),
         {:ok, capacity} <- prompt_capacity(local_config, deps),
         {:ok, mode} <- prompt_mode(default_mode(target), deps),
         {:ok, setup} <- build_setup(opts, target, capacity, mode, local_config) do
      {:ok, setup, :interactive, current_setup_path(config_root)}
    end
  end

  defp issue_setup(issue_ids, opts, local_config, config_root, _deps) do
    capacity = capacity_profile(local_config, "normal")
    target = %{type: "issues", issue_ids: issue_ids}

    with {:ok, setup} <- build_setup(opts, target, capacity, "issue-batch", local_config) do
      {:ok, setup, :issues, current_setup_path(config_root)}
    end
  end

  defp load_setup(setup_ref, config_root, local_config, deps) do
    path = setup_path(setup_ref, config_root)

    with {:ok, content} <- deps.read_file.(path),
         {:ok, setup} <- decode_yaml(content, path),
         {:ok, runtime_setup, workflow_path} <- materialize_loaded_setup(setup, path, config_root, local_config) do
      {:ok, runtime_setup, :saved, workflow_path}
    else
      {:error, :enoent} -> {:error, "Saved run setup not found: #{path}"}
      {:error, reason} when is_atom(reason) -> {:error, "Failed to read run setup #{path}: #{inspect(reason)}"}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  defp materialize_loaded_setup(%{"runtime" => _runtime} = setup, path, _config_root, _local_config) do
    {:ok, setup, path}
  end

  defp materialize_loaded_setup(run_setup, path, config_root, local_config) do
    case RunSetup.runtime_manifest(local_config, run_setup) do
      {:ok, runtime_manifest} ->
        {:ok, put_run_target(runtime_manifest, RunSetup.run_target(run_setup)), current_setup_path(config_root)}

      {:error, reason} ->
        {:error, "Invalid saved run setup #{path}: #{inspect(reason)}"}
    end
  end

  defp build_setup(opts, target, capacity, mode, local_config) do
    run_setup = run_setup(opts, target, capacity, mode)

    case RunSetup.runtime_manifest(local_config, run_setup) do
      {:ok, runtime_manifest} ->
        {:ok, put_run_target(runtime_manifest, run_target_config(target, capacity.name, mode))}

      {:error, {:invalid_manifest, diagnostics}} ->
        {:error, "Invalid repo manifest: #{format_manifest_diagnostics(diagnostics)}"}

      {:error, {:missing_manifest_file, path, reason}} ->
        {:error, "Manifest file not found: #{path} (#{reason})"}

      {:error, reason} ->
        {:error, "Failed to build runtime setup: #{inspect(reason)}"}
    end
  end

  defp run_setup(opts, target, capacity, mode) do
    %{
      "repo" => %{"path" => repo_root(opts)},
      "target" => run_setup_target(target),
      "mode" => mode,
      "capacity" => capacity_for_run_setup(capacity)
    }
  end

  defp run_setup_target(target) do
    target
    |> Map.take([:type, :name, :discovery])
    |> stringify_keys()
    |> Map.put("tracker", tracker_target_config(target))
  end

  defp capacity_for_run_setup(%{name: "custom"} = capacity) do
    %{
      "max_concurrent_agents" => capacity.max_concurrent_agents,
      "max_concurrent_startups" => capacity.max_concurrent_startups
    }
  end

  defp capacity_for_run_setup(capacity), do: capacity.name

  defp put_run_target(runtime_manifest, run_target) do
    update_in(runtime_manifest, ["runtime"], fn runtime ->
      (runtime || %{})
      |> Map.put("target", run_target)
    end)
  end

  defp repo_root(opts) do
    opts
    |> Keyword.get(:repo, System.get_env("SYMPHONY_RUN_REPO_ROOT") || File.cwd!())
    |> Path.expand()
  end

  defp ensure_local_config(opts, deps) do
    config_root = config_root(opts, deps)
    config_path = Path.join(config_root, @local_config_file)

    case deps.mkdir_p.(Path.join(config_root, @runs_dir)) do
      :ok ->
        if deps.file_regular?.(config_path) do
          read_local_config(config_path, config_root, deps)
        else
          create_local_config(config_path, config_root, deps)
        end

      {:error, reason} ->
        {:error, "Failed to create local config directory: #{inspect(reason)}"}
    end
  end

  defp read_local_config(config_path, config_root, deps) do
    with {:ok, content} <- deps.read_file.(config_path),
         {:ok, config} <- decode_yaml(content, config_path) do
      {:ok, LocalConfig.deep_merge(default_local_config(), LocalConfig.normalize_keys(config)), config_root}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Failed to read local config #{config_path}: #{inspect(reason)}"}

      {:error, message} when is_binary(message) ->
        {:error, message}
    end
  end

  defp create_local_config(config_path, config_root, deps) do
    config = default_local_config()

    case deps.write_file.(config_path, Renderer.to_yaml(config)) do
      :ok -> {:ok, config, config_root}
      {:error, reason} -> {:error, "Failed to write local config #{config_path}: #{inspect(reason)}"}
    end
  end

  defp config_root(opts, deps) do
    opts
    |> Keyword.get(:config_root)
    |> case do
      nil -> deps.env.("SYMPHONY_CONFIG_ROOT") || @default_config_dir
      value -> value
    end
    |> expand_user_path(deps)
  end

  defp maybe_save_setup(_setup, workflow_path, :saved, _opts, _config_root, _preview, _deps) do
    {:ok, nil, workflow_path}
  end

  defp maybe_save_setup(setup, workflow_path, source, opts, config_root, preview, deps) do
    case save_name(source, opts, preview, deps) do
      {:ok, nil} ->
        {:ok, nil, workflow_path}

      {:ok, name} ->
        path = named_setup_path(name, config_root)

        with :ok <- deps.mkdir_p.(Path.dirname(path)),
             :ok <- deps.write_file.(path, Renderer.to_yaml(run_setup_from_runtime(setup, opts))) do
          {:ok, path, workflow_path}
        else
          {:error, reason} -> {:error, "Failed to save run setup #{path}: #{inspect(reason)}"}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp run_setup_from_runtime(setup, opts) do
    runtime = Map.get(setup, "runtime", %{})
    run_target = Map.get(runtime, "target") || Map.get(runtime, "run_target", %{})
    tracker = runtime |> Map.get("tracker", %{}) |> Map.take(@tracker_target_keys)

    target =
      run_target
      |> Map.take(["type", "name", "discovery"])
      |> Map.put("tracker", tracker)

    %{
      "repo" => %{"path" => repo_root(opts)},
      "target" => target,
      "mode" => Map.get(run_target, "mode", "continuous"),
      "capacity" => runtime_capacity_for_run_setup(runtime, run_target)
    }
  end

  defp runtime_capacity_for_run_setup(runtime, %{"capacity" => "custom"}) do
    runtime
    |> Map.get("agent", %{})
    |> Map.take(["max_concurrent_agents", "max_concurrent_startups"])
  end

  defp runtime_capacity_for_run_setup(_runtime, %{"capacity" => capacity}) when is_binary(capacity), do: capacity
  defp runtime_capacity_for_run_setup(_runtime, _run_target), do: "normal"

  defp save_name(source, opts, preview, deps) do
    case Keyword.get(opts, :save) do
      nil ->
        if source == :interactive, do: prompt_save_name(preview, deps), else: {:ok, nil}

      name ->
        normalize_save_name(name)
    end
  end

  defp prompt_save_name(preview, deps) do
    case prompt(deps, preview <> "\n\nSave this run setup globally? [y/N] ") do
      {:ok, answer} -> maybe_prompt_setup_name(answer, deps)
      {:error, message} -> {:error, message}
    end
  end

  defp maybe_prompt_setup_name(answer, deps) do
    if yes?(answer) do
      case prompt(deps, "Setup name: ") do
        {:ok, name} -> normalize_save_name(name)
        {:error, message} -> {:error, message}
      end
    else
      {:ok, nil}
    end
  end

  defp normalize_save_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:error, "Run setup name cannot be blank"}

      String.contains?(trimmed, ["/", "\\"]) ->
        {:error, "Run setup name must not contain path separators"}

      true ->
        {:ok, trimmed}
    end
  end

  defp persist_current_setup(_setup, _workflow_path, :saved, _opts, _deps), do: :ok

  defp persist_current_setup(setup, workflow_path, _source, _opts, deps) do
    with :ok <- deps.mkdir_p.(Path.dirname(workflow_path)),
         :ok <- deps.write_file.(workflow_path, Renderer.to_yaml(setup)) do
      :ok
    else
      {:error, reason} -> {:error, "Failed to write run setup #{workflow_path}: #{inspect(reason)}"}
    end
  end

  defp confirm_start?(opts, preview, deps) do
    cond do
      Keyword.get(opts, :dry_run, false) ->
        {:ok, false}

      Keyword.get(opts, :yes, false) ->
        {:ok, true}

      true ->
        prompt_start_confirmation(preview, deps)
    end
  end

  defp prompt_start_confirmation(preview, deps) do
    case prompt(deps, preview <> "\n\nStart this run now? [Y/n] ") do
      {:ok, answer} -> {:ok, start_answer?(answer)}
      {:error, message} -> {:error, message}
    end
  end

  defp start_answer?(answer) do
    answer
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["", "y", "yes"]))
  end

  defp prompt_target(deps) do
    prompt_text = """
    Target type:
      1. Explicit issue IDs
      2. Linear project
      3. Linear team
      4. Linear query file
      5. Manual Linear query
    Choose target type [1]:
    """

    with {:ok, answer} <- prompt(deps, prompt_text) do
      case normalize_choice(answer, @target_choices, :issues) do
        :issues -> prompt_issue_ids(deps)
        :project -> prompt_project(deps)
        :team -> prompt_team(deps)
        :query_file -> prompt_query_file(deps)
        :query_manual -> prompt_query_manual(deps)
      end
    end
  end

  defp prompt_issue_ids(deps) do
    with {:ok, value} <- prompt(deps, "Issue IDs (comma or space separated): ") do
      ids = split_values(value)

      if ids == [] do
        {:error, "At least one issue ID is required"}
      else
        {:ok, %{type: "issues", issue_ids: ids}}
      end
    end
  end

  defp prompt_project(deps) do
    case discover(:projects, deps) do
      {:ok, projects} when projects != [] ->
        prompt_project_choice(projects, deps)

      {:error, reason} ->
        manual_project("failed (#{inspect(reason)}); using manual entry", deps)

      _ ->
        manual_project("unavailable; using manual entry", deps)
    end
  end

  defp prompt_project_choice(projects, deps) do
    choices = project_choice_lines(projects)

    with {:ok, answer} <- prompt(deps, "Select Linear project:\n#{choices}\n  m. Manual entry\nChoice [m]: ") do
      select_project_choice(projects, answer, deps)
    end
  end

  defp project_choice_lines(projects) do
    projects
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {project, index} ->
      "  #{index}. #{project_label(project)}"
    end)
  end

  defp project_label(project) do
    project[:name] || project["name"] || project[:slug] || project["slug"] || project[:id] || project["id"]
  end

  defp select_project_choice(projects, answer, deps) do
    case Integer.parse(answer) do
      {index, ""} when index >= 1 and index <= length(projects) ->
        projects
        |> Enum.at(index - 1)
        |> discovered_project()

      _ ->
        manual_project("manual entry", deps)
    end
  end

  defp discovered_project(project) do
    id = project[:id] || project["id"]
    name = project[:name] || project["name"]
    slug = project[:slug] || project["slug"] || project[:slug_id] || project["slug_id"]

    {:ok, %{type: "project", project_id: id, project_slug: slug, name: name, discovery: "discovered"}}
  end

  defp manual_project(discovery, deps) do
    with {:ok, value} <- prompt(deps, "Linear project ID or slug: ") do
      value = String.trim(value)

      cond do
        value == "" -> {:error, "Linear project ID or slug is required"}
        uuid?(value) -> {:ok, %{type: "project", project_id: value, discovery: discovery}}
        true -> {:ok, %{type: "project", project_slug: value, discovery: discovery}}
      end
    end
  end

  defp prompt_team(deps) do
    case discover(:teams, deps) do
      {:ok, teams} when teams != [] ->
        prompt_team_choice(teams, deps)

      {:error, reason} ->
        manual_team("failed (#{inspect(reason)}); using manual entry", deps)

      _ ->
        manual_team("unavailable; using manual entry", deps)
    end
  end

  defp prompt_team_choice(teams, deps) do
    choices =
      teams
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {team, index} ->
        key = team[:key] || team["key"]
        name = team[:name] || team["name"] || key
        "  #{index}. #{key} #{name}"
      end)

    with {:ok, answer} <- prompt(deps, "Select Linear team:\n#{choices}\n  m. Manual entry\nChoice [m]: ") do
      case Integer.parse(answer) do
        {index, ""} when index >= 1 and index <= length(teams) ->
          team = Enum.at(teams, index - 1)
          key = team[:key] || team["key"]
          name = team[:name] || team["name"]
          {:ok, %{type: "team", team_key: key, name: name, discovery: "discovered"}}

        _ ->
          manual_team("manual entry", deps)
      end
    end
  end

  defp manual_team(discovery, deps) do
    with {:ok, value} <- prompt(deps, "Linear team key: ") do
      key = value |> String.trim() |> String.upcase()

      if key == "" do
        {:error, "Linear team key is required"}
      else
        {:ok, %{type: "team", team_key: key, discovery: discovery}}
      end
    end
  end

  defp prompt_query_file(deps) do
    with {:ok, path} <- prompt(deps, "Linear query filter file path: ") do
      query_filter_file_target(path, deps)
    end
  end

  defp query_filter_file_target(path, deps) do
    path = path |> String.trim() |> expand_user_path(deps)

    if path == "" do
      {:error, "Linear query filter file path is required"}
    else
      read_query_filter_file(path, deps)
    end
  end

  defp read_query_filter_file(path, deps) do
    with {:ok, content} <- deps.read_file.(path),
         {:ok, filter} <- decode_query_filter(content, path) do
      {:ok, %{type: "query", filter: filter, query_file: path}}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Failed to read Linear query filter file #{path}: #{inspect(reason)}"}

      {:error, message} when is_binary(message) ->
        {:error, message}
    end
  end

  defp prompt_query_manual(deps) do
    with {:ok, filter_source} <- prompt(deps, "Linear query filter YAML/JSON object: ") do
      query_filter_manual_target(filter_source)
    end
  end

  defp query_filter_manual_target(filter_source) do
    filter_source = String.trim(filter_source)

    if filter_source == "" do
      {:error, "Linear query filter is required"}
    else
      build_query_filter_target(filter_source)
    end
  end

  defp build_query_filter_target(filter_source) do
    case decode_query_filter(filter_source, "inline Linear query filter") do
      {:ok, filter} -> {:ok, %{type: "query", filter: filter}}
      {:error, message} -> {:error, message}
    end
  end

  defp prompt_capacity(local_config, deps) do
    prompt_text = """
    Capacity:
      1. light
      2. normal
      3. swarm
      4. custom
    Choose capacity [2]:
    """

    with {:ok, answer} <- prompt(deps, prompt_text) do
      case normalize_choice(answer, %{"1" => "light", "2" => "normal", "3" => "swarm", "4" => "custom"}, "normal") do
        "custom" -> prompt_custom_capacity(local_config, deps)
        name -> {:ok, capacity_profile(local_config, name)}
      end
    end
  end

  defp prompt_custom_capacity(local_config, deps) do
    ceiling = capacity_ceiling(local_config)

    with {:ok, answer} <- prompt(deps, "Custom max concurrent agents (1-#{ceiling}): ") do
      case Integer.parse(answer) do
        {agents, ""} when agents >= 1 and agents <= ceiling ->
          {:ok,
           %{
             name: "custom",
             max_concurrent_agents: agents,
             max_concurrent_startups: min(agents, 2)
           }}

        _ ->
          {:error, "Custom capacity must be between 1 and #{ceiling}"}
      end
    end
  end

  defp capacity_profile(local_config, name) do
    profile =
      get_in(local_config, ["capacity_profiles", name]) ||
        get_in(default_local_config(), ["capacity_profiles", name])

    %{
      name: name,
      max_concurrent_agents: Map.fetch!(profile, "max_concurrent_agents"),
      max_concurrent_startups: Map.fetch!(profile, "max_concurrent_startups")
    }
  end

  defp capacity_ceiling(local_config) do
    case get_in(local_config, ["deployment", "ceilings", "max_concurrent_agents"]) || Map.get(local_config, "capacity_ceiling") do
      value when is_integer(value) and value > 0 -> value
      _ -> @capacity_ceiling
    end
  end

  defp prompt_mode(default, deps) do
    with {:ok, answer} <- prompt(deps, "Run mode: continuous, issue-batch, or query [#{default}]: ") do
      mode =
        answer
        |> String.trim()
        |> String.downcase()

      case mode do
        "" -> {:ok, default}
        "continuous" -> {:ok, "continuous"}
        "issue-batch" -> {:ok, "issue-batch"}
        "issue_batch" -> {:ok, "issue-batch"}
        "query" -> {:ok, "query"}
        _ -> {:error, "Run mode must be continuous, issue-batch, or query"}
      end
    end
  end

  defp default_mode(%{type: "issues"}), do: "issue-batch"
  defp default_mode(%{type: "query"}), do: "query"
  defp default_mode(%{type: "query_file"}), do: "query"
  defp default_mode(%{type: "query_manual"}), do: "query"
  defp default_mode(_target), do: "continuous"

  defp tracker_target_config(%{type: "issues", issue_ids: issue_ids}) do
    %{"issue_ids" => issue_ids}
  end

  defp tracker_target_config(%{type: "project", project_id: project_id}) when is_binary(project_id) do
    %{"project_id" => project_id}
  end

  defp tracker_target_config(%{type: "project", project_slug: project_slug}) when is_binary(project_slug) do
    %{"project_slug" => project_slug}
  end

  defp tracker_target_config(%{type: "team", team_key: team_key}) do
    %{"team_key" => team_key}
  end

  defp tracker_target_config(%{type: "query"}), do: %{}

  defp run_target_config(target, capacity_name, mode) do
    target
    |> Map.take([:type, :issue_ids, :project_id, :project_slug, :team_key, :filter, :query_file, :name, :discovery])
    |> stringify_keys()
    |> Map.put("mode", mode)
    |> Map.put("capacity", capacity_name)
  end

  defp discovery_summary(%{"discovery" => discovery}) when is_binary(discovery), do: "Discovery: #{discovery}"
  defp discovery_summary(_target), do: nil

  defp discover(kind, deps) do
    case deps.env.("LINEAR_API_KEY") do
      token when is_binary(token) and token != "" -> deps.linear_discovery.(kind, token)
      _ -> {:error, :missing_linear_api_token}
    end
  end

  defp prompt(deps, prompt) do
    case deps.prompt.(prompt) do
      nil -> {:error, "Input ended while reading local run setup"}
      :eof -> {:error, "Input ended while reading local run setup"}
      value when is_binary(value) -> {:ok, String.trim(value)}
      value -> {:ok, value |> to_string() |> String.trim()}
    end
  end

  defp normalize_choice(answer, choices, default) do
    normalized =
      answer
      |> String.trim()
      |> String.downcase()

    cond do
      normalized == "" -> default
      Map.has_key?(choices, normalized) -> Map.fetch!(choices, normalized)
      true -> normalized
    end
  end

  defp split_values(value) do
    value
    |> String.split([",", " ", "\n", "\t"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp explicit_issue_ids?(values) do
    values != [] and Enum.all?(values, &(issue_key?(&1) or linear_uuid?(&1)))
  end

  defp issue_key?(value), do: Regex.match?(~r/^[A-Z][A-Z0-9]+-\d+$/, value)
  defp linear_uuid?(value), do: Regex.match?(~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/, value)

  defp setup_path(ref, config_root) do
    expanded = Path.expand(ref)

    cond do
      Path.type(ref) == :absolute -> expanded
      String.ends_with?(ref, ".yml") or String.ends_with?(ref, ".yaml") -> Path.expand(ref)
      true -> named_setup_path(ref, config_root)
    end
  end

  defp named_setup_path(name, config_root), do: Path.join([config_root, @runs_dir, name <> ".yml"])
  defp current_setup_path(config_root), do: Path.join([config_root, @runs_dir, @current_run_file])

  defp expand_user_path(path, deps) do
    home = deps.home.()

    cond do
      path == "~" -> home
      String.starts_with?(path, "~/") -> Path.join(home, String.replace_prefix(path, "~/", ""))
      true -> Path.expand(path)
    end
  end

  defp decode_query_filter(content, source) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) -> {:ok, stringify_keys(decoded)}
      {:ok, _decoded} -> {:error, "#{source} must contain a YAML map"}
      {:error, reason} -> {:error, "Failed to parse #{source}: #{inspect(reason)}"}
    end
  end

  defp decode_yaml(content, path) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) -> {:ok, stringify_keys(decoded)}
      {:ok, _decoded} -> {:error, "#{path} must contain a YAML map"}
      {:error, reason} -> {:error, "Failed to parse #{path}: #{inspect(reason)}"}
    end
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp format_manifest_diagnostics(diagnostics) do
    Enum.map_join(diagnostics, "; ", fn diagnostic ->
      "#{diagnostic.path}: #{diagnostic.message}"
    end)
  end

  defp uuid?(value) do
    Regex.match?(~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/, value)
  end

  defp yes?(answer) do
    answer
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["y", "yes"]))
  end

  defp runtime_deps do
    %{
      prompt: &IO.gets/1,
      env: &System.get_env/1,
      home: fn -> System.user_home!() end,
      cwd: fn -> File.cwd!() end,
      file_regular?: &File.regular?/1,
      mkdir_p: &File.mkdir_p/1,
      read_file: &File.read/1,
      write_file: &File.write/2,
      linear_discovery: &discover_linear/2
    }
  end

  defp discover_linear(kind, token) when kind in [:projects, :teams] do
    query =
      case kind do
        :projects ->
          """
          query SymphonyLocalRunProjects {
            projects(first: 50) {
              nodes {
                id
                name
                slugId
              }
            }
          }
          """

        :teams ->
          """
          query SymphonyLocalRunTeams {
            teams(first: 50) {
              nodes {
                id
                key
                name
              }
            }
          }
          """
      end

    req_options =
      [
        headers: [{"Authorization", token}, {"Content-Type", "application/json"}],
        json: %{"query" => query}
      ]
      |> Keyword.merge(Application.get_env(:symphony_elixir, :linear_discovery_req_options, []))

    with {:ok, _apps} <- Application.ensure_all_started(:req),
         {:ok, response} <- Req.post("https://api.linear.app/graphql", req_options) do
      case response do
        %{status: 200, body: body} -> decode_discovery(kind, body)
        %{status: status} -> {:error, {:linear_api_status, status}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_discovery(:projects, %{"data" => %{"projects" => %{"nodes" => nodes}}}) when is_list(nodes) do
    {:ok,
     Enum.map(nodes, fn node ->
       %{
         id: node["id"],
         name: node["name"],
         slug: node["slugId"]
       }
     end)}
  end

  defp decode_discovery(:teams, %{"data" => %{"teams" => %{"nodes" => nodes}}}) when is_list(nodes) do
    {:ok,
     Enum.map(nodes, fn node ->
       %{
         id: node["id"],
         key: node["key"],
         name: node["name"]
       }
     end)}
  end

  defp decode_discovery(_kind, %{"errors" => errors}), do: {:error, {:linear_errors, errors}}
  defp decode_discovery(_kind, _body), do: {:error, :unexpected_linear_response}

  defp usage do
    """
    Usage:
      symphony run [ISSUE-ID ...] [--repo <path>] [--save <name>] [--dry-run] [--yes]
      symphony run <saved-name> [--dry-run] [--yes]
      symphony run --setup <name-or-path> [--dry-run] [--yes]
    """
    |> String.trim()
  end
end
