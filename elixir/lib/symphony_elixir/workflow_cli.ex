defmodule SymphonyElixir.WorkflowCLI do
  @moduledoc false

  alias SymphonyElixir.Workflow.{Manifest, Renderer}

  @type result :: {:ok, String.t()} | {:error, String.t()}

  @spec evaluate([String.t()]) :: result()
  def evaluate(["init" | args]), do: init(args)
  def evaluate(["check" | args]), do: check(args)
  def evaluate(["print" | args]), do: print(args)
  def evaluate(_args), do: {:error, usage()}

  defp init(args) do
    with {:ok, opts} <- parse_options(args, repo: :string, force: :boolean, preset: :string, modules: :string),
         {:ok, repo_root} <- repo_root(opts) do
      write_manifest(repo_root, opts)
    end
  end

  defp write_manifest(repo_root, opts) do
    manifest_path = Manifest.manifest_path(repo_root)

    if File.exists?(manifest_path) and not Keyword.get(opts, :force, false) do
      {:ok, "symphony.yml already exists at #{manifest_path}; left unchanged. Use --force to replace it."}
    else
      replace_manifest(repo_root, opts, manifest_path)
    end
  end

  defp replace_manifest(repo_root, opts, manifest_path) do
    manifest = Manifest.default(repo_root, opts)
    action = if File.exists?(manifest_path), do: "Replaced", else: "Created"

    case File.write(manifest_path, Renderer.to_yaml(manifest)) do
      :ok -> {:ok, "#{action} symphony.yml at #{manifest_path}."}
      {:error, reason} -> {:error, "Failed to write symphony.yml at #{manifest_path}: #{inspect(reason)}"}
    end
  end

  defp check(args) do
    with {:ok, opts} <- parse_options(args, repo: :string),
         {:ok, repo_root} <- repo_root(opts),
         {:ok, manifest} <- read_manifest(repo_root) do
      report = Manifest.validate(repo_root, manifest)

      if report.errors == [] do
        {:ok, Renderer.check_success(repo_root, manifest, report)}
      else
        {:error, Renderer.check_failure(report)}
      end
    end
  end

  defp print(args) do
    with {:ok, opts} <- parse_options(args, repo: :string, compiled: :boolean),
         {:ok, repo_root} <- repo_root(opts),
         {:ok, manifest} <- read_manifest(repo_root) do
      report = Manifest.validate(repo_root, manifest)

      if report.errors == [] do
        {:ok, Renderer.print(repo_root, manifest, report, Keyword.get(opts, :compiled, false))}
      else
        {:error, Renderer.check_failure(report)}
      end
    end
  end

  defp parse_options(args, switches) do
    case OptionParser.parse(args, strict: switches) do
      {opts, [], []} -> {:ok, opts}
      {_opts, _rest, _invalid} -> {:error, usage()}
    end
  end

  defp repo_root(opts) do
    repo_root =
      opts
      |> Keyword.get(:repo, ".")
      |> Path.expand()

    if File.dir?(repo_root) do
      {:ok, repo_root}
    else
      {:error, "Repo root not found: #{repo_root}"}
    end
  end

  defp read_manifest(repo_root) do
    case Manifest.read(repo_root) do
      {:ok, manifest} ->
        {:ok, manifest}

      {:error, {:missing_manifest_file, path, _reason}} ->
        {:error, "symphony.yml not found at #{path}. Run `symphony workflow init --repo #{repo_root}` to create it."}

      {:error, {:manifest_parse_error, reason}} ->
        {:error, "Failed to parse symphony.yml at #{Manifest.manifest_path(repo_root)}: #{inspect(reason)}. Fix the YAML or rerun `symphony workflow init --force`."}

      {:error, {:invalid_manifest, diagnostics}} ->
        {:error, Renderer.check_failure(Manifest.validation_report_from_diagnostics(diagnostics))}
    end
  end

  defp usage do
    """
    Usage:
      symphony workflow init [--repo <path>] [--preset <name>] [--modules <a,b>] [--force]
      symphony workflow check [--repo <path>]
      symphony workflow print [--repo <path>] [--compiled]
    """
    |> String.trim()
  end
end
