defmodule SymphonyElixir.ControlPlaneCLI do
  @moduledoc false

  alias SymphonyElixir.{ControlPlane, LocalConfig}
  alias SymphonyElixir.ControlPlane.Error
  alias SymphonyElixir.ReviewRecords.Redaction

  @usage """
  Usage:
    symphony control-plane inspect [--config-root <path>] [--json]
    symphony control-plane resume <run-id> [--owner <id>] [--confirm <token>] [--config-root <path>] [--json]
    symphony control-plane abandon <run-id> [--owner <id>] [--confirm <token>] [--config-root <path>] [--json]
    symphony control-plane prune [--confirm <token>] [--config-root <path>] [--json]
  """

  @switches [config_root: :string, owner: :string, confirm: :string, json: :boolean]

  @spec evaluate([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def evaluate(args) when is_list(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, ["inspect"], []} -> inspect_runs(opts)
      {opts, ["resume", admitted_run_id], []} -> run_action(:resume, admitted_run_id, opts)
      {opts, ["abandon", admitted_run_id], []} -> run_action(:abandon, admitted_run_id, opts)
      {opts, ["prune"], []} -> prune(opts)
      _invalid -> {:error, usage()}
    end
  end

  def evaluate(_args), do: {:error, usage()}

  defp inspect_runs(opts) do
    with_control_plane(opts, fn server ->
      with {:ok, runs} <- ControlPlane.inspect_runs(server) do
        render(%{runs: runs}, Keyword.get(opts, :json, false))
      end
    end)
  end

  defp run_action(action, admitted_run_id, opts) do
    with_control_plane(opts, fn server ->
      run_action_with_server(server, action, admitted_run_id, opts)
    end)
  end

  defp run_action_with_server(server, action, admitted_run_id, opts) do
    case Keyword.get(opts, :confirm) do
      nil -> preview_run_action(server, action, admitted_run_id, opts)
      confirmation -> confirm_run_action(server, action, admitted_run_id, confirmation, opts)
    end
  end

  defp preview_run_action(server, action, admitted_run_id, opts) do
    with {:ok, preview} <-
           ControlPlane.preview_run_action(server, action, admitted_run_id) do
      render(preview, Keyword.get(opts, :json, false))
    end
  end

  defp confirm_run_action(server, action, admitted_run_id, confirmation, opts) do
    with {:ok, owner_id} <- required_owner(opts),
         {:ok, result} <-
           ControlPlane.confirm_run_action(
             server,
             action,
             admitted_run_id,
             owner_id,
             confirmation
           ) do
      result
      |> operator_result()
      |> render(Keyword.get(opts, :json, false))
    end
  end

  defp prune(opts) do
    with {:ok, config} <- LocalConfig.load(config_opts(opts)),
         {:ok, retention_days} <- LocalConfig.terminal_retention_days(config) do
      prune_with_retention(opts, retention_days)
    else
      error -> format_error(error)
    end
  end

  defp prune_with_retention(opts, retention_days) do
    with_control_plane(opts, fn server ->
      prune_with_server(server, retention_days, opts)
    end)
  end

  defp prune_with_server(server, retention_days, opts) do
    case Keyword.get(opts, :confirm) do
      nil -> preview_prune(server, retention_days, opts)
      confirmation -> confirm_prune(server, retention_days, confirmation, opts)
    end
  end

  defp preview_prune(server, retention_days, opts) do
    with {:ok, preview} <- ControlPlane.preview_prune(server, retention_days) do
      render(preview, Keyword.get(opts, :json, false))
    end
  end

  defp confirm_prune(server, retention_days, confirmation, opts) do
    with {:ok, result} <- ControlPlane.prune(server, retention_days, confirmation) do
      render(result, Keyword.get(opts, :json, false))
    end
  end

  defp with_control_plane(opts, operation) do
    name = {:global, {__MODULE__, make_ref()}}

    case ControlPlane.start_link(Keyword.merge(config_opts(opts), name: name)) do
      {:ok, server} ->
        try do
          case operation.(server) do
            {:ok, _output} = result -> result
            error -> format_error(error)
          end
        after
          if Process.alive?(server), do: GenServer.stop(server)
        end

      error ->
        format_error(error)
    end
  end

  defp required_owner(opts) do
    case Keyword.get(opts, :owner) do
      owner_id when is_binary(owner_id) and owner_id != "" -> {:ok, owner_id}
      _missing -> {:error, :owner_required}
    end
  end

  defp config_opts(opts) do
    case Keyword.get(opts, :config_root) do
      nil -> []
      config_root -> [config_root: config_root]
    end
  end

  defp render(payload, true), do: {:ok, Jason.encode!(payload)}
  defp render(%{runs: []}, false), do: {:ok, "No durable runs."}

  defp render(%{runs: runs}, false) do
    rows = Enum.map_join(runs, "\n", &format_run/1)
    {:ok, rows}
  end

  defp render(payload, false), do: {:ok, Jason.encode!(payload, pretty: true)}

  defp operator_result(%{lease: lease, run: run}) do
    %{
      run: run,
      lease: %{
        owner_id: run.owner_id,
        fencing_generation: lease.fencing_token,
        lease_expires_at_ms: lease.deadline_ms
      }
    }
  end

  defp format_run(run) do
    [
      "run=#{run.admitted_run_id}",
      "target=#{run.target_id}",
      "issue=#{run.issue_identifier}",
      "issue_id=#{run.tracker_issue_id}",
      "state=#{run.lifecycle_state}",
      "owner=#{run.owner_id || "none"}",
      "lease_expires_at_ms=#{run.lease_expires_at_ms || "none"}",
      "fencing_generation=#{run.fencing_generation}",
      "retry_due_at_ms=#{run.retry_due_at_ms || "none"}",
      "blocked_reason=#{run.blocked_reason || "none"}",
      "reconciliation_status=#{run.reconciliation_status}"
    ]
    |> Enum.join(" ")
  end

  defp format_error({:error, %Error{message: message}}),
    do: {:error, Redaction.redact_string(message)}

  defp format_error({:error, {:invalid_terminal_retention_days, value}}) do
    {:error, "Invalid control_plane.terminal_retention_days: expected a positive integer, got #{value_type(value)}"}
  end

  defp format_error({:error, :owner_required}) do
    {:error, "--owner is required when confirming resume or abandon"}
  end

  defp format_error({:error, reason}) when is_atom(reason),
    do: {:error, Atom.to_string(reason)}

  defp format_error({:error, _reason}), do: {:error, "control_plane_error"}
  defp format_error(_other), do: {:error, "control_plane_error"}

  defp value_type(nil), do: "null"
  defp value_type(value) when is_integer(value), do: "integer"
  defp value_type(value) when is_binary(value), do: "string"
  defp value_type(value) when is_map(value), do: "map"
  defp value_type(value) when is_list(value), do: "list"
  defp value_type(_value), do: "other value"

  defp usage, do: String.trim(@usage)
end
