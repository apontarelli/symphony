defmodule SymphonyElixir.TargetRegistry.PreviewTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TargetRegistry.Diagnostic
  alias SymphonyElixir.TargetRegistry.Preview
  alias SymphonyElixir.TargetRegistry.Snapshot
  alias SymphonyElixir.TargetRegistry.Target

  test "hashes exact source bytes into deterministic proposed generations" do
    source = "version: 1\nhost: {}\ntargets: {}\n"

    assert Preview.generation(source) == Preview.generation(source)

    assert Preview.generation(source) ==
             "sha256:" <> (:crypto.hash(:sha256, source) |> Base.encode16(case: :lower))

    refute Preview.generation(source) == Preview.generation(source <> "\n")
    refute Preview.generation(source) == Preview.generation("# comment\n" <> source)
    refute Preview.generation(source) == Preview.generation(String.replace(source, "host: {}", "host:  {}"))
  end

  test "separates exact source generation from effective policy hashes" do
    current_source = "version: 1\nhost: {}\ntargets: {}\n"
    proposed_source = "# operator comment\n" <> current_source
    policy_hash = Preview.generation("effective policy")

    current =
      policy_hash
      |> snapshot()
      |> Map.merge(%{
        source_hash: Preview.generation(current_source),
        generation: Preview.generation(current_source)
      })

    proposed = snapshot(policy_hash)
    preview = Preview.preview(current, proposed, proposed_source)

    assert preview.expected_generation == Preview.generation(current_source)
    assert preview.proposed_generation == Preview.generation(proposed_source)
    assert preview.source_changed?
    assert [%{id: "main", policy_hash: ^policy_hash}] = preview.targets

    assert preview.diff == [
             %{
               path: "$.generation",
               before: Preview.generation(current_source),
               after: Preview.generation(proposed_source),
               classification: :source_difference
             }
           ]

    first_install = Preview.preview(nil, proposed, proposed_source)
    assert first_install.expected_generation == nil
    assert first_install.proposed_generation == Preview.generation(proposed_source)
  end

  test "compares source changes with source hash independently from expected generation" do
    proposed_source = "exact proposed source"
    proposed_hash = Preview.generation(proposed_source)
    loaded_hash = Preview.generation("different loaded source")
    registry_generation = Preview.generation("registry generation")
    proposed = snapshot("sha256:stable-policy")

    changed =
      Preview.preview(
        %{proposed | generation: proposed_hash, source_hash: loaded_hash},
        proposed,
        proposed_source
      )

    assert changed.expected_generation == proposed_hash
    assert changed.source_changed?

    assert changed.diff == [
             %{
               path: "$.generation",
               before: loaded_hash,
               after: proposed_hash,
               classification: :source_difference
             }
           ]

    unchanged =
      Preview.preview(
        %{proposed | generation: registry_generation, source_hash: proposed_hash},
        proposed,
        proposed_source
      )

    assert unchanged.expected_generation == registry_generation
    refute unchanged.source_changed?
    assert unchanged.diff == []

    first_install = Preview.preview(nil, proposed, proposed_source)
    assert first_install.source_changed?
    refute Enum.any?(first_install.diff, &(&1.path == "$.generation"))
  end

  test "redacts malformed public generations and fails closed on malformed validity" do
    source = "generation validation source"
    proposed_generation = Preview.generation(source)
    registry_generation = "SHA256:" <> String.duplicate("a", 64)
    loaded_source_hash = "sha256:" <> String.duplicate("A", 64)
    malformed_validity = "OpaqueValidityMaterialQ7vK2"

    current =
      snapshot(Preview.generation("stable policy"))
      |> Map.merge(%{
        generation: registry_generation,
        source_hash: loaded_source_hash
      })

    proposed = %{snapshot(Preview.generation("stable policy")) | globally_valid?: malformed_validity}
    preview = Preview.preview(current, proposed, source)

    assert preview.expected_generation == "[REDACTED]"
    assert preview.proposed_generation == proposed_generation
    assert preview.source_changed?
    assert preview.globally_valid? == false

    assert Enum.find(preview.diff, &(&1.path == "$.generation")) == %{
             path: "$.generation",
             before: "[REDACTED]",
             after: proposed_generation,
             classification: :source_difference
           }

    rendered = inspect(preview, limit: :infinity, printable_limit: :infinity)
    refute rendered =~ registry_generation
    refute rendered =~ loaded_source_hash
    refute rendered =~ malformed_validity
  end

  @tag :tmp_dir
  test "preview is a pure first-install operation with no lookup or write", %{tmp_dir: tmp_dir} do
    registry_path = Path.join(tmp_dir, "targets.yml")

    proposed =
      "sha256:policy-from-unresolved-reference"
      |> snapshot()
      |> Map.merge(%{
        path: registry_path,
        host: %{
          "tracker_connections" => %{
            "linear" => %{"api_key" => "$PREVIEW_ENV_VALUE"}
          }
        }
      })

    source = "version: 1\nhost:\n  tracker_connections: {}\ntargets: {}\n"
    original = :erlang.term_to_binary(proposed, [:deterministic])
    process_state = Process.get()

    preview = Preview.preview(proposed, source)

    assert preview.expected_generation == nil
    assert preview.proposed_generation == Preview.generation(source)
    assert :erlang.term_to_binary(proposed, [:deterministic]) == original
    assert Process.get() == process_state
    refute File.exists?(registry_path)
    assert File.ls!(tmp_dir) == []
  end

  test "diffs host and target snapshots with lexicographic JSON-style paths" do
    source = "same deterministic proposed bytes"
    current_target = snapshot("sha256:old-policy").targets["main"]
    proposed_target = snapshot("sha256:new-policy").targets["main"]

    current =
      "sha256:old-policy"
      |> snapshot()
      |> Map.merge(%{
        generation: Preview.generation(source),
        host: %{
          "capacity" => %{"max_concurrent_agents" => 2},
          "polling" => %{"interval_ms" => 1_000}
        },
        targets: %{
          "main" => %{
            current_target
            | configured: %{
                "state" => "paused",
                "dispatch_mode" => "explicit",
                "display_name" => "Old",
                "repo" => %{},
                "scheduling" => %{"weight" => 2}
              },
              dispatch_mode: :explicit
          }
        }
      })

    proposed =
      "sha256:new-policy"
      |> snapshot()
      |> Map.merge(%{
        host: %{
          "capacity" => %{"max_concurrent_agents" => 3},
          "polling" => %{"max_concurrent_target_polls" => 4}
        },
        targets: %{
          "main" => %{
            proposed_target
            | configured: %{
                "state" => "active",
                "dispatch_mode" => "watch",
                "display_name" => "New",
                "repo" => %{"expected_repository" => "org/repo"},
                "scheduling" => %{}
              },
              configured_state: :active,
              effective_state: :active,
              dispatch_mode: :watch
          }
        }
      })

    preview = Preview.preview(current, proposed, source)

    assert preview.diff == [
             %{
               path: "$.host.capacity.max_concurrent_agents",
               before: 2,
               after: 3,
               classification: :broadened
             },
             %{
               path: "$.host.polling.interval_ms",
               before: 1_000,
               after: nil,
               classification: :removed
             },
             %{
               path: "$.host.polling.max_concurrent_target_polls",
               before: nil,
               after: 4,
               classification: :added
             },
             %{
               path: "$.targets.main.dispatch_mode",
               before: "explicit",
               after: "watch",
               classification: :broadened
             },
             %{
               path: "$.targets.main.display_name",
               before: "Old",
               after: "New",
               classification: :changed
             },
             %{
               path: "$.targets.main.effective_state",
               before: :paused,
               after: :active,
               classification: :broadened
             },
             %{
               path: "$.targets.main.policy_hash",
               before: "sha256:old-policy",
               after: "sha256:new-policy",
               classification: :changed
             },
             %{
               path: "$.targets.main.repo.expected_repository",
               before: nil,
               after: "org/repo",
               classification: :added
             },
             %{
               path: "$.targets.main.scheduling.weight",
               before: 2,
               after: nil,
               classification: :removed
             },
             %{
               path: "$.targets.main.state",
               before: "paused",
               after: "active",
               classification: :broadened
             }
           ]
  end

  test "distinguishes absent, empty, nil, and nonempty maps" do
    source = "map presence source"
    absent = snapshot("sha256:stable-policy")

    empty =
      put_in(
        absent,
        [Access.key!(:targets), "main", Access.key!(:configured), "scheduling"],
        %{}
      )

    explicit_nil =
      put_in(
        absent,
        [Access.key!(:targets), "main", Access.key!(:configured), "scheduling"],
        nil
      )

    nonempty =
      put_in(
        absent,
        [Access.key!(:targets), "main", Access.key!(:configured), "scheduling"],
        %{"weight" => 1}
      )

    for {before, proposed, before_value, after_value, classification} <- [
          {absent, empty, nil, %{}, :added},
          {empty, absent, %{}, nil, :removed},
          {absent, explicit_nil, nil, nil, :added},
          {explicit_nil, absent, nil, nil, :removed}
        ] do
      preview = Preview.preview(with_generation(before, source), proposed, source)

      assert preview.diff == [
               %{
                 path: "$.targets.main.scheduling",
                 before: before_value,
                 after: after_value,
                 classification: classification
               }
             ]

      assert preview.impact.scope.classification == :unknown
      assert preview.impact.overall == :unknown
    end

    assert Preview.preview(with_generation(absent, source), nonempty, source).diff == [
             %{
               path: "$.targets.main.scheduling.weight",
               before: nil,
               after: 1,
               classification: :added
             }
           ]

    assert Preview.preview(with_generation(nonempty, source), absent, source).diff == [
             %{
               path: "$.targets.main.scheduling.weight",
               before: 1,
               after: nil,
               classification: :removed
             }
           ]
  end

  test "classifies only schema-valid semantic values directionally" do
    source = "semantic domain source"

    base =
      policy_snapshot(
        %{
          "state" => "paused",
          "dispatch_mode" => "explicit",
          "linear" => %{"required_labels" => [" Release "]},
          "runners" => %{"allowed" => ["codex"]},
          "concurrency" => %{"max_concurrent_agents" => 2},
          "budgets" => %{"daily" => %{"max_total_tokens" => 100}},
          "checks" => %{"pre_dispatch" => ["repo_validation"]}
        },
        :paused,
        :explicit
      )

    configured_path = [Access.key!(:targets), "main", Access.key!(:configured)]

    for {nested_path, diff_path, before, invalid, category} <- [
          {["concurrency", "max_concurrent_agents"], "$.targets.main.concurrency.max_concurrent_agents", 2, 2.5, :capacity},
          {["concurrency", "max_concurrent_agents"], "$.targets.main.concurrency.max_concurrent_agents", 2, 0, :capacity},
          {["budgets", "daily", "max_total_tokens"], "$.targets.main.budgets.daily.max_total_tokens", 100, -1, :budgets},
          {["runners", "allowed"], "$.targets.main.runners.allowed", ["codex"], ["codex", "other", "other"], :runners},
          {["runners", "allowed"], "$.targets.main.runners.allowed", ["codex"], ["codex", " "], :runners},
          {["linear", "required_labels"], "$.targets.main.linear.required_labels", [" Release "], ["release", "urgent", "URGENT"], :scope},
          {["checks", "pre_dispatch"], "$.targets.main.checks.pre_dispatch", ["repo_validation"], ["repo_validation", "unknown_check"], :checks},
          {["checks", "pre_dispatch"], "$.targets.main.checks.pre_dispatch", ["repo_validation"], ["repo_validation", 7], :checks}
        ] do
      proposed = put_in(base, configured_path ++ nested_path, invalid)
      preview = Preview.preview(with_generation(base, source), proposed, source)

      assert preview.diff == [
               %{
                 path: diff_path,
                 before: before,
                 after: invalid,
                 classification: :changed
               }
             ]

      assert preview.impact[category].classification == :unknown
      assert preview.impact.overall == :unknown
    end

    normalized_labels =
      put_in(
        base,
        configured_path ++ ["linear", "required_labels"],
        ["release", " Urgent "]
      )

    label_preview = Preview.preview(with_generation(base, source), normalized_labels, source)

    assert label_preview.diff == [
             %{
               path: "$.targets.main.linear.required_labels",
               before: [" Release "],
               after: ["release", " Urgent "],
               classification: :restricted
             }
           ]

    assert label_preview.impact.scope.classification == :restricted
    assert label_preview.impact.overall == :restricted
  end

  test "uses exact schema paths for directional semantic classification" do
    source = "exact semantic paths source"

    gate_fields =
      ~w(tracker_write vcs_publish pull_request_write merge deployment production_data)

    base =
      policy_snapshot(
        %{
          "state" => "paused",
          "dispatch_mode" => "explicit",
          "settings" => %{
            "state" => "paused",
            "effective_state" => "paused",
            "dispatch_mode" => "explicit",
            "external_side_effects" => %{"tracker_write" => "deny"}
          },
          "linear" => %{
            "settings" => %{"required_labels" => ["base"]}
          },
          "runners" => %{
            "settings" => %{"allowed" => ["codex"]}
          },
          "concurrency" => %{
            "max_total_tokens" => 1,
            "settings" => %{"max_concurrent_agents" => 1},
            "by_linear_state" => %{
              "in-progress" => 1,
              "In Progress" => 1,
              "Ready For QA" => 1,
              "" => 1,
              7 => 1
            }
          },
          "budgets" => %{
            "settings" => %{"max_total_tokens" => 1},
            "daily" => %{"max_concurrent_agents" => 1}
          },
          "checks" => %{"daily" => ["repo_validation"]},
          "external_side_effects" =>
            Map.new(gate_fields, &{&1, "deny"})
            |> Map.put("custom_write", "deny")
        },
        :paused,
        :explicit
      )

    configured_path = [Access.key!(:targets), "main", Access.key!(:configured)]

    for {nested_path, proposed_value} <- [
          {["concurrency", "max_total_tokens"], 2},
          {["concurrency", "settings", "max_concurrent_agents"], 2},
          {["budgets", "settings", "max_total_tokens"], 2},
          {["budgets", "daily", "max_concurrent_agents"], 2},
          {["checks", "daily"], ["repo_validation", "quality_gate"]},
          {["runners", "settings", "allowed"], ["codex", "opencode"]},
          {["linear", "settings", "required_labels"], ["base", "release"]},
          {["settings", "state"], "active"},
          {["settings", "effective_state"], "active"},
          {["settings", "dispatch_mode"], "watch"},
          {["settings", "external_side_effects", "tracker_write"], "allow"}
        ] do
      proposed = put_in(base, configured_path ++ nested_path, proposed_value)
      preview = Preview.preview(with_generation(base, source), proposed, source)

      assert [%{classification: :changed}] = preview.diff
      assert preview.impact.overall == :unknown
    end

    for {before_host, proposed_host} <- [
          {%{"state" => "paused"}, %{"state" => "active"}},
          {%{"effective_state" => "paused"}, %{"effective_state" => "active"}},
          {%{"dispatch_mode" => "explicit"}, %{"dispatch_mode" => "watch"}},
          {
            %{"external_side_effects" => %{"tracker_write" => "deny"}},
            %{"external_side_effects" => %{"tracker_write" => "allow"}}
          }
        ] do
      current = %{base | host: before_host}
      proposed = %{base | host: proposed_host}
      preview = Preview.preview(with_generation(current, source), proposed, source)

      assert [%{classification: :changed}] = preview.diff
      assert preview.impact.scope.classification == :unknown
      assert preview.impact.overall == :unknown
    end

    target = base.targets["main"]

    state_target = %{
      target
      | configured: Map.put(target.configured, "state", "active"),
        configured_state: :active
    }

    state_preview =
      Preview.preview(
        with_generation(base, source),
        %{base | targets: %{"main" => state_target}},
        source
      )

    assert [%{path: "$.targets.main.state", classification: :broadened}] = state_preview.diff
    assert state_preview.impact.state.classification == :broadened

    effective_target = %{target | effective_state: :active}

    effective_preview =
      Preview.preview(
        with_generation(base, source),
        %{base | targets: %{"main" => effective_target}},
        source
      )

    assert [%{path: "$.targets.main.effective_state", classification: :broadened}] =
             effective_preview.diff

    assert effective_preview.impact.state.classification == :broadened

    dispatch_target = %{
      target
      | configured: Map.put(target.configured, "dispatch_mode", "watch"),
        dispatch_mode: :watch
    }

    dispatch_preview =
      Preview.preview(
        with_generation(base, source),
        %{base | targets: %{"main" => dispatch_target}},
        source
      )

    assert [%{path: "$.targets.main.dispatch_mode", classification: :broadened}] =
             dispatch_preview.diff

    assert dispatch_preview.impact.dispatch_mode.classification == :broadened

    for gate_field <- gate_fields do
      proposed =
        put_in(
          base,
          configured_path ++ ["external_side_effects", gate_field],
          "allow"
        )

      preview = Preview.preview(with_generation(base, source), proposed, source)

      assert [
               %{
                 path: "$.targets.main.external_side_effects." <> ^gate_field,
                 classification: :broadened
               }
             ] = preview.diff

      assert preview.impact.external_side_effects.classification == :broadened
    end

    unknown_gate =
      put_in(
        base,
        configured_path ++ ["external_side_effects", "custom_write"],
        "allow"
      )

    unknown_gate_preview =
      Preview.preview(with_generation(base, source), unknown_gate, source)

    assert [
             %{
               path: "$.targets.main.external_side_effects[key:" <> _typed_path,
               before: "[REDACTED]",
               after: "[REDACTED]",
               classification: :changed
             }
           ] = unknown_gate_preview.diff

    assert unknown_gate_preview.impact.scope.classification == :unknown
    assert unknown_gate_preview.impact.overall == :unknown

    for state_name <- ["in-progress", "In Progress", "Ready For QA"] do
      proposed =
        put_in(
          base,
          configured_path ++ ["concurrency", "by_linear_state", state_name],
          2
        )

      preview = Preview.preview(with_generation(base, source), proposed, source)

      assert [%{before: 1, after: 2, classification: :broadened} = change] = preview.diff
      assert preview.impact.capacity.classification == :broadened

      if state_name == "in-progress" do
        assert change.path == "$.targets.main.concurrency.by_linear_state.in-progress"
      else
        assert String.starts_with?(
                 change.path,
                 "$.targets.main.concurrency.by_linear_state[key:"
               )

        refute change.path =~ state_name
      end
    end

    for invalid_state_name <- ["", 7] do
      proposed =
        put_in(
          base,
          configured_path ++ ["concurrency", "by_linear_state", invalid_state_name],
          2
        )

      preview = Preview.preview(with_generation(base, source), proposed, source)

      assert [
               %{
                 path: "$.targets.main.concurrency.by_linear_state[key:" <> _typed_path,
                 before: "[REDACTED]",
                 after: "[REDACTED]",
                 classification: :changed
               } = change
             ] = preview.diff

      refute Map.has_key?(change, :semantic_hint)
      refute Map.has_key?(change, :sensitive?)
      refute Map.has_key?(change, :before_present?)
      refute Map.has_key?(change, :after_present?)
      assert preview.impact.scope.classification == :unknown
      assert preview.impact.overall == :unknown
    end

    typed_current = %{
      base
      | targets: %{
          7 => %{
            target
            | id: 7,
              configured: %{"concurrency" => %{"max_concurrent_agents" => 1}}
          }
        }
    }

    typed_proposed =
      put_in(
        typed_current,
        [
          Access.key!(:targets),
          7,
          Access.key!(:configured),
          "concurrency",
          "max_concurrent_agents"
        ],
        2
      )

    typed_preview = Preview.preview(with_generation(typed_current, source), typed_proposed, source)
    assert [%{classification: :changed}] = typed_preview.diff
    assert typed_preview.impact.overall == :unknown

    host_current = %{base | host: %{"capacity" => %{"settings" => %{"max_concurrent_agents" => 1}}}}
    host_proposed = put_in(host_current, [Access.key!(:host), "capacity", "settings", "max_concurrent_agents"], 2)
    host_preview = Preview.preview(with_generation(host_current, source), host_proposed, source)
    assert [%{classification: :changed}] = host_preview.diff
    assert host_preview.impact.overall == :unknown
  end

  test "classifies restrictive, broadening, mixed, and unknown policy impact" do
    source = "stable source"

    broad =
      policy_snapshot(
        %{
          "state" => "active",
          "dispatch_mode" => "watch",
          "linear" => %{"required_labels" => ["base"]},
          "runners" => %{"allowed" => ["codex", "opencode"]},
          "concurrency" => %{
            "max_concurrent_agents" => 4,
            "max_concurrent_startups" => 2
          },
          "budgets" => %{
            "daily" => %{"max_total_tokens" => 100},
            "weekly" => %{"max_total_tokens" => 500}
          },
          "checks" => %{"pre_dispatch" => ["repo_validation"]},
          "external_side_effects" => %{
            "tracker_write" => "allow",
            "merge" => "manual_approval"
          }
        },
        :active,
        :watch
      )

    restricted =
      policy_snapshot(
        %{
          "state" => "paused",
          "dispatch_mode" => "explicit",
          "linear" => %{"required_labels" => ["base", "release"]},
          "runners" => %{"allowed" => ["codex"]},
          "concurrency" => %{
            "max_concurrent_agents" => 2,
            "max_concurrent_startups" => 2
          },
          "budgets" => %{
            "daily" => %{"max_total_tokens" => 50},
            "weekly" => %{"max_total_tokens" => 500}
          },
          "checks" => %{
            "pre_dispatch" => ["quality_gate", "repo_validation"]
          },
          "external_side_effects" => %{
            "tracker_write" => "manual_approval",
            "merge" => "deny"
          }
        },
        :paused,
        :explicit
      )

    restrictive_impact = Preview.preview(with_generation(broad, source), restricted, source).impact

    for category <- [
          :state,
          :dispatch_mode,
          :runners,
          :capacity,
          :budgets,
          :checks,
          :external_side_effects
        ] do
      assert restrictive_impact[category].classification == :restricted
      assert restrictive_impact[category].changes != []
    end

    assert restrictive_impact.overall == :restricted

    assert restrictive_impact.runtime == %{
             host_dispatch: :unavailable_in_phase_1,
             legacy_single_target: :unchanged
           }

    broadening_impact = Preview.preview(with_generation(restricted, source), broad, source).impact

    for category <- [
          :state,
          :dispatch_mode,
          :runners,
          :capacity,
          :budgets,
          :checks,
          :external_side_effects
        ] do
      assert broadening_impact[category].classification == :broadened
    end

    assert broadening_impact.overall == :broadened

    mixed =
      broad
      |> put_in(
        [Access.key!(:targets), "main", Access.key!(:configured), "concurrency"],
        %{"max_concurrent_agents" => 2, "max_concurrent_startups" => 4}
      )

    mixed_impact = Preview.preview(with_generation(broad, source), mixed, source).impact
    assert mixed_impact.capacity.classification == :mixed
    assert mixed_impact.overall == :mixed

    malformed =
      put_in(
        broad,
        [Access.key!(:targets), "main", Access.key!(:configured), "runners", "allowed"],
        {"codex", "opencode"}
      )

    unknown_impact = Preview.preview(with_generation(broad, source), malformed, source).impact
    assert unknown_impact.runners.classification == :unknown
    assert unknown_impact.overall == :unknown
  end

  test "uses omitted deny gates and reports invalid active targets as forced paused" do
    source = "stable fail-closed source"

    omitted =
      policy_snapshot(
        %{
          "state" => "active",
          "dispatch_mode" => "explicit",
          "external_side_effects" => %{}
        },
        :active,
        :explicit
      )

    explicit_deny =
      put_in(
        omitted,
        [
          Access.key!(:targets),
          "main",
          Access.key!(:configured),
          "external_side_effects",
          "tracker_write"
        ],
        "deny"
      )

    deny_preview = Preview.preview(with_generation(omitted, source), explicit_deny, source)

    assert Enum.find(
             deny_preview.diff,
             &(&1.path == "$.targets.main.external_side_effects.tracker_write")
           ).classification == :added

    assert deny_preview.impact.external_side_effects.classification == :unchanged

    manual =
      put_in(
        omitted,
        [
          Access.key!(:targets),
          "main",
          Access.key!(:configured),
          "external_side_effects",
          "tracker_write"
        ],
        "manual_approval"
      )

    omitted_term = :erlang.term_to_binary(omitted, [:deterministic])
    manual_preview = Preview.preview(with_generation(omitted, source), manual, source)

    assert Enum.find(
             manual_preview.diff,
             &(&1.path == "$.targets.main.external_side_effects.tracker_write")
           ).classification == :broadened

    assert manual_preview.impact.external_side_effects.classification == :broadened
    assert :erlang.term_to_binary(omitted, [:deterministic]) == omitted_term

    removed_preview = Preview.preview(with_generation(manual, source), omitted, source)
    assert removed_preview.impact.external_side_effects.classification == :restricted

    diagnostic = %Diagnostic{
      severity: :error,
      scope: {:target, "main"},
      path: "$.targets.main.runners.default",
      code: :unknown_reference,
      message: "runner is unavailable"
    }

    current = policy_snapshot(%{"state" => "active", "dispatch_mode" => "explicit"}, :active, :explicit)
    target = current.targets["main"]

    quarantined =
      %{
        current
        | targets: %{
            "main" => %{
              target
              | effective_state: :paused,
                valid?: false,
                diagnostics: [diagnostic]
            }
          },
          diagnostics: [diagnostic]
      }

    quarantine_preview = Preview.preview(with_generation(current, source), quarantined, source)

    assert quarantine_preview.impact.state.classification == :forced_paused

    assert Enum.any?(
             quarantine_preview.impact.state.changes,
             &(&1.path == "$.targets.main.effective_state" and
                 &1.classification == :forced_paused)
           )

    assert quarantine_preview.diagnostics == [diagnostic]
  end

  test "treats present unknown gates as unknown rather than omitted deny" do
    source = "gate presence source"

    omitted =
      policy_snapshot(
        %{
          "state" => "paused",
          "dispatch_mode" => "explicit",
          "external_side_effects" => %{}
        },
        :paused,
        :explicit
      )

    explicit_deny =
      put_in(
        omitted,
        [
          Access.key!(:targets),
          "main",
          Access.key!(:configured),
          "external_side_effects",
          "tracker_write"
        ],
        "deny"
      )

    unknown =
      put_in(
        omitted,
        [
          Access.key!(:targets),
          "main",
          Access.key!(:configured),
          "external_side_effects",
          "tracker_write"
        ],
        "mystery"
      )

    for {before, proposed, expected_classification} <- [
          {omitted, unknown, :added},
          {unknown, omitted, :removed},
          {explicit_deny, unknown, :changed},
          {unknown, explicit_deny, :changed}
        ] do
      preview = Preview.preview(with_generation(before, source), proposed, source)

      assert preview.diff == [
               %{
                 path: "$.targets.main.external_side_effects.tracker_write",
                 before:
                   get_in(before, [
                     Access.key!(:targets),
                     "main",
                     Access.key!(:configured),
                     "external_side_effects",
                     "tracker_write"
                   ]),
                 after:
                   get_in(proposed, [
                     Access.key!(:targets),
                     "main",
                     Access.key!(:configured),
                     "external_side_effects",
                     "tracker_write"
                   ]),
                 classification: expected_classification
               }
             ]

      assert preview.impact.external_side_effects.classification == :unknown
      assert preview.impact.overall == :unknown
    end
  end

  test "synthesizes one forced pause with the diff union target index" do
    source = "forced pause synthesis source"

    diagnostic = %Diagnostic{
      severity: :error,
      scope: {:target, "new target"},
      path: "$.targets[key:1:string].effective_state",
      code: :invalid_target,
      message: "active target is forced paused"
    }

    base = snapshot("sha256:stable-policy")

    invalid_target = %{
      base.targets["main"]
      | id: "new target",
        configured: %{"state" => "active"},
        configured_state: :active,
        effective_state: :paused,
        valid?: false,
        diagnostics: [diagnostic]
    }

    current = %{base | targets: %{"bad target" => %{"malformed" => true}}}

    proposed = %{
      base
      | targets: %{"new target" => invalid_target},
        diagnostics: [diagnostic]
    }

    added_preview = Preview.preview(with_generation(current, source), proposed, source)

    assert [
             %{
               path: "$.targets[key:1:string].effective_state",
               before: nil,
               after: :paused,
               classification: :forced_paused
             }
           ] =
             Enum.filter(
               added_preview.diff,
               &String.ends_with?(&1.path, ".effective_state")
             )

    assert [
             %Diagnostic{
               scope: {:target, "[REDACTED]"},
               path: "$.targets[key:1:string].effective_state",
               message: "[REDACTED] target is forced paused"
             }
           ] = added_preview.diagnostics

    assert added_preview.impact.state.classification == :forced_paused

    unchanged_current = %{proposed | generation: Preview.generation(source)}
    unchanged_preview = Preview.preview(unchanged_current, proposed, source)

    assert unchanged_preview.diff == [
             %{
               path: "$.targets[key:0:string].effective_state",
               before: :paused,
               after: :paused,
               classification: :forced_paused
             }
           ]

    assert unchanged_preview.impact.state.classification == :forced_paused
    assert unchanged_preview.diagnostics == added_preview.diagnostics
  end

  test "redacts recursive credentials, messages, authorization, URIs, and private keys" do
    fixture_token = "fixture-token-AbC123456789"
    resolved_env_value = "resolved-env-value-XyZ987654321"
    private_key = "-----BEGIN PRIVATE KEY-----\nvery-private-material\n-----END PRIVATE KEY-----"

    value = %{
      "credential" => fixture_token,
      "nested" => [
        %{"api_key" => resolved_env_value, "plain" => "visible"},
        {"Bearer #{fixture_token}", %{password: "tuple-password-value"}}
      ],
      "authorization" => "Basic dXNlcjpwYXNzd29yZA==",
      "database_connection_string" => "postgres://db-user:db-password@localhost/app?token=#{fixture_token}",
      "private_key" => private_key,
      "uri" => "https://uri-user:uri-password@example.test/path?api_key=#{resolved_env_value}&safe=visible",
      "message" => "arbitrary failure included #{fixture_token}, #{resolved_env_value}, and token=standalone-secret"
    }

    redacted = Preview.redact(value)

    assert redacted["credential"] == "[REDACTED]"
    assert [%{"api_key" => "[REDACTED]", "plain" => "visible"}, tuple] = redacted["nested"]
    assert is_tuple(tuple)
    assert elem(tuple, 1) == %{password: "[REDACTED]"}
    assert redacted["authorization"] == "[REDACTED]"
    assert redacted["database_connection_string"] == "[REDACTED]"
    assert redacted["private_key"] == "[REDACTED]"
    assert redacted["uri"] =~ "[REDACTED]"
    assert redacted["uri"] =~ "safe=visible"
    assert redacted["message"] =~ "[REDACTED]"
    assert redacted["message"] =~ "arbitrary failure included"

    diagnostic = %Diagnostic{
      severity: :error,
      scope: {:target, "main"},
      path: "$.targets.main.api_key",
      code: :credential_rejected,
      message: "arbitrary diagnostic leaked #{fixture_token} and #{resolved_env_value}"
    }

    redacted_diagnostic = Preview.redact(diagnostic)

    assert %Diagnostic{
             severity: :error,
             scope: {:target, "main"},
             path: "$.targets.main.api_key",
             code: :credential_rejected
           } = redacted_diagnostic

    assert redacted_diagnostic.message =~ "[REDACTED]"

    rendered = inspect({redacted, redacted_diagnostic}, limit: :infinity, printable_limit: :infinity)
    refute rendered =~ fixture_token
    refute rendered =~ resolved_env_value
    refute rendered =~ "tuple-password-value"
    refute rendered =~ "very-private-material"
    refute rendered =~ "uri-password"
    refute rendered =~ "standalone-secret"
  end

  test "scrubs multiline authorization, short secrets, and encoded URI parameters" do
    short_secret = "xy"
    encoded_secret = "resolved value/+123"

    diagnostic = %Diagnostic{
      severity: :error,
      scope: :host,
      path: "$.host.tracker_connections.linear",
      code: :credential_rejected,
      message: """
      authorization: Bearer bearer-credential-123
      authorization:
        Basic basic-credential-456
      credential=xy
      proxy remains
      """
    }

    uri =
      "https://example.test/callback?" <>
        "api%5Fkey=#{URI.encode_www_form(encoded_secret)}&safe=visible&token=query-secret-789" <>
        "&authorization&flag" <>
        "#credential=#{URI.encode_www_form(short_secret)}&keep=shown&password=fragment-secret-012"

    redacted =
      Preview.redact({
        %{"credential" => short_secret, "api_key" => encoded_secret},
        diagnostic,
        %{"uri" => uri}
      })

    {_credentials, redacted_diagnostic, %{"uri" => redacted_uri}} = redacted
    rendered = inspect(redacted, limit: :infinity, printable_limit: :infinity)

    for secret <- [
          encoded_secret,
          URI.encode_www_form(encoded_secret),
          "bearer-credential-123",
          "basic-credential-456",
          "query-secret-789",
          "fragment-secret-012"
        ] do
      refute rendered =~ secret
    end

    refute redacted_diagnostic.message =~ "credential=xy"
    refute redacted_uri =~ "credential=xy"
    assert rendered =~ "proxy remains"
    assert rendered =~ "safe=visible"
    assert rendered =~ "keep=shown"
    assert rendered =~ "[REDACTED]"

    assert redacted_uri =~ "&flag"
    refute redacted_uri =~ "&authorization"

    malformed_uri =
      Preview.redact(%{
        "uri" => "https://example.test/callback?api%5Fkey=%ZZ&flag"
      })["uri"]

    refute malformed_uri =~ "%ZZ"
    assert malformed_uri =~ "&flag"
  end

  test "redacts nested decoded URI credential assignments" do
    query_secret = "NestedQueryMaterial7kP4"
    fragment_secret = "NestedFragmentMaterial9mR2"

    uri =
      "https://example.test/callback?" <>
        "return=#{URI.encode_www_form("ok&token=#{query_secret}")}&safe=visible" <>
        "#next=#{URI.encode_www_form("ok&authorization=Bearer #{fragment_secret}")}&keep=shown"

    redacted_uri = Preview.redact(%{"uri" => uri})["uri"]

    refute redacted_uri =~ query_secret
    refute redacted_uri =~ URI.encode_www_form(query_secret)
    refute redacted_uri =~ fragment_secret
    refute redacted_uri =~ URI.encode_www_form(fragment_secret)
    assert redacted_uri =~ "return=[REDACTED]"
    assert redacted_uri =~ "next=[REDACTED]"
    assert redacted_uri =~ "safe=visible"
    assert redacted_uri =~ "keep=shown"

    malformed = Preview.redact(%{"uri" => "https://example.test/?return=%ZZ&safe=visible"})["uri"]
    assert malformed =~ "safe=visible"
  end

  test "trusts only generated change and diagnostic paths" do
    secret = "fixture-token-UntrustedPath123"
    diagnostic_path = "$.targets.main.external_side_effects.api_key"

    assert Preview.redact(%{path: secret, credential: secret}) == %{
             path: "[REDACTED]",
             credential: "[REDACTED]"
           }

    diagnostic = %Diagnostic{
      severity: :error,
      scope: {:target, "main"},
      path: diagnostic_path,
      code: :credential_rejected,
      message: "Bearer #{secret}"
    }

    assert Preview.redact(diagnostic).path == diagnostic_path
  end

  test "validates contextual paths, scopes, and target summary fields" do
    ordinary_path = "OrdinaryPathMaterial8nT3"
    diagnostic_path = "$.targets.DynamicPathMaterial6qW9.state"
    scope_id = "DynamicScopeMaterial4hJ7"

    assert Preview.redact(%{path: ordinary_path}) == %{path: "[REDACTED]"}

    diagnostic = %Diagnostic{
      severity: :error,
      scope: {:target, scope_id},
      path: diagnostic_path,
      code: :invalid_value,
      message: "ordinary diagnostic"
    }

    redacted_diagnostic = Preview.redact(diagnostic)
    assert redacted_diagnostic.path == "[REDACTED]"
    assert redacted_diagnostic.scope == {:target, "[REDACTED]"}

    bounded_diagnostic = %{diagnostic | scope: :host, path: String.duplicate("$.host", 200)}
    assert Preview.redact(bounded_diagnostic).path == "[REDACTED]"

    assert Preview.redact(%{
             diagnostic
             | scope: {:target, "a"},
               path: "$.targets.a.checks.pre_dispatch"
           }) == %{
             diagnostic
             | scope: {:target, "a"},
               path: "$.targets.a.checks.pre_dispatch"
           }

    summary_id = "SummaryIdentityMaterial5cV8"
    state_value = "SummaryStateMaterial3bN6"
    effective_state = "SummaryEffectiveMaterial2dF7"
    mode_value = "SummaryModeMaterial9sL4"
    policy_hash = "SummaryPolicyMaterial1gH5"
    malformed_validity = "SummaryValidityMaterial7pK2"
    base = snapshot(Preview.generation("summary policy"))
    target = base.targets["main"]

    malformed_target = %{
      target
      | id: summary_id,
        configured: %{"state" => state_value, "dispatch_mode" => mode_value},
        configured_state: {:unknown, state_value},
        effective_state: effective_state,
        dispatch_mode: {:unknown, mode_value},
        policy_hash: policy_hash,
        valid?: malformed_validity
    }

    proposed = %{base | targets: %{"main" => malformed_target}}
    preview = Preview.preview(with_generation(proposed, "summary source"), proposed, "summary source")

    assert [
             %{
               id: "[REDACTED]",
               configured_state: {:unknown, "[REDACTED]"},
               effective_state: "[REDACTED]",
               dispatch_mode: {:unknown, "[REDACTED]"},
               policy_hash: "[REDACTED]",
               valid?: false
             }
           ] = preview.targets

    rendered = inspect({redacted_diagnostic, preview}, limit: :infinity, printable_limit: :infinity)

    for secret <- [
          ordinary_path,
          diagnostic_path,
          scope_id,
          summary_id,
          state_value,
          effective_state,
          mode_value,
          policy_hash,
          malformed_validity
        ] do
      refute rendered =~ secret
    end
  end

  test "redacts short sensitive diff values without replacing ordinary values" do
    source = "short contextual source"
    base = snapshot(Preview.generation("short identifier policy"))
    target = base.targets["main"]

    current_target = %{
      target
      | id: "x",
        configured: Map.put(target.configured, "display_name", "x")
    }

    proposed_target = %{
      current_target
      | configured: Map.put(current_target.configured, "display_name", "visible")
    }

    current = %{
      base
      | generation: Preview.generation(source),
        host: %{
          "polling" => %{"opaque_extension" => "a"},
          "tracker_connections" => %{"linear" => %{"api_key" => "x"}}
        },
        targets: %{"x" => current_target}
    }

    proposed = %{
      current
      | host: %{
          "polling" => %{"opaque_extension" => "bc"},
          "tracker_connections" => %{"linear" => %{"api_key" => "yz"}}
        },
        targets: %{"x" => proposed_target}
    }

    preview = Preview.preview(current, proposed, source)

    assert preview.diff == [
             %{
               path: "$.host.polling[key:0:string]",
               before: "[REDACTED]",
               after: "[REDACTED]",
               classification: :changed
             },
             %{
               path: "$.host.tracker_connections.linear.api_key",
               before: "[REDACTED]",
               after: "[REDACTED]",
               classification: :changed
             },
             %{
               path: "$.targets.x.display_name",
               before: "x",
               after: "visible",
               classification: :changed
             }
           ]

    assert preview.impact.scope.changes == preview.diff
    assert [%{id: "x"}] = preview.targets

    for change <-
          preview.diff ++
            Enum.flat_map(
              ~w(state dispatch_mode scope runners capacity budgets checks external_side_effects)a,
              &preview.impact[&1].changes
            ) do
      refute Map.has_key?(change, :semantic_hint)
      refute Map.has_key?(change, :sensitive?)
      refute Map.has_key?(change, :before_present?)
      refute Map.has_key?(change, :after_present?)
    end

    rendered = inspect(preview, limit: :infinity, printable_limit: :infinity)
    assert rendered =~ "$.targets.x.display_name"
    refute rendered =~ ~s("yz")
    refute rendered =~ ~s("bc")

    assert Preview.redact(%{"credential" => "x", "plain" => "x"})["plain"] == "x"
  end

  test "contains malformed public summary and diagnostic fields" do
    source = "malformed public fields source"
    base = snapshot(Preview.generation("malformed public fields policy"))
    target = base.targets["main"]

    malformed_target = %{
      target
      | configured_state: 7,
        effective_state: 7,
        dispatch_mode: 7,
        policy_hash: nil
    }

    diagnostics = [
      %Diagnostic{
        severity: :error,
        scope: 7,
        path: "$",
        code: :invalid_public_field,
        message: 7
      },
      %Diagnostic{
        severity: :error,
        scope: :registry,
        path: "not-a-generated-path",
        code: :invalid_public_path,
        message: "visible"
      }
    ]

    current = %{base | generation: 7}

    proposed = %{
      base
      | targets: %{"main" => malformed_target},
        diagnostics: diagnostics
    }

    preview = Preview.preview(current, proposed, source)

    assert %{before: "[REDACTED]", classification: :source_difference} =
             Enum.find(preview.diff, &(&1.path == "$.generation"))

    assert [
             %{
               id: "main",
               configured_state: "[REDACTED]",
               effective_state: "[REDACTED]",
               dispatch_mode: "[REDACTED]",
               policy_hash: nil
             }
           ] = preview.targets

    assert [
             %Diagnostic{
               scope: "[REDACTED]",
               path: "$",
               message: "[REDACTED]"
             },
             %Diagnostic{
               scope: :registry,
               path: "[REDACTED]",
               message: "visible"
             }
           ] = preview.diagnostics

    assert Preview.redact(%{"path" => "visible"}) == %{"path" => "[REDACTED]"}
  end

  test "bounds preview secret collection by depth and node count" do
    source = "bounded preview secrets source"

    deep_host =
      Enum.reduce(1..70, %{}, fn index, nested ->
        %{"level-#{index}" => nested}
      end)

    deep_snapshot = %{
      snapshot(Preview.generation("deep preview policy"))
      | host: deep_host
    }

    assert Preview.preview(
             with_generation(deep_snapshot, source),
             deep_snapshot,
             source
           ).diff == []

    many_connections =
      Map.new(1..10_005, fn index ->
        {"connection-#{index}", "visible"}
      end)

    wide_snapshot = %{
      snapshot(Preview.generation("wide preview policy"))
      | host: %{"tracker_connections" => many_connections}
    }

    assert Preview.preview(
             with_generation(wide_snapshot, source),
             wide_snapshot,
             source
           ).diff == []
  end

  test "collects values under unknown keys before redacting public changes" do
    source = "unknown key sensitivity source"
    before_secret = "OpaqueUnknownBefore7vN4pQ2"
    after_secret = "OpaqueUnknownAfter9mK6rT3"
    base = snapshot(Preview.generation("unknown key policy"))
    current = %{base | host: %{"plain" => %{"opaque_extension" => before_secret}}}
    proposed = %{base | host: %{"plain" => %{"opaque_extension" => after_secret}}}

    preview = Preview.preview(with_generation(current, source), proposed, source)
    assert [%{before: "[REDACTED]", after: "[REDACTED]"}] = preview.diff

    rendered = inspect(preview, limit: :infinity, printable_limit: :infinity)
    refute rendered =~ before_secret
    refute rendered =~ after_secret
  end

  test "scrubs preview diff and diagnostics without exposing arbitrary map keys in paths" do
    source = "redacted preview source"
    old_token = "fixture-token-Old123456789"
    new_token = "resolved-env-value-New987654321"
    arbitrary_key = "arbitrary-#{old_token}"

    current =
      snapshot("sha256:unchanged-policy")
      |> Map.merge(%{
        generation: Preview.generation(source),
        host: %{
          "tracker_connections" => %{"linear" => %{"api_key" => old_token}},
          "malformed" => %{arbitrary_key => "before"}
        }
      })

    diagnostic = %Diagnostic{
      severity: :error,
      scope: {:target, "main"},
      path: "$.targets.main.external_side_effects.tracker_write",
      code: :credential_rejected,
      message: "adapter returned #{old_token}, #{new_token}, and Bearer #{new_token}"
    }

    proposed =
      snapshot("sha256:unchanged-policy")
      |> Map.merge(%{
        host: %{
          "tracker_connections" => %{"linear" => %{"api_key" => new_token}},
          "malformed" => %{arbitrary_key => "after"}
        },
        diagnostics: [diagnostic]
      })

    current_term = :erlang.term_to_binary(current, [:deterministic])
    proposed_term = :erlang.term_to_binary(proposed, [:deterministic])
    preview = Preview.preview(current, proposed, source)

    api_key_change =
      Enum.find(
        preview.diff,
        &(&1.path == "$.host.tracker_connections.linear.api_key")
      )

    assert api_key_change.before == "[REDACTED]"
    assert api_key_change.after == "[REDACTED]"
    assert Enum.any?(preview.diff, &String.contains?(&1.path, "[key:"))
    refute Enum.any?(preview.diff, &String.contains?(&1.path, arbitrary_key))

    assert [%Diagnostic{} = redacted_diagnostic] = preview.diagnostics
    assert redacted_diagnostic.path == diagnostic.path
    assert redacted_diagnostic.code == diagnostic.code
    assert redacted_diagnostic.scope == diagnostic.scope
    assert redacted_diagnostic.message =~ "[REDACTED]"

    rendered = inspect(preview, limit: :infinity, printable_limit: :infinity)
    refute rendered =~ old_token
    refute rendered =~ new_token
    refute rendered =~ arbitrary_key
    assert :erlang.term_to_binary(current, [:deterministic]) == current_term
    assert :erlang.term_to_binary(proposed, [:deterministic]) == proposed_term
  end

  test "redacts the complete preview while preserving generated hashes and safe identity" do
    source = "complete redaction source"
    injected_secret = "fixture-token-complete-preview-123"
    safe_target = snapshot("sha256:safe-policy").targets["main"]

    secret_target = %{
      safe_target
      | id: injected_secret,
        configured: %{
          "state" => injected_secret,
          "dispatch_mode" => injected_secret,
          "credential" => injected_secret
        },
        configured_state: {:unknown, injected_secret},
        dispatch_mode: {:unknown, injected_secret},
        policy_hash: injected_secret,
        valid?: false
    }

    proposed =
      "sha256:safe-policy"
      |> snapshot()
      |> Map.merge(%{
        host: %{"tracker_connections" => %{"linear" => %{"api_key" => injected_secret}}},
        targets: %{"main" => safe_target, injected_secret => secret_target}
      })

    preview = Preview.preview(nil, proposed, source)
    rendered = inspect(preview, limit: :infinity, printable_limit: :infinity)

    assert preview.expected_generation == nil
    assert preview.proposed_generation == Preview.generation(source)
    assert Enum.any?(preview.targets, &(&1.id == "main"))
    refute rendered =~ injected_secret
  end

  test "bounds malformed redaction and orders mixed-key terms deterministically" do
    secret = "fixture-token-MixedKey123456789"
    deep = Enum.reduce(1..100, secret, fn _index, nested -> [nested] end)

    entries = [
      {1, secret},
      {1.0, "Bearer #{secret}"},
      {:credential, secret},
      {%{"token" => secret}, "map-key-value"},
      {"nested", deep},
      {"plain", "visible"},
      {"invalid_utf8", <<255>>}
    ]

    first = entries |> Map.new() |> Preview.redact()
    reordered = entries |> Enum.reverse() |> Map.new() |> Preview.redact()

    assert first === reordered
    assert first["plain"] == "visible"
    assert first["invalid_utf8"] == "[REDACTED]"

    rendered = inspect(first, limit: :infinity, printable_limit: :infinity)
    refute rendered =~ secret
    refute rendered =~ "map-key-value"
    assert rendered =~ "[REDACTED]"

    assert Preview.redact(%{"password" => 123}) == %{"password" => "[REDACTED]"}

    wide = Map.new(1..10_005, &{&1, secret})
    assert [redacted_wide | "[REDACTED]"] = Preview.redact([wide, "after-bound"])
    assert map_size(redacted_wide) < map_size(wide)
    assert Enum.all?(redacted_wide, fn {_key, value} -> value == "[REDACTED]" end)
  end

  test "returns stable empty changes and identical reordered previews" do
    source = "canonical stable bytes"
    base = snapshot("sha256:stable-policy")
    target = base.targets["main"]
    alpha = %{target | id: "alpha"}

    host_entries = [
      {"capacity", %{"max_concurrent_agents" => 2}},
      {"polling", %{"interval_ms" => 1_000}}
    ]

    target_entries = [
      {"main", target},
      {"alpha", alpha}
    ]

    ordered = %{
      base
      | host: Map.new(host_entries),
        targets: Map.new(target_entries)
    }

    reordered = %{
      base
      | host: host_entries |> Enum.reverse() |> Map.new(),
        targets: target_entries |> Enum.reverse() |> Map.new()
    }

    current = with_generation(ordered, source)
    unchanged = Preview.preview(current, reordered, source)
    repeated = Preview.preview(current, reordered, source)

    assert unchanged == repeated
    assert unchanged.diff == []
    refute unchanged.source_changed?
    assert unchanged.impact.overall == :unchanged

    for category <- [
          :state,
          :dispatch_mode,
          :scope,
          :runners,
          :capacity,
          :budgets,
          :checks,
          :external_side_effects
        ] do
      assert unchanged.impact[category] == %{classification: :unchanged, changes: []}
    end

    assert Enum.map(unchanged.targets, & &1.id) == ["alpha", "main"]

    assert :erlang.term_to_binary(unchanged, [:deterministic]) ==
             :erlang.term_to_binary(repeated, [:deterministic])
  end

  test "uses a loaded source hash fallback and reports complete map removal" do
    current_source = "loaded bytes"
    proposed_source = "proposed bytes"

    current =
      "sha256:old-policy"
      |> snapshot()
      |> Map.merge(%{
        source_hash: Preview.generation(current_source),
        host: %{"polling" => %{"interval_ms" => 1_000}}
      })

    proposed = %{snapshot("sha256:new-policy") | host: %{}, targets: %{}}
    preview = Preview.preview(current, proposed, proposed_source)

    assert preview.expected_generation == Preview.generation(current_source)
    assert preview.targets == []

    assert Enum.any?(
             preview.diff,
             &(&1.path == "$.host.polling.interval_ms" and &1.classification == :removed)
           )

    assert Enum.any?(
             preview.diff,
             &(&1.path == "$.targets.main.policy_hash" and &1.classification == :removed)
           )
  end

  test "projects normalized dispatch and configured state once" do
    source = "normalized target fields source"
    base = snapshot("sha256:stable-policy")
    target = base.targets["main"]

    omitted_nil = %{
      base
      | targets: %{
          "main" => %{target | configured: %{"state" => "paused"}, dispatch_mode: nil}
        }
    }

    explicit_nil = %{
      base
      | targets: %{
          "main" => %{
            target
            | configured: %{"state" => "paused", "dispatch_mode" => nil},
              dispatch_mode: nil
          }
        }
    }

    assert Preview.preview(with_generation(omitted_nil, source), explicit_nil, source).diff == []

    explicit = %{
      base
      | targets: %{
          "main" => %{target | configured: %{"state" => "paused"}, dispatch_mode: :explicit}
        }
    }

    watch = %{
      base
      | targets: %{
          "main" => %{
            target
            | configured: %{"state" => "paused", "dispatch_mode" => nil},
              dispatch_mode: :watch
          }
        }
    }

    for {before, proposed, before_mode, after_mode, classification} <- [
          {omitted_nil, explicit, nil, "explicit", :broadened},
          {explicit, watch, "explicit", "watch", :broadened},
          {watch, explicit, "watch", "explicit", :restricted}
        ] do
      preview = Preview.preview(with_generation(before, source), proposed, source)

      assert preview.diff == [
               %{
                 path: "$.targets.main.dispatch_mode",
                 before: before_mode,
                 after: after_mode,
                 classification: classification
               }
             ]

      assert preview.impact.dispatch_mode.classification == classification
      assert preview.impact.overall == classification
    end

    paused = %{
      base
      | targets: %{
          "main" => %{
            target
            | configured: %{"state" => "active"},
              configured_state: :paused,
              effective_state: :paused
          }
        }
    }

    active = %{
      base
      | targets: %{
          "main" => %{
            target
            | configured: %{"state" => "paused"},
              configured_state: :active,
              effective_state: :active
          }
        }
    }

    state_preview = Preview.preview(with_generation(paused, source), active, source)

    assert state_preview.diff == [
             %{
               path: "$.targets.main.effective_state",
               before: :paused,
               after: :active,
               classification: :broadened
             },
             %{
               path: "$.targets.main.state",
               before: "paused",
               after: "active",
               classification: :broadened
             }
           ]

    assert state_preview.impact.state.classification == :broadened
    assert state_preview.impact.overall == :broadened
  end

  test "preserves malformed configured state and mode terms for unknown diffs" do
    source = "malformed normalized target fields source"
    base = snapshot(Preview.generation("malformed projection policy"))
    target = base.targets["main"]

    current = %{
      base
      | targets: %{
          "main" => %{
            target
            | configured: %{"state" => 7, "dispatch_mode" => 7},
              configured_state: nil,
              dispatch_mode: nil
          }
        }
    }

    proposed = %{
      base
      | targets: %{
          "main" => %{
            target
            | configured: %{"state" => 8, "dispatch_mode" => 8},
              configured_state: nil,
              dispatch_mode: nil
          }
        }
    }

    preview = Preview.preview(with_generation(current, source), proposed, source)

    assert preview.diff == [
             %{
               path: "$.targets.main.dispatch_mode",
               before: 7,
               after: 8,
               classification: :changed
             },
             %{
               path: "$.targets.main.state",
               before: 7,
               after: 8,
               classification: :changed
             }
           ]

    assert preview.impact.dispatch_mode.classification == :unknown
    assert preview.impact.state.classification == :unknown
    assert preview.impact.overall == :unknown
  end

  test "contains unknown lifecycle impact and classifies draining and retired transitions" do
    source = "lifecycle source"

    retired =
      policy_snapshot(
        %{
          "state" => "retired",
          "dispatch_mode" => "mystery",
          "runners" => %{"allowed" => ["codex", "opencode"]}
        },
        :retired,
        {:unknown, "mystery"}
      )

    draining =
      policy_snapshot(
        %{
          "state" => "draining",
          "dispatch_mode" => "explicit",
          "runners" => %{"allowed" => ["opencode", "other"]}
        },
        :draining,
        :explicit
      )

    broadened = Preview.preview(with_generation(retired, source), draining, source)
    assert broadened.impact.state.classification == :broadened
    assert broadened.impact.dispatch_mode.classification == :unknown
    assert broadened.impact.runners.classification == :unknown
    assert broadened.impact.overall == :unknown

    restricted = Preview.preview(with_generation(draining, source), retired, source)
    assert restricted.impact.state.classification == :restricted
    assert restricted.impact.dispatch_mode.classification == :unknown

    no_dispatch =
      policy_snapshot(%{"state" => "paused", "dispatch_mode" => nil}, :paused, nil)

    watch_dispatch =
      policy_snapshot(%{"state" => "paused", "dispatch_mode" => "watch"}, :paused, :watch)

    watch_preview = Preview.preview(with_generation(no_dispatch, source), watch_dispatch, source)
    assert watch_preview.impact.dispatch_mode.classification == :broadened

    active = policy_snapshot(%{"state" => "active"}, :active, nil)
    target = active.targets["main"]

    unknown_state = %{
      active
      | targets: %{
          "main" => %{
            target
            | configured: %{"state" => "mystery"},
              configured_state: {:unknown, "mystery"},
              effective_state: :paused
          }
        }
    }

    assert Preview.preview(with_generation(active, source), unknown_state, source).impact.state.classification ==
             :unknown
  end

  test "contains malformed snapshot target containers and values deterministically" do
    source = "malformed snapshot source"
    secret = "fixture-token-MalformedSnapshot123"
    base = snapshot("sha256:stable-policy")
    target = base.targets["main"]

    malformed_target = %{
      target
      | id: 7,
        configured: secret,
        configured_state: nil,
        effective_state: :paused,
        valid?: false
    }

    malformed_map = %{
      base
      | targets: %{
          7 => malformed_target,
          "raw" => %{"password" => secret}
        }
    }

    map_preview = Preview.preview(with_generation(base, source), malformed_map, source)

    assert [%{id: "[REDACTED]", valid?: false, policy_hash: "[REDACTED]"}] =
             map_preview.targets

    refute inspect(map_preview, limit: :infinity, printable_limit: :infinity) =~ secret

    malformed_container = %{base | targets: [secret]}
    container_preview = Preview.preview(with_generation(base, source), malformed_container, source)

    assert container_preview.targets == []
    refute inspect(container_preview, limit: :infinity, printable_limit: :infinity) =~ secret
  end

  test "indexes every malformed map key type without exposing key contents" do
    source = "mixed-key diff source"
    secret = "fixture-token-MixedDiffKey123"
    opaque = make_ref()

    keys = [
      :atom_key,
      "unsafe-binary-key",
      1,
      1.0,
      {:tuple, :key},
      [:list_key],
      %{"sensitive-key-content" => secret},
      opaque
    ]

    current_host = Map.new(keys, &{&1, "before-#{secret}"})
    proposed_host = Map.new(Enum.reverse(keys), &{&1, "after-#{secret}"})
    current = %{snapshot("sha256:stable-policy") | host: current_host}
    proposed = %{snapshot("sha256:stable-policy") | host: proposed_host}

    preview = Preview.preview(with_generation(current, source), proposed, source)
    paths = Enum.map(preview.diff, & &1.path)

    for type <- ~w(atom string integer float tuple list map term) do
      assert Enum.any?(paths, &String.contains?(&1, ":#{type}]"))
    end

    rendered = inspect(preview, limit: :infinity, printable_limit: :infinity)
    refute rendered =~ secret
    refute rendered =~ "sensitive-key-content"
    refute rendered =~ "unsafe-binary-key"

    assert Preview.redact(%{"unsafe-binary-key" => secret}) == %{
             "<key:0:string>" => "[REDACTED]"
           }
  end

  defp policy_snapshot(configured, effective_state, dispatch_mode) do
    base = snapshot("sha256:stable-policy")
    target = base.targets["main"]

    %{
      base
      | targets: %{
          "main" => %{
            target
            | configured: configured,
              configured_state: configured_state(configured["state"]),
              effective_state: effective_state,
              dispatch_mode: dispatch_mode
          }
        }
    }
  end

  defp with_generation(snapshot, source), do: %{snapshot | generation: Preview.generation(source)}

  defp configured_state("active"), do: :active
  defp configured_state("paused"), do: :paused
  defp configured_state("draining"), do: :draining
  defp configured_state("retired"), do: :retired

  defp snapshot(policy_hash) do
    target = %Target{
      id: "main",
      configured: %{"state" => "paused"},
      configured_state: :paused,
      effective_state: :paused,
      dispatch_mode: nil,
      valid?: true,
      effective_policy: %{"rule" => "effective"},
      policy_hash: policy_hash,
      diagnostics: []
    }

    %Snapshot{
      version: 1,
      globally_valid?: true,
      host: %{},
      targets: %{"main" => target},
      diagnostics: []
    }
  end
end
