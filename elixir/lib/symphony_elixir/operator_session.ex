defmodule SymphonyElixir.OperatorSession do
  @moduledoc """
  Owns the loopback operator credential for one host process.

  The bearer value is generated and retained only in this process as a digest. The
  public API exposes the credential path so a launcher can read it, but never
  returns the credential itself.
  """

  use GenServer

  import Bitwise, only: [&&&: 2]

  alias SymphonyElixir.LocalConfig
  alias SymphonyElixir.TargetRegistry.FileStore

  @credential_dir ".credentials"
  @session_dir "operator"
  @credential_file "token"
  @token_bytes 48
  @host_id_regex ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/

  defmodule State do
    @moduledoc false
    @enforce_keys [:host_id, :credential_path, :credential_stat, :token_digest]
    defstruct @enforce_keys
  end

  @type credentials :: %{host_id: String.t(), token_path: Path.t()}

  def start_link(opts \\ [])

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, :name) do
        nil -> GenServer.start_link(__MODULE__, opts)
        name -> GenServer.start_link(__MODULE__, opts, name: name)
      end
    else
      {:error, :invalid_options}
    end
  end

  def start_link(_opts), do: {:error, :invalid_options}

  @spec authenticate(GenServer.server(), binary()) :: :ok | {:error, :unauthorized | :unavailable}
  def authenticate(server, presented_token) when is_binary(presented_token) do
    GenServer.call(server, {:authenticate, presented_token})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def authenticate(_server, _presented_token), do: {:error, :unauthorized}

  @spec credentials(GenServer.server()) :: {:ok, credentials()} | {:error, :unavailable}
  def credentials(server) do
    GenServer.call(server, :credentials)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    with {:ok, current_uid} <- current_uid(),
         {:ok, host_id, config_root} <- validate_options(opts),
         {:ok, credential_path} <- prepare_credential_path(config_root, host_id, current_uid),
         {:ok, token, credential_stat} <- write_credential(credential_path, current_uid),
         token_digest <- :crypto.hash(:sha256, token) do
      {:ok,
       %State{
         host_id: host_id,
         credential_path: credential_path,
         credential_stat: credential_stat,
         token_digest: token_digest
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:credentials, _from, %State{} = state) do
    {:reply, {:ok, %{host_id: state.host_id, token_path: state.credential_path}}, state}
  end

  def handle_call({:authenticate, presented_token}, _from, %State{} = state) do
    presented_digest = :crypto.hash(:sha256, presented_token)

    if secure_compare(presented_digest, state.token_digest) do
      {:reply, :ok, state}
    else
      {:reply, {:error, :unauthorized}, state}
    end
  end

  @impl true
  def terminate(reason, %State{} = state) when reason in [:normal, :shutdown] do
    cleanup_credential(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, %{host_id: status.state.host_id})
    |> Map.put(:message, :redacted_operator_session_message)
    |> Map.put(:reason, :redacted_operator_session_reason)
  end

  defp validate_options(opts) do
    host_id = Keyword.get(opts, :host_id)
    config_root = Keyword.get(opts, :config_root)

    cond do
      not valid_host_id?(host_id) ->
        {:error, :invalid_host_id}

      not is_nil(config_root) and not is_binary(config_root) ->
        {:error, :invalid_config_root}

      true ->
        root = LocalConfig.root(config_root: config_root)
        {:ok, host_id, root}
    end
  end

  defp valid_host_id?(host_id) when is_binary(host_id),
    do: byte_size(host_id) > 0 and Regex.match?(@host_id_regex, host_id)

  defp valid_host_id?(_host_id), do: false

  defp prepare_credential_path(config_root, host_id, current_uid) do
    with :ok <- ensure_config_root(config_root, current_uid),
         {:ok, credentials_root} <-
           ensure_directory(Path.join(config_root, @credential_dir), 0o700, current_uid),
         {:ok, operator_root} <-
           ensure_directory(Path.join(credentials_root, @session_dir), 0o700, current_uid),
         {:ok, host_root} <-
           ensure_directory(Path.join(operator_root, host_id), 0o700, current_uid) do
      {:ok, Path.join(host_root, @credential_file)}
    end
  end

  defp ensure_config_root(path, current_uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode} = stat} ->
        if secure_directory?(stat, current_uid) and (mode &&& 0o022) == 0,
          do: :ok,
          else: {:error, :insecure_credentials_path}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(path),
             :ok <- File.chmod(path, 0o700),
             {:ok, %File.Stat{type: :directory} = stat} <- File.lstat(path),
             true <- secure_directory?(stat, current_uid) do
          :ok
        else
          _failure -> {:error, :insecure_credentials_path}
        end

      _failure ->
        {:error, :insecure_credentials_path}
    end
  end

  defp ensure_directory(path, mode, current_uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        if secure_directory?(stat, current_uid) and (stat.mode &&& 0o077) == 0 do
          {:ok, path}
        else
          {:error, :insecure_credentials_path}
        end

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(path),
             :ok <- File.chmod(path, mode),
             {:ok, %File.Stat{type: :directory} = stat} <- File.lstat(path),
             true <- secure_directory?(stat, current_uid),
             true <- (stat.mode &&& 0o077) == 0 do
          {:ok, path}
        else
          _failure -> {:error, :insecure_credentials_path}
        end

      _failure ->
        {:error, :insecure_credentials_path}
    end
  end

  defp secure_directory?(%File.Stat{type: :directory, mode: mode} = stat, current_uid) do
    (mode &&& 0o002) == 0 and owner_is_current_user?(stat, current_uid)
  end

  defp write_credential(path, current_uid) do
    token = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)

    with :ok <- validate_destination(path, current_uid),
         {:ok, temporary} <- FileStore.create_temp(path, token) do
      try do
        with :ok <- validate_destination(path, current_uid),
             :ok <- File.rename(temporary.path, path) do
          {:ok, token, temporary.stat}
        end
      after
        FileStore.remove_temp(temporary)
      end
    end
  end

  defp validate_destination(path, current_uid) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular} = stat} -> validate_credential_stat(stat, current_uid)
      _failure -> {:error, :insecure_credentials_file}
    end
  end

  defp validate_credential_stat(%File.Stat{type: :regular, mode: mode} = stat, current_uid) do
    if (mode &&& 0o077) == 0 and owner_is_current_user?(stat, current_uid),
      do: :ok,
      else: {:error, :insecure_credentials_file}
  end

  defp cleanup_credential(%State{credential_path: path, credential_stat: expected_stat}) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        if same_file?(stat, expected_stat), do: File.rm(path), else: :ok

      _other ->
        :ok
    end
  end

  defp same_file?(left, right) do
    left.inode == right.inode and left.major_device == right.major_device and
      left.minor_device == right.minor_device
  end

  defp owner_is_current_user?(%File.Stat{uid: uid}, current_uid)
       when is_integer(uid) and is_integer(current_uid),
       do: uid == current_uid

  defp current_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {uid, ""} when uid >= 0 -> {:ok, uid}
          _invalid -> {:error, :credential_store_unavailable}
        end

      _failure ->
        {:error, :credential_store_unavailable}
    end
  rescue
    _exception -> {:error, :credential_store_unavailable}
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end
end
