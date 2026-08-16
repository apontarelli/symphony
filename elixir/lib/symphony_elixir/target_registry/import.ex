defmodule SymphonyElixir.TargetRegistry.Import do
  @moduledoc false

  alias SymphonyElixir.Config.Schema, as: ConfigSchema
  alias SymphonyElixir.TargetRegistry.Diagnostic
  alias SymphonyElixir.TargetRegistry.Error
  alias SymphonyElixir.TargetRegistry.Preview
  alias SymphonyElixir.TargetRegistry.Schema
  alias SymphonyElixir.TargetRegistry.Target
  alias SymphonyElixir.TargetRegistry.Yaml

  @id_regex ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
  @default_active_states ["Todo", "In Progress", "Merging", "Rework"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @host_runner_fields ~w(
    kind command approval_policy thread_sandbox turn_sandbox_policy
    turn_timeout_ms read_timeout_ms stall_timeout_ms max_concurrent_startups
    agent hostname port config_dir config_path config_content server_auth permissions
    startup_timeout_ms
  )
  @safe_runner_setting_fields ~w(model)
  @safe_execution_profile_fields ~w(model reasoning_effort)
  @safe_reasoning_efforts ~w(minimal none low medium high xhigh max)
  @defaulted_runner_fields %{
    "codex_app_server" => MapSet.new(~w(command model approval_policy thread_sandbox turn_timeout_ms read_timeout_ms stall_timeout_ms execution_profiles)),
    "opencode_server" => MapSet.new(~w(hostname port turn_timeout_ms read_timeout_ms stall_timeout_ms startup_timeout_ms execution_profiles permissions))
  }
  @normalized_validation_command_fields ~w(command name)
  @mapped_runtime_sections ~w(tracker target hooks worker workspace polling quality_gate)
  @hook_fields ~w(after_create before_run after_run before_remove timeout_ms)
  @host_map_containers ~w(polling capacity scheduling tracker_connections runners)
  @repo_owned_sections ~w(
    project workflow docs validation vcs delivery automation capabilities issue_markers harness
  )
  @mapped_quality_fields ~w(enabled source_max_concurrency)
  @redacted "[REDACTED]"
  @encoding_max_depth 64
  @encoding_max_nodes 10_000

  defmodule Result do
    @moduledoc false

    @enforce_keys [
      :source,
      :proposal,
      :snapshot,
      :registry_preview,
      :current_repo_manifest,
      :effective_preview_target,
      :applicable?,
      :import_diagnostics,
      :field_dispositions,
      :source_differences
    ]
    defstruct [
      :source,
      :proposal,
      :snapshot,
      :registry_preview,
      :current_repo_manifest,
      :effective_preview_target,
      applicable?: false,
      import_diagnostics: [],
      field_dispositions: [],
      source_differences: []
    ]

    @type t :: %__MODULE__{}
  end

  @spec preview(binary(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def preview(source_bytes, opts) when is_binary(source_bytes) and is_list(opts) do
    if Keyword.keyword?(opts), do: preview_keyword(source_bytes, opts), else: options_error()
  end

  def preview(source_bytes, _opts) when is_binary(source_bytes), do: options_error()

  def preview(_source_bytes, _opts) do
    {:error, %Error{code: :invalid_type, path: "$.source", message: "import source bytes are required"}}
  end

  defp preview_keyword(source_bytes, opts) do
    with {:ok, input} <- input(source_bytes, opts),
         {:ok, document} <- decode_source(source_bytes),
         :ok <- validate_source_version(document),
         {:ok, runtime} <- runtime(document),
         :ok <- validate_api_key(runtime),
         {:ok, scope, scope_diagnostics} <- map_scope(runtime) do
      source_diagnostics = source_diagnostics(runtime)
      tracker = map(runtime["tracker"])
      runtime_target = map(runtime["target"])
      connection_id = input.connection_id
      target_id = input.target_id

      connection = %{
        "kind" => Map.get(tracker, "kind", "linear"),
        "endpoint" => Map.get(tracker, "endpoint", "https://api.linear.app/graphql"),
        "api_key" => Map.get(tracker, "api_key", "$LINEAR_API_KEY")
      }

      {host, connection_diagnostics} =
        merge_host_entry(input.host, "tracker_connections", connection_id, connection)

      linear = %{
        "connection" => connection_id,
        "scope" => scope,
        "active_states" => label_list(tracker, "active_states", @default_active_states),
        "terminal_states" => label_list(tracker, "terminal_states", @default_terminal_states),
        "required_labels" =>
          union_labels(
            label_list(tracker, "required_labels", []),
            label_list(runtime_target, "required_labels", [])
          )
      }

      worktree = map_worktree(runtime["workspace"], runtime["hooks"], target_id, input.repo_path)
      {host, polling_dispositions, polling_differences} = map_polling(runtime["polling"], host)

      {host, host_capacity_dispositions, host_capacity_differences} =
        map_host_capacity(runtime["worker"], host)

      {host, target_runners, runner_dispositions, runner_diagnostics} =
        map_runners(runtime, host, target_id)

      {concurrency, checks, quality_dispositions} =
        map_capacity_and_quality(runtime, target_id)

      mapping_diagnostics =
        source_diagnostics ++
          scope_diagnostics ++
          tracker_diagnostics(tracker) ++
          label_diagnostics(runtime) ++
          connection_diagnostics ++ runner_diagnostics

      target =
        %{
          "state" => "paused",
          "repo" => %{"path" => input.repo_path, "manifest" => "symphony.yml"},
          "worktree" => worktree,
          "linear" => linear,
          "runners" => target_runners,
          "concurrency" => concurrency,
          "budgets" => %{},
          "checks" => checks,
          "scheduling" => %{}
        }
        |> maybe_put("display_name", target_display_name(runtime_target))

      proposal = %{"version" => 1, "host" => host, "targets" => %{target_id => target}}

      with {:ok, snapshot} <- Schema.validate(proposal) do
        import_diagnostics =
          mapping_diagnostics
          |> Kernel.++(import_preflight(snapshot, proposal, runtime, target_id))
          |> Enum.uniq()
          |> Enum.sort_by(&{&1.path, &1.code, &1.message})

        registry_preview = Preview.preview(snapshot, encode_compact(proposal))
        snapshot_target = Map.get(snapshot.targets, target_id)
        repo_markers = get_in(input.current_repo_manifest, ["issue_markers", "labels"])

        effective_preview_target =
          put_in(
            target,
            ["linear", "required_labels"],
            union_labels(linear["required_labels"], repo_markers)
          )

        {authority_dispositions, authority_differences} =
          repository_authority(document, input.current_repo_manifest)

        {ignored_dispositions, ignored_differences} = ignored_runtime_fields(runtime)

        dispositions =
          tracker_dispositions(runtime, tracker, connection_id, target_id, scope) ++
            polling_dispositions ++
            host_capacity_dispositions ++
            workspace_dispositions(runtime["workspace"], target_id) ++
            hook_dispositions(runtime["hooks"], target_id) ++
            runner_dispositions ++
            quality_dispositions ++ authority_dispositions ++ ignored_dispositions

        {:ok,
         %Result{
           source: %{
             path: input.source_path,
             checksum: Preview.generation(source_bytes)
           },
           proposal: proposal,
           snapshot: snapshot,
           registry_preview: registry_preview,
           current_repo_manifest: input.current_repo_manifest,
           effective_preview_target: effective_preview_target,
           applicable?:
             import_diagnostics == [] and snapshot.globally_valid? and
               expected_incomplete_target?(snapshot_target, target_id),
           import_diagnostics: import_diagnostics,
           field_dispositions: dispositions,
           source_differences:
             polling_differences ++
               host_capacity_differences ++ authority_differences ++ ignored_differences
         }}
      end
    end
  end

  @spec encode_preview(term()) :: binary()
  def encode_preview(result) do
    encode_public(result, &import_projection/1, &public_import_projection/1)
  end

  @spec encode_repo_policy_preview(term()) :: binary()
  def encode_repo_policy_preview(result) do
    encode_public(result, &repo_policy_projection/1, &public_repo_policy_projection/1)
  end

  defp import_projection(%Result{} = result) do
    %{
      valid?: result.applicable?,
      targets: result.effective_preview_target,
      changes: disposition_projections(result.field_dispositions),
      diagnostics: result.import_diagnostics,
      host: redact_host_authority(result.proposal),
      runtime: preview_projection(result.registry_preview),
      source_changed: source_projection(result.source),
      before: difference_projections(result.source_differences)
    }
  end

  defp import_projection(_result), do: @redacted

  defp public_import_projection(%{
         valid?: applicable?,
         targets: effective_preview_target,
         changes: dispositions,
         diagnostics: diagnostics,
         host: proposal,
         runtime: registry_preview,
         source_changed: source,
         before: differences
       }) do
    %{
      "applicable?" => applicable?,
      "effective_preview_target" => effective_preview_target,
      "field_dispositions" => public_dispositions(dispositions),
      "import_diagnostics" => diagnostics,
      "proposal" => proposal,
      "registry_preview" => public_preview(registry_preview),
      "source" => public_source(source),
      "source_differences" => public_differences(differences)
    }
  end

  defp public_import_projection(_projection), do: @redacted

  defp repo_policy_projection(%Result{} = result) do
    %{
      manifest: get_in(result.current_repo_manifest, ["issue_markers", "labels"]),
      required_labels: get_in(result.effective_preview_target, ["linear", "required_labels"]),
      policy_hash: nil,
      changes: difference_projections(result.source_differences)
    }
  end

  defp repo_policy_projection(_result), do: @redacted

  defp public_repo_policy_projection(%{
         manifest: manifest,
         required_labels: labels,
         policy_hash: policy_hash,
         changes: differences
       }) do
    %{
      "current_repo_manifest" => %{"issue_markers" => %{"labels" => manifest}},
      "effective_required_labels" => labels,
      "policy_hash" => policy_hash,
      "source_differences" =>
        differences
        |> public_differences()
        |> Enum.filter(fn difference ->
          case difference do
            %{source_path: "$.issue_markers" <> _rest} -> true
            _other -> false
          end
        end)
    }
  end

  defp public_repo_policy_projection(_projection), do: @redacted

  defp source_projection(source) when is_map(source) do
    [
      @redacted,
      Map.get(source, :checksum, Map.get(source, "checksum"))
    ]
  end

  defp source_projection(_source), do: @redacted
  defp public_source([path, checksum]), do: %{"path" => path, "checksum" => checksum}
  defp public_source(_source), do: @redacted

  defp disposition_projections(dispositions) when is_list(dispositions) do
    Enum.map(dispositions, fn
      %{source_path: source_path, destination_path: destination_path, action: action} ->
        [trusted_path(source_path), trusted_path(destination_path), action]

      _malformed ->
        @redacted
    end)
  end

  defp disposition_projections(_dispositions), do: @redacted

  defp public_dispositions(dispositions) when is_list(dispositions) do
    Enum.map(dispositions, fn
      [source_path, destination_path, action] ->
        %{
          source_path: source_path,
          destination_path: destination_path,
          action: action
        }

      _malformed ->
        @redacted
    end)
  end

  defp public_dispositions(_dispositions), do: @redacted

  defp difference_projections(differences) when is_list(differences) do
    Enum.map(differences, fn
      %{
        source_path: source_path,
        destination_path: destination_path,
        classification: classification,
        source: source,
        effective: effective,
        reason: reason
      } ->
        [
          trusted_path(source_path),
          trusted_path(destination_path),
          classification,
          source,
          effective,
          reason
        ]

      _malformed ->
        @redacted
    end)
  end

  defp difference_projections(_differences), do: @redacted

  defp public_differences(differences) when is_list(differences) do
    Enum.map(differences, fn
      [source_path, destination_path, classification, source, effective, reason] ->
        %{
          source_path: source_path,
          destination_path: destination_path,
          classification: classification,
          source: source,
          effective: effective,
          reason: reason
        }

      _malformed ->
        @redacted
    end)
  end

  defp public_differences(_differences), do: @redacted

  defp preview_projection(%Preview{} = preview) do
    preview
    |> Map.from_struct()
    |> rename_key(:source_changed?, :source_changed)
    |> rename_key(:globally_valid?, :globally_valid)
    |> rename_key(:diff, :changes)
    |> rename_key(:impact, :host)
    |> Map.update(:changes, [], &change_projections/1)
    |> Map.update(:host, %{}, &impact_projection/1)
  end

  defp preview_projection(_preview), do: @redacted

  defp public_preview(preview) when is_map(preview) do
    preview
    |> rename_key(:source_changed, :source_changed?)
    |> rename_key(:globally_valid, :globally_valid?)
    |> rename_key(:changes, :diff)
    |> rename_key(:host, :impact)
  end

  defp public_preview(_preview), do: @redacted

  defp rename_key(map, source, destination) do
    {value, remaining} = Map.pop!(map, source)
    Map.put(remaining, destination, value)
  end

  defp impact_projection(impact) when is_map(impact) do
    Map.new(impact, fn
      {category, %{changes: changes} = value} ->
        {category, %{value | changes: change_projections(changes)}}

      entry ->
        entry
    end)
  end

  defp impact_projection(_impact), do: @redacted

  defp change_projections(changes) when is_list(changes) do
    Enum.map(changes, fn
      %{path: path} = change when is_binary(path) ->
        change
        |> redact_command_change(path)
        |> Map.put(:path, trusted_path(path))

      _malformed ->
        @redacted
    end)
  end

  defp change_projections(_changes), do: @redacted

  defp redact_command_change(change, path) do
    if String.ends_with?(path, ".command") do
      change
      |> redact_present(:before)
      |> redact_present(:after)
    else
      change
    end
  end

  defp redact_present(map, key) do
    if Map.has_key?(map, key), do: Map.put(map, key, @redacted), else: map
  end

  defp trusted_path(nil), do: nil

  defp trusted_path("$.issue_markers.labels" = path) do
    %Diagnostic{
      severity: :info,
      scope: :registry,
      path: "$",
      code: :public_import_repo_path,
      message: path
    }
  end

  defp trusted_path(path) when is_binary(path) do
    if String.valid?(path) do
      %Diagnostic{
        severity: :info,
        scope: :registry,
        path: path,
        code: :public_projection_path,
        message: ""
      }
    else
      @redacted
    end
  end

  defp trusted_path(_path), do: @redacted

  defp redact_host_authority(proposal) when is_map(proposal) do
    Map.update(proposal, "host", @redacted, &redact_host/1)
  end

  defp redact_host_authority(_proposal), do: @redacted

  defp redact_host(host) when is_map(host) do
    host
    |> Map.update("tracker_connections", %{}, fn
      connections when is_map(connections) ->
        Map.new(connections, fn {id, connection} ->
          {id, redact_connection(connection)}
        end)

      _malformed ->
        @redacted
    end)
    |> Map.update("runners", %{}, fn
      runners when is_map(runners) ->
        Map.new(runners, fn {id, runner} -> {id, redact_host_runner(runner)} end)

      _malformed ->
        @redacted
    end)
  end

  defp redact_host(_host), do: @redacted

  defp redact_connection(connection) when is_map(connection) do
    if Map.has_key?(connection, "api_key"),
      do: Map.put(connection, "api_key", @redacted),
      else: connection
  end

  defp redact_connection(_connection), do: @redacted

  defp redact_host_runner(runner) when is_map(runner) do
    runner
    |> redact_present("command")
    |> Map.update("turn_sandbox_policy", nil, &redact_writable_roots/1)
  end

  defp redact_host_runner(_runner), do: @redacted

  defp redact_writable_roots(policy) when is_map(policy) do
    if Map.has_key?(policy, "writableRoots"),
      do: Map.put(policy, "writableRoots", @redacted),
      else: policy
  end

  defp redact_writable_roots(_policy), do: @redacted

  defp encode_public(result, projection, public_projection) do
    public =
      result
      |> projection.()
      |> prepare_projection()
      |> Preview.redact()
      |> unwrap_trusted_paths()
      |> public_projection.()
      |> json_value()

    encode_json(public, pretty: true)
  rescue
    _exception -> "\"[REDACTED]\""
  end

  defp prepare_projection(value) do
    {prepared, _remaining} = prepare_projection(value, @encoding_max_depth, @encoding_max_nodes)
    prepared
  end

  defp prepare_projection(_value, depth, remaining) when depth <= 0 or remaining <= 0,
    do: {@redacted, max(remaining - 1, 0)}

  defp prepare_projection(%Diagnostic{} = diagnostic, _depth, remaining) do
    if valid_diagnostic?(diagnostic),
      do: {diagnostic, remaining - 1},
      else: {@redacted, remaining - 1}
  end

  defp prepare_projection(%{__struct__: _module} = struct, depth, remaining) do
    struct
    |> Map.from_struct()
    |> prepare_projection(depth, remaining)
  end

  defp prepare_projection(value, depth, remaining) when is_map(value) do
    if map_size(value) >= remaining do
      {@redacted, remaining - 1}
    else
      case safe_map_entries(value) do
        {:ok, entries} ->
          Enum.reduce_while(
            entries,
            {%{}, remaining - 1},
            &prepare_map_entry(&1, &2, depth)
          )

        :error ->
          {@redacted, remaining - 1}
      end
    end
  end

  defp prepare_projection(value, depth, remaining) when is_list(value) do
    Enum.reduce_while(value, {[], remaining - 1}, fn nested, {prepared, left} ->
      if left <= 0 do
        {:halt, {@redacted, 0}}
      else
        {nested, left} = prepare_projection(nested, depth - 1, left)
        {:cont, {[nested | prepared], left}}
      end
    end)
    |> then(fn
      {prepared, left} when is_list(prepared) -> {Enum.reverse(prepared), left}
      exhausted -> exhausted
    end)
  end

  defp prepare_projection(value, depth, remaining) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> prepare_projection(depth - 1, remaining - 1)
  end

  defp prepare_projection(value, _depth, remaining) when is_binary(value),
    do: {if(String.valid?(value), do: value, else: @redacted), remaining - 1}

  defp prepare_projection(value, _depth, remaining) when is_float(value),
    do: {if(finite_float?(value), do: value, else: @redacted), remaining - 1}

  defp prepare_projection(value, _depth, remaining)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_atom(value),
       do: {value, remaining - 1}

  defp prepare_projection(_value, _depth, remaining), do: {@redacted, remaining - 1}

  defp prepare_map_entry(_entry, {_prepared, left}, _depth) when left <= 0,
    do: {:halt, {@redacted, 0}}

  defp prepare_map_entry({key, nested}, {prepared, left}, depth) do
    {nested, left} = prepare_projection(nested, depth - 1, left)
    {:cont, {Map.put(prepared, key, nested), left}}
  end

  defp safe_map_entries(map) do
    entries =
      map
      |> Enum.map(fn {key, value} -> {public_object_key(key), key, value} end)
      |> Enum.sort_by(fn {normalized, _key, _value} -> normalized end)

    normalized = Enum.map(entries, &elem(&1, 0))

    if Enum.any?(normalized, &is_nil/1) or Enum.uniq(normalized) != normalized,
      do: :error,
      else: {:ok, Enum.map(entries, fn {_normalized, key, value} -> {key, value} end)}
  end

  defp public_object_key(key) when is_binary(key) do
    if String.valid?(key), do: key, else: nil
  end

  defp public_object_key(key) when is_atom(key), do: key |> Atom.to_string() |> public_object_key()
  defp public_object_key(_key), do: nil

  defp valid_diagnostic?(%Diagnostic{} = diagnostic) do
    diagnostic.severity in [:error, :warning, :info] and
      valid_diagnostic_scope?(diagnostic.scope) and
      is_binary(diagnostic.path) and String.valid?(diagnostic.path) and
      is_atom(diagnostic.code) and
      is_binary(diagnostic.message) and String.valid?(diagnostic.message)
  end

  defp valid_diagnostic_scope?(scope) when scope in [:registry, :host], do: true
  defp valid_diagnostic_scope?({:target, id}), do: valid_id?(id)
  defp valid_diagnostic_scope?(_scope), do: false

  defp unwrap_trusted_paths(%Diagnostic{
         code: :public_import_repo_path,
         message: path
       }),
       do: path

  defp unwrap_trusted_paths(%Diagnostic{code: :public_projection_path, path: path}), do: path

  defp unwrap_trusted_paths(%Diagnostic{} = diagnostic), do: diagnostic

  defp unwrap_trusted_paths(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, unwrap_trusted_paths(nested)} end)

  defp unwrap_trusted_paths([]), do: []

  defp unwrap_trusted_paths([head | tail]) do
    case unwrap_trusted_paths(tail) do
      values when is_list(values) -> [unwrap_trusted_paths(head) | values]
      _improper -> @redacted
    end
  end

  defp unwrap_trusted_paths(value), do: value

  defp json_value(%Diagnostic{} = diagnostic) do
    diagnostic
    |> Map.from_struct()
    |> json_value()
  end

  defp json_value(map) when is_map(map) do
    {:ok, entries} = safe_map_entries(map)

    Map.new(entries, fn {key, nested} ->
      {public_object_key(key), json_value(nested)}
    end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value({:target, id}), do: %{"target" => json_value(id)}

  defp json_value(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: @redacted)

  defp json_value(value) when is_float(value),
    do: if(finite_float?(value), do: value, else: @redacted)

  defp json_value(value) when is_atom(value),
    do: if(value in [true, false, nil], do: value, else: Atom.to_string(value))

  defp json_value(value) when is_integer(value), do: value

  defp encode_compact(value) do
    value
    |> prepare_projection()
    |> json_value()
    |> encode_json([])
  end

  defp encode_json(value, opts) do
    result = value |> ordered_json() |> Jason.encode(opts)
    if elem(result, 0) == :ok, do: elem(result, 1), else: "\"[REDACTED]\""
  end

  defp ordered_json(map) when is_map(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> {key, ordered_json(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered_json(list) when is_list(list), do: Enum.map(list, &ordered_json/1)
  defp ordered_json(value), do: value

  defp finite_float?(value) do
    <<_sign::1, exponent::11, _fraction::52>> = <<value::float-64>>
    exponent != 0x7FF
  end

  defp input(source_bytes, opts) do
    values = %{
      source_bytes: source_bytes,
      source_path: Keyword.get(opts, :source_path),
      target_id: Keyword.get(opts, :target_id),
      repo_path: Keyword.get(opts, :repo_path),
      connection_id: Keyword.get(opts, :connection_id, "linear"),
      current_repo_manifest: Keyword.get(opts, :current_repo_manifest),
      host: Keyword.get(opts, :host)
    }

    cond do
      not valid_nonblank_string?(values.source_path) ->
        input_string_error(:source_path)

      not valid_id?(values.target_id) ->
        input_id_error(:target_id)

      not valid_nonblank_string?(values.repo_path) ->
        input_string_error(:repo_path)

      Path.type(values.repo_path) != :absolute ->
        {:error,
         %Error{
           code: :invalid_value,
           path: "$.repo_path",
           message: "repo_path must be absolute"
         }}

      not valid_id?(values.connection_id) ->
        input_id_error(:connection_id)

      not valid_host?(values.host) ->
        {:error,
         %Error{
           code: :invalid_type,
           path: "$.host",
           message: "host must be bounded strict JSON with required map containers"
         }}

      not composition_manifest_shape_parity?(values.current_repo_manifest) ->
        {:error,
         %Error{
           code: :invalid_type,
           path: "$.current_repo_manifest",
           message: "current_repo_manifest must be a prevalidated normalized version 1 JSON map"
         }}

      true ->
        {:ok, values}
    end
  end

  defp valid_host?(host) when is_map(host) do
    Enum.all?(@host_map_containers, &is_map(host[&1])) and strict_json_safe?(host)
  end

  defp valid_host?(_host), do: false

  defp composition_manifest_shape_parity?(manifest) when is_map(manifest) do
    manifest["version"] == 1 and
      Enum.all?(@repo_owned_sections, &is_map(manifest[&1])) and
      valid_nonblank_string?(get_in(manifest, ["project", "repository"])) and
      valid_utf8_string_list?(get_in(manifest, ["issue_markers", "labels"])) and
      valid_manifest_validation_commands?(get_in(manifest, ["validation", "commands"])) and
      valid_manifest_auto_land?(Map.get(manifest, "auto_land")) and
      strict_json_safe?(manifest)
  end

  defp composition_manifest_shape_parity?(_manifest), do: false

  defp valid_manifest_validation_commands?(commands) when is_list(commands),
    do: Enum.all?(commands, &valid_manifest_validation_command?/1)

  defp valid_manifest_validation_commands?(_commands), do: false

  defp valid_manifest_validation_command?(command) when is_map(command) do
    Enum.sort(Map.keys(command)) == @normalized_validation_command_fields and
      valid_nonblank_string?(command["name"]) and
      valid_nonblank_string?(command["command"])
  end

  defp valid_manifest_validation_command?(_command), do: false

  defp valid_manifest_auto_land?(nil), do: true

  defp valid_manifest_auto_land?(auto_land) when is_map(auto_land),
    do: valid_utf8_string_list?(Map.get(auto_land, "required_checks", []))

  defp valid_manifest_auto_land?(_auto_land), do: false

  defp valid_utf8_string_list?(values) when is_list(values),
    do: Enum.all?(values, &(is_binary(&1) and String.valid?(&1)))

  defp valid_utf8_string_list?(_values), do: false

  defp strict_json_safe?(value) do
    match?({:ok, _remaining}, strict_json_safe?(value, @encoding_max_depth, @encoding_max_nodes))
  end

  defp strict_json_safe?(_value, _depth, remaining) when remaining <= 0, do: :error
  defp strict_json_safe?(_value, depth, _remaining) when depth <= 0, do: :error

  defp strict_json_safe?(value, depth, remaining) when is_map(value) do
    if map_size(value) >= remaining do
      :error
    else
      Enum.reduce_while(
        value,
        {:ok, remaining - 1},
        &strict_json_map_entry(&1, &2, depth)
      )
    end
  end

  defp strict_json_safe?(value, depth, remaining) when is_list(value) do
    strict_json_list(value, depth, remaining - 1)
  end

  defp strict_json_safe?(value, _depth, remaining) when is_binary(value) do
    if String.valid?(value), do: {:ok, remaining - 1}, else: :error
  end

  defp strict_json_safe?(value, _depth, remaining) when is_float(value) do
    if finite_float?(value), do: {:ok, remaining - 1}, else: :error
  end

  defp strict_json_safe?(value, _depth, remaining)
       when is_nil(value) or is_boolean(value) or is_integer(value),
       do: {:ok, remaining - 1}

  defp strict_json_safe?(_value, _depth, _remaining), do: :error
  defp strict_json_list([], _depth, remaining), do: {:ok, remaining}

  defp strict_json_list([nested | rest], depth, remaining) do
    case strict_json_safe?(nested, depth - 1, remaining) do
      {:ok, next} -> strict_json_list(rest, depth, next)
      :error -> :error
    end
  end

  defp strict_json_list(_improper, _depth, _remaining), do: :error

  defp strict_json_map_entry({key, nested}, {:ok, left}, depth) when is_binary(key) do
    if String.valid?(key),
      do: strict_json_step(nested, depth, left),
      else: {:halt, :error}
  end

  defp strict_json_map_entry(_invalid, _state, _depth), do: {:halt, :error}

  defp strict_json_step(nested, depth, left) do
    case strict_json_safe?(nested, depth - 1, left) do
      {:ok, next} -> {:cont, {:ok, next}}
      :error -> {:halt, :error}
    end
  end

  defp options_error do
    {:error,
     %Error{
       code: :invalid_type,
       path: "$.options",
       message: "options must be a keyword list"
     }}
  end

  defp input_string_error(key) do
    {:error,
     %Error{
       code: :invalid_type,
       path: "$.#{key}",
       message: "#{key} must be a non-blank valid UTF-8 string"
     }}
  end

  defp input_id_error(key) do
    {:error,
     %Error{
       code: :invalid_id,
       path: "$.#{key}",
       message: "#{key} must match the registry ID grammar"
     }}
  end

  defp validate_source_version(%{"version" => 1}), do: :ok
  defp validate_source_version(document) when not is_map_key(document, "version"), do: :ok

  defp validate_source_version(_document) do
    {:error,
     %Error{
       code: :unsupported_version,
       path: "$.version",
       message: "import source version must be integer 1"
     }}
  end

  defp source_diagnostics(runtime) do
    section_shape_diagnostics(runtime) ++
      tracker_field_diagnostics(map(runtime["tracker"])) ++
      target_field_diagnostics(map(runtime["target"])) ++
      hook_field_diagnostics(map(runtime["hooks"])) ++
      worker_field_diagnostics(map(runtime["worker"])) ++
      workspace_field_diagnostics(map(runtime["workspace"])) ++
      polling_field_diagnostics(map(runtime["polling"])) ++
      agent_field_diagnostics(map(runtime["agent"])) ++
      quality_field_diagnostics(map(runtime["quality_gate"]))
  end

  defp section_shape_diagnostics(runtime) do
    Enum.flat_map(@mapped_runtime_sections, fn section ->
      case Map.fetch(runtime, section) do
        :error ->
          []

        {:ok, value} when is_map(value) ->
          []

        {:ok, _invalid} ->
          [
            import_diagnostic(
              "$.runtime.#{section}",
              :invalid_type,
              "runtime #{section} must be a map"
            )
          ]
      end
    end)
  end

  defp tracker_field_diagnostics(tracker) do
    nonblank_string_field_diagnostics(
      tracker,
      ~w(kind endpoint),
      "$.runtime.tracker"
    )
  end

  defp target_field_diagnostics(target) do
    nonblank_string_field_diagnostics(
      target,
      ~w(type kind display_name name),
      "$.runtime.target"
    )
  end

  defp hook_field_diagnostics(hooks) do
    unknown =
      hooks
      |> Map.keys()
      |> Enum.reject(&(&1 in @hook_fields))
      |> Enum.sort()
      |> Enum.map(fn field ->
        import_diagnostic(
          "$.runtime.hooks.#{field}",
          :unknown_key,
          "runtime hook field is not supported"
        )
      end)

    commands =
      Enum.flat_map(
        ~w(after_create before_run after_run before_remove),
        &valid_utf8_field_diagnostics(hooks, &1, "$.runtime.hooks")
      )

    unknown ++
      commands ++
      positive_integer_field_diagnostics(hooks, ["timeout_ms"], "$.runtime.hooks")
  end

  defp worker_field_diagnostics(worker) do
    positive_integer_field_diagnostics(
      worker,
      ~w(max_concurrent_agents_per_host max_concurrent_startups_per_host),
      "$.runtime.worker"
    )
  end

  defp workspace_field_diagnostics(workspace) do
    optional_field_diagnostics(workspace, "root", "$.runtime.workspace", fn
      value when is_binary(value) ->
        cond do
          not String.valid?(value) or String.trim(value) == "" -> :invalid_value
          Path.type(value) != :absolute -> :invalid_value
          true -> nil
        end

      _invalid ->
        :invalid_type
    end)
  end

  defp polling_field_diagnostics(polling) do
    positive_integer_field_diagnostics(polling, ["interval_ms"], "$.runtime.polling")
  end

  defp agent_field_diagnostics(agent) do
    limits =
      positive_integer_field_diagnostics(
        agent,
        ~w(max_concurrent_agents max_concurrent_startups max_turns),
        "$.runtime.agent"
      )

    state_limits =
      case Map.fetch(agent, "max_concurrent_agents_by_state") do
        :error ->
          []

        {:ok, values} when is_map(values) ->
          values
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.flat_map(fn {state, limit} ->
            path = "$.runtime.agent.max_concurrent_agents_by_state.#{state}"

            cond do
              not valid_nonblank_string?(state) ->
                [import_diagnostic(path, :invalid_type, "state capacity key must be a string")]

              not (is_integer(limit) and limit > 0) ->
                [import_diagnostic(path, :invalid_value, "state capacity must be a positive integer")]

              true ->
                []
            end
          end)

        {:ok, _invalid} ->
          [
            import_diagnostic(
              "$.runtime.agent.max_concurrent_agents_by_state",
              :invalid_type,
              "state capacities must be a map"
            )
          ]
      end

    limits ++ state_limits
  end

  defp quality_field_diagnostics(quality) do
    enabled =
      optional_field_diagnostics(quality, "enabled", "$.runtime.quality_gate", fn value ->
        if is_boolean(value), do: nil, else: :invalid_type
      end)

    enabled ++
      positive_integer_field_diagnostics(
        quality,
        ["source_max_concurrency"],
        "$.runtime.quality_gate"
      )
  end

  defp nonblank_string_field_diagnostics(map, fields, path) do
    Enum.flat_map(fields, &nonblank_string_field_diagnostic(map, &1, path))
  end

  defp positive_integer_field_diagnostics(map, fields, path) do
    Enum.flat_map(fields, &positive_integer_field_diagnostic(map, &1, path))
  end

  defp valid_utf8_field_diagnostics(map, field, path),
    do: optional_field_diagnostics(map, field, path, &valid_utf8_string_error/1)

  defp nonblank_string_field_diagnostic(map, field, path),
    do: optional_field_diagnostics(map, field, path, &nonblank_string_error/1)

  defp positive_integer_field_diagnostic(map, field, path),
    do: optional_field_diagnostics(map, field, path, &positive_integer_error/1)

  defp valid_utf8_string_error(value) when is_binary(value),
    do: if(String.valid?(value), do: nil, else: :invalid_type)

  defp valid_utf8_string_error(_value), do: :invalid_type

  defp nonblank_string_error(value) when is_binary(value),
    do: if(valid_nonblank_string?(value), do: nil, else: :invalid_value)

  defp nonblank_string_error(_value), do: :invalid_type

  defp positive_integer_error(value) when is_integer(value),
    do: if(value > 0, do: nil, else: :invalid_value)

  defp positive_integer_error(_value), do: :invalid_type

  defp optional_field_diagnostics(map, field, path, validator) do
    case Map.fetch(map, field) do
      :error ->
        []

      {:ok, value} ->
        case validator.(value) do
          nil ->
            []

          code ->
            [
              import_diagnostic(
                "#{path}.#{field}",
                code,
                "runtime field does not match the supported type or range"
              )
            ]
        end
    end
  end

  defp validate_api_key(runtime) do
    case Map.get(map(runtime["tracker"]), "api_key") do
      nil ->
        :ok

      "$" <> name when name != "" ->
        if Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, name),
          do: :ok,
          else: invalid_api_key_error()

      _resolved_or_invalid ->
        invalid_api_key_error()
    end
  end

  defp invalid_api_key_error do
    {:error,
     %Error{
       code: :invalid_value,
       path: "$.runtime.tracker.api_key",
       message: "runtime tracker API key must be an unresolved environment reference"
     }}
  end

  defp tracker_diagnostics(%{"kind" => kind}) when is_binary(kind) and kind != "linear" do
    [
      import_diagnostic(
        "$.runtime.tracker.kind",
        :invalid_value,
        "only the linear tracker kind can be imported"
      )
    ]
  end

  defp tracker_diagnostics(_tracker), do: []

  defp label_diagnostics(runtime) do
    tracker = map(runtime["tracker"])
    target = map(runtime["target"])

    label_field_diagnostics(
      tracker,
      ~w(active_states terminal_states required_labels),
      "$.runtime.tracker"
    ) ++
      label_field_diagnostics(
        target,
        ["required_labels"],
        "$.runtime.target"
      )
  end

  defp label_field_diagnostics(map, fields, path) do
    Enum.flat_map(fields, fn field ->
      case Map.fetch(map, field) do
        :error ->
          []

        {:ok, values} when is_list(values) ->
          label_entries_diagnostics(values, field, path)

        {:ok, _invalid} ->
          [
            import_diagnostic(
              "#{path}.#{field}",
              :invalid_type,
              "#{field} must be a list"
            )
          ]
      end
    end)
  end

  defp label_entries_diagnostics(values, field, path) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(&label_entry_diagnostics(&1, field, path))
  end

  defp label_entry_diagnostics({value, index}, field, path) when is_binary(value) do
    if valid_nonblank_string?(value) do
      []
    else
      [
        import_diagnostic(
          "#{path}.#{field}[#{index}]",
          :invalid_value,
          "#{field} entries must be non-blank valid UTF-8 strings"
        )
      ]
    end
  end

  defp label_entry_diagnostics({_invalid, index}, field, path) do
    [
      import_diagnostic(
        "#{path}.#{field}[#{index}]",
        :invalid_type,
        "#{field} entries must be strings"
      )
    ]
  end

  defp label_list(map, field, default) when is_map(map) do
    case Map.fetch(map, field) do
      :error -> default
      {:ok, values} -> values
    end
  end

  defp decode_source(source_bytes) do
    case Yaml.decode(source_bytes) do
      {:ok, document} -> {:ok, document}
      {:error, error} -> {:error, yaml_error(error)}
    end
  end

  defp yaml_error(error) do
    %Error{
      code: error.code,
      path: error.path,
      message: error.message
    }
  end

  defp runtime(%{"runtime" => runtime}) when is_map(runtime), do: {:ok, runtime}

  defp runtime(%{"runtime" => _runtime}) do
    {:error, %Error{code: :invalid_type, path: "$.runtime", message: "runtime must be a map"}}
  end

  defp runtime(_document) do
    {:error, %Error{code: :missing_required_field, path: "$.runtime", message: "runtime is required"}}
  end

  defp map_scope(runtime) do
    tracker = map(runtime["tracker"] || %{})
    target = map(runtime["target"])

    diagnostics =
      selector_diagnostics(tracker, "$.runtime.tracker") ++
        selector_diagnostics(target, "$.runtime.target")

    candidates =
      (tracker_scope_candidates(tracker) ++ target_scope_candidates(target))
      |> Enum.uniq()

    case candidates do
      [scope] ->
        {:ok, scope, diagnostics}

      [] when diagnostics != [] ->
        {:ok, %{}, diagnostics}

      [] ->
        {:ok, %{},
         [
           import_diagnostic(
             "$.runtime",
             :invalid_scope,
             "runtime must select one supported tracker scope"
           )
         ]}

      _many ->
        {:ok, %{},
         diagnostics ++
           [
             import_diagnostic(
               "$.runtime.tracker",
               :ambiguous_import_scope,
               "runtime selects more than one tracker scope"
             )
           ]}
    end
  end

  defp tracker_scope_candidates(tracker) do
    [
      scope_candidate(tracker, "project_id", "project"),
      scope_candidate(tracker, "project_slug", "project"),
      scope_candidate(tracker, "team_key", "team"),
      scope_candidate(tracker, "query_file", "query"),
      issue_scope_candidate(tracker["issue_ids"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp target_scope_candidates(target) when is_map(target) do
    case target["type"] || target["kind"] do
      "project" ->
        [
          scope_candidate(target, "project_id", "project"),
          scope_candidate(target, "project_slug", "project")
        ]
        |> Enum.reject(&is_nil/1)

      "team" ->
        Enum.reject([scope_candidate(target, "team_key", "team")], &is_nil/1)

      "query" ->
        Enum.reject([scope_candidate(target, "query_file", "query")], &is_nil/1)

      "issues" ->
        Enum.reject([issue_scope_candidate(target["issue_ids"])], &is_nil/1)

      _missing_or_unknown ->
        []
    end
  end

  defp scope_candidate(map, field, type) do
    case map[field] do
      value when is_binary(value) ->
        if valid_nonblank_string?(value),
          do: %{"type" => type, field => value},
          else: nil

      _missing_or_invalid ->
        nil
    end
  end

  defp issue_scope_candidate(values) when is_list(values) and values != [] do
    if Enum.all?(values, &valid_nonblank_string?/1),
      do: %{"type" => "issues", "issue_ids" => values},
      else: nil
  end

  defp issue_scope_candidate(_values), do: nil

  defp selector_diagnostics(selector, path) when is_map(selector) do
    string_diagnostics =
      Enum.flat_map(
        ~w(project_id project_slug team_key query_file),
        &selector_field_diagnostics(selector, &1, path)
      )

    string_diagnostics ++ issue_ids_diagnostics(selector, path)
  end

  defp selector_field_diagnostics(selector, field, path) do
    case Map.fetch(selector, field) do
      :error ->
        []

      {:ok, value} when is_binary(value) ->
        if valid_nonblank_string?(value) do
          []
        else
          [
            import_diagnostic(
              "#{path}.#{field}",
              :invalid_value,
              "tracker selector must be a non-blank valid UTF-8 string"
            )
          ]
        end

      {:ok, _invalid} ->
        [
          import_diagnostic(
            "#{path}.#{field}",
            :invalid_type,
            "tracker selector must be a string"
          )
        ]
    end
  end

  defp issue_ids_diagnostics(selector, path) do
    case Map.fetch(selector, "issue_ids") do
      :error ->
        []

      {:ok, []} ->
        [
          import_diagnostic(
            "#{path}.issue_ids",
            :invalid_value,
            "issue_ids must be a non-empty list"
          )
        ]

      {:ok, values} when is_list(values) ->
        values
        |> Enum.with_index()
        |> Enum.flat_map(&issue_id_diagnostics(&1, path))

      {:ok, _invalid} ->
        [
          import_diagnostic(
            "#{path}.issue_ids",
            :invalid_type,
            "issue_ids must be a list"
          )
        ]
    end
  end

  defp issue_id_diagnostics({value, index}, path) when is_binary(value) do
    if valid_nonblank_string?(value) do
      []
    else
      [
        import_diagnostic(
          "#{path}.issue_ids[#{index}]",
          :invalid_value,
          "issue ID must be a non-blank valid UTF-8 string"
        )
      ]
    end
  end

  defp issue_id_diagnostics({_invalid, index}, path) do
    [
      import_diagnostic(
        "#{path}.issue_ids[#{index}]",
        :invalid_type,
        "issue ID must be a string"
      )
    ]
  end

  defp map_worktree(workspace, hooks, target_id, repo_path) do
    root =
      case workspace do
        %{"root" => source_root} when is_binary(source_root) ->
          Path.join(source_root, target_id)

        %{"root" => invalid_root} ->
          invalid_root

        _missing ->
          repo_path <> "-worktrees/" <> target_id
      end

    mapped_hooks = if is_nil(hooks), do: %{}, else: hooks

    %{
      "root" => root,
      "strategy" => "per_issue",
      "hooks" => mapped_hooks
    }
  end

  defp merge_host_entry(host, container_name, id, imported) do
    container = Map.fetch!(host, container_name)

    case Map.fetch(container, id) do
      :error ->
        {Map.put(host, container_name, Map.put(container, id, imported)), []}

      {:ok, ^imported} ->
        {host, []}

      {:ok, _conflicting} ->
        path = "$.host.#{container_name}.#{id}"

        {host,
         [
           import_diagnostic(
             path,
             :import_conflict,
             "imported host entry conflicts with the existing same-ID entry"
           )
         ]}
    end
  end

  defp map_runners(runtime, host, target_id) do
    {raw_runners, runners, runner_input_diagnostics} =
      validate_runtime_runners(runtime["runners"])

    {agent, agent_shape_diagnostics} = validate_agent(runtime["agent"])
    runner_ids = runners |> Map.keys() |> Enum.sort()

    {default_runner, default_runner_diagnostics} =
      default_runner(agent, runner_ids)

    max_agents = Map.get(agent, "max_concurrent_agents", 10)
    max_startups = Map.get(agent, "max_concurrent_startups", 2)
    max_turns = Map.get(agent, "max_turns", 20)

    mapped =
      Enum.map(runners, fn {id, runner} ->
        raw_runner = Map.get(raw_runners, id, %{})
        path = "$.runtime.runners.#{id}"

        {command, reasoning_effort, reasoning_diagnostics} =
          extract_reasoning(runner["kind"], runner["command"], raw_runner, "#{path}.command")

        {host_profiles, target_profiles, profile_dispositions} =
          split_execution_profiles(
            runner["execution_profiles"],
            raw_runner["execution_profiles"],
            path,
            target_id,
            id
          )

        host_runner =
          runner
          |> Map.take(@host_runner_fields)
          |> maybe_put("command", command)
          |> maybe_put("execution_profiles", host_profiles)
          |> Map.put("max_concurrent_agents", max_agents)
          |> Map.put("max_concurrent_startups", Map.get(runner, "max_concurrent_startups", max_startups))

        setting =
          runner
          |> Map.take(@safe_runner_setting_fields)
          |> maybe_put("max_turns", if(id == default_runner, do: max_turns))
          |> maybe_put("reasoning_effort", reasoning_effort)
          |> maybe_put("execution_profiles", target_profiles)

        host_dispositions =
          Enum.map(Map.keys(Map.take(raw_runner, @host_runner_fields)), fn field ->
            disposition("#{path}.#{field}", "$.host.runners.#{id}.#{field}", :mapped)
          end)

        target_dispositions =
          Enum.map(Map.keys(Map.take(raw_runner, @safe_runner_setting_fields)), fn field ->
            disposition(
              "#{path}.#{field}",
              "$.targets.#{target_id}.runners.settings.#{id}.#{field}",
              :mapped
            )
          end)

        derived_dispositions =
          []
          |> maybe_add_disposition(
            Map.has_key?(agent, "max_concurrent_agents"),
            "$.runtime.agent.max_concurrent_agents",
            "$.host.runners.#{id}.max_concurrent_agents",
            :mapped
          )
          |> maybe_add_disposition(
            Map.has_key?(agent, "max_concurrent_startups") and
              not Map.has_key?(raw_runner, "max_concurrent_startups"),
            "$.runtime.agent.max_concurrent_startups",
            "$.host.runners.#{id}.max_concurrent_startups",
            :mapped
          )
          |> maybe_add_disposition(
            id == default_runner and Map.has_key?(agent, "max_turns"),
            "$.runtime.agent.max_turns",
            "$.targets.#{target_id}.runners.settings.#{id}.max_turns",
            :mapped
          )

        reasoning_dispositions =
          if is_binary(reasoning_effort) do
            [
              disposition(
                "#{path}.command",
                "$.targets.#{target_id}.runners.settings.#{id}.reasoning_effort",
                :normalized
              )
            ]
          else
            []
          end

        dispositions =
          host_dispositions ++
            target_dispositions ++
            profile_dispositions ++ derived_dispositions ++ reasoning_dispositions

        {id, host_runner, setting, dispositions, reasoning_diagnostics}
      end)

    imported_host_runners =
      Map.new(mapped, fn {id, runner, _setting, _dispositions, _diagnostics} -> {id, runner} end)

    settings =
      Map.new(mapped, fn {id, _runner, setting, _dispositions, _diagnostics} -> {id, setting} end)

    target_runners = %{
      "default" => default_runner,
      "allowed" => runner_ids,
      "settings" => settings
    }

    {mapped_host, collision_diagnostics} =
      Enum.reduce(imported_host_runners, {host, []}, fn {id, runner}, {current, diagnostics} ->
        {next, entry_diagnostics} = merge_host_entry(current, "runners", id, runner)
        {next, entry_diagnostics ++ diagnostics}
      end)

    dispositions = Enum.flat_map(mapped, fn {_id, _runner, _setting, values, _diagnostics} -> values end)

    diagnostics =
      runner_input_diagnostics ++
        agent_shape_diagnostics ++
        default_runner_diagnostics ++
        Enum.flat_map(mapped, fn {_id, _runner, _setting, _values, diagnostics} ->
          diagnostics
        end) ++ collision_diagnostics

    {mapped_host, target_runners, dispositions, diagnostics}
  end

  defp split_execution_profiles(profiles, raw_profiles, runner_path, target_id, runner_id)
       when is_map(profiles) do
    entries =
      profiles
      |> Enum.map(fn {name, profile} -> {canonical_profile_name(name), name, profile} end)
      |> Enum.sort_by(fn {canonical, original, _profile} -> {canonical, original} end)

    host_profiles =
      Map.new(entries, fn {canonical, _original, profile} -> {canonical, profile} end)

    target_profiles =
      Map.new(entries, fn {canonical, _original, profile} ->
        {canonical, safe_execution_profile(profile)}
      end)

    collection_dispositions =
      if is_map(raw_profiles) do
        [
          disposition(
            "#{runner_path}.execution_profiles",
            "$.host.runners.#{runner_id}.execution_profiles",
            :mapped
          ),
          disposition(
            "#{runner_path}.execution_profiles",
            "$.targets.#{target_id}.runners.settings.#{runner_id}.execution_profiles",
            :mapped
          )
        ]
      else
        []
      end

    field_dispositions =
      raw_profiles
      |> map()
      |> Enum.map(fn {name, profile} -> {canonical_profile_name(name), name, profile} end)
      |> Enum.sort_by(fn {canonical, original, _profile} -> {canonical, original} end)
      |> Enum.flat_map(&execution_profile_dispositions(&1, runner_path, target_id, runner_id))

    {host_profiles, target_profiles, collection_dispositions ++ field_dispositions}
  end

  defp execution_profile_dispositions(
         {canonical, original, profile},
         runner_path,
         target_id,
         runner_id
       )
       when is_map(profile) do
    action = if canonical == original, do: :mapped, else: :normalized

    host =
      Enum.map(Map.keys(profile), fn field ->
        disposition(
          "#{runner_path}.execution_profiles.#{original}.#{field}",
          "$.host.runners.#{runner_id}.execution_profiles.#{canonical}.#{field}",
          action
        )
      end)

    target =
      profile
      |> Map.take(@safe_execution_profile_fields)
      |> Enum.filter(&safe_execution_profile_field?/1)
      |> Enum.map(fn {field, _value} ->
        disposition(
          "#{runner_path}.execution_profiles.#{original}.#{field}",
          "$.targets.#{target_id}.runners.settings.#{runner_id}.execution_profiles.#{canonical}.#{field}",
          action
        )
      end)

    host ++ target
  end

  defp execution_profile_dispositions(
         {_canonical, _original, _profile},
         _runner_path,
         _target_id,
         _runner_id
       ),
       do: []

  defp safe_execution_profile(profile) when is_map(profile) do
    profile
    |> Map.take(@safe_execution_profile_fields)
    |> Enum.filter(&safe_execution_profile_field?/1)
    |> Map.new()
  end

  defp safe_execution_profile(_profile), do: %{}

  defp safe_execution_profile_field?({"model", value}), do: valid_nonblank_string?(value)
  defp safe_execution_profile_field?({"reasoning_effort", value}), do: value in @safe_reasoning_efforts

  defp canonical_profile_name(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> "implementation"
      canonical -> canonical
    end
  end

  defp maybe_add_disposition(dispositions, true, source, destination, action),
    do: dispositions ++ [disposition(source, destination, action)]

  defp maybe_add_disposition(dispositions, false, _source, _destination, _action),
    do: dispositions

  defp validate_runtime_runners(nil), do: {%{}, %{}, []}

  defp validate_runtime_runners(runners) when is_map(runners) do
    {raw_runners, structural_diagnostics} =
      runners
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.with_index()
      |> Enum.reduce({%{}, []}, fn {{id, runner}, index}, {valid, diagnostics} ->
        case validate_runtime_runner(id, runner, index) do
          {:ok, id, runner} ->
            {Map.put(valid, id, runner), diagnostics}

          {:error, entry_diagnostics} ->
            {valid, diagnostics ++ entry_diagnostics}
        end
      end)

    null_diagnostics = defaulted_runner_null_diagnostics(raw_runners)
    catalog_input = drop_defaulted_runner_nulls(raw_runners)

    {normalized_runners, catalog_diagnostics} =
      case ConfigSchema.validate_runner_catalog_detailed(catalog_input) do
        {:ok, normalized} ->
          {normalized, []}

        {:error, errors} ->
          diagnostics =
            errors
            |> Enum.reject(&String.ends_with?(&1.path, ".reasoning_effort"))
            |> Enum.map(fn error ->
              import_diagnostic(
                "$.#{error.path}",
                error.code,
                "runner field does not match the supported catalog"
              )
            end)

          {%{}, diagnostics}
      end

    diagnostics =
      structural_diagnostics ++
        null_diagnostics ++
        catalog_diagnostics ++
        execution_profile_diagnostics(raw_runners) ++
        reasoning_source_diagnostics(raw_runners)

    {raw_runners, normalized_runners, diagnostics}
  end

  defp validate_runtime_runners(_runners) do
    {%{}, %{},
     [
       import_diagnostic(
         "$.runtime.runners",
         :invalid_type,
         "runtime runners must be a map"
       )
     ]}
  end

  defp defaulted_runner_null_diagnostics(runners) do
    runners
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {id, runner} ->
      kind = Map.get(runner, "kind", if(id == "codex", do: "codex_app_server"))
      defaulted_fields = Map.get(@defaulted_runner_fields, kind, MapSet.new())

      defaulted_fields
      |> Enum.filter(&(Map.has_key?(runner, &1) and is_nil(runner[&1])))
      |> Enum.sort()
      |> Enum.map(fn field ->
        import_diagnostic(
          "$.runtime.runners.#{id}.#{field}",
          :invalid_type,
          "runner defaulted field must not be null when present"
        )
      end)
    end)
  end

  defp drop_defaulted_runner_nulls(runners) do
    Map.new(runners, fn {id, runner} ->
      kind = Map.get(runner, "kind", if(id == "codex", do: "codex_app_server"))
      defaulted_fields = Map.get(@defaulted_runner_fields, kind, MapSet.new())
      fields = Enum.filter(defaulted_fields, &(Map.has_key?(runner, &1) and is_nil(runner[&1])))
      {id, Map.drop(runner, fields)}
    end)
  end

  defp reasoning_source_diagnostics(runners) do
    Enum.flat_map(runners, fn {id, runner} ->
      kind = Map.get(runner, "kind", if(id == "codex", do: "codex_app_server"))

      {_command, _reasoning_effort, diagnostics} =
        extract_reasoning(kind, Map.get(runner, "command"), runner, "$.runtime.runners.#{id}.command")

      diagnostics
    end)
  end

  defp execution_profile_diagnostics(runners) do
    runners
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(&runner_execution_profile_diagnostics/1)
  end

  defp runner_execution_profile_diagnostics({runner_id, runner}) do
    case Map.fetch(runner, "execution_profiles") do
      :error ->
        []

      {:ok, profiles} when is_map(profiles) ->
        profiles
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.flat_map(fn {profile_name, profile} ->
          execution_profile_diagnostics(profile, runner_id, profile_name)
        end)

      {:ok, _invalid} ->
        []
    end
  end

  defp execution_profile_diagnostics(profile, runner_id, profile_name)
       when is_map(profile) do
    path = "$.runtime.runners.#{runner_id}.execution_profiles.#{profile_name}"

    nonblank_string_field_diagnostics(profile, ~w(model budget), path) ++
      optional_field_diagnostics(
        profile,
        "reasoning_effort",
        path,
        &reasoning_effort_error/1
      ) ++
      positive_integer_field_diagnostics(profile, ["timeout_ms"], path) ++
      optional_field_diagnostics(profile, "max_retries", path, &non_negative_integer_error/1) ++
      optional_field_diagnostics(profile, "command", path, &command_error/1)
  end

  defp execution_profile_diagnostics(_profile, runner_id, profile_name) do
    [
      import_diagnostic(
        "$.runtime.runners.#{runner_id}.execution_profiles.#{profile_name}",
        :invalid_type,
        "execution profile must be a map"
      )
    ]
  end

  defp reasoning_effort_error(value),
    do: if(value in @safe_reasoning_efforts, do: nil, else: :invalid_value)

  defp non_negative_integer_error(value) when is_integer(value),
    do: if(value >= 0, do: nil, else: :invalid_value)

  defp non_negative_integer_error(_value), do: :invalid_type

  defp command_error(value) when is_list(value),
    do: if(Enum.all?(value, &(is_binary(&1) and String.valid?(&1))), do: nil, else: :invalid_type)

  defp command_error(_value), do: :invalid_type

  defp validate_runtime_runner(id, runner, _index) do
    path = "$.runtime.runners.#{id}"

    cond do
      not valid_id?(id) ->
        {:error,
         [
           import_diagnostic(
             path,
             :invalid_id,
             "runner ID must match the registry ID grammar"
           )
         ]}

      not is_map(runner) ->
        {:error, [import_diagnostic(path, :invalid_type, "runner definition must be a map")]}

      true ->
        {:ok, id, runner}
    end
  end

  defp validate_agent(nil), do: {%{}, []}
  defp validate_agent(agent) when is_map(agent), do: {agent, []}

  defp validate_agent(_agent) do
    {%{},
     [
       import_diagnostic(
         "$.runtime.agent",
         :invalid_type,
         "runtime agent must be a map"
       )
     ]}
  end

  defp default_runner(agent, runner_ids) do
    case Map.fetch(agent, "default_runner") do
      :error ->
        {List.first(runner_ids), []}

      {:ok, id} when is_binary(id) ->
        if valid_id?(id) do
          {id, []}
        else
          {id,
           [
             import_diagnostic(
               "$.runtime.agent.default_runner",
               :invalid_id,
               "default runner must match the registry ID grammar"
             )
           ]}
        end

      {:ok, invalid} ->
        {invalid,
         [
           import_diagnostic(
             "$.runtime.agent.default_runner",
             :invalid_type,
             "default runner must be a string"
           )
         ]}
    end
  end

  defp extract_reasoning("codex_app_server", normalized_command, raw_runner, path) do
    if Map.has_key?(raw_runner, "reasoning_effort") do
      {normalized_command, nil,
       [
         import_diagnostic(
           path,
           :unsupported_reasoning_argument,
           "reasoning effort must use one exact command argv -c pair"
         )
       ]}
    else
      case Map.fetch(raw_runner, "command") do
        :error -> {normalized_command, nil, []}
        {:ok, nil} -> {normalized_command, nil, []}
        {:ok, command} -> extract_codex_reasoning(command, path)
      end
    end
  end

  defp extract_reasoning(_kind, normalized_command, _raw_runner, _path),
    do: {normalized_command, nil, []}

  defp extract_codex_reasoning(command, path) when is_binary(command) do
    {command, nil,
     [
       import_diagnostic(
         path,
         :unsupported_reasoning_argument,
         "shell-string runner commands cannot be imported"
       )
     ]}
  end

  defp extract_codex_reasoning(command, path) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      extract_reasoning_argv(command, path)
    else
      unsupported_reasoning(command, path, "runner command argv must contain only strings")
    end
  end

  defp extract_codex_reasoning(command, path) do
    unsupported_reasoning(command, path, "runner command must be an argv list")
  end

  defp extract_reasoning_argv(command, path) do
    reasoning_values =
      command
      |> Enum.with_index()
      |> Enum.filter(fn {value, _index} ->
        String.starts_with?(value, "model_reasoning_effort=")
      end)

    exact_pairs =
      Enum.flat_map(reasoning_values, fn {value, value_index} ->
        with true <- value_index > 0,
             "-c" <- Enum.at(command, value_index - 1),
             {:ok, effort} <- parse_reasoning_value(value) do
          [{value_index - 1, value_index, effort}]
        else
          _not_exact -> []
        end
      end)

    case {reasoning_values, exact_pairs} do
      {[], []} ->
        {command, nil, []}

      {[{_value, value_index}], [{option_index, value_index, effort}]} ->
        normalized =
          command
          |> Enum.with_index()
          |> Enum.reject(fn {_value, index} -> index in [option_index, value_index] end)
          |> Enum.map(&elem(&1, 0))

        {normalized, effort, []}

      _unsupported ->
        unsupported_reasoning(
          command,
          path,
          "reasoning effort must use one exact known command argv -c pair"
        )
    end
  end

  defp unsupported_reasoning(command, path, message) do
    {command, nil, [import_diagnostic(path, :unsupported_reasoning_argument, message)]}
  end

  defp parse_reasoning_value("model_reasoning_effort=" <> value) do
    known = ~w(minimal low medium high xhigh)

    normalized =
      case value do
        "\"" <> rest -> strip_matching_quote(rest, "\"")
        "'" <> rest -> strip_matching_quote(rest, "'")
        unquoted -> unquoted
      end

    if normalized in known, do: {:ok, normalized}, else: :error
  end

  defp strip_matching_quote(value, quote) do
    if String.ends_with?(value, quote),
      do: binary_part(value, 0, byte_size(value) - byte_size(quote)),
      else: nil
  end

  defp map_capacity_and_quality(runtime, target_id) do
    agent = map(runtime["agent"])
    quality = map(runtime["quality_gate"])
    max_agents = Map.get(agent, "max_concurrent_agents", 10)
    max_startups = Map.get(agent, "max_concurrent_startups", 2)
    max_reviewers = Map.get(quality, "source_max_concurrency", 1)

    concurrency = %{
      "max_concurrent_agents" => max_agents,
      "max_concurrent_startups" => max_startups,
      "max_concurrent_reviewers" => max_reviewers,
      "by_linear_state" => Map.get(agent, "max_concurrent_agents_by_state", %{})
    }

    checks = %{
      "pre_dispatch" => [],
      "pre_handoff" => if(Map.get(quality, "enabled") == true, do: ["quality_gate"], else: []),
      "pre_publish" => [],
      "pre_merge" => []
    }

    dispositions =
      Enum.map(
        Enum.filter(
          ~w(max_concurrent_agents max_concurrent_startups max_concurrent_agents_by_state),
          &Map.has_key?(agent, &1)
        ),
        fn field ->
          disposition(
            "$.runtime.agent.#{field}",
            "$.targets.#{target_id}.concurrency",
            :mapped
          )
        end
      ) ++
        Enum.map(
          Enum.filter(~w(enabled source_max_concurrency), &Map.has_key?(quality, &1)),
          fn
            "enabled" ->
              disposition(
                "$.runtime.quality_gate.enabled",
                "$.targets.#{target_id}.checks.pre_handoff",
                :mapped
              )

            "source_max_concurrency" ->
              disposition(
                "$.runtime.quality_gate.source_max_concurrency",
                "$.targets.#{target_id}.concurrency.max_concurrent_reviewers",
                :mapped
              )
          end
        )

    {concurrency, checks, dispositions}
  end

  defp import_preflight(snapshot, proposal, runtime, target_id) do
    %Target{configured: configured} = Map.fetch!(snapshot.targets, target_id)

    state_overlap_diagnostics(configured, target_id) ++
      query_path_diagnostics(configured, target_id) ++
      lexical_path_diagnostics(configured, proposal["host"], target_id) ++
      runner_reference_preflight(configured, proposal["host"], target_id) ++
      capacity_preflight(configured, proposal["host"], target_id) ++
      profile_collision_diagnostics(runtime)
  end

  defp state_overlap_diagnostics(configured, target_id) do
    active = get_in(configured, ["linear", "active_states"])
    terminal = get_in(configured, ["linear", "terminal_states"])

    if is_list(active) and is_list(terminal) do
      overlap =
        active
        |> normalized_label_set()
        |> MapSet.intersection(normalized_label_set(terminal))
        |> MapSet.to_list()
        |> Enum.sort()

      if overlap == [] do
        []
      else
        path = "$.targets.#{target_id}.linear.terminal_states"

        [
          import_diagnostic(
            path,
            :state_overlap,
            "#{path} overlaps active states: #{Enum.join(overlap, ", ")}"
          )
        ]
      end
    else
      []
    end
  end

  defp normalized_label_set(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp query_path_diagnostics(configured, target_id) do
    query_file = get_in(configured, ["linear", "scope", "query_file"])

    if is_binary(query_file) and not safe_relative_path?(query_file) do
      path = "$.targets.#{target_id}.linear.scope.query_file"

      [
        import_diagnostic(
          path,
          :unsafe_path,
          "#{path} must be a traversal-free relative path"
        )
      ]
    else
      []
    end
  end

  defp safe_relative_path?(path) do
    relative? = Path.type(path) == :relative
    traversal? = Enum.any?(Path.split(path), &(&1 in [".", ".."]))
    relative? and path != "" and not traversal?
  end

  defp lexical_path_diagnostics(configured, host, target_id) do
    repo_path = get_in(configured, ["repo", "path"])
    worktree_path = get_in(configured, ["worktree", "root"])
    state_root = host["state_root"]
    repo = lexical_absolute_path(repo_path)
    worktree = lexical_absolute_path(worktree_path)
    state = lexical_absolute_path(state_root)
    repo_diagnostic_path = "$.targets.#{target_id}.repo.path"
    worktree_diagnostic_path = "$.targets.#{target_id}.worktree.root"

    absolute_path_diagnostics(repo_path, repo, repo_diagnostic_path) ++
      absolute_path_diagnostics(worktree_path, worktree, worktree_diagnostic_path) ++
      overlap_preflight(worktree, [{"repository root", repo}, {"host state root", state}], worktree_diagnostic_path) ++
      overlap_preflight(repo, [{"host state root", state}], repo_diagnostic_path)
  end

  defp lexical_absolute_path(path) when is_binary(path) do
    if String.valid?(path) and Path.type(path) == :absolute, do: Path.expand(path), else: nil
  end

  defp lexical_absolute_path(_path), do: nil

  defp absolute_path_diagnostics(raw, nil, path) when is_binary(raw),
    do: [import_diagnostic(path, :unsafe_path, "#{path} must be absolute")]

  defp absolute_path_diagnostics(_raw, _path, _diagnostic_path), do: []

  defp overlap_preflight(path, candidates, diagnostic_path) when is_binary(path) do
    overlaps =
      candidates
      |> Enum.filter(fn {_label, candidate} ->
        is_binary(candidate) and lexical_paths_overlap?(path, candidate)
      end)
      |> Enum.map(&elem(&1, 0))

    if overlaps == [] do
      []
    else
      [
        import_diagnostic(
          diagnostic_path,
          :path_overlap,
          "#{diagnostic_path} overlaps #{Enum.join(overlaps, ", ")}"
        )
      ]
    end
  end

  defp overlap_preflight(_path, _candidates, _diagnostic_path), do: []

  defp lexical_paths_overlap?(left, right) do
    left_segments = Path.split(left)
    right_segments = Path.split(right)
    prefix_segments?(left_segments, right_segments) or prefix_segments?(right_segments, left_segments)
  end

  defp prefix_segments?(_path, []), do: true
  defp prefix_segments?([segment | path], [segment | prefix]), do: prefix_segments?(path, prefix)
  defp prefix_segments?(_path, _prefix), do: false

  defp runner_reference_preflight(configured, host, target_id) do
    target_runners = configured["runners"]
    host_runners = host["runners"]
    allowed = target_runners["allowed"]
    default = target_runners["default"]
    settings = target_runners["settings"]
    root = "$.targets.#{target_id}.runners"

    allowed_reference_preflight(allowed, host_runners, root) ++
      default_reference_preflight(default, allowed, host_runners, root) ++
      setting_reference_preflight(settings, allowed, host_runners, root)
  end

  defp allowed_reference_preflight(allowed, host_runners, root) do
    allowed
    |> Enum.with_index()
    |> Enum.flat_map(&allowed_runner_reference_preflight(&1, host_runners, root))
  end

  defp allowed_runner_reference_preflight({runner_id, index}, host_runners, root) do
    path = "#{root}.allowed[#{index}]"
    diagnostic = import_diagnostic(path, :unknown_reference, "#{path} must reference a host runner")
    if Map.has_key?(host_runners, runner_id), do: [], else: [diagnostic]
  end

  defp default_reference_preflight(default, allowed, host_runners, root) do
    if valid_id?(default) do
      []
      |> maybe_add_preflight(
        default not in allowed,
        "#{root}.default",
        :runner_not_allowed,
        "#{root}.default must be a member of #{root}.allowed"
      )
      |> maybe_add_preflight(
        not Map.has_key?(host_runners, default),
        "#{root}.default",
        :unknown_reference,
        "#{root}.default must reference a host runner"
      )
    else
      []
    end
  end

  defp setting_reference_preflight(settings, allowed, host_runners, root) do
    Enum.flat_map(
      settings,
      &setting_runner_reference_preflight(&1, allowed, host_runners, root)
    )
  end

  defp setting_runner_reference_preflight({runner_id, _setting}, allowed, host_runners, root) do
    path = "#{root}.settings.#{runner_id}"

    []
    |> maybe_add_preflight(
      runner_id not in allowed,
      path,
      :runner_not_allowed,
      "#{path} is only valid for a runner in #{root}.allowed"
    )
    |> maybe_add_preflight(
      not Map.has_key?(host_runners, runner_id),
      path,
      :unknown_reference,
      "#{path} must reference a host runner"
    )
  end

  defp maybe_add_preflight(diagnostics, add?, path, code, message) do
    if add?, do: diagnostics ++ [import_diagnostic(path, code, message)], else: diagnostics
  end

  defp capacity_preflight(configured, host, target_id) do
    capacity_preflight_values(
      configured["concurrency"],
      configured["runners"],
      host["capacity"],
      host["runners"],
      target_id
    )
  end

  defp capacity_preflight_values(
         concurrency,
         target_runners,
         host_capacity,
         host_runners,
         target_id
       ) do
    runner_capacities = runner_capacities(target_runners["allowed"], host_runners)
    capacities = [host_capacity | runner_capacities]
    root = "$.targets.#{target_id}.concurrency"

    limit_diagnostics =
      capacity_limit_diagnostics(
        "max_concurrent_agents",
        concurrency,
        capacities,
        root,
        target_id
      ) ++
        capacity_limit_diagnostics(
          "max_concurrent_startups",
          concurrency,
          capacities,
          root,
          target_id
        ) ++
        capacity_limit_diagnostics(
          "max_concurrent_reviewers",
          concurrency,
          [host_capacity],
          root,
          target_id
        )

    limit_diagnostics ++
      state_capacity_diagnostics(
        concurrency["by_linear_state"],
        concurrency["max_concurrent_agents"],
        root,
        target_id
      )
  end

  defp runner_capacities(allowed, host_runners) do
    allowed
    |> Enum.map(&Map.get(host_runners, &1))
    |> Enum.filter(&is_map/1)
  end

  defp capacity_limit_diagnostics(field, concurrency, capacities, root, target_id) do
    ceiling =
      Enum.reduce(capacities, nil, fn capacity, current_ceiling ->
        case positive_integer(Map.get(capacity, field)) do
          nil -> current_ceiling
          value when is_nil(current_ceiling) or value < current_ceiling -> value
          _value -> current_ceiling
        end
      end)

    value = concurrency[field]

    if is_integer(value) and is_integer(ceiling) and value > ceiling do
      path = "#{root}.#{field}"

      [
        target_diagnostic(
          target_id,
          path,
          :capacity_exceeded,
          "#{path} must not exceed effective ceiling #{ceiling}"
        )
      ]
    else
      []
    end
  end

  defp state_capacity_diagnostics(values, state_limit, root, target_id)
       when is_map(values) and is_integer(state_limit) and state_limit > 0 do
    values
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(&state_capacity_entry_diagnostics(&1, state_limit, root, target_id))
  end

  defp state_capacity_diagnostics(_values, _state_limit, _root, _target_id), do: []

  defp state_capacity_entry_diagnostics({state, value}, state_limit, root, target_id)
       when is_binary(state) and is_integer(value) and value > state_limit do
    path = "#{root}.by_linear_state.#{state}"

    [
      target_diagnostic(
        target_id,
        path,
        :capacity_exceeded,
        "#{path} must not exceed #{root}.max_concurrent_agents (#{state_limit})"
      )
    ]
  end

  defp state_capacity_entry_diagnostics(_entry, _state_limit, _root, _target_id), do: []

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp profile_collision_diagnostics(runtime) do
    runtime
    |> Map.get("runners")
    |> map()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {runner_id, runner} ->
      profiles = Map.get(map(runner), "execution_profiles")

      if is_map(profiles) and canonical_profile_collision?(profiles) do
        [
          import_diagnostic(
            "$.runtime.runners.#{runner_id}.execution_profiles",
            :execution_profile_name_collision,
            "execution profile names collide after normalization"
          )
        ]
      else
        []
      end
    end)
  end

  defp canonical_profile_collision?(profiles) do
    names = profiles |> Map.keys() |> Enum.map(&canonical_profile_name/1)
    Enum.uniq(names) != names
  end

  defp expected_incomplete_target?(
         %Target{
           configured_state: :paused,
           effective_state: :paused,
           dispatch_mode: nil,
           valid?: false,
           repo_manifest: nil,
           effective_policy: nil,
           policy_hash: nil,
           diagnostics: diagnostics
         },
         target_id
       ) do
    diagnostics == expected_incomplete_diagnostics(target_id)
  end

  defp expected_incomplete_diagnostics(target_id) do
    scope = {:target, target_id}
    root = "$.targets.#{target_id}"

    [
      missing_policy_field(scope, "#{root}.budgets.daily"),
      missing_policy_field(scope, "#{root}.budgets.per_run"),
      missing_policy_field(scope, "#{root}.budgets.weekly"),
      %Diagnostic{
        severity: :error,
        scope: scope,
        path: "#{root}.external_side_effects",
        code: :incomplete_policy,
        message: "#{root}.external_side_effects is required; omitted operations default to deny"
      },
      missing_policy_field(scope, "#{root}.scheduling.weight")
    ]
  end

  defp missing_policy_field(scope, path) do
    %Diagnostic{
      severity: :error,
      scope: scope,
      path: path,
      code: :missing_required_field,
      message: "#{path} is required"
    }
  end

  defp repository_authority(document, current_repo_manifest) do
    dispositions =
      @repo_owned_sections
      |> Enum.filter(&Map.has_key?(document, &1))
      |> Enum.map(fn section ->
        disposition(
          "$.#{section}",
          "$.current_repo_manifest.#{section}",
          :reapplied_from_current_repo
        )
      end)

    source_markers = get_in(document, ["issue_markers", "labels"])
    current_markers = get_in(current_repo_manifest, ["issue_markers", "labels"])

    differences =
      if is_list(source_markers) and source_markers != current_markers do
        [
          %{
            source_path: "$.issue_markers.labels",
            destination_path: "$.effective_preview_target.linear.required_labels",
            classification: :source_difference,
            source: source_markers,
            effective: current_markers,
            reason: "current committed repository issue markers remain authoritative"
          }
        ]
      else
        []
      end

    {dispositions, differences}
  end

  defp ignored_runtime_fields(runtime) do
    host_only =
      ~w(server observability)
      |> Enum.filter(&Map.has_key?(runtime, &1))
      |> Enum.map(fn field ->
        {
          disposition("$.runtime.#{field}", nil, :ignored_host_only),
          source_difference(
            "$.runtime.#{field}",
            "host-only runtime field is reported and not copied into the target"
          )
        }
      end)

    legacy_posture =
      [
        if(Map.has_key?(runtime, "mode"), do: "$.runtime.mode"),
        if(Map.has_key?(map(runtime["target"]), "mode"), do: "$.runtime.target.mode")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn path ->
        {
          disposition(path, nil, :ignored_legacy_posture),
          source_difference(
            path,
            "legacy posture is ignored; imported targets are always paused without a dispatch mode"
          )
        }
      end)

    quality =
      runtime
      |> map()
      |> Map.get("quality_gate", %{})
      |> map()
      |> Map.keys()
      |> Enum.reject(&(&1 in @mapped_quality_fields))
      |> Enum.sort()
      |> Enum.map(fn field ->
        path = "$.runtime.quality_gate.#{field}"

        {
          disposition(path, nil, :not_mapped),
          source_difference(
            path,
            "implementation-specific quality setting remains under current repository policy"
          )
        }
      end)

    entries = host_only ++ legacy_posture ++ quality
    {Enum.map(entries, &elem(&1, 0)), Enum.map(entries, &elem(&1, 1))}
  end

  defp source_difference(source_path, reason) do
    %{
      source_path: source_path,
      destination_path: nil,
      classification: :source_difference,
      source: :present,
      effective: nil,
      reason: reason
    }
  end

  defp union_labels(left, right) do
    cond do
      valid_label_list?(left) and valid_label_list?(right) ->
        (left ++ right)
        |> Enum.map(&String.downcase(String.trim(&1)))
        |> Enum.uniq()
        |> Enum.sort()

      not valid_label_list?(left) ->
        left

      true ->
        right
    end
  end

  defp valid_label_list?(values) when is_list(values),
    do: Enum.all?(values, &valid_nonblank_string?/1)

  defp valid_label_list?(_values), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp hook_dispositions(hooks, target_id) when is_map(hooks) do
    Enum.map(Map.keys(hooks), fn field ->
      disposition(
        "$.runtime.hooks.#{field}",
        "$.targets.#{target_id}.worktree.hooks.#{field}",
        :mapped
      )
    end)
  end

  defp hook_dispositions(_hooks, _target_id), do: []

  defp target_display_name(target) do
    case Map.fetch(target, "display_name") do
      {:ok, value} -> value
      :error -> Map.get(target, "name")
    end
  end

  defp map_host_capacity(worker, host) when is_map(worker) do
    mappings = [
      {"max_concurrent_agents_per_host", "max_concurrent_agents"},
      {"max_concurrent_startups_per_host", "max_concurrent_startups"}
    ]

    Enum.reduce(mappings, {host, [], []}, &map_host_capacity_field(worker, &1, &2))
  end

  defp map_host_capacity(_worker, host), do: {host, [], []}

  defp map_host_capacity_field(
         worker,
         {source_field, host_field},
         {host, dispositions, differences}
       ) do
    case Map.fetch(worker, source_field) do
      :error ->
        {host, dispositions, differences}

      {:ok, source_limit} ->
        map_host_capacity_value(
          source_field,
          host_field,
          source_limit,
          get_in(host, ["capacity", host_field]),
          {host, dispositions, differences}
        )
    end
  end

  defp map_host_capacity_value(
         source_field,
         host_field,
         source_limit,
         nil,
         {host, dispositions, differences}
       ) do
    source_path = "$.runtime.worker.#{source_field}"
    destination_path = "$.host.capacity.#{host_field}"
    capacity = Map.put(map(host["capacity"]), host_field, source_limit)
    imported = disposition(source_path, destination_path, :compared)
    {Map.put(host, "capacity", capacity), dispositions ++ [imported], differences}
  end

  defp map_host_capacity_value(
         source_field,
         host_field,
         limit,
         limit,
         {host, dispositions, differences}
       ) do
    imported =
      disposition(
        "$.runtime.worker.#{source_field}",
        "$.host.capacity.#{host_field}",
        :matched
      )

    {host, dispositions ++ [imported], differences}
  end

  defp map_host_capacity_value(
         source_field,
         host_field,
         source_limit,
         effective_limit,
         {host, dispositions, differences}
       ) do
    source_path = "$.runtime.worker.#{source_field}"
    destination_path = "$.host.capacity.#{host_field}"
    imported = disposition(source_path, destination_path, :compared)

    difference = %{
      source_path: source_path,
      destination_path: destination_path,
      classification: :source_difference,
      source: source_limit,
      effective: effective_limit,
      reason: "existing host capacity remains unchanged"
    }

    {host, dispositions ++ [imported], differences ++ [difference]}
  end

  defp map_polling(%{"interval_ms" => source_interval}, host) do
    effective_interval = get_in(host, ["polling", "interval_ms"])
    action = if source_interval == effective_interval, do: :matched, else: :compared

    dispositions = [
      disposition(
        "$.runtime.polling.interval_ms",
        "$.host.polling.interval_ms",
        action
      )
    ]

    differences =
      if source_interval == effective_interval do
        []
      else
        [
          %{
            source_path: "$.runtime.polling.interval_ms",
            destination_path: "$.host.polling.interval_ms",
            classification: :source_difference,
            source: source_interval,
            effective: effective_interval,
            reason: "existing host polling remains unchanged"
          }
        ]
      end

    {host, dispositions, differences}
  end

  defp map_polling(_polling, host), do: {host, [], []}

  defp workspace_dispositions(%{"root" => _root}, target_id) do
    [
      disposition(
        "$.runtime.workspace.root",
        "$.targets.#{target_id}.worktree.root",
        :mapped_with_target_isolation
      )
    ]
  end

  defp workspace_dispositions(_workspace, _target_id), do: []

  defp tracker_dispositions(runtime, tracker, connection_id, target_id, scope) do
    connection_fields = Enum.filter(~w(kind endpoint api_key), &Map.has_key?(tracker, &1))
    target_fields = Enum.filter(~w(active_states terminal_states required_labels), &Map.has_key?(tracker, &1))

    Enum.map(connection_fields, fn field ->
      disposition("$.runtime.tracker.#{field}", "$.host.tracker_connections.#{connection_id}.#{field}", :mapped)
    end) ++
      Enum.map(target_fields, fn field ->
        disposition("$.runtime.tracker.#{field}", "$.targets.#{target_id}.linear.#{field}", :mapped)
      end) ++
      [
        disposition(
          scope_source_path(runtime, tracker, scope),
          "$.targets.#{target_id}.linear.scope",
          :mapped
        )
      ]
  end

  defp scope_source_path(_runtime, tracker, scope) do
    if scope in tracker_scope_candidates(tracker) do
      tracker_scope_source_path(scope)
    else
      "$.runtime.target.#{scope_field(scope)}"
    end
  end

  defp tracker_scope_source_path(scope), do: "$.runtime.tracker.#{scope_field(scope)}"

  defp scope_field(%{"project_id" => _value}), do: "project_id"
  defp scope_field(%{"project_slug" => _value}), do: "project_slug"
  defp scope_field(%{"team_key" => _value}), do: "team_key"
  defp scope_field(%{"query_file" => _value}), do: "query_file"
  defp scope_field(%{"issue_ids" => _value}), do: "issue_ids"
  defp scope_field(_scope), do: "scope"

  defp disposition(source_path, destination_path, action) do
    %{source_path: source_path, destination_path: destination_path, action: action}
  end

  defp import_diagnostic(path, code, message),
    do: diagnostic(:registry, path, code, message)

  defp target_diagnostic(target_id, path, code, message),
    do: diagnostic({:target, target_id}, path, code, message)

  defp diagnostic(scope, path, code, message) do
    %Diagnostic{
      severity: :error,
      scope: scope,
      path: path,
      code: code,
      message: message
    }
  end

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}

  defp valid_nonblank_string?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp valid_id?(value),
    do: valid_nonblank_string?(value) and Regex.match?(@id_regex, value)
end
