defmodule MOQX do
  @moduledoc """
  Elixir Media over QUIC library.

  Protocol code is built on top of a small transport adapter boundary so that
  native QUIC and deterministic support transports can share the same contract.
  """

  @doc "Returns the default native QUIC transport implementation."
  @spec transport() :: module()
  def transport do
    MOQX.Transport.Quicer
  end
end
