defmodule SymphonyElixir.HostScheduler.RegistryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HostScheduler.Registry
  alias SymphonyElixir.TargetRegistry.Yaml

  @tag :tmp_dir
  test "loads one verified file generation for host scheduling", %{tmp_dir: tmp_dir} do
    registry_path = Path.join(tmp_dir, "targets.yml")
    state_root = Path.join(Path.dirname(tmp_dir), Path.basename(tmp_dir) <> "-state")

    document = %{
      "version" => 1,
      "host" => %{
        "id" => "test-host",
        "state_root" => state_root,
        "polling" => %{"interval_ms" => 25, "max_concurrent_target_polls" => 2},
        "capacity" => %{
          "max_concurrent_agents" => 3,
          "max_concurrent_startups" => 2,
          "max_concurrent_reviewers" => 1
        },
        "scheduling" => %{
          "algorithm" => "weighted_deficit_round_robin",
          "max_credit_rounds" => 3
        },
        "tracker_connections" => %{
          "linear" => %{
            "kind" => "linear",
            "endpoint" => "https://tracker.example.invalid/graphql",
            "api_key" => "$LINEAR_API_KEY"
          }
        },
        "runners" => %{
          "codex" => %{
            "kind" => "codex_app_server",
            "command" => ["codex", "app-server"],
            "max_concurrent_agents" => 3,
            "max_concurrent_startups" => 2
          }
        }
      },
      "targets" => %{}
    }

    bytes = Yaml.encode(document)
    File.write!(registry_path, bytes)

    assert {:ok, %{snapshot: snapshot, contexts: %{}}} = Registry.load(registry_path)
    assert snapshot.globally_valid?
    assert snapshot.path == registry_path
    assert snapshot.generation == hash(bytes)
    assert snapshot.source_hash == snapshot.generation
    assert snapshot.host["state_root"] == state_root
  end

  defp hash(bytes),
    do: "sha256:" <> (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))
end
