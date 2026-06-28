defmodule SymphonyElixir.QualityGate.HostVisualQaTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.QualityGate.HostVisualQa, as: HostVisualQaSettings
  alias SymphonyElixir.QualityGate.HostVisualQa

  test "runs local command with visual QA env and reads manifest artifacts" do
    test_root = Path.join(System.tmp_dir!(), "symphony-host-visual-qa-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    artifact_root = Path.join(test_root, "artifacts")
    writer = Path.join(workspace, "write_manifest.exs")

    File.mkdir_p!(workspace)

    manifest =
      Jason.encode!(%{
        status: "passed",
        summary: "Captured desktop and mobile screenshots.",
        checks: [%{name: "viewport_screenshots", status: "passed"}],
        artifacts: [%{kind: "screenshot", label: "Desktop", path: "desktop.png"}]
      })

    File.write!(writer, """
    File.write!(System.fetch_env!("SYMPHONY_VISUAL_QA_MANIFEST"), #{inspect(manifest)})
    File.write!(Path.join(System.fetch_env!("SYMPHONY_VISUAL_QA_ARTIFACT_DIR"), "category.txt"), System.fetch_env!("SYMPHONY_VISUAL_QA_CATEGORY"))
    File.write!(Path.join(System.fetch_env!("SYMPHONY_VISUAL_QA_ARTIFACT_DIR"), "issue.txt"), System.fetch_env!("SYMPHONY_ISSUE_IDENTIFIER"))
    """)

    on_exit(fn -> File.rm_rf(test_root) end)

    elixir = System.find_executable("elixir") || "elixir"

    settings = %HostVisualQaSettings{
      command: "#{elixir} #{writer}",
      artifact_root: artifact_root,
      timeout_ms: 5_000
    }

    assert {:ok, result} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{host_visual_qa: settings},
               workspace: workspace,
               issue: %Issue{identifier: "SID-319", title: "Visual QA"},
               job: %{category: :product_visual_review}
             })

    assert result["status"] == "passed"
    assert result["summary"] == "Captured desktop and mobile screenshots."
    assert File.regular?(result["manifest_path"])
    assert File.read!(Path.join(result["artifact_dir"], "category.txt")) == "product_visual_review"
    assert File.read!(Path.join(result["artifact_dir"], "issue.txt")) == "SID-319"

    assert [
             %{
               "kind" => "screenshot",
               "label" => "Desktop",
               "summary" => "Host visual QA artifact captured.",
               "metadata" => %{"path" => "desktop.png"}
             }
           ] = result["artifacts"]
  end

  test "reports command failures and skips when not configured" do
    test_root = Path.join(System.tmp_dir!(), "symphony-host-visual-qa-failure-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert :skip =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{host_visual_qa: %HostVisualQaSettings{}},
               workspace: workspace,
               job: %{category: :product_visual_review}
             })

    settings = %HostVisualQaSettings{
      command: "printf 'missing browser Authorization: Bearer leak-token /tmp/symphony/secret.png api_key=abc123\\n' >&2; exit 7",
      artifact_root: Path.join(test_root, "artifacts"),
      timeout_ms: 5_000
    }

    assert {:error, {:host_visual_qa_command_failed, 7, output}} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{host_visual_qa: settings},
               workspace: workspace,
               issue: %Issue{identifier: "SID-319", title: "Visual QA"},
               job: %{category: :product_visual_review}
             })

    assert output =~ "missing browser"
    assert output =~ "Authorization: Bearer <redacted:secret>"
    assert output =~ "api_key=<redacted:secret>"
    assert output =~ "<redacted:absolute-path>"
    refute output =~ "leak-token"
    refute output =~ "/tmp/symphony"
  end

  test "runs local command with a clean visual QA environment" do
    test_root = Path.join(System.tmp_dir!(), "symphony-host-visual-qa-env-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    previous_linear_key = System.get_env("LINEAR_API_KEY")

    File.mkdir_p!(workspace)

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_linear_key)
      File.rm_rf(test_root)
    end)

    System.put_env("LINEAR_API_KEY", "linear-secret-sentinel")

    manifest = Jason.encode!(%{summary: "Clean environment confirmed."})

    settings = %HostVisualQaSettings{
      command:
        "if [ -n \"${LINEAR_API_KEY:-}\" ]; then printf 'Authorization: Bearer %s\\n' \"$LINEAR_API_KEY\" >&2; exit 9; fi; printf '%s' #{shell_quote(manifest)} > \"$SYMPHONY_VISUAL_QA_MANIFEST\"",
      artifact_root: Path.join(test_root, "artifacts"),
      timeout_ms: 5_000
    }

    assert {:ok, result} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{host_visual_qa: settings},
               workspace: workspace,
               issue: %Issue{identifier: "SID-319", title: "Visual QA"},
               job: %{category: :product_visual_review}
             })

    assert result["summary"] == "Clean environment confirmed."
  end

  test "runs remote command with clean env and reads returned manifest artifacts" do
    test_root = Path.join(System.tmp_dir!(), "symphony-host-visual-qa-remote-#{System.unique_integer([:positive])}")
    fake_bin = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    workspace = Path.join(test_root, "workspace")
    artifact_root = Path.join(test_root, "remote-artifacts")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")
    previous_artifact_root = System.get_env("SYMP_TEST_REMOTE_ARTIFACT_ROOT")

    File.mkdir_p!(fake_bin)
    File.mkdir_p!(workspace)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      restore_env("SYMP_TEST_REMOTE_ARTIFACT_ROOT", previous_artifact_root)
      File.rm_rf(test_root)
    end)

    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
    System.delete_env("SYMPHONY_SSH_CONFIG")
    System.put_env("SYMP_TEST_REMOTE_ARTIFACT_ROOT", artifact_root)

    File.write!(fake_ssh, """
    #!/bin/sh
    last=""
    for arg in "$@"; do
      last="$arg"
    done
    /bin/sh -lc "$last"
    status=$?
    rm -rf "${SYMP_TEST_REMOTE_ARTIFACT_ROOT:?}"
    exit "$status"
    """)

    File.chmod!(fake_ssh, 0o755)

    manifest =
      Jason.encode!(%{
        status: "passed",
        summary: "Remote screenshots passed.",
        artifacts: [%{kind: "screenshot", label: "Remote desktop", path: "remote-desktop.png"}]
      })

    settings = %HostVisualQaSettings{
      command: "printf '%s' #{shell_quote(manifest)} > \"$SYMPHONY_VISUAL_QA_MANIFEST\" && printf '%s' \"$SYMPHONY_VISUAL_QA_CATEGORY\" > \"$SYMPHONY_VISUAL_QA_ARTIFACT_DIR/category.txt\"",
      artifact_root: artifact_root,
      timeout_ms: 5_000
    }

    assert {:ok, result} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{host_visual_qa: settings},
               workspace: workspace,
               worker_host: "worker-a",
               issue: %Issue{identifier: "SID-319", title: "Visual QA"},
               job: %{category: :product_visual_review}
             })

    assert result["summary"] == "Remote screenshots passed."
    assert result["manifest_path"] =~ "visual-qa-manifest.json"

    assert [
             %{
               "kind" => "screenshot",
               "label" => "Remote desktop",
               "summary" => "Host visual QA artifact captured.",
               "metadata" => %{"path" => "remote-desktop.png"}
             }
           ] = result["artifacts"]
  end

  test "covers skip, workspace, artifact, path, and payload fallback edges" do
    test_root = Path.join(System.tmp_dir!(), "symphony-host-visual-qa-edges-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    artifact_root = Path.join(test_root, "artifacts")
    previous_path = System.get_env("PATH")

    File.mkdir_p!(workspace)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    assert :skip = HostVisualQa.run(%{})

    assert :skip =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{host_visual_qa: %HostVisualQaSettings{enabled: false, command: "printf '{}'"}},
               workspace: workspace
             })

    assert {:error, :workspace_unavailable} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{host_visual_qa: %HostVisualQaSettings{command: "printf '{}'"}}
             })

    artifact_file = Path.join(test_root, "artifact-root-file")
    File.write!(artifact_file, "not a directory")

    assert {:error, {:artifact_dir_unavailable, failed_dir, _reason}} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{
                 host_visual_qa: %HostVisualQaSettings{command: "printf '{}'", artifact_root: artifact_file}
               },
               workspace: workspace,
               issue: %{"identifier" => "***"}
             })

    assert failed_dir =~ "quality-gate"

    System.delete_env("PATH")

    assert {:ok, raw_result} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{
                 host_visual_qa: %HostVisualQaSettings{command: "printf '%s' \"$SYMPHONY_VISUAL_QA_CATEGORY\"", artifact_root: artifact_root, timeout_ms: nil}
               },
               workspace: workspace
             })

    assert raw_result["summary"] == "Host visual QA command completed."
    assert raw_result["raw_output"] =~ "product_visual_review"

    System.put_env("PATH", previous_path || "")

    assert {:ok, empty_manifest_result} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{
                 host_visual_qa: %HostVisualQaSettings{command: ": > \"$SYMPHONY_VISUAL_QA_MANIFEST\"", artifact_root: artifact_root}
               },
               workspace: workspace
             })

    assert empty_manifest_result["summary"] == "Host visual QA command completed."
    assert empty_manifest_result["manifest_path"] =~ "visual-qa-manifest.json"

    non_list_manifest = Jason.encode!(%{artifacts: "bad", checks: "bad"})

    assert {:ok, non_list_result} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{
                 host_visual_qa: %HostVisualQaSettings{
                   command: "printf '%s' #{shell_quote(non_list_manifest)} > \"$SYMPHONY_VISUAL_QA_MANIFEST\"",
                   artifact_root: artifact_root
                 }
               },
               workspace: workspace
             })

    assert non_list_result["artifacts"] == []
    assert non_list_result["checks"] == []

    mixed_manifest =
      Jason.encode!(%{
        artifacts: ["raw artifact", %{kind: "note"}, %{kind: "meta", metadata: "bad"}],
        checks: ["manual"]
      })

    assert {:ok, mixed_result} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{
                 host_visual_qa: %HostVisualQaSettings{
                   command: "printf '%s' #{shell_quote(mixed_manifest)} > \"$SYMPHONY_VISUAL_QA_MANIFEST\"",
                   artifact_root: artifact_root
                 }
               },
               workspace: workspace
             })

    assert [
             %{"kind" => "artifact", "label" => "artifact", "summary" => "raw artifact"},
             %{"kind" => "note"},
             %{"kind" => "meta", "metadata" => "bad"}
           ] = mixed_result["artifacts"]

    assert [%{"name" => "host_visual_qa", "status" => "manual"}] = mixed_result["checks"]
  end

  test "reports command timeout" do
    test_root = Path.join(System.tmp_dir!(), "symphony-host-visual-qa-timeout-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:error, {:host_visual_qa_timeout, 1}} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{
                 host_visual_qa: %HostVisualQaSettings{
                   command: "sleep 1",
                   artifact_root: Path.join(test_root, "artifacts"),
                   timeout_ms: 1
                 }
               },
               workspace: workspace
             })
  end

  test "reports remote ssh and wrapper failures" do
    test_root = Path.join(System.tmp_dir!(), "symphony-host-visual-qa-remote-failures-#{System.unique_integer([:positive])}")
    fake_bin = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    workspace = Path.join(test_root, "workspace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    File.mkdir_p!(fake_bin)
    File.mkdir_p!(workspace)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
    System.delete_env("SYMPHONY_SSH_CONFIG")

    settings = %HostVisualQaSettings{
      command: "printf '{}'",
      artifact_root: Path.join(test_root, "remote-artifacts"),
      timeout_ms: 5_000
    }

    File.write!(fake_ssh, "#!/bin/sh\nprintf 'remote shell failed\\n'\nexit 17\n")
    File.chmod!(fake_ssh, 0o755)

    assert {:error, {:host_visual_qa_command_failed, 17, "remote shell failed"}} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{host_visual_qa: settings},
               workspace: workspace,
               worker_host: "worker-a"
             })

    File.write!(fake_ssh, "#!/bin/sh\nprintf '__SYMPHONY_HOST_VISUAL_QA_STATUS__abc\\n'\nexit 0\n")
    File.chmod!(fake_ssh, 0o755)

    assert {:error, {:invalid_host_visual_qa_remote_output, output}} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{host_visual_qa: settings},
               workspace: workspace,
               worker_host: "worker-a"
             })

    assert output =~ "__SYMPHONY_HOST_VISUAL_QA_STATUS__abc"

    System.put_env("PATH", "")

    assert {:error, :ssh_not_found} =
             HostVisualQa.run(%{
               settings: %Schema.QualityGate{host_visual_qa: settings},
               workspace: workspace,
               worker_host: "worker-a"
             })
  end

  test "normalizes host visual QA schema strings" do
    blank_changeset =
      HostVisualQaSettings.changeset(%HostVisualQaSettings{}, %{
        command: " ",
        artifact_root: " /tmp/visual-artifacts "
      })

    assert blank_changeset.valid?

    blank_settings = Ecto.Changeset.apply_changes(blank_changeset)
    assert blank_settings.command == nil
    assert blank_settings.artifact_root == "/tmp/visual-artifacts"

    nil_changeset = HostVisualQaSettings.changeset(%HostVisualQaSettings{}, %{command: nil, artifact_root: nil})
    assert nil_changeset.valid?
  end

  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
