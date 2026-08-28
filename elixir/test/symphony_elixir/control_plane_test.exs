defmodule SymphonyElixir.ControlPlaneTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Exqlite.Sqlite3
  alias SymphonyElixir.ControlPlane

  alias SymphonyElixir.ControlPlane.{
    Error,
    Lease,
    Lifecycle,
    LifecycleTransition,
    ProcessOwnership,
    Recovery,
    SideEffect,
    TokenBudget
  }

  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TargetContext

  test "first start atomically creates a healthy owner-only store" do
    config_root = tmp_root!("control-plane-first-start")
    File.rm_rf!(config_root)

    server = start_control_plane!(config_root)
    database_path = ControlPlane.path(config_root: config_root)

    assert {:ok,
            %{
              path: ^database_path,
              schema_version: 6,
              status: :healthy
            }} = ControlPlane.health(server)

    assert permissions(config_root) == 0o700
    assert permissions(database_path) == 0o600

    for suffix <- ["-wal", "-shm"], File.exists?(database_path <> suffix) do
      assert permissions(database_path <> suffix) == 0o600
    end
  end

  test "concurrent first starts share one migrated schema" do
    config_root = tmp_root!("control-plane-concurrent-start")
    File.rm_rf!(config_root)
    parent = self()

    launch = fn index ->
      name = {:global, {__MODULE__, make_ref(), index}}

      result = ControlPlane.start_link(config_root: config_root, name: name, busy_timeout: 2_000)

      case result do
        {:ok, pid} ->
          Process.unlink(pid)
          send(parent, {:started, pid})
          {:ok, pid}

        error ->
          error
      end
    end

    tasks = Enum.map(1..2, &Task.async(fn -> launch.(&1) end))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    pids =
      Enum.map(results, fn
        {:ok, pid} -> pid
        error -> flunk("concurrent control-plane start failed: #{inspect(error)}")
      end)

    on_exit(fn -> Enum.each(pids, &stop_process/1) end)

    assert Enum.all?(pids, fn pid -> match?({:ok, %{schema_version: 6}}, ControlPlane.health(pid)) end)
  end

  test "busy handling is bounded across local processes" do
    config_root = tmp_root!("control-plane-busy")
    first = start_control_plane!(config_root, busy_timeout: 100)
    second = start_control_plane!(config_root, busy_timeout: 100)
    parent = self()

    holder =
      Task.async(fn ->
        ControlPlane.transaction(first, fn _transaction ->
          send(parent, {:write_lock_held, self()})

          receive do
            :release_write_lock -> {:ok, :released}
          after
            2_000 -> {:error, :release_timeout}
          end
        end)
      end)

    assert_receive {:write_lock_held, lock_owner}, 1_000
    started_at = System.monotonic_time(:millisecond)

    assert {:error, %Error{code: :transaction_failed, message: message}} =
             ControlPlane.transaction(second, fn _transaction -> {:ok, :unreachable} end)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert message =~ "control-plane transaction failed"
    assert elapsed_ms < 1_000

    send(lock_owner, :release_write_lock)
    assert {:ok, :released} = Task.await(holder, 1_000)
  end

  test "transaction callbacks commit domain results and roll back domain errors" do
    server = start_control_plane!(tmp_root!("control-plane-transactions"))

    assert {:ok, :committed} =
             ControlPlane.transaction(server, fn %ControlPlane.Transaction{} ->
               {:ok, :committed}
             end)

    assert {:error, :rejected} =
             ControlPlane.transaction(server, fn %ControlPlane.Transaction{} ->
               {:error, :rejected}
             end)

    assert {:error, %Error{code: :invalid_transaction_result}} =
             ControlPlane.transaction(server, fn %ControlPlane.Transaction{} -> :invalid end)

    assert {:ok, %{status: :healthy}} = ControlPlane.health(server)
  end

  test "admission is atomic, idempotent, recoverable, and credential-safe" do
    config_root = tmp_root!("control-plane-admission")
    server = start_control_plane!(config_root)
    database_path = ControlPlane.path(config_root: config_root)

    context =
      execution_context!(config_root, "alpha", "shared-issue-id", "SID-427", runner_password: "env:RUNNER_PASSWORD")

    assert {:ok, first} = ControlPlane.admit_run(server, context)
    assert {:ok, repeated} = ControlPlane.admit_run(server, context)
    assert repeated.admitted_run_id == first.admitted_run_id
    assert repeated.context == context

    assert {:ok, fetched} =
             ControlPlane.fetch_admission(server, "alpha", "shared-issue-id")

    assert fetched.admitted_run_id == first.admitted_run_id
    assert fetched.context == context
    assert inspect(fetched) =~ first.admitted_run_id
    refute inspect(fetched) =~ "TRACKER_KEY"
    refute inspect(fetched) =~ "RUNNER_PASSWORD"

    assert {:blocked, :missing_credentials} =
             ControlPlane.resolve_admission_credentials(fetched,
               env_fetcher: fn _variable -> :error end
             )

    tracker_credential = "resolved-tracker-credential"
    runner_credential = "resolved-runner-credential"

    assert {:ok, resolved} =
             ControlPlane.resolve_admission_credentials(fetched,
               env_fetcher: fn
                 "TRACKER_KEY" -> {:ok, tracker_credential}
                 "RUNNER_PASSWORD" -> {:ok, runner_credential}
               end
             )

    assert get_in(resolved.target.tracker_connection, ["policy", "api_key"]) ==
             tracker_credential

    assert get_in(resolved.runner_config, ["server_auth", "password"]) ==
             runner_credential

    refute database_bytes(database_path) =~ tracker_credential
    refute database_bytes(database_path) =~ runner_credential
  end

  test "concurrent admissions cannot exceed daily or weekly token balances" do
    config_root = tmp_root!("control-plane-token-capacity")
    now_ms = unix_ms!("2026-08-27T12:00:00Z")
    {clock_state, clock} = test_clock!(now_ms)
    first = start_control_plane!(config_root, clock: clock, busy_timeout: 2_000)
    second = start_control_plane!(config_root, clock: clock, busy_timeout: 2_000)
    limits = token_limits(75, 100, 100)

    contexts = [
      execution_context!(config_root, "alpha", "issue-1", "SID-440-A", budget_limits: limits),
      execution_context!(config_root, "alpha", "issue-2", "SID-440-B", budget_limits: limits)
    ]

    results =
      [first, second]
      |> Enum.zip(contexts)
      |> Enum.map(fn {server, context} ->
        Task.async(fn -> ControlPlane.admit_run(server, context) end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, _admission}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :daily_token_budget_exceeded})) == 1

    [{:ok, admission}] = Enum.filter(results, &match?({:ok, _admission}, &1))

    assert {:ok,
            %TokenBudget{
              admission_day: "2026-08-27",
              admission_week: "2026-08-24",
              reserved_tokens: 75,
              charged_tokens: 0,
              daily_available_tokens: 25,
              weekly_available_tokens: 25
            }} = ControlPlane.fetch_token_budget(first, admission.admitted_run_id)

    set_clock!(clock_state, unix_ms!("2026-08-28T12:00:00Z"))

    next_day =
      execution_context!(config_root, "alpha", "issue-3", "SID-440-C", budget_limits: limits)

    assert {:error, :weekly_token_budget_exceeded} =
             ControlPlane.admit_run(first, next_day)
  end

  test "cumulative usage and reservation release require the current durable fence" do
    config_root = tmp_root!("control-plane-token-fencing")
    {_clock_state, clock} = test_clock!(unix_ms!("2026-08-27T13:00:00Z"))
    server = start_control_plane!(config_root, clock: clock)
    database_path = ControlPlane.path(config_root: config_root)
    secret = "hostile-runtime-secret-value"

    context =
      execution_context!(config_root, "alpha", "issue-1", "SID-440", budget_limits: token_limits(100, 500, 1_000))

    assert {:ok, admission} = ControlPlane.admit_run(server, context)

    assert {:ok, first_lease} =
             ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-first")

    assert {:ok, %Lifecycle{state: :running, sequence: 2}} =
             ControlPlane.transition_run(
               server,
               first_lease,
               1,
               :admitted,
               :running,
               %{}
             )

    for cumulative <- [40, 40, 20] do
      assert {:ok, %TokenBudget{cumulative_tokens: 40, charged_tokens: 40}} =
               ControlPlane.record_token_usage(server, first_lease, cumulative)
    end

    assert {:error, :invalid_token_usage} =
             ControlPlane.record_token_usage(server, first_lease, %{"secret" => secret})

    assert {:ok, current_lease} =
             ControlPlane.transfer_lease(server, first_lease, "owner-current")

    assert {:error, :stale_lease} =
             ControlPlane.record_token_usage(server, first_lease, 60)

    assert {:error, :stale_lease} =
             ControlPlane.release_token_reservation(server, first_lease)

    assert {:error, :process_termination_unverified} =
             ControlPlane.release_token_reservation(server, current_lease)

    identity = process_identity(44_001)

    assert {:ok, %ProcessOwnership{state: :running}} =
             ControlPlane.register_process_group(server, current_lease, identity)

    assert {:error, :process_termination_unverified} =
             ControlPlane.release_token_reservation(server, current_lease)

    assert {:ok, %ProcessOwnership{state: :stopped}} =
             ControlPlane.record_process_group_termination(
               server,
               current_lease,
               44_001,
               {:stopped, %{verified_by: "budget-test"}}
             )

    assert {:ok, %Lifecycle{state: :blocked, sequence: 3}} =
             ControlPlane.transition_run(
               server,
               current_lease,
               2,
               :running,
               :blocked,
               %{reason: "target paused"}
             )

    assert {:ok,
            %TokenBudget{
              state: :released,
              charged_tokens: 40,
              reserved_tokens: 0,
              daily_available_tokens: 460
            }} = ControlPlane.release_token_reservation(server, current_lease)

    assert {:ok, %Lifecycle{state: :running, sequence: 4}} =
             ControlPlane.transition_run(
               server,
               current_lease,
               3,
               :blocked,
               :running,
               %{}
             )

    assert {:ok, %TokenBudget{state: :active, reserved_tokens: 60}} =
             ControlPlane.acquire_token_reservation(server, current_lease)

    assert {:ok, %Lifecycle{state: :completed}} =
             ControlPlane.transition_run(
               server,
               current_lease,
               4,
               :running,
               :completed,
               %{disposition: :succeeded}
             )

    assert {:ok,
            %TokenBudget{
              state: :terminal,
              cumulative_tokens: 40,
              charged_tokens: 40,
              reserved_tokens: 0
            }} = ControlPlane.fetch_token_budget(server, admission.admitted_run_id)

    refute database_bytes(database_path) =~ secret
  end

  test "an over-limit report charges the full reservation before rejection" do
    config_root = tmp_root!("control-plane-token-exhaustion")
    server = start_control_plane!(config_root)

    context =
      execution_context!(config_root, "alpha", "issue-exhaustion", "SID-440-LIMIT", budget_limits: token_limits(100, 500, 1_000))

    assert {:ok, admission} = ControlPlane.admit_run(server, context)

    assert {:ok, lease} =
             ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-limit")

    assert {:error, :token_budget_exhausted} =
             ControlPlane.record_token_usage(server, lease, 101)

    assert {:ok,
            %TokenBudget{
              state: :active,
              cumulative_tokens: 100,
              charged_tokens: 100,
              reserved_tokens: 0
            }} = ControlPlane.fetch_token_budget(server, admission.admitted_run_id)
  end

  test "restart retains active balances and UTC admission periods across a boundary" do
    config_root = tmp_root!("control-plane-token-restart")
    sunday_ms = unix_ms!("2026-08-30T23:59:59.900Z")
    monday_ms = unix_ms!("2026-08-31T00:00:00.000Z")
    {clock_state, clock} = test_clock!(sunday_ms)
    server = start_control_plane!(config_root, clock: clock)
    limits = token_limits(100, 100, 100)

    first_context =
      execution_context!(config_root, "alpha", "issue-sunday", "SID-440-S", budget_limits: limits)

    assert {:ok, first_admission} = ControlPlane.admit_run(server, first_context)

    assert {:ok, first_lease} =
             ControlPlane.acquire_lease(server, first_admission.admitted_run_id, "owner-sunday")

    assert {:ok, %TokenBudget{charged_tokens: 30, reserved_tokens: 70}} =
             ControlPlane.record_token_usage(server, first_lease, 30)

    stop_process(server)
    set_clock!(clock_state, monday_ms)
    reopened = start_control_plane!(config_root, clock: clock)

    assert {:ok,
            %TokenBudget{
              admission_day: "2026-08-30",
              admission_week: "2026-08-24",
              charged_tokens: 30,
              reserved_tokens: 70,
              daily_available_tokens: 0,
              weekly_available_tokens: 0
            }} = ControlPlane.fetch_token_budget(reopened, first_admission.admitted_run_id)

    monday_context =
      execution_context!(config_root, "alpha", "issue-monday", "SID-440-M", budget_limits: limits)

    assert {:ok, monday_admission} = ControlPlane.admit_run(reopened, monday_context)

    assert {:ok,
            %TokenBudget{
              admission_day: "2026-08-31",
              admission_week: "2026-08-31",
              reserved_tokens: 100
            }} = ControlPlane.fetch_token_budget(reopened, monday_admission.admitted_run_id)

    stop_process(reopened)
    restored_root = tmp_root!("control-plane-token-restored")
    restored_path = ControlPlane.path(config_root: restored_root)
    File.mkdir_p!(restored_root)
    File.cp!(ControlPlane.path(config_root: config_root), restored_path)
    File.chmod!(restored_path, 0o600)
    restored = start_control_plane!(restored_root, clock: clock)

    assert {:ok, %TokenBudget{charged_tokens: 30, reserved_tokens: 70}} =
             ControlPlane.fetch_token_budget(restored, first_admission.admitted_run_id)
  end

  test "corrupt token balances stop reopen fail closed" do
    config_root = tmp_root!("control-plane-token-corruption")
    server = start_control_plane!(config_root)
    database_path = ControlPlane.path(config_root: config_root)

    context =
      execution_context!(config_root, "alpha", "issue-1", "SID-440", budget_limits: token_limits(100, 100, 100))

    assert {:ok, _admission} = ControlPlane.admit_run(server, context)
    stop_process(server)

    execute_sql!(
      database_path,
      """
      PRAGMA ignore_check_constraints = ON;
      UPDATE run_token_budgets SET reserved_tokens = 101;
      """
    )

    assert {:error, %Error{code: :corrupt_store, reason: reason}} =
             start_unlinked(config_root: config_root, name: unique_name())

    refute is_nil(reason)
  end

  test "conflicting generations, hashes, and target envelopes cannot replace an admission" do
    config_root = tmp_root!("control-plane-admission-conflict")
    server = start_control_plane!(config_root)
    database_path = ControlPlane.path(config_root: config_root)

    original =
      execution_context!(config_root, "alpha", "issue-1", "SID-427",
        generation: hash("generation-1"),
        policy_hash: hash("policy-1")
      )

    original = %{original | policy: Map.put(original.policy, "priority", 1)}
    changed_numeric_policy = %{original | policy: Map.put(original.policy, "priority", 1.0)}

    changed_generation =
      execution_context!(config_root, "alpha", "issue-1", "SID-427",
        generation: hash("generation-2"),
        policy_hash: hash("policy-2")
      )

    changed_policy =
      execution_context!(config_root, "alpha", "issue-1", "SID-427",
        generation: hash("generation-1"),
        policy_hash: hash("policy-2")
      )

    changed_checks =
      execution_context!(config_root, "alpha", "issue-1", "SID-427",
        generation: hash("generation-1"),
        policy_hash: hash("policy-1"),
        check: "mix test changed"
      )

    assert {:ok, admission} = ControlPlane.admit_run(server, original)
    assert {:error, :admission_conflict} = ControlPlane.admit_run(server, changed_generation)
    assert {:error, :admission_conflict} = ControlPlane.admit_run(server, changed_policy)
    assert {:error, :admission_conflict} = ControlPlane.admit_run(server, changed_checks)

    assert {:error, :admission_conflict} =
             ControlPlane.admit_run(server, changed_numeric_policy)

    assert {:ok, retained} = ControlPlane.fetch_admission(server, "alpha", "issue-1")
    assert retained.admitted_run_id == admission.admitted_run_id
    assert retained.context == original
    assert scalar_query!(database_path, "SELECT count(*) FROM target_generations") == 1
  end

  test "target identity scopes overlapping tracker issue identities" do
    config_root = tmp_root!("control-plane-target-isolation")
    server = start_control_plane!(config_root)

    alpha = execution_context!(config_root, "alpha", "shared-id", "SID-427")
    beta = execution_context!(config_root, "beta", "shared-id", "SID-427")

    assert {:ok, alpha_admission} = ControlPlane.admit_run(server, alpha)
    assert {:ok, beta_admission} = ControlPlane.admit_run(server, beta)

    refute alpha_admission.admitted_run_id == beta_admission.admitted_run_id

    assert {:ok, fetched_alpha} =
             ControlPlane.fetch_admission(server, "alpha", "shared-id")

    assert {:ok, fetched_beta} =
             ControlPlane.fetch_admission(server, "beta", "shared-id")

    assert fetched_alpha.context.target.target_id == "alpha"
    assert fetched_beta.context.target.target_id == "beta"
    assert fetched_alpha.context.issue_identifier == fetched_beta.context.issue_identifier

    assert {:ok, alpha_lease} =
             ControlPlane.acquire_lease(
               server,
               alpha_admission.admitted_run_id,
               "alpha-owner"
             )

    assert {:ok, beta_lease} =
             ControlPlane.acquire_lease(
               server,
               beta_admission.admitted_run_id,
               "beta-owner"
             )

    assert alpha_lease.target_id == "alpha"
    assert beta_lease.target_id == "beta"
    assert alpha_lease.fencing_token == beta_lease.fencing_token
  end

  test "concurrent owners cannot both acquire one admitted run" do
    config_root = tmp_root!("control-plane-exclusive-lease")
    {_clock, clock} = test_clock!(1_000_000)
    first = start_control_plane!(config_root, clock: clock, busy_timeout: 2_000)
    second = start_control_plane!(config_root, clock: clock, busy_timeout: 2_000)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-428")
    assert {:ok, admission} = ControlPlane.admit_run(first, context)

    tasks = [
      Task.async(fn ->
        ControlPlane.acquire_lease(first, admission.admitted_run_id, "owner-a")
      end),
      Task.async(fn ->
        ControlPlane.acquire_lease(second, admission.admitted_run_id, "owner-b")
      end)
    ]

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, %Lease{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :lease_held})) == 1

    assert {:error, :lease_held} =
             ControlPlane.acquire_lease(
               first,
               admission.admitted_run_id,
               "owner-a"
             )
  end

  test "ownership transfer and release permanently fence stale owners and tokens" do
    config_root = tmp_root!("control-plane-fencing")
    {clock_state, clock} = test_clock!(1_000_000)
    server = start_control_plane!(config_root, clock: clock)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-428")
    assert {:ok, admission} = ControlPlane.admit_run(server, context)

    assert {:ok, first} =
             ControlPlane.acquire_lease(
               server,
               admission.admitted_run_id,
               "owner-a"
             )

    assert first.fencing_token == 1
    set_clock!(clock_state, 1_010_000)
    assert {:ok, renewed} = ControlPlane.renew_lease(server, first)
    assert renewed.fencing_token == first.fencing_token
    assert renewed.deadline_ms == 1_040_000

    set_clock!(clock_state, 1_011_000)

    assert {:ok, transferred} =
             ControlPlane.transfer_lease(server, renewed, "owner-b")

    assert transferred.owner_id == "owner-b"
    assert transferred.fencing_token == 2
    assert {:error, :stale_lease} = ControlPlane.renew_lease(server, renewed)
    assert {:error, :stale_lease} = ControlPlane.release_lease(server, renewed)

    stale_token = %{transferred | fencing_token: renewed.fencing_token}
    assert {:error, :stale_lease} = ControlPlane.renew_lease(server, stale_token)
    assert :ok = ControlPlane.release_lease(server, transferred)
    assert {:error, :stale_lease} = ControlPlane.renew_lease(server, transferred)

    assert {:ok, reacquired} =
             ControlPlane.acquire_lease(
               server,
               admission.admitted_run_id,
               "owner-c"
             )

    assert reacquired.fencing_token == 3
  end

  test "durable deadlines survive restart and use exact expiry boundaries" do
    config_root = tmp_root!("control-plane-lease-restart")
    {clock_state, clock} = test_clock!(2_000_000)
    first_server = start_control_plane!(config_root, clock: clock)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-428")
    assert {:ok, admission} = ControlPlane.admit_run(first_server, context)

    assert {:ok, first_lease} =
             ControlPlane.acquire_lease(
               first_server,
               admission.admitted_run_id,
               "owner-a"
             )

    stop_process(first_server)
    set_clock!(clock_state, first_lease.deadline_ms - 1)
    restarted = start_control_plane!(config_root, clock: clock)

    assert {:error, :lease_active} =
             ControlPlane.expire_lease(restarted, admission.admitted_run_id)

    assert {:error, :lease_held} =
             ControlPlane.acquire_lease(
               restarted,
               admission.admitted_run_id,
               "owner-b"
             )

    set_clock!(clock_state, first_lease.deadline_ms)

    assert {:error, :stale_lease} =
             ControlPlane.renew_lease(restarted, first_lease)

    assert {:ok, :expired} =
             ControlPlane.expire_lease(restarted, admission.admitted_run_id)

    assert {:ok, second_lease} =
             ControlPlane.acquire_lease(
               restarted,
               admission.admitted_run_id,
               "owner-b"
             )

    assert second_lease.fencing_token > first_lease.fencing_token
  end

  test "clock skew is bounded and clock failures cannot renew ownership" do
    config_root = tmp_root!("control-plane-lease-clock")
    {clock_state, clock} = test_clock!(3_000_000)
    server = start_control_plane!(config_root, clock: clock)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-428")
    assert {:ok, admission} = ControlPlane.admit_run(server, context)

    assert {:ok, lease} =
             ControlPlane.acquire_lease(
               server,
               admission.admitted_run_id,
               "owner-a"
             )

    set_clock!(clock_state, 2_999_000)
    assert {:ok, within_skew} = ControlPlane.renew_lease(server, lease)
    assert within_skew.deadline_ms == lease.deadline_ms

    set_clock!(clock_state, 2_998_999)

    assert {:error, %Error{code: :clock_failed}} =
             ControlPlane.renew_lease(server, within_skew)

    set_clock!(clock_state, :unavailable)

    assert {:error, %Error{code: :clock_failed}} =
             ControlPlane.renew_lease(server, within_skew)

    set_clock!(clock_state, 3_001_000)
    assert {:ok, recovered} = ControlPlane.renew_lease(server, within_skew)
    assert recovered.fencing_token == lease.fencing_token
    set_clock!(clock_state, 3_000_000)
    assert {:ok, transferred} = ControlPlane.transfer_lease(server, recovered, "owner-b")
    assert transferred.deadline_ms == recovered.deadline_ms
  end

  test "lease decisions sample the clock after write lock acquisition" do
    config_root = tmp_root!("control-plane-lease-clock-order")
    parent = self()
    {clock_state, base_clock} = test_clock!(4_000_000)

    clock = fn ->
      value = base_clock.()
      send(parent, {:lease_clock_read, self(), value})
      value
    end

    lock_server = start_control_plane!(config_root, clock: clock, busy_timeout: 2_000)
    lease_server = start_control_plane!(config_root, clock: clock, busy_timeout: 2_000)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-428")
    assert {:ok, admission} = ControlPlane.admit_run(lock_server, context)

    assert {:ok, lease} =
             ControlPlane.acquire_lease(
               lease_server,
               admission.admitted_run_id,
               "owner-a"
             )

    assert_receive {:lease_clock_read, ^lease_server, 4_000_000}
    holder = hold_write_lock(lock_server)
    assert_receive {:write_lock_held, lock_owner}, 1_000

    renewal =
      Task.async(fn ->
        send(parent, :renewal_started)
        ControlPlane.renew_lease(lease_server, lease)
      end)

    assert_receive :renewal_started
    refute_receive {:lease_clock_read, ^lease_server, _value}, 100
    set_clock!(clock_state, lease.deadline_ms)
    send(lock_owner, :release_write_lock)

    assert_receive {:lease_clock_read, ^lease_server, deadline_ms}, 1_000
    assert deadline_ms == lease.deadline_ms
    assert {:ok, :released} = Task.await(holder, 1_000)
    assert {:error, :stale_lease} = Task.await(renewal, 1_000)
  end

  test "store write failures cannot acquire or renew a lease" do
    config_root = tmp_root!("control-plane-lease-store-failure")
    {_clock, clock} = test_clock!(4_000_000)
    lock_server = start_control_plane!(config_root, clock: clock, busy_timeout: 50)
    lease_server = start_control_plane!(config_root, clock: clock, busy_timeout: 50)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-428")
    assert {:ok, admission} = ControlPlane.admit_run(lock_server, context)

    acquire_holder = hold_write_lock(lock_server)
    assert_receive {:write_lock_held, acquire_owner}, 1_000

    assert {:error, %Error{code: :transaction_failed}} =
             ControlPlane.acquire_lease(
               lease_server,
               admission.admitted_run_id,
               "owner-a"
             )

    send(acquire_owner, :release_write_lock)
    assert {:ok, :released} = Task.await(acquire_holder, 1_000)

    assert {:ok, lease} =
             ControlPlane.acquire_lease(
               lease_server,
               admission.admitted_run_id,
               "owner-a"
             )

    renew_holder = hold_write_lock(lock_server)
    assert_receive {:write_lock_held, renew_owner}, 1_000

    assert {:error, %Error{code: :transaction_failed}} =
             ControlPlane.renew_lease(lease_server, lease)

    send(renew_owner, :release_write_lock)
    assert {:ok, :released} = Task.await(renew_holder, 1_000)
    assert {:ok, renewed} = ControlPlane.renew_lease(lease_server, lease)
    assert renewed.fencing_token == lease.fencing_token
  end

  test "retry and blocked lifecycle evidence survives reopen and remains target scoped" do
    config_root = tmp_root!("control-plane-lifecycle-reopen")
    {clock_state, clock} = test_clock!(5_000_000)
    server = start_control_plane!(config_root, clock: clock)
    alpha_context = execution_context!(config_root, "alpha", "shared-issue", "SID-429")
    beta_context = execution_context!(config_root, "beta", "shared-issue", "SID-429")
    assert {:ok, alpha_admission} = ControlPlane.admit_run(server, alpha_context)
    assert {:ok, _beta_admission} = ControlPlane.admit_run(server, beta_context)

    assert {:ok, %Lifecycle{state: :admitted, sequence: 1} = initial} =
             ControlPlane.fetch_target_lifecycle(server, "alpha", "shared-issue")

    assert ControlPlane.project_runtime_state(initial) == :claimed

    assert {:ok, lease} =
             ControlPlane.acquire_lease(
               server,
               alpha_admission.admitted_run_id,
               "owner-a"
             )

    assert {:ok, %Lifecycle{state: :running, sequence: 2} = running} =
             ControlPlane.transition_run(
               server,
               lease,
               initial.sequence,
               :admitted,
               :running,
               %{}
             )

    assert ControlPlane.project_runtime_state(running) == :running

    failure = %{
      code: "agent_failed",
      message: "runtime exited",
      details: %{phase: "turn"}
    }

    assert {:ok, %Lifecycle{state: :retrying, sequence: 3}} =
             ControlPlane.transition_run(
               server,
               lease,
               running.sequence,
               :running,
               :retrying,
               %{attempt: 2, due_at_ms: 5_050_000, failure: failure}
             )

    stop_process(server)
    reopened = start_control_plane!(config_root, clock: clock)

    assert {:ok, retrying} =
             ControlPlane.fetch_target_lifecycle(
               reopened,
               "alpha",
               "shared-issue"
             )

    assert retrying.retry_attempt == 2
    assert retrying.retry_due_at_ms == 5_050_000

    assert retrying.failure == %{
             "code" => "agent_failed",
             "message" => "runtime exited",
             "details" => %{"phase" => "turn"}
           }

    assert ControlPlane.project_runtime_state(retrying) == :retrying

    assert {:ok, %Lifecycle{state: :admitted}} =
             ControlPlane.fetch_target_lifecycle(
               reopened,
               "beta",
               "shared-issue"
             )

    set_clock!(clock_state, 5_001_000)

    assert {:ok, %Lifecycle{state: :blocked, sequence: 4}} =
             ControlPlane.transition_run(
               reopened,
               lease,
               retrying.sequence,
               :retrying,
               :blocked,
               %{reason: "operator input required"}
             )

    stop_process(reopened)
    reopened_again = start_control_plane!(config_root, clock: clock)
    assert {:ok, blocked} = ControlPlane.fetch_lifecycle(reopened_again, lease.admitted_run_id)
    assert blocked.blocked_reason == "operator input required"
    assert ControlPlane.project_runtime_state(blocked) == :blocked

    assert {:ok,
            [
              %LifecycleTransition{sequence: 1, from_state: nil, to_state: :admitted},
              %LifecycleTransition{sequence: 2, from_state: :admitted, to_state: :running},
              %LifecycleTransition{sequence: 3, from_state: :running, to_state: :retrying},
              %LifecycleTransition{sequence: 4, from_state: :retrying, to_state: :blocked}
            ]} = ControlPlane.lifecycle_history(reopened_again, lease.admitted_run_id)
  end

  test "stale same-state observations cannot mutate a later lifecycle cycle" do
    config_root = tmp_root!("control-plane-lifecycle-sequence")
    {_clock_state, clock} = test_clock!(5_500_000)
    server = start_control_plane!(config_root, clock: clock)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-429")
    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-a")

    assert {:ok, %Lifecycle{state: :running, sequence: 2}} =
             ControlPlane.transition_run(server, lease, 1, :admitted, :running, %{})

    assert {:ok, %Lifecycle{state: :retrying, sequence: 3}} =
             ControlPlane.transition_run(
               server,
               lease,
               2,
               :running,
               :retrying,
               %{
                 attempt: 1,
                 due_at_ms: 5_501_000,
                 failure: %{code: "failed", message: "boom"}
               }
             )

    assert {:ok, %Lifecycle{state: :running, sequence: 4}} =
             ControlPlane.transition_run(server, lease, 3, :retrying, :running, %{})

    assert {:error, :out_of_order_transition} =
             ControlPlane.transition_run(
               server,
               lease,
               2,
               :running,
               :blocked,
               %{reason: "stale observation"}
             )
  end

  test "fencing and ordering reject partial writes while terminal duplicates are idempotent" do
    config_root = tmp_root!("control-plane-lifecycle-fencing")
    {_clock_state, clock} = test_clock!(6_000_000)
    server = start_control_plane!(config_root, clock: clock)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-429")
    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-a")

    assert {:ok, %Lifecycle{state: :running, sequence: 2}} =
             ControlPlane.transition_run(server, lease, 1, :admitted, :running, %{})

    stale_lease = %{lease | fencing_token: lease.fencing_token + 1}

    assert {:error, :stale_lease} =
             ControlPlane.transition_run(
               server,
               stale_lease,
               2,
               :running,
               :retrying,
               %{
                 attempt: 1,
                 due_at_ms: 6_001_000,
                 failure: %{code: "failed", message: "boom"}
               }
             )

    assert {:error, :duplicate_transition} =
             ControlPlane.transition_run(server, lease, 2, :running, :running, %{})

    assert {:error, :illegal_transition} =
             ControlPlane.transition_run(server, lease, 2, :running, :cleaned, %{})

    assert {:error, :out_of_order_transition} =
             ControlPlane.transition_run(
               server,
               lease,
               2,
               :blocked,
               :completed,
               %{disposition: :succeeded}
             )

    assert {:error, :invalid_transition} =
             ControlPlane.transition_run(
               server,
               lease,
               2,
               :running,
               :retrying,
               %{attempt: 1}
             )

    assert {:error, :invalid_transition} =
             ControlPlane.transition_run(
               server,
               lease,
               2,
               :running,
               :retrying,
               %{
                 attempt: 1,
                 due_at_ms: 6_001_000,
                 failure: %{1 => "invalid key", code: "failed", message: "boom"}
               }
             )

    assert {:ok, %Lifecycle{state: :running, sequence: 2}} =
             ControlPlane.fetch_lifecycle(server, admission.admitted_run_id)

    assert {:ok, history_before_completion} =
             ControlPlane.lifecycle_history(server, admission.admitted_run_id)

    assert length(history_before_completion) == 2

    assert {:error, :duplicate_transition} =
             ControlPlane.transition_run(server, lease, 1, :admitted, :running, %{})

    assert {:ok, %Lifecycle{state: :completed, sequence: 3} = completed} =
             ControlPlane.transition_run(
               server,
               lease,
               2,
               :running,
               :completed,
               %{disposition: :succeeded}
             )

    assert completed.completed_at
    assert ControlPlane.project_runtime_state(completed) == :completed

    assert {:error, :stale_lease} =
             ControlPlane.transition_run(
               server,
               stale_lease,
               2,
               :running,
               :completed,
               %{"disposition" => "succeeded"}
             )

    assert {:ok, ^completed} =
             ControlPlane.transition_run(
               server,
               lease,
               2,
               :running,
               :completed,
               %{"disposition" => "succeeded"}
             )

    assert {:error, :duplicate_transition} =
             ControlPlane.transition_run(
               server,
               lease,
               2,
               :running,
               :completed,
               %{disposition: :failed}
             )

    assert {:ok, %Lifecycle{state: :cleanup_pending, sequence: 4} = cleanup_pending} =
             ControlPlane.transition_run(
               server,
               lease,
               3,
               :completed,
               :cleanup_pending,
               %{}
             )

    assert cleanup_pending.cleanup_authority["workspace_path"] == context.workspace_path
    assert cleanup_pending.cleanup_pending_at

    assert {:error, :stale_lease} =
             ControlPlane.transition_run(
               server,
               stale_lease,
               3,
               :completed,
               :cleanup_pending,
               %{}
             )

    assert {:ok, ^cleanup_pending} =
             ControlPlane.transition_run(
               server,
               lease,
               3,
               :completed,
               :cleanup_pending,
               %{}
             )

    assert {:ok, %Lifecycle{state: :cleaned, sequence: 5} = cleaned} =
             ControlPlane.transition_run(
               server,
               lease,
               4,
               :cleanup_pending,
               :cleaned,
               %{}
             )

    assert cleaned.cleaned_at
    assert :ok = ControlPlane.release_lease(server, lease)

    assert {:ok, ^cleaned} =
             ControlPlane.transition_run(
               server,
               lease,
               4,
               :cleanup_pending,
               :cleaned,
               %{}
             )

    assert {:ok, ^cleaned} =
             ControlPlane.transition_run(
               server,
               lease,
               2,
               :running,
               :completed,
               %{disposition: :succeeded}
             )

    assert {:ok, ^cleaned} =
             ControlPlane.transition_run(
               server,
               lease,
               3,
               :completed,
               :cleanup_pending,
               %{}
             )

    assert {:ok, transitions} =
             ControlPlane.lifecycle_history(server, admission.admitted_run_id)

    assert Enum.map(transitions, & &1.to_state) ==
             [:admitted, :running, :completed, :cleanup_pending, :cleaned]
  end

  test "transition history failure rolls back current lifecycle state" do
    config_root = tmp_root!("control-plane-lifecycle-rollback")
    {_clock_state, clock} = test_clock!(7_000_000)
    server = start_control_plane!(config_root, clock: clock)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-429")
    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-a")

    assert {:ok, %Lifecycle{state: :running, sequence: 2}} =
             ControlPlane.transition_run(server, lease, 1, :admitted, :running, %{})

    stop_process(server)
    database_path = ControlPlane.path(config_root: config_root)

    execute_sql!(
      database_path,
      """
      CREATE TRIGGER fail_retry_history
      BEFORE INSERT ON run_lifecycle_transitions
      WHEN NEW.to_state = 'retrying'
      BEGIN
        SELECT RAISE(ABORT, 'fixture transition failure');
      END;
      """
    )

    reopened = start_control_plane!(config_root, clock: clock)

    assert {:error, %Error{code: :transaction_failed}} =
             ControlPlane.transition_run(
               reopened,
               lease,
               2,
               :running,
               :retrying,
               %{
                 attempt: 1,
                 due_at_ms: 7_001_000,
                 failure: %{code: "failed", message: "boom"}
               }
             )

    assert {:ok, %Lifecycle{state: :running, sequence: 2}} =
             ControlPlane.fetch_lifecycle(reopened, admission.admitted_run_id)

    assert {:ok, transitions} =
             ControlPlane.lifecycle_history(reopened, admission.admitted_run_id)

    assert Enum.map(transitions, & &1.to_state) == [:admitted, :running]
  end

  test "stale leases are rejected before every covered side effect" do
    config_root = tmp_root!("control-plane-side-effect-fencing")
    {_clock_state, clock} = test_clock!(8_000_000)
    server = start_control_plane!(config_root, clock: clock)

    context =
      execution_context!(config_root, "alpha", "issue-1", "SID-430", side_effect_gates: all_side_effect_gates())

    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, first_lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-a")

    assert {:ok, %Lifecycle{state: :running}} =
             ControlPlane.transition_run(server, first_lease, 1, :admitted, :running, %{})

    assert {:ok, _second_lease} = ControlPlane.transfer_lease(server, first_lease, "owner-b")

    for kind <- [
          :tracker_write,
          :publish_preflight,
          :publish_handoff,
          :handoff_route,
          :workspace_cleanup
        ] do
      assert {:error, :stale_lease} =
               ControlPlane.run_side_effect(
                 server,
                 first_lease,
                 kind,
                 "completion-#{kind}",
                 %{message: "completion"},
                 fn ->
                   send(self(), {:side_effect_called, kind})
                   {:ok, %{status: "done"}}
                 end
               )
    end

    refute_receive {:side_effect_called, _kind}
    assert {:ok, []} = ControlPlane.list_side_effects(server, admission.admitted_run_id)
  end

  test "pinned delivery gates and cleanup lifecycle authority fail closed" do
    config_root = tmp_root!("control-plane-side-effect-gates")
    {_clock_state, clock} = test_clock!(8_050_000)
    server = start_control_plane!(config_root, clock: clock)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-430")
    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-a")

    assert {:ok, %Lifecycle{state: :running}} =
             ControlPlane.transition_run(server, lease, 1, :admitted, :running, %{})

    for kind <- [:publish_preflight, :publish_handoff, :workspace_cleanup] do
      assert {:error, :side_effect_not_allowed} =
               ControlPlane.run_side_effect(
                 server,
                 lease,
                 kind,
                 "denied-#{kind}",
                 %{},
                 fn ->
                   send(self(), {:denied_side_effect_called, kind})
                   {:ok, %{}}
                 end
               )
    end

    assert {:error, :invalid_side_effect} =
             ControlPlane.begin_side_effect(
               server,
               lease,
               :tracker_write,
               "invalid-evidence",
               %{{:invalid, :key} => "unsafe"}
             )

    assert {:ok, %{status: :healthy}} = ControlPlane.health(server)

    refute_receive {:denied_side_effect_called, _kind}
    assert {:ok, []} = ControlPlane.list_side_effects(server, admission.admitted_run_id)
  end

  test "known completion side effects execute once across duplicate messages" do
    config_root = tmp_root!("control-plane-side-effect-idempotency")
    {_clock_state, clock} = test_clock!(8_100_000)
    server = start_control_plane!(config_root, clock: clock)

    context =
      execution_context!(config_root, "alpha", "issue-1", "SID-430", side_effect_gates: all_side_effect_gates())

    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-a")

    assert {:ok, %Lifecycle{state: :running, sequence: 2}} =
             ControlPlane.transition_run(server, lease, 1, :admitted, :running, %{})

    for kind <- [:tracker_write, :publish_preflight, :publish_handoff, :handoff_route] do
      operation = fn ->
        send(self(), {:side_effect_called, kind})
        {:ok, %{status: "done"}}
      end

      assert {:ok, %SideEffect{state: :succeeded} = first} =
               ControlPlane.run_side_effect(
                 server,
                 lease,
                 kind,
                 "completion-1",
                 %{message: "completion"},
                 operation
               )

      assert_receive {:side_effect_called, ^kind}

      assert {:ok, ^first} =
               ControlPlane.run_side_effect(
                 server,
                 lease,
                 kind,
                 "completion-1",
                 %{message: "completion"},
                 operation
               )

      refute_receive {:side_effect_called, ^kind}
    end

    assert {:ok, %Lifecycle{state: :completed, sequence: 3}} =
             ControlPlane.transition_run(
               server,
               lease,
               2,
               :running,
               :completed,
               %{disposition: :succeeded}
             )

    assert {:ok, %Lifecycle{state: :cleanup_pending, sequence: 4}} =
             ControlPlane.transition_run(
               server,
               lease,
               3,
               :completed,
               :cleanup_pending,
               %{}
             )

    cleanup = fn ->
      send(self(), :workspace_cleanup_called)
      {:ok, %{removed: true}}
    end

    assert {:ok, %SideEffect{state: :succeeded} = cleaned} =
             ControlPlane.run_side_effect(
               server,
               lease,
               :workspace_cleanup,
               "completion-1",
               %{workspace: "pinned"},
               cleanup
             )

    assert_receive :workspace_cleanup_called

    assert {:ok, ^cleaned} =
             ControlPlane.run_side_effect(
               server,
               lease,
               :workspace_cleanup,
               "completion-1",
               %{workspace: "pinned"},
               cleanup
             )

    refute_receive :workspace_cleanup_called
    assert {:ok, side_effects} = ControlPlane.list_side_effects(server, admission.admitted_run_id)
    assert length(side_effects) == 5
  end

  test "ambiguous external outcomes survive reopen and block automatic replay" do
    config_root = tmp_root!("control-plane-side-effect-reconciliation")
    {_clock_state, clock} = test_clock!(8_200_000)
    server = start_control_plane!(config_root, clock: clock)
    database_path = ControlPlane.path(config_root: config_root)
    secret = "side-effect-secret-value"
    context = execution_context!(config_root, "alpha", "issue-1", "SID-430")
    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-a")

    assert {:ok, %Lifecycle{state: :running}} =
             ControlPlane.transition_run(server, lease, 1, :admitted, :running, %{})

    assert {:blocked,
            %SideEffect{
              state: :reconciliation_required,
              outcome: %{
                "authorization" => "<redacted:secret>",
                "detail" => "timeout"
              }
            } = blocked} =
             ControlPlane.run_side_effect(
               server,
               lease,
               :tracker_write,
               "comment-1",
               %{body_sha256: hash("comment")},
               fn ->
                 {:ambiguous, %{authorization: secret, detail: "timeout"}}
               end
             )

    assert {:ok, %SideEffect{state: :pending}} =
             ControlPlane.begin_side_effect(
               server,
               lease,
               :tracker_write,
               "comment-2",
               %{body_sha256: hash("interrupted-comment")}
             )

    refute database_bytes(database_path) =~ secret
    stop_process(server)
    reopened = start_control_plane!(config_root, clock: clock)

    assert {:blocked, ^blocked} =
             ControlPlane.run_side_effect(
               reopened,
               lease,
               :tracker_write,
               "comment-1",
               %{body_sha256: hash("comment")},
               fn ->
                 send(self(), :ambiguous_side_effect_replayed)
                 {:ok, %{status: "done"}}
               end
             )

    refute_receive :ambiguous_side_effect_replayed

    assert {:blocked,
            %SideEffect{
              state: :reconciliation_required,
              outcome: %{
                "operator_action_required" => true,
                "reason" => "prior_external_outcome_unknown"
              }
            }} =
             ControlPlane.run_side_effect(
               reopened,
               lease,
               :tracker_write,
               "comment-2",
               %{body_sha256: hash("interrupted-comment")},
               fn ->
                 send(self(), :interrupted_side_effect_replayed)
                 {:ok, %{status: "done"}}
               end
             )

    refute_receive :interrupted_side_effect_replayed
  end

  test "side-effect identities and artifact paths remain target scoped" do
    config_root = tmp_root!("control-plane-side-effect-isolation")
    {_clock_state, clock} = test_clock!(8_300_000)
    server = start_control_plane!(config_root, clock: clock)
    alpha = execution_context!(config_root, "alpha", "shared-issue", "SID-430")
    beta = execution_context!(config_root, "beta", "shared-issue", "SID-430")
    assert {:ok, alpha_admission} = ControlPlane.admit_run(server, alpha)
    assert {:ok, beta_admission} = ControlPlane.admit_run(server, beta)
    assert {:ok, alpha_lease} = ControlPlane.acquire_lease(server, alpha_admission.admitted_run_id, "alpha-owner")
    assert {:ok, beta_lease} = ControlPlane.acquire_lease(server, beta_admission.admitted_run_id, "beta-owner")

    assert {:ok, %SideEffect{} = alpha_effect} =
             ControlPlane.begin_side_effect(
               server,
               alpha_lease,
               :tracker_write,
               "comment-1",
               %{body_sha256: hash("same-comment")}
             )

    assert {:ok, %SideEffect{} = beta_effect} =
             ControlPlane.begin_side_effect(
               server,
               beta_lease,
               :tracker_write,
               "comment-1",
               %{body_sha256: hash("same-comment")}
             )

    refute alpha_effect.admitted_run_id == beta_effect.admitted_run_id
    refute alpha_effect.target_id == beta_effect.target_id
    refute alpha_effect.artifact_path == beta_effect.artifact_path
    assert alpha_effect.tracker_issue_id == beta_effect.tracker_issue_id
  end

  test "lease transfer waits for verified process-group termination" do
    config_root = tmp_root!("control-plane-process-transfer")
    {_clock_state, clock} = test_clock!(8_400_000)
    server = start_control_plane!(config_root, clock: clock)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-430")
    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-a")

    assert {:ok, %Lifecycle{state: :running}} =
             ControlPlane.transition_run(server, lease, 1, :admitted, :running, %{})

    assert {:ok, %ProcessOwnership{state: :running, process_group_id: 41_001}} =
             ControlPlane.register_process_group(server, lease, process_identity(41_001))

    assert {:error, :process_termination_unverified} =
             ControlPlane.transfer_lease(server, lease, "owner-b")

    assert {:error, :process_termination_unverified} =
             ControlPlane.release_lease(server, lease)

    assert {:ok, %ProcessOwnership{state: :unverifiable}} =
             ControlPlane.record_process_group_termination(
               server,
               lease,
               41_001,
               {:unverifiable, %{reason: "group inspection failed"}}
             )

    assert {:ok, %Lifecycle{state: :blocked, blocked_reason: blocked_reason}} =
             ControlPlane.fetch_lifecycle(server, admission.admitted_run_id)

    assert blocked_reason == "process group termination is unverifiable"

    assert {:error, :process_termination_unverified} =
             ControlPlane.transfer_lease(server, lease, "owner-b")

    assert {:ok, %ProcessOwnership{state: :stopped}} =
             ControlPlane.record_process_group_termination(
               server,
               lease,
               41_001,
               {:stopped, %{verified_by: "process_supervisor"}}
             )

    assert {:error, :process_ownership_conflict} =
             ControlPlane.record_process_group_termination(
               server,
               lease,
               41_001,
               {:unverifiable, %{reason: "late ambiguous observation"}}
             )

    assert {:ok, transferred} = ControlPlane.transfer_lease(server, lease, "owner-b")
    assert transferred.fencing_token > lease.fencing_token

    assert {:error, :stale_lease} =
             ControlPlane.record_process_group_termination(
               server,
               lease,
               41_001,
               {:stopped, %{verified_by: "late-owner"}}
             )
  end

  test "two-target crash recovery preserves pinned authority and fenced side effects" do
    config_root = tmp_root!("control-plane-two-target-crash")
    {clock_state, clock} = test_clock!(8_500_000)
    registry_path = Path.join(config_root, "target-registry.yml")
    workflow_path = Path.join(config_root, "workflow.yml")
    File.write!(registry_path, "registry-generation=admitted\n")
    File.write!(workflow_path, "mix test.sid433\n")

    pinned_generation = hash(File.read!(registry_path))
    pinned_check = workflow_path |> File.read!() |> String.trim()
    server = start_control_plane!(config_root, clock: clock)

    alpha =
      execution_context!(config_root, "alpha", "shared-issue", "SID-433",
        generation: pinned_generation,
        check: pinned_check,
        tracker_key: "$ALPHA_TRACKER_KEY",
        runner_password: "env:ALPHA_RUNNER_PASSWORD",
        side_effect_gates: all_side_effect_gates()
      )

    beta =
      execution_context!(config_root, "beta", "shared-issue", "SID-433",
        generation: pinned_generation,
        check: pinned_check,
        tracker_key: "$BETA_TRACKER_KEY",
        runner_password: "env:BETA_RUNNER_PASSWORD",
        side_effect_gates: all_side_effect_gates()
      )

    assert {:ok, alpha_admission} = ControlPlane.admit_run(server, alpha)
    assert {:ok, beta_admission} = ControlPlane.admit_run(server, beta)
    refute alpha_admission.admitted_run_id == beta_admission.admitted_run_id

    assert {:ok, alpha_old_lease} =
             ControlPlane.acquire_lease(server, alpha_admission.admitted_run_id, "owner-old-alpha")

    assert {:ok, beta_old_lease} =
             ControlPlane.acquire_lease(server, beta_admission.admitted_run_id, "owner-old-beta")

    assert {:ok, %Lifecycle{state: :running, sequence: 2}} =
             ControlPlane.transition_run(server, alpha_old_lease, 1, :admitted, :running, %{})

    assert {:ok, %Lifecycle{state: :running, sequence: 2}} =
             ControlPlane.transition_run(server, beta_old_lease, 1, :admitted, :running, %{})

    assert {:ok, %ProcessOwnership{state: :running}} =
             ControlPlane.register_process_group(server, alpha_old_lease, process_identity(50_001))

    assert {:ok, %ProcessOwnership{state: :running}} =
             ControlPlane.register_process_group(server, beta_old_lease, process_identity(50_002))

    assert {:ok, %SideEffect{state: :pending} = interrupted_delivery} =
             ControlPlane.begin_side_effect(
               server,
               alpha_old_lease,
               :publish_handoff,
               "delivery-before-crash",
               %{commit: "alpha-pinned"}
             )

    File.write!(registry_path, "registry-generation=poisoned\n")
    File.write!(workflow_path, "mix poisoned\n")
    stop_process(server)
    set_clock!(clock_state, 8_501_000)
    reopened = start_control_plane!(config_root, clock: clock)
    parent = self()

    env_fetcher = fn
      "ALPHA_TRACKER_KEY" -> {:ok, "rotated-alpha-tracker"}
      "ALPHA_RUNNER_PASSWORD" -> {:ok, "rotated-alpha-runner"}
      "BETA_TRACKER_KEY" -> {:ok, "rotated-beta-tracker"}
      "BETA_RUNNER_PASSWORD" -> :error
    end

    assert {:ok, recovered} =
             ControlPlane.recover_runs(reopened, "owner-restarted",
               process_terminator: fn ownership ->
                 send(parent, {:terminated_before_recovery, ownership})
                 {:stopped, %{verified_by: "sid_433_test"}}
               end,
               env_fetcher: env_fetcher
             )

    assert Enum.map(recovered, & &1.admission.target_id) == ["alpha", "beta"]
    by_target = Map.new(recovered, &{&1.admission.target_id, &1})

    assert %Recovery{
             action: :retry,
             execution_context: recovered_alpha,
             lifecycle: %Lifecycle{
               state: :retrying,
               sequence: 3,
               retry_attempt: 1,
               failure: %{"code" => "host_restart"}
             },
             lease: alpha_recovery_lease
           } = by_target["alpha"]

    assert %Recovery{
             action: :blocked,
             execution_context: nil,
             blocked_reason: "recovery credentials are missing",
             lifecycle: %Lifecycle{
               state: :blocked,
               sequence: 3,
               blocked_reason: "recovery credentials are missing"
             },
             lease: beta_recovery_lease
           } = by_target["beta"]

    assert recovered_alpha.target.target_id == "alpha"
    assert recovered_alpha.target.registry_generation == pinned_generation
    assert recovered_alpha.target.effective_checks["pre_handoff"] == [pinned_check]
    assert recovered_alpha.workspace_path == alpha.workspace_path
    refute inspect(recovered_alpha) =~ "poisoned"
    refute inspect(recovered_alpha) =~ "rotated-alpha"

    beta_pinned = by_target["beta"].admission.context
    assert beta_pinned.target.target_id == "beta"
    assert beta_pinned.target.registry_generation == pinned_generation
    assert beta_pinned.target.effective_checks["pre_handoff"] == [pinned_check]
    refute inspect(beta_pinned) =~ "poisoned"

    assert alpha_recovery_lease.fencing_token > alpha_old_lease.fencing_token
    assert beta_recovery_lease.fencing_token > beta_old_lease.fencing_token

    assert_receive {:terminated_before_recovery, %ProcessOwnership{target_id: "alpha", process_group_id: 50_001}}

    assert_receive {:terminated_before_recovery, %ProcessOwnership{target_id: "beta", process_group_id: 50_002}}

    assert {:error, :stale_lease} = ControlPlane.renew_lease(reopened, alpha_old_lease)
    assert {:error, :stale_lease} = ControlPlane.renew_lease(reopened, beta_old_lease)

    for {lease, kind} <- [
          {alpha_old_lease, :publish_handoff},
          {beta_old_lease, :workspace_cleanup}
        ] do
      assert {:error, :stale_lease} =
               ControlPlane.run_side_effect(
                 reopened,
                 lease,
                 kind,
                 "stale-after-fence",
                 %{},
                 fn ->
                   send(parent, {:stale_side_effect_started, kind})
                   {:ok, %{}}
                 end
               )
    end

    refute_receive {:stale_side_effect_started, _kind}

    assert {:blocked,
            %SideEffect{
              state: :reconciliation_required,
              artifact_path: interrupted_artifact_path
            }} =
             ControlPlane.run_side_effect(
               reopened,
               alpha_recovery_lease,
               :publish_handoff,
               "delivery-before-crash",
               %{commit: "alpha-pinned"},
               fn ->
                 send(parent, :interrupted_delivery_replayed)
                 {:ok, %{status: "published"}}
               end
             )

    assert interrupted_artifact_path == interrupted_delivery.artifact_path
    refute_receive :interrupted_delivery_replayed

    assert {:ok, %Lifecycle{state: :running, sequence: 4}} =
             ControlPlane.transition_run(
               reopened,
               alpha_recovery_lease,
               3,
               :retrying,
               :running,
               %{}
             )

    delivery = fn ->
      send(parent, :recovered_delivery_started)
      {:ok, %{status: "published"}}
    end

    assert {:ok, %SideEffect{state: :succeeded} = delivered} =
             ControlPlane.run_side_effect(
               reopened,
               alpha_recovery_lease,
               :publish_handoff,
               "delivery-after-restart",
               %{commit: "alpha-retry"},
               delivery
             )

    assert_receive :recovered_delivery_started

    assert {:ok, ^delivered} =
             ControlPlane.run_side_effect(
               reopened,
               alpha_recovery_lease,
               :publish_handoff,
               "delivery-after-restart",
               %{commit: "alpha-retry"},
               delivery
             )

    refute_receive :recovered_delivery_started

    assert {:ok, %Lifecycle{state: :completed, sequence: 5}} =
             ControlPlane.transition_run(
               reopened,
               alpha_recovery_lease,
               4,
               :running,
               :completed,
               %{disposition: :succeeded}
             )

    assert {:ok, %Lifecycle{state: :cleanup_pending, sequence: 6}} =
             ControlPlane.transition_run(
               reopened,
               alpha_recovery_lease,
               5,
               :completed,
               :cleanup_pending,
               %{}
             )

    assert {:ok, %SideEffect{state: :succeeded} = cleanup_effect} =
             ControlPlane.run_side_effect(
               reopened,
               alpha_recovery_lease,
               :workspace_cleanup,
               "cleanup-after-restart",
               %{workspace: alpha.workspace_path},
               fn ->
                 send(parent, :recovered_cleanup_started)
                 {:ok, %{removed: true}}
               end
             )

    assert_receive :recovered_cleanup_started

    assert {:ok, %Lifecycle{state: :cleaned, sequence: 7}} =
             ControlPlane.transition_run(
               reopened,
               alpha_recovery_lease,
               6,
               :cleanup_pending,
               :cleaned,
               %{}
             )

    assert {:ok, alpha_effects} =
             ControlPlane.list_side_effects(reopened, alpha_admission.admitted_run_id)

    assert {:ok, []} =
             ControlPlane.list_side_effects(reopened, beta_admission.admitted_run_id)

    assert length(alpha_effects) == 3
    assert Enum.uniq(Enum.map(alpha_effects, & &1.artifact_path)) == Enum.map(alpha_effects, & &1.artifact_path)

    for effect <- alpha_effects do
      assert String.starts_with?(effect.artifact_path, alpha.workspace_path)
      assert effect.target_id == "alpha"
      refute effect.artifact_path =~ beta.workspace_path
    end

    assert cleanup_effect.artifact_path =~ "/workspace_cleanup/"
    assert delivered.artifact_path =~ "/publish_handoff/"
  end

  test "restart fences the old owner and converts verified interrupted work to a pinned retry" do
    config_root = tmp_root!("control-plane-recovery-running")
    {clock_state, clock} = test_clock!(9_000_000)
    server = start_control_plane!(config_root, clock: clock)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-431")
    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, old_lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-old")

    assert {:ok, %Lifecycle{state: :running}} =
             ControlPlane.transition_run(server, old_lease, 1, :admitted, :running, %{})

    identity = process_identity(51_001)

    assert {:ok, %ProcessOwnership{evidence: %{"identity" => ^identity}}} =
             ControlPlane.register_process_group(server, old_lease, identity)

    stop_process(server)
    set_clock!(clock_state, 9_001_000)
    reopened = start_control_plane!(config_root, clock: clock)
    parent = self()

    process_terminator = fn ownership ->
      send(parent, {:terminated_old_group, ownership})
      {:stopped, %{verified_by: "recovery_test"}}
    end

    assert {:ok,
            [
              %Recovery{
                action: :retry,
                execution_context: recovered_context,
                lifecycle: %Lifecycle{
                  state: :retrying,
                  retry_attempt: 1,
                  retry_due_at_ms: 9_001_000,
                  failure: %{"code" => "host_restart"}
                },
                lease: recovered_lease
              } = recovery
            ]} =
             ControlPlane.recover_runs(reopened, "owner-new",
               process_terminator: process_terminator,
               env_fetcher: fn "TRACKER_KEY" -> {:ok, "current-tracker-secret"} end
             )

    assert_receive {:terminated_old_group, %ProcessOwnership{fencing_token: old_token, process_group_id: 51_001}}

    assert old_token == old_lease.fencing_token
    assert recovered_lease.fencing_token > old_lease.fencing_token
    assert recovered_context.target.policy_hash == context.target.policy_hash
    assert recovered_context.policy == context.policy
    refute inspect(recovery) =~ "current-tracker-secret"
    refute database_bytes(ControlPlane.path(config_root: config_root)) =~ "current-tracker-secret"
    assert {:error, :stale_lease} = ControlPlane.renew_lease(reopened, old_lease)

    assert {:error, :stale_lease} =
             ControlPlane.transition_run(
               reopened,
               old_lease,
               recovery.lifecycle.sequence,
               :retrying,
               :blocked,
               %{reason: "stale worker"}
             )
  end

  test "recovery resumes old process reconciliation after recovery itself crashes" do
    config_root = tmp_root!("control-plane-recovery-interrupted")
    server = start_control_plane!(config_root)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-431")
    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, old_lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-old")

    assert {:ok, %Lifecycle{state: :running}} =
             ControlPlane.transition_run(server, old_lease, 1, :admitted, :running, %{})

    assert {:ok, %ProcessOwnership{state: :running}} =
             ControlPlane.register_process_group(server, old_lease, process_identity(51_501))

    stop_process(server)
    reopened = start_control_plane!(config_root)
    parent = self()

    {recovery_pid, recovery_monitor} =
      spawn_monitor(fn ->
        ControlPlane.recover_runs(reopened, "owner-interrupted",
          process_terminator: fn ownership ->
            send(parent, {:interrupted_recovery_inspecting, ownership})
            Process.sleep(:infinity)
          end
        )
      end)

    assert_receive {:interrupted_recovery_inspecting,
                    %ProcessOwnership{
                      fencing_token: old_token,
                      process_group_id: 51_501
                    }},
                   1_000

    assert old_token == old_lease.fencing_token
    Process.exit(recovery_pid, :kill)
    assert_receive {:DOWN, ^recovery_monitor, :process, ^recovery_pid, :killed}, 1_000

    assert {:ok, [%Recovery{action: :retry, lifecycle: %Lifecycle{state: :retrying}}]} =
             ControlPlane.recover_runs(reopened, "owner-resumed",
               process_terminator: fn ownership ->
                 send(parent, {:resumed_recovery_terminated, ownership})
                 {:stopped, %{verified_by: "recovery_test"}}
               end,
               env_fetcher: fn "TRACKER_KEY" -> {:ok, "current-tracker-secret"} end
             )

    assert_receive {:resumed_recovery_terminated,
                    %ProcessOwnership{
                      fencing_token: ^old_token,
                      process_group_id: 51_501
                    }},
                   1_000
  end

  test "restart does not reuse stopped ownership from an earlier attempt" do
    config_root = tmp_root!("control-plane-recovery-process-lineage")
    server = start_control_plane!(config_root)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-431")
    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, first_lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-first")

    assert {:ok, %Lifecycle{sequence: 2}} =
             ControlPlane.transition_run(server, first_lease, 1, :admitted, :running, %{})

    assert {:ok, %ProcessOwnership{state: :running}} =
             ControlPlane.register_process_group(server, first_lease, process_identity(51_601))

    assert {:ok, %ProcessOwnership{state: :stopped}} =
             ControlPlane.record_process_group_termination(
               server,
               first_lease,
               51_601,
               {:stopped, %{verified_by: "recovery_test"}}
             )

    assert {:ok, %Lifecycle{sequence: 3, state: :retrying}} =
             ControlPlane.transition_run(
               server,
               first_lease,
               2,
               :running,
               :retrying,
               %{
                 attempt: 1,
                 due_at_ms: System.system_time(:millisecond),
                 failure: %{code: "runtime_failed", message: "retry"}
               }
             )

    stop_process(server)
    reopened = start_control_plane!(config_root)

    assert {:ok, [%Recovery{action: :retry, lease: retry_lease}]} =
             ControlPlane.recover_runs(reopened, "owner-retry", env_fetcher: fn "TRACKER_KEY" -> {:ok, "current-tracker-secret"} end)

    assert {:ok, %Lifecycle{state: :running}} =
             ControlPlane.transition_run(reopened, retry_lease, 3, :retrying, :running, %{})

    stop_process(reopened)
    resumed = start_control_plane!(config_root)

    assert {:ok,
            [
              %Recovery{
                action: :blocked,
                blocked_reason: "recorded process ownership is missing after interruption",
                lifecycle: %Lifecycle{state: :blocked}
              }
            ]} =
             ControlPlane.recover_runs(resumed, "owner-resumed",
               process_terminator: fn _ownership ->
                 flunk("recovery must not reuse process ownership from an earlier attempt")
               end
             )
  end

  test "restart blocks uncertain process ownership without attaching or retrying" do
    config_root = tmp_root!("control-plane-recovery-unverifiable")
    {_clock_state, clock} = test_clock!(9_100_000)
    server = start_control_plane!(config_root, clock: clock)
    context = execution_context!(config_root, "alpha", "issue-1", "SID-431")
    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, old_lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-old")

    assert {:ok, %Lifecycle{state: :running}} =
             ControlPlane.transition_run(server, old_lease, 1, :admitted, :running, %{})

    assert {:ok, %ProcessOwnership{state: :running}} =
             ControlPlane.register_process_group(server, old_lease, process_identity(52_001))

    stop_process(server)
    reopened = start_control_plane!(config_root, clock: clock)

    assert {:ok,
            [
              %Recovery{
                action: :blocked,
                execution_context: nil,
                blocked_reason: "process group termination is unverifiable",
                lifecycle: %Lifecycle{
                  state: :blocked,
                  blocked_reason: "process group termination is unverifiable"
                },
                lease: recovered_lease
              }
            ]} =
             ControlPlane.recover_runs(reopened, "owner-new",
               process_terminator: fn _ownership ->
                 {:unverifiable, %{reason: "live identity did not match"}}
               end
             )

    assert recovered_lease.fencing_token > old_lease.fencing_token
    assert {:error, :stale_lease} = ControlPlane.renew_lease(reopened, old_lease)
  end

  test "restart restores admitted, retry, blocked, and cleanup work from durable authority" do
    config_root = tmp_root!("control-plane-recovery-states")
    {_clock_state, clock} = test_clock!(9_200_000)
    server = start_control_plane!(config_root, clock: clock)

    contexts = %{
      admitted: execution_context!(config_root, "alpha", "admitted", "SID-431-A"),
      retrying: execution_context!(config_root, "alpha", "retrying", "SID-431-R"),
      blocked: execution_context!(config_root, "alpha", "blocked", "SID-431-B"),
      cleanup: execution_context!(config_root, "alpha", "cleanup", "SID-431-C")
    }

    admissions =
      Map.new(contexts, fn {state, context} ->
        assert {:ok, admission} = ControlPlane.admit_run(server, context)
        {state, admission}
      end)

    leases =
      Map.new(admissions, fn {state, admission} ->
        assert {:ok, lease} =
                 ControlPlane.acquire_lease(
                   server,
                   admission.admitted_run_id,
                   "owner-#{state}"
                 )

        {state, lease}
      end)

    retry_lease = leases.retrying

    assert {:ok, %Lifecycle{sequence: 2}} =
             ControlPlane.transition_run(server, retry_lease, 1, :admitted, :running, %{})

    retry_failure = %{code: "runtime_failed", message: "retry later"}

    assert {:ok, %Lifecycle{state: :retrying}} =
             ControlPlane.transition_run(
               server,
               retry_lease,
               2,
               :running,
               :retrying,
               %{attempt: 3, due_at_ms: 9_250_000, failure: retry_failure}
             )

    blocked_lease = leases.blocked

    assert {:ok, %Lifecycle{sequence: 2}} =
             ControlPlane.transition_run(server, blocked_lease, 1, :admitted, :running, %{})

    assert {:ok, %Lifecycle{state: :blocked}} =
             ControlPlane.transition_run(
               server,
               blocked_lease,
               2,
               :running,
               :blocked,
               %{reason: "operator approval required"}
             )

    cleanup_lease = leases.cleanup

    assert {:ok, %Lifecycle{sequence: 2}} =
             ControlPlane.transition_run(server, cleanup_lease, 1, :admitted, :running, %{})

    assert {:ok, %Lifecycle{sequence: 3}} =
             ControlPlane.transition_run(
               server,
               cleanup_lease,
               2,
               :running,
               :completed,
               %{disposition: :succeeded}
             )

    assert {:ok, %Lifecycle{state: :cleanup_pending} = cleanup_before_restart} =
             ControlPlane.transition_run(
               server,
               cleanup_lease,
               3,
               :completed,
               :cleanup_pending,
               %{}
             )

    stop_process(server)
    reopened = start_control_plane!(config_root, clock: clock)

    assert {:ok, recovered} =
             ControlPlane.recover_runs(reopened, "owner-recovery", env_fetcher: fn "TRACKER_KEY" -> {:ok, "current-tracker-secret"} end)

    by_identifier = Map.new(recovered, &{&1.admission.issue_identifier, &1})

    assert %Recovery{action: :dispatch, lifecycle: %Lifecycle{state: :admitted}} =
             by_identifier["SID-431-A"]

    assert %Recovery{
             action: :retry,
             lifecycle: %Lifecycle{
               state: :retrying,
               retry_attempt: 3,
               retry_due_at_ms: 9_250_000,
               failure: %{"code" => "runtime_failed", "message" => "retry later"}
             }
           } = by_identifier["SID-431-R"]

    assert %Recovery{
             action: :blocked,
             blocked_reason: "operator approval required",
             lifecycle: %Lifecycle{state: :blocked}
           } = by_identifier["SID-431-B"]

    assert %Recovery{
             action: :cleanup,
             lifecycle: %Lifecycle{
               state: :cleanup_pending,
               completion_disposition: "succeeded",
               cleanup_authority: cleanup_authority
             }
           } = by_identifier["SID-431-C"]

    assert cleanup_authority == cleanup_before_restart.cleanup_authority
  end

  test "missing credentials block only the affected recovered run" do
    config_root = tmp_root!("control-plane-recovery-credentials")
    server = start_control_plane!(config_root)

    missing_context =
      execution_context!(config_root, "alpha", "missing", "SID-431-M", runner_password: "env:MISSING_PASSWORD")

    ready_context = execution_context!(config_root, "beta", "ready", "SID-431-D")
    assert {:ok, _missing} = ControlPlane.admit_run(server, missing_context)
    assert {:ok, _ready} = ControlPlane.admit_run(server, ready_context)
    stop_process(server)
    reopened = start_control_plane!(config_root)

    env_fetcher = fn
      "TRACKER_KEY" -> {:ok, "current-tracker-secret"}
      "MISSING_PASSWORD" -> :error
    end

    assert {:ok, recovered} =
             ControlPlane.recover_runs(reopened, "owner-recovery", env_fetcher: env_fetcher)

    by_identifier = Map.new(recovered, &{&1.admission.issue_identifier, &1})

    assert %Recovery{
             action: :blocked,
             blocked_reason: "recovery credentials are missing",
             lifecycle: %Lifecycle{
               state: :blocked,
               blocked_reason: "recovery credentials are missing"
             }
           } = by_identifier["SID-431-M"]

    assert %Recovery{action: :dispatch, lifecycle: %Lifecycle{state: :admitted}} =
             by_identifier["SID-431-D"]
  end

  test "resolved tracker and runner credentials are rejected before persistence" do
    config_root = tmp_root!("control-plane-secret-rejection")
    server = start_control_plane!(config_root)
    database_path = ControlPlane.path(config_root: config_root)
    tracker_secret = "resolved-tracker-secret"
    runner_secret = "resolved-runner-secret"

    tracker_context =
      execution_context!(config_root, "alpha", "issue-1", "SID-427", tracker_key: tracker_secret)

    runner_context =
      execution_context!(config_root, "alpha", "issue-2", "SID-428", runner_password: runner_secret)

    tracker_result = ControlPlane.admit_run(server, tracker_context)
    runner_result = ControlPlane.admit_run(server, runner_context)

    assert tracker_result == {:error, :invalid_admission}
    assert runner_result == {:error, :invalid_admission}
    refute inspect(tracker_result) =~ tracker_secret
    refute inspect(runner_result) =~ runner_secret
    refute database_bytes(database_path) =~ tracker_secret
    refute database_bytes(database_path) =~ runner_secret
    assert scalar_query!(database_path, "SELECT count(*) FROM target_generations") == 0
    assert scalar_query!(database_path, "SELECT count(*) FROM run_admissions") == 0
  end

  test "operator inspection uses one redacted canonical durable vocabulary" do
    config_root = tmp_root!("control-plane-operator-inspection")
    {clock_state, clock} = test_clock!(1_000)
    server = start_control_plane!(config_root, clock: clock)
    context = execution_context!(config_root, "alpha", "issue-safe", "SID-432")

    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner-a")

    assert {:ok, %Lifecycle{state: :blocked}} =
             ControlPlane.transition_run(
               server,
               lease,
               1,
               :admitted,
               :blocked,
               %{reason: "token=operator-secret at /private/operator/path"}
             )

    assert {:ok, [snapshot]} = ControlPlane.inspect_runs(server)
    assert snapshot.admitted_run_id == admission.admitted_run_id
    assert snapshot.target_id == "alpha"
    assert snapshot.tracker_issue_id == "issue-safe"
    assert snapshot.issue_identifier == "SID-432"
    assert snapshot.lifecycle_state == "blocked"
    assert snapshot.lifecycle_sequence == 2
    assert snapshot.owner_id == "owner-a"
    assert snapshot.lease_expires_at_ms == 31_000
    assert snapshot.fencing_generation == 1
    assert snapshot.retry_attempt == nil
    assert snapshot.retry_due_at_ms == nil
    assert snapshot.reconciliation_status == "clear"
    assert snapshot.blocked_reason =~ "token=<redacted:secret>"
    assert snapshot.blocked_reason =~ "<redacted:absolute-path>"
    refute inspect(snapshot) =~ "operator-secret"
    refute inspect(snapshot) =~ "/private/operator/path"

    set_clock!(clock_state, 2_000)
    assert :ok = ControlPlane.release_lease(server, lease)
  end

  test "resume and abandon confirmations bind current durable state and fencing" do
    config_root = tmp_root!("control-plane-operator-actions")
    server = start_control_plane!(config_root)
    context = execution_context!(config_root, "alpha", "issue-actions", "SID-432-A")
    assert {:ok, admission} = ControlPlane.admit_run(server, context)

    assert {:ok, resume_preview} =
             ControlPlane.preview_run_action(server, :resume, admission.admitted_run_id)

    assert resume_preview.operation == "resume"
    assert resume_preview.run.lifecycle_state == "admitted"

    assert {:error, :invalid_confirmation} =
             ControlPlane.confirm_run_action(
               server,
               :resume,
               admission.admitted_run_id,
               "operator-resume",
               "stale-preview"
             )

    assert {:ok, %{lease: resume_lease, run: resumed}} =
             ControlPlane.confirm_run_action(
               server,
               :resume,
               admission.admitted_run_id,
               "token=operator-secret at /private/operator/path",
               resume_preview.confirmation
             )

    assert resumed.lifecycle_state == "running"
    assert resumed.lifecycle_sequence == 2
    assert resumed.owner_id == "token=<redacted:secret> at <redacted:absolute-path>"
    assert resumed.fencing_generation == 1

    assert {:ok, abandon_preview} =
             ControlPlane.preview_run_action(server, :abandon, admission.admitted_run_id)

    assert {:error, :lease_held} =
             ControlPlane.confirm_run_action(
               server,
               :abandon,
               admission.admitted_run_id,
               "operator-abandon",
               abandon_preview.confirmation
             )

    assert :ok = ControlPlane.release_lease(server, resume_lease)

    assert {:ok, fresh_abandon_preview} =
             ControlPlane.preview_run_action(server, :abandon, admission.admitted_run_id)

    assert {:ok, %{lease: abandon_lease, run: abandoned}} =
             ControlPlane.confirm_run_action(
               server,
               :abandon,
               admission.admitted_run_id,
               "operator-abandon",
               fresh_abandon_preview.confirmation
             )

    assert abandoned.lifecycle_state == "completed"
    assert abandoned.lifecycle_sequence == 3
    assert abandoned.fencing_generation == 2
    assert :ok = ControlPlane.release_lease(server, abandon_lease)
  end

  test "retention prunes only confirmed old terminal rows" do
    config_root = tmp_root!("control-plane-retention")
    {clock_state, clock} = test_clock!(0)
    server = start_control_plane!(config_root, clock: clock)

    eligible_context = execution_context!(config_root, "alpha", "eligible", "SID-432-P")
    blocked_context = execution_context!(config_root, "alpha", "blocked", "SID-432-B")

    reconciliation_context =
      execution_context!(config_root, "alpha", "reconciliation", "SID-432-R")

    assert {:ok, eligible} = ControlPlane.admit_run(server, eligible_context)

    assert {:ok, eligible_lease} =
             ControlPlane.acquire_lease(server, eligible.admitted_run_id, "owner-eligible")

    assert {:ok, %Lifecycle{state: :completed}} =
             ControlPlane.transition_run(
               server,
               eligible_lease,
               1,
               :admitted,
               :completed,
               %{disposition: "done"}
             )

    assert :ok = ControlPlane.release_lease(server, eligible_lease)

    assert {:ok, blocked} = ControlPlane.admit_run(server, blocked_context)

    assert {:ok, blocked_lease} =
             ControlPlane.acquire_lease(server, blocked.admitted_run_id, "owner-blocked")

    assert {:ok, %Lifecycle{state: :blocked}} =
             ControlPlane.transition_run(
               server,
               blocked_lease,
               1,
               :admitted,
               :blocked,
               %{reason: "operator decision required"}
             )

    assert :ok = ControlPlane.release_lease(server, blocked_lease)

    assert {:ok, reconciliation} =
             ControlPlane.admit_run(server, reconciliation_context)

    assert {:ok, reconciliation_lease} =
             ControlPlane.acquire_lease(
               server,
               reconciliation.admitted_run_id,
               "owner-reconciliation"
             )

    assert {:ok, %SideEffect{state: :pending}} =
             ControlPlane.begin_side_effect(
               server,
               reconciliation_lease,
               :tracker_write,
               "retention-reconciliation",
               %{operation: "comment"}
             )

    assert {:blocked, %SideEffect{state: :reconciliation_required}} =
             ControlPlane.begin_side_effect(
               server,
               reconciliation_lease,
               :tracker_write,
               "retention-reconciliation",
               %{operation: "comment"}
             )

    assert {:ok, %Lifecycle{state: :completed}} =
             ControlPlane.transition_run(
               server,
               reconciliation_lease,
               1,
               :admitted,
               :completed,
               %{disposition: "done"}
             )

    assert :ok = ControlPlane.release_lease(server, reconciliation_lease)

    set_clock!(clock_state, 31 * 86_400_000)

    assert {:ok, preview} = ControlPlane.preview_prune(server, 30)
    assert preview.eligible_count == 1
    assert preview.preserved_terminal_count == 1
    assert Enum.map(preview.eligible_runs, & &1.admitted_run_id) == [eligible.admitted_run_id]

    assert {:error, :invalid_confirmation} =
             ControlPlane.prune(server, 30, "stale-preview")

    assert {:ok, %{pruned_count: 1, pruned_run_ids: [eligible_run_id]}} =
             ControlPlane.prune(server, 30, preview.confirmation)

    assert eligible_run_id == eligible.admitted_run_id

    assert {:error, :admission_not_found} =
             ControlPlane.fetch_lifecycle(server, eligible.admitted_run_id)

    assert {:ok, %Lifecycle{state: :blocked}} =
             ControlPlane.fetch_lifecycle(server, blocked.admitted_run_id)

    assert {:ok, reconciliation_snapshot} =
             ControlPlane.fetch_lifecycle(server, reconciliation.admitted_run_id)

    assert reconciliation_snapshot.state == :completed
    assert {:error, :invalid_retention} = ControlPlane.preview_prune(server, 0)
  end

  test "prune revalidates eligibility inside the delete transaction" do
    config_root = tmp_root!("control-plane-retention-race")
    test_pid = self()
    retention_now_ms = 31 * 86_400_000

    {:ok, clock_state} =
      Agent.start_link(fn ->
        %{armed: false, calls: 0, now_ms: 0}
      end)

    clock = fn ->
      {action, now_ms} =
        Agent.get_and_update(clock_state, fn state ->
          calls = if state.armed, do: state.calls + 1, else: state.calls
          action = if state.armed and calls == 2, do: :block, else: :continue
          {{action, state.now_ms}, %{state | calls: calls}}
        end)

      if action == :block do
        send(test_pid, {:prune_revalidation_clock, self()})

        receive do
          :continue_prune -> :ok
        after
          1_000 -> raise "prune revalidation was not released"
        end
      end

      now_ms
    end

    server = start_control_plane!(config_root, clock: clock)
    concurrent_server = start_control_plane!(config_root, clock: fn -> retention_now_ms end)
    context = execution_context!(config_root, "alpha", "race", "SID-432-RACE")

    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    assert {:ok, lease} = ControlPlane.acquire_lease(server, admission.admitted_run_id, "owner")

    assert {:ok, %Lifecycle{state: :completed}} =
             ControlPlane.transition_run(
               server,
               lease,
               1,
               :admitted,
               :completed,
               %{disposition: "done"}
             )

    assert :ok = ControlPlane.release_lease(server, lease)
    Agent.update(clock_state, &%{&1 | now_ms: retention_now_ms})
    assert {:ok, preview} = ControlPlane.preview_prune(server, 30)
    Agent.update(clock_state, &%{&1 | armed: true, calls: 0})

    prune_task =
      Task.async(fn ->
        ControlPlane.prune(server, 30, preview.confirmation)
      end)

    assert_receive {:prune_revalidation_clock, clock_pid}, 1_000

    assert {:ok, concurrent_lease} =
             ControlPlane.acquire_lease(
               concurrent_server,
               admission.admitted_run_id,
               "concurrent-owner"
             )

    send(clock_pid, :continue_prune)
    assert Task.await(prune_task) == {:error, :invalid_confirmation}

    assert {:ok, %Lifecycle{state: :completed}} =
             ControlPlane.fetch_lifecycle(server, admission.admitted_run_id)

    assert :ok = ControlPlane.release_lease(concurrent_server, concurrent_lease)
  end

  test "version one stores migrate through admission, lease, lifecycle, and side-effect schemas" do
    config_root = tmp_root!("control-plane-version-one")
    database_path = ControlPlane.path(config_root: config_root)

    seed_database!(
      database_path,
      """
      CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY CHECK (version > 0),
        applied_at TEXT NOT NULL
      );
      INSERT INTO schema_migrations (version, applied_at) VALUES (1, 'fixture');
      PRAGMA user_version = 1;
      """
    )

    server = start_control_plane!(config_root)

    assert {:ok, %{schema_version: 6, status: :healthy}} = ControlPlane.health(server)
    assert scalar_query!(database_path, "SELECT count(*) FROM run_leases") == 0
    assert scalar_query!(database_path, "SELECT count(*) FROM run_admissions") == 0
    assert scalar_query!(database_path, "SELECT count(*) FROM run_lifecycles") == 0
    assert scalar_query!(database_path, "SELECT count(*) FROM run_lifecycle_transitions") == 0
    assert scalar_query!(database_path, "SELECT count(*) FROM side_effect_intents") == 0
    assert scalar_query!(database_path, "SELECT count(*) FROM run_process_ownership") == 0
    assert scalar_query!(database_path, "SELECT count(*) FROM run_token_budgets") == 0
  end

  test "version five migration fails closed when prior admissions configured token budgets" do
    config_root = tmp_root!("control-plane-version-five-token-budget")
    database_path = ControlPlane.path(config_root: config_root)
    server = start_control_plane!(config_root)

    context =
      execution_context!(config_root, "alpha", "issue-legacy-budget", "SID-440-LEGACY", budget_limits: token_limits(100, 500, 1_000))

    assert {:ok, admission} = ControlPlane.admit_run(server, context)
    stop_process(server)

    execute_sql!(
      database_path,
      """
      DROP TABLE run_token_budgets;
      DELETE FROM schema_migrations WHERE version = 6;
      PRAGMA user_version = 5;
      """
    )

    assert {:error,
            %Error{
              code: :migration_failed,
              path: ^database_path,
              reason: admitted_run_id,
              message: message
            }} = start_unlinked(config_root: config_root, name: unique_name())

    assert admitted_run_id == admission.admitted_run_id
    assert message =~ "token usage was not persisted"
    assert read_user_version!(database_path) == 5
    assert scalar_query!(database_path, "SELECT count(*) FROM schema_migrations WHERE version = 6") == 0
  end

  test "a newer schema version stops startup with an actionable error" do
    config_root = tmp_root!("control-plane-newer-schema")
    database_path = ControlPlane.path(config_root: config_root)
    seed_database!(database_path, "PRAGMA user_version = 7")

    assert {:error,
            %Error{
              code: :unsupported_schema_version,
              path: ^database_path,
              message: message
            }} = start_unlinked(config_root: config_root, name: unique_name())

    assert message =~ "schema version 7 is newer than supported version 6"
  end

  test "migration failure rolls back schema state and stops startup" do
    config_root = tmp_root!("control-plane-migration-failure")
    database_path = ControlPlane.path(config_root: config_root)
    seed_database!(database_path, "CREATE TABLE schema_migrations (wrong_column INTEGER)")

    assert {:error, %Error{code: :migration_failed, message: message}} =
             start_unlinked(config_root: config_root, name: unique_name())

    assert message =~ "control-plane schema migration failed"
    assert read_user_version!(database_path) == 0
  end

  test "corruption stops startup with an actionable error" do
    config_root = tmp_root!("control-plane-corrupt")
    database_path = ControlPlane.path(config_root: config_root)
    File.mkdir_p!(config_root)
    File.write!(database_path, "not a sqlite database")

    assert {:error,
            %Error{
              code: :corrupt_store,
              path: ^database_path,
              message: message
            }} = start_unlinked(config_root: config_root, name: unique_name())

    assert message =~ "SQLite quick check"
  end

  test "an unusable config root stops startup with an actionable error" do
    parent = tmp_root!("control-plane-unwritable")
    config_root = Path.join(parent, "config-root-file")
    File.write!(config_root, "not a directory")
    database_path = ControlPlane.path(config_root: config_root)

    assert {:error,
            %Error{
              code: :unwritable_store,
              path: ^database_path,
              message: message
            }} = start_unlinked(config_root: config_root, name: unique_name())

    assert message =~ "config root is not a directory"
  end

  defp execution_context!(config_root, target_id, issue_id, issue_identifier, opts \\ []) do
    workspace_root = Path.join(config_root, "worktrees")
    File.mkdir_p!(workspace_root)

    runner =
      %{
        "kind" => "codex_app_server",
        "command" => ["codex", "app-server"],
        "turn_timeout_ms" => 30_000,
        "execution_profiles" => %{
          "implementation" => %{
            "model" => "model-#{target_id}",
            "reasoning_effort" => "high",
            "budget" => "standard",
            "timeout_ms" => 30_000,
            "max_retries" => 1
          }
        }
      }
      |> maybe_put_runner_password(Keyword.get(opts, :runner_password))

    target =
      %TargetContext{
        target_id: target_id,
        state: :active,
        dispatch_mode: :explicit,
        registry_generation: Keyword.get(opts, :generation, hash("generation-#{target_id}")),
        policy_hash: Keyword.get(opts, :policy_hash, hash("policy-#{target_id}")),
        repo_manifest_hash: hash("manifest-#{target_id}"),
        repo_policy: %{
          "manifest" => %{"version" => 1},
          "manifest_source_dir" => config_root,
          "workflow_module_resolution" => %{}
        },
        tracker_connection: %{
          "id" => "linear",
          "policy" => %{
            "kind" => "linear",
            "endpoint" => "https://tracker.example.invalid/graphql",
            "api_key" => Keyword.get(opts, :tracker_key, "$TRACKER_KEY")
          }
        },
        run_target: %{},
        worktree_policy: %{
          "root" => workspace_root,
          "strategy" => "per_issue",
          "hooks" => %{
            "after_create" => nil,
            "after_run" => nil,
            "before_remove" => nil,
            "before_run" => nil,
            "timeout_ms" => 5_000
          }
        },
        runner_policy: %{
          "default" => "runner",
          "allowed" => ["runner"],
          "runners" => %{"runner" => runner}
        },
        effective_checks: %{
          "pre_handoff" => [Keyword.get(opts, :check, "mix test")]
        },
        external_side_effect_gates:
          Keyword.get(opts, :side_effect_gates, %{
            "tracker_write" => "allow",
            "vcs_publish" => "deny"
          }),
        capacity_limits: %{"max_concurrent_agents" => 1},
        budget_limits: Keyword.get(opts, :budget_limits, %{})
      }

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      title: "Admission fixture",
      state: "In Progress"
    }

    assert {:ok, context} =
             ExecutionContext.new(target, issue,
               policy: %{
                 "delivery" => %{"pr_target" => "main"},
                 "target" => target_id
               }
             )

    context
  end

  defp all_side_effect_gates do
    %{
      "tracker_write" => "allow",
      "vcs_publish" => "allow",
      "pull_request_write" => "allow"
    }
  end

  defp maybe_put_runner_password(runner, nil), do: runner

  defp maybe_put_runner_password(runner, password) do
    Map.put(runner, "server_auth", %{"username" => "symphony", "password" => password})
  end

  defp process_identity(process_group_id) do
    %{
      "os_pid" => process_group_id,
      "process_group_id" => process_group_id,
      "wrapper_pid" => process_group_id - 1,
      "started_at" => "Wed Aug 26 17:00:00 2026"
    }
  end

  defp token_limits(per_run, daily, weekly) do
    %{
      "per_run" => %{"max_total_tokens" => per_run},
      "daily" => %{"max_total_tokens" => daily},
      "weekly" => %{"max_total_tokens" => weekly}
    }
  end

  defp unix_ms!(timestamp) do
    {:ok, datetime, 0} = DateTime.from_iso8601(timestamp)
    DateTime.to_unix(datetime, :millisecond)
  end

  defp hash(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end

  defp database_bytes(database_path) do
    [database_path, database_path <> "-wal", database_path <> "-shm"]
    |> Enum.filter(&File.regular?/1)
    |> Enum.map_join(&File.read!/1)
  end

  defp scalar_query!(database_path, sql) do
    {:ok, connection} = Sqlite3.open(database_path, mode: :readonly)
    {:ok, statement} = Sqlite3.prepare(connection, sql)
    {:row, [value]} = Sqlite3.step(connection, statement)
    :ok = Sqlite3.release(connection, statement)
    :ok = Sqlite3.close(connection)
    value
  end

  defp start_unlinked(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start(ControlPlane, opts, name: name)
  end

  defp start_control_plane!(config_root, opts \\ []) do
    child_opts =
      opts
      |> Keyword.put(:config_root, config_root)
      |> Keyword.put(:name, unique_name())

    start_supervised!({ControlPlane, child_opts}, restart: :temporary)
  end

  defp seed_database!(database_path, sql) do
    File.mkdir_p!(Path.dirname(database_path))
    {:ok, connection} = Sqlite3.open(database_path)
    :ok = Sqlite3.execute(connection, sql)
    :ok = Sqlite3.close(connection)
    File.chmod!(database_path, 0o600)
  end

  defp execute_sql!(database_path, sql) do
    {:ok, connection} = Sqlite3.open(database_path)
    :ok = Sqlite3.execute(connection, sql)
    :ok = Sqlite3.close(connection)
  end

  defp read_user_version!(database_path) do
    {:ok, connection} = Sqlite3.open(database_path, mode: :readonly)
    {:ok, statement} = Sqlite3.prepare(connection, "PRAGMA user_version")
    {:row, [version]} = Sqlite3.step(connection, statement)
    :ok = Sqlite3.release(connection, statement)
    :ok = Sqlite3.close(connection)
    version
  end

  defp permissions(path) do
    path
    |> File.stat!()
    |> Map.fetch!(:mode)
    |> band(0o777)
  end

  defp stop_process(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end

  defp unique_name, do: {:global, {__MODULE__, make_ref()}}

  defp test_clock!(initial_value) do
    clock_state =
      start_supervised!(
        {Agent, fn -> initial_value end},
        id: {__MODULE__, :clock, make_ref()}
      )

    {clock_state, fn -> Agent.get(clock_state, & &1) end}
  end

  defp set_clock!(clock_state, value) do
    Agent.update(clock_state, fn _current -> value end)
  end

  defp hold_write_lock(server) do
    parent = self()

    Task.async(fn ->
      ControlPlane.transaction(server, fn _transaction ->
        send(parent, {:write_lock_held, self()})

        receive do
          :release_write_lock -> {:ok, :released}
        after
          2_000 -> {:error, :release_timeout}
        end
      end)
    end)
  end

  defp tmp_root!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
