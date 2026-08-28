defmodule SymphonyElixir.HostScheduler do
  @moduledoc """
  Registry-generation owner for target polling, weighted grants, and host slots.

  Poll grants are issued one at a time by weighted deficit round-robin. Every
  grant is fenced to one target process and one verified registry generation.
  Agent, startup, reviewer, poll, runner, and target ceilings are accounted in
  this process so overlapping release paths cannot return a slot twice.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.ControlPlane.TokenBudget
  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.HostScheduler.Policy
  alias SymphonyElixir.HostScheduler.Registry
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.RunAuthority
  alias SymphonyElixir.TargetContext
  alias SymphonyElixir.TargetSupervisor

  @default_max_credit_rounds 4
  @default_registry_reload_interval_ms 1_000

  defmodule Grant do
    @moduledoc false

    @enforce_keys [
      :id,
      :scheduler,
      :target_id,
      :target_pid,
      :registry_generation,
      :issued_at
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: pos_integer(),
            scheduler: GenServer.server(),
            target_id: String.t(),
            target_pid: pid(),
            registry_generation: String.t(),
            issued_at: DateTime.t()
          }
  end

  defmodule TargetState do
    @moduledoc false

    @enforce_keys [:context, :limits]
    defstruct [
      :context,
      :limits,
      :pid,
      :monitor,
      :next_poll_due_at_ms,
      activation_pending?: false,
      managed?: false,
      retry_requested?: false
    ]
  end

  defmodule State do
    @moduledoc false

    @enforce_keys [
      :name,
      :target_supervisor,
      :orchestrator_opts,
      :registry_loader,
      :registry_reload_interval_ms,
      :host_limits,
      :targets,
      :policy
    ]
    defstruct @enforce_keys ++
                [
                  :registry_path,
                  :registry_generation,
                  :registry_error,
                  :reload_timer_ref,
                  :reload_timer_token,
                  :poll_timer_ref,
                  :poll_timer_token,
                  :next_poll_due_at_ms,
                  registry_verified?: true,
                  next_grant_id: 1,
                  grants: %{},
                  reviewers: %{},
                  retired_targets: %{},
                  connection_backoffs: %{}
                ]

    @type t :: %__MODULE__{}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @spec register_target(GenServer.server(), TargetContext.t(), pid()) :: :ok
  def register_target(
        server,
        %TargetContext{target_id: target_id, registry_generation: registry_generation},
        target_pid
      )
      when is_binary(target_id) and is_binary(registry_generation) and is_pid(target_pid) do
    GenServer.cast(server, {:register_target, target_id, registry_generation, target_pid})
  end

  @spec request_poll(GenServer.server(), String.t()) :: %{queued: true, coalesced: boolean()}
  def request_poll(server, target_id) when is_binary(target_id) do
    GenServer.call(server, {:request_poll, target_id})
  end

  @spec request_retry(GenServer.server(), String.t()) :: %{queued: true, coalesced: boolean()}
  def request_retry(server, target_id) when is_binary(target_id) do
    GenServer.call(server, {:request_retry, target_id})
  end

  @spec activate_target(GenServer.server(), TargetContext.t(), boolean()) :: :ok
  def activate_target(server, %TargetContext{} = context, resume_pending?)
      when is_boolean(resume_pending?) do
    GenServer.cast(
      server,
      {:activate_target, context.target_id, context.registry_generation, resume_pending?}
    )
  end

  @spec reserve_dispatch(Grant.t()) :: :ok | {:error, :capacity | :stale_grant}
  def reserve_dispatch(%Grant{scheduler: scheduler} = grant) do
    GenServer.call(scheduler, {:reserve_dispatch, grant})
  end

  @spec confirm_budget(Grant.t(), RunAuthority.t()) ::
          :ok | {:error, :budget_reservation | :stale_grant}
  def confirm_budget(%Grant{scheduler: scheduler} = grant, %RunAuthority{} = authority) do
    case budget_proof(authority) do
      {:ok, proof} -> GenServer.call(scheduler, {:confirm_budget, grant, proof})
      {:error, _reason} -> {:error, :budget_reservation}
    end
  end

  @spec finish_poll(Grant.t(), boolean() | {:defer, pos_integer()}) :: :ok
  def finish_poll(%Grant{scheduler: scheduler} = grant, result)
      when is_boolean(result) or
             (is_tuple(result) and tuple_size(result) == 2 and elem(result, 0) == :defer and
                is_integer(elem(result, 1)) and elem(result, 1) > 0) do
    GenServer.call(scheduler, {:finish_poll, grant, result})
  end

  @spec release_dispatch(Grant.t()) :: :ok
  def release_dispatch(%Grant{scheduler: scheduler} = grant) do
    GenServer.call(scheduler, {:release_slots, grant, [:agent, :startup]})
  end

  @spec release_startup(Grant.t()) :: :ok
  def release_startup(%Grant{scheduler: scheduler} = grant) do
    GenServer.call(scheduler, {:release_slots, grant, [:startup]})
  end

  @spec release_all(Grant.t()) :: :ok
  def release_all(%Grant{scheduler: scheduler} = grant) do
    GenServer.call(scheduler, {:release_slots, grant, [:poll, :agent, :startup]})
  end

  @spec reserve_reviewer(GenServer.server(), String.t(), pid()) ::
          {:ok, reference()} | {:error, :capacity}
  def reserve_reviewer(server, target_id, owner) when is_binary(target_id) and is_pid(owner) do
    GenServer.call(server, {:reserve_reviewer, target_id, owner})
  end

  @spec release_reviewer(GenServer.server(), reference()) :: :ok
  def release_reviewer(server, reservation) when is_reference(reservation) do
    GenServer.call(server, {:release_reviewer, reservation})
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    registry_path = Keyword.get(opts, :registry_path)
    registry_loader = Keyword.get(opts, :registry_loader, &Registry.load/1)

    with {:ok, runtime} <- initial_runtime(registry_path, registry_loader, opts),
         {:ok, policy} <-
           Policy.new(
             runtime.weights,
             max_credit_rounds(runtime.host, opts)
           ) do
      state = %State{
        name: Keyword.fetch!(opts, :name),
        target_supervisor: Keyword.get(opts, :target_supervisor, TargetSupervisor),
        orchestrator_opts: Keyword.get(opts, :orchestrator_opts, []),
        registry_path: registry_path,
        registry_loader: registry_loader,
        registry_reload_interval_ms:
          positive_integer(
            Keyword.get(opts, :registry_reload_interval_ms),
            @default_registry_reload_interval_ms
          ),
        registry_generation: runtime.generation,
        host_limits: scheduler_limits(runtime.host, runtime.contexts, Keyword.get(opts, :limits, %{})),
        targets: target_states(runtime.contexts, runtime.host, Keyword.get(opts, :limits, %{})),
        policy: policy
      }

      {:ok, state, {:continue, :start_targets}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:start_targets, %State{} = state) do
    state = state |> start_targets() |> schedule_registry_reload() |> schedule_dispatch()
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:register_target, target_id, registry_generation, pid},
        %State{} = state
      ) do
    state =
      case Map.fetch(state.targets, target_id) do
        {:ok,
         %TargetState{
           context: %TargetContext{registry_generation: ^registry_generation}
         } = target} ->
          state
          |> replace_target_process(target_id, target, pid, false)
          |> schedule_dispatch()

        _missing_or_stale ->
          state
      end

    {:noreply, state}
  end

  def handle_cast(
        {:activate_target, target_id, registry_generation, resume_pending?},
        state
      ) do
    state =
      case Map.fetch(state.targets, target_id) do
        {:ok,
         %TargetState{
           context: %TargetContext{
             state: :active,
             registry_generation: ^registry_generation
           }
         } = target} ->
          target = %{
            target
            | activation_pending?: false,
              retry_requested?: target.retry_requested? or resume_pending?,
              next_poll_due_at_ms: monotonic_ms()
          }

          state |> put_target(target_id, target) |> schedule_dispatch()

        _inactive_or_stale ->
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_call({:request_poll, target_id}, _from, state) do
    {reply, state} = queue_target_poll(state, target_id, :poll)
    {:reply, reply, state}
  end

  def handle_call({:request_retry, target_id}, _from, state) do
    {reply, state} = queue_target_poll(state, target_id, :retry)
    {:reply, reply, state}
  end

  def handle_call({:reserve_dispatch, %Grant{} = grant}, _from, state) do
    case Map.get(state.grants, grant.id) do
      %{grant: ^grant, poll: true, dispatch_attempted: false} = entry ->
        reserve_dispatch_reply(state, grant, entry)

      _missing_or_used ->
        {:reply, {:error, :stale_grant}, state}
    end
  end

  def handle_call({:confirm_budget, %Grant{} = grant, proof}, _from, state) do
    case Map.get(state.grants, grant.id) do
      %{grant: ^grant, agent: true, startup: true, budget_confirmed: false} = entry ->
        confirm_budget_reply(state, grant, proof, entry)

      %{grant: ^grant, budget_confirmed: true} ->
        confirmed_budget_reply(state, grant)

      _missing_or_unreserved ->
        {:reply, {:error, :stale_grant}, state}
    end
  end

  def handle_call({:finish_poll, %Grant{} = grant, result}, _from, state) do
    state =
      state
      |> release_slots(grant, [:poll])
      |> schedule_target_after_poll(grant, result)
      |> schedule_dispatch()

    {:reply, :ok, state}
  end

  def handle_call({:release_slots, %Grant{} = grant, slots}, _from, state) do
    state = state |> release_slots(grant, slots) |> stop_idle_retired_targets() |> schedule_dispatch()
    {:reply, :ok, state}
  end

  def handle_call({:reserve_reviewer, target_id, owner}, _from, state) do
    if reviewer_capacity_available?(state, target_id) do
      reservation = make_ref()
      reviewer = %{target_id: target_id, owner: owner}
      {:reply, {:ok, reservation}, %{state | reviewers: Map.put(state.reviewers, reservation, reviewer)}}
    else
      {:reply, {:error, :capacity}, state}
    end
  end

  def handle_call({:release_reviewer, reservation}, _from, state) do
    state = %{state | reviewers: Map.delete(state.reviewers, reservation)} |> stop_idle_retired_targets()
    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       counts: slot_counts(state),
       limits: state.host_limits,
       grants: map_size(state.grants),
       next_poll_in_ms: next_poll_in_ms(state),
       policy: state.policy,
       registry: %{
         path: state.registry_path,
         generation: state.registry_generation,
         verified?: state.registry_verified?,
         error: state.registry_error
       },
       targets: target_snapshots(state)
     }, state}
  end

  defp queue_target_poll(state, target_id, purpose) do
    case Map.fetch(state.targets, target_id) do
      {:ok, %TargetState{} = target} ->
        queue_target_poll(state, target_id, target, purpose)

      :error ->
        {%{queued: true, coalesced: true}, state}
    end
  end

  defp queue_target_poll(state, target_id, target, :poll) do
    coalesced =
      not grantable_target?(state, target) or target_poll_in_progress?(state, target_id) or
        due_now?(target.next_poll_due_at_ms)

    state =
      if coalesced do
        state
      else
        state
        |> put_target(target_id, %{target | next_poll_due_at_ms: monotonic_ms()})
        |> schedule_dispatch()
      end

    {%{queued: true, coalesced: coalesced}, state}
  end

  defp queue_target_poll(state, target_id, target, :retry) do
    coalesced =
      target.retry_requested? or target_poll_in_progress?(state, target_id) or
        not retryable_target?(state, target)

    state =
      if retryable_target?(state, target) do
        state
        |> put_target(target_id, %{
          target
          | retry_requested?: true,
            next_poll_due_at_ms: monotonic_ms()
        })
        |> schedule_dispatch()
      else
        state
      end

    {%{queued: true, coalesced: coalesced}, state}
  end

  defp reserve_dispatch_reply(state, grant, entry) do
    if current_grant?(state, grant) and dispatch_capacity_available?(state, entry) do
      updated = %{entry | agent: true, startup: true, dispatch_attempted: true}
      {:reply, :ok, put_grant(state, grant.id, updated)}
    else
      reason = if current_grant?(state, grant), do: :capacity, else: :stale_grant
      {:reply, {:error, reason}, state}
    end
  end

  defp confirm_budget_reply(state, grant, proof, entry) do
    if current_grant?(state, grant) and valid_budget_proof?(proof, grant) do
      {:reply, :ok, put_grant(state, grant.id, %{entry | budget_confirmed: true})}
    else
      reason = if current_grant?(state, grant), do: :budget_reservation, else: :stale_grant
      {:reply, {:error, reason}, state}
    end
  end

  defp confirmed_budget_reply(state, grant) do
    if current_grant?(state, grant),
      do: {:reply, :ok, state},
      else: {:reply, {:error, :stale_grant}, state}
  end

  @impl true
  def handle_info({:poll_tick, token}, %State{poll_timer_token: token} = state) do
    state = %{state | poll_timer_ref: nil, poll_timer_token: nil, next_poll_due_at_ms: nil}
    {:noreply, state |> issue_available_poll_grants() |> schedule_dispatch()}
  end

  def handle_info({:poll_tick, _stale_token}, state), do: {:noreply, state}

  def handle_info({:registry_reload, token}, %State{reload_timer_token: token} = state) do
    state = %{state | reload_timer_ref: nil, reload_timer_token: nil}

    state =
      case load_registry(state) do
        {:ok, loaded} -> apply_loaded_registry(state, loaded)
        {:error, reason} -> %{state | registry_verified?: false, registry_error: reason}
      end

    {:noreply, state |> schedule_registry_reload() |> schedule_dispatch()}
  end

  def handle_info({:registry_reload, _stale_token}, state), do: {:noreply, state}

  def handle_info({:DOWN, reference, :process, pid, _reason}, %State{} = state) do
    state =
      cond do
        Map.has_key?(state.retired_targets, pid) ->
          clear_retired_process(state, pid, reference)

        target_id = current_target_for_monitor(state, reference, pid) ->
          clear_current_target_process(state, target_id, pid)

        true ->
          state
      end

    {:noreply, schedule_dispatch(state)}
  end

  defp initial_runtime(nil, _registry_loader, opts) do
    target_context = Keyword.get(opts, :target_context)
    contexts = if match?(%TargetContext{}, target_context), do: %{target_context.target_id => target_context}, else: %{}
    weight = Keyword.get(opts, :target_weight, 1)
    weights = Enum.map(contexts, fn {target_id, _context} -> {target_id, weight} end)

    {:ok, %{contexts: contexts, generation: target_generation(target_context), host: nil, weights: weights}}
  end

  defp initial_runtime(registry_path, registry_loader, _opts) when is_binary(registry_path) do
    case invoke_registry_loader(registry_loader, registry_path) do
      {:ok, %{snapshot: snapshot, contexts: contexts} = loaded} ->
        {:ok,
         %{
           contexts: contexts,
           generation: snapshot.generation,
           host: snapshot.host,
           weights: registry_weights(loaded)
         }}

      {:error, reason} ->
        {:error, {:registry_start_failed, reason}}

      other ->
        {:error, {:registry_start_failed, {:invalid_loader_result, other}}}
    end
  end

  defp initial_runtime(_registry_path, _registry_loader, _opts), do: {:error, :invalid_registry_path}

  defp invoke_registry_loader(loader, path) when is_function(loader, 1), do: loader.(path)
  defp invoke_registry_loader(_loader, _path), do: {:error, :invalid_registry_loader}

  defp load_registry(%State{registry_path: path, registry_loader: loader}) when is_binary(path),
    do: invoke_registry_loader(loader, path)

  defp load_registry(_state), do: {:error, :registry_not_configured}

  defp apply_loaded_registry(state, %{snapshot: snapshot, contexts: contexts} = loaded) do
    if snapshot.generation == state.registry_generation do
      %{state | registry_verified?: true, registry_error: nil}
    else
      case Policy.new(registry_weights(loaded), max_credit_rounds(snapshot.host, [])) do
        {:ok, policy} ->
          desired_targets = target_states(contexts, snapshot.host, %{})

          state
          |> Map.put(:registry_generation, snapshot.generation)
          |> Map.put(:registry_verified?, true)
          |> Map.put(:registry_error, nil)
          |> Map.put(:host_limits, scheduler_limits(snapshot.host, contexts, %{}))
          |> Map.put(:policy, policy)
          |> reconcile_loaded_targets(desired_targets)
          |> start_targets()
          |> stop_idle_retired_targets()

        {:error, reason} ->
          %{state | registry_verified?: false, registry_error: reason}
      end
    end
  end

  defp reconcile_loaded_targets(state, desired_targets) do
    {remaining, targets, grants, retired_targets} =
      Enum.reduce(
        state.targets,
        {desired_targets, %{}, state.grants, state.retired_targets},
        fn {target_id, current}, {remaining, targets, grants, retired_targets} ->
          case Map.pop(remaining, target_id) do
            {%TargetState{} = desired, remaining} ->
              target = retain_target_runtime(state, current, desired)
              notify_target_context(target, desired.context)

              {
                remaining,
                Map.put(targets, target_id, target),
                retire_target_grants(grants, current),
                retired_targets
              }

            {nil, remaining} ->
              {
                remaining,
                targets,
                retire_target_grants(grants, current),
                put_retired_target(retired_targets, current)
              }
          end
        end
      )

    targets = Map.merge(targets, remaining)

    cancel_poll_timer(%{
      state
      | targets: targets,
        grants: grants,
        retired_targets: retired_targets
    })
  end

  defp retain_target_runtime(state, current, desired) do
    activation_pending? =
      desired.context.state == :active and current.context.state != :active

    retry_requested? =
      current.retry_requested? and desired.context.state in [:active, :draining]

    next_poll_due_at_ms =
      cond do
        activation_pending? -> nil
        retry_requested? -> monotonic_ms()
        desired.context.state == :active -> initial_poll_due(state, desired.context)
        true -> nil
      end

    %{
      desired
      | pid: current.pid,
        monitor: current.monitor,
        activation_pending?: activation_pending?,
        managed?: current.managed?,
        retry_requested?: retry_requested?,
        next_poll_due_at_ms: next_poll_due_at_ms
    }
  end

  defp notify_target_context(%TargetState{pid: pid}, context) when is_pid(pid) do
    if Process.alive?(pid), do: Orchestrator.apply_target_context(pid, context)
    :ok
  end

  defp notify_target_context(_target, _context), do: :ok

  defp start_targets(%State{} = state) do
    Enum.reduce(Map.keys(state.targets) |> Enum.sort(), state, fn target_id, state ->
      case Map.fetch!(state.targets, target_id) do
        %TargetState{pid: pid} when is_pid(pid) ->
          state

        %TargetState{context: %TargetContext{state: target_state}} = target
        when target_state in [:active, :draining] ->
          start_target(state, target_id, target)

        _inactive ->
          state
      end
    end)
  end

  defp start_target(%State{target_supervisor: false} = state, _target_id, _target), do: state

  defp start_target(%State{} = state, target_id, %TargetState{} = target) do
    opts =
      state.orchestrator_opts
      |> Keyword.put(:target_context, target.context)
      |> Keyword.put(:host_scheduler, state.name)
      |> target_process_name(state, target_id, target.context.registry_generation)

    case TargetSupervisor.start_target(state.target_supervisor, opts) do
      {:ok, pid} ->
        replace_target_process(state, target_id, target, pid, true)

      {:error, {:already_started, pid}} ->
        replace_target_process(state, target_id, target, pid, true)

      {:error, reason} ->
        Logger.error("Target process start failed target_id=#{target_id}: #{inspect(reason)}")
        state
    end
  end

  defp target_process_name(opts, %State{registry_path: nil}, _target_id, _generation),
    do: opts

  defp target_process_name(opts, %State{} = state, target_id, generation) do
    Keyword.put(
      opts,
      :name,
      {:global, {SymphonyElixir.Orchestrator, state.name, target_id, generation}}
    )
  end

  defp replace_target_process(state, target_id, %TargetState{pid: pid} = target, pid, managed?)
       when is_pid(pid) do
    target = %{target | managed?: target.managed? or managed?}

    state
    |> put_target(target_id, target)
    |> ensure_target_poll_due(target_id)
  end

  defp replace_target_process(state, target_id, %TargetState{} = target, pid, managed?)
       when is_pid(pid) do
    state = clear_current_target_process(state, target_id, target.pid)
    monitor = Process.monitor(pid)

    updated = %{
      target
      | pid: pid,
        monitor: monitor,
        managed?: managed?,
        next_poll_due_at_ms: initial_poll_due(state, target.context)
    }

    put_target(state, target_id, updated)
  end

  defp ensure_target_poll_due(state, target_id) do
    case Map.fetch(state.targets, target_id) do
      {:ok,
       %TargetState{
         activation_pending?: false,
         next_poll_due_at_ms: nil
       } = target} ->
        put_target(state, target_id, %{target | next_poll_due_at_ms: initial_poll_due(state, target.context)})

      _already_due_or_pending ->
        state
    end
  end

  defp initial_poll_due(state, %TargetContext{state: :active}) do
    if state.registry_verified?, do: monotonic_ms(), else: nil
  end

  defp initial_poll_due(_state, _context), do: nil

  defp retire_target_grants(grants, target) do
    grants
    |> Map.new(fn {grant_id, entry} ->
      if entry.grant.target_pid == target.pid,
        do: {grant_id, %{entry | poll: false}},
        else: {grant_id, entry}
    end)
    |> Map.reject(fn {_grant_id, entry} -> not entry.agent and not entry.startup and not entry.poll end)
  end

  defp put_retired_target(retired, %TargetState{pid: pid} = target) when is_pid(pid) do
    Map.put(retired, pid, %{
      target_id: target.context.target_id,
      monitor: target.monitor,
      managed?: target.managed?
    })
  end

  defp put_retired_target(retired, _target), do: retired

  defp clear_current_target_process(state, _target_id, nil), do: state

  defp clear_current_target_process(state, target_id, pid) when is_pid(pid) do
    case Map.fetch(state.targets, target_id) do
      {:ok, %TargetState{pid: ^pid} = target} ->
        if is_reference(target.monitor), do: Process.demonitor(target.monitor, [:flush])

        state
        |> clear_process_resources(pid)
        |> put_target(target_id, %{
          target
          | pid: nil,
            monitor: nil,
            next_poll_due_at_ms: nil,
            managed?: false
        })

      _other ->
        state
    end
  end

  defp clear_retired_process(state, pid, reference) do
    case Map.get(state.retired_targets, pid) do
      %{monitor: ^reference} ->
        state
        |> clear_process_resources(pid)
        |> Map.update!(:retired_targets, &Map.delete(&1, pid))

      _other ->
        state
    end
  end

  defp clear_process_resources(state, pid) do
    grants = Map.reject(state.grants, fn {_id, entry} -> entry.grant.target_pid == pid end)
    reviewers = Map.reject(state.reviewers, fn {_reservation, reviewer} -> reviewer.owner == pid end)
    %{state | grants: grants, reviewers: reviewers}
  end

  defp current_target_for_monitor(state, reference, pid) do
    Enum.find_value(state.targets, fn {target_id, target} ->
      if target.monitor == reference and target.pid == pid, do: target_id, else: nil
    end)
  end

  defp issue_available_poll_grants(state) do
    if state.registry_verified? and slot_counts(state).polls < state.host_limits.polls.max_concurrent do
      now_ms = monotonic_ms()
      eligible = eligible_target_ids(state, now_ms)

      case Policy.next(state.policy, eligible) do
        {:grant, target_id, policy} ->
          state
          |> Map.put(:policy, policy)
          |> issue_poll_grant(target_id)
          |> issue_available_poll_grants()

        {:idle, policy} ->
          %{state | policy: policy}
      end
    else
      state
    end
  end

  defp issue_poll_grant(state, target_id) do
    target = Map.fetch!(state.targets, target_id)

    grant = %Grant{
      id: state.next_grant_id,
      scheduler: state.name,
      target_id: target_id,
      target_pid: target.pid,
      registry_generation: target.context.registry_generation,
      issued_at: DateTime.utc_now()
    }

    entry = %{
      grant: grant,
      poll: true,
      agent: false,
      startup: false,
      dispatch_attempted: false,
      budget_confirmed: false,
      runner_id: target_runner_id(target.context)
    }

    Orchestrator.dispatch_grant(target.pid, grant)

    state
    |> put_target(target_id, %{
      target
      | next_poll_due_at_ms: nil,
        retry_requested?: false
    })
    |> Map.put(:next_grant_id, state.next_grant_id + 1)
    |> Map.put(:grants, Map.put(state.grants, grant.id, entry))
  end

  defp eligible_target_ids(state, now_ms) do
    state.targets
    |> Enum.flat_map(fn {target_id, target} ->
      if dispatchable_target?(state, target) and due_at?(target.next_poll_due_at_ms, now_ms) and
           not target_poll_in_progress?(state, target_id) and
           not connection_backoff_active?(state, target.context, now_ms) do
        [target_id]
      else
        []
      end
    end)
    |> Enum.sort()
  end

  defp grantable_target?(
         state,
         %TargetState{activation_pending?: false, context: context, pid: pid}
       ) do
    current_target_process?(state, context, pid) and context.state == :active
  end

  defp grantable_target?(_state, _target), do: false

  defp dispatchable_target?(
         state,
         %TargetState{
           activation_pending?: false,
           context: context,
           pid: pid,
           retry_requested?: retry_requested?
         }
       ) do
    current_target_process?(state, context, pid) and
      (context.state == :active or (context.state == :draining and retry_requested?))
  end

  defp dispatchable_target?(_state, _target), do: false

  defp current_target_process?(state, context, pid) do
    state.registry_verified? and is_pid(pid) and Process.alive?(pid) and
      context.registry_generation == state.registry_generation
  end

  defp retryable_target?(
         state,
         %TargetState{context: %TargetContext{state: target_state} = context, pid: pid}
       )
       when target_state in [:active, :draining],
       do: current_target_process?(state, context, pid)

  defp retryable_target?(_state, _target), do: false

  defp target_poll_in_progress?(state, target_id) do
    Enum.any?(state.grants, fn {_id, entry} -> entry.poll and entry.grant.target_id == target_id end)
  end

  defp schedule_target_after_poll(state, grant, result) do
    case Map.fetch(state.targets, grant.target_id) do
      {:ok,
       %TargetState{
         pid: pid,
         context: %TargetContext{registry_generation: generation}
       } = target}
      when pid == grant.target_pid and generation == grant.registry_generation ->
        now_ms = monotonic_ms()

        {next_due, state} =
          case {target.context.state, result} do
            {:active, true} ->
              {now_ms + target.limits.poll_interval_ms, state}

            {:active, {:defer, delay_ms}} ->
              state = put_connection_backoff(state, target.context, now_ms + delay_ms)
              {now_ms + max(target.limits.poll_interval_ms, delay_ms), state}

            {_state, _result} when target.retry_requested? ->
              {now_ms, state}

            {_state, _result} ->
              {nil, state}
          end

        put_target(state, grant.target_id, %{target | next_poll_due_at_ms: next_due})

      _stale_target ->
        state
    end
  end

  defp schedule_dispatch(%State{} = state) do
    state = cancel_poll_timer(state)

    case next_dispatch_delay(state) do
      nil ->
        state

      delay_ms ->
        token = make_ref()
        timer_ref = Process.send_after(self(), {:poll_tick, token}, delay_ms)

        %{
          state
          | poll_timer_ref: timer_ref,
            poll_timer_token: token,
            next_poll_due_at_ms: monotonic_ms() + delay_ms
        }
    end
  end

  defp next_dispatch_delay(state) do
    if poll_capacity_available?(state) do
      now_ms = monotonic_ms()

      state.targets
      |> Enum.flat_map(&target_dispatch_delay(state, &1, now_ms))
      |> Enum.min(fn -> nil end)
    end
  end

  defp poll_capacity_available?(state),
    do: state.registry_verified? and slot_counts(state).polls < state.host_limits.polls.max_concurrent

  defp target_dispatch_delay(state, {target_id, target}, now_ms) do
    if dispatchable_target?(state, target) and not target_poll_in_progress?(state, target_id) and
         is_integer(target.next_poll_due_at_ms) do
      due_at = target_dispatch_due_at(state, target)
      [max(0, due_at - now_ms)]
    else
      []
    end
  end

  defp target_dispatch_due_at(state, target) do
    case connection_backoff_until(state, target.context) do
      nil -> target.next_poll_due_at_ms
      backoff_until -> max(target.next_poll_due_at_ms, backoff_until)
    end
  end

  defp cancel_poll_timer(%State{poll_timer_ref: timer_ref} = state) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    %{state | poll_timer_ref: nil, poll_timer_token: nil, next_poll_due_at_ms: nil}
  end

  defp cancel_poll_timer(state),
    do: %{state | poll_timer_ref: nil, poll_timer_token: nil, next_poll_due_at_ms: nil}

  defp schedule_registry_reload(%State{registry_path: path} = state) when is_binary(path) do
    if is_reference(state.reload_timer_ref), do: Process.cancel_timer(state.reload_timer_ref)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:registry_reload, token}, state.registry_reload_interval_ms)
    %{state | reload_timer_ref: timer_ref, reload_timer_token: token}
  end

  defp schedule_registry_reload(state), do: state

  defp release_slots(state, %Grant{} = grant, slots) do
    case Map.get(state.grants, grant.id) do
      %{grant: ^grant} = entry ->
        updated = Enum.reduce(slots, entry, &Map.put(&2, &1, false))
        put_grant(state, grant.id, updated)

      _missing ->
        state
    end
  end

  defp put_grant(state, grant_id, entry) do
    if entry.poll or entry.agent or entry.startup,
      do: %{state | grants: Map.put(state.grants, grant_id, entry)},
      else: %{state | grants: Map.delete(state.grants, grant_id)}
  end

  defp current_grant?(state, %Grant{} = grant) do
    state.registry_verified? and grant.registry_generation == state.registry_generation and
      case Map.get(state.targets, grant.target_id) do
        %TargetState{pid: pid, context: %TargetContext{registry_generation: generation}} ->
          pid == grant.target_pid and generation == grant.registry_generation

        _missing ->
          false
      end
  end

  defp dispatch_capacity_available?(state, entry) do
    target_id = entry.grant.target_id
    target = Map.get(state.targets, target_id)
    host_counts = slot_counts(state)
    target_counts = target_slot_counts(state, target_id)

    match?(%TargetState{}, target) and host_counts.agents < state.host_limits.agents and
      host_counts.startups < state.host_limits.startups and
      target_counts.agents < target.limits.agents and
      target_counts.startups < target.limits.startups and
      runner_capacity_available?(state, entry.runner_id)
  end

  defp reviewer_capacity_available?(state, target_id) do
    case Map.get(state.targets, target_id) do
      %TargetState{} = target ->
        (grantable_target?(state, target) or draining_target_busy?(state, target)) and
          slot_counts(state).reviewers < state.host_limits.reviewers and
          target_slot_counts(state, target_id).reviewers < target.limits.reviewers

      _missing ->
        false
    end
  end

  defp draining_target_busy?(
         state,
         %TargetState{
           pid: pid,
           context: %TargetContext{target_id: target_id, state: :draining}
         }
       ) do
    Enum.any?(state.grants, fn {_grant_id, entry} ->
      entry.agent and entry.grant.target_id == target_id and entry.grant.target_pid == pid
    end)
  end

  defp draining_target_busy?(_state, _target), do: false

  defp runner_capacity_available?(_state, nil), do: true

  defp runner_capacity_available?(state, runner_id) do
    case Map.get(state.host_limits.runners, runner_id) do
      %{agents: agent_limit, startups: startup_limit} ->
        counts = runner_slot_counts(state, runner_id)
        counts.agents < agent_limit and counts.startups < startup_limit

      _unconfigured ->
        true
    end
  end

  defp runner_slot_counts(state, runner_id) do
    Enum.reduce(state.grants, %{agents: 0, startups: 0}, fn {_id, entry}, counts ->
      if entry.runner_id == runner_id do
        %{
          agents: counts.agents + if(entry.agent, do: 1, else: 0),
          startups: counts.startups + if(entry.startup, do: 1, else: 0)
        }
      else
        counts
      end
    end)
  end

  defp slot_counts(state) do
    Enum.reduce(state.grants, %{agents: 0, startups: 0, reviewers: map_size(state.reviewers), polls: 0}, fn
      {_id, entry}, counts ->
        %{
          agents: counts.agents + if(entry.agent, do: 1, else: 0),
          startups: counts.startups + if(entry.startup, do: 1, else: 0),
          reviewers: counts.reviewers,
          polls: counts.polls + if(entry.poll, do: 1, else: 0)
        }
    end)
  end

  defp target_slot_counts(state, target_id) do
    grant_counts =
      Enum.reduce(state.grants, %{agents: 0, startups: 0, polls: 0}, fn {_id, entry}, counts ->
        if entry.grant.target_id == target_id do
          %{
            agents: counts.agents + if(entry.agent, do: 1, else: 0),
            startups: counts.startups + if(entry.startup, do: 1, else: 0),
            polls: counts.polls + if(entry.poll, do: 1, else: 0)
          }
        else
          counts
        end
      end)

    reviewers = Enum.count(state.reviewers, fn {_reservation, reviewer} -> reviewer.target_id == target_id end)
    Map.put(grant_counts, :reviewers, reviewers)
  end

  defp stop_idle_retired_targets(state) do
    Enum.reduce(state.retired_targets, state, &stop_idle_retired_target/2)
  end

  defp stop_idle_retired_target({pid, retired}, state) do
    if retired_process_busy?(state, pid) do
      state
    else
      terminate_retired_target(state, pid, retired)
    end
  end

  defp retired_process_busy?(state, pid) do
    Enum.any?(state.grants, fn {_id, entry} -> entry.grant.target_pid == pid end) or
      Enum.any?(state.reviewers, fn {_id, reviewer} -> reviewer.owner == pid end)
  end

  defp terminate_retired_target(state, pid, retired) do
    if retired.managed? and state.target_supervisor != false do
      _ = DynamicSupervisor.terminate_child(state.target_supervisor, pid)
    end

    if is_reference(retired.monitor), do: Process.demonitor(retired.monitor, [:flush])
    %{state | retired_targets: Map.delete(state.retired_targets, pid)}
  end

  defp put_connection_backoff(state, context, until_ms) do
    case tracker_connection_id(context) do
      nil -> state
      connection_id -> %{state | connection_backoffs: Map.put(state.connection_backoffs, connection_id, until_ms)}
    end
  end

  defp connection_backoff_active?(state, context, now_ms) do
    case connection_backoff_until(state, context) do
      until_ms when is_integer(until_ms) -> until_ms > now_ms
      nil -> false
    end
  end

  defp connection_backoff_until(state, context) do
    case tracker_connection_id(context) do
      nil -> nil
      connection_id -> Map.get(state.connection_backoffs, connection_id)
    end
  end

  defp tracker_connection_id(%TargetContext{tracker_connection: %{"id" => id}}) when is_binary(id), do: id
  defp tracker_connection_id(_context), do: nil

  defp scheduler_limits(host, contexts, configured) when is_map(configured) do
    host_capacity = if is_map(host), do: Map.get(host, "capacity", %{}), else: %{}
    host_polling = if is_map(host), do: Map.get(host, "polling", %{}), else: %{}
    fallback_context = contexts |> Map.values() |> List.first()
    fallback_limits = if match?(%TargetContext{}, fallback_context), do: fallback_context.capacity_limits, else: %{}
    fallback_agents = positive_integer(Map.get(fallback_limits, "max_concurrent_agents"), 1)
    fallback_startups = positive_integer(Map.get(fallback_limits, "max_concurrent_startups"), 1)

    agents =
      positive_integer(
        Map.get(configured, :agents),
        positive_integer(Map.get(host_capacity, "max_concurrent_agents"), fallback_agents)
      )

    startups =
      positive_integer(
        Map.get(configured, :startups),
        positive_integer(Map.get(host_capacity, "max_concurrent_startups"), fallback_startups)
      )

    %{
      agents: agents,
      startups: startups,
      reviewers:
        positive_integer(
          Map.get(configured, :reviewers),
          positive_integer(Map.get(host_capacity, "max_concurrent_reviewers"), agents)
        ),
      polls: %{
        max_concurrent:
          positive_integer(
            get_in(configured, [:polls, :max_concurrent]),
            positive_integer(Map.get(host_polling, "max_concurrent_target_polls"), 1)
          ),
        interval_ms:
          positive_integer(
            get_in(configured, [:polls, :interval_ms]),
            positive_integer(
              Map.get(host_polling, "interval_ms"),
              positive_integer(Map.get(fallback_limits, "poll_interval_ms"), 1_000)
            )
          )
      },
      runners: runner_limits(host)
    }
  end

  defp target_states(contexts, host, configured) do
    host_poll_interval = scheduler_limits(host, contexts, configured).polls.interval_ms

    Map.new(contexts, fn {target_id, context} ->
      limits = context.capacity_limits

      {target_id,
       %TargetState{
         context: context,
         limits: %{
           agents: positive_integer(Map.get(limits, "max_concurrent_agents"), 1),
           startups: positive_integer(Map.get(limits, "max_concurrent_startups"), 1),
           reviewers:
             positive_integer(
               Map.get(limits, "max_concurrent_reviewers"),
               positive_integer(Map.get(limits, "max_concurrent_agents"), 1)
             ),
           poll_interval_ms: positive_integer(Map.get(limits, "poll_interval_ms"), host_poll_interval)
         }
       }}
    end)
  end

  defp runner_limits(%{"runners" => runners}) when is_map(runners) do
    Map.new(runners, fn {runner_id, limits} ->
      {runner_id,
       %{
         agents: positive_integer(Map.get(limits, "max_concurrent_agents"), 1),
         startups: positive_integer(Map.get(limits, "max_concurrent_startups"), 1)
       }}
    end)
  end

  defp runner_limits(_host), do: %{}

  defp max_credit_rounds(%{"scheduling" => scheduling}, _opts) when is_map(scheduling),
    do: positive_integer(Map.get(scheduling, "max_credit_rounds"), @default_max_credit_rounds)

  defp max_credit_rounds(_host, opts),
    do: positive_integer(Keyword.get(opts, :max_credit_rounds), @default_max_credit_rounds)

  defp registry_weights(%{weights: weights}) when is_list(weights), do: weights

  defp registry_weights(%{snapshot: snapshot, contexts: contexts}) do
    contexts
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn target_id ->
      weight =
        snapshot.targets
        |> Map.fetch!(target_id)
        |> Map.get(:effective_policy, %{})
        |> get_in(["scheduling", "weight"])

      {target_id, positive_integer(weight, 1)}
    end)
  end

  defp target_runner_id(%TargetContext{runner_policy: %{"default" => runner_id}}) when is_binary(runner_id),
    do: runner_id

  defp target_runner_id(_context), do: nil

  defp target_generation(%TargetContext{registry_generation: generation}), do: generation
  defp target_generation(_context), do: nil

  defp budget_proof(
         %RunAuthority{
           admission: %{context: %ExecutionContext{target: %TargetContext{} = target}}
         } = authority
       ) do
    case RunAuthority.fetch_token_budget(authority) do
      {:ok, :unlimited} when target.budget_limits == %{} ->
        {:ok, %{target_id: target.target_id, generation: target.registry_generation, reserved?: true}}

      {:ok, %TokenBudget{target_id: target_id, state: :active, reserved_tokens: reserved_tokens}}
      when target_id == target.target_id and reserved_tokens > 0 ->
        {:ok, %{target_id: target.target_id, generation: target.registry_generation, reserved?: true}}

      _missing_or_invalid ->
        {:error, :budget_reservation}
    end
  end

  defp budget_proof(_authority), do: {:error, :budget_reservation}

  defp valid_budget_proof?(
         %{target_id: target_id, reserved?: true},
         %Grant{target_id: target_id}
       ),
       do: true

  defp valid_budget_proof?(_proof, _grant), do: false

  defp target_snapshots(state) do
    now_ms = monotonic_ms()

    Map.new(state.targets, fn {target_id, target} ->
      counts = target_slot_counts(state, target_id)
      backoff_until_ms = connection_backoff_until(state, target.context)

      {target_id,
       %{
         configured_state: target.context.state,
         effective_state: effective_target_state(state, target, now_ms),
         eligibility_reason: target_eligibility_reason(state, target_id, target, now_ms),
         generation: target.context.registry_generation,
         pid: target.pid,
         queue_count: target_queue_count(state, target_id, target),
         counts: counts,
         limits: target.limits,
         scheduling: %{
           weight: Map.fetch!(state.policy.weights, target_id),
           deficit: Map.fetch!(state.policy.credits, target_id)
         },
         budget_limits: budget_limits_snapshot(target.context.budget_limits),
         tracker_backoff: %{
           active: is_integer(backoff_until_ms) and backoff_until_ms > now_ms,
           remaining_ms: if(is_integer(backoff_until_ms), do: max(backoff_until_ms - now_ms, 0), else: nil)
         },
         next_poll_in_ms: due_in_ms(target.next_poll_due_at_ms)
       }}
    end)
  end

  defp effective_target_state(_state, %TargetState{context: %{state: state}}, _now_ms)
       when state in [:paused, :draining, :retired],
       do: state

  defp effective_target_state(_state, %TargetState{activation_pending?: true}, _now_ms),
    do: :activating

  defp effective_target_state(%State{registry_verified?: false}, _target, _now_ms),
    do: :unavailable

  defp effective_target_state(state, %TargetState{} = target, now_ms) do
    cond do
      not current_target_process?(state, target.context, target.pid) -> :unavailable
      connection_backoff_active?(state, target.context, now_ms) -> :limited
      true -> :active
    end
  end

  defp target_eligibility_reason(%State{registry_verified?: false}, _target_id, _target, _now_ms),
    do: :registry_unverified

  defp target_eligibility_reason(_state, _target_id, %TargetState{activation_pending?: true}, _now_ms),
    do: :activation_pending

  defp target_eligibility_reason(_state, _target_id, %TargetState{context: %{state: :paused}}, _now_ms),
    do: :target_paused

  defp target_eligibility_reason(_state, _target_id, %TargetState{context: %{state: :retired}}, _now_ms),
    do: :target_retired

  defp target_eligibility_reason(state, target_id, %TargetState{} = target, now_ms) do
    cond do
      not current_target_process?(state, target.context, target.pid) ->
        :target_process_unavailable

      target.context.state == :draining and not target.retry_requested? ->
        :target_draining

      connection_backoff_active?(state, target.context, now_ms) ->
        :tracker_backoff

      target_poll_in_progress?(state, target_id) ->
        :poll_in_progress

      slot_counts(state).polls >= state.host_limits.polls.max_concurrent ->
        :host_poll_capacity

      not due_at?(target.next_poll_due_at_ms, now_ms) ->
        :poll_not_due

      true ->
        :eligible
    end
  end

  defp target_queue_count(state, target_id, target) do
    in_progress = if target_poll_in_progress?(state, target_id), do: 1, else: 0
    queued = if is_integer(target.next_poll_due_at_ms) or target.retry_requested?, do: 1, else: 0
    in_progress + queued
  end

  defp budget_limits_snapshot(%{
         "per_run" => %{"max_total_tokens" => per_run},
         "daily" => %{"max_total_tokens" => daily},
         "weekly" => %{"max_total_tokens" => weekly}
       }),
       do: %{per_run_tokens: per_run, daily_tokens: daily, weekly_tokens: weekly}

  defp budget_limits_snapshot(_limits), do: nil

  defp put_target(state, target_id, target),
    do: %{state | targets: Map.put(state.targets, target_id, target)}

  defp due_now?(due_at) when is_integer(due_at), do: due_at <= monotonic_ms()
  defp due_now?(_due_at), do: false

  defp due_at?(due_at, now_ms) when is_integer(due_at), do: due_at <= now_ms
  defp due_at?(_due_at, _now_ms), do: false

  defp next_poll_in_ms(%State{next_poll_due_at_ms: due_at}), do: due_in_ms(due_at)

  defp due_in_ms(nil), do: nil
  defp due_in_ms(due_at) when is_integer(due_at), do: max(0, due_at - monotonic_ms())

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, fallback), do: fallback

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
