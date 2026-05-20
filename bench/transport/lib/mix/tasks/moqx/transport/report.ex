defmodule Mix.Tasks.Moqx.Transport.Report do
  use Mix.Task

  alias MOQX.TransportBench.CLI

  @moduledoc false
  @shortdoc "Render a human-readable report from transport benchmark JSONL"

  @impl true
  def run(argv) do
    CLI.main(["report" | argv], surface: :mix)
  end
end
