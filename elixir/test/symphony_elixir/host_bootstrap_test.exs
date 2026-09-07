defmodule SymphonyElixir.HostBootstrapTest do
  use ExUnit.Case

  alias SymphonyElixir.{HostBootstrap, HostScheduler, LocalConfig}
  alias SymphonyElixir.TargetRegistry.Yaml

  test "first-use preview proposes both files without writing and is deterministic" do
    root = tmp_dir!("host-bootstrap-preview")

    assert {:ok,
            %{
              code: "setup_required",
              confirmation: token,
              files: files,
              existing: [],
              guidance: guidance
            }} = HostBootstrap.preview(config_root: root)

    assert is_binary(token) and token != ""
    assert [%{kind: :config}, %{kind: :registry}] = Enum.map(files, &Map.take(&1, [:kind]))

    for file <- files do
      assert file.action == "create"
      assert file.path in [LocalConfig.path(config_root: root), LocalConfig.target_registry_path(config_root: root)]
      assert is_binary(file.content) and file.content != ""
      assert file.digest == sha256(file.content)
      refute File.exists?(file.path)
    end

    assert {:ok, %{confirmation: ^token}} = HostBootstrap.preview(config_root: root)
    assert Map.has_key?(guidance, :tracker_connections)
    assert Map.has_key?(guidance, :runners)
    assert is_list(guidance.notes) and guidance.notes != []
  end

  test "confirmed setup creates only missing files with restrictive permissions and a loadable empty registry" do
    root = tmp_dir!("host-bootstrap-confirm")
    File.rmdir!(root)

    {:ok, %{confirmation: token}} = HostBootstrap.preview(config_root: root)
    assert {:ok, %{code: "setup_complete", created: created}} = HostBootstrap.confirm(token, config_root: root)

    config_path = LocalConfig.path(config_root: root)
    registry_path = LocalConfig.target_registry_path(config_root: root)
    assert Enum.sort(created) == Enum.sort([config_path, registry_path])

    assert {:ok, %File.Stat{mode: root_mode}} = File.lstat(root)
    assert Bitwise.band(root_mode, 0o777) == 0o700

    for path <- [config_path, registry_path] do
      assert {:ok, %File.Stat{mode: mode}} = File.lstat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    assert {:ok, %{snapshot: snapshot}} = HostScheduler.Registry.load(registry_path)
    assert snapshot.globally_valid?
    assert snapshot.targets == %{}
    assert snapshot.host["tracker_connections"] == %{}
    assert snapshot.host["runners"] == %{}
    assert snapshot.host["state_root"] == root <> "-state"
  end

  test "concurrent confirmations preserve the winning files and create one empty host" do
    root = tmp_dir!("host-bootstrap-concurrent")
    {:ok, %{confirmation: token}} = HostBootstrap.preview(config_root: root)

    results =
      1..8
      |> Task.async_stream(fn _ -> HostBootstrap.confirm(token, config_root: root) end, max_concurrency: 8)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %{code: "setup_complete"}}, &1)) == 1
    assert {:ok, %{code: "already_configured"}} = HostBootstrap.preview(config_root: root)

    assert {:ok, %{snapshot: %{globally_valid?: true, targets: targets}}} =
             HostScheduler.Registry.load(LocalConfig.target_registry_path(config_root: root))

    assert targets == %{}
  end

  test "replayed confirmation is rejected safely and repeated preview reports already configured" do
    root = tmp_dir!("host-bootstrap-replay")

    {:ok, %{confirmation: token}} = HostBootstrap.preview(config_root: root)
    assert {:ok, %{code: "setup_complete"}} = HostBootstrap.confirm(token, config_root: root)

    registry_bytes = File.read!(LocalConfig.target_registry_path(config_root: root))
    config_bytes = File.read!(LocalConfig.path(config_root: root))

    assert {:error, %{code: "confirmation_mismatch", next_action: next_action}} =
             HostBootstrap.confirm(token, config_root: root)

    assert is_binary(next_action) and next_action != ""
    assert File.read!(LocalConfig.target_registry_path(config_root: root)) == registry_bytes
    assert File.read!(LocalConfig.path(config_root: root)) == config_bytes

    assert {:ok, result} = HostBootstrap.preview(config_root: root)
    assert result.code == "already_configured"
    refute Map.has_key?(result, :confirmation)

    assert Enum.sort(Enum.map(result.existing, & &1.path)) ==
             Enum.sort([LocalConfig.path(config_root: root), LocalConfig.target_registry_path(config_root: root)])
  end

  test "existing config is respected and only the missing registry is created" do
    root = tmp_dir!("host-bootstrap-existing-config")
    config_path = LocalConfig.path(config_root: root)
    custom = "tracker:\n  api_key: $HOST_BOOTSTRAP_EXISTING_KEY\n"
    File.write!(config_path, custom)

    {:ok, %{confirmation: token, files: files}} = HostBootstrap.preview(config_root: root)
    assert [%{kind: :registry, path: registry_path}] = files
    assert registry_path == LocalConfig.target_registry_path(config_root: root)

    assert {:ok, %{code: "setup_complete", created: [^registry_path]}} =
             HostBootstrap.confirm(token, config_root: root)

    assert File.read!(config_path) == custom
    assert {:ok, config} = LocalConfig.load(config_root: root)
    assert config["tracker"]["api_key"] == "$HOST_BOOTSTRAP_EXISTING_KEY"
  end

  test "host file changes between preview and confirm are rejected without overwrites" do
    root = tmp_dir!("host-bootstrap-conflict")
    {:ok, %{confirmation: token}} = HostBootstrap.preview(config_root: root)

    racing = Yaml.encode(racing_registry(root))
    File.write!(LocalConfig.target_registry_path(config_root: root), racing)

    assert {:error, %{code: "confirmation_mismatch"}} = HostBootstrap.confirm(token, config_root: root)
    assert File.read!(LocalConfig.target_registry_path(config_root: root)) == racing
    refute File.exists?(LocalConfig.path(config_root: root))
  end

  test "symlinked host file locations fail closed" do
    root = tmp_dir!("host-bootstrap-symlink")
    clean = tmp_dir!("host-bootstrap-symlink-clean")
    registry_path = LocalConfig.target_registry_path(config_root: root)
    File.ln_s!(Path.join(root, "outside.yml"), registry_path)

    assert {:error, %{code: "unsafe_path", next_action: next_action}} =
             HostBootstrap.preview(config_root: root)

    assert is_binary(next_action) and next_action != ""

    {:ok, %{confirmation: token}} = HostBootstrap.preview(config_root: clean)

    assert {:error, %{code: "unsafe_path"}} = HostBootstrap.confirm(token, config_root: root)
    refute File.exists?(LocalConfig.path(config_root: clean))
  end

  test "an invalid existing config produces a stable safe error" do
    root = tmp_dir!("host-bootstrap-invalid-config")
    File.write!(LocalConfig.path(config_root: root), "config: [unclosed\n")

    assert {:error, %{code: "invalid_config", next_action: next_action}} =
             HostBootstrap.preview(config_root: root)

    assert is_binary(next_action) and next_action != ""
  end

  test "wrong-shaped nested config values return invalid_config with the config path and no environment remediation" do
    original_key = System.get_env("LINEAR_API_KEY")
    System.put_env("LINEAR_API_KEY", "host-bootstrap-secret-sentinel")
    on_exit(fn -> restore_env("LINEAR_API_KEY", original_key) end)

    shapes = [
      {"tracker-scalar", "tracker: 42\n", "tracker"},
      {"runners-scalar", "runners: 42\n", "runners"},
      {"polling-interval", "polling:\n  interval_ms: 0\n", "polling"}
    ]

    for {label, bytes, section} <- shapes do
      root = tmp_dir!("host-bootstrap-wrong-shape-#{label}")
      config_path = LocalConfig.path(config_root: root)
      File.write!(config_path, bytes)

      assert {:error, %{code: "invalid_config", next_action: next_action}} =
               HostBootstrap.preview(config_root: root)

      assert next_action =~ config_path
      assert next_action =~ section
      refute next_action =~ "HOME"
      refute next_action =~ "host-bootstrap-secret-sentinel"
      refute File.exists?(LocalConfig.target_registry_path(config_root: root))
    end
  end

  test "an empty list section is accepted as an empty section and guidance stays safe" do
    root = tmp_dir!("host-bootstrap-empty-section")
    File.write!(LocalConfig.path(config_root: root), "tracker: []\n")

    assert {:ok, %{code: "setup_required", guidance: guidance}} = HostBootstrap.preview(config_root: root)
    assert is_list(guidance.notes)
  end

  test "a valid existing config with runtime sections sets up the empty host without credentials" do
    root = tmp_dir!("host-bootstrap-valid-config")
    config_path = LocalConfig.path(config_root: root)
    original_key = System.get_env("LINEAR_API_KEY")
    original_unset_key = System.get_env("HOST_BOOTSTRAP_UNSET_KEY")

    System.delete_env("LINEAR_API_KEY")
    System.delete_env("HOST_BOOTSTRAP_UNSET_KEY")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", original_key)
      restore_env("HOST_BOOTSTRAP_UNSET_KEY", original_unset_key)
    end)

    bytes = """
    tracker:
      api_key: $HOST_BOOTSTRAP_UNSET_KEY
    polling:
      interval_ms: 5000
    agent:
      max_turns: 7
    runners:
      codex:
        command: [codex, app-server]
    """

    File.write!(config_path, bytes)

    assert {:ok, %{code: "setup_required", confirmation: token, files: [%{kind: :registry, path: registry_path}]}} =
             HostBootstrap.preview(config_root: root)

    assert registry_path == LocalConfig.target_registry_path(config_root: root)

    assert {:ok, %{code: "setup_complete", created: [^registry_path]}} =
             HostBootstrap.confirm(token, config_root: root)

    assert File.read!(config_path) == bytes
  end

  test "confirmation tokens must originate from the same previewed host state" do
    root_a = tmp_dir!("host-bootstrap-token-a")
    root_b = tmp_dir!("host-bootstrap-token-b")

    {:ok, %{confirmation: token}} = HostBootstrap.preview(config_root: root_a)

    assert {:error, %{code: "confirmation_mismatch"}} =
             HostBootstrap.confirm(token, config_root: root_b)

    for bad <- ["", "sb1-", "sb1-!!!not-base64!!!", "other-prefix-token", nil] do
      assert {:error, %{code: "invalid_confirmation"}} = HostBootstrap.confirm(bad, config_root: root_a)
    end

    assert {:error, %{code: "invalid_confirmation"}} = HostBootstrap.confirm("sb1-bogus")
    refute File.exists?(LocalConfig.path(config_root: root_a))
  end

  test "guidance reports connection IDs, runner availability, and missing credentials without leaking values" do
    root = tmp_dir!("host-bootstrap-guidance")
    registry_path = LocalConfig.target_registry_path(config_root: root)
    state_root = root <> "-state"
    File.write!(registry_path, registry_document(state_root))
    System.put_env("HOST_BOOTSTRAP_SET_KEY", "super-secret-sentinel-value")

    on_exit(fn ->
      System.delete_env("HOST_BOOTSTRAP_SET_KEY")
      System.delete_env("HOST_BOOTSTRAP_MISSING_KEY")
    end)

    assert {:ok, %{code: "setup_required", guidance: guidance}} =
             HostBootstrap.preview(config_root: root)

    assert [
             %{
               id: "linear-backup",
               kind: "linear",
               credential: "missing",
               credential_env: "HOST_BOOTSTRAP_MISSING_KEY"
             },
             %{
               id: "linear-main",
               kind: "linear",
               credential: "configured",
               credential_env: "HOST_BOOTSTRAP_SET_KEY"
             },
             %{
               id: "linear-vault",
               kind: "linear",
               credential: "external",
               credential_env: nil
             }
           ] = guidance.tracker_connections

    assert [%{name: "broken", executable: "definitely-missing-host-bootstrap-exe", available: false}] =
             guidance.runners

    assert Enum.any?(guidance.notes, &(&1 =~ "HOST_BOOTSTRAP_MISSING_KEY is not set"))
    assert Enum.any?(guidance.notes, &(&1 =~ "definitely-missing-host-bootstrap-exe"))

    refute inspect(guidance) =~ "super-secret-sentinel-value"
    refute Enum.any?(guidance.tracker_connections, &Map.has_key?(&1, :api_key))
  end

  test "missing credentials do not prevent the empty host setup" do
    root = tmp_dir!("host-bootstrap-no-credentials")
    System.delete_env("LINEAR_API_KEY")
    on_exit(fn -> System.delete_env("LINEAR_API_KEY") end)

    assert {:ok, %{code: "setup_required", confirmation: token, guidance: guidance}} =
             HostBootstrap.preview(config_root: root)

    assert is_binary(token)
    assert guidance.tracker_connections == []

    assert {:ok, %{code: "setup_complete"}} = HostBootstrap.confirm(token, config_root: root)

    assert {:ok, %{snapshot: %{targets: %{}}}} =
             HostScheduler.Registry.load(LocalConfig.target_registry_path(config_root: root))
  end

  defp racing_registry(root) do
    %{
      "version" => 1,
      "host" => %{
        "id" => "racing-host",
        "state_root" => root <> "-racing-state",
        "polling" => %{"interval_ms" => 500, "max_concurrent_target_polls" => 1},
        "capacity" => %{
          "max_concurrent_agents" => 1,
          "max_concurrent_startups" => 1,
          "max_concurrent_reviewers" => 1
        },
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 1},
        "tracker_connections" => %{},
        "runners" => %{}
      },
      "targets" => %{}
    }
  end

  defp registry_document(state_root) do
    %{
      "version" => 1,
      "host" => %{
        "id" => "guided-host",
        "state_root" => state_root,
        "polling" => %{"interval_ms" => 1_000, "max_concurrent_target_polls" => 2},
        "capacity" => %{
          "max_concurrent_agents" => 4,
          "max_concurrent_startups" => 2,
          "max_concurrent_reviewers" => 1
        },
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 3},
        "tracker_connections" => %{
          "linear-main" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "$HOST_BOOTSTRAP_SET_KEY"
          },
          "linear-backup" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "${HOST_BOOTSTRAP_MISSING_KEY}"
          },
          "linear-vault" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "secret://vault/team/key"
          }
        },
        "runners" => %{
          "broken" => %{
            "kind" => "codex_app_server",
            "command" => ["definitely-missing-host-bootstrap-exe", "app-server"],
            "max_concurrent_agents" => 1,
            "max_concurrent_startups" => 1
          }
        }
      },
      "targets" => %{}
    }
    |> Yaml.encode()
  end

  defp restore_env(name, original) do
    if original, do: System.put_env(name, original), else: System.delete_env(name)
  end

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
