defmodule SymphonyElixir.AgentRunnerContextTest.RuntimeAdapter do
  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.ExecutionContext

  @impl true
  def start(%ExecutionContext{} = context, issue, []) do
    notify({
      :runtime_started,
      context.target.target_id,
      context.runner_name,
      context.workspace_path,
      context.policy,
      issue.identifier
    })

    {:ok, %{context: context}}
  end

  @impl true
  def send_turn(%{context: context}, prompt, issue, opts) do
    notify({:runtime_turn, context.target.target_id, prompt, issue.state, Keyword.keys(opts)})

    case context.runner_config["test_turn_result"] do
      "error" -> {:error, {:primary_failed, context.target.target_id}}
      _success -> {:ok, %{session_id: "session-#{context.target.target_id}"}}
    end
  end

  @impl true
  def stop(%{context: context}) do
    notify({:runtime_stopped, context.target.target_id})

    case context.runner_config["test_stop_result"] do
      "error" -> {:error, {:cleanup_failed, context.target.target_id}}
      _success -> :ok
    end
  end

  @impl true
  def capabilities(_runner_config), do: %{}

  defp notify(message) do
    if recipient = Application.get_env(:symphony_elixir, :agent_runner_context_test_recipient) do
      send(recipient, message)
    end
  end
end

defmodule SymphonyElixir.AgentRunnerContextTest.LinearClient do
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TargetContext

  def fetch_issue_states_by_ids(%TargetContext{} = target, [issue_id]) do
    if recipient = Application.get_env(:symphony_elixir, :agent_runner_context_test_recipient) do
      send(
        recipient,
        {
          :tracker_refresh,
          target.target_id,
          target.tracker_connection["id"],
          target.registry_generation,
          [issue_id]
        }
      )
    end

    {:ok,
     [
       %Issue{
         id: issue_id,
         identifier: "SID-420",
         title: "Pinned refresh",
         state: List.first(target.run_target["active_states"]),
         labels: target.run_target["required_labels"]
       }
     ]}
  end
end

