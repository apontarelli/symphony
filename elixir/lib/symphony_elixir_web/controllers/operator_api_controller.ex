defmodule SymphonyElixirWeb.OperatorApiController do
  @moduledoc """
  Versioned read-only HTTP interface for local operator clients.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.OperatorInterface
  alias SymphonyElixirWeb.Endpoint

  @default_event_limit 200

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
