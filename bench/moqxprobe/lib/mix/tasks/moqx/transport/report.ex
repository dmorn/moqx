defmodule Mix.Tasks.Moqx.Transport.Report do
  use Mix.Task

  alias MOQXProbe.CLI

  @moduledoc false
  @shortdoc "Render a human-readable report from transport benchmark JSONL"

  @impl true
  def run(argv) do
    CLI.main(["report" | argv], surface: :mix)
  end
end
