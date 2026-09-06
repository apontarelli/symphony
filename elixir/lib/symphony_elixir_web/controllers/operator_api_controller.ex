defmodule SymphonyElixirWeb.OperatorApiController do
  @moduledoc """
  Versioned local operator snapshots, events, and authenticated commands.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.OperatorInterface
  alias SymphonyElixirWeb.Endpoint

  @default_event_limit 200

  plug(:require_local_session when action in [:preview, :confirm, :settings, :repositories])

  @spec preview(Conn.t(), map()) :: Conn.t()
  def preview(conn, _params) do
    OperatorInterface.preview(
      operator_interface(),
      conn.assigns.operator_credential,
      conn.body_params,
      host_scheduler: host_scheduler(),
      control_plane: control_plane()
    )
    |> command_response(conn, 200)
  end

  @spec confirm(Conn.t(), map()) :: Conn.t()
  def confirm(conn, _params) do
    OperatorInterface.confirm(operator_interface(), conn.assigns.operator_credential, conn.body_params)
    |> command_response(conn, 202)
  end

  @spec settings(Conn.t(), map()) :: Conn.t()
  def settings(conn, _params) do
    OperatorInterface.settings(
      operator_interface(),
      conn.assigns.operator_credential,
      conn.body_params,
      host_scheduler()
    )
    |> command_response(conn, 200)
  end

  @spec repositories(Conn.t(), map()) :: Conn.t()
  def repositories(conn, params) do
    status = if Map.get(params, "action") in ~w(recent browse scan manual), do: 202, else: 200

    OperatorInterface.repositories(
      operator_interface(),
      conn.assigns.operator_credential,
      conn.body_params,
      host_scheduler()
    )
    |> command_response(conn, status)
  end

  defp require_local_session(conn, _opts) do
    conn = Conn.put_resp_header(conn, "cache-control", "no-store")

    credential = conn |> Conn.get_req_header("authorization") |> bearer_credential()

    cond do
      not loopback?(conn.remote_ip) ->
        OperatorInterface.reject(operator_interface(), :loopback_required)
        |> command_response(conn, 403)
        |> halt()

      is_nil(credential) ->
        OperatorInterface.reject(operator_interface(), :unauthorized)
        |> command_response(conn, 401)
        |> halt()

      true ->
        conn
        |> Conn.assign(:operator_credential, credential)
    end
  end

  defp bearer_credential([header]) do
    case String.split(header, " ", trim: true) do
      [scheme, token] when byte_size(token) > 0 and byte_size(token) <= 256 ->
        if String.downcase(scheme) == "bearer", do: token

      _other ->
        nil
    end
  end

  defp bearer_credential(_headers), do: nil

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65_535, high, _}), do: high in 0x7F00..0x7FFF
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_address), do: false

  defp command_response({:ok, payload}, conn, status), do: conn |> put_status(status) |> json(payload)

  defp command_response({:error, payload}, conn, _status) do
    status =
      case payload.error.code do
        "unauthorized" ->
          401

        "loopback_required" ->
          403

        "scan_not_found" ->
          404

        code
        when code in [
               "operator_interface_unavailable",
               "host_unavailable",
               "preview_failed",
               "mutation_failed",
               "authority_unavailable",
               "control_plane_unavailable",
               "scheduler_unavailable",
               "unavailable"
             ] ->
          503

        code
        when code in [
               "invalid_repository_request",
               "invalid_command_request",
               "invalid_command",
               "invalid_action",
               "invalid_inputs",
               "invalid_target_id",
               "invalid_run_id",
               "incompatible_interface"
             ] ->
          400

        _code ->
          409
      end

    conn |> put_status(status) |> json(payload)
  end

  @spec snapshot(Conn.t(), map()) :: Conn.t()
  def snapshot(conn, _params) do
    case OperatorInterface.snapshot(
           operator_interface(),
           host_scheduler(),
           control_plane(),
           snapshot_timeout_ms()
         ) do
      {:ok, payload} -> json(conn, payload)
      {:error, :unavailable} -> unavailable(conn)
    end
  end

  @spec events(Conn.t(), map()) :: Conn.t()
  def events(conn, params) do
    with {:ok, host_id} <- required_string(params, "host_id"),
         {:ok, after_cursor} <- non_negative_integer(params, "after"),
         {:ok, limit} <- positive_integer(params, "limit", @default_event_limit),
         {:ok, payload} <-
           OperatorInterface.events(operator_interface(), host_id, after_cursor, limit) do
      json(conn, payload)
    else
      {:error, :invalid_cursor} ->
        error_response(conn, 400, "invalid_event_cursor", "host_id and after must identify a snapshot cursor")

      {:error, :invalid_limit} ->
        error_response(conn, 400, "invalid_event_limit", "limit must be an integer from 1 through 500")

      {:error, :unavailable} ->
        unavailable(conn)
    end
  end

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :invalid_cursor}
    end
  end

  defp non_negative_integer(params, key) do
    case Map.get(params, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value when is_binary(value) -> parse_integer(value, 0, :invalid_cursor)
      _missing_or_invalid -> {:error, :invalid_cursor}
    end
  end

  defp positive_integer(params, key, default) do
    case Map.get(params, key) do
      nil -> {:ok, default}
      value when is_integer(value) and value > 0 and value <= 500 -> {:ok, value}
      value when is_binary(value) -> parse_integer(value, 1, :invalid_limit, 500)
      _invalid -> {:error, :invalid_limit}
    end
  end

  defp parse_integer(value, minimum, error, maximum \\ nil) do
    case Integer.parse(value) do
      {integer, ""}
      when integer >= minimum and (is_nil(maximum) or integer <= maximum) ->
        {:ok, integer}

      _invalid ->
        {:error, error}
    end
  end

  defp unavailable(conn) do
    error_response(conn, 503, "operator_interface_unavailable", "Operator interface is unavailable")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp operator_interface do
    Endpoint.config(:operator_interface) || SymphonyElixir.OperatorInterface
  end

  defp host_scheduler do
    Endpoint.config(:host_scheduler) || SymphonyElixir.HostScheduler
  end

  defp control_plane do
    Endpoint.config(:control_plane) || SymphonyElixir.ControlPlane
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
