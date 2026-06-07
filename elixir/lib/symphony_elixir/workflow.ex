defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads workflow configuration and prompt from `symphony.yml`.
  """

  alias SymphonyElixir.Workflow.{Manifest, ModuleRegistry}
  alias SymphonyElixir.WorkflowStore

  @manifest_file_name "symphony.yml"

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      manifest_file_path()
  end

  @spec selected_workflow_file_path() :: Path.t()
  def selected_workflow_file_path, do: workflow_file_path()

  @spec manifest_file_path() :: Path.t()
  def manifest_file_path, do: Path.join(File.cwd!(), @manifest_file_name)

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t(),
          workflow_module_resolution: ModuleRegistry.prompt_module_resolution()
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current()

      _ ->
        load()
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(selected_workflow_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    Manifest.load(Path.expand(path))
  end

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end
end
