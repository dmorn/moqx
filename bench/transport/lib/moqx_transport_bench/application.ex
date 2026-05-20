defmodule MOQX.TransportBench.Application do
  @moduledoc false

  use Application

  alias MOQX.TransportBench.ReleaseCLI

  @run_env "MOQX_TRANSPORT_BENCH_RELEASE_CLI"

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(System.get_env(@run_env)),
      strategy: :one_for_one,
      name: __MODULE__.Supervisor
    )
  end

  defp children("1") do
    [
      %{
        id: ReleaseCLI,
        start: {Task, :start_link, [&run_release_cli/0]},
        restart: :temporary
      }
    ]
  end

  defp children(_value), do: []

  defp run_release_cli do
    ReleaseCLI.main_from_env()
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
