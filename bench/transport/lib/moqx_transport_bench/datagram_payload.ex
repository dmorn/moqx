defmodule MOQX.TransportBench.DatagramPayload do
  @moduledoc false

  @header_size 16

  def header_size, do: @header_size

  def padding_for_size(size) when is_integer(size) and size >= @header_size do
    :binary.copy(<<0>>, size - @header_size)
  end

  def encode(sequence, size, sent_at_us)
      when is_integer(sequence) and is_integer(size) and is_integer(sent_at_us) and
             size >= @header_size do
    encode(sequence, sent_at_us, padding_for_size(size))
  end

  def encode(sequence, sent_at_us, padding)
      when is_integer(sequence) and is_integer(sent_at_us) and is_binary(padding) do
    <<sequence::unsigned-big-64, sent_at_us::signed-big-64, padding::binary>>
  end

  def decode(<<sequence::unsigned-big-64, sent_at_us::signed-big-64, _rest::binary>>) do
    {:ok, sequence, sent_at_us}
  end

  def decode(_payload), do: :error

  def sequence(<<sequence::unsigned-big-64, _rest::binary>>), do: {:ok, sequence}
  def sequence(_payload), do: :error
end
