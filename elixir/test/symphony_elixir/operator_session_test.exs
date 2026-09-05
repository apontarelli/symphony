defmodule SymphonyElixir.OperatorSessionTest do
  use ExUnit.Case, async: false

  import Bitwise, only: [&&&: 2]

  alias SymphonyElixir.OperatorSession

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "creates a private per-host credential and authenticates without returning the token" do
    root = temporary_root()
    {:ok, server} = OperatorSession.start_link(host_id: "host-alpha", config_root: root)

    assert {:ok, %{host_id: "host-alpha", token_path: token_path}} =
             OperatorSession.credentials(server)

    assert is_binary(token_path)
    assert {:ok, token} = File.read(token_path)
    assert byte_size(token) >= 32
    assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.stat(token_path)
    assert (mode &&& 0o077) == 0
    assert :ok == OperatorSession.authenticate(server, token)
    assert {:error, :unauthorized} == OperatorSession.authenticate(server, token <> "wrong")

    assert :ok == GenServer.stop(server)
    refute File.exists?(token_path)
    assert {:error, :unavailable} == OperatorSession.credentials(server)

    File.rm_rf!(root)
  end

  test "creates missing config directories privately and tolerates a removed credential at shutdown" do
    root = Path.join(temporary_root(), "new-config")
    {:ok, server} = OperatorSession.start_link(host_id: "host-new", config_root: root)
    {:ok, %{token_path: token_path}} = OperatorSession.credentials(server)
    token = File.read!(token_path)

    assert (File.stat!(root).mode &&& 0o077) == 0
    assert :ok = OperatorSession.authenticate(server, token)
    File.rm!(token_path)
    assert :ok = GenServer.stop(server)
    assert {:error, :unavailable} = OperatorSession.authenticate(server, token)
  end

  test "rotates credentials on a new host session" do
    root = temporary_root()
    {:ok, first} = OperatorSession.start_link(host_id: "host-alpha", config_root: root)
    {:ok, %{token_path: token_path}} = OperatorSession.credentials(first)
    first_token = File.read!(token_path)
    assert :ok == GenServer.stop(first)

    {:ok, second} = OperatorSession.start_link(host_id: "host-alpha", config_root: root)
    {:ok, %{token_path: ^token_path}} = OperatorSession.credentials(second)
    second_token = File.read!(token_path)

    assert first_token != second_token
    assert {:error, :unauthorized} == OperatorSession.authenticate(second, first_token)
    assert :ok == OperatorSession.authenticate(second, second_token)

    GenServer.stop(second)
    File.rm_rf!(root)
  end

  test "accepts an optional unique registration name and rejects invalid credentials" do
    root = temporary_root()
    name = :"operator_session_#{System.unique_integer([:positive])}"
    {:ok, server} = OperatorSession.start_link(name: name, host_id: "host-beta", config_root: root)

    assert Process.whereis(name) == server
    assert {:error, :unauthorized} == OperatorSession.authenticate(server, "")
    assert {:error, :unauthorized} == OperatorSession.authenticate(server, nil)

    GenServer.stop(server)
    File.rm_rf!(root)
  end

  test "normal termination does not remove a replacement credential it does not own" do
    root = temporary_root()
    {:ok, server} = OperatorSession.start_link(host_id: "host-gamma", config_root: root)
    {:ok, %{token_path: token_path}} = OperatorSession.credentials(server)

    replacement_path = token_path <> ".replacement"
    File.write!(replacement_path, "replacement")
    File.chmod!(replacement_path, 0o600)
    File.rename!(replacement_path, token_path)

    assert :ok == GenServer.stop(server)
    assert File.read!(token_path) == "replacement"

    File.rm_rf!(root)
  end

  test "fails closed for a symlinked config root" do
    root = temporary_root()
    outside = temporary_root()
    linked_root = Path.join(root, "linked")
    File.ln_s!(outside, linked_root)

    assert {:error, :insecure_credentials_path} =
             OperatorSession.start_link(host_id: "host-alpha", config_root: linked_root)

    refute File.exists?(Path.join(outside, ".credentials"))
    File.rm_rf!(root)
    File.rm_rf!(outside)
  end

  test "fails closed for insecure credential directories and credential symlinks" do
    root = temporary_root()
    credentials_root = Path.join(root, ".credentials")
    operator_root = Path.join(credentials_root, "operator")
    host_root = Path.join(operator_root, "host-alpha")
    File.mkdir_p!(host_root)
    File.chmod!(credentials_root, 0o755)

    assert {:error, :insecure_credentials_path} =
             OperatorSession.start_link(host_id: "host-alpha", config_root: root)

    File.chmod!(credentials_root, 0o700)
    File.chmod!(operator_root, 0o700)
    File.chmod!(host_root, 0o700)
    token_path = Path.join(host_root, "token")
    outside_token = Path.join(root, "outside-token")
    File.write!(outside_token, "must remain unchanged")
    File.ln_s!(outside_token, token_path)

    assert {:error, :insecure_credentials_file} =
             OperatorSession.start_link(host_id: "host-alpha", config_root: root)

    assert File.read!(outside_token) == "must remain unchanged"
    File.rm_rf!(root)
  end

  test "rejects malformed options and invalid or missing host settings" do
    assert {:error, :invalid_options} == OperatorSession.start_link(:invalid)
    assert {:error, :invalid_options} == OperatorSession.start_link([:invalid])
    assert {:error, :invalid_host_id} == OperatorSession.start_link()
    assert {:error, :invalid_host_id} == OperatorSession.start_link(host_id: nil)
    assert {:error, :invalid_host_id} == OperatorSession.start_link(host_id: "../host")

    assert {:error, :invalid_config_root} ==
             OperatorSession.start_link(host_id: "host-alpha", config_root: 123)
  end

  test "returns unavailable for authentication after termination and redacts diagnostics" do
    root = temporary_root()
    {:ok, server} = OperatorSession.start_link(host_id: "host-alpha", config_root: root)
    {:ok, %{token_path: token_path}} = OperatorSession.credentials(server)
    token = File.read!(token_path)
    digest = :crypto.hash(:sha256, token)

    status = inspect(:sys.get_status(server))
    assert status =~ "host-alpha"
    refute status =~ token
    refute status =~ inspect(digest)
    refute status =~ token_path

    assert :ok == GenServer.stop(server)
    assert {:error, :unavailable} == OperatorSession.authenticate(server, token)
  end

  test "overlapping sessions leave the replacement credential owned by the newer session" do
    root = temporary_root()
    {:ok, first} = OperatorSession.start_link(host_id: "host-alpha", config_root: root)
    {:ok, %{token_path: token_path}} = OperatorSession.credentials(first)
    first_token = File.read!(token_path)

    {:ok, second} = OperatorSession.start_link(host_id: "host-alpha", config_root: root)
    {:ok, %{token_path: ^token_path}} = OperatorSession.credentials(second)
    second_token = File.read!(token_path)

    assert first_token != second_token
    assert :ok == OperatorSession.authenticate(first, first_token)
    assert :ok == OperatorSession.authenticate(second, second_token)
    assert {:error, :unauthorized} == OperatorSession.authenticate(second, first_token)

    assert :ok == GenServer.stop(first)
    assert File.read!(token_path) == second_token
    assert :ok == GenServer.stop(second)
    refute File.exists?(token_path)
  end

  test "rejects symlinked nested credential directories without writing outside the root" do
    root = temporary_root()
    outside = temporary_root()
    credentials_root = Path.join(root, ".credentials")
    operator_root = Path.join(credentials_root, "operator")
    File.mkdir_p!(credentials_root)
    File.chmod!(root, 0o700)
    File.chmod!(credentials_root, 0o700)
    File.ln_s!(outside, operator_root)

    assert {:error, :insecure_credentials_path} =
             OperatorSession.start_link(host_id: "host-alpha", config_root: root)

    refute File.exists?(Path.join(outside, "host-alpha"))

    File.rm!(operator_root)
    File.mkdir_p!(operator_root)
    File.chmod!(operator_root, 0o700)
    File.ln_s!(outside, Path.join(operator_root, "host-alpha"))

    assert {:error, :insecure_credentials_path} =
             OperatorSession.start_link(host_id: "host-alpha", config_root: root)

    refute File.exists?(Path.join(outside, "token"))
  end

  test "rejects a non-directory credential component" do
    root = temporary_root()
    credentials_root = Path.join(root, ".credentials")
    File.write!(credentials_root, "not a directory")
    File.chmod!(root, 0o700)
    File.chmod!(credentials_root, 0o600)

    assert {:error, :insecure_credentials_path} =
             OperatorSession.start_link(host_id: "host-alpha", config_root: root)
  end

  test "fails closed when the operating system cannot identify the credential owner" do
    root = temporary_root()
    executable = Path.join(root, "id")
    config_root = Path.join(root, "uncreated")
    previous_path = System.fetch_env!("PATH")
    on_exit(fn -> System.put_env("PATH", previous_path) end)

    for script <- ["#!/bin/sh\nprintf 'unknown-user\\n'\n", "#!/bin/sh\nexit 1\n"] do
      File.write!(executable, script)
      File.chmod!(executable, 0o700)
      System.put_env("PATH", root)

      assert {:error, :credential_store_unavailable} =
               OperatorSession.start_link(host_id: "host-owner", config_root: config_root)

      refute File.exists?(config_root)
    end

    File.rm!(executable)

    assert {:error, :credential_store_unavailable} =
             OperatorSession.start_link(host_id: "host-owner", config_root: config_root)

    refute File.exists?(config_root)
  end

  test "abnormal termination leaves the credential for a later rotation" do
    root = temporary_root()
    {:ok, server} = OperatorSession.start_link(host_id: "host-alpha", config_root: root)
    {:ok, %{token_path: token_path}} = OperatorSession.credentials(server)

    assert :ok == GenServer.stop(server, :abnormal)
    assert_receive {:EXIT, ^server, :abnormal}
    assert File.exists?(token_path)
  end

  defp temporary_root do
    root = Path.join(System.tmp_dir!(), "symphony-operator-session-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
