defmodule SymphonyElixir.Workflow.Manifest do
  @moduledoc false

  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workflow.ModuleRegistry

  @manifest_file "symphony.yml"
  @local_bindings_file ".symphony.local.yml"

  @type diagnostic :: %{path: String.t(), message: String.t()}
  @type manifest_error ::
          {:invalid_manifest, [diagnostic()]}
          | {:manifest_parse_error, term()}
          | {:missing_manifest_file, Path.t(), File.posix()}
  @type validation_error :: %{
          path: String.t(),
          message: String.t(),
          remediation: String.t()
        }
  @type validation_report :: %{
          errors: [validation_error()],
          modules: [String.t()],
          preset: String.t()
        }

  @spec load(Path.t()) :: {:ok, Workflow.loaded_workflow()} | {:error, manifest_error()}
  def load(path) when is_binary(path) do
    with {:ok, manifest} <- read(path) do
      case compile_diagnostics(manifest) do
        [] -> {:ok, compile(manifest)}
        diagnostics -> {:error, {:invalid_manifest, diagnostics}}
      end
    end
  end

  @spec read(Path.t()) :: {:ok, map()} | {:error, manifest_error()}
  def read(path_or_repo_root) when is_binary(path_or_repo_root) do
    path = manifest_source_path(path_or_repo_root)

    with {:ok, content} <- read_manifest(path),
         {:ok, decoded} <- decode_manifest(content) do
      normalize_manifest(decoded)
    end
  end

  @spec compile(map()) :: Workflow.loaded_workflow()
  def compile(manifest) when is_map(manifest) do
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

  @spec manifest_file_name() :: String.t()
  def manifest_file_name, do: @manifest_file

  @spec manifest_path(Path.t()) :: Path.t()
  def manifest_path(repo_root), do: Path.join(repo_root, @manifest_file)

  @spec default(Path.t(), keyword()) :: map()
  def default(repo_root, opts) do
    %{
      "version" => 1,
      "project" => %{
        "slug" => cli_detect_project_slug(repo_root),
        "name" => cli_detect_project_name(repo_root),
        "kind" => cli_detect_project_kind(repo_root),
        "app_kind" => cli_detect_app_kind(repo_root)
      },
      "workflow" => %{
        "preset" => Keyword.get(opts, :preset, "default"),
        "modules" => cli_explicit_modules(opts)
      },
      "docs" => %{"entrypoints" => cli_detect_doc_entrypoints(repo_root)},
      "validation" => %{"commands" => cli_detect_validation_commands(repo_root)},
      "vcs" => %{"mode" => cli_detect_vcs_mode(repo_root), "default_branch" => "main"},
      "delivery" => %{"pr_target" => "main"},
      "automation" => %{"posture" => "unattended", "profile" => "default", "completion_requirements" => []},
      "harness" => %{"codex_home" => nil},
      "bindings" => %{"local_file" => @local_bindings_file, "require_local" => false}
    }
  end

  @spec validate(Path.t(), map()) :: validation_report()
  def validate(repo_root, manifest) do
    errors =
      []
      |> validate_workflow(manifest)
      |> validate_docs(repo_root, manifest)
      |> validate_harness(repo_root, manifest)
      |> validate_bindings(repo_root, manifest)

    %{
      errors: Enum.reverse(errors),
      modules: manifest["workflow"]["modules"],
      preset: manifest["workflow"]["preset"]
    }
  end

  @spec validation_report_from_diagnostics([diagnostic()]) :: validation_report()
  def validation_report_from_diagnostics(diagnostics) do
    %{
      errors:
        Enum.map(diagnostics, fn %{path: path, message: message} ->
          %{path: path, message: message, remediation: "Fix the field in symphony.yml."}
        end),
      modules: [],
      preset: "default"
    }
  end

  @spec module_description(String.t()) :: String.t()
  def module_description(module_name), do: ModuleRegistry.module_description(module_name)

  defp manifest_source_path(path_or_repo_root) do
    if File.dir?(path_or_repo_root) do
      manifest_path(path_or_repo_root)
    else
      path_or_repo_root
    end
  end

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
    {version, version_errors} = integer_field(raw, "version", "version", default: 1)
    {project, project_errors} = normalize_project(Map.get(raw, "project"))
    {docs, docs_errors} = normalize_docs(Map.get(raw, "docs"))
    {vcs, vcs_errors} = normalize_vcs(Map.get(raw, "vcs"))
    {delivery, delivery_errors} = normalize_delivery(Map.get(raw, "delivery"), vcs)
    {validation, validation_errors} = normalize_validation(Map.get(raw, "validation"))
    {automation, automation_errors} = normalize_automation(Map.get(raw, "automation"))
    {workflow, workflow_errors} = normalize_workflow(Map.get(raw, "workflow"))
    {harness, harness_errors} = normalize_harness(Map.get(raw, "harness"))
    {bindings, bindings_errors} = normalize_bindings(Map.get(raw, "bindings"))
    {runtime, runtime_errors} = normalize_runtime(Map.get(raw, "runtime"))
    {prompt_template, prompt_errors} = string_field(raw, "prompt_template", "prompt_template", default: nil)

    errors =
      legacy_schema_errors(raw) ++
        version_errors ++
        project_errors ++
        docs_errors ++
        vcs_errors ++
        delivery_errors ++
        validation_errors ++
        automation_errors ++
        workflow_errors ++
        harness_errors ++
        bindings_errors ++
        runtime_errors ++
        prompt_errors

    if errors == [] do
      manifest =
        %{
          "version" => version,
          "project" => finalize_project(project),
          "docs" => docs,
          "vcs" => vcs,
          "delivery" => delivery,
          "validation" => validation,
          "automation" => automation,
          "workflow" => workflow,
          "harness" => harness,
          "bindings" => bindings,
          "runtime" => runtime
        }
        |> maybe_put("prompt_template", prompt_template)

      {:ok, manifest}
    else
      {:error, {:invalid_manifest, errors}}
    end
  end

  defp legacy_schema_errors(raw) do
    []
    |> reject_legacy_top_level(raw, "app", "is not supported; use project.app_kind")
    |> reject_legacy_top_level(raw, "autonomy", "is not supported; use automation")
    |> reject_legacy_nested(raw, ["docs", "entry_points"], "is not supported; use docs.entrypoints")
    |> reject_legacy_nested(raw, ["validation", "gates"], "is not supported; use validation.commands")
    |> reject_legacy_nested(raw, ["vcs", "kind"], "is not supported; use vcs.mode")
  end

  defp reject_legacy_top_level(errors, raw, key, message) do
    if Map.has_key?(raw, key), do: [%{path: key, message: message} | errors], else: errors
  end

  defp reject_legacy_nested(errors, raw, [section, key], message) do
    case Map.get(raw, section) do
      value when is_map(value) ->
        if Map.has_key?(value, key), do: [%{path: "#{section}.#{key}", message: message} | errors], else: errors

      _value ->
        errors
    end
  end

  defp normalize_project(nil) do
    {%{"slug" => nil, "name" => nil, "repository" => nil, "kind" => "generic", "app_kind" => "local", "facts" => %{}}, []}
  end

  defp normalize_project(raw) when is_map(raw) do
    {slug, slug_errors} = string_field(raw, "slug", "project.slug", default: nil)
    {name, name_errors} = string_field(raw, "name", "project.name", default: nil)
    {repository, repository_errors} = string_field(raw, "repository", "project.repository", default: nil)
    {kind, kind_errors} = string_field(raw, "kind", "project.kind", default: "generic")
    {app_kind, app_kind_errors} = string_field(raw, "app_kind", "project.app_kind", default: "local")
    {facts, facts_errors} = map_field(raw, "facts", "project.facts", default: %{})

    project =
      %{
        "slug" => slug,
        "name" => name,
        "kind" => kind,
        "app_kind" => app_kind,
        "facts" => facts
      }
      |> maybe_put("repository", repository)

    {project, slug_errors ++ name_errors ++ repository_errors ++ kind_errors ++ app_kind_errors ++ facts_errors}
  end

  defp normalize_project(_raw) do
    {%{"slug" => nil, "name" => nil, "repository" => nil, "kind" => "generic", "app_kind" => "local", "facts" => %{}}, [type_error("project", "must be a map")]}
  end

  defp finalize_project(project) do
    Map.put(project, "name", Map.get(project, "name") || Map.get(project, "slug"))
  end

  defp normalize_docs(nil), do: {%{"entrypoints" => []}, []}

  defp normalize_docs(raw) when is_map(raw) do
    {entrypoints, errors} = string_list_field(raw, "entrypoints", "docs.entrypoints", default: [])
    {%{"entrypoints" => entrypoints}, errors}
  end

  defp normalize_docs(_raw), do: {%{"entrypoints" => []}, [type_error("docs", "must be a map")]}

  defp normalize_vcs(nil), do: {%{"mode" => "git", "default_branch" => "main"}, []}

  defp normalize_vcs(raw) when is_map(raw) do
    {mode, mode_errors} = string_field(raw, "mode", "vcs.mode", default: "git")
    {default_branch, branch_errors} = string_field(raw, "default_branch", "vcs.default_branch", default: "main")
    {posture, posture_errors} = string_field(raw, "posture", "vcs.posture", default: nil)

    vcs =
      %{"mode" => mode, "default_branch" => default_branch}
      |> maybe_put("posture", posture)

    {vcs, mode_errors ++ branch_errors ++ posture_errors}
  end

  defp normalize_vcs(_raw), do: {%{"mode" => "git", "default_branch" => "main"}, [type_error("vcs", "must be a map")]}

  defp normalize_delivery(nil, vcs), do: {%{"pr_target" => vcs["default_branch"]}, []}

  defp normalize_delivery(raw, vcs) when is_map(raw) do
    {pr_target, errors} = string_field(raw, "pr_target", "delivery.pr_target", default: vcs["default_branch"])
    {%{"pr_target" => pr_target}, errors}
  end

  defp normalize_delivery(_raw, vcs), do: {%{"pr_target" => vcs["default_branch"]}, [type_error("delivery", "must be a map")]}

  defp normalize_validation(nil), do: {%{"commands" => []}, []}

  defp normalize_validation(raw) when is_map(raw) do
    {commands, errors} = commands_field(raw, "commands", "validation.commands")
    {%{"commands" => commands}, errors}
  end

  defp normalize_validation(_raw), do: {%{"commands" => []}, [type_error("validation", "must be a map")]}

  defp normalize_automation(nil) do
    {%{"posture" => "unattended", "profile" => "default", "completion_requirements" => []}, []}
  end

  defp normalize_automation(raw) when is_map(raw) do
    {posture, posture_errors} = string_field(raw, "posture", "automation.posture", default: "unattended")
    {profile, profile_errors} = string_field(raw, "profile", "automation.profile", default: "default")

    {completion_requirements, requirement_errors} =
      string_list_field(raw, "completion_requirements", "automation.completion_requirements", default: [])

    {review, review_errors} = map_field(raw, "review", "automation.review", default: nil)
    policy_ref_errors = unsupported_policy_ref(raw, "automation.policy_ref")

    automation =
      %{"posture" => posture, "profile" => profile, "completion_requirements" => completion_requirements}
      |> maybe_put("review", review)

    {automation, posture_errors ++ profile_errors ++ requirement_errors ++ review_errors ++ policy_ref_errors}
  end

  defp normalize_automation(_raw) do
    {%{"posture" => "unattended", "profile" => "default", "completion_requirements" => []}, [type_error("automation", "must be a map")]}
  end

  defp normalize_workflow(nil) do
    with {:ok, modules} <- ModuleRegistry.default_modules("default") do
      {%{"preset" => "default", "modules" => modules}, []}
    end
  end

  defp normalize_workflow(raw) when is_map(raw) do
    {preset, preset_errors} = string_field(raw, "preset", "workflow.preset", default: "default")
    {explicit_modules, module_requests, module_errors} = workflow_modules(raw)

    case ModuleRegistry.default_modules(preset) do
      {:ok, default_modules} ->
        modules = Enum.uniq(default_modules ++ explicit_modules)
        {%{"preset" => preset, "modules" => modules, "_module_requests" => module_requests}, preset_errors ++ module_errors}

      {:error, diagnostic} ->
        {%{"preset" => preset, "modules" => explicit_modules, "_module_requests" => module_requests}, preset_errors ++ module_errors ++ [diagnostic]}
    end
  end

  defp normalize_workflow(_raw), do: {%{"preset" => "default", "modules" => []}, [type_error("workflow", "must be a map")]}

  defp workflow_modules(raw) do
    case indexed_string_list_field(raw, "modules", "workflow.modules", default: []) do
      {modules, errors} ->
        module_names = Enum.map(modules, fn {name, _index} -> name end)
        module_requests = Enum.map(modules, fn {name, index} -> %{"name" => name, "index" => index} end)
        {module_names, module_requests, errors}
    end
  end

  defp normalize_harness(nil), do: {%{"codex_home" => nil}, []}

  defp normalize_harness(raw) when is_map(raw) do
    {codex_home, errors} = string_field(raw, "codex_home", "harness.codex_home", default: nil)
    {%{"codex_home" => codex_home}, errors}
  end

  defp normalize_harness(_raw), do: {%{"codex_home" => nil}, [type_error("harness", "must be a map")]}

  defp normalize_bindings(nil), do: {%{"local_file" => @local_bindings_file, "require_local" => false}, []}

  defp normalize_bindings(raw) when is_map(raw) do
    {local_file, local_file_errors} = string_field(raw, "local_file", "bindings.local_file", default: @local_bindings_file)
    {require_local, require_local_errors} = boolean_field(raw, "require_local", "bindings.require_local", default: false)
    {%{"local_file" => local_file, "require_local" => require_local}, local_file_errors ++ require_local_errors}
  end

  defp normalize_bindings(_raw), do: {%{"local_file" => @local_bindings_file, "require_local" => false}, [type_error("bindings", "must be a map")]}

  defp normalize_runtime(nil), do: {%{}, []}
  defp normalize_runtime(raw) when is_map(raw), do: {raw, []}
  defp normalize_runtime(_raw), do: {%{}, [type_error("runtime", "must be a map")]}

  defp compile_diagnostics(manifest) do
    workflow_module_diagnostics(manifest)
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
    public_manifest = public_manifest(manifest)
    project = manifest["project"]
    delivery = manifest["delivery"]
    validation = manifest["validation"]
    automation = manifest["automation"]

    %{
      "manifest" => public_manifest,
      "checks" => validation["commands"],
      "completion_requirements" => automation["completion_requirements"],
      "delivery" => delivery,
      "profiles" => manifest_profiles(manifest),
      "policy_metadata" => %{
        "profile" => automation["profile"],
        "project_id" => nil,
        "project_slug" => project["slug"],
        "source" => "symphony_manifest"
      }
    }
  end

  defp manifest_profiles(manifest) do
    profile = manifest["automation"]["profile"]
    policy = manifest_policy(manifest)

    %{"default" => policy}
    |> maybe_put(profile, policy)
  end

  defp manifest_policy(manifest) do
    %{
      "checks" => manifest["validation"]["commands"],
      "completion_requirements" => manifest["automation"]["completion_requirements"],
      "delivery" => manifest["delivery"],
      "manifest" => manifest_policy_inputs(manifest)
    }
    |> maybe_put("review", Map.get(manifest["automation"], "review"))
  end

  defp manifest_policy_inputs(manifest) do
    manifest
    |> public_manifest()
    |> Map.take(["project", "docs", "vcs", "delivery", "validation", "automation", "workflow", "harness", "bindings"])
  end

  defp public_manifest(manifest) do
    update_in(manifest, ["workflow"], fn workflow ->
      Map.delete(workflow, "_module_requests")
    end)
  end

  defp prompt_template(manifest) do
    {:ok, prompt} = ModuleRegistry.compile_manifest_prompt(manifest)
    prompt
  end

  defp validate_workflow(errors, manifest) do
    Enum.reduce(workflow_module_diagnostics(manifest), errors, fn diagnostic, acc ->
      validation_error(acc, diagnostic.path, diagnostic.message, "Use a supported workflow module.")
    end)
  end

  defp workflow_module_diagnostics(%{"workflow" => %{"modules" => modules} = workflow} = manifest) do
    requested_names = Enum.map(Map.get(workflow, "_module_requests", []), & &1["name"])

    default_diagnostics =
      modules
      |> Enum.reject(&(&1 in requested_names))
      |> Enum.with_index()
      |> Enum.flat_map(fn {name, index} -> ModuleRegistry.module_diagnostics(name, index, manifest) end)

    request_diagnostics =
      workflow
      |> Map.get("_module_requests", [])
      |> Enum.flat_map(fn %{"name" => name, "index" => index} ->
        ModuleRegistry.module_diagnostics(name, index, manifest)
      end)

    default_diagnostics ++ request_diagnostics
  end

  defp validate_docs(errors, repo_root, manifest) do
    manifest["docs"]["entrypoints"]
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {entrypoint, index}, acc ->
      cond do
        Path.type(entrypoint) == :absolute or not inside_repo?(repo_root, entrypoint) ->
          validation_error(acc, "docs.entrypoints[#{index}]", "must stay inside the repo", "Remove `..` path segments from doc entrypoints.")

        not File.regular?(Path.join(repo_root, entrypoint)) ->
          validation_error(acc, "docs.entrypoints[#{index}]", "missing #{inspect(entrypoint)}", "Create the file or remove it from `docs.entrypoints`.")

        true ->
          acc
      end
    end)
  end

  defp validate_harness(errors, repo_root, manifest) do
    case get_in(manifest, ["harness", "codex_home"]) do
      nil ->
        errors

      path ->
        expanded = Path.expand(path, repo_root)

        cond do
          not File.dir?(expanded) ->
            validation_error(errors, "harness.codex_home", "missing directory #{inspect(path)}", "Create #{path} or set `harness.codex_home: null`.")

          not File.regular?(Path.join(expanded, "AGENTS.md")) ->
            validation_error(errors, "harness.codex_home", "missing AGENTS.md in #{inspect(path)}", "Add a thin harness AGENTS.md.")

          true ->
            errors
        end
    end
  end

  defp validate_bindings(errors, repo_root, manifest) do
    local_file = get_in(manifest, ["bindings", "local_file"]) || @local_bindings_file
    require_local? = get_in(manifest, ["bindings", "require_local"]) || false
    path = Path.join(repo_root, local_file)

    cond do
      Path.type(local_file) == :absolute or not inside_repo?(repo_root, local_file) ->
        validation_error(errors, "bindings.local_file", "must stay inside the repo", "Remove `..` path segments from the local binding path.")

      require_local? and not File.regular?(path) ->
        validation_error(errors, "bindings.local_file", "missing required #{local_file}", "Create the file or set `bindings.require_local: false`.")

      true ->
        errors
    end
  end

  defp validation_error(errors, path, message, remediation) do
    [%{path: path, message: message, remediation: remediation} | errors]
  end

  defp cli_explicit_modules(opts) do
    opts
    |> Keyword.get(:modules, "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp cli_detect_project_slug(repo_root), do: repo_root |> Path.basename() |> String.downcase()
  defp cli_detect_project_name(repo_root), do: Path.basename(repo_root)

  defp cli_detect_project_kind(repo_root) do
    cond do
      File.regular?(Path.join(repo_root, "mix.exs")) or File.regular?(Path.join([repo_root, "elixir", "mix.exs"])) -> "elixir"
      File.regular?(Path.join(repo_root, "package.json")) -> "javascript"
      File.regular?(Path.join(repo_root, "pyproject.toml")) -> "python"
      true -> "generic"
    end
  end

  defp cli_detect_app_kind(repo_root) do
    if File.dir?(Path.join([repo_root, "lib", "symphony_elixir_web"])) or
         File.dir?(Path.join([repo_root, "elixir", "lib", "symphony_elixir_web"])) do
      "web"
    else
      "local"
    end
  end

  defp cli_detect_doc_entrypoints(repo_root) do
    ["AGENTS.md", "README.md", "SPEC.md", "elixir/AGENTS.md", "elixir/README.md"]
    |> Enum.filter(&File.regular?(Path.join(repo_root, &1)))
  end

  defp cli_detect_validation_commands(repo_root) do
    cond do
      File.regular?(Path.join(repo_root, "mix.exs")) -> [%{"name" => "test", "command" => "mix test"}]
      File.regular?(Path.join([repo_root, "elixir", "Makefile"])) -> [%{"name" => "all", "command" => "cd elixir && make all"}]
      File.regular?(Path.join(repo_root, "package.json")) -> [%{"name" => "test", "command" => "npm test"}]
      File.regular?(Path.join(repo_root, "pyproject.toml")) -> [%{"name" => "test", "command" => "pytest"}]
      true -> []
    end
  end

  defp cli_detect_vcs_mode(repo_root) do
    cond do
      File.dir?(Path.join(repo_root, ".jj")) -> "jj"
      File.dir?(Path.join(repo_root, ".git")) -> "git"
      true -> "none"
    end
  end

  defp commands_field(raw, key, path) do
    case Map.fetch(raw, key) do
      :error ->
        {[], []}

      {:ok, values} when is_list(values) ->
        values
        |> Enum.with_index()
        |> Enum.reduce({[], []}, &collect_command(&1, &2, path))
        |> reverse_items()

      {:ok, _value} ->
        {[], [type_error(path, "must be a list")]}
    end
  end

  defp normalize_command(raw, path) when is_map(raw) do
    {name, name_errors} = string_field(raw, "name", path <> ".name", required?: true)
    {command, command_errors} = string_field(raw, "command", path <> ".command", required?: true)

    if name_errors ++ command_errors == [] do
      {:ok, %{"name" => name, "command" => command}}
    else
      {:error, name_errors ++ command_errors}
    end
  end

  defp normalize_command(_raw, path), do: {:error, [type_error(path, "must be a map")]}

  defp collect_command({value, index}, {commands, errors}, path) do
    case normalize_command(value, "#{path}[#{index}]") do
      {:ok, command} -> {[command | commands], errors}
      {:error, command_errors} -> {commands, errors ++ command_errors}
    end
  end

  defp integer_field(raw, key, path, opts) do
    default = Keyword.fetch!(opts, :default)

    case Map.fetch(raw, key) do
      :error -> {default, []}
      {:ok, value} when is_integer(value) -> {value, []}
      {:ok, _value} -> {default, [type_error(path, "must be an integer")]}
    end
  end

  defp string_field(raw, key, path, opts) do
    default = Keyword.get(opts, :default)
    required? = Keyword.get(opts, :required?, false)

    case Map.fetch(raw, key) do
      :error ->
        missing_string_field(default, required?, path)

      {:ok, value} ->
        normalize_string_field_value(value, default, required?, path)
    end
  end

  defp missing_string_field(default, true, path), do: {default, [required(path)]}
  defp missing_string_field(default, false, _path), do: {default, []}

  defp normalize_string_field_value(nil, default, true, path), do: {default, [required(path)]}
  defp normalize_string_field_value(nil, default, false, _path), do: {default, []}

  defp normalize_string_field_value(value, default, required?, path) when is_binary(value) do
    value
    |> String.trim()
    |> normalized_string_value(default, required?, path)
  end

  defp normalize_string_field_value(_value, default, _required?, path), do: {default, [type_error(path, "must be a string")]}

  defp normalized_string_value("", default, true, path), do: {default, [required(path)]}
  defp normalized_string_value("", default, false, _path), do: {default, []}
  defp normalized_string_value(value, _default, _required?, _path), do: {value, []}

  defp boolean_field(raw, key, path, opts) do
    default = Keyword.fetch!(opts, :default)

    case Map.fetch(raw, key) do
      :error -> {default, []}
      {:ok, nil} -> {default, []}
      {:ok, value} when is_boolean(value) -> {value, []}
      {:ok, _value} -> {default, [type_error(path, "must be a boolean")]}
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

  defp unsupported_policy_ref(raw, path) do
    if Map.has_key?(raw, "policy_ref") do
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

  defp inside_repo?(repo_root, path) do
    expanded_repo = Path.expand(repo_root)
    expanded_path = Path.expand(path, expanded_repo)
    expanded_path == expanded_repo or String.starts_with?(expanded_path, expanded_repo <> "/")
  end

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
