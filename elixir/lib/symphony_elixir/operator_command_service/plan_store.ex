defmodule SymphonyElixir.OperatorCommandService.PlanStore do
  @moduledoc false

  alias Jason.OrderedObject
  alias SymphonyElixir.TargetRegistry.Error
  alias SymphonyElixir.TargetRegistry.FileStore
  require Record

  @file_info_fields Record.extract(:file_info, from_lib: "kernel/include/file.hrl")
  Record.defrecordp(:file_info, @file_info_fields)
  @file_info_size length(@file_info_fields) + 1

  defguardp valid_file_info(stat)
            when is_tuple(stat) and tuple_size(stat) == @file_info_size and
                   elem(stat, 0) == :file_info and is_integer(file_info(stat, :inode)) and
                   is_integer(file_info(stat, :major_device)) and
                   is_integer(file_info(stat, :minor_device)) and
                   is_atom(file_info(stat, :type)) and is_integer(file_info(stat, :mode))

  @build_keys [
    "action",
    "command",
    "created_at",
    "envelope_version",
    "expected_generation",
    "registry_path",
    "source_hashes",
    "target_id"
  ]
  @envelope_keys ["plan_id", "proposed_generation" | @build_keys]
  @identity_keys [
    "action",
    "command",
    "envelope_version",
    "expected_generation",
    "proposed_generation",
    "registry_path",
    "source_hashes",
    "target_id"
  ]
  @envelope_key_order [
    "envelope_version",
    "plan_id",
    "action",
    "target_id",
    "command",
    "registry_path",
    "expected_generation",
    "proposed_generation",
    "source_hashes",
    "created_at"
  ]
  @actions ~w(add import patch activate dispatch_mode pause drain retire remove dispatch)
  @forbidden_key_families ~w(authorization bearer private_key connection_string access_token client_secret credential credentials password passwords secret secrets token tokens api_key api_keys)
  @forbidden_exact_keys MapSet.new(~w(audit audit_claim audit_claims env environment prompt prompts provider_error raw_error))
  @target_id_regex ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
  @generation_regex ~r/^sha256:[0-9a-f]{64}$/
  @plan_id_regex ~r/^[0-9a-f]{64}$/
  @max_file_bytes 1_048_576
  @max_string_bytes 65_536
  @max_collection_width 256
  @max_depth 16
  @store_operation_arities %{
    before_lock_release: 0,
    before_existing_plan_open: 0,
    before_plan_dir_create: 0,
    before_plan_lock: 0,
    chmod: 2,
    close: 1,
    fstat: 1,
    link: 2,
    lstat: 1,
    open: 2,
    remove: 1,
    rmdir: 1,
    sync: 1,
    sync_parent: 1,
    temp_path: 1,
    write: 2
  }
  @lock_operation_keys [:before_lock_release, :rmdir]
  @temp_operation_keys [:chmod, :close, :fstat, :lstat, :open, :remove, :sync, :temp_path, :write]
  @temp_cleanup_operation_keys [:lstat, :remove]

  @max_nodes 4_096
  @min_integer -9_223_372_036_854_775_808
  @max_integer 9_223_372_036_854_775_807

  @spec build(map(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def build(fields, proposed_registry_bytes)
      when is_map(fields) and is_binary(proposed_registry_bytes) do
    with true <- exact_keys?(fields, @build_keys),
         :ok <- validate_fields(fields) do
      envelope =
        fields
        |> Map.put("proposed_generation", generation(proposed_registry_bytes))
        |> Map.put("plan_id", "")

      {:ok, Map.put(envelope, "plan_id", identity(envelope))}
    else
      _invalid -> plan_corrupt()
    end
  end

  def build(_fields, _proposed_registry_bytes), do: plan_corrupt()

  @spec store(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def store(plan_dir, envelope, opts \\ []) do
    with {:ok, file_ops} <- store_operations(opts),
         :ok <- validate_plan_dir(plan_dir),
         :ok <- validate_envelope(envelope),
         {:ok, bytes} <- encode_envelope(envelope),
         {:ok, plan_dir_stat} <- mkdir_plan_dir(plan_dir, file_ops) do
      store_locked(plan_dir, plan_dir_stat, envelope, bytes, file_ops)
    else
      {:error, %Error{}} = error -> error
      _invalid -> plan_corrupt()
    end
  end

  @spec read(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def read(plan_dir, plan_id, opts \\ []) do
    with :ok <- validate_plan_dir(plan_dir),
         true <- valid_plan_id?(plan_id),
         {:ok, plan_dir_stat} <- validate_read_plan_dir(plan_dir),
         {:ok, before_open} <- read_hook(opts) do
      read_path(plan_dir, plan_dir_stat, plan_path(plan_dir, plan_id), plan_id, before_open)
    else
      _invalid -> plan_corrupt()
    end
  end

  @spec consume(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def consume(plan_dir, plan_id, opts \\ []) do
    with :ok <- validate_plan_dir(plan_dir),
         true <- valid_plan_id?(plan_id),
         {:ok, plan_dir_stat} <- validate_existing_plan_dir(plan_dir),
         {:ok, before_remove} <- consume_hook(opts) do
      consume_locked(plan_dir, plan_dir_stat, plan_path(plan_dir, plan_id), plan_id, before_remove)
    else
      {:error, %Error{}} = error -> error
      _invalid -> plan_corrupt()
    end
  end

  defp consume_locked(plan_dir, plan_dir_stat, path, plan_id, before_remove) do
    operation = fn -> consume_owned(plan_dir, plan_dir_stat, path, plan_id, before_remove) end

    with :ok <- verify_plan_dir(plan_dir, plan_dir_stat),
         {:ok, result} <- FileStore.with_lock(path, operation),
         :ok <- verify_plan_dir(plan_dir, plan_dir_stat) do
      result
    else
      _failure -> atomic_error(path)
    end
  end

  defp consume_owned(plan_dir, plan_dir_stat, path, plan_id, before_remove) do
    with :ok <- verify_plan_dir(plan_dir, plan_dir_stat),
         {:ok, before_stat} <- private_lstat(path),
         {:ok, device} <- :file.open(path, [:read, :binary, :raw]) do
      consume_open_device(plan_dir, plan_dir_stat, path, plan_id, before_remove, before_stat, device)
    else
      {:error, :enoent} -> plan_not_found(path)
      _failure -> plan_corrupt(path)
    end
  end

  defp consume_open_device(
         plan_dir,
         plan_dir_stat,
         path,
         plan_id,
         before_remove,
         before_stat,
         device
       ) do
    result =
      with {:ok, device_stat} when valid_file_info(device_stat) <- :file.read_file_info(device),
           true <- same_file?(before_stat, device_stat),
           {:ok, bytes} <- read_device(device),
           {:ok, envelope} <- decode_envelope(bytes, plan_id, path),
           :ok <- invoke_hook(before_remove),
           :ok <- verify_plan_dir(plan_dir, plan_dir_stat),
           {:ok, ^bytes} <- reread_device(device),
           {:ok, current_stat} <- private_lstat(path),
           true <- same_file?(current_stat, device_stat),
           :ok <- remove_plan(path),
           :ok <- verify_plan_dir(plan_dir, plan_dir_stat) do
        {:ok, envelope}
      else
        {:error, %Error{}} = error -> error
        _failure -> plan_corrupt(path)
      end

    close_result = :file.close(device)
    if close_result == :ok, do: result, else: atomic_error(path)
  end

  defp store_locked(plan_dir, plan_dir_stat, envelope, bytes, file_ops) do
    plan_path = plan_path(plan_dir, envelope["plan_id"])

    with :ok <- invoke_store(file_ops, :before_plan_lock, [], fn -> :ok end),
         :ok <- verify_plan_dir(plan_dir, plan_dir_stat) do
      store_in_bound_dir(plan_dir, plan_dir_stat, plan_path, envelope, bytes, file_ops)
    else
      _failure -> atomic_error(plan_path)
    end
  end

  defp store_in_bound_dir(plan_dir, plan_dir_stat, plan_path, envelope, bytes, file_ops) do
    lock_ops = Map.take(file_ops, @lock_operation_keys)

    operation = fn ->
      store_owned(plan_dir, plan_dir_stat, plan_path, envelope, bytes, file_ops)
    end

    final_verify = fn
      {:ok, _envelope} ->
        with :ok <- verify_plan_dir(plan_dir, plan_dir_stat),
             {:ok, ^bytes} <- stable_private_bytes(plan_path) do
          :ok
        else
          _failure -> {:error, :final_verify_failed}
        end

      _body_error ->
        :ok
    end

    case FileStore.with_lock(plan_path, operation,
           file_ops: lock_ops,
           final_verify: final_verify
         ) do
      {:ok, result} ->
        result

      {:error, :lock_cleanup_failed, {:ok, _envelope}} ->
        committed_error(plan_path, bytes, "plan envelope lock cleanup failed after publication")

      {:error, :lock_cleanup_failed, {:error, %Error{} = body_error}} ->
        {:error, append_cleanup_message(body_error, "plan envelope lock cleanup failed")}

      _failure ->
        atomic_error(plan_path)
    end
  end

  defp append_cleanup_message(%Error{} = body_error, cleanup_message) do
    %Error{body_error | message: body_error.message <> "; " <> cleanup_message}
  end

  defp committed_error(plan_path, bytes, prefix) do
    expected_generation = generation(bytes)

    observed_generation =
      case stable_private_bytes(plan_path) do
        {:ok, observed_bytes} -> generation(observed_bytes)
        {:error, _reason} -> "unavailable"
      end

    atomic_error(
      plan_path,
      "#{prefix}; proposed_generation=#{expected_generation}; expected_generation=#{expected_generation}; observed_generation=#{observed_generation}"
    )
  end

  defp store_owned(plan_dir, plan_dir_stat, plan_path, envelope, bytes, file_ops) do
    before_open = Map.get(file_ops, :before_existing_plan_open, fn -> :ok end)

    case stable_private_bytes(plan_path, before_open) do
      {:ok, ^bytes} ->
        {:ok, envelope}

      {:ok, _different_bytes} ->
        plan_corrupt(plan_path)

      {:error, :enoent} ->
        write_new_plan(plan_dir, plan_dir_stat, plan_path, envelope, bytes, file_ops)

      {:error, reason} when reason in [:not_private_regular_file, :unstable_private_file] ->
        plan_corrupt(plan_path)

      {:error, _reason} ->
        atomic_error(plan_path)
    end
  end

  defp write_new_plan(plan_dir, plan_dir_stat, plan_path, envelope, bytes, file_ops) do
    temp_ops = Map.take(file_ops, @temp_operation_keys)

    case FileStore.create_temp(plan_path, bytes, file_ops: temp_ops) do
      {:ok, ownership} ->
        publish_new_plan(
          plan_dir,
          plan_dir_stat,
          ownership,
          plan_path,
          envelope,
          bytes,
          file_ops
        )

      {:error, _reason} ->
        atomic_error(plan_path)
    end
  end

  defp publish_new_plan(
         plan_dir,
         plan_dir_stat,
         ownership,
         plan_path,
         envelope,
         bytes,
         file_ops
       ) do
    case verify_plan_dir(plan_dir, plan_dir_stat) do
      :ok ->
        case invoke_store(file_ops, :link, [ownership.path, plan_path], &File.ln/2) do
          :ok ->
            finish_linked_plan(
              plan_dir,
              plan_dir_stat,
              ownership,
              plan_path,
              envelope,
              bytes,
              file_ops
            )

          failure ->
            finish_failed_link(
              plan_dir,
              plan_dir_stat,
              ownership,
              plan_path,
              envelope,
              bytes,
              file_ops,
              failure
            )
        end

      {:error, _reason} ->
        case remove_plan_temp(ownership, file_ops) do
          :ok -> atomic_error(plan_path)
          {:error, _reason} -> atomic_error(plan_path, "plan envelope temp cleanup failed before publication")
        end
    end
  end

  defp finish_linked_plan(
         plan_dir,
         plan_dir_stat,
         ownership,
         plan_path,
         envelope,
         bytes,
         file_ops
       ) do
    cleanup_result = remove_plan_temp(ownership, file_ops)
    sync_result = sync_plan_parent(plan_path, file_ops)
    directory_result = verify_plan_dir(plan_dir, plan_dir_stat)

    case stable_private_bytes(plan_path) do
      {:ok, ^bytes}
      when cleanup_result == :ok and sync_result == :ok and directory_result == :ok ->
        {:ok, envelope}

      _failure ->
        committed_error(plan_path, bytes, "plan envelope publication could not be durably verified")
    end
  end

  defp finish_existing_plan(
         plan_dir,
         plan_dir_stat,
         ownership,
         plan_path,
         envelope,
         bytes,
         file_ops
       ) do
    case remove_plan_temp(ownership, file_ops) do
      :ok -> accept_existing_plan(plan_dir, plan_dir_stat, plan_path, envelope, bytes)
      {:error, _reason} -> atomic_error(plan_path)
    end
  end

  defp finish_failed_link(
         plan_dir,
         plan_dir_stat,
         ownership,
         plan_path,
         envelope,
         bytes,
         file_ops,
         failure
       ) do
    case stable_private_bytes(plan_path) do
      {:ok, ^bytes} ->
        existing_race? =
          failure == {:error, :eexist} and
            linked_destination_identity(ownership, plan_path, file_ops) == :foreign

        if existing_race? do
          finish_existing_plan(
            plan_dir,
            plan_dir_stat,
            ownership,
            plan_path,
            envelope,
            bytes,
            file_ops
          )
        else
          _cleanup_result = remove_plan_temp(ownership, file_ops)
          _sync_result = sync_plan_parent(plan_path, file_ops)
          _directory_result = verify_plan_dir(plan_dir, plan_dir_stat)
          committed_error(plan_path, bytes, "plan envelope link failed after publication")
        end

      _not_committed ->
        case remove_plan_temp(ownership, file_ops) do
          :ok when failure == {:error, :eexist} -> plan_corrupt(plan_path)
          :ok -> atomic_error(plan_path)
          {:error, _reason} -> atomic_error(plan_path, "plan envelope temp cleanup failed before publication")
        end
    end
  end

  defp linked_destination_identity(ownership, plan_path, file_ops) do
    case invoke_store(file_ops, :lstat, [plan_path], &File.lstat/1) do
      {:ok,
       %File.Stat{
         inode: inode,
         major_device: major_device,
         minor_device: minor_device,
         type: type,
         mode: mode
       } = destination_stat}
      when is_integer(inode) and is_integer(major_device) and is_integer(minor_device) and
             is_atom(type) and is_integer(mode) ->
        if same_stat_identity?(ownership.stat, destination_stat), do: :owned, else: :foreign

      _unavailable ->
        :unavailable
    end
  end

  defp sync_plan_parent(plan_path, file_ops) do
    invoke_store(
      file_ops,
      :sync_parent,
      [Path.dirname(plan_path)],
      &FileStore.sync_directory/1
    )
  end

  defp remove_plan_temp(ownership, file_ops) do
    cleanup_ops = Map.take(file_ops, @temp_cleanup_operation_keys)
    FileStore.remove_temp(ownership, file_ops: cleanup_ops)
  end

  defp accept_existing_plan(plan_dir, plan_dir_stat, plan_path, envelope, bytes) do
    with :ok <- verify_plan_dir(plan_dir, plan_dir_stat),
         {:ok, ^bytes} <- stable_private_bytes(plan_path) do
      {:ok, envelope}
    else
      _failure -> plan_corrupt(plan_path)
    end
  end

  defp store_operations(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(opts, fn {key, _value} -> key == :file_ops end),
         true <- length(Keyword.get_values(opts, :file_ops)) <= 1,
         file_ops when is_map(file_ops) <- Keyword.get(opts, :file_ops, %{}),
         true <- valid_store_operations?(file_ops) do
      {:ok, file_ops}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp valid_store_operations?(file_ops) do
    Enum.all?(file_ops, fn {operation, function} ->
      case Map.fetch(@store_operation_arities, operation) do
        {:ok, arity} -> is_function(function, arity)
        :error -> false
      end
    end)
  end

  defp invoke_store(file_ops, operation, arguments, default) do
    file_ops
    |> Map.get(operation, default)
    |> apply(arguments)
  rescue
    _exception -> {:error, :operation_exception}
  catch
    _kind, _reason -> {:error, :operation_exception}
  end

  defp stable_private_bytes(path, before_open \\ fn -> :ok end) do
    with {:ok, before_stat} <- private_lstat(path),
         :ok <- invoke_hook(before_open),
         {:ok, device} <- :file.open(path, [:read, :binary, :raw]) do
      stable_private_open(path, before_stat, device)
    end
  end

  defp stable_private_open(path, before_stat, device) do
    result =
      with {:ok, device_stat} when valid_file_info(device_stat) <- :file.read_file_info(device),
           true <- same_file?(before_stat, device_stat),
           {:ok, bytes} <- read_device(device),
           {:ok, current_stat} <- private_lstat(path),
           true <- same_file?(current_stat, device_stat) do
        {:ok, bytes}
      else
        _failure -> {:error, :unstable_private_file}
      end

    close_result = :file.close(device)
    if close_result == :ok, do: result, else: {:error, :close_failed}
  end

  defp read_path(plan_dir, plan_dir_stat, path, requested_plan_id, before_open) do
    with :ok <- verify_plan_dir(plan_dir, plan_dir_stat),
         {:ok, before_stat} <- private_lstat(path),
         :ok <- invoke_hook(before_open),
         :ok <- verify_plan_dir(plan_dir, plan_dir_stat),
         {:ok, device} <- :file.open(path, [:read, :binary, :raw]) do
      result = read_open_device(path, requested_plan_id, before_stat, device)
      if verify_plan_dir(plan_dir, plan_dir_stat) == :ok, do: result, else: plan_corrupt(path)
    else
      {:error, :enoent} -> plan_not_found(path)
      _failure -> plan_corrupt(path)
    end
  end

  defp read_open_device(path, requested_plan_id, before_stat, device) do
    result =
      with {:ok, device_stat} when valid_file_info(device_stat) <- :file.read_file_info(device),
           true <- same_file?(before_stat, device_stat),
           {:ok, bytes} <- read_device(device),
           {:ok, current_stat} <- private_lstat(path),
           true <- same_file?(current_stat, device_stat) do
        decode_envelope(bytes, requested_plan_id, path)
      else
        _failure -> plan_corrupt(path)
      end

    close_result = :file.close(device)
    if close_result == :ok, do: result, else: plan_corrupt(path)
  end

  defp read_hook([]), do: {:ok, fn -> :ok end}

  defp read_hook(before_open: operation) when is_function(operation, 0),
    do: {:ok, operation}

  defp read_hook(_opts), do: {:error, :invalid_options}

  defp consume_hook([]), do: {:ok, fn -> :ok end}

  defp consume_hook(before_remove: operation) when is_function(operation, 0),
    do: {:ok, operation}

  defp consume_hook(_opts), do: {:error, :invalid_options}

  defp invoke_hook(operation) do
    operation.()
  rescue
    _exception -> {:error, :operation_exception}
  catch
    _kind, _reason -> {:error, :operation_exception}
  end

  defp private_lstat(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode} = stat} ->
        if Bitwise.band(mode, 0o777) == 0o600,
          do: {:ok, stat},
          else: {:error, :not_private_regular_file}

      {:ok, _not_regular} ->
        {:error, :not_regular_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp same_file?(stat, device_stat) do
    stat.type == file_info(device_stat, :type) and
      stat.inode == file_info(device_stat, :inode) and
      stat.major_device == file_info(device_stat, :major_device) and
      stat.minor_device == file_info(device_stat, :minor_device)
  end

  defp read_device(device) do
    case :file.read(device, @max_file_bytes + 1) do
      {:ok, bytes} when byte_size(bytes) <= @max_file_bytes -> {:ok, bytes}
      _failure -> {:error, :invalid_file}
    end
  end

  defp reread_device(device) do
    with {:ok, 0} <- :file.position(device, :bof) do
      read_device(device)
    end
  end

  defp decode_envelope(bytes, requested_plan_id, path) do
    with {:ok, ordered} <- Jason.decode(bytes, objects: :ordered_objects),
         {:ok, envelope, _remaining} <- plain_json(ordered, 0, @max_nodes),
         :ok <- validate_envelope(envelope),
         true <- envelope["plan_id"] == requested_plan_id do
      {:ok, envelope}
    else
      _invalid -> plan_corrupt(path)
    end
  end

  defp plain_json(_value, depth, _remaining) when depth > @max_depth,
    do: {:error, :too_deep}

  defp plain_json(_value, _depth, remaining) when remaining <= 0,
    do: {:error, :too_large}

  defp plain_json(%OrderedObject{values: pairs}, depth, remaining)
       when length(pairs) <= @max_collection_width do
    keys = Enum.map(pairs, &elem(&1, 0))

    if valid_object_keys?(keys) and length(Enum.uniq(keys)) == length(keys) do
      plain_json_pairs(pairs, depth, remaining)
    else
      {:error, :invalid_object}
    end
  end

  defp plain_json(%OrderedObject{}, _depth, _remaining), do: {:error, :too_wide}

  defp plain_json(values, depth, remaining)
       when is_list(values) and length(values) <= @max_collection_width do
    Enum.reduce_while(values, {:ok, [], remaining - 1}, fn value, {:ok, items, left} ->
      case plain_json(value, depth + 1, left) do
        {:ok, nested, next_left} -> {:cont, {:ok, [nested | items], next_left}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items, left} -> {:ok, Enum.reverse(items), left}
      {:error, _reason} = error -> error
    end
  end

  defp plain_json(values, _depth, _remaining) when is_list(values), do: {:error, :too_wide}

  defp plain_json(value, _depth, remaining) do
    if scalar_json?(value), do: {:ok, value, remaining - 1}, else: {:error, :invalid_value}
  end

  defp plain_json_pairs(pairs, depth, remaining) do
    Enum.reduce_while(
      pairs,
      {:ok, %{}, remaining - 1},
      &plain_json_pair(&1, &2, depth)
    )
  end

  defp plain_json_pair({key, value}, {:ok, map, left}, depth) do
    case plain_json(value, depth + 1, left) do
      {:ok, nested, next_left} -> {:cont, {:ok, Map.put(map, key, nested), next_left}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp validate_envelope(envelope) do
    with true <- is_map(envelope),
         true <- exact_keys?(envelope, @envelope_keys),
         :ok <- validate_fields(envelope),
         true <- valid_generation?(envelope["proposed_generation"]),
         true <- valid_plan_id?(envelope["plan_id"]),
         true <- identity(envelope) == envelope["plan_id"] do
      :ok
    else
      _invalid -> {:error, :invalid_envelope}
    end
  end

  defp validate_fields(fields) do
    with true <- fields["envelope_version"] == 1,
         true <- fields["action"] in @actions,
         true <- valid_target_id?(fields["target_id"]),
         true <- is_map(fields["command"]),
         true <- valid_json?(fields["command"]),
         true <- valid_path?(fields["registry_path"]),
         true <- valid_generation?(fields["expected_generation"]),
         true <- valid_source_hashes?(fields["source_hashes"]),
         true <- valid_created_at?(fields["created_at"]) do
      :ok
    else
      _invalid -> {:error, :invalid_fields}
    end
  end

  defp valid_json?(value), do: match?({:ok, _plain, _remaining}, plain_term(value, 0, @max_nodes))

  defp plain_term(_value, depth, _remaining) when depth > @max_depth,
    do: {:error, :too_deep}

  defp plain_term(_value, _depth, remaining) when remaining <= 0,
    do: {:error, :too_large}

  defp plain_term(value, depth, remaining) when is_map(value) and map_size(value) <= @max_collection_width do
    if valid_object_keys?(Map.keys(value)) do
      plain_term_pairs(value, depth, remaining)
    else
      {:error, :invalid_object}
    end
  end

  defp plain_term(value, _depth, _remaining) when is_map(value), do: {:error, :too_wide}

  defp plain_term(values, depth, remaining) when is_list(values) do
    case bounded_list(values) do
      {:ok, bounded_values} -> plain_term_list(bounded_values, depth, remaining)
      :error -> {:error, :too_wide}
    end
  end

  defp plain_term(value, _depth, remaining) do
    if scalar_json?(value), do: {:ok, value, remaining - 1}, else: {:error, :invalid_value}
  end

  defp plain_term_pairs(value, depth, remaining) do
    Enum.reduce_while(
      value,
      {:ok, %{}, remaining - 1},
      &plain_term_pair(&1, &2, depth)
    )
  end

  defp plain_term_pair({key, nested}, {:ok, map, left}, depth) do
    case plain_term(nested, depth + 1, left) do
      {:ok, plain, next_left} -> {:cont, {:ok, Map.put(map, key, plain), next_left}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp plain_term_list(values, depth, remaining) do
    Enum.reduce_while(
      values,
      {:ok, [], remaining - 1},
      &plain_term_list_item(&1, &2, depth)
    )
  end

  defp plain_term_list_item(value, {:ok, items, left}, depth) do
    case plain_term(value, depth + 1, left) do
      {:ok, plain, next_left} -> {:cont, {:ok, [plain | items], next_left}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp bounded_list(values) do
    if proper_bounded_list?(values, 0), do: {:ok, values}, else: :error
  end

  defp proper_bounded_list?([], _count), do: true

  defp proper_bounded_list?([_value | tail], count) when count < @max_collection_width,
    do: proper_bounded_list?(tail, count + 1)

  defp proper_bounded_list?(_values, _count), do: false

  defp valid_object_keys?(keys) do
    Enum.all?(keys, fn key ->
      is_binary(key) and valid_string?(key) and not forbidden_key?(key)
    end)
  end

  defp forbidden_key?("max_total_tokens"), do: false

  defp forbidden_key?(key) do
    normalized =
      key
      |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
      |> String.replace(~r/[-\s]+/u, "_")
      |> String.downcase()

    MapSet.member?(@forbidden_exact_keys, normalized) or
      Enum.any?(@forbidden_key_families, fn family ->
        normalized == family or String.ends_with?(normalized, "_" <> family)
      end)
  end

  defp scalar_json?(value) when is_binary(value), do: valid_string?(value)
  defp scalar_json?(value) when is_integer(value), do: value >= @min_integer and value <= @max_integer

  defp scalar_json?(value) when is_float(value) do
    rendered = :erlang.float_to_binary(value, [:compact])
    rendered not in ["nan", "inf", "-inf"]
  end

  defp scalar_json?(value), do: value in [nil, true, false]

  defp valid_string?(value), do: String.valid?(value) and byte_size(value) <= @max_string_bytes

  defp valid_target_id?(target_id),
    do:
      is_binary(target_id) and byte_size(target_id) <= 128 and
        Regex.match?(@target_id_regex, target_id)

  defp valid_plan_id?(plan_id),
    do: is_binary(plan_id) and Regex.match?(@plan_id_regex, plan_id)

  defp valid_generation?(value),
    do: is_binary(value) and Regex.match?(@generation_regex, value)

  defp valid_path?(path),
    do:
      is_binary(path) and byte_size(path) <= 4_096 and String.valid?(path) and
        Path.type(path) == :absolute and not String.contains?(path, <<0>>)

  defp validate_plan_dir(plan_dir) do
    if valid_path?(plan_dir), do: :ok, else: {:error, :invalid_plan_dir}
  end

  defp valid_source_hashes?(source_hashes)
       when is_map(source_hashes) and map_size(source_hashes) <= @max_collection_width do
    Enum.all?(source_hashes, fn {path, hash} -> valid_path?(path) and valid_generation?(hash) end)
  end

  defp valid_source_hashes?(_source_hashes), do: false

  defp valid_created_at?(value) when is_binary(value) do
    String.ends_with?(value, "Z") and match?({:ok, _date_time, 0}, DateTime.from_iso8601(value))
  end

  defp valid_created_at?(_value), do: false

  defp exact_keys?(map, expected),
    do: Enum.all?(Map.keys(map), &is_binary/1) and Enum.sort(Map.keys(map)) == Enum.sort(expected)

  defp identity(envelope) do
    envelope
    |> Map.take(@identity_keys)
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp encode_envelope(envelope) do
    bytes =
      @envelope_key_order
      |> Enum.map(fn key -> {key, canonical(envelope[key])} end)
      |> OrderedObject.new()
      |> Jason.encode!()

    if byte_size(bytes) <= @max_file_bytes, do: {:ok, bytes}, else: plan_corrupt()
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _nested} -> key end)
    |> Enum.map(fn {key, nested} -> {key, canonical(nested)} end)
    |> OrderedObject.new()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp mkdir_plan_dir(plan_dir, file_ops) do
    case File.lstat(plan_dir) do
      {:ok, stat} ->
        if private_plan_dir?(stat), do: {:ok, stat}, else: atomic_error(plan_dir)

      {:error, :enoent} ->
        create_plan_dir(plan_dir, file_ops)

      {:error, _reason} ->
        atomic_error(plan_dir)
    end
  end

  defp create_plan_dir(plan_dir, file_ops) do
    with :ok <- File.mkdir_p(Path.dirname(plan_dir)),
         :ok <- invoke_store(file_ops, :before_plan_dir_create, [], fn -> :ok end),
         :ok <- File.mkdir(plan_dir),
         {:ok, %File.Stat{type: :directory} = created_stat} <- File.lstat(plan_dir),
         :ok <- File.chmod(plan_dir, 0o700),
         {:ok, final_stat} <- File.lstat(plan_dir),
         true <- same_stat_identity?(created_stat, final_stat),
         true <- private_plan_dir?(final_stat) do
      {:ok, final_stat}
    else
      {:error, :eexist} -> validate_existing_plan_dir(plan_dir)
      _failure -> atomic_error(plan_dir)
    end
  end

  defp validate_read_plan_dir(plan_dir) do
    case File.lstat(plan_dir) do
      {:ok, stat} -> if private_plan_dir?(stat), do: {:ok, stat}, else: {:error, :invalid_plan_dir}
      {:error, _reason} -> {:error, :invalid_plan_dir}
    end
  end

  defp validate_existing_plan_dir(plan_dir) do
    case File.lstat(plan_dir) do
      {:ok, stat} -> if private_plan_dir?(stat), do: {:ok, stat}, else: atomic_error(plan_dir)
      {:error, _reason} -> atomic_error(plan_dir)
    end
  end

  defp verify_plan_dir(plan_dir, expected_stat) do
    case File.lstat(plan_dir) do
      {:ok, current_stat} ->
        if private_plan_dir?(current_stat) and same_stat_identity?(expected_stat, current_stat),
          do: :ok,
          else: {:error, :plan_dir_identity_changed}

      {:error, _reason} ->
        {:error, :plan_dir_identity_changed}
    end
  end

  defp private_plan_dir?(%File.Stat{type: :directory, mode: mode}),
    do: Bitwise.band(mode, 0o777) == 0o700

  defp private_plan_dir?(_stat), do: false

  defp same_stat_identity?(left, right) do
    left.type == right.type and
      left.inode == right.inode and
      left.major_device == right.major_device and
      left.minor_device == right.minor_device
  end

  defp remove_plan(path),
    do: if(File.rm(path) == :ok, do: :ok, else: atomic_error(path))

  defp plan_path(plan_dir, plan_id), do: Path.join(plan_dir, plan_id <> ".json")

  defp generation(bytes) do
    "sha256:" <> (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))
  end

  defp plan_not_found(path),
    do: {:error, %Error{code: :plan_not_found, message: "plan envelope was not found", path: path}}

  defp plan_corrupt(path \\ nil),
    do: {:error, %Error{code: :plan_corrupt, message: "plan envelope is corrupt", path: path}}

  defp atomic_error(path, message \\ "plan envelope could not be stored atomically"),
    do: {:error, %Error{code: :atomic_replace_failed, message: message, path: path}}
end
