defmodule SymphonyElixir.ProjectWorkflows do
  @moduledoc false

  alias SymphonyElixir.{LocalConfig, RunSetup}
  alias SymphonyElixir.Workflow.Manifest

  @current_file ".current.yml"

  @type source :: :saved | :current
  @type default_rank :: :default | :main | nil
  @type workflow_summary :: %{
          required(:name) => String.t(),
          required(:path) => Path.t(),
          required(:target) => String.t(),
          required(:mode) => String.t(),
          required(:capacity) => String.t(),
          required(:source) => source(),
          required(:default_rank) => default_rank()
        }

  @spec list(Path.t(), keyword()) ::
          {:ok, [workflow_summary()], [String.t()]} | {:error, String.t()}
  def list(project, opts \\ []) when is_binary(project) and is_list(opts) do
    project_root = Path.expand(project)
    manifest_path = Manifest.manifest_path(project_root)

    with :ok <- validate_project(project_root, manifest_path) do
      {workflows, warnings} = discover(project_root, manifest_path, opts)
      {:ok, Enum.sort_by(workflows, &sort_key/1), warnings}
    end
  end

  defp validate_project(project_root, manifest_path) do
    with true <- File.regular?(manifest_path),
         {:ok, manifest} <- Manifest.read(manifest_path, repo_setup?: true),
         %{errors: []} <- Manifest.validate(project_root, manifest) do
      :ok
    else
      false ->
        {:error, "No repo setup found at #{manifest_path}. Run `symphony setup init --repo #{project_root}` first."}

      {:error, reason} ->
        {:error, "Could not read repo setup #{manifest_path}: #{format_reason(reason)}"}

      %{errors: errors} ->
        {:error, "Invalid repo setup #{manifest_path}: #{format_diagnostics(errors)}"}
    end
  end

  defp discover(project_root, manifest_path, opts) do
    runs_dir = LocalConfig.runs_dir(opts)

    if File.dir?(runs_dir) do
      discover_paths(setup_paths(runs_dir), project_root, manifest_path)
    else
      {[], []}
    end
  end

  defp discover_paths(paths, project_root, manifest_path) do
    paths
    |> Enum.reduce({[], []}, fn path, acc ->
      path
      |> read_summary(project_root, manifest_path)
      |> collect_summary(acc)
    end)
    |> then(fn {workflows, warnings} -> {workflows, Enum.reverse(warnings)} end)
  end

  defp collect_summary({:ok, summary}, {workflows, warnings}), do: {[summary | workflows], warnings}
  defp collect_summary(:unrelated, acc), do: acc
  defp collect_summary({:warning, warning}, {workflows, warnings}), do: {workflows, [warning | warnings]}

  defp setup_paths(runs_dir) do
    saved = Path.wildcard(Path.join(runs_dir, "*.yml"))
    current = Path.join(runs_dir, @current_file)

    if File.regular?(current), do: saved ++ [current], else: saved
  end

  defp read_summary(path, project_root, manifest_path) do
    with {:ok, content} <- File.read(path),
         {:ok, setup} <- decode_setup(content),
         true <- matches_project?(setup, project_root, manifest_path),
         {:ok, summary} <- summarize(path, setup) do
      {:ok, summary}
    else
      false -> :unrelated
      {:error, reason} -> {:warning, "Skipped saved workflow #{path}: #{format_reason(reason)}"}
    end
  end

  defp decode_setup(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, setup} when is_map(setup) -> {:ok, LocalConfig.normalize_keys(setup)}
      {:ok, _other} -> {:error, "expected a YAML map"}
      {:error, reason} -> {:error, "invalid YAML (#{format_reason(reason)})"}
    end
  end

  defp matches_project?(setup, project_root, manifest_path) do
    case Map.get(setup, "repo") do
      repo when is_map(repo) ->
        same_path?(Map.get(repo, "path"), project_root) or
          same_path?(Map.get(repo, "manifest"), manifest_path)

      _other ->
        false
    end
  end

  defp same_path?(path, expected) when is_binary(path), do: Path.expand(path) == Path.expand(expected)
  defp same_path?(_path, _expected), do: false

  defp summarize(path, setup) do
    source = if Path.basename(path) == @current_file, do: :current, else: :saved
    name = if source == :current, do: ".current", else: Path.basename(path, ".yml")

    with {:ok, mode} <- mode_label(setup),
         {:ok, capacity} <- capacity_label(setup) do
      {:ok,
       %{
         name: name,
         path: path,
         target: target_summary(setup),
         mode: mode,
         capacity: capacity,
         source: source,
         default_rank: default_rank(name, source)
       }}
    end
  end

  defp mode_label(setup) do
    case Map.get(setup, "mode", "continuous") do
      mode when is_binary(mode) -> {:ok, mode}
      _other -> {:error, "mode must be a string"}
    end
  end

  defp capacity_label(setup) do
    case Map.get(setup, "capacity") do
      nil ->
        {:ok, RunSetup.capacity_label(setup)}

      capacity when is_binary(capacity) ->
        {:ok, RunSetup.capacity_label(setup)}

      %{} = capacity ->
        if positive_integer?(capacity["max_concurrent_agents"]) and
             positive_integer?(capacity["max_concurrent_startups"]) do
          {:ok, RunSetup.capacity_label(setup)}
        else
          {:error, "capacity must be a profile name or custom capacity map"}
        end

      _other ->
        {:error, "capacity must be a profile name or custom capacity map"}
    end
  end

  defp target_summary(setup) do
    target = map_value(setup, "target")
    tracker = map_value(target, "tracker")
    values = Map.merge(tracker, target)

    issue_target(values) ||
      project_target_summary(values) ||
      team_target(values) ||
      query_file_target(values) ||
      query_target(values) ||
      "Unknown target"
  end

  defp issue_target(values) do
    case non_empty_list(values["issue_ids"]) do
      nil -> nil
      issue_ids -> "Issues #{Enum.join(issue_ids, ", ")}"
    end
  end

  defp project_target_summary(values) do
    if values["type"] == "project" or present?(values["project_slug"]) or present?(values["project_id"]) do
      project_target(values)
    end
  end

  defp team_target(values) do
    team = first_present([values["team_key"], values["name"]])

    if values["type"] == "team" or present?(team) do
      if team, do: "Linear team #{team}", else: "Linear team"
    end
  end

  defp query_file_target(values) do
    if present?(values["query_file"]), do: "Linear query file #{values["query_file"]}"
  end

  defp query_target(values) do
    if values["type"] in ["query", "query_manual"] or present?(values["query"]), do: "Linear query"
  end

  defp project_target(values) do
    selector = values["project_slug"] || values["project_id"]
    name = values["name"]

    cond do
      present?(name) and present?(selector) and name != selector -> "Linear project #{name} (#{selector})"
      present?(selector) -> "Linear project #{selector}"
      present?(name) -> "Linear project #{name}"
      true -> "Linear project"
    end
  end

  defp map_value(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp non_empty_list(value) when is_list(value) do
    values = Enum.filter(value, &present?/1)
    if values == [], do: nil, else: values
  end

  defp non_empty_list(_value), do: nil

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp default_rank("default", :saved), do: :default
  defp default_rank("main", :saved), do: :main
  defp default_rank(_name, _source), do: nil

  defp sort_key(%{source: :current, name: name}), do: {1, 0, name}
  defp sort_key(%{default_rank: :default, name: name}), do: {0, 0, name}
  defp sort_key(%{default_rank: :main, name: name}), do: {0, 1, name}
  defp sort_key(%{name: name}), do: {0, 2, name}

  defp format_diagnostics(diagnostics) do
    Enum.map_join(diagnostics, "; ", fn diagnostic ->
      "#{Map.get(diagnostic, :path, "manifest")}: #{Map.get(diagnostic, :message, "invalid value")}"
    end)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
