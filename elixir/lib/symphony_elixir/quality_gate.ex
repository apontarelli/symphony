defmodule SymphonyElixir.QualityGate do
  @moduledoc """
  Runs host-owned quality-gate reviewer fanout and synthesis.
  """

  alias SymphonyElixir.{AgentRuntime, Config, ExecutionContext, Linear.Issue, SSH}
  alias SymphonyElixir.AgentRuntime.Event
  alias SymphonyElixir.Config.Schema.QualityGate, as: QualityGateSettings
  alias SymphonyElixir.QualityGate.{HostVisualQa, Planner, Synthesis}
  alias SymphonyElixir.ReviewRecords.Redaction

  @type result :: map()
  @review_roles %{
    source_correctness: :source_reviewer,
    test_quality: :test_reviewer,
    scenario_qa: :runtime_qa,
    product_visual_review: :product_visual_review,
    docs_source_of_truth: :docs_reviewer,
    security_data_migration: :security_reviewer
  }
  @browser_review_categories [:scenario_qa, :product_visual_review]
  @browser_preflight_script """
  chrome_path="${BROWSER_QA_CHROME_PATH:-}"
  if [ -n "$chrome_path" ]; then
    if [ -x "$chrome_path" ]; then
      exit 0
    fi
    echo "BROWSER_QA_CHROME_PATH is not executable: $chrome_path" >&2
    exit 1
  fi
  if [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
    exit 0
  fi
  command -v google-chrome >/dev/null 2>&1 && exit 0
  command -v chromium >/dev/null 2>&1 && exit 0
  command -v chromium-browser >/dev/null 2>&1 && exit 0
  command -v chrome >/dev/null 2>&1 && exit 0
  echo "No executable Chrome/Chromium browser found. Set BROWSER_QA_CHROME_PATH or install Google Chrome/Chromium." >&2
  exit 1
  """
  @status_tokens %{
    "blocked" => :blocked,
    "clean" => :passed,
    "failed" => :fix_required,
    "failure" => :fix_required,
    "fix_required" => :fix_required,
    "human_input_required" => :human_input_required,
    "needs_input" => :human_input_required,
    "ok" => :passed,
    "pass" => :passed,
    "passed" => :passed,
    "success" => :passed
  }

  @spec run_context(ExecutionContext.t(), Issue.t(), term()) ::
          result() | {:error, atom()}
  def run_context(%ExecutionContext{} = context, %Issue{} = issue, completion),
    do: run_context(context, issue, completion, [])

  @spec run_context(ExecutionContext.t(), Issue.t(), term(), keyword()) ::
          result() | {:error, atom()}
  def run_context(%ExecutionContext{} = context, %Issue{} = issue, completion, opts)
      when is_map(completion) and is_list(opts) do
    with :ok <- validate_implementation_context(context, issue),
         :ok <- validate_context_options(opts),
         {:ok, settings} <- pinned_quality_gate_settings(context),
         {:ok, provenance} <- ExecutionContext.safe_provenance(context) do
      context.workspace_path
      |> run_gate(
        context.policy,
        issue,
        completion,
        context_run_options(opts, context, settings)
      )
      |> Map.put(:provenance, provenance)
    end
  end

  def run_context(%ExecutionContext{}, %Issue{}, completion, _opts) when not is_map(completion),
    do: {:error, :invalid_quality_gate_completion}

  def run_context(%ExecutionContext{}, %Issue{}, _completion, _opts),
    do: {:error, :invalid_quality_gate_options}

  @doc false
  @spec run_for_test(Path.t() | nil, map(), Issue.t() | map() | nil, term(), keyword()) ::
          result()
  def run_for_test(workspace, policy, issue, completion, opts \\ []) do
    completion = if is_map(completion), do: completion, else: %{}
    opts = Keyword.put_new(opts, :settings, Config.settings!().quality_gate)
    run_gate(workspace, policy, issue, completion, opts)
  end

  defp run_gate(workspace, policy, issue, completion, opts)
       when is_map(completion) and is_list(opts) do
    settings = Keyword.fetch!(opts, :settings)

    runner = Keyword.get(opts, :runner, &default_runner/1)
    browser_preflight = Keyword.get(opts, :browser_preflight, &default_browser_preflight/1)
    host_visual_qa = Keyword.get(opts, :host_visual_qa, &HostVisualQa.run/1)
    worker_host = Keyword.get(opts, :worker_host)
    execution_context = Keyword.get(opts, :execution_context)

    review_context =
      review_context(
        issue,
        policy,
        settings,
        runner,
        browser_preflight,
        host_visual_qa,
        worker_host,
        execution_context
      )

    plan =
      Planner.plan(%{
        workspace: workspace,
        policy: policy,
        issue: issue,
        completion: completion,
        settings: settings
      })

    {current_results, history} = run_review_jobs(plan.jobs, plan, review_context, :initial)
    initial_synthesis = Synthesis.synthesize(current_results)

    {final_results, all_job_results, repair_passes, final_synthesis} =
      run_repair_loop(
        current_results,
        history,
        [],
        initial_synthesis,
        1,
        %{
          plan: plan,
          completion: completion,
          issue: issue,
          policy: policy,
          settings: settings,
          runner: runner,
          browser_preflight: browser_preflight,
          host_visual_qa: host_visual_qa,
          worker_host: worker_host,
          execution_context: execution_context,
          max_attempts: max_repair_passes(settings)
        }
      )

    %{
      status: final_synthesis.status,
      planner: plan_to_map(plan),
      jobs: all_job_results,
      final_jobs: final_results,
      synthesis: final_synthesis,
      repair_passes: repair_passes,
      unresolved_human_review_reasons: final_synthesis.unresolved_human_review_reasons
    }
  end

  @spec normalize_result(term()) :: map() | nil
  def normalize_result(nil), do: nil

  def normalize_result(result) when is_map(result) do
    synthesis = value_at(result, :synthesis)

    result
    |> normalize_nested_map()
    |> Map.put(:status, normalize_status(value_at(result, :status), :blocked))
    |> maybe_put_synthesis(synthesis)
  end

  def normalize_result(_result), do: nil

  @spec check(map() | nil) :: map() | nil
  def check(nil), do: nil

  def check(%{status: status} = quality_gate) do
    %{
      name: "quality_gates",
      status: route_status(status),
      summary: Map.get(quality_gate, :summary) || quality_gate_summary(quality_gate),
      metadata: quality_gate
    }
  end

  @spec review(map() | nil, map()) :: map()
  def review(nil, review), do: review

  def review(%{status: :passed} = quality_gate, review) do
    if missing_review?(review) do
      %{status: :clean, summary: quality_gate_summary(quality_gate), findings: []}
    else
      review
    end
  end

  def review(%{status: :fix_required} = quality_gate, _review) do
    findings =
      quality_gate
      |> quality_gate_findings()
      |> Enum.map(&finding_summary/1)

    %{status: :fix_required, summary: quality_gate_summary(quality_gate), findings: findings}
  end

  def review(%{status: :human_input_required} = quality_gate, _review) do
    %{status: :decision_needed, summary: quality_gate_summary(quality_gate), findings: []}
  end

  def review(_quality_gate, review), do: review

  @spec blocker(map() | nil) :: map() | nil
  def blocker(%{status: status} = quality_gate) when status in [:blocked, :human_input_required] do
    reason =
      quality_gate
      |> unresolved_reasons()
      |> case do
        [] -> quality_gate_summary(quality_gate)
        reasons -> Enum.join(reasons, "; ")
      end

    %{reason: reason, required_action: "Resolve quality-gate blockers before handoff: #{reason}"}
  end

  def blocker(_quality_gate), do: nil

  defp run_repair_loop(
         current_results,
         history,
         repair_passes,
         %{status: :fix_required} = synthesis,
         attempt,
         %{max_attempts: max_attempts} = context
       )
       when attempt <= max_attempts do
    rerun_categories = Synthesis.affected_categories(synthesis, current_results)

    repair_result = run_repair(context, synthesis, attempt)

    if repair_result.status == :passed do
      {next_plan, rerun_categories} =
        repair_rerun_plan(context.plan, context, repair_result, synthesis, current_results)

      rerun_jobs = Enum.filter(next_plan.jobs, &(&1.category in rerun_categories))

      {rerun_results, rerun_history} =
        run_review_jobs(
          rerun_jobs,
          next_plan,
          review_context(
            context.issue,
            context.policy,
            context.settings,
            context.runner,
            context.browser_preflight,
            context.host_visual_qa,
            context.worker_host,
            context.execution_context
          ),
          {:repair, attempt}
        )

      next_results = replace_results(current_results, rerun_results, rerun_categories)
      next_synthesis = Synthesis.synthesize(next_results)

      repair_pass = %{
        attempt: attempt,
        status: next_synthesis.status,
        repair_result: repair_result,
        rerun_categories: rerun_categories,
        rerun_jobs: rerun_results
      }

      run_repair_loop(
        next_results,
        history ++ [repair_result] ++ rerun_history,
        repair_passes ++ [repair_pass],
        next_synthesis,
        attempt + 1,
        Map.put(context, :plan, next_plan)
      )
    else
      final_synthesis = %{
        synthesis
        | status: :blocked,
          unresolved_human_review_reasons: [
            Map.get(repair_result, :blocked_reason) ||
              Map.get(repair_result, :summary) ||
              "repair pass failed"
            | synthesis.unresolved_human_review_reasons
          ]
      }

      repair_pass = %{
        attempt: attempt,
        status: final_synthesis.status,
        repair_result: repair_result,
        rerun_categories: rerun_categories,
        rerun_jobs: []
      }

      {current_results, history ++ [repair_result], repair_passes ++ [repair_pass], final_synthesis}
    end
  end

  defp run_repair_loop(current_results, history, repair_passes, synthesis, _attempt, _context) do
    {current_results, history, repair_passes, synthesis}
  end

  defp repair_rerun_plan(plan, context, repair_result, synthesis, current_results) do
    affected_categories = Synthesis.affected_categories(synthesis, current_results)
    next_plan = replan_after_repair(plan, context, repair_result)
    previous_categories = Enum.map(plan.jobs, & &1.category)

    new_categories =
      next_plan.jobs
      |> Enum.map(& &1.category)
      |> Kernel.--(previous_categories)

    {next_plan, Enum.uniq(affected_categories ++ new_categories)}
  end

  defp replan_after_repair(plan, context, repair_result) do
    case repair_scope_completion(repair_result) do
      nil ->
        plan

      completion ->
        next_plan =
          Planner.plan(%{
            workspace: plan.workspace,
            policy: context.policy,
            issue: context.issue,
            completion: completion,
            settings: context.settings
          })

        if next_plan.changed_files == [] and next_plan.changed_surfaces == [] do
          plan
        else
          next_plan
        end
    end
  end

  defp repair_scope_completion(%{raw_output: payload}) when is_map(payload) do
    nested_completion = value_at(payload, :completion)

    cond do
      scope_completion?(nested_completion) -> nested_completion
      scope_completion?(payload) -> payload
      true -> nil
    end
  end

  defp scope_completion?(completion) when is_map(completion) do
    Enum.any?(
      [
        :change_manifest,
        "change_manifest",
        :changeManifest,
        "changeManifest",
        :changed_files,
        "changed_files",
        :changedFiles,
        "changedFiles",
        :changed_surfaces,
        "changed_surfaces",
        :files,
        "files"
      ],
      &Map.has_key?(completion, &1)
    )
  end

  defp scope_completion?(_completion), do: false

  defp review_context(
         issue,
         policy,
         settings,
         runner,
         browser_preflight,
         host_visual_qa,
         worker_host,
         execution_context
       ) do
    %{
      issue: issue,
      policy: policy,
      settings: settings,
      runner: runner,
      browser_preflight: browser_preflight,
      host_visual_qa: host_visual_qa,
      worker_host: worker_host,
      execution_context: execution_context
    }
  end

  defp run_review_jobs(jobs, plan, context, phase) when is_list(jobs) do
    source_jobs = Enum.filter(jobs, &source_job?/1)
    runtime_jobs = Enum.reject(jobs, &source_job?/1)

    source_results =
      source_jobs
      |> Task.async_stream(
        &run_review_job(&1, plan, context, phase),
        max_concurrency: source_max_concurrency(context.settings),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.zip(source_jobs)
      |> Enum.map(fn
        {{:ok, result}, _job} ->
          result

        {{:exit, reason}, job} ->
          blocked_job_result(job, phase, {:source_job_exit, reason})
      end)

    runtime_results = Enum.map(runtime_jobs, &run_review_job(&1, plan, context, phase))

    results = source_results ++ runtime_results
    {results, results}
  end

  defp run_review_job(job, plan, context, phase) do
    case prepare_review_job(job, plan, context.execution_context) do
      {:ok, prepared_job} ->
        do_run_review_job(prepared_job, plan, context, phase)

      {:error, reason} ->
        blocked_job_result(job, phase, {:invalid_review_context, reason})
    end
  end

  defp prepare_review_job(job, _plan, nil), do: {:ok, job}

  defp prepare_review_job(%{category: category} = job, plan, %ExecutionContext{} = parent) do
    with {:ok, role} <- review_role(category),
         {:ok, child} <-
           ExecutionContext.derive_child(parent, role, profile: Map.fetch!(job, :execution_profile)),
         child = %{child | policy: review_policy_for(job, plan, child.policy, child.runner_name)},
         :ok <- ExecutionContext.validate(child),
         {:ok, provenance} <- ExecutionContext.safe_provenance(child) do
      {:ok,
       job
       |> Map.put(:execution_context, child)
       |> Map.put(:provenance, provenance)}
    end
  end

  defp review_role(category), do: Map.fetch(@review_roles, category)

  defp do_run_review_job(%{execution_mode: :blocked_runtime} = job, _plan, _context, phase) do
    blocked_job_result(job, phase, :runtime_review_blocked_by_policy)
  end

  defp do_run_review_job(%{execution_mode: :isolated_runtime} = job, _plan, _context, phase) do
    blocked_job_result(job, phase, :isolated_runtime_requires_workspace_isolation)
  end

  defp do_run_review_job(%{category: :product_visual_review} = job, plan, context, phase) do
    case maybe_run_host_visual_qa(job, plan, context) do
      {:ok, host_visual_qa} ->
        {job, review_policy} =
          job
          |> attach_host_visual_qa(host_visual_qa)
          |> read_only_review_job(context.policy)

        run_reviewer_job(job, plan, context, phase, review_policy)

      :skip ->
        run_browser_backed_review_job(job, plan, context, phase)

      {:error, reason} ->
        blocked_job_result(job, phase, {:host_visual_qa_failed, reason})
    end
  rescue
    error -> blocked_job_result(job, phase, Exception.message(error))
  catch
    kind, reason -> blocked_job_result(job, phase, {kind, reason})
  end

  defp do_run_review_job(job, plan, context, phase) do
    run_browser_backed_review_job(job, plan, context, phase)
  rescue
    error -> blocked_job_result(job, phase, Exception.message(error))
  catch
    kind, reason -> blocked_job_result(job, phase, {kind, reason})
  end

  defp run_browser_backed_review_job(job, plan, context, phase) do
    case maybe_run_browser_preflight(job, plan, context.browser_preflight, context.worker_host) do
      :ok ->
        run_reviewer_job(job, plan, context, phase, review_policy_for_job(job, plan, context.policy))

      {:error, reason} ->
        blocked_job_result(job, phase, reason)
    end
  end

  defp run_reviewer_job(job, plan, context, phase, review_policy) do
    runner_context =
      %{
        kind: :review,
        job: job,
        plan: plan_to_map(plan),
        issue: context.issue,
        policy: review_policy,
        settings: context.settings,
        workspace: plan.workspace,
        worker_host: context.worker_host,
        phase: phase
      }
      |> maybe_put_execution_context(job)

    runner_context
    |> context.runner.()
    |> normalize_review_result(job, phase)
  end

  defp maybe_run_host_visual_qa(job, plan, context) do
    visual_context =
      %{
        job: job,
        plan: plan_to_map(plan),
        issue: context.issue,
        policy: context.policy,
        settings: context.settings,
        workspace: plan.workspace,
        worker_host: context.worker_host
      }
      |> maybe_put_execution_context(job)

    invoke_host_visual_qa(context.host_visual_qa, visual_context)
    |> normalize_host_visual_qa_result()
  end

  defp maybe_put_execution_context(context, %{execution_context: %ExecutionContext{} = execution_context}),
    do: Map.put(context, :execution_context, execution_context)

  defp maybe_put_execution_context(context, _job), do: context

  defp invoke_host_visual_qa(host_visual_qa, context) when is_function(host_visual_qa, 1) do
    host_visual_qa.(context)
  end

  defp invoke_host_visual_qa(_host_visual_qa, _context), do: {:error, :invalid_host_visual_qa}

  defp normalize_host_visual_qa_result(:skip), do: :skip
  defp normalize_host_visual_qa_result({:ok, payload}) when is_map(payload), do: {:ok, normalize_nested_map(payload)}
  defp normalize_host_visual_qa_result({:error, reason}), do: {:error, reason}
  defp normalize_host_visual_qa_result(other), do: {:error, {:invalid_result, other}}

  defp attach_host_visual_qa(job, host_visual_qa) do
    job
    |> Map.put(:host_visual_qa, host_visual_qa)
    |> Map.update(:prompt, host_visual_qa_prompt(host_visual_qa), fn prompt ->
      [prompt, host_visual_qa_prompt(host_visual_qa)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
    end)
  end

  defp read_only_review_job(
         %{execution_context: %ExecutionContext{} = execution_context} = job,
         _policy
       ) do
    policy = read_only_review_policy(execution_context.policy, execution_context.runner_name)
    execution_context = %{execution_context | policy: policy}
    {Map.put(job, :execution_context, execution_context), policy}
  end

  defp read_only_review_job(job, policy) do
    review_policy = read_only_review_policy(policy, Config.default_runner_name())
    {job, review_policy}
  end

  defp host_visual_qa_prompt(host_visual_qa) do
    encoded =
      case Jason.encode(host_visual_qa, pretty: true) do
        {:ok, json} -> json
        {:error, _reason} -> inspect(host_visual_qa, pretty: true)
      end

    """
    ## Host visual QA artifacts

    A host-owned visual QA command already ran outside the reviewer sandbox. Review these artifacts and checks; do not launch a browser from the reviewer sandbox.

    ```json
    #{encoded}
    ```
    """
    |> String.trim()
  end

  defp review_policy_for_job(
         %{execution_context: %ExecutionContext{} = execution_context},
         _plan,
         _policy
       ),
       do: execution_context.policy

  defp review_policy_for_job(job, plan, policy),
    do: review_policy_for(job, plan, policy, Config.default_runner_name())

  defp review_policy_for(%{category: category}, plan, policy, runner_name)
       when category in @browser_review_categories do
    browser_capable_review_policy(policy, plan.workspace, runner_name)
  end

  defp review_policy_for(_job, _plan, policy, runner_name),
    do: read_only_review_policy(policy, runner_name)

  defp browser_capable_review_policy(policy, workspace, runner_name)
       when is_map(policy) and is_binary(runner_name) do
    runner = policy_runner(policy, runner_name)

    put_policy_runner(
      policy,
      Map.put(
        runner,
        "turn_sandbox_policy",
        browser_capable_turn_sandbox_policy(Map.get(runner, "turn_sandbox_policy"), workspace)
      ),
      runner_name
    )
  end

  defp browser_capable_review_policy(_policy, workspace, runner_name)
       when is_binary(runner_name) do
    put_policy_runner(
      %{},
      %{"turn_sandbox_policy" => browser_capable_turn_sandbox_policy(nil, workspace)},
      runner_name
    )
  end

  defp read_only_review_policy(policy, runner_name)
       when is_map(policy) and is_binary(runner_name) do
    runner = policy_runner(policy, runner_name)
    put_policy_runner(policy, Map.put(runner, "turn_sandbox_policy", read_only_turn_sandbox_policy()), runner_name)
  end

  defp read_only_review_policy(_policy, runner_name) when is_binary(runner_name) do
    put_policy_runner(
      %{},
      %{"turn_sandbox_policy" => read_only_turn_sandbox_policy()},
      runner_name
    )
  end

  defp read_only_turn_sandbox_policy do
    %{"type" => "readOnly", "networkAccess" => true}
  end

  defp browser_capable_turn_sandbox_policy(%{"type" => "dangerFullAccess"} = policy, _workspace), do: policy

  defp browser_capable_turn_sandbox_policy(%{"type" => "workspaceWrite"} = policy, _workspace) do
    Map.put(policy, "networkAccess", true)
  end

  defp browser_capable_turn_sandbox_policy(_policy, workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => Enum.reject([workspace], &is_nil/1),
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => true,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp policy_runner(policy, runner_name) when is_map(policy) and is_binary(runner_name) do
    policy
    |> normalize_policy_keys()
    |> get_in(["runners", runner_name])
    |> case do
      runner when is_map(runner) -> normalize_policy_keys(runner)
      _runner -> %{}
    end
  end

  defp put_policy_runner(policy, runner_policy, runner_name)
       when is_map(policy) and is_map(runner_policy) and is_binary(runner_name) do
    policy = policy |> normalize_policy_keys() |> Map.delete("codex")

    runners =
      case Map.get(policy, "runners") do
        runners when is_map(runners) -> runners
        _runners -> %{}
      end

    Map.put(policy, "runners", Map.put(runners, runner_name, runner_policy))
  end

  defp normalize_policy_keys(value) when is_map(value) do
    Map.new(value, fn {key, field_value} -> {to_string(key), normalize_policy_keys(field_value)} end)
  end

  defp normalize_policy_keys(value) when is_list(value), do: Enum.map(value, &normalize_policy_keys/1)
  defp normalize_policy_keys(value), do: value

  defp maybe_run_browser_preflight(%{category: category}, plan, browser_preflight, worker_host)
       when category in @browser_review_categories do
    browser_preflight
    |> invoke_browser_preflight(%{
      category: category,
      workspace: plan.workspace,
      worker_host: optional_string(worker_host)
    })
    |> normalize_browser_preflight_result()
  end

  defp maybe_run_browser_preflight(_job, _plan, _browser_preflight, _worker_host), do: :ok

  defp invoke_browser_preflight(browser_preflight, context) when is_function(browser_preflight, 1) do
    browser_preflight.(context)
  end

  defp invoke_browser_preflight(_browser_preflight, _context), do: {:error, :invalid_browser_preflight}

  defp normalize_browser_preflight_result(:ok), do: :ok
  defp normalize_browser_preflight_result({:ok, _metadata}), do: :ok
  defp normalize_browser_preflight_result({:error, reason}), do: {:error, {:browser_preflight_failed, reason}}
  defp normalize_browser_preflight_result(other), do: {:error, {:browser_preflight_failed, {:invalid_result, other}}}

  defp default_browser_preflight(%{worker_host: worker_host}) when is_binary(worker_host) do
    case SSH.run(worker_host, @browser_preflight_script, stderr_to_stdout: true) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:chrome_unavailable_on_worker, worker_host, status, compact_output(output)}}
      {:error, reason} -> {:error, {:worker_browser_preflight_unavailable, worker_host, reason}}
    end
  end

  defp default_browser_preflight(_context) do
    case System.cmd("/bin/sh", ["-lc", @browser_preflight_script], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:chrome_unavailable, status, compact_output(output)}}
    end
  end

  defp compact_output(output) when is_binary(output) do
    output
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp run_repair(context, synthesis, attempt) do
    runner_context = %{
      kind: :repair,
      attempt: attempt,
      plan: plan_to_map(context.plan),
      issue: context.issue,
      policy: context.policy,
      settings: context.settings,
      workspace: context.plan.workspace,
      worker_host: context.worker_host,
      execution_context: context.execution_context,
      synthesis: synthesis,
      prompt: repair_prompt(context.plan, synthesis, attempt)
    }

    runner_context
    |> context.runner.()
    |> normalize_repair_result(attempt)
  rescue
    error -> blocked_repair_result(attempt, Exception.message(error))
  catch
    kind, reason -> blocked_repair_result(attempt, {kind, reason})
  end

  defp default_runner(
         %{
           kind: :review,
           execution_context: %ExecutionContext{} = context,
           job: job,
           issue: issue
         } = runner_context
       ) do
    run_codex(context, job.prompt, issue, Map.get(runner_context, :adapter_registry))
  end

  defp default_runner(
         %{
           kind: :repair,
           execution_context: %ExecutionContext{} = context,
           prompt: prompt,
           issue: issue
         } = runner_context
       ) do
    run_codex(context, prompt, issue, Map.get(runner_context, :adapter_registry))
  end

  defp run_codex(%ExecutionContext{} = context, prompt, issue, adapter_registry) do
    opts_base =
      []
      |> maybe_put_adapter_registry(adapter_registry)

    run_codex_attempt(
      context,
      prompt,
      issue,
      opts_base,
      1,
      context.max_retries + 1
    )
  end

  defp run_codex_attempt(%ExecutionContext{} = context, prompt, issue, opts_base, attempt, max_attempts) do
    caller = self()
    ref = make_ref()

    on_event = fn event ->
      send(caller, {ref, event})
      :ok
    end

    opts = Keyword.put(opts_base, :on_event, on_event)

    case AgentRuntime.run(context, prompt, issue, opts) do
      {:ok, session} ->
        completion = quality_gate_completion(drain_messages(ref))

        if is_map(completion) do
          {:ok, completion |> Map.put(:session_id, session[:session_id]) |> Map.put(:attempt, attempt)}
        else
          {:ok,
           %{
             status: :blocked,
             blocked_reason: :reviewer_output_missing,
             summary: "Reviewer completed without structured quality_gate_reviewer output.",
             session_id: session[:session_id],
             attempt: attempt,
             findings: []
           }}
        end

      {:error, _reason} when attempt < max_attempts ->
        drain_messages(ref)
        run_codex_attempt(context, prompt, issue, opts_base, attempt + 1, max_attempts)

      {:error, reason} ->
        drain_messages(ref)

        {:ok,
         %{
           status: :blocked,
           blocked_reason: reason,
           summary: "Reviewer could not complete.",
           attempt: attempt,
           findings: []
         }}
    end
  end

  @doc false
  @spec quality_gate_completion_for_test([Event.t()]) :: map() | nil
  def quality_gate_completion_for_test(messages), do: quality_gate_completion(messages)

  defp drain_messages(ref, acc \\ []) do
    receive do
      {^ref, message} -> drain_messages(ref, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp quality_gate_completion(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn message ->
      message
      |> completion_from_message()
      |> reviewer_completion()
    end)
  end

  defp completion_from_message(%Event{payload: %{payload: payload}}) when is_map(payload), do: completion_from_payload(payload)
  defp completion_from_message(%Event{payload: payload}) when is_map(payload), do: completion_from_payload(payload)

  defp completion_from_payload(payload) when is_map(payload) do
    map_at_path(payload, ["params", "completion"]) ||
      map_at_path(payload, ["params", "turn", "completion"])
  end

  defp reviewer_completion(completion) when is_map(completion) do
    completion
    |> value_at(:quality_gate_reviewer)
    |> case do
      reviewer when is_map(reviewer) -> reviewer
      _ -> completion
    end
  end

  defp reviewer_completion(_completion), do: nil

  defp map_at_path(map, path) do
    Enum.reduce_while(path, map, fn key, acc ->
      case value_at(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp normalize_review_result({:ok, payload}, job, phase) when is_map(payload), do: review_result(payload, job, phase)
  defp normalize_review_result({:error, reason}, job, phase), do: blocked_job_result(job, phase, reason)
  defp normalize_review_result(payload, job, phase) when is_map(payload), do: review_result(payload, job, phase)
  defp normalize_review_result(other, job, phase), do: blocked_job_result(job, phase, {:invalid_reviewer_output, other})

  defp review_result(payload, job, phase) do
    result =
      %{
        id: "#{job.id}:#{phase_label(phase)}",
        category: job.category,
        status: normalize_status(value_at(payload, :status), :blocked),
        execution: :executed,
        required?: job.required?,
        phase: phase,
        execution_profile: job.execution_profile,
        isolation: job.isolation,
        summary: optional_string(value_at(payload, :summary)),
        findings: normalize_findings(value_at(payload, :findings)),
        raw_output: payload
      }
      |> maybe_put_job_provenance(job)

    case Map.get(job, :host_visual_qa) do
      host_visual_qa when is_map(host_visual_qa) -> Map.put(result, :host_visual_qa, host_visual_qa)
      _host_visual_qa -> result
    end
  end

  defp blocked_job_result(job, phase, reason) do
    reason = blocked_reason(reason)

    %{
      id: "#{Map.get(job, :id, "review")}:#{phase_label(phase)}",
      category: Map.get(job, :category, :review),
      status: :blocked,
      execution: :blocked,
      required?: Map.get(job, :required?, true),
      phase: phase,
      execution_profile: Map.get(job, :execution_profile),
      isolation: Map.get(job, :isolation),
      blocked_reason: reason,
      summary: "Reviewer job blocked: #{reason}",
      findings: [],
      raw_output: %{}
    }
    |> maybe_put_job_provenance(job)
  end

  defp maybe_put_job_provenance(result, %{provenance: provenance}) when is_map(provenance),
    do: Map.put(result, :provenance, provenance)

  defp maybe_put_job_provenance(result, _job), do: result

  defp normalize_repair_result({:ok, payload}, attempt) when is_map(payload), do: repair_result(payload, attempt)
  defp normalize_repair_result({:error, reason}, attempt), do: blocked_repair_result(attempt, reason)
  defp normalize_repair_result(payload, attempt) when is_map(payload), do: repair_result(payload, attempt)
  defp normalize_repair_result(other, attempt), do: blocked_repair_result(attempt, {:invalid_repair_output, other})

  defp repair_result(payload, attempt) do
    %{
      id: "repair:#{attempt}",
      kind: :repair,
      attempt: attempt,
      status: normalize_status(value_at(payload, :status), :blocked),
      summary: optional_string(value_at(payload, :summary)),
      raw_output: payload
    }
  end

  defp blocked_repair_result(attempt, reason) do
    reason = blocked_reason(reason)

    %{
      id: "repair:#{attempt}",
      kind: :repair,
      attempt: attempt,
      status: :blocked,
      blocked_reason: reason,
      summary: "Repair pass blocked: #{reason}",
      raw_output: %{}
    }
  end

  defp blocked_reason(reason) do
    reason
    |> inspect()
    |> Redaction.redact_string()
  end

  defp replace_results(current_results, rerun_results, rerun_categories) do
    current_results
    |> Enum.reject(&(Map.get(&1, :category) in rerun_categories))
    |> Kernel.++(rerun_results)
  end

  defp source_job?(%{execution_mode: mode}), do: mode in [:parallel_source, :serialized_source]

  defp source_max_concurrency(%{source_max_concurrency: value}) when is_integer(value) and value > 0, do: value
  defp source_max_concurrency(_settings), do: 3

  defp max_repair_passes(%{max_repair_passes: value}) when is_integer(value) and value >= 0, do: value
  defp max_repair_passes(_settings), do: 1

  defp plan_to_map(%Planner.Plan{} = plan) do
    %{
      status: plan.status,
      workspace: plan.workspace,
      changed_files: plan.changed_files,
      changed_surfaces: plan.changed_surfaces,
      jobs: plan.jobs,
      metadata: plan.metadata
    }
  end

  defp repair_prompt(plan, synthesis, attempt) do
    """
    Role: You are implementing repair pass #{attempt} for the Symphony quality gate.

    Goal: Resolve only the fix-required findings below without expanding the ticket.

    Success criteria:
    - Each finding is fixed at its source or reported with an exact blocker.
    - Relevant validation passes after the changes.
    - Structured completion evidence lists changed files, validation, and any blocker.

    Changed files:
    #{bullet_list(plan.changed_files)}

    Findings:
    #{finding_list(synthesis.findings)}
    """
  end

  defp finding_list(findings) do
    Enum.map_join(findings, "\n", fn finding ->
      "- #{finding.category}/#{finding.severity}: #{finding.evidence}"
    end)
  end

  defp bullet_list([]), do: "- None supplied."
  defp bullet_list(items), do: Enum.map_join(items, "\n", &"- #{&1}")

  defp normalize_findings(findings) when is_list(findings), do: findings
  defp normalize_findings(_findings), do: []

  defp normalize_nested_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      normalized_key =
        if is_atom(key) do
          Atom.to_string(key)
        else
          to_string(key)
        end

      {normalized_key, normalize_nested_map(value)}
    end)
  end

  defp normalize_nested_map(value) when is_list(value), do: Enum.map(value, &normalize_nested_map/1)
  defp normalize_nested_map(value), do: value

  defp maybe_put_synthesis(result, synthesis) when is_map(synthesis) do
    Map.put(result, :synthesis, normalize_nested_map(synthesis))
  end

  defp maybe_put_synthesis(result, _synthesis), do: result

  defp normalize_status(value, default) when is_atom(value), do: normalize_status(Atom.to_string(value), default)

  defp normalize_status(value, default) when is_binary(value) do
    Map.get(@status_tokens, value |> String.trim() |> String.downcase(), default)
  end

  defp normalize_status(_value, default), do: default

  defp route_status(:human_input_required), do: :blocked
  defp route_status(status), do: status

  defp quality_gate_summary(quality_gate) do
    synthesis = value_at(quality_gate, :synthesis)

    case value_at(synthesis, :summary) do
      summary when is_binary(summary) ->
        summary

      _ ->
        case value_at(quality_gate, :status) do
          :passed -> "Quality gate passed."
          :fix_required -> "Quality gate requires fixes."
          :blocked -> "Quality gate blocked."
          :human_input_required -> "Quality gate requires human input."
          status -> "Quality gate status: #{status}."
        end
    end
  end

  defp quality_gate_findings(quality_gate) do
    synthesis = value_at(quality_gate, :synthesis)

    cond do
      is_list(value_at(synthesis, :findings)) -> value_at(synthesis, :findings)
      is_list(value_at(quality_gate, :findings)) -> value_at(quality_gate, :findings)
      true -> []
    end
  end

  defp finding_summary(finding) when is_map(finding) do
    finding
    |> value_at(:evidence)
    |> optional_string()
    |> case do
      nil -> inspect(finding)
      summary -> summary
    end
  end

  defp finding_summary(finding), do: to_string(finding)

  defp unresolved_reasons(quality_gate) do
    synthesis = value_at(quality_gate, :synthesis)

    reasons =
      value_at(quality_gate, :unresolved_human_review_reasons) ||
        value_at(synthesis, :unresolved_human_review_reasons)

    if is_list(reasons) do
      Enum.map(reasons, &to_string/1)
    else
      []
    end
  end

  defp missing_review?(review) when is_map(review) do
    status = value_at(review, :status)
    status in [nil, :unknown, "unknown"]
  end

  defp missing_review?(_review), do: true

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

  defp phase_label(:initial), do: "initial"
  defp phase_label({:repair, attempt}), do: "repair_#{attempt}"

  defp value_at(nil, _key), do: nil
  defp value_at(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp value_at(_value, _key), do: nil

  defp validate_implementation_context(%ExecutionContext{role: :implementation} = context, %Issue{} = issue) do
    with :ok <- ExecutionContext.validate(context),
         true <- context.issue_id == issue.id,
         true <- context.issue_identifier == issue.identifier do
      :ok
    else
      _invalid -> {:error, :invalid_quality_gate_context}
    end
  end

  defp validate_implementation_context(_context, _issue),
    do: {:error, :invalid_quality_gate_context}

  defp validate_context_options(opts) do
    allowed = [:adapter_registry, :browser_preflight, :host_visual_qa, :runner]

    if Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         Enum.all?(Keyword.keys(opts), &(&1 in allowed)),
       do: :ok,
       else: {:error, :invalid_quality_gate_options}
  end

  defp context_run_options(opts, context, settings) do
    adapter_registry = Keyword.get(opts, :adapter_registry)

    opts
    |> Keyword.delete(:adapter_registry)
    |> Keyword.put_new(:runner, fn runner_context ->
      runner_context
      |> maybe_put_runner_adapter_registry(adapter_registry)
      |> default_runner()
    end)
    |> Keyword.put(:settings, settings)
    |> Keyword.put(:worker_host, context.worker_host)
    |> Keyword.put(:execution_context, context)
  end

  defp maybe_put_runner_adapter_registry(runner_context, adapter_registry)
       when is_map(adapter_registry),
       do: Map.put(runner_context, :adapter_registry, adapter_registry)

  defp maybe_put_runner_adapter_registry(runner_context, _adapter_registry),
    do: runner_context

  defp maybe_put_adapter_registry(opts, adapter_registry) when is_map(adapter_registry),
    do: Keyword.put(opts, :adapter_registry, adapter_registry)

  defp maybe_put_adapter_registry(opts, _adapter_registry), do: opts

  defp pinned_quality_gate_settings(%ExecutionContext{} = context) do
    attrs =
      get_in(context.target.repo_policy, ["manifest", "quality_gate"])
      |> case do
        value when is_map(value) -> value
        nil -> %{}
        _invalid -> :invalid
      end

    case attrs do
      :invalid ->
        {:error, :invalid_quality_gate_settings}

      attrs ->
        %QualityGateSettings{}
        |> QualityGateSettings.changeset(attrs)
        |> Ecto.Changeset.apply_action(:validate)
        |> case do
          {:ok, settings} -> {:ok, settings}
          {:error, _changeset} -> {:error, :invalid_quality_gate_settings}
        end
    end
  end
end
