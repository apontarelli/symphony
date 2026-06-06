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
    admin = ProfileBindingAdmin.facts()

    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:admin, admin)
      |> assign(:discovered_projects, [])
      |> assign(:draft_projects, nil)
      |> assign(:scope_editor_open, false)
      |> assign(:project_search_query, "")
      |> assign(:project_status_filter, "active")
      |> assign(:diagnostics_open, false)
      |> assign(:admin_message, nil)
      |> assign(:admin_error, nil)
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
  def handle_event("refresh_projects", _params, socket) do
    case ProfileBindingAdmin.discover_projects() do
      {:ok, projects} ->
        {:noreply,
         socket
         |> assign(:discovered_projects, projects)
         |> assign(:draft_projects, nil)
         |> assign(:scope_editor_open, true)
         |> assign(:admin, ProfileBindingAdmin.facts())
         |> assign(:admin_message, "Project list refreshed.")
         |> assign(:admin_error, nil)}

      {:error, reason} ->
        admin = ProfileBindingAdmin.facts()

        {:noreply,
         socket
         |> assign(:admin, admin)
         |> assign(:admin_message, nil)
         |> assign(:admin_error, discovery_error_message(reason, admin))}
    end
  end

  def handle_event("save_bindings", %{"projects" => project_params}, socket) do
    projects = socket.assigns.draft_projects || ProfileBindingAdmin.parse_project_params(project_params)

    case ProfileBindingAdmin.save_project_bindings(projects) do
      {:ok, _bindings} ->
        maybe_schedule_runtime_tick(socket.assigns.payload)

        {:noreply,
         socket
         |> assign(:admin, ProfileBindingAdmin.facts())
         |> assign(:draft_projects, nil)
         |> assign(:scope_editor_open, false)
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

  def handle_event("change_bindings", %{"projects" => project_params}, socket) do
    {:noreply, assign(socket, :draft_projects, ProfileBindingAdmin.parse_project_params(project_params))}
  end

  def handle_event("change_bindings", _params, socket), do: {:noreply, assign(socket, :draft_projects, [])}

  def handle_event("open_scope_editor", _params, socket) do
    {:noreply, assign(socket, :scope_editor_open, true)}
  end

  def handle_event("close_scope_editor", _params, socket) do
    socket =
      socket
      |> assign(:scope_editor_open, false)
      |> assign(:draft_projects, nil)

    if not control_interaction_active?(socket) do
      maybe_schedule_runtime_tick(socket.assigns.payload)
    end

    {:noreply, socket}
  end

  def handle_event("change_project_search", params, socket) do
    {:noreply,
     socket
     |> assign(:project_search_query, Map.get(params, "project_search", ""))
     |> assign(:project_status_filter, Map.get(params, "project_status", "active"))}
  end

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
          <h1 class="panel-title"><%= panel_title(@admin) %></h1>
          <p :if={panel_context(@admin)} class="panel-copy"><%= panel_context(@admin) %></p>
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

        <section class="section-card admin-panel">
          <div class="section-header">
            <div>
              <h2 class="section-title">Automation scope</h2>
              <p class="section-copy">Saved locally for this repo. Eligible projects still follow workflow gates.</p>
            </div>
            <button type="button" phx-click="open_scope_editor">Edit scope</button>
          </div>

          <%= if @admin_message do %>
            <p class="notice-copy"><%= @admin_message %></p>
          <% end %>

          <%= if @admin_error do %>
            <p class="error-inline"><%= @admin_error %></p>
          <% end %>

          <%= if scope_summary_rows(@draft_projects) == [] do %>
            <p class="empty-state">No projects are in automation scope.</p>
          <% else %>
            <div class="scope-summary-list">
              <article :for={row <- scope_summary_rows(@draft_projects)} class="scope-summary-row">
                <div class="issue-stack">
                  <span class="issue-id"><%= row.name %></span>
                  <span :if={row.slug_id} class="muted mono"><%= row.slug_id %></span>
                </div>
                <span class={scope_status_class(row.status_label)}><%= row.status_label %></span>
                <span class="muted"><%= row.profile %></span>
                <span class="muted"><%= row.pr_target || "Profile default" %></span>
              </article>
            </div>
          <% end %>

          <div :if={@scope_editor_open} class="scope-editor-panel">
            <div class="section-header">
              <div>
                <h3 class="section-title">Project search</h3>
                <p class="section-copy">Search and filter Linear team projects before adding them to scope.</p>
              </div>
              <button type="button" class="subtle-button" phx-click="close_scope_editor">Close</button>
            </div>

            <form phx-change="change_project_search" class="search-controls">
              <label>
                <span>Search</span>
                <input type="search" name="project_search" value={@project_search_query} placeholder="Filter by project name or slug" />
              </label>
              <label>
                <span>Status</span>
                <select name="project_status">
                  <option value="active" selected={@project_status_filter == "active"}>Active</option>
                  <option value="all" selected={@project_status_filter == "all"}>All</option>
                  <option value="completed" selected={@project_status_filter == "completed"}>Completed</option>
                </select>
              </label>
              <button type="button" phx-click="refresh_projects">Discover projects</button>
            </form>

            <form phx-change="change_bindings" phx-submit="save_bindings">
              <%= if project_search_rows(@discovered_projects, @draft_projects, @project_search_query, @project_status_filter) == [] do %>
                <p class="empty-state">No matching projects. Try another search or status filter.</p>
              <% else %>
                <div class="table-wrap">
                  <table class="data-table admin-table">
                    <thead>
                      <tr>
                        <th>Automate</th>
                        <th>Project</th>
                        <th>Status</th>
                        <th>Profile</th>
                        <th>PR target</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={{row, index} <- Enum.with_index(project_search_rows(@discovered_projects, @draft_projects, @project_search_query, @project_status_filter))}>
                        <td data-label="Automate">
                          <label class="scope-toggle">
                            <input type="checkbox" name={"projects[#{index}][include]"} value="true" checked={row.bound?} />
                            <span><%= if row.bound?, do: "Automated", else: "Not automated" %></span>
                          </label>
                          <input type="hidden" name={"projects[#{index}][selector_kind]"} value={row.selector_kind} />
                          <input type="hidden" name={"projects[#{index}][selector_value]"} value={row.selector_value} />
                        </td>
                        <td data-label="Project">
                          <div class="issue-stack">
                            <span class="issue-id"><%= row.name %></span>
                            <span :if={row.slug_id} class="muted mono"><%= row.slug_id %></span>
                          </div>
                        </td>
                        <td data-label="Status">
                          <div class="detail-stack">
                            <span class={scope_status_class(row.status_label)}><%= row.status_label %></span>
                            <span class="muted"><%= row.status_detail %></span>
                          </div>
                        </td>
                        <td data-label="Profile">
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
                        <td data-label="PR target">
                          <div class="target-control">
                            <select name={"projects[#{index}][pr_target_mode]"}>
                              <option value="profile" selected={row.pr_target_mode == "profile"}>Profile default</option>
                              <option value="main" selected={row.pr_target_mode == "main"}>main</option>
                              <option
                                :if={row.generated_pr_target}
                                value="generated"
                                selected={row.pr_target_mode == "generated"}
                              >
                                <%= row.generated_pr_target %>
                              </option>
                              <option value="custom" selected={row.pr_target_mode == "custom"}>Custom</option>
                            </select>
                            <input
                              type="text"
                              name={"projects[#{index}][pr_target_custom]"}
                              value={row.pr_target_custom || ""}
                              placeholder="custom/base-branch"
                            />
                          </div>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
                <button type="submit">Save bindings</button>
              <% end %>
            </form>
          </div>

          <div class="admin-section">
            <button type="button" class="subtle-button" phx-click="toggle_diagnostics">
              <%= if @diagnostics_open, do: "Hide profiles and diagnostics", else: "Show profiles and diagnostics" %>
            </button>
            <div :if={@diagnostics_open} class="admin-content">
              <div class="profile-strip">
                <span :for={profile <- @admin.profiles} class="profile-pill">
                  <%= profile.name %>
                  <span class="muted"><%= profile.pr_target || "n/a" %></span>
                </span>
              </div>

              <div class="admin-grid">
                <div class="admin-facts">
                  <h3>Workflow</h3>
                  <dl>
                    <dt>File</dt>
                    <dd class="mono"><%= @admin.workflow_path %></dd>
                    <dt>Tracker</dt>
                    <dd><%= @admin.workflow.tracker_kind %></dd>
                    <dt><%= team_selector_key(@admin) %></dt>
                    <dd><%= team_selector_value(@admin) %></dd>
                    <dt>Active states</dt>
                    <dd><%= Enum.join(@admin.workflow.active_states, ", ") %></dd>
                    <dt>Terminal states</dt>
                    <dd><%= Enum.join(@admin.workflow.terminal_states, ", ") %></dd>
                  </dl>
                </div>

                <div class="admin-facts">
                  <h3>Binding source</h3>
                  <dl>
                    <dt>Source</dt>
                    <dd class="mono"><%= @admin.binding_source.path %></dd>
                    <dt>Mode</dt>
                    <dd><%= if @admin.binding_source.explicit?, do: "explicit", else: "default" %></dd>
                    <dt>Validation</dt>
                    <dd><%= @admin.validation.message %></dd>
                    <dt>Fallback</dt>
                    <dd><%= fallback_summary(@admin.bindings) %></dd>
                  </dl>
                </div>
              </div>
            </div>
          </div>
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
                  <span class="issue-id"><%= entry.issue_identifier %></span>
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
                        <span class="issue-id"><%= entry.issue_identifier %></span>
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

  defp put_project_groups(%{error: _error} = payload), do: payload
  defp put_project_groups(payload), do: Map.put(payload, :project_groups, project_groups(payload))

  defp panel_title(admin) do
    case team_selector_value(admin) do
      "missing" -> repo_name(admin)
      team -> "#{repo_name(admin)} / #{team}"
    end
  end

  defp panel_context(admin) do
    case team_selector_key(admin) do
      "missing" -> nil
      key -> "#{key}=#{team_selector_value(admin)}"
    end
  end

  defp repo_name(%{workflow_path: workflow_path}) when is_binary(workflow_path) do
    workflow_path
    |> Path.dirname()
    |> repo_root()
    |> Path.basename()
  end

  defp repo_name(_admin), do: "Symphony"

  defp team_selector_key(%{bindings: %{team_key: team_key}}) when is_binary(team_key), do: "team_key"
  defp team_selector_key(%{bindings: %{team_id: team_id}}) when is_binary(team_id), do: "team_id"
  defp team_selector_key(_admin), do: "missing"

  defp team_selector_value(%{bindings: %{team_key: team_key}}) when is_binary(team_key), do: team_key
  defp team_selector_value(%{bindings: %{team_id: team_id}}) when is_binary(team_id), do: team_id
  defp team_selector_value(_admin), do: "missing"

  defp fallback_summary(%{catch_all: %{enabled: true}, allow_default: true}), do: "catch_all and default fallback enabled"
  defp fallback_summary(%{catch_all: %{enabled: true}}), do: "catch_all enabled"
  defp fallback_summary(%{allow_default: true}), do: "default fallback enabled"
  defp fallback_summary(_bindings), do: "explicit projects only"

  defp signal_count(payload) do
    length(payload.work_errors) + length(payload.config_warnings) + length(payload.stale_warnings)
  end

  defp discovery_error_message({:linear_api_status, status}, admin) do
    discovery_error_message({:linear_api_status, status, []}, admin)
  end

  defp discovery_error_message({:linear_api_status, status, errors}, admin) do
    detail =
      case errors do
        [%{message: message} | _rest] when is_binary(message) -> " Linear says: #{message}"
        _errors -> ""
      end

    "Linear setup blocked while discovering projects for #{team_selector_key(admin)}=#{team_selector_value(admin)}. " <>
      "Linear rejected the request with HTTP #{status}; verify the token, team selector, and Linear permissions, then retry." <>
      detail
  end

  defp discovery_error_message(:missing_linear_project_discovery_team_selector, _admin) do
    "Linear setup blocked: configure team_key or team_id before discovering projects."
  end

  defp discovery_error_message(reason, admin) do
    "Linear setup blocked while discovering projects for #{team_selector_key(admin)}=#{team_selector_value(admin)}: #{inspect(reason)}"
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

  defp scope_status_class("Automated"), do: "state-badge state-badge-active"
  defp scope_status_class("Needs attention"), do: "state-badge state-badge-warning"
  defp scope_status_class(_status), do: "state-badge state-badge-idle"

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

  defp repo_root(path) do
    cond do
      File.dir?(Path.join(path, ".git")) or File.dir?(Path.join(path, ".jj")) ->
        path

      Path.dirname(path) == path ->
        path

      true ->
        repo_root(Path.dirname(path))
    end
  end

  defp admin_project_rows(projects, nil), do: ProfileBindingAdmin.project_rows(projects)
  defp admin_project_rows(projects, draft_projects), do: ProfileBindingAdmin.project_rows(projects, draft_projects)

  defp scope_summary_rows(draft_projects) do
    []
    |> admin_project_rows(draft_projects)
    |> Enum.filter(& &1.bound?)
  end

  defp project_search_rows(projects, draft_projects, query, status_filter) do
    current_rows = admin_project_rows(projects, nil)
    draft_rows = admin_project_rows(projects, draft_projects)

    retained_bound_keys =
      (current_rows ++ draft_rows)
      |> Enum.filter(& &1.bound?)
      |> Enum.map(& &1.selector_key)
      |> MapSet.new()

    draft_rows
    |> Enum.filter(&(MapSet.member?(retained_bound_keys, &1.selector_key) or project_row_matches?(&1, query, status_filter)))
    |> Enum.sort_by(fn row -> {if(row.bound?, do: 0, else: 1), String.downcase(row.name || "")} end)
  end

  defp project_row_matches?(row, query, status_filter) do
    project_row_matches_status?(row, status_filter) and project_row_matches_query?(row, query)
  end

  defp project_row_matches_status?(row, "all"), do: not row.deleted?
  defp project_row_matches_status?(row, "completed"), do: not row.deleted? and not row.active?
  defp project_row_matches_status?(row, _active), do: row.active?

  defp project_row_matches_query?(_row, nil), do: true
  defp project_row_matches_query?(_row, ""), do: true

  defp project_row_matches_query?(row, query) do
    normalized_query = query |> to_string() |> String.trim() |> String.downcase()

    [row.name, row.slug_id, row.id, row.project_url]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(fn value -> String.contains?(String.downcase(to_string(value)), normalized_query) end)
  end

  defp control_interaction_active?(socket) do
    not is_nil(socket.assigns.draft_projects) or socket.assigns.diagnostics_open or socket.assigns.scope_editor_open
  end

  defp maybe_schedule_runtime_tick(%{running: running}) when running != [] do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp maybe_schedule_runtime_tick(_payload), do: :ok

  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
