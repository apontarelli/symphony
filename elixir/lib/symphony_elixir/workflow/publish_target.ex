defmodule SymphonyElixir.Workflow.PublishTarget do
  @moduledoc false

  @type diagnostic :: %{
          required(:path) => String.t(),
          required(:message) => String.t(),
          optional(:remediation) => String.t()
        }

  @spec build(String.t() | nil, String.t() | nil) :: map() | nil
  def build(repository, pr_target) when is_binary(repository) and is_binary(pr_target) do
    case github_repository_path(repository) do
      {:ok, github_repository} ->
        %{
          "repository" => repository,
          "pr_target" => pr_target,
          "github_repository" => github_repository,
          "display" => "#{github_repository}:#{pr_target}"
        }

      :error ->
        nil
    end
  end

  def build(_repository, _pr_target), do: nil

  @spec diagnostics(map()) :: [diagnostic()]
  def diagnostics(manifest) when is_map(manifest) do
    []
    |> validate_repository(manifest)
    |> validate_pr_target(manifest)
    |> Enum.reverse()
  end

  @spec config(map()) :: map()
  def config(manifest) when is_map(manifest) do
    case build(get_in(manifest, ["project", "repository"]), get_in(manifest, ["delivery", "pr_target"])) do
      nil -> %{}
      target -> %{"publish_target" => target}
    end
  end

  @spec ambiguous_pr_target?(term()) :: boolean()
  def ambiguous_pr_target?(value) when is_binary(value) do
    target = String.trim(value)

    target == "" or Regex.match?(~r/\s/, target) or String.starts_with?(target, "origin/") or
      String.starts_with?(target, "refs/") or target in ["HEAD", "@", "-"]
  end

  def ambiguous_pr_target?(_value), do: true

  defp validate_repository(errors, manifest) do
    case get_in(manifest, ["project", "repository"]) do
      repository when is_binary(repository) ->
        case github_repository_path(repository) do
          {:ok, _path} ->
            errors

          :error ->
            [
              %{
                path: "project.repository",
                message: "must be a GitHub repository URL for publish handoff",
                remediation: "Set `project.repository` to a GitHub HTTPS or SSH URL."
              }
              | errors
            ]
        end

      _repository ->
        [
          %{
            path: "project.repository",
            message: "is required for publish handoff",
            remediation: "Set `project.repository` to the GitHub repository Symphony should publish to."
          }
          | errors
        ]
    end
  end

  defp validate_pr_target(errors, manifest) do
    pr_target = get_in(manifest, ["delivery", "pr_target"])

    cond do
      not explicit_pr_target_source?(manifest) ->
        [
          %{
            path: "delivery.pr_target",
            message: "is required for publish handoff",
            remediation: "Set `delivery.pr_target` to the PR base branch, for example `main`."
          }
          | errors
        ]

      ambiguous_pr_target?(pr_target) ->
        [
          %{
            path: "delivery.pr_target",
            message: "must be an unambiguous branch name for publish handoff",
            remediation: "Use a branch name such as `main`, not `#{pr_target}`."
          }
          | errors
        ]

      true ->
        errors
    end
  end

  defp explicit_pr_target_source?(manifest) do
    get_in(manifest, ["_field_sources", "delivery_pr_target_explicit"]) == true
  end

  defp github_repository_path(repository) when is_binary(repository) do
    repository
    |> String.trim()
    |> github_path_from_repository()
    |> normalize_github_repository_path()
  end

  defp github_path_from_repository("https://github.com/" <> path), do: path
  defp github_path_from_repository("git@github.com:" <> path), do: path
  defp github_path_from_repository("ssh://git@github.com/" <> path), do: path
  defp github_path_from_repository("github.com/" <> path), do: path
  defp github_path_from_repository(_repository), do: nil

  defp normalize_github_repository_path(nil), do: :error

  defp normalize_github_repository_path(path) do
    normalized =
      path
      |> String.trim()
      |> String.trim_trailing("/")
      |> String.replace_suffix(".git", "")

    case String.split(normalized, "/", trim: true) do
      [owner, repo] ->
        if valid_github_owner?(owner) and valid_github_repo?(repo) do
          {:ok, owner <> "/" <> repo}
        else
          :error
        end

      _segments ->
        :error
    end
  end

  defp valid_github_owner?(owner), do: String.match?(owner, ~r/\A[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\z/)

  defp valid_github_repo?(repo) do
    String.match?(repo, ~r/\A[A-Za-z0-9_.-]+\z/) and repo not in [".", ".."]
  end
end
