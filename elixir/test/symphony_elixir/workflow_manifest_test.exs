defmodule SymphonyElixir.WorkflowManifestTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import ExUnit.CaptureIO

  alias SymphonyElixir.Workflow.Check
  alias SymphonyElixir.Workflow.Manifest
  alias SymphonyElixir.Workflow.ModuleRegistry
  alias SymphonyElixir.WorkflowStore

  test "workflow loader uses repo symphony.yml when no explicit workflow path is set" do
    repo_root = Path.expand("../../..", __DIR__)
    original_cwd = File.cwd!()
    original_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)

    try do
      Application.delete_env(:symphony_elixir, :workflow_file_path)
      File.cd!(repo_root)

      assert SymphonyElixir.Workflow.workflow_source_path() == Path.join(repo_root, "symphony.yml")
      assert {:ok, loaded} = SymphonyElixir.Workflow.load()
      assert loaded.config["tracker"]["project_slug"] == "symphony-self-contained-workflow-modules-72083cd8c253"
      assert loaded.prompt_template =~ "Linear Workpad"
    after
      File.cd!(original_cwd)
      restore_app_env(:workflow_file_path, original_workflow_path)
    end
  end

  test "workflow source resolver falls back to WORKFLOW.md when no manifest exists" do
    test_root = make_test_root!()
    original_cwd = File.cwd!()
    original_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)

    try do
      Application.delete_env(:symphony_elixir, :workflow_file_path)
      File.cd!(test_root)

      assert Path.expand(SymphonyElixir.Workflow.workflow_source_path()) == Path.expand(Path.join(test_root, "WORKFLOW.md"))
    after
      File.cd!(original_cwd)
      restore_app_env(:workflow_file_path, original_workflow_path)
    end
  end

  test "workflow loader accepts an explicit manifest path" do
    manifest_path = Path.expand("../../../symphony.yml", __DIR__)

    assert {:ok, loaded} = SymphonyElixir.Workflow.load(manifest_path)
    assert loaded.config["tracker"]["project_slug"] == "symphony-self-contained-workflow-modules-72083cd8c253"
    assert loaded.prompt_template =~ "Linear Workpad"
  end

  test "current repo manifest resolves through the bundled core module" do
    manifest_path = Path.expand("../../../symphony.yml", __DIR__)

    assert {:ok, resolved} = Manifest.compile(manifest_path)
    assert resolved.project_name == "Symphony"
    assert resolved.preset == "core"
    assert [%{id: "core_delivery", version: 1}] = resolved.modules
    assert resolved.config["tracker"]["project_slug"] == "symphony-self-contained-workflow-modules-72083cd8c253"
    assert resolved.prompt =~ "Linear Workpad"
    refute resolved.prompt =~ "symphony-linear"
    assert Path.expand("../../../symphony.yml", __DIR__) in resolved.source_paths
    assert Enum.any?(resolved.source_paths, &String.ends_with?(&1, "/priv/workflow_modules/core_delivery.yml"))
    assert resolved.policy_hash =~ ~r/^sha256:[a-f0-9]{64}$/
  end

  test "workflow store reloads when a selected module source changes" do
    test_root = make_test_root!()
    module_root = Path.join(test_root, "modules")
    manifest_path = Path.join(test_root, "symphony.yml")
    original_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    original_module_root = Application.get_env(:symphony_elixir, :workflow_modules_root)

    File.mkdir_p!(module_root)
    File.write!(Path.join(test_root, "README.md"), "# Fixture\n")
    write_fixture_module!(module_root, "First prompt.")
    write_fixture_manifest!(manifest_path)

    try do
      Application.put_env(:symphony_elixir, :workflow_file_path, manifest_path)
      Application.put_env(:symphony_elixir, :workflow_modules_root, module_root)

      assert {:ok, state} = WorkflowStore.init([])
      assert state.workflow.prompt == "First prompt."

      write_fixture_module!(module_root, "Second prompt.")

      assert {:noreply, reloaded_state} = WorkflowStore.handle_info(:poll, state)
      assert reloaded_state.workflow.prompt == "Second prompt."
      refute reloaded_state.stamp == state.stamp
    after
      restore_app_env(:workflow_file_path, original_workflow_path)
      restore_app_env(:workflow_modules_root, original_module_root)
    end
  end

  test "workflow store keeps the last good workflow when a selected module source disappears" do
    test_root = make_test_root!()
    module_root = Path.join(test_root, "modules")
    manifest_path = Path.join(test_root, "symphony.yml")
    module_path = Path.join(module_root, "fixture.yml")
    original_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    original_module_root = Application.get_env(:symphony_elixir, :workflow_modules_root)

    File.mkdir_p!(module_root)
    File.write!(Path.join(test_root, "README.md"), "# Fixture\n")
    write_fixture_module!(module_root, "Stable prompt.")
    write_fixture_manifest!(manifest_path)

    try do
      Application.put_env(:symphony_elixir, :workflow_file_path, manifest_path)
      Application.put_env(:symphony_elixir, :workflow_modules_root, module_root)

      assert {:ok, state} = WorkflowStore.init([])
      assert state.workflow.prompt == "Stable prompt."

      File.rm!(module_path)

      log =
        capture_log(fn ->
          assert {:noreply, retained_state} = WorkflowStore.handle_info(:poll, state)
          assert retained_state.workflow.prompt == "Stable prompt."
          assert retained_state.stamp == state.stamp
        end)

      assert log =~ "Failed to reload workflow path="
    after
      restore_app_env(:workflow_file_path, original_workflow_path)
      restore_app_env(:workflow_modules_root, original_module_root)
    end
  end

  test "workflow check prints resolved module metadata and policy hash" do
    manifest_path = Path.expand("../../../symphony.yml", __DIR__)

    output =
      capture_io(fn ->
        assert :ok = Check.run(["--manifest", manifest_path])
      end)

    assert output =~ "Workflow check OK"
    assert output =~ "core_delivery@1"
    assert output =~ "policy_hash: sha256:"
    assert output =~ "WORKFLOW.md is a legacy/runtime export path"
  end

  test "manifest runtime overrides module defaults in compiled config" do
    test_root = make_test_root!()
    module_root = Path.join(test_root, "modules")
    File.mkdir_p!(module_root)
    File.write!(Path.join(test_root, "README.md"), "# Fixture\n")

    File.write!(
      Path.join(module_root, "fixture.yml"),
      """
      id: fixture
      version: 1
      summary: Fixture module
      config:
        tracker:
          kind: linear
          api_key: "$LINEAR_API_KEY"
          project_slug: old-project
        codex:
          command: codex app-server
      prompt: |
        Fixture prompt.
      """
    )

    manifest_path = Path.join(test_root, "symphony.yml")

    File.write!(
      manifest_path,
      """
      version: 1
      project:
        name: Fixture
      workflow:
        preset: core
        modules:
          - fixture
      docs:
        entrypoints:
          - README.md
      runtime:
        tracker:
          project_slug: new-project
      """
    )

    assert {:ok, resolved} = Manifest.compile(manifest_path, root: module_root)
    assert resolved.config["tracker"]["project_slug"] == "new-project"
    assert resolved.prompt == "Fixture prompt."
  end

  test "unknown modules fail with an actionable missing module error" do
    test_root = make_test_root!()
    module_root = Path.join(test_root, "modules")
    File.mkdir_p!(module_root)
    File.write!(Path.join(test_root, "README.md"), "# Fixture\n")

    manifest_path = Path.join(test_root, "symphony.yml")

    File.write!(
      manifest_path,
      """
      version: 1
      project:
        name: Fixture
      workflow:
        preset: core
        modules:
          - missing
      docs:
        entrypoints:
          - README.md
      """
    )

    assert {:error, reason} = Manifest.compile(manifest_path, root: module_root)
    assert Manifest.format_error(reason) =~ "Missing workflow module"
  end

  test "docs entrypoints must exist relative to the manifest" do
    test_root = make_test_root!()
    module_root = Path.join(test_root, "modules")
    File.mkdir_p!(module_root)

    File.write!(
      Path.join(module_root, "fixture.yml"),
      """
      id: fixture
      version: 1
      summary: Fixture module
      config:
        tracker:
          kind: memory
      prompt: |
        Fixture prompt.
      """
    )

    manifest_path = Path.join(test_root, "symphony.yml")

    File.write!(
      manifest_path,
      """
      version: 1
      project:
        name: Fixture
      workflow:
        preset: core
        modules:
          - fixture
      docs:
        entrypoints:
          - MISSING.md
      """
    )

    assert {:error, reason} = Manifest.compile(manifest_path, root: module_root)
    assert Manifest.format_error(reason) =~ ~s(docs.entrypoints contains missing file "MISSING.md")
  end

  test "module registry validates module metadata" do
    test_root = make_test_root!()
    module_root = Path.join(test_root, "modules")
    File.mkdir_p!(module_root)

    File.write!(
      Path.join(module_root, "fixture.yml"),
      """
      id: other
      version: 1
      summary: Fixture module
      config: {}
      prompt: |
        Fixture prompt.
      """
    )

    assert {:error, reason} = ModuleRegistry.resolve(["fixture"], root: module_root)
    assert Manifest.format_error(reason) =~ "id must be \"fixture\""
  end

  defp make_test_root! do
    root = Path.join(System.tmp_dir!(), "symphony-manifest-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root = File.cd!(root, &File.cwd!/0)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp write_fixture_module!(module_root, prompt) do
    File.write!(
      Path.join(module_root, "fixture.yml"),
      """
      id: fixture
      version: 1
      summary: Fixture module
      config:
        tracker:
          kind: memory
      prompt: |
        #{prompt}
      """
    )
  end

  defp write_fixture_manifest!(manifest_path) do
    File.write!(
      manifest_path,
      """
      version: 1
      project:
        name: Fixture
      workflow:
        preset: core
        modules:
          - fixture
      docs:
        entrypoints:
          - README.md
      """
    )
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
