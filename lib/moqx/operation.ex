defmodule MOQX.Operation do
  @moduledoc """
  Protocol-neutral application intent accepted by a protocol implementation.

  Wire messages are intentionally excluded from this namespace.
  """

  @type t ::
          Discover.t()
          | CancelDiscovery.t()
          | Subscribe.t()
          | UpdateSubscription.t()
          | Unsubscribe.t()
          | Publish.t()
          | AddTrack.t()
          | RejectTrackRequest.t()
          | AcceptPublicationSubscription.t()
          | RejectPublicationSubscription.t()
          | PublishObject.t()
          | PublishCatalog.t()
          | WithdrawTrack.t()
          | FinishPublishedSubscription.t()
          | FinishPublication.t()
          | Close.t()

  defmodule Discover do
    @moduledoc "Starts live broadcast-prefix discovery."
    @enforce_keys [:prefix]
    defstruct [:prefix, options: []]
    @type t :: %__MODULE__{prefix: binary(), options: keyword()}
  end

  defmodule CancelDiscovery do
    @moduledoc "Cancels one broadcast discovery."
    @enforce_keys [:discovery]
    defstruct [:discovery]
    @type t :: %__MODULE__{discovery: MOQX.Discovery.t()}
  end

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

  defmodule UpdateSubscription do
    @moduledoc "Updates the parameters or object boundary of an active subscription."

    @enforce_keys [:subscription]
    defstruct [:subscription, options: []]

    @type t :: %__MODULE__{subscription: MOQX.Subscription.t(), options: keyword()}
  end

  defmodule Publish do
    @moduledoc "Advertises one application-level track namespace."

    @enforce_keys [:namespace]
    defstruct [:namespace, options: []]

    @type t :: %__MODULE__{namespace: [binary()], options: keyword()}
  end

  defmodule RejectTrackRequest do
    @moduledoc "Rejects one pending request for track metadata."
    @enforce_keys [:request, :rejection]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            request: MOQX.PublicationTrackRequest.t(),
            rejection: MOQX.SubscriptionRejection.t()
          }
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
    @moduledoc """
    Accepts one pending inbound publisher subscription.

    When `published_track` is absent, the selected protocol may register the
    requested track reactively from `options` without initiating a separate
    publisher-driven subscription.
    """

    @enforce_keys [:request]
    defstruct [:request, :published_track, reply_mode: :subscription, options: []]

    @type t :: %__MODULE__{
            request: MOQX.PublicationSubscriptionRequest.t(),
            published_track: MOQX.PublishedTrack.t() | nil,
            reply_mode: :subscription | :reactive | :none,
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

  defmodule PublishCatalog do
    @moduledoc "Publishes one complete application-profile catalog snapshot."
    @enforce_keys [:track, :catalog]
    defstruct [:track, :catalog]
    @type t :: %__MODULE__{track: MOQX.PublishedTrack.t(), catalog: MOQX.Catalog.t()}
  end

  defmodule WithdrawTrack do
    @moduledoc "Withdraws one registered published track without ending its publication."

    @enforce_keys [:track]
    defstruct [:track, options: []]

    @type t :: %__MODULE__{track: MOQX.PublishedTrack.t(), options: keyword()}
  end

  defmodule FinishPublication do
    @moduledoc "Gracefully withdraws a namespace publication."

    @enforce_keys [:publication]
    defstruct [:publication, options: []]

    @type t :: %__MODULE__{publication: MOQX.Publication.t(), options: keyword()}
  end

  defmodule FinishPublishedSubscription do
    @moduledoc "Finishes one accepted inbound publisher subscription."

    @enforce_keys [:subscription]
    defstruct [:subscription, options: []]

    @type t :: %__MODULE__{
            subscription: MOQX.PublishedSubscription.t(),
            options: keyword()
          }
  end

  defmodule Close do
    @moduledoc "Requests graceful connection shutdown."

    defstruct [:reason]

    @type t :: %__MODULE__{reason: term()}
  end
end
