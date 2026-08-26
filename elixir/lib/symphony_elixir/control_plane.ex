defmodule SymphonyElixir.ControlPlane do
  @moduledoc """
  Owns the local SQLite control-plane store and its schema lifecycle.

  Callers use domain operations and `transaction/2`; SQLite connections, SQL,
  migrations, and schema checks remain private to this process.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias SymphonyElixir.LocalConfig

  @database_file "control-plane.sqlite3"
  @schema_version 1
  @default_busy_timeout_ms 5_000
  @maximum_busy_timeout_ms 30_000
  @call_timeout_ms @maximum_busy_timeout_ms + 5_000

  defmodule Error do
    @moduledoc false

    @enforce_keys [:code, :message, :path]
    defexception [:code, :message, :path, :reason]

    @type t :: %__MODULE__{
            code: atom(),
            message: String.t(),
            path: Path.t(),
            reason: term()
          }
  end

  defmodule Transaction do
    @moduledoc false

    @enforce_keys [:owner, :ref]
    defstruct [:owner, :ref]

    @opaque t :: %__MODULE__{owner: pid(), ref: reference()}
  end

  @type health :: %{
          required(:path) => Path.t(),
          required(:schema_version) => pos_integer(),
          required(:status) => :healthy
        }
  @type transaction_result(value) :: {:ok, value} | {:error, term()}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec path(keyword()) :: Path.t()
  def path(opts \\ []) do
    config_root =
      Keyword.get(opts, :config_root) ||
        Application.get_env(:symphony_elixir, :control_plane_config_root) ||
        LocalConfig.root()

    config_root
    |> Path.expand()
    |> Path.join(@database_file)
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec health(GenServer.server()) :: {:ok, health()} | {:error, Error.t()}
  def health(server \\ __MODULE__) do
    GenServer.call(server, :health, @call_timeout_ms)
  end

  @doc """
  Runs domain operations in one immediate SQLite transaction.

  The callback receives an opaque transaction handle, not a connection. It must
  return `{:ok, value}` to commit or `{:error, reason}` to roll back.
  """
  @spec transaction(GenServer.server(), (Transaction.t() -> transaction_result(value))) ::
          transaction_result(value)
        when value: term()
  def transaction(server \\ __MODULE__, operation) when is_function(operation, 1) do
    GenServer.call(server, {:transaction, operation}, @call_timeout_ms)
  end

  @impl true
  def init(opts) do
    database_path = path(opts)

    with {:ok, busy_timeout_ms} <- busy_timeout(opts, database_path),
         :ok <- prepare_store_path(database_path),
         {:ok, connection} <- open(database_path),
         {:ok, state} <- initialize_connection(connection, database_path, busy_timeout_ms) do
      {:ok, state}
    else
      {:error, %Error{} = error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply, check_health(state.connection, state.path), state}
  end

  def handle_call({:transaction, operation}, _from, state) do
    {:reply, run_transaction(state.connection, state.path, operation), state}
  end

  @impl true
  def terminate(_reason, %{connection: connection, path: database_path}) do
    _ = Sqlite3.close(connection)
    _ = secure_database_files(database_path)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp busy_timeout(opts, database_path) do
    timeout_ms =
      Keyword.get(
        opts,
        :busy_timeout,
        Application.get_env(:symphony_elixir, :control_plane_busy_timeout, @default_busy_timeout_ms)
      )

    if is_integer(timeout_ms) and timeout_ms >= 0 and timeout_ms <= @maximum_busy_timeout_ms do
      {:ok, timeout_ms}
    else
      {:error,
       error(
         :invalid_busy_timeout,
         database_path,
         "control-plane busy timeout must be between 0 and #{@maximum_busy_timeout_ms} milliseconds",
         timeout_ms
       )}
    end
  end

  defp prepare_store_path(database_path) do
    root = Path.dirname(database_path)

    with :ok <- ensure_private_directory(root, database_path) do
      ensure_private_database_file(database_path)
    end
  end

  defp ensure_private_directory(root, database_path) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        chmod(root, 0o700, database_path, :unwritable_store, "cannot secure control-plane config root")

      {:ok, %File.Stat{type: type}} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "control-plane config root is not a directory",
           type
         )}

      {:error, :enoent} ->
        with :ok <- file_result(File.mkdir_p(root), database_path, :unwritable_store, "cannot create control-plane config root"),
             {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
             :ok <- chmod(root, 0o700, database_path, :unwritable_store, "cannot secure control-plane config root") do
          :ok
        else
          {:ok, %File.Stat{type: type}} ->
            {:error,
             error(
               :unwritable_store,
               database_path,
               "control-plane config root is not a directory",
               type
             )}

          {:error, %Error{} = store_error} ->
            {:error, store_error}

          {:error, reason} ->
            {:error,
             error(
               :unwritable_store,
               database_path,
               "cannot inspect control-plane config root after creation",
               reason
             )}
        end

      {:error, reason} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "cannot inspect control-plane config root",
           reason
         )}
    end
  end

  defp ensure_private_database_file(database_path) do
    case File.lstat(database_path) do
      {:ok, %File.Stat{type: :regular}} ->
        chmod(database_path, 0o600, database_path, :unwritable_store, "cannot secure control-plane database")

      {:ok, %File.Stat{type: type}} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "control-plane database path is not a regular file",
           type
         )}

      {:error, :enoent} ->
        create_private_database_file(database_path)

      {:error, reason} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "cannot inspect control-plane database path",
           reason
         )}
    end
  end

  defp create_private_database_file(database_path) do
    case File.open(database_path, [:write, :binary, :exclusive]) do
      {:ok, device} ->
        close_result = File.close(device)

        with :ok <-
               file_result(
                 close_result,
                 database_path,
                 :unwritable_store,
                 "cannot close new control-plane database"
               ) do
          chmod(
            database_path,
            0o600,
            database_path,
            :unwritable_store,
            "cannot secure new control-plane database"
          )
        end

      {:error, :eexist} ->
        ensure_private_database_file(database_path)

      {:error, reason} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "cannot create control-plane database",
           reason
         )}
    end
  end

  defp chmod(path, mode, database_path, code, message) do
    file_result(File.chmod(path, mode), database_path, code, message)
  end

  defp file_result(:ok, _database_path, _code, _message), do: :ok

  defp file_result({:error, reason}, database_path, code, message) do
    {:error, error(code, database_path, message, reason)}
  end

  defp open(database_path) do
    case Sqlite3.open(database_path, mode: :readwrite) do
      {:ok, connection} -> {:ok, connection}
      {:error, reason} -> {:error, error(:unwritable_store, database_path, "cannot open control-plane database for writing", reason)}
    end
  end

  defp initialize_connection(connection, database_path, busy_timeout_ms) do
    case configure_and_migrate(connection, database_path, busy_timeout_ms) do
      :ok ->
        {:ok, %{connection: connection, path: database_path, busy_timeout_ms: busy_timeout_ms}}

      {:error, %Error{} = store_error} ->
        _ = Sqlite3.close(connection)
        {:error, store_error}
    end
  end

  defp configure_and_migrate(connection, database_path, busy_timeout_ms) do
    with :ok <-
           sqlite_result(
             Sqlite3.set_busy_timeout(connection, busy_timeout_ms),
             database_path,
             :store_configuration_failed,
             "cannot configure bounded SQLite busy handling"
           ),
         :ok <- quick_check(connection, database_path),
         :ok <- execute(connection, "PRAGMA foreign_keys = ON", database_path, :store_configuration_failed),
         :ok <-
           verify_single_value(
             connection,
             "PRAGMA foreign_keys",
             1,
             database_path,
             :store_configuration_failed,
             "SQLite foreign-key enforcement is unavailable"
           ),
         :ok <- execute(connection, "PRAGMA synchronous = FULL", database_path, :store_configuration_failed),
         :ok <- execute(connection, "PRAGMA trusted_schema = OFF", database_path, :store_configuration_failed),
         :ok <- migrate(connection, database_path),
         :ok <- configure_wal(connection, database_path, busy_timeout_ms),
         {:ok, _health} <- check_health(connection, database_path) do
      secure_database_files(database_path)
    end
  end

  defp configure_wal(connection, database_path, busy_timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + busy_timeout_ms
    configure_wal_until(connection, database_path, deadline_ms)
  end

  defp configure_wal_until(connection, database_path, deadline_ms) do
    case query(connection, "PRAGMA journal_mode = WAL") do
      {:ok, [[mode]]} when mode in ["wal", "WAL"] ->
        :ok

      {:ok, rows} ->
        {:error, error(:store_configuration_failed, database_path, "SQLite WAL mode is unavailable", rows)}

      {:error, reason} when reason in [:busy, :busy_timeout] ->
        retry_wal_or_fail(connection, database_path, deadline_ms, reason)

      {:error, reason} ->
        {:error, error(:store_configuration_failed, database_path, "cannot enable SQLite WAL mode", reason)}
    end
  end

  defp retry_wal_or_fail(connection, database_path, deadline_ms, reason) do
    if System.monotonic_time(:millisecond) < deadline_ms do
      Process.sleep(10)
      configure_wal_until(connection, database_path, deadline_ms)
    else
      {:error, error(:store_configuration_failed, database_path, "cannot enable SQLite WAL mode before the busy timeout", reason)}
    end
  end

  defp migrate(connection, database_path) do
    with :ok <- execute(connection, "BEGIN IMMEDIATE", database_path, :migration_failed),
         {:ok, version} <- read_schema_version(connection, database_path),
         :ok <- validate_schema_version(version, database_path),
         :ok <- apply_migrations(connection, version, database_path),
         :ok <- execute(connection, "COMMIT", database_path, :migration_failed) do
      :ok
    else
      {:error, %Error{} = migration_error} ->
        _ = Sqlite3.execute(connection, "ROLLBACK")
        {:error, migration_error}
    end
  end

  defp validate_schema_version(version, _database_path) when version <= @schema_version, do: :ok

  defp validate_schema_version(version, database_path) do
    {:error,
     error(
       :unsupported_schema_version,
       database_path,
       "control-plane schema version #{version} is newer than supported version #{@schema_version}",
       version
     )}
  end

  defp apply_migrations(connection, 0, database_path) do
    migration = """
    CREATE TABLE schema_migrations (
      version INTEGER PRIMARY KEY CHECK (version > 0),
      applied_at TEXT NOT NULL
    );
    INSERT INTO schema_migrations (version, applied_at)
    VALUES (1, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
    PRAGMA user_version = 1;
    """

    execute(connection, migration, database_path, :migration_failed)
  end

  defp apply_migrations(_connection, @schema_version, _database_path), do: :ok

  defp read_schema_version(connection, database_path) do
    case query(connection, "PRAGMA user_version") do
      {:ok, [[version]]} when is_integer(version) and version >= 0 -> {:ok, version}
      {:ok, rows} -> {:error, error(:corrupt_store, database_path, "control-plane schema version is invalid", rows)}
      {:error, reason} -> {:error, error(:corrupt_store, database_path, "cannot read control-plane schema version", reason)}
    end
  end

  defp check_health(connection, database_path) do
    with :ok <- quick_check(connection, database_path),
         {:ok, version} <- read_schema_version(connection, database_path),
         :ok <- validate_current_schema(connection, version, database_path) do
      {:ok, %{path: database_path, schema_version: version, status: :healthy}}
    end
  end

  defp quick_check(connection, database_path) do
    case query(connection, "PRAGMA quick_check(1)") do
      {:ok, [["ok"]]} -> :ok
      {:ok, rows} -> {:error, error(:corrupt_store, database_path, "control-plane database failed SQLite quick check", rows)}
      {:error, reason} -> {:error, error(:corrupt_store, database_path, "cannot complete SQLite quick check", reason)}
    end
  end

  defp validate_current_schema(connection, @schema_version, database_path) do
    case query(connection, "SELECT max(version) FROM schema_migrations") do
      {:ok, [[@schema_version]]} -> :ok
      {:ok, rows} -> {:error, error(:corrupt_store, database_path, "control-plane migration history does not match its schema version", rows)}
      {:error, reason} -> {:error, error(:corrupt_store, database_path, "cannot read control-plane migration history", reason)}
    end
  end

  defp validate_current_schema(_connection, version, database_path) do
    {:error,
     error(
       :unsupported_schema_version,
       database_path,
       "control-plane schema version #{version} is not supported by this release",
       version
     )}
  end

  defp verify_single_value(connection, sql, expected, database_path, code, message) do
    case query(connection, sql) do
      {:ok, [[^expected]]} -> :ok
      {:ok, rows} -> {:error, error(code, database_path, message, rows)}
      {:error, reason} -> {:error, error(code, database_path, message, reason)}
    end
  end

  defp run_transaction(connection, database_path, operation) do
    with :ok <- execute(connection, "BEGIN IMMEDIATE", database_path, :transaction_failed) do
      transaction = %Transaction{owner: self(), ref: make_ref()}
      result = invoke_transaction(operation, transaction, database_path)
      finish_transaction(connection, database_path, result)
    end
  end

  defp invoke_transaction(operation, transaction, database_path) do
    operation.(transaction)
  rescue
    exception ->
      {:callback_error,
       error(
         :transaction_callback_failed,
         database_path,
         "control-plane transaction callback raised #{inspect(exception.__struct__)}",
         Exception.message(exception)
       )}
  catch
    kind, reason ->
      {:callback_error,
       error(
         :transaction_callback_failed,
         database_path,
         "control-plane transaction callback stopped with #{kind}",
         reason
       )}
  end

  defp finish_transaction(connection, database_path, {:ok, _value} = result) do
    case execute(connection, "COMMIT", database_path, :transaction_failed) do
      :ok ->
        result

      {:error, %Error{} = commit_error} ->
        _ = Sqlite3.execute(connection, "ROLLBACK")
        {:error, commit_error}
    end
  end

  defp finish_transaction(connection, _database_path, {:error, _reason} = result) do
    _ = Sqlite3.execute(connection, "ROLLBACK")
    result
  end

  defp finish_transaction(connection, _database_path, {:callback_error, %Error{} = callback_error}) do
    _ = Sqlite3.execute(connection, "ROLLBACK")
    {:error, callback_error}
  end

  defp finish_transaction(connection, database_path, result) do
    _ = Sqlite3.execute(connection, "ROLLBACK")

    {:error,
     error(
       :invalid_transaction_result,
       database_path,
       "control-plane transaction callback must return {:ok, value} or {:error, reason}",
       result
     )}
  end

  defp execute(connection, sql, database_path, code) do
    case Sqlite3.execute(connection, sql) do
      :ok -> :ok
      {:error, reason} -> {:error, error(code, database_path, sqlite_message(code), reason)}
    end
  end

  defp sqlite_result(:ok, _database_path, _code, _message), do: :ok

  defp sqlite_result({:error, reason}, database_path, code, message) do
    {:error, error(code, database_path, message, reason)}
  end

  defp query(connection, sql, params \\ []) do
    case Sqlite3.prepare(connection, sql) do
      {:ok, statement} ->
        try do
          with :ok <- Sqlite3.bind(statement, params) do
            collect_rows(connection, statement, [])
          end
        after
          _ = Sqlite3.release(connection, statement)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_rows(connection, statement, rows) do
    case Sqlite3.step(connection, statement) do
      {:row, row} -> collect_rows(connection, statement, [row | rows])
      :done -> {:ok, Enum.reverse(rows)}
      :busy -> {:error, :busy_timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  defp secure_database_files(database_path) do
    [database_path, database_path <> "-wal", database_path <> "-shm"]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case secure_database_file(path, database_path) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = store_error} -> {:halt, {:error, store_error}}
      end
    end)
  end

  defp secure_database_file(path, database_path) do
    basename = Path.basename(path)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        chmod(
          path,
          0o600,
          database_path,
          :unwritable_store,
          "cannot secure control-plane database file #{basename}"
        )

      {:ok, %File.Stat{type: type}} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "control-plane database file #{basename} is not regular",
           type
         )}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error,
         error(
           :unwritable_store,
           database_path,
           "cannot inspect control-plane database file #{basename}",
           reason
         )}
    end
  end

  defp sqlite_message(:migration_failed), do: "control-plane schema migration failed"
  defp sqlite_message(:transaction_failed), do: "control-plane transaction failed"
  defp sqlite_message(code), do: "control-plane SQLite operation failed during #{code}"

  defp error(code, database_path, message, reason) do
    %Error{
      code: code,
      path: database_path,
      message: "#{message} at #{database_path}: #{format_reason(reason)}",
      reason: reason
    }
  end

  defp format_reason(%{message: message}) when is_binary(message), do: message
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
