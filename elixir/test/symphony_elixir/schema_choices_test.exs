defmodule SymphonyElixir.SchemaChoicesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "finite configuration catalogs accept each exposed value and reject unknown values" do
    base = %{"profiles" => %{"default" => %{"delivery" => %{"pr_target" => "main"}}}}

    for {path, definition} <- Schema.settings_choices(), not String.starts_with?(path, "runners.") do
      [section, field] = String.split(path, ".")

      for value <- definition.values do
        assert {:ok, _settings} = Schema.parse(Map.put(base, section, %{field => value})), "#{path}=#{value}"
      end

      assert {:error, {:invalid_workflow_config, _}} = Schema.parse(Map.put(base, section, %{field => "unsupported"}))
    end
  end

  test "all catalog runner kinds have accepted configurations and unknown kinds are rejected" do
    runners = %{
      "codex" => %{"kind" => "codex_app_server", "command" => ["codex"], "model" => "gpt-5.6"},
      "omp" => %{"kind" => "omp_acp", "command" => ["omp", "--no-extensions", "--no-skills"], "profile" => "default", "thinking" => "medium", "model" => "provider/model"},
      "open" => %{"kind" => "opencode_server", "command" => ["opencode"]}
    }

    assert Enum.sort(Enum.map(runners, fn {_, runner} -> runner["kind"] end)) == Schema.settings_choices()["runners.*.kind"].values
    assert {:ok, _normalized} = Schema.validate_runner_catalog(runners)
    assert {:error, _errors} = Schema.validate_runner_catalog(%{"codex" => Map.put(runners["codex"], "kind", "unsupported")})

    for {path, runner_name, field, wrap} <- [
          {"runners.*.thinking", "omp", "thinking", &Function.identity/1},
          {"runners.*.permissions.*", "omp", "permissions", &%{"read" => &1}},
          {"runners.*.hostname", "open", "hostname", &Function.identity/1}
        ] do
      for value <- Schema.settings_choices()[path].values do
        assert {:ok, _} =
                 Schema.validate_runner_catalog(%{
                   runner_name => Map.put(runners[runner_name], field, wrap.(value))
                 })
      end

      assert {:error, _} =
               Schema.validate_runner_catalog(%{
                 runner_name => Map.put(runners[runner_name], field, wrap.("unsupported"))
               })
    end
  end
end
