defmodule SymphonyElixir.TargetRegistry.FileStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TargetRegistry.Error
  alias SymphonyElixir.TargetRegistry.FileStore

  @tag :tmp_dir
  test "reads exact registry bytes and their lowercase SHA-256 generation", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    bytes = "version: 1\n# exact bytes\ntargets: {}\n"
    File.write!(path, bytes)

    assert {:ok, %{bytes: ^bytes, generation: generation}} = FileStore.read(path)

    assert generation ==
             "sha256:" <> (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))
  end

  @tag :tmp_dir
  test "atomically replaces an existing registry with a mode 0600 file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    original = "version: 1\ntargets: {}\n"
    replacement = "version: 1\ntargets:\n  main:\n    state: paused\n"
    File.write!(path, original)
    {:ok, %{generation: expected_generation}} = FileStore.read(path)

    assert {:ok, %{bytes: ^replacement, generation: proposed_generation}} =
             FileStore.replace(path, replacement, expected_generation)

    assert File.read!(path) == replacement
    assert proposed_generation == generation(replacement)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert File.ls!(tmp_dir) == ["targets.yml"]

    assert :ok = FileStore.sync_directory(tmp_dir)

    assert :ok =
             FileStore.sync_directory(tmp_dir,
               open: fn _directory, _modes -> {:error, :enotsup} end
             )

    assert {:error, :parent_sync_failed} =
             FileStore.sync_directory(tmp_dir,
               open: fn _directory, _modes -> {:error, :eacces} end
             )

    for failure <- [
          fn _directory, _modes -> raise "opaque sync open failure" end,
          fn _directory, _modes -> throw(:opaque_sync_open_failure) end,
          fn _directory, _modes -> exit(:opaque_sync_open_failure) end
        ] do
      assert {:error, :parent_sync_failed} =
               FileStore.sync_directory(tmp_dir, open: failure)
    end

    assert {:error, :parent_sync_failed} = FileStore.sync_directory(:invalid)

    assert {:error, :parent_sync_failed} =
             FileStore.sync_directory(tmp_dir, unknown: :option)
  end

  @tag :tmp_dir
  test "orders injected file operations and keeps the temporary file in the registry directory", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "targets.yml")
    original = "original registry bytes"
    replacement = "replacement registry bytes"
    File.write!(path, original)
    parent = self()

    record = fn event -> send(parent, event) end

    file_ops = %{
      mkdir: fn lock_path ->
        record.({:mkdir, lock_path})
        File.mkdir(lock_path)
      end,
      read: fn read_path ->
        record.({:read, read_path})
        File.read(read_path)
      end,
      temp_path: fn registry_path ->
        temp_path = Path.join(Path.dirname(registry_path), ".targets.yml.ordered-temp")
        record.({:temp_path, temp_path})
        temp_path
      end,
      open: fn temp_path, modes ->
        record.({:open, temp_path, modes})
        :file.open(temp_path, modes)
      end,
      chmod: fn temp_path, mode ->
        record.({:chmod, temp_path, mode})
        File.chmod(temp_path, mode)
      end,
      write: fn device, bytes ->
        record.({:write, bytes})
        :file.write(device, bytes)
      end,
      sync: fn device ->
        record.(:sync_temp)
        :file.sync(device)
      end,
      close: fn device ->
        record.(:close_temp)
        :file.close(device)
      end,
      rename: fn source, destination ->
        record.({:rename, source, destination})
        File.rename(source, destination)
      end,
      sync_parent: fn directory ->
        record.({:sync_parent, directory})
        :ok
      end,
      remove: fn temp_path ->
        record.({:remove, temp_path})
        File.rm(temp_path)
      end,
      rmdir: fn lock_path ->
        record.({:rmdir, lock_path})
        File.rmdir(lock_path)
      end
    }

    assert {:ok, %{bytes: ^replacement}} =
             FileStore.replace(path, replacement, generation(original), file_ops: file_ops)

    temp_path = Path.join(tmp_dir, ".targets.yml.ordered-temp")

    assert collect_events(13) == [
             {:mkdir, path <> ".lock"},
             {:read, path},
             {:temp_path, temp_path},
             {:open, temp_path, [:write, :binary, :exclusive]},
             {:chmod, temp_path, 0o600},
             {:write, replacement},
             :sync_temp,
             :close_temp,
             {:rename, temp_path, path},
             {:sync_parent, tmp_dir},
             {:read, path},
             {:read, path},
             {:rmdir, path <> ".lock"}
           ]
  end

  @tag :tmp_dir
  test "rejects missing and unreadable registries without decoding their bytes", %{tmp_dir: tmp_dir} do
    missing_path = Path.join(tmp_dir, "missing.yml")

    assert {:error, %Error{code: :registry_not_found}} = FileStore.read(missing_path)
    assert {:error, %Error{code: :registry_unreadable}} = FileStore.read(42)

    assert {:error, %Error{code: :registry_unreadable}} =
             FileStore.read(missing_path, file_ops: %{read: fn _path -> raise "opaque read failure" end})

    invalid_utf8_path = Path.join(tmp_dir, "opaque.yml")

    assert {:error, %Error{code: :registry_unreadable}} =
             FileStore.read(missing_path, unknown: :option)

    invalid_utf8 = <<0xFF, 0x00, 0x80>>
    File.write!(invalid_utf8_path, invalid_utf8)
    assert {:ok, %{bytes: ^invalid_utf8}} = FileStore.read(invalid_utf8_path)
  end

  @tag :tmp_dir
  test "uses the owned lock causally and rejects a concurrent writer", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    original = "original"
    File.write!(path, original)
    owner = self()

    first =
      Task.async(fn ->
        FileStore.replace(path, "first replacement", generation(original),
          file_ops: %{
            mkdir: fn lock_path ->
              :ok = File.mkdir(lock_path)
              send(owner, {:lock_acquired, self()})

              receive do
                :continue -> :ok
              end
            end
          }
        )
      end)

    assert_receive {:lock_acquired, first_pid}
    assert File.dir?(path <> ".lock")

    assert {:error, %Error{code: :registry_locked}} =
             FileStore.replace(path, "second replacement", generation(original))

    send(first_pid, :continue)
    assert {:ok, %{bytes: "first replacement"}} = Task.await(first)
    refute File.exists?(path <> ".lock")
    assert File.read!(path) == "first replacement"
  end

  @tag :tmp_dir
  test "rejects stale generations before creating a temporary file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    original = "current bytes"
    File.write!(path, original)
    parent = self()

    assert {:error, %Error{code: :stale_generation}} =
             FileStore.replace(path, "replacement", generation("stale bytes"),
               file_ops: %{
                 temp_path: fn _path -> send(parent, :temp_requested) end
               }
             )

    assert {:error, %Error{code: :registry_unreadable}} =
             FileStore.replace(path, "replacement", generation(original),
               file_ops: %{
                 read: fn _path -> {:error, :eio} end,
                 temp_path: fn _path -> send(parent, :temp_requested) end
               }
             )

    refute_receive :temp_requested
    assert File.read!(path) == original
    refute_receive :temp_requested
    assert File.read!(path) == original
    assert File.ls!(tmp_dir) == ["targets.yml"]
  end

  @tag :tmp_dir
  test "preserves original bytes and removes owned temporary files on every pre-rename failure", %{
    tmp_dir: tmp_dir
  } do
    failures = [
      {:open, fn _path, _modes -> {:error, :eacces} end},
      {:chmod, fn _path, _mode -> {:error, :eacces} end},
      {:short_write,
       fn device, _bytes ->
         :ok = :file.write(device, "short")
         {:ok, 5}
       end},
      {:sync, fn _device -> {:error, :eio} end},
      {:close,
       fn device ->
         :ok = :file.close(device)
         {:error, :eio}
       end},
      {:rename, fn _source, _destination -> {:error, :eio} end}
    ]

    Enum.each(failures, fn {operation, failure} ->
      case_dir = Path.join(tmp_dir, Atom.to_string(operation))
      File.mkdir_p!(case_dir)
      path = Path.join(case_dir, "targets.yml")
      original = "original #{operation}"
      File.write!(path, original)
      operation = if operation == :short_write, do: :write, else: operation

      assert {:error, %Error{code: :atomic_replace_failed}} =
               FileStore.replace(path, "replacement", generation(original), file_ops: %{operation => failure})

      assert File.read!(path) == original
      assert File.ls!(case_dir) == ["targets.yml"]
    end)
  end

  @tag :tmp_dir
  test "catches exceptions, throws, and exits while preserving bytes and cleaning owned state", %{
    tmp_dir: tmp_dir
  } do
    failures = [
      fn _device, _bytes -> raise "opaque failure" end,
      fn _device, _bytes -> throw(:opaque_failure) end,
      fn _device, _bytes -> exit(:opaque_failure) end
    ]

    Enum.with_index(failures, fn failure, index ->
      case_dir = Path.join(tmp_dir, Integer.to_string(index))
      File.mkdir_p!(case_dir)
      path = Path.join(case_dir, "targets.yml")
      original = "original #{index}"
      File.write!(path, original)

      assert {:error, %Error{code: :atomic_replace_failed}} =
               FileStore.replace(path, "replacement", generation(original), file_ops: %{write: failure})

      assert File.read!(path) == original
      assert File.ls!(case_dir) == ["targets.yml"]
    end)
  end

  @tag :tmp_dir
  test "does not remove a lock it did not acquire", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    lock_path = path <> ".lock"
    File.write!(path, "original")
    File.mkdir!(lock_path)
    File.write!(Path.join(lock_path, "owner"), "other writer")

    assert {:error, %Error{code: :registry_locked}} =
             FileStore.replace(path, "replacement", generation("original"))

    assert File.read!(Path.join(lock_path, "owner")) == "other writer"
    assert File.read!(path) == "original"
  end

  @tag :tmp_dir
  test "reports lock acquisition errors without removing unowned state", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    File.write!(path, "original")

    assert {:error, %Error{code: :atomic_replace_failed}} =
             FileStore.replace(path, "replacement", generation("original"), file_ops: %{mkdir: fn _lock_path -> {:error, :eacces} end})

    assert File.read!(path) == "original"
    refute File.exists?(path <> ".lock")
  end

  @tag :tmp_dir
  test "preserves a replacement lock and reports committed bytes when ownership changes", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "targets.yml")
    lock_path = path <> ".lock"
    original = "original"
    replacement = "replacement"
    File.write!(path, original)

    sync_parent = fn _directory ->
      Enum.each(File.ls!(lock_path), fn entry -> File.rm!(Path.join(lock_path, entry)) end)
      File.rmdir!(lock_path)
      File.mkdir!(lock_path)
      File.write!(Path.join(lock_path, "foreign-owner"), "replacement lock")
      :ok
    end

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             FileStore.replace(path, replacement, generation(original), file_ops: %{sync_parent: sync_parent})

    assert message =~ "expected_generation=#{generation(replacement)}"
    assert message =~ "observed_generation=#{generation(replacement)}"
    assert File.read!(path) == replacement
    assert File.read!(Path.join(lock_path, "foreign-owner")) == "replacement lock"
  end

  @tag :tmp_dir
  test "surfaces lock directory removal failure after publication", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    lock_path = path <> ".lock"
    original = "original"
    replacement = "replacement"
    File.write!(path, original)
    rmdir = fn ^lock_path -> {:error, :eio} end

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             FileStore.replace(path, replacement, generation(original), file_ops: %{rmdir: rmdir})

    assert message =~ "expected_generation=#{generation(replacement)}"
    assert message =~ "observed_generation=#{generation(replacement)}"
    assert File.read!(path) == replacement
    assert File.dir?(lock_path)
    File.rmdir!(lock_path)
  end

  @tag :tmp_dir
  test "reports expected and observed generations after a checksum mismatch", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    original = "original"
    replacement = "replacement"
    File.write!(path, original)
    read_count_key = {__MODULE__, make_ref()}

    read = fn read_path ->
      count = Process.get(read_count_key, 0)
      Process.put(read_count_key, count + 1)

      if count == 0, do: File.read(read_path), else: {:ok, "observed corruption"}
    end

    assert {:error, %Error{code: :checksum_mismatch, message: message}} =
             FileStore.replace(path, replacement, generation(original), file_ops: %{read: read})

    assert message =~ "expected_generation=#{generation(replacement)}"
    assert message =~ "observed_generation=#{generation("observed corruption")}"
    assert File.read!(path) == replacement
    assert File.ls!(tmp_dir) == ["targets.yml"]
  end

  @tag :tmp_dir
  test "reports a post-rename durability failure without claiming rollback", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    original = "original"
    replacement = "replacement"
    File.write!(path, original)

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             FileStore.replace(path, replacement, generation(original),
               file_ops: %{
                 sync_parent: fn _directory -> {:error, :eio} end
               }
             )

    assert message =~ "expected_generation=#{generation(replacement)}"
    assert message =~ "observed_generation=#{generation(replacement)}"
    refute message =~ "rollback"
    assert File.read!(path) == replacement
  end

  @tag :tmp_dir

  test "reports an unavailable observed generation when the post-rename read fails", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "targets.yml")
    original = "original"
    replacement = "replacement"
    File.write!(path, original)
    read_count_key = {__MODULE__, make_ref()}

    read = fn read_path ->
      count = Process.get(read_count_key, 0)
      Process.put(read_count_key, count + 1)
      if count == 0, do: File.read(read_path), else: {:error, :eio}
    end

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             FileStore.replace(path, replacement, generation(original), file_ops: %{read: read})

    assert message =~ "expected_generation=#{generation(replacement)}"
    assert message =~ "observed_generation=unavailable"
    assert File.read!(path) == replacement
    assert File.ls!(tmp_dir) == ["targets.yml"]
  end

  test "rejects relative registry paths before every file operation" do
    parent = self()
    relative_path = "relative/targets.yml"
    mkdir = fn _path -> send(parent, :relative_mkdir) end

    assert {:error, %Error{code: :registry_unreadable}} =
             FileStore.read(relative_path,
               file_ops: %{read: fn _path -> send(parent, :relative_read) end}
             )

    assert {:error, %Error{code: :atomic_replace_failed}} =
             FileStore.replace(relative_path, "replacement", generation("original"), file_ops: %{mkdir: mkdir})

    refute_receive :relative_read
    refute_receive :relative_mkdir
    refute File.exists?("relative")
  end

  @tag :tmp_dir
  test "rejects invalid arguments, injection, and traversal-generated temporary paths before mutation", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "targets.yml")
    original = "original"
    File.write!(path, original)

    invalid_calls = [
      fn -> FileStore.replace(path, :not_binary, generation(original)) end,
      fn -> FileStore.replace(42, "replacement", generation(original)) end,
      fn -> FileStore.replace(path, "replacement", "SHA256:" <> String.duplicate("a", 64)) end,
      fn -> FileStore.replace(path, "replacement", generation(original), unknown: :option) end,
      fn ->
        FileStore.replace(path, "replacement", generation(original), file_ops: %{write: fn _one_argument -> :ok end})
      end,
      fn ->
        FileStore.replace(path, "replacement", generation(original), file_ops: %{temp_path: fn _path -> Path.join(tmp_dir, "../escaped.tmp") end})
      end
    ]

    Enum.each(invalid_calls, fn invalid_call ->
      assert {:error, %Error{code: :atomic_replace_failed}} = invalid_call.()
      assert File.read!(path) == original
    end)

    refute File.exists?(Path.join(Path.dirname(tmp_dir), "escaped.tmp"))
    assert File.ls!(tmp_dir) == ["targets.yml"]
  end

  @tag :tmp_dir
  test "requires explicit identity for partial temporary cleanup", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "targets.yml")
    temp_path = Path.join(tmp_dir, ".targets.yml.partial-open")
    original = "original"
    File.write!(path, original)

    open_then_fail = fn open_path, modes ->
      {:ok, device} = :file.open(open_path, modes)
      :ok = :file.close(device)
      owned_stat = File.lstat!(open_path)
      {:error, :eio, {:created, owned_stat}}
    end

    assert {:error, %Error{code: :atomic_replace_failed}} =
             FileStore.replace(path, "replacement", generation(original),
               file_ops: %{
                 temp_path: fn _path -> temp_path end,
                 open: open_then_fail
               }
             )

    assert File.read!(path) == original
    refute File.exists?(temp_path)
    assert File.ls!(tmp_dir) == ["targets.yml"]

    replacement_path = Path.join(tmp_dir, ".targets.yml.partial-replaced")
    foreign_replacement_path = replacement_path <> ".foreign"

    replace_then_fail = fn ^replacement_path, modes ->
      {:ok, device} = :file.open(replacement_path, modes)
      :ok = :file.close(device)
      owned_stat = File.lstat!(replacement_path)
      File.write!(foreign_replacement_path, "foreign replacement")
      assert File.exists?(replacement_path)
      assert File.exists?(foreign_replacement_path)
      File.rename!(foreign_replacement_path, replacement_path)
      {:error, :eio, {:created, owned_stat}}
    end

    assert {:error, :temp_cleanup_failed} =
             FileStore.create_temp(path, "replacement",
               file_ops: %{
                 temp_path: fn _path -> replacement_path end,
                 open: replace_then_fail
               }
             )

    assert File.read!(replacement_path) == "foreign replacement"

    failed_cleanup_path = Path.join(tmp_dir, ".targets.yml.partial-remove-failure")

    fail_after_create = fn ^failed_cleanup_path, modes ->
      {:ok, device} = :file.open(failed_cleanup_path, modes)
      :ok = :file.close(device)
      {:error, :eio, {:created, File.lstat!(failed_cleanup_path)}}
    end

    assert {:error, %Error{code: :atomic_replace_failed, message: cleanup_message}} =
             FileStore.replace(path, "replacement", generation(original),
               file_ops: %{
                 temp_path: fn _path -> failed_cleanup_path end,
                 open: fail_after_create,
                 remove: fn ^failed_cleanup_path -> {:error, :eio} end
               }
             )

    assert cleanup_message == "target registry temporary file cleanup failed"
    assert File.exists?(failed_cleanup_path)

    for {suffix, creation_identity} <- [
          {"ambiguous-created", fn _path -> :created end},
          {"malformed-created", fn _path -> {:created, %{inode: :unknown}} end},
          {"malformed-ownership",
           fn path ->
             %FileStore.TempOwnership{
               path: path,
               stat: %File.Stat{
                 type: :directory,
                 inode: 1,
                 major_device: 1,
                 minor_device: 1,
                 mode: 0o600
               }
             }
           end}
        ] do
      unowned_path = Path.join(tmp_dir, ".targets.yml.#{suffix}")

      unowned_open = fn ^unowned_path, modes ->
        {:ok, device} = :file.open(unowned_path, modes)
        :ok = :file.close(device)
        File.write!(unowned_path, "unowned partial")
        {:error, :eio, creation_identity.(unowned_path)}
      end

      assert {:error, :open_failed} =
               FileStore.create_temp(path, "replacement",
                 file_ops: %{
                   temp_path: fn _path -> unowned_path end,
                   open: unowned_open
                 }
               )

      assert File.read!(unowned_path) == "unowned partial"
    end
  end

  @tag :tmp_dir
  test "does not remove a temporary path that exclusive open did not acquire", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    temp_path = Path.join(tmp_dir, ".targets.yml.foreign-temp")
    File.write!(path, "original")
    File.write!(temp_path, "other writer")

    assert {:error, %Error{code: :atomic_replace_failed}} =
             FileStore.replace(path, "replacement", generation("original"), file_ops: %{temp_path: fn _path -> temp_path end})

    assert File.read!(path) == "original"
    assert File.read!(temp_path) == "other writer"
    refute File.exists?(path <> ".lock")
  end

  @tag :tmp_dir
  test "preserves a foreign temporary file created before a generic open error", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    temp_path = Path.join(tmp_dir, ".targets.yml.generic-error")
    File.write!(path, "original")

    open = fn ^temp_path, _modes ->
      File.write!(temp_path, "foreign")
      {:error, :eio}
    end

    assert {:error, %Error{code: :atomic_replace_failed}} =
             FileStore.replace(path, "replacement", generation("original"), file_ops: %{temp_path: fn _path -> temp_path end, open: open})

    assert File.read!(temp_path) == "foreign"
    assert File.read!(path) == "original"
  end

  @tag :tmp_dir
  test "clears temp ownership after rename and preserves pathname reuse", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    temp_path = Path.join(tmp_dir, ".targets.yml.reused-after-rename")
    File.write!(path, "original")

    rename = fn ^temp_path, ^path ->
      :ok = File.rename(temp_path, path)
      :ok = File.write(temp_path, "foreign reuse")
      :ok
    end

    assert {:ok, %{bytes: "replacement"}} =
             FileStore.replace(path, "replacement", generation("original"),
               file_ops: %{
                 temp_path: fn _path -> temp_path end,
                 rename: rename
               }
             )

    assert File.read!(path) == "replacement"
    assert File.read!(temp_path) == "foreign reuse"
  end

  @tag :tmp_dir
  test "preserves foreign temp reuse and surfaces owned-temp cleanup failure", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    reused_path = Path.join(tmp_dir, ".targets.yml.reused-before-cleanup")
    failed_cleanup_path = Path.join(tmp_dir, ".targets.yml.cleanup-failure")
    File.write!(path, "original")

    sync = fn _device ->
      File.rm!(reused_path)
      File.write!(reused_path, "foreign reuse")
      {:error, :eio}
    end

    assert {:error, %Error{code: :atomic_replace_failed}} =
             FileStore.replace(path, "replacement", generation("original"),
               file_ops: %{
                 temp_path: fn _path -> reused_path end,
                 sync: sync
               }
             )

    assert File.read!(reused_path) == "foreign reuse"

    assert {:error, %Error{code: :atomic_replace_failed}} =
             FileStore.replace(path, "replacement", generation("original"),
               file_ops: %{
                 temp_path: fn _path -> failed_cleanup_path end,
                 sync: fn _device -> {:error, :eio} end,
                 remove: fn ^failed_cleanup_path -> {:error, :eio} end
               }
             )

    assert File.exists?(failed_cleanup_path)
  end

  @tag :tmp_dir
  test "keeps ownership primitive APIs total across identity and cleanup failures", %{tmp_dir: tmp_dir} do
    destination = Path.join(tmp_dir, "targets.yml")
    temp_path = Path.join(tmp_dir, ".targets.yml.primitive")

    assert {:error, :invalid_temp_arguments} = FileStore.create_temp("relative.yml", "bytes")
    assert {:error, :invalid_temp_arguments} = FileStore.create_temp(destination, :not_binary)
    assert {:error, :invalid_temp_arguments} = FileStore.create_temp(destination, "bytes", unknown: :option)
    assert {:error, :invalid_temp_arguments} = FileStore.remove_temp(:not_owned)

    assert {:ok, ownership} =
             FileStore.create_temp(destination, "bytes", file_ops: %{temp_path: fn _path -> temp_path end})

    assert {:error, :invalid_temp_arguments} = FileStore.remove_temp(ownership, unknown: :option)
    assert :ok = FileStore.remove_temp(ownership)

    vanished_path = Path.join(tmp_dir, ".targets.yml.vanished")

    assert {:ok, vanished} =
             FileStore.create_temp(destination, "bytes", file_ops: %{temp_path: fn _path -> vanished_path end})

    File.rm!(vanished_path)
    assert :ok = FileStore.remove_temp(vanished)

    unavailable_path = Path.join(tmp_dir, ".targets.yml.unavailable")

    assert {:ok, unavailable} =
             FileStore.create_temp(destination, "bytes", file_ops: %{temp_path: fn _path -> unavailable_path end})

    assert {:error, :identity_unavailable} =
             FileStore.remove_temp(unavailable, file_ops: %{lstat: fn _path -> {:error, :eio} end})

    File.rm!(unavailable_path)

    identity_path = Path.join(tmp_dir, ".targets.yml.identity-failure")
    parent = self()

    assert {:error, :temp_identity_failed} =
             FileStore.create_temp(destination, "bytes",
               file_ops: %{
                 temp_path: fn _path -> identity_path end,
                 fstat: fn _device -> {:error, :eio} end,
                 close: fn device ->
                   send(parent, :identity_device_closed)
                   :file.close(device)
                 end
               }
             )

    assert_receive :identity_device_closed
    refute_receive :identity_device_closed
    File.rm!(identity_path)

    absent_partial = Path.join(tmp_dir, ".targets.yml.absent-partial")

    assert {:error, :open_failed} =
             FileStore.create_temp(destination, "bytes",
               file_ops: %{
                 temp_path: fn _path -> absent_partial end,
                 open: fn _path, _modes -> {:error, :eio, :created} end
               }
             )

    refute File.exists?(absent_partial)
  end

  @tag :tmp_dir
  test "rejects malformed stat identities without raising or leaking an open temp", %{tmp_dir: tmp_dir} do
    destination = Path.join(tmp_dir, "targets.yml")
    temp_path = Path.join(tmp_dir, ".targets.yml.malformed-fstat")
    parent = self()

    assert {:error, :temp_identity_failed} =
             FileStore.create_temp(destination, "bytes",
               file_ops: %{
                 temp_path: fn _path -> temp_path end,
                 fstat: fn _device -> {:ok, {:file_info}} end,
                 close: fn device ->
                   send(parent, :malformed_fstat_device_closed)
                   :file.close(device)
                 end
               }
             )

    assert_receive :malformed_fstat_device_closed
    refute_receive :malformed_fstat_device_closed
    owned_stat = File.lstat!(temp_path)
    File.rm!(temp_path)

    assert {:error, :identity_unavailable} =
             FileStore.remove_temp(
               %FileStore.TempOwnership{
                 path: temp_path,
                 stat: owned_stat
               },
               file_ops: %{lstat: fn _path -> {:ok, %{type: :regular}} end}
             )

    lock_path = Path.join(tmp_dir, "malformed-lock")
    reject_malformed_lock = fn -> flunk("malformed lock stat ran the body") end
    malformed_lock_stat = fn _path -> {:ok, %{type: :directory}} end

    assert {:error, :lock_failed} =
             FileStore.with_lock(lock_path, reject_malformed_lock, file_ops: %{lstat: malformed_lock_stat})

    File.rm_rf!(lock_path <> ".lock")
  end

  @tag :tmp_dir
  test "rejects untrusted lock tokens and cleans only proved ownership", %{tmp_dir: tmp_dir} do
    permissive_path = Path.join(tmp_dir, "permissive-token")
    permissive_lock = permissive_path <> ".lock"
    parent = self()

    permissive_create = fn token_path, token ->
      File.write!(token_path, token, [:write, :binary, :exclusive])
      File.chmod!(token_path, 0o644)
      :ok
    end

    permissive_body = fn -> send(parent, :permissive_body_ran) end

    assert {:error, :lock_failed} =
             FileStore.with_lock(permissive_path, permissive_body, file_ops: %{lock_token_create: permissive_create})

    refute_receive :permissive_body_ran
    refute File.exists?(permissive_lock)

    partial_path = Path.join(tmp_dir, "partial-token")
    partial_lock = partial_path <> ".lock"

    partial_create = fn token_path, token ->
      File.write!(token_path, token, [:write, :binary, :exclusive])
      File.chmod!(token_path, 0o600)
      {:error, :eio, {:created, File.lstat!(token_path)}}
    end

    partial_body = fn -> send(parent, :partial_body_ran) end

    assert {:error, :lock_failed} =
             FileStore.with_lock(partial_path, partial_body, file_ops: %{lock_token_create: partial_create})

    refute_receive :partial_body_ran
    refute File.exists?(partial_lock)

    foreign_path = Path.join(tmp_dir, "foreign-token")
    foreign_lock = foreign_path <> ".lock"

    foreign_create = fn token_path, _token ->
      File.write!(token_path, "foreign", [:write, :binary, :exclusive])
      {:error, :eio}
    end

    foreign_body = fn -> send(parent, :foreign_body_ran) end

    assert {:error, :lock_cleanup_failed} =
             FileStore.with_lock(foreign_path, foreign_body, file_ops: %{lock_token_create: foreign_create})

    refute_receive :foreign_body_ran
    [foreign_name] = File.ls!(foreign_lock)
    assert File.read!(Path.join(foreign_lock, foreign_name)) == "foreign"
    File.rm_rf!(foreign_lock)
  end

  @tag :tmp_dir
  test "keeps lock token write lifecycle exceptions total and leak free", %{tmp_dir: tmp_dir} do
    parent = self()

    failures = [
      {:chmod, %{lock_token_chmod: fn _path, _mode -> raise "token chmod" end}},
      {:write, %{lock_token_write: fn _device, _token -> throw(:token_write) end}},
      {:sync, %{lock_token_sync: fn _device -> exit(:token_sync) end}},
      {:close,
       %{
         lock_token_close: fn device ->
           send(parent, :token_device_closed)
           :ok = :file.close(device)
           raise "token close"
         end
       }}
    ]

    Enum.each(failures, fn {name, file_ops} ->
      path = Path.join(tmp_dir, "token-#{name}")

      assert {:error, :lock_failed} =
               FileStore.with_lock(path, fn -> flunk("#{name} failure ran the body") end, file_ops: file_ops)

      refute File.exists?(path <> ".lock")
    end)

    assert_receive :token_device_closed
    refute_receive :token_device_closed
  end

  @tag :tmp_dir
  test "reconciles a rename that publishes before returning an error", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    original = "original"
    replacement = "replacement"
    expected_generation = generation(replacement)
    parent = self()
    File.write!(path, original)

    rename = fn source, ^path ->
      :ok = File.rename(source, path)
      {:error, :eio}
    end

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             FileStore.replace(path, replacement, generation(original),
               file_ops: %{
                 rename: rename,
                 sync_parent: fn ^tmp_dir ->
                   send(parent, :rename_error_parent_synced)
                   :ok
                 end
               }
             )

    assert message =~ "expected_generation=#{expected_generation}"
    assert message =~ "observed_generation=#{expected_generation}"
    assert_receive :rename_error_parent_synced
    refute_receive :rename_error_parent_synced
    assert File.read!(path) == replacement
    assert File.ls!(tmp_dir) == ["targets.yml"]
  end

  @tag :tmp_dir
  test "rejects a registry changed by the before-lock-release hook", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    original = "original"
    replacement = "replacement"
    foreign = "foreign after hook"
    File.write!(path, original)

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             FileStore.replace(path, replacement, generation(original),
               file_ops: %{
                 before_lock_release: fn ->
                   File.write!(path, foreign)
                   :ok
                 end
               }
             )

    assert message =~ "expected_generation=#{generation(replacement)}"
    assert message =~ "observed_generation=#{generation(foreign)}"
    assert File.read!(path) == foreign
  end

  @tag :tmp_dir
  test "preserves a stale body error when lock cleanup also fails", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "targets.yml")
    lock_path = path <> ".lock"
    original = "original"
    replacement = "replacement"
    File.write!(path, original)
    fail_lock_cleanup = fn ^lock_path -> {:error, :eio} end

    assert {:error,
            %Error{
              code: :stale_generation,
              message: "target registry generation is stale; target registry lock cleanup failed"
            }} =
             FileStore.replace(path, replacement, generation("stale"), file_ops: %{rmdir: fail_lock_cleanup})

    assert File.read!(path) == original
    File.rmdir!(lock_path)
  end

  @tag :tmp_dir
  test "catches lock callbacks and reports unavailable cleanup observations", %{tmp_dir: tmp_dir} do
    for callback <- [fn -> raise "lock callback" end, fn -> throw(:lock_callback) end] do
      path = Path.join(tmp_dir, "lock-callback-#{System.unique_integer([:positive])}")
      assert {:ok, {:error, :operation_exception}} = FileStore.with_lock(path, callback)
      refute File.exists?(path <> ".lock")
    end

    path = Path.join(tmp_dir, "targets.yml")
    lock_path = path <> ".lock"
    original = "original"
    replacement = "replacement"
    File.write!(path, original)
    read_count_key = {__MODULE__, make_ref()}

    read = fn read_path ->
      count = Process.get(read_count_key, 0)
      Process.put(read_count_key, count + 1)
      if count < 2, do: File.read(read_path), else: {:error, :eio}
    end

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             FileStore.replace(path, replacement, generation(original),
               file_ops: %{
                 read: read,
                 rmdir: fn ^lock_path -> {:error, :eio} end
               }
             )

    assert message =~ "observed_generation=unavailable"
    File.rmdir!(lock_path)

    cleanup_path = Path.join(tmp_dir, "cleanup.yml")
    cleanup_temp = Path.join(tmp_dir, ".cleanup.yml.temp")
    File.write!(cleanup_path, "original")

    assert {:error, %Error{code: :atomic_replace_failed}} =
             FileStore.replace(cleanup_path, "replacement", generation("original"),
               file_ops: %{
                 temp_path: fn _path -> cleanup_temp end,
                 rename: fn _source, _destination -> {:error, :eio} end,
                 remove: fn ^cleanup_temp -> {:error, :eio} end
               }
             )

    assert File.exists?(cleanup_temp)
    token_failure_path = Path.join(tmp_dir, "token-failure")
    token_failure_lock = token_failure_path <> ".lock"

    mkdir_unwritable_lock = fn ^token_failure_lock ->
      :ok = File.mkdir(token_failure_lock)
      :ok = File.chmod(token_failure_lock, 0o500)
    end

    assert {:error, :lock_failed} =
             FileStore.with_lock(token_failure_path, fn -> :ok end, file_ops: %{mkdir: mkdir_unwritable_lock})

    if File.exists?(token_failure_lock) do
      File.chmod!(token_failure_lock, 0o700)
      File.rmdir!(token_failure_lock)
    end
  end

  @tag :tmp_dir
  test "covers lock identity and default token creation failures", %{tmp_dir: tmp_dir} do
    initial_path = Path.join(tmp_dir, "initial-stat-error")
    initial_lock = initial_path <> ".lock"
    replaced_path = Path.join(tmp_dir, "default-token-replaced-after-write")
    replaced_lock = replaced_path <> ".lock"
    token_path_key = {__MODULE__, make_ref()}
    parent = self()

    tracked_open = fn token_path, modes ->
      Process.put(token_path_key, token_path)
      :file.open(token_path, modes)
    end

    replace_after_write = fn device, token ->
      :ok = :file.write(device, token)
      token_path = Process.get(token_path_key)
      owned_stat = File.lstat!(token_path)
      File.rm!(token_path)
      File.write!(token_path, token)
      File.chmod!(token_path, 0o600)
      replacement_stat = File.lstat!(token_path)
      send(parent, {:default_token_replaced, token_path, token, owned_stat, replacement_stat})
      :ok
    end

    assert {:error, :lock_cleanup_failed} =
             FileStore.with_lock(replaced_path, fn -> send(parent, :replaced_default_body_ran) end,
               file_ops: %{
                 lock_token_open: tracked_open,
                 lock_token_write: replace_after_write
               }
             )

    refute_receive :replaced_default_body_ran

    assert_receive {:default_token_replaced, replaced_token_path, token, owned_stat, replacement_stat}

    refute {owned_stat.inode, owned_stat.major_device, owned_stat.minor_device} ==
             {replacement_stat.inode, replacement_stat.major_device, replacement_stat.minor_device}

    assert File.read!(replaced_token_path) == token
    assert File.exists?(replaced_lock)
    File.rm_rf!(replaced_lock)

    initial_lstat = fn
      ^initial_lock -> {:error, :eio}
      path -> File.lstat(path)
    end

    assert {:error, :lock_failed} =
             FileStore.with_lock(initial_path, fn -> flunk("initial stat failure ran body") end, file_ops: %{lstat: initial_lstat})

    File.rmdir!(initial_lock)

    for outcome <- [:changed, :unavailable] do
      path = Path.join(tmp_dir, "current-lock-#{outcome}")
      lock_path = path <> ".lock"
      count_key = {__MODULE__, make_ref()}

      lstat = fn stat_path ->
        if stat_path == lock_path do
          count = Process.get(count_key, 0)
          Process.put(count_key, count + 1)

          case {count, outcome} do
            {1, :changed} ->
              %File.Stat{} = stat = File.lstat!(stat_path)
              {:ok, %File.Stat{stat | inode: stat.inode + 1}}

            {1, :unavailable} ->
              {:error, :eio}

            _other ->
              File.lstat(stat_path)
          end
        else
          File.lstat(stat_path)
        end
      end

      assert {:error, :lock_failed} =
               FileStore.with_lock(path, fn -> flunk("#{outcome} lock ran body") end, file_ops: %{lstat: lstat})

      refute File.exists?(lock_path)
    end

    created_path = Path.join(tmp_dir, "explicit-created-open")
    created_lock = created_path <> ".lock"

    created_open = fn token_path, modes ->
      {:ok, device} = :file.open(token_path, modes)
      :ok = :file.close(device)
      {:error, :eio, {:created, File.lstat!(token_path)}}
    end

    assert {:error, :lock_failed} =
             FileStore.with_lock(created_path, fn -> flunk("created open ran body") end, file_ops: %{lock_token_open: created_open})

    refute File.exists?(created_lock)

    fstat_path = Path.join(tmp_dir, "token-fstat-error")

    assert {:error, :lock_cleanup_failed} =
             FileStore.with_lock(fstat_path, fn -> flunk("fstat failure ran body") end,
               file_ops: %{
                 lock_token_fstat: fn _device -> {:error, :eio} end
               }
             )

    assert File.exists?(fstat_path <> ".lock")
    File.rm_rf!(fstat_path <> ".lock")

    capture_path = Path.join(tmp_dir, "token-capture-error")
    capture_lock = capture_path <> ".lock"
    token_lstat_key = {__MODULE__, make_ref()}

    capture_lstat = fn stat_path ->
      if String.starts_with?(Path.basename(stat_path), ".owner-") do
        count = Process.get(token_lstat_key, 0)
        Process.put(token_lstat_key, count + 1)
        if count == 0, do: {:error, :eio}, else: File.lstat(stat_path)
      else
        File.lstat(stat_path)
      end
    end

    assert {:error, :lock_cleanup_failed} =
             FileStore.with_lock(capture_path, fn -> flunk("capture failure ran body") end, file_ops: %{lstat: capture_lstat})

    File.rm_rf!(capture_lock)

    verify_path = Path.join(tmp_dir, "token-verify-open-error")

    verify_open = fn token_path, modes ->
      if :read in modes, do: {:error, :eio}, else: :file.open(token_path, modes)
    end

    assert {:error, :lock_failed} =
             FileStore.with_lock(verify_path, fn -> flunk("verify open failure ran body") end, file_ops: %{lock_token_open: verify_open})

    refute File.exists?(verify_path <> ".lock")

    private_path = Path.join(tmp_dir, "default-token-mode")

    assert {:error, :lock_failed} =
             FileStore.with_lock(private_path, fn -> flunk("permissive default token ran body") end,
               file_ops: %{
                 lock_token_chmod: fn _path, _mode -> :ok end
               }
             )

    refute File.exists?(private_path <> ".lock")
  end

  @tag :tmp_dir
  test "covers override token ownership and cleanup outcomes", %{tmp_dir: tmp_dir} do
    descriptor_path = Path.join(tmp_dir, "descriptor-token-replaced")
    descriptor_lock = descriptor_path <> ".lock"
    descriptor_parent = self()

    replace_before_capture = fn token_path, modes ->
      {:ok, device} = :file.open(token_path, modes)
      owned_stat = File.lstat!(token_path)
      foreign_token_path = token_path <> ".foreign"
      File.write!(foreign_token_path, "replacement token")
      File.chmod!(foreign_token_path, 0o600)
      assert File.exists?(token_path)
      assert File.exists?(foreign_token_path)
      File.rename!(foreign_token_path, token_path)
      replacement_stat = File.lstat!(token_path)
      send(descriptor_parent, {:descriptor_token_replaced, token_path, owned_stat, replacement_stat})
      {:ok, device}
    end

    descriptor_body = fn -> send(descriptor_parent, :descriptor_body_ran) end

    assert {:error, :lock_cleanup_failed} =
             FileStore.with_lock(descriptor_path, descriptor_body, file_ops: %{lock_token_open: replace_before_capture})

    refute_receive :descriptor_body_ran

    assert_receive {:descriptor_token_replaced, descriptor_token, descriptor_a, descriptor_b}

    refute {descriptor_a.inode, descriptor_a.major_device, descriptor_a.minor_device} ==
             {descriptor_b.inode, descriptor_b.major_device, descriptor_b.minor_device}

    assert File.read!(descriptor_token) == "replacement token"
    assert File.exists?(descriptor_lock)
    File.rm_rf!(descriptor_lock)

    bare_error_path = Path.join(tmp_dir, "override-bare-error-replaced")
    bare_error_lock = bare_error_path <> ".lock"

    replace_before_bare_error = fn token_path, token ->
      File.write!(token_path, token, [:write, :binary, :exclusive])
      owned_stat = File.lstat!(token_path)
      foreign_token_path = token_path <> ".foreign"
      File.write!(foreign_token_path, token)
      File.chmod!(foreign_token_path, 0o600)
      assert File.exists?(token_path)
      assert File.exists?(foreign_token_path)
      File.rename!(foreign_token_path, token_path)
      replacement_stat = File.lstat!(token_path)
      send(descriptor_parent, {:override_token_replaced, token_path, token, owned_stat, replacement_stat})
      {:error, :eio}
    end

    bare_error_body = fn -> send(descriptor_parent, :bare_error_body_ran) end

    bare_error_ops = %{lock_token_create: replace_before_bare_error}

    assert {:error, :lock_cleanup_failed} =
             FileStore.with_lock(bare_error_path, bare_error_body, file_ops: bare_error_ops)

    refute_receive :bare_error_body_ran

    assert_receive {:override_token_replaced, bare_error_token_path, bare_error_token, bare_error_a, bare_error_b}

    refute {bare_error_a.inode, bare_error_a.major_device, bare_error_a.minor_device} ==
             {bare_error_b.inode, bare_error_b.major_device, bare_error_b.minor_device}

    assert File.read!(bare_error_token_path) == bare_error_token
    assert File.exists?(bare_error_lock)
    File.rm_rf!(bare_error_lock)

    malformed_path = Path.join(tmp_dir, "override-malformed-identity")
    malformed_lock = malformed_path <> ".lock"

    malformed_create = fn token_path, token ->
      File.write!(token_path, token, [:write, :binary, :exclusive])
      File.chmod!(token_path, 0o600)
      {:error, :eio, {:created, %{path: token_path}}}
    end

    malformed_body = fn -> send(descriptor_parent, :malformed_body_ran) end

    assert {:error, :lock_cleanup_failed} =
             FileStore.with_lock(malformed_path, malformed_body, file_ops: %{lock_token_create: malformed_create})

    refute_receive :malformed_body_ran
    assert File.exists?(malformed_lock)
    File.rm_rf!(malformed_lock)
    created_path = Path.join(tmp_dir, "override-created")

    created = fn token_path, token ->
      File.write!(token_path, token, [:write, :binary, :exclusive])
      File.chmod!(token_path, 0o600)
      {:error, :eio, {:created, File.lstat!(token_path)}}
    end

    assert {:error, :lock_failed} =
             FileStore.with_lock(created_path, fn -> flunk("created override ran body") end, file_ops: %{lock_token_create: created})

    refute File.exists?(created_path <> ".lock")

    claimed_path = Path.join(tmp_dir, "override-created-claimed")

    claimed = fn token_path, token ->
      File.write!(token_path, token, [:write, :binary, :exclusive])
      {:error, :eio, {:created, File.lstat!(token_path)}}
    end

    assert {:error, :lock_failed} =
             FileStore.with_lock(claimed_path, fn -> flunk("claimed override ran body") end,
               file_ops: %{
                 lock_token_create: claimed,
                 lock_token_open: fn _path, _modes -> {:error, :eio} end
               }
             )

    refute File.exists?(claimed_path <> ".lock")

    absent_path = Path.join(tmp_dir, "override-created-absent")

    assert {:error, :lock_failed} =
             FileStore.with_lock(absent_path, fn -> flunk("absent override ran body") end,
               file_ops: %{
                 lock_token_create: fn _path, _token -> {:error, :eio, :created} end
               }
             )

    refute File.exists?(absent_path <> ".lock")

    unreadable_path = Path.join(tmp_dir, "override-unreadable")
    unreadable_lock = unreadable_path <> ".lock"
    token_path_key = {__MODULE__, make_ref()}

    unreadable_create = fn token_path, token ->
      Process.put(token_path_key, token_path)
      File.write!(token_path, token, [:write, :binary, :exclusive])
      File.chmod!(token_path, 0o600)
      :ok
    end

    unreadable_open = fn _path, _modes -> {:ok, :invalid_token_device} end

    unreadable_fstat = fn :invalid_token_device ->
      :file.read_file_info(Process.get(token_path_key))
    end

    assert {:error, :lock_cleanup_failed} =
             FileStore.with_lock(unreadable_path, fn -> flunk("unreadable override ran body") end,
               file_ops: %{
                 lock_token_close: fn :invalid_token_device -> :ok end,
                 lock_token_create: unreadable_create,
                 lock_token_fstat: unreadable_fstat,
                 lock_token_open: unreadable_open
               }
             )

    File.rm_rf!(unreadable_lock)
  end

  @tag :tmp_dir
  test "covers owned token cleanup and failed rename observations", %{tmp_dir: tmp_dir} do
    vanished_path = Path.join(tmp_dir, "vanished-token")
    token_path_key = {__MODULE__, make_ref()}

    vanished_open = fn token_path, modes ->
      Process.put(token_path_key, token_path)
      :file.open(token_path, modes)
    end

    vanished_close = fn device ->
      :ok = :file.close(device)
      File.rm!(Process.get(token_path_key))
      {:error, :eio}
    end

    assert {:error, :lock_failed} =
             FileStore.with_lock(vanished_path, fn -> flunk("vanished token ran body") end,
               file_ops: %{
                 lock_token_close: vanished_close,
                 lock_token_open: vanished_open
               }
             )

    refute File.exists?(vanished_path <> ".lock")

    remove_path = Path.join(tmp_dir, "token-remove-error")
    remove_lock = remove_path <> ".lock"

    permissive = fn token_path, token ->
      File.write!(token_path, token, [:write, :binary, :exclusive])
      File.chmod!(token_path, 0o644)
      :ok
    end

    assert {:error, :lock_cleanup_failed} =
             FileStore.with_lock(remove_path, fn -> flunk("remove error ran body") end,
               file_ops: %{
                 lock_token_create: permissive,
                 lock_token_remove: fn _path -> {:error, :eio} end
               }
             )

    File.rm_rf!(remove_lock)
    token_stat_path = Path.join(tmp_dir, "cleanup-token-stat-error")
    token_stat_lock = token_stat_path <> ".lock"
    token_lstat_key = {__MODULE__, make_ref()}

    token_cleanup_lstat = fn stat_path ->
      if String.starts_with?(Path.basename(stat_path), ".owner-") do
        count = Process.get(token_lstat_key, 0)
        Process.put(token_lstat_key, count + 1)
        if count == 2, do: {:error, :eio}, else: File.lstat(stat_path)
      else
        File.lstat(stat_path)
      end
    end

    assert {:error, :lock_cleanup_failed} =
             FileStore.with_lock(token_stat_path, fn -> flunk("token stat cleanup ran body") end,
               file_ops: %{
                 lock_token_create: permissive,
                 lstat: token_cleanup_lstat
               }
             )

    File.rm_rf!(token_stat_lock)

    lock_stat_path = Path.join(tmp_dir, "cleanup-lock-stat-error")
    lock_stat_lock = lock_stat_path <> ".lock"
    lock_lstat_key = {__MODULE__, make_ref()}

    cleanup_lstat = fn stat_path ->
      if stat_path == lock_stat_lock do
        count = Process.get(lock_lstat_key, 0)
        Process.put(lock_lstat_key, count + 1)
        if count == 1, do: {:error, :eio}, else: File.lstat(stat_path)
      else
        File.lstat(stat_path)
      end
    end

    assert {:error, :lock_cleanup_failed} =
             FileStore.with_lock(lock_stat_path, fn -> flunk("lock stat cleanup ran body") end,
               file_ops: %{
                 lock_token_create: permissive,
                 lstat: cleanup_lstat
               }
             )

    File.rm_rf!(lock_stat_lock)

    malformed_temp = Path.join(tmp_dir, ".malformed-owned-temp")
    File.write!(malformed_temp, "owned")

    assert {:error, :identity_changed} =
             FileStore.remove_temp(%FileStore.TempOwnership{
               path: malformed_temp,
               stat: %{}
             })

    File.rm!(malformed_temp)

    for observed <- [:different, :unavailable] do
      case_dir = Path.join(tmp_dir, "rename-observed-#{observed}")
      File.mkdir!(case_dir)
      path = Path.join(case_dir, "targets.yml")
      original = "original"
      replacement = "replacement"
      File.write!(path, original)
      read_key = {__MODULE__, make_ref()}

      read = fn read_path ->
        count = Process.get(read_key, 0)
        Process.put(read_key, count + 1)

        case {count, observed} do
          {2, :different} -> {:ok, "different observation"}
          {2, :unavailable} -> {:error, :eio}
          _other -> File.read(read_path)
        end
      end

      rename = fn source, ^path ->
        :ok = File.rename(source, path)
        {:error, :eio}
      end

      assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
               FileStore.replace(path, replacement, generation(original), file_ops: %{read: read, rename: rename})

      expected_observed =
        if observed == :different,
          do: generation("different observation"),
          else: "unavailable"

      assert message =~ "observed_generation=#{expected_observed}"
      assert File.read!(path) == replacement
    end
  end

  defp collect_events(count) do
    Enum.map(1..count, fn _index ->
      receive do
        event -> event
      after
        100 -> :missing_event
      end
    end)
  end

  defp generation(bytes) do
    "sha256:" <> (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))
  end
