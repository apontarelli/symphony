defmodule SymphonyElixir.LocalHostTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Bitwise, only: [&&&: 2]

  alias SymphonyElixir.{LocalHost, OperatorInterface}
  alias SymphonyElixir.LocalHost.Ownership

  @ownership_key {Ownership, :host_lock}

  setup do
    Process.flag(:trap_exit, true)

    on_exit(fn ->
      case Process.whereis(SymphonyElixir.HostOwnership) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      :persistent_term.erase(@ownership_key)
    end)

    :ok
  end

  describe "discover/1" do
    test "reports an absent host without writing when no config root or record exists" do
      root = missing_root()

      assert {:error, %{code: "host_not_running"} = error} = LocalHost.discover(config_root: root)
      assert is_binary(error.next_action)
      # Discovery must never create the per-user root on its own.
      refute File.exists?(root)
    end

    test "rejects a malformed or partial record as uncertain" do
      root = record_root()
      write_record(root, "not-json")

      assert {:error, %{code: "host_uncertain"}} = LocalHost.discover(config_root: root)

      write_record(root, Jason.encode!(%{"endpoint" => "http://127.0.0.1:4000"}))

      assert {:error, %{code: "host_uncertain"}} = LocalHost.discover(config_root: root)
    end

    test "rejects a non-loopback endpoint as insecure" do
      root = record_root()
      write_record(root, record(root, %{"endpoint" => "http://0.0.0.0:4000"}))

      assert {:error, %{code: "host_insecure"}} = LocalHost.discover(config_root: root)
    end

    test "rejects world-readable discovery records as insecure" do
      root = record_root()
      path = write_record(root, record(root))
      File.chmod!(path, 0o644)

      assert {:error, %{code: "host_insecure"}} = LocalHost.discover(config_root: root)
    end

    test "rejects a world-readable credential file as insecure" do
      root = record_root()
      write_record(root, record(root))
      write_token(root, "credential-value", 0o644)

      assert {:error, %{code: "host_insecure"}} = LocalHost.discover(config_root: root)
    end

    test "reports a stale host when the readiness endpoint is unreachable" do
      root = record_root()
      write_record(root, record(root))
      write_token(root, "credential-value", 0o600)

      request = fn _endpoint, _token -> {:error, :unreachable} end

      assert {:error, %{code: "host_stale"}} =
               LocalHost.discover(config_root: root, readiness_request: request)
    end

    test "reports a stale host when the recorded credential is rejected" do
      root = record_root()
      write_record(root, record(root))
      write_token(root, "credential-value", 0o600)

      request = fn _endpoint, _token -> {:ok, %{status: 401}} end

      assert {:error, %{code: "host_stale"}} =
               LocalHost.discover(config_root: root, readiness_request: request)
    end

    test "reports a stale host when the live host has a different identity" do
      root = record_root()
      write_record(root, record(root, %{"host_id" => "host-recorded"}))
      write_token(root, "credential-value", 0o600)

      request = readiness_request("host-live", 1, 1)

      assert {:error, %{code: "host_stale"}} =
               LocalHost.discover(config_root: root, readiness_request: request)
    end

    test "reports an incompatible host when record and live versions disagree" do
      root = record_root()
      write_record(root, record(root, %{"interface_version" => 2}))
      write_token(root, "credential-value", 0o600)

      request = readiness_request("host-alpha", 1, 1)

      assert {:error, %{code: "host_incompatible"}} =
               LocalHost.discover(config_root: root, readiness_request: request)
    end

    test "reports an incompatible host when the running build speaks older versions" do
      root = record_root()
      expected = OperatorInterface.interface_versions()

      write_record(root, record(root, %{"interface_version" => expected.interface_version + 1}))

      write_token(root, "credential-value", 0o600)

      request =
        readiness_request("host-alpha", expected.interface_version + 1, expected.schema_version)

      assert {:error, %{code: "host_incompatible"}} =
               LocalHost.discover(config_root: root, readiness_request: request)
    end

    test "returns verified atom-key discovery for a live authenticated host" do
      root = record_root()
      write_record(root, record(root))
      token_path = write_token(root, "credential-value", 0o600)
      expected = OperatorInterface.interface_versions()

      request = fn endpoint, token ->
        assert endpoint == "http://127.0.0.1:4000"
        assert token == "credential-value"

        {:ok,
         %{
           status: 200,
           body: %{
             "host_id" => "host-alpha",
             "interface_version" => expected.interface_version,
             "schema_version" => expected.schema_version
           }
         }}
      end

      assert {:ok, discovery} = LocalHost.discover(config_root: root, readiness_request: request)

      assert discovery.endpoint == "http://127.0.0.1:4000"
      assert discovery.host_id == "host-alpha"
      assert discovery.interface_version == expected.interface_version
      assert discovery.schema_version == expected.schema_version
      assert discovery.token_file == token_path
      # The credential itself never travels through discovery.
      refute Map.has_key?(discovery, :token)
    end
  end

  describe "attach/1" do
    test "a free lock does not authorize startup over insecure discovery metadata" do
      root = record_root()
      write_registry(root)
      path = write_record(root, record(root))
      File.chmod!(path, 0o644)

      assert {:error, %{code: "host_insecure"}} =
               LocalHost.attach(
                 config_root: root,
                 ownership_probe: fn -> :free end,
                 detached_launcher: fn _registry, _opts -> flunk("unsafe metadata must block startup") end
               )
    end

    test "does not start a host or create configuration when the registry is missing" do
      root = missing_root()

      assert {:error, %{code: "host_registry_missing"}} =
               LocalHost.attach(
                 config_root: root,
                 ownership_probe: fn -> :free end,
                 detached_launcher: fn _registry, _opts -> flunk("host must not launch") end
               )

      refute File.exists?(root)
    end

    test "returns the existing host discovery when ownership is already held" do
      root = record_root()
      write_record(root, record(root))
      write_token(root, "credential-value", 0o600)

      assert {:ok, %{host_id: "host-alpha"}} =
               LocalHost.attach(
                 config_root: root,
                 ownership_probe: fn -> :held end,
                 readiness_request: fn _endpoint, _token ->
                   {:ok,
                    %{
                      status: 200,
                      body: %{
                        "host_id" => "host-alpha",
                        "interface_version" => 1,
                        "schema_version" => 1
                      }
                    }}
                 end,
                 detached_launcher: fn _registry, _opts -> flunk("host must not launch") end
               )
    end

    test "fails safely when ownership is held but the host is not discoverable" do
      root = record_root()
      write_registry(root)

      assert {:error, %{code: "host_already_running"}} =
               LocalHost.attach(
                 config_root: root,
                 ownership_probe: fn -> :held end,
                 readiness_request: fn _endpoint, _token -> {:error, :unreachable} end,
                 detached_launcher: fn _registry, _opts -> flunk("host must not launch") end
               )
    end

    test "refuses to launch when ownership cannot be verified" do
      root = record_root()
      write_registry(root)

      assert {:error, %{code: "host_ownership_unknown"}} =
               LocalHost.attach(
                 config_root: root,
                 ownership_probe: fn -> {:error, :probe_broken} end,
                 detached_launcher: fn _registry, _opts -> flunk("host must not launch") end
               )
    end

    test "waits for authenticated readiness after launching a detached host" do
      root = record_root()
      registry = write_registry(root)

      launched = fn ^registry, _opts ->
        # The detached host publishes its discovery only after launch.
        write_record(root, record(root))
        write_token(root, "credential-value", 0o600)
        :ok
      end

      assert {:ok, %{host_id: "host-alpha", endpoint: "http://127.0.0.1:4000"}} =
               LocalHost.attach(
                 config_root: root,
                 ownership_probe: fn -> :free end,
                 detached_launcher: launched,
                 attach_poll_ms: 1,
                 attach_timeout_ms: 5_000,
                 readiness_request: fn _endpoint, _token ->
                   {:ok,
                    %{
                      status: 200,
                      body: %{
                        "host_id" => "host-alpha",
                        "interface_version" => 1,
                        "schema_version" => 1
                      }
                    }}
                 end
               )
    end

    test "reports a timeout when the detached host never becomes ready" do
      root = record_root()
      write_registry(root)

      assert {:error, %{code: "host_start_timeout"}} =
               LocalHost.attach(
                 config_root: root,
                 ownership_probe: fn -> :free end,
                 detached_launcher: fn _registry, _opts -> :ok end,
                 attach_poll_ms: 1,
                 attach_timeout_ms: 10,
                 readiness_request: fn _endpoint, _token -> {:error, :unreachable} end
               )
    end
  end

  describe "Ownership" do
    test "claims the per-user lock and excludes other BEAMs through the write-free probe" do
      root = missing_root()

      assert {:ok, pid} = Ownership.claim(config_root: root)
      assert true = Process.alive?(pid)
      assert File.regular?(Path.join(root, "host.lock"))

      # The standalone probe observes the BEAM-held flock from outside.
      assert :held = Ownership.probe(config_root: root)

      # A second claim inside the same BEAM reuses the existing owner.
      assert {:ok, ^pid} = Ownership.claim(config_root: root)

      assert :ok = GenServer.stop(pid, :normal)

      # Ownership is BEAM-held: it survives the ownership process and is
      # only released when this BEAM drops the resource or exits.
      assert :held = Ownership.probe(config_root: root)
      :persistent_term.erase(@ownership_key)
      assert :free = Ownership.probe(config_root: root)
    end

    test "lock path derives only from the per-user config root, so a different root stays free" do
      root_a = missing_root()
      root_b = missing_root()

      assert {:ok, _pid} = Ownership.claim(config_root: root_a)
      assert :held = Ownership.probe(config_root: root_a)
      assert :free = Ownership.probe(config_root: root_b)

      # A claim for a different lock cannot silently reuse this owner.
      assert {:error, {:host_lock_unavailable, :ownership_mismatch}} =
               Ownership.claim(config_root: root_b)
    end

    test "publishes the private discovery record once the host is ready and removes it on shutdown" do
      root = missing_root()
      token_file = Path.join(root, "token")

      readiness = fn ->
        {:ok,
         %{
           endpoint: "http://127.0.0.1:4000",
           host_id: "host-alpha",
           started_at: "2026-09-06T00:00:00Z",
           interface_version: 1,
           schema_version: 1,
           token_file: token_file
         }}
      end

      assert {:ok, pid} = Ownership.claim(config_root: root, readiness: readiness)

      record_path = Path.join([root, "host", "discovery.json"])
      wait_until(fn -> File.regular?(record_path) end)

      assert {:ok, %File.Stat{mode: mode}} = File.stat(record_path)
      assert (mode &&& 0o777) == 0o600

      assert {:ok, %{"endpoint" => "http://127.0.0.1:4000", "host_id" => "host-alpha"} = record} =
               Jason.decode(File.read!(record_path))

      # The record carries the credential path, never the credential.
      refute Map.has_key?(record, "token")
      assert record["token_file"] == token_file

      assert :ok = GenServer.stop(pid, :normal)
      refute File.exists?(record_path)
    end

    test "keeps a foreign record at shutdown" do
      root = missing_root()

      readiness = fn ->
        {:ok,
         %{
           endpoint: "http://127.0.0.1:4000",
           host_id: "host-alpha",
           started_at: "2026-09-06T00:00:00Z",
           interface_version: 1,
           schema_version: 1,
           token_file: Path.join(root, "token")
         }}
      end

      assert {:ok, pid} = Ownership.claim(config_root: root, readiness: readiness)
      record_path = Path.join([root, "host", "discovery.json"])
      wait_until(fn -> File.regular?(record_path) end)

      File.write!(record_path, Jason.encode!(record(root, %{"host_id" => "host-other"})))

      assert :ok = GenServer.stop(pid, :normal)
      assert File.exists?(record_path)
    end
  end

  describe "Ownership.loopback_endpoint/2" do
    test "derives reachable loopback endpoints from bound listener addresses" do
      assert {:ok, "http://127.0.0.1:4000"} = Ownership.loopback_endpoint({127, 0, 0, 1}, 4000)

      # Wildcard binds serve their same-family loopback address.
      assert {:ok, "http://127.0.0.1:4000"} = Ownership.loopback_endpoint({0, 0, 0, 0}, 4000)

      # An IPv4-mapped loopback listener is published as IPv4 loopback.
      {:ok, mapped_loopback} = :inet.parse_address(~c"::ffff:127.0.0.1")
      assert {:ok, "http://127.0.0.1:4000"} = Ownership.loopback_endpoint(mapped_loopback, 4000)

      # IPv6 loopback is published bracketed; the IPv6 wildcard serves it.
      assert {:ok, "http://[::1]:4000"} = Ownership.loopback_endpoint({0, 0, 0, 0, 0, 0, 0, 1}, 4000)
      assert {:ok, "http://[::1]:4000"} = Ownership.loopback_endpoint({0, 0, 0, 0, 0, 0, 0, 0}, 4000)

      # Any other bind has no endpoint that both reaches the listener
      # and satisfies the loopback-only discovery contract.
      assert {:error, :non_loopback_listener} = Ownership.loopback_endpoint({192, 168, 1, 5}, 4000)
      assert {:error, :non_loopback_listener} = Ownership.loopback_endpoint({0xFE80, 0, 0, 0, 0, 0, 0, 1}, 4000)
      assert {:error, :non_loopback_listener} = Ownership.loopback_endpoint({127, 0, 0, 2}, 4000)
    end
  end

  describe "Ownership discovery refresh" do
    test "follows changed worker metadata and keeps the last record while a worker restarts" do
      root = missing_root()
      record_path = Path.join([root, "host", "discovery.json"])

      bucket =
        start_supervised!({Agent, fn -> %{host_id: "host-alpha", port: 4000, token: Path.join(root, "token-a")} end})

      readiness = fn ->
        Agent.get(bucket, fn
          :pending -> :pending
          meta -> {:ok, readiness_info(meta)}
        end)
      end

      assert {:ok, pid} = Ownership.claim(config_root: root, readiness: readiness)
      wait_until(fn -> record_field(record_path, "host_id") == "host-alpha" end, 400)

      # An HTTP listener restart rebinds an ephemeral port; the record
      # must follow the new endpoint.
      Agent.update(bucket, &Map.merge(&1, %{port: 4711}))
      wait_until(fn -> record_field(record_path, "endpoint") == "http://127.0.0.1:4711" end, 400)
      assert record_field(record_path, "host_id") == "host-alpha"

      # An operator interface restart replaces the identity and the
      # credential path; the record must follow both.
      Agent.update(bucket, &Map.merge(&1, %{host_id: "host-beta", token: Path.join(root, "token-b")}))
      wait_until(fn -> record_field(record_path, "host_id") == "host-beta" end, 400)
      assert record_field(record_path, "token_file") == Path.join(root, "token-b")

      # While the restarted worker is not ready yet, the last record
      # stays in place and the BEAM lock stays held.
      Agent.update(bucket, fn _meta -> :pending end)
      Process.sleep(1_500)
      assert record_field(record_path, "host_id") == "host-beta"
      assert :held = Ownership.probe(config_root: root)

      Agent.update(bucket, fn _meta -> %{host_id: "host-gamma", port: 4000, token: Path.join(root, "token-c")} end)
      wait_until(fn -> record_field(record_path, "host_id") == "host-gamma" end, 400)

      assert :ok = GenServer.stop(pid, :normal)
      refute File.exists?(record_path)
    end

    test "never republishes after an unpublish request" do
      root = missing_root()
      record_path = Path.join([root, "host", "discovery.json"])

      readiness = fn -> {:ok, readiness_info(%{host_id: "host-alpha", port: 4000, token: Path.join(root, "token-a")})} end

      assert {:ok, pid} = Ownership.claim(config_root: root, readiness: readiness)
      wait_until(fn -> File.regular?(record_path) end)

      assert :ok = Ownership.unpublish(pid)
      refute File.exists?(record_path)

      # Sync ticks keep firing, but the record must not reappear.
      Process.sleep(1_500)
      refute File.exists?(record_path)

      assert :ok = GenServer.stop(pid, :normal)
      refute File.exists?(record_path)
    end
  end

  describe "Ownership live discovery" do
    test "rediscovers and reattaches after the supervised operator interface restarts" do
      root = missing_root()

      start_supervised!({SymphonyElixir.HttpServer, host: "127.0.0.1", port: 0})

      assert {:ok, pid} = Ownership.claim(config_root: root)
      assert {:ok, initial} = wait_for_discovery(root)

      # Restart the supervised operator interface exactly like the
      # one_for_one supervisor does after a crash: new host identity,
      # new credential path, and Ownership keeps running untouched.
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.OperatorInterface)
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.OperatorInterface)

      assert {:ok, recovered} = wait_for_discovery(root)
      assert recovered.host_id != initial.host_id
      assert recovered.token_file != initial.token_file

      # The lock never moved, so another BEAM stays excluded, and the
      # normal attach path succeeds against the refreshed metadata.
      assert :held = Ownership.probe(config_root: root)
      assert {:ok, attached} = LocalHost.attach(config_root: root)
      assert attached.host_id == recovered.host_id

      assert :ok = GenServer.stop(pid, :normal)
      refute File.exists?(Path.join([root, "host", "discovery.json"]))
    end

    test "rediscovers after the HTTP listener restarts on a new ephemeral port" do
      root = missing_root()

      start_supervised!({SymphonyElixir.HttpServer, host: "127.0.0.1", port: 0})
      assert {:ok, pid} = Ownership.claim(config_root: root)
      assert {:ok, initial} = wait_for_discovery(root)

      # Restart the listener: reserve the old port first so the kernel
      # cannot hand the same ephemeral port back, keeping the rebind
      # observable. Same host identity, fresh port.
      initial_port = URI.parse(initial.endpoint).port
      stop_supervised!(SymphonyElixir.HttpServer)
      {:ok, reserve} = :gen_tcp.listen(initial_port, ip: {127, 0, 0, 1}, reuseaddr: true)

      start_supervised!({SymphonyElixir.HttpServer, host: "127.0.0.1", port: 0})

      assert {:ok, recovered} = wait_for_discovery(root)
      assert recovered.endpoint != initial.endpoint
      assert recovered.host_id == initial.host_id
      :ok = :gen_tcp.close(reserve)

      assert {:ok, _} = LocalHost.attach(config_root: root)
      assert :ok = GenServer.stop(pid, :normal)
      refute File.exists?(Path.join([root, "host", "discovery.json"]))
    end

    test "publishes a reachable bracketed IPv6 endpoint for an IPv6 loopback listener" do
      root = missing_root()

      start_supervised!({SymphonyElixir.HttpServer, host: "::1", port: 0})
      assert {:ok, {{0, 0, 0, 0, 0, 0, 0, 1}, port}} = wait_for_bound_address()

      expected_endpoint = "http://[::1]:#{port}"
      assert {:ok, ^expected_endpoint} = Ownership.loopback_endpoint({0, 0, 0, 0, 0, 0, 0, 1}, port)

      assert {:ok, pid} = Ownership.claim(config_root: root)

      # Discovery contacts the published endpoint over IPv6 loopback and
      # the authenticated readiness check succeeds end to end.
      assert {:ok, discovery} = wait_for_discovery(root)
      assert discovery.endpoint == expected_endpoint

      assert {:ok, _} = LocalHost.attach(config_root: root)
      assert :ok = GenServer.stop(pid, :normal)
      refute File.exists?(Path.join([root, "host", "discovery.json"]))
    end
  end

  defp missing_root do
    root = Path.join(System.tmp_dir!(), "symphony-local-host-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false))
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp record_root do
    root = missing_root()
    host_dir = Path.join(root, "host")
    File.mkdir_p!(host_dir)
    File.chmod!(root, 0o700)
    File.chmod!(host_dir, 0o700)
    root
  end

  defp record(root, overrides \\ []) do
    base = %{
      "endpoint" => "http://127.0.0.1:4000",
      "host_id" => "host-alpha",
      "started_at" => "2026-09-06T00:00:00Z",
      "interface_version" => 1,
      "schema_version" => 1,
      "token_file" => Path.join(root, "token")
    }

    Map.merge(base, Map.new(overrides))
  end

  defp write_record(root, content) when is_binary(content) do
    path = Path.join([root, "host", "discovery.json"])
    File.write!(path, content)
    File.chmod!(path, 0o600)
    path
  end

  defp write_record(root, content) when is_map(content) do
    write_record(root, Jason.encode!(content))
  end

  defp write_token(root, value, mode) do
    path = Path.join(root, "token")
    File.write!(path, value)
    File.chmod!(path, mode)
    path
  end

  defp write_registry(root) do
    registry = Path.join(root, "targets.yml")
    File.write!(registry, "version: 1\nhost:\n  id: local\n  state_root: #{root}/state\n")
    registry
  end

  defp readiness_request(host_id, interface_version, schema_version) do
    fn _endpoint, _token ->
      {:ok,
       %{
         status: 200,
         body: %{
           "host_id" => host_id,
           "interface_version" => interface_version,
           "schema_version" => schema_version
         }
       }}
    end
  end

  defp wait_until(condition, attempts \\ 100) do
    if condition.() do
      :ok
    else
      if attempts <= 0 do
        flunk("condition was never met")
      else
        :timer.sleep(10)
        wait_until(condition, attempts - 1)
      end
    end
  end

  defp readiness_info(meta) do
    %{
      endpoint: "http://127.0.0.1:#{Map.get(meta, :port, 4000)}",
      host_id: meta.host_id,
      started_at: "2026-09-06T00:00:00Z",
      interface_version: 1,
      schema_version: 1,
      token_file: meta.token
    }
  end

  defp record_field(record_path, field) do
    case File.read(record_path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, record} when is_map(record) -> record[field]
          _other -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp wait_for_discovery(root, attempts \\ 600) do
    case LocalHost.discover(config_root: root) do
      {:ok, discovery} ->
        {:ok, discovery}

      {:error, _retryable} when attempts > 0 ->
        Process.sleep(25)
        wait_for_discovery(root, attempts - 1)

      {:error, error} ->
        flunk("discovery never succeeded: #{inspect(error)}")
    end
  end

  defp wait_for_bound_address(attempts \\ 200) do
    case SymphonyElixir.HttpServer.bound_address() do
      {:ok, _bound} = bound ->
        bound

      nil when attempts > 0 ->
        Process.sleep(25)
        wait_for_bound_address(attempts - 1)

      nil ->
        flunk("HTTP listener never bound")
    end
  end
end
