defmodule SymphonyElixir.OperatorRepositoryChoicesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{LocalConfig, OperatorRepositoryChoices}
  alias SymphonyElixir.Workflow.Renderer

  test "repository-dependent fields are unavailable while host capacity remains available" do
    root = tmp_dir!("operator-choices-no-repo")
    on_exit(fn -> File.rm_rf!(root) end)

    choices = OperatorRepositoryChoices.build(nil, config_root: root)

    assert choices["workflow"].status == "unavailable"
    assert choices["workflow"].reason == "repository_required"
    assert choices["profile"].status == "unavailable"
    assert choices["workflow.modules"].status == "unavailable"
    assert choices["capacity"].status == "current"
    assert Enum.any?(choices["capacity"].choices, &(&1.value == "normal" and &1.status == "available"))
  end

  test "reports an unavailable catalog when the repository manifest is missing" do
    root = tmp_dir!("operator-choices-missing-repo")
    config_root = Path.join(root, "config")
    missing_repo = Path.join(root, "missing-repo")
    on_exit(fn -> File.rm_rf!(root) end)

    choices = OperatorRepositoryChoices.build(missing_repo, config_root: config_root)

    assert choices["workflow"].status == "unavailable"
    assert choices["workflow"].reason == "repository_unavailable"
    assert choices["profile"].reason == "repository_unavailable"
    assert choices["workflow.modules"].reason == "repository_unavailable"
    assert choices["capacity"].status == "current"
    assert Enum.any?(choices["capacity"].choices, &(&1.value == "normal" and &1.status == "available"))
  end

  test "contains malformed local config at the filesystem boundary" do
    root = tmp_dir!("operator-choices-malformed-config")
    repo = Path.join(root, "repo")
    config_root = Path.join(root, "config")
    File.mkdir_p!(repo)
    File.mkdir_p!(config_root)
    File.write!(Path.join(repo, "README.md"), "docs\n")
    write_repo_manifest!(repo)
    File.write!(Path.join(config_root, "config.yml"), "profiles: [unclosed\n")
    on_exit(fn -> File.rm_rf!(root) end)

    choices = OperatorRepositoryChoices.build(repo, config_root: config_root)

    assert choices["profile"] == %{
             cardinality: "scalar",
             choices: [],
             status: "unavailable",
             reason: "invalid_local_config"
           }

    assert choices["capacity"].status == "unavailable"
    assert choices["capacity"].reason == "invalid_local_config"
    assert choices["workflow.modules"].status == "current"
    refute inspect(choices) =~ "unclosed"
  end

  test "contains an unreadable local config root without exposing its contents" do
    root = tmp_dir!("operator-choices-unreadable-config")
    repo = Path.join(root, "repo")
    config_root = Path.join(root, "config-root")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "README.md"), "docs\n")
    write_repo_manifest!(repo)
    File.write!(config_root, "operator-secret-unreadable-config")
    on_exit(fn -> File.rm_rf!(root) end)

    choices = OperatorRepositoryChoices.build(repo, config_root: config_root)

    assert choices["profile"].reason == "invalid_local_config"
    assert choices["capacity"].reason == "invalid_local_config"
    refute inspect(choices) =~ "operator-secret-unreadable-config"
  end

  test "rejects malformed choice containers without offering their contents" do
    root = tmp_dir!("operator-choices-invalid-containers")
    repo = Path.join(root, "repo")
    config_root = Path.join(root, "config")
    File.mkdir_p!(repo)
    File.mkdir_p!(config_root)
    File.write!(Path.join(repo, "README.md"), "docs\n")
    write_repo_manifest!(repo)

    File.write!(
      Path.join(config_root, "config.yml"),
      "capacity_profiles: [private-value]\nworkflow_modules: [private-value]\n"
    )

    on_exit(fn -> File.rm_rf!(root) end)

    choices = OperatorRepositoryChoices.build(repo, config_root: config_root)

    assert choices["capacity"].status == "unavailable"
    assert choices["capacity"].reason == "invalid_local_config"
    assert Enum.any?(choices["profile"].choices, &(&1.value == "default" and &1.status == "invalid"))
    refute inspect(choices) =~ "private-value"
  end

  test "lists saved workflows, repository profiles, registered modules, and valid capacities" do
    root = tmp_dir!("operator-choices-valid")
    repo = Path.join(root, "repo")
    config_root = Path.join(root, "config")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "README.md"), "docs\n")
    write_repo_manifest!(repo)

    assert {:ok, _path} =
             LocalConfig.write(
               %{
                 "profiles" => %{
                   "default" => %{"delivery" => %{"pr_target" => "main"}},
                   "strict" => %{"delivery" => %{"pr_target" => "human-review"}}
                 }
               },
               config_root: config_root
             )

    File.mkdir_p!(Path.join(config_root, "runs"))

    File.write!(
      Path.join([config_root, "runs", "default.yml"]),
      Renderer.to_yaml(%{
        "repo" => %{"path" => repo},
        "target" => %{"type" => "query_manual"},
        "mode" => "watch",
        "capacity" => "normal"
      })
    )

    on_exit(fn -> File.rm_rf!(root) end)
    choices = OperatorRepositoryChoices.build(repo, config_root: config_root)

    assert Enum.any?(choices["workflow"].choices, &(&1.value == "default" and &1.status == "available"))
    assert Enum.any?(choices["profile"].choices, &(&1.value == "strict" and &1.status == "available"))
    assert Enum.any?(choices["workflow.modules"].choices, &(&1.value == "repo.docs" and &1.status == "available"))
    assert Enum.any?(choices["capacity"].choices, &(&1.value == "normal" and &1.status == "available"))
  end

  test "retains malformed saved workflows alongside selectable ones" do
    root = tmp_dir!("operator-choices-saved-workflow-failures")
    repo = Path.join(root, "repo")
    config_root = Path.join(root, "config")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "README.md"), "docs\n")
    write_repo_manifest!(repo)
    File.mkdir_p!(Path.join(config_root, "runs"))

    File.write!(
      Path.join([config_root, "runs", "default.yml"]),
      Renderer.to_yaml(%{
        "repo" => %{"path" => repo},
        "target" => %{"type" => "query_manual"},
        "mode" => "watch",
        "capacity" => "normal"
      })
    )

    File.write!(Path.join([config_root, "runs", "broken.yml"]), "[not yaml")
    on_exit(fn -> File.rm_rf!(root) end)

    choices = OperatorRepositoryChoices.build(repo, config_root: config_root)

    assert Enum.any?(choices["workflow"].choices, &(&1.value == "default" and &1.status == "available"))

    assert Enum.any?(choices["workflow"].choices, fn choice ->
             choice.value == "broken" and choice.status == "invalid" and
               choice.reason == "incompatible_workflow_definition"
           end)

    write_repo_manifest!(repo, ["missing-module"])
    choices = OperatorRepositoryChoices.build(repo, config_root: config_root)

    assert Enum.any?(choices["workflow.modules"].choices, fn choice ->
             choice.value == "missing-module" and choice.status == "invalid" and
               choice.reason == "incompatible_workflow_module"
           end)
  end

  test "keeps incompatible entries visible without leaking credentials" do
    root = tmp_dir!("operator-choices-invalid")
    repo = Path.join(root, "repo")
    config_root = Path.join(root, "config")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "README.md"), "docs\n")
    write_repo_manifest!(repo)

    assert {:ok, _path} =
             LocalConfig.write(
               %{
                 "tracker" => %{"api_key" => "operator-secret-value"},
                 "profiles" => %{
                   "broken" => %{
                     "delivery" => %{"pr_target" => "main", "unsupported" => "operator-private"}
                   }
                 },
                 "workflow_modules" => %{"configured-missing" => %{"enabled" => true}},
                 "capacity_profiles" => %{
                   "broken" => %{"max_concurrent_agents" => 99, "max_concurrent_startups" => 99}
                 }
               },
               config_root: config_root
             )

    on_exit(fn -> File.rm_rf!(root) end)
    choices = OperatorRepositoryChoices.build(repo, config_root: config_root)

    assert Enum.any?(choices["profile"].choices, fn choice ->
             choice.value == "broken" and choice.status == "invalid" and
               choice.reason == "incompatible_profile_definition"
           end)

    assert Enum.any?(choices["workflow.modules"].choices, fn choice ->
             choice.value == "configured-missing" and choice.status == "invalid" and
               choice.reason == "incompatible_workflow_module"
           end)

    assert Enum.any?(choices["capacity"].choices, fn choice ->
             choice.value == "broken" and choice.status == "invalid" and
               choice.reason == "invalid_capacity_profile"
           end)

    refute inspect(choices) =~ "operator-secret-value"
  end

  defp write_repo_manifest!(repo, modules \\ []) do
    workflow = if modules == [], do: %{}, else: %{"modules" => modules}

    File.write!(
      Path.join(repo, "symphony.yml"),
      Renderer.to_yaml(%{
        "version" => 1,
        "project" => %{"slug" => "choices-repo", "repository" => "https://github.com/example/choices"},
        "docs" => %{"entrypoints" => ["README.md"]},
        "delivery" => %{"pr_target" => "main"},
        "workflow" => workflow
      })
    )
  end

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
