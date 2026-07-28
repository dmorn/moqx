defmodule MOQX.Protocol.Draft16 do
  @moduledoc """
  Standard MOQT draft-16 subscriber implementation.

  This implementation owns the draft-16 setup, subscription, control-message,
  and subgroup wire semantics. It coexists with the provider-specific
  draft-14 implementation behind the protocol-neutral `MOQX` API.
  """

  @behaviour MOQX.Protocol

  alias MOQX.Event.{
    CatalogReceived,
    ConnectionClosed,
    ObjectReceived,
    ObjectStatus,
    PublicationReady,
    PublicationSubscriberJoined,
    SubgroupEnded,
    SubscriptionAccepted,
    SubscriptionDone,
    SubscriptionFailed,
    SubscriptionUpdated,
    SubscriptionUpdateFailed
  }

  alias MOQX.Operation.{
    AddTrack,
    Close,
    Publish,
    PublishObject,
    Subscribe,
    Unsubscribe,
    UpdateSubscription
  }

  alias MOQX.Protocol.{Capabilities, Transition, TransportSpec}
  alias MOQX.Protocol.MOQTDraft16.{Codec, SubgroupDecoder}

  @known_message_parameter_ids [0x02, 0x03, 0x08, 0x09, 0x10, 0x20, 0x21, 0x22, 0x32]

  defmodule State do
    @moduledoc false
    defstruct phase: :starting,
              endpoint: nil,
              control_buffer: <<>>,
              stream_decoders: %{},
              stream_subscriptions: %{},
              next_request_id: 0,
              max_request_id: 0,
              subscriptions: %{},
              subscription_lifecycles: %{},
              pending_updates: %{},
              aliases: %{},
              publications: %{},
              next_track_alias: 0,
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
  def id, do: :draft_16

  @impl true
  def transport_spec(_endpoint, _options) do
    {:ok,
     %TransportSpec{
       alpn: "moqt-16",
       connect_options: [
         alpn: ["moqt-16"],
         verify: :verify_peer,
         peer_bidi_stream_count: 16,
         peer_unidi_stream_count: 128
       ],
       required_capabilities: MapSet.new([:streams])
     }}
  end

  @impl true
  def init(%URI{scheme: "moqt"} = endpoint, _options),
    do: {:ok, %State{endpoint: endpoint}}

  def init(_endpoint, _options), do: {:error, :draft_16_requires_native_quic}

  @impl true
  def handle_transport(%State{phase: :starting} = state, {:connection_event, _conn, :ready, _}) do
    Transition.ok(%{state | phase: :setup},
      actions: [
        {:open_stream, :control, [direction: :bidirectional, active: true],
         Codec.client_setup(state.endpoint)}
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

  def handle_transport(%State{} = state, {:datagram, _connection, data, _metadata}) do
    with {:ok, object} <- Codec.decode_datagram(data) do
      object_event(state, object)
    end
  end

  def handle_transport(%State{} = state, {:stream_event, stream, event, metadata})
      when event in [:peer_finished_sending, :peer_aborted_sending, :closed] do
    if stream.info.direction == :bidirectional and stream.info.initiator == :local do
      Transition.error(close_state(state), control_stream_termination_reason(state, event))
    else
      finish_subgroup_stream(state, stream.info.stream_id, event, metadata)
    end
  end

  def handle_transport(%State{} = state, {:runtime_timeout, {:subscription_delivery, request_id}}) do
    complete_subscription(state, request_id, true)
  end

  def handle_transport(
        %State{phase: :setup} = state,
        {:connection_event, _conn, :closed, metadata}
      ) do
    Transition.error(close_state(state), {:connection_closed_during_setup, metadata})
  end

  def handle_transport(%State{} = state, {:connection_event, _conn, :closed, metadata}) do
    Transition.ok(close_state(state), events: [%ConnectionClosed{metadata: metadata}])
  end

  def handle_transport(%State{} = state, _event), do: Transition.ok(state)

  @impl true
  def handle_operation(%State{phase: :ready} = state, %Subscribe{
        track: track,
        options: options
      }) do
    with {:ok, filter} <- subscription_filter(options),
         :ok <- validate_priority(options),
         :ok <- validate_group_order(options),
         {:ok, delivery_timeout} <- delivery_timeout(options),
         :ok <- validate_parameters(options),
         :ok <- validate_request_credit(state) do
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
        actions: [
          {:send_stream, :control,
           Codec.subscribe(request_id, track, Keyword.put(options, :filter, filter)), []}
        ]
      )
    else
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %Unsubscribe{
        subscription: subscription
      }) do
    case state.subscriptions[subscription.id] do
      ^subscription ->
        next_state = %{
          state
          | subscriptions: Map.delete(state.subscriptions, subscription.id),
            pending_updates:
              Map.reject(state.pending_updates, fn {_request_id, candidate} ->
                candidate.id == subscription.id
              end)
        }

        Transition.ok(next_state,
          events: [{:subscription_ended, subscription}],
          actions: [{:send_stream, :control, Codec.unsubscribe(subscription.id), []}]
        )

      _other ->
        Transition.error(state, :unknown_subscription)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %UpdateSubscription{
        subscription: subscription,
        options: options
      }) do
    with ^subscription <- state.subscriptions[subscription.id],
         {:ok, options} <- normalize_update_options(options),
         :ok <- validate_request_credit(state) do
      request_id = state.next_request_id

      next_state = %{
        state
        | next_request_id: request_id + 2,
          pending_updates: Map.put(state.pending_updates, request_id, subscription)
      }

      Transition.ok(next_state,
        events: [{:subscription_updated, subscription}],
        actions: [
          {:send_stream, :control, Codec.request_update(request_id, subscription.id, options), []}
        ]
      )
    else
      nil -> Transition.error(state, :unknown_subscription)
      {:error, reason} -> Transition.error(state, reason)
      _other -> Transition.error(state, :unknown_subscription)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %Publish{
        namespace: namespace,
        options: options
      }) do
    with :ok <- validate_namespace(namespace),
         false <- publication_namespace?(state, namespace),
         :ok <- validate_request_credit(state) do
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

      Transition.ok(next_state,
        events: [{:publication_started, publication}],
        actions: [
          {:send_stream, :control, Codec.publish_namespace(request_id, namespace), []}
        ]
      )
    else
      true -> Transition.error(state, :namespace_already_published)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %AddTrack{} = operation) do
    with {:ok, entry} <- fetch_publication(state, operation.publication),
         :ready <- entry.status,
         :ok <- validate_track_name(operation.track),
         false <- Map.has_key?(entry.tracks, operation.track),
         {:ok, retention} <- validate_retention(Keyword.get(operation.options, :retention, :live)),
         :ok <- validate_request_credit(state) do
      request_id = state.next_request_id
      track_alias = state.next_track_alias

      track_ref = %MOQX.TrackRef{
        namespace: operation.publication.namespace,
        track: operation.track
      }

      published_track = %MOQX.PublishedTrack{
        publication: operation.publication,
        track: track_ref,
        retention: retention
      }

      track_entry = %{
        track: published_track,
        request_id: request_id,
        track_alias: track_alias,
        status: :pending,
        options: operation.options
      }

      entry = %{entry | tracks: Map.put(entry.tracks, operation.track, track_entry)}

      next_state = %{
        state
        | next_request_id: request_id + 2,
          next_track_alias: track_alias + 1,
          publications: Map.put(state.publications, operation.publication.id, entry)
      }

      Transition.ok(next_state,
        events: [{:track_added, published_track}],
        actions: [
          {:send_stream, :control,
           Codec.publish_track(request_id, track_ref, track_alias, operation.options), []}
        ]
      )
    else
      :pending -> Transition.error(state, :publication_not_ready)
      true -> Transition.error(state, :track_already_registered)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %PublishObject{} = operation) do
    with {:ok, entry} <- fetch_publication(state, operation.track.publication),
         %{track: published_track, status: :ready} = track_entry <-
           entry.tracks[operation.track.track.track],
         true <- published_track == operation.track,
         :ok <- validate_object(operation.object) do
      stream_number = state.next_publication_stream
      key = {:publication, track_entry.request_id, stream_number}
      bytes = Codec.encode_subgroup(track_entry.track_alias, operation.object)

      Transition.ok(%{state | next_publication_stream: stream_number + 1},
        events: [{:object_published, operation.track}],
        actions: [
          {:open_stream, key, [direction: :unidirectional], bytes, [finish: true]}
        ]
      )
    else
      %{status: :pending} -> Transition.error(state, :published_track_not_ready)
      nil -> Transition.error(state, :unknown_published_track)
      false -> Transition.error(state, :unknown_published_track)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  def handle_operation(%State{} = state, %Close{}) do
    Transition.ok(close_state(state),
      events: [:connection_ended],
      actions: [{:close_connection, 0}]
    )
  end

  def handle_operation(%State{} = state, %Subscribe{}),
    do: Transition.error(state, :connection_not_ready)

  def handle_operation(%State{} = state, operation)
      when is_struct(operation, Publish) or is_struct(operation, AddTrack) or
             is_struct(operation, PublishObject),
      do: Transition.error(state, :connection_not_ready)

  def handle_operation(%State{} = state, _operation),
    do: Transition.error(state, :unsupported_operation)

  @impl true
  def capabilities(_state) do
    %Capabilities{
      operations:
        MapSet.new([:subscribe, :update_subscription, :publish, :add_track, :publish_object]),
      delivery_modes: MapSet.new([:subgroup, :datagram]),
      metadata: %{catalog_track: "catalog", draft: 16}
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
      {:ok, setup} ->
        Transition.ok(%{state | phase: :ready, max_request_id: setup.max_request_id},
          events: [:ready]
        )

      {:error, reason} ->
        Transition.error(state, reason)
    end
  end

  defp handle_control_frame(%State{phase: :setup} = state, {_type, _payload}),
    do: Transition.error(state, :server_setup_required)

  defp handle_control_frame(%State{} = state, {0x04, payload}) do
    with {:ok, ok} <- Codec.decode_subscribe_ok(payload),
         %MOQX.Subscription{} = subscription <- state.subscriptions[ok.request_id],
         :ok <- ensure_track_alias_available(state, ok.track_alias) do
      next_state = %{state | aliases: Map.put(state.aliases, ok.track_alias, subscription)}

      Transition.ok(next_state,
        events: [
          %SubscriptionAccepted{
            subscription: subscription,
            parameters: ok.parameters,
            track_extensions: ok.track_extensions
          }
        ]
      )
    else
      nil -> Transition.error(state, :unknown_subscribe_request)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  defp handle_control_frame(%State{} = state, {0x0B, payload}) do
    with {:ok, done} <- Codec.decode_publish_done(payload),
         %SubscriptionState{} = lifecycle <-
           state.subscription_lifecycles[done.request_id] do
      lifecycle = %{lifecycle | completion: done, delivery_timer_started?: false}

      state = %{
        state
        | subscription_lifecycles:
            Map.put(state.subscription_lifecycles, done.request_id, lifecycle)
      }

      maybe_complete_subscription(state, done.request_id)
    else
      nil -> Transition.error(state, :unknown_subscribe_request)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  defp handle_control_frame(%State{} = state, {0x05, payload}) do
    with {:ok, error} <- Codec.decode_request_error(payload) do
      case state.pending_updates[error.request_id] do
        %MOQX.Subscription{} = subscription ->
          protocol_error = %MOQX.ProtocolError{
            protocol: id(),
            operation: :update_subscription,
            code: error.error_code,
            reason: error.reason
          }

          next_state = %{
            state
            | pending_updates: Map.delete(state.pending_updates, error.request_id)
          }

          Transition.ok(next_state,
            events: [
              %SubscriptionUpdateFailed{
                subscription: subscription,
                error: protocol_error
              }
            ]
          )

        nil ->
          fail_subscription_request(state, error)
      end
    end
  end

  defp handle_control_frame(%State{} = state, {0x07, payload}) do
    with {:ok, ok} <- Codec.decode_request_ok(payload) do
      case state.pending_updates[ok.request_id] do
        %MOQX.Subscription{} = subscription ->
          next_state = %{
            state
            | pending_updates: Map.delete(state.pending_updates, ok.request_id)
          }

          Transition.ok(next_state,
            events: [
              %SubscriptionUpdated{subscription: subscription, parameters: ok.parameters}
            ]
          )

        nil ->
          accept_publication_namespace(state, ok.request_id)
      end
    end
  end

  defp handle_control_frame(%State{} = state, {0x1E, payload}) do
    with {:ok, ok} <- Codec.decode_publish_ok(payload),
         {:ok, publication_id, track_name, track_entry} <-
           fetch_track_by_request_id(state, ok.request_id),
         :pending <- track_entry.status do
      entry = state.publications[publication_id]
      track_entry = %{track_entry | status: :ready}
      entry = %{entry | tracks: Map.put(entry.tracks, track_name, track_entry)}

      next_state = %{
        state
        | publications: Map.put(state.publications, publication_id, entry)
      }

      Transition.ok(next_state,
        events: [
          %PublicationSubscriberJoined{
            track: track_entry.track,
            request_id: ok.request_id
          }
        ]
      )
    else
      :ready -> Transition.error(state, :duplicate_publish_ok)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  defp handle_control_frame(%State{} = state, {0x15, payload}) do
    with {:ok, max_request_id} <- Codec.decode_max_request_id(payload),
         true <- max_request_id > state.max_request_id do
      Transition.ok(%{state | max_request_id: max_request_id})
    else
      false -> Transition.error(state, :invalid_max_request_id)
      {:error, _reason} -> Transition.error(state, :invalid_max_request_id)
    end
  end

  defp handle_control_frame(%State{} = state, {0x21, _payload}),
    do: Transition.error(state, :duplicate_server_setup)

  defp handle_control_frame(%State{} = state, {_type, _payload}), do: Transition.ok(state)

  defp ensure_track_alias_available(%State{aliases: aliases}, track_alias) do
    if Map.has_key?(aliases, track_alias) do
      {:error, {:duplicate_track_alias, track_alias}}
    else
      :ok
    end
  end

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

  defp reduce_object_event(object, {:ok, transition}) do
    case object_event(transition.state, object) do
      {:ok, next} -> {:cont, {:ok, merge_transitions(transition, next)}}
      {:error, reason, next} -> {:halt, {:error, reason, next}}
    end
  end

  defp object_event(state, %{track_alias: alias_id} = decoded) do
    case state.aliases[alias_id] do
      %MOQX.Subscription{} = subscription when not is_nil(decoded.status) ->
        Transition.ok(state,
          events: [%ObjectStatus{object: public_object(subscription, decoded)}]
        )

      %MOQX.Subscription{track: %{track: "catalog"}} = subscription ->
        case MOQX.Catalog.decode(decoded.payload,
               format: :moqtail_cmsf,
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
      extensions: Map.get(decoded, :extensions, []),
      end_of_group?: Map.get(decoded, :end_of_group?, false),
      payload: decoded.payload
    }
  end

  defp subscription_filter(options) do
    case Keyword.fetch(options, :filter) do
      {:ok, %MOQX.SubscriptionFilter{} = filter} -> validate_filter(filter)
      {:ok, other} -> {:error, {:invalid_subscription_filter, other}}
      :error -> filter_from_start(Keyword.get(options, :start, :next_object))
    end
  end

  defp filter_from_start(:next_object),
    do: {:ok, %MOQX.SubscriptionFilter{type: :largest_object}}

  defp filter_from_start(:next_group),
    do: {:ok, %MOQX.SubscriptionFilter{type: :next_group_start}}

  defp filter_from_start(other), do: {:error, {:unsupported_subscription_start, other}}

  defp validate_filter(%MOQX.SubscriptionFilter{
         type: type,
         start_location: nil,
         end_group: nil
       })
       when type in [:next_group_start, :largest_object],
       do: {:ok, %MOQX.SubscriptionFilter{type: type}}

  defp validate_filter(
         %MOQX.SubscriptionFilter{
           type: :absolute_start,
           start_location: {group, object},
           end_group: nil
         } = filter
       )
       when is_integer(group) and group >= 0 and is_integer(object) and object >= 0,
       do: {:ok, filter}

  defp validate_filter(
         %MOQX.SubscriptionFilter{
           type: :absolute_range,
           start_location: {group, object},
           end_group: end_group
         } = filter
       )
       when is_integer(group) and group >= 0 and is_integer(object) and object >= 0 and
              is_integer(end_group) and end_group >= group,
       do: {:ok, filter}

  defp validate_filter(filter), do: {:error, {:invalid_subscription_filter, filter}}

  defp validate_priority(options) do
    case Keyword.get(options, :priority, 128) do
      priority when priority in 0..255 -> :ok
      _other -> {:error, :invalid_subscription_priority}
    end
  end

  defp validate_group_order(options) do
    case Keyword.get(options, :group_order) do
      nil -> :ok
      order when order in [:ascending, :descending] -> :ok
      _other -> {:error, :invalid_group_order}
    end
  end

  defp delivery_timeout(options) do
    case Keyword.get(options, :delivery_timeout, 5_000) do
      timeout when is_integer(timeout) and timeout > 0 -> {:ok, timeout}
      _other -> {:error, :invalid_delivery_timeout}
    end
  end

  defp validate_parameters(options) do
    parameters = Keyword.get(options, :parameters, [])

    if valid_parameter_list?(parameters) and unique_parameter_ids?(parameters, options) do
      :ok
    else
      {:error, :invalid_subscription_parameters}
    end
  end

  defp valid_parameter_list?(parameters) when is_list(parameters) do
    Enum.all?(parameters, fn
      %MOQX.SubscriptionParameter.Authorization{value: value} ->
        is_binary(value)

      %MOQX.SubscriptionParameter.DeliveryTimeout{milliseconds: value} ->
        is_integer(value) and value > 0

      %MOQX.SubscriptionParameter.Extension{
        protocol: :draft_16,
        identifier: identifier,
        value: value
      } ->
        is_integer(identifier) and identifier >= 0 and
          identifier not in @known_message_parameter_ids and
          valid_extension_value?(identifier, value)

      _parameter ->
        false
    end)
  end

  defp valid_parameter_list?(_parameters), do: false

  defp valid_extension_value?(identifier, value) when rem(identifier, 2) == 0,
    do: is_integer(value) and value >= 0

  defp valid_extension_value?(_identifier, value), do: is_binary(value)

  defp unique_parameter_ids?(parameters, options) do
    option_ids =
      if Keyword.has_key?(options, :delivery_timeout), do: [0x02], else: []

    ids = option_ids ++ Enum.map(parameters, &parameter_identifier/1)
    length(ids) == MapSet.size(MapSet.new(ids))
  end

  defp parameter_identifier(%MOQX.SubscriptionParameter.Authorization{}), do: 0x03
  defp parameter_identifier(%MOQX.SubscriptionParameter.DeliveryTimeout{}), do: 0x02

  defp parameter_identifier(%MOQX.SubscriptionParameter.Extension{identifier: identifier}),
    do: identifier

  defp validate_namespace(namespace)
       when is_list(namespace) and namespace != [] and length(namespace) <= 32 do
    if Enum.all?(namespace, &(is_binary(&1) and byte_size(&1) > 0)) and
         Enum.sum(Enum.map(namespace, &byte_size/1)) <= 4_096 do
      :ok
    else
      {:error, :invalid_namespace}
    end
  end

  defp validate_namespace(_namespace), do: {:error, :invalid_namespace}

  defp validate_track_name(track) when is_binary(track) and byte_size(track) <= 4_096, do: :ok
  defp validate_track_name(_track), do: {:error, :invalid_track_name}

  defp validate_retention(retention) when retention in [:live, :latest, :all],
    do: {:ok, retention}

  defp validate_retention(_retention), do: {:error, :invalid_retention}

  defp validate_object(%MOQX.Object{} = object) do
    validators = [
      valid_non_negative_integer?(object.group_id),
      valid_non_negative_integer?(object.object_id),
      is_nil(object.subgroup_id) or valid_non_negative_integer?(object.subgroup_id),
      is_nil(object.publisher_priority) or object.publisher_priority in 0..255,
      is_binary(object.payload)
    ]

    if Enum.all?(validators), do: :ok, else: {:error, :invalid_object}
  end

  defp validate_object(_object), do: {:error, :invalid_object}

  defp valid_non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp publication_namespace?(state, namespace) do
    Enum.any?(state.publications, fn {_id, entry} ->
      entry.publication.namespace == namespace
    end)
  end

  defp fetch_publication(state, publication) do
    case state.publications[publication.id] do
      %{publication: ^publication} = entry -> {:ok, entry}
      _other -> {:error, :unknown_publication}
    end
  end

  defp accept_publication_namespace(state, request_id) do
    case state.publications[request_id] do
      %{status: :pending, publication: publication} = entry ->
        next_state = %{
          state
          | publications: Map.put(state.publications, request_id, %{entry | status: :ready})
        }

        Transition.ok(next_state, events: [%PublicationReady{publication: publication}])

      %{status: :ready} ->
        Transition.error(state, :duplicate_publication_response)

      nil ->
        Transition.error(state, :unknown_update_request)
    end
  end

  defp fetch_track_by_request_id(state, request_id) do
    matches =
      for {publication_id, entry} <- state.publications,
          {track_name, track_entry} <- entry.tracks,
          track_entry.request_id == request_id,
          do: {:ok, publication_id, track_name, track_entry}

    List.first(matches) || {:error, :unknown_publish_request}
  end

  defp validate_request_credit(%State{next_request_id: next, max_request_id: max})
       when next <= max,
       do: :ok

  defp validate_request_credit(_state), do: {:error, :request_id_credit_exhausted}

  defp normalize_update_options(options) do
    with {:ok, options} <- normalize_update_filter(options),
         :ok <- validate_optional_priority(options),
         :ok <- validate_optional_delivery_timeout(options),
         :ok <- validate_parameters(options),
         :ok <- validate_update_flags(options) do
      {:ok, options}
    end
  end

  defp normalize_update_filter(options) do
    if Keyword.has_key?(options, :filter) or Keyword.has_key?(options, :start) do
      case subscription_filter(options) do
        {:ok, filter} -> {:ok, Keyword.put(options, :filter, filter)}
        error -> error
      end
    else
      {:ok, options}
    end
  end

  defp validate_optional_priority(options) do
    if Keyword.has_key?(options, :priority), do: validate_priority(options), else: :ok
  end

  defp validate_optional_delivery_timeout(options) do
    if Keyword.has_key?(options, :delivery_timeout) do
      case delivery_timeout(options) do
        {:ok, _timeout} -> :ok
        error -> error
      end
    else
      :ok
    end
  end

  defp validate_update_flags(options) do
    forward = Keyword.get(options, :forward)
    new_group = Keyword.get(options, :new_group)

    if forward in [nil, true, false] and
         (is_nil(new_group) or (is_integer(new_group) and new_group >= 0)) do
      :ok
    else
      {:error, :invalid_subscription_update}
    end
  end

  defp fail_subscription_request(state, error) do
    case state.subscriptions[error.request_id] do
      %MOQX.Subscription{} = subscription ->
        next_state = drop_subscription(state, subscription.id)

        protocol_error = %MOQX.ProtocolError{
          protocol: id(),
          operation: :subscribe,
          code: error.error_code,
          reason: error.reason
        }

        Transition.ok(next_state,
          events: [%SubscriptionFailed{subscription: subscription, error: protocol_error}]
        )

      nil ->
        Transition.error(state, :unknown_subscribe_request)
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

  defp finish_subgroup_stream(
         state,
         stream_id,
         :peer_finished_sending,
         _metadata
       ) do
    request_id = state.stream_subscriptions[stream_id]

    with %SubgroupDecoder{} = decoder <- state.stream_decoders[stream_id],
         :ok <- SubgroupDecoder.complete(decoder) do
      finish_ended_subgroup(state, stream_id, request_id, decoder, :complete, nil)
    else
      nil -> Transition.ok(state)
      {:error, reason} -> Transition.error(drop_stream(state, stream_id), reason)
    end
  end

  defp finish_subgroup_stream(state, stream_id, event, metadata)
       when event in [:peer_aborted_sending, :closed] do
    request_id = state.stream_subscriptions[stream_id]

    case state.stream_decoders[stream_id] do
      %SubgroupDecoder{} = decoder ->
        outcome = if event == :peer_aborted_sending, do: :reset, else: :closed

        finish_ended_subgroup(
          state,
          stream_id,
          request_id,
          decoder,
          outcome,
          metadata[:error_code]
        )

      nil ->
        Transition.ok(drop_stream(state, stream_id))
    end
  end

  defp finish_ended_subgroup(state, stream_id, request_id, decoder, outcome, error_code) do
    state = drop_stream(state, stream_id)

    case state.subscription_lifecycles[request_id] do
      %SubscriptionState{processed_streams: processed} = lifecycle ->
        lifecycle = %{lifecycle | processed_streams: MapSet.put(processed, stream_id)}

        state = %{
          state
          | subscription_lifecycles: Map.put(state.subscription_lifecycles, request_id, lifecycle)
        }

        prepend_event(
          maybe_complete_subscription(state, request_id),
          subgroup_ended(lifecycle.subscription, decoder, outcome, error_code)
        )

      nil ->
        Transition.ok(state)
    end
  end

  defp subgroup_ended(subscription, decoder, outcome, error_code) do
    %SubgroupEnded{
      subscription: subscription,
      group_id: decoder.header.group_id,
      subgroup_id: decoder.subgroup_id || decoder.header.subgroup_id,
      outcome: outcome,
      error_code: error_code,
      end_of_group?: outcome == :complete and decoder.header.end_of_group?
    }
  end

  defp prepend_event({:ok, %Transition{} = transition}, event) do
    {:ok, %{transition | events: [event | transition.events]}}
  end

  defp maybe_complete_subscription(state, request_id) do
    case state.subscription_lifecycles[request_id] do
      %SubscriptionState{completion: nil} ->
        Transition.ok(state)

      %SubscriptionState{
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
      %SubscriptionState{subscription: subscription, completion: done} = lifecycle
      when not is_nil(done) ->
        completion = %MOQX.Subscription.Completion{
          status: completion_status(done.status_code),
          status_code: done.status_code,
          reason: done.reason,
          expected_streams: expected_stream_count(done.stream_count),
          processed_streams: MapSet.size(lifecycle.processed_streams),
          timed_out?: timed_out?
        }

        state = drop_subscription(state, request_id)

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

  defp drop_subscription(state, request_id) do
    aliases =
      Map.reject(state.aliases, fn {_alias_id, candidate} -> candidate.id == request_id end)

    stream_ids =
      for {stream_id, ^request_id} <- state.stream_subscriptions, do: stream_id

    %{
      state
      | subscriptions: Map.delete(state.subscriptions, request_id),
        subscription_lifecycles: Map.delete(state.subscription_lifecycles, request_id),
        aliases: aliases,
        stream_subscriptions:
          Map.reject(state.stream_subscriptions, fn {_stream_id, candidate} ->
            candidate == request_id
          end),
        stream_decoders: Map.drop(state.stream_decoders, stream_ids)
    }
  end

  defp completion_status(0), do: :internal_error
  defp completion_status(1), do: :unauthorized
  defp completion_status(2), do: :track_ended
  defp completion_status(3), do: :subscription_ended
  defp completion_status(4), do: :going_away
  defp completion_status(5), do: :expired
  defp completion_status(6), do: :too_far_behind
  defp completion_status(8), do: :update_failed
  defp completion_status(0x12), do: :malformed_track
  defp completion_status(code), do: {:unknown, code}

  defp expected_stream_count(0x3FFF_FFFF_FFFF_FFFF), do: :unknown
  defp expected_stream_count(count), do: count

  defp drop_stream(state, stream_id) do
    %{
      state
      | stream_decoders: Map.delete(state.stream_decoders, stream_id),
        stream_subscriptions: Map.delete(state.stream_subscriptions, stream_id)
    }
  end

  defp close_state(state) do
    %{
      state
      | phase: :closed,
        control_buffer: <<>>,
        stream_decoders: %{},
        stream_subscriptions: %{},
        subscriptions: %{},
        subscription_lifecycles: %{},
        pending_updates: %{},
        aliases: %{}
    }
  end

  defp control_stream_termination_reason(%State{control_buffer: <<>>}, event),
    do: {:control_stream_terminated, event}

  defp control_stream_termination_reason(%State{control_buffer: buffer}, event),
    do: {:incomplete_control_stream, event, byte_size(buffer)}
end
