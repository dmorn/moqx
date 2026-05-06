defmodule MOQX do
  @moduledoc """
  Clean-slate Media over QUIC library targeting MOQT draft-14.

  This branch intentionally removes the previous Rustler/moqtail-backed public
  API. New protocol code should be built on top of a small transport adapter
  boundary so that QUIC can be swapped for deterministic test transports.
  """

  @doc "Returns the configured transport implementation."
  @spec transport() :: module()
  def transport do
    Application.get_env(:moqx, :transport, MOQX.Transport.Quicer)
  end
end
