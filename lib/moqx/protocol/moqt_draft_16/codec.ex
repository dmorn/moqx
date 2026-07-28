defmodule MOQX.Protocol.MOQTDraft16.Codec do
  @moduledoc "Wire primitives for the standard MOQT draft-16 implementation."

  import Bitwise

  @spec client_setup(URI.t()) :: binary()
  def client_setup(%URI{} = endpoint) do
    path =
      case {endpoint.path, endpoint.query} do
        {nil, nil} -> ""
        {path, nil} -> path
        {nil, query} -> "?" <> query
        {path, query} -> path <> "?" <> query
      end

    authority = endpoint.authority || endpoint.host

    frame(0x20, [
      encode_varint(3),
      encode_bytes_parameter(1, path),
      encode_integer_parameter(1, 100),
      encode_bytes_parameter(3, authority)
    ])
  end

  @spec subscribe(non_neg_integer(), MOQX.TrackRef.t(), keyword()) :: binary()
  def subscribe(request_id, %MOQX.TrackRef{} = track, options) do
    parameters = subscription_parameters(options)

    frame(0x03, [
      encode_varint(request_id),
      encode_tuple(track.namespace),
      encode_bytes(track.track),
      encode_varint(length(parameters)),
      encode_parameter_list(parameters)
    ])
  end

  @spec unsubscribe(non_neg_integer()) :: binary()
  def unsubscribe(request_id), do: frame(0x0A, encode_varint(request_id))

  @spec request_update(non_neg_integer(), non_neg_integer(), keyword()) :: binary()
  def request_update(request_id, existing_request_id, options) do
    parameters = update_parameters(options)

    frame(0x02, [
      encode_varint(request_id),
      encode_varint(existing_request_id),
      encode_varint(length(parameters)),
      encode_parameter_list(parameters)
    ])
  end

  @spec publish_namespace(non_neg_integer(), [binary()]) :: binary()
  def publish_namespace(request_id, namespace) do
    frame(0x06, [
      encode_varint(request_id),
      encode_tuple(namespace),
      encode_varint(0)
    ])
  end

  @spec publish_track(
          non_neg_integer(),
          MOQX.TrackRef.t(),
          non_neg_integer(),
          keyword()
        ) :: binary()
  def publish_track(request_id, %MOQX.TrackRef{} = track, track_alias, options \\ []) do
    parameters = [{0x10, :integer, boolean_integer(Keyword.get(options, :forward, true))}]

    frame(0x1D, [
      encode_varint(request_id),
      encode_tuple(track.namespace),
      encode_bytes(track.track),
      encode_varint(track_alias),
      encode_varint(length(parameters)),
      encode_parameter_list(parameters),
      encode_varint(0)
    ])
  end

  @spec decode_publish_ok(binary()) ::
          {:ok, %{request_id: non_neg_integer(), parameters: [SubscriptionParameter.t()]}}
          | {:error, :invalid_publish_ok}
  def decode_publish_ok(payload) do
    with {:ok, request_id, rest} <- decode_varint(payload),
         {:ok, parameter_count, rest} <- decode_varint(rest),
         {:ok, parameters, <<>>} <- decode_parameters(rest, parameter_count, :message) do
      {:ok, %{request_id: request_id, parameters: Enum.map(parameters, &public_parameter/1)}}
    else
      _other -> {:error, :invalid_publish_ok}
    end
  end

  @spec encode_subgroup(non_neg_integer(), MOQX.Object.t()) :: binary()
  def encode_subgroup(track_alias, %MOQX.Object{} = object) do
    subgroup_id = object.subgroup_id || 0
    priority = object.publisher_priority || 127
    type = if object.end_of_group?, do: 0x1C, else: 0x14

    IO.iodata_to_binary([
      encode_varint(type),
      encode_varint(track_alias),
      encode_varint(object.group_id),
      encode_varint(subgroup_id),
      <<priority>>,
      encode_varint(object.object_id),
      encode_object_payload(object)
    ])
  end

  @spec decode_request_ok(binary()) ::
          {:ok, %{request_id: non_neg_integer(), parameters: [SubscriptionParameter.t()]}}
          | {:error, :invalid_request_ok}
  def decode_request_ok(payload) do
    with {:ok, request_id, rest} <- decode_varint(payload),
         {:ok, parameter_count, rest} <- decode_varint(rest),
         {:ok, parameters, <<>>} <- decode_parameters(rest, parameter_count, :message),
         :ok <- validate_subscribe_ok_parameters(parameters) do
      {:ok, %{request_id: request_id, parameters: Enum.map(parameters, &public_parameter/1)}}
    else
      _other -> {:error, :invalid_request_ok}
    end
  end

  @spec decode_max_request_id(binary()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_max_request_id}
  def decode_max_request_id(payload) do
    case decode_varint(payload) do
      {:ok, max_request_id, <<>>} -> {:ok, max_request_id}
      _other -> {:error, :invalid_max_request_id}
    end
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

  alias MOQX.SubscriptionParameter

  @spec decode_server_setup(binary()) ::
          {:ok, %{max_request_id: non_neg_integer(), parameters: [SubscriptionParameter.t()]}}
          | {:error, :invalid_server_setup}
  def decode_server_setup(payload) do
    with {:ok, parameter_count, rest} <- decode_varint(payload),
         {:ok, parameters, <<>>} <- decode_parameters(rest, parameter_count, :setup),
         :ok <- validate_server_setup_parameters(parameters) do
      max_request_id =
        Enum.find_value(parameters, 0, fn
          %{identifier: 0x02, value: value} -> value
          _parameter -> nil
        end)

      public_parameters =
        Enum.flat_map(parameters, fn
          %{identifier: 0x02} -> []
          parameter -> [public_parameter(parameter)]
        end)

      {:ok, %{max_request_id: max_request_id, parameters: public_parameters}}
    else
      _other -> {:error, :invalid_server_setup}
    end
  end

  @spec decode_subscribe_ok(binary()) ::
          {:ok,
           %{
             request_id: non_neg_integer(),
             track_alias: non_neg_integer(),
             parameters: [SubscriptionParameter.t()],
             track_extensions: [MOQX.Extension.t()]
           }}
          | {:error, :invalid_subscribe_ok}
  def decode_subscribe_ok(payload) do
    with {:ok, request_id, rest} <- decode_varint(payload),
         {:ok, track_alias, rest} <- decode_varint(rest),
         {:ok, parameter_count, rest} <- decode_varint(rest),
         {:ok, parameters, rest} <- decode_parameters(rest, parameter_count, :message),
         :ok <- validate_subscribe_ok_parameters(parameters),
         {:ok, track_extensions} <- decode_extension_parameters(rest) do
      {:ok,
       %{
         request_id: request_id,
         track_alias: track_alias,
         parameters: Enum.map(parameters, &public_parameter/1),
         track_extensions: Enum.map(track_extensions, &public_wire_extension/1)
       }}
    else
      _other -> {:error, :invalid_subscribe_ok}
    end
  end

  @spec decode_request_error(binary()) ::
          {:ok, %{request_id: non_neg_integer(), error_code: non_neg_integer(), reason: binary()}}
          | {:error, :invalid_request_error}
  def decode_request_error(payload) do
    with {:ok, request_id, rest} <- decode_varint(payload),
         {:ok, error_code, rest} <- decode_varint(rest),
         {:ok, _retry_interval, rest} <- decode_varint(rest),
         {:ok, reason, <<>>} <- decode_bytes(rest) do
      {:ok, %{request_id: request_id, error_code: error_code, reason: reason}}
    else
      _other -> {:error, :invalid_request_error}
    end
  end

  @spec decode_publish_done(binary()) ::
          {:ok,
           %{
             request_id: non_neg_integer(),
             status_code: non_neg_integer(),
             stream_count: non_neg_integer(),
             reason: binary()
           }}
          | {:error, :invalid_publish_done}
  def decode_publish_done(payload) do
    with {:ok, request_id, rest} <- decode_varint(payload),
         {:ok, status_code, rest} <- decode_varint(rest),
         {:ok, stream_count, rest} <- decode_varint(rest),
         {:ok, reason, <<>>} <- decode_bytes(rest) do
      {:ok,
       %{
         request_id: request_id,
         status_code: status_code,
         stream_count: stream_count,
         reason: reason
       }}
    else
      _other -> {:error, :invalid_publish_done}
    end
  end

  @spec decode_datagram(binary()) :: {:ok, map()} | {:error, :invalid_datagram}
  def decode_datagram(payload) do
    with {:ok, type, rest} <- decode_varint(payload),
         :ok <- validate_datagram_type(type),
         {:ok, track_alias, rest} <- decode_varint(rest),
         {:ok, group_id, rest} <- decode_varint(rest),
         {:ok, object_id, rest} <- decode_optional_varint(rest, (type &&& 0x04) != 0, 0),
         {:ok, priority, rest} <- decode_optional_priority(rest, (type &&& 0x08) != 0),
         {:ok, extensions, rest} <- decode_datagram_extensions(rest, (type &&& 0x01) != 0),
         {:ok, status, object_payload} <- decode_datagram_payload(rest, (type &&& 0x20) != 0) do
      {:ok,
       %{
         track_alias: track_alias,
         group_id: group_id,
         subgroup_id: nil,
         object_id: object_id,
         priority: priority,
         status: status,
         extensions: extensions,
         end_of_group?: (type &&& 0x02) != 0,
         payload: object_payload
       }}
    else
      _other -> {:error, :invalid_datagram}
    end
  end

  @doc false
  @spec decode_extensions(binary()) ::
          {:ok, [MOQX.Extension.t()]} | {:error, term()}
  def decode_extensions(binary) do
    case decode_extension_parameters(binary) do
      {:ok, extensions} -> {:ok, Enum.map(extensions, &public_wire_extension/1)}
      error -> error
    end
  end

  @spec decode_varint(binary()) ::
          {:ok, non_neg_integer(), binary()} | :more | {:error, :invalid_varint}
  def decode_varint(<<prefix::2, _::6, _::binary>> = binary) do
    length = 1 <<< prefix

    if byte_size(binary) < length do
      :more
    else
      <<encoded::binary-size(^length), rest::binary>> = binary
      value_bits = length * 8 - 2
      <<_prefix::2, value::unsigned-big-integer-size(^value_bits)>> = encoded
      {:ok, value, rest}
    end
  end

  def decode_varint(<<>>), do: :more

  @spec encode_varint(non_neg_integer()) :: binary()
  def encode_varint(value) when value < 64, do: <<value>>
  def encode_varint(value) when value < 16_384, do: <<1::2, value::14>>
  def encode_varint(value) when value < 1_073_741_824, do: <<2::2, value::30>>
  def encode_varint(value) when value < 4_611_686_018_427_387_904, do: <<3::2, value::62>>

  defp boolean_integer(true), do: 1
  defp boolean_integer(false), do: 0

  defp encode_object_payload(%MOQX.Object{payload: payload}) when byte_size(payload) > 0,
    do: [encode_varint(byte_size(payload)), payload]

  defp encode_object_payload(%MOQX.Object{status: status}) do
    [encode_varint(0), encode_varint(object_status(status))]
  end

  defp object_status(nil), do: 0
  defp object_status(:object_does_not_exist), do: 1
  defp object_status(:end_of_group), do: 3
  defp object_status(:end_of_track), do: 4

  defp frame(type, payload) do
    payload = IO.iodata_to_binary(payload)
    IO.iodata_to_binary([encode_varint(type), <<byte_size(payload)::16>>, payload])
  end

  defp encode_tuple(fields) do
    [encode_varint(length(fields)) | Enum.map(fields, &encode_bytes/1)]
  end

  defp encode_bytes(value), do: [encode_varint(byte_size(value)), value]

  defp encode_integer_parameter(delta_type, value),
    do: [encode_varint(delta_type), encode_varint(value)]

  defp encode_bytes_parameter(delta_type, value),
    do: [encode_varint(delta_type), encode_bytes(value)]

  defp subscription_parameters(options) do
    filter =
      Keyword.get_lazy(options, :filter, fn ->
        case Keyword.get(options, :start, :next_object) do
          :next_group -> %MOQX.SubscriptionFilter{type: :next_group_start}
          :next_object -> %MOQX.SubscriptionFilter{type: :largest_object}
        end
      end)

    [
      {0x02, :integer, Keyword.get(options, :delivery_timeout)},
      {0x20, :integer, Keyword.get(options, :priority, 128)},
      {0x21, :bytes, encode_filter(filter)},
      {0x22, :integer, encode_group_order(Keyword.get(options, :group_order))}
    ]
    |> Enum.reject(fn {_identifier, _kind, value} -> is_nil(value) end)
    |> Kernel.++(extension_parameters(Keyword.get(options, :parameters, [])))
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp update_parameters(options) do
    filter =
      cond do
        Keyword.has_key?(options, :filter) ->
          Keyword.fetch!(options, :filter)

        Keyword.get(options, :start) == :next_group ->
          %MOQX.SubscriptionFilter{type: :next_group_start}

        Keyword.get(options, :start) == :next_object ->
          %MOQX.SubscriptionFilter{type: :largest_object}

        true ->
          nil
      end

    [
      {0x02, :integer, Keyword.get(options, :delivery_timeout)},
      {0x10, :integer, encode_boolean(Keyword.get(options, :forward))},
      {0x20, :integer, Keyword.get(options, :priority)},
      {0x21, :bytes, if(filter, do: encode_filter(filter))},
      {0x32, :integer, Keyword.get(options, :new_group)}
    ]
    |> Enum.reject(fn {_identifier, _kind, value} -> is_nil(value) end)
    |> Kernel.++(extension_parameters(Keyword.get(options, :parameters, [])))
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp extension_parameters(parameters) do
    Enum.map(parameters, fn
      %SubscriptionParameter.Authorization{value: value} ->
        {0x03, :bytes, value}

      %SubscriptionParameter.DeliveryTimeout{milliseconds: value} ->
        {0x02, :integer, value}

      %SubscriptionParameter.Extension{identifier: identifier, value: value}
      when is_integer(value) ->
        {identifier, :integer, value}

      %SubscriptionParameter.Extension{identifier: identifier, value: value}
      when is_binary(value) ->
        {identifier, :bytes, value}
    end)
  end

  defp encode_parameter_list(parameters) do
    {_identifier, encoded} =
      Enum.reduce(parameters, {0, []}, fn {identifier, kind, value}, {previous, encoded} ->
        parameter =
          case kind do
            :integer -> encode_integer_parameter(identifier - previous, value)
            :bytes -> encode_bytes_parameter(identifier - previous, value)
          end

        {identifier, [encoded, parameter]}
      end)

    encoded
  end

  defp encode_filter(%MOQX.SubscriptionFilter{type: :next_group_start}), do: encode_varint(1)
  defp encode_filter(%MOQX.SubscriptionFilter{type: :largest_object}), do: encode_varint(2)

  defp encode_filter(%MOQX.SubscriptionFilter{
         type: :absolute_start,
         start_location: {group, object}
       }),
       do: IO.iodata_to_binary([encode_varint(3), encode_varint(group), encode_varint(object)])

  defp encode_filter(%MOQX.SubscriptionFilter{
         type: :absolute_range,
         start_location: {group, object},
         end_group: end_group
       }),
       do:
         IO.iodata_to_binary([
           encode_varint(4),
           encode_varint(group),
           encode_varint(object),
           encode_varint(end_group)
         ])

  defp encode_group_order(nil), do: nil
  defp encode_group_order(:ascending), do: 1
  defp encode_group_order(:descending), do: 2

  defp encode_boolean(nil), do: nil
  defp encode_boolean(false), do: 0
  defp encode_boolean(true), do: 1

  defp decode_bytes(binary) do
    with {:ok, length, rest} <- decode_varint(binary),
         true <- byte_size(rest) >= length do
      <<value::binary-size(^length), rest::binary>> = rest
      {:ok, value, rest}
    else
      _other -> :more
    end
  end

  defp decode_parameters(binary, count, kind),
    do: decode_parameters(binary, count, kind, 0, [], MapSet.new())

  defp decode_parameters(rest, 0, _kind, _identifier, parameters, _seen),
    do: {:ok, Enum.reverse(parameters), rest}

  defp decode_parameters(binary, count, kind, previous_identifier, parameters, seen) do
    with {:ok, delta, rest} <- decode_varint(binary),
         identifier = previous_identifier + delta,
         false <- MapSet.member?(seen, identifier),
         {:ok, value, rest} <- decode_parameter_value(identifier, rest) do
      parameter = %{kind: kind, identifier: identifier, value: value}

      decode_parameters(
        rest,
        count - 1,
        kind,
        identifier,
        [parameter | parameters],
        MapSet.put(seen, identifier)
      )
    else
      _other -> {:error, :invalid_parameters}
    end
  end

  defp decode_extension_parameters(binary),
    do: decode_extension_parameters(binary, 0, [], MapSet.new())

  defp decode_extension_parameters(<<>>, _identifier, parameters, _seen),
    do: {:ok, Enum.reverse(parameters)}

  defp decode_extension_parameters(binary, previous_identifier, parameters, seen) do
    with {:ok, delta, rest} <- decode_varint(binary),
         identifier = previous_identifier + delta,
         false <- MapSet.member?(seen, identifier),
         {:ok, value, rest} <- decode_parameter_value(identifier, rest) do
      decode_extension_parameters(
        rest,
        identifier,
        [%{identifier: identifier, value: value} | parameters],
        MapSet.put(seen, identifier)
      )
    else
      _other -> {:error, :invalid_extensions}
    end
  end

  defp decode_parameter_value(identifier, rest) when rem(identifier, 2) == 0,
    do: decode_varint(rest)

  defp decode_parameter_value(_identifier, rest), do: decode_bytes(rest)

  defp validate_server_setup_parameters(parameters) do
    if Enum.any?(parameters, &(&1.identifier in [0x01, 0x03, 0x05])) do
      {:error, :invalid_server_setup_parameter}
    else
      :ok
    end
  end

  defp public_parameter(%{kind: :message, identifier: 0x02, value: value}),
    do: %SubscriptionParameter.DeliveryTimeout{milliseconds: value}

  defp public_parameter(%{kind: :message, identifier: 0x03, value: value}),
    do: %SubscriptionParameter.Authorization{value: value}

  defp public_parameter(%{kind: :message, identifier: 0x08, value: value}),
    do: %SubscriptionParameter.Expires{milliseconds: value}

  defp public_parameter(%{kind: :message, identifier: 0x09, value: value}) do
    {:ok, group, rest} = decode_varint(value)
    {:ok, object, <<>>} = decode_varint(rest)
    %SubscriptionParameter.LargestObject{location: {group, object}}
  end

  defp public_parameter(%{kind: :message, identifier: 0x22, value: 1}),
    do: %SubscriptionParameter.GroupOrder{value: :ascending}

  defp public_parameter(%{kind: :message, identifier: 0x22, value: 2}),
    do: %SubscriptionParameter.GroupOrder{value: :descending}

  defp public_parameter(parameter), do: public_extension(parameter)

  defp public_extension(%{identifier: identifier, value: value}) do
    %SubscriptionParameter.Extension{
      protocol: :draft_16,
      identifier: identifier,
      value: value
    }
  end

  defp public_wire_extension(%{identifier: identifier, value: value}) do
    %MOQX.Extension{protocol: :draft_16, identifier: identifier, value: value}
  end

  defp validate_datagram_type(type)
       when type <= 0xFF and (type &&& 0xD0) == 0 and (type &&& 0x22) != 0x22,
       do: :ok

  defp validate_datagram_type(_type), do: {:error, :invalid_datagram_type}

  defp validate_subscribe_ok_parameters(parameters) do
    if Enum.all?(parameters, fn
         %{identifier: 0x08, value: value} -> is_integer(value)
         %{identifier: 0x09, value: value} -> valid_location?(value)
         %{identifier: 0x22, value: value} -> value in [1, 2]
         _parameter -> true
       end) do
      :ok
    else
      {:error, :invalid_subscribe_ok_parameter}
    end
  end

  defp valid_location?(value) do
    with {:ok, _group, rest} <- decode_varint(value),
         {:ok, _object, <<>>} <- decode_varint(rest) do
      true
    else
      _other -> false
    end
  end

  defp decode_optional_varint(rest, true, default), do: {:ok, default, rest}
  defp decode_optional_varint(rest, false, _default), do: decode_varint(rest)

  defp decode_optional_priority(rest, true), do: {:ok, nil, rest}
  defp decode_optional_priority(<<priority, rest::binary>>, false), do: {:ok, priority, rest}
  defp decode_optional_priority(<<>>, false), do: :more

  defp decode_datagram_extensions(rest, false), do: {:ok, [], rest}

  defp decode_datagram_extensions(rest, true) do
    with {:ok, length, rest} when length > 0 <- decode_varint(rest),
         true <- byte_size(rest) >= length do
      <<encoded::binary-size(^length), rest::binary>> = rest

      case decode_extension_parameters(encoded) do
        {:ok, extensions} -> {:ok, Enum.map(extensions, &public_wire_extension/1), rest}
        error -> error
      end
    else
      _other -> {:error, :invalid_extensions}
    end
  end

  defp decode_datagram_payload(rest, false), do: {:ok, nil, rest}

  defp decode_datagram_payload(rest, true) do
    with {:ok, status, <<>>} <- decode_varint(rest),
         {:ok, status} <- decode_object_status(status) do
      {:ok, status, ""}
    else
      _other -> {:error, :invalid_object_status}
    end
  end

  defp decode_object_status(0), do: {:ok, nil}
  defp decode_object_status(3), do: {:ok, :end_of_group}
  defp decode_object_status(4), do: {:ok, :end_of_track}
  defp decode_object_status(_status), do: {:error, :invalid_object_status}
end
