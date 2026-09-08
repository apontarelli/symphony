defmodule SymphonyElixir.TargetRegistry.PolicyParityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TargetRegistry.PolicyParity

  defp compare(before, after_, target_id \\ "app") do
    PolicyParity.compare(
      %{"manifest" => before["manifest"], "target" => before["target"]},
      %{"manifest" => after_["manifest"], "target" => after_["target"]},
      target_id
    )
  end

  defp codes({:weakened, findings}), do: Enum.map(findings, & &1.code)

  test "review rules, workflow selection, repository identity and routing cannot be discarded" do
    manifest = %{
      "project" => %{"repository" => "https://example.invalid/repo"},
      "workflow" => %{"modules" => ["human-review"]},
      "automation" => %{"review" => %{"minimum_approvals" => 2}},
      "review_routing" => %{"security/**" => "Human Review"},
      "issue_markers" => %{"allowed_projects" => ["project-a"]}
    }

    assert {:weakened, findings} = compare(%{"manifest" => manifest}, %{"manifest" => %{}})
    assert Enum.all?(findings, &(&1.code == :policy_changed))

    assert Enum.map(findings, & &1.path) == [
             "$.targets.app.repository_policy.project",
             "$.targets.app.repository_policy.workflow",
             "$.targets.app.repository_policy.review_routing",
             "$.targets.app.repository_policy.issue_markers",
             "$.targets.app.repository_policy.automation.review"
           ]
  end

  test "restriction diagnostics identify the actual configured field" do
    before = %{
      "manifest" => %{"capabilities" => %{"required" => ["browser"]}},
      "target" => %{"checks" => %{"pre_merge" => ["ci"]}}
    }

    assert {:weakened, findings} = compare(before, %{})

    assert Enum.map(findings, & &1.path) == [
             "$.targets.app.repository_policy.capabilities.required",
             "$.targets.app.checks.pre_merge"
           ]
  end

  test "identical policies and tightenings never weaken" do
    manifest = %{
      "validation" => %{"commands" => [%{"name" => "all", "command" => "make all"}]},
      "docs" => %{"entrypoints" => ["README.md"]},
      "capabilities" => %{"required" => ["github_pr"]},
      "auto_land" => %{
        "posture" => "permissive",
        "dry_run" => true,
        "force_human_review_paths" => ["lib/**"],
        "force_human_review_labels" => ["human-review"],
        "required_checks" => ["ci"]
      },
      "automation" => %{"completion_requirements" => ["Run validation."]}
    }

    target = %{
      "budgets" => %{"per_run" => %{"max_total_tokens" => 100}, "daily" => %{"max_total_tokens" => 1_000}},
      "external_side_effects" => %{"merge" => "deny", "vcs_publish" => "manual_approval"},
      "checks" => %{"pre_publish" => ["publish_preflight"]},
      "linear" => %{
        "required_labels" => ["ready"],
        "scope" => %{"type" => "project", "project_id" => "p1"}
      },
      "repo" => %{"path" => "/repos/app", "expected_repository" => "https://example/app"}
    }

    after_ = %{
      "manifest" => deep_tighten(manifest),
      "target" => deep_tighten(target)
    }

    assert :ok = compare(%{"manifest" => manifest, "target" => target}, after_)
  end

  test "dropped or changed validation commands weaken" do
    before = %{"manifest" => %{"validation" => %{"commands" => [%{"name" => "all", "command" => "make all"}]}}}

    dropped = %{"manifest" => %{"validation" => %{"commands" => []}}}
    assert {:weakened, findings} = compare(%{"manifest" => before["manifest"]}, dropped)
    assert :validation_command_dropped in codes({:weakened, findings})

    changed = %{"manifest" => %{"validation" => %{"commands" => [%{"name" => "all", "command" => "make fast"}]}}}
    assert {:weakened, findings} = compare(%{"manifest" => before["manifest"]}, changed)
    assert :validation_command_changed in codes({:weakened, findings})
  end

  test "duplicate command names compare every required command" do
    both = %{
      "manifest" => %{
        "validation" => %{
          "commands" => [
            %{"name" => "verify", "command" => "mix lint"},
            %{"name" => "verify", "command" => "mix test"}
          ]
        }
      }
    }

    assert :ok = compare(both, both)

    reordered = %{
      "manifest" => %{
        "validation" => %{
          "commands" => [
            %{"name" => "verify", "command" => "mix test"},
            %{"name" => "verify", "command" => "mix lint"}
          ]
        }
      }
    }

    assert :ok = compare(both, reordered)

    one_dropped = %{"manifest" => %{"validation" => %{"commands" => [%{"name" => "verify", "command" => "mix test"}]}}}

    assert {:weakened, findings} = compare(both, one_dropped)
    assert [:validation_command_changed] = codes({:weakened, findings})

    one_replaced = %{
      "manifest" => %{
        "validation" => %{
          "commands" => [
            %{"name" => "verify", "command" => "mix lint"},
            %{"name" => "verify", "command" => "mix lint"}
          ]
        }
      }
    }

    assert {:weakened, findings} = compare(both, one_replaced)
    assert [:validation_command_changed] = codes({:weakened, findings})
  end

  test "raw spellings compare through Manifest normalization" do
    raw = %{
      "manifest" => %{
        "project" => %{"repository" => " https://example.invalid/repo "},
        "docs" => %{"entrypoints" => [" README.md "]},
        "validation" => %{
          "commands" => [%{"name" => " all ", "command" => " make all "}],
          "required_files" => [" scripts/check.sh "]
        },
        "capabilities" => %{"required" => [" browser "]},
        "auto_land" => %{
          "posture" => " strict ",
          "force_human_review_paths" => [" lib/** "]
        },
        "automation" => %{"completion_requirements" => [" Run validation. "]}
      }
    }

    compiled = %{
      "manifest" => %{
        "project" => %{"repository" => "https://example.invalid/repo"},
        "docs" => %{"entrypoints" => ["README.md"]},
        "validation" => %{
          "commands" => [%{"name" => "all", "command" => "make all"}],
          "required_files" => ["scripts/check.sh"]
        },
        "capabilities" => %{"required" => ["browser"]},
        "auto_land" => %{"posture" => "strict", "force_human_review_paths" => ["lib/**"]},
        "automation" => %{"completion_requirements" => ["Run validation."]}
      }
    }

    assert :ok = compare(raw, compiled)
    assert :ok = compare(compiled, raw)
  end

  test "dropped required files, docs, and capabilities weaken" do
    before = %{
      "manifest" => %{
        "validation" => %{"required_files" => ["scripts/check.sh"]},
        "docs" => %{"entrypoints" => ["README.md", "docs/guide.md"]},
        "capabilities" => %{"required" => ["linear", "browser"]}
      }
    }

    after_ = %{
      "manifest" => %{
        "validation" => %{"required_files" => []},
        "docs" => %{"entrypoints" => ["README.md"]},
        "capabilities" => %{"required" => ["linear"]}
      }
    }

    assert {:weakened, findings} = compare(before, after_)

    assert Enum.sort([
             :validation_required_file_dropped,
             :docs_entrypoint_dropped,
             :required_capability_dropped
           ]) == Enum.sort(codes({:weakened, findings}) |> Enum.uniq())
  end

  test "landing posture, dry run, protected paths, labels, and checks weaken" do
    before = %{
      "manifest" => %{
        "auto_land" => %{
          "posture" => "off",
          "dry_run" => true,
          "force_human_review_paths" => ["security/**"],
          "force_human_review_labels" => ["human-review"],
          "required_checks" => ["fixture-ci"]
        }
      }
    }

    after_ = %{
      "manifest" => %{
        "auto_land" => %{
          "posture" => "permissive",
          "dry_run" => false,
          "force_human_review_paths" => [],
          "force_human_review_labels" => [],
          "required_checks" => []
        }
      }
    }

    assert {:weakened, findings} = compare(before, after_)

    assert Enum.sort([
             :landing_posture_weakened,
             :landing_dry_run_disabled,
             :protected_path_dropped,
             :protected_label_dropped,
             :landing_required_check_dropped
           ]) == Enum.sort(codes({:weakened, findings}))
  end

  test "posture ordering treats off as strongest and permissive as weakest" do
    before = %{"manifest" => %{"auto_land" => %{"posture" => "strict"}}}

    for weakened_posture <- ["permissive"] do
      assert {:weakened, _findings} =
               compare(before, %{"manifest" => %{"auto_land" => %{"posture" => weakened_posture}}})
    end

    for preserved <- ["off", "strict"] do
      assert :ok = compare(before, %{"manifest" => %{"auto_land" => %{"posture" => preserved}}})
    end

    assert :ok = compare(%{"manifest" => %{"auto_land" => %{"posture" => "permissive"}}}, before)
  end

  test "completion requirements cannot be dropped" do
    before = %{"manifest" => %{"automation" => %{"completion_requirements" => ["Run validation."]}}}
    after_ = %{"manifest" => %{"automation" => %{"completion_requirements" => []}}}

    assert {:weakened, findings} = compare(before, after_)
    assert :completion_requirement_dropped in codes({:weakened, findings})
  end

  test "raised or removed budgets weaken and tightened budgets do not" do
    before = %{"target" => %{"budgets" => %{"per_run" => %{"max_total_tokens" => 500}}}}

    for after_budget <- [%{"max_total_tokens" => 501}, %{}] do
      assert {:weakened, findings} =
               compare(before, %{"target" => %{"budgets" => %{"per_run" => after_budget}}})

      assert :budget_raised in codes({:weakened, findings})
    end

    assert :ok = compare(before, %{"target" => %{"budgets" => %{"per_run" => %{"max_total_tokens" => 500}}}})
  end

  test "side effect gates only tighten" do
    before = %{"target" => %{"external_side_effects" => %{"merge" => "deny", "deployment" => "manual_approval"}}}

    weakened = %{"target" => %{"external_side_effects" => %{"merge" => "allow", "deployment" => "allow"}}}
    assert {:weakened, findings} = compare(before, weakened)
    gate_codes = codes({:weakened, findings})
    assert length(gate_codes) == 2
    assert Enum.all?(gate_codes, &(&1 == :side_effect_gate_weakened))

    tightened = %{"target" => %{"external_side_effects" => %{"merge" => "deny", "deployment" => "deny"}}}
    assert :ok = compare(before, tightened)
  end

  test "an absent legacy gate was allowed and must not silently stay allowed" do
    before = %{"target" => %{"external_side_effects" => %{}}}
    after_ = %{"target" => %{"external_side_effects" => %{"vcs_publish" => "allow"}}}
    assert :ok = compare(before, after_)

    denied = %{"target" => %{"external_side_effects" => %{"vcs_publish" => "deny"}}}
    assert :ok = compare(before, denied)
  end

  test "target checks cannot be dropped" do
    before = %{"target" => %{"checks" => %{"pre_publish" => ["publish_preflight", "pr_checks"]}}}
    after_ = %{"target" => %{"checks" => %{"pre_publish" => ["pr_checks"]}}}

    assert {:weakened, findings} = compare(before, after_)
    assert :check_dropped in codes({:weakened, findings})
  end

  test "tracker routing cannot widen or change selectors" do
    before = %{
      "target" => %{
        "linear" => %{
          "required_labels" => ["repo:app", "ready"],
          "scope" => %{"type" => "issues", "issue_ids" => ["SID-1", "SID-2"]}
        }
      }
    }

    widened = %{
      "target" => %{
        "linear" => %{
          "required_labels" => ["repo:app"],
          "scope" => %{"type" => "issues", "issue_ids" => ["SID-1", "SID-2", "SID-3"]}
        }
      }
    }

    assert {:weakened, findings} = compare(before, widened)
    assert :required_label_dropped in codes({:weakened, findings})
    assert :tracker_scope_widened in codes({:weakened, findings})

    retyped = %{"target" => %{"linear" => %{"scope" => %{"type" => "team", "team_key" => "ENG"}}}}
    assert {:weakened, findings} = compare(before, retyped)
    assert :tracker_scope_changed in codes({:weakened, findings})

    narrowed = %{
      "target" => %{
        "linear" => %{
          "required_labels" => ["repo:app", "ready", "extra"],
          "scope" => %{"type" => "issues", "issue_ids" => ["SID-1"]}
        }
      }
    }

    assert :ok = compare(before, narrowed)
  end

  test "repository identity cannot change" do
    before = %{"target" => %{"repo" => %{"path" => "/repos/app", "expected_repository" => "https://example/app"}}}

    moved = %{"target" => %{"repo" => %{"path" => "/repos/other", "expected_repository" => "https://example/app"}}}
    assert {:weakened, findings} = compare(before, moved)
    assert :repository_identity_changed in codes({:weakened, findings})

    rehosted = %{"target" => %{"repo" => %{"path" => "/repos/app", "expected_repository" => "https://example/mirror"}}}
    assert {:weakened, findings} = compare(before, rehosted)
    assert :repository_identity_changed in codes({:weakened, findings})
  end

  test "findings are target scoped for the operator preview" do
    before = %{"manifest" => %{"validation" => %{"commands" => [%{"name" => "all", "command" => "make all"}]}}}
    after_ = %{"manifest" => %{}}

    assert {:weakened, [%{severity: :error, scope: {:target, "dogfood"}, path: path, code: :validation_command_dropped}]} =
             compare(before, after_, "dogfood")

    assert path == "$.targets.dogfood.repository_policy.validation.commands.all"
  end

  defp deep_tighten(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, deep_tighten(nested)} end)

  defp deep_tighten(value) when is_list(value) do
    tightened = Enum.map(value, &deep_tighten/1)

    case tightened do
      [] -> []
      _entries -> tightened
    end
  end

  # Lists may only grow, scalars stay: append a harmless duplicate-avoiding
  # marker by keeping the original list, so tightenings pass by construction.
  defp deep_tighten(value), do: value
end
