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
      "harness.codex_home: #{harness_summary(manifest)}",
      "bindings.local_file: #{bindings_summary(repo_root, manifest)}"
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
  def to_yaml(value), do: render_yaml(value, 0) <> "\n"

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

  defp harness_summary(manifest) do
    case get_in(manifest, ["harness", "codex_home"]) do
      nil -> "managed default"
      path -> path
    end
  end

  defp bindings_summary(repo_root, manifest) do
    local_file = get_in(manifest, ["bindings", "local_file"]) || ".symphony.local.yml"

    if File.regular?(Path.join(repo_root, local_file)) do
      "#{local_file} present"
    else
      "#{local_file} optional"
    end
  end

  defp compiled_workflow(manifest) do
    compiled = Manifest.compile(manifest)

    "---\n" <> to_yaml(compiled.config) <> "---\n\n" <> compiled.prompt
  end

  defp format_error(%{path: path, message: message, remediation: remediation}) do
    "- #{path}: #{message}. #{remediation}"
  end

  defp render_yaml(value, indent) when is_map(value) do
    value
    |> ordered_entries()
    |> Enum.map_join("\n", fn {key, nested} ->
      spaces = String.duplicate(" ", indent)

      if scalar?(nested) do
        "#{spaces}#{key}: #{render_scalar(nested)}"
      else
        "#{spaces}#{key}:\n#{render_yaml(nested, indent + 2)}"
      end
    end)
  end

  defp render_yaml([], indent), do: String.duplicate(" ", indent) <> "[]"

  defp render_yaml(values, indent) when is_list(values) do
    Enum.map_join(values, "\n", fn value ->
      spaces = String.duplicate(" ", indent)

      cond do
        scalar?(value) ->
          "#{spaces}- #{render_scalar(value)}"

        is_map(value) ->
          [first | rest] = String.split(render_yaml(value, indent + 2), "\n")
          ([spaces <> "- " <> String.trim_leading(first)] ++ rest) |> Enum.join("\n")

        true ->
          "#{spaces}- #{render_scalar(to_string(value))}"
      end
    end)
  end

  defp ordered_entries(map) do
    order = [
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
      "bindings",
      "local_file",
      "require_local",
      "tracker",
      "active_states",
      "terminal_states",
      "polling",
      "interval_ms",
      "workspace",
      "root",
      "agent",
      "max_concurrent_agents",
      "max_turns",
      "codex",
      "command",
      "approval_policy",
      "thread_sandbox",
      "turn_sandbox_policy",
      "type",
      "networkAccess"
    ]

    Enum.sort_by(map, fn {key, _value} ->
      case Enum.find_index(order, &(&1 == key)) do
        nil -> {1, key}
        index -> {0, index}
      end
    end)
  end

  defp scalar?(value), do: is_nil(value) or is_binary(value) or is_integer(value) or is_boolean(value) or value == []

  defp render_scalar(nil), do: "null"
  defp render_scalar(true), do: "true"
  defp render_scalar(false), do: "false"
  defp render_scalar([]), do: "[]"
  defp render_scalar(value) when is_integer(value), do: Integer.to_string(value)

  defp render_scalar(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end
end
