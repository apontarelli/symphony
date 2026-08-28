defmodule SymphonyElixir.HostScheduler.PolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HostScheduler.Policy

  test "adds deterministic weighted credit and caps accumulated credit" do
    assert {:ok, policy} = Policy.new([{"alpha", 1}, {"beta", 3}], 2)

    policy = policy |> Policy.add_credit() |> Policy.add_credit() |> Policy.add_credit()

    assert policy.order == ["alpha", "beta"]
    assert policy.credits == %{"alpha" => 2, "beta" => 6}
    assert policy.cursor == 0
  end

  test "selects from the cursor in stable order and preserves weight" do
    assert {:ok, policy} = Policy.new([{"alpha", 2}, {"beta", 1}, {"gamma", 1}], 3)

    assert {:grant, "alpha", policy} = Policy.next(policy, ["alpha", "beta", "gamma"])
    assert {:grant, "beta", policy} = Policy.next(policy, ["alpha", "beta", "gamma"])
    assert {:grant, "gamma", policy} = Policy.next(policy, ["alpha", "beta", "gamma"])
    assert {:grant, "alpha", policy} = Policy.next(policy, ["alpha", "beta", "gamma"])
    assert policy.credits == %{"alpha" => 0, "beta" => 0, "gamma" => 0}
    assert policy.cursor == 1
  end

  test "skips ineligible targets and bounds their stored-credit burst" do
    assert {:ok, policy} = Policy.new([{"alpha", 1}, {"beta", 1}], 2)

    policy =
      Enum.reduce(1..6, policy, fn _round, policy ->
        assert {:grant, "beta", policy} = Policy.next(policy, MapSet.new(["beta"]))
        policy
      end)

    assert policy.credits["alpha"] == 2

    grants =
      Enum.map_reduce(1..4, policy, fn _decision, policy ->
        assert {:grant, target_id, policy} = Policy.next(policy, ["alpha", "beta"])
        {target_id, policy}
      end)
      |> elem(0)

    assert "alpha" in Enum.take(grants, 2)
  end

  test "documented starvation bound holds for continuously eligible targets" do
    targets = [{"alpha", 3}, {"beta", 2}, {"gamma", 1}]
    max_credit_rounds = 2
    bound = max_credit_rounds * Enum.sum(Enum.map(targets, &elem(&1, 1)))
    assert {:ok, policy} = Policy.new(targets, max_credit_rounds)

    {grants, _policy} =
      Enum.map_reduce(1..(bound * 4), policy, fn _decision, policy ->
        assert {:grant, target_id, policy} = Policy.next(policy, Enum.map(targets, &elem(&1, 0)))
        {target_id, policy}
      end)

    Enum.each(Enum.map(targets, &elem(&1, 0)), fn target_id ->
      indexes =
        grants
        |> Enum.with_index()
        |> Enum.flat_map(fn {granted, index} -> if granted == target_id, do: [index], else: [] end)

      gaps = Enum.zip_with(indexes, tl(indexes), &(&2 - &1))
      assert Enum.max(gaps) <= bound
    end)
  end

  test "returns idle for empty or invalid eligibility and rejects malformed policy" do
    assert {:ok, empty} = Policy.new([], 1)
    assert {:idle, ^empty} = Policy.next(empty, :invalid)
    assert {:ok, one_target} = Policy.new([{"alpha", 1}], 1)
    assert {:idle, _credited} = Policy.next(one_target, ["missing"])

    assert {:error, :invalid_policy} = Policy.new([{"alpha", 0}], 2)
    assert {:error, :invalid_policy} = Policy.new([{"alpha", 1}, {"alpha", 2}], 2)
    assert {:error, :invalid_policy} = Policy.new([:invalid], 2)
    assert {:error, :invalid_policy} = Policy.new([], 0)
    assert {:error, :invalid_policy} = Policy.new(:invalid, 2)
  end
end
