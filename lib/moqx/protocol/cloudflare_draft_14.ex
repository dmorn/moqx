defmodule MOQX.Protocol.CloudflareDraft14 do
  @moduledoc """
  Cloudflare's deployed MOQT draft-14 lifecycle and catalog convention.

  The implementation uses the shared draft-14 wire package, while retaining
  ownership of setup policy, supported operations and public events.
  """

  @behaviour MOQX.Protocol

  alias MOQX.Operation.{Close, Subscribe, Unsubscribe}
  alias MOQX.Protocol.{Capabilities, Transition, TransportSpec}
  alias MOQX.Protocol.MOQTDraft14.Codec
  alias MOQX.Protocol.MOQTDraft14.SubgroupDecoder

  defmodule State do
    @moduledoc false
    defstruct phase: :starting,
              control_buffer: <<>>,
              stream_decoders: %{},
              next_request_id: 0,
              subscriptions: %{},
              aliases: %{}
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
  def init(_endpoint, _options), do: {:ok, %State{}}

  @impl true
  def handle_transport(%State{phase: :starting} = state, {:connection_event, _conn, :ready, _}) do
    Transition.ok(%{state | phase: :setup},
      actions: [
        {:open_stream, :control, [direction: :bidirectional, active: true], Codec.client_setup()}
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
    Transition.ok(%{
      state
      | stream_decoders: Map.delete(state.stream_decoders, stream.info.stream_id)
    })
  end

  def handle_transport(
        %State{phase: :setup} = state,
        {:connection_event, _conn, :closed, metadata}
      ) do
    Transition.error(state, {:connection_closed_during_setup, metadata})
  end

  def handle_transport(%State{} = state, {:connection_event, _conn, :closed, metadata}) do
    Transition.ok(%{state | phase: :closed}, events: [{:connection_closed, metadata}])
  end

  def handle_transport(%State{} = state, _event), do: Transition.ok(state)

  @impl true
  def handle_operation(%State{phase: :ready} = state, %Subscribe{track: track, options: options}) do
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
  end

  def handle_operation(%State{phase: :ready} = state, %Unsubscribe{subscription: subscription}) do
    if Map.has_key?(state.subscriptions, subscription.id) do
      aliases =
        Map.reject(state.aliases, fn {_alias_id, candidate} -> candidate.id == subscription.id end)

      next_state = %{
        state
        | subscriptions: Map.delete(state.subscriptions, subscription.id),
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

  def handle_operation(%State{phase: :ready} = state, %Close{}) do
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
      Transition.ok(next_state, events: [{:subscribe_ok, subscription}])
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
          aliases: aliases
      }

      protocol_error = %MOQX.ProtocolError{
        protocol: id(),
        operation: :subscribe,
        code: error.error_code,
        reason: error.reason_phrase
      }

      Transition.ok(next_state, events: [{:subscription_error, subscription, protocol_error}])
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

  defp object_event(state, %{track_alias: alias_id, payload: payload} = decoded) do
    case state.aliases[alias_id] do
      %MOQX.Subscription{} = subscription when not is_nil(decoded.status) ->
        Transition.ok(state, events: [{:object_status, public_object(subscription, decoded)}])

      %MOQX.Subscription{track: %{track: ".catalog"}} ->
        case MOQX.Catalog.decode(payload) do
          {:ok, catalog} -> Transition.ok(state, events: [{:catalog, catalog}])
          {:error, reason} -> Transition.error(state, {:invalid_catalog, reason})
        end

      %MOQX.Subscription{} = subscription ->
        Transition.ok(state, events: [{:object, public_object(subscription, decoded)}])

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
end

defmodule MOQX.Protocol.CloudflareDraft14.Session do
  @moduledoc "Compatibility namespace for the Cloudflare draft-14 lifecycle state machine."
end
