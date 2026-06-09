defmodule Mix.Tasks.Incident.LinearIssue do
  use Mix.Task

  alias SymphonyElixir.{Config, IncidentLinearIssue, Workflow}

  @shortdoc "Dry-run or create a Linear issue from a production failure signal payload"

  @moduledoc """
  Builds a bounded Linear issue payload from a production failure signal.
  The payload must include a generic failure summary plus source-specific evidence in
  `source_payload`; see `docs/incident_linear_issue.md` for the exact per-source fields.

  Dry-run is the default and does not require Linear credentials:

      mix incident.linear_issue --payload /path/to/signal.json

  Create mode requires explicit project opt-in:

      mix incident.linear_issue --payload /path/to/signal.json --create --acknowledge-project-opt-in

  Supported signal sources:

      github_actions, sentry, posthog, project_webhook
  """

  @switches [
    payload: :string,
    workflow: :string,
    state: :string,
    labels: :string,
    create: :boolean,
    acknowledge_project_opt_in: :boolean,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      opts[:create] ->
        create_issue(opts)

      true ->
        dry_run(opts)
    end
  end

  defp dry_run(opts) do
    opts
    |> payload_from_opts()
    |> IncidentLinearIssue.plan(plan_opts(opts))
    |> case do
      {:ok, plan} -> Mix.shell().info(IncidentLinearIssue.format_dry_run(plan))
      {:error, reason} -> Mix.raise("Unable to build incident issue payload: #{inspect(reason)}")
    end
  end

  defp create_issue(opts) do
    unless opts[:acknowledge_project_opt_in] do
      Mix.raise("Create mode requires --acknowledge-project-opt-in")
    end

    workflow_path = Keyword.get(opts, :workflow, "symphony.yml") |> Path.expand()
    :ok = Workflow.set_workflow_file_path(workflow_path)

    case Config.validate!() do
      :ok ->
        do_create_issue(opts)

      {:error, reason} ->
        Mix.raise("Invalid workflow configuration for Linear create mode: #{inspect(reason)}")
    end
  end

  defp do_create_issue(opts) do
    create_opts =
      opts
      |> plan_opts()
      |> Keyword.put(:project_opt_in, true)

    opts
    |> payload_from_opts()
    |> IncidentLinearIssue.create(create_opts)
    |> case do
      {:ok, issue} ->
        Mix.shell().info("Created Linear issue: #{issue["identifier"]} #{issue["url"]}")

      {:duplicate, duplicate} ->
        Mix.shell().info("Duplicate suppressed: #{duplicate.identifier} #{duplicate.url}")

      {:error, reason} ->
        Mix.raise("Unable to create incident issue: #{inspect(reason)}")
    end
  end

  defp payload_from_opts(opts) do
    case Keyword.get(opts, :payload) do
      nil ->
        Mix.raise("Missing required option --payload")

      path ->
        path
        |> read_payload_file()
        |> decode_payload()
    end
  end

  defp read_payload_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, reason} -> Mix.raise("Unable to read payload #{path}: #{inspect(reason)}")
    end
  end

  defp decode_payload(content) do
    case Jason.decode(content) do
      {:ok, payload} when is_map(payload) -> payload
      {:ok, _other} -> Mix.raise("Payload JSON must be an object")
      {:error, reason} -> Mix.raise("Invalid payload JSON: #{inspect(reason)}")
    end
  end

  defp plan_opts(opts) do
    []
    |> maybe_put(:target_state, Keyword.get(opts, :state))
    |> maybe_put(:labels, labels(opts))
  end

  defp labels(opts) do
    case Keyword.get(opts, :labels) do
      nil ->
        nil

      labels ->
        labels
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
