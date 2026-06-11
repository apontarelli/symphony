defmodule SymphonyElixir.ReviewRecords do
  @moduledoc """
  Persists host-owned quality-gate review records and retrospective exports.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.HandoffRoute
  alias SymphonyElixir.HandoffRoute.Decision
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.LogFile
  alias SymphonyElixir.QualityGate.Synthesis
  alias SymphonyElixir.ReviewRecords.{ParallelReviewAdapter, PathSanitizer, Redaction}

  @metadata_schema "symphony.quality_gate_review_record.metadata.v1"
  @quality_gate_schema "symphony.quality_gate_review_record.quality_gate.v1"
  @findings_schema "symphony.quality_gate_review_record.findings.v1"
  @disposition_schema "symphony.quality_gate_review_record.disposition.v1"
  @handoff_route_schema "symphony.quality_gate_review_record.handoff_route.v1"
  @export_schema "symphony.review_retrospective_input.v1"

  @type record_files :: %{
          metadata: Path.t(),
          quality_gate: Path.t(),
          findings: Path.t(),
          disposition: Path.t(),
          handoff_route: Path.t()
        }

  @type write_result :: %{
          record_dir: Path.t(),
          files: record_files()
        }

  @spec records_root(Path.t() | nil) :: Path.t()
  def records_root(nil), do: Path.join(default_logs_root(), "review-records")
  def records_root(logs_root) when is_binary(logs_root), do: Path.join(Path.expand(logs_root), "review-records")

  @spec write_quality_gate_run(map()) :: {:ok, write_result()} | {:error, term()}
  def write_quality_gate_run(params) when is_map(params) do
    with {:ok, normalized} <- normalize_write_params(params),
         :ok <- File.mkdir_p(normalized.record_dir) do
      files = record_files(normalized.record_dir)

      metadata = metadata_payload(normalized, files)
      quality_gate = quality_gate_payload(normalized.quality_gate, normalized.workspace)
      findings = findings_payload(normalized, quality_gate)
      disposition = disposition_payload(normalized, findings)
      handoff_route = handoff_route_payload(normalized.handoff_route)

      with :ok <- write_json(files.metadata, metadata),
           :ok <- write_json(files.quality_gate, quality_gate),
           :ok <- write_json_once(files.findings, findings),
           :ok <- write_json_once(files.disposition, disposition),
           :ok <- write_json(files.handoff_route, handoff_route),
           :ok <- write_parallel_review_compatibility(normalized, files) do
        {:ok, %{record_dir: normalized.record_dir, files: files}}
      end
    end
  rescue
    error -> {:error, error}
  end

  @spec list(Path.t() | nil, keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(logs_root, opts \\ []) when is_list(opts) do
    records_root = records_root(logs_root)
    limit = Keyword.get(opts, :limit, 20)

    summaries =
      records_root
      |> metadata_paths()
      |> Enum.flat_map(&record_summary(&1, records_root))
      |> Enum.sort_by(&summary_sort_key/1, :desc)
      |> maybe_limit(limit)

    {:ok, summaries}
  rescue
    error -> {:error, error}
  end

  @spec show(Path.t() | nil, String.t()) :: {:ok, map()} | {:error, term()}
  def show(logs_root, run_id) when is_binary(run_id) do
    records_root = records_root(logs_root)
    normalized_run_id = sanitize_segment(run_id)

    records =
      records_root
      |> metadata_paths()
      |> Enum.filter(&(Path.basename(Path.dirname(&1)) == normalized_run_id))

    case records do
      [] ->
        {:error, :not_found}

      [metadata_path] ->
        {:ok, read_record!(Path.dirname(metadata_path))}

      ambiguous ->
        {:error, {:ambiguous_run_id, Enum.map(ambiguous, &Path.dirname/1)}}
    end
  rescue
    error -> {:error, error}
  end

  @spec export(Path.t() | nil, keyword()) :: {:ok, map() | String.t()} | {:error, term()}
  def export(logs_root, opts \\ []) when is_list(opts) do
    format = Keyword.get(opts, :format, :markdown)
    records_root = records_root(logs_root)

    records =
      records_root
      |> metadata_paths()
      |> Enum.map(&(Path.dirname(&1) |> read_record!()))
      |> Enum.sort_by(&record_sort_key/1, :desc)
      |> filter_since(Keyword.get(opts, :since))

    export = export_payload(records)

    case format do
      :json -> {:ok, export}
      "json" -> {:ok, export}
      :markdown -> {:ok, export_markdown(export)}
      "markdown" -> {:ok, export_markdown(export)}
      other -> {:error, {:unsupported_export_format, other}}
    end
  rescue
    error -> {:error, error}
  end

  defp default_logs_root do
    LogFile.default_log_file()
    |> Config.log_file()
    |> logs_root_from_log_file()
  end

  defp logs_root_from_log_file(log_file) do
    expanded = Path.expand(log_file)
    parent = Path.dirname(expanded)

    if Path.basename(expanded) == "symphony.log" and Path.basename(parent) == "log" do
      Path.dirname(parent)
    else
      parent
    end
  end

  defp normalize_write_params(params) do
    project = normalize_project(field(params, :project, %{}), field(params, :policy, %{}))
    issue = normalize_issue(field(params, :issue, %{}))
    workflow = normalize_workflow(field(params, :workflow, %{}), field(params, :policy, %{}))
    run = normalize_run(field(params, :run, %{}), params)
    logs_root = field(params, :logs_root, nil)
    workspace = workspace_path(params)
    record_dir = Path.join([records_root(logs_root), "quality-gates", project.slug, issue.identifier, run.id])

    {:ok,
     %{
       logs_root: logs_root,
       workspace: workspace,
       project: project,
       issue: issue,
       workflow: workflow,
       run: run,
       quality_gate: field(params, :quality_gate, %{}),
       handoff_route: field(params, :handoff_route, %{}),
       record_dir: record_dir
     }}
  end

  defp normalize_project(project, policy) do
    %{
      slug:
        (field(project, :slug, nil) ||
           field(policy, :project_slug, nil) ||
           get_in_any(policy, [["policy_metadata", "project_slug"], [:policy_metadata, :project_slug], ["project", "slug"], [:project, :slug]]))
        |> fallback("unknown-project")
        |> sanitize_segment(),
      name: field(project, :name, get_in_any(policy, [["project", "name"], [:project, :name]])),
      repository: field(project, :repository, get_in_any(policy, [["project", "repository"], [:project, :repository], ["manifest", "project", "repository"]]))
    }
  end

  defp normalize_issue(%Issue{} = issue), do: normalize_issue(Map.from_struct(issue))

  defp normalize_issue(issue) when is_map(issue) do
    %{
      id: optional_string(field(issue, :id, nil)),
      identifier: issue |> field(:identifier, "unknown-issue") |> fallback("unknown-issue") |> sanitize_segment(),
      title: optional_string(field(issue, :title, nil)),
      url: optional_string(field(issue, :url, nil))
    }
  end

  defp normalize_issue(_issue), do: normalize_issue(%{})

  defp normalize_workflow(workflow, policy) do
    %{
      profile: field(workflow, :profile, nil) || get_in_any(policy, [["policy_metadata", "profile"], [:policy_metadata, :profile]]),
      policy_ref: field(workflow, :policy_ref, nil) || field(policy, :policy_ref, nil),
      target: field(workflow, :target, nil) || get_in_any(policy, [["delivery", "pr_target"], [:delivery, :pr_target]])
    }
  end

  defp normalize_run(run, params) do
    raw_id =
      field(run, :id, nil) ||
        field(params, :run_id, nil) ||
        field(run, :session_id, nil) ||
        field(params, :session_id, nil) ||
        content_run_id(run, params)

    %{
      id: raw_id |> fallback("unknown-run") |> sanitize_segment(),
      raw_id: optional_string(raw_id),
      session_id: optional_string(field(run, :session_id, field(params, :session_id, nil))),
      started_at: iso8601_or_nil(field(run, :started_at, field(params, :started_at, nil))),
      completed_at: iso8601_or_now(field(run, :completed_at, field(params, :completed_at, nil))),
      created_at: iso8601_now()
    }
  end

  defp content_run_id(run, params) do
    hash =
      :sha256
      |> :crypto.hash(
        :erlang.term_to_binary({
          field(params, :issue, nil),
          field(run, :started_at, field(params, :started_at, nil)),
          field(run, :completed_at, field(params, :completed_at, nil)),
          field(params, :quality_gate, nil)
        })
      )
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "run-#{hash}"
  end

  defp workspace_path(params) do
    quality_gate = field(params, :quality_gate, %{})

    params
    |> field(:workspace, nil)
    |> fallback(field(params, :workspace_path, nil))
    |> fallback(
      get_in_any(quality_gate, [
        [:planner, :workspace],
        ["planner", "workspace"],
        [:planner, :workspace_path],
        ["planner", "workspace_path"]
      ])
    )
    |> runtime_string()
  end

  defp metadata_payload(normalized, files) do
    changed_files = changed_files(normalized.quality_gate, normalized.workspace)
    changed_surfaces = changed_surfaces(normalized.quality_gate)

    %{
      schema: @metadata_schema,
      record_type: "symphony_quality_gate",
      project: normalized.project,
      issue: normalized.issue,
      workflow: normalized.workflow,
      run: normalized.run,
      created_at: normalized.run.created_at,
      changed_files: changed_files,
      changed_surfaces: changed_surfaces,
      artifact_paths: %{
        metadata: Path.basename(files.metadata),
        quality_gate: Path.basename(files.quality_gate),
        findings: Path.basename(files.findings),
        disposition: Path.basename(files.disposition),
        handoff_route: Path.basename(files.handoff_route)
      }
    }
    |> Redaction.json_ready()
  end

  defp quality_gate_payload(quality_gate, workspace) do
    quality_gate = PathSanitizer.sanitize_payload_paths(quality_gate, workspace)
    jobs = quality_gate |> field(:jobs, []) |> list_value()

    %{
      schema: @quality_gate_schema,
      status: quality_gate |> field(:status, :blocked) |> token(),
      planner_decision: quality_gate |> field(:planner, %{}) |> redact_runtime_payload(),
      requested_jobs: quality_gate |> field(:planner, %{}) |> field(:jobs, []) |> redact_runtime_payload(),
      executed_jobs: jobs |> Enum.filter(&executed_job?/1) |> redact_runtime_payload(),
      blocked_jobs: jobs |> Enum.filter(&blocked_job?/1) |> redact_runtime_payload(),
      skipped_jobs: jobs |> Enum.filter(&skipped_job?/1) |> redact_runtime_payload(),
      raw_normalized_reviewer_outputs: redact_runtime_payload(jobs),
      synthesis: quality_gate |> field(:synthesis, %{}) |> redact_runtime_payload(),
      repair_passes: quality_gate |> field(:repair_passes, []) |> redact_runtime_payload(),
      unresolved_human_review_reasons:
        quality_gate
        |> field(:unresolved_human_review_reasons, [])
        |> redact_runtime_payload()
    }
    |> Redaction.json_ready()
  end

  defp findings_payload(normalized, quality_gate_payload) do
    findings =
      normalized.quality_gate
      |> normalized_findings(normalized.workspace)
      |> Enum.map(&put_finding_repair(&1, normalized.quality_gate))

    %{
      schema: @findings_schema,
      review_id: normalized.run.id,
      record_type: "symphony_quality_gate",
      quality_gate_status: quality_gate_payload["status"],
      findings: findings
    }
    |> Redaction.json_ready()
  end

  defp disposition_payload(normalized, findings_payload) do
    now = normalized.run.created_at

    dispositions =
      findings_payload["findings"]
      |> Enum.map(fn finding ->
        %{
          finding_id: finding["id"],
          category: finding["category"],
          status: initial_disposition(finding),
          rationale: initial_disposition_rationale(finding),
          updated_at: now,
          updated_by: "symphony",
          links: finding_links(finding)
        }
      end)

    %{
      schema: @disposition_schema,
      review_id: normalized.run.id,
      instruction: "When acting on these findings, update only this disposition sidecar. Do not edit findings.json.",
      dispositions: dispositions
    }
    |> Redaction.json_ready()
  end

  defp handoff_route_payload(%Decision{} = decision), do: handoff_route_payload(HandoffRoute.to_map(decision))

  defp handoff_route_payload(route) when is_map(route) do
    %{
      schema: @handoff_route_schema,
      route: redact_runtime_payload(route),
      quality_gate_evidence: quality_gate_evidence(route)
    }
    |> Redaction.json_ready()
  end

  defp handoff_route_payload(_route), do: handoff_route_payload(%{})

  defp normalized_findings(quality_gate, workspace) do
    jobs = quality_gate |> field(:jobs, []) |> list_value()
    job_by_id = Map.new(jobs, &{field(&1, :id, nil), &1})

    synthesis_findings =
      jobs
      |> Enum.reject(&(blocked_job?(&1) or skipped_job?(&1)))
      |> Synthesis.normalize_findings()
      |> Enum.map(&normalize_synthesis_finding(&1, workspace, job_by_id))

    review_state_findings =
      jobs
      |> Enum.flat_map(fn job ->
        cond do
          blocked_job?(job) -> [synthetic_job_finding(job, :human_input_required)]
          skipped_job?(job) -> [synthetic_job_finding(job, :no_action)]
          true -> []
        end
      end)

    (synthesis_findings ++ review_state_findings)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_synthesis_finding(finding, workspace, job_by_id) when is_map(finding) do
    source_job_id = field(finding, :source_job_id, nil)
    source_job = Map.get(job_by_id, source_job_id, %{})
    category = finding |> field(:category, :source_correctness) |> token()
    severity = finding |> field(:severity, :major) |> token()

    evidence =
      finding
      |> field(:evidence, "Reviewer reported an actionable finding.")
      |> fallback("Reviewer reported an actionable finding.")

    base = %{
      category: category,
      severity: severity,
      evidence: Redaction.redact_string(evidence),
      affected_files: finding |> field(:affected_files, []) |> PathSanitizer.safe_file_list(workspace),
      source_job: optional_string(source_job_id),
      source_phase: source_job |> field(:phase, nil) |> token(),
      recommended_disposition: finding |> field(:recommended_disposition, :human_input_required) |> token(),
      reproducibility_notes:
        finding
        |> field(:reproducibility_notes, nil)
        |> optional_string()
    }

    base
    |> Map.put(:id, finding_id(base))
    |> Map.merge(parallel_review_fields(base))
  end

  defp normalize_synthesis_finding(_finding, _workspace, _job_by_id), do: nil

  defp synthetic_job_finding(job, recommended_disposition) do
    category = job |> field(:category, :review) |> token()
    evidence = field(job, :blocked_reason, field(job, :summary, "Reviewer job did not produce findings."))

    base = %{
      category: category,
      severity: if(recommended_disposition == :no_action, do: "trivial", else: "major"),
      evidence: Redaction.redact_string(evidence),
      affected_files: [],
      source_job: job |> field(:id, nil) |> optional_string(),
      source_phase: job |> field(:phase, nil) |> token(),
      recommended_disposition: token(recommended_disposition),
      reproducibility_notes: nil,
      synthetic: true
    }

    base
    |> Map.put(:id, finding_id(base))
    |> Map.merge(parallel_review_fields(base))
  end

  defp put_finding_repair(%{recommended_disposition: "fix_required", category: category} = finding, quality_gate) do
    case repair_for_category(quality_gate, category) do
      nil -> finding
      repair -> Map.put(finding, :repair, repair)
    end
  end

  defp put_finding_repair(finding, _quality_gate), do: finding

  defp repair_for_category(quality_gate, category) do
    quality_gate
    |> field(:repair_passes, [])
    |> list_value()
    |> Enum.find_value(fn repair_pass ->
      rerun_categories =
        repair_pass
        |> field(:rerun_categories, [])
        |> list_value()
        |> Enum.map(&token/1)

      if token(field(repair_pass, :status, nil)) == "passed" and category in rerun_categories do
        %{
          status: "fixed",
          repair_pass: field(repair_pass, :attempt, nil),
          rerun_jobs:
            repair_pass
            |> field(:rerun_jobs, [])
            |> list_value()
            |> Enum.map(&field(&1, :id, nil))
            |> Enum.reject(&is_nil/1)
        }
      end
    end)
  end

  defp initial_disposition(%{"repair" => %{"status" => "fixed"}}), do: "fixed"
  defp initial_disposition(%{"recommended_disposition" => "fix_required"}), do: "accepted"
  defp initial_disposition(%{"recommended_disposition" => "follow_up"}), do: "deferred_followup"
  defp initial_disposition(%{"recommended_disposition" => "human_input_required"}), do: "needs_user_decision"
  defp initial_disposition(%{"recommended_disposition" => "rejected_false_positive"}), do: "rejected_false_positive"
  defp initial_disposition(%{"recommended_disposition" => "no_action"}), do: "no_action"
  defp initial_disposition(_finding), do: "untriaged"

  defp initial_disposition_rationale(%{"repair" => %{"status" => "fixed"}}), do: "Fixed by quality-gate repair/rerun evidence."
  defp initial_disposition_rationale(%{"recommended_disposition" => "follow_up"}), do: "Reviewer recommended follow-up outside the blocking repair path."
  defp initial_disposition_rationale(%{"recommended_disposition" => "rejected_false_positive"}), do: "Reviewer output marked this as a false positive."
  defp initial_disposition_rationale(%{"recommended_disposition" => "human_input_required"}), do: "Quality gate preserved this as an operator-decision item."
  defp initial_disposition_rationale(%{"recommended_disposition" => "no_action"}), do: "No action required."
  defp initial_disposition_rationale(_finding), do: ""

  defp finding_links(%{"repair" => repair}), do: [%{"kind" => "quality_gate_repair", "target" => repair}]
  defp finding_links(_finding), do: []

  defp parallel_review_fields(finding) do
    %{
      kind: "finding",
      lens: finding.category,
      priority: priority_for_severity(finding.severity),
      title: short_title(finding.evidence),
      locations: finding.affected_files,
      root_cause: finding.category,
      recommendation: finding.recommended_disposition,
      validation: finding.source_job || "quality_gate"
    }
  end

  defp priority_for_severity("critical"), do: "P0"
  defp priority_for_severity("major"), do: "P1"
  defp priority_for_severity("minor"), do: "P2"
  defp priority_for_severity(_severity), do: "P3"

  defp short_title(evidence) when is_binary(evidence) do
    if String.length(evidence) > 80, do: String.slice(evidence, 0, 77) <> "...", else: evidence
  end

  defp finding_id(finding) do
    digest =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(Map.take(finding, [:category, :evidence, :affected_files, :source_job, :recommended_disposition])))
      |> Base.encode16(case: :upper)
      |> binary_part(0, 10)

    "QG-#{digest}"
  end

  defp changed_files(quality_gate, workspace) do
    quality_gate
    |> field(:planner, %{})
    |> field(:changed_files, [])
    |> PathSanitizer.safe_file_list(workspace)
  end

  defp changed_surfaces(quality_gate) do
    quality_gate
    |> field(:planner, %{})
    |> field(:changed_surfaces, [])
    |> list_value()
    |> Enum.map(&token/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp executed_job?(job), do: token(field(job, :execution, nil)) == "executed"
  defp blocked_job?(job), do: token(field(job, :execution, nil)) == "blocked" or token(field(job, :status, nil)) == "blocked"
  defp skipped_job?(job), do: token(field(job, :execution, nil)) == "skipped" or token(field(job, :status, nil)) == "skipped"

  defp quality_gate_evidence(route) do
    route
    |> field(:evidence, [])
    |> list_value()
    |> Enum.filter(fn evidence ->
      evidence |> field(:kind, nil) |> token() == "check" and
        evidence |> field(:summary, "") |> to_string() |> String.downcase() |> String.contains?("quality")
    end)
    |> redact_runtime_payload()
  end

  defp write_parallel_review_compatibility(normalized, files) do
    ParallelReviewAdapter.write(normalized, files)
  end

  defp metadata_paths(records_root) do
    records_root
    |> Path.join("quality-gates/*/*/*/metadata.json")
    |> Path.wildcard()
  end

  defp record_summary(metadata_path, records_root) do
    record_dir = Path.dirname(metadata_path)

    try do
      record = read_record!(record_dir)
      metadata = record.metadata
      disposition_counts = disposition_counts(record.disposition)

      [
        %{
          project_slug: get_in(metadata, ["project", "slug"]),
          issue_identifier: get_in(metadata, ["issue", "identifier"]),
          run_id: get_in(metadata, ["run", "id"]),
          created_at: metadata["created_at"],
          completed_at: get_in(metadata, ["run", "completed_at"]),
          quality_gate_status: record.quality_gate["status"],
          route: get_in(record.handoff_route, ["route", "route"]),
          target_state: get_in(record.handoff_route, ["route", "target_state"]),
          findings_count: length(get_in(record.findings, ["findings"]) || []),
          disposition_counts: disposition_counts,
          record_path: relative_record_path(record_dir, records_root)
        }
      ]
    rescue
      _error -> []
    end
  end

  defp read_record!(record_dir) do
    %{
      record_dir: record_dir,
      metadata: read_json!(Path.join(record_dir, "metadata.json")),
      quality_gate: read_json!(Path.join(record_dir, "quality_gate.json")),
      findings: read_json!(Path.join(record_dir, "findings.json")),
      disposition: read_json!(Path.join(record_dir, "disposition.json")),
      handoff_route: read_json!(Path.join(record_dir, "handoff_route.json"))
    }
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp relative_record_path(record_dir, records_root) do
    record_dir
    |> Path.relative_to(records_root)
    |> Path.split()
    |> Path.join()
  end

  defp summary_sort_key(summary) do
    {summary.completed_at || summary.created_at || "", summary.record_path || ""}
  end

  defp record_sort_key(record) do
    metadata = record.metadata
    {get_in(metadata, ["run", "completed_at"]) || metadata["created_at"] || "", relative_record_path(record.record_dir, Path.join(record.record_dir, "../../../.."))}
  end

  defp maybe_limit(records, limit) when is_integer(limit) and limit > 0, do: Enum.take(records, limit)
  defp maybe_limit(records, _limit), do: records

  defp filter_since(records, nil), do: records
  defp filter_since([], :last), do: []
  defp filter_since([latest | _records], :last), do: [latest]
  defp filter_since(records, "last"), do: filter_since(records, :last)

  defp filter_since(records, since) when is_binary(since) do
    case parse_since(since) do
      {:ok, cutoff} ->
        Enum.filter(records, &record_on_or_after?(&1, cutoff))

      :error ->
        records
    end
  end

  defp filter_since(records, _since), do: records

  defp parse_since(value) do
    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, elem(DateTime.from_iso8601(value), 1)}

      match?({:ok, _}, Date.from_iso8601(value)) ->
        {:ok, value |> Date.from_iso8601!() |> DateTime.new!(~T[00:00:00], "Etc/UTC")}

      true ->
        :error
    end
  end

  defp record_timestamp(record) do
    timestamp = get_in(record.metadata, ["run", "completed_at"]) || record.metadata["created_at"]

    case DateTime.from_iso8601(timestamp || "") do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp record_on_or_after?(record, cutoff) do
    case record_timestamp(record) do
      nil -> false
      timestamp -> DateTime.compare(timestamp, cutoff) != :lt
    end
  end

  defp export_payload(records) do
    entries = Enum.flat_map(records, &export_entries/1)

    %{
      "schema" => @export_schema,
      "created_at" => iso8601_now(),
      "record_count" => length(records),
      "records" => Enum.map(records, &export_record_summary/1),
      "groups" => %{
        "by_category" => group_entries(entries, & &1["category"]),
        "by_disposition" => group_entries(entries, & &1["disposition"]),
        "by_surface" => group_by_surface(entries),
        "false_positive_patterns" => Enum.filter(entries, &(&1["disposition"] == "rejected_false_positive")),
        "follow_up_candidates" => Enum.filter(entries, &(&1["disposition"] == "deferred_followup"))
      },
      "review_retrospective_compatibility" => %{
        "artifact_root" => "review-records",
        "parallel_review_path" => "parallel-review/<project-slug>/<run-id>",
        "note" => "Set AGENT_RECORDS_HOME to the review-records root to let review-retrospective discover compatible exported records."
      }
    }
  end

  defp export_record_summary(record) do
    project_slug = get_in(record.metadata, ["project", "slug"])
    issue_identifier = get_in(record.metadata, ["issue", "identifier"])
    run_id = get_in(record.metadata, ["run", "id"])

    %{
      "project_slug" => project_slug,
      "issue_identifier" => issue_identifier,
      "run_id" => run_id,
      "quality_gate_status" => record.quality_gate["status"],
      "route" => get_in(record.handoff_route, ["route", "route"]),
      "record_path" => export_record_path(project_slug, issue_identifier, run_id)
    }
  end

  defp export_record_path(project_slug, issue_identifier, run_id) do
    ["quality-gates", project_slug || "unknown-project", issue_identifier || "unknown-issue", run_id || "unknown-run"]
    |> Path.join()
  end

  defp export_entries(record) do
    dispositions =
      record.disposition
      |> Map.get("dispositions", [])
      |> Map.new(fn disposition -> {disposition["finding_id"], disposition} end)

    record.findings
    |> Map.get("findings", [])
    |> Enum.map(fn finding ->
      disposition = Map.get(dispositions, finding["id"], %{})

      %{
        "record_id" => get_in(record.metadata, ["run", "id"]),
        "project_slug" => get_in(record.metadata, ["project", "slug"]),
        "issue_identifier" => get_in(record.metadata, ["issue", "identifier"]),
        "finding_id" => finding["id"],
        "category" => finding["category"],
        "disposition" => disposition["status"] || "untriaged",
        "affected_files" => finding["affected_files"] || [],
        "changed_surfaces" => get_in(record.metadata, ["changed_surfaces"]) || [],
        "evidence" => finding["evidence"],
        "source_job" => finding["source_job"]
      }
    end)
  end

  defp group_entries(entries, key_fun) do
    entries
    |> Enum.group_by(key_fun)
    |> Map.new(fn {key, grouped} -> {key || "unknown", grouped} end)
  end

  defp group_by_surface(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      surfaces =
        case entry["affected_files"] do
          [] -> entry["changed_surfaces"]
          files -> files
        end

      Enum.map(surfaces, &{&1, entry})
    end)
    |> Enum.group_by(fn {surface, _entry} -> surface end, fn {_surface, entry} -> entry end)
  end

  defp export_markdown(export) do
    [
      "# Symphony Quality-Gate Retrospective Input",
      "",
      "Records: #{export["record_count"]}",
      "",
      "## By Category",
      grouped_markdown(export["groups"]["by_category"]),
      "",
      "## By Disposition",
      grouped_markdown(export["groups"]["by_disposition"]),
      "",
      "## By Surface",
      grouped_markdown(export["groups"]["by_surface"]),
      "",
      "## False-Positive Patterns",
      entries_markdown(export["groups"]["false_positive_patterns"]),
      "",
      "## Follow-Up Candidates",
      entries_markdown(export["groups"]["follow_up_candidates"])
    ]
    |> Enum.join("\n")
  end

  defp grouped_markdown(groups) when map_size(groups) == 0, do: "- None."

  defp grouped_markdown(groups) do
    groups
    |> Enum.sort_by(fn {key, _entries} -> key end)
    |> Enum.map_join("\n", fn {key, entries} ->
      ["### #{key}", entries_markdown(entries)]
      |> Enum.join("\n")
    end)
  end

  defp entries_markdown([]), do: "- None."

  defp entries_markdown(entries) do
    Enum.map_join(entries, "\n", fn entry ->
      files =
        entry
        |> Map.get("affected_files", [])
        |> case do
          [] -> "no files"
          values -> Enum.join(values, ", ")
        end

      "- #{entry["issue_identifier"]} #{entry["record_id"]} #{entry["finding_id"]} [#{entry["disposition"]}] #{files}: #{entry["evidence"]}"
    end)
  end

  defp disposition_counts(disposition) do
    disposition
    |> Map.get("dispositions", [])
    |> Enum.frequencies_by(&(&1["status"] || "untriaged"))
  end

  defp record_files(record_dir) do
    %{
      metadata: Path.join(record_dir, "metadata.json"),
      quality_gate: Path.join(record_dir, "quality_gate.json"),
      findings: Path.join(record_dir, "findings.json"),
      disposition: Path.join(record_dir, "disposition.json"),
      handoff_route: Path.join(record_dir, "handoff_route.json")
    }
  end

  defp write_json(path, payload), do: File.write(path, Jason.encode!(Redaction.json_ready(payload), pretty: true) <> "\n")

  defp write_json_once(path, payload) do
    if File.exists?(path) do
      :ok
    else
      write_json(path, payload)
    end
  end

  defp redact_runtime_payload(payload), do: Redaction.json_ready(payload)

  defp list_value(values) when is_list(values), do: values
  defp list_value(_values), do: []

  defp token(nil), do: ""
  defp token(value) when is_atom(value), do: value |> Atom.to_string() |> token()

  defp token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp token(value), do: value |> to_string() |> token()

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp field(_map, _key, default), do: default

  defp get_in_any(map, paths) do
    Enum.find_value(paths, &get_in_path(map, &1))
  end

  defp get_in_path(map, path) do
    Enum.reduce_while(path, map, &get_in_path_segment/2)
  end

  defp get_in_path_segment(key, acc) do
    case field(acc, key, nil) do
      nil -> {:halt, nil}
      value -> {:cont, value}
    end
  end

  defp fallback(nil, value), do: value
  defp fallback("", value), do: value

  defp fallback(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp fallback(value, _fallback), do: to_string(value)

  defp optional_string(nil), do: nil

  defp optional_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      string -> Redaction.redact_string(string)
    end
  end

  defp sanitize_segment(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim(".-_")
    |> fallback("unknown")
  end

  defp iso8601_or_nil(nil), do: nil
  defp iso8601_or_nil(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601_or_nil(value) when is_binary(value), do: value
  defp iso8601_or_nil(value), do: to_string(value)

  defp iso8601_or_now(nil), do: iso8601_now()
  defp iso8601_or_now(value), do: iso8601_or_nil(value)

  defp iso8601_now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp runtime_string(nil), do: nil

  defp runtime_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      string -> string
    end
  end
end
