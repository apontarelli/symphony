defmodule SymphonyElixir.ControlPlaneTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Exqlite.Sqlite3
  alias SymphonyElixir.ControlPlane
  alias SymphonyElixir.ControlPlane.Error
  alias SymphonyElixir.ExecutionContext
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TargetContext

  test "first start atomically creates a healthy owner-only store" do
    config_root = tmp_root!("control-plane-first-start")
    File.rm_rf!(config_root)

    server = start_control_plane!(config_root)
    database_path = ControlPlane.path(config_root: config_root)

    assert {:ok,
            %{
              path: ^database_path,
              schema_version: 2,
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

    assert Enum.all?(pids, fn pid -> match?({:ok, %{schema_version: 2}}, ControlPlane.health(pid)) end)
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

  test "admission is atomic, idempotent, recoverable, and credential-safe" do
    config_root = tmp_root!("control-plane-admission")
    server = start_control_plane!(config_root)
    database_path = ControlPlane.path(config_root: config_root)

    context =
      execution_context!(config_root, "alpha", "shared-issue-id", "SID-427", runner_password: "env:RUNNER_PASSWORD")

    assert {:ok, first} = ControlPlane.admit_run(server, context)
    assert {:ok, repeated} = ControlPlane.admit_run(server, context)
    assert repeated.admitted_run_id == first.admitted_run_id
    assert repeated.context == context

    assert {:ok, fetched} =
             ControlPlane.fetch_admission(server, "alpha", "shared-issue-id")

    assert fetched.admitted_run_id == first.admitted_run_id
    assert fetched.context == context
    assert inspect(fetched) =~ first.admitted_run_id
    refute inspect(fetched) =~ "TRACKER_KEY"
    refute inspect(fetched) =~ "RUNNER_PASSWORD"

    assert {:blocked, :missing_credentials} =
             ControlPlane.resolve_admission_credentials(fetched,
               env_fetcher: fn _variable -> :error end
             )

    tracker_credential = "resolved-tracker-credential"
    runner_credential = "resolved-runner-credential"

    assert {:ok, resolved} =
             ControlPlane.resolve_admission_credentials(fetched,
               env_fetcher: fn
                 "TRACKER_KEY" -> {:ok, tracker_credential}
                 "RUNNER_PASSWORD" -> {:ok, runner_credential}
               end
             )

    assert get_in(resolved.target.tracker_connection, ["policy", "api_key"]) ==
             tracker_credential

    assert get_in(resolved.runner_config, ["server_auth", "password"]) ==
             runner_credential

    refute database_bytes(database_path) =~ tracker_credential
    refute database_bytes(database_path) =~ runner_credential
  end

  test "conflicting generations, hashes, and target envelopes cannot replace an admission" do
    config_root = tmp_root!("control-plane-admission-conflict")
    server = start_control_plane!(config_root)
    database_path = ControlPlane.path(config_root: config_root)

    original =
      execution_context!(config_root, "alpha", "issue-1", "SID-427",
        generation: hash("generation-1"),
        policy_hash: hash("policy-1")
      )

    original = %{original | policy: Map.put(original.policy, "priority", 1)}
    changed_numeric_policy = %{original | policy: Map.put(original.policy, "priority", 1.0)}

    changed_generation =
      execution_context!(config_root, "alpha", "issue-1", "SID-427",
        generation: hash("generation-2"),
        policy_hash: hash("policy-2")
      )

    changed_policy =
      execution_context!(config_root, "alpha", "issue-1", "SID-427",
        generation: hash("generation-1"),
        policy_hash: hash("policy-2")
      )

    changed_checks =
      execution_context!(config_root, "alpha", "issue-1", "SID-427",
        generation: hash("generation-1"),
        policy_hash: hash("policy-1"),
        check: "mix test changed"
      )

    assert {:ok, admission} = ControlPlane.admit_run(server, original)
    assert {:error, :admission_conflict} = ControlPlane.admit_run(server, changed_generation)
    assert {:error, :admission_conflict} = ControlPlane.admit_run(server, changed_policy)
    assert {:error, :admission_conflict} = ControlPlane.admit_run(server, changed_checks)

    assert {:error, :admission_conflict} =
             ControlPlane.admit_run(server, changed_numeric_policy)

    assert {:ok, retained} = ControlPlane.fetch_admission(server, "alpha", "issue-1")
    assert retained.admitted_run_id == admission.admitted_run_id
    assert retained.context == original
    assert scalar_query!(database_path, "SELECT count(*) FROM target_generations") == 1
  end

  test "target identity scopes overlapping tracker issue identities" do
    config_root = tmp_root!("control-plane-target-isolation")
    server = start_control_plane!(config_root)

    alpha = execution_context!(config_root, "alpha", "shared-id", "SID-427")
    beta = execution_context!(config_root, "beta", "shared-id", "SID-427")

    assert {:ok, alpha_admission} = ControlPlane.admit_run(server, alpha)
    assert {:ok, beta_admission} = ControlPlane.admit_run(server, beta)

    refute alpha_admission.admitted_run_id == beta_admission.admitted_run_id

    assert {:ok, fetched_alpha} =
             ControlPlane.fetch_admission(server, "alpha", "shared-id")

    assert {:ok, fetched_beta} =
             ControlPlane.fetch_admission(server, "beta", "shared-id")

    assert fetched_alpha.context.target.target_id == "alpha"
    assert fetched_beta.context.target.target_id == "beta"
    assert fetched_alpha.context.issue_identifier == fetched_beta.context.issue_identifier
  end

  test "resolved tracker and runner credentials are rejected before persistence" do
    config_root = tmp_root!("control-plane-secret-rejection")
    server = start_control_plane!(config_root)
    database_path = ControlPlane.path(config_root: config_root)
    tracker_secret = "resolved-tracker-secret"
    runner_secret = "resolved-runner-secret"

    tracker_context =
      execution_context!(config_root, "alpha", "issue-1", "SID-427", tracker_key: tracker_secret)

    runner_context =
      execution_context!(config_root, "alpha", "issue-2", "SID-428", runner_password: runner_secret)

    tracker_result = ControlPlane.admit_run(server, tracker_context)
    runner_result = ControlPlane.admit_run(server, runner_context)

    assert tracker_result == {:error, :invalid_admission}
    assert runner_result == {:error, :invalid_admission}
    refute inspect(tracker_result) =~ tracker_secret
    refute inspect(runner_result) =~ runner_secret
    refute database_bytes(database_path) =~ tracker_secret
    refute database_bytes(database_path) =~ runner_secret
    assert scalar_query!(database_path, "SELECT count(*) FROM target_generations") == 0
    assert scalar_query!(database_path, "SELECT count(*) FROM run_admissions") == 0
  end

  test "version one stores migrate to the admission schema" do
    config_root = tmp_root!("control-plane-version-one")
    database_path = ControlPlane.path(config_root: config_root)

    seed_database!(
      database_path,
      """
      CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY CHECK (version > 0),
        applied_at TEXT NOT NULL
      );
      INSERT INTO schema_migrations (version, applied_at) VALUES (1, 'fixture');
      PRAGMA user_version = 1;
      """
    )

    server = start_control_plane!(config_root)

    assert {:ok, %{schema_version: 2, status: :healthy}} = ControlPlane.health(server)
    assert scalar_query!(database_path, "SELECT count(*) FROM run_admissions") == 0
  end

  test "a newer schema version stops startup with an actionable error" do
    config_root = tmp_root!("control-plane-newer-schema")
    database_path = ControlPlane.path(config_root: config_root)
    seed_database!(database_path, "PRAGMA user_version = 3")

    assert {:error,
            %Error{
              code: :unsupported_schema_version,
              path: ^database_path,
              message: message
            }} = start_unlinked(config_root: config_root, name: unique_name())

    assert message =~ "schema version 3 is newer than supported version 2"
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

  defp execution_context!(config_root, target_id, issue_id, issue_identifier, opts \\ []) do
    workspace_root = Path.join(config_root, "worktrees")
    File.mkdir_p!(workspace_root)

    runner =
      %{
        "kind" => "codex_app_server",
        "command" => ["codex", "app-server"],
        "turn_timeout_ms" => 30_000,
        "execution_profiles" => %{
          "implementation" => %{
            "model" => "model-#{target_id}",
            "reasoning_effort" => "high",
            "budget" => "standard",
            "timeout_ms" => 30_000,
            "max_retries" => 1
          }
        }
      }
      |> maybe_put_runner_password(Keyword.get(opts, :runner_password))

    target =
      %TargetContext{
        target_id: target_id,
        state: :active,
        dispatch_mode: :explicit,
        registry_generation: Keyword.get(opts, :generation, hash("generation-#{target_id}")),
        policy_hash: Keyword.get(opts, :policy_hash, hash("policy-#{target_id}")),
        repo_manifest_hash: hash("manifest-#{target_id}"),
        repo_policy: %{
          "manifest" => %{"version" => 1},
          "manifest_source_dir" => config_root,
          "workflow_module_resolution" => %{}
        },
        tracker_connection: %{
          "id" => "linear",
          "policy" => %{
            "kind" => "linear",
            "endpoint" => "https://tracker.example.invalid/graphql",
            "api_key" => Keyword.get(opts, :tracker_key, "$TRACKER_KEY")
          }
        },
        run_target: %{},
        worktree_policy: %{
          "root" => workspace_root,
          "strategy" => "per_issue",
          "hooks" => %{
            "after_create" => nil,
            "after_run" => nil,
            "before_remove" => nil,
            "before_run" => nil,
            "timeout_ms" => 5_000
          }
        },
        runner_policy: %{
          "default" => "runner",
          "allowed" => ["runner"],
          "runners" => %{"runner" => runner}
        },
        effective_checks: %{
          "pre_handoff" => [Keyword.get(opts, :check, "mix test")]
        },
        external_side_effect_gates: %{
          "tracker_write" => "allow",
          "vcs_publish" => "deny"
        },
        capacity_limits: %{"max_concurrent_agents" => 1},
        budget_limits: %{}
      }

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      title: "Admission fixture",
      state: "In Progress"
    }

    assert {:ok, context} =
             ExecutionContext.new(target, issue,
               policy: %{
                 "delivery" => %{"pr_target" => "main"},
                 "target" => target_id
               }
             )

    context
  end

  defp maybe_put_runner_password(runner, nil), do: runner

  defp maybe_put_runner_password(runner, password) do
    Map.put(runner, "server_auth", %{"username" => "symphony", "password" => password})
  end

  defp hash(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end

  defp database_bytes(database_path) do
    [database_path, database_path <> "-wal", database_path <> "-shm"]
    |> Enum.filter(&File.regular?/1)
    |> Enum.map_join(&File.read!/1)
  end

  defp scalar_query!(database_path, sql) do
    {:ok, connection} = Sqlite3.open(database_path, mode: :readonly)
    {:ok, statement} = Sqlite3.prepare(connection, sql)
    {:row, [value]} = Sqlite3.step(connection, statement)
    :ok = Sqlite3.release(connection, statement)
    :ok = Sqlite3.close(connection)
    value
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
