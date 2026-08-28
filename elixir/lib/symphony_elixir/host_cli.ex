defmodule SymphonyElixir.HostCLI do
  @moduledoc false

  alias SymphonyElixir.OperatorCommandService
  alias SymphonyElixir.OperatorCommandService.Command
  alias SymphonyElixir.OperatorCommandService.PlanStore
  alias SymphonyElixir.TargetRegistry.Preview
  alias SymphonyElixir.TargetRegistry.Yaml

  @host_usage """
  Usage:
    symphony host target add <id> --input <target.yml> [--registry <path>] [--json]
    symphony host target add <id> --confirm <plan-id> [--registry <path>] [--json]
    symphony host target import <id> --workflow <path> --repo <path> [--connection <id>] [--runner <source>=<id>] [--registry <path>] [--json]
    symphony host target import <id> --confirm <plan-id> [--registry <path>] [--json]
    symphony host target plan <id> --patch <target-patch.yml> [--registry <path>] [--json]
    symphony host target patch <id> --confirm <plan-id> [--registry <path>] [--json]
    symphony host target activate <id> [--mode <watch|explicit>] [--registry <path>] [--json]
    symphony host target activate <id> --confirm <plan-id> [--registry <path>] [--json]
    symphony host target pause <id> [--registry <path>] [--json]
    symphony host target pause <id> --confirm <plan-id> [--registry <path>] [--json]
    symphony host target drain <id> [--registry <path>] [--json]
    symphony host target drain <id> --confirm <plan-id> [--registry <path>] [--json]
    symphony host target retire <id> [--registry <path>] [--json]
    symphony host target retire <id> --confirm <plan-id> [--registry <path>] [--json]
  """

  @add_usage """
  Usage:
    symphony host target add <id> --input <target.yml> [--registry <path>] [--json]
    symphony host target add <id> --confirm <plan-id> [--registry <path>] [--json]
  """

  @import_usage """
  Usage:
    symphony host target import <id> --workflow <path> --repo <path> [--connection <id>] [--runner <source>=<id>] [--registry <path>] [--json]
    symphony host target import <id> --confirm <plan-id> [--registry <path>] [--json]
  """

  @plan_usage """
  Usage:
    symphony host target plan <id> --patch <target-patch.yml> [--registry <path>] [--json]
  """

  @patch_usage """
  Usage:
    symphony host target patch <id> --confirm <plan-id> [--registry <path>] [--json]
  """

  @activate_usage """
  Usage:
    symphony host target activate <id> [--mode <watch|explicit>] [--registry <path>] [--json]
    symphony host target activate <id> --confirm <plan-id> [--registry <path>] [--json]
  """

  @pause_usage """
  Usage:
    symphony host target pause <id> [--registry <path>] [--json]
    symphony host target pause <id> --confirm <plan-id> [--registry <path>] [--json]
  """

  @drain_usage """
  Usage:
    symphony host target drain <id> [--registry <path>] [--json]
    symphony host target drain <id> --confirm <plan-id> [--registry <path>] [--json]
  """

  @retire_usage """
  Usage:
    symphony host target retire <id> [--registry <path>] [--json]
    symphony host target retire <id> --confirm <plan-id> [--registry <path>] [--json]
  """

  @actions [:add, :import, :patch, :activate, :pause, :drain, :retire]
  @lifecycle_actions [:activate, :pause, :drain, :retire]

  @target_id_regex ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
  @plan_id_regex ~r/^[0-9a-f]{64}$/
  @max_path_length 4096
  @max_timestamp_length 64
  @max_preview_depth 32
  @max_preview_nodes 10_000
  @max_preview_key_bytes 512
  @max_preview_string_leaf_bytes 262_144
  @max_preview_aggregate_bytes 1_048_576
  @max_preview_integer_external_bytes div(@max_preview_aggregate_bytes * 1_000, 2_400)
  @json_short_escapes %{
    ?\b => "\\b",
    ?\t => "\\t",
    ?\n => "\\n",
    ?\f => "\\f",
    ?\r => "\\r",
    ?" => "\\\"",
    ?\\ => "\\\\"
  }

  @type plan_fn ::
          (Command.t(), keyword() ->
             {:ok, OperatorCommandService.Plan.t()} | {:error, OperatorCommandService.Error.t()})
  @type confirm_action_fn ::
          (String.t(), String.t(), atom(), true, keyword() ->
             {:ok, OperatorCommandService.ApplyResult.t()} | {:error, OperatorCommandService.Error.t()})
  @type confirm_fn ::
          (String.t(), String.t(), true, keyword() ->
             {:ok, OperatorCommandService.ApplyResult.t()} | {:error, OperatorCommandService.Error.t()})

  @type deps :: %{
          optional(:plan) => plan_fn(),
          optional(:confirm_action) => confirm_action_fn(),
          optional(:confirm) => confirm_fn(),
          optional(:read_file) => (String.t() -> {:ok, String.t()} | {:error, term()}),
          optional(:yaml_decode) => (String.t() -> {:ok, map()} | {:error, term()}),
          optional(:json_encode) => (term() -> {:ok, String.t()} | {:error, term()})
        }

  @spec evaluate([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def evaluate(args), do: evaluate(args, %{})

  @spec evaluate([String.t()], deps()) :: {:ok, String.t()} | {:error, String.t()}
  def evaluate([], _deps) do
    {:error, host_usage()}
  end

  def evaluate(["--help"], _deps) do
    {:ok, host_usage()}
  end

  def evaluate(["target", "--help"], _deps) do
    {:ok, host_usage()}
  end

  def evaluate(["target", "add", "--help"], _deps) do
    {:ok, add_usage()}
  end

  def evaluate(["target", "add" | args], deps) do
    evaluate_add(args, deps)
  end

  def evaluate(["target", "import", "--help"], _deps) do
    {:ok, import_usage()}
  end

  def evaluate(["target", "import" | args], deps) do
    evaluate_import(args, deps)
  end

  def evaluate(["target", "plan", "--help"], _deps) do
    {:ok, plan_usage()}
  end

  def evaluate(["target", "plan" | args], deps) do
    evaluate_plan(args, deps)
  end

  def evaluate(["target", "patch", "--help"], _deps) do
    {:ok, patch_usage()}
  end

  def evaluate(["target", "patch" | args], deps) do
    evaluate_patch(args, deps)
  end

  for action <- @lifecycle_actions do
    action_name = Atom.to_string(action)

    def evaluate(["target", unquote(action_name), "--help"], _deps) do
      {:ok, lifecycle_usage(unquote(action))}
    end

    def evaluate(["target", unquote(action_name) | args], deps) do
      evaluate_lifecycle(unquote(action), args, deps)
    end
  end

  def evaluate(["target", _unknown | _args], _deps) do
    {:error, host_usage()}
  end

  def evaluate(_args, _deps) do
    {:error, host_usage()}
  end

  defp evaluate_lifecycle(action, args, deps) do
    usage = lifecycle_usage(action)

    case parse_lifecycle_args(action, args) do
      {:ok, target_id, opts} ->
        dispatch_lifecycle(action, target_id, opts, deps)

      :error ->
        if json_selected?(args),
          do: json_error_envelope("invalid_arguments", "Invalid arguments", usage, deps),
          else: {:error, usage}
    end
  end

  defp parse_lifecycle_args(action, args) do
    option_keys =
      if action == :activate,
        do: [:mode, :confirm, :registry, :json],
        else: [:confirm, :registry, :json]

    strict_options =
      if action == :activate,
        do: [mode: :keep, confirm: :keep, registry: :keep, json: :boolean],
        else: [confirm: :keep, registry: :keep, json: :boolean]

    with :ok <- prevalidate_argv(args, option_keys),
         {opts, [target_id], []} <- OptionParser.parse(args, strict: strict_options),
         true <- valid_target_id?(target_id),
         true <- valid_singleton_counts?(opts, option_keys),
         true <- valid_lifecycle_mode?(action, opts) do
      {:ok, target_id, opts}
    else
      _invalid -> :error
    end
  end

  defp valid_lifecycle_mode?(:activate, opts) do
    modes = Keyword.get_values(opts, :mode)
    confirm? = Keyword.has_key?(opts, :confirm)

    length(modes) <= 1 and Enum.all?(modes, &(&1 in ["explicit", "watch"])) and
      not (confirm? and modes != [])
  end

  defp valid_lifecycle_mode?(action, opts) when action in [:pause, :drain, :retire],
    do: not Keyword.has_key?(opts, :mode)

  defp dispatch_lifecycle(action, target_id, opts, deps) do
    if Keyword.has_key?(opts, :confirm) do
      do_lifecycle_confirm(action, target_id, opts, deps)
    else
      do_lifecycle_preview(action, target_id, opts, deps)
    end
  end

  defp do_lifecycle_preview(action, target_id, opts, deps) do
    json? = Keyword.get(opts, :json, false)
    registry_opt = registry_opt(opts)
    expected_path = expected_registry_path(registry_opt)

    with command <- lifecycle_command(action, target_id, Keyword.get(opts, :mode)),
         service_opts <- build_service_opts(registry_opt),
         {:ok, plan} <- plan(command, service_opts, deps),
         :ok <- validate_plan_for_command(plan, action, target_id, expected_path),
         {:ok, output} <- render_plan_output(plan, json?, deps) do
      {:ok, output}
    else
      error -> format_host_error(error, json?, lifecycle_usage(action), deps)
    end
  end

  defp do_lifecycle_confirm(action, target_id, opts, deps) do
    plan_id = Keyword.fetch!(opts, :confirm)
    json? = Keyword.get(opts, :json, false)
    registry_opt = registry_opt(opts)
    expected_path = expected_registry_path(registry_opt)

    with :ok <- validate_plan_id(plan_id),
         service_opts <- build_service_opts(registry_opt),
         {:ok, result} <- confirm_action(target_id, plan_id, action, true, service_opts, deps),
         :ok <- validate_apply_result_for_command(result, action, target_id, plan_id, expected_path),
         {:ok, output} <- render_apply_output(result, json?, deps) do
      {:ok, output}
    else
      error -> format_host_error(error, json?, lifecycle_usage(action), deps)
    end
  end

  defp lifecycle_command(:activate, target_id, mode) do
    %Command.Activate{
      target_id: target_id,
      dispatch_mode: lifecycle_dispatch_mode(mode)
    }
  end

  defp lifecycle_command(:pause, target_id, nil), do: %Command.Pause{target_id: target_id}
  defp lifecycle_command(:drain, target_id, nil), do: %Command.Drain{target_id: target_id}
  defp lifecycle_command(:retire, target_id, nil), do: %Command.Retire{target_id: target_id}

  defp lifecycle_dispatch_mode("explicit"), do: :explicit
  defp lifecycle_dispatch_mode("watch"), do: :watch
  defp lifecycle_dispatch_mode(nil), do: nil

  defp evaluate_add(args, deps) do
    case parse_add_args(args) do
      {:ok, target_id, opts} ->
        dispatch_add(target_id, opts, deps)

      :error ->
        if json_selected?(args),
          do: json_error_envelope("invalid_arguments", "Invalid arguments", add_usage(), deps),
          else: {:error, add_usage()}
    end
  end

  defp parse_add_args(args) do
    with :ok <- prevalidate_argv(args, [:input, :confirm, :registry, :json]),
         {opts, [target_id], []} <-
           OptionParser.parse(args,
             strict: [
               input: :keep,
               confirm: :keep,
               registry: :keep,
               json: :boolean
             ]
           ),
         true <- valid_target_id?(target_id),
         true <- valid_singleton_counts?(opts, [:input, :confirm, :registry, :json]) do
      {:ok, target_id, opts}
    else
      _invalid -> :error
    end
  end

  defp dispatch_add(target_id, opts, deps) do
    json? = Keyword.get(opts, :json, false)

    case add_mode(opts) do
      :preview ->
        do_add_preview(target_id, opts, deps)

      :confirm ->
        do_add_confirm(target_id, opts, deps)

      :invalid ->
        if json?,
          do: json_error_envelope("invalid_arguments", "Invalid arguments", add_usage(), deps),
          else: {:error, add_usage()}
    end
  end

  defp add_mode(opts) do
    has_input = Keyword.has_key?(opts, :input)
    has_confirm = Keyword.has_key?(opts, :confirm)
    input_count = length(Keyword.get_values(opts, :input))
    confirm_count = length(Keyword.get_values(opts, :confirm))

    cond do
      has_input and has_confirm -> :invalid
      has_input and input_count == 1 -> :preview
      has_confirm and confirm_count == 1 -> :confirm
      true -> :invalid
    end
  end

  defp evaluate_import(args, deps) do
    case parse_import_args(args) do
      {:ok, target_id, opts} ->
        dispatch_import(target_id, opts, deps)

      :error ->
        if json_selected?(args),
          do: json_error_envelope("invalid_arguments", "Invalid arguments", import_usage(), deps),
          else: {:error, import_usage()}
    end
  end

  defp parse_import_args(args) do
    with :ok <- prevalidate_argv(args, [:workflow, :repo, :connection, :registry, :confirm, :json]),
         :ok <- prevalidate_runner_assignment(args),
         {opts, [target_id], []} <-
           OptionParser.parse(args,
             strict: [
               workflow: :keep,
               repo: :keep,
               connection: :keep,
               runner: :keep,
               registry: :keep,
               confirm: :keep,
               json: :boolean
             ]
           ),
         true <- valid_target_id?(target_id),
         true <- valid_singleton_counts?(opts, [:workflow, :repo, :connection, :registry, :confirm, :json]) do
      {:ok, target_id, opts}
    else
      _invalid -> :error
    end
  end

  defp prevalidate_runner_assignment(args) do
    if Enum.any?(args, &String.starts_with?(&1, "--runner=")), do: :error, else: :ok
  end

  defp dispatch_import(target_id, opts, deps) do
    json? = Keyword.get(opts, :json, false)

    case import_mode(opts) do
      :preview ->
        do_import_preview(target_id, opts, deps)

      :confirm ->
        do_import_confirm(target_id, opts, deps)

      :invalid ->
        if json?,
          do: json_error_envelope("invalid_arguments", "Invalid arguments", import_usage(), deps),
          else: {:error, import_usage()}
    end
  end

  defp import_mode(opts) do
    cond do
      import_confirm_only?(opts) -> :confirm
      import_preview_ready?(opts) -> :preview
      true -> :invalid
    end
  end

  defp import_confirm_only?(opts) do
    has_confirm = Keyword.has_key?(opts, :confirm)
    has_workflow = Keyword.has_key?(opts, :workflow)
    has_repo = Keyword.has_key?(opts, :repo)
    confirm_count = length(Keyword.get_values(opts, :confirm))

    has_confirm and confirm_count == 1 and not has_workflow and not has_repo and
      not Keyword.has_key?(opts, :connection) and not Keyword.has_key?(opts, :runner)
  end

  defp import_preview_ready?(opts) do
    has_workflow = Keyword.has_key?(opts, :workflow)
    has_repo = Keyword.has_key?(opts, :repo)
    workflow_count = length(Keyword.get_values(opts, :workflow))
    repo_count = length(Keyword.get_values(opts, :repo))

    has_workflow and has_repo and workflow_count == 1 and repo_count == 1 and
      not Keyword.has_key?(opts, :confirm)
  end

  defp evaluate_plan(args, deps) do
    with :ok <- prevalidate_argv(args, [:patch, :registry, :json]),
         {opts, [target_id], []} <-
           OptionParser.parse(args,
             strict: [
               patch: :keep,
               registry: :keep,
               json: :boolean
             ]
           ),
         true <- valid_target_id?(target_id),
         true <- Keyword.has_key?(opts, :patch),
         true <- length(Keyword.get_values(opts, :patch)) == 1,
         true <- valid_singleton_counts?(opts, [:patch, :registry, :json]) do
      do_plan_preview(target_id, opts, deps)
    else
      _invalid ->
        if json_selected?(args),
          do: json_error_envelope("invalid_arguments", "Invalid arguments", plan_usage(), deps),
          else: {:error, plan_usage()}
    end
  end

  defp evaluate_patch(args, deps) do
    with :ok <- prevalidate_argv(args, [:confirm, :registry, :json]),
         {opts, [target_id], []} <-
           OptionParser.parse(args,
             strict: [
               confirm: :keep,
               registry: :keep,
               json: :boolean
             ]
           ),
         true <- valid_target_id?(target_id),
         true <- Keyword.has_key?(opts, :confirm),
         true <- length(Keyword.get_values(opts, :confirm)) == 1,
         true <- valid_singleton_counts?(opts, [:confirm, :registry, :json]) do
      do_patch_confirm(target_id, opts, deps)
    else
      _invalid ->
        if json_selected?(args),
          do: json_error_envelope("invalid_arguments", "Invalid arguments", patch_usage(), deps),
          else: {:error, patch_usage()}
    end
  end

  defp do_add_preview(target_id, opts, deps) do
    input_path = Keyword.fetch!(opts, :input)
    json? = Keyword.get(opts, :json, false)
    registry_opt = registry_opt(opts)
    expected_path = expected_registry_path(registry_opt)

    with {:ok, file_content} <- read_file(input_path, deps),
         {:ok, target} <- yaml_decode(file_content, deps),
         :ok <- validate_target_only_map(target),
         command <- %Command.Add{target_id: target_id, target: target},
         service_opts <- build_service_opts(registry_opt),
         {:ok, plan} <- plan(command, service_opts, deps),
         :ok <- validate_plan_for_command(plan, :add, target_id, expected_path),
         {:ok, output} <- render_plan_output(plan, json?, deps) do
      {:ok, output}
    else
      error -> format_host_error(error, json?, add_usage(), deps)
    end
  end

  defp do_add_confirm(target_id, opts, deps) do
    plan_id = Keyword.fetch!(opts, :confirm)
    json? = Keyword.get(opts, :json, false)
    registry_opt = registry_opt(opts)
    expected_path = expected_registry_path(registry_opt)

    with :ok <- validate_plan_id(plan_id),
         service_opts <- build_service_opts(registry_opt),
         {:ok, result} <- confirm_action(target_id, plan_id, :add, true, service_opts, deps),
         :ok <- validate_apply_result_for_command(result, :add, target_id, plan_id, expected_path),
         {:ok, output} <- render_apply_output(result, json?, deps) do
      {:ok, output}
    else
      error -> format_host_error(error, json?, add_usage(), deps)
    end
  end

  defp do_import_preview(target_id, opts, deps) do
    workflow = Keyword.fetch!(opts, :workflow)
    repo = Keyword.fetch!(opts, :repo)
    connection_id = Keyword.get(opts, :connection)
    runners = Keyword.get_values(opts, :runner)
    json? = Keyword.get(opts, :json, false)
    registry_opt = registry_opt(opts)
    expected_path = expected_registry_path(registry_opt)

    with {:ok, runner_ids} <- parse_runner_mappings(runners),
         command <-
           %Command.Import{
             target_id: target_id,
             workflow: workflow,
             repo: repo,
             connection_id: connection_id,
             runner_ids: runner_ids
           },
         service_opts <- build_service_opts(registry_opt),
         {:ok, plan} <- plan(command, service_opts, deps),
         :ok <- validate_plan_for_command(plan, :import, target_id, expected_path),
         {:ok, output} <- render_plan_output(plan, json?, deps) do
      {:ok, output}
    else
      error -> format_host_error(error, json?, import_usage(), deps)
    end
  end

  defp do_import_confirm(target_id, opts, deps) do
    plan_id = Keyword.fetch!(opts, :confirm)
    json? = Keyword.get(opts, :json, false)
    registry_opt = registry_opt(opts)
    expected_path = expected_registry_path(registry_opt)

    with :ok <- validate_plan_id(plan_id),
         service_opts <- build_service_opts(registry_opt),
         {:ok, result} <- confirm_action(target_id, plan_id, :import, true, service_opts, deps),
         :ok <- validate_apply_result_for_command(result, :import, target_id, plan_id, expected_path),
         {:ok, output} <- render_apply_output(result, json?, deps) do
      {:ok, output}
    else
      error -> format_host_error(error, json?, import_usage(), deps)
    end
  end

  defp do_plan_preview(target_id, opts, deps) do
    patch_path = Keyword.fetch!(opts, :patch)
    json? = Keyword.get(opts, :json, false)
    registry_opt = registry_opt(opts)
    expected_path = expected_registry_path(registry_opt)

    with {:ok, file_content} <- read_file(patch_path, deps),
         {:ok, changes} <- yaml_decode(file_content, deps),
         :ok <- validate_target_only_map(changes),
         command <- %Command.Patch{target_id: target_id, changes: changes},
         service_opts <- build_service_opts(registry_opt),
         {:ok, plan} <- plan(command, service_opts, deps),
         :ok <- validate_plan_for_command(plan, :patch, target_id, expected_path),
         {:ok, output} <- render_plan_output(plan, json?, deps) do
      {:ok, output}
    else
      error -> format_host_error(error, json?, plan_usage(), deps)
    end
  end

  defp do_patch_confirm(target_id, opts, deps) do
    plan_id = Keyword.fetch!(opts, :confirm)
    json? = Keyword.get(opts, :json, false)
    registry_opt = registry_opt(opts)
    expected_path = expected_registry_path(registry_opt)

    with :ok <- validate_plan_id(plan_id),
         service_opts <- build_service_opts(registry_opt),
         {:ok, result} <- confirm_action(target_id, plan_id, :patch, true, service_opts, deps),
         :ok <- validate_apply_result_for_command(result, :patch, target_id, plan_id, expected_path),
         {:ok, output} <- render_apply_output(result, json?, deps) do
      {:ok, output}
    else
      error -> format_host_error(error, json?, patch_usage(), deps)
    end
  end

  defp read_file(path, deps) do
    reader = Map.get(deps, :read_file, &File.read/1)

    case safe_invoke(fn -> reader.(path) end) do
      {:ok, {:ok, content}} when is_binary(content) -> {:ok, content}
      _other -> {:error, "file_read_failed"}
    end
  end

  defp yaml_decode(content, deps) do
    decoder = Map.get(deps, :yaml_decode, &Yaml.decode/1)

    case safe_invoke(fn -> decoder.(content) end) do
      {:ok, {:ok, map}} when is_map(map) ->
        validate_yaml_map_keys(map)

      {:ok, {:error, %{code: code, message: message}}} when is_atom(code) and is_binary(message) ->
        {:error, %OperatorCommandService.Error{code: code, message: message}}

      _other ->
        {:error, "yaml_decode_failed"}
    end
  end

  defp validate_yaml_map_keys(map) do
    if map_size(map) == 0 or Enum.all?(map, fn {k, _v} -> is_binary(k) end) do
      {:ok, map}
    else
      {:error, "yaml_decode_failed"}
    end
  end

  @target_root_keys MapSet.new(~w(display_name state dispatch_mode repo worktree linear runners concurrency budgets checks external_side_effects scheduling))
  @registry_envelope_keys MapSet.new(~w(version host targets))

  defp validate_target_only_map(map) when is_map(map) do
    keys = Map.keys(map)

    cond do
      Enum.any?(keys, &MapSet.member?(@registry_envelope_keys, &1)) ->
        {:error, "invalid_target_input"}

      not Enum.all?(keys, &MapSet.member?(@target_root_keys, &1)) ->
        {:error, "invalid_target_input"}

      true ->
        :ok
    end
  end

  defp parse_runner_mappings(runners) do
    Enum.reduce_while(Enum.with_index(runners, 1), {:ok, %{}}, fn {mapping, index}, {:ok, acc} ->
      parse_single_runner(mapping, acc, index)
    end)
  end

  defp parse_single_runner(mapping, acc, index) do
    case String.split(mapping, "=", parts: 2) do
      [source, id] -> validate_runner_entry(source, id, acc, index)
      _invalid -> {:halt, {:error, "invalid runner mapping at occurrence #{index}"}}
    end
  end

  defp validate_runner_entry(source, id, acc, index) do
    cond do
      not valid_target_id?(source) ->
        {:halt, {:error, "invalid runner source at occurrence #{index}"}}

      not valid_target_id?(id) ->
        {:halt, {:error, "invalid runner id at occurrence #{index}"}}

      Map.has_key?(acc, source) ->
        {:halt, {:error, "duplicate runner source at occurrence #{index}"}}

      id_in_runner_ids?(acc, id) ->
        {:halt, {:error, "duplicate runner id at occurrence #{index}"}}

      true ->
        {:cont, {:ok, Map.put(acc, source, id)}}
    end
  end

  defp id_in_runner_ids?(acc, id) do
    Enum.any?(acc, fn {_key, value} -> value == id end)
  end

  defp validate_plan_for_command(%OperatorCommandService.Plan{} = plan, expected_action, expected_target_id, expected_registry_path) do
    with true <- valid_plan_field_types?(plan),
         true <- plan.action == expected_action,
         true <- plan.target_id == expected_target_id,
         true <- plan.registry_path == expected_registry_path do
      :ok
    else
      false -> {:error, "plan_validation_failed"}
    end
  end

  defp valid_plan_field_types?(plan) do
    valid_plan_base?(plan) and
      valid_generation?(plan.expected_generation) and
      valid_generation?(plan.proposed_generation) and
      valid_created_at?(plan.created_at) and
      valid_preview?(plan.preview)
  end

  defp valid_plan_base?(plan) do
    is_binary(plan.target_id) and
      plan.action in @actions and
      valid_plan_id_applicability?(plan.id, plan.applicable?) and
      valid_registry_path?(plan.registry_path) and
      is_boolean(plan.applicable?)
  end

  defp valid_plan_id_applicability?(nil, false), do: true

  defp valid_plan_id_applicability?(id, true) when is_binary(id) do
    String.valid?(id) and Regex.match?(@plan_id_regex, id)
  end

  defp valid_plan_id_applicability?(_id, _applicable?), do: false

  defp validate_apply_result_for_command(%OperatorCommandService.ApplyResult{} = result, expected_action, expected_target_id, expected_plan_id, expected_registry_path) do
    with true <- valid_apply_result_field_types?(result),
         true <- result.action == expected_action,
         true <- result.target_id == expected_target_id,
         true <- result.plan_id == expected_plan_id,
         true <- result.registry_path == expected_registry_path do
      :ok
    else
      false -> {:error, "apply_result_validation_failed"}
    end
  end

  defp valid_apply_result_field_types?(result) do
    valid_apply_plan_id?(result.plan_id) and
      result.action in @actions and
      is_binary(result.target_id) and
      valid_registry_path?(result.registry_path) and
      valid_generation?(result.old_generation) and
      valid_generation?(result.new_generation) and
      result.committed? == true and
      result.plan_consumed? == true
  end

  defp valid_apply_plan_id?(value) when is_binary(value) do
    String.valid?(value) and Regex.match?(@plan_id_regex, value)
  end

  defp valid_apply_plan_id?(_value), do: false

  defp valid_registry_path?(path) when is_binary(path) do
    String.valid?(path) and
      String.trim(path) == path and
      path != "" and
      String.length(path) <= @max_path_length and
      Path.type(path) == :absolute
  end

  defp valid_registry_path?(_path), do: false

  defp valid_created_at?(value) when is_binary(value) do
    if String.valid?(value) and String.length(value) <= @max_timestamp_length do
      case DateTime.from_iso8601(value) do
        {:ok, _datetime, 0} -> true
        _ -> false
      end
    else
      false
    end
  end

  defp valid_created_at?(_value), do: false

  defp valid_preview?(value) do
    if is_map(value) do
      case do_valid_preview?(value, 0, @max_preview_nodes, @max_preview_aggregate_bytes) do
        {true, _remaining_nodes, _remaining_bytes} -> true
        {false, _remaining_nodes, _remaining_bytes} -> false
      end
    else
      false
    end
  end

  defp do_valid_preview?(_value, depth, remaining_nodes, remaining_bytes)
       when depth > @max_preview_depth,
       do: {false, remaining_nodes, remaining_bytes}

  defp do_valid_preview?(_value, _depth, remaining_nodes, remaining_bytes)
       when remaining_nodes <= 0,
       do: {false, remaining_nodes, remaining_bytes}

  defp do_valid_preview?(nil, _depth, remaining_nodes, remaining_bytes),
    do: charge_preview_scalar("null", remaining_nodes, remaining_bytes)

  defp do_valid_preview?(true, _depth, remaining_nodes, remaining_bytes),
    do: charge_preview_scalar("true", remaining_nodes, remaining_bytes)

  defp do_valid_preview?(false, _depth, remaining_nodes, remaining_bytes),
    do: charge_preview_scalar("false", remaining_nodes, remaining_bytes)

  defp do_valid_preview?(n, _depth, remaining_nodes, remaining_bytes) when is_integer(n) do
    if :erlang.external_size(n) <= @max_preview_integer_external_bytes do
      n
      |> Integer.to_string()
      |> charge_preview_scalar(remaining_nodes, remaining_bytes)
    else
      {false, remaining_nodes, remaining_bytes}
    end
  end

  defp do_valid_preview?(n, _depth, remaining_nodes, remaining_bytes) when is_float(n) do
    n
    |> encode_preview_scalar()
    |> charge_preview_scalar(remaining_nodes, remaining_bytes)
  end

  defp do_valid_preview?(s, _depth, remaining_nodes, remaining_bytes) when is_binary(s) do
    with true <- String.valid?(s),
         true <- byte_size(s) <= @max_preview_string_leaf_bytes do
      s
      |> encode_preview_scalar()
      |> charge_preview_scalar(remaining_nodes, remaining_bytes)
    else
      _invalid -> {false, remaining_nodes, remaining_bytes}
    end
  end

  defp do_valid_preview?([], _depth, remaining_nodes, remaining_bytes),
    do: {true, remaining_nodes - 1, remaining_bytes}

  defp do_valid_preview?([head | tail], depth, remaining_nodes, remaining_bytes)
       when is_list(tail) do
    case do_valid_preview?(head, depth + 1, remaining_nodes - 1, remaining_bytes) do
      {true, rem_nodes, rem_bytes} -> do_valid_preview?(tail, depth, rem_nodes, rem_bytes)
      {false, rem_nodes, rem_bytes} -> {false, rem_nodes, rem_bytes}
    end
  end

  defp do_valid_preview?([_head | _non_list], _depth, remaining_nodes, remaining_bytes),
    do: {false, remaining_nodes, remaining_bytes}

  defp do_valid_preview?(map, depth, remaining_nodes, remaining_bytes) when is_map(map) do
    do_valid_preview_map?(map, depth, remaining_nodes - 1, remaining_bytes)
  end

  defp do_valid_preview?(_value, _depth, remaining_nodes, remaining_bytes),
    do: {false, remaining_nodes, remaining_bytes}

  defp charge_preview_scalar(rendered, remaining_nodes, remaining_bytes) do
    rendered_bytes = byte_size(rendered)

    if rendered_bytes <= remaining_bytes do
      {true, remaining_nodes - 1, remaining_bytes - rendered_bytes}
    else
      {false, remaining_nodes, remaining_bytes}
    end
  end

  defp encode_preview_scalar(value) when is_float(value) do
    value
    |> Jason.Encode.float()
    |> IO.iodata_to_binary()
  end

  defp encode_preview_scalar(value) when is_binary(value) do
    [?", escape_preview_string(value), ?"]
    |> IO.iodata_to_binary()
  end

  defp escape_preview_string(<<>>), do: []

  defp escape_preview_string(<<byte, rest::binary>>) do
    escaped =
      case Map.fetch(@json_short_escapes, byte) do
        {:ok, sequence} -> sequence
        :error when byte < 0x20 -> "\\u00" <> Base.encode16(<<byte>>)
        :error -> <<byte>>
      end

    [escaped | escape_preview_string(rest)]
  end

  defp do_valid_preview_map?(map, depth, remaining_nodes, remaining_bytes) do
    do_valid_preview_map_entries(Map.to_list(map), depth, remaining_nodes, remaining_bytes)
  end

  defp do_valid_preview_map_entries([], _depth, remaining_nodes, remaining_bytes),
    do: {true, remaining_nodes, remaining_bytes}

  defp do_valid_preview_map_entries([{k, v} | rest], depth, remaining_nodes, remaining_bytes) do
    do_valid_preview_map_entry(k, v, rest, depth, remaining_nodes, remaining_bytes)
  end

  defp do_valid_preview_map_entry(k, _v, _rest, _depth, remaining_nodes, remaining_bytes)
       when not is_binary(k) or remaining_nodes <= 0,
       do: {false, remaining_nodes, remaining_bytes}

  defp do_valid_preview_map_entry(k, v, rest, depth, remaining_nodes, remaining_bytes) do
    with true <- String.valid?(k),
         key_bytes = byte_size(k),
         true <- key_bytes <= @max_preview_key_bytes and key_bytes <= remaining_bytes,
         {true, rem_nodes, rem_bytes} <-
           do_valid_preview?(v, depth + 1, remaining_nodes - 1, remaining_bytes - key_bytes) do
      do_valid_preview_map_entries(rest, depth, rem_nodes, rem_bytes)
    else
      false -> {false, remaining_nodes, remaining_bytes}
      {false, rem_nodes, rem_bytes} -> {false, rem_nodes, rem_bytes}
    end
  end

  defp valid_generation?(gen) when is_binary(gen) do
    Regex.match?(~r/^sha256:[0-9a-f]{64}$/, gen)
  end

  defp valid_generation?(_gen) do
    false
  end

  defp redact_plan(%OperatorCommandService.Plan{} = plan) do
    projection = %{
      "id" => plan.id,
      "action" => Atom.to_string(plan.action),
      "target_id" => plan.target_id,
      "registry_path" => plan.registry_path,
      "expected_generation" => plan.expected_generation,
      "proposed_generation" => plan.proposed_generation,
      "applicable?" => plan.applicable?,
      "preview" => plan.preview,
      "created_at" => plan.created_at
    }

    projection
    |> Map.to_list()
    |> Preview.redact()
    |> Map.new()
  end

  defp redact_apply_result(%OperatorCommandService.ApplyResult{} = result) do
    projection = %{
      "plan_id" => result.plan_id,
      "action" => Atom.to_string(result.action),
      "target_id" => result.target_id,
      "registry_path" => result.registry_path,
      "old_generation" => result.old_generation,
      "new_generation" => result.new_generation,
      "committed?" => result.committed?,
      "plan_consumed?" => result.plan_consumed?
    }

    projection
    |> Map.to_list()
    |> Preview.redact()
    |> Map.new()
  end

  defp registry_opt(opts) do
    case Keyword.get(opts, :registry) do
      nil -> []
      path -> [registry_path: path]
    end
  end

  defp expected_registry_path(registry_opt) do
    case resolve_registry_path(registry_opt) do
      {:ok, path} -> path
      {:error, _reason} -> nil
    end
  end

  defp build_service_opts(registry_opt) do
    registry_opt
  end

  defp plan(command, opts, deps) do
    planner = Map.get(deps, :plan, &OperatorCommandService.plan/2)

    case safe_invoke(fn -> planner.(command, opts) end) do
      {:ok, {:ok, %OperatorCommandService.Plan{} = plan}} ->
        {:ok, plan}

      {:ok, {:error, %{code: code, message: message}}} when is_atom(code) ->
        {:error, %OperatorCommandService.Error{code: code, message: message}}

      _other ->
        {:error, "plan_dependency_failed"}
    end
  end

  defp confirm_action(target_id, plan_id, expected_action, confirmation, opts, deps) do
    action =
      Map.get(deps, :confirm_action, fn tid, pid, exp, conf, opts ->
        default_confirm_action(tid, pid, exp, conf, opts, deps)
      end)

    case safe_invoke(fn -> action.(target_id, plan_id, expected_action, confirmation, opts) end) do
      {:ok, {:ok, %OperatorCommandService.ApplyResult{} = result}} ->
        {:ok, result}

      {:ok, {:error, %{code: code, message: message}}} when is_atom(code) ->
        {:error, %OperatorCommandService.Error{code: code, message: message}}

      _other ->
        {:error, "confirm_action_failed"}
    end
  end

  defp default_confirm_action(target_id, plan_id, expected_action, true, opts, deps) do
    confirm_fn = Map.get(deps, :confirm, &OperatorCommandService.confirm/4)

    with {:ok, registry_path} <- resolve_registry_path(opts),
         plan_dir <- plan_dir(opts, registry_path),
         {:ok, envelope} <- PlanStore.read(plan_dir, plan_id),
         true <- envelope["action"] == Atom.to_string(expected_action),
         true <- envelope["target_id"] == target_id,
         true <- envelope["registry_path"] == registry_path,
         {:ok, result} <- confirm_fn.(target_id, plan_id, true, opts) do
      {:ok, result}
    else
      false ->
        {:error,
         %OperatorCommandService.Error{
           code: :plan_mismatch,
           message: "plan envelope does not match command",
           path: "$.plan"
         }}

      {:error, %OperatorCommandService.Error{}} = error ->
        error

      {:error, %SymphonyElixir.TargetRegistry.Error{code: code, message: message}} ->
        {:error, %OperatorCommandService.Error{code: code, message: message}}

      {:error, _reason} ->
        {:error, "confirm_action_failed"}
    end
  end

  defp resolve_registry_path(opts) do
    case Keyword.fetch(opts, :registry_path) do
      {:ok, path} ->
        if valid_path?(path), do: {:ok, Path.expand(path)}, else: {:error, :invalid_registry_path}

      :error ->
        {:ok, SymphonyElixir.LocalConfig.target_registry_path()}
    end
  end

  defp plan_dir(opts, registry_path) do
    if Keyword.has_key?(opts, :registry_path) do
      Path.join(Path.dirname(registry_path), "target-plans")
    else
      SymphonyElixir.LocalConfig.target_plan_dir()
    end
  end

  defp valid_path?(path) when is_binary(path) do
    path != "" and String.valid?(path) and String.trim(path) == path
  end

  defp valid_target_id?(value) when is_binary(value) do
    String.valid?(value) and Regex.match?(@target_id_regex, value)
  end

  defp valid_singleton_counts?(opts, singletons) do
    Enum.all?(singletons, fn key -> length(Keyword.get_values(opts, key)) <= 1 end)
  end

  defp prevalidate_argv(args, singletons) do
    flag_strings = Enum.map(singletons, &("--" <> Atom.to_string(&1)))

    repeated? =
      args
      |> Enum.filter(&(&1 in flag_strings))
      |> Enum.frequencies()
      |> Enum.any?(fn {_flag, count} -> count > 1 end)

    negated? =
      Enum.any?(args, fn arg ->
        Enum.any?(singletons, fn s -> arg == "--no-" <> Atom.to_string(s) end)
      end)

    assigned? =
      Enum.any?(args, fn arg ->
        Enum.any?(singletons, fn s -> String.starts_with?(arg, "--" <> Atom.to_string(s) <> "=") end)
      end)

    if repeated? or negated? or assigned?, do: :error, else: :ok
  end

  defp validate_plan_id(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@plan_id_regex, value),
      do: :ok,
      else: {:error, "invalid plan ID"}
  end

  defp json_selected?(args) do
    Enum.count(args, &(&1 == "--json")) == 1
  end

  defp json_error_envelope(code, message, usage, deps) do
    encoder = Map.get(deps, :json_encode, &Jason.encode/1)
    envelope = %{code: code}
    envelope = if is_binary(message) and message != "", do: Map.put(envelope, :message, message), else: envelope

    envelope =
      for usage when is_binary(usage) and usage != "" <- [usage], reduce: envelope do
        envelope -> Map.put(envelope, :usage, usage)
      end

    case safe_invoke(fn -> encoder.(envelope) end) do
      {:ok, {:ok, json}} when is_binary(json) ->
        if json_valid?(json), do: {:error, json}, else: {:error, hardcoded_json_fallback()}

      _other ->
        {:error, hardcoded_json_fallback()}
    end
  end

  defp hardcoded_json_fallback do
    ~s|{"code":"json_encoding_failed","message":"JSON encoding failed"}|
  end

  defp format_host_error({:error, %OperatorCommandService.Error{code: code, message: message}}, true, usage, deps) do
    safe_message = safe_error_message(message)
    json_error_envelope(Atom.to_string(code), safe_message, usage, deps)
  end

  defp format_host_error({:error, reason}, true, usage, deps) when is_binary(reason) do
    {code, message} = normalize_error_reason(reason)
    json_error_envelope(code, message, usage, deps)
  end

  defp format_host_error({:error, %OperatorCommandService.Error{code: code, message: message}}, false, _usage, _deps) do
    safe_message = safe_error_message(message)
    {:error, "#{code}: #{safe_message}"}
  end

  defp format_host_error({:error, reason}, false, _usage, _deps) when is_binary(reason) do
    {:error, reason}
  end

  defp safe_error_message(message) when is_binary(message) do
    redacted = Preview.redact(message)

    if String.valid?(redacted) and redacted != "" do
      redacted
    else
      "error message redacted"
    end
  end

  defp safe_error_message(_message) do
    "error message redacted"
  end

  defp normalize_error_reason(reason) when is_binary(reason) do
    known = %{
      "invalid_arguments" => {"invalid_arguments", "Invalid arguments"},
      "invalid plan ID" => {"invalid plan ID", "Invalid plan ID"},
      "plan_validation_failed" => {"plan_validation_failed", "Plan validation failed"},
      "apply_result_validation_failed" => {"apply_result_validation_failed", "Apply result validation failed"},
      "file_read_failed" => {"file_read_failed", "File read failed"},
      "yaml_decode_failed" => {"yaml_decode_failed", "YAML decode failed"},
      "plan_dependency_failed" => {"plan_dependency_failed", "Plan dependency failed"},
      "confirm_action_failed" => {"confirm_action_failed", "Confirm action failed"},
      "invalid_target_input" => {"invalid_target_input", "Invalid target input"},
      "json_encoding_failed" => {"json_encoding_failed", "JSON encoding failed"},
      "host_dependency_error" => {"host_dependency_error", "Host dependency error"}
    }

    Map.get(known, reason, {"internal_error", "An internal error occurred"})
  end

  defp render_plan_output(plan, true, deps) do
    redacted = redact_plan(plan)
    safe_json_encode(redacted, deps)
  end

  defp render_plan_output(plan, false, _deps) do
    redacted = redact_plan(plan)
    {:ok, plan_text(redacted)}
  end

  defp render_apply_output(result, true, deps) do
    redacted = redact_apply_result(result)
    safe_json_encode(redacted, deps)
  end

  defp render_apply_output(result, false, _deps) do
    redacted = redact_apply_result(result)
    {:ok, apply_text(redacted)}
  end

  defp safe_json_encode(value, deps) do
    encoder = Map.get(deps, :json_encode, &Jason.encode/1)

    case safe_invoke(fn -> encoder.(value) end) do
      {:ok, {:ok, json}} when is_binary(json) ->
        if json_valid?(json), do: {:ok, json}, else: {:error, hardcoded_json_fallback()}

      _other ->
        {:error, hardcoded_json_fallback()}
    end
  end

  defp json_valid?(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp safe_invoke(fun) do
    {:ok, fun.()}
  rescue
    _exception -> {:error, :dependency_exception}
  catch
    _kind, _reason -> {:error, :dependency_exception}
  end

  defp plan_text(plan) when is_map(plan) do
    action = plan["action"]

    preview_body =
      if is_map(plan["preview"]) and map_size(plan["preview"]) > 0 do
        format_preview_deterministic(plan["preview"])
      else
        ""
      end

    sections = [
      "Plan #{action} for #{plan["target_id"]}",
      "  operation: #{action}",
      "  target: #{plan["target_id"]}",
      "  plan ID: #{plan["id"] || "(not applicable)"}",
      "  applicable: #{plan["applicable?"]}",
      "  expected generation: #{plan["expected_generation"]}",
      "  proposed generation: #{plan["proposed_generation"]}",
      "  registry path: #{plan["registry_path"]}",
      "  created at: #{plan["created_at"]}",
      if(preview_body != "", do: "  preview:\n#{preview_body}", else: nil),
      "  Note: Phase 1 has no polling, queues, active host runs, or host side effects."
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_preview_deterministic(value, indent \\ 1)

  defp format_preview_deterministic(value, indent) when is_map(value) do
    padding = String.duplicate("  ", indent)

    value
    |> Map.to_list()
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join("\n", fn {k, v} ->
      formatted_v = format_preview_deterministic(v, indent + 1)

      if String.contains?(formatted_v, "\n") do
        "#{padding}#{k}:\n#{formatted_v}"
      else
        "#{padding}#{k}: #{formatted_v}"
      end
    end)
  end

  defp format_preview_deterministic(value, indent) when is_list(value) do
    padding = String.duplicate("  ", indent)

    value
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {v, i} ->
      formatted_v = format_preview_deterministic(v, indent + 1)

      if String.contains?(formatted_v, "\n") do
        "#{padding}[#{i}]:\n#{formatted_v}"
      else
        "#{padding}[#{i}]: #{formatted_v}"
      end
    end)
  end

  defp format_preview_deterministic(nil, _indent), do: "null"
  defp format_preview_deterministic(true, _indent), do: "true"
  defp format_preview_deterministic(false, _indent), do: "false"
  defp format_preview_deterministic(value, _indent) when is_integer(value), do: Integer.to_string(value)

  defp format_preview_deterministic(value, _indent) when is_float(value) do
    encode_preview_scalar(value)
  end

  defp format_preview_deterministic(value, _indent) when is_binary(value) do
    encode_preview_scalar(value)
  end

  defp apply_text(result) when is_map(result) do
    action = result["action"]

    [
      "Apply #{action} for #{result["target_id"]}",
      "  plan ID: #{result["plan_id"]}",
      "  registry path: #{result["registry_path"]}",
      "  action: #{action}",
      "  target: #{result["target_id"]}",
      "  committed: #{result["committed?"]}",
      "  plan consumed: #{result["plan_consumed?"]}",
      "  old generation: #{result["old_generation"]}",
      "  new generation: #{result["new_generation"]}"
    ]
    |> Enum.join("\n")
  end

  defp host_usage, do: @host_usage |> String.trim()
  defp add_usage, do: @add_usage |> String.trim()
  defp import_usage, do: @import_usage |> String.trim()
  defp plan_usage, do: @plan_usage |> String.trim()
  defp patch_usage, do: @patch_usage |> String.trim()
  defp lifecycle_usage(:activate), do: @activate_usage |> String.trim()
  defp lifecycle_usage(:pause), do: @pause_usage |> String.trim()
  defp lifecycle_usage(:drain), do: @drain_usage |> String.trim()
  defp lifecycle_usage(:retire), do: @retire_usage |> String.trim()
end
