defmodule SymphonyElixir.LocalRunTest do
  use ExUnit.Case

  alias SymphonyElixir.LocalRun
  alias SymphonyElixir.Workflow.Renderer

  test "interactive builder creates first-run config, discovers projects, previews, and saves setup" do
    root = tmp_root!("local-run-interactive")
    repo = tmp_repo!(root)
    config_root = Path.join(root, "config")
    parent = self()

    deps =
      deps(root,
        prompt_answers: ["2", "1", "2", "", "y", "dogfood"],
        env: %{"LINEAR_API_KEY" => "linear-token"},
        discovery: fn :projects, "linear-token" ->
          send(parent, :project_discovery_attempted)
          {:ok, [%{id: "project-id", name: "Symphony", slug: "symphony"}]}
        end
      )

    assert {:ok, result} =
             LocalRun.evaluate(["--repo", repo, "--config-root", config_root, "--dry-run"], deps)

    assert_received :project_discovery_attempted
    assert File.regular?(Path.join(config_root, "config.yml"))
    assert result.start? == false
    assert result.saved_path == Path.join([config_root, "runs", "dogfood.yml"])
    assert File.regular?(result.saved_path)
    refute Map.has_key?(result.setup, "_field_sources")
    refute Map.has_key?(result.setup, "_runtime_allowed?")
    assert result.setup["runtime"]["workspace"]["root"] == "~/dev/symphony-workspaces"
    assert result.setup["runtime"]["tracker"]["project_id"] == "project-id"
    assert result.setup["runtime"]["agent"]["max_concurrent_agents"] == 4
    assert result.setup["runtime"]["target"]["mode"] == "continuous"
    assert result.setup["runtime"]["runners"]["codex"]["approval_policy"] == "never"
    assert result.preview =~ "Run preview"
    assert result.preview =~ "Target: Linear project Symphony (project-id)"
    assert result.preview =~ "Capacity: normal (agents=4, startups=1)"
  end

  test "default Linear discovery starts Req before fetching projects" do
    root = tmp_root!("local-run-default-discovery")
    repo = tmp_repo!(root)
    config_root = Path.join(root, "config")
    previous_options = Application.get_env(:symphony_elixir, :linear_discovery_req_options)

    Application.put_env(:symphony_elixir, :linear_discovery_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      if previous_options do
        Application.put_env(:symphony_elixir, :linear_discovery_req_options, previous_options)
      else
        Application.delete_env(:symphony_elixir, :linear_discovery_req_options)
      end
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "projects" => %{
            "nodes" => [
              %{"id" => "project-id", "name" => "Symphony", "slugId" => "symphony"}
            ]
          }
        }
      })
    end)

    assert {:ok, result} =
             LocalRun.evaluate(
               ["--repo", repo, "--config-root", config_root, "--dry-run"],
               deps(root,
                 prompt_answers: ["2", "1", "2", "", "n"],
                 env: %{"LINEAR_API_KEY" => "linear-token"}
               )
             )

    assert result.setup["runtime"]["tracker"]["project_id"] == "project-id"
    assert result.preview =~ "Target: Linear project Symphony (project-id)"
  end

  test "manual target entry works when discovery fails" do
    root = tmp_root!("local-run-fallback")
    repo = tmp_repo!(root)
    parent = self()

    deps =
      deps(root,
        prompt_answers: ["3", "SID", "2", "", "n"],
        env: %{"LINEAR_API_KEY" => "linear-token"},
        discovery: fn :teams, "linear-token" ->
          send(parent, :team_discovery_attempted)
          {:error, :unavailable}
        end
      )

    assert {:ok, result} =
             LocalRun.evaluate(["--repo", repo, "--config-root", Path.join(root, "config"), "--dry-run"], deps)

    assert_received :team_discovery_attempted
    assert result.saved_path == nil
    assert result.setup["runtime"]["tracker"]["team_key"] == "SID"
    assert result.preview =~ "Target: Linear team SID"
    assert result.preview =~ "Discovery: failed (:unavailable); using manual entry"
  end

  test "interactive query file target defaults to query mode" do
    root = tmp_root!("local-run-query-file")
    repo = tmp_repo!(root)
    query_path = Path.join(root, "linear-filter.yml")

    File.write!(query_path, """
    priority:
      lte: 2
    """)

    assert {:ok, result} =
             LocalRun.evaluate(
               ["--repo", repo, "--config-root", Path.join(root, "config"), "--dry-run"],
               deps(root, prompt_answers: ["4", query_path, "1", "", "n"])
             )

    assert result.setup["runtime"]["target"]["type"] == "query"
    assert result.setup["runtime"]["target"]["filter"] == %{"priority" => %{"lte" => 2}}
    assert result.setup["runtime"]["target"]["mode"] == "query"
    assert result.preview =~ "Target: Linear query filter file #{query_path}"
    assert result.preview =~ "Mode: query"
  end

  test "saved run setups round trip by name through the same preview" do
    root = tmp_root!("local-run-round-trip")
    repo = tmp_repo!(root)
    config_root = Path.join(root, "config")

    save_deps = deps(root, prompt_answers: ["n"])

    assert {:ok, saved} =
             LocalRun.evaluate(
               ["SID-374", "--repo", repo, "--config-root", config_root, "--save", "sid-374", "--dry-run"],
               save_deps
             )

    assert saved.setup["runtime"]["target"]["mode"] == "issue-batch"
    assert {:ok, persisted_setup} = YamlElixir.read_from_file(saved.saved_path)
    assert persisted_setup["repo"]["path"] == repo
    assert persisted_setup["target"]["tracker"]["issue_ids"] == ["SID-374"]
    refute Map.has_key?(persisted_setup, "runtime")

    load_deps = deps(root, prompt_answers: [])
    assert {:ok, loaded} = LocalRun.evaluate(["sid-374", "--config-root", config_root, "--dry-run"], load_deps)

    assert loaded.source == :saved
    assert loaded.setup["runtime"]["tracker"]["issue_ids"] == ["SID-374"]
    assert loaded.setup["runtime"]["target"] == saved.setup["runtime"]["target"]
    assert loaded.preview == LocalRun.preview(loaded.setup, loaded.workflow_path)
    assert loaded.preview =~ "Target: Issues SID-374"
  end

  test "--setup materializes canonical saved run setup files" do
    root = tmp_root!("local-run-canonical-setup")
    repo = tmp_repo!(root)
    config_root = Path.join(root, "config")
    File.mkdir_p!(Path.join(config_root, "runs"))

    File.write!(
      Path.join([config_root, "runs", "dogfood.yml"]),
      Renderer.to_yaml(%{
        "repo" => %{"path" => repo},
        "target" => %{"type" => "issues", "tracker" => %{"issue_ids" => ["SID-374"]}},
        "mode" => "issue-batch",
        "capacity" => "light"
      })
    )

    assert {:ok, loaded} = LocalRun.evaluate(["--setup", "dogfood", "--config-root", config_root, "--dry-run"], deps(root, prompt_answers: []))

    assert loaded.setup["runtime"]["tracker"]["issue_ids"] == ["SID-374"]
    assert loaded.setup["runtime"]["target"]["mode"] == "issue-batch"
    assert loaded.preview =~ "Target: Issues SID-374"
  end

  test "explicit Linear UUID targets default to issue-batch mode" do
    root = tmp_root!("local-run-uuid")
    repo = tmp_repo!(root)
    issue_id = "11111111-1111-1111-1111-111111111111"

    assert {:ok, result} =
             LocalRun.evaluate(
               [issue_id, "--repo", repo, "--config-root", Path.join(root, "config"), "--dry-run"],
               deps(root, prompt_answers: [])
             )

    assert result.setup["runtime"]["tracker"]["issue_ids"] == [issue_id]
    assert result.setup["runtime"]["target"]["mode"] == "issue-batch"
  end

  test "explicit issue identifiers default to issue-batch mode" do
    root = tmp_root!("local-run-issues")
    repo = tmp_repo!(root)

    assert {:ok, result} =
             LocalRun.evaluate(
               ["SID-374", "SID-375", "--repo", repo, "--config-root", Path.join(root, "config"), "--dry-run"],
               deps(root, prompt_answers: [])
             )

    assert result.setup["runtime"]["tracker"]["issue_ids"] == ["SID-374", "SID-375"]
    assert result.setup["runtime"]["target"]["type"] == "issues"
    assert result.setup["runtime"]["target"]["mode"] == "issue-batch"
    assert result.preview =~ "Mode: issue-batch"
  end

  test "accepted run preview starts explicit issue runs" do
    root = tmp_root!("local-run-start")
    repo = tmp_repo!(root)

    assert {:ok, result} =
             LocalRun.evaluate(
               ["SID-374", "--repo", repo, "--config-root", Path.join(root, "config")],
               deps(root, prompt_answers: [""])
             )

    assert result.start? == true
    assert result.setup["runtime"]["target"]["mode"] == "issue-batch"
    assert result.preview =~ "Target: Issues SID-374"
  end

  test "custom capacity is bounded by the configured ceiling" do
    root = tmp_root!("local-run-capacity")
    repo = tmp_repo!(root)

    result =
      LocalRun.evaluate(
        ["--repo", repo, "--config-root", Path.join(root, "config"), "--dry-run"],
        deps(root, prompt_answers: ["1", "SID-374", "4", "11"])
      )

    assert {:error, message} = result
    assert message =~ "Custom capacity must be between 1 and 10"
  end

  defp deps(root, opts) do
    answers = Keyword.fetch!(opts, :prompt_answers)
    env = Keyword.get(opts, :env, %{})
    discovery = Keyword.get(opts, :discovery)
    parent = self()

    prompt_agent =
      start_supervised!({Agent, fn -> answers end},
        id: {:prompt_answers, System.unique_integer([:positive])}
      )

    deps = %{
      prompt: fn prompt ->
        send(parent, {:prompt, prompt})

        Agent.get_and_update(prompt_agent, fn
          [answer | rest] -> {answer, rest}
          [] -> {nil, []}
        end)
      end,
      puts: fn output -> send(parent, {:output, output}) end,
      env: fn key -> Map.get(env, key) end,
      home: fn -> root end,
      cwd: fn -> root end
    }

    if discovery do
      Map.put(deps, :linear_discovery, discovery)
    else
      deps
    end
  end

  defp tmp_root!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)

    on_exit(fn -> File.rm_rf!(path) end)

    path
  end

  defp tmp_repo!(root) do
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)

    File.write!(Path.join(repo, "symphony.yml"), """
    version: 1
    project:
      slug: symphony
      name: Symphony
      repository: https://github.com/apontarelli/symphony
      kind: elixir
      app_kind: web
    workflow:
      preset: default
    validation:
      commands:
        - name: all
          command: cd elixir && mise exec -- make all
    vcs:
      mode: jj
      default_branch: main
    delivery:
      pr_target: main
    automation:
      posture: unattended
      profile: default
    harness:
      codex_home: null
    """)

    repo
  end
end
