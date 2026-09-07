defmodule SymphonyElixir.HostSetupAdmissionSmokeTest do
  @moduledoc """
  Runnable real-host setup-to-admission smoke.

  Boots one real host (registry file, scheduler, control plane, operator
  interface), then walks the SID-496 operator journey end to end:

    1. settings Apply creates a paused target on a real local repository,
    2. Activate separately permits admission,
    3. an explicit issue batch is previewed and confirmed on the same host,
    4. host routing rules resolve the issue to exactly one repository,
    5. the run is admitted through the durable control plane with its policy
       pinned, and a later settings Apply cannot retroactively change it.

  Linear responses come from an HTTP client fixture and the runtime adapter stops
  after admission. The host polls and admits work without direct test admission.
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.{
    ControlPlane,
    HostScheduler,
    OperatorInterface,
    OperatorSettings
  }

  alias SymphonyElixir.HostScheduler.Registry
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Linear.MetadataCache
  alias SymphonyElixir.TargetRegistry.Yaml

  defmodule TrackerFixture do
    def init(opts), do: opts

    def call(conn, _opts) do
      issue = %{
        "id" => "SID-1001",
        "identifier" => "SID-1001",
        "title" => "Setup-to-admission smoke",
        "state" => %{"name" => "Todo"},
        "team" => %{"id" => "eng", "key" => "ENG"},
        "project" => %{"id" => "project-1", "slugId" => "p1"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "issue" => issue,
            "issues" => %{"nodes" => [issue], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}
          }
        })
      )
    end
  end

  defmodule AdmissionOnlyRuntime do
    @behaviour SymphonyElixir.AgentRuntime
    def start(_context, _issue, _opts), do: {:error, :smoke_admission_complete}
    def send_turn(_session, _prompt, _issue, _opts), do: {:error, :smoke_admission_complete}
    def stop(_session), do: :ok
    def capabilities(_config), do: %{}
  end

  @moduletag :tmp_dir
  @repo Path.expand("../fixtures/target_registry/repos/symphony", __DIR__)

  setup %{tmp_dir: root} do
    {repo, policy} = SymphonyElixir.TestSupport.host_repository_fixture(root, @repo)
    previous_http_options = Req.default_options()
    Req.default_options(Keyword.put(previous_http_options, :plug, TrackerFixture))
    on_exit(fn -> Req.default_options(previous_http_options) end)
    previous_key = System.get_env("SID496_SMOKE_KEY")
    System.put_env("SID496_SMOKE_KEY", "loopback-fixture")

    on_exit(fn ->
      if previous_key, do: System.put_env("SID496_SMOKE_KEY", previous_key), else: System.delete_env("SID496_SMOKE_KEY")
    end)

    path = Path.join([root, "registry", "targets.yml"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Yaml.encode(empty_registry(root)))

    control_plane = start_supervised!({ControlPlane, name: unique_name(), config_root: root})
    target_supervisor = start_supervised!({SymphonyElixir.TargetSupervisor, name: unique_name()})

    scheduler =
      start_supervised!(
        {HostScheduler,
         name: unique_name(),
         registry_path: path,
         target_supervisor: target_supervisor,
         registry_reload_interval_ms: 60_000,
         orchestrator_opts: [
           control_plane: control_plane,
           agent_runner_options: [adapter_registry: %{"codex_app_server" => AdmissionOnlyRuntime}]
         ]}
      )

    interface =
      start_supervised!({OperatorInterface, name: unique_name(), config_root: root, install_log_handler: false})

    {:ok, metadata} = OperatorInterface.credentials(interface)
    credential = File.read!(metadata.token_path)

    data = %{
      teams: [%{id: "eng", key: "ENG", name: "Engineering"}],
      projects: [%{id: "project-1", slug_id: "p1", name: "Smoke", team_ids: ["eng"]}],
      states: [
        %{id: "todo", name: "Todo", type: "unstarted", team_id: "eng"},
        %{id: "done", name: "Done", type: "completed", team_id: "eng"}
      ],
      labels: []
    }

    cache =
      start_supervised!({MetadataCache, name: nil, fetch_fun: fn _ -> {:ok, data} end, env_fetcher: fn _ -> "fixture-key" end})

    await_metadata(cache, %{"id" => "linear-main", "policy" => empty_registry(root)["host"]["tracker_connections"]["linear-main"]})

    issue = %Issue{
      id: "SID-1001",
      identifier: "SID-1001",
      title: "Setup-to-admission smoke",
      state: "Todo",
      team_key: "ENG",
      project_id: "project-1",
      labels: []
    }

    opts = [
      host_scheduler: scheduler,
      control_plane: control_plane,
      config_root: root,
      metadata_cache: [server: cache],
      fetch_issues: fn _target, _ids -> {:ok, [issue]} end
    ]

    %{
      scheduler: scheduler,
      control_plane: control_plane,
      interface: interface,
      credential: credential,
      opts: opts,
      path: path,
      repo: repo,
      policy: policy,
      issue: issue,
      root: root
    }
  end

  test "settings Apply, Activate, explicit batch, routing, and pinned admission", context do
    # 1. Setup: Apply creates the target paused. Nothing is admitted yet.
    apply_command = %{
      "action" => "settings_apply",
      "target_id" => "delivery",
      "inputs" => %{"repository" => context.repo, "selections" => target_selections(context)}
    }

    {apply_request, apply_preview} = preview!(context, apply_command)
    assert apply_preview.identity.mode == "create"
    assert apply_preview.proposed_state.target["configured_state"] == "paused"
    assert apply_preview.proposed_state.settings.values["linear.scope.project_id"] == "project-1"

    applied = confirm!(context, apply_request, apply_preview)
    assert applied.status == "completed"
    assert applied.result.committed? == true
    assert applied.result.settings.values["repo.path"] == context.repo
    assert applied.result.settings.revisions["registry"] == HostScheduler.snapshot(context.scheduler).registry.generation

    snapshot = HostScheduler.snapshot(context.scheduler)
    delivery = snapshot.targets["delivery"]
    assert delivery.configured_state == :paused
    assert delivery.effective_state == :paused
    assert snapshot.registry.verified? == true

    # 2. Activation is a separate preview and confirm that permits admission.
    activate_command = %{"action" => "activate", "target_id" => "delivery", "inputs" => %{"dispatch_mode" => "explicit"}}

    {activate_request, activate_preview} = preview!(context, activate_command)
    assert activate_preview.consequences |> hd() =~ "active"
    assert confirm!(context, activate_request, activate_preview).status == "completed"

    snapshot = HostScheduler.snapshot(context.scheduler)
    assert snapshot.targets["delivery"].effective_state == :active

    # 3. An explicit batch previews its exact issue, repository, policy, and
    #    limits, and commits as a scope update on the same target and host.
    batch_command = %{"action" => "batch", "target_id" => "delivery", "inputs" => %{"issue_ids" => ["SID-1001"]}}

    {batch_request, batch_preview} = preview!(context, batch_command)
    batch = batch_preview.proposed_state.batch
    assert [%{identifier: "SID-1001", state: "Todo"}] = batch.issues
    assert batch.repository == context.policy["project"]["repository"]
    assert is_binary(batch.policy.policy_hash)
    assert batch.limits.issue_batch_limit == 1

    batched = confirm!(context, batch_request, batch_preview)
    assert batched.status == "completed"
    assert batched.result.batch.issue_ids == ["SID-1001"]

    {:ok, reloaded} = Registry.load(context.path)
    pinned = reloaded.contexts["delivery"]
    assert pinned.state == :active
    assert pinned.dispatch_mode == :explicit
    assert pinned.capacity_limits["issue_batch_limit"] == 1

    # 4. The host routing rules resolve the admitted issue to one repository.
    catalog = OperatorSettings.build(context.scheduler, %{"target_id" => "delivery"}, context.opts)
    assert catalog.routing.status == "routed"
    assert catalog.routing.repository == context.policy["project"]["repository"]

    # 5. Admission runs through the durable control plane with the policy
    #    pinned at admission time.
    assert :ok = HostScheduler.resolve_issue_routing(context.scheduler, "delivery", context.issue)
    admission = await_admission(context.control_plane)
    admitted_hash = admission.context.target.policy_hash
    assert admitted_hash == pinned.policy_hash

    # 6. A later settings Apply changes future admissions only.
    patch_command = %{
      "action" => "settings_apply",
      "target_id" => "delivery",
      "inputs" => %{"selections" => %{"concurrency.max_concurrent_agents" => 1}}
    }

    {patch_request, patch_preview} = preview!(context, patch_command)
    assert Enum.any?(patch_preview.consequences, &String.contains?(&1, "pinned admission policy"))
    assert confirm!(context, patch_request, patch_preview).status == "completed"

    {:ok, still_pinned} = ControlPlane.fetch_admission(context.control_plane, "delivery", "SID-1001")
    assert still_pinned.context.target.policy_hash == admitted_hash

    {:ok, after_patch} = Registry.load(context.path)
    refute after_patch.contexts["delivery"].policy_hash == admitted_hash
  end

  defp empty_registry(root) do
    {:ok, policy_yaml} = File.read(Path.join(@repo, "symphony.yml"))
    {:ok, policy} = Yaml.decode(policy_yaml)

    %{
      "version" => 1,
      "host" => %{
        "id" => "setup-smoke-host",
        "state_root" => Path.join(root, "state"),
        "polling" => %{"interval_ms" => 30_000, "max_concurrent_target_polls" => 1},
        "capacity" => %{"max_concurrent_agents" => 4, "max_concurrent_startups" => 2, "max_concurrent_reviewers" => 1},
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 4},
        "tracker_connections" => %{
          "linear-main" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "$SID496_SMOKE_KEY"
          }
        },
        "runners" => %{
          "codex" => %{
            "kind" => "codex_app_server",
            "command" => ["codex", "app-server"],
            "turn_timeout_ms" => 60_000,
            "max_concurrent_agents" => 4,
            "max_concurrent_startups" => 2
          }
        },
        "repository_defaults" =>
          Map.merge(policy, %{
            "capabilities" => %{"required" => []},
            "issue_markers" => %{"labels" => [], "allowed_projects" => []}
          })
      },
      "targets" => %{}
    }
  end

  defp target_selections(context) do
    %{
      "display_name" => "Delivery",
      "worktree.root" => Path.join(context.root, "delivery-worktrees"),
      "worktree.strategy" => "per_issue",
      "linear.connection" => "linear-main",
      "linear.scope.type" => "project",
      "linear.scope.project_id" => "project-1",
      "linear.active_states" => ["Todo"],
      "linear.terminal_states" => ["Done"],
      "linear.required_labels" => [],
      "runners.allowed" => ["codex"],
      "runners.default" => "codex",
      "concurrency.max_concurrent_agents" => 2,
      "concurrency.max_concurrent_startups" => 1,
      "concurrency.max_concurrent_reviewers" => 1,
      "budgets.per_run.max_total_tokens" => 5_000,
      "budgets.daily.max_total_tokens" => 50_000,
      "budgets.weekly.max_total_tokens" => 250_000,
      "checks.pre_dispatch" => ["capability_preflight"],
      "checks.pre_handoff" => [],
      "checks.pre_publish" => [],
      "checks.pre_merge" => [],
      "scheduling.weight" => 1
    }
  end

  defp request(context, command) do
    {:ok, marker} = OperatorInterface.marker(context.interface)

    command =
      if get_in(command, ["inputs", "selections", "linear.connection"]) do
        catalog = OperatorSettings.build(context.scheduler, command["inputs"], context.opts)
        put_in(command, ["inputs", "linear_revision"], catalog.revisions["linear"])
      else
        command
      end

    %{
      "interface_version" => 1,
      "host_id" => marker.host_id,
      "registry_generation" => HostScheduler.snapshot(context.scheduler).registry.generation,
      "command" => command
    }
  end

  defp preview!(context, command) do
    request = request(context, command)
    assert {:ok, preview} = OperatorInterface.preview(context.interface, context.credential, request, context.opts)
    {request, preview}
  end

  defp confirm!(context, request, preview) do
    assert {:ok, accepted} =
             OperatorInterface.confirm(
               context.interface,
               context.credential,
               Map.put(request, "confirmation_token", preview.confirmation_token)
             )

    await_result(context.interface, accepted.id)
  end

  defp await_result(interface, id, attempts \\ 200)

  defp await_result(_interface, _id, 0), do: flunk("command did not complete")

  defp await_result(interface, id, attempts) do
    {:ok, marker} = OperatorInterface.marker(interface)
    result = Enum.find(marker.command_results, &(&1.id == id))

    if result && result.status != "accepted" do
      result
    else
      Process.sleep(5)
      await_result(interface, id, attempts - 1)
    end
  end

  defp await_admission(control_plane, attempts \\ 200)
  defp await_admission(_control_plane, 0), do: flunk("host did not admit the confirmed batch")

  defp await_admission(control_plane, attempts) do
    case ControlPlane.fetch_admission(control_plane, "delivery", "SID-1001") do
      {:ok, admission} ->
        admission

      _ ->
        Process.sleep(10)
        await_admission(control_plane, attempts - 1)
    end
  end

  defp unique_name do
    Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")
  end

  defp await_metadata(cache, connection, attempts \\ 200)
  defp await_metadata(_cache, _connection, 0), do: flunk("metadata did not become ready")

  defp await_metadata(cache, connection, attempts) do
    case MetadataCache.get(connection, server: cache) do
      %{status: "current"} ->
        :ok

      _ ->
        Process.sleep(5)
        await_metadata(cache, connection, attempts - 1)
    end
  end
end
