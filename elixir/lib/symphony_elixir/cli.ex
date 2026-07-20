defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with a manifest.
  """

  alias SymphonyElixir.{LocalConfig, LocalRun, LogFile, ProjectWorkflows, RunSetup, SetupMigration}
  alias SymphonyElixir.ReviewRecords.Command, as: ReviewRecordsCommand

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @acknowledgement_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @switches [
    {@acknowledgement_switch, :boolean},
    logs_root: :string,
    port: :integer,
    profile: :string
  ]
  @list_switches [repo: :string, config_root: :string, no_env_file: :boolean, help: :boolean]
  @saved_run_switches [
    {@acknowledgement_switch, :boolean},
    config_root: :string,
    logs_root: :string,
    port: :integer,
    preview: :boolean,
    profile: :string,
    repo: :string,
    yes: :boolean
  ]
  @run_switches @switches ++
                  [
                    allow_missing_capabilities: :boolean,
                    auto_land: :boolean,
                    human_review_only: :boolean,
                    ignore_markers: :boolean,
                    limit: :integer,
                    max_agents: :integer,
                    max_startups: :integer,
                    mode: :string,
                    no_land: :boolean,
                    preview: :boolean,
                    repo: :string,
                    require_review: :boolean,
                    require_validation: :boolean,
                    skip_review: :boolean,
                    skip_validation: :boolean,
                    workflow: :string,
                    picker: :boolean
                  ]

  @run_switch_keys Keyword.keys(@run_switches)
  @base_switch_keys Keyword.keys(@switches)
  @runtime_selection_switches @run_switch_keys -- (@base_switch_keys ++ [:repo])
  @shared_runtime_switches @base_switch_keys -- [@acknowledgement_switch]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          required(:file_regular?) => (String.t() -> boolean()),
          required(:set_workflow_file_path) => (String.t() -> :ok | {:error, term()}),
          required(:set_logs_root) => (String.t() -> :ok | {:error, term()}),
          required(:set_server_port_override) => (non_neg_integer() | nil -> :ok | {:error, term()}),
          required(:set_profile_override) => (String.t() | nil -> :ok | {:error, term()}),
          required(:ensure_all_started) => (-> ensure_started_result()),
          optional(:cwd) => (-> String.t()),
          optional(:tty?) => (-> boolean()),
          optional(:confirm) => (String.t() -> boolean()),
          optional(:prompt) => (String.t() -> String.t() | nil | :eof),
          optional(:puts) => (String.t() -> term())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        if workflow_command?(args) do
          System.halt(0)
        else
          wait_for_shutdown()
        end

      {:ok, message} ->
        IO.puts(message)
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()]) :: :ok | {:ok, String.t()} | {:error, String.t()}
  def evaluate(args), do: evaluate(args, runtime_deps())

  @spec evaluate([String.t()], deps()) :: :ok | {:ok, String.t()} | {:error, String.t()}
  def evaluate(["workflow" | _workflow_args], _deps) do
    {:error, "`symphony workflow` was removed; use `symphony setup init|check|preview`."}
  end

  def evaluate(["setup", "migrate" | migrate_args], _deps) do
    evaluate_setup_migrate(migrate_args)
  end

  def evaluate(["setup" | ["preview" | setup_args]], _deps) do
    setup_args
    |> then(&SymphonyElixir.WorkflowCLI.evaluate(["print" | &1]))
    |> setup_result()
  end

  def evaluate(["setup" | setup_args], _deps) do
    setup_args
    |> SymphonyElixir.WorkflowCLI.evaluate()
    |> setup_result()
  end

  def evaluate(["run" | run_args], deps) do
    evaluate_run(run_args, deps)
  end

  def evaluate(["list" | list_args], deps) do
    evaluate_list(list_args, deps)
  end

  def evaluate(["review-records" | review_record_args], _deps) do
    ReviewRecordsCommand.evaluate(review_record_args)
  end

  def evaluate([], deps) do
    cwd = deps |> Map.get(:cwd, fn -> File.cwd!() end) |> apply([])

    if RunSetup.repo_setup_valid?(cwd) do
      evaluate_picker([repo: cwd], deps)
    else
      {:ok, usage_message()}
    end
  end

  def evaluate(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps),
             :ok <- maybe_set_profile_override(opts, deps) do
          run(default_workflow_path(deps), opts, deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps),
             :ok <- maybe_set_profile_override(opts, deps) do
          run(workflow_path, opts, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  defp evaluate_list(args, deps) do
    case OptionParser.parse(args, strict: @list_switches, aliases: [h: :help]) do
      {opts, [], []} ->
        evaluate_list_options(opts, deps)

      _other ->
        {:error, list_usage_message()}
    end
  end

  defp evaluate_list_options(opts, deps) do
    if Keyword.get(opts, :help, false) do
      {:ok, list_usage_message()}
    else
      evaluate_list_catalog(opts, deps)
    end
  end

  defp evaluate_list_catalog(opts, deps) do
    project = Keyword.get(opts, :repo) || list_cwd(deps)

    case ProjectWorkflows.list(project, config_opts(opts)) do
      {:ok, workflows, warnings} ->
        {:ok, format_workflow_catalog(Path.expand(project), workflows, warnings)}

      {:error, message} ->
        {:error, message}
    end
  end

  defp list_cwd(deps) do
    deps
    |> Map.get(:cwd, fn -> System.get_env("SYMPHONY_RUN_REPO_ROOT") || File.cwd!() end)
    |> apply([])
  end

  defp format_workflow_catalog(project, workflows, warnings) do
    body =
      case workflows do
        [] ->
          "No saved workflows found for #{project}."

        workflows ->
          rows =
            Enum.map(workflows, fn workflow ->
              [
                workflow_name(workflow),
                workflow.target,
                workflow.mode,
                workflow.capacity,
                workflow_source(workflow)
              ]
            end)

          table = format_table(["NAME", "TARGET", "MODE", "CAPACITY", "SOURCE"], rows)
          "Project workflows for #{project}\n\n#{table}"
      end

    append_catalog_warnings(body, warnings)
  end

  defp workflow_name(%{default_rank: :default, name: name}), do: "#{name} [default]"
  defp workflow_name(%{default_rank: :main, name: name}), do: "#{name} [main]"
  defp workflow_name(%{name: name}), do: name

  defp workflow_source(%{source: :current, path: path}), do: "recent/unsaved (#{path})"
  defp workflow_source(%{path: path}), do: "saved (#{path})"

  defp format_table(headers, rows) do
    widths =
      [headers | rows]
      |> Enum.zip_with(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    separator = Enum.map(widths, &String.duplicate("-", &1))

    [headers, separator | rows]
    |> Enum.map_join("\n", &format_table_row(&1, widths))
  end

  defp format_table_row(row, widths) do
    last_index = length(row) - 1

    row
    |> Enum.with_index()
    |> Enum.map_join("  ", fn {value, index} ->
      if index == last_index, do: value, else: String.pad_trailing(value, Enum.at(widths, index))
    end)
  end

  defp append_catalog_warnings(output, []), do: output

  defp append_catalog_warnings(output, warnings) do
    output <> "\n\nWarnings:\n" <> Enum.map_join(warnings, "\n", &"  - #{&1}")
  end

  defp list_usage_message do
    """
    Usage:
      symphony list [--repo <path>] [--config-root <path>] [--no-env-file]

    Lists saved workflows for the active repo without starting Symphony or changing local config.
    """
    |> String.trim()
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps), do: run(workflow_path, [], deps)

  defp run(workflow_path, _opts, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)
      start_runtime(expanded_path, deps)
    else
      {:error, "Manifest file not found: #{expanded_path}"}
    end
  end

  defp start_runtime(workflow_path, deps) do
    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Symphony with manifest #{workflow_path}: #{inspect(reason)}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    """
    Usage:
      symphony setup <init|check|preview> [options]
      symphony setup migrate --repo <path> [--name <lowercase-slug>] [--config-root <path>] [--apply]
      symphony list [--repo <path>] [--config-root <path>]
      symphony run <saved-name> [--preview] [--config-root <path>] [--yes]
      symphony run [ISSUE-ID ...] [--repo <path>] [--save <lowercase-slug>] [--preview] [--yes]
      symphony run --workflow <path> [--mode watch|drain|issue_batch] [options]
    """
    |> String.trim()
  end

  defp default_workflow_path(_deps), do: Path.expand("symphony.yml")

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      set_profile_override: &SymphonyElixir.Config.set_profile_override/1,
      cwd: fn -> System.get_env("SYMPHONY_RUN_REPO_ROOT") || File.cwd!() end,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp workflow_command?(["setup" | _args]), do: true
  defp workflow_command?(_args), do: false

  defp evaluate_run(args, deps) do
    with :ok <- validate_run_args(args) do
      evaluate_supported_run(args, deps)
    end
  end

  defp validate_run_args(args) do
    cond do
      "--dry-run" in args ->
        {:error, "`--dry-run` was removed; use `symphony run <saved-name> --preview`."}

      "--setup" in args ->
        {:error, "`--setup` was removed; use `symphony run <saved-name>`."}

      "--preview" in args and "--workflow" in args ->
        {:error, "`--preview` requires a saved workflow name; explicit runtime files are start-only."}

      true ->
        :ok
    end
  end

  defp evaluate_supported_run(args, deps) do
    if "--picker" in args do
      evaluate_picker_args(args, deps)
    else
      evaluate_run_target(args, deps)
    end
  end

  defp evaluate_run_target(args, deps) do
    case saved_setup_args(args) do
      {:saved, name, opts} -> run_saved_setup(name, opts, deps)
      {:invalid_name, name} -> {:error, format_command_error({:invalid_run_setup_name, name})}
      :not_saved -> evaluate_non_saved_run(args, deps)
    end
  end

  defp evaluate_non_saved_run(args, deps) do
    if runtime_run_args?(args), do: evaluate_runtime_run(args, deps), else: evaluate_local_run(args, deps)
  end

  defp runtime_run_args?(args) do
    case OptionParser.parse(args, strict: @run_switches) do
      {opts, [], []} ->
        runtime_selection_switch?(opts) or shared_runtime_switch_without_repo?(opts)

      _ ->
        false
    end
  end

  defp runtime_selection_switch?(opts) do
    Enum.any?(@runtime_selection_switches, &Keyword.has_key?(opts, &1))
  end

  defp shared_runtime_switch_without_repo?(opts) do
    not Keyword.has_key?(opts, :repo) and Enum.any?(@shared_runtime_switches, &Keyword.has_key?(opts, &1))
  end

  defp saved_setup_args(args) do
    case OptionParser.parse(args, strict: @saved_run_switches) do
      {opts, [name], []} ->
        cond do
          issue_identifier?(name) -> :not_saved
          RunSetup.validate_name(name) == :ok -> {:saved, name, opts}
          true -> {:invalid_name, name}
        end

      _other ->
        :not_saved
    end
  end

  defp issue_identifier?(value) do
    Regex.match?(~r/^[A-Z][A-Z0-9]+-\d+$/, value) or
      Regex.match?(~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/, value)
  end

  defp evaluate_local_run(args, deps) do
    local_run_args = Enum.reject(args, &(&1 == @acknowledgement_flag))

    with {:ok, result} <- LocalRun.evaluate(local_run_args, Map.get(deps, :local_run_deps, %{})),
         :ok <- maybe_acknowledge_local_run_start(result, args) do
      if result.start?, do: run(result.workflow_path, [], deps), else: {:ok, result.preview}
    end
  end

  defp maybe_acknowledge_local_run_start(%{start?: true}, args) do
    require_guardrails_acknowledgement(local_run_acknowledgement_opts(args))
  end

  defp maybe_acknowledge_local_run_start(_result, _args), do: :ok

  defp local_run_acknowledgement_opts(args) do
    if Enum.member?(args, @acknowledgement_flag), do: [{@acknowledgement_switch, true}], else: []
  end

  defp evaluate_picker_args(args, deps) do
    switches = @saved_run_switches ++ [picker: :boolean]

    case OptionParser.parse(args, strict: switches) do
      {opts, [], []} -> evaluate_picker(opts, deps)
      _other -> {:error, usage_message()}
    end
  end

  defp evaluate_picker(opts, deps) do
    cwd = deps |> Map.get(:cwd, fn -> File.cwd!() end) |> apply([])
    repo = opts |> Keyword.get(:repo, cwd) |> Path.expand()
    tty? = deps |> Map.get(:tty?, fn -> IO.ANSI.enabled?() end) |> apply([])

    cond do
      not RunSetup.repo_setup_valid?(repo) ->
        {:error, "No valid symphony.yml found for #{repo}."}

      not tty? ->
        {:error, "Interactive workflow selection requires a TTY. Use `symphony list --repo #{repo}` then `symphony run <saved-name>`."}

      true ->
        picker_opts =
          case Keyword.get(opts, :config_root) do
            nil -> []
            root -> [config_root: root]
          end

        with {:ok, workflows, warnings} <- ProjectWorkflows.list(repo, picker_opts),
             {:ok, selection} <- prompt_workflow_selection(workflows, warnings, deps) do
          run_picker_selection(selection, workflows, Keyword.put(opts, :repo, repo), deps)
        end
    end
  end

  defp prompt_workflow_selection(workflows, warnings, deps) do
    workflow_lines =
      workflows
      |> Enum.with_index(1)
      |> Enum.map(fn {workflow, index} ->
        "  #{index}. #{workflow.name} — #{workflow.target} · #{workflow.mode} · #{workflow.capacity}"
      end)

    warning_lines = Enum.map(warnings, &"  warning: #{&1}")
    create_index = length(workflows) + 1

    prompt_text =
      (["Saved workflows:"] ++
         workflow_lines ++
         ["  #{create_index}. Create new workflow", "  q. Cancel"] ++
         warning_lines ++ ["Select workflow: "])
      |> Enum.join("\n")

    case prompt_cli(deps, prompt_text) do
      nil -> {:ok, :cancel}
      :eof -> {:ok, :cancel}
      answer -> parse_picker_selection(answer, length(workflows), create_index)
    end
  end

  defp parse_picker_selection(answer, workflow_count, create_index) do
    normalized = answer |> String.trim() |> String.downcase()

    cond do
      normalized in ["q", "quit", "cancel"] ->
        {:ok, :cancel}

      normalized == Integer.to_string(create_index) ->
        {:ok, :create}

      true ->
        case Integer.parse(normalized) do
          {index, ""} when index >= 1 and index <= workflow_count -> {:ok, {:saved, index - 1}}
          _other -> {:error, "Invalid workflow selection."}
        end
    end
  end

  defp run_picker_selection(:cancel, _workflows, _opts, _deps), do: {:ok, "Run cancelled."}

  defp run_picker_selection(:create, _workflows, opts, deps) do
    opts
    |> Keyword.delete(:picker)
    |> picker_local_run_args()
    |> evaluate_local_run(deps)
  end

  defp run_picker_selection({:saved, index}, workflows, opts, deps) do
    workflow = Enum.fetch!(workflows, index)
    launch_name = if workflow.source == :current, do: "current", else: workflow.name
    run_saved_setup(launch_name, Keyword.delete(opts, :picker), deps, workflow.path)
  end

  defp picker_local_run_args(opts) do
    []
    |> append_cli_option("--repo", Keyword.get(opts, :repo))
    |> append_cli_option("--config-root", Keyword.get(opts, :config_root))
    |> append_cli_flag("--yes", Keyword.get(opts, :yes, false))
    |> append_cli_flag(@acknowledgement_flag, Keyword.get(opts, @acknowledgement_switch, false))
  end

  defp append_cli_option(args, _flag, nil), do: args
  defp append_cli_option(args, flag, value), do: args ++ [flag, to_string(value)]
  defp append_cli_flag(args, _flag, false), do: args
  defp append_cli_flag(args, flag, true), do: args ++ [flag]

  defp prompt_cli(deps, message) do
    case Map.get(deps, :prompt) do
      prompt when is_function(prompt, 1) -> prompt.(message)
      _other -> IO.gets(message)
    end
  end

  defp run_saved_setup(name, opts, deps, selected_path \\ nil) do
    config_opts = config_opts(opts)
    preview? = Keyword.get(opts, :preview, false)

    with {:ok, config, config_path} <- load_saved_run_config(config_opts, preview?),
         {:ok, setup, setup_path} <- read_saved_workflow(name, selected_path, config_opts),
         {:ok, runtime_manifest} <- RunSetup.runtime_manifest(config, setup),
         {:ok, resolved_setup} <-
           resolve_saved_run_setup(runtime_manifest, setup, setup_path, opts, deps) do
      context = %{
        name: name,
        opts: opts,
        deps: deps,
        config_opts: config_opts,
        config: config,
        setup: setup,
        config_path: config_path,
        setup_path: setup_path,
        runtime_manifest: runtime_manifest,
        resolved_setup: resolved_setup
      }

      continue_saved_setup_run(context)
    else
      {:error, reason} -> {:error, format_command_error(reason)}
    end
  end

  defp read_saved_workflow(name, nil, config_opts), do: RunSetup.read(name, config_opts)
  defp read_saved_workflow(_name, selected_path, _config_opts), do: RunSetup.read_path(selected_path)

  defp load_saved_run_config(config_opts, true) do
    case LocalConfig.load(config_opts) do
      {:ok, config} -> {:ok, config, LocalConfig.path(config_opts)}
      {:error, :enoent} -> {:ok, LocalConfig.default_config(), LocalConfig.path(config_opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_saved_run_config(config_opts, false) do
    case LocalConfig.ensure(config_opts) do
      {:ok, _status, config, config_path} -> {:ok, config, config_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_saved_run_setup(runtime_manifest, setup, setup_path, opts, deps) do
    cwd = deps |> Map.get(:cwd, fn -> File.cwd!() end) |> apply([])
    repo = get_in(setup, ["repo", "path"]) || Keyword.get(opts, :repo, cwd)

    RunSetup.resolve_manifest(
      runtime_manifest,
      opts
      |> Keyword.put(:cwd, Path.expand(repo))
      |> Keyword.put(:repo_setup_source, "repo symphony.yml")
      |> Keyword.put(:runtime_setup_path, setup_path)
      |> Keyword.put(:runtime_setup_source, "saved workflow")
    )
  end

  defp continue_saved_setup_run(%{opts: opts, resolved_setup: resolved_setup} = context) do
    if Keyword.get(opts, :preview, false) do
      {:ok, RunSetup.preview(resolved_setup)}
    else
      start_saved_setup_runtime(context)
    end
  end

  defp start_saved_setup_runtime(context) do
    preview = RunSetup.preview(context.resolved_setup)

    with :ok <- require_guardrails_acknowledgement(context.opts),
         :ok <- validate_startup(context.resolved_setup),
         :ok <- maybe_confirm_saved_run(preview, context.opts, context.deps),
         :ok <- maybe_set_logs_root(context.opts, context.deps),
         :ok <- maybe_set_server_port(context.opts, context.deps),
         :ok <- maybe_set_profile_override(context.opts, context.deps),
         {:ok, runtime_path} <-
           RunSetup.materialize_runtime_manifest(
             context.name,
             context.config,
             context.setup,
             context.config_opts
           ) do
      resolved_setup = %{
        context.resolved_setup
        | runtime_setup_path: runtime_path,
          runtime_setup_source: "materialized saved workflow"
      }

      :ok = RunSetup.put_current(resolved_setup)
      :ok = context.deps.set_workflow_file_path.(runtime_path)
      start_runtime(runtime_path, context.deps)
    end
  end

  defp maybe_confirm_saved_run(preview, opts, deps) when is_list(opts) do
    if Keyword.get(opts, :yes, false) do
      emit_preview(preview, deps)
      :ok
    else
      confirm_run(preview, deps)
    end
  end

  defp emit_preview(preview, deps) do
    case Map.get(deps, :puts) do
      puts when is_function(puts, 1) -> puts.(preview)
      _other -> IO.puts(preview)
    end
  end

  defp evaluate_setup_migrate(args) do
    switches = [
      repo: :string,
      name: :string,
      config_root: :string,
      apply: :boolean
    ]

    case OptionParser.parse(args, strict: switches) do
      {opts, [], []} -> migrate_setup(opts, Keyword.get(opts, :apply, false))
      _other -> {:error, usage_message()}
    end
  end

  defp migrate_setup(opts, apply?) do
    with {:ok, repo} <- fetch_migration_repo(opts) do
      name = Keyword.get(opts, :name, default_run_setup_name(repo))
      config_opts = config_opts(opts)

      if apply?, do: apply_migration(repo, name, config_opts), else: preview_migration(repo, name, config_opts)
    end
  end

  defp fetch_migration_repo(opts) do
    case Keyword.fetch(opts, :repo) do
      {:ok, repo} -> {:ok, repo}
      :error -> {:error, "setup migrate requires --repo <path>."}
    end
  end

  defp apply_migration(repo, name, config_opts) do
    case SetupMigration.apply(repo, name, config_opts) do
      {:ok, plan} -> {:ok, SetupMigration.format(plan, :apply)}
      {:error, reason} -> {:error, format_command_error(reason)}
    end
  end

  defp preview_migration(repo, name, config_opts) do
    case SetupMigration.plan(repo, name, config_opts) do
      {:ok, plan} -> {:ok, SetupMigration.format(plan, :dry_run)}
      {:error, reason} -> {:error, format_command_error(reason)}
    end
  end

  defp config_opts(opts) do
    case Keyword.get(opts, :config_root) do
      nil -> []
      root -> [config_root: root]
    end
  end

  defp default_run_setup_name(repo) do
    repo
    |> Path.expand()
    |> Path.basename()
  end

  defp format_command_error({:invalid_run_setup_name, name}) do
    "Invalid saved workflow name #{inspect(name)}; use a lowercase slug such as `main` or `opencode-dogfood`."
  end

  defp format_command_error({:unknown_capacity_profile, name}), do: "Unknown capacity profile: #{name}"
  defp format_command_error({:invalid_capacity, capacity}), do: "Invalid capacity: #{inspect(capacity)}"

  defp format_command_error({:invalid_deployment_ceilings, ceilings}) do
    "Invalid deployment ceilings: #{inspect(ceilings)}. Values must be positive integers."
  end

  defp format_command_error({:capacity_exceeds_deployment_ceiling, label, capacity, ceilings}) do
    "Capacity #{label} exceeds deployment ceilings: requested #{inspect(capacity)}, ceilings #{inspect(ceilings)}"
  end

  defp format_command_error({:missing_manifest_file, path, reason}), do: "Manifest file not found: #{path} (#{reason})"
  defp format_command_error({:invalid_manifest, diagnostics}) when is_list(diagnostics), do: inspect({:invalid_manifest, diagnostics})
  defp format_command_error(reason) when is_binary(reason), do: reason
  defp format_command_error(reason), do: inspect(reason)

  defp evaluate_runtime_run(args, deps) do
    case OptionParser.parse(args, strict: @run_switches) do
      {opts, [], []} ->
        cwd = deps |> Map.get(:cwd, fn -> File.cwd!() end) |> apply([])
        opts = Keyword.put_new(opts, :cwd, cwd)
        handle_run_options(opts, deps)

      _ ->
        {:error, usage_message()}
    end
  end

  defp handle_run_options(opts, deps) do
    with {:ok, setup} <- RunSetup.resolve(opts) do
      maybe_preview_or_start_run(setup, opts, deps)
    end
  end

  defp maybe_preview_or_start_run(setup, opts, deps) do
    if Keyword.get(opts, :preview, false) do
      {:error, "`--preview` requires a saved workflow name."}
    else
      start_confirmed_run(setup, opts, deps)
    end
  end

  defp start_confirmed_run(setup, opts, deps) do
    preview = RunSetup.preview(setup)

    with :ok <- validate_startup(setup),
         :ok <- confirm_run(preview, deps),
         :ok <- apply_run_setup(setup, opts, deps) do
      start_runtime(setup.runtime_setup_path, deps)
    end
  end

  defp apply_run_setup(setup, opts, deps) do
    with :ok <- maybe_set_logs_root(opts, deps),
         :ok <- maybe_set_server_port(opts, deps),
         :ok <- maybe_set_profile_override([profile: setup.profile], deps) do
      :ok = RunSetup.put_current(setup)
      :ok = deps.set_workflow_file_path.(setup.runtime_setup_path)
    end
  end

  defp validate_startup(setup) do
    case RunSetup.startup_error(setup) do
      nil -> :ok
      error -> {:error, error}
    end
  end

  defp confirm_run(preview, deps) do
    tty? = deps |> Map.get(:tty?, &default_tty?/0) |> apply([])
    confirm = Map.get(deps, :confirm, &default_confirm/1)

    cond do
      tty? and confirm.(preview) ->
        :ok

      tty? ->
        {:error, preview <> "\n\nRun cancelled."}

      true ->
        {:error, preview <> "\n\nInteractive confirmation requires a TTY; use `symphony run --preview` to inspect without starting."}
    end
  end

  defp default_tty? do
    case :io.getopts(:standard_io) do
      opts when is_list(opts) -> Keyword.get(opts, :terminal, false) == true
      _ -> false
    end
  catch
    _kind, _reason -> false
  end

  defp default_confirm(preview) do
    IO.puts(preview)

    case IO.gets("Start Symphony? [y/N] ") do
      answer when is_binary(answer) ->
        normalized = answer |> String.trim() |> String.downcase()
        normalized in ["y", "yes"]

      _ ->
        false
    end
  end

  defp setup_result({status, output}) when status in [:ok, :error] and is_binary(output) do
    {status, setup_language(output)}
  end

  defp setup_result(result), do: result

  defp setup_language(output) do
    case String.split(output, "\n\nCompiled workflow\n", parts: 2) do
      [summary, compiled] -> setup_summary_language(summary) <> "\n\nCompiled workflow\n" <> compiled
      [summary] -> setup_summary_language(summary)
    end
  end

  defp setup_summary_language(output) do
    output
    |> String.replace("Workflow check passed", "Repo setup check passed")
    |> String.replace("Workflow check failed", "Repo setup check failed")
    |> String.replace("Resolved workflow", "Resolved repo setup")
    |> String.replace("manifest:", "setup:")
    |> String.replace("symphony workflow", "symphony setup")
    |> String.replace("symphony setup print", "symphony setup preview")
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  defp maybe_set_profile_override(opts, deps) do
    case Keyword.get_values(opts, :profile) do
      [] ->
        :ok

      values ->
        profile = values |> List.last() |> String.trim()

        if profile == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_profile_override.(profile)
        end
    end
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
