defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:diagnostics_open, false)
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      maybe_schedule_runtime_tick(socket.assigns.payload)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    if control_interaction_active?(socket) do
      {:noreply, socket}
    else
      maybe_schedule_runtime_tick(socket.assigns.payload)
      {:noreply, assign(socket, :now, DateTime.utc_now())}
    end
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    payload = load_payload()

    if not control_interaction_active?(socket) do
      maybe_schedule_runtime_tick(payload)
    end

    {:noreply,
     socket
     |> assign(:payload, payload)
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("toggle_diagnostics", _params, socket) do
    socket = update(socket, :diagnostics_open, &(!&1))

    if not control_interaction_active?(socket) do
      maybe_schedule_runtime_tick(socket.assigns.payload)
    end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="control-panel">
        <div>
          <p class="eyebrow">Symphony Control Panel</p>
          <h1 class="panel-title"><%= panel_title(@payload) %></h1>
          <p :if={panel_context(@payload)} class="panel-copy"><%= panel_context(@payload) %></p>
        </div>

        <div class="status-stack">
          <span class="status-badge status-badge-live">
            <span class="status-badge-dot"></span>
            Live
          </span>
          <span class="status-badge status-badge-offline">
            <span class="status-badge-dot"></span>
            Offline
          </span>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">Snapshot unavailable</h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid" aria-label="Control panel overview">
          <article class="metric-card">
            <p class="metric-label">Freshness</p>
            <p class="metric-value">Live</p>
            <p class="metric-detail"><%= freshness_text(@payload.generated_at, @now) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Waiting for retry windows.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Waiting for operator input.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Completed plus active sessions.</p>
          </article>

          <article class="metric-card metric-card-wide">
            <p class="metric-label">Token usage</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail"><%= token_hotspot_text(@payload.token_hotspot) %></p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Project views</h2>
              <p class="section-copy">Running and retrying issues grouped by tracker metadata.</p>
            </div>
          </div>

          <%= if @payload.project_groups == [] do %>
            <p class="empty-state">No active project views.</p>
          <% else %>
            <div class="project-group-grid">
              <article :for={group <- @payload.project_groups} class="project-group">
                <div class="project-group-header">
                  <strong><%= group.label %></strong>
                  <span class="muted numeric"><%= group.running_count %> running / <%= group.retrying_count %> retrying</span>
                </div>
                <ul>
                  <li :for={issue <- group.issues}>
                    <span class="issue-id"><%= issue.issue_identifier %></span>
                    <span class="muted"><%= issue.queue %></span>
                    <span class="muted"><%= issue.profile || "n/a" %></span>
                    <span class="muted"><%= entry_target(issue) %></span>
                  </li>
                </ul>
              </article>
            </div>
          <% end %>
        </section>

        <section class="section-card primary-section">
          <div class="section-header">
            <div>
              <h2 class="section-title">Project status</h2>
              <p class="section-copy">Configured project health, active work, retry pressure, and warnings.</p>
            </div>
          </div>

          <%= if @payload.project_statuses == [] do %>
            <p class="empty-state">No tracker project is configured.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table project-table">
                <thead>
                  <tr>
                    <th>Project</th>
                    <th>Status</th>
                    <th>Running</th>
                    <th>Retrying</th>
                    <th>Errors</th>
                    <th>Profile</th>
                    <th>PR target</th>
                    <th>Last activity</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={project <- @payload.project_statuses}>
                    <td data-label="Project">
                      <div class="issue-stack">
                        <span class="issue-id"><%= project.project %></span>
                        <span :if={project.project_slug} class="muted"><%= project.project_slug %></span>
                      </div>
                    </td>
                    <td data-label="Status">
                      <div class="chip-row">
                        <span :for={status <- project.statuses} class={project_status_badge_class(status)}>
                          <%= project_status_label(status) %>
                        </span>
                      </div>
                    </td>
                    <td data-label="Running" class="numeric"><%= project.running %></td>
                    <td data-label="Retrying" class="numeric"><%= project.retrying %></td>
                    <td data-label="Errors" class="numeric"><%= project.errors %></td>
                    <td data-label="Profile"><%= project.profile %></td>
                    <td data-label="PR target"><%= project.pr_target %></td>
                    <td data-label="Last activity"><%= format_timestamp(project.last_activity_at) %></td>
                    <td data-label="Actions">
                      <div class="action-stack">
                        <a :for={action <- project.actions} class="table-action" href={action.href}><%= action.label %></a>
                        <span :if={project.actions == []} class="muted">n/a</span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section :if={signal_count(@payload) > 0} class="signal-grid" aria-label="Issue signals">
          <article :if={@payload.work_errors != []} class="signal-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Work errors</h2>
                <p class="section-copy">Retrying work with actionable error text.</p>
              </div>
            </div>
            <%= if @payload.work_errors == [] do %>
              <p class="empty-state">No work errors.</p>
            <% else %>
              <ul class="signal-list">
                <li :for={entry <- @payload.work_errors}>
                  <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                  <span class="muted">attempt <%= entry.attempt %></span>
                  <span><%= entry.error %></span>
                </li>
              </ul>
            <% end %>
          </article>

          <article :if={@payload.config_warnings != []} class="signal-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Config warnings</h2>
                <p class="section-copy">Configuration gaps that affect dispatch.</p>
              </div>
            </div>
            <%= if @payload.config_warnings == [] do %>
              <p class="empty-state">No config warnings.</p>
            <% else %>
              <ul class="signal-list">
                <li :for={warning <- @payload.config_warnings}>
                  <span class="issue-id"><%= warning.code %></span>
                  <span><%= warning.message %></span>
                </li>
              </ul>
            <% end %>
          </article>

          <article :if={@payload.stale_warnings != []} class="signal-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Stale sessions</h2>
                <p class="section-copy">Warnings for active sessions with no recent Codex event.</p>
              </div>
            </div>
            <%= if @payload.stale_warnings == [] do %>
              <p class="empty-state">No stale sessions.</p>
            <% else %>
              <ul class="signal-list">
                <li :for={warning <- @payload.stale_warnings}>
                  <span class="issue-id"><%= warning.issue_identifier %></span>
                  <span class="muted"><%= format_runtime_seconds(warning.stale_seconds) %> since activity</span>
                </li>
              </ul>
            <% end %>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, profile, target, last agent activity, and token split.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Profile / target</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td data-label="Issue">
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td data-label="State">
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td data-label="Profile / target">
                      <div class="detail-stack">
                        <span><%= entry.profile || "n/a" %></span>
                        <span class="muted"><%= entry_target(entry) %></span>
                      </div>
                    </td>
                    <td data-label="Session">
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            aria-label={"Copy session ID for #{entry.issue_identifier}"}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td data-label="Runtime / turns" class="numeric">
                      <%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %>
                    </td>
                    <td data-label="Codex update">
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td data-label="Tokens">
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">
                          In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %>
                        </span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section :if={@payload.rate_limits_available} class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Current upstream constraints.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section :if={@payload.handoff_routes != []} class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Handoff routes</h2>
              <p class="section-copy">Completed route decisions, evidence summaries, and review artifacts.</p>
            </div>
          </div>

          <div class="table-wrap">
            <table class="data-table" style="min-width: 900px;">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Route</th>
                  <th>Target</th>
                  <th>Evidence</th>
                  <th>Artifacts</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={route <- @payload.handoff_routes}>
                  <td data-label="Issue">
                    <span class="issue-id"><%= route_value(route, :issue_id) || "n/a" %></span>
                  </td>
                  <td data-label="Route">
                    <span class={state_badge_class(route_value(route, :route) || "")}>
                      <%= route_label(route_value(route, :route)) %>
                    </span>
                  </td>
                  <td data-label="Target"><%= route_value(route, :target_state) || "n/a" %></td>
                  <td data-label="Evidence">
                    <div class="detail-stack">
                      <span><%= route_value(route, :summary) || "n/a" %></span>
                      <span :if={route_evidence_text(route)} class="muted"><%= route_evidence_text(route) %></span>
                    </div>
                  </td>
                  <td data-label="Artifacts">
                    <div class="action-stack">
                      <%= if route_artifacts(route) == [] do %>
                        <span class="muted">n/a</span>
                      <% else %>
                        <%= for artifact <- route_artifacts(route) do %>
                          <a
                            :if={external_issue_url(artifact_url(artifact))}
                            class="table-action"
                            href={artifact_url(artifact)}
                            target="_blank"
                            rel="noopener noreferrer"
                          ><%= artifact_label(artifact) %></a>
                          <span :if={!external_issue_url(artifact_url(artifact))} class="muted">
                            <%= artifact_text(artifact) %>
                          </span>
                        <% end %>
                      <% end %>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">No blocked sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Profile / target</th>
                    <th>Session</th>
                    <th>Blocked at</th>
                    <th>Last update</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td data-label="Issue">
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td data-label="State">
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || "Blocked" %>
                      </span>
                    </td>
                    <td data-label="Profile / target">
                      <div class="detail-stack">
                        <span><%= entry.profile || "n/a" %></span>
                        <span class="muted"><%= entry_target(entry) %></span>
                      </div>
                    </td>
                    <td data-label="Session">
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          aria-label={"Copy session ID for #{entry.issue_identifier}"}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td data-label="Blocked at" class="mono"><%= entry.blocked_at || "n/a" %></td>
                    <td data-label="Last update">
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td data-label="Error"><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    orchestrator()
    |> Presenter.state_payload(snapshot_timeout_ms())
    |> put_project_groups()
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp put_project_groups(%{error: _error} = payload), do: payload
  defp put_project_groups(payload), do: Map.put(payload, :project_groups, project_groups(payload))

  defp panel_title(%{project_statuses: [%{project: project} | _projects]}) when is_binary(project), do: project
  defp panel_title(_payload), do: "Symphony"

  defp panel_context(%{project_statuses: [%{project_slug: slug} | _projects]}) when is_binary(slug), do: slug
  defp panel_context(%{project_statuses: [%{project_id: id} | _projects]}) when is_binary(id), do: "project_id=#{id}"
  defp panel_context(_payload), do: nil

  defp signal_count(payload) do
    length(payload.work_errors) + length(payload.config_warnings) + length(payload.stale_warnings)
  end

  defp project_groups(%{running: running, retrying: retrying}) do
    entries =
      Enum.map(running, &Map.put(&1, :queue, "running")) ++
        Enum.map(retrying, &Map.put(&1, :queue, "retrying"))

    entries
    |> Enum.group_by(&project_group_key/1)
    |> Enum.map(fn {key, group_entries} ->
      %{
        label: project_group_label(key),
        running_count: Enum.count(group_entries, &(&1.queue == "running")),
        retrying_count: Enum.count(group_entries, &(&1.queue == "retrying")),
        issues: group_entries
      }
    end)
    |> Enum.sort_by(& &1.label)
  end

  defp project_groups(_payload), do: []

  defp project_group_key(%{policy: %{"policy_metadata" => metadata}}) when is_map(metadata) do
    cond do
      is_binary(metadata["project_slug"]) -> "project_slug:#{metadata["project_slug"]}"
      is_binary(metadata["project_id"]) -> "project_id:#{metadata["project_id"]}"
      true -> "unassigned"
    end
  end

  defp project_group_key(_entry), do: "unassigned"

  defp project_group_label("project_slug:" <> slug), do: slug
  defp project_group_label("project_id:" <> id), do: id
  defp project_group_label("unassigned"), do: "Unassigned / other"

  defp entry_target(entry) do
    Map.get(entry, :target) || Map.get(entry, :pr_target) || "n/a"
  end

  defp route_value(route, key) when is_map(route) do
    Map.get(route, key) || Map.get(route, Atom.to_string(key))
  end

  defp route_value(_route, _key), do: nil

  defp route_label(nil), do: "n/a"

  defp route_label(route) do
    route
    |> to_string()
    |> String.replace("_", " ")
  end

  defp route_evidence_text(route) do
    route
    |> route_value(:evidence)
    |> case do
      evidence when is_list(evidence) ->
        evidence
        |> Enum.filter(&(route_value(&1, :kind) == "product_visual_review"))
        |> Enum.map(&route_value(&1, :summary))
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
        |> case do
          "" -> nil
          text -> text
        end

      _evidence ->
        nil
    end
  end

  defp route_artifacts(route) do
    case route_value(route, :artifacts) do
      artifacts when is_list(artifacts) -> artifacts
      _artifacts -> []
    end
  end

  defp artifact_url(artifact), do: route_value(artifact, :url)

  defp artifact_label(artifact) do
    route_value(artifact, :label) || route_value(artifact, :kind) || "artifact"
  end

  defp artifact_text(artifact) do
    case route_value(artifact, :summary) do
      summary when is_binary(summary) and summary != "" -> "#{artifact_label(artifact)}: #{summary}"
      _summary -> artifact_label(artifact)
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp freshness_text(generated_at, %DateTime{} = now) when is_binary(generated_at) do
    case DateTime.from_iso8601(generated_at) do
      {:ok, parsed, _offset} ->
        "#{format_runtime_seconds(DateTime.diff(now, parsed, :second))} old"

      _ ->
        "n/a"
    end
  end

  defp freshness_text(_generated_at, _now), do: "n/a"

  defp format_timestamp(nil), do: "No active work"

  defp format_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> Calendar.strftime(parsed, "%Y-%m-%d %H:%M UTC")
      _ -> timestamp
    end
  end

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp token_hotspot_text(nil), do: "No active token hotspot."

  defp token_hotspot_text(hotspot) do
    "Highest active: #{hotspot.issue_identifier} with #{format_int(hotspot.total_tokens)} tokens."
  end

  defp project_status_label("config_warning"), do: "Config warning"
  defp project_status_label("work_error"), do: "Work error"
  defp project_status_label("retrying"), do: "Retrying"
  defp project_status_label("stale"), do: "Stale"
  defp project_status_label("active"), do: "Active"
  defp project_status_label("idle"), do: "Idle"
  defp project_status_label(status), do: status

  defp project_status_badge_class(status), do: "state-badge state-badge-#{status}"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp control_interaction_active?(socket), do: socket.assigns.diagnostics_open

  defp maybe_schedule_runtime_tick(%{running: running}) when running != [] do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp maybe_schedule_runtime_tick(_payload), do: :ok

  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
