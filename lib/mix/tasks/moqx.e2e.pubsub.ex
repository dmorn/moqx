defmodule Mix.Tasks.Moqx.E2e.Pubsub do
  @moduledoc """
  Deprecated alias for `mix moqx.roundtrip`.
  """

  use Mix.Task

  @shortdoc "Deprecated alias for moqx.roundtrip"
  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    Mix.shell().info("mix moqx.e2e.pubsub is deprecated; use mix moqx.roundtrip")
    Mix.Tasks.Moqx.Roundtrip.run(args)
  end
end
