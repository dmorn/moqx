defmodule MOQX.Protocol.CloudflareDraft14 do
  @moduledoc """
  Cloudflare's deployed MOQT draft-14 lifecycle and catalog convention.

  The implementation uses the shared draft-14 wire package, while retaining
  ownership of setup policy, supported operations and public events.
  """

  @behaviour MOQX.Protocol

  alias MOQX.Operation.{
    AcceptPublicationSubscription,
    AddTrack,
    Close,
    FinishPublication,
    Publish,
    PublishObject,
    RejectPublicationSubscription,
    Subscribe,
    Unsubscribe
  }

  alias MOQX.Protocol.{Capabilities, Transition, TransportSpec}
  alias MOQX.Protocol.MOQTDraft14.Codec
  alias MOQX.Protocol.MOQTDraft14.Messages
  alias MOQX.Protocol.MOQTDraft14.SubgroupDecoder

  alias MOQX.Event.{
    CatalogReceived,
    ConnectionClosed,
    ObjectReceived,
    ObjectStatus,
    PublicationCancelled,
    PublicationFailed,
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

  defmodule State do
    @moduledoc false
    defstruct phase: :starting,
              control_buffer: <<>>,
              stream_decoders: %{},
              stream_subscriptions: %{},
              next_request_id: 0,
              subscriptions: %{},
              subscription_lifecycles: %{},
              aliases: %{},
              authorization: nil,
              handle_scope: :uninitialized,
              publications: %{},
              pending_publisher_subscriptions: %{},
              publisher_subscriptions: %{},
              next_publication_stream: 0
  end

  defmodule SubscriptionState do
    @moduledoc false
    @enforce_keys [:subscription, :delivery_timeout]
    defstruct [
      :subscription,
      :delivery_timeout,
      :completion,
      delivery_timer_started?: false,
      processed_streams: MapSet.new()
    ]
  end

  @impl true
  def id, do: :cloudflare_draft_14

  @impl true
  def transport_spec(_endpoint, _options) do
    {:ok,
     %TransportSpec{
       alpn: "moq-00",
       connect_options: [
         alpn: ["moq-00"],
         verify: :verify_peer,
         peer_bidi_stream_count: 16,
         peer_unidi_stream_count: 128
       ],
       required_capabilities: MapSet.new([:streams])
     }}
  end

  @impl true
  def init(_endpoint, options) do
    case Keyword.get(options, :authorization) do
      nil ->
        {:ok, %State{handle_scope: make_ref()}}

      %MOQX.Secret{} = authorization ->
        {:ok, %State{authorization: authorization, handle_scope: make_ref()}}

      _other ->
        {:error, :authorization_must_be_an_moqx_secret}
    end
  end

  @impl true
  def handle_transport(%State{phase: :starting} = state, {:connection_event, _conn, :ready, _}) do
    Transition.ok(%{state | phase: :setup},
      actions: [
        {:open_stream, :control, [direction: :bidirectional, active: true],
         sensitive_bytes(
           Codec.client_setup(authorization_params(state.authorization)),
           state.authorization
         )}
      ]
    )
  end

  def handle_transport(%State{} = state, {:stream_data, stream, data, _metadata}) do
    if stream.info.direction == :bidirectional and stream.info.initiator == :local do
      handle_control_data(state, data)
    else
      handle_subgroup_data(state, stream.info.stream_id, data)
    end
  end

  def handle_transport(%State{} = state, {:stream_event, stream, event, metadata})
      when event in [:peer_finished_sending, :peer_aborted_sending, :closed] do
    finish_subgroup_stream(state, stream.info.stream_id, event, metadata)
  end

  def handle_transport(%State{} = state, {:runtime_timeout, {:subscription_delivery, request_id}}) do
    complete_subscription(state, request_id, true)
  end

  def handle_transport(
        %State{} = state,
        {:runtime_timeout, {:publisher_subscription_decision, handle}}
      ) do
    case state.pending_publisher_subscriptions[handle.request_id] do
      %{request: %{handle: ^handle} = request} ->
        state = %{
          state
          | pending_publisher_subscriptions:
              Map.delete(state.pending_publisher_subscriptions, handle.request_id)
        }

        error = %Messages.SubscribeError{
          request_id: handle.request_id,
          error_code: 2,
          reason_phrase: "subscription decision timed out"
        }

        Transition.ok(state,
          events: [
            %PublicationSubscriptionCancelled{request: request, reason: :decision_timeout}
          ],
          actions: [{:send_stream, :control, Codec.encode(error), []}]
        )

      _other ->
        Transition.ok(state)
    end
  end

  def handle_transport(
        %State{phase: :setup} = state,
        {:connection_event, _conn, :closed, metadata}
      ) do
    Transition.error(state, {:connection_closed_during_setup, metadata})
  end

  def handle_transport(%State{} = state, {:connection_event, _conn, :closed, metadata}) do
    Transition.ok(
      %{state | phase: :closed, pending_publisher_subscriptions: %{}},
      events: [%ConnectionClosed{metadata: metadata}]
    )
  end

  def handle_transport(%State{} = state, _event), do: Transition.ok(state)

  @impl true
  def handle_operation(%State{phase: :ready} = state, %Subscribe{track: track, options: options}) do
    with {:ok, delivery_timeout} <- delivery_timeout(options),
         {:ok, filter_type} <- subscription_filter(options) do
      start_subscription(
        state,
        track,
        Keyword.put(options, :filter_type, filter_type),
        delivery_timeout
      )
    else
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %Unsubscribe{subscription: subscription}) do
    if Map.has_key?(state.subscriptions, subscription.id) do
      next_state = %{
        state
        | subscriptions: Map.delete(state.subscriptions, subscription.id)
      }

      Transition.ok(next_state,
        events: [{:subscription_ended, subscription}],
        actions: [{:send_stream, :control, Codec.unsubscribe(subscription.id), []}]
      )
    else
      Transition.error(state, :unknown_subscription)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %Publish{
        namespace: namespace,
        options: options
      }) do
    with :ok <- validate_namespace(namespace),
         {:ok, inbound_subscriptions} <- inbound_subscription_options(options),
         false <- publication_namespace?(state, namespace) do
      request_id = state.next_request_id
      publication = %MOQX.Publication{id: request_id, namespace: namespace}

      entry = %{
        publication: publication,
        status: :pending,
        tracks: %{},
        inbound_subscriptions: inbound_subscriptions,
        options: options
      }

      next_state = %{
        state
        | next_request_id: request_id + 2,
          publications: Map.put(state.publications, request_id, entry)
      }

      message = %Messages.PublishNamespace{
        request_id: request_id,
        track_namespace: namespace,
        params: authorization_params(state.authorization)
      }

      Transition.ok(next_state,
        events: [{:publication_started, publication}],
        actions: [
          {:send_stream, :control, sensitive_bytes(Codec.encode(message), state.authorization),
           []}
        ]
      )
    else
      true -> Transition.error(state, :namespace_already_published)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %AddTrack{} = operation) do
    with {:ok, entry} <- fetch_publication(state, operation.publication),
         :ok <- validate_track_name(operation.track),
         false <- Map.has_key?(entry.tracks, operation.track),
         {:ok, retention} <- validate_retention(Keyword.get(operation.options, :retention, :live)) do
      track_ref = %MOQX.TrackRef{
        namespace: operation.publication.namespace,
        track: operation.track
      }

      published_track = %MOQX.PublishedTrack{
        publication: operation.publication,
        track: track_ref,
        retention: retention
      }

      track_entry = %{track: published_track, retained: [], largest_location: nil}
      entry = %{entry | tracks: Map.put(entry.tracks, operation.track, track_entry)}

      next_state = %{
        state
        | publications: Map.put(state.publications, operation.publication.id, entry)
      }

      Transition.ok(next_state, events: [{:track_added, published_track}])
    else
      true -> Transition.error(state, :track_already_registered)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(
        %State{phase: :ready} = state,
        %AcceptPublicationSubscription{} = operation
      ) do
    accept_publication_subscription(state, operation)
  end

  def handle_operation(
        %State{phase: :ready} = state,
        %RejectPublicationSubscription{} = operation
      ) do
    reject_publication_subscription(state, operation)
  end

  def handle_operation(%State{phase: :ready} = state, %PublishObject{} = operation) do
    published_track = operation.track

    with {:ok, entry} <- fetch_publication(state, operation.track.publication),
         :ok <- validate_object(operation.object),
         %{track: ^published_track} = track_entry <- entry.tracks[operation.track.track.track] do
      track_entry =
        track_entry
        |> remember_largest_location(operation.object)
        |> retain_object(operation.object)

      entry = %{entry | tracks: Map.put(entry.tracks, operation.track.track.track, track_entry)}

      state = %{
        state
        | publications: Map.put(state.publications, operation.track.publication.id, entry)
      }

      {state, actions} = object_actions(state, operation.track, operation.object)

      Transition.ok(state,
        events: [{:object_published, operation.track}],
        actions: actions
      )
    else
      nil -> Transition.error(state, :unknown_published_track)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %FinishPublication{} = operation) do
    case fetch_publication(state, operation.publication) do
      {:ok, _entry} -> finish_known_publication(state, operation)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %Close{}) do
    Transition.ok(%{state | phase: :closed},
      events: [:connection_ended],
      actions: [{:close_connection, 0}]
    )
  end

  def handle_operation(%State{} = state, %Subscribe{}),
    do: Transition.error(state, :connection_not_ready)

  def handle_operation(%State{} = state, operation)
      when is_struct(operation, Publish) or is_struct(operation, AddTrack) or
             is_struct(operation, AcceptPublicationSubscription) or
             is_struct(operation, RejectPublicationSubscription) or
             is_struct(operation, PublishObject) or is_struct(operation, FinishPublication),
      do: Transition.error(state, :connection_not_ready)

  def handle_operation(%State{} = state, _operation),
    do: Transition.error(state, :unsupported_operation)

  defp start_subscription(state, track, options, delivery_timeout) do
    request_id = state.next_request_id
    subscription = %MOQX.Subscription{id: request_id, track: track}

    lifecycle = %SubscriptionState{
      subscription: subscription,
      delivery_timeout: delivery_timeout
    }

    next_state = %{
      state
      | next_request_id: request_id + 2,
        subscriptions: Map.put(state.subscriptions, request_id, subscription),
        subscription_lifecycles: Map.put(state.subscription_lifecycles, request_id, lifecycle)
    }

    Transition.ok(next_state,
      events: [{:subscription_started, subscription}],
      actions: [{:send_stream, :control, Codec.subscribe(request_id, track, options), []}]
    )
  end

  defp delivery_timeout(options) do
    case Keyword.get(options, :delivery_timeout, 5_000) do
      timeout when is_integer(timeout) and timeout >= 0 -> {:ok, timeout}
      _other -> {:error, :invalid_delivery_timeout}
    end
  end

  defp subscription_filter(options) do
    case Keyword.get(options, :start, :next_object) do
      :next_object -> {:ok, :largest_object}
      :next_group -> {:ok, :next_group_start}
      other -> {:error, {:unsupported_subscription_start, other}}
    end
  end

  @impl true
  def capabilities(_state) do
    %Capabilities{
      operations: MapSet.new([:subscribe, :publish, :accept_subscription, :reject_subscription]),
      delivery_modes: MapSet.new([:subgroup]),
      metadata: %{catalog_track: ".catalog"}
    }
  end

  defp handle_control_data(state, data) do
    buffer = state.control_buffer <> data

    with {:ok, frames, rest} <- Codec.decode_control(buffer) do
      initial = Transition.ok(%{state | control_buffer: rest})
      Enum.reduce_while(frames, initial, &reduce_control_frame/2)
    end
  end

  defp reduce_control_frame(frame, {:ok, transition}) do
    case handle_control_frame(transition.state, frame) do
      {:ok, next} -> {:cont, {:ok, merge_transitions(transition, next)}}
      {:error, reason, next} -> {:halt, {:error, reason, next}}
    end
  end

  defp merge_transitions(%Transition{} = previous, %Transition{} = next) do
    %Transition{
      next
      | events: previous.events ++ next.events,
        actions: previous.actions ++ next.actions
    }
  end

  defp handle_control_frame(%State{phase: :setup} = state, {0x21, payload}) do
    case Codec.decode_server_setup(payload) do
      {:ok, _version} -> Transition.ok(%{state | phase: :ready}, events: [:ready])
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  defp handle_control_frame(%State{} = state, {0x04, payload}) do
    with {:ok, ok} <- Codec.decode_subscribe_ok(payload),
         %MOQX.Subscription{} = subscription <- state.subscriptions[ok.request_id] do
      next_state = %{state | aliases: Map.put(state.aliases, ok.track_alias, subscription)}
      Transition.ok(next_state, events: [%SubscriptionAccepted{subscription: subscription}])
    else
      nil -> Transition.error(state, :unknown_subscribe_request)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  defp handle_control_frame(%State{} = state, {0x05, payload}) do
    with {:ok, error} <- Codec.decode_subscribe_error(payload),
         %MOQX.Subscription{} = subscription <- state.subscriptions[error.request_id] do
      aliases =
        Map.reject(state.aliases, fn {_alias_id, candidate} -> candidate.id == subscription.id end)

      next_state = %{
        state
        | subscriptions: Map.delete(state.subscriptions, subscription.id),
          subscription_lifecycles: Map.delete(state.subscription_lifecycles, subscription.id),
          aliases: aliases
      }

      protocol_error = %MOQX.ProtocolError{
        protocol: id(),
        operation: :subscribe,
        code: error.error_code,
        reason: error.reason_phrase
      }

      Transition.ok(next_state,
        events: [%SubscriptionFailed{subscription: subscription, error: protocol_error}]
      )
    else
      nil -> Transition.error(state, :unknown_subscribe_request)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  defp handle_control_frame(%State{} = state, {0x07, payload}) do
    with {:ok, message} <- Codec.decode_publish_namespace_ok(payload),
         %{publication: publication} = entry <- state.publications[message.request_id] do
      entry = %{entry | status: :active}

      next_state = %{
        state
        | publications: Map.put(state.publications, publication.id, entry)
      }

      Transition.ok(next_state, events: [%PublicationReady{publication: publication}])
    else
      nil -> Transition.error(state, :unknown_publish_namespace_request)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  defp handle_control_frame(%State{} = state, {0x08, payload}) do
    with {:ok, message} <- Codec.decode_publish_namespace_error(payload),
         %{publication: publication} <- state.publications[message.request_id] do
      error = %MOQX.ProtocolError{
        protocol: id(),
        operation: :publish,
        code: message.error_code,
        reason: message.reason_phrase
      }

      next_state = %{state | publications: Map.delete(state.publications, publication.id)}

      Transition.ok(next_state,
        events: [%PublicationFailed{publication: publication, error: error}]
      )
    else
      nil -> Transition.error(state, :unknown_publish_namespace_request)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  defp handle_control_frame(%State{} = state, {0x0C, payload}) do
    with {:ok, message} <- Codec.decode_publish_namespace_cancel(payload),
         {_id, %{publication: publication}} <-
           publication_by_namespace(state, message.track_namespace) do
      error = %MOQX.ProtocolError{
        protocol: id(),
        operation: :publish,
        code: message.error_code,
        reason: message.reason_phrase
      }

      {pending, pending_events, pending_actions} =
        finish_pending_publication_subscriptions(
          state,
          publication.id,
          :publication_cancelled,
          "publication cancelled"
        )

      next_state =
        state
        |> drop_publication(publication.id)
        |> Map.put(:pending_publisher_subscriptions, pending)

      Transition.ok(next_state,
        events: [%PublicationCancelled{publication: publication, error: error} | pending_events],
        actions: pending_actions
      )
    else
      nil -> Transition.ok(state)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  defp handle_control_frame(%State{} = state, {0x03, payload}) do
    with {:ok, subscribe} <- Codec.decode_subscribe(payload) do
      handle_inbound_subscribe(state, subscribe)
    end
  end

  defp handle_control_frame(%State{} = state, {0x0A, payload}) do
    with {:ok, unsubscribe} <- Codec.decode_unsubscribe(payload) do
      handle_inbound_unsubscribe(state, unsubscribe)
    end
  end

  defp handle_control_frame(%State{} = state, {0x0B, payload}) do
    with {:ok, done} <- Codec.decode_publish_done(payload),
         %{subscription: %MOQX.Subscription{}} = lifecycle <-
           state.subscription_lifecycles[done.request_id] do
      next_state = %{
        state
        | subscription_lifecycles:
            Map.put(state.subscription_lifecycles, done.request_id, %{
              lifecycle
              | completion: done,
                delivery_timer_started?: false
            })
      }

      maybe_complete_subscription(next_state, done.request_id)
    else
      nil -> Transition.error(state, :unknown_subscribe_request)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  defp handle_control_frame(%State{} = state, {_type, _payload}), do: Transition.ok(state)

  defp handle_subgroup_data(state, stream_id, data) do
    decoder = Map.get(state.stream_decoders, stream_id, %SubgroupDecoder{})

    case SubgroupDecoder.push(decoder, data) do
      {:ok, decoder, objects} ->
        stream_subscriptions = associate_stream(state, decoder, stream_id)

        next_state = %{
          state
          | stream_decoders: Map.put(state.stream_decoders, stream_id, decoder),
            stream_subscriptions: stream_subscriptions
        }

        Enum.reduce_while(objects, Transition.ok(next_state), &reduce_object_event/2)

      {:error, reason} ->
        Transition.error(state, reason)
    end
  end

  defp associate_stream(state, %{header: %{track_alias: alias_id}}, stream_id) do
    case state.aliases[alias_id] do
      %MOQX.Subscription{id: request_id} ->
        Map.put(state.stream_subscriptions, stream_id, request_id)

      nil ->
        state.stream_subscriptions
    end
  end

  defp associate_stream(state, %{header: nil}, _stream_id), do: state.stream_subscriptions

  defp reduce_object_event(object, {:ok, transition}) do
    case object_event(transition.state, object) do
      {:ok, next} -> {:cont, {:ok, merge_transitions(transition, next)}}
      {:error, reason, next} -> {:halt, {:error, reason, next}}
    end
  end

  defp object_event(state, %{track_alias: alias_id, payload: payload} = decoded) do
    case state.aliases[alias_id] do
      %MOQX.Subscription{} = subscription when not is_nil(decoded.status) ->
        Transition.ok(state,
          events: [%ObjectStatus{object: public_object(subscription, decoded)}]
        )

      %MOQX.Subscription{track: %{track: ".catalog"}} = subscription ->
        case MOQX.Catalog.decode(payload,
               format: :cloudflare,
               namespace: subscription.track.namespace
             ) do
          {:ok, catalog} ->
            Transition.ok(state,
              events: [%CatalogReceived{catalog: catalog, subscription: subscription}]
            )

          {:error, reason} ->
            Transition.error(state, {:invalid_catalog, reason})
        end

      %MOQX.Subscription{} = subscription ->
        Transition.ok(state,
          events: [%ObjectReceived{object: public_object(subscription, decoded)}]
        )

      nil ->
        Transition.error(state, {:unknown_track_alias, alias_id})
    end
  end

  defp public_object(subscription, decoded) do
    %MOQX.Object{
      subscription: subscription,
      group_id: decoded.group_id,
      subgroup_id: decoded.subgroup_id,
      object_id: decoded.object_id,
      publisher_priority: decoded.priority,
      status: decoded.status,
      payload: decoded.payload
    }
  end

  defp finish_subgroup_stream(state, stream_id, event, metadata) do
    request_id = state.stream_subscriptions[stream_id]
    decoder = state.stream_decoders[stream_id]

    case {event, decoder} do
      {:peer_finished_sending, %SubgroupDecoder{} = decoder} ->
        case SubgroupDecoder.complete(decoder) do
          :ok ->
            finish_known_subgroup(state, stream_id, request_id, decoder, event, metadata)

          {:error, reason} ->
            Transition.error(drop_subgroup_stream(state, stream_id), reason)
        end

      {_event, %SubgroupDecoder{} = decoder} ->
        finish_known_subgroup(state, stream_id, request_id, decoder, event, metadata)

      {_event, nil} ->
        Transition.ok(drop_subgroup_stream(state, stream_id))
    end
  end

  defp finish_known_subgroup(state, stream_id, request_id, decoder, event, metadata) do
    state = drop_subgroup_stream(state, stream_id)

    case state.subscription_lifecycles[request_id] do
      %{processed_streams: processed} = lifecycle ->
        lifecycle = %{lifecycle | processed_streams: MapSet.put(processed, stream_id)}

        state = %{
          state
          | subscription_lifecycles: Map.put(state.subscription_lifecycles, request_id, lifecycle)
        }

        prepend_event(
          maybe_complete_subscription(state, request_id),
          subgroup_ended(lifecycle.subscription, decoder, event, metadata)
        )

      nil ->
        Transition.ok(state)
    end
  end

  defp drop_subgroup_stream(state, stream_id) do
    %{
      state
      | stream_decoders: Map.delete(state.stream_decoders, stream_id),
        stream_subscriptions: Map.delete(state.stream_subscriptions, stream_id)
    }
  end

  defp subgroup_ended(subscription, decoder, event, metadata) do
    outcome =
      case event do
        :peer_finished_sending -> :complete
        :peer_aborted_sending -> :reset
        :closed -> :closed
      end

    %SubgroupEnded{
      subscription: subscription,
      group_id: decoder.header.group_id,
      subgroup_id: decoder.header.subgroup_id,
      outcome: outcome,
      error_code: metadata[:error_code],
      end_of_group?: outcome == :complete and Bitwise.band(decoder.header.type, 0x08) != 0
    }
  end

  defp prepend_event({:ok, %Transition{} = transition}, event) do
    {:ok, %{transition | events: [event | transition.events]}}
  end

  defp maybe_complete_subscription(state, request_id) do
    case state.subscription_lifecycles[request_id] do
      %{completion: nil} ->
        Transition.ok(state)

      %{
        completion: done,
        processed_streams: processed,
        delivery_timeout: timeout,
        delivery_timer_started?: timer_started?
      } = lifecycle ->
        if done.stream_count != 0x3FFF_FFFF_FFFF_FFFF and
             MapSet.size(processed) >= done.stream_count do
          complete_subscription(state, request_id, false)
        else
          continue_draining(state, request_id, lifecycle, timer_started?, timeout)
        end

      nil ->
        Transition.error(state, :unknown_subscribe_request)
    end
  end

  defp continue_draining(state, _request_id, _lifecycle, true, _timeout),
    do: Transition.ok(state)

  defp continue_draining(state, request_id, lifecycle, false, timeout) do
    lifecycle = %{lifecycle | delivery_timer_started?: true}

    state = %{
      state
      | subscription_lifecycles: Map.put(state.subscription_lifecycles, request_id, lifecycle)
    }

    Transition.ok(state,
      actions: [{:start_timer, {:subscription_delivery, request_id}, timeout}]
    )
  end

  defp complete_subscription(state, request_id, timed_out?) do
    case state.subscription_lifecycles[request_id] do
      %{subscription: subscription, completion: %Messages.PublishDone{} = done} = lifecycle ->
        completion = %MOQX.Subscription.Completion{
          status: completion_status(done.status_code),
          status_code: done.status_code,
          reason: done.reason_phrase,
          expected_streams: expected_stream_count(done.stream_count),
          processed_streams: MapSet.size(lifecycle.processed_streams),
          timed_out?: timed_out?
        }

        aliases =
          Map.reject(state.aliases, fn {_alias_id, candidate} -> candidate.id == request_id end)

        stream_subscriptions =
          Map.reject(state.stream_subscriptions, fn {_stream_id, candidate} ->
            candidate == request_id
          end)

        state = %{
          state
          | subscriptions: Map.delete(state.subscriptions, request_id),
            subscription_lifecycles: Map.delete(state.subscription_lifecycles, request_id),
            aliases: aliases,
            stream_subscriptions: stream_subscriptions
        }

        actions =
          if timed_out?, do: [], else: [{:cancel_timer, {:subscription_delivery, request_id}}]

        Transition.ok(state,
          events: [%SubscriptionDone{subscription: subscription, completion: completion}],
          actions: actions
        )

      _other ->
        Transition.ok(state)
    end
  end

  defp completion_status(0), do: :internal_error
  defp completion_status(1), do: :unauthorized
  defp completion_status(2), do: :track_ended
  defp completion_status(3), do: :subscription_ended
  defp completion_status(4), do: :going_away
  defp completion_status(5), do: :expired
  defp completion_status(6), do: :too_far_behind
  defp completion_status(7), do: :malformed_track
  defp completion_status(code), do: {:unknown, code}

  defp expected_stream_count(0x3FFF_FFFF_FFFF_FFFF), do: :unknown
  defp expected_stream_count(count), do: count

  defp handle_inbound_subscribe(state, subscribe) do
    if Map.has_key?(state.pending_publisher_subscriptions, subscribe.request_id) or
         Map.has_key?(state.publisher_subscriptions, subscribe.request_id) do
      Transition.error(state, :duplicate_subscribe_request)
    else
      case publication_by_namespace(state, subscribe.track_namespace) do
        {_publication_id, %{inbound_subscriptions: %{mode: :controlled}} = entry} ->
          pend_inbound_subscription(state, entry, subscribe)

        {_publication_id, entry} ->
          automatically_handle_inbound_subscription(state, entry, subscribe)

        nil ->
          reject_missing_track(state, subscribe.request_id)
      end
    end
  end

  defp automatically_handle_inbound_subscription(state, entry, subscribe) do
    case entry.tracks[subscribe.track_name] do
      %{track: published_track} = track_entry ->
        largest_location = track_entry.largest_location

        subscription = %{
          request_id: subscribe.request_id,
          publication_id: published_track.publication.id,
          track: published_track,
          track_alias: subscribe.request_id,
          subscriber_priority: subscribe.subscriber_priority,
          group_order: :ascending,
          forward: subscribe.forward,
          filter: %MOQX.SubscriptionFilter{type: :absolute_start, start_location: {0, 0}},
          stream_count: 0
        }

        state = %{
          state
          | publisher_subscriptions:
              Map.put(state.publisher_subscriptions, subscribe.request_id, subscription)
        }

        ok = %Messages.SubscribeOk{
          request_id: subscribe.request_id,
          track_alias: subscribe.request_id,
          expires: 0,
          group_order: :ascending,
          largest_location: largest_location,
          params: %{}
        }

        {state, replay_actions} = replay_actions(state, subscription, track_entry.retained)

        Transition.ok(state,
          events: [
            %PublicationSubscriberJoined{
              track: published_track,
              request_id: subscribe.request_id
            }
          ],
          actions: [{:send_stream, :control, Codec.encode(ok), []} | replay_actions]
        )

      nil ->
        reject_missing_track(state, subscribe.request_id)
    end
  end

  defp pend_inbound_subscription(state, entry, subscribe) do
    policy = entry.inbound_subscriptions

    pending_count =
      Enum.count(state.pending_publisher_subscriptions, fn {_request_id, pending} ->
        pending.publication_id == entry.publication.id
      end)

    if pending_count >= policy.max_pending do
      reject_subscription(state, subscribe.request_id, 0, "pending subscription limit exceeded")
    else
      handle = %MOQX.PublicationSubscriptionRequest.Handle{
        scope: state.handle_scope,
        request_id: subscribe.request_id
      }

      request = %MOQX.PublicationSubscriptionRequest{
        handle: handle,
        publication: entry.publication,
        track: %MOQX.TrackRef{
          namespace: subscribe.track_namespace,
          track: subscribe.track_name
        },
        subscriber_priority: subscribe.subscriber_priority,
        group_order: subscribe.group_order,
        forward: subscribe.forward,
        filter: %MOQX.SubscriptionFilter{
          type: subscribe.filter_type,
          start_location: subscribe.start_location,
          end_group: subscribe.end_group
        },
        parameters: public_subscription_parameters(subscribe.params)
      }

      largest_location = pending_largest_location(entry, subscribe.track_name)

      pending = %{
        request: request,
        publication_id: entry.publication.id,
        effective_filter: effective_subscription_filter(request.filter, largest_location),
        largest_location: largest_location
      }

      state = %{
        state
        | pending_publisher_subscriptions:
            Map.put(state.pending_publisher_subscriptions, subscribe.request_id, pending)
      }

      Transition.ok(state,
        events: [%PublicationSubscriptionRequested{request: request}],
        actions: [
          {:start_timer, {:publisher_subscription_decision, handle}, policy.timeout}
        ]
      )
    end
  end

  defp accept_publication_subscription(state, operation) do
    request = operation.request
    handle = request.handle

    with :ok <- validate_request_scope(state, handle),
         %{request: ^request} = pending <-
           state.pending_publisher_subscriptions[handle.request_id],
         {:ok, entry} <- fetch_publication(state, operation.published_track.publication),
         %{track: published_track} = track_entry <-
           entry.tracks[operation.published_track.track.track],
         true <-
           published_track == operation.published_track and published_track.track == request.track,
         {:ok, group_order} <- accepted_group_order(request.group_order, operation.options),
         {:ok, expires} <- subscription_expiry(operation.options) do
      subscription = %{
        request_id: handle.request_id,
        publication_id: published_track.publication.id,
        track: published_track,
        track_alias: handle.request_id,
        subscriber_priority: request.subscriber_priority,
        group_order: group_order,
        forward: request.forward,
        filter: pending.effective_filter,
        stream_count: 0
      }

      state = %{
        state
        | pending_publisher_subscriptions:
            Map.delete(state.pending_publisher_subscriptions, handle.request_id),
          publisher_subscriptions:
            Map.put(state.publisher_subscriptions, handle.request_id, subscription)
      }

      ok = %Messages.SubscribeOk{
        request_id: handle.request_id,
        track_alias: handle.request_id,
        expires: expires,
        group_order: group_order,
        largest_location: pending.largest_location,
        params: %{}
      }

      {state, replay_actions} = replay_actions(state, subscription, track_entry.retained)

      Transition.ok(state,
        events: [
          %PublicationSubscriberJoined{track: published_track, request_id: handle.request_id}
        ],
        actions: [
          {:cancel_timer, {:publisher_subscription_decision, handle}},
          {:send_stream, :control, Codec.encode(ok), []}
          | replay_actions
        ]
      )
    else
      nil -> Transition.error(state, :stale_subscription_request)
      false -> Transition.error(state, :subscription_request_track_mismatch)
      {:error, reason} -> Transition.error(state, reason)
      _other -> Transition.error(state, :stale_subscription_request)
    end
  end

  defp reject_publication_subscription(state, operation) do
    request = operation.request
    handle = request.handle

    with :ok <- validate_request_scope(state, handle),
         %{request: ^request} <- state.pending_publisher_subscriptions[handle.request_id],
         {:ok, error_code} <- subscription_error_code(operation.rejection.code) do
      state = %{
        state
        | pending_publisher_subscriptions:
            Map.delete(state.pending_publisher_subscriptions, handle.request_id)
      }

      error = %Messages.SubscribeError{
        request_id: handle.request_id,
        error_code: error_code,
        reason_phrase: operation.rejection.reason || Atom.to_string(operation.rejection.code)
      }

      Transition.ok(state,
        actions: [
          {:cancel_timer, {:publisher_subscription_decision, handle}},
          {:send_stream, :control, Codec.encode(error), []}
        ]
      )
    else
      nil -> Transition.error(state, :stale_subscription_request)
      {:error, reason} -> Transition.error(state, reason)
      _other -> Transition.error(state, :stale_subscription_request)
    end
  end

  defp validate_request_scope(%State{handle_scope: scope}, %{scope: scope}), do: :ok
  defp validate_request_scope(_state, _handle), do: {:error, :wrong_client_subscription_request}

  defp accepted_group_order(:ascending, _options), do: {:ok, :ascending}

  defp accepted_group_order(:publisher, options) do
    case Keyword.get(options, :group_order, :ascending) do
      :ascending -> {:ok, :ascending}
      :descending -> {:error, :unsupported_group_order}
      _other -> {:error, :invalid_group_order}
    end
  end

  defp accepted_group_order(:descending, _options), do: {:error, :unsupported_group_order}

  defp subscription_expiry(options) do
    case Keyword.get(options, :expires, 0) do
      expires when is_integer(expires) and expires >= 0 -> {:ok, expires}
      _other -> {:error, :invalid_subscription_expiry}
    end
  end

  defp pending_largest_location(entry, track_name) do
    case entry.tracks[track_name] do
      %{largest_location: largest_location} -> largest_location
      nil -> nil
    end
  end

  defp effective_subscription_filter(
         %MOQX.SubscriptionFilter{type: :largest_object},
         nil
       ),
       do: %MOQX.SubscriptionFilter{type: :absolute_start, start_location: {0, 0}}

  defp effective_subscription_filter(
         %MOQX.SubscriptionFilter{type: :largest_object},
         {group_id, object_id}
       ),
       do: %MOQX.SubscriptionFilter{
         type: :absolute_start,
         start_location: {group_id, object_id + 1}
       }

  defp effective_subscription_filter(
         %MOQX.SubscriptionFilter{type: :next_group_start},
         nil
       ),
       do: %MOQX.SubscriptionFilter{type: :absolute_start, start_location: {0, 0}}

  defp effective_subscription_filter(
         %MOQX.SubscriptionFilter{type: :next_group_start},
         {group_id, _object_id}
       ),
       do: %MOQX.SubscriptionFilter{type: :absolute_start, start_location: {group_id + 1, 0}}

  defp effective_subscription_filter(filter, _largest_location), do: filter

  defp subscription_error_code(:internal_error), do: {:ok, 0}
  defp subscription_error_code(:unauthorized), do: {:ok, 1}
  defp subscription_error_code(:timeout), do: {:ok, 2}
  defp subscription_error_code(:not_supported), do: {:ok, 3}
  defp subscription_error_code(:track_does_not_exist), do: {:ok, 4}
  defp subscription_error_code(:invalid_range), do: {:ok, 5}
  defp subscription_error_code(:malformed_auth_token), do: {:ok, 0x10}
  defp subscription_error_code(:expired_auth_token), do: {:ok, 0x12}
  defp subscription_error_code(_other), do: {:error, :invalid_subscription_rejection}

  defp public_subscription_parameters(params) do
    Enum.map(params, fn
      {3, value} ->
        %MOQX.SubscriptionParameter.Authorization{value: value}

      {2, milliseconds} ->
        %MOQX.SubscriptionParameter.DeliveryTimeout{milliseconds: milliseconds}

      {identifier, value} ->
        %MOQX.SubscriptionParameter.Extension{
          protocol: id(),
          identifier: identifier,
          value: value
        }
    end)
  end

  defp reject_missing_track(state, request_id),
    do: reject_subscription(state, request_id, 4, "track not found")

  defp reject_subscription(state, request_id, error_code, reason_phrase) do
    error = %Messages.SubscribeError{
      request_id: request_id,
      error_code: error_code,
      reason_phrase: reason_phrase
    }

    Transition.ok(state, actions: [{:send_stream, :control, Codec.encode(error), []}])
  end

  defp handle_inbound_unsubscribe(state, unsubscribe) do
    case Map.pop(state.pending_publisher_subscriptions, unsubscribe.request_id) do
      {%{request: request}, pending} ->
        Transition.ok(%{state | pending_publisher_subscriptions: pending},
          events: [
            %PublicationSubscriptionCancelled{request: request, reason: :unsubscribed}
          ],
          actions: [
            {:cancel_timer, {:publisher_subscription_decision, request.handle}}
          ]
        )

      {nil, _pending} ->
        handle_active_inbound_unsubscribe(state, unsubscribe)
    end
  end

  defp handle_active_inbound_unsubscribe(state, unsubscribe) do
    case Map.pop(state.publisher_subscriptions, unsubscribe.request_id) do
      {nil, _subscriptions} ->
        Transition.ok(state)

      {subscription, subscriptions} ->
        done = publish_done(subscription, 3, "subscription ended")

        Transition.ok(%{state | publisher_subscriptions: subscriptions},
          events: [
            %PublicationSubscriberLeft{
              track: subscription.track,
              request_id: subscription.request_id
            }
          ],
          actions: [{:send_stream, :control, Codec.encode(done), []}]
        )
    end
  end

  defp object_actions(state, track, object) do
    state.publisher_subscriptions
    |> Enum.filter(fn {_id, subscription} ->
      subscription.track == track and subscription.forward and
        object_matches_filter?(subscription.filter, object)
    end)
    |> Enum.reduce({state, []}, fn {_id, subscription}, {state, actions} ->
      {state, action} = subgroup_action(state, subscription, object)
      {state, actions ++ [action]}
    end)
  end

  defp replay_actions(state, _subscription, []), do: {state, []}
  defp replay_actions(state, %{forward: false}, _objects), do: {state, []}

  defp replay_actions(state, subscription, objects) do
    objects
    |> Enum.filter(&object_matches_filter?(subscription.filter, &1))
    |> Enum.reduce({state, []}, fn object, {state, actions} ->
      current = state.publisher_subscriptions[subscription.request_id]
      {state, action} = subgroup_action(state, current, object)
      {state, actions ++ [action]}
    end)
  end

  defp object_matches_filter?(%MOQX.SubscriptionFilter{type: :absolute_start} = filter, object),
    do: {object.group_id, object.object_id} >= filter.start_location

  defp object_matches_filter?(%MOQX.SubscriptionFilter{type: :absolute_range} = filter, object),
    do:
      {object.group_id, object.object_id} >= filter.start_location and
        object.group_id <= filter.end_group

  defp object_matches_filter?(%MOQX.SubscriptionFilter{type: :largest_object}, _object), do: true

  defp object_matches_filter?(%MOQX.SubscriptionFilter{type: :next_group_start}, _object),
    do: true

  defp subgroup_action(state, subscription, object) do
    stream_number = state.next_publication_stream
    key = {:publication, subscription.request_id, stream_number}
    bytes = Codec.encode_subgroup(subscription.track_alias, object)
    subscription = %{subscription | stream_count: subscription.stream_count + 1}

    state = %{
      state
      | next_publication_stream: stream_number + 1,
        publisher_subscriptions:
          Map.put(state.publisher_subscriptions, subscription.request_id, subscription)
    }

    action =
      {:open_stream, key, [direction: :unidirectional], bytes, [finish: true]}

    {state, action}
  end

  defp retain_object(%{track: %{retention: :live}} = entry, _object), do: entry

  defp retain_object(%{track: %{retention: :latest}} = entry, object),
    do: %{entry | retained: [object]}

  defp retain_object(%{track: %{retention: :all}} = entry, object),
    do: %{entry | retained: entry.retained ++ [object]}

  defp remember_largest_location(entry, object) do
    location = {object.group_id, object.object_id}

    case entry.largest_location do
      nil -> %{entry | largest_location: location}
      current when location > current -> %{entry | largest_location: location}
      _current -> entry
    end
  end

  defp finish_publication_subscriptions(state, publication_id, options) do
    status = Keyword.get(options, :status, 2)
    reason = Keyword.get(options, :reason, "track ended")

    Enum.reduce(state.publisher_subscriptions, {%{}, []}, fn {id, subscription},
                                                             {remaining, actions} ->
      if subscription.publication_id == publication_id do
        done = publish_done(subscription, status, reason)
        {remaining, actions ++ [{:send_stream, :control, Codec.encode(done), []}]}
      else
        {Map.put(remaining, id, subscription), actions}
      end
    end)
  end

  defp finish_known_publication(state, operation) do
    {pending, pending_events, pending_actions} =
      finish_pending_publication_subscriptions(
        state,
        operation.publication.id,
        :publication_finished,
        "publication finished"
      )

    {subscriptions, done_actions} =
      finish_publication_subscriptions(state, operation.publication.id, operation.options)

    namespace_done = %Messages.PublishNamespaceDone{
      track_namespace: operation.publication.namespace
    }

    next_state = %{
      state
      | publications: Map.delete(state.publications, operation.publication.id),
        pending_publisher_subscriptions: pending,
        publisher_subscriptions: subscriptions
    }

    Transition.ok(next_state,
      events: [{:publication_finished, operation.publication} | pending_events],
      actions:
        pending_actions ++
          done_actions ++
          [{:send_stream, :control, Codec.encode(namespace_done), []}]
    )
  end

  defp finish_pending_publication_subscriptions(state, publication_id, reason, error_reason) do
    Enum.reduce(
      state.pending_publisher_subscriptions,
      {%{}, [], []},
      fn {request_id, pending}, {remaining, events, actions} ->
        if pending.publication_id == publication_id do
          error = %Messages.SubscribeError{
            request_id: request_id,
            error_code: 4,
            reason_phrase: error_reason
          }

          next_actions = [
            {:cancel_timer, {:publisher_subscription_decision, pending.request.handle}},
            {:send_stream, :control, Codec.encode(error), []}
          ]

          next_event = %PublicationSubscriptionCancelled{
            request: pending.request,
            reason: reason
          }

          {remaining, events ++ [next_event], actions ++ next_actions}
        else
          {Map.put(remaining, request_id, pending), events, actions}
        end
      end
    )
  end

  defp publish_done(subscription, status, reason) do
    %Messages.PublishDone{
      request_id: subscription.request_id,
      status_code: status,
      stream_count: subscription.stream_count,
      reason_phrase: reason
    }
  end

  defp fetch_publication(state, %MOQX.Publication{id: id, namespace: namespace}) do
    case state.publications[id] do
      %{publication: %{namespace: ^namespace}} = entry -> {:ok, entry}
      _other -> {:error, :unknown_publication}
    end
  end

  defp publication_namespace?(state, namespace),
    do: not is_nil(publication_by_namespace(state, namespace))

  defp publication_by_namespace(state, namespace) do
    Enum.find(state.publications, fn {_id, entry} ->
      entry.publication.namespace == namespace
    end)
  end

  defp drop_publication(state, publication_id) do
    subscriptions =
      Map.reject(state.publisher_subscriptions, fn {_id, subscription} ->
        subscription.publication_id == publication_id
      end)

    %{
      state
      | publications: Map.delete(state.publications, publication_id),
        publisher_subscriptions: subscriptions
    }
  end

  defp validate_namespace(namespace) do
    if namespace != [] and Enum.all?(namespace, &(is_binary(&1) and byte_size(&1) > 0)) do
      :ok
    else
      {:error, :invalid_namespace}
    end
  end

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

  defp validate_retention(retention) when retention in [:live, :latest, :all],
    do: {:ok, retention}

  defp validate_retention(_retention), do: {:error, :invalid_retention}

  defp validate_track_name(track) when is_binary(track) and byte_size(track) > 0, do: :ok
  defp validate_track_name(_track), do: {:error, :invalid_track_name}

  defp validate_object(%MOQX.Object{} = object) do
    valid? =
      non_negative_integer?(object.group_id) and
        optional_non_negative_integer?(object.subgroup_id) and
        non_negative_integer?(object.object_id) and
        valid_priority?(object.publisher_priority) and valid_status?(object.status) and
        is_binary(object.payload)

    if valid?, do: :ok, else: {:error, :invalid_object}
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp optional_non_negative_integer?(nil), do: true
  defp optional_non_negative_integer?(value), do: non_negative_integer?(value)
  defp valid_priority?(nil), do: true
  defp valid_priority?(value), do: value in 0..255

  defp valid_status?(status),
    do: status in [nil, :object_does_not_exist, :end_of_group, :end_of_track]

  defp authorization_params(nil), do: %{}

  defp authorization_params(%MOQX.Secret{} = secret) do
    %{3 => Codec.authorization_token(MOQX.Secret.reveal(secret))}
  end

  defp sensitive_bytes(bytes, nil), do: bytes
  defp sensitive_bytes(bytes, %MOQX.Secret{}), do: MOQX.Sensitive.new(bytes)
end

defmodule MOQX.Protocol.CloudflareDraft14.Session do
  @moduledoc "Compatibility namespace for the Cloudflare draft-14 lifecycle state machine."
end
