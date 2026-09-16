defmodule MOQX.Protocol.MOQTDraft18.Codec do
  @moduledoc "Wire primitives for the standard MOQT draft-18 implementation."

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

    # SETUP options span the payload; unlike draft-16 there is no count and
    # PATH (0x01) and AUTHORITY (0x05) are ordinary delta-coded byte KVPs.
    frame(0x2F00, [encode_bytes_parameter(1, path), encode_bytes_parameter(4, authority)])
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

  @spec decode_subscribe(binary()) :: {:ok, map()} | {:error, :invalid_subscribe}
  def decode_subscribe(payload) do
    with {:ok, request_id, rest} <- decode_varint(payload),
         {:ok, namespace, rest} <- decode_tuple(rest),
         {:ok, track_name, rest} <- decode_bytes(rest),
         :ok <- validate_full_track_name(namespace, track_name),
         {:ok, parameter_count, rest} <- decode_varint(rest),
         {:ok, parameters, <<>>} <- decode_parameters(rest, parameter_count, :message),
         {:ok, filter} <- subscribe_filter(parameters),
         {:ok, forward} <- boolean_parameter(parameters, 0x10, true),
         {:ok, priority} <- priority_parameter(parameters),
         {:ok, group_order} <- group_order_parameter(parameters) do
      {:ok,
       %{
         request_id: request_id,
         track_namespace: namespace,
         track_name: track_name,
         subscriber_priority: priority,
         group_order: group_order,
         forward: forward,
         filter: filter,
         parameters: public_subscribe_parameters(parameters)
       }}
    else
      _other -> {:error, :invalid_subscribe}
    end
  end

  @spec subscribe_ok(non_neg_integer(), keyword()) :: binary()
  def subscribe_ok(track_alias, options \\ []) do
    parameters =
      [
        {0x08, :integer, Keyword.get(options, :expires)},
        {0x09, :location, Keyword.get(options, :largest_location)},
        {0x22, :integer, encode_group_order(Keyword.get(options, :group_order))}
      ]
      |> Enum.reject(fn {_identifier, _kind, value} -> is_nil(value) end)
      |> Enum.sort_by(&elem(&1, 0))

    frame(0x04, [
      encode_varint(track_alias),
      encode_varint(length(parameters)),
      encode_parameter_list(parameters),
      encode_property_list(Keyword.get(options, :track_extensions, []))
    ])
  end

  @spec request_update(non_neg_integer(), keyword()) :: binary()
  def request_update(request_id, options) do
    parameters = update_parameters(options)

    frame(0x02, [
      encode_varint(request_id),
      encode_varint(length(parameters)),
      encode_parameter_list(parameters)
    ])
  end

  @spec decode_request_update(binary()) :: {:ok, map()} | {:error, :invalid_request_update}
  def decode_request_update(payload) do
    with {:ok, request_id, rest} <- decode_varint(payload),
         {:ok, parameter_count, rest} <- decode_varint(rest),
         {:ok, parameters, <<>>} <- decode_parameters(rest, parameter_count, :message),
         {:ok, forward} <- optional_boolean_parameter(parameters, 0x10),
         {:ok, priority} <- optional_priority_parameter(parameters),
         {:ok, filter} <- optional_filter_parameter(parameters) do
      {:ok,
       %{
         request_id: request_id,
         forward: forward,
         subscriber_priority: priority,
         filter: filter,
         new_group: parameter_value(parameters, 0x32),
         parameters:
           parameters
           |> Enum.reject(&(&1.identifier in [0x10, 0x20, 0x21, 0x32]))
           |> Enum.map(&public_parameter/1)
       }}
    else
      _other -> {:error, :invalid_request_update}
    end
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
      encode_parameter_list(parameters)
    ])
  end

  @spec publish_done(non_neg_integer(), non_neg_integer(), binary()) :: binary()
  def publish_done(status, stream_count, reason) do
    frame(0x0B, [
      encode_varint(status),
      encode_varint(stream_count),
      encode_bytes(reason)
    ])
  end

  @doc "Encodes a draft-18 request-stream error (correlation is the stream)."
  @spec request_error(non_neg_integer(), binary()) :: binary()
  def request_error(error_code, reason) do
    frame(0x05, [encode_varint(error_code), encode_varint(0), encode_bytes(reason)])
  end

  @doc "Encodes a generic successful response on the owning request stream."
  @spec request_ok(keyword()) :: binary()
  def request_ok(options \\ []) do
    parameters = Keyword.get(options, :parameters, [])

    frame(0x07, [
      encode_varint(length(parameters)),
      encode_parameter_list(parameters),
      encode_property_list(Keyword.get(options, :track_extensions, []))
    ])
  end

  @spec encode_subgroup(non_neg_integer(), MOQX.Object.t()) :: binary()
  def encode_subgroup(track_alias, %MOQX.Object{timestamp: _timestamp} = object) do
    subgroup_id = object.subgroup_id || 0
    priority = object.publisher_priority || 128

    first_object? =
      object.first_object? == true or (is_nil(object.first_object?) and object.object_id == 0)

    type =
      0x15 ||| if(object.end_of_group?, do: 0x08, else: 0) |||
        if(first_object?, do: 0x40, else: 0)

    IO.iodata_to_binary([
      encode_varint(type),
      encode_varint(track_alias),
      encode_varint(object.group_id),
      encode_varint(subgroup_id),
      <<priority>>,
      encode_subgroup_object_fields(object.object_id, object)
    ])
  end

  @doc false
  @spec encode_subgroup_object(non_neg_integer(), MOQX.Object.t()) ::
          {:ok, binary()} | {:error, :invalid_subgroup_object_order}
  def encode_subgroup_object(previous_object_id, %MOQX.Object{} = object)
      when object.object_id > previous_object_id do
    object_fields =
      encode_subgroup_object_fields(object.object_id - previous_object_id - 1, object)

    end_of_group =
      if object.end_of_group? and object.status not in [:end_of_group, :end_of_track] do
        encode_subgroup_status_fields(0, :end_of_group)
      else
        []
      end

    {:ok, IO.iodata_to_binary([object_fields, end_of_group])}
  end

  def encode_subgroup_object(_previous_object_id, _object),
    do: {:error, :invalid_subgroup_object_order}

  @spec encode_datagram(non_neg_integer(), MOQX.Object.t()) :: binary()
  def encode_datagram(track_alias, %MOQX.Object{timestamp: _timestamp} = object) do
    extensions = encode_object_extensions(object.extensions || [])

    type =
      0x00
      |> set_datagram_bit(0x01, extensions != "")
      |> set_datagram_bit(0x02, object.end_of_group? == true)
      |> set_datagram_bit(0x04, object.object_id == 0)
      |> set_datagram_bit(0x08, is_nil(object.publisher_priority))
      |> set_datagram_bit(0x20, not is_nil(object.status))

    IO.iodata_to_binary([
      encode_varint(type),
      encode_varint(track_alias),
      encode_varint(object.group_id),
      if(object.object_id == 0, do: [], else: encode_varint(object.object_id)),
      if(is_nil(object.publisher_priority), do: [], else: <<object.publisher_priority>>),
      if(extensions == "", do: [], else: [encode_varint(byte_size(extensions)), extensions]),
      if(is_nil(object.status),
        do: object.payload,
        else: encode_varint(object_status(object.status))
      )
    ])
  end

  @spec decode_request_ok(binary()) ::
          {:ok,
           %{parameters: [SubscriptionParameter.t()], track_extensions: [MOQX.Extension.t()]}}
          | {:error, :invalid_request_ok}
  def decode_request_ok(payload) do
    with {:ok, parameter_count, rest} <- decode_varint(payload),
         {:ok, parameters, rest} <- decode_parameters(rest, parameter_count, :message),
         {:ok, properties} <- decode_extension_parameters(rest) do
      {:ok,
       %{
         parameters: Enum.map(parameters, &public_parameter/1),
         track_extensions: Enum.map(properties, &public_wire_extension/1)
       }}
    else
      _other -> {:error, :invalid_request_ok}
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
          {:ok, %{parameters: [SubscriptionParameter.t()]}} | {:error, :invalid_server_setup}
  def decode_server_setup(payload) do
    case decode_setup_options(payload, 0) do
      :ok -> {:ok, %{parameters: []}}
      :error -> {:error, :invalid_server_setup}
    end
  end

  defp decode_setup_options(<<>>, _previous), do: :ok

  defp decode_setup_options(binary, previous) do
    with {:ok, delta, rest} <- decode_varint(binary),
         identifier when identifier <= 0xFFFFFFFFFFFFFFFF and identifier not in [0x01, 0x05] <-
           previous + delta,
         {:ok, _value, rest} <- decode_kvp_value(identifier, rest) do
      decode_setup_options(rest, identifier)
    else
      _other -> :error
    end
  end

  @spec decode_subscribe_ok(binary()) ::
          {:ok,
           %{
             track_alias: non_neg_integer(),
             parameters: [SubscriptionParameter.t()],
             track_extensions: [MOQX.Extension.t()]
           }}
          | {:error, :invalid_subscribe_ok}
  def decode_subscribe_ok(payload) do
    with {:ok, track_alias, rest} <- decode_varint(payload),
         {:ok, parameter_count, rest} <- decode_varint(rest),
         {:ok, parameters, rest} <- decode_parameters(rest, parameter_count, :message),
         :ok <- validate_subscribe_ok_parameters(parameters),
         {:ok, track_extensions} <- decode_extension_parameters(rest) do
      {:ok,
       %{
         track_alias: track_alias,
         parameters: Enum.map(parameters, &public_parameter/1),
         track_extensions: Enum.map(track_extensions, &public_wire_extension/1)
       }}
    else
      _other -> {:error, :invalid_subscribe_ok}
    end
  end

  @spec decode_request_error(binary()) ::
          {:ok,
           %{error_code: non_neg_integer(), retry_interval: non_neg_integer(), reason: binary()}}
          | {:error, :invalid_request_error}
  def decode_request_error(payload) do
    with {:ok, error_code, rest} <- decode_varint(payload),
         {:ok, retry_interval, rest} <- decode_varint(rest),
         {:ok, reason, <<>>} when byte_size(reason) <= 1_024 <- decode_bytes(rest) do
      {:ok, %{error_code: error_code, retry_interval: retry_interval, reason: reason}}
    else
      _other -> {:error, :invalid_request_error}
    end
  end

  @spec decode_publish_done(binary()) ::
          {:ok,
           %{
             status_code: non_neg_integer(),
             stream_count: non_neg_integer(),
             reason: binary()
           }}
          | {:error, :invalid_publish_done}
  def decode_publish_done(payload) do
    with {:ok, status_code, rest} <- decode_varint(payload),
         {:ok, stream_count, rest} <- decode_varint(rest),
         {:ok, reason, <<>>} when byte_size(reason) <= 1_024 <- decode_bytes(rest) do
      {:ok,
       %{
         status_code: status_code,
         stream_count: stream_count,
         reason: reason
       }}
    else
      _other -> {:error, :invalid_publish_done}
    end
  end

  @spec decode_datagram(binary()) :: {:ok, map() | :padding} | {:error, :invalid_datagram}
  def decode_datagram(payload) do
    case decode_varint(payload) do
      {:ok, 0x132B3E29, padding} ->
        if zero_bytes?(padding), do: {:ok, :padding}, else: {:error, :invalid_datagram}

      {:ok, type, rest} ->
        decode_object_datagram(type, rest)

      _other ->
        {:error, :invalid_datagram}
    end
  end

  @doc false
  @spec zero_bytes?(binary()) :: boolean()
  def zero_bytes?(<<>>), do: true
  def zero_bytes?(<<0, rest::binary>>), do: zero_bytes?(rest)
  def zero_bytes?(_data), do: false

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
  def decode_varint(<<first, _::binary>> = binary) do
    leading_ones = leading_ones(first, 0)
    length = if leading_ones == 8, do: 9, else: leading_ones + 1

    if byte_size(binary) < length do
      :more
    else
      <<encoded::binary-size(^length), rest::binary>> = binary

      value =
        if length == 9 do
          <<0xFF, value::unsigned-big-64>> = encoded
          value
        else
          value_bits = length * 8 - length
          <<_prefix::size(^length), value::unsigned-big-integer-size(^value_bits)>> = encoded
          value
        end

      {:ok, value, rest}
    end
  end

  def decode_varint(<<>>), do: :more

  @spec encode_varint(non_neg_integer()) :: binary()
  def encode_varint(value) when value in 0..0x7F, do: <<value>>
  def encode_varint(value) when value <= 0x3FFF, do: <<0b10::2, value::14>>
  def encode_varint(value) when value <= 0x1FFFFF, do: <<0b110::3, value::21>>
  def encode_varint(value) when value <= 0xFFFFFFF, do: <<0b1110::4, value::28>>
  def encode_varint(value) when value <= 0x7FFFFFFFF, do: <<0b11110::5, value::35>>
  def encode_varint(value) when value <= 0x3FFFFFFFFFF, do: <<0b111110::6, value::42>>
  def encode_varint(value) when value <= 0x1FFFFFFFFFFFF, do: <<0b1111110::7, value::49>>
  def encode_varint(value) when value <= 0xFFFFFFFFFFFFFF, do: <<0xFE, value::56>>
  def encode_varint(value) when value <= 0xFFFFFFFFFFFFFFFF, do: <<0xFF, value::64>>

  defp leading_ones(byte, count) when count < 8 do
    if (byte &&& 0x80 >>> count) == 0, do: count, else: leading_ones(byte, count + 1)
  end

  defp leading_ones(_byte, 8), do: 8

  defp boolean_integer(true), do: 1
  defp boolean_integer(false), do: 0

  defp encode_subgroup_object_fields(delta, object) do
    extensions = encode_object_extensions(object.extensions || [])

    [
      encode_varint(delta),
      encode_varint(byte_size(extensions)),
      extensions,
      encode_object_payload(object)
    ]
  end

  defp encode_subgroup_status_fields(delta, status) do
    [
      encode_varint(delta),
      encode_varint(0),
      encode_varint(0),
      encode_varint(object_status(status))
    ]
  end

  defp encode_object_payload(%MOQX.Object{payload: payload}) when byte_size(payload) > 0,
    do: [encode_varint(byte_size(payload)), payload]

  defp encode_object_payload(%MOQX.Object{status: status}) do
    [encode_varint(0), encode_varint(object_status(status))]
  end

  defp object_status(nil), do: 0
  defp object_status(:end_of_group), do: 3
  defp object_status(:end_of_track), do: 4

  defp decode_object_datagram(type, rest) do
    with :ok <- validate_datagram_type(type),
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

  defp set_datagram_bit(type, bit, true), do: type ||| bit
  defp set_datagram_bit(type, _bit, false), do: type

  defp encode_object_extensions(extensions) do
    extensions
    |> Enum.map(fn
      %MOQX.Extension{protocol: :draft_18, identifier: identifier, value: value}
      when is_integer(value) ->
        {identifier, :integer, value}

      %MOQX.Extension{protocol: :draft_18, identifier: identifier, value: value}
      when is_binary(value) ->
        {identifier, :bytes, value}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> encode_parameter_list()
    |> IO.iodata_to_binary()
  end

  defp frame(type, payload) do
    payload = IO.iodata_to_binary(payload)
    IO.iodata_to_binary([encode_varint(type), <<byte_size(payload)::16>>, payload])
  end

  defp encode_tuple(fields) do
    [encode_varint(length(fields)) | Enum.map(fields, &encode_bytes/1)]
  end

  defp decode_tuple(binary) do
    with {:ok, count, rest} when count <= 32 <- decode_varint(binary),
         {:ok, fields, rest} <- decode_tuple_fields(rest, count, []),
         true <- Enum.sum(Enum.map(fields, &byte_size/1)) <= 4_096 do
      {:ok, fields, rest}
    else
      _other -> {:error, :invalid_tuple}
    end
  end

  defp decode_tuple_fields(rest, 0, fields), do: {:ok, Enum.reverse(fields), rest}

  defp decode_tuple_fields(binary, count, fields) do
    case decode_bytes(binary) do
      {:ok, field, rest} when byte_size(field) > 0 ->
        decode_tuple_fields(rest, count - 1, [field | fields])

      _other ->
        {:error, :invalid_tuple}
    end
  end

  defp encode_bytes(value), do: [encode_varint(byte_size(value)), value]

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
          [
            encode_varint(identifier - previous),
            encode_message_parameter(identifier, kind, value)
          ]

        {identifier, [encoded, parameter]}
      end)

    encoded
  end

  defp encode_message_parameter(identifier, _kind, value) when identifier in [0x10, 0x20, 0x22],
    do: <<value>>

  defp encode_message_parameter(0x09, :location, {group, object}),
    do: [encode_varint(group), encode_varint(object)]

  defp encode_message_parameter(identifier, _kind, value) when identifier in [0x02, 0x08, 0x32],
    do: encode_varint(value)

  defp encode_message_parameter(identifier, _kind, value) when identifier in [0x03, 0x21],
    do: encode_bytes(value)

  defp encode_message_parameter(identifier, :integer, value),
    do:
      if(rem(identifier, 2) == 0,
        do: encode_varint(value),
        else: encode_bytes(encode_varint(value))
      )

  defp encode_message_parameter(identifier, :bytes, value),
    do:
      if(rem(identifier, 2) == 0,
        do: encode_varint(:binary.decode_unsigned(value)),
        else: encode_bytes(value)
      )

  defp encode_property_list(properties) do
    properties
    |> Enum.map(fn
      %MOQX.Extension{identifier: identifier, value: value} when is_integer(value) ->
        {identifier, :integer, value}

      %MOQX.Extension{identifier: identifier, value: value} when is_binary(value) ->
        {identifier, :bytes, value}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({0, []}, fn {identifier, kind, value}, {previous, encoded} ->
      value = if(kind == :integer, do: encode_varint(value), else: encode_bytes(value))
      {identifier, [encoded, encode_varint(identifier - previous), value]}
    end)
    |> elem(1)
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
           encode_varint(end_group - group)
         ])

  defp encode_group_order(nil), do: nil
  defp encode_group_order(:ascending), do: 1
  defp encode_group_order(:descending), do: 2

  defp encode_boolean(nil), do: nil
  defp encode_boolean(false), do: 0
  defp encode_boolean(true), do: 1

  defp decode_bytes(binary) do
    with {:ok, length, rest} <- decode_varint(binary),
         true <- length <= 65_535,
         true <- byte_size(rest) >= length do
      <<value::binary-size(^length), rest::binary>> = rest
      {:ok, value, rest}
    else
      _other -> :more
    end
  end

  defp validate_full_track_name(namespace, track_name) do
    if Enum.sum(Enum.map(namespace, &byte_size/1)) + byte_size(track_name) <= 4_096,
      do: :ok,
      else: {:error, :full_track_name_too_large}
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

  defp subscribe_filter(parameters) do
    case parameter_value(parameters, 0x21) do
      nil -> {:ok, %MOQX.SubscriptionFilter{type: :largest_object}}
      encoded -> decode_filter(encoded)
    end
  end

  defp decode_filter(encoded) do
    case decode_varint(encoded) do
      {:ok, 1, <<>>} ->
        {:ok, %MOQX.SubscriptionFilter{type: :next_group_start}}

      {:ok, 2, <<>>} ->
        {:ok, %MOQX.SubscriptionFilter{type: :largest_object}}

      {:ok, 3, rest} ->
        with {:ok, group, rest} <- decode_varint(rest),
             {:ok, object, <<>>} <- decode_varint(rest) do
          {:ok, %MOQX.SubscriptionFilter{type: :absolute_start, start_location: {group, object}}}
        end

      {:ok, 4, rest} ->
        with {:ok, group, rest} <- decode_varint(rest),
             {:ok, object, rest} <- decode_varint(rest),
             {:ok, end_group_delta, <<>>} <- decode_varint(rest) do
          {:ok,
           %MOQX.SubscriptionFilter{
             type: :absolute_range,
             start_location: {group, object},
             end_group: group + end_group_delta
           }}
        else
          _other -> {:error, :invalid_filter}
        end

      _other ->
        {:error, :invalid_filter}
    end
  end

  defp boolean_parameter(parameters, identifier, default) do
    case parameter_value(parameters, identifier) do
      nil -> {:ok, default}
      0 -> {:ok, false}
      1 -> {:ok, true}
      _other -> {:error, :invalid_boolean_parameter}
    end
  end

  defp optional_boolean_parameter(parameters, identifier) do
    case parameter_value(parameters, identifier) do
      nil -> {:ok, nil}
      0 -> {:ok, false}
      1 -> {:ok, true}
      _other -> {:error, :invalid_boolean_parameter}
    end
  end

  defp priority_parameter(parameters) do
    case parameter_value(parameters, 0x20) do
      nil -> {:ok, 128}
      priority when priority in 0..255 -> {:ok, priority}
      _other -> {:error, :invalid_priority}
    end
  end

  defp optional_priority_parameter(parameters) do
    case parameter_value(parameters, 0x20) do
      nil -> {:ok, nil}
      priority when priority in 0..255 -> {:ok, priority}
      _other -> {:error, :invalid_priority}
    end
  end

  defp optional_filter_parameter(parameters) do
    case parameter_value(parameters, 0x21) do
      nil -> {:ok, nil}
      encoded -> decode_filter(encoded)
    end
  end

  defp group_order_parameter(parameters) do
    case parameter_value(parameters, 0x22) do
      nil -> {:ok, :publisher}
      1 -> {:ok, :ascending}
      2 -> {:ok, :descending}
      _other -> {:error, :invalid_group_order}
    end
  end

  defp parameter_value(parameters, identifier) do
    Enum.find_value(parameters, fn
      %{identifier: ^identifier, value: value} -> value
      _parameter -> nil
    end)
  end

  defp decode_extension_parameters(binary),
    do: decode_extension_parameters(binary, 0, [], MapSet.new())

  defp decode_extension_parameters(<<>>, _identifier, parameters, _seen),
    do: {:ok, Enum.reverse(parameters)}

  defp decode_extension_parameters(binary, previous_identifier, parameters, seen) do
    with {:ok, delta, rest} <- decode_varint(binary),
         identifier = previous_identifier + delta,
         false <- MapSet.member?(seen, identifier),
         {:ok, value, rest} <- decode_kvp_value(identifier, rest) do
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

  defp decode_parameter_value(identifier, <<value, rest::binary>>)
       when identifier in [0x10, 0x20, 0x22],
       do: {:ok, value, rest}

  defp decode_parameter_value(0x09, rest) do
    with {:ok, group, rest} <- decode_varint(rest),
         {:ok, object, rest} <- decode_varint(rest) do
      {:ok, {group, object}, rest}
    end
  end

  defp decode_parameter_value(identifier, rest)
       when identifier in [0x02, 0x04, 0x06, 0x08, 0x0A, 0x32],
       do: decode_varint(rest)

  defp decode_parameter_value(identifier, rest) when identifier in [0x03, 0x21],
    do: decode_bytes(rest)

  defp decode_parameter_value(0x34, rest), do: decode_tuple(rest)

  defp decode_parameter_value(_identifier, _rest), do: {:error, :unknown_message_parameter}

  defp decode_kvp_value(identifier, rest) when rem(identifier, 2) == 0,
    do: decode_varint(rest)

  defp decode_kvp_value(_identifier, rest), do: decode_bytes(rest)

  defp public_parameter(%{kind: :message, identifier: 0x02, value: value}),
    do: %SubscriptionParameter.DeliveryTimeout{milliseconds: value}

  defp public_parameter(%{kind: :message, identifier: 0x03, value: value}),
    do: %SubscriptionParameter.Authorization{value: value}

  defp public_parameter(%{kind: :message, identifier: 0x08, value: value}),
    do: %SubscriptionParameter.Expires{milliseconds: value}

  defp public_parameter(%{kind: :message, identifier: 0x09, value: value}),
    do: %SubscriptionParameter.LargestObject{location: value}

  defp public_parameter(%{kind: :message, identifier: 0x22, value: 1}),
    do: %SubscriptionParameter.GroupOrder{value: :ascending}

  defp public_parameter(%{kind: :message, identifier: 0x22, value: 2}),
    do: %SubscriptionParameter.GroupOrder{value: :descending}

  defp public_parameter(parameter), do: public_extension(parameter)

  defp public_subscribe_parameters(parameters) do
    parameters
    |> Enum.reject(&(&1.identifier in [0x10, 0x20, 0x21, 0x22]))
    |> Enum.map(&public_parameter/1)
  end

  defp public_extension(%{identifier: identifier, value: value}) do
    %SubscriptionParameter.Extension{
      protocol: :draft_18,
      identifier: identifier,
      value: value
    }
  end

  defp public_wire_extension(%{identifier: identifier, value: value}) do
    %MOQX.Extension{protocol: :draft_18, identifier: identifier, value: value}
  end

  defp validate_datagram_type(type)
       when type in 0x00..0x0F or
              (type in 0x20..0x2F and (type &&& 0x02) == 0),
       do: :ok

  defp validate_datagram_type(_type), do: {:error, :invalid_datagram_type}

  defp validate_subscribe_ok_parameters(parameters) do
    if Enum.all?(parameters, fn
         %{identifier: 0x08, value: value} -> is_integer(value)
         %{identifier: 0x09, value: {group, object}} -> group >= 0 and object >= 0
         %{identifier: 0x22, value: value} -> value in [1, 2]
         _parameter -> true
       end) do
      :ok
    else
      {:error, :invalid_subscribe_ok_parameter}
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
