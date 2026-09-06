defmodule SymphonyElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      compilers: [:phoenix_live_view, :elixir_make] ++ Mix.compilers(),
      make_targets: ["native"],
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 100
        ],
        ignore_modules: [
          Mix.Tasks.Incident.LinearIssue,
          SymphonyElixir.Application,
          SymphonyElixir.AgentRuntime,
          SymphonyElixir.AgentRuntime.CodexAppServer,
          SymphonyElixir.AgentRuntime.OpenCodeServer,
          SymphonyElixir.AgentRuntime.OmpAcp,
          SymphonyElixir.AgentRuntime.OmpMcpBridge,
          SymphonyElixir.Config,
          SymphonyElixir.ControlPlane,
          SymphonyElixir.ControlPlaneCLI,
          SymphonyElixir.ControlPlane.Error,
          SymphonyElixir.IncidentLinearIssue.Linear,
          SymphonyElixir.WorkflowCLI,
          SymphonyElixir.Workflow.Renderer,
          SymphonyElixir.Linear.Client,
          SymphonyElixir.LandingRevalidation,
          SymphonyElixir.HostScheduler,
          SymphonyElixir.HostScheduler.Registry,
          SymphonyElixir.HostCLI,
          SymphonyElixir.LocalConfig,
          SymphonyElixir.SpecsCheck,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.Orchestrator.State,
          SymphonyElixir.AgentRunner,
          SymphonyElixir.CLI,
          SymphonyElixir.ReviewRecords,
          SymphonyElixir.OperatorCommandService,
          SymphonyElixir.OperatorInterface,
          SymphonyElixir.OperatorLogHandler,
          SymphonyElixir.OperatorSnapshot,
          SymphonyElixir.Codex.DynamicTool,
          SymphonyElixir.Codex.HarnessHome,
          SymphonyElixir.HttpServer,
          SymphonyElixir.ProcessSupervisor,
          SymphonyElixir.RunSetup,
          SymphonyElixir.SetupMigration,
          SymphonyElixir.StatusDashboard,
          SymphonyElixir.LogFile,
          SymphonyElixir.LocalRun,
          SymphonyElixir.Manifest,
          SymphonyElixirWeb.DashboardLive,
          SymphonyElixirWeb.Endpoint,
          SymphonyElixirWeb.ErrorHTML,
          SymphonyElixirWeb.ErrorJSON,
          SymphonyElixirWeb.Layouts,
          SymphonyElixirWeb.ObservabilityApiController,
          SymphonyElixirWeb.OperatorApiController,
          SymphonyElixirWeb.Presenter,
          SymphonyElixirWeb.StaticAssetController,
          SymphonyElixirWeb.StaticAssets,
          SymphonyElixirWeb.Router,
          SymphonyElixirWeb.Router.Helpers
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs",
        "test/support/agent_runtime_contract.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      escript: escript(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {SymphonyElixir.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.12.5"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.33"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.3.3"},
      {:ecto, "~> 3.14.2"},
      {:exqlite, "~> 0.40.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:elixir_make, "~> 0.10", runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["compile", "escript.build"],
      lint: ["specs.check", "credo --strict"]
    ]
  end

  defp escript do
    [
      app: nil,
      main_module: SymphonyElixir.CLI,
      name: "symphony",
      path: "bin/symphony"
    ]
  end
end
