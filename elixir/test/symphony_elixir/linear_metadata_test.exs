defmodule SymphonyElixir.Linear.MetadataTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Metadata

  @connection %{
    "id" => "linear-main",
    "policy" => %{
      "kind" => "linear",
      "endpoint" => "https://linear.example/graphql",
      "api_key" => "$LINEAR_TEST_KEY"
    }
  }

  defp response(body, status \\ 200), do: {:ok, %{status: status, body: body}}

  defp page(root, nodes, has_next \\ false, cursor \\ nil) do
    %{
      "data" => %{
        root => %{
          "nodes" => nodes,
          "pageInfo" => %{"hasNextPage" => has_next, "endCursor" => cursor}
        }
      }
    }
  end

  defp project(id, name, slug_id, team_nodes, has_next \\ false, cursor \\ nil) do
    %{
      "id" => id,
      "name" => name,
      "slugId" => slug_id,
      "teams" => %{
        "nodes" => team_nodes,
        "pageInfo" => %{"hasNextPage" => has_next, "endCursor" => cursor}
      }
    }
  end

  defp base_responder(fun) do
    fn endpoint, payload, headers ->
      send(self(), {:metadata_request, endpoint, payload, headers})
      fun.(payload)
    end
  end

  test "fully paginates catalogs and project teams while retaining duplicate names" do
    request_fun =
      base_responder(fn %{"operationName" => operation, "variables" => %{"after" => cursor}} = payload ->
        case {operation, cursor} do
          {"SymphonyMetadataTeams", nil} ->
            response(page("teams", [%{"id" => "t-1", "name" => "Platform", "key" => "PLAT"}], true, "teams-1"))

          {"SymphonyMetadataTeams", "teams-1"} ->
            response(page("teams", [%{"id" => "t-2", "name" => "Platform", "key" => "CORE"}]))

          {"SymphonyMetadataProjects", nil} ->
            response(page("projects", [project("p-1", "Checkout", "checkout", [%{"id" => "t-1"}], true, "p-1-teams")], true, "projects-1"))

          {"SymphonyMetadataProjects", "projects-1"} ->
            response(page("projects", [project("p-2", "Checkout", "checkout-two", [%{"id" => "t-2"}])]))

          {"SymphonyMetadataProjectTeams", "p-1-teams"} ->
            response(%{
              "data" => %{
                "project" => %{
                  "teams" => %{
                    "nodes" => [%{"id" => "t-2"}],
                    "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                  }
                }
              }
            })

          {"SymphonyMetadataStates", nil} ->
            response(page("workflowStates", [%{"id" => "s-1", "name" => "Todo", "type" => "unstarted", "team" => %{"id" => "t-1"}}]))

          {"SymphonyMetadataLabels", nil} ->
            response(
              page("issueLabels", [
                %{"id" => "l-1", "name" => "Ops", "team" => nil},
                %{"id" => "l-2", "name" => "Ops", "team" => %{"id" => "t-1"}}
              ])
            )

          _ ->
            flunk("unexpected metadata request: #{inspect(payload["operationName"])} / #{inspect(payload["variables"])}")
        end
      end)

    assert {:ok, metadata} = Metadata.fetch(@connection, env_fetcher: fn "LINEAR_TEST_KEY" -> "secret" end, request_fun: request_fun)

    assert metadata.teams == [
             %{id: "t-1", name: "Platform", key: "PLAT"},
             %{id: "t-2", name: "Platform", key: "CORE"}
           ]

    assert metadata.projects == [
             %{id: "p-1", name: "Checkout", slug_id: "checkout", team_ids: ["t-1", "t-2"]},
             %{id: "p-2", name: "Checkout", slug_id: "checkout-two", team_ids: ["t-2"]}
           ]

    assert metadata.states == [%{id: "s-1", name: "Todo", type: "unstarted", team_id: "t-1"}]

    assert metadata.labels == [
             %{id: "l-1", name: "Ops", team_id: nil},
             %{id: "l-2", name: "Ops", team_id: "t-1"}
           ]

    assert_received {:metadata_request, _, %{"operationName" => "SymphonyMetadataTeams"}, headers}
    assert {"Authorization", "secret"} in headers
    refute Enum.any?(headers, fn {_name, value} -> value == "$LINEAR_TEST_KEY" end)
  end

  test "deduplicates repeated identities without deduplicating names and resolves braced secrets" do
    responder =
      base_responder(fn %{"operationName" => operation} ->
        case operation do
          "SymphonyMetadataTeams" ->
            response(
              page("teams", [
                %{"id" => "t-1", "name" => "Same", "key" => "A"},
                %{"id" => "t-1", "name" => "Same changed", "key" => "A2"},
                %{"id" => "t-2", "name" => "Same", "key" => "B"}
              ])
            )

          "SymphonyMetadataProjects" ->
            response(page("projects", [project("p-1", "Same", "same", [])]))

          "SymphonyMetadataStates" ->
            response(
              page("workflowStates", [
                %{"id" => "s-1", "name" => "Same", "type" => "backlog", "team" => %{"id" => "t-1"}}
              ])
            )

          "SymphonyMetadataLabels" ->
            response(
              page("issueLabels", [
                %{"id" => "l-1", "name" => "Same", "team" => nil},
                %{"id" => "l-2", "name" => "Same", "team" => nil}
              ])
            )

          _ ->
            flunk("unexpected operation")
        end
      end)

    connection = put_in(@connection, ["policy", "api_key"], "${LINEAR_TEST_KEY}")

    assert {:ok, metadata} =
             Metadata.fetch(connection,
               env_fetcher: fn variable ->
                 send(self(), {:env_variable, variable})
                 "secret"
               end,
               request_fun: responder
             )

    assert_received {:env_variable, "LINEAR_TEST_KEY"}
    assert Enum.map(metadata.teams, & &1.id) == ["t-1", "t-2"]
    assert Enum.map(metadata.labels, & &1.id) == ["l-1", "l-2"]
  end

  test "classifies authentication, rate limiting, and transport failures without raw details" do
    for {response_value, expected} <- [
          {response(%{}, 401), :authentication_failed},
          {response(%{}, 429), :rate_limited},
          {response(%{"errors" => [%{"extensions" => %{"code" => "UNAUTHENTICATED"}, "message" => "secret token"}]}), :authentication_failed},
          {response(%{"errors" => [%{"extensions" => %{"code" => "RATELIMITED"}, "message" => "too many"}]}), :rate_limited},
          {{:error, {:closed, "private transport details"}}, :offline}
        ] do
      request_fun = fn _endpoint, _payload, _headers -> response_value end
      assert {:error, ^expected} = Metadata.fetch(@connection, env_fetcher: fn _ -> "secret" end, request_fun: request_fun)
    end
  end

  test "rejects malformed cursors and never returns partial catalogs" do
    request_fun = fn _endpoint, %{"operationName" => "SymphonyMetadataTeams"}, _headers ->
      response(page("teams", [%{"id" => "t-1", "name" => "Platform", "key" => "PLAT"}], true, nil))
    end

    assert {:error, :invalid_response} =
             Metadata.fetch(@connection,
               env_fetcher: fn _ -> "secret" end,
               request_fun: request_fun
             )
  end

  test "bounds pages and entries even when the server keeps returning cursors" do
    request_fun = fn _endpoint, %{"operationName" => "SymphonyMetadataTeams"}, _headers ->
      response(page("teams", [%{"id" => "t-1", "name" => "Platform", "key" => "PLAT"}], true, "again"))
    end

    assert {:error, :catalog_limit} =
             Metadata.fetch(@connection,
               env_fetcher: fn _ -> "secret" end,
               request_fun: request_fun,
               max_pages: 2
             )
  end
end
