defmodule SymphonyElixir.AgentRuntime.OmpMcpBridge do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias SymphonyElixir.Codex.DynamicTool

  @mcp_protocol_version "2025-03-26"
  @max_body_bytes 1_048_576

  @enforce_keys [:server, :state, :token, :url]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          server: pid(),
          state: pid(),
          token: String.t(),
          url: String.t()
        }

  @spec start() :: {:ok, t()} | {:error, term()}
  def start do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    case Agent.start_link(fn -> nil end) do
      {:ok, state} -> start_server_for_state(state, token)
      {:error, _reason} = error -> error
    end
  end

  defp start_server_for_state(state, token) do
    case start_server(state, token) do
      {:ok, server} -> finish_start(state, server, token)
      {:error, reason} -> stop_failed_state(state, reason)
    end
  end

  defp finish_start(state, server, token) do
    case ThousandIsland.listener_info(server) do
      {:ok, {_address, port}} ->
        {:ok,
         %__MODULE__{
           server: server,
           state: state,
           token: token,
           url: "http://127.0.0.1:#{port}/"
         }}

      :error ->
        stop_process(server, &Supervisor.stop(&1, :normal, 5_000))
        stop_failed_state(state, :mcp_bridge_listener_unavailable)
    end
  end

  defp stop_failed_state(state, reason) do
    stop_process(state, &Agent.stop(&1, :normal, 5_000))
    {:error, reason}
  end

  @spec mcp_server(t()) :: map()
  def mcp_server(%__MODULE__{} = bridge) do
    %{
      "type" => "http",
      "name" => "symphony",
      "url" => bridge.url,
      "headers" => [
        %{"name" => "Authorization", "value" => "Bearer " <> bridge.token}
      ]
    }
  end

  @spec set_tool_executor(t(), (String.t(), term() -> map()) | nil) :: :ok
  def set_tool_executor(%__MODULE__{state: state}, executor)
      when is_nil(executor) or is_function(executor, 2) do
    Agent.update(state, fn _current -> executor end)
  end

  @spec stop(t()) :: :ok | {:error, term()}
  def stop(%__MODULE__{} = bridge) do
    server_result = stop_process(bridge.server, &Supervisor.stop(&1, :normal, 5_000))
    state_result = stop_process(bridge.state, &Agent.stop(&1, :normal, 5_000))

    case {server_result, state_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, :ok} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, reason}
      {{:error, first}, {:error, second}} -> {:error, {first, second}}
    end
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, {state, token}) do
    cond do
      conn.method != "POST" ->
        send_resp(conn, 405, "method not allowed")

      not authorized?(conn, token) ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> send_resp(401, "unauthorized")

      true ->
        handle_request(conn, state)
    end
  end

  defp start_server(state, token) do
    Bandit.start_link(
      plug: {__MODULE__, {state, token}},
      ip: {127, 0, 0, 1},
      port: 0,
      startup_log: false
    )
  end

  defp authorized?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> candidate] when byte_size(candidate) == byte_size(token) ->
        Plug.Crypto.secure_compare(candidate, token)

      _other ->
        false
    end
  end

  defp handle_request(conn, state) do
    with {:ok, body, conn} <- read_request_body(conn, "", 0),
         {:ok, request} when is_map(request) <- Jason.decode(body) do
      respond(conn, dispatch(request, state))
    else
      {:error, :body_too_large, conn} -> send_resp(conn, 413, "request too large")
      _invalid -> json_response(conn, 400, rpc_error(nil, -32_700, "Parse error"))
    end
  end

  defp read_request_body(conn, body, size) do
    case read_body(conn, length: @max_body_bytes, read_length: 64_000) do
      {:ok, chunk, conn} -> append_body(conn, body, size, chunk, true)
      {:more, chunk, conn} -> append_body(conn, body, size, chunk, false)
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp append_body(conn, body, size, chunk, complete?) do
    next_size = size + byte_size(chunk)

    cond do
      next_size > @max_body_bytes -> {:error, :body_too_large, conn}
      complete? -> {:ok, body <> chunk, conn}
      true -> read_request_body(conn, body <> chunk, next_size)
    end
  end

  defp dispatch(%{"jsonrpc" => "2.0", "method" => method} = request, state) do
    id = Map.get(request, "id")
    params = Map.get(request, "params", %{})
    result = dispatch_method(method, state, params)

    case {id, result} do
      {nil, _result} -> :notification
      {id, {:ok, value}} -> {:json, rpc_result(id, value)}
      {id, {:error, code, message}} -> {:json, rpc_error(id, code, message)}
    end
  end

  defp dispatch(request, _state),
    do: {:json, rpc_error(Map.get(request, "id"), -32_600, "Invalid Request")}

  defp dispatch_method("initialize", _state, _params) do
    {:ok,
     %{
       "protocolVersion" => @mcp_protocol_version,
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{"name" => "symphony-linear", "version" => "1"}
     }}
  end

  defp dispatch_method("ping", _state, _params), do: {:ok, %{}}
  defp dispatch_method("tools/list", _state, _params), do: {:ok, %{"tools" => DynamicTool.tool_specs()}}
  defp dispatch_method("tools/call", state, params), do: call_tool(state, params)
  defp dispatch_method("notifications/initialized", _state, _params), do: :notification
  defp dispatch_method("notifications/cancelled", _state, _params), do: :notification
  defp dispatch_method(_unknown, _state, _params), do: {:error, -32_601, "Method not found"}

  defp call_tool(state, %{"name" => "linear_graphql"} = params) do
    arguments = Map.get(params, "arguments", %{})

    case Agent.get(state, & &1) do
      executor when is_function(executor, 2) ->
        executor
        |> invoke_tool(arguments)
        |> tool_result()

      _missing ->
        {:ok, mcp_tool_result(false, "The Symphony tool executor is unavailable outside an active turn.")}
    end
  end

  defp call_tool(_state, %{"name" => name}) when is_binary(name) do
    {:ok, mcp_tool_result(false, "Unsupported tool: #{name}")}
  end

  defp call_tool(_state, _params),
    do: {:error, -32_602, "Invalid tools/call params"}

  defp invoke_tool(executor, arguments) do
    executor.("linear_graphql", arguments)
  rescue
    error -> %{"success" => false, "output" => Exception.message(error)}
  catch
    kind, reason -> %{"success" => false, "output" => inspect({kind, reason})}
  end

  defp tool_result(%{} = result) do
    success = Map.get(result, "success", Map.get(result, :success, false)) == true
    text = tool_output(result)
    {:ok, mcp_tool_result(success, text)}
  end

  defp tool_result(other),
    do: {:ok, mcp_tool_result(false, "Invalid Symphony tool result: #{inspect(other)}")}

  defp tool_output(result) do
    Map.get(result, "output") ||
      Map.get(result, :output) ||
      result
      |> Map.get("contentItems", Map.get(result, :contentItems, []))
      |> Enum.find_value(fn item -> Map.get(item, "text", Map.get(item, :text)) end) ||
      Jason.encode!(result)
  end

  defp mcp_tool_result(success, text) do
    %{
      "content" => [%{"type" => "text", "text" => to_string(text)}],
      "isError" => not success
    }
  end

  defp respond(conn, :notification), do: send_resp(conn, 202, "")
  defp respond(conn, {:json, payload}), do: json_response(conn, 200, payload)

  defp json_response(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp rpc_result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp rpc_error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp stop_process(pid, stop) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        stop.(pid)
        :ok
      catch
        :exit, reason -> {:error, reason}
      end
    else
      :ok
    end
  end
end
