defmodule MOQX.Protocol.MOQTDraft14.Codec do
  @moduledoc "Wire primitives and message codecs shared by draft-14 implementations."

  import Bitwise

  alias MOQX.Protocol.MOQTDraft14.Messages

  @draft_14 0xFF00000E

  @spec client_setup() :: binary()
  def client_setup do
    encode(%Messages.ClientSetup{versions: [@draft_14], params: %{2 => 100}})
  end

  @spec subscribe(non_neg_integer(), MOQX.TrackRef.t(), keyword()) :: binary()
  def subscribe(request_id, %MOQX.TrackRef{} = track, options \\ []) do
    encode(%Messages.Subscribe{
      request_id: request_id,
      track_namespace: track.namespace,
      track_name: track.track,
      subscriber_priority: Keyword.get(options, :priority, 127)
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
      encode_filter(subscribe.filter_type),
      encode_params(subscribe.params)
    ])
  end

  def encode(%Messages.Unsubscribe{request_id: request_id}) do
    frame(0x0A, encode_varint(request_id))
  end

  @spec unsubscribe(non_neg_integer()) :: binary()
  def unsubscribe(request_id), do: encode(%Messages.Unsubscribe{request_id: request_id})

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
    encoded =
      Enum.map(params, fn
        {key, value} when rem(key, 2) == 0 ->
          [encode_varint(key), encode_varint(value)]

        {key, value} when is_binary(value) ->
          [encode_varint(key), encode_varint(byte_size(value)), value]
      end)

    [encode_varint(map_size(params)), encoded]
  end

  defp encode_group_order(:publisher), do: 0
  defp encode_group_order(:ascending), do: 1
  defp encode_group_order(:descending), do: 2

  defp encode_bool(true), do: 1
  defp encode_bool(false), do: 0

  defp encode_filter(:next_group_start), do: encode_varint(1)
  defp encode_filter(:largest_object), do: encode_varint(2)

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
