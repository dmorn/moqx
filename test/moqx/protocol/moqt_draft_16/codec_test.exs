defmodule MOQX.Protocol.MOQTDraft16.CodecTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQTDraft16.{Codec, SubgroupDecoder}

  test "encodes raw QUIC setup with path, request credit, and authority" do
    assert Codec.client_setup(URI.parse("moqt://relay.moqtail.dev/live?token=one")) ==
             <<0x20, 0, 40, 3, 1, 15, "/live?token=one", 1, 0x4064::16, 3, 17,
               "relay.moqtail.dev">>
  end

  test "encodes a next-group subscription using draft-16 message parameters" do
    track = %MOQX.TrackRef{namespace: ["moqtail", "testsrc"], track: "catalog"}

    assert Codec.subscribe(0, track, start: :next_group, priority: 127) ==
             <<0x03, 0, 33, 0, 2, 7, "moqtail", 7, "testsrc", 7, "catalog", 2, 0x20, 0x407F::16,
               1, 1, 1>>
  end

  test "decodes setup, subscribe acceptance, and one subgroup object incrementally" do
    assert {:ok, [{0x21, <<0>>}], <<>>} = Codec.decode_control(<<0x21, 0, 1, 0>>)

    assert {:ok, %{request_id: 0, track_alias: 7}} =
             Codec.decode_subscribe_ok(<<0, 7, 0>>)

    decoder = %SubgroupDecoder{}

    assert {:ok, decoder, []} =
             SubgroupDecoder.push(decoder, <<0x34, 7>>)

    assert {:ok, _decoder, [object]} =
             SubgroupDecoder.push(decoder, <<9, 3, 0, 5, "hello">>)

    assert object == %{
             track_alias: 7,
             group_id: 9,
             subgroup_id: 3,
             priority: nil,
             object_id: 0,
             status: nil,
             payload: "hello"
           }
  end

  test "derives subgroup IDs and maps draft-16 object statuses" do
    assert {:ok, _decoder, [object]} =
             SubgroupDecoder.push(%SubgroupDecoder{}, <<0x12, 1, 2, 9, 4, 1, "x">>)

    assert %{subgroup_id: 4, object_id: 4, priority: 9, payload: "x"} = object

    assert {:ok, _decoder, [status]} =
             SubgroupDecoder.push(%SubgroupDecoder{}, <<0x30, 1, 2, 0, 0, 3>>)

    assert %{subgroup_id: 0, status: :end_of_group, payload: ""} = status
  end
end
