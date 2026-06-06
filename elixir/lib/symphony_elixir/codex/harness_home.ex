defmodule SymphonyElixir.Codex.HarnessHome do
  @moduledoc """
  Builds the Symphony-owned Codex home used by unattended app-server sessions.
  """

  alias SymphonyElixir.{Shell, Workflow}

  @override_env "SYMPHONY_CODEX_HOME"

  @agents_md """
  # Symphony Harness

  Scope: global defaults for Symphony-managed unattended Codex sessions.

  - Treat this `CODEX_HOME` as Symphony-owned harness runtime state.
  - Use the session cwd as the target repository; repo-local `AGENTS.md` and docs layer after this file.
  - Do not rely on the operator's interactive `~/.codex/AGENTS.md`, prompts, hooks, or skills.
  - Do not copy Symphony skills into `~/.agents` or `~/.codex`; use the skills and tools available in the session.
  - Keep automation behavior deterministic and report only true blockers that require missing auth, secrets, or permissions.
  """

  @spec agents_md() :: String.t()
  def agents_md, do: @agents_md

  @spec path(Path.t(), keyword()) :: Path.t()
  def path(workspace, opts \\ []) when is_binary(workspace) do
    remote? = Keyword.get(opts, :remote, false)

    case System.get_env(@override_env) do
      override when is_binary(override) and override != "" ->
        maybe_expand(override, remote?)

      _ ->
        configured_path(remote?) || managed_path(workspace, remote?)
    end
  end

  @spec ensure_local(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def ensure_local(workspace) when is_binary(workspace) do
    codex_home = path(workspace)
    agents_path = Path.join(codex_home, "AGENTS.md")

    with :ok <- File.mkdir_p(codex_home),
         :ok <- File.write(agents_path, agents_md()),
         :ok <- ensure_local_auth_link(codex_home) do
      {:ok, codex_home}
    else
      {:error, reason} -> {:error, {:codex_harness_home_failed, codex_home, reason}}
    end
  end

  @spec local_port_env(Path.t()) :: [{charlist(), charlist()}]
  def local_port_env(codex_home) when is_binary(codex_home) do
    [{~c"CODEX_HOME", String.to_charlist(codex_home)}]
  end

  @spec remote_prepare_command(Path.t()) :: String.t()
  def remote_prepare_command(codex_home) when is_binary(codex_home) do
    agents_path = Path.join(codex_home, "AGENTS.md")
    auth_path = Path.join(codex_home, "auth.json")

    [
      "mkdir -p #{Shell.escape(codex_home)}",
      "printf %b #{Shell.escape(shell_printf_escape(agents_md()))} > #{Shell.escape(agents_path)}",
      "if [ ! -e #{Shell.escape(auth_path)} ] && [ ! -L #{Shell.escape(auth_path)} ] && [ -f \"$HOME/.codex/auth.json\" ]; then ln -s \"$HOME/.codex/auth.json\" #{Shell.escape(auth_path)}; fi"
    ]
    |> Enum.join(" && ")
  end

  defp configured_path(remote?) do
    with {:ok, %{config: config}} <- Workflow.current(),
         path when is_binary(path) <- get_in(config, ["manifest", "harness", "codex_home"]),
         trimmed when trimmed != "" <- String.trim(path) do
      maybe_expand_configured_path(trimmed, remote?)
    else
      _ -> nil
    end
  end

  defp maybe_expand_configured_path(path, true), do: path

  defp maybe_expand_configured_path(path, false) do
    path
    |> Path.expand(Path.dirname(Workflow.selected_workflow_file_path()))
  end

  defp managed_path(workspace, remote?) do
    workspace
    |> Path.dirname()
    |> Path.join(Path.join([".symphony", "codex_home"]))
    |> maybe_expand(remote?)
  end

  defp maybe_expand(path, true), do: path
  defp maybe_expand(path, false), do: Path.expand(path)

  defp ensure_local_auth_link(codex_home) do
    source = Path.expand("~/.codex/auth.json")
    destination = Path.join(codex_home, "auth.json")

    cond do
      path_exists_or_symlink?(destination) ->
        :ok

      File.exists?(source) ->
        File.ln_s(source, destination)

      true ->
        :ok
    end
  end

  defp path_exists_or_symlink?(path) do
    File.exists?(path) or match?({:ok, _stat}, File.lstat(path))
  end

  defp shell_printf_escape(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
  end
end
