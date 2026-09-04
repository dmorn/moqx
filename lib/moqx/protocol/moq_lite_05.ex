defmodule MOQX.Protocol.MOQLite05 do
  @moduledoc "MoQ Lite draft-05 over native QUIC."

  @behaviour MOQX.Protocol

  alias MOQX.Codec, as: BinaryCodec

  alias MOQX.Event.{
    ConnectionClosed,
    ObjectReceived,
    PublicationReady,
    PublicationSubscriberJoined,
    PublicationSubscriberLeft,
    PublicationSubscriptionCancelled,
    PublicationSubscriptionRequested,
    SubgroupEnded,
    SubscriptionAccepted,
    SubscriptionDone,
    SubscriptionFailed
  }

  alias MOQX.Protocol.{Capabilities, Transition, TransportSpec}
  alias MOQX.Protocol.MOQLite05.Codec
  alias MOQX.Protocol.MOQLite05.GroupDecoder

  alias MOQX.Protocol.MOQLite05.Messages.{
    AnnounceBroadcast,
    AnnounceOk,
    Frame,
    Group,
    Setup,
    Subscribe,
    SubscribeDrop,
    SubscribeEnd,
    SubscribeOk,
    SubscribeUpdate,
    Track,
    TrackInfo
  }

  @max_varint 4_611_686_018_427_387_903

  defmodule State do
    @moduledoc false
    defstruct phase: :starting,
              endpoint: nil,
              role: :both,
              peer_setup: nil,
              handle_scope: nil,
              next_publication_id: 0,
              next_published_track_id: 0,
              next_subscribe_id: 0,
              publications: %{},
              announce_streams: %{},
              pending_publisher_subscriptions: %{},
              publisher_subscriptions: %{},
              subscriptions: %{},
              group_decoders: %{},
              peer_stream_buffers: %{}
  end

  @impl true
  def id, do: :moq_lite_05

  @impl true
  def transport_spec(_endpoint, _options) do
    {:ok,
     %TransportSpec{
       alpn: "moq-lite-05",
       connect_options: [
         alpn: ["moq-lite-05"],
         verify: :verify_peer,
         datagram_receive_enabled: 1,
         peer_bidi_stream_count: 128,
         peer_unidi_stream_count: 128
       ],
       required_capabilities: MapSet.new([:streams])
     }}
  end

  @impl true
  def init(%URI{scheme: scheme} = endpoint, options) when scheme in ["moql", "moqt"] do
    role = Keyword.get(options, :role, :both)

    if role in [:both, :publisher, :subscriber] do
      {:ok, %State{endpoint: endpoint, role: role, handle_scope: make_ref()}}
    else
      {:error, :invalid_moq_lite_role}
    end
  end

  def init(_endpoint, _options), do: {:error, :moq_lite_05_requires_native_quic}

  @impl true
  def handle_transport(%State{phase: :starting} = state, {:connection_event, _conn, :ready, _}) do
    setup = %Setup{path: endpoint_path(state.endpoint), role: state.role}

    bytes =
      [BinaryCodec.encode_varint(0x1), Codec.encode_setup(setup)]
      |> IO.iodata_to_binary()

    Transition.ok(%{state | phase: :ready},
      events: [:ready],
      actions: [
        {:open_stream, :setup, [direction: :unidirectional], bytes, [finish: true]}
      ]
    )
  end

  def handle_transport(
        %State{} = state,
        {:connection_event, _connection, :closed, metadata}
      ) do
    active_events =
      state.publisher_subscriptions
      |> Enum.sort_by(fn {subscribe_id, _entry} -> subscribe_id end)
      |> Enum.map(fn {subscribe_id, entry} ->
        %PublicationSubscriberLeft{
          track: entry.track,
          subscription: entry.handle,
          request_id: subscribe_id
        }
      end)

    pending_events =
      state.pending_publisher_subscriptions
      |> Enum.sort_by(fn {subscribe_id, _entry} -> subscribe_id end)
      |> Enum.map(fn {_subscribe_id, entry} ->
        %PublicationSubscriptionCancelled{
          request: entry.request,
          reason: :publication_cancelled
        }
      end)

    next_state = %{
      state
      | publisher_subscriptions: %{},
        pending_publisher_subscriptions: %{},
        subscriptions: %{},
        group_decoders: %{},
        peer_stream_buffers: %{},
        announce_streams: %{}
    }

    Transition.ok(next_state,
      events: active_events ++ pending_events ++ [%ConnectionClosed{metadata: metadata}]
    )
  end

  def handle_transport(
        %State{} = state,
        {:stream_data, _stream, data, %{logical_stream: {:track, subscribe_id}}}
      ) do
    case state.subscriptions[subscribe_id] do
      nil ->
        Transition.error(state, :unknown_track_stream)

      entry ->
        buffer = Map.get(entry, :track_buffer, <<>>) <> data

        case Codec.decode_track_info(buffer) do
          {:ok, info} ->
            entry = %{
              entry
              | track_info: %MOQX.TrackInfo{
                  publisher_priority: info.publisher_priority,
                  publisher_ordered: info.publisher_ordered,
                  publisher_max_latency: info.publisher_max_latency,
                  timescale: info.timescale
                },
                track_buffer: <<>>
            }

            accept_if_ready(state, subscribe_id, entry)

          {:error, :invalid_track_info} ->
            put_subscription(state, subscribe_id, Map.put(entry, :track_buffer, buffer))
            |> Transition.ok()
        end
    end
  end

  def handle_transport(
        %State{} = state,
        {:stream_event, _stream, event, %{logical_stream: {:track, subscribe_id}} = metadata}
      )
      when event in [:peer_finished_sending, :peer_aborted_sending, :closed] do
    finish_track_stream(state, subscribe_id, event, metadata)
  end

  def handle_transport(
        %State{} = state,
        {:stream_data, %{info: %{direction: :bidirectional, initiator: :peer}} = stream, data,
         _metadata}
      ) do
    handle_peer_stream_data(state, stream.info.stream_id, data)
  end

  def handle_transport(
        %State{} = state,
        {:stream_data, %{info: %{direction: :unidirectional, initiator: :peer}} = stream, data,
         _metadata}
      ) do
    handle_peer_unidirectional_data(state, stream.info.stream_id, data)
  end

  def handle_transport(
        %State{} = state,
        {:stream_data, _stream, data, %{logical_stream: {:subscribe, subscribe_id}}}
      ) do
    case state.subscriptions[subscribe_id] do
      nil ->
        Transition.error(state, :unknown_subscribe_stream)

      entry ->
        buffer = Map.get(entry, :subscribe_buffer, <<>>) <> data

        with {:ok, responses, rest} <- Codec.decode_subscribe_responses(buffer),
             {:ok, entry} <- reduce_subscribe_responses(entry, responses) do
          entry = Map.put(entry, :subscribe_buffer, rest)
          accept_if_ready(state, subscribe_id, entry)
        else
          {:error, reason} -> Transition.error(state, reason)
        end
    end
  end

  def handle_transport(
        %State{} = state,
        {:stream_event, _stream, :peer_finished_sending,
         %{logical_stream: {:subscribe, subscribe_id}}}
      ) do
    finish_subscription(state, subscribe_id)
  end

  def handle_transport(
        %State{} = state,
        {:stream_event, _stream, event, %{logical_stream: {:subscribe, subscribe_id}} = metadata}
      )
      when event in [:peer_aborted_sending, :peer_aborted_receiving, :closed] do
    abort_subscription(state, subscribe_id, metadata[:error_code] || 0)
  end

  def handle_transport(
        %State{} = state,
        {:stream_event, _stream, event, %{logical_stream: {:group, subscribe_id, group_id}}}
      )
      when event in [:peer_aborted_receiving, :closed] do
    clear_active_publication_group(state, subscribe_id, group_id)
  end

  def handle_transport(
        %State{} = state,
        {:stream_event,
         %{info: %{stream_id: stream_id, direction: :bidirectional, initiator: :peer}}, event,
         metadata}
      )
      when event in [
             :peer_finished_sending,
             :peer_aborted_sending,
             :peer_aborted_receiving,
             :closed
           ] do
    finish_inbound_subscription(state, stream_id, event, metadata)
  end

  def handle_transport(
        %State{} = state,
        {:stream_event, %{info: %{stream_id: stream_id}}, :peer_finished_sending, _metadata}
      ) do
    case Map.fetch(state.group_decoders, stream_id) do
      {:ok, decoder} -> finish_group_stream(state, stream_id, decoder)
      :error -> Transition.ok(state)
    end
  end

  def handle_transport(
        %State{} = state,
        {:runtime_timeout,
         {:publisher_subscription_decision,
          %MOQX.PublicationSubscriptionRequest.Handle{
            scope: scope,
            request_id: subscribe_id
          } = handle}}
      ) do
    case state.pending_publisher_subscriptions[subscribe_id] do
      %{request: %{handle: ^handle} = request, stream_id: stream_id}
      when scope == state.handle_scope ->
        next_state = %{
          state
          | pending_publisher_subscriptions:
              Map.delete(state.pending_publisher_subscriptions, subscribe_id)
        }

        Transition.ok(next_state,
          events: [
            %PublicationSubscriptionCancelled{request: request, reason: :decision_timeout}
          ],
          actions: [{:abort_stream_sending, {:peer_stream, stream_id}, 2}]
        )

      _other ->
        Transition.ok(state)
    end
  end

  def handle_transport(
        %State{} = state,
        {:stream_event,
         %{info: %{stream_id: stream_id, direction: :unidirectional, initiator: :peer}}, event,
         metadata}
      )
      when event in [:peer_aborted_sending, :closed] do
    case Map.fetch(state.group_decoders, stream_id) do
      {:ok, %{group: nil}} -> Transition.error(state, :incomplete_group_stream)
      {:ok, decoder} -> reset_group_stream(state, stream_id, decoder, event, metadata)
      :error -> Transition.ok(state)
    end
  end

  def handle_transport(%State{} = state, _event), do: Transition.ok(state)

  @impl true
  def handle_operation(%State{phase: :ready} = state, %MOQX.Operation.Subscribe{} = operation) do
    with {:ok, priority, ordered, max_latency, group_start, group_end} <-
           subscription_options(operation.options),
         {:ok, broadcast_path} <- broadcast_path(operation.track.namespace) do
      subscribe_id = state.next_subscribe_id
      subscription = %MOQX.Subscription{id: subscribe_id, track: operation.track}

      entry = %{
        subscription: subscription,
        track_info: nil,
        accepted_group: nil,
        accepted?: false,
        track_buffer: <<>>,
        subscribe_buffer: <<>>,
        subscribe_end: nil,
        subscribe_finished?: false,
        pending_group_events: [],
        accounted_ranges: [],
        processed_group_streams: 0,
        wire_options: %{
          priority: priority,
          ordered: ordered,
          max_latency: max_latency,
          group_start: group_start,
          group_end: group_end
        },
        options: operation.options
      }

      next_state = %{
        state
        | next_subscribe_id: subscribe_id + 1,
          subscriptions: Map.put(state.subscriptions, subscribe_id, entry)
      }

      track = %Track{broadcast_path: broadcast_path, track_name: operation.track.track}

      subscribe = %Subscribe{
        subscribe_id: subscribe_id,
        broadcast_path: broadcast_path,
        track_name: operation.track.track,
        subscriber_priority: priority,
        subscriber_ordered: ordered,
        subscriber_max_latency: max_latency,
        group_start: group_start,
        group_end: group_end
      }

      Transition.ok(next_state,
        events: [{:subscription_started, subscription}],
        actions: [
          {:open_stream, {:track, subscribe_id}, [direction: :bidirectional, active: true],
           stream_bytes(0x6, Codec.encode_track(track)), [finish: true]},
          {:open_stream, {:subscribe, subscribe_id}, [direction: :bidirectional, active: true],
           stream_bytes(0x2, Codec.encode_subscribe(subscribe))}
        ]
      )
    else
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %MOQX.Operation.Publish{} = operation) do
    with {:ok, _path} <- broadcast_path(operation.namespace),
         {:ok, inbound_subscriptions} <- inbound_subscription_options(operation.options),
         false <- publication_namespace?(state, operation.namespace) do
      publication = %MOQX.Publication{
        id: state.next_publication_id,
        namespace: operation.namespace
      }

      entry = %{
        publication: publication,
        tracks: %{},
        inbound_subscriptions: inbound_subscriptions,
        options: operation.options
      }

      next_state = %{
        state
        | next_publication_id: state.next_publication_id + 1,
          publications: Map.put(state.publications, publication.id, entry)
      }

      Transition.ok(next_state,
        events: [{:publication_started, publication}, %PublicationReady{publication: publication}],
        actions: announce_publication_actions(next_state.announce_streams, publication, :active)
      )
    else
      true -> Transition.error(state, :namespace_already_published)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %MOQX.Operation.AddTrack{} = operation) do
    with %{publication: publication} = entry <- state.publications[operation.publication.id],
         true <- publication == operation.publication,
         :ok <- validate_track_name(operation.track),
         false <- Map.has_key?(entry.tracks, operation.track),
         {:ok, track_options} <- published_track_options(operation.options) do
      track_ref = %MOQX.TrackRef{namespace: publication.namespace, track: operation.track}

      published_track = %MOQX.PublishedTrack{
        scope: state.handle_scope,
        id: state.next_published_track_id,
        publication: publication,
        track: track_ref,
        retention: track_options.retention
      }

      track_entry = Map.put(track_options, :track, published_track)
      entry = %{entry | tracks: Map.put(entry.tracks, operation.track, track_entry)}

      next_state = %{
        state
        | next_published_track_id: state.next_published_track_id + 1,
          publications: Map.put(state.publications, publication.id, entry)
      }

      Transition.ok(next_state, events: [{:track_added, published_track}])
    else
      nil -> Transition.error(state, :unknown_publication)
      false -> Transition.error(state, :unknown_publication)
      true -> Transition.error(state, :track_already_registered)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(
        %State{phase: :ready} = state,
        %MOQX.Operation.AcceptPublicationSubscription{published_track: nil} = operation
      ) do
    request = operation.request
    handle = request.handle

    with %MOQX.PublicationSubscriptionRequest.Handle{
           scope: scope,
           request_id: subscribe_id
         } <- handle,
         true <- scope == state.handle_scope,
         %{request: ^request} = pending <- state.pending_publisher_subscriptions[subscribe_id],
         {:ok, publication} <- fetch_publication(state, request.publication),
         nil <- publication.tracks[request.track.track],
         {:ok, track_options} <- published_track_options(operation.options) do
      published_track = %MOQX.PublishedTrack{
        scope: state.handle_scope,
        id: state.next_published_track_id,
        publication: request.publication,
        track: request.track,
        retention: track_options.retention
      }

      track_entry = Map.put(track_options, :track, published_track)

      publication = %{
        publication
        | tracks: Map.put(publication.tracks, request.track.track, track_entry)
      }

      state = %{
        state
        | next_published_track_id: state.next_published_track_id + 1,
          publications: Map.put(state.publications, request.publication.id, publication)
      }

      establish_publisher_subscription(
        state,
        pending,
        published_track,
        operation.reply_mode
      )
    else
      nil -> Transition.error(state, :stale_subscription_request)
      false -> Transition.error(state, :stale_subscription_request)
      {:error, reason} -> Transition.error(state, reason)
      _other -> Transition.error(state, :track_already_registered)
    end
  end

  def handle_operation(
        %State{phase: :ready} = state,
        %MOQX.Operation.AcceptPublicationSubscription{} = operation
      ) do
    request = operation.request
    handle = request.handle

    with %MOQX.PublicationSubscriptionRequest.Handle{
           scope: scope,
           request_id: subscribe_id
         } <- handle,
         true <- scope == state.handle_scope,
         %{request: ^request} = pending <- state.pending_publisher_subscriptions[subscribe_id],
         %MOQX.PublishedTrack{} = published_track <- operation.published_track,
         true <- published_track.track == request.track,
         {:ok, publication} <- fetch_publication(state, published_track.publication),
         %{track: ^published_track} <- publication.tracks[published_track.track.track] do
      establish_publisher_subscription(state, pending, published_track, operation.reply_mode)
    else
      nil -> Transition.error(state, :stale_subscription_request)
      false -> Transition.error(state, :subscription_request_track_mismatch)
      {:error, reason} -> Transition.error(state, reason)
      _other -> Transition.error(state, :stale_subscription_request)
    end
  end

  def handle_operation(
        %State{phase: :ready} = state,
        %MOQX.Operation.RejectPublicationSubscription{} = operation
      ) do
    request = operation.request
    handle = request.handle

    with %MOQX.PublicationSubscriptionRequest.Handle{
           scope: scope,
           request_id: subscribe_id
         } <- handle,
         true <- scope == state.handle_scope,
         %{request: ^request} = pending <- state.pending_publisher_subscriptions[subscribe_id],
         {:ok, error_code} <- rejection_error_code(operation.rejection.code) do
      next_state = %{
        state
        | pending_publisher_subscriptions:
            Map.delete(state.pending_publisher_subscriptions, subscribe_id)
      }

      Transition.ok(next_state,
        actions: [
          {:cancel_timer, {:publisher_subscription_decision, handle}},
          {:abort_stream_sending, {:peer_stream, pending.stream_id}, error_code}
        ]
      )
    else
      nil -> Transition.error(state, :stale_subscription_request)
      false -> Transition.error(state, :stale_subscription_request)
      {:error, reason} -> Transition.error(state, reason)
      _other -> Transition.error(state, :stale_subscription_request)
    end
  end

  def handle_operation(
        %State{phase: :ready} = state,
        %MOQX.Operation.PublishObject{} = operation
      ) do
    with :ok <- validate_published_track_scope(state, operation.track),
         {:ok, publication} <- fetch_publication(state, operation.track.publication),
         %{track: published_track} <- publication.tracks[operation.track.track.track],
         true <- published_track == operation.track,
         :ok <- validate_published_object(operation.object),
         {:ok, subscriptions, actions} <-
           publish_object_actions(
             state.publisher_subscriptions,
             published_track,
             operation.object
           ) do
      next_state = %{state | publisher_subscriptions: subscriptions}

      Transition.ok(next_state,
        events: [{:object_published, published_track}],
        actions: actions
      )
    else
      nil -> Transition.error(state, :unknown_published_track)
      false -> Transition.error(state, :unknown_published_track)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(
        %State{phase: :ready} = state,
        %MOQX.Operation.WithdrawTrack{} = operation
      ) do
    with :ok <- validate_published_track_scope(state, operation.track),
         {:ok, publication} <- fetch_publication(state, operation.track.publication),
         %{track: published_track} <- publication.tracks[operation.track.track.track],
         true <- published_track == operation.track,
         :ok <- validate_withdraw_track_options(operation.options) do
      {active, remaining_active} =
        Enum.split_with(state.publisher_subscriptions, fn {_id, entry} ->
          entry.track == published_track
        end)

      {pending, remaining_pending} =
        Enum.split_with(state.pending_publisher_subscriptions, fn {_id, entry} ->
          entry.request.track == published_track.track
        end)

      active = Enum.sort_by(active, &elem(&1, 0))
      pending = Enum.sort_by(pending, &elem(&1, 0))

      publication = %{
        publication
        | tracks: Map.delete(publication.tracks, operation.track.track.track)
      }

      next_state = %{
        state
        | publications: Map.put(state.publications, operation.track.publication.id, publication),
          publisher_subscriptions: Map.new(remaining_active),
          pending_publisher_subscriptions: Map.new(remaining_pending)
      }

      active_events =
        Enum.map(active, fn {subscribe_id, entry} ->
          %PublicationSubscriberLeft{
            track: entry.track,
            subscription: entry.handle,
            request_id: subscribe_id
          }
        end)

      pending_events =
        Enum.map(pending, fn {_subscribe_id, entry} ->
          %PublicationSubscriptionCancelled{
            request: entry.request,
            reason: :track_withdrawn
          }
        end)

      active_actions =
        Enum.flat_map(active, fn {_subscribe_id, entry} ->
          last_group = entry.last_group || entry.subscribe.group_start || 0
          response = Codec.encode_subscribe_response(%SubscribeEnd{group: last_group})

          active_group_abort_actions(entry) ++
            [{:send_stream, {:peer_stream, entry.stream_id}, response, [finish: true]}]
        end)

      pending_actions =
        Enum.flat_map(pending, fn {_subscribe_id, entry} ->
          cancel_decision_timer_actions(entry) ++
            [{:abort_stream_sending, {:peer_stream, entry.stream_id}, 0x10}]
        end)

      Transition.ok(next_state,
        events: [{:track_withdrawn, published_track}] ++ active_events ++ pending_events,
        actions: active_actions ++ pending_actions
      )
    else
      nil ->
        Transition.error(state, :unknown_published_track)

      false ->
        Transition.error(state, :unknown_published_track)

      {:error, :wrong_client_published_track} ->
        Transition.error(state, :wrong_client_published_track)

      {:error, reason}
      when reason in [:unsupported_completion_status, :invalid_track_completion] ->
        Transition.error(state, reason)

      {:error, _reason} ->
        Transition.error(state, :unknown_published_track)
    end
  end

  def handle_operation(
        %State{phase: :ready} = state,
        %MOQX.Operation.FinishPublishedSubscription{} = operation
      ) do
    handle = operation.subscription

    with %MOQX.PublishedSubscription{scope: scope, request_id: subscribe_id} <- handle,
         true <- scope == state.handle_scope,
         %{handle: ^handle} = entry <- state.publisher_subscriptions[subscribe_id],
         :ok <- validate_finish_subscription_options(operation.options) do
      last_group = entry.last_group || entry.subscribe.group_start || 0
      response = Codec.encode_subscribe_response(%SubscribeEnd{group: last_group})

      next_state = %{
        state
        | publisher_subscriptions: Map.delete(state.publisher_subscriptions, subscribe_id)
      }

      Transition.ok(next_state,
        events: [
          {:published_subscription_finished, handle},
          %PublicationSubscriberLeft{
            track: entry.track,
            subscription: handle,
            request_id: subscribe_id
          }
        ],
        actions:
          active_group_abort_actions(entry) ++
            [{:send_stream, {:peer_stream, entry.stream_id}, response, [finish: true]}]
      )
    else
      nil -> Transition.error(state, :unknown_published_subscription)
      false -> Transition.error(state, :unknown_published_subscription)
      {:error, reason} -> Transition.error(state, reason)
      _other -> Transition.error(state, :unknown_published_subscription)
    end
  end

  def handle_operation(
        %State{phase: :ready} = state,
        %MOQX.Operation.FinishPublication{} = operation
      ) do
    case fetch_publication(state, operation.publication) do
      {:ok, _entry} -> finish_publication(state, operation.publication)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(
        %State{phase: :ready} = state,
        %MOQX.Operation.UpdateSubscription{subscription: subscription, options: options}
      ) do
    with %{subscription: ^subscription} = entry <- state.subscriptions[subscription.id],
         {:ok, wire} <- update_options(options, entry.wire_options) do
      update = %SubscribeUpdate{
        subscriber_priority: wire.priority,
        subscriber_ordered: wire.ordered,
        subscriber_max_latency: wire.max_latency,
        group_start: wire.group_start,
        group_end: wire.group_end
      }

      next_entry = %{entry | wire_options: wire, options: Keyword.merge(entry.options, options)}
      next_state = put_subscription(state, subscription.id, next_entry)

      Transition.ok(next_state,
        events: [{:subscription_updated, subscription}],
        actions: [
          {:send_stream, {:subscribe, subscription.id}, Codec.encode_subscribe_update(update), []}
        ]
      )
    else
      nil -> Transition.error(state, :unknown_subscription)
      {:error, reason} -> Transition.error(state, reason)
      _other -> Transition.error(state, :unknown_subscription)
    end
  end

  def handle_operation(
        %State{phase: :ready} = state,
        %MOQX.Operation.Unsubscribe{subscription: subscription}
      ) do
    case state.subscriptions[subscription.id] do
      %{subscription: ^subscription} ->
        next_state = %{state | subscriptions: Map.delete(state.subscriptions, subscription.id)}

        Transition.ok(next_state,
          events: [{:subscription_ended, subscription}],
          actions: [
            {:send_stream, {:subscribe, subscription.id}, <<>>, [finish: true]}
          ]
        )

      _other ->
        Transition.error(state, :unknown_subscription)
    end
  end

  def handle_operation(%State{} = state, %MOQX.Operation.Close{}) do
    Transition.ok(%{state | phase: :closed},
      events: [:connection_ended],
      actions: [{:close_connection, 0}]
    )
  end

  def handle_operation(%State{} = state, _operation),
    do: Transition.error(state, :unsupported_operation)

  @impl true
  def capabilities(_state) do
    %Capabilities{
      operations:
        MapSet.new([
          :subscribe,
          :update_subscription,
          :publish,
          :add_track,
          :accept_publication_subscription,
          :publish_object,
          :withdraw_track,
          :finish_published_subscription,
          :finish_publication
        ]),
      delivery_modes: MapSet.new([:subgroup]),
      metadata: %{draft: :moq_lite_05}
    }
  end

  defp endpoint_path(%URI{} = endpoint) do
    path = endpoint.path || "/"
    if endpoint.query, do: path <> "?" <> endpoint.query, else: path
  end

  defp subscription_options(options) do
    with {:ok, priority} <- priority(options),
         {:ok, ordered} <- ordered(options),
         {:ok, max_latency} <- max_latency(options),
         {:ok, group_start, group_end} <- group_range(options),
         :ok <- unsupported_parameters(options),
         :ok <- reject_unknown_subscription_option(options) do
      {:ok, priority, ordered, max_latency, group_start, group_end}
    end
  end

  defp update_options(options, current) do
    with {:ok, priority} <- optional(options, :priority, current.priority, &priority/1),
         {:ok, ordered} <- optional(options, :group_order, current.ordered, &ordered/1),
         {:ok, max_latency} <-
           optional(options, :delivery_timeout, current.max_latency, &max_latency/1),
         {:ok, group_start, group_end} <- optional_group_range(options, current),
         :ok <- unsupported_parameters(options),
         :ok <- reject_unknown_subscription_option(options) do
      {:ok,
       %{
         priority: priority,
         ordered: ordered,
         max_latency: max_latency,
         group_start: group_start,
         group_end: group_end
       }}
    end
  end

  defp optional(options, key, current, validate) do
    if Keyword.has_key?(options, key), do: validate.(options), else: {:ok, current}
  end

  defp optional_group_range(options, current) do
    if Keyword.has_key?(options, :filter) or Keyword.has_key?(options, :start) do
      group_range(options)
    else
      {:ok, current.group_start, current.group_end}
    end
  end

  defp priority(options) do
    case Keyword.get(options, :priority, 128) do
      value when is_integer(value) and value in 0..255 -> {:ok, value}
      _other -> {:error, :invalid_priority}
    end
  end

  defp ordered(options) do
    case Keyword.get(options, :group_order, :descending) do
      :ascending -> {:ok, true}
      :descending -> {:ok, false}
      other -> {:error, {:unsupported_subscription_option, :group_order, other}}
    end
  end

  defp max_latency(options) do
    case Keyword.get(options, :delivery_timeout, 0) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:error, :invalid_delivery_timeout}
    end
  end

  defp group_range(options) do
    cond do
      Keyword.has_key?(options, :start) ->
        {:error, {:unsupported_subscription_option, :start, Keyword.fetch!(options, :start)}}

      not Keyword.has_key?(options, :filter) ->
        {:ok, nil, nil}

      true ->
        filter_range(Keyword.fetch!(options, :filter))
    end
  end

  defp filter_range(%MOQX.SubscriptionFilter{
         type: :absolute_start,
         start_location: {group, 0}
       })
       when is_integer(group) and group >= 0,
       do: {:ok, group, nil}

  defp filter_range(%MOQX.SubscriptionFilter{
         type: :absolute_range,
         start_location: {group, 0},
         end_group: ending
       })
       when is_integer(group) and group >= 0 and is_integer(ending) and ending >= group,
       do: {:ok, group, ending}

  defp filter_range(filter),
    do: {:error, {:unsupported_subscription_option, :filter, filter}}

  defp unsupported_parameters(options) do
    case Keyword.get(options, :parameters, []) do
      [] -> :ok
      parameters -> {:error, {:unsupported_subscription_option, :parameters, parameters}}
    end
  end

  defp reject_unknown_subscription_option(options) do
    reject_unknown_option(
      options,
      [:start, :filter, :priority, :group_order, :delivery_timeout, :parameters],
      :unsupported_subscription_option
    )
  end

  defp broadcast_path(namespace)
       when is_list(namespace) and namespace != [] do
    if Enum.all?(namespace, &(is_binary(&1) and &1 != "" and not String.contains?(&1, "/"))) do
      {:ok, Enum.join(namespace, "/")}
    else
      {:error, :invalid_namespace}
    end
  end

  defp broadcast_path(_namespace), do: {:error, :invalid_namespace}

  defp stream_bytes(type, payload) do
    [BinaryCodec.encode_varint(type), payload]
    |> IO.iodata_to_binary()
  end

  defp handle_peer_stream_data(state, stream_id, data) do
    case publisher_stream_entry(state, stream_id) do
      {collection, subscribe_id, entry} ->
        handle_subscribe_update(state, collection, subscribe_id, entry, stream_id, data)

      nil ->
        handle_new_peer_stream_data(state, stream_id, data)
    end
  end

  defp handle_new_peer_stream_data(state, stream_id, data) do
    buffer = Map.get(state.peer_stream_buffers, stream_id, <<>>) <> data
    dispatch_peer_request(state, stream_id, buffer, decode_peer_request(buffer))
  end

  defp dispatch_peer_request(state, stream_id, buffer, :more) do
    next_state = %{
      state
      | peer_stream_buffers: Map.put(state.peer_stream_buffers, stream_id, buffer)
    }

    Transition.ok(next_state)
  end

  defp dispatch_peer_request(state, stream_id, _buffer, {:ok, 0x6, payload, <<>>}) do
    with {:ok, track} <- Codec.decode_track(payload),
         {:ok, track_entry} <- fetch_published_track(state, track) do
      info = %TrackInfo{
        publisher_priority: track_entry.publisher_priority,
        publisher_ordered: track_entry.publisher_ordered,
        publisher_max_latency: track_entry.publisher_max_latency,
        timescale: track_entry.timescale
      }

      next_state = %{
        state
        | peer_stream_buffers: Map.delete(state.peer_stream_buffers, stream_id)
      }

      Transition.ok(next_state,
        actions: [
          {:send_stream, {:peer_stream, stream_id}, Codec.encode_track_info(info), [finish: true]}
        ]
      )
    else
      {:error, :track_not_found} ->
        next_state = %{
          state
          | peer_stream_buffers: Map.delete(state.peer_stream_buffers, stream_id)
        }

        Transition.ok(next_state,
          actions: [{:abort_stream_sending, {:peer_stream, stream_id}, 0x10}]
        )

      {:error, reason} ->
        Transition.error(state, reason)
    end
  end

  defp dispatch_peer_request(state, stream_id, _buffer, {:ok, 0x2, payload, trailing}) do
    case Codec.decode_subscribe(payload) do
      {:ok, subscribe} ->
        state
        |> handle_inbound_subscribe(stream_id, subscribe)
        |> apply_initial_subscribe_updates(subscribe.subscribe_id, stream_id, trailing)

      {:error, _reason} ->
        reject_peer_stream(state, stream_id, 2)
    end
  end

  defp dispatch_peer_request(state, stream_id, _buffer, {:ok, 0x1, payload, <<>>}) do
    case Codec.decode_announce_request(payload) do
      {:ok, announce} -> accept_announce_stream(state, stream_id, announce)
      {:error, _reason} -> reject_peer_stream(state, stream_id, 2)
    end
  end

  defp dispatch_peer_request(state, stream_id, _buffer, {:ok, _type, _payload, _trailing}),
    do: reject_peer_stream(state, stream_id, 2)

  defp handle_subscribe_update(state, collection, subscribe_id, entry, stream_id, data) do
    buffer = Map.get(state.peer_stream_buffers, stream_id, <<>>) <> data

    with {:ok, updates, rest} <- decode_subscribe_updates(buffer, []),
         {:ok, entry} <- apply_subscribe_updates(entry, updates) do
      entries = Map.put(Map.fetch!(state, collection), subscribe_id, entry)

      next_state =
        state
        |> Map.put(collection, entries)
        |> Map.put(:peer_stream_buffers, put_buffer(state.peer_stream_buffers, stream_id, rest))

      Transition.ok(next_state)
    else
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  defp publisher_stream_entry(state, stream_id) do
    Enum.find_value(
      [:publisher_subscriptions, :pending_publisher_subscriptions],
      &publisher_stream_entry(state, &1, stream_id)
    )
  end

  defp publisher_stream_entry(state, collection, stream_id) do
    case Enum.find(Map.fetch!(state, collection), fn {_subscribe_id, entry} ->
           entry.stream_id == stream_id
         end) do
      {subscribe_id, entry} -> {collection, subscribe_id, entry}
      nil -> nil
    end
  end

  defp apply_initial_subscribe_updates({:ok, transition}, _subscribe_id, _stream_id, <<>>),
    do: {:ok, transition}

  defp apply_initial_subscribe_updates(
         {:ok, transition},
         subscribe_id,
         stream_id,
         trailing
       ) do
    case publisher_stream_entry(transition.state, stream_id) do
      {collection, ^subscribe_id, entry} ->
        case handle_subscribe_update(
               transition.state,
               collection,
               subscribe_id,
               entry,
               stream_id,
               trailing
             ) do
          {:ok, %Transition{} = update_transition} ->
            {:ok,
             %Transition{
               update_transition
               | events: transition.events ++ update_transition.events,
                 actions: transition.actions ++ update_transition.actions
             }}

          error ->
            error
        end

      _other ->
        {:ok, transition}
    end
  end

  defp apply_initial_subscribe_updates(error, _subscribe_id, _stream_id, _trailing), do: error

  defp decode_subscribe_updates(<<>>, updates), do: {:ok, Enum.reverse(updates), <<>>}

  defp decode_subscribe_updates(buffer, updates) do
    case complete_framed_message(buffer) do
      {:ok, encoded, trailing} ->
        case Codec.decode_subscribe_update(encoded) do
          {:ok, update} -> decode_subscribe_updates(trailing, [update | updates])
          {:error, _reason} -> {:error, :invalid_subscribe_update}
        end

      :more ->
        {:ok, Enum.reverse(updates), buffer}
    end
  end

  defp apply_subscribe_updates(entry, updates) do
    Enum.reduce_while(updates, {:ok, entry}, fn update, {:ok, entry} ->
      subscribe = %{
        entry.subscribe
        | subscriber_priority: update.subscriber_priority,
          subscriber_ordered: update.subscriber_ordered,
          subscriber_max_latency: update.subscriber_max_latency,
          group_start: update.group_start,
          group_end: update.group_end
      }

      case inbound_subscription_filter(subscribe) do
        {:ok, _filter} -> {:cont, {:ok, %{entry | subscribe: subscribe}}}
        {:error, _reason} -> {:halt, {:error, :invalid_subscribe_update}}
      end
    end)
  end

  defp put_buffer(buffers, stream_id, <<>>), do: Map.delete(buffers, stream_id)
  defp put_buffer(buffers, stream_id, buffer), do: Map.put(buffers, stream_id, buffer)

  defp complete_framed_message(buffer) do
    case BinaryCodec.decode_varint(buffer) do
      {:ok, length, rest} when byte_size(rest) >= length ->
        prefix_size = byte_size(buffer) - byte_size(rest)
        encoded_size = prefix_size + length
        <<encoded::binary-size(^encoded_size), trailing::binary>> = buffer
        {:ok, encoded, trailing}

      _incomplete ->
        :more
    end
  end

  defp handle_peer_unidirectional_data(state, stream_id, data) do
    case state.group_decoders[stream_id] do
      %GroupDecoder{} = decoder ->
        push_group_data(state, stream_id, decoder, data)

      nil ->
        buffer = Map.get(state.peer_stream_buffers, stream_id, <<>>) <> data

        case BinaryCodec.decode_varint(buffer) do
          {:ok, 0x0, _rest} ->
            state = %{
              state
              | peer_stream_buffers: Map.delete(state.peer_stream_buffers, stream_id)
            }

            push_group_data(state, stream_id, %GroupDecoder{}, buffer)

          {:ok, 0x1, _rest} ->
            decode_peer_setup(state, stream_id, buffer)

          {:ok, _unknown, _rest} ->
            Transition.ok(
              %{state | peer_stream_buffers: Map.delete(state.peer_stream_buffers, stream_id)},
              actions: [{:abort_stream_receiving, {:peer_stream, stream_id}, 2}]
            )

          {:error, :incomplete} ->
            next_state = %{
              state
              | peer_stream_buffers: Map.put(state.peer_stream_buffers, stream_id, buffer)
            }

            Transition.ok(next_state)
        end
    end
  end

  defp push_group_data(state, stream_id, decoder, data) do
    with {:ok, decoder, frames} <- GroupDecoder.push(decoder, data),
         {:ok, state, events} <- received_frame_events(state, frames) do
      next_state = %{
        state
        | group_decoders: Map.put(state.group_decoders, stream_id, decoder)
      }

      Transition.ok(next_state, events: events)
    else
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  defp decode_peer_setup(%{peer_setup: nil} = state, stream_id, buffer) do
    case decode_peer_request(buffer) do
      {:ok, 0x1, payload, <<>>} ->
        with {:ok, setup} <- Codec.decode_setup(payload),
             :ok <- validate_server_setup(setup) do
          next_state = %{
            state
            | peer_setup: setup,
              peer_stream_buffers: Map.delete(state.peer_stream_buffers, stream_id)
          }

          Transition.ok(next_state)
        else
          {:error, reason} -> protocol_violation(state, reason)
        end

      :more ->
        next_state = %{
          state
          | peer_stream_buffers: Map.put(state.peer_stream_buffers, stream_id, buffer)
        }

        Transition.ok(next_state)

      _other ->
        protocol_violation(state, :invalid_setup_stream)
    end
  end

  defp decode_peer_setup(state, _stream_id, _buffer),
    do: protocol_violation(state, :duplicate_setup_stream)

  defp validate_server_setup(%Setup{path: nil, role: :both}), do: :ok
  defp validate_server_setup(%Setup{}), do: {:error, :peer_setup_contains_client_parameters}

  defp decode_peer_request(buffer) do
    with {:ok, type, rest} <- BinaryCodec.decode_varint(buffer),
         {:ok, length, after_length} <- BinaryCodec.decode_varint(rest),
         true <- byte_size(after_length) >= length do
      <<_payload::binary-size(^length), trailing::binary>> = after_length
      length_size = byte_size(rest) - byte_size(after_length)
      framed = binary_part(rest, 0, length_size + length)
      {:ok, type, framed, trailing}
    else
      _incomplete -> :more
    end
  end

  defp fetch_published_track(state, %Track{} = track) do
    Enum.find_value(state.publications, {:error, :track_not_found}, fn {_id, entry} ->
      with {:ok, path} <- broadcast_path(entry.publication.namespace),
           true <- path == track.broadcast_path,
           %{track: _published_track} = track_entry <- entry.tracks[track.track_name] do
        {:ok, track_entry}
      else
        _other -> nil
      end
    end)
  end

  defp publication_namespace?(state, namespace) do
    Enum.any?(state.publications, fn {_id, entry} -> entry.publication.namespace == namespace end)
  end

  defp finish_publication(state, publication) do
    {active, remaining_active} =
      Enum.split_with(state.publisher_subscriptions, fn {_id, entry} ->
        entry.track.publication == publication
      end)

    {pending, remaining_pending} =
      Enum.split_with(state.pending_publisher_subscriptions, fn {_id, entry} ->
        entry.request.publication == publication
      end)

    active = Enum.sort_by(active, &elem(&1, 0))
    pending = Enum.sort_by(pending, &elem(&1, 0))

    next_state = %{
      state
      | publications: Map.delete(state.publications, publication.id),
        publisher_subscriptions: Map.new(remaining_active),
        pending_publisher_subscriptions: Map.new(remaining_pending)
    }

    Transition.ok(next_state,
      events:
        publication_finish_events(active, pending) ++ [{:publication_finished, publication}],
      actions:
        publication_finish_actions(active, pending) ++
          announce_publication_actions(state.announce_streams, publication, :ended)
    )
  end

  defp publication_finish_events(active, pending) do
    Enum.map(active, fn {subscribe_id, entry} ->
      %PublicationSubscriberLeft{
        track: entry.track,
        subscription: entry.handle,
        request_id: subscribe_id
      }
    end) ++
      Enum.map(pending, fn {_subscribe_id, entry} ->
        %PublicationSubscriptionCancelled{
          request: entry.request,
          reason: :publication_finished
        }
      end)
  end

  defp publication_finish_actions(active, pending) do
    Enum.flat_map(active, fn {_subscribe_id, entry} ->
      last_group = entry.last_group || entry.subscribe.group_start || 0
      response = Codec.encode_subscribe_response(%SubscribeEnd{group: last_group})

      active_group_abort_actions(entry) ++
        [{:send_stream, {:peer_stream, entry.stream_id}, response, [finish: true]}]
    end) ++
      Enum.flat_map(pending, fn {_subscribe_id, entry} ->
        cancel_decision_timer_actions(entry) ++
          [{:abort_stream_sending, {:peer_stream, entry.stream_id}, 0}]
      end)
  end

  defp accept_announce_stream(state, stream_id, announce) do
    publications = matching_publications(state.publications, announce.broadcast_path_prefix)

    ok = %AnnounceOk{hop_id: 0, active_count: length(publications)}

    broadcasts =
      Enum.map(publications, fn publication ->
        announce_broadcast(publication, announce.broadcast_path_prefix, :active)
      end)

    bytes =
      [Codec.encode_announce_ok(ok), Enum.map(broadcasts, &Codec.encode_announce_broadcast/1)]
      |> IO.iodata_to_binary()

    next_state = %{
      state
      | peer_stream_buffers: Map.delete(state.peer_stream_buffers, stream_id),
        announce_streams: Map.put(state.announce_streams, stream_id, announce)
    }

    Transition.ok(next_state,
      actions: [{:send_stream, {:peer_stream, stream_id}, bytes, []}]
    )
  end

  defp matching_publications(publications, prefix) do
    publications
    |> Enum.sort_by(fn {id, _entry} -> id end)
    |> Enum.flat_map(fn {_id, entry} ->
      {:ok, path} = broadcast_path(entry.publication.namespace)
      if String.starts_with?(path, prefix), do: [entry.publication], else: []
    end)
  end

  defp announce_publication_actions(announce_streams, publication, status) do
    announce_streams
    |> Enum.sort_by(fn {stream_id, _announce} -> stream_id end)
    |> Enum.flat_map(fn {stream_id, announce} ->
      {:ok, path} = broadcast_path(publication.namespace)

      if String.starts_with?(path, announce.broadcast_path_prefix) do
        bytes =
          publication
          |> announce_broadcast(announce.broadcast_path_prefix, status)
          |> Codec.encode_announce_broadcast()

        [{:send_stream, {:peer_stream, stream_id}, bytes, []}]
      else
        []
      end
    end)
  end

  defp announce_broadcast(publication, prefix, status) do
    {:ok, path} = broadcast_path(publication.namespace)
    suffix_size = byte_size(path) - byte_size(prefix)

    %AnnounceBroadcast{
      status: status,
      path_suffix: binary_part(path, byte_size(prefix), suffix_size),
      hop_ids: []
    }
  end

  defp fetch_publication(state, %MOQX.Publication{} = publication) do
    case state.publications[publication.id] do
      %{publication: ^publication} = entry -> {:ok, entry}
      _other -> {:error, :unknown_publication}
    end
  end

  defp validate_published_track_scope(
         %State{handle_scope: scope},
         %MOQX.PublishedTrack{scope: scope}
       ),
       do: :ok

  defp validate_published_track_scope(_state, %MOQX.PublishedTrack{}),
    do: {:error, :wrong_client_published_track}

  defp validate_withdraw_track_options(options) when is_list(options) do
    cond do
      not Keyword.keyword?(options) ->
        {:error, :invalid_track_completion}

      Enum.any?(Keyword.keys(options), &(&1 not in [:status, :reason])) ->
        {:error, :invalid_track_completion}

      Keyword.get(options, :status, :track_ended) != :track_ended ->
        {:error, :unsupported_completion_status}

      not is_binary(Keyword.get(options, :reason, "track ended")) ->
        {:error, :invalid_track_completion}

      byte_size(Keyword.get(options, :reason, "track ended")) > 1_024 ->
        {:error, :invalid_track_completion}

      true ->
        :ok
    end
  end

  defp validate_withdraw_track_options(_options), do: {:error, :invalid_track_completion}

  defp establish_publisher_subscription(state, pending, published_track, reply_mode) do
    subscribe_id = pending.subscribe.subscribe_id

    published_subscription = %MOQX.PublishedSubscription{
      scope: state.handle_scope,
      request_id: subscribe_id
    }

    active = %{
      handle: published_subscription,
      track: published_track,
      request: pending.request,
      stream_id: pending.stream_id,
      subscribe: pending.subscribe,
      accepted?: false,
      last_group: nil,
      active_group: nil
    }

    next_state = %{
      state
      | pending_publisher_subscriptions:
          Map.delete(state.pending_publisher_subscriptions, subscribe_id),
        publisher_subscriptions: Map.put(state.publisher_subscriptions, subscribe_id, active)
    }

    reply_events =
      case reply_mode do
        :reactive ->
          [{:reactive_subscription_accepted, published_track, published_subscription}]

        :none ->
          []

        _other ->
          [{:published_subscription_accepted, published_subscription}]
      end

    actions =
      cancel_decision_timer_actions(pending)

    Transition.ok(next_state,
      events:
        reply_events ++
          [
            %PublicationSubscriberJoined{
              track: published_track,
              subscription: published_subscription,
              request_id: subscribe_id
            }
          ],
      actions: actions
    )
  end

  defp cancel_decision_timer_actions(%{timer?: true} = pending) do
    [{:cancel_timer, {:publisher_subscription_decision, pending.request.handle}}]
  end

  defp cancel_decision_timer_actions(_pending), do: []

  defp inbound_subscription_options(options) do
    case Keyword.get(options, :inbound_subscriptions, :automatic) do
      :automatic ->
        {:ok, %{mode: :automatic}}

      :controlled ->
        timeout = Keyword.get(options, :subscription_decision_timeout, 5_000)
        max_pending = Keyword.get(options, :max_pending_subscriptions, 128)

        if is_integer(timeout) and timeout >= 0 and is_integer(max_pending) and max_pending > 0 do
          {:ok, %{mode: :controlled, timeout: timeout, max_pending: max_pending}}
        else
          {:error, :invalid_inbound_subscription_options}
        end

      _other ->
        {:error, :invalid_inbound_subscription_options}
    end
  end

  defp rejection_error_code(:internal_error), do: {:ok, 0}
  defp rejection_error_code(:unauthorized), do: {:ok, 1}
  defp rejection_error_code(:timeout), do: {:ok, 2}
  defp rejection_error_code(:not_supported), do: {:ok, 3}
  defp rejection_error_code(:malformed_auth_token), do: {:ok, 4}
  defp rejection_error_code(:expired_auth_token), do: {:ok, 5}
  defp rejection_error_code(:track_does_not_exist), do: {:ok, 0x10}
  defp rejection_error_code(:invalid_range), do: {:ok, 0x11}
  defp rejection_error_code(_code), do: {:error, :invalid_subscription_rejection}

  defp handle_inbound_subscribe(state, stream_id, subscribe) do
    with false <- publisher_subscription_id?(state, subscribe.subscribe_id),
         {:ok, publication_entry} <- fetch_publication_by_path(state, subscribe.broadcast_path),
         {:ok, filter} <- inbound_subscription_filter(subscribe) do
      case publication_entry.inbound_subscriptions do
        %{mode: :controlled} = policy ->
          pend_controlled_subscription(
            state,
            publication_entry,
            stream_id,
            subscribe,
            filter,
            policy
          )

        %{mode: :automatic} ->
          automatically_accept_subscription(
            state,
            publication_entry,
            stream_id,
            subscribe,
            filter
          )
      end
    else
      true -> reject_peer_stream(state, stream_id, 2)
      {:error, :publication_not_found} -> reject_peer_stream(state, stream_id, 0x10)
      {:error, :invalid_subscription_range} -> reject_peer_stream(state, stream_id, 0x11)
      {:error, _reason} -> reject_peer_stream(state, stream_id, 2)
    end
  end

  defp pend_controlled_subscription(state, publication, stream_id, subscribe, filter, policy) do
    if pending_subscription_count(state, publication.publication.id) >= policy.max_pending do
      reject_peer_stream(state, stream_id, 2)
    else
      request = publication_subscription_request(state, publication, subscribe, filter)

      pending = %{
        request: request,
        stream_id: stream_id,
        subscribe: subscribe,
        publication_id: publication.publication.id,
        timer?: true
      }

      next_state = put_pending_subscription(state, stream_id, subscribe.subscribe_id, pending)

      Transition.ok(next_state,
        events: [%PublicationSubscriptionRequested{request: request}],
        actions: [
          {:start_timer, {:publisher_subscription_decision, request.handle}, policy.timeout}
        ]
      )
    end
  end

  defp publication_subscription_request(state, publication, subscribe, filter) do
    handle = %MOQX.PublicationSubscriptionRequest.Handle{
      scope: state.handle_scope,
      request_id: subscribe.subscribe_id
    }

    %MOQX.PublicationSubscriptionRequest{
      handle: handle,
      publication: publication.publication,
      track: %MOQX.TrackRef{
        namespace: publication.publication.namespace,
        track: subscribe.track_name
      },
      subscriber_priority: subscribe.subscriber_priority,
      group_order: if(subscribe.subscriber_ordered, do: :ascending, else: :descending),
      forward: true,
      filter: filter,
      parameters: []
    }
  end

  defp put_pending_subscription(state, stream_id, subscribe_id, pending) do
    %{
      state
      | peer_stream_buffers: Map.delete(state.peer_stream_buffers, stream_id),
        pending_publisher_subscriptions:
          Map.put(state.pending_publisher_subscriptions, subscribe_id, pending)
    }
  end

  defp publisher_subscription_id?(state, subscribe_id) do
    Map.has_key?(state.pending_publisher_subscriptions, subscribe_id) or
      Map.has_key?(state.publisher_subscriptions, subscribe_id)
  end

  defp automatically_accept_subscription(state, publication, stream_id, subscribe, filter) do
    case publication.tracks[subscribe.track_name] do
      %{track: published_track} ->
        handle = %MOQX.PublicationSubscriptionRequest.Handle{
          scope: state.handle_scope,
          request_id: subscribe.subscribe_id
        }

        request = %MOQX.PublicationSubscriptionRequest{
          handle: handle,
          publication: publication.publication,
          track: published_track.track,
          subscriber_priority: subscribe.subscriber_priority,
          group_order: if(subscribe.subscriber_ordered, do: :ascending, else: :descending),
          forward: true,
          filter: filter,
          parameters: []
        }

        pending = %{
          request: request,
          stream_id: stream_id,
          subscribe: subscribe,
          publication_id: publication.publication.id,
          timer?: false
        }

        state = %{
          state
          | peer_stream_buffers: Map.delete(state.peer_stream_buffers, stream_id),
            pending_publisher_subscriptions:
              Map.put(
                state.pending_publisher_subscriptions,
                subscribe.subscribe_id,
                pending
              )
        }

        establish_publisher_subscription(state, pending, published_track, :none)

      nil ->
        Transition.ok(state,
          actions: [{:abort_stream_sending, {:peer_stream, stream_id}, 0x10}]
        )
    end
  end

  defp fetch_publication_by_path(state, path) do
    Enum.find_value(state.publications, {:error, :publication_not_found}, fn {_id, entry} ->
      case broadcast_path(entry.publication.namespace) do
        {:ok, ^path} -> {:ok, entry}
        _other -> nil
      end
    end)
  end

  defp inbound_subscription_filter(%Subscribe{group_start: nil, group_end: nil}),
    do: {:ok, %MOQX.SubscriptionFilter{type: :largest_object}}

  defp inbound_subscription_filter(%Subscribe{group_start: first, group_end: nil})
       when not is_nil(first),
       do: {:ok, %MOQX.SubscriptionFilter{type: :absolute_start, start_location: {first, 0}}}

  defp inbound_subscription_filter(%Subscribe{group_start: first, group_end: last})
       when not is_nil(first) and not is_nil(last) and first <= last,
       do:
         {:ok,
          %MOQX.SubscriptionFilter{
            type: :absolute_range,
            start_location: {first, 0},
            end_group: last
          }}

  defp inbound_subscription_filter(_subscribe), do: {:error, :invalid_subscription_range}

  defp pending_subscription_count(state, publication_id) do
    Enum.count(state.pending_publisher_subscriptions, fn {_id, pending} ->
      pending.publication_id == publication_id
    end)
  end

  defp finish_inbound_subscription(state, stream_id, event, metadata) do
    case Enum.find(state.publisher_subscriptions, fn {_id, entry} ->
           entry.stream_id == stream_id
         end) do
      {subscribe_id, entry} ->
        actions = inbound_subscription_finish_actions(entry, event, metadata)

        next_state = %{
          state
          | publisher_subscriptions: Map.delete(state.publisher_subscriptions, subscribe_id),
            peer_stream_buffers: Map.delete(state.peer_stream_buffers, stream_id)
        }

        Transition.ok(next_state,
          events: [
            %PublicationSubscriberLeft{
              track: entry.track,
              subscription: entry.handle,
              request_id: subscribe_id
            }
          ],
          actions: actions
        )

      nil ->
        finish_pending_inbound_subscription(state, stream_id, event, metadata)
    end
  end

  defp finish_pending_inbound_subscription(state, stream_id, event, metadata) do
    case Enum.find(state.pending_publisher_subscriptions, fn {_id, entry} ->
           entry.stream_id == stream_id
         end) do
      {subscribe_id, entry} ->
        next_state = %{
          state
          | pending_publisher_subscriptions:
              Map.delete(state.pending_publisher_subscriptions, subscribe_id),
            peer_stream_buffers: Map.delete(state.peer_stream_buffers, stream_id)
        }

        Transition.ok(next_state,
          events: [
            %PublicationSubscriptionCancelled{request: entry.request, reason: :unsubscribed}
          ],
          actions: [
            {:cancel_timer, {:publisher_subscription_decision, entry.request.handle}}
            | mirror_peer_termination(stream_id, event, metadata)
          ]
        )

      nil ->
        cond do
          Map.has_key?(state.announce_streams, stream_id) ->
            Transition.ok(
              %{state | announce_streams: Map.delete(state.announce_streams, stream_id)},
              actions: mirror_peer_termination(stream_id, event, metadata)
            )

          Map.has_key?(state.peer_stream_buffers, stream_id) ->
            Transition.error(state, :incomplete_peer_stream)

          true ->
            Transition.ok(state)
        end
    end
  end

  defp inbound_subscription_finish_actions(entry, :peer_finished_sending, _metadata) do
    active_group_abort_actions(entry) ++
      [{:send_stream, {:peer_stream, entry.stream_id}, <<>>, [finish: true]}]
  end

  defp inbound_subscription_finish_actions(entry, event, metadata) do
    active_group_abort_actions(entry) ++
      mirror_peer_termination(entry.stream_id, event, metadata)
  end

  defp active_group_abort_actions(%{active_group: nil}), do: []

  defp active_group_abort_actions(%{active_group: group, request: request}) do
    [{:abort_stream_sending, {:group, request.handle.request_id, group.id}, 0}]
  end

  defp clear_active_publication_group(state, subscribe_id, group_id) do
    case state.publisher_subscriptions[subscribe_id] do
      %{active_group: %{id: ^group_id}} = entry ->
        subscriptions =
          Map.put(state.publisher_subscriptions, subscribe_id, %{entry | active_group: nil})

        Transition.ok(%{state | publisher_subscriptions: subscriptions})

      _other ->
        Transition.ok(state)
    end
  end

  defp validate_track_name(track) when is_binary(track) and track != "", do: :ok
  defp validate_track_name(_track), do: {:error, :invalid_track_name}

  defp published_track_options(options) do
    retention = Keyword.get(options, :retention, :live)
    delivery = Keyword.get(options, :delivery, :subgroup)
    timescale = Keyword.get(options, :timescale)
    priority = Keyword.get(options, :publisher_priority, 128)
    max_latency = Keyword.get(options, :publisher_max_latency, 0)

    with :ok <- reject_unknown_published_track_option(options),
         :ok <- validate_retention(retention),
         :ok <- validate_publisher_delivery(delivery),
         :ok <- validate_timescale(timescale),
         :ok <- validate_publisher_priority(priority),
         :ok <- validate_publisher_max_latency(max_latency) do
      {:ok,
       %{
         retention: retention,
         delivery: delivery,
         timescale: timescale,
         publisher_priority: priority,
         publisher_ordered: false,
         publisher_max_latency: max_latency
       }}
    end
  end

  defp reject_unknown_published_track_option(options) do
    reject_unknown_option(
      options,
      [:retention, :delivery, :timescale, :publisher_priority, :publisher_max_latency],
      :unsupported_published_track_option
    )
  end

  defp reject_unknown_option(options, allowed, error_tag) do
    case Enum.find(options, fn {key, _value} -> key not in allowed end) do
      {key, value} -> {:error, {error_tag, key, value}}
      nil -> :ok
    end
  end

  defp validate_retention(retention) when retention in [:live, :latest, :all], do: :ok
  defp validate_retention(_retention), do: {:error, :invalid_retention}

  defp validate_publisher_delivery(:subgroup), do: :ok

  defp validate_publisher_delivery(delivery),
    do: {:error, {:unsupported_published_track_option, :delivery, delivery}}

  defp validate_timescale(value)
       when is_integer(value) and value > 0 and value <= @max_varint,
       do: :ok

  defp validate_timescale(_value), do: {:error, :invalid_timescale}

  defp validate_publisher_priority(value) when is_integer(value) and value in 0..255, do: :ok
  defp validate_publisher_priority(_value), do: {:error, :invalid_publisher_priority}

  defp validate_publisher_max_latency(value)
       when is_integer(value) and value >= 0 and value <= @max_varint,
       do: :ok

  defp validate_publisher_max_latency(_value),
    do: {:error, :invalid_publisher_max_latency}

  defp validate_published_object(%MOQX.Object{} = object) do
    with :ok <- validate_non_negative(object.group_id, :invalid_group_id),
         :ok <- validate_non_negative(object.object_id, :invalid_object_id),
         :ok <- validate_non_negative(object.timestamp, :invalid_timestamp),
         :ok <- validate_payload(object.payload) do
      validate_object_status(object.status)
    end
  end

  defp validate_non_negative(value, _reason) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(_value, reason), do: {:error, reason}

  defp validate_payload(payload) when is_binary(payload), do: :ok
  defp validate_payload(_payload), do: {:error, :invalid_payload}

  defp validate_object_status(nil), do: :ok
  defp validate_object_status(_status), do: {:error, :unsupported_object_status}

  defp validate_finish_subscription_options([]), do: :ok

  defp validate_finish_subscription_options(options),
    do: {:error, {:unsupported_finish_subscription_options, options}}

  defp publish_object_actions(subscriptions, track, object) do
    subscriptions
    |> Enum.sort_by(fn {subscribe_id, _entry} -> subscribe_id end)
    |> Enum.reduce_while({:ok, subscriptions, []}, fn {subscribe_id, entry},
                                                      {:ok, subscriptions, actions} ->
      publish_object_for_entry(
        subscribe_id,
        entry,
        track,
        object,
        subscriptions,
        actions
      )
    end)
  end

  defp publish_object_for_entry(subscribe_id, entry, track, object, subscriptions, actions) do
    if entry.track == track and object_matches_subscription?(object, entry.subscribe) do
      publish_matching_object(subscribe_id, entry, object, subscriptions, actions)
    else
      {:cont, {:ok, subscriptions, actions}}
    end
  end

  defp publish_matching_object(subscribe_id, entry, object, subscriptions, actions) do
    {entry, prefix_actions} = resolve_subscription_actions(entry, object)

    case publication_object_action(subscribe_id, entry, object) do
      {:ok, entry, action} ->
        {:cont,
         {:ok, Map.put(subscriptions, subscribe_id, entry), actions ++ prefix_actions ++ [action]}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp resolve_subscription_actions(%{accepted?: false} = entry, object) do
    action =
      {:send_stream, {:peer_stream, entry.stream_id},
       Codec.encode_subscribe_response(%SubscribeOk{group: object.group_id}), []}

    {%{entry | accepted?: true}, [action]}
  end

  defp resolve_subscription_actions(%{last_group: last_group} = entry, object)
       when is_integer(last_group) and object.group_id > last_group + 1 do
    drop = %SubscribeDrop{
      group_start: last_group + 1,
      group_end: object.group_id - 1,
      error_code: 0
    }

    action =
      {:send_stream, {:peer_stream, entry.stream_id}, Codec.encode_subscribe_response(drop), []}

    {entry, [action]}
  end

  defp resolve_subscription_actions(entry, _object), do: {entry, []}

  defp publication_object_action(subscribe_id, %{active_group: nil} = entry, object)
       when object.object_id == 0 do
    group = %Group{subscribe_id: subscribe_id, group_sequence: object.group_id}
    frame = %Frame{timestamp_delta: object.timestamp, payload: object.payload}
    key = {:group, subscribe_id, object.group_id}
    bytes = stream_bytes(0x0, [Codec.encode_group(group), Codec.encode_frame(frame)])
    finish? = object.end_of_group? == true

    entry = %{
      entry
      | active_group:
          if(finish?,
            do: nil,
            else: %{id: object.group_id, timestamp: object.timestamp, next_id: 1}
          ),
        last_group: object.group_id
    }

    {:ok, entry, {:open_stream, key, [direction: :unidirectional], bytes, [finish: finish?]}}
  end

  defp publication_object_action(_subscribe_id, %{active_group: nil}, _object),
    do: {:error, :group_must_start_at_object_zero}

  defp publication_object_action(subscribe_id, %{active_group: active} = entry, object)
       when active.id == object.group_id and active.next_id == object.object_id do
    frame = %Frame{
      timestamp_delta: object.timestamp - active.timestamp,
      payload: object.payload
    }

    finish? = object.end_of_group? == true

    entry = %{
      entry
      | active_group:
          if(finish?,
            do: nil,
            else: %{active | timestamp: object.timestamp, next_id: object.object_id + 1}
          ),
        last_group: object.group_id
    }

    {:ok, entry,
     {:send_stream, {:group, subscribe_id, object.group_id}, Codec.encode_frame(frame),
      [finish: finish?]}}
  end

  defp publication_object_action(_subscribe_id, _entry, _object),
    do: {:error, :invalid_group_sequence}

  defp object_matches_subscription?(object, %Subscribe{group_start: first, group_end: last}) do
    (is_nil(first) or object.group_id >= first) and (is_nil(last) or object.group_id <= last)
  end

  defp reduce_subscribe_responses(entry, responses) do
    Enum.reduce_while(responses, {:ok, entry}, fn
      %SubscribeOk{group: group}, {:ok, %{accepted_group: nil} = entry} ->
        {:cont, {:ok, %{entry | accepted_group: group}}}

      %SubscribeOk{}, {:ok, _entry} ->
        {:halt, {:error, :duplicate_subscribe_ok}}

      %SubscribeEnd{group: group}, {:ok, %{subscribe_end: nil} = entry} ->
        {:cont, {:ok, %{entry | subscribe_end: group}}}

      %SubscribeEnd{}, {:ok, _entry} ->
        {:halt, {:error, :duplicate_subscribe_end}}

      %SubscribeDrop{group_start: first, group_end: last}, {:ok, entry}
      when first <= last ->
        {:cont, {:ok, account_range(entry, first, last)}}

      %SubscribeDrop{}, {:ok, _entry} ->
        {:halt, {:error, :invalid_subscribe_drop}}

      _other, {:ok, entry} ->
        {:cont, {:ok, entry}}
    end)
  end

  defp accept_if_ready(state, subscribe_id, entry) do
    {entry, acceptance_events} =
      case entry do
        %{accepted?: false, accepted_group: group, track_info: %MOQX.TrackInfo{}}
        when not is_nil(group) ->
          {%{entry | accepted?: true},
           [%SubscriptionAccepted{subscription: entry.subscription, track_info: entry.track_info}]}

        _other ->
          {entry, []}
      end

    {entry, pending_events} =
      if entry.accepted? do
        {%{entry | pending_group_events: []}, Enum.reverse(entry.pending_group_events)}
      else
        {entry, []}
      end

    next_state = put_subscription(state, subscribe_id, entry)
    events = acceptance_events ++ pending_events

    if entry.accepted? and entry.subscribe_finished? do
      next_state
      |> finish_subscription(subscribe_id)
      |> prepend_transition_events(events)
    else
      Transition.ok(next_state, events: events)
    end
  end

  defp put_subscription(state, subscribe_id, entry) do
    %{state | subscriptions: Map.put(state.subscriptions, subscribe_id, entry)}
  end

  defp received_frame_events(state, frames) do
    Enum.reduce_while(frames, {:ok, state, []}, &receive_frame/2)
    |> case do
      {:ok, state, events} -> {:ok, state, Enum.reverse(events)}
      error -> error
    end
  end

  defp receive_frame(frame, {:ok, state, events}) do
    case state.subscriptions[frame.subscribe_id] do
      %{subscription: subscription} = entry ->
        event = object_received_event(frame, subscription)
        receive_frame(state, entry, frame.subscribe_id, event, events)

      _other ->
        {:halt, {:error, :unknown_group_subscription}}
    end
  end

  defp receive_frame(state, %{accepted?: true}, _subscribe_id, event, events) do
    {:cont, {:ok, state, [event | events]}}
  end

  defp receive_frame(state, entry, subscribe_id, event, events) do
    entry = Map.update!(entry, :pending_group_events, &[event | &1])
    {:cont, {:ok, put_subscription(state, subscribe_id, entry), events}}
  end

  defp object_received_event(frame, subscription) do
    object = %MOQX.Object{
      subscription: subscription,
      group_id: frame.group_sequence,
      object_id: frame.object_id,
      timestamp: frame.timestamp,
      payload: frame.payload
    }

    %ObjectReceived{object: object}
  end

  defp finish_group_stream(state, stream_id, decoder) do
    with :ok <- GroupDecoder.complete(decoder),
         %{subscription: subscription} <- state.subscriptions[decoder.group.subscribe_id] do
      event = %SubgroupEnded{
        subscription: subscription,
        group_id: decoder.group.group_sequence,
        subgroup_id: nil,
        outcome: :complete,
        end_of_group?: true
      }

      entry =
        state.subscriptions
        |> Map.fetch!(decoder.group.subscribe_id)
        |> account_range(decoder.group.group_sequence, decoder.group.group_sequence)
        |> Map.update!(:processed_group_streams, &(&1 + 1))

      next_state =
        state
        |> put_subscription(decoder.group.subscribe_id, entry)
        |> Map.put(:group_decoders, Map.delete(state.group_decoders, stream_id))

      emit_or_queue_group_event(next_state, decoder.group.subscribe_id, event)
    else
      {:error, reason} -> Transition.error(state, reason)
      nil -> Transition.error(state, :unknown_group_subscription)
    end
  end

  defp reset_group_stream(state, stream_id, decoder, event, metadata) do
    case state.subscriptions[decoder.group.subscribe_id] do
      %{subscription: subscription} = entry ->
        error_code = if event == :peer_aborted_sending, do: metadata[:error_code]

        ended = %SubgroupEnded{
          subscription: subscription,
          group_id: decoder.group.group_sequence,
          subgroup_id: nil,
          outcome: if(event == :peer_aborted_sending, do: :reset, else: :closed),
          error_code: error_code,
          end_of_group?: false
        }

        entry =
          entry
          |> account_range(decoder.group.group_sequence, decoder.group.group_sequence)
          |> Map.update!(:processed_group_streams, &(&1 + 1))

        next_state =
          state
          |> put_subscription(decoder.group.subscribe_id, entry)
          |> Map.put(:group_decoders, Map.delete(state.group_decoders, stream_id))

        emit_or_queue_group_event(next_state, decoder.group.subscribe_id, ended)

      nil ->
        Transition.error(state, :unknown_group_subscription)
    end
  end

  defp finish_subscription(state, subscribe_id) do
    case state.subscriptions[subscribe_id] do
      nil ->
        Transition.ok(state)

      %{subscribe_buffer: buffer} when buffer != <<>> ->
        Transition.error(state, :incomplete_subscribe_stream)

      %{accepted?: false, accepted_group: group} = entry when not is_nil(group) ->
        put_subscription(state, subscribe_id, %{entry | subscribe_finished?: true})
        |> Transition.ok()

      %{accepted_group: nil, subscribe_end: last} = entry when not is_nil(last) ->
        complete_subscription(state, subscribe_id, entry)

      %{accepted_group: first, subscribe_end: last} = entry
      when not is_nil(first) and not is_nil(last) ->
        if range_covered?(entry.accounted_ranges, first, last) do
          complete_subscription(state, subscribe_id, entry)
        else
          Transition.error(state, :unaccounted_subscription_groups)
        end

      _entry ->
        Transition.error(state, :subscribe_stream_ended_without_end)
    end
  end

  defp complete_subscription(state, subscribe_id, entry) do
    completion = %MOQX.Subscription.Completion{
      status: :track_ended,
      status_code: 0,
      reason: "track ended",
      expected_streams: :unknown,
      processed_streams: entry.processed_group_streams
    }

    next_state = %{state | subscriptions: Map.delete(state.subscriptions, subscribe_id)}

    Transition.ok(next_state,
      events: [%SubscriptionDone{subscription: entry.subscription, completion: completion}]
    )
  end

  defp abort_subscription(state, subscribe_id, error_code) do
    case state.subscriptions[subscribe_id] do
      nil ->
        Transition.ok(state)

      entry ->
        next_state = drop_subscription_state(state, subscribe_id)

        event =
          if entry.accepted? do
            completion = %MOQX.Subscription.Completion{
              status: :subscription_ended,
              status_code: error_code,
              reason: "subscribe stream reset",
              expected_streams: :unknown,
              processed_streams: entry.processed_group_streams
            }

            %SubscriptionDone{subscription: entry.subscription, completion: completion}
          else
            error = %MOQX.ProtocolError{
              protocol: id(),
              operation: :subscribe,
              code: error_code,
              reason: "subscribe stream reset"
            }

            %SubscriptionFailed{subscription: entry.subscription, error: error}
          end

        Transition.ok(next_state, events: [event])
    end
  end

  defp finish_track_stream(state, subscribe_id, event, metadata) do
    case state.subscriptions[subscribe_id] do
      nil ->
        Transition.ok(state)

      %{track_info: %MOQX.TrackInfo{}, track_buffer: <<>>} ->
        Transition.ok(state)

      entry ->
        error_code = metadata[:error_code] || 0

        reason =
          if event == :peer_finished_sending do
            "track stream ended before a complete TRACK_INFO"
          else
            "track stream reset"
          end

        error = %MOQX.ProtocolError{
          protocol: id(),
          operation: :subscribe,
          code: error_code,
          reason: reason
        }

        Transition.ok(drop_subscription_state(state, subscribe_id),
          events: [%SubscriptionFailed{subscription: entry.subscription, error: error}]
        )
    end
  end

  defp emit_or_queue_group_event(state, subscribe_id, event) do
    case state.subscriptions[subscribe_id] do
      %{accepted?: true} ->
        Transition.ok(state, events: [event])

      entry when not is_nil(entry) ->
        entry = Map.update!(entry, :pending_group_events, &[event | &1])
        Transition.ok(put_subscription(state, subscribe_id, entry))

      nil ->
        Transition.error(state, :unknown_group_subscription)
    end
  end

  defp reject_peer_stream(state, stream_id, error_code) do
    Transition.ok(
      %{state | peer_stream_buffers: Map.delete(state.peer_stream_buffers, stream_id)},
      actions: [{:abort_stream_sending, {:peer_stream, stream_id}, error_code}]
    )
  end

  defp protocol_violation(state, reason) do
    Transition.error(state, reason, actions: [{:close_connection, 0x0F}])
  end

  defp mirror_peer_termination(stream_id, :peer_finished_sending, _metadata) do
    [{:send_stream, {:peer_stream, stream_id}, <<>>, [finish: true]}]
  end

  defp mirror_peer_termination(stream_id, :peer_aborted_sending, metadata) do
    [{:abort_stream_sending, {:peer_stream, stream_id}, metadata[:error_code] || 0}]
  end

  defp mirror_peer_termination(_stream_id, _event, _metadata), do: []

  defp prepend_transition_events({:ok, %Transition{} = transition}, events) do
    {:ok, %{transition | events: events ++ transition.events}}
  end

  defp prepend_transition_events(error, _events), do: error

  defp drop_subscription_state(state, subscribe_id) do
    group_decoders =
      Map.reject(state.group_decoders, fn {_stream_id, decoder} ->
        decoder.group && decoder.group.subscribe_id == subscribe_id
      end)

    %{
      state
      | subscriptions: Map.delete(state.subscriptions, subscribe_id),
        group_decoders: group_decoders
    }
  end

  defp account_range(entry, first, last) do
    ranges =
      [{first, last} | entry.accounted_ranges]
      |> Enum.sort()
      |> Enum.reduce([], fn
        range, [] ->
          [range]

        {first, last}, [{current_first, current_last} | rest]
        when first <= current_last + 1 ->
          [{current_first, max(current_last, last)} | rest]

        range, ranges ->
          [range | ranges]
      end)
      |> Enum.reverse()

    %{entry | accounted_ranges: ranges}
  end

  defp range_covered?(ranges, first, last) do
    Enum.any?(ranges, fn {range_first, range_last} ->
      range_first <= first and range_last >= last
    end)
  end
end
