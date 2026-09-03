defmodule SymphonyElixir.MultiRepositorySystemTest.TargetEndpoint do
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {:ok,
     %{
       recipient: Keyword.fetch!(opts, :recipient),
       target_id: Keyword.fetch!(opts, :target_id)
     }}
  end

  @impl true
  def handle_cast({:dispatch_grant, grant}, state) do
    send(state.recipient, {:dispatch_grant, state.target_id, grant})
    {:noreply, state}
  end

  def handle_cast({:apply_target_context, _context}, state), do: {:noreply, state}
end

defmodule SymphonyElixir.MultiRepositorySystemTest.RuntimeAdapter do
  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.AgentRuntime.Event
  alias SymphonyElixir.ExecutionContext

  @impl true
  def start(%ExecutionContext{} = context, issue, []) do
    recipient =
      Application.fetch_env!(:symphony_elixir, :multi_repository_system_test_recipient)

    send(recipient, {:runtime_started, context.target.target_id, issue.identifier, self()})
    {:ok, %{context: context, recipient: recipient}}
  end

  @impl true
  def send_turn(%{context: context, recipient: recipient}, _prompt, issue, opts) do
    target_id = context.target.target_id
    result_path = Path.join(context.workspace_path, "change.txt")
    File.write!(result_path, context.runner_config["proof_content"] <> "\n")

    {output, status} =
      System.cmd("/bin/sh", ["-c", context.runner_config["proof_check"]],
        cd: context.workspace_path,
        stderr_to_stdout: true
      )

    completion = %{
      outcome: :completed,
      changed_files: ["change.txt"],
      validation: [
        %{
          name: context.runner_config["proof_check_name"],
          status: if(status == 0, do: :passed, else: :failed),
          output: String.trim(output)
        }
      ],
      review: %{status: :clean},
      landing: %{route: context.runner_config["proof_landing_route"]}
    }

    {:ok, event} =
      Event.turn_completed(
        runtime: :multi_repository_proof,
        session_id: "session-#{target_id}",
        usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
        payload: %{params: %{completion: completion}}
      )

    Keyword.fetch!(opts, :on_event).(event)
    send(recipient, {:repository_validated, target_id, issue.identifier, self(), completion})

    receive do
      :complete -> {:ok, %{session_id: "session-#{target_id}"}}
      {:fail, reason} -> {:error, reason}
    end
  end

  @impl true
  def stop(%{context: context, recipient: recipient}) do
    send(recipient, {:runtime_stopped, context.target.target_id})
    :ok
  end

  @impl true
  def capabilities(_runner_config),
    do: %{token_usage: %{status: :supported, version: "sid-461-test-v1"}}
end

