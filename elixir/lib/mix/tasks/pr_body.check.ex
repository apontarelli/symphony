defmodule Mix.Tasks.PrBody.Check do
  use Mix.Task

  alias SymphonyElixir.PrBody

  @shortdoc "Validate PR body format against the repository PR template"

  @moduledoc """
  Validates a PR description markdown file against the structure and expectations
  implied by the repository pull request template.

  Usage:

      mix pr_body.check --file /path/to/pr_body.md
  """

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [file: :string, help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        opts
        |> required_opt(:file)
        |> validate_file!()
    end
  end

  defp required_opt(opts, key) do
    case opts[key] do
      nil -> Mix.raise("Missing required option --#{key}")
      value -> value
    end
  end

  defp validate_file!(file_path) do
    case PrBody.validate_file(file_path) do
      :ok ->
        Mix.shell().info("PR body format OK")

      {:error, message} ->
        print_invalid_body_errors(message)
        Mix.raise("PR body format invalid. #{message}")
    end
  end

  defp print_invalid_body_errors(message) do
    message
    |> String.split("\n", trim: true)
    |> Enum.each(&Mix.shell().error("ERROR: #{&1}"))
  end
end
