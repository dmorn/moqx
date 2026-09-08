defmodule MOQX.PublicationTrackRequest do
  @moduledoc """
  One pending request for an absent track's immutable metadata, not a subscription.

  The connection's `events_to` recipient owns provisioning. `timeout_ms` is the
  decision window starting when MOQX receives the request, not when the caller
  reads its mailbox. Registering the track resolves all pending requests for its
  exact publication and name; it does not authorize any media subscription.
  """
  @enforce_keys [:handle, :publication, :track, :timeout_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          handle: MOQX.PublicationTrackRequest.Handle.t(),
          publication: MOQX.Publication.t(),
          track: MOQX.TrackRef.t(),
          timeout_ms: non_neg_integer()
        }
end

defmodule MOQX.PublicationTrackRequest.Handle do
  @moduledoc "Opaque connection-scoped identity for one metadata request. Do not construct or inspect its fields."
  @enforce_keys [:scope, :id]
  defstruct @enforce_keys
  @opaque t :: %__MODULE__{scope: reference(), id: non_neg_integer()}
end

defimpl Inspect, for: MOQX.PublicationTrackRequest.Handle do
  def inspect(_, _), do: "#MOQX.PublicationTrackRequest.Handle<OPAQUE>"
end
