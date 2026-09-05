defmodule SymphonyElixir.OperatorSettings do
  @moduledoc "Authoritative, credential-safe settings choices and retained selection errors."

  alias SymphonyElixir.{Config, HostScheduler, OperatorRepositoryChoices, RunSetup}
  alias SymphonyElixir.TargetRegistry.{FileStore, Schema, Yaml}

  @spec build(GenServer.server(), map(), keyword()) :: map()
  def build(scheduler, request, opts) do
    {registry, generation, source_reason} = registry(scheduler)
    target_id = request["target_id"]
    target = if registry, do: Map.get(registry.targets, target_id)
    configured = target_configured(registry, target)
    repo = request["repository"] || configured_value(configured, "repo.path")
    repo = if is_binary(repo), do: repo
    selections = request["selections"] || %{}

    definitions =
      Schema.settings_choices()
      |> Map.merge(Config.Schema.settings_choices())
      |> Map.merge(RunSetup.settings_choices())
      |> Map.new(fn {path, definition} ->
        {path,
         %{
           cardinality: definition.cardinality,
           choices: Enum.map(definition.values, &choice/1),
           status: "current",
           reason: nil
         }}
      end)
      |> Map.merge(host_choices(registry, source_reason))
      |> Map.merge(OperatorRepositoryChoices.build(repo, opts))

    fields =
      Map.new(definitions, fn {path, field} ->
        selected = Map.get(selections, path, configured_value(configured, path))
        {path, select(field, selected)}
      end)

    allowed = fields["runners.allowed"].selected
    fields = Map.update!(fields, "runners.default", &constrain_default(&1, allowed))

    errors = selection_errors(fields, selections)
    reason = source_reason || target_reason(target_id, target)

    %{
      registry_generation: generation,
      status: if(reason, do: "unavailable", else: "current"),
      reason: reason,
      fields: fields,
      apply_blocked: not is_nil(reason) or errors != [],
      errors: errors
    }
  end

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
    values = List.wrap(selected)
    cardinality_valid = valid_cardinality?(field.cardinality, selected)

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

    choices = choices ++ missing
    bad = Enum.find(choices, &(&1.selected and &1.status not in ["current", "available"]))

    reason =
      cond do
        not cardinality_valid -> "invalid_cardinality"
        bad -> bad.reason
        true -> nil
      end

    field |> Map.merge(%{choices: choices, selected: selected, valid: is_nil(reason), reason: reason || field.reason})
  end

  defp valid_cardinality?(_cardinality, nil), do: true
  defp valid_cardinality?("list", selected), do: is_list(selected)
  defp valid_cardinality?("scalar", selected), do: not is_list(selected) and not is_map(selected)

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
end
