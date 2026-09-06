defmodule SymphonyElixir.Linear.Metadata do
  @moduledoc """
  Read-only Linear metadata catalog fetcher.

  The fetcher deliberately owns no cache and performs no writes. Every catalog is
  fetched to completion before it returns, so callers never receive a partial
  success when one of the GraphQL requests fails.
  """

  @default_page_size 50
  @default_max_pages 100
  @default_max_entries 10_000
  @max_page_size 100
  @max_pages 100
  @max_entries 10_000

  @teams_query """
  query SymphonyMetadataTeams($first: Int!, $after: String) {
    teams(first: $first, after: $after) {
      nodes { id name key }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @projects_query """
  query SymphonyMetadataProjects($first: Int!, $after: String, $teamFirst: Int!, $teamAfter: String) {
    projects(first: $first, after: $after) {
      nodes {
        id
        name
        slugId
        teams(first: $teamFirst, after: $teamAfter) {
          nodes { id }
          pageInfo { hasNextPage endCursor }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @project_teams_query """
  query SymphonyMetadataProjectTeams($projectId: String!, $first: Int!, $after: String) {
    project(id: $projectId) {
      teams(first: $first, after: $after) {
        nodes { id }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @states_query """
  query SymphonyMetadataStates($first: Int!, $after: String) {
    workflowStates(first: $first, after: $after) {
      nodes { id name type team { id } }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @labels_query """
  query SymphonyMetadataLabels($first: Int!, $after: String) {
    issueLabels(first: $first, after: $after) {
      nodes { id name team { id } }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @doc """
  Fetch and normalize the complete Linear metadata catalogs for a connection.

  `request_fun` receives `(endpoint, payload, headers)` and may return either a
  Req-style `{:ok, response}` tuple or a response map. `env_fetcher` receives
  the environment variable name and defaults to `System.get_env/1`.
  """
  @spec fetch(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def fetch(connection, opts \\ [])

  @spec fetch(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def fetch(connection, opts) when is_map(connection) and is_list(opts) do
    with {:ok, limits} <- limits(opts),
         {:ok, endpoint} <- endpoint(connection),
         {:ok, api_key} <- resolve_api_key(connection, opts),
         {:ok, request_fun} <- request_fun(opts),
         headers = [{"Authorization", api_key}, {"Content-Type", "application/json"}],
         {:ok, teams} <- fetch_catalog(:teams, endpoint, headers, limits, request_fun),
         {:ok, projects} <- fetch_projects(endpoint, headers, limits, request_fun),
         {:ok, states} <- fetch_catalog(:states, endpoint, headers, limits, request_fun),
         {:ok, labels} <- fetch_catalog(:labels, endpoint, headers, limits, request_fun) do
      {:ok, %{teams: teams, projects: projects, states: states, labels: labels}}
    end
  end

  def fetch(_connection, _opts), do: {:error, :invalid_response}

  defp limits(opts) do
    if Keyword.keyword?(opts) do
      page_size = bounded_option(opts, :page_size, @default_page_size, 1, @max_page_size)
      max_pages = bounded_option(opts, :max_pages, @default_max_pages, 1, @max_pages)
      max_entries = bounded_option(opts, :max_entries, @default_max_entries, 1, @max_entries)

      if is_integer(page_size) and is_integer(max_pages) and is_integer(max_entries) do
        {:ok, %{page_size: page_size, max_pages: max_pages, max_entries: max_entries}}
      else
        {:error, :invalid_response}
      end
    else
      {:error, :invalid_response}
    end
  end

  defp bounded_option(opts, key, default, min, max) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= min -> min(value, max)
      _value -> :invalid
    end
  end

  defp endpoint(connection) do
    policy = value(connection, "policy")

    case {value(policy, "kind"), value(policy, "endpoint")} do
      {"linear", endpoint} when is_binary(endpoint) ->
        endpoint = String.trim(endpoint)

        case URI.parse(endpoint) do
          %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" ->
            {:ok, endpoint}

          _ ->
            {:error, :invalid_response}
        end

      _ ->
        {:error, :invalid_response}
    end
  rescue
    _error -> {:error, :invalid_response}
  end

  defp resolve_api_key(connection, opts) do
    policy = value(connection, "policy")
    reference = value(policy, "api_key")
    env_fetcher = Keyword.get(opts, :env_fetcher, &System.get_env/1)

    if is_function(env_fetcher, 1) do
      case env_reference(reference) do
        {:ok, variable} -> fetch_environment_secret(env_fetcher, variable)
        :error -> {:error, :authentication_failed}
      end
    else
      {:error, :invalid_response}
    end
  end

  defp env_reference(reference) when is_binary(reference) do
    cond do
      String.starts_with?(reference, "${") and String.ends_with?(reference, "}") ->
        variable = binary_part(reference, 2, byte_size(reference) - 3)
        valid_env_variable(variable)

      String.starts_with?(reference, "$") ->
        valid_env_variable(binary_part(reference, 1, byte_size(reference) - 1))

      true ->
        :error
    end
  end

  defp env_reference(_reference), do: :error

  defp valid_env_variable(variable) when is_binary(variable) do
    if Regex.match?(~r/^[A-Za-z0-9._-]+$/, variable), do: {:ok, variable}, else: :error
  end

  defp fetch_environment_secret(fetcher, variable) do
    result =
      try do
        fetcher.(variable)
      rescue
        _error -> :missing
      catch
        _kind, _reason -> :missing
      end

    value =
      case result do
        {:ok, secret} -> secret
        secret -> secret
      end

    if is_binary(value) and String.trim(value) != "" do
      {:ok, value}
    else
      {:error, :authentication_failed}
    end
  end

  defp request_fun(opts) do
    case Keyword.get(opts, :request_fun, &default_request/3) do
      fun when is_function(fun, 3) -> {:ok, fun}
      _fun -> {:error, :invalid_response}
    end
  end

  defp default_request(endpoint, payload, headers) do
    Req.post(endpoint,
      json: payload,
      headers: headers,
      retry: false,
      redirect: false,
      receive_timeout: 30_000,
      connect_options: [timeout: 30_000]
    )
  end

  defp fetch_catalog(kind, endpoint, headers, limits, request_fun) do
    {query, root} = catalog_query(kind)

    paginate(
      fn cursor ->
        variables = %{"first" => limits.page_size, "after" => cursor}

        with {:ok, body} <-
               request(request_fun, endpoint, query, operation_name(kind), variables, headers) do
          extract_connection(body, root)
        end
      end,
      limits
    )
    |> normalize_catalog(kind)
  end

  defp fetch_projects(endpoint, headers, limits, request_fun) do
    paginate(
      fn cursor ->
        variables = %{
          "first" => limits.page_size,
          "after" => cursor,
          "teamFirst" => limits.page_size,
          "teamAfter" => nil
        }

        with {:ok, page} <-
               request(request_fun, endpoint, @projects_query, "SymphonyMetadataProjects", variables, headers),
             {:ok, connection} <- extract_connection(page, "projects"),
             {:ok, projects} <- fetch_project_teams(connection.nodes, endpoint, headers, limits, request_fun) do
          {:ok, %{nodes: projects, page_info: connection.page_info}}
        end
      end,
      limits
    )
    |> normalize_catalog(:projects)
  end

  defp fetch_project_teams(nodes, endpoint, headers, limits, request_fun) when is_list(nodes) do
    if proper_list?(nodes) do
      fetch_project_teams_list(nodes, endpoint, headers, limits, request_fun)
    else
      {:error, :invalid_response}
    end
  end

  defp fetch_project_teams(_nodes, _endpoint, _headers, _limits, _request_fun), do: {:error, :invalid_response}

  defp fetch_project_teams_list(nodes, endpoint, headers, limits, request_fun) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      with {:ok, project} <- normalize_project(node),
           {:ok, team_ids} <- paginate_project_teams(node, project.id, endpoint, headers, limits, request_fun) do
        {:cont, {:ok, [Map.put(node, "team_ids", team_ids) | acc]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projects} -> {:ok, Enum.reverse(projects)}
      error -> error
    end
  end

  defp paginate_project_teams(node, project_id, endpoint, headers, limits, request_fun) do
    fetch_page = fn cursor ->
      variables = %{"projectId" => project_id, "first" => limits.page_size, "after" => cursor}

      with {:ok, body} <-
             request(request_fun, endpoint, @project_teams_query, "SymphonyMetadataProjectTeams", variables, headers) do
        extract_project_teams(body)
      end
    end

    with {:ok, initial} <- parse_connection(value(node, "teams")),
         {:ok, nodes} <- paginate(fetch_page, limits, initial) do
      normalize_team_ids(nodes)
    end
  end

  defp extract_project_teams(body) do
    with {:ok, data} <- data(body),
         project when is_map(project) <- value(data, "project"),
         {:ok, connection} <- parse_connection(value(project, "teams")) do
      {:ok, connection}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp paginate(fetch_page, limits), do: paginate(fetch_page, limits, :fetch)

  defp paginate(fetch_page, limits, :fetch) do
    case fetch_page.(nil) do
      {:ok, %{nodes: page_nodes, page_info: page_info}} when is_list(page_nodes) ->
        if proper_list?(page_nodes) do
          start_pagination(fetch_page, limits, 1, page_nodes, page_info)
        else
          {:error, :invalid_response}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp paginate(fetch_page, limits, %{nodes: initial_nodes, page_info: page_info})
       when is_list(initial_nodes) do
    if proper_list?(initial_nodes) do
      start_pagination(fetch_page, limits, 1, initial_nodes, page_info)
    else
      {:error, :invalid_response}
    end
  end

  defp paginate(_fetch_page, _limits, _initial), do: {:error, :invalid_response}

  defp start_pagination(fetch_page, limits, pages, page_nodes, page_info) do
    count = length(page_nodes)

    if count > limits.max_entries do
      {:error, :catalog_limit}
    else
      paginate_pages(
        fetch_page,
        limits,
        pages,
        Enum.reverse(page_nodes),
        count,
        next_cursor(page_info),
        MapSet.new()
      )
    end
  end

  defp paginate_pages(
         _fetch_page,
         _limits,
         _pages,
         _nodes,
         _count,
         :malformed,
         _seen
       ),
       do: {:error, :invalid_response}

  defp paginate_pages(
         _fetch_page,
         %{max_pages: max_pages},
         pages,
         _nodes,
         _count,
         cursor,
         _seen
       )
       when pages >= max_pages and not is_nil(cursor),
       do: {:error, :catalog_limit}

  defp paginate_pages(_fetch_page, _limits, _pages, nodes, _count, nil, _seen),
    do: {:ok, Enum.reverse(nodes)}

  defp paginate_pages(fetch_page, limits, pages, nodes, count, cursor, seen_cursors) do
    with false <- MapSet.member?(seen_cursors, cursor),
         {:ok, %{nodes: page_nodes, page_info: page_info}} <- fetch_page.(cursor) do
      new_count = count + length(page_nodes)

      if new_count > limits.max_entries do
        {:error, :catalog_limit}
      else
        paginate_pages(
          fetch_page,
          limits,
          pages + 1,
          Enum.reverse(page_nodes, nodes),
          new_count,
          next_cursor(page_info),
          MapSet.put(seen_cursors, cursor)
        )
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  defp next_cursor(%{has_next_page: false}), do: nil
  defp next_cursor(%{has_next_page: true, end_cursor: cursor}) when is_binary(cursor) and cursor != "", do: cursor
  defp next_cursor(_page_info), do: :malformed

  defp normalize_catalog({:error, :malformed}, _kind), do: {:error, :invalid_response}
  defp normalize_catalog({:error, reason}, _kind), do: {:error, reason}

  defp normalize_catalog({:ok, nodes}, :teams) do
    deduplicate(nodes, &normalize_team/1)
  end

  defp normalize_catalog({:ok, nodes}, :projects) do
    deduplicate(nodes, &normalize_project/1)
  end

  defp normalize_catalog({:ok, nodes}, :states) do
    deduplicate(nodes, &normalize_state/1)
  end

  defp normalize_catalog({:ok, nodes}, :labels) do
    deduplicate(nodes, &normalize_label/1)
  end

  defp deduplicate(nodes, normalizer) do
    Enum.reduce_while(nodes, {:ok, {[], MapSet.new()}}, fn node, {:ok, {acc, ids}} = unchanged ->
      with {:ok, normalized} <- normalizer.(node),
           false <- MapSet.member?(ids, normalized.id) do
        {:cont, {:ok, {[normalized | acc], MapSet.put(ids, normalized.id)}}}
      else
        true -> {:cont, unchanged}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, {normalized, _ids}} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} -> {:error, :invalid_response}
    end
  end

  defp normalize_team(node) do
    with {:ok, id} <- required_text(node, "id"),
         {:ok, name} <- required_text(node, "name"),
         {:ok, key} <- required_text(node, "key") do
      {:ok, %{id: id, name: name, key: key}}
    end
  end

  defp normalize_project(node) do
    with {:ok, id} <- required_text(node, "id"),
         {:ok, name} <- required_text(node, "name"),
         {:ok, slug_id} <- required_text(node, "slugId"),
         {:ok, team_ids} <- project_team_ids(node) do
      {:ok, %{id: id, name: name, slug_id: slug_id, team_ids: team_ids}}
    end
  end

  defp project_team_ids(node) when is_map(node) do
    cond do
      Map.has_key?(node, "team_ids") -> normalize_existing_team_ids(Map.get(node, "team_ids"))
      Map.has_key?(node, :team_ids) -> normalize_existing_team_ids(Map.get(node, :team_ids))
      true -> {:ok, []}
    end
  end

  defp project_team_ids(_node), do: {:error, :invalid_response}

  defp normalize_existing_team_ids(team_ids) when is_list(team_ids) do
    if proper_list?(team_ids) and Enum.all?(team_ids, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, Enum.uniq(Enum.map(team_ids, &String.trim/1))}
    else
      {:error, :invalid_response}
    end
  end

  defp normalize_existing_team_ids(_team_ids), do: {:error, :invalid_response}

  defp normalize_state(node) do
    with {:ok, id} <- required_text(node, "id"),
         {:ok, name} <- required_text(node, "name"),
         {:ok, type} <- required_text(node, "type"),
         team when is_map(team) <- value(node, "team"),
         {:ok, team_id} <- required_text(team, "id") do
      {:ok, %{id: id, name: name, type: type, team_id: team_id}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_label(node) do
    with {:ok, id} <- required_text(node, "id"),
         {:ok, name} <- required_text(node, "name"),
         {:ok, team_id} <- optional_team_id(node) do
      {:ok, %{id: id, name: name, team_id: team_id}}
    end
  end

  defp normalize_team_ids(nodes) do
    Enum.reduce_while(nodes, {:ok, {[], MapSet.new()}}, fn node, {:ok, {ids, seen}} = unchanged ->
      with {:ok, id} <- required_text(node, "id"),
           false <- MapSet.member?(seen, id) do
        {:cont, {:ok, {[id | ids], MapSet.put(seen, id)}}}
      else
        true -> {:cont, unchanged}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, {ids, _seen}} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp optional_team_id(node) do
    case value(node, "team") do
      nil -> {:ok, nil}
      team when is_map(team) -> required_text(team, "id")
      _ -> {:error, :invalid_response}
    end
  end

  defp required_text(map, key) when is_map(map) do
    case value(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :invalid_response}, else: {:ok, value}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp required_text(_map, _key), do: {:error, :invalid_response}

  defp catalog_query(:teams), do: {@teams_query, "teams"}
  defp catalog_query(:states), do: {@states_query, "workflowStates"}
  defp catalog_query(:labels), do: {@labels_query, "issueLabels"}

  defp operation_name(:teams), do: "SymphonyMetadataTeams"
  defp operation_name(:states), do: "SymphonyMetadataStates"
  defp operation_name(:labels), do: "SymphonyMetadataLabels"

  defp request(fun, endpoint, query, operation_name, variables, headers) do
    payload = %{"query" => query, "variables" => variables, "operationName" => operation_name}

    result =
      try do
        fun.(endpoint, payload, headers)
      rescue
        _error -> {:error, :offline}
      catch
        _kind, _reason -> {:error, :offline}
      end

    case result do
      {:error, _reason} -> {:error, :offline}
      {:ok, response} -> classify_response(response)
      response when is_map(response) -> classify_response(response)
      _other -> {:error, :invalid_response}
    end
  end

  defp classify_response(response) when is_map(response) do
    status = value(response, "status")
    body = value(response, "body")

    cond do
      status in [401, 403] -> {:error, :authentication_failed}
      status == 429 -> {:error, :rate_limited}
      status == 408 or (is_integer(status) and status in 500..599) -> {:error, :offline}
      not (is_integer(status) and status in 200..299) -> {:error, :invalid_response}
      true -> classify_body(body)
    end
  end

  defp classify_response(_response), do: {:error, :invalid_response}

  defp classify_body(body) when is_map(body) do
    errors = value(body, "errors")

    cond do
      is_list(errors) and proper_list?(errors) and errors != [] ->
        {:error, classify_graphql_errors(errors)}

      not is_nil(errors) ->
        {:error, :invalid_response}

      true ->
        {:ok, body}
    end
  end

  defp classify_body(_body), do: {:error, :invalid_response}

  defp classify_graphql_errors(errors) do
    codes =
      Enum.flat_map(errors, fn error ->
        code = value(value(error, "extensions"), "code")
        if is_binary(code), do: [String.upcase(code)], else: []
      end)

    messages =
      Enum.flat_map(errors, fn error ->
        message = value(error, "message")
        if is_binary(message), do: [String.downcase(message)], else: []
      end)

    cond do
      Enum.any?(codes, &(&1 in ~w(UNAUTHENTICATED UNAUTHORIZED FORBIDDEN AUTHENTICATION_FAILED INVALID_API_KEY))) ->
        :authentication_failed

      Enum.any?(codes, &(&1 in ~w(RATELIMITED RATE_LIMITED TOO_MANY_REQUESTS))) ->
        :rate_limited

      Enum.any?(messages, &String.contains?(&1, ["rate limit", "ratelimit", "too many request"])) ->
        :rate_limited

      Enum.any?(messages, &String.contains?(&1, ["unauthoriz", "forbidden", "authentication", "api key"])) ->
        :authentication_failed

      true ->
        :invalid_response
    end
  end

  defp parse_connection(connection) when is_map(connection) do
    nodes = value(connection, "nodes")
    page_info = value(connection, "pageInfo")

    with true <- is_list(nodes) and proper_list?(nodes),
         {:ok, page_info} <- parse_page_info(page_info) do
      {:ok, %{nodes: nodes, page_info: page_info}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp parse_connection(_connection), do: {:error, :invalid_response}

  defp parse_page_info(page_info) when is_map(page_info) do
    has_next = value(page_info, "hasNextPage")
    end_cursor = value(page_info, "endCursor")

    cond do
      has_next === false and (is_nil(end_cursor) or is_binary(end_cursor)) ->
        {:ok, %{has_next_page: false, end_cursor: end_cursor}}

      has_next === true and is_binary(end_cursor) and String.trim(end_cursor) != "" ->
        {:ok, %{has_next_page: true, end_cursor: end_cursor}}

      true ->
        {:error, :invalid_response}
    end
  end

  defp parse_page_info(_page_info), do: {:error, :invalid_response}

  defp extract_connection(body, key) do
    with {:ok, data} <- data(body), do: parse_connection(value(data, key))
  end

  defp data(body) when is_map(body) do
    case value(body, "data") do
      data when is_map(data) -> {:ok, data}
      _ -> {:error, :invalid_response}
    end
  end

  defp data(_body), do: {:error, :invalid_response}

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_value), do: false

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  defp value(_map, _key), do: nil
end
