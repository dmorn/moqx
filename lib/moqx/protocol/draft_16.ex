defmodule MOQX.Protocol.Draft16 do
  @moduledoc """
  Standard MOQT draft-16 subscriber implementation.

  This implementation owns the draft-16 setup, subscription, control-message,
  and subgroup wire semantics. It coexists with the provider-specific
  draft-14 implementation behind the protocol-neutral `MOQX` API.
  """

  @behaviour MOQX.Protocol

  alias MOQX.Event.{
    ConnectionClosed,
    ObjectReceived,
    ObjectStatus,
    SubscriptionAccepted,
    SubscriptionDone,
    SubscriptionFailed,
    SubscriptionUpdated,
    SubscriptionUpdateFailed
  }

  alias MOQX.Operation.{Close, Subscribe, Unsubscribe, UpdateSubscription}
  alias MOQX.Protocol.{Capabilities, Transition, TransportSpec}
  alias MOQX.Protocol.MOQTDraft16.{Codec, SubgroupDecoder}

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
              aliases: %{}
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

  def handle_transport(%State{} = state, {:stream_event, stream, event, _metadata})
      when event in [:peer_finished_sending, :peer_aborted_sending, :closed] do
    if stream.info.direction == :bidirectional and stream.info.initiator == :local do
      Transition.error(state, {:control_stream_terminated, event})
    else
      finish_subgroup_stream(state, stream.info.stream_id)
    end
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
    if Map.has_key?(state.subscriptions, subscription.id) do
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
    else
      Transition.error(state, :unknown_subscription)
    end
  end

  def handle_operation(%State{phase: :ready} = state, %UpdateSubscription{
        subscription: subscription,
        options: options
      }) do
    with %MOQX.Subscription{} <- state.subscriptions[subscription.id],
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
    end
  end

  def handle_operation(%State{} = state, %Close{}) do
    Transition.ok(%{state | phase: :closed},
      events: [:connection_ended],
      actions: [{:close_connection, 0}]
    )
  end

  def handle_operation(%State{} = state, %Subscribe{}),
    do: Transition.error(state, :connection_not_ready)

  def handle_operation(%State{} = state, _operation),
    do: Transition.error(state, :unsupported_operation)

  @impl true
  def capabilities(_state) do
    %Capabilities{
      operations: MapSet.new([:subscribe, :update_subscription]),
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
         %MOQX.Subscription{} = subscription <- state.subscriptions[ok.request_id] do
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
    with {:ok, ok} <- Codec.decode_request_ok(payload),
         %MOQX.Subscription{} = subscription <- state.pending_updates[ok.request_id] do
      next_state = %{state | pending_updates: Map.delete(state.pending_updates, ok.request_id)}

      Transition.ok(next_state,
        events: [
          %SubscriptionUpdated{subscription: subscription, parameters: ok.parameters}
        ]
      )
    else
      nil -> Transition.error(state, :unknown_update_request)
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

    if is_list(parameters) and
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
               ((is_integer(value) and value >= 0) or is_binary(value))

           _parameter ->
             false
         end) do
      :ok
    else
      {:error, :invalid_subscription_parameters}
    end
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

  defp finish_subgroup_stream(state, stream_id) do
    request_id = state.stream_subscriptions[stream_id]

    with %SubgroupDecoder{} = decoder <- state.stream_decoders[stream_id],
         :ok <- SubgroupDecoder.complete(decoder) do
      finish_complete_subgroup_stream(state, stream_id, request_id)
    else
      nil -> Transition.ok(state)
      {:error, reason} -> Transition.error(state, reason)
    end
  end

  defp finish_complete_subgroup_stream(state, stream_id, request_id) do
    state = %{
      state
      | stream_decoders: Map.delete(state.stream_decoders, stream_id),
        stream_subscriptions: Map.delete(state.stream_subscriptions, stream_id)
    }

    case state.subscription_lifecycles[request_id] do
      %SubscriptionState{processed_streams: processed} = lifecycle ->
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
end
