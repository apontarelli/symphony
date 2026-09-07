defmodule SymphonyElixir.TargetRoutingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{RunTarget, TargetRouting}

  @issue %Issue{id: "uuid-1", identifier: "ENG-1", project_id: "project-1", team_key: "ENG", labels: ["repo:alpha"]}

  test "distinct project bindings do not conflict in preview or admission" do
    alpha = entry("alpha", %{"type" => "project", "project_id" => "project-1"})
    beta = entry("beta", %{"type" => "project", "project_id" => "project-2"})
    assert Enum.all?(TargetRouting.preview([alpha, beta]), &(&1.status == "routed"))
    assert :ok = TargetRouting.resolve_issue_for([alpha, beta], "alpha", @issue)
  end

  test "routing does not compare identities from different tracker connections" do
    alpha = entry("alpha", %{"type" => "project", "project_id" => "project-1"})
    beta = %{entry("beta", alpha.scope) | connection_id: "other-workspace"}
    assert :ok = TargetRouting.resolve_issue_for([alpha, beta], "alpha", @issue)
  end

  test "broad targets require explicit repository markers and respect them" do
    scope = %{"type" => "team", "team_key" => "ENG"}
    alpha = entry("alpha", scope)
    assert {:error, :routing_missing} = TargetRouting.resolve_issue_for([alpha], "alpha", @issue)

    alpha = %{alpha | markers: RunTarget.repo_markers(%{"labels" => ["repo:alpha"]})}
    beta = %{entry("beta", scope) | markers: RunTarget.repo_markers(%{"labels" => ["repo:beta"]})}
    assert :ok = TargetRouting.resolve_issue_for([alpha, beta], "alpha", @issue)
    both = %Issue{@issue | labels: ["repo:alpha", "repo:beta"]}
    assert {:error, {:routing_ambiguous, _}} = TargetRouting.resolve_issue_for([alpha, beta], "alpha", both)
  end

  test "explicit UUID selections bind the actual issue" do
    alpha = entry("alpha", %{"type" => "issues", "issue_ids" => ["uuid-1"]})
    assert :ok = TargetRouting.resolve_issue_for([alpha], "alpha", @issue)
    assert {:error, :routing_missing} = TargetRouting.resolve_issue_for([alpha], "alpha", %Issue{@issue | id: "uuid-2"})
  end

  test "UUID and identifier selections that may alias one issue preview as conflicts" do
    uuid = "6d20240e-7b4c-4d40-9a1e-0f2b3c4d5e6f"
    alpha = entry("alpha", %{"type" => "issues", "issue_ids" => [uuid]})
    beta = entry("beta", %{"type" => "issues", "issue_ids" => ["ENG-1"]})

    assert TargetRouting.scopes_potentially_overlap?(alpha.scope, beta.scope)
    refute TargetRouting.scopes_exactly_overlap?(alpha.scope, beta.scope)

    routing = TargetRouting.preview([alpha, beta]) |> Map.new(&{&1.target_id, &1})

    assert routing["alpha"].status == "ambiguous"
    assert routing["alpha"].reason == "routing_ambiguous"
    assert Enum.map(routing["alpha"].conflicts, & &1.target_id) == ["beta"]
    assert routing["beta"].status == "ambiguous"

    # Admission of the aliased issue stays fail-closed.
    aliased = %Issue{@issue | id: uuid, identifier: "ENG-1"}

    assert {:error, {:routing_ambiguous, matches}} = TargetRouting.resolve_issue([alpha, beta], aliased)
    assert Enum.map(matches, & &1.target_id) == ["alpha", "beta"]
  end

  test "same-shape issue selections stay provably disjoint" do
    first_uuid = "6d20240e-7b4c-4d40-9a1e-0f2b3c4d5e6f"
    second_uuid = "7e31351f-8c5d-4d50-8b2f-1a4c5d6e7f8a"
    alpha = entry("alpha", %{"type" => "issues", "issue_ids" => [first_uuid]})
    beta = entry("beta", %{"type" => "issues", "issue_ids" => [second_uuid]})
    gamma = entry("gamma", %{"type" => "issues", "issue_ids" => ["ENG-1"]})
    delta = entry("delta", %{"type" => "issues", "issue_ids" => ["ENG-2"]})

    refute TargetRouting.scopes_potentially_overlap?(alpha.scope, beta.scope)
    refute TargetRouting.scopes_potentially_overlap?(gamma.scope, delta.scope)

    for entries <- [[alpha, beta], [gamma, delta]] do
      assert Enum.all?(TargetRouting.preview(entries), &(&1.status == "routed"))
    end

    assert {:ok, matched} = TargetRouting.resolve_issue([alpha, beta], %Issue{@issue | id: first_uuid})
    assert matched.target_id == "alpha"
  end

  defp entry(id, scope) do
    %{
      target_id: id,
      connection_id: "workspace",
      scope: scope,
      scope_type: scope["type"],
      repository: "owner/" <> id,
      repository_key: "slug:owner/" <> id,
      markers: RunTarget.RepoMarkers.empty(),
      active?: true
    }
  end
end
