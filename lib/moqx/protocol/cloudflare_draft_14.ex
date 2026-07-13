defmodule MOQX.Protocol.CloudflareDraft14 do
  @moduledoc """
  Cloudflare's deployed MOQT draft-14 lifecycle and catalog convention.

  The implementation uses the shared draft-14 wire package, while retaining
  ownership of setup policy, supported operations and public events.
  """

  @behaviour MOQX.Protocol

  alias MOQX.Operation.{
    AddTrack,
    Close,
    FinishPublication,
    Publish,
    PublishObject,
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
              publications: %{},
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
      nil -> {:ok, %State{}}
      %MOQX.Secret{} = authorization -> {:ok, %State{authorization: authorization}}
      _other -> {:error, :authorization_must_be_an_moqx_secret}
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

  def handle_transport(%State{} = state, {:stream_event, stream, event, _metadata})
      when event in [:peer_finished_sending, :peer_aborted_sending, :closed] do
    finish_subgroup_stream(state, stream.info.stream_id)
  end

  def handle_transport(%State{} = state, {:runtime_timeout, {:subscription_delivery, request_id}}) do
    complete_subscription(state, request_id, true)
  end

  def handle_transport(
        %State{phase: :setup} = state,
        {:connection_event, _conn, :closed, metadata}
      ) do
    Transition.error(state, {:connection_closed_during_setup, metadata})
  end

  def handle_transport(%State{} = state, {:connection_event, _conn, :closed, metadata}) do
    Transition.ok(%{state | phase: :closed}, events: [%ConnectionClosed{metadata: metadata}])
  end

  def handle_transport(%State{} = state, _event), do: Transition.ok(state)

  @impl true
  def handle_operation(%State{phase: :ready} = state, %Subscribe{track: track, options: options}) do
    case delivery_timeout(options) do
      {:ok, delivery_timeout} -> start_subscription(state, track, options, delivery_timeout)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %Unsubscribe{subscription: subscription}) do
    if Map.has_key?(state.subscriptions, subscription.id) do
      aliases =
        Map.reject(state.aliases, fn {_alias_id, candidate} -> candidate.id == subscription.id end)

      next_state = %{
        state
        | subscriptions: Map.delete(state.subscriptions, subscription.id),
          subscription_lifecycles: Map.delete(state.subscription_lifecycles, subscription.id),
          aliases: aliases
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
         false <- publication_namespace?(state, namespace) do
      request_id = state.next_request_id
      publication = %MOQX.Publication{id: request_id, namespace: namespace}

      entry = %{
        publication: publication,
        status: :pending,
        tracks: %{},
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

      track_entry = %{track: published_track, retained: []}
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

  def handle_operation(%State{phase: :ready} = state, %PublishObject{} = operation) do
    published_track = operation.track

    with {:ok, entry} <- fetch_publication(state, operation.track.publication),
         :ok <- validate_object(operation.object),
         %{track: ^published_track} = track_entry <- entry.tracks[operation.track.track.track] do
      track_entry = retain_object(track_entry, operation.object)
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

  @impl true
  def capabilities(_state) do
    %Capabilities{
      operations: MapSet.new([:subscribe, :publish]),
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

      next_state = drop_publication(state, publication.id)

      Transition.ok(next_state,
        events: [%PublicationCancelled{publication: publication, error: error}]
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

      %MOQX.Subscription{track: %{track: ".catalog"}} ->
        case MOQX.Catalog.decode(payload) do
          {:ok, catalog} -> Transition.ok(state, events: [%CatalogReceived{catalog: catalog}])
          {:error, reason} -> Transition.error(state, {:invalid_catalog, reason})
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

  defp finish_subgroup_stream(state, stream_id) do
    request_id = state.stream_subscriptions[stream_id]
    state = %{state | stream_decoders: Map.delete(state.stream_decoders, stream_id)}

    case state.subscription_lifecycles[request_id] do
      %{processed_streams: processed} = lifecycle ->
        lifecycle = %{lifecycle | processed_streams: MapSet.put(processed, stream_id)}

        state = %{
          state
          | subscription_lifecycles: Map.put(state.subscription_lifecycles, request_id, lifecycle)
        }

        maybe_complete_subscription(state, request_id)

      nil ->
        Transition.ok(state)
    end
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
    with {_publication_id, entry} <- publication_by_namespace(state, subscribe.track_namespace),
         %{track: published_track} = track_entry <- entry.tracks[subscribe.track_name] do
      largest_location = largest_location(track_entry.retained)

      subscription = %{
        request_id: subscribe.request_id,
        publication_id: published_track.publication.id,
        track: published_track,
        track_alias: subscribe.request_id,
        forward: subscribe.forward,
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
    else
      nil ->
        error = %Messages.SubscribeError{
          request_id: subscribe.request_id,
          error_code: 4,
          reason_phrase: "track not found"
        }

        Transition.ok(state,
          actions: [{:send_stream, :control, Codec.encode(error), []}]
        )
    end
  end

  defp handle_inbound_unsubscribe(state, unsubscribe) do
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
      subscription.track == track and subscription.forward
    end)
    |> Enum.reduce({state, []}, fn {_id, subscription}, {state, actions} ->
      {state, action} = subgroup_action(state, subscription, object)
      {state, actions ++ [action]}
    end)
  end

  defp replay_actions(state, _subscription, []), do: {state, []}
  defp replay_actions(state, %{forward: false}, _objects), do: {state, []}

  defp replay_actions(state, subscription, objects) do
    Enum.reduce(objects, {state, []}, fn object, {state, actions} ->
      current = state.publisher_subscriptions[subscription.request_id]
      {state, action} = subgroup_action(state, current, object)
      {state, actions ++ [action]}
    end)
  end

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
    {subscriptions, done_actions} =
      finish_publication_subscriptions(state, operation.publication.id, operation.options)

    namespace_done = %Messages.PublishNamespaceDone{
      track_namespace: operation.publication.namespace
    }

    next_state = %{
      state
      | publications: Map.delete(state.publications, operation.publication.id),
        publisher_subscriptions: subscriptions
    }

    Transition.ok(next_state,
      events: [{:publication_finished, operation.publication}],
      actions: done_actions ++ [{:send_stream, :control, Codec.encode(namespace_done), []}]
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

  defp largest_location([]), do: nil

  defp largest_location(objects) do
    objects
    |> Enum.map(&{&1.group_id, &1.object_id})
    |> Enum.max()
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
