defmodule SymphonyElixir.DirectoryEntriesTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.DirectoryEntries
  import SymphonyElixir.TestSupport, only: [eventually: 1]

  test "halts after one request in a wide directory" do
    directory = temporary_directory("wide")

    try do
      Enum.each(1..256, fn index ->
        File.write!(Path.join(directory, "entry-#{index}"), "")
      end)

      deadline_ms = System.monotonic_time(:millisecond) + 5_000

      assert {:ok, 1} =
               DirectoryEntries.reduce_while(directory, 0, deadline_ms, fn _name, count ->
                 {:halt, count + 1}
               end)
    after
      File.rm_rf(directory)
    end
  end

  test "returns unreadable with the original accumulator for a missing directory" do
    missing_directory =
      Path.join(
        System.tmp_dir!(),
        "symphony-directory-entries-missing-#{System.unique_integer([:positive])}"
      )

    assert {:error, :unreadable, :unchanged} =
             DirectoryEntries.reduce_while(
               missing_directory,
               :unchanged,
               System.monotonic_time(:millisecond) + 5_000,
               fn _name, acc -> {:cont, acc} end
             )
  end

  test "preserves a filename containing a newline" do
    directory = temporary_directory("newline")
    filename = "before\nafter"
    File.write!(Path.join(directory, filename), "")

    try do
      deadline_ms = System.monotonic_time(:millisecond) + 5_000

      assert {:ok, names} =
               DirectoryEntries.reduce_while(directory, [], deadline_ms, fn name, names ->
                 {:cont, [name | names]}
               end)

      assert names == [filename]
    after
      File.rm_rf(directory)
    end
  end

  test "cleans up the native process when the callback raises" do
    directory = temporary_directory("callback-error")
    File.write!(Path.join(directory, "entry"), "")

    try do
      assert_raise RuntimeError, "callback failed", fn ->
        DirectoryEntries.reduce_while(
          directory,
          :unchanged,
          System.monotonic_time(:millisecond) + 5_000,
          fn _name, _acc -> raise "callback failed" end
        )
      end

      assert eventually(fn ->
               case System.cmd("ps", ["-axo", "command="], stderr_to_stdout: true) do
                 {output, 0} ->
                   if String.contains?(output, directory), do: nil, else: :clean

                 _error ->
                   nil
               end
             end) == :clean
    after
      File.rm_rf(directory)
    end
  end

  test "returns timeout without starting an expired traversal" do
    directory = temporary_directory("timeout")
    File.write!(Path.join(directory, "entry"), "")

    try do
      assert {:error, :timeout, :unchanged} =
               DirectoryEntries.reduce_while(
                 directory,
                 :unchanged,
                 System.monotonic_time(:millisecond) - 1,
                 fn _name, acc -> {:cont, acc} end
               )
    after
      File.rm_rf(directory)
    end
  end

  test "a deployment missing its bundled helper fails without reading directories" do
    with_iterator(nil, fn ->
      assert {:error, :iterator_unavailable, :unchanged} =
               DirectoryEntries.reduce_while("/", :unchanged, deadline(), fn _, _ -> flunk("unexpected entry") end)
    end)
  end

  test "fragmented transport preserves a complete filename" do
    with_iterator("printf '\\000\\000'; sleep 0.03; printf '\\000\\004D'; sleep 0.03; printf 'abc'", fn ->
      assert {:ok, ["abc"]} =
               DirectoryEntries.reduce_while("/", [], deadline(), fn name, names -> {:halt, [name | names]} end)
    end)
  end

  test "malformed transport frames never reach the directory callback" do
    frames = [
      "printf '\\000\\001\\000\\001'",
      "printf '\\000\\000\\000\\001Eextra'",
      "printf '\\000\\000\\000\\001X'",
      "printf '\\000\\001\\000\\000'; dd if=/dev/zero bs=65535 count=1 2>/dev/null; sleep 0.03; printf '\\000\\000'"
    ]

    for frame <- frames do
      with_iterator(frame, fn ->
        assert {:error, :iterator_unavailable, :unchanged} =
                 DirectoryEntries.reduce_while("/", :unchanged, deadline(), fn _, _ -> flunk("unexpected entry") end)
      end)
    end
  end

  test "native exit during the next request retains accepted entries" do
    with_iterator("printf '\\000\\000\\000\\004Dabc'; dd bs=1 count=1 of=/dev/null 2>/dev/null; exit 7", fn ->
      assert {:error, :iterator_unavailable, ["abc"]} =
               DirectoryEntries.reduce_while("/", [], deadline(), fn name, names -> {:cont, [name | names]} end)
    end)
  end

  test "native exit before the next request retains accepted entries" do
    with_iterator("printf '\\000\\000\\000\\004Dabc'; exit 7", fn ->
      assert {:error, :iterator_unavailable, ["abc"]} =
               DirectoryEntries.reduce_while("/", [], deadline(), fn name, names ->
                 receive do
                   {_port, {:exit_status, 7}} -> {:cont, [name | names]}
                 after
                   1_000 -> flunk("native helper did not exit")
                 end
               end)
    end)
  end

  test "a stalled native read times out and terminates its process group" do
    with_iterator("sleep 30", fn ->
      assert {:error, :timeout, :unchanged} =
               DirectoryEntries.reduce_while("/", :unchanged, deadline(500), fn _, _ -> flunk("unexpected entry") end)
    end)
  end

  test "a callback cannot extend the traversal deadline" do
    directory = temporary_directory("slow-callback")
    File.write!(Path.join(directory, "entry"), "")

    try do
      expires_at = deadline(500)

      assert {:error, :timeout, 1} =
               DirectoryEntries.reduce_while(directory, 0, expires_at, fn _, count ->
                 Process.sleep(max(expires_at - System.monotonic_time(:millisecond) + 1, 0))
                 {:cont, count + 1}
               end)
    after
      File.rm_rf!(directory)
    end
  end

  test "a queued native response cannot deliver a candidate after the deadline" do
    control = temporary_directory("late-response")
    ready = Path.join(control, "ready")
    release = Path.join(control, "release")
    on_exit(fn -> File.rm_rf!(control) end)
    quote = &SymphonyElixir.Shell.escape/1

    body =
      "touch #{quote.(ready)}; while [ ! -f #{quote.(release)} ]; do sleep 0.01; done; " <>
        "printf '\\000\\000\\000\\004Dabc'"

    with_iterator(body, fn ->
      expires_at = deadline(2_000)
      parent = self()

      task =
        Task.async(fn ->
          DirectoryEntries.reduce_while("/", [], expires_at, fn name, _ ->
            send(parent, {:late_candidate, name})
            {:halt, [name]}
          end)
        end)

      assert eventually(fn -> File.exists?(ready) and Process.info(task.pid, :status) == {:status, :waiting} end)
      true = :erlang.suspend_process(task.pid)

      try do
        File.write!(release, "")
        Process.sleep(max(expires_at - System.monotonic_time(:millisecond) + 20, 0))
      after
        :erlang.resume_process(task.pid)
      end

      assert {:error, :timeout, []} = Task.await(task)
      refute_received {:late_candidate, _}
    end)
  end

  test "browser retains discovered candidates when native enumeration times out" do
    with_iterator("sleep 30", fn ->
      result =
        SymphonyElixir.OperatorRepositoryBrowser.run(
          %{"action" => "scan", "path" => "/"},
          %{roots: ["/"], max_depth: 1, timeout_ms: 500},
          fn _ -> :ok end
        )

      assert result.status == "timeout"
      assert result.candidates == [%{path: "/", kind: "directory"}]
      assert result.errors == [%{path: nil, reason: :timeout}]
    end)
  end

  test "unrepresentable native filenames become JSON-safe errors, not failed scans" do
    body =
      "printf '\\000\\000\\000\\002D\\377'; dd bs=1 count=1 of=/dev/null 2>/dev/null; " <>
        "printf '\\000\\000\\000\\001E'"

    with_iterator(body, fn ->
      result =
        SymphonyElixir.OperatorRepositoryBrowser.run(
          %{"action" => "scan", "path" => "/"},
          %{roots: ["/"], max_depth: 1},
          fn _ -> :ok end
        )

      assert result.status == "partial"
      assert result.candidates == [%{path: "/", kind: "directory"}]
      assert result.errors == [%{path: "/", reason: :invalid_filename}]
      assert Jason.decode!(Jason.encode!(result))["errors"] == [%{"path" => "/", "reason" => "invalid_filename"}]
    end)
  end

  test "directory enumeration needs search permission, not read permission, on ancestors" do
    parent = temporary_directory("search-only")
    child = Path.join(parent, "child")
    File.mkdir!(child)
    File.write!(Path.join(child, "entry"), "")
    File.chmod!(parent, 0o111)

    try do
      assert {:error, :eacces} = File.ls(parent)

      assert {:ok, ["entry"]} =
               DirectoryEntries.reduce_while(child, [], deadline(), fn name, names -> {:cont, [name | names]} end)
    after
      File.chmod!(parent, 0o700)
      File.rm_rf!(parent)
    end
  end

  defp deadline(milliseconds \\ 5_000), do: System.monotonic_time(:millisecond) + milliseconds

  # These executables model transport faults at the OS process seam. Filesystem behavior
  # is covered above using the real bundled helper. No production artifact is replaced.
  defp with_iterator(body, test) do
    root = temporary_directory("deployment")
    application = Path.join(root, "symphony_elixir")
    native = Path.join(application, "priv/native")
    original_ebin = Application.app_dir(:symphony_elixir, "ebin")
    isolated_ebin = Path.join(application, "ebin")
    File.mkdir_p!(native)
    File.ln_s!(original_ebin, isolated_ebin)

    if body do
      executable = Path.join(native, "directory_iterator")
      File.write!(executable, "#!/bin/sh\ndd bs=1 count=1 of=/dev/null 2>/dev/null\n" <> body <> "\ndd bs=1 count=1 of=/dev/null 2>/dev/null\n")
      File.chmod!(executable, 0o700)
    end

    true = :code.replace_path(:symphony_elixir, String.to_charlist(isolated_ebin))

    try do
      test.()
    after
      true = :code.replace_path(:symphony_elixir, String.to_charlist(original_ebin))
      File.rm_rf!(root)
    end
  end

  defp temporary_directory(label) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "symphony-directory-entries-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    {:ok, canonical} = SymphonyElixir.PathSafety.canonicalize(directory)
    canonical
  end
end
