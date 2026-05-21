defmodule MOQX.Transport.Send do
  @moduledoc """
  Transport send request accepted by a backend.

  A send token means the backend accepted the request for scheduling. It is not
  proof that the peer received the bytes.
  """

  @type t :: %__MODULE__{
          ref: reference(),
          byte_size: non_neg_integer(),
          finish?: boolean()
        }

  defstruct [:ref, :byte_size, finish?: false]
end
