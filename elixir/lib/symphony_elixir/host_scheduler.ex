defmodule SymphonyElixir.HostScheduler do
  @moduledoc """
  Host-owned poll timing, weighted scheduling, and slot accounting.

  A poll grant is current only while it remains in this process. A target must
  reserve the grant before one dispatch attempt. Release operations are
  idempotent, so overlapping worker-exit, cancellation, and lease-loss paths
  cannot return a slot twice.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.HostScheduler.Policy
  alias SymphonyElixir.{Orchestrator, TargetContext, TargetSupervisor}

  @default_max_credit_rounds 4

  defmodule Grant do
    @moduledoc false

    @enforce_keys [:id, :scheduler, :target_id, :target_pid, :issued_at]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: pos_integer(),
            scheduler: GenServer.server(),
            target_id: String.t(),
            target_pid: pid(),
            issued_at: DateTime.t()
          }
  end

  defmodule State do
    @moduledoc false

    @enforce_keys [
      :name,
      :target_supervisor,
      :orchestrator_opts,
      :target_context,
      :poll_interval_ms,
      :limits,
      :policy
    ]
    defstruct @enforce_keys ++
                [
                  :target_pid,
                  :target_monitor,
                  :timer_ref,
                  :timer_token,
                  :next_poll_due_at_ms,
                  next_grant_id: 1,
                  grants: %{},
                  reviewers: %{}
                ]

    @type t :: %__MODULE__{}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @spec register_target(GenServer.server(), String.t(), pid()) :: :ok
  def register_target(server, target_id, target_pid)
      when is_binary(target_id) and is_pid(target_pid) do
    GenServer.cast(server, {:register_target, target_id, target_pid})
  end

  @spec request_poll(GenServer.server(), String.t()) :: %{queued: true, coalesced: boolean()}
  def request_poll(server, target_id) when is_binary(target_id) do
    GenServer.call(server, {:request_poll, target_id})
  end

  @spec reserve_dispatch(Grant.t()) :: :ok | {:error, :capacity | :stale_grant}
  def reserve_dispatch(%Grant{scheduler: scheduler} = grant) do
    GenServer.call(scheduler, {:reserve_dispatch, grant})
  end

  @spec finish_poll(Grant.t(), boolean()) :: :ok
  def finish_poll(%Grant{scheduler: scheduler} = grant, continue?) when is_boolean(continue?) do
    GenServer.call(scheduler, {:finish_poll, grant, continue?})
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
    target_context = Keyword.get(opts, :target_context)
    limits = scheduler_limits(target_context, Keyword.get(opts, :limits, %{}))
    poll_interval_ms = limits.polls.interval_ms
    target_id = target_id(target_context)
    targets = if target_id, do: [{target_id, Keyword.get(opts, :target_weight, 1)}], else: []

    case Policy.new(
           targets,
           Keyword.get(opts, :max_credit_rounds, @default_max_credit_rounds)
         ) do
      {:ok, policy} ->
        state = %State{
          name: Keyword.fetch!(opts, :name),
          target_supervisor: Keyword.get(opts, :target_supervisor, TargetSupervisor),
          orchestrator_opts: Keyword.get(opts, :orchestrator_opts, []),
          target_context: target_context,
          poll_interval_ms: poll_interval_ms,
          limits: limits,
          policy: policy
        }

        {:ok, state, {:continue, :start_target}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:start_target, %State{target_context: nil} = state), do: {:noreply, state}

  def handle_continue(:start_target, %State{target_supervisor: false} = state),
    do: {:noreply, state}

  def handle_continue(:start_target, %State{} = state) do
    opts =
      state.orchestrator_opts
      |> Keyword.put(:target_context, state.target_context)
      |> Keyword.put(:host_scheduler, state.name)

    case TargetSupervisor.start_target(state.target_supervisor, opts) do
      {:ok, pid} -> {:noreply, register_target_process(state, pid)}
      {:error, {:already_started, pid}} -> {:noreply, register_target_process(state, pid)}
      {:error, reason} -> {:stop, {:target_start_failed, reason}, state}
    end
  end

  @impl true
  def handle_cast({:register_target, target_id, pid}, %State{} = state) do
    if target_id == target_id(state.target_context) do
      {:noreply, register_target_process(state, pid)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:request_poll, target_id}, _from, state) do
    matches? = target_id == target_id(state.target_context)
    coalesced = not matches? or poll_in_progress?(state) or poll_due?(state)
    state = if matches? and not coalesced, do: schedule_poll(state, 0), else: state
    {:reply, %{queued: true, coalesced: coalesced}, state}
  end

  def handle_call({:reserve_dispatch, %Grant{} = grant}, _from, state) do
    case Map.get(state.grants, grant.id) do
      %{grant: ^grant, poll: true, dispatch_attempted: false} = entry ->
        if dispatch_capacity_available?(state) do
          updated = %{entry | agent: true, startup: true, dispatch_attempted: true}
          {:reply, :ok, put_grant(state, grant.id, updated)}
        else
          {:reply, {:error, :capacity}, state}
        end

      _missing_or_used ->
        {:reply, {:error, :stale_grant}, state}
    end
  end

  def handle_call({:finish_poll, %Grant{} = grant, continue?}, _from, state) do
    state = release_slots(state, grant, [:poll])
    state = if continue?, do: schedule_poll(state, state.poll_interval_ms), else: cancel_poll(state)
    {:reply, :ok, state}
  end

  def handle_call({:release_slots, %Grant{} = grant, slots}, _from, state) do
    {:reply, :ok, release_slots(state, grant, slots)}
  end

  def handle_call({:reserve_reviewer, target_id, owner}, _from, state) do
    if target_id == target_id(state.target_context) and map_size(state.reviewers) < state.limits.reviewers do
      reservation = make_ref()
      {:reply, {:ok, reservation}, %{state | reviewers: Map.put(state.reviewers, reservation, owner)}}
    else
      {:reply, {:error, :capacity}, state}
    end
  end

  def handle_call({:release_reviewer, reservation}, _from, state) do
    {:reply, :ok, %{state | reviewers: Map.delete(state.reviewers, reservation)}}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       counts: slot_counts(state),
       limits: state.limits,
       grants: map_size(state.grants),
       next_poll_in_ms: next_poll_in_ms(state),
       policy: state.policy
     }, state}
  end

  @impl true
  def handle_info({:poll_tick, token}, %State{timer_token: token} = state) do
    state = %{state | timer_ref: nil, timer_token: nil, next_poll_due_at_ms: nil}

    case issue_poll_grant(state) do
      {:ok, state} -> {:noreply, state}
      {:idle, state} -> {:noreply, schedule_poll(state, state.poll_interval_ms)}
    end
  end

  def handle_info({:poll_tick, _stale_token}, state), do: {:noreply, state}

  def handle_info({:DOWN, reference, :process, pid, _reason}, %State{} = state) do
    if reference == state.target_monitor and pid == state.target_pid,
      do: {:noreply, clear_target_process(state)},
      else: {:noreply, state}
  end

  defp register_target_process(%State{target_pid: pid} = state, pid) when is_pid(pid) do
    if is_reference(state.timer_ref), do: state, else: schedule_poll(state, 0)
  end

  defp register_target_process(%State{} = state, pid) when is_pid(pid) do
    state = clear_target_process(state)
    monitor = Process.monitor(pid)

    state
    |> Map.put(:target_pid, pid)
    |> Map.put(:target_monitor, monitor)
    |> schedule_poll(0)
  end

  defp clear_target_process(%State{target_pid: pid} = state) when is_pid(pid) do
    if is_reference(state.target_monitor), do: Process.demonitor(state.target_monitor, [:flush])
    grants = Map.reject(state.grants, fn {_id, entry} -> entry.grant.target_pid == pid end)
    reviewers = Map.reject(state.reviewers, fn {_reservation, owner} -> owner == pid end)

    %{state | target_pid: nil, target_monitor: nil, grants: grants, reviewers: reviewers}
    |> cancel_poll()
  end

  defp clear_target_process(state), do: state

  defp issue_poll_grant(%State{target_pid: pid} = state) when is_pid(pid) do
    target_id = target_id(state.target_context)

    if slot_counts(state).polls < state.limits.polls.max_concurrent do
      case Policy.next(state.policy, [target_id]) do
        {:grant, ^target_id, policy} ->
          grant = %Grant{
            id: state.next_grant_id,
            scheduler: state.name,
            target_id: target_id,
            target_pid: pid,
            issued_at: DateTime.utc_now()
          }

          entry = %{grant: grant, poll: true, agent: false, startup: false, dispatch_attempted: false}
          Orchestrator.dispatch_grant(pid, grant)

          {:ok,
           %{
             state
             | policy: policy,
               next_grant_id: state.next_grant_id + 1,
               grants: Map.put(state.grants, grant.id, entry)
           }}

        {:idle, policy} ->
          {:idle, %{state | policy: policy}}
      end
    else
      {:idle, state}
    end
  end

  defp issue_poll_grant(state), do: {:idle, state}

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

  defp dispatch_capacity_available?(state) do
    counts = slot_counts(state)
    counts.agents < state.limits.agents and counts.startups < state.limits.startups
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

  defp scheduler_limits(target_context, configured) when is_map(configured) do
    target_limits = if match?(%TargetContext{}, target_context), do: target_context.capacity_limits, else: %{}
    agents = positive_limit(configured, :agents, target_limits, "max_concurrent_agents", 1)
    startups = positive_limit(configured, :startups, target_limits, "max_concurrent_startups", 1)

    %{
      agents: agents,
      startups: startups,
      reviewers: positive_integer(Map.get(configured, :reviewers), agents),
      polls: %{
        max_concurrent: positive_integer(get_in(configured, [:polls, :max_concurrent]), 1),
        interval_ms:
          positive_integer(
            get_in(configured, [:polls, :interval_ms]),
            positive_integer(Map.get(target_limits, "poll_interval_ms"), 1_000)
          )
      }
    }
  end

  defp positive_limit(configured, configured_key, target_limits, target_key, fallback) do
    positive_integer(Map.get(configured, configured_key), positive_integer(Map.get(target_limits, target_key), fallback))
  end

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, fallback), do: fallback

  defp target_id(%TargetContext{target_id: target_id}), do: target_id
  defp target_id(_target_context), do: nil

  defp schedule_poll(%State{target_pid: pid} = state, delay_ms)
       when is_pid(pid) and is_integer(delay_ms) and delay_ms >= 0 do
    state = cancel_poll(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:poll_tick, token}, delay_ms)

    %{
      state
      | timer_ref: timer_ref,
        timer_token: token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll(state, _delay_ms), do: state

  defp cancel_poll(%State{timer_ref: timer_ref} = state) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    %{state | timer_ref: nil, timer_token: nil, next_poll_due_at_ms: nil}
  end

  defp cancel_poll(state), do: %{state | timer_ref: nil, timer_token: nil, next_poll_due_at_ms: nil}

  defp poll_in_progress?(state), do: slot_counts(state).polls > 0

  defp poll_due?(%State{next_poll_due_at_ms: due_at}) when is_integer(due_at),
    do: due_at <= System.monotonic_time(:millisecond)

  defp poll_due?(_state), do: false

  defp next_poll_in_ms(%State{next_poll_due_at_ms: nil}), do: nil

  defp next_poll_in_ms(%State{next_poll_due_at_ms: due_at}),
    do: max(0, due_at - System.monotonic_time(:millisecond))
end
