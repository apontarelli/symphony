defmodule SymphonyElixir.QualityGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ExecutionProfile
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HandoffRouteRecorder
  alias SymphonyElixir.QualityGate
  alias SymphonyElixir.QualityGate.Planner
  alias SymphonyElixir.QualityGate.Synthesis

  test "planner selects required review categories from changed scope" do
    completion = %{
      changed_files: [
        "elixir/lib/symphony_elixir/orchestrator.ex",
        "elixir/test/symphony_elixir/orchestrator_status_test.exs",
        "elixir/lib/symphony_elixir_web/live/dashboard_live.ex",
        "elixir/priv/static/dashboard.css",
        "elixir/README.md",
        "elixir/lib/symphony_elixir/ssh.ex"
      ],
      changed_surfaces: [:workflow, :tests, :web_ui, :docs]
    }

    plan =
      Planner.plan(%{
        completion: completion,
        issue: %Issue{identifier: "SID-319", title: "Quality gate fanout", labels: ["security"]},
        policy: %{},
        settings: Config.settings!().quality_gate,
        workspace: "/tmp/symphony-workspace"
      })

    categories = MapSet.new(plan.jobs, & &1.category)

    assert categories ==
             MapSet.new([
               :source_correctness,
               :test_quality,
               :scenario_qa,
               :product_visual_review,
               :docs_source_of_truth,
               :security_data_migration
             ])

    assert Enum.all?(plan.jobs, &(&1.required? == true))
    assert source_job = Enum.find(plan.jobs, &(&1.category == :source_correctness))
    assert source_job.execution_mode == :parallel_source
    assert source_job.prompt =~ "Role: You are the read-only source correctness reviewer"
    assert source_job.prompt =~ "Return a passing result when no fix-required finding remains"
    assert source_job.prompt =~ "Constraints: Do not edit files."

    assert qa_job = Enum.find(plan.jobs, &(&1.category == :scenario_qa))
    assert qa_job.execution_mode == :serialized_runtime
    assert qa_job.isolation == :serialized
  end

  test "planner reuses handoff manifest aliases for changed-file scope" do
    direct_alias =
      Planner.plan(%{
        completion: %{"changedFiles" => [" lib/source.ex ", "", 123]},
        settings: %Schema.QualityGate{}
      })

    assert direct_alias.changed_files == ["lib/source.ex"]
    assert Enum.any?(direct_alias.jobs, &(&1.category == :source_correctness))

    nested_alias =
      Planner.plan(%{
        completion: %{"changeManifest" => %{"files" => ["docs/README.md"]}},
        settings: %Schema.QualityGate{}
      })

    assert nested_alias.changed_files == ["docs/README.md"]
    assert Enum.any?(nested_alias.jobs, &(&1.category == :docs_source_of_truth))

    configured_entrypoint =
      Planner.plan(%{
        completion: %{"changed_files" => ["DESIGN.md"]},
        policy: %{"manifest" => %{"docs" => %{"entrypoints" => ["DESIGN.md"]}}},
        settings: %Schema.QualityGate{}
      })

    assert Enum.any?(configured_entrypoint.jobs, &(&1.category == :docs_source_of_truth))

    product_doc =
      Planner.plan(%{
        completion: %{"changed_files" => ["PRODUCT.md"]},
        settings: %Schema.QualityGate{}
      })

    assert Enum.any?(product_doc.jobs, &(&1.category == :docs_source_of_truth))
  end

  test "planner treats package TypeScript source and tests as reviewable scope" do
    plan =
      Planner.plan(%{
        completion: %{
          changed_files: [
            "packages/web/src/features/workoutTracking/index.ts",
            "packages/web/src/features/workoutTracking/smartSetTargets.ts",
            "packages/web/tests/features/workoutTracking/smartSetTargets.test.ts"
          ]
        },
        settings: %Schema.QualityGate{}
      })

    assert plan.changed_files == [
             "packages/web/src/features/workoutTracking/index.ts",
             "packages/web/src/features/workoutTracking/smartSetTargets.ts",
             "packages/web/tests/features/workoutTracking/smartSetTargets.test.ts"
           ]

    assert Enum.any?(plan.jobs, &(&1.category == :source_correctness))
    assert Enum.any?(plan.jobs, &(&1.category == :test_quality))
  end

  test "planner uses manifest path classification rules before built-in language defaults" do
    settings = %Schema.QualityGate{
      path_classification: %{
        "sources" => ["engine/**/*.zig"],
        "tests" => ["spec/**/*_spec.zig", "**/*_test.go"]
      }
    }

    plan =
      Planner.plan(%{
        completion: %{
          changed_files: [
            "engine/runtime/main.zig",
            "spec/runtime/main_spec.zig",
            "root_test.go"
          ]
        },
        settings: settings
      })

    assert Enum.any?(plan.jobs, &(&1.category == :source_correctness))
    assert Enum.any?(plan.jobs, &(&1.category == :test_quality))

    single_pattern_plan =
      Planner.plan(%{
        completion: %{changed_files: ["native/runtime/foo.c"]},
        settings: %Schema.QualityGate{path_classification: %{source: "native/**/*.c"}}
      })

    assert Enum.any?(single_pattern_plan.jobs, &(&1.category == :source_correctness))

    default_settings_plan =
      Planner.plan(%{
        completion: %{changed_files: ["lib/fallback.ex"]}
      })

    assert Enum.any?(default_settings_plan.jobs, &(&1.category == :source_correctness))
  end

  test "quality gate repairs fix-required findings and reruns the affected review subset" do
    parent = self()
    issue = %Issue{identifier: "SID-319", title: "Quality gate fanout", labels: []}

    runner = fn
      %{kind: :review, job: %{category: :source_correctness}, phase: :initial} ->
        send(parent, {:reviewed, :source_correctness, :initial})
        {:ok, %{status: :passed, findings: []}}

      %{kind: :review, job: %{category: :test_quality}, phase: :initial} ->
        send(parent, {:reviewed, :test_quality, :initial})

        {:ok,
         %{
           status: :fix_required,
           findings: [
             %{
               severity: :major,
               category: :test_quality,
               evidence: "New branch is not covered by assertions.",
               affected_files: ["elixir/test/symphony_elixir/source_test.exs"],
               reproducibility_notes: "Run the focused test suite.",
               recommended_disposition: :fix_required
             }
           ]
         }}

      %{kind: :repair, attempt: 1} ->
        send(parent, {:repair, 1})
        %{status: :passed, summary: "Added the missing assertion."}

      %{kind: :review, job: %{category: :test_quality}, phase: {:repair, 1}} ->
        send(parent, {:reviewed, :test_quality, {:repair, 1}})
        {:ok, %{status: :passed, findings: []}}
    end

    result =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{
          changed_files: [
            "elixir/lib/symphony_elixir/source.ex",
            "elixir/test/symphony_elixir/source_test.exs"
          ]
        },
        runner: runner
      )

    assert result.status == :passed
    assert [%{attempt: 1, status: :passed, rerun_categories: [:test_quality]}] = result.repair_passes

    assert_receive {:reviewed, :source_correctness, :initial}
    assert_receive {:reviewed, :test_quality, :initial}
    assert_receive {:repair, 1}
    assert_receive {:reviewed, :test_quality, {:repair, 1}}
    refute_receive {:reviewed, :source_correctness, {:repair, 1}}, 50
  end

  test "quality gate replans repair completion scope before rerunning reviewers" do
    parent = self()
    issue = %Issue{identifier: "SID-319", title: "Quality gate fanout", labels: []}

    runner = fn
      %{kind: :review, job: %{category: :source_correctness}, phase: :initial} ->
        send(parent, {:reviewed, :source_correctness, :initial})

        {:ok,
         %{
           status: :fix_required,
           findings: [
             %{
               category: :source_correctness,
               evidence: "Repair changed a migration too.",
               recommended_disposition: :fix_required
             }
           ]
         }}

      %{kind: :review, job: %{category: category}, phase: :initial} ->
        send(parent, {:reviewed, category, :initial})
        {:ok, %{status: :passed, findings: []}}

      %{kind: :repair, attempt: 1} ->
        send(parent, {:repair, 1})

        %{
          status: :passed,
          summary: "Updated source and migration.",
          changed_files: ["lib/source.ex", "priv/repo/migrations/add_quality_gate.exs"]
        }

      %{kind: :review, job: %{category: category}, phase: {:repair, 1}} ->
        send(parent, {:reviewed, category, {:repair, 1}})
        {:ok, %{status: :passed, findings: []}}
    end

    result =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["lib/source.ex"]},
        runner: runner
      )

    assert result.status == :passed
    assert [%{rerun_categories: rerun_categories}] = result.repair_passes
    assert :source_correctness in rerun_categories
    assert :security_data_migration in rerun_categories

    assert_receive {:reviewed, :source_correctness, :initial}
    assert_receive {:repair, 1}
    assert_receive {:reviewed, :source_correctness, {:repair, 1}}
    assert_receive {:reviewed, :security_data_migration, {:repair, 1}}
  end

  test "quality gate handles nested and no-op repair completion scopes" do
    issue = %Issue{identifier: "SID-319", title: "Quality gate fanout", labels: []}

    nested_parent = self()

    nested =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["lib/source.ex"]},
        runner: fn
          %{kind: :review, job: %{category: :source_correctness}, phase: :initial} ->
            {:ok,
             %{
               status: :fix_required,
               findings: [
                 %{
                   category: :source_correctness,
                   evidence: "Repair reports nested completion scope.",
                   recommended_disposition: :fix_required
                 }
               ]
             }}

          %{kind: :repair, attempt: 1} ->
            %{
              status: :passed,
              completion: %{changed_files: ["priv/repo/migrations/add_quality_gate.exs"]}
            }

          %{kind: :review, job: %{category: category}, phase: {:repair, 1}} ->
            send(nested_parent, {:nested_rerun, category})
            {:ok, %{status: :passed, findings: []}}

          %{kind: :review} ->
            {:ok, %{status: :passed, findings: []}}
        end
      )

    assert nested.status == :passed
    assert_receive {:nested_rerun, :source_correctness}
    assert_receive {:nested_rerun, :security_data_migration}

    noop_parent = self()

    noop =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["test/source_test.exs"]},
        runner: fn
          %{kind: :review, job: %{category: :test_quality}, phase: :initial} ->
            {:ok,
             %{
               status: :fix_required,
               findings: [
                 %{
                   category: :test_quality,
                   evidence: "Repair reports an empty changed-file scope.",
                   recommended_disposition: :fix_required
                 }
               ]
             }}

          %{kind: :repair, attempt: 1} ->
            %{status: :passed, completion: %{changed_files: []}}

          %{kind: :review, job: %{category: category}, phase: {:repair, 1}} ->
            send(noop_parent, {:noop_rerun, category})
            {:ok, %{status: :passed, findings: []}}

          %{kind: :review} ->
            {:ok, %{status: :passed, findings: []}}
        end
      )

    assert noop.status == :passed
    assert_receive {:noop_rerun, :test_quality}
    refute_receive {:noop_rerun, :security_data_migration}, 50
  end

  test "codex execution profiles provide conservative typed defaults and command overrides" do
    settings = Config.settings!()

    assert %{
             name: "test_reviewer",
             model: "gpt-5.6-terra",
             reasoning_effort: "medium",
             budget: "standard",
             timeout_ms: 1_200_000,
             max_retries: 0
           } = ExecutionProfile.resolve(settings, "test_reviewer")

    assert %{reasoning_effort: "medium"} = ExecutionProfile.resolve(settings, "source_reviewer")

    command =
      ExecutionProfile.command(
        ["codex", "--config", "model_reasoning_effort=xhigh", "app-server"],
        ExecutionProfile.resolve(settings, "test_reviewer")
      )

    assert command == [
             "codex",
             "--config",
             "model_reasoning_effort=xhigh",
             "--config",
             "model=\"gpt-5.6-terra\"",
             "--config",
             "model_reasoning_effort=medium",
             "app-server"
           ]

    assert {:ok, overridden_settings} =
             Schema.parse(%{
               "profiles" => %{"default" => %{"delivery" => %{"pr_target" => "main"}}},
               "runners" => %{
                 "codex" => %{
                   "kind" => "codex_app_server",
                   "command" => ["codex", "app-server"],
                   "execution_profiles" => %{
                     "source_reviewer" => %{
                       "reasoning_effort" => "low",
                       "budget" => "cheap",
                       "timeout_ms" => 60_000,
                       "max_retries" => 1
                     },
                     "runtime_qa" => %{"reasoning_effort" => "none"},
                     "security_reviewer" => %{"reasoning_effort" => "max"}
                   }
                 }
               }
             })

    assert %{
             name: "source_reviewer",
             reasoning_effort: "low",
             budget: "cheap",
             timeout_ms: 60_000,
             max_retries: 1
           } = ExecutionProfile.resolve(overridden_settings, "source_reviewer")

    assert %{reasoning_effort: "none"} = ExecutionProfile.resolve(overridden_settings, "runtime_qa")
    assert %{reasoning_effort: "max"} = ExecutionProfile.resolve(overridden_settings, "security_reviewer")
  end

  test "handoff routing consumes quality gate evidence" do
    workspace = Path.join(System.tmp_dir!(), "symphony-quality-gate-route-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(workspace) end)

    fix_required =
      HandoffRouteRecorder.classify_completion(
        %{
          quality_gate: %{
            status: :fix_required,
            planner: %{jobs: [%{category: :test_quality}]},
            jobs: [%{category: :test_quality, status: :fix_required}],
            synthesis: %{
              status: :fix_required,
              findings: [%{category: :test_quality, recommended_disposition: :fix_required}]
            }
          }
        },
        nil,
        workspace
      )

    assert fix_required.route == :rework
    assert Enum.any?(fix_required.evidence, &(&1.kind == :check and &1.status == :fix_required and &1.summary =~ "Quality gate"))

    blocked =
      HandoffRouteRecorder.classify_completion(
        %{
          quality_gate: %{
            status: :blocked,
            unresolved_human_review_reasons: ["runtime QA requires unavailable browser credentials"]
          }
        },
        nil,
        workspace
      )

    assert blocked.route == :blocked
    assert blocked.recommendation =~ "browser credentials"
  end

  test "orchestrator runs host quality gate before handoff routing" do
    parent = self()
    previous_runner = Application.get_env(:symphony_elixir, :quality_gate_runner)
    write_workflow_file!(Workflow.workflow_file_path(), quality_gate_enabled: true)

    on_exit(fn ->
      case previous_runner do
        nil -> Application.delete_env(:symphony_elixir, :quality_gate_runner)
        runner -> Application.put_env(:symphony_elixir, :quality_gate_runner, runner)
      end
    end)

    Application.put_env(:symphony_elixir, :quality_gate_runner, fn
      %{kind: :review, job: %{category: category}} ->
        send(parent, {:quality_gate_review, category})
        {:ok, %{status: :passed, findings: []}}
    end)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-quality-gate-orchestrator-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/source.ex"), "defmodule Source do\nend\n")
    on_exit(fn -> File.rm_rf(workspace) end)

    issue_id = "issue-quality-gate"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :QualityGateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "SID-319",
      issue: %Issue{id: issue_id, identifier: "SID-319", title: "Quality gate", state: "In Progress"},
      session_id: nil,
      workspace_path: workspace,
      policy: %{},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    send(
      pid,
      {:runtime_event, issue_id,
       %{
         event: :turn_completed,
         timestamp: DateTime.utc_now(),
         completion: %{
           checks: [%{name: "mix test", status: :passed}],
           change_manifest: %{changed_files: ["lib/source.ex"], validation: [%{name: "mix test", status: "passed"}]}
         }
       }}
    )

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert_receive {:quality_gate_review, :source_correctness}
    assert_receive {:quality_gate_review, :test_quality}

    assert Enum.any?(state.handoff_routes[issue_id].evidence, fn evidence ->
             evidence.kind == "check" and evidence.status == "passed" and evidence.summary =~ "quality_gate"
           end)
  end

  test "orchestrator writes a quality gate review record after handoff routing" do
    parent = self()
    previous_runner = Application.get_env(:symphony_elixir, :quality_gate_runner)
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    logs_root = Path.join(System.tmp_dir!(), "symphony-quality-gate-records-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(), quality_gate_enabled: true)
    Application.put_env(:symphony_elixir, :log_file, SymphonyElixir.LogFile.default_log_file(logs_root))

    on_exit(fn ->
      case previous_runner do
        nil -> Application.delete_env(:symphony_elixir, :quality_gate_runner)
        runner -> Application.put_env(:symphony_elixir, :quality_gate_runner, runner)
      end

      case previous_log_file do
        nil -> Application.delete_env(:symphony_elixir, :log_file)
        log_file -> Application.put_env(:symphony_elixir, :log_file, log_file)
      end

      File.rm_rf(logs_root)
    end)

    Application.put_env(:symphony_elixir, :quality_gate_runner, fn
      %{kind: :review, job: %{category: category}} ->
        send(parent, {:quality_gate_review, category})
        {:ok, %{status: :passed, findings: []}}
    end)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-quality-gate-record-orchestrator-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/source.ex"), "defmodule Source do\nend\n")
    on_exit(fn -> File.rm_rf(workspace) end)

    issue_id = "issue-quality-gate-record"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :QualityGateRecordOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "SID-320",
      issue: %Issue{
        id: issue_id,
        identifier: "SID-320",
        title: "Persist quality-gate records",
        state: "In Progress",
        url: "https://linear.app/example/issue/SID-320/example"
      },
      session_id: "session-320",
      workspace_path: workspace,
      policy: %{
        "policy_metadata" => %{"profile" => "default", "project_slug" => "symphony"},
        "policy_ref" => "640c639998cf",
        "delivery" => %{"pr_target" => "main"},
        "project" => %{"slug" => "symphony", "repository" => "https://github.com/apontarelli/symphony"}
      },
      started_at: DateTime.from_naive!(~N[2026-06-11 16:00:00], "Etc/UTC")
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    send(
      pid,
      {:runtime_event, issue_id,
       %{
         event: :turn_completed,
         timestamp: DateTime.from_naive!(~N[2026-06-11 16:05:00], "Etc/UTC"),
         session_id: "session-320",
         completion: %{
           checks: [%{name: "mix test", status: :passed}],
           change_manifest: %{changed_files: ["lib/source.ex"], validation: [%{name: "mix test", status: "passed"}]}
         }
       }}
    )

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)

    assert_receive {:quality_gate_review, :source_correctness}
    assert_receive {:quality_gate_review, :test_quality}
    :sys.get_state(pid)

    assert {:ok, record} =
             eventually(fn ->
               case SymphonyElixir.ReviewRecords.show(logs_root, "session-320") do
                 {:ok, record} -> {:ok, record}
                 {:error, :not_found} -> nil
               end
             end)

    assert record.metadata["issue"]["identifier"] == "SID-320"
    assert record.metadata["workflow"]["policy_ref"] == "640c639998cf"
    assert record.quality_gate["status"] == "passed"
    assert record.handoff_route["route"]["target_state"] == "Human Review"
  end

  test "orchestrator host quality gate overrides worker gate and blocks publish side effects" do
    parent = self()
    previous_quality_runner = Application.get_env(:symphony_elixir, :quality_gate_runner)
    previous_preflight_runner = Application.get_env(:symphony_elixir, :publish_preflight_runner)
    previous_publish_runner = Application.get_env(:symphony_elixir, :publish_handoff_runner)

    write_workflow_file!(Workflow.workflow_file_path(), quality_gate_enabled: true, quality_gate_max_repair_passes: 0)

    on_exit(fn ->
      case previous_quality_runner do
        nil -> Application.delete_env(:symphony_elixir, :quality_gate_runner)
        runner -> Application.put_env(:symphony_elixir, :quality_gate_runner, runner)
      end

      case previous_preflight_runner do
        nil -> Application.delete_env(:symphony_elixir, :publish_preflight_runner)
        runner -> Application.put_env(:symphony_elixir, :publish_preflight_runner, runner)
      end

      case previous_publish_runner do
        nil -> Application.delete_env(:symphony_elixir, :publish_handoff_runner)
        runner -> Application.put_env(:symphony_elixir, :publish_handoff_runner, runner)
      end
    end)

    Application.put_env(:symphony_elixir, :quality_gate_runner, fn
      %{kind: :review, job: %{category: :source_correctness}} ->
        send(parent, {:quality_gate_review, :source_correctness})

        {:ok,
         %{
           status: :fix_required,
           findings: [
             %{
               category: :source_correctness,
               evidence: "Host review found a blocker.",
               recommended_disposition: :fix_required
             }
           ]
         }}

      %{kind: :review, job: %{category: category}} ->
        send(parent, {:quality_gate_review, category})
        {:ok, %{status: :passed, findings: []}}
    end)

    Application.put_env(:symphony_elixir, :publish_preflight_runner, fn %{step: step} ->
      send(parent, {:publish_preflight_called, step})
      {:ok, %{status: 0, output: "ok"}}
    end)

    Application.put_env(:symphony_elixir, :publish_handoff_runner, fn %{step: step, command: command, args: args} ->
      send(parent, {:publish_handoff_command, step, command, args})
      {:ok, %{status: 0, output: "ok"}}
    end)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-quality-gate-publish-block-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/source.ex"), "defmodule Source do\nend\n")
    on_exit(fn -> File.rm_rf(workspace) end)

    issue_id = "issue-quality-gate-publish-block"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :QualityGatePublishBlockOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "SID-319",
      issue: %Issue{id: issue_id, identifier: "SID-319", title: "Quality gate publish", state: "In Progress"},
      session_id: nil,
      workspace_path: workspace,
      worker_host: nil,
      policy: %{
        "publish_target" => %{
          "repository" => "https://github.com/example/project",
          "pr_target" => "main",
          "github_repository" => "example/project",
          "display" => "example/project:main"
        },
        "manifest" => %{"project" => %{"repository" => "https://github.com/example/project"}},
        "delivery" => %{"pr_target" => "main"}
      },
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    send(
      pid,
      {:runtime_event, issue_id,
       %{
         event: :turn_completed,
         timestamp: DateTime.utc_now(),
         completion: %{
           quality_gate: %{status: :passed},
           checks: [%{name: "tests", status: :passed}],
           change_manifest: %{changed_files: ["lib/source.ex"], validation: [%{name: "tests", status: "passed"}]}
         }
       }}
    )

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert_receive {:quality_gate_review, :source_correctness}
    assert_receive {:quality_gate_review, :test_quality}
    refute_receive {:publish_preflight_called, _step}, 50
    refute_receive {:publish_handoff_command, _step, _command, _args}, 50

    assert %{route: route, target_state: "Rework"} = state.handoff_routes[issue_id]
    assert route in ["rework", :rework]
  end

  test "planner handles nested manifests and conservative runtime isolation modes" do
    settings = %Schema.QualityGate{source_max_concurrency: 1, runtime_isolation: "blocked"}

    plan =
      Planner.plan(%{
        completion: %{
          "change_manifest" => %{"changed_files" => [" README.md ", "", 12]},
          "changed_surfaces" => ["cli", "unknown-surface"]
        },
        issue: %{labels: "not-list"},
        settings: settings
      })

    assert Enum.find(plan.jobs, &(&1.category == :docs_source_of_truth))
    assert scenario = Enum.find(plan.jobs, &(&1.category == :scenario_qa))
    assert scenario.execution_mode == :blocked_runtime
    refute Enum.any?(plan.changed_surfaces, &(&1 == :unknown_surface))

    isolated =
      Planner.plan(%{
        completion: %{changed_files: ["lib/symphony_elixir_web/live/dashboard_live.ex"]},
        settings: %Schema.QualityGate{runtime_isolation: "isolated_workspace"}
      })

    assert Enum.any?(isolated.jobs, &(&1.execution_mode == :isolated_runtime))
  end

  test "planner covers fallback scope parsing" do
    empty = Planner.plan(%{completion: "bad", settings: nil})
    assert empty.changed_files == []
    assert empty.changed_surfaces == []
    assert empty.jobs == []
    assert empty.metadata.source_max_concurrency == 3

    malformed_manifest =
      Planner.plan(%{
        completion: %{"change_manifest" => "bad", "changed_surfaces" => [123]},
        settings: %Schema.QualityGate{}
      })

    assert malformed_manifest.changed_files == []
    assert malformed_manifest.changed_surfaces == []

    non_list_files =
      Planner.plan(%{
        completion: %{changed_files: "lib/source.ex"},
        settings: %Schema.QualityGate{}
      })

    assert non_list_files.changed_files == []

    docs =
      Planner.plan(%{
        completion: %{"changed_files" => ["docs/README.md"]},
        settings: %Schema.QualityGate{}
      })

    assert Enum.any?(docs.jobs, &(&1.category == :docs_source_of_truth))

    malformed_doc_entrypoints =
      Planner.plan(%{
        completion: %{"changed_files" => ["DESIGN.md"]},
        policy: %{"manifest" => %{"docs" => %{"entrypoints" => "DESIGN.md"}}},
        settings: %Schema.QualityGate{}
      })

    refute Enum.any?(malformed_doc_entrypoints.jobs, &(&1.category == :docs_source_of_truth))

    scenario =
      Planner.plan(%{
        completion: %{"changed_surfaces" => ["cli"]},
        settings: %Schema.QualityGate{}
      })

    assert Enum.any?(scenario.jobs, &(&1.prompt =~ "- None supplied."))
  end

  test "synthesis normalizes malformed findings without atomizing unknown tokens" do
    result =
      Synthesis.synthesize([
        %{
          id: "docs",
          category: :docs_source_of_truth,
          status: :passed,
          findings: [
            %{
              "severity" => "surprising",
              "category" => "unknown-category",
              "summary" => "Docs need a decision",
              "files" => [" docs/README.md ", ""],
              "reproducibility" => "Read the docs.",
              "disposition" => "unknown-disposition"
            },
            "not a finding"
          ]
        },
        %{id: "duplicate", category: :docs_source_of_truth, status: :fix_required, findings: []}
      ])

    assert result.status == :human_input_required
    assert [%{category: :docs_source_of_truth, recommended_disposition: :human_input_required} | _] = result.findings

    assert Synthesis.affected_categories(
             %{findings: [%{category: "not-atom", recommended_disposition: :fix_required}]},
             []
           ) == []

    blocked = Synthesis.synthesize([%{status: :blocked, category: :runtime_qa}])
    assert blocked.status == :blocked
    assert blocked.unresolved_human_review_reasons == ["runtime_qa blocked"]
  end

  test "synthesis covers synthetic findings and fallback values" do
    fix_required = Synthesis.synthesize([%{id: "source", category: :source_correctness, status: :fix_required}])
    assert fix_required.status == :fix_required
    assert [%{recommended_disposition: :fix_required}] = fix_required.findings

    blocked = Synthesis.synthesize([%{status: :blocked, blocked_reason: "Browser unavailable"}])
    assert blocked.unresolved_human_review_reasons == ["Browser unavailable"]

    malformed =
      Synthesis.synthesize([
        %{
          id: "malformed",
          category: :source_correctness,
          status: :passed,
          findings: [
            %{
              "severity" => 123,
              "category" => :source_correctness,
              "recommended_disposition" => 456
            }
          ]
        }
      ])

    assert malformed.status == :human_input_required
    assert [%{evidence: "Reviewer reported an actionable finding.", severity: :major}] = malformed.findings

    assert Synthesis.affected_categories(
             %{findings: []},
             [%{status: :fix_required, category: "source_correctness"}]
           ) == []
  end

  test "quality gate public helpers normalize alternate result states" do
    assert %{status: :passed} = QualityGate.run(nil, %{}, nil, "not metadata")
    assert QualityGate.normalize_result("bad") == nil
    assert QualityGate.check(nil) == nil
    assert QualityGate.review(nil, %{status: :clean}) == %{status: :clean}
    assert QualityGate.blocker(%{status: :passed}) == nil

    passed = QualityGate.normalize_result(%{"status" => "passed", "synthesis" => %{"summary" => "Clean"}})
    existing_review = %{status: :clean, summary: "existing"}
    assert QualityGate.review(passed, existing_review) == existing_review
    assert QualityGate.check(passed).name == "quality_gates"
    assert QualityGate.normalize_result(%{"status" => "surprise"}).status == :blocked

    human_input =
      QualityGate.normalize_result(%{
        "status" => "human_input_required",
        "synthesis" => %{"unresolved_human_review_reasons" => ["Need approval"]}
      })

    assert QualityGate.check(human_input).status == :blocked
    assert QualityGate.review(human_input, %{}).status == :decision_needed
    assert QualityGate.blocker(human_input).required_action =~ "Need approval"

    blocked = QualityGate.normalize_result(%{"status" => "blocked"})
    assert QualityGate.blocker(blocked).reason == "Quality gate blocked."

    assert QualityGate.check(%{status: :unknown}).summary == "Quality gate status: unknown."
    assert QualityGate.review(%{status: :passed}, nil).status == :clean

    assert QualityGate.review(%{status: :fix_required, findings: ["plain finding"]}, %{}) == %{
             status: :fix_required,
             summary: "Quality gate requires fixes.",
             findings: ["plain finding"]
           }

    assert QualityGate.review(%{status: :fix_required, findings: [%{evidence: " concrete finding "}]}, %{}).findings == [
             "concrete finding"
           ]

    assert QualityGate.review(%{status: :fix_required}, %{}).findings == []
    assert QualityGate.review(%{status: :fix_required, synthesis: "bad"}, %{}).findings == []
    assert QualityGate.review(%{status: :blocked}, %{status: :existing}) == %{status: :existing}
  end

  test "quality gate covers blocked runtime and malformed review runner outputs" do
    issue = %Issue{identifier: "SID-319", title: "Quality gate"}

    blocked_runtime =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_surfaces: ["cli"]},
        settings: %Schema.QualityGate{runtime_isolation: "blocked"}
      )

    assert blocked_runtime.status == :blocked
    assert Enum.any?(blocked_runtime.jobs, &(&1.blocked_reason =~ "runtime_review_blocked_by_policy"))

    isolated_runtime =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_surfaces: ["cli"]},
        settings: %Schema.QualityGate{runtime_isolation: "isolated_workspace"}
      )

    assert isolated_runtime.status == :blocked
    assert Enum.any?(isolated_runtime.jobs, &(&1.blocked_reason =~ "isolated_runtime_requires_workspace_isolation"))

    parent = self()

    read_only =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{"runners" => %{"codex" => %{"turn_sandbox_policy" => %{"type" => "workspaceWrite"}}}},
        issue,
        %{changed_files: ["lib/source.ex"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        runner: fn %{kind: :review, policy: policy} ->
          send(parent, {:review_policy, policy})
          {:ok, %{status: :passed, findings: []}}
        end
      )

    assert read_only.status == :passed
    assert_receive {:review_policy, policy}
    assert get_in(policy, ["runners", "codex", "turn_sandbox_policy", "type"]) == "readOnly"

    QualityGate.run(
      "/tmp/symphony-workspace",
      "not a policy",
      issue,
      %{changed_files: ["lib/source.ex"]},
      settings: %Schema.QualityGate{max_repair_passes: 0},
      runner: fn %{kind: :review, policy: policy} ->
        send(parent, {:review_policy_from_non_map, policy})
        {:ok, %{status: :passed, findings: []}}
      end
    )

    assert_receive {:review_policy_from_non_map, non_map_policy}
    assert get_in(non_map_policy, ["runners", "codex", "turn_sandbox_policy", "type"]) == "readOnly"

    QualityGate.run(
      "/tmp/symphony-workspace",
      %{"runners" => %{"codex" => "not a map"}},
      issue,
      %{changed_files: ["lib/source.ex"]},
      settings: %Schema.QualityGate{max_repair_passes: 0},
      runner: fn %{kind: :review, policy: policy} ->
        send(parent, {:review_policy_from_malformed_runner, policy})
        {:ok, %{status: :passed, findings: []}}
      end
    )

    assert_receive {:review_policy_from_malformed_runner, malformed_codex_policy}
    assert get_in(malformed_codex_policy, ["runners", "codex", "turn_sandbox_policy", "type"]) == "readOnly"

    browser_policy =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_surfaces: ["cli", "web_ui"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        browser_preflight: fn context ->
          send(parent, {:browser_preflight, context})
          :ok
        end,
        runner: fn %{kind: :review, job: %{category: category}, policy: policy} ->
          send(parent, {:browser_review_policy, category, policy})
          {:ok, %{status: :passed, findings: []}}
        end
      )

    assert browser_policy.status == :passed

    assert_receive {:browser_preflight, %{category: :scenario_qa, workspace: "/tmp/symphony-workspace"}}
    assert_receive {:browser_preflight, %{category: :product_visual_review, workspace: "/tmp/symphony-workspace"}}

    assert_receive {:browser_review_policy, :scenario_qa, scenario_policy}
    assert get_in(scenario_policy, ["runners", "codex", "turn_sandbox_policy", "type"]) == "workspaceWrite"
    assert get_in(scenario_policy, ["runners", "codex", "turn_sandbox_policy", "networkAccess"]) == true
    assert get_in(scenario_policy, ["runners", "codex", "turn_sandbox_policy", "writableRoots"]) == ["/tmp/symphony-workspace"]

    assert_receive {:browser_review_policy, :product_visual_review, visual_policy}
    assert get_in(visual_policy, ["runners", "codex", "turn_sandbox_policy", "type"]) == "workspaceWrite"
    assert get_in(visual_policy, ["runners", "codex", "turn_sandbox_policy", "networkAccess"]) == true

    preflight_blocked =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_surfaces: ["web_ui"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        worker_host: "worker-a",
        browser_preflight: fn context ->
          send(parent, {:blocked_browser_preflight, context})
          {:error, :chrome_missing}
        end,
        runner: fn %{kind: :review} ->
          flunk("browser reviewer should not run when preflight fails")
        end
      )

    assert preflight_blocked.status == :blocked
    assert_receive {:blocked_browser_preflight, %{category: :product_visual_review, workspace: "/tmp/symphony-workspace", worker_host: "worker-a"}}

    assert Enum.any?(preflight_blocked.jobs, fn job ->
             job.category == :product_visual_review and job.blocked_reason =~ "browser_preflight_failed" and
               job.blocked_reason =~ "chrome_missing"
           end)

    runner = fn
      %{kind: :review, job: %{category: :source_correctness}} ->
        {:error, :review_failed}

      %{kind: :review, job: %{category: :test_quality}} ->
        %{status: 123, summary: " ", findings: "bad"}
    end

    malformed =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["lib/source.ex", "test/source_test.exs"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        runner: runner
      )

    assert malformed.status == :blocked
    assert Enum.any?(malformed.jobs, &(&1.blocked_reason =~ "review_failed"))
    assert Enum.any?(malformed.jobs, &(&1.summary == nil and &1.findings == []))

    invalid =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["lib/source.ex"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        runner: fn %{kind: :review} -> :bad end
      )

    assert invalid.status == :blocked
    assert Enum.any?(invalid.jobs, &(&1.blocked_reason =~ "invalid_reviewer_output"))
  end

  test "browser review policies preserve explicit browser-capable sandbox shapes" do
    {workspace_result, workspace_policy} =
      capture_visual_review_policy(%{
        "runners" => %{
          "codex" => %{
            "turn_sandbox_policy" => %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/custom"], "networkAccess" => false}
          }
        }
      })

    assert workspace_result.status == :passed
    assert get_in(workspace_policy, ["runners", "codex", "turn_sandbox_policy", "type"]) == "workspaceWrite"
    assert get_in(workspace_policy, ["runners", "codex", "turn_sandbox_policy", "networkAccess"]) == true
    assert get_in(workspace_policy, ["runners", "codex", "turn_sandbox_policy", "writableRoots"]) == ["/tmp/custom"]

    {_atom_workspace_result, atom_workspace_policy} =
      capture_visual_review_policy(%{
        runners: %{
          codex: %{
            turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["/tmp/atom"], networkAccess: false}
          }
        }
      })

    assert get_in(atom_workspace_policy, ["runners", "codex", "turn_sandbox_policy", "type"]) == "workspaceWrite"
    assert get_in(atom_workspace_policy, ["runners", "codex", "turn_sandbox_policy", "networkAccess"]) == true
    assert get_in(atom_workspace_policy, ["runners", "codex", "turn_sandbox_policy", "writableRoots"]) == ["/tmp/atom"]

    {_danger_result, danger_policy} =
      capture_visual_review_policy(%{
        "runners" => %{
          "codex" => %{"turn_sandbox_policy" => %{"type" => "dangerFullAccess", "reason" => "operator override"}}
        }
      })

    assert get_in(danger_policy, ["runners", "codex", "turn_sandbox_policy"]) == %{
             "type" => "dangerFullAccess",
             "reason" => "operator override"
           }

    {_atom_danger_result, atom_danger_policy} =
      capture_visual_review_policy(%{
        runners: %{
          codex: %{turn_sandbox_policy: %{type: "dangerFullAccess", reason: "operator override"}}
        }
      })

    assert get_in(atom_danger_policy, ["runners", "codex", "turn_sandbox_policy"]) == %{
             "type" => "dangerFullAccess",
             "reason" => "operator override"
           }

    {_fallback_result, fallback_policy} = capture_visual_review_policy("not a policy")
    assert get_in(fallback_policy, ["runners", "codex", "turn_sandbox_policy", "type"]) == "workspaceWrite"
    assert get_in(fallback_policy, ["runners", "codex", "turn_sandbox_policy", "networkAccess"]) == true
    assert fallback_policy["codex"] == nil

    {_legacy_bad_result, legacy_bad_policy} = capture_visual_review_policy(%{"codex" => "bad"})
    assert get_in(legacy_bad_policy, ["runners", "codex", "turn_sandbox_policy", "type"]) == "workspaceWrite"
    assert legacy_bad_policy["codex"] == nil
  end

  test "product visual review consumes host visual QA artifacts without browser reviewer sandbox access" do
    parent = self()

    result =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        %Issue{identifier: "SID-319", title: "Quality gate"},
        %{changed_files: ["lib/example_web/live/dashboard_live.ex"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        host_visual_qa: fn context ->
          send(parent, {:host_visual_qa, context})

          {:ok,
           %{
             "status" => "passed",
             "summary" => "Desktop and mobile captures passed.",
             "checks" => [%{"name" => "viewport_screenshots", "status" => "passed"}],
             "artifacts" => [%{"kind" => "screenshot", "label" => "Desktop", "summary" => "Desktop capture"}]
           }}
        end,
        browser_preflight: fn context ->
          send(parent, {:browser_preflight, context})
          :ok
        end,
        runner: fn
          %{kind: :review, job: %{category: :product_visual_review} = job, policy: policy} ->
            send(parent, {:visual_reviewer, policy, job})
            {:ok, %{status: :passed, findings: []}}

          %{kind: :review, job: %{category: :source_correctness}} ->
            {:ok, %{status: :passed, findings: []}}

          %{kind: :review, job: %{category: :scenario_qa}} ->
            {:ok, %{status: :passed, findings: []}}
        end
      )

    assert result.status == :passed
    assert_receive {:host_visual_qa, %{job: %{category: :product_visual_review}, workspace: "/tmp/symphony-workspace"}}
    refute_receive {:browser_preflight, %{category: :product_visual_review}}, 50

    assert_receive {:visual_reviewer, policy, job}
    assert get_in(policy, ["runners", "codex", "turn_sandbox_policy", "type"]) == "readOnly"
    assert job.prompt =~ "Host visual QA artifacts"
    assert job.prompt =~ "Desktop and mobile captures passed"

    assert %{host_visual_qa: %{"summary" => "Desktop and mobile captures passed."}} =
             Enum.find(result.jobs, &(&1.category == :product_visual_review))
  end

  test "product visual review blocks before reviewer when host visual QA fails" do
    parent = self()

    result =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        %Issue{identifier: "SID-319", title: "Quality gate"},
        %{changed_files: ["lib/example_web/live/dashboard_live.ex"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        host_visual_qa: fn context ->
          send(parent, {:host_visual_qa, context})
          {:error, :browser_launch_failed}
        end,
        browser_preflight: fn context ->
          send(parent, {:browser_preflight, context})
          :ok
        end,
        runner: fn
          %{kind: :review, job: %{category: :product_visual_review}} ->
            flunk("product visual reviewer should not run when host visual QA fails")

          %{kind: :review, job: %{category: :source_correctness}} ->
            {:ok, %{status: :passed, findings: []}}

          %{kind: :review, job: %{category: :scenario_qa}} ->
            {:ok, %{status: :passed, findings: []}}
        end
      )

    assert result.status == :blocked
    assert_receive {:host_visual_qa, %{job: %{category: :product_visual_review}}}
    refute_receive {:browser_preflight, %{category: :product_visual_review}}, 50

    assert Enum.any?(result.jobs, fn job ->
             job.category == :product_visual_review and job.blocked_reason =~ "host_visual_qa_failed" and
               job.blocked_reason =~ "browser_launch_failed"
           end)
  end

  test "review and repair runner contexts preserve worker host" do
    parent = self()

    result =
      QualityGate.run(
        "/remote/workspaces/SID-319",
        %{},
        %Issue{identifier: "SID-319", title: "Quality gate"},
        %{changed_files: ["lib/source.ex"]},
        worker_host: "worker-a",
        settings: %Schema.QualityGate{max_repair_passes: 1},
        runner: fn
          %{kind: :review, phase: :initial, worker_host: worker_host} ->
            send(parent, {:review_worker_host, :initial, worker_host})

            {:ok,
             %{
               status: :fix_required,
               findings: [
                 %{
                   category: :source_correctness,
                   evidence: "Needs repair",
                   recommended_disposition: :fix_required
                 }
               ]
             }}

          %{kind: :repair, attempt: 1, worker_host: worker_host} ->
            send(parent, {:repair_worker_host, worker_host})
            {:ok, %{status: :passed}}

          %{kind: :review, phase: {:repair, 1}, worker_host: worker_host} ->
            send(parent, {:review_worker_host, {:repair, 1}, worker_host})
            {:ok, %{status: :passed, findings: []}}
        end
      )

    assert result.status == :passed
    assert_receive {:review_worker_host, :initial, "worker-a"}
    assert_receive {:repair_worker_host, "worker-a"}
    assert_receive {:review_worker_host, {:repair, 1}, "worker-a"}
  end

  test "product visual review handles malformed host visual QA callbacks" do
    invalid_callback =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        %Issue{identifier: "SID-319", title: "Quality gate"},
        %{changed_files: ["lib/example_web/live/dashboard_live.ex"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        host_visual_qa: :not_a_function,
        runner: fn %{kind: :review, job: %{category: :product_visual_review}} ->
          flunk("product visual reviewer should not run when host visual QA callback is invalid")
        end
      )

    assert invalid_callback.status == :blocked
    assert Enum.any?(invalid_callback.jobs, &(&1.blocked_reason =~ "invalid_host_visual_qa"))

    invalid_result =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        %Issue{identifier: "SID-319", title: "Quality gate"},
        %{changed_files: ["lib/example_web/live/dashboard_live.ex"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        host_visual_qa: fn _context -> :surprise end,
        runner: fn %{kind: :review, job: %{category: :product_visual_review}} ->
          flunk("product visual reviewer should not run when host visual QA result is invalid")
        end
      )

    assert invalid_result.status == :blocked
    assert Enum.any?(invalid_result.jobs, &(&1.blocked_reason =~ "invalid_result"))

    raised =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        %Issue{identifier: "SID-319", title: "Quality gate"},
        %{changed_files: ["lib/example_web/live/dashboard_live.ex"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        host_visual_qa: fn _context -> raise "visual qa exploded" end,
        runner: fn %{kind: :review, job: %{category: :product_visual_review}} ->
          flunk("product visual reviewer should not run when host visual QA raises")
        end
      )

    assert raised.status == :blocked
    assert Enum.any?(raised.jobs, &(&1.blocked_reason =~ "visual qa exploded"))

    thrown =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        %Issue{identifier: "SID-319", title: "Quality gate"},
        %{changed_files: ["lib/example_web/live/dashboard_live.ex"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        host_visual_qa: fn _context -> throw(:visual_qa_thrown) end,
        runner: fn %{kind: :review, job: %{category: :product_visual_review}} ->
          flunk("product visual reviewer should not run when host visual QA throws")
        end
      )

    assert thrown.status == :blocked
    assert Enum.any?(thrown.jobs, &(&1.blocked_reason =~ "visual_qa_thrown"))
  end

  test "product visual review prompt falls back to inspected host visual QA payload" do
    parent = self()

    result =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        %Issue{identifier: "SID-319", title: "Quality gate"},
        %{changed_files: ["lib/example_web/live/dashboard_live.ex"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        host_visual_qa: fn _context ->
          {:ok, %{"summary" => "Function payload captured.", "raw" => fn -> :not_json end}}
        end,
        runner: fn
          %{kind: :review, job: %{category: :product_visual_review} = job} ->
            send(parent, {:inspected_visual_prompt, job.prompt})
            {:ok, %{status: :passed, findings: []}}

          %{kind: :review, job: %{category: :source_correctness}} ->
            {:ok, %{status: :passed, findings: []}}

          %{kind: :review, job: %{category: :scenario_qa}} ->
            {:ok, %{status: :passed, findings: []}}
        end
      )

    assert result.status == :passed
    assert_receive {:inspected_visual_prompt, prompt}
    assert prompt =~ "Function payload captured"
    assert prompt =~ "#Function"
  end

  test "browser preflight blocks malformed callbacks and invalid results" do
    invalid_callback =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        %Issue{identifier: "SID-319", title: "Quality gate"},
        %{changed_surfaces: ["web_ui"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        browser_preflight: :not_a_function,
        runner: fn %{kind: :review} -> flunk("browser reviewer should not run") end
      )

    assert invalid_callback.status == :blocked
    assert Enum.any?(invalid_callback.jobs, &(&1.blocked_reason =~ "invalid_browser_preflight"))

    invalid_result =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        %Issue{identifier: "SID-319", title: "Quality gate"},
        %{changed_surfaces: ["web_ui"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        browser_preflight: fn _context -> :surprise end,
        runner: fn %{kind: :review} -> flunk("browser reviewer should not run") end
      )

    assert invalid_result.status == :blocked
    assert Enum.any?(invalid_result.jobs, &(&1.blocked_reason =~ "invalid_result"))
  end

  test "default browser preflight checks local and remote Chrome availability" do
    test_root = Path.join(System.tmp_dir!(), "symphony-quality-gate-browser-preflight-#{System.unique_integer([:positive])}")
    fake_chrome = Path.join(test_root, "Chrome")
    fake_bin = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin, "ssh")

    previous_browser_path = System.get_env("BROWSER_QA_CHROME_PATH")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("BROWSER_QA_CHROME_PATH", previous_browser_path)
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(fake_bin)
    File.write!(fake_chrome, "#!/bin/sh\nexit 0\n")
    File.chmod!(fake_chrome, 0o755)
    System.put_env("BROWSER_QA_CHROME_PATH", fake_chrome)

    assert run_default_visual_preflight().status == :passed

    System.put_env("BROWSER_QA_CHROME_PATH", Path.join(test_root, "missing-chrome"))

    local_blocked = run_default_visual_preflight()
    assert local_blocked.status == :blocked
    assert Enum.any?(local_blocked.jobs, &(&1.blocked_reason =~ "chrome_unavailable"))

    System.delete_env("BROWSER_QA_CHROME_PATH")
    System.delete_env("SYMPHONY_SSH_CONFIG")
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))

    File.write!(fake_ssh, "#!/bin/sh\nprintf 'remote ok\\n'\nexit 0\n")
    File.chmod!(fake_ssh, 0o755)
    assert run_default_visual_preflight(worker_host: "worker-a").status == :passed

    File.write!(fake_ssh, "#!/bin/sh\nprintf 'remote missing\\n'\nexit 7\n")
    File.chmod!(fake_ssh, 0o755)
    remote_blocked = run_default_visual_preflight(worker_host: "worker-a")
    assert remote_blocked.status == :blocked

    assert Enum.any?(remote_blocked.jobs, fn job ->
             job.blocked_reason =~ "chrome_unavailable_on_worker" and job.blocked_reason =~ "remote missing"
           end)

    System.put_env("PATH", "")
    ssh_missing = run_default_visual_preflight(worker_host: "worker-a")
    assert ssh_missing.status == :blocked
    assert Enum.any?(ssh_missing.jobs, &(&1.blocked_reason =~ "worker_browser_preflight_unavailable"))
  end

  test "quality gate covers review exits and exceptions" do
    issue = %Issue{identifier: "SID-319", title: "Quality gate"}
    settings = %Schema.QualityGate{max_repair_passes: 0}
    parent = self()

    previous_trap_exit = Process.flag(:trap_exit, true)

    killed =
      try do
        QualityGate.run(
          "/tmp/symphony-workspace",
          %{},
          issue,
          %{changed_files: ["lib/source.ex"]},
          settings: settings,
          runner: fn %{kind: :review} ->
            Process.unlink(parent)
            Process.exit(self(), :kill)
          end
        )
      after
        Process.flag(:trap_exit, previous_trap_exit)
      end

    assert killed.status == :blocked
    assert Enum.any?(killed.jobs, &(&1.blocked_reason =~ "source_job_exit"))

    previous_trap_exit = Process.flag(:trap_exit, true)

    killed_docs =
      try do
        QualityGate.run(
          "/tmp/symphony-workspace",
          %{},
          issue,
          %{changed_files: ["lib/source.ex", "README.md"]},
          settings: settings,
          runner: fn
            %{kind: :review, job: %{category: :docs_source_of_truth}} ->
              Process.unlink(parent)
              Process.exit(self(), :kill)

            %{kind: :review} ->
              {:ok, %{status: :passed, findings: []}}
          end
        )
      after
        Process.flag(:trap_exit, previous_trap_exit)
      end

    assert killed_docs.status == :blocked

    assert Enum.any?(
             killed_docs.jobs,
             &(&1.category == :docs_source_of_truth and &1.blocked_reason =~ "source_job_exit")
           )

    raised =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["lib/source.ex"]},
        settings: settings,
        runner: fn %{kind: :review} -> raise "review exploded" end
      )

    assert Enum.any?(raised.jobs, &(&1.blocked_reason =~ "review exploded"))

    thrown =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["lib/source.ex"]},
        settings: settings,
        runner: fn %{kind: :review} -> throw(:review_thrown) end
      )

    assert Enum.any?(thrown.jobs, &(&1.blocked_reason =~ "review_thrown"))
  end

  test "quality gate covers failed repair attempts" do
    issue = %Issue{identifier: "SID-319", title: "Quality gate"}

    review_fix_required = fn
      %{kind: :review} ->
        {:ok,
         %{
           status: :fix_required,
           findings: [
             %{
               category: :source_correctness,
               evidence: "Needs repair",
               recommended_disposition: :fix_required
             }
           ]
         }}
    end

    errored =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["lib/source.ex"]},
        runner: fn
          %{kind: :repair} -> {:error, :repair_failed}
          context -> review_fix_required.(context)
        end
      )

    assert errored.status == :blocked
    assert [%{repair_result: %{blocked_reason: repair_failed_reason}}] = errored.repair_passes
    assert repair_failed_reason =~ "repair_failed"

    raised =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["lib/source.ex"]},
        runner: fn
          %{kind: :repair} -> raise "repair exploded"
          context -> review_fix_required.(context)
        end
      )

    assert [%{repair_result: %{blocked_reason: raised_reason}}] = raised.repair_passes
    assert raised_reason =~ "repair exploded"

    thrown =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["lib/source.ex"]},
        runner: fn
          %{kind: :repair} -> throw(:repair_thrown)
          context -> review_fix_required.(context)
        end
      )

    assert [%{repair_result: %{blocked_reason: thrown_reason}}] = thrown.repair_passes
    assert thrown_reason =~ "repair_thrown"

    invalid =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["lib/source.ex"]},
        runner: fn
          %{kind: :repair} -> :bad
          context -> review_fix_required.(context)
        end
      )

    assert [%{repair_result: %{blocked_reason: invalid_reason}}] = invalid.repair_passes
    assert invalid_reason =~ "invalid_repair_output"
  end

  test "quality gate covers repair fallbacks and malformed settings" do
    issue = %Issue{identifier: "SID-319", title: "Quality gate"}

    empty_prompt =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_surfaces: ["cli"]},
        browser_preflight: fn _context -> :ok end,
        runner: fn
          %{kind: :review} ->
            {:ok,
             %{
               status: :passed,
               findings: [
                 %{
                   category: "not-an-atom",
                   evidence: "Needs manual repair",
                   recommended_disposition: :fix_required
                 }
               ]
             }}

          %{kind: :repair, prompt: prompt} ->
            assert prompt =~ "- None supplied."
            {:ok, %{status: :passed}}
        end
      )

    assert empty_prompt.status == :fix_required
    assert [%{status: :fix_required, rerun_categories: [:scenario_qa]}] = empty_prompt.repair_passes

    summary_only =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["lib/source.ex"]},
        runner: fn
          %{kind: :repair} ->
            %{status: :fix_required, summary: "Repair still needs work."}

          %{kind: :review} ->
            {:ok,
             %{
               status: :fix_required,
               findings: [
                 %{
                   category: :source_correctness,
                   evidence: "Needs repair",
                   recommended_disposition: :fix_required
                 }
               ]
             }}
        end
      )

    assert summary_only.status == :blocked
    assert summary_only.unresolved_human_review_reasons |> hd() == "Repair still needs work."

    malformed_settings =
      QualityGate.run(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["lib/source.ex"]},
        settings: :bad,
        runner: fn
          %{kind: :repair} ->
            {:ok, %{status: :passed}}

          %{kind: :review, phase: :initial} ->
            {:ok,
             %{
               status: :fix_required,
               findings: [
                 %{
                   category: :source_correctness,
                   evidence: "Needs repair",
                   recommended_disposition: :fix_required
                 }
               ]
             }}

          %{kind: :review, phase: {:repair, 1}} ->
            {:ok, %{status: :passed, findings: []}}
        end
      )

    assert malformed_settings.status == :passed
    assert [%{attempt: 1}] = malformed_settings.repair_passes
  end

  test "quality gate default runner handles missing workspace and app-server failures" do
    issue = %Issue{identifier: "SID-319", title: "Quality gate"}

    missing_workspace = QualityGate.run(nil, %{}, issue, %{changed_files: ["lib/source.ex"]})
    assert missing_workspace.status == :blocked
    assert Enum.any?(missing_workspace.jobs, &(&1.raw_output.blocked_reason == :workspace_unavailable))

    test_root = Path.join(System.tmp_dir!(), "symphony-quality-gate-app-failure-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "SID-319")
    fake_codex = Path.join(test_root, "fake-codex")

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/source.ex"), "defmodule Source do\nend\n")
    File.write!(fake_codex, "#!/bin/sh\nexit 1\n")
    File.chmod!(fake_codex, 0o755)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{fake_codex} app-server",
        quality_gate_enabled: true
      )

      failed = QualityGate.run(workspace, %{}, issue, %{changed_files: ["lib/source.ex"]})
      assert failed.status == :blocked

      assert Enum.any?(failed.jobs, fn job ->
               match?({:codex_app_server_unavailable, _reason}, job.raw_output.blocked_reason)
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "quality gate default runner retries app-server launch failures from reviewer profile" do
    test_root = Path.join(System.tmp_dir!(), "symphony-quality-gate-app-retry-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "SID-319")
    fake_codex = Path.join(test_root, "fake-codex")
    count_file = Path.join(test_root, "attempt-count")

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/source.ex"), "defmodule Source do\nend\n")

    File.write!(fake_codex, """
    #!/bin/sh
    count_file="#{count_file}"
    count=$(cat "$count_file" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"

    if [ "$count" -eq 1 ]; then
      exit 1
    fi

    while IFS= read -r line; do
      if printf '%s' "$line" | grep -q '"method":"initialize"'; then
        printf '%s\\n' '{"id":1,"result":{}}'
      elif printf '%s' "$line" | grep -q '"method":"thread/start"'; then
        printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-quality"}}}'
      elif printf '%s' "$line" | grep -q '"method":"turn/start"'; then
        printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-quality"}}}'
        printf '%s\\n' '{"method":"turn/completed","params":{"completion":{"quality_gate_reviewer":{"status":"passed","findings":[]}}}}'
        exit 0
      fi
    done
    """)

    File.chmod!(fake_codex, 0o755)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{fake_codex} app-server",
        quality_gate_enabled: true,
        quality_gate_source_max_concurrency: 1,
        quality_gate_reviewer_max_retries: 1
      )

      result =
        QualityGate.run(
          workspace,
          %{},
          %Issue{identifier: "SID-319", title: "Retry runner"},
          %{changed_files: ["lib/source.ex"]}
        )

      assert result.status == :passed
      assert count_file |> File.read!() |> String.to_integer() >= 2
    after
      File.rm_rf(test_root)
    end
  end

  test "execution profile fallbacks cover command and malformed profile inputs" do
    assert %{name: "implementation", reasoning_effort: nil} = ExecutionProfile.resolve(nil)

    assert ["custom", "app-server"] ==
             ExecutionProfile.command(["codex", "app-server"], %{
               command: ["custom", "app-server"],
               model: "ignored",
               reasoning_effort: "high"
             })

    assert ["codex", "app-server"] ==
             ExecutionProfile.command(["codex", "app-server"], %{reasoning_effort: nil, model: nil})

    assert ["codex", "--config", "model=\"gpt-5.5\"", "app-server"] ==
             ExecutionProfile.command(["codex", "app-server"], %{reasoning_effort: nil, model: nil}, "gpt-5.5")

    assert ["codex", "--config", "model=\"gpt-5.5\"", "app-server"] ==
             ExecutionProfile.command(
               ["codex", "--config", "model=\"gpt-5.5\"", "app-server"],
               %{reasoning_effort: nil, model: nil},
               "gpt-5.4"
             )

    assert ["codex", "--model", "gpt-5.5", "app-server"] ==
             ExecutionProfile.command(
               ["codex", "--model", "gpt-5.5", "app-server"],
               %{reasoning_effort: nil, model: nil},
               "gpt-5.4"
             )

    assert ["codex", "--config", "model=\"gpt-5.4\"", "app-server"] ==
             ExecutionProfile.command(
               ["codex", "app-server"],
               %{reasoning_effort: nil, model: "gpt-5.4"},
               "gpt-5.5"
             )

    assert ["codex", "run", "--config", "model=\"gpt-5.5\""] ==
             ExecutionProfile.command(["codex", "run"], %{model: "gpt-5.5", reasoning_effort: nil})

    assert {:ok, settings} =
             Schema.parse(%{
               "profiles" => %{"default" => %{"delivery" => %{"pr_target" => "main"}}},
               "runners" => %{
                 "codex" => %{
                   "kind" => "codex_app_server",
                   "command" => ["codex", "app-server"],
                   "execution_profiles" => %{
                     "" => "bad",
                     "test_reviewer" => %{"reasoning_effort" => "x-high", "timeout_ms" => 0, "max_retries" => -1}
                   }
                 }
               },
               "quality_gate" => %{"runtime_isolation" => "BLOCKED"}
             })

    assert settings.quality_gate.runtime_isolation == "blocked"
    assert %{reasoning_effort: "xhigh", timeout_ms: 1_200_000, max_retries: 0} = ExecutionProfile.resolve(settings, "test_reviewer")

    non_map_profiles = %{settings | runners: put_in(settings.runners, ["codex", "execution_profiles"], "bad")}
    assert %{reasoning_effort: "medium"} = ExecutionProfile.resolve(non_map_profiles, "source_reviewer")

    codex_timeout_settings = %{settings | quality_gate: %{settings.quality_gate | reviewer_timeout_ms: nil}}
    assert %{timeout_ms: 3_600_000} = ExecutionProfile.resolve(codex_timeout_settings, "source_reviewer")

    blank_model_settings = %{
      settings
      | runners: put_in(settings.runners, ["codex", "execution_profiles"], %{"source_reviewer" => %{"model" => " "}})
    }

    assert %{model: nil} = ExecutionProfile.resolve(blank_model_settings, "source_reviewer")

    command_settings = %{
      settings
      | runners:
          put_in(settings.runners, ["codex", "execution_profiles"], %{
            "source_reviewer" => %{"command" => ["custom", nil, "app-server"]},
            "test_reviewer" => %{"command" => "custom --flag 'two words'"},
            "docs_reviewer" => %{"command" => ""},
            "product_visual_review" => %{"command" => [nil, " "]},
            "runtime_qa" => %{"command" => "'unterminated"},
            "security_reviewer" => %{"command" => 123}
          })
    }

    assert %{command: ["custom", "app-server"]} = ExecutionProfile.resolve(command_settings, "source_reviewer")
    assert %{command: ["custom", "--flag", "two words"]} = ExecutionProfile.resolve(command_settings, "test_reviewer")
    assert %{command: nil} = ExecutionProfile.resolve(command_settings, "docs_reviewer")
    assert %{command: nil} = ExecutionProfile.resolve(command_settings, "product_visual_review")
    assert %{command: nil} = ExecutionProfile.resolve(command_settings, "runtime_qa")
    assert %{command: nil} = ExecutionProfile.resolve(command_settings, "security_reviewer")

    invalid_timeout_settings = %{
      codex_timeout_settings
      | runners: put_in(codex_timeout_settings.runners, ["codex", "turn_timeout_ms"], "bad")
    }

    assert %{timeout_ms: 3_600_000} = ExecutionProfile.resolve(invalid_timeout_settings, "source_reviewer")
  end

  test "quality gate schema preserves non-binary runtime isolation validation errors" do
    changeset = Schema.QualityGate.changeset(%Schema.QualityGate{}, %{runtime_isolation: 123})
    refute changeset.valid?
  end

  test "default app-server runner records reviewer and repair output" do
    test_root = Path.join(System.tmp_dir!(), "symphony-quality-gate-default-runner-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "SID-319")
    fake_codex = Path.join(test_root, "fake-codex")

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/source.ex"), "defmodule Source do\nend\n")

    File.write!(fake_codex, """
    #!/bin/sh
    while IFS= read -r line; do
      if printf '%s' "$line" | grep -q '"method":"initialize"'; then
        printf '%s\\n' '{"id":1,"result":{}}'
      elif printf '%s' "$line" | grep -q '"method":"thread/start"'; then
        printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-quality"}}}'
      elif printf '%s' "$line" | grep -q '"method":"turn/start"'; then
        printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-quality"}}}'

        if printf '%s' "$line" | grep -qi 'repair pass'; then
          printf '%s\\n' '{"method":"turn/completed","params":{"completion":{"quality_gate_reviewer":{"status":"passed","findings":[]}}}}'
        else
          printf '%s\\n' '{"method":"turn/completed","params":{"completion":{"quality_gate_reviewer":{"status":"fix_required","findings":[{"category":"source_correctness","evidence":"Needs repair","recommended_disposition":"fix_required"}]}}}}'
        fi

        exit 0
      fi
    done
    """)

    File.chmod!(fake_codex, 0o755)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{fake_codex} app-server",
        quality_gate_enabled: true
      )

      result =
        QualityGate.run(
          workspace,
          %{},
          %Issue{identifier: "SID-319", title: "Default runner"},
          %{changed_files: ["lib/source.ex"]}
        )

      assert [%{repair_result: %{status: :passed}}] = result.repair_passes
      assert Enum.any?(result.jobs, &(&1.raw_output[:session_id] || &1.raw_output["session_id"]))
    after
      File.rm_rf(test_root)
    end
  end

  test "default app-server runner launches review and repair on worker host" do
    test_root = Path.join(System.tmp_dir!(), "symphony-quality-gate-remote-runner-#{System.unique_integer([:positive])}")
    fake_bin = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    trace_file = Path.join(test_root, "ssh.trace")
    count_file = Path.join(test_root, "turn-count")
    remote_workspace = "/remote/workspaces/SID-319"
    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")
    previous_count = System.get_env("SYMP_TEST_SSH_COUNT")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      restore_env("SYMP_TEST_SSH_COUNT", previous_count)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(fake_bin)
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
    System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
    System.put_env("SYMP_TEST_SSH_COUNT", count_file)
    System.delete_env("SYMPHONY_SSH_CONFIG")

    File.write!(fake_ssh, """
    #!/bin/sh
    trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-quality-gate-remote.trace}"
    count_file="${SYMP_TEST_SSH_COUNT:-/tmp/symphony-quality-gate-remote.count}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"

    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$line" in
        *initialize*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *thread/start*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-quality-remote"}}}'
          ;;
        *turn/start*)
          lock_dir="${count_file}.lock"
          while ! mkdir "$lock_dir" 2>/dev/null; do
            sleep 0.01
          done

          count=0
          if [ -f "$count_file" ]; then
            IFS= read -r count < "$count_file" || count=0
          fi
          count=$((count + 1))
          printf '%s\\n' "$count" > "$count_file"
          rmdir "$lock_dir"

          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-quality-remote"}}}'

          if [ "$count" -eq 1 ]; then
            printf '%s\\n' '{"method":"turn/completed","params":{"completion":{"quality_gate_reviewer":{"status":"fix_required","findings":[{"category":"source_correctness","evidence":"Needs repair","recommended_disposition":"fix_required"}]}}}}'
          else
            printf '%s\\n' '{"method":"turn/completed","params":{"completion":{"quality_gate_reviewer":{"status":"passed","findings":[]}}}}'
          fi

          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(fake_ssh, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/remote/workspaces",
      codex_command: "fake-remote-codex app-server",
      quality_gate_enabled: true
    )

    result =
      QualityGate.run(
        remote_workspace,
        %{},
        %Issue{identifier: "SID-319", title: "Remote default runner"},
        %{changed_files: ["lib/source.ex"]},
        worker_host: "worker-01:2200"
      )

    assert result.status == :passed
    assert [%{repair_result: %{status: :passed}}] = result.repair_passes
    assert count_file |> File.read!() |> String.trim() |> String.to_integer() >= 3

    argv_lines =
      trace_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "ARGV:"))

    assert length(argv_lines) >= 3
    assert Enum.all?(argv_lines, &(&1 =~ "-T -p 2200 worker-01 bash -lc"))
    assert Enum.all?(argv_lines, &(&1 =~ remote_workspace))
  end

  test "default app-server runner accepts direct and missing completion payloads" do
    test_root = Path.join(System.tmp_dir!(), "symphony-quality-gate-direct-runner-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "SID-319")
    fake_codex = Path.join(test_root, "fake-codex")

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/source.ex"), "defmodule Source do\nend\n")

    File.write!(fake_codex, """
    #!/bin/sh
    while IFS= read -r line; do
      if printf '%s' "$line" | grep -q '"method":"initialize"'; then
        printf '%s\\n' '{"id":1,"result":{}}'
      elif printf '%s' "$line" | grep -q '"method":"thread/start"'; then
        printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-quality"}}}'
      elif printf '%s' "$line" | grep -q '"method":"turn/start"'; then
        printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-quality"}}}'

        if printf '%s' "$line" | grep -q 'missing-completion'; then
          printf '%s\\n' '{"method":"turn/completed","params":{}}'
        else
          printf '%s\\n' '{"method":"turn/completed","params":{"completion":{"status":"passed","findings":[]}}}'
        fi

        exit 0
      fi
    done
    """)

    File.chmod!(fake_codex, 0o755)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{fake_codex} app-server",
        quality_gate_enabled: true
      )

      direct =
        QualityGate.run(
          workspace,
          %{},
          %Issue{identifier: "SID-319", title: "Direct completion"},
          %{changed_files: ["lib/source.ex"]}
        )

      assert direct.status == :passed

      missing =
        QualityGate.run(
          workspace,
          %{},
          %Issue{identifier: "SID-319", title: "missing-completion"},
          %{changed_files: ["lib/source.ex"]}
        )

      assert missing.status == :blocked
      assert Enum.any?(missing.jobs, &(&1.raw_output.blocked_reason == :reviewer_output_missing))
    after
      File.rm_rf(test_root)
    end
  end

  defp capture_visual_review_policy(policy) do
    parent = self()

    result =
      QualityGate.run(
        "/tmp/symphony-workspace",
        policy,
        %Issue{identifier: "SID-319", title: "Quality gate"},
        %{changed_surfaces: ["web_ui"]},
        settings: %Schema.QualityGate{max_repair_passes: 0},
        browser_preflight: fn _context -> {:ok, %{browser: "checked"}} end,
        runner: fn %{kind: :review, policy: review_policy} ->
          send(parent, {:captured_visual_review_policy, review_policy})
          {:ok, %{status: :passed, findings: []}}
        end
      )

    assert_receive {:captured_visual_review_policy, review_policy}
    {result, review_policy}
  end

  defp run_default_visual_preflight(opts \\ []) do
    QualityGate.run(
      "/tmp/symphony-workspace",
      %{},
      %Issue{identifier: "SID-319", title: "Quality gate"},
      %{changed_surfaces: ["web_ui"]},
      Keyword.merge(
        [
          settings: %Schema.QualityGate{max_repair_passes: 0},
          runner: fn %{kind: :review} -> {:ok, %{status: :passed, findings: []}} end
        ],
        opts
      )
    )
  end
end
