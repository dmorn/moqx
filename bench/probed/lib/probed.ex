defmodule Probed do
  @moduledoc """
  Remote control-plane daemon for transport benchmark lab nodes.
  """

  @doc """
  Returns the daemon application version.
  """
  def version do
    Application.spec(:probed, :vsn)
  end
end
