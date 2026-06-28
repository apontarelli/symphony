defmodule SymphonyElixir.Codex.LaunchTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Codex.Launch

  test "remote launch validates argv before starting ssh" do
    workspace = "/remote/workspaces/MT-INVALID-ARGV"

    assert {:error, :invalid_argv} = Launch.start(workspace, "worker-01", [])
    assert {:error, :invalid_argv} = Launch.start(workspace, "worker-01", ["codex", :app_server])
  end
end
