defmodule SymphonyElixir.OperatorRepositoryChoicesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OperatorRepositoryChoices

  test "repository policy fields require a repository path" do
    choices = OperatorRepositoryChoices.build(nil, host: host(), configured: configured())

    assert choices["repository_profile"].status == "unavailable"
    assert choices["repository_profile"].reason == "repository_required"
    assert choices["repository_policy.workflow.modules"].status == "unavailable"
    assert choices["repository_policy.workflow.modules"].reason == "repository_required"
  end

  test "configured policy catalog does not require a repository manifest" do
    root = tmp_dir!("operator-choices-no-manifest")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(root) end)

    choices =
      OperatorRepositoryChoices.build(repo,
        host: host(),
        configured: configured()
      )

    assert Enum.any?(choices["repository_profile"].choices, &(&1.value == "strict"))
    assert choices["repository_policy.workflow.modules"].status == "current"
    assert Enum.any?(choices["repository_policy.workflow.modules"].choices, &(&1.value == "workspace"))
    refute File.exists?(Path.join(repo, "symphony.yml"))
  end

  test "delivery.github_pr is available for valid GitHub identity and explicit pr target" do
    choices =
      OperatorRepositoryChoices.build("/tmp/operator-choices-delivery",
        host: host(),
        configured: configured()
      )

    field = choices["repository_policy.workflow.modules"]
    assert field.status == "current"

    delivery = Enum.find(field.choices, &(&1.value == "delivery.github_pr"))
    assert delivery.status == "available"
    assert is_nil(delivery.reason)

    assert Enum.any?(field.choices, &(&1.value == "workspace" and &1.status == "available"))
  end

  test "non-GitHub repository identity keeps module choices unavailable" do
    host =
      put_in(host(), ["repository_defaults", "project", "repository"], "https://gitlab.com/example/choices")

    choices =
      OperatorRepositoryChoices.build("/tmp/operator-choices-delivery",
        host: host,
        configured: configured()
      )

    field = choices["repository_policy.workflow.modules"]
    assert field.status == "unavailable"
    assert field.reason == "repository_policy_invalid"
    assert field.choices == []
  end

  test "invalid host policy keeps module choices unavailable without exposing raw policy" do
    root = tmp_dir!("operator-choices-invalid-policy")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(root) end)

    choices =
      OperatorRepositoryChoices.build(repo,
        host: %{"repository_defaults" => %{"capabilities" => %{"token" => "private-value"}}},
        configured: configured()
      )

    assert choices["repository_profile"].status == "current"
    assert choices["repository_profile"].choices == []
    assert is_nil(choices["repository_profile"].reason)
    assert choices["repository_policy.workflow.modules"].reason == "repository_policy_invalid"
    refute inspect(choices) =~ "private-value"
  end

  test "unknown configured profile keeps host profile choices selectable" do
    root = tmp_dir!("operator-choices-unknown-profile")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(root) end)

    configured = Map.put(configured(), "repository_profile", "removed")

    choices = OperatorRepositoryChoices.build(repo, host: host(), configured: configured)

    assert choices["repository_profile"].status == "current"
    assert [%{value: "strict", status: "available"}] = choices["repository_profile"].choices
    assert choices["repository_policy.workflow.modules"].status == "unavailable"
    assert choices["repository_policy.workflow.modules"].reason == "repository_policy_invalid"

    drafted =
      OperatorRepositoryChoices.build(repo,
        host: host(),
        configured: configured,
        selections: %{"repository_profile" => "strict"}
      )

    assert drafted["repository_policy.workflow.modules"].status == "current"
    assert Enum.any?(drafted["repository_policy.workflow.modules"].choices, &(&1.value == "workspace"))

    cleared =
      OperatorRepositoryChoices.build(repo,
        host: host(),
        configured: configured,
        selections: %{"repository_profile" => nil}
      )

    assert cleared["repository_policy.workflow.modules"].status == "current"

    invalid =
      OperatorRepositoryChoices.build(repo,
        host: host(),
        configured: configured,
        selections: %{"repository_profile" => "bogus"}
      )

    assert invalid["repository_policy.workflow.modules"].status == "unavailable"
    assert invalid["repository_policy.workflow.modules"].reason == "repository_policy_invalid"
  end

  test "profile-only policy resolves once a profile is drafted when defaults are incomplete" do
    root = tmp_dir!("operator-choices-profile-only")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(root) end)

    host = %{
      "repository_defaults" => Map.drop(host()["repository_defaults"], ["project", "workflow"]),
      "repository_profiles" => %{
        "strict" => %{
          "project" => %{"slug" => "choices", "repository" => "https://github.com/example/choices"}
        }
      }
    }

    choices = OperatorRepositoryChoices.build(repo, host: host, configured: configured())

    assert choices["repository_profile"].status == "current"
    assert Enum.any?(choices["repository_profile"].choices, &(&1.value == "strict"))
    assert choices["repository_policy.workflow.modules"].status == "unavailable"
    assert choices["repository_policy.workflow.modules"].reason == "repository_policy_invalid"

    drafted =
      OperatorRepositoryChoices.build(repo,
        host: host,
        configured: configured(),
        selections: %{"repository_profile" => "strict"}
      )

    assert drafted["repository_policy.workflow.modules"].status == "current"

    assert Enum.any?(
             drafted["repository_policy.workflow.modules"].choices,
             &(&1.value == "delivery.github_pr" and &1.status == "available")
           )
  end

  defp host do
    %{
      "repository_defaults" => %{
        "project" => %{"slug" => "choices", "repository" => "https://github.com/example/choices"},
        "docs" => %{"entrypoints" => []},
        "validation" => %{"commands" => [], "required_files" => []},
        "vcs" => %{"mode" => "git", "default_branch" => "main"},
        "delivery" => %{"pr_target" => "main"},
        "workflow" => %{"modules" => ["workspace"]},
        "capabilities" => %{"required" => []}
      },
      "repository_profiles" => %{
        "strict" => %{"workflow" => %{"modules" => ["workspace"]}}
      }
    }
  end

  defp configured, do: %{"repo" => %{"path" => "/tmp/choices"}}

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
