defmodule SymphonyElixir.RunTarget do
  @moduledoc """
  Runtime issue target model and repo marker safety helpers.
  """

  alias SymphonyElixir.Linear.Issue

  defmodule RepoMarkers do
    @moduledoc """
    Repository-owned issue markers used to constrain broad run targets.
    """

    defstruct labels: [], allowed_projects: []

    @type t :: %__MODULE__{
            labels: [String.t()],
            allowed_projects: [String.t()]
          }

    @spec empty() :: t()
    def empty, do: %__MODULE__{}

    @spec normalize(term()) :: t()
    def normalize(%__MODULE__{} = markers) do
      %__MODULE__{
        labels: normalize_labels(markers.labels),
        allowed_projects: normalize_projects(markers.allowed_projects)
      }
    end

    def normalize(markers) when is_map(markers) do
      %__MODULE__{
        labels: markers |> map_field(:labels) |> normalize_labels(),
        allowed_projects: markers |> map_field(:allowed_projects) |> normalize_projects()
      }
    end

    def normalize(_markers), do: empty()

    @spec normalize_labels(term()) :: [String.t()]
    def normalize_labels(values) do
      values
      |> normalize_projects()
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
    end

    @spec normalize_projects(term()) :: [String.t()]
    def normalize_projects(values) when is_list(values) do
      values
      |> Enum.map(&normalized_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end

    def normalize_projects(_values), do: []

    defp map_field(map, key) when is_map(map) do
      Map.get(map, key) || Map.get(map, to_string(key))
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

  defmodule Resolution do
    @moduledoc """
    Resolved target issues plus preview warnings.
    """

    defstruct target: nil, issues: [], warnings: [], ordering: :priority

    @type warning :: %{
            required(:code) => atom(),
            optional(:issue_id) => String.t() | nil,
            optional(:issue_identifier) => String.t() | nil,
            optional(:message) => String.t()
          }

    @type t :: %__MODULE__{
            target: SymphonyElixir.RunTarget.t() | nil,
            issues: [Issue.t()],
            warnings: [warning()],
            ordering: :priority | :target
          }

    @spec new(SymphonyElixir.RunTarget.t() | nil, [Issue.t()], [warning()]) :: t()
    def new(target, issues, warnings \\ []) when is_list(issues) and is_list(warnings) do
      %__MODULE__{
        target: target,
        issues: issues,
        warnings: warnings,
        ordering: ordering(target)
      }
    end

    defp ordering(%{__struct__: SymphonyElixir.RunTarget, type: :issues}), do: :target
    defp ordering(_target), do: :priority
  end

  @type target_type :: :project | :team | :query | :issues

  defstruct tracker: "linear",
            type: nil,
            project_id: nil,
            project_slug: nil,
            team_key: nil,
            filter: %{},
            issue_ids: []

  @type t :: %__MODULE__{
          tracker: String.t(),
          type: target_type() | nil,
          project_id: String.t() | nil,
          project_slug: String.t() | nil,
          team_key: String.t() | nil,
          filter: map(),
          issue_ids: [String.t()]
        }

  @spec from_settings(term()) :: {:ok, t()} | {:error, term()}
  def from_settings(%{target: target, tracker: tracker}) do
    default_tracker = tracker |> map_field(:kind) |> normalized_string() || "linear"

    case parse(target, default_tracker: default_tracker) do
      {:ok, %__MODULE__{} = run_target} -> {:ok, run_target}
      {:error, :missing_run_target} -> from_tracker(tracker)
      {:error, reason} -> {:error, reason}
    end
  end

  def from_settings(%{tracker: tracker}), do: from_tracker(tracker)
  def from_settings(_settings), do: {:error, :missing_run_target}

  @spec parse(term()) :: {:ok, t()} | {:error, term()}
  def parse(raw), do: parse(raw, [])

  @spec parse(term(), keyword()) :: {:ok, t()} | {:error, term()}
  def parse(nil, _opts), do: {:error, :missing_run_target}

  def parse(raw, opts) when is_map(raw) and is_list(opts) do
    target = normalize_map_keys(raw)
    tracker = normalized_string(target["tracker"]) || Keyword.get(opts, :default_tracker, "linear")

    with {:ok, type} <- parse_type(target["type"] || target["kind"]) do
      build_target(type, tracker, target)
    end
  end

  def parse(_raw, _opts), do: {:error, :invalid_run_target}

  @spec from_tracker(term()) :: {:ok, t()} | {:error, term()}
  def from_tracker(tracker) do
    project_id = tracker |> map_field(:project_id) |> normalized_string()
    project_slug = tracker |> map_field(:project_slug) |> normalized_string()
    team_key = tracker |> map_field(:team_key) |> normalized_string()
    issue_ids = tracker |> map_field(:issue_ids) |> normalize_string_list()

    cond do
      issue_ids != [] ->
        {:ok, %__MODULE__{tracker: tracker_kind(tracker), type: :issues, issue_ids: issue_ids}}

      is_binary(project_id) ->
        {:ok, %__MODULE__{tracker: tracker_kind(tracker), type: :project, project_id: project_id}}

      is_binary(project_slug) ->
        {:ok, %__MODULE__{tracker: tracker_kind(tracker), type: :project, project_slug: project_slug}}

      is_binary(team_key) ->
        {:ok, %__MODULE__{tracker: tracker_kind(tracker), type: :team, team_key: team_key}}

      true ->
        {:error, :missing_linear_run_target}
    end
  end

  @spec repo_markers(term()) :: RepoMarkers.t()
  def repo_markers(%{issue_markers: markers}), do: RepoMarkers.normalize(markers)
  def repo_markers(markers), do: RepoMarkers.normalize(markers)

  @spec validate_marker_safety(t(), RepoMarkers.t()) :: :ok | {:error, term()}
  def validate_marker_safety(%__MODULE__{} = target, %RepoMarkers{} = markers) do
    if broad_target?(target) and empty_markers?(markers) do
      {:error, :run_target_requires_issue_markers}
    else
      :ok
    end
  end

  @spec apply_marker_safety(t(), [Issue.t()], RepoMarkers.t()) :: Resolution.t()
  def apply_marker_safety(%__MODULE__{type: :issues} = target, issues, %RepoMarkers{} = markers)
      when is_list(issues) do
    warnings =
      issues
      |> Enum.reject(&marker_match?(&1, markers))
      |> Enum.map(&marker_mismatch_warning/1)

    Resolution.new(target, issues, warnings)
  end

  def apply_marker_safety(%__MODULE__{} = target, issues, %RepoMarkers{} = markers) when is_list(issues) do
    issues =
      if empty_markers?(markers) do
        issues
      else
        Enum.filter(issues, &marker_match?(&1, markers))
      end

    Resolution.new(target, issues, [])
  end

  @spec marker_match?(Issue.t(), RepoMarkers.t()) :: boolean()
  def marker_match?(%Issue{} = issue, %RepoMarkers{} = markers) do
    labels_match?(issue, markers.labels) and project_match?(issue, markers.allowed_projects)
  end

  @spec broad_target?(t()) :: boolean()
  def broad_target?(%__MODULE__{type: type}), do: type in [:team, :query]

  @spec empty_markers?(RepoMarkers.t()) :: boolean()
  def empty_markers?(%RepoMarkers{labels: [], allowed_projects: []}), do: true
  def empty_markers?(%RepoMarkers{}), do: false

  defp build_target(:project, tracker, target) do
    project = map_field(target, :project) || %{}
    project_id = normalized_string(target["project_id"] || project["id"])
    project_slug = normalized_string(target["project_slug"] || target["project_slug_id"] || project["slug"] || project["slug_id"] || project["slugId"])

    if project_id || project_slug do
      {:ok, %__MODULE__{tracker: tracker, type: :project, project_id: project_id, project_slug: project_slug}}
    else
      {:error, :missing_project_target}
    end
  end

  defp build_target(:team, tracker, target) do
    team_key = normalized_string(target["team_key"] || get_in(target, ["team", "key"]))

    if team_key do
      {:ok, %__MODULE__{tracker: tracker, type: :team, team_key: team_key}}
    else
      {:error, :missing_team_target}
    end
  end

  defp build_target(:query, tracker, target) do
    filter = target["filter"] || target["query"]

    if is_map(filter) do
      {:ok, %__MODULE__{tracker: tracker, type: :query, filter: normalize_map_keys(filter)}}
    else
      {:error, :missing_query_filter}
    end
  end

  defp build_target(:issues, tracker, target) do
    issue_ids =
      (target["issue_ids"] || target["issues"] || target["ids"])
      |> normalize_string_list()

    if issue_ids == [] do
      {:error, :missing_issue_ids}
    else
      {:ok, %__MODULE__{tracker: tracker, type: :issues, issue_ids: issue_ids}}
    end
  end

  defp parse_type(type) when is_atom(type), do: parse_type(Atom.to_string(type))

  defp parse_type(type) when is_binary(type) do
    case type |> String.trim() |> String.downcase() do
      "project" -> {:ok, :project}
      "team" -> {:ok, :team}
      "query" -> {:ok, :query}
      "issues" -> {:ok, :issues}
      "issue_ids" -> {:ok, :issues}
      "issue" -> {:ok, :issues}
      "" -> {:error, :missing_run_target_type}
      unknown -> {:error, {:unsupported_run_target_type, unknown}}
    end
  end

  defp parse_type(_type), do: {:error, :missing_run_target_type}

  defp tracker_kind(tracker), do: tracker |> map_field(:kind) |> normalized_string() || "linear"

  defp marker_mismatch_warning(%Issue{} = issue) do
    %{
      code: :repo_marker_mismatch,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      message: "Explicit issue does not match repository issue markers."
    }
  end

  defp labels_match?(_issue, []), do: true

  defp labels_match?(%Issue{labels: labels}, marker_labels) when is_list(labels) and is_list(marker_labels) do
    issue_labels =
      labels
      |> RepoMarkers.normalize_labels()
      |> MapSet.new()

    Enum.all?(marker_labels, &MapSet.member?(issue_labels, &1))
  end

  defp labels_match?(_issue, _marker_labels), do: false

  defp project_match?(_issue, []), do: true

  defp project_match?(%Issue{} = issue, marker_projects) when is_list(marker_projects) do
    issue_projects =
      [issue.project_slug, issue.project_id]
      |> RepoMarkers.normalize_projects()
      |> MapSet.new()

    Enum.any?(marker_projects, &MapSet.member?(issue_projects, &1))
  end

  defp normalize_map_keys(value) when is_map(value) do
    Map.new(value, fn {key, field_value} -> {to_string(key), normalize_map_keys(field_value)} end)
  end

  defp normalize_map_keys(value) when is_list(value), do: Enum.map(value, &normalize_map_keys/1)
  defp normalize_map_keys(value), do: value

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalized_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(_values), do: []

  defp normalized_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_string(value) when is_atom(value) and value not in [nil, true, false] do
    value
    |> Atom.to_string()
    |> normalized_string()
  end

  defp normalized_string(_value), do: nil

  defp map_field(map, field) when is_map(map) and is_atom(field) do
    Map.get(map, field) || Map.get(map, Atom.to_string(field))
  end

  defp map_field(_map, _field), do: nil
end
