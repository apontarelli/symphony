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
                    "nodes" => [%{"id" => "t-1"}, %{"id" => "t-2"}],
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
                %{"id" => "l-2", "name" => "Ops", "team" => %{"id" => "t-1"}},
                %{"id" => "group", "name" => "Category", "team" => nil, "isGroup" => true}
              ])
            )

          _ ->
            flunk("unexpected metadata request: #{inspect(payload["operationName"])} / #{inspect(payload["variables"])}")
        end
      end)

    assert {:ok, metadata} = Metadata.fetch(@connection, env_fetcher: fn "LINEAR_TEST_KEY" -> {:ok, "secret"} end, request_fun: request_fun)

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
          {response(%{"errors" => [%{"extensions" => %{"code" => "RATELIMITED"}, "message" => "too many"}]}, 400), :rate_limited},
          {response(%{"errors" => [%{"extensions" => %{"code" => "AUTHENTICATION_ERROR"}, "message" => "Authentication required"}]}, 400), :authentication_failed},
          {{:error, {:closed, "private transport details"}}, :offline}
        ] do
      request_fun = fn _endpoint, _payload, _headers -> response_value end
      assert {:error, ^expected} = Metadata.fetch(@connection, env_fetcher: fn _ -> "secret" end, request_fun: request_fun)
    end
  end

  test "the real HTTP adapter reports an unreachable endpoint without exposing transport details" do
    connection = put_in(@connection, ["policy", "endpoint"], "https://127.0.0.1:0/graphql")
    assert {:error, :offline} = Metadata.fetch(connection, env_fetcher: fn _ -> "fixture-key" end)
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

  test "bounds the first page before returning any catalog entries" do
    request_fun = fn _endpoint, %{"operationName" => "SymphonyMetadataTeams"}, _headers ->
      response(
        page("teams", [
          %{"id" => "t-1", "name" => "Platform", "key" => "PLAT"},
          %{"id" => "t-2", "name" => "Core", "key" => "CORE"}
        ])
      )
    end

    assert {:error, :catalog_limit} =
             Metadata.fetch(@connection,
               env_fetcher: fn _ -> "secret" end,
               request_fun: request_fun,
               max_entries: 1
             )
  end

  test "bounds project-team continuation entries across the complete connection" do
    request_fun =
      fn _endpoint, %{"operationName" => operation, "variables" => %{"after" => cursor}}, _headers ->
        case {operation, cursor} do
          {"SymphonyMetadataTeams", nil} ->
            response(page("teams", []))

          {"SymphonyMetadataProjects", nil} ->
            response(
              page(
                "projects",
                [project("p-1", "Checkout", "checkout", [%{"id" => "t-1"}], true, "team-1")]
              )
            )

          {"SymphonyMetadataProjectTeams", "team-1"} ->
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
        end
      end

    assert {:error, :catalog_limit} =
             Metadata.fetch(@connection,
               env_fetcher: fn _ -> "secret" end,
               request_fun: request_fun,
               max_entries: 1
             )
  end

  test "bounds project-team continuation pages before fetching another cursor" do
    request_fun =
      fn _endpoint, %{"operationName" => operation, "variables" => %{"after" => cursor}}, _headers ->
        case {operation, cursor} do
          {"SymphonyMetadataTeams", nil} ->
            response(page("teams", []))

          {"SymphonyMetadataProjects", nil} ->
            response(
              page(
                "projects",
                [project("p-1", "Checkout", "checkout", [%{"id" => "t-1"}], true, "team-1")]
              )
            )

          {"SymphonyMetadataProjectTeams", "team-1"} ->
            flunk("project-team continuation must not be fetched after the page bound")
        end
      end

    assert {:error, :catalog_limit} =
             Metadata.fetch(@connection,
               env_fetcher: fn _ -> "secret" end,
               request_fun: request_fun,
               max_pages: 1
             )
  end

  test "rejects malformed project-team continuation responses without partial projects" do
    request_fun =
      fn _endpoint, %{"operationName" => operation, "variables" => %{"after" => cursor}}, _headers ->
        case {operation, cursor} do
          {"SymphonyMetadataTeams", nil} ->
            response(page("teams", []))

          {"SymphonyMetadataProjects", nil} ->
            response(
              page(
                "projects",
                [project("p-1", "Checkout", "checkout", [%{"id" => "t-1"}], true, "team-1")]
              )
            )

          {"SymphonyMetadataProjectTeams", "team-1"} ->
            response(%{"data" => %{"project" => %{"teams" => %{"nodes" => :not_a_list}}}})
        end
      end

    assert {:error, :invalid_response} =
             Metadata.fetch(@connection,
               env_fetcher: fn _ -> "secret" end,
               request_fun: request_fun
             )
  end

  test "rejects invalid pagination limits before making a request" do
    for opts <- [[:bad_option], [page_size: 0], [page_size: :many], [max_pages: 0], [max_entries: -1]] do
      request_fun = fn _endpoint, _payload, _headers -> flunk("invalid limits must not make a request") end

      assert {:error, :invalid_response} =
               Metadata.fetch(
                 @connection,
                 opts ++ [env_fetcher: fn _ -> "secret" end, request_fun: request_fun]
               )
    end

    assert {:error, :invalid_response} = Metadata.fetch(:not_a_connection)
    assert {:error, :invalid_response} = Metadata.fetch(@connection, :not_a_keyword_list)

    assert {:error, :invalid_response} =
             Metadata.fetch(@connection, env_fetcher: fn _ -> "secret" end, request_fun: :not_callable)
  end

  test "fails closed for malformed connections, page info, and continuation responses" do
    malformed_bodies = [
      "not a response",
      %{"data" => "not a map"},
      %{
        "data" => %{
          "teams" => %{
            "nodes" => [%{"id" => "t-1"} | :improper_tail],
            "pageInfo" => %{"hasNextPage" => false}
          }
        }
      },
      %{},
      %{"data" => %{}},
      %{"data" => %{"teams" => %{"nodes" => :not_a_list, "pageInfo" => %{"hasNextPage" => false}}}},
      %{"data" => %{"teams" => %{"nodes" => [], "pageInfo" => nil}}},
      %{
        "data" => %{
          "teams" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true, "endCursor" => nil}}
        }
      },
      %{
        "data" => %{
          "teams" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => 42}}
        }
      }
    ]

    for body <- malformed_bodies do
      request_fun = fn _endpoint, _payload, _headers -> response(body) end

      assert {:error, :invalid_response} =
               Metadata.fetch(@connection,
                 env_fetcher: fn _ -> "secret" end,
                 request_fun: request_fun
               )
    end

    request_fun = fn _endpoint, %{"variables" => %{"after" => cursor}}, _headers ->
      case cursor do
        nil -> response(page("teams", [%{"id" => "t-1", "name" => "Platform", "key" => "PLAT"}], true, "next"))
        "next" -> response(%{"data" => %{"teams" => nil}})
      end
    end

    assert {:error, :invalid_response} =
             Metadata.fetch(@connection,
               env_fetcher: fn _ -> "secret" end,
               request_fun: request_fun
             )
  end

  test "rejects cursor cycles instead of returning repeated pages" do
    request_fun = fn _endpoint, %{"variables" => %{"after" => cursor}}, _headers ->
      case cursor do
        nil -> response(page("teams", [%{"id" => "t-1", "name" => "One", "key" => "ONE"}], true, "a"))
        "a" -> response(page("teams", [%{"id" => "t-2", "name" => "Two", "key" => "TWO"}], true, "b"))
        "b" -> response(page("teams", [%{"id" => "t-3", "name" => "Three", "key" => "THREE"}], true, "a"))
      end
    end

    assert {:error, :invalid_response} =
             Metadata.fetch(@connection,
               env_fetcher: fn _ -> "secret" end,
               request_fun: request_fun,
               max_pages: 10
             )
  end

  test "returns the transport classification when a later page fails" do
    request_fun = fn _endpoint, %{"variables" => %{"after" => cursor}}, _headers ->
      case cursor do
        nil ->
          response(
            page(
              "teams",
              [%{"id" => "t-1", "name" => "Platform", "key" => "PLAT"}],
              true,
              "next"
            )
          )

        "next" ->
          {:error, {:closed, "private continuation details"}}
      end
    end

    assert {:error, :offline} =
             Metadata.fetch(@connection,
               env_fetcher: fn _ -> "secret" end,
               request_fun: request_fun
             )
  end

  test "rejects incomplete catalog entries instead of returning partial metadata" do
    valid_teams = page("teams", [])
    valid_projects = page("projects", [project("p-1", "Checkout", "checkout", [])])
    valid_states = page("workflowStates", [])
    valid_labels = page("issueLabels", [])

    malformed_entries = [
      {"SymphonyMetadataTeams", page("teams", [%{"id" => "t-1", "name" => "Platform"}])},
      {"SymphonyMetadataTeams", page("teams", [nil])},
      {"SymphonyMetadataProjects", page("projects", [Map.delete(project("p-1", "Checkout", "checkout", []), "slugId")])},
      {"SymphonyMetadataProjects", page("projects", [project("p-1", "Checkout", "checkout", [%{}])])},
      {
        "SymphonyMetadataProjects",
        page("projects", [
          Map.put(project("p-1", "Checkout", "checkout", []), "teams", %{"nodes" => []})
        ])
      },
      {
        "SymphonyMetadataStates",
        page("workflowStates", [
          %{"id" => "s-1", "name" => "Todo", "type" => "unstarted", "team" => nil}
        ])
      },
      {
        "SymphonyMetadataLabels",
        page("issueLabels", [%{"id" => "l-1", "name" => "Ops", "team" => "not-a-team"}])
      }
    ]

    for {target_operation, malformed_body} <- malformed_entries do
      request_fun =
        fn _endpoint, %{"operationName" => operation}, _headers ->
          case operation do
            ^target_operation -> response(malformed_body)
            "SymphonyMetadataTeams" -> response(valid_teams)
            "SymphonyMetadataProjects" -> response(valid_projects)
            "SymphonyMetadataStates" -> response(valid_states)
            "SymphonyMetadataLabels" -> response(valid_labels)
          end
        end

      assert {:error, :invalid_response} =
               Metadata.fetch(@connection,
                 env_fetcher: fn _ -> "secret" end,
                 request_fun: request_fun
               )
    end
  end

  test "rejects invalid or unavailable secret references without contacting Linear" do
    invalid_references = ["plain-secret", "$", "${}", "$BAD!", 123, nil]

    for reference <- invalid_references do
      connection = put_in(@connection, ["policy", "api_key"], reference)

      request_fun = fn _endpoint, _payload, _headers -> send(self(), :unexpected_metadata_request) end

      assert {:error, :authentication_failed} =
               Metadata.fetch(connection,
                 env_fetcher: fn _variable ->
                   send(self(), :unexpected_env_lookup)
                   "secret"
                 end,
                 request_fun: request_fun
               )

      refute_received :unexpected_env_lookup
      refute_received :unexpected_metadata_request
    end

    unavailable_fetchers = [
      fn _variable -> nil end,
      fn _variable -> " \t" end,
      fn _variable -> {:error, :missing} end,
      fn _variable -> raise "resolver details must stay private" end,
      fn _variable -> throw({:resolver_failed, "secret"}) end
    ]

    for env_fetcher <- unavailable_fetchers do
      request_fun = fn _endpoint, _payload, _headers -> send(self(), :unexpected_metadata_request) end

      assert {:error, :authentication_failed} =
               Metadata.fetch(@connection, env_fetcher: env_fetcher, request_fun: request_fun)

      refute_received :unexpected_metadata_request
    end

    assert {:error, :invalid_response} =
             Metadata.fetch(@connection,
               env_fetcher: :not_a_function,
               request_fun: fn _endpoint, _payload, _headers ->
                 send(self(), :unexpected_metadata_request)
               end
             )

    refute_received :unexpected_metadata_request
  end

  test "rejects invalid endpoints before resolving credentials or making requests" do
    invalid_connections =
      Enum.map(
        [nil, "", "http://linear.example/graphql", "https://user:pass@linear.example/graphql", "https://[", "linear.example/graphql"],
        fn endpoint -> put_in(@connection, ["policy", "endpoint"], endpoint) end
      ) ++
        [put_in(@connection, ["policy", "kind"], "other")]

    for connection <- invalid_connections do
      request_fun = fn _endpoint, _payload, _headers -> send(self(), :unexpected_metadata_request) end

      assert {:error, :invalid_response} =
               Metadata.fetch(connection,
                 env_fetcher: fn _variable ->
                   send(self(), :unexpected_env_lookup)
                   "secret"
                 end,
                 request_fun: request_fun
               )

      refute_received :unexpected_env_lookup
      refute_received :unexpected_metadata_request
    end
  end

  test "preserves transport and GraphQL failure precedence without exposing details" do
    authentication_body = %{
      "errors" => [%{"extensions" => %{"code" => "UNAUTHENTICATED"}, "message" => "secret token"}]
    }

    rate_limit_body = %{
      "errors" => [%{"extensions" => %{"code" => "RATELIMITED"}, "message" => "too many requests"}]
    }

    cases = [
      {fn _endpoint, _payload, _headers -> response(authentication_body, 401) end, :authentication_failed},
      {fn _endpoint, _payload, _headers -> response(rate_limit_body, 429) end, :rate_limited},
      {fn _endpoint, _payload, _headers -> response(authentication_body, 408) end, :offline},
      {fn _endpoint, _payload, _headers -> response(authentication_body, 500) end, :offline},
      {fn _endpoint, _payload, _headers -> %{status: 401, body: %{"errors" => "private"}} end, :authentication_failed},
      {fn _endpoint, _payload, _headers -> {:error, {:closed, "private transport details"}} end, :offline},
      {fn _endpoint, _payload, _headers -> raise "private transport details" end, :offline},
      {fn _endpoint, _payload, _headers -> throw({:transport, "private transport details"}) end, :offline},
      {fn _endpoint, _payload, _headers -> {:ok, :not_a_response} end, :invalid_response},
      {fn _endpoint, _payload, _headers -> :not_a_response end, :invalid_response},
      {
        fn _endpoint, _payload, _headers ->
          response(
            %{
              "errors" => [
                Map.merge(authentication_body["errors"] |> hd(), %{
                  "extensions" => %{"code" => "RATELIMITED"},
                  "message" => "authentication required"
                })
              ]
            },
            400
          )
        end,
        :rate_limited
      },
      {
        fn _endpoint, _payload, _headers ->
          response(
            %{
              "errors" => [
                %{"extensions" => %{"code" => "RATELIMITED"}, "message" => "too many requests"},
                %{"extensions" => %{"code" => "UNAUTHENTICATED"}, "message" => "authentication required"}
              ]
            },
            400
          )
        end,
        :authentication_failed
      },
      {
        fn _endpoint, _payload, _headers ->
          response(%{"errors" => [%{"extensions" => %{"code" => "UNKNOWN"}, "message" => "unexpected"}]})
        end,
        :invalid_response
      },
      {fn _endpoint, _payload, _headers -> response(%{"data" => %{}}, 400) end, :invalid_response},
      {fn _endpoint, _payload, _headers -> response(%{}, 302) end, :invalid_response},
      {fn _endpoint, _payload, _headers -> response(%{"errors" => [nil]}, 400) end, :invalid_response}
    ]

    for {request_fun, expected} <- cases do
      assert {:error, ^expected} =
               Metadata.fetch(@connection, env_fetcher: fn _ -> "secret" end, request_fun: request_fun)
    end
  end
end
