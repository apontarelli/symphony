defmodule SymphonyElixir.TrackerCoordinatorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{RunTarget, TrackerCoordinator}

  setup do
    state_root =
      System.tmp_dir!()
      |> Path.join("symphony-tracker-coordinator-#{System.unique_integer([:positive])}")

    state_path = Path.join(state_root, "coordinator.state")

    Application.put_env(:symphony_elixir, :tracker_coordinator_state_path, state_path)

    on_exit(fn -> File.rm_rf(state_root) end)

    %{state_path: state_path, state_root: state_root}
  end

  test "equivalent targets share one cached candidate fetch", %{state_path: state_path} do
    issue = issue("issue-cache", "MT-CACHE")
    resolution = RunTarget.Resolution.new(nil, [issue], [])
    parent = self()

    fetch_fun = fn ->
      send(parent, :candidate_fetch)
      {:ok, resolution}
    end

    assert {:ok, ^resolution} =
             TrackerCoordinator.resolve_candidate_issues(nil, fetch_fun,
               state_path: state_path,
               cache_ttl_ms: 60_000,
               now_ms: 1_000
             )

    assert {:ok, ^resolution} =
             TrackerCoordinator.resolve_candidate_issues(nil, fetch_fun,
               state_path: state_path,
               cache_ttl_ms: 60_000,
               now_ms: 2_000
             )

    assert_receive :candidate_fetch
    refute_receive :candidate_fetch, 10
  end

  test "different cache keys do not share candidate results", %{state_path: state_path} do
    first_resolution = RunTarget.Resolution.new(nil, [issue("issue-cache-a", "MT-A")], [])
    second_resolution = RunTarget.Resolution.new(nil, [issue("issue-cache-b", "MT-B")], [])
    parent = self()

    first_fetch = fn ->
      send(parent, :first_candidate_fetch)
      {:ok, first_resolution}
    end

    second_fetch = fn ->
      send(parent, :second_candidate_fetch)
      {:ok, second_resolution}
    end

    assert {:ok, ^first_resolution} =
             TrackerCoordinator.resolve_candidate_issues(nil, first_fetch,
               cache_key: {:project, "first"},
               state_path: state_path,
               cache_ttl_ms: 60_000,
               now_ms: 1_000
             )

    assert {:ok, ^second_resolution} =
             TrackerCoordinator.resolve_candidate_issues(nil, second_fetch,
               cache_key: {:project, "second"},
               state_path: state_path,
               cache_ttl_ms: 60_000,
               now_ms: 2_000
             )

    assert_receive :first_candidate_fetch
    assert_receive :second_candidate_fetch
  end

  test "shared rate limit blocks later candidate fetches and exposes status", %{
    state_path: state_path
  } do
    first_fetch = fn ->
      {:error, {:linear_rate_limited, %{status: 400, retry_after_ms: 60_000, errors: [%{code: "RATELIMITED"}]}}}
    end

    assert {:error, {:linear_rate_limited, %{retry_after_ms: 60_000}}} =
             TrackerCoordinator.resolve_candidate_issues(nil, first_fetch,
               state_path: state_path,
               now_ms: 1_000
             )

    second_fetch = fn -> flunk("shared rate limit should skip the tracker adapter") end

    assert {:error, {:linear_rate_limited, details}} =
             TrackerCoordinator.resolve_candidate_issues(nil, second_fetch,
               state_path: state_path,
               now_ms: 2_000
             )

    assert details.reason == :tracker_rate_limited
    assert details.source == :candidate_fetch
    assert details.retry_after_ms > 0

    assert %{reason: :tracker_rate_limited, source: :candidate_fetch, remaining_ms: remaining_ms} =
             TrackerCoordinator.rate_limit(state_path: state_path, now_ms: 2_000)

    assert remaining_ms > 0
  end

  test "leases prevent concurrent claims and expired leases are recoverable", %{
    state_path: state_path
  } do
    issue = issue("issue-lease", "MT-LEASE")

    assert :ok =
             TrackerCoordinator.claim_issue(issue, "daemon-a",
               state_path: state_path,
               lease_ttl_ms: 5_000,
               now_ms: 1_000
             )

    assert {:error, :leased} =
             TrackerCoordinator.claim_issue(issue, "daemon-b",
               state_path: state_path,
               lease_ttl_ms: 5_000,
               now_ms: 2_000
             )

    assert :ok =
             TrackerCoordinator.claim_issue(issue, "daemon-b",
               state_path: state_path,
               lease_ttl_ms: 5_000,
               now_ms: 7_000
             )

    assert [%{owner_id: "daemon-b"}] =
             TrackerCoordinator.snapshot(state_path: state_path, now_ms: 7_000).leases
  end

  test "lease refresh keeps active ownership ahead of stale recovery", %{
    state_path: state_path
  } do
    issue = issue("issue-refresh", "MT-REFRESH")

    assert :ok =
             TrackerCoordinator.claim_issue(issue, "daemon-a",
               state_path: state_path,
               lease_ttl_ms: 5_000,
               now_ms: 1_000
             )

    assert :ok =
             TrackerCoordinator.refresh_issue_lease(issue.id, "daemon-a",
               state_path: state_path,
               lease_ttl_ms: 5_000,
               now_ms: 4_000
             )

    assert {:error, :leased} =
             TrackerCoordinator.claim_issue(issue, "daemon-b",
               state_path: state_path,
               lease_ttl_ms: 5_000,
               now_ms: 7_000
             )

    assert :ok =
             TrackerCoordinator.claim_issue(issue, "daemon-b",
               state_path: state_path,
               lease_ttl_ms: 5_000,
               now_ms: 10_000
             )
  end

  test "fresh lock contention fails closed instead of running unlocked", %{state_path: state_path} do
    lock_path = state_path <> ".lock"
    File.mkdir_p!(Path.dirname(lock_path))

    File.write!(
      lock_path,
      :erlang.term_to_binary(%{pid: self(), acquired_at_ms: System.system_time(:millisecond)})
    )

    fetch_fun = fn -> flunk("coordinator must not fetch while lock is unavailable") end

    assert {:error, {:coordinator_lock_unavailable, :busy}} =
             TrackerCoordinator.resolve_candidate_issues(nil, fetch_fun,
               state_path: state_path,
               lock_retry_attempts: 1,
               lock_retry_sleep_ms: 1
             )
  end

  test "write failures return controlled coordinator errors", %{state_path: state_path} do
    File.mkdir_p!(state_path <> ".tmp")

    assert {:error, {:coordinator_write_failed, reason}} =
             TrackerCoordinator.claim_issue(issue("issue-write-error", "MT-WRITE"), "daemon-a", state_path: state_path)

    assert reason in [:eisdir, :eacces]
  end

  test "stale coordinator lock file is recovered after a daemon dies", %{
    state_path: state_path
  } do
    lock_path = state_path <> ".lock"
    File.mkdir_p!(Path.dirname(lock_path))

    File.write!(
      lock_path,
      :erlang.term_to_binary(%{
        pid: :dead_daemon,
        acquired_at_ms: System.system_time(:millisecond) - 120_000
      })
    )

    issue = issue("issue-stale-lock", "MT-STALE-LOCK")
    resolution = RunTarget.Resolution.new(nil, [issue], [])

    assert {:ok, ^resolution} =
             TrackerCoordinator.resolve_candidate_issues(nil, fn -> {:ok, resolution} end,
               state_path: state_path,
               now_ms: 1_000
             )

    refute File.exists?(lock_path)
  end

  test "coordinator state stays under operator runtime path, not target repo config" do
    Application.delete_env(:symphony_elixir, :tracker_coordinator_state_path)
    state_path = TrackerCoordinator.state_path()

    refute String.ends_with?(state_path, "symphony.yml")
    assert state_path =~ ".symphony"
  end

  test "default coordinator path supports candidate fetch and snapshot" do
    issue = issue("issue-default", "MT-DEFAULT")
    resolution = RunTarget.Resolution.new(nil, [issue], [])

    assert {:ok, ^resolution} =
             TrackerCoordinator.resolve_candidate_issues(nil, fn -> {:ok, resolution} end)

    assert %{cache_entries: 1, leases: []} = TrackerCoordinator.snapshot()
  end

  test "explicit RunTarget participates in cache keys", %{state_path: state_path} do
    target = %RunTarget{type: :issues, issue_ids: ["issue-target"]}
    resolution = RunTarget.Resolution.new(target, [issue("issue-target", "MT-TARGET")], [])

    assert {:ok, ^resolution} =
             TrackerCoordinator.resolve_candidate_issues(target, fn -> {:ok, resolution} end, state_path: state_path)
  end

  test "refresh and release respect lease ownership", %{state_path: state_path} do
    issue = issue("issue-release", "MT-RELEASE")

    assert :ok = TrackerCoordinator.claim_issue(issue, "daemon-a", state_path: state_path)
    assert {:error, :leased} = TrackerCoordinator.refresh_issue_lease(issue.id, "daemon-b", state_path: state_path)
    assert :ok = TrackerCoordinator.release_issue(issue.id, "daemon-b", state_path: state_path)
    assert [%{owner_id: "daemon-a"}] = TrackerCoordinator.snapshot(state_path: state_path).leases

    assert :ok = TrackerCoordinator.release_issue(issue.id, "daemon-a", state_path: state_path)
    assert [] = TrackerCoordinator.snapshot(state_path: state_path).leases

    assert :ok = TrackerCoordinator.claim_issue(issue, "daemon-a", state_path: state_path)
    assert :ok = TrackerCoordinator.release_issue(issue.id, nil, state_path: state_path)
    assert [] = TrackerCoordinator.snapshot(state_path: state_path).leases
  end

  test "state decoding failures fall back to empty state", %{state_path: state_path} do
    File.mkdir_p!(Path.dirname(state_path))
    File.write!(state_path, :erlang.term_to_binary(%{unexpected: true}))
    assert %{cache_entries: 0, leases: [], rate_limit: nil} = TrackerCoordinator.snapshot(state_path: state_path)

    File.write!(state_path, <<131, 255>>)
    assert %{cache_entries: 0, leases: [], rate_limit: nil} = TrackerCoordinator.snapshot(state_path: state_path)
  end

  test "unreadable state returns a controlled write error after fallback", %{state_path: state_path} do
    File.mkdir_p!(state_path)

    assert {:error, {:coordinator_write_failed, reason}} =
             TrackerCoordinator.snapshot(state_path: state_path)

    assert reason in [:eisdir, :eacces, :enotdir]
  end

  test "malformed lock files are not treated as stale", %{state_path: state_path} do
    lock_path = state_path <> ".lock"
    File.mkdir_p!(Path.dirname(lock_path))
    File.write!(lock_path, <<131, 255>>)

    assert {:error, {:coordinator_lock_unavailable, :busy}} =
             TrackerCoordinator.rate_limit(
               state_path: state_path,
               lock_retry_attempts: 1,
               lock_retry_sleep_ms: 1
             )
  end

  test "lock open failures return controlled coordinator errors", %{state_path: state_path} do
    lock_path = state_path <> ".lock"
    File.mkdir_p!(lock_path)

    assert {:error, {:coordinator_lock_unavailable, reason}} =
             TrackerCoordinator.rate_limit(state_path: state_path)

    assert reason == :busy
  end

  test "rate-limit normalization handles reset headers and malformed details", %{state_path: state_path} do
    reset_at = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601()

    assert %{remaining_ms: reset_remaining_ms} =
             TrackerCoordinator.record_rate_limit(%{reset_at: reset_at}, :candidate_fetch,
               state_path: state_path,
               now_ms: 1_000
             )

    assert reset_remaining_ms > 0

    assert %{remaining_ms: 30_000} =
             TrackerCoordinator.record_rate_limit(%{retry_after_ms: "bad", reset_at: "not-a-date"}, :candidate_fetch,
               state_path: state_path,
               now_ms: 2_000
             )

    assert %{remaining_ms: 30_000} =
             TrackerCoordinator.record_rate_limit(%{retry_after_ms: "bad"}, :candidate_fetch,
               state_path: state_path,
               now_ms: 2_500
             )

    assert %{error: ":unexpected", remaining_ms: 30_000} =
             TrackerCoordinator.record_rate_limit(:unexpected, :candidate_fetch,
               state_path: state_path,
               now_ms: 3_000
             )

    assert TrackerCoordinator.rate_limit(state_path: state_path, now_ms: 40_000) == nil
  end

  test "snapshot preserves malformed lease entries until a valid expiry exists", %{state_path: state_path} do
    File.mkdir_p!(Path.dirname(state_path))

    state = %{
      version: 1,
      caches: %{},
      leases: %{"malformed" => %{owner_id: "daemon-a"}},
      rate_limit: nil
    }

    File.write!(state_path, :erlang.term_to_binary(state))

    assert [%{owner_id: "daemon-a"}] = TrackerCoordinator.snapshot(state_path: state_path).leases
  end

  test "malformed rate-limit entries expire instead of surfacing", %{state_path: state_path} do
    File.mkdir_p!(Path.dirname(state_path))

    state = %{
      version: 1,
      caches: %{},
      leases: %{},
      rate_limit: %{reason: :tracker_rate_limited}
    }

    File.write!(state_path, :erlang.term_to_binary(state))

    assert TrackerCoordinator.rate_limit(state_path: state_path) == nil
  end

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Tracker coordinator test",
      state: "Todo"
    }
  end
end
