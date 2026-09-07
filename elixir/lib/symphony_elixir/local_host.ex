defmodule SymphonyElixir.LocalHost do
  @moduledoc """
  Private, authenticated discovery of the per-user local Symphony host.

  Discovery reads the private record published by
  `SymphonyElixir.LocalHost.Ownership` and then verifies it against the
  running host through the authenticated readiness endpoint: bearer
  credential from the per-user token file, loopback endpoint, host
  identity, and interface/schema versions. A record is never trusted on
  its own, so stale, partial, insecure, or incompatible records are
  rejected with distinct, credential-safe error codes.

  `attach/1` starts a detached registry host only when ownership is
  proven absent (the OS-held per-user lock is free), then waits for
  authenticated readiness. It never creates configuration.
  """

  alias SymphonyElixir.{LocalConfig, LocalHost.Ownership, OperatorInterface, OperatorSession}
  alias SymphonyElixir.LocalHost.Lock

  @readiness_path "/api/v1/operator/readiness"
  @readiness_timeout_ms 3_000
  @token_max_bytes 256
  @attach_poll_ms 250
  @attach_timeout_ms 30_000

  @host_id_regex ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
  @loopback_hosts MapSet.new(["127.0.0.1", "::1"])

  @type discovery :: %{
          endpoint: String.t(),
          host_id: String.t(),
          interface_version: pos_integer(),
          schema_version: pos_integer(),
          token_file: Path.t()
        }

  @type discovery_error :: %{code: String.t(), next_action: String.t()}

  @spec discover() :: {:ok, discovery()} | {:error, discovery_error()}
  def discover, do: discover([])

  @doc """
  Verifies the published discovery record against the live host.

  Never writes and never touches the ownership lock; a missing config
  root or record is simply an absent host.
  """
  @spec discover(keyword()) :: {:ok, discovery()} | {:error, discovery_error()}
  def discover(opts) do
    record_path = record_path(opts)

    with {:ok, bytes} <- read_record(record_path),
         {:ok, record} <- decode_record(bytes),
         :ok <- validate_record_security(record_path),
         {:ok, token} <- read_token(record),
         {:ok, readiness} <- request_readiness(record, token, opts),
         :ok <- verify_identity(record, readiness),
         :ok <- verify_versions(record, readiness) do
      {:ok,
       %{
         endpoint: record["endpoint"],
         host_id: record["host_id"],
         interface_version: record["interface_version"],
         schema_version: record["schema_version"],
         token_file: record["token_file"]
       }}
    else
      {:error, %{code: _code} = error} -> {:error, error}
    end
  rescue
    _exception -> {:error, host_uncertain()}
  catch
    _kind, _reason -> {:error, host_uncertain()}
  end

  @spec attach() :: {:ok, discovery()} | {:error, discovery_error()}
  def attach, do: attach([])

  @doc """
  Ensures a detached local host is running and returns its discovery.

  Idempotent: when ownership is already held and the running host is
  discoverable, its discovery is returned without starting anything.
  """
  @spec attach(keyword()) :: {:ok, discovery()} | {:error, discovery_error()}
  def attach(opts) do
    registry_path = LocalConfig.target_registry_path(config_root_keyword(opts))

    with :free <- ownership_status(opts),
         :ok <- verify_absent_host(opts),
         :ok <- ensure_registry(registry_path),
         :ok <- launch_detached_host(registry_path, opts) do
      await_ready_discovery(opts)
    else
      :held ->
        case discover(opts) do
          {:ok, discovery} ->
            {:ok, discovery}

          {:error, _unavailable} ->
            {:error, host_already_running()}
        end

      {:error, %{code: _code} = error} ->
        {:error, error}
    end
  end

  defp verify_absent_host(opts) do
    case discover(opts) do
      {:error, %{code: code}} when code in ["host_not_running", "host_stale"] -> :ok
      {:error, error} -> {:error, error}
      {:ok, _unlocked_host} -> {:error, ownership_unknown()}
    end
  end

  defp ownership_status(opts) do
    probe = Keyword.get(opts, :ownership_probe, fn -> Ownership.probe(config_root_keyword(opts)) end)

    case probe.() do
      :free -> :free
      :held -> :held
      _other -> {:error, ownership_unknown()}
    end
  end

  defp ensure_registry(registry_path) do
    if File.regular?(registry_path) do
      :ok
    else
      {:error, %{code: "host_registry_missing", next_action: "Run first-use setup before attaching a host."}}
    end
  end

  defp launch_detached_host(registry_path, opts) do
    launcher = Keyword.get(opts, :detached_launcher) || (&detached_host_command/2)

    case launcher.(registry_path, opts) do
      :ok ->
        :ok

      {:error, %{code: _code} = error} ->
        {:error, error}

      _other ->
        {:error, host_start_failed()}
    end
  end

  # The native launcher double-forks into a new session and replaces all
  # terminal descriptors before exec. The host is not a client child.
  defp detached_host_command(registry_path, opts) do
    with {:ok, %{code: "already_configured"}} <- SymphonyElixir.HostBootstrap.preview(config_root_keyword(opts)),
         {:ok, project_dir} <- host_project_dir(),
         {:ok, mise} <- find_executable("mise"),
         {:ok, log_file} <- prepare_boot_log(opts),
         launcher when is_binary(launcher) <- Lock.native_path("host_lock") do
      mix_env = System.get_env("MIX_ENV") || "dev"
      snippet = ~s|SymphonyElixir.CLI.main(["host", "run", "--registry", System.fetch_env!("SYMPHONY_DETACHED_REGISTRY")])|
      root = LocalConfig.root(config_root_keyword(opts))

      args = ["detach", log_file, mise, "exec", "--", "mix", "run", "--no-start", "--no-compile", "--no-halt", "-e", snippet]

      environment = [
        {"MIX_ENV", mix_env},
        {"SYMPHONY_HOME", project_dir},
        {"SYMPHONY_CONFIG_ROOT", root},
        {"SYMPHONY_DETACHED_REGISTRY", registry_path}
      ]

      case System.cmd(launcher, args, cd: project_dir, env: environment) do
        {_output, 0} -> :ok
        _failure -> {:error, host_start_failed()}
      end
    else
      {:error, %{code: _code} = error} ->
        {:error, error}

      {:ok, _setup_required} ->
        {:error, %{code: "host_configuration_missing", next_action: "Run host bootstrap preview and confirm the missing host files."}}

      _unavailable ->
        {:error, host_launch_unavailable()}
    end
  end

  defp prepare_boot_log(opts) do
    directory = Path.dirname(record_path(opts))

    result =
      case File.lstat(directory) do
        {:error, :enoent} ->
          with :ok <- File.mkdir_p(directory), do: File.chmod(directory, 0o700)

        {:ok, _stat} ->
          :ok

        _other ->
          :error
      end

    with :ok <- result,
         :ok <- secure_directory?(directory),
         path = Path.join(directory, "boot-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false) <> ".log"),
         :ok <- File.write(path, "", [:exclusive]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    else
      _failure -> {:error, host_insecure()}
    end
  end

  defp host_project_dir do
    home = System.get_env("SYMPHONY_HOME")

    if is_binary(home) and File.regular?(Path.join(home, "mix.exs")),
      do: {:ok, Path.expand(home)},
      else: beam_project_dir()
  end

  defp beam_project_dir do
    case :code.which(SymphonyElixir.HostCLI) do
      beam when is_list(beam) ->
        project_dir = beam |> to_string() |> nested_dirname(6)

        if File.regular?(Path.join(project_dir, "mix.exs")),
          do: {:ok, project_dir},
          else: escript_project_dir()

      _other ->
        escript_project_dir()
    end
  end

  defp nested_dirname(path, 0), do: path

  defp nested_dirname(path, count) when count > 0,
    do: path |> Path.dirname() |> nested_dirname(count - 1)

  defp escript_project_dir do
    project_dir = :escript.script_name() |> to_string() |> Path.expand() |> Path.dirname() |> Path.dirname()

    if File.regular?(Path.join(project_dir, "mix.exs")),
      do: {:ok, project_dir},
      else: {:error, host_launch_unavailable()}
  rescue
    _exception -> {:error, host_launch_unavailable()}
  catch
    _kind, _reason -> {:error, host_launch_unavailable()}
  end

  defp find_executable(name) do
    case System.find_executable(name) do
      nil -> {:error, host_launch_unavailable()}
      path -> {:ok, path}
    end
  end

  defp await_ready_discovery(opts) do
    deadline = Keyword.get(opts, :attach_timeout_ms, @attach_timeout_ms)
    started_at = System.monotonic_time(:millisecond)
    poll = Keyword.get(opts, :attach_poll_ms, @attach_poll_ms)

    do_await_ready_discovery(opts, deadline, started_at, poll)
  end

  defp do_await_ready_discovery(opts, deadline, started_at, poll) do
    remaining = deadline - (System.monotonic_time(:millisecond) - started_at)

    if remaining <= 0 do
      {:error, %{code: "host_start_timeout", next_action: "The detached host did not become ready; inspect the private host boot log for startup errors."}}
    else
      case discover(opts) do
        {:ok, discovery} ->
          {:ok, discovery}

        {:error, %{code: code}} when code in ["host_not_running", "host_stale", "host_uncertain"] ->
          Process.sleep(min(poll, remaining))
          do_await_ready_discovery(opts, deadline, started_at, poll)

        {:error, %{code: _code} = error} ->
          {:error, error}
      end
    end
  end

  defp record_path(opts) do
    opts
    |> config_root_keyword()
    |> LocalConfig.root()
    |> Path.join("host/discovery.json")
  end

  defp config_root_keyword(opts) do
    case Keyword.get(opts, :config_root) do
      nil -> []
      root -> [config_root: root]
    end
  end

  defp read_record(record_path) do
    with {:ok, %File.Stat{size: size}} <- File.lstat(record_path),
         true <- size <= 16_384,
         :ok <- validate_record_security(record_path),
         {:ok, bytes} <- File.read(record_path) do
      {:ok, bytes}
    else
      {:error, :enoent} -> {:error, host_not_running()}
      {:error, %{code: _code} = error} -> {:error, error}
      _failure -> {:error, host_uncertain()}
    end
  end

  defp decode_record(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"endpoint" => endpoint, "host_id" => host_id} = record}
      when is_binary(endpoint) and is_binary(host_id) ->
        with :ok <- valid_endpoint?(endpoint),
             :ok <- valid_host_id?(host_id),
             :ok <- valid_versions?(record),
             :ok <- valid_token_file?(record) do
          {:ok, record}
        else
          {:error, :non_loopback} -> {:error, host_insecure()}
          _invalid -> {:error, host_uncertain()}
        end

      _other ->
        {:error, host_uncertain()}
    end
  end

  defp valid_host_id?(host_id) when is_binary(host_id),
    do: if(Regex.match?(@host_id_regex, host_id), do: :ok, else: {:error, :invalid_host_id})

  defp valid_host_id?(_host_id), do: {:error, :invalid_host_id}

  defp valid_endpoint?(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "http", host: host, port: port, userinfo: nil, path: path, query: nil, fragment: nil}
      when not is_nil(host) and path in [nil, ""] ->
        if MapSet.member?(@loopback_hosts, host) and port > 0 and port <= 65_535,
          do: :ok,
          else: {:error, :non_loopback}

      _other ->
        {:error, :invalid_endpoint}
    end
  end

  defp read_token(record) do
    token_file = record["token_file"]

    with :ok <- secure_token_file(token_file),
         {:ok, bytes} <- File.read(token_file),
         token = String.trim(bytes),
         true <- byte_size(token) > 0 and byte_size(token) <= @token_max_bytes do
      {:ok, token}
    else
      {:error, :insecure} -> {:error, host_insecure()}
      _missing -> {:error, host_stale()}
    end
  end

  defp secure_token_file(path) do
    with :ok <- secure_file?(path, 0o600),
         {:ok, %File.Stat{size: size}} <- File.lstat(path),
         true <- size <= @token_max_bytes,
         :ok <- secure_directory?(Path.dirname(path)) do
      :ok
    else
      {:error, :missing} = missing -> missing
      _failure -> {:error, :insecure}
    end
  end

  defp valid_versions?(record) do
    interface_version = Map.get(record, "interface_version")
    schema_version = Map.get(record, "schema_version")

    if is_integer(interface_version) and interface_version > 0 and
         is_integer(schema_version) and schema_version > 0,
       do: :ok,
       else: {:error, :invalid_versions}
  end

  defp valid_token_file?(record) do
    case Map.get(record, "token_file") do
      token_file when is_binary(token_file) ->
        if Path.type(token_file) == :absolute,
          do: :ok,
          else: {:error, :invalid_token_file}

      _other ->
        {:error, :invalid_token_file}
    end
  end

  defp validate_record_security(record_path) do
    with :ok <- secure_file?(record_path, 0o600),
         :ok <- secure_directory?(Path.dirname(record_path)) do
      :ok
    else
      _insecure -> {:error, host_insecure()}
    end
  end

  defp secure_file?(path, expected_mode) do
    with {:ok, %File.Stat{type: :regular} = stat} <- File.lstat(path),
         {:ok, current_uid} <- OperatorSession.current_uid() do
      if private_mode?(stat, expected_mode) and owned?(stat, current_uid),
        do: :ok,
        else: {:error, :insecure}
    else
      {:error, :enoent} -> {:error, :missing}
      _failure -> {:error, :insecure}
    end
  end

  defp secure_directory?(path) do
    with {:ok, %File.Stat{type: :directory} = stat} <- File.lstat(path),
         {:ok, current_uid} <- OperatorSession.current_uid() do
      if Bitwise.band(stat.mode, 0o077) == 0 and owned?(stat, current_uid),
        do: :ok,
        else: {:error, :insecure}
    else
      _failure -> {:error, :missing}
    end
  end

  defp private_mode?(%File.Stat{mode: mode}, expected_mode) do
    Bitwise.band(mode, 0o777) == expected_mode
  end

  defp owned?(%File.Stat{uid: uid}, current_uid), do: is_integer(uid) and uid == current_uid

  defp request_readiness(record, token, opts) do
    request = Keyword.get(opts, :readiness_request) || (&default_readiness_request/2)

    case request.(record["endpoint"], token) do
      {:ok, %{status: 200} = response} ->
        readiness_body(response)

      {:ok, %{status: 401}} ->
        {:error, host_stale()}

      {:ok, %{status: 403}} ->
        {:error, host_insecure()}

      {:ok, %{status: 404}} ->
        {:error, host_incompatible()}

      {:ok, %{status: _other}} ->
        {:error, host_uncertain()}

      _unreachable ->
        {:error, host_stale()}
    end
  end

  defp default_readiness_request(endpoint, token) do
    with {:ok, _applications} <- Application.ensure_all_started(:req) do
      Req.get(endpoint <> @readiness_path,
        headers: %{"authorization" => "Bearer " <> token},
        retry: false,
        redirect: false,
        connect_options: [timeout: @readiness_timeout_ms],
        receive_timeout: @readiness_timeout_ms
      )
    end
  rescue
    _exception -> {:error, :unreachable}
  catch
    _kind, _reason -> {:error, :unreachable}
  end

  defp readiness_body(%{body: body}) when is_map(body) do
    with :ok <- valid_host_id?(body["host_id"]),
         {:ok, interface_version} <- positive_integer(body["interface_version"]),
         {:ok, schema_version} <- positive_integer(body["schema_version"]) do
      {:ok, %{host_id: body["host_id"], interface_version: interface_version, schema_version: schema_version}}
    else
      _invalid -> {:error, host_incompatible()}
    end
  end

  defp readiness_body(_other), do: {:error, host_incompatible()}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_version}

  defp verify_identity(record, readiness) do
    if record["host_id"] == readiness.host_id,
      do: :ok,
      else: {:error, host_stale()}
  end

  defp verify_versions(record, readiness) do
    expected = OperatorInterface.interface_versions()

    if record["interface_version"] == readiness.interface_version and
         record["schema_version"] == readiness.schema_version and
         readiness.interface_version == expected.interface_version and
         readiness.schema_version == expected.schema_version do
      :ok
    else
      {:error, host_incompatible()}
    end
  end

  defp host_not_running do
    %{
      code: "host_not_running",
      next_action: "Start a local host with `symphony host run` or `symphony host attach`."
    }
  end

  defp host_already_running do
    %{
      code: "host_already_running",
      next_action: "Another process owns this user's host lock; inspect it with `symphony host discover`."
    }
  end

  defp host_stale do
    %{
      code: "host_stale",
      next_action: "The recorded host is no longer reachable; stop it or attach again to restart."
    }
  end

  defp host_incompatible do
    %{
      code: "host_incompatible",
      next_action: "The running host speaks an incompatible protocol version; restart it from this checkout."
    }
  end

  defp host_insecure do
    %{
      code: "host_insecure",
      next_action: "The host discovery record or credential file failed the local security check; stop the host and reattach."
    }
  end

  defp host_uncertain do
    %{
      code: "host_uncertain",
      next_action: "The host discovery record is incomplete or unreadable; retry discovery or restart the host."
    }
  end

  defp ownership_unknown do
    %{
      code: "host_ownership_unknown",
      next_action: "Host ownership could not be verified; no host was started."
    }
  end

  defp host_start_failed do
    %{
      code: "host_start_failed",
      next_action: "The detached host failed to start; inspect the Symphony host log for errors."
    }
  end

  defp host_launch_unavailable do
    %{
      code: "host_launch_unavailable",
      next_action: "The detached host launcher is unavailable; run `symphony host run` directly."
    }
  end
end
