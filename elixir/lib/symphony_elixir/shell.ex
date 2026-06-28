defmodule SymphonyElixir.Shell do
  @moduledoc false

  @spec escape(String.t()) :: String.t()
  def escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  @spec argv_to_command([String.t()]) :: String.t()
  def argv_to_command(argv) when is_list(argv) do
    Enum.map_join(argv, " ", &display_arg/1)
  end

  @spec split(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def split(command) when is_binary(command) do
    command
    |> String.graphemes()
    |> split_graphemes([], "", nil, false)
  end

  @spec remote_command(String.t()) :: String.t()
  def remote_command(command) when is_binary(command) do
    "bash -lc " <> escape(command)
  end

  defp split_graphemes([], tokens, current, nil, false) do
    {:ok, finalize_token(tokens, current)}
  end

  defp split_graphemes([], _tokens, _current, quote, _escaped), do: {:error, {:unterminated_quote, quote}}

  defp split_graphemes([char | rest], tokens, current, quote, true) do
    split_graphemes(rest, tokens, current <> char, quote, false)
  end

  defp split_graphemes(["\\" | rest], tokens, current, quote, false) do
    split_graphemes(rest, tokens, current, quote, true)
  end

  defp split_graphemes([char | rest], tokens, current, nil, false) when char in ["'", "\""] do
    split_graphemes(rest, tokens, current, char, false)
  end

  defp split_graphemes([char | rest], tokens, current, quote, false) when char == quote do
    split_graphemes(rest, tokens, current, nil, false)
  end

  defp split_graphemes([char | rest], tokens, current, nil, false) when char in [" ", "\t", "\n", "\r"] do
    split_graphemes(rest, finalize_token(tokens, current), "", nil, false)
  end

  defp split_graphemes([char | rest], tokens, current, quote, false) do
    split_graphemes(rest, tokens, current <> char, quote, false)
  end

  defp finalize_token(tokens, ""), do: tokens
  defp finalize_token(tokens, current), do: tokens ++ [current]

  defp display_arg(value) when is_binary(value) do
    if String.match?(value, ~r|^[A-Za-z0-9_@%+=:,./-]+$|) do
      value
    else
      escape(value)
    end
  end
end
