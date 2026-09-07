defmodule SymphonyElixir.HostBootstrap do
  @moduledoc false

  alias SymphonyElixir.Config.Schema, as: ConfigSchema
  alias SymphonyElixir.LocalConfig
  alias SymphonyElixir.TargetRegistry.{Schema, Validation, Yaml}
  alias SymphonyElixir.Workflow.Renderer

  @token_prefix "sb1-"
  @token_format 1
  @file_permission 0o600
  @root_permission 0o700
  @host_id "local"
  @default_polling %{"interval_ms" => 30_000, "max_concurrent_target_polls" => 2}
  @default_capacity %{
    "max_concurrent_agents" => 4,
    "max_concurrent_startups" => 1,
    "max_concurrent_reviewers" => 1
  }
  @default_scheduling %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 3}

  @spec preview(keyword()) :: {:ok, map()} | {:error, map()}
  def preview(opts \\ []) do
    with {:ok, view} <- build_view(opts) do
      {:ok, preview_result(view)}
    end
  rescue
    _exception -> {:error, error("bootstrap_unavailable", "Bootstrap could not inspect the host environment. Ensure HOME is set and retry.")}
  end

  @spec confirm(term(), keyword()) :: {:ok, map()} | {:error, map()}
  def confirm(token, opts \\ [])

  @spec confirm(term(), keyword()) :: {:ok, map()} | {:error, map()}
  def confirm(token, opts) when is_binary(token) and is_list(opts) do
    with {:ok, expected} <- decode_confirmation(token),
         {:ok, view} <- build_view(opts),
         :ok <- match_confirmation(expected, view) do
      commit(view)
    end
  rescue
    _exception -> {:error, error("bootstrap_unavailable", "Bootstrap could not inspect the host environment. Ensure HOME is set and retry.")}
  end

  def confirm(_token, _opts),
    do:
      {:error,
       error(
         "invalid_confirmation",
         "The confirmation token is invalid. Run host bootstrap preview for a fresh preview."
       )}

  defp build_view(opts) do
    home = Keyword.get(opts, :home) || System.user_home!()

    with {:ok, _applications} <- Application.ensure_all_started(:yaml_elixir),
         {:ok, config_file} <- inspect_file(LocalConfig.path(opts), "config"),
         {:ok, config} <- effective_config(config_file),
         {:ok, registry_file} <- inspect_file(LocalConfig.target_registry_path(opts), "registry"),
         {:ok, registry_document} <- effective_registry(registry_file, opts, home) do
      {:ok,
       %{
         home: home,
         root: LocalConfig.root(opts),
         config_file: config_file,
         registry_file: registry_file,
         config: config,
         registry_document: registry_document,
         proposal: proposal(config_file, registry_file)
       }}
    else
      {:error, %{code: _code}} = failure -> failure
      _unavailable -> {:error, error("bootstrap_unavailable", "The YAML runtime could not start. Rebuild Symphony before retrying.")}
    end
  end

  defp inspect_file(path, kind) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, bytes} ->
            {:ok, %{path: path, status: :present, bytes: bytes, digest: digest(bytes)}}

          _failure ->
            {:error,
             error(
               "#{kind}_unreadable",
               "#{path} exists but could not be read. Fix access, then run host bootstrap preview again."
             )}
        end

      {:error, :enoent} ->
        {:ok, %{path: path, status: :missing, bytes: nil, digest: nil}}

      _other ->
        {:error,
         error(
           "unsafe_path",
           "#{path} is not a regular file. Remove the symlink or directory entry, then run host bootstrap preview again."
         )}
    end
  end

  defp effective_config(%{status: :missing, path: path}),
    do: validate_effective_config(LocalConfig.default_config(), path)

  defp effective_config(%{bytes: bytes, path: path}) do
    case Yaml.decode(bytes) do
      {:ok, document} when is_map(document) ->
        config =
          LocalConfig.default_config()
          |> LocalConfig.deep_merge(document)
          |> normalize_empty_sections()

        validate_effective_config(config, path)

      _invalid ->
        {:error, invalid_config_error(path, "is not valid YAML")}
    end
  end

  # The runtime schema treats an empty list as an empty section (cast_embed
  # converts keyword lists to maps); normalize it so guidance only ever sees
  # map sections.
  defp normalize_empty_sections(config) do
    Enum.reduce(ConfigSchema.__schema__(:embeds), config, fn section, acc ->
      name = Atom.to_string(section)

      case acc do
        %{^name => []} -> Map.put(acc, name, %{})
        _present -> acc
      end
    end)
  end

  # The local config is a partial overlay: the workflow half of the runtime
  # composition (RunSetup/Manifest) supplies the plain map sections such as
  # profiles and their cross-section semantics. Validate the structured
  # sections with the runtime schema's own embedded changesets and the runner
  # catalog with its own validator, so wrong-shaped values return
  # invalid_config before guidance or acceptance reads them.
  defp validate_effective_config(config, path) do
    runtime = LocalConfig.runtime_config(config)

    errors =
      Enum.flat_map(ConfigSchema.__schema__(:embeds), fn section ->
        name = Atom.to_string(section)
        embedded_section_errors(name, ConfigSchema.__schema__(:embed, section), Map.get(runtime, name))
      end) ++ runner_catalog_errors(Map.get(runtime, "runners"))

    if errors == [] do
      {:ok, config}
    else
      {:error, invalid_config_error(path, "has invalid runtime settings (#{Enum.join(errors, "; ")})")}
    end
  end

  defp embedded_section_errors(_section, _embed, nil), do: []

  defp embedded_section_errors(section, _embed, value) when not is_map(value),
    do: ["#{section} must be a map"]

  defp embedded_section_errors(section, %Ecto.Embedded{related: related}, value) do
    related
    |> struct()
    |> related.changeset(value)
    |> Ecto.Changeset.apply_action(:validate)
    |> case do
      {:ok, _settings} -> []
      {:error, changeset} -> section_error_paths(changeset, section)
    end
  end

  # Stable field paths with a generic diagnostic; Ecto messages and option
  # values are never echoed, so no configuration value can reach the output.
  defp section_error_paths(changeset, section) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn _error -> :invalid end)
    |> flatten_section_paths(section)
  end

  defp flatten_section_paths(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {field, nested} -> flatten_section_paths(nested, "#{prefix}.#{field}") end)
  end

  defp flatten_section_paths(messages, prefix) when is_list(messages),
    do: ["#{prefix} is invalid"]

  defp runner_catalog_errors(nil), do: []

  defp runner_catalog_errors(runners) when is_map(runners) do
    case ConfigSchema.validate_runner_catalog_detailed(runners) do
      {:ok, _normalized_runners} -> []
      {:error, errors} -> Enum.map(errors, &"#{&1.path} #{&1.code}")
    end
  end

  defp runner_catalog_errors(_not_a_map), do: ["runners must be a map"]

  defp invalid_config_error(path, reason) do
    error(
      "invalid_config",
      "The local config file #{path} #{reason}. Fix it manually; bootstrap never overwrites existing files."
    )
  end

  defp effective_registry(%{status: :missing, path: path}, _opts, home),
    do: validate_registry(default_registry_document(Path.dirname(path)), path, home)

  defp effective_registry(%{bytes: bytes, path: path}, _opts, home) do
    with {:ok, document} <- decode_registry(bytes) do
      validate_registry(document, path, home)
    end
  end

  defp decode_registry(bytes) do
    case Yaml.decode(bytes) do
      {:ok, document} when is_map(document) -> {:ok, document}
      _invalid -> {:error, registry_error("is not valid YAML")}
    end
  end

  defp validate_registry(document, path, home) do
    case Schema.validate(document, home: home) do
      {:ok, snapshot} ->
        snapshot
        |> Map.put(:path, path)
        |> Validation.validate(registry_path: path)
        |> case do
          %{globally_valid?: true} -> {:ok, document}
          _invalid -> {:error, registry_error("does not pass registry validation")}
        end

      {:error, _reason} ->
        {:error, registry_error("does not pass registry validation")}
    end
  end

  defp registry_error(reason) do
    error(
      "invalid_registry",
      "The target registry #{reason}. Fix it manually; bootstrap never overwrites existing files."
    )
  end

  defp default_registry_document(root) do
    %{
      "version" => 1,
      "host" => %{
        "id" => @host_id,
        "state_root" => root <> "-state",
        "polling" => @default_polling,
        "capacity" => @default_capacity,
        "scheduling" => @default_scheduling,
        "tracker_connections" => %{},
        "runners" => %{}
      },
      "targets" => %{}
    }
  end

  defp proposal(config_file, registry_file) do
    %{
      config: if(config_file.status == :missing, do: Renderer.to_yaml(LocalConfig.default_config())),
      registry: if(registry_file.status == :missing, do: Yaml.encode(default_registry_document(Path.dirname(registry_file.path))))
    }
  end

  defp preview_result(view) do
    files = proposed_files(view)

    result = %{
      code: if(files == [], do: "already_configured", else: "setup_required"),
      existing: existing_files(view),
      guidance: guidance(view)
    }

    if files == [] do
      result
    else
      Map.put(result, :confirmation, confirmation_token(view))
      |> Map.put(:files, files)
    end
  end

  defp proposed_files(view) do
    for {kind, path, bytes} <- [
          {:config, view.config_file.path, view.proposal.config},
          {:registry, view.registry_file.path, view.proposal.registry}
        ],
        is_binary(bytes),
        do: %{kind: kind, path: path, action: "create", content: bytes, digest: digest(bytes)}
  end

  defp existing_files(view) do
    for file <- [view.config_file, view.registry_file],
        file.status == :present,
        do: %{kind: file_kind(file, view), path: file.path, digest: file.digest}
  end

  defp file_kind(%{path: path}, view) do
    if path == view.config_file.path, do: :config, else: :registry
  end

  defp confirmation_token(view) do
    @token_prefix <> Base.url_encode64(Jason.encode!(confirmation_payload(view)), padding: false)
  end

  defp confirmation_payload(view) do
    %{
      "format" => @token_format,
      "config" => file_confirmation(view.config_file, view.proposal.config),
      "registry" => file_confirmation(view.registry_file, view.proposal.registry)
    }
  end

  defp file_confirmation(file, proposed_bytes) do
    %{
      "path" => file.path,
      "state" => file.digest && "sha256:#{file.digest}",
      "proposal" => proposed_bytes && "sha256:#{digest(proposed_bytes)}"
    }
  end

  defp decode_confirmation(token) do
    with @token_prefix <> encoded <- token,
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, payload} <- Jason.decode(json),
         %{"format" => @token_format, "config" => %{}, "registry" => %{}} <- payload do
      {:ok, payload}
    else
      _invalid ->
        {:error,
         error(
           "invalid_confirmation",
           "The confirmation token is invalid. Run host bootstrap preview for a fresh preview."
         )}
    end
  end

  defp match_confirmation(expected, view) do
    if expected == confirmation_payload(view) do
      :ok
    else
      {:error,
       error(
         "confirmation_mismatch",
         "The host files changed since the preview. Run host bootstrap preview again and reconfirm."
       )}
    end
  end

  defp commit(view) do
    files = proposed_files(view)

    with :ok <- ensure_root(view.root),
         {:ok, created} <- create_files(files) do
      {:ok,
       %{
         code: "setup_complete",
         created: Enum.map(created, & &1.path),
         existing: existing_files(view),
         guidance: guidance(view)
       }}
    end
  end

  defp ensure_root(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(root),
             :ok <- File.chmod(root, @root_permission) do
          :ok
        else
          _failure -> {:error, write_failed_error()}
        end

      _other ->
        {:error,
         error(
           "unsafe_path",
           "#{root} is not a directory. Remove the symlink or file entry, then run host bootstrap preview again."
         )}
    end
  end

  defp create_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, created} ->
      case create_file(file.path, file.content) do
        :ok -> {:cont, {:ok, [file | created]}}
        {:error, _reason} = failure -> {:halt, failure}
      end
    end)
  end

  defp create_file(path, bytes) do
    case :file.open(path, [:write, :exclusive, :binary]) do
      {:ok, device} ->
        result =
          with :ok <- File.chmod(path, @file_permission),
               :ok <- :file.write(device, bytes),
               :ok <- :file.sync(device),
               :ok <- :file.close(device),
               {:ok, ^bytes} <- File.read(path) do
            :ok
          else
            _failure ->
              :file.close(device)
              {:error, write_failed_error()}
          end

        result

      {:error, _reason} ->
        {:error, write_failed_error()}
    end
  end

  defp write_failed_error do
    error(
      "write_failed",
      "Host file creation failed or a file already existed. Inspect the retained files, then run host bootstrap preview again; existing files are never overwritten."
    )
  end

  defp guidance(view) do
    connections = tracker_connection_guidance(view.registry_document)
    runners = runner_guidance(guidance_runners(view))

    %{
      tracker_connections: connections,
      runners: runners,
      notes: guidance_notes(view, connections, runners)
    }
  end

  defp guidance_runners(view) do
    case get_in(view.registry_document, ["host", "runners"]) do
      runners when is_map(runners) and map_size(runners) > 0 ->
        runners

      _empty_or_missing ->
        view.config |> Map.get("runners", %{}) |> LocalConfig.normalize_keys()
    end
  end

  defp tracker_connection_guidance(document) do
    document
    |> get_in(["host", "tracker_connections"])
    |> guidance_entries()
    |> Enum.map(fn {id, connection} ->
      reference = Map.get(connection, "api_key")

      %{
        id: id,
        kind: Map.get(connection, "kind"),
        credential: credential_status(reference),
        credential_env: env_name(reference) |> ok_value()
      }
    end)
  end

  defp runner_guidance(runners) do
    runners
    |> guidance_entries()
    |> Enum.map(fn {name, runner} ->
      executable = runner_executable(runner)
      %{name: name, executable: executable, available: available?(executable)}
    end)
  end

  defp guidance_entries(map) when is_map(map) do
    map
    |> LocalConfig.normalize_keys()
    |> Enum.filter(fn {_key, value} -> is_map(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp guidance_entries(_value), do: []

  defp runner_executable(%{"command" => [executable | _rest]}) when is_binary(executable), do: executable
  defp runner_executable(%{"kind" => "opencode_server"}), do: "opencode"
  defp runner_executable(_runner), do: nil

  defp available?(executable) when is_binary(executable), do: System.find_executable(executable) != nil
  defp available?(_executable), do: false

  defp credential_status(reference) when is_binary(reference) do
    case env_name(reference) do
      {:ok, name} ->
        if String.trim(System.get_env(name) || "") == "", do: "missing", else: "configured"

      :error ->
        if String.starts_with?(reference, "secret://"), do: "external", else: "unresolved"
    end
  end

  defp credential_status(_reference), do: "unresolved"

  defp env_name(reference) when is_binary(reference) do
    case Regex.run(~r/\A\$([A-Za-z0-9._-]+)\z/, reference, capture: :all_but_first) do
      [name] ->
        {:ok, name}

      _other ->
        case Regex.run(~r/\A\$\{([A-Za-z0-9._-]+)\}\z/, reference, capture: :all_but_first) do
          [name] -> {:ok, name}
          _invalid -> :error
        end
    end
  end

  defp env_name(_reference), do: :error

  defp guidance_notes(view, connections, runners) do
    connection_notes(connections, view.registry_file.path) ++
      config_tracker_notes(view) ++
      runner_notes(runners) ++
      ["New targets start paused and run only after activation."]
  end

  defp connection_notes([], registry_path) do
    [
      "No tracker connections are configured. Add host.tracker_connections entries to #{registry_path} when tracker access is needed."
    ]
  end

  defp connection_notes(connections, _registry_path) do
    Enum.flat_map(connections, fn
      %{id: id, credential: "missing", credential_env: env} when is_binary(env) ->
        ["Tracker connection #{id} cannot authenticate: #{env} is not set. The host still starts without it."]

      %{credential: "missing"} = connection ->
        ["Tracker connection #{connection.id} has an unresolved credential reference and cannot authenticate."]

      _configured ->
        []
    end)
  end

  defp config_tracker_notes(view) do
    case view.config |> get_in(["tracker", "api_key"]) do
      reference when is_binary(reference) ->
        case {env_name(reference), credential_status(reference)} do
          {{:ok, name}, "missing"} ->
            ["#{name} is not set; local runs will not have tracker access until it is provided."]

          _configured_or_external ->
            []
        end

      _missing ->
        []
    end
  end

  defp runner_notes(runners) do
    Enum.flat_map(runners, fn
      %{name: name, available: false, executable: nil} ->
        ["Runner #{name} has no launchable command configured."]

      %{name: name, available: false, executable: executable} when is_binary(executable) ->
        ["Runner #{name} executable #{executable} was not found on PATH; runs selecting it will fail until it is installed."]

      _available ->
        []
    end)
  end

  defp ok_value({:ok, value}), do: value
  defp ok_value(_error), do: nil

  defp digest(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp error(code, next_action), do: %{code: code, next_action: next_action}
end
