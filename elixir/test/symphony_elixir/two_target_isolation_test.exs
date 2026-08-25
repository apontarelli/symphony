defmodule SymphonyElixir.TwoTargetIsolationTest.LinearClient do
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{RunTarget, TargetContext}

  def resolve_run_target(%TargetContext{} = target, %RunTarget{} = run_target) do
    notify({:tracker_resolution, target.target_id, run_target})
    {:ok, RunTarget.Resolution.new(run_target, [issue_for(target)])}
  end

  def fetch_issues_by_states(%TargetContext{} = target, states) do
    notify({:tracker_state_read, target.target_id, states})
    {:ok, [issue_for(target)]}
  end

  def fetch_issue_states_by_ids(%TargetContext{} = target, issue_ids) do
    notify({:tracker_issue_read, target.target_id, target.tracker_connection["id"], issue_ids})
    {:ok, [issue_for(target)]}
  end

  def graphql(%TargetContext{} = target, query, variables, _opts) do
    operation =
      cond do
        String.contains?(query, "SymphonyCreateComment") -> :create_comment
        String.contains?(query, "SymphonyResolveStateId") -> :resolve_state
        String.contains?(query, "SymphonyUpdateIssueState") -> :update_state
      end

    notify({:tracker_mutation, target.target_id, operation, variables})

    case operation do
      :create_comment ->
        {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}

      :resolve_state ->
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{
                 "states" => %{"nodes" => [%{"id" => "state-#{target.target_id}"}]}
               }
             }
           }
         }}

      :update_state ->
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
    end
  end

  defp issue_for(%TargetContext{} = target) do
    %Issue{
      id: "shared-issue",
      identifier: "SID-SHARED",
      title: "Two-target isolation",
      state: List.first(target.run_target["active_states"]),
      labels: target.run_target["required_labels"],
      url: "https://linear.example/SID-SHARED"
    }
  end

  defp notify(message) do
    if recipient = Application.get_env(:symphony_elixir, :two_target_isolation_recipient) do
      send(recipient, message)
    end
  end
end

defmodule SymphonyElixir.TwoTargetIsolationTest.RuntimeAdapter do
  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.ExecutionContext

  @impl true
  def start(%ExecutionContext{} = context, issue, []) do
    notify({
      :runtime_start,
      context.target.target_id,
      context.runner_name,
      context.execution_profile.model,
      context.workspace_path,
      issue.identifier
    })

    {:ok, %{context: context}}
  end

  @impl true
  def send_turn(%{context: context}, prompt, _issue, _opts) do
    notify({
      :runtime_turn,
      context.target.target_id,
      context.execution_profile.model,
      context.target.effective_checks,
      prompt
    })

    case context.runner_config["test_turn_result"] do
      "timeout" -> {:error, :turn_timeout}
      _success -> {:ok, %{session_id: "session-#{context.target.target_id}"}}
    end
  end

  @impl true
  def stop(%{context: context}) do
    notify({:runtime_stop, context.target.target_id})
    :ok
  end

  @impl true
  def capabilities(runner_config) do
    model = get_in(runner_config, ["execution_profiles", "implementation", "model"])
    notify({:runtime_capabilities, runner_config["kind"], model})
    %{"runner" => runner_config["kind"], "model" => model}
  end

  defp notify(message) do
    if recipient = Application.get_env(:symphony_elixir, :two_target_isolation_recipient) do
      send(recipient, message)
    end
  end
end

