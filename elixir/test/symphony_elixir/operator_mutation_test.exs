defmodule SymphonyElixir.OperatorMutationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{ControlPlane, ExecutionContext, HostScheduler, OperatorInterface, OperatorMutation, PathSafety}
  alias SymphonyElixir.HostScheduler.Registry
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TargetRegistry.Yaml

  @moduletag :tmp_dir
  @repo Path.expand("../fixtures/target_registry/repos/symphony", __DIR__)

  setup %{tmp_dir: root} do
    path = Path.join([root, "registry", "targets.yml"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Yaml.encode(registry(root)))

    scheduler_opts = [
      name: unique_name(),
      registry_path: path,
      target_supervisor: false,
      registry_reload_interval_ms: 60_000
    ]

    scheduler = start_supervised!({HostScheduler, scheduler_opts})

    control_plane = start_supervised!({ControlPlane, name: unique_name(), config_root: root})

    interface =
      start_supervised!({OperatorInterface, name: unique_name(), config_root: root, install_log_handler: false})

    {:ok, metadata} = OperatorInterface.credentials(interface)
    credential = File.read!(metadata.token_path)
    {:ok, loaded} = Registry.load(path)
    opts = [host_scheduler: scheduler, control_plane: control_plane, config_root: root]

    %{
      scheduler: scheduler,
      control_plane: control_plane,
      interface: interface,
      credential: credential,
      opts: opts,
      path: path,
      target: loaded.contexts["alpha"],
      root: root
    }
  end

  test "watch activation is previewed and committed with its dispatch mode", context do
    command = %{"action" => "activate", "target_id" => "alpha", "inputs" => %{"dispatch_mode" => "watch"}}
    {request, preview} = preview!(context, command)
    assert preview.proposed_state.target["dispatch_mode"] == "watch"
    assert confirm!(context, request, preview).status == "completed"
    assert HostScheduler.snapshot(context.scheduler).targets["alpha"].operator.dispatch_mode == :watch
  end

  test "invalid target policy remains a disabled preview and cannot be committed", context do
    command = %{"action" => "patch", "target_id" => "alpha", "inputs" => %{"changes" => %{"concurrency" => %{"max_concurrent_agents" => 0}}}}
    {_request, preview} = preview!(context, command)
    assert preview.disabled_reason == "plan_not_applicable"
    assert preview.confirmation_token == nil
    assert HostScheduler.snapshot(context.scheduler).targets["alpha"].limits.agents == 2
  end

  test "capacity reduction describes numeric consequences before changing host limits", context do
    command = %{"action" => "patch", "target_id" => "alpha", "inputs" => %{"changes" => %{"concurrency" => %{"max_concurrent_agents" => 1}}}}
    {request, preview} = preview!(context, command)
    assert Enum.any?(preview.consequences, &String.contains?(&1, "2 -> 1"))
    assert confirm!(context, request, preview).status == "completed"
    assert HostScheduler.snapshot(context.scheduler).targets["alpha"].limits.agents == 1
  end

  test "repository branch changes require the matching completed catalog", context do
    {context, repo} = branch_context(context)
    branch = "release/2026"
    catalog = branch_scan!(context, repo, branch)

    command = %{
      "action" => "patch",
      "target_id" => "alpha",
      "inputs" => %{"changes" => %{"repo" => %{"branch" => branch}}}
    }

    request = mutation_request(context, command, catalog.scan_id)

    assert {:ok, preview} =
             OperatorInterface.preview(context.interface, context.credential, request, context.opts)

    assert preview.proposed_state.preview["branch_selection"] == %{
             "repository" => canonical!(repo),
             "branch" => branch
           }

    assert confirm!(context, request, preview).status == "completed"
    {:ok, document} = Yaml.decode(File.read!(context.path))
    assert get_in(document, ["targets", "alpha", "repo", "branch"]) == branch
  end

  test "repository branch preview fails closed without a scan or with mismatched branch", context do
    {context, repo} = branch_context(context)
    branch = "release/2026"
    command = %{"action" => "patch", "target_id" => "alpha", "inputs" => %{"changes" => %{"repo" => %{"branch" => "main"}}}}

    missing_scan = mutation_request(context, command, nil)

    assert {:error, missing} =
             OperatorInterface.preview(context.interface, context.credential, missing_scan, context.opts)

    assert missing.error.code == "branch_scan_required"

    catalog = branch_scan!(context, repo, branch)
    mismatched = mutation_request(context, command, catalog.scan_id)

    assert {:error, stale} =
             OperatorInterface.preview(context.interface, context.credential, mismatched, context.opts)

    assert stale.error.code == "branch_catalog_stale"

    matching = branch_scan!(context, repo, "main")
    request = mutation_request(context, command, matching.scan_id)
    assert {:ok, preview} = OperatorInterface.preview(context.interface, context.credential, request, context.opts)
    assert confirm!(context, request, preview).status == "completed"
  end

  test "repository branch preview rejects a catalog from another repository", context do
    {context, repo} = branch_context(context)
    other_repo = Path.join(System.tmp_dir!(), "operator-branch-other-#{System.unique_integer([:positive])}")
    File.cp_r!(repo, other_repo)
    on_exit(fn -> File.rm_rf(other_repo) end)
    catalog = branch_scan!(context, other_repo, "main")
    command = %{"action" => "patch", "target_id" => "alpha", "inputs" => %{"changes" => %{"repo" => %{"branch" => "main"}}}}
    request = mutation_request(context, command, catalog.scan_id)

    assert {:error, stale} =
             OperatorInterface.preview(context.interface, context.credential, request, context.opts)

    assert stale.error.code == "branch_catalog_stale"
  end

  test "repository branch confirmation rejects a refreshed or cancelled catalog", context do
    for stale_action <- [:refresh, :cancel] do
      {context, repo} = branch_context(context)
      catalog = branch_scan!(context, repo, "main")
      command = %{"action" => "patch", "target_id" => "alpha", "inputs" => %{"changes" => %{"repo" => %{"branch" => "main"}}}}
      request = mutation_request(context, command, catalog.scan_id)

      assert {:ok, preview} =
               OperatorInterface.preview(context.interface, context.credential, request, context.opts)

      case stale_action do
        :refresh ->
          refreshed = branch_scan!(context, repo, "main")
          refute refreshed.scan_id == catalog.scan_id

        :cancel ->
          assert {:ok, cancelled} =
                   OperatorInterface.repositories(
                     context.interface,
                     context.credential,
                     %{"action" => "cancel", "scan_id" => catalog.scan_id},
                     context.scheduler
                   )

          assert cancelled.status == "cancelled"
      end

      assert {:error, stale} =
               OperatorInterface.confirm(
                 context.interface,
                 context.credential,
                 Map.put(request, "confirmation_token", preview.confirmation_token)
               )

      assert stale.error.code == "branch_catalog_stale"
    end
  end

  test "repository branch confirmation tokens bind the catalog scan ID", context do
    {context, repo} = branch_context(context)
    catalog = branch_scan!(context, repo, "main")
    command = %{"action" => "patch", "target_id" => "alpha", "inputs" => %{"changes" => %{"repo" => %{"branch" => "main"}}}}
    request = mutation_request(context, command, catalog.scan_id)

    assert {:ok, preview} =
             OperatorInterface.preview(context.interface, context.credential, request, context.opts)

    mismatched_request =
      request
      |> Map.put("branch_scan_id", "scan-not-the-previewed-catalog")
      |> Map.put("confirmation_token", preview.confirmation_token)

    assert {:error, mismatch} =
             OperatorInterface.confirm(context.interface, context.credential, mismatched_request)

    assert mismatch.error.code == "confirmation_mismatch"
  end

  test "target mutation requires a durable registry and run recovery requires an existing run", context do
    empty = start_supervised!({HostScheduler, name: unique_name(), target_supervisor: false}, id: :empty_scheduler)
    opts = Keyword.put(mutation_opts(context), :host_scheduler, empty)

    assert {:error, :registry_not_configured} =
             OperatorMutation.preview(%{"action" => "retire", "target_id" => "alpha", "inputs" => %{}}, opts)

    assert {:error, :admission_not_found} =
             OperatorMutation.preview(%{"action" => "resume_run", "run_id" => "missing", "inputs" => %{}}, mutation_opts(context))
  end

  test "changed scheduler generation invalidates a prepared command", context do
    opts = mutation_opts(context)
    {:ok, prepared} = OperatorMutation.preview(%{"action" => "refresh", "inputs" => %{}}, opts)
    File.write!(context.path, File.read!(context.path) <> "\n# refreshed generation\n")
    assert {:ok, _} = HostScheduler.reload(context.scheduler)

    assert {:error, %{code: :stale_generation, state_may_have_changed: false}} =
             OperatorMutation.confirm(prepared, opts)
  end

  test "registry reload failure after commit reports the persisted mutation", context do
    fail_reload = start_supervised!({Agent, fn -> false end})

    loader = fn path ->
      if Agent.get(fail_reload, & &1), do: {:error, :eacces}, else: Registry.load(path)
    end

    scheduler =
      start_supervised!({HostScheduler, name: unique_name(), registry_path: context.path, registry_loader: loader, target_supervisor: false, registry_reload_interval_ms: 60_000},
        id: :reload_failure
      )

    context = %{context | scheduler: scheduler, opts: Keyword.put(context.opts, :host_scheduler, scheduler)}
    {request, preview} = preview!(context, %{"action" => "retire", "target_id" => "alpha", "inputs" => %{}})
    Agent.update(fail_reload, fn _ -> true end)

    result = confirm!(context, request, preview)
    assert result.status == "failed"
    assert result.error.code == "scheduler_reload_failed"
    assert result.state_may_have_changed
    {:ok, document} = Yaml.decode(File.read!(context.path))
    assert document["targets"]["alpha"]["state"] == "retired"
  end

  test "work acquired after shutdown preview prevents shutdown confirmation", context do
    for {action, inputs} <- [{"activate", %{"dispatch_mode" => "explicit"}}, {"drain", %{}}] do
      {request, preview} = preview!(context, %{"action" => action, "target_id" => "alpha", "inputs" => inputs})
      assert confirm!(context, request, preview).status == "completed"
    end

    {:ok, loaded} = Registry.load(context.path)
    HostScheduler.register_target(context.scheduler, loaded.contexts["alpha"], self())
    {request, preview} = preview!(context, %{"action" => "shutdown", "inputs" => %{}})
    assert %{queued: true, coalesced: false} = HostScheduler.request_retry(context.scheduler, "alpha")
    assert_receive {:"$gen_cast", {:dispatch_grant, grant}}, 1_000
    result = confirm!(context, request, preview)
    assert result.status == "failed"
    assert result.error.code == "work_in_progress"
    refute result.state_may_have_changed
    refute HostScheduler.snapshot(context.scheduler).shutdown.requested?
    :ok = HostScheduler.finish_poll(grant, false)
  end

  test "invalid authority configuration and unknown bindings fail without leaking details", context do
    opts = mutation_opts(context)

    assert {:error, %{code: :authority_unavailable, state_may_have_changed: true}} =
             OperatorMutation.preview(%{"action" => "prune", "inputs" => %{}}, Keyword.put(opts, :config_root, 123))

    {:ok, prepared} = OperatorMutation.preview(%{"action" => "refresh", "inputs" => %{}}, opts)
    prepared = put_in(prepared, [:binding, :kind], :unknown)
    assert {:error, :invalid_confirmation} = OperatorMutation.confirm(prepared, opts)
  end

  test "operator diagnostics omit live confirmation tokens and credential locations", context do
    {request, preview} = preview!(context, %{"action" => "refresh", "inputs" => %{}})

    for diagnostic <- [inspect(:sys.get_state(context.interface)), inspect(:sys.get_status(context.interface))] do
      assert diagnostic =~ request["host_id"]
      refute diagnostic =~ preview.confirmation_token
      refute diagnostic =~ context.credential
      refute diagnostic =~ context.root
    end
  end

  test "rejects malformed commands and confirmations before consulting authorities", context do
    opts = mutation_opts(context)

    assert {:error, :invalid_command} = OperatorMutation.preview(:not_a_command, opts)
    assert {:error, :invalid_confirmation} = OperatorMutation.confirm(:not_a_confirmation, opts)
    assert {:error, :invalid_confirmation} = OperatorMutation.confirm(%{}, opts)

    assert {:error, :invalid_inputs} =
             OperatorMutation.preview(%{"action" => "refresh"}, opts)

    assert {:error, :invalid_action} =
             OperatorMutation.preview(%{"action" => "not-an-action", "inputs" => %{}}, opts)

    assert {:error, :invalid_command} =
             OperatorMutation.preview(
               %{"action" => "refresh", "inputs" => %{}, "unexpected" => true},
               opts
             )

    assert {:error, :invalid_target_id} =
             OperatorMutation.preview(
               %{"action" => "pause", "target_id" => nil, "inputs" => %{}},
               opts
             )

    assert {:error, :invalid_run_id} =
             OperatorMutation.preview(
               %{"action" => "resume_run", "run_id" => nil, "inputs" => %{}},
               opts
             )

    assert {:error, :invalid_inputs} =
             OperatorMutation.preview(
               %{
                 "action" => "activate",
                 "target_id" => "alpha",
                 "inputs" => %{"dispatch_mode" => "unsupported"}
               },
               opts
             )

    assert {:error, :invalid_inputs} =
             OperatorMutation.preview(
               %{"action" => "patch", "target_id" => "alpha", "inputs" => %{"changes" => []}},
               opts
             )
  end

  test "fails closed when a scheduler or control-plane authority is unavailable", context do
    opts = mutation_opts(context)
    refresh = %{"action" => "refresh", "inputs" => %{}}

    assert {:error, :scheduler_unavailable} =
             OperatorMutation.preview(refresh, Keyword.put(opts, :host_scheduler, nil))

    assert {:error, :invalid_host_id} =
             OperatorMutation.preview(refresh, Keyword.put(opts, :host_id, nil))

    run_command = %{"action" => "resume_run", "run_id" => "missing-run", "inputs" => %{}}

    assert {:error, :control_plane_unavailable} =
             OperatorMutation.preview(run_command, Keyword.put(opts, :control_plane, nil))

    assert {:error, :control_plane_unavailable} =
             OperatorMutation.preview(
               %{"action" => "prune", "inputs" => %{}},
               Keyword.put(opts, :control_plane, nil)
             )

    run = admit!(context, "control-plane-unavailable")
    {:ok, prepared} = OperatorMutation.preview(run_command("resume_run", run), opts)

    assert {:error, :control_plane_unavailable} =
             OperatorMutation.confirm(prepared, Keyword.put(opts, :control_plane, nil))
  end

  test "reports an uncertain authority failure when the scheduler disappears", context do
    opts = mutation_opts(context)
    scheduler = spawn(fn -> :ok end)
    reference = Process.monitor(scheduler)
    assert_receive {:DOWN, ^reference, :process, ^scheduler, _reason}

    assert {:error, %{code: :authority_unavailable, state_may_have_changed: true}} =
             OperatorMutation.preview(
               %{"action" => "refresh", "inputs" => %{}},
               Keyword.put(opts, :host_scheduler, scheduler)
             )
  end

  test "registry edits fence both preview and confirmation", context do
    opts = mutation_opts(context)
    command = %{"action" => "retire", "target_id" => "alpha", "inputs" => %{}}
    {:ok, prepared} = OperatorMutation.preview(command, opts)
    File.write!(context.path, File.read!(context.path) <> "\n# unobserved operator edit\n")

    assert {:error, :stale_generation} = OperatorMutation.preview(command, opts)

    assert {:error, %{code: :stale_generation, state_may_have_changed: false}} =
             OperatorMutation.confirm(prepared, opts)
  end

  test "confirmation refuses to mutate after the registry becomes unverified", context do
    opts = mutation_opts(context)
    {:ok, prepared} = OperatorMutation.preview(%{"action" => "refresh", "inputs" => %{}}, opts)
    File.write!(context.path, "not: [valid: yaml")
    assert {:error, _reason} = HostScheduler.reload(context.scheduler)
    assert %{registry: %{verified?: false}} = HostScheduler.snapshot(context.scheduler)

    assert {:error, %{code: :registry_unverified, state_may_have_changed: false}} =
             OperatorMutation.confirm(prepared, opts)

    {:ok, diagnostic} = OperatorMutation.preview(%{"action" => "refresh", "inputs" => %{}}, opts)
    public_state = diagnostic.current_state |> Jason.encode!() |> Jason.decode!()
    assert public_state["registry"]["error"]["code"] == "invalid_yaml"

    invalid = put_in(registry(context.root), ["host", "state_root"], Path.dirname(context.path))
    File.write!(context.path, Yaml.encode(invalid))
    assert {:error, {:invalid_registry, _}} = HostScheduler.reload(context.scheduler)
    {:ok, diagnostic} = OperatorMutation.preview(%{"action" => "refresh", "inputs" => %{}}, opts)
    public_state = diagnostic.current_state |> Jason.encode!() |> Jason.decode!()
    assert ["invalid_registry", errors] = public_state["registry"]["error"]
    assert Enum.any?(errors, &(&1["code"] == "path_overlap"))
  end

  test "confirmation refuses refresh after shutdown has been requested", context do
    opts = mutation_opts(context)
    {:ok, prepared} = OperatorMutation.preview(%{"action" => "refresh", "inputs" => %{}}, opts)
    generation = prepared.registry_generation
    assert :ok = HostScheduler.begin_shutdown(context.scheduler, generation)

    assert {:error, %{code: :shutdown_requested, state_may_have_changed: false}} =
             OperatorMutation.confirm(prepared, opts)
  end

  test "prune rejects invalid retention configuration without exposing backend details", context do
    opts = mutation_opts(context)
    File.write!(Path.join(context.root, "config.yml"), "control_plane:\n  terminal_retention_days: 0\n")

    assert {:error, :backend_failed} =
             OperatorMutation.preview(%{"action" => "prune", "inputs" => %{}}, opts)
  end

  test "disabled target mutations preview their current state but cannot be confirmed", context do
    opts = mutation_opts(context)

    {:ok, paused} =
      OperatorMutation.preview(
        %{"action" => "pause", "target_id" => "alpha", "inputs" => %{}},
        opts
      )

    assert paused.disabled_reason == "invalid_transition"
    assert paused.current_state.target.configured_state == :paused
    assert paused.proposed_state.target == paused.current_state.target

    assert {:error, %{code: :mutation_disabled, state_may_have_changed: false}} =
             OperatorMutation.confirm(paused, opts)

    {:ok, missing} =
      OperatorMutation.preview(
        %{"action" => "retire", "target_id" => "missing-target", "inputs" => %{}},
        opts
      )

    assert missing.disabled_reason == "target_not_found"
    assert missing.current_state.target.target_id == "missing-target"
  end

  test "disabled run actions remain preview-only after a terminal transition", context do
    opts = mutation_opts(context)
    run = admit!(context, "disabled-run")
    {:ok, lease} = ControlPlane.acquire_lease(context.control_plane, run.admitted_run_id, "terminal-owner")

    assert {:ok, _lifecycle} =
             ControlPlane.transition_run(
               context.control_plane,
               lease,
               1,
               :admitted,
               :completed,
               %{disposition: "operator-completed"}
             )

    assert :ok = ControlPlane.release_lease(context.control_plane, lease)

    {:ok, prepared} =
      OperatorMutation.preview(
        %{"action" => "resume_run", "run_id" => run.admitted_run_id, "inputs" => %{}},
        opts
      )

    assert prepared.disabled_reason == "operator_action_not_allowed"
    assert prepared.proposed_state.run == prepared.current_state.run

    assert {:error, %{code: :mutation_disabled, state_may_have_changed: false}} =
             OperatorMutation.confirm(prepared, opts)
  end

  test "prune confirmation is invalidated when an eligible run gains a lease", context do
    opts = mutation_opts(context)
    run = admit!(context, "prune-race")
    {:ok, lease} = ControlPlane.acquire_lease(context.control_plane, run.admitted_run_id, "terminal-owner")

    assert {:ok, _lifecycle} =
             ControlPlane.transition_run(
               context.control_plane,
               lease,
               1,
               :admitted,
               :completed,
               %{disposition: "done"}
             )

    assert :ok = ControlPlane.release_lease(context.control_plane, lease)

    database_path = ControlPlane.path(config_root: context.root)
    {:ok, db} = Exqlite.Sqlite3.open(database_path)

    assert :ok =
             Exqlite.Sqlite3.execute(
               db,
               "UPDATE run_lifecycles SET completed_at = '1970-01-01T00:00:00Z' WHERE admitted_run_id = '#{run.admitted_run_id}'"
             )

    assert :ok = Exqlite.Sqlite3.close(db)
    File.write!(Path.join(context.root, "config.yml"), "control_plane:\n  terminal_retention_days: 30\n")

    {:ok, prepared} = OperatorMutation.preview(%{"action" => "prune", "inputs" => %{}}, opts)
    assert Enum.map(prepared.current_state.runs, & &1.admitted_run_id) == [run.admitted_run_id]

    {:ok, competing_lease} =
      ControlPlane.acquire_lease(context.control_plane, run.admitted_run_id, "competing-owner")

    assert {:error, %{code: :invalid_confirmation, state_may_have_changed: false}} =
             OperatorMutation.confirm(prepared, opts)

    assert :ok = ControlPlane.release_lease(context.control_plane, competing_lease)

    assert {:ok, %{action: "prune", result: %{pruned_count: 1}}} =
             OperatorMutation.confirm(prepared, opts)
  end

  test "missing registry plan reports an uncommitted backend failure", context do
    opts = mutation_opts(context)
    command = %{"action" => "retire", "target_id" => "alpha", "inputs" => %{}}
    {:ok, prepared} = OperatorMutation.preview(command, opts)
    plan_path = Path.join([Path.dirname(context.path), "target-plans", prepared.binding.plan_id <> ".json"])

    assert :ok = File.rm(plan_path)

    assert {:error, %{code: :plan_not_found, state_may_have_changed: false}} =
             OperatorMutation.confirm(prepared, opts)

    assert HostScheduler.snapshot(context.scheduler).registry.generation == prepared.registry_generation
  end

  test "confirmation rejects a prepared command rebound to another host or command", context do
    opts = mutation_opts(context)
    {:ok, prepared} = OperatorMutation.preview(%{"action" => "refresh", "inputs" => %{}}, opts)

    assert {:error, :confirmation_binding_mismatch} =
             OperatorMutation.confirm(
               %{prepared | command: %{"action" => "shutdown", "inputs" => %{}}},
               opts
             )

    assert {:error, :confirmation_binding_mismatch} =
             OperatorMutation.confirm(prepared, Keyword.put(opts, :host_id, "another-host"))
  end

  test "lifecycle previews describe actual transitions and confirmation reloads the host", context do
    for {action, expected, inputs} <- [
          {"activate", :active, %{"dispatch_mode" => "explicit"}},
          {"pause", :paused, %{}},
          {"activate", :active, %{"dispatch_mode" => "explicit"}},
          {"drain", :draining, %{}},
          {"pause", :paused, %{}},
          {"retire", :retired, %{}}
        ] do
      before = HostScheduler.snapshot(context.scheduler).targets["alpha"].configured_state
      {request, preview} = preview!(context, %{"action" => action, "target_id" => "alpha", "inputs" => inputs})
      assert preview.current_state.target.configured_state == before
      assert preview.proposed_state.target["configured_state"] == Atom.to_string(expected)
      assert HostScheduler.snapshot(context.scheduler).targets["alpha"].configured_state == before
      assert confirm!(context, request, preview).status == "completed"
      assert HostScheduler.snapshot(context.scheduler).targets["alpha"].configured_state == expected
    end
  end

  test "settings Apply exposes old and new values without leaking credentials", context do
    command = %{"action" => "patch", "target_id" => "alpha", "inputs" => %{"changes" => %{"display_name" => "Changed"}}}
    {request, preview} = preview!(context, command)
    diff = preview.proposed_state.preview["registry"]["diff"]
    assert Enum.any?(diff, &(&1["before"] == "Alpha" and &1["after"] == "Changed"))
    refute Jason.encode!(preview) =~ "$LINEAR_API_KEY"
    assert confirm!(context, request, preview).status == "completed"
    {:ok, document} = Yaml.decode(File.read!(context.path))
    assert document["targets"]["alpha"]["display_name"] == "Changed"
  end

  test "registry edits not yet observed by the scheduler invalidate target confirmations", context do
    {request, preview} = preview!(context, %{"action" => "retire", "target_id" => "alpha", "inputs" => %{}})
    File.write!(context.path, File.read!(context.path) <> "\n# another operator edit\n")
    result = confirm!(context, request, preview)
    assert result.status == "failed"
    refute result.state_may_have_changed
    {:ok, document} = Yaml.decode(File.read!(context.path))
    assert document["targets"]["alpha"]["state"] == "paused"
  end

  test "fenced refresh rejects a registry generation not yet loaded by the scheduler", context do
    generation = HostScheduler.snapshot(context.scheduler).registry.generation
    changed = put_in(registry(context.root), ["targets", "alpha", "display_name"], "Unpreviewed")
    File.write!(context.path, Yaml.encode(changed))

    assert {:error, :stale_generation} = HostScheduler.refresh(context.scheduler, generation)
    assert HostScheduler.snapshot(context.scheduler).registry.generation == generation

    assert {:ok, refreshed} = HostScheduler.refresh(context.scheduler)
    assert refreshed.registry.generation != generation
  end

  test "shutdown rejects an unobserved registry edit before fencing the host", context do
    generation = HostScheduler.snapshot(context.scheduler).registry.generation
    File.write!(context.path, File.read!(context.path) <> "\n# intervening edit\n")

    assert {:error, :stale_generation} = HostScheduler.begin_shutdown(context.scheduler, generation)
    refute HostScheduler.snapshot(context.scheduler).shutdown.requested?
  end

  test "durable recovery binds run identity and fencing and uses the host as owner", context do
    run = admit!(context, "run-one")
    {request, preview} = preview!(context, run_command("resume_run", run))
    {:ok, lease} = ControlPlane.acquire_lease(context.control_plane, run.admitted_run_id, "other-owner")
    :ok = ControlPlane.release_lease(context.control_plane, lease)
    stale = confirm!(context, request, preview)
    assert stale.status == "failed"
    assert stale.error.code == "invalid_confirmation"

    {request, preview} = preview!(context, run_command("resume_run", run))
    completed = confirm!(context, request, preview)
    assert completed.status == "completed"
    {:ok, [snapshot]} = ControlPlane.inspect_runs(context.control_plane)
    {:ok, marker} = OperatorInterface.marker(context.interface)
    assert snapshot.lifecycle_state == "running"
    assert snapshot.owner_id == marker.host_id

    {_request, disabled} = preview!(context, run_command("abandon_run", run))
    assert disabled.confirmation_token == nil
    assert disabled.disabled_reason == "lease_held"
    assert disabled.current_state.run.lifecycle_state == "running"

    other_run = admit!(context, "run-two")
    {request, preview} = preview!(context, run_command("abandon_run", other_run))
    assert confirm!(context, request, preview).status == "completed"
    {:ok, runs} = ControlPlane.inspect_runs(context.control_plane)
    assert Enum.find(runs, &(&1.admitted_run_id == other_run.admitted_run_id)).lifecycle_state == "completed"
  end

  test "a transition failure after lease acquisition truthfully reports changed host state", context do
    run = admit!(context, "run-failure")
    {request, preview} = preview!(context, run_command("resume_run", run))
    {:ok, db} = Exqlite.Sqlite3.open(ControlPlane.path(config_root: context.root))

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TRIGGER fail_operator_transition BEFORE INSERT ON run_lifecycle_transitions
      WHEN NEW.to_state = 'running'
      BEGIN SELECT RAISE(ABORT, 'injected transition failure'); END;
      """)

    :ok = Exqlite.Sqlite3.close(db)
    failed = confirm!(context, request, preview)
    assert failed.status == "failed"
    assert failed.state_may_have_changed
    {:ok, [snapshot]} = ControlPlane.inspect_runs(context.control_plane)
    assert snapshot.lifecycle_state == "admitted"
    assert snapshot.fencing_generation > preview.current_state.run.fencing_generation
    refute Jason.encode!(failed) =~ "injected transition failure"
  end

  test "authenticated pruning preserves nonterminal runs and uses host retention", context do
    run = admit!(context, "run-preserved")
    File.write!(Path.join(context.root, "config.yml"), "control_plane:\n  terminal_retention_days: 30\n")
    {request, preview} = preview!(context, %{"action" => "prune", "inputs" => %{}})
    assert preview.proposed_state.prune.retention_days == 30
    assert confirm!(context, request, preview).status == "completed"
    assert {:ok, [preserved]} = ControlPlane.inspect_runs(context.control_plane)
    assert preserved.admitted_run_id == run.admitted_run_id
    assert preserved.lifecycle_state == "admitted"
  end

  test "prune uses the interface configuration root, not transport options", context do
    File.write!(Path.join(context.root, "config.yml"), "control_plane:\n  terminal_retention_days: 45\n")
    context = %{context | opts: Keyword.put(context.opts, :config_root, Path.join(context.root, "wrong-root"))}

    {_request, preview} = preview!(context, %{"action" => "prune", "inputs" => %{}})
    assert preview.proposed_state.prune.retention_days == 45
  end

  test "shutdown initiation failure publishes failure without a completed result", context do
    context = %{context | opts: Keyword.put(context.opts, :shutdown, fn -> raise "shutdown failed" end)}
    {request, preview} = preview!(context, %{"action" => "shutdown", "inputs" => %{}})
    result = confirm!(context, request, preview)

    assert result.status == "failed"
    assert result.error.code == "shutdown_failed"
    assert result.state_may_have_changed
    assert HostScheduler.snapshot(context.scheduler).shutdown.requested?
    {:ok, marker} = OperatorInterface.marker(context.interface)
    {:ok, feed} = OperatorInterface.events(context.interface, marker.host_id, 0, 200)

    statuses =
      for %{kind: "command_result", data: %{id: id, status: status}} <- feed.events,
          id == result.id,
          do: status

    assert statuses == ["accepted", "failed"]
  end

  test "shutdown is disabled before drain and atomically prevents new work after confirmation", context do
    {_request, paused} = preview!(context, %{"action" => "shutdown", "inputs" => %{}})
    assert is_binary(paused.confirmation_token)
    assert paused.disabled_reason == nil

    {request, activate} =
      preview!(context, %{"action" => "activate", "target_id" => "alpha", "inputs" => %{"dispatch_mode" => "explicit"}})

    assert confirm!(context, request, activate).status == "completed"
    {_request, disabled} = preview!(context, %{"action" => "shutdown", "inputs" => %{}})
    assert disabled.confirmation_token == nil
    assert disabled.disabled_reason == "targets_not_drained"
    {request, drain} = preview!(context, %{"action" => "drain", "target_id" => "alpha", "inputs" => %{}})
    assert confirm!(context, request, drain).status == "completed"
    parent = self()

    context = %{
      context
      | opts:
          Keyword.put(context.opts, :shutdown, fn ->
            send(parent, :shutdown_requested)
            :ok
          end)
    }

    {request, shutdown} = preview!(context, %{"action" => "shutdown", "inputs" => %{}})
    assert confirm!(context, request, shutdown).status == "completed"
    assert HostScheduler.snapshot(context.scheduler).shutdown.requested?
    assert {:error, :shutdown_requested} = HostScheduler.refresh(context.scheduler)
    assert {:error, :capacity} = HostScheduler.reserve_reviewer(context.scheduler, "alpha", self())
    assert_receive :shutdown_requested, 1_000
  end

  defp branch_context(context) do
    repo = Path.join(System.tmp_dir!(), "operator-branch-mutation-#{System.unique_integer([:positive])}")
    File.cp_r!(@repo, repo)
    on_exit(fn -> File.rm_rf(repo) end)

    for args <- [
          ["init", "--initial-branch=main"],
          ["remote", "add", "origin", "https://github.com/example/symphony-fixture"],
          ["add", "."],
          ["-c", "user.name=Branch Tests", "-c", "user.email=branch@example.invalid", "commit", "-m", "fixture"],
          ["branch", "release/2026"]
        ] do
      {output, status} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
      assert status == 0, output
    end

    {:ok, document} = Yaml.decode(File.read!(context.path))
    document = put_in(document, ["targets", "alpha", "repo", "path"], repo)
    File.write!(context.path, Yaml.encode(document))
    assert {:ok, _snapshot} = HostScheduler.reload(context.scheduler)
    {context, repo}
  end

  defp branch_scan!(context, repo, configured_target) do
    request =
      %{"action" => "branches", "path" => repo, "target_id" => "alpha"}
      |> Map.put("configured_target", configured_target)

    assert {:ok, started} =
             OperatorInterface.repositories(context.interface, context.credential, request, context.scheduler)

    await_branch_scan(context, started.scan_id)
  end

  defp await_branch_scan(context, scan_id, after_cursor \\ 0, attempts \\ 200)

  defp await_branch_scan(_context, _scan_id, _after, 0), do: flunk("branch scan did not finish")

  defp await_branch_scan(context, scan_id, after_cursor, attempts) do
    assert {:ok, response} =
             OperatorInterface.repositories(
               context.interface,
               context.credential,
               %{"action" => "poll", "scan_id" => scan_id, "after" => after_cursor},
               context.scheduler
             )

    if response.status == "running" do
      Process.sleep(10)
      await_branch_scan(context, scan_id, response.next_cursor, attempts - 1)
    else
      response
    end
  end

  defp mutation_request(context, command, scan_id) do
    {:ok, marker} = OperatorInterface.marker(context.interface)

    request = %{
      "interface_version" => 1,
      "host_id" => marker.host_id,
      "registry_generation" => HostScheduler.snapshot(context.scheduler).registry.generation,
      "command" => command
    }

    if is_binary(scan_id), do: Map.put(request, "branch_scan_id", scan_id), else: request
  end

  defp canonical!(path) do
    {:ok, canonical} = PathSafety.canonicalize(path)
    canonical
  end

  defp preview!(context, command) do
    {:ok, marker} = OperatorInterface.marker(context.interface)

    request = %{
      "interface_version" => 1,
      "host_id" => marker.host_id,
      "registry_generation" => HostScheduler.snapshot(context.scheduler).registry.generation,
      "command" => command
    }

    assert {:ok, preview} = OperatorInterface.preview(context.interface, context.credential, request, context.opts)
    {request, preview}
  end

  defp mutation_opts(context) do
    {:ok, marker} = OperatorInterface.marker(context.interface)
    Keyword.put(context.opts, :host_id, marker.host_id)
  end

  defp confirm!(context, request, preview) do
    assert {:ok, accepted} =
             OperatorInterface.confirm(
               context.interface,
               context.credential,
               Map.put(request, "confirmation_token", preview.confirmation_token)
             )

    await_result(context.interface, accepted.id)
  end

  defp await_result(interface, id, attempts \\ 200) do
    {:ok, marker} = OperatorInterface.marker(interface)
    result = Enum.find(marker.command_results, &(&1.id == id))

    if result.status == "accepted" do
      assert attempts > 0
      Process.sleep(5)
      await_result(interface, id, attempts - 1)
    else
      result
    end
  end

  defp admit!(context, id) do
    target = %{context.target | state: :active, dispatch_mode: :explicit, budget_limits: %{}}

    runner = %{
      "kind" => "codex_app_server",
      "command" => ["codex", "app-server"],
      "turn_timeout_ms" => 30_000,
      "execution_profiles" => %{
        "implementation" => %{
          "model" => "test-model",
          "reasoning_effort" => "high",
          "budget" => "standard",
          "timeout_ms" => 30_000,
          "max_retries" => 1
        }
      }
    }

    target = %{
      target
      | runner_policy: %{"default" => "runner", "allowed" => ["runner"], "runners" => %{"runner" => runner}}
    }

    issue = %Issue{id: id, identifier: "SID-481-" <> id, title: "Operator contract", state: "In Progress"}
    {:ok, execution} = ExecutionContext.new(target, issue, policy: %{"delivery" => %{"pr_target" => "main"}})
    assert {:ok, admission} = ControlPlane.admit_run(context.control_plane, execution)
    admission
  end

  defp run_command(action, run), do: %{"action" => action, "run_id" => run.admitted_run_id, "inputs" => %{}}
  defp unique_name, do: {:global, {__MODULE__, make_ref()}}

  defp side_effect_gates do
    Map.new(~w(tracker_write vcs_publish pull_request_write merge deployment production_data), &{&1, "deny"})
  end

  defp registry(root) do
    %{
      "version" => 1,
      "host" => %{
        "id" => "operator-test",
        "state_root" => Path.join(root, "state"),
        "polling" => %{"interval_ms" => 30_000, "max_concurrent_target_polls" => 1},
        "capacity" => %{"max_concurrent_agents" => 4, "max_concurrent_startups" => 2, "max_concurrent_reviewers" => 1},
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 4},
        "tracker_connections" => %{
          "linear-main" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "$LINEAR_API_KEY"
          }
        },
        "runners" => %{
          "existing" => %{
            "kind" => "codex_app_server",
            "command" => ["existing", "app-server"],
            "max_concurrent_agents" => 4,
            "max_concurrent_startups" => 2
          }
        }
      },
      "targets" => %{
        "alpha" => %{
          "display_name" => "Alpha",
          "state" => "paused",
          "repo" => %{"path" => @repo, "manifest" => "symphony.yml"},
          "worktree" => %{"root" => Path.join(root, "worktrees"), "strategy" => "per_issue", "hooks" => %{}},
          "linear" => %{
            "connection" => "linear-main",
            "scope" => %{"type" => "project", "project_id" => "project-1"},
            "active_states" => ["Todo", "In Progress"],
            "terminal_states" => ["Done"],
            "required_labels" => []
          },
          "runners" => %{"allowed" => ["existing"], "default" => "existing", "settings" => %{}},
          "concurrency" => %{
            "max_concurrent_agents" => 2,
            "max_concurrent_startups" => 1,
            "max_concurrent_reviewers" => 1,
            "by_linear_state" => %{}
          },
          "budgets" => %{
            "per_run" => %{"max_total_tokens" => 1_000},
            "daily" => %{"max_total_tokens" => 10_000},
            "weekly" => %{"max_total_tokens" => 50_000}
          },
          "checks" => %{
            "pre_dispatch" => ["capability_preflight"],
            "pre_handoff" => ["repo_validation", "quality_gate"],
            "pre_publish" => ["publish_preflight"],
            "pre_merge" => ["pr_checks", "review_feedback_sweep"]
          },
          "external_side_effects" => side_effect_gates(),
          "scheduling" => %{"weight" => 1}
        }
      }
    }
  end
end
