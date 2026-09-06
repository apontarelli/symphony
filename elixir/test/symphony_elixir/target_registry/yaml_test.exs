defmodule SymphonyElixir.TargetRegistry.YamlTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TargetRegistry.Yaml

  test "decode preserves supported scalar, list, and map values" do
    yaml = """
    string: value
    integer: 42
    float: 1.5
    boolean: true
    "null": null
    empty_list: []
    empty_map: {}
    list:
      - one
      - 2
      - false
      - nested: value
    map:
      child:
        - alpha
        - beta
    """

    assert {:ok,
            %{
              "string" => "value",
              "integer" => 42,
              "float" => 1.5,
              "boolean" => true,
              "null" => nil,
              "empty_list" => [],
              "empty_map" => %{},
              "list" => ["one", 2, false, %{"nested" => "value"}],
              "map" => %{"child" => ["alpha", "beta"]}
            }} = Yaml.decode(yaml)
  end

  test "decode preserves valid UTF-8 binary scalars and finite floats" do
    yaml = "!!binary aMOpbGxv: 1.25\n"

    assert {:ok, %{"héllo" => 1.25} = registry} = Yaml.decode(yaml)
    assert registry |> Yaml.encode() |> Yaml.decode() == {:ok, registry}
  end

  test "decode rejects unsupported scalar nodes with deterministic paths" do
    cases = [
      {"invalid UTF-8 map value", "value: !!binary /w==\n", "$.value"},
      {"invalid UTF-8 list value", "values: [valid, !!binary /w==]\n", "$.values[1]"},
      {"invalid UTF-8 map key", "!!binary /w==: value\n", "$[key:0]"},
      {"nested invalid UTF-8 map key", "nested:\n  !!binary /w==: value\n", "$.nested[key:0]"},
      {"NaN", "value: .nan\n", "$.value"},
      {"positive infinity", "value: .inf\n", "$.value"},
      {"negative infinity", "value: -.inf\n", "$.value"}
    ]

    for {name, yaml, path} <- cases do
      message = "unsupported YAML scalar at #{path}"

      assert {:error,
              %Yaml.Error{
                code: :unsupported_scalar,
                message: ^message,
                path: ^path
              }} = Yaml.decode(yaml),
             "expected #{name} to be rejected"
    end
  end

  test "decode supports a verbatim explicit merge tag" do
    yaml = """
    defaults: &defaults
      model: base
    runner:
      !<tag:yaml.org,2002:merge> <<: *defaults
      command: run
    """

    assert {:ok,
            %{
              "defaults" => %{"model" => "base"},
              "runner" => %{"model" => "base", "command" => "run"}
            }} = Yaml.decode(yaml)
  end

  test "decode supports the explicit merge tag shorthand" do
    yaml = """
    defaults: &defaults
      model: base
    runner:
      !!merge <<: *defaults
      command: run
    """

    assert {:ok,
            %{
              "defaults" => %{"model" => "base"},
              "runner" => %{"model" => "base", "command" => "run"}
            }} = Yaml.decode(yaml)
  end

  test "decode rejects explicit merge tags on keys other than <<" do
    cases = [
      "runner:\n  !!merge model: value\n",
      "runner:\n  !<tag:yaml.org,2002:merge> model: value\n",
      "runner:\n  !!merge \"model\": value\n"
    ]

    for yaml <- cases do
      assert {:error, %Yaml.Error{code: :invalid_yaml, message: "invalid YAML"}} =
               Yaml.decode(yaml)
    end
  end

  test "decode rejects explicit merge tags on collection tokens" do
    cases = [
      "runner: !!merge [one]\n",
      "runner: !!merge {one: two}\n",
      "runner: !<tag:yaml.org,2002:merge> [one]\n",
      """
      runner:
        !!merge
          one: two
      """
    ]

    for yaml <- cases do
      assert {:error, %Yaml.Error{code: :invalid_yaml, message: "invalid YAML"}} =
               Yaml.decode(yaml)
    end
  end

  test "encode quotes ambiguous binary keys and round-trips them as strings" do
    registry = %{
      "" => "empty",
      "<<" => "merge",
      "true" => "boolean",
      "null" => "null",
      "1" => "integer",
      "1.5" => "float",
      "# note" => "comment",
      "[list]" => "indicator",
      "key: value" => "colon",
      "safe_key" => "plain"
    }

    yaml = Yaml.encode(registry)

    assert yaml =~ ~s(safe_key: "plain")

    for key <- ["", "<<", "true", "null", "1", "1.5", "# note", "[list]", "key: value"] do
      assert yaml =~ "#{inspect(key)}:", "expected #{inspect(key)} to be quoted in:\n#{yaml}"
    end

    assert {:ok, ^registry} = Yaml.decode(yaml)
  end

  test "encode escapes C1 characters in registry keys and values" do
    registry = %{"key\u0085" => "before\u0080\u009Fafter"}

    assert Yaml.encode(registry) == "\"key\\x85\": \"before\\x80\\x9Fafter\"\n"
    assert registry |> Yaml.encode() |> Yaml.decode() == {:ok, registry}
  end

  test "encode round-trips floats and recursively nested lists and maps" do
    registry = %{
      "float" => 1.5,
      "list" => [
        nil,
        "line one\nline \"two\"\\end\t",
        42,
        2.25,
        true,
        false,
        [],
        [3.5, %{"nested" => 4.75}]
      ],
      "map" => %{"items" => [%{"ratio" => 0.5}, [6.25]]}
    }

    assert registry |> Yaml.encode() |> Yaml.decode() == {:ok, registry}
  end

  test "encode rejects unsupported terms with the renderer error shape and path" do
    cases = [
      {:unsupported, "$"},
      {[:unsupported], "$[0]"},
      {%{"tuple" => {:unsupported}}, "$.tuple"},
      {%{"outer" => [%{"inner" => :unsupported}]}, "$.outer[0].inner"},
      {%{"outer.key" => :unsupported}, "$[\"outer.key\"]"},
      {<<255>>, "$"},
      {[1 | 2], "$"}
    ]

    for {value, path} <- cases do
      message =
        "unsupported registry YAML value at #{path}: expected nil, a valid UTF-8 binary, an integer, a finite float, a boolean, a list, or a map"

      assert_raise ArgumentError, message, fn ->
        Yaml.encode(value)
      end
    end

    for key <- [:unsupported, <<255>>] do
      assert_raise ArgumentError,
                   "unsupported registry YAML map key at $[key:0]: expected a valid UTF-8 binary",
                   fn ->
                     Yaml.encode(%{key => "value"})
                   end
    end
  end

  test "encode keeps its string success type for each supported root type" do
    assert Yaml.encode(nil) == "null\n"
    assert Yaml.encode("value") == "\"value\"\n"
    assert Yaml.encode(42) == "42\n"
    assert Yaml.encode(1.5) == "1.5\n"
    assert Yaml.encode(true) == "true\n"
    assert Yaml.encode([]) == "[]\n"
    assert Yaml.encode(%{}) == "{}\n"
  end

  test "decode preserves non-overlapping YAML merges" do
    yaml = """
    defaults: &defaults
      model: base
      timeout_ms: 100
    runner:
      <<: *defaults
      command: run
    """

    assert {:ok,
            %{
              "defaults" => %{"model" => "base", "timeout_ms" => 100},
              "runner" => %{"model" => "base", "timeout_ms" => 100, "command" => "run"}
            }} = Yaml.decode(yaml)
  end

  test "decode rejects a key supplied by a merge and written directly" do
    yaml = """
    defaults: &defaults
      model: base
    runner:
      <<: *defaults
      model: direct
    """

    assert {:error, %{code: :duplicate_key, path: "$.runner.model", key: "model"}} =
             Yaml.decode(yaml)
  end

  test "decode rejects a direct key written before a merge supplies it" do
    yaml = """
    defaults: &defaults
      model: base
    runner:
      model: direct
      <<: *defaults
    """

    assert {:error, %{code: :duplicate_key, path: "$.runner.model", key: "model"}} =
             Yaml.decode(yaml)
  end

  test "decode preserves nested YAML merges" do
    yaml = """
    base: &base
      model: base
    defaults: &defaults
      <<: *base
      timeout_ms: 100
    runner:
      <<: *defaults
      command: run
    """

    assert {:ok,
            %{
              "base" => %{"model" => "base"},
              "defaults" => %{"model" => "base", "timeout_ms" => 100},
              "runner" => %{"model" => "base", "timeout_ms" => 100, "command" => "run"}
            }} = Yaml.decode(yaml)
  end

  test "decode rejects repeated semantic merge keys" do
    yaml = """
    first: &first
      model: first
    second: &second
      timeout_ms: 100
    runner:
      <<: *first
      <<: *second
    """

    assert {:error, %{code: :duplicate_key, path: "$.runner.<<", key: "<<"}} =
             Yaml.decode(yaml)
  end

  test "decode preserves a sequence of non-overlapping merge maps" do
    yaml = """
    model: &model
      model: base
    timeout: &timeout
      timeout_ms: 100
    runner:
      <<: [*model, *timeout]
      command: run
    """

    assert {:ok, registry} = Yaml.decode(yaml)

    assert registry["runner"] == %{
             "model" => "base",
             "timeout_ms" => 100,
             "command" => "run"
           }
  end

  test "decode rejects overlapping keys from merge sources" do
    yaml = """
    first: &first
      model: first
    second: &second
      model: second
    runner:
      <<: [*first, *second]
    """

    assert {:error, %{code: :duplicate_key, path: "$.runner.model", key: "model"}} =
             Yaml.decode(yaml)
  end

  test "decode distinguishes semantic and literal merge-shaped alias keys" do
    yaml = """
    source: &source
      model: base
    quoted:
      "<<": *source
    tagged:
      !!str <<: *source
    merged:
      <<: *source
    """

    assert {:ok, registry} = Yaml.decode(yaml)
    assert registry["quoted"] == %{"<<" => %{"model" => "base"}}
    assert registry["tagged"] == %{"<<" => %{"model" => "base"}}
    assert registry["merged"] == %{"model" => "base"}
  end

  test "decode returns stable errors for undefined and cyclic aliases" do
    cases = [
      "value: *missing\n",
      """
      root: &root
        self: *root
      """
    ]

    for yaml <- cases do
      assert {:error, %{code: :invalid_yaml, message: "invalid YAML"}} = Yaml.decode(yaml)
    end
  end

  test "decode rejects invalid merge scalar and sequence values" do
    cases = [
      """
      runner:
        <<: value
      """,
      """
      defaults: &defaults
        model: base
      runner:
        <<: [*defaults, value]
      """
    ]

    for yaml <- cases do
      assert {:error,
              %{
                code: :invalid_yaml,
                path: "$.runner.<<",
                key: "<<",
                message: "YAML merge at $.runner.<< must contain a map or list of maps"
              }} = Yaml.decode(yaml)
    end
  end

  test "decode chooses a deterministic error for competing merge collisions" do
    yaml = """
    first: &first
      zeta: first
      alpha: first
    second: &second
      zeta: second
      alpha: second
    runner:
      <<: [*first, *second]
    """

    assert [result] = yaml |> then(&Enum.map(1..10, fn _ -> Yaml.decode(&1) end)) |> Enum.uniq()

    assert {:error, %{code: :duplicate_key, path: "$.runner.alpha", key: "alpha"}} =
             result
  end

  test "decode preserves duplicate detection across wide direct and merged maps" do
    entries =
      Enum.map(0..511, fn index ->
        key = index |> Integer.to_string() |> String.pad_leading(4, "0")
        "key_#{key}: #{index}"
      end)

    direct_yaml = Enum.join(entries, "\n") <> "\nkey_0511: duplicate\n"

    assert {:error, %{code: :duplicate_key, path: "$.key_0511", key: "key_0511"}} =
             Yaml.decode(direct_yaml)

    merge_yaml =
      "defaults: &defaults\n" <>
        Enum.map_join(entries, "\n", &"  #{&1}") <>
        "\nrunner:\n  <<: *defaults\n  key_0511: duplicate\n"

    assert {:error, %{code: :duplicate_key, path: "$.runner.key_0511", key: "key_0511"}} =
             Yaml.decode(merge_yaml)
  end

  test "decode rejects repeated literal and quoted merge-shaped keys" do
    cases = [
      {"quoted",
       """
       quoted:
         "<<": first
         '<<': second
       """},
      {"literal",
       """
       literal:
         !!str <<: first
         "<<": second
       """}
    ]

    for {path, yaml} <- cases do
      expected_path = "$.#{path}.<<"

      assert {:error, %{code: :duplicate_key, path: ^expected_path, key: "<<"}} =
               Yaml.decode(yaml)
    end
  end

  test "decode is deterministic across repeated merge and literal-key parsing" do
    yaml = """
    defaults: &defaults
      model: base
    runner:
      <<: *defaults
      timeout_ms: 100
    literal:
      "<<": value
    """

    expected =
      {:ok,
       %{
         "defaults" => %{"model" => "base"},
         "runner" => %{"model" => "base", "timeout_ms" => 100},
         "literal" => %{"<<" => "value"}
       }}

    assert yaml |> then(&Enum.map(1..10, fn _ -> Yaml.decode(&1) end)) |> Enum.uniq() ==
             [expected]
  end

  test "decode rejects duplicate keys at every registry map depth" do
    cases = [
      {"top-level key",
       """
       version: 1
       version: 2
       """, "$.version", "version"},
      {"target ID",
       """
       targets:
         alpha: {}
         alpha: {}
       """, "$.targets.alpha", "alpha"},
      {"nested budget key",
       """
       targets:
         alpha:
           budgets:
             daily:
               max_total_tokens: 100
               max_total_tokens: 200
       """, "$.targets.alpha.budgets.daily.max_total_tokens", "max_total_tokens"},
      {"gate key",
       """
       targets:
         alpha:
           external_side_effects:
             merge: deny
             merge: allow
       """, "$.targets.alpha.external_side_effects.merge", "merge"}
    ]

    for {name, yaml, path, key} <- cases do
      assert {:error, %{code: :duplicate_key, path: ^path, key: ^key}} = Yaml.decode(yaml),
             "expected #{name} to be rejected"
    end
  end

  test "decode rejects non-string map keys" do
    cases = [
      {"integer", "1: value\n"},
      {"boolean", "true: value\n"},
      {"sequence", "? [alpha, beta]\n: value\n"},
      {"map", "? {nested: key}\n: value\n"}
    ]

    for {name, yaml} <- cases do
      assert {:error, %{code: :non_string_key, path: "$"}} = Yaml.decode(yaml),
             "expected #{name} key to be rejected"
    end
  end

  test "decode reports duplicate keys inside a complex map key" do
    yaml = "? {nested: first, nested: second}\n: value\n"

    assert {:error, %{code: :duplicate_key, path: "$.nested", key: "nested"}} =
             Yaml.decode(yaml)
  end

  test "decode rejects multiple YAML documents" do
    yaml = """
    version: 1
    ---
    version: 2
    """

    assert {:error, %{code: :multiple_documents, document_count: 2}} = Yaml.decode(yaml)
  end

  test "decode counts explicit empty documents mixed with non-empty documents" do
    cases = [
      "---\n...\n---\nversion: 1\n",
      "---\nversion: 1\n...\n---\n...\n"
    ]

    for yaml <- cases do
      assert {:error, %{code: :multiple_documents, document_count: 2}} = Yaml.decode(yaml)
    end
  end

  test "decode returns a stable missing-document error for empty streams" do
    for yaml <- ["", "# comment only\n"] do
      assert {:error,
              %Yaml.Error{
                code: :missing_document,
                message: "expected one YAML document, got 0",
                document_count: 0
              }} = Yaml.decode(yaml)
    end
  end

  test "decode returns a stable error for malformed YAML" do
    assert {:error, %{code: :invalid_yaml, message: "invalid YAML"}} =
             Yaml.decode("version: [\n")
  end

  test "decode rejects non-map roots" do
    for yaml <- ["value\n", "- one\n- two\n", "---\n...\n"] do
      assert {:error, %{code: :invalid_root, message: "YAML root must be a map"}} =
               Yaml.decode(yaml)
    end
  end

  test "encode uses stable registry and dynamic ID ordering" do
    registry = %{
      "targets" => %{
        "zeta" => %{
          "external_side_effects" => %{"merge" => "deny", "tracker_write" => "allow"},
          "budgets" => %{
            "weekly" => %{"max_total_tokens" => 700},
            "per_run" => %{"max_total_tokens" => 100},
            "daily" => %{"max_total_tokens" => 500}
          },
          "display_name" => "Zeta"
        },
        "alpha" => %{"state" => "paused"}
      },
      "host" => %{
        "capacity" => %{
          "max_concurrent_reviewers" => 2,
          "max_concurrent_startups" => 1,
          "max_concurrent_agents" => 3
        },
        "polling" => %{"max_concurrent_target_polls" => 2, "interval_ms" => 5_000},
        "id" => "local"
      },
      "version" => 1
    }

    assert Yaml.encode(registry) ==
             """
             version: 1
             host:
               id: "local"
               polling:
                 interval_ms: 5000
                 max_concurrent_target_polls: 2
               capacity:
                 max_concurrent_agents: 3
                 max_concurrent_startups: 1
                 max_concurrent_reviewers: 2
             targets:
               alpha:
                 state: "paused"
               zeta:
                 display_name: "Zeta"
                 budgets:
                   per_run:
                     max_total_tokens: 100
                   daily:
                     max_total_tokens: 500
                   weekly:
                     max_total_tokens: 700
                 external_side_effects:
                   tracker_write: "allow"
                   merge: "deny"
             """
  end

  test "encode orders repository branch between manifest and expected repository" do
    registry = %{
      "targets" => %{
        "main" => %{
          "repo" => %{
            "expected_repository" => "org/repo",
            "branch" => "release/2026",
            "manifest" => "symphony.yml",
            "path" => "/tmp/repo"
          }
        }
      },
      "version" => 1
    }

    assert Yaml.encode(registry) ==
             """
             version: 1
             targets:
               main:
                 repo:
                   path: "/tmp/repo"
                   manifest: "symphony.yml"
                   branch: "release/2026"
                   expected_repository: "org/repo"
             """
  end

  test "encode round-trips empty maps at every structural position" do
    cases = [
      {"root", %{}},
      {"nested map", %{"nested" => %{"empty" => %{}}}},
      {"list element", %{"items" => [%{}, %{"nested" => %{}}]}}
    ]

    for {name, registry} <- cases do
      yaml = Yaml.encode(registry)

      assert {:ok, ^registry} = Yaml.decode(yaml),
             "expected #{name} empty map to round-trip, encoded as:\n#{yaml}"
    end

    assert Yaml.encode(%{}) == "{}\n"
  end

  test "encode canonically orders every fixed host runner field" do
    registry = %{
      "host" => %{
        "runners" => %{
          "codex" => %{
            "max_concurrent_startups" => 2,
            "permissions" => ["read", "write"],
            "config_content" => "model = test",
            "port" => 4_001,
            "execution_profiles" => %{
              "review" => %{
                "command" => ["codex", "app-server"],
                "max_retries" => 2,
                "timeout_ms" => 1_000,
                "budget" => "standard",
                "reasoning_effort" => "high",
                "model" => "gpt-review"
              }
            },
            "thread_sandbox" => "workspace-write",
            "read_timeout_ms" => 2_000,
            "command" => ["codex", "app-server"],
            "startup_timeout_ms" => 5_000,
            "approval_policy" => "never",
            "config_path" => "/tmp/config/config.toml",
            "turn_sandbox_policy" => %{
              "networkAccess" => true,
              "excludeSlashTmp" => false,
              "readOnlyAccess" => %{"type" => "fullAccess"},
              "writableRoots" => ["/tmp/workspace"],
              "excludeTmpdirEnvVar" => false,
              "type" => "workspaceWrite"
            },
            "agent" => "reviewer",
            "model" => "gpt-main",
            "hostname" => "127.0.0.1",
            "turn_timeout_ms" => 1_000,
            "stall_timeout_ms" => 3_000,
            "server_auth" => %{"password" => "secret", "username" => "operator"},
            "kind" => "app_server",
            "config_dir" => "/tmp/config",
            "max_concurrent_agents" => 4
          }
        }
      },
      "targets" => %{
        "alpha" => %{
          "runners" => %{
            "settings" => %{
              "codex" => %{
                "execution_profiles" => %{
                  "implementation" => %{
                    "max_retries" => 1,
                    "model" => "gpt-implementation",
                    "reasoning_effort" => "medium",
                    "budget" => "standard",
                    "timeout_ms" => 2_000
                  }
                },
                "model" => "gpt-default"
              }
            }
          }
        }
      }
    }

    assert Yaml.encode(registry) ==
             """
             host:
               runners:
                 codex:
                   kind: "app_server"
                   command:
                     - "codex"
                     - "app-server"
                   model: "gpt-main"
                   approval_policy: "never"
                   thread_sandbox: "workspace-write"
                   turn_sandbox_policy:
                     type: "workspaceWrite"
                     writableRoots:
                       - "/tmp/workspace"
                     readOnlyAccess:
                       type: "fullAccess"
                     networkAccess: true
                     excludeTmpdirEnvVar: false
                     excludeSlashTmp: false
                   turn_timeout_ms: 1000
                   read_timeout_ms: 2000
                   stall_timeout_ms: 3000
                   execution_profiles:
                     review:
                       model: "gpt-review"
                       reasoning_effort: "high"
                       budget: "standard"
                       timeout_ms: 1000
                       max_retries: 2
                       command:
                         - "codex"
                         - "app-server"
                   agent: "reviewer"
                   hostname: "127.0.0.1"
                   port: 4001
                   config_dir: "/tmp/config"
                   config_path: "/tmp/config/config.toml"
                   config_content: "model = test"
                   server_auth:
                     username: "operator"
                     password: "secret"
                   permissions:
                     - "read"
                     - "write"
                   startup_timeout_ms: 5000
                   max_concurrent_agents: 4
                   max_concurrent_startups: 2
             targets:
               alpha:
                 runners:
                   settings:
                     codex:
                       model: "gpt-default"
                       execution_profiles:
                         implementation:
                           model: "gpt-implementation"
                           reasoning_effort: "medium"
                           budget: "standard"
                           timeout_ms: 2000
                           max_retries: 1
             """
  end
end
