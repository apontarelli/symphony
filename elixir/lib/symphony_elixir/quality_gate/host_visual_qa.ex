defmodule SymphonyElixir.QualityGate.HostVisualQa do
  @moduledoc false

  alias SymphonyElixir.Config.Schema.QualityGate.HostVisualQa, as: Settings
  alias SymphonyElixir.ReviewRecords.Redaction
  alias SymphonyElixir.{Shell, SSH}

  @manifest_filename "visual-qa-manifest.json"
  @remote_status_marker "__SYMPHONY_HOST_VISUAL_QA_STATUS__"
  @remote_output_begin_marker "__SYMPHONY_HOST_VISUAL_QA_OUTPUT_BEGIN__"
  @remote_output_end_marker "__SYMPHONY_HOST_VISUAL_QA_OUTPUT_END__"
  @remote_manifest_begin_marker "__SYMPHONY_HOST_VISUAL_QA_MANIFEST_BEGIN__"
  @remote_manifest_end_marker "__SYMPHONY_HOST_VISUAL_QA_MANIFEST_END__"
  @default_path "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  @clean_env_keys ~w(HOME TMPDIR TMP TEMP LANG LC_ALL LC_CTYPE TERM)

  @spec run(map()) :: :skip | {:ok, map()} | {:error, term()}
  def run(%{settings: %{host_visual_qa: %Settings{} = settings}} = context) do
    with {:ok, command} <- configured_command(settings),
         {:ok, workspace} <- workspace(context),
         {:ok, artifact_dir} <- artifact_dir(settings, context),
         {:ok, result} <- execute_command(context, workspace, artifact_dir, command, timeout_ms(settings)) do
      normalize_success(result, artifact_dir)
    end
  end

  def run(_context), do: :skip

  defp configured_command(%Settings{enabled: false}), do: :skip

  defp configured_command(%Settings{command: command}) when is_binary(command) and command != "" do
    {:ok, command}
  end

  defp configured_command(_settings), do: :skip

  defp workspace(%{workspace: workspace}) when is_binary(workspace) and workspace != "", do: {:ok, workspace}
  defp workspace(_context), do: {:error, :workspace_unavailable}

  defp artifact_dir(%Settings{artifact_root: root}, context) do
    root = root || Path.join(System.tmp_dir!(), "symphony-host-visual-qa")
    dir = Path.join([expand_local_path(root, context), issue_slug(context), run_slug()])

    case Map.get(context, :worker_host) do
      host when is_binary(host) and host != "" ->
        {:ok, dir}

      _worker_host ->
        case File.mkdir_p(dir) do
          :ok -> {:ok, dir}
          {:error, reason} -> {:error, {:artifact_dir_unavailable, dir, reason}}
        end
    end
  end

  defp expand_local_path(path, %{worker_host: host}) when is_binary(host) and host != "", do: path
  defp expand_local_path(path, _context), do: Path.expand(path)

  defp issue_slug(context) do
    context
    |> Map.get(:issue)
    |> issue_identifier()
    |> case do
      nil -> "quality-gate"
      identifier -> safe_slug(identifier)
    end
  end

  defp issue_identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(%{"identifier" => identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue), do: nil

  defp run_slug do
    "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  defp safe_slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "quality-gate"
      slug -> slug
    end
  end

  defp timeout_ms(%Settings{timeout_ms: timeout}) when is_integer(timeout) and timeout > 0, do: timeout
  defp timeout_ms(_settings), do: 300_000

  defp execute_command(context, workspace, artifact_dir, command, timeout_ms) do
    env = command_env(context, artifact_dir)

    task =
      Task.async(fn ->
        if remote_host?(context) do
          execute_remote(context.worker_host, workspace, command, env, artifact_dir)
        else
          execute_local(workspace, command, env)
        end
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        normalize_command_result(result)

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:host_visual_qa_timeout, timeout_ms}}
    end
  end

  defp remote_host?(%{worker_host: host}) when is_binary(host) and host != "", do: true
  defp remote_host?(_context), do: false

  defp execute_local(workspace, command, env) do
    {output, status} =
      System.cmd(env_executable(), clean_shell_args(env, command),
        cd: workspace,
        stderr_to_stdout: true
      )

    {:ok, %{status: status, output: output}}
  end

  defp execute_remote(worker_host, workspace, command, env, artifact_dir) do
    manifest_path = Path.join(artifact_dir, @manifest_filename)
    command_output_path = Path.join(artifact_dir, "command-output.txt")

    remote_command =
      """
      mkdir -p #{Shell.escape(artifact_dir)} || exit $?
      cd #{Shell.escape(workspace)} || exit $?
      #{clean_remote_shell_command(env, command)} > #{Shell.escape(command_output_path)} 2>&1
      status=$?
      printf '#{@remote_status_marker}%s\\n' "$status"
      printf '#{@remote_output_begin_marker}\\n'
      cat #{Shell.escape(command_output_path)} 2>/dev/null || true
      printf '\\n#{@remote_output_end_marker}\\n'
      if [ -f #{Shell.escape(manifest_path)} ]; then
        printf '#{@remote_manifest_begin_marker}\\n'
        cat #{Shell.escape(manifest_path)}
        printf '\\n#{@remote_manifest_end_marker}\\n'
      fi
      exit 0
      """

    case SSH.run(worker_host, remote_command, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> parse_remote_result(output)
      {:ok, {output, status}} -> {:ok, %{status: status, output: output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp env_executable do
    System.find_executable("env") || "/usr/bin/env"
  end

  defp clean_shell_args(env, command) do
    ["-i"] ++ environment_assignments(env) ++ ["/bin/sh", "-c", command]
  end

  defp clean_remote_shell_command(env, command) do
    ["env" | clean_shell_args(env, command)]
    |> Enum.map_join(" ", &Shell.escape/1)
  end

  defp environment_assignments(env) do
    clean_base_env()
    |> Enum.concat(env)
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
  end

  defp clean_base_env do
    [{"PATH", inherited_path()}, {"SHELL", "/bin/sh"}] ++
      Enum.flat_map(@clean_env_keys, fn key ->
        case System.get_env(key) do
          value when is_binary(value) and value != "" -> [{key, value}]
          _value -> []
        end
      end)
  end

  defp inherited_path do
    case System.get_env("PATH") do
      path when is_binary(path) and path != "" -> path
      _path -> @default_path
    end
  end

  defp parse_remote_result(output) when is_binary(output) do
    case remote_status(output) do
      {:ok, status} ->
        {:ok,
         %{
           status: status,
           output: remote_section(output, @remote_output_begin_marker, @remote_output_end_marker) || "",
           manifest: remote_section(output, @remote_manifest_begin_marker, @remote_manifest_end_marker)
         }}

      :error ->
        {:error, {:invalid_host_visual_qa_remote_output, compact_output(output)}}
    end
  end

  defp remote_status(output) do
    output
    |> String.split("\n")
    |> Enum.find_value(:error, &remote_status_line/1)
  end

  defp remote_status_line(line) do
    if String.starts_with?(line, @remote_status_marker) do
      line
      |> String.slice(byte_size(@remote_status_marker), byte_size(line))
      |> String.trim()
      |> parse_remote_status()
    end
  end

  defp parse_remote_status(value) do
    case Integer.parse(value) do
      {status, ""} -> {:ok, status}
      _parse_error -> nil
    end
  end

  defp remote_section(output, begin_marker, end_marker) do
    with [_prefix, rest] <- String.split(output, begin_marker, parts: 2),
         [section | _suffix] <- String.split(String.trim_leading(rest, "\n"), end_marker, parts: 2) do
      String.trim_trailing(section, "\n")
    else
      _missing -> nil
    end
  end

  defp command_env(context, artifact_dir) do
    manifest_path = Path.join(artifact_dir, @manifest_filename)

    [
      {"SYMPHONY_VISUAL_QA_ARTIFACT_DIR", artifact_dir},
      {"SYMPHONY_VISUAL_QA_MANIFEST", manifest_path},
      {"SYMPHONY_VISUAL_QA_CATEGORY", visual_qa_category(context)}
    ]
    |> maybe_put_env("SYMPHONY_ISSUE_IDENTIFIER", issue_identifier(Map.get(context, :issue)))
  end

  defp visual_qa_category(%{job: job}) when is_map(job) do
    job
    |> Map.get(:category, Map.get(job, "category", :product_visual_review))
    |> to_string()
  end

  defp visual_qa_category(_context), do: "product_visual_review"

  defp maybe_put_env(env, _key, nil), do: env
  defp maybe_put_env(env, key, value), do: [{key, to_string(value)} | env]

  defp normalize_command_result({:ok, %{status: status, output: output} = result})
       when is_integer(status) and is_binary(output) do
    {:ok, result}
  end

  defp normalize_command_result({:error, reason}), do: {:error, reason}

  defp normalize_success(%{status: 0, output: output} = result, artifact_dir) do
    payload =
      artifact_dir
      |> manifest_payload(output, Map.get(result, :manifest))
      |> Map.put_new("status", "passed")
      |> Map.put_new("summary", "Host visual QA command completed.")
      |> Map.put("artifact_dir", artifact_dir)

    {:ok, normalize_payload(payload)}
  end

  defp normalize_success(%{status: status, output: output}, _artifact_dir) do
    {:error, {:host_visual_qa_command_failed, status, compact_output(output)}}
  end

  defp manifest_payload(artifact_dir, output) do
    manifest_path = Path.join(artifact_dir, @manifest_filename)

    if File.regular?(manifest_path) do
      manifest_path
      |> File.read!()
      |> decode_json_map()
      |> Map.put_new("manifest_path", manifest_path)
    else
      output
      |> decode_json_map()
      |> Map.put_new("raw_output", compact_output(output))
    end
  end

  defp manifest_payload(artifact_dir, _output, manifest) when is_binary(manifest) and manifest != "" do
    Path.join(artifact_dir, @manifest_filename)
    |> then(fn manifest_path ->
      manifest
      |> decode_json_map()
      |> Map.put_new("manifest_path", manifest_path)
    end)
  end

  defp manifest_payload(artifact_dir, output, _manifest), do: manifest_payload(artifact_dir, output)

  defp decode_json_map(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      %{}
    else
      case Jason.decode(value) do
        {:ok, decoded} when is_map(decoded) -> decoded
        _decode_error -> %{}
      end
    end
  end

  defp normalize_payload(payload) when is_map(payload) do
    payload
    |> normalize_keys()
    |> Map.update("artifacts", [], &normalize_artifacts/1)
    |> Map.update("checks", [], &normalize_checks/1)
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_keys(value)} end)
  end

  defp normalize_keys(values) when is_list(values), do: Enum.map(values, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_artifacts(artifacts) when is_list(artifacts), do: Enum.map(artifacts, &normalize_artifact/1)
  defp normalize_artifacts(_artifacts), do: []

  defp normalize_artifact(artifact) when is_map(artifact) do
    case Map.get(artifact, "path") do
      path when is_binary(path) and path != "" ->
        metadata =
          artifact
          |> Map.get("metadata", %{})
          |> normalize_keys()
          |> Map.put_new("path", path)

        artifact
        |> Map.delete("path")
        |> Map.put("metadata", metadata)
        |> Map.put_new("summary", "Host visual QA artifact captured.")

      _path ->
        artifact
    end
  end

  defp normalize_artifact(artifact), do: %{"kind" => "artifact", "label" => "artifact", "summary" => to_string(artifact)}

  defp normalize_checks(checks) when is_list(checks), do: Enum.map(checks, &normalize_check/1)
  defp normalize_checks(_checks), do: []

  defp normalize_check(check) when is_map(check), do: check
  defp normalize_check(check), do: %{"name" => "host_visual_qa", "status" => to_string(check)}

  defp compact_output(output) when is_binary(output) do
    output
    |> Redaction.redact_string()
    |> String.trim()
    |> String.slice(0, 4_000)
  end
end
