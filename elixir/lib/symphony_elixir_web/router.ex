defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/favicon.ico", StaticAssetController, :favicon)
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/operator/snapshot", OperatorApiController, :snapshot)
    match(:*, "/api/v1/operator/snapshot", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/operator/events", OperatorApiController, :events)
    match(:*, "/api/v1/operator/events", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/operator/commands/preview", OperatorApiController, :preview)
    match(:*, "/api/v1/operator/commands/preview", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/operator/commands/confirm", OperatorApiController, :confirm)
    match(:*, "/api/v1/operator/commands/confirm", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/control-plane/runs", ObservabilityApiController, :control_plane)
    match(:*, "/api/v1/control-plane/runs", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/control-plane/runs/:run_id/resume", ObservabilityApiController, :mutation_contract_required)
    match(:*, "/api/v1/control-plane/runs/:run_id/resume", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/control-plane/runs/:run_id/abandon", ObservabilityApiController, :mutation_contract_required)
    match(:*, "/api/v1/control-plane/runs/:run_id/abandon", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/control-plane/prune", ObservabilityApiController, :mutation_contract_required)
    match(:*, "/api/v1/control-plane/prune", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :mutation_contract_required)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
