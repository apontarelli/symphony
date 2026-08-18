defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.{Client, Issue}
  alias SymphonyElixir.{RunTarget, TargetContext}

  @resolution_map_size map_size(%RunTarget.Resolution{})
  @issue_map_size map_size(%Issue{})
  @datetime_map_size map_size(~U[2000-01-01 00:00:00Z])

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec resolve_candidate_issues(SymphonyElixir.RunTarget.t() | nil) ::
          {:ok, SymphonyElixir.RunTarget.Resolution.t()} | {:error, term()}
  def resolve_candidate_issues(target), do: client_module().resolve_run_target(target)

  @spec resolve_candidate_issues(TargetContext.t(), RunTarget.t()) ::
          {:ok, RunTarget.Resolution.t()} | {:error, term()}
  def resolve_candidate_issues(%TargetContext{} = context, %RunTarget{} = target) do
    context_client_call(:resolve_run_target, [context, target], fn
      {:ok, resolution} ->
        if valid_context_resolution?(resolution, target) do
          {:ok, resolution}
        else
          {:error, :invalid_tracker_adapter_result}
        end

      result ->
        context_error_result(result)
    end)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_states(TargetContext.t(), [String.t()]) ::
          {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(%TargetContext{} = context, states) when is_list(states) do
    context_client_call(:fetch_issues_by_states, [context, states], fn
      {:ok, issues} when is_list(issues) ->
        if valid_issue_list?(issues), do: {:ok, issues}, else: context_error_result(:malformed)

      result ->
        context_error_result(result)
    end)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec fetch_issue_states_by_ids(TargetContext.t(), [String.t()]) ::
          {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(%TargetContext{} = context, issue_ids)
      when is_list(issue_ids) do
    context_client_call(:fetch_issue_states_by_ids, [context, issue_ids], fn
      {:ok, issues} when is_list(issues) ->
        if valid_issue_list?(issues), do: {:ok, issues}, else: context_error_result(:malformed)

      result ->
        context_error_result(result)
    end)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec create_comment(TargetContext.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def create_comment(%TargetContext{} = context, issue_id, body)
      when is_binary(issue_id) and is_binary(body) do
    context_client_call(
      :graphql,
      [context, @create_comment_mutation, %{issueId: issue_id, body: body}, []],
      fn
        {:ok, response} when is_map(response) ->
          if get_in(response, ["data", "commentCreate", "success"]) == true,
            do: :ok,
            else: {:error, :comment_create_failed}

        result ->
          context_error_result(result)
      end
    )
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec update_issue_state(TargetContext.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def update_issue_state(%TargetContext{} = context, issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(context, issue_id, state_name) do
      context_client_call(
        :graphql,
        [context, @update_state_mutation, %{issueId: issue_id, stateId: state_id}, []],
        &normalize_issue_update_result/1
      )
    end
  end

  defp valid_context_resolution?(
         %RunTarget.Resolution{
           target: resolution_target,
           issues: issues,
           warnings: warnings,
           ordering: ordering
         } = resolution,
         target
       ) do
    map_size(resolution) == @resolution_map_size and
      resolution_target === target and
      valid_issue_list?(issues) and
      valid_warning_list?(warnings) and
      ordering === expected_resolution_ordering(target)
  end

  defp valid_context_resolution?(_resolution, _target), do: false

  defp valid_issue_list?(issues) when is_list(issues) do
    Enum.all?(issues, &valid_issue?/1)
  end

  defp valid_issue_list?(_issues), do: false

  defp valid_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           description: description,
           priority: priority,
           state: state,
           branch_name: branch_name,
           url: url,
           assignee_id: assignee_id,
           team_id: team_id,
           team_key: team_key,
           team_name: team_name,
           project_id: project_id,
           project_slug: project_slug,
           project_name: project_name,
           blocked_by: blocked_by,
           labels: labels,
           assigned_to_worker: assigned_to_worker,
           created_at: created_at,
           updated_at: updated_at
         } = issue
       ) do
    map_size(issue) == @issue_map_size and
      valid_issue_identity_fields?(id, identifier, title, description, priority, state) and
      valid_issue_assignment_fields?(
        branch_name,
        url,
        assignee_id,
        team_id,
        team_key,
        team_name
      ) and
      valid_issue_project_fields?(project_id, project_slug, project_name) and
      valid_issue_nested_fields?(
        blocked_by,
        labels,
        assigned_to_worker,
        created_at,
        updated_at
      )
  end

  defp valid_issue?(_issue), do: false

  defp valid_issue_identity_fields?(id, identifier, title, description, priority, state) do
    binary_or_nil?(id) and
      binary_or_nil?(identifier) and
      binary_or_nil?(title) and
      binary_or_nil?(description) and
      integer_or_nil?(priority) and
      binary_or_nil?(state)
  end

  defp valid_issue_assignment_fields?(
         branch_name,
         url,
         assignee_id,
         team_id,
         team_key,
         team_name
       ) do
    binary_or_nil?(branch_name) and
      binary_or_nil?(url) and
      binary_or_nil?(assignee_id) and
      binary_or_nil?(team_id) and
      binary_or_nil?(team_key) and
      binary_or_nil?(team_name)
  end

  defp valid_issue_project_fields?(project_id, project_slug, project_name) do
    binary_or_nil?(project_id) and
      binary_or_nil?(project_slug) and
      binary_or_nil?(project_name)
  end

  defp valid_issue_nested_fields?(
         blocked_by,
         labels,
         assigned_to_worker,
         created_at,
         updated_at
       ) do
    valid_blocker_list?(blocked_by) and
      valid_string_list?(labels) and
      is_boolean(assigned_to_worker) and
      valid_datetime_or_nil?(created_at) and
      valid_datetime_or_nil?(updated_at)
  end

  defp valid_string_list?([]), do: true

  defp valid_string_list?([value | rest]) when is_binary(value),
    do: valid_string_list?(rest)

  defp valid_string_list?(_values), do: false

  defp valid_blocker_list?([]), do: true

  defp valid_blocker_list?([blocker | rest]) do
    valid_blocker?(blocker) and valid_blocker_list?(rest)
  end

  defp valid_blocker_list?(_blockers), do: false

  defp valid_blocker?(%{id: id, identifier: identifier, state: state} = blocker) do
    not is_struct(blocker) and
      map_size(blocker) == 3 and
      binary_or_nil?(id) and
      binary_or_nil?(identifier) and
      binary_or_nil?(state)
  end

  defp valid_blocker?(_blocker), do: false

  defp valid_datetime_or_nil?(nil), do: true

  defp valid_datetime_or_nil?(
         %DateTime{
           calendar: Calendar.ISO,
           year: year,
           month: month,
           day: day,
           hour: hour,
           minute: minute,
           second: second,
           microsecond: {microsecond, precision},
           time_zone: "Etc/UTC",
           zone_abbr: "UTC",
           utc_offset: 0,
           std_offset: 0
         } = datetime
       ) do
    map_size(datetime) == @datetime_map_size and
      valid_date_fields?(year, month, day) and
      valid_time_fields?(hour, minute, second, microsecond, precision)
  end

  defp valid_datetime_or_nil?(_datetime), do: false

  defp valid_date_fields?(year, month, day)
       when is_integer(year) and is_integer(month) and is_integer(day) do
    match?({:ok, _date}, Date.new(year, month, day))
  end

  defp valid_date_fields?(_year, _month, _day), do: false

  defp valid_time_fields?(hour, minute, second, microsecond, precision)
       when is_integer(hour) and is_integer(minute) and is_integer(second) and
              is_integer(microsecond) and is_integer(precision) do
    canonical_microsecond?(microsecond, precision) and
      match?({:ok, _time}, Time.new(hour, minute, second, {microsecond, precision}))
  end

  defp valid_time_fields?(_hour, _minute, _second, _microsecond, _precision), do: false

  defp canonical_microsecond?(microsecond, precision) do
    precision in 0..6 and
      microsecond in 0..999_999 and
      rem(microsecond, Integer.pow(10, 6 - precision)) == 0
  end

  defp valid_warning_list?(warnings) when is_list(warnings) do
    Enum.all?(warnings, &valid_warning?/1)
  end

  defp valid_warning_list?(_warnings), do: false

  defp valid_warning?(warning) when is_map(warning) do
    allowed_keys = [:code, :issue_id, :issue_identifier, :message]

    Map.has_key?(warning, :code) and
      Map.keys(warning) -- allowed_keys == [] and
      is_atom(Map.get(warning, :code)) and
      valid_optional_warning_field?(warning, :issue_id, &binary_or_nil?/1) and
      valid_optional_warning_field?(warning, :issue_identifier, &binary_or_nil?/1) and
      valid_optional_warning_field?(warning, :message, &is_binary/1)
  end

  defp valid_warning?(_warning), do: false

  defp valid_optional_warning_field?(warning, key, validator) do
    not Map.has_key?(warning, key) or validator.(Map.get(warning, key))
  end

  defp binary_or_nil?(value), do: is_binary(value) or is_nil(value)
  defp integer_or_nil?(value), do: is_integer(value) or is_nil(value)

  defp expected_resolution_ordering(%RunTarget{type: :issues}), do: :target
  defp expected_resolution_ordering(%RunTarget{}), do: :priority

  defp context_client_call(function, arguments, normalize_result) do
    client = client_module()

    cond do
      not is_atom(client) ->
        {:error, :invalid_tracker_adapter}

      not Code.ensure_loaded?(client) or
          not function_exported?(client, function, length(arguments)) ->
        {:error, :invalid_tracker_adapter}

      true ->
        result =
          try do
            {:returned, apply(client, function, arguments)}
          catch
            _kind, _reason -> :failed
          end

        case result do
          {:returned, returned} -> normalize_context_result(normalize_result, returned)
          :failed -> {:error, :linear_request_failed}
        end
    end
  end

  defp normalize_context_result(normalize_result, returned) do
    normalize_result.(returned)
  catch
    _kind, _reason -> {:error, :invalid_tracker_adapter_result}
  end

  defp context_error_result({:error, {:linear_rate_limited, details}})
       when is_map(details),
       do: {:error, {:linear_rate_limited, context_rate_limit_details(details)}}

  defp context_error_result({:error, reason})
       when reason in [
              :invalid_run_target,
              :invalid_tracker_context,
              :invalid_tracker_adapter,
              :invalid_tracker_adapter_result,
              :invalid_linear_request_result,
              :linear_request_failed,
              :missing_linear_viewer_identity,
              :run_target_requires_issue_markers
            ],
       do: {:error, reason}

  defp context_error_result(_result), do: {:error, :invalid_tracker_adapter_result}

  defp normalize_issue_update_result({:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}),
    do: :ok

  defp normalize_issue_update_result({:ok, response}) when is_map(response),
    do: {:error, :issue_update_failed}

  defp normalize_issue_update_result(result), do: context_error_result(result)

  defp context_rate_limit_details(details) do
    Enum.reduce(details, %{}, fn
      {:status, status}, safe when is_integer(status) ->
        Map.put(safe, :status, status)

      {:retry_after_ms, retry_after_ms}, safe
      when is_integer(retry_after_ms) and retry_after_ms >= 0 ->
        Map.put(safe, :retry_after_ms, retry_after_ms)

      {:reset_at, reset_at}, safe when is_binary(reset_at) ->
        case DateTime.from_iso8601(reset_at) do
          {:ok, _datetime, _offset} -> Map.put(safe, :reset_at, reset_at)
          {:error, _reason} -> safe
        end

      _unsafe, safe ->
        safe
    end)
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp resolve_state_id(%TargetContext{} = context, issue_id, state_name) do
    context_client_call(
      :graphql,
      [context, @state_lookup_query, %{issueId: issue_id, stateName: state_name}, []],
      fn
        {:ok, response} when is_map(response) ->
          case get_in(response, [
                 "data",
                 "issue",
                 "team",
                 "states",
                 "nodes",
                 Access.at(0),
                 "id"
               ]) do
            state_id when is_binary(state_id) -> {:ok, state_id}
            _missing -> {:error, :state_not_found}
          end

        result ->
          context_error_result(result)
      end
    )
  end
end
