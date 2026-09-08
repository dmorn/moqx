defmodule MOQX.Protocol.MOQLite05.MetadataDemand do
  @moduledoc false
  alias MOQX.Event.{PublicationTrackRequestDone, PublicationTrackRequested}
  alias MOQX.Protocol.MOQLite05.{Codec, Messages}
  alias MOQX.Protocol.Transition

  def validate_options(options) do
    mode = Keyword.get(options, :missing_track_metadata, :reject)
    timeout = Keyword.get(options, :track_metadata_timeout, 5_000)
    limit = Keyword.get(options, :max_pending_track_metadata, 128)

    if mode in [:reject, :controlled] and is_integer(timeout) and timeout >= 0 and
         timeout <= 4_294_967_295 and is_integer(limit) and limit > 0,
       do: :ok,
       else: {:error, :invalid_track_metadata_options}
  end

  def request(state, stream_id, track) do
    state = %{state | peer_stream_buffers: Map.delete(state.peer_stream_buffers, stream_id)}

    entry =
      Enum.find_value(state.publications, fn {_id, entry} ->
        if Enum.join(entry.publication.namespace, "/") == track.broadcast_path, do: entry
      end)

    if entry && Keyword.get(entry.options, :missing_track_metadata, :reject) == :controlled &&
         pending_count(state, entry.publication) <
           Keyword.get(entry.options, :max_pending_track_metadata, 128) do
      request = %MOQX.PublicationTrackRequest{
        handle: %MOQX.PublicationTrackRequest.Handle{
          scope: state.handle_scope,
          id: state.next_track_request_id
        },
        publication: entry.publication,
        track: %MOQX.TrackRef{namespace: entry.publication.namespace, track: track.track_name},
        timeout_ms: Keyword.get(entry.options, :track_metadata_timeout, 5_000)
      }

      pending = %{request: request, stream_id: stream_id, receive_finished?: false}

      state = %{
        state
        | next_track_request_id: state.next_track_request_id + 1,
          pending_track_requests:
            Map.put(state.pending_track_requests, request.handle.id, pending)
      }

      Transition.ok(state,
        events: [%PublicationTrackRequested{request: request}],
        actions: [{:start_timer, {:track_metadata, request.handle}, request.timeout_ms}]
      )
    else
      Transition.ok(state, actions: [{:abort_stream_sending, {:peer_stream, stream_id}, 0x10}])
    end
  end

  defp pending_count(state, publication),
    do:
      Enum.count(state.pending_track_requests, fn {_, entry} ->
        entry.request.publication == publication
      end)

  def registered(state, track_entry) do
    {pending, remaining} =
      Enum.split_with(state.pending_track_requests, fn {_, entry} ->
        entry.request.publication == track_entry.track.publication &&
          entry.request.track == track_entry.track.track
      end)

    state = %{state | pending_track_requests: Map.new(remaining)}

    events =
      Enum.map(pending, fn {_, entry} ->
        %PublicationTrackRequestDone{request: entry.request, reason: :registered}
      end)

    actions =
      Enum.flat_map(pending, fn {_, entry} ->
        info =
          struct!(
            Messages.TrackInfo,
            Map.take(track_entry, [
              :publisher_priority,
              :publisher_ordered,
              :publisher_max_latency,
              :timescale
            ])
          )

        [
          {:cancel_timer, {:track_metadata, entry.request.handle}},
          {:send_stream, {:peer_stream, entry.stream_id}, Codec.encode_track_info(info),
           [finish: true]}
        ]
      end)

    {state, events, actions}
  end

  def timeout(state, handle) do
    case Enum.find(state.pending_track_requests, fn {_, entry} ->
           entry.request.handle == handle
         end) do
      {id, entry} ->
        Transition.ok(
          %{state | pending_track_requests: Map.delete(state.pending_track_requests, id)},
          events: [%PublicationTrackRequestDone{request: entry.request, reason: :timed_out}],
          actions: abort_actions(entry, 2)
        )

      nil ->
        Transition.ok(state)
    end
  end

  def reject(state, request, error_code) do
    case Enum.find(state.pending_track_requests, fn {_, entry} -> entry.request == request end) do
      {id, entry} ->
        Transition.ok(
          %{state | pending_track_requests: Map.delete(state.pending_track_requests, id)},
          events: [%PublicationTrackRequestDone{request: request, reason: :rejected}],
          actions: [
            {:cancel_timer, {:track_metadata, request.handle}} | abort_actions(entry, error_code)
          ]
        )

      nil ->
        Transition.error(state, :stale_track_request)
    end
  end

  def peer_event(state, stream_id, event) do
    case Enum.find(state.pending_track_requests, fn {_, entry} -> entry.stream_id == stream_id end) do
      {id, entry} when event == :peer_finished_sending ->
        Transition.ok(%{
          state
          | pending_track_requests:
              Map.put(state.pending_track_requests, id, %{entry | receive_finished?: true})
        })

      {id, entry} ->
        actions =
          case event do
            :closed -> []
            :peer_aborted_sending -> abort_actions(%{entry | receive_finished?: true}, 0)
            _ -> abort_actions(entry, 0)
          end

        Transition.ok(
          %{state | pending_track_requests: Map.delete(state.pending_track_requests, id)},
          events: [%PublicationTrackRequestDone{request: entry.request, reason: :peer_cancelled}],
          actions: [{:cancel_timer, {:track_metadata, entry.request.handle}} | actions]
        )

      nil ->
        :unknown
    end
  end

  def data(state, stream_id, data) do
    case Enum.find(state.pending_track_requests, fn {_, entry} -> entry.stream_id == stream_id end) do
      {_id, _entry} when data == <<>> ->
        Transition.ok(state)

      {id, entry} ->
        Transition.ok(
          %{state | pending_track_requests: Map.delete(state.pending_track_requests, id)},
          events: [%PublicationTrackRequestDone{request: entry.request, reason: :invalid_request}],
          actions: [
            {:cancel_timer, {:track_metadata, entry.request.handle}} | abort_actions(entry, 2)
          ]
        )

      nil ->
        :unknown
    end
  end

  def finish_publication(state, publication) do
    {pending, remaining} =
      Enum.split_with(state.pending_track_requests, fn {_, entry} ->
        entry.request.publication == publication
      end)

    events =
      Enum.map(pending, fn {_, entry} ->
        %PublicationTrackRequestDone{request: entry.request, reason: :publication_finished}
      end)

    actions =
      Enum.flat_map(pending, fn {_, entry} ->
        [{:cancel_timer, {:track_metadata, entry.request.handle}} | abort_actions(entry, 0x10)]
      end)

    {%{state | pending_track_requests: Map.new(remaining)}, events, actions}
  end

  def close_all(state) do
    events =
      Enum.map(state.pending_track_requests, fn {_, entry} ->
        %PublicationTrackRequestDone{request: entry.request, reason: :connection_closed}
      end)

    {%{state | pending_track_requests: %{}}, events}
  end

  defp abort_actions(entry, code) do
    receiving =
      if entry.receive_finished?,
        do: [],
        else: [{:abort_stream_receiving, {:peer_stream, entry.stream_id}, code}]

    receiving ++ [{:abort_stream_sending, {:peer_stream, entry.stream_id}, code}]
  end
end
