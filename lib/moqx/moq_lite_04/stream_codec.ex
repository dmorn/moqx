defmodule MOQX.MOQLite04.StreamCodec do
  @moduledoc """
  Pure byte-stream codec for MOQ Lite draft-04 streams.

  The codec is intentionally transport-free. It consumes ordered stream bytes,
  buffers incomplete input, classifies opener-side streams from their
  `STREAM_TYPE` prefix, and emits complete MOQ Lite message structs.
  """

  alias MOQX.Codec
  alias MOQX.Codec.Encoder
  alias MOQX.MOQLite04

  @enforce_keys [:side, :stream_type, :buffer, :message_count]
  defstruct side: :opener, stream_type: nil, buffer: <<>>, message_count: 0

  @type side :: :opener | :responder

  @type t :: %__MODULE__{
          side: side(),
          stream_type: MOQLite04.stream_type() | nil,
          buffer: binary(),
          message_count: non_neg_integer()
        }

  @doc """
  Creates an empty stream codec.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      side: Keyword.get(opts, :side, :opener),
      stream_type: Keyword.get(opts, :stream_type),
      buffer: <<>>,
      message_count: 0
    }
  end

  @doc """
  Encodes stream bytes for a stream type and message sequence.

  Opener-side bytes include the stream type prefix. Responder-side bytes are
  encoded for a stream that has already been classified by the opener prefix.
  """
  @spec encode(MOQLite04.stream_type(), [MOQLite04.message()], keyword()) ::
          {:ok, binary()} | {:error, term()}
  def encode(stream_type, messages, opts \\ []) when is_list(messages) do
    side = Keyword.get(opts, :side, :opener)

    codec = new(side: side, stream_type: stream_type)

    case encode_next(codec, messages) do
      {:ok, _codec, bytes} -> {:ok, bytes}
      {:error, reason, _codec} -> {:error, reason}
    end
  end

  @doc """
  Encodes the next messages for an existing stream codec.

  Opener-side codecs emit the stream type prefix only before the first message.
  The returned codec must be retained by the caller for later sends on the same
  stream.
  """
  @spec encode_next(t(), [MOQLite04.message()]) ::
          {:ok, t(), binary()} | {:error, term(), t()}
  def encode_next(%__MODULE__{stream_type: nil} = codec, _messages),
    do: {:error, :missing_stream_type, codec}

  def encode_next(%__MODULE__{} = codec, messages) when is_list(messages) do
    with {:ok, stream_type_id} <- MOQLite04.stream_type_id(codec.stream_type),
         {:ok, payloads} <-
           encode_messages(codec.stream_type, codec.side, messages, codec.message_count) do
      prefix =
        if codec.side == :opener and codec.message_count == 0 do
          Codec.encode_varint(stream_type_id)
        else
          <<>>
        end

      codec = %{codec | message_count: codec.message_count + length(messages)}

      {:ok, codec, IO.iodata_to_binary([prefix, payloads])}
    else
      {:error, reason} -> {:error, reason, codec}
    end
  end

  @doc """
  Receives ordered stream bytes and emits any complete messages decoded so far.
  """
  @spec recv(t(), iodata()) :: {:ok, t(), [MOQLite04.message()]} | {:error, term(), t()}
  def recv(%__MODULE__{} = codec, bytes) do
    buffer = codec.buffer <> IO.iodata_to_binary(bytes)
    codec = %{codec | buffer: buffer}

    with {:ok, codec} <- maybe_decode_stream_type(codec),
         {:ok, codec, messages} <- decode_available_messages(codec, []) do
      {:ok, codec, messages}
    else
      {:error, reason, codec} -> {:error, reason, codec}
    end
  end

  defp encode_messages(_stream_type, _side, [], _count), do: {:ok, []}

  defp encode_messages(stream_type, side, [message | rest], count) do
    with :ok <- valid_message?(stream_type, side, message, count),
         {:ok, encoded_rest} <- encode_messages(stream_type, side, rest, count + 1) do
      payload = Encoder.encode(message)

      {:ok,
       [
         [
           message_prefix(stream_type, side, message),
           Codec.encode_varint(byte_size(payload)),
           payload
         ],
         encoded_rest
       ]}
    end
  end

  defp valid_message?(:group, :opener, %MOQLite04.Group{}, 0), do: :ok
  defp valid_message?(:group, :opener, %MOQLite04.Frame{}, count) when count > 0, do: :ok
  defp valid_message?(:announce, :opener, %MOQLite04.AnnounceInterest{}, 0), do: :ok
  defp valid_message?(:announce, :responder, %MOQLite04.Announce{}, _count), do: :ok
  defp valid_message?(:subscribe, :opener, %MOQLite04.Subscribe{}, 0), do: :ok

  defp valid_message?(:subscribe, :opener, %MOQLite04.SubscribeUpdate{}, count) when count > 0,
    do: :ok

  defp valid_message?(:subscribe, :responder, %MOQLite04.SubscribeOk{}, _count), do: :ok
  defp valid_message?(:subscribe, :responder, %MOQLite04.SubscribeDrop{}, _count), do: :ok
  defp valid_message?(:fetch, :opener, %MOQLite04.Fetch{}, 0), do: :ok
  defp valid_message?(:fetch, :responder, %MOQLite04.Frame{}, _count), do: :ok
  defp valid_message?(:probe, _side, %MOQLite04.Probe{}, _count), do: :ok
  defp valid_message?(:goaway, _side, %MOQLite04.Goaway{}, 0), do: :ok

  defp valid_message?(_stream_type, _side, message, _count),
    do: {:error, {:unexpected_message, message}}

  defp message_prefix(:subscribe, :responder, %MOQLite04.SubscribeOk{}) do
    {:ok, id} = MOQLite04.subscribe_response_type_id(:ok)
    Codec.encode_varint(id)
  end

  defp message_prefix(:subscribe, :responder, %MOQLite04.SubscribeDrop{}) do
    {:ok, id} = MOQLite04.subscribe_response_type_id(:drop)
    Codec.encode_varint(id)
  end

  defp message_prefix(_stream_type, _side, _message), do: <<>>

  defp maybe_decode_stream_type(%{stream_type: nil, side: :opener, buffer: buffer} = codec) do
    case Codec.decode_varint(buffer) do
      {:ok, id, rest} ->
        case MOQLite04.stream_type(id) do
          {:ok, stream_type} -> {:ok, %{codec | stream_type: stream_type, buffer: rest}}
          {:error, reason} -> {:error, reason, codec}
        end

      {:error, :incomplete} ->
        {:ok, codec}
    end
  end

  defp maybe_decode_stream_type(%{stream_type: nil} = codec),
    do: {:error, :missing_stream_type, codec}

  defp maybe_decode_stream_type(%__MODULE__{} = codec), do: {:ok, codec}

  defp decode_available_messages(%{stream_type: nil} = codec, messages),
    do: {:ok, codec, Enum.reverse(messages)}

  defp decode_available_messages(%__MODULE__{} = codec, messages) do
    case decode_one_message(codec) do
      {:ok, codec, message} ->
        decode_available_messages(codec, [message | messages])

      {:incomplete, codec} ->
        {:ok, codec, Enum.reverse(messages)}

      {:error, reason, codec} ->
        {:error, reason, codec}
    end
  end

  defp decode_one_message(%{stream_type: :subscribe, side: :responder, buffer: buffer} = codec) do
    case Codec.decode_varint(buffer) do
      {:ok, type_id, rest} ->
        with {:ok, type} <- MOQLite04.subscribe_response_type(type_id),
             {:ok, length, payload_buffer} <- Codec.decode_varint(rest) do
          decode_message_payload(
            codec,
            buffer,
            payload_buffer,
            length,
            subscribe_response_decoder(type)
          )
        else
          {:error, :incomplete} -> {:incomplete, codec}
          {:error, reason} -> {:error, reason, codec}
        end

      {:error, :incomplete} ->
        {:incomplete, codec}
    end
  end

  defp decode_one_message(%{buffer: buffer} = codec) do
    case Codec.decode_varint(buffer) do
      {:ok, length, rest} ->
        case decoder_for(codec.stream_type, codec.side, codec.message_count) do
          {:ok, decoder} -> decode_message_payload(codec, buffer, rest, length, decoder)
          {:error, reason} -> {:error, reason, codec}
        end

      {:error, :incomplete} ->
        {:incomplete, codec}
    end
  end

  defp decode_message_payload(codec, original_buffer, payload_buffer, length, decoder)
       when byte_size(payload_buffer) >= length do
    <<payload::binary-size(^length), rest::binary>> = payload_buffer

    case decoder.decode(payload, %{}) do
      {:ok, message} ->
        {:ok, %{codec | buffer: rest, message_count: codec.message_count + 1}, message}

      {:error, reason} ->
        {:error, reason, %{codec | buffer: original_buffer}}
    end
  end

  defp decode_message_payload(codec, _original_buffer, _payload_buffer, _length, _decoder),
    do: {:incomplete, codec}

  defp decoder_for(:group, :opener, 0), do: {:ok, MOQLite04.Group}
  defp decoder_for(:group, :opener, count) when count > 0, do: {:ok, MOQLite04.Frame}
  defp decoder_for(:announce, :opener, 0), do: {:ok, MOQLite04.AnnounceInterest}
  defp decoder_for(:announce, :responder, _count), do: {:ok, MOQLite04.Announce}
  defp decoder_for(:subscribe, :opener, 0), do: {:ok, MOQLite04.Subscribe}

  defp decoder_for(:subscribe, :opener, count) when count > 0,
    do: {:ok, MOQLite04.SubscribeUpdate}

  defp decoder_for(:fetch, :opener, 0), do: {:ok, MOQLite04.Fetch}
  defp decoder_for(:fetch, :responder, _count), do: {:ok, MOQLite04.Frame}
  defp decoder_for(:probe, _side, _count), do: {:ok, MOQLite04.Probe}
  defp decoder_for(:goaway, _side, 0), do: {:ok, MOQLite04.Goaway}

  defp decoder_for(stream_type, side, _count),
    do: {:error, {:unsupported_stream_side, stream_type, side}}

  defp subscribe_response_decoder(:ok), do: MOQLite04.SubscribeOk
  defp subscribe_response_decoder(:drop), do: MOQLite04.SubscribeDrop
end
