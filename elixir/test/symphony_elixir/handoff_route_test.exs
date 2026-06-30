defmodule SymphonyElixir.HandoffRouteTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{HandoffRoute, HandoffRouteRecorder}
  alias SymphonyElixir.HandoffRoute.ProductVisualReviewEvidence
  alias SymphonyElixir.WorkflowModules.ProductVisualReview.Config, as: ProductVisualReviewConfig

  test "classifies dry-run auto-land as eligible while keeping handoff conservative" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "mix test", status: :passed}],
        review: %{status: :clean},
        changed_surfaces: [:docs, :tests],
        policy: %{auto_land: %{enabled: true}, pr_target: "main"}
      })

    assert decision.route == :auto_land
    assert decision.target_state == "Human Review"
    assert decision.summary =~ "Dry-run auto-land"
    assert decision.recommendation =~ "Auto-land"
    assert decision.metadata == %{auto_land_executor: "dry_run", dry_run: true}

    assert %{
             route: "auto_land",
             target_state: "Human Review",
             evidence: evidence
           } = HandoffRoute.to_map(decision)

    assert Enum.any?(evidence, &(&1.summary =~ "All checks passed"))
    assert Enum.any?(evidence, &(&1.summary =~ "low-risk"))
  end

  test "classifies explicitly opted-in permissive local work as guarded real auto-land" do
    decision =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        pr_feedback: clean_pr_feedback(),
        review: %{status: :clean},
        changed_surfaces: [:docs, :tests],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "none"},
          auto_land: %{posture: "permissive", dry_run: false}
        }
      })

    assert decision.route == :auto_land
    assert decision.target_state == "Merging"
    assert decision.summary =~ "guarded landing"
    assert decision.recommendation =~ "Merging"
    assert decision.metadata == %{auto_land_executor: "land_merge", dry_run: false}

    assert Enum.any?(
             decision.evidence,
             &(&1.kind == :auto_land and &1.status == :passed and &1.summary =~ "pr_feedback")
           )
  end

  test "classifies explicitly opted-in strict production work only with recovery evidence" do
    decision =
      HandoffRoute.classify(%{
        checks: auto_land_checks(strict_recovery_checks()),
        pr_feedback: clean_pr_feedback(),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "production_web"},
          auto_land: %{dry_run: false}
        }
      })

    assert decision.route == :auto_land
    assert decision.target_state == "Merging"

    assert Enum.any?(
             decision.evidence,
             &(&1.kind == :auto_land and &1.status == :passed and &1.summary =~ "rollback_plan")
           )
  end

  test "blocks real auto-land when PR feedback sweep evidence is missing" do
    decision =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "none"},
          auto_land: %{posture: "permissive", dry_run: false}
        }
      })

    assert decision.route == :blocked
    assert decision.target_state == "Human Review"

    assert Enum.any?(
             decision.evidence,
             &(&1.kind == :auto_land and &1.status == :missing and &1.summary =~ "pr_feedback")
           )
  end

  test "does not accept bare pr_feedback check tokens as sweep evidence" do
    decision =
      HandoffRoute.classify(%{
        checks: real_auto_land_checks(),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "none"},
          auto_land: %{posture: "permissive", dry_run: false}
        }
      })

    assert decision.route == :blocked
    assert decision.target_state == "Human Review"

    assert Enum.any?(
             decision.evidence,
             &(&1.kind == :auto_land and &1.status == :missing and &1.summary =~ "pr_feedback")
           )
  end

  test "routes stale sync or actionable PR feedback evidence to rework before real auto-land" do
    sync_failed =
      HandoffRoute.classify(%{
        checks: replace_check(auto_land_checks(), "sync", :failed, "Branch is stale against main."),
        pr_feedback: clean_pr_feedback(),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "none"},
          auto_land: %{posture: "permissive", dry_run: false}
        }
      })

    feedback_failed =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        pr_feedback: outstanding_pr_feedback(),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "none"},
          auto_land: %{posture: "permissive", dry_run: false}
        }
      })

    assert sync_failed.route == :rework
    assert sync_failed.target_state == "Rework"
    assert feedback_failed.route == :rework
    assert feedback_failed.target_state == "Rework"
  end

  test "routes structured PR feedback by normalized status and unresolved counts" do
    addressed =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        pr_feedback: clean_pr_feedback("addressed", "0"),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: permissive_real_auto_land_policy()
      })

    pushback_posted =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        pr_feedback: clean_pr_feedback("pushback_posted"),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: permissive_real_auto_land_policy()
      })

    unresolved_count =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        pr_feedback: clean_pr_feedback(:none, 0, top_level_count: 1),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: permissive_real_auto_land_policy()
      })

    assert addressed.route == :auto_land
    assert pushback_posted.route == :auto_land
    assert unresolved_count.route == :rework
  end

  test "blocks malformed structured PR feedback instead of treating it as proof" do
    incomplete_channel =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        pr_feedback: %{status: :none, top_level_comments: "not checked"},
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: permissive_real_auto_land_policy()
      })

    non_map_feedback =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        pr_feedback: "not feedback",
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: permissive_real_auto_land_policy()
      })

    unsupported_status =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        pr_feedback: clean_pr_feedback("not_applicable"),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: permissive_real_auto_land_policy()
      })

    unknown_status =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        pr_feedback: clean_pr_feedback("commented"),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: permissive_real_auto_land_policy()
      })

    non_string_status =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        pr_feedback: clean_pr_feedback(12),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: permissive_real_auto_land_policy()
      })

    malformed_count =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        pr_feedback: clean_pr_feedback(:none, "unparsed"),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: permissive_real_auto_land_policy()
      })

    non_integer_count =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        pr_feedback: clean_pr_feedback(:none, []),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: permissive_real_auto_land_policy()
      })

    for decision <- [
          incomplete_channel,
          non_map_feedback,
          unsupported_status,
          unknown_status,
          non_string_status,
          malformed_count,
          non_integer_count
        ] do
      assert decision.route == :blocked
      assert decision.target_state == "Human Review"
      assert Enum.any?(decision.evidence, &(&1.kind == :auto_land and &1.status == :missing))
    end
  end

  test "blocks strict real auto-land when production recovery evidence is missing" do
    decision =
      HandoffRoute.classify(%{
        checks: auto_land_checks(~w(deployment_status monitoring_source incident_issue_creation)),
        pr_feedback: clean_pr_feedback(),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "production_web"},
          auto_land: %{dry_run: false}
        }
      })

    assert decision.route == :blocked
    assert decision.target_state == "Human Review"

    assert Enum.any?(
             decision.evidence,
             &(&1.kind == :auto_land and &1.status == :missing and &1.summary =~ "rollback_plan")
           )
  end

  test "posture off prevents real auto-land even when legacy enabled flag is true" do
    decision =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        pr_feedback: clean_pr_feedback(),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: %{
          auto_land: %{enabled: true, posture: "off", dry_run: false}
        }
      })

    assert decision.route == :human_review
    assert decision.target_state == "Human Review"
  end

  test "classifies top-level auto-land enablement as auto-land eligible" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "mix test", status: :passed}],
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: %{auto_land_enabled: true}
      })

    assert decision.route == :auto_land
  end

  test "does not classify missing check evidence as auto-land eligible" do
    decision =
      HandoffRoute.classify(%{
        checks: [],
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: %{auto_land: %{enabled: true}}
      })

    assert decision.route == :human_review
    assert decision.target_state == "Human Review"
    assert Enum.any?(decision.evidence, &(&1.kind == :check and &1.status == :missing))
  end

  test "does not use manifest validation as the only auto-land check" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "change_manifest", status: :passed}],
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: %{auto_land: %{enabled: true}}
      })

    assert decision.route == :human_review
  end

  test "manifest auto-land policy blocks handoff when required evidence is missing" do
    decision =
      HandoffRoute.classify(%{
        checks: [
          %{name: "tests", status: :passed},
          %{name: "quality_gates", status: :passed},
          %{name: "automated_review", status: :passed},
          %{name: "route_classification", status: :passed},
          %{name: "sync", status: :passed}
        ],
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "none"},
          auto_land: %{
            posture: "permissive",
            required_checks: ["security-review"],
            blocked_state: "Human Review",
            dry_run: true
          }
        }
      })

    assert decision.route == :blocked
    assert decision.target_state == "Human Review"
    assert decision.summary =~ "Missing required auto-land evidence"
    assert Enum.any?(decision.evidence, &(&1.kind == :auto_land and &1.status == :missing and &1.summary =~ "security-review"))
  end

  test "manifest auto-land policy records passed evidence when every required check is present" do
    decision =
      HandoffRoute.classify(%{
        checks: auto_land_checks(["security-review"]),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "none"},
          auto_land: %{
            posture: "permissive",
            required_checks: ["security-review"],
            dry_run: true
          }
        }
      })

    assert decision.route == :auto_land
    assert Enum.any?(decision.evidence, &(&1.kind == :auto_land and &1.status == :passed))
  end

  test "manifest auto-land force-human-review labels route to human review" do
    decision =
      HandoffRoute.classify(%{
        checks: auto_land_checks(),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        issue_labels: [" Manual-Review "],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "none"},
          auto_land: %{posture: "permissive", dry_run: true}
        }
      })

    assert decision.route == :human_review

    assert Enum.any?(
             decision.evidence,
             &(&1.kind == :policy and &1.summary =~ "manual-review")
           )
  end

  test "auto-land posture off routes through human review" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "tests", status: :passed}],
        review: %{status: :clean},
        changed_surfaces: [:docs],
        policy: %{auto_land: %{posture: "off", dry_run: true}}
      })

    assert decision.route == :human_review
    assert decision.target_state == "Human Review"
  end

  test "routes risky completed work to human review with risk evidence" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "mix test", status: "passed"}],
        review: %{status: "clean"},
        changed_surfaces: [:workflow, :backend],
        policy: %{auto_land: %{enabled: true}}
      })

    assert decision.route == :human_review
    assert decision.target_state == "Human Review"
    assert decision.summary =~ "Human review"
    assert Enum.any?(decision.evidence, &(&1.kind == :changed_surface and &1.status == :risky))
  end

  test "routes failed checks and review feedback to rework" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "mix test", status: :failed, summary: "2 failures"}],
        review: %{status: :fix_required, findings: ["Inline reviewer requested a guard."]},
        changed_surfaces: [:elixir],
        policy: %{}
      })

    assert decision.route == :rework
    assert decision.target_state == "Rework"
    assert decision.recommendation =~ "Address failed gates"
    assert Enum.any?(decision.evidence, &(&1.kind == :check and &1.status == :failed))
    assert Enum.any?(decision.evidence, &(&1.kind == :review and &1.status == :fix_required))
  end

  test "routes external blockers to blocked handoff with required action" do
    decision =
      HandoffRoute.classify(%{
        blocker: %{
          reason: "Missing required Linear permission",
          required_action: "Grant comment edit access"
        },
        checks: [%{name: "mix test", status: :passed}]
      })

    assert decision.route == :blocked
    assert decision.target_state == "Human Review"
    assert decision.summary =~ "Blocked"
    assert decision.recommendation == "Grant comment edit access"
    assert Enum.any?(decision.evidence, &(&1.kind == :blocker))
  end

  test "decision-needed handoffs carry options and recommendation fields" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "mix test", status: :passed}],
        review: %{status: :decision_needed},
        changed_surfaces: [:domain],
        decision: %{
          question: "Should Symphony auto-land this class later?",
          recommendation: "Keep Human Review for v1",
          options: [
            %{id: "hold", label: "Keep Human Review", description: "Conservative v1 route."},
            %{id: "autoland", label: "Auto-land later", description: "Requires the land executor."}
          ]
        }
      })

    assert decision.route == :decision_needed
    assert decision.target_state == "Human Review"
    assert decision.recommendation == "Keep Human Review for v1"
    assert Enum.map(decision.options, & &1.id) == ["hold", "autoland"]

    assert %{options: [%{id: "hold"}, %{id: "autoland"}]} = HandoffRoute.to_map(decision)

    body = HandoffRoute.format_comment(decision)
    assert body =~ "### Handoff Route"
    assert body =~ "decision_needed"
    assert body =~ "Keep Human Review"
    assert body =~ "Recommended: Keep Human Review for v1"
  end

  test "routes decision-needed handoffs without concrete options to rework" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "mix test", status: :passed}],
        review: %{status: :decision_needed},
        decision: %{question: "Choose a deployment path"}
      })

    assert decision.route == :rework
    assert decision.target_state == "Rework"
    assert decision.recommendation =~ "Address failed gates"

    assert Enum.any?(
             decision.evidence,
             &(&1.kind == :route_gate and &1.status == :failed and &1.summary =~ "missing concrete options")
           )
  end

  test "routes decision-needed handoffs without concrete recommendation to rework" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "mix test", status: :passed}],
        review: %{status: :decision_needed},
        decision: %{
          question: "Choose a deployment path",
          options: [
            %{id: "hold", label: "Keep Human Review", description: "Use the conservative path."}
          ]
        }
      })

    assert decision.route == :rework
    assert decision.target_state == "Rework"

    assert Enum.any?(
             decision.evidence,
             &(&1.kind == :route_gate and &1.status == :failed and &1.summary =~ "missing a concrete recommendation")
           )
  end

  test "rejects malformed decision options before selecting decision-needed route" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "mix test", status: :passed}],
        review: %{status: :decision_needed},
        decision: %{
          question: "Choose a deployment path",
          recommendation: "Keep Human Review for v1",
          options: [
            %{},
            %{id: " ", label: "Keep Human Review", description: "Use the conservative path."},
            %{id: "hold", label: " ", description: "Use the conservative path."},
            %{id: "hold", label: "Keep Human Review", description: " "}
          ]
        }
      })

    assert decision.route == :rework
    assert decision.target_state == "Rework"
    assert decision.options == []

    assert Enum.any?(
             decision.evidence,
             &(&1.kind == :route_gate and &1.status == :failed and &1.summary =~ "missing concrete options")
           )
  end

  test "rejects mixed valid and malformed decision options before selecting decision-needed route" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "mix test", status: :passed}],
        review: %{status: :decision_needed},
        decision: %{
          question: "Choose a deployment path",
          recommendation: "Keep Human Review for v1",
          options: [
            %{id: "hold", label: "Keep Human Review", description: "Use the conservative path."},
            %{id: "ship", label: " ", description: "Ship immediately."}
          ]
        }
      })

    assert decision.route == :rework
    assert decision.target_state == "Rework"

    assert Enum.any?(
             decision.evidence,
             &(&1.kind == :route_gate and &1.status == :failed and &1.summary =~ "contains malformed options")
           )
  end

  test "product and visual handoffs use spec route name and preserve artifact links" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "mix test", status: :passed}],
        review: %{status: :clean},
        changed_surfaces: [:external_user_ui],
        artifacts: [
          %{kind: :screenshot, label: "Dashboard smoke", url: "https://example.test/smoke.png"},
          %{kind: :video, label: "Interaction capture", url: "https://example.test/smoke.mp4"}
        ]
      })

    assert decision.route == :product_visual_review
    assert decision.target_state == "Human Review"
    assert Enum.map(decision.artifacts, & &1.kind) == [:screenshot, :video]

    assert %{route: "product_visual_review", artifacts: [%{kind: "screenshot"}, %{kind: "video"}]} =
             HandoffRoute.to_map(decision)

    body = HandoffRoute.format_comment(decision)
    assert body =~ "Dashboard smoke"
    assert body =~ "https://example.test/smoke.png"
    assert body =~ "Interaction capture"
  end

  test "recorder records backend-only product visual review skip evidence" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_module_ids: ["product_visual_review"],
      workflow_modules_product_visual_review: %{enabled: true, route_policy: "auto"}
    )

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-visual-skip-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib/symphony_elixir"))
      File.write!(Path.join([workspace, "lib/symphony_elixir/orchestrator.ex"]), "defmodule Orchestrator, do: nil\n")

      decision =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "all", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "changed_files" => ["lib/symphony_elixir/orchestrator.ex"]
          },
          nil,
          workspace
        )

      assert decision.route == :human_review

      assert %{kind: :product_visual_review, status: :skipped, metadata: %{requirement: :skip}} =
               Enum.find(decision.evidence, &(&1.kind == :product_visual_review))
    after
      File.rm_rf(test_root)
    end
  end

  test "recorder ignores malformed precomputed changed-file metadata for visual QA classification" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_module_ids: ["product_visual_review"],
      workflow_modules_product_visual_review: %{enabled: true, route_policy: "auto"}
    )

    decision =
      HandoffRouteRecorder.classify_completion(%{
        "checks" => [
          123,
          %{"name" => "change_manifest", "status" => :passed, "metadata" => %{"changed_files" => "not a list"}}
        ],
        "product_visual_review" => %{"status" => "passed"}
      })

    assert decision.route == :rework

    assert %{kind: :product_visual_review, status: :skipped, metadata: %{matched_files: []}} =
             Enum.find(decision.evidence, &(&1.kind == :product_visual_review))
  end

  test "recorder classifies visual QA from host-validated manifest instead of stale completion check" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_module_ids: ["product_visual_review"],
      workflow_modules_product_visual_review: %{enabled: true, route_policy: "auto"}
    )

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-visual-trusted-manifest-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib/example_web/live"))
      File.write!(Path.join([workspace, "lib/example_web/live/dashboard_live.ex"]), "defmodule DashboardLive, do: nil\n")

      decision =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [
              %{
                "name" => "change_manifest",
                "status" => :passed,
                "metadata" => %{"changed_files" => []}
              }
            ],
            "review" => %{"status" => "clean"},
            "changed_files" => ["lib/example_web/live/dashboard_live.ex"]
          },
          nil,
          workspace
        )

      assert decision.route == :blocked

      assert %{kind: :product_visual_review, status: :blocked, metadata: %{matched_files: matched_files}} =
               Enum.find(decision.evidence, &(&1.kind == :product_visual_review))

      assert matched_files == ["lib/example_web/live/dashboard_live.ex"]
    after
      File.rm_rf(test_root)
    end
  end

  test "recorder preserves durable product visual review artifacts and rejects local temp paths" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_module_ids: ["product_visual_review"],
      workflow_modules_product_visual_review: %{enabled: true, route_policy: "auto"}
    )

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-visual-artifacts-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib/example_web/live"))
      File.write!(Path.join([workspace, "lib/example_web/live/dashboard_live.ex"]), "defmodule DashboardLive, do: nil\n")

      decision =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "all", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "changed_files" => ["lib/example_web/live/dashboard_live.ex"],
            "product_visual_review" => %{
              "status" => "passed",
              "checks" => [
                %{"name" => "viewport_screenshots", "status" => "passed", "summary" => "desktop and mobile captured"},
                %{"name" => "interaction_smoke", "status" => "passed", "summary" => "filter toggle worked"}
              ],
              "artifacts" => [
                %{
                  "kind" => "screenshot",
                  "label" => "Desktop screenshot",
                  "url" => "https://artifacts.example/SID-314/desktop.png"
                },
                %{
                  "kind" => "screenshot",
                  "label" => "Mobile screenshot",
                  "url" => "/private/tmp/symphony/mobile.png"
                },
                %{
                  "kind" => "interaction_notes",
                  "label" => "Interaction smoke",
                  "summary" => "Toggled the filter and confirmed the result count changed."
                },
                %{
                  "kind" => "product_design_notes",
                  "label" => "Product design notes",
                  "summary" => "Empty and loading states were unchanged."
                }
              ]
            }
          },
          nil,
          workspace
        )

      assert decision.route == :product_visual_review
      assert Enum.map(decision.artifacts, & &1.label) == ["Desktop screenshot", "Interaction smoke", "Product design notes"]
      refute Enum.any?(decision.artifacts, &(&1.url == "/private/tmp/symphony/mobile.png"))

      assert %{metadata: %{rejected_artifacts: [%{label: "Mobile screenshot", reason: :local_artifact_path}]}} =
               Enum.find(decision.evidence, &(&1.kind == :product_visual_review))

      assert %{artifacts: artifacts} = HandoffRoute.to_map(decision)
      assert Enum.any?(artifacts, &(&1.label == "Desktop screenshot" and &1.url == "https://artifacts.example/SID-314/desktop.png"))
      assert Enum.any?(artifacts, &(&1.label == "Interaction smoke" and &1.summary =~ "Toggled the filter"))
      refute inspect(artifacts) =~ "/private/tmp"
    after
      File.rm_rf(test_root)
    end
  end

  test "recorder derives product visual review evidence from host quality gate artifacts" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_module_ids: ["product_visual_review"],
      workflow_modules_product_visual_review: %{enabled: true, route_policy: "auto"}
    )

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-visual-host-quality-gate-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib/example_web/live"))
      File.write!(Path.join([workspace, "lib/example_web/live/dashboard_live.ex"]), "defmodule DashboardLive, do: nil\n")

      decision =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "all", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "changed_files" => ["lib/example_web/live/dashboard_live.ex"],
            "quality_gate" => %{
              "status" => "passed",
              "final_jobs" => [
                %{
                  "category" => "product_visual_review",
                  "status" => "passed",
                  "host_visual_qa" => %{
                    "status" => "passed",
                    "summary" => "Host visual QA captured desktop and mobile.",
                    "checks" => [%{"name" => "viewport_screenshots", "status" => "passed"}],
                    "artifacts" => [
                      %{
                        "kind" => "screenshot",
                        "label" => "Desktop screenshot",
                        "summary" => "Desktop screenshot captured.",
                        "metadata" => %{"path" => "/tmp/symphony/desktop.png"}
                      }
                    ],
                    "artifact_dir" => "/tmp/symphony"
                  }
                }
              ]
            }
          },
          nil,
          workspace
        )

      assert decision.route == :product_visual_review
      assert Enum.map(decision.artifacts, & &1.label) == ["Desktop screenshot"]
      assert hd(decision.artifacts).metadata == %{}

      assert %{kind: :product_visual_review, status: :passed, summary: summary} =
               Enum.find(decision.evidence, &(&1.kind == :product_visual_review))

      assert summary =~ "Host visual QA captured desktop and mobile"
      refute inspect(HandoffRoute.to_map(decision)) =~ "/tmp/symphony"
    after
      File.rm_rf(test_root)
    end
  end

  test "recorder derives host quality gate visual evidence from job summary and mixed artifacts" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_module_ids: ["product_visual_review"],
      workflow_modules_product_visual_review: %{enabled: true, route_policy: "auto"}
    )

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-visual-host-quality-gate-fallbacks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib/example_web/live"))
      File.write!(Path.join([workspace, "lib/example_web/live/dashboard_live.ex"]), "defmodule DashboardLive, do: nil\n")

      decision =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "all", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "changed_files" => ["lib/example_web/live/dashboard_live.ex"],
            "quality_gate" => %{
              "status" => "passed",
              "final_jobs" => [
                %{"category" => nil},
                %{
                  "category" => "product_visual_review",
                  "status" => "passed",
                  "summary" => "Job summary supplied host visual QA evidence.",
                  "host_visual_qa" => %{
                    "status" => "passed",
                    "summary" => " ",
                    "artifacts" => [
                      "raw artifact note",
                      %{
                        "kind" => "note",
                        "label" => "Manual note",
                        "summary" => "Operator attached manual note.",
                        "metadata" => "not a metadata map"
                      }
                    ]
                  }
                }
              ]
            }
          },
          nil,
          workspace
        )

      assert decision.route == :product_visual_review

      assert %{kind: :product_visual_review, status: :passed, summary: summary} =
               Enum.find(decision.evidence, &(&1.kind == :product_visual_review))

      assert summary =~ "Job summary supplied host visual QA evidence"
    after
      File.rm_rf(test_root)
    end
  end

  test "recorder derives blocked product visual review evidence from host quality gate blockers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_module_ids: ["product_visual_review"],
      workflow_modules_product_visual_review: %{enabled: true, route_policy: "auto"}
    )

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-visual-host-quality-gate-blocked-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib/example_web/live"))
      File.write!(Path.join([workspace, "lib/example_web/live/dashboard_live.ex"]), "defmodule DashboardLive, do: nil\n")

      decision =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "all", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "changed_files" => ["lib/example_web/live/dashboard_live.ex"],
            "quality_gate" => %{
              "status" => "blocked",
              "final_jobs" => [
                "not a job",
                %{"category" => nil},
                %{"category" => 123},
                %{"category" => "product_visual_review", "status" => "passed"},
                %{
                  "category" => "product_visual_review",
                  "status" => "blocked",
                  "summary" => "Job summary says host visual QA infrastructure failed.",
                  "blocked_reason" => "host_visual_qa command failed after browser capture timed out"
                }
              ]
            }
          },
          nil,
          workspace
        )

      assert decision.route == :blocked

      assert %{kind: :product_visual_review, status: :blocked, summary: summary} =
               Enum.find(decision.evidence, &(&1.kind == :product_visual_review))

      assert summary =~ "Job summary says host visual QA infrastructure failed"

      reason_only_decision =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "all", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "changed_files" => ["lib/example_web/live/dashboard_live.ex"],
            "quality_gate" => %{
              "status" => "blocked",
              "final_jobs" => [
                %{
                  "category" => "product_visual_review",
                  "status" => nil,
                  "blocked_reason" => "host_visual_qa skipped without a status"
                },
                %{
                  "category" => "product_visual_review",
                  "status" => "blocked",
                  "blocked_reason" => "host_visual_qa command failed without a job summary"
                }
              ]
            }
          },
          nil,
          workspace
        )

      assert reason_only_decision.route == :blocked

      assert %{kind: :product_visual_review, status: :blocked, summary: reason_only_summary} =
               Enum.find(reason_only_decision.evidence, &(&1.kind == :product_visual_review))

      assert reason_only_summary =~ "host_visual_qa command failed without a job summary"
    after
      File.rm_rf(test_root)
    end
  end

  test "missing required visual capture tooling routes as structured blocked evidence" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_module_ids: ["product_visual_review"],
      workflow_modules_product_visual_review: %{enabled: true, route_policy: "auto"}
    )

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-visual-blocked-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib/example_web/live"))
      File.write!(Path.join([workspace, "lib/example_web/live/dashboard_live.ex"]), "defmodule DashboardLive, do: nil\n")

      decision =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "all", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "changed_files" => ["lib/example_web/live/dashboard_live.ex"],
            "product_visual_review" => %{
              "status" => "blocked",
              "reason" => "Browser capture tooling is unavailable.",
              "required_action" => "Attach desktop and mobile screenshots before handoff."
            }
          },
          nil,
          workspace
        )

      assert decision.route == :blocked
      assert decision.recommendation == "Attach desktop and mobile screenshots before handoff."

      assert %{kind: :product_visual_review, status: :blocked, summary: summary} =
               Enum.find(decision.evidence, &(&1.kind == :product_visual_review))

      assert summary =~ "Browser capture tooling is unavailable"
    after
      File.rm_rf(test_root)
    end
  end

  test "product visual review evidence handles missing recommended review and local-only artifacts" do
    recommended =
      HandoffRoute.classify(%{
        checks: [%{name: "all", status: :passed}],
        review: %{status: :clean},
        product_visual_review: %{
          requirement: "recommended",
          status: "missing",
          reason: "issue labels indicate product-facing work",
          checks: "not a list"
        }
      })

    assert recommended.route == :product_visual_review

    assert %{kind: :product_visual_review, status: :missing, summary: summary} =
             Enum.find(recommended.evidence, &(&1.kind == :product_visual_review))

    assert summary =~ "issue labels indicate product-facing work"

    blocked =
      HandoffRoute.classify(%{
        checks: [%{name: "all", status: :passed}],
        review: %{status: :clean},
        product_visual_review: %{
          requirement: :required,
          status: :passed,
          artifacts: [
            %{kind: :screenshot, label: "Desktop screenshot", url: "file:///tmp/symphony/desktop.png"}
          ]
        }
      })

    assert blocked.route == :blocked
    assert blocked.artifacts == []

    assert %{metadata: %{rejected_artifacts: [%{label: "Desktop screenshot", reason: :local_artifact_path}]}} =
             Enum.find(blocked.evidence, &(&1.kind == :product_visual_review))

    malformed =
      HandoffRoute.classify(%{
        checks: [%{name: "all", status: :passed}],
        review: %{status: :clean},
        product_visual_review: "not a map",
        artifacts: [
          "Manual artifact note",
          %{kind: :artifact, label: "Reference without URL"},
          %{kind: :artifact, label: "Blank URL reference", url: " "},
          %{kind: :screenshot, label: "Local artifact", url: "/tmp/symphony/local.png"},
          nil
        ]
      })

    assert malformed.route == :human_review
    assert Enum.map(malformed.artifacts, & &1.summary) == ["Manual artifact note", nil, nil]
  end

  test "product visual review evidence normalizes malformed payloads conservatively" do
    skipped_required =
      ProductVisualReviewEvidence.normalize(%{
        requirement: :required,
        status: :skipped,
        reason: "agent skipped required visual QA",
        artifacts: "not a list",
        expected_checks: 123
      })

    assert skipped_required.status == :blocked
    assert skipped_required.artifacts == []
    assert skipped_required.expected_checks == []

    assert %{
             reason: "Product visual review required blocked: agent skipped required visual QA.",
             required_action: "Run product visual QA or attach structured desktop/mobile evidence before handoff."
           } = ProductVisualReviewEvidence.blocker(skipped_required)

    unknown_required = ProductVisualReviewEvidence.normalize(%{requirement: "required", status: "unknown"})
    assert unknown_required.status == :blocked

    rejected_blocked =
      ProductVisualReviewEvidence.normalize(%{
        requirement: "required",
        status: "blocked",
        artifacts: [
          %{kind: :screenshot, label: "Local screenshot", reference: "/tmp/local.png"}
        ]
      })

    assert rejected_blocked.status == :blocked
    assert rejected_blocked.rejected_artifacts == [%{kind: :screenshot, label: "Local screenshot", reason: :local_artifact_path}]

    passed_by_check =
      ProductVisualReviewEvidence.normalize(%{
        requirement: "required",
        status: "passed",
        checks: [
          %{name: "viewport_screenshots", status: "ok", summary: 42, metadata: "not a map"}
        ]
      })

    assert passed_by_check.status == :passed
    assert [%{status: :passed, summary: "42", metadata: %{}}] = passed_by_check.checks

    malformed =
      ProductVisualReviewEvidence.normalize(%{
        :requirement => 123,
        :status => 123,
        :reason => " ",
        :matched_files => 123,
        :checks => [123],
        :artifacts => [
          "Manual note",
          "",
          %{kind: 123, label: "Reference without URL", metadata: "not a map"},
          %{kind: :artifact, label: "Blank URL reference", url: " "}
        ],
        123 => "ignored"
      })

    assert malformed.requirement == :skip
    assert malformed.status == :unknown
    assert malformed.reason == nil
    assert malformed.matched_files == []
    assert ProductVisualReviewEvidence.artifacts(%{artifacts: "not a list"}) == []
    assert ProductVisualReviewEvidence.artifacts(malformed) |> Enum.map(& &1.summary) == ["Manual note", nil, nil]
    assert malformed.rejected_artifacts == [%{kind: :artifact, label: "artifact", reason: :invalid_artifact}]

    assert [%{summary: generic_summary}] =
             ProductVisualReviewEvidence.evidence(%{
               malformed
               | status: :passed,
                 requirement: :recommended,
                 reason: nil
             })

    assert generic_summary == "Product visual review recommended passed: evidence recorded."
    assert ProductVisualReviewEvidence.evidence(nil) == []
    assert ProductVisualReviewEvidence.blocker(%{requirement: :recommended, status: :missing}) == nil
  end

  test "product visual review rejects non-durable absolute artifact references" do
    blocked =
      HandoffRoute.classify(%{
        checks: [%{name: "all", status: :passed}],
        review: %{status: :clean},
        product_visual_review: %{
          requirement: :required,
          status: :passed,
          artifacts: [
            %{kind: :screenshot, label: "Workspace screenshot", url: "/workspace/SID-314/desktop.png"},
            %{kind: :screenshot, label: "Repo screenshot", url: "/repo/screenshots/mobile.png"},
            %{kind: :screenshot, label: "Durable screenshot", url: "https://artifacts.example/SID-314/desktop.png"}
          ]
        }
      })

    assert blocked.route == :product_visual_review
    assert Enum.map(blocked.artifacts, & &1.label) == ["Durable screenshot"]
    refute inspect(HandoffRoute.to_map(blocked)) =~ "/workspace"
    refute inspect(HandoffRoute.to_map(blocked)) =~ "/repo/screenshots"

    assert %{metadata: %{rejected_artifacts: rejected_artifacts}} =
             Enum.find(blocked.evidence, &(&1.kind == :product_visual_review))

    assert Enum.map(rejected_artifacts, & &1.label) == ["Workspace screenshot", "Repo screenshot"]
  end

  test "recorder classify_completion public arities preserve default routing behavior" do
    completion = %{"checks" => [%{"name" => "all", "status" => "passed"}], "review" => %{"status" => "clean"}}
    blocker = %{reason: "Missing token", required_action: "Restore token."}

    assert HandoffRouteRecorder.classify_completion(completion).route == :rework
    assert HandoffRouteRecorder.classify_completion(%{}, blocker).route == :blocked
    assert HandoffRouteRecorder.classify_completion(completion, nil, nil).route == :rework
    assert HandoffRouteRecorder.classify_completion(completion, nil, nil, "worker-a").route == :rework

    assert HandoffRouteRecorder.classify_completion(
             completion,
             nil,
             nil,
             nil,
             %{policy: %{auto_land: %{enabled: false}}}
           ).route == :rework
  end

  test "top-level product artifacts reject local paths while preserving durable links" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "all", status: :passed}],
        review: %{status: :clean},
        artifacts: [
          %{kind: :screenshot, label: "Local screenshot", url: "/tmp/symphony/local.png"},
          %{kind: :screenshot, label: "Durable screenshot", url: "https://artifacts.example/SID-314/desktop.png"}
        ]
      })

    assert decision.route == :product_visual_review
    assert Enum.map(decision.artifacts, & &1.label) == ["Durable screenshot"]
    refute inspect(HandoffRoute.to_map(decision)) =~ "/tmp/symphony"
  end

  test "handoff route classifies malformed product visual review payloads conservatively" do
    assert ProductVisualReviewEvidence.artifacts("not normalized evidence") == []

    skipped =
      HandoffRoute.classify(%{
        checks: [%{name: "all", status: :passed}],
        review: %{status: :clean},
        product_visual_review: %{requirement: :required, status: :skipped, reason: "agent skipped visual QA"}
      })

    assert skipped.route == :blocked

    required_unknown =
      HandoffRoute.classify(%{
        checks: [%{name: "all", status: :passed}],
        review: %{status: :clean},
        product_visual_review: %{requirement: :required, status: "unknown", artifacts: "not a list"}
      })

    assert required_unknown.route == :blocked

    blocked_with_rejection =
      HandoffRoute.classify(%{
        checks: [%{name: "all", status: :passed}],
        review: %{status: :clean},
        product_visual_review: %{
          requirement: :required,
          status: :blocked,
          artifacts: [%{kind: :screenshot, label: "Local capture", url: "/tmp/local.png"}]
        }
      })

    assert blocked_with_rejection.route == :blocked

    assert %{metadata: %{rejected_artifacts: [%{label: "Local capture", reason: :local_artifact_path}]}} =
             Enum.find(blocked_with_rejection.evidence, &(&1.kind == :product_visual_review))

    unknown =
      HandoffRoute.classify(%{
        checks: [%{name: "all", status: :passed}],
        review: %{status: :clean},
        product_visual_review: %{
          123 => "ignored",
          requirement: 123,
          status: 123,
          reason: " ",
          expected_checks: "not a list",
          artifacts: [
            "",
            "Manual note",
            %{kind: 123, label: "Blank URL", url: " ", metadata: "not a map"}
          ],
          checks: [%{name: "viewport_screenshots", status: "passed", metadata: "not a map"}]
        }
      })

    assert unknown.route == :human_review
    assert Enum.map(unknown.artifacts, & &1.summary) == ["Manual note", nil]

    assert %{metadata: %{expected_checks: [], rejected_artifacts: [%{reason: :invalid_artifact}]}} =
             Enum.find(unknown.evidence, &(&1.kind == :product_visual_review))
  end

  test "recorder uses run-resolved product visual review config from routing context" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_module_ids: ["product_visual_review"],
      workflow_modules_product_visual_review: %{enabled: true, route_policy: "off"}
    )

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-visual-run-config-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib/example_web/live"))
      File.write!(Path.join([workspace, "lib/example_web/live/dashboard_live.ex"]), "defmodule DashboardLive, do: nil\n")

      decision =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "all", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "changed_files" => ["lib/example_web/live/dashboard_live.ex"]
          },
          nil,
          workspace,
          nil,
          %{
            workflow_module_resolution: %{
              modules: [
                %{
                  id: "product_visual_review",
                  version: "v1",
                  config: %{
                    "workflow_modules" => %{
                      "product_visual_review" => %{"enabled" => true, "route_policy" => "required"}
                    }
                  }
                }
              ]
            }
          }
        )

      assert decision.route == :blocked

      assert %{kind: :product_visual_review, status: :blocked, metadata: %{route_policy: "required"}} =
               Enum.find(decision.evidence, &(&1.kind == :product_visual_review))
    after
      File.rm_rf(test_root)
    end
  end

  test "recorder supports explicit and nested visual review config sources" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-visual-config-sources-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib/example_web/live"))
      File.write!(Path.join([workspace, "lib/example_web/live/dashboard_live.ex"]), "defmodule DashboardLive, do: nil\n")

      completion = %{
        "checks" => [%{"name" => "all", "status" => "passed"}],
        "review" => %{"status" => "clean"},
        "changed_files" => ["lib/example_web/live/dashboard_live.ex"]
      }

      explicit_struct =
        HandoffRouteRecorder.classify_completion(
          completion,
          nil,
          workspace,
          nil,
          %{product_visual_review_config: %ProductVisualReviewConfig{enabled: true, route_policy: "required"}}
        )

      nested_map =
        HandoffRouteRecorder.classify_completion(
          completion,
          nil,
          workspace,
          nil,
          %{
            product_visual_review_config: %{
              "workflow_modules" => %{
                "product_visual_review" => %{"enabled" => true, "route_policy" => "required"}
              }
            }
          }
        )

      string_key_resolution =
        HandoffRouteRecorder.classify_completion(
          completion,
          nil,
          workspace,
          nil,
          %{
            "workflow_module_resolution" => %{
              "modules" => [
                %{
                  "id" => "product_visual_review",
                  "config" => %{"enabled" => true, "route_policy" => "required"}
                }
              ]
            }
          }
        )

      for decision <- [explicit_struct, nested_map, string_key_resolution] do
        assert decision.route == :blocked

        assert %{kind: :product_visual_review, status: :blocked, metadata: %{route_policy: "required"}} =
                 Enum.find(decision.evidence, &(&1.kind == :product_visual_review))
      end

      invalid_resolution =
        HandoffRouteRecorder.classify_completion(
          completion,
          nil,
          workspace,
          nil,
          %{
            workflow_module_resolution: %{
              modules: [
                %{id: "product_visual_review", config: %{"route_policy" => "invalid"}},
                123
              ]
            }
          }
        )

      malformed_resolution =
        HandoffRouteRecorder.classify_completion(
          completion,
          nil,
          workspace,
          nil,
          %{workflow_module_resolution: %{"modules" => "not a list"}}
        )

      for decision <- [invalid_resolution, malformed_resolution] do
        assert decision.route == :human_review
        refute Enum.any?(decision.evidence, &(&1.kind == :product_visual_review))
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "recorder treats run module snapshot without product visual review as disabled" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workflow_module_ids: ["product_visual_review"],
      workflow_modules_product_visual_review: %{enabled: true, route_policy: "required"}
    )

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-visual-no-run-module-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib/example_web/live"))
      File.write!(Path.join([workspace, "lib/example_web/live/dashboard_live.ex"]), "defmodule DashboardLive, do: nil\n")

      decision =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "all", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "changed_files" => ["lib/example_web/live/dashboard_live.ex"]
          },
          nil,
          workspace,
          nil,
          %{
            workflow_module_resolution: %{
              modules: [
                %{id: "repo.docs", version: "v1", config: %{}}
              ]
            }
          }
        )

      refute decision.route in [:blocked, :product_visual_review]
      refute Enum.any?(decision.evidence, &(&1.kind == :product_visual_review))
    after
      File.rm_rf(test_root)
    end
  end

  test "handoff comment renders artifact notes and empty artifact details" do
    body =
      HandoffRoute.format_comment(%HandoffRoute.Decision{
        route: :human_review,
        target_state: "Human Review",
        summary: "Manual review.",
        recommendation: "Review evidence.",
        evidence: [],
        options: [],
        artifacts: [
          %HandoffRoute.Artifact{kind: :interaction_notes, label: "Interaction smoke", summary: "Menu toggled."},
          %HandoffRoute.Artifact{kind: :artifact, label: "Reference without URL"}
        ]
      })

    assert body =~ "interaction_notes Interaction smoke: Menu toggled."
    assert body =~ "artifact Reference without URL: recorded"
  end

  test "normalizes malformed optional route input conservatively" do
    blocked =
      HandoffRoute.classify(%{
        "checks" => "not a list",
        "review" => "not a map",
        "changed_surfaces" => "not a list",
        "artifacts" => "not a list",
        "decision" => "not a map",
        "policy" => "not a map",
        "blocker" => "Operator input required"
      })

    assert blocked.route == :blocked
    assert blocked.recommendation =~ "Resolve the blocker"
    assert Enum.any?(blocked.evidence, &(&1.kind == :check and &1.status == :missing))

    conservative =
      HandoffRoute.classify(%{
        checks: [%{"name" => "custom gate", "status" => 12, 42 => "ignored"}],
        review: %{status: :commented},
        changed_surfaces: ["unknown surface"],
        policy: %{auto_land: true},
        decision: %{options: "not a list"},
        labels: "not a list"
      })

    assert conservative.route == :human_review
    assert Enum.any?(conservative.evidence, &(&1.summary == "Review status: commented"))
  end

  test "renders empty optional handoff sections" do
    body =
      HandoffRoute.format_comment(%HandoffRoute.Decision{
        route: :human_review,
        target_state: "Human Review",
        summary: "Manual review.",
        recommendation: "Review evidence.",
        evidence: [],
        options: [],
        artifacts: []
      })

    assert body =~ "#### Options\n\n- None."
    assert body =~ "#### Evidence\n\n- None."
    assert body =~ "#### Artifacts\n\n- None."
  end

  test "recorder classifies completion metadata before tracker writes" do
    assert HandoffRouteRecorder.completion_metadata?(%{"checks" => []})
    assert HandoffRouteRecorder.completion_metadata?(%{"publish_preflight" => %{}})
    assert HandoffRouteRecorder.completion_metadata?(%{"changed_files" => []})
    refute HandoffRouteRecorder.completion_metadata?(%{"ignored" => true})
    refute HandoffRouteRecorder.completion_metadata?("not completion metadata")

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-completion-metadata-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join([workspace, "lib", "view.ex"]), "defmodule View, do: nil\n")

      decision =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "mix test", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "changed_surfaces" => ["visual_design"],
            "changed_files" => ["lib/view.ex"]
          },
          nil,
          workspace
        )

      assert decision.route == :product_visual_review
    after
      File.rm_rf(test_root)
    end

    malformed = HandoffRouteRecorder.classify_completion("not completion metadata")

    assert malformed.route == :human_review
    assert Enum.any?(malformed.evidence, &(&1.kind == :check and &1.status == :missing))
  end

  test "recorder prefers host policy and labels over completion-owned route policy" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-host-policy-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join([workspace, "lib", "safe.ex"]), "defmodule Safe, do: nil\n")

      completion_claims_real_land = %{
        checks: auto_land_checks(),
        pr_feedback: clean_pr_feedback(),
        review: %{status: :clean},
        changed_surfaces: [:docs],
        changed_files: ["lib/safe.ex"],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "none"},
          auto_land: %{posture: "permissive", dry_run: false}
        }
      }

      host_dry_run =
        HandoffRouteRecorder.classify_completion(
          completion_claims_real_land,
          nil,
          workspace,
          nil,
          %{
            policy: %{
              project: %{criticality: "prototype", deployment_coupling: "none"},
              auto_land: %{posture: "permissive", dry_run: true}
            },
            labels: []
          }
        )

      host_force_review_label =
        HandoffRouteRecorder.classify_completion(
          completion_claims_real_land,
          nil,
          workspace,
          nil,
          %{
            policy: %{
              project: %{criticality: "prototype", deployment_coupling: "none"},
              auto_land: %{posture: "permissive", dry_run: false}
            },
            labels: ["no-auto-land"]
          }
        )

      assert host_dry_run.route == :auto_land
      assert host_dry_run.target_state == "Human Review"
      assert host_force_review_label.route == :human_review
      assert host_force_review_label.target_state == "Human Review"

      keyword_context_force_review_label =
        HandoffRouteRecorder.classify_completion(
          completion_claims_real_land,
          nil,
          workspace,
          nil,
          policy: %{
            project: %{criticality: "prototype", deployment_coupling: "none"},
            auto_land: %{posture: "permissive", dry_run: false}
          },
          labels: ["no-auto-land"]
        )

      invalid_context_uses_completion_policy =
        HandoffRouteRecorder.classify_completion(
          completion_claims_real_land,
          nil,
          workspace,
          nil,
          "not routing context"
        )

      camel_feedback_completion =
        completion_claims_real_land
        |> Map.delete(:pr_feedback)
        |> Map.put("prFeedback", clean_pr_feedback())

      camel_feedback =
        HandoffRouteRecorder.classify_completion(
          camel_feedback_completion,
          nil,
          workspace,
          nil,
          %{
            policy: %{
              project: %{criticality: "prototype", deployment_coupling: "none"},
              auto_land: %{posture: "permissive", dry_run: false}
            },
            labels: []
          }
        )

      assert keyword_context_force_review_label.route == :human_review
      assert keyword_context_force_review_label.target_state == "Human Review"
      assert invalid_context_uses_completion_policy.route == :auto_land
      assert invalid_context_uses_completion_policy.target_state == "Merging"
      assert camel_feedback.route == :auto_land
      assert camel_feedback.target_state == "Merging"
    after
      File.rm_rf(test_root)
    end
  end

  test "publish preflight failures route as structured blockers" do
    decision =
      HandoffRouteRecorder.classify_completion(%{
        "checks" => [%{"name" => "tests", "status" => "passed"}],
        "publish_preflight" => %{
          "status" => "blocked",
          "repository" => "https://github.com/example/project",
          "base_branch" => "main",
          "capabilities" => %{
            "workspace_vcs_metadata" => true,
            "remote_push" => false,
            "pr_creation" => true
          },
          "failures" => [
            %{
              "class" => "remote_push_unavailable",
              "summary" => "Remote push dry-run failed."
            }
          ]
        }
      })

    assert decision.route == :blocked
    assert decision.target_state == "Human Review"
    assert decision.recommendation =~ "Authenticate GitHub CLI/API access"

    assert Enum.any?(
             decision.evidence,
             &publish_preflight_remote_push_failure?/1
           )

    assert %{evidence: evidence} = HandoffRoute.to_map(decision)

    assert Enum.any?(
             evidence,
             &(&1.kind == "publish_preflight" and &1.metadata.failure_class == :remote_push_unavailable and
                 &1.metadata.reason == :github_publish_unavailable)
           )
  end

  test "legacy publish preflight classes map to specific capability reasons" do
    decision =
      HandoffRouteRecorder.classify_completion(%{
        checks: [%{name: "tests", status: :passed}],
        publish_preflight: %{
          status: :blocked,
          repository: "https://github.com/example/project",
          base_branch: "main",
          failures: [
            %{class: :workspace_vcs_metadata_unavailable, summary: "Git metadata unavailable."},
            %{class: :pr_creation_unavailable, summary: "PR creation unavailable."}
          ]
        }
      })

    assert decision.route == :blocked
    assert decision.recommendation =~ "write Git metadata"

    assert Enum.any?(
             decision.evidence,
             &(&1.kind == :publish_preflight and &1.metadata.reason == :git_metadata_denied)
           )

    assert Enum.any?(
             decision.evidence,
             &(&1.kind == :publish_preflight and &1.metadata.reason == :github_publish_unavailable)
           )
  end

  test "capability preflight blocker surfaces all missing capability reasons" do
    decision =
      HandoffRouteRecorder.classify_completion(%{}, %{
        reason: "sandbox_tcp_denied, git_metadata_denied, github_publish_unavailable",
        required_action:
          "Run trusted-local validation with localhost TCP enabled. Run trusted-local validation or host-owned delivery with permission to write Git metadata. Authenticate GitHub CLI/API access and remote publish permission."
      })

    assert decision.route == :blocked
    assert decision.target_state == "Human Review"
    assert decision.recommendation =~ "localhost TCP"
    assert decision.recommendation =~ "GitHub"

    assert Enum.any?(
             decision.evidence,
             &(&1.kind == :blocker and &1.summary =~ "sandbox_tcp_denied" and
                 &1.summary =~ "git_metadata_denied" and &1.summary =~ "github_publish_unavailable")
           )
  end

  test "publish preflight passed evidence does not block handoff" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-publish-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join([workspace, "lib", "safe.ex"]), "defmodule Safe, do: nil\n")

      decision =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "tests", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "changed_files" => ["lib/safe.ex"],
            "publish_preflight" => %{
              "repository" => "https://github.com/example/project",
              "base_branch" => "main",
              "capabilities" => %{
                "workspace_vcs_metadata" => true,
                "remote_push" => true,
                "pr_creation" => true
              },
              "failures" => []
            }
          },
          nil,
          workspace
        )

      assert decision.route == :human_review

      assert Enum.any?(
               decision.evidence,
               &(&1.kind == :publish_preflight and &1.status == :passed and &1.summary =~ "main")
             )
    after
      File.rm_rf(test_root)
    end
  end

  test "normalizes malformed publish preflight metadata conservatively" do
    malformed = HandoffRoute.classify(%{publish_preflight: "not a map"})
    assert malformed.route == :human_review
    refute Enum.any?(malformed.evidence, &(&1.kind == :publish_preflight))

    no_failures =
      HandoffRoute.classify(%{
        checks: [%{name: "tests", status: :passed}],
        publish_preflight: %{
          failures: "not a list",
          capabilities: %{},
          repository: "https://github.com/example/project",
          base_branch: "main"
        }
      })

    assert Enum.any?(no_failures.evidence, &(&1.kind == :publish_preflight and &1.status == :passed))

    invalid_failures =
      HandoffRoute.classify(%{
        checks: [%{name: "tests", status: :passed}],
        publish_preflight: %{
          failures: [%{}, "not a map"],
          capabilities: %{},
          repository: "https://github.com/example/project",
          base_branch: "main"
        }
      })

    assert Enum.any?(invalid_failures.evidence, &(&1.kind == :publish_preflight and &1.status == :passed))

    malformed_fields =
      HandoffRoute.classify(%{
        publish_preflight: %{
          123 => "ignored",
          status: 123,
          repository: " ",
          base_branch: 123,
          capabilities: "not a map",
          failures: [
            %{
              456 => "ignored",
              class: 123,
              summary: "Publish preflight failed.",
              command: 42,
              details: %{}
            },
            "not a map"
          ]
        }
      })

    assert malformed_fields.route == :blocked

    assert [
             %{
               kind: :publish_preflight,
               status: :blocked,
               metadata: %{
                 repository: nil,
                 base_branch: nil,
                 capabilities: %{
                   workspace_vcs_metadata: false,
                   remote_push: false,
                   pr_creation: false
                 },
                 failure_class: :unknown,
                 command: "42",
                 details: nil
               }
             }
           ] = Enum.filter(malformed_fields.evidence, &(&1.kind == :publish_preflight))
  end

  test "recorder fails closed when completion metadata omits or malforms the manifest" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-malformed-manifest-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      missing =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "mix test", "status" => "passed"}],
            "review" => %{"status" => "clean"}
          },
          nil,
          workspace
        )

      assert missing.route == :rework
      assert manifest_failure_reason?(missing, :missing_changed_files)

      malformed =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "mix test", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "change_manifest" => []
          },
          nil,
          workspace
        )

      assert malformed.route == :rework
      assert manifest_failure_reason?(malformed, :invalid_manifest)

      duplicate_alias =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "mix test", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "changed_files" => ["lib/safe.ex"],
            "files" => ["../do-not-persist.env"]
          },
          nil,
          workspace
        )

      assert duplicate_alias.route == :rework
      assert manifest_failure_reason?(duplicate_alias, :duplicate_changed_file_aliases)

      duplicate_manifest_alias =
        HandoffRouteRecorder.classify_completion(
          %{
            :change_manifest => %{"changed_files" => ["lib/safe.ex"]},
            "change_manifest" => %{"changed_files" => ["lib/safe.ex"]},
            "checks" => [%{"name" => "mix test", "status" => "passed"}],
            "review" => %{"status" => "clean"}
          },
          nil,
          workspace
        )

      assert duplicate_manifest_alias.route == :rework
      assert manifest_failure_reason?(duplicate_manifest_alias, :duplicate_change_manifest_aliases)

      conflicting_sources =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "mix test", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "change_manifest" => %{"changed_files" => ["lib/safe.ex"]},
            "changed_files" => ["../do-not-persist.env"]
          },
          nil,
          workspace
        )

      assert conflicting_sources.route == :rework
      assert manifest_failure_reason?(conflicting_sources, :conflicting_manifest_sources)

      comment = HandoffRoute.format_comment(conflicting_sources)
      refute comment =~ "do-not-persist"
    after
      File.rm_rf(test_root)
    end
  end

  test "recorder blocks handoff when changed-file manifest validation fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-manifest-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      decision =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "mix test", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "changed_surfaces" => ["docs"],
            "changed_files" => ["../.env"]
          },
          nil,
          workspace
        )

      assert decision.route == :rework
      assert decision.target_state == "Rework"

      assert Enum.any?(decision.evidence, fn evidence ->
               evidence.kind == :check and evidence.status == :failed and
                 evidence.summary =~ "Changed-file manifest rejected" and
                 match?(
                   [%{reason: :path_traversal, path: "../.env"}],
                   evidence.metadata.failures
                 )
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "recorder validates nested change manifests and rejects missing workspace context" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-route-nested-manifest-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join([workspace, "lib", "nested.ex"]), "defmodule Nested, do: nil\n")

      valid =
        HandoffRouteRecorder.classify_completion(
          %{
            "checks" => [%{"name" => "mix test", "status" => "passed"}],
            "review" => %{"status" => "clean"},
            "change_manifest" => %{
              "changed_files" => ["lib/nested.ex"],
              "validation" => [%{"name" => "mix test", "status" => "passed"}]
            }
          },
          nil,
          workspace
        )

      assert valid.route == :human_review
      assert Enum.any?(valid.evidence, &(&1.kind == :check and &1.summary =~ "change_manifest"))

      assert Enum.any?(valid.evidence, fn evidence ->
               evidence.kind == :check and
                 evidence.metadata == %{
                   changed_files: ["lib/nested.ex"],
                   validation: [%{"name" => "mix test", "status" => "passed"}]
                 }
             end)

      missing_workspace =
        HandoffRouteRecorder.classify_completion(%{
          "changed_files" => ["lib/nested.ex"],
          "checks" => [%{"name" => "mix test", "status" => "passed"}],
          "review" => %{"status" => "clean"}
        })

      assert missing_workspace.route == :rework

      assert Enum.any?(missing_workspace.evidence, fn evidence ->
               evidence.kind == :check and evidence.status == :failed and
                 match?([%{reason: :missing_workspace}], evidence.metadata.failures)
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "recorder fails closed for remote workspace manifests" do
    remote =
      HandoffRouteRecorder.classify_completion(
        %{
          "changed_files" => ["lib/remote.ex"],
          "checks" => [%{"name" => "mix test", "status" => "passed"}],
          "review" => %{"status" => "clean"}
        },
        nil,
        "/remote/workspace",
        "worker-a"
      )

    assert remote.route == :rework
    assert manifest_failure_reason?(remote, :remote_workspace_validation_unavailable)

    assert Enum.any?(remote.evidence, fn evidence ->
             evidence.kind == :check and
               get_in(evidence.metadata, [:failures, Access.at(0), :metadata, :worker_host]) == "worker-a"
           end)
  end

  test "recorder writes the route comment and moves the selected state" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "route gate", status: :failed, summary: "PR checks failed"}],
        review: %{status: :clean}
      })

    assert decision.route == :rework
    assert :ok = HandoffRouteRecorder.record("issue-1", decision)
    assert_receive {:memory_tracker_comment, "issue-1", comment}
    assert comment =~ "### Handoff Route"
    assert comment =~ "rework"
    assert_receive {:memory_tracker_state_update, "issue-1", "Rework"}
  end

  defp auto_land_checks(extra_checks \\ []) do
    ~w(tests quality_gates automated_review route_classification sync)
    |> Kernel.++(extra_checks)
    |> Enum.map(&%{name: &1, status: :passed})
  end

  defp permissive_real_auto_land_policy do
    %{
      project: %{criticality: "prototype", deployment_coupling: "none"},
      auto_land: %{posture: "permissive", dry_run: false}
    }
  end

  defp real_auto_land_checks(extra_checks \\ []) do
    auto_land_checks(["pr_feedback"] ++ extra_checks)
  end

  defp clean_pr_feedback(status \\ :none, default_count \\ 0, opts \\ []) do
    top_level_count = Keyword.get(opts, :top_level_count, default_count)

    %{
      status: status,
      top_level_comments: %{
        checked: true,
        source: "gh pr view --comments",
        unresolved_actionable_count: top_level_count
      },
      inline_review_comments: %{
        checked: true,
        source: "gh api repos/example/project/pulls/1/comments",
        unresolved_actionable_count: default_count
      },
      review_summaries: %{
        checked: true,
        source: "gh pr view --json reviews",
        unresolved_actionable_count: default_count
      }
    }
  end

  defp outstanding_pr_feedback do
    %{
      status: :outstanding,
      top_level_comments: %{checked: true, source: "gh pr view --comments", unresolved_actionable_count: 1},
      inline_review_comments: %{
        checked: true,
        source: "gh api repos/example/project/pulls/1/comments",
        unresolved_actionable_count: 0
      },
      review_summaries: %{checked: true, source: "gh pr view --json reviews", unresolved_actionable_count: 0}
    }
  end

  defp strict_recovery_checks do
    ~w(deployment_status rollback_plan monitoring_source incident_issue_creation)
  end

  defp replace_check(checks, name, status, summary) do
    Enum.map(checks, fn
      %{name: ^name} = check -> Map.merge(check, %{status: status, summary: summary})
      check -> check
    end)
  end

  defp publish_preflight_remote_push_failure?(evidence) do
    evidence.kind == :publish_preflight and
      evidence.status == :blocked and
      evidence.metadata.failure_class == :remote_push_unavailable
  end

  defp manifest_failure_reason?(decision, reason) do
    Enum.any?(decision.evidence, fn evidence ->
      evidence.kind == :check and evidence.status == :failed and
        Enum.any?(get_in(evidence.metadata, [:failures]) || [], &(&1.reason == reason))
    end)
  end
end
