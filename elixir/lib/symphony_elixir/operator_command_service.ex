defmodule SymphonyElixir.OperatorCommandService do
  @moduledoc false
  alias SymphonyElixir.LocalConfig
  alias SymphonyElixir.OperatorCommandService.Command
  alias SymphonyElixir.OperatorCommandService.PlanStore
  alias SymphonyElixir.TargetRegistry
  alias SymphonyElixir.TargetRegistry.Composition
  alias SymphonyElixir.TargetRegistry.FileStore
  alias SymphonyElixir.TargetRegistry.Import, as: RegistryImport
  alias SymphonyElixir.TargetRegistry.Preview
  alias SymphonyElixir.TargetRegistry.Schema
  alias SymphonyElixir.TargetRegistry.Validation
  alias SymphonyElixir.TargetRegistry.Yaml
  alias SymphonyElixir.Workflow.Manifest

  defmodule Error do
    @moduledoc false

    @enforce_keys [:code, :message]
    @derive {Jason.Encoder,
             only: [
               :code,
               :message,
               :path,
               :committed?,
               :expected_generation,
               :observed_generation
             ]}
    defstruct [:code, :message, :path, committed?: false, expected_generation: nil, observed_generation: nil]

    @type t :: %__MODULE__{
            code: atom(),
            message: String.t(),
            path: String.t() | nil,
            committed?: boolean(),
            expected_generation: String.t() | nil,
            observed_generation: String.t() | nil
          }
  end

  defmodule Plan do
    @moduledoc false

    @enforce_keys [
      :id,
      :action,
      :target_id,
      :registry_path,
      :expected_generation,
      :proposed_generation,
      :applicable?,
      :preview,
      :created_at
    ]
    @derive {Jason.Encoder,
             only: [
               :id,
               :action,
               :target_id,
               :registry_path,
               :expected_generation,
               :proposed_generation,
               :applicable?,
               :preview,
               :created_at
             ]}
    defstruct [
      :id,
      :action,
      :target_id,
      :registry_path,
      :expected_generation,
      :proposed_generation,
      :applicable?,
      :preview,
      :created_at
    ]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            action: :add | :import,
            target_id: String.t(),
            registry_path: Path.t(),
            expected_generation: String.t(),
            proposed_generation: String.t(),
            applicable?: boolean(),
            preview: map(),
            created_at: String.t()
          }
  end

  defmodule ApplyResult do
    @moduledoc false

    @enforce_keys [
      :plan_id,
      :action,
      :target_id,
      :registry_path,
      :old_generation,
      :new_generation,
      :committed?,
      :plan_consumed?
    ]
    @derive {Jason.Encoder,
             only: [
               :plan_id,
               :action,
               :target_id,
               :registry_path,
               :old_generation,
               :new_generation,
               :committed?,
               :plan_consumed?
             ]}
    defstruct [
      :plan_id,
      :action,
      :target_id,
      :registry_path,
      :old_generation,
      :new_generation,
      :committed?,
      :plan_consumed?
    ]

    @type t :: %__MODULE__{
            plan_id: String.t(),
            action: :add | :import,
            target_id: String.t(),
            registry_path: Path.t(),
            old_generation: String.t(),
            new_generation: String.t(),
            committed?: boolean(),
            plan_consumed?: boolean()
          }
  end

  @option_keys [
    :config_root,
    :consume_plan,
    :encode_import_preview,
    :load_manifest,
    :now,
    :preview_import,
    :read_file,
    :read_plan,
    :registry_path,
    :replace_registry,
    :store_plan
  ]

  @spec plan(Command.t(), keyword()) :: {:ok, Plan.t()} | {:error, Error.t()}
  def plan(%Command.Add{} = command, opts) do
    with :ok <- validate_add(command),
         {:ok, registry_path} <- registry_path(opts),
         plan_dir <- plan_dir(opts, registry_path),
         {:ok, current_file} <- read_registry(registry_path),
         {:ok, current_document, current_snapshot} <-
           decode_registry(current_file, registry_path) do
      plan_add(
        command,
        registry_path,
        plan_dir,
        current_file,
        current_document,
        current_snapshot,
        opts
      )
    end
  end

  def plan(%Command.Import{} = command, opts) do
    with {:ok, normalized_command} <- validate_import(command),
         {:ok, registry_path} <- registry_path(opts),
         plan_dir <- plan_dir(opts, registry_path),
         {:ok, current_file} <- read_registry(registry_path),
         {:ok, current_document, current_snapshot} <-
           decode_registry(current_file, registry_path) do
      plan_import(
        normalized_command,
        registry_path,
        plan_dir,
        current_file,
        current_document,
        current_snapshot,
        opts
      )
    end
  end

  def plan(_command, _opts),
    do: error(:invalid_command, "command must be a typed operator command", "$.command")

  @spec apply(String.t(), TargetRegistry.generation(), true, keyword()) ::
          {:ok, ApplyResult.t()} | {:error, Error.t()}
  def apply(plan_id, expected_generation, confirmation, opts) do
    with :ok <- validate_plan_id(plan_id),
         :ok <- validate_generation(expected_generation),
         {:ok, registry_path} <- registry_path(opts),
         :ok <- require_confirmation(confirmation) do
      apply_confirmed(plan_id, expected_generation, registry_path, opts)
    end
  end

  @spec confirm(String.t(), String.t(), true, keyword()) ::
          {:ok, ApplyResult.t()} | {:error, Error.t()}
  def confirm(target_id, plan_id, confirmation, opts) do
    with :ok <- validate_target_id(target_id),
         :ok <- validate_plan_id(plan_id),
         {:ok, registry_path} <- registry_path(opts),
         :ok <- require_confirmation(confirmation),
         plan_dir <- plan_dir(opts, registry_path),
         {:ok, envelope} <- read_envelope(plan_dir, plan_id, opts),
         :ok <- validate_confirm_envelope(envelope, target_id, plan_id, registry_path) do
      apply(plan_id, envelope["expected_generation"], true, opts)
    end
  end

  defp validate_confirm_envelope(envelope, target_id, plan_id, registry_path) do
    if envelope["plan_id"] == plan_id and envelope["target_id"] == target_id and
         envelope["registry_path"] == registry_path and envelope["action"] in ["add", "import"] and
         valid_envelope_command?(envelope["action"], target_id, envelope["command"]) do
      :ok
    else
      error(:plan_mismatch, "plan envelope does not match confirmation binding", "$.plan")
    end
  end

  defp apply_confirmed(plan_id, expected_generation, registry_path, opts) do
    plan_dir = plan_dir(opts, registry_path)

    with {:ok, envelope} <- read_envelope(plan_dir, plan_id, opts),
         :ok <- validate_apply_envelope(envelope, plan_id, expected_generation, registry_path),
         {:ok, replacement} <- replace_from_envelope(envelope, opts),
         consume_result <- consume_envelope(plan_dir, plan_id, opts) do
      apply_result(envelope, replacement, consume_result)
    end
  end

  defp read_envelope(plan_dir, plan_id, opts) do
    reader = Keyword.get(opts, :read_plan, &PlanStore.read/2)
    normalize_plan_result(invoke(fn -> reader.(plan_dir, plan_id) end))
  end

  defp consume_envelope(plan_dir, plan_id, opts) do
    consumer = Keyword.get(opts, :consume_plan, &PlanStore.consume/2)
    normalize_plan_result(invoke(fn -> consumer.(plan_dir, plan_id) end))
  end

  defp normalize_plan_result({:ok, {:ok, envelope}}) when is_map(envelope), do: {:ok, envelope}

  defp normalize_plan_result({:ok, {:error, %TargetRegistry.Error{} = source}}),
    do: registry_error(source)

  defp normalize_plan_result({:ok, {:error, %Error{}} = error}), do: error
  defp normalize_plan_result(_result), do: error(:plan_corrupt, "plan envelope is unavailable or corrupt", "$.plan")

  defp validate_apply_envelope(envelope, plan_id, expected_generation, registry_path) do
    with true <- envelope["plan_id"] == plan_id,
         true <- envelope["expected_generation"] == expected_generation,
         true <- envelope["registry_path"] == registry_path,
         true <- envelope["action"] in ["add", "import"],
         true <- valid_id?(envelope["target_id"]),
         :ok <- validate_generation(envelope["proposed_generation"]),
         true <- is_map(envelope["source_hashes"]),
         true <- valid_envelope_command?(envelope["action"], envelope["target_id"], envelope["command"]) do
      :ok
    else
      false -> error(:plan_mismatch, "plan envelope binding does not match apply arguments", "$.plan")
      {:error, %Error{}} = error -> error
    end
  end

  defp valid_envelope_command?(
         "add",
         target_id,
         %{"target_id" => target_id, "target" => target} = command
       )
       when map_size(command) == 2,
       do: strict_json_map?(target)

  defp valid_envelope_command?(
         "import",
         target_id,
         %{
           "connection_id" => connection_id,
           "repo" => repo,
           "runner_ids" => runner_ids,
           "target_id" => target_id,
           "workflow" => workflow
         } = command
       )
       when map_size(command) == 5 do
    valid_path?(workflow) and Path.type(workflow) == :absolute and
      valid_path?(repo) and Path.type(repo) == :absolute and
      valid_id?(connection_id) and valid_runner_ids?(runner_ids)
  end

  defp valid_envelope_command?(_action, _target_id, _command), do: false

  defp replace_from_envelope(envelope, opts) do
    replacer =
      Keyword.get(opts, :replace_registry, fn path, expected, proposed, rebuild ->
        default_replace_registry(path, expected, proposed, rebuild, opts)
      end)

    rebuild = fn bytes -> rebuild_envelope(envelope, bytes, opts) end

    case invoke(fn ->
           replacer.(
             envelope["registry_path"],
             envelope["expected_generation"],
             envelope["proposed_generation"],
             rebuild
           )
         end) do
      {:ok, {:ok, result}} when is_map(result) ->
        {:ok, result}

      {:ok, {:error, %TargetRegistry.Error{} = source}} ->
        committed_replacement_error(source, envelope)

      {:ok, {:error, %Error{}} = error} ->
        error

      _failure ->
        error(:atomic_replace_failed, "target registry replacement failed", envelope["registry_path"])
    end
  end

  defp committed_replacement_error(source, envelope) do
    proposed_generation = envelope["proposed_generation"]

    if source.code in [:atomic_replace_failed, :checksum_mismatch] do
      case FileStore.read(envelope["registry_path"]) do
        {:ok, %{generation: ^proposed_generation}} ->
          {:error,
           %Error{
             code: source.code,
             message: source.message,
             path: source.path,
             committed?: true,
             expected_generation: proposed_generation,
             observed_generation: proposed_generation
           }}

        _not_committed ->
          registry_error(source)
      end
    else
      registry_error(source)
    end
  end

  defp default_replace_registry(path, expected_generation, _proposed_generation, rebuild, opts) do
    with {:ok, %{bytes: current_bytes}} <- FileStore.read(path),
         {:ok, proposed_bytes} <- rebuild.(current_bytes) do
      guarded_replace(path, proposed_bytes, expected_generation, rebuild, opts)
    end
  end

  defp guarded_replace(path, proposed_bytes, expected_generation, rebuild, opts) do
    key = {__MODULE__, make_ref()}
    Process.put(key, :pending)

    guarded_read = fn read_path ->
      if Process.get(key) == :pending do
        read_path
        |> verify_locked_rebuild(rebuild, opts)
        |> record_locked_rebuild(key)
      else
        File.read(read_path)
      end
    end

    try do
      result =
        FileStore.replace(path, proposed_bytes, expected_generation, file_ops: %{read: guarded_read})

      case Process.get(key) do
        {:error, %Error{}} = error -> error
        _verified -> result
      end
    after
      Process.delete(key)
    end
  end

  defp record_locked_rebuild({:ok, current_bytes}, key) do
    Process.put(key, :verified)
    {:ok, current_bytes}
  end

  defp record_locked_rebuild({:error, %Error{}} = error, key) do
    Process.put(key, error)
    {:error, :proposal_rejected}
  end

  defp verify_locked_rebuild(path, rebuild, opts) do
    reader = Keyword.get(opts, :read_file, &File.read/1)

    with {:ok, current_bytes} <- reader.(path),
         {:ok, _rebuilt_bytes} <- rebuild.(current_bytes) do
      {:ok, current_bytes}
    else
      {:error, %Error{}} = error -> error
      _failure -> error(:registry_unreadable, "target registry could not be read while locked", path)
    end
  end

  defp rebuild_envelope(%{"action" => "add"} = envelope, current_bytes, _opts) do
    command = envelope["command"]

    with {:ok, current_file} <- current_file(current_bytes),
         {:ok, current_document, current_snapshot} <-
           decode_registry(current_file, envelope["registry_path"]),
         false <- Map.has_key?(current_document["targets"], envelope["target_id"]),
         normalized_target <-
           command["target"] |> Map.put("state", "paused") |> Map.delete("dispatch_mode"),
         proposed_document <-
           put_in(current_document, ["targets", envelope["target_id"]], normalized_target),
         proposed_bytes <- Yaml.encode(proposed_document),
         {:ok, proposed_snapshot} <-
           snapshot_for(proposed_document, proposed_bytes, envelope["registry_path"]),
         proposed_snapshot <- Composition.compose(proposed_snapshot),
         :ok <- ensure_add_applicable(current_snapshot, proposed_snapshot, envelope["target_id"]),
         :ok <-
           verify_proposed_generation(
             proposed_bytes,
             envelope["proposed_generation"],
             envelope["registry_path"]
           ) do
      {:ok, proposed_bytes}
    else
      true -> error(:duplicate_target_id, "target ID now exists", "$.targets.#{envelope["target_id"]}")
      {:error, %Error{}} = error -> error
    end
  end

  defp rebuild_envelope(%{"action" => "import"} = envelope, current_bytes, opts) do
    command = envelope["command"]
    manifest_path = Manifest.manifest_path(command["repo"])

    with true <-
           Map.keys(envelope["source_hashes"]) |> Enum.sort() ==
             Enum.sort([command["workflow"], manifest_path]),
         {:ok, source_bytes} <- read_exact(command["workflow"], opts),
         :ok <-
           verify_source_hash(
             command["workflow"],
             source_bytes,
             envelope["source_hashes"][command["workflow"]]
           ),
         {:ok, mapped_source} <-
           map_import_source(source_bytes, command["runner_ids"]),
         {:ok, manifest_bytes} <- read_exact(manifest_path, opts),
         :ok <-
           verify_source_hash(
             manifest_path,
             manifest_bytes,
             envelope["source_hashes"][manifest_path]
           ),
         {:ok, current_manifest} <- load_manifest(command["repo"], opts),
         {:ok, ^manifest_bytes} <- read_exact(manifest_path, opts),
         {:ok, ^source_bytes} <- read_exact(command["workflow"], opts),
         {:ok, current_file} <- current_file(current_bytes),
         {:ok, current_document, current_snapshot} <-
           decode_registry(current_file, envelope["registry_path"]),
         false <- Map.has_key?(current_document["targets"], envelope["target_id"]),
         {:ok, %RegistryImport.Result{} = import_result} <-
           preview_import(
             mapped_source,
             [
               target_id: command["target_id"],
               source_path: command["workflow"],
               repo_path: command["repo"],
               connection_id: command["connection_id"],
               current_repo_manifest: current_manifest,
               host: current_snapshot.host
             ],
             opts
           ) do
      proposed_document = %{
        "version" => 1,
        "host" => import_result.proposal["host"],
        "targets" =>
          Map.put(
            current_document["targets"],
            command["target_id"],
            import_result.proposal["targets"][command["target_id"]]
          )
      }

      finish_import_rebuild(proposed_document, current_snapshot, import_result, envelope)
    else
      true -> error(:duplicate_target_id, "target ID now exists", "$.targets.#{envelope["target_id"]}")
      false -> error(:plan_mismatch, "import source bindings are invalid", "$.plan.source_hashes")
      {:error, %Error{}} = error -> error
      {:error, %TargetRegistry.Error{} = source} -> registry_error(source)
      _changed -> error(:import_source_changed, "import source changed while applying", command["workflow"])
    end
  end

  defp finish_import_rebuild(proposed_document, current_snapshot, import_result, envelope) do
    proposed_bytes = Yaml.encode(proposed_document)

    with {:ok, proposed_snapshot} <-
           snapshot_for(proposed_document, proposed_bytes, envelope["registry_path"]) do
      proposed_snapshot = Composition.compose(proposed_snapshot)

      if current_snapshot.globally_valid? and import_result.applicable? and
           add_applicable?(proposed_snapshot, envelope["target_id"]) and
           Preview.generation(proposed_bytes) == envelope["proposed_generation"] do
        {:ok, proposed_bytes}
      else
        error(:proposed_generation_mismatch, "rebuilt import proposal changed", "$.plan")
      end
    end
  end

  defp ensure_add_applicable(current_snapshot, proposed_snapshot, target_id) do
    if current_snapshot.globally_valid? and add_applicable?(proposed_snapshot, target_id),
      do: :ok,
      else: error(:plan_not_applicable, "rebuilt add proposal is not applicable", "$.plan")
  end

  defp verify_proposed_generation(bytes, expected, path) do
    if Preview.generation(bytes) == expected,
      do: :ok,
      else: error(:proposed_generation_mismatch, "rebuilt proposal generation changed", path)
  end

  defp verify_source_hash(path, bytes, expected) do
    if Preview.generation(bytes) == expected,
      do: :ok,
      else: error(:import_source_changed, "import source checksum changed", path)
  end

  defp current_file(bytes) when is_binary(bytes),
    do: {:ok, %{bytes: bytes, generation: Preview.generation(bytes)}}

  defp apply_result(envelope, replacement, {:ok, _consumed}) do
    {:ok,
     %ApplyResult{
       plan_id: envelope["plan_id"],
       action: String.to_existing_atom(envelope["action"]),
       target_id: envelope["target_id"],
       registry_path: envelope["registry_path"],
       old_generation: envelope["expected_generation"],
       new_generation: replacement.generation,
       committed?: true,
       plan_consumed?: true
     }}
  end

  defp apply_result(envelope, replacement, {:error, %Error{} = consume_error}) do
    {:error,
     %Error{
       consume_error
       | committed?: true,
         expected_generation: envelope["proposed_generation"],
         observed_generation: replacement.generation
     }}
  end

  defp invoke(function) do
    {:ok, function.()}
  rescue
    _exception -> {:error, :dependency_exception}
  catch
    _kind, _reason -> {:error, :dependency_exception}
  end

  defp require_confirmation(true), do: :ok

  defp require_confirmation(_nontrue),
    do: error(:confirmation_required, "literal confirmation true is required", "$.confirmation")

  defp validate_plan_id(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(~r/^[0-9a-f]{64}$/, value),
      do: :ok,
      else: error(:invalid_plan_id, "plan ID is invalid", "$.plan_id")
  end

  defp validate_plan_id(_value),
    do: error(:invalid_plan_id, "plan ID is invalid", "$.plan_id")

  defp validate_generation(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(~r/^sha256:[0-9a-f]{64}$/, value),
      do: :ok,
      else: error(:invalid_generation, "expected generation is invalid", "$.expected_generation")
  end

  defp validate_generation(_value),
    do: error(:invalid_generation, "expected generation is invalid", "$.expected_generation")

  defp validate_target_id(value) do
    if valid_id?(value),
      do: :ok,
      else: error(:invalid_target_id, "target ID is invalid", "$.target_id")
  end

  defp validate_add(command) do
    if Map.keys(command) |> Enum.sort() == [:__struct__, :target, :target_id] and
         valid_id?(command.target_id) and strict_json_map?(command.target) do
      :ok
    else
      error(:invalid_command, "add command is invalid", "$.command")
    end
  end

  defp strict_json_map?(value) when is_map(value) and not is_struct(value),
    do: match?({:ok, _remaining}, strict_json(value, 16, 4_096))

  defp strict_json_map?(_value), do: false

  defp strict_json(_value, _depth, remaining) when remaining <= 0, do: :error
  defp strict_json(_value, depth, _remaining) when depth <= 0, do: :error

  defp strict_json(value, depth, remaining) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(
      value,
      {:ok, remaining - 1},
      &strict_json_map_entry(&1, &2, depth)
    )
  end

  defp strict_json(value, depth, remaining) when is_list(value),
    do: strict_json_list(value, depth, remaining - 1)

  defp strict_json(value, _depth, remaining) when is_binary(value) do
    if String.valid?(value), do: {:ok, remaining - 1}, else: :error
  end

  defp strict_json(value, _depth, remaining) when is_float(value) do
    <<_sign::1, exponent::11, _fraction::52>> = <<value::float-64>>
    if exponent == 0x7FF, do: :error, else: {:ok, remaining - 1}
  end

  defp strict_json(value, _depth, remaining)
       when is_nil(value) or is_boolean(value) or is_integer(value),
       do: {:ok, remaining - 1}

  defp strict_json(_value, _depth, _remaining), do: :error

  defp strict_json_map_entry({key, nested}, {:ok, left}, depth) when is_binary(key) do
    if String.valid?(key),
      do: strict_json_map_value(nested, depth, left),
      else: {:halt, :error}
  end

  defp strict_json_map_entry(_entry, _state, _depth), do: {:halt, :error}

  defp strict_json_map_value(nested, depth, left) do
    case strict_json(nested, depth - 1, left) do
      {:ok, next} -> {:cont, {:ok, next}}
      :error -> {:halt, :error}
    end
  end

  defp strict_json_list([], _depth, remaining), do: {:ok, remaining}

  defp strict_json_list([nested | rest], depth, remaining) do
    case strict_json(nested, depth - 1, remaining) do
      {:ok, next} -> strict_json_list(rest, depth, next)
      :error -> :error
    end
  end

  defp strict_json_list(_improper, _depth, _remaining), do: :error

  defp registry_path(opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         true <- Enum.all?(opts, fn {key, _value} -> key in @option_keys end),
         true <- valid_option_values?(opts),
         true <- Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts),
         false <- Keyword.has_key?(opts, :registry_path) and Keyword.has_key?(opts, :config_root),
         {:ok, path} <- configured_registry_path(opts) do
      {:ok, path}
    else
      _invalid -> error(:invalid_options, "options must select one valid registry path", "$.options")
    end
  end

  defp valid_option_values?(opts) do
    Enum.all?(opts, fn
      {key, value} when key in [:config_root, :registry_path] ->
        is_binary(value)

      {:now, value} ->
        is_function(value, 0)

      {key, value} when key in [:encode_import_preview, :load_manifest, :read_file] ->
        is_function(value, 1)

      {:preview_import, value} ->
        is_function(value, 2)

      {key, value} when key in [:consume_plan, :read_plan, :store_plan] ->
        is_function(value, 2)

      {:replace_registry, value} ->
        is_function(value, 4)
    end)
  end

  defp plan_import(
         command,
         registry_path,
         plan_dir,
         current_file,
         current_document,
         current_snapshot,
         opts
       ) do
    cond do
      not current_snapshot.globally_valid? ->
        nonapplicable_import_plan(
          command,
          registry_path,
          current_file,
          Preview.preview(current_snapshot, current_snapshot, current_file.bytes),
          %{"import_diagnostics" => json_value(current_snapshot.diagnostics)},
          opts
        )

      Map.has_key?(current_document["targets"], command.target_id) ->
        error(:duplicate_target_id, "target ID already exists", "$.targets.#{command.target_id}")

      true ->
        build_import_plan(
          command,
          registry_path,
          plan_dir,
          current_file,
          current_document,
          current_snapshot,
          opts
        )
    end
  end

  defp build_import_plan(
         command,
         registry_path,
         plan_dir,
         current_file,
         current_document,
         current_snapshot,
         opts
       ) do
    manifest_path = Manifest.manifest_path(command.repo)

    with {:ok, source_bytes} <- read_exact(command.workflow, opts),
         {:ok, mapped_source} <- map_import_source(source_bytes, command.runner_ids),
         {:ok, manifest_before} <- read_exact(manifest_path, opts),
         {:ok, current_manifest} <- load_manifest(command.repo, opts),
         {:ok, ^manifest_before} <- read_exact(manifest_path, opts),
         {:ok, %RegistryImport.Result{} = import_result} <-
           preview_import(
             mapped_source,
             [
               target_id: command.target_id,
               source_path: command.workflow,
               repo_path: command.repo,
               connection_id: command.connection_id,
               current_repo_manifest: current_manifest,
               host: current_snapshot.host
             ],
             opts
           ),
         {:ok, ^source_bytes} <- read_exact(command.workflow, opts) do
      import_result = %{
        import_result
        | source: %{
            path: command.workflow,
            checksum: Preview.generation(source_bytes)
          }
      }

      proposed_document = %{
        "version" => 1,
        "host" => import_result.proposal["host"],
        "targets" =>
          Map.put(
            current_document["targets"],
            command.target_id,
            import_result.proposal["targets"][command.target_id]
          )
      }

      proposed_bytes = Yaml.encode(proposed_document)

      with {:ok, proposed_snapshot} <-
             snapshot_for(proposed_document, proposed_bytes, registry_path) do
        proposed_snapshot =
          proposed_snapshot
          |> Validation.validate(registry_path: registry_path)
          |> Composition.compose()

        registry_preview = Preview.preview(current_snapshot, proposed_snapshot, proposed_bytes)

        import_result = %RegistryImport.Result{
          import_result
          | proposal: proposed_document,
            snapshot: proposed_snapshot,
            registry_preview: registry_preview,
            applicable?:
              import_result.applicable? and proposed_snapshot.globally_valid? and
                add_applicable?(proposed_snapshot, command.target_id)
        }

        persist_import_plan(%{
          command: command,
          registry_path: registry_path,
          plan_dir: plan_dir,
          current_file: current_file,
          proposed_bytes: proposed_bytes,
          manifest_path: manifest_path,
          source_bytes: source_bytes,
          manifest_bytes: manifest_before,
          registry_preview: registry_preview,
          import_result: import_result,
          opts: opts
        })
      end
    else
      {:error, %Error{}} = error -> error
      {:error, %TargetRegistry.Error{} = source} -> registry_error(source)
      _changed -> error(:import_source_changed, "import source changed while planning", command.workflow)
    end
  end

  defp persist_import_plan(%{
         command: command,
         registry_path: registry_path,
         plan_dir: plan_dir,
         current_file: current_file,
         proposed_bytes: proposed_bytes,
         manifest_path: manifest_path,
         source_bytes: source_bytes,
         manifest_bytes: manifest_bytes,
         registry_preview: registry_preview,
         import_result: import_result,
         opts: opts
       }) do
    public_import = public_import(import_result, opts)

    if import_result.applicable? do
      created_at = now(opts)

      source_hashes = %{
        command.workflow => Preview.generation(source_bytes),
        manifest_path => Preview.generation(manifest_bytes)
      }

      command_data = %{
        "target_id" => command.target_id,
        "workflow" => command.workflow,
        "repo" => command.repo,
        "connection_id" => command.connection_id,
        "runner_ids" => command.runner_ids
      }

      with {:ok, envelope} <-
             build_envelope(
               "import",
               command.target_id,
               command_data,
               registry_path,
               current_file.generation,
               source_hashes,
               created_at,
               proposed_bytes
             ),
           {:ok, stored} <- store_envelope(plan_dir, envelope, opts) do
        {:ok,
         public_plan(
           stored,
           :import,
           command.target_id,
           registry_path,
           true,
           %{
             "registry" => json_value(registry_preview),
             "import" => public_import
           }
         )}
      end
    else
      nonapplicable_import_plan(
        command,
        registry_path,
        current_file,
        registry_preview,
        public_import,
        opts
      )
    end
  end

  defp nonapplicable_import_plan(
         command,
         registry_path,
         current_file,
         registry_preview,
         import_preview,
         opts
       ) do
    {:ok,
     %Plan{
       id: nil,
       action: :import,
       target_id: command.target_id,
       registry_path: registry_path,
       expected_generation: current_file.generation,
       proposed_generation: registry_preview.proposed_generation,
       applicable?: false,
       preview: %{
         "registry" => json_value(registry_preview),
         "import" => import_preview
       },
       created_at: now(opts)
     }}
  end

  defp preview_import(source, preview_opts, opts) do
    previewer = Keyword.get(opts, :preview_import, &RegistryImport.preview/2)
    previewer.(source, preview_opts)
  end

  defp map_import_source(source_bytes, runner_ids) when map_size(runner_ids) == 0,
    do: {:ok, source_bytes}

  defp map_import_source(source_bytes, runner_ids) do
    with {:ok, document} <- decode_yaml(source_bytes),
         runtime when is_map(runtime) <- document["runtime"],
         runners when is_map(runners) <- runtime["runners"],
         true <- Enum.all?(Map.keys(runner_ids), &Map.has_key?(runners, &1)),
         {:ok, renamed_runners} <- rename_runners(runners, runner_ids) do
      runtime =
        runtime
        |> Map.put("runners", renamed_runners)
        |> Map.update("agent", nil, &rename_default_runner(&1, runner_ids))

      {:ok, document |> Map.put("runtime", runtime) |> Yaml.encode()}
    else
      false -> error(:invalid_runner_mapping, "runner mapping names an absent source runner", "$.command.runner_ids")
      {:error, %Error{}} = error -> error
      _invalid -> error(:invalid_runner_mapping, "runner mapping requires runtime runners", "$.command.runner_ids")
    end
  end

  defp rename_default_runner(agent, runner_ids) when is_map(agent) do
    case agent["default_runner"] do
      id when is_binary(id) -> Map.put(agent, "default_runner", Map.get(runner_ids, id, id))
      _missing -> agent
    end
  end

  defp rename_default_runner(agent, _runner_ids), do: agent

  defp rename_runners(runners, runner_ids) do
    Enum.reduce_while(runners, {:ok, %{}}, fn {source_id, runner}, {:ok, renamed} ->
      registry_id = Map.get(runner_ids, source_id, source_id)

      if Map.has_key?(renamed, registry_id) do
        {:halt,
         error(
           :invalid_runner_mapping,
           "runner mapping creates a registry ID collision",
           "$.command.runner_ids"
         )}
      else
        {:cont, {:ok, Map.put(renamed, registry_id, runner)}}
      end
    end)
  end

  defp public_import(result, opts) do
    encoder = Keyword.get(opts, :encode_import_preview, &RegistryImport.encode_preview/1)

    case result |> encoder.() |> Jason.decode() do
      {:ok, value} when is_map(value) -> value
      _invalid -> %{"applicable?" => false, "import_diagnostics" => [%{"code" => "preview_encoding_failed"}]}
    end
  end

  defp read_exact(path, opts) do
    reader = Keyword.get(opts, :read_file, &File.read/1)

    case invoke(fn -> reader.(path) end) do
      {:ok, {:ok, bytes}} when is_binary(bytes) -> {:ok, bytes}
      _failure -> error(:source_unreadable, "required source file could not be read", path)
    end
  end

  defp load_manifest(repo, opts) do
    loader = Keyword.get(opts, :load_manifest, &default_load_manifest/1)

    case invoke(fn -> loader.(repo) end) do
      {:ok, {:ok, manifest}} when is_map(manifest) -> {:ok, manifest}
      {:ok, {:error, %Error{}} = error} -> error
      _failure -> error(:manifest_invalid, "current repository manifest is invalid", Manifest.manifest_path(repo))
    end
  end

  defp default_load_manifest(repo) do
    manifest_path = Manifest.manifest_path(repo)

    with {:ok, manifest} <- Manifest.read(manifest_path, repo_setup?: true),
         %{errors: []} <- Manifest.validate(repo, manifest),
         %{config: %{"manifest" => current_manifest}} <- Manifest.compile(manifest) do
      {:ok, current_manifest}
    else
      _failure -> error(:manifest_invalid, "current repository manifest is invalid", manifest_path)
    end
  end

  defp validate_import(%Command.Import{} = command) do
    valid_keys =
      Map.keys(command) |> Enum.sort() ==
        [:__struct__, :connection_id, :repo, :runner_ids, :target_id, :workflow]

    connection_id = command.connection_id || "linear"
    runner_ids = command.runner_ids || %{}

    if valid_keys and valid_id?(command.target_id) and valid_path?(command.workflow) and
         valid_path?(command.repo) and valid_id?(connection_id) and valid_runner_ids?(runner_ids) do
      {:ok,
       %Command.Import{
         command
         | workflow: Path.expand(command.workflow),
           repo: Path.expand(command.repo),
           connection_id: connection_id,
           runner_ids: runner_ids
       }}
    else
      error(:invalid_command, "import command is invalid", "$.command")
    end
  end

  defp valid_runner_ids?(runner_ids) when is_map(runner_ids) and not is_struct(runner_ids) do
    Enum.all?(runner_ids, fn {source, registry} -> valid_id?(source) and valid_id?(registry) end) and
      runner_ids |> Map.values() |> Enum.uniq() |> length() == map_size(runner_ids)
  end

  defp valid_runner_ids?(_runner_ids), do: false

  defp configured_registry_path(opts) do
    case Keyword.fetch(opts, :registry_path) do
      {:ok, path} -> expanded_path(path)
      :error -> registry_path_from_root(Keyword.fetch(opts, :config_root))
    end
  end

  defp registry_path_from_root({:ok, root}) do
    if valid_path?(root),
      do: {:ok, LocalConfig.target_registry_path(config_root: root)},
      else: :error
  end

  defp registry_path_from_root(:error), do: {:ok, LocalConfig.target_registry_path()}

  defp expanded_path(path) do
    if valid_path?(path), do: {:ok, Path.expand(path)}, else: :error
  end

  defp read_registry(path) do
    case FileStore.read(path) do
      {:ok, result} -> {:ok, result}
      {:error, %TargetRegistry.Error{} = source} -> registry_error(source)
    end
  end

  defp registry_error(source) do
    {:error, %Error{code: source.code, message: source.message, path: source.path}}
  end

  defp plan_dir(opts, registry_path) do
    cond do
      Keyword.has_key?(opts, :registry_path) ->
        Path.join(Path.dirname(registry_path), "target-plans")

      Keyword.has_key?(opts, :config_root) ->
        LocalConfig.target_plan_dir(config_root: Keyword.fetch!(opts, :config_root))

      true ->
        LocalConfig.target_plan_dir()
    end
  end

  defp decode_registry(%{bytes: bytes, generation: generation}, registry_path) do
    with {:ok, document} <- decode_yaml(bytes),
         {:ok, snapshot} <- validate_document(document) do
      snapshot =
        snapshot
        |> Map.merge(%{
          path: registry_path,
          source_hash: generation,
          generation: generation
        })
        |> Validation.validate(registry_path: registry_path)

      {:ok, document, snapshot}
    end
  end

  defp decode_yaml(bytes) do
    case Yaml.decode(bytes) do
      {:ok, document} ->
        {:ok, document}

      {:error, source} ->
        error(source.code, source.message, source.path)
    end
  end

  defp validate_document(document) do
    case Schema.validate(document) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, %TargetRegistry.Error{} = source} -> registry_error(source)
    end
  end

  defp plan_add(
         command,
         registry_path,
         plan_dir,
         current_file,
         current_document,
         current_snapshot,
         opts
       ) do
    cond do
      not current_snapshot.globally_valid? ->
        nonapplicable_plan(command, registry_path, current_file, current_snapshot, [], opts)

      Map.has_key?(current_document["targets"], command.target_id) ->
        diagnostic = %{
          "severity" => "error",
          "scope" => %{"type" => "target", "id" => command.target_id},
          "path" => "$.targets.#{command.target_id}",
          "code" => "duplicate_target_id",
          "message" => "target ID already exists"
        }

        nonapplicable_plan(command, registry_path, current_file, current_snapshot, [diagnostic], opts)

      true ->
        build_add_plan(
          command,
          registry_path,
          plan_dir,
          current_file,
          current_document,
          current_snapshot,
          opts
        )
    end
  end

  defp build_add_plan(
         command,
         registry_path,
         plan_dir,
         current_file,
         current_document,
         current_snapshot,
         opts
       ) do
    requested_document = put_in(current_document, ["targets", command.target_id], command.target)
    normalized_target = command.target |> Map.put("state", "paused") |> Map.delete("dispatch_mode")
    proposed_document = put_in(current_document, ["targets", command.target_id], normalized_target)
    proposed_bytes = Yaml.encode(proposed_document)

    with {:ok, requested_snapshot} <-
           snapshot_for(requested_document, current_file.bytes, registry_path, current_file.generation),
         {:ok, proposed_snapshot} <-
           snapshot_for(proposed_document, proposed_bytes, registry_path) do
      proposed_snapshot = Composition.compose(proposed_snapshot)
      registry_preview = Preview.preview(current_snapshot, proposed_snapshot, proposed_bytes)
      normalization_preview = Preview.preview(requested_snapshot, proposed_snapshot, proposed_bytes)

      persist_add_plan(%{
        command: command,
        registry_path: registry_path,
        plan_dir: plan_dir,
        current_file: current_file,
        proposed_snapshot: proposed_snapshot,
        proposed_bytes: proposed_bytes,
        registry_preview: registry_preview,
        normalization_preview: normalization_preview,
        opts: opts
      })
    end
  end

  defp persist_add_plan(%{
         command: command,
         registry_path: registry_path,
         plan_dir: plan_dir,
         current_file: current_file,
         proposed_snapshot: proposed_snapshot,
         proposed_bytes: proposed_bytes,
         registry_preview: registry_preview,
         normalization_preview: normalization_preview,
         opts: opts
       }) do
    if add_applicable?(proposed_snapshot, command.target_id) do
      created_at = now(opts)

      with {:ok, envelope} <-
             build_envelope(
               "add",
               command.target_id,
               %{"target_id" => command.target_id, "target" => command.target},
               registry_path,
               current_file.generation,
               %{},
               created_at,
               proposed_bytes
             ),
           {:ok, stored} <- store_envelope(plan_dir, envelope, opts) do
        {:ok,
         public_plan(
           stored,
           :add,
           command.target_id,
           registry_path,
           true,
           %{
             "registry" => json_value(registry_preview),
             "normalization" => json_value(normalization_preview)
           }
         )}
      end
    else
      nonapplicable_proposal(command, registry_path, current_file, registry_preview, opts)
    end
  end

  defp snapshot_for(document, bytes, registry_path, generation \\ nil) do
    with {:ok, snapshot} <- validate_document(document) do
      source_generation = generation || Preview.generation(bytes)

      snapshot =
        snapshot
        |> Map.merge(%{
          path: registry_path,
          source_hash: source_generation,
          generation: source_generation
        })
        |> Validation.validate(registry_path: registry_path)

      {:ok, snapshot}
    end
  end

  defp add_applicable?(snapshot, target_id) do
    blocking_codes = [
      :execution_profile_name_collision,
      :manifest_invalid,
      :manifest_not_found,
      :repository_mismatch,
      :unsafe_path
    ]

    %TargetRegistry.Target{diagnostics: target_diagnostics} =
      Map.fetch!(snapshot.targets, target_id)

    diagnostics = snapshot.diagnostics ++ target_diagnostics

    snapshot.globally_valid? and
      not Enum.any?(diagnostics, fn diagnostic ->
        diagnostic.scope == {:target, target_id} and diagnostic.code in blocking_codes
      end)
  end

  defp build_envelope(
         action,
         target_id,
         command,
         registry_path,
         expected_generation,
         source_hashes,
         created_at,
         proposed_bytes
       ) do
    fields = %{
      "action" => action,
      "command" => command,
      "created_at" => created_at,
      "envelope_version" => 1,
      "expected_generation" => expected_generation,
      "registry_path" => registry_path,
      "source_hashes" => source_hashes,
      "target_id" => target_id
    }

    case PlanStore.build(fields, proposed_bytes) do
      {:ok, envelope} -> {:ok, envelope}
      {:error, %TargetRegistry.Error{} = source} -> registry_error(source)
    end
  end

  defp store_envelope(plan_dir, envelope, opts) do
    store = Keyword.get(opts, :store_plan, &PlanStore.store/2)

    case invoke(fn -> store.(plan_dir, envelope) end) do
      {:ok, {:ok, stored}} when is_map(stored) -> {:ok, stored}
      {:ok, {:error, %TargetRegistry.Error{} = source}} -> registry_error(source)
      {:ok, {:error, %Error{}} = error} -> error
      _failure -> error(:plan_store_failed, "plan envelope could not be stored", plan_dir)
    end
  end

  defp public_plan(envelope, action, target_id, registry_path, applicable?, preview) do
    %Plan{
      id: envelope["plan_id"],
      action: action,
      target_id: target_id,
      registry_path: registry_path,
      expected_generation: envelope["expected_generation"],
      proposed_generation: envelope["proposed_generation"],
      applicable?: applicable?,
      preview: preview,
      created_at: envelope["created_at"]
    }
  end

  defp nonapplicable_proposal(command, registry_path, current_file, preview, opts) do
    {:ok,
     %Plan{
       id: nil,
       action: :add,
       target_id: command.target_id,
       registry_path: registry_path,
       expected_generation: current_file.generation,
       proposed_generation: preview.proposed_generation,
       applicable?: false,
       preview: %{"registry" => json_value(preview)},
       created_at: now(opts)
     }}
  end

  defp nonapplicable_plan(
         command,
         registry_path,
         current_file,
         current_snapshot,
         diagnostics,
         opts
       ) do
    registry_preview =
      current_snapshot
      |> Preview.preview(current_snapshot, current_file.bytes)
      |> json_value()
      |> Map.update!("diagnostics", &(&1 ++ diagnostics))

    {:ok,
     %Plan{
       id: nil,
       action: :add,
       target_id: command.target_id,
       registry_path: registry_path,
       expected_generation: current_file.generation,
       proposed_generation: current_file.generation,
       applicable?: false,
       preview: %{"registry" => registry_preview},
       created_at: now(opts)
     }}
  end

  defp now(opts) do
    provider =
      Keyword.get(opts, :now, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      end)

    case invoke(provider) do
      {:ok, value} when is_binary(value) -> value
      _invalid -> ""
    end
  end

  defp json_value(%TargetRegistry.Diagnostic{} = diagnostic) do
    %{
      "severity" => Atom.to_string(diagnostic.severity),
      "scope" => diagnostic_scope(diagnostic.scope),
      "path" => diagnostic.path,
      "code" => Atom.to_string(diagnostic.code),
      "message" => diagnostic.message
    }
  end

  defp json_value(%_struct{} = value), do: value |> Map.from_struct() |> json_value()

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {json_key(key), json_value(nested)} end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(nil), do: nil
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value) when is_binary(value) or is_number(value), do: value

  defp json_key(key) do
    if is_atom(key), do: Atom.to_string(key), else: key
  end

  defp diagnostic_scope(scope) when scope in [:registry, :host], do: Atom.to_string(scope)
  defp diagnostic_scope({:target, id}), do: %{"type" => "target", "id" => json_value(id)}

  defp valid_id?(value) when is_binary(value),
    do: String.valid?(value) and Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, value)

  defp valid_id?(_value), do: false

  defp valid_path?(path) when is_binary(path),
    do: path != "" and String.valid?(path) and String.trim(path) == path

  defp valid_path?(_path), do: false

  defp error(code, message, path), do: {:error, %Error{code: code, message: message, path: path}}
end
