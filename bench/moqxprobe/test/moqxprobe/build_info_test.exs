defmodule MOQXProbe.BuildInfoTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.BuildInfo

  test "uses the build git SHA when one was embedded" do
    assert BuildInfo.git_sha(
             build_git_sha: " abcdef0\n",
             command_runner: fn _, _, _ -> raise "git command should not run" end
           ) == "abcdef0"
  end

  test "falls back to git when no build SHA is embedded" do
    command_runner = fn
      "git", ["rev-parse", "--short", "HEAD"], [stderr_to_stdout: true] ->
        {"1234567\n", 0}
    end

    assert BuildInfo.git_sha(build_git_sha: nil, command_runner: command_runner) == "1234567"
  end

  test "returns nil when neither embedded nor runtime git SHA is available" do
    command_runner = fn _, _, _ -> {"fatal: not a git repo", 1} end

    assert BuildInfo.git_sha(build_git_sha: "unknown", command_runner: command_runner) == nil
  end
end
