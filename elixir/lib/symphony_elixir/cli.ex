defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with a manifest.
  """

  alias SymphonyElixir.{LocalRun, LogFile}
  alias SymphonyElixir.ReviewRecords.Command, as: ReviewRecordsCommand
  alias SymphonyElixir.RunSetup
  alias SymphonyElixir.SetupMigration

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @acknowledgement_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @switches [
    {@acknowledgement_switch, :boolean},
    logs_root: :string,
    port: :integer,
    profile: :string
  ]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          required(:file_regular?) => (String.t() -> boolean()),
          required(:set_workflow_file_path) => (String.t() -> :ok | {:error, term()}),
          required(:set_logs_root) => (String.t() -> :ok | {:error, term()}),
          required(:set_server_port_override) => (non_neg_integer() | nil -> :ok | {:error, term()}),
          required(:set_profile_override) => (String.t() | nil -> :ok | {:error, term()}),
          required(:ensure_all_started) => (-> ensure_started_result())
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
  def evaluate(["workflow" | workflow_args], _deps) do
    SymphonyElixir.WorkflowCLI.evaluate(workflow_args)
  end

  def evaluate(["run" | run_args], deps) do
    evaluate_run(run_args, deps)
  end

  def evaluate(["setup", "migrate" | migrate_args], _deps) do
    evaluate_setup_migrate(migrate_args)
  end

  def evaluate(["review-records" | review_record_args], _deps) do
    ReviewRecordsCommand.evaluate(review_record_args)
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
    [
      "Usage: symphony [--logs-root <path>] [--port <port>] [--profile <name>] [path-to-symphony.yml]",
      "       symphony run [target...] [--repo <path>] [--config-root <path>] [--setup <name>] [--save <name>] [--dry-run] [--yes]",
      "       symphony run <name> [--config-root <path>] [--dry-run] [--i-understand-that-this-will-be-running-without-the-usual-guardrails]",
      "       symphony setup migrate --repo <path> [--name <name>] [--config-root <path>] [--dry-run|--apply]"
    ]
    |> Enum.join("\n")
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
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp workflow_command?(["workflow" | _args]), do: true
  defp workflow_command?(["setup" | _args]), do: true
  defp workflow_command?(_args), do: false

  defp evaluate_run(args, deps) do
    case legacy_saved_setup_args(args) do
      {:legacy, name, opts} ->
        run_saved_setup(name, opts, deps)

      :not_legacy ->
        evaluate_local_run(args, deps)
    end
  end

  defp legacy_saved_setup_args(args) do
    switches = [
      {@acknowledgement_switch, :boolean},
      config_root: :string,
      dry_run: :boolean,
      logs_root: :string,
      port: :integer,
      profile: :string
    ]

    case OptionParser.parse(args, strict: switches) do
      {opts, [name], []} ->
        if legacy_saved_setup?(name, opts) do
          {:legacy, name, opts}
        else
          :not_legacy
        end

      {_opts, _rest, []} ->
        :not_legacy

      {_opts, _rest, _invalid} ->
        :not_legacy
    end
  end

  defp legacy_saved_setup?(name, opts) do
    case RunSetup.read(name, config_opts(opts)) do
      {:ok, setup, _setup_path} -> legacy_saved_setup_shape?(setup)
      {:error, _reason} -> false
    end
  end

  defp legacy_saved_setup_shape?(%{"repo" => repo}) when is_map(repo), do: true
  defp legacy_saved_setup_shape?(_setup), do: false

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

  defp run_saved_setup(name, opts, deps) do
    config_opts = config_opts(opts)

    with {:ok, _status, config, config_path} <- SymphonyElixir.LocalConfig.ensure(config_opts),
         {:ok, setup, setup_path} <- RunSetup.read(name, config_opts),
         {:ok, runtime_manifest} <- RunSetup.runtime_manifest(config, setup) do
      continue_saved_setup_run(%{
        name: name,
        opts: opts,
        deps: deps,
        config_opts: config_opts,
        config: config,
        setup: setup,
        config_path: config_path,
        setup_path: setup_path,
        runtime_manifest: runtime_manifest
      })
    else
      {:error, reason} -> {:error, format_command_error(reason)}
    end
  end

  defp continue_saved_setup_run(context) do
    case Keyword.get(context.opts, :dry_run, false) do
      true ->
        {:ok, run_dry_run_output(context.name, context.config_path, context.setup_path, context.setup, context.runtime_manifest)}

      false ->
        start_saved_setup_runtime(context.name, context.opts, context.deps, context.config_opts, context.config, context.setup)
    end
  end

  defp start_saved_setup_runtime(name, opts, deps, config_opts, config, setup) do
    with :ok <- require_guardrails_acknowledgement(opts),
         :ok <- maybe_set_logs_root(opts, deps),
         :ok <- maybe_set_server_port(opts, deps),
         :ok <- maybe_set_profile_override(opts, deps),
         {:ok, runtime_path} <- RunSetup.materialize_runtime_manifest(name, config, setup, config_opts) do
      run(runtime_path, opts, deps)
    end
  end

  defp evaluate_setup_migrate(args) do
    switches = [
      repo: :string,
      name: :string,
      config_root: :string,
      dry_run: :boolean,
      apply: :boolean
    ]

    case OptionParser.parse(args, strict: switches) do
      {opts, [], []} ->
        migrate_setup(opts)

      _ ->
        {:error, usage_message()}
    end
  end

  defp migrate_setup(opts) do
    case {Keyword.get(opts, :dry_run, false), Keyword.get(opts, :apply, false)} do
      {true, true} -> {:error, "Choose either --dry-run or --apply, not both."}
      {_dry_run?, apply?} -> migrate_setup(opts, apply?)
    end
  end

  defp migrate_setup(opts, apply?) do
    with {:ok, repo} <- fetch_migration_repo(opts) do
      name = Keyword.get(opts, :name, default_run_setup_name(repo))
      config_opts = config_opts(opts)

      case apply? do
        true -> apply_migration(repo, name, config_opts)
        false -> preview_migration(repo, name, config_opts)
      end
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

  defp run_dry_run_output(name, config_path, setup_path, setup, runtime_manifest) do
    [
      "Resolved saved run setup #{name}",
      "local config: #{config_path}",
      "run setup: #{setup_path}",
      "repo manifest: #{get_in(runtime_manifest, ["repo", "manifest"]) || get_in(setup, ["repo", "manifest"]) || get_in(setup, ["repo", "path"])}",
      "capacity: #{RunSetup.capacity_label(setup)}",
      "mode: #{Map.get(setup, "mode", "unattended")}",
      "dry run: daemon not started"
    ]
    |> Enum.join("\n")
  end

  defp format_command_error({:invalid_run_setup_name, name}), do: "Invalid run setup name: #{inspect(name)}"
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
  defp format_command_error(reason), do: inspect(reason)

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
