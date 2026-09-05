defmodule SymphonyElixir.OperatorInterfaceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{OperatorInterface, OperatorLogHandler, OperatorSnapshot}

  test "complete snapshot preserves ordering, versions, explicit availability, and redaction" do
    now = ~U[2026-09-04 20:00:00.000Z]
    secret = "operator-contract-secret"

    host = %{
      counts: %{agents: 1, startups: 1, reviewers: 0, polls: 1},
      limits: %{agents: 3, startups: 2, reviewers: 2, polls: %{max_concurrent: 2}},
      registry: %{generation: "sha256:generation", verified?: true, error: nil},
      targets: %{
        "beta" => target_snapshot("beta", :paused),
        "alpha" =>
          target_snapshot("alpha", :active)
          |> put_in([:operator, :policy_hash], "secret://operator/policy")
      }
    }

    runtime_results = %{
      "alpha" =>
        {:current,
         %{
           pending_queue_observed_at: now,
           pending_queue: [
             %{
               position: 1,
               issue_id: "issue-2",
               issue_identifier: "SID-2",
               state: "Todo",
               priority: 1,
               status: :waiting,
               reason: :target_agent_capacity
             },
             %{
               position: 2,
               issue_id: "issue-1",
               issue_identifier: "SID-1",
               state: "Todo",
               priority: 2,
               status: :waiting,
               reason: :linear_state_capacity
             }
           ],
           running: [
             %{
               target_id: "alpha",
               issue_id: "issue-1",
               attempt: 1,
               adapter: %{kind: "codex", diagnostics: %{command: ["--api-key", secret]}},
               workspace_path: "/tmp/password=#{secret}",
               worker_host: "local",
               started_at: now,
               last_runtime_progress_timestamp: now,
               last_runtime_timestamp: now,
               last_runtime_event: :turn_progress,
               last_runtime_message: %{message: %{prompt: secret}}
             }
           ],
           retrying: [],
           blocked: [],
           handoff_routes: [
             %{issue_id: "issue-1", route: "auto_land", target_state: "Merging", summary: secret}
           ],
           landing_queue: [
             %{issue_id: "issue-1", status: :selected, position: 1, blocked_reasons: [], wait_ms: 0}
           ]
         }},
      "beta" => {:unavailable, nil}
    }

    durable_runs =
      {:current,
       [
         %{
           admitted_run_id: "run-1",
           target_id: "alpha",
           tracker_issue_id: "issue-1",
           issue_identifier: "SID-1",
           lifecycle_state: "running",
           lifecycle_sequence: 2,
           owner_id: "owner-1",
           lease_expires_at_ms: 123,
           fencing_generation: 3,
           retry_attempt: nil,
           retry_due_at_ms: nil,
           blocked_reason: "api_key=#{secret}",
           reconciliation_status: "clear",
           terminal_at: nil,
           updated_at: DateTime.to_iso8601(now)
         }
       ]}

    marker = %{
      host_id: "host-contract",
      started_at: DateTime.to_iso8601(now),
      cursor: 41,
      interface_version: 1,
      schema_version: 1
    }

    snapshot =
      OperatorSnapshot.project(
        {:current, host},
        runtime_results,
        durable_runs,
        {:unavailable, nil},
        marker,
        now
      )

    assert snapshot.interface_version == 1
    assert snapshot.schema_version == 1
    assert snapshot.snapshot == %{mode: "complete", replacement_required: false, event_cursor: 41}
    assert snapshot.host.id == "host-contract"
    assert snapshot.host.registry == %{status: "verified", generation: "sha256:generation", verified: true, error: nil}
    assert Enum.map(snapshot.targets, & &1.target_id) == ["alpha", "beta"]
    assert snapshot.aggregate.capacity.used.agents == 1
    assert snapshot.aggregate.capacity.limits.agents == 3

    alpha = Enum.find(snapshot.targets, &(&1.target_id == "alpha"))
    beta = Enum.find(snapshot.targets, &(&1.target_id == "beta"))

    assert Enum.map(alpha.queue.entries, & &1.issue_identifier) == ["SID-2", "SID-1"]
    assert alpha.queue.status == "current"
    assert alpha.budget.status == "unavailable"
    assert beta.runtime == %{status: "unavailable", counts: nil}
    assert beta.queue == %{status: "unavailable", observed_at: nil, entries: []}
    assert snapshot.freshness.status == "partial"
    assert alpha.repository.path == "/tmp/alpha"
    assert alpha.policy_hash == "<redacted:secret-reference>"

    run = List.first(snapshot.runs.entries)
    assert run.stage == %{name: "landing", status: "selected"}
    assert run.execution.last_event == %{type: "turn_progress", at: DateTime.to_iso8601(now)}
    assert run.execution.workspace == "/tmp/password=<redacted:secret>"
    assert run.handoff_state == %{status: "recorded", route: "auto_land", target_state: "Merging"}
    assert run.landing_state == %{status: "selected", position: 1, reasons: [], wait_ms: 0}
    assert run.cleanup_state == %{status: "not_applicable"}
    assert Enum.find(run.commands, &(&1.action == "abandon")).available
    refute Enum.find(run.commands, &(&1.action == "resume")).available

    encoded = Jason.encode!(snapshot)
    refute encoded =~ secret
    refute encoded =~ "last_runtime_message"
    refute encoded =~ "prompt"
    refute encoded =~ "--api-key"

    failed_snapshot =
      OperatorSnapshot.project(
        {:current, host},
        %{"alpha" => {:timeout, nil}, "beta" => {:unavailable, nil}},
        durable_runs,
        {:unavailable, nil},
        marker,
        now
      )

    assert [failed_run] = failed_snapshot.runs.entries
    assert failed_run.execution.status == "timeout"
    assert failed_run.handoff_state.status == "timeout"
    assert failed_run.landing_state.status == "timeout"
  end

  test "stale queue data remains visible and labeled stale" do
    now = ~U[2026-09-04 20:10:00.000Z]

    host = %{
      counts: %{agents: 0, startups: 0, reviewers: 0, polls: 0},
      limits: %{agents: 4, startups: 2, reviewers: 2, polls: %{max_concurrent: 2}},
      registry: %{generation: "sha256:generation", verified?: true, error: nil},
      targets: %{"alpha" => target_snapshot("alpha", :active)}
    }

    snapshot =
      OperatorSnapshot.project(
        {:current, host},
        %{
          "alpha" =>
            {:current,
             %{
               pending_queue_observed_at: ~U[2026-09-04 20:00:00.000Z],
               pending_queue: [
                 %{
                   position: 1,
                   issue_id: "issue-1",
                   issue_identifier: "SID-1",
                   state: "Todo",
                   priority: 1,
                   status: :waiting,
                   reason: :target_agent_capacity
                 }
               ],
               running: [],
               retrying: [],
               blocked: [],
               handoff_routes: [],
               landing_queue: []
             }}
        },
        {:current, []},
        {:current, []},
        %{
          host_id: "host-stale",
          started_at: DateTime.to_iso8601(now),
          cursor: 0,
          interface_version: 1,
          schema_version: 1
        },
        now
      )

    assert [target] = snapshot.targets
    assert target.queue.status == "stale"
    assert [%{issue_identifier: "SID-1"}] = target.queue.entries
    assert Enum.any?(snapshot.warnings, &(&1.code == "queue_stale"))
    assert snapshot.freshness.status == "partial"
  end

  test "unavailable scheduler remains an explicit complete replacement" do
    now = ~U[2026-09-04 20:00:00.000Z]

    snapshot =
      OperatorSnapshot.project(
        {:timeout, nil},
        %{},
        {:unavailable, nil},
        {:unavailable, nil},
        %{
          host_id: "host-timeout",
          started_at: DateTime.to_iso8601(now),
          cursor: 7,
          interface_version: 1,
          schema_version: 1
        },
        now
      )

    assert snapshot.host.status == "timeout"
    assert snapshot.host.capacity == %{status: "timeout", used: nil, limits: nil}
    assert snapshot.aggregate.counts == %{status: "timeout", queued: nil, running: nil, retrying: nil, blocked: nil}
    assert snapshot.targets == []
    assert snapshot.runs == %{status: "unavailable", entries: []}
    assert snapshot.snapshot == %{mode: "complete", replacement_required: false, event_cursor: 7}
  end

  test "budget states distinguish current, missing, and not configured" do
    now = ~U[2026-09-04 20:00:00.000Z]

    host = %{
      counts: %{agents: 0, startups: 0, reviewers: 0, polls: 0},
      limits: %{agents: 4, startups: 2, reviewers: 2, polls: %{max_concurrent: 2}},
      registry: %{generation: "sha256:generation", verified?: true, error: nil},
      targets: %{
        "alpha" => target_snapshot("alpha", :active),
        "beta" => target_snapshot("beta", :active),
        "gamma" => Map.put(target_snapshot("gamma", :active), :budget_limits, nil)
      }
    }

    runtime_results =
      Map.new(Map.keys(host.targets), fn target_id ->
        {target_id,
         {:current,
          %{
            pending_queue_observed_at: now,
            pending_queue: [],
            running: [],
            retrying: [],
            blocked: [],
            handoff_routes: [],
            landing_queue: []
          }}}
      end)

    snapshot =
      OperatorSnapshot.project(
        {:current, host},
        runtime_results,
        {:current, []},
        {:current,
         [
           %{
             target_id: "alpha",
             reserved_tokens: 50,
             daily_reserved_tokens: 600,
             weekly_reserved_tokens: 700,
             charged_tokens: 100,
             daily_charged_tokens: 500,
             weekly_charged_tokens: 800
           }
         ]},
        %{
          host_id: "host-budgets",
          started_at: DateTime.to_iso8601(now),
          cursor: 0,
          interface_version: 1,
          schema_version: 1
        },
        now
      )

    targets = Map.new(snapshot.targets, &{&1.target_id, &1})
    assert targets["alpha"].budget.status == "current"
    assert targets["alpha"].budget.exhausted
    assert targets["beta"].budget.status == "missing"
    assert targets["gamma"].budget.status == "not_configured"
    assert snapshot.freshness.status == "live"
  end

  test "event cursors are ordered and detect host restart and retained-range gaps" do
    server = unique_name(:events)
    start_supervised!({OperatorInterface, name: server, host_id: "host-a", max_events: 3, install_log_handler: false})

    assert {:ok, %{cursor: 0, host_id: "host-a"}} = OperatorInterface.marker(server)

    OperatorInterface.publish_state_change(server)

    OperatorInterface.publish_runtime_event(server, %{
      target_id: "alpha",
      issue_id: "issue-1",
      issue_identifier: "SID-1",
      admitted_run_id: "run-1",
      event: :turn_started,
      timestamp: ~U[2026-09-04 20:00:00Z],
      payload: %{prompt: "must-not-appear"}
    })

    OperatorInterface.publish_log(server, :info, "api_key=stream-secret prompt=unredacted-input", "Test")

    assert {:ok, events} = OperatorInterface.events(server, "host-a", 0, 2)
    assert Enum.map(events.events, & &1.cursor) == [1, 2]
    assert events.next_cursor == 2
    assert events.latest_cursor == 3
    assert events.truncation.response_limited
    refute events.gap.detected
    refute events.snapshot_replacement.required

    assert {:ok, final_page} = OperatorInterface.events(server, "host-a", 2, 2)
    assert [%{cursor: 3, kind: "log", data: log}] = final_page.events
    assert log.message =~ "<redacted:secret>"
    assert log.message =~ "<redacted:prompt>"
    refute inspect(log) =~ "stream-secret"
    refute inspect(log) =~ "unredacted-input"

    assert {:ok, restarted} = OperatorInterface.events(server, "host-b", 3, 10)
    assert restarted.events == []
    assert restarted.gap == %{detected: true, reason: "host_restarted"}
    assert restarted.snapshot_replacement == %{required: true, reason: "host_restarted"}

    OperatorInterface.publish_state_change(server)
    OperatorInterface.publish_state_change(server)
    OperatorInterface.publish_state_change(server)
    assert {:ok, %{cursor: 6}} = OperatorInterface.marker(server)

    assert {:ok, empty} = OperatorInterface.events(server, "host-a", 6, 10)
    assert empty.events == []
    assert empty.next_cursor == 6

    assert {:ok, ahead} = OperatorInterface.events(server, "host-a", 7, 10)
    assert ahead.gap == %{detected: true, reason: "cursor_ahead"}
    assert ahead.snapshot_replacement.required

    assert {:error, :invalid_cursor} = OperatorInterface.events(server, "", 0, 10)
    assert {:error, :invalid_cursor} = OperatorInterface.events(server, "host-a", -1, 10)
    assert {:error, :invalid_limit} = OperatorInterface.events(server, "host-a", 0, 0)

    assert {:ok, gap} = OperatorInterface.events(server, "host-a", 0, 10)
    assert gap.events == []
    assert gap.gap == %{detected: true, reason: "cursor_before_retention"}
    assert gap.snapshot_replacement.required
    assert gap.truncation.retention_truncated
    assert gap.truncation.dropped_events == 3
    assert gap.first_available_cursor == 4
  end

  test "individual oversized logs carry explicit truncation metadata" do
    server = unique_name(:log_truncation)
    start_supervised!({OperatorInterface, name: server, host_id: "host-log", install_log_handler: false})

    OperatorInterface.publish_log(server, :warning, String.duplicate("x", 5_000), nil)

    assert {:ok, response} = OperatorInterface.events(server, "host-log", 0, 10)
    assert [%{data: %{truncation: %{truncated: true, original_bytes: 5_000}} = data}] = response.events
    assert byte_size(data.message) == 4_096
  end

  test "logger handler publishes a redacted event through its nested config" do
    server = unique_name(:logger_handler)
    start_supervised!({OperatorInterface, name: server, host_id: "host-handler", install_log_handler: false})

    event = %{
      level: :info,
      msg: {:string, ~c"Completed in 1µs secret://operator/token"},
      meta: %{mfa: {__MODULE__, :logger_contract, 0}, time: System.system_time(:microsecond)}
    }

    assert :ok = OperatorLogHandler.log(event, %{config: %{server: server}})
    assert {:ok, response} = OperatorInterface.events(server, "host-handler", 0, 10)

    assert [%{data: log}] = response.events
    assert log.message == "Completed in 1µs <redacted:secret-reference>"
    assert Jason.decode!(Jason.encode!(response))["events"] |> hd() |> get_in(["data", "message"]) == log.message
    assert log.source == "Elixir.SymphonyElixir.OperatorInterfaceTest"
  end

  test "logs redact quoted credentials and every line of a prompt" do
    server = unique_name(:structured_redaction)
    start_supervised!({OperatorInterface, name: server, host_id: "host-safe", install_log_handler: false})

    OperatorInterface.publish_log(
      server,
      :error,
      ~s({"api_key": "private-credential", "prompt": "first\nprivate-prompt"}),
      "Review"
    )

    OperatorLogHandler.log(
      %{
        level: :error,
        msg: {:string, ~s({"api_key": "#{String.duplicate("LARGE_PRIVATE", 2_000)}"})},
        meta: %{}
      },
      %{config: %{server: server}}
    )

    assert {:ok, response} = OperatorInterface.events(server, "host-safe", 0, 10)
    encoded = Jason.encode!(response)
    refute encoded =~ "private-credential"
    refute encoded =~ "private-prompt"
    refute encoded =~ "LARGE_PRIVATE"
  end

  test "raw runtime output and crash reports never enter the retained log text" do
    server = unique_name(:raw_logs)
    start_supervised!({OperatorInterface, name: server, host_id: "host-raw", install_log_handler: false})

    OperatorLogHandler.log(
      %{level: :warning, msg: {:string, "fatal unlabeled-private-prompt"}, meta: %{operator_payload: :unsafe}},
      %{config: %{server: server}}
    )

    OperatorLogHandler.log(
      %{level: :error, msg: {:report, %{reason: "unlabeled-private-credential"}}, meta: %{}},
      %{config: %{server: server}}
    )

    assert {:ok, response} = OperatorInterface.events(server, "host-raw", 0, 10)
    assert Enum.map(response.events, & &1.data.level) == ["warning", "error"]
    encoded = Jason.encode!(response)
    refute encoded =~ "unlabeled-private-prompt"
    refute encoded =~ "unlabeled-private-credential"
  end

  test "leased runs cannot advertise an operator action until the lease expires" do
    run = %{
      owner_id: "runtime-owner",
      lifecycle_state: "blocked",
      reconciliation_status: "clear",
      lease_expires_at_ms: System.system_time(:millisecond) + 60_000
    }

    commands = SymphonyElixir.ControlPlane.operator_action_availability(run)
    assert Enum.all?(commands, &(&1.available == false and &1.disabled_reason == "lease_held"))

    expired_commands =
      run
      |> Map.put(:lease_expires_at_ms, 0)
      |> SymphonyElixir.ControlPlane.operator_action_availability()

    assert Enum.all?(expired_commands, & &1.available)
  end

  defp target_snapshot(target_id, state) do
    %{
      configured_state: state,
      effective_state: state,
      eligibility_reason: if(state == :active, do: :eligible, else: :target_paused),
      generation: "sha256:generation",
      pid: self(),
      counts: %{agents: 0, startups: 0, reviewers: 0},
      limits: %{agents: 2, startups: 1, reviewers: 1},
      budget_limits: %{per_run_tokens: 100, daily_tokens: 1_000, weekly_tokens: 5_000},
      tracker_backoff: %{active: false, remaining_ms: nil},
      operator: %{
        dispatch_mode: :explicit,
        policy_hash: "sha256:policy-#{target_id}",
        repository: %{path: "/tmp/#{target_id}"},
        tracker: %{
          connection_id: "linear-primary",
          kind: "linear",
          scope: %{"type" => "project", "project_slug" => target_id}
        }
      }
    }
  end

  defp unique_name(suffix),
    do: Module.concat(__MODULE__, "#{suffix}_#{System.unique_integer([:positive])}")
end
