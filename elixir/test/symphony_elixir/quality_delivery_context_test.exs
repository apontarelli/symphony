defmodule SymphonyElixir.QualityDeliveryContextTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{
    ExecutionContext,
    HandoffRouteRecorder,
    PublishHandoff,
    PublishPreflight,
    QualityGate,
    ReviewRecords,
    TargetContext
  }

  alias SymphonyElixir.Linear.Issue

  defmodule QualityGateAdapter do
    @behaviour SymphonyElixir.AgentRuntime

    alias SymphonyElixir.AgentRuntime.Event
    alias SymphonyElixir.ExecutionContext

    @impl true
    def start(%ExecutionContext{} = context, _issue, []), do: {:ok, context}

    @impl true
    def send_turn(%ExecutionContext{} = context, _prompt, _issue, opts) do
      failure_mode =
        if context.role == :implementation,
          do: nil,
          else: context.runner_config["test_failure"]

      case failure_mode do
        "always" -> {:error, :configured_failure}
        "once" -> fail_once(context, opts)
        _mode -> complete_turn(context, opts)
      end
    end

    defp fail_once(context, opts) do
      key = {__MODULE__, context.role}

      case Process.get(key, 0) do
        0 ->
          Process.put(key, 1)
          {:error, :configured_failure}

        _attempt ->
          complete_turn(context, opts)
      end
    end

    defp complete_turn(context, opts) do
      status = if context.role == :implementation, do: "passed", else: "fix_required"

      findings =
        if status == "passed" do
          []
        else
          [
            %{
              "category" => "source_correctness",
              "evidence" => "Exercise the pinned default reviewer.",
              "recommended_disposition" => "fix_required"
            }
          ]
        end

      {:ok, event} =
        Event.new(:turn_completed,
          payload: %{
            "params" => %{
              "completion" => %{
                "quality_gate_reviewer" => %{
                  "status" => status,
                  "findings" => findings
                }
              }
            }
          }
        )

      :ok = Keyword.fetch!(opts, :on_event).(event)
      {:ok, %{session_id: "session-#{context.role}"}}
    end

    @impl true
    def stop(%ExecutionContext{}), do: :ok

    @impl true
    def capabilities(_runner_config), do: %{}
  end

  @hash "sha256:" <> String.duplicate("a", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-quality-delivery-context-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_preflight_runner = Application.get_env(:symphony_elixir, :publish_preflight_runner)
    previous_handoff_runner = Application.get_env(:symphony_elixir, :publish_handoff_runner)

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      restore_env(:memory_tracker_recipient, previous_recipient)
      restore_env(:publish_preflight_runner, previous_preflight_runner)
      restore_env(:publish_handoff_runner, previous_handoff_runner)
      File.rm_rf(root)
    end)

    issue = %Issue{
      id: "issue-419",
      identifier: "SID-419",
      title: "Context isolation",
      state: "In Progress",
      labels: ["repo:symphony"],
      url: "https://linear.example/SID-419"
    }

    alpha = execution_context!(root, "alpha", issue, "main", 1, delivery_gates("allow"))
    beta = execution_context!(root, "beta", issue, "release", 2, delivery_gates("deny"))

    %{root: root, issue: issue, alpha: alpha, beta: beta}
  end

  test "default context reviewer and repair use pinned runtime dispatch", %{
    issue: issue,
    alpha: alpha
  } do
    context =
      alpha
      |> put_in(
        [Access.key!(:target), Access.key!(:repo_policy), "manifest", "quality_gate", "max_repair_passes"],
        1
      )
      |> replace_runner(fn runner ->
        test_profile =
          runner["execution_profiles"]["source_reviewer"]
          |> Map.put("max_retries", 1)

        runner
        |> Map.put("test_failure", "once")
        |> put_in(["execution_profiles", "source_reviewer"], test_profile)
        |> put_in(["execution_profiles", "test_reviewer"], test_profile)
      end)

    assert :ok = ExecutionContext.validate(context)

    result =
      QualityGate.run_context(
        context,
        issue,
        %{changed_files: ["lib/source.ex"]},
        adapter_registry: %{"codex_app_server" => QualityGateAdapter}
      )

    assert result.status == :fix_required, inspect(result, pretty: true)
    assert [%{repair_result: %{status: :passed}}] = result.repair_passes

    assert Enum.all?(
             result.final_jobs,
             &match?(%{provenance: %{target_id: "alpha"}}, &1)
           )

    failing_context = replace_runner(alpha, &Map.put(&1, "test_failure", "always"))

    blocked =
      QualityGate.run_context(
        failing_context,
        issue,
        %{changed_files: ["lib/source.ex"]},
        adapter_registry: %{"codex_app_server" => QualityGateAdapter}
      )

    assert blocked.status == :blocked

    unavailable_context =
      replace_runner(alpha, &Map.put(&1, "command", ["/definitely/missing-codex"]))

    assert %{status: :blocked} =
             QualityGate.run_context(
               unavailable_context,
               issue,
               %{changed_files: ["lib/source.ex"]}
             )
  end

  test "all reviewer roles derive from the implementation context", %{
    issue: issue,
    alpha: alpha
  } do
    completion = %{
      changed_files: [
        "lib/source.ex",
        "test/source_test.exs",
        "README.md",
        "priv/repo/migrations/20260825000000_change.exs",
        "assets/app.tsx"
      ],
      changed_surfaces: [:runtime, :product, :security, :docs, :tests]
    }

    result =
      QualityGate.run_context(alpha, issue, completion,
        runner: fn _context -> %{status: :passed, summary: "clean", findings: []} end,
        browser_preflight: fn _context -> :ok end,
        host_visual_qa: fn _context -> :skip end
      )

    roles =
      result.final_jobs
      |> Enum.map(& &1.provenance.role)
      |> MapSet.new()

    assert roles ==
             MapSet.new([
               "source_reviewer",
               "test_reviewer",
               "runtime_qa",
               "product_visual_review",
               "docs_reviewer",
               "security_reviewer"
             ])
  end

  test "review child contexts enforce role sandbox policies", %{
    issue: issue,
    alpha: alpha
  } do
    parent = self()

    runner = fn %{execution_context: child} ->
      assert {:ok, runtime_settings} = SymphonyElixir.Config.codex_runtime_settings(child)
      send(parent, {:review_sandbox, child.role, runtime_settings.turn_sandbox_policy})
      %{status: :passed, summary: "clean", findings: []}
    end

    result =
      QualityGate.run_context(
        alpha,
        issue,
        %{
          changed_files: ["lib/source.ex", "assets/app.tsx"],
          changed_surfaces: [:product]
        },
        runner: runner,
        browser_preflight: fn _context -> :ok end,
        host_visual_qa: fn _context -> :skip end
      )

    assert result.status == :passed
    assert_receive {:review_sandbox, :source_reviewer, %{"type" => "readOnly"}}

    assert_receive {:review_sandbox, :product_visual_review,
                    %{
                      "type" => "workspaceWrite",
                      "networkAccess" => true,
                      "writableRoots" => [workspace]
                    }}

    assert workspace == alpha.workspace_path

    host_visual_result =
      QualityGate.run_context(
        alpha,
        issue,
        %{changed_files: ["assets/app.tsx"], changed_surfaces: [:product]},
        runner: runner,
        browser_preflight: fn _context -> flunk("host visual evidence bypasses browser preflight") end,
        host_visual_qa: fn _context ->
          {:ok, %{"status" => "passed", "summary" => "Pinned host visual evidence"}}
        end
      )

    assert host_visual_result.status == :passed
    assert_receive {:review_sandbox, :product_visual_review, %{"type" => "readOnly"}}
  end

  test "context entrypoints reject invalid authority and options before side effects", %{
    root: root,
    issue: issue,
    alpha: alpha
  } do
    bad_issue = %{issue | id: "other-issue"}
    invalid_context = %{alpha | workspace_path: Path.join(root, "wrong")}
    runner = fn _payload -> flunk("invalid context reached a side effect") end

    assert ExecutionContext.safe_provenance(:invalid) == {:error, :invalid_context}

    assert {:ok, child} =
             ExecutionContext.derive_child(alpha, :source_reviewer, profile: "source_reviewer")

    assert {:error, :invalid_quality_gate_context} =
             QualityGate.run_context(child, issue, %{})

    assert {:error, :invalid_quality_gate_context} =
             QualityGate.run_context(alpha, bad_issue, %{}, runner: runner)

    assert {:error, :invalid_quality_gate_context} =
             QualityGate.run_context(invalid_context, issue, %{}, runner: runner)

    assert {:error, :invalid_quality_gate_options} =
             QualityGate.run_context(alpha, issue, %{}, :invalid)

    assert {:error, :invalid_quality_gate_completion} =
             QualityGate.run_context(alpha, issue, :invalid, runner: runner)

    assert {:error, :invalid_quality_gate_options} =
             QualityGate.run_context(alpha, issue, %{},
               runner: runner,
               runner: runner
             )

    malformed_settings =
      put_in(
        alpha.target.repo_policy["manifest"]["quality_gate"],
        "invalid"
      )

    assert {:error, :invalid_quality_gate_settings} =
             QualityGate.run_context(malformed_settings, issue, %{}, runner: runner)

    invalid_settings =
      put_in(
        alpha.target.repo_policy["manifest"]["quality_gate"],
        %{"source_max_concurrency" => 0}
      )

    assert {:error, :invalid_quality_gate_settings} =
             QualityGate.run_context(invalid_settings, issue, %{}, runner: runner)

    default_settings =
      update_in(
        alpha.target.repo_policy["manifest"],
        &Map.delete(&1, "quality_gate")
      )

    assert %{status: :passed} =
             QualityGate.run_context(default_settings, issue, %{}, runner: runner)

    legacy_invalid =
      QualityGate.run(
        alpha.workspace_path,
        alpha.policy,
        issue,
        %{changed_files: ["lib/source.ex"]},
        execution_context: :invalid,
        runner: runner
      )

    assert legacy_invalid.status == :blocked

    assert PublishPreflight.run_context(:invalid) ==
             {:error, :invalid_publish_preflight_context}

    assert PublishPreflight.run_context(alpha, :invalid) ==
             {:error, :invalid_publish_preflight_options}

    assert PublishPreflight.run_context(invalid_context, runner: runner) ==
             {:error, :invalid_publish_preflight_context}

    assert PublishHandoff.run_context(:invalid, issue, %{}) ==
             {:error, :invalid_publish_handoff_context}

    assert PublishHandoff.run_context(alpha, issue, %{}, :invalid) ==
             {:error, :invalid_publish_handoff_options}

    assert PublishHandoff.run_context(invalid_context, issue, %{}, runner: runner) ==
             {:error, :invalid_publish_handoff_context}

    assert PublishHandoff.run_context(alpha, bad_issue, %{}, runner: runner) ==
             {:error, :invalid_publish_handoff_context}

    assert HandoffRouteRecorder.classify_completion_context(:invalid, issue, %{}) ==
             {:error, :invalid_handoff_context}

    assert HandoffRouteRecorder.classify_completion_context(invalid_context, issue, %{}) ==
             {:error, :invalid_handoff_context}

    decision = HandoffRouteRecorder.classify_completion_context(alpha, issue, %{})

    assert HandoffRouteRecorder.record(invalid_context, decision) ==
             {:error, :invalid_handoff_context}

    assert ReviewRecords.write_quality_gate_run(alpha, :invalid) ==
             {:error, :invalid_review_record_params}

    assert ReviewRecords.write_quality_gate_run(alpha, %{}) ==
             {:error, :missing_review_record_root}

    assert ReviewRecords.write_quality_gate_run(alpha, %{
             logs_root: Path.join(root, "logs"),
             issue: bad_issue,
             quality_gate: %{}
           }) ==
             {:error, :review_record_issue_mismatch}

    {:ok, provenance} = ExecutionContext.safe_provenance(alpha)

    assert ReviewRecords.write_quality_gate_run(alpha, %{
             logs_root: Path.join(root, "logs"),
             quality_gate: %{provenance: provenance},
             handoff_route: :invalid
           }) ==
             {:error, :review_record_context_mismatch}
  end

  test "reviewers derive target-scoped child contexts from pinned authority", %{
    issue: issue,
    alpha: alpha,
    beta: beta
  } do
    parent = self()

    runner = fn %{execution_context: child, policy: policy, settings: settings} ->
      send(parent, {
        :reviewer,
        child.target.target_id,
        child.role,
        child.execution_profile.model,
        get_in(policy, ["delivery", "pr_target"]),
        settings.source_max_concurrency
      })

      %{status: :passed, summary: "clean", findings: []}
    end

    [alpha_result, beta_result] =
      [alpha, beta]
      |> Task.async_stream(
        &QualityGate.run_context(&1, issue, %{changed_files: ["lib/source.ex"]}, runner: runner),
        ordered: true,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert alpha_result.status == :passed
    assert beta_result.status == :passed
    assert alpha_result.provenance.target_id == "alpha"
    assert beta_result.provenance.target_id == "beta"

    assert_receive {:reviewer, "alpha", :source_reviewer, "review-alpha", "main", 1}
    assert_receive {:reviewer, "beta", :source_reviewer, "review-beta", "release", 2}

    assert Enum.any?(
             alpha_result.final_jobs,
             &match?(%{provenance: %{target_id: "alpha", role: "source_reviewer"}}, &1)
           )

    assert Enum.all?(
             alpha_result.final_jobs,
             &match?(%{provenance: %{target_id: "alpha"}}, &1)
           )

    assert Enum.any?(
             beta_result.final_jobs,
             &match?(%{provenance: %{target_id: "beta", role: "source_reviewer"}}, &1)
           )

    assert Enum.all?(
             beta_result.final_jobs,
             &match?(%{provenance: %{target_id: "beta"}}, &1)
           )
  end

  test "publish preflight uses pinned targets and delivery gates", %{
    issue: issue,
    alpha: alpha,
    beta: beta
  } do
    parent = self()

    poison = fn command ->
      send(parent, {:global_runner_used, command})
      {:error, :global_runner_used}
    end

    Application.put_env(:symphony_elixir, :publish_preflight_runner, poison)
    Application.put_env(:symphony_elixir, :publish_handoff_runner, poison)

    runner = fn command ->
      send(parent, {:preflight, command.provenance.target_id, command.step})
      {:ok, %{status: 0, output: "ok"}}
    end

    alpha_task = Task.async(fn -> PublishPreflight.run_context(alpha, runner: runner) end)
    beta_task = Task.async(fn -> PublishPreflight.run_context(beta, runner: runner) end)

    alpha_result = Task.await(alpha_task)
    beta_result = Task.await(beta_task)

    assert alpha_result.status == :passed, inspect(alpha_result, pretty: true)
    assert alpha_result.repository == "https://github.com/example/alpha"
    assert alpha_result.base_branch == "main"
    assert alpha_result.provenance.target_id == "alpha"

    assert beta_result.status == :blocked
    assert beta_result.repository == "https://github.com/example/beta"
    assert beta_result.base_branch == "release"
    assert [%{class: :delivery_not_allowed}] = beta_result.failures
    assert beta_result.provenance.target_id == "beta"

    assert %{status: :blocked, failure: %{reason: :publish_preflight_missing}} =
             PublishHandoff.run_context(alpha, issue, %{}, runner: runner)

    publish_runner = fn command ->
      send(parent, {:publish, command.provenance.target_id, command.step})

      output =
        case command.step do
          :git_remote_get_url -> "git@github.com:example/alpha.git\n"
          :git_committed_changed_files -> "lib/source.ex\n"
          :git_unstaged_changed_files -> ""
          :git_staged_changed_files -> ""
          :git_untracked_files -> ""
          :git_diff_cached -> ""
          :git_current -> "1234567890abcdef\n"
          :pr_view -> "no pull request found"
          :pr_create -> "https://github.com/example/alpha/pull/42\n"
          _step -> "ok\n"
        end

      status = if command.step in [:git_diff_cached, :pr_view], do: 1, else: 0
      {:ok, %{status: status, output: output}}
    end

    assert %{
             status: :passed,
             pr_url: "https://github.com/example/alpha/pull/42",
             provenance: %{target_id: "alpha"}
           } =
             PublishHandoff.run_context(
               alpha,
               issue,
               %{
                 publish_preflight: alpha_result,
                 change_manifest: %{changed_files: ["lib/source.ex"]}
               },
               runner: publish_runner
             )

    assert_receive {:publish, "alpha", :git_remote_get_url}
    assert_receive {:publish, "alpha", :pr_create}

    assert %{status: :blocked, failure: %{reason: :delivery_not_allowed}} =
             PublishHandoff.run(
               alpha.workspace_path,
               alpha.policy,
               issue,
               %{},
               delivery_gates: :invalid
             )

    assert %{status: :blocked, failure: %{reason: :change_manifest_missing}} =
             PublishHandoff.run_context(
               alpha,
               issue,
               %{publish_preflight: alpha_result},
               runner: runner
             )

    assert %{status: :blocked, failure: %{reason: :delivery_not_allowed}} =
             PublishHandoff.run_context(
               beta,
               issue,
               %{publish_preflight: beta_result},
               runner: runner
             )

    assert {:error, :publish_preflight_context_mismatch} =
             PublishHandoff.run_context(
               beta,
               issue,
               %{publish_preflight: alpha_result},
               runner: runner
             )

    assert_receive {:preflight, "alpha", :workspace_vcs_metadata}
    assert_receive {:preflight, "alpha", :remote_push}
    assert_receive {:preflight, "alpha", :pr_creation}
    refute_receive {:preflight, "beta", _step}
    refute_receive {:global_runner_used, _command}
  end

  test "handoff evidence tracker writes and records stay bound to one context", %{
    root: root,
    issue: issue,
    alpha: alpha,
    beta: beta
  } do
    quality_runner = fn _context -> %{status: :passed, summary: "clean", findings: []} end
    preflight_runner = fn _command -> {:ok, %{status: 0, output: "ok"}} end

    alpha_quality =
      QualityGate.run_context(alpha, issue, %{changed_files: ["lib/source.ex"]}, runner: quality_runner)

    beta_quality =
      QualityGate.run_context(beta, issue, %{changed_files: ["lib/source.ex"]}, runner: quality_runner)

    alpha_preflight = PublishPreflight.run_context(alpha, runner: preflight_runner)
    beta_preflight = PublishPreflight.run_context(beta, runner: preflight_runner)

    alpha_completion =
      alpha_quality
      |> route_completion(alpha_preflight)
      |> Map.put(:run_id, "run-419")

    beta_completion = route_completion(beta_quality, beta_preflight)

    alpha_decision =
      HandoffRouteRecorder.classify_completion_context(
        alpha,
        issue,
        alpha_completion
      )

    beta_decision =
      HandoffRouteRecorder.classify_completion_context(
        beta,
        issue,
        beta_completion
      )

    assert alpha_decision.metadata.provenance.target_id == "alpha"
    assert alpha_decision.metadata.provenance.run_id == "run-419"
    assert beta_decision.metadata.provenance.target_id == "beta"

    assert {:error, :handoff_evidence_context_mismatch} =
             HandoffRouteRecorder.classify_completion_context(
               beta,
               issue,
               alpha_completion
             )

    assert {:error, :handoff_evidence_context_mismatch} =
             HandoffRouteRecorder.classify_completion_context(
               alpha,
               issue,
               %{quality_gate: :invalid}
             )

    assert {:error, :handoff_evidence_context_mismatch} =
             HandoffRouteRecorder.classify_completion_context(
               alpha,
               issue,
               :invalid
             )

    assert :ok = HandoffRouteRecorder.record(alpha, alpha_decision)
    assert_receive {:memory_tracker_comment, "issue-419", comment}
    assert comment =~ "Target: `alpha`"
    assert comment =~ alpha.target.registry_generation
    refute comment =~ "token-alpha"
    alpha_target_state = alpha_decision.target_state
    assert_receive {:memory_tracker_state_update, "issue-419", ^alpha_target_state}
    mismatched_decision = %{alpha_decision | metadata: %{provenance: :invalid}}

    assert {:error, :handoff_context_mismatch} =
             HandoffRouteRecorder.record(alpha, mismatched_decision)

    assert {:error, :tracker_write_not_allowed} =
             HandoffRouteRecorder.record(beta, beta_decision)

    logs_root = Path.join(root, "logs")

    params = fn quality_gate, decision ->
      %{
        logs_root: logs_root,
        project: %{slug: "symphony"},
        issue: issue,
        run: %{id: "shared-run"},
        quality_gate: quality_gate,
        handoff_route: decision
      }
    end

    alpha_record_task =
      Task.async(fn ->
        ReviewRecords.write_quality_gate_run(
          alpha,
          params.(alpha_quality, alpha_decision)
        )
      end)

    beta_record_task =
      Task.async(fn ->
        ReviewRecords.write_quality_gate_run(
          beta,
          params.(beta_quality, beta_decision)
        )
      end)

    assert {:ok, alpha_record} = Task.await(alpha_record_task)
    assert {:ok, beta_record} = Task.await(beta_record_task)
    refute alpha_record.record_dir == beta_record.record_dir
    assert alpha_record.record_dir =~ "/targets/alpha/"
    assert beta_record.record_dir =~ "/targets/beta/"

    alpha_metadata = alpha_record.files.metadata |> File.read!() |> Jason.decode!()
    beta_metadata = beta_record.files.metadata |> File.read!() |> Jason.decode!()

    assert alpha_metadata["provenance"]["target_id"] == "alpha"
    assert beta_metadata["provenance"]["target_id"] == "beta"
    assert alpha_metadata["provenance"]["run_id"] == "shared-run"
    refute File.read!(alpha_record.files.metadata) =~ "token-alpha"
    refute File.read!(beta_record.files.metadata) =~ "token-beta"

    assert {:error, :review_record_context_mismatch} =
             ReviewRecords.write_quality_gate_run(
               beta,
               params.(alpha_quality, beta_decision)
             )
  end

  test "review child contexts cannot publish mutate trackers or write evidence", %{
    root: root,
    issue: issue,
    alpha: alpha
  } do
    assert {:ok, child} =
             ExecutionContext.derive_child(alpha, :source_reviewer, profile: "source_reviewer")

    notifier = fn payload ->
      send(self(), {:unexpected_side_effect, payload})
      {:ok, %{status: 0, output: "ok"}}
    end

    assert {:error, :invalid_quality_gate_context} =
             QualityGate.run_context(child, issue, %{changed_files: ["lib/source.ex"]}, runner: notifier)

    assert {:error, :invalid_publish_preflight_context} =
             PublishPreflight.run_context(child, runner: notifier)

    assert {:error, :invalid_publish_handoff_context} =
             PublishHandoff.run_context(child, issue, %{}, runner: notifier)

    assert {:error, :invalid_handoff_context} =
             HandoffRouteRecorder.classify_completion_context(child, issue, %{})

    assert {:error, :invalid_review_record_context} =
             ReviewRecords.write_quality_gate_run(child, %{
               logs_root: Path.join(root, "logs"),
               quality_gate: %{}
             })

    refute_receive {:unexpected_side_effect, _payload}
  end

  defp execution_context!(root, target_id, issue, branch, source_concurrency, gates) do
    target_root = Path.join(root, target_id)
    File.mkdir_p!(Path.join([target_root, issue.identifier, "lib"]))
    File.write!(Path.join([target_root, issue.identifier, "lib/source.ex"]), "defmodule Source do\nend\n")

    runner_name = "runner-#{target_id}"

    runner = %{
      "kind" => "codex_app_server",
      "command" => ["codex", "app-server"],
      "approval_policy" => "never",
      "thread_sandbox" => "workspace-write",
      "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => false},
      "turn_timeout_ms" => 5_000,
      "max_turns" => 1,
      "execution_profiles" => %{
        "implementation" => %{
          "model" => "implementation-#{target_id}",
          "timeout_ms" => 5_000,
          "max_retries" => 0
        },
        "source_reviewer" => %{
          "model" => "review-#{target_id}",
          "timeout_ms" => 5_000,
          "max_retries" => 0
        }
      }
    }

    manifest = %{
      "project" => %{
        "slug" => "symphony",
        "repository" => "https://github.com/example/#{target_id}"
      },
      "delivery" => %{"pr_target" => branch},
      "vcs" => %{"mode" => "git"},
      "quality_gate" => %{
        "enabled" => true,
        "source_max_concurrency" => source_concurrency,
        "max_repair_passes" => 0,
        "runtime_isolation" => "serialized"
      }
    }

    target = %TargetContext{
      target_id: target_id,
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: @hash,
      policy_hash: @hash,
      repo_manifest_hash: @hash,
      repo_policy: %{
        "manifest" => manifest,
        "manifest_source_dir" => root,
        "workflow_module_resolution" => %{"modules" => []}
      },
      tracker_connection: %{
        "id" => "memory-#{target_id}",
        "policy" => %{
          "kind" => "memory",
          "endpoint" => "memory://#{target_id}",
          "api_key" => "token-#{target_id}"
        }
      },
      run_target: %{},
      worktree_policy: %{
        "root" => target_root,
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
        "default" => runner_name,
        "allowed" => [runner_name],
        "runners" => %{runner_name => runner}
      },
      effective_checks: %{
        "repository" => %{"validation" => [], "auto_land" => []},
        "target" => %{"pre_handoff" => ["quality_gate"], "source" => target_id}
      },
      external_side_effect_gates: gates,
      capacity_limits: %{},
      budget_limits: %{}
    }

    policy = %{
      "capabilities" => %{"required" => []},
      "delivery" => %{"pr_target" => branch},
      "publish_target" => %{
        "repository" => "https://github.com/example/#{target_id}",
        "pr_target" => branch,
        "github_repository" => "example/#{target_id}",
        "display" => "example/#{target_id}:#{branch}"
      },
      "manifest" => manifest,
      "target_restrictions" => %{
        "effective_checks" => target.effective_checks,
        "external_side_effect_gates" => gates
      }
    }

    assert {:ok, context} = ExecutionContext.new(target, issue, policy: policy)
    context
  end

  defp replace_runner(%ExecutionContext{} = context, update) when is_function(update, 1) do
    runner = update.(context.runner_config)

    runner_policy =
      Map.update!(
        context.target.runner_policy,
        "runners",
        &Map.put(&1, context.runner_name, runner)
      )

    target = %{context.target | runner_policy: runner_policy}
    issue = %Issue{id: context.issue_id, identifier: context.issue_identifier}

    assert {:ok, replaced} =
             ExecutionContext.new(target, issue,
               policy: context.policy,
               worker_host: context.worker_host
             )

    replaced
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

  defp route_completion(quality_gate, publish_preflight) do
    %{
      checks: [%{name: "all", status: :passed}],
      review: %{status: :clean},
      change_manifest: %{changed_files: ["lib/source.ex"]},
      quality_gate: quality_gate,
      publish_preflight: publish_preflight
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
