defmodule Mix.Tasks.Moqx.Transport.Measure do
  @moduledoc false
  use Mix.Task

  alias MOQXProbe.CLI

  @shortdoc "Run QUIC measurement benchmarks"

  @impl Mix.Task
  def run(argv) do
    CLI.main(["measure" | argv], surface: :mix)
  end
end
