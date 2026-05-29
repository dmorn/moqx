defmodule Mix.Tasks.Moqx.Transport.Iperf3Baseline do
  use Mix.Task

  alias MOQXProbe.CLI

  @moduledoc false
  @shortdoc "Run the iperf3 path baseline transport benchmark"

  @impl true
  def run(argv) do
    CLI.main(["iperf3-baseline" | argv], surface: :mix)
  end
end
