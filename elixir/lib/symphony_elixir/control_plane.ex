defmodule SymphonyElixir.ControlPlane do
  @moduledoc """
  Owns the local SQLite control-plane store and its schema lifecycle.

  Callers use domain operations and `transaction/2`; SQLite connections, SQL,
  migrations, and schema checks remain private to this process.
  """

  use GenServer
  alias Exqlite.Sqlite3
  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.LocalConfig
  alias SymphonyElixir.TargetContext

  @database_file "control-plane.sqlite3"
  @schema_version 2
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

  defmodule Admission do
    @moduledoc false

    @enforce_keys [
      :admitted_run_id,
      :target_id,
      :tracker_issue_id,
      :issue_identifier,
      :registry_generation,
      :policy_hash,
      :repo_manifest_hash,
      :context,
      :admitted_at
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            admitted_run_id: String.t(),
            target_id: String.t(),
            tracker_issue_id: String.t(),
            issue_identifier: String.t(),
            registry_generation: String.t(),
            policy_hash: String.t(),
            repo_manifest_hash: String.t(),
            context: ExecutionContext.t(),
            admitted_at: String.t()
          }
  end

  @type health :: %{
          required(:path) => Path.t(),
          required(:schema_version) => pos_integer(),
          required(:status) => :healthy
        }
  @type transaction_result(value) :: {:ok, value} | {:error, term()}
  @type admission_error ::
          :admission_conflict
          | :admission_not_found
          | :invalid_admission
          | Error.t()

  @type credential_resolution ::
          {:ok, ExecutionContext.t()}
          | {:blocked, :missing_credentials | :credential_resolution_failed}
          | {:error, :invalid_admission}

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

  @doc """
  Atomically admits one immutable target-and-issue run.

  The execution context must retain validated credential references. A
  repeated admission with the same pinned envelope returns the original
  admitted run ID. Any changed generation, hash, or envelope conflicts.
  """
  @spec admit_run(GenServer.server(), ExecutionContext.t()) ::
          {:ok, Admission.t()} | {:error, admission_error()}
  def admit_run(server \\ __MODULE__, context) do
    GenServer.call(server, {:admit_run, context}, @call_timeout_ms)
  end

  @spec fetch_admission(GenServer.server(), String.t(), String.t()) ::
          {:ok, Admission.t()} | {:error, admission_error()}
  def fetch_admission(server \\ __MODULE__, target_id, tracker_issue_id) do
    GenServer.call(
      server,
      {:fetch_admission, target_id, tracker_issue_id},
      @call_timeout_ms
    )
  end

  @doc """
  Resolves current tracker and runner credentials for a pinned admission.

  Lease and fencing code must call this only after it owns the run.
  """
  @spec resolve_admission_credentials(Admission.t()) :: credential_resolution()
  def resolve_admission_credentials(admission),
    do: resolve_admission_credentials(admission, [])

  @spec resolve_admission_credentials(Admission.t(), keyword()) :: credential_resolution()
  def resolve_admission_credentials(%Admission{context: %ExecutionContext{} = context}, opts)
      when is_list(opts) do
    with {:ok, fetcher} <- credential_fetcher(opts),
         {:ok, _references} <- credential_references(context),
         {:ok, resolved} <- resolve_context_credentials(context, fetcher),
         :ok <- ExecutionContext.validate(resolved) do
      {:ok, resolved}
    else
      {:blocked, reason} -> {:blocked, reason}
      _invalid -> {:error, :invalid_admission}
    end
  end

  def resolve_admission_credentials(_admission, _opts), do: {:error, :invalid_admission}

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

  def handle_call({:admit_run, context}, _from, state) do
    result =
      with {:ok, record} <- prepare_admission(context) do
        persist_admission(state.connection, state.path, record)
      end

    {:reply, result, state}
  end

  def handle_call({:fetch_admission, target_id, tracker_issue_id}, _from, state) do
    {:reply, load_admission(state.connection, state.path, target_id, tracker_issue_id), state}
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

    with :ok <- execute(connection, migration, database_path, :migration_failed) do
      apply_migrations(connection, 1, database_path)
    end
  end

  defp apply_migrations(connection, 1, database_path) do
    migration = """
    CREATE TABLE target_generations (
      target_id TEXT NOT NULL,
      registry_generation TEXT NOT NULL,
      policy_hash TEXT NOT NULL,
      repo_manifest_hash TEXT NOT NULL,
      target_context_json TEXT NOT NULL,
      secret_references_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      PRIMARY KEY (target_id, registry_generation)
    );

    CREATE TABLE run_admissions (
      admitted_run_id TEXT PRIMARY KEY,
      target_id TEXT NOT NULL,
      tracker_issue_id TEXT NOT NULL,
      issue_identifier TEXT NOT NULL,
      registry_generation TEXT NOT NULL,
      policy_hash TEXT NOT NULL,
      repo_manifest_hash TEXT NOT NULL,
      role TEXT NOT NULL,
      execution_profile_json TEXT NOT NULL,
      workspace_authority_json TEXT NOT NULL,
      runner_policy_json TEXT NOT NULL,
      checks_json TEXT NOT NULL,
      delivery_gates_json TEXT NOT NULL,
      context_json TEXT NOT NULL,
      provenance_json TEXT NOT NULL,
      secret_references_json TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state = 'admitted'),
      admitted_at TEXT NOT NULL,
      UNIQUE (target_id, tracker_issue_id),
      FOREIGN KEY (target_id, registry_generation)
        REFERENCES target_generations (target_id, registry_generation)
    );

    INSERT INTO schema_migrations (version, applied_at)
    VALUES (2, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
    PRAGMA user_version = 2;
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
    with {:ok, [[@schema_version]]} <-
           query(connection, "SELECT max(version) FROM schema_migrations"),
         :ok <- validate_admission_schema(connection, database_path) do
      :ok
    else
      {:ok, rows} ->
        {:error,
         error(
           :corrupt_store,
           database_path,
           "control-plane migration history does not match its schema version",
           rows
         )}

      {:error, %Error{} = store_error} ->
        {:error, store_error}

      {:error, reason} ->
        {:error,
         error(
           :corrupt_store,
           database_path,
           "cannot read control-plane migration history",
           reason
         )}
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

  defp validate_admission_schema(connection, database_path) do
    sql = """
    SELECT
      target.target_id,
      target.registry_generation,
      target.policy_hash,
      target.repo_manifest_hash,
      target.target_context_json,
      target.secret_references_json,
      admission.admitted_run_id,
      admission.tracker_issue_id,
      admission.context_json,
      admission.provenance_json,
      admission.state
    FROM target_generations AS target
    LEFT JOIN run_admissions AS admission
      ON admission.target_id = target.target_id
     AND admission.registry_generation = target.registry_generation
    LIMIT 0
    """

    case query(connection, sql) do
      {:ok, []} -> :ok
      {:ok, rows} -> corrupt_store(database_path, {:unexpected_schema_rows, length(rows)})
      {:error, reason} -> corrupt_store(database_path, {:invalid_admission_schema, reason})
    end
  end

  defp prepare_admission(%ExecutionContext{} = context) do
    with :ok <- ExecutionContext.validate(context),
         {:ok, references} <- credential_references(context),
         {:ok, provenance} <- ExecutionContext.safe_provenance(context),
         {:ok, target_context_json} <- encode_json(target_to_map(context.target)),
         {:ok, context_json} <- encode_json(execution_to_map(context)),
         {:ok, secret_references_json} <- encode_json(references),
         {:ok, provenance_json} <- encode_json(stringify_keys(provenance)),
         {:ok, execution_profile_json} <-
           encode_json(stringify_keys(context.execution_profile)),
         {:ok, workspace_authority_json} <-
           encode_json(%{
             "workspace_path" => context.workspace_path,
             "worker_host" => context.worker_host,
             "worktree_policy" => context.target.worktree_policy
           }),
         {:ok, runner_policy_json} <- encode_json(context.target.runner_policy),
         {:ok, checks_json} <- encode_json(context.target.effective_checks),
         {:ok, delivery_gates_json} <-
           encode_json(context.target.external_side_effect_gates) do
      {:ok,
       %{
         admitted_run_id: admitted_run_id(),
         target_id: context.target.target_id,
         tracker_issue_id: context.issue_id,
         issue_identifier: context.issue_identifier,
         registry_generation: context.target.registry_generation,
         policy_hash: context.target.policy_hash,
         repo_manifest_hash: context.target.repo_manifest_hash,
         role: Atom.to_string(context.role),
         execution_profile_json: execution_profile_json,
         workspace_authority_json: workspace_authority_json,
         runner_policy_json: runner_policy_json,
         checks_json: checks_json,
         delivery_gates_json: delivery_gates_json,
         target_context_json: target_context_json,
         context_json: context_json,
         provenance_json: provenance_json,
         secret_references_json: secret_references_json,
         admitted_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    else
      _invalid -> {:error, :invalid_admission}
    end
  end

  defp prepare_admission(_context), do: {:error, :invalid_admission}

  defp persist_admission(connection, database_path, record) do
    with :ok <- execute(connection, "BEGIN IMMEDIATE", database_path, :transaction_failed) do
      result =
        with :ok <- ensure_target_generation(connection, database_path, record),
             {:ok, existing} <-
               select_admission(connection, database_path, record.target_id, record.tracker_issue_id) do
          persist_or_reuse_admission(connection, database_path, record, existing)
        end

      finish_transaction(connection, database_path, result)
    end
  end

  defp ensure_target_generation(connection, database_path, record) do
    sql = """
    SELECT policy_hash, repo_manifest_hash, target_context_json, secret_references_json
    FROM target_generations
    WHERE target_id = ?1 AND registry_generation = ?2
    """

    case domain_query(
           connection,
           sql,
           [record.target_id, record.registry_generation],
           database_path,
           "cannot read pinned target generation"
         ) do
      {:ok, []} ->
        insert_target_generation(connection, database_path, record)

      {:ok,
       [
         [
           policy_hash,
           repo_manifest_hash,
           target_context_json,
           secret_references_json
         ]
       ]} ->
        if policy_hash == record.policy_hash and
             repo_manifest_hash == record.repo_manifest_hash and
             same_json?(target_context_json, record.target_context_json) and
             same_json?(secret_references_json, record.secret_references_json) do
          :ok
        else
          {:error, :admission_conflict}
        end

      {:ok, _invalid_rows} ->
        corrupt_store(database_path, :invalid_target_generation)

      {:error, _reason} = error ->
        error
    end
  end

  defp insert_target_generation(connection, database_path, record) do
    sql = """
    INSERT INTO target_generations (
      target_id,
      registry_generation,
      policy_hash,
      repo_manifest_hash,
      target_context_json,
      secret_references_json,
      created_at
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    """

    expect_no_rows(
      connection,
      sql,
      [
        record.target_id,
        record.registry_generation,
        record.policy_hash,
        record.repo_manifest_hash,
        record.target_context_json,
        record.secret_references_json,
        record.admitted_at
      ],
      database_path,
      "cannot persist pinned target generation"
    )
  end

  defp persist_or_reuse_admission(connection, database_path, record, nil) do
    with :ok <- insert_admission(connection, database_path, record),
         {:ok, row} <-
           select_admission(
             connection,
             database_path,
             record.target_id,
             record.tracker_issue_id
           ) do
      decode_admission_row(row, database_path)
    end
  end

  defp persist_or_reuse_admission(_connection, database_path, record, row) do
    if same_admission_row?(row, record),
      do: decode_admission_row(row, database_path),
      else: {:error, :admission_conflict}
  end

  defp insert_admission(connection, database_path, record) do
    sql = """
    INSERT INTO run_admissions (
      admitted_run_id,
      target_id,
      tracker_issue_id,
      issue_identifier,
      registry_generation,
      policy_hash,
      repo_manifest_hash,
      role,
      execution_profile_json,
      workspace_authority_json,
      runner_policy_json,
      checks_json,
      delivery_gates_json,
      context_json,
      provenance_json,
      secret_references_json,
      state,
      admitted_at
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9,
      ?10, ?11, ?12, ?13, ?14, ?15, ?16, 'admitted', ?17
    )
    """

    expect_no_rows(
      connection,
      sql,
      [
        record.admitted_run_id,
        record.target_id,
        record.tracker_issue_id,
        record.issue_identifier,
        record.registry_generation,
        record.policy_hash,
        record.repo_manifest_hash,
        record.role,
        record.execution_profile_json,
        record.workspace_authority_json,
        record.runner_policy_json,
        record.checks_json,
        record.delivery_gates_json,
        record.context_json,
        record.provenance_json,
        record.secret_references_json,
        record.admitted_at
      ],
      database_path,
      "cannot persist run admission"
    )
  end

  defp load_admission(connection, database_path, target_id, tracker_issue_id)
       when is_binary(target_id) and is_binary(tracker_issue_id) do
    with {:ok, row} <-
           select_admission(connection, database_path, target_id, tracker_issue_id) do
      case row do
        nil -> {:error, :admission_not_found}
        stored -> decode_admission_row(stored, database_path)
      end
    end
  end

  defp load_admission(_connection, _database_path, _target_id, _tracker_issue_id),
    do: {:error, :invalid_admission}

  defp select_admission(connection, database_path, target_id, tracker_issue_id) do
    sql = """
    SELECT
      admission.admitted_run_id,
      admission.issue_identifier,
      admission.registry_generation,
      admission.policy_hash,
      admission.repo_manifest_hash,
      admission.role,
      admission.execution_profile_json,
      admission.workspace_authority_json,
      admission.runner_policy_json,
      admission.checks_json,
      admission.delivery_gates_json,
      admission.context_json,
      admission.provenance_json,
      admission.secret_references_json,
      admission.admitted_at,
      target.target_context_json,
      target.secret_references_json
    FROM run_admissions AS admission
    JOIN target_generations AS target
      ON target.target_id = admission.target_id
     AND target.registry_generation = admission.registry_generation
    WHERE admission.target_id = ?1 AND admission.tracker_issue_id = ?2
    """

    case domain_query(
           connection,
           sql,
           [target_id, tracker_issue_id],
           database_path,
           "cannot read run admission"
         ) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row]} -> {:ok, row}
      {:ok, _invalid_rows} -> corrupt_store(database_path, :duplicate_run_admission)
      {:error, _reason} = error -> error
    end
  end

  defp same_admission_row?(
         [
           _admitted_run_id,
           issue_identifier,
           registry_generation,
           policy_hash,
           repo_manifest_hash,
           role,
           execution_profile_json,
           workspace_authority_json,
           runner_policy_json,
           checks_json,
           delivery_gates_json,
           context_json,
           provenance_json,
           secret_references_json,
           _admitted_at,
           target_context_json,
           target_secret_references_json
         ],
         record
       ) do
    issue_identifier == record.issue_identifier and
      registry_generation == record.registry_generation and
      policy_hash == record.policy_hash and
      repo_manifest_hash == record.repo_manifest_hash and
      role == record.role and
      Enum.all?(
        [
          {execution_profile_json, record.execution_profile_json},
          {workspace_authority_json, record.workspace_authority_json},
          {runner_policy_json, record.runner_policy_json},
          {checks_json, record.checks_json},
          {delivery_gates_json, record.delivery_gates_json},
          {context_json, record.context_json},
          {provenance_json, record.provenance_json},
          {secret_references_json, record.secret_references_json},
          {target_context_json, record.target_context_json},
          {target_secret_references_json, record.secret_references_json}
        ],
        fn {stored, incoming} -> same_json?(stored, incoming) end
      )
  end

  defp same_admission_row?(_row, _record), do: false

  defp decode_admission_row(
         [
           admitted_run_id,
           _issue_identifier,
           _registry_generation,
           _policy_hash,
           _repo_manifest_hash,
           _role,
           _execution_profile_json,
           _workspace_authority_json,
           _runner_policy_json,
           _checks_json,
           _delivery_gates_json,
           context_json,
           _provenance_json,
           _secret_references_json,
           admitted_at,
           target_context_json,
           _target_secret_references_json
         ] = row,
         database_path
       ) do
    with {:ok, target_map} <- decode_json(target_context_json),
         {:ok, execution_map} <- decode_json(context_json),
         {:ok, target} <- target_from_map(target_map),
         {:ok, context} <- execution_from_map(execution_map, target),
         {:ok, record} <- prepare_admission(context),
         true <- same_admission_row?(row, record) do
      {:ok,
       %Admission{
         admitted_run_id: admitted_run_id,
         target_id: target.target_id,
         tracker_issue_id: context.issue_id,
         issue_identifier: context.issue_identifier,
         registry_generation: target.registry_generation,
         policy_hash: target.policy_hash,
         repo_manifest_hash: target.repo_manifest_hash,
         context: context,
         admitted_at: admitted_at
       }}
    else
      _invalid -> corrupt_store(database_path, :invalid_run_admission)
    end
  end

  defp decode_admission_row(_row, database_path),
    do: corrupt_store(database_path, :invalid_run_admission)

  defp target_to_map(%TargetContext{} = target) do
    %{
      "target_id" => target.target_id,
      "state" => Atom.to_string(target.state),
      "dispatch_mode" => optional_atom_string(target.dispatch_mode),
      "registry_generation" => target.registry_generation,
      "policy_hash" => target.policy_hash,
      "repo_manifest_hash" => target.repo_manifest_hash,
      "issue_policy_authority" => target.issue_policy_authority,
      "repo_policy" => target.repo_policy,
      "tracker_connection" => target.tracker_connection,
      "run_target" => target.run_target,
      "worktree_policy" => target.worktree_policy,
      "runner_policy" => target.runner_policy,
      "effective_checks" => target.effective_checks,
      "external_side_effect_gates" => target.external_side_effect_gates,
      "capacity_limits" => target.capacity_limits,
      "budget_limits" => target.budget_limits
    }
  end

  defp execution_to_map(%ExecutionContext{} = context) do
    %{
      "issue_id" => context.issue_id,
      "issue_identifier" => context.issue_identifier,
      "workspace_path" => context.workspace_path,
      "runner_name" => context.runner_name,
      "runner_config" => context.runner_config,
      "policy" => context.policy,
      "role" => Atom.to_string(context.role),
      "execution_profile" => stringify_keys(context.execution_profile),
      "timeout_ms" => context.timeout_ms,
      "max_retries" => context.max_retries,
      "worker_host" => context.worker_host
    }
  end

  defp target_from_map(map) when is_map(map) do
    keys = ~w(
      budget_limits
      capacity_limits
      dispatch_mode
      effective_checks
      external_side_effect_gates
      issue_policy_authority
      policy_hash
      registry_generation
      repo_manifest_hash
      repo_policy
      run_target
      runner_policy
      state
      target_id
      tracker_connection
      worktree_policy
    )

    with true <- Enum.sort(Map.keys(map)) == Enum.sort(keys),
         {:ok, state} <- target_state(map["state"]),
         {:ok, dispatch_mode} <- dispatch_mode(map["dispatch_mode"]) do
      {:ok,
       struct!(TargetContext,
         target_id: map["target_id"],
         state: state,
         dispatch_mode: dispatch_mode,
         registry_generation: map["registry_generation"],
         policy_hash: map["policy_hash"],
         repo_manifest_hash: map["repo_manifest_hash"],
         issue_policy_authority: map["issue_policy_authority"],
         repo_policy: map["repo_policy"],
         tracker_connection: map["tracker_connection"],
         run_target: map["run_target"],
         worktree_policy: map["worktree_policy"],
         runner_policy: map["runner_policy"],
         effective_checks: map["effective_checks"],
         external_side_effect_gates: map["external_side_effect_gates"],
         capacity_limits: map["capacity_limits"],
         budget_limits: map["budget_limits"]
       )}
    else
      _invalid -> {:error, :invalid_target_context}
    end
  end

  defp target_from_map(_map), do: {:error, :invalid_target_context}

  defp execution_from_map(map, %TargetContext{} = target) when is_map(map) do
    keys = ~w(
      execution_profile
      issue_id
      issue_identifier
      max_retries
      policy
      role
      runner_config
      runner_name
      timeout_ms
      worker_host
      workspace_path
    )

    with true <- Enum.sort(Map.keys(map)) == Enum.sort(keys),
         {:ok, role} <- execution_role(map["role"]),
         {:ok, profile} <- execution_profile(map["execution_profile"]) do
      context =
        struct!(ExecutionContext,
          target: target,
          issue_id: map["issue_id"],
          issue_identifier: map["issue_identifier"],
          workspace_path: map["workspace_path"],
          runner_name: map["runner_name"],
          runner_config: map["runner_config"],
          policy: map["policy"],
          role: role,
          execution_profile: profile,
          timeout_ms: map["timeout_ms"],
          max_retries: map["max_retries"],
          worker_host: map["worker_host"]
        )

      case ExecutionContext.validate(context) do
        :ok -> {:ok, context}
        {:error, _reason} -> {:error, :invalid_execution_context}
      end
    else
      _invalid -> {:error, :invalid_execution_context}
    end
  end

  defp execution_from_map(_map, _target), do: {:error, :invalid_execution_context}

  defp execution_profile(map) when is_map(map) do
    keys = ~w(budget command max_retries model name reasoning_effort timeout_ms)

    if Enum.sort(Map.keys(map)) == keys do
      {:ok,
       %{
         name: map["name"],
         reasoning_effort: map["reasoning_effort"],
         budget: map["budget"],
         timeout_ms: map["timeout_ms"],
         max_retries: map["max_retries"],
         command: map["command"],
         model: map["model"]
       }}
    else
      {:error, :invalid_execution_profile}
    end
  end

  defp execution_profile(_map), do: {:error, :invalid_execution_profile}

  defp credential_references(%ExecutionContext{target: %TargetContext{} = target}) do
    with {:ok, tracker_reference} <-
           tracker_secret_reference(target.tracker_connection),
         {:ok, runner_references} <- runner_secret_references(target.runner_policy) do
      {:ok,
       %{
         "tracker_api_key" => tracker_reference,
         "runner_server_auth_passwords" => runner_references
       }}
    end
  end

  defp credential_references(_context), do: {:error, :invalid_admission}

  defp tracker_secret_reference(%{
         "policy" => %{"api_key" => reference}
       })
       when is_binary(reference) do
    with false <- String.starts_with?(reference, "env:"),
         {:ok, _variable} <- reference_variable(reference) do
      {:ok, reference}
    else
      _invalid -> {:error, :invalid_tracker_secret_reference}
    end
  end

  defp tracker_secret_reference(_connection),
    do: {:error, :invalid_tracker_secret_reference}

  defp runner_secret_references(%{"runners" => runners}) when is_map(runners) do
    Enum.reduce_while(runners, {:ok, %{}}, fn {runner_name, runner}, {:ok, references} ->
      case runner_secret_reference(runner) do
        {:ok, nil} ->
          {:cont, {:ok, references}}

        {:ok, reference} ->
          {:cont, {:ok, Map.put(references, runner_name, reference)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp runner_secret_references(_policy),
    do: {:error, :invalid_runner_secret_reference}

  defp runner_secret_reference(%{"server_auth" => %{"password" => reference}})
       when is_binary(reference) do
    with true <- String.starts_with?(reference, "env:"),
         {:ok, _variable} <- reference_variable(reference) do
      {:ok, reference}
    else
      _invalid -> {:error, :invalid_runner_secret_reference}
    end
  end

  defp runner_secret_reference(%{"server_auth" => nil}), do: {:ok, nil}
  defp runner_secret_reference(%{"server_auth" => _invalid}), do: {:error, :invalid_runner_secret_reference}
  defp runner_secret_reference(runner) when is_map(runner), do: {:ok, nil}
  defp runner_secret_reference(_runner), do: {:error, :invalid_runner_secret_reference}

  defp credential_fetcher(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(opts, fn {key, _value} -> key == :env_fetcher end) and
         length(Keyword.get_values(opts, :env_fetcher)) <= 1 do
      case Keyword.get(opts, :env_fetcher, &System.fetch_env/1) do
        fetcher when is_function(fetcher, 1) -> {:ok, fetcher}
        _invalid -> {:error, :invalid_admission}
      end
    else
      {:error, :invalid_admission}
    end
  end

  defp resolve_context_credentials(context, fetcher) do
    with {:ok, references} <- credential_references(context),
         {:ok, values} <- resolve_reference_values(references, fetcher) do
      target = context.target

      tracker_reference = references["tracker_api_key"]

      tracker_connection =
        put_in(
          target.tracker_connection,
          ["policy", "api_key"],
          Map.fetch!(values, tracker_reference)
        )

      runners =
        resolve_runner_credentials(
          target.runner_policy["runners"],
          references["runner_server_auth_passwords"],
          values
        )

      runner_policy = put_in(target.runner_policy, ["runners"], runners)
      target = %{target | tracker_connection: tracker_connection, runner_policy: runner_policy}

      {:ok,
       %{
         context
         | target: target,
           runner_config: Map.fetch!(runners, context.runner_name)
       }}
    end
  end

  defp resolve_runner_credentials(runners, references, values) do
    Map.new(runners, fn {runner_name, runner} ->
      case Map.get(references, runner_name) do
        nil ->
          {runner_name, runner}

        reference ->
          {runner_name,
           put_in(
             runner,
             ["server_auth", "password"],
             Map.fetch!(values, reference)
           )}
      end
    end)
  end

  defp resolve_reference_values(references, fetcher) do
    references
    |> credential_reference_values()
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn reference, {:ok, values} ->
      with {:ok, variable} <- reference_variable(reference),
           {:ok, value} <- fetch_current_credential(fetcher, variable) do
        {:cont, {:ok, Map.put(values, reference, value)}}
      else
        {:blocked, _reason} = blocked -> {:halt, blocked}
        _invalid -> {:halt, {:blocked, :credential_resolution_failed}}
      end
    end)
  end

  defp credential_reference_values(%{
         "tracker_api_key" => tracker_reference,
         "runner_server_auth_passwords" => runner_references
       }) do
    [tracker_reference | Map.values(runner_references)]
  end

  defp fetch_current_credential(fetcher, variable) do
    case invoke_credential_fetcher(fetcher, variable) do
      {:ok, {:ok, value}} when is_binary(value) ->
        if value != "" and String.valid?(value),
          do: {:ok, value},
          else: {:blocked, :missing_credentials}

      {:ok, :error} ->
        {:blocked, :missing_credentials}

      _invalid ->
        {:blocked, :credential_resolution_failed}
    end
  end

  defp invoke_credential_fetcher(fetcher, variable) do
    {:ok, fetcher.(variable)}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp reference_variable("env:" <> variable) do
    if Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, variable),
      do: {:ok, variable},
      else: {:error, :invalid_secret_reference}
  end

  defp reference_variable(reference) do
    case Regex.run(~r/\A\$([A-Za-z0-9._-]+)\z/, reference, capture: :all_but_first) do
      [variable] ->
        {:ok, variable}

      _no_match ->
        case Regex.run(
               ~r/\A\$\{([A-Za-z0-9._-]+)\}\z/,
               reference,
               capture: :all_but_first
             ) do
          [variable] -> {:ok, variable}
          _invalid -> {:error, :invalid_secret_reference}
        end
    end
  end

  defp target_state("paused"), do: {:ok, :paused}
  defp target_state("active"), do: {:ok, :active}
  defp target_state("draining"), do: {:ok, :draining}
  defp target_state("retired"), do: {:ok, :retired}
  defp target_state(_state), do: {:error, :invalid_target_state}

  defp dispatch_mode("explicit"), do: {:ok, :explicit}
  defp dispatch_mode("watch"), do: {:ok, :watch}
  defp dispatch_mode(nil), do: {:ok, nil}
  defp dispatch_mode(_mode), do: {:error, :invalid_dispatch_mode}

  defp execution_role("implementation"), do: {:ok, :implementation}
  defp execution_role("source_reviewer"), do: {:ok, :source_reviewer}
  defp execution_role("test_reviewer"), do: {:ok, :test_reviewer}
  defp execution_role("runtime_qa"), do: {:ok, :runtime_qa}
  defp execution_role("product_visual_review"), do: {:ok, :product_visual_review}
  defp execution_role("docs_reviewer"), do: {:ok, :docs_reviewer}
  defp execution_role("security_reviewer"), do: {:ok, :security_reviewer}
  defp execution_role(_role), do: {:error, :invalid_role}

  defp optional_atom_string(nil), do: nil
  defp optional_atom_string(value), do: Atom.to_string(value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
    end)
  end

  defp admitted_run_id do
    "run_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp decode_json(_value), do: {:error, :invalid_json}

  defp same_json?(left, right) do
    with {:ok, decoded_left} <- decode_json(left),
         {:ok, decoded_right} <- decode_json(right) do
      decoded_left === decoded_right
    else
      _invalid -> false
    end
  end

  defp expect_no_rows(connection, sql, params, database_path, message) do
    case domain_query(connection, sql, params, database_path, message) do
      {:ok, []} -> :ok
      {:ok, _rows} -> corrupt_store(database_path, :unexpected_sql_rows)
      {:error, _reason} = error -> error
    end
  end

  defp domain_query(connection, sql, params, database_path, message) do
    case query(connection, sql, params) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, error(:transaction_failed, database_path, message, reason)}
    end
  end

  defp corrupt_store(database_path, reason) do
    {:error,
     error(
       :corrupt_store,
       database_path,
       "control-plane durable admission state is invalid",
       reason
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

defimpl Inspect, for: SymphonyElixir.ControlPlane.Admission do
  import Inspect.Algebra

  @impl true
  def inspect(admission, opts) do
    safe =
      Map.take(admission, [
        :admitted_run_id,
        :target_id,
        :tracker_issue_id,
        :issue_identifier,
        :registry_generation,
        :policy_hash,
        :repo_manifest_hash,
        :admitted_at
      ])

    concat(["#SymphonyElixir.ControlPlane.Admission<", to_doc(safe, opts), ">"])
  end
end
