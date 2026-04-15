defmodule Mix.Tasks.Moqx.Moqtail.Demo do
  @moduledoc """
  Deprecated alias for `mix moqx.inspect`.
  """

  use Mix.Task

  @shortdoc "Deprecated alias for moqx.inspect"
  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    Mix.shell().info("mix moqx.moqtail.demo is deprecated; use mix moqx.inspect")
    Mix.Tasks.Moqx.Inspect.run(args)
  end
end
