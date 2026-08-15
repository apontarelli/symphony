defmodule SymphonyElixir.TargetRegistry.ValidationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TargetRegistry.Diagnostic
  alias SymphonyElixir.TargetRegistry.Schema
  alias SymphonyElixir.TargetRegistry.Validation

  setup %{tmp_dir: tmp_dir} do
    registry_dir = Path.join(tmp_dir, "config")
    repo = Path.join(tmp_dir, "repos/main")

    File.mkdir_p!(registry_dir)
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "symphony.yml"), "project:\n  name: test\n")
    File.write!(Path.join(repo, "issues.yml"), "issues: []\n")
    outside_file = Path.join(tmp_dir, "outside.yml")
    File.write!(outside_file, "outside: true\n")
    File.ln_s!(outside_file, Path.join(repo, "escape.yml"))
    loop_a = Path.join(tmp_dir, "loop-a")
    loop_b = Path.join(tmp_dir, "loop-b")
    File.ln_s!(loop_b, loop_a)
    File.ln_s!(loop_a, loop_b)
    File.ln_s!(loop_a, Path.join(repo, "loop.yml"))

    paths = %{
      registry: Path.join(registry_dir, "targets.yml"),
      state: Path.join(tmp_dir, "state"),
      repo: repo,
      worktree: Path.join(tmp_dir, "worktrees/main"),
      outside_file: outside_file,
      loop: loop_a
    }

    {:ok, paths: paths}
  end

  @tag :tmp_dir
  test "quarantines a target whose tracker connection is not defined by the host", %{paths: paths} do
    snapshot =
      paths
      |> valid_snapshot()
      |> put_in([Access.key!(:targets), "main", Access.key!(:configured), "linear", "connection"], "missing")
      |> Validation.validate()

    assert_target_error(snapshot, "main", "$.targets.main.linear.connection", :unknown_reference)
    assert snapshot.globally_valid?
  end

  @tag :tmp_dir
  test "validates default, allowed, and settings runner references", %{paths: paths} do
    cases = [
      {["codex"], "claude", %{}, "$.targets.main.runners.default", :runner_not_allowed},
      {["missing"], "missing", %{}, "$.targets.main.runners.allowed[0]", :unknown_reference},
      {["codex"], "codex", %{"claude" => %{}}, "$.targets.main.runners.settings.claude", :runner_not_allowed}
    ]

    for {allowed, default, settings, path, code} <- cases do
      snapshot =
        paths
        |> valid_snapshot()
        |> put_in(
          [Access.key!(:targets), "main", Access.key!(:configured), "runners"],
          %{"allowed" => allowed, "default" => default, "settings" => settings}
        )
        |> Validation.validate()

      assert_target_error(snapshot, "main", path, code)
    end
  end

  @tag :tmp_dir
  test "contains dynamic runner setting keys and preserves deterministic diagnostics", %{paths: paths} do
    settings_entries = [
      {1, %{}},
      {1.0, %{}},
      {%{"sensitive-key" => "sensitive-value"}, %{}}
    ]

    snapshots =
      for entries <- [settings_entries, Enum.reverse(settings_entries)] do
        invalid_target =
          put_in(valid_target(paths), ["runners", "settings"], Map.new(entries))

        paths
        |> valid_snapshot(%{"alpha" => invalid_target, "safe" => valid_target(paths)})
        |> Validation.validate()
      end

    expected = [
      {{:target, "alpha"}, "$.targets.alpha.runners.settings[key:0:float]", :invalid_type, "$.targets.alpha.runners.settings[key:0:float] must be a string"},
      {{:target, "alpha"}, "$.targets.alpha.runners.settings[key:0:float]", :runner_not_allowed,
       "$.targets.alpha.runners.settings[key:0:float] is only valid for a runner in $.targets.alpha.runners.allowed"},
      {{:target, "alpha"}, "$.targets.alpha.runners.settings[key:0:float]", :unknown_reference, "$.targets.alpha.runners.settings[key:0:float] must reference a host runner"},
      {{:target, "alpha"}, "$.targets.alpha.runners.settings[key:1:integer]", :invalid_type, "$.targets.alpha.runners.settings[key:1:integer] must be a string"},
      {{:target, "alpha"}, "$.targets.alpha.runners.settings[key:1:integer]", :runner_not_allowed,
       "$.targets.alpha.runners.settings[key:1:integer] is only valid for a runner in $.targets.alpha.runners.allowed"},
      {{:target, "alpha"}, "$.targets.alpha.runners.settings[key:1:integer]", :unknown_reference, "$.targets.alpha.runners.settings[key:1:integer] must reference a host runner"},
      {{:target, "alpha"}, "$.targets.alpha.runners.settings[key:2:map]", :invalid_type, "$.targets.alpha.runners.settings[key:2:map] must be a string"},
      {{:target, "alpha"}, "$.targets.alpha.runners.settings[key:2:map]", :runner_not_allowed,
       "$.targets.alpha.runners.settings[key:2:map] is only valid for a runner in $.targets.alpha.runners.allowed"},
      {{:target, "alpha"}, "$.targets.alpha.runners.settings[key:2:map]", :unknown_reference, "$.targets.alpha.runners.settings[key:2:map] must reference a host runner"}
    ]

    for snapshot <- snapshots do
      assert diagnostic_values(snapshot.targets["alpha"].diagnostics) == expected
      assert snapshot.targets["safe"].diagnostics == []
      assert snapshot.targets["safe"].valid?
    end

    assert diagnostic_values(Enum.at(snapshots, 0).diagnostics) ==
             diagnostic_values(Enum.at(snapshots, 1).diagnostics)
  end

  @tag :tmp_dir
  test "uses bounded paths for every non-string runner setting key type", %{paths: paths} do
    cat_path = System.find_executable("cat") || raise "cat executable is required"
    port = Port.open({:spawn_executable, cat_path}, [])

    key_types = [
      {1, "integer"},
      {1.5, "float"},
      {:sensitive_atom, "atom"},
      {{:sensitive_tuple}, "tuple"},
      {%{sensitive: true}, "map"},
      {[:sensitive], "list"},
      {self(), "pid"},
      {make_ref(), "reference"},
      {fn -> :sensitive end, "function"},
      {port, "port"},
      {<<1::1>>, "bitstring"}
    ]

    for {key, type} <- key_types do
      target = put_in(valid_target(paths), ["runners", "settings"], %{key => %{}})

      snapshot =
        paths
        |> valid_snapshot(%{"main" => target})
        |> Validation.validate()

      setting_path = "$.targets.main.runners.settings[key:0:#{type}]"

      assert diagnostic_values(snapshot.targets["main"].diagnostics) == [
               {{:target, "main"}, setting_path, :invalid_type, "#{setting_path} must be a string"},
               {{:target, "main"}, setting_path, :runner_not_allowed, "#{setting_path} is only valid for a runner in $.targets.main.runners.allowed"},
               {{:target, "main"}, setting_path, :unknown_reference, "#{setting_path} must reference a host runner"}
             ]
    end

    Port.close(port)
  end

  @tag :tmp_dir
  test "checks every runner setting key against allowed and host runners", %{paths: paths} do
    snapshot =
      paths
      |> valid_snapshot()
      |> put_in(
        [Access.key!(:targets), "main", Access.key!(:configured), "runners"],
        %{
          "allowed" => ["codex", "missing"],
          "default" => "codex",
          "settings" => %{"claude" => %{}, "missing" => %{}, "other" => %{}}
        }
      )
      |> Validation.validate()

    assert diagnostic_values(snapshot.targets["main"].diagnostics) == [
             {{:target, "main"}, "$.targets.main.runners.allowed[1]", :unknown_reference, "$.targets.main.runners.allowed[1] must reference a host runner"},
             {{:target, "main"}, "$.targets.main.runners.settings.claude", :runner_not_allowed, "$.targets.main.runners.settings.claude is only valid for a runner in $.targets.main.runners.allowed"},
             {{:target, "main"}, "$.targets.main.runners.settings.missing", :unknown_reference, "$.targets.main.runners.settings.missing must reference a host runner"},
             {{:target, "main"}, "$.targets.main.runners.settings.other", :runner_not_allowed, "$.targets.main.runners.settings.other is only valid for a runner in $.targets.main.runners.allowed"},
             {{:target, "main"}, "$.targets.main.runners.settings.other", :unknown_reference, "$.targets.main.runners.settings.other must reference a host runner"}
           ]
  end

  @tag :tmp_dir
  test "requires exactly one selector family matching the Linear scope type", %{paths: paths} do
    valid_scopes = [
      %{"type" => "project", "project_id" => "p-1"},
      %{"type" => "project", "project_slug" => "roadmap"},
      %{"type" => "team", "team_key" => "ENG"},
      %{"type" => "query", "query_file" => "issues.yml"},
      %{"type" => "issues", "issue_ids" => ["SID-1"]}
    ]

    for scope <- valid_scopes do
      snapshot =
        paths
        |> valid_snapshot()
        |> put_in([Access.key!(:targets), "main", Access.key!(:configured), "linear", "scope"], scope)
        |> Validation.validate()

      assert snapshot.targets["main"].valid?
    end

    invalid_scopes = [
      {%{"type" => "project", "project_id" => "p-1", "project_slug" => "roadmap"}, "$.targets.main.linear.scope.project_slug", :scope_exclusivity},
      {%{"type" => "team", "team_key" => "ENG", "query_file" => "issues.yml"}, "$.targets.main.linear.scope", :scope_exclusivity},
      {%{"type" => "issues", "team_key" => "ENG"}, "$.targets.main.linear.scope.type", :scope_mismatch},
      {%{"type" => "query"}, "$.targets.main.linear.scope", :scope_exclusivity}
    ]

    for {scope, path, code} <- invalid_scopes do
      snapshot =
        paths
        |> valid_snapshot()
        |> put_in([Access.key!(:targets), "main", Access.key!(:configured), "linear", "scope"], scope)
        |> Validation.validate()

      assert_target_error(snapshot, "main", path, code)
    end
  end

  @tag :tmp_dir
  test "uses only locally valid selectors for Linear scope cross-field checks", %{paths: paths} do
    cases = [
      {%{"type" => "project", "project_id" => nil, "project_slug" => "roadmap"},
       [
         {{:target, "main"}, "$.targets.main.linear.scope.project_id", :invalid_type, "$.targets.main.linear.scope.project_id must be a string"}
       ]},
      {%{"type" => "query", "team_key" => " ", "query_file" => "issues.yml"},
       [
         {{:target, "main"}, "$.targets.main.linear.scope.team_key", :invalid_value, "$.targets.main.linear.scope.team_key must not be empty"}
       ]},
      {%{"type" => "team", "team_key" => "ENG", "issue_ids" => []},
       [
         {{:target, "main"}, "$.targets.main.linear.scope.issue_ids", :invalid_value, "$.targets.main.linear.scope.issue_ids must not be empty"}
       ]},
      {%{"type" => "project", "project_id" => " ", "project_slug" => nil},
       [
         {{:target, "main"}, "$.targets.main.linear.scope", :scope_exclusivity, "$.targets.main.linear.scope must contain exactly one selector family"},
         {{:target, "main"}, "$.targets.main.linear.scope.project_id", :invalid_value, "$.targets.main.linear.scope.project_id must not be empty"},
         {{:target, "main"}, "$.targets.main.linear.scope.project_slug", :invalid_type, "$.targets.main.linear.scope.project_slug must be a string"}
       ]},
      {%{"type" => "issues", "project_id" => "p-1", "issue_ids" => ["SID-1", nil]},
       [
         {{:target, "main"}, "$.targets.main.linear.scope.issue_ids[1]", :invalid_type, "$.targets.main.linear.scope.issue_ids[1] must be a string"},
         {{:target, "main"}, "$.targets.main.linear.scope.type", :scope_mismatch, "$.targets.main.linear.scope.type must match the configured selector family"}
       ]},
      {%{"type" => "issues", "issue_ids" => []},
       [
         {{:target, "main"}, "$.targets.main.linear.scope", :scope_exclusivity, "$.targets.main.linear.scope must contain exactly one selector family"},
         {{:target, "main"}, "$.targets.main.linear.scope.issue_ids", :invalid_value, "$.targets.main.linear.scope.issue_ids must not be empty"}
       ]}
    ]

    for {scope, expected} <- cases do
      target = put_in(valid_target(paths), ["linear", "scope"], scope)

      snapshot =
        paths
        |> valid_snapshot(%{"main" => target})
        |> Validation.validate()

      assert diagnostic_values(snapshot.targets["main"].diagnostics) == expected
    end
  end

  @tag :tmp_dir
  test "rejects active and terminal Linear states that overlap after normalization", %{paths: paths} do
    snapshot =
      paths
      |> valid_snapshot()
      |> put_in(
        [Access.key!(:targets), "main", Access.key!(:configured), "linear", "active_states"],
        [" Todo ", "In Progress"]
      )
      |> put_in(
        [Access.key!(:targets), "main", Access.key!(:configured), "linear", "terminal_states"],
        ["in progress", "DONE"]
      )
      |> Validation.validate()

    assert_target_error(
      snapshot,
      "main",
      "$.targets.main.linear.terminal_states",
      :state_overlap
    )
  end

  @tag :tmp_dir
  test "intersects target capacity with host, selected runner, and target ceilings", %{paths: paths} do
    host_limited =
      paths
      |> valid_snapshot()
      |> put_in([Access.key!(:host), "capacity", "max_concurrent_agents"], 3)
      |> Validation.validate()

    assert_target_error(
      host_limited,
      "main",
      "$.targets.main.concurrency.max_concurrent_agents",
      :capacity_exceeded
    )

    runner_limited =
      paths
      |> valid_snapshot()
      |> put_in(
        [Access.key!(:targets), "main", Access.key!(:configured), "runners"],
        %{"allowed" => ["claude"], "default" => "claude", "settings" => %{}}
      )
      |> Validation.validate()

    assert_target_error(
      runner_limited,
      "main",
      "$.targets.main.concurrency.max_concurrent_agents",
      :capacity_exceeded
    )

    startup_limited =
      paths
      |> valid_snapshot()
      |> put_in(
        [
          Access.key!(:targets),
          "main",
          Access.key!(:configured),
          "concurrency",
          "max_concurrent_startups"
        ],
        4
      )
      |> Validation.validate()

    assert_target_error(
      startup_limited,
      "main",
      "$.targets.main.concurrency.max_concurrent_startups",
      :capacity_exceeded
    )

    reviewer_limited =
      paths
      |> valid_snapshot()
      |> put_in(
        [
          Access.key!(:targets),
          "main",
          Access.key!(:configured),
          "concurrency",
          "max_concurrent_reviewers"
        ],
        3
      )
      |> Validation.validate()

    assert_target_error(
      reviewer_limited,
      "main",
      "$.targets.main.concurrency.max_concurrent_reviewers",
      :capacity_exceeded
    )

    state_limited =
      paths
      |> valid_snapshot()
      |> put_in(
        [
          Access.key!(:targets),
          "main",
          Access.key!(:configured),
          "concurrency",
          "by_linear_state",
          "in progress"
        ],
        5
      )
      |> Validation.validate()

    assert_target_error(
      state_limited,
      "main",
      "$.targets.main.concurrency.by_linear_state.in progress",
      :capacity_exceeded
    )
  end

  @tag :tmp_dir
  test "intersects capacity with every selectable allowed runner", %{paths: paths} do
    snapshot =
      paths
      |> valid_snapshot()
      |> put_in(
        [Access.key!(:targets), "main", Access.key!(:configured), "runners"],
        %{"allowed" => ["claude", "codex"], "default" => "codex", "settings" => %{}}
      )
      |> put_in(
        [
          Access.key!(:targets),
          "main",
          Access.key!(:configured),
          "concurrency",
          "max_concurrent_startups"
        ],
        3
      )
      |> Validation.validate()

    assert diagnostic_values(snapshot.targets["main"].diagnostics) == [
             {{:target, "main"}, "$.targets.main.concurrency.max_concurrent_agents", :capacity_exceeded, "$.targets.main.concurrency.max_concurrent_agents must not exceed effective ceiling 3"},
             {{:target, "main"}, "$.targets.main.concurrency.max_concurrent_startups", :capacity_exceeded, "$.targets.main.concurrency.max_concurrent_startups must not exceed effective ceiling 2"}
           ]
  end

  @tag :tmp_dir
  test "orders token budgets from per-run through daily and weekly", %{paths: paths} do
    cases = [
      {["daily", "max_total_tokens"], 500, "$.targets.main.budgets.daily.max_total_tokens"},
      {["weekly", "max_total_tokens"], 5_000, "$.targets.main.budgets.weekly.max_total_tokens"}
    ]

    for {budget_path, value, diagnostic_path} <- cases do
      snapshot =
        paths
        |> valid_snapshot()
        |> put_in(
          [Access.key!(:targets), "main", Access.key!(:configured), "budgets" | budget_path],
          value
        )
        |> Validation.validate()

      assert_target_error(snapshot, "main", diagnostic_path, :budget_order)
    end
  end

  @tag :tmp_dir
  test "treats omitted gate operations as deny without changing configured policy", %{paths: paths} do
    snapshot =
      paths
      |> valid_snapshot()
      |> put_in(
        [Access.key!(:targets), "main", Access.key!(:configured), "external_side_effects"],
        %{"tracker_write" => "manual_approval"}
      )

    configured = snapshot.targets["main"].configured
    validated = Validation.validate(snapshot)
    target = validated.targets["main"]

    assert target.configured == configured
    assert Validation.effective_gate(target, "tracker_write") == "manual_approval"
    assert Validation.effective_gate(target, "merge") == "deny"
    assert Validation.effective_gate(target, "production_data") == "deny"
  end

  @tag :tmp_dir
  test "rejects worktree overlap with repo, host state, and registry roots", %{paths: paths} do
    overlapping_roots = [
      Path.join(paths.repo, "worktrees"),
      Path.join(paths.state, "worktrees"),
      Path.join(Path.dirname(paths.registry), "worktrees")
    ]

    for root <- overlapping_roots do
      snapshot =
        paths
        |> valid_snapshot()
        |> put_in(
          [Access.key!(:targets), "main", Access.key!(:configured), "worktree", "root"],
          root
        )
        |> Validation.validate()

      assert_target_error(snapshot, "main", "$.targets.main.worktree.root", :path_overlap)
    end
  end

  @tag :tmp_dir
  test "allows a shared repo root but rejects overlapping worktree roots across targets", %{paths: paths} do
    second_worktree = Path.join(Path.dirname(paths.worktree), "second")

    targets = %{
      "alpha" => valid_target(paths),
      "beta" => put_in(valid_target(paths), ["worktree", "root"], second_worktree)
    }

    shared_repo_snapshot = paths |> valid_snapshot(targets) |> Validation.validate()
    assert shared_repo_snapshot.targets["alpha"].valid?
    assert shared_repo_snapshot.targets["beta"].valid?

    overlapping_targets =
      put_in(targets, ["beta", "worktree", "root"], paths.worktree)

    overlapping_snapshot = paths |> valid_snapshot(overlapping_targets) |> Validation.validate()

    assert_target_error(
      overlapping_snapshot,
      "alpha",
      "$.targets.alpha.worktree.root",
      :path_overlap
    )

    assert_target_error(
      overlapping_snapshot,
      "beta",
      "$.targets.beta.worktree.root",
      :path_overlap
    )
  end

  @tag :tmp_dir
  test "rejects traversal and symlink escape for manifest and query paths", %{paths: paths} do
    cases = [
      {["repo", "manifest"], "../outside.yml", "$.targets.main.repo.manifest"},
      {["repo", "manifest"], "escape.yml", "$.targets.main.repo.manifest"},
      {["linear", "scope"], %{"type" => "query", "query_file" => "../outside.yml"}, "$.targets.main.linear.scope.query_file"},
      {["linear", "scope"], %{"type" => "query", "query_file" => "escape.yml"}, "$.targets.main.linear.scope.query_file"}
    ]

    for {configured_path, value, diagnostic_path} <- cases do
      snapshot =
        paths
        |> valid_snapshot()
        |> put_in(
          [Access.key!(:targets), "main", Access.key!(:configured) | configured_path],
          value
        )
        |> Validation.validate()

      assert_target_error(snapshot, "main", diagnostic_path, :unsafe_path)
    end
  end

  @tag :tmp_dir
  test "rejects non-absolute, missing, non-file, and unresolvable paths", %{paths: paths} do
    cases = [
      {["repo", "path"], "relative/repo", "$.targets.main.repo.path"},
      {["repo", "path"], Path.join(Path.dirname(paths.repo), "missing"), "$.targets.main.repo.path"},
      {["repo", "path"], paths.loop, "$.targets.main.repo.path"},
      {["worktree", "root"], "relative/worktree", "$.targets.main.worktree.root"},
      {["repo", "manifest"], "missing.yml", "$.targets.main.repo.manifest"},
      {["repo", "manifest"], paths.outside_file, "$.targets.main.repo.manifest"},
      {["repo", "manifest"], "loop.yml", "$.targets.main.repo.manifest"}
    ]

    for {configured_path, value, diagnostic_path} <- cases do
      snapshot =
        paths
        |> valid_snapshot()
        |> put_in(
          [Access.key!(:targets), "main", Access.key!(:configured) | configured_path],
          value
        )
        |> Validation.validate()

      assert_target_error(snapshot, "main", diagnostic_path, :unsafe_path)
    end

    unsafe_state =
      paths
      |> valid_snapshot()
      |> put_in([Access.key!(:host), "state_root"], paths.loop)
      |> Validation.validate()

    refute unsafe_state.globally_valid?
    assert_diagnostic(unsafe_state, :host, "$.host.state_root", :unsafe_path)
  end

  @tag :tmp_dir
  test "sorts and deduplicates diagnostics for equivalent target insertion orders", %{paths: paths} do
    alpha = put_in(valid_target(paths), ["linear", "connection"], "missing")

    beta =
      paths
      |> valid_target()
      |> put_in(["worktree", "root"], Path.join(Path.dirname(paths.worktree), "second"))
      |> put_in(["runners", "allowed"], ["missing"])
      |> put_in(["runners", "default"], "missing")

    forward =
      paths
      |> valid_snapshot(Map.new([{"alpha", alpha}, {"beta", beta}]))
      |> Validation.validate()

    reverse =
      paths
      |> valid_snapshot(Map.new([{"beta", beta}, {"alpha", alpha}]))
      |> Validation.validate()

    assert diagnostic_values(forward.diagnostics) == diagnostic_values(reverse.diagnostics)

    assert diagnostic_values(Validation.validate(forward).diagnostics) ==
             diagnostic_values(forward.diagnostics)

    assert forward.diagnostics ==
             Enum.sort_by(forward.diagnostics, fn diagnostic ->
               {scope_order(diagnostic.scope), diagnostic.path, diagnostic.code, diagnostic.message}
             end)
  end

  @tag :tmp_dir
  test "contains target errors and makes unsafe host state roots globally invalid", %{paths: paths} do
    relative_state =
      paths
      |> valid_snapshot()
      |> put_in([Access.key!(:host), "state_root"], "relative/state")
      |> Validation.validate()

    refute relative_state.globally_valid?
    assert_diagnostic(relative_state, :host, "$.host.state_root", :unsafe_path)

    overlapping_state =
      paths
      |> valid_snapshot()
      |> put_in([Access.key!(:host), "state_root"], paths.repo)
      |> Validation.validate()

    refute overlapping_state.globally_valid?
    assert_diagnostic(overlapping_state, :host, "$.host.state_root", :path_overlap)

    second_worktree = Path.join(Path.dirname(paths.worktree), "second")

    targets = %{
      "alpha" => valid_target(paths),
      "beta" => put_in(valid_target(paths), ["worktree", "root"], second_worktree)
    }

    snapshot = valid_snapshot(paths, targets)

    prior =
      %Diagnostic{
        severity: :error,
        scope: {:target, "alpha"},
        path: "$.targets.alpha.display_name",
        code: :prior_error,
        message: "existing target error"
      }

    alpha = snapshot.targets["alpha"]
    configured = put_in(alpha.configured, ["worktree", "root"], second_worktree)
    alpha = %{alpha | configured: configured, valid?: false, effective_state: :paused, diagnostics: [prior]}
    snapshot = put_in(snapshot.targets["alpha"], alpha)

    contained = Validation.validate(snapshot)

    refute contained.targets["alpha"].valid?
    assert contained.targets["alpha"].configured_state == :active
    assert contained.targets["alpha"].effective_state == :paused
    assert contained.targets["beta"].valid?
    assert contained.globally_valid?
    assert Enum.count(contained.diagnostics, &(&1 == prior)) == 1
  end

  @tag :tmp_dir
  test "fails closed without crashing on malformed snapshot containers and target data", %{paths: paths} do
    malformed_snapshot = %{valid_snapshot(paths) | host: :invalid, targets: :invalid, diagnostics: nil}
    contained_snapshot = Validation.validate(malformed_snapshot)

    refute contained_snapshot.globally_valid?
    assert contained_snapshot.targets == %{}
    assert_diagnostic(contained_snapshot, :registry, "$.targets", :invalid_snapshot)

    snapshot = valid_snapshot(paths)
    target = %{snapshot.targets["main"] | configured: :invalid}
    snapshot = put_in(snapshot.targets["main"], target)
    contained_target = Validation.validate(snapshot)

    assert Map.has_key?(contained_target.targets, "main")

    assert_target_error(
      contained_target,
      "main",
      "$.targets.main",
      :invalid_snapshot
    )

    nested_snapshot =
      paths
      |> valid_snapshot()
      |> put_in([Access.key!(:host), "runners"], :invalid)
      |> put_in(
        [Access.key!(:targets), "main", Access.key!(:configured), "linear"],
        :invalid
      )

    contained_nested = Validation.validate(nested_snapshot)

    refute contained_nested.globally_valid?
    assert_diagnostic(contained_nested, :host, "$.host.runners", :invalid_snapshot)
    assert_target_error(contained_nested, "main", "$.targets.main", :invalid_snapshot)

    assert Validation.validate(:invalid) == :invalid
    assert Validation.effective_gate(:invalid, "merge") == "deny"
    assert Validation.effective_gate(contained_target.targets["main"], "unknown") == "deny"

    raw_target_snapshot = %{valid_snapshot(paths) | targets: %{"raw" => :invalid}}
    assert Validation.validate(raw_target_snapshot).targets["raw"] == :invalid

    empty_target = %{
      valid_snapshot(paths).targets["main"]
      | configured: %{},
        valid?: false,
        effective_state: :paused,
        diagnostics: []
    }

    empty_snapshot = %{valid_snapshot(paths) | path: nil, targets: %{"main" => empty_target}}
    refute Validation.validate(empty_snapshot).targets["main"].valid?

    malformed_runners =
      paths
      |> valid_target()
      |> put_in(["runners"], %{"allowed" => :invalid, "default" => 12, "settings" => %{}})

    malformed_runner_snapshot =
      paths
      |> valid_snapshot(%{"main" => malformed_runners})
      |> Validation.validate()

    refute malformed_runner_snapshot.targets["main"].valid?

    malformed_allowed =
      put_in(valid_target(paths), ["runners", "allowed"], ["codex", 12])

    malformed_allowed_snapshot =
      paths
      |> valid_snapshot(%{"main" => malformed_allowed})
      |> Validation.validate()

    refute malformed_allowed_snapshot.targets["main"].valid?

    host_without_ceilings = put_in(valid_host(paths), ["capacity"], %{})

    target_without_runner =
      put_in(
        valid_target(paths),
        ["runners"],
        %{"allowed" => ["missing"], "default" => "missing", "settings" => %{}}
      )

    assert {:ok, no_ceiling_snapshot} =
             Schema.validate(%{
               "version" => 1,
               "host" => host_without_ceilings,
               "targets" => %{"main" => target_without_runner}
             })

    no_ceiling_snapshot = Validation.validate(%{no_ceiling_snapshot | path: paths.registry})
    refute no_ceiling_snapshot.globally_valid?
    refute no_ceiling_snapshot.targets["main"].valid?

    nonbinary_repo =
      paths
      |> valid_snapshot()
      |> put_in([Access.key!(:targets), "main", Access.key!(:configured), "repo", "path"], 12)
      |> Validation.validate()

    assert_target_error(nonbinary_repo, "main", "$.targets.main.repo.path", :unsafe_path)

    nonbinary_id =
      paths
      |> valid_snapshot(%{12 => valid_target(paths)})
      |> Validation.validate()

    assert Map.has_key?(nonbinary_id.targets, 12)
    refute nonbinary_id.targets[12].valid?

    unusual_scope =
      %Diagnostic{
        severity: :info,
        scope: :unexpected,
        path: "$",
        code: :existing_info,
        message: "existing diagnostic"
      }

    unusual_snapshot = %{valid_snapshot(paths) | diagnostics: [unusual_scope]}
    assert unusual_scope in Validation.validate(unusual_snapshot).diagnostics
  end

  defp valid_snapshot(paths), do: valid_snapshot(paths, %{"main" => valid_target(paths)})

  defp valid_snapshot(paths, targets) do
    document = %{"version" => 1, "host" => valid_host(paths), "targets" => targets}
    assert {:ok, snapshot} = Schema.validate(document)
    %{snapshot | path: paths.registry}
  end

  defp valid_target(paths) do
    %{
      "display_name" => "Main",
      "state" => "active",
      "dispatch_mode" => "explicit",
      "repo" => %{"path" => paths.repo, "manifest" => "symphony.yml"},
      "worktree" => %{"root" => paths.worktree, "strategy" => "per_issue", "hooks" => %{}},
      "linear" => %{
        "connection" => "linear-main",
        "scope" => %{"type" => "project", "project_id" => "project-1"},
        "active_states" => ["Todo", "In Progress"],
        "terminal_states" => ["Done"],
        "required_labels" => []
      },
      "runners" => %{"allowed" => ["codex"], "default" => "codex", "settings" => %{}},
      "concurrency" => %{
        "max_concurrent_agents" => 4,
        "max_concurrent_startups" => 2,
        "max_concurrent_reviewers" => 1,
        "by_linear_state" => %{"in progress" => 2}
      },
      "budgets" => %{
        "per_run" => %{"max_total_tokens" => 1_000},
        "daily" => %{"max_total_tokens" => 10_000},
        "weekly" => %{"max_total_tokens" => 50_000}
      },
      "checks" => %{
        "pre_dispatch" => ["capability_preflight"],
        "pre_handoff" => ["repo_validation", "quality_gate"],
        "pre_publish" => ["publish_preflight"],
        "pre_merge" => ["pr_checks", "review_feedback_sweep"]
      },
      "external_side_effects" => %{
        "tracker_write" => "deny",
        "vcs_publish" => "deny",
        "pull_request_write" => "deny",
        "merge" => "deny",
        "deployment" => "deny",
        "production_data" => "deny"
      },
      "scheduling" => %{"weight" => 10}
    }
  end

  defp valid_host(paths) do
    %{
      "id" => "local-host",
      "state_root" => paths.state,
      "polling" => %{"interval_ms" => 1_000, "max_concurrent_target_polls" => 2},
      "capacity" => %{
        "max_concurrent_agents" => 8,
        "max_concurrent_startups" => 4,
        "max_concurrent_reviewers" => 2
      },
      "scheduling" => %{
        "algorithm" => "weighted_deficit_round_robin",
        "max_credit_rounds" => 3
      },
      "tracker_connections" => %{
        "linear-main" => %{
          "kind" => "linear",
          "endpoint" => "https://api.linear.app/graphql",
          "api_key" => "$LINEAR_API_KEY"
        }
      },
      "runners" => %{
        "codex" => %{
          "kind" => "codex_app_server",
          "command" => ["codex", "app-server"],
          "max_concurrent_agents" => 6,
          "max_concurrent_startups" => 3
        },
        "claude" => %{
          "kind" => "codex_app_server",
          "command" => ["claude", "app-server"],
          "max_concurrent_agents" => 3,
          "max_concurrent_startups" => 2
        }
      }
    }
  end

  defp diagnostic_values(diagnostics) do
    Enum.map(diagnostics, &{&1.scope, &1.path, &1.code, &1.message})
  end

  defp scope_order(:registry), do: {0, ""}
  defp scope_order(:host), do: {1, ""}
  defp scope_order({:target, id}), do: {2, id}

  defp assert_diagnostic(snapshot, scope, path, code) do
    assert Enum.any?(
             snapshot.diagnostics,
             &(&1.scope == scope and &1.path == path and &1.code == code)
           )
  end

  defp assert_target_error(snapshot, id, path, code) do
    target = snapshot.targets[id]

    refute target.valid?
    assert target.effective_state == :paused
    assert Enum.any?(target.diagnostics, &(&1.path == path and &1.code == code))
  end
end
