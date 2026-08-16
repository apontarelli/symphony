defmodule SymphonyElixir.TargetRegistry.FileStore do
  @moduledoc false

  alias SymphonyElixir.TargetRegistry.Error
  require Record

  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  defmodule LockOwnership do
    @moduledoc false

    @enforce_keys [:path, :stat, :token_path, :token_stat, :token]
    defstruct [:path, :stat, :token_path, :token_stat, :token]
  end

  defmodule TempOwnership do
    @moduledoc false

    @enforce_keys [:path, :stat]
    defstruct [:path, :stat]
    @type t :: %__MODULE__{path: Path.t(), stat: File.Stat.t()}
  end

  @generation_regex ~r/^sha256:[0-9a-f]{64}$/
  @operation_arities %{
    before_lock_release: 0,
    chmod: 2,
    close: 1,
    fstat: 1,
    lock_token_chmod: 2,
    lock_token_close: 1,
    lock_token_create: 2,
    lock_token_fstat: 1,
    lock_token_open: 2,
    lock_token_remove: 1,
    lock_token_sync: 1,
    lock_token_write: 2,
    lstat: 1,
    mkdir: 1,
    open: 2,
    read: 1,
    remove: 1,
    rename: 2,
    rmdir: 1,
    sync: 1,
    sync_parent: 1,
    temp_path: 1,
    write: 2
  }

  @type read_result :: %{bytes: binary(), generation: String.t()}
  @type file_operation :: (... -> term())
  @type file_operations :: %{optional(atom()) => file_operation()}

  @spec read(Path.t(), keyword()) :: {:ok, read_result()} | {:error, Error.t()}
  def read(path, opts \\ []) do
    with :ok <- validate_path(path),
         {:ok, operations} <- operations(opts, :read) do
      read_with(path, operations)
    else
      {:error, :invalid_path} -> error(:registry_unreadable, "target registry path is invalid", nil)
      {:error, :invalid_options} -> error(:registry_unreadable, "file operation injection is invalid", path_or_nil(path))
    end
  end

  @spec replace(Path.t(), binary(), String.t(), keyword()) ::
          {:ok, read_result()} | {:error, Error.t()}
  def replace(path, bytes, expected_generation, opts \\ []) do
    with :ok <- validate_path(path),
         true <- is_binary(bytes),
         true <- valid_generation?(expected_generation),
         {:ok, operations} <- operations(opts, :replace) do
      acquire_and_replace(path, bytes, expected_generation, operations)
    else
      _invalid ->
        error(
          :atomic_replace_failed,
          "atomic replacement arguments or file operation injection are invalid",
          path_or_nil(path)
        )
    end
  end

  @spec with_lock(Path.t(), (-> term()), keyword()) ::
          {:ok, term()}
          | {:error, :locked | :lock_failed | :invalid_lock_arguments}
          | {:error, :lock_cleanup_failed, term()}
  def with_lock(path, operation, opts \\ []) do
    with :ok <- validate_path(path),
         true <- is_function(operation, 0),
         {:ok, operations, final_verify} <- lock_options(opts) do
      run_with_lock(path <> ".lock", operation, final_verify, operations)
    else
      _invalid -> {:error, :invalid_lock_arguments}
    end
  end

  @spec create_temp(Path.t(), binary(), keyword()) ::
          {:ok, TempOwnership.t()} | {:error, atom()}
  def create_temp(path, bytes, opts \\ []) do
    with :ok <- validate_path(path),
         true <- is_binary(bytes),
         {:ok, operations} <- operations(opts, :temp) do
      create_temp_with(path, bytes, operations)
    else
      _invalid -> {:error, :invalid_temp_arguments}
    end
  end

  @spec remove_temp(term(), keyword()) :: :ok | {:error, atom()}
  def remove_temp(ownership, opts \\ []) do
    case ownership do
      %TempOwnership{} -> remove_temp_with(ownership, opts)
      _invalid -> {:error, :invalid_temp_arguments}
    end
  end

  defp remove_temp_with(ownership, opts) do
    case operations(opts, :temp_cleanup) do
      {:ok, operations} -> remove_owned_temp(ownership, operations)
      {:error, :invalid_options} -> {:error, :invalid_temp_arguments}
    end
  end

  defp acquire_and_replace(path, bytes, expected_generation, operations) do
    operation = fn -> replace_while_locked(path, bytes, expected_generation, operations) end

    final_verify = fn
      {:ok, _result} ->
        case read_with(path, operations) do
          {:ok, %{bytes: ^bytes}} -> :ok
          _failure -> {:error, :final_verify_failed}
        end

      _body_error ->
        :ok
    end

    case run_with_lock(path <> ".lock", operation, final_verify, operations) do
      {:ok, result} ->
        result

      {:error, :locked} ->
        error(:registry_locked, "target registry is locked", path)

      {:error, :lock_cleanup_failed, {:ok, _result}} ->
        lock_cleanup_error(path, bytes, operations)

      {:error, :lock_cleanup_failed, {:error, %Error{} = body_error}} ->
        {:error, append_cleanup_message(body_error, "target registry lock cleanup failed")}

      {:error, _reason} ->
        error(:atomic_replace_failed, "target registry lock could not be acquired", path)
    end
  end

  defp append_cleanup_message(%Error{} = body_error, cleanup_message) do
    %Error{body_error | message: body_error.message <> "; " <> cleanup_message}
  end

  defp run_with_lock(lock_path, operation, final_verify, operations) do
    case acquire_lock(lock_path, operations) do
      {:ok, ownership} ->
        result = invoke_callback(operation)
        before_release_result = invoke(operations, :before_lock_release, [])
        final_verify_result = invoke_callback(fn -> final_verify.(result) end)
        release_result = release_lock(ownership, operations)

        if before_release_result == :ok and final_verify_result == :ok and release_result == :ok,
          do: {:ok, result},
          else: {:error, :lock_cleanup_failed, result}

      {:error, :eexist} ->
        {:error, :locked}

      {:error, :lock_cleanup_failed} ->
        {:error, :lock_cleanup_failed}

      {:error, _reason} ->
        {:error, :lock_failed}
    end
  end

  defp invoke_callback(operation) do
    operation.()
  rescue
    _exception -> {:error, :operation_exception}
  catch
    _kind, _reason -> {:error, :operation_exception}
  end

  defp acquire_lock(lock_path, operations) do
    case invoke(operations, :mkdir, [lock_path]) do
      :ok -> establish_lock_ownership(lock_path, operations)
      {:error, :eexist} -> {:error, :eexist}
      _failure -> {:error, :lock_create_failed}
    end
  end

  defp establish_lock_ownership(lock_path, operations) do
    token = random_token()
    token_path = Path.join(lock_path, ".owner-" <> token)

    case invoke(operations, :lstat, [lock_path]) do
      {:ok, lock_stat} ->
        if valid_file_stat?(lock_stat) and lock_stat.type == :directory,
          do: establish_token_ownership(lock_path, lock_stat, token_path, token, operations),
          else: {:error, :lock_identity_failed}

      _failure ->
        {:error, :lock_identity_failed}
    end
  end

  defp establish_token_ownership(lock_path, lock_stat, token_path, token, operations) do
    case create_and_verify_lock_token(token_path, token, operations) do
      {:ok, token_stat} ->
        confirm_lock_ownership(lock_path, lock_stat, token_path, token_stat, token, operations)

      {:error, _reason, token_ownership} ->
        cleanup_failed_lock(lock_path, lock_stat, token_path, token_ownership, operations)
    end
  end

  defp confirm_lock_ownership(lock_path, lock_stat, token_path, token_stat, token, operations) do
    ownership = %TempOwnership{path: token_path, stat: token_stat}

    case invoke(operations, :lstat, [lock_path]) do
      {:ok, current_lock_stat} ->
        if same_identity?(lock_stat, current_lock_stat) do
          {:ok,
           %LockOwnership{
             path: lock_path,
             stat: lock_stat,
             token_path: token_path,
             token_stat: token_stat,
             token: token
           }}
        else
          cleanup_failed_lock(lock_path, lock_stat, token_path, ownership, operations)
        end

      _failure ->
        cleanup_failed_lock(lock_path, lock_stat, token_path, ownership, operations)
    end
  end

  defp create_and_verify_lock_token(token_path, token, operations) do
    case Map.fetch!(operations, :lock_token_create) do
      nil -> create_default_lock_token(token_path, token, operations)
      _override -> create_overridden_lock_token(token_path, token, operations)
    end
  end

  defp create_default_lock_token(token_path, token, operations) do
    case invoke(operations, :lock_token_open, [token_path, [:write, :binary, :exclusive]]) do
      {:ok, device} ->
        persist_lock_token(token_path, token, device, operations)

      {:error, _reason, creation_identity} ->
        ownership = explicit_creation_ownership(token_path, creation_identity)
        {:error, :lock_token_create_failed, ownership}

      _failure ->
        {:error, :lock_token_create_failed, nil}
    end
  end

  defp persist_lock_token(token_path, token, device, operations) do
    capture_result = capture_lock_token(token_path, device, operations)

    write_result =
      case capture_result do
        {:ok, _ownership} ->
          with :ok <- invoke(operations, :lock_token_chmod, [token_path, 0o600]),
               :ok <- invoke(operations, :lock_token_write, [device, token]),
               :ok <- invoke(operations, :lock_token_sync, [device]) do
            :ok
          else
            _failure -> {:error, :lock_token_persist_failed}
          end

        {:error, _reason, _ownership} ->
          {:error, :lock_token_identity_failed}
      end

    close_result = invoke(operations, :lock_token_close, [device])
    finish_persisted_lock_token(token_path, token, capture_result, write_result, close_result, operations)
  end

  defp capture_lock_token(token_path, device, operations) do
    with {:ok, stat} <- invoke(operations, :lstat, [token_path]),
         true <- valid_file_stat?(stat) and stat.type == :regular do
      capture_lock_token_descriptor(token_path, stat, device, operations)
    else
      _failure -> {:error, :lock_token_identity_failed, nil}
    end
  end

  defp capture_lock_token_descriptor(token_path, stat, device, operations) do
    with {:ok, device_stat} <- invoke(operations, :lock_token_fstat, [device]),
         true <- same_descriptor_identity?(stat, device_stat) do
      {:ok, %TempOwnership{path: token_path, stat: stat}}
    else
      _failure -> {:error, :lock_token_identity_failed, nil}
    end
  end

  defp finish_persisted_lock_token(
         token_path,
         token,
         capture_result,
         write_result,
         close_result,
         operations
       ) do
    ownership =
      case capture_result do
        {:ok, ownership} -> ownership
        {:error, _reason, ownership} -> ownership
      end

    case {write_result, close_result} do
      {:ok, :ok} -> verify_persisted_lock_token(token_path, token, ownership, operations)
      _failure -> {:error, :lock_token_persist_failed, ownership}
    end
  end

  defp verify_persisted_lock_token(token_path, token, ownership, operations) do
    case inspect_lock_token(token_path, token, operations) do
      {:ok, token_stat, ^token} -> accept_private_lock_token(token_stat, ownership)
      _failure -> {:error, :lock_token_identity_failed, ownership}
    end
  end

  defp accept_private_lock_token(token_stat, ownership) do
    if private_lock_token?(token_stat) and same_identity?(ownership.stat, token_stat),
      do: {:ok, token_stat},
      else: {:error, :lock_token_identity_failed, ownership}
  end

  defp create_overridden_lock_token(token_path, token, operations) do
    case invoke(operations, :lock_token_create, [token_path, token]) do
      :ok ->
        verify_overridden_lock_token(token_path, token, operations)

      {:error, _reason, creation_identity} ->
        ownership = explicit_creation_ownership(token_path, creation_identity)
        {:error, :lock_token_create_failed, ownership}

      _failure ->
        {:error, :lock_token_create_failed, nil}
    end
  end

  defp verify_overridden_lock_token(token_path, token, operations) do
    case inspect_lock_token(token_path, token, operations) do
      {:ok, token_stat, ^token} ->
        ownership = %TempOwnership{path: token_path, stat: token_stat}

        if private_lock_token?(token_stat),
          do: {:ok, token_stat},
          else: {:error, :lock_token_not_private, ownership}

      _failure ->
        {:error, :lock_token_identity_failed, nil}
    end
  end

  defp explicit_creation_ownership(path, {:created, %File.Stat{} = stat}) do
    if valid_file_stat?(stat) and stat.type == :regular,
      do: %TempOwnership{path: path, stat: stat},
      else: nil
  end

  defp explicit_creation_ownership(
         path,
         %TempOwnership{path: path, stat: %File.Stat{} = stat} = ownership
       ) do
    if valid_file_stat?(stat) and stat.type == :regular, do: ownership, else: nil
  end

  defp explicit_creation_ownership(_path, _creation_identity), do: nil

  defp inspect_lock_token(token_path, token, operations) do
    with {:ok, before_stat} <- invoke(operations, :lstat, [token_path]),
         true <- valid_file_stat?(before_stat) and before_stat.type == :regular,
         {:ok, device} <- invoke(operations, :lock_token_open, [token_path, [:read, :binary, :raw]]) do
      inspect_open_lock_token(token_path, token, before_stat, device, operations)
    else
      _failure -> {:error, :lock_token_identity_failed}
    end
  end

  defp inspect_open_lock_token(token_path, token, before_stat, device, operations) do
    result =
      with {:ok, device_stat} <- invoke(operations, :lock_token_fstat, [device]),
           true <- same_descriptor_identity?(before_stat, device_stat),
           {:ok, bytes} <- read_lock_token(device, byte_size(token) + 1),
           {:ok, current_stat} <- invoke(operations, :lstat, [token_path]),
           true <- same_identity?(before_stat, current_stat) do
        {:ok, current_stat, bytes}
      else
        _failure -> {:error, :lock_token_identity_failed}
      end

    close_result = invoke(operations, :lock_token_close, [device])
    if close_result == :ok, do: result, else: {:error, :lock_token_close_failed}
  end

  defp read_lock_token(device, limit) do
    case :file.read(device, limit) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      _failure -> {:error, :lock_token_read_failed}
    end
  end

  defp cleanup_failed_lock(lock_path, lock_stat, token_path, token_ownership, operations) do
    token_cleanup_result =
      case token_ownership do
        %TempOwnership{} = ownership -> remove_owned_lock_token(ownership, operations)
        nil -> token_absent?(token_path, operations)
      end

    lock_cleanup_result =
      if token_cleanup_result == :ok,
        do: remove_owned_lock_dir(lock_path, lock_stat, operations),
        else: {:error, :lock_token_unowned}

    if token_cleanup_result == :ok and lock_cleanup_result == :ok,
      do: {:error, :lock_identity_failed},
      else: {:error, :lock_cleanup_failed}
  end

  defp token_absent?(token_path, operations) do
    case invoke(operations, :lstat, [token_path]) do
      {:error, :enoent} -> :ok
      _present_or_unknown -> {:error, :lock_token_unowned}
    end
  end

  defp remove_owned_lock_token(%TempOwnership{} = ownership, operations) do
    case invoke(operations, :lstat, [ownership.path]) do
      {:ok, current_stat} ->
        remove_matching_lock_token(ownership, current_stat, operations)

      {:error, :enoent} ->
        :ok

      _failure ->
        {:error, :lock_token_identity_failed}
    end
  end

  defp remove_matching_lock_token(ownership, current_stat, operations) do
    if same_identity?(ownership.stat, current_stat),
      do: normalize_lock_token_remove(invoke(operations, :lock_token_remove, [ownership.path])),
      else: {:error, :lock_token_identity_changed}
  end

  defp normalize_lock_token_remove(:ok), do: :ok
  defp normalize_lock_token_remove(_failure), do: {:error, :lock_token_remove_failed}

  defp remove_owned_lock_dir(lock_path, lock_stat, operations) do
    case invoke(operations, :lstat, [lock_path]) do
      {:ok, current_lock_stat} ->
        remove_matching_lock_dir(lock_path, lock_stat, current_lock_stat, operations)

      _failure ->
        {:error, :lock_identity_failed}
    end
  end

  defp remove_matching_lock_dir(lock_path, lock_stat, current_lock_stat, operations) do
    if same_identity?(lock_stat, current_lock_stat),
      do: normalize_lock_dir_remove(invoke(operations, :rmdir, [lock_path])),
      else: {:error, :lock_identity_changed}
  end

  defp normalize_lock_dir_remove(:ok), do: :ok
  defp normalize_lock_dir_remove(_failure), do: {:error, :lock_remove_failed}

  defp release_lock(%LockOwnership{} = ownership, operations) do
    with {:ok, lock_stat} <- invoke(operations, :lstat, [ownership.path]),
         true <- same_identity?(ownership.stat, lock_stat),
         {:ok, token_stat, token} <-
           inspect_lock_token(ownership.token_path, ownership.token, operations),
         true <- private_lock_token?(token_stat),
         true <- token == ownership.token,
         true <- same_identity?(ownership.token_stat, token_stat),
         :ok <-
           remove_owned_lock_token(
             %TempOwnership{path: ownership.token_path, stat: token_stat},
             operations
           ),
         :ok <- remove_owned_lock_dir(ownership.path, ownership.stat, operations) do
      :ok
    else
      _failure -> {:error, :lock_cleanup_failed}
    end
  end

  defp private_lock_token?(stat) do
    valid_file_stat?(stat) and stat.type == :regular and
      Bitwise.band(stat.mode, 0o777) == 0o600
  end

  defp lock_cleanup_error(path, bytes, operations) do
    expected_generation = generation(bytes)

    observed_generation =
      case read_with(path, operations) do
        {:ok, %{generation: generation}} -> generation
        {:error, %Error{}} -> "unavailable"
      end

    after_rename_error(path, expected_generation, observed_generation)
  end

  defp replace_while_locked(path, bytes, expected_generation, operations) do
    case read_with(path, operations) do
      {:ok, %{generation: ^expected_generation}} ->
        open_and_replace(path, bytes, operations)

      {:ok, %{generation: _current_generation}} ->
        error(:stale_generation, "target registry generation is stale", path)

      {:error, %Error{}} = read_error ->
        read_error
    end
  end

  defp open_and_replace(path, bytes, operations) do
    case create_temp_with(path, bytes, operations) do
      {:ok, ownership} ->
        case invoke(operations, :rename, [ownership.path, path]) do
          :ok ->
            verify_after_rename(path, bytes, operations)

          _failure ->
            reconcile_failed_rename(ownership, path, bytes, operations)
        end

      {:error, :temp_cleanup_failed} ->
        error(:atomic_replace_failed, "target registry temporary file cleanup failed", path)

      {:error, _reason} ->
        error(:atomic_replace_failed, "target registry temporary file could not be persisted", path)
    end
  end

  defp reconcile_failed_rename(ownership, path, bytes, operations) do
    case read_with(path, operations) do
      {:ok, %{bytes: ^bytes}} ->
        _cleanup_result = remove_owned_temp(ownership, operations)
        _sync_result = invoke(operations, :sync_parent, [Path.dirname(path)])
        expected_generation = generation(bytes)

        observed_generation =
          case read_with(path, operations) do
            {:ok, %{bytes: ^bytes, generation: generation}} -> generation
            {:ok, %{generation: generation}} -> generation
            {:error, %Error{}} -> "unavailable"
          end

        after_rename_error(path, expected_generation, observed_generation)

      _not_committed ->
        result = error(:atomic_replace_failed, "target registry could not be renamed atomically", path)
        finish_temp(result, ownership, path, operations)
    end
  end

  defp create_temp_with(path, bytes, operations) do
    with temp_path when is_binary(temp_path) <- invoke(operations, :temp_path, [path]),
         :ok <- validate_temp_path(path, temp_path) do
      open_temp(temp_path, bytes, operations)
    else
      _failure -> {:error, :temp_path_failed}
    end
  end

  defp open_temp(temp_path, bytes, operations) do
    case invoke(operations, :open, [temp_path, [:write, :binary, :exclusive]]) do
      {:ok, device} ->
        persist_open_temp(temp_path, device, bytes, operations)

      {:error, _reason, creation_identity} ->
        finish_partial_temp(
          explicit_creation_ownership(temp_path, creation_identity),
          operations
        )

      _failure ->
        {:error, :open_failed}
    end
  end

  defp persist_open_temp(temp_path, device, bytes, operations) do
    case capture_open_temp(temp_path, device, operations) do
      {:ok, ownership} ->
        persist_owned_temp(ownership, device, bytes, operations)

      {:error, _reason} = error ->
        close_after_identity_failure(device, operations, error)
    end
  end

  defp close_after_identity_failure(device, operations, result) do
    result
  after
    _close_result = invoke(operations, :close, [device])
  end

  defp persist_owned_temp(ownership, device, bytes, operations) do
    case write_and_close(ownership.path, device, bytes, operations) do
      :ok -> {:ok, ownership}
      {:error, _reason} -> cleanup_failed_persist(ownership, operations)
    end
  end

  defp cleanup_failed_persist(ownership, operations) do
    case remove_owned_temp(ownership, operations) do
      :ok -> {:error, :persist_failed}
      {:error, _reason} -> {:error, :temp_cleanup_failed}
    end
  end

  defp capture_open_temp(temp_path, device, operations) do
    with {:ok, stat} <- invoke(operations, :lstat, [temp_path]),
         true <- valid_file_stat?(stat) and stat.type == :regular,
         {:ok, device_stat} <- invoke(operations, :fstat, [device]),
         true <- same_descriptor_identity?(stat, device_stat) do
      {:ok, %TempOwnership{path: temp_path, stat: stat}}
    else
      _failure -> {:error, :temp_identity_failed}
    end
  end

  defp finish_partial_temp(nil, _operations), do: {:error, :open_failed}

  defp finish_partial_temp(%TempOwnership{} = ownership, operations) do
    case remove_owned_temp(ownership, operations) do
      :ok -> {:error, :open_failed}
      {:error, _reason} -> {:error, :temp_cleanup_failed}
    end
  end

  defp finish_temp(result, ownership, path, operations) do
    case remove_owned_temp(ownership, operations) do
      :ok -> result
      {:error, _reason} -> error(:atomic_replace_failed, "target registry temporary file cleanup failed", path)
    end
  end

  defp remove_owned_temp(%TempOwnership{} = ownership, operations) do
    case invoke(operations, :lstat, [ownership.path]) do
      {:ok, current_stat} ->
        if valid_file_stat?(current_stat),
          do: remove_matching_temp(ownership, current_stat, operations),
          else: {:error, :identity_unavailable}

      {:error, :enoent} ->
        :ok

      _failure ->
        {:error, :identity_unavailable}
    end
  end

  defp remove_matching_temp(ownership, current_stat, operations) do
    if same_identity?(ownership.stat, current_stat) do
      normalize_temp_remove(invoke(operations, :remove, [ownership.path]))
    else
      {:error, :identity_changed}
    end
  end

  defp normalize_temp_remove(:ok), do: :ok
  defp normalize_temp_remove(_failure), do: {:error, :remove_failed}

  defp write_and_close(temp_path, device, bytes, operations) do
    write_result =
      with :ok <- invoke(operations, :chmod, [temp_path, 0o600]),
           :ok <- invoke(operations, :write, [device, bytes]),
           :ok <- invoke(operations, :sync, [device]) do
        :ok
      else
        _failure -> {:error, :write_failed}
      end

    close_result = invoke(operations, :close, [device])

    cond do
      write_result != :ok -> write_result
      close_result != :ok -> {:error, :close_failed}
      true -> :ok
    end
  end

  defp verify_after_rename(path, bytes, operations) do
    expected_generation = generation(bytes)
    sync_result = invoke(operations, :sync_parent, [Path.dirname(path)])

    case read_with(path, operations) do
      {:ok, %{generation: ^expected_generation} = result} when sync_result == :ok ->
        {:ok, result}

      {:ok, %{generation: ^expected_generation}} ->
        after_rename_error(path, expected_generation, expected_generation)

      {:ok, %{generation: observed_generation}} ->
        error(
          :checksum_mismatch,
          generation_message("target registry checksum verification failed", expected_generation, observed_generation),
          path
        )

      {:error, %Error{}} ->
        after_rename_error(path, expected_generation, "unavailable")
    end
  end

  defp after_rename_error(path, expected_generation, observed_generation) do
    error(
      :atomic_replace_failed,
      generation_message("target registry replacement could not be durably verified", expected_generation, observed_generation),
      path
    )
  end

  defp generation_message(prefix, expected_generation, observed_generation) do
    "#{prefix}; expected_generation=#{expected_generation}; observed_generation=#{observed_generation}"
  end

  defp read_with(path, operations) do
    case invoke(operations, :read, [path]) do
      {:ok, bytes} when is_binary(bytes) ->
        {:ok, %{bytes: bytes, generation: generation(bytes)}}

      {:error, :enoent} ->
        error(:registry_not_found, "target registry was not found", path)

      _failure ->
        error(:registry_unreadable, "target registry could not be read", path)
    end
  end

  defp lock_options(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(opts, fn {key, _value} -> key in [:file_ops, :final_verify] end),
         true <- length(Keyword.get_values(opts, :final_verify)) <= 1,
         final_verify <- Keyword.get(opts, :final_verify, fn _result -> :ok end),
         true <- is_function(final_verify, 1),
         {:ok, operations} <- operations(Keyword.drop(opts, [:final_verify]), :lock) do
      {:ok, operations, final_verify}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp operations(opts, required_set) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(opts, fn {key, _value} -> key == :file_ops end),
         true <- length(Keyword.get_values(opts, :file_ops)) <= 1,
         overrides when is_map(overrides) <- Keyword.get(opts, :file_ops, %{}),
         true <- valid_operations?(overrides, required_set) do
      {:ok, Map.merge(default_operations(), overrides)}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp valid_operations?(overrides, required_set) do
    required_keys =
      case required_set do
        :read ->
          [:read]

        :lock ->
          [
            :before_lock_release,
            :lock_token_chmod,
            :lock_token_close,
            :lock_token_create,
            :lock_token_fstat,
            :lock_token_open,
            :lock_token_remove,
            :lock_token_sync,
            :lock_token_write,
            :lstat,
            :mkdir,
            :rmdir
          ]

        :temp ->
          [:chmod, :close, :fstat, :lstat, :open, :remove, :sync, :temp_path, :write]

        :temp_cleanup ->
          [:lstat, :remove]

        :replace ->
          Map.keys(@operation_arities)
      end

    Enum.all?(Map.keys(overrides), &(&1 in required_keys)) and
      Enum.all?(overrides, fn {key, function} ->
        is_function(function, Map.fetch!(@operation_arities, key))
      end)
  end

  defp default_operations do
    %{
      before_lock_release: fn -> :ok end,
      chmod: &File.chmod/2,
      close: &:file.close/1,
      fstat: &:file.read_file_info/1,
      lock_token_chmod: &File.chmod/2,
      lock_token_close: &:file.close/1,
      lock_token_create: nil,
      lock_token_fstat: &:file.read_file_info/1,
      lock_token_open: &:file.open/2,
      lock_token_remove: &File.rm/1,
      lock_token_sync: &:file.sync/1,
      lock_token_write: &:file.write/2,
      lstat: &File.lstat/1,
      mkdir: &File.mkdir/1,
      open: &:file.open/2,
      read: &File.read/1,
      remove: &File.rm/1,
      rename: &File.rename/2,
      rmdir: &File.rmdir/1,
      sync: &:file.sync/1,
      sync_parent: &sync_directory/1,
      temp_path: &unique_temp_path/1,
      write: &:file.write/2
    }
  end

  defp invoke(operations, operation, arguments) do
    apply(Map.fetch!(operations, operation), arguments)
  rescue
    _exception -> {:error, :operation_exception}
  catch
    _kind, _reason -> {:error, :operation_exception}
  end

  @spec sync_directory(Path.t(), keyword()) :: :ok | {:error, :parent_sync_failed}
  def sync_directory(directory, opts \\ []) do
    with true <- is_binary(directory),
         {:ok, open} <- sync_open(opts) do
      case invoke_sync_open(open, directory) do
        {:ok, device} ->
          sync_device(device)

        {:error, reason} when reason in [:eisdir, :enotsup, :einval] ->
          :ok

        _failure ->
          {:error, :parent_sync_failed}
      end
    else
      _invalid -> {:error, :parent_sync_failed}
    end
  end

  defp sync_device(device) do
    sync_result = :file.sync(device)
    close_result = :file.close(device)

    if sync_result == :ok and close_result == :ok,
      do: :ok,
      else: {:error, :parent_sync_failed}
  end

  defp sync_open([]), do: {:ok, &:file.open/2}

  defp sync_open(open: operation) when is_function(operation, 2),
    do: {:ok, operation}

  defp sync_open(_opts), do: {:error, :invalid_options}

  defp invoke_sync_open(open, directory) do
    open.(directory, [:read, :raw, :directory])
  rescue
    _exception -> {:error, :operation_exception}
  catch
    _kind, _reason -> {:error, :operation_exception}
  end

  defp same_identity?(left, right) do
    valid_file_stat?(left) and
      valid_file_stat?(right) and
      left.type == right.type and
      left.inode == right.inode and
      left.major_device == right.major_device and
      left.minor_device == right.minor_device
  end

  defp same_descriptor_identity?(stat, device_stat) do
    valid_file_info?(device_stat) and
      stat.type == file_info(device_stat, :type) and
      stat.inode == file_info(device_stat, :inode) and
      stat.major_device == file_info(device_stat, :major_device) and
      stat.minor_device == file_info(device_stat, :minor_device)
  end

  defp valid_file_stat?(%File.Stat{
         inode: inode,
         major_device: major_device,
         minor_device: minor_device,
         type: type,
         mode: mode
       }),
       do:
         is_integer(inode) and is_integer(major_device) and is_integer(minor_device) and
           is_atom(type) and is_integer(mode)

  defp valid_file_stat?(_stat), do: false

  defp valid_file_info?(stat) do
    Record.is_record(stat, :file_info) and
      tuple_size(stat) == tuple_size(file_info()) and
      is_integer(file_info(stat, :inode)) and
      is_integer(file_info(stat, :major_device)) and
      is_integer(file_info(stat, :minor_device)) and
      is_atom(file_info(stat, :type)) and
      is_integer(file_info(stat, :mode))
  end

  defp random_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp unique_temp_path(path) do
    basename = Path.basename(path)
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(Path.dirname(path), ".#{basename}.tmp-#{suffix}")
  end

  defp validate_temp_path(path, temp_path) do
    same_directory? = Path.dirname(temp_path) == Path.dirname(path)
    safe_basename? = Path.basename(temp_path) not in ["", ".", ".."]
    no_traversal? = ".." not in Path.split(temp_path)
    distinct? = temp_path not in [path, path <> ".lock"]

    if validate_path(temp_path) == :ok and same_directory? and safe_basename? and no_traversal? and distinct?,
      do: :ok,
      else: {:error, :invalid_temp_path}
  end

  defp validate_path(path) when is_binary(path) do
    if path != "" and String.valid?(path) and Path.type(path) == :absolute and
         not String.contains?(path, <<0>>) and Path.basename(path) not in ["", ".", ".."],
       do: :ok,
       else: {:error, :invalid_path}
  end

  defp validate_path(_path), do: {:error, :invalid_path}

  defp valid_generation?(generation),
    do: is_binary(generation) and Regex.match?(@generation_regex, generation)

  defp path_or_nil(path) when is_binary(path), do: path
  defp path_or_nil(_path), do: nil

  defp generation(bytes) do
    "sha256:" <> (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))
  end

  defp error(code, message, path), do: {:error, %Error{code: code, message: message, path: path}}
end
