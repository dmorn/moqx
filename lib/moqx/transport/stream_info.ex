defmodule MOQX.Transport.StreamInfo do
  @moduledoc """
  Stable metadata for one QUIC stream from local endpoint perspective.
  """

  @type direction :: :bidirectional | :unidirectional
  @type role :: :client | :server
  @type initiator :: :local | :peer

  @type t :: %__MODULE__{
          stream_id: non_neg_integer(),
          direction: direction(),
          initiator: initiator(),
          initiator_role: role(),
          local_role: role(),
          send_side?: boolean(),
          receive_side?: boolean()
        }

  defstruct [
    :stream_id,
    :direction,
    :initiator,
    :initiator_role,
    :local_role,
    :send_side?,
    :receive_side?
  ]
end
