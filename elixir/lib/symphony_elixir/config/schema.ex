defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Workflow.PublishTarget

  @primary_key false
  @policy_ref_length 12
  @profile_policy_ref_key "policy_ref"
  @profile_policy_metadata_key "policy_metadata"
  @reserved_profile_policy_keys MapSet.new([@profile_policy_ref_key, @profile_policy_metadata_key])
  @delivery_pr_target_key "pr_target"
  @delivery_v1_fields MapSet.new([@delivery_pr_target_key])
  @profile_runner_v1_fields MapSet.new(["approval_policy", "thread_sandbox", "turn_sandbox_policy"])
  @runner_v1_fields MapSet.new([
                      "kind",
                      "command",
                      "model",
                      "approval_policy",
                      "thread_sandbox",
                      "turn_sandbox_policy",
                      "turn_timeout_ms",
                      "read_timeout_ms",
                      "stall_timeout_ms",
                      "execution_profiles",
                      "max_concurrent_startups"
                    ])
  @default_runner_name "codex"
  @supported_runner_kinds MapSet.new(["codex_app_server"])
  @default_runner_config %{
    "kind" => "codex_app_server",
    "command" => ["codex", "app-server"],
    "model" => "gpt-5.6-sol",
    "approval_policy" => "never",
    "thread_sandbox" => "workspace-write",
    "turn_timeout_ms" => 3_600_000,
    "read_timeout_ms" => 30_000,
    "stall_timeout_ms" => 300_000,
    "execution_profiles" => %{}
  }
  @default_runners %{@default_runner_name => @default_runner_config}

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_id, :string)
      field(:project_slug, :string)
      field(:team_key, :string)
      field(:workspace_slug, :string)
      field(:assignee, :string)
      field(:issue_ids, {:array, :string}, default: [])
      field(:query, :string)
      field(:query_file, :string)
      field(:required_labels, {:array, :string}, default: [])
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress", "Merging", "Rework"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_key,
          :project_id,
          :project_slug,
          :team_key,
          :workspace_slug,
          :assignee,
          :issue_ids,
          :query,
          :query_file,
          :required_labels,
          :active_states,
          :terminal_states
        ],
        empty_values: []
      )
      |> update_change(:required_labels, fn labels ->
        labels
        |> Enum.map(&(String.trim(&1) |> String.downcase()))
        |> Enum.uniq()
      end)
      |> update_change(:issue_ids, fn ids ->
        ids
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
      end)
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
      field(:max_concurrent_startups_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host, :max_concurrent_startups_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
      |> validate_number(:max_concurrent_startups_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:default_runner, :string, default: "codex")
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_concurrent_startups, :integer, default: 2)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :default_runner,
          :max_concurrent_agents,
          :max_concurrent_startups,
          :max_turns,
          :max_retry_backoff_ms,
          :max_concurrent_agents_by_state
        ],
        empty_values: []
      )
      |> update_change(:default_runner, &normalize_runner_name/1)
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_concurrent_startups, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end

    defp normalize_runner_name(value) when is_binary(value) do
      value
      |> String.trim()
      |> case do
        "" -> nil
        runner -> runner
      end
    end
  end

  defmodule Codex do
    @moduledoc false
    defstruct command: "codex app-server",
              model: "gpt-5.6-sol",
              approval_policy: "never",
              thread_sandbox: "workspace-write",
              turn_sandbox_policy: nil,
              turn_timeout_ms: 3_600_000,
              read_timeout_ms: 30_000,
              stall_timeout_ms: 300_000,
              execution_profiles: %{}
  end

  defmodule QualityGate do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    @runtime_isolation_modes ~w(serialized isolated_workspace blocked)

    defmodule HostVisualQa do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false

      embedded_schema do
        field(:enabled, :boolean, default: true)
        field(:command, :string)
        field(:timeout_ms, :integer, default: 300_000)
        field(:artifact_root, :string)
      end

      @type t :: %__MODULE__{
              enabled: boolean(),
              command: String.t() | nil,
              timeout_ms: pos_integer(),
              artifact_root: String.t() | nil
            }

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:enabled, :command, :timeout_ms, :artifact_root], empty_values: [])
        |> update_change(:command, &normalize_optional_string/1)
        |> update_change(:artifact_root, &normalize_optional_string/1)
        |> validate_number(:timeout_ms, greater_than: 0)
      end

      defp normalize_optional_string(value) when is_binary(value) do
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end
      end
    end

    embedded_schema do
      field(:enabled, :boolean, default: true)
      field(:source_max_concurrency, :integer, default: 3)
      field(:max_repair_passes, :integer, default: 1)
      field(:runtime_isolation, :string, default: "serialized")
      field(:reviewer_timeout_ms, :integer, default: 1_200_000)
      field(:reviewer_max_retries, :integer, default: 0)
      field(:path_classification, :map, default: %{})
      embeds_one(:host_visual_qa, HostVisualQa, on_replace: :update, defaults_to_struct: true)
    end

    @type t :: %__MODULE__{
            enabled: boolean(),
            source_max_concurrency: pos_integer(),
            max_repair_passes: non_neg_integer(),
            runtime_isolation: String.t(),
            reviewer_timeout_ms: pos_integer(),
            reviewer_max_retries: non_neg_integer(),
            path_classification: map(),
            host_visual_qa: HostVisualQa.t()
          }

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :source_max_concurrency,
          :max_repair_passes,
          :runtime_isolation,
          :reviewer_timeout_ms,
          :reviewer_max_retries,
          :path_classification
        ],
        empty_values: []
      )
      |> cast_embed(:host_visual_qa, with: &HostVisualQa.changeset/2)
      |> update_change(:runtime_isolation, &normalize_runtime_isolation/1)
      |> validate_number(:source_max_concurrency, greater_than: 0)
      |> validate_number(:max_repair_passes, greater_than_or_equal_to: 0)
      |> validate_number(:reviewer_timeout_ms, greater_than: 0)
      |> validate_number(:reviewer_max_retries, greater_than_or_equal_to: 0)
      |> validate_inclusion(:runtime_isolation, @runtime_isolation_modes)
    end

    defp normalize_runtime_isolation(value) when is_binary(value) do
      value
      |> String.trim()
      |> String.downcase()
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Project do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    @criticalities ~w(local prototype internal production)
    @deployment_couplings ~w(none local preview staging production production_web)

    embedded_schema do
      field(:criticality, :string, default: "internal")
      field(:deployment_coupling, :string, default: "local")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:criticality, :deployment_coupling], empty_values: [])
      |> update_change(:criticality, &normalize_token/1)
      |> update_change(:deployment_coupling, &normalize_token/1)
      |> validate_inclusion(:criticality, @criticalities)
      |> validate_inclusion(:deployment_coupling, @deployment_couplings)
    end

    defp normalize_token(value) when is_binary(value) do
      value
      |> String.trim()
      |> String.downcase()
    end
  end

  defmodule AutoLand do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    @postures ~w(off permissive strict)
    @default_force_human_review_labels ~w(force-human-review human-review manual-review no-auto-land)

    embedded_schema do
      field(:posture, :string)
      field(:required_checks, {:array, :string}, default: [])
      field(:force_human_review_labels, {:array, :string}, default: @default_force_human_review_labels)
      field(:blocked_state, :string, default: "Human Review")
      field(:dry_run, :boolean, default: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :posture,
          :required_checks,
          :force_human_review_labels,
          :blocked_state,
          :dry_run
        ],
        empty_values: []
      )
      |> update_change(:posture, &normalize_optional_token/1)
      |> update_change(:required_checks, &normalize_token_list/1)
      |> update_change(:force_human_review_labels, &normalize_token_list/1)
      |> validate_posture()
    end

    defp validate_posture(changeset) do
      validate_change(changeset, :posture, fn
        :posture, posture ->
          if posture in @postures do
            []
          else
            [posture: "is invalid"]
          end
      end)
    end

    defp normalize_optional_token(nil), do: nil

    defp normalize_optional_token(value) when is_binary(value) do
      value
      |> String.trim()
      |> String.downcase()
      |> case do
        "" -> nil
        normalized -> normalized
      end
    end

    defp normalize_token_list(values) when is_list(values) do
      values
      |> Enum.map(&normalize_optional_token/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  defmodule IssueMarkers do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset
    alias SymphonyElixir.RunTarget.RepoMarkers, as: RunTargetRepoMarkers

    @primary_key false

    embedded_schema do
      field(:labels, {:array, :string}, default: [])
      field(:allowed_projects, {:array, :string}, default: [])
    end

    @type t :: %__MODULE__{
            labels: [String.t()],
            allowed_projects: [String.t()]
          }

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:labels, :allowed_projects], empty_values: [])
      |> update_change(:labels, &RunTargetRepoMarkers.normalize_labels/1)
      |> update_change(:allowed_projects, &RunTargetRepoMarkers.normalize_projects/1)
    end
  end

  defmodule WorkflowModules do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.WorkflowModules.ProductVisualReview.Config, as: ProductVisualReview

    @primary_key false

    @type t :: %__MODULE__{
            product_visual_review: ProductVisualReview.t()
          }

    embedded_schema do
      embeds_one(:product_visual_review, ProductVisualReview, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [])
      |> cast_embed(:product_visual_review, with: &ProductVisualReview.changeset/2)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:project, Project, on_replace: :update, defaults_to_struct: true)
    embeds_one(:auto_land, AutoLand, on_replace: :update, defaults_to_struct: true)
    embeds_one(:quality_gate, QualityGate, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:issue_markers, IssueMarkers, on_replace: :update, defaults_to_struct: true)
    field(:target, :map)
    field(:runners, :map, default: @default_runners)
    field(:profiles, :map, default: %{})
    field(:policy_metadata, :map, default: %{})
    embeds_one(:workflow_modules, WorkflowModules, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> reject_legacy_codex_config()
    |> case do
      {:ok, config} -> validate_config(config)
      {:error, message} -> {:error, {:invalid_workflow_config, message}}
    end
  end

  defp validate_config(config) do
    config
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_effective_policy(%__MODULE__{}, String.t() | atom() | nil) ::
          {:ok, map()} | {:error, term()}
  def resolve_effective_policy(settings, profile_ref \\ "default") do
    resolve_effective_policy(settings, profile_ref, [], [])
  end

  @spec resolve_effective_policy(%__MODULE__{}, String.t() | atom() | nil, [String.t() | atom()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_effective_policy(settings, profile_ref, refinement_refs, opts)
      when is_list(refinement_refs) and is_list(opts) do
    with {:ok, profile_name} <- normalize_profile_reference(profile_ref),
         {:ok, refinement_names} <- normalize_refinement_references(refinement_refs),
         {:ok, policy} <- resolve_profile_policy(settings.profiles, profile_name, refinement_names, opts) do
      metadata =
        settings.policy_metadata
        |> normalize_policy_metadata()
        |> Map.merge(Keyword.get(opts, :metadata, %{}) |> normalize_policy_metadata())

      finalized_policy = put_resolved_publish_target(policy)

      finalized_policy
      |> Map.put(@profile_policy_ref_key, policy_ref(finalized_policy))
      |> put_policy_metadata(metadata)
      |> then(&{:ok, &1})
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case default_runner_config!(settings)["turn_sandbox_policy"] do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case default_runner_config!(settings)["turn_sandbox_policy"] do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:runners, :profiles, :policy_metadata, :target])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:project, with: &Project.changeset/2)
    |> cast_embed(:auto_land, with: &AutoLand.changeset/2)
    |> cast_embed(:quality_gate, with: &QualityGate.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:issue_markers, with: &IssueMarkers.changeset/2)
    |> cast_embed(:workflow_modules, with: &WorkflowModules.changeset/2)
    |> update_change(:runners, &normalize_runner_map/1)
    |> validate_runners()
    |> validate_default_runner()
    |> validate_profiles()
  end

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    %{settings | tracker: tracker, workspace: workspace, runners: normalize_runner_map(settings.runners)}
  end

  @spec default_runner_config(%__MODULE__{}) :: {:ok, map()} | {:error, term()}
  def default_runner_config(%__MODULE__{} = settings) do
    runner_name = default_runner_name(settings)

    case Map.fetch(settings.runners || %{}, runner_name) do
      {:ok, runner} when is_map(runner) -> {:ok, runner}
      _ -> {:error, {:unknown_default_runner, runner_name}}
    end
  end

  @spec default_runner_config!(%__MODULE__{}) :: map()
  def default_runner_config!(%__MODULE__{} = settings) do
    case default_runner_config(settings) do
      {:ok, runner} -> runner
      {:error, reason} -> raise ArgumentError, message: "Invalid default runner config: #{inspect(reason)}"
    end
  end

  @spec default_runner_name(%__MODULE__{}) :: String.t()
  def default_runner_name(%__MODULE__{agent: %{default_runner: runner_name}})
      when is_binary(runner_name) and runner_name != "",
      do: runner_name

  def default_runner_name(%__MODULE__{}), do: @default_runner_name

  @spec default_runners() :: map()
  def default_runners, do: @default_runners

  @doc false
  @spec codex_action_approval_policy_error(term()) :: :on_request | :invalid_type | nil
  def codex_action_approval_policy_error(value) when is_binary(value) do
    case String.trim(value) do
      "on-request" -> :on_request
      _policy -> nil
    end
  end

  def codex_action_approval_policy_error(value) when is_map(value) do
    if Map.has_key?(normalize_keys(value), "on-request"), do: :on_request
  end

  def codex_action_approval_policy_error(_value), do: :invalid_type

  defp reject_legacy_codex_config(%{"codex" => _config}) do
    {:error, "runtime.codex is not supported; use runtime.runners.<name> (for Codex use runtime.runners.codex)"}
  end

  defp reject_legacy_codex_config(config), do: {:ok, config}

  defp normalize_runner_map(runners) when runners == %{}, do: @default_runners

  defp normalize_runner_map(runners) when is_map(runners) do
    Map.new(runners, fn {name, runner} ->
      runner_name = normalize_runner_map_key(name)
      {runner_name, normalize_runner_config(runner_name, runner)}
    end)
  end

  defp normalize_runner_map_key(name) do
    name
    |> to_string()
    |> String.trim()
  end

  defp normalize_runner_config(name, runner) when is_map(runner) do
    @default_runner_config
    |> Map.put("kind", default_kind_for_runner(name))
    |> Map.merge(normalize_keys(runner))
    |> update_runner_optional_map("approval_policy")
    |> update_runner_optional_map("turn_sandbox_policy")
  end

  defp normalize_runner_config(_name, runner), do: runner

  defp default_kind_for_runner(@default_runner_name), do: "codex_app_server"
  defp default_kind_for_runner(_runner_name), do: nil

  defp update_runner_optional_map(runner, key) do
    case Map.get(runner, key) do
      %{} = value -> Map.put(runner, key, normalize_keys(value))
      _value -> runner
    end
  end

  defp validate_runners(%{valid?: false} = changeset), do: changeset

  defp validate_runners(changeset) do
    changeset
    |> get_field(:runners)
    |> runner_validation_errors()
    |> Enum.reduce(changeset, fn message, acc -> add_error(acc, :runners, message) end)
  end

  defp validate_default_runner(%{valid?: false} = changeset), do: changeset

  defp validate_default_runner(changeset) do
    runner_name = get_field(changeset, :agent).default_runner
    runners = get_field(changeset, :runners) || %{}

    cond do
      not is_binary(runner_name) or runner_name == "" ->
        add_error(changeset, :agent, "runtime.agent.default_runner is required")

      Map.has_key?(runners, runner_name) ->
        changeset

      true ->
        add_error(changeset, :agent, "runtime.agent.default_runner #{inspect(runner_name)} must reference runtime.runners.#{runner_name}")
    end
  end

  defp runner_validation_errors(runners) when is_map(runners) do
    runners
    |> Enum.flat_map(fn {name, runner} -> runner_validation_errors(to_string(name), runner) end)
  end

  defp runner_validation_errors("", _runner), do: ["runtime.runners runner names must not be blank"]

  defp runner_validation_errors(name, runner) when is_map(runner) do
    unsupported =
      runner
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(@runner_v1_fields, &1))
      |> Enum.sort()
      |> Enum.map(fn field -> "runtime.runners.#{name}.#{field} is not supported in v1" end)

    [
      validate_runner_kind(name, Map.get(runner, "kind")),
      validate_runner_command(name, Map.get(runner, "command")),
      validate_runner_string(name, "model", Map.get(runner, "model")),
      validate_runner_approval_policy(name, Map.get(runner, "approval_policy")),
      validate_runner_string(name, "thread_sandbox", Map.get(runner, "thread_sandbox")),
      validate_runner_map(name, "turn_sandbox_policy", Map.get(runner, "turn_sandbox_policy")),
      validate_runner_positive_integer(name, "turn_timeout_ms", Map.get(runner, "turn_timeout_ms")),
      validate_runner_positive_integer(name, "read_timeout_ms", Map.get(runner, "read_timeout_ms")),
      validate_runner_non_negative_integer(name, "stall_timeout_ms", Map.get(runner, "stall_timeout_ms")),
      validate_runner_map(name, "execution_profiles", Map.get(runner, "execution_profiles")),
      validate_runner_positive_integer(name, "max_concurrent_startups", Map.get(runner, "max_concurrent_startups"))
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(unsupported)
  end

  defp runner_validation_errors(name, _runner), do: ["runtime.runners.#{name} must be a map"]

  defp validate_runner_kind(name, value) when is_binary(value) do
    kind = String.trim(value)

    cond do
      kind == "" ->
        "runtime.runners.#{name}.kind is required"

      MapSet.member?(@supported_runner_kinds, kind) ->
        nil

      true ->
        "runtime.runners.#{name}.kind #{inspect(kind)} is not supported; supported kinds: codex_app_server"
    end
  end

  defp validate_runner_kind(name, _value), do: "runtime.runners.#{name}.kind must be a string"

  defp validate_runner_command(name, values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.find_value(fn
      {value, index} when is_binary(value) ->
        if String.trim(value) == "", do: "runtime.runners.#{name}.command[#{index}] must be a non-empty string"

      {_value, index} ->
        "runtime.runners.#{name}.command[#{index}] must be a non-empty string"
    end)
    |> case do
      nil -> if values == [], do: "runtime.runners.#{name}.command is required"
      message -> message
    end
  end

  defp validate_runner_command(name, _value), do: "runtime.runners.#{name}.command must be a list"

  defp validate_runner_approval_policy(name, value) do
    format_codex_action_approval_policy_error("runtime.runners.#{name}.approval_policy", value)
  end

  defp format_codex_action_approval_policy_error(path, value) do
    case codex_action_approval_policy_error(value) do
      :on_request -> "#{path} on-request is not supported; Symphony agents are unattended"
      :invalid_type -> "#{path} must be a string or map"
      nil -> nil
    end
  end

  defp validate_runner_string(_name, _field, value) when is_binary(value), do: nil
  defp validate_runner_string(name, field, _value), do: "runtime.runners.#{name}.#{field} must be a string"

  defp validate_runner_map(_name, _field, nil), do: nil
  defp validate_runner_map(_name, _field, value) when is_map(value), do: nil
  defp validate_runner_map(name, field, _value), do: "runtime.runners.#{name}.#{field} must be a map"

  defp validate_runner_positive_integer(_name, _field, nil), do: nil
  defp validate_runner_positive_integer(_name, _field, value) when is_integer(value) and value > 0, do: nil

  defp validate_runner_positive_integer(name, field, _value),
    do: "runtime.runners.#{name}.#{field} must be a positive integer"

  defp validate_runner_non_negative_integer(_name, _field, value) when is_integer(value) and value >= 0, do: nil

  defp validate_runner_non_negative_integer(name, field, _value),
    do: "runtime.runners.#{name}.#{field} must be a non-negative integer"

  defp validate_profiles(%{valid?: false} = changeset), do: changeset

  defp validate_profiles(changeset) do
    changeset
    |> get_field(:profiles)
    |> profile_validation_errors()
    |> Enum.reduce(changeset, fn message, acc -> add_error(acc, :profiles, message) end)
  end

  defp profile_validation_errors(profiles) do
    missing_default_errors =
      if Map.has_key?(profiles, "default") do
        []
      else
        ["default profile is required"]
      end

    shape_errors = Enum.flat_map(profiles, fn {name, policy} -> validate_profile_shape(name, policy) end)
    resolution_errors = validate_resolvable_profiles(profiles, shape_errors)

    missing_default_errors ++ shape_errors ++ resolution_errors
  end

  defp validate_profile_shape(name, policy) when is_map(policy) do
    reserved_profile_field_errors(name, policy) ++
      validate_profile_delivery_shape(name, Map.get(policy, "delivery")) ++
      validate_profile_legacy_codex_shape(name, Map.get(policy, "codex")) ++
      validate_profile_runners_shape(name, Map.get(policy, "runners"))
  end

  defp validate_profile_shape(name, _policy), do: ["#{name} profile must be a map"]

  defp reserved_profile_field_errors(name, policy) do
    policy
    |> Map.keys()
    |> Enum.flat_map(&reserved_profile_field_error(name, &1))
  end

  defp reserved_profile_field_error(name, key) do
    normalized_key = to_string(key)
    target_key = policy_directive_target_key(normalized_key)

    cond do
      MapSet.member?(@reserved_profile_policy_keys, normalized_key) ->
        ["#{name}.#{normalized_key} is reserved"]

      MapSet.member?(@reserved_profile_policy_keys, target_key) ->
        ["#{name}.#{normalized_key} targets reserved #{target_key}"]

      true ->
        []
    end
  end

  defp policy_directive_target_key("add_" <> target_key), do: target_key
  defp policy_directive_target_key("append_" <> target_key), do: target_key
  defp policy_directive_target_key(_key), do: nil

  defp validate_profile_delivery_shape(_name, nil), do: []

  defp validate_profile_delivery_shape(name, delivery) when is_map(delivery) do
    unsupported_errors =
      delivery
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(@delivery_v1_fields, &1))
      |> Enum.sort()
      |> Enum.map(fn field -> "#{name}.delivery.#{field} is not supported in v1" end)

    pr_target_errors =
      case Map.get(delivery, @delivery_pr_target_key) do
        value when is_binary(value) ->
          if String.trim(value) == "", do: ["#{name}.delivery.pr_target is required"], else: []

        nil ->
          []

        _value ->
          ["#{name}.delivery.pr_target must be a string"]
      end

    unsupported_errors ++ pr_target_errors
  end

  defp validate_profile_delivery_shape(name, _delivery), do: ["#{name}.delivery must be a map"]

  defp validate_profile_legacy_codex_shape(_name, nil), do: []

  defp validate_profile_legacy_codex_shape(name, _codex) do
    ["#{name}.codex is not supported in v1; use #{name}.runners.<runner_name>"]
  end

  defp validate_profile_runners_shape(_name, nil), do: []

  defp validate_profile_runners_shape(name, runners) when is_map(runners) do
    runners
    |> Enum.flat_map(fn {runner_name, runner_policy} ->
      validate_profile_runner_shape(name, to_string(runner_name), runner_policy)
    end)
  end

  defp validate_profile_runners_shape(name, _runners), do: ["#{name}.runners must be a map"]

  defp validate_profile_runner_shape(name, runner_name, runner_policy) when is_map(runner_policy) do
    unsupported_errors =
      runner_policy
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(@profile_runner_v1_fields, &1))
      |> Enum.sort()
      |> Enum.map(fn field -> "#{name}.runners.#{runner_name}.#{field} is not supported in v1" end)

    field_errors =
      [
        validate_profile_runner_approval_policy(name, runner_name, Map.get(runner_policy, "approval_policy")),
        validate_profile_runner_thread_sandbox(name, runner_name, Map.get(runner_policy, "thread_sandbox")),
        validate_profile_runner_turn_sandbox_policy(name, runner_name, Map.get(runner_policy, "turn_sandbox_policy"))
      ]
      |> Enum.reject(&is_nil/1)

    unsupported_errors ++ field_errors
  end

  defp validate_profile_runner_shape(name, runner_name, _runner_policy),
    do: ["#{name}.runners.#{runner_name} must be a map"]

  defp validate_profile_runner_approval_policy(_name, _runner_name, nil), do: nil

  defp validate_profile_runner_approval_policy(name, runner_name, value) do
    format_codex_action_approval_policy_error("#{name}.runners.#{runner_name}.approval_policy", value)
  end

  defp validate_profile_runner_thread_sandbox(_name, _runner_name, nil), do: nil

  defp validate_profile_runner_thread_sandbox(_name, _runner_name, value) when is_binary(value), do: nil

  defp validate_profile_runner_thread_sandbox(name, runner_name, _value),
    do: "#{name}.runners.#{runner_name}.thread_sandbox must be a string"

  defp validate_profile_runner_turn_sandbox_policy(_name, _runner_name, nil), do: nil

  defp validate_profile_runner_turn_sandbox_policy(_name, _runner_name, value) when is_map(value), do: nil

  defp validate_profile_runner_turn_sandbox_policy(name, runner_name, _value),
    do: "#{name}.runners.#{runner_name}.turn_sandbox_policy must be a map"

  defp validate_resolvable_profiles(profiles, shape_errors) do
    if Map.has_key?(profiles, "default") and shape_errors == [] do
      profiles
      |> Map.keys()
      |> Enum.sort()
      |> Enum.flat_map(&profile_resolution_errors(profiles, &1))
    else
      []
    end
  end

  defp profile_resolution_errors(profiles, profile_name) do
    case resolve_profile_policy(profiles, profile_name) do
      {:ok, _policy} -> []
      {:error, reason} -> [format_policy_resolution_error(reason)]
    end
  end

  defp normalize_profile_reference(nil), do: {:ok, "default"}

  defp normalize_profile_reference(profile_ref) when is_atom(profile_ref) or is_binary(profile_ref) do
    profile_name = to_string(profile_ref)

    if String.trim(profile_name) == "" do
      {:error, :blank_workflow_profile}
    else
      {:ok, profile_name}
    end
  end

  defp normalize_profile_reference(profile_ref), do: {:error, {:invalid_workflow_profile_ref, profile_ref}}

  defp normalize_refinement_references(refinement_refs) when is_list(refinement_refs) do
    refinement_refs
    |> Enum.reduce_while({:ok, []}, fn profile_ref, {:ok, acc} ->
      case normalize_profile_reference(profile_ref) do
        {:ok, profile_name} -> {:cont, {:ok, [profile_name | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, profile_names} -> {:ok, Enum.reverse(profile_names)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_profile_policy(profiles, profile_name) when is_map(profiles) do
    resolve_profile_policy(profiles, profile_name, [], [])
  end

  defp resolve_profile_policy(profiles, profile_name, refinement_names, opts)
       when is_map(profiles) and is_list(refinement_names) and is_list(opts) do
    locked_delivery_target = normalize_delivery_target_override(Keyword.get(opts, :delivery_target_override))

    with {:ok, default_policy} <- fetch_profile_policy(profiles, "default"),
         {:ok, selected_policy} <- fetch_profile_policy(profiles, profile_name),
         {:ok, default_effective} <- apply_policy_overrides(%{}, default_policy, ["default"]),
         {:ok, policy} <- apply_selected_policy(default_effective, selected_policy, profile_name),
         {:ok, policy} <- apply_delivery_target_override(policy, locked_delivery_target),
         :ok <- validate_resolved_delivery(policy, profile_name),
         :ok <- validate_resolved_runner_policies(policy, profile_name) do
      apply_refinement_policies(profiles, policy, refinement_names, locked_delivery_target)
    end
  end

  defp fetch_profile_policy(profiles, "default") do
    case Map.fetch(profiles, "default") do
      {:ok, policy} -> {:ok, policy}
      :error -> {:error, :missing_default_workflow_profile}
    end
  end

  defp fetch_profile_policy(profiles, profile_name) do
    case Map.fetch(profiles, profile_name) do
      {:ok, policy} -> {:ok, policy}
      :error -> {:error, {:unknown_workflow_profile, profile_name, Map.keys(profiles) |> Enum.sort()}}
    end
  end

  defp apply_selected_policy(default_effective, _selected_policy, "default"), do: {:ok, default_effective}

  defp apply_selected_policy(default_effective, selected_policy, profile_name) do
    apply_policy_overrides(default_effective, selected_policy, [profile_name])
  end

  defp normalize_delivery_target_override(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_delivery_target_override(_value), do: nil

  defp apply_delivery_target_override(policy, nil), do: {:ok, policy}

  defp apply_delivery_target_override(policy, delivery_target) do
    apply_policy_overrides(policy, %{"delivery" => %{@delivery_pr_target_key => delivery_target}}, ["delivery_target_override"])
  end

  defp apply_refinement_policies(_profiles, policy, [], _locked_delivery_target), do: {:ok, policy}

  defp apply_refinement_policies(profiles, policy, [profile_name | rest], locked_delivery_target) do
    with {:ok, selected_policy} <- fetch_profile_policy(profiles, profile_name),
         {:ok, refined_policy} <- apply_policy_overrides(policy, selected_policy, [profile_name]),
         :ok <- validate_refinement_delivery_target(refined_policy, profile_name, locked_delivery_target),
         :ok <- validate_resolved_delivery(refined_policy, profile_name),
         :ok <- validate_resolved_runner_policies(refined_policy, profile_name) do
      apply_refinement_policies(profiles, refined_policy, rest, locked_delivery_target)
    end
  end

  defp put_resolved_publish_target(policy) do
    if publish_handoff_policy?(policy) do
      repository = get_in(policy, ["manifest", "project", "repository"])
      pr_target = get_in(policy, ["delivery", @delivery_pr_target_key])

      case PublishTarget.build(repository, pr_target) do
        nil -> Map.delete(policy, "publish_target")
        target -> Map.put(policy, "publish_target", target)
      end
    else
      policy
    end
  end

  defp publish_handoff_policy?(policy) do
    Map.has_key?(policy, "publish_target") or
      publish_handoff_manifest_policy?(policy)
  end

  defp publish_handoff_manifest_policy?(policy) do
    with true <- "delivery.github_pr" in (get_in(policy, ["manifest", "workflow", "modules"]) || []),
         repository when is_binary(repository) <- get_in(policy, ["manifest", "project", "repository"]),
         pr_target when is_binary(pr_target) <- get_in(policy, ["delivery", @delivery_pr_target_key]) do
      PublishTarget.build(repository, pr_target) != nil
    else
      _value -> false
    end
  end

  defp apply_policy_overrides(base, overrides, path) when is_map(base) and is_map(overrides) do
    overrides
    |> Enum.sort_by(fn {raw_key, _value} -> policy_override_sort_key(raw_key) end)
    |> Enum.reduce_while({:ok, base}, fn {raw_key, value}, {:ok, acc} ->
      key = to_string(raw_key)

      case apply_policy_override(acc, key, value, path) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp policy_override_sort_key(raw_key) do
    key = to_string(raw_key)

    if String.starts_with?(key, "add_") or String.starts_with?(key, "append_") do
      {1, key}
    else
      {0, key}
    end
  end

  defp apply_policy_override(acc, key, value, path) do
    cond do
      String.starts_with?(key, "add_") ->
        apply_add_policy_override(acc, key, value, path)

      String.starts_with?(key, "append_") ->
        apply_append_policy_override(acc, key, value, path)

      true ->
        apply_replace_policy_override(acc, key, value, path)
    end
  end

  defp apply_add_policy_override(acc, key, value, path) do
    target_key = String.replace_prefix(key, "add_", "")
    target_path = path ++ [target_key]

    with {:ok, merged} <- add_policy_map(Map.get(acc, target_key, %{}), value, target_path) do
      {:ok, Map.put(acc, target_key, merged)}
    end
  end

  defp apply_append_policy_override(acc, key, value, path) do
    target_key = String.replace_prefix(key, "append_", "")
    target_path = path ++ [target_key]

    with {:ok, merged} <- append_policy_list(Map.get(acc, target_key, []), value, target_path) do
      {:ok, Map.put(acc, target_key, merged)}
    end
  end

  defp apply_replace_policy_override(acc, key, value, path) do
    with {:ok, normalized} <- normalize_policy_value(value, path ++ [key]) do
      {:ok, Map.put(acc, key, normalized)}
    end
  end

  defp normalize_policy_value(value, path) when is_map(value), do: apply_policy_overrides(%{}, value, path)

  defp normalize_policy_value(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case normalize_policy_value(entry, path ++ [Integer.to_string(index)]) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_policy_value(value, _path), do: {:ok, value}

  defp add_policy_map(existing, value, path) when is_map(existing) and is_map(value) do
    apply_policy_overrides(existing, value, path)
  end

  defp add_policy_map(_existing, value, path) when is_map(value) do
    {:error, {:invalid_policy_add_field, Enum.join(path, "."), :expected_existing_map}}
  end

  defp add_policy_map(_existing, _value, path) do
    {:error, {:invalid_policy_add_field, Enum.join(path, "."), :expected_map}}
  end

  defp append_policy_list(existing, value, path) when is_list(existing) and is_list(value) do
    case normalize_policy_value(value, path) do
      {:ok, normalized} -> {:ok, existing ++ normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_policy_list(_existing, value, path) when is_list(value) do
    {:error, {:invalid_policy_append_field, Enum.join(path, "."), :expected_existing_list}}
  end

  defp append_policy_list(_existing, _value, path) do
    {:error, {:invalid_policy_append_field, Enum.join(path, "."), :expected_list}}
  end

  defp validate_resolved_delivery(policy, profile_name) do
    case Map.get(policy, "delivery") do
      %{} = delivery ->
        pr_target = Map.get(delivery, @delivery_pr_target_key)

        unsupported_fields =
          delivery
          |> Map.keys()
          |> Enum.reject(&MapSet.member?(@delivery_v1_fields, &1))
          |> Enum.sort()

        cond do
          unsupported_fields != [] ->
            {:error, {:unsupported_delivery_policy_fields, profile_name, unsupported_fields}}

          not valid_pr_target?(pr_target) ->
            {:error, {:missing_delivery_pr_target, profile_name}}

          publish_handoff_policy?(policy) and PublishTarget.ambiguous_pr_target?(pr_target) ->
            {:error, {:ambiguous_delivery_pr_target, profile_name}}

          true ->
            :ok
        end

      _delivery ->
        {:error, {:missing_delivery_pr_target, profile_name}}
    end
  end

  defp validate_resolved_runner_policies(policy, profile_name) do
    case Map.get(policy, "runners") do
      runners when is_map(runners) ->
        validate_resolved_runner_policy_map(runners, profile_name)

      _runners ->
        :ok
    end
  end

  defp validate_resolved_runner_policy_map(runners, profile_name) do
    case Enum.find_value(runners, &resolved_runner_policy_error(&1, profile_name)) do
      nil -> :ok
      message -> {:error, {:invalid_resolved_runner_policy, message}}
    end
  end

  defp resolved_runner_policy_error({runner_name, runner_policy}, profile_name) do
    profile_name
    |> validate_profile_runner_shape(to_string(runner_name), runner_policy)
    |> List.first()
  end

  defp valid_pr_target?(value), do: is_binary(value) and String.trim(value) != ""

  defp validate_refinement_delivery_target(_policy, _profile_name, nil), do: :ok

  defp validate_refinement_delivery_target(policy, profile_name, locked_delivery_target) do
    case get_in(policy, ["delivery", @delivery_pr_target_key]) do
      ^locked_delivery_target ->
        :ok

      changed_target ->
        {:error, {:refinement_delivery_target_override, profile_name, locked_delivery_target, changed_target}}
    end
  end

  defp policy_ref(policy) do
    :sha256
    |> :crypto.hash(canonical_policy(policy))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @policy_ref_length)
  end

  defp canonical_policy(value) when is_map(value) do
    encoded_fields =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join(",", fn {key, field_value} ->
        Jason.encode!(to_string(key)) <> ":" <> canonical_policy(field_value)
      end)

    "{" <> encoded_fields <> "}"
  end

  defp canonical_policy(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_policy/1) <> "]"
  end

  defp canonical_policy(value), do: Jason.encode!(value)

  defp put_policy_metadata(policy, metadata) when is_map(metadata) and map_size(metadata) > 0 do
    Map.put(policy, @profile_policy_metadata_key, normalize_keys(metadata))
  end

  defp put_policy_metadata(policy, _metadata), do: policy

  defp normalize_policy_metadata(metadata) when is_map(metadata), do: normalize_keys(metadata)
  defp normalize_policy_metadata(_metadata), do: %{}

  defp format_policy_resolution_error({:missing_delivery_pr_target, profile_name}) do
    "#{profile_name}.delivery.pr_target is required in resolved policy"
  end

  defp format_policy_resolution_error({:ambiguous_delivery_pr_target, profile_name}) do
    "#{profile_name}.delivery.pr_target must be an unambiguous branch name for publish handoff"
  end

  defp format_policy_resolution_error({:unsupported_delivery_policy_fields, profile_name, fields}) do
    formatted_fields = Enum.map_join(fields, ", ", &"#{profile_name}.delivery.#{&1}")
    "#{formatted_fields} not supported in v1"
  end

  defp format_policy_resolution_error({:invalid_policy_add_field, path, expected}) do
    "#{path} cannot be merged with add_* policy field; #{expected}"
  end

  defp format_policy_resolution_error({:invalid_resolved_runner_policy, message}), do: message

  defp format_policy_resolution_error({:invalid_policy_append_field, path, expected}) do
    "#{path} cannot be merged with append_* policy field; #{expected}"
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
