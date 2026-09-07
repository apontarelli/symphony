defmodule SymphonyElixir.HostTerminal do
  @moduledoc """
  Local terminal attachment. Configuration and process ownership stay in Elixir
  host authority; closing this client never stops the host.
  """

  alias SymphonyElixir.{HostBootstrap, LocalHost}

  @spec evaluate([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def evaluate(["bootstrap", "preview"]), do: encode(HostBootstrap.preview())
  def evaluate(["bootstrap", "confirm", "--confirmation", token]), do: encode(HostBootstrap.confirm(token))
  def evaluate(["discover"]), do: encode(LocalHost.discover())
  def evaluate(["attach"]), do: encode(LocalHost.attach())

  def evaluate(_args) do
    encode(error("invalid_arguments", "Use host bootstrap preview, host bootstrap confirm --confirmation TOKEN, host discover, or host attach."))
  end

  @doc """
  Decides whether interactive terminal flows may run. An explicit
  SYMPHONY_INTERACTIVE_TTY override from the launcher wins; otherwise both
  standard input and standard output must be terminals, because color support
  alone never establishes input interactivity.
  """
  @spec interactive_tty?() :: boolean()
  def interactive_tty? do
    case System.get_env("SYMPHONY_INTERACTIVE_TTY") do
      "1" -> true
      "0" -> false
      _ -> standard_io_interactive?()
    end
  end

  @spec open(map()) :: {:ok, String.t()} | {:error, String.t()}
  def open(deps \\ %{}) do
    tty? = Map.get(deps, :tty?, &interactive_tty?/0)
    prompt = Map.get(deps, :prompt, &IO.gets/1)

    if tty?.() do
      case connect(prompt) do
        {:ok, host} ->
          IO.puts("Attached to the local host. Closing this terminal leaves the host running.")
          IO.puts("Commands: status, drain TARGET, shutdown, q. Host changes require confirmation.")
          session(host, prompt)

        {:error, _reason} = result ->
          encode(result)
      end
    else
      encode(error("terminal_required", "Use an interactive terminal, or host bootstrap preview and host attach for machine-readable setup."))
    end
  end

  defp standard_io_interactive? do
    case :io.getopts(:standard_io) do
      opts when is_list(opts) ->
        Keyword.get(opts, :stdin, false) == true and Keyword.get(opts, :stdout, false) == true

      _ ->
        false
    end
  catch
    _kind, _reason -> false
  end

  defp connect(prompt) do
    case LocalHost.discover() do
      {:ok, host} -> {:ok, host}
      {:error, %{code: code}} when code in ["host_not_running", "host_stale"] -> setup_and_attach(prompt)
      {:error, _reason} = result -> result
    end
  end

  defp setup_and_attach(prompt) do
    with {:ok, preview} <- HostBootstrap.preview(),
         :ok <- confirm_setup(preview, prompt) do
      LocalHost.attach()
    end
  end

  defp confirm_setup(%{confirmation: token} = preview, prompt) when is_binary(token) do
    print_json(preview)

    if answer(prompt, "Create the listed missing host files? Type yes to confirm: ") == "yes" do
      case HostBootstrap.confirm(token) do
        {:ok, _result} -> :ok
        {:error, _reason} = result -> result
      end
    else
      error("setup_cancelled", "No host was started. Run symphony when ready to confirm setup.")
    end
  end

  defp confirm_setup(preview, _prompt) do
    print_json(preview)
    :ok
  end

  defp session(host, prompt) do
    case answer(prompt, "symphony> ") do
      value when value in [nil, "q", "quit"] ->
        {:ok, "Detached. The host remains running."}

      "status" ->
        show_result(request(host, :get, "/snapshot"))
        session(host, prompt)

      "shutdown" ->
        case change(host, %{"action" => "shutdown", "inputs" => %{}}, prompt) do
          :confirmed -> {:ok, "Host shutdown requested after drain. Check host discover for completion."}
          :cancelled -> session(host, prompt)
        end

      "drain " <> target ->
        change(host, %{"action" => "drain", "target_id" => String.trim(target), "inputs" => %{}}, prompt)
        session(host, prompt)

      _other ->
        IO.puts("Use status, drain TARGET, shutdown, or q.")
        session(host, prompt)
    end
  end

  defp change(host, command, prompt) do
    with {:ok, snapshot} <- request(host, :get, "/snapshot"),
         generation when is_binary(generation) <- get_in(snapshot, ["host", "registry", "generation"]),
         envelope = %{
           "interface_version" => 1,
           "host_id" => host.host_id,
           "registry_generation" => generation,
           "command" => command
         },
         {:ok, preview} <- request(host, :post, "/commands/preview", envelope) do
      print_json(preview)
      confirm_change(host, envelope, preview, prompt)
    else
      {:error, _reason} = result ->
        show_result(result)
        :cancelled

      _other ->
        show_result(error("host_unavailable", "Fetch a current verified host snapshot before retrying."))
        :cancelled
    end
  end

  defp confirm_change(host, envelope, %{"confirmation_token" => token}, prompt) when is_binary(token) do
    if answer(prompt, "Apply this exact host change? Type yes to confirm: ") == "yes" do
      result = request(host, :post, "/commands/confirm", Map.put(envelope, "confirmation_token", token))
      show_result(result)
      if match?({:ok, _}, result), do: :confirmed, else: :cancelled
    else
      IO.puts("Change cancelled.")
      :cancelled
    end
  end

  defp confirm_change(_host, _envelope, _preview, _prompt), do: :cancelled

  defp request(host, method, path, body \\ nil) do
    with {:ok, current} <- LocalHost.discover(),
         true <- current.host_id == host.host_id,
         {:ok, credential} <- File.read(current.token_file),
         {:ok, _apps} <- Application.ensure_all_started(:req) do
      opts = [
        method: method,
        url: current.endpoint <> "/api/v1/operator" <> path,
        headers: [{"authorization", "Bearer " <> String.trim(credential)}],
        retry: false,
        redirect: false,
        receive_timeout: 5_000,
        connect_options: [timeout: 2_000]
      ]

      opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

      case Req.request(opts) do
        {:ok, %{status: status, body: payload}} when status in 200..299 and is_map(payload) -> {:ok, payload}
        _other -> error("host_request_failed", "Refresh the host connection and check the host state before retrying a change.")
      end
    else
      _other -> error("host_connection_changed", "Detach and run symphony again to verify the current host identity.")
    end
  rescue
    _exception -> error("host_request_failed", "Check the host connection before retrying.")
  end

  defp answer(prompt, text) do
    case prompt.(text) do
      value when is_binary(value) -> String.trim(value)
      _eof_or_error -> nil
    end
  end

  defp show_result({_status, payload}), do: print_json(payload)
  defp print_json(payload), do: IO.puts(Jason.encode!(payload, pretty: true, escape: :html_safe))
  defp encode({status, payload}), do: {status, Jason.encode!(payload, escape: :html_safe)}
  defp error(code, next_action), do: {:error, %{code: code, next_action: next_action}}
end
