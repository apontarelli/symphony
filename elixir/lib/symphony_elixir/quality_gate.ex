defmodule SymphonyElixir.QualityGate do
  @moduledoc """
  Runs host-owned quality-gate reviewer fanout and synthesis.
  """

  alias SymphonyElixir.Codex.{AppServer, ExecutionProfile}
  alias SymphonyElixir.{Config, Linear.Issue, SSH}
  alias SymphonyElixir.QualityGate.{Planner, Synthesis}

  @type result :: map()
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

  @spec run(Path.t() | nil, map(), Issue.t() | map() | nil, term()) :: result()
  def run(workspace, policy, issue, completion), do: run(workspace, policy, issue, completion, [])

  @spec run(Path.t() | nil, map(), Issue.t() | map() | nil, term(), keyword()) :: result()
  def run(workspace, policy, issue, completion, opts) when is_map(completion) and is_list(opts) do
    settings = Keyword.get(opts, :settings, Config.settings!().quality_gate)
    runner = Keyword.get(opts, :runner, &default_runner/1)
    browser_preflight = Keyword.get(opts, :browser_preflight, &default_browser_preflight/1)
    worker_host = Keyword.get(opts, :worker_host)
    review_context = review_context(issue, policy, settings, runner, browser_preflight, worker_host)

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
          worker_host: worker_host,
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

  def run(workspace, policy, issue, _completion, opts) do
    run(workspace, policy, issue, %{}, opts)
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

    repair_result =
      run_repair(
        context.plan,
        context.issue,
        context.policy,
        context.settings,
        context.runner,
        synthesis,
        attempt
      )

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
            context.worker_host
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

  defp review_context(issue, policy, settings, runner, browser_preflight, worker_host) do
    %{
      issue: issue,
      policy: policy,
      settings: settings,
      runner: runner,
      browser_preflight: browser_preflight,
      worker_host: worker_host
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

  defp run_review_job(%{execution_mode: :blocked_runtime} = job, _plan, _context, phase) do
    blocked_job_result(job, phase, :runtime_review_blocked_by_policy)
  end

  defp run_review_job(%{execution_mode: :isolated_runtime} = job, _plan, _context, phase) do
    blocked_job_result(job, phase, :isolated_runtime_requires_workspace_isolation)
  end

  defp run_review_job(job, plan, context, phase) do
    case maybe_run_browser_preflight(job, plan, context.browser_preflight, context.worker_host) do
      :ok ->
        review_policy = review_policy_for(job, plan, context.policy)

        runner_context = %{
          kind: :review,
          job: job,
          plan: plan_to_map(plan),
          issue: context.issue,
          policy: review_policy,
          settings: context.settings,
          workspace: plan.workspace,
          phase: phase
        }

        runner_context
        |> context.runner.()
        |> normalize_review_result(job, phase)

      {:error, reason} ->
        blocked_job_result(job, phase, reason)
    end
  rescue
    error -> blocked_job_result(job, phase, Exception.message(error))
  catch
    kind, reason -> blocked_job_result(job, phase, {kind, reason})
  end

  defp review_policy_for(%{category: category}, plan, policy) when category in @browser_review_categories do
    browser_capable_review_policy(policy, plan.workspace)
  end

  defp review_policy_for(_job, _plan, policy), do: read_only_review_policy(policy)

  defp browser_capable_review_policy(policy, workspace) when is_map(policy) do
    codex = policy_codex(policy)

    Map.put(
      policy,
      "codex",
      Map.put(codex, "turn_sandbox_policy", browser_capable_turn_sandbox_policy(Map.get(codex, "turn_sandbox_policy"), workspace))
    )
  end

  defp browser_capable_review_policy(_policy, workspace) do
    %{"codex" => %{"turn_sandbox_policy" => browser_capable_turn_sandbox_policy(nil, workspace)}}
  end

  defp read_only_review_policy(policy) when is_map(policy) do
    codex = policy_codex(policy)

    Map.put(policy, "codex", Map.put(codex, "turn_sandbox_policy", read_only_turn_sandbox_policy()))
  end

  defp read_only_review_policy(_policy) do
    %{"codex" => %{"turn_sandbox_policy" => read_only_turn_sandbox_policy()}}
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

  defp policy_codex(policy) when is_map(policy) do
    case Map.get(policy, "codex", Map.get(policy, :codex, %{})) do
      codex when is_map(codex) -> normalize_policy_keys(codex)
      _codex -> %{}
    end
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

  defp run_repair(plan, issue, policy, settings, runner, synthesis, attempt) do
    context = %{
      kind: :repair,
      attempt: attempt,
      plan: plan_to_map(plan),
      issue: issue,
      policy: policy,
      settings: settings,
      workspace: plan.workspace,
      synthesis: synthesis,
      prompt: repair_prompt(plan, synthesis, attempt)
    }

    context
    |> runner.()
    |> normalize_repair_result(attempt)
  rescue
    error -> blocked_repair_result(attempt, Exception.message(error))
  catch
    kind, reason -> blocked_repair_result(attempt, {kind, reason})
  end

  defp default_runner(%{kind: :review, workspace: workspace, job: job, policy: policy, issue: issue, settings: settings})
       when is_binary(workspace) do
    run_codex(workspace, job.prompt, issue, policy, job.execution_profile, settings)
  end

  defp default_runner(%{kind: :review}) do
    {:ok, %{status: :blocked, blocked_reason: :workspace_unavailable, findings: []}}
  end

  defp default_runner(%{kind: :repair, workspace: workspace, prompt: prompt, policy: policy, issue: issue, settings: settings})
       when is_binary(workspace) do
    run_codex(workspace, prompt, issue, policy, "implementation", settings)
  end

  defp run_codex(workspace, prompt, issue, policy, execution_profile, _settings) do
    profile = ExecutionProfile.resolve(Config.settings!(), execution_profile)

    opts_base = [
      policy: policy,
      execution_profile: execution_profile,
      turn_timeout_ms: profile.timeout_ms
    ]

    run_codex_attempt(
      workspace,
      prompt,
      issue || %Issue{identifier: "QUALITY-GATE", title: "Quality gate review"},
      opts_base,
      1,
      max_codex_attempts(profile)
    )
  end

  defp run_codex_attempt(workspace, prompt, issue, opts_base, attempt, max_attempts) do
    caller = self()
    ref = make_ref()

    on_message = fn message ->
      send(caller, {ref, message})
      :ok
    end

    opts = Keyword.put(opts_base, :on_message, on_message)

    case AppServer.run(workspace, prompt, issue, opts) do
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
        run_codex_attempt(workspace, prompt, issue, opts_base, attempt + 1, max_attempts)

      {:error, reason} ->
        {:ok,
         %{
           status: :blocked,
           blocked_reason: {:codex_app_server_unavailable, reason},
           attempt: attempt,
           findings: []
         }}
    end
  end

  defp max_codex_attempts(%{max_retries: max_retries}) when is_integer(max_retries) and max_retries > 0 do
    max_retries + 1
  end

  defp max_codex_attempts(_profile), do: 1

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

  defp completion_from_message(%{payload: payload}) when is_map(payload), do: completion_from_payload(payload)
  defp completion_from_message(_message), do: nil

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
  end

  defp blocked_job_result(job, phase, reason) do
    %{
      id: "#{Map.get(job, :id, "review")}:#{phase_label(phase)}",
      category: Map.get(job, :category, :review),
      status: :blocked,
      execution: :blocked,
      required?: Map.get(job, :required?, true),
      phase: phase,
      execution_profile: Map.get(job, :execution_profile),
      isolation: Map.get(job, :isolation),
      blocked_reason: inspect(reason),
      summary: "Reviewer job blocked: #{inspect(reason)}",
      findings: [],
      raw_output: %{}
    }
  end

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
    %{
      id: "repair:#{attempt}",
      kind: :repair,
      attempt: attempt,
      status: :blocked,
      blocked_reason: inspect(reason),
      summary: "Repair pass blocked: #{inspect(reason)}",
      raw_output: %{}
    }
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
    Repair pass #{attempt} for the Symphony quality gate.

    Address only the fix-required findings below, then return structured completion evidence.

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
end
