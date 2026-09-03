defmodule SymphonyElixir.ExecutionContextTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{ExecutionContext, Orchestrator}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TargetContext
  alias SymphonyElixir.TargetRegistry.Composition
  alias SymphonyElixir.TargetRegistry.Preview
  alias SymphonyElixir.TargetRegistry.Schema
  alias SymphonyElixir.TargetRegistry.Validation

  defmodule ManifestAdapter do
    @moduledoc false

    def read(_path, _opts), do: {:ok, manifest()}
    def validate(_repo_path, _manifest), do: %{errors: [], modules: [], preset: "default"}

    def compile(manifest) do
      %{
        config: %{"manifest" => manifest},
        workflow_module_resolution: %{
          module_names: ["quality"],
          module_refs: [%{name: "quality", version: "v1"}],
          policy_hash: "sha256:" <> String.duplicate("d", 64),
          rendered: "quality policy"
        }
      }
    end

    def manifest do
      %{
        "version" => 1,
        "project" => %{"repository" => "https://github.com/example/repo"},
        "workflow" => %{},
        "docs" => %{},
        "validation" => %{"commands" => [%{"command" => "mix test", "name" => "test"}]},
        "vcs" => %{},
        "delivery" => %{},
        "automation" => %{},
        "harness" => %{},
        "capabilities" => %{},
        "issue_markers" => %{"labels" => ["repo:required"]}
      }
    end
  end

  defmodule TypespecConsumer do
    @moduledoc false

    alias SymphonyElixir.ExecutionContext

    @type constructor_options :: ExecutionContext.constructor_options()
    @type child_options :: ExecutionContext.child_options()

    @spec implementation(ExecutionContext.implementation_role()) ::
            ExecutionContext.implementation_role()
    def implementation(role), do: role

    @spec landing(ExecutionContext.landing_role()) :: ExecutionContext.landing_role()
    def landing(role), do: role

    @spec review(ExecutionContext.review_role()) :: ExecutionContext.review_role()
    def review(role), do: role
  end

  test "exports distinct role and closed option types" do
    assert TypespecConsumer.implementation(:implementation) == :implementation
    assert TypespecConsumer.landing(:landing) == :landing
    assert TypespecConsumer.review(:source_reviewer) == :source_reviewer
    assert {:ok, types} = Code.Typespec.fetch_types(ExecutionContext)

    type_names =
      MapSet.new(types, fn {_kind, {name, _type, _args}} -> name end)

    assert MapSet.subset?(
             MapSet.new(~w(implementation_role landing_role review_role constructor_options child_options)a),
             type_names
           )
  end

  @tag :tmp_dir
  test "constructs an implementation context from pinned target policy", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    policy = %{"sandbox" => %{"network_access" => false}, "secrets" => []}

    assert {:ok, %ExecutionContext{} = context} = ExecutionContext.new(target, issue, policy: policy)
    assert context.target.target_id == "alpha"
    assert context.issue_id == "issue-407"
    assert context.issue_identifier == "SID-407"
    assert context.workspace_path == Path.join([tmp_dir, "worktrees", "alpha", "SID-407"])
    assert context.runner_name == "codex"
    assert context.runner_config["command"] == ["codex", "app-server"]
    assert context.role == :implementation
    assert context.execution_profile.name == "implementation"
    assert context.execution_profile.model == "implementation-model"
    assert context.execution_profile.command == nil
    assert context.timeout_ms == 45_000
    assert context.max_retries == 1
    assert context.worker_host == nil
    assert context.policy == policy
    assert ExecutionContext.run_id(context) == {"alpha", "issue-407"}
    assert ExecutionContext.run_id(:invalid) == nil
  end

  @tag :tmp_dir
  test "constructs a landing context for the Merging state", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-408", identifier: "SID-408", state: "Merging"}
    policy = %{"sandbox" => %{"network_access" => false}, "secrets" => []}

    assert {:ok, %ExecutionContext{} = context} = ExecutionContext.new(target, issue, policy: policy)
    assert context.role == :landing
    assert context.execution_profile.name == "landing"
    assert context.execution_profile.model == nil
    assert context.workspace_path == Path.join([tmp_dir, "worktrees", "alpha", "SID-408"])
    assert {:ok, %{role: "landing"}} = ExecutionContext.safe_provenance(context)
  end

  @tag :tmp_dir
  test "refreshes a pinned context when dispatch moves into and out of landing", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-409", identifier: "SID-409", state: "In Progress"}
    policy = %{"sandbox" => %{"network_access" => false}, "secrets" => []}

    assert {:ok, implementation} = ExecutionContext.new(target, issue, policy: policy)

    assert {:ok, landing} =
             ExecutionContext.refresh_dispatch_role(%{implementation | role: :implementation}, %{
               issue
               | state: "Merging"
             })

    assert landing.role == :landing
    assert landing.execution_profile.name == "landing"

    assert {:ok, refreshed_implementation} =
             ExecutionContext.refresh_dispatch_role(landing, %{issue | state: "Rework"})

    assert refreshed_implementation.role == :implementation
    assert refreshed_implementation.execution_profile.name == "implementation"

    assert {:error, :invalid_issue} =
             ExecutionContext.refresh_dispatch_role(implementation, %{issue | id: "other-issue"})

    assert {:error, :invalid_context} =
             ExecutionContext.refresh_dispatch_role(%{implementation | role: :landing}, issue)

    assert {:error, :invalid_context} =
             ExecutionContext.refresh_dispatch_role(:invalid, issue)
  end

  @tag :tmp_dir
  test "landing completion skips implementation publication and routing", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-410", identifier: "SID-410", state: "Merging"}
    policy = %{"sandbox" => %{"network_access" => false}, "secrets" => []}

    assert {:ok, landing} = ExecutionContext.new(target, issue, policy: policy)

    state =
      Orchestrator.complete_issue_for_test(
        %Orchestrator.State{},
        landing,
        issue,
        %{changed_files: ["lib/source.ex"], checks: [%{name: "test", status: "passed"}]}
      )

    assert MapSet.member?(state.completed, ExecutionContext.run_id(landing))
    assert state.delivery.handoff_routes == %{}
  end

  @tag :tmp_dir
  test "accepts partial and absent profiles from the Task-1 composition pipeline", %{tmp_dir: tmp_dir} do
    document =
      registry_document(tmp_dir)
      |> put_in(
        ["host", "runners", "codex", "execution_profiles"],
        %{"implementation" => %{"model" => "partial-model"}}
      )

    target = target_context!(tmp_dir, document)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}

    assert {:ok, parent} =
             ExecutionContext.new(target, issue, policy: %{"sandbox" => "restricted"})

    assert parent.execution_profile == %{
             name: "implementation",
             reasoning_effort: nil,
             budget: "standard",
             timeout_ms: 60_000,
             max_retries: 0,
             command: nil,
             model: "partial-model"
           }

    assert {:ok, child} = ExecutionContext.derive_child(parent, :source_reviewer, [])

    assert child.execution_profile == %{
             name: "source_reviewer",
             reasoning_effort: "medium",
             budget: "standard",
             timeout_ms: 60_000,
             max_retries: 0,
             command: nil,
             model: nil
           }
  end

  @tag :tmp_dir
  test "accepts canonical kind-specific fields from composed Codex and OpenCode profiles", %{tmp_dir: tmp_dir} do
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]

    codex_target = target_context!(tmp_dir)

    assert {:ok, codex_context} = ExecutionContext.new(codex_target, issue, opts)

    assert get_in(codex_context.runner_config, ["execution_profiles", "implementation", "approval_policy"]) ==
             "never"

    assert get_in(codex_context.runner_config, ["execution_profiles", "implementation", "thread_sandbox"]) ==
             "workspace-write"

    refute Map.has_key?(codex_context.execution_profile, :approval_policy)

    opencode_document =
      registry_document(tmp_dir)
      |> put_in(["host", "runners", "open"], opencode_runner())
      |> put_in(["targets", "alpha", "runners", "default"], "open")
      |> put_in(["targets", "alpha", "runners", "allowed"], ["codex", "reviewer", "open"])
      |> put_in(["targets", "alpha", "runners", "settings", "open"], %{})

    opencode_target = target_context!(tmp_dir, opencode_document)

    assert {:ok, opencode_context} = ExecutionContext.new(opencode_target, issue, opts)
    assert opencode_context.runner_config["kind"] == "opencode_server"
    refute Map.has_key?(opencode_context.execution_profile, :approval_policy)

    profile_with_extra_task_one_field =
      put_in(
        opencode_target.runner_policy,
        ["runners", "open", "execution_profiles", "implementation", "approval_policy"],
        "never"
      )

    assert {:ok, compatible_context} =
             ExecutionContext.new(
               %{opencode_target | runner_policy: profile_with_extra_task_one_field},
               issue,
               opts
             )

    refute Map.has_key?(compatible_context.execution_profile, :approval_policy)
  end

  @tag :tmp_dir
  test "rejects missing, duplicate, unknown, and malformed constructor options", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    policy = %{"sandbox" => %{"network_access" => false}}

    assert ExecutionContext.new(target, issue, []) == {:error, :missing_policy}
    assert ExecutionContext.new(target, issue, policy: policy, policy: policy) == {:error, :duplicate_option}
    assert ExecutionContext.new(target, issue, policy: policy, timeout_ms: 1) == {:error, :unknown_option}
    assert ExecutionContext.new(target, issue, [:not_a_pair]) == {:error, :invalid_options}
    assert ExecutionContext.new(target, issue, %{policy: policy}) == {:error, :invalid_options}
  end

  @tag :tmp_dir
  test "rejects hostile target identity and generation state", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]

    assert ExecutionContext.new(%{target | target_id: "../alpha"}, issue, opts) == {:error, :invalid_target}
    assert ExecutionContext.new(%{target | registry_generation: "current"}, issue, opts) == {:error, :invalid_target}
    assert ExecutionContext.new(%{target | policy_hash: nil}, issue, opts) == {:error, :invalid_target}
    assert ExecutionContext.new(%{target | repo_manifest_hash: <<0xFF>>}, issue, opts) == {:error, :invalid_target}
    assert ExecutionContext.new(%{}, issue, opts) == {:error, :invalid_target}
  end

  @tag :tmp_dir
  test "accepts non-dispatching lifecycle states and rejects unknown states", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]

    for state <- [:paused, :draining, :retired] do
      assert {:ok, context} =
               ExecutionContext.new(%{target | state: state, dispatch_mode: nil}, issue, opts)

      assert context.target.state == state
      assert context.target.dispatch_mode == nil
    end

    assert ExecutionContext.new(%{target | state: :unknown}, issue, opts) ==
             {:error, :invalid_target}
  end

  @tag :tmp_dir
  test "rejects malformed issue identity without inventing a replacement", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    opts = [policy: %{"sandbox" => "restricted"}]

    for issue <- [
          %Issue{id: nil, identifier: "SID-407"},
          %Issue{id: " ", identifier: "SID-407"},
          %Issue{id: "issue\nsecret", identifier: "SID-407"},
          %Issue{id: <<0xFF>>, identifier: "SID-407"},
          %Issue{id: "issue-407", identifier: nil},
          %Issue{id: "issue-407", identifier: " "},
          %Issue{id: "issue-407", identifier: <<0xFF>>}
        ] do
      assert ExecutionContext.new(target, issue, opts) == {:error, :invalid_issue}
    end

    assert ExecutionContext.new(target, %{}, opts) == {:error, :invalid_issue}
  end

  @tag :tmp_dir
  test "rejects relative workspace roots without resolving them against CWD", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]
    worktree_policy = %{target.worktree_policy | "root" => "relative/worktrees"}

    assert ExecutionContext.new(%{target | worktree_policy: worktree_policy}, issue, opts) ==
             {:error, :invalid_worktree_policy}
  end

  @tag :tmp_dir
  test "canonicalizes an absolute Task-1 workspace root before pinning it", %{tmp_dir: tmp_dir} do
    raw_root = "#{tmp_dir}/canonical/../canonical"

    document =
      registry_document(tmp_dir)
      |> put_in(["targets", "alpha", "worktree", "root"], raw_root)

    target = target_context!(tmp_dir, document)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}

    assert {:ok, context} =
             ExecutionContext.new(target, issue, policy: %{"sandbox" => "restricted"})

    assert context.workspace_path ==
             Path.join([Path.expand(raw_root), "alpha", "SID-407"])
  end

  @tag :tmp_dir
  test "requires a typed worktree policy and a safe issue path segment", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]

    target_root = Path.join([tmp_dir, "target-worktrees", "alpha"])

    assert {:ok, context} =
             ExecutionContext.new(
               %{target | worktree_policy: %{target.worktree_policy | "root" => target_root}},
               issue,
               opts
             )

    assert context.workspace_path == Path.join(target_root, "SID-407")

    assert ExecutionContext.new(
             %{target | worktree_policy: Map.delete(target.worktree_policy, "hooks")},
             issue,
             opts
           ) == {:error, :invalid_worktree_policy}

    hooks = %{
      "after_create" => "",
      "before_run" => "printf 'token=sk-test-execution-hook'\nprintf done",
      "after_run" => " ",
      "before_remove" => nil,
      "timeout_ms" => 1_000
    }

    assert {:ok, _context_with_hooks} =
             ExecutionContext.new(
               %{target | worktree_policy: %{target.worktree_policy | "hooks" => hooks}},
               issue,
               opts
             )

    for invalid_hooks <- [
          Map.delete(hooks, "after_create"),
          Map.put(hooks, "unknown", "value"),
          Map.put(hooks, "before_run", 42),
          Map.put(hooks, "before_run", <<0xFF>>),
          Map.put(hooks, "timeout_ms", 0)
        ] do
      assert ExecutionContext.new(
               %{target | worktree_policy: %{target.worktree_policy | "hooks" => invalid_hooks}},
               issue,
               opts
             ) == {:error, :invalid_worktree_policy}
    end

    for worktree_policy <- [
          nil,
          %{},
          Map.put(target.worktree_policy, "root", " "),
          Map.put(target.worktree_policy, "root", <<0xFF>>),
          Map.put(target.worktree_policy, "strategy", "shared"),
          Map.put(target.worktree_policy, "hooks", [])
        ] do
      assert ExecutionContext.new(%{target | worktree_policy: worktree_policy}, issue, opts) ==
               {:error, :invalid_worktree_policy}
    end

    for identifier <- [".", "..", "SID/407", "SID\\407", "SID-../407", "SID\0-407", "SID\t407"] do
      assert ExecutionContext.new(target, %{issue | identifier: identifier}, opts) ==
               {:error, :invalid_issue}
    end
  end

  @tag :tmp_dir
  test "requires exact repository policy keys and absolute source provenance", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]
    repo_policy = target.repo_policy

    malformed_repo_policies = [
      Map.delete(repo_policy, "manifest_source_dir"),
      Map.delete(repo_policy, "workflow_module_resolution"),
      Map.put(repo_policy, "unknown", "forged"),
      Map.put(repo_policy, "manifest_source_dir", "relative/source"),
      Map.put(repo_policy, "manifest_source_dir", <<0xFF>>),
      Map.put(repo_policy, "manifest", []),
      Map.put(repo_policy, "workflow_module_resolution", [])
    ]

    for malformed_repo_policy <- malformed_repo_policies do
      assert ExecutionContext.new(%{target | repo_policy: malformed_repo_policy}, issue, opts) ==
               {:error, :invalid_target}
    end
  end

  @tag :tmp_dir
  test "rejects every existing workspace symlink and permits nonexistent trailing paths", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]
    internal_parent = Path.join(tmp_dir, "internal-parent")
    real_root = Path.join(internal_parent, "real-root")
    linked_root_inside_parent = Path.join(internal_parent, "linked-root")
    File.mkdir_p!(real_root)
    File.ln_s!(real_root, linked_root_inside_parent)

    assert ExecutionContext.new(
             %{target | worktree_policy: %{target.worktree_policy | "root" => linked_root_inside_parent}},
             issue,
             opts
           ) == {:error, :invalid_workspace_path}

    internal_target_root = Path.join(tmp_dir, "internal-targets")
    real_target = Path.join(internal_target_root, "real-alpha")
    File.mkdir_p!(real_target)
    File.ln_s!(real_target, Path.join(internal_target_root, "alpha"))

    assert ExecutionContext.new(
             %{
               target
               | workspace_layout: :target_scoped,
                 worktree_policy: %{target.worktree_policy | "root" => internal_target_root}
             },
             issue,
             opts
           ) == {:error, :invalid_workspace_path}

    issue_root = Path.join([tmp_dir, "internal-issues", "alpha"])
    other_issue = Path.join(issue_root, "SID-408")
    File.mkdir_p!(other_issue)
    File.ln_s!(other_issue, Path.join(issue_root, "SID-407"))

    assert ExecutionContext.new(
             %{target | worktree_policy: %{target.worktree_policy | "root" => issue_root}},
             issue,
             opts
           ) == {:error, :invalid_workspace_path}

    nonexistent_root = Path.join(tmp_dir, "nonexistent-trailing")
    File.mkdir_p!(Path.join(nonexistent_root, "alpha"))

    assert {:ok, context} =
             ExecutionContext.new(
               %{
                 target
                 | workspace_layout: :target_scoped,
                   worktree_policy: %{target.worktree_policy | "root" => nonexistent_root}
               },
               issue,
               opts
             )

    assert context.workspace_path == Path.join([nonexistent_root, "alpha", "SID-407"])
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(Path.join(outside, "alpha"))

    linked_root = Path.join([tmp_dir, "linked-worktrees", "alpha"])
    File.mkdir_p!(Path.dirname(linked_root))
    File.ln_s!(Path.join(outside, "alpha"), linked_root)

    assert ExecutionContext.new(
             %{target | worktree_policy: %{target.worktree_policy | "root" => linked_root}},
             issue,
             opts
           ) == {:error, :invalid_workspace_path}

    base_root = Path.join(tmp_dir, "base-worktrees")
    File.mkdir_p!(base_root)
    File.ln_s!(Path.join(outside, "alpha"), Path.join(base_root, "alpha"))

    assert ExecutionContext.new(
             %{
               target
               | workspace_layout: :target_scoped,
                 worktree_policy: %{target.worktree_policy | "root" => base_root}
             },
             issue,
             opts
           ) == {:error, :invalid_workspace_path}

    target_root = Path.join([tmp_dir, "issue-worktrees", "alpha"])
    File.mkdir_p!(target_root)
    File.ln_s!(outside, Path.join(target_root, "SID-407"))

    assert ExecutionContext.new(
             %{target | worktree_policy: %{target.worktree_policy | "root" => target_root}},
             issue,
             opts
           ) == {:error, :invalid_workspace_path}

    symlink_loop = Path.join(tmp_dir, "symlink-loop")
    File.ln_s!(symlink_loop, symlink_loop)

    assert ExecutionContext.new(
             %{target | worktree_policy: %{target.worktree_policy | "root" => symlink_loop}},
             issue,
             opts
           ) == {:error, :invalid_workspace_path}
  end

  @tag :tmp_dir
  test "rejects an existing workspace path that cannot be inspected", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    workspace_root = Path.join([tmp_dir, "restricted-worktrees", "alpha"])
    workspace_path = Path.join(workspace_root, issue.identifier)
    File.mkdir_p!(workspace_path)
    on_exit(fn -> File.chmod!(workspace_root, 0o700) end)
    File.chmod!(workspace_root, 0o600)

    assert File.lstat(workspace_path) == {:error, :eacces}

    assert ExecutionContext.new(
             %{target | worktree_policy: %{target.worktree_policy | "root" => workspace_root}},
             issue,
             policy: %{"sandbox" => "restricted"}
           ) == {:error, :invalid_workspace_path}
  end

  @tag :tmp_dir
  test "accepts only recursively JSON-safe string-keyed restrictive policy maps", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}

    assert {:ok, context} =
             ExecutionContext.new(target, issue,
               policy: %{
                 "sandbox" => %{"network_access" => false},
                 "limits" => [1, 2.5, nil, true, "safe"]
               }
             )

    assert context.policy["limits"] == [1, 2.5, nil, true, "safe"]

    for policy <- [
          nil,
          [],
          %{},
          %{sandbox: "restricted"},
          %{"nested" => %{1 => "invalid"}},
          %{"nested" => {:not, :json}},
          %{"nested" => ["safe" | :improper]},
          %{<<0xFF>> => "invalid"},
          %{"secret" => <<0xFF>>}
        ] do
      assert ExecutionContext.new(target, issue, policy: policy) == {:error, :invalid_policy}
    end
  end

  @tag :tmp_dir
  test "validates the pinned default, allowed list, and full selected runner", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]

    reviewer_policy = Map.put(target.runner_policy, "default", "reviewer")
    assert {:ok, reviewer_context} = ExecutionContext.new(%{target | runner_policy: reviewer_policy}, issue, opts)
    assert reviewer_context.runner_name == "reviewer"
    assert reviewer_context.execution_profile.model == "review-model"

    for runner_policy <- [
          Map.put(target.runner_policy, "default", " "),
          Map.put(target.runner_policy, "allowed", "codex"),
          Map.put(target.runner_policy, "allowed", ["codex", "codex"]),
          Map.put(target.runner_policy, "runners", []),
          Map.put(target.runner_policy, "allowed", ["codex" | "reviewer"])
        ] do
      assert ExecutionContext.new(%{target | runner_policy: runner_policy}, issue, opts) ==
               {:error, :invalid_runner_policy}
    end

    not_allowed = Map.put(target.runner_policy, "default", "forbidden")
    assert ExecutionContext.new(%{target | runner_policy: not_allowed}, issue, opts) == {:error, :runner_not_allowed}

    missing_runner =
      Map.put(target.runner_policy, "runners", Map.delete(target.runner_policy["runners"], "codex"))

    configured_runner_policy =
      target.runner_policy
      |> put_in(["runners", "codex", "reasoning_effort"], nil)
      |> put_in(
        ["runners", "codex", "execution_profiles", "implementation", "command"],
        ["custom-codex", "app-server"]
      )

    assert {:ok, configured_context} =
             ExecutionContext.new(%{target | runner_policy: configured_runner_policy}, issue, opts)

    assert configured_context.execution_profile.command == ["custom-codex", "app-server"]
    assert ExecutionContext.new(%{target | runner_policy: missing_runner}, issue, opts) == {:error, :runner_not_found}

    malformed_runners = [
      put_in(target.runner_policy, ["runners", "codex"], :invalid),
      put_in(target.runner_policy, ["runners", "codex"], %{}),
      put_in(target.runner_policy, ["runners", "codex", "command"], ["codex" | "app-server"]),
      put_in(target.runner_policy, ["runners", "codex", "execution_profiles"], []),
      put_in(target.runner_policy, ["runners", "codex", "execution_profiles", "implementation"], :invalid),
      put_in(target.runner_policy, ["runners", "codex", "private"], fn -> :secret end)
    ]

    for runner_policy <- malformed_runners do
      assert ExecutionContext.new(%{target | runner_policy: runner_policy}, issue, opts) ==
               {:error, :invalid_runner_config}
    end
  end

  @tag :tmp_dir
  test "keeps runner and profile grammar at the pinned authority boundary", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]

    assert ExecutionContext.new(
             %{target | runner_policy: Map.put(target.runner_policy, "fallback", "reviewer")},
             issue,
             opts
           ) == {:error, :invalid_runner_policy}

    runner_with_extra_field =
      put_in(target.runner_policy, ["runners", "codex", "task_one_extension"], "value")

    assert {:ok, runner_context} =
             ExecutionContext.new(%{target | runner_policy: runner_with_extra_field}, issue, opts)

    assert runner_context.runner_config["task_one_extension"] == "value"

    profile_with_extra_field =
      put_in(
        target.runner_policy,
        ["runners", "codex", "execution_profiles", "implementation", "task_one_extension"],
        "value"
      )

    assert {:ok, profile_context} =
             ExecutionContext.new(%{target | runner_policy: profile_with_extra_field}, issue, opts)

    refute Map.has_key?(profile_context.execution_profile, :task_one_extension)
  end

  @tag :tmp_dir
  test "requires the explicit pinned profile timeout fallback", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]

    runner_policy =
      update_in(target.runner_policy, ["runners", "codex"], &Map.delete(&1, "turn_timeout_ms"))

    assert ExecutionContext.new(%{target | runner_policy: runner_policy}, issue, opts) ==
             {:error, :invalid_runner_config}
  end

  @tag :tmp_dir
  test "accepts composed OpenCode runner fields without owning their grammar", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]

    opencode =
      target.runner_policy["runners"]["codex"]
      |> Map.drop(~w(approval_policy thread_sandbox turn_sandbox_policy))
      |> Map.update!("execution_profiles", fn profiles ->
        Map.new(profiles, fn {name, profile} ->
          {name, Map.drop(profile, ~w(approval_policy thread_sandbox turn_sandbox_policy))}
        end)
      end)
      |> Map.merge(%{
        "kind" => "opencode_server",
        "config_content" => "safe: true",
        "hostname" => "127.0.0.1",
        "permissions" => %{},
        "port" => "auto",
        "server_auth" => %{"password" => "secret", "username" => "worker"},
        "startup_timeout_ms" => 30_000
      })

    runner_policy = put_in(target.runner_policy, ["runners", "codex"], opencode)
    assert {:ok, context} = ExecutionContext.new(%{target | runner_policy: runner_policy}, issue, opts)
    assert context.runner_config["kind"] == "opencode_server"

    map_config_policy =
      put_in(runner_policy, ["runners", "codex", "config_content"], %{"safe" => true})

    assert {:ok, _map_config_context} =
             ExecutionContext.new(%{target | runner_policy: map_config_policy}, issue, opts)

    minimal_runner_policy =
      update_in(
        runner_policy,
        ["runners", "codex"],
        &Map.drop(&1, ~w(config_content server_auth))
      )

    assert {:ok, _minimal_context} =
             ExecutionContext.new(%{target | runner_policy: minimal_runner_policy}, issue, opts)
  end

  @tag :tmp_dir
  test "pins Task-1 runner safety fields without projecting profile grammar", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]

    runner_policy =
      update_in(
        target.runner_policy,
        ["runners", "codex"],
        &Map.drop(&1, ~w(approval_policy thread_sandbox turn_sandbox_policy))
      )

    assert {:ok, context} =
             ExecutionContext.new(%{target | runner_policy: runner_policy}, issue, opts)

    assert context.runner_config == runner_policy["runners"]["codex"]
  end

  @tag :tmp_dir
  test "does not reinterpret Task-1-only profile safety fields", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}

    runner_policy =
      put_in(
        target.runner_policy,
        ["runners", "codex", "execution_profiles", "implementation", "approval_policy"],
        "on-request"
      )

    assert {:ok, context} =
             ExecutionContext.new(
               %{target | runner_policy: runner_policy},
               issue,
               policy: %{"sandbox" => "restricted"}
             )

    refute Map.has_key?(context.execution_profile, :approval_policy)
  end

  @tag :tmp_dir
  test "allows an omitted worker host and rejects unsafe SSH destinations secret-safely", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    policy = %{"sandbox" => "restricted"}

    assert {:ok, %{worker_host: nil}} = ExecutionContext.new(target, issue, policy: policy)

    assert {:ok, %{worker_host: "worker-01:2200"}} =
             ExecutionContext.new(target, issue, policy: policy, worker_host: "worker-01:2200")

    assert {:ok, %{worker_host: "root@127.0.0.1:2200"}} =
             ExecutionContext.new(target, issue,
               policy: policy,
               worker_host: "root@127.0.0.1:2200"
             )

    assert {:ok, %{worker_host: "root@[::1]:2200"}} =
             ExecutionContext.new(target, issue,
               policy: policy,
               worker_host: "root@[::1]:2200"
             )

    secret = "worker-secret-407"

    for worker_host <- [
          "",
          " ",
          "-oProxyCommand=#{secret}",
          "worker host",
          "worker/#{secret}",
          "worker\n#{secret}",
          "worker:0",
          "worker:65536",
          <<0xFF>>,
          "ssh://-F::",
          "ssh://root@-E::",
          "ssh://root@worker/#{secret}",
          407
        ] do
      result = ExecutionContext.new(target, issue, policy: policy, worker_host: worker_host)
      assert result == {:error, :invalid_worker_host}
      refute inspect(result) =~ secret
    end
  end

  @tag :tmp_dir
  test "accepts a safe URI worker host from pinned inputs without runtime config", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}

    assert {:ok, %{worker_host: "ssh://root@worker.example:2200"}} =
             ExecutionContext.new(target, issue,
               policy: %{"sandbox" => "restricted"},
               worker_host: "ssh://root@worker.example:2200"
             )
  end

  @tag :tmp_dir
  test "requires callers to provide the worker host struct key", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}

    assert {:ok, context} =
             ExecutionContext.new(target, issue, policy: %{"sandbox" => "restricted"})

    fields_without_worker_host =
      context
      |> Map.from_struct()
      |> Map.delete(:worker_host)

    assert_raise ArgumentError, fn -> struct!(ExecutionContext, fields_without_worker_host) end
  end

  @tag :tmp_dir
  test "uses pinned fallbacks without allowing reviewer profile crossing", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]

    without_implementation =
      update_in(
        target.runner_policy,
        ["runners", "codex", "execution_profiles"],
        &Map.delete(&1, "implementation")
      )

    assert {:ok, implementation} =
             ExecutionContext.new(%{target | runner_policy: without_implementation}, issue, opts)

    assert %{name: "implementation", model: nil, timeout_ms: 60_000, max_retries: 0} =
             implementation.execution_profile

    without_source_reviewer =
      update_in(
        target.runner_policy,
        ["runners", "codex", "execution_profiles"],
        &Map.delete(&1, "source_reviewer")
      )

    assert {:ok, parent} =
             ExecutionContext.new(%{target | runner_policy: without_source_reviewer}, issue, opts)

    assert {:ok, reviewer} = ExecutionContext.derive_child(parent, :source_reviewer, [])

    assert %{name: "source_reviewer", model: nil, timeout_ms: 60_000, max_retries: 0} =
             reviewer.execution_profile

    assert ExecutionContext.derive_child(parent, :source_reviewer, profile: "security_reviewer") ==
             {:error, :profile_not_allowed}
  end

  @tag :tmp_dir
  test "rejects a present scalar reviewer profile as invalid runner config", %{tmp_dir: tmp_dir} do
    target =
      target_context!(tmp_dir)
      |> Map.update!(:runner_policy, fn runner_policy ->
        put_in(
          runner_policy,
          ["runners", "codex", "execution_profiles", "source_reviewer"],
          "invalid"
        )
      end)

    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]

    assert {:ok, parent} = ExecutionContext.new(target, issue, opts)

    assert ExecutionContext.derive_child(parent, :source_reviewer, []) ==
             {:error, :invalid_runner_config}
  end

  @tag :tmp_dir
  test "derives only the six reviewer roles while preserving the pinned parent context", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    policy = %{"sandbox" => %{"network_access" => false}, "secrets" => []}

    assert {:ok, parent} =
             ExecutionContext.new(target, issue, policy: policy, worker_host: "worker-01:2200")

    roles = [
      :source_reviewer,
      :test_reviewer,
      :runtime_qa,
      :product_visual_review,
      :docs_reviewer,
      :security_reviewer
    ]

    for role <- roles do
      assert {:ok, child} = ExecutionContext.derive_child(parent, role, [])
      assert child.target == parent.target
      assert child.issue_id == parent.issue_id
      assert child.issue_identifier == parent.issue_identifier
      assert child.workspace_path == parent.workspace_path
      assert child.worker_host == parent.worker_host
      assert child.policy == parent.policy
      assert child.role == role
      assert child.runner_name == parent.runner_name
      assert child.runner_config == parent.runner_config
      assert child.execution_profile.name == Atom.to_string(role)
      assert child.execution_profile.model == "#{role}-model"
      assert child.timeout_ms == 15_000
      assert child.max_retries == 0
    end

    assert ExecutionContext.derive_child(parent, :implementation, []) == {:error, :invalid_role}
    assert ExecutionContext.derive_child(parent, :unknown_reviewer, []) == {:error, :invalid_role}
    assert ExecutionContext.derive_child(%{}, :source_reviewer, []) == {:error, :invalid_context}

    invalid_parent = %{parent | target: %{parent.target | runner_policy: %{}}}

    assert ExecutionContext.derive_child(invalid_parent, :source_reviewer, []) ==
             {:error, :invalid_context}
  end

  @tag :tmp_dir
  test "validates the complete pinned parent before child derivation", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    assert {:ok, parent} = ExecutionContext.new(target, issue, policy: %{"sandbox" => "restricted"})

    stale_target =
      put_in(
        parent.target.runner_policy,
        ["runners", "codex", "execution_profiles", "implementation", "model"],
        "changed-after-pinning"
      )

    hostile_parents = [
      %{parent | target: nil},
      %{parent | target: %{parent.target | runner_policy: nil}},
      %{parent | runner_name: nil},
      %{parent | runner_config: %{}},
      %{parent | execution_profile: nil},
      %{parent | execution_profile: %URI{}},
      %{parent | policy: nil},
      %{parent | workspace_path: nil},
      %{parent | timeout_ms: 0},
      %{parent | max_retries: -1},
      %{parent | worker_host: :local},
      %{parent | issue_id: nil},
      %{parent | issue_identifier: "../SID-407"},
      %{parent | target: %{parent.target | runner_policy: stale_target}},
      %{
        parent
        | target: %{
            parent.target
            | repo_policy: Map.put(parent.target.repo_policy, "unknown", "forged")
          }
      },
      %{
        parent
        | target: %{
            parent.target
            | worktree_policy: Map.delete(parent.target.worktree_policy, "hooks")
          }
      }
    ]

    for hostile_parent <- hostile_parents do
      assert ExecutionContext.derive_child(hostile_parent, :source_reviewer, unknown: true) ==
               {:error, :invalid_context}
    end
  end

  @tag :tmp_dir
  test "rejects child derivation from an inconsistent pinned runner policy", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    assert {:ok, parent} = ExecutionContext.new(target, issue, policy: %{"sandbox" => "restricted"})

    runner_policy = Map.put(parent.target.runner_policy, "allowed", ["codex"])
    parent = %{parent | target: %{parent.target | runner_policy: runner_policy}}

    assert ExecutionContext.derive_child(parent, :source_reviewer, []) ==
             {:error, :invalid_context}
  end

  @tag :tmp_dir
  test "child options only select policy-authorized runners and profiles", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    policy = %{"sandbox" => "restricted"}
    assert {:ok, parent} = ExecutionContext.new(target, issue, policy: policy)

    assert {:ok, child} =
             ExecutionContext.derive_child(parent, :source_reviewer,
               runner: "reviewer",
               profile: "source_reviewer"
             )

    assert child.runner_name == "reviewer"
    assert child.runner_config == parent.target.runner_policy["runners"]["reviewer"]
    assert child.execution_profile.name == "source_reviewer"
    assert child.execution_profile.model == "source_reviewer-model"
    assert child.timeout_ms == 15_000
    assert child.max_retries == 0

    assert Map.take(child, ~w(target issue_id issue_identifier workspace_path worker_host policy)a) ==
             Map.take(parent, ~w(target issue_id issue_identifier workspace_path worker_host policy)a)

    assert ExecutionContext.derive_child(parent, :source_reviewer, runner: "forbidden") ==
             {:error, :runner_not_allowed}

    assert ExecutionContext.derive_child(parent, :source_reviewer, profile: "unconfigured") ==
             {:error, :profile_not_allowed}

    assert ExecutionContext.derive_child(parent, :source_reviewer, runner: :reviewer) ==
             {:error, :invalid_runner}

    assert ExecutionContext.derive_child(parent, :source_reviewer, profile: :security_reviewer) ==
             {:error, :invalid_profile}

    assert ExecutionContext.derive_child(parent, :source_reviewer, runner: "codex", runner: "reviewer") ==
             {:error, :duplicate_option}

    assert ExecutionContext.derive_child(parent, :source_reviewer, [:not_a_pair]) ==
             {:error, :invalid_options}

    assert ExecutionContext.derive_child(parent, :source_reviewer, %{runner: "reviewer"}) ==
             {:error, :invalid_options}

    for key <- [
          :runner_config,
          :model,
          :command,
          :timeout_ms,
          :max_retries,
          :root,
          :policy,
          :target,
          :workspace,
          :workspace_path,
          :worker_host,
          :unknown
        ] do
      assert ExecutionContext.derive_child(parent, :source_reviewer, [{key, "override"}]) ==
               {:error, :unknown_option}
    end
  end

  @tag :tmp_dir
  test "rejects unsupported target terms and owns accepted nested containers", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    opts = [policy: %{"sandbox" => "restricted"}]
    source_value = Path.join(tmp_dir, "owned-target-value")
    backing = String.duplicate("x", 100_000) <> source_value

    subbinary =
      binary_part(
        backing,
        byte_size(backing) - byte_size(source_value),
        byte_size(source_value)
      )

    nested = %{subbinary => %{"map" => subbinary, "list" => [subbinary, %{"deep" => subbinary}]}}

    owned_target = %{
      target
      | repo_policy:
          target.repo_policy
          |> put_in(["manifest", "owned"], nested)
          |> Map.put("manifest_source_dir", subbinary),
        worktree_policy: put_in(target.worktree_policy, ["hooks", "before_run"], subbinary)
    }

    assert {:ok, context} = ExecutionContext.new(owned_target, issue, opts)
    [{owned_key, owned_value}] = Map.to_list(context.target.repo_policy["manifest"]["owned"])

    for owned_binary <- [
          context.target.repo_policy["manifest_source_dir"],
          context.target.worktree_policy["hooks"]["before_run"],
          owned_key,
          owned_value["map"],
          hd(owned_value["list"]),
          get_in(owned_value, ["list", Access.at(1), "deep"])
        ] do
      assert owned_binary == subbinary
      assert :binary.referenced_byte_size(owned_binary) == byte_size(owned_binary)
    end

    tuple_with_subbinary = {:unsupported, subbinary}

    for field <- ~w(
          repo_policy tracker_connection run_target worktree_policy runner_policy effective_checks
          external_side_effect_gates capacity_limits budget_limits
        )a do
      hostile_target = Map.replace!(target, field, %{"nested" => tuple_with_subbinary})

      expected_error =
        case field do
          :worktree_policy -> :invalid_worktree_policy
          :runner_policy -> :invalid_runner_policy
          _other -> :invalid_target
        end

      assert ExecutionContext.new(hostile_target, issue, opts) == {:error, expected_error}
    end

    for hostile <- [
          fn -> :unsupported end,
          self(),
          make_ref(),
          %URI{scheme: "secret"},
          ["safe" | :improper]
        ] do
      hostile_target = %{target | repo_policy: %{"nested" => hostile}}
      assert ExecutionContext.new(hostile_target, issue, opts) == {:error, :invalid_target}
    end
  end

  @tag :tmp_dir
  test "inspects hostile typed contexts with a fixed redacted placeholder", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    issue = %Issue{id: "issue-407", identifier: "SID-407"}
    secret = "hostile-inspect-secret-407"

    assert {:ok, context} =
             ExecutionContext.new(target, issue, policy: %{"credential" => secret})

    hostile = %{
      context
      | target: nil,
        issue_id: secret,
        issue_identifier: secret,
        workspace_path: secret,
        runner_name: secret,
        runner_config: %{secret => self()},
        policy: %{secret => make_ref()},
        execution_profile: %{secret => fn -> secret end},
        worker_host: secret
    }

    assert inspect(hostile) == "#SymphonyElixir.ExecutionContext<redacted>"
    refute inspect(hostile) =~ secret
  end

  @tag :tmp_dir
  test "owns its pinned snapshot and redacts execution policy from Inspect", %{tmp_dir: tmp_dir} do
    target = target_context!(tmp_dir)
    source_issue_id = String.duplicate("i", 128)
    issue_backing = String.duplicate("x", 100_000) <> source_issue_id

    issue_id =
      binary_part(
        issue_backing,
        byte_size(issue_backing) - byte_size(source_issue_id),
        byte_size(source_issue_id)
      )

    source_target_id = "a" <> String.duplicate("t", 126) <> "a"
    target_backing = String.duplicate("y", 100_000) <> source_target_id

    target_id =
      binary_part(
        target_backing,
        byte_size(target_backing) - byte_size(source_target_id),
        byte_size(source_target_id)
      )

    secret = "inspect-secret-407"

    runner_policy =
      put_in(
        target.runner_policy,
        ["runners", "codex", "execution_profiles", "source_reviewer", "model"],
        "#{secret}-model"
      )

    target = %{target | target_id: target_id, runner_policy: runner_policy}
    issue = %Issue{id: issue_id, identifier: "SID-407"}
    policy = %{"sandbox" => "restricted", "credential" => secret}

    assert {:ok, parent} =
             ExecutionContext.new(target, issue, policy: policy, worker_host: "#{secret}.example")

    assert :binary.referenced_byte_size(parent.issue_id) == byte_size(parent.issue_id)
    assert :binary.referenced_byte_size(parent.target.target_id) == byte_size(parent.target.target_id)

    later_runner_policy =
      put_in(
        target.runner_policy,
        ["runners", "codex", "execution_profiles", "source_reviewer", "model"],
        "later-registry-model"
      )

    later_target = %{target | runner_policy: later_runner_policy}

    refute get_in(parent.target.runner_policy, ["runners", "codex", "execution_profiles", "source_reviewer", "model"]) ==
             get_in(later_target.runner_policy, ["runners", "codex", "execution_profiles", "source_reviewer", "model"])

    assert {:ok, child} = ExecutionContext.derive_child(parent, :source_reviewer, [])
    assert child.execution_profile.model == "#{secret}-model"

    inspected = inspect(parent)
    refute inspected =~ secret
    refute inspected =~ "runner_config"
    refute inspected =~ "execution_profile"
    refute inspected =~ "worktree_policy"
    refute inspected =~ "workspace_path"
    refute inspected =~ "worker_host"
    refute inspected =~ "credential"
  end

  defp target_context!(tmp_dir, document \\ nil) do
    repo_path = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo_path)
    File.write!(Path.join(repo_path, "symphony.yml"), "version: 1\n")

    document = document || registry_document(tmp_dir)
    assert {:ok, structured} = Schema.validate(document, home: tmp_dir)
    assert structured.globally_valid?
    assert structured.targets["alpha"].valid?

    registry_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-execution-context-registry-#{System.unique_integer([:positive])}/targets.yml"
      )

    validated = Validation.validate(structured, registry_path: registry_path)
    assert validated.globally_valid?, inspect(validated.diagnostics)
    assert validated.targets["alpha"].valid?, inspect(validated.targets["alpha"].diagnostics)

    composed = Composition.compose(validated, manifest: ManifestAdapter)
    assert composed.targets["alpha"].valid?, inspect(composed.targets["alpha"].diagnostics)

    generation = Preview.generation("execution-context-fixture")

    loaded = %{
      composed
      | path: registry_path,
        source_hash: generation,
        generation: generation
    }

    assert {:ok, context} =
             TargetContext.from_registry(loaded, "alpha", env_fetcher: fn "TRACKER_KEY" -> {:ok, "credential"} end)

    context
  end

  defp registry_document(tmp_dir) do
    %{
      "version" => 1,
      "host" => %{
        "id" => "fixture-host",
        "state_root" => Path.join(tmp_dir, "state"),
        "polling" => %{"interval_ms" => 1_000, "max_concurrent_target_polls" => 2},
        "capacity" => %{
          "max_concurrent_agents" => 4,
          "max_concurrent_startups" => 2,
          "max_concurrent_reviewers" => 2
        },
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 2},
        "tracker_connections" => %{
          "linear-primary" => %{
            "kind" => "linear",
            "endpoint" => "https://tracker.example.invalid/graphql",
            "api_key" => "$TRACKER_KEY"
          }
        },
        "runners" => %{
          "codex" => runner("implementation-model"),
          "reviewer" => runner("review-model")
        }
      },
      "targets" => %{
        "alpha" => %{
          "display_name" => "Alpha",
          "state" => "active",
          "dispatch_mode" => "explicit",
          "repo" => %{
            "path" => Path.join(tmp_dir, "repo"),
            "manifest" => "symphony.yml",
            "expected_repository" => "https://github.com/example/repo"
          },
          "worktree" => %{
            "root" => Path.join([tmp_dir, "worktrees", "alpha"]),
            "strategy" => "per_issue",
            "hooks" => %{}
          },
          "linear" => %{
            "connection" => "linear-primary",
            "scope" => %{"type" => "project", "project_slug" => "alpha"},
            "active_states" => ["Todo", "In Progress"],
            "terminal_states" => ["Done"],
            "required_labels" => ["target:alpha"]
          },
          "runners" => %{
            "default" => "codex",
            "allowed" => ["codex", "reviewer"],
            "settings" => %{
              "codex" => %{"model" => "target-model"},
              "reviewer" => %{"model" => "target-review-model"}
            }
          },
          "concurrency" => %{
            "max_concurrent_agents" => 2,
            "max_concurrent_startups" => 1,
            "max_concurrent_reviewers" => 1
          },
          "budgets" => %{
            "per_run" => %{"max_total_tokens" => 1_000},
            "daily" => %{"max_total_tokens" => 10_000},
            "weekly" => %{"max_total_tokens" => 50_000}
          },
          "checks" => %{"pre_dispatch" => ["capability_preflight"], "pre_handoff" => ["quality_gate"]},
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
      }
    }
  end

  defp runner(model) do
    profiles =
      for role <- ~w(implementation source_reviewer test_reviewer runtime_qa product_visual_review docs_reviewer security_reviewer),
          into: %{} do
        profile = %{
          "model" => if(role == "implementation", do: model, else: "#{role}-model"),
          "reasoning_effort" => if(role in ["product_visual_review", "security_reviewer"], do: "high", else: "medium"),
          "budget" => "restricted",
          "timeout_ms" => if(role == "implementation", do: 45_000, else: 15_000),
          "max_retries" => if(role == "implementation", do: 1, else: 0)
        }

        profile =
          if role == "implementation" do
            Map.merge(profile, %{
              "approval_policy" => "never",
              "thread_sandbox" => "workspace-write",
              "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => false}
            })
          else
            profile
          end

        {role, profile}
      end

    %{
      "kind" => "codex_app_server",
      "command" => ["codex", "app-server"],
      "approval_policy" => "never",
      "thread_sandbox" => "workspace-write",
      "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => false},
      "turn_timeout_ms" => 60_000,
      "read_timeout_ms" => 30_000,
      "stall_timeout_ms" => 300_000,
      "max_concurrent_agents" => 4,
      "max_concurrent_startups" => 2,
      "execution_profiles" => profiles
    }
  end

  defp opencode_runner do
    %{
      "kind" => "opencode_server",
      "command" => ["opencode", "serve"],
      "model" => "open/model",
      "hostname" => "127.0.0.1",
      "permissions" => %{},
      "port" => "auto",
      "startup_timeout_ms" => 30_000,
      "turn_timeout_ms" => 60_000,
      "read_timeout_ms" => 30_000,
      "stall_timeout_ms" => 300_000,
      "max_concurrent_agents" => 4,
      "max_concurrent_startups" => 2,
      "execution_profiles" => %{
        "implementation" => %{
          "model" => "open/implementation-model",
          "reasoning_effort" => "medium",
          "budget" => "restricted",
          "timeout_ms" => 45_000,
          "max_retries" => 1
        }
      }
    }
  end
end
