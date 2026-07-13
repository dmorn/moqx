defmodule MOQX.Protocol.Capabilities do
  @moduledoc """
  Inspectable feature surface exposed by one protocol implementation.

  Capabilities describe application-visible protocol support. They are
  separate from `MOQX.Transport.Capabilities`, which describes the negotiated
  QUIC transport.
  """

  defstruct operations: MapSet.new(),
            delivery_modes: MapSet.new(),
            extensions: MapSet.new(),
            metadata: %{}

  @type t :: %__MODULE__{
          operations: MapSet.t(atom()),
          delivery_modes: MapSet.t(atom()),
          extensions: MapSet.t(atom()),
          metadata: map()
        }
end
