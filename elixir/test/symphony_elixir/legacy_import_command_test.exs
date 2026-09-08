defmodule SymphonyElixir.LegacyImportCommandTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HostCLI
  alias SymphonyElixir.HostScheduler.Registry
  alias SymphonyElixir.OperatorCommandService
  alias SymphonyElixir.OperatorCommandService.Command
  alias SymphonyElixir.TargetRegistry.Composition
  alias SymphonyElixir.TargetRegistry.Preview
  alias SymphonyElixir.TargetRegistry.Revisions
  alias SymphonyElixir.TargetRegistry.Yaml
  alias SymphonyElixir.Workflow.Manifest

  @manifest_fixture_source Path.expand("../fixtures/target_registry/repos/symphony", __DIR__)

  @tag :tmp_dir
  test "cutover plans non-mutating and confirms an atomic paused migration", %{tmp_dir: tmp_dir} do
    {registry_path, repo} = cutover_fixtures(tmp_dir)
    local_config = write_local_config(tmp_dir)
    legacy_registry = write_legacy_registry(tmp_dir, repo)
    registry_before = File.read!(registry_path)

    command = %Command.LegacyImport{
      local_config: local_config,
      legacy_registry: legacy_registry,
      connection_id: "linear-main"
    }

    assert {:ok, plan} = OperatorCommandService.plan(command, registry_path: registry_path)
    assert plan.applicable?, inspect(plan.preview, limit: :infinity)
    assert plan.action == :legacy_import
    assert plan.target_id == "host"

    legacy_preview = plan.preview["legacy_import"]
    assert legacy_preview["applicable?"] == true

    assert [%{"kind" => "local_config"}, %{"kind" => "legacy_registry"}, %{"kind" => "repo_manifest"}] =
             Enum.map(legacy_preview["sources"], &Map.take(&1, ["kind"]))

    for source <- legacy_preview["sources"] do
      assert %{"checksum" => checksum} = source
      assert Preview.generation(File.read!(source["path"])) == checksum
    end

    assert Enum.any?(legacy_preview["parity"], &(&1["verdict"] == "preserved"))

    # Preview never mutates the registry.
    assert File.read!(registry_path) == registry_before

    assert {:ok, result} = OperatorCommandService.confirm("host", plan.id, true, registry_path: registry_path)
    assert result.committed?
    assert result.old_generation != result.new_generation

    {:ok, document} = Yaml.decode(File.read!(registry_path))
    target = document["targets"]["legacy-app"]
    assert target["state"] == "paused"
    refute Map.has_key?(target, "dispatch_mode")
    refute Map.has_key?(target["repo"], "manifest")
    assert get_in(target, ["repository_policy", "project", "slug"]) == "symphony-fixture"

    assert document["host"]["tracker_connections"]["linear-main"]["api_key"] == "$LINEAR_API_KEY"
    assert document["host"]["runners"]["codex"]["max_concurrent_agents"] == 1

    # The pre-cutover registry is archived for recovery before replacement,
    # and the cutover leaves a durable provenance record beside the archive.
    assert {:ok, history} = Revisions.history(registry_path)

    {:ok, before_document} = Yaml.decode(registry_before)
    {:ok, before_revision} = Composition.canonical_hash(before_document)
    assert Enum.any?(history, &(&1["revision"] == before_revision))

    provenance_path =
      Path.join(
        Path.expand(registry_path <> ".revisions"),
        "import-#{result.plan_id}.json"
      )

    {:ok, provenance} = provenance_path |> File.read!() |> Jason.decode()
    assert provenance["kind"] == "legacy_import"
    assert provenance["plan_id"] == result.plan_id
    assert provenance["old_generation"] == result.old_generation
    assert provenance["new_generation"] == result.new_generation
    assert map_size(provenance["source_hashes"]) == 3
  end

  @tag :tmp_dir
  test "a source path ending in _access_token still confirms and records provenance", %{tmp_dir: tmp_dir} do
    {registry_path, repo} = cutover_fixtures(tmp_dir)
    local_config = write_local_config(tmp_dir)
    # The whole source filename ends in _access_token: credential scanning
    # must treat source_hashes keys as paths, not credential field names.
    legacy_registry = write_legacy_registry(tmp_dir, repo, "legacy_access_token")

    command = %Command.LegacyImport{local_config: local_config, legacy_registry: legacy_registry}
    assert {:ok, plan} = OperatorCommandService.plan(command, registry_path: registry_path)
    assert plan.applicable?, inspect(plan.preview, limit: :infinity)

    assert {:ok, result} = OperatorCommandService.confirm("host", plan.id, true, registry_path: registry_path)
    assert result.committed?

    provenance_path =
      Path.join(
        Path.expand(registry_path <> ".revisions"),
        "import-#{result.plan_id}.json"
      )

    {:ok, provenance} = provenance_path |> File.read!() |> Jason.decode()
    assert provenance["kind"] == "legacy_import"
    assert Map.has_key?(provenance["source_hashes"], legacy_registry)
  end

  @tag :tmp_dir
  test "source races invalidate the preview and never write", %{tmp_dir: tmp_dir} do
    {registry_path, repo} = cutover_fixtures(tmp_dir)
    local_config = write_local_config(tmp_dir)
    legacy_registry = write_legacy_registry(tmp_dir, repo)
    registry_before = File.read!(registry_path)

    command = %Command.LegacyImport{local_config: local_config, legacy_registry: legacy_registry}
    assert {:ok, plan} = OperatorCommandService.plan(command, registry_path: registry_path)

    File.write!(local_config, File.read!(local_config) <> "# edited mid-flight\n")

    assert {:error, %OperatorCommandService.Error{code: :import_source_changed}} =
             OperatorCommandService.confirm("host", plan.id, true, registry_path: registry_path)

    assert File.read!(registry_path) == registry_before
  end

  @tag :tmp_dir
  test "a source changing during confirmation never commits stale bytes", %{tmp_dir: tmp_dir} do
    {registry_path, repo} = cutover_fixtures(tmp_dir)
    local_config = write_local_config(tmp_dir)
    legacy_registry = write_legacy_registry(tmp_dir, repo)
    original = File.read!(local_config)
    registry_before = File.read!(registry_path)

    command = %Command.LegacyImport{local_config: local_config, legacy_registry: legacy_registry}
    assert {:ok, plan} = OperatorCommandService.plan(command, registry_path: registry_path)

    # The local config reads as the previewed bytes while the pipeline starts
    # (hash verification passes) and changes before the final unchanged
    # verification, exercising the exact read-verify gap.
    reads = :counters.new(1, [])

    racing_reader = fn path ->
      if path == local_config do
        :counters.add(reads, 1, 1)
        if :counters.get(reads, 1) <= 1, do: {:ok, original}, else: {:ok, original <> "# raced\n"}
      else
        File.read(path)
      end
    end

    assert {:error, %OperatorCommandService.Error{code: :import_source_changed}} =
             OperatorCommandService.confirm("host", plan.id, true,
               registry_path: registry_path,
               read_file: racing_reader
             )

    assert File.read!(registry_path) == registry_before
  end

  @tag :tmp_dir
  test "repeated import is an explicit no-op and divergent targets conflict", %{tmp_dir: tmp_dir} do
    {registry_path, repo} = cutover_fixtures(tmp_dir)
    local_config = write_local_config(tmp_dir)
    legacy_registry = write_legacy_registry(tmp_dir, repo)

    command = %Command.LegacyImport{local_config: local_config, legacy_registry: legacy_registry}
    assert {:ok, plan} = OperatorCommandService.plan(command, registry_path: registry_path)
    assert {:ok, _result} = OperatorCommandService.confirm("host", plan.id, true, registry_path: registry_path)
    migrated = File.read!(registry_path)

    assert {:ok, again} = OperatorCommandService.plan(command, registry_path: registry_path)
    assert again.applicable?
    assert Enum.any?(again.preview["legacy_import"]["field_dispositions"], &(&1["action"] == "unchanged"))
    assert again.proposed_generation == Preview.generation(migrated)

    diverged = write_diverged_legacy_registry(tmp_dir, legacy_registry)

    assert {:ok, conflict} =
             OperatorCommandService.plan(%Command.LegacyImport{legacy_registry: diverged}, registry_path: registry_path)

    refute conflict.applicable?

    assert Enum.any?(
             conflict.preview["legacy_import"]["import_diagnostics"],
             &(&1["code"] == "target_conflict" and &1["path"] == "$.targets.legacy-app")
           )
  end

  @tag :tmp_dir
  test "differing host values between the sources and the registry block", %{tmp_dir: tmp_dir} do
    {registry_path, repo} = cutover_fixtures(tmp_dir)
    registry_before = File.read!(registry_path)
    conflicting_config = write_local_config(tmp_dir, polling_interval: 61_000)
    legacy_registry = write_legacy_registry(tmp_dir, repo)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.LegacyImport{local_config: conflicting_config, legacy_registry: legacy_registry},
               registry_path: registry_path
             )

    refute plan.applicable?
    refute plan.id

    assert Enum.any?(
             plan.preview["legacy_import"]["import_diagnostics"],
             &(&1["code"] == "host_entry_conflict" and &1["path"] == "$.host.polling.interval_ms")
           )

    assert File.read!(registry_path) == registry_before
  end

  @tag :tmp_dir
  test "unsupported local configuration fields block the cutover instead of being dropped", %{tmp_dir: tmp_dir} do
    {registry_path, repo} = cutover_fixtures(tmp_dir)
    dogfood_config = write_local_config(tmp_dir)
    legacy_registry = write_legacy_registry(tmp_dir, repo)

    File.write!(
      dogfood_config,
      File.read!(dogfood_config) <>
        """
        agent:
          default_runner: "omp"
          max_turns: 20
        workspace:
          root: "~/dev/symphony-workspaces"
        repository_browser:
          roots: []
        """
    )

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.LegacyImport{local_config: dogfood_config, legacy_registry: legacy_registry},
               registry_path: registry_path
             )

    refute plan.applicable?

    blocked_paths =
      plan.preview["legacy_import"]["import_diagnostics"]
      |> Enum.filter(&(&1["code"] == "unsupported_field"))
      |> Enum.map(& &1["path"])
      |> MapSet.new()

    assert MapSet.subset?(MapSet.new(["$.agent", "$.workspace", "$.repository_browser"]), blocked_paths)
  end

  @tag :tmp_dir
  test "migrated policy stays authoritative after the legacy manifest changes or disappears", %{tmp_dir: tmp_dir} do
    # Isolated per-test repository: this test edits and deletes the manifest.
    repo = ready_repo(tmp_dir, "authority")
    registry_path = write_current_registry(tmp_dir)
    local_config = write_local_config(tmp_dir)
    legacy_registry = write_legacy_registry(tmp_dir, repo)
    manifest_path = Path.join(repo, "symphony.yml")
    original_manifest = File.read!(manifest_path)

    command = %Command.LegacyImport{local_config: local_config, legacy_registry: legacy_registry}

    try do
      assert {:ok, plan} = OperatorCommandService.plan(command, registry_path: registry_path)
      assert {:ok, _result} = OperatorCommandService.confirm("host", plan.id, true, registry_path: registry_path)

      {:ok, %{snapshot: before_snapshot}} = Registry.load(registry_path)
      before_policy_hash = before_snapshot.targets["legacy-app"].policy_hash
      assert before_policy_hash

      # Editing the legacy manifest after cutover cannot change host policy.
      File.write!(manifest_path, String.replace(original_manifest, "mix test", "mix test.only-one"))

      assert {:ok, %{snapshot: edited_snapshot}} = Registry.load(registry_path)
      assert edited_snapshot.targets["legacy-app"].policy_hash == before_policy_hash

      # Neither can removing it entirely: registry loads never reread manifests.
      File.rm!(manifest_path)

      assert {:ok, %{snapshot: removed_snapshot}} = Registry.load(registry_path)
      assert removed_snapshot.targets["legacy-app"].policy_hash == before_policy_hash
    after
      File.write!(manifest_path, original_manifest)
    end
  end

  @tag :tmp_dir
  test "an in-place legacy registry migrates through the same contract", %{tmp_dir: tmp_dir} do
    repo = ready_repo(tmp_dir, "in-place")
    legacy_registry = write_legacy_registry(tmp_dir, repo)

    # The legacy registry IS the migration target registry.
    registry_path = Path.join(tmp_dir, "targets.yml")
    File.cp!(legacy_registry, registry_path)

    command = %Command.LegacyImport{legacy_registry: legacy_registry, local_config: write_local_config(tmp_dir)}
    assert {:ok, plan} = OperatorCommandService.plan(command, registry_path: registry_path)
    assert plan.applicable?
    assert plan.id

    assert {:ok, result} = OperatorCommandService.confirm("host", plan.id, true, registry_path: registry_path)
    assert result.committed?

    {:ok, document} = Yaml.decode(File.read!(registry_path))
    target = document["targets"]["legacy-app"]
    assert target["state"] == "paused"
    refute Map.has_key?(target, "dispatch_mode")
    refute Map.has_key?(target["repo"], "manifest")
    assert target["repository_policy"]["project"]["slug"] == "symphony-fixture"

    # A host restart loads the migrated registry as the only authority.
    assert {:ok, %{snapshot: snapshot}} = Registry.load(registry_path)
    assert snapshot.targets["legacy-app"].policy_hash
  end

  @tag :tmp_dir
  test "weakened compiled manifests block confirmation", %{tmp_dir: tmp_dir} do
    {registry_path, repo} = cutover_fixtures(tmp_dir)
    legacy_registry = write_legacy_registry(tmp_dir, repo)

    {:ok, manifest} = Manifest.read(Path.join(repo, "symphony.yml"), repo_setup?: true)
    %{config: %{"manifest" => compiled}} = Manifest.compile(manifest)

    weakened =
      compiled
      |> put_in(["validation", "commands"], [])
      |> put_in(["capabilities", "required"], [])

    command = %Command.LegacyImport{legacy_registry: legacy_registry}

    assert {:ok, plan} =
             OperatorCommandService.plan(command,
               registry_path: registry_path,
               load_legacy_manifest: fn _path -> {:ok, weakened} end
             )

    refute plan.applicable?

    codes = Enum.flat_map(plan.preview["legacy_import"]["parity"], &Enum.map(&1["findings"], fn f -> f["code"] end))
    assert "validation_command_dropped" in codes
    assert "required_capability_dropped" in codes
  end

  @tag :tmp_dir
  test "registries with unknown root keys or unsupported versions fail closed", %{tmp_dir: tmp_dir} do
    repo = ready_repo(tmp_dir, "closed")
    legacy_registry = write_legacy_registry(tmp_dir, repo)

    for document <- [
          %{"version" => 1, "host" => %{"id" => "h"}, "targets" => %{}, "extra" => %{}},
          %{"version" => 2, "host" => %{"id" => "h"}, "targets" => %{}}
        ] do
      path = Path.join(tmp_dir, "targets.yml")
      File.write!(path, Yaml.encode(document))

      assert {:error, %OperatorCommandService.Error{code: :invalid_registry}} =
               OperatorCommandService.plan(%Command.LegacyImport{legacy_registry: legacy_registry},
                 registry_path: path
               )
    end
  end

  @tag :tmp_dir
  test "invalid commands and missing sources stay typed", %{tmp_dir: tmp_dir} do
    registry_path = write_current_registry(tmp_dir)

    assert {:error, %OperatorCommandService.Error{code: :invalid_command}} =
             OperatorCommandService.plan(%Command.LegacyImport{local_config: nil, legacy_registry: nil},
               registry_path: registry_path
             )

    assert {:error, %OperatorCommandService.Error{code: :registry_not_found}} =
             OperatorCommandService.plan(%Command.LegacyImport{legacy_registry: "/definitely/missing/targets.yml"},
               registry_path: "/definitely/missing/registry.yml"
             )

    assert {:error, %OperatorCommandService.Error{code: :source_unreadable}} =
             OperatorCommandService.plan(%Command.LegacyImport{legacy_registry: "/definitely/missing/targets.yml"},
               registry_path: registry_path
             )
  end

  @tag :tmp_dir
  test "an invalid target budget cannot receive a confirmation plan", %{tmp_dir: tmp_dir} do
    {registry_path, repo} = cutover_fixtures(tmp_dir)
    source = write_legacy_registry(tmp_dir, repo)
    {:ok, document} = source |> File.read!() |> Yaml.decode()
    document = update_in(document, ["targets", "legacy-app", "budgets"], &Map.delete(&1, "daily"))
    File.write!(source, Yaml.encode(document))
    command = %Command.LegacyImport{legacy_registry: source, local_config: write_local_config(tmp_dir)}
    assert {:ok, plan} = OperatorCommandService.plan(command, registry_path: registry_path)
    refute plan.applicable?
    assert is_nil(plan.id)
  end

  @tag :tmp_dir
  test "malformed local restrictions cannot be silently discarded", %{tmp_dir: tmp_dir} do
    {registry_path, _repo} = cutover_fixtures(tmp_dir)
    source = Path.join(tmp_dir, "malformed.yml")

    for document <- [%{"capacity_ceiling" => -1}, %{"tracker" => "restricted"}, %{"deployment" => %{"ceilings" => []}}] do
      File.write!(source, Yaml.encode(document))

      assert {:ok, plan} =
               OperatorCommandService.plan(%Command.LegacyImport{local_config: source}, registry_path: registry_path)

      refute plan.applicable?
      assert is_nil(plan.id)
    end
  end

  @tag :tmp_dir
  test "malformed target entries in the current registry block planning with typed errors", %{tmp_dir: tmp_dir} do
    {registry_path, repo} = cutover_fixtures(tmp_dir)
    legacy_registry = write_legacy_registry(tmp_dir, repo)

    {:ok, document} = registry_path |> File.read!() |> Yaml.decode()
    File.write!(registry_path, Yaml.encode(put_in(document, ["targets"], %{"scalar-entry" => 42})))
    registry_before = File.read!(registry_path)

    assert {:ok, plan} =
             OperatorCommandService.plan(%Command.LegacyImport{legacy_registry: legacy_registry},
               registry_path: registry_path
             )

    refute plan.applicable?
    assert is_nil(plan.id)

    assert Enum.any?(
             plan.preview["legacy_import"]["import_diagnostics"],
             &(&1["code"] == "invalid_type" and &1["path"] == "$.targets.scalar-entry")
           )

    assert File.read!(registry_path) == registry_before
  end

  @tag :tmp_dir
  test "malformed target entries in the legacy source block planning with typed errors", %{tmp_dir: tmp_dir} do
    {registry_path, repo} = cutover_fixtures(tmp_dir)
    source = write_legacy_registry(tmp_dir, repo)

    {:ok, document} = source |> File.read!() |> Yaml.decode()
    File.write!(source, Yaml.encode(put_in(document, ["targets", "list-entry"], ["invalid"])))
    registry_before = File.read!(registry_path)

    assert {:ok, plan} =
             OperatorCommandService.plan(
               %Command.LegacyImport{local_config: write_local_config(tmp_dir), legacy_registry: source},
               registry_path: registry_path
             )

    refute plan.applicable?
    assert is_nil(plan.id)

    assert Enum.any?(
             plan.preview["legacy_import"]["import_diagnostics"],
             &(&1["code"] == "invalid_type" and &1["path"] == "$.targets.list-entry")
           )

    assert File.read!(registry_path) == registry_before
  end

  @tag :tmp_dir
  test "the CLI previews and confirms the cutover through the same contract", %{tmp_dir: tmp_dir} do
    {registry_path, repo} = cutover_fixtures(tmp_dir)
    local_config = write_local_config(tmp_dir)
    legacy_registry = write_legacy_registry(tmp_dir, repo)

    assert {:ok, output} =
             HostCLI.evaluate(
               [
                 "config",
                 "import",
                 "--local-config",
                 local_config,
                 "--legacy-registry",
                 legacy_registry,
                 "--registry",
                 registry_path,
                 "--json"
               ],
               %{}
             )

    assert {:ok, decoded} = Jason.decode(output)
    assert decoded["action"] == "legacy_import"
    assert decoded["applicable?"] == true
    plan_id = decoded["id"]
    assert is_binary(plan_id) and plan_id != ""

    assert {:ok, confirm_output} =
             HostCLI.evaluate(
               ["config", "import", "--confirm", plan_id, "--registry", registry_path, "--json"],
               %{}
             )

    assert {:ok, confirmed} = Jason.decode(confirm_output)
    assert confirmed["action"] == "legacy_import"
    assert confirmed["committed?"] == true

    assert {:error, _usage} = HostCLI.evaluate(["config", "import"], %{})
    assert {:error, _usage} = HostCLI.evaluate(["config", "import", "--local-config", local_config, "--confirm", plan_id], %{})
  end

  @tag :tmp_dir
  test "config recover exports a paused host-owned document from an archived revision", %{tmp_dir: tmp_dir} do
    repo = ready_repo(tmp_dir, "recover")
    legacy_registry = write_legacy_registry(tmp_dir, repo)

    # Archive the legacy registry as a source revision of this registry path.
    registry_path = Path.join(tmp_dir, "targets.yml")
    File.cp!(legacy_registry, registry_path)
    {:ok, document} = Yaml.decode(File.read!(registry_path))
    {:ok, revision} = Composition.canonical_hash(document)
    assert :ok = Revisions.archive(registry_path, File.read!(registry_path))

    assert {:error, "config_recovery_requires_host_owned_revision"} =
             HostCLI.evaluate(["config", "recover", "--revision", revision, "--registry", registry_path], %{})

    command = %Command.LegacyImport{legacy_registry: legacy_registry, local_config: write_local_config(tmp_dir)}
    assert {:ok, plan} = OperatorCommandService.plan(command, registry_path: registry_path)
    assert plan.applicable?
    assert {:ok, _} = OperatorCommandService.confirm("host", plan.id, true, registry_path: registry_path)
    {:ok, migrated} = registry_path |> File.read!() |> Yaml.decode()
    {:ok, revision} = Composition.canonical_hash(migrated)

    # Recovery uses the archived host policy even after source files disappear.
    File.rm!(Path.join(repo, "symphony.yml"))
    File.rm!(legacy_registry)

    active = put_in(migrated, ["targets", "legacy-app", "state"], "active")
    active = put_in(active, ["targets", "legacy-app", "dispatch_mode"], "watch")
    assert :ok = Revisions.archive(registry_path, Yaml.encode(active))
    {:ok, active_revision} = Composition.canonical_hash(active)

    assert {:ok, paused_output} =
             HostCLI.evaluate(["config", "recover", "--revision", active_revision, "--registry", registry_path], %{})

    {:ok, paused} = Yaml.decode(paused_output)
    assert paused["targets"]["legacy-app"]["state"] == "paused"
    refute Map.has_key?(paused["targets"]["legacy-app"], "dispatch_mode")

    assert {:ok, output} =
             HostCLI.evaluate(
               ["config", "recover", "--revision", revision, "--registry", registry_path],
               %{}
             )

    {:ok, recovered} = Yaml.decode(output)
    target = recovered["targets"]["legacy-app"]
    assert target["state"] == "paused"
    refute Map.has_key?(target, "dispatch_mode")
    refute Map.has_key?(target["repo"], "manifest")
    assert target["repository_policy"]["project"]["slug"] == "symphony-fixture"

    assert {:error, _usage} = HostCLI.evaluate(["config", "recover", "--registry", registry_path], %{})
    assert {:error, _failed} = HostCLI.evaluate(["config", "recover", "--revision", "sha256:#{String.duplicate("0", 64)}", "--registry", registry_path], %{})
  end

  # ------------------------------------------------------------------
  # Fixtures
  # ------------------------------------------------------------------

  defp cutover_fixtures(tmp_dir) do
    {write_current_registry(tmp_dir), ready_repo(tmp_dir, "cutover")}
  end

  defp ready_repo(tmp_dir, name) do
    repo = Path.join(Path.dirname(tmp_dir), Path.basename(tmp_dir) <> "-" <> name)
    if File.exists?(repo), do: File.rm_rf!(repo)
    File.cp_r!(@manifest_fixture_source, repo)
    git!(repo, ["init", "--initial-branch=main"])
    git!(repo, ["remote", "add", "origin", "https://github.com/example/symphony-fixture.git"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=Legacy Command Tests", "-c", "user.email=legacy-command-tests@example.invalid", "commit", "-m", "fixture"])
    repo
  end

  defp write_current_registry(tmp_dir) do
    path = Path.join(tmp_dir, "targets.yml")

    document = %{
      "version" => 1,
      "host" => %{
        "id" => "current-host",
        "capabilities" => ["github_pr", "browser"],
        "state_root" => Path.join(Path.dirname(tmp_dir), "state-" <> Path.basename(tmp_dir)),
        "polling" => %{"interval_ms" => 45_000, "max_concurrent_target_polls" => 1},
        "capacity" => %{
          "max_concurrent_agents" => 20,
          "max_concurrent_startups" => 1,
          "max_concurrent_reviewers" => 1
        },
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 4},
        "tracker_connections" => %{},
        "runners" => %{}
      },
      "targets" => %{}
    }

    File.write!(path, Yaml.encode(document))
    path
  end

  # Host-mappable fields only; anything else blocks the cutover by design.
  defp write_local_config(tmp_dir, opts \\ []) do
    path = Path.join(tmp_dir, "config.yml")
    interval = Keyword.get(opts, :polling_interval, 45_000)

    File.write!(path, """
    version: 1
    tracker:
      kind: "linear"
      endpoint: "https://api.linear.app/graphql"
      api_key: "$LINEAR_API_KEY"
    polling:
      interval_ms: #{interval}
    capacity_ceiling: 20
    runners:
      codex:
        kind: "codex_app_server"
        command: ["codex", "app-server"]
        approval_policy: "never"
    """)

    path
  end

  defp write_legacy_registry(tmp_dir, repo, name \\ "legacy-targets.yml") do
    path = Path.join(tmp_dir, name)

    document = %{
      "version" => 1,
      "host" => %{
        "id" => "legacy-host",
        "capabilities" => ["github_pr", "browser"],
        "state_root" => Path.join(Path.dirname(tmp_dir), "legacy-state-" <> Path.basename(tmp_dir)),
        "polling" => %{"interval_ms" => 45_000, "max_concurrent_target_polls" => 1},
        "capacity" => %{
          "max_concurrent_agents" => 20,
          "max_concurrent_startups" => 1,
          "max_concurrent_reviewers" => 1
        },
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 4},
        "tracker_connections" => %{
          "linear-main" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "$LINEAR_API_KEY"
          }
        },
        "runners" => %{}
      },
      "targets" => %{"legacy-app" => legacy_target(repo)}
    }

    File.write!(path, Yaml.encode(document))
    path
  end

  defp write_diverged_legacy_registry(tmp_dir, original) do
    path = Path.join(tmp_dir, "diverged-legacy-targets.yml")
    {:ok, document} = Yaml.decode(File.read!(original))
    diverged = put_in(document, ["targets", "legacy-app", "display_name"], "Diverged")
    File.write!(path, Yaml.encode(diverged))
    path
  end

  defp legacy_target(repo) do
    %{
      "state" => "active",
      "dispatch_mode" => "watch",
      "repo" => %{"path" => repo, "manifest" => "symphony.yml"},
      "worktree" => %{
        "root" => Path.join(System.tmp_dir!(), "legacy-command-worktrees-#{System.unique_integer([:positive])}"),
        "strategy" => "per_issue"
      },
      "linear" => %{
        "connection" => "linear-main",
        "scope" => %{"type" => "project", "project_id" => "legacy-project-001"},
        "active_states" => ["Todo", "In Progress"],
        "terminal_states" => ["Done", "Canceled"],
        "required_labels" => []
      },
      "runners" => %{"allowed" => ["codex"], "default" => "codex", "settings" => %{}},
      "concurrency" => %{
        "max_concurrent_agents" => 1,
        "max_concurrent_startups" => 1,
        "max_concurrent_reviewers" => 1
      },
      "budgets" => %{
        "per_run" => %{"max_total_tokens" => 500_000},
        "daily" => %{"max_total_tokens" => 5_000_000},
        "weekly" => %{"max_total_tokens" => 20_000_000}
      },
      "checks" => %{"pre_dispatch" => []},
      "external_side_effects" => %{
        "tracker_write" => "allow",
        "vcs_publish" => "manual_approval",
        "pull_request_write" => "manual_approval",
        "merge" => "deny",
        "deployment" => "deny",
        "production_data" => "deny"
      },
      "scheduling" => %{"weight" => 10}
    }
  end

  defp git!(repo, args) do
    {output, status} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    assert status == 0, output
  end
end
