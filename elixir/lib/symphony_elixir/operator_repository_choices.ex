defmodule SymphonyElixir.OperatorRepositoryChoices do
  @moduledoc false

  alias SymphonyElixir.TargetRegistry.RepositoryPolicy
  alias SymphonyElixir.Workflow.Manifest
  alias SymphonyElixir.Workflow.ModuleRegistry

  @type choice :: %{
          required(:value) => String.t(),
          required(:status) => String.t(),
          required(:reason) => String.t() | nil
        }
  @type field :: %{
          required(:cardinality) => String.t(),
          required(:choices) => [choice()],
          required(:status) => String.t(),
          required(:reason) => String.t() | nil
        }

  @spec build(nil | String.t(), keyword()) :: %{String.t() => field()}
  def build(nil, _opts), do: repository_required_catalog()

  def build(repo, opts) when is_binary(repo) and is_list(opts) do
    if String.trim(repo) == "" do
      repository_required_catalog()
    else
      build_for_repository(opts)
    end
  end

  defp build_for_repository(opts) do
    host = Keyword.get(opts, :host, %{})
    configured = Keyword.get(opts, :configured, %{})
    selections = Keyword.get(opts, :selections, %{})

    # The profile catalog is host data and stays selectable even when the
    # currently configured profile no longer resolves; module choices follow
    # the draft-selected profile so a broken selection can be repaired.
    modules =
      case resolve_policy(host, effective_configured(configured, selections)) do
        {:ok, policy} -> modules_field(policy)
        {:error, _diagnostics} -> unavailable_field("list", "repository_policy_invalid")
      end

    %{
      "repository_profile" => profile_field(host),
      "repository_policy.workflow.modules" => modules
    }
  end

  defp effective_configured(configured, selections) when is_map(configured) and is_map(selections) do
    case Map.fetch(selections, "repository_profile") do
      {:ok, nil} -> Map.delete(configured, "repository_profile")
      {:ok, profile} -> Map.put(configured, "repository_profile", profile)
      :error -> configured
    end
  end

  defp effective_configured(configured, _selections), do: configured

  defp resolve_policy(host, configured) when is_map(host) and is_map(configured) do
    case RepositoryPolicy.resolve(host, configured) do
      {:ok, policy, _sources} when is_map(policy) -> {:ok, policy}
      _ -> {:error, :invalid}
    end
  rescue
    _error -> {:error, :invalid}
  catch
    _kind, _reason -> {:error, :invalid}
  end

  defp resolve_policy(_host, _configured), do: {:error, :invalid}

  defp profile_field(host) when is_map(host) do
    profiles = Map.get(host, "repository_profiles", %{})

    if is_map(profiles) do
      choices =
        profiles
        |> Map.keys()
        |> Enum.map(&available_choice(to_string(&1)))
        |> Enum.sort_by(& &1.value)

      current_field("scalar", choices)
    else
      unavailable_field("scalar", "repository_policy_invalid")
    end
  end

  defp profile_field(_host), do: unavailable_field("scalar", "repository_policy_invalid")

  defp modules_field(policy) do
    # RepositoryPolicy.resolve drops `_field_sources` provenance; renormalize for module diagnostics.
    case Manifest.normalize_map(policy, repo_setup?: true) do
      {:ok, manifest} when is_map(manifest) ->
        configured =
          case get_in(policy, ["workflow", "modules"]) do
            modules when is_list(modules) -> Enum.filter(modules, &is_binary/1)
            _ -> []
          end

        names = Enum.uniq(configured ++ ModuleRegistry.module_names())
        choices = Enum.map(names, &module_choice(&1, manifest)) |> Enum.sort_by(& &1.value)
        current_field("list", choices)

      _unnormalized ->
        unavailable_field("list", "repository_policy_invalid")
    end
  end

  defp module_choice(name, manifest) do
    case ModuleRegistry.module_diagnostics(name, 0, manifest) do
      [] -> available_choice(name)
      _ -> invalid_choice(name, "incompatible_workflow_module")
    end
  end

  defp repository_required_catalog do
    %{
      "repository_profile" => unavailable_field("scalar", "repository_required"),
      "repository_policy.workflow.modules" => unavailable_field("list", "repository_required")
    }
  end

  defp current_field(cardinality, choices), do: field(cardinality, choices, "current", nil)
  defp unavailable_field(cardinality, reason), do: field(cardinality, [], "unavailable", reason)
  defp field(cardinality, choices, status, reason), do: %{cardinality: cardinality, choices: choices, status: status, reason: reason}
  defp available_choice(value), do: %{value: value, status: "available", reason: nil}
  defp invalid_choice(value, reason), do: %{value: value, status: "invalid", reason: reason}
end
