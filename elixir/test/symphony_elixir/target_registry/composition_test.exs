defmodule SymphonyElixir.TargetRegistry.CompositionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TargetRegistry.Composition
  alias SymphonyElixir.TargetRegistry.Diagnostic
  alias SymphonyElixir.TargetRegistry.Schema
  alias SymphonyElixir.TargetRegistry.Snapshot
  alias SymphonyElixir.TargetRegistry.Target

  defmodule LocalManifestAdapter do
    @moduledoc false

    alias SymphonyElixir.Workflow.Manifest

    def read(path, opts) do
      case Manifest.read(path, opts) do
        {:ok, manifest} ->
          case fault(manifest) do
            "read_exception" -> raise "injected read exception"
            "read_unexpected" -> :unexpected
            "read_shape_unexpected" -> {:ok, %{}}
            "read_malformed_semantic_errors" -> {:error, {:invalid_manifest, :malformed}}
            _fault -> {:ok, manifest}
          end

        error ->
          error
      end
    end

    def validate(repo_path, manifest) do
      case fault(manifest) do
        "validation_exception" ->
          raise "injected validation exception"

        "validation_unexpected" ->
          :unexpected

        "validation_result_unexpected" ->
          %{errors: []}

        "malformed_semantic_errors" ->
          %{errors: [:invalid], modules: [], preset: "default"}

        _fault ->
          Manifest.validate(repo_path, manifest)
      end
    end

    def compile(manifest) do
      case fault(manifest) do
        "compile_exception" -> raise "injected compile exception"
        "compile_unexpected" -> :unexpected
        fault -> manifest |> Manifest.compile() |> inject_compile_fault(fault)
      end
    end

    def non_finite_float do
      external_positive_infinity = <<131, 70, 0x7F, 0xF0, 0, 0, 0, 0, 0, 0>>

      try do
        case :erlang.binary_to_term(external_positive_infinity) do
          value when is_float(value) -> {:ok, value}
          _value -> :unsupported
        end
      rescue
        ArgumentError -> :unsupported
      end
    end

    defp inject_compile_fault(_compiled, "result_unexpected"),
      do: %{config: %{}, workflow_module_resolution: %{}}

    defp inject_compile_fault(compiled, "resolution_unexpected"),
      do: Map.put(compiled, :workflow_module_resolution, %{})

    defp inject_compile_fault(compiled, "manifest_labels_not_list"),
      do: put_in(compiled, [:config, "manifest", "issue_markers", "labels"], "not-a-list")

    defp inject_compile_fault(compiled, "manifest_repository_not_string"),
      do: put_in(compiled, [:config, "manifest", "project", "repository"], 42)

    defp inject_compile_fault(compiled, "manifest_required_checks_not_list"),
      do: put_in(compiled, [:config, "manifest", "auto_land", "required_checks"], "not-a-list")

    defp inject_compile_fault(compiled, "manifest_review_paths_not_list"),
      do: put_in(compiled, [:config, "manifest", "auto_land", "force_human_review_paths"], "not-a-list")

    defp inject_compile_fault(compiled, "manifest_auto_land_invalid"),
      do: put_in(compiled, [:config, "manifest", "auto_land"], "not-a-map")

    defp inject_compile_fault(compiled, "manifest_improper_list") do
      put_in(compiled, [:config, "manifest", "validation", "commands"], [
        %{"name" => "test", "command" => "mix test"} | :invalid
      ])
    end

    defp inject_compile_fault(compiled, "manifest_json_improper_list"),
      do: put_in(compiled, [:config, "manifest", "docs", "entrypoints"], ["README.md" | :invalid])

    defp inject_compile_fault(compiled, "manifest_function"),
      do: put_in(compiled, [:config, "manifest", "docs", "invalid"], fn -> :invalid end)

    defp inject_compile_fault(compiled, "manifest_tuple"),
      do: put_in(compiled, [:config, "manifest", "capabilities", "required"], {:invalid, :term})

    defp inject_compile_fault(compiled, "manifest_non_string_key") do
      update_in(compiled, [:config, "manifest", "project"], &Map.put(&1, :repository, "duplicate"))
    end

    defp inject_compile_fault(compiled, "manifest_validation_command_not_map"),
      do: put_in(compiled, [:config, "manifest", "validation", "commands"], [42])

    defp inject_compile_fault(compiled, "manifest_validation_command_missing_name"),
      do: put_in(compiled, [:config, "manifest", "validation", "commands"], [%{"command" => "mix test"}])

    defp inject_compile_fault(compiled, "manifest_validation_command_missing_command"),
      do: put_in(compiled, [:config, "manifest", "validation", "commands"], [%{"name" => "test"}])

    defp inject_compile_fault(compiled, "manifest_validation_command_name_not_string") do
      put_in(compiled, [:config, "manifest", "validation", "commands"], [
        %{"name" => 42, "command" => "mix test"}
      ])
    end

    defp inject_compile_fault(compiled, "manifest_validation_command_command_not_string") do
      put_in(compiled, [:config, "manifest", "validation", "commands"], [
        %{"name" => "test", "command" => 42}
      ])
    end

    defp inject_compile_fault(compiled, "manifest_validation_command_unknown_field") do
      put_in(compiled, [:config, "manifest", "validation", "commands"], [
        %{"name" => "test", "command" => "mix test", "timeout" => 60}
      ])
    end

    defp inject_compile_fault(compiled, "manifest_validation_command_non_string_key") do
      put_in(compiled, [:config, "manifest", "validation", "commands"], [
        %{"name" => "test", "command" => "mix test", timeout: 60}
      ])
    end

    defp inject_compile_fault(compiled, "manifest_invalid_utf8"),
      do: put_in(compiled, [:config, "manifest", "docs", "invalid"], <<0xFF>>)

    defp inject_compile_fault(compiled, "manifest_invalid_utf8_key") do
      update_in(compiled, [:config, "manifest", "docs"], &Map.put(&1, <<0xFF>>, "invalid"))
    end

    defp inject_compile_fault(compiled, "manifest_non_finite_float") do
      case non_finite_float() do
        {:ok, value} -> put_in(compiled, [:config, "manifest", "docs", "invalid"], value)
        :unsupported -> compiled
      end
    end

    defp inject_compile_fault(compiled, "resolution_names_not_list"),
      do: put_in(compiled, [:workflow_module_resolution, :module_names], "not-a-list")

    defp inject_compile_fault(compiled, "resolution_invalid_name"),
      do: put_in(compiled, [:workflow_module_resolution, :module_names], [42])

    defp inject_compile_fault(compiled, "resolution_refs_not_list"),
      do: put_in(compiled, [:workflow_module_resolution, :module_refs], "not-a-list")

    defp inject_compile_fault(compiled, "resolution_invalid_ref"),
      do: put_in(compiled, [:workflow_module_resolution, :module_refs], [{:invalid}])

    defp inject_compile_fault(compiled, "resolution_non_string_ref_key") do
      put_in(
        compiled,
        [:workflow_module_resolution, :module_refs],
        [%{1 => "invalid", name: "module", version: "v1"}]
      )
    end

    defp inject_compile_fault(compiled, "resolution_key_collision") do
      update_in(
        compiled,
        [:workflow_module_resolution],
        &Map.put(&1, "policy_hash", &1.policy_hash)
      )
    end

    defp inject_compile_fault(compiled, "resolution_invalid_utf8"),
      do: put_in(compiled, [:workflow_module_resolution, :rendered], <<0xFF>>)

    defp inject_compile_fault(compiled, fault)
         when fault in [
                "resolution_metadata_a",
                "resolution_metadata_b",
                "resolution_effective_base",
                "resolution_identity",
                "resolution_version",
                "resolution_rendered",
                "resolution_policy_hash",
                "resolution_string_keys"
              ] do
      compiled
      |> put_in([:config, "manifest", "project", "name"], "Symphony Fixture")
      |> mutate_resolution(fault)
    end

    defp inject_compile_fault(compiled, _fault), do: compiled

    defp mutate_resolution(compiled, "resolution_metadata_a") do
      update_in(compiled, [:workflow_module_resolution, :modules], fn [module | rest] ->
        [
          Map.merge(module, %{
            description: "metadata a",
            default: true,
            prompt_sections: ["a"],
            compatibility: %{"runner" => "a"},
            pins: ["a"]
          })
          | rest
        ]
      end)
    end

    defp mutate_resolution(compiled, "resolution_metadata_b") do
      update_in(compiled, [:workflow_module_resolution, :modules], fn [module | rest] ->
        [
          Map.merge(module, %{
            description: "metadata b",
            default: false,
            prompt_sections: ["b"],
            compatibility: %{"runner" => "b"},
            pins: ["b"]
          })
          | rest
        ]
      end)
    end

    defp mutate_resolution(compiled, "resolution_effective_base"), do: compiled

    defp mutate_resolution(compiled, "resolution_string_keys") do
      update_in(compiled, [:workflow_module_resolution], fn resolution ->
        Map.new(resolution, fn
          {:module_refs, refs} ->
            {"module_refs", Enum.map(refs, &Map.new(&1, fn {key, value} -> {to_string(key), value} end))}

          {key, value} ->
            {to_string(key), value}
        end)
      end)
    end

    defp mutate_resolution(compiled, "resolution_identity") do
      compiled
      |> put_in([:workflow_module_resolution, :module_names], ["changed-module"])
      |> put_in([:workflow_module_resolution, :module_refs], [%{name: "changed-module", version: "v1"}])
    end

    defp mutate_resolution(compiled, "resolution_version") do
      update_in(compiled, [:workflow_module_resolution, :module_refs], fn [ref | rest] ->
        [Map.put(ref, :version, "v2") | rest]
      end)
    end

    defp mutate_resolution(compiled, "resolution_rendered"),
      do: put_in(compiled, [:workflow_module_resolution, :rendered], "changed rendered policy")

    defp mutate_resolution(compiled, "resolution_policy_hash") do
      put_in(
        compiled,
        [:workflow_module_resolution, :policy_hash],
        "sha256:" <> String.duplicate("f", 64)
      )
    end

    defp fault(manifest), do: get_in(manifest, ["project", "name"])
  end

  @fixture_root Path.expand("../../fixtures/target_registry/repos", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    repos = Path.join(tmp_dir, "repos")
    File.mkdir_p!(repos)
    File.cp_r!(Path.join(@fixture_root, "symphony"), Path.join(repos, "symphony"))
    File.cp_r!(Path.join(@fixture_root, "other"), Path.join(repos, "other"))

    {:ok,
     paths: %{
       symphony: Path.join(repos, "symphony"),
       other: Path.join(repos, "other"),
       worktree: Path.join(tmp_dir, "worktrees")
     }}
  end

  @tag :tmp_dir
  test "composes the current committed repository manifest", %{paths: paths} do
    target =
      target("alpha", paths.symphony, paths.worktree, %{
        diagnostics: [
          diagnostic(
            "alpha",
            "$.targets.alpha.repo.expected_repository",
            :repository_mismatch,
            "stale composition diagnostic"
          ),
          %{"not" => "a diagnostic"}
        ]
      })

    snapshot = snapshot(%{"alpha" => target})

    assert %Snapshot{targets: %{"alpha" => composed}} = Composition.compose(snapshot)

    assert %Target{valid?: true, effective_state: :active, diagnostics: []} = composed
    assert composed.repo_manifest["project"]["repository"] == "https://github.com/example/symphony-fixture"
    assert "product_visual_review" in composed.repo_manifest["workflow"]["modules"]

    assert get_in(composed.effective_policy, ["repo_policy", "manifest"]) == composed.repo_manifest
    assert get_in(composed.effective_policy, ["tracker_connection", "id"]) == "linear-primary"
    assert get_in(composed.effective_policy, ["runner_policy", "default"]) == "codex"
    assert get_in(composed.effective_policy, ["runner_policy", "runners", "codex", "model"]) == "test-model"
    assert get_in(composed.effective_policy, ["capacity_limits", "max_concurrent_agents"]) == 2
    assert get_in(composed.effective_policy, ["budget_limits", "per_run", "max_total_tokens"]) == 1_000
    assert get_in(composed.effective_policy, ["external_side_effect_gates", "merge"]) == "manual_approval"
    assert composed.policy_hash =~ ~r/^sha256:[0-9a-f]{64}$/
  end

  @tag :tmp_dir
  test "quarantines a semantically invalid committed manifest with precise paths", %{paths: paths} do
    File.write!(Path.join(paths.symphony, "symphony.yml"), """
    version: 1
    project:
      repository: https://github.com/example/symphony-fixture
    runtime:
      tracker:
        kind: linear
    """)

    snapshot = snapshot(%{"alpha" => target("alpha", paths.symphony, paths.worktree)})
    composed = Composition.compose(snapshot)
    quarantined = composed.targets["alpha"]

    assert %Target{
             configured_state: :active,
             effective_state: :paused,
             valid?: false,
             repo_manifest: nil,
             effective_policy: nil,
             policy_hash: nil
           } = quarantined

    assert Enum.map(quarantined.diagnostics, &diagnostic_tuple/1) == [
             {
               :error,
               {:target, "alpha"},
               "$.targets.alpha.repo.manifest.runtime",
               :manifest_invalid,
               "current repository manifest is runtime setup, not repo setup"
             },
             {
               :error,
               {:target, "alpha"},
               "$.targets.alpha.repo.manifest.runtime.tracker",
               :manifest_invalid,
               "current repository manifest is runtime setup, not repo setup"
             }
           ]

    assert composed.diagnostics == quarantined.diagnostics
  end

  @tag :tmp_dir
  test "quarantines a missing configured manifest without probing alternatives", %{paths: paths} do
    target =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{"repo" => %{"manifest" => "policy/current.yml"}}
      })

    composed = Composition.compose(snapshot(%{"alpha" => target}))
    quarantined = composed.targets["alpha"]

    assert %Target{valid?: false, effective_state: :paused} = quarantined

    assert quarantined.diagnostics == [
             diagnostic(
               "alpha",
               "$.targets.alpha.repo.manifest",
               :manifest_not_found,
               "current repository manifest policy/current.yml is missing"
             )
           ]
  end

  @tag :tmp_dir
  test "accepts every supported GitHub repository identity form case-insensitively", %{paths: paths} do
    identities = [
      "https://github.com/EXAMPLE/SYMPHONY-FIXTURE.git/",
      "git@github.com:example/symphony-fixture.git",
      "ssh://git@github.com/example/symphony-fixture",
      "github.com/example/symphony-fixture/"
    ]

    for {identity, index} <- Enum.with_index(identities) do
      id = "identity-#{index}"

      target =
        target(id, paths.symphony, paths.worktree, %{
          configured: %{"repo" => %{"expected_repository" => identity}}
        })

      assert %Target{valid?: true, policy_hash: "sha256:" <> _digest} =
               Composition.compose(snapshot(%{id => target})).targets[id]
    end
  end

  @tag :tmp_dir
  test "quarantines an expected repository identity mismatch", %{paths: paths} do
    target =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{
          "repo" => %{"expected_repository" => "https://github.com/example/other-fixture"}
        }
      })

    quarantined = Composition.compose(snapshot(%{"alpha" => target})).targets["alpha"]

    assert %Target{configured_state: :active, effective_state: :paused, valid?: false} = quarantined

    assert quarantined.diagnostics == [
             diagnostic(
               "alpha",
               "$.targets.alpha.repo.expected_repository",
               :repository_mismatch,
               "expected repository example/other-fixture does not match current repository example/symphony-fixture"
             )
           ]
  end

  @tag :tmp_dir
  test "unions target labels with current repository issue markers", %{paths: paths} do
    target =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{
          "linear" => %{
            "required_labels" => [" Host:Required ", "NEEDS-REVIEW", "host:required"]
          }
        }
      })

    composed = Composition.compose(snapshot(%{"alpha" => target})).targets["alpha"]

    assert get_in(composed.effective_policy, ["run_target", "required_labels"]) == [
             "host:required",
             "needs-review",
             "repo:symphony-fixture"
           ]

    assert get_in(composed.effective_policy, ["repo_policy", "manifest", "issue_markers", "labels"]) == [
             "repo:symphony-fixture",
             "needs-review"
           ]
  end

  @tag :tmp_dir
  test "preserves repository authority and includes only committed policy plus module resolution", %{paths: paths} do
    composed =
      Composition.compose(snapshot(%{"alpha" => target("alpha", paths.symphony, paths.worktree)})).targets["alpha"]

    repo_policy = composed.effective_policy["repo_policy"]
    manifest = repo_policy["manifest"]
    module_resolution = repo_policy["workflow_module_resolution"]

    assert Map.keys(repo_policy) |> Enum.sort() == [
             "manifest",
             "manifest_source_dir",
             "workflow_module_resolution"
           ]

    assert repo_policy["manifest_source_dir"] == paths.symphony
    assert manifest == composed.repo_manifest
    assert manifest["workflow"]["config"]["product_visual_review"]["enabled"]
    assert manifest["validation"]["commands"] == [%{"name" => "focused", "command" => "mix test"}]
    assert manifest["vcs"] == %{"mode" => "git", "default_branch" => "main"}
    assert manifest["delivery"] == %{"pr_target" => "main"}
    assert manifest["capabilities"] == %{"required" => ["github_pr", "browser"]}
    assert manifest["issue_markers"]["labels"] == ["repo:symphony-fixture", "needs-review"]

    assert Map.keys(module_resolution) |> Enum.sort() == [
             "module_names",
             "module_refs",
             "policy_hash",
             "rendered"
           ]

    assert Enum.all?(module_resolution["module_refs"], fn ref ->
             Map.keys(ref) |> Enum.sort() == ["name", "version"]
           end)

    assert "product_visual_review" in module_resolution["module_names"]
    assert value_paths(composed.effective_policy, composed.repo_manifest) == [["repo_policy", "manifest"]]

    for excluded_source <- ~w(tracker workspace polling runtime) do
      assert key_paths(composed.effective_policy, excluded_source) == []
    end

    assert composed.effective_policy["effective_checks"] == %{
             "repository" => %{
               "validation" => [%{"name" => "focused", "command" => "mix test"}],
               "auto_land" => ["fixture-ci"]
             },
             "target" => target("alpha", paths.symphony, paths.worktree).configured["checks"]
           }

    assert composed.effective_policy["worktree_policy"] ==
             target("alpha", paths.symphony, paths.worktree).configured["worktree"]

    assert composed.effective_policy["worktree_policy"]["strategy"] == "per_issue"
    assert composed.effective_policy["runner_policy"]["allowed"] == ["codex"]
  end

  @tag :tmp_dir
  test "target runner tuning preserves host controls and allows canonical target-only safe tuning", %{paths: paths} do
    host =
      put_in(host(), ["runners", "codex", "execution_profiles"], %{
        "implementation" => %{
          "model" => "host-model",
          "reasoning_effort" => "medium",
          "budget" => "restricted",
          "timeout_ms" => 30_000,
          "max_retries" => 0,
          "command" => ["codex", "--restricted", "app-server"],
          "approval_policy" => "never",
          "thread_sandbox" => "workspace-write",
          "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => false}
        },
        "source_reviewer" => %{
          "model" => "review-model",
          "reasoning_effort" => "high",
          "command" => ["codex", "--read-only", "app-server"]
        }
      })

    target =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{
          "runners" => %{
            "settings" => %{
              "codex" => %{
                "model" => "target-model",
                "reasoning_effort" => "high",
                "max_turns" => 7,
                "execution_profiles" => %{
                  "implementation" => %{
                    "model" => "target-implementation-model",
                    "reasoning_effort" => "xhigh",
                    "budget" => "unlimited",
                    "timeout_ms" => 300_000,
                    "max_retries" => 9,
                    "command" => ["unsafe", "adapter"],
                    "approval_policy" => "on-request",
                    "thread_sandbox" => "danger-full-access",
                    "turn_sandbox_policy" => %{"type" => "dangerFullAccess"}
                  },
                  " Source-Reviewer " => %{"model" => "target-review-model"},
                  " Target-Only " => %{
                    "model" => "target-only-model",
                    "reasoning_effort" => "low",
                    "command" => ["unsafe", "target-only"]
                  },
                  "malformed" => :invalid
                }
              }
            }
          }
        }
      })

    runner =
      Composition.compose(snapshot(%{"alpha" => target}, %{host: host}))
      |> get_in([Access.key!(:targets), "alpha", Access.key!(:effective_policy), "runner_policy", "runners", "codex"])

    assert Map.take(runner, [
             "kind",
             "command",
             "approval_policy",
             "thread_sandbox",
             "turn_sandbox_policy",
             "model",
             "reasoning_effort",
             "max_turns"
           ]) == %{
             "kind" => "codex_app_server",
             "command" => ["codex", "app-server"],
             "approval_policy" => "never",
             "thread_sandbox" => "workspace-write",
             "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => false},
             "model" => "target-model",
             "reasoning_effort" => "high",
             "max_turns" => 7
           }

    assert runner["execution_profiles"] == %{
             "implementation" => %{
               "model" => "target-implementation-model",
               "reasoning_effort" => "xhigh",
               "budget" => "restricted",
               "timeout_ms" => 30_000,
               "max_retries" => 0,
               "command" => ["codex", "--restricted", "app-server"],
               "approval_policy" => "never",
               "thread_sandbox" => "workspace-write",
               "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => false}
             },
             "source_reviewer" => %{
               "model" => "target-review-model",
               "reasoning_effort" => "high",
               "command" => ["codex", "--read-only", "app-server"]
             },
             "target_only" => %{
               "model" => "target-only-model",
               "reasoning_effort" => "low"
             }
           }

    profile_names = Map.keys(runner["execution_profiles"])
    assert Enum.map(profile_names, &normalize_profile_name/1) == profile_names
    assert Enum.uniq_by(profile_names, &normalize_profile_name/1) == profile_names
  end

  @tag :tmp_dir
  test "profile aliases collide with a generic deterministic diagnostic", %{paths: paths} do
    cases = [
      {
        :host,
        [
          {"source_reviewer", %{"model" => "canonical"}},
          {"source-reviewer", %{"model" => "hyphen"}}
        ]
      },
      {
        :target,
        [
          {"source_reviewer", %{"model" => "canonical"}},
          {" Source-Reviewer ", %{"model" => "spaced"}}
        ]
      },
      {
        :target,
        [
          {"implementation", %{"model" => "canonical"}},
          {"  ", %{"model" => "spaced"}}
        ]
      }
    ]

    for {source, entries} <- cases,
        ordered_entries <- [entries, Enum.reverse(entries)] do
      profiles = Map.new(ordered_entries)

      {host, target} =
        case source do
          :host ->
            {
              put_in(host(), ["runners", "codex", "execution_profiles"], profiles),
              target("alpha", paths.symphony, paths.worktree)
            }

          :target ->
            {
              host(),
              target("alpha", paths.symphony, paths.worktree, %{
                configured: %{
                  "runners" => %{
                    "settings" => %{"codex" => %{"execution_profiles" => profiles}}
                  }
                }
              })
            }
        end

      composed = Composition.compose(snapshot(%{"alpha" => target}, %{host: host}))
      quarantined = composed.targets["alpha"]

      assert %Target{
               valid?: false,
               effective_state: :paused,
               repo_manifest: nil,
               effective_policy: nil,
               policy_hash: nil
             } = quarantined

      assert quarantined.diagnostics == [
               diagnostic(
                 "alpha",
                 "$.targets.alpha.runners.settings.codex.execution_profiles",
                 :execution_profile_name_collision,
                 "execution profile names collide after normalization"
               )
             ]

      assert composed.diagnostics == quarantined.diagnostics
    end
  end

  @tag :tmp_dir
  test "profile collision diagnostics do not disclose alias key contents", %{paths: paths} do
    secret = "secret-token-8472"

    profiles = %{
      "api-key-#{secret}" => %{"model" => "first"},
      "api_key_#{secret}" => %{"model" => "second"}
    }

    target =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{
          "runners" => %{
            "settings" => %{"codex" => %{"execution_profiles" => profiles}}
          }
        }
      })

    composed = Composition.compose(snapshot(%{"alpha" => target}))

    expected = [
      diagnostic(
        "alpha",
        "$.targets.alpha.runners.settings.codex.execution_profiles",
        :execution_profile_name_collision,
        "execution profile names collide after normalization"
      )
    ]

    assert composed.targets["alpha"].diagnostics == expected
    assert composed.diagnostics == expected

    diagnostic_text = inspect(expected)
    refute diagnostic_text =~ secret
    refute diagnostic_text =~ "api-key"
    refute diagnostic_text =~ "api_key"
  end

  @tag :tmp_dir
  test "quarantines malformed runner composition inputs deterministically", %{paths: paths} do
    base_target = target("alpha", paths.symphony, paths.worktree)

    invalid_host_runner = put_in(host(), ["runners", "codex"], :invalid)

    invalid_host_profile =
      put_in(host(), ["runners", "codex", "execution_profiles"], %{
        "source_reviewer" => :invalid
      })

    target_profile =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{
          "runners" => %{
            "settings" => %{
              "codex" => %{
                "execution_profiles" => %{
                  "source_reviewer" => %{"model" => "target-model"}
                }
              }
            }
          }
        }
      })

    invalid_profile_name =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{
          "runners" => %{
            "settings" => %{
              "codex" => %{
                "execution_profiles" => %{{:invalid, :name} => %{}}
              }
            }
          }
        }
      })

    cases = [
      {
        invalid_host_runner,
        base_target,
        "$.targets.alpha.runners.settings.codex",
        "current runner policy inputs have an invalid shape"
      },
      {
        invalid_host_profile,
        target_profile,
        "$.targets.alpha.repo.manifest",
        "composed effective policy is not JSON-safe"
      },
      {
        host(),
        invalid_profile_name,
        "$.targets.alpha.runners.settings.codex.execution_profiles",
        "target runner codex execution profile names are invalid"
      }
    ]

    for {host, target, path, message} <- cases do
      composed = Composition.compose(snapshot(%{"alpha" => target}, %{host: host}))

      assert composed.targets["alpha"].diagnostics == [
               diagnostic("alpha", path, :manifest_invalid, message)
             ]

      assert composed.diagnostics == composed.targets["alpha"].diagnostics
    end
  end

  @tag :tmp_dir
  test "rejects runtime-owned and repository-owned fields under targets", %{paths: paths} do
    configured =
      target("alpha", paths.symphony, paths.worktree).configured
      |> Map.merge(%{
        "effective_policy" => %{"issue_markers" => %{"labels" => []}},
        "runtime" => %{"tracker" => %{}},
        "workflow" => %{"modules" => []},
        "validation" => %{"commands" => []}
      })

    document = %{
      "version" => 1,
      "host" => schema_host(paths.worktree),
      "targets" => %{"alpha" => configured}
    }

    assert {:ok, snapshot} = Schema.validate(document)
    rejected = snapshot.targets["alpha"]

    assert %Target{valid?: false, effective_policy: nil, repo_manifest: nil, policy_hash: nil} =
             rejected

    assert Enum.map(rejected.diagnostics, &{&1.path, &1.code}) == [
             {"$.targets.alpha.effective_policy", :unknown_key},
             {"$.targets.alpha.runtime", :unknown_key},
             {"$.targets.alpha.validation", :unknown_key},
             {"$.targets.alpha.workflow", :unknown_key}
           ]

    assert Composition.compose(snapshot).targets["alpha"] == rejected
  end

  @tag :tmp_dir
  test "hashes canonical policy independent of map order and filesystem metadata", %{paths: paths} do
    direct_target = target("alpha", paths.symphony, paths.worktree)

    direct =
      Composition.compose(snapshot(%{"alpha" => direct_target})).targets["alpha"]

    File.touch!(Path.join(paths.symphony, "symphony.yml"), {{2030, 1, 1}, {0, 0, 0}})
    File.touch!(Path.join(paths.symphony, "README.md"), {{2030, 1, 1}, {0, 0, 0}})

    reordered_target = %{
      direct_target
      | configured: reverse_maps(direct_target.configured)
    }

    reordered =
      Composition.compose(snapshot(%{"alpha" => reordered_target}, %{host: reverse_maps(host())})).targets["alpha"]

    assert direct.policy_hash == reordered.policy_hash
    assert direct.effective_policy == reordered.effective_policy

    restricted_target =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{"linear" => %{"required_labels" => ["host:other"]}}
      })

    restricted =
      Composition.compose(snapshot(%{"alpha" => restricted_target})).targets["alpha"]

    refute direct.policy_hash == restricted.policy_hash
  end

  @tag :tmp_dir
  test "manifest source, hooks, and timeout rotate the policy hash", %{paths: paths} do
    base_target = target("alpha", paths.symphony, paths.worktree)
    base = Composition.compose(snapshot(%{"alpha" => base_target})).targets["alpha"]

    nested_dir = Path.join(paths.symphony, "policy")
    File.mkdir_p!(nested_dir)
    File.cp!(Path.join(paths.symphony, "symphony.yml"), Path.join(nested_dir, "current.yml"))

    nested_target =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{"repo" => %{"manifest" => "policy/current.yml"}}
      })

    nested = Composition.compose(snapshot(%{"alpha" => nested_target})).targets["alpha"]

    command_target =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{
          "worktree" => %{
            "hooks" => %{"before_run" => "printf 'token=sk-test-composition-hook'"}
          }
        }
      })

    command = Composition.compose(snapshot(%{"alpha" => command_target})).targets["alpha"]

    timeout_target =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{"worktree" => %{"hooks" => %{"timeout_ms" => 12_345}}}
      })

    timeout = Composition.compose(snapshot(%{"alpha" => timeout_target})).targets["alpha"]

    assert nested.repo_manifest == base.repo_manifest
    assert get_in(nested.effective_policy, ["repo_policy", "manifest_source_dir"]) == nested_dir
    refute nested.policy_hash == base.policy_hash
    refute command.policy_hash == base.policy_hash
    refute timeout.policy_hash == base.policy_hash
  end

  @tag :tmp_dir
  test "exposes the existing canonical JSON hash as a total public helper" do
    ordered = %{"a" => 1, "b" => [true, nil]}
    reordered = Map.new([{"b", [true, nil]}, {"a", 1}])

    nested = %{
      "nested" => [%{"float" => 1.5, "integer" => -2}, "value"],
      "zero" => 0.0
    }

    expected = "sha256:1cc69c7fa23616ca2ec3ee70d24390a6225c8832db8a4c814c7e0e7f942f8668"
    assert {:ok, ^expected} = Composition.canonical_hash(ordered)
    assert {:ok, ^expected} = Composition.canonical_hash(reordered)

    nested_expected =
      "sha256:c4badfa82403976214f10cc73bb8fd3c6ddcefbe7dd85ced8c8b241adda7bc76"

    assert {:ok, ^nested_expected} = Composition.canonical_hash(nested)

    for unsafe <- [
          fn -> :private end,
          ["valid" | :invalid],
          %{1 => "invalid"},
          %{key: "invalid"},
          %{"key" => 1, key: 2},
          %{<<0xFF>> => "invalid UTF-8 key"},
          %{"value" => <<0xFF>>}
        ] do
      assert {:error, :not_json_safe} = Composition.canonical_hash(unsafe)
    end
  end

  @tag :tmp_dir
  test "verifies a selected composed target against Phase 1 schema and composition authority", %{paths: paths} do
    composed = validated_composed_snapshot(paths)

    assert :ok = Composition.verify_composed_target(composed, "alpha")

    for policy_path <- [
          ["repo_policy", "manifest_source_dir"],
          ["worktree_policy", "hooks", "before_run"],
          ["worktree_policy", "hooks", "timeout_ms"],
          ["runner_policy", "default"],
          ["capacity_limits", "max_concurrent_agents"],
          ["tracker_connection", "policy", "endpoint"],
          ["external_side_effect_gates", "merge"]
        ] do
      forged = forge_selected_policy(composed, policy_path, "forged")

      assert {:error, :invalid_composed_target} =
               Composition.verify_composed_target(forged, "alpha")
    end
  end

  @tag :tmp_dir
  test "rejects composed targets that fail Phase 1 cross-field validation", %{paths: paths} do
    composed = validated_composed_snapshot(paths)
    target = composed.targets["alpha"]

    excessive_capacity =
      forge_configured_policy(
        composed,
        ["concurrency", "max_concurrent_agents"],
        5,
        ["capacity_limits", "max_concurrent_agents"],
        5
      )

    contradictory_budget =
      forge_configured_policy(
        composed,
        ["budgets", "daily", "max_total_tokens"],
        500,
        ["budget_limits", "daily", "max_total_tokens"],
        500
      )

    unknown_tracker =
      forge_configured_policy(
        composed,
        ["linear", "connection"],
        "missing-tracker",
        ["tracker_connection"],
        %{"id" => "missing-tracker", "policy" => nil}
      )

    unknown_runner =
      put_selected_target(composed, %{
        target
        | configured:
            put_in(
              target.configured,
              ["runners", "settings", "missing-runner"],
              %{"model" => "private-runner-model"}
            )
      })

    unsafe_repo =
      put_selected_target(composed, %{
        target
        | configured:
            put_in(
              target.configured,
              ["repo", "path"],
              Path.join(paths.worktree, "missing-repository")
            )
      })

    overlapping_roots =
      forge_configured_policy(
        composed,
        ["worktree", "root"],
        paths.symphony,
        ["worktree_policy", "root"],
        paths.symphony
      )

    for forged <- [
          excessive_capacity,
          contradictory_budget,
          unknown_tracker,
          unknown_runner,
          unsafe_repo,
          overlapping_roots
        ] do
      result = Composition.verify_composed_target(forged, "alpha")
      assert result == {:error, :invalid_composed_target}
      refute inspect(result) =~ "private-runner-model"
    end
  end

  @tag :tmp_dir
  test "rejects a selected target overlapped by an unselected target root", %{paths: paths} do
    composed = validated_two_target_composed_snapshot(paths)
    beta = composed.targets["beta"]
    alpha_root = get_in(composed.targets["alpha"].configured, ["worktree", "root"])

    forged =
      put_in(
        composed.targets["beta"],
        %{beta | configured: put_in(beta.configured, ["worktree", "root"], alpha_root)}
      )

    assert {:error, :invalid_composed_target} =
             Composition.verify_composed_target(forged, "alpha")
  end

  @tag :tmp_dir
  test "accepts a valid selected target beside an unrelated composition quarantine", %{paths: paths} do
    beta = target("beta", paths.other, paths.worktree)

    composed =
      validated_composed_snapshot(paths, %{
        "alpha" => target("alpha", paths.symphony, paths.worktree).configured,
        "beta" => beta.configured
      })

    assert %Target{valid?: false, effective_state: :paused} = composed.targets["beta"]
    assert :ok = Composition.verify_composed_target(composed, "alpha")
  end

  @tag :tmp_dir
  test "contains hostile target enumerables without disclosing their reasons", %{paths: paths} do
    composed = validated_composed_snapshot(paths)
    private_reason = "private-enumerable-reason"

    hostile_streams = [
      Stream.map([:trigger], fn _value -> throw(private_reason) end),
      Stream.map([:trigger], fn _value -> exit(private_reason) end)
    ]

    for hostile <- hostile_streams do
      snapshot = %{composed | targets: hostile}
      result = Composition.verify_composed_target(snapshot, "alpha")

      assert result == {:error, :invalid_composed_target}
      refute inspect(result) =~ private_reason
    end
  end

  @tag :tmp_dir
  test "rejects forged snapshot provenance and diagnostic seams without disclosure", %{paths: paths} do
    composed = validated_composed_snapshot(paths)
    target = composed.targets["alpha"]

    coherent_diagnostic =
      %Diagnostic{
        severity: :info,
        scope: {:target, "alpha"},
        path: "$.targets.alpha",
        code: :forged,
        message: "attacker-private-value"
      }

    cases = [
      %{composed | host: put_in(composed.host, ["runners", "codex", "command"], ["forged-runner"])},
      put_in(composed.targets["alpha"].configured["scheduling"]["weight"], 99),
      put_in(composed.targets["alpha"].diagnostics, [coherent_diagnostic]),
      %{composed | diagnostics: [coherent_diagnostic]},
      %{
        composed
        | targets: %{"alpha" => %{target | diagnostics: [coherent_diagnostic]}},
          diagnostics: [coherent_diagnostic]
      },
      %{composed | diagnostics: [%{"message" => "attacker-private-value"}]},
      %{composed | targets: %{"alpha" => %{target | diagnostics: [:malformed]}}},
      %{composed | targets: %{"alpha" => %{target | valid?: false}}},
      %{composed | targets: %{"alpha" => :malformed}}
    ]

    for forged <- cases do
      result = Composition.verify_composed_target(forged, "alpha")
      assert result == {:error, :invalid_composed_target}
      refute inspect(result) =~ "attacker-private-value"
    end
  end

  @tag :tmp_dir
  test "rejects malformed manifest, module resolution, and normalized Phase 1 inputs", %{paths: paths} do
    composed = validated_composed_snapshot(paths)
    target = composed.targets["alpha"]
    resolution_path = ["repo_policy", "workflow_module_resolution"]

    malformed_resolutions = [
      Map.put(get_in(target.effective_policy, resolution_path), "extra", true),
      Map.put(get_in(target.effective_policy, resolution_path), :rendered, "duplicate"),
      Map.delete(get_in(target.effective_policy, resolution_path), "module_refs")
    ]

    cases =
      Enum.map(malformed_resolutions, fn resolution ->
        policy = put_in(target.effective_policy, resolution_path, resolution)

        policy_hash =
          case Composition.canonical_hash(policy) do
            {:ok, hash} -> hash
            {:error, :not_json_safe} -> target.policy_hash
          end

        put_selected_target(composed, %{target | effective_policy: policy, policy_hash: policy_hash})
      end) ++
        [
          invalid_manifest_snapshot(composed),
          put_selected_target(composed, %{target | effective_policy: %{}}),
          put_in(composed.targets["alpha"].configured["repo"]["path"], "~/forged-repo"),
          put_in(composed.host["state_root"], "~/forged-state"),
          put_in(composed.host["runners"]["codex"]["command"], ["codex" | :malformed]),
          %{composed | targets: Map.put(composed.targets, "unexpected", %{})}
        ]

    for forged <- cases do
      assert {:error, :invalid_composed_target} =
               Composition.verify_composed_target(forged, "alpha")
    end

    assert {:error, :invalid_composed_target} =
             Composition.verify_composed_target(composed, :alpha)

    assert {:error, :invalid_composed_target} =
             Composition.verify_composed_target(%{}, "alpha")
  end

  @tag :tmp_dir
  test "projects only effective module resolution fields into policy and hash", %{paths: paths} do
    compose_fault = fn fault ->
      write_fault_manifest!(paths.symphony, fault)

      Composition.compose(
        snapshot(%{"alpha" => target("alpha", paths.symphony, paths.worktree)}),
        manifest: LocalManifestAdapter
      ).targets["alpha"]
    end

    metadata_a = compose_fault.("resolution_metadata_a")
    metadata_b = compose_fault.("resolution_metadata_b")

    assert metadata_a.valid?
    assert metadata_b.valid?
    assert metadata_a.effective_policy == metadata_b.effective_policy
    assert metadata_a.policy_hash == metadata_b.policy_hash

    projection = get_in(metadata_a.effective_policy, ["repo_policy", "workflow_module_resolution"])

    assert Map.keys(projection) |> Enum.sort() == [
             "module_names",
             "module_refs",
             "policy_hash",
             "rendered"
           ]

    assert Enum.all?(projection["module_refs"], fn ref ->
             Map.keys(ref) |> Enum.sort() == ["name", "version"]
           end)

    base = compose_fault.("resolution_effective_base")
    string_keys = compose_fault.("resolution_string_keys")
    assert string_keys.effective_policy == base.effective_policy
    assert string_keys.policy_hash == base.policy_hash

    for fault <- ~w(
          resolution_identity
          resolution_version
          resolution_rendered
          resolution_policy_hash
        ) do
      changed = compose_fault.(fault)
      assert changed.valid?
      refute changed.effective_policy == base.effective_policy
      refute changed.policy_hash == base.policy_hash
    end
  end

  @tag :tmp_dir
  test "quarantines only malformed compiled nested policy output", %{paths: paths} do
    good =
      target("good", paths.other, paths.worktree, %{
        configured: %{
          "repo" => %{"expected_repository" => "https://github.com/example/other-fixture"}
        }
      })

    faults = ~w(
      manifest_labels_not_list
      manifest_repository_not_string
      manifest_required_checks_not_list
      manifest_review_paths_not_list
      manifest_auto_land_invalid
      manifest_improper_list
      manifest_json_improper_list
      manifest_function
      manifest_tuple
      resolution_names_not_list
      resolution_invalid_name
      resolution_refs_not_list
      resolution_invalid_ref
      resolution_non_string_ref_key
    )

    command_faults = ~w(
      manifest_validation_command_not_map
      manifest_validation_command_missing_name
      manifest_validation_command_missing_command
      manifest_validation_command_name_not_string
      manifest_validation_command_command_not_string
      manifest_validation_command_unknown_field
      manifest_validation_command_non_string_key
    )

    faults = faults ++ command_faults

    for fault <- faults do
      write_fault_manifest!(paths.symphony, fault)

      composed =
        Composition.compose(
          snapshot(%{
            "bad" => target("bad", paths.symphony, paths.worktree),
            "good" => good
          }),
          manifest: LocalManifestAdapter
        )

      assert %Target{valid?: true, effective_state: :active, diagnostics: []} =
               composed.targets["good"]

      assert_manifest_invalid_target(
        composed,
        "current repository manifest compiled result has an invalid shape"
      )
    end

    write_fault_manifest!(paths.symphony, "Symphony Fixture")

    bad_labels =
      target("bad", paths.symphony, paths.worktree, %{
        configured: %{"linear" => %{"required_labels" => "not-a-list"}}
      })

    composed = Composition.compose(snapshot(%{"bad" => bad_labels, "good" => good}))

    assert %Target{valid?: true, effective_state: :active, diagnostics: []} =
             composed.targets["good"]

    assert_manifest_invalid_target(
      composed,
      "current target policy inputs have an invalid shape",
      "$.targets.bad.linear.required_labels"
    )
  end

  @tag :tmp_dir
  test "rejects atom and string JSON key collisions before projection or hashing", %{paths: paths} do
    good =
      target("good", paths.other, paths.worktree, %{
        configured: %{
          "repo" => %{"expected_repository" => "https://github.com/example/other-fixture"}
        }
      })

    for fault <- ["manifest_non_string_key", "resolution_key_collision"] do
      write_fault_manifest!(paths.symphony, fault)

      composed =
        Composition.compose(
          snapshot(%{
            "bad" => target("bad", paths.symphony, paths.worktree),
            "good" => good
          }),
          manifest: LocalManifestAdapter
        )

      assert %Target{valid?: true, effective_state: :active, diagnostics: []} =
               composed.targets["good"]

      assert_manifest_invalid_target(
        composed,
        "current repository manifest compiled result has an invalid shape"
      )
    end

    write_fault_manifest!(paths.symphony, "Symphony Fixture")

    hash_collision_values = [
      %{"weight" => 2, weight: 3},
      ["valid", %{"weight" => 2, weight: 3}],
      ["valid" | :invalid]
    ]

    for scheduling <- hash_collision_values do
      hash_collision =
        target("bad", paths.symphony, paths.worktree, %{
          configured: %{"scheduling" => scheduling}
        })

      composed = Composition.compose(snapshot(%{"bad" => hash_collision, "good" => good}))

      assert %Target{valid?: true, effective_state: :active, diagnostics: []} =
               composed.targets["good"]

      assert_manifest_invalid_target(
        composed,
        "composed effective policy is not JSON-safe"
      )
    end
  end

  @tag :tmp_dir
  test "contains invalid UTF-8 at compiled and effective policy boundaries", %{paths: paths} do
    good =
      target("good", paths.other, paths.worktree, %{
        configured: %{
          "repo" => %{"expected_repository" => "https://github.com/example/other-fixture"}
        }
      })

    for fault <- ~w(manifest_invalid_utf8 manifest_invalid_utf8_key resolution_invalid_utf8) do
      write_fault_manifest!(paths.symphony, fault)

      composed =
        Composition.compose(
          snapshot(%{
            "bad" => target("bad", paths.symphony, paths.worktree),
            "good" => good
          }),
          manifest: LocalManifestAdapter
        )

      assert %Target{valid?: true, effective_state: :active, diagnostics: []} =
               composed.targets["good"]

      assert_manifest_invalid_target(
        composed,
        "current repository manifest compiled result has an invalid shape"
      )
    end

    write_fault_manifest!(paths.symphony, "Symphony Fixture")

    finite =
      target("finite", paths.symphony, paths.worktree, %{
        configured: %{"scheduling" => %{"fraction" => 1.5}}
      })

    assert %Target{valid?: true, effective_state: :active, policy_hash: "sha256:" <> _} =
             Composition.compose(snapshot(%{"finite" => finite})).targets["finite"]

    invalid_target =
      target("bad", paths.symphony, paths.worktree, %{
        configured: %{"scheduling" => %{"invalid" => <<0xFF>>}}
      })

    invalid_key_target =
      target("bad", paths.symphony, paths.worktree, %{
        configured: %{"scheduling" => %{<<0xFF>> => "invalid"}}
      })

    base_host = host()

    invalid_host =
      base_host
      |> put_in(["runners", "codex", "environment"], %{"INVALID" => <<0xFF>>})
      |> put_in(["runners", "safe"], get_in(base_host, ["runners", "codex"]))

    safe_target =
      target("good", paths.other, paths.worktree, %{
        configured: %{
          "repo" => %{"expected_repository" => "https://github.com/example/other-fixture"},
          "runners" => %{
            "default" => "safe",
            "allowed" => ["safe"],
            "settings" => %{"safe" => %{"model" => "test-model"}}
          }
        }
      })

    cases = [
      {base_host, invalid_target, good},
      {base_host, invalid_key_target, good},
      {invalid_host, target("bad", paths.symphony, paths.worktree), safe_target}
    ]

    for {case_host, bad, case_good} <- cases do
      composed =
        Composition.compose(snapshot(%{"bad" => bad, "good" => case_good}, %{host: case_host}))

      assert %Target{valid?: true, effective_state: :active, diagnostics: []} =
               composed.targets["good"]

      assert_manifest_invalid_target(composed, "composed effective policy is not JSON-safe")
    end
  end

  @tag :tmp_dir
  test "rejects non-finite floats only when the BEAM accepts their external term", %{paths: paths} do
    case LocalManifestAdapter.non_finite_float() do
      :unsupported ->
        :ok

      {:ok, non_finite} ->
        good =
          target("good", paths.other, paths.worktree, %{
            configured: %{
              "repo" => %{"expected_repository" => "https://github.com/example/other-fixture"}
            }
          })

        write_fault_manifest!(paths.symphony, "manifest_non_finite_float")

        compiled =
          Composition.compose(
            snapshot(%{
              "bad" => target("bad", paths.symphony, paths.worktree),
              "good" => good
            }),
            manifest: LocalManifestAdapter
          )

        assert %Target{valid?: true, effective_state: :active, diagnostics: []} =
                 compiled.targets["good"]

        assert_manifest_invalid_target(
          compiled,
          "current repository manifest compiled result has an invalid shape"
        )

        write_fault_manifest!(paths.symphony, "Symphony Fixture")

        invalid_target =
          target("bad", paths.symphony, paths.worktree, %{
            configured: %{"scheduling" => %{"invalid" => non_finite}}
          })

        effective =
          Composition.compose(snapshot(%{"bad" => invalid_target, "good" => good}))

        assert %Target{valid?: true, effective_state: :active, diagnostics: []} =
                 effective.targets["good"]

        assert_manifest_invalid_target(effective, "composed effective policy is not JSON-safe")
    end
  end

  @tag :tmp_dir
  test "contains manifest and identity failures to their targets with stable diagnostics", %{paths: paths} do
    existing =
      %Diagnostic{
        severity: :info,
        scope: :registry,
        path: "$",
        code: :loaded,
        message: "registry loaded"
      }

    good = target("a-good", paths.symphony, paths.worktree)
    mismatched = target("z-bad", paths.other, paths.worktree)

    snapshot =
      snapshot(
        Map.new([{"z-bad", mismatched}, {"a-good", good}]),
        %{diagnostics: [existing]}
      )

    first = Composition.compose(snapshot)
    second = Composition.compose(first)

    assert %Target{valid?: true, effective_state: :active, policy_hash: "sha256:" <> _} =
             first.targets["a-good"]

    assert %Target{
             configured_state: :active,
             effective_state: :paused,
             valid?: false,
             configured: configured,
             repo_manifest: nil,
             effective_policy: nil
           } = first.targets["z-bad"]

    assert configured == mismatched.configured
    assert first == second
    assert hd(first.diagnostics) == existing

    assert Enum.map(first.diagnostics, &{&1.scope, &1.code}) == [
             {:registry, :loaded},
             {{:target, "z-bad"}, :repository_mismatch}
           ]

    reordered =
      Composition.compose(
        snapshot(Map.new([{"a-good", good}, {"z-bad", mismatched}]), %{
          diagnostics: [existing]
        })
      )

    assert reordered.diagnostics == first.diagnostics
  end

  @tag :tmp_dir
  test "recomposes composition-only quarantines after the same snapshot manifest is repaired", %{paths: paths} do
    manifest_path = Path.join(paths.symphony, "policy/current.yml")

    target =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{"repo" => %{"manifest" => "policy/current.yml"}}
      })

    missing = Composition.compose(snapshot(%{"alpha" => target}))

    assert missing.targets["alpha"].diagnostics == [
             diagnostic(
               "alpha",
               "$.targets.alpha.repo.manifest",
               :manifest_not_found,
               "current repository manifest policy/current.yml is missing"
             )
           ]

    File.mkdir_p!(Path.dirname(manifest_path))
    File.write!(manifest_path, "version: [\n")
    invalid = Composition.compose(missing)

    assert invalid.targets["alpha"].diagnostics == [
             diagnostic(
               "alpha",
               "$.targets.alpha.repo.manifest",
               :manifest_invalid,
               "current repository manifest is invalid YAML"
             )
           ]

    File.write!(manifest_path, fixture_manifest())
    recovered = Composition.compose(invalid)

    assert %Target{
             valid?: true,
             configured_state: :active,
             effective_state: :active,
             dispatch_mode: :explicit,
             diagnostics: [],
             repo_manifest: %{},
             effective_policy: %{},
             policy_hash: "sha256:" <> _
           } = recovered.targets["alpha"]

    assert recovered.diagnostics == []
  end

  @tag :tmp_dir
  test "restores a repaired paused target without activating it", %{paths: paths} do
    manifest_path = Path.join(paths.symphony, "policy/paused.yml")

    target =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{
          "state" => "paused",
          "repo" => %{"manifest" => "policy/paused.yml"}
        },
        configured_state: :paused,
        effective_state: :paused
      })

    missing = Composition.compose(snapshot(%{"alpha" => target}))
    File.mkdir_p!(Path.dirname(manifest_path))
    File.write!(manifest_path, fixture_manifest())
    recovered = Composition.compose(missing)

    assert %Target{
             valid?: true,
             configured_state: :paused,
             effective_state: :paused,
             diagnostics: [],
             repo_manifest: %{},
             effective_policy: %{},
             policy_hash: "sha256:" <> _
           } = recovered.targets["alpha"]
  end

  @tag :tmp_dir
  test "does not revive targets with structural errors", %{paths: paths} do
    structural_diagnostic =
      diagnostic(
        "alpha",
        "$.targets.alpha.dispatch_mode",
        :missing_dispatch_mode,
        "$.targets.alpha.dispatch_mode must be explicit or watch for an active target"
      )

    invalid =
      target("alpha", paths.symphony, paths.worktree, %{
        valid?: false,
        effective_state: :paused,
        diagnostics: [structural_diagnostic]
      })

    composed = Composition.compose(snapshot(%{"alpha" => invalid}))

    assert composed.targets["alpha"] == invalid
    assert composed.diagnostics == [structural_diagnostic]
  end

  @tag :tmp_dir
  test "fails closed at every local manifest boundary without aborting other targets", %{paths: paths} do
    good =
      target("good", paths.other, paths.worktree, %{
        configured: %{
          "repo" => %{"expected_repository" => "https://github.com/example/other-fixture"}
        }
      })

    cases = [
      {"read_exception", "current repository manifest read failed"},
      {"read_unexpected", "current repository manifest read returned an invalid result"},
      {"read_shape_unexpected", "current repository manifest read returned an invalid result"},
      {"read_malformed_semantic_errors", "current repository manifest read returned malformed semantic errors"},
      {"validation_exception", "current repository manifest validation failed"},
      {"validation_unexpected", "current repository manifest validation returned an invalid result"},
      {"validation_result_unexpected", "current repository manifest validation returned an invalid result"},
      {"malformed_semantic_errors", "current repository manifest validation returned malformed semantic errors"},
      {"compile_exception", "current repository manifest compilation failed"},
      {"compile_unexpected", "current repository manifest compilation returned an invalid result"},
      {"result_unexpected", "current repository manifest compiled result has an invalid shape"},
      {"resolution_unexpected", "current repository manifest compiled result has an invalid shape"}
    ]

    for {fault, message} <- cases do
      write_fault_manifest!(paths.symphony, fault)

      composed =
        Composition.compose(
          snapshot(%{
            "bad" => target("bad", paths.symphony, paths.worktree),
            "good" => good
          }),
          manifest: LocalManifestAdapter
        )

      assert %Target{valid?: true, effective_state: :active, diagnostics: []} =
               composed.targets["good"]

      assert %Target{
               valid?: false,
               effective_state: :paused,
               repo_manifest: nil,
               effective_policy: nil,
               policy_hash: nil
             } = composed.targets["bad"]

      assert composed.targets["bad"].diagnostics == [
               diagnostic(
                 "bad",
                 "$.targets.bad.repo.manifest",
                 :manifest_invalid,
                 message
               )
             ]

      assert composed.diagnostics == composed.targets["bad"].diagnostics
    end
  end

  @tag :tmp_dir
  test "malformed already-invalid targets cannot crash or contaminate valid targets", %{paths: paths} do
    malformed =
      %{
        target("bad", paths.other, paths.worktree)
        | configured: :malformed,
          valid?: false,
          effective_state: :paused,
          diagnostics: :malformed
      }

    registry_diagnostic =
      %Diagnostic{
        severity: :warning,
        scope: :registry,
        path: "$",
        code: :existing_warning,
        message: "existing warning"
      }

    source =
      snapshot(
        %{
          "bad" => malformed,
          "good" => target("good", paths.symphony, paths.worktree),
          "raw" => :malformed
        },
        %{diagnostics: [%{"not" => "a diagnostic"}, registry_diagnostic]}
      )

    composed = Composition.compose(source)

    assert composed.targets["bad"] == malformed
    assert composed.targets["raw"] == :malformed
    assert %Target{valid?: true, effective_state: :active} = composed.targets["good"]
    assert composed.diagnostics == [registry_diagnostic]
  end

  @tag :tmp_dir
  test "converts YAML parse and repository validation failures to target diagnostics", %{paths: paths} do
    manifest_path = Path.join(paths.symphony, "symphony.yml")
    File.write!(manifest_path, "version: [\n")

    parsed = Composition.compose(snapshot(%{"alpha" => target("alpha", paths.symphony, paths.worktree)}))

    assert parsed.targets["alpha"].diagnostics == [
             diagnostic(
               "alpha",
               "$.targets.alpha.repo.manifest",
               :manifest_invalid,
               "current repository manifest is invalid YAML"
             )
           ]

    source =
      @fixture_root
      |> Path.join("symphony/symphony.yml")
      |> File.read!()
      |> String.replace("    - README.md", "    - MISSING.md")

    File.write!(manifest_path, source)
    validated = Composition.compose(snapshot(%{"alpha" => target("alpha", paths.symphony, paths.worktree)}))

    assert Enum.map(validated.targets["alpha"].diagnostics, &diagnostic_tuple/1) == [
             {
               :error,
               {:target, "alpha"},
               "$.targets.alpha.repo.manifest.docs.entrypoints[0]",
               :manifest_invalid,
               "current repository manifest missing \"MISSING.md\""
             }
           ]
  end

  @tag :tmp_dir
  test "accepts an omitted repository identity pin", %{paths: paths} do
    target =
      target("alpha", paths.symphony, paths.worktree, %{
        configured: %{"repo" => %{"expected_repository" => nil}}
      })

    assert %Target{valid?: true, policy_hash: "sha256:" <> _} =
             Composition.compose(snapshot(%{"alpha" => target})).targets["alpha"]
  end

  @tag :tmp_dir
  test "leaves globally invalid snapshots unchanged", %{paths: paths} do
    source =
      snapshot(
        %{"alpha" => target("alpha", paths.symphony, paths.worktree)},
        %{globally_valid?: false, host: :malformed, diagnostics: :malformed}
      )

    assert Composition.compose(source) == source
  end

  @tag :tmp_dir
  test "sorts every diagnostic scope and contains non-string target identifiers", %{paths: paths} do
    numeric =
      %{
        target("numeric", paths.other, paths.worktree)
        | id: 7
      }

    existing = [
      %Diagnostic{
        severity: :warning,
        scope: :other,
        path: "$.other",
        code: :other_warning,
        message: "other warning"
      },
      %Diagnostic{
        severity: :warning,
        scope: :host,
        path: "$.host",
        code: :host_warning,
        message: "host warning"
      },
      %Diagnostic{
        severity: :info,
        scope: :registry,
        path: "$",
        code: :registry_info,
        message: "registry info"
      }
    ]

    composed = Composition.compose(snapshot(%{7 => numeric}, %{diagnostics: existing}))

    assert Enum.map(composed.diagnostics, & &1.scope) == [
             :registry,
             :host,
             {:target, 7},
             :other
           ]

    assert composed.targets[7].diagnostics == [
             diagnostic(
               7,
               "$.targets[7].repo.expected_repository",
               :repository_mismatch,
               "expected repository example/symphony-fixture does not match current repository example/other-fixture"
             )
           ]
  end

  defp fixture_manifest do
    @fixture_root
    |> Path.join("symphony/symphony.yml")
    |> File.read!()
  end

  defp write_fault_manifest!(repo_path, fault) do
    source = String.replace(fixture_manifest(), "name: Symphony Fixture", "name: #{fault}")
    File.write!(Path.join(repo_path, "symphony.yml"), source)
  end

  defp assert_manifest_invalid_target(
         composed,
         message,
         path \\ "$.targets.bad.repo.manifest"
       ) do
    assert %Target{
             valid?: false,
             effective_state: :paused,
             repo_manifest: nil,
             effective_policy: nil,
             policy_hash: nil
           } = composed.targets["bad"]

    expected = [
      diagnostic(
        "bad",
        path,
        :manifest_invalid,
        message
      )
    ]

    assert composed.targets["bad"].diagnostics == expected
    assert composed.diagnostics == expected
  end

  defp normalize_profile_name(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp diagnostic_tuple(diagnostic) do
    {diagnostic.severity, diagnostic.scope, diagnostic.path, diagnostic.code, diagnostic.message}
  end

  defp value_paths(value, expected), do: value_paths(value, expected, [])

  defp value_paths(value, expected, path) when value == expected, do: [path]

  defp value_paths(value, expected, path) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} ->
      value_paths(nested, expected, path ++ [to_string(key)])
    end)
  end

  defp value_paths(value, expected, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {nested, index} -> value_paths(nested, expected, path ++ [index]) end)
  end

  defp value_paths(_value, _expected, _path), do: []

  defp key_paths(value, expected), do: key_paths(value, expected, [])

  defp key_paths(value, expected, path) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} ->
      nested_path = path ++ [to_string(key)]
      found = if to_string(key) == expected, do: [nested_path], else: []
      found ++ key_paths(nested, expected, nested_path)
    end)
  end

  defp key_paths(value, expected, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {nested, index} -> key_paths(nested, expected, path ++ [index]) end)
  end

  defp key_paths(_value, _expected, _path), do: []

  defp snapshot(targets, overrides \\ %{}) do
    base = %Snapshot{
      version: 1,
      path: nil,
      source_hash: nil,
      generation: nil,
      globally_valid?: true,
      host: host(),
      targets: targets,
      diagnostics: []
    }

    struct!(base, overrides)
  end

  defp validated_composed_snapshot(paths) do
    validated_composed_snapshot(paths, %{
      "alpha" => target("alpha", paths.symphony, paths.worktree).configured
    })
  end

  defp validated_composed_snapshot(paths, targets) do
    document = %{
      "version" => 1,
      "host" => schema_host(paths.worktree),
      "targets" => targets
    }

    assert {:ok, structured} = Schema.validate(document, home: "/deterministic-home")
    assert structured.globally_valid?
    assert structured.targets["alpha"].valid?

    composed = Composition.compose(structured)
    assert composed.targets["alpha"].valid?, inspect(composed.targets["alpha"].diagnostics)
    composed
  end

  defp validated_two_target_composed_snapshot(paths) do
    beta =
      target("beta", paths.other, paths.worktree, %{
        configured: %{
          "repo" => %{"expected_repository" => "https://github.com/example/other-fixture"}
        }
      })

    validated_composed_snapshot(paths, %{
      "alpha" => target("alpha", paths.symphony, paths.worktree).configured,
      "beta" => beta.configured
    })
  end

  defp forge_selected_policy(snapshot, path, value) do
    target = snapshot.targets["alpha"]
    policy = put_in(target.effective_policy, path, value)
    put_selected_target(snapshot, %{target | effective_policy: policy, policy_hash: canonical_hash(policy)})
  end

  defp forge_configured_policy(
         snapshot,
         configured_path,
         configured_value,
         policy_path,
         policy_value
       ) do
    target = snapshot.targets["alpha"]
    configured = put_in(target.configured, configured_path, configured_value)
    policy = put_in(target.effective_policy, policy_path, policy_value)

    put_selected_target(snapshot, %{
      target
      | configured: configured,
        effective_policy: policy,
        policy_hash: canonical_hash(policy)
    })
  end

  defp invalid_manifest_snapshot(snapshot) do
    target = snapshot.targets["alpha"]
    manifest = Map.delete(target.repo_manifest, "version")

    policy =
      put_in(target.effective_policy, ["repo_policy", "manifest"], manifest)

    put_selected_target(snapshot, %{
      target
      | repo_manifest: manifest,
        effective_policy: policy,
        policy_hash: canonical_hash(policy)
    })
  end

  defp put_selected_target(snapshot, target) do
    %{snapshot | targets: Map.put(snapshot.targets, "alpha", target)}
  end

  defp canonical_hash(term) do
    {:ok, hash} = Composition.canonical_hash(term)
    hash
  end

  defp target(id, repo_path, worktree_root, overrides \\ %{}) do
    configured = %{
      "display_name" => String.upcase(id),
      "state" => "active",
      "dispatch_mode" => "explicit",
      "repo" => %{
        "path" => repo_path,
        "manifest" => "symphony.yml",
        "expected_repository" => "git@github.com:example/symphony-fixture.git"
      },
      "worktree" => %{
        "root" => Path.join(worktree_root, id),
        "strategy" => "per_issue",
        "hooks" => %{
          "after_create" => nil,
          "before_run" => nil,
          "after_run" => nil,
          "before_remove" => nil,
          "timeout_ms" => 60_000
        }
      },
      "linear" => %{
        "connection" => "linear-primary",
        "scope" => %{"type" => "project", "project_slug" => id},
        "active_states" => ["Todo", "In Progress"],
        "terminal_states" => ["Done"],
        "required_labels" => ["host:required"]
      },
      "runners" => %{
        "default" => "codex",
        "allowed" => ["codex"],
        "settings" => %{
          "codex" => %{"model" => "test-model", "reasoning_effort" => "high", "max_turns" => 10}
        }
      },
      "concurrency" => %{
        "max_concurrent_agents" => 2,
        "max_concurrent_startups" => 1,
        "max_concurrent_reviewers" => 1,
        "by_linear_state" => %{"in progress" => 1}
      },
      "budgets" => %{
        "per_run" => %{"max_total_tokens" => 1_000},
        "daily" => %{"max_total_tokens" => 10_000},
        "weekly" => %{"max_total_tokens" => 50_000}
      },
      "checks" => %{
        "pre_dispatch" => ["capability_preflight"],
        "pre_handoff" => ["quality_gate"],
        "pre_publish" => ["publish_preflight"],
        "pre_merge" => ["pr_checks"]
      },
      "external_side_effects" => %{
        "tracker_write" => "allow",
        "vcs_publish" => "allow",
        "pull_request_write" => "allow",
        "merge" => "manual_approval",
        "deployment" => "deny",
        "production_data" => "deny"
      },
      "scheduling" => %{"weight" => 2}
    }

    %Target{
      id: id,
      configured: deep_merge(configured, Map.get(overrides, :configured, %{})),
      configured_state: Map.get(overrides, :configured_state, :active),
      effective_state: Map.get(overrides, :effective_state, :active),
      dispatch_mode: Map.get(overrides, :dispatch_mode, :explicit),
      valid?: Map.get(overrides, :valid?, true),
      repo_manifest: Map.get(overrides, :repo_manifest),
      effective_policy: Map.get(overrides, :effective_policy),
      policy_hash: Map.get(overrides, :policy_hash),
      diagnostics: Map.get(overrides, :diagnostics, [])
    }
  end

  defp host do
    %{
      "tracker_connections" => %{
        "linear-primary" => %{
          "kind" => "linear",
          "endpoint" => "https://tracker.example.invalid/graphql",
          "api_key" => "$LINEAR_API_KEY"
        }
      },
      "runners" => %{
        "codex" => %{
          "kind" => "codex_app_server",
          "command" => ["codex", "app-server"],
          "approval_policy" => "never",
          "thread_sandbox" => "workspace-write",
          "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => false},
          "max_concurrent_agents" => 4,
          "max_concurrent_startups" => 2
        }
      }
    }
  end

  defp schema_host(root) do
    Map.merge(host(), %{
      "id" => "fixture-host",
      "state_root" => Path.join(root, "state"),
      "polling" => %{"interval_ms" => 1_000, "max_concurrent_target_polls" => 2},
      "capacity" => %{
        "max_concurrent_agents" => 4,
        "max_concurrent_startups" => 2,
        "max_concurrent_reviewers" => 2
      },
      "scheduling" => %{
        "algorithm" => "weighted_deficit_round_robin",
        "max_credit_rounds" => 2
      }
    })
  end

  defp reverse_maps(value) when is_map(value) do
    value
    |> Enum.reverse()
    |> Map.new(fn {key, nested} -> {key, reverse_maps(nested)} end)
  end

  defp reverse_maps(value) when is_list(value), do: Enum.map(value, &reverse_maps/1)
  defp reverse_maps(value), do: value

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value),
        do: deep_merge(left_value, right_value),
        else: right_value
    end)
  end

  defp diagnostic(id, path, code, message) do
    %Diagnostic{severity: :error, scope: {:target, id}, path: path, code: code, message: message}
  end
end
