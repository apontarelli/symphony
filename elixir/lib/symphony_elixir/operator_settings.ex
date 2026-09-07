defmodule SymphonyElixir.OperatorSettings do
  @moduledoc """
  Authoritative, credential-safe settings field metadata and retained errors.

  Every field a client may edit is described by host-owned metadata: scope,
  type and cardinality, current, inherited, and effective values with their
  source, the catalog revision the choices came from, choice availability,
  editability, and a disabled reason. Catalog entries alone are not writable
  contracts; `OperatorSettingsApply` is the only writer of these fields.

  A request with `scope: "host"` describes the shared repository policy
  layers (`host.repository_defaults.*` and
  `host.repository_profiles.<name>.*`). Target requests leave `target_id`
  opaque, so a target literally named `host` is an ordinary target.
  """

  alias SymphonyElixir.{Config, HostScheduler, OperatorRepositoryChoices, RunSetup, TargetRouting}
  alias SymphonyElixir.TargetRegistry.{Composition, FileStore, RepositoryPolicy, Schema, Yaml}
  alias SymphonyElixir.Workflow.ModuleRegistry

  @read_only_fields ~w(
    mode
    quality_gate.runtime_isolation
  )

  @wildcard_fields ~w(
    runners.*.kind
    runners.*.thinking
    runners.*.permissions.*
    runners.*.hostname
    host.tracker_connections.*.kind
    runners.settings.*.reasoning_effort
  )

  @open_choice_fields ~w(
    host.tracker_connections.*.kind
    runners.settings.*.reasoning_effort
  )

  # Open-value target fields the Apply writer accepts, with their value types.
  @open_target_fields %{
    "display_name" => "string",
    "repo.path" => "path",
    "repo.branch" => "ref",
    "worktree.root" => "path",
    "scheduling.weight" => "positive_integer",
    "concurrency.max_concurrent_agents" => "positive_integer",
    "concurrency.max_concurrent_startups" => "positive_integer",
    "concurrency.max_concurrent_reviewers" => "positive_integer",
    "budgets.per_run.max_total_tokens" => "positive_integer",
    "budgets.daily.max_total_tokens" => "positive_integer",
    "budgets.weekly.max_total_tokens" => "positive_integer"
  }

  @linear_open_types %{
    "linear.scope.query_file" => "path",
    "linear.scope.issue_ids" => "identifier_list"
  }

  # Catalog fields whose choices come from another host-owned provider; they
  # are editable target fields even though they carry no local enum.
  @target_provider_fields ~w(
    repository_profile
    linear.connection
    linear.scope.project_id
    linear.scope.project_slug
    linear.scope.team_key
    runners.allowed
    runners.default
    linear.active_states
    linear.terminal_states
    linear.required_labels
  )

  @runner_open_setting_types %{"model" => "string", "max_turns" => "positive_integer"}

  @runner_setting_names Map.keys(@runner_open_setting_types) ++ ["reasoning_effort"]

  # The repository policy vocabulary every settings writer accepts, as leaf
  # paths relative to a policy layer, with their host-owned value types.
  # Enum-typed fields reuse schema choices; workflow preset and module fields
  # reuse the module registry, the authority runtime composition checks; there
  # is no client-private enum.
  @policy_field_types %{
    "project.app_kind" => "string",
    "project.criticality" => "choice",
    "project.deployment_coupling" => "choice",
    "project.kind" => "string",
    "project.name" => "string",
    "project.repository" => "string",
    "project.slug" => "string",
    "docs.entrypoints" => "string_list",
    "vcs.default_branch" => "ref",
    "vcs.mode" => "string",
    "vcs.posture" => "string",
    "delivery.pr_target" => "ref",
    "validation.required_files" => "string_list",
    "validation.commands" => "command_list",
    "automation.completion_requirements" => "string_list",
    "automation.posture" => "string",
    "automation.profile" => "string",
    "automation.review" => "string_map",
    "review_routing" => "string_map",
    "workflow.preset" => "preset",
    "workflow.modules" => "modules",
    "auto_land.posture" => "choice",
    "auto_land.blocked_state" => "string",
    "auto_land.dry_run" => "boolean",
    "auto_land.required_checks" => "string_list",
    "auto_land.force_human_review_labels" => "string_list",
    "auto_land.force_human_review_paths" => "string_list",
    "harness.codex_home" => "path",
    "issue_markers.labels" => "string_list",
    "issue_markers.allowed_projects" => "string_list",
    "capabilities.required" => "string_list"
  }

  @doc """
  Builds the complete editable-field catalog for one target (or a new target
  draft) plus the host-owned routing preview for the resulting selection.

  A request with `scope: "host"` builds the shared repository policy layer
  catalog instead: `host.repository_defaults.*` and
  `host.repository_profiles.<name>.*`. Otherwise `target_id` is an opaque
  target ID, including the literal ID `host`.
  """
  @spec build(GenServer.server(), map(), keyword()) :: map()
  def build(scheduler, request, opts) do
    {registry, generation, source_reason} = registry(scheduler)

    if request["scope"] == "host" do
      host_catalog(registry, generation, source_reason, request)
    else
      target_catalog(registry, generation, source_reason, request, opts)
    end
  end

  @doc """
  Nests flat field selections into the configured document shape the registry
  stores. Only explicitly selected fields are placed, and `nil` leaves are
  preserved so merge-patch deletion reaches the registry writer.
  """
  @spec selection_document(map()) :: map()
  def selection_document(selections) when is_map(selections) do
    Enum.reduce(selections, %{}, fn {path, value}, document ->
      put_path(document, String.split(path, "."), value)
    end)
  end

  def selection_document(_selections), do: %{}

  @doc """
  The draft configured document after applying selections, used for routing
  previews that must reflect a proposal instead of stored configuration.
  Selections apply as merge-patch: `nil` deletes the stored leaf.
  """
  @spec draft_configured(map(), map()) :: map()
  def draft_configured(configured, selections) when is_map(configured) and is_map(selections),
    do: merge_patch(configured, selection_document(selections))

  def draft_configured(configured, _selections), do: configured || %{}

  @doc """
  The host repository policy layer changes implied by host-scope selections,
  in the shape the HostPatch command accepts.
  """
  @spec host_changes(map()) :: map()
  def host_changes(selections) when is_map(selections),
    do: selection_document(selections) |> Map.get("host", %{})

  def host_changes(_selections), do: %{}

  @doc """
  The shared repository policy layers after applying host-scope selections
  with merge-patch semantics (`nil` deletes a leaf).
  """
  @spec draft_host_layers(map(), map()) :: map()
  def draft_host_layers(host, selections) when is_map(host) do
    host
    |> Map.take(["repository_defaults", "repository_profiles"])
    |> merge_patch(host_changes(selections))
  end

  def draft_host_layers(_host, _selections), do: %{}

  @doc false
  @spec policy_fields() :: %{String.t() => String.t()}
  def policy_fields, do: @policy_field_types

  # ------------------------------------------------------------------
  # Target catalog
  # ------------------------------------------------------------------

  defp target_catalog(registry, generation, source_reason, request, opts) do
    target_id = request["target_id"]
    target = if registry, do: Map.get(registry.targets, target_id)
    configured = target_configured(registry, target)
    selections = request["selections"] || %{}
    repo = selected_repository(request, configured)
    creation? = is_nil(target)
    linear = SymphonyElixir.OperatorLinearChoices.build(registry, configured, request, opts)
    host = Map.fetch!(configured, "host")

    policies =
      configured
      |> configured_without_host()
      |> policy_projections(host, selections)

    definitions =
      choice_definitions()
      |> Map.merge(runner_setting_definitions(configured, selections, host))
      |> Map.merge(open_definitions())
      |> Map.merge(policy_field_definitions("repository_policy."))
      |> Map.merge(host_choices(registry, source_reason))
      |> Map.merge(
        OperatorRepositoryChoices.build(
          repo,
          opts
          |> Keyword.put(:host, host)
          |> Keyword.put(:configured, configured)
          |> Keyword.put(:selections, selections)
        )
      )
      |> Map.merge(linear.fields)
      |> Map.merge(read_only_definitions())
      |> Map.new(fn {path, field} ->
        {path, classify(path, field, false, creation?, revision(generation, linear))}
      end)

    fields =
      Map.new(definitions, fn {path, field} ->
        selected = Map.get(selections, path, configured_value(configured, path))
        {path, field |> put_provenance(path, selected, selections, configured, host, policies) |> select(selected)}
      end)

    allowed = fields["runners.allowed"].selected
    fields = Map.update!(fields, "runners.default", &constrain_default(&1, allowed))
    fields = require_linear_scope(fields)

    errors = selection_errors(fields, selections)
    reason = source_reason || target_reason(target_id, target)

    %{
      registry_generation: generation,
      status: if(reason, do: "unavailable", else: "current"),
      reason: reason,
      fields: fields,
      linear: Map.drop(linear, [:fields]),
      revisions: %{"registry" => generation, "linear" => linear_revision(linear)},
      routing: routing_preview(registry, target_id, configured, selections, reason, policies.effective),
      apply_blocked: not is_nil(reason) or errors != [],
      errors: errors
    }
  end

  defp choice_definitions do
    Schema.settings_choices()
    |> Map.merge(RunSetup.settings_choices())
    |> Map.reject(fn {path, _definition} -> path in @wildcard_fields end)
    |> Map.new(fn {path, definition} -> {path, choice_field(definition)} end)
  end

  defp policy_field_definitions(prefix) do
    Map.new(@policy_field_types, fn {rel, type} ->
      {prefix <> rel, policy_field(rel, type)}
    end)
  end

  # Finite workflow vocabulary comes from the module registry, the same
  # authority runtime composition resolves presets and modules against, so
  # catalogs never carry a second enum and unknown or removed values surface as
  # invalid retained selections instead of free text.
  defp policy_field(_rel, "preset"),
    do: registry_choice_field("scalar", ModuleRegistry.preset_names())

  defp policy_field(_rel, "modules"),
    do: registry_choice_field("list", ModuleRegistry.module_names())

  defp policy_field(rel, "choice"),
    do: choice_field(Map.fetch!(Config.Schema.settings_choices(), rel))

  defp policy_field(_rel, type),
    do: %{cardinality: policy_cardinality(type), type: type, choices: [], status: "current", reason: nil}

  defp registry_choice_field(cardinality, values) do
    %{
      cardinality: cardinality,
      type: "choice",
      choices: Enum.map(values, &choice/1),
      status: "current",
      reason: nil
    }
  end

  defp choice_field(definition) do
    %{
      cardinality: definition.cardinality,
      type: "choice",
      choices: Enum.map(definition.values, &choice/1),
      status: "current",
      reason: nil
    }
  end

  defp read_only_definitions do
    @wildcard_fields
    |> Enum.sort()
    |> Map.new(fn path ->
      {path,
       %{
         cardinality: "scalar",
         type: if(path in @open_choice_fields, do: "open", else: "choice"),
         choices: [],
         status: "current",
         reason: nil
       }}
    end)
  end

  defp open_definitions do
    Map.new(@open_target_fields, fn {path, type} ->
      {path, %{cardinality: "scalar", type: type, choices: [], status: "current", reason: nil}}
    end)
  end

  # Runner tuning is addressed per concrete host runner, never through a
  # wildcard, so a selection can only name a runner the host actually defines.
  defp runner_setting_definitions(configured, selections, host) do
    configured_runners =
      configured
      |> Kernel.||(%{})
      |> get_in(["runners", "settings"])
      |> map_keys()

    draft_runners =
      selections
      |> Enum.flat_map(fn {path, _value} ->
        case String.split(path, ".") do
          ["runners", "settings", runner, _setting] -> [runner]
          _other -> []
        end
      end)
      |> MapSet.new()

    # Concrete runner IDs come from the host catalog itself, so tuning is
    # discoverable for a runner that exists on the host but is not yet
    # configured on any target.
    runners =
      [map_keys(host["runners"]), configured_runners, MapSet.to_list(draft_runners)]
      |> Enum.concat()
      |> Enum.uniq()
      |> Enum.sort()

    reasoning = Map.fetch!(Schema.settings_choices(), "runners.settings.*.reasoning_effort")

    Enum.flat_map(runners, fn runner ->
      reasoning_field = %{
        cardinality: "scalar",
        type: "choice",
        choices: Enum.map(reasoning.values, &choice/1),
        status: "current",
        reason: nil
      }

      open_fields =
        Enum.map(@runner_open_setting_types, fn {setting, type} ->
          {"runners.settings.#{runner}.#{setting}", %{cardinality: "scalar", type: type, choices: [], status: "current", reason: nil}}
        end)

      [{"runners.settings.#{runner}.reasoning_effort", reasoning_field} | open_fields]
    end)
    |> Map.new()
  end

  defp selected_repository(request, configured) do
    repo = request["repository"] || get_in(request, ["selections", "repo.path"]) || configured_value(configured, "repo.path")
    if is_binary(repo) and repo != "", do: repo
  end

  defp classify(path, field, host_scope?, _creation?, revision) do
    {scope, editable, disabled_reason} =
      cond do
        host_scope? ->
          {"host", true, nil}

        path in ["state", "dispatch_mode"] ->
          {"target", false, "lifecycle_command_required"}

        path in @wildcard_fields ->
          {"reference", false, "wildcard_reference"}

        String.starts_with?(path, "host.") ->
          {"host", false, "host_field_read_only"}

        path in @read_only_fields ->
          {"reference", false, "run_setup_field"}

        writable_target_field?(path) ->
          {"target", true, nil}

        # Anything else the merged catalogs describe is not a writable
        # registry path; it stays visible but never editable.
        true ->
          {"reference", false, "unsupported_field"}
      end

    field
    |> ensure_type(path)
    |> Map.merge(%{
      scope: scope,
      editable: editable,
      disabled_reason: disabled_reason,
      revision: revision
    })
  end

  defp writable_target_field?(path) do
    Map.has_key?(@open_target_fields, path) or
      Map.has_key?(@linear_open_types, path) or
      path in @target_provider_fields or path in target_choice_fields() or
      runner_setting_path?(path) or target_policy_field?(path)
  end

  defp target_choice_fields do
    Schema.settings_choices()
    |> Map.keys()
    |> Kernel.--(@wildcard_fields ++ ["state", "dispatch_mode"])
  end

  defp runner_setting_path?(path) do
    case String.split(path, ".") do
      ["runners", "settings", _runner, setting] -> setting in @runner_setting_names
      _other -> false
    end
  end

  defp target_policy_field?("repository_policy." <> rel), do: Map.has_key?(@policy_field_types, rel)
  defp target_policy_field?(_path), do: false

  # Linear and repository fields arrive without a type; finite fields carry
  # authoritative choices and open fields carry an explicit value type.
  defp ensure_type(field, path) do
    type =
      Map.get(field, :type) || Map.get(@linear_open_types, path) ||
        if Map.has_key?(field, :choices), do: "choice", else: "open"

    Map.put(field, :type, type)
  end

  defp revision(nil, _linear), do: nil

  defp revision(generation, linear) do
    revision = linear_revision(linear)

    if revision,
      do: %{"registry" => generation, "linear" => revision},
      else: %{"registry" => generation}
  end

  defp linear_revision(%{connection_revision: revision}) when is_binary(revision), do: revision
  defp linear_revision(_linear), do: nil

  # Every field carries where its value comes from: the stored override (or
  # host layer), the composed effective value the runtime resolves, and what a
  # cleared override would inherit from the shared layers. Concrete runner
  # tuning composes through the registry's runner overlay, so the catalog
  # reports the merged value new runs will use instead of the bare override.
  defp put_provenance(
         field,
         "repository_policy." <> rel = path,
         _selected,
         selections,
         _configured,
         host,
         policies
       ) do
    field
    |> Map.put(:current, policy_leaf(Map.get(policies.stored, "repository_policy"), rel))
    |> Map.put(:inherited, policy_leaf(policies.inherited, rel))
    |> Map.put(:effective, policy_leaf(policies.effective, rel))
    |> Map.put(:source, policy_leaf_source(host, policies.draft, rel, selections, path))
  end

  defp put_provenance(field, path, selected, selections, configured, host, policies) do
    case split_runner_setting(path) do
      {runner, setting} ->
        put_runner_provenance(field, path, runner, setting, selections, configured, host, policies)

      :not_runner_setting ->
        current = configured_value(configured, path)

        source =
          cond do
            Map.has_key?(selections, path) -> "selection"
            not is_nil(current) -> "target"
            true -> nil
          end

        Map.merge(field, %{current: current, inherited: nil, effective: selected, source: source})
    end
  end

  defp split_runner_setting(path) do
    case String.split(path, ".") do
      ["runners", "settings", runner, setting] when setting in @runner_setting_names ->
        {runner, setting}

      _other ->
        :not_runner_setting
    end
  end

  # `current` is the stored target override; `inherited` is the host runner's
  # own tuning; `effective` is what registry composition resolves for the
  # draft settings, so clearing an override previews and reads back the host
  # value. A runner the host no longer defines cannot compose, so its
  # effective value is honestly nil.
  defp put_runner_provenance(field, path, runner, setting, selections, configured, host, policies) do
    host_runner = get_in(host, ["runners", runner])
    draft_settings = get_in(policies.draft, ["runners", "settings", runner]) || %{}

    effective =
      case Composition.compose_runner(host_runner, draft_settings, runner) do
        {:ok, composed} -> Map.get(composed, setting)
        _uncomposable -> nil
      end

    source =
      cond do
        Map.has_key?(selections, path) -> "selection"
        policy_leaf_present?(get_in(configured, ["runners", "settings", runner]), setting) -> "target"
        policy_leaf_present?(host_runner, setting) -> "host"
        true -> nil
      end

    field
    |> Map.put(:current, configured_value(configured, path))
    |> Map.put(:inherited, if(is_map(host_runner), do: Map.get(host_runner, setting), else: nil))
    |> Map.put(:effective, effective)
    |> Map.put(:source, source)
  end

  # Repository policy leaves resolve through host defaults, the selected
  # profile, then the target override; the deepest layer naming the leaf wins.
  defp policy_leaf_source(host, configured, rel, selections, path) do
    if Map.has_key?(selections, path) do
      "selection"
    else
      profile =
        configured
        |> Map.get("repository_profile")

      profiles =
        host
        |> Map.get("repository_profiles")
        |> default_map()

      cond do
        policy_leaf_present?(Map.get(configured, "repository_policy"), rel) -> "target"
        is_binary(profile) and policy_leaf_present?(Map.get(profiles, profile), rel) -> "profile"
        policy_leaf_present?(Map.get(host, "repository_defaults"), rel) -> "host"
        true -> nil
      end
    end
  end

  defp policy_projections(stored, host, selections) do
    draft = draft_configured(stored, selections)

    %{
      stored: stored,
      draft: draft,
      effective: resolve_policy(host, draft),
      inherited: resolve_policy(host, Map.delete(draft, "repository_policy"))
    }
  end

  defp resolve_policy(host, configured) when is_map(host) and is_map(configured) do
    case RepositoryPolicy.resolve(host, configured) do
      {:ok, policy, _sources} when is_map(policy) -> policy
      _unresolved -> %{}
    end
  rescue
    _error -> %{}
  catch
    _kind, _reason -> %{}
  end

  defp resolve_policy(_host, _configured), do: %{}

  defp policy_leaf(policy, rel) when is_map(policy), do: get_in(policy, String.split(rel, "."))
  defp policy_leaf(_policy, _rel), do: nil

  defp policy_leaf_present?(policy, rel) do
    String.split(rel, ".")
    |> Enum.reduce_while({true, policy}, fn key, {true, nested} ->
      if is_map(nested) and Map.has_key?(nested, key),
        do: {:cont, {true, Map.get(nested, key)}},
        else: {:halt, {false, nil}}
    end)
    |> elem(0)
  end

  defp policy_cardinality(type) when type in ["string_list", "command_list"], do: "list"
  defp policy_cardinality("string_map"), do: "map"
  defp policy_cardinality(_scalar), do: "scalar"

  # ------------------------------------------------------------------
  # Host catalog (shared repository policy layers)
  # ------------------------------------------------------------------

  defp host_catalog(registry, generation, source_reason, request) do
    selections = request["selections"] || %{}
    host = if registry, do: registry.host || %{}, else: %{}
    revision = if is_nil(generation), do: nil, else: %{"registry" => generation}
    status = if(source_reason, do: "unavailable", else: "current")

    fields =
      host
      |> host_layer_definitions(selections, status, source_reason)
      |> Map.new(fn {path, entry} ->
        selected = Map.get(selections, path, policy_leaf(entry.layer, entry.rel))

        field =
          classify(path, entry.field, true, true, revision)
          |> put_host_provenance(path, entry, selected, selections)
          |> select(selected)

        {path, field}
      end)

    errors = selection_errors(fields, selections)

    %{
      registry_generation: generation,
      status: status,
      reason: source_reason,
      fields: fields,
      linear: nil,
      revisions: %{"registry" => generation},
      routing: nil,
      apply_blocked: not is_nil(source_reason) or errors != [],
      errors: errors
    }
  end

  # Layer names come from the host catalog plus any profile a draft selection
  # introduces, so a new profile is discoverable before it exists.
  defp host_layer_definitions(host, selections, status, reason) do
    defaults = default_map(Map.get(host, "repository_defaults"))
    profiles = default_map(Map.get(host, "repository_profiles"))

    names = (Map.keys(profiles) ++ draft_profile_names(selections)) |> Enum.uniq() |> Enum.sort()

    layer_entries({"repository_defaults", nil, defaults}, status, reason) ++
      Enum.flat_map(names, &profile_layer_entries(&1, Map.get(profiles, &1), status, reason))
  end

  defp layer_entries({name, profile_name, layer}, status, reason) do
    policy_field_definitions("host.#{name}.")
    |> Enum.map(fn {path, field} ->
      rel = String.trim_leading(path, "host.#{name}.")

      field = %{field | status: status, reason: reason}

      field =
        if profile_name != nil and not RepositoryPolicy.valid_profile_name?(profile_name),
          do: Map.put(field, :validation_reason, "invalid_profile_name"),
          else: field

      {path, %{field: field, layer: layer, rel: rel}}
    end)
  end

  defp profile_layer_entries(name, layer, status, reason),
    do: layer_entries({"repository_profiles.#{name}", name, default_map(layer)}, status, reason)

  defp put_host_provenance(field, path, entry, selected, selections) do
    source =
      cond do
        Map.has_key?(selections, path) -> "selection"
        policy_leaf_present?(entry.layer, entry.rel) -> "host"
        true -> nil
      end

    field
    |> Map.put(:current, policy_leaf(entry.layer, entry.rel))
    |> Map.put(:inherited, nil)
    |> Map.put(:effective, selected)
    |> Map.put(:source, source)
  end

  defp draft_profile_names(selections) do
    selections
    |> Enum.flat_map(fn {path, _value} ->
      case String.split(path, ".") do
        ["host", "repository_profiles", name | _rest] -> [name]
        _other -> []
      end
    end)
    |> Enum.uniq()
  end

  defp require_linear_scope(%{"linear.connection" => %{selected: connection}, "linear.scope.type" => %{selected: nil} = scope} = fields)
       when not is_nil(connection) do
    Map.put(fields, "linear.scope.type", %{scope | valid: false, reason: "selection_required"})
  end

  defp require_linear_scope(fields), do: fields

  defp target_configured(registry, target) do
    configured = if target, do: target.configured, else: %{}
    Map.put(configured, "host", if(registry, do: registry.host, else: %{}))
  end

  defp target_reason(target_id, nil) when not is_nil(target_id), do: "target_not_found"
  defp target_reason(_target_id, _target), do: nil

  defp selection_errors(fields, selections) do
    fields
    |> Enum.flat_map(fn {path, field} ->
      if field.valid, do: [], else: [%{field: path, reason: field.reason || "selection_invalid"}]
    end)
    |> Kernel.++(Enum.map(Map.keys(selections) -- Map.keys(fields), &%{field: &1, reason: "unknown_field"}))
    |> Enum.sort_by(& &1.field)
  end

  defp registry(scheduler) do
    host = HostScheduler.snapshot(scheduler)

    with %{verified?: true, path: path, generation: generation} <- host[:registry],
         {:ok, %{bytes: bytes, generation: ^generation}} <- FileStore.read(path),
         {:ok, document} <- Yaml.decode(bytes),
         {:ok, snapshot} <- Schema.validate(document, registry_path: path) do
      {snapshot, generation, if(snapshot.globally_valid?, do: nil, else: "registry_invalid")}
    else
      {:ok, %{generation: generation}} -> {nil, generation, "registry_stale"}
      _ -> {nil, get_in(host, [:registry, :generation]), "registry_unavailable"}
    end
  catch
    :exit, _ -> {nil, nil, "host_unavailable"}
  end

  defp host_choices(registry, reason) do
    host = if registry, do: registry.host || %{}, else: %{}
    runners = entries(host["runners"], "$.host.runners", registry, reason)
    connections = entries(host["tracker_connections"], "$.host.tracker_connections", registry, reason)

    %{
      "runners.allowed" => field("list", runners, reason),
      "runners.default" => field("scalar", runners, reason),
      "linear.connection" => field("scalar", connections, reason)
    }
  end

  defp entries(entries, prefix, registry, reason) when is_map(entries) do
    entries
    |> Enum.sort()
    |> Enum.map(fn {id, entry} ->
      invalid =
        Enum.any?(registry.diagnostics, fn diagnostic ->
          diagnostic.severity == :error and
            (diagnostic.path == "#{prefix}.#{id}" or String.starts_with?(diagnostic.path, "#{prefix}.#{id}."))
        end)

      kind = if invalid, do: nil, else: entry["kind"]

      choice(id)
      |> Map.put(:kind, kind)
      |> Map.put(
        :status,
        cond do
          invalid -> "invalid"
          reason -> "unavailable"
          true -> "available"
        end
      )
      |> Map.put(:reason, if(invalid, do: "configuration_invalid", else: reason))
    end)
  end

  defp entries(_, _, _, _), do: []

  defp field(cardinality, choices, reason),
    do: %{
      cardinality: cardinality,
      type: "choice",
      choices: choices,
      status: if(reason, do: "unavailable", else: "current"),
      reason: reason
    }

  defp choice(value), do: %{value: value, status: "available", reason: nil}

  defp configured_value(configured, path) do
    Enum.reduce(String.split(path, "."), configured, fn key, value ->
      if is_map(value), do: Map.get(value, key), else: nil
    end)
  end

  defp select(field, selected) do
    choices = selection_choices(field, selected)
    type_valid = valid_type?(field, selected)
    cardinality_valid = valid_cardinality?(field.cardinality, selected)

    bad = Enum.find(choices, &(&1.selected and &1.status not in ["current", "available"]))

    reason =
      cond do
        not cardinality_valid -> "invalid_cardinality"
        not type_valid -> "invalid_value"
        field[:validation_reason] -> field.validation_reason
        bad -> bad.reason
        true -> nil
      end

    field |> Map.merge(%{choices: choices, selected: selected, valid: is_nil(reason), reason: reason || field.reason})
  end

  defp selection_choices(field, selected) do
    values = if field.type == "choice", do: List.wrap(selected), else: []
    choices = Enum.map(field.choices, &select_choice(&1, values))
    known = MapSet.new(choices, & &1.value)

    missing =
      values
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.map(fn value ->
        %{
          value: value,
          selected: true,
          status: if(field.status == "unavailable", do: "unavailable", else: "stale"),
          reason: field.reason || "selection_removed"
        }
      end)

    choices ++ missing
  end

  # Open values carry explicit host-owned validation; finite fields validate
  # through their authoritative choices instead.
  defp valid_type?(%{type: type}, _selected) when type in ["choice", "open"], do: true

  defp valid_type?(%{type: "positive_integer"}, selected),
    do: is_nil(selected) or (is_integer(selected) and selected > 0)

  defp valid_type?(%{type: "string"}, selected),
    do: is_nil(selected) or nonempty_string(selected)

  defp valid_type?(%{type: "boolean"}, selected),
    do: is_nil(selected) or is_boolean(selected)

  defp valid_type?(%{type: "ref"}, selected),
    do: is_nil(selected) or (nonempty_string(selected) and SymphonyElixir.OperatorBranchCatalog.valid_target?(selected))

  defp valid_type?(%{type: "path"}, selected),
    do: is_nil(selected) or (nonempty_string(selected) and Path.type(selected) == :absolute)

  defp valid_type?(%{type: "identifier_list"}, selected) when is_list(selected),
    do: Enum.all?(selected, &nonempty_string/1)

  defp valid_type?(%{type: "identifier_list"}, nil), do: true

  defp valid_type?(%{type: "string_list"}, nil), do: true

  defp valid_type?(%{type: "string_list"}, selected) when is_list(selected),
    do: Enum.all?(selected, &nonempty_string/1)

  defp valid_type?(%{type: "command_list"}, nil), do: true

  defp valid_type?(%{type: "command_list"}, selected) when is_list(selected),
    do: Enum.all?(selected, &valid_command?/1)

  defp valid_type?(%{type: "string_map"}, selected),
    do: is_nil(selected) or valid_string_map?(selected)

  defp valid_type?(_field, _selected), do: false

  defp valid_command?(command) do
    is_map(command) and Enum.sort(Map.keys(command)) == ["command", "name"] and
      nonempty_string(Map.get(command, "name")) and nonempty_string(Map.get(command, "command"))
  end

  defp valid_string_map?(value) do
    is_map(value) and not is_struct(value) and Enum.all?(Map.keys(value), &is_binary/1) and
      match?({:ok, _encoded}, Jason.encode(value))
  end

  defp nonempty_string(value), do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp valid_cardinality?(_cardinality, nil), do: true
  defp valid_cardinality?("list", selected), do: is_list(selected)
  defp valid_cardinality?("scalar", selected), do: not is_list(selected) and not is_map(selected)
  defp valid_cardinality?("map", selected), do: is_map(selected) and not is_struct(selected)

  defp select_choice(entry, values) do
    selected? = entry.value in values
    status = if selected? and entry.status == "available", do: "current", else: entry.status
    Map.merge(entry, %{selected: selected?, status: status})
  end

  defp constrain_default(field, allowed) do
    allowed = if is_list(allowed), do: allowed, else: []

    choices =
      Enum.map(field.choices, fn entry ->
        if entry.value not in allowed and entry.status in ["available", "current"],
          do: %{entry | status: "unavailable", reason: "default_runner_not_allowed"},
          else: entry
      end)

    invalid = not is_nil(field.selected) and field.selected not in allowed

    %{
      field
      | choices: choices,
        valid: field.valid and not invalid,
        reason: if(invalid, do: "default_runner_not_allowed", else: field.reason)
    }
  end

  defp routing_preview(registry, target_id, configured, selections, source_reason, resolved_policy) do
    with nil <- source_reason,
         %{} = registry <- registry do
      draft = configured_without_host(configured) |> draft_configured(selections)

      entry =
        TargetRouting.configured_entry(
          draft_target_id(target_id),
          with_resolved_markers(draft, resolved_policy),
          existing_target_active?(registry, target_id)
        )

      routing = TargetRouting.snapshot_entries(registry) |> TargetRouting.with_draft(entry) |> TargetRouting.preview()

      Enum.find(routing, &(&1.target_id == entry.target_id))
    else
      reason when is_binary(reason) -> %{status: "unavailable", reason: reason, conflicts: []}
      _unavailable -> %{status: "unavailable", reason: "registry_unavailable", conflicts: []}
    end
  end

  # Draft routing must see the markers a target actually resolves (host
  # defaults and its profile compose before any target override); the raw
  # override alone would understate them.
  defp with_resolved_markers(draft, resolved_policy) when is_map(resolved_policy) do
    case resolved_policy["issue_markers"] do
      markers when is_map(markers) ->
        overrides = if is_map(draft["repository_policy"]), do: draft["repository_policy"], else: %{}
        Map.put(draft, "repository_policy", Map.put(overrides, "issue_markers", markers))

      _no_markers ->
        draft
    end
  end

  defp with_resolved_markers(draft, _unresolved), do: draft

  defp configured_without_host(configured), do: Map.delete(configured || %{}, "host")

  defp draft_target_id(nil), do: "draft-target"
  defp draft_target_id(target_id) when is_binary(target_id), do: target_id

  defp existing_target_active?(registry, target_id) when is_binary(target_id) do
    case Map.get(registry.targets, target_id) do
      %SymphonyElixir.TargetRegistry.Target{configured_state: :active} -> true
      _missing_or_inactive -> false
    end
  end

  defp existing_target_active?(_registry, _target_id), do: false

  # A nil selection clears the leaf; put_path preserves the nil so registry
  # merge-patch writers delete the stored key instead of dropping the request.
  defp put_path(document, [key], value) when is_map(document), do: Map.put(document, key, value)

  defp put_path(document, [key | rest], value) when is_map(document) do
    nested = Map.get(document, key)
    Map.put(document, key, put_path(if(is_map(nested), do: nested, else: %{}), rest, value))
  end

  defp put_path(document, [], _value), do: document

  defp merge_patch(current, patch) when is_map(patch) do
    Enum.reduce(patch, current, fn {key, value}, merged ->
      cond do
        is_nil(value) -> Map.delete(merged, key)
        is_map(value) -> Map.put(merged, key, merge_patch(map_or_empty(Map.get(merged, key)), value))
        true -> Map.put(merged, key, value)
      end
    end)
  end

  defp merge_patch(current, _patch), do: current

  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_other), do: %{}

  defp default_map(map) when is_map(map), do: map
  defp default_map(_other), do: %{}

  defp map_keys(value) when is_map(value), do: Map.keys(value)
  defp map_keys(_value), do: []
end
