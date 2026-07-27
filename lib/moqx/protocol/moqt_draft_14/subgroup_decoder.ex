defmodule MOQX.Protocol.MOQTDraft14.SubgroupDecoder do
  @moduledoc "Incremental decoder for one draft-14 subgroup stream."

  alias MOQX.Protocol.MOQTDraft14.Codec

  defstruct header: nil, buffer: <<>>, current_object_id: 0, object_count: 0

  @type t :: %__MODULE__{
          header: struct() | nil,
          buffer: binary(),
          current_object_id: non_neg_integer(),
          object_count: non_neg_integer()
        }

  @spec push(t(), binary()) :: {:ok, t(), [struct()]} | {:error, term()}
  def push(%__MODULE__{} = decoder, data) when is_binary(data) do
    decoder
    |> Map.update!(:buffer, &(&1 <> data))
    |> ensure_header()
    |> decode_objects([])
  end

  @spec complete(t()) :: :ok | {:error, {:incomplete_subgroup_stream, map()}}
  def complete(%__MODULE__{header: header, buffer: <<>>, object_count: count})
      when not is_nil(header) and count > 0,
      do: :ok

  def complete(%__MODULE__{header: header, buffer: buffer}) do
    {:error,
     {:incomplete_subgroup_stream,
      %{header_decoded?: not is_nil(header), buffered_bytes: byte_size(buffer)}}}
  end

  defp ensure_header(%__MODULE__{header: nil, buffer: buffer} = decoder) do
    case Codec.decode_subgroup_header(buffer) do
      {:ok, header, rest} -> %{decoder | header: header, buffer: rest}
      :more -> {:more, decoder}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_header(decoder), do: decoder

  defp decode_objects({:more, decoder}, objects), do: {:ok, decoder, Enum.reverse(objects)}
  defp decode_objects({:error, reason}, _objects), do: {:error, reason}

  defp decode_objects(%__MODULE__{} = decoder, objects) do
    case Codec.decode_subgroup_object(decoder.header, decoder.current_object_id, decoder.buffer) do
      {:ok, object, rest} ->
        next = %{
          decoder
          | buffer: rest,
            current_object_id: object.object_id,
            object_count: decoder.object_count + 1
        }

        decode_objects(next, [object | objects])

      :more ->
        {:ok, decoder, Enum.reverse(objects)}
    end
  end
end
