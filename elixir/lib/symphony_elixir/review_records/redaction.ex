defmodule SymphonyElixir.ReviewRecords.Redaction do
  @moduledoc """
  Converts review-record payloads into JSON-safe data while removing local secrets.
  """

  alias SymphonyElixir.HandoffRoute
  alias SymphonyElixir.HandoffRoute.Decision

  @secret_key ~r/(api[_-]?key|authorization|credential|password|secret|token)/i
  @authorization_bearer ~r{(?i)(authorization\s*:\s*bearer\s+)[^\s,"')\]\}]+}
  @bare_bearer ~r{(?i)(bearer\s+)[^\s,"')\]\}]+}
  @secret_assignment ~r{(?i)((?:api[_-]?key|credential|password|secret|token)\s*[=:]\s*)[^\s,"')\]\}]+}
  @embedded_absolute_path ~r{(?<![:/A-Za-z0-9_.-])/(?:[^\s,"')\]\}]+/?)+}

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
