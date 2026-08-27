defmodule SymphonyElixir.QualityGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.Event
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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

    selected_runner =
      overridden_settings
      |> Schema.default_runner_config!()
      |> put_in(["execution_profiles", "source_reviewer", "reasoning_effort"], "xhigh")

    assert %{reasoning_effort: "xhigh"} =
             ExecutionProfile.resolve(overridden_settings, selected_runner, "source_reviewer")

    assert %{reasoning_effort: "none"} = ExecutionProfile.resolve(overridden_settings, "runtime_qa")
    assert %{reasoning_effort: "max"} = ExecutionProfile.resolve(overridden_settings, "security_reviewer")
  end

  test "pure execution profile resolution accepts absent and partial composed profiles" do
    partial_runner = %{
      "execution_profiles" => %{
        "source_reviewer" => %{"model" => "gpt-review"}
      }
    }

    assert {:ok,
            %{
              name: "source_reviewer",
              reasoning_effort: "medium",
              budget: "standard",
              timeout_ms: 45_000,
              max_retries: 2,
              command: nil,
              model: "gpt-review"
            }} =
             ExecutionProfile.resolve_pinned(
               partial_runner,
               "source_reviewer",
               45_000,
               2
             )

    assert {:ok, %{name: "source_reviewer", model: "gpt-review"}} =
             ExecutionProfile.resolve_pinned(partial_runner, :source_reviewer, 45_000, 2)

    assert {:ok, %{name: "source_reviewer"}} =
             ExecutionProfile.resolve_pinned(
               %{"execution_profiles" => %{}},
               "source_reviewer",
               45_000,
               2
             )

    assert {:ok, %{name: "implementation"}} =
             ExecutionProfile.resolve_pinned(%{}, "", 45_000, 2)

    assert ExecutionProfile.resolve_pinned(%{}, <<0xFF>>, 45_000, 2) ==
             {:error, :invalid_profile}

    numeric_runner =
      put_in(partial_runner, ["execution_profiles", "source_reviewer", "model"], 407)

    assert {:ok, %{model: "407"}} =
             ExecutionProfile.resolve_pinned(numeric_runner, "source_reviewer", 45_000, 2)

    scalar_command_runner =
      put_in(partial_runner, ["execution_profiles", "source_reviewer", "command"], 407)

    assert {:ok, %{command: nil, model: "gpt-review"}} =
             ExecutionProfile.resolve_pinned(scalar_command_runner, "source_reviewer", 45_000, 2)

    assert {:ok,
            %{
              name: "implementation",
              reasoning_effort: nil,
              budget: "standard",
              timeout_ms: 60_000,
              max_retries: 0,
              command: nil,
              model: nil
            }} = ExecutionProfile.resolve_pinned(%{}, nil, 60_000, 0)
  end

  test "pure execution profile resolution rejects present scalar named profiles" do
    for scalar <- ["invalid", 407, [], true, nil] do
      runner = %{"execution_profiles" => %{"source_reviewer" => scalar}}

      assert ExecutionProfile.resolve_pinned(runner, "source_reviewer", 45_000, 0) ==
               {:error, :invalid_runner}
    end
  end

  test "pure execution profile resolution rejects hostile terms with fixed errors" do
    secret = "profile-secret-407"

    hostile_runner = %{
      "execution_profiles" => %{
        "source_reviewer" => %{"model" => fn -> secret end}
      }
    }

    result = ExecutionProfile.resolve_pinned(hostile_runner, "source_reviewer", 45_000, 0)
    assert result == {:error, :invalid_runner}
    refute inspect(result) =~ secret

    assert ExecutionProfile.resolve_pinned(nil, "source_reviewer", 45_000, 0) ==
             {:error, :invalid_runner}

    nested_struct = %{"extension" => %URI{host: secret}}

    assert ExecutionProfile.resolve_pinned(nested_struct, "source_reviewer", 45_000, 0) ==
             {:error, :invalid_runner}

    assert ExecutionProfile.resolve_pinned(
             %{"extension" => [1 | 2]},
             "source_reviewer",
             45_000,
             0
           ) == {:error, :invalid_runner}

    assert ExecutionProfile.resolve_pinned(%{}, %URI{host: secret}, 45_000, 0) ==
             {:error, :invalid_profile}

    assert ExecutionProfile.resolve_pinned(%{}, "source_reviewer", 0, 0) ==
             {:error, :invalid_fallbacks}

    normalizable_runner = %{
      "extension" => 1.5,
      "execution_profiles" => %{
        "source_reviewer" => %{
          "reasoning_effort" => " ",
          "model" => %{"ignored" => "value"}
        }
      }
    }

    assert {:ok, %{reasoning_effort: nil, model: nil}} =
             ExecutionProfile.resolve_pinned(
               normalizable_runner,
               "source_reviewer",
               45_000,
               0
             )

    for runner <- [
          %{~c"execution_profiles" => %{}},
          %{"execution_profiles" => %{~c"source-reviewer" => %{}}},
          %{"execution_profiles" => %{"source_reviewer" => %{~c"model" => ~c"legacy-model"}}}
        ] do
      assert ExecutionProfile.resolve_pinned(runner, "source_reviewer", 45_000, 0) ==
               {:error, :invalid_runner}
    end

    assert ExecutionProfile.resolve_pinned(%{}, ~c"source-reviewer", 45_000, 0) ==
             {:error, :invalid_profile}
  end

  test "legacy execution profile resolve/3 preserves non-UTF-8 binary commands" do
    settings = Config.settings!()

    runner = %{
      "execution_profiles" => %{
        "source_reviewer" => %{"command" => <<0xFF>>}
      }
    }

    assert ExecutionProfile.resolve_pinned(runner, "source_reviewer", 45_000, 0) ==
             {:error, :invalid_runner}

    assert %{command: [<<0xFF>>]} =
             ExecutionProfile.resolve(settings, runner, "source_reviewer")
  end

  test "legacy execution profile resolve/3 normalizes nested charlist references, keys, and values" do
    settings = Config.settings!()

    charlist_top_level_runner = %{
      ~c"execution_profiles" => %{
        ~c"source-reviewer" => %{
          ~c"model" => ~c"legacy-model"
        }
      }
    }

    assert ExecutionProfile.resolve(settings, charlist_top_level_runner, ~c"source-reviewer") == %{
             name: "source_reviewer",
             reasoning_effort: "medium",
             budget: "standard",
             timeout_ms: settings.quality_gate.reviewer_timeout_ms,
             max_retries: settings.quality_gate.reviewer_max_retries,
             command: nil,
             model: nil
           }

    exact_string_top_level_runner = %{
      "execution_profiles" => %{
        ~c"source-reviewer" => %{
          ~c"model" => ~c"legacy-model"
        }
      }
    }

    assert ExecutionProfile.resolve(settings, exact_string_top_level_runner, ~c"source-reviewer") == %{
             name: "source_reviewer",
             reasoning_effort: "medium",
             budget: "standard",
             timeout_ms: settings.quality_gate.reviewer_timeout_ms,
             max_retries: settings.quality_gate.reviewer_max_retries,
             command: nil,
             model: "legacy-model"
           }
  end

  test "legacy execution profile resolve/3 coerces integer refs and rejects unsupported refs" do
    settings = Config.settings!()
    runner = %{"execution_profiles" => %{}}

    assert ExecutionProfile.resolve_pinned(runner, 407, 45_000, 2) ==
             {:error, :invalid_profile}

    assert %{name: "407"} = ExecutionProfile.resolve(settings, runner, 407)

    assert_raise Protocol.UndefinedError, fn ->
      ExecutionProfile.resolve(settings, runner, {:source_reviewer, :extra})
    end

    assert_raise Protocol.UndefinedError, fn ->
      ExecutionProfile.resolve(settings, runner, %{name: "source_reviewer"})
    end
  end

  test "legacy execution profile resolve/3 preserves nested coercion errors" do
    settings = Config.settings!()

    for runner <- [
          %{"execution_profiles" => %{{:source, :reviewer} => %{}}},
          %{"execution_profiles" => %{"source_reviewer" => %{{:model, :key} => "ignored"}}}
        ] do
      assert_raise Protocol.UndefinedError, fn ->
        ExecutionProfile.resolve(settings, runner, "source_reviewer")
      end
    end

    for value <- [{:invalid, :value}, %{}, fn -> :invalid end] do
      runner = %{"execution_profiles" => %{"source_reviewer" => %{"model" => value}}}

      assert_raise Protocol.UndefinedError, fn ->
        ExecutionProfile.resolve(settings, runner, "source_reviewer")
      end
    end
  end

  test "legacy execution profile resolve/3 accepts exact string execution_profiles key" do
    settings = Config.settings!()

    runner = %{
      "execution_profiles" => %{
        "source_reviewer" => %{"model" => "gpt-review"}
      }
    }

    assert %{name: "source_reviewer", model: "gpt-review"} =
             ExecutionProfile.resolve(settings, runner, "source_reviewer")
  end

  test "legacy execution profile resolve/3 ignores invalid fallback overrides" do
    settings = Config.settings!()

    runner = %{
      "execution_profiles" => %{
        "source_reviewer" => %{
          "model" => "gpt-review",
          "timeout_ms" => :invalid,
          "max_retries" => :invalid,
          "command" => 407
        }
      }
    }

    profile = ExecutionProfile.resolve(settings, runner, "source_reviewer")

    assert profile.model == "gpt-review"
    assert profile.timeout_ms == settings.quality_gate.reviewer_timeout_ms
    assert profile.max_retries == settings.quality_gate.reviewer_max_retries
    assert profile.command == nil
  end

  test "legacy execution profile resolve/3 discards unknown profile fields" do
    settings = Config.settings!()

    runner = %{
      "execution_profiles" => %{
        "source_reviewer" => %{"legacy_extension" => :atom}
      }
    }

    assert ExecutionProfile.resolve(settings, runner, :source_reviewer) == %{
             name: "source_reviewer",
             reasoning_effort: "medium",
             budget: "standard",
             timeout_ms: settings.quality_gate.reviewer_timeout_ms,
             max_retries: settings.quality_gate.reviewer_max_retries,
             command: nil,
             model: nil
           }
  end

  test "legacy execution profile wrappers delegate with settings fallbacks" do
    settings = Config.settings!()
    runner = Schema.default_runner_config!(settings)

    assert {:ok, pure_profile} =
             ExecutionProfile.resolve_pinned(
               runner,
               "test_reviewer",
               settings.quality_gate.reviewer_timeout_ms,
               settings.quality_gate.reviewer_max_retries
             )

    assert ExecutionProfile.resolve(settings, runner, "test_reviewer") == pure_profile
    assert ExecutionProfile.resolve(settings, "test_reviewer") == pure_profile

    runner_with_extension = Map.put(runner, :extension, true)

    assert ExecutionProfile.resolve(settings, runner_with_extension, "test_reviewer") == pure_profile

    legacy_runner =
      Map.put(runner, "execution_profiles", %{
        :source_reviewer => %{model: 123}
      })

    assert %{model: "123"} =
             ExecutionProfile.resolve(settings, legacy_runner, :source_reviewer)
  end

  test "handoff routing consumes quality gate evidence" do
    workspace = Path.join(System.tmp_dir!(), "symphony-quality-gate-route-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(workspace) end)

    fix_required =
      HandoffRouteRecorder.classify_completion_for_test(
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
      HandoffRouteRecorder.classify_completion_for_test(
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
    assert %{status: :passed} = QualityGate.run_for_test(nil, %{}, nil, "not metadata")
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
      QualityGate.run_for_test(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_surfaces: ["cli"]},
        settings: %Schema.QualityGate{runtime_isolation: "blocked"}
      )

    assert blocked_runtime.status == :blocked
    assert Enum.any?(blocked_runtime.jobs, &(&1.blocked_reason =~ "runtime_review_blocked_by_policy"))

    isolated_runtime =
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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

    QualityGate.run_for_test(
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

    QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
        QualityGate.run_for_test(
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
        QualityGate.run_for_test(
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
      QualityGate.run_for_test(
        "/tmp/symphony-workspace",
        %{},
        issue,
        %{changed_files: ["lib/source.ex"]},
        settings: settings,
        runner: fn %{kind: :review} -> raise "review exploded" end
      )

    assert Enum.any?(raised.jobs, &(&1.blocked_reason =~ "review exploded"))

    thrown =
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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
      QualityGate.run_for_test(
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

  test "normalized reviewer completion parsing handles supported payload boundaries" do
    reviewer = %{status: :passed, findings: []}

    nested = %Event{
      payload: %{
        payload: %{"params" => %{"completion" => %{"quality_gate_reviewer" => reviewer}}}
      }
    }

    assert QualityGate.quality_gate_completion_for_test([nested]) == reviewer

    turn_nested = %Event{
      payload: %{
        "params" => %{
          "turn" => %{"completion" => %{"quality_gate_reviewer" => reviewer}}
        }
      }
    }

    assert QualityGate.quality_gate_completion_for_test([turn_nested]) == reviewer

    direct = %Event{payload: %{"params" => %{"completion" => reviewer}}}
    assert QualityGate.quality_gate_completion_for_test([direct]) == reviewer

    non_map = %Event{payload: %{"params" => %{"completion" => "invalid"}}}
    assert QualityGate.quality_gate_completion_for_test([non_map]) == nil
    assert QualityGate.quality_gate_completion_for_test([%Event{payload: %{}}]) == nil
  end

  defp capture_visual_review_policy(policy) do
    parent = self()

    result =
      QualityGate.run_for_test(
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
    QualityGate.run_for_test(
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
