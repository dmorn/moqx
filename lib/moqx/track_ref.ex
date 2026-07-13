defmodule MOQX.TrackRef do
  @moduledoc """
  Protocol-neutral application address for one media track.

  A concrete protocol implementation translates namespace components and the
  track name into its own wire representation.
  """

  @enforce_keys [:namespace, :track]
  defstruct [:namespace, :track]

  @type t :: %__MODULE__{
          namespace: [binary()],
          track: binary()
        }
end
