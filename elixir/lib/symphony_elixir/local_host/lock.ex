defmodule SymphonyElixir.LocalHost.Lock do
  @moduledoc """
  BEAM-held host ownership lock.

  `acquire/1` takes an exclusive non-blocking `flock` on the per-user
  lock file through a NIF and returns a resource holding the file
  descriptor. The descriptor lives inside the BEAM process itself, so
  the kernel releases ownership exactly when the BEAM exits; there is
  no helper process that could be killed out from under a running host.
  """

  @on_load {:init_nif, 0}

  @native_dir_env "SYMPHONY_NATIVE_DIR"

  @doc false
  @spec init_nif() :: :ok
  def init_nif do
    case safe_native_path("host_lock_nif.so") do
      nil ->
        :ok

      path ->
        load_path = String.trim_trailing(path, ".so")

        case :erlang.load_nif(String.to_charlist(load_path), 0) do
          :ok -> :ok
          {:error, _reason} -> :ok
        end
    end
  end

  @doc """
  Resolves a bundled native artifact for every launch entrypoint.

  Works for the source-tree Mix launcher (project priv through the
  loaded application), the built escript (`elixir/bin/symphony`, whose
  artifacts are not embedded and live in the project priv directory next
  to the script), and any explicit override through `#{@native_dir_env}`.
  """
  @spec native_path(String.t()) :: Path.t() | nil
  def native_path(name) do
    relative = Path.join("priv/native", name)

    candidates =
      [
        app_dir_candidate(relative),
        env_dir_candidate(name),
        script_dir_candidate(relative)
      ]
      |> List.flatten()
      |> Enum.filter(&is_binary/1)

    Enum.find(candidates, &File.regular?/1)
  end

  @doc """
  Takes the exclusive lock on `path` for the lifetime of this BEAM.

  Returns `{:ok, resource}` when ownership is acquired, `{:error,
  :held}` when another process owns the lock, or an error when the lock
  could not be established. Never publishes lock file contents.
  """
  @spec acquire(Path.t()) :: {:ok, reference()} | {:error, :held | :nif_not_loaded | atom()}
  def acquire(_path), do: :erlang.nif_error(:nif_not_loaded)

  defp safe_native_path(name) do
    native_path(name)
  rescue
    _exception -> nil
  catch
    :throw, _reason -> nil
    :exit, _reason -> nil
    _kind, _reason -> nil
  end

  defp app_dir_candidate(relative) do
    case :code.priv_dir(:symphony_elixir) do
      priv when is_list(priv) ->
        [Path.join(priv, Path.join("native", Path.basename(relative)))]

      _other ->
        [Application.app_dir(:symphony_elixir, relative)]
    end
  rescue
    _exception -> []
  end

  defp env_dir_candidate(name) do
    case System.get_env(@native_dir_env) do
      dir when is_binary(dir) and dir != "" -> [Path.join(dir, name)]
      _other -> []
    end
  end

  # The built escript lives in <project>/bin; its native artifacts are
  # not embedded in the escript archive, so resolve them from the
  # script location relative to the project root.
  defp script_dir_candidate(relative) do
    case safe_script_name() do
      nil ->
        []

      script when is_binary(script) ->
        if File.regular?(script) do
          project_root =
            script
            |> Path.expand()
            |> Path.dirname()
            |> Path.dirname()

          [Path.join(project_root, relative)]
        else
          []
        end

      _not_a_script ->
        []
    end
  end

  defp safe_script_name do
    :escript.script_name() |> to_string()
  rescue
    _exception -> nil
  catch
    :throw, _reason -> nil
    :exit, _reason -> nil
    _kind, _reason -> nil
  end
end
