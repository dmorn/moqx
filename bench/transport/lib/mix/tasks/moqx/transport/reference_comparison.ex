defmodule Mix.Tasks.Moqx.Transport.ReferenceComparison do
  @moduledoc false
  use Mix.Task

  alias MOQX.TransportBench.CLI

  @shortdoc "Run reference QUIC comparison benchmarks"

  @impl Mix.Task
  def run(argv) do
    CLI.main(["reference-comparison" | argv], surface: :mix)
  end
end
