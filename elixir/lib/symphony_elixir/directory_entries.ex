defmodule SymphonyElixir.DirectoryEntries do
  @moduledoc """
  Incremental directory traversal through the bundled native iterator.

  The native helper receives one request for each entry and returns one bounded
  binary frame. It is deliberately kept outside the BEAM so a native failure
  cannot take down the VM.
  """

  alias SymphonyElixir.ProcessSupervisor

  @max_frame_bytes 65_536
  @frame_header_bytes 4
  @max_buffer_bytes @max_frame_bytes + @frame_header_bytes

  @type callback(acc) :: (binary(), acc -> {:cont, acc} | {:halt, acc})
  @type result(acc) :: {:ok, acc} | {:error, :unreadable | :timeout | :iterator_unavailable, acc}

  @spec reduce_while(Path.t(), acc, integer(), callback(acc)) :: result(acc) when acc: var
  def reduce_while(path, acc, deadline_ms, callback)
      when is_binary(path) and is_integer(deadline_ms) and is_function(callback, 2) do
    if deadline_expired?(deadline_ms) do
      {:error, :timeout, acc}
    else
      executable = Application.app_dir(:symphony_elixir, "priv/native/directory_iterator")

      case ProcessSupervisor.start([executable, path], stderr_to_stdout: false) do
        {:ok, process} ->
          try do
            reduce_entries(process, acc, deadline_ms, callback)
          after
            close_iterator(process)
          end

        {:error, _reason} ->
          {:error, :iterator_unavailable, acc}
      end
    end
  end

  defp reduce_entries(process, acc, deadline_ms, callback) do
    if deadline_expired?(deadline_ms) do
      {:error, :timeout, acc}
    else
      port = ProcessSupervisor.port(process)

      reduce_response(request_entry(port, deadline_ms), process, acc, deadline_ms, callback)
    end
  end

  defp reduce_response({:ok, :end}, _process, acc, _deadline_ms, _callback), do: {:ok, acc}
  defp reduce_response({:error, reason}, _process, acc, _deadline_ms, _callback), do: {:error, reason, acc}

  defp reduce_response({:ok, {:entry, name}}, process, acc, deadline_ms, callback) do
    if deadline_expired?(deadline_ms) do
      {:error, :timeout, acc}
    else
      case callback.(name, acc) do
        {:cont, next_acc} -> reduce_entries(process, next_acc, deadline_ms, callback)
        {:halt, next_acc} -> {:ok, next_acc}
      end
    end
  end

  defp request_entry(port, deadline_ms) do
    with :ok <- send_request(port, "N") do
      await_frame(port, deadline_ms, <<>>)
    end
  end

  defp send_request(port, command) do
    true = Port.command(port, command)
    :ok
  rescue
    ArgumentError -> {:error, :iterator_unavailable}
  end

  defp close_iterator(process) do
    port = ProcessSupervisor.port(process)

    if send_request(port, "Q") == :ok do
      receive do
        {^port, {:exit_status, _status}} -> :ok
      after
        100 -> :ok
      end
    end

    ProcessSupervisor.kill(process)
  end

  defp await_frame(port, deadline_ms, buffered) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, chunk}} when is_binary(chunk) ->
          case decode_frame(buffered, chunk) do
            {:more, next_buffer} -> await_frame(port, deadline_ms, next_buffer)
            {:ok, frame} -> {:ok, frame}
            {:error, reason} -> {:error, reason}
          end

        {^port, {:exit_status, _status}} ->
          {:error, :iterator_unavailable}
      after
        remaining_ms -> {:error, :timeout}
      end
    end
  end

  defp decode_frame(buffered, chunk)
       when byte_size(buffered) + byte_size(chunk) > @max_buffer_bytes,
       do: {:error, :iterator_unavailable}

  defp decode_frame(buffered, chunk), do: decode_buffer(buffered <> chunk)

  defp decode_buffer(<<length::unsigned-big-32, payload::binary>> = buffer)
       when length <= @max_frame_bytes and byte_size(payload) < length,
       do: {:more, buffer}

  defp decode_buffer(<<length::unsigned-big-32, payload::binary>>)
       when length <= @max_frame_bytes and byte_size(payload) == length,
       do: decode_payload(payload)

  defp decode_buffer(<<_length::unsigned-big-32, _payload::binary>>),
    do: {:error, :iterator_unavailable}

  defp decode_buffer(short_header), do: {:more, short_header}

  defp decode_payload(<<"D", name::binary>>) when byte_size(name) > 0,
    do: {:ok, {:entry, name}}

  defp decode_payload(<<"E">>), do: {:ok, :end}
  defp decode_payload(<<"F">>), do: {:error, :unreadable}
  defp decode_payload(_payload), do: {:error, :iterator_unavailable}

  defp deadline_expired?(deadline_ms),
    do: deadline_ms <= System.monotonic_time(:millisecond)
end
