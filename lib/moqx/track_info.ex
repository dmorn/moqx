defmodule MOQX.TrackInfo do
  @moduledoc "Protocol-neutral immutable publisher properties for one received track."

  @enforce_keys [
    :publisher_priority,
    :publisher_ordered,
    :publisher_max_latency,
    :timescale
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          publisher_priority: 0..255,
          publisher_ordered: boolean(),
          publisher_max_latency: non_neg_integer(),
          timescale: pos_integer()
        }
end
