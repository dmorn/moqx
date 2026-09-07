defmodule MOQX.Protocol.MOQLite05.Discovery do
  @moduledoc false
  alias MOQX.Event.{BroadcastAvailable, BroadcastWithdrawn, DiscoveryDone, DiscoveryReady}
  alias MOQX.Protocol.MOQLite05.{Codec, Messages}
  alias MOQX.Protocol.Transition
  @max_frame 65_536

  def start(state, operation) do
    limit = Keyword.get(operation.options, :max_broadcasts, 1024)

    if is_binary(operation.prefix) and String.valid?(operation.prefix) and
         byte_size(operation.prefix) <= 4096 and
         is_integer(limit) and limit > 0 and
         Keyword.keys(operation.options) -- [:max_broadcasts] == [] do
      id = state.next_discovery_id
      handle = %MOQX.Discovery{scope: state.handle_scope, id: id, prefix: operation.prefix}

      entry = %{
        handle: handle,
        buffer: <<>>,
        remaining: nil,
        broadcasts: MapSet.new(),
        limit: limit
      }

      state = %{
        state
        | next_discovery_id: id + 1,
          discoveries: Map.put(state.discoveries, id, entry)
      }

      request =
        Codec.encode_announce_request(%Messages.AnnounceRequest{
          broadcast_path_prefix: operation.prefix
        })

      Transition.ok(state,
        events: [{:discovery_started, handle}],
        actions: [
          {:open_stream, {:discovery, id}, [direction: :bidirectional, active: true],
           <<1, request::binary>>}
        ]
      )
    else
      Transition.error(state, :invalid_discovery_options)
    end
  end

  def cancel(state, handle) do
    case state.discoveries[handle.id] do
      %{handle: ^handle} -> finish(state, handle.id, :cancelled)
      _ -> Transition.error(state, :unknown_discovery)
    end
  end

  def data(state, id, data) do
    case state.discoveries[id] do
      nil -> Transition.ok(state)
      entry -> parse(state, id, %{entry | buffer: entry.buffer <> data}, [])
    end
  end

  def finish(state, id, reason) do
    case Map.pop(state.discoveries, id) do
      {nil, _} ->
        Transition.ok(state)

      {entry, rest} ->
        Transition.ok(%{state | discoveries: rest},
          events: ended_events(entry, reason),
          actions: [
            {:abort_stream_receiving, {:discovery, id}, 0},
            {:send_stream, {:discovery, id}, <<>>, [finish: true]}
          ]
        )
    end
  end

  def close_all(state) do
    events =
      state.discoveries
      |> Enum.sort()
      |> Enum.flat_map(fn {_id, entry} -> ended_events(entry, :connection_closed) end)

    {%{state | discoveries: %{}}, events}
  end

  defp ended_events(entry, reason) do
    withdrawn =
      entry.broadcasts
      |> Enum.sort()
      |> Enum.map(&%BroadcastWithdrawn{discovery: entry.handle, path: &1, reason: reason})

    withdrawn ++ [%DiscoveryDone{discovery: entry.handle, reason: reason}]
  end

  defp parse(state, id, entry, events) do
    case frame(entry.buffer) do
      :more ->
        Transition.ok(%{state | discoveries: Map.put(state.discoveries, id, entry)},
          events: events
        )

      {:error, reason} ->
        fail(state, id, entry, events, reason)

      {:ok, framed, rest} ->
        case message(entry, framed) do
          {:ok, entry, next_events} ->
            parse(state, id, %{entry | buffer: rest}, events ++ next_events)

          {:error, reason} ->
            fail(state, id, entry, events, reason)
        end
    end
  end

  defp fail(state, id, entry, events, reason) do
    {:ok, transition} =
      finish(%{state | discoveries: Map.put(state.discoveries, id, entry)}, id, reason)

    {:ok, %{transition | events: events ++ transition.events}}
  end

  defp message(%{remaining: nil} = entry, framed) do
    case Codec.decode_announce_ok(framed) do
      {:ok, %{active_count: count}} when count <= entry.limit ->
        entry = %{entry | remaining: count}
        {:ok, entry, if(count == 0, do: [%DiscoveryReady{discovery: entry.handle}], else: [])}

      _ ->
        {:error, :invalid_announcement}
    end
  end

  defp message(entry, framed) do
    case Codec.decode_announce_broadcast(framed) do
      {:ok, broadcast} -> update(entry, broadcast)
      _ -> {:error, :invalid_announcement}
    end
  end

  defp update(entry, %{status: :active, path_suffix: suffix}) do
    path = entry.handle.prefix <> suffix
    known? = MapSet.member?(entry.broadcasts, path)

    cond do
      entry.remaining > 0 and known? ->
        {:error, :invalid_announcement}

      not known? and MapSet.size(entry.broadcasts) >= entry.limit ->
        {:error, :too_many_broadcasts}

      true ->
        events =
          if known?, do: [], else: [%BroadcastAvailable{discovery: entry.handle, path: path}]

        events =
          if entry.remaining == 1,
            do: events ++ [%DiscoveryReady{discovery: entry.handle}],
            else: events

        {:ok,
         %{
           entry
           | broadcasts: MapSet.put(entry.broadcasts, path),
             remaining: max(entry.remaining - 1, 0)
         }, events}
    end
  end

  defp update(%{remaining: remaining}, %{status: :ended}) when remaining > 0,
    do: {:error, :invalid_announcement}

  defp update(entry, %{status: :ended, path_suffix: suffix}) do
    path = entry.handle.prefix <> suffix

    events =
      if MapSet.member?(entry.broadcasts, path),
        do: [%BroadcastWithdrawn{discovery: entry.handle, path: path, reason: :withdrawn}],
        else: []

    {:ok, %{entry | broadcasts: MapSet.delete(entry.broadcasts, path)}, events}
  end

  defp frame(buffer) do
    case MOQX.Codec.decode_varint(buffer) do
      {:ok, length, _rest} when length > @max_frame ->
        {:error, :announcement_too_large}

      {:ok, length, rest} when byte_size(rest) >= length ->
        header_size = byte_size(buffer) - byte_size(rest)

        {:ok, binary_part(buffer, 0, header_size + length),
         binary_part(rest, length, byte_size(rest) - length)}

      _ ->
        :more
    end
  end
end
