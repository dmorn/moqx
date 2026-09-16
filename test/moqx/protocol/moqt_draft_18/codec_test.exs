defmodule MOQX.Protocol.MOQTDraft18.CodecTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQTDraft18.{Codec, SubgroupDecoder}

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

  test "subgroup carries subgroup id and preserves first-object provenance" do
    object = %MOQX.Object{group_id: 1, subgroup_id: 2, object_id: 0, timestamp: 0, payload: "x"}
    assert <<0x55, _::binary>> = Codec.encode_subgroup(3, object)

    object = %{object | object_id: 1}
    assert <<0x15, _::binary>> = Codec.encode_subgroup(3, object)

    object = %{object | object_id: 4, first_object?: true}
    assert <<0x55, _::binary>> = Codec.encode_subgroup(3, object)
  end

  test "one subgroup stream delta-encodes multiple objects and preserves properties" do
    extension = %MOQX.Extension{protocol: :draft_18, identifier: 0x3D, value: "trace"}

    first = %MOQX.Object{
      group_id: 7,
      subgroup_id: 2,
      object_id: 4,
      timestamp: 0,
      first_object?: true,
      extensions: [extension],
      payload: "a"
    }

    last = %{first | object_id: 6, extensions: [], payload: "b", end_of_group?: true}
    first_bytes = Codec.encode_subgroup(3, first)
    assert {:ok, last_bytes} = Codec.encode_subgroup_object(4, last)

    assert {:ok, decoder, [decoded_first, decoded_last, end_of_group]} =
             SubgroupDecoder.push(%SubgroupDecoder{}, first_bytes <> last_bytes)

    assert decoded_first.object_id == 4
    assert decoded_first.first_object?
    assert decoded_first.priority == 128
    assert decoded_first.extensions == [extension]
    assert decoded_last.object_id == 6
    refute decoded_last.first_object?
    assert end_of_group.object_id == 7
    assert end_of_group.status == :end_of_group
    assert decoder.end_of_group?
  end

  test "padding datagrams require zero-filled payloads" do
    type = Codec.encode_varint(0x132B3E29)
    assert {:ok, :padding} = Codec.decode_datagram(type <> <<0, 0>>)
    assert {:error, :invalid_datagram} = Codec.decode_datagram(type <> <<0, 1>>)
  end

  test "byte-valued properties reject lengths above the draft limit" do
    encoded = <<1>> <> Codec.encode_varint(65_536)
    assert {:error, :invalid_extensions} = Codec.decode_extensions(encoded)
  end

  test "incoming names and reason phrases enforce draft-18 bounds" do
    namespace = IO.iodata_to_binary([Codec.encode_varint(33), List.duplicate(<<1, "x">>, 33)])
    payload = <<1>> <> namespace <> <<1, "t", 0>>
    assert {:error, :invalid_subscribe} = Codec.decode_subscribe(payload)

    reason = :binary.copy("x", 1_025)
    error_payload = <<1, 0>> <> Codec.encode_varint(byte_size(reason)) <> reason
    assert {:error, :invalid_request_error} = Codec.decode_request_error(error_payload)
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
