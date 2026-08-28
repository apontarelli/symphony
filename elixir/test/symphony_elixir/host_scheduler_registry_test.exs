defmodule SymphonyElixir.HostSchedulerRegistryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ControlPlane
  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.HostScheduler
  alias SymphonyElixir.HostScheduler.Grant
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunAuthority
  alias SymphonyElixir.TargetContext
  alias SymphonyElixir.TrackerCoordinator

  import SymphonyElixir.TestSupport, only: [eventually: 1]

  @tag :tmp_dir
  test "bounds concurrent target polls and isolates connection backoff", %{tmp_dir: tmp_dir} do
    generation = hash("multi-target")

    contexts = %{
      "alpha" => target_context(tmp_dir, "alpha", generation, "shared"),
      "beta" => target_context(tmp_dir, "beta", generation, "shared"),
      "gamma" => target_context(tmp_dir, "gamma", generation, "isolated")
    }

    scheduler = start_registry_scheduler(contexts, generation, polls: 1, agents: 1)

    Enum.each(contexts, fn {_target_id, context} ->
      HostScheduler.register_target(scheduler, context, self())
    end)

    assert %Grant{target_id: "alpha"} = alpha = receive_grant()
    assert HostScheduler.snapshot(scheduler).counts.polls == 1
    refute_receive {:"$gen_cast", {:dispatch_grant, %Grant{}}}, 20

    assert :ok = HostScheduler.reserve_dispatch(alpha)
    assert :ok = HostScheduler.finish_poll(alpha, {:defer, 100})

    assert %Grant{target_id: "gamma"} = gamma = receive_grant()
    assert {:error, :capacity} = HostScheduler.reserve_dispatch(gamma)
    assert :ok = HostScheduler.finish_poll(gamma, false)
    refute_receive {:"$gen_cast", {:dispatch_grant, %Grant{target_id: "beta"}}}, 50

    assert :ok = HostScheduler.release_all(alpha)
    assert %Grant{target_id: "beta"} = beta = receive_grant(500)
    assert :ok = HostScheduler.finish_poll(beta, false)
  end

  test "paused draining and retired targets receive no grant" do
    generation = hash("lifecycle-gates")

    contexts = %{
      "active" => target_context("/tmp", "active", generation, "active", :active),
      "draining" => target_context("/tmp", "draining", generation, "draining", :draining),
      "paused" => target_context("/tmp", "paused", generation, "paused", :paused),
      "retired" => target_context("/tmp", "retired", generation, "retired", :retired)
    }

    scheduler = start_registry_scheduler(contexts, generation, polls: 4)

    Enum.each(contexts, fn {_target_id, context} ->
      HostScheduler.register_target(scheduler, context, self())
    end)

    assert %Grant{target_id: "active"} = grant = receive_grant()
    assert :ok = HostScheduler.finish_poll(grant, false)
    refute_receive {:"$gen_cast", {:dispatch_grant, %Grant{}}}, 50
  end

  test "reload fences pause and drain before explicit reactivation" do
    generation_a = hash("lifecycle-active")
    generation_b = hash("lifecycle-paused")
    generation_c = hash("lifecycle-draining")
    generation_d = hash("lifecycle-reactivated")
    active = target_context("/tmp", "alpha", generation_a, "shared", :active)
    paused = target_context("/tmp", "alpha", generation_b, "shared", :paused)
    draining = target_context("/tmp", "alpha", generation_c, "shared", :draining)
    reactivated = target_context("/tmp", "alpha", generation_d, "shared", :active)

    {:ok, source} =
      Agent.start_link(fn -> {:ok, loaded(%{"alpha" => active}, generation_a, polls: 1)} end)

    scheduler = unique_name(LifecycleReload)

    start_supervised!(
      {HostScheduler,
       name: scheduler, registry_path: "/synthetic/lifecycle-registry.yml", registry_loader: fn _path -> Agent.get(source, & &1) end, registry_reload_interval_ms: 10, target_supervisor: false}
    )

    HostScheduler.register_target(scheduler, active, self())
    assert %Grant{} = active_grant = receive_grant()
    assert :ok = HostScheduler.reserve_dispatch(active_grant)

    Agent.update(source, fn _current ->
      {:ok, loaded(%{"alpha" => paused}, generation_b, polls: 1)}
    end)

    assert_receive {:"$gen_cast", {:apply_target_context, ^paused}}, 1_000

    assert eventually(fn ->
             case HostScheduler.snapshot(scheduler) do
               %{
                 counts: %{agents: 1, startups: 1, polls: 0},
                 targets: %{
                   "alpha" => %{
                     configured_state: :paused,
                     effective_state: :paused,
                     generation: ^generation_b
                   }
                 }
               } = snapshot ->
                 snapshot

               _other ->
                 nil
             end
           end)

    assert {:error, :stale_grant} = HostScheduler.reserve_dispatch(active_grant)
    assert %{queued: true, coalesced: true} = HostScheduler.request_poll(scheduler, "alpha")
    assert :ok = HostScheduler.release_all(active_grant)
    assert eventually(fn -> HostScheduler.snapshot(scheduler).counts.agents == 0 end)

    Agent.update(source, fn _current ->
      {:ok, loaded(%{"alpha" => draining}, generation_c, polls: 1)}
    end)

    assert_receive {:"$gen_cast", {:apply_target_context, ^draining}}, 1_000
    assert %{queued: true, coalesced: true} = HostScheduler.request_poll(scheduler, "alpha")
    assert %{queued: true, coalesced: false} = HostScheduler.request_retry(scheduler, "alpha")
    assert %Grant{registry_generation: ^generation_c} = draining_grant = receive_grant()
    assert :ok = HostScheduler.finish_poll(draining_grant, false)

    Agent.update(source, fn _current ->
      {:ok, loaded(%{"alpha" => reactivated}, generation_d, polls: 1)}
    end)

    assert_receive {:"$gen_cast", {:apply_target_context, ^reactivated}}, 1_000
    assert %{queued: true, coalesced: true} = HostScheduler.request_poll(scheduler, "alpha")
    refute_receive {:"$gen_cast", {:dispatch_grant, %Grant{}}}, 30

    :ok = HostScheduler.activate_target(scheduler, reactivated, false)
    assert %Grant{registry_generation: ^generation_d} = resumed_grant = receive_grant()
    assert :ok = HostScheduler.finish_poll(resumed_grant, false)
  end

  test "reload failure fences grants and stale target registration" do
    generation_a = hash("generation-a")
    generation_b = hash("generation-b")
    context_a = target_context("/tmp", "alpha", generation_a, "shared")
    context_b = target_context("/tmp", "alpha", generation_b, "shared")
    {:ok, source} = Agent.start_link(fn -> {:ok, loaded(%{"alpha" => context_a}, generation_a, polls: 1)} end)

    scheduler = unique_name(Reload)

    start_supervised!(
      {HostScheduler, name: scheduler, registry_path: "/synthetic/registry.yml", registry_loader: fn _path -> Agent.get(source, & &1) end, registry_reload_interval_ms: 10, target_supervisor: false}
    )

    HostScheduler.register_target(scheduler, context_a, self())
    assert %Grant{registry_generation: ^generation_a} = stale = receive_grant()

    Agent.update(source, fn _current -> {:error, :unreadable} end)

    assert eventually(fn ->
             case HostScheduler.snapshot(scheduler).registry do
               %{generation: ^generation_a, verified?: false, error: :unreadable} = registry -> registry
               _other -> nil
             end
           end)

    assert {:error, :stale_grant} = HostScheduler.reserve_dispatch(stale)
    assert :ok = HostScheduler.finish_poll(stale, false)
    assert %{queued: true, coalesced: true} = HostScheduler.request_poll(scheduler, "alpha")

    Agent.update(source, fn _current -> {:ok, loaded(%{"alpha" => context_b}, generation_b, polls: 1)} end)

    assert eventually(fn ->
             case HostScheduler.snapshot(scheduler).registry do
               %{generation: ^generation_b, verified?: true, error: nil} = registry -> registry
               _other -> nil
             end
           end)

    stale_target =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(stale_target, :stop) end)

    HostScheduler.register_target(scheduler, context_b, self())
    HostScheduler.register_target(scheduler, context_a, stale_target)

    assert %{pid: current_pid, generation: ^generation_b} =
             HostScheduler.snapshot(scheduler).targets["alpha"]

    assert current_pid == self()
    assert %Grant{registry_generation: ^generation_b} = current = receive_grant()
    assert :ok = HostScheduler.finish_poll(current, false)
  end

  @tag :tmp_dir
  test "budgeted dispatch requires a durable reservation proof", %{tmp_dir: tmp_dir} do
    target = budgeted_target_context(tmp_dir, "alpha")
    issue = issue("shared-issue", "SID-442")
    assert {:ok, context} = ExecutionContext.new(target, issue, policy: dispatch_policy())

    control_plane = unique_name(ControlPlane)
    start_supervised!({ControlPlane, name: control_plane, config_root: tmp_dir})
    assert {:ok, authority} = RunAuthority.admit(control_plane, "budget-owner", context)

    scheduler = unique_name(Budget)

    scheduler_opts = [
      name: scheduler,
      target_context: target,
      target_supervisor: false,
      limits: %{polls: %{interval_ms: 50_000}}
    ]

    start_supervised!({HostScheduler, scheduler_opts})

    HostScheduler.register_target(scheduler, target, self())
    assert %Grant{} = grant = receive_grant()
    assert :ok = HostScheduler.reserve_dispatch(grant)
    assert :ok = HostScheduler.confirm_budget(grant, authority)
    assert :ok = HostScheduler.release_all(grant)
    assert :ok = RunAuthority.release(authority)
  end

  @tag :tmp_dir
  test "duplicate tracker issue IDs retain target-scoped run and lease identity", %{tmp_dir: tmp_dir} do
    generation = hash("duplicate-identity")
    issue = issue("same-id", "SID-442")
    alpha = complete_target_context(tmp_dir, "alpha", generation, "shared", %{})
    beta = complete_target_context(tmp_dir, "beta", generation, "shared", %{})

    assert {:ok, alpha_context} = ExecutionContext.new(alpha, issue, policy: dispatch_policy())
    assert {:ok, beta_context} = ExecutionContext.new(beta, issue, policy: dispatch_policy())
    refute ExecutionContext.run_id(alpha_context) == ExecutionContext.run_id(beta_context)
    refute alpha_context.workspace_path == beta_context.workspace_path

    state_path = Path.join(tmp_dir, "shared-tracker.state")
    assert :ok = TrackerCoordinator.claim_issue(alpha, issue, "alpha-owner", state_path: state_path)
    assert :ok = TrackerCoordinator.claim_issue(beta, issue, "beta-owner", state_path: state_path)

    assert %{leases: leases} = TrackerCoordinator.snapshot(state_path: state_path)

    assert Enum.sort(Enum.map(leases, &{&1.target_id, &1.issue_id})) == [
             {"alpha", "same-id"},
             {"beta", "same-id"}
           ]
  end

  defp start_registry_scheduler(contexts, generation, opts) do
    scheduler = unique_name(Registry)
    loaded = loaded(contexts, generation, opts)

    scheduler_opts = [
      name: scheduler,
      registry_path: "/synthetic/registry.yml",
      registry_loader: fn _path -> {:ok, loaded} end,
      registry_reload_interval_ms: 50_000,
      target_supervisor: false
    ]

    start_supervised!({HostScheduler, scheduler_opts})

    scheduler
  end

  defp loaded(contexts, generation, opts) do
    polls = Keyword.get(opts, :polls, 1)
    agents = Keyword.get(opts, :agents, 4)

    %{
      snapshot: %{
        generation: generation,
        host: %{
          "polling" => %{"interval_ms" => 1, "max_concurrent_target_polls" => polls},
          "capacity" => %{
            "max_concurrent_agents" => agents,
            "max_concurrent_startups" => agents,
            "max_concurrent_reviewers" => agents
          },
          "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 2},
          "runners" => %{
            "runner-alpha" => %{"max_concurrent_agents" => agents, "max_concurrent_startups" => agents},
            "runner-beta" => %{"max_concurrent_agents" => agents, "max_concurrent_startups" => agents}
          }
        }
      },
      contexts: contexts,
      weights: contexts |> Map.keys() |> Enum.sort() |> Enum.map(&{&1, if(&1 == "beta", do: 3, else: 1)})
    }
  end

  defp target_context(root, target_id, generation, connection_id, state \\ :active) do
    %TargetContext{
      target_id: target_id,
      state: state,
      dispatch_mode: :watch,
      registry_generation: generation,
      policy_hash: hash("policy-#{target_id}"),
      repo_manifest_hash: hash("manifest-#{target_id}"),
      repo_policy: %{},
      tracker_connection: %{"id" => connection_id},
      run_target: %{},
      worktree_policy: %{"root" => Path.join(root, "worktrees")},
      runner_policy: %{"default" => "runner-alpha"},
      effective_checks: %{},
      external_side_effect_gates: %{},
      capacity_limits: %{
        "max_concurrent_agents" => 1,
        "max_concurrent_startups" => 1,
        "max_concurrent_reviewers" => 1,
        "poll_interval_ms" => 1
      },
      budget_limits: %{}
    }
  end

  defp budgeted_target_context(root, target_id) do
    complete_target_context(root, target_id, hash("budget-generation"), "linear", %{
      "per_run" => %{"max_total_tokens" => 100},
      "daily" => %{"max_total_tokens" => 500},
      "weekly" => %{"max_total_tokens" => 1_000}
    })
  end

  defp complete_target_context(root, target_id, generation, connection_id, budgets) do
    workspace_root = Path.join(root, "worktrees")
    File.mkdir_p!(workspace_root)

    %TargetContext{
      target_id: target_id,
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: generation,
      policy_hash: hash("policy-#{target_id}"),
      repo_manifest_hash: hash("manifest-#{target_id}"),
      repo_policy: %{
        "manifest" => %{"version" => 1},
        "manifest_source_dir" => root,
        "workflow_module_resolution" => %{}
      },
      tracker_connection: %{
        "id" => connection_id,
        "policy" => %{
          "kind" => "linear",
          "endpoint" => "https://tracker.example.invalid/graphql",
          "api_key" => "$TRACKER_KEY"
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
        "default" => "runner-alpha",
        "allowed" => ["runner-alpha"],
        "runners" => %{
          "runner-alpha" => %{
            "kind" => "codex_app_server",
            "command" => ["codex", "app-server"],
            "turn_timeout_ms" => 30_000,
            "execution_profiles" => %{
              "implementation" => %{
                "model" => "model-#{target_id}",
                "timeout_ms" => 30_000,
                "max_retries" => 1
              }
            }
          }
        }
      },
      effective_checks: %{"pre_handoff" => ["mix test"]},
      external_side_effect_gates: %{
        "tracker_write" => "allow",
        "vcs_publish" => "allow",
        "pull_request_write" => "allow"
      },
      capacity_limits: %{
        "max_concurrent_agents" => 1,
        "max_concurrent_startups" => 1,
        "max_concurrent_reviewers" => 1
      },
      budget_limits: budgets
    }
  end

  defp issue(id, identifier) do
    %Issue{id: id, identifier: identifier, title: "Shared issue", state: "In Progress"}
  end

  defp dispatch_policy do
    %{"delivery" => %{"pr_target" => "main"}, "target" => "registry-test"}
  end

  defp receive_grant(timeout \\ 1_000) do
    assert_receive {:"$gen_cast", {:dispatch_grant, %Grant{} = grant}}, timeout
    grant
  end

  defp unique_name(suffix),
    do: Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")

  defp hash(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
