defmodule SymphonyElixir.WorkflowModules.ProductVisualReview do
  @moduledoc """
  Product-facing visual QA routing and prompt rendering.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.WorkflowModules.ProductVisualReview.Config

  defmodule Config do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    @valid_project_kinds ~w(web mobile desktop)
    @valid_route_policies ~w(auto required recommended off)

    @default_changed_file_triggers [
      "**/app/**/*",
      "**/assets/**/*",
      "**/components/**/*",
      "**/lib/*_web/**/*",
      "**/pages/**/*",
      "**/priv/static/**/*",
      "**/screens/**/*",
      "**/src/**/*.css",
      "**/src/**/*.jsx",
      "**/src/**/*.scss",
      "**/src/**/*.tsx",
      "**/src/*.css",
      "**/src/*.jsx",
      "**/src/*.scss",
      "**/src/*.tsx",
      "**/styles/**/*",
      "**/ui/**/*",
      "app/**/*",
      "apps/**/*",
      "assets/**/*",
      "components/**/*",
      "lib/*_web/**/*",
      "pages/**/*",
      "priv/static/**/*",
      "public/**/*",
      "screens/**/*",
      "src/**/*.css",
      "src/**/*.jsx",
      "src/**/*.scss",
      "src/**/*.tsx",
      "src/*.css",
      "src/*.jsx",
      "src/*.scss",
      "src/*.tsx",
      "styles/**/*",
      "ui/**/*"
    ]

    @default_issue_label_triggers ~w(app design frontend mobile product ui ux web)
    @default_checks ~w(viewport_screenshots responsive_states interaction_smoke product_design_notes)
    @default_artifacts ~w(visual_qa_manifest viewport_screenshots interaction_notes product_design_notes)

    @type t :: %__MODULE__{
            enabled: boolean(),
            project_kind: String.t(),
            route_policy: String.t(),
            changed_file_triggers: [String.t()],
            issue_label_triggers: [String.t()],
            checks: [String.t()],
            artifacts: [String.t()]
          }

    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:project_kind, :string, default: "web")
      field(:route_policy, :string, default: "auto")
      field(:changed_file_triggers, {:array, :string}, default: @default_changed_file_triggers)
      field(:issue_label_triggers, {:array, :string}, default: @default_issue_label_triggers)
      field(:checks, {:array, :string}, default: @default_checks)
      field(:artifacts, {:array, :string}, default: @default_artifacts)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :project_kind,
          :route_policy,
          :changed_file_triggers,
          :issue_label_triggers,
          :checks,
          :artifacts
        ],
        empty_values: []
      )
      |> update_change(:project_kind, &normalize_token/1)
      |> update_change(:route_policy, &normalize_token/1)
      |> update_change(:changed_file_triggers, &normalize_string_list/1)
      |> update_change(:issue_label_triggers, &normalize_label_list/1)
      |> update_change(:checks, &normalize_string_list/1)
      |> update_change(:artifacts, &normalize_string_list/1)
      |> validate_inclusion(:project_kind, @valid_project_kinds)
      |> validate_inclusion(:route_policy, @valid_route_policies)
    end

    defp normalize_token(value) do
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()
    end

    defp normalize_label_list(values) do
      values
      |> normalize_string_list()
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
    end

    defp normalize_string_list(values) do
      values
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end
  end

  @type requirement :: :required | :recommended | :skip

  @type decision :: %{
          module: String.t(),
          requirement: requirement(),
          reason: String.t(),
          project_kind: String.t(),
          route_policy: String.t(),
          checks: [String.t()],
          artifacts: [String.t()],
          matched_files: [String.t()],
          matched_labels: [String.t()]
        }

  @type route_evidence :: %{
          module: String.t(),
          requirement: requirement(),
          status: atom(),
          reason: String.t(),
          required_action: String.t() | nil,
          project_kind: String.t(),
          route_policy: String.t(),
          checks: [map()],
          artifacts: [map()],
          expected_checks: [String.t()],
          expected_artifacts: [String.t()],
          matched_files: [String.t()],
          matched_labels: [String.t()]
        }

  @spec classify(Config.t(), [String.t()]) :: decision()
  def classify(%Config{} = config, changed_files) when is_list(changed_files) do
    classify(config, changed_files, nil)
  end

  @spec classify(Config.t(), [String.t()], Issue.t() | nil) :: decision()
  def classify(%Config{enabled: false} = config, changed_files, issue) when is_list(changed_files) do
    skip(config, changed_files, issue, "module disabled")
  end

  def classify(%Config{route_policy: "off"} = config, changed_files, issue) when is_list(changed_files) do
    skip(config, changed_files, issue, "route policy off")
  end

  def classify(%Config{route_policy: "required"} = config, changed_files, issue) when is_list(changed_files) do
    decision(:required, config, changed_files, issue, "route policy required")
  end

  def classify(%Config{route_policy: "recommended"} = config, changed_files, issue) when is_list(changed_files) do
    decision(:recommended, config, changed_files, issue, "route policy recommended")
  end

  def classify(%Config{} = config, changed_files, issue) when is_list(changed_files) do
    matched_files = matching_files(changed_files, config.changed_file_triggers)
    matched_labels = matching_labels(issue, config.issue_label_triggers)

    cond do
      matched_files != [] ->
        decision(:required, config, changed_files, issue, "changed files match product-facing routes")

      matched_labels != [] ->
        decision(:recommended, config, changed_files, issue, "issue labels indicate product-facing work")

      true ->
        skip(config, changed_files, issue, "no product-facing route trigger matched")
    end
  end

  @spec route_evidence(Config.t(), [String.t()], Issue.t() | nil, term()) :: route_evidence() | nil
  def route_evidence(%Config{enabled: false}, _changed_files, _issue, payload) do
    if payload_present?(payload), do: route_evidence(%Config{enabled: true, route_policy: "off"}, [], nil, payload)
  end

  def route_evidence(%Config{} = config, changed_files, issue, payload) when is_list(changed_files) do
    decision = classify(config, changed_files, issue)
    payload = normalize_payload(payload)
    status = evidence_status(decision.requirement, payload)
    reason = payload_text(payload, :reason) || payload_text(payload, :summary) || decision.reason

    %{
      module: "product_visual_review",
      requirement: decision.requirement,
      status: status,
      reason: reason,
      required_action: payload_text(payload, :required_action) || default_required_action(decision.requirement, status),
      project_kind: decision.project_kind,
      route_policy: decision.route_policy,
      checks: payload_list(payload, :checks),
      artifacts: payload_list(payload, :artifacts),
      expected_checks: decision.checks,
      expected_artifacts: decision.artifacts,
      matched_files: decision.matched_files,
      matched_labels: decision.matched_labels
    }
  end

  def route_evidence(%Config{} = config, _changed_files, issue, payload), do: route_evidence(config, [], issue, payload)

  @spec prompt_section(Config.t() | nil) :: String.t() | nil
  def prompt_section(nil), do: nil

  def prompt_section(%Config{enabled: false}), do: nil

  def prompt_section(%Config{route_policy: "off"}), do: nil

  def prompt_section(%Config{} = config) do
    """
    ## Workflow Module: product_visual_review

    Route id: `product_visual_review`
    Project kind: `#{config.project_kind}`
    Route policy: `#{config.route_policy}`

    Classification:
    - Before handoff, list changed files from the current diff and classify the work against this module.
    - Required when route policy is `required` or changed files match product-facing triggers.
    - Recommended when route policy is `recommended` or issue labels match product-facing triggers.
    - Skip visual QA when the diff is backend, infra, docs, or test-only and no product-facing trigger matched.

    Changed-file triggers:
    #{code_bullet_list(config.changed_file_triggers)}

    Product-facing issue labels:
    #{code_bullet_list(config.issue_label_triggers)}

    Checks:
    #{check_list(config)}

    Artifact evidence:
    #{code_bullet_list(config.artifacts)}

    Handoff:
    - Record whether `product_visual_review` was required, recommended, or skipped.
    - When run, tell Antonio which route/screen/state changed, which checks passed, where screenshots or media are attached, and what remains for human product/design review.
    - For `mobile` and `desktop` project kinds, keep the same check ids and replace Browser/Playwright capture with the native simulator/device or desktop-app capture path.
    """
    |> String.trim()
  end

  defp decision(requirement, config, changed_files, issue, reason) do
    %{
      module: "product_visual_review",
      requirement: requirement,
      reason: reason,
      project_kind: config.project_kind,
      route_policy: config.route_policy,
      checks: effective_checks(requirement, config),
      artifacts: effective_artifacts(requirement, config),
      matched_files: matching_files(changed_files, config.changed_file_triggers),
      matched_labels: matching_labels(issue, config.issue_label_triggers)
    }
  end

  defp skip(config, changed_files, issue, reason) do
    decision(:skip, config, changed_files, issue, reason)
  end

  @evidence_status_tokens %{
    "blocked" => :blocked,
    "clean" => :passed,
    "error" => :blocked,
    "failed" => :blocked,
    "failure" => :blocked,
    "fix_required" => :blocked,
    "missing" => :missing,
    "ok" => :passed,
    "pass" => :passed,
    "passed" => :passed,
    "skipped" => :skipped,
    "success" => :passed
  }

  defp evidence_status(:skip, _payload), do: :skipped

  defp evidence_status(:required, payload) do
    case payload_status(payload) do
      :passed -> if(payload_evidence?(payload), do: :passed, else: :blocked)
      _status -> :blocked
    end
  end

  defp evidence_status(:recommended, payload) do
    case payload_status(payload) do
      :passed -> if(payload_evidence?(payload), do: :passed, else: :missing)
      :blocked -> :blocked
      _status -> :missing
    end
  end

  defp payload_status(payload) when is_map(payload) do
    payload
    |> fetch_payload(:status, nil)
    |> normalize_status()
  end

  defp normalize_status(status) when is_atom(status) do
    status
    |> Atom.to_string()
    |> normalize_status()
  end

  defp normalize_status(status) when is_binary(status) do
    Map.get(@evidence_status_tokens, normalize_label(status))
  end

  defp normalize_status(_status), do: nil

  defp default_required_action(:required, status) when status in [:blocked, :missing] do
    "Run product visual QA or attach structured desktop/mobile evidence before handoff."
  end

  defp default_required_action(_requirement, _status), do: nil

  defp payload_present?(payload) when is_map(payload), do: map_size(payload) > 0
  defp payload_present?(_payload), do: false

  defp payload_evidence?(payload) when is_map(payload) do
    payload_list(payload, :checks) != [] or payload_list(payload, :artifacts) != []
  end

  defp payload_evidence?(_payload), do: false

  defp normalize_payload(payload) when is_map(payload), do: payload
  defp normalize_payload(_payload), do: %{}

  defp payload_text(payload, key) do
    payload
    |> fetch_payload(key, nil)
    |> optional_trimmed_string()
  end

  defp payload_list(payload, key) do
    case fetch_payload(payload, key, []) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp fetch_payload(payload, key, default) when is_map(payload) do
    Map.get(payload, key, Map.get(payload, to_string(key), default))
  end

  defp optional_trimmed_string(nil), do: nil

  defp optional_trimmed_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp effective_checks(:skip, _config), do: []
  defp effective_checks(_requirement, config), do: config.checks

  defp effective_artifacts(:skip, _config), do: []
  defp effective_artifacts(_requirement, config), do: config.artifacts

  defp matching_files(changed_files, triggers) when is_list(changed_files) and is_list(triggers) do
    changed_files
    |> Enum.map(&normalize_path/1)
    |> Enum.filter(fn file ->
      Enum.any?(triggers, &path_matches?(file, &1))
    end)
    |> Enum.uniq()
  end

  defp matching_files(_changed_files, _triggers), do: []

  defp matching_labels(%Issue{labels: labels}, triggers) when is_list(labels) and is_list(triggers) do
    normalized_triggers = MapSet.new(triggers, &normalize_label/1)

    labels
    |> Enum.map(&normalize_label/1)
    |> Enum.filter(&MapSet.member?(normalized_triggers, &1))
    |> Enum.uniq()
  end

  defp matching_labels(_issue, _triggers), do: []

  defp path_matches?(file, trigger) when is_binary(file) and is_binary(trigger) do
    trigger
    |> normalize_path()
    |> glob_regex()
    |> Regex.match?(file)
  end

  defp normalize_path(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
  end

  defp normalize_label(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp glob_regex(pattern) do
    pattern
    |> Regex.escape()
    |> String.replace("\\*\\*/", "(?:.*/)?")
    |> String.replace("\\*\\*", ".*")
    |> String.replace("\\*", "[^/]*")
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end

  defp check_list(%Config{project_kind: "web", checks: checks}) do
    checks
    |> Enum.map(&web_check_description/1)
    |> bullet_lines()
  end

  defp check_list(%Config{project_kind: project_kind, checks: checks}) do
    checks
    |> Enum.map(&portable_check_description(&1, project_kind))
    |> bullet_lines()
  end

  defp web_check_description("viewport_screenshots") do
    "`viewport_screenshots`: capture Browser/Playwright screenshots for the changed route at desktop and mobile widths."
  end

  defp web_check_description("responsive_states") do
    "`responsive_states`: verify the changed screen at narrow and wide breakpoints without overlap, clipping, or unusable controls."
  end

  defp web_check_description("interaction_smoke") do
    "`interaction_smoke`: exercise the changed interaction path once and record the expected result."
  end

  defp web_check_description("product_design_notes") do
    "`product_design_notes`: note visual/product concerns Antonio should inspect, including empty/loading/error states when relevant."
  end

  defp web_check_description(check), do: "`#{check}`"

  defp portable_check_description(check, project_kind) do
    "`#{check}`: run the #{project_kind} equivalent and record evidence in the same artifact schema."
  end

  defp code_bullet_list([]), do: "- none"

  defp code_bullet_list(items) do
    Enum.map_join(items, "\n", &"- `#{&1}`")
  end

  defp bullet_lines([]), do: "- none"

  defp bullet_lines(items) do
    Enum.map_join(items, "\n", &"- #{&1}")
  end
end