end

defmodule SymphonyElixir.OperatorCommandService.PlanStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OperatorCommandService.PlanStore
  alias SymphonyElixir.TargetRegistry.Error

  test "builds a deterministic plan ID from canonical command, registry, and source bindings" do
    proposed_registry_bytes = "version: 1\ntargets:\n  main:\n    state: paused\n"
    fields = plan_fields()

    assert {:ok, first} = PlanStore.build(fields, proposed_registry_bytes)
    assert {:ok, second} = PlanStore.build(fields, proposed_registry_bytes)
    assert first == second
    assert first["plan_id"] =~ ~r/^[0-9a-f]{64}$/
    assert first["proposed_generation"] == generation(proposed_registry_bytes)

    assert {:ok, different_time} =
             PlanStore.build(
               Map.put(fields, "created_at", "2026-08-16T12:35:56.000000Z"),
               proposed_registry_bytes
             )

    assert different_time["plan_id"] == first["plan_id"]
  end

  @tag :tmp_dir
  test "stores immutable mode 0600 JSON and consumes only a verified envelope", %{tmp_dir: tmp_dir} do
    plan_dir = Path.join(tmp_dir, "plans")
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    plan_id = envelope["plan_id"]
    plan_path = Path.join(plan_dir, plan_id <> ".json")

    assert {:ok, ^envelope} = PlanStore.store(plan_dir, envelope)
    assert Jason.decode!(File.read!(plan_path)) == envelope
    assert Bitwise.band(File.stat!(plan_path).mode, 0o777) == 0o600
    assert File.ls!(plan_dir) == [plan_id <> ".json"]

    assert {:ok, ^envelope} = PlanStore.read(plan_dir, plan_id)
    assert {:ok, ^envelope} = PlanStore.read(plan_dir, plan_id)
    assert File.exists?(plan_path)

    assert {:ok, ^envelope} = PlanStore.consume(plan_dir, plan_id)
    refute File.exists?(plan_path)
    assert {:error, %Error{code: :plan_not_found}} = PlanStore.read(plan_dir, plan_id)
  end

  @tag :tmp_dir
  test "reads only stable private regular plan objects and never deletes corrupt paths", %{tmp_dir: tmp_dir} do
    plan_dir = Path.join(tmp_dir, "plans")
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    plan_id = envelope["plan_id"]
    plan_path = Path.join(plan_dir, plan_id <> ".json")
    assert {:ok, ^envelope} = PlanStore.store(plan_dir, envelope)
    plan_bytes = File.read!(plan_path)

    File.chmod!(plan_path, 0o644)
    assert {:error, %Error{code: :plan_corrupt}} = PlanStore.read(plan_dir, plan_id)
    assert File.read!(plan_path) == plan_bytes
    File.chmod!(plan_path, 0o600)

    target_path = Path.join(tmp_dir, "symlink-target.json")
    File.rename!(plan_path, target_path)
    File.ln_s!(target_path, plan_path)
    assert {:error, %Error{code: :plan_corrupt}} = PlanStore.read(plan_dir, plan_id)
    assert {:error, %Error{code: :plan_corrupt}} = PlanStore.consume(plan_dir, plan_id)
    assert File.lstat!(plan_path).type == :symlink
    assert File.read!(target_path) == plan_bytes

    File.rm!(plan_path)
    File.rename!(target_path, plan_path)
    replacement_path = plan_path <> ".replacement"
    parent = self()

    read =
      Task.async(fn ->
        PlanStore.read(plan_dir, plan_id,
          before_open: fn ->
            send(parent, {:plan_lstat_complete, self()})

            receive do
              :continue_plan_read -> :ok
            end
          end
        )
      end)

    assert_receive {:plan_lstat_complete, read_pid}
    File.write!(replacement_path, plan_bytes)
    File.chmod!(replacement_path, 0o600)
    assert File.exists?(plan_path)
    assert File.exists?(replacement_path)
    File.rename!(replacement_path, plan_path)
    send(read_pid, :continue_plan_read)

    assert {:error, %Error{code: :plan_corrupt}} = Task.await(read)
    assert File.read!(plan_path) == plan_bytes
  end

  test "canonicalizes source-hash and command key order while binding every identity field" do
    fields = plan_fields()

    reordered =
      fields
      |> Map.put(
        "command",
        Enum.into(Enum.reverse(Enum.to_list(fields["command"])), %{})
      )
      |> Map.put(
        "source_hashes",
        Enum.into(Enum.reverse(Enum.to_list(fields["source_hashes"])), %{})
      )

    assert {:ok, original} = PlanStore.build(fields, "proposed registry")
    assert {:ok, same_identity} = PlanStore.build(reordered, "proposed registry")
    assert same_identity["plan_id"] == original["plan_id"]

    changes = [
      {["command", "display_name"], "Other"},
      {["registry_path"], "/tmp/other/targets.yml"},
      {["expected_generation"], generation("other original")},
      {["source_hashes", "/tmp/import.yml"], generation("other source")}
    ]

    Enum.each(changes, fn {path, value} ->
      changed_fields = put_in_path(fields, path, value)
      assert {:ok, changed} = PlanStore.build(changed_fields, "proposed registry")
      refute changed["plan_id"] == original["plan_id"]
    end)

    assert {:ok, changed_bytes} = PlanStore.build(fields, "other proposed registry")
    refute changed_bytes["plan_id"] == original["plan_id"]
  end

  @tag :tmp_dir
  test "writes deterministic bytes and permits only byte-identical idempotent stores", %{tmp_dir: tmp_dir} do
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    first_dir = Path.join(tmp_dir, "first")
    second_dir = Path.join(tmp_dir, "second")
    filename = envelope["plan_id"] <> ".json"

    assert {:ok, ^envelope} = PlanStore.store(first_dir, envelope)
    first_bytes = File.read!(Path.join(first_dir, filename))
    assert {:ok, ^envelope} = PlanStore.store(first_dir, envelope)
    assert File.read!(Path.join(first_dir, filename)) == first_bytes

    assert {:ok, ^envelope} = PlanStore.store(second_dir, envelope)
    assert File.read!(Path.join(second_dir, filename)) == first_bytes

    different_creation_time =
      Map.put(envelope, "created_at", "2026-08-16T12:35:56.000000Z")

    assert different_creation_time["plan_id"] == envelope["plan_id"]

    assert {:error, %Error{code: :plan_corrupt}} =
             PlanStore.store(first_dir, different_creation_time)

    assert File.read!(Path.join(first_dir, filename)) == first_bytes
  end

  @tag :tmp_dir
  test "never overwrites a destination created after the synced temp opens", %{tmp_dir: tmp_dir} do
    plan_dir = Path.join(tmp_dir, "plans")
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    plan_path = Path.join(plan_dir, envelope["plan_id"] <> ".json")
    foreign_bytes = "foreign destination"
    parent = self()

    store =
      Task.async(fn ->
        PlanStore.store(plan_dir, envelope,
          file_ops: %{
            open: fn temp_path, modes ->
              {:ok, device} = :file.open(temp_path, modes)
              send(parent, {:plan_temp_opened, self()})

              receive do
                :continue_plan_store -> {:ok, device}
              end
            end
          }
        )
      end)

    assert_receive {:plan_temp_opened, store_pid}
    File.write!(plan_path, foreign_bytes)
    File.chmod!(plan_path, 0o600)
    send(store_pid, :continue_plan_store)

    assert {:error, %Error{code: :plan_corrupt}} = Task.await(store)
    assert File.read!(plan_path) == foreign_bytes
  end

  @tag :tmp_dir
  test "claims plan temps only from successful or explicit partial exclusive creation", %{tmp_dir: tmp_dir} do
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")

    generic_dir = Path.join(tmp_dir, "generic")
    generic_temp = Path.join(generic_dir, ".plan.generic-error")

    generic_open = fn ^generic_temp, _modes ->
      File.write!(generic_temp, "foreign temp")
      {:error, :eio}
    end

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(generic_dir, envelope,
               file_ops: %{
                 temp_path: fn _path -> generic_temp end,
                 open: generic_open
               }
             )

    assert File.read!(generic_temp) == "foreign temp"

    partial_dir = Path.join(tmp_dir, "partial")
    partial_temp = Path.join(partial_dir, ".plan.partial-created")

    partial_open = fn ^partial_temp, modes ->
      {:ok, device} = :file.open(partial_temp, modes)
      :ok = :file.close(device)
      {:error, :eio, {:created, File.lstat!(partial_temp)}}
    end

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(partial_dir, envelope,
               file_ops: %{
                 temp_path: fn _path -> partial_temp end,
                 open: partial_open
               }
             )

    refute File.exists?(partial_temp)
  end

  @tag :tmp_dir
  test "preserves plan temp pathname reuse after link publication", %{tmp_dir: tmp_dir} do
    plan_dir = Path.join(tmp_dir, "plans")
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    plan_path = Path.join(plan_dir, envelope["plan_id"] <> ".json")
    temp_path = Path.join(plan_dir, ".plan.reused-after-link")
    parent = self()

    store =
      Task.async(fn ->
        PlanStore.store(plan_dir, envelope,
          file_ops: %{
            temp_path: fn _path -> temp_path end,
            link: fn ^temp_path, ^plan_path ->
              :ok = File.ln(temp_path, plan_path)
              send(parent, {:plan_linked, self()})

              receive do
                :continue_link_cleanup -> :ok
              end
            end
          }
        )
      end)

    assert_receive {:plan_linked, store_pid}
    File.rm!(temp_path)
    File.write!(temp_path, "foreign reuse")
    send(store_pid, :continue_link_cleanup)

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} = Task.await(store)
    committed_generation = generation(File.read!(plan_path))
    assert message =~ "expected_generation=#{committed_generation}"
    assert message =~ "observed_generation=#{committed_generation}"
    assert File.read!(temp_path) == "foreign reuse"
  end

  @tag :tmp_dir
  test "surfaces plan temp cleanup failure and closes once across operation exceptions", %{tmp_dir: tmp_dir} do
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    cleanup_dir = Path.join(tmp_dir, "cleanup")
    cleanup_path = Path.join(cleanup_dir, ".plan.cleanup-failure")

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             PlanStore.store(cleanup_dir, envelope,
               file_ops: %{
                 temp_path: fn _path -> cleanup_path end,
                 remove: fn ^cleanup_path -> {:error, :eio} end
               }
             )

    plan_path = Path.join(cleanup_dir, envelope["plan_id"] <> ".json")
    committed_generation = generation(File.read!(plan_path))
    assert message =~ "expected_generation=#{committed_generation}"
    assert message =~ "observed_generation=#{committed_generation}"
    assert File.exists?(cleanup_path)

    failures = [
      fn _device, _bytes -> raise "opaque write failure" end,
      fn _device, _bytes -> throw(:opaque_write_failure) end,
      fn _device, _bytes -> exit(:opaque_write_failure) end
    ]

    Enum.with_index(failures, fn write, index ->
      case_dir = Path.join(tmp_dir, "exception-#{index}")
      parent = self()

      assert {:error, %Error{code: :atomic_replace_failed}} =
               PlanStore.store(case_dir, envelope,
                 file_ops: %{
                   write: write,
                   close: fn device ->
                     send(parent, {:plan_temp_closed, index})
                     :file.close(device)
                   end
                 }
               )

      assert_receive {:plan_temp_closed, ^index}
      refute_receive {:plan_temp_closed, ^index}
      assert File.ls!(case_dir) == []
    end)
  end

  @tag :tmp_dir
  test "rejects duplicate, unknown, tampered, truncated, and invalid UTF-8 envelopes without deletion", %{
    tmp_dir: tmp_dir
  } do
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    plan_id = envelope["plan_id"]
    plan_dir = Path.join(tmp_dir, "plans")
    plan_path = Path.join(plan_dir, plan_id <> ".json")
    assert {:ok, ^envelope} = PlanStore.store(plan_dir, envelope)
    valid_bytes = File.read!(plan_path)

    duplicate =
      String.replace(
        valid_bytes,
        ~s({"envelope_version":1),
        ~s({"envelope_version":1,"envelope_version":1),
        global: false
      )

    unknown_secret = String.replace_suffix(valid_bytes, "}", ~s(,"api_key":"do-not-leak"}))
    tampered = envelope |> put_in(["command", "display_name"], "Tampered") |> Jason.encode!()

    deep_json = envelope |> Map.put("command", nested_value(18)) |> Jason.encode!()

    wide_json =
      envelope
      |> Map.put("command", Map.new(1..257, fn index -> {"field_#{index}", index} end))
      |> Jason.encode!()

    node_heavy_json =
      envelope
      |> Map.put(
        "command",
        %{"batches" => Enum.map(1..256, fn _index -> List.duplicate(0, 16) end)}
      )
      |> Jason.encode!()

    wide_list_json =
      envelope
      |> Map.put("command", %{"items" => List.duplicate(0, 257)})
      |> Jason.encode!()

    corruptions = [
      duplicate,
      unknown_secret,
      tampered,
      binary_part(valid_bytes, 0, byte_size(valid_bytes) - 1),
      <<valid_bytes::binary, 0xFF>>,
      deep_json,
      wide_json,
      wide_list_json,
      node_heavy_json
    ]

    Enum.each(corruptions, fn corrupt_bytes ->
      File.write!(plan_path, corrupt_bytes)

      assert {:error, %Error{code: :plan_corrupt, message: message}} =
               PlanStore.consume(plan_dir, plan_id)

      refute message =~ "do-not-leak"
      assert File.read!(plan_path) == corrupt_bytes
    end)

    File.write!(plan_path, String.duplicate(" ", 1_048_577))
    assert {:error, %Error{code: :plan_corrupt}} = PlanStore.read(plan_dir, plan_id)
    assert File.exists?(plan_path)
  end

  @tag :tmp_dir
  test "rejects traversal IDs and invalid or secret-bearing bounded envelope values", %{tmp_dir: tmp_dir} do
    plan_dir = Path.join(tmp_dir, "plans")
    File.mkdir_p!(plan_dir)
    sentinel = Path.join(tmp_dir, "sentinel.json")
    File.write!(sentinel, "outside")

    for plan_id <- ["../sentinel", "..", "A" <> String.duplicate("a", 63), String.duplicate("a", 65)] do
      assert {:error, %Error{code: :plan_corrupt}} = PlanStore.read(plan_dir, plan_id)
      assert {:error, %Error{code: :plan_corrupt}} = PlanStore.consume(plan_dir, plan_id)
    end

    assert File.read!(sentinel) == "outside"

    invalid_fields = [
      :not_a_map,
      Map.put(plan_fields(), "unknown", "value"),
      Map.put(plan_fields(), :action, "add"),
      plan_fields() |> Map.delete("action") |> Map.put("planAction", "add"),
      Map.put(plan_fields(), "action", "unknown"),
      Map.put(plan_fields(), "target_id", "../main"),
      Map.put(plan_fields(), "registry_path", "relative/targets.yml"),
      Map.put(plan_fields(), "expected_generation", String.duplicate("a", 64)),
      Map.put(plan_fields(), "source_hashes", []),
      Map.put(plan_fields(), "created_at", 42),
      Map.put(plan_fields(), "created_at", "2026-08-16T12:34:56+01:00"),
      put_in(plan_fields(), ["command", "api_key"], "do-not-store"),
      put_in(plan_fields(), ["command", "env"], %{"TOKEN" => "do-not-store"}),
      put_in(plan_fields(), ["command", "prompt"], "do-not-store"),
      put_in(plan_fields(), ["command", "invalid_utf8"], <<0xFF>>),
      put_in(plan_fields(), ["command", "improper"], [1 | 2]),
      Map.put(plan_fields(), "command", nested_value(18)),
      Map.put(
        plan_fields(),
        "command",
        %{"batches" => Enum.map(1..256, fn _index -> List.duplicate(0, 16) end)}
      ),
      Map.put(
        plan_fields(),
        "command",
        Map.new(1..257, fn index -> {"field_#{index}", index} end)
      )
    ]

    invalid_fields =
      case non_finite_float() do
        {:ok, value} -> [put_in(plan_fields(), ["command", "nonfinite"], value) | invalid_fields]
        :unsupported -> invalid_fields
      end

    Enum.each(invalid_fields, fn
      :not_a_map ->
        assert {:error, %Error{code: :plan_corrupt}} =
                 PlanStore.build(:not_a_map, "proposed registry")

      fields ->
        assert {:error, %Error{code: :plan_corrupt, message: "plan envelope is corrupt"}} =
                 PlanStore.build(fields, "proposed registry")
    end)

    assert {:error, %Error{code: :plan_corrupt}} =
             PlanStore.build(plan_fields(), :not_binary)
  end

  @tag :tmp_dir
  test "rejects normalized secret key families at every command depth", %{tmp_dir: tmp_dir} do
    plan_dir = Path.join(tmp_dir, "plans")

    secret_keys = [
      "authorization",
      "bearer-token",
      "privateKey",
      "connection_string",
      "access-token",
      "clientSecret",
      "serviceCredential",
      "database-password",
      "signing_secret",
      "refreshToken",
      "external-api-key"
    ]

    Enum.each(secret_keys, fn key ->
      cleartext = "cleartext-for-#{key}"

      fields =
        put_in(plan_fields(), ["command", "outer"], %{"items" => [%{key => cleartext}]})

      assert {:error, %Error{code: :plan_corrupt}} =
               PlanStore.build(fields, "proposed registry")

      refute File.exists?(plan_dir)
    end)
  end

  @tag :tmp_dir
  test "consume holds the plan lock and never deletes or returns a replaced object", %{tmp_dir: tmp_dir} do
    plan_dir = Path.join(tmp_dir, "plans")
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    plan_id = envelope["plan_id"]
    plan_path = Path.join(plan_dir, plan_id <> ".json")
    assert {:ok, ^envelope} = PlanStore.store(plan_dir, envelope)
    parent = self()

    consume =
      Task.async(fn ->
        PlanStore.consume(plan_dir, plan_id,
          before_remove: fn ->
            send(parent, :consume_ready)

            receive do
              :continue_consume -> :ok
            end
          end
        )
      end)

    assert_receive :consume_ready

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(plan_dir, envelope)

    replacement = Map.put(envelope, "created_at", "2026-08-16T12:35:56.000000Z")
    replacement_bytes = Jason.encode!(replacement)
    File.rm!(plan_path)
    File.write!(plan_path, replacement_bytes)
    File.chmod!(plan_path, 0o600)
    send(consume.pid, :continue_consume)

    assert {:error, %Error{code: code}} = Task.await(consume)
    assert code in [:plan_corrupt, :atomic_replace_failed]
    assert File.read!(plan_path) == replacement_bytes
  end

  @tag :tmp_dir
  test "preserves a replacement plan lock and reports the committed envelope generation", %{
    tmp_dir: tmp_dir
  } do
    plan_dir = Path.join(tmp_dir, "plans")
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    plan_path = Path.join(plan_dir, envelope["plan_id"] <> ".json")
    lock_path = plan_path <> ".lock"

    replace_lock = fn ->
      Enum.each(File.ls!(lock_path), fn entry -> File.rm!(Path.join(lock_path, entry)) end)
      File.rmdir!(lock_path)
      File.mkdir!(lock_path)
      File.write!(Path.join(lock_path, "foreign-owner"), "replacement lock")
      :ok
    end

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             PlanStore.store(plan_dir, envelope, file_ops: %{before_lock_release: replace_lock})

    committed_generation = generation(File.read!(plan_path))
    assert message =~ "expected_generation=#{committed_generation}"
    assert message =~ "observed_generation=#{committed_generation}"
    assert File.read!(Path.join(lock_path, "foreign-owner")) == "replacement lock"
  end

  @tag :tmp_dir
  test "surfaces plan lock directory removal failure after publication", %{tmp_dir: tmp_dir} do
    plan_dir = Path.join(tmp_dir, "plans")
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    plan_path = Path.join(plan_dir, envelope["plan_id"] <> ".json")
    lock_path = plan_path <> ".lock"

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             PlanStore.store(plan_dir, envelope, file_ops: %{rmdir: fn ^lock_path -> {:error, :eio} end})

    committed_generation = generation(File.read!(plan_path))
    assert message =~ "expected_generation=#{committed_generation}"
    assert message =~ "observed_generation=#{committed_generation}"
    assert File.dir?(lock_path)
    File.rmdir!(lock_path)
  end

  @tag :tmp_dir
  test "enforces mode 0700 on the final plan directory without rejecting ancestor symlinks", %{
    tmp_dir: tmp_dir
  } do
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")

    created_dir = Path.join(tmp_dir, "created")
    assert {:ok, ^envelope} = PlanStore.store(created_dir, envelope)
    assert File.lstat!(created_dir).type == :directory
    assert Bitwise.band(File.lstat!(created_dir).mode, 0o777) == 0o700

    permissive_dir = Path.join(tmp_dir, "permissive")
    File.mkdir!(permissive_dir)
    File.chmod!(permissive_dir, 0o755)

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(permissive_dir, envelope)

    assert File.ls!(permissive_dir) == []

    symlink_target = Path.join(tmp_dir, "symlink-target")
    symlink_dir = Path.join(tmp_dir, "symlink-plans")
    File.mkdir!(symlink_target)
    File.chmod!(symlink_target, 0o700)
    File.ln_s!(symlink_target, symlink_dir)

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(symlink_dir, envelope)

    assert File.ls!(symlink_target) == []

    regular_path = Path.join(tmp_dir, "regular-file")
    File.write!(regular_path, "not a directory")

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(regular_path, envelope)

    real_parent = Path.join(tmp_dir, "real-parent")
    linked_parent = Path.join(tmp_dir, "linked-parent")
    File.mkdir!(real_parent)
    File.ln_s!(real_parent, linked_parent)
    linked_plan_dir = Path.join(linked_parent, "plans")

    assert {:ok, ^envelope} = PlanStore.store(linked_plan_dir, envelope)
    assert File.lstat!(linked_plan_dir).type == :directory
    assert Bitwise.band(File.lstat!(linked_plan_dir).mode, 0o777) == 0o700
  end

  @tag :tmp_dir
  test "keeps plan read and consume total across missing, locked, and injected failures", %{tmp_dir: tmp_dir} do
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    plan_id = envelope["plan_id"]
    missing_dir = Path.join(tmp_dir, "missing")

    assert {:error, %Error{code: :plan_corrupt}} = PlanStore.read(missing_dir, plan_id)
    assert {:error, %Error{code: :atomic_replace_failed}} = PlanStore.consume(missing_dir, plan_id)

    empty_dir = Path.join(tmp_dir, "empty")
    File.mkdir!(empty_dir)
    File.chmod!(empty_dir, 0o700)
    assert {:error, %Error{code: :plan_not_found}} = PlanStore.consume(empty_dir, plan_id)

    locked_dir = Path.join(tmp_dir, "locked-consume")
    assert {:ok, ^envelope} = PlanStore.store(locked_dir, envelope)
    locked_path = Path.join(locked_dir, plan_id <> ".json")
    File.mkdir!(locked_path <> ".lock")

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.consume(locked_dir, plan_id)

    File.rmdir!(locked_path <> ".lock")

    assert {:error, %Error{code: :plan_corrupt}} =
             PlanStore.read(locked_dir, plan_id, unknown: :option)

    assert {:error, %Error{code: :plan_corrupt}} =
             PlanStore.consume(locked_dir, plan_id, unknown: :option)

    for before_remove <- [fn -> raise "consume hook" end, fn -> throw(:consume_hook) end] do
      assert {:error, %Error{code: :plan_corrupt}} =
               PlanStore.consume(locked_dir, plan_id, before_remove: before_remove)

      assert File.exists?(locked_path)
    end

    assert {:error, %Error{code: :plan_corrupt}} =
             PlanStore.store(Path.join(tmp_dir, "unknown-op"), envelope, file_ops: %{unknown: fn -> :ok end})
  end

  @tag :tmp_dir
  test "covers no-replace publication failure and exact-race outcomes", %{tmp_dir: tmp_dir} do
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")

    link_failures = [
      {"error", fn _source, _destination -> {:error, :eio} end},
      {"raise", fn _source, _destination -> raise "link failure" end},
      {"throw", fn _source, _destination -> throw(:link_failure) end}
    ]

    Enum.each(link_failures, fn {name, link} ->
      plan_dir = Path.join(tmp_dir, "link-#{name}")

      assert {:error, %Error{code: :atomic_replace_failed}} =
               PlanStore.store(plan_dir, envelope, file_ops: %{link: link})

      assert File.ls!(plan_dir) == []
    end)

    cleanup_dir = Path.join(tmp_dir, "link-cleanup")
    cleanup_temp = Path.join(cleanup_dir, ".plan.link-cleanup")

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(cleanup_dir, envelope,
               file_ops: %{
                 temp_path: fn _path -> cleanup_temp end,
                 link: fn _source, _destination -> {:error, :eio} end,
                 remove: fn ^cleanup_temp -> {:error, :eio} end
               }
             )

    assert File.exists?(cleanup_temp)

    sync_dir = Path.join(tmp_dir, "sync-failure")

    assert {:error, %Error{code: :atomic_replace_failed, message: sync_message}} =
             PlanStore.store(sync_dir, envelope, file_ops: %{sync_parent: fn _directory -> {:error, :eio} end})

    assert sync_message =~ "observed_generation="

    baseline_dir = Path.join(tmp_dir, "baseline")
    assert {:ok, ^envelope} = PlanStore.store(baseline_dir, envelope)
    filename = envelope["plan_id"] <> ".json"
    exact_bytes = File.read!(Path.join(baseline_dir, filename))
    race_dir = Path.join(tmp_dir, "exact-race")
    race_path = Path.join(race_dir, filename)
    parent = self()

    store =
      Task.async(fn ->
        PlanStore.store(race_dir, envelope,
          file_ops: %{
            open: fn temp_path, modes ->
              {:ok, device} = :file.open(temp_path, modes)
              send(parent, {:exact_temp_opened, self()})

              receive do
                :continue_exact_store -> {:ok, device}
              end
            end
          }
        )
      end)

    assert_receive {:exact_temp_opened, store_pid}
    File.write!(race_path, exact_bytes)

    File.chmod!(race_path, 0o600)
    send(store_pid, :continue_exact_store)
    assert {:ok, ^envelope} = Task.await(store)
    assert File.read!(race_path) == exact_bytes
    failed_existing_dir = Path.join(tmp_dir, "exact-race-cleanup")
    failed_existing_path = Path.join(failed_existing_dir, filename)
    failed_existing_temp = Path.join(failed_existing_dir, ".plan.exact-cleanup")

    create_exact_destination = fn _temp_path, ^failed_existing_path ->
      File.write!(failed_existing_path, exact_bytes)
      File.chmod!(failed_existing_path, 0o600)
      {:error, :eexist}
    end

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(failed_existing_dir, envelope,
               file_ops: %{
                 temp_path: fn _path -> failed_existing_temp end,
                 link: create_exact_destination,
                 remove: fn ^failed_existing_temp -> {:error, :eio} end
               }
             )

    assert File.read!(failed_existing_path) == exact_bytes
    assert File.exists?(failed_existing_temp)
  end

  @tag :tmp_dir
  test "covers causal plan directory races and unavailable committed observations", %{tmp_dir: tmp_dir} do
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    raced_dir = Path.join(tmp_dir, "raced-dir")

    create_raced_dir = fn ->
      File.mkdir!(raced_dir)
      File.chmod!(raced_dir, 0o700)
      :ok
    end

    assert {:ok, ^envelope} =
             PlanStore.store(raced_dir, envelope, file_ops: %{before_plan_dir_create: create_raced_dir})

    failed_dir = Path.join(tmp_dir, "failed-dir")

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(failed_dir, envelope, file_ops: %{before_plan_dir_create: fn -> {:error, :eio} end})

    refute File.exists?(failed_dir)

    unavailable_dir = Path.join(tmp_dir, "unavailable-commit")
    plan_path = Path.join(unavailable_dir, envelope["plan_id"] <> ".json")
    lock_path = plan_path <> ".lock"

    remove_published_plan_and_replace_lock = fn ->
      File.rm!(plan_path)
      Enum.each(File.ls!(lock_path), fn entry -> File.rm!(Path.join(lock_path, entry)) end)
      File.rmdir!(lock_path)
      File.mkdir!(lock_path)
      File.write!(Path.join(lock_path, "foreign-owner"), "replacement lock")
      :ok
    end

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             PlanStore.store(unavailable_dir, envelope,
               file_ops: %{
                 before_lock_release: remove_published_plan_and_replace_lock
               }
             )

    assert message =~ "observed_generation=unavailable"
    assert File.read!(Path.join(lock_path, "foreign-owner")) == "replacement lock"
  end

  @tag :tmp_dir
  test "reports plan filesystem failures without overwriting or consuming state", %{tmp_dir: tmp_dir} do
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    plan_id = envelope["plan_id"]

    assert {:error, %Error{code: :plan_corrupt}} = PlanStore.store("relative/plans", envelope)

    blocking_file = Path.join(tmp_dir, "blocking-file")
    File.write!(blocking_file, "not a directory")

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(Path.join(blocking_file, "plans"), envelope)

    locked_dir = Path.join(tmp_dir, "locked")
    File.mkdir_p!(locked_dir)
    File.mkdir!(Path.join(locked_dir, plan_id <> ".json.lock"))

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(locked_dir, envelope)

    directory_plan_dir = Path.join(tmp_dir, "directory-plan")
    directory_plan_path = Path.join(directory_plan_dir, plan_id <> ".json")
    File.mkdir_p!(directory_plan_path)
    File.chmod!(directory_plan_dir, 0o700)

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(directory_plan_dir, envelope)

    assert {:error, %Error{code: :plan_corrupt}} =
             PlanStore.read(directory_plan_dir, plan_id)

    private_dir = Path.join(tmp_dir, "private")
    assert {:ok, ^envelope} = PlanStore.store(private_dir, envelope)
    private_path = Path.join(private_dir, plan_id <> ".json")
    File.chmod!(private_path, 0o644)

    assert {:error, %Error{code: :plan_corrupt}} =
             PlanStore.store(private_dir, envelope)

    oversized_fields =
      put_in(
        plan_fields(),
        ["command", "payloads"],
        List.duplicate(String.duplicate("a", 65_536), 17)
      )

    assert {:ok, oversized_envelope} =
             PlanStore.build(oversized_fields, "proposed registry")

    assert {:error, %Error{code: :plan_corrupt}} =
             PlanStore.store(Path.join(tmp_dir, "oversized"), oversized_envelope)

    consume_dir = Path.join(tmp_dir, "consume-error")
    assert {:ok, ^envelope} = PlanStore.store(consume_dir, envelope)
    consume_path = Path.join(consume_dir, plan_id <> ".json")

    deny_remove = fn ->
      File.chmod!(consume_dir, 0o500)
      :ok
    end

    try do
      assert {:error, %Error{code: :atomic_replace_failed}} =
               PlanStore.consume(consume_dir, plan_id, before_remove: deny_remove)

      assert File.exists?(consume_path)
    after
      File.chmod!(consume_dir, 0o700)
    end

    injected_failure_dir = Path.join(tmp_dir, "injected-open-failure")

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(injected_failure_dir, envelope, file_ops: %{open: fn _path, _modes -> {:error, :eio} end})

    assert File.ls!(injected_failure_dir) == []

    assert {:error, %Error{code: :plan_corrupt}} =
             PlanStore.store(Path.join(tmp_dir, "invalid-injection"), envelope, file_ops: %{open: fn _path -> :ok end})
  end

  @tag :tmp_dir
  test "rejects replacement of the validated final plan directory before locking", %{tmp_dir: tmp_dir} do
    plan_dir = Path.join(tmp_dir, "bound-plan-dir")
    replacement_dir = Path.join(tmp_dir, "replacement-plan-dir")
    File.mkdir!(plan_dir)
    File.chmod!(plan_dir, 0o700)
    File.mkdir!(replacement_dir)
    File.chmod!(replacement_dir, 0o700)
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    parent = self()

    replace_plan_dir = fn ->
      File.rmdir!(plan_dir)
      File.ln_s!(replacement_dir, plan_dir)
      send(parent, :validated_plan_dir_replaced)
      :ok
    end

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(plan_dir, envelope, file_ops: %{before_plan_lock: replace_plan_dir})

    assert_receive :validated_plan_dir_replaced
    assert File.lstat!(plan_dir).type == :symlink
    assert File.ls!(replacement_dir) == []
  end

  @tag :tmp_dir
  test "preserves plan body errors when lock cleanup also fails", %{tmp_dir: tmp_dir} do
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    corrupt_dir = Path.join(tmp_dir, "corrupt-cleanup")
    assert {:ok, ^envelope} = PlanStore.store(corrupt_dir, envelope)

    corrupt_path = Path.join(corrupt_dir, envelope["plan_id"] <> ".json")
    corrupt_lock = corrupt_path <> ".lock"
    File.write!(corrupt_path, "corrupt")
    File.chmod!(corrupt_path, 0o600)

    assert {:error,
            %Error{
              code: :plan_corrupt,
              message: "plan envelope is corrupt; plan envelope lock cleanup failed"
            }} =
             PlanStore.store(corrupt_dir, envelope, file_ops: %{rmdir: fn ^corrupt_lock -> {:error, :eio} end})

    assert File.read!(corrupt_path) == "corrupt"
    File.rmdir!(corrupt_lock)

    atomic_dir = Path.join(tmp_dir, "atomic-cleanup")
    atomic_path = Path.join(atomic_dir, envelope["plan_id"] <> ".json")
    atomic_lock = atomic_path <> ".lock"

    assert {:error,
            %Error{
              code: :atomic_replace_failed,
              message: "plan envelope could not be stored atomically; plan envelope lock cleanup failed"
            }} =
             PlanStore.store(atomic_dir, envelope,
               file_ops: %{
                 open: fn _path, _modes -> {:error, :eio} end,
                 rmdir: fn ^atomic_lock -> {:error, :eio} end
               }
             )

    refute File.exists?(atomic_path)
    File.rmdir!(atomic_lock)
  end

  @tag :tmp_dir
  test "rejects a plan changed by the before-lock-release hook", %{tmp_dir: tmp_dir} do
    plan_dir = Path.join(tmp_dir, "final-plan-verify")
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    plan_path = Path.join(plan_dir, envelope["plan_id"] <> ".json")
    foreign = "foreign after hook"

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             PlanStore.store(plan_dir, envelope,
               file_ops: %{
                 before_lock_release: fn ->
                   File.write!(plan_path, foreign)
                   File.chmod!(plan_path, 0o600)
                   :ok
                 end
               }
             )

    assert message =~ "proposed_generation="
    assert message =~ "observed_generation=#{generation(foreign)}"
    assert File.read!(plan_path) == foreign
  end

  @tag :tmp_dir
  test "rejects an idempotent plan replaced between identity and descriptor checks", %{tmp_dir: tmp_dir} do
    plan_dir = Path.join(tmp_dir, "stable-idempotency")
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    assert {:ok, ^envelope} = PlanStore.store(plan_dir, envelope)

    plan_path = Path.join(plan_dir, envelope["plan_id"] <> ".json")
    replacement_path = plan_path <> ".replacement"
    exact_bytes = File.read!(plan_path)
    original_inode = File.lstat!(plan_path).inode
    parent = self()

    replace_existing = fn ->
      File.write!(replacement_path, exact_bytes)
      File.chmod!(replacement_path, 0o600)
      assert File.exists?(plan_path)
      assert File.exists?(replacement_path)
      File.rename!(replacement_path, plan_path)
      send(parent, :existing_plan_replaced)
      :ok
    end

    assert {:error, %Error{code: :plan_corrupt}} =
             PlanStore.store(plan_dir, envelope, file_ops: %{before_existing_plan_open: replace_existing})

    assert_receive :existing_plan_replaced
    refute File.lstat!(plan_path).inode == original_inode
    assert File.read!(plan_path) == exact_bytes
  end

  @tag :tmp_dir
  test "syncs the plan parent when linked temp cleanup fails", %{tmp_dir: tmp_dir} do
    plan_dir = Path.join(tmp_dir, "plans-cleanup-sync")
    temp_path = Path.join(plan_dir, ".plan.cleanup-sync")
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    plan_path = Path.join(plan_dir, envelope["plan_id"] <> ".json")
    parent = self()

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             PlanStore.store(plan_dir, envelope,
               file_ops: %{
                 temp_path: fn _path -> temp_path end,
                 remove: fn ^temp_path -> {:error, :eio} end,
                 sync_parent: fn ^plan_dir ->
                   send(parent, :cleanup_failure_parent_synced)
                   :ok
                 end
               }
             )

    committed_generation = generation(File.read!(plan_path))
    assert message =~ "observed_generation=#{committed_generation}"
    assert_receive :cleanup_failure_parent_synced
    refute_receive :cleanup_failure_parent_synced
    assert File.exists?(temp_path)
  end

  @tag :tmp_dir
  test "reconciles a link that publishes before returning an error", %{tmp_dir: tmp_dir} do
    plan_dir = Path.join(tmp_dir, "plans")
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    plan_path = Path.join(plan_dir, envelope["plan_id"] <> ".json")
    parent = self()

    link = fn source, ^plan_path ->
      :ok = File.ln(source, plan_path)
      {:error, :eio}
    end

    assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
             PlanStore.store(plan_dir, envelope,
               file_ops: %{
                 link: link,
                 sync_parent: fn ^plan_dir ->
                   send(parent, :link_error_parent_synced)
                   :ok
                 end
               }
             )

    committed_generation = generation(File.read!(plan_path))
    assert message =~ "proposed_generation=#{committed_generation}"
    assert message =~ "observed_generation=#{committed_generation}"
    assert_receive :link_error_parent_synced
    refute_receive :link_error_parent_synced
    assert File.ls!(plan_dir) == [Path.basename(plan_path)]
  end

  @tag :tmp_dir
  test "reports committed state when link returns eexist after publication", %{tmp_dir: tmp_dir} do
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")
    parent = self()

    for identity <- [:owned, :unavailable] do
      plan_dir = Path.join(tmp_dir, "link-eexist-#{identity}")
      plan_path = Path.join(plan_dir, envelope["plan_id"] <> ".json")
      lstat_key = {__MODULE__, make_ref()}

      lstat = fn path ->
        count = Process.get(lstat_key, 0)
        Process.put(lstat_key, count + 1)

        if identity == :unavailable and count == 1,
          do: {:ok, %{}},
          else: File.lstat(path)
      end

      link = fn source, ^plan_path ->
        :ok = File.ln(source, plan_path)
        {:error, :eexist}
      end

      assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
               PlanStore.store(plan_dir, envelope,
                 file_ops: %{
                   link: link,
                   lstat: lstat,
                   sync_parent: fn ^plan_dir ->
                     send(parent, {:link_eexist_parent_synced, identity})
                     :ok
                   end
                 }
               )

      committed_generation = generation(File.read!(plan_path))
      assert message =~ "proposed_generation=#{committed_generation}"
      assert message =~ "observed_generation=#{committed_generation}"
      assert_receive {:link_eexist_parent_synced, ^identity}
      refute_receive {:link_eexist_parent_synced, ^identity}
      assert File.ls!(plan_dir) == [Path.basename(plan_path)]
    end
  end

  @tag :tmp_dir
  test "covers prepublication directory loss and existing-plan replacement", %{tmp_dir: tmp_dir} do
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")

    missing_dir = Path.join(tmp_dir, "missing-before-lock")
    File.mkdir!(missing_dir)
    File.chmod!(missing_dir, 0o700)

    assert {:error, %Error{code: :atomic_replace_failed}} =
             PlanStore.store(missing_dir, envelope,
               file_ops: %{
                 before_plan_lock: fn ->
                   File.rmdir!(missing_dir)
                   :ok
                 end
               }
             )

    refute File.exists?(missing_dir)

    seed_dir = Path.join(tmp_dir, "existing-replacement-seed")
    assert {:ok, ^envelope} = PlanStore.store(seed_dir, envelope)
    filename = envelope["plan_id"] <> ".json"
    exact_bytes = File.read!(Path.join(seed_dir, filename))
    plan_dir = Path.join(tmp_dir, "existing-replacement")
    plan_path = Path.join(plan_dir, filename)

    link = fn _source, ^plan_path ->
      File.write!(plan_path, exact_bytes)
      File.chmod!(plan_path, 0o600)
      {:error, :eexist}
    end

    remove = fn temp_path ->
      :ok = File.rm(temp_path)
      File.write!(plan_path, "replacement after exact observation")
      File.chmod!(plan_path, 0o600)
      :ok
    end

    assert {:error, %Error{code: :plan_corrupt}} =
             PlanStore.store(plan_dir, envelope, file_ops: %{link: link, remove: remove})

    assert File.read!(plan_path) == "replacement after exact observation"
  end

  @tag :tmp_dir
  test "covers both cleanup outcomes after plan directory replacement", %{tmp_dir: tmp_dir} do
    {:ok, envelope} = PlanStore.build(plan_fields(), "proposed registry")

    for cleanup <- [:absent, :unavailable] do
      plan_dir = Path.join(tmp_dir, "prepublish-directory-#{cleanup}")
      saved_dir = plan_dir <> "-saved"
      File.mkdir!(plan_dir)
      File.chmod!(plan_dir, 0o700)
      lstat_key = {__MODULE__, make_ref()}

      close = fn device ->
        :ok = :file.close(device)
        File.rename!(plan_dir, saved_dir)
        File.mkdir!(plan_dir)
        File.chmod!(plan_dir, 0o700)
        :ok
      end

      lstat = fn path ->
        count = Process.get(lstat_key, 0)
        Process.put(lstat_key, count + 1)

        if cleanup == :unavailable and count == 1,
          do: {:error, :eio},
          else: File.lstat(path)
      end

      assert {:error, %Error{code: :atomic_replace_failed, message: message}} =
               PlanStore.store(plan_dir, envelope, file_ops: %{close: close, lstat: lstat})

      if cleanup == :unavailable do
        assert message =~ "temp cleanup failed before publication"
      else
        refute message =~ "temp cleanup failed"
      end

      assert File.ls!(plan_dir) == []
      File.rm_rf!(saved_dir)
    end
  end

  defp put_in_path(map, [key], value), do: Map.put(map, key, value)
  defp put_in_path(map, [key | rest], value), do: Map.put(map, key, put_in_path(map[key], rest, value))

  defp nested_value(depth) do
    Enum.reduce(1..depth, "leaf", fn index, nested -> %{"level_#{index}" => nested} end)
  end

  defp non_finite_float do
    external_positive_infinity = <<131, 70, 0x7F, 0xF0, 0, 0, 0, 0, 0, 0>>

    try do
      {:ok, :erlang.binary_to_term(external_positive_infinity)}
    rescue
      ArgumentError -> :unsupported
    end
  end

  defp plan_fields do
    %{
      "envelope_version" => 1,
      "action" => "add",
      "target_id" => "main",
      "command" => %{
        "checks" => [
          "mix test",
          %{"enabled" => true, "note" => nil, "weight" => 1.5}
        ],
        "display_name" => "Main",
        "linear" => %{"scope" => %{"project_slug" => "symphony"}}
      },
      "registry_path" => "/tmp/symphony/targets.yml",
      "expected_generation" => generation("original registry"),
      "source_hashes" => %{
        "/tmp/import.yml" => generation("import source"),
        "/tmp/repo/symphony.yml" => generation("repository source")
      },
      "created_at" => "2026-08-16T12:34:56.000000Z"
    }
  end

  defp generation(bytes) do
    "sha256:" <> (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))
  end
end
