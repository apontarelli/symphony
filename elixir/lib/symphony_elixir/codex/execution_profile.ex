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

  @type profile_ref :: String.t() | atom() | nil
  @type resolution_error :: :invalid_fallbacks | :invalid_profile | :invalid_runner
  @type resolution_result :: {:ok, t()} | {:error, resolution_error()}

  @defaults %{
    "implementation" => %{"reasoning_effort" => nil, "budget" => "standard"},
    "landing" => %{"reasoning_effort" => nil, "budget" => "standard"},
    "source_reviewer" => %{"reasoning_effort" => "medium", "budget" => "standard"},
    "test_reviewer" => %{"reasoning_effort" => "medium", "budget" => "standard"},
    "runtime_qa" => %{"reasoning_effort" => "medium", "budget" => "standard"},
    "product_visual_review" => %{"reasoning_effort" => "high", "budget" => "standard"},
    "docs_reviewer" => %{"reasoning_effort" => "medium", "budget" => "standard"},
    "security_reviewer" => %{"reasoning_effort" => "high", "budget" => "standard"}
  }

  @valid_reasoning_efforts MapSet.new(~w(none low medium high xhigh max))

  @spec resolve(Schema.t(), profile_ref()) :: t()
  def resolve(%Schema{} = settings, profile_ref) do
    resolve(settings, Config.default_runner!(settings), profile_ref)
  end

  @spec resolve(Schema.t(), map(), profile_ref()) :: t()
  def resolve(%Schema{} = settings, runner, profile_ref) when is_map(runner) do
    name = normalize_legacy_profile_ref(profile_ref)
    {projected_runner, legacy_command} = project_legacy_runner(runner, name)

    case resolve_pinned(
           projected_runner,
           name,
           default_timeout(settings),
           settings.quality_gate.reviewer_max_retries
         ) do
      {:ok, profile} -> %{profile | command: legacy_command}
    end
  end

  @doc """
  Resolves a profile from an explicit runner and explicit fallback limits.

  This function does not read runtime configuration. Invalid untrusted input
  returns a fixed atom reason and never includes runner data.
  """
  @spec resolve_pinned(map(), profile_ref(), pos_integer(), non_neg_integer()) ::
          resolution_result()
  def resolve_pinned(runner, profile_ref, fallback_timeout_ms, fallback_max_retries)
      when is_map(runner) and not is_struct(runner) and is_integer(fallback_timeout_ms) and
             fallback_timeout_ms > 0 and is_integer(fallback_max_retries) and fallback_max_retries >= 0 do
    with :ok <- validate_runner_data(runner),
         {:ok, name} <- profile_name(profile_ref),
         {:ok, profile_override} <- strict_profile_override(runner, name) do
      profile =
        @defaults
        |> Map.get(name, @defaults["source_reviewer"])
        |> Map.merge(profile_override)

      {:ok,
       %{
         name: name,
         reasoning_effort: normalize_reasoning_effort(Map.get(profile, "reasoning_effort")),
         budget: normalized_string(Map.get(profile, "budget")) || "standard",
         timeout_ms: positive_integer(Map.get(profile, "timeout_ms")) || fallback_timeout_ms,
         max_retries: non_negative_integer(Map.get(profile, "max_retries")) || fallback_max_retries,
         command: normalize_command(Map.get(profile, "command")),
         model: normalized_string(Map.get(profile, "model"))
       }}
    end
  end

  def resolve_pinned(runner, _profile_ref, _fallback_timeout_ms, _fallback_max_retries)
      when not is_map(runner) or is_struct(runner),
      do: {:error, :invalid_runner}

  def resolve_pinned(_runner, _profile_ref, _fallback_timeout_ms, _fallback_max_retries),
    do: {:error, :invalid_fallbacks}

  defp strict_profile_override(runner, name) do
    case Map.fetch(runner, "execution_profiles") do
      :error ->
        {:ok, %{}}

      {:ok, profiles} ->
        case Map.fetch(profiles, name) do
          :error -> {:ok, %{}}
          {:ok, profile} when is_map(profile) and not is_struct(profile) -> {:ok, profile}
          {:ok, _profile} -> {:error, :invalid_runner}
        end
    end
  end

  defp validate_runner_data(runner) do
    if json_safe?(runner) and valid_profiles_container?(runner),
      do: :ok,
      else: {:error, :invalid_runner}
  end

  defp profile_name(profile_ref)
       when is_binary(profile_ref) or is_atom(profile_ref) or is_nil(profile_ref) do
    case normalize_profile_name(profile_ref) do
      name when is_binary(name) -> {:ok, name}
      nil -> {:error, :invalid_profile}
    end
  end

  defp profile_name(_profile_ref), do: {:error, :invalid_profile}

  @spec resolve(profile_ref()) :: t()
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

  defp project_legacy_runner(runner, name) do
    profile =
      runner
      |> Map.get("execution_profiles")
      |> normalize_legacy_profiles()
      |> Map.get(name, %{})
      |> project_legacy_profile()

    projected_command = Map.get(profile, "command")
    legacy_command = normalize_legacy_command(projected_command)
    strict_profile = if json_safe?(projected_command), do: profile, else: Map.delete(profile, "command")

    {%{"execution_profiles" => %{name => strict_profile}}, legacy_command}
  end

  defp normalize_legacy_profiles(profiles) when is_map(profiles) do
    Map.new(profiles, fn {raw_name, profile} ->
      {normalize_legacy_profile_ref(raw_name), normalize_legacy_profile_fields(profile)}
    end)
  end

  defp normalize_legacy_profiles(_profiles), do: %{}

  defp normalize_legacy_profile_fields(profile) when is_map(profile) do
    Map.new(profile, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_legacy_profile_fields(_profile), do: %{}

  defp project_legacy_profile(profile) do
    Enum.reduce(profile, %{}, fn {key, value}, projected ->
      case project_legacy_profile_value(key, value) do
        {:ok, projected_value} -> Map.put(projected, key, projected_value)
        :ignore -> projected
      end
    end)
  end

  defp project_legacy_profile_value("timeout_ms", timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: {:ok, timeout_ms}

  defp project_legacy_profile_value("max_retries", max_retries)
       when is_integer(max_retries) and max_retries >= 0,
       do: {:ok, max_retries}

  defp project_legacy_profile_value(key, _value) when key in ["timeout_ms", "max_retries"],
    do: :ignore

  defp project_legacy_profile_value("command", command) when is_list(command),
    do: {:ok, Enum.map(command, &legacy_normalized_string/1)}

  defp project_legacy_profile_value("command", command)
       when is_nil(command) or is_binary(command),
       do: {:ok, command}

  defp project_legacy_profile_value("command", _command), do: :ignore

  defp project_legacy_profile_value(key, value)
       when key in ["reasoning_effort", "budget", "model"],
       do: {:ok, legacy_normalized_string(value)}

  defp project_legacy_profile_value(_key, _value), do: :ignore

  defp normalize_legacy_profile_ref(nil), do: "implementation"

  defp normalize_legacy_profile_ref(profile_ref) do
    profile_ref
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> "implementation"
      normalized -> normalized
    end
  end

  defp normalize_legacy_command(nil), do: nil

  defp normalize_legacy_command(command) when is_list(command) do
    case normalize_legacy_command_parts(command, []) do
      [] -> nil
      argv -> Enum.reverse(argv)
    end
  end

  defp normalize_legacy_command(command) when is_binary(command) do
    case Shell.split(command) do
      {:ok, []} -> nil
      {:ok, argv} -> argv
      {:error, _reason} -> nil
    end
  end

  defp normalize_legacy_command_parts([], argv), do: argv

  defp normalize_legacy_command_parts([part | rest], argv) do
    case legacy_normalized_string(part) do
      nil -> normalize_legacy_command_parts(rest, argv)
      normalized -> normalize_legacy_command_parts(rest, [normalized | argv])
    end
  end

  defp legacy_normalized_string(nil), do: nil

  defp legacy_normalized_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      string -> string
    end
  end

  defp normalize_profile_name(nil), do: "implementation"

  defp normalize_profile_name(name) when is_binary(name) do
    if String.valid?(name) do
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")
      |> case do
        "" -> "implementation"
        normalized -> normalized
      end
    end
  end

  defp normalize_profile_name(name) when is_atom(name),
    do: name |> to_string() |> normalize_profile_name()

  defp normalize_reasoning_effort(nil), do: nil

  defp normalize_reasoning_effort(value) do
    case normalized_string(value) do
      nil ->
        nil

      normalized ->
        effort =
          normalized
          |> String.downcase()
          |> String.replace("x-high", "xhigh")

        if MapSet.member?(@valid_reasoning_efforts, effort), do: effort
    end
  end

  defp normalize_command(nil), do: nil

  defp normalize_command(command) when is_list(command) do
    case normalize_command_parts(command, []) do
      [] -> nil
      argv -> Enum.reverse(argv)
    end
  end

  defp normalize_command(command) when is_binary(command) do
    if String.valid?(command) do
      case Shell.split(command) do
        {:ok, []} -> nil
        {:ok, argv} -> argv
        {:error, _reason} -> nil
      end
    end
  end

  defp normalize_command(_command), do: nil

  defp normalize_command_parts([], argv), do: argv

  defp normalize_command_parts([part | rest], argv) do
    case normalized_string(part) do
      nil -> normalize_command_parts(rest, argv)
      normalized -> normalize_command_parts(rest, [normalized | argv])
    end
  end

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

  defp normalized_string(value) when is_binary(value) do
    if String.valid?(value) do
      value
      |> String.trim()
      |> case do
        "" -> nil
        string -> string
      end
    end
  end

  defp normalized_string(value) when is_atom(value) or is_integer(value) or is_float(value),
    do: value |> to_string() |> normalized_string()

  defp normalized_string(_value), do: nil

  defp json_safe?(value) when is_struct(value), do: false

  defp json_safe?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and String.valid?(key) and json_safe?(nested)
    end)
  end

  defp json_safe?([]), do: true
  defp json_safe?([_value | _rest] = values), do: json_safe_list?(values)
  defp json_safe?(value) when is_binary(value), do: String.valid?(value)
  defp json_safe?(value) when is_float(value), do: finite_float?(value)
  defp json_safe?(value) when is_integer(value) or is_boolean(value) or is_nil(value), do: true
  defp json_safe?(_value), do: false

  defp json_safe_list?([]), do: true
  defp json_safe_list?([value | rest]), do: json_safe?(value) and json_safe_list?(rest)
  defp json_safe_list?(_improper), do: false

  defp finite_float?(value) do
    <<_sign::1, exponent::11, _fraction::52>> = <<value::float-64>>
    exponent != 0x7FF
  end

  defp valid_profiles_container?(runner) do
    case Map.fetch(runner, "execution_profiles") do
      :error -> true
      {:ok, profiles} -> is_map(profiles) and not is_struct(profiles)
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil
end
