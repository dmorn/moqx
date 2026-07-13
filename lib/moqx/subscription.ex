defmodule MOQX.Subscription do
  @moduledoc "Public handle for one active track subscription."

  @enforce_keys [:id, :track]
  defstruct [:id, :track]

  @type t :: %__MODULE__{id: non_neg_integer(), track: MOQX.TrackRef.t()}
end
