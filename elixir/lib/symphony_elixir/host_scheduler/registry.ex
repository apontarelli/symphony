defmodule SymphonyElixir.HostScheduler.Registry do
  @moduledoc false

  alias SymphonyElixir.TargetContext
  alias SymphonyElixir.TargetRegistry
  alias SymphonyElixir.TargetRegistry.{Composition, FileStore, Schema, Validation, Yaml}

  @type loaded :: %{
          snapshot: TargetRegistry.Snapshot.t(),
          contexts: %{String.t() => TargetContext.t()}
        }

  def load(path, opts \\ [])
  @spec load(Path.t(), keyword()) :: {:ok, loaded()} | {:error, term()}

  def load(path, opts) when is_binary(path) and is_list(opts) do
    expanded_path = Path.expand(path)

    with {:ok, %{bytes: bytes, generation: generation}} <- FileStore.read(expanded_path),
         {:ok, document} <- Yaml.decode(bytes),
         {:ok, snapshot} <- Schema.validate(document, home: Keyword.get(opts, :home, System.user_home!())) do
      snapshot =
        snapshot
        |> Map.merge(%{
          path: expanded_path,
          source_hash: generation,
          generation: generation
        })
        |> Validation.validate(registry_path: expanded_path)
        |> Composition.compose()

      if snapshot.globally_valid? do
        {:ok,
         %{
           snapshot: snapshot,
           contexts: build_contexts(snapshot, opts)
         }}
      else
        {:error, {:invalid_registry, snapshot.diagnostics}}
      end
    end
  rescue
    exception -> {:error, {:registry_load_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:registry_load_failed, {kind, reason}}}
  end

  def load(_path, _opts), do: {:error, :invalid_registry_path}

  defp build_contexts(snapshot, opts) do
    context_opts =
      case Keyword.fetch(opts, :env_fetcher) do
        {:ok, env_fetcher} -> [env_fetcher: env_fetcher]
        :error -> []
      end

    snapshot.targets
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(%{}, fn target_id, contexts ->
      case TargetContext.from_registry(snapshot, target_id, context_opts) do
        {:ok, %TargetContext{} = context} -> Map.put(contexts, target_id, context)
        {:error, _reason} -> contexts
      end
    end)
  end
end
