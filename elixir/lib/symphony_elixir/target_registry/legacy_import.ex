defmodule SymphonyElixir.TargetRegistry.LegacyImport do
  @moduledoc """
  Explicit cutover of legacy Symphony configuration into the host registry.

  Migrates a legacy local `config.yml` (host-wide tracker connection, runner
  catalog, polling, and capacity ceilings) and a legacy target registry whose
  targets still reference repository manifests through `repo.manifest` into
  the current host-owned registry document. The migration is pure: every
  source is decoded by the caller, the proposal is validated and composed,
  each mapped field is dispositioned, and `PolicyParity` proves that no
  restriction weakens. Targets always migrate paused without a dispatch
  mode; activation stays a separate command. Registry targets are never
  silently overwritten: identical re-imports are explicit no-ops and any
  difference is a blocking conflict.
  """

  alias SymphonyElixir.LocalConfig
  alias SymphonyElixir.TargetRegistry.Composition
  alias SymphonyElixir.TargetRegistry.Diagnostic
  alias SymphonyElixir.TargetRegistry.PolicyParity
  alias SymphonyElixir.TargetRegistry.Preview
  alias SymphonyElixir.TargetRegistry.Schema
  alias SymphonyElixir.TargetRegistry.Validation
  alias SymphonyElixir.TargetRegistry.Yaml

  @default_active_states ["Todo", "In Progress", "Merging", "Rework"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @secret_reference_regex ~r/^\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})$/
  @host_entry_containers ~w(tracker_connections runners)
  @host_field_sections ~w(polling capacity scheduling)
  @host_policy_sections ~w(repository_defaults repository_profiles capabilities)
  @supported_host_sections @host_field_sections ++ @host_policy_sections
  @supported_host_keys @host_entry_containers ++ @supported_host_sections
  @legacy_host_identity_keys ~w(id state_root)
  @tracker_section_keys ~w(kind endpoint api_key active_states terminal_states required_labels)
  @polling_section_keys ~w(interval_ms)
  @deployment_section_keys ~w(ceilings)
  @ceiling_keys ~w(max_concurrent_agents max_concurrent_startups)
  @informational_local_config_keys ~w(version)
  @mappable_local_config_keys ~w(tracker runners polling deployment capacity_ceiling)
  @default_runner_limits %{"max_concurrent_agents" => 1, "max_concurrent_startups" => 1}
  @runner_limit_fields ~w(max_concurrent_agents max_concurrent_startups)
  @unmappable_tracker_policy_keys ~w(active_states terminal_states required_labels)

  defmodule Result do
    @moduledoc false

    defstruct [
      :sources,
      :proposal,
      :proposed_bytes,
      :snapshot,
      :registry_preview,
      :applicable?,
      :import_diagnostics,
      :field_dispositions,
      :source_differences,
      :parity
    ]

    @type source :: %{
            required(:kind) => String.t(),
            required(:path) => String.t() | nil,
            required(:checksum) => String.t() | nil
          }

    @type disposition :: %{
            required(:source_path) => String.t(),
            required(:destination_path) => String.t() | nil,
            required(:action) => atom()
          }

    @type difference :: %{
            required(:source_path) => String.t(),
            required(:destination_path) => String.t() | nil,
            required(:classification) => String.t(),
            required(:reason) => String.t()
          }

    @type parity :: %{
            required(:target_id) => String.t(),
            required(:verdict) => :preserved | :weakened,
            required(:findings) => [Diagnostic.t()]
          }

    @type t :: %__MODULE__{
            sources: [source()],
            proposal: map(),
            proposed_bytes: binary(),
            snapshot: SymphonyElixir.TargetRegistry.Snapshot.t(),
            registry_preview: Preview.t(),
            applicable?: boolean(),
            import_diagnostics: [Diagnostic.t()],
            field_dispositions: [disposition()],
            source_differences: [difference()],
            parity: [parity()]
          }
  end

  @doc """
  Returns every repository manifest a cutover must read.

  A target needs a manifest read when the legacy registry (or the current
  registry during an in-place migration) still references one through an
  explicit `repo.manifest`. Profile-only host targets are never reread, and
  malformed target entries (scalars, lists, nulls) bind nothing; `preview/1`
  rejects those with typed target-scoped diagnostics.
  """
  @spec manifest_bindings(map() | nil, map() | nil) :: [
          %{
            required(:target_id) => String.t(),
            required(:repo_path) => String.t(),
            required(:manifest_path) => String.t()
          }
        ]
  def manifest_bindings(current_document, legacy_document) do
    legacy_targets = targets_of(legacy_document)
    current_targets = targets_of(current_document)

    Map.merge(legacy_targets, current_targets, fn _id, legacy, current ->
      if manifest_target?(current), do: current, else: legacy
    end)
    |> Enum.filter(fn {_id, target} -> manifest_target?(target) end)
    |> Enum.map(fn {id, target} ->
      repo = map(target["repo"])
      repo_path = Path.expand(repo["path"])

      %{
        target_id: id,
        repo_path: repo_path,
        manifest_path: Path.expand(Path.join(repo_path, repo["manifest"]))
      }
    end)
    |> Enum.sort_by(& &1.target_id)
  end

  @doc """
  Builds the cutover proposal from decoded legacy sources.

  All inputs are pre-decoded maps; this function never reads files, so the
  command service can bind exact source bytes around it. Inputs:

  * `:current_document` - decoded registry being migrated into
  * `:current_bytes` - raw bytes of that registry (for its generation)
  * `:local_config` - `%{path:, document:}` decoded legacy `config.yml`
  * `:legacy_registry` - `%{path:, document:}` decoded legacy `targets.yml`
  * `:manifests` - `%{manifest_path => %{raw:, compiled:}}`
  * `:connection_id`, `:registry_path`, `:home`
  """
  @spec preview(keyword()) :: {:ok, Result.t()} | {:error, term()}
  def preview(input) when is_list(input) do
    current_document = Keyword.fetch!(input, :current_document)
    current_bytes = Keyword.fetch!(input, :current_bytes)
    current_host = map(current_document["host"])
    current_targets = targets_of(current_document)

    if current_host == %{} do
      {:error, :current_registry_missing_host}
    else
      local_config = normalize_source(Keyword.get(input, :local_config))
      legacy_registry = normalize_source(Keyword.get(input, :legacy_registry))
      manifests = Keyword.get(input, :manifests, %{})
      connection_id = Keyword.get(input, :connection_id, "linear")
      registry_path = Keyword.fetch!(input, :registry_path)
      home = Keyword.get(input, :home)

      {local_fragment, local_dispositions, local_differences, local_diagnostics} =
        map_local_config(local_config, connection_id)

      legacy_document = if legacy_registry, do: map(legacy_registry.document), else: %{}
      legacy_host = map(legacy_document["host"])
      legacy_targets = targets_of(legacy_document)

      {legacy_fragment, legacy_dispositions, legacy_diagnostics} =
        map_legacy_host(legacy_host)

      source_conflicts =
        source_conflicts(local_fragment, legacy_fragment, local_config, legacy_registry)

      {host, host_dispositions, host_conflicts} =
        apply_fragments(current_host, local_fragment, legacy_fragment)

      malformed_target_diagnostics =
        malformed_target_diagnostics(current_targets) ++ malformed_target_diagnostics(legacy_targets)

      {targets, target_dispositions, target_diagnostics, parity} =
        migrate_targets(current_targets, legacy_targets, manifests)

      proposal = %{"version" => 1, "host" => host, "targets" => targets}
      proposed_bytes = Yaml.encode(proposal)

      diagnostics =
        (malformed_target_diagnostics ++
           local_diagnostics ++
           legacy_diagnostics ++
           source_conflicts ++
           host_conflicts ++
           target_diagnostics)
        |> Enum.uniq()
        |> Enum.sort_by(&{&1.path, &1.code, &1.message})

      dispositions =
        Enum.sort_by(
          local_dispositions ++ legacy_dispositions ++ host_dispositions ++ target_dispositions,
          & &1.source_path
        )

      differences = Enum.sort_by(local_differences, & &1.source_path)

      finish_proposal(
        %Result{
          proposal: proposal,
          proposed_bytes: proposed_bytes,
          import_diagnostics: diagnostics,
          field_dispositions: dispositions,
          source_differences: differences,
          parity: parity,
          sources: sources(local_config, legacy_registry, manifests)
        },
        current_document,
        current_bytes,
        registry_path,
        home
      )
    end
  end

  defp targets_of(document) when is_map(document) do
    case document["targets"] do
      targets when is_map(targets) and not is_struct(targets) -> targets
      _missing_or_invalid -> %{}
    end
  end

  defp targets_of(_document), do: %{}

  defp normalize_source(nil), do: nil

  defp normalize_source(source) do
    %{
      path: Map.get(source, :path) || Map.get(source, "path"),
      document: Map.get(source, :document) || Map.get(source, "document")
    }
  end

  defp map(value) when is_map(value) and not is_struct(value), do: value
  defp map(_value), do: %{}

  # ------------------------------------------------------------------
  # Local config fragment
  # ------------------------------------------------------------------

  defp map_local_config(nil, _connection_id), do: {%{}, [], [], []}

  defp map_local_config(source, connection_id) do
    config = LocalConfig.normalize_keys(source.document || %{})

    {fragment, tracker_dispositions, tracker_diagnostics} =
      map_tracker(Map.get(config, "tracker"), connection_id)

    {fragment, runner_dispositions, runner_diagnostics} =
      map_runners(Map.get(config, "runners"), fragment)

    {fragment, polling_dispositions, polling_diagnostics} =
      map_polling(Map.get(config, "polling"), fragment)

    {fragment, capacity_dispositions, capacity_diagnostics} =
      map_capacity(Map.get(config, "deployment"), Map.get(config, "capacity_ceiling"), fragment)

    {unsupported_dispositions, unsupported_differences, unsupported_diagnostics} =
      unsupported_local_config(config)

    mapped_dispositions = tracker_dispositions ++ runner_dispositions ++ polling_dispositions ++ capacity_dispositions
    dispositions = Enum.sort_by(mapped_dispositions ++ unsupported_dispositions, & &1.source_path)

    diagnostics =
      (tracker_diagnostics ++
         runner_diagnostics ++
         polling_diagnostics ++
         capacity_diagnostics ++
         unsupported_diagnostics ++ unsupported_nested_local_config(config) ++ invalid_local_fields(config))
      |> Enum.sort_by(& &1.path)

    {fragment, dispositions, unsupported_differences, diagnostics}
  end

  defp invalid_local_fields(config) do
    map_fields = ~w(tracker runners polling deployment)

    shape_errors =
      for key <- map_fields, Map.has_key?(config, key), not is_map(config[key]) do
        host_diagnostic("$.#{key}", :invalid_type, "$.#{key} must be a map")
      end

    number_fields =
      [{config, "capacity_ceiling", "$.capacity_ceiling"}, {map(config["polling"]), "interval_ms", "$.polling.interval_ms"}] ++
        Enum.map(@ceiling_keys, fn key ->
          {map(map(config["deployment"])["ceilings"]), key, "$.deployment.ceilings.#{key}"}
        end)

    number_errors =
      for {fields, key, path} <- number_fields,
          Map.has_key?(fields, key),
          not (is_integer(fields[key]) and fields[key] > 0) do
        host_diagnostic(path, :invalid_value, "#{path} must be a positive integer")
      end

    version_errors =
      if Map.has_key?(config, "version") and config["version"] != 1,
        do: [host_diagnostic("$.version", :unsupported_version, "only legacy configuration version 1 is supported")],
        else: []

    shape_errors ++ number_errors ++ version_errors ++ local_ceiling_errors(config)
  end

  defp local_ceiling_errors(config) do
    ceiling_errors =
      if is_map(config["deployment"]) and Map.has_key?(config["deployment"], "ceilings") and
           not is_map(config["deployment"]["ceilings"]),
         do: [host_diagnostic("$.deployment.ceilings", :invalid_type, "$.deployment.ceilings must be a map")],
         else: []

    ceiling = map(map(config["deployment"])["ceilings"])["max_concurrent_agents"]

    conflicts =
      if ceiling != nil and config["capacity_ceiling"] != nil and ceiling != config["capacity_ceiling"],
        do: [host_diagnostic("$.capacity_ceiling", :import_source_conflict, "legacy capacity ceilings disagree")],
        else: []

    ceiling_errors ++ conflicts
  end

  defp map_tracker(nil, _connection_id), do: {%{}, [], []}

  defp map_tracker(tracker, connection_id) do
    tracker = map(tracker)

    case secret_reference(tracker["api_key"]) do
      :ok ->
        connection = %{
          "kind" => Map.get(tracker, "kind", "linear"),
          "endpoint" => Map.get(tracker, "endpoint", "https://api.linear.app/graphql"),
          "api_key" => Map.get(tracker, "api_key", "$LINEAR_API_KEY")
        }

        dispositions =
          for field <- ~w(kind endpoint api_key) do
            disposition("$.tracker.#{field}", "$.host.tracker_connections.#{connection_id}.#{field}", :mapped)
          end

        {%{"tracker_connections" => %{connection_id => connection}}, dispositions, unmapped_tracker_policy(tracker)}

      {:error, diagnostic} ->
        {%{}, [], [diagnostic]}
    end
  end

  defp secret_reference(nil), do: :ok

  defp secret_reference(value) when is_binary(value) do
    if Regex.match?(@secret_reference_regex, value) do
      :ok
    else
      {:error, inline_credential_diagnostic("$.tracker.api_key")}
    end
  end

  defp secret_reference(_value), do: {:error, inline_credential_diagnostic("$.tracker.api_key")}

  defp inline_credential_diagnostic(path) do
    host_diagnostic(path, :inline_credential_rejected, "#{path} must stay an environment reference such as $LINEAR_API_KEY")
  end

  defp unmapped_tracker_policy(tracker) do
    defaults = %{
      "active_states" => @default_active_states,
      "terminal_states" => @default_terminal_states,
      "required_labels" => []
    }

    for key <- @unmappable_tracker_policy_keys,
        Map.has_key?(tracker, key),
        Map.get(tracker, key) != Map.get(defaults, key) do
      host_diagnostic(
        "$.tracker.#{key}",
        :unmapped_tracker_policy,
        "$.tracker.#{key} carries target policy a host-wide import cannot place; import the saved workflow for this tracker instead"
      )
    end
  end

  defp map_runners(nil, fragment), do: {fragment, [], []}

  defp map_runners(runners, fragment) do
    runners
    |> map()
    |> Enum.sort()
    |> Enum.reduce({fragment, [], []}, fn {id, raw_runner}, {fragment, dispositions, diagnostics} ->
      runner = map(raw_runner)
      defaulted = @runner_limit_fields -- Map.keys(runner)
      host_runner = Map.merge(runner, Map.take(@default_runner_limits, defaulted))

      dispositions =
        dispositions ++
          for field <- Map.keys(runner) do
            disposition("$.runners.#{id}.#{field}", "$.host.runners.#{id}.#{field}", :mapped)
          end ++
          for field <- defaulted do
            disposition("$.runners.#{id}.#{field}", "$.host.runners.#{id}.#{field}", :defaulted_restrictive)
          end

      fragment = Map.update(fragment, "runners", %{id => host_runner}, &Map.put(&1, id, host_runner))
      {fragment, dispositions, diagnostics}
    end)
  end

  defp map_polling(nil, fragment), do: {fragment, [], []}

  defp map_polling(polling, fragment) do
    interval = map(polling)["interval_ms"]

    if is_integer(interval) and interval > 0 do
      fragment = Map.update(fragment, "polling", %{"interval_ms" => interval}, &Map.put(&1, "interval_ms", interval))

      dispositions = [
        disposition("$.polling.interval_ms", "$.host.polling.interval_ms", :mapped)
      ]

      {fragment, dispositions, []}
    else
      {fragment, [], []}
    end
  end

  defp map_capacity(nil, nil, fragment), do: {fragment, [], []}

  defp map_capacity(deployment, legacy_ceiling, fragment) do
    ceilings = deployment |> map() |> Map.get("ceilings") |> map()

    {fragment, ceiling_dispositions} =
      Enum.reduce(~w(max_concurrent_agents max_concurrent_startups), {fragment, []}, fn field, {fragment, dispositions} ->
        case ceilings[field] do
          value when is_integer(value) and value > 0 ->
            fragment = Map.update(fragment, "capacity", %{field => value}, &Map.put(&1, field, value))

            {fragment,
             [
               disposition(
                 "$.deployment.ceilings.#{field}",
                 "$.host.capacity.#{field}",
                 :mapped
               )
               | dispositions
             ]}

          _absent ->
            {fragment, dispositions}
        end
      end)

    case legacy_ceiling do
      value when is_integer(value) and value > 0 ->
        fragment = Map.update(fragment, "capacity", %{"max_concurrent_agents" => value}, &Map.put(&1, "max_concurrent_agents", value))

        {
          fragment,
          [
            disposition("$.capacity_ceiling", "$.host.capacity.max_concurrent_agents", :mapped)
            | ceiling_dispositions
          ],
          []
        }

      _absent ->
        {fragment, ceiling_dispositions, []}
    end
  end

  # Every local configuration field the cutover cannot place is reported;
  # policy-bearing fields block the import instead of being dropped. Only the
  # version marker is informational.
  defp unsupported_local_config(config) do
    entries =
      config
      |> Enum.sort()
      |> Enum.flat_map(fn {key, _value} ->
        if key in @mappable_local_config_keys do
          []
        else
          path = "$.#{key}"
          reason = unsupported_local_config_reason(key)
          diagnostic = unsupported_local_config_diagnostic(path, key)

          [
            {disposition(path, nil, :not_mapped), source_difference(path, reason), diagnostic}
          ]
        end
      end)

    {
      Enum.map(entries, &elem(&1, 0)),
      Enum.map(entries, &elem(&1, 1)),
      Enum.flat_map(entries, &List.wrap(elem(&1, 2)))
    }
  end

  defp unsupported_local_config_diagnostic(path, key) do
    if key in @informational_local_config_keys do
      nil
    else
      host_diagnostic(
        path,
        :unsupported_field,
        "#{path} has no host-registry mapping and cannot be dropped; remove it from the import source or import it through its dedicated surface"
      )
    end
  end

  defp unsupported_local_config_reason("version"),
    do: "legacy configuration version marker; the host registry carries its own document version"

  defp unsupported_local_config_reason(_key),
    do: "legacy local configuration section has no host-registry mapping and blocks the cutover"

  # Unknown nested fields inside mappable sections cannot be dropped either.
  defp unsupported_nested_local_config(config) do
    section_field_diagnostics(map(config["tracker"]), @tracker_section_keys, "tracker") ++
      section_field_diagnostics(map(config["polling"]), @polling_section_keys, "polling") ++
      section_field_diagnostics(map(config["deployment"]), @deployment_section_keys, "deployment") ++
      deployment_ceiling_diagnostics(config)
  end

  defp section_field_diagnostics(section, allowed, name) when section != %{} do
    section
    |> Enum.sort()
    |> Enum.flat_map(fn {key, _value} ->
      if key in allowed do
        []
      else
        [
          host_diagnostic(
            "$.#{name}.#{key}",
            :unsupported_field,
            "$.#{name}.#{key} has no host-registry mapping and cannot be dropped; resolve the legacy configuration before cutover"
          )
        ]
      end
    end)
  end

  defp section_field_diagnostics(_section, _allowed, _name), do: []

  defp deployment_ceiling_diagnostics(config) do
    config
    |> map()
    |> Map.get("deployment")
    |> map()
    |> Map.get("ceilings")
    |> map()
    |> Enum.sort()
    |> Enum.flat_map(fn {key, _value} ->
      if key in @ceiling_keys do
        []
      else
        [
          host_diagnostic(
            "$.deployment.ceilings.#{key}",
            :unsupported_field,
            "$.deployment.ceilings.#{key} has no host-registry mapping and cannot be dropped; resolve the legacy configuration before cutover"
          )
        ]
      end
    end)
  end

  # ------------------------------------------------------------------
  # Legacy registry host fragment
  # ------------------------------------------------------------------

  # Supported host sections (including the shared repository policy layers)
  # carry into the proposal; any other legacy host field blocks instead of
  # being dropped. Host identity (id, state_root) stays with the live host.
  defp map_legacy_host(legacy_host) do
    fragment = Map.take(legacy_host, @supported_host_keys)

    invalid_containers =
      for key <- @host_entry_containers, Map.has_key?(legacy_host, key), not is_map(legacy_host[key]) do
        host_diagnostic("$.host.#{key}", :invalid_type, "$.host.#{key} must be a map")
      end

    diagnostics =
      legacy_host
      |> Map.keys()
      |> Enum.reject(&(&1 in @supported_host_keys or &1 in @legacy_host_identity_keys))
      |> Enum.sort()
      |> Enum.map(fn key ->
        host_diagnostic(
          "$.host.#{key}",
          :unsupported_host_field,
          "$.host.#{key} has no host-registry mapping and cannot be dropped; resolve the legacy registry before cutover"
        )
      end)

    {fragment, [], diagnostics ++ invalid_containers}
  end

  # ------------------------------------------------------------------
  # Source conflicts between two legacy authorities
  # ------------------------------------------------------------------

  defp source_conflicts(local_fragment, legacy_fragment, local_config, legacy_registry)
       when is_map(local_fragment) and is_map(legacy_fragment) and local_config != nil and
              legacy_registry != nil do
    for section <- @supported_host_keys,
        {field, value} <- Enum.sort(map(local_fragment[section])),
        legacy_section = map(legacy_fragment[section]),
        Map.has_key?(legacy_section, field),
        legacy_section[field] != value do
      host_diagnostic(
        "$.host.#{section}.#{field}",
        :import_source_conflict,
        "the legacy sources disagree on host #{section}.#{field}; resolve the conflict before cutover"
      )
    end
  end

  defp source_conflicts(_local_fragment, _legacy_fragment, _local_config, _legacy_registry), do: []

  # ------------------------------------------------------------------
  # Fragment application: fail-closed, no policy overwrite
  # ------------------------------------------------------------------

  # The registry never adopts a legacy value that differs from a value it
  # already holds: differing entries or fields become blocking
  # host-entry conflicts the operator must resolve first. Absent values map
  # in and equal values are explicit no-ops.
  defp apply_fragments(current_host, local_fragment, legacy_fragment) do
    {host, legacy_dispositions, legacy_conflicts} =
      apply_fragment(current_host, legacy_fragment, "legacy_registry")

    {host, local_dispositions, local_conflicts} = apply_fragment(host, local_fragment, nil)

    {host, legacy_dispositions ++ local_dispositions, legacy_conflicts ++ local_conflicts}
  end

  defp apply_fragment(host, fragment, _source) when fragment == %{}, do: {host, [], []}

  defp apply_fragment(host, fragment, source) do
    {host, entry_dispositions, entry_conflicts} =
      Enum.reduce(@host_entry_containers, {host, [], []}, &apply_entries(&1, &2, fragment, source))

    {host, section_dispositions, section_conflicts} =
      Enum.reduce(@supported_host_sections, {host, [], []}, fn section, {host, dispositions, conflicts} ->
        case Map.get(fragment, section) do
          nil ->
            {host, dispositions, conflicts}

          value ->
            apply_section(host, section, value, source, dispositions, conflicts)
        end
      end)

    {
      host,
      Enum.sort_by(entry_dispositions ++ section_dispositions, & &1.source_path),
      Enum.uniq(entry_conflicts ++ section_conflicts)
    }
  end

  defp apply_entries(container, state, fragment, source) do
    fragment
    |> Map.get(container, %{})
    |> map()
    |> Enum.sort()
    |> Enum.reduce(state, fn {id, entry}, {host, dispositions, conflicts} ->
      destination = "$.host.#{container}.#{id}"
      source_path = "#{source_path(source)}.#{container}.#{id}"
      {host, action} = merge_entry(host, [container, id], entry)
      action = if action == :conflict, do: :host_entry_conflict, else: action

      conflicts =
        case action do
          :host_entry_conflict -> [host_entry_conflict_diagnostic(destination) | conflicts]
          _mapped_or_unchanged -> conflicts
        end

      {host, [disposition(source_path, destination, action) | dispositions], conflicts}
    end)
  end

  defp apply_section(host, section, value, source, dispositions, conflicts) when not is_map(value) do
    destination = "$.host.#{section}"
    source_path = "#{source_path(source)}.#{section}"

    case Map.fetch(host, section) do
      :error ->
        {Map.put(host, section, value), [disposition(source_path, destination, :mapped) | dispositions], conflicts}

      {:ok, ^value} ->
        {host, [disposition(source_path, destination, :unchanged) | dispositions], conflicts}

      {:ok, _different} ->
        entry = disposition(source_path, destination, :host_entry_conflict)
        {host, [entry | dispositions], [host_entry_conflict_diagnostic(destination) | conflicts]}
    end
  end

  # Sections merge field-wise so partial fragments never remove fields the
  # registry already requires (for example capacity's reviewer limit).
  defp apply_section(host, section, value, source, dispositions, conflicts) do
    current = if is_map(host[section]), do: host[section], else: nil

    value
    |> map()
    |> Enum.sort()
    |> Enum.reduce({host, dispositions, conflicts}, fn {field, field_value}, {host, dispositions, conflicts} ->
      destination = "$.host.#{section}.#{field}"
      source_path = "#{source_path(source)}.#{section}.#{field}"

      cond do
        current == nil ->
          host = Map.update(host, section, %{field => field_value}, &Map.put(&1, field, field_value))
          {host, [disposition(source_path, destination, :mapped) | dispositions], conflicts}

        Map.get(current, field) == nil ->
          host = put_in(host, [section, field], field_value)
          {host, [disposition(source_path, destination, :mapped) | dispositions], conflicts}

        Map.get(current, field) == field_value ->
          {host, [disposition(source_path, destination, :unchanged) | dispositions], conflicts}

        true ->
          entry = disposition(source_path, destination, :host_entry_conflict)
          {host, [entry | dispositions], [host_entry_conflict_diagnostic(destination) | conflicts]}
      end
    end)
  end

  defp source_path(nil), do: "$.local_config"
  defp source_path("legacy_registry"), do: "$.legacy_registry"

  defp merge_entry(host, [container, id], entry) do
    current = get_in(host, [container, id])

    cond do
      is_nil(current) ->
        {Map.update(host, container, %{id => entry}, &Map.put(&1, id, entry)), :mapped}

      current == entry ->
        {host, :unchanged}

      true ->
        {host, :conflict}
    end
  end

  defp host_entry_conflict_diagnostic(destination) do
    host_diagnostic(
      destination,
      :host_entry_conflict,
      "#{destination} already holds a different value; align the registry or the import sources before cutover"
    )
  end

  # ------------------------------------------------------------------
  # Target migration
  # ------------------------------------------------------------------

  defp migrate_targets(current_targets, legacy_targets, manifests) do
    # Every legacy target id and every still-manifest-backed current target id
    # is processed explicitly; nothing is discarded by a merge. A legacy
    # target that differs from the registry target stays a visible conflict.
    ids =
      (Map.keys(legacy_targets) ++
         Enum.filter(Map.keys(current_targets), &manifest_target?(current_targets[&1])))
      |> Enum.uniq()
      |> Enum.sort()

    # Malformed entries (scalar, list, or null) are never migrated: preview/1
    # already rejected them with typed diagnostics, so they cannot reach the
    # registry document or a parity verdict from here.
    migrated =
      Enum.flat_map(ids, fn id ->
        source = legacy_targets[id] || current_targets[id]

        if target_entry?(source) do
          [migrate_target(id, source, current_targets[id], legacy_targets[id], manifests)]
        else
          []
        end
      end)

    {
      Enum.reduce(migrated, current_targets, fn entry, targets ->
        if entry.changed?, do: Map.put(targets, entry.target_id, entry.migrated), else: targets
      end),
      Enum.flat_map(migrated, & &1.dispositions),
      Enum.flat_map(migrated, & &1.diagnostics),
      Enum.map(migrated, &%{target_id: &1.target_id, verdict: &1.parity_verdict, findings: &1.parity_findings})
    }
  end

  # Only an explicit repo.manifest reference marks a manifest-backed legacy
  # target. A target with a repository path but no inline policy may be a
  # legitimate profile-only or defaults-only host target; it is carried, not
  # reread from a repository manifest.
  defp manifest_target?(target) when is_map(target) and not is_struct(target) do
    repo = map(target["repo"])
    is_binary(repo["manifest"]) and repo["manifest"] != "" and is_binary(repo["path"]) and repo["path"] != ""
  end

  # Scalar, list, and null entries cannot reference a repository manifest;
  # preview/1 rejects them with typed diagnostics instead.
  defp manifest_target?(_entry), do: false

  defp target_entry?(entry), do: is_map(entry) and not is_struct(entry)

  # Reject malformed entries in both registries, including entries that
  # manifest discovery skipped because they cannot reference a manifest.
  defp malformed_target_diagnostics(targets) do
    for {id, entry} <- targets, not target_entry?(entry) do
      path = "$.targets.#{id}"

      %Diagnostic{
        severity: :error,
        scope: {:target, id},
        path: path,
        code: :invalid_type,
        message: "#{path} must be a map"
      }
    end
  end

  defp migrate_target(id, legacy_target, current_target, legacy_registry_target, manifests) do
    binding = manifest_binding_for(legacy_target)
    before_manifest = before_manifest(binding, legacy_target, manifests)
    after_manifest = after_manifest(binding, legacy_target, manifests)
    {migrated, state_disposition} = force_paused(legacy_target)
    migrated = put_repository_policy(migrated, binding, after_manifest)
    migrated = drop_manifest_reference(migrated, binding)

    {changed?, dispositions, diagnostics} =
      target_changed_or_conflict(id, migrated, current_target, legacy_registry_target, state_disposition, binding)

    parity_findings = parity_findings(id, before_manifest, after_manifest, legacy_target, migrated)

    %{
      target_id: id,
      migrated: migrated,
      changed?: changed?,
      dispositions: dispositions,
      diagnostics: diagnostics,
      parity_verdict: if(parity_findings == [], do: :preserved, else: :weakened),
      parity_findings: parity_findings
    }
  end

  defp manifest_binding_for(legacy_target) do
    if manifest_target?(legacy_target) do
      repo = map(legacy_target["repo"])
      repo_path = Path.expand(repo["path"])

      %{manifest_path: Path.expand(Path.join(repo_path, repo["manifest"]))}
    else
      nil
    end
  end

  defp before_manifest(nil, legacy_target, _manifests), do: map(legacy_target["repository_policy"])

  defp before_manifest(binding, _legacy_target, manifests) do
    case Map.get(manifests, binding.manifest_path) do
      %{raw: raw} when is_map(raw) -> raw
      _missing -> nil
    end
  end

  defp after_manifest(nil, legacy_target, _manifests), do: map(legacy_target["repository_policy"])

  defp after_manifest(binding, _legacy_target, manifests) do
    case Map.get(manifests, binding.manifest_path) do
      %{compiled: compiled} when is_map(compiled) -> compiled
      _missing -> nil
    end
  end

  defp drop_manifest_reference(target, nil), do: target

  defp drop_manifest_reference(target, _binding) do
    update_in(target, ["repo"], &Map.delete(map(&1), "manifest"))
  end

  defp force_paused(target) do
    legacy_state = target["state"]
    migrated = target |> Map.put("state", "paused") |> Map.delete("dispatch_mode")

    if legacy_state in [nil, "paused"] do
      {migrated, nil}
    else
      {migrated, disposition("$.targets.state", nil, :forced_paused)}
    end
  end

  defp put_repository_policy(migrated, nil, _after_manifest), do: migrated

  defp put_repository_policy(migrated, _binding, after_manifest)
       when is_map(after_manifest) and after_manifest != %{},
       do: migrated |> Map.put("repository_policy", after_manifest) |> derive_expected_repository(after_manifest)

  defp put_repository_policy(migrated, _binding, _missing), do: migrated

  # Legacy targets pinned identity only through the repository manifest; the
  # migrated target must pin it explicitly.
  defp derive_expected_repository(%{"repo" => %{"expected_repository" => expected}} = target, _manifest)
       when is_binary(expected) and expected != "",
       do: target

  defp derive_expected_repository(%{"repo" => _repo} = target, manifest) do
    case get_in(manifest, ["project", "repository"]) do
      repository when is_binary(repository) and repository != "" ->
        put_in(target, ["repo", "expected_repository"], repository)

      _missing ->
        target
    end
  end

  # The registry never silently overwrites or duplicates targets. A repeated
  # import of identical content is an explicit no-op. An in-place migration
  # permits rewriting exactly the still-manifest-backed current target (or an
  # identical external legacy target); anything else that differs is a
  # blocking conflict the operator must resolve first.
  defp target_changed_or_conflict(id, _migrated, nil, _legacy_registry_target, state_disposition, binding) do
    dispositions =
      List.wrap(state_disposition) ++
        case binding do
          nil -> []
          _binding -> [disposition("$.repo.manifest", "$.targets.#{id}.repository_policy", :inlined_repository_policy)]
        end

    {true, dispositions, []}
  end

  defp target_changed_or_conflict(id, migrated, current_target, legacy_registry_target, state_disposition, binding) do
    comparable = drop_lifecycle(migrated)
    current_comparable = current_target |> map() |> drop_lifecycle()

    cond do
      comparable == current_comparable ->
        {false, [disposition("$.targets.#{id}", "$.targets.#{id}", :unchanged)], []}

      legacy_registry_target != nil and legacy_registry_target != current_target ->
        target_conflict(id, "the legacy registry target differs from the registry target")

      manifest_target?(current_target) ->
        # In-place migration of exactly the bound current legacy target.
        dispositions =
          List.wrap(state_disposition) ++
            case binding do
              nil -> []
              _binding -> [disposition("$.repo.manifest", "$.targets.#{id}.repository_policy", :inlined_repository_policy)]
            end

        {true, dispositions, []}

      true ->
        {_changed?, _dispositions, diagnostics} = target_conflict(id, "repeated import cannot overwrite or duplicate it")
        {false, [disposition("$.targets.#{id}", "$.targets.#{id}", :host_entry_conflict)], diagnostics}
    end
  end

  defp drop_lifecycle(target), do: target |> Map.delete("state") |> Map.delete("dispatch_mode")

  defp target_conflict(id, reason) do
    path = "$.targets.#{id}"

    {false, [],
     [
       %Diagnostic{
         severity: :error,
         scope: {:target, id},
         path: path,
         code: :target_conflict,
         message: "#{path} already exists with different configuration; #{reason}"
       }
     ]}
  end

  defp parity_findings(id, before_manifest, after_manifest, before_target, migrated) do
    case PolicyParity.compare(
           %{"manifest" => before_manifest, "target" => before_target},
           %{"manifest" => after_manifest, "target" => migrated},
           id
         ) do
      :ok -> []
      {:weakened, findings} -> findings
    end
  end

  # ------------------------------------------------------------------
  # Proposal validation
  # ------------------------------------------------------------------

  defp finish_proposal(result, current_document, current_bytes, registry_path, home) do
    %Result{
      proposal: proposal,
      proposed_bytes: proposed_bytes,
      import_diagnostics: diagnostics,
      field_dispositions: dispositions,
      source_differences: differences,
      parity: parity,
      sources: sources
    } = result

    case Schema.validate(proposal, home: home) do
      {:ok, snapshot} ->
        generation = Preview.generation(proposed_bytes)

        proposed_snapshot =
          snapshot
          |> Map.merge(%{path: registry_path, source_hash: generation, generation: generation})
          |> Validation.validate(registry_path: registry_path)
          |> Composition.compose()

        registry_preview =
          case current_snapshot(current_document, current_bytes, registry_path, home) do
            nil -> Preview.preview(proposed_snapshot, proposed_bytes)
            current -> Preview.preview(current, proposed_snapshot, proposed_bytes)
          end

        weakened? = Enum.any?(parity, &(&1.verdict == :weakened))

        {:ok,
         %Result{
           sources: sources,
           proposal: proposal,
           proposed_bytes: proposed_bytes,
           snapshot: proposed_snapshot,
           registry_preview: registry_preview,
           applicable?:
             diagnostics == [] and proposed_snapshot.globally_valid? and not weakened? and
               Enum.all?(proposed_snapshot.targets, fn {_id, target} -> target.valid? and is_binary(target.policy_hash) end),
           import_diagnostics: diagnostics,
           field_dispositions: dispositions,
           source_differences: differences,
           parity: parity
         }}

      {:error, %SymphonyElixir.TargetRegistry.Error{} = source} ->
        {:error, source}
    end
  end

  defp current_snapshot(current_document, current_bytes, registry_path, home) do
    case Schema.validate(current_document, home: home) do
      {:ok, snapshot} ->
        generation = Preview.generation(current_bytes)

        snapshot
        |> Map.merge(%{path: registry_path, source_hash: generation, generation: generation})

      _invalid_or_legacy ->
        nil
    end
  end

  defp sources(local_config, legacy_registry, manifests) do
    local_source = source_entry(local_config, "local_config")
    legacy_source = source_entry(legacy_registry, "legacy_registry")

    manifest_sources =
      manifests
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {path, _manifest} -> %{kind: "repo_manifest", path: path, checksum: nil} end)

    List.wrap(local_source) ++ List.wrap(legacy_source) ++ manifest_sources
  end

  defp source_entry(nil, _kind), do: nil

  defp source_entry(source, kind), do: [%{kind: kind, path: source.path, checksum: nil}]

  defp disposition(source_path, destination_path, action) do
    %{source_path: source_path, destination_path: destination_path, action: action}
  end

  defp source_difference(source_path, reason) do
    %{
      source_path: source_path,
      destination_path: nil,
      classification: "unsupported",
      reason: reason
    }
  end

  defp host_diagnostic(path, code, message) do
    %Diagnostic{severity: :error, scope: :host, path: path, code: code, message: message}
  end
end
