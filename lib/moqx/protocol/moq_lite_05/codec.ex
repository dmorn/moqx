defmodule MOQX.Protocol.MOQLite05.Codec do
  @moduledoc "Payload codecs for MoQ Lite draft-05."

  alias MOQX.Codec

  alias MOQX.Protocol.MOQLite05.Messages.{
    AnnounceBroadcast,
    AnnounceOk,
    AnnounceRequest,
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

  @spec encode_setup(Setup.t()) :: binary()
  def encode_setup(%Setup{} = setup) do
    parameters =
      []
      |> maybe_parameter(0x1, encode_probe(setup.probe), setup.probe != :none)
      |> maybe_parameter(0x2, setup.path, not is_nil(setup.path))
      |> maybe_parameter(0x3, encode_role(setup.role), setup.role != :both)
      |> Enum.reverse()

    payload = [Codec.encode_varint(length(parameters)), parameters]

    [Codec.encode_varint(IO.iodata_length(payload)), payload]
    |> IO.iodata_to_binary()
  end

  @spec decode_setup(binary()) :: {:ok, Setup.t()} | {:error, :invalid_setup}
  def decode_setup(data) when is_binary(data) do
    with {:ok, length, rest} <- Codec.decode_varint(data),
         {:ok, payload, <<>>} <- take(rest, length),
         {:ok, count, parameters} <- Codec.decode_varint(payload),
         {:ok, parameters} <- decode_parameters(parameters, count, %{}),
         {:ok, path} <- decode_path(parameters),
         {:ok, probe} <- decode_probe(parameters),
         {:ok, role} <- decode_role(parameters) do
      {:ok, %Setup{path: path, probe: probe, role: role}}
    else
      _error -> {:error, :invalid_setup}
    end
  end

  @spec encode_track_info(TrackInfo.t()) :: binary()
  def encode_track_info(%TrackInfo{} = info) do
    payload = [
      <<info.publisher_priority, ordered(info.publisher_ordered)>>,
      Codec.encode_varint(info.publisher_max_latency),
      Codec.encode_varint(info.timescale)
    ]

    [Codec.encode_varint(IO.iodata_length(payload)), payload]
    |> IO.iodata_to_binary()
  end

  @spec decode_track_info(binary()) :: {:ok, TrackInfo.t()} | {:error, :invalid_track_info}
  def decode_track_info(data) when is_binary(data) do
    with {:ok, length, rest} <- Codec.decode_varint(data),
         {:ok, <<priority, ordered, values::binary>>, <<>>} <- take(rest, length),
         {:ok, ordered} <- decode_ordered(ordered),
         {:ok, max_latency, rest} <- Codec.decode_varint(values),
         {:ok, timescale, <<>>} when timescale > 0 <- Codec.decode_varint(rest) do
      {:ok,
       %TrackInfo{
         publisher_priority: priority,
         publisher_ordered: ordered,
         publisher_max_latency: max_latency,
         timescale: timescale
       }}
    else
      _error -> {:error, :invalid_track_info}
    end
  end

  @spec encode_track(Track.t()) :: binary()
  def encode_track(%Track{} = track) do
    payload = [Codec.encode_string(track.broadcast_path), Codec.encode_string(track.track_name)]

    [Codec.encode_varint(IO.iodata_length(payload)), payload]
    |> IO.iodata_to_binary()
  end

  @spec decode_track(binary()) :: {:ok, Track.t()} | {:error, :invalid_track}
  def decode_track(data) when is_binary(data) do
    with {:ok, length, rest} <- Codec.decode_varint(data),
         {:ok, payload, <<>>} <- take(rest, length),
         {:ok, broadcast_path, rest} <- Codec.decode_string(payload),
         {:ok, track_name, <<>>} <- Codec.decode_string(rest) do
      {:ok, %Track{broadcast_path: broadcast_path, track_name: track_name}}
    else
      _error -> {:error, :invalid_track}
    end
  end

  @spec encode_subscribe(Subscribe.t()) :: binary()
  def encode_subscribe(%Subscribe{} = subscribe) do
    payload = [
      Codec.encode_varint(subscribe.subscribe_id),
      Codec.encode_string(subscribe.broadcast_path),
      Codec.encode_string(subscribe.track_name),
      <<subscribe.subscriber_priority, ordered(subscribe.subscriber_ordered)>>,
      Codec.encode_varint(subscribe.subscriber_max_latency),
      Codec.encode_varint(encode_group_bound(subscribe.group_start)),
      Codec.encode_varint(encode_group_bound(subscribe.group_end))
    ]

    [Codec.encode_varint(IO.iodata_length(payload)), payload]
    |> IO.iodata_to_binary()
  end

  @spec decode_subscribe(binary()) :: {:ok, Subscribe.t()} | {:error, :invalid_subscribe}
  def decode_subscribe(data) when is_binary(data) do
    with {:ok, length, rest} <- Codec.decode_varint(data),
         {:ok, payload, <<>>} <- take(rest, length),
         {:ok, subscribe_id, rest} <- Codec.decode_varint(payload),
         {:ok, broadcast_path, rest} <- Codec.decode_string(rest),
         {:ok, track_name, <<priority, ordered, rest::binary>>} <- Codec.decode_string(rest),
         {:ok, ordered} <- decode_ordered(ordered),
         {:ok, max_latency, rest} <- Codec.decode_varint(rest),
         {:ok, group_start, rest} <- Codec.decode_varint(rest),
         {:ok, group_end, <<>>} <- Codec.decode_varint(rest) do
      {:ok,
       %Subscribe{
         subscribe_id: subscribe_id,
         broadcast_path: broadcast_path,
         track_name: track_name,
         subscriber_priority: priority,
         subscriber_ordered: ordered,
         subscriber_max_latency: max_latency,
         group_start: decode_group_bound(group_start),
         group_end: decode_group_bound(group_end)
       }}
    else
      _error -> {:error, :invalid_subscribe}
    end
  end

  @spec encode_subscribe_update(SubscribeUpdate.t()) :: binary()
  def encode_subscribe_update(%SubscribeUpdate{} = update) do
    payload = [
      <<update.subscriber_priority, ordered(update.subscriber_ordered)>>,
      Codec.encode_varint(update.subscriber_max_latency),
      Codec.encode_varint(encode_group_bound(update.group_start)),
      Codec.encode_varint(encode_group_bound(update.group_end))
    ]

    [Codec.encode_varint(IO.iodata_length(payload)), payload]
    |> IO.iodata_to_binary()
  end

  @spec decode_subscribe_update(binary()) ::
          {:ok, SubscribeUpdate.t()} | {:error, :invalid_subscribe_update}
  def decode_subscribe_update(data) when is_binary(data) do
    with {:ok, length, rest} <- Codec.decode_varint(data),
         {:ok, <<priority, ordered, values::binary>>, <<>>} <- take(rest, length),
         {:ok, ordered} <- decode_ordered(ordered),
         {:ok, max_latency, rest} <- Codec.decode_varint(values),
         {:ok, group_start, rest} <- Codec.decode_varint(rest),
         {:ok, group_end, <<>>} <- Codec.decode_varint(rest) do
      {:ok,
       %SubscribeUpdate{
         subscriber_priority: priority,
         subscriber_ordered: ordered,
         subscriber_max_latency: max_latency,
         group_start: decode_group_bound(group_start),
         group_end: decode_group_bound(group_end)
       }}
    else
      _error -> {:error, :invalid_subscribe_update}
    end
  end

  @spec encode_subscribe_response(SubscribeOk.t() | SubscribeEnd.t() | SubscribeDrop.t()) ::
          binary()
  def encode_subscribe_response(%SubscribeOk{group: group}) do
    [Codec.encode_varint(0x0), framed(Codec.encode_varint(group))]
    |> IO.iodata_to_binary()
  end

  def encode_subscribe_response(%SubscribeEnd{group: group}) do
    [Codec.encode_varint(0x1), framed(Codec.encode_varint(group))]
    |> IO.iodata_to_binary()
  end

  def encode_subscribe_response(%SubscribeDrop{} = drop) do
    payload = [
      Codec.encode_varint(drop.group_start),
      Codec.encode_varint(drop.group_end),
      Codec.encode_varint(drop.error_code)
    ]

    [Codec.encode_varint(0x2), framed(payload)]
    |> IO.iodata_to_binary()
  end

  @spec decode_subscribe_responses(binary()) ::
          {:ok, [SubscribeOk.t() | SubscribeEnd.t() | SubscribeDrop.t()], binary()}
          | {:error, :invalid_subscribe_response}
  def decode_subscribe_responses(data) when is_binary(data) do
    decode_subscribe_responses(data, [])
  end

  defp decode_subscribe_responses(<<>>, responses),
    do: {:ok, Enum.reverse(responses), <<>>}

  defp decode_subscribe_responses(data, responses) do
    case Codec.decode_varint(data) do
      {:ok, type, after_type} ->
        case split_framed_payload(after_type) do
          {:ok, payload, rest} ->
            decode_subscribe_response_payload(type, payload, rest, responses)

          :more ->
            {:ok, Enum.reverse(responses), data}
        end

      {:error, :incomplete} ->
        {:ok, Enum.reverse(responses), data}
    end
  end

  defp decode_subscribe_response_payload(type, payload, rest, responses) do
    case decode_subscribe_response(type, payload) do
      {:ok, response} -> decode_subscribe_responses(rest, [response | responses])
      {:error, :invalid_subscribe_response} = error -> error
    end
  end

  defp decode_subscribe_response(type, payload) when type in [0x0, 0x1] do
    case Codec.decode_varint(payload) do
      {:ok, group, <<>>} ->
        message =
          if type == 0x0, do: %SubscribeOk{group: group}, else: %SubscribeEnd{group: group}

        {:ok, message}

      _error ->
        {:error, :invalid_subscribe_response}
    end
  end

  defp decode_subscribe_response(0x2, payload) do
    with {:ok, group_start, rest} <- Codec.decode_varint(payload),
         {:ok, group_end, rest} <- Codec.decode_varint(rest),
         {:ok, error_code, <<>>} <- Codec.decode_varint(rest) do
      {:ok,
       %SubscribeDrop{
         group_start: group_start,
         group_end: group_end,
         error_code: error_code
       }}
    else
      _error -> {:error, :invalid_subscribe_response}
    end
  end

  defp decode_subscribe_response(_unknown, _payload),
    do: {:error, :invalid_subscribe_response}

  @spec encode_frame(Frame.t()) :: binary()
  def encode_frame(%Frame{} = frame) do
    [
      Codec.encode_varint(zigzag_encode(frame.timestamp_delta)),
      Codec.encode_varint(byte_size(frame.payload)),
      frame.payload
    ]
    |> IO.iodata_to_binary()
  end

  @spec decode_frame(binary()) :: {:ok, Frame.t(), binary()} | :more
  def decode_frame(data) when is_binary(data) do
    with {:ok, timestamp_delta, rest} <- Codec.decode_varint(data),
         {:ok, length, rest} <- Codec.decode_varint(rest),
         {:ok, payload, rest} <- take(rest, length) do
      {:ok, %Frame{timestamp_delta: zigzag_decode(timestamp_delta), payload: payload}, rest}
    else
      _error -> :more
    end
  end

  @spec encode_group(Group.t()) :: binary()
  def encode_group(%Group{} = group) do
    [Codec.encode_varint(group.subscribe_id), Codec.encode_varint(group.group_sequence)]
    |> framed()
    |> IO.iodata_to_binary()
  end

  @spec decode_group(binary()) :: {:ok, Group.t()} | {:error, :invalid_group}
  def decode_group(data) when is_binary(data) do
    with {:ok, length, rest} <- Codec.decode_varint(data),
         {:ok, payload, <<>>} <- take(rest, length),
         {:ok, subscribe_id, rest} <- Codec.decode_varint(payload),
         {:ok, group_sequence, <<>>} <- Codec.decode_varint(rest) do
      {:ok, %Group{subscribe_id: subscribe_id, group_sequence: group_sequence}}
    else
      _error -> {:error, :invalid_group}
    end
  end

  @spec encode_announce_request(AnnounceRequest.t()) :: binary()
  def encode_announce_request(%AnnounceRequest{} = request) do
    [Codec.encode_string(request.broadcast_path_prefix), Codec.encode_varint(request.exclude_hop)]
    |> framed()
    |> IO.iodata_to_binary()
  end

  @spec decode_announce_request(binary()) ::
          {:ok, AnnounceRequest.t()} | {:error, :invalid_announce_request}
  def decode_announce_request(data) when is_binary(data) do
    with {:ok, payload} <- framed_payload(data),
         {:ok, prefix, rest} <- Codec.decode_string(payload),
         {:ok, exclude_hop, <<>>} <- Codec.decode_varint(rest) do
      {:ok, %AnnounceRequest{broadcast_path_prefix: prefix, exclude_hop: exclude_hop}}
    else
      _error -> {:error, :invalid_announce_request}
    end
  end

  @spec encode_announce_ok(AnnounceOk.t()) :: binary()
  def encode_announce_ok(%AnnounceOk{} = ok) do
    [Codec.encode_varint(ok.hop_id), Codec.encode_varint(ok.active_count)]
    |> framed()
    |> IO.iodata_to_binary()
  end

  @spec decode_announce_ok(binary()) :: {:ok, AnnounceOk.t()} | {:error, :invalid_announce_ok}
  def decode_announce_ok(data) when is_binary(data) do
    with {:ok, payload} <- framed_payload(data),
         {:ok, hop_id, rest} <- Codec.decode_varint(payload),
         {:ok, active_count, <<>>} <- Codec.decode_varint(rest) do
      {:ok, %AnnounceOk{hop_id: hop_id, active_count: active_count}}
    else
      _error -> {:error, :invalid_announce_ok}
    end
  end

  @spec encode_announce_broadcast(AnnounceBroadcast.t()) :: binary()
  def encode_announce_broadcast(%AnnounceBroadcast{} = broadcast) do
    payload = [
      Codec.encode_varint(announce_status(broadcast.status)),
      Codec.encode_string(broadcast.path_suffix),
      Codec.encode_varint(length(broadcast.hop_ids)),
      Enum.map(broadcast.hop_ids, &Codec.encode_varint/1)
    ]

    payload |> framed() |> IO.iodata_to_binary()
  end

  @spec decode_announce_broadcast(binary()) ::
          {:ok, AnnounceBroadcast.t()} | {:error, :invalid_announce_broadcast}
  def decode_announce_broadcast(data) when is_binary(data) do
    with {:ok, payload} <- framed_payload(data),
         {:ok, status, rest} <- Codec.decode_varint(payload),
         {:ok, status} <- decode_announce_status(status),
         {:ok, suffix, rest} <- Codec.decode_string(rest),
         {:ok, hop_count, rest} <- Codec.decode_varint(rest),
         {:ok, hop_ids, <<>>} <- decode_varints(rest, hop_count, []) do
      {:ok, %AnnounceBroadcast{status: status, path_suffix: suffix, hop_ids: hop_ids}}
    else
      _error -> {:error, :invalid_announce_broadcast}
    end
  end

  defp maybe_parameter(parameters, _id, _value, false), do: parameters

  defp maybe_parameter(parameters, id, value, true) do
    encoded = IO.iodata_to_binary(value)

    [
      [Codec.encode_varint(id), Codec.encode_varint(byte_size(encoded)), encoded]
      | parameters
    ]
  end

  defp encode_probe(:report), do: Codec.encode_varint(1)
  defp encode_probe(:increase), do: Codec.encode_varint(2)
  defp encode_probe(:none), do: <<>>

  defp encode_role(:publisher), do: Codec.encode_varint(1)
  defp encode_role(:subscriber), do: Codec.encode_varint(2)
  defp encode_role(:both), do: <<>>

  defp decode_parameters(<<>>, 0, parameters), do: {:ok, parameters}

  defp decode_parameters(data, count, parameters) when count > 0 do
    with {:ok, id, rest} <- Codec.decode_varint(data),
         false <- Map.has_key?(parameters, id),
         {:ok, length, rest} <- Codec.decode_varint(rest),
         {:ok, value, rest} <- take(rest, length) do
      decode_parameters(rest, count - 1, Map.put(parameters, id, value))
    else
      _error -> {:error, :invalid_parameters}
    end
  end

  defp decode_parameters(_data, _count, _parameters), do: {:error, :invalid_parameters}

  defp decode_path(parameters) do
    case Map.fetch(parameters, 0x2) do
      {:ok, path} -> if String.valid?(path), do: {:ok, path}, else: {:error, :invalid_utf8}
      :error -> {:ok, nil}
    end
  end

  defp decode_probe(parameters), do: decode_enum_parameter(parameters, 0x1, :none, &probe/1)
  defp decode_role(parameters), do: decode_enum_parameter(parameters, 0x3, :both, &role/1)

  defp decode_enum_parameter(parameters, id, default, decode) do
    case Map.fetch(parameters, id) do
      {:ok, encoded} ->
        case Codec.decode_varint(encoded) do
          {:ok, value, <<>>} -> {:ok, decode.(value)}
          _error -> {:error, :invalid_parameter}
        end

      :error ->
        {:ok, default}
    end
  end

  defp probe(0), do: :none
  defp probe(1), do: :report
  defp probe(_other), do: :increase

  defp role(1), do: :publisher
  defp role(2), do: :subscriber
  defp role(_other), do: :both

  defp ordered(true), do: 1
  defp ordered(false), do: 0

  defp decode_ordered(0), do: {:ok, false}
  defp decode_ordered(1), do: {:ok, true}
  defp decode_ordered(_other), do: {:error, :invalid_ordered}

  defp encode_group_bound(nil), do: 0
  defp encode_group_bound(group), do: group + 1

  defp decode_group_bound(0), do: nil
  defp decode_group_bound(group), do: group - 1

  defp announce_status(:ended), do: 0
  defp announce_status(:active), do: 1

  defp decode_announce_status(0), do: {:ok, :ended}
  defp decode_announce_status(1), do: {:ok, :active}
  defp decode_announce_status(_other), do: {:error, :invalid_status}

  defp zigzag_encode(value) when value >= 0, do: value * 2
  defp zigzag_encode(value), do: -value * 2 - 1

  defp zigzag_decode(value) when rem(value, 2) == 0, do: div(value, 2)
  defp zigzag_decode(value), do: -div(value + 1, 2)

  defp take(data, length) when byte_size(data) >= length do
    <<value::binary-size(^length), rest::binary>> = data
    {:ok, value, rest}
  end

  defp take(_data, _length), do: {:error, :incomplete}

  defp framed(payload), do: [Codec.encode_varint(IO.iodata_length(payload)), payload]

  defp framed_payload(data) do
    with {:ok, length, rest} <- Codec.decode_varint(data),
         {:ok, payload, <<>>} <- take(rest, length) do
      {:ok, payload}
    end
  end

  defp split_framed_payload(data) do
    case Codec.decode_varint(data) do
      {:ok, length, rest} when byte_size(rest) >= length ->
        <<payload::binary-size(^length), trailing::binary>> = rest
        {:ok, payload, trailing}

      _incomplete ->
        :more
    end
  end

  defp decode_varints(rest, 0, values), do: {:ok, Enum.reverse(values), rest}

  defp decode_varints(data, count, values) do
    with {:ok, value, rest} <- Codec.decode_varint(data) do
      decode_varints(rest, count - 1, [value | values])
    end
  end
end
