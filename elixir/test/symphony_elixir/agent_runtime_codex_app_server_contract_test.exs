defmodule SymphonyElixir.AgentRuntimeCodexAppServerContractTest do
  use SymphonyElixir.AgentRuntimeContract,
    adapter: SymphonyElixir.AgentRuntime.CodexAppServer,
    expected_runtime: :codex_app_server,
    fake: SymphonyElixir.AgentRuntimeContract.FakeCodex
end
