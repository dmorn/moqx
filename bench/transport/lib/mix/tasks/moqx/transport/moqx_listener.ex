defmodule Mix.Tasks.Moqx.Transport.MoqxListener do
  @moduledoc false
  use Mix.Task

  alias MOQX.TransportBench.CLI

  @shortdoc "Run a MOQX.Transport echo/drain listener for reference clients"

  @impl Mix.Task
  def run(argv) do
    CLI.main(["moqx-listener" | argv], surface: :mix)
  end
end
