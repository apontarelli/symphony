defmodule SymphonyElixir.SchedulerStatusTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.SchedulerStatus

  test "one safe projection serves status fields and structured logs" do
    secret = "scheduler-projection-secret"

    host_snapshot = %{
      counts: %{agents: 1, startups: 0, reviewers: 0, polls: 1},
      limits: %{
        agents: 2,
        startups: 1,
        reviewers: 1,
        polls: %{max_concurrent: 2},
        raw_policy: secret
      },
      targets: %{
        "alpha" => %{
          configured_state: :active,
          effective_state: :limited,
          eligibility_reason: :tracker_backoff,
          queue_count: 2,
          counts: %{agents: 1, startups: 0, reviewers: 0, polls: 1},
          limits: %{agents: 1, startups: 1, reviewers: 1, poll_interval_ms: 1_000},
          scheduling: %{weight: 3, deficit: 2},
          budget_limits: %{per_run_tokens: 100, daily_tokens: 200, weekly_tokens: 500},
          tracker_backoff: %{active: true, remaining_ms: 750},
          raw_policy: secret,
          credentials: secret,
          prompt: secret,
          transition_evidence: secret
        }
      }
    }

    runtime_snapshots = %{
      "alpha" => %{
        running: [%{prompt: secret}],
        retrying: [%{credentials: secret}],
        blocked: [%{transition_evidence: secret}]
      }
    }

    durable_runs = [
      %{
        admitted_run_id: "run-alpha-1",
        target_id: "alpha",
        tracker_issue_id: "issue-shared",
        issue_identifier: "SID-SHARED",
        lifecycle_state: "blocked",
        blocked_reason: "budget_exhausted",
        transition_evidence: secret
      },
      %{
        admitted_run_id: "run-alpha-2",
        target_id: "alpha",
        tracker_issue_id: "issue-retrying",
        issue_identifier: "SID-RETRY",
        lifecycle_state: "retrying",
        blocked_reason: nil
      },
      %{
        admitted_run_id: "completed-run",
        target_id: "alpha",
        tracker_issue_id: "issue-completed",
        issue_identifier: "SID-DONE",
        lifecycle_state: "completed",
        blocked_reason: nil
      }
    ]

    budgets = [
      %{
        target_id: "alpha",
        reserved_tokens: 25,
        daily_reserved_tokens: 25,
        weekly_reserved_tokens: 25,
        charged_tokens: 175,
        daily_charged_tokens: 175,
        weekly_charged_tokens: 175
      }
    ]

    log =
      capture_log(fn ->
        projection =
          SchedulerStatus.project(host_snapshot, runtime_snapshots, durable_runs, budgets)

        assert projection == %{
                 counts: %{running: 1, retrying: 1, blocked: 1},
                 host: %{
                   queue_count: 2,
                   capacity: %{
                     used: %{agents: 1, startups: 0, reviewers: 0, polls: 1},
                     limits: %{agents: 2, startups: 1, reviewers: 1, polls: 2}
                   }
                 },
                 targets: [
                   %{
                     target_id: "alpha",
                     configured_state: :active,
                     effective_state: :limited,
                     eligibility_reason: :tracker_backoff,
                     queue_count: 2,
                     scheduling: %{weight: 3, deficit: 2},
                     capacity: %{
                       used: %{agents: 1, startups: 0, reviewers: 0, polls: 1},
                       limits: %{agents: 1, startups: 1, reviewers: 1}
                     },
                     budget: %{
                       configured: true,
                       exhausted: true,
                       reserved_tokens: 25,
                       daily_reserved_tokens: 25,
                       weekly_reserved_tokens: 25,
                       charged_tokens: 175,
                       daily_charged_tokens: 175,
                       weekly_charged_tokens: 175,
                       limits: %{per_run_tokens: 100, daily_tokens: 200, weekly_tokens: 500}
                     },
                     tracker_backoff: %{active: true, remaining_ms: 750},
                     counts: %{running: 1, retrying: 1, blocked: 1},
                     runs: [
                       %{
                         admitted_run_id: "run-alpha-1",
                         target_id: "alpha",
                         issue_id: "issue-shared",
                         issue_identifier: "SID-SHARED",
                         state: "blocked",
                         blocked_reason: "budget_exhausted"
                       },
                       %{
                         admitted_run_id: "run-alpha-2",
                         target_id: "alpha",
                         issue_id: "issue-retrying",
                         issue_identifier: "SID-RETRY",
                         state: "retrying",
                         blocked_reason: nil
                       }
                     ]
                   }
                 ]
               }

        refute inspect(projection) =~ secret
      end)

    assert log =~ "target_id=alpha"
    refute log =~ "completed-run"
    assert log =~ "budget_daily_reserved_tokens=25"
    assert log =~ "budget_weekly_reserved_tokens=25"
    assert log =~ "runs=alpha/SID-SHARED/run-alpha-1"
    assert log =~ "alpha/SID-RETRY/run-alpha-2"
    refute log =~ secret
  end

  test "weekly exhaustion and absent runs remain safe" do
    host_snapshot = %{
      counts: %{},
      limits: %{polls: %{}},
      targets: %{
        "beta" => %{
          configured_state: :active,
          effective_state: :active,
          eligibility_reason: :eligible,
          queue_count: 0,
          counts: %{},
          limits: %{},
          scheduling: %{weight: nil, deficit: nil},
          budget_limits: %{per_run_tokens: 50, daily_tokens: 100, weekly_tokens: 100},
          tracker_backoff: %{}
        }
      }
    }

    log =
      capture_log(fn ->
        projection =
          SchedulerStatus.project(
            host_snapshot,
            %{"beta" => %{running: [], retrying: [], blocked: []}},
            [],
            [
              %{
                target_id: "beta",
                reserved_tokens: 0,
                charged_tokens: 100,
                daily_charged_tokens: 0,
                weekly_charged_tokens: 100
              }
            ]
          )

        assert [%{budget: %{exhausted: true}, scheduling: %{weight: 0, deficit: 0}}] =
                 projection.targets
      end)

    assert log =~ "runs=none"
  end

  test "budget exhaustion uses reservations from the matching period" do
    host_snapshot = %{
      counts: %{},
      limits: %{polls: %{}},
      targets: %{
        "alpha" => %{
          budget_limits: %{per_run_tokens: 50, daily_tokens: 100, weekly_tokens: 1_000}
        }
      }
    }

    projection =
      SchedulerStatus.project(
        host_snapshot,
        %{},
        [],
        [
          %{
            target_id: "alpha",
            reserved_tokens: 100,
            daily_reserved_tokens: 0,
            weekly_reserved_tokens: 100,
            charged_tokens: 0,
            daily_charged_tokens: 0,
            weekly_charged_tokens: 0
          }
        ]
      )

    assert [%{budget: %{exhausted: false}}] = projection.targets
  end
end
