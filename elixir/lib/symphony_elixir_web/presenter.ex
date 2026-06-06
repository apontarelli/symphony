defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}
  alias SymphonyElixir.Config.ProfileBindings

  @stale_after_seconds 5 * 60
  @default_profile "default"
  @default_pr_target "main"

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at_datetime = DateTime.utc_now() |> DateTime.truncate(:second)
    generated_at = DateTime.to_iso8601(generated_at_datetime)

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        bound_projects = bound_project_payloads(snapshot)
        default_project_slug = default_project_slug(bound_projects)
        projects_by_slug = projects_by_slug(bound_projects)
        running = Enum.map(snapshot.running, &running_entry_payload(&1, projects_by_slug, default_project_slug))
        retrying = Enum.map(snapshot.retrying, &retry_entry_payload(&1, projects_by_slug, default_project_slug))
        blocked = Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload(&1, projects_by_slug, default_project_slug))
        work_errors = work_error_payloads(retrying)
        stale_warnings = stale_warning_payloads(running, generated_at_datetime)
        config_warnings = config_warning_payloads()
        project_status_projects = project_status_projects(bound_projects, running, retrying)

        %{
          generated_at: generated_at,
          counts: %{
            running: length(running),
            retrying: length(retrying),
            blocked: length(blocked),
            work_errors: length(work_errors),
            config_warnings: length(config_warnings),
            stale_warnings: length(stale_warnings)
          },
          project_statuses:
            project_status_payloads(
              project_status_projects,
              running,
              retrying,
              work_errors,
              config_warnings,
              stale_warnings
            ),
          work_errors: work_errors,
          config_warnings: config_warnings,
          stale_warnings: stale_warnings,
          running: running,
          retrying: retrying,
          blocked: blocked,
          token_hotspot: token_hotspot_payload(running),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits,
          rate_limits_available: meaningful_rate_limits?(snapshot.rate_limits)
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        bound_projects = bound_project_payloads(snapshot)
        default_project_slug = default_project_slug(bound_projects)
        projects_by_slug = projects_by_slug(bound_projects)

        running =
          snapshot.running
          |> Enum.find(&(&1.identifier == issue_identifier))
          |> maybe_put_project_defaults(projects_by_slug, default_project_slug)

        retry =
          snapshot.retrying
          |> Enum.find(&(&1.identifier == issue_identifier))
          |> maybe_put_project_defaults(projects_by_slug, default_project_slug)

        blocked =
          Map.get(snapshot, :blocked, [])
          |> Enum.find(&(&1.identifier == issue_identifier))
          |> maybe_put_project_defaults(projects_by_slug, default_project_slug)

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp maybe_put_project_defaults(nil, _projects_by_slug, _default_project_slug), do: nil

  defp maybe_put_project_defaults(entry, projects_by_slug, default_project_slug) when is_map(entry) do
    project_slug = entry_project_slug(entry, default_project_slug)
    project = Map.get(projects_by_slug, project_slug, %{})

    entry
    |> Map.put(:project_slug, project_slug)
    |> Map.put(:profile, entry_project_profile(entry, project))
    |> Map.put(:pr_target, entry_project_pr_target(entry, project))
  end

  defp running_entry_payload(entry, projects_by_slug, default_project_slug) do
    project_slug = entry_project_slug(entry, default_project_slug)
    project = Map.get(projects_by_slug, project_slug, %{})

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      project_slug: project_slug,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      target: Map.get(entry, :target),
      policy_ref: Map.get(entry, :policy_ref),
      policy: Map.get(entry, :policy),
      session_id: entry.session_id,
      profile: entry_project_profile(entry, project),
      pr_target: entry_project_pr_target(entry, project),
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
    |> put_if_present(:last_progress_at, iso8601(Map.get(entry, :last_codex_progress_timestamp)))
    |> put_if_present(:last_error_signature, Map.get(entry, :last_codex_error_signature))
  end

  defp retry_entry_payload(entry, projects_by_slug, default_project_slug) do
    project_slug = entry_project_slug(entry, default_project_slug)
    project = Map.get(projects_by_slug, project_slug, %{})

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      project_slug: project_slug,
      attempt: entry.attempt,
      profile: entry_project_profile(entry, project),
      pr_target: entry_project_pr_target(entry, project),
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      target: Map.get(entry, :target),
      policy_ref: Map.get(entry, :policy_ref),
      policy: Map.get(entry, :policy)
    }
    |> put_if_present(:session_id, Map.get(entry, :session_id))
    |> put_if_present(:last_error_signature, Map.get(entry, :last_error_signature))
  end

  defp blocked_entry_payload(entry, projects_by_slug, default_project_slug) do
    project_slug = entry_project_slug(entry, default_project_slug)
    project = Map.get(projects_by_slug, project_slug, %{})

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      project_slug: project_slug,
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      target: Map.get(entry, :target),
      policy_ref: Map.get(entry, :policy_ref),
      policy: Map.get(entry, :policy),
      session_id: entry.session_id,
      profile: entry_project_profile(entry, project),
      pr_target: entry_project_pr_target(entry, project),
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      target: Map.get(running, :target),
      policy_ref: Map.get(running, :policy_ref),
      policy: Map.get(running, :policy),
      session_id: running.session_id,
      project_slug: Map.get(running, :project_slug),
      profile: Map.get(running, :profile, @default_profile),
      pr_target: Map.get(running, :pr_target, @default_pr_target),
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
    |> put_if_present(:last_progress_at, iso8601(Map.get(running, :last_codex_progress_timestamp)))
    |> put_if_present(:last_error_signature, Map.get(running, :last_codex_error_signature))
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      project_slug: Map.get(retry, :project_slug),
      profile: Map.get(retry, :profile, @default_profile),
      pr_target: Map.get(retry, :pr_target, @default_pr_target),
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      target: Map.get(retry, :target),
      policy_ref: Map.get(retry, :policy_ref),
      policy: Map.get(retry, :policy)
    }
    |> put_if_present(:session_id, Map.get(retry, :session_id))
    |> put_if_present(:last_error_signature, Map.get(retry, :last_error_signature))
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      target: Map.get(blocked, :target),
      policy_ref: Map.get(blocked, :policy_ref),
      policy: Map.get(blocked, :policy),
      session_id: blocked.session_id,
      project_slug: Map.get(blocked, :project_slug),
      profile: Map.get(blocked, :profile, @default_profile),
      pr_target: Map.get(blocked, :pr_target, @default_pr_target),
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
  end

  defp bound_project_payloads(snapshot) do
    snapshot
    |> snapshot_bound_project_payloads()
    |> case do
      [] -> configured_bound_project_payloads()
      projects -> projects
    end
  end

  defp snapshot_bound_project_payloads(snapshot) when is_map(snapshot) do
    snapshot
    |> Map.get(:bound_projects, Map.get(snapshot, :project_bindings, []))
    |> List.wrap()
    |> Enum.flat_map(&normalize_bound_project/1)
  end

  defp configured_bound_project_payloads do
    case Config.settings() do
      {:ok, settings} ->
        case settings.tracker.project_slug do
          slug when is_binary(slug) and slug != "" ->
            [
              %{
                id: slug,
                name: human_project_name(slug) || slug,
                slug: slug,
                url: linear_project_url(slug),
                profile: @default_profile,
                pr_target: @default_pr_target
              }
            ]

          _ ->
            []
        end

      {:error, _reason} ->
        []
    end
  end

  defp normalize_bound_project(project) when is_map(project) do
    case bound_project_slug(project) do
      slug when is_binary(slug) and slug != "" -> [bound_project_payload(project, slug)]
      _ -> []
    end
  end

  defp normalize_bound_project(_project), do: []

  defp bound_project_slug(project) do
    project_value(project, :project_slug) || project_value(project, :slug) || project_value(project, :id)
  end

  defp bound_project_payload(project, slug) do
    %{
      id: slug,
      name: project_name(project, slug),
      slug: slug,
      url: project_value(project, :url) || linear_project_url(slug),
      profile: project_value(project, :profile) || @default_profile,
      pr_target: project_value(project, :pr_target) || project_value(project, :target) || @default_pr_target
    }
  end

  defp project_value(project, key) when is_map(project) and is_atom(key) do
    Map.get(project, key) || Map.get(project, Atom.to_string(key))
  end

  defp project_name(project, slug) do
    raw_name = normalized_string(project_value(project, :name))
    slug_name = human_project_name(slug)

    cond do
      is_nil(raw_name) -> slug_name || slug
      raw_name in [project_value(project, :id), slug] or opaque_project_name?(raw_name) -> slug_name || raw_name
      true -> raw_name
    end
  end

  defp opaque_project_name?(value) when is_binary(value), do: Regex.match?(~r/^[0-9a-f-]{8,}$/i, value)
  defp opaque_project_name?(_value), do: false

  defp normalized_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_string(_value), do: nil

  defp human_project_name(value) when is_binary(value) do
    value
    |> String.replace(~r/-[0-9a-f]{8,}$/i, "")
    |> String.replace(["-", "_"], " ")
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> String.capitalize(normalized)
    end
  end

  defp default_project_slug([%{slug: slug} | _projects]), do: slug
  defp default_project_slug(_projects), do: nil

  defp projects_by_slug(projects) do
    Map.new(projects, fn project -> {project.slug, project} end)
  end

  defp entry_project_slug(entry, default_project_slug) do
    project_value(entry, :project_slug) || project_value(entry, :slug) || default_project_slug
  end

  defp entry_project_profile(entry, project) do
    project_value(entry, :profile) || project_value(project, :profile) || @default_profile
  end

  defp entry_project_pr_target(entry, project) do
    project_value(entry, :pr_target) || project_value(project, :pr_target) ||
      project_value(project, :target) || project_value(entry, :target) || @default_pr_target
  end

  defp project_status_projects([], [], []), do: []

  defp project_status_projects(bound_projects, running, retrying) do
    bound_slugs = MapSet.new(Enum.map(bound_projects, & &1.slug))

    entries = running ++ retrying

    runtime_projects =
      entries
      |> Enum.map(&Map.get(&1, :project_slug))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(bound_slugs, &1))
      |> Enum.map(fn slug ->
        runtime_project_payload(slug, Enum.find(entries, &(Map.get(&1, :project_slug) == slug)))
      end)

    bound_projects ++ runtime_projects
  end

  defp runtime_project_payload(nil, entry) do
    %{
      id: "runtime",
      name: "Runtime",
      slug: nil,
      url: nil,
      profile: project_value(entry || %{}, :profile) || @default_profile,
      pr_target: project_value(entry || %{}, :pr_target) || @default_pr_target
    }
  end

  defp runtime_project_payload(slug, entry) do
    %{
      id: slug,
      name: slug,
      slug: slug,
      url: linear_project_url(slug),
      profile: project_value(entry || %{}, :profile) || @default_profile,
      pr_target: project_value(entry || %{}, :pr_target) || @default_pr_target
    }
  end

  defp project_status_payloads([], [], [], [], config_warnings, []) when config_warnings != [] do
    [
      %{
        id: "configuration",
        project: "Configuration",
        project_slug: nil,
        project_url: nil,
        statuses: ["config_warning"],
        running: 0,
        retrying: 0,
        errors: 0,
        stale_warnings: 0,
        config_warnings: length(config_warnings),
        profile: @default_profile,
        pr_target: @default_pr_target,
        last_activity_at: nil,
        actions: []
      }
    ]
  end

  defp project_status_payloads([], running, retrying, work_errors, config_warnings, stale_warnings) do
    project_status_payloads(
      [
        %{
          id: "runtime",
          name: "Runtime",
          slug: nil,
          url: nil,
          profile: @default_profile,
          pr_target: @default_pr_target
        }
      ],
      running,
      retrying,
      work_errors,
      config_warnings,
      stale_warnings
    )
  end

  defp project_status_payloads(bound_projects, running, retrying, work_errors, config_warnings, stale_warnings) do
    Enum.map(bound_projects, fn project ->
      project_running = Enum.filter(running, &entry_in_project?(&1, project.slug))
      project_retrying = Enum.filter(retrying, &entry_in_project?(&1, project.slug))
      project_errors = Enum.filter(work_errors, &entry_in_project?(&1, project.slug))
      project_stale_warnings = Enum.filter(stale_warnings, &entry_in_project?(&1, project.slug))
      running_count = length(project_running)
      retrying_count = length(project_retrying)
      error_count = length(project_errors)
      stale_count = length(project_stale_warnings)
      config_warning_count = length(config_warnings)

      %{
        id: project.id,
        project: project.name,
        project_slug: project.slug,
        project_url: project.url,
        statuses: project_statuses(running_count, retrying_count, error_count, stale_count, config_warning_count),
        running: running_count,
        retrying: retrying_count,
        errors: error_count,
        stale_warnings: stale_count,
        config_warnings: config_warning_count,
        profile: project.profile,
        pr_target: project.pr_target,
        last_activity_at: latest_activity_at(project_running),
        actions: project_actions(project)
      }
    end)
  end

  defp entry_in_project?(entry, project_slug) do
    entry_slug = Map.get(entry, :project_slug)
    is_nil(project_slug) or is_nil(entry_slug) or entry_slug == project_slug
  end

  defp project_statuses(running_count, retrying_count, error_count, stale_count, config_warning_count) do
    [
      config_warning_count > 0 && "config_warning",
      error_count > 0 && "work_error",
      retrying_count > 0 && "retrying",
      stale_count > 0 && "stale",
      running_count > 0 && "active",
      (running_count == 0 and retrying_count == 0 and error_count == 0) && "idle"
    ]
    |> Enum.reject(&(&1 in [false, nil]))
  end

  defp project_actions(%{url: url}) when is_binary(url), do: [%{label: "Open Linear", href: url}]
  defp project_actions(_project), do: []

  defp latest_activity_at(running) do
    running
    |> Enum.map(&last_activity_at/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
    |> iso8601()
  end

  defp work_error_payloads(retrying) do
    retrying
    |> Enum.filter(&(is_binary(&1.error) and String.trim(&1.error) != ""))
    |> Enum.map(fn retry ->
      %{
        issue_id: retry.issue_id,
        issue_identifier: retry.issue_identifier,
        issue_url: Map.get(retry, :issue_url),
        project_slug: retry.project_slug,
        attempt: retry.attempt,
        error: retry.error,
        due_at: retry.due_at
      }
    end)
  end

  defp stale_warning_payloads(running, now) do
    running
    |> Enum.flat_map(fn entry ->
      case stale_age_seconds(entry, now) do
        seconds when is_integer(seconds) and seconds > @stale_after_seconds ->
          [
            %{
              issue_id: entry.issue_id,
              issue_identifier: entry.issue_identifier,
              project_slug: entry.project_slug,
              session_id: entry.session_id,
              last_activity_at: last_activity_at(entry) |> iso8601(),
              stale_seconds: seconds
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp stale_age_seconds(entry, now) do
    case last_activity_at(entry) do
      %DateTime{} = last_activity -> max(DateTime.diff(now, last_activity, :second), 0)
      _ -> nil
    end
  end

  defp last_activity_at(entry) do
    parse_iso8601(entry.last_event_at) || parse_iso8601(entry.started_at)
  end

  defp config_warning_payloads do
    case Config.settings() do
      {:ok, settings} ->
        settings.tracker
        |> tracker_config_warnings()

      {:error, reason} ->
        [config_warning("workflow_config", "Workflow config could not be loaded: #{inspect(reason)}.")]
    end
  end

  defp tracker_config_warnings(tracker) do
    [
      missing_tracker_kind_warning(tracker),
      unsupported_tracker_kind_warning(tracker),
      missing_linear_api_token_warning(tracker),
      missing_linear_project_scope_warning(tracker)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp missing_tracker_kind_warning(%{kind: nil}), do: config_warning("missing_tracker_kind", "Tracker kind is not configured.")
  defp missing_tracker_kind_warning(_tracker), do: nil

  defp unsupported_tracker_kind_warning(%{kind: kind}) when kind not in [nil, "linear", "memory"] do
    config_warning("unsupported_tracker_kind", "Tracker kind `#{kind}` is not supported.")
  end

  defp unsupported_tracker_kind_warning(_tracker), do: nil

  defp missing_linear_api_token_warning(%{kind: "linear", api_key: api_key}) when not is_binary(api_key) do
    config_warning("missing_linear_api_token", "Linear API token is not configured.")
  end

  defp missing_linear_api_token_warning(_tracker), do: nil

  defp missing_linear_project_scope_warning(%{kind: "linear", project_slug: project_slug}) when not is_binary(project_slug) do
    if linear_dispatch_scope_configured?() do
      nil
    else
      config_warning("missing_linear_project_slug", "Linear project slug is not configured.")
    end
  end

  defp missing_linear_project_scope_warning(_tracker), do: nil

  defp config_warning(code, message), do: %{code: code, message: message}

  defp linear_dispatch_scope_configured? do
    Config.linear_profile_bindings()
    |> ProfileBindings.dispatch_scope_configured?()
  end

  defp token_hotspot_payload([]), do: nil

  defp token_hotspot_payload(running) do
    case Enum.max_by(running, &token_total/1, fn -> nil end) do
      %{tokens: %{total_tokens: total_tokens}} = entry when is_integer(total_tokens) and total_tokens > 0 ->
        %{
          issue_identifier: entry.issue_identifier,
          session_id: entry.session_id,
          total_tokens: total_tokens,
          input_tokens: entry.tokens.input_tokens,
          output_tokens: entry.tokens.output_tokens
        }

      _ ->
        nil
    end
  end

  defp token_total(%{tokens: %{total_tokens: total_tokens}}) when is_integer(total_tokens), do: total_tokens
  defp token_total(_entry), do: 0

  defp meaningful_rate_limits?(nil), do: false
  defp meaningful_rate_limits?(value) when is_binary(value), do: meaningful_rate_limit_value?(value)

  defp meaningful_rate_limits?(map) when is_map(map) do
    Enum.any?(map, fn
      {key, value} when key in ["primary", :primary, "secondary", :secondary] ->
        meaningful_rate_limit_bucket?(value)

      {key, value} when key in ["credits", :credits] ->
        meaningful_rate_limit_credits?(value)

      {key, _value}
      when key in ["limit_id", :limit_id, "limit_name", :limit_name, "id", :id, "name", :name] ->
        false

      {_key, %{} = value} ->
        meaningful_rate_limits?(value)

      {_key, value} ->
        meaningful_rate_limit_value?(value)
    end)
  end

  defp meaningful_rate_limits?(_value), do: true

  defp meaningful_rate_limit_bucket?(bucket) when is_map(bucket) do
    Enum.any?(
      ["remaining", :remaining, "limit", :limit, "reset_in_seconds", :reset_in_seconds, "reset_at", :reset_at, "resetAt", :resetAt],
      &meaningful_rate_limit_value?(Map.get(bucket, &1))
    )
  end

  defp meaningful_rate_limit_bucket?(_bucket), do: false

  defp meaningful_rate_limit_credits?(credits) when is_map(credits) do
    Enum.any?(
      ["unlimited", :unlimited, "has_credits", :has_credits, "balance", :balance],
      &meaningful_rate_limit_value?(Map.get(credits, &1))
    )
  end

  defp meaningful_rate_limit_credits?(_credits), do: false

  defp meaningful_rate_limit_value?(value) when is_integer(value) or is_float(value), do: true
  defp meaningful_rate_limit_value?(value) when is_binary(value), do: String.trim(value) not in ["", "n/a", "unknown"]
  defp meaningful_rate_limit_value?(value) when is_boolean(value), do: true
  defp meaningful_rate_limit_value?(_value), do: false

  defp linear_project_url(project_slug), do: "https://linear.app/project/#{project_slug}/issues"

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp put_if_present(payload, _key, nil), do: payload
  defp put_if_present(payload, key, value), do: Map.put(payload, key, value)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp parse_iso8601(_value), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
