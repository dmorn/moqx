defmodule MOQX.PublicationSubscriptionRequest do
  @moduledoc "Inspectable application request for an inbound publisher subscription."

  alias MOQX.PublicationSubscriptionRequest.Handle

  @enforce_keys [
    :handle,
    :publication,
    :track,
    :subscriber_priority,
    :group_order,
    :forward,
    :filter,
    :parameters
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          handle: Handle.t(),
          publication: MOQX.Publication.t(),
          track: MOQX.TrackRef.t(),
          subscriber_priority: 0..255,
          group_order: :publisher | :ascending | :descending,
          forward: boolean(),
          filter: MOQX.SubscriptionFilter.t(),
          parameters: [MOQX.SubscriptionParameter.t()]
        }
end

defmodule MOQX.PublicationSubscriptionRequest.Handle do
  @moduledoc false

  @enforce_keys [:scope, :request_id]
  defstruct [:scope, :request_id]

  @opaque t :: %__MODULE__{scope: reference(), request_id: non_neg_integer()}
end

defimpl Inspect, for: MOQX.PublicationSubscriptionRequest.Handle do
  def inspect(_handle, _options), do: "#MOQX.PublicationSubscriptionRequest.Handle<OPAQUE>"
end
