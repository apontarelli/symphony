defmodule SymphonyElixir.RunSetupTest do
  use ExUnit.Case

  alias SymphonyElixir.LocalConfig
  alias SymphonyElixir.RunSetup
  alias SymphonyElixir.Workflow.{Manifest, Renderer}

  test "run setup names cannot escape the global runs directory" do
    root = tmp_dir!("symphony-run-setup")

    assert {:ok, path} = RunSetup.path("daily.local-1", config_root: root)
    assert path == Path.join([root, "runs", "daily.local-1.yml"])

    for unsafe <- ["", ".", "..", "../daily", "daily/name", "daily name", ".hidden"] do
      assert {:error, {:invalid_run_setup_name, ^unsafe}} = RunSetup.path(unsafe, config_root: root)
    end
  end

  test "write and read round trips repo reference, target, mode, capacity, and restrictive flags" do
    root = tmp_dir!("symphony-run-setup")
    repo = tmp_repo!("target-repo")

    setup = %{
      "repo" => %{"path" => repo},
      "target" => %{"tracker" => %{"project_slug" => "symphony"}},
      "mode" => "unattended",
      "capacity" => "light",
      "restrictive_flags" => %{"required_labels" => ["symphony"]}
    }

    assert {:ok, path} = RunSetup.write("dogfood", setup, config_root: root)
    assert path == Path.join([root, "runs", "dogfood.yml"])

    assert {:ok, ^setup, ^path} = RunSetup.read("dogfood", config_root: root)
  end

  test "runtime manifest composition overlays local config and saved run setup on repo setup" do
    root = tmp_dir!("symphony-run-setup")
    repo = tmp_repo!("target-repo")
    write_repo_manifest!(repo)

    config =
      LocalConfig.default_config()
      |> put_in(["workspace", "root"], "~/custom-workspaces")

    setup = %{
      "repo" => %{"path" => repo},
      "target" => %{"tracker" => %{"project_slug" => "symphony"}},
      "mode" => "unattended",
      "capacity" => "light",
      "restrictive_flags" => %{"required_labels" => ["symphony"]}
    }

    assert {:ok, runtime_manifest} = RunSetup.runtime_manifest(config, setup)

    assert get_in(runtime_manifest, ["project", "slug"]) == "target-repo"
    assert get_in(runtime_manifest, ["runtime", "workspace", "root"]) == "~/custom-workspaces"
    assert get_in(runtime_manifest, ["runtime", "tracker", "project_slug"]) == "symphony"
    assert get_in(runtime_manifest, ["runtime", "tracker", "required_labels"]) == ["symphony"]
    assert get_in(runtime_manifest, ["runtime", "agent", "max_concurrent_agents"]) == 1
    assert get_in(runtime_manifest, ["runtime", "agent", "max_concurrent_startups"]) == 1
    assert get_in(runtime_manifest, ["runtime", "runners", "codex", "command"]) == ["codex", "app-server"]

    runtime_path = Path.join(root, "runtime.yml")
    File.write!(runtime_path, Renderer.to_yaml(runtime_manifest))
    assert {:ok, %{config: compiled}} = Manifest.load(runtime_path, repo_setup?: false)
    assert compiled["tracker"]["project_slug"] == "symphony"
    assert compiled["workspace"]["root"] == "~/custom-workspaces"
  end

  test "target tracker keys cannot override operator tracker defaults" do
    repo = tmp_repo!("target-repo")
    write_repo_manifest!(repo)

    config =
      LocalConfig.default_config()
      |> put_in(["tracker", "api_key"], "$LOCAL_LINEAR_API_KEY")
      |> put_in(["tracker", "active_states"], ["Ready", "Building"])

    setup = %{
      "repo" => %{"path" => repo},
      "target" => %{
        "tracker" => %{
          "project_slug" => "symphony",
          "api_key" => "$RUN_SETUP_LINEAR_API_KEY",
          "active_states" => ["Hijacked"]
        }
      },
      "mode" => "unattended",
      "capacity" => "light"
    }

    assert {:ok, runtime_manifest} = RunSetup.runtime_manifest(config, setup)

    assert get_in(runtime_manifest, ["runtime", "tracker", "project_slug"]) == "symphony"
    assert get_in(runtime_manifest, ["runtime", "tracker", "api_key"]) == "$LOCAL_LINEAR_API_KEY"
    assert get_in(runtime_manifest, ["runtime", "tracker", "active_states"]) == ["Ready", "Building"]
  end

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp tmp_repo!(name) do
    root = tmp_dir!(name)
    File.mkdir_p!(Path.join(root, ".git"))
    root
  end

  defp write_repo_manifest!(repo) do
    File.write!(Path.join(repo, "README.md"), "docs\n")

    File.write!(
      Path.join(repo, "symphony.yml"),
      """
      version: 1
      project:
        slug: target-repo
        name: Target Repo
        repository: https://github.com/example/target-repo
        kind: elixir
        app_kind: web
      docs:
        entrypoints:
          - README.md
      delivery:
        pr_target: main
      workflow:
        preset: default
      """
    )
  end
end
