defmodule MOQX.TransportBench.BuildInfo do
  @moduledoc false

  @build_git_sha System.get_env("MOQX_TRANSPORT_BENCH_BUILD_GIT_SHA")

  def git_sha(opts \\ []) do
    build_git_sha = Keyword.get(opts, :build_git_sha, @build_git_sha)
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    normalize_git_sha(build_git_sha) || git_command_sha(command_runner)
  end

  defp git_command_sha(command_runner) do
    case command_runner.("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> normalize_git_sha(sha)
      _error -> nil
    end
  rescue
    ErlangError -> nil
  end

  defp normalize_git_sha(nil), do: nil

  defp normalize_git_sha(sha) when is_binary(sha) do
    sha = String.trim(sha)

    if sha in ["", "unknown"] do
      nil
    else
      sha
    end
  end
end
