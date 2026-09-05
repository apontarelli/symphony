defmodule SymphonyElixir.OperatorLogHandler do
  @moduledoc false

  @behaviour :logger_handler

  alias SymphonyElixir.OperatorInterface

  @formatter_config %{
    chars_limit: 8_192,
    depth: 20,
    single_line: true,
    template: [:msg]
  }

  @impl true
  def adding_handler(config), do: {:ok, config}

  @impl true
  def changing_config(_operation, old_config, new_config),
    do: {:ok, Map.merge(old_config, new_config)}

  @impl true
  def filter_config(config), do: config

  @impl true
  def removing_handler(_config), do: :ok

  # Runtime protocol frames, child output, and OTP reports can contain unlabeled
  # prompts or credentials. Keep their level/source, but never format their body.
  @impl true
  def log(%{level: level, meta: %{operator_payload: :unsafe} = metadata}, %{config: %{server: server}}) do
    source = metadata |> Map.get(:mfa) |> source_module()
    OperatorInterface.publish_log(server, level, "<omitted:raw-runtime-payload>", source)
  end

  def log(%{level: level, msg: {:report, _report}, meta: metadata}, %{config: %{server: server}}) do
    source = metadata |> Map.get(:mfa) |> source_module()
    OperatorInterface.publish_log(server, level, "<omitted:runtime-report>", source)
  end

  def log(%{level: level, meta: metadata} = event, %{config: %{server: server}}) do
    message = event |> :logger_formatter.format(@formatter_config) |> IO.chardata_to_string()
    source = metadata |> Map.get(:mfa) |> source_module()
    OperatorInterface.publish_log(server, level, message, source)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  def log(_event, _config), do: :ok

  defp source_module({module, _function, _arity}) when is_atom(module), do: Atom.to_string(module)
  defp source_module(_mfa), do: nil
end
