defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.ControlPlane
  alias SymphonyElixir.ReviewRecords.Redaction
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, state_payload())
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

  @spec mutation_contract_required(Conn.t(), map()) :: Conn.t()
  def mutation_contract_required(conn, _params) do
    error_response(
      conn,
      410,
      "operator_confirmation_required",
      "Use the authenticated /api/v1/operator/commands/preview and /api/v1/operator/commands/confirm endpoints."
    )
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier} = params) do
    case issue_payload(issue_identifier, Map.get(params, "target_id")) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :ambiguous_issue} ->
        error_response(
          conn,
          409,
          "ambiguous_issue",
          "Multiple targets use this issue identifier; provide target_id"
        )

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
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

  defp control_plane_error(conn, %ControlPlane.Error{message: message}) do
    error_response(
      conn,
      503,
      "control_plane_unavailable",
      Redaction.redact_string(message)
    )
  end

  defp control_plane_error(conn, _reason) do
    error_response(conn, 503, "control_plane_unavailable", "Control plane is unavailable")
  end

  defp control_plane_server do
    Endpoint.config(:control_plane) || SymphonyElixir.ControlPlane
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp state_payload do
    case Endpoint.config(:orchestrator) do
      nil ->
        Presenter.host_state_payload(
          host_scheduler(),
          control_plane_server(),
          snapshot_timeout_ms()
        )

      configured_orchestrator ->
        Presenter.state_payload(configured_orchestrator, snapshot_timeout_ms())
    end
  end

  defp issue_payload(issue_identifier, target_id) do
    case Endpoint.config(:orchestrator) do
      nil ->
        Presenter.host_issue_payload(
          issue_identifier,
          target_id,
          host_scheduler(),
          control_plane_server(),
          snapshot_timeout_ms()
        )

      configured_orchestrator ->
        Presenter.issue_payload(
          issue_identifier,
          configured_orchestrator,
          snapshot_timeout_ms()
        )
    end
  end

  defp host_scheduler do
    Endpoint.config(:host_scheduler) || SymphonyElixir.HostScheduler
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
