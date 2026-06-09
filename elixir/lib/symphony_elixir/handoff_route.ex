defmodule SymphonyElixir.HandoffRoute do
  @moduledoc """
  Classifies completed Symphony work into a structured handoff route.

  The classifier is intentionally conservative: it can identify auto-land
  eligibility, but v1 still targets Human Review unless the selected route is
  Rework.
  """

  alias SymphonyElixir.HandoffRoute.PublishPreflightEvidence

  defmodule Evidence do
    @moduledoc "Supporting fact used to select a handoff route."

    defstruct [:kind, :status, :summary, metadata: %{}]

    @type t :: %__MODULE__{
            kind: atom(),
            status: atom(),
            summary: String.t(),
            metadata: map()
          }
  end

  defmodule Option do
    @moduledoc "Concrete operator option for decision-needed handoffs."

    defstruct [:id, :label, :description]

    @type t :: %__MODULE__{
            id: String.t(),
            label: String.t(),
            description: String.t()
          }
  end

  defmodule Artifact do
    @moduledoc "Screenshot, video, or other route-relevant review artifact."

    defstruct [:kind, :label, :url]

    @type t :: %__MODULE__{
            kind: atom(),
            label: String.t(),
            url: String.t()
          }
  end

  defmodule Decision do
    @moduledoc "Structured route decision persisted with run outcomes."

    defstruct [
      :route,
      :target_state,
      :summary,
      :recommendation,
      options: [],
      evidence: [],
      artifacts: [],
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            route: atom(),
            target_state: String.t(),
            summary: String.t(),
            recommendation: String.t(),
            options: [Option.t()],
            evidence: [Evidence.t()],
            artifacts: [Artifact.t()],
            metadata: map()
          }
  end

  @risky_surfaces MapSet.new([
                    :api,
                    :auth,
                    :backend,
                    :billing,
                    :config,
                    :database,
                    :domain,
                    :elixir,
                    :migration,
                    :external_user_ui,
                    :product,
                    :visual,
                    :visual_design,
                    :web_ui,
                    :workflow
                  ])

  @product_surfaces MapSet.new([:external_user_ui, :product, :visual, :visual_design, :web_ui])
  @artifact_review_kinds MapSet.new([:screenshot, :video, :recording])
  @passed_statuses MapSet.new([:passed, :pass, :success, :clean, :ok])
  @failed_statuses MapSet.new([:failed, :failure, :error, :fix_required, :blocked])
  @decision_statuses MapSet.new([:decision_needed, :needs_decision, :needs_input])
  @default_force_human_review_labels ~w(force-human-review human-review manual-review no-auto-land)
  @known_keys %{
    "artifacts" => :artifacts,
    "auto_land" => :auto_land,
    "auto_land_enabled" => :auto_land_enabled,
    "blocker" => :blocker,
    "blocked_state" => :blocked_state,
    "changed_surfaces" => :changed_surfaces,
    "checks" => :checks,
    "criticality" => :criticality,
    "decision" => :decision,
    "description" => :description,
    "deployment_coupling" => :deployment_coupling,
    "dry_run" => :dry_run,
    "enabled" => :enabled,
    "failure_state" => :failure_state,
    "force_human_review_labels" => :force_human_review_labels,
    "findings" => :findings,
    "id" => :id,
    "issue_labels" => :issue_labels,
    "kind" => :kind,
    "label" => :label,
    "labels" => :labels,
    "name" => :name,
    "options" => :options,
    "policy" => :policy,
    "posture" => :posture,
    "pr_target" => :pr_target,
    "project" => :project,
    "question" => :question,
    "reason" => :reason,
    "recommendation" => :recommendation,
    "require_human_review" => :require_human_review,
    "required_action" => :required_action,
    "required_checks" => :required_checks,
    "requires_human_review" => :requires_human_review,
    "review" => :review,
    "status" => :status,
    "summary" => :summary,
    "url" => :url
  }
  @status_tokens %{
    "blocked" => :blocked,
    "clean" => :clean,
    "decision_needed" => :decision_needed,
    "error" => :error,
    "failed" => :failed,
    "failure" => :failure,
    "fix_required" => :fix_required,
    "needs_decision" => :needs_decision,
    "needs_input" => :needs_input,
    "ok" => :ok,
    "pass" => :pass,
    "passed" => :passed,
    "success" => :success,
    "unknown" => :unknown
  }
  @surface_tokens %{
    "api" => :api,
    "auth" => :auth,
    "backend" => :backend,
    "billing" => :billing,
    "config" => :config,
    "database" => :database,
    "docs" => :docs,
    "domain" => :domain,
    "elixir" => :elixir,
    "external_user_ui" => :external_user_ui,
    "migration" => :migration,
    "product" => :product,
    "tests" => :tests,
    "visual" => :visual,
    "visual_design" => :visual_design,
    "web_ui" => :web_ui,
    "workflow" => :workflow
  }
  @artifact_kind_tokens %{
    "artifact" => :artifact,
    "recording" => :recording,
    "screenshot" => :screenshot,
    "video" => :video
  }

  @type input :: map()

  @spec classify(input()) :: Decision.t()
  def classify(input) when is_map(input) do
    context = normalize_input(input)

    cond do
      context.blocker ->
        blocked_decision(context)

      failed_route_gate?(context) ->
        rework_decision(context)

      pre_review_route_needed?(context) ->
        pre_review_route_decision(context)

      product_visual_review?(context) ->
        product_visual_review_decision(context)

      risky?(context) ->
        human_review_decision(context)

      auto_land_candidate?(context) ->
        auto_land_decision(context)

      true ->
        human_review_decision(context)
    end
  end

  @spec to_map(Decision.t()) :: map()
  def to_map(%Decision{} = decision) do
    %{
      route: Atom.to_string(decision.route),
      target_state: decision.target_state,
      summary: decision.summary,
      recommendation: decision.recommendation,
      options: Enum.map(decision.options, &option_to_map/1),
      evidence: Enum.map(decision.evidence, &evidence_to_map/1),
      artifacts: Enum.map(decision.artifacts, &artifact_to_map/1),
      metadata: decision.metadata
    }
  end

  @spec format_comment(Decision.t()) :: String.t()
  def format_comment(%Decision{} = decision) do
    [
      "### Handoff Route",
      "",
      "- Route: `#{decision.route}`",
      "- Target Linear state: `#{decision.target_state}`",
      "- Summary: #{decision.summary}",
      "- Recommended: #{decision.recommendation}",
      "",
      "#### Options",
      "",
      option_lines(decision.options),
      "",
      "#### Evidence",
      "",
      evidence_lines(decision.evidence),
      "",
      "#### Artifacts",
      "",
      artifact_lines(decision.artifacts)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp normalize_input(input) do
    checks = fetch(input, :checks, []) |> normalize_checks()
    review = fetch(input, :review, %{}) |> normalize_review()
    changed_surfaces = fetch(input, :changed_surfaces, []) |> normalize_surfaces()
    policy = fetch(input, :policy, %{}) |> normalize_map()
    artifacts = fetch(input, :artifacts, []) |> normalize_artifacts()
    decision = fetch(input, :decision, %{}) |> normalize_decision()
    publish_preflight = fetch(input, :publish_preflight, nil) |> PublishPreflightEvidence.normalize()
    blocker = normalize_blocker(fetch(input, :blocker, nil)) || PublishPreflightEvidence.blocker(publish_preflight)
    labels = fetch(input, :labels, fetch(input, :issue_labels, [])) |> normalize_label_list()

    evidence_context = %{
      checks: checks,
      review: review,
      changed_surfaces: changed_surfaces,
      policy: policy,
      artifacts: artifacts,
      blocker: blocker,
      decision: decision,
      labels: labels,
      publish_preflight: publish_preflight
    }

    %{
      checks: checks,
      review: review,
      changed_surfaces: changed_surfaces,
      policy: policy,
      artifacts: artifacts,
      decision: decision,
      publish_preflight: publish_preflight,
      blocker: blocker,
      labels: labels,
      evidence: base_evidence(evidence_context)
    }
  end

  defp blocked_decision(context) do
    %Decision{
      route: :blocked,
      target_state: "Human Review",
      summary: "Blocked by missing required access or input.",
      recommendation:
        context.blocker.required_action ||
          "Resolve the blocker before Symphony can complete validation.",
      evidence: context.evidence,
      artifacts: context.artifacts
    }
  end

  defp missing_auto_land_evidence_decision(context) do
    %Decision{
      route: :blocked,
      target_state: auto_land_blocked_state(context.policy),
      summary: "Missing required auto-land evidence.",
      recommendation: "Record the missing evidence before final route classification.",
      evidence: context.evidence,
      artifacts: context.artifacts
    }
  end

  defp rework_decision(context) do
    %Decision{
      route: :rework,
      target_state: "Rework",
      summary: "Rework required before handoff.",
      recommendation: "Address failed gates or reviewer feedback, then rerun validation.",
      evidence: context.evidence,
      artifacts: context.artifacts
    }
  end

  defp decision_needed_decision(context) do
    %Decision{
      route: :decision_needed,
      target_state: "Human Review",
      summary: context.decision.question || "Operator decision required before completion.",
      recommendation: context.decision.recommendation || "Choose one of the listed options.",
      options: context.decision.options,
      evidence: context.evidence,
      artifacts: context.artifacts
    }
  end

  defp product_visual_review_decision(context) do
    %Decision{
      route: :product_visual_review,
      target_state: "Human Review",
      summary: "Product or visual review required for changed surfaces.",
      recommendation: "Review the attached artifacts and approve or request Rework.",
      evidence: context.evidence,
      artifacts: context.artifacts
    }
  end

  defp human_review_decision(context) do
    %Decision{
      route: :human_review,
      target_state: "Human Review",
      summary: "Human review required for risky or policy-protected work.",
      recommendation: "Review evidence, then approve for Merging or request Rework.",
      evidence: context.evidence,
      artifacts: context.artifacts
    }
  end

  defp auto_land_decision(context) do
    %Decision{
      route: :auto_land,
      target_state: "Human Review",
      summary: "Auto-land eligible, held for Human Review until the land executor exists.",
      recommendation: "Auto-land eligible by checks, review, changed surfaces, and policy.",
      evidence: context.evidence,
      artifacts: context.artifacts,
      metadata: %{auto_land_executor: "not_implemented"}
    }
  end

  defp failed_route_gate?(context) do
    Enum.any?(context.checks, &(Map.get(&1, :status) in @failed_statuses)) or
      Map.get(context.review, :status) == :fix_required or
      decision_options_missing?(context.review, context.decision) or
      decision_options_malformed?(context.decision) or
      decision_recommendation_missing?(context.review, context.decision)
  end

  defp pre_review_route_needed?(context) do
    auto_land_force_human_review_label?(context) or
      missing_auto_land_evidence?(context) or
      decision_needed?(context)
  end

  defp pre_review_route_decision(context) do
    cond do
      auto_land_force_human_review_label?(context) ->
        human_review_decision(context)

      missing_auto_land_evidence?(context) ->
        missing_auto_land_evidence_decision(context)

      true ->
        decision_needed_decision(context)
    end
  end

  defp decision_needed?(context) do
    Map.get(context.review, :status) in @decision_statuses or context.decision.options != []
  end

  defp decision_required?(review, decision) do
    Map.get(review, :status) in @decision_statuses or
      context_decision_present?(decision)
  end

  defp context_decision_present?(decision) do
    decision.options != [] or not is_nil(decision.question) or not is_nil(decision.recommendation)
  end

  defp decision_options_missing?(review, decision) do
    decision_required?(review, decision) and decision.options == []
  end

  defp decision_recommendation_missing?(review, decision) do
    decision_required?(review, decision) and is_nil(decision.recommendation)
  end

  defp decision_options_malformed?(decision) do
    Map.get(decision, :invalid_options?, false) == true
  end

  defp product_visual_review?(context) do
    Enum.any?(context.changed_surfaces, &MapSet.member?(@product_surfaces, &1)) or
      Enum.any?(context.artifacts, &MapSet.member?(@artifact_review_kinds, &1.kind))
  end

  defp risky?(context) do
    Enum.any?(context.changed_surfaces, &MapSet.member?(@risky_surfaces, &1)) or
      policy_requires_human_review?(context.policy)
  end

  defp auto_land_candidate?(context) do
    context.checks != [] and
      auto_land_enabled?(context.policy) and
      not missing_auto_land_evidence?(context) and
      Enum.all?(context.checks, &(Map.get(&1, :status) in @passed_statuses)) and
      Map.get(context.review, :status) in @passed_statuses and
      not risky?(context)
  end

  defp policy_requires_human_review?(policy) do
    fetch(policy, :require_human_review, false) == true or
      fetch(policy, :requires_human_review, false) == true
  end

  defp auto_land_force_human_review_label?(context) do
    not is_nil(matched_auto_land_force_human_review_label(context))
  end

  defp auto_land_enabled?(policy) do
    auto_land = fetch(policy, :auto_land, %{}) |> normalize_map()

    fetch(policy, :auto_land_enabled, false) == true or
      fetch(auto_land, :enabled, false) == true or
      (manifest_auto_land_policy?(auto_land) and fetch(auto_land, :posture, "permissive") != "off")
  end

  defp base_evidence(context) do
    []
    |> Kernel.++(blocker_evidence(context.blocker))
    |> Kernel.++(PublishPreflightEvidence.evidence(context.publish_preflight))
    |> Kernel.++(check_evidence(context.checks))
    |> Kernel.++(review_evidence(context.review))
    |> Kernel.++(route_gate_evidence(context.review, context.decision))
    |> Kernel.++(surface_evidence(context.changed_surfaces))
    |> Kernel.++(policy_evidence(context.policy))
    |> Kernel.++(auto_land_force_label_evidence(%{labels: context.labels, policy: context.policy}))
    |> Kernel.++(auto_land_evidence(%{checks: context.checks, policy: context.policy}))
    |> Kernel.++(artifact_evidence(context.artifacts))
  end

  defp blocker_evidence(nil), do: []

  defp blocker_evidence(blocker) do
    [
      %Evidence{
        kind: :blocker,
        status: :blocked,
        summary: blocker.reason,
        metadata: %{required_action: blocker.required_action}
      }
    ]
  end

  defp check_evidence([]) do
    [
      %Evidence{
        kind: :check,
        status: :missing,
        summary: "No check evidence supplied."
      }
    ]
  end

  defp check_evidence(checks) do
    if Enum.all?(checks, &(Map.get(&1, :status) in @passed_statuses)) do
      [
        %Evidence{
          kind: :check,
          status: :passed,
          summary: "All checks passed: #{Enum.map_join(checks, ", ", & &1.name)}"
        }
      ]
    else
      Enum.map(checks, fn check ->
        %Evidence{
          kind: :check,
          status: Map.get(check, :status),
          summary: check.summary || "#{check.name} #{check.status}"
        }
      end)
    end
  end

  defp review_evidence(%{status: :unknown}), do: []

  defp review_evidence(review) do
    [
      %Evidence{
        kind: :review,
        status: review.status,
        summary: review.summary || review_summary(review)
      }
    ]
  end

  defp route_gate_evidence(review, decision) do
    []
    |> maybe_add_evidence(
      decision_options_missing?(review, decision),
      %Evidence{
        kind: :route_gate,
        status: :failed,
        summary: "Decision-needed handoff is missing concrete options."
      }
    )
    |> maybe_add_evidence(
      decision_recommendation_missing?(review, decision),
      %Evidence{
        kind: :route_gate,
        status: :failed,
        summary: "Decision-needed handoff is missing a concrete recommendation."
      }
    )
    |> maybe_add_evidence(
      decision_options_malformed?(decision),
      %Evidence{
        kind: :route_gate,
        status: :failed,
        summary: "Decision-needed handoff contains malformed options."
      }
    )
  end

  defp maybe_add_evidence(evidence, true, item), do: evidence ++ [item]
  defp maybe_add_evidence(evidence, false, _item), do: evidence

  defp surface_evidence([]), do: []

  defp surface_evidence(surfaces) do
    status =
      if Enum.any?(surfaces, &MapSet.member?(@risky_surfaces, &1)) do
        :risky
      else
        :low_risk
      end

    [
      %Evidence{
        kind: :changed_surface,
        status: status,
        summary: "Changed surfaces are #{status_label(status)}: #{Enum.map_join(surfaces, ", ", &Atom.to_string/1)}"
      }
    ]
  end

  defp policy_evidence(policy) when policy == %{}, do: []

  defp policy_evidence(policy) do
    [
      %Evidence{
        kind: :policy,
        status: :applied,
        summary: "Project policy applied.",
        metadata: policy
      }
    ]
  end

  defp auto_land_force_label_evidence(context) do
    case matched_auto_land_force_human_review_label(context) do
      nil ->
        []

      label ->
        [
          %Evidence{
            kind: :policy,
            status: :applied,
            summary: "Auto-land forced to human review by issue label: #{label}"
          }
        ]
    end
  end

  defp auto_land_evidence(context) do
    required_checks = auto_land_required_checks(context)

    cond do
      required_checks == [] ->
        []

      missing_auto_land_evidence?(context) ->
        [
          %Evidence{
            kind: :auto_land,
            status: :missing,
            summary: "Missing required auto-land evidence: #{Enum.join(missing_auto_land_checks(context), ", ")}"
          }
        ]

      true ->
        [
          %Evidence{
            kind: :auto_land,
            status: :passed,
            summary: "Required auto-land evidence is present: #{Enum.join(required_checks, ", ")}"
          }
        ]
    end
  end

  defp missing_auto_land_evidence?(context) do
    missing_auto_land_checks(context) != []
  end

  defp missing_auto_land_checks(context) do
    required_checks = auto_land_required_checks(context)
    passed_checks = auto_land_passed_checks(context.checks)
    required_checks -- passed_checks
  end

  defp auto_land_passed_checks(checks) do
    checks
    |> Enum.filter(&(Map.get(&1, :status) in @passed_statuses))
    |> Enum.map(& &1.name)
  end

  defp auto_land_required_checks(%{policy: policy}) do
    auto_land = fetch(policy, :auto_land, %{}) |> normalize_map()

    if manifest_auto_land_policy?(auto_land) and fetch(auto_land, :posture, "permissive") != "off" do
      policy
      |> default_auto_land_required_checks(auto_land)
      |> Kernel.++(fetch(auto_land, :required_checks, []) |> normalize_string_list())
      |> Enum.uniq()
    else
      []
    end
  end

  defp default_auto_land_required_checks(policy, auto_land) do
    if strict_auto_land_policy?(policy, auto_land) do
      ~w(tests quality_gates automated_review route_classification sync recovery)
    else
      ~w(tests quality_gates automated_review route_classification sync)
    end
  end

  defp strict_auto_land_policy?(policy, auto_land) do
    project = fetch(policy, :project, %{}) |> normalize_map()

    fetch(auto_land, :posture, nil) == "strict" or
      fetch(project, :criticality, nil) == "production" or
      fetch(project, :deployment_coupling, nil) in ["production", "production_web"]
  end

  defp manifest_auto_land_policy?(auto_land) do
    Enum.any?([:posture, :dry_run, :required_checks, :blocked_state, :failure_state], &Map.has_key?(auto_land, &1))
  end

  defp matched_auto_land_force_human_review_label(%{labels: labels, policy: policy}) do
    auto_land = fetch(policy, :auto_land, %{}) |> normalize_map()

    if manifest_auto_land_policy?(auto_land) do
      label_set = MapSet.new(labels)

      auto_land
      |> fetch(:force_human_review_labels, @default_force_human_review_labels)
      |> normalize_label_list()
      |> Enum.find(&MapSet.member?(label_set, &1))
    end
  end

  defp auto_land_blocked_state(policy) do
    policy
    |> fetch(:auto_land, %{})
    |> normalize_map()
    |> fetch(:blocked_state, "Human Review")
  end

  defp artifact_evidence([]), do: []

  defp artifact_evidence(artifacts) do
    [
      %Evidence{
        kind: :artifact,
        status: :available,
        summary: "Review artifacts available: #{Enum.map_join(artifacts, ", ", & &1.label)}"
      }
    ]
  end

  defp normalize_checks(checks) when is_list(checks) do
    Enum.map(checks, fn check ->
      check = normalize_map(check)

      %{
        name: fetch(check, :name, "unnamed check") |> to_string(),
        status: fetch(check, :status, :unknown) |> normalize_status(),
        summary: optional_string(fetch(check, :summary, nil))
      }
    end)
  end

  defp normalize_checks(_checks), do: []

  defp normalize_review(review) when is_map(review) do
    review = normalize_map(review)
    findings = fetch(review, :findings, [])

    %{
      status: fetch(review, :status, :unknown) |> normalize_status(),
      summary: optional_string(fetch(review, :summary, nil)),
      findings: if(is_list(findings), do: findings, else: [])
    }
  end

  defp normalize_review(_review), do: %{status: :unknown, summary: nil, findings: []}

  defp normalize_surfaces(surfaces) when is_list(surfaces) do
    Enum.map(surfaces, &normalize_surface/1)
  end

  defp normalize_surfaces(_surfaces), do: []

  defp normalize_artifacts(artifacts) when is_list(artifacts) do
    Enum.map(artifacts, fn artifact ->
      artifact = normalize_map(artifact)

      %Artifact{
        kind: fetch(artifact, :kind, :artifact) |> normalize_artifact_kind(),
        label: fetch(artifact, :label, "artifact") |> to_string(),
        url: fetch(artifact, :url, "") |> to_string()
      }
    end)
  end

  defp normalize_artifacts(_artifacts), do: []

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&optional_trimmed_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_values), do: []

  defp normalize_label_list(values) do
    values
    |> normalize_string_list()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp normalize_decision(decision) when is_map(decision) do
    decision = normalize_map(decision)
    {options, invalid_options?} = fetch(decision, :options, []) |> normalize_options()

    %{
      question: fetch(decision, :question, nil) |> optional_trimmed_string(),
      recommendation: fetch(decision, :recommendation, nil) |> optional_trimmed_string(),
      options: options,
      invalid_options?: invalid_options?
    }
  end

  defp normalize_decision(_decision),
    do: %{question: nil, recommendation: nil, options: [], invalid_options?: false}

  defp normalize_options(options) when is_list(options) do
    {options, invalid_options?} =
      Enum.reduce(options, {[], false}, fn option, {options, invalid_options?} ->
        option = normalize_map(option)
        id = fetch(option, :id, nil) |> optional_trimmed_string()
        label = fetch(option, :label, nil) |> optional_trimmed_string()
        description = fetch(option, :description, nil) |> optional_trimmed_string()

        if id && label && description do
          {[%Option{id: id, label: label, description: description} | options], invalid_options?}
        else
          {options, true}
        end
      end)

    {Enum.reverse(options), invalid_options?}
  end

  defp normalize_options(_options), do: {[], false}

  defp normalize_blocker(nil), do: nil

  defp normalize_blocker(blocker) when is_map(blocker) do
    blocker = normalize_map(blocker)

    %{
      reason: fetch(blocker, :reason, "Blocked by missing required access or input.") |> to_string(),
      required_action: optional_string(fetch(blocker, :required_action, nil))
    }
  end

  defp normalize_blocker(blocker), do: %{reason: to_string(blocker), required_action: nil}

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_map(_map), do: %{}

  defp fetch(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp normalize_status(status), do: normalize_token(status, @status_tokens, :unknown)
  defp normalize_surface(surface), do: normalize_token(surface, @surface_tokens, :other)
  defp normalize_artifact_kind(kind), do: normalize_token(kind, @artifact_kind_tokens, :artifact)

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: Map.get(@known_keys, normalize_string_token(key), key)
  defp normalize_key(key), do: key

  defp normalize_token(value, _tokens, _default) when is_atom(value), do: value

  defp normalize_token(value, tokens, default) when is_binary(value) do
    Map.get(tokens, normalize_string_token(value), default)
  end

  defp normalize_token(_value, _tokens, default), do: default

  defp normalize_string_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
  end

  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)

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

  defp review_summary(%{status: :clean}), do: "Review output is clean."
  defp review_summary(%{status: :fix_required, findings: findings}), do: "Review requires fixes: #{Enum.join(findings, "; ")}"
  defp review_summary(%{status: :decision_needed}), do: "Review requires an operator decision."
  defp review_summary(review), do: "Review status: #{review.status}"

  defp status_label(:low_risk), do: "low-risk"
  defp status_label(status), do: Atom.to_string(status)

  defp option_lines([]), do: ["- None."]

  defp option_lines(options) do
    Enum.map(options, fn option ->
      "- `#{option.id}` #{option.label}: #{option.description}"
    end)
  end

  defp evidence_lines([]), do: ["- None."]

  defp evidence_lines(evidence) do
    Enum.map(evidence, fn item ->
      "- #{item.kind}/#{item.status}: #{item.summary}"
    end)
  end

  defp artifact_lines([]), do: ["- None."]

  defp artifact_lines(artifacts) do
    Enum.map(artifacts, fn artifact ->
      "- #{artifact.kind} #{artifact.label}: #{artifact.url}"
    end)
  end

  defp option_to_map(%Option{} = option) do
    %{id: option.id, label: option.label, description: option.description}
  end

  defp evidence_to_map(%Evidence{} = evidence) do
    %{
      kind: Atom.to_string(evidence.kind),
      status: Atom.to_string(evidence.status),
      summary: evidence.summary,
      metadata: evidence.metadata
    }
  end

  defp artifact_to_map(%Artifact{} = artifact) do
    %{kind: Atom.to_string(artifact.kind), label: artifact.label, url: artifact.url}
  end
end
