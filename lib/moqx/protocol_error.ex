defmodule MOQX.ProtocolError do
  @moduledoc "Application-facing error returned by one selected protocol implementation."

  @enforce_keys [:protocol, :operation, :code]
  defstruct [:protocol, :operation, :code, :reason]

  @type t :: %__MODULE__{
          protocol: atom(),
          operation: atom(),
          code: non_neg_integer(),
          reason: binary() | nil
        }
end