defmodule SymphonyElixir.AgentRunnerContextTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunnerContextTest.{LinearClient, RuntimeAdapter}
  alias SymphonyElixir.{ExecutionContext, TargetContext}
  alias SymphonyElixir.Workflow.Manifest

  @hash "sha256:" <> String.duplicate("a", 64)
  @adapter_registry %{"codex_app_server" => RuntimeAdapter}

  setup do
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_recipient = Application.get_env(:symphony_elixir, :agent_runner_context_test_recipient)

    Application.put_env(:symphony_elixir, :linear_client_module, LinearClient)
    Application.put_env(:symphony_elixir, :agent_runner_context_test_recipient, self())

    on_exit(fn ->
      restore_application_env(:linear_client_module, previous_client)
      restore_application_env(:agent_runner_context_test_recipient, previous_recipient)
    end)

    :ok
  end

  @tag :tmp_dir
  test "concurrent workers keep lifecycle authority pinned after global config changes", %{tmp_dir: tmp_dir} do
    issue = %Issue{
      id: "issue-420",
      identifier: "SID-420",
      title: "Isolate agent workers",
      state: "In Progress",
      labels: ["admitted"]
    }

    alpha = execution_context(tmp_dir, "alpha", issue, max_turns: 2)
    beta = execution_context(tmp_dir, "beta", issue, max_turns: 2)
    parent = self()

    tasks =
      for context <- [alpha, beta] do
        Task.async(fn ->
          send(parent, {:worker_admitted, self()})

          receive do
            :run -> AgentRunner.run_context(context, issue, parent, adapter_registry: @adapter_registry)
          end
        end)
      end

    task_pids =
      for _ <- tasks do
        assert_receive {:worker_admitted, task_pid}
        task_pid
      end

    poisoned_root = Path.join(tmp_dir, "poisoned")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: poisoned_root,
      tracker_active_states: ["Poisoned"],
      tracker_required_labels: ["poisoned"],
      max_turns: 9,
      codex_model: "poisoned-model"
    )

    Enum.each(task_pids, &send(&1, :run))
    assert Enum.map(tasks, &Task.await(&1, 5_000)) == [:ok, :ok]

    starts = receive_tagged(:runtime_started, 2)
    turns = receive_tagged(:runtime_turn, 4)
    refreshes = receive_tagged(:tracker_refresh, 4)
    stops = receive_tagged(:runtime_stopped, 2)

    assert Enum.map(starts, &elem(&1, 1)) |> Enum.sort() == ["alpha", "beta"]
    assert Enum.map(starts, &elem(&1, 2)) |> Enum.sort() == ["runner-alpha", "runner-beta"]
    assert Enum.map(starts, &elem(&1, 3)) |> Enum.sort() == Enum.sort([alpha.workspace_path, beta.workspace_path])
    assert Enum.map(starts, &get_in(elem(&1, 4), ["target"])) |> Enum.sort() == ["alpha", "beta"]

    assert Enum.count(turns, &(elem(&1, 1) == "alpha")) == 2
    assert Enum.count(turns, &(elem(&1, 1) == "beta")) == 2
    assert Enum.any?(turns, fn message -> elem(message, 1) == "alpha" and elem(message, 2) =~ "target=alpha" end)
    assert Enum.any?(turns, fn message -> elem(message, 1) == "beta" and elem(message, 2) =~ "target=beta" end)
    refute Enum.any?(turns, &(elem(&1, 2) =~ "poisoned"))

    assert Enum.map(refreshes, &{elem(&1, 1), elem(&1, 2)}) |> Enum.sort() == [
             {"alpha", "linear-alpha"},
             {"alpha", "linear-alpha"},
             {"beta", "linear-beta"},
             {"beta", "linear-beta"}
           ]

    assert Enum.map(refreshes, &elem(&1, 3)) == [@hash, @hash, @hash, @hash]
    assert Enum.map(stops, &elem(&1, 1)) |> Enum.sort() == ["alpha", "beta"]

    assert_receive {:runtime_event, "issue-420", %{event: :agent_max_turns_exhausted, max_turns: 2}}
    assert_receive {:runtime_event, "issue-420", %{event: :agent_max_turns_exhausted, max_turns: 2}}

    assert File.read!(Path.join(alpha.workspace_path, "cleanup.txt")) == "alpha"
    assert File.read!(Path.join(beta.workspace_path, "cleanup.txt")) == "beta"
    refute File.exists?(poisoned_root)
  end

  @tag :tmp_dir
  test "primary and runtime cleanup failures remain structured", %{tmp_dir: tmp_dir} do
    issue = %Issue{
      id: "issue-420",
      identifier: "SID-420",
      title: "Preserve both failures",
      state: "In Progress"
    }

    context =
      execution_context(tmp_dir, "alpha", issue,
        test_turn_result: "error",
        test_stop_result: "error"
      )

    assert AgentRunner.run_context(context, issue, self(), adapter_registry: @adapter_registry) ==
             {:error, {:agent_run_failed, {:primary_failed, "alpha"}, {:runtime_cleanup_failed, {:cleanup_failed, "alpha"}}}}

    assert_receive {:runtime_stopped, "alpha"}
    assert File.read!(Path.join(context.workspace_path, "cleanup.txt")) == "alpha"
  end

  defp execution_context(tmp_dir, target_id, issue, opts) do
    root = Path.join(tmp_dir, target_id)
    File.mkdir_p!(root)

    {:ok, loaded_workflow} = Workflow.current()
    {:ok, base_manifest} = Manifest.read(Workflow.workflow_file_path(), repo_setup?: false)

    manifest =
      Map.put(
        base_manifest,
        "prompt_template",
        "target=#{target_id} policy={{ policy.target }}"
      )

    resolution = manifest |> Manifest.compile() |> Map.fetch!(:workflow_module_resolution)
    runner_name = "runner-#{target_id}"

    runner =
      %{
        "kind" => "codex_app_server",
        "command" => ["codex", "app-server"],
        "approval_policy" => "never",
        "thread_sandbox" => "workspace-write",
        "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => false},
        "turn_timeout_ms" => 5_000,
        "max_turns" => Keyword.get(opts, :max_turns, 1),
        "execution_profiles" => %{
          "implementation" => %{
            "model" => "model-#{target_id}",
            "timeout_ms" => 5_000,
            "max_retries" => 0
          }
        }
      }
      |> maybe_put_runner_option("test_turn_result", Keyword.get(opts, :test_turn_result))
      |> maybe_put_runner_option("test_stop_result", Keyword.get(opts, :test_stop_result))

    target = %TargetContext{
      target_id: target_id,
      state: :active,
      dispatch_mode: :explicit,
      registry_generation: @hash,
      policy_hash: @hash,
      repo_manifest_hash: @hash,
      repo_policy: %{
        "manifest" => manifest,
        "manifest_source_dir" => loaded_workflow.manifest_source_dir,
        "workflow_module_resolution" => resolution_projection(resolution)
      },
      tracker_connection: %{
        "id" => "linear-#{target_id}",
        "policy" => %{
          "kind" => "linear",
          "endpoint" => "https://#{target_id}.example.invalid/graphql",
          "api_key" => "key-#{target_id}"
        }
      },
      run_target: %{
        "active_states" => ["#{String.capitalize(target_id)} Active"],
        "required_labels" => ["target:#{target_id}"],
        "scope" => %{"type" => "issues", "issue_ids" => [issue.identifier]}
      },
      worktree_policy: %{
        "root" => root,
        "strategy" => "per_issue",
        "hooks" => %{
          "after_create" => nil,
          "before_run" => nil,
          "after_run" => "printf '#{target_id}' > cleanup.txt",
          "before_remove" => nil,
          "timeout_ms" => 5_000
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

    assert {:ok, context} =
             ExecutionContext.new(target, issue,
               policy: %{
                 "capabilities" => %{"required" => []},
                 "target" => target_id
               }
             )

    context
  end

  defp resolution_projection(resolution) do
    %{
      "module_names" => resolution.module_names,
      "module_refs" => Enum.map(resolution.module_refs, &%{"name" => &1.name, "version" => &1.version}),
      "policy_hash" => resolution.policy_hash,
      "rendered" => resolution.rendered
    }
  end

  defp maybe_put_runner_option(runner, _key, nil), do: runner
  defp maybe_put_runner_option(runner, key, value), do: Map.put(runner, key, value)

  defp receive_tagged(tag, count) do
    for _ <- 1..count do
      receive do
        {^tag, _, _, _, _, _} = message -> message
        {^tag, _, _, _, _} = message -> message
        {^tag, _} = message -> message
      after
        1_000 -> flunk("missing #{tag} message")
      end
    end
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
