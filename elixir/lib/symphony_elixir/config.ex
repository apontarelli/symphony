defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `symphony.yml`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workflow.Manifest
  alias SymphonyElixir.Workflow.ModuleRegistry

  @profile_override_env_key :workflow_profile_override

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case selected_workflow_config() do
      {:ok, config} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Manifest.read(Workflow.selected_workflow_file_path()) do
      {:ok, %{"prompt_template" => prompt}} when is_binary(prompt) ->
        if String.trim(prompt) == "", do: default_prompt_template(), else: prompt

      _ ->
        default_prompt_template()
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec log_file(Path.t()) :: Path.t()
  def log_file(default) when is_binary(default) do
    Application.get_env(:symphony_elixir, :log_file, default)
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, config} <- selected_workflow_config(),
         {:ok, settings} <- Schema.parse(config),
         :ok <- validate_semantics(settings) do
      validate_profile_override(settings)
    end
  end

  @spec effective_policy(String.t() | atom() | nil) :: {:ok, map()} | {:error, term()}
  def effective_policy(profile_ref \\ "default") do
    with {:ok, settings} <- settings() do
      Schema.resolve_effective_policy(settings, profile_ref)
    end
  end

  @spec issue_policy(Issue.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue_policy(%Issue{} = issue, opts \\ []) do
    with {:ok, settings} <- settings() do
      profile = normalized_string(Keyword.get(opts, :profile_override) || profile_override()) || "default"

      Schema.resolve_effective_policy(settings, profile, [],
        metadata: %{
          source: policy_source(profile),
          profile: profile,
          project_id: issue.project_id,
          project_slug: issue.project_slug
        }
      )
    end
  end

  @spec set_profile_override(String.t() | nil) :: :ok
  def set_profile_override(nil), do: clear_profile_override()

  def set_profile_override(profile) when is_binary(profile) do
    Application.put_env(:symphony_elixir, @profile_override_env_key, profile)
    :ok
  end

  @spec clear_profile_override() :: :ok
  def clear_profile_override do
    Application.delete_env(:symphony_elixir, @profile_override_env_key)
    :ok
  end

  @spec profile_override() :: String.t() | nil
  def profile_override do
    Application.get_env(:symphony_elixir, @profile_override_env_key)
    |> normalized_string()
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      runner_name = Schema.default_runner_name(settings)
      runner = Schema.default_runner_config!(settings)

      with {:ok, runner_policy_overrides} <- policy_runner_overrides(Keyword.get(opts, :policy), runner_name),
           {:ok, turn_sandbox_policy} <-
             runtime_turn_sandbox_policy(settings, workspace, opts, runner_policy_overrides),
           {:ok, approval_policy} <- runtime_approval_policy(runner["approval_policy"], runner_policy_overrides),
           {:ok, thread_sandbox} <- runtime_thread_sandbox(runner["thread_sandbox"], runner_policy_overrides) do
        {:ok,
         %{
           approval_policy: approval_policy,
           thread_sandbox: thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  @spec default_runner!() :: map()
  def default_runner!, do: settings!() |> Schema.default_runner_config!()

  @spec default_runner!(Schema.t()) :: map()
  def default_runner!(%Schema{} = settings), do: Schema.default_runner_config!(settings)

  @spec default_runner_name() :: String.t()
  def default_runner_name, do: settings!() |> Schema.default_runner_name()

  @spec runner_turn_timeout_ms() :: pos_integer()
  def runner_turn_timeout_ms do
    case default_runner!()["turn_timeout_ms"] do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _timeout -> 3_600_000
    end
  end

  @spec runner_read_timeout_ms() :: pos_integer()
  def runner_read_timeout_ms do
    case default_runner!()["read_timeout_ms"] do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _timeout -> 30_000
    end
  end

  @spec runner_stall_timeout_ms() :: non_neg_integer()
  def runner_stall_timeout_ms do
    case default_runner!()["stall_timeout_ms"] do
      timeout when is_integer(timeout) and timeout >= 0 -> timeout
      _timeout -> 300_000
    end
  end

  @spec max_concurrent_startups() :: pos_integer()
  def max_concurrent_startups do
    settings = settings!()
    runner = Schema.default_runner_config!(settings)

    [
      settings.agent.max_concurrent_startups,
      runner["max_concurrent_startups"]
    ]
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> case do
      [] -> settings.agent.max_concurrent_agents
      limits -> Enum.min(limits)
    end
  end

  defp policy_runner_overrides(nil, _runner_name), do: {:ok, %{}}

  defp policy_runner_overrides(%{"codex" => codex}, _runner_name), do: {:error, {:invalid_policy_legacy_codex, codex}}
  defp policy_runner_overrides(%{codex: codex}, _runner_name), do: {:error, {:invalid_policy_legacy_codex, codex}}

  defp policy_runner_overrides(%{"runners" => runners}, runner_name) when is_map(runners) do
    case Map.get(runners, runner_name) do
      runner when is_map(runner) -> {:ok, normalize_map_keys(runner)}
      nil -> {:ok, %{}}
      runner -> {:error, {:invalid_policy_runner, runner_name, runner}}
    end
  end

  defp policy_runner_overrides(%{runners: runners}, runner_name) when is_map(runners) do
    policy_runner_overrides(%{"runners" => normalize_map_keys(runners)}, runner_name)
  end

  defp policy_runner_overrides(%{"runners" => runners}, _runner_name), do: {:error, {:invalid_policy_runners, runners}}
  defp policy_runner_overrides(%{runners: runners}, _runner_name), do: {:error, {:invalid_policy_runners, runners}}
  defp policy_runner_overrides(policy, _runner_name) when is_map(policy), do: {:ok, %{}}
  defp policy_runner_overrides(_policy, _runner_name), do: {:ok, %{}}

  defp runtime_turn_sandbox_policy(settings, workspace, opts, runner_policy_overrides) do
    case Map.fetch(runner_policy_overrides, "turn_sandbox_policy") do
      {:ok, %{} = policy} -> {:ok, normalize_map_keys(policy)}
      {:ok, nil} -> Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts)
      {:ok, policy} -> {:error, {:invalid_policy_runner_turn_sandbox_policy, policy}}
      :error -> Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts)
    end
  end

  defp runtime_approval_policy(default_approval_policy, runner_policy_overrides) do
    case Map.fetch(runner_policy_overrides, "approval_policy") do
      {:ok, value} when is_binary(value) or is_map(value) -> {:ok, normalize_map_keys(value)}
      {:ok, value} -> {:error, {:invalid_policy_runner_approval_policy, value}}
      :error -> {:ok, default_approval_policy}
    end
  end

  defp runtime_thread_sandbox(default_thread_sandbox, runner_policy_overrides) do
    case Map.fetch(runner_policy_overrides, "thread_sandbox") do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_policy_runner_thread_sandbox, value}}
      :error -> {:ok, default_thread_sandbox}
    end
  end

  defp normalize_map_keys(value) when is_map(value) do
    Map.new(value, fn {key, field_value} -> {to_string(key), normalize_map_keys(field_value)} end)
  end

  defp normalize_map_keys(value) when is_list(value), do: Enum.map(value, &normalize_map_keys/1)
  defp normalize_map_keys(value), do: value

  @spec format_error(term()) :: String.t()
  def format_error(:missing_linear_api_token), do: "Linear API token missing in selected workflow config"

  def format_error(:missing_linear_project_scope),
    do: "Linear project_id, project_slug, or team_key missing in selected workflow config"

  def format_error(:missing_tracker_kind), do: "Tracker kind missing in selected workflow config"

  def format_error({:unsupported_tracker_kind, kind}),
    do: "Unsupported tracker kind in selected workflow config: #{inspect(kind)}"

  def format_error({:invalid_workflow_config, message}), do: "Invalid selected workflow config: #{message}"

  def format_error({:manifest_parse_error, raw_reason}), do: "Failed to parse symphony.yml: #{inspect(raw_reason)}"

  def format_error({:invalid_manifest, diagnostics}),
    do: "Invalid symphony.yml manifest: #{format_manifest_diagnostics(diagnostics)}"

  def format_error({:missing_manifest_file, path, raw_reason}),
    do: "Missing symphony.yml at #{path}: #{inspect(raw_reason)}"

  def format_error({:unknown_workflow_profile_override, profile, reason}),
    do: "Invalid workflow profile override profile=#{inspect(profile)} reason=#{inspect(reason)}"

  def format_error(other), do: "Invalid workflow config: #{inspect(other)}"

  @spec config_error?(term()) :: boolean()
  def config_error?(:missing_linear_api_token), do: true
  def config_error?(:missing_linear_project_scope), do: true
  def config_error?(:missing_tracker_kind), do: true
  def config_error?({:unsupported_tracker_kind, _kind}), do: true
  def config_error?({:invalid_workflow_config, _message}), do: true
  def config_error?({:manifest_parse_error, _reason}), do: true
  def config_error?({:invalid_manifest, _diagnostics}), do: true
  def config_error?({:missing_manifest_file, _path, _reason}), do: true
  def config_error?({:unknown_workflow_profile_override, _profile, _reason}), do: true
  def config_error?(_reason), do: false

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not linear_scope_configured?(settings.tracker) ->
        {:error, :missing_linear_project_scope}

      true ->
        :ok
    end
  end

  defp linear_scope_configured?(tracker) do
    is_binary(tracker.project_id) or is_binary(tracker.project_slug) or is_binary(tracker.team_key)
  end

  defp selected_workflow_config do
    case Workflow.load(Workflow.selected_workflow_file_path()) do
      {:ok, %{config: config}} ->
        {:ok, config}

      {:error, {:invalid_manifest, diagnostics}} ->
        {:error, {:invalid_workflow_config, format_manifest_diagnostics(diagnostics)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_profile_override(settings) do
    case profile_override() do
      nil ->
        :ok

      profile ->
        case Schema.resolve_effective_policy(settings, profile) do
          {:ok, _policy} -> :ok
          {:error, reason} -> {:error, {:unknown_workflow_profile_override, profile, reason}}
        end
    end
  end

  defp policy_source("default"), do: "default_profile"
  defp policy_source(_profile), do: "profile_override"

  defp normalized_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_string(_value), do: nil

  defp default_prompt_template do
    case ModuleRegistry.compile_default_preset() do
      {:ok, prompt} ->
        prompt

      {:error, reason} ->
        raise ArgumentError, message: "Invalid default workflow module preset: #{inspect(reason)}"
    end
  end

  defp format_manifest_diagnostics(diagnostics) when is_list(diagnostics) do
    Enum.map_join(diagnostics, ", ", fn
      %{path: path, message: message} -> "#{path} #{message}"
      diagnostic when is_binary(diagnostic) -> diagnostic
    end)
  end
end
