defmodule Probed.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = []

    Supervisor.start_link(children,
      name: Probed.Supervisor,
      strategy: :one_for_one
    )
  end
end
