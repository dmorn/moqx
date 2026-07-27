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
    filter =
      case Keyword.get(options, :start, :next_object) do
        :next_group -> 1
        :next_object -> 2
      end

    priority = Keyword.get(options, :priority, 128)

    frame(0x03, [
      encode_varint(request_id),
      encode_tuple(track.namespace),
      encode_bytes(track.track),
      encode_varint(2),
      encode_integer_parameter(0x20, priority),
      encode_bytes_parameter(1, encode_varint(filter))
    ])
  end

  @spec unsubscribe(non_neg_integer()) :: binary()
  def unsubscribe(request_id), do: frame(0x0A, encode_varint(request_id))

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

  @spec decode_server_setup(binary()) :: :ok | {:error, :invalid_server_setup}
  def decode_server_setup(payload) do
    case decode_varint(payload) do
      {:ok, _parameter_count, _parameters} -> :ok
      _other -> {:error, :invalid_server_setup}
    end
  end

  @spec decode_subscribe_ok(binary()) ::
          {:ok, %{request_id: non_neg_integer(), track_alias: non_neg_integer()}}
          | {:error, :invalid_subscribe_ok}
  def decode_subscribe_ok(payload) do
    with {:ok, request_id, rest} <- decode_varint(payload),
         {:ok, track_alias, rest} <- decode_varint(rest),
         {:ok, _parameter_count, _rest} <- decode_varint(rest) do
      {:ok, %{request_id: request_id, track_alias: track_alias}}
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

  defp decode_bytes(binary) do
    with {:ok, length, rest} <- decode_varint(binary),
         true <- byte_size(rest) >= length do
      <<value::binary-size(^length), rest::binary>> = rest
      {:ok, value, rest}
    else
      _other -> :more
    end
  end
end
