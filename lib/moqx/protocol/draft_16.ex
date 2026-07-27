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
    SubscriptionFailed
  }

  alias MOQX.Operation.{Close, Subscribe, Unsubscribe}
  alias MOQX.Protocol.{Capabilities, Transition, TransportSpec}
  alias MOQX.Protocol.MOQTDraft16.{Codec, SubgroupDecoder}

  defmodule State do
    @moduledoc false
    defstruct phase: :starting,
              endpoint: nil,
              control_buffer: <<>>,
              stream_decoders: %{},
              next_request_id: 0,
              subscriptions: %{},
              aliases: %{}
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
    with :ok <- validate_start(options),
         :ok <- validate_priority(options) do
      request_id = state.next_request_id
      subscription = %MOQX.Subscription{id: request_id, track: track}

      next_state = %{
        state
        | next_request_id: request_id + 2,
          subscriptions: Map.put(state.subscriptions, request_id, subscription)
      }

      Transition.ok(next_state,
        events: [{:subscription_started, subscription}],
        actions: [{:send_stream, :control, Codec.subscribe(request_id, track, options), []}]
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
          aliases:
            Map.reject(state.aliases, fn {_alias, candidate} ->
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
      operations: MapSet.new([:subscribe]),
      delivery_modes: MapSet.new([:subgroup]),
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
      :ok -> Transition.ok(%{state | phase: :ready}, events: [:ready])
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
    with {:ok, error} <- Codec.decode_request_error(payload),
         %MOQX.Subscription{} = subscription <- state.subscriptions[error.request_id] do
      next_state = %{
        state
        | subscriptions: Map.delete(state.subscriptions, subscription.id),
          aliases:
            Map.reject(state.aliases, fn {_alias, candidate} ->
              candidate.id == subscription.id
            end)
      }

      protocol_error = %MOQX.ProtocolError{
        protocol: id(),
        operation: :subscribe,
        code: error.error_code,
        reason: error.reason
      }

      Transition.ok(next_state,
        events: [%SubscriptionFailed{subscription: subscription, error: protocol_error}]
      )
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
        next_state = %{
          state
          | stream_decoders: Map.put(state.stream_decoders, stream_id, decoder)
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
      payload: decoded.payload
    }
  end

  defp validate_start(options) do
    case Keyword.get(options, :start, :next_object) do
      start when start in [:next_object, :next_group] -> :ok
      other -> {:error, {:unsupported_subscription_start, other}}
    end
  end

  defp validate_priority(options) do
    case Keyword.get(options, :priority, 128) do
      priority when priority in 0..255 -> :ok
      _other -> {:error, :invalid_subscription_priority}
    end
  end
end
