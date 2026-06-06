defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an optional manifest path.
  """

  alias SymphonyElixir.Config.ProfileBindings
  alias SymphonyElixir.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @default_linear_bindings_file "linear-profile-bindings.local.yml"
  @switches [
    {@acknowledgement_switch, :boolean},
    linear_bindings: :string,
    logs_root: :string,
    port: :integer,
    profile: :string
  ]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          set_linear_profile_bindings: (map() -> :ok | {:error, term()}),
          set_linear_profile_bindings_source_path: (String.t(), boolean() -> :ok | {:error, term()}),
          set_profile_override: (String.t() | nil -> :ok | {:error, term()}),
          load_linear_profile_bindings: (String.t() -> {:ok, map()} | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

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

  defp run(workflow_path, opts, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      with :ok <- maybe_load_linear_profile_bindings(opts, expanded_path, deps) do
        start_runtime(expanded_path, deps)
      end
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
    "Usage: symphony [--logs-root <path>] [--port <port>] [--linear-bindings <path>] [--profile <name>] [path-to-symphony.yml]\n\nIf --linear-bindings is omitted, Symphony loads linear-profile-bindings.local.yml next to the selected manifest when present."
  end

  defp default_workflow_path(_deps), do: Path.expand("symphony.yml")

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      set_linear_profile_bindings: &ProfileBindings.set/1,
      set_linear_profile_bindings_source_path: &ProfileBindings.set_source_path/2,
      set_profile_override: &ProfileBindings.set_profile_override/1,
      load_linear_profile_bindings: &ProfileBindings.load_file/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
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

  defp maybe_load_linear_profile_bindings(opts, workflow_path, deps) do
    case Keyword.get_values(opts, :linear_bindings) do
      [] ->
        default_path =
          workflow_path
          |> Path.dirname()
          |> Path.join(@default_linear_bindings_file)
          |> Path.expand()

        :ok = deps.set_linear_profile_bindings_source_path.(default_path, false)

        if deps.file_regular?.(default_path) do
          load_linear_profile_bindings(default_path, deps)
        else
          :ok
        end

      values ->
        path = values |> List.last() |> String.trim()
        expanded_path = Path.expand(path)
        :ok = deps.set_linear_profile_bindings_source_path.(expanded_path, true)
        load_linear_profile_bindings(expanded_path, deps)
    end
  end

  defp load_linear_profile_bindings("", _deps), do: {:error, usage_message()}

  defp load_linear_profile_bindings(path, deps) do
    expanded_path = Path.expand(path)

    case deps.load_linear_profile_bindings.(expanded_path) do
      {:ok, bindings} ->
        :ok = deps.set_linear_profile_bindings.(bindings)

      {:error, reason} ->
        {:error, "Failed to load Linear profile bindings #{expanded_path}: #{inspect(reason)}"}
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
