defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  @project_closeout_labels MapSet.new(["project closeout", "project-closeout", "project_closeout"])

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :team_id,
    :team_key,
    :team_name,
    :project_id,
    :project_slug,
    :project_name,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          team_id: String.t() | nil,
          team_key: String.t() | nil,
          team_name: String.t() | nil,
          project_id: String.t() | nil,
          project_slug: String.t() | nil,
          project_name: String.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type ticket_kind :: :implementation | :requirement | :project_closeout

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @spec ticket_kind(t()) :: ticket_kind()
  def ticket_kind(%__MODULE__{labels: labels}) when is_list(labels) do
    normalized_labels =
      labels
      |> Enum.map(&normalize_label/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    cond do
      MapSet.member?(normalized_labels, "requirement") ->
        :requirement

      Enum.any?(@project_closeout_labels, &MapSet.member?(normalized_labels, &1)) ->
        :project_closeout

      true ->
        :implementation
    end
  end

  def ticket_kind(%__MODULE__{}), do: :implementation

  @spec requirement?(t()) :: boolean()
  def requirement?(%__MODULE__{} = issue), do: ticket_kind(issue) == :requirement

  defp normalize_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      label -> label
    end
  end

  defp normalize_label(_value), do: nil
end
