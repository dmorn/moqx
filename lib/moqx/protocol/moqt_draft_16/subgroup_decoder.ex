defmodule MOQX.Protocol.MOQTDraft16.SubgroupDecoder do
  @moduledoc "Incremental decoder for one MOQT draft-16 subgroup stream."

  import Bitwise

  alias MOQX.Protocol.MOQTDraft16.Codec

  defstruct header: nil, buffer: <<>>, previous_object_id: nil

  @type t :: %__MODULE__{
          header: map() | nil,
          buffer: binary(),
          previous_object_id: non_neg_integer() | nil
        }

  @spec push(t(), binary()) :: {:ok, t(), [map()]} | {:error, term()}
  def push(%__MODULE__{} = decoder, data) when is_binary(data) do
    decoder
    |> Map.update!(:buffer, &(&1 <> data))
    |> ensure_header()
    |> decode_objects([])
  end

  @spec complete(t()) :: :ok | {:error, {:incomplete_subgroup_stream, map()}}
  def complete(%__MODULE__{header: header, buffer: <<>>}) when not is_nil(header), do: :ok

  def complete(%__MODULE__{header: header, buffer: buffer}) do
    {:error,
     {:incomplete_subgroup_stream,
      %{header_decoded?: not is_nil(header), buffered_bytes: byte_size(buffer)}}}
  end

  defp ensure_header(%__MODULE__{header: nil, buffer: buffer} = decoder) do
    with {:ok, type, rest} <- Codec.decode_varint(buffer),
         :ok <- valid_header_type(type),
         {:ok, track_alias, rest} <- Codec.decode_varint(rest),
         {:ok, group_id, rest} <- Codec.decode_varint(rest),
         {:ok, subgroup_id, rest} <- decode_subgroup_id(type, rest),
         {:ok, priority, rest} <- decode_priority(type, rest) do
      header = %{
        type: type,
        track_alias: track_alias,
        group_id: group_id,
        subgroup_id: subgroup_id,
        priority: priority,
        extensions?: (type &&& 0x01) != 0,
        end_of_group?: (type &&& 0x08) != 0
      }

      %{decoder | header: header, buffer: rest}
    else
      :more -> {:more, decoder}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_header(decoder), do: decoder

  defp decode_objects({:more, decoder}, objects), do: {:ok, decoder, Enum.reverse(objects)}
  defp decode_objects({:error, reason}, _objects), do: {:error, reason}

  defp decode_objects(%__MODULE__{} = decoder, objects) do
    case decode_object(decoder) do
      {:ok, object, rest} ->
        next = %{decoder | buffer: rest, previous_object_id: object.object_id}
        decode_objects(next, [object | objects])

      :more ->
        {:ok, decoder, Enum.reverse(objects)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_object(%__MODULE__{header: header, buffer: buffer} = decoder) do
    with {:ok, delta, rest} <- Codec.decode_varint(buffer),
         {:ok, extensions, rest} <- decode_extensions(header.extensions?, rest),
         {:ok, payload_length, rest} <- Codec.decode_varint(rest) do
      object_id =
        case decoder.previous_object_id do
          nil -> delta
          previous -> previous + delta + 1
        end

      decode_object_payload(header, object_id, extensions, payload_length, rest)
    end
  end

  defp decode_object_payload(header, object_id, extensions, 0, rest) do
    with {:ok, status, rest} <- Codec.decode_varint(rest),
         {:ok, status} <- decode_object_status(status) do
      {:ok, public_object(header, object_id, extensions, status, ""), rest}
    end
  end

  defp decode_object_payload(header, object_id, extensions, length, rest)
       when byte_size(rest) >= length do
    <<payload::binary-size(^length), rest::binary>> = rest
    {:ok, public_object(header, object_id, extensions, nil, payload), rest}
  end

  defp decode_object_payload(_header, _object_id, _extensions, _length, _rest), do: :more

  defp public_object(header, object_id, extensions, status, payload) do
    %{
      track_alias: header.track_alias,
      group_id: header.group_id,
      subgroup_id: header.subgroup_id || object_id,
      priority: header.priority,
      object_id: object_id,
      status: status,
      extensions: extensions,
      end_of_group?: header.end_of_group?,
      payload: payload
    }
  end

  defp decode_extensions(false, rest), do: {:ok, [], rest}

  defp decode_extensions(true, rest) do
    with {:ok, length, rest} <- Codec.decode_varint(rest),
         true <- byte_size(rest) >= length,
         <<encoded::binary-size(^length), rest::binary>> <- rest,
         {:ok, extensions} <- Codec.decode_extensions(encoded) do
      {:ok, extensions, rest}
    else
      _other -> :more
    end
  end

  defp decode_subgroup_id(type, rest) do
    case (type &&& 0x06) >>> 1 do
      0 -> {:ok, 0, rest}
      1 -> {:ok, nil, rest}
      2 -> Codec.decode_varint(rest)
      3 -> {:error, :reserved_subgroup_id_mode}
    end
  end

  defp decode_priority(type, rest) when (type &&& 0x20) != 0, do: {:ok, nil, rest}
  defp decode_priority(_type, <<priority, rest::binary>>), do: {:ok, priority, rest}
  defp decode_priority(_type, <<>>), do: :more

  defp valid_header_type(type)
       when type in 0x10..0x1F or type in 0x30..0x3F,
       do: :ok

  defp valid_header_type(_type), do: {:error, :invalid_subgroup_header_type}

  defp decode_object_status(0), do: {:ok, nil}
  defp decode_object_status(3), do: {:ok, :end_of_group}
  defp decode_object_status(4), do: {:ok, :end_of_track}
  defp decode_object_status(status), do: {:error, {:invalid_object_status, status}}
end
