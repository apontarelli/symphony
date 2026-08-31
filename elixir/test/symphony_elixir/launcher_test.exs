defmodule SymphonyElixir.LauncherTest do
  use ExUnit.Case

  test "resolves repository root against the caller directory" do
    assert {output, 0} = run_launcher(repo_root!(), ".")
    assert output =~ "setup: #{Path.join(repo_root!(), "symphony.yml")}"
  end

  @tag :tmp_dir
  test "preserves an absolute repository path", %{tmp_dir: tmp_dir} do
    caller = Path.join(tmp_dir, "caller")
    File.mkdir_p!(caller)

    assert {output, 0} = run_launcher(caller, repo_root!())
    assert output =~ "setup: #{Path.join(repo_root!(), "symphony.yml")}"
  end

  @tag :tmp_dir
  test "resolves a relative repository path against another caller directory", %{tmp_dir: tmp_dir} do
    caller = Path.join(tmp_dir, "caller")
    repo = Path.join(caller, "target")
    File.mkdir_p!(caller)
    File.ln_s!(repo_root!(), repo)

    assert {output, 0} = run_launcher(caller, "target")
    assert output =~ "setup: #{Path.join(repo, "symphony.yml")}"
  end

  @tag :tmp_dir
  test "resolves explicit run repository paths against the caller directory", %{tmp_dir: tmp_dir} do
    caller = Path.join(tmp_dir, "caller")
    repo = Path.join(caller, "target")
    File.mkdir_p!(caller)
    File.ln_s!(repo_root!(), repo)

    assert {output, 0} =
             run_command(caller, [
               "run",
               "SID-455",
               "--repo",
               "target",
               "--preview",
               "--no-env-file"
             ])

    assert output =~ "repo setup: #{Path.join(repo, "symphony.yml")}"
  end

  @tag :tmp_dir
  test "reports a missing caller-relative repository path", %{tmp_dir: tmp_dir} do
    caller = Path.join(tmp_dir, "caller")
    missing = Path.join(caller, "missing")
    File.mkdir_p!(caller)

    assert {output, 1} = run_launcher(caller, "missing")
    assert output =~ "Repo root not found: #{missing}"
  end

  defp run_launcher(caller, repo_arg) do
    run_command(caller, ["setup", "check", "--repo", repo_arg])
  end

  defp run_command(caller, args) do
    System.cmd(
      Path.join(repo_root!(), "bin/symphony"),
      args,
      cd: caller,
      env: [
        {"SYMPHONY_HOME", Path.join(repo_root!(), "elixir")},
        {"SYMPHONY_SKIP_BUILD", "1"}
      ],
      stderr_to_stdout: true
    )
  end

  defp repo_root!, do: Path.expand("../../..", __DIR__)
end
