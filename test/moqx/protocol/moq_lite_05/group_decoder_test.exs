defmodule MOQX.Protocol.MOQLite05.GroupDecoderTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQLite05.GroupDecoder

  test "incrementally decodes frames with absolute timestamps and group coordinates" do
    decoder = %GroupDecoder{}

    assert {:ok, decoder, []} =
             GroupDecoder.push(decoder, <<0, 2, 4, 7, 0x80, 0x02>>)

    assert {:ok, _decoder, frames} =
             GroupDecoder.push(decoder, <<0xBF, 0x20, 1, "a", 0x57, 0x6F, 1, "b">>)

    assert frames == [
             %{subscribe_id: 4, group_sequence: 7, object_id: 0, timestamp: 90_000, payload: "a"},
             %{subscribe_id: 4, group_sequence: 7, object_id: 1, timestamp: 87_000, payload: "b"}
           ]
  end

  test "accepts a clean Group Stream FIN and rejects a truncated frame" do
    assert {:ok, complete, []} = GroupDecoder.push(%GroupDecoder{}, <<0, 2, 4, 7>>)
    assert :ok = GroupDecoder.complete(complete)

    assert {:ok, truncated, []} = GroupDecoder.push(complete, <<0x40>>)

    assert {:error, {:incomplete_group_stream, %{buffered_bytes: 1}}} =
             GroupDecoder.complete(truncated)
  end
end
