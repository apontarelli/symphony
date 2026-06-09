defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Workflow.ModuleRegistry

  @render_opts [strict_variables: true, strict_filters: true]

  @type prompt_bundle :: %{
          prompt: String.t(),
          workflow_module_resolution: ModuleRegistry.prompt_module_resolution()
        }

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    build_prompt_bundle(issue, opts).prompt
  end

  @spec build_prompt_bundle(SymphonyElixir.Linear.Issue.t(), keyword()) :: prompt_bundle()
  def build_prompt_bundle(issue, opts \\ []) do
    workflow = workflow!()
    workflow_module_resolution = workflow_module_resolution!(workflow)
    policy = prompt_policy(issue, opts)

    template =
      workflow
      |> prompt_template!()
      |> parse_template!()

    prompt =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map(),
          "policy" => policy |> to_solid_value(),
          "policy_json" => Jason.encode!(policy, pretty: true),
          "workflow" => workflow_context(workflow_module_resolution)
        },
        @render_opts
      )
      |> IO.iodata_to_binary()
      |> append_selected_policy_context(policy)

    %{
      prompt: prompt,
      workflow_module_resolution: workflow_module_resolution
    }
  end

  @doc false
  @spec workpad_policy_stamp(map()) :: String.t()
  def workpad_policy_stamp(policy) when is_map(policy) do
    fields =
      [
        {"profile", selected_profile(policy)},
        {"target", selected_target(policy)},
        {"policy_ref", selected_policy_ref(policy)}
      ]
      |> maybe_append_override_source(policy)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{stamp_value(value)}" end)

    "Policy: " <> fields
  end

  defp prompt_policy(issue, opts) do
    case Keyword.fetch(opts, :policy) do
      {:ok, policy} when is_map(policy) ->
        policy

      _ ->
        resolve_prompt_policy(issue)
    end
  end

  defp resolve_prompt_policy(issue) do
    case Config.issue_policy(issue) do
      {:ok, policy} -> policy
      _ -> %{}
    end
  end

  defp workflow! do
    case Workflow.current() do
      {:ok, workflow} when is_map(workflow) -> workflow
      {:error, reason} -> raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
    end
  end

  defp prompt_template!(%{prompt_template: prompt}) when is_binary(prompt), do: prompt

  defp workflow_module_resolution!(%{workflow_module_resolution: resolution}) when is_map(resolution), do: resolution

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp workflow_context(%{module_refs: refs, module_names: names, policy_hash: policy_hash, rendered: rendered}) do
    %{
      "modules" => rendered,
      "module_policy_hash" => policy_hash,
      "module_names" => Enum.join(names, ", "),
      "module_refs" => Enum.map(refs, &to_solid_map/1)
    }
  end

  defp append_selected_policy_context(prompt, policy) when is_map(policy) and map_size(policy) > 0 do
    [String.trim_trailing(prompt), selected_policy_context(policy)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp append_selected_policy_context(prompt, _policy), do: prompt

  defp selected_policy_context(policy) do
    stamp_rule =
      "- Stamp rule: add/update only that one-line stamp in the active `## Codex Workpad` before " <>
        "implementation work starts; do not add a larger policy section unless a conflict/blocker needs explanation."

    sections =
      [
        "## Selected Workflow Profile",
        "",
        "- Workpad stamp: `#{workpad_policy_stamp(policy)}`",
        stamp_rule,
        policy_section("Profile rules", prompt_rule_items(policy)),
        policy_section("Validation requirements", validation_requirement_items(policy)),
        policy_section("Review requirements", review_requirement_items(policy))
      ]
      |> List.flatten()
      |> Enum.reject(&(&1 == nil or &1 == ""))

    Enum.join(sections, "\n")
  end

  defp policy_section(_title, []), do: []

  defp policy_section(title, items) do
    ["", "#{title}:" | Enum.map(items, &"- #{&1}")]
  end

  defp prompt_rule_items(policy) do
    [
      policy_value(policy, "prompt_rules"),
      policy_value(policy, "prompt_requirements"),
      prompt_policy_rules(policy_value(policy, "prompt"))
    ]
    |> policy_items()
  end

  defp prompt_policy_rules(%{} = prompt_policy) do
    [
      policy_value(prompt_policy, "rules"),
      policy_value(prompt_policy, "instructions"),
      policy_value(prompt_policy, "requirements")
    ]
    |> policy_items()
    |> case do
      [] -> prompt_policy
      items -> items
    end
  end

  defp prompt_policy_rules(prompt_policy), do: prompt_policy

  defp validation_requirement_items(policy) do
    [
      named_policy_value("checks", policy_value(policy, "checks")),
      named_policy_value("completion_requirements", policy_value(policy, "completion_requirements")),
      named_policy_value("validation", policy_value(policy, "validation")),
      named_policy_value("validation_requirements", policy_value(policy, "validation_requirements"))
    ]
    |> policy_items()
  end

  defp review_requirement_items(policy) do
    [
      named_policy_value("review", policy_value(policy, "review")),
      named_policy_value("review_requirements", policy_value(policy, "review_requirements")),
      named_policy_value("review_routing", policy_value(policy, "review_routing"))
    ]
    |> policy_items()
  end

  defp named_policy_value(_name, nil), do: nil
  defp named_policy_value(_name, []), do: nil
  defp named_policy_value(_name, value) when is_map(value) and map_size(value) == 0, do: nil

  defp named_policy_value(name, values) when is_list(values) do
    Enum.map(values, fn value -> "#{name}: #{format_policy_value(value)}" end)
  end

  defp named_policy_value(name, value), do: "#{name}: #{format_policy_value(value)}"

  defp policy_items(values) when is_list(values) do
    values
    |> List.flatten()
    |> Enum.reject(&empty_policy_value?/1)
    |> Enum.flat_map(&policy_item/1)
  end

  defp policy_item(%{} = value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, entry_value} -> "#{key}: #{format_policy_value(entry_value)}" end)
  end

  defp policy_item(value), do: [format_policy_value(value)]

  defp empty_policy_value?(nil), do: true
  defp empty_policy_value?(value) when is_map(value) and map_size(value) == 0, do: true
  defp empty_policy_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp empty_policy_value?(_value), do: false

  defp format_policy_value(value) when is_binary(value), do: value
  defp format_policy_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_policy_value(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp format_policy_value(value), do: to_string(value)

  defp maybe_append_override_source(fields, policy) do
    case override_source(policy) do
      nil -> fields
      source -> fields ++ [{"override", source}]
    end
  end

  defp override_source(policy) do
    metadata = policy_metadata(policy)

    cond do
      truthy?(policy_value(metadata, "cli_override")) ->
        policy_value(metadata, "source") || "cli_override"

      policy_value(metadata, "override_source") ->
        policy_value(metadata, "override_source")

      policy_value(metadata, "override") ->
        policy_value(metadata, "override")

      source = policy_value(metadata, "source") ->
        if String.ends_with?(to_string(source), "_override"), do: source

      true ->
        nil
    end
  end

  defp selected_profile(policy) do
    policy
    |> policy_metadata()
    |> policy_value("profile")
    |> case do
      nil -> "default"
      profile -> profile
    end
  end

  defp selected_target(policy) do
    policy
    |> policy_value("delivery")
    |> case do
      %{} = delivery -> policy_value(delivery, "pr_target")
      _delivery -> nil
    end
    |> case do
      nil -> "unknown"
      target -> target
    end
  end

  defp selected_policy_ref(policy), do: policy_value(policy, "policy_ref") || "unknown"

  defp policy_metadata(policy) do
    case policy_value(policy, "policy_metadata") do
      %{} = metadata -> metadata
      _metadata -> %{}
    end
  end

  defp policy_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> policy_atom_value(map, key)
    end
  end

  defp policy_atom_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp stamp_value(value) do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truthy?(value), do: value == true or value == "true"
end
