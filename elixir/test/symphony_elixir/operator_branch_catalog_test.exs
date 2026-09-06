defmodule SymphonyElixir.OperatorBranchCatalogTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OperatorBranchCatalog

  setup do
    repo = Path.join(System.tmp_dir!(), "operator-branches-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)
    git!(repo, ["init", "--initial-branch=main"])
    git!(repo, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial"])
    %{repo: repo, inspection: %{path: repo, state: "ready", vcs: "git", default_branch: "main"}}
  end

  test "local and remote-only branches are deduplicated without changing refs", context do
    git!(context.repo, ["remote", "add", "origin", "https://github.com/example/catalog.git"])
    git!(context.repo, ["branch", "feature"])
    git!(context.repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    git!(context.repo, ["update-ref", "refs/remotes/origin/remote-only", "HEAD"])
    git!(context.repo, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
    git!(context.repo, ["branch", "--set-upstream-to=origin/main", "feature"])
    git!(context.repo, ["branch", "origin/main"])
    before = git!(context.repo, ["show-ref"])

    catalog = OperatorBranchCatalog.discover(context.inspection, configured_target: "feature")

    assert catalog.status == "current"
    assert Enum.count(catalog.choices, &(&1.value == "main")) == 1
    assert Enum.find(catalog.choices, &(&1.value == "main")).current
    assert Enum.find(catalog.choices, &(&1.value == "main")).manifest_default
    assert Enum.find(catalog.choices, &(&1.value == "main")).remote_default
    assert Enum.find(catalog.choices, &(&1.value == "feature")).configured
    assert Enum.find(catalog.choices, &(&1.value == "feature")).remote_tracking
    assert Enum.any?(catalog.choices, &String.contains?(&1.value, "remote-only"))
    assert catalog.apply_allowed
    assert git!(context.repo, ["show-ref"]) == before
    assert git!(context.repo, ["symbolic-ref", "HEAD"]) == "refs/heads/main\n"
  end

  test "missing origin and detached HEAD still expose local branches", context do
    git!(context.repo, ["checkout", "--detach"])
    catalog = OperatorBranchCatalog.discover(context.inspection, configured_target: "main")
    assert catalog.status == "current"
    assert Enum.any?(catalog.choices, &(&1.value == "main"))
    refute Enum.any?(catalog.choices, & &1.current)
    assert catalog.apply_allowed
  end

  test "deleted configured target stays visible but cannot be applied", context do
    git!(context.repo, ["branch", "deleted"])
    git!(context.repo, ["branch", "-D", "deleted"])
    catalog = OperatorBranchCatalog.discover(context.inspection, configured_target: "deleted")
    choice = Enum.find(catalog.choices, &(&1.value == "deleted"))
    assert choice.configured
    assert choice.status == "stale"
    refute catalog.apply_allowed
  end

  test "non-ready repository does not execute commands", context do
    catalog =
      OperatorBranchCatalog.discover(%{context.inspection | state: "needs_setup"},
        command_runner: fn _, _, _ -> flunk("non-ready discovery executed a command") end
      )

    assert catalog.status == "unavailable"
    refute catalog.apply_allowed
  end

  test "malformed command output does not become branch choices", context do
    for output <- [
          <<255, 0, 10>>,
          "refs/heads/main" <> <<0, 0, 0, 32, 0>> <> String.duplicate("a", 39)
        ] do
      catalog =
        OperatorBranchCatalog.discover(context.inspection,
          command_runner: git_ref_runner(output)
        )

      assert catalog.status == "unavailable"
      assert catalog.choices == []
      refute catalog.apply_allowed
    end
  end

  test "command errors and timeout expose a typed fallback without raw output", context do
    for result <- [{:error, :timeout}, {:ok, {"private command failure", 128}}] do
      catalog =
        OperatorBranchCatalog.discover(context.inspection,
          command_runner: fn _, _, _ -> result end
        )

      assert catalog.status == "unavailable"
      assert catalog.typed_fallback
      refute catalog.apply_allowed
      refute inspect(catalog) =~ "private command failure"
    end
  end

  test "cancelled discovery does not run a command", context do
    catalog =
      OperatorBranchCatalog.discover(context.inspection,
        cancelled?: fn -> true end,
        command_runner: fn _, _, _ -> flunk("cancelled discovery executed a command") end
      )

    assert catalog.status == "unavailable"
    refute catalog.apply_allowed
  end

  test "typed fallback rejects invalid targets and cannot override cancellation", context do
    runner = fn _, _, _ -> {:error, :process_timeout} end
    valid = OperatorBranchCatalog.discover(context.inspection, configured_target: "typed-topic", command_runner: runner)
    assert valid.typed_fallback and valid.apply_allowed
    invalid = OperatorBranchCatalog.discover(context.inspection, configured_target: "../invalid", command_runner: runner)
    refute invalid.apply_allowed

    cancelled =
      OperatorBranchCatalog.discover(context.inspection,
        configured_target: "main",
        cancelled?: fn -> Process.get(:discovery_cancelled, false) end,
        command_runner: fn _, _, _ ->
          Process.put(:discovery_cancelled, true)
          {:ok, {"", 0}}
        end
      )

    assert cancelled.reason == "discovery_cancelled"
    refute cancelled.typed_fallback
    refute cancelled.apply_allowed
  end

  test "cancellation wins when a command times out", context do
    catalog =
      OperatorBranchCatalog.discover(context.inspection,
        configured_target: "main",
        cancelled?: fn -> Process.get(:discovery_cancelled, false) end,
        command_runner: fn _, _, _ ->
          Process.put(:discovery_cancelled, true)
          {:error, :process_timeout}
        end
      )

    Process.delete(:discovery_cancelled)
    assert catalog.reason == "discovery_cancelled"
    refute catalog.typed_fallback
    refute catalog.apply_allowed
  end

  test "an empty successful listing cannot be applied", context do
    catalog =
      OperatorBranchCatalog.discover(context.inspection,
        command_runner: fn _, _, _ -> {:ok, {"", 0}} end
      )

    assert catalog.status == "current"
    assert catalog.reason == nil
    assert catalog.choices == []
    refute catalog.typed_fallback
    refute catalog.apply_allowed
  end

  test "a branch can track another local branch", context do
    git!(context.repo, ["branch", "topic"])
    git!(context.repo, ["branch", "--set-upstream-to=main", "topic"])
    catalog = OperatorBranchCatalog.discover(context.inspection, configured_target: "topic")
    assert catalog.status == "current"
    choice = Enum.find(catalog.choices, &(&1.value == "topic"))
    assert choice.upstream == "main"
    refute choice.remote_tracking
    assert catalog.apply_allowed
  end

  test "refresh observes ref deletion rather than reusing the prior catalog", context do
    git!(context.repo, ["branch", "temporary"])
    first = OperatorBranchCatalog.discover(context.inspection, configured_target: "temporary")
    assert first.apply_allowed
    git!(context.repo, ["branch", "-D", "temporary"])
    second = OperatorBranchCatalog.discover(context.inspection, configured_target: "temporary")
    refute second.apply_allowed
    assert Enum.find(second.choices, &(&1.value == "temporary")).status == "stale"
  end

  test "Jujutsu bookmarks are read without snapshotting a changed working copy", context do
    git!(context.repo, ["remote", "add", "origin", "https://github.com/example/catalog.git"])
    git!(context.repo, ["update-ref", "refs/remotes/origin/remote-topic", "HEAD"])
    {_, 0} = System.cmd("jj", ["git", "init", "--colocate"], cd: context.repo, stderr_to_stdout: true)
    {_, 0} = System.cmd("jj", ["bookmark", "create", "topic", "-r", "@-"], cd: context.repo, stderr_to_stdout: true)
    {before, 0} = System.cmd("jj", ["--ignore-working-copy", "op", "log", "--no-graph", "-T", "id"], cd: context.repo)
    File.write!(Path.join(context.repo, "untracked"), "must not be snapshotted")
    catalog = OperatorBranchCatalog.discover(%{context.inspection | vcs: "jj"}, configured_target: "topic")
    assert catalog.status == "current"
    assert Enum.any?(catalog.choices, &(&1.value == "topic" and &1.configured))
    assert Enum.find(catalog.choices, &(&1.value == "remote-topic")).remote_refs == ["remote-topic@origin"]
    assert catalog.apply_allowed
    {after_discovery, 0} = System.cmd("jj", ["--ignore-working-copy", "op", "log", "--no-graph", "-T", "id"], cd: context.repo)
    assert before == after_discovery
  end

  test "invalid inspection inputs never authorize discovery", context do
    for inspection <- [nil, %{context.inspection | path: nil}, %{context.inspection | vcs: "svn"}] do
      catalog = OperatorBranchCatalog.discover(inspection)
      assert catalog.status == "unavailable"
      refute catalog.apply_allowed
      refute catalog.typed_fallback
    end
  end

  test "malformed Git records cannot be selected", context do
    object = String.duplicate("a", 40)

    for fields <- [
          ["missing fields"],
          ["refs/remotes/origin/bad..name", "", "", " ", object],
          ["refs/remotes/origin", "", "", " ", object],
          ["refs/tags/release", "", "", " ", object]
        ] do
      output = Enum.join(fields, <<0>>)
      catalog = OperatorBranchCatalog.discover(context.inspection, command_runner: git_ref_runner(output))
      assert catalog.reason == "discovery_output_invalid"
      assert catalog.choices == []
      refute catalog.apply_allowed
    end
  end

  test "invalid or timed out remote-default lookup does not return a current catalog", context do
    refs = Enum.join(["refs/heads/main", "", "", "*", String.duplicate("a", 40)], <<0>>)

    for result <- [{:ok, {"unexpected default\n", 0}}, {:error, :process_timeout}] do
      runner = fn
        ["git", "remote"], _, _ -> {:ok, {"", 0}}
        ["git", "for-each-ref" | _], _, _ -> {:ok, {refs, 0}}
        _, _, _ -> result
      end

      catalog = OperatorBranchCatalog.discover(context.inspection, command_runner: runner)
      assert catalog.status == "unavailable"
      refute catalog.apply_allowed
    end
  end

  test "malformed Jujutsu tracking records cannot become choices", context do
    for output <- ["missing fields", Enum.join(["topic", "origin", "unknown", "", ""], <<0>>), Enum.join(["bad..name", "origin", "present", "tracked", "tracking"], <<0>>)] do
      catalog =
        OperatorBranchCatalog.discover(%{context.inspection | vcs: "jj"},
          command_runner: fn _, _, _ -> {:ok, {output, 0}} end
        )

      assert catalog.reason == "discovery_output_invalid"
      assert catalog.choices == []
      refute catalog.apply_allowed
    end
  end

  test "adapter faults expose no private output and permit only explicit typed fallback", context do
    for runner <- [
          fn _, _, _ -> raise "private adapter failure" end,
          fn _, _, _ -> exit(:private_adapter_failure) end,
          fn _, _, _ -> {:error, :private_adapter_failure} end,
          fn _, _, _ -> {:ok, {String.duplicate("x", 262_145), 0}} end
        ] do
      catalog = OperatorBranchCatalog.discover(context.inspection, command_runner: runner)
      assert catalog.status == "unavailable"
      assert catalog.typed_fallback
      refute catalog.apply_allowed
      refute inspect(catalog) =~ "private_adapter_failure"
    end
  end

  test "a failed cancellation check cannot authorize typed fallback", context do
    for callback <- [fn -> raise "cancel failure" end, fn -> throw(:cancel_failure) end] do
      catalog = OperatorBranchCatalog.discover(context.inspection, configured_target: "main", cancelled?: callback)
      assert catalog.reason == "discovery_cancelled"
      refute catalog.apply_allowed
      refute catalog.typed_fallback
    end
  end

  test "invalid timeout input still performs bounded discovery", context do
    catalog = OperatorBranchCatalog.discover(context.inspection, timeout_ms: 0, configured_target: "main")
    assert catalog.status == "current"
    assert catalog.apply_allowed
  end

  test "slash-containing remote names preserve the remote-only branch value", context do
    git!(context.repo, ["remote", "add", "team/upstream", "https://github.com/example/catalog.git"])
    git!(context.repo, ["update-ref", "refs/remotes/team/upstream/topic", "HEAD"])
    catalog = OperatorBranchCatalog.discover(context.inspection, configured_target: "topic")
    assert catalog.apply_allowed
    choice = Enum.find(catalog.choices, &(&1.value == "topic"))
    assert choice.remote_names == ["team/upstream"]
    assert choice.remote_refs == ["refs/remotes/team/upstream/topic"]
  end

  test "malformed remote names cannot corrupt remote-only selections", context do
    catalog =
      OperatorBranchCatalog.discover(context.inspection,
        command_runner: fn _, _, _ -> {:ok, {"bad..remote\n", 0}} end
      )

    assert catalog.reason == "discovery_output_invalid"
    refute catalog.apply_allowed
  end

  test "typed fallback rejects special revisions rather than treating them as branches", context do
    runner = fn _, _, _ -> {:error, :process_timeout} end

    for branch <- ["HEAD", "@", "topic~1", "-topic", "topic//sub", "topic.lock"] do
      catalog = OperatorBranchCatalog.discover(context.inspection, configured_target: branch, command_runner: runner)
      refute catalog.apply_allowed
    end
  end

  defp git_ref_runner(output) do
    fn
      ["git", "remote"], _, _ -> {:ok, {"", 0}}
      ["git", "for-each-ref" | _], _, _ -> {:ok, {output, 0}}
    end
  end

  defp git!(repo, args) do
    {output, status} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
