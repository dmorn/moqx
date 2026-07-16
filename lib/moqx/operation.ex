defmodule MOQX.Operation do
  @moduledoc """
  Protocol-neutral application intent accepted by a protocol implementation.

  Wire messages are intentionally excluded from this namespace.
  """

  @type t ::
          Subscribe.t()
          | Unsubscribe.t()
          | Publish.t()
          | AddTrack.t()
          | AcceptPublicationSubscription.t()
          | RejectPublicationSubscription.t()
          | PublishObject.t()
          | FinishPublication.t()
          | Close.t()

  defmodule Subscribe do
    @moduledoc "Subscribes to one application-level track address."

    @enforce_keys [:track]
    defstruct [:track, options: []]

    @type t :: %__MODULE__{track: MOQX.TrackRef.t(), options: keyword()}
  end

  defmodule Unsubscribe do
    @moduledoc "Ends one subscription created through the public API."

    @enforce_keys [:subscription]
    defstruct [:subscription]

    @type t :: %__MODULE__{subscription: term()}
  end

  defmodule Publish do
    @moduledoc "Advertises one application-level track namespace."

    @enforce_keys [:namespace]
    defstruct [:namespace, options: []]

    @type t :: %__MODULE__{namespace: [binary()], options: keyword()}
  end

  defmodule AddTrack do
    @moduledoc "Registers one track under an active publication."

    @enforce_keys [:publication, :track]
    defstruct [:publication, :track, options: []]

    @type t :: %__MODULE__{
            publication: MOQX.Publication.t(),
            track: binary(),
            options: keyword()
          }
  end

  defmodule AcceptPublicationSubscription do
    @moduledoc "Accepts one pending inbound publisher subscription."

    @enforce_keys [:request, :published_track]
    defstruct [:request, :published_track, options: []]

    @type t :: %__MODULE__{
            request: MOQX.PublicationSubscriptionRequest.t(),
            published_track: MOQX.PublishedTrack.t(),
            options: keyword()
          }
  end

  defmodule RejectPublicationSubscription do
    @moduledoc "Rejects one pending inbound publisher subscription."

    @enforce_keys [:request, :rejection]
    defstruct [:request, :rejection]

    @type t :: %__MODULE__{
            request: MOQX.PublicationSubscriptionRequest.t(),
            rejection: MOQX.SubscriptionRejection.t()
          }
  end

  defmodule PublishObject do
    @moduledoc "Publishes one protocol-neutral object on a registered track."

    @enforce_keys [:track, :object]
    defstruct [:track, :object]

    @type t :: %__MODULE__{track: MOQX.PublishedTrack.t(), object: MOQX.Object.t()}
  end

  defmodule FinishPublication do
    @moduledoc "Gracefully withdraws a namespace publication."

    @enforce_keys [:publication]
    defstruct [:publication, options: []]

    @type t :: %__MODULE__{publication: MOQX.Publication.t(), options: keyword()}
  end

  defmodule Close do
    @moduledoc "Requests graceful connection shutdown."

    defstruct [:reason]

    @type t :: %__MODULE__{reason: term()}
  end
end
