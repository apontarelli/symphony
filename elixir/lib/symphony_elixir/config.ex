defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `symphony.yml`.
  """

  alias SymphonyElixir.Config.ProfileBindings
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workflow.ModuleRegistry

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
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
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
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

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      with :ok <- validate_semantics(settings) do
        ProfileBindings.validate(settings, ProfileBindings.current())
      end
    end
  end

  @spec effective_policy(String.t() | atom() | nil) :: {:ok, map()} | {:error, term()}
  def effective_policy(profile_ref \\ "default") do
    with {:ok, settings} <- settings() do
      Schema.resolve_effective_policy(settings, profile_ref)
    end
  end

  @spec issue_policy(Issue.t(), keyword()) :: {:ok, map()} | {:skip, term()} | {:error, term()}
  def issue_policy(%Issue{} = issue, opts \\ []) do
    with {:ok, settings} <- settings() do
      ProfileBindings.select_policy(settings, issue, ProfileBindings.current(), opts)
    end
  end

  @spec linear_profile_bindings() :: ProfileBindings.binding_config()
  def linear_profile_bindings do
    ProfileBindings.current()
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, codex_policy_overrides} <- policy_codex_overrides(Keyword.get(opts, :policy)),
           {:ok, turn_sandbox_policy} <-
             runtime_turn_sandbox_policy(settings, workspace, opts, codex_policy_overrides),
           {:ok, approval_policy} <- runtime_approval_policy(settings.codex.approval_policy, codex_policy_overrides),
           {:ok, thread_sandbox} <- runtime_thread_sandbox(settings.codex.thread_sandbox, codex_policy_overrides) do
        {:ok,
         %{
           approval_policy: approval_policy,
           thread_sandbox: thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp policy_codex_overrides(nil), do: {:ok, %{}}

  defp policy_codex_overrides(%{"codex" => codex}) when is_map(codex), do: {:ok, normalize_map_keys(codex)}
  defp policy_codex_overrides(%{codex: codex}) when is_map(codex), do: {:ok, normalize_map_keys(codex)}

  defp policy_codex_overrides(%{"codex" => nil}), do: {:ok, %{}}
  defp policy_codex_overrides(%{codex: nil}), do: {:ok, %{}}

  defp policy_codex_overrides(%{"codex" => codex}), do: {:error, {:invalid_policy_codex, codex}}
  defp policy_codex_overrides(%{codex: codex}), do: {:error, {:invalid_policy_codex, codex}}
  defp policy_codex_overrides(policy) when is_map(policy), do: {:ok, %{}}
  defp policy_codex_overrides(_policy), do: {:ok, %{}}

  defp runtime_turn_sandbox_policy(settings, workspace, opts, codex_policy_overrides) do
    case Map.fetch(codex_policy_overrides, "turn_sandbox_policy") do
      {:ok, %{} = policy} -> {:ok, normalize_map_keys(policy)}
      {:ok, nil} -> Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts)
      {:ok, policy} -> {:error, {:invalid_policy_codex_turn_sandbox_policy, policy}}
      :error -> Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts)
    end
  end

  defp runtime_approval_policy(default_approval_policy, codex_policy_overrides) do
    case Map.fetch(codex_policy_overrides, "approval_policy") do
      {:ok, value} when is_binary(value) or is_map(value) -> {:ok, normalize_map_keys(value)}
      {:ok, value} -> {:error, {:invalid_policy_codex_approval_policy, value}}
      :error -> {:ok, default_approval_policy}
    end
  end

  defp runtime_thread_sandbox(default_thread_sandbox, codex_policy_overrides) do
    case Map.fetch(codex_policy_overrides, "thread_sandbox") do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_policy_codex_thread_sandbox, value}}
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

  def format_error(:missing_linear_project_slug), do: "Linear project slug missing in selected workflow config"

  def format_error(:missing_tracker_kind), do: "Tracker kind missing in selected workflow config"

  def format_error({:unsupported_tracker_kind, kind}),
    do: "Unsupported tracker kind in selected workflow config: #{inspect(kind)}"

  def format_error({:invalid_workflow_config, message}), do: "Invalid selected workflow config: #{message}"

  def format_error({:manifest_parse_error, raw_reason}), do: "Failed to parse symphony.yml: #{inspect(raw_reason)}"

  def format_error({:invalid_manifest, diagnostics}),
    do: "Invalid symphony.yml manifest: #{format_manifest_diagnostics(diagnostics)}"

  def format_error({:missing_manifest_file, path, raw_reason}),
    do: "Missing symphony.yml at #{path}: #{inspect(raw_reason)}"

  def format_error({:invalid_linear_profile_bindings, message}), do: "Invalid Linear profile bindings: #{message}"

  def format_error({:unknown_linear_profile_binding, source, profile, reason}),
    do: "Invalid Linear profile binding source=#{inspect(source)} profile=#{inspect(profile)} reason=#{inspect(reason)}"

  def format_error(:missing_linear_catch_all_team_selector),
    do: "Linear catch-all profile binding requires external team_id or team_key"

  def format_error(other), do: "Invalid workflow config: #{inspect(other)}"

  @spec config_error?(term()) :: boolean()
  def config_error?(:missing_linear_api_token), do: true
  def config_error?(:missing_linear_project_slug), do: true
  def config_error?(:missing_tracker_kind), do: true
  def config_error?({:unsupported_tracker_kind, _kind}), do: true
  def config_error?({:invalid_workflow_config, _message}), do: true
  def config_error?({:manifest_parse_error, _reason}), do: true
  def config_error?({:invalid_manifest, _diagnostics}), do: true
  def config_error?({:missing_manifest_file, _path, _reason}), do: true
  def config_error?({:invalid_linear_profile_bindings, _message}), do: true
  def config_error?({:unknown_linear_profile_binding, _source, _profile, _reason}), do: true
  def config_error?(:missing_linear_catch_all_team_selector), do: true
  def config_error?(_reason), do: false

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and
        not is_binary(settings.tracker.project_slug) and
          not ProfileBindings.dispatch_scope_configured?(ProfileBindings.current()) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

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
