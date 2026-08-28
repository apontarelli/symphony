defmodule SymphonyElixir.HostScheduler.Policy do
  @moduledoc """
  Pure weighted-deficit scheduling state.

  Credit is added only when no eligible target has dispatchable credit. Each
  addition gives a target its configured weight and caps stored credit at
  `weight * max_credit_rounds`. Selection starts at the cursor and advances in
  stable target order after every grant.

  A continuously eligible target receives a grant within at most
  `max_credit_rounds * sum(weights)` successful grant decisions. The cap is
  what keeps credit accumulated while a target is ineligible from making that
  bound unbounded when the target becomes eligible again.
  """

  @enforce_keys [:order, :weights, :credits, :cursor, :max_credit_rounds]
  defstruct @enforce_keys

  @type target_id :: term()
  @type target :: {target_id(), pos_integer()}
  @type t :: %__MODULE__{
          order: [target_id()],
          weights: %{target_id() => pos_integer()},
          credits: %{target_id() => non_neg_integer()},
          cursor: non_neg_integer(),
          max_credit_rounds: pos_integer()
        }

  @spec new([target()], pos_integer()) :: {:ok, t()} | {:error, :invalid_policy}
  def new(targets, max_credit_rounds)
      when is_list(targets) and is_integer(max_credit_rounds) and max_credit_rounds > 0 do
    case valid_targets?(targets) do
      true ->
        order = Enum.map(targets, &elem(&1, 0))
        weights = Map.new(targets)

        {:ok,
         %__MODULE__{
           order: order,
           weights: weights,
           credits: Map.new(order, &{&1, 0}),
           cursor: 0,
           max_credit_rounds: max_credit_rounds
         }}

      false ->
        {:error, :invalid_policy}
    end
  end

  def new(_targets, _max_credit_rounds), do: {:error, :invalid_policy}

  @spec add_credit(t()) :: t()
  def add_credit(%__MODULE__{} = policy) do
    credits =
      Map.new(policy.order, fn target_id ->
        weight = Map.fetch!(policy.weights, target_id)
        current = Map.fetch!(policy.credits, target_id)
        {target_id, min(current + weight, weight * policy.max_credit_rounds)}
      end)

    %{policy | credits: credits}
  end

  @spec next(t(), MapSet.t(target_id()) | [target_id()]) ::
          {:grant, target_id(), t()} | {:idle, t()}
  def next(%__MODULE__{} = policy, eligible_targets) do
    eligible = eligible_set(eligible_targets)
    policy = if dispatchable?(policy, eligible), do: policy, else: add_credit(policy)

    case find_next(policy, eligible, 0) do
      nil ->
        {:idle, policy}

      {target_id, index} ->
        credits = Map.update!(policy.credits, target_id, &(&1 - 1))
        cursor = if policy.order == [], do: 0, else: rem(index + 1, length(policy.order))
        {:grant, target_id, %{policy | credits: credits, cursor: cursor}}
    end
  end

  defp valid_targets?(targets) do
    ids = Enum.map(targets, &target_id/1)

    Enum.all?(targets, fn
      {_target_id, weight} when is_integer(weight) and weight > 0 -> true
      _invalid -> false
    end) and length(ids) == MapSet.size(MapSet.new(ids))
  end

  defp target_id({target_id, _weight}), do: target_id
  defp target_id(_invalid), do: make_ref()

  defp eligible_set(%MapSet{} = eligible), do: eligible
  defp eligible_set(eligible) when is_list(eligible), do: MapSet.new(eligible)
  defp eligible_set(_invalid), do: MapSet.new()

  defp dispatchable?(policy, eligible) do
    Enum.any?(policy.order, fn target_id ->
      MapSet.member?(eligible, target_id) and Map.fetch!(policy.credits, target_id) > 0
    end)
  end

  defp find_next(%__MODULE__{order: []}, _eligible, _offset), do: nil

  defp find_next(%__MODULE__{order: order} = policy, eligible, offset)
       when offset < length(order) do
    index = rem(policy.cursor + offset, length(order))
    target_id = Enum.at(order, index)

    if MapSet.member?(eligible, target_id) and Map.fetch!(policy.credits, target_id) > 0,
      do: {target_id, index},
      else: find_next(policy, eligible, offset + 1)
  end

  defp find_next(%__MODULE__{}, _eligible, _offset), do: nil
end
