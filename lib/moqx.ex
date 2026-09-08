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
          {:profile, MOQX.Profile.t()}
          | {:max_catalog_bytes, pos_integer()}
          | {:max_catalog_encoded_bytes, pos_integer()}
          | {:start, subscription_start()}
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

  `:profile` defaults to `:none`: even catalog-named tracks emit opaque
  `ObjectReceived` events. Select `:cloudflare_cmsf`, `:moqtail_cmsf`, or `:hang`
  explicitly for `CatalogReceived` snapshots. The byte-limit options default to
  1 MiB each. HANG `catalog.json.z` selects raw DEFLATE; other HANG track names
  select plain JSON. Malformed updates emit `CatalogFailed` on this handle and
  preserve the last valid snapshot; a newer valid group can recover. HANG
  snapshots replace the whole catalog, report added/removed/changed track refs,
  and ignore older groups. Duplicate groups and nonzero object IDs are errors.
  Profile selection is immutable for the subscription lifetime.

  The `:start` option accepts `:next_object` or `:next_group` and defaults to
  `:next_object`. Protocol implementations map that application policy to
  their native subscription filter and reject unsupported policies explicitly.
  """
  @spec subscribe(MOQX.Client.t(), MOQX.TrackRef.t(), [subscription_option()]) ::
          {:ok, MOQX.Subscription.t()} | {:error, term()}
  def subscribe(client, track, options \\ []) do
    ConnectionDriver.subscribe(client, track, options)
  end

  @doc """
  Discovers matching Lite05 broadcasts using a literal path prefix.

  `BroadcastAvailable` events enumerate initial matches, followed by
  `DiscoveryReady`; additions and withdrawals then continue live. This does not
  subscribe to track catalogs. `max_broadcasts` defaults to 1024; exceeding it
  ends only that discovery. Replacement advertisements emit withdrawal with
  reason `:replaced` followed by availability. An unknown withdrawal terminates
  the discovery with `:invalid_announcement`, clearing all its broadcasts.
  Other protocols return `:unsupported_operation`.
  """
  @spec discover(MOQX.Client.t(), binary(), keyword()) ::
          {:ok, MOQX.Discovery.t()} | {:error, term()}
  def discover(client, prefix, options \\ []),
    do: ConnectionDriver.discover(client, prefix, options)

  @doc "Cancels one discovery, withdrawing its reported broadcasts before `DiscoveryDone`."
  @spec cancel_discovery(MOQX.Client.t(), MOQX.Discovery.t()) :: :ok | {:error, term()}
  def cancel_discovery(client, discovery),
    do: ConnectionDriver.cancel_discovery(client, discovery)

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
  Registers a retained catalog track under a ready publication.

  Requires an explicit `:profile`. HANG supports `compression: :none` (default,
  `catalog.json`) and `:deflate` (`catalog.json.z`). Register both to serve both
  forms. Each handle has independent update numbering and retains its latest
  snapshot for late subscribers. CMSF uses its profile's conventional name.
  """
  @spec add_catalog(MOQX.Client.t(), MOQX.Publication.t(), keyword()) ::
          {:ok, MOQX.PublishedTrack.t()} | {:error, term()}
  def add_catalog(client, publication, options) do
    profile = Keyword.get(options, :profile)
    compression = Keyword.get(options, :compression, :none)

    with :ok <- MOQX.Profile.validate(profile, client.protocol),
         {:ok, name} <- MOQX.Profile.track_name(profile, compression) do
      options = options |> Keyword.put(:retention, :latest) |> Keyword.put(:timescale, 1_000_000)
      add_track(client, publication, name, options)
    end
  end

  @doc """
  Publishes a complete catalog snapshot on a handle returned by `add_catalog/3`.

  Groups increase from zero independently per handle. Every update is one
  object, immediately finished, and retained for late subscribers. A failed
  validation does not consume a group number. This is transport admission;
  `CatalogReceived` at a receiver proves delivery.
  """
  @spec publish_catalog(MOQX.Client.t(), MOQX.PublishedTrack.t(), MOQX.Catalog.t()) ::
          :ok | {:error, term()}
  def publish_catalog(client, track, catalog),
    do: ConnectionDriver.publish_catalog(client, track, catalog)

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
  Publishes a complete group containing zero objects on a registered Lite track.

  Unlike an object with an empty payload, this sends only a group header and FIN.
  `group_id` must be in `0..4_611_686_018_427_387_902`, leaving room for the
  exclusive SUBSCRIBE_END bound. A new group must have a greater ID than the
  previous published group, and an open non-empty group must first be finished
  with an object whose `end_of_group?` is true. These publication-wide checks
  also apply to `publish_object/3`, even with zero subscribers. Multiple objects
  within an open group keep consecutive object IDs starting at zero.

  An empty group has no timestamp. Subsequent groups may use earlier or later
  timestamps; MOQX never interprets or rewrites codec epochs. HANG consumers own
  decoder reset and any cross-group ordering. Receiver events preserve arrival
  order, not global group order (see `MOQX.Event.SubgroupEnded`).

  Only matching subscriber ranges receive the group; completion counts it in
  the exclusive END bound. `retention: :latest` retains this header-only group
  in place of the previous single-object snapshot, so late subscribers do not
  receive stale pre-discontinuity media. This does not add an archive or
  multi-object group cache; other retention modes retain their existing behavior.

  Invalid IDs return `:invalid_group_id`, non-increasing IDs return
  `:invalid_group_sequence`, and an open group returns `:unfinished_group`.
  Foreign-client handles return `:wrong_client_published_track`; removed tracks
  return `:unknown_published_track` (or `:unknown_publication` once the entire
  publication has ended). A replacement track starts a fresh sequence.
  Other protocol implementations return `{:error, :unsupported_operation}`.
  Success means backend admission, not peer delivery or decoder reset.
  """
  @spec publish_empty_group(MOQX.Client.t(), MOQX.PublishedTrack.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  def publish_empty_group(client, track, group_id) do
    ConnectionDriver.publish_empty_group(client, track, group_id)
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
