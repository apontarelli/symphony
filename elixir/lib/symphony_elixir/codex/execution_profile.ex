defmodule SymphonyElixir.Codex.ExecutionProfile do
  @moduledoc """
  Resolves typed Codex execution profiles into launch settings.
  """

  alias SymphonyElixir.{Config, Shell}
  alias SymphonyElixir.Config.Schema

  @type t :: %{
          name: String.t(),
          reasoning_effort: String.t() | nil,
          budget: String.t(),
          timeout_ms: pos_integer(),
          max_retries: non_neg_integer(),
          command: [String.t()] | nil,
          model: String.t() | nil
        }

  @defaults %{
    "implementation" => %{"reasoning_effort" => nil, "budget" => "standard"},
    "source_reviewer" => %{"reasoning_effort" => "medium", "budget" => "standard"},
    "test_reviewer" => %{"reasoning_effort" => "medium", "budget" => "standard"},
    "runtime_qa" => %{"reasoning_effort" => "medium", "budget" => "standard"},
    "product_visual_review" => %{"reasoning_effort" => "high", "budget" => "standard"},
    "docs_reviewer" => %{"reasoning_effort" => "medium", "budget" => "standard"},
    "security_reviewer" => %{"reasoning_effort" => "high", "budget" => "standard"}
  }

  @valid_reasoning_efforts MapSet.new(~w(none low medium high xhigh max))

  @spec resolve(Schema.t(), String.t() | atom() | nil) :: t()
  def resolve(%Schema{} = settings, profile_ref) do
    name = normalize_profile_name(profile_ref)

    profile =
      @defaults
      |> Map.get(name, @defaults["source_reviewer"])
      |> Map.merge(Config.default_runner!(settings)["execution_profiles"] |> normalize_profiles() |> Map.get(name, %{}))

    %{
      name: name,
      reasoning_effort: normalize_reasoning_effort(Map.get(profile, "reasoning_effort")),
      budget: normalized_string(Map.get(profile, "budget")) || "standard",
      timeout_ms: positive_integer(Map.get(profile, "timeout_ms")) || default_timeout(settings),
      max_retries: non_negative_integer(Map.get(profile, "max_retries")) || settings.quality_gate.reviewer_max_retries,
      command: normalize_command(Map.get(profile, "command")),
      model: normalized_string(Map.get(profile, "model"))
    }
  end

  @spec resolve(String.t() | atom() | nil) :: t()
  def resolve(profile_ref), do: Config.settings!() |> resolve(profile_ref)

  @spec command([String.t()], t()) :: [String.t()]
  def command(base_command, profile), do: command(base_command, profile, nil)

  @spec command([String.t()], t(), String.t() | nil) :: [String.t()]
  def command(_base_command, %{command: command}, _default_model) when is_list(command), do: command

  def command(base_command, profile, default_model) when is_list(base_command) and is_map(profile) do
    model = model_for_command(base_command, Map.get(profile, :model), default_model)

    additions =
      []
      |> maybe_add_model_config(model)
      |> maybe_add_reasoning_config(Map.get(profile, :reasoning_effort))

    cond do
      additions == [] ->
        base_command

      List.last(base_command) == "app-server" ->
        {prefix, ["app-server"]} = Enum.split(base_command, -1)
        prefix ++ additions ++ ["app-server"]

      true ->
        base_command ++ additions
    end
  end

  defp model_for_command(base_command, profile_model, default_model) do
    cond do
      command_sets_model?(base_command) -> nil
      is_binary(profile_model) -> profile_model
      true -> normalized_string(default_model)
    end
  end

  defp command_sets_model?(command) when is_list(command) do
    command
    |> Enum.with_index()
    |> Enum.any?(fn {arg, index} ->
      next_arg = Enum.at(command, index + 1)

      arg in ["-m", "--model"] or
        String.starts_with?(arg, "--model=") or
        (arg in ["-c", "--config"] and is_binary(next_arg) and String.starts_with?(next_arg, "model=")) or
        String.starts_with?(arg, "--config=model=")
    end)
  end

  defp normalize_profiles(profiles) when is_map(profiles) do
    Map.new(profiles, fn {name, profile} ->
      {normalize_profile_name(name), normalize_profile(profile)}
    end)
  end

  defp normalize_profiles(_profiles), do: %{}

  defp normalize_profile(profile) when is_map(profile) do
    Map.new(profile, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_profile(_profile), do: %{}

  defp normalize_profile_name(nil), do: "implementation"

  defp normalize_profile_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> "implementation"
      normalized -> normalized
    end
  end

  defp normalize_reasoning_effort(nil), do: nil

  defp normalize_reasoning_effort(value) do
    effort =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.replace("x-high", "xhigh")

    if MapSet.member?(@valid_reasoning_efforts, effort), do: effort
  end

  defp normalize_command(nil), do: nil

  defp normalize_command(command) when is_list(command) do
    command
    |> Enum.map(&normalized_string/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      argv -> argv
    end
  end

  defp normalize_command(command) when is_binary(command) do
    case Shell.split(command) do
      {:ok, []} -> nil
      {:ok, argv} -> argv
      {:error, _reason} -> nil
    end
  end

  defp normalize_command(_command), do: nil

  defp maybe_add_model_config(configs, nil), do: configs
  defp maybe_add_model_config(configs, model), do: configs ++ ["--config", ~s(model="#{model}")]

  defp maybe_add_reasoning_config(configs, nil), do: configs

  defp maybe_add_reasoning_config(configs, effort) do
    configs ++ ["--config", "model_reasoning_effort=#{effort}"]
  end

  defp default_timeout(%Schema{quality_gate: %{reviewer_timeout_ms: timeout}}) when is_integer(timeout), do: timeout

  defp default_timeout(%Schema{} = settings) do
    case Config.default_runner!(settings)["turn_timeout_ms"] do
      timeout when is_integer(timeout) -> timeout
      _timeout -> 3_600_000
    end
  end

  defp normalized_string(nil), do: nil

  defp normalized_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      string -> string
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil
end
