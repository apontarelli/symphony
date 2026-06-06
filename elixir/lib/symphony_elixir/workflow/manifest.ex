defmodule SymphonyElixir.Workflow.Manifest do
  @moduledoc false

  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workflow.ModuleRegistry

  @type diagnostic :: %{path: String.t(), message: String.t()}
  @type manifest_error ::
          {:invalid_manifest, [diagnostic()]}
          | {:manifest_parse_error, term()}
          | {:missing_manifest_file, Path.t(), File.posix()}

  @spec load(Path.t()) :: {:ok, Workflow.loaded_workflow()} | {:error, manifest_error()}
  def load(path) when is_binary(path) do
    with {:ok, content} <- read_manifest(path),
         {:ok, decoded} <- decode_manifest(content),
         {:ok, manifest} <- normalize_manifest(decoded) do
      {:ok, compile(manifest)}
    end
  end

  @spec manifest_file_name() :: String.t()
  def manifest_file_name, do: "symphony.yml"

  defp read_manifest(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:missing_manifest_file, path, reason}}
    end
  end

  defp decode_manifest(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, normalize_keys(decoded)}

      {:ok, _decoded} ->
        {:error, {:invalid_manifest, [%{path: "$", message: "must be a map"}]}}

      {:error, reason} ->
        {:error, {:manifest_parse_error, reason}}
    end
  end

  defp normalize_manifest(raw) do
    {project, project_errors} = normalize_project(Map.get(raw, "project"))
    {app, app_errors} = normalize_app(Map.get(raw, "app"))
    {docs, docs_errors} = normalize_docs(Map.get(raw, "docs"))
    {vcs, vcs_errors} = normalize_vcs(Map.get(raw, "vcs"))
    {delivery, delivery_errors} = normalize_delivery(Map.get(raw, "delivery"), vcs)
    {validation, validation_errors} = normalize_validation(Map.get(raw, "validation"))
    {autonomy, autonomy_errors} = normalize_autonomy(Map.get(raw, "autonomy"))
    {workflow, workflow_errors} = normalize_workflow(Map.get(raw, "workflow"))
    {runtime, runtime_errors} = normalize_runtime(Map.get(raw, "runtime"))
    {prompt_template, prompt_errors} = string_field(raw, "prompt_template", "prompt_template", default: nil)

    errors =
      project_errors ++
        app_errors ++
        docs_errors ++
        vcs_errors ++
        delivery_errors ++
        validation_errors ++
        autonomy_errors ++ workflow_errors ++ runtime_errors ++ prompt_errors

    if errors == [] do
      manifest =
        %{
          "project" => finalize_project(project),
          "app" => app,
          "docs" => docs,
          "vcs" => vcs,
          "delivery" => delivery,
          "validation" => validation,
          "autonomy" => autonomy,
          "workflow" => workflow,
          "runtime" => runtime
        }
        |> maybe_put("prompt_template", prompt_template)

      case validate_manifest_modules(Enum.with_index(manifest["workflow"]["modules"]), manifest) do
        [] -> {:ok, manifest}
        module_errors -> {:error, {:invalid_manifest, module_errors}}
      end
    else
      {:error, {:invalid_manifest, errors}}
    end
  end

  defp normalize_project(nil) do
    {%{"slug" => nil, "name" => nil, "repository" => nil, "facts" => %{}}, []}
  end

  defp normalize_project(raw) when is_map(raw) do
    {slug, slug_errors} = string_field(raw, "slug", "project.slug", default: nil)
    {name, name_errors} = string_field(raw, "name", "project.name", default: nil)
    {repository, repository_errors} = string_field(raw, "repository", "project.repository", default: nil)
    {facts, facts_errors} = map_field(raw, "facts", "project.facts", default: %{})

    project =
      %{"slug" => slug, "name" => name, "facts" => facts}
      |> maybe_put("repository", repository)

    {project, slug_errors ++ name_errors ++ repository_errors ++ facts_errors}
  end

  defp normalize_project(_raw) do
    {%{"slug" => nil, "name" => nil, "repository" => nil, "facts" => %{}}, [type_error("project", "must be a map")]}
  end

  defp finalize_project(project) do
    Map.put(project, "name", Map.get(project, "name") || Map.get(project, "slug"))
  end

  defp normalize_app(nil), do: {%{"kind" => "local"}, []}

  defp normalize_app(raw) when is_map(raw) do
    {kind, errors} = string_field(raw, "kind", "app.kind", default: "local")
    {%{"kind" => kind}, errors}
  end

  defp normalize_app(_raw), do: {%{"kind" => "local"}, [type_error("app", "must be a map")]}

  defp normalize_docs(nil), do: {%{"entry_points" => []}, []}

  defp normalize_docs(raw) when is_map(raw) do
    {entry_points, errors} = string_list_field(raw, "entry_points", "docs.entry_points", default: [])
    {%{"entry_points" => entry_points}, errors}
  end

  defp normalize_docs(_raw), do: {%{"entry_points" => []}, [type_error("docs", "must be a map")]}

  defp normalize_vcs(nil), do: {%{"kind" => "git", "default_branch" => "main"}, []}

  defp normalize_vcs(raw) when is_map(raw) do
    {kind, kind_errors} = string_field(raw, "kind", "vcs.kind", default: "git")
    {default_branch, branch_errors} = string_field(raw, "default_branch", "vcs.default_branch", default: "main")
    {posture, posture_errors} = string_field(raw, "posture", "vcs.posture", default: nil)

    vcs =
      %{"kind" => kind, "default_branch" => default_branch}
      |> maybe_put("posture", posture)

    {vcs, kind_errors ++ branch_errors ++ posture_errors}
  end

  defp normalize_vcs(_raw), do: {%{"kind" => "git", "default_branch" => "main"}, [type_error("vcs", "must be a map")]}

  defp normalize_delivery(nil, vcs), do: {%{"pr_target" => vcs["default_branch"]}, []}

  defp normalize_delivery(raw, vcs) when is_map(raw) do
    {pr_target, errors} = string_field(raw, "pr_target", "delivery.pr_target", default: vcs["default_branch"])
    {%{"pr_target" => pr_target}, errors}
  end

  defp normalize_delivery(_raw, vcs), do: {%{"pr_target" => vcs["default_branch"]}, [type_error("delivery", "must be a map")]}

  defp normalize_validation(nil), do: {%{"gates" => []}, []}

  defp normalize_validation(raw) when is_map(raw) do
    {gates, errors} = gates_field(raw, "gates", "validation.gates")
    {%{"gates" => gates}, errors}
  end

  defp normalize_validation(_raw), do: {%{"gates" => []}, [type_error("validation", "must be a map")]}

  defp normalize_autonomy(nil) do
    {%{"profile" => "default", "completion_requirements" => []}, []}
  end

  defp normalize_autonomy(raw) when is_map(raw) do
    {profile, profile_errors} = string_field(raw, "profile", "autonomy.profile", default: "default")

    {completion_requirements, requirement_errors} =
      string_list_field(raw, "completion_requirements", "autonomy.completion_requirements", default: [])

    {review, review_errors} = map_field(raw, "review", "autonomy.review", default: nil)
    policy_ref_errors = unsupported_field(raw, "policy_ref", "autonomy.policy_ref")

    autonomy =
      %{"profile" => profile, "completion_requirements" => completion_requirements}
      |> maybe_put("review", review)

    {autonomy, profile_errors ++ requirement_errors ++ review_errors ++ policy_ref_errors}
  end

  defp normalize_autonomy(_raw) do
    {%{"profile" => "default", "completion_requirements" => []}, [type_error("autonomy", "must be a map")]}
  end

  defp normalize_workflow(nil) do
    with {:ok, modules} <- ModuleRegistry.default_modules("default") do
      {%{"preset" => "default", "modules" => modules}, []}
    end
  end

  defp normalize_workflow(raw) when is_map(raw) do
    {preset, preset_errors} = string_field(raw, "preset", "workflow.preset", default: "default")

    case ModuleRegistry.default_modules(preset) do
      {:ok, default_modules} ->
        {modules, module_errors} = resolve_workflow_modules(raw, default_modules)

        {%{"preset" => preset, "modules" => modules}, preset_errors ++ module_errors}

      {:error, diagnostic} ->
        {%{"preset" => preset, "modules" => []}, preset_errors ++ [diagnostic]}
    end
  end

  defp normalize_workflow(_raw), do: {%{"preset" => "default", "modules" => []}, [type_error("workflow", "must be a map")]}

  defp resolve_workflow_modules(raw, default_modules) do
    case indexed_string_list_field(raw, "modules", "workflow.modules", default: nil) do
      {nil, errors} ->
        {default_modules, errors}

      {manifest_modules, errors} ->
        errors = errors ++ validate_manifest_modules(manifest_modules)
        module_names = Enum.map(manifest_modules, fn {name, _index} -> name end)
        {Enum.uniq(default_modules ++ module_names), errors}
    end
  end

  defp validate_manifest_modules(modules, manifest \\ nil)

  defp validate_manifest_modules(modules, nil) do
    Enum.flat_map(modules, fn {name, index} ->
      case ModuleRegistry.module_defaults(name, index) do
        {:ok, _defaults} -> []
        {:error, diagnostic} -> [diagnostic]
      end
    end)
  end

  defp validate_manifest_modules(modules, manifest) do
    Enum.flat_map(modules, fn {name, index} ->
      ModuleRegistry.module_diagnostics(name, index, manifest)
    end)
  end

  defp compile(manifest) do
    config =
      manifest
      |> registry_config()
      |> deep_merge(manifest_config(manifest))
      |> deep_merge(manifest["runtime"])

    prompt = Map.get(manifest, "prompt_template") || prompt_template(manifest)

    %{
      config: config,
      prompt: prompt,
      prompt_template: prompt
    }
  end

  defp registry_config(%{"workflow" => %{"preset" => preset_name, "modules" => modules}} = manifest) do
    {:ok, preset} = ModuleRegistry.preset(preset_name)

    module_config =
      modules
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {name, index}, config ->
        {:ok, module_config} = ModuleRegistry.module_config(name, index, manifest)
        deep_merge(config, module_config)
      end)

    deep_merge(preset.config, module_config)
  end

  defp manifest_config(manifest) do
    project = manifest["project"]
    delivery = manifest["delivery"]
    validation = manifest["validation"]
    autonomy = manifest["autonomy"]

    %{
      "manifest" => manifest,
      "checks" => validation["gates"],
      "completion_requirements" => autonomy["completion_requirements"],
      "delivery" => delivery,
      "profiles" => manifest_profiles(manifest),
      "policy_metadata" => %{
        "profile" => autonomy["profile"],
        "project_id" => nil,
        "project_slug" => project["slug"],
        "source" => "symphony_manifest"
      }
    }
  end

  defp manifest_profiles(manifest) do
    profile = manifest["autonomy"]["profile"]
    policy = manifest_policy(manifest)

    %{"default" => policy}
    |> maybe_put(profile, policy)
  end

  defp manifest_policy(manifest) do
    %{
      "checks" => manifest["validation"]["gates"],
      "completion_requirements" => manifest["autonomy"]["completion_requirements"],
      "delivery" => manifest["delivery"],
      "manifest" => manifest_policy_inputs(manifest)
    }
    |> maybe_put("review", Map.get(manifest["autonomy"], "review"))
  end

  defp manifest_policy_inputs(manifest) do
    Map.take(manifest, ["project", "app", "docs", "vcs", "workflow"])
  end

  defp prompt_template(manifest) do
    project = manifest["project"]
    app = manifest["app"]
    docs = manifest["docs"]["entry_points"]
    facts = project["facts"]
    validation_gates = manifest["validation"]["gates"]
    completion_requirements = manifest["autonomy"]["completion_requirements"]
    review = Map.get(manifest["autonomy"], "review")
    vcs = manifest["vcs"]
    delivery = manifest["delivery"]
    workflow = manifest["workflow"]
    module_sections = registry_prompt_sections(workflow)

    [
      "You are working on a Linear issue for #{project["name"]}.",
      "",
      "Project slug: #{project["slug"]}",
      "Repository: #{project["repository"]}",
      "App kind: #{app["kind"]}",
      prompt_map_section("Project facts", facts),
      prompt_list_section("Docs entry points", docs),
      prompt_vcs_section(vcs),
      prompt_delivery_section(delivery),
      prompt_gate_section(validation_gates),
      prompt_list_section("Completion requirements", completion_requirements),
      prompt_review_section(review),
      "",
      "Workflow modules:",
      module_sections,
      "",
      "{% if attempt %}",
      "Continuation context:",
      "",
      "- This is retry attempt {{ attempt }} because the ticket is still in an active state.",
      "- Resume from the current workspace state instead of restarting from scratch.",
      "- Do not repeat already-completed investigation or validation unless needed for new code changes.",
      "- Do not end the turn while the issue remains in an active state unless blocked by missing required permissions or secrets.",
      "{% endif %}",
      "",
      "Issue context:",
      "Identifier: {{ issue.identifier }}",
      "Title: {{ issue.title }}",
      "Current status: {{ issue.state }}",
      "Labels: {{ issue.labels }}",
      "URL: {{ issue.url }}",
      "",
      "Description:",
      "{% if issue.description %}",
      "{{ issue.description }}",
      "{% else %}",
      "No description provided.",
      "{% endif %}"
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp registry_prompt_sections(%{"preset" => preset_name, "modules" => modules}) do
    {:ok, preset} = ModuleRegistry.preset(preset_name)

    module_sections =
      modules
      |> Enum.with_index()
      |> Enum.flat_map(fn {name, index} ->
        {:ok, prompt_sections} = ModuleRegistry.module_prompt_sections(name, index)
        Enum.map(prompt_sections, &"- #{&1}")
      end)

    Enum.map(preset.prompt_sections, &"- #{&1}") ++ module_sections
  end

  defp prompt_list_section(_title, []), do: []

  defp prompt_list_section(title, values) do
    [title <> ":" | Enum.map(values, &"- #{&1}")]
  end

  defp prompt_map_section(_title, values) when values == %{}, do: []

  defp prompt_map_section(title, values) do
    lines =
      values
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> "- #{key}: #{prompt_value(value)}" end)

    [title <> ":" | lines]
  end

  defp prompt_value(value) when is_binary(value), do: value
  defp prompt_value(value), do: inspect(value)

  defp prompt_vcs_section(vcs) do
    [
      "VCS:",
      "- Kind: #{vcs["kind"]}",
      "- Default branch: #{vcs["default_branch"]}"
    ]
    |> maybe_append("posture", vcs["posture"])
  end

  defp maybe_append(lines, _label, nil), do: lines
  defp maybe_append(lines, label, value), do: lines ++ ["- #{String.capitalize(label)}: #{value}"]

  defp prompt_delivery_section(%{"pr_target" => pr_target}) do
    [
      "Delivery:",
      "- PR target: #{pr_target}"
    ]
  end

  defp prompt_review_section(nil), do: []

  defp prompt_review_section(review) do
    [
      "Review policy:"
      | review
        |> Enum.sort_by(fn {key, _value} -> key end)
        |> Enum.map(fn {key, value} -> "- #{key}: #{prompt_value(value)}" end)
    ]
  end

  defp prompt_gate_section([]), do: ["Validation gates:", "- Use the repo-local validation gate that matches the changed surface."]

  defp prompt_gate_section(gates) do
    ["Validation gates:" | Enum.map(gates, &"- #{&1["name"]}: #{&1["command"]}")]
  end

  defp gates_field(raw, key, path) do
    case Map.fetch(raw, key) do
      :error ->
        {[], []}

      {:ok, values} when is_list(values) ->
        values
        |> Enum.with_index()
        |> Enum.reduce({[], []}, &collect_gate(&1, &2, path))
        |> reverse_items()

      {:ok, _value} ->
        {[], [type_error(path, "must be a list")]}
    end
  end

  defp normalize_gate(raw, path) when is_map(raw) do
    {name, name_errors} = string_field(raw, "name", path <> ".name", required?: true)
    {command, command_errors} = string_field(raw, "command", path <> ".command", required?: true)

    if name_errors ++ command_errors == [] do
      {:ok, %{"name" => name, "command" => command}}
    else
      {:error, name_errors ++ command_errors}
    end
  end

  defp normalize_gate(_raw, path), do: {:error, [type_error(path, "must be a map")]}

  defp collect_gate({value, index}, {gates, errors}, path) do
    case normalize_gate(value, "#{path}[#{index}]") do
      {:ok, gate} -> {[gate | gates], errors}
      {:error, gate_errors} -> {gates, errors ++ gate_errors}
    end
  end

  defp string_field(raw, key, path, opts) do
    default = Keyword.get(opts, :default)
    required? = Keyword.get(opts, :required?, false)

    case Map.fetch(raw, key) do
      :error when required? ->
        {default, [required(path)]}

      :error ->
        {default, []}

      {:ok, nil} when required? ->
        {default, [required(path)]}

      {:ok, nil} ->
        {default, []}

      {:ok, value} when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" and required? do
          {default, [required(path)]}
        else
          {trimmed, []}
        end

      {:ok, _value} ->
        {default, [type_error(path, "must be a string")]}
    end
  end

  defp map_field(raw, key, path, opts) do
    default = Keyword.fetch!(opts, :default)

    case Map.fetch(raw, key) do
      :error -> {default, []}
      {:ok, nil} -> {default, []}
      {:ok, value} when is_map(value) -> {value, []}
      {:ok, _value} -> {default, [type_error(path, "must be a map")]}
    end
  end

  defp normalize_runtime(nil), do: {%{}, []}
  defp normalize_runtime(raw) when is_map(raw), do: {raw, []}
  defp normalize_runtime(_raw), do: {%{}, [type_error("runtime", "must be a map")]}

  defp string_list_field(raw, key, path, opts) do
    default = Keyword.fetch!(opts, :default)

    case Map.fetch(raw, key) do
      :error ->
        {default, []}

      {:ok, nil} ->
        {default, []}

      {:ok, values} when is_list(values) ->
        values
        |> Enum.with_index()
        |> Enum.reduce({[], []}, &collect_string_item(&1, &2, path))
        |> reverse_items()

      {:ok, _value} ->
        {default, [type_error(path, "must be a list")]}
    end
  end

  defp indexed_string_list_field(raw, key, path, opts) do
    default = Keyword.fetch!(opts, :default)

    case Map.fetch(raw, key) do
      :error ->
        {default, []}

      {:ok, nil} ->
        {default, []}

      {:ok, values} when is_list(values) ->
        values
        |> Enum.with_index()
        |> Enum.reduce({[], []}, &collect_indexed_string_item(&1, &2, path))
        |> reverse_items()

      {:ok, _value} ->
        {default, [type_error(path, "must be a list")]}
    end
  end

  defp required(path), do: %{path: path, message: "is required"}
  defp type_error(path, message), do: %{path: path, message: message}

  defp unsupported_field(raw, key, path) do
    if Map.has_key?(raw, key) do
      [%{path: path, message: "is not supported; policy_ref is derived from the resolved policy"}]
    else
      []
    end
  end

  defp collect_string_item({value, index}, {items, errors}, path) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {items, errors ++ [type_error("#{path}[#{index}]", "must be a non-empty string")]}
    else
      {[trimmed | items], errors}
    end
  end

  defp collect_string_item({_value, index}, {items, errors}, path) do
    {items, errors ++ [type_error("#{path}[#{index}]", "must be a non-empty string")]}
  end

  defp collect_indexed_string_item({value, index}, {items, errors}, path) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {items, errors ++ [type_error("#{path}[#{index}]", "must be a non-empty string")]}
    else
      {[{trimmed, index} | items], errors}
    end
  end

  defp collect_indexed_string_item({_value, index}, {items, errors}, path) do
    {items, errors ++ [type_error("#{path}[#{index}]", "must be a non-empty string")]}
  end

  defp reverse_items({items, errors}), do: {Enum.reverse(items), errors}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_keys(nested)} end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
