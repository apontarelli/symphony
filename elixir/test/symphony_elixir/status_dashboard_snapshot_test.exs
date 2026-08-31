defmodule SymphonyElixir.StatusDashboardSnapshotTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HostScheduler
  alias SymphonyElixir.TestSupport.Snapshot

  defmodule SnapshotServer do
    use GenServer

    def init(snapshot), do: {:ok, snapshot}

    def handle_call(:snapshot, from, {:deferred, recipient, _snapshot} = state) do
      send(recipient, {:snapshot_requested, self(), from})
      {:noreply, state}
    end

    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  test "registry host aggregates target snapshots and ignores unavailable targets" do
    alpha =
      start_snapshot_server(%{
        running: [running_entry(%{identifier: "SID-A", runtime_total_tokens: 12})],
        retrying: [retry_entry(%{identifier: "SID-RETRY-A", due_in_ms: 8_000})],
        runtime_totals: %{input_tokens: 10, output_tokens: 2, total_tokens: 12, seconds_running: 3},
        rate_limits: %{limit_id: "alpha-tier"},
        tracker: %{limited?: false, rate_limit: nil},
        polling: %{checking?: true, next_poll_in_ms: 8_000}
      })

    zeta =
      start_snapshot_server(%{
        running: [running_entry(%{identifier: "SID-Z", runtime_total_tokens: 25})],
        retrying: [retry_entry(%{identifier: "SID-RETRY-Z", due_in_ms: 2_000})],
        runtime_totals: %{input_tokens: 20, output_tokens: 5, total_tokens: 25, seconds_running: 7},
        rate_limits: %{limit_id: "zeta-tier"},
        tracker: %{limited?: true, rate_limit: %{source: "linear", remaining_ms: 4_000}},
        polling: %{checking?: false, next_poll_in_ms: 2_000}
      })

    unavailable =
      start_snapshot_server(%{
        running: [running_entry(%{identifier: "SKIP-ME", runtime_total_tokens: 999})],
        retrying: [],
        runtime_totals: %{input_tokens: 999, output_tokens: 999, total_tokens: 999, seconds_running: 999},
        rate_limits: %{limit_id: "unavailable-tier"},
        tracker: %{limited?: false, rate_limit: nil},
        polling: %{checking?: false, next_poll_in_ms: 1_000}
      })

    _scheduler =
      start_snapshot_server(
        %{
          targets: %{
            "zeta" => %{pid: zeta, effective_state: :active},
            "paused" => %{pid: nil, effective_state: :paused},
            "unavailable" => %{pid: unavailable, effective_state: :unavailable},
            "alpha" => %{pid: alpha, effective_state: :active}
          }
        },
        name: HostScheduler
      )

    dashboard = start_dashboard()
    send(dashboard, :refresh)

    assert_receive {:dashboard_frame, content}
    refute content =~ "Orchestrator snapshot unavailable"
    assert content =~ "SID-A"
    assert content =~ "SID-Z"
    assert content =~ "SID-RETRY-A"
    assert content =~ "SID-RETRY-Z"
    assert content =~ "in 30"
    assert content =~ "out 7"
    assert content =~ "total 37"
    assert content =~ "alpha-tier"
    refute content =~ "zeta-tier"
    assert content =~ "tracker_rate_limited"
    assert content =~ "Next refresh:"
    assert content =~ "checking now"
    refute content =~ "SKIP-ME"
    refute content =~ "unavailable-tier"
  end

  test "target snapshots are requested concurrently" do
    snapshot = %{
      running: [],
      retrying: [],
      runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      tracker: %{limited?: false, rate_limit: nil},
      polling: %{checking?: false, next_poll_in_ms: 1_000}
    }

    alpha = start_snapshot_server({:deferred, self(), snapshot})
    zeta = start_snapshot_server({:deferred, self(), snapshot})

    _scheduler =
      start_snapshot_server(
        %{
          targets: %{
            "zeta" => %{pid: zeta, effective_state: :active},
            "alpha" => %{pid: alpha, effective_state: :active}
          }
        },
        name: HostScheduler
      )

    dashboard = start_dashboard()
    send(dashboard, :refresh)

    requests =
      for _index <- 1..2 do
        assert_receive {:snapshot_requested, pid, from}, 500
        {pid, from}
      end

    assert requests |> Enum.map(&elem(&1, 0)) |> MapSet.new() == MapSet.new([alpha, zeta])
    Enum.each(requests, fn {_pid, from} -> GenServer.reply(from, snapshot) end)

    assert_receive {:dashboard_frame, content}
    refute content =~ "Orchestrator snapshot unavailable"
  end

  test "scheduler unavailability renders the unavailable frame" do
    assert Process.whereis(HostScheduler) == nil

    dashboard = start_dashboard()
    send(dashboard, :refresh)

    assert_receive {:dashboard_frame, content}
    assert content =~ "Orchestrator snapshot unavailable"
  end

  @terminal_columns 115

  test "snapshot fixture: idle dashboard" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    Snapshot.assert_dashboard_snapshot!("idle", render_snapshot(snapshot_data, 0.0))
  end

  test "snapshot fixture: idle dashboard with observability url" do
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)

    on_exit(fn ->
      if is_nil(previous_port_override) do
        Application.delete_env(:symphony_elixir, :server_port_override)
      else
        Application.put_env(:symphony_elixir, :server_port_override, previous_port_override)
      end
    end)

    Application.put_env(:symphony_elixir, :server_port_override, 4000)

    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    Snapshot.assert_dashboard_snapshot!("idle_with_dashboard_url", render_snapshot(snapshot_data, 0.0))
  end

  test "snapshot fixture: super busy dashboard" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-101",
             runtime_total_tokens: 120_450,
             runtime_seconds: 785,
             turn_count: 11,
             last_runtime_event: "turn_completed",
             last_runtime_message: turn_completed_message("completed")
           }),
           running_entry(%{
             identifier: "MT-102",
             session_id: "thread-abcdef1234567890",
             adapter: adapter_diagnostics("5252"),
             runtime_total_tokens: 89_200,
             runtime_seconds: 412,
             turn_count: 4,
             last_runtime_event: "codex/event/task_started",
             last_runtime_message: exec_command_message("mix test --cover")
           })
         ],
         retrying: [],
         runtime_totals: %{
           input_tokens: 250_000,
           output_tokens: 18_500,
           total_tokens: 268_500,
           seconds_running: 4_321
         },
         rate_limits: %{
           limit_id: "gpt-5",
           primary: %{remaining: 12_345, limit: 20_000, reset_in_seconds: 30},
           secondary: %{remaining: 45, limit: 60, reset_in_seconds: 12},
           credits: %{has_credits: true, balance: 9_876.5}
         }
       }}

    Snapshot.assert_dashboard_snapshot!("super_busy", render_snapshot(snapshot_data, 1_842.7))
  end

  test "snapshot fixture: backoff queue pressure" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-638",
             state: "retrying",
             runtime_total_tokens: 14_200,
             runtime_seconds: 1_225,
             turn_count: 7,
             last_runtime_event: :notification,
             last_runtime_message: agent_message_delta("waiting on rate-limit backoff window")
           })
         ],
         retrying: [
           retry_entry(%{
             identifier: "MT-450",
             attempt: 4,
             due_in_ms: 1_250,
             error: "rate limit exhausted"
           }),
           retry_entry(%{
             identifier: "MT-451",
             attempt: 2,
             due_in_ms: 3_900,
             error: "retrying after API timeout with jitter"
           }),
           retry_entry(%{
             identifier: "MT-452",
             attempt: 6,
             due_in_ms: 8_100,
             error: "worker crashed\nrestarting cleanly"
           }),
           retry_entry(%{
             identifier: "MT-453",
             attempt: 1,
             due_in_ms: 11_000,
             error: "fourth queued retry should also render after removing the top-three limit"
           })
         ],
         runtime_totals: %{input_tokens: 18_000, output_tokens: 2_200, total_tokens: 20_200, seconds_running: 2_700},
         rate_limits: %{
           limit_id: "gpt-5",
           primary: %{remaining: 0, limit: 20_000, reset_in_seconds: 95},
           secondary: %{remaining: 0, limit: 60, reset_in_seconds: 45},
           credits: %{has_credits: false}
         }
       }}

    Snapshot.assert_dashboard_snapshot!("backoff_queue", render_snapshot(snapshot_data, 15.4))
  end

  test "backoff queue row escapes escaped newline sequences" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [
           retry_entry(%{
             identifier: "MT-980",
             attempt: 1,
             due_in_ms: 1_500,
             error: "error with \\nnewline"
           })
         ],
         runtime_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = render_snapshot(snapshot_data, 0.0)
    backoff_lines = rendered |> String.split("\n") |> Enum.filter(&String.contains?(&1, "MT-980"))

    assert length(backoff_lines) == 1

    [backoff_line] = backoff_lines

    assert backoff_line =~ "error=error with newline"
    refute backoff_line =~ "\\n"
  end

  test "snapshot fixture: unlimited credits variant" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-777",
             state: "running",
             runtime_total_tokens: 3_200,
             runtime_seconds: 75,
             turn_count: 7,
             last_runtime_event: "codex/event/token_count",
             last_runtime_message: token_usage_message(90, 12, 102)
           })
         ],
         retrying: [],
         runtime_totals: %{input_tokens: 90, output_tokens: 12, total_tokens: 102, seconds_running: 75},
         rate_limits: %{
           limit_id: "priority-tier",
           primary: %{remaining: 100, limit: 100, reset_in_seconds: 1},
           secondary: %{remaining: 500, limit: 500, reset_in_seconds: 1},
           credits: %{unlimited: true}
         }
       }}

    Snapshot.assert_dashboard_snapshot!("credits_unlimited", render_snapshot(snapshot_data, 42.0))
  end

  defp render_snapshot(snapshot_data, tps) do
    StatusDashboard.format_snapshot_content_for_test(snapshot_data, tps, @terminal_columns)
  end

  defp running_entry(overrides) do
    Map.merge(
      %{
        identifier: "MT-000",
        state: "running",
        session_id: "thread-1234567890",
        adapter: adapter_diagnostics("4242"),
        profile: "default",
        target: "Human Review",
        runtime_total_tokens: 0,
        runtime_seconds: 0,
        turn_count: 1,
        last_runtime_event: :notification,
        last_runtime_message: turn_started_message()
      },
      overrides
    )
  end

  defp adapter_diagnostics(app_server_pid) do
    %{
      kind: "codex",
      diagnostics: %{
        app_server_pid: app_server_pid
      }
    }
  end

  defp retry_entry(overrides) do
    Map.merge(
      %{
        issue_id: "issue-1",
        identifier: "MT-000",
        profile: "default",
        target: "Human Review",
        attempt: 1,
        due_in_ms: 1_000,
        error: "retry scheduled"
      },
      overrides
    )
  end

  defp start_snapshot_server(snapshot, opts \\ []) do
    {:ok, pid} = GenServer.start(SnapshotServer, snapshot, opts)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    pid
  end

  defp start_dashboard do
    test_pid = self()

    opts = [
      name: {:global, {__MODULE__, make_ref()}},
      enabled: true,
      refresh_ms: 60_000,
      render_interval_ms: 1,
      render_fun: &send(test_pid, {:dashboard_frame, &1})
    ]

    start_supervised!({StatusDashboard, opts})
  end

  defp turn_started_message do
    %{
      event: :notification,
      message: %{
        "method" => "turn/started",
        "params" => %{"turn" => %{"id" => "turn-1"}}
      }
    }
  end

  defp turn_completed_message(status) do
    %{
      event: :notification,
      message: %{
        "method" => "turn/completed",
        "params" => %{"turn" => %{"status" => status}}
      }
    }
  end

  defp exec_command_message(command) do
    %{
      event: :notification,
      message: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => command}}
      }
    }
  end

  defp agent_message_delta(delta) do
    %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_message_delta",
        "params" => %{"msg" => %{"payload" => %{"delta" => delta}}}
      }
    }
  end

  defp token_usage_message(input_tokens, output_tokens, total_tokens) do
    %{
      event: :notification,
      message: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "tokenUsage" => %{
            "total" => %{
              "inputTokens" => input_tokens,
              "outputTokens" => output_tokens,
              "totalTokens" => total_tokens
            }
          }
        }
      }
    }
  end
end
