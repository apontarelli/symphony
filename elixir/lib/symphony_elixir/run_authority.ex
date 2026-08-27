defmodule SymphonyElixir.RunAuthority do
  @moduledoc """
  Owns the ordered durable-control-plane operations for one admitted run.

  The authority keeps the current lease and lifecycle together so orchestration
  code cannot mutate durable run state with a stale sequence or detached token.
  """

  alias SymphonyElixir.ControlPlane
  alias SymphonyElixir.ControlPlane.{Admission, Lease, Lifecycle, Recovery, SideEffect}
  alias SymphonyElixir.ExecutionContext

  @enforce_keys [:server, :owner_id, :admission, :lease, :lifecycle]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          server: GenServer.server(),
          owner_id: String.t(),
          admission: Admission.t(),
          lease: Lease.t(),
          lifecycle: Lifecycle.t()
        }

  @type recovered :: %{
          action: Recovery.action(),
          authority: t(),
          execution_context: ExecutionContext.t() | nil,
          blocked_reason: String.t() | nil
        }

  @spec admit(GenServer.server(), String.t(), ExecutionContext.t()) ::
          {:ok, t()} | {:error, term()}
  def admit(server, owner_id, %ExecutionContext{} = context) do
    with {:ok, admission} <- ControlPlane.admit_run(server, context),
         {:ok, lease} <- ControlPlane.acquire_lease(server, admission.admitted_run_id, owner_id),
         {:ok, lifecycle} <- ControlPlane.fetch_lifecycle(server, admission.admitted_run_id) do
      {:ok, new(server, owner_id, admission, lease, lifecycle)}
    end
  end

  @spec recover(GenServer.server(), String.t(), keyword()) ::
          {:ok, [recovered()]} | {:error, term()}
  def recover(server, owner_id, opts \\ []) do
    with {:ok, recoveries} <- ControlPlane.recover_runs(server, owner_id, opts) do
      {:ok, Enum.map(recoveries, &from_recovery(server, owner_id, &1))}
    end
  end

  @spec renew(t()) :: {:ok, t()} | {:error, term()}
  def renew(%__MODULE__{} = authority) do
    case ControlPlane.renew_lease(authority.server, authority.lease) do
      {:ok, lease} -> {:ok, %{authority | lease: lease}}
      {:error, _reason} = error -> error
    end
  end

  @spec transition(t(), Lifecycle.state(), map()) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{lifecycle: %Lifecycle{state: state}} = authority, state, _evidence),
    do: {:ok, authority}

  def transition(%__MODULE__{} = authority, next_state, evidence)
      when is_atom(next_state) and is_map(evidence) do
    lifecycle = authority.lifecycle

    case ControlPlane.transition_run(
           authority.server,
           authority.lease,
           lifecycle.sequence,
           lifecycle.state,
           next_state,
           evidence
         ) do
      {:ok, next_lifecycle} -> {:ok, %{authority | lifecycle: next_lifecycle}}
      {:error, _reason} = error -> error
    end
  end

  @spec register_process(t(), map()) :: {:ok, t()} | {:error, term()}
  def register_process(%__MODULE__{} = authority, identity) when is_map(identity) do
    case ControlPlane.register_process_group(authority.server, authority.lease, identity) do
      {:ok, _ownership} -> {:ok, authority}
      {:error, _reason} = error -> error
    end
  end

  @spec record_process_stopped(t(), pos_integer(), map()) :: {:ok, t()} | {:error, term()}
  def record_process_stopped(%__MODULE__{} = authority, process_group_id, evidence)
      when is_integer(process_group_id) and process_group_id > 0 and is_map(evidence) do
    case ControlPlane.record_process_group_termination(
           authority.server,
           authority.lease,
           process_group_id,
           {:stopped, evidence}
         ) do
      {:ok, _ownership} -> {:ok, authority}
      {:error, _reason} = error -> error
    end
  end

  @spec run_side_effect(
          t(),
          SideEffect.kind(),
          String.t(),
          map(),
          (-> {:ok, map()} | {:failed, map()} | {:ambiguous, map()})
        ) ::
          {:ok, map(), SideEffect.t()}
          | {:completed, SideEffect.t()}
          | {:failed, SideEffect.t()}
          | {:blocked, SideEffect.t()}
          | {:error, term()}
  def run_side_effect(%__MODULE__{} = authority, kind, idempotency_key, intent, operation)
      when is_atom(kind) and is_binary(idempotency_key) and is_map(intent) and
             is_function(operation, 0) do
    case ControlPlane.begin_side_effect(
           authority.server,
           authority.lease,
           kind,
           idempotency_key,
           intent
         ) do
      {:ok, _pending} ->
        finish_side_effect(authority, kind, idempotency_key, operation)

      {:completed, effect} ->
        {:completed, effect}

      {:failed, effect} ->
        {:failed, effect}

      {:blocked, effect} ->
        {:blocked, effect}

      {:error, _reason} = error ->
        error
    end
  end

  @spec release(t()) :: :ok | {:error, term()}
  def release(%__MODULE__{} = authority),
    do: ControlPlane.release_lease(authority.server, authority.lease)

  defp finish_side_effect(authority, kind, idempotency_key, operation) do
    outcome = invoke_side_effect(operation)

    case ControlPlane.finish_side_effect(
           authority.server,
           authority.lease,
           kind,
           idempotency_key,
           durable_outcome(outcome)
         ) do
      {:ok, effect} -> {:ok, side_effect_result(outcome), effect}
      {:failed, effect} -> {:failed, effect}
      {:blocked, effect} -> {:blocked, effect}
      {:error, _reason} = error -> error
    end
  end

  defp invoke_side_effect(operation) do
    case operation.() do
      {status, outcome} when status in [:ok, :failed, :ambiguous] and is_map(outcome) ->
        {status, outcome}

      other ->
        {:ambiguous, %{reason: "invalid_side_effect_result", result: inspect(other)}}
    end
  rescue
    error ->
      {:ambiguous,
       %{
         reason: "side_effect_raised",
         exception: inspect(error.__struct__),
         message: Exception.message(error)
       }}
  catch
    kind, reason ->
      {:ambiguous, %{reason: "side_effect_exited", exit_kind: inspect(kind), detail: inspect(reason)}}
  end

  defp durable_outcome({:ok, outcome}), do: {:succeeded, outcome}
  defp durable_outcome({:failed, outcome}), do: {:failed, outcome}
  defp durable_outcome({:ambiguous, outcome}), do: {:ambiguous, outcome}

  defp side_effect_result({_status, outcome}), do: outcome

  defp from_recovery(server, owner_id, %Recovery{} = recovery) do
    %{
      action: recovery.action,
      authority:
        new(
          server,
          owner_id,
          recovery.admission,
          recovery.lease,
          recovery.lifecycle
        ),
      execution_context: recovery.execution_context,
      blocked_reason: recovery.blocked_reason
    }
  end

  defp new(server, owner_id, admission, lease, lifecycle) do
    %__MODULE__{
      server: server,
      owner_id: owner_id,
      admission: admission,
      lease: lease,
      lifecycle: lifecycle
    }
  end
end
