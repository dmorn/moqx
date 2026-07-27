defmodule MOQX.Extension do
  @moduledoc "Protocol-specific extension information retained losslessly at a public boundary."

  @enforce_keys [:protocol, :identifier, :value]
  defstruct [:protocol, :identifier, :value]

  @type t :: %__MODULE__{
          protocol: atom(),
          identifier: non_neg_integer(),
          value: non_neg_integer() | binary()
        }
end
