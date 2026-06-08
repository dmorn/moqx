defprotocol MOQX.Codec.Encoder do
  @moduledoc """
  Protocol for encoding typed values into payload iodata.

  Implementations receive typed values and return iodata for that value's
  payload. Protocol-specific stream codecs decide when to call this protocol
  and own stream type prefixes, payload-size fields, buffering, and FIN
  handling.
  """

  @doc """
  Encodes a typed value into payload iodata.
  """
  @spec encode(t()) :: iodata()
  def encode(value)
end

defimpl MOQX.Codec.Encoder, for: List do
  def encode(list), do: Enum.map(list, &MOQX.Codec.Encoder.encode/1)
end

defimpl MOQX.Codec.Encoder, for: BitString do
  def encode(binary) when is_binary(binary), do: binary
end
