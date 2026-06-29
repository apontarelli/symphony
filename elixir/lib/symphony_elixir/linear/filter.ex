defmodule SymphonyElixir.Linear.Filter do
  @moduledoc false

  alias SymphonyElixir.RunTarget
  alias SymphonyElixir.RunTarget.RepoMarkers

  @spec issue_filter(RunTarget.t(), [String.t()], RepoMarkers.t()) :: map()
  def issue_filter(%RunTarget{type: :query, filter: filter}, state_names, %RepoMarkers{} = markers)
      when is_map(filter) and is_list(state_names) do
    markers = RepoMarkers.normalize(markers)

    [filter, state_filter(state_names), marker_filter(markers)]
    |> Enum.reject(&empty_filter?/1)
    |> case do
      [] -> %{}
      [only] -> only
      filters -> %{"and" => filters}
    end
  end

  def issue_filter(%RunTarget{}, _state_names, _markers), do: %{}

  defp state_filter(state_names) do
    states = normalize_string_list(state_names)

    if states == [] do
      %{}
    else
      %{"state" => %{"name" => %{"in" => states}}}
    end
  end

  defp marker_filter(%RepoMarkers{} = markers) do
    [label_filter(markers.labels), project_filter(markers.allowed_projects)]
    |> Enum.reject(&empty_filter?/1)
    |> case do
      [] -> %{}
      [only] -> only
      filters -> %{"and" => filters}
    end
  end

  defp label_filter([]), do: %{}
  defp label_filter(labels), do: %{"labels" => %{"name" => %{"in" => labels}}}

  defp project_filter([]), do: %{}

  defp project_filter(projects) do
    %{
      "or" => [
        %{"project" => %{"slugId" => %{"in" => projects}}},
        %{"project" => %{"id" => %{"in" => projects}}}
      ]
    }
  end

  defp empty_filter?(filter), do: filter in [nil, %{}]

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalized_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalized_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_string(_value), do: nil
end
