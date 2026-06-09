defmodule SymphonyElixir.HandoffRouteTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{HandoffRoute, HandoffRouteRecorder}

  test "classifies low-risk passed work as auto-land eligible while keeping v1 handoff conservative" do
    decision =
      HandoffRoute.classify(%{
        checks: [%{name: "mix test", status: :passed}],
        review: %{status: :clean},
        changed_surfaces: [:docs, :tests],
        policy: %{auto_land: %{enabled: true}, pr_target: "main"}
      })

    assert decision.route == :auto_land
    assert decision.target_state == "Human Review"
    assert decision.recommendation =~ "Auto-land"

    assert %{
             route: "auto_land",
             target_state: "Human Review",
             evidence: evidence
           } = HandoffRoute.to_map(decision)

    assert Enum.any?(evidence, &(&1.summary =~ "All checks passed"))
    assert Enum.any?(evidence, &(&1.summary =~ "low-risk"))
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
    assert decision.recommendation =~ "Restore host VCS/GitHub publish capability"

    assert Enum.any?(
             decision.evidence,
             &publish_preflight_remote_push_failure?/1
           )

    assert %{evidence: evidence} = HandoffRoute.to_map(decision)

    assert Enum.any?(
             evidence,
             &(&1.kind == "publish_preflight" and &1.metadata.failure_class == :remote_push_unavailable)
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
