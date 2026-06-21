defmodule SymphonyElixir.HandoffRouteRecorder do
  @moduledoc """
  Records structured handoff route decisions to the configured tracker.
  """

  alias SymphonyElixir.{Config, HandoffManifest, HandoffRoute, PathSafety, QualityGate, Tracker}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.WorkflowModules.ProductVisualReview
  alias SymphonyElixir.WorkflowModules.ProductVisualReview.Config, as: ProductVisualReviewConfig

  @manifest_check_name "change_manifest"
  @completion_keys [
    :checks,
    "checks",
    :changed_files,
    "changed_files",
    :changedFiles,
    "changedFiles",
    :change_manifest,
    "change_manifest",
    :changeManifest,
    "changeManifest",
    :review,
    "review",
    :changed_surfaces,
    "changed_surfaces",
    :policy,
    "policy",
    :artifacts,
    "artifacts",
    :decision,
    "decision",
    :publish_preflight,
    "publish_preflight",
    :publish_handoff,
    "publish_handoff",
    :publishHandoff,
    "publishHandoff",
    :pr_feedback,
    "pr_feedback",
    :prFeedback,
    "prFeedback",
    :product_visual_review,
    "product_visual_review",
    :productVisualReview,
    "productVisualReview",
    :quality_gate,
    "quality_gate",
    :qualityGate,
    "qualityGate"
  ]
  @completion_field_aliases %{
    pr_feedback: [:pr_feedback, "pr_feedback", :prFeedback, "prFeedback"],
    publish_handoff: [:publish_handoff, "publish_handoff", :publishHandoff, "publishHandoff"]
  }

  @spec classify_completion(term()) :: HandoffRoute.Decision.t()
  def classify_completion(completion), do: classify_completion(completion, nil, nil, nil, %{}, nil)

  @spec classify_completion(term(), map() | nil) :: HandoffRoute.Decision.t()
  def classify_completion(completion, blocker), do: classify_completion(completion, blocker, nil, nil, %{}, nil)

  @spec classify_completion(term(), map() | nil, Path.t() | nil) :: HandoffRoute.Decision.t()
  def classify_completion(completion, blocker, workspace), do: classify_completion(completion, blocker, workspace, nil, %{}, nil)

  @spec classify_completion(term(), map() | nil, Path.t() | nil, String.t() | nil) :: HandoffRoute.Decision.t()
  def classify_completion(completion, blocker, workspace, worker_host) do
    classify_completion(completion, blocker, workspace, worker_host, %{}, nil)
  end

  @spec classify_completion(term(), map() | nil, Path.t() | nil, String.t() | nil, map() | keyword()) ::
          HandoffRoute.Decision.t()
  def classify_completion(completion, blocker, workspace, worker_host, routing_context) do
    classify_completion(completion, blocker, workspace, worker_host, routing_context, nil)
  end

  @spec classify_completion(
          term(),
          map() | nil,
          Path.t() | nil,
          String.t() | nil,
          map() | keyword(),
          Issue.t() | nil
        ) ::
          HandoffRoute.Decision.t()
  def classify_completion(
        completion,
        blocker,
        workspace,
        worker_host,
        routing_context,
        issue
      ) do
    completion = if is_map(completion), do: completion, else: %{}

    manifest_check = handoff_manifest_check_for_completion(completion, workspace, worker_host)

    quality_gate =
      completion
      |> completion_alias(:quality_gate, :qualityGate, nil)
      |> QualityGate.normalize_result()

    checks =
      completion
      |> completion_field(:checks, [])
      |> append_handoff_manifest_check(manifest_check)
      |> append_quality_gate_check(quality_gate)

    review =
      completion
      |> completion_field(:review, %{})
      |> then(&QualityGate.review(quality_gate, &1))

    %{
      checks: checks,
      review: review,
      changed_surfaces: completion_field(completion, :changed_surfaces, []),
      policy: routing_policy(completion, routing_context),
      issue_labels: routing_labels(completion, routing_context),
      artifacts: completion_field(completion, :artifacts, []),
      decision: completion_field(completion, :decision, %{}),
      pr_feedback: completion_field(completion, :pr_feedback, nil),
      publish_preflight: completion_field(completion, :publish_preflight, nil),
      publish_handoff: completion_field(completion, :publish_handoff, nil),
      product_visual_review: product_visual_review_evidence(completion, manifest_check, routing_context, issue),
      blocker: blocker || QualityGate.blocker(quality_gate)
    }
    |> HandoffRoute.classify()
  end

  @spec completion_metadata?(term()) :: boolean()
  def completion_metadata?(completion) when is_map(completion) do
    Enum.any?(@completion_keys, &Map.has_key?(completion, &1))
  end

  def completion_metadata?(_completion), do: false

  @spec record(String.t(), HandoffRoute.Decision.t()) :: :ok | {:error, term()}
  def record(issue_id, %HandoffRoute.Decision{} = decision) when is_binary(issue_id) do
    with :ok <- Tracker.create_comment(issue_id, HandoffRoute.format_comment(decision)) do
      Tracker.update_issue_state(issue_id, decision.target_state)
    end
  end

  defp completion_field(completion, key, default) do
    key
    |> completion_field_keys()
    |> Enum.reduce_while(default, fn candidate, acc ->
      case Map.fetch(completion, candidate) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, acc}
      end
    end)
  end

  defp completion_field_keys(key), do: Map.get(@completion_field_aliases, key, [key, to_string(key)])

  defp routing_policy(completion, routing_context) do
    context_field(routing_context, :policy, nil) || completion_field(completion, :policy, %{})
  end

  defp routing_labels(completion, routing_context) do
    context_field(routing_context, :labels, context_field(routing_context, :issue_labels, nil)) ||
      completion_field(completion, :issue_labels, completion_field(completion, :labels, []))
  end

  defp context_field(context, key, default) when is_map(context) do
    Map.get(context, key, Map.get(context, to_string(key), default))
  end

  defp context_field(context, key, default) when is_list(context) do
    Keyword.get(context, key, default)
  end

  defp context_field(_context, _key, default), do: default

  defp completion_alias(completion, key, camel_key, default) do
    completion
    |> completion_field(key, completion_field(completion, camel_key, default))
  end

  defp product_visual_review_evidence(completion, manifest_check, routing_context, issue) do
    payload =
      completion_alias(completion, :product_visual_review, :productVisualReview, nil) ||
        product_visual_review_payload_from_quality_gate(completion_alias(completion, :quality_gate, :qualityGate, nil))

    ProductVisualReview.route_evidence(
      product_visual_review_config(routing_context),
      changed_files_from_manifest_check(manifest_check),
      issue,
      payload
    )
  end

  defp product_visual_review_payload_from_quality_gate(quality_gate) when is_map(quality_gate) do
    quality_gate
    |> quality_gate_jobs()
    |> Enum.find_value(&product_visual_review_payload_from_job/1)
  end

  defp product_visual_review_payload_from_quality_gate(_quality_gate), do: nil

  defp quality_gate_jobs(quality_gate) do
    quality_gate
    |> list_field(:final_jobs)
    |> Kernel.++(list_field(quality_gate, :jobs))
  end

  defp product_visual_review_payload_from_job(job) when is_map(job) do
    if normalize_token(module_field(job, :category)) == "product_visual_review" do
      host_visual_qa = module_field(job, :host_visual_qa)

      cond do
        is_map(host_visual_qa) ->
          host_visual_qa_route_payload(host_visual_qa, job)

        host_visual_qa_blocked_job?(job) ->
          blocked_host_visual_qa_route_payload(job)

        true ->
          nil
      end
    end
  end

  defp product_visual_review_payload_from_job(_job), do: nil

  defp host_visual_qa_route_payload(host_visual_qa, job) do
    summary =
      optional_string(module_field(host_visual_qa, :summary)) ||
        optional_string(module_field(job, :summary)) ||
        "Host visual QA completed."

    %{
      "status" => optional_string(module_field(host_visual_qa, :status)) || optional_string(module_field(job, :status)) || "passed",
      "summary" => summary,
      "reason" => summary,
      "required_action" => optional_string(module_field(host_visual_qa, :required_action)),
      "checks" => list_field(host_visual_qa, :checks),
      "artifacts" => host_visual_qa |> list_field(:artifacts) |> Enum.map(&route_safe_artifact/1)
    }
    |> drop_nil_values()
  end

  defp host_visual_qa_blocked_job?(job) do
    blocked_reason = optional_string(module_field(job, :blocked_reason)) || ""
    normalize_token(module_field(job, :status)) == "blocked" and String.contains?(blocked_reason, "host_visual_qa")
  end

  defp blocked_host_visual_qa_route_payload(job) do
    reason =
      optional_string(module_field(job, :summary)) ||
        optional_string(module_field(job, :blocked_reason)) ||
        "Host visual QA was blocked."

    %{
      "status" => "blocked",
      "reason" => reason,
      "summary" => reason,
      "required_action" => "Fix host visual QA infrastructure or attach structured desktop/mobile evidence before handoff."
    }
  end

  defp list_field(map, key) when is_map(map) do
    case module_field(map, key) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp route_safe_artifact(artifact) when is_map(artifact) do
    metadata =
      artifact
      |> module_field(:metadata)
      |> route_safe_artifact_metadata()

    artifact
    |> Map.drop(["path", :path])
    |> Map.put("metadata", metadata)
  end

  defp route_safe_artifact(artifact), do: artifact

  defp route_safe_artifact_metadata(metadata) when is_map(metadata) do
    Map.drop(metadata, ["path", :path, "artifact_dir", :artifact_dir, "manifest_path", :manifest_path])
  end

  defp route_safe_artifact_metadata(_metadata), do: %{}

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_token(value) when is_atom(value), do: normalize_token(Atom.to_string(value))

  defp normalize_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_token(value), do: value |> to_string() |> normalize_token()

  defp optional_string(nil), do: nil

  defp optional_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      string -> string
    end
  end

  defp product_visual_review_config(routing_context) do
    explicit_config =
      routing_context
      |> context_field(:product_visual_review_config, nil)
      |> product_visual_review_config_from_value()

    workflow_module_resolution = context_field(routing_context, :workflow_module_resolution, nil)

    case explicit_config do
      %ProductVisualReviewConfig{} = config ->
        config

      nil ->
        if is_nil(workflow_module_resolution) do
          Config.settings!().workflow_modules.product_visual_review
        else
          product_visual_review_config_from_resolution(workflow_module_resolution) ||
            disabled_product_visual_review_config()
        end
    end
  end

  defp product_visual_review_config_from_resolution(%{modules: modules}) when is_list(modules) do
    Enum.find_value(modules, fn module ->
      if module_field(module, :id) == "product_visual_review" do
        module
        |> module_field(:config)
        |> product_visual_review_config_from_value()
      end
    end)
  end

  defp product_visual_review_config_from_resolution(%{"modules" => modules}) when is_list(modules) do
    product_visual_review_config_from_resolution(%{modules: modules})
  end

  defp product_visual_review_config_from_resolution(_resolution), do: nil

  defp product_visual_review_config_from_value(%ProductVisualReviewConfig{} = config), do: config

  defp product_visual_review_config_from_value(config) when is_map(config) do
    attrs = nested_product_visual_review_config(config) || config

    %ProductVisualReviewConfig{}
    |> ProductVisualReviewConfig.changeset(attrs)
    |> Ecto.Changeset.apply_action(:validate)
    |> case do
      {:ok, config} -> config
      {:error, _changeset} -> nil
    end
  end

  defp product_visual_review_config_from_value(_config), do: nil

  defp disabled_product_visual_review_config do
    %ProductVisualReviewConfig{enabled: false, route_policy: "off"}
  end

  defp nested_product_visual_review_config(config) when is_map(config) do
    workflow_modules = module_field(config, :workflow_modules)

    if is_map(workflow_modules) do
      module_field(workflow_modules, :product_visual_review)
    end
  end

  defp module_field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp module_field(_map, _key), do: nil

  defp changed_files_from_manifest_check(%{
         name: @manifest_check_name,
         status: :passed,
         metadata: %{changed_files: changed_files}
       })
       when is_list(changed_files) do
    changed_files
  end

  defp changed_files_from_manifest_check(_check), do: []

  defp append_handoff_manifest_check(checks, nil) do
    checks = if is_list(checks), do: checks, else: []
    checks
  end

  defp append_handoff_manifest_check(checks, manifest_check) when is_map(manifest_check) do
    checks = if is_list(checks), do: checks, else: []
    checks ++ [manifest_check]
  end

  defp append_quality_gate_check(checks, nil), do: checks

  defp append_quality_gate_check(checks, quality_gate) do
    checks = if is_list(checks), do: checks, else: []
    checks ++ [quality_gate |> route_safe_quality_gate() |> QualityGate.check()]
  end

  defp route_safe_quality_gate(quality_gate) when is_map(quality_gate) do
    Map.new(quality_gate, fn {key, value} ->
      if normalize_token(key) == "host_visual_qa" do
        {key, route_safe_host_visual_qa(value)}
      else
        {key, route_safe_quality_gate(value)}
      end
    end)
  end

  defp route_safe_quality_gate(values) when is_list(values), do: Enum.map(values, &route_safe_quality_gate/1)
  defp route_safe_quality_gate(value), do: value

  defp route_safe_host_visual_qa(host_visual_qa) when is_map(host_visual_qa) do
    Enum.reduce(host_visual_qa, %{}, fn {key, value}, acc ->
      case normalize_token(key) do
        token when token in ["artifact_dir", "manifest_path", "raw_output"] ->
          acc

        "artifacts" when is_list(value) ->
          Map.put(acc, key, Enum.map(value, &route_safe_artifact/1))

        _token ->
          Map.put(acc, key, route_safe_host_visual_qa(value))
      end
    end)
  end

  defp route_safe_host_visual_qa(values) when is_list(values), do: Enum.map(values, &route_safe_host_visual_qa/1)
  defp route_safe_host_visual_qa(value), do: value

  defp handoff_manifest_check_for_completion(completion, workspace, worker_host) do
    case HandoffManifest.source(completion) do
      :absent ->
        if completion_metadata?(completion) do
          handoff_manifest_check(%{}, workspace, worker_host)
        end

      {:present, manifest} ->
        handoff_manifest_check(manifest, workspace, worker_host)

      {:failed, failure} ->
        failed_handoff_manifest_check(failure)
    end
  end

  defp handoff_manifest_check(_manifest, _workspace, worker_host)
       when is_binary(worker_host) and worker_host != "" do
    %{
      name: "change_manifest",
      status: :failed,
      summary: "Changed-file manifest rejected: remote workspace validation is unavailable.",
      metadata: %{
        failures: [
          %{
            path: "<workspace>",
            reason: :remote_workspace_validation_unavailable,
            message: "Host-side changed-file manifest validation cannot resolve remote workspace paths or symlinks.",
            metadata: %{worker_host: worker_host}
          }
        ]
      }
    }
  end

  defp handoff_manifest_check(_manifest, workspace, _worker_host) when not is_binary(workspace) do
    %{
      name: "change_manifest",
      status: :failed,
      summary: "Changed-file manifest rejected: workspace path is unavailable for host validation.",
      metadata: %{
        failures: [
          %{
            path: "<workspace>",
            reason: :missing_workspace,
            message: "Workspace path is required to validate changed-file manifest containment.",
            metadata: %{}
          }
        ]
      }
    }
  end

  defp handoff_manifest_check(manifest, workspace, _worker_host) do
    case PathSafety.validate_handoff_manifest(workspace, manifest) do
      {:ok, %{changed_files: changed_files, validation: validation}} ->
        %{
          name: "change_manifest",
          status: :passed,
          summary: "Changed-file manifest validated: #{length(changed_files)} file(s).",
          metadata: %{changed_files: changed_files, validation: validation}
        }

      {:error, %{summary: summary, failures: failures}} ->
        %{
          name: "change_manifest",
          status: :failed,
          summary: summary,
          metadata: %{failures: failures}
        }
    end
  end

  defp failed_handoff_manifest_check(failure) do
    %{
      name: "change_manifest",
      status: :failed,
      summary: "Changed-file manifest rejected: 1 failure(s): #{failure.reason}",
      metadata: %{failures: [failure]}
    }
  end
end
