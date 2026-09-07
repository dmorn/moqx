defmodule MOQX.Subscription do
  @moduledoc "Public handle for one active track subscription."

  @enforce_keys [:id, :track]
  defstruct [:id, :track, :scope]

  @opaque t :: %__MODULE__{
            id: non_neg_integer(),
            scope: reference() | nil | :uninitialized,
            track: MOQX.TrackRef.t()
          }
end
