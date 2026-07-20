defmodule SymphonyElixir.ProjectWorkflowsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProjectWorkflows
  alias SymphonyElixir.Workflow.Renderer

  setup do
    root = tmp_dir!("symphony-project-workflows")
    repo = Path.join(root, "repo")
    config_root = Path.join(root, "config")
    other_repo = Path.join(root, "other-repo")

    File.mkdir_p!(repo)
    File.mkdir_p!(other_repo)
    write_repo_manifest!(repo, "target-repo")
    write_repo_manifest!(other_repo, "other-repo")

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, repo: repo, config_root: config_root, other_repo: other_repo}
  end

  test "missing config root and runs directory return an empty catalog without creating files", context do
    missing_root = Path.join(context.root, "missing")

    assert {:ok, [], []} = ProjectWorkflows.list(context.repo, config_root: missing_root)
    refute File.exists?(missing_root)

    File.mkdir_p!(context.config_root)
    assert {:ok, [], []} = ProjectWorkflows.list(context.repo, config_root: context.config_root)
    refute File.exists?(Path.join(context.config_root, "runs"))
  end

  test "lists matching path and manifest setups in project order", context do
    write_setup!(context.config_root, "zeta", setup(context.repo, issues_target(["SID-9"]), "watch", "light"))

    write_setup!(
      context.config_root,
      "main",
      setup(%{"manifest" => Path.join(context.repo, "symphony.yml")}, project_target("symphony"), "drain", %{
        "max_concurrent_agents" => 3,
        "max_concurrent_startups" => 1
      })
    )

    write_setup!(context.config_root, "alpha", setup(context.repo, team_target("SID"), "watch", "normal"))
    write_setup!(context.config_root, "default", setup(context.repo, query_target("filters/open.yml"), "issue_batch", "swarm"))
    write_setup!(context.config_root, "foreign", setup(context.other_repo, issues_target(["SID-1"]), "watch", "normal"))
    write_setup!(context.config_root, ".current", setup(context.repo, %{"type" => "query_manual"}, "watch", "light"))

    assert {:ok, workflows, []} = ProjectWorkflows.list(context.repo, config_root: context.config_root)

    assert Enum.map(workflows, & &1.name) == ["default", "main", "alpha", "zeta", ".current"]
    assert Enum.map(workflows, & &1.default_rank) == [:default, :main, nil, nil, nil]
    assert List.last(workflows).source == :current

    assert Enum.find(workflows, &(&1.name == "default")).target == "Linear query file filters/open.yml"
    assert Enum.find(workflows, &(&1.name == "main")).target == "Linear project symphony"
    assert Enum.find(workflows, &(&1.name == "main")).capacity == "3/1"
    assert Enum.find(workflows, &(&1.name == "alpha")).target == "Linear team SID"
    assert Enum.find(workflows, &(&1.name == "zeta")).target == "Issues SID-9"
    refute Enum.any?(workflows, &(&1.name == "foreign"))
  end

  test "invalid and unreadable setup entries become actionable warnings", context do
    runs_dir = Path.join(context.config_root, "runs")
    File.mkdir_p!(runs_dir)
    File.write!(Path.join(runs_dir, "invalid.yml"), "repo: [")
    File.write!(Path.join(runs_dir, "scalar.yml"), "[]")
    write_setup!(context.config_root, "bad-repo", %{"repo" => "not-a-map"})
    write_setup!(context.config_root, "bad-mode", setup(context.repo, %{}, %{}, "normal"))
    write_setup!(context.config_root, "bad-capacity", setup(context.repo, %{}, "watch", 4))
    write_setup!(context.config_root, "Main", setup(context.repo, %{}, "watch", "normal"))
    File.mkdir_p!(Path.join(runs_dir, "unreadable.yml"))
    write_setup!(context.config_root, "valid", setup(context.repo, issues_target(["SID-399"]), "watch", "normal"))

    write_setup!(
      context.config_root,
      "invalid-shape",
      setup(context.repo, %{}, "watch", %{"max_concurrent_agents" => %{}})
    )

    assert {:ok, [%{name: "valid"}], warnings} =
             ProjectWorkflows.list(context.repo, config_root: context.config_root)

    assert length(warnings) == 7
    assert Enum.any?(warnings, &(&1 =~ "invalid.yml" and &1 =~ "invalid YAML"))
    assert Enum.any?(warnings, &(&1 =~ "scalar.yml" and &1 =~ "expected a YAML map"))
    assert Enum.any?(warnings, &(&1 =~ "bad-mode.yml" and &1 =~ "mode must be"))
    assert Enum.any?(warnings, &(&1 =~ "bad-capacity.yml" and &1 =~ "capacity must be"))
    assert Enum.any?(warnings, &(&1 =~ "invalid-shape.yml" and &1 =~ "capacity must be"))
    assert Enum.any?(warnings, &(&1 =~ "Main.yml" and &1 =~ "lowercase slug"))
    assert Enum.any?(warnings, &(&1 =~ "unreadable.yml" and &1 =~ ":eisdir"))
  end

  test "uses safe defaults and summarizes legacy project target shapes", context do
    write_setup!(context.config_root, "empty-project", %{
      "repo" => %{"path" => context.repo},
      "target" => %{"type" => "project"}
    })

    write_setup!(context.config_root, "named-project", %{
      "repo" => %{"path" => context.repo},
      "target" => %{"type" => "project", "name" => "Named project"}
    })

    assert {:ok, workflows, []} = ProjectWorkflows.list(context.repo, config_root: context.config_root)
    assert Enum.map(workflows, & &1.capacity) == ["normal", "normal"]
    assert Enum.map(workflows, & &1.mode) == ["watch", "watch"]
    assert Enum.map(workflows, & &1.target) == ["Linear project", "Linear project Named project"]
  end

  test "derives missing modes and target summaries from canonical run setup rules", context do
    write_setup!(context.config_root, "issues", %{
      "repo" => %{"path" => context.repo},
      "target" => %{"type" => "issues", "tracker" => %{"issue_ids" => ["SID-1"]}}
    })

    write_setup!(context.config_root, "query", %{
      "repo" => %{"path" => context.repo},
      "target" => %{"type" => "query_manual", "name" => "Named query"}
    })

    assert {:ok, workflows, []} = ProjectWorkflows.list(context.repo, config_root: context.config_root)
    assert Enum.find(workflows, &(&1.name == "issues")).mode == "issue-batch"
    assert Enum.find(workflows, &(&1.name == "query")).mode == "watch"
    assert Enum.find(workflows, &(&1.name == "query")).target == "Manual Linear query"
  end

  test "requires a valid repo setup manifest", context do
    repo = Path.join(context.root, "not-configured")
    File.mkdir_p!(repo)

    assert {:error, message} = ProjectWorkflows.list(repo)
    assert message =~ "No repo setup found"
    assert message =~ "symphony setup init"
  end

  test "reports malformed and invalid repo setup manifests", context do
    malformed_repo = Path.join(context.root, "malformed")
    invalid_repo = Path.join(context.root, "invalid")
    File.mkdir_p!(malformed_repo)
    File.mkdir_p!(invalid_repo)
    File.write!(Path.join(malformed_repo, "symphony.yml"), "project: [")
    File.write!(Path.join(invalid_repo, "symphony.yml"), Renderer.to_yaml(%{"version" => 1}))

    assert {:error, malformed_message} =
             ProjectWorkflows.list(malformed_repo, config_root: context.config_root)

    assert malformed_message =~ "Could not read repo setup"

    assert {:error, invalid_message} =
             ProjectWorkflows.list(invalid_repo, config_root: context.config_root)

    assert invalid_message =~ "Invalid repo setup"
  end

  defp setup(repo, target, mode, capacity) when is_binary(repo) do
    setup(%{"path" => repo}, target, mode, capacity)
  end

  defp setup(repo, target, mode, capacity) do
    %{"repo" => repo, "target" => target, "mode" => mode, "capacity" => capacity}
  end

  defp issues_target(issue_ids), do: %{"type" => "issues", "tracker" => %{"issue_ids" => issue_ids}}
  defp project_target(slug), do: %{"type" => "project", "tracker" => %{"project_slug" => slug}}
  defp team_target(key), do: %{"type" => "team", "tracker" => %{"team_key" => key}}
  defp query_target(path), do: %{"type" => "query_file", "tracker" => %{"query_file" => path}}

  defp write_setup!(config_root, name, value) do
    runs_dir = Path.join(config_root, "runs")
    File.mkdir_p!(runs_dir)
    File.write!(Path.join(runs_dir, name <> ".yml"), Renderer.to_yaml(value))
  end

  defp write_repo_manifest!(repo, slug) do
    File.write!(Path.join(repo, "README.md"), "docs\n")

    File.write!(
      Path.join(repo, "symphony.yml"),
      Renderer.to_yaml(%{
        "version" => 1,
        "project" => %{"slug" => slug, "repository" => "https://github.com/example/#{slug}"},
        "docs" => %{"entrypoints" => ["README.md"]},
        "delivery" => %{"pr_target" => "main"},
        "workflow" => %{"preset" => "default"}
      })
    )
  end

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
