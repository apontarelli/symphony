defmodule SymphonyElixir.PathSafetyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PathSafety

  test "handoff manifest accepts normalized source-code changes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-manifest-valid-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join([workspace, "lib", "source.ex"]), "defmodule Source, do: nil\n")

      assert {:ok,
              %{
                changed_files: ["lib/source.ex"],
                validation: [%{name: "mix test", status: "passed"}]
              }} =
               PathSafety.validate_handoff_manifest(workspace, %{
                 changed_files: ["lib/source.ex"],
                 validation: [%{name: "mix test", status: "passed"}]
               })
    after
      File.rm_rf(test_root)
    end
  end

  test "handoff manifest accepts string-keyed file lists and map entries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-manifest-map-entry-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join([workspace, "lib", "map_entry.ex"]), "defmodule MapEntry, do: nil\n")

      assert {:ok,
              %{
                changed_files: ["lib/map_entry.ex"],
                validation: [%{"name" => "mix test", "status" => "passed"}]
              }} =
               PathSafety.validate_handoff_manifest(workspace, %{
                 "files" => [%{"path" => "lib/map_entry.ex"}],
                 "checks" => [%{"name" => "mix test", "status" => "passed"}],
                 "ignored" => true
               })
    after
      File.rm_rf(test_root)
    end
  end

  test "handoff manifest accepts durable env templates" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-manifest-env-template-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, ".env.example"), "API_URL=http://localhost:4000\n")

      assert {:ok, %{changed_files: [".env.example"]}} =
               PathSafety.validate_handoff_manifest(workspace, %{
                 changed_files: [".env.example"]
               })
    after
      File.rm_rf(test_root)
    end
  end

  test "handoff manifest treats reserved local paths case-insensitively" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-manifest-casefold-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      assert {:error, %{failures: failures}} =
               PathSafety.validate_handoff_manifest(workspace, %{
                 changed_files: [".ENV", "TMP/scratch.txt", "APP.LOG", ".ENV.EXAMPLE"]
               })

      assert Enum.map(failures, & &1.reason) == [
               :local_secret,
               :generated_runtime_state,
               :generated_runtime_state
             ]

      assert Enum.map(failures, & &1.path) == [".ENV", "TMP/scratch.txt", "APP.LOG"]
    after
      File.rm_rf(test_root)
    end
  end

  test "handoff manifest rejects unsafe and non-durable paths with structured failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-manifest-unsafe-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      assert {:error, %{status: :failed, failures: failures, summary: summary}} =
               PathSafety.validate_handoff_manifest(workspace, %{
                 changed_files: [
                   "/etc/passwd",
                   "../outside.env",
                   "_build/dev/cache",
                   "deps/cache.txt",
                   "tmp/scratch.txt",
                   "log/symphony.log",
                   ".env"
                 ],
                 validation: [%{name: "mix test", status: "passed"}]
               })

      assert summary =~ "Changed-file manifest rejected"
      refute summary =~ "/etc/passwd"
      refute summary =~ "../outside.env"
      refute summary =~ ".env"

      assert Enum.map(failures, & &1.path) == [
               "/etc/passwd",
               "../outside.env",
               "_build/dev/cache",
               "deps/cache.txt",
               "tmp/scratch.txt",
               "log/symphony.log",
               ".env"
             ]

      assert Enum.map(failures, & &1.reason) == [
               :absolute_path,
               :path_traversal,
               :generated_runtime_state,
               :generated_runtime_state,
               :generated_runtime_state,
               :generated_runtime_state,
               :local_secret
             ]

      assert Enum.all?(failures, &is_binary(&1.message))
    after
      File.rm_rf(test_root)
    end
  end

  test "handoff manifest rejects credential paths and hidden caches without blocking source cache folders" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-manifest-credential-cache-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join([workspace, "lib", "cache"]))
      File.write!(Path.join([workspace, "lib", "cache", "source.ex"]), "defmodule CachedSource, do: nil\n")

      assert {:error, %{failures: failures}} =
               PathSafety.validate_handoff_manifest(workspace, %{
                 changed_files: [
                   ".ssh/id_rsa",
                   ".aws/credentials",
                   ".pytest_cache/README.md",
                   "cache/runtime.json",
                   "lib/cache/source.ex"
                 ]
               })

      assert Enum.map(failures, & &1.reason) == [
               :local_secret,
               :local_secret,
               :generated_runtime_state,
               :generated_runtime_state
             ]

      assert Enum.map(failures, & &1.path) == [
               ".ssh/id_rsa",
               ".aws/credentials",
               ".pytest_cache/README.md",
               "cache/runtime.json"
             ]
    after
      File.rm_rf(test_root)
    end
  end

  test "handoff manifest rejects symlink aliases to local secrets and runtime state" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-manifest-symlink-exclusions-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "_build"))
      File.write!(Path.join(workspace, ".env"), "TOKEN=secret\n")
      File.write!(Path.join([workspace, "_build", "cache.txt"]), "cache\n")
      File.ln_s!(".env", Path.join(workspace, "safe_env"))
      File.ln_s!("_build", Path.join(workspace, "safe_cache"))

      assert {:error, %{failures: failures}} =
               PathSafety.validate_handoff_manifest(workspace, %{
                 changed_files: ["safe_env", "safe_cache/cache.txt"]
               })

      assert Enum.map(failures, & &1.reason) == [:local_secret, :generated_runtime_state]
      assert Enum.map(failures, & &1.path) == ["safe_env", "safe_cache/cache.txt"]

      assert Enum.map(failures, & &1.metadata.resolved_relative_path) == [
               ".env",
               "_build/cache.txt"
             ]
    after
      File.rm_rf(test_root)
    end
  end

  test "handoff manifest rejects malformed payloads with structured failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-manifest-malformed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      assert_failure_reason(PathSafety.validate_handoff_manifest(workspace, "not a map"), :invalid_manifest)
      assert_failure_reason(PathSafety.validate_handoff_manifest(workspace, %{validation: []}), :missing_changed_files)
      assert_failure_reason(PathSafety.validate_handoff_manifest(workspace, %{changed_files: nil}), :invalid_manifest)
      assert_invalid_manifest_type(workspace, "lib/source.ex", "string")
      assert_invalid_manifest_type(workspace, true, "boolean")
      assert_failure_reason(PathSafety.validate_handoff_manifest(workspace, %{changed_files: []}), :empty_changed_files)

      assert {:error,
              %{
                failures: [%{reason: :invalid_manifest, metadata: %{aliases: aliases}}],
                summary: summary
              }} =
               PathSafety.validate_handoff_manifest(workspace, %{
                 :changed_files => ["lib/source.ex"],
                 "files" => ["../do-not-persist.env"]
               })

      assert aliases == ["changed_files", "files"]
      refute summary =~ "do-not-persist"
      refute summary =~ "lib/source.ex"

      assert {:error, %{failures: [%{path: "<manifest.changed_files[0]>", metadata: metadata}], summary: summary}} =
               PathSafety.validate_handoff_manifest(workspace, %{
                 changed_files: [%{"path" => nil, "secret" => "do-not-persist"}]
               })

      assert metadata == %{index: 0, type: "map"}
      refute summary =~ "do-not-persist"

      assert {:error, %{failures: [%{path: "<manifest.changed_files[0]>", metadata: metadata}]}} =
               PathSafety.validate_handoff_manifest(workspace, %{changed_files: [123]})

      assert metadata == %{index: 0, type: "integer"}

      assert_invalid_path_entry_type(workspace, 1.25, "float")
      assert_invalid_path_entry_type(workspace, [], "list")
      assert_invalid_path_entry_type(workspace, {:tuple, "secret"}, "term")

      assert_failure_reason(
        PathSafety.validate_handoff_manifest("  ", %{changed_files: ["lib/source.ex"]}),
        :workspace_unreadable
      )

      missing_workspace = Path.join(test_root, "missing")

      assert_failure_reason(
        PathSafety.validate_handoff_manifest(missing_workspace, %{changed_files: ["lib/source.ex"]}),
        :workspace_unreadable
      )

      file_workspace = Path.join(test_root, "workspace-file")
      File.write!(file_workspace, "not a directory\n")

      assert_failure_reason(
        PathSafety.validate_handoff_manifest(file_workspace, %{changed_files: ["lib/source.ex"]}),
        :workspace_unreadable
      )
    after
      File.rm_rf(test_root)
    end
  end

  test "handoff manifest rejects invalid path syntax and unreadable path resolution" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-manifest-invalid-paths-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join(workspace, "not-a-directory"), "file parent\n")

      assert {:error, %{failures: failures}} =
               PathSafety.validate_handoff_manifest(workspace, %{
                 changed_files: [
                   " ",
                   "lib/\nsource.ex",
                   "lib//source.ex",
                   "lib",
                   "not-a-directory/child.ex"
                 ]
               })

      assert Enum.map(failures, & &1.reason) == [
               :empty_path,
               :invalid_path,
               :not_normalized,
               :not_file,
               :path_unreadable
             ]

      refute Enum.any?(failures, &String.contains?(&1.message, "lib/\nsource.ex"))

      assert {:ok, %{changed_files: ["deleted_source.ex"]}} =
               PathSafety.validate_handoff_manifest(workspace, %{
                 changed_files: ["deleted_source.ex"]
               })
    after
      File.rm_rf(test_root)
    end
  end

  test "handoff manifest rejects symlink escapes under the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-manifest-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      outside = Path.join(test_root, "outside")

      File.mkdir_p!(workspace)
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(workspace, "linked"))

      assert {:error, %{failures: [%{reason: :outside_workspace, path: "linked/secret.txt"} = failure]}} =
               PathSafety.validate_handoff_manifest(workspace, %{
                 changed_files: ["linked/secret.txt"],
                 validation: [%{name: "mix test", status: "passed"}]
               })

      assert failure.message =~ "resolves outside the workspace"
      assert {:ok, canonical_workspace} = PathSafety.canonicalize(workspace)
      assert failure.metadata.workspace == canonical_workspace
    after
      File.rm_rf(test_root)
    end
  end

  test "handoff manifest rejects symlink cycles with structured failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-manifest-symlink-loop-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)
      File.ln_s!("loop", Path.join(workspace, "loop"))

      assert {:error, %{failures: [%{reason: :symlink_loop, path: "loop/source.ex"} = failure]}} =
               PathSafety.validate_handoff_manifest(workspace, %{
                 changed_files: ["loop/source.ex"]
               })

      assert failure.message =~ "symlink cycle"
    after
      File.rm_rf(test_root)
    end
  end

  defp assert_failure_reason(result, reason) do
    assert {:error, %{failures: [%{reason: ^reason}]}} = result
  end

  defp assert_invalid_manifest_type(workspace, changed_files, type) do
    assert {:error, %{failures: [%{metadata: %{type: ^type}}], summary: summary}} =
             PathSafety.validate_handoff_manifest(workspace, %{changed_files: changed_files})

    refute summary =~ "secret"
  end

  defp assert_invalid_path_entry_type(workspace, entry, type) do
    assert {:error, %{failures: [%{path: "<manifest.changed_files[0]>", metadata: metadata}], summary: summary}} =
             PathSafety.validate_handoff_manifest(workspace, %{changed_files: [entry]})

    assert metadata == %{index: 0, type: type}
    refute summary =~ "secret"
  end
end
