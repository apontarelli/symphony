defmodule SymphonyElixir.LandingQueueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{LandingQueue, LandingRevalidation}
  alias SymphonyElixir.LandingQueue.Entry

  @now ~U[2026-09-03 12:00:00Z]

  test "dependencies block dependents without blocking independent work" do
    dependent =
      entry("issue-b", "SID-102", "2026-09-03T10:00:00Z", dependencies: [%{id: "issue-a", identifier: "SID-101", state: "Merging"}])

    independent = entry("issue-c", "SID-103", "2026-09-03T10:01:00Z")

    assert {:ok, plan} =
             LandingQueue.plan([dependent, independent], [],
               now: @now,
               terminal_states: ["Done", "Canceled"]
             )

    assert plan.selected.issue_id == "issue-c"
    assert queue_entry(plan, "issue-b").status == :blocked
    assert queue_entry(plan, "issue-b").blocked_reasons == [:dependency_not_landed]
    assert queue_entry(plan, "issue-b").dependency_blockers == dependent.dependencies
  end

  test "a terminal dependency makes its dependent eligible" do
    dependent =
      entry("issue-b", "SID-102", "2026-09-03T10:00:00Z", dependencies: [%{id: "issue-a", identifier: "SID-101", state: "Done"}])

    assert {:ok, plan} =
             LandingQueue.plan([dependent], [], now: @now, terminal_states: ["Done"])

    assert plan.selected.issue_id == "issue-b"
    assert queue_entry(plan, "issue-b").status == :selected
  end

  test "file conflicts are explicit and a running landing serializes the target" do
    first = entry("issue-a", "SID-101", "2026-09-03T10:00:00Z", changed_files: ["lib/a.ex"])
    second = entry("issue-b", "SID-102", "2026-09-03T10:01:00Z", changed_files: ["lib/a.ex", "lib/b.ex"])

    assert {:ok, plan} = LandingQueue.plan([first, second], [%{issue_id: "running"}], now: @now)
    assert plan.selected == nil

    first_plan = queue_entry(plan, "issue-a")
    assert first_plan.status == :waiting
    assert first_plan.blocked_reasons == [:landing_slot_occupied]

    assert first_plan.conflicts == [
             %{issue_id: "issue-b", identifier: "SID-102", overlapping_files: ["lib/a.ex"]}
           ]
  end

  test "priority precedes freshness and freshness resolves equal priority" do
    stale_high_priority =
      entry("issue-a", "SID-101", "2026-09-03T11:59:00Z",
        priority: 1,
        revalidation: %{status: :refresh_required, reason: :target_refresh_required}
      )

    fresh_low_priority = entry("issue-b", "SID-102", "2026-09-03T11:59:00Z", priority: 4)

    assert {:ok, priority_plan} = LandingQueue.plan([stale_high_priority, fresh_low_priority], [], now: @now)
    assert priority_plan.selected.issue_id == "issue-a"
    assert priority_plan.selected.freshness == :refresh_required

    stale_equal_priority = %{stale_high_priority | priority: 2}
    fresh_equal_priority = %{fresh_low_priority | priority: 2}

    assert {:ok, freshness_plan} = LandingQueue.plan([stale_equal_priority, fresh_equal_priority], [], now: @now)
    assert freshness_plan.selected.issue_id == "issue-b"
  end

  test "bounded aging promotes old work and FIFO resolves equal entries" do
    old_low_priority = entry("issue-a", "SID-101", "2026-09-03T11:15:00Z", priority: 4)
    new_high_priority = entry("issue-b", "SID-102", "2026-09-03T11:59:00Z", priority: 2)

    assert {:ok, aged_plan} = LandingQueue.plan([new_high_priority, old_low_priority], [], now: @now)
    assert aged_plan.selected.issue_id == "issue-a"
    assert aged_plan.selected.starvation_promotions == 3
    assert aged_plan.selected.effective_priority == 1
    assert aged_plan.starvation.max_promotion_wait_ms == 3_600_000

    earlier = entry("issue-c", "SID-103", "2026-09-03T11:00:00Z", priority: 2)
    later = entry("issue-d", "SID-104", "2026-09-03T11:01:00Z", priority: 2)

    assert {:ok, fifo_plan} = LandingQueue.plan([later, earlier], [], now: @now)
    assert fifo_plan.selected.issue_id == "issue-c"
    assert Enum.map(fifo_plan.entries, & &1.issue_id) == ["issue-c", "issue-d"]
  end

  test "failed revalidation stays visible and does not block a valid change" do
    failed =
      entry("issue-a", "SID-101", "2026-09-03T10:00:00Z", revalidation: %{status: :failed, reason: :github_unavailable})

    ready = entry("issue-b", "SID-102", "2026-09-03T10:01:00Z")

    assert {:ok, plan} = LandingQueue.plan([failed, ready], [], now: @now)
    assert plan.selected.issue_id == "issue-b"
    assert queue_entry(plan, "issue-a").status == :blocked
    assert queue_entry(plan, "issue-a").blocked_reasons == [:revalidation_failed]
  end

  test "two conflicting changes land one at a time and revalidate the second target" do
    first = entry("issue-a", "SID-101", "2026-09-03T10:00:00Z", changed_files: ["lib/shared.ex"])

    second =
      entry("issue-b", "SID-102", "2026-09-03T10:01:00Z",
        changed_files: ["lib/shared.ex"],
        revalidation: %{status: :ready, target_revision: "target-before-first"}
      )

    assert {:ok, first_plan} = LandingQueue.plan([second, first], [], now: @now)
    assert first_plan.selected.issue_id == "issue-a"

    assert {:ok, occupied_plan} =
             LandingQueue.plan([second], [%{issue_id: "issue-a", changed_files: first.changed_files}], now: @now)

    assert occupied_plan.selected == nil
    assert queue_entry(occupied_plan, "issue-b").status == :waiting

    revalidated_second = %{
      second
      | revalidation: %{status: :ready, target_revision: "target-after-first"}
    }

    assert {:ok, second_plan} = LandingQueue.plan([revalidated_second], [], now: @now)
    assert second_plan.selected.issue_id == "issue-b"
    assert second_plan.selected.entry.revalidation.target_revision == "target-after-first"
  end

  test "the same durable evidence reconstructs the same restart order" do
    entries = [
      entry("issue-b", "SID-102", "2026-09-03T10:00:00Z", priority: 2),
      entry("issue-a", "SID-101", "2026-09-03T10:00:00Z", priority: 2)
    ]

    assert {:ok, before_restart} = LandingQueue.plan(entries, [], now: @now)
    reconstructed = Enum.map(entries, &struct!(Entry, Map.from_struct(&1)))
    assert {:ok, after_restart} = LandingQueue.plan(Enum.reverse(reconstructed), [], now: @now)

    assert before_restart.selected.issue_id == "issue-a"
    assert after_restart.selected.issue_id == before_restart.selected.issue_id
    assert Enum.map(after_restart.entries, & &1.issue_id) == Enum.map(before_restart.entries, & &1.issue_id)
  end

  test "duplicate queue authority is rejected" do
    duplicate = entry("issue-a", "SID-101", "2026-09-03T10:00:00Z")
    assert {:error, :duplicate_landing_queue_issue} = LandingQueue.plan([duplicate, duplicate], [], now: @now)
  end

  test "GitHub revalidation records current target evidence" do
    parent = self()

    runner = fn command, args, opts ->
      send(parent, {:command, command, args, opts})
      {:ok, %{status: 0, output: Jason.encode!(github_payload())}}
    end

    result = LandingRevalidation.check(entry("issue-a", "SID-101", "2026-09-03T10:00:00Z"), now: @now, runner: runner)

    assert result.status == :ready
    assert result.reason == :merge_gate_clear
    assert result.target_revision == "base-sha"
    assert result.head_revision == "head-sha"
    assert result.checks == %{total: 2, passed: 2, blocking: 0}

    assert_received {:command, "gh", ["pr", "view", "https://github.com/example/repo/pull/1", "--repo", "example/repo", "--json", fields], []}
    assert fields =~ "baseRefOid"
    assert fields =~ "statusCheckRollup"
  end

  test "GitHub revalidation requires refresh for stale or conflicting branches" do
    stale_runner = fn _, _, _ ->
      {:ok, %{status: 0, output: Jason.encode!(github_payload(%{"mergeStateStatus" => "BEHIND"}))}}
    end

    conflict_runner = fn _, _, _ ->
      {:ok, %{status: 0, output: Jason.encode!(github_payload(%{"mergeable" => "CONFLICTING", "mergeStateStatus" => "DIRTY"}))}}
    end

    queue_entry = entry("issue-a", "SID-101", "2026-09-03T10:00:00Z")
    assert %{status: :refresh_required, reason: :target_refresh_required} = LandingRevalidation.check(queue_entry, runner: stale_runner)
    assert %{status: :refresh_required, reason: :merge_conflict} = LandingRevalidation.check(queue_entry, runner: conflict_runner)

    merged_runner = fn _, _, _ ->
      {:ok, %{status: 0, output: Jason.encode!(github_payload(%{"state" => "MERGED"}))}}
    end

    assert %{status: :blocked, reason: :pull_request_not_open} =
             LandingRevalidation.check(queue_entry, runner: merged_runner)
  end

  test "GitHub revalidation fails closed on checks, identity, and command errors" do
    pending_checks = [
      %{"__typename" => "CheckRun", "status" => "IN_PROGRESS", "conclusion" => nil}
    ]

    blocked_runner = fn _, _, _ ->
      {:ok, %{status: 0, output: Jason.encode!(github_payload(%{"statusCheckRollup" => pending_checks}))}}
    end

    identity_runner = fn _, _, _ ->
      {:ok, %{status: 0, output: Jason.encode!(github_payload(%{"headRefName" => "wrong"}))}}
    end

    command_runner = fn _, _, _ -> {:ok, %{status: 1, output: "not available\n"}} end
    queue_entry = entry("issue-a", "SID-101", "2026-09-03T10:00:00Z")

    assert %{status: :blocked, reason: :required_checks_not_passed} =
             LandingRevalidation.check(queue_entry, runner: blocked_runner)

    assert %{status: :failed, reason: :github_revalidation_identity_mismatch} =
             LandingRevalidation.check(queue_entry, runner: identity_runner)

    assert %{status: :failed, reason: {:github_revalidation_failed, 1, "not available"}} =
             LandingRevalidation.check(queue_entry, runner: command_runner)
  end

  test "GitHub revalidation rejects invalid inputs and unavailable evidence" do
    queue_entry = entry("issue-a", "SID-101", "2026-09-03T10:00:00Z")
    unused_runner = fn _, _, _ -> flunk("runner must not be called") end

    assert %{status: :failed, reason: :invalid_landing_queue_entry} =
             LandingRevalidation.check(:invalid)

    assert %{status: :failed, reason: :publish_evidence_missing} =
             LandingRevalidation.check(%{queue_entry | pr_url: nil}, runner: unused_runner)

    assert %{status: :failed, reason: :invalid_revalidation_options} =
             LandingRevalidation.check(queue_entry, now: :invalid, runner: unused_runner)

    assert %{status: :failed, reason: {:github_revalidation_failed, :offline}} =
             LandingRevalidation.check(queue_entry, runner: fn _, _, _ -> {:error, :offline} end)

    assert %{status: :failed, reason: {:github_revalidation_invalid_result, :invalid}} =
             LandingRevalidation.check(queue_entry, runner: fn _, _, _ -> :invalid end)

    assert %{status: :failed, reason: :github_revalidation_payload_invalid} =
             LandingRevalidation.check(queue_entry,
               runner: fn _, _, _ -> {:ok, %{status: 0, output: "[]"}} end
             )
  end

  test "GitHub revalidation records draft, unknown, policy, and malformed-check blockers" do
    queue_entry = entry("issue-a", "SID-101", "2026-09-03T10:00:00Z")

    assert %{status: :blocked, reason: :pull_request_draft} =
             revalidate_with_payload(queue_entry, %{"isDraft" => true})

    assert %{status: :blocked, reason: :mergeability_unknown} =
             revalidate_with_payload(queue_entry, %{
               "mergeable" => "UNKNOWN",
               "mergeStateStatus" => "UNKNOWN"
             })

    assert %{status: :blocked, reason: :merge_policy_blocked} =
             revalidate_with_payload(queue_entry, %{"mergeStateStatus" => "BLOCKED"})

    assert %{status: :blocked, reason: :required_checks_not_passed} =
             revalidate_with_payload(queue_entry, %{
               "statusCheckRollup" => [%{"__typename" => "Unknown"}, nil]
             })

    assert %{status: :failed, reason: :github_revalidation_identity_mismatch} =
             revalidate_with_payload(queue_entry, %{"statusCheckRollup" => nil})
  end

  test "queue validation fails closed for malformed entries and options" do
    valid = entry("issue-a", "SID-101", "2026-09-03T10:00:00Z")

    assert {:error, :invalid_landing_queue} = LandingQueue.plan(:invalid)
    assert {:error, :invalid_landing_queue} = LandingQueue.plan([], :invalid)
    assert {:error, :invalid_landing_queue} = LandingQueue.plan([], [], :invalid)
    assert {:error, :invalid_landing_queue_clock} = LandingQueue.plan([valid], [], now: :invalid)
    assert {:error, :invalid_landing_queue_entry} = LandingQueue.plan([%{}])

    malformed_entries = [
      %{valid | dependencies: :invalid},
      %{valid | dependencies: [nil]},
      %{valid | changed_files: :invalid},
      %{valid | changed_files: [nil]},
      %{valid | changed_files: ["lib/a.ex", "lib/a.ex"]},
      %{valid | revalidation: :invalid},
      %{valid | revalidation: %{status: :unknown}}
    ]

    Enum.each(malformed_entries, fn malformed ->
      assert {:error, :invalid_landing_queue_entry} = LandingQueue.plan([malformed])
    end)
  end

  test "blocked queue states remain visible while the landing slot is occupied" do
    blocked =
      entry("issue-a", "SID-101", "2026-09-03T10:00:00Z",
        priority: nil,
        dependencies: [%{id: "issue-dependency", state: nil}],
        revalidation: %{status: :blocked, reason: :pull_request_draft}
      )

    blank_state_dependency =
      entry("issue-b", "SID-102", "2026-09-03T10:01:00Z", dependencies: [%{id: "issue-dependency", state: " "}])

    ready = entry("issue-c", "SID-103", "2026-09-03T10:02:00Z")

    assert {:ok, plan} =
             LandingQueue.plan([ready, blank_state_dependency, blocked], [%{issue_id: "running"}],
               now: @now,
               terminal_states: :invalid
             )

    blocked_plan = queue_entry(plan, "issue-a")
    assert blocked_plan.status == :blocked
    assert blocked_plan.blocked_reasons == [:dependency_not_landed]
    assert blocked_plan.base_priority == 5

    assert queue_entry(plan, "issue-b").status == :blocked
    assert queue_entry(plan, "issue-c").status == :waiting
  end

  test "a blocked revalidation does not prevent independent selection" do
    blocked =
      entry("issue-a", "SID-101", "2026-09-03T10:00:00Z", revalidation: %{status: :blocked, reason: :pull_request_draft})

    assert {:ok, blocked_plan} = LandingQueue.plan([blocked])
    assert blocked_plan.selected == nil
    assert queue_entry(blocked_plan, "issue-a").status == :blocked

    ready = entry("issue-b", "SID-102", "2026-09-03T10:01:00Z")

    assert {:ok, plan} = LandingQueue.plan([blocked, ready])
    assert plan.selected.issue_id == "issue-b"
    assert queue_entry(plan, "issue-a").blocked_reasons == [:revalidation_blocked]
  end

  defp revalidate_with_payload(entry, overrides) do
    runner = fn _, _, _ ->
      {:ok, %{status: 0, output: Jason.encode!(github_payload(overrides))}}
    end

    LandingRevalidation.check(entry, now: @now, runner: runner)
  end

  defp entry(issue_id, identifier, enqueued_at, opts \\ []) do
    {:ok, enqueued_at, 0} = DateTime.from_iso8601(enqueued_at)

    struct!(Entry, %{
      issue_id: issue_id,
      identifier: identifier,
      enqueued_at: enqueued_at,
      priority: Keyword.get(opts, :priority, 2),
      admitted_run_id: "run-#{issue_id}",
      pr_url: "https://github.com/example/repo/pull/1",
      repository: "example/repo",
      base_branch: "main",
      branch: "ticket/#{String.downcase(identifier)}",
      dependencies: Keyword.get(opts, :dependencies, []),
      changed_files: Keyword.get(opts, :changed_files, ["lib/#{issue_id}.ex"]),
      revalidation: Keyword.get(opts, :revalidation, %{status: :ready, reason: :merge_gate_clear})
    })
  end

  defp queue_entry(plan, issue_id), do: Enum.find(plan.entries, &(&1.issue_id == issue_id))

  defp github_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "url" => "https://github.com/example/repo/pull/1",
        "baseRefName" => "main",
        "baseRefOid" => "base-sha",
        "headRefName" => "ticket/sid-101",
        "headRefOid" => "head-sha",
        "isDraft" => false,
        "state" => "OPEN",
        "mergeable" => "MERGEABLE",
        "mergeStateStatus" => "CLEAN",
        "reviewDecision" => "APPROVED",
        "statusCheckRollup" => [
          %{"__typename" => "CheckRun", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
          %{"__typename" => "StatusContext", "state" => "SUCCESS"}
        ]
      },
      overrides
    )
  end
end
