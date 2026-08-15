defmodule SymphonyElixir.Workflow.Renderer do
  @moduledoc false

  alias SymphonyElixir.Workflow.Manifest

  @spec check_success(Path.t(), map(), Manifest.validation_report()) :: String.t()
  def check_success(repo_root, manifest, report) do
    lines = [
      "Workflow check passed",
      "manifest: #{Manifest.manifest_path(repo_root)}",
      "preset: #{report.preset}",
      "modules:",
      module_lines(report.modules),
      "docs:",
      value_lines(get_in(manifest, ["docs", "entrypoints"]) || []),
      "validation:",
      validation_lines(get_in(manifest, ["validation", "commands"]) || []),
      "publish target:",
      publish_target_lines(manifest),
      "harness.codex_home: #{harness_summary(manifest)}"
    ]

    lines |> List.flatten() |> Enum.join("\n")
  end

  @spec check_failure(Manifest.validation_report()) :: String.t()
  def check_failure(report) do
    ["Workflow check failed" | Enum.map(report.errors, &format_error/1)]
    |> Enum.join("\n")
  end

  @spec print(Path.t(), map(), Manifest.validation_report(), boolean()) :: String.t()
  def print(repo_root, manifest, report, compiled?) do
    summary =
      [
        "Resolved workflow",
        "manifest: #{Manifest.manifest_path(repo_root)}",
        "project: #{get_in(manifest, ["project", "name"])} (#{get_in(manifest, ["project", "kind"])}/#{get_in(manifest, ["project", "app_kind"])})",
        "preset: #{report.preset}",
        "modules:",
        module_lines(report.modules),
        "defaults:",
        "  delivery.pr_target: #{get_in(manifest, ["delivery", "pr_target"])}",
        "  vcs.mode: #{get_in(manifest, ["vcs", "mode"])}",
        "  harness.codex_home: #{harness_summary(manifest)}",
        "publish target:",
        publish_target_lines(manifest),
        "docs:",
        value_lines(get_in(manifest, ["docs", "entrypoints"]) || []),
        "validation:",
        validation_lines(get_in(manifest, ["validation", "commands"]) || [])
      ]
      |> List.flatten()
      |> Enum.join("\n")

    if compiled? do
      summary <> "\n\nCompiled workflow\n" <> compiled_workflow(manifest)
    else
      summary
    end
  end

  @spec to_yaml(term()) :: String.t()
  def to_yaml(value) do
    key_order = legacy_key_order()
    render_yaml(value, 0, fn _path -> key_order end, [], :legacy) <> "\n"
  end

  @type yaml_path :: [String.t() | non_neg_integer()]
  @type key_order :: [String.t()] | (yaml_path() -> [String.t()])

  @spec to_yaml(term(), key_order()) :: String.t()
  def to_yaml(value, key_order) when is_list(key_order) do
    to_yaml(value, fn _path -> key_order end)
  end

  def to_yaml(value, key_order) when is_function(key_order, 1) do
    render_yaml(value, 0, key_order, [], :registry) <> "\n"
  end

  defp module_lines(modules) do
    Enum.map(modules, fn module_name ->
      "  - #{module_name}: #{Manifest.module_description(module_name)}"
    end)
  end

  defp value_lines([]), do: ["  - none"]
  defp value_lines(values), do: Enum.map(values, &"  - #{&1}")

  defp validation_lines([]), do: ["  - none"]

  defp validation_lines(commands) do
    Enum.map(commands, fn command ->
      "  - #{Map.get(command, "name")}: #{Map.get(command, "command")}"
    end)
  end

  defp publish_target_lines(manifest) do
    case Manifest.publish_target(manifest) do
      %{"display" => display, "repository" => repository, "pr_target" => pr_target} ->
        [
          "  repository: #{repository}",
          "  pr_target: #{pr_target}",
          "  resolved: #{display}"
        ]

      _target ->
        ["  - none"]
    end
  end

  defp harness_summary(manifest) do
    case get_in(manifest, ["harness", "codex_home"]) do
      nil -> "managed default"
      path -> path
    end
  end

  defp compiled_workflow(manifest) do
    compiled = Manifest.compile(manifest)

    "---\n" <> to_yaml(compiled.config) <> "---\n\n" <> compiled.prompt
  end

  defp format_error(%{path: path, message: message, remediation: remediation}) do
    "- #{path}: #{message}. #{remediation}"
  end

  defp render_yaml(value, indent, _key_order, _path, :registry)
       when is_map(value) and map_size(value) == 0 do
    String.duplicate(" ", indent) <> "{}"
  end

  defp render_yaml(value, indent, key_order, path, mode) when is_map(value) do
    value
    |> ordered_entries(key_order.(Enum.reverse(path)))
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {{key, nested}, index} ->
      spaces = String.duplicate(" ", indent)
      rendered_key = render_key(key, mode, [{:key, index} | path])

      if scalar?(nested, mode) do
        "#{spaces}#{rendered_key}: #{render_scalar(nested, mode)}"
      else
        "#{spaces}#{rendered_key}:\n#{render_yaml(nested, indent + 2, key_order, [key | path], mode)}"
      end
    end)
  end

  defp render_yaml([], indent, _key_order, _path, _mode),
    do: String.duplicate(" ", indent) <> "[]"

  defp render_yaml(values, indent, key_order, path, mode) when is_list(values) do
    if mode == :registry and not proper_list?(values) do
      unsupported_registry_value!(values, path)
    end

    values
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {value, index} ->
      spaces = String.duplicate(" ", indent)

      cond do
        scalar?(value, mode) ->
          "#{spaces}- #{render_scalar(value, mode)}"

        is_map(value) ->
          [first | rest] =
            value
            |> render_yaml(indent + 2, key_order, [index | path], mode)
            |> String.split("\n")

          ([spaces <> "- " <> String.trim_leading(first)] ++ rest) |> Enum.join("\n")

        mode == :registry and is_list(value) ->
          "#{spaces}-\n#{render_yaml(value, indent + 2, key_order, [index | path], mode)}"

        mode == :legacy ->
          "#{spaces}- #{render_scalar(to_string(value), mode)}"

        true ->
          unsupported_registry_value!(value, [index | path])
      end
    end)
  end

  defp render_yaml(value, indent, _key_order, path, :registry) do
    if scalar?(value, :registry) do
      String.duplicate(" ", indent) <> render_scalar(value, :registry)
    else
      unsupported_registry_value!(value, path)
    end
  end

  defp scalar?(value, :legacy),
    do: is_nil(value) or is_binary(value) or is_integer(value) or is_boolean(value) or value == []

  defp scalar?(value, :registry),
    do:
      is_nil(value) or (is_binary(value) and String.valid?(value)) or is_integer(value) or
        is_boolean(value) or value == [] or is_float(value)

  defp render_scalar(nil, _mode), do: "null"
  defp render_scalar(true, _mode), do: "true"
  defp render_scalar(false, _mode), do: "false"
  defp render_scalar([], _mode), do: "[]"
  defp render_scalar(value, _mode) when is_integer(value), do: Integer.to_string(value)
  defp render_scalar(value, :registry) when is_float(value), do: Float.to_string(value)

  defp render_scalar(value, :legacy) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  defp render_scalar(value, :registry) when is_binary(value), do: quote_yaml_string(value)

  defp render_key(key, :legacy, _path), do: key

  defp render_key(key, :registry, path) when is_binary(key) do
    if String.valid?(key) do
      if plain_registry_key?(key), do: key, else: quote_yaml_string(key)
    else
      unsupported_registry_key!(key, path)
    end
  end

  defp render_key(key, :registry, path), do: unsupported_registry_key!(key, path)

  defp proper_list?([]), do: true
  defp proper_list?([_value | rest]), do: proper_list?(rest)
  defp proper_list?(_value), do: false

  defp unsupported_registry_value!(_value, path) do
    raise ArgumentError,
          "unsupported registry YAML value at #{registry_yaml_path(path)}: expected nil, a valid UTF-8 binary, an integer, a finite float, a boolean, a list, or a map"
  end

  defp unsupported_registry_key!(_key, path) do
    raise ArgumentError,
          "unsupported registry YAML map key at #{registry_yaml_path(path)}: expected a valid UTF-8 binary"
  end

  defp registry_yaml_path(path) do
    path
    |> Enum.reverse()
    |> Enum.reduce("$", fn
      index, rendered when is_integer(index) ->
        "#{rendered}[#{index}]"

      {:key, index}, rendered ->
        "#{rendered}[key:#{index}]"

      key, rendered ->
        if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_-]*$/, key) do
          "#{rendered}.#{key}"
        else
          "#{rendered}[#{inspect(key)}]"
        end
    end)
  end

  defp plain_registry_key?(key) do
    Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_-]*$/, key) and
      key |> String.downcase() |> then(&(&1 not in ["null", "true", "false", "yes", "no", "on", "off", "y", "n"]))
  end

  @yaml_escapes %{
    ?\\ => "\\\\",
    ?" => "\\\"",
    0x00 => "\\0",
    0x07 => "\\a",
    0x08 => "\\b",
    0x09 => "\\t",
    0x0A => "\\n",
    0x0B => "\\v",
    0x0C => "\\f",
    0x0D => "\\r",
    0x1B => "\\e"
  }

  defp quote_yaml_string(value) do
    escaped =
      value
      |> String.to_charlist()
      |> Enum.map_join(fn codepoint ->
        case Map.fetch(@yaml_escapes, codepoint) do
          {:ok, escape} ->
            escape

          :error when codepoint < 0x20 or codepoint in 0x7F..0x9F ->
            "\\x" <> (codepoint |> Integer.to_string(16) |> String.pad_leading(2, "0"))

          :error ->
            <<codepoint::utf8>>
        end
      end)

    "\"" <> escaped <> "\""
  end

  defp legacy_key_order do
    [
      "version",
      "project",
      "name",
      "kind",
      "app_kind",
      "workflow",
      "preset",
      "modules",
      "docs",
      "entrypoints",
      "validation",
      "commands",
      "vcs",
      "mode",
      "delivery",
      "pr_target",
      "automation",
      "posture",
      "harness",
      "codex_home",
      "tracker",
      "project_id",
      "project_slug",
      "team_key",
      "workspace_slug",
      "issue_ids",
      "query",
      "query_file",
      "active_states",
      "terminal_states",
      "polling",
      "interval_ms",
      "workspace",
      "root",
      "agent",
      "default_runner",
      "max_concurrent_agents",
      "max_concurrent_startups",
      "max_turns",
      "runners",
      "codex",
      "kind",
      "command",
      "model",
      "approval_policy",
      "thread_sandbox",
      "turn_sandbox_policy",
      "turn_timeout_ms",
      "read_timeout_ms",
      "stall_timeout_ms",
      "execution_profiles",
      "target",
      "mode",
      "capacity",
      "type",
      "issue_ids",
      "discovery",
      "networkAccess"
    ]
  end

  defp key_order_index(key_order) do
    key_order
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {key, index}, indexes -> Map.put_new(indexes, key, index) end)
  end

  defp ordered_entries(map, key_order) do
    key_order = key_order_index(key_order)

    Enum.sort_by(map, fn {key, _value} ->
      case Map.fetch(key_order, key) do
        :error -> {1, key}
        {:ok, index} -> {0, index}
      end
    end)
  end
end
