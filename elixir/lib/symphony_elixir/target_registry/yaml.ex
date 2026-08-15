defmodule SymphonyElixir.TargetRegistry.Yaml do
  @moduledoc false

  defmodule Error do
    @moduledoc false

    @enforce_keys [:code, :message]
    defstruct [:code, :message, :path, :key, :document_count]

    @type code ::
            :duplicate_key
            | :non_string_key
            | :missing_document
            | :multiple_documents
            | :invalid_yaml
            | :invalid_root
            | :unsupported_scalar
    @type t :: %__MODULE__{
            code: code(),
            message: String.t(),
            path: String.t() | nil,
            key: term(),
            document_count: non_neg_integer() | nil
          }
  end

  alias __MODULE__.Error
  alias SymphonyElixir.Workflow.Renderer

  @yamerl_options [
    detailed_constr: true,
    str_node_as_binary: true,
    keep_duplicate_keys: true,
    ignore_unrecognized_tags: true
  ]
  @execution_profile_key_order [
    "model",
    "reasoning_effort",
    "budget",
    "timeout_ms",
    "max_retries",
    "command"
  ]

  @spec encode(term()) :: String.t()
  def encode(registry) do
    Renderer.to_yaml(registry, &registry_key_order/1)
  end

  @spec decode(String.t()) :: {:ok, map()} | {:error, Error.t()}
  def decode(content) when is_binary(content) do
    case parse_yaml(content) do
      {:ok, documents, merge_key_locations} ->
        decode_documents(documents, merge_key_locations)

      {:error, %Error{}} = error ->
        error
    end
  end

  defp parse_yaml(content) do
    case parse_merge_key_locations(content) do
      {:ok, merge_key_locations} ->
        documents = :yamerl_constr.string(content, @yamerl_options)
        {:ok, documents, merge_key_locations}

      {:error, :invalid_merge_tag} ->
        invalid_yaml_error()
    end
  catch
    _kind, _reason -> invalid_yaml_error()
  end

  defp parse_merge_key_locations(content) do
    owner = self()
    reference = make_ref()

    :yamerl_parser.string(content,
      token_fun: token_collector(owner, reference, {[], false})
    )

    receive do
      {^reference, {_merge_key_locations, true}} ->
        {:error, :invalid_merge_tag}

      {^reference, {merge_key_locations, false}} ->
        {:ok, merge_key_locations}
    end
  end

  defp token_collector(owner, reference, merge_state) do
    fn
      {:yamerl_stream_end, _line, _column} ->
        send(owner, {reference, merge_state})
        :ok

      token ->
        next_state = remember_merge_key_location(token, merge_state)
        {:ok, token_collector(owner, reference, next_state)}
    end
  end

  defp remember_merge_key_location(
         {:yamerl_collection_start, _line, _column, tag, _style, _kind},
         {merge_key_locations, invalid_merge_tag?}
       ) do
    {merge_key_locations, invalid_merge_tag? or explicit_merge_tag?(tag)}
  end

  defp remember_merge_key_location(
         {:yamerl_scalar, line, column, tag, _style, substyle, spelling},
         {merge_key_locations, invalid_merge_tag?}
       ) do
    cond do
      explicit_merge_tag?(tag) and spelling == ~c"<<" ->
        {[{line, column} | merge_key_locations], invalid_merge_tag?}

      explicit_merge_tag?(tag) ->
        {merge_key_locations, true}

      implicit_merge_key?(tag, substyle, spelling) ->
        {[{line, column} | merge_key_locations], invalid_merge_tag?}

      true ->
        {merge_key_locations, invalid_merge_tag?}
    end
  end

  defp remember_merge_key_location(_token, merge_state), do: merge_state

  defp explicit_merge_tag?({:yamerl_tag, _line, _column, ~c"tag:yaml.org,2002:merge"}),
    do: true

  defp explicit_merge_tag?(_tag), do: false

  defp implicit_merge_key?(
         {:yamerl_tag, _line, _column, {:non_specific, ~c"?"}},
         :plain,
         ~c"<<"
       ),
       do: true

  defp implicit_merge_key?(_tag, _substyle, _spelling), do: false

  defp decode_documents([], _merge_key_locations), do: missing_document_error()

  defp decode_documents([{:yamerl_doc, root}], merge_key_locations) do
    case build_node(root, "$", merge_key_locations) do
      {:ok, document} when is_map(document) -> {:ok, document}
      {:ok, _document} -> invalid_root_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp decode_documents(documents, _merge_key_locations) do
    document_count_error(length(documents))
  end

  defp build_node(
         {:yamerl_map, :yamerl_node_map, _tag, _location, entries},
         path,
         merge_key_locations
       ) do
    build_map(entries, path, merge_key_locations, {%{}, %{}, false}, 0)
  end

  defp build_node(
         {:yamerl_seq, :yamerl_node_seq, _tag, _location, values, _count},
         path,
         merge_key_locations
       ) do
    build_sequence(values, path, merge_key_locations, 0)
  end

  defp build_node(
         {:yamerl_null, :yamerl_node_null, _tag, _location},
         _path,
         _merge_key_locations
       ),
       do: {:ok, nil}

  defp build_node(
         {_yamerl_element, _yamerl_node, _tag, _location, value},
         path,
         _merge_key_locations
       ) do
    if supported_scalar?(value) do
      {:ok, value}
    else
      unsupported_scalar_error(path)
    end
  end

  defp supported_scalar?(value) when is_binary(value), do: String.valid?(value)

  defp supported_scalar?(value),
    do: is_integer(value) or is_float(value) or is_boolean(value)

  defp build_sequence([], _path, _merge_key_locations, _index), do: {:ok, []}

  defp build_sequence([node | rest], path, merge_key_locations, index) do
    with {:ok, value} <- build_node(node, "#{path}[#{index}]", merge_key_locations),
         {:ok, rest_values} <-
           build_sequence(rest, path, merge_key_locations, index + 1) do
      {:ok, [value | rest_values]}
    end
  end

  defp build_map([], _path, _merge_key_locations, {map, _seen, _merge_seen}, _index),
    do: {:ok, map}

  defp build_map(
         [{key_node, value_node} | rest],
         path,
         merge_key_locations,
         state,
         index
       ) do
    build_map_entry(
      merge_key_node?(key_node, merge_key_locations),
      key_node,
      value_node,
      rest,
      path,
      merge_key_locations,
      state,
      index
    )
  end

  defp build_map_entry(
         false,
         key_node,
         value_node,
         rest,
         path,
         merge_key_locations,
         {map, seen, merge_seen},
         index
       ) do
    with {:ok, key} <- build_map_key(key_node, path, index, merge_key_locations),
         :ok <- ensure_new_key(key, path, seen),
         {:ok, value} <- build_node(value_node, "#{path}.#{key}", merge_key_locations) do
      build_map(
        rest,
        path,
        merge_key_locations,
        {Map.put(map, key, value), Map.put(seen, key, true), merge_seen},
        index + 1
      )
    end
  end

  defp build_map_entry(
         true,
         _key_node,
         _value_node,
         _rest,
         path,
         _merge_key_locations,
         {_map, _seen, true},
         _index
       ),
       do: duplicate_key_error(path, "<<")

  defp build_map_entry(
         true,
         _key_node,
         value_node,
         rest,
         path,
         merge_key_locations,
         {map, seen, false},
         index
       ) do
    with {:ok, merge_maps} <- build_merge_value(value_node, path, merge_key_locations),
         {:ok, merged_map, merged_seen} <- merge_maps(merge_maps, path, map, seen) do
      build_map(
        rest,
        path,
        merge_key_locations,
        {merged_map, merged_seen, true},
        index + 1
      )
    end
  end

  defp build_map_key(key_node, path, index, merge_key_locations) do
    node_path = if scalar_node?(key_node), do: "#{path}[key:#{index}]", else: path

    case build_node(key_node, node_path, merge_key_locations) do
      {:ok, key} when is_binary(key) -> {:ok, key}
      {:ok, key} -> non_string_key_error(path, key)
      {:error, %Error{}} = error -> error
    end
  end

  defp scalar_node?({:yamerl_map, :yamerl_node_map, _tag, _location, _entries}), do: false

  defp scalar_node?({_element, _node, _tag, _location, _value}), do: true
  defp scalar_node?(_node), do: false

  defp ensure_new_key(key, path, seen) do
    if Map.has_key?(seen, key) do
      duplicate_key_error(path, key)
    else
      :ok
    end
  end

  defp build_merge_value(value_node, path, merge_key_locations) do
    with {:ok, value} <- build_node(value_node, path, merge_key_locations) do
      normalize_merge_value(value, path)
    end
  end

  defp normalize_merge_value(value, _path) when is_map(value), do: {:ok, [value]}
  defp normalize_merge_value(values, path) when is_list(values), do: normalize_merge_maps(values, path, [])
  defp normalize_merge_value(_value, path), do: invalid_merge_error(path)

  defp normalize_merge_maps([], _path, maps), do: {:ok, Enum.reverse(maps)}

  defp normalize_merge_maps([map | rest], path, maps) when is_map(map) do
    normalize_merge_maps(rest, path, [map | maps])
  end

  defp normalize_merge_maps(_values, path, _maps), do: invalid_merge_error(path)

  defp merge_maps([], _path, map, seen), do: {:ok, map, seen}

  defp merge_maps([source | rest], path, map, seen) do
    entries = Enum.sort_by(source, fn {key, _value} -> key end)

    with {:ok, merged_map, merged_seen} <- merge_map_entries(entries, path, map, seen) do
      merge_maps(rest, path, merged_map, merged_seen)
    end
  end

  defp merge_map_entries([], _path, map, seen), do: {:ok, map, seen}

  defp merge_map_entries([{key, value} | rest], path, map, seen) do
    with :ok <- ensure_new_key(key, path, seen) do
      merge_map_entries(
        rest,
        path,
        Map.put(map, key, value),
        Map.put(seen, key, true)
      )
    end
  end

  defp merge_key_node?(
         {:yamerl_str, :yamerl_node_str, _tag, location, "<<"},
         merge_key_locations
       ) do
    {Keyword.fetch!(location, :line), Keyword.fetch!(location, :column)} in merge_key_locations
  end

  defp merge_key_node?(_key_node, _merge_key_locations), do: false

  defp missing_document_error do
    {:error,
     %Error{
       code: :missing_document,
       message: "expected one YAML document, got 0",
       document_count: 0
     }}
  end

  defp document_count_error(document_count) do
    {:error,
     %Error{
       code: :multiple_documents,
       message: "expected one YAML document, got #{document_count}",
       document_count: document_count
     }}
  end

  defp duplicate_key_error(path, key) do
    key_path = "#{path}.#{key}"

    {:error,
     %Error{
       code: :duplicate_key,
       message: "duplicate YAML key at #{key_path}",
       path: key_path,
       key: key
     }}
  end

  defp non_string_key_error(path, key) do
    {:error,
     %Error{
       code: :non_string_key,
       message: "YAML map at #{path} has a non-string key",
       path: path,
       key: key
     }}
  end

  defp invalid_merge_error(path) do
    merge_path = "#{path}.<<"

    {:error,
     %Error{
       code: :invalid_yaml,
       message: "YAML merge at #{merge_path} must contain a map or list of maps",
       path: merge_path,
       key: "<<"
     }}
  end

  defp unsupported_scalar_error(path) do
    {:error,
     %Error{
       code: :unsupported_scalar,
       message: "unsupported YAML scalar at #{path}",
       path: path
     }}
  end

  defp invalid_yaml_error do
    {:error, %Error{code: :invalid_yaml, message: "invalid YAML"}}
  end

  defp invalid_root_error do
    {:error, %Error{code: :invalid_root, message: "YAML root must be a map", path: "$"}}
  end

  @registry_key_orders [
    {[], ["version", "host", "targets"]},
    {["host"], ["id", "state_root", "polling", "capacity", "scheduling", "tracker_connections", "runners"]},
    {["host", "polling"], ["interval_ms", "max_concurrent_target_polls"]},
    {["host", "capacity"], ["max_concurrent_agents", "max_concurrent_startups", "max_concurrent_reviewers"]},
    {["host", "scheduling"], ["algorithm", "max_credit_rounds"]},
    {["host", "tracker_connections"], []},
    {["host", "tracker_connections", :dynamic], ["kind", "endpoint", "api_key"]},
    {["host", "runners"], []},
    {["host", "runners", :dynamic],
     [
       "kind",
       "command",
       "model",
       "approval_policy",
       "thread_sandbox",
       "turn_sandbox_policy",
       "turn_timeout_ms",
       "read_timeout_ms",
       "stall_timeout_ms",
       "execution_profiles",
       "agent",
       "hostname",
       "port",
       "config_dir",
       "config_path",
       "config_content",
       "server_auth",
       "permissions",
       "startup_timeout_ms",
       "max_concurrent_agents",
       "max_concurrent_startups"
     ]},
    {["host", "runners", :dynamic, "turn_sandbox_policy"],
     [
       "type",
       "writableRoots",
       "readOnlyAccess",
       "networkAccess",
       "excludeTmpdirEnvVar",
       "excludeSlashTmp"
     ]},
    {["host", "runners", :dynamic, "turn_sandbox_policy", "readOnlyAccess"], ["type"]},
    {["host", "runners", :dynamic, "server_auth"], ["username", "password"]},
    {["host", "runners", :dynamic, "execution_profiles"], []},
    {["host", "runners", :dynamic, "execution_profiles", :dynamic], @execution_profile_key_order},
    {["targets"], []},
    {["targets", :dynamic],
     [
       "display_name",
       "state",
       "dispatch_mode",
       "repo",
       "worktree",
       "linear",
       "runners",
       "concurrency",
       "budgets",
       "checks",
       "external_side_effects",
       "scheduling"
     ]},
    {["targets", :dynamic, "repo"], ["path", "manifest", "expected_repository"]},
    {["targets", :dynamic, "worktree"], ["root", "strategy", "hooks"]},
    {["targets", :dynamic, "worktree", "hooks"], ["after_create", "before_run", "after_run", "before_remove", "timeout_ms"]},
    {["targets", :dynamic, "linear"], ["connection", "scope", "active_states", "terminal_states", "required_labels"]},
    {["targets", :dynamic, "linear", "scope"], ["type", "project_id", "project_slug", "team_key", "query_file", "issue_ids"]},
    {["targets", :dynamic, "runners"], ["allowed", "default", "settings"]},
    {["targets", :dynamic, "runners", "settings"], []},
    {["targets", :dynamic, "runners", "settings", :dynamic], ["model", "reasoning_effort", "max_turns", "execution_profiles"]},
    {["targets", :dynamic, "runners", "settings", :dynamic, "execution_profiles"], []},
    {[
       "targets",
       :dynamic,
       "runners",
       "settings",
       :dynamic,
       "execution_profiles",
       :dynamic
     ], @execution_profile_key_order},
    {["targets", :dynamic, "concurrency"],
     [
       "max_concurrent_agents",
       "max_concurrent_startups",
       "max_concurrent_reviewers",
       "by_linear_state"
     ]},
    {["targets", :dynamic, "concurrency", "by_linear_state"], []},
    {["targets", :dynamic, "budgets"], ["per_run", "daily", "weekly"]},
    {["targets", :dynamic, "budgets", :dynamic], ["max_total_tokens"]},
    {["targets", :dynamic, "checks"], ["pre_dispatch", "pre_handoff", "pre_publish", "pre_merge"]},
    {["targets", :dynamic, "external_side_effects"], ["tracker_write", "vcs_publish", "pull_request_write", "merge", "deployment", "production_data"]},
    {["targets", :dynamic, "scheduling"], ["weight"]}
  ]

  defp registry_key_order(path) do
    Enum.find_value(@registry_key_orders, [], fn {pattern, order} ->
      if registry_path?(pattern, path), do: order
    end)
  end

  defp registry_path?(pattern, path) when length(pattern) == length(path) do
    pattern
    |> Enum.zip(path)
    |> Enum.all?(fn
      {:dynamic, _segment} -> true
      {expected, actual} -> expected == actual
    end)
  end

  defp registry_path?(_pattern, _path), do: false
end
