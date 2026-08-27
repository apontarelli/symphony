defmodule SymphonyElixir.LocalConfigTest do
  use ExUnit.Case

  alias SymphonyElixir.LocalConfig

  test "ensure creates the default operator config outside the target repo" do
    root = tmp_dir!("symphony-local-config")

    assert {:ok, :created, config, path} = LocalConfig.ensure(config_root: root)
    assert path == Path.join(root, "config.yml")

    assert config["workspace"]["root"] == "~/dev/symphony-workspaces"
    assert config["tracker"]["active_states"] == ["Todo", "In Progress", "Merging", "Rework"]
    assert config["tracker"]["terminal_states"] == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config["control_plane"]["terminal_retention_days"] == 30

    assert config["capacity_profiles"] == %{
             "light" => %{"max_concurrent_agents" => 1, "max_concurrent_startups" => 1},
             "normal" => %{"max_concurrent_agents" => 4, "max_concurrent_startups" => 1},
             "swarm" => %{"max_concurrent_agents" => 10, "max_concurrent_startups" => 2}
           }

    assert config["deployment"]["ceilings"] == %{
             "max_concurrent_agents" => 10,
             "max_concurrent_startups" => 2
           }

    assert get_in(config, ["runners", "codex", "command"]) == ["codex", "app-server"]
    assert {:ok, ^config} = LocalConfig.load(config_root: root)
  end

  test "capacity profile resolution enforces deployment ceilings" do
    config =
      LocalConfig.default_config()
      |> put_in(["deployment", "ceilings"], %{
        "max_concurrent_agents" => 4,
        "max_concurrent_startups" => 1
      })

    assert {:ok,
            %{
              "max_concurrent_agents" => 4,
              "max_concurrent_startups" => 1
            }} = LocalConfig.resolve_capacity(config, "normal")

    assert {:error, {:capacity_exceeds_deployment_ceiling, "swarm", %{"max_concurrent_agents" => 10, "max_concurrent_startups" => 2}, %{"max_concurrent_agents" => 4, "max_concurrent_startups" => 1}}} =
             LocalConfig.resolve_capacity(config, "swarm")
  end

  test "inline capacity maps are validated like named profiles" do
    config = LocalConfig.default_config()

    assert {:ok,
            %{
              "max_concurrent_agents" => 2,
              "max_concurrent_startups" => 1
            }} =
             LocalConfig.resolve_capacity(config, %{
               "max_concurrent_agents" => 2,
               "max_concurrent_startups" => 1
             })

    assert {:error, {:invalid_capacity, _capacity}} =
             LocalConfig.resolve_capacity(config, %{
               "max_concurrent_agents" => 0,
               "max_concurrent_startups" => 1
             })
  end

  test "deployment ceilings must be positive integers" do
    for invalid_ceiling <- ["4", nil, 0, -1] do
      config =
        LocalConfig.default_config()
        |> put_in(["deployment", "ceilings", "max_concurrent_agents"], invalid_ceiling)

      assert {:error, {:invalid_deployment_ceilings, ceilings}} =
               LocalConfig.resolve_capacity(config, "light")

      assert ceilings["max_concurrent_agents"] == invalid_ceiling
    end
  end

  test "null deployment ceiling values loaded from local config remain invalid" do
    root = tmp_dir!("symphony-local-config")

    File.write!(Path.join(root, "config.yml"), """
    deployment:
      ceilings:
        max_concurrent_agents:
    """)

    assert {:ok, config} = LocalConfig.load(config_root: root)

    assert {:error, {:invalid_deployment_ceilings, ceilings}} =
             LocalConfig.resolve_capacity(config, "light")

    assert is_nil(ceilings["max_concurrent_agents"])
  end

  test "terminal retention rejects invalid operator configuration" do
    assert {:ok, 30} =
             LocalConfig.default_config()
             |> LocalConfig.terminal_retention_days()

    for invalid <- [nil, "30", 0, -1] do
      config =
        LocalConfig.default_config()
        |> put_in(["control_plane", "terminal_retention_days"], invalid)

      assert {:error, {:invalid_terminal_retention_days, ^invalid}} =
               LocalConfig.terminal_retention_days(config)
    end
  end

  test "null terminal retention loaded from operator config remains invalid" do
    root = tmp_dir!("symphony-local-config")

    File.write!(Path.join(root, "config.yml"), """
    control_plane:
      terminal_retention_days:
    """)

    assert {:ok, config} = LocalConfig.load(config_root: root)

    assert {:error, {:invalid_terminal_retention_days, nil}} =
             LocalConfig.terminal_retention_days(config)
  end

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
