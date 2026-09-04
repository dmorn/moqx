defmodule MOQX do
  @moduledoc """
  Elixir Media over QUIC library.

  Protocol code is built on top of a small transport adapter boundary so that
  native QUIC and deterministic support transports can share the same contract.
  """

  alias MOQX.Protocol.Resolver
  alias MOQX.Runtime.ConnectionDriver

  @typedoc """
  Relative object boundary requested when a subscription begins.

  `:next_object` starts after the publisher's current largest object and is the
  compatibility default. `:next_group` waits for the first object in a later
  group. A selected protocol returns an error when it cannot represent the
  requested policy.
  """
  @type subscription_start :: :next_object | :next_group

  @typedoc "Option accepted by `subscribe/3`."
  @type subscription_option ::
          {:start, subscription_start()}
          | {:filter, MOQX.SubscriptionFilter.t()}
          | {:priority, 0..255}
          | {:group_order, :ascending | :descending}
          | {:delivery_timeout, pos_integer()}
          | {:parameters, [MOQX.SubscriptionParameter.t()]}

  @typedoc "Option accepted by `update_subscription/3`."
  @type subscription_update_option ::
          {:start, subscription_start()}
          | {:filter, MOQX.SubscriptionFilter.t()}
          | {:priority, 0..255}
          | {:delivery_timeout, pos_integer()}
          | {:forward, boolean()}
          | {:new_group, non_neg_integer()}
          | {:parameters, [MOQX.SubscriptionParameter.t()]}

  @typedoc "Object delivery selected for a published track."
  @type publication_delivery :: :subgroup | :datagram

  @typedoc "Protocol-neutral reason for publisher-initiated subscription completion."
  @type published_subscription_status ::
          :internal_error
          | :unauthorized
          | :track_ended
          | :subscription_ended
          | :going_away
          | :expired
          | :too_far_behind
          | :malformed_track
          | :update_failed

  @typedoc "Error returned by `withdraw_track/3`."
  @type withdraw_track_error ::
          :unknown_published_track
          | :wrong_client_published_track
          | :unsupported_completion_status
          | :invalid_track_completion
          | :timeout
          | {:connection_closed, term()}
          | {:transport_action_failed, term()}

  @typedoc "Option accepted by `add_track/4`."
  @type published_track_option ::
          {:retention, :live | :latest | :all}
          | {:delivery, publication_delivery()}
          | {:timescale, pos_integer()}
          | {:publisher_priority, 0..255}
          | {:publisher_max_latency, non_neg_integer()}

  @doc "Returns the default native QUIC transport implementation."
  @spec transport() :: module()
  def transport do
    MOQX.Transport.Quicer
  end

  @doc "Connects to an endpoint using one explicitly selected protocol implementation."
  @spec connect(binary() | URI.t(), keyword()) :: {:ok, MOQX.Client.t()} | {:error, term()}
  def connect(endpoint, options) when is_binary(endpoint) or is_struct(endpoint, URI) do
    with {:ok, event_recipient} <- event_recipient(options),
         {:ok, endpoint} <- parse_endpoint(endpoint),
         {:ok, protocol} <- Resolver.fetch(Keyword.fetch!(options, :protocol)) do
      ConnectionDriver.start(endpoint, protocol, options, event_recipient)
    end
  rescue
    KeyError -> {:error, :protocol_required}
  end

  defp event_recipient(options) do
    case Keyword.get(options, :events_to, self()) do
      pid when is_pid(pid) -> {:ok, pid}
      _other -> {:error, :events_to_must_be_a_pid}
    end
  end

  @doc """
  Subscribes to a protocol-neutral track address.

  The `:start` option accepts `:next_object` or `:next_group` and defaults to
  `:next_object`. Protocol implementations map that application policy to
  their native subscription filter and reject unsupported policies explicitly.
  """
  @spec subscribe(MOQX.Client.t(), MOQX.TrackRef.t(), [subscription_option()]) ::
          {:ok, MOQX.Subscription.t()} | {:error, term()}
  def subscribe(client, track, options \\ []) do
    ConnectionDriver.subscribe(client, track, options)
  end

  @doc "Updates an active subscription's draft-neutral filter and delivery parameters."
  @spec update_subscription(
          MOQX.Client.t(),
          MOQX.Subscription.t(),
          [subscription_update_option()]
        ) ::
          :ok | {:error, term()}
  def update_subscription(client, subscription, options) do
    ConnectionDriver.update_subscription(client, subscription, options)
  end

  @doc "Ends an active subscription and sends the selected protocol's unsubscribe message."
  @spec unsubscribe(MOQX.Client.t(), MOQX.Subscription.t()) :: :ok | {:error, term()}
  def unsubscribe(client, subscription) do
    ConnectionDriver.unsubscribe(client, subscription)
  end

  @doc "Advertises a namespace through the selected protocol implementation."
  @spec publish(MOQX.Client.t(), [binary()], keyword()) ::
          {:ok, MOQX.Publication.t()} | {:error, term()}
  def publish(client, namespace, options \\ []) when is_list(namespace) do
    ConnectionDriver.publish(client, namespace, options)
  end

  @doc """
  Registers a track under an active publication.

  `:delivery` defaults to `:subgroup`. The selected protocol rejects a delivery
  mode it cannot represent. MoQ Lite draft-05 additionally requires a positive
  `:timescale` and accepts `:publisher_priority` and
  `:publisher_max_latency` for its immutable `TRACK_INFO`.
  """
  @spec add_track(MOQX.Client.t(), MOQX.Publication.t(), binary(), [published_track_option()]) ::
          {:ok, MOQX.PublishedTrack.t()} | {:error, term()}
  def add_track(client, publication, track, options \\ []) when is_binary(track) do
    ConnectionDriver.add_track(client, publication, track, options)
  end

  @doc """
  Accepts one pending inbound publisher subscription.

  Pass an existing `PublishedTrack` to attach another subscriber to a
  registered track; the result contains its `PublishedSubscription` handle.
  Pass track options instead to register the requested track reactively and
  accept its first subscription without sending a separate publisher-initiated
  `PUBLISH`; that result contains both the new track and subscription handles.
  """
  def accept_subscription(client, request, published_track_or_options, options \\ [])

  @spec accept_subscription(
          MOQX.Client.t(),
          MOQX.PublicationSubscriptionRequest.t(),
          [published_track_option()]
        ) ::
          {:ok, MOQX.PublishedTrack.t(), MOQX.PublishedSubscription.t()} | {:error, term()}
  def accept_subscription(client, request, options, []) when is_list(options) do
    ConnectionDriver.accept_subscription(client, request, nil, options)
  end

  @spec accept_subscription(
          MOQX.Client.t(),
          MOQX.PublicationSubscriptionRequest.t(),
          MOQX.PublishedTrack.t(),
          keyword()
        ) :: {:ok, MOQX.PublishedSubscription.t()} | {:error, term()}
  def accept_subscription(client, request, %MOQX.PublishedTrack{} = published_track, options) do
    ConnectionDriver.accept_subscription(client, request, published_track, options)
  end

  @doc "Rejects one pending inbound publisher subscription."
  @spec reject_subscription(
          MOQX.Client.t(),
          MOQX.PublicationSubscriptionRequest.t(),
          MOQX.SubscriptionRejection.t()
        ) :: :ok | {:error, term()}
  def reject_subscription(client, request, rejection) do
    ConnectionDriver.reject_subscription(client, request, rejection)
  end

  @doc "Publishes one object on a registered track."
  @spec publish_object(MOQX.Client.t(), MOQX.PublishedTrack.t(), MOQX.Object.t()) ::
          :ok | {:error, term()}
  def publish_object(client, track, object) do
    ConnectionDriver.publish_object(client, track, object)
  end

  @doc """
  Withdraws one registered track while keeping its publication and siblings active.

  The track is unavailable to new subscribers before this call returns. The
  selected protocol maps `:status` to its native terminal code. The default
  status is `:track_ended`.
  """
  @spec withdraw_track(
          MOQX.Client.t(),
          MOQX.PublishedTrack.t(),
          [{:status, published_subscription_status()} | {:reason, binary()}]
        ) :: :ok | {:error, withdraw_track_error()}
  def withdraw_track(client, track, options \\ []) do
    ConnectionDriver.withdraw_track(client, track, options)
  end

  @doc """
  Finishes every active delivery and withdraws a namespace publication.

  Pending controlled subscription requests are cancelled before established
  subscriptions and published tracks complete. The selected protocol
  withdraws the namespace only after those per-request completion boundaries.
  """
  @spec finish_publication(MOQX.Client.t(), MOQX.Publication.t(), keyword()) ::
          :ok | {:error, term()}
  def finish_publication(client, publication, options \\ []) do
    ConnectionDriver.finish_publication(client, publication, options)
  end

  @doc """
  Finishes one accepted publisher subscription without withdrawing its track
  or namespace publication.

  The selected implementation maps the protocol-neutral `:status` atom to its
  native `PUBLISH_DONE` code. The default is `:subscription_ended`.
  """
  @spec finish_subscription(
          MOQX.Client.t(),
          MOQX.PublishedSubscription.t(),
          [{:status, published_subscription_status()} | {:reason, binary()}]
        ) :: :ok | {:error, term()}
  def finish_subscription(client, published_subscription, options \\ []) do
    ConnectionDriver.finish_subscription(client, published_subscription, options)
  end

  @doc "Gracefully closes the selected protocol connection."
  @spec close(MOQX.Client.t(), keyword()) :: :ok | {:error, term()}
  def close(client, options \\ []) do
    ConnectionDriver.close(client, Keyword.get(options, :reason))
  end

  defp parse_endpoint(%URI{host: host} = endpoint) when is_binary(host), do: {:ok, endpoint}

  defp parse_endpoint(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{host: host} = uri when is_binary(host) -> {:ok, uri}
      _uri -> {:error, :invalid_endpoint}
    end
  end
end
