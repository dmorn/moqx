defmodule MOQX.Protocol.MOQTDraft18.CodecTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQTDraft18.Codec

  test "leading-one vi64 round trips every asymmetric length boundary" do
    values = [0, 127, 128, 16_383, 16_384, 2_097_151, 2_097_152, 0xFFFFFFFFFFFFFFFF]

    for value <- values do
      encoded = Codec.encode_varint(value)
      assert {:ok, ^value, <<>>} = Codec.decode_varint(encoded)
    end

    assert byte_size(Codec.encode_varint(127)) == 1
    assert byte_size(Codec.encode_varint(128)) == 2
    assert byte_size(Codec.encode_varint(0xFFFFFFFFFFFFFFFF)) == 9
  end

  test "decoder permits a non-minimal vi64 encoding" do
    assert {:ok, 1, <<0xAA>>} = Codec.decode_varint(<<0b10000000, 1, 0xAA>>)
  end

  test "native QUIC setup uses 0x2f00, u16 framing, PATH, and AUTHORITY" do
    setup = Codec.client_setup(URI.parse("moqt://relay.example/live?x=1"))
    assert {:ok, [{0x2F00, payload}], <<>>} = Codec.decode_control(setup)
    assert byte_size(payload) == byte_size(setup) - 4
    assert payload =~ "/live?x=1"
    assert payload =~ "relay.example"
  end

  test "request-stream responses contain no request id" do
    assert Codec.request_ok() == <<0x07, 0, 1, 0>>
    assert Codec.subscribe_ok(5) == <<0x04, 0, 2, 5, 0>>
    assert Codec.request_error(4, "no") == <<0x05, 0, 5, 4, 0, 2, "no">>

    assert Codec.publish_done(5, 0x3FFF_FFFF_FFFF_FFFF, "") ==
             <<0x0B, 0, 11, 5, 0xFF, 0x3FFF_FFFF_FFFF_FFFF::64, 0>>
  end

  test "message parameters use their declared value encoding" do
    track = %MOQX.TrackRef{namespace: [], track: "x"}
    encoded = Codec.subscribe(1, track, priority: 128)
    assert {:ok, [{0x03, payload}], <<>>} = Codec.decode_control(encoded)

    # request id, empty namespace, track, count=2, priority delta/value,
    # filter delta/length/value. Priority is uint8, not vi64.
    assert payload == <<1, 0, 1, "x", 2, 0x20, 128, 1, 1, 2>>
    assert {:ok, %{subscriber_priority: 128}} = Codec.decode_subscribe(payload)
  end

  test "absolute range end group is decoded from its delta" do
    track = %MOQX.TrackRef{namespace: ["n"], track: "t"}

    filter = %MOQX.SubscriptionFilter{
      type: :absolute_range,
      start_location: {10, 2},
      end_group: 13
    }

    encoded = Codec.subscribe(1, track, filter: filter)
    assert {:ok, [{0x03, payload}], <<>>} = Codec.decode_control(encoded)
    assert {:ok, %{filter: %{end_group: 13}}} = Codec.decode_subscribe(payload)
  end

  test "subgroup explicitly carries subgroup id and marks only object zero first" do
    object = %MOQX.Object{group_id: 1, subgroup_id: 2, object_id: 0, timestamp: 0, payload: "x"}
    assert <<0x54, _::binary>> = Codec.encode_subgroup(3, object)

    object = %{object | object_id: 1}
    assert <<0x14, _::binary>> = Codec.encode_subgroup(3, object)
  end

  test "unknown message parameters are fatal instead of guessed from parity" do
    payload = <<1, 0, 1, "x", 1, 0x24, 7>>
    assert {:error, :invalid_subscribe} = Codec.decode_subscribe(payload)
  end

  test "datagram decoder accepts only registered draft-18 type patterns" do
    assert {:ok, %{payload: "x"}} = Codec.decode_datagram(<<0x0C, 1, 2, "x">>)
    assert {:error, :invalid_datagram} = Codec.decode_datagram(<<0x10>>)
    assert {:error, :invalid_datagram} = Codec.decode_datagram(<<0x22>>)
  end
end
