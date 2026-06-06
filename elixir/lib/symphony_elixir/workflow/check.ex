defmodule SymphonyElixir.Workflow.Check do
  @moduledoc false

  alias SymphonyElixir.Workflow.Manifest

  @switches [manifest: :string]

  @spec run([String.t()]) :: :ok | {:error, String.t()}
  def run(args) when is_list(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        manifest_path = opts |> Keyword.get(:manifest, Manifest.default_path()) |> Path.expand()

        case Manifest.compile(manifest_path) do
          {:ok, resolved} ->
            IO.puts(success_report(resolved))
            :ok

          {:error, reason} ->
            {:error, Manifest.format_error(reason)}
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec success_report(Manifest.resolved()) :: String.t()
  def success_report(resolved) do
    module_lines =
      Enum.map_join(resolved.modules, "\n", fn workflow_module ->
        "- #{workflow_module.id}@#{workflow_module.version} - #{workflow_module.summary}"
      end)

    """
    Workflow check OK
    manifest: #{resolved.manifest_path}
    project: #{resolved.project_name}
    preset: #{resolved.preset}
    modules:
    #{module_lines}
    policy_hash: #{resolved.policy_hash}
    compatibility: WORKFLOW.md is a legacy/runtime export path, not the default target-repo authoring contract.
    """
    |> String.trim_trailing()
  end

  @spec usage_message() :: String.t()
  def usage_message do
    "Usage: symphony workflow check [--manifest path/to/symphony.yml]"
  end
end
