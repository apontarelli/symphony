defmodule SymphonyElixir.HttpServer do
  @moduledoc """
  Compatibility facade that starts the Phoenix observability endpoint when enabled.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixirWeb.Endpoint

  @secret_key_bytes 48

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    case Keyword.get(opts, :port, Config.server_port()) do
      port when is_integer(port) and port >= 0 ->
        host = Keyword.get(opts, :host, Config.settings!().server.host)
        orchestrator = Keyword.get(opts, :orchestrator)
        host_scheduler = Keyword.get(opts, :host_scheduler, SymphonyElixir.HostScheduler)
        control_plane = Keyword.get(opts, :control_plane, SymphonyElixir.ControlPlane)

        operator_interface =
          Keyword.get(opts, :operator_interface, SymphonyElixir.OperatorInterface)

        snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)

        with {:ok, ip} <- parse_host(host) do
          endpoint_opts =
            [
              server: true,
              http: [ip: ip, port: port],
              url: [host: normalize_host(host)],
              host_scheduler: host_scheduler,
              control_plane: control_plane,
              operator_interface: operator_interface,
              snapshot_timeout_ms: snapshot_timeout_ms,
              secret_key_base: secret_key_base()
            ]

          endpoint_config =
            :symphony_elixir
            |> Application.get_env(Endpoint, [])
            |> Keyword.merge(endpoint_opts)
            |> maybe_put_orchestrator(orchestrator)

          Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
          Endpoint.start_link()
        end

      _ ->
        :ignore
    end
  end

  defp maybe_put_orchestrator(endpoint_opts, nil),
    do: Keyword.delete(endpoint_opts, :orchestrator)

  defp maybe_put_orchestrator(endpoint_opts, orchestrator),
    do: Keyword.put(endpoint_opts, :orchestrator, orchestrator)

  @spec bound_port(term()) :: non_neg_integer() | nil
  def bound_port(_server \\ __MODULE__) do
    case Bandit.PhoenixAdapter.server_info(Endpoint, :http) do
      {:ok, {_ip, port}} when is_integer(port) -> port
      _ -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp parse_host({_, _, _, _} = ip), do: {:ok, ip}
  defp parse_host({_, _, _, _, _, _, _, _} = ip), do: {:ok, ip}

  defp parse_host(host) when is_binary(host) do
    charhost = String.to_charlist(host)

    case :inet.parse_address(charhost) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _reason} ->
        case :inet.getaddr(charhost, :inet) do
          {:ok, ip} -> {:ok, ip}
          {:error, _reason} -> :inet.getaddr(charhost, :inet6)
        end
    end
  end

  defp normalize_host(host) when host in ["", nil], do: "127.0.0.1"
  defp normalize_host(host) when is_binary(host), do: host
  defp normalize_host(host), do: to_string(host)

  defp secret_key_base do
    Base.encode64(:crypto.strong_rand_bytes(@secret_key_bytes), padding: false)
  end
end