defmodule SymphonyElixir.TwoTargetIsolationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TwoTargetIsolationTest.{LinearClient, RuntimeAdapter}

  alias SymphonyElixir.{
    AgentRunner,
    ExecutionContext,
    HandoffRouteRecorder,
    Orchestrator,
    PublishHandoff,
    PublishPreflight,
    QualityGate,
    ReviewRecords,
    RunTarget,
    TargetContext,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.Manifest

  @adapter_registry %{"codex_app_server" => RuntimeAdapter}
  @alpha_hash "sha256:" <> String.duplicate("a", 64)
  @beta_hash "sha256:" <> String.duplicate("b", 64)
  @publish_outputs %{
    git_remote_get_url: "git@github.com:example/alpha.git\n",
    git_committed_changed_files: "lib/change.ex\n",
    git_unstaged_changed_files: "",
    git_staged_changed_files: "",
    git_untracked_files: "",
    git_diff_cached: "",
    git_current: "1234567890abcdef\n",
    pr_view: "no pull request found",
    pr_create: "https://github.com/example/alpha/pull/422\n"
  }
  @publish_failure_steps [:git_diff_cached, :pr_view]

  setup do
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_recipient = Application.get_env(:symphony_elixir, :two_target_isolation_recipient)

    Application.put_env(:symphony_elixir, :linear_client_module, LinearClient)
    Application.put_env(:symphony_elixir, :two_target_isolation_recipient, self())

    on_exit(fn ->
      restore_application_env(:linear_client_module, previous_client)
      restore_application_env(:two_target_isolation_recipient, previous_recipient)
    end)

    :ok
  end

  @tag :tmp_dir
  test "complete reusable run path isolates two targets after global authority changes", %{tmp_dir: tmp_dir} do
    issue = %Issue{
      id: "shared-issue",
      identifier: "SID-SHARED",
      title: "Two-target isolation",
      state: "In Progress",
      labels: ["target:shared"],
      url: "https://linear.example/SID-SHARED"
    }

    alpha = execution_context!(tmp_dir, "alpha", issue)
    beta = execution_context!(tmp_dir, "beta", issue)

    resolutions =
      [alpha, beta]
      |> Task.async_stream(fn context -> Tracker.resolve_candidate_issues(context.target) end,
        ordered: true,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, resolution}} -> resolution end)

    assert Enum.map(resolutions, &List.first(&1.issues).identifier) == ["SID-SHARED", "SID-SHARED"]

    assert_receive {:tracker_resolution, "alpha", %RunTarget{type: :project, project_id: "project-alpha"}}
    assert_receive {:tracker_resolution, "beta", %RunTarget{type: :team, team_key: "BETA"}}

    poisoned_root = Path.join(tmp_dir, "poisoned-workspaces")
    poisoned_workflow = Workflow.workflow_file_path()
    missing_workflow = Path.join(tmp_dir, "missing-workflow.yml")

    write_workflow_file!(poisoned_workflow,
      workspace_root: poisoned_root,
      tracker_kind: "memory",
      tracker_active_states: ["Poisoned"],
      tracker_required_labels: ["poisoned"],
      codex_model: "poisoned-model",
      codex_stall_timeout_ms: 0,
      checks: ["poisoned-check"]
    )

    Workflow.set_workflow_file_path(missing_workflow)
    assert_raise ArgumentError, fn -> Config.settings!() end

    parent = self()

    run_results =
      [alpha, beta]
      |> Task.async_stream(
        fn context ->
          AgentRunner.run_context(context, issue, parent, adapter_registry: @adapter_registry)
        end,
        ordered: true,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert run_results == [:ok, {:error, :turn_timeout}]
    assert_receive {:runtime_capabilities, "codex_app_server", "model-alpha"}
    assert_receive {:runtime_capabilities, "codex_app_server", "model-beta"}

    assert_receive {:runtime_start, "alpha", "runner-alpha", "model-alpha", alpha_workspace, "SID-SHARED"}
    assert alpha_workspace == alpha.workspace_path
    assert_receive {:runtime_start, "beta", "runner-beta", "model-beta", beta_workspace, "SID-SHARED"}
    assert beta_workspace == beta.workspace_path

    assert_receive {:runtime_turn, "alpha", "model-alpha", alpha_checks, alpha_prompt}
    assert get_in(alpha_checks, ["target", "pre_handoff"]) == ["mix test.alpha"]
    assert alpha_prompt =~ "target=alpha"
    refute alpha_prompt =~ "poisoned"

    assert_receive {:runtime_turn, "beta", "model-beta", beta_checks, beta_prompt}
    assert get_in(beta_checks, ["target", "pre_handoff"]) == ["mix test.beta"]
    assert beta_prompt =~ "target=beta"
    refute beta_prompt =~ "poisoned"

    assert_receive {:runtime_stop, "alpha"}
    assert_receive {:runtime_stop, "beta"}
    assert File.read!(Path.join(alpha.workspace_path, "before.txt")) == "before-alpha"
    assert File.read!(Path.join(alpha.workspace_path, "after.txt")) == "after-alpha"
    assert File.read!(Path.join(beta.workspace_path, "before.txt")) == "before-beta"
    assert File.read!(Path.join(beta.workspace_path, "after.txt")) == "after-beta"
    refute File.exists?(poisoned_root)

    File.mkdir_p!(Path.join(alpha.workspace_path, "lib"))
    File.mkdir_p!(Path.join(beta.workspace_path, "lib"))
    File.write!(Path.join(alpha.workspace_path, "lib/change.ex"), "defmodule AlphaChange do\nend\n")
    File.write!(Path.join(beta.workspace_path, "lib/change.ex"), "defmodule BetaChange do\nend\n")

    quality_runner = quality_runner(parent)

    [alpha_quality, beta_quality] =
      [alpha, beta]
      |> Task.async_stream(
        &QualityGate.run_context(&1, issue, %{changed_files: ["lib/change.ex"]}, runner: quality_runner),
        ordered: true,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert alpha_quality.status == :passed
    assert alpha_quality.provenance.target_id == "alpha"
    assert beta_quality.status == :fix_required
    assert beta_quality.provenance.target_id == "beta"
    assert_receive {:quality_check, "alpha", :source_reviewer, "review-alpha", "main", 1}
    assert_receive {:quality_check, "beta", :source_reviewer, "review-beta", "release", 2}

    preflight_runner = fn command ->
      send(parent, {:preflight, command.provenance.target_id, command.step})
      {:ok, %{status: 0, output: "ok"}}
    end

    alpha_preflight = PublishPreflight.run_context(alpha, runner: preflight_runner)
    beta_preflight = PublishPreflight.run_context(beta, runner: preflight_runner)

    assert alpha_preflight.status == :passed
    assert alpha_preflight.repository == "https://github.com/example/alpha"
    assert beta_preflight.status == :blocked
    assert beta_preflight.repository == "https://github.com/example/beta"
    assert [%{class: :delivery_not_allowed}] = beta_preflight.failures
    refute_received {:preflight, "beta", _step}

    alpha_completion = route_completion(alpha_quality, alpha_preflight)
    beta_completion = route_completion(beta_quality, beta_preflight)

    assert %{status: :passed, provenance: %{target_id: "alpha"}} =
             PublishHandoff.run_context(alpha, issue, alpha_completion, runner: publish_runner(parent))

    assert %{status: :blocked, failure: %{reason: :delivery_not_allowed}} =
             PublishHandoff.run_context(beta, issue, beta_completion, runner: publish_runner(parent))

    alpha_decision = HandoffRouteRecorder.classify_completion_context(alpha, issue, alpha_completion)
    beta_decision = HandoffRouteRecorder.classify_completion_context(beta, issue, beta_completion)

    assert alpha_decision.metadata.provenance.target_id == "alpha"
    assert beta_decision.metadata.provenance.target_id == "beta"
    assert :ok = HandoffRouteRecorder.record(alpha, alpha_decision)
    assert {:error, :tracker_write_not_allowed} = HandoffRouteRecorder.record(beta, beta_decision)

    assert_receive {:tracker_mutation, "alpha", :create_comment, %{issueId: "shared-issue"}}
    assert_receive {:tracker_mutation, "alpha", :resolve_state, %{issueId: "shared-issue"}}
    assert_receive {:tracker_mutation, "alpha", :update_state, %{issueId: "shared-issue"}}
    refute_received {:tracker_mutation, "beta", _operation, _variables}

    logs_root = Path.join(tmp_dir, "logs")

    record_params = fn quality_gate, decision ->
      %{
        logs_root: logs_root,
        project: %{slug: "symphony"},
        issue: issue,
        run: %{id: "shared-run"},
        quality_gate: quality_gate,
        handoff_route: decision
      }
    end

    assert {:ok, alpha_record} =
             ReviewRecords.write_quality_gate_run(
               alpha,
               record_params.(alpha_quality, alpha_decision)
             )

    assert {:ok, beta_record} =
             ReviewRecords.write_quality_gate_run(
               beta,
               record_params.(beta_quality, beta_decision)
             )

    refute alpha_record.record_dir == beta_record.record_dir
    assert alpha_record.record_dir =~ "/targets/alpha/"
    assert beta_record.record_dir =~ "/targets/beta/"

    Workflow.set_workflow_file_path(poisoned_workflow)
    assert Config.settings!().workspace.root == Path.expand(poisoned_root)

    assert_orchestrator_failure_isolation!(alpha, beta, issue)

    assert {:ok, _removed} = Workspace.remove(alpha)
    refute File.exists?(alpha.workspace_path)
    assert File.dir?(beta.workspace_path)
    assert {:ok, _removed} = Workspace.remove(beta)
    refute File.exists?(beta.workspace_path)
  end

  defp execution_context!(root, target_id, issue) do
    target_root = Path.join(root, "worktrees-#{target_id}")
    File.mkdir_p!(target_root)

    {:ok, loaded_workflow} = Workflow.current()
    {:ok, base_manifest} = Manifest.read(Workflow.workflow_file_path(), repo_setup?: false)

    {branch, source_concurrency, stall_timeout_ms, turn_result, scope, hash} =
      case target_id do
        "alpha" ->
          {"main", 1, 1_000, "success", %{"type" => "project", "project_id" => "project-alpha"}, @alpha_hash}

        "beta" ->
          {"release", 2, 600_000, "timeout", %{"type" => "team", "team_key" => "BETA"}, @beta_hash}
      end

    manifest =
      Map.merge(base_manifest, %{
        "project" => %{
          "slug" => "symphony-#{target_id}",
          "repository" => "https://github.com/example/#{target_id}"
        },
        "delivery" => %{"pr_target" => branch},
        "prompt_template" => "target=#{target_id} policy={{ policy.target }} checks=#{target_id}",
        "quality_gate" => %{
          "enabled" => true,
          "source_max_concurrency" => source_concurrency,
          "max_repair_passes" => 0,
          "runtime_isolation" => "serialized"
        }
      })

    resolution = manifest |> Manifest.compile() |> Map.fetch!(:workflow_module_resolution)
    runner_name = "runner-#{target_id}"

    runner = %{
      "kind" => "codex_app_server",
      "command" => ["codex", "app-server"],
      "approval_policy" => "never",
      "thread_sandbox" => "workspace-write",
      "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => false},
      "turn_timeout_ms" => if(target_id == "alpha", do: 4_000, else: 7_000),
      "read_timeout_ms" => 2_000,
      "stall_timeout_ms" => stall_timeout_ms,
      "max_turns" => 1,
      "test_turn_result" => turn_result,
      "execution_profiles" => %{
        "implementation" => %{
          "model" => "model-#{target_id}",
          "timeout_ms" => if(target_id == "alpha", do: 4_000, else: 7_000),
          "max_retries" => if(target_id == "alpha", do: 1, else: 2)
        },
        "source_reviewer" => %{
          "model" => "review-#{target_id}",
          "timeout_ms" => 5_000,
          "max_retries" => 0
        }
      }
    }

    gates = delivery_gates(if(target_id == "alpha", do: "allow", else: "deny"))

    target = %TargetContext{
      target_id: target_id,
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: hash,
      policy_hash: hash,
      repo_manifest_hash: hash,
      repo_policy: %{
        "manifest" => manifest,
        "manifest_source_dir" => loaded_workflow.manifest_source_dir,
        "workflow_module_resolution" => resolution_projection(resolution)
      },
      tracker_connection: %{
        "id" => "linear-#{target_id}",
        "policy" => %{
          "kind" => "linear",
          "endpoint" => "https://#{target_id}.example.invalid/graphql",
          "api_key" => "token-#{target_id}"
        }
      },
      run_target: %{
        "scope" => scope,
        "active_states" => ["#{String.capitalize(target_id)} Active"],
        "terminal_states" => ["Done"],
        "required_labels" => ["target:#{target_id}"]
      },
      worktree_policy: %{
        "root" => target_root,
        "strategy" => "per_issue",
        "hooks" => %{
          "after_create" => nil,
          "before_run" => "printf 'before-#{target_id}' > before.txt",
          "after_run" => "printf 'after-#{target_id}' > after.txt",
          "before_remove" => nil,
          "timeout_ms" => 5_000
        }
      },
      runner_policy: %{
        "default" => runner_name,
        "allowed" => [runner_name],
        "runners" => %{runner_name => runner}
      },
      effective_checks: %{
        "repository" => %{"validation" => ["mix test.#{target_id}"], "auto_land" => []},
        "target" => %{"pre_handoff" => ["mix test.#{target_id}"], "source" => target_id}
      },
      external_side_effect_gates: gates,
      capacity_limits: %{"max_concurrent_agents" => source_concurrency},
      budget_limits: %{}
    }

    policy = %{
      "capabilities" => %{"required" => []},
      "delivery" => %{"pr_target" => branch},
      "manifest" => manifest,
      "publish_target" => %{
        "repository" => "https://github.com/example/#{target_id}",
        "pr_target" => branch,
        "github_repository" => "example/#{target_id}",
        "display" => "example/#{target_id}:#{branch}"
      },
      "target" => target_id,
      "target_restrictions" => %{
        "effective_checks" => target.effective_checks,
        "external_side_effect_gates" => gates
      }
    }

    assert {:ok, context} = ExecutionContext.new(target, issue, policy: policy)
    context
  end

  defp quality_runner(parent) do
    fn %{execution_context: child, settings: settings} ->
      target_id = child.target.target_id

      send(parent, {
        :quality_check,
        target_id,
        child.role,
        child.execution_profile.model,
        get_in(child.policy, ["delivery", "pr_target"]),
        settings.source_max_concurrency
      })

      if target_id == "alpha" do
        %{status: :passed, summary: "alpha clean", findings: []}
      else
        %{
          status: :fix_required,
          findings: [
            %{
              severity: :major,
              category: :source_correctness,
              evidence: "Beta requires a target-scoped repair.",
              affected_files: ["lib/change.ex"],
              reproducibility_notes: "Run mix test.beta.",
              recommended_disposition: :fix_required
            }
          ]
        }
      end
    end
  end

  defp publish_runner(parent) do
    fn command ->
      send(parent, {:publish, command.provenance.target_id, command.step})

      output = Map.get(@publish_outputs, command.step, "ok\n")
      status = if command.step in @publish_failure_steps, do: 1, else: 0
      {:ok, %{status: status, output: output}}
    end
  end

  defp route_completion(quality_gate, publish_preflight) do
    %{
      checks: [%{name: "target", status: :passed}],
      review: %{status: :clean},
      change_manifest: %{changed_files: ["lib/change.ex"]},
      quality_gate: quality_gate,
      publish_preflight: publish_preflight
    }
  end

  defp assert_orchestrator_failure_isolation!(alpha, beta, issue) do
    orchestrator_name = Module.concat(__MODULE__, :IsolationOrchestrator)
    {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)
    alpha_worker = sleeper()
    beta_worker = sleeper()

    on_exit(fn ->
      stop_if_alive(alpha_worker)
      stop_if_alive(beta_worker)
      if Process.alive?(orchestrator), do: Process.exit(orchestrator, :normal)
    end)

    stale_at = DateTime.add(DateTime.utc_now(), -5, :second)
    active_at = DateTime.utc_now()
    alpha_run_id = ExecutionContext.run_id(alpha)
    beta_run_id = ExecutionContext.run_id(beta)
    alpha_ref = make_ref()
    beta_ref = make_ref()

    alpha_entry = running_entry(alpha, issue, alpha_worker, alpha_ref, stale_at)
    beta_entry = running_entry(beta, issue, beta_worker, beta_ref, active_at)

    :sys.replace_state(orchestrator, fn state ->
      %{
        state
        | max_concurrent_agents: 2,
          running: %{alpha_run_id => alpha_entry, beta_run_id => beta_entry},
          claimed: MapSet.new([alpha_run_id, beta_run_id])
      }
    end)

    send(orchestrator, :run_poll_cycle)
    _snapshot = GenServer.call(orchestrator, :snapshot)
    stalled_state = :sys.get_state(orchestrator)

    refute Map.has_key?(stalled_state.running, alpha_run_id)
    assert stalled_state.retry_attempts[alpha_run_id].execution_context == alpha
    assert stalled_state.running[beta_run_id].execution_context == beta
    assert Process.alive?(beta_worker)

    stop_if_alive(beta_worker)
    send(orchestrator, {:DOWN, beta_ref, :process, beta_worker, :boom})
    _snapshot = GenServer.call(orchestrator, :snapshot)
    crashed_state = :sys.get_state(orchestrator)

    assert crashed_state.retry_attempts[alpha_run_id].execution_context == alpha
    assert crashed_state.retry_attempts[beta_run_id].execution_context == beta
    assert map_size(crashed_state.retry_attempts) == 2

    blocked_worker = sleeper()
    blocked_ref = make_ref()
    blocked_at = DateTime.utc_now()

    on_exit(fn -> stop_if_alive(blocked_worker) end)

    blocked_entry =
      beta
      |> running_entry(issue, blocked_worker, blocked_ref, blocked_at)
      |> Map.merge(%{
        last_runtime_message: %{
          event: :turn_input_required,
          message: %{"method" => "turn/input_required"},
          timestamp: blocked_at
        },
        last_runtime_event: :turn_input_required
      })

    :sys.replace_state(orchestrator, fn state ->
      %{
        state
        | running: Map.put(state.running, beta_run_id, blocked_entry),
          retry_attempts: Map.delete(state.retry_attempts, beta_run_id),
          claimed: MapSet.put(state.claimed, beta_run_id)
      }
    end)

    stop_if_alive(blocked_worker)
    send(orchestrator, {:DOWN, blocked_ref, :process, blocked_worker, {:shutdown, :input_required}})
    _snapshot = GenServer.call(orchestrator, :snapshot)
    blocked_state = :sys.get_state(orchestrator)

    assert blocked_state.retry_attempts[alpha_run_id].execution_context == alpha
    refute Map.has_key?(blocked_state.retry_attempts, beta_run_id)
    assert blocked_state.blocked[beta_run_id].execution_context == beta
    assert blocked_state.blocked[beta_run_id].error == "runtime turn requires operator input"
  end

  defp running_entry(context, issue, pid, ref, timestamp) do
    %{
      pid: pid,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      execution_context: context,
      worker_host: context.worker_host,
      workspace_path: context.workspace_path,
      stall_timeout_ms: context.runner_config["stall_timeout_ms"],
      runtime: String.to_atom(context.runner_config["kind"]),
      session_id: "session-#{context.target.target_id}",
      last_runtime_message: nil,
      last_runtime_timestamp: timestamp,
      last_runtime_progress_timestamp: timestamp,
      last_runtime_event: :turn_started,
      last_runtime_error_signature: nil,
      startup_slot?: false,
      runtime_input_tokens: 0,
      runtime_output_tokens: 0,
      runtime_total_tokens: 0,
      runtime_last_reported_input_tokens: 0,
      runtime_last_reported_output_tokens: 0,
      runtime_last_reported_total_tokens: 0,
      turn_count: 1,
      retry_attempt: 0,
      profile: "default",
      target: context.target.target_id,
      policy_ref: context.policy["policy_ref"],
      workflow_module_resolution: context.target.repo_policy["workflow_module_resolution"],
      started_at: timestamp
    }
  end

  defp sleeper do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp delivery_gates(publish) do
    %{
      "tracker_write" => publish,
      "vcs_publish" => publish,
      "pull_request_write" => publish,
      "merge" => "deny",
      "deployment" => "deny",
      "production_data" => "deny"
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

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
