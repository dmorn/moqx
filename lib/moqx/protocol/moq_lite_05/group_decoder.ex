defmodule MOQX.Protocol.MOQLite05.GroupDecoder do
  @moduledoc "Incremental decoder for one publisher-created Group Stream."

  alias MOQX.Codec, as: BinaryCodec
  alias MOQX.Protocol.MOQLite05.Codec

  defstruct buffer: <<>>, stream_type?: false, group: nil, timestamp: 0, next_frame_id: 0

  @type decoded_frame :: %{
          subscribe_id: non_neg_integer(),
          group_sequence: non_neg_integer(),
          object_id: non_neg_integer(),
          timestamp: integer(),
          payload: binary()
        }

  @type t :: %__MODULE__{
          buffer: binary(),
          stream_type?: boolean(),
          group: MOQX.Protocol.MOQLite05.Messages.Group.t() | nil,
          timestamp: integer(),
          next_frame_id: non_neg_integer()
        }

  @spec push(t(), binary()) ::
          {:ok, t(), [decoded_frame()]} | {:error, :invalid_group_stream}
  def push(%__MODULE__{} = decoder, data) when is_binary(data) do
    decoder = %{decoder | buffer: decoder.buffer <> data}

    case decode_header(decoder) do
      {:ok, decoder} -> decode_frames(decoder, [])
      {:more, decoder} -> {:ok, decoder, []}
      {:error, _reason} = error -> error
    end
  end

  @spec complete(t()) :: :ok | {:error, {:incomplete_group_stream, map()}}
  def complete(%__MODULE__{stream_type?: true, group: group, buffer: <<>>})
      when not is_nil(group),
      do: :ok

  def complete(%__MODULE__{} = decoder) do
    {:error,
     {:incomplete_group_stream,
      %{
        header_decoded?: not is_nil(decoder.group),
        buffered_bytes: byte_size(decoder.buffer)
      }}}
  end

  defp decode_header(%__MODULE__{stream_type?: false, buffer: buffer} = decoder) do
    case BinaryCodec.decode_varint(buffer) do
      {:ok, 0x0, rest} -> decode_header(%{decoder | stream_type?: true, buffer: rest})
      {:ok, _unknown, _rest} -> {:error, :invalid_group_stream}
      {:error, :incomplete} -> {:more, decoder}
    end
  end

  defp decode_header(%__MODULE__{group: nil, buffer: buffer} = decoder) do
    case split_framed(buffer) do
      {:ok, encoded, rest} ->
        case Codec.decode_group(encoded) do
          {:ok, group} -> {:ok, %{decoder | group: group, buffer: rest}}
          {:error, :invalid_group} -> {:error, :invalid_group_stream}
        end

      :more ->
        {:more, decoder}
    end
  end

  defp decode_header(%__MODULE__{} = decoder), do: {:ok, decoder}

  defp decode_frames(%__MODULE__{buffer: buffer} = decoder, frames) do
    case Codec.decode_frame(buffer) do
      {:ok, frame, rest} ->
        timestamp = decoder.timestamp + frame.timestamp_delta
        group = decoder.group

        decoded = %{
          subscribe_id: group.subscribe_id,
          group_sequence: group.group_sequence,
          object_id: decoder.next_frame_id,
          timestamp: timestamp,
          payload: frame.payload
        }

        decode_frames(
          %{
            decoder
            | buffer: rest,
              timestamp: timestamp,
              next_frame_id: decoder.next_frame_id + 1
          },
          [decoded | frames]
        )

      :more ->
        {:ok, decoder, Enum.reverse(frames)}
    end
  end

  defp split_framed(data) do
    case BinaryCodec.decode_varint(data) do
      {:ok, length, rest} when byte_size(rest) >= length ->
        <<_payload::binary-size(^length), trailing::binary>> = rest
        prefix_size = byte_size(data) - byte_size(rest)
        encoded = binary_part(data, 0, prefix_size + length)
        {:ok, encoded, trailing}

      _incomplete ->
        :more
    end
  end
end
