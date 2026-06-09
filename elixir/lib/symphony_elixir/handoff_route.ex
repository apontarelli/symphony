defmodule SymphonyElixir.HandoffRoute do
  @moduledoc """
  Classifies completed Symphony work into a structured handoff route.

  The classifier is intentionally conservative: dry-run auto-land still targets
  Human Review, while explicitly opted-in real auto-land moves qualified work to
  the existing Merging land flow.
  """

  alias SymphonyElixir.HandoffRoute.{AutoLandPolicy, PublishHandoffEvidence, PublishPreflightEvidence}

  @manifest_check_name "change_manifest"
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
    "force_human_review_labels" => :force_human_review_labels,
    "findings" => :findings,
    "checked" => :checked,
    "checked_at" => :checked_at,
    "id" => :id,
    "inline_review_comments" => :inline_review_comments,
    "issue_labels" => :issue_labels,
    "kind" => :kind,
    "label" => :label,
    "labels" => :labels,
    "metadata" => :metadata,
    "name" => :name,
    "options" => :options,
    "policy" => :policy,
    "posture" => :posture,
    "pr_feedback" => :pr_feedback,
    "pr_number" => :pr_number,
    "pr_target" => :pr_target,
    "project" => :project,
    "publish_handoff" => :publish_handoff,
    "question" => :question,
    "reason" => :reason,
    "recommendation" => :recommendation,
    "require_human_review" => :require_human_review,
    "required_action" => :required_action,
    "required_checks" => :required_checks,
    "requires_human_review" => :requires_human_review,
    "review" => :review,
    "review_summaries" => :review_summaries,
    "source" => :source,
    "status" => :status,
    "structured_pr_feedback" => :structured_pr_feedback,
    "summary" => :summary,
    "top_level_comments" => :top_level_comments,
    "unresolved_actionable" => :unresolved_actionable,
    "unresolved_actionable_count" => :unresolved_actionable_count,
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
    pr_feedback = fetch(input, :pr_feedback, nil) |> normalize_pr_feedback()

    checks =
      input
      |> fetch(:checks, [])
      |> normalize_checks()
      |> Kernel.++(pr_feedback_checks(pr_feedback))

    review = fetch(input, :review, %{}) |> normalize_review()
    changed_surfaces = fetch(input, :changed_surfaces, []) |> normalize_surfaces()
    policy = fetch(input, :policy, %{}) |> normalize_map()
    artifacts = fetch(input, :artifacts, []) |> normalize_artifacts()
    decision = fetch(input, :decision, %{}) |> normalize_decision()
    publish_preflight = fetch(input, :publish_preflight, nil) |> PublishPreflightEvidence.normalize()
    publish_handoff = fetch(input, :publish_handoff, nil) |> PublishHandoffEvidence.normalize()

    blocker =
      normalize_blocker(fetch(input, :blocker, nil)) ||
        PublishPreflightEvidence.blocker(publish_preflight) ||
        PublishHandoffEvidence.blocker(publish_handoff)

    labels = fetch(input, :labels, fetch(input, :issue_labels, [])) |> normalize_label_list()
    auto_land = AutoLandPolicy.evaluate(%{checks: checks, labels: labels, policy: policy})

    evidence_context = %{
      checks: checks,
      review: review,
      changed_surfaces: changed_surfaces,
      policy: policy,
      artifacts: artifacts,
      blocker: blocker,
      decision: decision,
      labels: labels,
      pr_feedback: pr_feedback,
      publish_preflight: publish_preflight,
      publish_handoff: publish_handoff,
      auto_land: auto_land
    }

    %{
      checks: checks,
      review: review,
      changed_surfaces: changed_surfaces,
      policy: policy,
      artifacts: artifacts,
      decision: decision,
      publish_preflight: publish_preflight,
      publish_handoff: publish_handoff,
      blocker: blocker,
      labels: labels,
      pr_feedback: pr_feedback,
      auto_land: auto_land,
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
      target_state: context.auto_land.blocked_state,
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
      target_state: auto_land_target_state(context.auto_land),
      summary: auto_land_summary(context.auto_land),
      recommendation: auto_land_recommendation(context.auto_land),
      evidence: context.evidence,
      artifacts: context.artifacts,
      metadata: auto_land_metadata(context.auto_land)
    }
  end

  defp auto_land_target_state(%{dry_run?: true}), do: "Human Review"
  defp auto_land_target_state(%{dry_run?: false}), do: "Merging"

  defp auto_land_summary(%{dry_run?: true}) do
    "Dry-run auto-land eligible, held for Human Review without merging."
  end

  defp auto_land_summary(%{dry_run?: false}) do
    "Auto-land eligible for guarded landing through the Merging flow."
  end

  defp auto_land_recommendation(%{dry_run?: true}) do
    "Auto-land eligible by checks, review, changed surfaces, and policy; dry-run keeps the PR in Human Review."
  end

  defp auto_land_recommendation(%{dry_run?: false}) do
    "Run the existing Merging land flow after confirming checks and feedback remain clear."
  end

  defp auto_land_metadata(%{dry_run?: true}), do: %{auto_land_executor: "dry_run", dry_run: true}
  defp auto_land_metadata(%{dry_run?: false}), do: %{auto_land_executor: "land_merge", dry_run: false}

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
    substantive_auto_land_checks(context.checks) != [] and
      context.auto_land.enabled? and
      not missing_auto_land_evidence?(context) and
      Enum.all?(context.checks, &(Map.get(&1, :status) in @passed_statuses)) and
      Map.get(context.review, :status) in @passed_statuses and
      not risky?(context)
  end

  defp substantive_auto_land_checks(checks) do
    Enum.reject(checks, &(&1.name == @manifest_check_name))
  end

  defp policy_requires_human_review?(policy) do
    fetch(policy, :require_human_review, false) == true or
      fetch(policy, :requires_human_review, false) == true
  end

  defp auto_land_force_human_review_label?(context), do: not is_nil(context.auto_land.matched_force_human_review_label)

  defp missing_auto_land_evidence?(context), do: context.auto_land.missing_checks != []

  defp base_evidence(context) do
    []
    |> Kernel.++(blocker_evidence(context.blocker))
    |> Kernel.++(PublishPreflightEvidence.evidence(context.publish_preflight))
    |> Kernel.++(PublishHandoffEvidence.evidence(context.publish_handoff))
    |> Kernel.++(check_evidence(context.checks))
    |> Kernel.++(review_evidence(context.review))
    |> Kernel.++(route_gate_evidence(context.review, context.decision))
    |> Kernel.++(surface_evidence(context.changed_surfaces))
    |> Kernel.++(policy_evidence(context.policy))
    |> Kernel.++(context.auto_land.evidence)
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
      ] ++ metadata_check_evidence(checks)
    else
      Enum.map(checks, fn check ->
        %Evidence{
          kind: :check,
          status: Map.get(check, :status),
          summary: check.summary || "#{check.name} #{check.status}",
          metadata: check.metadata
        }
      end)
    end
  end

  defp metadata_check_evidence(checks) do
    checks
    |> Enum.filter(&(Map.get(&1, :metadata, %{}) != %{}))
    |> Enum.map(fn check ->
      %Evidence{
        kind: :check,
        status: Map.get(check, :status),
        summary: check.summary || "#{check.name} #{check.status}",
        metadata: check.metadata
      }
    end)
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
        summary: optional_string(fetch(check, :summary, nil)),
        metadata: fetch(check, :metadata, %{}) |> normalize_map()
      }
    end)
  end

  defp normalize_checks(_checks), do: []

  defp normalize_pr_feedback(nil), do: nil

  defp normalize_pr_feedback(feedback) when is_map(feedback) do
    feedback = normalize_map(feedback)

    %{
      status: fetch(feedback, :status, :unknown) |> normalize_pr_feedback_status(),
      pr_number: fetch(feedback, :pr_number, nil),
      checked_at: fetch(feedback, :checked_at, nil) |> optional_trimmed_string(),
      top_level_comments: feedback |> fetch(:top_level_comments, %{}) |> normalize_pr_feedback_channel(),
      inline_review_comments: feedback |> fetch(:inline_review_comments, %{}) |> normalize_pr_feedback_channel(),
      review_summaries: feedback |> fetch(:review_summaries, %{}) |> normalize_pr_feedback_channel()
    }
  end

  defp normalize_pr_feedback(_feedback), do: nil

  defp normalize_pr_feedback_channel(channel) when is_map(channel) do
    channel = normalize_map(channel)

    %{
      checked: fetch(channel, :checked, false) == true,
      source: channel |> fetch(:source, nil) |> optional_trimmed_string(),
      unresolved_actionable_count:
        channel
        |> fetch(:unresolved_actionable_count, fetch(channel, :unresolved_actionable, nil))
        |> normalize_non_negative_integer()
    }
  end

  defp normalize_pr_feedback_channel(_channel), do: %{checked: false, source: nil, unresolved_actionable_count: nil}

  defp pr_feedback_checks(nil), do: []

  defp pr_feedback_checks(pr_feedback) do
    cond do
      pr_feedback_clean?(pr_feedback) ->
        [pr_feedback_check(:passed, "PR feedback sweep completed.", pr_feedback)]

      pr_feedback_failed?(pr_feedback) ->
        [pr_feedback_check(:failed, "Actionable PR feedback is unresolved.", pr_feedback)]

      true ->
        []
    end
  end

  defp pr_feedback_check(status, summary, pr_feedback) do
    %{
      name: "pr_feedback",
      status: status,
      summary: summary,
      metadata: Map.put(pr_feedback, :structured_pr_feedback, true)
    }
  end

  defp pr_feedback_clean?(pr_feedback) do
    pr_feedback.status in [:none, :addressed, :pushback_posted] and
      pr_feedback_channels_proven?(pr_feedback) and
      pr_feedback_unresolved_count(pr_feedback) == 0
  end

  defp pr_feedback_failed?(pr_feedback) do
    pr_feedback.status == :outstanding or
      (pr_feedback_channels_proven?(pr_feedback) and pr_feedback_unresolved_count(pr_feedback) > 0)
  end

  defp pr_feedback_channels_proven?(pr_feedback) do
    Enum.all?(pr_feedback_channels(pr_feedback), fn channel ->
      channel.checked and is_binary(channel.source) and is_integer(channel.unresolved_actionable_count)
    end)
  end

  defp pr_feedback_unresolved_count(pr_feedback) do
    pr_feedback
    |> pr_feedback_channels()
    |> Enum.map(& &1.unresolved_actionable_count)
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  defp pr_feedback_channels(pr_feedback) do
    [
      pr_feedback.top_level_comments,
      pr_feedback.inline_review_comments,
      pr_feedback.review_summaries
    ]
  end

  defp normalize_pr_feedback_status(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_pr_feedback_status()
  end

  defp normalize_pr_feedback_status(value) when is_binary(value) do
    value
    |> normalize_string_token()
    |> case do
      "none" -> :none
      "addressed" -> :addressed
      "pushback_posted" -> :pushback_posted
      "outstanding" -> :outstanding
      "not_applicable" -> :not_applicable
      _value -> :unknown
    end
  end

  defp normalize_pr_feedback_status(_value), do: :unknown

  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp normalize_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _result -> nil
    end
  end

  defp normalize_non_negative_integer(_value), do: nil

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
