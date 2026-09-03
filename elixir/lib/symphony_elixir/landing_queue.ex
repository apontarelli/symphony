defmodule SymphonyElixir.LandingQueue do
  @moduledoc """
  Builds one deterministic, target-scoped landing plan.

  Landing is serialized per target. File overlap remains part of the decision
  evidence so the selected order is explainable, while serialization also
  protects changes whose semantic conflicts are not visible from file paths.
  """

  @starvation_interval_ms 15 * 60 * 1_000
  @max_starvation_promotions 4

  defmodule Entry do
    @moduledoc false

    @enforce_keys [:issue_id, :identifier, :enqueued_at, :revalidation]
    defstruct [
      :issue_id,
      :identifier,
      :enqueued_at,
      :priority,
      :admitted_run_id,
      :pr_url,
      :repository,
      :base_branch,
      :branch,
      dependencies: [],
      changed_files: [],
      revalidation: %{}
    ]

    @type t :: %__MODULE__{
            issue_id: String.t(),
            identifier: String.t(),
            enqueued_at: DateTime.t(),
            priority: integer() | nil,
            admitted_run_id: String.t() | nil,
            pr_url: String.t() | nil,
            repository: String.t() | nil,
            base_branch: String.t() | nil,
            branch: String.t() | nil,
            dependencies: [map()],
            changed_files: [String.t()],
            revalidation: map()
          }
  end

  defmodule Plan do
    @moduledoc false

    @enforce_keys [:entries, :selected, :starvation]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            entries: [map()],
            selected: map() | nil,
            starvation: map()
          }
  end

  @type revalidation_status :: :ready | :refresh_required | :blocked | :failed

  @spec starvation_policy() :: %{
          interval_ms: pos_integer(),
          max_promotions: pos_integer(),
          max_promotion_wait_ms: pos_integer()
        }
  def starvation_policy do
    %{
      interval_ms: @starvation_interval_ms,
      max_promotions: @max_starvation_promotions,
      max_promotion_wait_ms: @starvation_interval_ms * @max_starvation_promotions
    }
  end

  @spec plan([Entry.t()], [map()], keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def plan(entries, running_landings \\ [], opts \\ []) do
    if is_list(entries) and is_list(running_landings) and is_list(opts) do
      build_plan(entries, running_landings, opts)
    else
      {:error, :invalid_landing_queue}
    end
  end

  defp build_plan(entries, running_landings, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    terminal_states = normalize_terminal_states(Keyword.get(opts, :terminal_states, []))

    with :ok <- validate_now(now),
         :ok <- validate_entries(entries),
         :ok <- validate_unique_issue_ids(entries) do
      conflicts = conflict_index(entries)

      planned_entries =
        entries
        |> Enum.map(&plan_entry(&1, conflicts, terminal_states, now))
        |> Enum.sort_by(& &1.order_key)
        |> number_eligible_entries()

      selected = select_entry(planned_entries, running_landings)

      {:ok,
       %Plan{
         entries: apply_slot_status(planned_entries, selected, running_landings),
         selected: selected,
         starvation: starvation_policy()
       }}
    end
  end

  defp validate_now(%DateTime{}), do: :ok
  defp validate_now(_now), do: {:error, :invalid_landing_queue_clock}

  defp validate_entries(entries) do
    if Enum.all?(entries, &valid_entry?/1), do: :ok, else: {:error, :invalid_landing_queue_entry}
  end

  defp valid_entry?(%Entry{} = entry) do
    present?(entry.issue_id) and present?(entry.identifier) and
      match?(%DateTime{}, entry.enqueued_at) and valid_dependencies?(entry.dependencies) and
      valid_changed_files?(entry.changed_files) and valid_revalidation?(entry.revalidation)
  end

  defp valid_entry?(_entry), do: false

  defp valid_dependencies?(dependencies) when is_list(dependencies) do
    Enum.all?(dependencies, fn
      dependency when is_map(dependency) -> present?(field(dependency, :id))
      _invalid -> false
    end)
  end

  defp valid_dependencies?(_dependencies), do: false

  defp valid_changed_files?(changed_files) when is_list(changed_files) do
    Enum.all?(changed_files, &present?/1) and length(changed_files) == length(Enum.uniq(changed_files))
  end

  defp valid_changed_files?(_changed_files), do: false

  defp valid_revalidation?(revalidation) when is_map(revalidation) do
    field(revalidation, :status) in [:ready, :refresh_required, :blocked, :failed]
  end

  defp valid_revalidation?(_revalidation), do: false

  defp validate_unique_issue_ids(entries) do
    issue_ids = Enum.map(entries, & &1.issue_id)
    if length(issue_ids) == length(Enum.uniq(issue_ids)), do: :ok, else: {:error, :duplicate_landing_queue_issue}
  end

  defp plan_entry(entry, conflicts, terminal_states, now) do
    dependency_blockers = dependency_blockers(entry.dependencies, terminal_states)
    revalidation_status = field(entry.revalidation, :status)
    blocked_reasons = blocked_reasons(dependency_blockers, revalidation_status)
    wait_ms = max(DateTime.diff(now, entry.enqueued_at, :millisecond), 0)
    promotions = min(div(wait_ms, @starvation_interval_ms), @max_starvation_promotions)
    base_priority = priority_rank(entry.priority)
    effective_priority = max(base_priority - promotions, 1)
    freshness_rank = freshness_rank(revalidation_status)

    %{
      entry: entry,
      issue_id: entry.issue_id,
      identifier: entry.identifier,
      status: if(blocked_reasons == [], do: :eligible, else: :blocked),
      blocked_reasons: blocked_reasons,
      dependency_blockers: dependency_blockers,
      conflicts: Map.get(conflicts, entry.issue_id, []),
      wait_ms: wait_ms,
      starvation_promotions: promotions,
      base_priority: base_priority,
      effective_priority: effective_priority,
      freshness: revalidation_status,
      order_key: {
        effective_priority,
        freshness_rank,
        DateTime.to_unix(entry.enqueued_at, :microsecond),
        entry.identifier,
        entry.issue_id
      }
    }
  end

  defp blocked_reasons([], status) when status in [:ready, :refresh_required], do: []
  defp blocked_reasons([], :blocked), do: [:revalidation_blocked]
  defp blocked_reasons([], :failed), do: [:revalidation_failed]
  defp blocked_reasons(_dependency_blockers, _status), do: [:dependency_not_landed]

  defp freshness_rank(:ready), do: 0
  defp freshness_rank(:refresh_required), do: 1
  defp freshness_rank(_blocked), do: 2

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp dependency_blockers(dependencies, terminal_states) do
    Enum.filter(dependencies, fn dependency ->
      case normalize_state(field(dependency, :state)) do
        nil -> true
        state -> not Enum.member?(terminal_states, state)
      end
    end)
  end

  defp normalize_terminal_states(states) when is_list(states) do
    states
    |> Enum.map(&normalize_state/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_terminal_states(_states), do: []

  defp conflict_index(entries) do
    file_sets = Map.new(entries, &{&1.issue_id, MapSet.new(&1.changed_files)})

    Map.new(entries, fn entry ->
      conflicts =
        entries
        |> Enum.reject(&(&1.issue_id == entry.issue_id))
        |> Enum.map(&conflict_evidence(entry, &1, file_sets))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&{&1.identifier, &1.issue_id})

      {entry.issue_id, conflicts}
    end)
  end

  defp conflict_evidence(entry, other, file_sets) do
    overlap =
      file_sets
      |> Map.fetch!(entry.issue_id)
      |> MapSet.intersection(Map.fetch!(file_sets, other.issue_id))
      |> Enum.sort()

    if overlap == [] do
      nil
    else
      %{issue_id: other.issue_id, identifier: other.identifier, overlapping_files: overlap}
    end
  end

  defp number_eligible_entries(entries) do
    {entries, _position} =
      Enum.map_reduce(entries, 1, fn
        %{status: :eligible} = entry, position -> {Map.put(entry, :position, position), position + 1}
        entry, position -> {Map.put(entry, :position, nil), position}
      end)

    entries
  end

  defp select_entry(_entries, [_running | _rest]), do: nil
  defp select_entry(entries, []), do: Enum.find(entries, &(&1.status == :eligible))

  defp apply_slot_status(entries, nil, [_running | _rest]) do
    Enum.map(entries, fn
      %{status: :eligible} = entry -> %{entry | status: :waiting, blocked_reasons: [:landing_slot_occupied]}
      entry -> entry
    end)
  end

  defp apply_slot_status(entries, nil, []), do: entries

  defp apply_slot_status(entries, %{issue_id: selected_issue_id}, []) do
    Enum.map(entries, fn
      %{issue_id: ^selected_issue_id} = entry -> %{entry | status: :selected}
      %{status: :eligible} = entry -> %{entry | status: :waiting}
      entry -> entry
    end)
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_state(_state), do: nil

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
