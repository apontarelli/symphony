defmodule SymphonyElixir.IncidentLinearIssue do
  @moduledoc """
  Builds and optionally creates Linear issues from project-owned production failure signals.

  This is an explicit integration surface for project monitoring. It is not part of the
  orchestrator polling loop and it does not make production-posture decisions without opt-in.
  """

  alias SymphonyElixir.IncidentLinearIssue.Linear

  @supported_severities ["critical", "high", "medium", "low"]
  @source_payload_required_fields [
    {"github_actions", ["repository", "workflow", "run_id", "run_url"]},
    {"sentry", ["organization", "project", "issue_url", "event_id"]},
    {"posthog", ["project", "alert_name", "alert_url", "metric"]},
    {"project_webhook", ["webhook_name", "event_id", "event_url"]}
  ]
  @source_payload_required_fields_by_source Map.new(@source_payload_required_fields)
  @severity_priorities %{"critical" => 1, "high" => 2, "medium" => 3, "low" => 4}
  @allowed_target_states ["Backlog", "Todo"]
  @terminal_duplicate_state_types ["completed", "canceled"]
  @terminal_duplicate_state_names ["closed", "cancelled", "canceled", "duplicate", "done"]
  @default_labels ["incident", "production-failure"]
  @default_target_state "Backlog"
  @default_candidate_limit 50
  @max_candidate_limit 50
  @required_fields [
    "title",
    "severity",
    "affected_project",
    "signal_source",
    "failing_signal",
    "evidence_links",
    "source_payload",
    "reproduction",
    "diagnostics",
    "suggested_owner",
    "suggested_validation",
    "suggested_agent_route"
  ]
  @required_text_fields [
    "title",
    "affected_project",
    "failing_signal",
    "reproduction",
    "diagnostics",
    "suggested_owner",
    "suggested_validation",
    "suggested_agent_route"
  ]

  defmodule Dedupe do
    @moduledoc false

    defstruct [:correlation_key, :marker, :candidate_limit]

    @type t :: %__MODULE__{
            correlation_key: String.t(),
            marker: String.t(),
            candidate_limit: pos_integer()
          }
  end

  defmodule Duplicate do
    @moduledoc false

    defstruct [:id, :identifier, :title, :url, :state]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            identifier: String.t() | nil,
            title: String.t() | nil,
            url: String.t() | nil,
            state: String.t() | nil
          }
  end

  defstruct [
    :title,
    :body,
    :severity,
    :priority,
    :target_project,
    :target_team_key,
    :target_state,
    :signal_source,
    :source_id,
    :source_payload,
    :failing_signal,
    :suggested_owner,
    :suggested_validation,
    :suggested_agent_route,
    :dedupe,
    labels: [],
    evidence_links: []
  ]

  @type t :: %__MODULE__{
          title: String.t(),
          body: String.t(),
          severity: String.t(),
          priority: 1..4,
          target_project: String.t(),
          target_team_key: String.t() | nil,
          target_state: String.t(),
          signal_source: String.t(),
          source_id: String.t() | nil,
          source_payload: %{String.t() => String.t()},
          failing_signal: String.t(),
          suggested_owner: String.t(),
          suggested_validation: String.t(),
          suggested_agent_route: String.t(),
          labels: [String.t()],
          evidence_links: [String.t()],
          dedupe: Dedupe.t()
        }

  @spec supported_sources() :: [String.t()]
  def supported_sources, do: Enum.map(@source_payload_required_fields, &elem(&1, 0))

  @spec source_payload_required_fields() :: %{String.t() => [String.t()]}
  def source_payload_required_fields, do: @source_payload_required_fields_by_source

  @spec plan(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def plan(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    payload = normalize_payload(payload)

    with :ok <- require_fields(payload),
         {:ok, severity} <- normalize_severity(payload["severity"]),
         {:ok, source} <- normalize_source(payload["signal_source"]),
         {:ok, source_payload} <- normalize_source_payload(source, payload["source_payload"]),
         {:ok, evidence_links} <- normalize_evidence_links(payload["evidence_links"]),
         {:ok, source_id} <- normalize_optional_field(payload, "source_id"),
         {:ok, fingerprint} <- normalize_optional_field(payload, "fingerprint"),
         {:ok, target_team_key} <- normalize_optional_field(payload, "team_key"),
         {:ok, target_state} <- normalize_target_state(Keyword.get(opts, :target_state, @default_target_state)),
         {:ok, candidate_limit} <- normalize_candidate_limit(Keyword.get(opts, :candidate_limit, @default_candidate_limit)) do
      target_project = required_string!(payload, "affected_project")
      label_names = label_names(source, severity, opts)
      priority = priority_for(severity)
      correlation_key = correlation_key(payload, source, target_project, fingerprint, source_id)
      dedupe = dedupe(correlation_key, candidate_limit)

      plan = %__MODULE__{
        title: "[#{severity}] #{required_string!(payload, "title")}",
        body: body(payload, severity, priority, source, source_id, source_payload, evidence_links, dedupe),
        severity: severity,
        priority: priority,
        target_project: target_project,
        target_team_key: target_team_key,
        target_state: target_state,
        signal_source: source,
        source_id: source_id,
        source_payload: source_payload,
        failing_signal: required_string!(payload, "failing_signal"),
        labels: label_names,
        evidence_links: evidence_links,
        suggested_owner: required_string!(payload, "suggested_owner"),
        suggested_validation: required_string!(payload, "suggested_validation"),
        suggested_agent_route: required_string!(payload, "suggested_agent_route"),
        dedupe: dedupe
      }

      {:ok, plan}
    end
  end

  @spec find_duplicate(t(), [map()]) :: :none | {:duplicate, Duplicate.t()}
  def find_duplicate(%__MODULE__{dedupe: %Dedupe{marker: marker}}, candidate_issues)
      when is_list(candidate_issues) do
    candidate_issues
    |> Enum.find(&active_duplicate_candidate?(&1, marker))
    |> case do
      nil -> :none
      issue -> {:duplicate, duplicate(issue)}
    end
  end

  @spec format_dry_run(t()) :: String.t()
  def format_dry_run(%__MODULE__{} = plan) do
    """
    DRY RUN: no Linear issue was created
    Target project: #{plan.target_project}
    Target team: #{plan.target_team_key || "project default"}
    Target state: #{plan.target_state}
    Linear priority: #{priority_label(plan.priority)}
    Labels: #{Enum.join(plan.labels, ", ")}
    Correlation key: #{plan.dedupe.correlation_key}
    Candidate scan limit: #{plan.dedupe.candidate_limit}
    Manual inspection: review the issue body below before using --create

    --- Linear issue body ---
    #{plan.body}
    """
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  @spec create(map(), keyword()) ::
          {:ok, map()} | {:duplicate, Duplicate.t()} | {:error, term()}
  def create(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    Linear.create(payload, opts)
  end

  defp normalize_payload(payload) do
    Map.new(payload, fn {key, value} -> {to_string(key), value} end)
  end

  defp require_fields(payload) do
    missing =
      Enum.filter(@required_fields, fn field ->
        missing_field?(payload, field)
      end)

    invalid =
      Enum.filter(@required_text_fields, fn field ->
        invalid_text_field?(payload, field)
      end)

    cond do
      missing != [] -> {:error, {:missing_required_fields, missing}}
      invalid != [] -> {:error, {:invalid_required_fields, invalid}}
      true -> :ok
    end
  end

  defp missing_field?(payload, "source_payload") do
    not Map.has_key?(payload, "source_payload") or is_nil(Map.get(payload, "source_payload"))
  end

  defp missing_field?(payload, field) do
    case Map.get(payload, field) do
      value when is_binary(value) -> String.trim(value) == ""
      value when is_list(value) -> value == []
      nil -> true
      _value -> false
    end
  end

  defp invalid_text_field?(payload, field) do
    case Map.fetch(payload, field) do
      {:ok, value} when is_binary(value) -> false
      {:ok, nil} -> false
      {:ok, _value} -> true
      :error -> false
    end
  end

  defp normalize_severity(severity) when is_binary(severity) do
    severity = normalize_text(severity)

    if severity in @supported_severities do
      {:ok, severity}
    else
      {:error, {:unsupported_severity, severity, @supported_severities}}
    end
  end

  defp normalize_severity(severity), do: {:error, {:unsupported_severity, severity, @supported_severities}}

  defp normalize_source(source) when is_binary(source) do
    source = normalize_text(source)

    if source in supported_sources() do
      {:ok, source}
    else
      {:error, {:unsupported_signal_source, source, supported_sources()}}
    end
  end

  defp normalize_source(source), do: {:error, {:unsupported_signal_source, source, supported_sources()}}

  defp normalize_source_payload(source, payload) when is_map(payload) do
    payload = Map.new(payload, fn {key, value} -> {to_string(key), value} end)
    required_fields = Map.fetch!(@source_payload_required_fields_by_source, source)

    missing_fields =
      Enum.filter(required_fields, fn field ->
        case Map.fetch(payload, field) do
          :error -> true
          {:ok, value} when is_binary(value) -> String.trim(value) == ""
          {:ok, _value} -> false
        end
      end)

    invalid_fields =
      payload
      |> Enum.reject(fn {_field, value} -> is_binary(value) end)
      |> Enum.map(fn {field, _value} -> field end)
      |> Enum.sort()

    cond do
      missing_fields != [] ->
        {:error, {:missing_source_payload_fields, source, missing_fields}}

      invalid_fields != [] ->
        {:error, {:invalid_source_payload_fields, source, invalid_fields}}

      true ->
        normalized_payload =
          payload
          |> Enum.map(fn {field, value} -> {field, String.trim(value)} end)
          |> Enum.reject(fn {_field, value} -> value == "" end)
          |> Map.new()

        {:ok, normalized_payload}
    end
  end

  defp normalize_source_payload(source, _payload),
    do: {:error, {:invalid_source_payload, source, Map.fetch!(@source_payload_required_fields_by_source, source)}}

  defp normalize_target_state(target_state) when is_binary(target_state) do
    normalized = normalize_text(target_state)

    case Enum.find(@allowed_target_states, &(normalize_text(&1) == normalized)) do
      nil -> {:error, {:unsupported_target_state, target_state, @allowed_target_states}}
      target_state -> {:ok, target_state}
    end
  end

  defp normalize_target_state(target_state),
    do: {:error, {:unsupported_target_state, target_state, @allowed_target_states}}

  defp normalize_evidence_links(links) when is_list(links) do
    invalid_indices =
      links
      |> Enum.with_index()
      |> Enum.reject(fn {link, _index} -> is_binary(link) end)
      |> Enum.map(fn {_link, index} -> index end)

    if invalid_indices != [] do
      {:error, {:invalid_evidence_links, invalid_indices}}
    else
      links =
        links
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      if links == [] do
        {:error, :missing_evidence_links}
      else
        {:ok, links}
      end
    end
  end

  defp normalize_evidence_links(_links), do: {:error, :missing_evidence_links}

  defp normalize_optional_field(payload, field) do
    case Map.fetch(payload, field) do
      {:ok, value} when is_binary(value) -> {:ok, optional_string(value)}
      {:ok, nil} -> {:ok, nil}
      {:ok, _value} -> {:error, {:invalid_optional_field, field}}
      :error -> {:ok, nil}
    end
  end

  defp optional_string(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_candidate_limit(candidate_limit)
       when is_integer(candidate_limit) and candidate_limit > @max_candidate_limit,
       do: {:ok, @max_candidate_limit}

  defp normalize_candidate_limit(candidate_limit)
       when is_integer(candidate_limit) and candidate_limit > 0,
       do: {:ok, candidate_limit}

  defp normalize_candidate_limit(candidate_limit),
    do: {:error, {:invalid_candidate_limit, candidate_limit, @max_candidate_limit}}

  defp label_names(source, severity, opts) do
    base_labels =
      (Keyword.get(opts, :labels) || @default_labels)
      |> Enum.map(&normalize_label/1)
      |> Enum.reject(&(&1 == ""))

    Enum.uniq(base_labels ++ ["source:#{source}", "severity:#{severity}"])
  end

  defp priority_for(severity), do: Map.fetch!(@severity_priorities, severity)

  defp correlation_key(payload, source, target_project, fingerprint, source_id) do
    suffix = fingerprint || source_id || normalize_text(required_string!(payload, "title"))
    "symphony-incident:#{source}:#{target_project}:#{suffix}"
  end

  defp dedupe(correlation_key, candidate_limit) do
    marker_hash = correlation_key |> sha256() |> binary_part(0, 16)

    %Dedupe{
      correlation_key: correlation_key,
      marker: "<!-- symphony-incident-correlation: #{marker_hash} -->",
      candidate_limit: candidate_limit
    }
  end

  defp body(payload, severity, priority, source, source_id, source_payload, evidence_links, %Dedupe{} = dedupe) do
    """
    #{dedupe.marker}

    ## Production Failure Signal

    - Severity: #{severity}
    - Linear priority: #{priority_label(priority)}
    - Affected project: #{required_string!(payload, "affected_project")}
    - Target team: #{optional_string(payload["team_key"] || "") || "project default"}
    - Monitor source: #{source}
    - Failing signal: #{required_string!(payload, "failing_signal")}
    - Source ID: #{source_id || "not provided"}
    - Suggested owner: #{required_string!(payload, "suggested_owner")}
    - Suggested agent route: #{required_string!(payload, "suggested_agent_route")}

    ## Evidence

    #{bullet_list(evidence_links)}

    ## Source Evidence

    #{source_payload_list(source, source_payload)}

    ## Reproduction

    #{required_string!(payload, "reproduction")}

    ## Suggested Validation

    #{required_string!(payload, "suggested_validation")}

    ## Diagnostics

    #{required_string!(payload, "diagnostics")}

    ## Dedupe

    - Correlation key: `#{dedupe.correlation_key}`
    - Candidate scan limit: #{dedupe.candidate_limit} recent issues in the target project
    - Duplicate marker: `#{dedupe.marker}`

    ## Ownership Boundary

    This issue was generated from a project-specific monitoring signal.
    It is not a universal Symphony runtime assumption, and it should not trigger production-posture-changing automation without explicit project opt-in.
    Keep monitoring source configuration in the project that owns the signal; Symphony only receives this normalized payload and creates bounded tracker work.
    """
    |> String.trim()
  end

  defp bullet_list(items) do
    Enum.map_join(items, "\n", &("- " <> &1))
  end

  defp source_payload_list(source, payload) do
    required_fields = Map.fetch!(@source_payload_required_fields_by_source, source)
    required_pairs = Enum.map(required_fields, &{&1, Map.fetch!(payload, &1)})

    extra_pairs =
      payload
      |> Map.drop(required_fields)
      |> Enum.sort_by(fn {field, _value} -> field end)

    Enum.map_join(required_pairs ++ extra_pairs, "\n", fn {field, value} -> "- #{field}: #{value}" end)
  end

  defp priority_label(1), do: "P1 urgent"
  defp priority_label(2), do: "P2 high"
  defp priority_label(3), do: "P3 medium"
  defp priority_label(4), do: "P4 low"

  defp candidate_contains_marker?(candidate, marker) do
    candidate
    |> field("description")
    |> case do
      description when is_binary(description) -> String.contains?(description, marker)
      _ -> false
    end
  end

  defp active_duplicate_candidate?(candidate, marker) do
    candidate_contains_marker?(candidate, marker) and not terminal_duplicate_candidate?(candidate)
  end

  defp terminal_duplicate_candidate?(candidate) do
    state = field(candidate, "state")

    state_type(state) in @terminal_duplicate_state_types or
      normalize_text(state_name(candidate)) in @terminal_duplicate_state_names
  end

  defp state_type(%{} = state), do: normalize_text(field(state, "type"))
  defp state_type(_state), do: nil

  defp duplicate(issue) do
    %Duplicate{
      id: field(issue, "id"),
      identifier: field(issue, "identifier"),
      title: field(issue, "title"),
      url: field(issue, "url"),
      state: state_name(issue)
    }
  end

  defp state_name(issue) do
    case field(issue, "state") do
      %{} = state -> field(state, "name")
      state -> state
    end
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp required_string!(payload, field) do
    payload |> Map.fetch!(field) |> String.trim()
  end

  defp normalize_label(label) do
    label
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_text(_value), do: nil

  defp sha256(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
