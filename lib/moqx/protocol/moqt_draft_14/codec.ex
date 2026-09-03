defmodule MOQX.Protocol.MOQTDraft14.Codec do
  @moduledoc "Wire primitives and message codecs shared by draft-14 implementations."

  import Bitwise

  alias MOQX.Protocol.MOQTDraft14.Messages

  @draft_14 0xFF00000E

  @spec client_setup(map()) :: binary()
  def client_setup(params \\ %{}) do
    encode(%Messages.ClientSetup{versions: [@draft_14], params: Map.put_new(params, 2, 100)})
  end

  @doc "Encodes a draft-14 AUTHORIZATION TOKEN using Alias Type USE_VALUE."
  @spec authorization_token(binary(), non_neg_integer()) :: binary()
  def authorization_token(token, token_type \\ 0) when is_binary(token) do
    IO.iodata_to_binary([encode_varint(0x03), encode_varint(token_type), token])
  end

  @spec subscribe(non_neg_integer(), MOQX.TrackRef.t(), keyword()) :: binary()
  def subscribe(request_id, %MOQX.TrackRef{} = track, options \\ []) do
    encode(%Messages.Subscribe{
      request_id: request_id,
      track_namespace: track.namespace,
      track_name: track.track,
      subscriber_priority: Keyword.get(options, :priority, 127),
      filter_type: Keyword.get(options, :filter_type, :largest_object)
    })
  end

  @spec encode(struct()) :: binary()
  def encode(%Messages.ClientSetup{} = setup) do
    versions = Enum.map(setup.versions, &encode_varint/1)
    params = encode_params(setup.params)
    frame(0x20, [encode_varint(length(setup.versions)), versions, params])
  end

  def encode(%Messages.Subscribe{} = subscribe) do
    namespace = subscribe.track_namespace

    namespace =
      [
        encode_varint(length(namespace))
        | Enum.flat_map(namespace, fn component ->
            [encode_varint(byte_size(component)), component]
          end)
      ]

    frame(0x03, [
      encode_varint(subscribe.request_id),
      namespace,
      encode_varint(byte_size(subscribe.track_name)),
      subscribe.track_name,
      <<subscribe.subscriber_priority, encode_group_order(subscribe.group_order),
        encode_bool(subscribe.forward)>>,
      encode_filter(subscribe),
      encode_params(subscribe.params)
    ])
  end

  def encode(%Messages.Unsubscribe{request_id: request_id}) do
    frame(0x0A, encode_varint(request_id))
  end

  def encode(%Messages.PublishNamespace{} = publish) do
    frame(0x06, [
      encode_varint(publish.request_id),
      encode_namespace(publish.track_namespace),
      encode_params(publish.params)
    ])
  end

  def encode(%Messages.SubscribeOk{} = subscribe) do
    {content_exists, location} = encode_optional_location(subscribe.largest_location)

    frame(0x04, [
      encode_varint(subscribe.request_id),
      encode_varint(subscribe.track_alias),
      encode_varint(subscribe.expires || 0),
      <<encode_group_order(subscribe.group_order), content_exists>>,
      location,
      encode_params(subscribe.params)
    ])
  end

  def encode(%Messages.SubscribeError{} = error) do
    frame(0x05, [
      encode_varint(error.request_id),
      encode_varint(error.error_code),
      encode_reason(error.reason_phrase)
    ])
  end

  def encode(%Messages.PublishDone{} = done) do
    frame(0x0B, [
      encode_varint(done.request_id),
      encode_varint(done.status_code),
      encode_varint(done.stream_count),
      encode_reason(done.reason_phrase)
    ])
  end

  def encode(%Messages.PublishNamespaceDone{} = done) do
    frame(0x09, encode_namespace(done.track_namespace))
  end

  @spec unsubscribe(non_neg_integer()) :: binary()
  def unsubscribe(request_id), do: encode(%Messages.Unsubscribe{request_id: request_id})

  @spec encode_subgroup(non_neg_integer(), MOQX.Object.t()) :: binary()
  def encode_subgroup(track_alias, %MOQX.Object{timestamp: _timestamp} = object) do
    subgroup_id = object.subgroup_id || 0
    priority = object.publisher_priority || 127

    IO.iodata_to_binary([
      encode_varint(0x15),
      encode_varint(track_alias),
      encode_varint(object.group_id),
      encode_varint(subgroup_id),
      <<priority>>,
      encode_varint(object.object_id),
      encode_varint(0),
      encode_object_payload(object)
    ])
  end

  @spec decode_control(binary()) ::
          {:ok, [{non_neg_integer(), binary()}], binary()} | {:error, term()}
  def decode_control(buffer), do: decode_control(buffer, [])

  defp decode_control(<<>>, frames), do: {:ok, Enum.reverse(frames), <<>>}

  defp decode_control(buffer, frames) do
    with {:ok, type, after_type} <- decode_varint(buffer),
         <<length::16, payload_and_rest::binary>> <- after_type do
      if byte_size(payload_and_rest) < length do
        {:ok, Enum.reverse(frames), buffer}
      else
        <<payload::binary-size(^length), rest::binary>> = payload_and_rest
        decode_control(rest, [{type, payload} | frames])
      end
    else
      :more -> {:ok, Enum.reverse(frames), buffer}
      _other -> {:ok, Enum.reverse(frames), buffer}
    end
  end

  @spec decode_server_setup(binary()) :: {:ok, non_neg_integer()} | {:error, term()}
  def decode_server_setup(payload) do
    with {:ok, @draft_14, rest} <- decode_varint(payload),
         {:ok, _params, <<>>} <- skip_params(rest) do
      {:ok, %Messages.ServerSetup{selected_version: @draft_14}}
    else
      {:ok, version, _rest} -> {:error, {:unsupported_version, version}}
      _other -> {:error, :invalid_server_setup}
    end
  end

  @spec decode_subscribe_ok(binary()) :: {:ok, map()} | {:error, term()}
  def decode_subscribe_ok(payload) do
    with {:ok, request_id, rest} <- decode_varint(payload),
         {:ok, track_alias, rest} <- decode_varint(rest),
         {:ok, expires, <<group_order, content_exists, rest::binary>>} <- decode_varint(rest),
         {:ok, largest_location, rest} <- decode_location(content_exists, rest),
         {:ok, _params, <<>>} <- skip_params(rest) do
      {:ok,
       %Messages.SubscribeOk{
         request_id: request_id,
         track_alias: track_alias,
         expires: expires,
         group_order: group_order,
         largest_location: largest_location
       }}
    else
      _other -> {:error, :invalid_subscribe_ok}
    end
  end

  @spec decode_subscribe_error(binary()) :: {:ok, struct()} | {:error, term()}
  def decode_subscribe_error(payload) do
    with {:ok, request_id, rest} <- decode_varint(payload),
         {:ok, error_code, rest} <- decode_varint(rest),
         {:ok, reason_length, rest} <- decode_varint(rest),
         true <- byte_size(rest) == reason_length do
      {:ok,
       %Messages.SubscribeError{
         request_id: request_id,
         error_code: error_code,
         reason_phrase: rest
       }}
    else
      _other -> {:error, :invalid_subscribe_error}
    end
  end

  @spec decode_publish_done(binary()) :: {:ok, struct()} | {:error, term()}
  def decode_publish_done(payload) do
    with {:ok, request_id, rest} <- decode_varint(payload),
         {:ok, status_code, rest} <- decode_varint(rest),
         {:ok, stream_count, rest} <- decode_varint(rest),
         {:ok, reason_length, rest} <- decode_varint(rest),
         true <- byte_size(rest) == reason_length do
      {:ok,
       %Messages.PublishDone{
         request_id: request_id,
         status_code: status_code,
         stream_count: stream_count,
         reason_phrase: rest
       }}
    else
      _other -> {:error, :invalid_publish_done}
    end
  end

  @spec decode_subscribe(binary()) :: {:ok, struct()} | {:error, term()}
  def decode_subscribe(payload) do
    with {:ok, request_id, rest} <- decode_varint(payload),
         {:ok, namespace, rest} <- decode_namespace(rest),
         {:ok, track_name, rest} <- decode_bytes(rest),
         <<priority, group_order, forward, rest::binary>>
         when group_order in 0..2 and forward in 0..1 <- rest,
         {:ok, filter_type, rest} <- decode_varint(rest),
         {:ok, filter_type, start_location, end_group, rest} <- decode_filter(filter_type, rest),
         {:ok, params, <<>>} <- decode_params(rest) do
      {:ok,
       %Messages.Subscribe{
         request_id: request_id,
         track_namespace: namespace,
         track_name: track_name,
         subscriber_priority: priority,
         group_order: decode_group_order(group_order),
         forward: forward == 1,
         filter_type: filter_type,
         start_location: start_location,
         end_group: end_group,
         params: params
       }}
    else
      _other -> {:error, :invalid_subscribe}
    end
  end

  @spec decode_unsubscribe(binary()) :: {:ok, struct()} | {:error, term()}
  def decode_unsubscribe(payload) do
    case decode_varint(payload) do
      {:ok, request_id, <<>>} -> {:ok, %Messages.Unsubscribe{request_id: request_id}}
      _other -> {:error, :invalid_unsubscribe}
    end
  end

  @spec decode_publish_namespace_ok(binary()) :: {:ok, struct()} | {:error, term()}
  def decode_publish_namespace_ok(payload) do
    case decode_varint(payload) do
      {:ok, request_id, <<>>} -> {:ok, %Messages.PublishNamespaceOk{request_id: request_id}}
      _other -> {:error, :invalid_publish_namespace_ok}
    end
  end

  @spec decode_publish_namespace_error(binary()) :: {:ok, struct()} | {:error, term()}
  def decode_publish_namespace_error(payload) do
    with {:ok, request_id, rest} <- decode_varint(payload),
         {:ok, error_code, rest} <- decode_varint(rest),
         {:ok, reason, <<>>} <- decode_bytes(rest) do
      {:ok,
       %Messages.PublishNamespaceError{
         request_id: request_id,
         error_code: error_code,
         reason_phrase: reason
       }}
    else
      _other -> {:error, :invalid_publish_namespace_error}
    end
  end

  @spec decode_publish_namespace_cancel(binary()) :: {:ok, struct()} | {:error, term()}
  def decode_publish_namespace_cancel(payload) do
    with {:ok, namespace, rest} <- decode_namespace(payload),
         {:ok, error_code, rest} <- decode_varint(rest),
         {:ok, reason, <<>>} <- decode_bytes(rest) do
      {:ok,
       %Messages.PublishNamespaceCancel{
         track_namespace: namespace,
         error_code: error_code,
         reason_phrase: reason
       }}
    else
      _other -> {:error, :invalid_publish_namespace_cancel}
    end
  end

  @spec decode_subgroup_object(binary()) :: {:ok, map(), binary()} | :more | {:error, term()}
  def decode_subgroup_object(buffer) do
    with {:ok, header, rest} <- decode_subgroup_header(buffer) do
      decode_subgroup_object(header, 0, rest)
    end
  end

  @spec decode_subgroup_header(binary()) :: {:ok, struct(), binary()} | :more | {:error, term()}
  def decode_subgroup_header(buffer) do
    with {:ok, type, rest} <- decode_varint(buffer),
         true <- type in 0x10..0x1D,
         {:ok, alias_id, rest} <- decode_varint(rest),
         {:ok, group_id, rest} <- decode_varint(rest),
         {:ok, subgroup_id, rest} <- decode_optional_subgroup(type, rest),
         <<priority, rest::binary>> <- rest do
      {:ok,
       %Messages.SubgroupHeader{
         type: type,
         track_alias: alias_id,
         group_id: group_id,
         subgroup_id: subgroup_id,
         publisher_priority: priority
       }, rest}
    else
      :more -> :more
      false -> {:error, :invalid_subgroup_header}
      _other -> :more
    end
  end

  @spec decode_subgroup_object(struct(), non_neg_integer(), binary()) ::
          {:ok, struct(), binary()} | :more | {:error, term()}
  def decode_subgroup_object(%Messages.SubgroupHeader{} = header, current_object_id, buffer) do
    with {:ok, object_id_delta, rest} <- decode_varint(buffer),
         {:ok, rest} <- skip_extension_headers(header.type, rest),
         {:ok, payload_length, rest} <- decode_varint(rest),
         {:ok, status, payload, trailing} <- decode_object_payload(payload_length, rest) do
      {:ok,
       %Messages.SubgroupObject{
         type: header.type,
         track_alias: header.track_alias,
         group_id: header.group_id,
         subgroup_id: header.subgroup_id,
         priority: header.publisher_priority,
         object_id: current_object_id + object_id_delta,
         status: status,
         payload: payload
       }, trailing}
    else
      :more -> :more
    end
  end

  @spec encode_varint(non_neg_integer()) :: binary()
  def encode_varint(value) when value < 64, do: <<value>>
  def encode_varint(value) when value < 16_384, do: <<value ||| 0x4000::16>>
  def encode_varint(value) when value < 1_073_741_824, do: <<value ||| 0x80000000::32>>

  def encode_varint(value) when value < 4_611_686_018_427_387_904,
    do: <<value ||| 0xC000000000000000::64>>

  @spec decode_varint(binary()) :: {:ok, non_neg_integer(), binary()} | :more
  def decode_varint(<<prefix::2, _::6, _::binary>> = binary) do
    length = 1 <<< prefix

    if byte_size(binary) < length do
      :more
    else
      <<encoded::unsigned-size(^length)-unit(8), rest::binary>> = binary
      mask = (1 <<< (length * 8 - 2)) - 1
      {:ok, encoded &&& mask, rest}
    end
  end

  def decode_varint(_binary), do: :more

  defp frame(type, payload) do
    payload = IO.iodata_to_binary(payload)
    IO.iodata_to_binary([encode_varint(type), <<byte_size(payload)::16>>, payload])
  end

  defp encode_params(params) do
    entries = if is_map(params), do: Enum.sort_by(params, &elem(&1, 0)), else: params

    encoded =
      Enum.map(entries, fn
        {key, value} when rem(key, 2) == 0 ->
          [encode_varint(key), encode_varint(value)]

        {key, value} when is_binary(value) ->
          [encode_varint(key), encode_varint(byte_size(value)), value]
      end)

    [encode_varint(Enum.count(entries)), encoded]
  end

  defp encode_namespace(namespace) do
    [
      encode_varint(length(namespace))
      | Enum.flat_map(namespace, fn component ->
          [encode_varint(byte_size(component)), component]
        end)
    ]
  end

  defp encode_reason(reason), do: [encode_varint(byte_size(reason)), reason]

  defp encode_optional_location(nil), do: {0, <<>>}

  defp encode_optional_location({group_id, object_id}) do
    {1, [encode_varint(group_id), encode_varint(object_id)]}
  end

  defp encode_object_payload(%MOQX.Object{
         status: nil,
         extensions: _extensions,
         end_of_group?: _end_of_group?,
         payload: payload
       }) do
    [encode_varint(byte_size(payload)), payload]
  end

  defp encode_object_payload(%MOQX.Object{
         status: status,
         extensions: _extensions,
         end_of_group?: _end_of_group?
       }) do
    [encode_varint(0), encode_varint(encode_object_status(status))]
  end

  defp encode_group_order(:publisher), do: 0
  defp encode_group_order(:ascending), do: 1
  defp encode_group_order(:descending), do: 2

  defp decode_group_order(0), do: :publisher
  defp decode_group_order(1), do: :ascending
  defp decode_group_order(2), do: :descending
  defp decode_group_order(other), do: {:unknown, other}

  defp encode_bool(true), do: 1
  defp encode_bool(false), do: 0

  defp encode_filter(%Messages.Subscribe{filter_type: :next_group_start}),
    do: encode_varint(1)

  defp encode_filter(%Messages.Subscribe{filter_type: :largest_object}),
    do: encode_varint(2)

  defp encode_filter(%Messages.Subscribe{
         filter_type: :absolute_start,
         start_location: {group_id, object_id}
       }) do
    [encode_varint(3), encode_varint(group_id), encode_varint(object_id)]
  end

  defp encode_filter(%Messages.Subscribe{
         filter_type: :absolute_range,
         start_location: {group_id, object_id},
         end_group: end_group
       }) do
    [
      encode_varint(4),
      encode_varint(group_id),
      encode_varint(object_id),
      encode_varint(end_group)
    ]
  end

  defp decode_filter(1, rest), do: {:ok, :next_group_start, nil, nil, rest}
  defp decode_filter(2, rest), do: {:ok, :largest_object, nil, nil, rest}

  defp decode_filter(3, rest) do
    with {:ok, group_id, rest} <- decode_varint(rest),
         {:ok, object_id, rest} <- decode_varint(rest) do
      {:ok, :absolute_start, {group_id, object_id}, nil, rest}
    end
  end

  defp decode_filter(4, rest) do
    with {:ok, group_id, rest} <- decode_varint(rest),
         {:ok, object_id, rest} <- decode_varint(rest),
         {:ok, end_group, rest} when end_group >= group_id <- decode_varint(rest) do
      {:ok, :absolute_range, {group_id, object_id}, end_group, rest}
    else
      _other -> {:error, :invalid_range}
    end
  end

  defp decode_filter(_filter, _rest), do: {:error, :unsupported_filter}

  defp decode_location(0, rest), do: {:ok, nil, rest}

  defp decode_location(1, rest) do
    with {:ok, group_id, rest} <- decode_varint(rest),
         {:ok, object_id, rest} <- decode_varint(rest) do
      {:ok, {group_id, object_id}, rest}
    end
  end

  defp decode_location(_other, _rest), do: {:error, :invalid_boolean}

  defp decode_optional_subgroup(type, rest) when type in [0x14, 0x15, 0x1C, 0x1D],
    do: decode_varint(rest)

  defp decode_optional_subgroup(_type, rest), do: {:ok, 0, rest}

  defp skip_extension_headers(type, binary)
       when type in [0x11, 0x13, 0x15, 0x19, 0x1B, 0x1D] do
    with {:ok, length, rest} <- decode_varint(binary),
         true <- byte_size(rest) >= length do
      <<_headers::binary-size(^length), rest::binary>> = rest
      {:ok, rest}
    else
      _other -> :more
    end
  end

  defp skip_extension_headers(_type, rest), do: {:ok, rest}

  defp decode_object_payload(0, binary) do
    with {:ok, status, rest} <- decode_varint(binary),
         {:ok, status} <- decode_object_status(status) do
      {:ok, status, <<>>, rest}
    end
  end

  defp decode_object_payload(length, binary) do
    if byte_size(binary) < length do
      :more
    else
      <<payload::binary-size(^length), rest::binary>> = binary
      {:ok, nil, payload, rest}
    end
  end

  defp decode_object_status(0), do: {:ok, nil}
  defp decode_object_status(1), do: {:ok, :object_does_not_exist}
  defp decode_object_status(3), do: {:ok, :end_of_group}
  defp decode_object_status(4), do: {:ok, :end_of_track}
  defp decode_object_status(status), do: {:error, {:invalid_object_status, status}}

  defp encode_object_status(:object_does_not_exist), do: 1
  defp encode_object_status(:end_of_group), do: 3
  defp encode_object_status(:end_of_track), do: 4

  defp decode_namespace(binary) do
    with {:ok, count, rest} <- decode_varint(binary) do
      decode_namespace(count, rest, [])
    end
  end

  defp decode_namespace(0, rest, components), do: {:ok, Enum.reverse(components), rest}

  defp decode_namespace(count, binary, components) do
    with {:ok, component, rest} <- decode_bytes(binary) do
      decode_namespace(count - 1, rest, [component | components])
    end
  end

  defp decode_bytes(binary) do
    with {:ok, length, rest} <- decode_varint(binary),
         true <- byte_size(rest) >= length do
      <<value::binary-size(^length), trailing::binary>> = rest
      {:ok, value, trailing}
    else
      _other -> :more
    end
  end

  defp decode_params(binary) do
    with {:ok, count, rest} <- decode_varint(binary) do
      decode_params(count, rest, [])
    end
  end

  defp decode_params(0, rest, params), do: {:ok, Enum.reverse(params), rest}

  defp decode_params(count, binary, params) do
    with {:ok, key, rest} <- decode_varint(binary),
         {:ok, value, rest} <- skip_param_value(key, rest) do
      decode_params(count - 1, rest, [{key, value} | params])
    end
  end

  defp skip_params(binary) do
    with {:ok, count, rest} <- decode_varint(binary) do
      skip_params(count, rest)
    end
  end

  defp skip_params(0, rest), do: {:ok, %{}, rest}

  defp skip_params(count, binary) do
    with {:ok, key, rest} <- decode_varint(binary),
         {:ok, _value, rest} <- skip_param_value(key, rest) do
      skip_params(count - 1, rest)
    end
  end

  defp skip_param_value(key, binary) when rem(key, 2) == 0, do: decode_varint(binary)

  defp skip_param_value(_key, binary) do
    with {:ok, length, rest} <- decode_varint(binary),
         true <- byte_size(rest) >= length do
      <<value::binary-size(^length), rest::binary>> = rest
      {:ok, value, rest}
    else
      _other -> :more
    end
  end
end
