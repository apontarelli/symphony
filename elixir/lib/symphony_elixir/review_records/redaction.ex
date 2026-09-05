defmodule SymphonyElixir.ReviewRecords.Redaction do
  @moduledoc """
  Converts review-record payloads into JSON-safe data while removing local secrets.
  """

  alias SymphonyElixir.HandoffRoute
  alias SymphonyElixir.HandoffRoute.Decision

  @secret_key ~r/(api[_-]?key|authorization|credential|password|secret|token)/i
  @authorization_bearer ~r{(?i)(authorization\s*:\s*bearer\s+)[^\s,"')\]\}]+}
  @bare_bearer ~r{(?i)(bearer\s+)[^\s,"')\]\}]+}
  @secret_assignment ~r{(?is)((?:["']?[A-Za-z0-9_-]*(?:api[_-]?key|authorization|credential|password|secret|token)[A-Za-z0-9_-]*["']?)\s*(?:=>|[=:])\s*)(?:"(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?|[^\s,"')\]\}]+)}
  @embedded_absolute_path ~r{(?<![:/A-Za-z0-9_.-])/(?:[^\s,"')\]\}]+/?)+}
  @operator_prompt ~r{((?:["']?(?:prompt|input)["']?)\s*(?:=>|[=:])\s*).*}is
  @secret_reference ~r{secret://[^\s"'<>),\]\}]+}i

  @spec json_ready(term()) :: term()
  def json_ready(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def json_ready(%Date{} = value), do: Date.to_iso8601(value)
  def json_ready(%Decision{} = decision), do: decision |> HandoffRoute.to_map() |> json_ready()

  def json_ready(%_struct{} = struct) do
    struct
    |> Map.from_struct()
    |> json_ready()
  end

  def json_ready(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      string_key = key_name(key)
      {string_key, json_ready_value(string_key, value)}
    end)
  end

  def json_ready(values) when is_list(values), do: Enum.map(values, &json_ready/1)
  def json_ready(value) when is_atom(value), do: token(value)
  def json_ready(value) when is_binary(value), do: redact_string(value)
  def json_ready(value), do: value

  @doc """
  Redacts secret-bearing keys, labeled secret values, and exact in-memory secrets
  without changing map keys or other value types.
  """
  @spec redact_secrets(term(), [String.t()]) :: term()

  def redact_secrets(map, exact_values) when is_map(map) and is_list(exact_values) do
    Map.new(map, fn {key, value} ->
      if Regex.match?(@secret_key, key_name(key)) do
        {key, "<redacted:secret>"}
      else
        {key, redact_secrets(value, exact_values)}
      end
    end)
  end

  def redact_secrets(values, exact_values) when is_list(values),
    do: Enum.map(values, &redact_secrets(&1, exact_values))

  def redact_secrets(value, exact_values) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact_secrets(&1, exact_values))
    |> List.to_tuple()
  end

  def redact_secrets(value, exact_values) when is_binary(value) do
    exact_values
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.reduce(redact_secret_values(value), fn secret, redacted ->
      String.replace(redacted, secret, "<redacted:secret>")
    end)
  end

  def redact_secrets(value, _exact_values), do: value

  @spec redact_string(term()) :: String.t()
  def redact_string(value) when is_binary(value) do
    value
    |> redact_secret_values()
    |> redact_paths()
  end

  def redact_string(value) do
    value
    |> to_string()
    |> redact_string()
  end

  @doc """
  Redacts operator-visible strings without hiding intentional workspace paths.
  Prompt-bearing text is removed through the end, including multiline payloads.
  """
  @spec redact_operator_string(String.t()) :: String.t()
  def redact_operator_string(value) when is_binary(value) do
    value
    |> then(&Regex.replace(@secret_reference, &1, "<redacted:secret-reference>"))
    |> redact_secret_values()
    |> then(&Regex.replace(@operator_prompt, &1, "\\1<redacted:prompt>"))
  end

  defp json_ready_value(key, value) do
    if Regex.match?(@secret_key, key) do
      "<redacted:secret>"
    else
      json_ready(value)
    end
  end

  defp redact_secret_values(value) do
    @authorization_bearer
    |> Regex.replace(value, "\\1<redacted:secret>")
    |> then(&Regex.replace(@bare_bearer, &1, "\\1<redacted:secret>"))
    |> then(&Regex.replace(@secret_assignment, &1, "\\1<redacted:secret>"))
  end

  defp redact_paths(value) do
    cond do
      Path.type(value) == :absolute ->
        "<redacted:absolute-path>"

      Regex.match?(@embedded_absolute_path, value) ->
        Regex.replace(@embedded_absolute_path, value, "<redacted:absolute-path>")

      true ->
        value
    end
  end

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key), do: to_string(key)

  defp token(nil), do: ""
  defp token(value) when is_atom(value), do: value |> Atom.to_string() |> token()

  defp token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end
end
