defmodule SymphonyElixir.ControlPlaneTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Exqlite.Sqlite3
  alias SymphonyElixir.ControlPlane
  alias SymphonyElixir.ControlPlane.Error

  test "first start atomically creates a healthy owner-only store" do
    config_root = tmp_root!("control-plane-first-start")
    File.rm_rf!(config_root)

    server = start_control_plane!(config_root)
    database_path = ControlPlane.path(config_root: config_root)

    assert {:ok,
            %{
              path: ^database_path,
              schema_version: 1,
              status: :healthy
            }} = ControlPlane.health(server)

    assert permissions(config_root) == 0o700
    assert permissions(database_path) == 0o600

    for suffix <- ["-wal", "-shm"], File.exists?(database_path <> suffix) do
      assert permissions(database_path <> suffix) == 0o600
    end
  end

  test "concurrent first starts share one migrated schema" do
    config_root = tmp_root!("control-plane-concurrent-start")
    File.rm_rf!(config_root)
    parent = self()

    launch = fn index ->
      name = {:global, {__MODULE__, make_ref(), index}}

      result = ControlPlane.start_link(config_root: config_root, name: name, busy_timeout: 2_000)

      case result do
        {:ok, pid} ->
          Process.unlink(pid)
          send(parent, {:started, pid})
          {:ok, pid}

        error ->
          error
      end
    end

    tasks = Enum.map(1..2, &Task.async(fn -> launch.(&1) end))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    pids =
      Enum.map(results, fn
        {:ok, pid} -> pid
        error -> flunk("concurrent control-plane start failed: #{inspect(error)}")
      end)

    on_exit(fn -> Enum.each(pids, &stop_process/1) end)

    assert Enum.all?(pids, fn pid -> match?({:ok, %{schema_version: 1}}, ControlPlane.health(pid)) end)
  end

  test "busy handling is bounded across local processes" do
    config_root = tmp_root!("control-plane-busy")
    first = start_control_plane!(config_root, busy_timeout: 100)
    second = start_control_plane!(config_root, busy_timeout: 100)
    parent = self()

    holder =
      Task.async(fn ->
        ControlPlane.transaction(first, fn _transaction ->
          send(parent, {:write_lock_held, self()})

          receive do
            :release_write_lock -> {:ok, :released}
          after
            2_000 -> {:error, :release_timeout}
          end
        end)
      end)

    assert_receive {:write_lock_held, lock_owner}, 1_000
    started_at = System.monotonic_time(:millisecond)

    assert {:error, %Error{code: :transaction_failed, message: message}} =
             ControlPlane.transaction(second, fn _transaction -> {:ok, :unreachable} end)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert message =~ "control-plane transaction failed"
    assert elapsed_ms < 1_000

    send(lock_owner, :release_write_lock)
    assert {:ok, :released} = Task.await(holder, 1_000)
  end

  test "transaction callbacks commit domain results and roll back domain errors" do
    server = start_control_plane!(tmp_root!("control-plane-transactions"))

    assert {:ok, :committed} =
             ControlPlane.transaction(server, fn %ControlPlane.Transaction{} ->
               {:ok, :committed}
             end)

    assert {:error, :rejected} =
             ControlPlane.transaction(server, fn %ControlPlane.Transaction{} ->
               {:error, :rejected}
             end)

    assert {:error, %Error{code: :invalid_transaction_result}} =
             ControlPlane.transaction(server, fn %ControlPlane.Transaction{} -> :invalid end)

    assert {:ok, %{status: :healthy}} = ControlPlane.health(server)
  end

  test "a newer schema version stops startup with an actionable error" do
    config_root = tmp_root!("control-plane-newer-schema")
    database_path = ControlPlane.path(config_root: config_root)
    seed_database!(database_path, "PRAGMA user_version = 2")

    assert {:error,
            %Error{
              code: :unsupported_schema_version,
              path: ^database_path,
              message: message
            }} = start_unlinked(config_root: config_root, name: unique_name())

    assert message =~ "schema version 2 is newer than supported version 1"
  end

  test "migration failure rolls back schema state and stops startup" do
    config_root = tmp_root!("control-plane-migration-failure")
    database_path = ControlPlane.path(config_root: config_root)
    seed_database!(database_path, "CREATE TABLE schema_migrations (wrong_column INTEGER)")

    assert {:error, %Error{code: :migration_failed, message: message}} =
             start_unlinked(config_root: config_root, name: unique_name())

    assert message =~ "control-plane schema migration failed"
    assert read_user_version!(database_path) == 0
  end

  test "corruption stops startup with an actionable error" do
    config_root = tmp_root!("control-plane-corrupt")
    database_path = ControlPlane.path(config_root: config_root)
    File.mkdir_p!(config_root)
    File.write!(database_path, "not a sqlite database")

    assert {:error,
            %Error{
              code: :corrupt_store,
              path: ^database_path,
              message: message
            }} = start_unlinked(config_root: config_root, name: unique_name())

    assert message =~ "SQLite quick check"
  end

  test "an unusable config root stops startup with an actionable error" do
    parent = tmp_root!("control-plane-unwritable")
    config_root = Path.join(parent, "config-root-file")
    File.write!(config_root, "not a directory")
    database_path = ControlPlane.path(config_root: config_root)

    assert {:error,
            %Error{
              code: :unwritable_store,
              path: ^database_path,
              message: message
            }} = start_unlinked(config_root: config_root, name: unique_name())

    assert message =~ "config root is not a directory"
  end

  defp start_unlinked(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start(ControlPlane, opts, name: name)
  end

  defp start_control_plane!(config_root, opts \\ []) do
    child_opts =
      opts
      |> Keyword.put(:config_root, config_root)
      |> Keyword.put(:name, unique_name())

    start_supervised!({ControlPlane, child_opts}, restart: :temporary)
  end

  defp seed_database!(database_path, sql) do
    File.mkdir_p!(Path.dirname(database_path))
    {:ok, connection} = Sqlite3.open(database_path)
    :ok = Sqlite3.execute(connection, sql)
    :ok = Sqlite3.close(connection)
    File.chmod!(database_path, 0o600)
  end

  defp read_user_version!(database_path) do
    {:ok, connection} = Sqlite3.open(database_path, mode: :readonly)
    {:ok, statement} = Sqlite3.prepare(connection, "PRAGMA user_version")
    {:row, [version]} = Sqlite3.step(connection, statement)
    :ok = Sqlite3.release(connection, statement)
    :ok = Sqlite3.close(connection)
    version
  end

  defp permissions(path) do
    path
    |> File.stat!()
    |> Map.fetch!(:mode)
    |> band(0o777)
  end

  defp stop_process(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end

  defp unique_name, do: {:global, {__MODULE__, make_ref()}}

  defp tmp_root!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
