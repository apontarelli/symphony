defmodule SymphonyElixir.QualityGate.Planner do
  @moduledoc """
  Builds a deterministic host-owned review plan from completion scope.
  """

  alias SymphonyElixir.Config.Schema.QualityGate
  alias SymphonyElixir.HandoffManifest

  defmodule Plan do
    @moduledoc "Host-owned quality-gate review plan."

    defstruct [
      :status,
      :workspace,
      changed_files: [],
      changed_surfaces: [],
      jobs: [],
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            status: :planned,
            workspace: Path.t() | nil,
            changed_files: [String.t()],
            changed_surfaces: [atom()],
            jobs: [map()],
            metadata: map()
          }
  end

  @type input :: %{
          optional(:completion) => map(),
          optional(:issue) => term(),
          optional(:policy) => map(),
          optional(:settings) => QualityGate.t(),
          optional(:workspace) => Path.t() | nil
        }

  @source_categories [
    :source_correctness,
    :test_quality,
    :docs_source_of_truth,
    :security_data_migration
  ]

  @category_profiles %{
    source_correctness: "source_reviewer",
    test_quality: "test_reviewer",
    scenario_qa: "runtime_qa",
    product_visual_review: "product_visual_review",
    docs_source_of_truth: "docs_reviewer",
    security_data_migration: "security_reviewer"
  }
  @surface_tokens %{
    "auth" => :auth,
    "billing" => :billing,
    "cli" => :cli,
    "database" => :database,
    "docs" => :docs,
    "external_side_effect" => :external_side_effect,
    "external_user_ui" => :external_user_ui,
    "migration" => :migration,
    "operator_workflow" => :operator_workflow,
    "product" => :product,
    "runtime" => :runtime,
    "security" => :security,
    "tests" => :tests,
    "visual" => :visual,
    "visual_design" => :visual_design,
    "web_ui" => :web_ui,
    "workflow" => :workflow
  }

  @spec plan(input()) :: Plan.t()
  def plan(input) when is_map(input) do
    completion = Map.get(input, :completion, %{})
    settings = Map.get(input, :settings)
    changed_files = changed_files(completion)
    changed_surfaces = changed_surfaces(completion)

    context = %{
      changed_files: changed_files,
      changed_surfaces: changed_surfaces,
      issue: Map.get(input, :issue),
      policy: Map.get(input, :policy, %{})
    }

    jobs =
      [
        maybe_job(:source_correctness, context, settings),
        maybe_job(:test_quality, context, settings),
        maybe_job(:scenario_qa, context, settings),
        maybe_job(:product_visual_review, context, settings),
        maybe_job(:docs_source_of_truth, context, settings),
        maybe_job(:security_data_migration, context, settings)
      ]
      |> Enum.reject(&is_nil/1)

    %Plan{
      status: :planned,
      workspace: Map.get(input, :workspace),
      changed_files: changed_files,
      changed_surfaces: changed_surfaces,
      jobs: jobs,
      metadata: %{
        source_max_concurrency: source_max_concurrency(settings),
        runtime_isolation: runtime_isolation(settings)
      }
    }
  end

  defp maybe_job(category, context, settings) do
    if required?(category, Map.put(context, :settings, settings)) do
      %{
        id: Atom.to_string(category),
        category: category,
        required?: true,
        execution_mode: execution_mode(category, settings),
        isolation: job_isolation(category, settings),
        execution_profile: Map.fetch!(@category_profiles, category),
        prompt: prompt_for(category, context),
        reason: reason_for(category, context)
      }
    end
  end

  defp required?(:source_correctness, %{changed_files: files, settings: settings}) do
    Enum.any?(files, &(configured_path?(&1, :source, settings) or source_file?(&1)))
  end

  defp required?(:test_quality, %{changed_files: files, changed_surfaces: surfaces, settings: settings}) do
    Enum.any?(files, &(configured_path?(&1, :tests, settings) or test_file?(&1))) or
      :tests in surfaces or
      Enum.any?(files, &behavior_file?/1)
  end

  defp required?(:scenario_qa, %{changed_files: files, changed_surfaces: surfaces}) do
    Enum.any?(surfaces, &(&1 in [:workflow, :runtime, :operator_workflow, :cli])) or
      Enum.any?(files, &scenario_file?/1)
  end

  defp required?(:product_visual_review, %{changed_files: files, changed_surfaces: surfaces}) do
    Enum.any?(surfaces, &(&1 in [:external_user_ui, :product, :visual, :visual_design, :web_ui])) or
      Enum.any?(files, &visual_file?/1)
  end

  defp required?(:docs_source_of_truth, %{changed_files: files, changed_surfaces: surfaces, policy: policy}) do
    :docs in surfaces or Enum.any?(files, &docs_or_source_of_truth_file?(&1, policy))
  end

  defp required?(:security_data_migration, %{changed_files: files, changed_surfaces: surfaces, issue: issue}) do
    Enum.any?(surfaces, &(&1 in [:auth, :billing, :database, :external_side_effect, :migration, :security])) or
      Enum.any?(files, &security_file?/1) or
      issue_label?(issue, "security")
  end

  defp execution_mode(category, settings) when category in @source_categories do
    if source_max_concurrency(settings) > 1, do: :parallel_source, else: :serialized_source
  end

  defp execution_mode(_category, settings) do
    case runtime_isolation(settings) do
      :blocked -> :blocked_runtime
      :isolated_workspace -> :isolated_runtime
      :serialized -> :serialized_runtime
    end
  end

  defp job_isolation(category, _settings) when category in @source_categories, do: :shared_read_only_workspace
  defp job_isolation(_category, settings), do: runtime_isolation(settings)

  defp source_max_concurrency(%QualityGate{source_max_concurrency: value}) when is_integer(value), do: value
  defp source_max_concurrency(_settings), do: 3

  defp runtime_isolation(%QualityGate{runtime_isolation: "isolated_workspace"}), do: :isolated_workspace
  defp runtime_isolation(%QualityGate{runtime_isolation: "blocked"}), do: :blocked
  defp runtime_isolation(_settings), do: :serialized

  defp configured_path?(path, category, %QualityGate{path_classification: rules}) when is_binary(path) and is_map(rules) do
    rules
    |> configured_patterns(category)
    |> Enum.any?(&glob_match?(&1, path))
  end

  defp configured_path?(_path, _category, _settings), do: false

  defp configured_patterns(rules, category) do
    category
    |> path_classification_keys()
    |> Enum.flat_map(fn key ->
      case Map.get(rules, key, Map.get(rules, to_string(key))) do
        patterns when is_list(patterns) -> patterns
        pattern when is_binary(pattern) -> [pattern]
        _patterns -> []
      end
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp path_classification_keys(:source), do: [:source, :sources]
  defp path_classification_keys(:tests), do: [:tests, :test]

  defp glob_match?(pattern, path) do
    pattern
    |> glob_regex()
    |> Regex.match?(path)
  end

  defp glob_regex(pattern) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*/", "(?:.*/)?")
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.compile!("^#{regex}$")
  end

  defp changed_files(completion) when is_map(completion) do
    case HandoffManifest.source(completion) do
      {:present, manifest} when is_map(manifest) ->
        manifest_changed_files(manifest)

      {:present, _manifest} ->
        []

      _source ->
        []
    end
    |> case do
      files when is_list(files) -> files
      _files -> []
    end
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp changed_files(_completion), do: []

  defp manifest_changed_files(manifest) when is_map(manifest) do
    fetch_value(manifest, :changed_files) ||
      fetch_value(manifest, :changedFiles) ||
      fetch_value(manifest, :files)
  end

  defp changed_surfaces(completion) when is_map(completion) do
    completion
    |> fetch_value(:changed_surfaces)
    |> case do
      surfaces when is_list(surfaces) -> surfaces
      _ -> []
    end
    |> Enum.flat_map(&surface_token/1)
    |> Enum.uniq()
  end

  defp changed_surfaces(_completion), do: []

  defp source_file?(path) do
    String.match?(path, ~r/(^|\/)(lib|bin|config|priv|src|packages\/[^\/]+\/src)\/.+\.(ex|exs|js|jsx|ts|tsx|css)$/)
  end

  defp behavior_file?(path) do
    source_file?(path) and not test_file?(path) and not visual_file?(path)
  end

  defp test_file?(path) do
    String.contains?(path, ["/test/", "/tests/"]) or String.starts_with?(path, ["test/", "tests/"]) or
      String.match?(path, ~r/(^|[._-])test\.(exs|js|jsx|ts|tsx)$/)
  end

  defp scenario_file?(path) do
    String.contains?(path, [
      "/cli",
      "/live/",
      "/router",
      "/endpoint",
      "/orchestrator",
      "/status_dashboard",
      "/workflow",
      "/workspace",
      "bin/"
    ])
  end

  defp visual_file?(path) do
    String.contains?(path, [
      "_web/live",
      "_web/components",
      "/priv/static/",
      "dashboard.css",
      "product_visual_review",
      ".css"
    ])
  end

  defp docs_or_source_of_truth_file?(path, policy) do
    base = Path.basename(path)

    path in policy_doc_entrypoints(policy) or
      String.starts_with?(path, ["docs/", "elixir/docs/", ".github/"]) or
      base in ["README.md", "PRODUCT.md", "SPEC.md", "AGENTS.md", "Makefile", "mise.toml", "Dockerfile"] or
      path == "symphony.yml" or
      String.ends_with?(path, ["/README.md", "/AGENTS.md"])
  end

  defp policy_doc_entrypoints(policy) when is_map(policy) do
    policy
    |> fetch_value(:manifest)
    |> case do
      manifest when is_map(manifest) -> fetch_value(manifest, :docs)
      _manifest -> nil
    end
    |> case do
      docs when is_map(docs) -> fetch_value(docs, :entrypoints)
      _docs -> []
    end
    |> case do
      entrypoints when is_list(entrypoints) -> entrypoints
      _entrypoints -> []
    end
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp policy_doc_entrypoints(_policy), do: []

  defp security_file?(path) do
    downcased = String.downcase(path)

    String.contains?(downcased, [
      "auth",
      "billing",
      "credential",
      "env",
      "migration",
      "payment",
      "permission",
      "secret",
      "security",
      "ssh",
      "token",
      "webhook"
    ])
  end

  defp issue_label?(%{labels: labels}, label) when is_list(labels) do
    Enum.any?(labels, &(String.downcase(to_string(&1)) == label))
  end

  defp issue_label?(_issue, _label), do: false

  defp surface_token(value) when is_atom(value), do: [value]

  defp surface_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> then(fn token ->
      case Map.fetch(@surface_tokens, token) do
        {:ok, surface} -> [surface]
        :error -> []
      end
    end)
  end

  defp surface_token(_value), do: []

  defp prompt_for(category, context) do
    """
    Run the #{category_label(category)} quality-gate review for this completed Symphony issue.

    Changed files:
    #{bullet_list(context.changed_files)}

    Return structured completion metadata with quality_gate_reviewer.status and quality_gate_reviewer.findings.
    Each finding must include severity, category, evidence, affected_files, reproducibility_notes, and recommended_disposition.
    """
  end

  defp reason_for(:source_correctness, _context), do: "Source files changed and need regression-oriented correctness review."
  defp reason_for(:test_quality, _context), do: "Tests changed or source behavior needs protection."
  defp reason_for(:scenario_qa, _context), do: "CLI, runtime, workflow, or operator journey changed."
  defp reason_for(:product_visual_review, _context), do: "Product-facing UI or visual surface changed."
  defp reason_for(:docs_source_of_truth, _context), do: "Docs, setup, workflow, or source-of-truth files changed."
  defp reason_for(:security_data_migration, _context), do: "Security, data, migration, credential, or external-side-effect surface changed."

  defp category_label(category), do: category |> Atom.to_string() |> String.replace("_", " ")

  defp bullet_list([]), do: "- None supplied."

  defp bullet_list(items) do
    Enum.map_join(items, "\n", &"- #{&1}")
  end

  defp fetch_value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
end