defmodule SymphonyElixir.MultiRepositorySystemTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{
    AgentRunner,
    ControlPlane,
    ExecutionContext,
    HostScheduler,
    TargetContext,
    Workspace
  }

  alias SymphonyElixir.ControlPlane.{Admission, Lease, Lifecycle, SideEffect}
  alias SymphonyElixir.HostScheduler.Grant
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.MultiRepositorySystemTest.{RuntimeAdapter, TargetEndpoint}
  alias SymphonyElixir.Workflow.Manifest

  @adapter_registry %{"codex_app_server" => RuntimeAdapter}
  @tracker_key "sid-461-memory-tracker"

  setup do
    previous_recipient =
      Application.get_env(:symphony_elixir, :multi_repository_system_test_recipient)

    previous_tracker_key = System.get_env("SID461_TRACKER_KEY")
    Application.put_env(:symphony_elixir, :multi_repository_system_test_recipient, self())
    System.put_env("SID461_TRACKER_KEY", @tracker_key)

    on_exit(fn ->
      restore_application_env(
        :multi_repository_system_test_recipient,
        previous_recipient
      )

      restore_env("SID461_TRACKER_KEY", previous_tracker_key)
    end)

    :ok
  end

  @tag :tmp_dir
  test "one host isolates two repositories while one target recovers", %{tmp_dir: tmp_dir} do
    generation = hash("sid-461-generation")
    source_root = Path.join(tmp_dir, "repositories")
    workspace_root = Path.join(tmp_dir, "workspaces")

    symphony_repo =
      create_repository!(source_root, "symphony", "symphony-source", "validate-symphony")

    second_repo =
      create_repository!(source_root, "second-repository", "second-source", "validate-second")

    symphony_issue = issue("issue-symphony", "SID-461-A")
    second_issue = issue("issue-second", "SID-461-B")

    symphony =
      execution_context!(workspace_root, symphony_repo, symphony_issue, %{
        target_id: "symphony",
        generation: generation,
        runner_name: "runner-symphony",
        proof_content: "symphony-change",
        proof_check: "sh validate-symphony",
        proof_check_name: "validate-symphony",
        landing_route: "auto_land",
        token_limit: 120
      })

    second =
      execution_context!(workspace_root, second_repo, second_issue, %{
        target_id: "second-repository",
        generation: generation,
        runner_name: "runner-second",
        proof_content: "second-repository-change",
        proof_check: "sh validate-second",
        proof_check_name: "validate-second",
        landing_route: "human_review",
        token_limit: 240
      })

    assert symphony.workspace_path != second.workspace_path
    assert symphony.target.policy_hash != second.target.policy_hash
    assert symphony.target.repo_manifest_hash != second.target.repo_manifest_hash
    assert symphony.runner_name != second.runner_name
    assert symphony.policy["landing"]["route"] == "auto_land"
    assert second.policy["landing"]["route"] == "human_review"

    control_plane = unique_name(ControlPlane)
    start_supervised!({ControlPlane, name: control_plane, config_root: tmp_dir})

    {:ok, symphony_admission, symphony_lease} =
      admit_running!(control_plane, symphony, "owner-symphony")

    {:ok, second_admission, second_lease} =
      admit_running!(control_plane, second, "owner-second")

    scheduler = unique_name(HostScheduler)
    registry = loaded_registry(symphony.target, second.target, generation)

    scheduler_opts = [
      name: scheduler,
      registry_path: "/deterministic/sid-461-targets.yml",
      registry_loader: fn _path -> {:ok, registry} end,
      registry_reload_interval_ms: 50_000,
      target_supervisor: false
    ]

    start_supervised!({HostScheduler, scheduler_opts})

    {:ok, symphony_endpoint} =
      TargetEndpoint.start_link(recipient: self(), target_id: symphony.target.target_id)

    {:ok, second_endpoint} =
      TargetEndpoint.start_link(recipient: self(), target_id: second.target.target_id)

    HostScheduler.register_target(scheduler, symphony.target, symphony_endpoint)
    HostScheduler.register_target(scheduler, second.target, second_endpoint)

    grants = receive_grants(2)
    symphony_grant = Map.fetch!(grants, symphony.target.target_id)
    second_grant = Map.fetch!(grants, second.target.target_id)

    assert :ok = HostScheduler.reserve_dispatch(symphony_grant)
    assert :ok = HostScheduler.reserve_dispatch(second_grant)
    assert :ok = HostScheduler.finish_poll(symphony_grant, false)
    assert :ok = HostScheduler.finish_poll(second_grant, false)

    assert HostScheduler.snapshot(scheduler).counts == %{
             agents: 2,
             startups: 2,
             reviewers: 0,
             polls: 0
           }

    symphony_task = run_repository(symphony, symphony_issue)
    second_task = run_repository(second, second_issue)

    assert_receive {:runtime_started, "symphony", "SID-461-A", _}, 1_000
    assert_receive {:runtime_started, "second-repository", "SID-461-B", _}, 1_000

    validated = receive_validations(2)
    symphony_first_worker = validated["symphony"].worker
    second_worker = validated["second-repository"].worker

    assert File.read!(Path.join(symphony.workspace_path, "repository.txt")) ==
             "symphony-source\n"

    assert File.read!(Path.join(second.workspace_path, "repository.txt")) ==
             "second-source\n"

    refute File.exists?(Path.join(symphony.workspace_path, "validate-second"))
    refute File.exists?(Path.join(second.workspace_path, "validate-symphony"))

    send(symphony_first_worker, {:fail, :operator_intervention})

    assert Task.await(symphony_task, 2_000) == {:error, :operator_intervention}
    assert_receive {:runtime_stopped, "symphony"}, 1_000

    assert {:ok, %Lifecycle{state: :blocked, sequence: 3}} =
             ControlPlane.transition_run(
               control_plane,
               symphony_lease,
               2,
               :running,
               :blocked,
               %{reason: "operator intervention"}
             )

    assert %{queued: true} = HostScheduler.request_retry(scheduler, "symphony")
    assert_receive {:dispatch_grant, "symphony", %Grant{} = capacity_grant}, 1_000
    assert {:error, :capacity} = HostScheduler.reserve_dispatch(capacity_grant)
    assert :ok = HostScheduler.finish_poll(capacity_grant, false)
    assert :ok = HostScheduler.release_dispatch(symphony_grant)
    assert %{queued: true} = HostScheduler.request_retry(scheduler, "symphony")
    assert_receive {:dispatch_grant, "symphony", %Grant{} = recovery_grant}, 1_000
    assert :ok = HostScheduler.reserve_dispatch(recovery_grant)
    assert :ok = HostScheduler.finish_poll(recovery_grant, false)

    assert HostScheduler.snapshot(scheduler).counts.agents == 2
    assert Process.alive?(second_worker)

    assert {:ok, %Lifecycle{state: :running, sequence: 4}} =
             ControlPlane.transition_run(
               control_plane,
               symphony_lease,
               3,
               :blocked,
               :running,
               %{}
             )

    recovered_symphony_task = run_repository(symphony, symphony_issue)

    assert_receive {:runtime_started, "symphony", "SID-461-A", _}, 1_000

    assert_receive {:repository_validated, "symphony", "SID-461-A", recovered_worker, recovered_completion},
                   1_000

    assert validation_passed?(recovered_completion, "validate-symphony")
    assert validation_passed?(validated["second-repository"].completion, "validate-second")

    send(second_worker, :complete)
    send(recovered_worker, :complete)

    assert Task.await(second_task, 2_000) == :ok
    assert Task.await(recovered_symphony_task, 2_000) == :ok
    assert_receive {:runtime_stopped, "second-repository"}, 1_000
    assert_receive {:runtime_stopped, "symphony"}, 1_000

    assert :ok = HostScheduler.release_dispatch(second_grant)
    assert :ok = HostScheduler.release_dispatch(recovery_grant)

    assert HostScheduler.snapshot(scheduler).counts == %{
             agents: 0,
             startups: 0,
             reviewers: 0,
             polls: 0
           }

    assert {:ok, _budget} = ControlPlane.record_token_usage(control_plane, symphony_lease, 45)
    assert {:ok, _budget} = ControlPlane.record_token_usage(control_plane, second_lease, 90)

    retain_completion_evidence!(
      control_plane,
      symphony_admission,
      symphony_lease,
      4,
      recovered_completion
    )

    retain_completion_evidence!(
      control_plane,
      second_admission,
      second_lease,
      2,
      validated["second-repository"].completion
    )

    clean_run!(control_plane, symphony_admission, symphony_lease, 5, symphony)
    clean_run!(control_plane, second_admission, second_lease, 3, second)

    refute File.exists?(symphony.workspace_path)
    refute File.exists?(second.workspace_path)
    assert File.exists?(Path.join(symphony_repo, "symphony.yml"))
    assert File.exists?(Path.join(second_repo, "symphony.yml"))

    GenServer.stop(control_plane)
    reopened = unique_name(ControlPlane)
    start_supervised!({ControlPlane, name: reopened, config_root: tmp_dir})

    assert {:ok, runs} = ControlPlane.inspect_runs(reopened)

    assert Enum.map(runs, &{&1.target_id, &1.lifecycle_state}) |> Enum.sort() == [
             {"second-repository", "cleaned"},
             {"symphony", "cleaned"}
           ]

    assert {:ok, symphony_history} =
             ControlPlane.lifecycle_history(reopened, symphony_admission.admitted_run_id)

    assert Enum.map(symphony_history, & &1.to_state) == [
             :admitted,
             :running,
             :blocked,
             :running,
             :completed,
             :cleanup_pending,
             :cleaned
           ]

    assert {:ok, second_history} =
             ControlPlane.lifecycle_history(reopened, second_admission.admitted_run_id)

    assert Enum.map(second_history, & &1.to_state) == [
             :admitted,
             :running,
             :completed,
             :cleanup_pending,
             :cleaned
           ]

    assert_retained_evidence!(
      reopened,
      symphony_admission,
      "validate-symphony",
      "auto_land"
    )

    assert_retained_evidence!(
      reopened,
      second_admission,
      "validate-second",
      "human_review"
    )

    assert {:ok, budgets} = ControlPlane.inspect_target_budgets(reopened)

    assert Enum.map(budgets, &{&1.target_id, &1.charged_tokens}) |> Enum.sort() == [
             {"second-repository", 90},
             {"symphony", 45}
           ]
  end

  defp run_repository(context, issue) do
    parent = self()

    Task.async(fn ->
      AgentRunner.run_context(context, issue, parent,
        adapter_registry: @adapter_registry,
        issue_state_fetcher: fn _target, [issue_id] ->
          {:ok, [%{issue | id: issue_id, state: "Done"}]}
        end,
        max_turns: 1
      )
    end)
  end

  defp create_repository!(source_root, name, identity, validator) do
    repo = Path.join(source_root, name)
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "repository.txt"), identity <> "\n")
    File.write!(Path.join(repo, validator), "test \"$(cat change.txt)\" = \"#{name}-change\"\n")

    File.write!(
      Path.join(repo, "symphony.yml"),
      "version: 1\nproject:\n  slug: #{name}\nvalidation:\n  commands:\n    - name: #{validator}\n      command: sh #{validator}\n"
    )

    run_git!(repo, ["init", "--initial-branch=main"])
    run_git!(repo, ["config", "user.name", "Symphony Test"])
    run_git!(repo, ["config", "user.email", "symphony-test@example.invalid"])
    run_git!(repo, ["add", "."])
    run_git!(repo, ["commit", "-m", "chore: initialize #{name}"])
    repo
  end

  defp run_git!(repo, args) do
    {_output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
  end

  defp execution_context!(workspace_root, source_repo, issue, opts) do
    target_id = Map.fetch!(opts, :target_id)
    generation = Map.fetch!(opts, :generation)
    runner_name = Map.fetch!(opts, :runner_name)
    proof_content = Map.fetch!(opts, :proof_content)
    proof_check = Map.fetch!(opts, :proof_check)
    proof_check_name = Map.fetch!(opts, :proof_check_name)
    landing_route = Map.fetch!(opts, :landing_route)
    token_limit = Map.fetch!(opts, :token_limit)
    root = Path.join(workspace_root, target_id)
    File.mkdir_p!(root)

    {:ok, _loaded_workflow} = Workflow.current()
    {:ok, base_manifest} = Manifest.read(Workflow.workflow_file_path(), repo_setup?: false)

    manifest =
      base_manifest
      |> Map.put("prompt_template", "target=#{target_id} policy={{ policy.target }}")
      |> put_in(["project", "name"], target_id)
      |> put_in(["project", "repository"], "https://github.com/example/#{target_id}")

    resolution = manifest |> Manifest.compile() |> Map.fetch!(:workflow_module_resolution)

    runner = %{
      "kind" => "codex_app_server",
      "command" => ["codex", "app-server"],
      "approval_policy" => "never",
      "thread_sandbox" => "workspace-write",
      "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => false},
      "turn_timeout_ms" => 5_000,
      "max_turns" => 1,
      "proof_content" => proof_content,
      "proof_check" => proof_check,
      "proof_check_name" => proof_check_name,
      "proof_landing_route" => landing_route,
      "execution_profiles" => %{
        "implementation" => %{
          "model" => "model-#{target_id}",
          "timeout_ms" => 5_000,
          "max_retries" => 0
        }
      }
    }

    target = %TargetContext{
      target_id: target_id,
      workspace_layout: :flat,
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: generation,
      policy_hash: hash("policy-#{target_id}"),
      repo_manifest_hash: hash("manifest-#{target_id}"),
      repo_policy: %{
        "manifest" => manifest,
        "manifest_source_dir" => source_repo,
        "workflow_module_resolution" => resolution_projection(resolution)
      },
      tracker_connection: %{
        "id" => "tracker-#{target_id}",
        "policy" => %{
          "kind" => "memory",
          "endpoint" => "memory://#{target_id}",
          "api_key" => "$SID461_TRACKER_KEY"
        }
      },
      run_target: %{
        "active_states" => ["In Progress"],
        "terminal_states" => ["Done"],
        "required_labels" => ["target:#{target_id}"],
        "scope" => %{"type" => "issues", "issue_ids" => [issue.id]}
      },
      worktree_policy: %{
        "root" => root,
        "strategy" => "per_issue",
        "hooks" => %{
          "after_create" => "git clone --quiet '#{source_repo}' .",
          "before_run" => nil,
          "after_run" => nil,
          "before_remove" => nil,
          "timeout_ms" => 5_000
        }
      },
      runner_policy: %{
        "default" => runner_name,
        "allowed" => [runner_name],
        "runners" => %{runner_name => runner}
      },
      effective_checks: %{"pre_handoff" => [proof_check]},
      external_side_effect_gates: %{
        "tracker_write" => "allow",
        "vcs_publish" => if(landing_route == "auto_land", do: "allow", else: "deny"),
        "pull_request_write" => if(landing_route == "auto_land", do: "allow", else: "deny")
      },
      capacity_limits: %{
        "max_concurrent_agents" => 1,
        "max_concurrent_startups" => 1,
        "max_concurrent_reviewers" => 1
      },
      budget_limits: %{
        "per_run" => %{"max_total_tokens" => token_limit},
        "daily" => %{"max_total_tokens" => token_limit * 2},
        "weekly" => %{"max_total_tokens" => token_limit * 4}
      }
    }

    assert {:ok, context} =
             ExecutionContext.new(target, issue,
               policy: %{
                 "capabilities" => %{"required" => []},
                 "delivery" => %{"pr_target" => "main"},
                 "landing" => %{"route" => landing_route},
                 "target" => target_id
               }
             )

    context
  end

  defp admit_running!(control_plane, context, owner_id) do
    assert {:ok, %Admission{} = admission} = ControlPlane.admit_run(control_plane, context)

    assert {:ok, %Lease{} = lease} =
             ControlPlane.acquire_lease(control_plane, admission.admitted_run_id, owner_id)

    assert {:ok, %Lifecycle{state: :running, sequence: 2}} =
             ControlPlane.transition_run(
               control_plane,
               lease,
               1,
               :admitted,
               :running,
               %{}
             )

    {:ok, admission, lease}
  end

  defp retain_completion_evidence!(
         control_plane,
         admission,
         lease,
         running_sequence,
         completion
       ) do
    validation = completion.validation |> List.first() |> Map.take([:name, :status])
    landing = completion.landing

    assert {:ok, %SideEffect{state: :succeeded}} =
             ControlPlane.run_side_effect(
               control_plane,
               lease,
               :handoff_route,
               "sid-461-handoff",
               %{
                 issue_identifier: admission.issue_identifier,
                 validation: validation,
                 landing: landing
               },
               fn ->
                 {:ok,
                  %{
                    issue_identifier: admission.issue_identifier,
                    validation: validation,
                    landing: landing
                  }}
               end
             )

    assert {:ok, %Lifecycle{state: :completed}} =
             ControlPlane.transition_run(
               control_plane,
               lease,
               running_sequence,
               :running,
               :completed,
               %{disposition: :succeeded}
             )
  end

  defp clean_run!(control_plane, admission, lease, completed_sequence, context) do
    assert {:ok, %Lifecycle{state: :cleanup_pending}} =
             ControlPlane.transition_run(
               control_plane,
               lease,
               completed_sequence,
               :completed,
               :cleanup_pending,
               %{}
             )

    assert {:ok, %SideEffect{state: :succeeded}} =
             ControlPlane.run_side_effect(
               control_plane,
               lease,
               :workspace_cleanup,
               "sid-461-workspace-cleanup",
               %{workspace_path: context.workspace_path},
               fn ->
                 case Workspace.remove(context) do
                   {:ok, removed} ->
                     {:ok,
                      %{
                        workspace_path: context.workspace_path,
                        removed: inspect(removed)
                      }}

                   {:error, reason} ->
                     {:failed, %{reason: inspect(reason)}}
                 end
               end
             )

    assert {:ok, %Lifecycle{state: :cleaned}} =
             ControlPlane.transition_run(
               control_plane,
               lease,
               completed_sequence + 1,
               :cleanup_pending,
               :cleaned,
               %{}
             )

    assert :ok = ControlPlane.release_lease(control_plane, lease)

    assert {:ok, %Lifecycle{state: :cleaned}} =
             ControlPlane.fetch_lifecycle(control_plane, admission.admitted_run_id)
  end

  defp assert_retained_evidence!(control_plane, admission, check_name, landing_route) do
    assert {:ok, side_effects} =
             ControlPlane.list_side_effects(control_plane, admission.admitted_run_id)

    assert %SideEffect{state: :succeeded, outcome: handoff_outcome} =
             Enum.find(side_effects, &(&1.kind == :handoff_route))

    assert handoff_outcome["validation"] == %{"name" => check_name, "status" => "passed"}
    assert handoff_outcome["landing"] == %{"route" => landing_route}

    assert %SideEffect{state: :succeeded, outcome: cleanup_outcome} =
             Enum.find(side_effects, &(&1.kind == :workspace_cleanup))

    assert cleanup_outcome["workspace_path"] == "<redacted:absolute-path>"
  end

  defp receive_grants(count) do
    Enum.reduce(1..count, %{}, fn _, grants ->
      assert_receive {:dispatch_grant, target_id, %Grant{} = grant}, 1_000
      Map.put(grants, target_id, grant)
    end)
  end

  defp receive_validations(count) do
    Enum.reduce(1..count, %{}, fn _, validations ->
      assert_receive {:repository_validated, target_id, issue_identifier, worker, completion},
                     2_000

      Map.put(validations, target_id, %{
        issue_identifier: issue_identifier,
        worker: worker,
        completion: completion
      })
    end)
  end

  defp validation_passed?(completion, name) do
    Enum.any?(completion.validation, &(&1.name == name and &1.status == :passed))
  end

  defp loaded_registry(symphony, second, generation) do
    %{
      snapshot: %{
        generation: generation,
        host: %{
          "polling" => %{"interval_ms" => 50_000, "max_concurrent_target_polls" => 2},
          "capacity" => %{
            "max_concurrent_agents" => 2,
            "max_concurrent_startups" => 2,
            "max_concurrent_reviewers" => 1
          },
          "scheduling" => %{
            "algorithm" => "weighted_deficit_round_robin",
            "max_credit_rounds" => 2
          }
        }
      },
      contexts: %{symphony.target_id => symphony, second.target_id => second},
      weights: [{symphony.target_id, 1}, {second.target_id, 1}]
    }
  end

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Multi-repository proof #{identifier}",
      state: "In Progress",
      labels: []
    }
  end

  defp resolution_projection(resolution) do
    %{
      "module_names" => resolution.module_names,
      "module_refs" => Enum.map(resolution.module_refs, &%{"name" => &1.name, "version" => &1.version}),
      "policy_hash" => resolution.policy_hash,
      "rendered" => resolution.rendered
    }
  end

  defp hash(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp unique_name(suffix),
    do: Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")

  defp restore_application_env(key, nil),
    do: Application.delete_env(:symphony_elixir, key)

  defp restore_application_env(key, value),
    do: Application.put_env(:symphony_elixir, key, value)
end
