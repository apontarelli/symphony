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
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="control-panel">
        <div>
          <p class="eyebrow">Symphony Control Panel</p>
          <h1 class="panel-title">Project health</h1>
          <p class="panel-copy">
            <%= if @payload[:error] do %>
              Snapshot unavailable.
            <% else %>
              Snapshot <%= freshness_text(@payload.generated_at, @now) %>.
            <% end %>
          </p>
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

          <article class={metric_card_class(@payload.counts.work_errors, "danger")}>
            <p class="metric-label">Work errors</p>
            <p class="metric-value numeric"><%= @payload.counts.work_errors %></p>
            <p class="metric-detail">Retry entries with recent errors.</p>
          </article>

          <article class={metric_card_class(@payload.counts.config_warnings, "warning")}>
            <p class="metric-label">Config warnings</p>
            <p class="metric-value numeric"><%= @payload.counts.config_warnings %></p>
            <p class="metric-detail">Workflow configuration gaps.</p>
          </article>

          <article class={metric_card_class(@payload.counts.stale_warnings, "warning")}>
            <p class="metric-label">Stale warnings</p>
            <p class="metric-value numeric"><%= @payload.counts.stale_warnings %></p>
            <p class="metric-detail">No Codex event for over 5 minutes.</p>
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

        <section class="section-card primary-section">
          <div class="section-header">
            <div>
              <h2 class="section-title">Project status</h2>
              <p class="section-copy">Bound project health, active work, retry pressure, and warnings.</p>
            </div>
          </div>

          <%= if @payload.project_statuses == [] do %>
            <p class="empty-state">No bound projects are configured.</p>
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

        <section class="signal-grid" aria-label="Issue signals">
          <article class="signal-card">
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
                  <span class="issue-id"><%= entry.issue_identifier %></span>
                  <span class="muted">attempt <%= entry.attempt %></span>
                  <span><%= entry.error %></span>
                </li>
              </ul>
            <% end %>
          </article>

          <article class="signal-card">
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

          <article class="signal-card">
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
                        <span class="issue-id"><%= entry.issue_identifier %></span>
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
                        <span><%= entry.profile %></span>
                        <span class="muted"><%= entry.pr_target %></span>
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

        <details class="section-card admin-section">
          <summary>Admin</summary>
          <div class="admin-content">
            <div>
              <h2 class="section-title">Project bindings</h2>
              <p class="section-copy">Read-only here; operational status stays in the primary table.</p>
            </div>
            <dl class="binding-list">
              <div :for={project <- @payload.project_statuses}>
                <dt><%= project.project %></dt>
                <dd>
                  profile <span class="mono"><%= project.profile %></span>,
                  target <span class="mono"><%= project.pr_target %></span>
                </dd>
              </div>
            </dl>
          </div>
        </details>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
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

  defp metric_card_class(0, _kind), do: "metric-card"
  defp metric_card_class(_count, "danger"), do: "metric-card metric-card-danger"
  defp metric_card_class(_count, "warning"), do: "metric-card metric-card-warning"

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

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
