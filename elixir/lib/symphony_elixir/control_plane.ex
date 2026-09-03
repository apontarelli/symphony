defmodule SymphonyElixir.ControlPlane do
  @moduledoc """
  Owns the local SQLite control-plane store and its schema lifecycle.

  Callers use domain operations and `transaction/2`; SQLite connections, SQL,
  migrations, and schema checks remain private to this process.
  """

  use GenServer
  require Logger
  alias Exqlite.Sqlite3
  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.LocalConfig
  alias SymphonyElixir.ProcessSupervisor
  alias SymphonyElixir.ReviewRecords.Redaction
  alias SymphonyElixir.TargetContext

  @database_file "control-plane.sqlite3"
  @schema_version 6
  @default_busy_timeout_ms 5_000
  @maximum_busy_timeout_ms 30_000
  @lease_duration_ms 30_000
  @lease_renewal_interval_ms 10_000
  @maximum_clock_skew_ms 1_000
  @call_timeout_ms @maximum_busy_timeout_ms + 5_000
  @lifecycle_states [:admitted, :running, :retrying, :blocked, :completed, :cleanup_pending, :cleaned]
  @recoverable_lifecycle_states [:admitted, :running, :retrying, :blocked, :cleanup_pending]
  @idempotent_lifecycle_states [:completed, :cleanup_pending, :cleaned]
  @side_effect_kinds [
    :tracker_write,
    :publish_preflight,
    :publish_handoff,
    :handoff_route,
    :workspace_cleanup
  ]
  @side_effect_states [:pending, :succeeded, :failed, :reconciliation_required]
  @operator_run_actions [:resume, :abandon]
  @terminal_lifecycle_states [:completed, :cleaned]
  @retained_artifact_kinds ["publish_handoff", "handoff_route"]
  @legal_lifecycle_transitions %{
    admitted: [:running, :blocked, :completed],
    running: [:retrying, :blocked, :completed],
    retrying: [:running, :blocked, :completed],
    blocked: [:running, :completed],
    completed: [:cleanup_pending],
    cleanup_pending: [:cleaned],
    cleaned: []
  }

  defmodule Error do
    @moduledoc false

    @enforce_keys [:code, :message, :path]
    defexception [:code, :message, :path, :reason]

    @type t :: %__MODULE__{
            code: atom(),
            message: String.t(),
            path: Path.t(),
            reason: term()
          }
  end

  defmodule Transaction do
    @moduledoc false

    @enforce_keys [:owner, :ref]
    defstruct [:owner, :ref]

    @opaque t :: %__MODULE__{owner: pid(), ref: reference()}
  end

  defmodule Admission do
    @moduledoc false

    @enforce_keys [
      :admitted_run_id,
      :target_id,
      :tracker_issue_id,
      :issue_identifier,
      :registry_generation,
      :policy_hash,
      :repo_manifest_hash,
      :context,
      :admitted_at
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            admitted_run_id: String.t(),
            target_id: String.t(),
            tracker_issue_id: String.t(),
            issue_identifier: String.t(),
            registry_generation: String.t(),
            policy_hash: String.t(),
            repo_manifest_hash: String.t(),
            context: ExecutionContext.t(),
            admitted_at: String.t()
          }
  end

  defmodule Lease do
    @moduledoc false

    @enforce_keys [
      :admitted_run_id,
      :target_id,
      :tracker_issue_id,
      :owner_id,
      :fencing_token,
      :deadline_ms
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            admitted_run_id: String.t(),
            target_id: String.t(),
            tracker_issue_id: String.t(),
            owner_id: String.t(),
            fencing_token: pos_integer(),
            deadline_ms: integer()
          }
  end

  defmodule TokenBudget do
    @moduledoc false

    @enforce_keys [
      :admitted_run_id,
      :target_id,
      :admission_day,
      :admission_week,
      :per_run_limit,
      :daily_limit,
      :weekly_limit,
      :cumulative_tokens,
      :charged_tokens,
      :reserved_tokens,
      :state,
      :daily_available_tokens,
      :weekly_available_tokens,
      :updated_at
    ]
    defstruct @enforce_keys

    @type state :: :active | :released | :terminal
    @type t :: %__MODULE__{
            admitted_run_id: String.t(),
            target_id: String.t(),
            admission_day: String.t(),
            admission_week: String.t(),
            per_run_limit: pos_integer(),
            daily_limit: pos_integer(),
            weekly_limit: pos_integer(),
            cumulative_tokens: non_neg_integer(),
            charged_tokens: non_neg_integer(),
            reserved_tokens: non_neg_integer(),
            state: state(),
            daily_available_tokens: non_neg_integer(),
            weekly_available_tokens: non_neg_integer(),
            updated_at: String.t()
          }
  end

  defmodule Lifecycle do
    @moduledoc false

    @enforce_keys [
      :admitted_run_id,
      :target_id,
      :tracker_issue_id,
      :state,
      :sequence,
      :admitted_at,
      :updated_at
    ]
    defstruct [
      :admitted_run_id,
      :target_id,
      :tracker_issue_id,
      :state,
      :sequence,
      :retry_attempt,
      :retry_due_at_ms,
      :failure,
      :blocked_reason,
      :completion_disposition,
      :cleanup_authority,
      :admitted_at,
      :started_at,
      :completed_at,
      :cleanup_pending_at,
      :cleaned_at,
      :updated_at
    ]

    @type state ::
            :admitted
            | :running
            | :retrying
            | :blocked
            | :completed
            | :cleanup_pending
            | :cleaned

    @type t :: %__MODULE__{
            admitted_run_id: String.t(),
            target_id: String.t(),
            tracker_issue_id: String.t(),
            state: state(),
            sequence: pos_integer(),
            retry_attempt: pos_integer() | nil,
            retry_due_at_ms: non_neg_integer() | nil,
            failure: map() | nil,
            blocked_reason: String.t() | nil,
            completion_disposition: String.t() | nil,
            cleanup_authority: map() | nil,
            admitted_at: String.t(),
            started_at: String.t() | nil,
            completed_at: String.t() | nil,
            cleanup_pending_at: String.t() | nil,
            cleaned_at: String.t() | nil,
            updated_at: String.t()
          }
  end

  defmodule LifecycleTransition do
    @moduledoc false

    @enforce_keys [
      :admitted_run_id,
      :sequence,
      :from_state,
      :to_state,
      :occurred_at,
      :evidence
    ]
    defstruct [
      :admitted_run_id,
      :sequence,
      :from_state,
      :to_state,
      :owner_id,
      :fencing_token,
      :occurred_at,
      :evidence
    ]

    @type t :: %__MODULE__{
            admitted_run_id: String.t(),
            sequence: pos_integer(),
            from_state: Lifecycle.state() | nil,
            to_state: Lifecycle.state(),
            owner_id: String.t() | nil,
            fencing_token: pos_integer() | nil,
            occurred_at: String.t(),
            evidence: map()
          }
  end

  defmodule SideEffect do
    @moduledoc false

    @enforce_keys [
      :admitted_run_id,
      :target_id,
      :tracker_issue_id,
      :kind,
      :idempotency_key,
      :artifact_path,
      :state,
      :owner_id,
      :fencing_token,
      :intent,
      :started_at,
      :updated_at
    ]
    defstruct [
      :admitted_run_id,
      :target_id,
      :tracker_issue_id,
      :kind,
      :idempotency_key,
      :artifact_path,
      :state,
      :owner_id,
      :fencing_token,
      :intent,
      :outcome,
      :started_at,
      :completed_at,
      :updated_at
    ]

    @type kind ::
            :tracker_write
            | :publish_preflight
            | :publish_handoff
            | :handoff_route
            | :workspace_cleanup
    @type state :: :pending | :succeeded | :failed | :reconciliation_required
    @type t :: %__MODULE__{
            admitted_run_id: String.t(),
            target_id: String.t(),
            tracker_issue_id: String.t(),
            kind: kind(),
            idempotency_key: String.t(),
            artifact_path: Path.t(),
            state: state(),
            owner_id: String.t(),
            fencing_token: pos_integer(),
            intent: map(),
            outcome: map() | nil,
            started_at: String.t(),
            completed_at: String.t() | nil,
            updated_at: String.t()
          }
  end

  defmodule ProcessOwnership do
    @moduledoc false

    @enforce_keys [
      :admitted_run_id,
      :target_id,
      :tracker_issue_id,
      :owner_id,
      :fencing_token,
      :process_group_id,
      :state,
      :evidence,
      :started_at,
      :updated_at
    ]
    defstruct @enforce_keys

    @type state :: :running | :stopped | :unverifiable
    @type t :: %__MODULE__{
            admitted_run_id: String.t(),
            target_id: String.t(),
            tracker_issue_id: String.t(),
            owner_id: String.t(),
            fencing_token: pos_integer(),
            process_group_id: pos_integer(),
            state: state(),
            evidence: map(),
            started_at: String.t(),
            updated_at: String.t()
          }
  end

  defmodule Recovery do
    @moduledoc false

    @enforce_keys [:admission, :lifecycle, :lease, :action]
    defstruct [
      :admission,
      :lifecycle,
      :lease,
      :action,
      :execution_context,
      :blocked_reason
    ]

    @type action :: :dispatch | :retry | :blocked | :cleanup
    @type t :: %__MODULE__{
            admission: Admission.t(),
            lifecycle: Lifecycle.t(),
            lease: Lease.t(),
            action: action(),
            execution_context: ExecutionContext.t() | nil,
            blocked_reason: String.t() | nil
          }
  end

  @type health :: %{
          required(:path) => Path.t(),
          required(:schema_version) => pos_integer(),
          required(:status) => :healthy
        }
  @type transaction_result(value) :: {:ok, value} | {:error, term()}
  @type admission_error ::
          :admission_conflict
          | :admission_not_found
          | :invalid_admission
          | Error.t()
  @type lease_error ::
          :admission_not_found
          | :invalid_lease
          | :lease_active
          | :lease_held
          | :lease_not_found
          | :process_termination_unverified
          | :stale_lease
          | Error.t()
  @type token_budget_error ::
          :admission_not_found
          | :daily_token_budget_exceeded
          | :invalid_lease
          | :invalid_token_usage
          | :stale_lease
          | :token_budget_exhausted
          | :token_budget_not_configured
          | :token_budget_not_reserved
          | :weekly_token_budget_exceeded
          | Error.t()
  @type lifecycle_error ::
          :admission_not_found
          | :duplicate_transition
          | :illegal_transition
          | :invalid_lease
          | :invalid_transition
          | :out_of_order_transition
          | :stale_lease
          | token_budget_error()
          | Error.t()
  @type side_effect_error ::
          :admission_not_found
          | :invalid_lease
          | :invalid_side_effect
          | :side_effect_conflict
          | :side_effect_not_allowed
          | :side_effect_not_found
          | :stale_lease
          | Error.t()
  @type side_effect_claim ::
          {:ok, SideEffect.t()}
          | {:completed, SideEffect.t()}
          | {:failed, SideEffect.t()}
          | {:blocked, SideEffect.t()}
          | {:error, side_effect_error()}
  @type process_ownership_error ::
          :admission_not_found
          | :invalid_lease
          | :invalid_process_ownership
          | :process_ownership_conflict
          | :process_termination_unverified
          | :stale_lease
          | Error.t()
  @type recovery_error ::
          :invalid_recovery
          | :recovery_not_found
          | :stale_lease
          | Error.t()
  @type operator_error ::
          :confirmation_required
          | :invalid_confirmation
          | :invalid_operator_action
          | :operator_action_not_allowed
          | :reconciliation_required
          | admission_error()
          | lease_error()
          | lifecycle_error()
  @type prune_error ::
          :invalid_confirmation
          | :invalid_retention
          | Error.t()

  @type credential_resolution ::
          {:ok, ExecutionContext.t()}
          | {:blocked, :missing_credentials | :credential_resolution_failed}
          | {:error, :invalid_admission}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec path(keyword()) :: Path.t()
  def path(opts \\ []) do
    config_root =
      Keyword.get(opts, :config_root) ||
        Application.get_env(:symphony_elixir, :control_plane_config_root) ||
        LocalConfig.root()

    config_root
    |> Path.expand()
    |> Path.join(@database_file)
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec lease_policy() :: %{
          duration_ms: pos_integer(),
          renewal_interval_ms: pos_integer(),
          maximum_clock_skew_ms: non_neg_integer()
        }
  def lease_policy do
    %{
      duration_ms: @lease_duration_ms,
      renewal_interval_ms: @lease_renewal_interval_ms,
      maximum_clock_skew_ms: @maximum_clock_skew_ms
    }
  end

  @spec health(GenServer.server()) :: {:ok, health()} | {:error, Error.t()}
  def health(server \\ __MODULE__) do
    GenServer.call(server, :health, @call_timeout_ms)
  end

  @doc """
  Returns the credential-safe canonical projection of every durable run.
  """
  @spec inspect_runs(GenServer.server()) :: {:ok, [map()]} | {:error, Error.t()}
  def inspect_runs(server \\ __MODULE__) do
    GenServer.call(server, :inspect_runs, @call_timeout_ms)
  end

  @doc """
  Returns credential-safe token reservation and charged-use totals by target.
  """
  @spec inspect_target_budgets(GenServer.server()) :: {:ok, [map()]} | {:error, Error.t()}
  def inspect_target_budgets(server \\ __MODULE__) do
    GenServer.call(server, :inspect_target_budgets, @call_timeout_ms)
  end

  @doc """
  Previews a fenced resume or abandon operation against current durable state.
  """
  @spec preview_run_action(GenServer.server(), :resume | :abandon, String.t()) ::
          {:ok, map()} | {:error, operator_error()}
  def preview_run_action(server \\ __MODULE__, action, admitted_run_id) do
    GenServer.call(
      server,
      {:preview_run_action, action, admitted_run_id},
      @call_timeout_ms
    )
  end

  @doc """
  Confirms a previously previewed run action.

  The confirmation token binds the action to the current lifecycle sequence and
  fencing generation. The operation acquires a new lease before mutation.
  """
  @spec confirm_run_action(
          GenServer.server(),
          :resume | :abandon,
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, %{lease: Lease.t(), run: map()}} | {:error, operator_error()}
  def confirm_run_action(
        server \\ __MODULE__,
        action,
        admitted_run_id,
        owner_id,
        confirmation
      ) do
    GenServer.call(
      server,
      {:confirm_run_action, action, admitted_run_id, owner_id, confirmation},
      @call_timeout_ms
    )
  end

  @doc """
  Previews terminal-run pruning for the configured retention period.
  """
  @spec preview_prune(GenServer.server(), pos_integer()) ::
          {:ok, map()} | {:error, prune_error()}
  def preview_prune(server \\ __MODULE__, retention_days) do
    GenServer.call(server, {:preview_prune, retention_days}, @call_timeout_ms)
  end

  @doc """
  Prunes only terminal runs that still match a current preview.
  """
  @spec prune(GenServer.server(), pos_integer(), String.t()) ::
          {:ok, map()} | {:error, prune_error()}
  def prune(server \\ __MODULE__, retention_days, confirmation) do
    GenServer.call(
      server,
      {:prune, retention_days, confirmation},
      @call_timeout_ms
    )
  end

  @doc """
  Runs domain operations in one immediate SQLite transaction.

  The callback receives an opaque transaction handle, not a connection. It must
  return `{:ok, value}` to commit or `{:error, reason}` to roll back.
  """
  @spec transaction(GenServer.server(), (Transaction.t() -> transaction_result(value))) ::
          transaction_result(value)
        when value: term()
  def transaction(server \\ __MODULE__, operation) when is_function(operation, 1) do
    GenServer.call(server, {:transaction, operation}, @call_timeout_ms)
  end

  @doc """
  Atomically admits one immutable target-and-issue run.

  The execution context must retain validated credential references. A
  repeated admission with the same pinned envelope returns the original
  admitted run ID. Any changed generation, hash, or envelope conflicts.
  """
  @spec admit_run(GenServer.server(), ExecutionContext.t()) ::
          {:ok, Admission.t()} | {:error, admission_error()}
  def admit_run(server \\ __MODULE__, context) do
    GenServer.call(server, {:admit_run, context}, @call_timeout_ms)
  end

  @doc """
  Returns the durable reservation, charged usage, and admission-period balances.
  """
  @spec fetch_token_budget(GenServer.server(), String.t()) ::
          {:ok, TokenBudget.t()} | {:error, token_budget_error()}
  def fetch_token_budget(server \\ __MODULE__, admitted_run_id) do
    GenServer.call(server, {:fetch_token_budget, admitted_run_id}, @call_timeout_ms)
  end

  @doc """
  Records a monotonic cumulative token total under the current durable fence.

  Duplicate totals and lower out-of-order totals return the stored maximum.
  """
  @spec record_token_usage(GenServer.server(), Lease.t(), non_neg_integer()) ::
          {:ok, TokenBudget.t() | :unlimited} | {:error, token_budget_error()}
  def record_token_usage(server \\ __MODULE__, lease, cumulative_total_tokens) do
    GenServer.call(
      server,
      {:record_token_usage, lease, cumulative_total_tokens},
      @call_timeout_ms
    )
  end

  @doc """
  Releases the unused reservation after fenced process-stop evidence.

  Charged cumulative usage remains allocated to the admission day and week.
  """
  @spec release_token_reservation(GenServer.server(), Lease.t()) ::
          {:ok, TokenBudget.t() | :unlimited} | {:error, token_budget_error()}
  def release_token_reservation(server \\ __MODULE__, lease) do
    GenServer.call(server, {:release_token_reservation, lease}, @call_timeout_ms)
  end

  @doc """
  Reacquires the run's remaining per-run ceiling before a paused run resumes.
  """
  @spec acquire_token_reservation(GenServer.server(), Lease.t()) ::
          {:ok, TokenBudget.t() | :unlimited} | {:error, token_budget_error()}
  def acquire_token_reservation(server \\ __MODULE__, lease) do
    GenServer.call(server, {:acquire_token_reservation, lease}, @call_timeout_ms)
  end

  @doc """
  Atomically acquires the admitted run for one owner.

  An active lease cannot be reacquired, including by the same owner. After
  release or expiry, acquisition assigns a fencing token greater than every
  token previously issued for the run.
  """
  @spec acquire_lease(GenServer.server(), String.t(), String.t()) ::
          {:ok, Lease.t()} | {:error, lease_error()}
  def acquire_lease(server \\ __MODULE__, admitted_run_id, owner_id) do
    GenServer.call(
      server,
      {:acquire_lease, admitted_run_id, owner_id},
      @call_timeout_ms
    )
  end

  @doc """
  Renews a current lease without changing its fencing token.
  """
  @spec renew_lease(GenServer.server(), Lease.t()) ::
          {:ok, Lease.t()} | {:error, lease_error()}
  def renew_lease(server \\ __MODULE__, lease) do
    GenServer.call(server, {:renew_lease, lease}, @call_timeout_ms)
  end

  @doc """
  Transfers a current lease to a different owner and issues a new token.
  """
  @spec transfer_lease(GenServer.server(), Lease.t(), String.t()) ::
          {:ok, Lease.t()} | {:error, lease_error()}
  def transfer_lease(server \\ __MODULE__, lease, new_owner_id) do
    GenServer.call(
      server,
      {:transfer_lease, lease, new_owner_id},
      @call_timeout_ms
    )
  end

  @doc """
  Releases a current lease. The issued token remains retired durably.
  """
  @spec release_lease(GenServer.server(), Lease.t()) ::
          :ok | {:error, lease_error()}
  def release_lease(server \\ __MODULE__, lease) do
    GenServer.call(server, {:release_lease, lease}, @call_timeout_ms)
  end

  @doc """
  Clears an expired lease while retaining its fencing-token history.
  """
  @spec expire_lease(GenServer.server(), String.t()) ::
          {:ok, :expired} | {:error, lease_error()}
  def expire_lease(server \\ __MODULE__, admitted_run_id) do
    GenServer.call(server, {:expire_lease, admitted_run_id}, @call_timeout_ms)
  end

  @doc """
  Returns the authoritative lifecycle for one admitted run.
  """
  @spec fetch_lifecycle(GenServer.server(), String.t()) ::
          {:ok, Lifecycle.t()} | {:error, lifecycle_error()}
  def fetch_lifecycle(server \\ __MODULE__, admitted_run_id) do
    GenServer.call(server, {:fetch_lifecycle, admitted_run_id}, @call_timeout_ms)
  end

  @doc """
  Returns the lifecycle scoped by target and tracker issue identity.
  """
  @spec fetch_target_lifecycle(GenServer.server(), String.t(), String.t()) ::
          {:ok, Lifecycle.t()} | {:error, lifecycle_error()}
  def fetch_target_lifecycle(server \\ __MODULE__, target_id, tracker_issue_id) do
    GenServer.call(
      server,
      {:fetch_target_lifecycle, target_id, tracker_issue_id},
      @call_timeout_ms
    )
  end

  @doc """
  Applies one fenced lifecycle transition.

  The caller supplies the sequence and state it observed. A changed current
  sequence or state fails as out of order. Exact duplicate completion and
  cleanup messages return the current lifecycle without appending history.
  """
  @spec transition_run(
          GenServer.server(),
          Lease.t(),
          pos_integer(),
          Lifecycle.state(),
          Lifecycle.state(),
          map()
        ) :: {:ok, Lifecycle.t()} | {:error, lifecycle_error()}
  def transition_run(
        server \\ __MODULE__,
        lease,
        expected_sequence,
        expected_state,
        next_state,
        evidence
      ) do
    GenServer.call(
      server,
      {:transition_run, lease, expected_sequence, expected_state, next_state, evidence},
      @call_timeout_ms
    )
  end

  @doc """
  Returns the append-only lifecycle transition history in sequence order.
  """
  @spec lifecycle_history(GenServer.server(), String.t()) ::
          {:ok, [LifecycleTransition.t()]} | {:error, lifecycle_error()}
  def lifecycle_history(server \\ __MODULE__, admitted_run_id) do
    GenServer.call(server, {:lifecycle_history, admitted_run_id}, @call_timeout_ms)
  end

  @doc """
  Starts one fenced side effect before its external call.

  The durable identity is target-scoped by the admitted run, effect kind, and
  idempotency key. A repeated pending intent becomes reconciliation-required;
  a known terminal outcome is returned without authorizing another call.
  """
  @spec begin_side_effect(
          GenServer.server(),
          Lease.t(),
          SideEffect.kind(),
          String.t(),
          map()
        ) :: side_effect_claim()
  def begin_side_effect(server \\ __MODULE__, lease, kind, idempotency_key, intent) do
    GenServer.call(
      server,
      {:begin_side_effect, lease, kind, idempotency_key, intent},
      @call_timeout_ms
    )
  end

  @doc """
  Records the fenced outcome of a previously started side effect.
  """
  @spec finish_side_effect(
          GenServer.server(),
          Lease.t(),
          SideEffect.kind(),
          String.t(),
          {:succeeded | :failed | :ambiguous, map()}
        ) ::
          {:ok, SideEffect.t()}
          | {:failed, SideEffect.t()}
          | {:blocked, SideEffect.t()}
          | {:error, side_effect_error()}
  def finish_side_effect(server \\ __MODULE__, lease, kind, idempotency_key, outcome) do
    GenServer.call(
      server,
      {:finish_side_effect, lease, kind, idempotency_key, outcome},
      @call_timeout_ms
    )
  end

  @doc """
  Runs an external call only after its durable fenced intent is committed.

  The callback returns `{:ok, outcome}`, `{:failed, outcome}`, or
  `{:ambiguous, outcome}`. Exceptions, exits, and other return values are
  recorded as reconciliation-required.
  """
  @spec run_side_effect(
          GenServer.server(),
          Lease.t(),
          SideEffect.kind(),
          String.t(),
          map(),
          (-> {:ok, map()} | {:failed, map()} | {:ambiguous, map()})
        ) :: {:ok, SideEffect.t()} | {:blocked, SideEffect.t()} | {:error, term()}
  def run_side_effect(
        server \\ __MODULE__,
        lease,
        kind,
        idempotency_key,
        intent,
        operation
      )
      when is_function(operation, 0) do
    case begin_side_effect(server, lease, kind, idempotency_key, intent) do
      {:ok, _side_effect} ->
        outcome = invoke_side_effect(operation)

        case finish_side_effect(server, lease, kind, idempotency_key, outcome) do
          {:failed, side_effect} -> {:error, {:side_effect_failed, side_effect}}
          result -> result
        end

      {:completed, side_effect} ->
        {:ok, side_effect}

      {:failed, side_effect} ->
        {:error, {:side_effect_failed, side_effect}}

      {:blocked, side_effect} ->
        {:blocked, side_effect}

      {:error, _reason} = error ->
        error
    end
  end

  @spec fetch_side_effect(GenServer.server(), String.t(), SideEffect.kind(), String.t()) ::
          {:ok, SideEffect.t()} | {:error, side_effect_error()}
  def fetch_side_effect(server \\ __MODULE__, admitted_run_id, kind, idempotency_key) do
    GenServer.call(
      server,
      {:fetch_side_effect, admitted_run_id, kind, idempotency_key},
      @call_timeout_ms
    )
  end

  @spec list_side_effects(GenServer.server(), String.t()) ::
          {:ok, [SideEffect.t()]} | {:error, side_effect_error()}
  def list_side_effects(server \\ __MODULE__, admitted_run_id) do
    GenServer.call(server, {:list_side_effects, admitted_run_id}, @call_timeout_ms)
  end

  @doc """
  Registers the stable local process identity owned by the current fenced
  lease. The identity must come from `ProcessSupervisor.recovery_identity/1`.
  """
  @spec register_process_group(GenServer.server(), Lease.t(), map()) ::
          {:ok, ProcessOwnership.t()} | {:error, process_ownership_error()}
  def register_process_group(server \\ __MODULE__, lease, process_identity) do
    GenServer.call(
      server,
      {:register_process_group, lease, process_identity},
      @call_timeout_ms
    )
  end

  @doc """
  Records verified termination or an unverifiable process-group outcome.

  An unverifiable outcome also moves a running lifecycle to `blocked` in the
  same transaction.
  """
  @spec record_process_group_termination(
          GenServer.server(),
          Lease.t(),
          pos_integer(),
          {:stopped | :unverifiable, map()}
        ) :: {:ok, ProcessOwnership.t()} | {:error, process_ownership_error()}
  def record_process_group_termination(
        server \\ __MODULE__,
        lease,
        process_group_id,
        outcome
      ) do
    GenServer.call(
      server,
      {:record_process_group_termination, lease, process_group_id, outcome},
      @call_timeout_ms
    )
  end

  @doc """
  Fences and reconstructs every durable nonterminal run for a new host owner.

  Interrupted running work becomes an immediate retry only after its prior
  process group is absent or verifiably terminated. Retry deadlines, blocked
  reasons, and cleanup authority are returned without consulting mutable
  workflow or registry configuration.
  """
  def recover_runs(server \\ __MODULE__, owner_id, opts \\ [])

  @spec recover_runs(GenServer.server(), String.t(), keyword()) ::
          {:ok, [Recovery.t()]} | {:error, recovery_error() | term()}

  def recover_runs(server, owner_id, opts) when is_list(opts) do
    process_terminator =
      Keyword.get(opts, :process_terminator, &terminate_recorded_process_group/1)

    credential_opts = Keyword.take(opts, [:env_fetcher])
    target_id = Keyword.get(opts, :target_id)

    with :ok <- validate_recovery_request(owner_id, process_terminator),
         :ok <- validate_recovery_target_id(target_id),
         {:ok, admitted_run_ids} <-
           GenServer.call(server, {:list_recoverable_runs, target_id}, @call_timeout_ms) do
      recover_admitted_runs(
        server,
        admitted_run_ids,
        owner_id,
        process_terminator,
        credential_opts,
        []
      )
    end
  end

  def recover_runs(_server, _owner_id, _opts), do: {:error, :invalid_recovery}

  @doc """
  Projects durable lifecycle state into the existing orchestrator state slots.
  """
  @spec project_runtime_state(Lifecycle.t()) ::
          :claimed | :running | :retrying | :blocked | :completed
  def project_runtime_state(%Lifecycle{state: :admitted}), do: :claimed
  def project_runtime_state(%Lifecycle{state: :running}), do: :running
  def project_runtime_state(%Lifecycle{state: :retrying}), do: :retrying
  def project_runtime_state(%Lifecycle{state: :blocked}), do: :blocked

  def project_runtime_state(%Lifecycle{state: state})
      when state in [:completed, :cleanup_pending, :cleaned],
      do: :completed

  @spec fetch_admission(GenServer.server(), String.t(), String.t()) ::
          {:ok, Admission.t()} | {:error, admission_error()}
  def fetch_admission(server \\ __MODULE__, target_id, tracker_issue_id) do
    GenServer.call(
      server,
      {:fetch_admission, target_id, tracker_issue_id},
      @call_timeout_ms
    )
  end

  @doc """
  Resolves current tracker and runner credentials for a pinned admission.

  Lease and fencing code must call this only after it owns the run.
  """
  @spec resolve_admission_credentials(Admission.t()) :: credential_resolution()
  def resolve_admission_credentials(admission),
    do: resolve_admission_credentials(admission, [])

  @spec resolve_admission_credentials(Admission.t(), keyword()) :: credential_resolution()
  def resolve_admission_credentials(%Admission{context: %ExecutionContext{} = context}, opts)
      when is_list(opts) do
    with {:ok, fetcher} <- credential_fetcher(opts),
         {:ok, _references} <- credential_references(context),
         {:ok, resolved} <- resolve_context_credentials(context, fetcher),
         :ok <- ExecutionContext.validate(resolved) do
      {:ok, resolved}
    else
      {:blocked, reason} -> {:blocked, reason}
      _invalid -> {:error, :invalid_admission}
    end
  end

  def resolve_admission_credentials(_admission, _opts), do: {:error, :invalid_admission}

  @impl true
  def init(opts) do
    database_path = path(opts)

    with {:ok, busy_timeout_ms} <- busy_timeout(opts, database_path),
         {:ok, clock} <- clock(opts, database_path),
         :ok <- prepare_store_path(database_path),
         {:ok, connection} <- open(database_path),
         {:ok, state} <- initialize_connection(connection, database_path, busy_timeout_ms) do
      {:ok, Map.put(state, :clock, clock)}
    else
      {:error, %Error{} = error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply, check_health(state.connection, state.path), state}
  end

  def handle_call(:inspect_runs, _from, state) do
    result = load_operator_snapshots(state.connection, state.path)
    log_operator_snapshot(result)
    {:reply, result, state}
  end

  def handle_call(:inspect_target_budgets, _from, state) do
    result =
      load_target_budget_snapshots(
        state.connection,
        state.path,
        state.clock
      )

    {:reply, result, state}
  end

  def handle_call({:preview_run_action, action, admitted_run_id}, _from, state) do
    result =
      preview_operator_run_action(
        state.connection,
        state.path,
        action,
        admitted_run_id
      )

    {:reply, result, state}
  end

  def handle_call(
        {:confirm_run_action, action, admitted_run_id, owner_id, confirmation},
        _from,
        state
      ) do
    result =
      confirm_operator_run_action(
        state.connection,
        state.path,
        state.clock,
        action,
        admitted_run_id,
        owner_id,
        confirmation
      )

    log_operator_action(action, admitted_run_id, result)
    {:reply, result, state}
  end

  def handle_call({:preview_prune, retention_days}, _from, state) do
    result =
      preview_terminal_prune(
        state.connection,
        state.path,
        state.clock,
        retention_days
      )

    {:reply, result, state}
  end

  def handle_call({:prune, retention_days, confirmation}, _from, state) do
    result =
      prune_terminal_runs(
        state.connection,
        state.path,
        state.clock,
        retention_days,
        confirmation
      )

    log_prune(result)
    {:reply, result, state}
  end

  def handle_call({:transaction, operation}, _from, state) do
    {:reply, run_transaction(state.connection, state.path, operation), state}
  end

  def handle_call({:admit_run, context}, _from, state) do
    result =
      with {:ok, now_ms} <- wall_clock_ms(state.clock, state.path),
           {:ok, admitted_at} <- timestamp_from_ms(now_ms, state.path),
           {:ok, record} <- prepare_admission(context, admitted_at) do
        persist_admission(state.connection, state.path, record)
      end

    {:reply, result, state}
  end

  def handle_call({:fetch_admission, target_id, tracker_issue_id}, _from, state) do
    {:reply, load_admission(state.connection, state.path, target_id, tracker_issue_id), state}
  end

  def handle_call({:fetch_token_budget, admitted_run_id}, _from, state) do
    result = load_token_budget(state.connection, state.path, admitted_run_id)
    {:reply, result, state}
  end

  def handle_call({:record_token_usage, lease, cumulative_total_tokens}, _from, state) do
    result =
      persist_token_usage(
        state.connection,
        state.path,
        lease,
        cumulative_total_tokens,
        state.clock
      )

    {:reply, result, state}
  end

  def handle_call({:release_token_reservation, lease}, _from, state) do
    result =
      release_token_reservation(
        state.connection,
        state.path,
        lease,
        state.clock
      )

    {:reply, result, state}
  end

  def handle_call({:acquire_token_reservation, lease}, _from, state) do
    result =
      acquire_token_reservation(
        state.connection,
        state.path,
        lease,
        state.clock
      )

    {:reply, result, state}
  end

  def handle_call({:acquire_lease, admitted_run_id, owner_id}, _from, state) do
    result =
      acquire_run_lease(
        state.connection,
        state.path,
        admitted_run_id,
        owner_id,
        state.clock
      )

    {:reply, result, state}
  end

  def handle_call({:renew_lease, lease}, _from, state) do
    result = renew_run_lease(state.connection, state.path, lease, state.clock)
    {:reply, result, state}
  end

  def handle_call({:transfer_lease, lease, new_owner_id}, _from, state) do
    result =
      transfer_run_lease(
        state.connection,
        state.path,
        lease,
        new_owner_id,
        state.clock
      )

    {:reply, result, state}
  end

  def handle_call({:release_lease, lease}, _from, state) do
    result = release_run_lease(state.connection, state.path, lease, state.clock)
    {:reply, result, state}
  end

  def handle_call({:expire_lease, admitted_run_id}, _from, state) do
    result =
      expire_run_lease(
        state.connection,
        state.path,
        admitted_run_id,
        state.clock
      )

    {:reply, result, state}
  end

  def handle_call({:list_recoverable_runs, target_id}, _from, state) do
    {:reply, select_recoverable_run_ids(state.connection, state.path, target_id), state}
  end

  def handle_call({:fence_run_for_recovery, admitted_run_id, owner_id}, _from, state) do
    result =
      fence_run_for_recovery(
        state.connection,
        state.path,
        admitted_run_id,
        owner_id,
        state.clock
      )

    {:reply, result, state}
  end

  def handle_call({:fetch_lifecycle, admitted_run_id}, _from, state) do
    {:reply, load_lifecycle(state.connection, state.path, admitted_run_id), state}
  end

  def handle_call({:fetch_target_lifecycle, target_id, tracker_issue_id}, _from, state) do
    result =
      load_target_lifecycle(
        state.connection,
        state.path,
        target_id,
        tracker_issue_id
      )

    {:reply, result, state}
  end

  def handle_call(
        {:transition_run, lease, expected_sequence, expected_state, next_state, evidence},
        _from,
        state
      ) do
    result =
      persist_lifecycle_transition(
        state.connection,
        state.path,
        lease,
        expected_sequence,
        expected_state,
        next_state,
        evidence,
        state.clock
      )

    {:reply, result, state}
  end

  def handle_call({:lifecycle_history, admitted_run_id}, _from, state) do
    {:reply, load_lifecycle_history(state.connection, state.path, admitted_run_id), state}
  end

  def handle_call(
        {:begin_side_effect, lease, kind, idempotency_key, intent},
        _from,
        state
      ) do
    result =
      persist_side_effect_intent(
        state.connection,
        state.path,
        lease,
        kind,
        idempotency_key,
        intent,
        state.clock
      )

    {:reply, result, state}
  end

  def handle_call(
        {:finish_side_effect, lease, kind, idempotency_key, outcome},
        _from,
        state
      ) do
    result =
      persist_side_effect_outcome(
        state.connection,
        state.path,
        lease,
        kind,
        idempotency_key,
        outcome,
        state.clock
      )

    {:reply, result, state}
  end

  def handle_call({:fetch_side_effect, admitted_run_id, kind, idempotency_key}, _from, state) do
    result =
      load_side_effect(
        state.connection,
        state.path,
        admitted_run_id,
        kind,
        idempotency_key
      )

    {:reply, result, state}
  end

  def handle_call({:list_side_effects, admitted_run_id}, _from, state) do
    {:reply, load_side_effects(state.connection, state.path, admitted_run_id), state}
  end

  def handle_call({:register_process_group, lease, process_identity}, _from, state) do
    result =
      persist_process_group(
        state.connection,
        state.path,
        lease,
        process_identity,
        state.clock
      )

    {:reply, result, state}
  end

  def handle_call(
        {:record_process_group_termination, lease, process_group_id, outcome},
        _from,
        state
      ) do
    result =
      persist_process_group_termination(
        state.connection,
        state.path,
        lease,
        process_group_id,
        outcome,
        state.clock
      )

    {:reply, result, state}
  end

  def handle_call(
        {:record_recovered_process_termination, lease, ownership, outcome},
        _from,
        state
      ) do
    result =
      persist_recovered_process_termination(
        state.connection,
        state.path,
        lease,
        ownership,
        outcome,
        state.clock
      )

    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, %{connection: connection, path: database_path}) do
    _ = Sqlite3.close(connection)
    _ = secure_database_files(database_path)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp load_operator_snapshots(connection, database_path) do
    sql = """
    SELECT
      admissions.admitted_run_id,
      admissions.target_id,
      admissions.tracker_issue_id,
      admissions.issue_identifier,
      lifecycles.state,
      lifecycles.sequence,
      leases.owner_id,
      COALESCE(leases.fencing_token, 0),
      leases.lease_deadline_ms,
      lifecycles.retry_attempt,
      lifecycles.retry_due_at_ms,
      lifecycles.blocked_reason,
      CASE
        WHEN EXISTS (
          SELECT 1 FROM side_effect_intents effects
          WHERE effects.admitted_run_id = admissions.admitted_run_id
            AND effects.state = 'reconciliation_required'
        ) THEN 'reconciliation_required'
        WHEN EXISTS (
          SELECT 1 FROM side_effect_intents effects
          WHERE effects.admitted_run_id = admissions.admitted_run_id
            AND effects.state = 'pending'
        ) THEN 'pending'
        WHEN EXISTS (
          SELECT 1 FROM side_effect_intents effects
          WHERE effects.admitted_run_id = admissions.admitted_run_id
            AND effects.state = 'failed'
        ) THEN 'failed'
        ELSE 'clear'
      END,
      CASE
        WHEN lifecycles.state = 'cleaned' THEN lifecycles.cleaned_at
        WHEN lifecycles.state = 'completed' THEN lifecycles.completed_at
        ELSE NULL
      END,
      lifecycles.updated_at
    FROM run_admissions admissions
    JOIN run_lifecycles lifecycles
      ON lifecycles.admitted_run_id = admissions.admitted_run_id
    LEFT JOIN run_leases leases
      ON leases.admitted_run_id = admissions.admitted_run_id
    ORDER BY admissions.admitted_at, admissions.admitted_run_id
    """

    with {:ok, rows} <-
           domain_query(
             connection,
             sql,
             [],
             database_path,
             "cannot inspect durable control-plane runs"
           ) do
      decode_operator_snapshots(rows, database_path)
    end
  end

  defp load_target_budget_snapshots(connection, database_path, clock) do
    with {:ok, now_ms} <- wall_clock_ms(clock, database_path),
         {:ok, now} <- DateTime.from_unix(now_ms, :millisecond) do
      load_target_budget_snapshots_for_date(connection, database_path, DateTime.to_date(now))
    else
      {:error, _reason} = error -> error
    end
  end

  defp load_target_budget_snapshots_for_date(connection, database_path, today) do
    admission_day = Date.to_iso8601(today)
    admission_week = today |> Date.beginning_of_week(:monday) |> Date.to_iso8601()

    sql = """
    SELECT
      target_id,
      coalesce(sum(reserved_tokens), 0),
      coalesce(sum(CASE WHEN admission_day = ?1 THEN reserved_tokens ELSE 0 END), 0),
      coalesce(sum(CASE WHEN admission_week = ?2 THEN reserved_tokens ELSE 0 END), 0),
      coalesce(sum(charged_tokens), 0),
      coalesce(sum(CASE WHEN admission_day = ?1 THEN charged_tokens ELSE 0 END), 0),
      coalesce(sum(CASE WHEN admission_week = ?2 THEN charged_tokens ELSE 0 END), 0),
      min(CASE WHEN admission_day = ?1 THEN daily_limit END),
      min(CASE WHEN admission_week = ?2 THEN weekly_limit END)
    FROM run_token_budgets
    GROUP BY target_id
    ORDER BY target_id
    """

    with {:ok, rows} <-
           domain_query(
             connection,
             sql,
             [admission_day, admission_week],
             database_path,
             "cannot inspect target token budgets"
           ) do
      decode_target_budget_snapshots(rows, database_path)
    end
  end

  defp decode_target_budget_snapshots(rows, database_path) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, snapshots} ->
      case decode_target_budget_snapshot(row) do
        {:ok, snapshot} ->
          {:cont, {:ok, [snapshot | snapshots]}}

        :error ->
          {:halt, corrupt_store(database_path, :invalid_target_budget_snapshot)}
      end
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_target_budget_snapshot([
         target_id,
         reserved_tokens,
         daily_reserved_tokens,
         weekly_reserved_tokens,
         charged_tokens,
         daily_charged_tokens,
         weekly_charged_tokens,
         daily_limit,
         weekly_limit
       ]) do
    with true <- valid_non_empty_string?(target_id),
         true <-
           Enum.all?(
             [
               reserved_tokens,
               daily_reserved_tokens,
               weekly_reserved_tokens,
               charged_tokens,
               daily_charged_tokens,
               weekly_charged_tokens
             ],
             &is_integer/1
           ),
         true <- valid_optional_integer?(daily_limit),
         true <- valid_optional_integer?(weekly_limit) do
      {:ok,
       %{
         target_id: Redaction.redact_string(target_id),
         reserved_tokens: reserved_tokens,
         daily_reserved_tokens: daily_reserved_tokens,
         weekly_reserved_tokens: weekly_reserved_tokens,
         charged_tokens: charged_tokens,
         daily_charged_tokens: daily_charged_tokens,
         weekly_charged_tokens: weekly_charged_tokens,
         daily_limit: daily_limit,
         weekly_limit: weekly_limit
       }}
    else
      _invalid -> :error
    end
  end

  defp decode_target_budget_snapshot(_invalid), do: :error

  defp decode_operator_snapshots(rows, database_path) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, snapshots} ->
      case decode_operator_snapshot(row) do
        {:ok, snapshot} -> {:cont, {:ok, [snapshot | snapshots]}}
        :error -> {:halt, corrupt_store(database_path, :invalid_operator_snapshot)}
      end
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_operator_snapshot([
         admitted_run_id,
         target_id,
         tracker_issue_id,
         issue_identifier,
         state,
         sequence,
         owner_id,
         fencing_generation,
         lease_expires_at_ms,
         retry_attempt,
         retry_due_at_ms,
         blocked_reason,
         reconciliation_status,
         terminal_at,
         updated_at
       ]) do
    with true <-
           valid_operator_identity?(
             admitted_run_id,
             target_id,
             tracker_issue_id,
             issue_identifier
           ),
         true <- valid_operator_lifecycle?(state, sequence),
         true <-
           valid_operator_lease?(
             owner_id,
             fencing_generation,
             lease_expires_at_ms
           ),
         true <-
           valid_operator_optional_fields?(
             retry_attempt,
             retry_due_at_ms,
             blocked_reason,
             terminal_at
           ),
         true <- valid_reconciliation_status?(reconciliation_status),
         true <- is_binary(updated_at) do
      {:ok,
       %{
         admitted_run_id: Redaction.redact_string(admitted_run_id),
         target_id: Redaction.redact_string(target_id),
         tracker_issue_id: Redaction.redact_string(tracker_issue_id),
         issue_identifier: Redaction.redact_string(issue_identifier),
         lifecycle_state: state,
         lifecycle_sequence: sequence,
         owner_id: redact_optional_string(owner_id),
         lease_expires_at_ms: lease_expires_at_ms,
         fencing_generation: fencing_generation,
         retry_attempt: retry_attempt,
         retry_due_at_ms: retry_due_at_ms,
         blocked_reason: redact_optional_string(blocked_reason),
         reconciliation_status: reconciliation_status,
         terminal_at: terminal_at,
         updated_at: updated_at
       }}
    else
      _invalid -> :error
    end
  end

  defp decode_operator_snapshot(_row), do: :error

  defp valid_operator_identity?(
         admitted_run_id,
         target_id,
         tracker_issue_id,
         issue_identifier
       ) do
    Enum.all?(
      [admitted_run_id, target_id, tracker_issue_id, issue_identifier],
      &valid_non_empty_string?/1
    )
  end

  defp valid_operator_lifecycle?(state, sequence) do
    state in [
      "admitted",
      "running",
      "retrying",
      "blocked",
      "completed",
      "cleanup_pending",
      "cleaned"
    ] and is_integer(sequence) and sequence > 0
  end

  defp valid_operator_lease?(owner_id, fencing_generation, lease_expires_at_ms) do
    valid_optional_string?(owner_id) and
      is_integer(fencing_generation) and fencing_generation >= 0 and
      valid_optional_integer?(lease_expires_at_ms)
  end

  defp valid_operator_optional_fields?(
         retry_attempt,
         retry_due_at_ms,
         blocked_reason,
         terminal_at
       ) do
    valid_optional_integer?(retry_attempt) and
      valid_optional_integer?(retry_due_at_ms) and
      valid_optional_string?(blocked_reason) and
      valid_optional_string?(terminal_at)
  end

  defp valid_reconciliation_status?(status),
    do: status in ["clear", "failed", "pending", "reconciliation_required"]

  defp valid_optional_string?(nil), do: true
  defp valid_optional_string?(value), do: is_binary(value)
  defp valid_optional_integer?(nil), do: true
  defp valid_optional_integer?(value), do: is_integer(value)

  defp redact_optional_string(nil), do: nil
  defp redact_optional_string(value), do: Redaction.redact_string(value)

  defp preview_operator_run_action(connection, database_path, action, admitted_run_id) do
    with :ok <- validate_operator_action(action),
         :ok <- validate_admitted_run_id(admitted_run_id),
         {:ok, snapshot} <-
           load_operator_snapshot(connection, database_path, admitted_run_id),
         :ok <- validate_operator_action_state(action, snapshot),
         :ok <- require_reconciled_side_effects(snapshot) do
      {:ok, operator_run_preview(action, snapshot)}
    end
  end

  defp load_operator_snapshot(connection, database_path, admitted_run_id) do
    with {:ok, snapshots} <- load_operator_snapshots(connection, database_path) do
      case Enum.find(snapshots, &(&1.admitted_run_id == admitted_run_id)) do
        nil -> {:error, :admission_not_found}
        snapshot -> {:ok, snapshot}
      end
    end
  end

  defp validate_operator_action(action) when action in @operator_run_actions, do: :ok
  defp validate_operator_action(_action), do: {:error, :invalid_operator_action}

  defp validate_operator_action_state(:resume, %{lifecycle_state: state})
       when state in ["admitted", "retrying", "blocked"],
       do: :ok

  defp validate_operator_action_state(:abandon, %{lifecycle_state: state})
       when state in ["admitted", "running", "retrying", "blocked"],
       do: :ok

  defp validate_operator_action_state(_action, _snapshot),
    do: {:error, :operator_action_not_allowed}

  defp require_reconciled_side_effects(%{reconciliation_status: status})
       when status in ["pending", "reconciliation_required"],
       do: {:error, :reconciliation_required}

  defp require_reconciled_side_effects(_snapshot), do: :ok

  defp operator_run_preview(action, snapshot) do
    %{
      operation: Atom.to_string(action),
      run: snapshot,
      confirmation:
        confirmation_token(%{
          "operation" => Atom.to_string(action),
          "admitted_run_id" => snapshot.admitted_run_id,
          "lifecycle_sequence" => snapshot.lifecycle_sequence,
          "lifecycle_state" => snapshot.lifecycle_state,
          "fencing_generation" => snapshot.fencing_generation
        })
    }
  end

  defp confirm_operator_run_action(
         connection,
         database_path,
         clock,
         action,
         admitted_run_id,
         owner_id,
         confirmation
       ) do
    with :ok <- validate_owner_id(owner_id),
         true <- is_binary(confirmation) and confirmation != "",
         {:ok, preview} <-
           preview_operator_run_action(
             connection,
             database_path,
             action,
             admitted_run_id
           ),
         true <- confirmation == preview.confirmation,
         {:ok, lease} <-
           acquire_run_lease(
             connection,
             database_path,
             admitted_run_id,
             owner_id,
             clock
           ) do
      apply_operator_run_action(
        connection,
        database_path,
        clock,
        action,
        preview.run,
        lease
      )
    else
      false -> {:error, :invalid_confirmation}
      {:error, _reason} = error -> error
    end
  end

  defp apply_operator_run_action(
         connection,
         database_path,
         clock,
         action,
         snapshot,
         lease
       ) do
    next_state = if action == :resume, do: :running, else: :completed
    evidence = if action == :resume, do: %{}, else: %{disposition: "abandoned_by_operator"}

    result =
      persist_lifecycle_transition(
        connection,
        database_path,
        lease,
        snapshot.lifecycle_sequence,
        String.to_existing_atom(snapshot.lifecycle_state),
        next_state,
        evidence,
        clock
      )

    case result do
      {:ok, lifecycle} ->
        {:ok,
         %{
           lease: lease,
           run: operator_snapshot_after_action(snapshot, lifecycle, lease)
         }}

      {:error, _reason} = error ->
        _ = release_run_lease(connection, database_path, lease, clock)
        error
    end
  end

  defp operator_snapshot_after_action(snapshot, lifecycle, lease) do
    %{
      snapshot
      | lifecycle_state: Atom.to_string(lifecycle.state),
        lifecycle_sequence: lifecycle.sequence,
        owner_id: redact_optional_string(lease.owner_id),
        lease_expires_at_ms: lease.deadline_ms,
        fencing_generation: lease.fencing_token,
        retry_attempt: lifecycle.retry_attempt,
        retry_due_at_ms: lifecycle.retry_due_at_ms,
        blocked_reason: redact_optional_string(lifecycle.blocked_reason),
        terminal_at: lifecycle.cleaned_at || lifecycle.completed_at,
        updated_at: lifecycle.updated_at
    }
  end

  defp preview_terminal_prune(connection, database_path, clock, retention_days) do
    with :ok <- validate_retention_days(retention_days),
         {:ok, now_ms} <- wall_clock_ms(clock, database_path),
         {:ok, eligible_run_ids} <-
           eligible_prune_run_ids(
             connection,
             database_path,
             now_ms,
             retention_days
           ),
         {:ok, snapshots} <- load_operator_snapshots(connection, database_path) do
      eligible = Enum.filter(snapshots, &(&1.admitted_run_id in eligible_run_ids))

      terminal_count =
        Enum.count(snapshots, fn snapshot ->
          snapshot.lifecycle_state in Enum.map(@terminal_lifecycle_states, &Atom.to_string/1)
        end)

      {:ok,
       %{
         operation: "prune",
         retention_days: retention_days,
         eligible_runs: eligible,
         eligible_count: length(eligible),
         preserved_terminal_count: terminal_count - length(eligible),
         confirmation:
           confirmation_token(%{
             "operation" => "prune",
             "retention_days" => retention_days,
             "eligible_run_ids" => eligible_run_ids
           })
       }}
    end
  end

  defp validate_retention_days(retention_days)
       when is_integer(retention_days) and retention_days > 0,
       do: :ok

  defp validate_retention_days(_retention_days), do: {:error, :invalid_retention}

  defp eligible_prune_run_ids(
         connection,
         database_path,
         now_ms,
         retention_days
       ) do
    cutoff_ms = now_ms - retention_days * 86_400_000

    with {:ok, cutoff} <- timestamp_from_ms(cutoff_ms, database_path) do
      sql = """
      SELECT lifecycles.admitted_run_id
      FROM run_lifecycles lifecycles
      LEFT JOIN run_leases leases
        ON leases.admitted_run_id = lifecycles.admitted_run_id
      WHERE lifecycles.state IN ('completed', 'cleaned')
        AND CASE
          WHEN lifecycles.state = 'cleaned' THEN lifecycles.cleaned_at
          ELSE lifecycles.completed_at
        END <= ?1
        AND (
          leases.owner_id IS NULL OR
          leases.lease_deadline_ms <= ?2
        )
        AND NOT EXISTS (
          SELECT 1 FROM run_process_ownership ownership
          WHERE ownership.admitted_run_id = lifecycles.admitted_run_id
            AND ownership.state != 'stopped'
        )
        AND NOT EXISTS (
          SELECT 1 FROM side_effect_intents effects
          WHERE effects.admitted_run_id = lifecycles.admitted_run_id
            AND (
              effects.state IN ('pending', 'reconciliation_required') OR
              effects.kind IN (?3, ?4)
            )
        )
      ORDER BY lifecycles.admitted_run_id
      """

      with {:ok, rows} <-
             domain_query(
               connection,
               sql,
               [cutoff, now_ms | @retained_artifact_kinds],
               database_path,
               "cannot preview terminal control-plane retention"
             ) do
        decode_run_id_rows(rows, database_path)
      end
    end
  end

  defp decode_run_id_rows(rows, database_path) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [admitted_run_id], {:ok, run_ids}
      when is_binary(admitted_run_id) and admitted_run_id != "" ->
        {:cont, {:ok, [admitted_run_id | run_ids]}}

      _invalid, _acc ->
        {:halt, corrupt_store(database_path, :invalid_prune_candidate)}
    end)
    |> case do
      {:ok, run_ids} -> {:ok, Enum.reverse(run_ids)}
      {:error, _reason} = error -> error
    end
  end

  defp prune_terminal_runs(
         connection,
         database_path,
         clock,
         retention_days,
         confirmation
       ) do
    with true <- is_binary(confirmation) and confirmation != "",
         {:ok, preview} <-
           preview_terminal_prune(
             connection,
             database_path,
             clock,
             retention_days
           ),
         true <- confirmation == preview.confirmation,
         run_ids = Enum.map(preview.eligible_runs, & &1.admitted_run_id),
         {:ok, pruned_count} <-
           delete_terminal_runs(
             connection,
             database_path,
             clock,
             retention_days,
             run_ids
           ) do
      {:ok,
       %{
         operation: "prune",
         retention_days: retention_days,
         pruned_count: pruned_count,
         pruned_run_ids: run_ids
       }}
    else
      false -> {:error, :invalid_confirmation}
      {:error, _reason} = error -> error
    end
  end

  defp delete_terminal_runs(
         connection,
         database_path,
         clock,
         retention_days,
         run_ids
       ) do
    with {:ok, now_ms} <- wall_clock_ms(clock, database_path) do
      delete_terminal_runs_at(
        connection,
        database_path,
        now_ms,
        retention_days,
        run_ids
      )
    end
  end

  defp delete_terminal_runs_at(
         connection,
         database_path,
         now_ms,
         retention_days,
         run_ids
       ) do
    run_transaction(connection, database_path, fn _transaction ->
      delete_current_terminal_runs(
        connection,
        database_path,
        now_ms,
        retention_days,
        run_ids
      )
    end)
  end

  defp delete_current_terminal_runs(
         connection,
         database_path,
         now_ms,
         retention_days,
         run_ids
       ) do
    with {:ok, current_run_ids} <-
           eligible_prune_run_ids(
             connection,
             database_path,
             now_ms,
             retention_days
           ),
         true <- Enum.all?(run_ids, &(&1 in current_run_ids)),
         :ok <-
           delete_run_rows(
             connection,
             database_path,
             "run_process_ownership",
             run_ids
           ),
         :ok <-
           delete_run_rows(
             connection,
             database_path,
             "side_effect_intents",
             run_ids
           ),
         :ok <-
           delete_run_rows(
             connection,
             database_path,
             "run_lifecycle_transitions",
             run_ids
           ),
         :ok <-
           delete_run_rows(
             connection,
             database_path,
             "run_lifecycles",
             run_ids
           ),
         :ok <- delete_run_rows(connection, database_path, "run_leases", run_ids),
         :ok <-
           delete_run_rows(
             connection,
             database_path,
             "run_admissions",
             run_ids
           ) do
      {:ok, length(run_ids)}
    else
      false -> {:error, :invalid_confirmation}
      {:error, _reason} = error -> error
    end
  end

  defp delete_run_rows(_connection, _database_path, _table, []), do: :ok

  defp delete_run_rows(connection, database_path, table, run_ids) do
    Enum.reduce_while(run_ids, :ok, fn admitted_run_id, :ok ->
      sql = "DELETE FROM #{table} WHERE admitted_run_id = ?1"

      case expect_no_rows(
             connection,
             sql,
             [admitted_run_id],
             database_path,
             "cannot prune terminal control-plane rows from #{table}"
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp confirmation_token(payload) do
    payload
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp log_operator_snapshot({:ok, snapshots}) do
    Logger.debug(fn ->
      "control_plane_snapshot=" <> Jason.encode!(snapshots)
    end)
  end

  defp log_operator_snapshot({:error, reason}) do
    Logger.warning(
      "control_plane_snapshot_failed=" <>
        Jason.encode!(Redaction.json_ready(%{reason: inspect(reason)}))
    )
  end

  defp log_operator_action(action, admitted_run_id, result) do
    Logger.info(fn ->
      "control_plane_operation=" <>
        Jason.encode!(
          Redaction.json_ready(%{
            operation: action,
            admitted_run_id: admitted_run_id,
            result: operator_result_status(result)
          })
        )
    end)
  end

  defp log_prune(result) do
    Logger.info(fn ->
      "control_plane_operation=" <>
        Jason.encode!(
          Redaction.json_ready(%{
            operation: :prune,
            result: operator_result_status(result)
          })
        )
    end)
  end

  defp operator_result_status({:ok, result}),
    do: %{status: :ok, result: result}

  defp operator_result_status({:error, reason}),
    do: %{status: :error, reason: inspect(reason)}

  defp validate_recovery_request(owner_id, process_terminator) do
    with :ok <- validate_owner_id(owner_id),
         true <- is_function(process_terminator, 1) do
      :ok
    else
      _invalid -> {:error, :invalid_recovery}
    end
  end

  defp validate_recovery_target_id(nil), do: :ok
  defp validate_recovery_target_id(target_id) when is_binary(target_id) and target_id != "", do: :ok
  defp validate_recovery_target_id(_target_id), do: {:error, :invalid_recovery}

  defp recover_admitted_runs(
         _server,
         [],
         _owner_id,
         _process_terminator,
         _credential_opts,
         recovered
       ),
       do: {:ok, Enum.reverse(recovered)}

  defp recover_admitted_runs(
         server,
         [admitted_run_id | rest],
         owner_id,
         process_terminator,
         credential_opts,
         recovered
       ) do
    with {:ok, claim} <-
           GenServer.call(
             server,
             {:fence_run_for_recovery, admitted_run_id, owner_id},
             @call_timeout_ms
           ),
         {:ok, lifecycle, process_blocked_reason} <-
           reconcile_recovery_process(server, claim, process_terminator),
         {:ok, recovery} <-
           build_recovery(server, claim, lifecycle, process_blocked_reason, credential_opts) do
      recover_admitted_runs(
        server,
        rest,
        owner_id,
        process_terminator,
        credential_opts,
        [recovery | recovered]
      )
    end
  end

  defp reconcile_recovery_process(
         server,
         %{lifecycle: %Lifecycle{state: :running}} = claim,
         _process_terminator
       )
       when is_nil(claim.previous_process_ownership) do
    reason = "recorded process ownership is missing after interruption"

    with {:ok, blocked} <-
           transition_run(
             server,
             claim.lease,
             claim.lifecycle.sequence,
             :running,
             :blocked,
             %{reason: reason}
           ) do
      {:ok, blocked, reason}
    end
  end

  defp reconcile_recovery_process(
         _server,
         %{previous_process_ownership: nil, lifecycle: lifecycle},
         _process_terminator
       ),
       do: {:ok, lifecycle, nil}

  defp reconcile_recovery_process(
         _server,
         %{
           previous_process_ownership: %ProcessOwnership{state: :stopped},
           lifecycle: lifecycle
         },
         _process_terminator
       ),
       do: {:ok, lifecycle, nil}

  defp reconcile_recovery_process(
         _server,
         %{
           previous_process_ownership: %ProcessOwnership{state: :unverifiable},
           lifecycle: lifecycle
         },
         _process_terminator
       ) do
    {:ok, lifecycle, "process group ownership requires operator reconciliation"}
  end

  defp reconcile_recovery_process(
         server,
         %{
           previous_process_ownership: %ProcessOwnership{state: :running} = ownership,
           lease: lease
         } = claim,
         process_terminator
       ) do
    outcome = invoke_process_terminator(process_terminator, ownership)

    with {:ok, _ownership} <-
           GenServer.call(
             server,
             {:record_recovered_process_termination, lease, ownership, outcome},
             @call_timeout_ms
           ),
         {:ok, lifecycle} <- fetch_lifecycle(server, lease.admitted_run_id) do
      case outcome do
        {:stopped, _evidence} -> {:ok, lifecycle, nil}
        {:unverifiable, _evidence} -> {:ok, lifecycle, lifecycle.blocked_reason || recovery_process_block_reason(claim)}
      end
    end
  end

  defp invoke_process_terminator(process_terminator, ownership) do
    case process_terminator.(ownership) do
      {state, evidence} when state in [:stopped, :unverifiable] and is_map(evidence) ->
        {state, evidence}

      other ->
        {:unverifiable, %{reason: "process terminator returned an invalid result", result: inspect(other)}}
    end
  rescue
    error ->
      {:unverifiable,
       %{
         reason: "process terminator raised",
         exception: inspect(error.__struct__),
         message: Exception.message(error)
       }}
  catch
    kind, reason ->
      {:unverifiable, %{reason: "process terminator exited", exit_kind: inspect(kind), detail: inspect(reason)}}
  end

  defp terminate_recorded_process_group(%ProcessOwnership{evidence: evidence}) do
    case Map.fetch(evidence, "identity") do
      {:ok, identity} when is_map(identity) ->
        ProcessSupervisor.terminate_recovered_group(identity)

      _missing ->
        {:unverifiable, %{reason: "persisted process identity is missing", verified_by: "control_plane"}}
    end
  end

  defp recovery_process_block_reason(%{lifecycle: %Lifecycle{state: :cleanup_pending}}),
    do: "cleanup is blocked by unverifiable process ownership"

  defp recovery_process_block_reason(_claim),
    do: "process group termination is unverifiable"

  defp build_recovery(
         _server,
         claim,
         lifecycle,
         process_blocked_reason,
         _credential_opts
       )
       when is_binary(process_blocked_reason) do
    {:ok, recovery(claim, lifecycle, :blocked, nil, process_blocked_reason)}
  end

  defp build_recovery(server, claim, %Lifecycle{state: :running} = lifecycle, nil, credential_opts) do
    case resolve_admission_credentials(claim.admission, credential_opts) do
      {:ok, context} ->
        attempt = (lifecycle.retry_attempt || 0) + 1

        with {:ok, retrying} <-
               transition_run(
                 server,
                 claim.lease,
                 lifecycle.sequence,
                 :running,
                 :retrying,
                 %{
                   attempt: attempt,
                   due_at_ms: claim.recovered_at_ms,
                   failure: %{
                     code: "host_restart",
                     message: "run was interrupted by a host-process restart"
                   }
                 }
               ) do
          {:ok, recovery(claim, retrying, :retry, context, nil)}
        end

      {:blocked, reason} ->
        block_recovery_credentials(server, claim, lifecycle, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_recovery(
         server,
         claim,
         %Lifecycle{state: state} = lifecycle,
         nil,
         credential_opts
       )
       when state in [:admitted, :retrying] do
    case resolve_admission_credentials(claim.admission, credential_opts) do
      {:ok, context} ->
        action = if state == :admitted, do: :dispatch, else: :retry
        {:ok, recovery(claim, lifecycle, action, context, nil)}

      {:blocked, reason} ->
        block_recovery_credentials(server, claim, lifecycle, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_recovery(
         _server,
         claim,
         %Lifecycle{state: :blocked} = lifecycle,
         nil,
         _credential_opts
       ) do
    {:ok, recovery(claim, lifecycle, :blocked, nil, lifecycle.blocked_reason)}
  end

  defp build_recovery(
         _server,
         claim,
         %Lifecycle{state: :cleanup_pending} = lifecycle,
         nil,
         credential_opts
       ) do
    case resolve_admission_credentials(claim.admission, credential_opts) do
      {:ok, context} ->
        {:ok, recovery(claim, lifecycle, :cleanup, context, nil)}

      {:blocked, reason} ->
        blocked_reason = credential_block_reason(reason)
        {:ok, recovery(claim, lifecycle, :blocked, nil, blocked_reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp block_recovery_credentials(server, claim, lifecycle, reason) do
    blocked_reason = credential_block_reason(reason)

    with {:ok, blocked} <-
           transition_run(
             server,
             claim.lease,
             lifecycle.sequence,
             lifecycle.state,
             :blocked,
             %{reason: blocked_reason}
           ) do
      {:ok, recovery(claim, blocked, :blocked, nil, blocked_reason)}
    end
  end

  defp credential_block_reason(:missing_credentials), do: "recovery credentials are missing"

  defp credential_block_reason(:credential_resolution_failed),
    do: "recovery credential resolution failed"

  defp recovery(claim, lifecycle, action, context, blocked_reason) do
    %Recovery{
      admission: claim.admission,
      lifecycle: lifecycle,
      lease: claim.lease,
      action: action,
      execution_context: context,
      blocked_reason: blocked_reason
    }
  end

  defp busy_timeout(opts, database_path) do
    timeout_ms =
      Keyword.get(
        opts,
        :busy_timeout,
        Application.get_env(:symphony_elixir, :control_plane_busy_timeout, @default_busy_timeout_ms)
      )

    if is_integer(timeout_ms) and timeout_ms >= 0 and timeout_ms <= @maximum_busy_timeout_ms do
      {:ok, timeout_ms}
    else
      {:error,
       error(
         :invalid_busy_timeout,
         database_path,
         "control-plane busy timeout must be between 0 and #{@maximum_busy_timeout_ms} milliseconds",
         timeout_ms
       )}
    end
  end

  defp clock(opts, database_path) do
    case Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end) do
      clock when is_function(clock, 0) ->
        {:ok, clock}

      invalid ->
        {:error,
         error(
           :invalid_clock,
           database_path,
           "control-plane clock must be a zero-arity function",
           invalid
         )}
    end
  end

  defp wall_clock_ms(clock, database_path) do
    case invoke_clock(clock) do
      {:ok, now_ms} when is_integer(now_ms) and now_ms >= 0 ->
        {:ok, now_ms}

      {:ok, invalid} ->
        {:error,
         error(
           :clock_failed,
           database_path,
           "control-plane wall clock returned an invalid millisecond timestamp",
           invalid
         )}

      {:error, reason} ->
        {:error,
         error(
           :clock_failed,
           database_path,
           "control-plane wall clock is unavailable",
           reason
         )}
    end
  end

  defp invoke_clock(clock) do
    {:ok, clock.()}
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp prepare_store_path(database_path) do
    root = Path.dirname(database_path)

    with :ok <- ensure_private_directory(root, database_path) do
      ensure_private_database_file(database_path)
    end
  end

  defp ensure_private_directory(root, database_path) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        chmod(root, 0o700, database_path, :unwritable_store, "cannot secure control-plane config root")

      {:ok, %File.Stat{type: type}} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "control-plane config root is not a directory",
           type
         )}

      {:error, :enoent} ->
        with :ok <- file_result(File.mkdir_p(root), database_path, :unwritable_store, "cannot create control-plane config root"),
             {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
             :ok <- chmod(root, 0o700, database_path, :unwritable_store, "cannot secure control-plane config root") do
          :ok
        else
          {:ok, %File.Stat{type: type}} ->
            {:error,
             error(
               :unwritable_store,
               database_path,
               "control-plane config root is not a directory",
               type
             )}

          {:error, %Error{} = store_error} ->
            {:error, store_error}

          {:error, reason} ->
            {:error,
             error(
               :unwritable_store,
               database_path,
               "cannot inspect control-plane config root after creation",
               reason
             )}
        end

      {:error, reason} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "cannot inspect control-plane config root",
           reason
         )}
    end
  end

  defp ensure_private_database_file(database_path) do
    case File.lstat(database_path) do
      {:ok, %File.Stat{type: :regular}} ->
        chmod(database_path, 0o600, database_path, :unwritable_store, "cannot secure control-plane database")

      {:ok, %File.Stat{type: type}} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "control-plane database path is not a regular file",
           type
         )}

      {:error, :enoent} ->
        create_private_database_file(database_path)

      {:error, reason} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "cannot inspect control-plane database path",
           reason
         )}
    end
  end

  defp create_private_database_file(database_path) do
    case File.open(database_path, [:write, :binary, :exclusive]) do
      {:ok, device} ->
        close_result = File.close(device)

        with :ok <-
               file_result(
                 close_result,
                 database_path,
                 :unwritable_store,
                 "cannot close new control-plane database"
               ) do
          chmod(
            database_path,
            0o600,
            database_path,
            :unwritable_store,
            "cannot secure new control-plane database"
          )
        end

      {:error, :eexist} ->
        ensure_private_database_file(database_path)

      {:error, reason} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "cannot create control-plane database",
           reason
         )}
    end
  end

  defp chmod(path, mode, database_path, code, message) do
    file_result(File.chmod(path, mode), database_path, code, message)
  end

  defp file_result(:ok, _database_path, _code, _message), do: :ok

  defp file_result({:error, reason}, database_path, code, message) do
    {:error, error(code, database_path, message, reason)}
  end

  defp open(database_path) do
    case Sqlite3.open(database_path, mode: :readwrite) do
      {:ok, connection} -> {:ok, connection}
      {:error, reason} -> {:error, error(:unwritable_store, database_path, "cannot open control-plane database for writing", reason)}
    end
  end

  defp initialize_connection(connection, database_path, busy_timeout_ms) do
    case configure_and_migrate(connection, database_path, busy_timeout_ms) do
      :ok ->
        {:ok, %{connection: connection, path: database_path, busy_timeout_ms: busy_timeout_ms}}

      {:error, %Error{} = store_error} ->
        _ = Sqlite3.close(connection)
        {:error, store_error}
    end
  end

  defp configure_and_migrate(connection, database_path, busy_timeout_ms) do
    with :ok <-
           sqlite_result(
             Sqlite3.set_busy_timeout(connection, busy_timeout_ms),
             database_path,
             :store_configuration_failed,
             "cannot configure bounded SQLite busy handling"
           ),
         :ok <- quick_check(connection, database_path),
         :ok <- execute(connection, "PRAGMA foreign_keys = ON", database_path, :store_configuration_failed),
         :ok <-
           verify_single_value(
             connection,
             "PRAGMA foreign_keys",
             1,
             database_path,
             :store_configuration_failed,
             "SQLite foreign-key enforcement is unavailable"
           ),
         :ok <- execute(connection, "PRAGMA synchronous = FULL", database_path, :store_configuration_failed),
         :ok <- execute(connection, "PRAGMA trusted_schema = OFF", database_path, :store_configuration_failed),
         :ok <- migrate(connection, database_path),
         :ok <- configure_wal(connection, database_path, busy_timeout_ms),
         {:ok, _health} <- check_health(connection, database_path) do
      secure_database_files(database_path)
    end
  end

  defp configure_wal(connection, database_path, busy_timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + busy_timeout_ms
    configure_wal_until(connection, database_path, deadline_ms)
  end

  defp configure_wal_until(connection, database_path, deadline_ms) do
    case query(connection, "PRAGMA journal_mode = WAL") do
      {:ok, [[mode]]} when mode in ["wal", "WAL"] ->
        :ok

      {:ok, rows} ->
        {:error, error(:store_configuration_failed, database_path, "SQLite WAL mode is unavailable", rows)}

      {:error, reason} when reason in [:busy, :busy_timeout] ->
        retry_wal_or_fail(connection, database_path, deadline_ms, reason)

      {:error, reason} ->
        {:error, error(:store_configuration_failed, database_path, "cannot enable SQLite WAL mode", reason)}
    end
  end

  defp retry_wal_or_fail(connection, database_path, deadline_ms, reason) do
    if System.monotonic_time(:millisecond) < deadline_ms do
      Process.sleep(10)
      configure_wal_until(connection, database_path, deadline_ms)
    else
      {:error, error(:store_configuration_failed, database_path, "cannot enable SQLite WAL mode before the busy timeout", reason)}
    end
  end

  defp migrate(connection, database_path) do
    with :ok <- execute(connection, "BEGIN IMMEDIATE", database_path, :migration_failed),
         {:ok, version} <- read_schema_version(connection, database_path),
         :ok <- validate_schema_version(version, database_path),
         :ok <- apply_migrations(connection, version, database_path),
         :ok <- execute(connection, "COMMIT", database_path, :migration_failed) do
      :ok
    else
      {:error, %Error{} = migration_error} ->
        _ = Sqlite3.execute(connection, "ROLLBACK")
        {:error, migration_error}
    end
  end

  defp validate_schema_version(version, _database_path) when version <= @schema_version, do: :ok

  defp validate_schema_version(version, database_path) do
    {:error,
     error(
       :unsupported_schema_version,
       database_path,
       "control-plane schema version #{version} is newer than supported version #{@schema_version}",
       version
     )}
  end

  defp apply_migrations(connection, 0, database_path) do
    migration = """
    CREATE TABLE schema_migrations (
      version INTEGER PRIMARY KEY CHECK (version > 0),
      applied_at TEXT NOT NULL
    );
    INSERT INTO schema_migrations (version, applied_at)
    VALUES (1, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
    PRAGMA user_version = 1;
    """

    with :ok <- execute(connection, migration, database_path, :migration_failed) do
      apply_migrations(connection, 1, database_path)
    end
  end

  defp apply_migrations(connection, 1, database_path) do
    migration = """
    CREATE TABLE target_generations (
      target_id TEXT NOT NULL,
      registry_generation TEXT NOT NULL,
      policy_hash TEXT NOT NULL,
      repo_manifest_hash TEXT NOT NULL,
      target_context_json TEXT NOT NULL,
      secret_references_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      PRIMARY KEY (target_id, registry_generation)
    );

    CREATE TABLE run_admissions (
      admitted_run_id TEXT PRIMARY KEY,
      target_id TEXT NOT NULL,
      tracker_issue_id TEXT NOT NULL,
      issue_identifier TEXT NOT NULL,
      registry_generation TEXT NOT NULL,
      policy_hash TEXT NOT NULL,
      repo_manifest_hash TEXT NOT NULL,
      role TEXT NOT NULL,
      execution_profile_json TEXT NOT NULL,
      workspace_authority_json TEXT NOT NULL,
      runner_policy_json TEXT NOT NULL,
      checks_json TEXT NOT NULL,
      delivery_gates_json TEXT NOT NULL,
      context_json TEXT NOT NULL,
      provenance_json TEXT NOT NULL,
      secret_references_json TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state = 'admitted'),
      admitted_at TEXT NOT NULL,
      UNIQUE (target_id, tracker_issue_id),
      FOREIGN KEY (target_id, registry_generation)
        REFERENCES target_generations (target_id, registry_generation)
    );

    INSERT INTO schema_migrations (version, applied_at)
    VALUES (2, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
    PRAGMA user_version = 2;
    """

    with :ok <- execute(connection, migration, database_path, :migration_failed) do
      apply_migrations(connection, 2, database_path)
    end
  end

  defp apply_migrations(connection, 2, database_path) do
    migration = """
    CREATE TABLE run_leases (
      admitted_run_id TEXT PRIMARY KEY,
      owner_id TEXT,
      fencing_token INTEGER NOT NULL CHECK (fencing_token > 0),
      lease_deadline_ms INTEGER,
      acquired_at_ms INTEGER NOT NULL,
      renewed_at_ms INTEGER NOT NULL,
      last_observed_at_ms INTEGER NOT NULL,
      CHECK (
        (owner_id IS NULL AND lease_deadline_ms IS NULL) OR
        (length(owner_id) > 0 AND lease_deadline_ms IS NOT NULL)
      ),
      FOREIGN KEY (admitted_run_id)
        REFERENCES run_admissions (admitted_run_id)
    );

    INSERT INTO schema_migrations (version, applied_at)
    VALUES (3, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
    PRAGMA user_version = 3;
    """

    with :ok <- execute(connection, migration, database_path, :migration_failed) do
      apply_migrations(connection, 3, database_path)
    end
  end

  defp apply_migrations(connection, 3, database_path) do
    migration = """
    CREATE TABLE run_lifecycles (
      admitted_run_id TEXT PRIMARY KEY,
      state TEXT NOT NULL CHECK (
        state IN (
          'admitted',
          'running',
          'retrying',
          'blocked',
          'completed',
          'cleanup_pending',
          'cleaned'
        )
      ),
      sequence INTEGER NOT NULL CHECK (sequence > 0),
      retry_attempt INTEGER CHECK (retry_attempt > 0),
      retry_due_at_ms INTEGER CHECK (retry_due_at_ms >= 0),
      failure_json TEXT,
      blocked_reason TEXT CHECK (blocked_reason IS NULL OR length(blocked_reason) > 0),
      completion_disposition TEXT CHECK (
        completion_disposition IS NULL OR length(completion_disposition) > 0
      ),
      cleanup_authority_json TEXT,
      admitted_at TEXT NOT NULL,
      started_at TEXT,
      completed_at TEXT,
      cleanup_pending_at TEXT,
      cleaned_at TEXT,
      updated_at TEXT NOT NULL,
      CHECK (
        state != 'retrying' OR
        (retry_attempt IS NOT NULL AND retry_due_at_ms IS NOT NULL AND failure_json IS NOT NULL)
      ),
      CHECK (state != 'blocked' OR blocked_reason IS NOT NULL),
      CHECK (
        state NOT IN ('completed', 'cleanup_pending', 'cleaned') OR
        (completion_disposition IS NOT NULL AND completed_at IS NOT NULL)
      ),
      CHECK (
        state NOT IN ('cleanup_pending', 'cleaned') OR
        (cleanup_authority_json IS NOT NULL AND cleanup_pending_at IS NOT NULL)
      ),
      CHECK (state != 'cleaned' OR cleaned_at IS NOT NULL),
      FOREIGN KEY (admitted_run_id)
        REFERENCES run_admissions (admitted_run_id)
    );

    CREATE TABLE run_lifecycle_transitions (
      admitted_run_id TEXT NOT NULL,
      sequence INTEGER NOT NULL CHECK (sequence > 0),
      from_state TEXT CHECK (
        from_state IS NULL OR
        from_state IN (
          'admitted',
          'running',
          'retrying',
          'blocked',
          'completed',
          'cleanup_pending',
          'cleaned'
        )
      ),
      to_state TEXT NOT NULL CHECK (
        to_state IN (
          'admitted',
          'running',
          'retrying',
          'blocked',
          'completed',
          'cleanup_pending',
          'cleaned'
        )
      ),
      owner_id TEXT CHECK (owner_id IS NULL OR length(owner_id) > 0),
      fencing_token INTEGER CHECK (fencing_token > 0),
      occurred_at TEXT NOT NULL,
      evidence_json TEXT NOT NULL,
      PRIMARY KEY (admitted_run_id, sequence),
      CHECK (
        (owner_id IS NULL AND fencing_token IS NULL) OR
        (owner_id IS NOT NULL AND fencing_token IS NOT NULL)
      ),
      FOREIGN KEY (admitted_run_id)
        REFERENCES run_admissions (admitted_run_id)
    );

    INSERT INTO run_lifecycles (
      admitted_run_id,
      state,
      sequence,
      admitted_at,
      updated_at
    )
    SELECT admitted_run_id, 'admitted', 1, admitted_at, admitted_at
    FROM run_admissions;

    INSERT INTO run_lifecycle_transitions (
      admitted_run_id,
      sequence,
      from_state,
      to_state,
      owner_id,
      fencing_token,
      occurred_at,
      evidence_json
    )
    SELECT admitted_run_id, 1, NULL, 'admitted', NULL, NULL, admitted_at, '{}'
    FROM run_admissions;

    INSERT INTO schema_migrations (version, applied_at)
    VALUES (4, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
    PRAGMA user_version = 4;
    """

    with :ok <- execute(connection, migration, database_path, :migration_failed) do
      apply_migrations(connection, 4, database_path)
    end
  end

  defp apply_migrations(connection, 4, database_path) do
    migration = """
    CREATE TABLE side_effect_intents (
      admitted_run_id TEXT NOT NULL,
      target_id TEXT NOT NULL,
      tracker_issue_id TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (
        kind IN (
          'tracker_write',
          'publish_preflight',
          'publish_handoff',
          'handoff_route',
          'workspace_cleanup'
        )
      ),
      idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) > 0),
      artifact_path TEXT NOT NULL CHECK (length(artifact_path) > 0),
      state TEXT NOT NULL CHECK (
        state IN ('pending', 'succeeded', 'failed', 'reconciliation_required')
      ),
      owner_id TEXT NOT NULL CHECK (length(owner_id) > 0),
      fencing_token INTEGER NOT NULL CHECK (fencing_token > 0),
      intent_json TEXT NOT NULL,
      outcome_json TEXT,
      started_at TEXT NOT NULL,
      completed_at TEXT,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (admitted_run_id, kind, idempotency_key),
      UNIQUE (artifact_path),
      CHECK (
        (state = 'pending' AND outcome_json IS NULL AND completed_at IS NULL) OR
        (state = 'reconciliation_required' AND outcome_json IS NOT NULL AND completed_at IS NULL) OR
        (state IN ('succeeded', 'failed') AND outcome_json IS NOT NULL AND completed_at IS NOT NULL)
      ),
      FOREIGN KEY (admitted_run_id)
        REFERENCES run_admissions (admitted_run_id)
    );

    CREATE TABLE run_process_ownership (
      admitted_run_id TEXT NOT NULL,
      target_id TEXT NOT NULL,
      tracker_issue_id TEXT NOT NULL,
      owner_id TEXT NOT NULL CHECK (length(owner_id) > 0),
      fencing_token INTEGER NOT NULL CHECK (fencing_token > 0),
      process_group_id INTEGER NOT NULL CHECK (process_group_id > 0),
      state TEXT NOT NULL CHECK (state IN ('running', 'stopped', 'unverifiable')),
      evidence_json TEXT NOT NULL,
      started_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (admitted_run_id, fencing_token),
      UNIQUE (admitted_run_id, process_group_id),
      FOREIGN KEY (admitted_run_id)
        REFERENCES run_admissions (admitted_run_id)
    );

    INSERT INTO schema_migrations (version, applied_at)
    VALUES (5, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
    PRAGMA user_version = 5;
    """

    with :ok <- execute(connection, migration, database_path, :migration_failed) do
      apply_migrations(connection, 5, database_path)
    end
  end

  defp apply_migrations(connection, 5, database_path) do
    migration = """
    CREATE TABLE run_token_budgets (
      admitted_run_id TEXT PRIMARY KEY,
      target_id TEXT NOT NULL CHECK (length(target_id) > 0),
      admission_day TEXT NOT NULL CHECK (length(admission_day) = 10),
      admission_week TEXT NOT NULL CHECK (length(admission_week) = 10),
      per_run_limit INTEGER NOT NULL CHECK (per_run_limit > 0),
      daily_limit INTEGER NOT NULL CHECK (daily_limit >= per_run_limit),
      weekly_limit INTEGER NOT NULL CHECK (weekly_limit >= daily_limit),
      cumulative_tokens INTEGER NOT NULL DEFAULT 0 CHECK (
        cumulative_tokens >= 0 AND cumulative_tokens <= per_run_limit
      ),
      charged_tokens INTEGER NOT NULL DEFAULT 0 CHECK (
        charged_tokens >= 0 AND charged_tokens = cumulative_tokens
      ),
      reserved_tokens INTEGER NOT NULL CHECK (
        reserved_tokens >= 0 AND
        charged_tokens + reserved_tokens <= per_run_limit
      ),
      state TEXT NOT NULL CHECK (state IN ('active', 'released', 'terminal')),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      CHECK (
        (state = 'active' AND charged_tokens + reserved_tokens = per_run_limit) OR
        (state IN ('released', 'terminal') AND reserved_tokens = 0)
      ),
      FOREIGN KEY (admitted_run_id)
        REFERENCES run_admissions (admitted_run_id)
    );

    CREATE INDEX run_token_budgets_daily
      ON run_token_budgets (target_id, admission_day);
    CREATE INDEX run_token_budgets_weekly
      ON run_token_budgets (target_id, admission_week);

    INSERT INTO schema_migrations (version, applied_at)
    VALUES (6, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
    PRAGMA user_version = 6;
    """

    with :ok <- ensure_token_budget_migration_safe(connection, database_path) do
      execute(connection, migration, database_path, :migration_failed)
    end
  end

  defp apply_migrations(_connection, @schema_version, _database_path), do: :ok

  defp ensure_token_budget_migration_safe(connection, database_path) do
    sql = """
    SELECT admission.admitted_run_id, target.target_context_json
    FROM run_admissions AS admission
    JOIN target_generations AS target
      ON target.target_id = admission.target_id
     AND target.registry_generation = admission.registry_generation
    """

    case query(connection, sql) do
      {:ok, rows} ->
        validate_legacy_token_budget_rows(rows, database_path)

      {:error, reason} ->
        {:error,
         error(
           :migration_failed,
           database_path,
           "cannot inspect existing admissions before token budget migration",
           reason
         )}
    end
  end

  defp validate_legacy_token_budget_rows([], _database_path), do: :ok

  defp validate_legacy_token_budget_rows(
         [[admitted_run_id, target_context_json] | rest],
         database_path
       )
       when is_binary(admitted_run_id) and admitted_run_id != "" and
              is_binary(target_context_json) do
    case decode_json(target_context_json) do
      {:ok, %{"budget_limits" => limits}} when is_map(limits) and map_size(limits) == 0 ->
        validate_legacy_token_budget_rows(rest, database_path)

      {:ok, %{"budget_limits" => limits}} when is_map(limits) ->
        {:error,
         error(
           :migration_failed,
           database_path,
           "cannot safely migrate an admitted run whose token usage was not persisted by schema version 5",
           admitted_run_id
         )}

      _invalid ->
        corrupt_store(database_path, {:invalid_legacy_token_budget, admitted_run_id})
    end
  end

  defp validate_legacy_token_budget_rows(_rows, database_path),
    do: corrupt_store(database_path, :invalid_legacy_token_budget_rows)

  defp read_schema_version(connection, database_path) do
    case query(connection, "PRAGMA user_version") do
      {:ok, [[version]]} when is_integer(version) and version >= 0 -> {:ok, version}
      {:ok, rows} -> {:error, error(:corrupt_store, database_path, "control-plane schema version is invalid", rows)}
      {:error, reason} -> {:error, error(:corrupt_store, database_path, "cannot read control-plane schema version", reason)}
    end
  end

  defp check_health(connection, database_path) do
    with :ok <- quick_check(connection, database_path),
         {:ok, version} <- read_schema_version(connection, database_path),
         :ok <- validate_current_schema(connection, version, database_path) do
      {:ok, %{path: database_path, schema_version: version, status: :healthy}}
    end
  end

  defp quick_check(connection, database_path) do
    case query(connection, "PRAGMA quick_check(1)") do
      {:ok, [["ok"]]} -> :ok
      {:ok, rows} -> {:error, error(:corrupt_store, database_path, "control-plane database failed SQLite quick check", rows)}
      {:error, reason} -> {:error, error(:corrupt_store, database_path, "cannot complete SQLite quick check", reason)}
    end
  end

  defp validate_current_schema(connection, @schema_version, database_path) do
    with {:ok, [[@schema_version]]} <-
           query(connection, "SELECT max(version) FROM schema_migrations"),
         :ok <- validate_admission_schema(connection, database_path),
         :ok <- validate_lease_schema(connection, database_path),
         :ok <- validate_lifecycle_schema(connection, database_path),
         :ok <- validate_side_effect_schema(connection, database_path),
         :ok <- validate_token_budget_schema(connection, database_path) do
      :ok
    else
      {:ok, rows} ->
        {:error,
         error(
           :corrupt_store,
           database_path,
           "control-plane migration history does not match its schema version",
           rows
         )}

      {:error, %Error{} = store_error} ->
        {:error, store_error}

      {:error, reason} ->
        {:error,
         error(
           :corrupt_store,
           database_path,
           "cannot read control-plane migration history",
           reason
         )}
    end
  end

  defp validate_current_schema(_connection, version, database_path) do
    {:error,
     error(
       :unsupported_schema_version,
       database_path,
       "control-plane schema version #{version} is not supported by this release",
       version
     )}
  end

  defp validate_admission_schema(connection, database_path) do
    sql = """
    SELECT
      target.target_id,
      target.registry_generation,
      target.policy_hash,
      target.repo_manifest_hash,
      target.target_context_json,
      target.secret_references_json,
      admission.admitted_run_id,
      admission.tracker_issue_id,
      admission.context_json,
      admission.provenance_json,
      admission.state
    FROM target_generations AS target
    LEFT JOIN run_admissions AS admission
      ON admission.target_id = target.target_id
     AND admission.registry_generation = target.registry_generation
    LIMIT 0
    """

    case query(connection, sql) do
      {:ok, []} -> :ok
      {:ok, rows} -> corrupt_store(database_path, {:unexpected_schema_rows, length(rows)})
      {:error, reason} -> corrupt_store(database_path, {:invalid_admission_schema, reason})
    end
  end

  defp validate_lease_schema(connection, database_path) do
    sql = """
    SELECT
      lease.admitted_run_id,
      lease.owner_id,
      lease.fencing_token,
      lease.lease_deadline_ms,
      lease.acquired_at_ms,
      lease.renewed_at_ms,
      lease.last_observed_at_ms
    FROM run_leases AS lease
    JOIN run_admissions AS admission
      ON admission.admitted_run_id = lease.admitted_run_id
    LIMIT 0
    """

    case query(connection, sql) do
      {:ok, []} -> :ok
      {:ok, rows} -> corrupt_store(database_path, {:unexpected_lease_schema_rows, length(rows)})
      {:error, reason} -> corrupt_store(database_path, {:invalid_lease_schema, reason})
    end
  end

  defp validate_lifecycle_schema(connection, database_path) do
    sql = """
    SELECT
      lifecycle.admitted_run_id,
      lifecycle.state,
      lifecycle.sequence,
      lifecycle.retry_attempt,
      lifecycle.retry_due_at_ms,
      lifecycle.failure_json,
      lifecycle.blocked_reason,
      lifecycle.completion_disposition,
      lifecycle.cleanup_authority_json,
      lifecycle.admitted_at,
      lifecycle.started_at,
      lifecycle.completed_at,
      lifecycle.cleanup_pending_at,
      lifecycle.cleaned_at,
      lifecycle.updated_at,
      transition.from_state,
      transition.to_state,
      transition.owner_id,
      transition.fencing_token,
      transition.occurred_at,
      transition.evidence_json
    FROM run_lifecycles AS lifecycle
    JOIN run_admissions AS admission
      ON admission.admitted_run_id = lifecycle.admitted_run_id
    LEFT JOIN run_lifecycle_transitions AS transition
      ON transition.admitted_run_id = lifecycle.admitted_run_id
    LIMIT 0
    """

    case query(connection, sql) do
      {:ok, []} -> :ok
      {:ok, rows} -> corrupt_store(database_path, {:unexpected_lifecycle_schema_rows, length(rows)})
      {:error, reason} -> corrupt_store(database_path, {:invalid_lifecycle_schema, reason})
    end
  end

  defp validate_side_effect_schema(connection, database_path) do
    sql = """
    SELECT
      effect.admitted_run_id,
      effect.target_id,
      effect.tracker_issue_id,
      effect.kind,
      effect.idempotency_key,
      effect.artifact_path,
      effect.state,
      effect.owner_id,
      effect.fencing_token,
      effect.intent_json,
      effect.outcome_json,
      effect.started_at,
      effect.completed_at,
      effect.updated_at,
      process.owner_id,
      process.fencing_token,
      process.process_group_id,
      process.state,
      process.evidence_json,
      process.started_at,
      process.updated_at
    FROM side_effect_intents AS effect
    JOIN run_admissions AS admission
      ON admission.admitted_run_id = effect.admitted_run_id
    LEFT JOIN run_process_ownership AS process
      ON process.admitted_run_id = effect.admitted_run_id
    LIMIT 0
    """

    case query(connection, sql) do
      {:ok, []} -> :ok
      {:ok, rows} -> corrupt_store(database_path, {:unexpected_side_effect_schema_rows, length(rows)})
      {:error, reason} -> corrupt_store(database_path, {:invalid_side_effect_schema, reason})
    end
  end

  defp validate_token_budget_schema(connection, database_path) do
    schema_sql = """
    SELECT
      budget.admitted_run_id,
      budget.target_id,
      budget.admission_day,
      budget.admission_week,
      budget.per_run_limit,
      budget.daily_limit,
      budget.weekly_limit,
      budget.cumulative_tokens,
      budget.charged_tokens,
      budget.reserved_tokens,
      budget.state,
      budget.created_at,
      budget.updated_at
    FROM run_token_budgets AS budget
    JOIN run_admissions AS admission
      ON admission.admitted_run_id = budget.admitted_run_id
     AND admission.target_id = budget.target_id
    LIMIT 0
    """

    invariant_sql = """
    SELECT target_id
    FROM run_token_budgets
    GROUP BY target_id, admission_day
    HAVING sum(charged_tokens + reserved_tokens) > min(daily_limit)
    UNION ALL
    SELECT target_id
    FROM run_token_budgets
    GROUP BY target_id, admission_week
    HAVING sum(charged_tokens + reserved_tokens) > min(weekly_limit)
    LIMIT 1
    """

    with {:ok, []} <- query(connection, schema_sql),
         {:ok, []} <- query(connection, invariant_sql) do
      :ok
    else
      {:ok, rows} -> corrupt_store(database_path, {:invalid_token_budget_balances, rows})
      {:error, reason} -> corrupt_store(database_path, {:invalid_token_budget_schema, reason})
    end
  end

  defp select_recoverable_run_ids(connection, database_path, target_id) do
    states = Enum.map_join(@recoverable_lifecycle_states, ", ", &"'#{Atom.to_string(&1)}'")

    {target_filter, params} =
      if is_binary(target_id),
        do: {" AND admission.target_id = ?1", [target_id]},
        else: {"", []}

    sql = """
    SELECT lifecycle.admitted_run_id
    FROM run_lifecycles AS lifecycle
    JOIN run_admissions AS admission
      ON admission.admitted_run_id = lifecycle.admitted_run_id
    WHERE lifecycle.state IN (#{states})#{target_filter}
    ORDER BY
      lifecycle.admitted_at ASC,
      admission.target_id ASC,
      admission.tracker_issue_id ASC,
      lifecycle.admitted_run_id ASC
    """

    case domain_query(
           connection,
           sql,
           params,
           database_path,
           "cannot list recoverable runs"
         ) do
      {:ok, rows} ->
        decode_recoverable_run_ids(rows, database_path)

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_recoverable_run_ids(rows, database_path) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [admitted_run_id], {:ok, admitted_run_ids}
      when is_binary(admitted_run_id) and admitted_run_id != "" ->
        {:cont, {:ok, [admitted_run_id | admitted_run_ids]}}

      _invalid, _acc ->
        {:halt, corrupt_store(database_path, :invalid_recoverable_run)}
    end)
    |> case do
      {:ok, admitted_run_ids} -> {:ok, Enum.reverse(admitted_run_ids)}
      {:error, _reason} = error -> error
    end
  end

  defp fence_run_for_recovery(
         connection,
         database_path,
         admitted_run_id,
         owner_id,
         clock
       ) do
    with :ok <- validate_admitted_run_id(admitted_run_id),
         :ok <- validate_owner_id(owner_id) do
      lease_transaction(connection, database_path, clock, fn now_ms ->
        fence_current_run_for_recovery(
          connection,
          database_path,
          admitted_run_id,
          owner_id,
          now_ms
        )
      end)
    else
      _invalid -> {:error, :invalid_recovery}
    end
  end

  defp fence_current_run_for_recovery(
         connection,
         database_path,
         admitted_run_id,
         owner_id,
         now_ms
       ) do
    with {:ok, {lifecycle, _cleanup_authority}} <-
           select_lifecycle_by_run_id(connection, database_path, admitted_run_id),
         true <- lifecycle.state in @recoverable_lifecycle_states,
         {:ok, admission} <-
           load_admission(
             connection,
             database_path,
             lifecycle.target_id,
             lifecycle.tracker_issue_id
           ),
         {:ok, lease_row} <- select_lease_record(connection, database_path, admitted_run_id),
         {:ok, previous_process_ownership} <-
           select_lifecycle_process_ownership(connection, database_path, lifecycle),
         {:ok, lease} <-
           fence_recovery_lease(
             connection,
             database_path,
             admission,
             owner_id,
             lease_row,
             now_ms
           ) do
      {:ok,
       %{
         admission: admission,
         lifecycle: lifecycle,
         lease: lease,
         previous_process_ownership: previous_process_ownership,
         recovered_at_ms: now_ms
       }}
    else
      false -> {:error, :recovery_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp fence_recovery_lease(
         connection,
         database_path,
         admission,
         owner_id,
         [
           _target_id,
           _tracker_issue_id,
           nil,
           nil,
           nil,
           nil,
           nil,
           nil
         ],
         now_ms
       ) do
    with :ok <-
           insert_lease_record(
             connection,
             database_path,
             admission.admitted_run_id,
             owner_id,
             now_ms
           ) do
      {:ok,
       build_lease(
         admission.admitted_run_id,
         admission.target_id,
         admission.tracker_issue_id,
         owner_id,
         1,
         lease_deadline(now_ms)
       )}
    end
  end

  defp fence_recovery_lease(
         connection,
         database_path,
         admission,
         owner_id,
         [
           target_id,
           tracker_issue_id,
           _current_owner_id,
           fencing_token,
           _deadline_ms,
           _acquired_at_ms,
           _renewed_at_ms,
           last_observed_at_ms
         ],
         now_ms
       )
       when target_id == admission.target_id and
              tracker_issue_id == admission.tracker_issue_id and
              is_integer(fencing_token) and fencing_token > 0 and
              is_integer(last_observed_at_ms) do
    with :ok <- validate_clock_progress(now_ms, last_observed_at_ms, database_path),
         next_token = fencing_token + 1,
         next_deadline_ms = lease_deadline(now_ms),
         :ok <-
           activate_lease_record(
             connection,
             database_path,
             admission.admitted_run_id,
             fencing_token,
             owner_id,
             next_token,
             next_deadline_ms,
             now_ms
           ) do
      {:ok,
       build_lease(
         admission.admitted_run_id,
         admission.target_id,
         admission.tracker_issue_id,
         owner_id,
         next_token,
         next_deadline_ms
       )}
    end
  end

  defp fence_recovery_lease(
         _connection,
         database_path,
         _admission,
         _owner_id,
         _lease_row,
         _now_ms
       ),
       do: corrupt_store(database_path, :invalid_recovery_lease)

  defp acquire_run_lease(
         connection,
         database_path,
         admitted_run_id,
         owner_id,
         clock
       ) do
    with :ok <- validate_admitted_run_id(admitted_run_id),
         :ok <- validate_owner_id(owner_id) do
      lease_transaction(connection, database_path, clock, fn now_ms ->
        acquire_current_lease(
          connection,
          database_path,
          admitted_run_id,
          owner_id,
          now_ms
        )
      end)
    end
  end

  defp acquire_selected_lease(
         _connection,
         _database_path,
         _admitted_run_id,
         _owner_id,
         _now_ms,
         nil
       ),
       do: {:error, :admission_not_found}

  defp acquire_selected_lease(
         connection,
         database_path,
         admitted_run_id,
         owner_id,
         now_ms,
         [target_id, tracker_issue_id, nil, nil, nil, nil, nil, nil]
       ) do
    with :ok <-
           insert_lease_record(
             connection,
             database_path,
             admitted_run_id,
             owner_id,
             now_ms
           ) do
      {:ok,
       build_lease(
         admitted_run_id,
         target_id,
         tracker_issue_id,
         owner_id,
         1,
         lease_deadline(now_ms)
       )}
    end
  end

  defp acquire_selected_lease(
         connection,
         database_path,
         admitted_run_id,
         owner_id,
         now_ms,
         [
           target_id,
           tracker_issue_id,
           current_owner_id,
           fencing_token,
           deadline_ms,
           _acquired_at_ms,
           _renewed_at_ms,
           last_observed_at_ms
         ]
       )
       when is_integer(fencing_token) and fencing_token > 0 and
              is_integer(last_observed_at_ms) do
    with :ok <- validate_clock_progress(now_ms, last_observed_at_ms, database_path),
         :ok <- lease_available(current_owner_id, deadline_ms, now_ms),
         :ok <-
           ensure_process_group_stopped(
             connection,
             database_path,
             admitted_run_id,
             fencing_token
           ),
         next_token = fencing_token + 1,
         next_deadline_ms = lease_deadline(now_ms),
         :ok <-
           activate_lease_record(
             connection,
             database_path,
             admitted_run_id,
             fencing_token,
             owner_id,
             next_token,
             next_deadline_ms,
             now_ms
           ) do
      {:ok,
       build_lease(
         admitted_run_id,
         target_id,
         tracker_issue_id,
         owner_id,
         next_token,
         next_deadline_ms
       )}
    end
  end

  defp acquire_selected_lease(
         _connection,
         database_path,
         _admitted_run_id,
         _owner_id,
         _now_ms,
         _row
       ),
       do: corrupt_store(database_path, :invalid_run_lease)

  defp renew_run_lease(connection, database_path, lease, clock) do
    with :ok <- validate_lease(lease) do
      lease_transaction(connection, database_path, clock, fn now_ms ->
        renew_current_lease(connection, database_path, lease, now_ms)
      end)
    end
  end

  defp transfer_run_lease(
         connection,
         database_path,
         lease,
         new_owner_id,
         clock
       ) do
    with :ok <- validate_lease(lease),
         :ok <- validate_owner_id(new_owner_id),
         :ok <- validate_new_owner(lease.owner_id, new_owner_id) do
      lease_transaction(connection, database_path, clock, fn now_ms ->
        transfer_current_lease(
          connection,
          database_path,
          lease,
          new_owner_id,
          now_ms
        )
      end)
    end
  end

  defp release_run_lease(connection, database_path, lease, clock) do
    with :ok <- validate_lease(lease) do
      lease_transaction(connection, database_path, clock, fn now_ms ->
        release_current_lease(connection, database_path, lease, now_ms)
      end)
      |> release_result()
    end
  end

  defp expire_run_lease(
         connection,
         database_path,
         admitted_run_id,
         clock
       ) do
    with :ok <- validate_admitted_run_id(admitted_run_id) do
      lease_transaction(connection, database_path, clock, fn now_ms ->
        expire_current_lease(
          connection,
          database_path,
          admitted_run_id,
          now_ms
        )
      end)
    end
  end

  defp acquire_current_lease(
         connection,
         database_path,
         admitted_run_id,
         owner_id,
         now_ms
       ) do
    with {:ok, row} <-
           select_lease_record(connection, database_path, admitted_run_id) do
      acquire_selected_lease(
        connection,
        database_path,
        admitted_run_id,
        owner_id,
        now_ms,
        row
      )
    end
  end

  defp renew_current_lease(connection, database_path, lease, now_ms) do
    with {:ok, row} <-
           select_lease_record(
             connection,
             database_path,
             lease.admitted_run_id
           ),
         {:ok, current_deadline_ms} <-
           authorize_lease(row, lease, now_ms, database_path),
         next_deadline_ms = max(current_deadline_ms, lease_deadline(now_ms)),
         :ok <-
           renew_lease_record(
             connection,
             database_path,
             lease,
             next_deadline_ms,
             now_ms
           ) do
      {:ok, %{lease | deadline_ms: next_deadline_ms}}
    end
  end

  defp transfer_current_lease(
         connection,
         database_path,
         lease,
         new_owner_id,
         now_ms
       ) do
    with {:ok, row} <-
           select_lease_record(
             connection,
             database_path,
             lease.admitted_run_id
           ),
         {:ok, current_deadline_ms} <-
           authorize_lease(row, lease, now_ms, database_path),
         :ok <-
           ensure_process_group_stopped(
             connection,
             database_path,
             lease.admitted_run_id,
             lease.fencing_token
           ),
         next_token = lease.fencing_token + 1,
         next_deadline_ms = max(current_deadline_ms, lease_deadline(now_ms)),
         :ok <-
           transfer_lease_record(
             connection,
             database_path,
             lease,
             new_owner_id,
             next_token,
             next_deadline_ms,
             now_ms
           ) do
      {:ok,
       %{
         lease
         | owner_id: new_owner_id,
           fencing_token: next_token,
           deadline_ms: next_deadline_ms
       }}
    end
  end

  defp release_current_lease(connection, database_path, lease, now_ms) do
    with {:ok, row} <-
           select_lease_record(
             connection,
             database_path,
             lease.admitted_run_id
           ),
         {:ok, _current_deadline_ms} <-
           authorize_lease(row, lease, now_ms, database_path),
         :ok <-
           ensure_process_group_stopped(
             connection,
             database_path,
             lease.admitted_run_id,
             lease.fencing_token
           ),
         :ok <-
           ensure_token_reservation_release_safe(
             connection,
             database_path,
             lease.admitted_run_id,
             lease.fencing_token
           ),
         {:ok, _budget} <-
           release_current_token_reservation(
             connection,
             database_path,
             lease.admitted_run_id,
             now_ms,
             :released
           ),
         :ok <-
           clear_lease_record(
             connection,
             database_path,
             lease.admitted_run_id,
             lease.fencing_token,
             now_ms
           ) do
      {:ok, :released}
    end
  end

  defp expire_current_lease(
         connection,
         database_path,
         admitted_run_id,
         now_ms
       ) do
    with {:ok, row} <-
           select_lease_record(connection, database_path, admitted_run_id) do
      expire_selected_lease(
        connection,
        database_path,
        admitted_run_id,
        now_ms,
        row
      )
    end
  end

  defp expire_selected_lease(
         _connection,
         _database_path,
         _admitted_run_id,
         _now_ms,
         nil
       ),
       do: {:error, :admission_not_found}

  defp expire_selected_lease(
         _connection,
         _database_path,
         _admitted_run_id,
         _now_ms,
         [_target_id, _tracker_issue_id, nil, nil, nil, nil, nil, nil]
       ),
       do: {:error, :lease_not_found}

  defp expire_selected_lease(
         _connection,
         _database_path,
         _admitted_run_id,
         _now_ms,
         [
           _target_id,
           _tracker_issue_id,
           nil,
           fencing_token,
           nil,
           _acquired_at_ms,
           _renewed_at_ms,
           _last_observed_at_ms
         ]
       )
       when is_integer(fencing_token) and fencing_token > 0,
       do: {:error, :lease_not_found}

  defp expire_selected_lease(
         connection,
         database_path,
         admitted_run_id,
         now_ms,
         [
           _target_id,
           _tracker_issue_id,
           owner_id,
           fencing_token,
           deadline_ms,
           _acquired_at_ms,
           _renewed_at_ms,
           last_observed_at_ms
         ]
       )
       when is_binary(owner_id) and owner_id != "" and
              is_integer(fencing_token) and fencing_token > 0 and
              is_integer(deadline_ms) and is_integer(last_observed_at_ms) do
    with :ok <- validate_clock_progress(now_ms, last_observed_at_ms, database_path),
         :ok <- require_expired(deadline_ms, now_ms),
         :ok <-
           clear_lease_record(
             connection,
             database_path,
             admitted_run_id,
             fencing_token,
             now_ms
           ) do
      {:ok, :expired}
    end
  end

  defp expire_selected_lease(
         _connection,
         database_path,
         _admitted_run_id,
         _now_ms,
         _row
       ),
       do: corrupt_store(database_path, :invalid_run_lease)

  defp select_lease_record(connection, database_path, admitted_run_id) do
    sql = """
    SELECT
      admission.target_id,
      admission.tracker_issue_id,
      lease.owner_id,
      lease.fencing_token,
      lease.lease_deadline_ms,
      lease.acquired_at_ms,
      lease.renewed_at_ms,
      lease.last_observed_at_ms
    FROM run_admissions AS admission
    LEFT JOIN run_leases AS lease
      ON lease.admitted_run_id = admission.admitted_run_id
    WHERE admission.admitted_run_id = ?1
    """

    case domain_query(
           connection,
           sql,
           [admitted_run_id],
           database_path,
           "cannot read run lease"
         ) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row]} -> {:ok, row}
      {:ok, _invalid_rows} -> corrupt_store(database_path, :duplicate_run_lease)
      {:error, _reason} = error -> error
    end
  end

  defp insert_lease_record(
         connection,
         database_path,
         admitted_run_id,
         owner_id,
         now_ms
       ) do
    sql = """
    INSERT INTO run_leases (
      admitted_run_id,
      owner_id,
      fencing_token,
      lease_deadline_ms,
      acquired_at_ms,
      renewed_at_ms,
      last_observed_at_ms
    ) VALUES (?1, ?2, 1, ?3, ?4, ?4, ?4)
    """

    expect_no_rows(
      connection,
      sql,
      [admitted_run_id, owner_id, lease_deadline(now_ms), now_ms],
      database_path,
      "cannot acquire run lease"
    )
  end

  defp activate_lease_record(
         connection,
         database_path,
         admitted_run_id,
         current_token,
         owner_id,
         next_token,
         next_deadline_ms,
         now_ms
       ) do
    sql = """
    UPDATE run_leases
    SET owner_id = ?1,
        fencing_token = ?2,
        lease_deadline_ms = ?3,
        acquired_at_ms = ?4,
        renewed_at_ms = ?4,
        last_observed_at_ms = max(last_observed_at_ms, ?4)
    WHERE admitted_run_id = ?5 AND fencing_token = ?6
    """

    expect_no_rows(
      connection,
      sql,
      [
        owner_id,
        next_token,
        next_deadline_ms,
        now_ms,
        admitted_run_id,
        current_token
      ],
      database_path,
      "cannot acquire run lease"
    )
  end

  defp renew_lease_record(
         connection,
         database_path,
         lease,
         next_deadline_ms,
         now_ms
       ) do
    sql = """
    UPDATE run_leases
    SET lease_deadline_ms = ?1,
        renewed_at_ms = ?2,
        last_observed_at_ms = max(last_observed_at_ms, ?2)
    WHERE admitted_run_id = ?3
      AND owner_id = ?4
      AND fencing_token = ?5
    """

    expect_no_rows(
      connection,
      sql,
      [
        next_deadline_ms,
        now_ms,
        lease.admitted_run_id,
        lease.owner_id,
        lease.fencing_token
      ],
      database_path,
      "cannot renew run lease"
    )
  end

  defp transfer_lease_record(
         connection,
         database_path,
         lease,
         new_owner_id,
         next_token,
         next_deadline_ms,
         now_ms
       ) do
    sql = """
    UPDATE run_leases
    SET owner_id = ?1,
        fencing_token = ?2,
        lease_deadline_ms = ?3,
        acquired_at_ms = ?4,
        renewed_at_ms = ?4,
        last_observed_at_ms = max(last_observed_at_ms, ?4)
    WHERE admitted_run_id = ?5
      AND owner_id = ?6
      AND fencing_token = ?7
    """

    expect_no_rows(
      connection,
      sql,
      [
        new_owner_id,
        next_token,
        next_deadline_ms,
        now_ms,
        lease.admitted_run_id,
        lease.owner_id,
        lease.fencing_token
      ],
      database_path,
      "cannot transfer run lease"
    )
  end

  defp clear_lease_record(
         connection,
         database_path,
         admitted_run_id,
         fencing_token,
         now_ms
       ) do
    sql = """
    UPDATE run_leases
    SET owner_id = NULL,
        lease_deadline_ms = NULL,
        renewed_at_ms = ?1,
        last_observed_at_ms = max(last_observed_at_ms, ?1)
    WHERE admitted_run_id = ?2 AND fencing_token = ?3
    """

    expect_no_rows(
      connection,
      sql,
      [now_ms, admitted_run_id, fencing_token],
      database_path,
      "cannot clear run lease"
    )
  end

  defp authorize_lease(nil, _lease, _now_ms, _database_path),
    do: {:error, :admission_not_found}

  defp authorize_lease(
         [
           target_id,
           tracker_issue_id,
           owner_id,
           fencing_token,
           deadline_ms,
           _acquired_at_ms,
           _renewed_at_ms,
           last_observed_at_ms
         ],
         lease,
         now_ms,
         database_path
       )
       when is_binary(owner_id) and owner_id != "" and
              is_integer(fencing_token) and fencing_token > 0 and
              is_integer(deadline_ms) and is_integer(last_observed_at_ms) do
    with :ok <- validate_clock_progress(now_ms, last_observed_at_ms, database_path),
         true <-
           target_id == lease.target_id and
             tracker_issue_id == lease.tracker_issue_id and
             owner_id == lease.owner_id and
             fencing_token == lease.fencing_token,
         true <- now_ms < deadline_ms do
      {:ok, deadline_ms}
    else
      false -> {:error, :stale_lease}
      {:error, %Error{} = clock_error} -> {:error, clock_error}
    end
  end

  defp authorize_lease(
         [
           _target_id,
           _tracker_issue_id,
           nil,
           fencing_token,
           nil,
           _acquired_at_ms,
           _renewed_at_ms,
           _last_observed_at_ms
         ],
         _lease,
         _now_ms,
         _database_path
       )
       when is_integer(fencing_token) and fencing_token > 0,
       do: {:error, :stale_lease}

  defp authorize_lease(_row, _lease, _now_ms, database_path),
    do: corrupt_store(database_path, :invalid_run_lease)

  defp lease_transaction(connection, database_path, clock, operation) do
    with :ok <-
           execute(
             connection,
             "BEGIN IMMEDIATE",
             database_path,
             :transaction_failed
           ) do
      result =
        with {:ok, now_ms} <- wall_clock_ms(clock, database_path) do
          operation.(now_ms)
        end

      finish_lease_transaction(connection, database_path, result)
    end
  end

  defp finish_lease_transaction(connection, database_path, {tag, _value} = result)
       when tag in [:completed, :failed, :blocked] do
    case finish_transaction(connection, database_path, {:ok, result}) do
      {:ok, ^result} -> result
      {:error, _reason} = error -> error
    end
  end

  defp finish_lease_transaction(
         connection,
         database_path,
         {:token_budget_exhausted, budget}
       ) do
    case finish_transaction(connection, database_path, {:ok, budget}) do
      {:ok, ^budget} -> {:error, :token_budget_exhausted}
      {:error, _reason} = error -> error
    end
  end

  defp finish_lease_transaction(connection, database_path, result),
    do: finish_transaction(connection, database_path, result)

  defp lease_available(nil, nil, _now_ms), do: :ok

  defp lease_available(owner_id, deadline_ms, now_ms)
       when is_binary(owner_id) and owner_id != "" and
              is_integer(deadline_ms) do
    if now_ms >= deadline_ms, do: :ok, else: {:error, :lease_held}
  end

  defp lease_available(_owner_id, _deadline_ms, _now_ms),
    do: {:error, :invalid_lease}

  defp require_expired(deadline_ms, now_ms) do
    if now_ms >= deadline_ms, do: :ok, else: {:error, :lease_active}
  end

  defp validate_clock_progress(now_ms, last_observed_at_ms, database_path) do
    if now_ms + @maximum_clock_skew_ms >= last_observed_at_ms do
      :ok
    else
      {:error,
       error(
         :clock_failed,
         database_path,
         "control-plane wall clock moved backward beyond the allowed skew",
         %{
           maximum_clock_skew_ms: @maximum_clock_skew_ms,
           last_observed_at_ms: last_observed_at_ms,
           now_ms: now_ms
         }
       )}
    end
  end

  defp validate_admitted_run_id(value)
       when is_binary(value) and value != "" do
    if String.valid?(value), do: :ok, else: {:error, :invalid_lease}
  end

  defp validate_admitted_run_id(_value), do: {:error, :invalid_lease}

  defp validate_owner_id(value) when is_binary(value) and value != "" do
    if String.valid?(value), do: :ok, else: {:error, :invalid_lease}
  end

  defp validate_owner_id(_value), do: {:error, :invalid_lease}

  defp validate_new_owner(owner_id, owner_id), do: {:error, :invalid_lease}
  defp validate_new_owner(_owner_id, _new_owner_id), do: :ok

  defp validate_lease(%Lease{
         admitted_run_id: admitted_run_id,
         target_id: target_id,
         tracker_issue_id: tracker_issue_id,
         owner_id: owner_id,
         fencing_token: fencing_token,
         deadline_ms: deadline_ms
       })
       when is_binary(target_id) and target_id != "" and
              is_binary(tracker_issue_id) and tracker_issue_id != "" and
              is_integer(fencing_token) and fencing_token > 0 and
              is_integer(deadline_ms) do
    case validate_admitted_run_id(admitted_run_id) do
      :ok -> validate_owner_id(owner_id)
      {:error, _reason} = error -> error
    end
  end

  defp validate_lease(_lease), do: {:error, :invalid_lease}

  defp lease_deadline(now_ms), do: now_ms + @lease_duration_ms

  defp build_lease(
         admitted_run_id,
         target_id,
         tracker_issue_id,
         owner_id,
         fencing_token,
         deadline_ms
       ) do
    %Lease{
      admitted_run_id: admitted_run_id,
      target_id: target_id,
      tracker_issue_id: tracker_issue_id,
      owner_id: owner_id,
      fencing_token: fencing_token,
      deadline_ms: deadline_ms
    }
  end

  defp release_result({:ok, :released}), do: :ok
  defp release_result({:error, _reason} = error), do: error

  defp persist_token_usage(connection, database_path, lease, cumulative_total_tokens, clock) do
    with :ok <- validate_lease(lease),
         true <- is_integer(cumulative_total_tokens) and cumulative_total_tokens >= 0 do
      lease_transaction(connection, database_path, clock, fn now_ms ->
        record_fenced_token_usage(
          connection,
          database_path,
          lease,
          cumulative_total_tokens,
          now_ms
        )
      end)
    else
      false -> {:error, :invalid_token_usage}
      {:error, _reason} = error -> error
    end
  end

  defp record_fenced_token_usage(
         connection,
         database_path,
         lease,
         cumulative_total_tokens,
         now_ms
       ) do
    with {:ok, lease_row} <-
           select_lease_record(connection, database_path, lease.admitted_run_id),
         {:ok, _deadline_ms} <-
           authorize_lease(lease_row, lease, now_ms, database_path) do
      record_current_token_usage(
        connection,
        database_path,
        lease.admitted_run_id,
        cumulative_total_tokens,
        now_ms
      )
    end
  end

  defp release_token_reservation(connection, database_path, lease, clock) do
    with :ok <- validate_lease(lease) do
      lease_transaction(connection, database_path, clock, fn now_ms ->
        release_fenced_token_reservation(connection, database_path, lease, now_ms)
      end)
    end
  end

  defp release_fenced_token_reservation(connection, database_path, lease, now_ms) do
    with {:ok, lease_row} <-
           select_lease_record(connection, database_path, lease.admitted_run_id),
         {:ok, _deadline_ms} <-
           authorize_lease(lease_row, lease, now_ms, database_path),
         :ok <-
           ensure_process_group_stopped(
             connection,
             database_path,
             lease.admitted_run_id,
             lease.fencing_token
           ),
         :ok <-
           ensure_token_reservation_release_safe(
             connection,
             database_path,
             lease.admitted_run_id,
             lease.fencing_token
           ) do
      release_current_token_reservation(
        connection,
        database_path,
        lease.admitted_run_id,
        now_ms,
        :released
      )
    end
  end

  defp acquire_token_reservation(connection, database_path, lease, clock) do
    with :ok <- validate_lease(lease) do
      lease_transaction(connection, database_path, clock, fn now_ms ->
        acquire_fenced_token_reservation(connection, database_path, lease, now_ms)
      end)
    end
  end

  defp acquire_fenced_token_reservation(connection, database_path, lease, now_ms) do
    with {:ok, lease_row} <-
           select_lease_record(connection, database_path, lease.admitted_run_id),
         {:ok, _deadline_ms} <-
           authorize_lease(lease_row, lease, now_ms, database_path) do
      acquire_current_token_reservation(
        connection,
        database_path,
        lease.admitted_run_id,
        now_ms
      )
    end
  end

  defp record_current_token_usage(
         connection,
         database_path,
         admitted_run_id,
         cumulative_total_tokens,
         now_ms
       ) do
    with {:ok, budget} <-
           select_token_budget(connection, database_path, admitted_run_id) do
      record_selected_token_usage(
        connection,
        database_path,
        budget,
        cumulative_total_tokens,
        now_ms
      )
    end
  end

  defp record_selected_token_usage(
         _connection,
         _database_path,
         :unlimited,
         _cumulative_total_tokens,
         _now_ms
       ),
       do: {:ok, :unlimited}

  defp record_selected_token_usage(
         connection,
         database_path,
         %{state: :active} = budget,
         cumulative_total_tokens,
         _now_ms
       )
       when cumulative_total_tokens <= budget.cumulative_tokens do
    token_budget_snapshot(connection, database_path, budget)
  end

  defp record_selected_token_usage(
         connection,
         database_path,
         %{state: :active} = budget,
         cumulative_total_tokens,
         now_ms
       )
       when cumulative_total_tokens > budget.per_run_limit do
    with {:ok, updated_at} <- timestamp_from_ms(now_ms, database_path),
         :ok <-
           update_token_budget(
             connection,
             database_path,
             budget.admitted_run_id,
             budget.per_run_limit,
             0,
             :active,
             updated_at
           ),
         {:ok, updated} <-
           select_token_budget(connection, database_path, budget.admitted_run_id),
         {:ok, snapshot} <- token_budget_snapshot(connection, database_path, updated) do
      {:token_budget_exhausted, snapshot}
    end
  end

  defp record_selected_token_usage(
         connection,
         database_path,
         %{state: :active} = budget,
         cumulative_total_tokens,
         now_ms
       ) do
    reserved_tokens = budget.per_run_limit - cumulative_total_tokens

    with {:ok, updated_at} <- timestamp_from_ms(now_ms, database_path),
         :ok <-
           update_token_budget(
             connection,
             database_path,
             budget.admitted_run_id,
             cumulative_total_tokens,
             reserved_tokens,
             :active,
             updated_at
           ),
         {:ok, updated} <-
           select_token_budget(connection, database_path, budget.admitted_run_id) do
      token_budget_snapshot(connection, database_path, updated)
    end
  end

  defp record_selected_token_usage(
         _connection,
         _database_path,
         %{state: state},
         _cumulative_total_tokens,
         _now_ms
       )
       when state in [:released, :terminal],
       do: {:error, :token_budget_not_reserved}

  defp acquire_current_token_reservation(connection, database_path, admitted_run_id, now_ms) do
    with {:ok, budget} <- select_token_budget(connection, database_path, admitted_run_id) do
      acquire_selected_token_reservation(connection, database_path, budget, now_ms)
    end
  end

  defp acquire_selected_token_reservation(
         _connection,
         _database_path,
         :unlimited,
         _now_ms
       ),
       do: {:ok, :unlimited}

  defp acquire_selected_token_reservation(connection, database_path, %{state: :active} = budget, _now_ms),
    do: token_budget_snapshot(connection, database_path, budget)

  defp acquire_selected_token_reservation(
         _connection,
         _database_path,
         %{state: :terminal},
         _now_ms
       ),
       do: {:error, :token_budget_not_reserved}

  defp acquire_selected_token_reservation(
         connection,
         database_path,
         %{state: :released} = budget,
         now_ms
       ) do
    remaining_tokens = budget.per_run_limit - budget.cumulative_tokens

    with true <- remaining_tokens > 0,
         {:ok, {daily_allocated, stored_daily_limit}} <-
           period_token_balance(
             connection,
             database_path,
             budget.target_id,
             :day,
             budget.admission_day
           ),
         :ok <-
           ensure_token_capacity(
             daily_allocated,
             remaining_tokens,
             effective_period_limit(budget.daily_limit, stored_daily_limit),
             :daily_token_budget_exceeded
           ),
         {:ok, {weekly_allocated, stored_weekly_limit}} <-
           period_token_balance(
             connection,
             database_path,
             budget.target_id,
             :week,
             budget.admission_week
           ),
         :ok <-
           ensure_token_capacity(
             weekly_allocated,
             remaining_tokens,
             effective_period_limit(budget.weekly_limit, stored_weekly_limit),
             :weekly_token_budget_exceeded
           ),
         {:ok, updated_at} <- timestamp_from_ms(now_ms, database_path),
         :ok <-
           update_token_budget(
             connection,
             database_path,
             budget.admitted_run_id,
             budget.cumulative_tokens,
             remaining_tokens,
             :active,
             updated_at
           ),
         {:ok, updated} <-
           select_token_budget(connection, database_path, budget.admitted_run_id) do
      token_budget_snapshot(connection, database_path, updated)
    else
      false -> {:error, :token_budget_exhausted}
      {:error, _reason} = error -> error
    end
  end

  defp release_current_token_reservation(
         connection,
         database_path,
         admitted_run_id,
         now_ms,
         next_state
       )
       when next_state in [:released, :terminal] do
    with {:ok, budget} <- select_token_budget(connection, database_path, admitted_run_id) do
      release_selected_token_reservation(
        connection,
        database_path,
        budget,
        now_ms,
        next_state
      )
    end
  end

  defp release_selected_token_reservation(
         _connection,
         _database_path,
         :unlimited,
         _now_ms,
         _next_state
       ),
       do: {:ok, :unlimited}

  defp release_selected_token_reservation(
         connection,
         database_path,
         %{state: current_state} = budget,
         _now_ms,
         next_state
       )
       when current_state == next_state or current_state == :terminal do
    token_budget_snapshot(connection, database_path, budget)
  end

  defp release_selected_token_reservation(
         connection,
         database_path,
         budget,
         now_ms,
         next_state
       ) do
    with {:ok, updated_at} <- timestamp_from_ms(now_ms, database_path),
         :ok <-
           update_token_budget(
             connection,
             database_path,
             budget.admitted_run_id,
             budget.cumulative_tokens,
             0,
             next_state,
             updated_at
           ),
         {:ok, updated} <-
           select_token_budget(connection, database_path, budget.admitted_run_id) do
      token_budget_snapshot(connection, database_path, updated)
    end
  end

  defp update_token_budget(
         connection,
         database_path,
         admitted_run_id,
         cumulative_tokens,
         reserved_tokens,
         state,
         updated_at
       ) do
    sql = """
    UPDATE run_token_budgets
    SET cumulative_tokens = ?1,
        charged_tokens = ?1,
        reserved_tokens = ?2,
        state = ?3,
        updated_at = ?4
    WHERE admitted_run_id = ?5
    """

    expect_no_rows(
      connection,
      sql,
      [
        cumulative_tokens,
        reserved_tokens,
        Atom.to_string(state),
        updated_at,
        admitted_run_id
      ],
      database_path,
      "cannot persist token budget"
    )
  end

  defp load_token_budget(connection, database_path, admitted_run_id)
       when is_binary(admitted_run_id) and admitted_run_id != "" do
    with {:ok, budget} <- select_token_budget(connection, database_path, admitted_run_id) do
      case budget do
        :unlimited -> {:error, :token_budget_not_configured}
        stored -> token_budget_snapshot(connection, database_path, stored)
      end
    end
  end

  defp load_token_budget(_connection, _database_path, _admitted_run_id),
    do: {:error, :invalid_lease}

  defp select_token_budget(connection, database_path, admitted_run_id) do
    sql = """
    SELECT
      admission.target_id,
      budget.admission_day,
      budget.admission_week,
      budget.per_run_limit,
      budget.daily_limit,
      budget.weekly_limit,
      budget.cumulative_tokens,
      budget.charged_tokens,
      budget.reserved_tokens,
      budget.state,
      budget.updated_at
    FROM run_admissions AS admission
    LEFT JOIN run_token_budgets AS budget
      ON budget.admitted_run_id = admission.admitted_run_id
    WHERE admission.admitted_run_id = ?1
    """

    case domain_query(
           connection,
           sql,
           [admitted_run_id],
           database_path,
           "cannot read run token budget"
         ) do
      {:ok, []} ->
        {:error, :admission_not_found}

      {:ok, [[_target_id, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil]]} ->
        {:ok, :unlimited}

      {:ok, [row]} ->
        decode_token_budget_row(admitted_run_id, row, database_path)

      {:ok, _invalid_rows} ->
        corrupt_store(database_path, :invalid_run_token_budget)

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_token_budget_row(
         admitted_run_id,
         [
           target_id,
           admission_day,
           admission_week,
           per_run_limit,
           daily_limit,
           weekly_limit,
           cumulative_tokens,
           charged_tokens,
           reserved_tokens,
           state,
           updated_at
         ],
         database_path
       ) do
    with {:ok, decoded_state} <- decode_token_budget_state(state),
         true <-
           Enum.all?(
             [admitted_run_id, target_id, admission_day, admission_week, updated_at],
             &valid_non_empty_string?/1
           ),
         true <-
           Enum.all?(
             [
               per_run_limit,
               daily_limit,
               weekly_limit,
               cumulative_tokens,
               charged_tokens,
               reserved_tokens
             ],
             &is_integer/1
           ) do
      {:ok,
       %{
         admitted_run_id: admitted_run_id,
         target_id: target_id,
         admission_day: admission_day,
         admission_week: admission_week,
         per_run_limit: per_run_limit,
         daily_limit: daily_limit,
         weekly_limit: weekly_limit,
         cumulative_tokens: cumulative_tokens,
         charged_tokens: charged_tokens,
         reserved_tokens: reserved_tokens,
         state: decoded_state,
         updated_at: updated_at
       }}
    else
      _invalid -> corrupt_store(database_path, :invalid_run_token_budget)
    end
  end

  defp decode_token_budget_state("active"), do: {:ok, :active}
  defp decode_token_budget_state("released"), do: {:ok, :released}
  defp decode_token_budget_state("terminal"), do: {:ok, :terminal}
  defp decode_token_budget_state(_state), do: {:error, :invalid_token_budget_state}

  defp token_budget_snapshot(connection, database_path, budget) do
    with {:ok, {daily_allocated, stored_daily_limit}} <-
           period_token_balance(
             connection,
             database_path,
             budget.target_id,
             :day,
             budget.admission_day
           ),
         {:ok, {weekly_allocated, stored_weekly_limit}} <-
           period_token_balance(
             connection,
             database_path,
             budget.target_id,
             :week,
             budget.admission_week
           ) do
      daily_limit = effective_period_limit(budget.daily_limit, stored_daily_limit)
      weekly_limit = effective_period_limit(budget.weekly_limit, stored_weekly_limit)

      {:ok,
       struct!(
         TokenBudget,
         Map.merge(budget, %{
           daily_available_tokens: max(daily_limit - daily_allocated, 0),
           weekly_available_tokens: max(weekly_limit - weekly_allocated, 0)
         })
       )}
    end
  end

  defp period_token_balance(connection, database_path, target_id, period, value)
       when period in [:day, :week] do
    {period_column, limit_column} =
      if period == :day,
        do: {"admission_day", "daily_limit"},
        else: {"admission_week", "weekly_limit"}

    sql = """
    SELECT
      coalesce(sum(charged_tokens + reserved_tokens), 0),
      min(#{limit_column})
    FROM run_token_budgets
    WHERE target_id = ?1 AND #{period_column} = ?2
    """

    case domain_query(
           connection,
           sql,
           [target_id, value],
           database_path,
           "cannot read token budget balance"
         ) do
      {:ok, [[allocated, nil]]} when allocated == 0 ->
        {:ok, {0, nil}}

      {:ok, [[allocated, limit]]}
      when is_integer(allocated) and allocated >= 0 and is_integer(limit) and limit > 0 ->
        {:ok, {allocated, limit}}

      {:ok, rows} ->
        corrupt_store(database_path, {:invalid_token_budget_balance, rows})

      {:error, _reason} = error ->
        error
    end
  end

  defp effective_period_limit(configured_limit, nil), do: configured_limit
  defp effective_period_limit(configured_limit, stored_limit), do: min(configured_limit, stored_limit)

  defp ensure_token_capacity(allocated, requested, limit, _error)
       when allocated + requested <= limit,
       do: :ok

  defp ensure_token_capacity(_allocated, _requested, _limit, error), do: {:error, error}

  defp load_lifecycle(connection, database_path, admitted_run_id)
       when is_binary(admitted_run_id) and admitted_run_id != "" do
    with {:ok, {lifecycle, _cleanup_authority}} <-
           select_lifecycle_by_run_id(connection, database_path, admitted_run_id) do
      {:ok, lifecycle}
    end
  end

  defp load_lifecycle(_connection, _database_path, _admitted_run_id),
    do: {:error, :invalid_transition}

  defp load_target_lifecycle(connection, database_path, target_id, tracker_issue_id)
       when is_binary(target_id) and target_id != "" and
              is_binary(tracker_issue_id) and tracker_issue_id != "" do
    with {:ok, {lifecycle, _cleanup_authority}} <-
           select_target_lifecycle(
             connection,
             database_path,
             target_id,
             tracker_issue_id
           ) do
      {:ok, lifecycle}
    end
  end

  defp load_target_lifecycle(_connection, _database_path, _target_id, _tracker_issue_id),
    do: {:error, :invalid_transition}

  defp persist_lifecycle_transition(
         connection,
         database_path,
         lease,
         expected_sequence,
         expected_state,
         next_state,
         evidence,
         clock
       ) do
    with :ok <- validate_lease(lease),
         :ok <-
           validate_lifecycle_transition(
             expected_sequence,
             expected_state,
             next_state,
             evidence
           ) do
      request = %{
        lease: lease,
        expected_sequence: expected_sequence,
        expected_state: expected_state,
        next_state: next_state,
        evidence: evidence
      }

      lease_transaction(connection, database_path, clock, fn now_ms ->
        transition_current_lifecycle(connection, database_path, request, now_ms)
      end)
    end
  end

  defp transition_current_lifecycle(connection, database_path, request, now_ms) do
    with {:ok, lifecycle_record} <-
           select_lifecycle_by_run_id(
             connection,
             database_path,
             request.lease.admitted_run_id
           ) do
      transition_lifecycle(
        connection,
        database_path,
        lifecycle_record,
        request,
        now_ms
      )
    end
  end

  defp validate_lifecycle_transition(expected_sequence, expected_state, next_state, evidence)
       when is_integer(expected_sequence) and expected_sequence > 0 and
              expected_state in @lifecycle_states and
              next_state in @lifecycle_states and
              is_map(evidence),
       do: :ok

  defp validate_lifecycle_transition(
         _expected_sequence,
         _expected_state,
         _next_state,
         _evidence
       ),
       do: {:error, :invalid_transition}

  defp transition_lifecycle(
         connection,
         database_path,
         {lifecycle, cleanup_authority},
         request,
         now_ms
       ) do
    cond do
      lifecycle.sequence > request.expected_sequence ->
        replay_lifecycle_transition(
          connection,
          database_path,
          lifecycle,
          cleanup_authority,
          request
        )

      lifecycle.sequence < request.expected_sequence ->
        {:error, :out_of_order_transition}

      lifecycle.state != request.expected_state ->
        {:error, :out_of_order_transition}

      lifecycle.state == request.next_state ->
        {:error, :duplicate_transition}

      request.next_state not in Map.fetch!(@legal_lifecycle_transitions, lifecycle.state) ->
        {:error, :illegal_transition}

      true ->
        apply_lifecycle_transition(
          connection,
          database_path,
          {lifecycle, cleanup_authority},
          request,
          now_ms
        )
    end
  end

  defp replay_lifecycle_transition(
         connection,
         database_path,
         lifecycle,
         cleanup_authority,
         request
       ) do
    with {:ok, normalized_evidence} <-
           normalize_transition_evidence(
             request.next_state,
             request.evidence,
             cleanup_authority
           ),
         {:ok, transition} <-
           select_lifecycle_transition(
             connection,
             database_path,
             lifecycle.admitted_run_id,
             request.expected_sequence + 1
           ) do
      classify_replayed_transition(
        lifecycle,
        transition,
        request,
        normalized_evidence
      )
    end
  end

  defp classify_replayed_transition(lifecycle, transition, request, normalized_evidence) do
    cond do
      transition.from_state != request.expected_state or
          transition.to_state != request.next_state ->
        {:error, :out_of_order_transition}

      transition.owner_id != request.lease.owner_id or
          transition.fencing_token != request.lease.fencing_token ->
        {:error, :stale_lease}

      transition.evidence !== normalized_evidence ->
        {:error, :duplicate_transition}

      request.next_state in @idempotent_lifecycle_states ->
        {:ok, lifecycle}

      true ->
        {:error, :duplicate_transition}
    end
  end

  defp apply_lifecycle_transition(
         connection,
         database_path,
         {lifecycle, cleanup_authority},
         request,
         now_ms
       ) do
    with {:ok, lease_row} <-
           select_lease_record(
             connection,
             database_path,
             request.lease.admitted_run_id
           ),
         {:ok, _deadline_ms} <-
           authorize_lease(lease_row, request.lease, now_ms, database_path),
         {:ok, normalized_evidence} <-
           normalize_transition_evidence(
             request.next_state,
             request.evidence,
             cleanup_authority
           ),
         {:ok, _budget} <-
           prepare_token_budget_transition(
             connection,
             database_path,
             lifecycle.admitted_run_id,
             request.next_state,
             now_ms
           ),
         {:ok, occurred_at} <- timestamp_from_ms(now_ms, database_path),
         next_lifecycle =
           next_lifecycle(
             lifecycle,
             request.next_state,
             normalized_evidence,
             occurred_at
           ),
         :ok <-
           update_lifecycle_record(
             connection,
             database_path,
             lifecycle,
             next_lifecycle
           ),
         :ok <-
           insert_lifecycle_transition(
             connection,
             database_path,
             lifecycle,
             next_lifecycle,
             request.lease,
             normalized_evidence,
             occurred_at
           ),
         {:ok, {stored, _cleanup_authority}} <-
           select_lifecycle_by_run_id(
             connection,
             database_path,
             lifecycle.admitted_run_id
           ) do
      {:ok, stored}
    end
  end

  defp prepare_token_budget_transition(
         connection,
         database_path,
         admitted_run_id,
         :running,
         now_ms
       ),
       do:
         acquire_current_token_reservation(
           connection,
           database_path,
           admitted_run_id,
           now_ms
         )

  defp prepare_token_budget_transition(
         connection,
         database_path,
         admitted_run_id,
         :completed,
         now_ms
       ),
       do:
         release_current_token_reservation(
           connection,
           database_path,
           admitted_run_id,
           now_ms,
           :terminal
         )

  defp prepare_token_budget_transition(
         _connection,
         _database_path,
         _admitted_run_id,
         _next_state,
         _now_ms
       ),
       do: {:ok, :unchanged}

  defp normalize_transition_evidence(:running, evidence, _cleanup_authority) do
    cond do
      map_size(evidence) == 0 ->
        {:ok, %{}}

      evidence_keys?(evidence, [:landing_queue]) ->
        with {:ok, landing_queue} <- fetch_evidence(evidence, :landing_queue),
             true <- is_map(landing_queue) and map_size(landing_queue) > 0,
             :ok <- validate_json_keys(landing_queue),
             {:ok, json} <- encode_json(landing_queue),
             {:ok, normalized} <- decode_json_map(json) do
          {:ok, %{"landing_queue" => normalized}}
        else
          _invalid -> {:error, :invalid_transition}
        end

      true ->
        {:error, :invalid_transition}
    end
  end

  defp normalize_transition_evidence(:retrying, evidence, _cleanup_authority) do
    with true <- evidence_keys?(evidence, [:attempt, :due_at_ms, :failure]),
         {:ok, attempt} <- fetch_evidence(evidence, :attempt),
         true <- is_integer(attempt) and attempt > 0,
         {:ok, due_at_ms} <- fetch_evidence(evidence, :due_at_ms),
         true <- is_integer(due_at_ms) and due_at_ms >= 0,
         {:ok, failure} <- fetch_evidence(evidence, :failure),
         {:ok, normalized_failure} <- normalize_failure(failure) do
      {:ok,
       %{
         "attempt" => attempt,
         "due_at_ms" => due_at_ms,
         "failure" => normalized_failure
       }}
    else
      _invalid -> {:error, :invalid_transition}
    end
  end

  defp normalize_transition_evidence(:blocked, evidence, _cleanup_authority) do
    with true <- evidence_keys?(evidence, [:reason]),
         {:ok, reason} <- fetch_evidence(evidence, :reason),
         true <- valid_non_empty_string?(reason) do
      {:ok, %{"reason" => reason}}
    else
      _invalid -> {:error, :invalid_transition}
    end
  end

  defp normalize_transition_evidence(:completed, evidence, _cleanup_authority) do
    with true <- evidence_keys?(evidence, [:disposition]),
         {:ok, disposition} <- fetch_evidence(evidence, :disposition),
         {:ok, normalized_disposition} <- normalize_disposition(disposition) do
      {:ok, %{"disposition" => normalized_disposition}}
    else
      _invalid -> {:error, :invalid_transition}
    end
  end

  defp normalize_transition_evidence(:cleanup_pending, evidence, cleanup_authority) do
    if map_size(evidence) == 0 and is_map(cleanup_authority) do
      {:ok, %{"cleanup_authority" => cleanup_authority}}
    else
      {:error, :invalid_transition}
    end
  end

  defp normalize_transition_evidence(:cleaned, evidence, _cleanup_authority) do
    if map_size(evidence) == 0, do: {:ok, %{}}, else: {:error, :invalid_transition}
  end

  defp normalize_transition_evidence(_state, _evidence, _cleanup_authority),
    do: {:error, :invalid_transition}

  defp evidence_keys?(evidence, expected_keys) do
    actual_keys =
      Enum.map(Map.keys(evidence), fn
        key when is_atom(key) -> key
        key when is_binary(key) -> Enum.find(expected_keys, &(Atom.to_string(&1) == key))
        _key -> nil
      end)

    MapSet.new(actual_keys) == MapSet.new(expected_keys) and
      length(actual_keys) == length(expected_keys)
  end

  defp fetch_evidence(evidence, key) do
    case {Map.fetch(evidence, key), Map.fetch(evidence, Atom.to_string(key))} do
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      _missing_or_duplicate -> :error
    end
  end

  defp normalize_failure(failure) when is_map(failure) do
    with :ok <- validate_json_keys(failure),
         {:ok, json} <- encode_json(failure),
         {:ok, normalized} <- decode_json_map(json),
         true <- valid_non_empty_string?(Map.get(normalized, "code")),
         true <- valid_non_empty_string?(Map.get(normalized, "message")) do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_transition}
    end
  end

  defp normalize_failure(_failure), do: {:error, :invalid_transition}

  defp validate_json_keys(map) when is_map(map) do
    normalized_keys =
      Enum.map(Map.keys(map), fn
        key when is_atom(key) -> Atom.to_string(key)
        key when is_binary(key) -> key
        _key -> nil
      end)

    valid_keys? =
      Enum.all?(normalized_keys, &is_binary/1) and
        MapSet.size(MapSet.new(normalized_keys)) == map_size(map)

    valid_values? =
      Enum.all?(Map.values(map), &(validate_json_keys(&1) == :ok))

    if valid_keys? and valid_values?, do: :ok, else: :error
  end

  defp validate_json_keys(list) when is_list(list) do
    if Enum.all?(list, &(validate_json_keys(&1) == :ok)), do: :ok, else: :error
  end

  defp validate_json_keys(_value), do: :ok

  defp normalize_disposition(disposition) when is_atom(disposition),
    do: normalize_disposition(Atom.to_string(disposition))

  defp normalize_disposition(disposition) when is_binary(disposition) do
    if valid_non_empty_string?(disposition),
      do: {:ok, disposition},
      else: {:error, :invalid_transition}
  end

  defp normalize_disposition(_disposition), do: {:error, :invalid_transition}

  defp valid_non_empty_string?(value) when is_binary(value) and value != "",
    do: String.valid?(value)

  defp valid_non_empty_string?(_value), do: false

  defp next_lifecycle(lifecycle, :running, _evidence, occurred_at) do
    %{
      lifecycle
      | state: :running,
        sequence: lifecycle.sequence + 1,
        retry_attempt: nil,
        retry_due_at_ms: nil,
        failure: nil,
        blocked_reason: nil,
        started_at: lifecycle.started_at || occurred_at,
        updated_at: occurred_at
    }
  end

  defp next_lifecycle(
         lifecycle,
         :retrying,
         %{
           "attempt" => attempt,
           "due_at_ms" => due_at_ms,
           "failure" => failure
         },
         occurred_at
       ) do
    %{
      lifecycle
      | state: :retrying,
        sequence: lifecycle.sequence + 1,
        retry_attempt: attempt,
        retry_due_at_ms: due_at_ms,
        failure: failure,
        blocked_reason: nil,
        updated_at: occurred_at
    }
  end

  defp next_lifecycle(
         lifecycle,
         :blocked,
         %{"reason" => reason},
         occurred_at
       ) do
    %{
      lifecycle
      | state: :blocked,
        sequence: lifecycle.sequence + 1,
        retry_attempt: nil,
        retry_due_at_ms: nil,
        failure: nil,
        blocked_reason: reason,
        updated_at: occurred_at
    }
  end

  defp next_lifecycle(
         lifecycle,
         :completed,
         %{"disposition" => disposition},
         occurred_at
       ) do
    %{
      lifecycle
      | state: :completed,
        sequence: lifecycle.sequence + 1,
        retry_attempt: nil,
        retry_due_at_ms: nil,
        failure: nil,
        blocked_reason: nil,
        completion_disposition: disposition,
        completed_at: lifecycle.completed_at || occurred_at,
        updated_at: occurred_at
    }
  end

  defp next_lifecycle(
         lifecycle,
         :cleanup_pending,
         %{"cleanup_authority" => cleanup_authority},
         occurred_at
       ) do
    %{
      lifecycle
      | state: :cleanup_pending,
        sequence: lifecycle.sequence + 1,
        cleanup_authority: cleanup_authority,
        cleanup_pending_at: lifecycle.cleanup_pending_at || occurred_at,
        updated_at: occurred_at
    }
  end

  defp next_lifecycle(lifecycle, :cleaned, %{}, occurred_at) do
    %{
      lifecycle
      | state: :cleaned,
        sequence: lifecycle.sequence + 1,
        cleaned_at: lifecycle.cleaned_at || occurred_at,
        updated_at: occurred_at
    }
  end

  defp update_lifecycle_record(
         connection,
         database_path,
         current,
         next
       ) do
    sql = """
    UPDATE run_lifecycles
    SET state = ?1,
        sequence = ?2,
        retry_attempt = ?3,
        retry_due_at_ms = ?4,
        failure_json = ?5,
        blocked_reason = ?6,
        completion_disposition = ?7,
        cleanup_authority_json = ?8,
        started_at = ?9,
        completed_at = ?10,
        cleanup_pending_at = ?11,
        cleaned_at = ?12,
        updated_at = ?13
    WHERE admitted_run_id = ?14
      AND state = ?15
      AND sequence = ?16
    RETURNING admitted_run_id
    """

    with {:ok, failure_json} <- encode_optional_json(next.failure),
         {:ok, cleanup_authority_json} <-
           encode_optional_json(next.cleanup_authority),
         {:ok, [[admitted_run_id]]} <-
           domain_query(
             connection,
             sql,
             [
               Atom.to_string(next.state),
               next.sequence,
               next.retry_attempt,
               next.retry_due_at_ms,
               failure_json,
               next.blocked_reason,
               next.completion_disposition,
               cleanup_authority_json,
               next.started_at,
               next.completed_at,
               next.cleanup_pending_at,
               next.cleaned_at,
               next.updated_at,
               current.admitted_run_id,
               Atom.to_string(current.state),
               current.sequence
             ],
             database_path,
             "cannot persist current run lifecycle"
           ),
         true <- admitted_run_id == current.admitted_run_id do
      :ok
    else
      {:ok, _rows} -> {:error, :out_of_order_transition}
      false -> corrupt_store(database_path, :mismatched_lifecycle_update)
      {:error, _reason} = error -> error
    end
  end

  defp insert_lifecycle_transition(
         connection,
         database_path,
         current,
         next,
         lease,
         evidence,
         occurred_at
       ) do
    sql = """
    INSERT INTO run_lifecycle_transitions (
      admitted_run_id,
      sequence,
      from_state,
      to_state,
      owner_id,
      fencing_token,
      occurred_at,
      evidence_json
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
    """

    with {:ok, evidence_json} <- encode_json(evidence) do
      expect_no_rows(
        connection,
        sql,
        [
          current.admitted_run_id,
          next.sequence,
          Atom.to_string(current.state),
          Atom.to_string(next.state),
          lease.owner_id,
          lease.fencing_token,
          occurred_at,
          evidence_json
        ],
        database_path,
        "cannot append run lifecycle transition"
      )
    end
  end

  defp select_lifecycle_by_run_id(
         connection,
         database_path,
         admitted_run_id
       ) do
    select_lifecycle(
      connection,
      database_path,
      "admission.admitted_run_id = ?1",
      [admitted_run_id]
    )
  end

  defp select_target_lifecycle(
         connection,
         database_path,
         target_id,
         tracker_issue_id
       ) do
    select_lifecycle(
      connection,
      database_path,
      "admission.target_id = ?1 AND admission.tracker_issue_id = ?2",
      [target_id, tracker_issue_id]
    )
  end

  defp select_lifecycle(connection, database_path, predicate, params) do
    sql = """
    SELECT
      admission.target_id,
      admission.tracker_issue_id,
      admission.workspace_authority_json,
      lifecycle.admitted_run_id,
      lifecycle.state,
      lifecycle.sequence,
      lifecycle.retry_attempt,
      lifecycle.retry_due_at_ms,
      lifecycle.failure_json,
      lifecycle.blocked_reason,
      lifecycle.completion_disposition,
      lifecycle.cleanup_authority_json,
      lifecycle.admitted_at,
      lifecycle.started_at,
      lifecycle.completed_at,
      lifecycle.cleanup_pending_at,
      lifecycle.cleaned_at,
      lifecycle.updated_at
    FROM run_admissions AS admission
    JOIN run_lifecycles AS lifecycle
      ON lifecycle.admitted_run_id = admission.admitted_run_id
    WHERE #{predicate}
    """

    case domain_query(
           connection,
           sql,
           params,
           database_path,
           "cannot read run lifecycle"
         ) do
      {:ok, []} -> {:error, :admission_not_found}
      {:ok, [row]} -> decode_lifecycle_row(row, database_path)
      {:ok, _rows} -> corrupt_store(database_path, :duplicate_run_lifecycle)
      {:error, _reason} = error -> error
    end
  end

  defp decode_lifecycle_row(
         [
           target_id,
           tracker_issue_id,
           workspace_authority_json,
           admitted_run_id,
           state,
           sequence,
           retry_attempt,
           retry_due_at_ms,
           failure_json,
           blocked_reason,
           completion_disposition,
           cleanup_authority_json,
           admitted_at,
           started_at,
           completed_at,
           cleanup_pending_at,
           cleaned_at,
           updated_at
         ],
         database_path
       ) do
    record = %{
      target_id: target_id,
      tracker_issue_id: tracker_issue_id,
      admitted_run_id: admitted_run_id,
      sequence: sequence,
      retry_attempt: retry_attempt,
      retry_due_at_ms: retry_due_at_ms,
      blocked_reason: blocked_reason,
      completion_disposition: completion_disposition,
      admitted_at: admitted_at,
      started_at: started_at,
      completed_at: completed_at,
      cleanup_pending_at: cleanup_pending_at,
      cleaned_at: cleaned_at,
      updated_at: updated_at
    }

    with :ok <- validate_lifecycle_record(record),
         {:ok, lifecycle_state} <- decode_lifecycle_state(state),
         {:ok, workspace_authority} <-
           decode_json_map(workspace_authority_json),
         {:ok, failure} <- decode_optional_json(failure_json),
         {:ok, cleanup_authority} <-
           decode_optional_json(cleanup_authority_json) do
      lifecycle =
        build_lifecycle(
          record,
          lifecycle_state,
          failure,
          cleanup_authority
        )

      {:ok, {lifecycle, workspace_authority}}
    else
      _invalid -> corrupt_store(database_path, :invalid_run_lifecycle)
    end
  end

  defp decode_lifecycle_row(_row, database_path),
    do: corrupt_store(database_path, :invalid_run_lifecycle)

  defp validate_lifecycle_record(record) do
    with :ok <- validate_lifecycle_identity(record),
         :ok <- validate_lifecycle_sequence(record) do
      validate_lifecycle_timestamps(record)
    end
  end

  defp validate_lifecycle_identity(%{
         target_id: target_id,
         tracker_issue_id: tracker_issue_id,
         admitted_run_id: admitted_run_id
       })
       when is_binary(target_id) and target_id != "" and
              is_binary(tracker_issue_id) and tracker_issue_id != "" and
              is_binary(admitted_run_id) and admitted_run_id != "",
       do: :ok

  defp validate_lifecycle_identity(_record), do: {:error, :invalid_run_lifecycle}

  defp validate_lifecycle_sequence(%{sequence: sequence})
       when is_integer(sequence) and sequence > 0,
       do: :ok

  defp validate_lifecycle_sequence(_record), do: {:error, :invalid_run_lifecycle}

  defp validate_lifecycle_timestamps(%{
         admitted_at: admitted_at,
         updated_at: updated_at
       })
       when is_binary(admitted_at) and is_binary(updated_at),
       do: :ok

  defp validate_lifecycle_timestamps(_record), do: {:error, :invalid_run_lifecycle}

  defp decode_json_map(json) do
    case decode_json(json) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _invalid -> {:error, :invalid_json_map}
    end
  end

  defp build_lifecycle(record, lifecycle_state, failure, cleanup_authority) do
    %Lifecycle{
      admitted_run_id: record.admitted_run_id,
      target_id: record.target_id,
      tracker_issue_id: record.tracker_issue_id,
      state: lifecycle_state,
      sequence: record.sequence,
      retry_attempt: record.retry_attempt,
      retry_due_at_ms: record.retry_due_at_ms,
      failure: failure,
      blocked_reason: record.blocked_reason,
      completion_disposition: record.completion_disposition,
      cleanup_authority: cleanup_authority,
      admitted_at: record.admitted_at,
      started_at: record.started_at,
      completed_at: record.completed_at,
      cleanup_pending_at: record.cleanup_pending_at,
      cleaned_at: record.cleaned_at,
      updated_at: record.updated_at
    }
  end

  defp select_lifecycle_transition(
         connection,
         database_path,
         admitted_run_id,
         sequence
       ) do
    sql = """
    SELECT
      admitted_run_id,
      sequence,
      from_state,
      to_state,
      owner_id,
      fencing_token,
      occurred_at,
      evidence_json
    FROM run_lifecycle_transitions
    WHERE admitted_run_id = ?1 AND sequence = ?2
    """

    case domain_query(
           connection,
           sql,
           [admitted_run_id, sequence],
           database_path,
           "cannot read run lifecycle transition"
         ) do
      {:ok, []} -> corrupt_store(database_path, :missing_lifecycle_transition)
      {:ok, [row]} -> decode_lifecycle_transition(row, database_path)
      {:ok, _rows} -> corrupt_store(database_path, :duplicate_lifecycle_transition)
      {:error, _reason} = error -> error
    end
  end

  defp load_lifecycle_history(connection, database_path, admitted_run_id)
       when is_binary(admitted_run_id) and admitted_run_id != "" do
    with {:ok, _lifecycle} <-
           load_lifecycle(connection, database_path, admitted_run_id) do
      sql = """
      SELECT
        admitted_run_id,
        sequence,
        from_state,
        to_state,
        owner_id,
        fencing_token,
        occurred_at,
        evidence_json
      FROM run_lifecycle_transitions
      WHERE admitted_run_id = ?1
      ORDER BY sequence
      """

      case domain_query(
             connection,
             sql,
             [admitted_run_id],
             database_path,
             "cannot read run lifecycle history"
           ) do
        {:ok, rows} -> decode_lifecycle_history(rows, database_path)
        {:error, _reason} = error -> error
      end
    end
  end

  defp load_lifecycle_history(_connection, _database_path, _admitted_run_id),
    do: {:error, :invalid_transition}

  defp decode_lifecycle_history(rows, database_path) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, transitions} ->
      case decode_lifecycle_transition(row, database_path) do
        {:ok, transition} ->
          {:cont, {:ok, [transition | transitions]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, transitions} -> {:ok, Enum.reverse(transitions)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_lifecycle_transition(
         [
           admitted_run_id,
           sequence,
           from_state,
           to_state,
           owner_id,
           fencing_token,
           occurred_at,
           evidence_json
         ],
         database_path
       )
       when is_binary(admitted_run_id) and admitted_run_id != "" and
              is_integer(sequence) and sequence > 0 and
              is_binary(occurred_at) do
    with {:ok, decoded_from_state} <- decode_optional_lifecycle_state(from_state),
         {:ok, decoded_to_state} <- decode_lifecycle_state(to_state),
         {:ok, evidence} <- decode_json(evidence_json),
         true <- is_map(evidence) do
      {:ok,
       %LifecycleTransition{
         admitted_run_id: admitted_run_id,
         sequence: sequence,
         from_state: decoded_from_state,
         to_state: decoded_to_state,
         owner_id: owner_id,
         fencing_token: fencing_token,
         occurred_at: occurred_at,
         evidence: evidence
       }}
    else
      _invalid -> corrupt_store(database_path, :invalid_lifecycle_transition)
    end
  end

  defp decode_lifecycle_transition(_row, database_path),
    do: corrupt_store(database_path, :invalid_lifecycle_transition)

  defp decode_lifecycle_state("admitted"), do: {:ok, :admitted}
  defp decode_lifecycle_state("running"), do: {:ok, :running}
  defp decode_lifecycle_state("retrying"), do: {:ok, :retrying}
  defp decode_lifecycle_state("blocked"), do: {:ok, :blocked}
  defp decode_lifecycle_state("completed"), do: {:ok, :completed}
  defp decode_lifecycle_state("cleanup_pending"), do: {:ok, :cleanup_pending}
  defp decode_lifecycle_state("cleaned"), do: {:ok, :cleaned}
  defp decode_lifecycle_state(_state), do: {:error, :invalid_lifecycle_state}

  defp decode_optional_lifecycle_state(nil), do: {:ok, nil}
  defp decode_optional_lifecycle_state(state), do: decode_lifecycle_state(state)

  defp encode_optional_json(nil), do: {:ok, nil}
  defp encode_optional_json(value), do: encode_json(value)

  defp decode_optional_json(nil), do: {:ok, nil}
  defp decode_optional_json(value), do: decode_json(value)

  defp timestamp_from_ms(now_ms, database_path) do
    case DateTime.from_unix(now_ms, :millisecond) do
      {:ok, timestamp} ->
        {:ok, DateTime.to_iso8601(timestamp)}

      {:error, reason} ->
        {:error,
         error(
           :clock_failed,
           database_path,
           "control-plane wall clock cannot be represented as a timestamp",
           reason
         )}
    end
  end

  defp persist_side_effect_intent(
         connection,
         database_path,
         lease,
         kind,
         idempotency_key,
         intent,
         clock
       ) do
    with :ok <- validate_lease(lease),
         :ok <- validate_side_effect_identity(kind, idempotency_key, intent),
         {:ok, normalized_intent} <- normalize_durable_evidence(intent),
         {:ok, intent_json} <- encode_json(normalized_intent) do
      request = %{
        lease: lease,
        kind: kind,
        idempotency_key: idempotency_key,
        intent: normalized_intent,
        intent_json: intent_json
      }

      lease_transaction(connection, database_path, clock, fn now_ms ->
        begin_current_side_effect(connection, database_path, request, now_ms)
      end)
    else
      _invalid -> {:error, :invalid_side_effect}
    end
  end

  defp begin_current_side_effect(connection, database_path, request, now_ms) do
    with {:ok, lease_row} <-
           select_lease_record(connection, database_path, request.lease.admitted_run_id),
         {:ok, _deadline_ms} <-
           authorize_lease(lease_row, request.lease, now_ms, database_path),
         {:ok, admission} <-
           load_admission(
             connection,
             database_path,
             request.lease.target_id,
             request.lease.tracker_issue_id
           ),
         true <- admission.admitted_run_id == request.lease.admitted_run_id,
         artifact_path =
           side_effect_artifact_path(admission, request.kind, request.idempotency_key),
         {:ok, existing} <-
           select_side_effect(
             connection,
             database_path,
             request.lease.admitted_run_id,
             request.kind,
             request.idempotency_key
           ) do
      case existing do
        nil ->
          insert_new_side_effect(
            connection,
            database_path,
            Map.merge(request, %{admission: admission, artifact_path: artifact_path}),
            now_ms
          )

        %SideEffect{} = side_effect ->
          classify_repeated_side_effect(
            connection,
            database_path,
            side_effect,
            request.intent,
            artifact_path,
            now_ms
          )
      end
    else
      false -> {:error, :stale_lease}
      {:error, _reason} = error -> error
    end
  end

  defp insert_new_side_effect(connection, database_path, request, now_ms) do
    with :ok <-
           authorize_new_side_effect(
             connection,
             database_path,
             request.admission,
             request.kind
           ),
         {:ok, started_at} <- timestamp_from_ms(now_ms, database_path),
         :ok <-
           insert_side_effect(
             connection,
             database_path,
             request,
             started_at
           ),
         {:ok, %SideEffect{} = stored} <-
           select_side_effect(
             connection,
             database_path,
             request.lease.admitted_run_id,
             request.kind,
             request.idempotency_key
           ) do
      {:ok, stored}
    end
  end

  defp classify_repeated_side_effect(
         connection,
         database_path,
         side_effect,
         intent,
         artifact_path,
         now_ms
       ) do
    if side_effect.intent === intent and side_effect.artifact_path == artifact_path do
      case side_effect.state do
        :pending ->
          mark_side_effect_reconciliation(
            connection,
            database_path,
            side_effect,
            %{
              "reason" => "prior_external_outcome_unknown",
              "operator_action_required" => true
            },
            now_ms
          )

        :succeeded ->
          {:completed, side_effect}

        :failed ->
          {:failed, side_effect}

        :reconciliation_required ->
          {:blocked, side_effect}
      end
    else
      {:error, :side_effect_conflict}
    end
  end

  defp persist_side_effect_outcome(
         connection,
         database_path,
         lease,
         kind,
         idempotency_key,
         outcome,
         clock
       ) do
    with :ok <- validate_lease(lease),
         :ok <- validate_side_effect_identity(kind, idempotency_key, %{}),
         {:ok, state, normalized_outcome} <- normalize_side_effect_outcome(outcome),
         {:ok, outcome_json} <- encode_json(normalized_outcome) do
      request = %{
        lease: lease,
        kind: kind,
        idempotency_key: idempotency_key,
        state: state,
        outcome: normalized_outcome,
        outcome_json: outcome_json
      }

      lease_transaction(connection, database_path, clock, fn now_ms ->
        finish_current_side_effect(connection, database_path, request, now_ms)
      end)
    else
      _invalid -> {:error, :invalid_side_effect}
    end
  end

  defp finish_current_side_effect(connection, database_path, request, now_ms) do
    with {:ok, lease_row} <-
           select_lease_record(connection, database_path, request.lease.admitted_run_id),
         {:ok, _deadline_ms} <-
           authorize_lease(lease_row, request.lease, now_ms, database_path),
         {:ok, side_effect} <-
           select_side_effect(
             connection,
             database_path,
             request.lease.admitted_run_id,
             request.kind,
             request.idempotency_key
           ) do
      finish_selected_side_effect(
        connection,
        database_path,
        side_effect,
        request.lease,
        request.state,
        request.outcome,
        request.outcome_json,
        now_ms
      )
    end
  end

  defp finish_selected_side_effect(
         _connection,
         _database_path,
         nil,
         _lease,
         _state,
         _normalized_outcome,
         _outcome_json,
         _now_ms
       ),
       do: {:error, :side_effect_not_found}

  defp finish_selected_side_effect(
         connection,
         database_path,
         side_effect,
         lease,
         state,
         normalized_outcome,
         outcome_json,
         now_ms
       ) do
    cond do
      side_effect.owner_id != lease.owner_id or
          side_effect.fencing_token != lease.fencing_token ->
        {:error, :stale_lease}

      side_effect.state == :pending ->
        store_side_effect_outcome(
          connection,
          database_path,
          side_effect,
          state,
          outcome_json,
          now_ms
        )

      side_effect.state == state and side_effect.outcome === normalized_outcome ->
        side_effect_outcome_result(side_effect)

      true ->
        {:error, :side_effect_conflict}
    end
  end

  defp store_side_effect_outcome(
         connection,
         database_path,
         side_effect,
         :reconciliation_required,
         outcome_json,
         now_ms
       ) do
    mark_side_effect_reconciliation(
      connection,
      database_path,
      side_effect,
      outcome_json,
      now_ms,
      :encoded
    )
  end

  defp store_side_effect_outcome(
         connection,
         database_path,
         side_effect,
         state,
         outcome_json,
         now_ms
       )
       when state in [:succeeded, :failed] do
    with {:ok, completed_at} <- timestamp_from_ms(now_ms, database_path),
         :ok <-
           update_side_effect_outcome(
             connection,
             database_path,
             side_effect,
             state,
             outcome_json,
             completed_at
           ),
         {:ok, %SideEffect{} = stored} <-
           select_side_effect(
             connection,
             database_path,
             side_effect.admitted_run_id,
             side_effect.kind,
             side_effect.idempotency_key
           ) do
      side_effect_outcome_result(stored)
    end
  end

  defp mark_side_effect_reconciliation(
         connection,
         database_path,
         side_effect,
         outcome,
         now_ms,
         encoding \\ :encode
       ) do
    with {:ok, outcome_json} <- maybe_encode_side_effect_outcome(outcome, encoding),
         {:ok, updated_at} <- timestamp_from_ms(now_ms, database_path),
         :ok <-
           update_side_effect_reconciliation(
             connection,
             database_path,
             side_effect,
             outcome_json,
             updated_at
           ),
         {:ok, %SideEffect{} = stored} <-
           select_side_effect(
             connection,
             database_path,
             side_effect.admitted_run_id,
             side_effect.kind,
             side_effect.idempotency_key
           ) do
      {:blocked, stored}
    end
  end

  defp maybe_encode_side_effect_outcome(outcome_json, :encoded), do: {:ok, outcome_json}
  defp maybe_encode_side_effect_outcome(outcome, :encode), do: encode_json(outcome)

  defp side_effect_outcome_result(%SideEffect{state: :succeeded} = side_effect),
    do: {:ok, side_effect}

  defp side_effect_outcome_result(%SideEffect{state: :failed} = side_effect),
    do: {:failed, side_effect}

  defp side_effect_outcome_result(%SideEffect{state: :reconciliation_required} = side_effect),
    do: {:blocked, side_effect}

  defp authorize_new_side_effect(connection, database_path, admission, :workspace_cleanup) do
    with {:ok, lifecycle} <-
           load_lifecycle(connection, database_path, admission.admitted_run_id),
         true <- lifecycle.state == :cleanup_pending do
      :ok
    else
      _not_allowed -> {:error, :side_effect_not_allowed}
    end
  end

  defp authorize_new_side_effect(_connection, _database_path, admission, kind) do
    gates = admission.context.target.external_side_effect_gates

    allowed? =
      case kind do
        kind when kind in [:tracker_write, :handoff_route] ->
          gates["tracker_write"] == "allow"

        kind when kind in [:publish_preflight, :publish_handoff] ->
          gates["vcs_publish"] == "allow" and gates["pull_request_write"] == "allow"
      end

    if allowed?, do: :ok, else: {:error, :side_effect_not_allowed}
  end

  defp validate_side_effect_identity(kind, idempotency_key, intent)
       when kind in @side_effect_kinds and is_binary(idempotency_key) and
              idempotency_key != "" and byte_size(idempotency_key) <= 512 and is_map(intent) do
    if String.valid?(idempotency_key), do: :ok, else: {:error, :invalid_side_effect}
  end

  defp validate_side_effect_identity(_kind, _idempotency_key, _intent),
    do: {:error, :invalid_side_effect}

  defp normalize_side_effect_outcome({status, outcome})
       when status in [:succeeded, :failed, :ambiguous] and is_map(outcome) do
    with {:ok, normalized} <- normalize_durable_evidence(outcome) do
      state = if status == :ambiguous, do: :reconciliation_required, else: status
      {:ok, state, normalized}
    end
  end

  defp normalize_side_effect_outcome(_outcome), do: {:error, :invalid_side_effect}

  defp invoke_side_effect(operation) do
    case operation.() do
      {:ok, outcome} when is_map(outcome) -> {:succeeded, outcome}
      {:failed, outcome} when is_map(outcome) -> {:failed, outcome}
      {:ambiguous, outcome} when is_map(outcome) -> {:ambiguous, outcome}
      {:error, reason} -> {:ambiguous, opaque_external_failure(reason)}
      other -> {:ambiguous, opaque_external_failure(other)}
    end
  rescue
    exception ->
      {:ambiguous, %{"reason" => "external_call_raised", "class" => inspect(exception.__struct__)}}
  catch
    kind, _reason ->
      {:ambiguous, %{"reason" => "external_call_stopped", "class" => Atom.to_string(kind)}}
  end

  defp opaque_external_failure(reason) when is_map(reason) do
    case normalize_durable_evidence(reason) do
      {:ok, normalized} -> normalized
      {:error, :invalid_durable_evidence} -> %{"reason" => "external_call_outcome_unknown"}
    end
  end

  defp opaque_external_failure(_reason),
    do: %{"reason" => "external_call_outcome_unknown"}

  defp normalize_durable_evidence(evidence) when is_map(evidence) do
    case Redaction.json_ready(evidence) do
      normalized when is_map(normalized) -> {:ok, normalized}
      _invalid -> {:error, :invalid_durable_evidence}
    end
  rescue
    _exception -> {:error, :invalid_durable_evidence}
  catch
    _kind, _reason -> {:error, :invalid_durable_evidence}
  end

  defp normalize_durable_evidence(_evidence), do: {:error, :invalid_durable_evidence}

  defp insert_side_effect(connection, database_path, request, started_at) do
    sql = """
    INSERT INTO side_effect_intents (
      admitted_run_id,
      target_id,
      tracker_issue_id,
      kind,
      idempotency_key,
      artifact_path,
      state,
      owner_id,
      fencing_token,
      intent_json,
      started_at,
      updated_at
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'pending', ?7, ?8, ?9, ?10, ?10)
    """

    expect_no_rows(
      connection,
      sql,
      [
        request.admission.admitted_run_id,
        request.admission.target_id,
        request.admission.tracker_issue_id,
        Atom.to_string(request.kind),
        request.idempotency_key,
        request.artifact_path,
        request.lease.owner_id,
        request.lease.fencing_token,
        request.intent_json,
        started_at
      ],
      database_path,
      "cannot persist side-effect intent"
    )
  end

  defp update_side_effect_outcome(
         connection,
         database_path,
         side_effect,
         state,
         outcome_json,
         completed_at
       ) do
    sql = """
    UPDATE side_effect_intents
    SET state = ?1,
        outcome_json = ?2,
        completed_at = ?3,
        updated_at = ?3
    WHERE admitted_run_id = ?4
      AND kind = ?5
      AND idempotency_key = ?6
      AND state = 'pending'
      AND owner_id = ?7
      AND fencing_token = ?8
    """

    expect_no_rows(
      connection,
      sql,
      [
        Atom.to_string(state),
        outcome_json,
        completed_at,
        side_effect.admitted_run_id,
        Atom.to_string(side_effect.kind),
        side_effect.idempotency_key,
        side_effect.owner_id,
        side_effect.fencing_token
      ],
      database_path,
      "cannot persist side-effect outcome"
    )
  end

  defp update_side_effect_reconciliation(
         connection,
         database_path,
         side_effect,
         outcome_json,
         updated_at
       ) do
    sql = """
    UPDATE side_effect_intents
    SET state = 'reconciliation_required',
        outcome_json = ?1,
        updated_at = ?2
    WHERE admitted_run_id = ?3
      AND kind = ?4
      AND idempotency_key = ?5
      AND state = 'pending'
      AND owner_id = ?6
      AND fencing_token = ?7
    """

    expect_no_rows(
      connection,
      sql,
      [
        outcome_json,
        updated_at,
        side_effect.admitted_run_id,
        Atom.to_string(side_effect.kind),
        side_effect.idempotency_key,
        side_effect.owner_id,
        side_effect.fencing_token
      ],
      database_path,
      "cannot mark side effect for reconciliation"
    )
  end

  defp load_side_effect(connection, database_path, admitted_run_id, kind, idempotency_key) do
    with :ok <- validate_admitted_run_id(admitted_run_id),
         :ok <- validate_side_effect_identity(kind, idempotency_key, %{}),
         {:ok, side_effect} <-
           select_side_effect(
             connection,
             database_path,
             admitted_run_id,
             kind,
             idempotency_key
           ) do
      case side_effect do
        %SideEffect{} -> {:ok, side_effect}
        nil -> {:error, :side_effect_not_found}
      end
    end
  end

  defp load_side_effects(connection, database_path, admitted_run_id) do
    with :ok <- validate_admitted_run_id(admitted_run_id),
         {:ok, _lifecycle} <- load_lifecycle(connection, database_path, admitted_run_id) do
      sql = side_effect_select_sql() <> " WHERE admitted_run_id = ?1 ORDER BY kind, idempotency_key"

      case domain_query(
             connection,
             sql,
             [admitted_run_id],
             database_path,
             "cannot list side effects"
           ) do
        {:ok, rows} -> decode_side_effects(rows, database_path)
        {:error, _reason} = error -> error
      end
    end
  end

  defp select_side_effect(connection, database_path, admitted_run_id, kind, idempotency_key) do
    sql =
      side_effect_select_sql() <>
        " WHERE admitted_run_id = ?1 AND kind = ?2 AND idempotency_key = ?3"

    case domain_query(
           connection,
           sql,
           [admitted_run_id, Atom.to_string(kind), idempotency_key],
           database_path,
           "cannot read side effect"
         ) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row]} -> decode_side_effect(row, database_path)
      {:ok, _rows} -> corrupt_store(database_path, :duplicate_side_effect)
      {:error, _reason} = error -> error
    end
  end

  defp side_effect_select_sql do
    """
    SELECT
      admitted_run_id,
      target_id,
      tracker_issue_id,
      kind,
      idempotency_key,
      artifact_path,
      state,
      owner_id,
      fencing_token,
      intent_json,
      outcome_json,
      started_at,
      completed_at,
      updated_at
    FROM side_effect_intents
    """
  end

  defp decode_side_effects(rows, database_path) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, side_effects} ->
      case decode_side_effect(row, database_path) do
        {:ok, side_effect} -> {:cont, {:ok, [side_effect | side_effects]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, side_effects} -> {:ok, Enum.reverse(side_effects)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_side_effect(
         [
           admitted_run_id,
           target_id,
           tracker_issue_id,
           kind,
           idempotency_key,
           artifact_path,
           state,
           owner_id,
           fencing_token,
           intent_json,
           outcome_json,
           started_at,
           completed_at,
           updated_at
         ],
         database_path
       ) do
    fields = %{
      admitted_run_id: admitted_run_id,
      target_id: target_id,
      tracker_issue_id: tracker_issue_id,
      kind: kind,
      idempotency_key: idempotency_key,
      artifact_path: artifact_path,
      state: state,
      owner_id: owner_id,
      fencing_token: fencing_token,
      intent_json: intent_json,
      outcome_json: outcome_json,
      started_at: started_at,
      completed_at: completed_at,
      updated_at: updated_at
    }

    with true <- valid_side_effect_row?(fields),
         {:ok, decoded_kind} <- decode_side_effect_kind(kind),
         {:ok, decoded_state} <- decode_side_effect_state(state),
         {:ok, intent} <- decode_json(intent_json),
         {:ok, outcome} <- decode_optional_json(outcome_json),
         true <- is_map(intent) and (is_nil(outcome) or is_map(outcome)) do
      {:ok,
       %SideEffect{
         admitted_run_id: admitted_run_id,
         target_id: target_id,
         tracker_issue_id: tracker_issue_id,
         kind: decoded_kind,
         idempotency_key: idempotency_key,
         artifact_path: artifact_path,
         state: decoded_state,
         owner_id: owner_id,
         fencing_token: fencing_token,
         intent: intent,
         outcome: outcome,
         started_at: started_at,
         completed_at: completed_at,
         updated_at: updated_at
       }}
    else
      _invalid -> corrupt_store(database_path, :invalid_side_effect)
    end
  end

  defp decode_side_effect(_row, database_path),
    do: corrupt_store(database_path, :invalid_side_effect)

  defp valid_side_effect_row?(fields) do
    strings = [
      fields.admitted_run_id,
      fields.target_id,
      fields.tracker_issue_id,
      fields.idempotency_key,
      fields.artifact_path,
      fields.owner_id,
      fields.started_at,
      fields.updated_at
    ]

    Enum.all?(strings, &valid_non_empty_string?/1) and
      is_integer(fields.fencing_token) and fields.fencing_token > 0 and
      (is_nil(fields.completed_at) or is_binary(fields.completed_at))
  end

  defp decode_side_effect_kind(value) when is_binary(value) do
    case Enum.find(@side_effect_kinds, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_side_effect_kind}
      kind -> {:ok, kind}
    end
  end

  defp decode_side_effect_kind(_value), do: {:error, :invalid_side_effect_kind}

  defp decode_side_effect_state(value) when is_binary(value) do
    case Enum.find(@side_effect_states, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_side_effect_state}
      state -> {:ok, state}
    end
  end

  defp decode_side_effect_state(_value), do: {:error, :invalid_side_effect_state}

  defp side_effect_artifact_path(admission, kind, idempotency_key) do
    digest =
      :crypto.hash(:sha256, idempotency_key)
      |> Base.url_encode64(padding: false)

    Path.join([
      admission.context.workspace_path,
      ".symphony",
      "side-effects",
      admission.admitted_run_id,
      Atom.to_string(kind),
      digest <> ".json"
    ])
  end

  defp persist_process_group(connection, database_path, lease, process_identity, clock) do
    with :ok <- validate_lease(lease),
         {:ok, process_group_id, evidence, evidence_json} <-
           normalize_process_identity(process_identity) do
      lease_transaction(connection, database_path, clock, fn now_ms ->
        register_current_process_group(
          connection,
          database_path,
          lease,
          process_group_id,
          evidence,
          evidence_json,
          now_ms
        )
      end)
    else
      _invalid -> {:error, :invalid_process_ownership}
    end
  end

  defp normalize_process_identity(identity) when is_map(identity) do
    with true <-
           evidence_keys?(
             identity,
             [:os_pid, :process_group_id, :wrapper_pid, :started_at]
           ),
         {:ok, os_pid} <- fetch_evidence(identity, :os_pid),
         {:ok, process_group_id} <- fetch_evidence(identity, :process_group_id),
         {:ok, wrapper_pid} <- fetch_evidence(identity, :wrapper_pid),
         {:ok, started_at} <- fetch_evidence(identity, :started_at),
         true <- Enum.all?([os_pid, process_group_id, wrapper_pid], &(is_integer(&1) and &1 > 0)),
         true <- os_pid == process_group_id,
         true <- valid_non_empty_string?(started_at),
         {:ok, normalized_identity} <- normalize_durable_evidence(identity),
         evidence = %{"identity" => normalized_identity},
         {:ok, evidence_json} <- encode_json(evidence) do
      {:ok, process_group_id, evidence, evidence_json}
    else
      _invalid -> {:error, :invalid_process_ownership}
    end
  end

  defp normalize_process_identity(_identity), do: {:error, :invalid_process_ownership}

  defp register_current_process_group(
         connection,
         database_path,
         lease,
         process_group_id,
         evidence,
         evidence_json,
         now_ms
       ) do
    with {:ok, lease_row} <-
           select_lease_record(connection, database_path, lease.admitted_run_id),
         {:ok, _deadline_ms} <- authorize_lease(lease_row, lease, now_ms, database_path),
         {:ok, lifecycle} <-
           load_lifecycle(connection, database_path, lease.admitted_run_id),
         true <- lifecycle.state == :running,
         {:ok, existing} <-
           select_process_ownership(
             connection,
             database_path,
             lease.admitted_run_id,
             lease.fencing_token
           ) do
      case existing do
        nil ->
          insert_process_ownership(
            connection,
            database_path,
            lease,
            process_group_id,
            evidence_json,
            now_ms
          )

        %ProcessOwnership{
          process_group_id: ^process_group_id,
          owner_id: owner_id,
          state: :running,
          evidence: ^evidence
        } = ownership
        when owner_id == lease.owner_id ->
          {:ok, ownership}

        %ProcessOwnership{} ->
          {:error, :process_ownership_conflict}
      end
    else
      false -> {:error, :invalid_process_ownership}
      {:error, _reason} = error -> error
    end
  end

  defp persist_process_group_termination(
         connection,
         database_path,
         lease,
         process_group_id,
         outcome,
         clock
       ) do
    with :ok <- validate_lease(lease),
         true <- is_integer(process_group_id) and process_group_id > 0,
         {:ok, next_state, evidence} <- normalize_process_termination(outcome),
         {:ok, evidence_json} <- encode_json(evidence) do
      lease_transaction(connection, database_path, clock, fn now_ms ->
        terminate_current_process_group(
          connection,
          database_path,
          lease,
          process_group_id,
          next_state,
          evidence,
          evidence_json,
          now_ms
        )
      end)
    else
      _invalid -> {:error, :invalid_process_ownership}
    end
  end

  defp persist_recovered_process_termination(
         connection,
         database_path,
         lease,
         %ProcessOwnership{} = ownership,
         outcome,
         clock
       ) do
    with :ok <- validate_lease(lease),
         true <- ownership.admitted_run_id == lease.admitted_run_id,
         true <- ownership.target_id == lease.target_id,
         true <- ownership.tracker_issue_id == lease.tracker_issue_id,
         true <- ownership.fencing_token < lease.fencing_token,
         {:ok, next_state, evidence} <- normalize_process_termination(outcome),
         {:ok, evidence_json} <- encode_json(evidence) do
      lease_transaction(connection, database_path, clock, fn now_ms ->
        terminate_recovered_process_group(
          connection,
          database_path,
          lease,
          ownership,
          next_state,
          evidence,
          evidence_json,
          now_ms
        )
      end)
    else
      _invalid -> {:error, :invalid_process_ownership}
    end
  end

  defp persist_recovered_process_termination(
         _connection,
         _database_path,
         _lease,
         _ownership,
         _outcome,
         _clock
       ),
       do: {:error, :invalid_process_ownership}

  defp terminate_recovered_process_group(
         connection,
         database_path,
         lease,
         ownership,
         next_state,
         evidence,
         evidence_json,
         now_ms
       ) do
    with {:ok, lease_row} <-
           select_lease_record(connection, database_path, lease.admitted_run_id),
         {:ok, _deadline_ms} <- authorize_lease(lease_row, lease, now_ms, database_path),
         {:ok, stored_ownership} <-
           select_process_ownership(
             connection,
             database_path,
             ownership.admitted_run_id,
             ownership.fencing_token
           ),
         true <- stored_ownership === ownership do
      apply_process_termination(
        connection,
        database_path,
        stored_ownership,
        lease,
        next_state,
        evidence,
        evidence_json,
        now_ms
      )
    else
      false -> {:error, :process_ownership_conflict}
      {:error, _reason} = error -> error
    end
  end

  defp terminate_current_process_group(
         connection,
         database_path,
         lease,
         process_group_id,
         next_state,
         evidence,
         evidence_json,
         now_ms
       ) do
    with {:ok, lease_row} <-
           select_lease_record(connection, database_path, lease.admitted_run_id),
         {:ok, _deadline_ms} <- authorize_lease(lease_row, lease, now_ms, database_path),
         {:ok, ownership} <-
           select_process_ownership(
             connection,
             database_path,
             lease.admitted_run_id,
             lease.fencing_token
           ),
         :ok <-
           validate_process_termination_identity(
             ownership,
             lease,
             process_group_id
           ) do
      apply_process_termination(
        connection,
        database_path,
        ownership,
        lease,
        next_state,
        evidence,
        evidence_json,
        now_ms
      )
    end
  end

  defp apply_process_termination(
         _connection,
         _database_path,
         %ProcessOwnership{state: state, evidence: stored_evidence} = ownership,
         _lease,
         state,
         evidence,
         _evidence_json,
         _now_ms
       )
       when stored_evidence === evidence,
       do: {:ok, ownership}

  defp apply_process_termination(
         _connection,
         _database_path,
         %ProcessOwnership{state: :stopped},
         _lease,
         _next_state,
         _evidence,
         _evidence_json,
         _now_ms
       ),
       do: {:error, :process_ownership_conflict}

  defp apply_process_termination(
         connection,
         database_path,
         ownership,
         lease,
         next_state,
         _evidence,
         evidence_json,
         now_ms
       ) do
    with {:ok, updated_at} <- timestamp_from_ms(now_ms, database_path),
         :ok <-
           update_process_ownership(
             connection,
             database_path,
             ownership,
             next_state,
             evidence_json,
             updated_at
           ),
         :ok <-
           maybe_block_unverifiable_process(
             connection,
             database_path,
             lease,
             next_state,
             now_ms
           ),
         {:ok, %ProcessOwnership{} = stored} <-
           select_process_ownership(
             connection,
             database_path,
             ownership.admitted_run_id,
             ownership.fencing_token
           ) do
      {:ok, stored}
    end
  end

  defp maybe_block_unverifiable_process(
         connection,
         database_path,
         lease,
         :unverifiable,
         now_ms
       ) do
    with {:ok, {lifecycle, cleanup_authority}} <-
           select_lifecycle_by_run_id(connection, database_path, lease.admitted_run_id) do
      block_unverifiable_lifecycle(
        connection,
        database_path,
        lease,
        lifecycle,
        cleanup_authority,
        now_ms
      )
    end
  end

  defp maybe_block_unverifiable_process(
         _connection,
         _database_path,
         _lease,
         :stopped,
         _now_ms
       ),
       do: :ok

  defp block_unverifiable_lifecycle(
         _connection,
         _database_path,
         _lease,
         %Lifecycle{state: :blocked},
         _cleanup_authority,
         _now_ms
       ),
       do: :ok

  defp block_unverifiable_lifecycle(
         connection,
         database_path,
         lease,
         %Lifecycle{state: state} = lifecycle,
         cleanup_authority,
         now_ms
       )
       when state in [:admitted, :running, :retrying] do
    request = %{
      lease: lease,
      expected_sequence: lifecycle.sequence,
      expected_state: state,
      next_state: :blocked,
      evidence: %{reason: "process group termination is unverifiable"}
    }

    case transition_lifecycle(
           connection,
           database_path,
           {lifecycle, cleanup_authority},
           request,
           now_ms
         ) do
      {:ok, _blocked} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp block_unverifiable_lifecycle(
         _connection,
         _database_path,
         _lease,
         %Lifecycle{state: :cleanup_pending},
         _cleanup_authority,
         _now_ms
       ),
       do: :ok

  defp block_unverifiable_lifecycle(
         _connection,
         _database_path,
         _lease,
         _lifecycle,
         _cleanup_authority,
         _now_ms
       ),
       do: {:error, :invalid_process_ownership}

  defp normalize_process_termination({state, evidence})
       when state in [:stopped, :unverifiable] and is_map(evidence) do
    case normalize_durable_evidence(evidence) do
      {:ok, normalized} ->
        {:ok, state, Map.put(normalized, "result", Atom.to_string(state))}

      {:error, :invalid_durable_evidence} ->
        {:error, :invalid_process_ownership}
    end
  end

  defp normalize_process_termination(_outcome),
    do: {:error, :invalid_process_ownership}

  defp validate_process_termination_identity(
         %ProcessOwnership{
           owner_id: owner_id,
           process_group_id: process_group_id
         },
         lease,
         process_group_id
       )
       when owner_id == lease.owner_id,
       do: :ok

  defp validate_process_termination_identity(nil, _lease, _process_group_id),
    do: {:error, :invalid_process_ownership}

  defp validate_process_termination_identity(_ownership, _lease, _process_group_id),
    do: {:error, :process_ownership_conflict}

  defp ensure_process_group_stopped(connection, database_path, admitted_run_id, fencing_token) do
    with {:ok, ownership} <-
           select_process_ownership(
             connection,
             database_path,
             admitted_run_id,
             fencing_token
           ) do
      case ownership do
        nil ->
          :ok

        %ProcessOwnership{state: :stopped} ->
          :ok

        %ProcessOwnership{state: state} when state in [:running, :unverifiable] ->
          {:error, :process_termination_unverified}
      end
    end
  end

  defp ensure_token_reservation_release_safe(
         connection,
         database_path,
         admitted_run_id,
         fencing_token
       ) do
    with {:ok, budget} <- select_token_budget(connection, database_path, admitted_run_id) do
      ensure_budget_process_stop_evidence(
        connection,
        database_path,
        admitted_run_id,
        fencing_token,
        budget
      )
    end
  end

  defp ensure_budget_process_stop_evidence(
         _connection,
         _database_path,
         _admitted_run_id,
         _fencing_token,
         :unlimited
       ),
       do: :ok

  defp ensure_budget_process_stop_evidence(
         _connection,
         _database_path,
         _admitted_run_id,
         _fencing_token,
         %{state: state}
       )
       when state in [:released, :terminal],
       do: :ok

  defp ensure_budget_process_stop_evidence(
         connection,
         database_path,
         admitted_run_id,
         fencing_token,
         %{state: :active}
       ) do
    with {:ok, {lifecycle, _cleanup_authority}} <-
           select_lifecycle_by_run_id(connection, database_path, admitted_run_id),
         {:ok, ownership} <-
           select_process_ownership(
             connection,
             database_path,
             admitted_run_id,
             fencing_token
           ) do
      cond do
        is_nil(lifecycle.started_at) -> :ok
        match?(%ProcessOwnership{state: :stopped}, ownership) -> :ok
        true -> {:error, :process_termination_unverified}
      end
    end
  end

  defp insert_process_ownership(
         connection,
         database_path,
         lease,
         process_group_id,
         evidence_json,
         now_ms
       ) do
    with {:ok, started_at} <- timestamp_from_ms(now_ms, database_path),
         :ok <-
           expect_no_rows(
             connection,
             """
             INSERT INTO run_process_ownership (
               admitted_run_id,
               target_id,
               tracker_issue_id,
               owner_id,
               fencing_token,
               process_group_id,
               state,
               evidence_json,
               started_at,
               updated_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'running', ?7, ?8, ?8)
             """,
             [
               lease.admitted_run_id,
               lease.target_id,
               lease.tracker_issue_id,
               lease.owner_id,
               lease.fencing_token,
               process_group_id,
               evidence_json,
               started_at
             ],
             database_path,
             "cannot persist process-group ownership"
           ),
         {:ok, %ProcessOwnership{} = stored} <-
           select_process_ownership(
             connection,
             database_path,
             lease.admitted_run_id,
             lease.fencing_token
           ) do
      {:ok, stored}
    end
  end

  defp update_process_ownership(
         connection,
         database_path,
         ownership,
         state,
         evidence_json,
         updated_at
       ) do
    expect_no_rows(
      connection,
      """
      UPDATE run_process_ownership
      SET state = ?1, evidence_json = ?2, updated_at = ?3
      WHERE admitted_run_id = ?4
        AND fencing_token = ?5
        AND owner_id = ?6
        AND process_group_id = ?7
      """,
      [
        Atom.to_string(state),
        evidence_json,
        updated_at,
        ownership.admitted_run_id,
        ownership.fencing_token,
        ownership.owner_id,
        ownership.process_group_id
      ],
      database_path,
      "cannot persist process-group termination"
    )
  end

  defp select_lifecycle_process_ownership(
         connection,
         database_path,
         %Lifecycle{} = lifecycle
       ) do
    with {:ok, transition} <-
           select_lifecycle_transition(
             connection,
             database_path,
             lifecycle.admitted_run_id,
             lifecycle.sequence
           ) do
      case transition.fencing_token do
        fencing_token when is_integer(fencing_token) ->
          select_process_ownership(
            connection,
            database_path,
            lifecycle.admitted_run_id,
            fencing_token
          )

        nil ->
          {:ok, nil}
      end
    end
  end

  defp select_process_ownership(
         connection,
         database_path,
         admitted_run_id,
         fencing_token
       ) do
    sql = """
    SELECT
      admitted_run_id,
      target_id,
      tracker_issue_id,
      owner_id,
      fencing_token,
      process_group_id,
      state,
      evidence_json,
      started_at,
      updated_at
    FROM run_process_ownership
    WHERE admitted_run_id = ?1 AND fencing_token = ?2
    """

    case domain_query(
           connection,
           sql,
           [admitted_run_id, fencing_token],
           database_path,
           "cannot read process-group ownership"
         ) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row]} -> decode_process_ownership(row, database_path)
      {:ok, _rows} -> corrupt_store(database_path, :duplicate_process_ownership)
      {:error, _reason} = error -> error
    end
  end

  defp decode_process_ownership(
         [
           admitted_run_id,
           target_id,
           tracker_issue_id,
           owner_id,
           fencing_token,
           process_group_id,
           state,
           evidence_json,
           started_at,
           updated_at
         ],
         database_path
       ) do
    fields = %{
      admitted_run_id: admitted_run_id,
      target_id: target_id,
      tracker_issue_id: tracker_issue_id,
      owner_id: owner_id,
      fencing_token: fencing_token,
      process_group_id: process_group_id,
      started_at: started_at,
      updated_at: updated_at
    }

    with true <- valid_process_ownership_row?(fields),
         {:ok, decoded_state} <- decode_process_ownership_state(state),
         {:ok, evidence} <- decode_json(evidence_json),
         true <- is_map(evidence) do
      {:ok,
       %ProcessOwnership{
         admitted_run_id: admitted_run_id,
         target_id: target_id,
         tracker_issue_id: tracker_issue_id,
         owner_id: owner_id,
         fencing_token: fencing_token,
         process_group_id: process_group_id,
         state: decoded_state,
         evidence: evidence,
         started_at: started_at,
         updated_at: updated_at
       }}
    else
      _invalid -> corrupt_store(database_path, :invalid_process_ownership)
    end
  end

  defp decode_process_ownership(_row, database_path),
    do: corrupt_store(database_path, :invalid_process_ownership)

  defp valid_process_ownership_row?(fields) do
    strings = [
      fields.admitted_run_id,
      fields.target_id,
      fields.tracker_issue_id,
      fields.owner_id,
      fields.started_at,
      fields.updated_at
    ]

    Enum.all?(strings, &valid_non_empty_string?/1) and
      is_integer(fields.fencing_token) and fields.fencing_token > 0 and
      is_integer(fields.process_group_id) and fields.process_group_id > 0
  end

  defp decode_process_ownership_state("running"), do: {:ok, :running}
  defp decode_process_ownership_state("stopped"), do: {:ok, :stopped}
  defp decode_process_ownership_state("unverifiable"), do: {:ok, :unverifiable}
  defp decode_process_ownership_state(_state), do: {:error, :invalid_process_ownership_state}

  defp prepare_admission(%ExecutionContext{} = context) do
    prepare_admission(context, DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp prepare_admission(%ExecutionContext{} = context, admitted_at)
       when is_binary(admitted_at) do
    with :ok <- ExecutionContext.validate(context),
         {:ok, references} <- credential_references(context),
         {:ok, provenance} <- ExecutionContext.safe_provenance(context),
         {:ok, token_budget} <- prepare_token_budget(context.target.budget_limits, admitted_at),
         {:ok, target_context_json} <- encode_json(target_to_map(context.target)),
         {:ok, context_json} <- encode_json(execution_to_map(context)),
         {:ok, secret_references_json} <- encode_json(references),
         {:ok, provenance_json} <- encode_json(stringify_keys(provenance)),
         {:ok, execution_profile_json} <-
           encode_json(stringify_keys(context.execution_profile)),
         {:ok, workspace_authority_json} <-
           encode_json(%{
             "workspace_path" => context.workspace_path,
             "worker_host" => context.worker_host,
             "worktree_policy" => context.target.worktree_policy
           }),
         {:ok, runner_policy_json} <- encode_json(context.target.runner_policy),
         {:ok, checks_json} <- encode_json(context.target.effective_checks),
         {:ok, delivery_gates_json} <-
           encode_json(context.target.external_side_effect_gates) do
      {:ok,
       %{
         admitted_run_id: admitted_run_id(),
         target_id: context.target.target_id,
         tracker_issue_id: context.issue_id,
         issue_identifier: context.issue_identifier,
         registry_generation: context.target.registry_generation,
         policy_hash: context.target.policy_hash,
         repo_manifest_hash: context.target.repo_manifest_hash,
         role: Atom.to_string(context.role),
         execution_profile_json: execution_profile_json,
         workspace_authority_json: workspace_authority_json,
         runner_policy_json: runner_policy_json,
         checks_json: checks_json,
         delivery_gates_json: delivery_gates_json,
         target_context_json: target_context_json,
         context_json: context_json,
         provenance_json: provenance_json,
         secret_references_json: secret_references_json,
         token_budget: token_budget,
         admitted_at: admitted_at
       }}
    else
      _invalid -> {:error, :invalid_admission}
    end
  end

  defp prepare_admission(_context, _admitted_at), do: {:error, :invalid_admission}

  defp prepare_token_budget(limits, _admitted_at) when limits == %{}, do: {:ok, nil}

  defp prepare_token_budget(
         %{
           "per_run" => %{"max_total_tokens" => per_run_limit},
           "daily" => %{"max_total_tokens" => daily_limit},
           "weekly" => %{"max_total_tokens" => weekly_limit}
         },
         admitted_at
       )
       when is_integer(per_run_limit) and per_run_limit > 0 and
              is_integer(daily_limit) and daily_limit >= per_run_limit and
              is_integer(weekly_limit) and weekly_limit >= daily_limit do
    with {:ok, admission_day, admission_week} <- admission_periods(admitted_at) do
      {:ok,
       %{
         admission_day: admission_day,
         admission_week: admission_week,
         per_run_limit: per_run_limit,
         daily_limit: daily_limit,
         weekly_limit: weekly_limit
       }}
    end
  end

  defp prepare_token_budget(_limits, _admitted_at), do: {:error, :invalid_token_budget}

  defp admission_periods(admitted_at) do
    case DateTime.from_iso8601(admitted_at) do
      {:ok, admitted, 0} ->
        date = DateTime.to_date(admitted)

        {:ok, Date.to_iso8601(date), date |> Date.beginning_of_week(:monday) |> Date.to_iso8601()}

      _invalid ->
        {:error, :invalid_admission_period}
    end
  end

  defp persist_admission(connection, database_path, record) do
    with :ok <- execute(connection, "BEGIN IMMEDIATE", database_path, :transaction_failed) do
      result =
        with :ok <- ensure_target_generation(connection, database_path, record),
             {:ok, existing} <-
               select_admission(connection, database_path, record.target_id, record.tracker_issue_id) do
          persist_or_reuse_admission(connection, database_path, record, existing)
        end

      finish_transaction(connection, database_path, result)
    end
  end

  defp ensure_target_generation(connection, database_path, record) do
    sql = """
    SELECT policy_hash, repo_manifest_hash, target_context_json, secret_references_json
    FROM target_generations
    WHERE target_id = ?1 AND registry_generation = ?2
    """

    case domain_query(
           connection,
           sql,
           [record.target_id, record.registry_generation],
           database_path,
           "cannot read pinned target generation"
         ) do
      {:ok, []} ->
        insert_target_generation(connection, database_path, record)

      {:ok,
       [
         [
           policy_hash,
           repo_manifest_hash,
           target_context_json,
           secret_references_json
         ]
       ]} ->
        if policy_hash == record.policy_hash and
             repo_manifest_hash == record.repo_manifest_hash and
             same_json?(target_context_json, record.target_context_json) and
             same_json?(secret_references_json, record.secret_references_json) do
          :ok
        else
          {:error, :admission_conflict}
        end

      {:ok, _invalid_rows} ->
        corrupt_store(database_path, :invalid_target_generation)

      {:error, _reason} = error ->
        error
    end
  end

  defp insert_target_generation(connection, database_path, record) do
    sql = """
    INSERT INTO target_generations (
      target_id,
      registry_generation,
      policy_hash,
      repo_manifest_hash,
      target_context_json,
      secret_references_json,
      created_at
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    """

    expect_no_rows(
      connection,
      sql,
      [
        record.target_id,
        record.registry_generation,
        record.policy_hash,
        record.repo_manifest_hash,
        record.target_context_json,
        record.secret_references_json,
        record.admitted_at
      ],
      database_path,
      "cannot persist pinned target generation"
    )
  end

  defp persist_or_reuse_admission(connection, database_path, record, nil) do
    with :ok <- ensure_initial_token_capacity(connection, database_path, record),
         :ok <- insert_admission(connection, database_path, record),
         :ok <- insert_initial_lifecycle(connection, database_path, record),
         :ok <- insert_initial_token_budget(connection, database_path, record),
         {:ok, row} <-
           select_admission(
             connection,
             database_path,
             record.target_id,
             record.tracker_issue_id
           ) do
      decode_admission_row(row, database_path)
    end
  end

  defp persist_or_reuse_admission(_connection, database_path, record, row) do
    if same_admission_row?(row, record),
      do: decode_admission_row(row, database_path),
      else: {:error, :admission_conflict}
  end

  defp insert_admission(connection, database_path, record) do
    sql = """
    INSERT INTO run_admissions (
      admitted_run_id,
      target_id,
      tracker_issue_id,
      issue_identifier,
      registry_generation,
      policy_hash,
      repo_manifest_hash,
      role,
      execution_profile_json,
      workspace_authority_json,
      runner_policy_json,
      checks_json,
      delivery_gates_json,
      context_json,
      provenance_json,
      secret_references_json,
      state,
      admitted_at
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9,
      ?10, ?11, ?12, ?13, ?14, ?15, ?16, 'admitted', ?17
    )
    """

    expect_no_rows(
      connection,
      sql,
      [
        record.admitted_run_id,
        record.target_id,
        record.tracker_issue_id,
        record.issue_identifier,
        record.registry_generation,
        record.policy_hash,
        record.repo_manifest_hash,
        record.role,
        record.execution_profile_json,
        record.workspace_authority_json,
        record.runner_policy_json,
        record.checks_json,
        record.delivery_gates_json,
        record.context_json,
        record.provenance_json,
        record.secret_references_json,
        record.admitted_at
      ],
      database_path,
      "cannot persist run admission"
    )
  end

  defp insert_initial_lifecycle(connection, database_path, record) do
    lifecycle_sql = """
    INSERT INTO run_lifecycles (
      admitted_run_id,
      state,
      sequence,
      admitted_at,
      updated_at
    ) VALUES (?1, 'admitted', 1, ?2, ?2)
    """

    transition_sql = """
    INSERT INTO run_lifecycle_transitions (
      admitted_run_id,
      sequence,
      from_state,
      to_state,
      owner_id,
      fencing_token,
      occurred_at,
      evidence_json
    ) VALUES (?1, 1, NULL, 'admitted', NULL, NULL, ?2, '{}')
    """

    with :ok <-
           expect_no_rows(
             connection,
             lifecycle_sql,
             [record.admitted_run_id, record.admitted_at],
             database_path,
             "cannot persist initial run lifecycle"
           ) do
      expect_no_rows(
        connection,
        transition_sql,
        [record.admitted_run_id, record.admitted_at],
        database_path,
        "cannot persist initial run transition"
      )
    end
  end

  defp ensure_initial_token_capacity(_connection, _database_path, %{token_budget: nil}),
    do: :ok

  defp ensure_initial_token_capacity(connection, database_path, record) do
    budget = record.token_budget

    with {:ok, {daily_allocated, stored_daily_limit}} <-
           period_token_balance(
             connection,
             database_path,
             record.target_id,
             :day,
             budget.admission_day
           ),
         :ok <-
           ensure_token_capacity(
             daily_allocated,
             budget.per_run_limit,
             effective_period_limit(budget.daily_limit, stored_daily_limit),
             :daily_token_budget_exceeded
           ),
         {:ok, {weekly_allocated, stored_weekly_limit}} <-
           period_token_balance(
             connection,
             database_path,
             record.target_id,
             :week,
             budget.admission_week
           ) do
      ensure_token_capacity(
        weekly_allocated,
        budget.per_run_limit,
        effective_period_limit(budget.weekly_limit, stored_weekly_limit),
        :weekly_token_budget_exceeded
      )
    end
  end

  defp insert_initial_token_budget(_connection, _database_path, %{token_budget: nil}), do: :ok

  defp insert_initial_token_budget(connection, database_path, record) do
    budget = record.token_budget

    sql = """
    INSERT INTO run_token_budgets (
      admitted_run_id,
      target_id,
      admission_day,
      admission_week,
      per_run_limit,
      daily_limit,
      weekly_limit,
      cumulative_tokens,
      charged_tokens,
      reserved_tokens,
      state,
      created_at,
      updated_at
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, 0, ?5, 'active', ?8, ?8)
    """

    expect_no_rows(
      connection,
      sql,
      [
        record.admitted_run_id,
        record.target_id,
        budget.admission_day,
        budget.admission_week,
        budget.per_run_limit,
        budget.daily_limit,
        budget.weekly_limit,
        record.admitted_at
      ],
      database_path,
      "cannot persist initial token reservation"
    )
  end

  defp load_admission(connection, database_path, target_id, tracker_issue_id)
       when is_binary(target_id) and is_binary(tracker_issue_id) do
    with {:ok, row} <-
           select_admission(connection, database_path, target_id, tracker_issue_id) do
      case row do
        nil -> {:error, :admission_not_found}
        stored -> decode_admission_row(stored, database_path)
      end
    end
  end

  defp load_admission(_connection, _database_path, _target_id, _tracker_issue_id),
    do: {:error, :invalid_admission}

  defp select_admission(connection, database_path, target_id, tracker_issue_id) do
    sql = """
    SELECT
      admission.admitted_run_id,
      admission.issue_identifier,
      admission.registry_generation,
      admission.policy_hash,
      admission.repo_manifest_hash,
      admission.role,
      admission.execution_profile_json,
      admission.workspace_authority_json,
      admission.runner_policy_json,
      admission.checks_json,
      admission.delivery_gates_json,
      admission.context_json,
      admission.provenance_json,
      admission.secret_references_json,
      admission.admitted_at,
      target.target_context_json,
      target.secret_references_json
    FROM run_admissions AS admission
    JOIN target_generations AS target
      ON target.target_id = admission.target_id
     AND target.registry_generation = admission.registry_generation
    WHERE admission.target_id = ?1 AND admission.tracker_issue_id = ?2
    """

    case domain_query(
           connection,
           sql,
           [target_id, tracker_issue_id],
           database_path,
           "cannot read run admission"
         ) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row]} -> {:ok, row}
      {:ok, _invalid_rows} -> corrupt_store(database_path, :duplicate_run_admission)
      {:error, _reason} = error -> error
    end
  end

  defp same_admission_row?(
         [
           _admitted_run_id,
           issue_identifier,
           registry_generation,
           policy_hash,
           repo_manifest_hash,
           role,
           execution_profile_json,
           workspace_authority_json,
           runner_policy_json,
           checks_json,
           delivery_gates_json,
           context_json,
           provenance_json,
           secret_references_json,
           _admitted_at,
           target_context_json,
           target_secret_references_json
         ],
         record
       ) do
    issue_identifier == record.issue_identifier and
      registry_generation == record.registry_generation and
      policy_hash == record.policy_hash and
      repo_manifest_hash == record.repo_manifest_hash and
      role == record.role and
      Enum.all?(
        [
          {execution_profile_json, record.execution_profile_json},
          {workspace_authority_json, record.workspace_authority_json},
          {runner_policy_json, record.runner_policy_json},
          {checks_json, record.checks_json},
          {delivery_gates_json, record.delivery_gates_json},
          {context_json, record.context_json},
          {provenance_json, record.provenance_json},
          {secret_references_json, record.secret_references_json},
          {target_context_json, record.target_context_json},
          {target_secret_references_json, record.secret_references_json}
        ],
        fn {stored, incoming} -> same_json?(stored, incoming) end
      )
  end

  defp same_admission_row?(_row, _record), do: false

  defp decode_admission_row(
         [
           admitted_run_id,
           _issue_identifier,
           _registry_generation,
           _policy_hash,
           _repo_manifest_hash,
           _role,
           _execution_profile_json,
           _workspace_authority_json,
           _runner_policy_json,
           _checks_json,
           _delivery_gates_json,
           context_json,
           _provenance_json,
           _secret_references_json,
           admitted_at,
           target_context_json,
           _target_secret_references_json
         ] = row,
         database_path
       ) do
    with {:ok, target_map} <- decode_json(target_context_json),
         {:ok, execution_map} <- decode_json(context_json),
         {:ok, target} <- target_from_map(target_map),
         {:ok, context} <- execution_from_map(execution_map, target),
         {:ok, record} <- prepare_admission(context),
         true <- same_admission_row?(row, record) do
      {:ok,
       %Admission{
         admitted_run_id: admitted_run_id,
         target_id: target.target_id,
         tracker_issue_id: context.issue_id,
         issue_identifier: context.issue_identifier,
         registry_generation: target.registry_generation,
         policy_hash: target.policy_hash,
         repo_manifest_hash: target.repo_manifest_hash,
         context: context,
         admitted_at: admitted_at
       }}
    else
      _invalid -> corrupt_store(database_path, :invalid_run_admission)
    end
  end

  defp decode_admission_row(_row, database_path),
    do: corrupt_store(database_path, :invalid_run_admission)

  defp target_to_map(%TargetContext{} = target) do
    %{
      "target_id" => target.target_id,
      "state" => Atom.to_string(target.state),
      "dispatch_mode" => optional_atom_string(target.dispatch_mode),
      "registry_generation" => target.registry_generation,
      "policy_hash" => target.policy_hash,
      "repo_manifest_hash" => target.repo_manifest_hash,
      "issue_policy_authority" => target.issue_policy_authority,
      "workspace_layout" => Atom.to_string(target.workspace_layout),
      "repo_policy" => target.repo_policy,
      "tracker_connection" => target.tracker_connection,
      "run_target" => target.run_target,
      "worktree_policy" => target.worktree_policy,
      "runner_policy" => target.runner_policy,
      "effective_checks" => target.effective_checks,
      "external_side_effect_gates" => target.external_side_effect_gates,
      "capacity_limits" => target.capacity_limits,
      "budget_limits" => target.budget_limits
    }
  end

  defp execution_to_map(%ExecutionContext{} = context) do
    %{
      "issue_id" => context.issue_id,
      "issue_identifier" => context.issue_identifier,
      "workspace_path" => context.workspace_path,
      "runner_name" => context.runner_name,
      "runner_config" => context.runner_config,
      "policy" => context.policy,
      "role" => Atom.to_string(context.role),
      "execution_profile" => stringify_keys(context.execution_profile),
      "timeout_ms" => context.timeout_ms,
      "max_retries" => context.max_retries,
      "worker_host" => context.worker_host
    }
  end

  defp target_from_map(map) when is_map(map) do
    map =
      Map.put_new_lazy(map, "workspace_layout", fn ->
        root = get_in(map, ["worktree_policy", "root"])

        if is_map(map["issue_policy_authority"]) or
             (is_binary(root) and Path.basename(root) == map["target_id"]),
           do: "flat",
           else: "target_scoped"
      end)

    keys = ~w(
      budget_limits
      capacity_limits
      dispatch_mode
      effective_checks
      external_side_effect_gates
      issue_policy_authority
      policy_hash
      registry_generation
      repo_manifest_hash
      repo_policy
      run_target
      runner_policy
      state
      target_id
      tracker_connection
      worktree_policy
      workspace_layout
    )

    with true <- Enum.sort(Map.keys(map)) == Enum.sort(keys),
         {:ok, state} <- target_state(map["state"]),
         {:ok, dispatch_mode} <- dispatch_mode(map["dispatch_mode"]),
         {:ok, workspace_layout} <- workspace_layout(map["workspace_layout"]) do
      {:ok,
       struct!(TargetContext,
         target_id: map["target_id"],
         state: state,
         dispatch_mode: dispatch_mode,
         registry_generation: map["registry_generation"],
         policy_hash: map["policy_hash"],
         repo_manifest_hash: map["repo_manifest_hash"],
         issue_policy_authority: map["issue_policy_authority"],
         workspace_layout: workspace_layout,
         repo_policy: map["repo_policy"],
         tracker_connection: map["tracker_connection"],
         run_target: map["run_target"],
         worktree_policy: map["worktree_policy"],
         runner_policy: map["runner_policy"],
         effective_checks: map["effective_checks"],
         external_side_effect_gates: map["external_side_effect_gates"],
         capacity_limits: map["capacity_limits"],
         budget_limits: map["budget_limits"]
       )}
    else
      _invalid -> {:error, :invalid_target_context}
    end
  end

  defp target_from_map(_map), do: {:error, :invalid_target_context}

  defp execution_from_map(map, %TargetContext{} = target) when is_map(map) do
    keys = ~w(
      execution_profile
      issue_id
      issue_identifier
      max_retries
      policy
      role
      runner_config
      runner_name
      timeout_ms
      worker_host
      workspace_path
    )

    with true <- Enum.sort(Map.keys(map)) == Enum.sort(keys),
         {:ok, role} <- execution_role(map["role"]),
         {:ok, profile} <- execution_profile(map["execution_profile"]) do
      context =
        struct!(ExecutionContext,
          target: target,
          issue_id: map["issue_id"],
          issue_identifier: map["issue_identifier"],
          workspace_path: map["workspace_path"],
          runner_name: map["runner_name"],
          runner_config: map["runner_config"],
          policy: map["policy"],
          role: role,
          execution_profile: profile,
          timeout_ms: map["timeout_ms"],
          max_retries: map["max_retries"],
          worker_host: map["worker_host"]
        )

      case ExecutionContext.validate(context) do
        :ok -> {:ok, context}
        {:error, _reason} -> {:error, :invalid_execution_context}
      end
    else
      _invalid -> {:error, :invalid_execution_context}
    end
  end

  defp execution_from_map(_map, _target), do: {:error, :invalid_execution_context}

  defp execution_profile(map) when is_map(map) do
    keys = ~w(budget command max_retries model name reasoning_effort timeout_ms)

    if Enum.sort(Map.keys(map)) == keys do
      {:ok,
       %{
         name: map["name"],
         reasoning_effort: map["reasoning_effort"],
         budget: map["budget"],
         timeout_ms: map["timeout_ms"],
         max_retries: map["max_retries"],
         command: map["command"],
         model: map["model"]
       }}
    else
      {:error, :invalid_execution_profile}
    end
  end

  defp execution_profile(_map), do: {:error, :invalid_execution_profile}

  defp credential_references(%ExecutionContext{target: %TargetContext{} = target}) do
    with {:ok, tracker_reference} <-
           tracker_secret_reference(target.tracker_connection),
         {:ok, runner_references} <- runner_secret_references(target.runner_policy) do
      {:ok,
       %{
         "tracker_api_key" => tracker_reference,
         "runner_server_auth_passwords" => runner_references
       }}
    end
  end

  defp credential_references(_context), do: {:error, :invalid_admission}

  defp tracker_secret_reference(%{
         "policy" => %{"api_key" => reference}
       })
       when is_binary(reference) do
    with false <- String.starts_with?(reference, "env:"),
         {:ok, _variable} <- reference_variable(reference) do
      {:ok, reference}
    else
      _invalid -> {:error, :invalid_tracker_secret_reference}
    end
  end

  defp tracker_secret_reference(_connection),
    do: {:error, :invalid_tracker_secret_reference}

  defp runner_secret_references(%{"runners" => runners}) when is_map(runners) do
    Enum.reduce_while(runners, {:ok, %{}}, fn {runner_name, runner}, {:ok, references} ->
      case runner_secret_reference(runner) do
        {:ok, nil} ->
          {:cont, {:ok, references}}

        {:ok, reference} ->
          {:cont, {:ok, Map.put(references, runner_name, reference)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp runner_secret_references(_policy),
    do: {:error, :invalid_runner_secret_reference}

  defp runner_secret_reference(%{"server_auth" => %{"password" => reference}})
       when is_binary(reference) do
    with true <- String.starts_with?(reference, "env:"),
         {:ok, _variable} <- reference_variable(reference) do
      {:ok, reference}
    else
      _invalid -> {:error, :invalid_runner_secret_reference}
    end
  end

  defp runner_secret_reference(%{"server_auth" => nil}), do: {:ok, nil}
  defp runner_secret_reference(%{"server_auth" => _invalid}), do: {:error, :invalid_runner_secret_reference}
  defp runner_secret_reference(runner) when is_map(runner), do: {:ok, nil}
  defp runner_secret_reference(_runner), do: {:error, :invalid_runner_secret_reference}

  defp credential_fetcher(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(opts, fn {key, _value} -> key == :env_fetcher end) and
         length(Keyword.get_values(opts, :env_fetcher)) <= 1 do
      case Keyword.get(opts, :env_fetcher, &System.fetch_env/1) do
        fetcher when is_function(fetcher, 1) -> {:ok, fetcher}
        _invalid -> {:error, :invalid_admission}
      end
    else
      {:error, :invalid_admission}
    end
  end

  defp resolve_context_credentials(context, fetcher) do
    with {:ok, references} <- credential_references(context),
         {:ok, values} <- resolve_reference_values(references, fetcher) do
      target = context.target

      tracker_reference = references["tracker_api_key"]

      tracker_connection =
        put_in(
          target.tracker_connection,
          ["policy", "api_key"],
          Map.fetch!(values, tracker_reference)
        )

      runners =
        resolve_runner_credentials(
          target.runner_policy["runners"],
          references["runner_server_auth_passwords"],
          values
        )

      runner_policy = put_in(target.runner_policy, ["runners"], runners)
      target = %{target | tracker_connection: tracker_connection, runner_policy: runner_policy}

      {:ok,
       %{
         context
         | target: target,
           runner_config: Map.fetch!(runners, context.runner_name)
       }}
    end
  end

  defp resolve_runner_credentials(runners, references, values) do
    Map.new(runners, fn {runner_name, runner} ->
      case Map.get(references, runner_name) do
        nil ->
          {runner_name, runner}

        reference ->
          {runner_name,
           put_in(
             runner,
             ["server_auth", "password"],
             Map.fetch!(values, reference)
           )}
      end
    end)
  end

  defp resolve_reference_values(references, fetcher) do
    references
    |> credential_reference_values()
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn reference, {:ok, values} ->
      with {:ok, variable} <- reference_variable(reference),
           {:ok, value} <- fetch_current_credential(fetcher, variable) do
        {:cont, {:ok, Map.put(values, reference, value)}}
      else
        {:blocked, _reason} = blocked -> {:halt, blocked}
        _invalid -> {:halt, {:blocked, :credential_resolution_failed}}
      end
    end)
  end

  defp credential_reference_values(%{
         "tracker_api_key" => tracker_reference,
         "runner_server_auth_passwords" => runner_references
       }) do
    [tracker_reference | Map.values(runner_references)]
  end

  defp fetch_current_credential(fetcher, variable) do
    case invoke_credential_fetcher(fetcher, variable) do
      {:ok, {:ok, value}} when is_binary(value) ->
        if value != "" and String.valid?(value),
          do: {:ok, value},
          else: {:blocked, :missing_credentials}

      {:ok, :error} ->
        {:blocked, :missing_credentials}

      _invalid ->
        {:blocked, :credential_resolution_failed}
    end
  end

  defp invoke_credential_fetcher(fetcher, variable) do
    {:ok, fetcher.(variable)}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp reference_variable("env:" <> variable) do
    if Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, variable),
      do: {:ok, variable},
      else: {:error, :invalid_secret_reference}
  end

  defp reference_variable(reference) do
    case Regex.run(~r/\A\$([A-Za-z0-9._-]+)\z/, reference, capture: :all_but_first) do
      [variable] ->
        {:ok, variable}

      _no_match ->
        case Regex.run(
               ~r/\A\$\{([A-Za-z0-9._-]+)\}\z/,
               reference,
               capture: :all_but_first
             ) do
          [variable] -> {:ok, variable}
          _invalid -> {:error, :invalid_secret_reference}
        end
    end
  end

  defp target_state("paused"), do: {:ok, :paused}
  defp target_state("active"), do: {:ok, :active}
  defp target_state("draining"), do: {:ok, :draining}
  defp target_state("retired"), do: {:ok, :retired}
  defp target_state(_state), do: {:error, :invalid_target_state}

  defp dispatch_mode("explicit"), do: {:ok, :explicit}
  defp dispatch_mode("watch"), do: {:ok, :watch}
  defp dispatch_mode(nil), do: {:ok, nil}
  defp dispatch_mode(_mode), do: {:error, :invalid_dispatch_mode}

  defp workspace_layout("flat"), do: {:ok, :flat}
  defp workspace_layout("target_scoped"), do: {:ok, :target_scoped}
  defp workspace_layout(_layout), do: {:error, :invalid_workspace_layout}

  defp execution_role("implementation"), do: {:ok, :implementation}
  defp execution_role("landing"), do: {:ok, :landing}
  defp execution_role("source_reviewer"), do: {:ok, :source_reviewer}
  defp execution_role("test_reviewer"), do: {:ok, :test_reviewer}
  defp execution_role("runtime_qa"), do: {:ok, :runtime_qa}
  defp execution_role("product_visual_review"), do: {:ok, :product_visual_review}
  defp execution_role("docs_reviewer"), do: {:ok, :docs_reviewer}
  defp execution_role("security_reviewer"), do: {:ok, :security_reviewer}
  defp execution_role(_role), do: {:error, :invalid_role}

  defp optional_atom_string(nil), do: nil
  defp optional_atom_string(value), do: Atom.to_string(value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
    end)
  end

  defp admitted_run_id do
    "run_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp decode_json(_value), do: {:error, :invalid_json}

  defp same_json?(left, right) do
    with {:ok, decoded_left} <- decode_json(left),
         {:ok, decoded_right} <- decode_json(right) do
      decoded_left === decoded_right
    else
      _invalid -> false
    end
  end

  defp expect_no_rows(connection, sql, params, database_path, message) do
    case domain_query(connection, sql, params, database_path, message) do
      {:ok, []} -> :ok
      {:ok, _rows} -> corrupt_store(database_path, :unexpected_sql_rows)
      {:error, _reason} = error -> error
    end
  end

  defp domain_query(connection, sql, params, database_path, message) do
    case query(connection, sql, params) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, error(:transaction_failed, database_path, message, reason)}
    end
  end

  defp corrupt_store(database_path, reason) do
    {:error,
     error(
       :corrupt_store,
       database_path,
       "control-plane durable state is invalid",
       reason
     )}
  end

  defp verify_single_value(connection, sql, expected, database_path, code, message) do
    case query(connection, sql) do
      {:ok, [[^expected]]} -> :ok
      {:ok, rows} -> {:error, error(code, database_path, message, rows)}
      {:error, reason} -> {:error, error(code, database_path, message, reason)}
    end
  end

  defp run_transaction(connection, database_path, operation) do
    with :ok <- execute(connection, "BEGIN IMMEDIATE", database_path, :transaction_failed) do
      transaction = %Transaction{owner: self(), ref: make_ref()}
      result = invoke_transaction(operation, transaction, database_path)
      finish_transaction(connection, database_path, result)
    end
  end

  defp invoke_transaction(operation, transaction, database_path) do
    operation.(transaction)
  rescue
    exception ->
      {:callback_error,
       error(
         :transaction_callback_failed,
         database_path,
         "control-plane transaction callback raised #{inspect(exception.__struct__)}",
         Exception.message(exception)
       )}
  catch
    kind, reason ->
      {:callback_error,
       error(
         :transaction_callback_failed,
         database_path,
         "control-plane transaction callback stopped with #{kind}",
         reason
       )}
  end

  defp finish_transaction(connection, database_path, {:ok, _value} = result) do
    case execute(connection, "COMMIT", database_path, :transaction_failed) do
      :ok ->
        result

      {:error, %Error{} = commit_error} ->
        _ = Sqlite3.execute(connection, "ROLLBACK")
        {:error, commit_error}
    end
  end

  defp finish_transaction(connection, _database_path, {:error, _reason} = result) do
    _ = Sqlite3.execute(connection, "ROLLBACK")
    result
  end

  defp finish_transaction(connection, _database_path, {:callback_error, %Error{} = callback_error}) do
    _ = Sqlite3.execute(connection, "ROLLBACK")
    {:error, callback_error}
  end

  defp finish_transaction(connection, database_path, result) do
    _ = Sqlite3.execute(connection, "ROLLBACK")

    {:error,
     error(
       :invalid_transaction_result,
       database_path,
       "control-plane transaction callback must return {:ok, value} or {:error, reason}",
       result
     )}
  end

  defp execute(connection, sql, database_path, code) do
    case Sqlite3.execute(connection, sql) do
      :ok -> :ok
      {:error, reason} -> {:error, error(code, database_path, sqlite_message(code), reason)}
    end
  end

  defp sqlite_result(:ok, _database_path, _code, _message), do: :ok

  defp sqlite_result({:error, reason}, database_path, code, message) do
    {:error, error(code, database_path, message, reason)}
  end

  defp query(connection, sql, params \\ []) do
    case Sqlite3.prepare(connection, sql) do
      {:ok, statement} ->
        try do
          with :ok <- Sqlite3.bind(statement, params) do
            collect_rows(connection, statement, [])
          end
        after
          _ = Sqlite3.release(connection, statement)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_rows(connection, statement, rows) do
    case Sqlite3.step(connection, statement) do
      {:row, row} -> collect_rows(connection, statement, [row | rows])
      :done -> {:ok, Enum.reverse(rows)}
      :busy -> {:error, :busy_timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  defp secure_database_files(database_path) do
    [database_path, database_path <> "-wal", database_path <> "-shm"]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case secure_database_file(path, database_path) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = store_error} -> {:halt, {:error, store_error}}
      end
    end)
  end

  defp secure_database_file(path, database_path) do
    basename = Path.basename(path)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        chmod(
          path,
          0o600,
          database_path,
          :unwritable_store,
          "cannot secure control-plane database file #{basename}"
        )

      {:ok, %File.Stat{type: type}} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "control-plane database file #{basename} is not regular",
           type
         )}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "cannot inspect control-plane database file #{basename}",
           reason
         )}
    end
  end

  defp sqlite_message(:migration_failed), do: "control-plane schema migration failed"
  defp sqlite_message(:transaction_failed), do: "control-plane transaction failed"
  defp sqlite_message(code), do: "control-plane SQLite operation failed during #{code}"

  defp error(code, database_path, message, reason) do
    %Error{
      code: code,
      path: database_path,
      message: "#{message} at #{database_path}: #{format_reason(reason)}",
      reason: reason
    }
  end

  defp format_reason(%{message: message}) when is_binary(message), do: message
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end

defimpl Inspect, for: SymphonyElixir.ControlPlane.Admission do
  import Inspect.Algebra

  @impl true
  def inspect(admission, opts) do
    safe =
      Map.take(admission, [
        :admitted_run_id,
        :target_id,
        :tracker_issue_id,
        :issue_identifier,
        :registry_generation,
        :policy_hash,
        :repo_manifest_hash,
        :admitted_at
      ])

    concat(["#SymphonyElixir.ControlPlane.Admission<", to_doc(safe, opts), ">"])
  end
end

defimpl Inspect, for: SymphonyElixir.ControlPlane.Recovery do
  import Inspect.Algebra

  @impl true
  def inspect(recovery, opts) do
    safe =
      Map.take(recovery, [
        :admission,
        :lifecycle,
        :lease,
        :action,
        :blocked_reason
      ])

    concat(["#SymphonyElixir.ControlPlane.Recovery<", to_doc(safe, opts), ">"])
  end
end
