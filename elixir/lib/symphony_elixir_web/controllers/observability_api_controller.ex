defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{ControlPlane, LocalConfig}
  alias SymphonyElixir.ControlPlane.Lease
  alias SymphonyElixir.ReviewRecords.Redaction
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  plug(:require_loopback_operator when action in [:resume, :abandon, :prune])

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec control_plane(Conn.t(), map()) :: Conn.t()
  def control_plane(conn, _params) do
    case Presenter.control_plane_payload(control_plane_server()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, reason} ->
        control_plane_error(conn, reason)
    end
  end

  @spec resume(Conn.t(), map()) :: Conn.t()
  def resume(conn, %{"run_id" => admitted_run_id} = params) do
    run_action(conn, :resume, admitted_run_id, params)
  end

  @spec abandon(Conn.t(), map()) :: Conn.t()
  def abandon(conn, %{"run_id" => admitted_run_id} = params) do
    run_action(conn, :abandon, admitted_run_id, params)
  end

  @spec prune(Conn.t(), map()) :: Conn.t()
  def prune(conn, params) do
    case terminal_retention_days() do
      {:ok, retention_days} -> prune_with_retention(conn, params, retention_days)
      {:error, reason} -> control_plane_error(conn, reason)
    end
  end

  defp prune_with_retention(conn, params, retention_days) do
    case Map.get(params, "confirmation") do
      nil -> preview_prune(conn, retention_days)
      confirmation -> confirm_prune(conn, retention_days, confirmation)
    end
  end

  defp preview_prune(conn, retention_days) do
    result =
      control_plane_call(fn ->
        ControlPlane.preview_prune(control_plane_server(), retention_days)
      end)

    case result do
      {:ok, preview} -> json(conn, preview)
      {:error, reason} -> control_plane_error(conn, reason)
    end
  end

  defp confirm_prune(conn, retention_days, confirmation) do
    result =
      control_plane_call(fn ->
        ControlPlane.prune(control_plane_server(), retention_days, confirmation)
      end)

    case result do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, reason} ->
        control_plane_error(conn, reason)
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp run_action(conn, action, admitted_run_id, params) do
    case Map.get(params, "confirmation") do
      nil -> preview_run_action(conn, action, admitted_run_id)
      confirmation -> confirm_run_action(conn, action, admitted_run_id, confirmation, params)
    end
  end

  defp preview_run_action(conn, action, admitted_run_id) do
    result =
      control_plane_call(fn ->
        ControlPlane.preview_run_action(
          control_plane_server(),
          action,
          admitted_run_id
        )
      end)

    case result do
      {:ok, preview} -> json(conn, preview)
      {:error, reason} -> control_plane_error(conn, reason)
    end
  end

  defp confirm_run_action(conn, action, admitted_run_id, confirmation, params) do
    owner_id = Map.get(params, "owner_id")

    result =
      control_plane_call(fn ->
        ControlPlane.confirm_run_action(
          control_plane_server(),
          action,
          admitted_run_id,
          owner_id,
          confirmation
        )
      end)

    run_action_response(conn, result)
  end

  defp run_action_response(conn, {:ok, %{lease: %Lease{} = lease, run: run}}) do
    payload = %{
      run: run,
      lease: %{
        owner_id: run.owner_id,
        fencing_generation: lease.fencing_token,
        lease_expires_at_ms: lease.deadline_ms
      }
    }

    conn
    |> put_status(202)
    |> json(payload)
  end

  defp run_action_response(conn, {:error, reason}),
    do: control_plane_error(conn, reason)

  defp control_plane_call(operation) do
    operation.()
  rescue
    _exception -> {:error, :control_plane_unavailable}
  catch
    :exit, _reason -> {:error, :control_plane_unavailable}
  end

  defp control_plane_error(conn, %ControlPlane.Error{message: message}) do
    error_response(
      conn,
      503,
      "control_plane_unavailable",
      Redaction.redact_string(message)
    )
  end

  defp control_plane_error(conn, {:invalid_terminal_retention_days, value}) do
    error_response(
      conn,
      503,
      "invalid_terminal_retention_days",
      "Invalid control_plane.terminal_retention_days: expected a positive integer, got #{value_type(value)}"
    )
  end

  defp control_plane_error(conn, :admission_not_found),
    do: error_response(conn, 404, "run_not_found", "Durable run not found")

  defp control_plane_error(conn, :control_plane_unavailable),
    do:
      error_response(
        conn,
        503,
        "control_plane_unavailable",
        "Control plane is unavailable"
      )

  defp control_plane_error(conn, reason)
       when reason in [
              :invalid_confirmation,
              :invalid_operator_action,
              :invalid_retention,
              :invalid_lease
            ],
       do: error_response(conn, 400, Atom.to_string(reason), "Invalid control-plane request")

  defp control_plane_error(conn, reason)
       when reason in [
              :lease_active,
              :lease_held,
              :operator_action_not_allowed,
              :process_termination_unverified,
              :reconciliation_required,
              :stale_lease
            ],
       do: error_response(conn, 409, Atom.to_string(reason), "Control-plane state changed")

  defp control_plane_error(conn, reason),
    do: error_response(conn, 503, "control_plane_failed", Redaction.redact_string(inspect(reason)))

  defp terminal_retention_days do
    case Endpoint.config(:control_plane_retention_days) do
      days when is_integer(days) -> LocalConfig.terminal_retention_days(%{"control_plane" => %{"terminal_retention_days" => days}})
      nil -> load_terminal_retention_days()
      invalid -> {:error, {:invalid_terminal_retention_days, invalid}}
    end
  end

  defp load_terminal_retention_days do
    opts =
      case Endpoint.config(:control_plane_config_root) do
        nil -> []
        config_root -> [config_root: config_root]
      end

    with {:ok, config} <- LocalConfig.load(opts) do
      LocalConfig.terminal_retention_days(config)
    end
  end

  defp control_plane_server do
    Endpoint.config(:control_plane) || SymphonyElixir.ControlPlane
  end

  defp require_loopback_operator(%Conn{remote_ip: remote_ip} = conn, _opts) do
    if loopback?(remote_ip) do
      conn
    else
      conn
      |> error_response(
        403,
        "operator_api_local_only",
        "Control-plane mutations require a loopback connection"
      )
      |> halt()
    end
  end

  defp loopback?({127, _second, _third, _fourth}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp loopback?({0, 0, 0, 0, 0, 65_535, ipv4_high, _ipv4_low}),
    do: ipv4_high in 0x7F00..0x7FFF

  defp loopback?(_remote_ip), do: false

  defp value_type(nil), do: "null"
  defp value_type(value) when is_integer(value), do: "integer"
  defp value_type(value) when is_binary(value), do: "string"
  defp value_type(value) when is_map(value), do: "map"
  defp value_type(value) when is_list(value), do: "list"
  defp value_type(_value), do: "other value"

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
