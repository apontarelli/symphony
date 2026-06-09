defmodule SymphonyElixir.HandoffRoute.AutoLandPolicy do
  @moduledoc false

  alias SymphonyElixir.HandoffRoute.Evidence

  defstruct enabled?: false,
            required_checks: [],
            missing_checks: [],
            matched_force_human_review_label: nil,
            blocked_state: "Human Review",
            evidence: []

  @type t :: %__MODULE__{
          enabled?: boolean(),
          required_checks: [String.t()],
          missing_checks: [String.t()],
          matched_force_human_review_label: String.t() | nil,
          blocked_state: String.t(),
          evidence: [Evidence.t()]
        }

  @passed_statuses MapSet.new([:passed, :pass, :success, :clean, :ok])
  @default_required_checks ~w(tests quality_gates automated_review route_classification sync)
  @strict_recovery_checks ~w(
    deployment_status
    rollback_plan
    monitoring_source
    incident_issue_creation
  )
  @default_force_human_review_labels ~w(force-human-review human-review manual-review no-auto-land)
  @check_aliases %{
    "deployment" => "deployment_status",
    "deployment-status" => "deployment_status",
    "incident_intake" => "incident_issue_creation",
    "incident-intake" => "incident_issue_creation",
    "incident_issue" => "incident_issue_creation",
    "incident-issue-creation" => "incident_issue_creation",
    "rollback" => "rollback_plan",
    "rollback-plan" => "rollback_plan",
    "rollback_path" => "rollback_plan",
    "rollback-path" => "rollback_plan",
    "monitoring-source" => "monitoring_source",
    "monitoring" => "monitoring_source"
  }
  @known_keys %{
    "auto_land" => :auto_land,
    "auto_land_enabled" => :auto_land_enabled,
    "blocked_state" => :blocked_state,
    "criticality" => :criticality,
    "deployment_coupling" => :deployment_coupling,
    "dry_run" => :dry_run,
    "enabled" => :enabled,
    "failure_state" => :failure_state,
    "force_human_review_labels" => :force_human_review_labels,
    "project" => :project,
    "posture" => :posture,
    "required_checks" => :required_checks
  }

  @spec evaluate(term()) :: t()
  def evaluate(input) when is_map(input) do
    checks = fetch(input, :checks, [])
    policy = fetch(input, :policy, %{}) |> normalize_map()
    labels = fetch(input, :labels, []) |> normalize_label_list()
    auto_land = fetch(policy, :auto_land, %{}) |> normalize_map()
    required_checks = required_checks(policy, auto_land)
    missing_checks = required_checks -- passed_checks(checks)
    matched_force_label = matched_force_human_review_label(labels, auto_land)

    %__MODULE__{
      enabled?: enabled?(policy, auto_land),
      required_checks: required_checks,
      missing_checks: missing_checks,
      matched_force_human_review_label: matched_force_label,
      blocked_state: fetch(auto_land, :blocked_state, "Human Review"),
      evidence: evidence(required_checks, missing_checks, matched_force_label)
    }
  end

  def evaluate(_input), do: %__MODULE__{}

  defp evidence(required_checks, missing_checks, matched_force_label) do
    []
    |> Kernel.++(force_label_evidence(matched_force_label))
    |> Kernel.++(required_check_evidence(required_checks, missing_checks))
  end

  defp force_label_evidence(nil), do: []

  defp force_label_evidence(label) do
    [
      %Evidence{
        kind: :policy,
        status: :applied,
        summary: "Auto-land forced to human review by issue label: #{label}"
      }
    ]
  end

  defp required_check_evidence([], _missing_checks), do: []

  defp required_check_evidence(_required_checks, missing_checks) when missing_checks != [] do
    [
      %Evidence{
        kind: :auto_land,
        status: :missing,
        summary: "Missing required auto-land evidence: #{Enum.join(missing_checks, ", ")}"
      }
    ]
  end

  defp required_check_evidence(required_checks, _missing_checks) do
    [
      %Evidence{
        kind: :auto_land,
        status: :passed,
        summary: "Required auto-land evidence is present: #{Enum.join(required_checks, ", ")}"
      }
    ]
  end

  defp enabled?(policy, auto_land) do
    fetch(policy, :auto_land_enabled, false) == true or
      fetch(auto_land, :enabled, false) == true or
      (manifest_policy?(auto_land) and fetch(auto_land, :posture, "permissive") != "off")
  end

  defp required_checks(policy, auto_land) do
    if manifest_policy?(auto_land) and fetch(auto_land, :posture, "permissive") != "off" do
      policy
      |> default_required_checks(auto_land)
      |> Kernel.++(fetch(auto_land, :required_checks, []) |> normalize_check_list())
      |> Enum.uniq()
    else
      []
    end
  end

  defp default_required_checks(policy, auto_land) do
    if strict_policy?(policy, auto_land) do
      @default_required_checks ++ @strict_recovery_checks
    else
      @default_required_checks
    end
  end

  defp strict_policy?(policy, auto_land) do
    project = fetch(policy, :project, %{}) |> normalize_map()

    fetch(auto_land, :posture, nil) == "strict" or
      fetch(project, :criticality, nil) == "production" or
      fetch(project, :deployment_coupling, nil) in ["production", "production_web"]
  end

  defp manifest_policy?(auto_land) do
    Enum.any?([:posture, :dry_run, :required_checks, :blocked_state, :failure_state], &Map.has_key?(auto_land, &1))
  end

  defp matched_force_human_review_label(labels, auto_land) do
    if manifest_policy?(auto_land) do
      label_set = MapSet.new(labels)

      auto_land
      |> fetch(:force_human_review_labels, @default_force_human_review_labels)
      |> normalize_label_list()
      |> Enum.find(&MapSet.member?(label_set, &1))
    end
  end

  defp passed_checks(checks) do
    checks
    |> Enum.filter(&(Map.get(&1, :status) in @passed_statuses))
    |> Enum.flat_map(&check_names/1)
    |> Enum.uniq()
  end

  defp check_names(%{name: name}) do
    case normalize_check(name) do
      nil ->
        []

      name ->
        canonical = Map.get(@check_aliases, name, name)

        if canonical == name do
          [name]
        else
          [name, canonical]
        end
    end
  end

  defp check_names(_check), do: []

  defp normalize_check_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_check/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Map.get(@check_aliases, &1, &1))
  end

  defp normalize_check_list(_values), do: []

  defp normalize_label_list(values) do
    values
    |> normalize_string_list()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&optional_trimmed_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_values), do: []

  defp normalize_check(value) do
    optional_trimmed_string(value)
  end

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_map(_map), do: %{}

  defp fetch(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: Map.get(@known_keys, normalize_key_token(key), key)
  defp normalize_key(key), do: key

  defp normalize_key_token(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
  end

  defp optional_trimmed_string(nil), do: nil

  defp optional_trimmed_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
