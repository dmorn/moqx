defmodule Mix.Tasks.Moqx.Transport.SelfPair do
  use Mix.Task

  alias MOQX.TransportBench.CLI

  @moduledoc false
  @shortdoc "Run the quicer self-pair transport calibration benchmark"

  @impl true
  def run(argv) do
    CLI.main(["self-pair" | argv], surface: :mix)
  end
end
