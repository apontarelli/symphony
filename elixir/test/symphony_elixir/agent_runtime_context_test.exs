defmodule SymphonyElixir.AgentRuntimeContextTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AgentRuntime, CapabilityPreflight, ExecutionContext, TargetContext}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @hash "sha256:" <> String.duplicate("a", 64)

  defmodule CaptureAdapter do
    @behaviour AgentRuntime

    @impl true
    def start(%ExecutionContext{} = context, issue, []) do
      {:ok, %{context: context, issue: issue}}
    end

    @impl true
    def send_turn(%{context: context}, prompt, issue, opts) do
      if on_event = Keyword.get(opts, :on_event) do
        on_event.(%{event: :captured})
      end

      {:ok,
       %{
         issue_id: issue.id,
         model: context.execution_profile.model || context.runner_config["model"],
         profile: context.execution_profile.name,
         prompt: prompt,
         runner_kind: context.runner_config["kind"],
         runner_name: context.runner_name,
         target_id: context.target.target_id,
         timeout_ms: context.timeout_ms,
         worker_host: context.worker_host
       }}
    end

    @impl true
    def stop(%{context: %ExecutionContext{}}), do: :ok

    @impl true
    def capabilities(runner_config) do
      %{
        adapter: runner_config["kind"],
        model: runner_config["model"],
        pinned: true
      }
    end
  end

  test "concurrent sessions retain distinct pinned runner authority" do
    issue_a = issue("issue-a", "SID-418-A")
    issue_b = issue("issue-b", "SID-418-B")

    context_a =
      execution_context(
        "alpha",
        issue_a,
        "codex",
        runner("codex_app_server", "model-alpha", 11_000, 101),
        worker_host: "alpha.example"
      )

    context_b =
      execution_context(
        "beta",
        issue_b,
        "open",
        runner("opencode_server", "model-beta", 22_000, 202),
        worker_host: "beta.example"
      )

    registry = %{
      "codex_app_server" => CaptureAdapter,
      "opencode_server" => CaptureAdapter
    }

    results =
      [{context_a, issue_a}, {context_b, issue_b}]
      |> Task.async_stream(
        fn {context, issue} ->
          AgentRuntime.run(context, "Pinned prompt", issue, adapter_registry: registry)
        end,
        ordered: true,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    assert [
             %{
               target_id: "alpha",
               runner_name: "codex",
               runner_kind: "codex_app_server",
               model: "model-alpha",
               timeout_ms: 11_000,
               worker_host: "alpha.example"
             },
             %{
               target_id: "beta",
               runner_name: "open",
               runner_kind: "opencode_server",
               model: "model-beta",
               timeout_ms: 22_000,
               worker_host: "beta.example"
             }
           ] = results
  end

  test "review sessions use the pinned child profile" do
    issue = issue("issue-review", "SID-418-REVIEW")
    runner = runner("codex_app_server", "implementation-model", 30_000, 300)
    parent = execution_context("review-target", issue, "codex", runner)

    assert {:ok, child} =
             ExecutionContext.derive_child(parent, :source_reviewer, [])

    registry = %{"codex_app_server" => CaptureAdapter}

    assert {:ok, session} =
             AgentRuntime.start_session(child, issue, adapter_registry: registry)

    assert session.context == child

    assert {:ok, result} =
             AgentRuntime.send_turn(session, "Review", issue)

    assert result.profile == "source_reviewer"
    assert result.model == "source-model-implementation-model"
    assert result.timeout_ms == 3_000
    assert :ok = AgentRuntime.stop_session(session)
  end

  test "context entrypoints reject authority overrides and mismatched issues" do
    issue = issue("issue-strict", "SID-418-STRICT")
    context = execution_context("strict", issue, "codex", runner("codex_app_server", "pinned", 9_000, 90))
    registry = %{"codex_app_server" => CaptureAdapter}

    assert AgentRuntime.start_session(context, issue,
             adapter_registry: registry,
             runner_config: %{"kind" => "opencode_server"}
           ) == {:error, :invalid_agent_runtime_options}

    assert AgentRuntime.capabilities(context,
             adapter_registry: registry,
             settings: :poisoned
           ) == {:error, :invalid_agent_runtime_options}

    assert {:ok, session} =
             AgentRuntime.start_session(context, issue, adapter_registry: registry)

    assert AgentRuntime.send_turn(session, "Prompt", issue, turn_timeout_ms: 1) == {:error, :invalid_agent_runtime_options}

    assert AgentRuntime.send_turn(
             session,
             "Prompt",
             issue("other", "SID-OTHER")
           ) == {:error, :agent_runtime_issue_mismatch}

    assert :ok = AgentRuntime.stop_session(session)
  end

  test "invalid contexts fail before adapter launch without exposing context data" do
    issue = issue("issue-invalid", "SID-418-INVALID")
    context = execution_context("invalid", issue, "codex", runner("codex_app_server", "secret-model", 8_000, 80))
    forged = %{context | runner_name: "missing"}
    registry = %{"codex_app_server" => CaptureAdapter}

    assert AgentRuntime.start_session(forged, issue, adapter_registry: registry) ==
             {:error, :invalid_agent_runtime_context}

    refute inspect(AgentRuntime.start_session(forged, issue, adapter_registry: registry)) =~ "secret-model"

    assert ExecutionContext.validate(:not_a_context) == {:error, :invalid_context}
  end

  test "capability preflight uses pinned target identity, worker, and hook timeout" do
    issue = issue("issue-preflight", "SID-418-PREFLIGHT")

    context =
      execution_context(
        "preflight",
        issue,
        "open",
        runner("opencode_server", "preflight-model", 7_000, 321),
        policy: %{"capabilities" => %{"required" => ["git_metadata"]}},
        worker_host: "worker.example"
      )

    registry = %{"opencode_server" => CaptureAdapter}
    test_pid = self()

    assert %{status: :passed, failures: []} =
             CapabilityPreflight.run(context,
               adapter_registry: registry,
               runner: fn probe ->
                 send(test_pid, {:probe, probe})
                 {:ok, %{status: 0, output: ""}}
               end
             )

    assert_receive {:probe,
                    %{
                      target_id: "preflight",
                      issue_identifier: "SID-418-PREFLIGHT",
                      runner_name: "open",
                      runner_kind: "opencode_server",
                      worker_host: "worker.example",
                      timeout_ms: 321,
                      runner_capabilities: %{
                        adapter: "opencode_server",
                        model: "preflight-model",
                        pinned: true
                      }
                    }}

    assert CapabilityPreflight.run(context,
             adapter_registry: registry,
             timeout_ms: 1
           ) == {:error, :invalid_capability_preflight_options}
  end

  test "capability preflight validates context paths and pinned Codex sandbox policy" do
    issue = issue("issue-capability-context", "SID-418-CAPABILITY")
    codex_runner = runner("codex_app_server", "codex-model", 6_000, 222)

    context =
      execution_context(
        "capability-context",
        issue,
        "codex",
        codex_runner,
        policy: %{"capabilities" => %{"required" => []}}
      )

    assert CapabilityPreflight.run(context) == %{status: :passed, failures: []}

    assert Schema.resolve_pinned_turn_sandbox_policy(:invalid, "/tmp", false) ==
             {:error, {:unsafe_turn_sandbox_policy, :invalid_pinned_authority}}

    tcp_context =
      execution_context(
        "capability-tcp",
        issue,
        "codex",
        codex_runner,
        policy: %{"capabilities" => %{"required" => ["localhost_tcp"]}}
      )

    assert CapabilityPreflight.run(tcp_context, tcp_probe: fn -> :ok end) ==
             %{status: :passed, failures: []}

    assert CapabilityPreflight.run(tcp_context, %{}) ==
             {:error, :invalid_capability_preflight_options}

    forged = %{tcp_context | runner_name: "forged"}

    assert CapabilityPreflight.run(forged, []) ==
             {:error, :invalid_capability_preflight_context}
  end

  test "capability preflight rejects invalid policy and runner authority" do
    issue = issue("issue-capability-errors", "SID-418-CAPABILITY-ERROR")

    invalid_policy_context =
      execution_context(
        "invalid-policy",
        issue,
        "codex",
        runner("codex_app_server", "codex-model", 5_000, 111),
        policy: %{
          "capabilities" => %{"required" => ["localhost_tcp"]},
          "runners" => "invalid"
        }
      )

    assert CapabilityPreflight.run(invalid_policy_context, tcp_probe: fn -> :ok end) ==
             {:error, :invalid_capability_preflight_context}

    unsupported_context =
      execution_context(
        "unsupported-runner",
        issue,
        "custom",
        runner("custom_runtime", "custom-model", 5_000, 111)
      )

    assert CapabilityPreflight.run(unsupported_context,
             adapter_registry: %{"custom_runtime" => CaptureAdapter}
           ) == {:error, :invalid_capability_preflight_context}
  end

  defp execution_context(target_id, issue, runner_name, runner, opts \\ []) do
    root = Path.join(System.tmp_dir!(), "symphony-agent-runtime-context")
    hook_timeout = Keyword.get(opts, :hook_timeout, runner["hook_timeout_ms"])

    target = %TargetContext{
      target_id: target_id,
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: @hash,
      policy_hash: @hash,
      repo_manifest_hash: @hash,
      repo_policy: %{
        "manifest" => %{},
        "manifest_source_dir" => root,
        "workflow_module_resolution" => %{}
      },
      tracker_connection: %{},
      run_target: %{},
      worktree_policy: %{
        "root" => root,
        "strategy" => "per_issue",
        "hooks" => %{
          "after_create" => nil,
          "after_run" => nil,
          "before_remove" => nil,
          "before_run" => nil,
          "timeout_ms" => hook_timeout
        }
      },
      runner_policy: %{
        "default" => runner_name,
        "allowed" => [runner_name],
        "runners" => %{runner_name => runner}
      },
      effective_checks: %{},
      external_side_effect_gates: %{},
      capacity_limits: %{},
      budget_limits: %{}
    }

    policy = Keyword.get(opts, :policy, %{"capabilities" => %{"required" => []}})

    assert {:ok, context} =
             ExecutionContext.new(target, issue,
               policy: policy,
               worker_host: Keyword.get(opts, :worker_host)
             )

    context
  end

  defp issue(id, identifier), do: %Issue{id: id, identifier: identifier}

  defp runner(kind, model, timeout_ms, hook_timeout_ms) do
    %{
      "kind" => kind,
      "command" => if(kind == "codex_app_server", do: ["codex", "app-server"], else: ["opencode", "serve"]),
      "model" => model,
      "read_timeout_ms" => 1_000,
      "startup_timeout_ms" => 1_000,
      "turn_timeout_ms" => timeout_ms,
      "hook_timeout_ms" => hook_timeout_ms,
      "approval_policy" => "never",
      "thread_sandbox" => "workspace-write",
      "turn_sandbox_policy" => %{
        "type" => "workspaceWrite",
        "writableRoots" => ["/tmp"],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => true,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      },
      "execution_profiles" => %{
        "implementation" => %{
          "model" => model,
          "timeout_ms" => timeout_ms,
          "max_retries" => 1
        },
        "source_reviewer" => %{
          "model" => "source-model-#{model}",
          "timeout_ms" => 3_000,
          "max_retries" => 0
        }
      }
    }
  end
end
