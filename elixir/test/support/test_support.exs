defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          write_manifest_file!: 1,
          write_manifest_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0,
          read_pid: 1,
          os_pid_alive?: 1,
          eventually: 1,
          eventually: 2
        ]

      setup do
        SymphonyElixir.TestSupport.ensure_application_started!()

        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "symphony.runtime.yml")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        previous_log_file = Application.get_env(:symphony_elixir, :log_file)
        Application.put_env(:symphony_elixir, :log_file, SymphonyElixir.LogFile.default_log_file(Path.join(workflow_root, "runtime")))
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :workflow_profile_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          Application.delete_env(:symphony_elixir, :publish_handoff_runner)
          Application.delete_env(:symphony_elixir, :publish_preflight_runner)
          Application.delete_env(:symphony_elixir, :quality_gate_runner)

          case previous_log_file do
            nil -> Application.delete_env(:symphony_elixir, :log_file)
            log_file -> Application.put_env(:symphony_elixir, :log_file, log_file)
          end

          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    write_manifest_file!(path, overrides)
  end

  def write_manifest_file!(path, overrides \\ []) do
    manifest = workflow_content(overrides)
    File.write!(path, manifest)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def read_pid(path) do
    case File.read(path) do
      {:ok, pid_text} ->
        case Integer.parse(String.trim(pid_text)) do
          {pid, ""} -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def os_pid_alive?(nil), do: false

  def os_pid_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  def eventually(fun, attempts \\ 20)

  def eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(50)
        eventually(fun, attempts - 1)

      false ->
        Process.sleep(50)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  def eventually(_fun, 0), do: false

  def ensure_application_started! do
    case Application.ensure_all_started(:symphony_elixir) do
      {:ok, _started_apps} -> :ok
      {:error, reason} -> raise "failed to start symphony_elixir application: #{inspect(reason)}"
    end
  end

  def stop_default_http_server do
    children =
      case Process.whereis(SymphonyElixir.Supervisor) do
        pid when is_pid(pid) -> Supervisor.which_children(pid)
        nil -> []
      end

    case Enum.find(children, fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_id: nil,
          tracker_project_slug: "project",
          tracker_team_key: nil,
          tracker_workspace_slug: nil,
          tracker_assignee: nil,
          tracker_required_labels: [],
          tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          default_runner: "codex",
          worker_max_concurrent_startups_per_host: nil,
          max_concurrent_agents: 10,
          max_concurrent_startups: 2,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          runner_kind: "codex_app_server",
          codex_command: "codex app-server",
          codex_model: "gpt-5.5",
          codex_approval_policy: "never",
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 30_000,
          codex_stall_timeout_ms: 300_000,
          runner_max_concurrent_startups: nil,
          quality_gate_enabled: false,
          quality_gate_source_max_concurrency: 3,
          quality_gate_max_repair_passes: 1,
          quality_gate_runtime_isolation: "serialized",
          quality_gate_reviewer_timeout_ms: 1_200_000,
          quality_gate_reviewer_max_retries: 0,
          profiles: %{default: %{delivery: %{pr_target: "main"}}},
          harness_codex_home: nil,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          project_repository: "https://github.com/example/project.git",
          delivery_pr_target: "main",
          issue_markers: %{"labels" => [], "allowed_projects" => []},
          target: nil,
          workflow_module_ids: [],
          workflow_modules_product_visual_review: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_id = Keyword.get(config, :tracker_project_id)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_team_key = Keyword.get(config, :tracker_team_key)
    tracker_workspace_slug = Keyword.get(config, :tracker_workspace_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_required_labels = Keyword.get(config, :tracker_required_labels)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    default_runner = Keyword.get(config, :default_runner)
    worker_max_concurrent_startups_per_host = Keyword.get(config, :worker_max_concurrent_startups_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_concurrent_startups = Keyword.get(config, :max_concurrent_startups)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    runner_kind = Keyword.get(config, :runner_kind)
    codex_command = Keyword.get(config, :codex_command)
    runner_command = Keyword.get(config, :runner_command) || command_argv(codex_command)
    codex_model = Keyword.get(config, :codex_model)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    runner_max_concurrent_startups = Keyword.get(config, :runner_max_concurrent_startups)
    quality_gate_enabled = Keyword.get(config, :quality_gate_enabled)
    quality_gate_source_max_concurrency = Keyword.get(config, :quality_gate_source_max_concurrency)
    quality_gate_max_repair_passes = Keyword.get(config, :quality_gate_max_repair_passes)
    quality_gate_runtime_isolation = Keyword.get(config, :quality_gate_runtime_isolation)
    quality_gate_reviewer_timeout_ms = Keyword.get(config, :quality_gate_reviewer_timeout_ms)
    quality_gate_reviewer_max_retries = Keyword.get(config, :quality_gate_reviewer_max_retries)
    profiles = Keyword.get(config, :profiles)
    harness_codex_home = Keyword.get(config, :harness_codex_home)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    project_repository = Keyword.get(config, :project_repository)
    delivery_pr_target = Keyword.get(config, :delivery_pr_target)
    issue_markers = Keyword.get(config, :issue_markers)
    target = Keyword.get(config, :target)
    workflow_module_ids = Keyword.get(config, :workflow_module_ids)
    workflow_modules_product_visual_review = Keyword.get(config, :workflow_modules_product_visual_review)
    prompt = Keyword.get(config, :prompt)

    runtime_sections =
      [
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_id: #{yaml_value(tracker_project_id)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  team_key: #{yaml_value(tracker_team_key)}",
        "  workspace_slug: #{yaml_value(tracker_workspace_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  required_labels: #{yaml_value(tracker_required_labels)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        target && "target: #{yaml_value(target)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host, worker_max_concurrent_startups_per_host),
        "agent:",
        "  default_runner: #{yaml_value(default_runner)}",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_concurrent_startups: #{yaml_value(max_concurrent_startups)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "runners:",
        "  codex:",
        "    kind: #{yaml_value(runner_kind)}",
        "    command: #{yaml_value(runner_command)}",
        "    model: #{yaml_value(codex_model)}",
        "    approval_policy: #{yaml_value(codex_approval_policy)}",
        "    thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "    turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "    turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "    read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "    stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        "    max_concurrent_startups: #{yaml_value(runner_max_concurrent_startups)}",
        "quality_gate:",
        "  enabled: #{yaml_value(quality_gate_enabled)}",
        "  source_max_concurrency: #{yaml_value(quality_gate_source_max_concurrency)}",
        "  max_repair_passes: #{yaml_value(quality_gate_max_repair_passes)}",
        "  runtime_isolation: #{yaml_value(quality_gate_runtime_isolation)}",
        "  reviewer_timeout_ms: #{yaml_value(quality_gate_reviewer_timeout_ms)}",
        "  reviewer_max_retries: #{yaml_value(quality_gate_reviewer_max_retries)}",
        "profiles: #{yaml_value(profiles)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    sections =
      [
        "project:",
        "  slug: #{yaml_value(tracker_project_slug)}",
        "  name: #{yaml_value("project")}",
        "  repository: #{yaml_value(project_repository)}",
        "delivery:",
        "  pr_target: #{yaml_value(delivery_pr_target)}",
        "issue_markers: #{yaml_value(issue_markers)}",
        workflow_yaml(workflow_module_ids, workflow_modules_product_visual_review),
        "harness:",
        "  codex_home: #{yaml_value(harness_codex_home)}",
        "runtime:",
        indent_block(Enum.join(runtime_sections, "\n"), 2),
        prompt_template_yaml(prompt)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp command_argv(nil), do: nil
  defp command_argv(command) when is_list(command), do: command

  defp command_argv(command) when is_binary(command) do
    case SymphonyElixir.Shell.split(command) do
      {:ok, argv} -> argv
      {:error, _reason} -> command
    end
  end

  defp command_argv(command), do: command

  defp workflow_yaml(module_ids, nil) when module_ids in [nil, []] do
    "workflow:\n  preset: \"default\""
  end

  defp workflow_yaml(module_ids, product_visual_review) when module_ids in [nil, []] and is_map(product_visual_review) do
    workflow_yaml([], product_visual_review)
  end

  defp workflow_yaml(module_ids, product_visual_review) when is_list(module_ids) do
    [
      "workflow:",
      "  preset: \"default\"",
      module_ids != [] && "  modules:",
      Enum.map(module_ids, &"    - #{yaml_value(&1)}"),
      workflow_module_config_yaml(product_visual_review)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms) do
    "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}\n  after_create: null"
  end

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host, max_concurrent_startups_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host) and
              is_nil(max_concurrent_startups_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host, max_concurrent_startups_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}",
      !is_nil(max_concurrent_startups_per_host) &&
        "  max_concurrent_startups_per_host: #{yaml_value(max_concurrent_startups_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp workflow_module_config_yaml(nil), do: nil

  defp workflow_module_config_yaml(product_visual_review) when is_map(product_visual_review) do
    [
      "  config:",
      "    product_visual_review: #{yaml_value(product_visual_review)}"
    ]
    |> Enum.join("\n")
  end

  defp hook_entry("after_create", nil), do: "  after_create: null"
  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end

  defp prompt_template_yaml(nil), do: nil

  defp prompt_template_yaml(prompt) when is_binary(prompt) do
    "prompt_template: |\n" <> indent_block(prompt, 2)
  end

  defp indent_block(text, spaces) when is_binary(text) do
    prefix = String.duplicate(" ", spaces)

    text
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", &(prefix <> &1))
  end
end
