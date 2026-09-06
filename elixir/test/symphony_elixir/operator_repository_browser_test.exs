defmodule SymphonyElixir.OperatorRepositoryBrowserTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.OperatorRepositoryBrowser

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-repository-browser-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "scan emits the root at depth zero and stops at depth and result bounds", %{root: root} do
    File.mkdir_p!(Path.join(root, "one/two/three"))
    File.mkdir_p!(Path.join(root, ".git/objects"))
    File.mkdir_p!(Path.join(root, "deps/library"))

    context = %{roots: [root], max_depth: 1, max_results: 20, max_entries: 100}
    result = run(%{"action" => "scan"}, context)
    paths = candidate_paths(result)

    assert Path.expand(root) in paths
    assert Path.join(root, "one") in paths
    refute Path.join(root, "one/two") in paths
    refute Enum.any?(paths, &String.contains?(&1, "/.git/"))
    refute Enum.any?(paths, &String.contains?(&1, "/deps/"))

    bounded = run(%{"action" => "scan"}, %{context | max_depth: 10, max_results: 2})
    assert length(bounded.candidates) == 2
    assert bounded.status == "limit"
  end

  test "max_entries bounds visited filesystem entries in a large tree", %{root: root} do
    for index <- 1..100 do
      File.mkdir_p!(Path.join(root, "repository-#{index}"))
    end

    result =
      run(%{"action" => "scan"}, %{
        roots: [root],
        max_depth: 2,
        max_results: 100,
        max_entries: 5,
        timeout_ms: 1_000
      })

    assert result.visited <= 5
    assert length(result.candidates) <= 5
    assert result.status == "limit"
  end

  test "callback cancellation stops traversal without exceeding work bound", %{root: root} do
    File.mkdir_p!(Path.join(root, "one/two"))
    parent = self()

    result =
      run(
        %{"action" => "scan"},
        %{roots: [root], max_depth: 10, max_results: 100, max_entries: 100, timeout_ms: 1_000},
        fn event ->
          send(parent, {:repository_browser_event, event})
          :cancel
        end
      )

    assert result.status == "cancelled"
    assert result.visited <= 100
    assert_received {:repository_browser_event, %{type: "candidate"}}
  end

  test "process cancellation is observed between bounded filesystem operations", %{root: root} do
    File.mkdir_p!(Path.join(root, "one/two"))
    parent = self()

    task =
      Task.async(fn ->
        run(
          %{"action" => "scan"},
          %{roots: [root], max_depth: 10, max_results: 100, max_entries: 100, timeout_ms: 1_000},
          fn event ->
            send(parent, {:repository_browser_event, event})

            receive do
              :release -> :ok
            end
          end
        )
      end)

    assert_receive {:repository_browser_event, %{type: "candidate"}}, 1_000
    send(task.pid, :cancel)
    send(task.pid, :release)
    assert %{status: "cancelled"} = Task.await(task, 1_000)
  end

  test "discovery does not mutate a read-only candidate or run repository code", %{root: root} do
    readonly = Path.join(root, "readonly")
    File.mkdir!(readonly)
    manifest = Path.join(readonly, "symphony.yml")
    content = "hooks:\n  after_create: touch must-not-exist\n"
    File.write!(manifest, content)
    File.chmod!(readonly, 0o500)

    try do
      result = run(%{"action" => "scan"}, %{roots: [readonly], max_depth: 2, timeout_ms: 1_000})
      assert candidate_paths(result) == [Path.expand(readonly)]
      assert File.ls!(readonly) == ["symphony.yml"]
      assert File.read!(manifest) == content
      assert {:ok, %{mode: mode}} = File.stat(readonly)
      assert Bitwise.band(mode, 0o777) == 0o500
    after
      File.chmod!(readonly, 0o700)
    end
  end

  test "permission errors are incremental and do not stop readable siblings", %{root: root} do
    blocked = Path.join(root, "blocked")
    sibling = Path.join(root, "sibling")
    File.mkdir!(blocked)
    File.mkdir!(sibling)
    File.chmod!(blocked, 0o000)
    parent = self()

    try do
      assert {:error, :eacces} = File.ls(blocked)

      result =
        run(%{"action" => "scan"}, %{roots: [root], max_depth: 2}, fn event ->
          send(parent, {:discovery, event})
          :ok
        end)

      assert result.status == "partial"
      assert sibling in candidate_paths(result)
      assert %{path: blocked, reason: :unreadable} in result.errors
      assert_received {:discovery, %{type: "error", error: %{path: ^blocked, reason: :unreadable}}}
    after
      File.chmod!(blocked, 0o700)
    end
  end

  test "timeout retains incremental results and reports why traversal stopped", %{root: root} do
    File.mkdir!(Path.join(root, "child"))

    result =
      run(%{"action" => "scan"}, %{roots: [root], timeout_ms: 10}, fn
        %{type: "candidate"} ->
          Process.sleep(20)
          :ok

        _ ->
          :ok
      end)

    assert result.status == "timeout"
    assert candidate_paths(result) == [root]
    assert Enum.count(result.errors, &(&1.reason == :timeout)) == 1
  end

  test "duplicate roots and symlink cycles do not consume traversal limits", %{root: root} do
    File.mkdir!(Path.join(root, "child"))
    File.ln_s!(root, Path.join(root, "child/cycle"))
    result = run(%{"action" => "scan"}, %{roots: [root, root], max_depth: 10, max_entries: 20})

    assert result.status == "ok"
    assert Enum.sort(candidate_paths(result)) == [root, Path.join(root, "child")]
  end

  test "overlapping roots retain each root's depth budget", %{root: root} do
    nested = Path.join(root, "nested")
    leaf = Path.join(nested, "leaf")
    File.mkdir_p!(leaf)

    for roots <- [[root, nested], [nested, root]] do
      result = run(%{"action" => "scan"}, %{roots: roots, max_depth: 1})
      assert result.status == "ok"
      assert Enum.sort(candidate_paths(result)) == Enum.sort([root, nested, leaf])
    end
  end

  test "reports a missing root as unreadable", %{root: root} do
    missing = Path.join(root, "missing")
    result = run(%{"action" => "scan"}, %{roots: [missing], max_entries: 10, timeout_ms: 1_000})

    assert result.candidates == []
    assert Enum.any?(result.errors, &(&1.reason == :unreadable))
  end

  test "root lexical exclusions survive canonicalization through a hidden symlink", %{root: root} do
    state_root = Path.join(root, "state")
    outside = Path.join(root, "outside")
    lexical_root = Path.join(state_root, ".hidden/link")
    File.mkdir_p!(Path.dirname(lexical_root))
    File.mkdir_p!(outside)
    File.ln_s!(outside, lexical_root)

    result =
      run(%{"action" => "scan"}, %{
        roots: [lexical_root],
        max_depth: 1,
        max_results: 20,
        max_entries: 20,
        timeout_ms: 1_000
      })

    assert result.candidates == []
    refute Enum.any?(result.errors, &(&1.path == outside))
  end

  test "missing roots consume bounded work before filesystem access", %{root: root} do
    missing_roots = Enum.map(1..5, &Path.join(root, "missing-#{&1}"))

    result =
      run(%{"action" => "scan"}, %{
        roots: missing_roots,
        max_entries: 1,
        max_results: 20,
        timeout_ms: 1_000
      })

    assert result.visited == 1
    assert length(result.errors) == 1
    assert result.status == "limit"
  end

  test "recent reports stale paths and continues with readable paths", %{root: root} do
    stale = Path.join(root, "stale")
    recent = Path.join(root, "recent")
    File.mkdir!(recent)

    result =
      run(%{"action" => "recent"}, %{
        recent: [stale, recent],
        max_entries: 10,
        max_results: 20,
        timeout_ms: 1_000
      })

    assert candidate_paths(result) == [recent]
    assert %{path: stale, reason: :unreadable} in result.errors
    assert result.status == "partial"
  end

  test "deduplicates canonical symlink aliases and rejects symlink escapes", %{root: root} do
    real = Path.join(root, "real")
    outside = Path.join(Path.dirname(root), "symphony-browser-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(real)
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.join(outside, "secret"))
    File.ln_s!(real, Path.join(root, "alias"))
    File.ln_s!(outside, Path.join(root, "escape"))

    try do
      result = run(%{"action" => "scan"}, %{roots: [root], max_depth: 1, timeout_ms: 1_000})
      paths = candidate_paths(result)

      assert Enum.count(paths, &(&1 == Path.expand(real))) == 1
      refute Enum.any?(paths, &String.contains?(&1, "symphony-browser-outside-"))
      refute Enum.any?(result.errors, &String.contains?(to_string(&1.path), "secret"))
    after
      File.rm_rf(outside)
    end
  end

  test "excluded physical roots and excluded ancestors apply to explicit modes", %{root: root} do
    excluded = Path.join(root, "excluded")
    allowed = Path.join(root, "allowed")
    File.mkdir_p!(Path.join(excluded, "repo"))
    File.mkdir_p!(Path.join(allowed, "repo"))
    File.mkdir_p!(Path.join(root, ".hidden/repo"))

    context = %{roots: [root], excluded_roots: [excluded], max_depth: 2, timeout_ms: 1_000}

    assert run(%{"action" => "manual", "path" => Path.join(excluded, "repo")}, context).candidates == []
    assert run(%{"action" => "manual", "path" => Path.join(root, ".hidden/repo")}, context).candidates == []

    browsed = run(%{"action" => "browse", "path" => root}, context)
    refute Enum.any?(candidate_paths(browsed), &String.contains?(&1, "/excluded"))
    refute Enum.any?(candidate_paths(browsed), &String.contains?(&1, "/.hidden"))
  end

  test "all modes return canonical directory candidates", %{root: root} do
    repo = Path.join(root, "repo")
    child = Path.join(root, "child")
    File.mkdir_p!(repo)
    File.mkdir_p!(child)

    context = %{roots: [root], recent: [repo], max_depth: 1, max_results: 20, max_entries: 100, timeout_ms: 1_000}

    assert candidate_paths(run(%{"action" => "recent"}, context)) == [Path.expand(repo)]
    assert candidate_paths(run(%{"action" => "manual", "path" => repo}, context)) == [Path.expand(repo)]
    assert Path.expand(child) in candidate_paths(run(%{"action" => "browse", "path" => root}, context))
    assert Path.expand(root) in candidate_paths(run(%{"action" => "scan"}, context))

    assert Enum.all?(run(%{"action" => "scan"}, context).candidates, fn candidate ->
             candidate.kind == "directory" and Path.type(candidate.path) == :absolute
           end)
  end

  test "manual entry distinguishes files, missing paths, and escaping links", %{root: root} do
    file = Path.join(root, "file")
    missing = Path.join(root, "missing")
    link = Path.join(root, "escape")
    File.write!(file, "not a directory")
    File.ln_s!(Path.dirname(root), link)

    for {path, reason} <- [{file, :not_directory}, {missing, :unreadable}, {link, :unsafe_symlink}] do
      result = run(%{"action" => "manual", "path" => path}, %{})
      assert result.status == "error"
      assert result.candidates == []
      assert result.errors == [%{path: path, reason: reason}]
    end
  end

  test "explicit scan rejects outside roots and applies exclusions before traversal", %{root: root} do
    hidden = Path.join(root, "private_cache")
    File.mkdir!(hidden)
    context = %{roots: [root], exclusions: ["PRIVATE_CACHE"]}

    outside = run(%{"action" => "scan", "path" => Path.dirname(root)}, context)
    assert outside.status == "error"
    assert [%{reason: :outside_allowed_root}] = outside.errors

    for action <- ["scan", "browse"] do
      excluded = run(%{"action" => action, "path" => hidden}, context)
      assert excluded.candidates == []
      assert excluded.errors == []
    end
  end

  test "explicit browsing rejects escaping links and reports missing directories", %{root: root} do
    link = Path.join(root, "escape")
    File.ln_s!(Path.dirname(root), link)
    escaped = run(%{"action" => "browse", "path" => link}, %{})
    assert escaped.status == "error"
    assert [%{reason: :unsafe_symlink}] = escaped.errors

    missing = run(%{"action" => "browse", "path" => Path.join(root, "missing")}, %{})
    assert missing.status == "partial"
    assert [%{reason: :unreadable}] = missing.errors
  end

  test "cancellation before explicit work returns no candidates", %{root: root} do
    for action <- ["manual", "browse", "recent"] do
      send(self(), :cancel)
      result = run(%{"action" => action, "path" => root}, %{recent: [root]})
      assert result.status == "cancelled"
      assert result.candidates == []
      assert result.visited == 0
    end
  end

  test "cancelling an error event preserves that error and stops later recent entries", %{root: root} do
    result =
      run(%{"action" => "recent"}, %{recent: [Path.join(root, "missing"), root]}, fn
        %{type: "error"} -> :cancel
        _event -> :ok
      end)

    assert result.status == "cancelled"
    assert result.candidates == []
    assert [%{reason: :unreadable}] = result.errors
  end

  test "unresolvable links produce errors without losing readable siblings", %{root: root} do
    loop = Path.join(root, "loop")
    sibling = Path.join(root, "sibling")
    File.ln_s!(loop, loop)
    File.mkdir!(sibling)

    for action <- ["browse", "scan"] do
      result = run(%{"action" => action, "path" => root}, %{roots: [root], max_depth: 1})
      assert result.status == "partial"
      assert sibling in candidate_paths(result)
      assert %{path: loop, reason: :unreadable} in result.errors
    end
  end

  test "unresolvable explicit paths fail without returning candidates", %{root: root} do
    loop = Path.join(root, "loop")
    File.ln_s!(loop, loop)
    path = Path.join(loop, "child")

    for action <- ["manual", "browse", "scan"] do
      result = run(%{"action" => action, "path" => path}, %{roots: [root]})
      assert result.status == "error"
      assert result.candidates == []
      assert result.errors == [%{path: path, reason: :unreadable}]
    end
  end

  test "explicit filesystem root policy allows a bounded selected subtree", %{root: root} do
    result = run(%{"action" => "scan", "path" => root}, %{roots: ["/"], max_depth: 0})
    assert result.status == "ok"
    assert candidate_paths(result) == [root]
  end

  test "process cancellation is observed after an unreadable entry", %{root: root} do
    loop = Path.join(root, "loop")
    File.ln_s!(loop, loop)

    result =
      run(%{"action" => "browse", "path" => root}, %{}, fn %{type: "error"} ->
        send(self(), :cancel)
        :ok
      end)

    assert result.status == "cancelled"
    assert result.errors == [%{path: loop, reason: :unreadable}]
  end

  test "timeout remains primary when its notification is cancelled", %{root: root} do
    result =
      run(%{"action" => "manual", "path" => root}, %{timeout_ms: 10}, fn
        %{type: "candidate"} ->
          Process.sleep(20)
          :ok

        %{type: "error"} ->
          :cancel
      end)

    assert result.status == "timeout"
    assert candidate_paths(result) == [root]
    assert result.errors == [%{path: nil, reason: :timeout}]
  end

  test "browsing never returns the parent through a self-referential child link", %{root: root} do
    child = Path.join(root, "child")
    File.mkdir!(child)
    File.ln_s!(root, Path.join(root, "self"))

    result = run(%{"action" => "browse", "path" => root}, %{})
    assert result.status == "ok"
    assert candidate_paths(result) == [child]
  end

  test "replacement symlinks cannot redirect an already checked scan root", %{root: root} do
    for replacement <- [:root, :ancestor] do
      parent = Path.join(root, Atom.to_string(replacement))
      scanned = Path.join(parent, "workspace")
      moved = parent <> "-moved"
      outside = parent <> "-outside"
      File.mkdir_p!(scanned)
      File.mkdir_p!(Path.join(outside, "workspace"))

      result =
        run(%{"action" => "scan", "path" => scanned}, %{roots: [scanned]}, fn
          %{type: "candidate", candidate: %{path: ^scanned}} ->
            if replacement == :root do
              File.rename!(scanned, moved)
              File.ln_s!(outside, scanned)
            else
              File.rename!(parent, moved)
              File.ln_s!(outside, parent)
            end

            :ok

          _event ->
            :ok
        end)

      assert result.status == "partial"
      assert result.errors == [%{path: scanned, reason: :unreadable}]
      assert candidate_paths(result) == [scanned]
    end
  end

  defp run(request, context, emit \\ fn _event -> :ok end), do: OperatorRepositoryBrowser.run(request, context, emit)
  defp candidate_paths(result), do: Enum.map(result.candidates, & &1.path)
end
