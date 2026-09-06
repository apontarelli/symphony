defmodule SymphonyElixir.OperatorRepositoryBrowser do
  @moduledoc false

  alias SymphonyElixir.{DirectoryEntries, PathSafety}

  @default_max_depth 3
  @default_max_results 100
  @default_max_entries 10_000
  @default_timeout_ms 5_000

  @excluded_names MapSet.new([
                    ".git",
                    ".hg",
                    ".jj",
                    ".svn",
                    "_build",
                    "__pycache__",
                    ".cache",
                    ".elixir_ls",
                    ".mix",
                    ".symphony",
                    "cache",
                    "deps",
                    "node_modules",
                    "target",
                    "vendor"
                  ])

  @type candidate :: %{path: Path.t(), kind: String.t()}
  @type error :: %{path: Path.t() | nil, reason: atom()}
  @type result :: %{
          status: String.t(),
          candidates: [candidate()],
          errors: [error()],
          visited: non_neg_integer()
        }

  @spec run(map(), map(), (map() -> :ok | :cancel)) :: result()
  def run(%{"action" => action} = request, context, emit) do
    dispatch(action, Map.get(request, "path"), new_state(context, emit))
  end

  defp new_state(context, emit) do
    exclusions = MapSet.union(@excluded_names, normalize_names(Map.get(context, :exclusions)))

    excluded_roots =
      context
      |> context_path_forms(:excluded_roots)
      |> Enum.flat_map(fn %{lexical: lexical, canonical: canonical} -> [lexical, canonical] end)
      |> Enum.uniq()

    %{
      emit: emit,
      roots: context_path_forms(context, :roots),
      recent: context_path_forms(context, :recent),
      exclusions: exclusions,
      excluded_roots: excluded_roots,
      max_depth: non_negative_integer(Map.get(context, :max_depth), @default_max_depth),
      max_results: non_negative_integer(Map.get(context, :max_results), @default_max_results),
      max_entries: non_negative_integer(Map.get(context, :max_entries), @default_max_entries),
      deadline:
        System.monotonic_time(:millisecond) +
          non_negative_integer(Map.get(context, :timeout_ms), @default_timeout_ms),
      candidates: [],
      result_count: 0,
      errors: [],
      seen: MapSet.new(),
      scanned_depths: %{},
      visited: 0
    }
  end

  defp context_path_forms(context, key) when key in [:roots, :recent, :excluded_roots] do
    context
    |> Map.get(key)
    |> normalize_paths()
    |> Enum.map(&path_form/1)
    |> Enum.uniq()
  end

  defp path_form(path) do
    lexical = Path.expand(path)

    canonical =
      case PathSafety.canonicalize(lexical) do
        {:ok, canonical} -> canonical
        {:error, _reason} -> lexical
      end

    %{lexical: lexical, canonical: canonical}
  end

  defp dispatch("recent", _path, state) do
    process_recent(state.recent, state)
    |> finish(nil)
  end

  defp dispatch("manual", path, state) do
    expanded = Path.expand(path)

    case begin_work(state) do
      {:ok, state} ->
        case explicit_candidate(expanded, state, explicit_scope(expanded)) do
          {:reported, state} -> finish(state, :error)
          {:skip, state} -> finish(state, nil)
          result -> finish(result, nil)
        end

      result ->
        finish(result, nil)
    end
  end

  defp dispatch("browse", path, state) do
    expanded = Path.expand(path)

    case PathSafety.canonicalize(expanded) do
      {:ok, canonical} ->
        cond do
          excluded_path?(expanded, canonical, state) ->
            finish(state, nil)

          not inside_explicit_scope?(expanded, canonical) ->
            finish(record_error(state, expanded, :unsafe_symlink), :error)

          true ->
            browse_directory(expanded, canonical, state)
        end

      {:error, _reason} ->
        finish(record_error(state, path, :unreadable), :error)
    end
  end

  defp dispatch("scan", nil, state), do: scan_roots(state.roots, state.roots, state)

  defp dispatch("scan", path, state) do
    expanded = Path.expand(path)

    case PathSafety.canonicalize(expanded) do
      {:ok, canonical} ->
        allowed_roots = canonical_paths(state.roots)

        cond do
          excluded_path?(expanded, canonical, state) ->
            finish(state, nil)

          not inside_any?(canonical, allowed_roots) ->
            finish(record_error(state, expanded, :outside_allowed_root), :error)

          true ->
            finish(scan_one_root(%{lexical: expanded, canonical: canonical}, allowed_roots, state), nil)
        end

      {:error, _reason} ->
        finish(record_error(state, path, :unreadable), :error)
    end
  end

  defp process_recent(paths, state) do
    Enum.reduce_while(paths, {:ok, state}, fn %{lexical: lexical}, {:ok, state} ->
      case begin_work(state) do
        {:ok, state} -> reduce_recent(explicit_candidate(lexical, state, explicit_scope(lexical)))
        stopped -> {:halt, stopped}
      end
    end)
  end

  defp reduce_recent({:skip, state}), do: {:cont, {:ok, state}}
  defp reduce_recent({:ok, state}), do: {:cont, {:ok, state}}
  defp reduce_recent({:reported, state}), do: {:cont, {:ok, state}}
  defp reduce_recent(stopped), do: {:halt, stopped}

  defp scan_roots(roots, allowed_roots, state) do
    allowed_roots = canonical_paths(allowed_roots)

    roots
    |> Enum.reduce_while(state, fn root, state ->
      case scan_one_root(root, allowed_roots, state) do
        {:ok, state} -> {:cont, state}
        {:stop, reason, state} -> {:halt, {state, reason}}
      end
    end)
    |> case do
      {state, reason} -> finish(state, reason)
      state -> finish(state, nil)
    end
  end

  defp scan_one_root(%{lexical: lexical, canonical: canonical}, allowed_roots, state) do
    with {:ok, state} <- begin_work(state) do
      cond do
        excluded_path?(lexical, canonical, state) ->
          {:ok, state}

        not inside_any?(canonical, allowed_roots) ->
          {:ok, state}

        not directory?(canonical) ->
          record_error(state, lexical, :unreadable)

        true ->
          scan_directory(lexical, canonical, 0, allowed_roots, state)
      end
    end
  end

  defp browse_directory(lexical, canonical, state) do
    with {:ok, state} <- begin_work(state),
         true <- directory?(canonical) do
      read_children(canonical, state, &process_browse_child(&1, lexical, canonical, &2), lexical)
      |> finish(nil)
    else
      false -> finish(record_error(state, lexical, :unreadable), nil)
      result -> finish(result, nil)
    end
  end

  defp process_browse_child(child, lexical_parent, physical_parent, state) do
    lexical = Path.join(lexical_parent, child)

    with false <- excluded_name?(child, state),
         {:ok, canonical} <- PathSafety.canonicalize(Path.join(physical_parent, child)),
         true <- canonical != physical_parent and inside?(canonical, physical_parent),
         false <- excluded_path?(lexical, canonical, state),
         true <- directory?(canonical) do
      add_candidate(canonical, state)
    else
      {:error, _reason} -> record_error(state, lexical, :unreadable)
      _excluded -> {:ok, state}
    end
  end

  defp scan_directory(lexical, physical, depth, allowed_roots, state) do
    with false <- Map.get(state.scanned_depths, physical, state.max_depth + 1) <= depth,
         {:ok, state} <- add_candidate(physical, state) do
      state = %{state | scanned_depths: Map.put(state.scanned_depths, physical, depth)}

      if depth >= state.max_depth do
        {:ok, state}
      else
        read_children(
          physical,
          state,
          &process_scan_child(&1, lexical, physical, depth, allowed_roots, &2),
          lexical
        )
      end
    else
      true -> {:ok, state}
      stopped -> stopped
    end
  end

  defp process_scan_child(child, lexical_parent, physical_parent, depth, allowed_roots, state) do
    lexical = Path.join(lexical_parent, child)

    with false <- excluded_name?(child, state),
         {:ok, canonical} <- PathSafety.canonicalize(Path.join(physical_parent, child)),
         true <- inside_any?(canonical, allowed_roots),
         false <- excluded_path?(lexical, canonical, state),
         true <- directory?(canonical) do
      scan_directory(lexical, canonical, depth + 1, allowed_roots, state)
    else
      {:error, _reason} -> record_error(state, lexical, :unreadable)
      _excluded -> {:ok, state}
    end
  end

  defp read_children(path, state, processor, error_path) do
    case entry_boundary({:ok, state}) do
      {:halt, stopped} ->
        stopped

      {:cont, initial} ->
        result =
          DirectoryEntries.reduce_while(path, initial, state.deadline, fn child, {:ok, state} ->
            visit_child(child, state, processor, error_path)
          end)

        case result do
          {:ok, outcome} -> outcome
          {:error, :timeout, {:ok, state}} -> {:stop, :timeout, state}
          {:error, reason, {:ok, state}} -> record_error(state, error_path, reason)
        end
    end
  end

  defp visit_child(child, state, processor, error_path) do
    state = %{state | visited: state.visited + 1}

    outcome =
      if String.valid?(child) do
        processor.(child, state)
      else
        record_error(state, error_path, :invalid_filename)
      end

    entry_boundary(outcome)
  end

  defp entry_boundary({:stop, _reason, _state} = stopped), do: {:halt, stopped}

  defp entry_boundary({:ok, state}) do
    case control(state) do
      {:stop, reason} -> {:halt, {:stop, reason, state}}
      :continue when state.visited >= state.max_entries -> {:halt, {:stop, :limit, state}}
      :continue -> {:cont, {:ok, state}}
    end
  end

  defp canonical_paths(forms), do: Enum.map(forms, & &1.canonical)

  defp explicit_candidate(expanded, state, scope) do
    with {:ok, canonical} <- PathSafety.canonicalize(expanded),
         false <- excluded_path?(expanded, canonical, state),
         :ok <- if(inside?(canonical, scope), do: :ok, else: {:error, :unsafe_symlink}),
         :directory <- directory_status(canonical) do
      add_candidate(canonical, state)
    else
      true -> {:skip, state}
      {:error, :unsafe_symlink} -> explicit_result_error(expanded, state, :unsafe_symlink)
      {:error, _reason} -> explicit_result_error(expanded, state, :unreadable)
      reason -> explicit_result_error(expanded, state, reason)
    end
  end

  defp explicit_result_error(path, state, reason) do
    case record_error(state, path, reason) do
      {:ok, state} -> {:reported, state}
      {:stop, stop_reason, state} -> {:stop, stop_reason, state}
    end
  end

  defp explicit_scope(path) do
    expanded_parent = Path.dirname(Path.expand(path))

    case PathSafety.canonicalize(expanded_parent) do
      {:ok, canonical_parent} -> canonical_parent
      {:error, _reason} -> expanded_parent
    end
  end

  defp add_candidate(path, state) do
    if MapSet.member?(state.seen, path) do
      {:ok, state}
    else
      candidate = %{path: path, kind: "directory"}

      state = %{
        state
        | seen: MapSet.put(state.seen, path),
          candidates: [candidate | state.candidates],
          result_count: state.result_count + 1
      }

      with {:ok, state} <- emit(state, %{type: "candidate", candidate: candidate}) do
        candidate_boundary(state)
      end
    end
  end

  defp candidate_boundary(state) do
    case control(state) do
      {:stop, reason} -> {:stop, reason, state}
      :continue when state.result_count >= state.max_results -> {:stop, :limit, state}
      :continue -> {:ok, state}
    end
  end

  defp begin_work(state) do
    case control(state) do
      {:stop, reason} -> {:stop, reason, state}
      :continue when state.visited >= state.max_entries -> {:stop, :limit, state}
      :continue -> {:ok, %{state | visited: state.visited + 1}}
    end
  end

  defp control(state) do
    if System.monotonic_time(:millisecond) >= state.deadline do
      {:stop, :timeout}
    else
      receive do
        :cancel -> {:stop, :cancelled}
      after
        0 -> :continue
      end
    end
  end

  defp emit(state, event) do
    case state.emit.(event) do
      :ok -> {:ok, state}
      :cancel -> {:stop, :cancelled, state}
    end
  end

  defp record_error(state, path, reason) do
    error = %{path: safe_path(path), reason: reason}
    state = %{state | errors: [error | state.errors]}

    emit(state, %{type: "error", error: error})
  end

  defp finish({:ok, state}, :error), do: finish(state, :error)
  defp finish({:ok, state}, _default_reason), do: finish(state, nil)
  defp finish({:stop, reason, state}, _default_reason), do: finish(state, reason)

  defp finish(state, reason) do
    reason =
      if is_nil(reason) and System.monotonic_time(:millisecond) >= state.deadline do
        :timeout
      else
        reason
      end

    state = if reason == :timeout, do: report_timeout(state), else: state

    %{
      status: status(reason, state),
      candidates: Enum.reverse(state.candidates),
      errors: Enum.reverse(state.errors),
      visited: state.visited
    }
  end

  defp report_timeout(state) do
    case record_error(state, nil, :timeout) do
      {:ok, state} -> state
      {:stop, _reason, state} -> state
    end
  end

  defp status(:cancelled, _state), do: "cancelled"
  defp status(:timeout, _state), do: "timeout"
  defp status(:limit, _state), do: "limit"
  defp status(:error, _state), do: "error"
  defp status(nil, %{errors: [_ | _]}), do: "partial"
  defp status(nil, _state), do: "ok"

  defp excluded_path?(lexical, canonical, state) do
    excluded_name_path?(lexical, state) or
      excluded_name_path?(canonical, state) or
      inside_any?(lexical, state.excluded_roots) or
      inside_any?(canonical, state.excluded_roots)
  end

  defp excluded_name_path?(path, state) do
    path
    |> Path.split()
    |> Enum.any?(&excluded_name?(&1, state))
  end

  defp excluded_name?(name, state) when is_binary(name) do
    normalized = String.downcase(name)
    String.starts_with?(normalized, ".") or MapSet.member?(state.exclusions, normalized)
  end

  defp inside_explicit_scope?(expanded, canonical), do: inside?(canonical, explicit_scope(expanded))

  defp inside_any?(_path, []), do: false
  defp inside_any?(path, roots), do: Enum.any?(roots, &inside?(path, &1))

  defp inside?(path, root) when path == root, do: true
  defp inside?(path, "/"), do: String.starts_with?(path, "/")
  defp inside?(path, root), do: String.starts_with?(path, root <> "/")

  defp directory_status(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> :directory
      {:ok, _stat} -> :not_directory
      {:error, _reason} -> :unreadable
    end
  end

  defp directory?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> true
      _ -> false
    end
  end

  defp safe_path(path) when is_binary(path) do
    if Path.type(path) == :absolute, do: Path.expand(path), else: nil
  end

  defp safe_path(_path), do: nil

  defp normalize_paths(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp normalize_paths(_value), do: []

  defp normalize_names(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_names(_value), do: MapSet.new()

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default
end
