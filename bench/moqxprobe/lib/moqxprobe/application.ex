defmodule MOQXProbe.Application do
  @moduledoc false

  use Application

  alias Burrito.Util.Args
  alias MOQXProbe.ReleaseCLI

  @run_env "MOQXPROBE_RELEASE_CLI"

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      children(cli_mode(System.get_env(@run_env), Args.get_bin_path())),
      strategy: :one_for_one,
      name: __MODULE__.Supervisor
    )
  end

  defp cli_mode("1", _bin_path), do: :release
  defp cli_mode(_run_env, :not_in_burrito), do: :none
  defp cli_mode(_run_env, _bin_path), do: :burrito

  defp children(:release), do: [release_cli_child(&run_release_cli_from_env/0)]
  defp children(:burrito), do: [release_cli_child(&run_release_cli_from_burrito/0)]
  defp children(:none), do: []

  defp release_cli_child(run_fun) do
    %{
      id: ReleaseCLI,
      start: {Task, :start_link, [run_fun]},
      restart: :temporary
    }
  end

  defp run_release_cli_from_env do
    run_release_cli(&ReleaseCLI.main_from_env/0)
  end

  defp run_release_cli_from_burrito do
    run_release_cli(&ReleaseCLI.main_from_burrito/0)
  end

  defp run_release_cli(run_fun) do
    run_fun.()
    System.stop(0)
  rescue
    exception ->
      IO.puts(:stderr, Exception.format(:error, exception, __STACKTRACE__))
      System.stop(1)
  catch
    kind, reason ->
      IO.puts(:stderr, Exception.format(kind, reason, __STACKTRACE__))
      System.stop(1)
  end
end
