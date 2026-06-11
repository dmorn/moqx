defmodule MOQX.Codec do
  @moduledoc """
  Shared codec namespace for MOQT-family protocol implementations.

  Protocol-specific modules own their wire formats. This namespace holds the
  generic encoder/decoder contracts and will host binary helpers shared by
  draft-14, MOQ Lite, and future protocol variants.
  """

  @max_varint 4_611_686_018_427_387_903

  @typedoc "Unsigned QUIC variable-length integer value."
  @type varint :: 0..4_611_686_018_427_387_903

  @doc """
  Encodes a non-negative integer using QUIC variable-length integer encoding.
  """
  @spec encode_varint(varint()) :: binary()
  def encode_varint(value) when is_integer(value) and value >= 0 and value <= 63 do
    <<value::8>>
  end

  def encode_varint(value) when is_integer(value) and value <= 16_383 do
    <<0b01::2, value::14>>
  end

  def encode_varint(value) when is_integer(value) and value <= 1_073_741_823 do
    <<0b10::2, value::30>>
  end

  def encode_varint(value) when is_integer(value) and value <= @max_varint do
    <<0b11::2, value::62>>
  end

  @doc """
  Decodes one QUIC variable-length integer from the front of a binary.
  """
  @spec decode_varint(binary()) ::
          {:ok, varint(), binary()} | {:error, :incomplete}
  def decode_varint(<<0::2, value::6, rest::binary>>) do
    {:ok, value, rest}
  end

  def decode_varint(<<1::2, value::14, rest::binary>>) do
    {:ok, value, rest}
  end

  def decode_varint(<<2::2, value::30, rest::binary>>) do
    {:ok, value, rest}
  end

  def decode_varint(<<3::2, value::62, rest::binary>>) do
    {:ok, value, rest}
  end

  def decode_varint(_data), do: {:error, :incomplete}

  @doc """
  Encodes a UTF-8 string as a QUIC varint byte length followed by bytes.
  """
  @spec encode_string(String.t()) :: binary()
  def encode_string(value) when is_binary(value) do
    encode_bytes(value)
  end

  @doc """
  Decodes a QUIC varint length-prefixed UTF-8 string.
  """
  @spec decode_string(binary()) ::
          {:ok, String.t(), binary()} | {:error, :incomplete | :invalid_utf8}
  def decode_string(data) when is_binary(data) do
    with {:ok, value, rest} <- decode_bytes(data) do
      if String.valid?(value) do
        {:ok, value, rest}
      else
        {:error, :invalid_utf8}
      end
    end
  end

  @doc """
  Encodes opaque bytes as a QUIC varint byte length followed by bytes.
  """
  @spec encode_bytes(binary()) :: binary()
  def encode_bytes(value) when is_binary(value) do
    [encode_varint(byte_size(value)), value]
    |> IO.iodata_to_binary()
  end

  @doc """
  Decodes QUIC varint length-prefixed opaque bytes.
  """
  @spec decode_bytes(binary()) ::
          {:ok, binary(), binary()} | {:error, :incomplete}
  def decode_bytes(data) when is_binary(data) do
    with {:ok, length, rest} <- decode_varint(data) do
      decode_sized_bytes(rest, length)
    end
  end

  defp decode_sized_bytes(data, length) when byte_size(data) >= length do
    <<value::binary-size(^length), rest::binary>> = data
    {:ok, value, rest}
  end

  defp decode_sized_bytes(_data, _length), do: {:error, :incomplete}
end
