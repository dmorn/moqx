defmodule Mix.Tasks.Moqx.Transport.SenderAdmission do
  @moduledoc false

  use Mix.Task

  alias MOQXProbe.CLI

  @shortdoc "Run the local DATAGRAM sender admission microbenchmark"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    CLI.main(["sender-admission" | argv], surface: :mix)
  end
end
