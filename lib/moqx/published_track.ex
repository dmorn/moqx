defmodule MOQX.PublishedTrack do
  @moduledoc "Opaque handle for a track registered under a publication."

  @enforce_keys [:publication, :track, :retention]
  defstruct [:scope, :id, :publication, :track, :retention]

  @type retention :: :live | :latest | :all

  @opaque t :: %__MODULE__{
            scope: reference() | nil | :uninitialized,
            id: non_neg_integer() | nil,
            publication: MOQX.Publication.t(),
            track: MOQX.TrackRef.t(),
            retention: retention()
          }

  @doc false
  @spec track_ref(t()) :: MOQX.TrackRef.t()
  def track_ref(%__MODULE__{track: track}), do: track
end
