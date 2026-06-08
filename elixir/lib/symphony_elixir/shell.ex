defmodule SymphonyElixir.Shell do
  @moduledoc false

  @spec escape(String.t()) :: String.t()
  def escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  @spec remote_command(String.t()) :: String.t()
  def remote_command(command) when is_binary(command) do
    "bash -lc " <> escape(command)
  end
end
