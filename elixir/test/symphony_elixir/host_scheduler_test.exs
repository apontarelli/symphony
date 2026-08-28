defmodule SymphonyElixir.HostSchedulerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.HostScheduler
  alias SymphonyElixir.HostScheduler.Grant
  alias SymphonyElixir.TargetContext
  import SymphonyElixir.TestSupport, only: [eventually: 1]

  test "one grant reserves and idempotently releases host slots" do
    scheduler = unique_name(Slots)
    target = target_context("single-target", 50_000)

    start_supervised!(
      {HostScheduler,
       name: scheduler,
       target_context: target,
       target_supervisor: false,
       limits: %{
         agents: 1,
         startups: 1,
         reviewers: 1,
         polls: %{max_concurrent: 1, interval_ms: 50_000}
       }}
    )

    assert :ok = HostScheduler.register_target(scheduler, target, self())
    assert_receive {:"$gen_cast", {:dispatch_grant, %Grant{} = grant}}, 1_000
    assert HostScheduler.snapshot(scheduler).counts == %{agents: 0, startups: 0, reviewers: 0, polls: 1}

    assert :ok = HostScheduler.reserve_dispatch(grant)
    assert {:error, :stale_grant} = HostScheduler.reserve_dispatch(grant)
    assert HostScheduler.snapshot(scheduler).counts == %{agents: 1, startups: 1, reviewers: 0, polls: 1}

    assert :ok = HostScheduler.release_startup(grant)
    assert :ok = HostScheduler.release_startup(grant)
    assert HostScheduler.snapshot(scheduler).counts.startups == 0

    assert {:ok, reviewer} = HostScheduler.reserve_reviewer(scheduler, target.target_id, self())
    assert {:error, :capacity} = HostScheduler.reserve_reviewer(scheduler, target.target_id, self())
    assert HostScheduler.snapshot(scheduler).counts.reviewers == 1
    assert :ok = HostScheduler.release_reviewer(scheduler, reviewer)
    assert :ok = HostScheduler.release_reviewer(scheduler, reviewer)

    assert :ok = HostScheduler.finish_poll(grant, false)
    assert HostScheduler.snapshot(scheduler).counts == %{agents: 1, startups: 0, reviewers: 0, polls: 0}
    assert :ok = HostScheduler.release_all(grant)
    assert :ok = HostScheduler.release_all(grant)
    assert HostScheduler.snapshot(scheduler).counts == %{agents: 0, startups: 0, reviewers: 0, polls: 0}
    assert HostScheduler.snapshot(scheduler).grants == 0
  end

  test "poll timing remains available while an agent slot is held" do
    scheduler = unique_name(Polling)
    target = target_context("polling-target", 10)

    start_supervised!(
      {HostScheduler,
       name: scheduler,
       target_context: target,
       target_supervisor: false,
       limits: %{
         agents: 1,
         startups: 1,
         polls: %{max_concurrent: 1, interval_ms: 10}
       }}
    )

    HostScheduler.register_target(scheduler, target, self())
    assert_receive {:"$gen_cast", {:dispatch_grant, %Grant{} = first}}, 1_000
    assert :ok = HostScheduler.reserve_dispatch(first)
    assert :ok = HostScheduler.finish_poll(first, true)

    assert_receive {:"$gen_cast", {:dispatch_grant, %Grant{} = second}}, 1_000
    assert second.id != first.id
    assert {:error, :capacity} = HostScheduler.reserve_dispatch(second)
    assert :ok = HostScheduler.finish_poll(second, false)
    assert :ok = HostScheduler.release_all(first)
  end

  test "refresh requests coalesce and target exit returns every slot" do
    scheduler = unique_name(TargetExit)
    target = target_context("exit-target", 50_000)
    parent = self()
    target_pid = spawn(fn -> forward_grants(parent) end)

    scheduler_options = [
      name: scheduler,
      target_context: target,
      target_supervisor: false,
      limits: %{polls: %{interval_ms: 50_000}}
    ]

    start_supervised!({HostScheduler, scheduler_options})

    assert %{queued: true, coalesced: true} = HostScheduler.request_poll(scheduler, "wrong-target")
    HostScheduler.register_target(scheduler, %{target | target_id: "wrong-target"}, self())
    refute_receive {:forwarded_grant, _grant}, 20

    HostScheduler.register_target(scheduler, target, target_pid)
    assert_receive {:forwarded_grant, %Grant{} = grant}, 1_000
    assert :ok = HostScheduler.reserve_dispatch(grant)
    assert %{queued: true, coalesced: true} = HostScheduler.request_poll(scheduler, target.target_id)

    Process.exit(target_pid, :kill)

    assert eventually(fn ->
             case HostScheduler.snapshot(scheduler) do
               %{counts: %{agents: 0, startups: 0, reviewers: 0, polls: 0}, grants: 0} = snapshot -> snapshot
               _other -> nil
             end
           end)
  end

  test "target replacement clears slots held by the previous process" do
    scheduler = unique_name(TargetReplacement)
    target = target_context("replacement-target", 50_000)
    parent = self()
    first_target = spawn(fn -> forward_grants(parent) end)
    second_target = spawn(fn -> forward_grants(parent) end)

    on_exit(fn ->
      send(first_target, :stop)
      send(second_target, :stop)
    end)

    scheduler_options = [
      name: scheduler,
      target_context: target,
      target_supervisor: false,
      limits: %{reviewers: 1, polls: %{interval_ms: 50_000}}
    ]

    start_supervised!({HostScheduler, scheduler_options})

    HostScheduler.register_target(scheduler, target, first_target)
    assert_receive {:forwarded_grant, %Grant{} = first_grant}, 1_000
    assert :ok = HostScheduler.reserve_dispatch(first_grant)
    assert {:ok, _reviewer} = HostScheduler.reserve_reviewer(scheduler, target.target_id, first_target)

    HostScheduler.register_target(scheduler, target, second_target)
    assert_receive {:forwarded_grant, %Grant{} = second_grant}, 1_000

    assert {:error, :stale_grant} = HostScheduler.reserve_dispatch(first_grant)

    assert HostScheduler.snapshot(scheduler).counts == %{
             agents: 0,
             startups: 0,
             reviewers: 0,
             polls: 1
           }

    assert :ok = HostScheduler.finish_poll(second_grant, false)
    assert HostScheduler.snapshot(scheduler).grants == 0
  end

  test "manual refresh schedules an immediate poll when idle" do
    scheduler = unique_name(Refresh)
    target = target_context("refresh-target", 50_000)

    scheduler_options = [
      name: scheduler,
      target_context: target,
      target_supervisor: false,
      limits: %{polls: %{interval_ms: 50_000}}
    ]

    start_supervised!({HostScheduler, scheduler_options})

    HostScheduler.register_target(scheduler, target, self())
    assert_receive {:"$gen_cast", {:dispatch_grant, %Grant{} = first}}, 1_000
    assert :ok = HostScheduler.finish_poll(first, false)

    assert %{queued: true, coalesced: false} = HostScheduler.request_poll(scheduler, target.target_id)
    assert_receive {:"$gen_cast", {:dispatch_grant, %Grant{} = second}}, 1_000
    assert second.id > first.id
    assert :ok = HostScheduler.finish_poll(second, false)
  end

  test "starts without a target and rejects invalid policy" do
    scheduler = unique_name(Empty)
    start_supervised!({HostScheduler, name: scheduler, target_context: nil})
    assert HostScheduler.snapshot(scheduler).grants == 0

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error, :invalid_policy} =
               HostScheduler.start_link(
                 name: unique_name(Invalid),
                 target_context: target_context("invalid-target", 1_000),
                 target_supervisor: false,
                 target_weight: 0
               )
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp forward_grants(parent) do
    receive do
      {:"$gen_cast", {:dispatch_grant, grant}} ->
        send(parent, {:forwarded_grant, grant})
        forward_grants(parent)

      :stop ->
        :ok
    end
  end

  defp unique_name(suffix), do: Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")

  defp target_context(target_id, poll_interval_ms) do
    hash = "sha256:" <> String.duplicate("a", 64)

    struct!(TargetContext,
      target_id: target_id,
      state: :active,
      dispatch_mode: :watch,
      registry_generation: hash,
      policy_hash: hash,
      repo_manifest_hash: hash,
      repo_policy: %{},
      tracker_connection: %{},
      run_target: %{},
      worktree_policy: %{},
      runner_policy: %{},
      effective_checks: %{},
      external_side_effect_gates: %{},
      capacity_limits: %{
        "max_concurrent_agents" => 1,
        "max_concurrent_startups" => 1,
        "poll_interval_ms" => poll_interval_ms
      },
      budget_limits: %{}
    )
  end
end
