defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, RunTarget, TargetContext}
  alias SymphonyElixir.Linear.{Filter, Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000
  @linear_rate_limit_reset_headers [
    "x-ratelimit-endpoint-requests-reset",
    "x-ratelimit-requests-reset"
  ]

  @query_by_project_slug """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        team {
          id
          key
          name
        }
        project {
          id
          slugId
          name
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_project_id """
  query SymphonyLinearPollByProjectId($projectId: ID!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {id: {eq: $projectId}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        team {
          id
          key
          name
        }
        project {
          id
          slugId
          name
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_team_key """
  query SymphonyLinearPollByTeamKey($teamKey: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {team: {key: {eq: $teamKey}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        team {
          id
          key
          name
        }
        project {
          id
          slugId
          name
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_filter """
  query SymphonyLinearPollByFilter($filter: IssueFilter, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: $filter, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        team {
          id
          key
          name
        }
        project {
          id
          slugId
          name
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesByUuid($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        team {
          id
          key
          name
        }
        project {
          id
          slugId
          name
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @query_by_issue_ref """
  query SymphonyLinearIssueById($id: String!, $relationFirst: Int!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      priority
      state {
        name
      }
      branchName
      url
      assignee {
        id
      }
      team {
        id
        key
        name
      }
      project {
        id
        slugId
        name
      }
      labels {
        nodes {
          name
        }
      }
      inverseRelations(first: $relationFirst) {
        nodes {
          type
          issue {
            id
            identifier
            state {
              name
            }
          }
        }
      }
      createdAt
      updatedAt
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_issues_by_states(TargetContext.t(), [String.t()]) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(%TargetContext{} = context, state_names),
    do: fetch_issues_by_states(context, state_names, [])

  @doc false
  @spec fetch_issues_by_states(TargetContext.t(), [String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(%TargetContext{} = context, state_names, opts)
      when is_list(state_names) and is_list(opts) do
    with {:ok, normalized_states} <- context_string_list(state_names) do
      fetch_context_issues_by_states(context, normalized_states, opts)
    end
  end

  def fetch_issues_by_states(%TargetContext{}, _state_names, _opts),
    do: {:error, :invalid_tracker_context}

  defp fetch_context_issues_by_states(_context, [], _opts), do: {:ok, []}

  defp fetch_context_issues_by_states(context, states, opts) do
    with {:ok, target} <- context_configured_target(context),
         {:ok, _active_states, required_labels, assignee} <- context_routing(context),
         {:ok, %RunTarget.Resolution{issues: issues}} <-
           resolve_context_target(
             context,
             target,
             states,
             required_labels,
             assignee,
             opts
           ) do
      {:ok, issues}
    end
  end

  @spec resolve_run_target(TargetContext.t(), RunTarget.t()) ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_run_target(%TargetContext{} = context, %RunTarget{} = target),
    do: resolve_run_target(context, target, [])

  def resolve_run_target(%TargetContext{}, _target),
    do: {:error, :invalid_tracker_context}

  @doc false
  @spec resolve_run_target(TargetContext.t(), RunTarget.t(), keyword()) ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_run_target(%TargetContext{} = context, %RunTarget{} = target, opts)
      when is_list(opts) do
    with {:ok, state_names, required_labels, assignee} <- context_routing(context) do
      resolve_context_target(
        context,
        target,
        state_names,
        required_labels,
        assignee,
        opts
      )
    end
  end

  def resolve_run_target(%TargetContext{}, %RunTarget{}, _opts),
    do: {:error, :invalid_tracker_context}

  @spec fetch_issue_states_by_ids(TargetContext.t(), [String.t()]) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(%TargetContext{} = context, issue_ids),
    do: fetch_issue_states_by_ids(context, issue_ids, [])

  @doc false
  @spec fetch_issue_states_by_ids(TargetContext.t(), [String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(%TargetContext{} = context, issue_ids, opts)
      when is_list(issue_ids) and is_list(opts) do
    with {:ok, ids} <- context_string_list(issue_ids) do
      fetch_context_issue_states(context, ids, opts)
    end
  end

  def fetch_issue_states_by_ids(%TargetContext{}, _issue_ids, _opts),
    do: {:error, :invalid_tracker_context}

  defp fetch_context_issue_states(_context, [], _opts), do: {:ok, []}

  defp fetch_context_issue_states(context, ids, opts) do
    graphql_fun = fn query, variables -> graphql(context, query, variables, opts) end

    with {:ok, _states, _required_labels, assignee} <- context_routing(context),
         {:ok, assignee_filter} <- context_assignee_filter(assignee, graphql_fun) do
      do_fetch_issue_states(ids, assignee_filter, graphql_fun)
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        response_error(response)

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @spec graphql(TargetContext.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, atom() | {:linear_rate_limited, map()}}
  def graphql(%TargetContext{} = context, query, variables, opts)
      when is_binary(query) and is_map(variables) and is_list(opts) do
    case context_request_options(opts) do
      {:ok, request_fun, operation_name} ->
        payload = build_graphql_payload(query, variables, operation_name)

        with {:ok, endpoint, headers} <- context_graphql_transport(context) do
          context_graphql_request(request_fun, endpoint, payload, headers)
        end

      :error ->
        {:error, :invalid_linear_request_result}
    end
  end

  def graphql(%TargetContext{}, _query, _variables, _opts),
    do: {:error, :invalid_linear_request_result}

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, nil, graphql_fun)
    end
  end

  @doc false
  @spec fetch_by_project_selector_for_test(
          map(),
          [String.t()],
          (String.t(), map() -> {:ok, map()} | {:error, term()})
        ) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_by_project_selector_for_test(selector, state_names, graphql_fun)
      when is_map(selector) and is_list(state_names) and is_function(graphql_fun, 2) do
    do_fetch_by_project_selector(selector, state_names, nil, graphql_fun)
  end

  @doc false
  @spec resolve_run_target_for_test(
          RunTarget.t(),
          [String.t()],
          RunTarget.RepoMarkers.t(),
          (String.t(), map() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_run_target_for_test(%RunTarget{} = target, state_names, %RunTarget.RepoMarkers{} = markers, graphql_fun)
      when is_list(state_names) and is_function(graphql_fun, 2) do
    with :ok <- validate_linear_target(target),
         :ok <- RunTarget.validate_marker_safety(target, markers),
         {:ok, issues} <- do_resolve_run_target(target, state_names, markers, nil, graphql_fun) do
      {:ok, RunTarget.apply_marker_safety(target, issues, markers)}
    end
  end

  defp context_routing(%TargetContext{run_target: run_target}) when is_map(run_target) do
    with {:ok, state_names} <- context_string_list(Map.get(run_target, "active_states", [])),
         {:ok, required_labels} <-
           context_string_list(Map.get(run_target, "required_labels", [])),
         {:ok, assignee} <- context_optional_string(Map.get(run_target, "assignee")) do
      {:ok, state_names, Enum.map(required_labels, &String.downcase/1), assignee}
    end
  end

  defp context_routing(%TargetContext{}), do: {:error, :invalid_tracker_context}

  defp context_string_list(values) when is_list(values) do
    if List.improper?(values) do
      {:error, :invalid_tracker_context}
    else
      normalized = Enum.map(values, &context_optional_string/1)

      if Enum.all?(normalized, &match?({:ok, value} when is_binary(value), &1)) do
        {:ok, normalized |> Enum.map(fn {:ok, value} -> value end) |> Enum.uniq()}
      else
        {:error, :invalid_tracker_context}
      end
    end
  end

  defp context_string_list(_values), do: {:error, :invalid_tracker_context}

  defp context_optional_string(nil), do: {:ok, nil}

  defp context_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_tracker_context}
      normalized -> {:ok, normalized}
    end
  end

  defp context_optional_string(_value), do: {:error, :invalid_tracker_context}

  defp context_assignee_filter(nil, _graphql_fun), do: {:ok, nil}

  defp context_assignee_filter(assignee, graphql_fun),
    do: build_assignee_filter(assignee, graphql_fun)

  defp context_target_issues(
         _target,
         [],
         _markers,
         _assignee_filter,
         _graphql_fun
       ),
       do: {:ok, []}

  defp context_target_issues(target, state_names, markers, assignee_filter, graphql_fun),
    do: do_resolve_run_target(target, state_names, markers, assignee_filter, graphql_fun)

  defp resolve_context_target(
         context,
         target,
         state_names,
         required_labels,
         assignee,
         opts
       ) do
    graphql_fun = fn query, variables -> graphql(context, query, variables, opts) end
    markers = %RunTarget.RepoMarkers{labels: required_labels}

    with :ok <- validate_linear_target(target),
         :ok <- RunTarget.validate_marker_safety(target, markers),
         {:ok, assignee_filter} <- context_assignee_filter(assignee, graphql_fun),
         {:ok, issues} <-
           context_target_issues(
             target,
             state_names,
             markers,
             assignee_filter,
             graphql_fun
           ) do
      resolution = RunTarget.apply_marker_safety(target, issues, markers)

      {:ok,
       %{
         resolution
         | issues:
             Enum.filter(
               resolution.issues,
               &Issue.routable?(&1, required_labels)
             )
       }}
    end
  end

  defp context_configured_target(%TargetContext{
         tracker_connection: %{"policy" => %{"kind" => kind}},
         run_target: run_target
       })
       when is_binary(kind) and is_map(run_target) do
    scope = Map.get(run_target, "scope", run_target)

    cond do
      String.downcase(String.trim(kind)) != "linear" ->
        {:error, :invalid_tracker_adapter}

      context_query_file_only?(scope) ->
        {:error, :query_file_not_materialized}

      true ->
        RunTarget.parse(scope, default_tracker: "linear")
    end
  end

  defp context_configured_target(%TargetContext{}),
    do: {:error, :invalid_tracker_context}

  defp context_query_file_only?(scope) when is_map(scope) do
    type =
      context_scope_value(scope, "type", :type) ||
        context_scope_value(scope, "kind", :kind)

    query = context_scope_value(scope, "query", :query)
    filter = context_scope_value(scope, "filter", :filter)
    query_file = context_scope_value(scope, "query_file", :query_file)

    normalized_type =
      if is_binary(type),
        do: String.downcase(String.trim(type)),
        else: nil

    normalized_type == "query" and not is_map(query) and not is_map(filter) and
      is_binary(query_file) and String.trim(query_file) != ""
  end

  defp context_query_file_only?(_scope), do: false

  defp context_scope_value(scope, string_key, atom_key),
    do: Map.get(scope, string_key) || Map.get(scope, atom_key)

  defp do_resolve_run_target(%RunTarget{type: :project, project_id: project_id}, state_names, _markers, assignee_filter, graphql_fun)
       when is_binary(project_id) do
    do_fetch_by_project_selector(%{project_id: project_id}, state_names, assignee_filter, graphql_fun)
  end

  defp do_resolve_run_target(%RunTarget{type: :project, project_slug: project_slug}, state_names, _markers, assignee_filter, graphql_fun)
       when is_binary(project_slug) do
    do_fetch_by_project_selector(%{project_slug: project_slug}, state_names, assignee_filter, graphql_fun)
  end

  defp do_resolve_run_target(%RunTarget{type: :team, team_key: team_key}, state_names, _markers, assignee_filter, graphql_fun)
       when is_binary(team_key) do
    do_fetch_by_project_selector(%{team_key: team_key}, state_names, assignee_filter, graphql_fun)
  end

  defp do_resolve_run_target(%RunTarget{type: :query} = target, state_names, markers, assignee_filter, graphql_fun) do
    target
    |> Filter.issue_filter(state_names, markers)
    |> do_fetch_by_filter(assignee_filter, graphql_fun)
  end

  defp do_resolve_run_target(%RunTarget{type: :issues, issue_ids: issue_ids}, state_names, _markers, assignee_filter, graphql_fun) do
    with {:ok, issues} <- do_fetch_issue_states(issue_ids, assignee_filter, graphql_fun) do
      {:ok, filter_issues_by_states(issues, state_names)}
    end
  end

  defp do_resolve_run_target(_target, _state_names, _markers, _assignee_filter, _graphql_fun), do: {:error, :invalid_run_target}

  defp do_fetch_by_project_selector(%{project_id: project_id}, state_names, assignee_filter, graphql_fun)
       when is_binary(project_id) and is_function(graphql_fun, 2) do
    do_fetch_by_states(@query_by_project_id, %{projectId: project_id}, state_names, assignee_filter, graphql_fun)
  end

  defp do_fetch_by_project_selector(%{project_slug: project_slug}, state_names, assignee_filter, graphql_fun)
       when is_binary(project_slug) and is_function(graphql_fun, 2) do
    project_slug
    |> project_slug_fetch_values()
    |> Enum.reduce_while({:ok, []}, fn fetch_slug, {:ok, acc} ->
      case do_fetch_by_states(
             @query_by_project_slug,
             %{projectSlug: fetch_slug},
             state_names,
             assignee_filter,
             graphql_fun
           ) do
        {:ok, issues} -> {:cont, {:ok, acc ++ issues}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.uniq_by(issues, &issue_identity/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_fetch_by_project_selector(%{team_key: team_key}, state_names, assignee_filter, graphql_fun)
       when is_binary(team_key) and is_function(graphql_fun, 2) do
    do_fetch_by_states(@query_by_team_key, %{teamKey: team_key}, state_names, assignee_filter, graphql_fun)
  end

  defp do_fetch_by_project_selector(_selector, _state_names, _assignee_filter, _graphql_fun), do: {:ok, []}

  defp do_fetch_by_states(query, variables, state_names, assignee_filter, graphql_fun) when is_function(graphql_fun, 2) do
    do_fetch_paginated_issues(
      query,
      fn after_cursor ->
        Map.merge(variables, %{
          stateNames: state_names,
          first: @issue_page_size,
          relationFirst: @issue_page_size,
          after: after_cursor
        })
      end,
      assignee_filter,
      graphql_fun
    )
  end

  defp do_fetch_by_filter(filter, assignee_filter, graphql_fun) when is_map(filter) and is_function(graphql_fun, 2) do
    do_fetch_paginated_issues(
      @query_by_filter,
      fn after_cursor ->
        %{
          filter: filter,
          first: @issue_page_size,
          relationFirst: @issue_page_size,
          after: after_cursor
        }
      end,
      assignee_filter,
      graphql_fun
    )
  end

  defp do_fetch_paginated_issues(query, variables_fun, assignee_filter, graphql_fun)
       when is_binary(query) and is_function(variables_fun, 1) and is_function(graphql_fun, 2) do
    do_fetch_paginated_issues_page(query, variables_fun, assignee_filter, nil, [], graphql_fun)
  end

  defp do_fetch_paginated_issues_page(query, variables_fun, assignee_filter, after_cursor, acc_issues, graphql_fun) do
    with {:ok, body} <- graphql_fun.(query, variables_fun.(after_cursor)),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_paginated_issues_page(query, variables_fun, assignee_filter, next_cursor, updated_acc, graphql_fun)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp issue_identity(%Issue{id: issue_id}) when is_binary(issue_id), do: {:id, issue_id}
  defp issue_identity(%Issue{identifier: identifier}) when is_binary(identifier), do: {:identifier, identifier}
  defp issue_identity(issue), do: {:term, inspect(issue)}

  defp project_slug_fetch_values(project_slug) do
    case String.trim(project_slug) do
      "" ->
        []

      slug ->
        [slug, linear_slug_id_suffix(slug)]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    end
  end

  defp linear_slug_id_suffix(project_slug) when is_binary(project_slug) do
    suffix =
      project_slug
      |> String.split("-", trim: true)
      |> List.last()

    cond do
      suffix == project_slug -> nil
      is_binary(suffix) and Regex.match?(~r/^[A-Za-z0-9]{8,}$/, suffix) -> suffix
      true -> nil
    end
  end

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)
    {linear_ids, identifiers} = split_issue_refs(batch_ids)

    with {:ok, issues} <- fetch_issue_ref_batch(linear_ids, identifiers, assignee_filter, graphql_fun) do
      updated_acc = prepend_page_issues(issues, acc_issues)
      do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index)
    end
  end

  defp split_issue_refs(issue_refs) when is_list(issue_refs) do
    Enum.reduce(issue_refs, {[], []}, fn issue_ref, {linear_ids, identifiers} ->
      if uuid?(issue_ref) do
        {[issue_ref | linear_ids], identifiers}
      else
        {linear_ids, [issue_ref | identifiers]}
      end
    end)
    |> then(fn {linear_ids, identifiers} -> {Enum.reverse(linear_ids), Enum.reverse(identifiers)} end)
  end

  defp fetch_issue_ref_batch(linear_ids, identifiers, assignee_filter, graphql_fun) do
    with {:ok, linear_issues} <- fetch_linear_ids(linear_ids, assignee_filter, graphql_fun),
         {:ok, identifier_issues} <- fetch_issue_identifiers(identifiers, assignee_filter, graphql_fun) do
      {:ok, linear_issues ++ identifier_issues}
    end
  end

  defp fetch_linear_ids([], _assignee_filter, _graphql_fun), do: {:ok, []}

  defp fetch_linear_ids(linear_ids, assignee_filter, graphql_fun) do
    case graphql_fun.(@query_by_ids, %{
           ids: linear_ids,
           first: length(linear_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} -> decode_linear_response(body, assignee_filter)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_issue_identifiers([], _assignee_filter, _graphql_fun), do: {:ok, []}

  defp fetch_issue_identifiers(identifiers, assignee_filter, graphql_fun) do
    Enum.reduce_while(identifiers, {:ok, []}, fn identifier, {:ok, acc} ->
      case fetch_issue_identifier(identifier, assignee_filter, graphql_fun) do
        {:ok, issues} -> {:cont, {:ok, acc ++ issues}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_issue_identifier(identifier, assignee_filter, graphql_fun) do
    case graphql_fun.(@query_by_issue_ref, %{id: identifier, relationFirst: @issue_page_size}) do
      {:ok, body} -> decode_linear_response(body, assignee_filter)
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id, identifier: identifier} ->
        Map.get(issue_order_index, issue_id) || Map.get(issue_order_index, identifier, fallback_index)

      _ ->
        fallback_index
    end)
  end

  defp uuid?(value) when is_binary(value) do
    Regex.match?(~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/, value)
  end

  defp filter_issues_by_states(issues, state_names) when is_list(issues) and is_list(state_names) do
    wanted_states =
      state_names
      |> Enum.map(&normalize_issue_state/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    if MapSet.size(wanted_states) == 0 do
      issues
    else
      Enum.filter(issues, fn
        %Issue{state: state} -> MapSet.member?(wanted_states, normalize_issue_state(state))
        _issue -> false
      end)
    end
  end

  defp validate_linear_target(%RunTarget{tracker: tracker}) when is_binary(tracker) do
    if String.downcase(String.trim(tracker)) == "linear" do
      :ok
    else
      {:error, {:unsupported_run_target_tracker, tracker}}
    end
  end

  defp validate_linear_target(_target), do: {:error, :invalid_run_target}

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_issue_state(_state_name), do: ""

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp graphql_error_messages(%{"errors" => errors}) when is_list(errors) do
    errors
    |> Enum.flat_map(fn
      %{"message" => message, "extensions" => %{"code" => code}} when is_binary(message) and is_binary(code) ->
        [%{code: code, message: message}]

      %{"message" => message} when is_binary(message) ->
        [%{message: message}]

      _error ->
        []
    end)
  end

  defp graphql_error_messages(_body), do: []

  defp response_error(%{status: status, body: body} = response) do
    errors = graphql_error_messages(body)

    case linear_rate_limit_details(response, errors) do
      nil -> {:error, {:linear_api_status, status, errors}}
      details -> {:error, {:linear_rate_limited, details}}
    end
  end

  defp linear_rate_limit_details(%{status: status, body: body} = response, errors) do
    if status == 400 and rate_limited_errors?(body, errors) do
      %{
        status: status,
        retry_after_ms: retry_after_ms(response),
        reset_at: rate_limit_reset_at(response),
        errors: errors
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  defp rate_limited_errors?(%{"errors" => errors}, _messages) when is_list(errors) do
    Enum.any?(errors, fn
      %{"extensions" => %{"code" => "RATELIMITED"}} -> true
      %{"extensions" => %{"code" => code}} when is_binary(code) -> String.upcase(code) == "RATELIMITED"
      _error -> false
    end)
  end

  defp rate_limited_errors?(_body, errors) when is_list(errors) do
    Enum.any?(errors, fn
      %{code: "RATELIMITED"} -> true
      %{code: code} when is_binary(code) -> String.upcase(code) == "RATELIMITED"
      _error -> false
    end)
  end

  defp retry_after_ms(response) do
    response
    |> response_header("retry-after")
    |> parse_retry_after_ms()
  end

  defp rate_limit_reset_at(response) do
    @linear_rate_limit_reset_headers
    |> Enum.find_value(&response_header(response, &1))
    |> parse_reset_at()
  end

  defp response_header(%{headers: headers}, name), do: header_value(headers, String.downcase(name))
  defp response_header(_response, _name), do: nil

  defp header_value(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == name, do: value

      _header ->
        nil
    end)
  end

  defp header_value(headers, name) when is_map(headers) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if key |> to_string() |> String.downcase() == name, do: value
    end)
  end

  defp header_value(_headers, _name), do: nil

  defp parse_retry_after_ms(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> nil
    end
  end

  defp parse_retry_after_ms(value) when is_integer(value) and value >= 0, do: value * 1_000
  defp parse_retry_after_ms(_value), do: nil

  defp parse_reset_at(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {milliseconds, ""} when milliseconds >= 0 -> parse_reset_at(milliseconds)
      _parse_error -> nil
    end
  end

  defp parse_reset_at(value) when is_integer(value) and value >= 0 do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _error -> nil
    end
  end

  defp parse_reset_at(_value), do: nil

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp non_empty_context_string?(value) when is_binary(value) do
    String.trim(value) != ""
  catch
    _kind, _reason -> false
  end

  defp context_graphql_transport(%TargetContext{
         tracker_connection: %{
           "id" => connection_id,
           "policy" => %{
             "kind" => "linear",
             "endpoint" => endpoint,
             "api_key" => token
           }
         }
       })
       when is_binary(connection_id) and is_binary(endpoint) and is_binary(token) do
    if non_empty_context_string?(connection_id) and
         non_empty_context_string?(endpoint) and
         non_empty_context_string?(token) do
      {:ok, endpoint,
       [
         {"Authorization", token},
         {"Content-Type", "application/json"}
       ]}
    else
      {:error, :invalid_tracker_context}
    end
  end

  defp context_graphql_transport(%TargetContext{}), do: {:error, :invalid_tracker_context}

  defp context_request_options(opts) do
    request_fun = Keyword.get(opts, :request_fun, &post_context_graphql_request/3)
    operation_name = Keyword.get(opts, :operation_name)

    if is_function(request_fun, 3) do
      {:ok, request_fun, operation_name}
    else
      :error
    end
  catch
    _kind, _reason -> :error
  end

  defp context_graphql_request(request_fun, endpoint, payload, headers) do
    result =
      try do
        {:returned, request_fun.(endpoint, payload, headers)}
      catch
        _kind, _reason -> :failed
      end

    case result do
      {:returned, {:ok, response}} ->
        normalize_context_response(response)

      {:returned, {:error, _reason}} ->
        {:error, :linear_request_failed}

      {:returned, _malformed} ->
        {:error, :invalid_linear_request_result}

      :failed ->
        {:error, :linear_request_failed}
    end
  end

  defp normalize_context_response(response) do
    do_normalize_context_response(response)
  catch
    _kind, _reason -> {:error, :invalid_linear_request_result}
  end

  defp do_normalize_context_response(response) when is_map(response) do
    if valid_context_response?(response),
      do: normalize_valid_context_response(response),
      else: {:error, :invalid_linear_request_result}
  end

  defp do_normalize_context_response(_response),
    do: {:error, :invalid_linear_request_result}

  defp normalize_valid_context_response(%{
         status: 200,
         body: %{"data" => data} = body
       })
       when is_map(data) and map_size(body) == 1,
       do: {:ok, body}

  defp normalize_valid_context_response(%{status: 200}),
    do: {:error, :invalid_linear_request_result}

  defp normalize_valid_context_response(response), do: context_response_error(response)

  defp valid_context_response?(response) when is_map(response) do
    safe_response_keys? =
      response
      |> Map.keys()
      |> Enum.all?(&is_atom/1)

    with true <- safe_response_keys?,
         {:ok, status} when is_integer(status) and status >= 100 and status <= 599 <-
           Map.fetch(response, :status),
         {:ok, body} when is_map(body) <- Map.fetch(response, :body),
         true <- valid_context_json?(body),
         true <- valid_context_headers_field?(response) do
      true
    else
      _ -> false
    end
  end

  defp valid_context_headers_field?(response) do
    case Map.fetch(response, :headers) do
      :error -> true
      {:ok, headers} -> valid_context_headers?(headers)
    end
  end

  defp valid_context_headers?(headers) when is_list(headers) do
    Enum.all?(headers, &valid_context_header?/1)
  end

  defp valid_context_headers?(headers) when is_map(headers) do
    Enum.all?(headers, fn {key, value} ->
      is_binary(key) and valid_context_header_value?(value)
    end)
  end

  defp valid_context_headers?(_headers), do: false

  defp valid_context_header?({key, value}) when is_binary(key),
    do: valid_context_header_value?(value)

  defp valid_context_header?(_header), do: false
  defp valid_context_header_value?(value) when is_binary(value), do: true
  defp valid_context_header_value?(value) when is_integer(value), do: true

  defp valid_context_header_value?(value) when is_list(value) do
    Enum.all?(value, &is_binary/1)
  end

  defp valid_context_header_value?(_value), do: false

  defp valid_context_json?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested_value} ->
      is_binary(key) and valid_context_json?(nested_value)
    end)
  end

  defp valid_context_json?(value) when is_list(value),
    do: Enum.all?(value, &valid_context_json?/1)

  defp valid_context_json?(value) when is_binary(value), do: true
  defp valid_context_json?(value) when is_integer(value), do: true
  defp valid_context_json?(value) when is_float(value), do: true
  defp valid_context_json?(value) when is_boolean(value), do: true
  defp valid_context_json?(nil), do: true
  defp valid_context_json?(_value), do: false

  defp context_response_error(%{body: body} = response) do
    response = context_rate_limit_response(response)

    case linear_rate_limit_details(response, graphql_error_messages(body)) do
      nil ->
        {:error, :linear_request_failed}

      details ->
        {:error,
         {:linear_rate_limited,
          Map.take(details, [
            :status,
            :retry_after_ms,
            :reset_at
          ])}}
    end
  end

  defp context_response_error(_response), do: {:error, :linear_request_failed}

  defp context_rate_limit_response(%{headers: headers} = response) when is_map(headers) do
    normalized_headers =
      Map.new(headers, fn {key, value} ->
        {key, context_rate_header_value(value)}
      end)

    %{response | headers: normalized_headers}
  end

  defp context_rate_limit_response(response), do: response

  defp context_rate_header_value([value | _rest]) when is_binary(value), do: value
  defp context_rate_header_value([]), do: nil
  defp context_rate_header_value(value), do: value

  defp post_context_graphql_request(endpoint, payload, headers) do
    Req.post(endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"data" => %{"issue" => nil}}, _assignee_filter), do: {:ok, []}

  defp decode_linear_response(%{"data" => %{"issue" => issue}}, assignee_filter) when is_map(issue) do
    issues =
      issue
      |> normalize_issue(assignee_filter)
      |> List.wrap()

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      team_id: get_in(issue, ["team", "id"]),
      team_key: get_in(issue, ["team", "key"]),
      team_name: get_in(issue, ["team", "name"]),
      project_id: get_in(issue, ["project", "id"]),
      project_slug: get_in(issue, ["project", "slugId"]),
      project_name: get_in(issue, ["project", "name"]),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp build_assignee_filter(assignee) when is_binary(assignee),
    do: build_assignee_filter(assignee, &graphql/2)

  defp build_assignee_filter(assignee, graphql_fun)
       when is_binary(assignee) and is_function(graphql_fun, 2) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter(graphql_fun)

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter(graphql_fun) when is_function(graphql_fun, 2) do
    case graphql_fun.(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
