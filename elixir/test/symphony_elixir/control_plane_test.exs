defmodule SymphonyElixir.ControlPlaneTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Exqlite.Sqlite3
  alias SymphonyElixir.ControlPlane
  alias SymphonyElixir.ControlPlane.{Error, Lease, Lifecycle, LifecycleTransition}
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
              schema_version: 4,
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

    assert Enum.all?(pids, fn pid -> match?({:ok, %{schema_version: 4}}, ControlPlane.health(pid)) end)
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

  test "version one stores migrate through admission, lease, and lifecycle schemas" do
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

    assert {:ok, %{schema_version: 4, status: :healthy}} = ControlPlane.health(server)
    assert scalar_query!(database_path, "SELECT count(*) FROM run_leases") == 0
    assert scalar_query!(database_path, "SELECT count(*) FROM run_admissions") == 0
    assert scalar_query!(database_path, "SELECT count(*) FROM run_lifecycles") == 0
    assert scalar_query!(database_path, "SELECT count(*) FROM run_lifecycle_transitions") == 0
  end

  test "a newer schema version stops startup with an actionable error" do
    config_root = tmp_root!("control-plane-newer-schema")
    database_path = ControlPlane.path(config_root: config_root)
    seed_database!(database_path, "PRAGMA user_version = 5")

    assert {:error,
            %Error{
              code: :unsupported_schema_version,
              path: ^database_path,
              message: message
            }} = start_unlinked(config_root: config_root, name: unique_name())

    assert message =~ "schema version 5 is newer than supported version 4"
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
        external_side_effect_gates: %{
          "tracker_write" => "allow",
          "vcs_publish" => "deny"
        },
        capacity_limits: %{"max_concurrent_agents" => 1},
        budget_limits: %{}
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

  defp maybe_put_runner_password(runner, nil), do: runner

  defp maybe_put_runner_password(runner, password) do
    Map.put(runner, "server_auth", %{"username" => "symphony", "password" => password})
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
