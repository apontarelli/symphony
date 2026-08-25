defmodule SymphonyElixir.SSH do
  @moduledoc false

  alias SymphonyElixir.{ProcessSupervisor, Shell}

  @type target :: %{destination: String.t(), port: String.t() | nil}
  @type parse_error :: :invalid_target

  @spec run(String.t(), String.t(), keyword()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    {timeout_ms, command_opts} = Keyword.pop(opts, :timeout)

    with {:ok, target} <- parse_target(host),
         {:ok, executable} <- ssh_executable() do
      run_command(executable, ssh_args(target, command), timeout_ms, command_opts)
    end
  end

  defp run_command(executable, args, nil, opts),
    do: {:ok, System.cmd(executable, args, opts)}

  defp run_command(executable, args, timeout_ms, opts)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    ProcessSupervisor.run([executable | args], timeout_ms, opts)
  end

  defp run_command(_executable, _args, _timeout_ms, _opts),
    do: {:error, :invalid_ssh_timeout}

  @spec start_port(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def start_port(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, target} <- parse_target(host),
         {:ok, executable} <- ssh_executable() do
      line_bytes = Keyword.get(opts, :line)

      port_opts =
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(ssh_args(target, command), &String.to_charlist/1)
        ]
        |> maybe_put_line_option(line_bytes)

      {:ok, Port.open({:spawn_executable, String.to_charlist(executable)}, port_opts)}
    end
  end

  @spec remote_shell_command(String.t()) :: String.t()
  def remote_shell_command(command) when is_binary(command) do
    Shell.remote_command(command)
  end

  defp ssh_executable do
    case System.find_executable("ssh") do
      nil -> {:error, :ssh_not_found}
      executable -> {:ok, executable}
    end
  end

  defp ssh_args(%{destination: destination, port: port}, command) do
    []
    |> maybe_put_config()
    |> Kernel.++(["-T"])
    |> maybe_put_port(port)
    |> Kernel.++([destination, remote_shell_command(command)])
  end

  defp maybe_put_line_option(port_opts, nil), do: port_opts
  defp maybe_put_line_option(port_opts, line_bytes), do: Keyword.put(port_opts, :line, line_bytes)

  defp maybe_put_config(args) do
    case System.get_env("SYMPHONY_SSH_CONFIG") do
      config_path when is_binary(config_path) and config_path != "" ->
        args ++ ["-F", config_path]

      _ ->
        args
    end
  end

  defp maybe_put_port(args, nil), do: args
  defp maybe_put_port(args, port), do: args ++ ["-p", port]

  @doc """
  Parses an SSH destination without reading environment or starting SSH.
  """
  @spec parse_target(term()) :: {:ok, target()} | {:error, parse_error()}
  def parse_target(target) when is_binary(target) do
    with {:ok, target} <- validate_target_term(target),
         {:ok, target} <- normalize_uri_target(target),
         {:ok, user_prefix, host} <- split_user(target),
         :ok <- validate_host_start(host),
         {:ok, destination, port} <- parse_host(user_prefix, host) do
      {:ok, %{destination: destination, port: port}}
    else
      _invalid -> {:error, :invalid_target}
    end
  end

  def parse_target(_target), do: {:error, :invalid_target}

  defp validate_target_term(target) do
    cond do
      not String.valid?(target) ->
        {:error, :invalid_target}

      Regex.match?(~r/[\p{Cc}]/u, target) ->
        {:error, :invalid_target}

      true ->
        trimmed = String.trim(target)

        if trimmed != "" and not Regex.match?(~r/\s/u, trimmed),
          do: {:ok, trimmed},
          else: {:error, :invalid_target}
    end
  end

  defp normalize_uri_target(<<"ssh://", authority::binary>>) do
    if authority != "" and not String.contains?(authority, ["/", "?", "#"]),
      do: {:ok, authority},
      else: {:error, :invalid_target}
  end

  defp normalize_uri_target(target), do: {:ok, target}

  defp validate_host_start(<<"-", _rest::binary>>), do: {:error, :invalid_target}
  defp validate_host_start(_host), do: :ok

  defp split_user(target) do
    case String.split(target, "@", parts: 2) do
      [host] ->
        {:ok, "", host}

      [user, host] ->
        if Regex.match?(~r/\A[A-Za-z0-9_][A-Za-z0-9._+-]*\z/, user) and host != "",
          do: {:ok, user <> "@", host},
          else: {:error, :invalid_target}
    end
  end

  defp parse_host(user_prefix, "[" <> _rest = host) do
    case Regex.run(~r/\A(\[[^\]]+\]):([0-9]+)\z/, host, capture: :all_but_first) do
      [bracketed, port] ->
        with true <- valid_bracketed_host?(bracketed),
             :ok <- validate_port(port) do
          {:ok, user_prefix <> bracketed, port}
        else
          _invalid -> {:error, :invalid_target}
        end

      _no_port ->
        if valid_bracketed_host?(host),
          do: {:ok, user_prefix <> host, nil},
          else: {:error, :invalid_target}
    end
  end

  defp parse_host(user_prefix, host) do
    case length(:binary.matches(host, ":")) do
      0 ->
        if valid_hostname?(host),
          do: {:ok, user_prefix <> host, nil},
          else: {:error, :invalid_target}

      1 ->
        parse_host_port(user_prefix, host)

      _ipv6 ->
        if valid_ipv6?(host),
          do: {:ok, user_prefix <> host, nil},
          else: {:error, :invalid_target}
    end
  end

  defp parse_host_port(user_prefix, host) do
    with [hostname, port] <- String.split(host, ":", parts: 2),
         true <- valid_hostname?(hostname),
         :ok <- validate_port(port) do
      {:ok, user_prefix <> hostname, port}
    else
      _invalid -> {:error, :invalid_target}
    end
  end

  defp valid_hostname?(host) do
    parts = String.split(host, ".", trim: false)

    labels =
      case List.last(parts) do
        "" -> Enum.drop(parts, -1)
        _label -> parts
      end

    not String.ends_with?(host, "..") and labels != [] and
      Enum.all?(labels, &valid_hostname_label?/1)
  end

  defp valid_hostname_label?(label),
    do: Regex.match?(~r/\A[A-Za-z0-9_](?:[A-Za-z0-9_+-]*[A-Za-z0-9])?\z/, label)

  defp valid_bracketed_host?("[" <> rest) do
    with true <- String.ends_with?(rest, "]"),
         inner = binary_part(rest, 0, byte_size(rest) - 1),
         true <- valid_ipv6?(inner) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_ipv6?(host) do
    case String.split(host, "%", parts: 2) do
      [address] ->
        ipv6_address?(address)

      [address, zone] ->
        valid_zone?(zone) and ipv6_address?(address)
    end
  end

  defp ipv6_address?(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, {_a, _b, _c, _d, _e, _f, _g, _h}} -> true
      _invalid -> false
    end
  end

  defp valid_zone?(zone),
    do: Regex.match?(~r/\A[A-Za-z0-9_.-]{1,63}\z/, zone)

  defp validate_port(port) do
    case Integer.parse(port) do
      {number, ""} when number in 1..65_535 -> :ok
      _invalid -> {:error, :invalid_target}
    end
  end
end
