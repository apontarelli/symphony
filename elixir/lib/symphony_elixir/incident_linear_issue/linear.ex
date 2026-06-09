defmodule SymphonyElixir.IncidentLinearIssue.Linear do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.IncidentLinearIssue
  alias SymphonyElixir.Linear.Client

  @recent_issues_query """
  query SymphonyIncidentRecentIssues($projectSlug: String!, $first: Int!) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}}, first: $first, orderBy: updatedAt) {
      nodes {
        id
        identifier
        title
        description
        url
        state {
          name
          type
        }
      }
    }
  }
  """
  @allowed_target_state_types ["backlog", "unstarted"]

  @target_query """
  query SymphonyIncidentTarget($projectSlug: String!) {
    projects(filter: {slugId: {eq: $projectSlug}}, first: 1) {
      nodes {
        id
        name
        slugId
        teams {
          nodes {
            id
            key
            name
            states {
              nodes {
                id
                name
                type
              }
            }
          }
        }
      }
    }
  }
  """

  @labels_query """
  query SymphonyIncidentLabels($teamId: ID!, $names: [String!]!, $first: Int!) {
    issueLabels(filter: {team: {id: {eq: $teamId}}, name: {in: $names}}, first: $first) {
      nodes {
        id
        name
      }
    }
  }
  """

  @create_mutation """
  mutation SymphonyIncidentCreateIssue($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue {
        id
        identifier
        title
        url
      }
    }
  }
  """

  @spec create(map(), keyword()) ::
          {:ok, map()} | {:duplicate, IncidentLinearIssue.Duplicate.t()} | {:error, term()}
  def create(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    with :ok <- require_project_opt_in(opts),
         {:ok, plan} <- IncidentLinearIssue.plan(payload, opts),
         :ok <- require_configured_project_scope(plan),
         {:ok, candidates} <- recent_issues(plan, opts) do
      case IncidentLinearIssue.find_duplicate(plan, candidates) do
        {:duplicate, duplicate} -> {:duplicate, duplicate}
        :none -> create_from_plan(plan, opts)
      end
    end
  end

  defp require_project_opt_in(opts) do
    if Keyword.get(opts, :project_opt_in, false), do: :ok, else: {:error, :project_opt_in_required}
  end

  defp require_configured_project_scope(%IncidentLinearIssue{} = plan) do
    with {:ok, settings} <- Config.settings() do
      cond do
        settings.tracker.kind != "linear" ->
          {:error, {:unsupported_incident_tracker_kind, settings.tracker.kind}}

        not is_binary(settings.tracker.project_slug) ->
          {:error, :missing_incident_project_scope}

        normalize_text(settings.tracker.project_slug) != normalize_text(plan.target_project) ->
          {:error, {:incident_project_scope_mismatch, plan.target_project, settings.tracker.project_slug}}

        true ->
          :ok
      end
    end
  end

  defp recent_issues(%IncidentLinearIssue{} = plan, opts) do
    client = client_module(opts)

    case client.graphql(@recent_issues_query, %{
           projectSlug: plan.target_project,
           first: plan.dedupe.candidate_limit
         }) do
      {:ok, %{"errors" => errors}} when not is_nil(errors) and errors != [] -> {:error, {:linear_graphql_errors, errors}}
      {:ok, %{"data" => %{"issues" => %{"nodes" => nodes}}}} when is_list(nodes) -> {:ok, nodes}
      {:ok, _body} -> {:error, :linear_unknown_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_from_plan(%IncidentLinearIssue{} = plan, opts) do
    client = client_module(opts)

    with {:ok, target} <- resolve_target(plan, client),
         {:ok, label_ids} <- resolve_label_ids(plan, target.team_id, client) do
      create_linear_issue(plan, target, label_ids, client)
    end
  end

  defp resolve_target(%IncidentLinearIssue{} = plan, client) do
    case client.graphql(@target_query, %{projectSlug: plan.target_project}) do
      {:ok, %{"errors" => errors}} when not is_nil(errors) and errors != [] ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, %{"data" => %{"projects" => %{"nodes" => [project | _]}}}} ->
        resolve_target_from_project(plan, project)

      {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}} ->
        {:error, {:project_not_found, plan.target_project}}

      {:ok, _body} ->
        {:error, :linear_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_target_from_project(%IncidentLinearIssue{} = plan, project) do
    teams = get_in(project, ["teams", "nodes"]) || []

    if plan.target_team_key do
      resolve_target_from_team_key(plan, project, teams)
    else
      case teams do
        [%{} = team] ->
          resolve_target_for_team(plan, project, team)

        [] ->
          {:error, {:project_has_no_teams, plan.target_project}}

        _teams ->
          {:error, {:ambiguous_project_teams, plan.target_project}}
      end
    end
  end

  defp resolve_target_from_team_key(%IncidentLinearIssue{} = plan, project, teams) do
    case Enum.find(teams, &(normalize_text(&1["key"]) == normalize_text(plan.target_team_key))) do
      %{} = team -> resolve_target_for_team(plan, project, team)
      nil -> {:error, {:target_team_not_found, plan.target_team_key, plan.target_project}}
    end
  end

  defp resolve_target_for_team(%IncidentLinearIssue{} = plan, project, team) do
    case find_state(team, plan.target_state) do
      nil ->
        {:error, {:target_state_not_found, plan.target_state}}

      %{} = state ->
        with :ok <- validate_target_state(state, plan.target_state),
             team_id when is_binary(team_id) <- team["id"],
             project_id when is_binary(project_id) <- project["id"],
             state_id when is_binary(state_id) <- state["id"] do
          {:ok, %{project_id: project_id, team_id: team_id, state_id: state_id}}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_linear_target}
        end
    end
  end

  defp find_state(team, target_state) do
    team
    |> get_in(["states", "nodes"])
    |> case do
      states when is_list(states) -> Enum.find(states, &(normalize_text(&1["name"]) == normalize_text(target_state)))
      _ -> nil
    end
  end

  defp validate_target_state(state, target_state) do
    state_type = normalize_text(state["type"])

    if state_type in @allowed_target_state_types do
      :ok
    else
      {:error, {:target_state_not_allowed, target_state, state["type"]}}
    end
  end

  defp resolve_label_ids(%IncidentLinearIssue{} = plan, team_id, client) do
    case client.graphql(@labels_query, %{teamId: team_id, names: plan.labels, first: length(plan.labels)}) do
      {:ok, %{"errors" => errors}} when not is_nil(errors) and errors != [] ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, %{"data" => %{"issueLabels" => %{"nodes" => labels}}}} when is_list(labels) ->
        label_lookup = Map.new(labels, &{normalize_text(&1["name"]), &1["id"]})
        missing_labels = Enum.reject(plan.labels, &Map.has_key?(label_lookup, normalize_text(&1)))

        if missing_labels == [] do
          {:ok, Enum.map(plan.labels, &Map.fetch!(label_lookup, normalize_text(&1)))}
        else
          {:error, {:missing_linear_labels, missing_labels}}
        end

      {:ok, _body} ->
        {:error, :linear_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_linear_issue(%IncidentLinearIssue{} = plan, target, label_ids, client) do
    input = %{
      teamId: target.team_id,
      projectId: target.project_id,
      stateId: target.state_id,
      labelIds: label_ids,
      priority: plan.priority,
      title: plan.title,
      description: plan.body
    }

    case client.graphql(@create_mutation, %{input: input}) do
      {:ok, %{"errors" => errors}} when not is_nil(errors) and errors != [] -> {:error, {:linear_graphql_errors, errors}}
      {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}} -> {:ok, issue}
      {:ok, %{"data" => %{"issueCreate" => %{"success" => false}}}} -> {:error, :linear_issue_create_failed}
      {:ok, _body} -> {:error, :linear_unknown_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()

  defp client_module(opts) do
    Keyword.get(opts, :client) ||
      Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end
end
