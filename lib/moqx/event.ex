defmodule MOQX.Event do
  @moduledoc "Typed application-facing events emitted by a `MOQX.Client`."

  @type t ::
          MOQX.Event.SubscriptionAccepted.t()
          | MOQX.Event.SubscriptionFailed.t()
          | MOQX.Event.SubscriptionDone.t()
          | MOQX.Event.ObjectReceived.t()
          | MOQX.Event.ObjectStatus.t()
          | MOQX.Event.CatalogReceived.t()
          | MOQX.Event.PublicationReady.t()
          | MOQX.Event.PublicationFailed.t()
          | MOQX.Event.PublicationCancelled.t()
          | MOQX.Event.PublicationSubscriptionRequested.t()
          | MOQX.Event.PublicationSubscriptionCancelled.t()
          | MOQX.Event.PublicationSubscriberJoined.t()
          | MOQX.Event.PublicationSubscriberLeft.t()
          | MOQX.Event.ConnectionClosed.t()
          | MOQX.Event.ProtocolFailed.t()
end

defmodule MOQX.Event.PublicationSubscriptionRequested do
  @moduledoc "An inbound publisher subscription is waiting for an application decision."
  @enforce_keys [:request]
  defstruct [:request]
  @type t :: %__MODULE__{request: MOQX.PublicationSubscriptionRequest.t()}
end

defmodule MOQX.Event.PublicationSubscriptionCancelled do
  @moduledoc "A pending inbound publisher subscription can no longer be decided."
  @enforce_keys [:request, :reason]
  defstruct [:request, :reason]

  @type t :: %__MODULE__{
          request: MOQX.PublicationSubscriptionRequest.t(),
          reason:
            :unsubscribed | :decision_timeout | :publication_finished | :publication_cancelled
        }
end

defmodule MOQX.Event.SubscriptionAccepted do
  @moduledoc "The relay accepted a subscription."
  @enforce_keys [:subscription]
  defstruct [:subscription]
  @type t :: %__MODULE__{subscription: MOQX.Subscription.t()}
end

defmodule MOQX.Event.SubscriptionFailed do
  @moduledoc "The relay rejected a subscription."
  @enforce_keys [:subscription, :error]
  defstruct [:subscription, :error]
  @type t :: %__MODULE__{subscription: MOQX.Subscription.t(), error: MOQX.ProtocolError.t()}
end

defmodule MOQX.Event.SubscriptionDone do
  @moduledoc "A subscription reached its terminal state after delivery draining."
  @enforce_keys [:subscription, :completion]
  defstruct [:subscription, :completion]

  @type t :: %__MODULE__{
          subscription: MOQX.Subscription.t(),
          completion: MOQX.Subscription.Completion.t()
        }
end

defmodule MOQX.Event.ObjectReceived do
  @moduledoc "A subscribed object was received."
  @enforce_keys [:object]
  defstruct [:object]
  @type t :: %__MODULE__{object: MOQX.Object.t()}
end

defmodule MOQX.Event.ObjectStatus do
  @moduledoc "A subscribed object-status marker was received."
  @enforce_keys [:object]
  defstruct [:object]
  @type t :: %__MODULE__{object: MOQX.Object.t()}
end

defmodule MOQX.Event.CatalogReceived do
  @moduledoc "A catalog object was decoded."
  @enforce_keys [:catalog]
  defstruct [:catalog]
  @type t :: %__MODULE__{catalog: MOQX.Catalog.t()}
end

defmodule MOQX.Event.PublicationReady do
  @moduledoc "A namespace publication was accepted."
  @enforce_keys [:publication]
  defstruct [:publication]
  @type t :: %__MODULE__{publication: MOQX.Publication.t()}
end

defmodule MOQX.Event.PublicationFailed do
  @moduledoc "A namespace publication was rejected."
  @enforce_keys [:publication, :error]
  defstruct [:publication, :error]
  @type t :: %__MODULE__{publication: MOQX.Publication.t(), error: MOQX.ProtocolError.t()}
end

defmodule MOQX.Event.PublicationCancelled do
  @moduledoc "A relay cancelled an active namespace publication."
  @enforce_keys [:publication, :error]
  defstruct [:publication, :error]
  @type t :: %__MODULE__{publication: MOQX.Publication.t(), error: MOQX.ProtocolError.t()}
end

defmodule MOQX.Event.PublicationSubscriberJoined do
  @moduledoc "A remote subscriber joined a published track."
  @enforce_keys [:track, :request_id]
  defstruct [:track, :request_id]
  @type t :: %__MODULE__{track: MOQX.PublishedTrack.t(), request_id: non_neg_integer()}
end

defmodule MOQX.Event.PublicationSubscriberLeft do
  @moduledoc "A remote subscriber left a published track."
  @enforce_keys [:track, :request_id]
  defstruct [:track, :request_id]
  @type t :: %__MODULE__{track: MOQX.PublishedTrack.t(), request_id: non_neg_integer()}
end

defmodule MOQX.Event.ConnectionClosed do
  @moduledoc "The transport connection closed."
  @enforce_keys [:metadata]
  defstruct [:metadata]
  @type t :: %__MODULE__{metadata: map()}
end

defmodule MOQX.Event.ProtocolFailed do
  @moduledoc "The selected protocol implementation failed."
  @enforce_keys [:reason]
  defstruct [:reason]
  @type t :: %__MODULE__{reason: term()}
end
