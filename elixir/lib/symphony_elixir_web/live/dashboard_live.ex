defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Config.ProfileBindingAdmin
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:admin, ProfileBindingAdmin.facts())
      |> assign(:discovered_projects, [])
      |> assign(:admin_message, nil)
      |> assign(:admin_error, nil)
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
  def handle_event("refresh_projects", _params, socket) do
    case ProfileBindingAdmin.discover_projects() do
      {:ok, projects} ->
        {:noreply,
         socket
         |> assign(:discovered_projects, projects)
         |> assign(:admin, ProfileBindingAdmin.facts())
         |> assign(:admin_message, "Project list refreshed.")
         |> assign(:admin_error, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:admin, ProfileBindingAdmin.facts())
         |> assign(:admin_message, nil)
         |> assign(:admin_error, "Project discovery failed: #{inspect(reason)}")}
    end
  end

  def handle_event("save_bindings", %{"projects" => project_params}, socket) do
    projects = ProfileBindingAdmin.parse_project_params(project_params)

    case ProfileBindingAdmin.save_project_bindings(projects) do
      {:ok, _bindings} ->
        {:noreply,
         socket
         |> assign(:admin, ProfileBindingAdmin.facts())
         |> assign(:admin_message, "Bindings saved and applied.")
         |> assign(:admin_error, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:admin, ProfileBindingAdmin.facts())
         |> assign(:admin_message, nil)
         |> assign(:admin_error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("save_bindings", _params, socket), do: handle_event("save_bindings", %{"projects" => %{}}, socket)

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
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
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card admin-panel">
          <div class="section-header">
            <div>
              <h2 class="section-title">Admin</h2>
              <p class="section-copy">Local Linear project bindings for the active workflow.</p>
            </div>
            <button type="button" phx-click="refresh_projects">Refresh projects</button>
          </div>

          <%= if @admin_message do %>
            <p class="notice-copy"><%= @admin_message %></p>
          <% end %>

          <%= if @admin_error do %>
            <p class="error-inline"><%= @admin_error %></p>
          <% end %>

          <div class="admin-grid">
            <div class="admin-facts">
              <h3>Workflow</h3>
              <dl>
                <dt>File</dt>
                <dd class="mono"><%= @admin.workflow_path %></dd>
                <dt>Tracker</dt>
                <dd><%= @admin.workflow.tracker_kind %></dd>
                <dt>Team</dt>
                <dd><%= @admin.workflow.team_selector %></dd>
                <dt>Active states</dt>
                <dd><%= Enum.join(@admin.workflow.active_states, ", ") %></dd>
                <dt>Terminal states</dt>
                <dd><%= Enum.join(@admin.workflow.terminal_states, ", ") %></dd>
              </dl>
            </div>

            <div class="admin-facts">
              <h3>Bindings</h3>
              <dl>
                <dt>Source</dt>
                <dd class="mono"><%= @admin.binding_source.path %></dd>
                <dt>Path mode</dt>
                <dd><%= if @admin.binding_source.explicit?, do: "explicit", else: "default" %></dd>
                <dt>Loaded</dt>
                <dd><%= @admin.bindings.loaded %></dd>
                <dt>Exists</dt>
                <dd><%= @admin.binding_source.exists? %></dd>
                <dt>Validation</dt>
                <dd><%= @admin.validation.message %></dd>
                <dt>allow_default</dt>
                <dd><%= @admin.bindings.allow_default %></dd>
                <dt>catch_all</dt>
                <dd><%= inspect(@admin.bindings.catch_all) %></dd>
              </dl>
            </div>
          </div>

          <div class="profile-strip">
            <span :for={profile <- @admin.profiles} class="profile-pill">
              <%= profile.name %>
              <span class="muted"><%= profile.pr_target || "n/a" %></span>
            </span>
          </div>

          <form phx-submit="save_bindings">
            <div class="table-wrap">
              <table class="data-table admin-table">
                <thead>
                  <tr>
                    <th>Use</th>
                    <th>Project</th>
                    <th>ID</th>
                    <th>Slug</th>
                    <th>Status</th>
                    <th>Profile</th>
                    <th>PR target</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{row, index} <- Enum.with_index(admin_project_rows(@discovered_projects))}>
                    <td>
                      <input type="checkbox" name={"projects[#{index}][include]"} value="true" checked={row.bound?} />
                      <input type="hidden" name={"projects[#{index}][selector_kind]"} value={row.selector_kind} />
                      <input type="hidden" name={"projects[#{index}][selector_value]"} value={row.selector_value} />
                    </td>
                    <td><%= row.name %></td>
                    <td class="mono"><%= row.id || "n/a" %></td>
                    <td class="mono"><%= row.slug_id || "n/a" %></td>
                    <td><%= row.status_name %> / <%= row.status_type %></td>
                    <td>
                      <select name={"projects[#{index}][profile]"}>
                        <option
                          :for={profile <- @admin.profiles}
                          value={profile.name}
                          selected={profile.name == row.profile}
                        >
                          <%= profile.name %>
                        </option>
                      </select>
                    </td>
                    <td>
                      <input type="text" name={"projects[#{index}][pr_target]"} value={row.pr_target || ""} />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <button type="submit">Save bindings</button>
          </form>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Project views</h2>
              <p class="section-copy">Running and retrying issues grouped by selected binding metadata.</p>
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
                  </li>
                </ul>
              </article>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 12rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Policy</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span><%= entry.profile || "n/a" %></span>
                        <span class="muted"><%= entry.target || "n/a" %></span>
                      </div>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Policy</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span><%= entry.profile || "n/a" %></span>
                        <span class="muted"><%= entry.target || "n/a" %></span>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
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

  defp put_project_groups(%{error: _error} = payload), do: payload
  defp put_project_groups(payload), do: Map.put(payload, :project_groups, project_groups(payload))

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

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

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

  defp admin_project_rows(projects), do: ProfileBindingAdmin.project_rows(projects)

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
