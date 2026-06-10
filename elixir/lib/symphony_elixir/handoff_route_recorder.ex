defmodule SymphonyElixir.HandoffRouteRecorder do
  @moduledoc """
  Records structured handoff route decisions to the configured tracker.
  """

  alias SymphonyElixir.{Config, HandoffManifest, HandoffRoute, PathSafety, Tracker}
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
    "productVisualReview"
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

    checks =
      completion
      |> completion_field(:checks, [])
      |> append_handoff_manifest_check(manifest_check)

    %{
      checks: checks,
      review: completion_field(completion, :review, %{}),
      changed_surfaces: completion_field(completion, :changed_surfaces, []),
      policy: routing_policy(completion, routing_context),
      issue_labels: routing_labels(completion, routing_context),
      artifacts: completion_field(completion, :artifacts, []),
      decision: completion_field(completion, :decision, %{}),
      pr_feedback: completion_field(completion, :pr_feedback, nil),
      publish_preflight: completion_field(completion, :publish_preflight, nil),
      publish_handoff: completion_field(completion, :publish_handoff, nil),
      product_visual_review: product_visual_review_evidence(completion, manifest_check, routing_context, issue),
      blocker: blocker
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
    completion
    |> completion_alias(:product_visual_review, :productVisualReview, nil)
    |> then(fn payload ->
      ProductVisualReview.route_evidence(
        product_visual_review_config(routing_context),
        changed_files_from_manifest_check(manifest_check),
        issue,
        payload
      )
    end)
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
