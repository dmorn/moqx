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

    assert Codec.subscribe(0, track, start: :next_object, priority: 127) ==
             <<0x03, 0, 33, 0, 2, 7, "moqtail", 7, "testsrc", 7, "catalog", 2, 0x20, 0x407F::16,
               1, 1, 2>>
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
             extensions: [],
             end_of_group?: false,
             payload: "hello"
           }
  end

  test "control framing returns an incomplete trailing frame without consuming it" do
    trailing = <<0x04, 0>>

    assert {:ok, [{0x21, <<0>>}], ^trailing} =
             Codec.decode_control(<<0x21, 0, 1, 0, trailing::binary>>)
  end

  test "strictly decodes server setup parameters and rejects malformed payloads" do
    assert {:ok,
            %{
              max_request_id: 42,
              parameters: [
                %MOQX.SubscriptionParameter.Extension{
                  protocol: :draft_16,
                  identifier: 0x07,
                  value: "moqtail"
                }
              ]
            }} = Codec.decode_server_setup(<<2, 2, 42, 5, 7, "moqtail">>)

    assert {:error, :invalid_server_setup} = Codec.decode_server_setup(<<0, 99>>)
    assert {:error, :invalid_server_setup} = Codec.decode_server_setup(<<1, 2>>)
    assert {:error, :invalid_server_setup} = Codec.decode_server_setup(<<1, 1, 0>>)
  end

  test "decodes subscribe ok parameters and track extensions losslessly" do
    assert {:ok,
            %{
              request_id: 0,
              track_alias: 7,
              parameters: [
                %MOQX.SubscriptionParameter.Expires{milliseconds: 900},
                %MOQX.SubscriptionParameter.GroupOrder{value: :descending}
              ],
              track_extensions: [
                %MOQX.Extension{
                  protocol: :draft_16,
                  identifier: 0x3E,
                  value: 4
                }
              ]
            }} =
             Codec.decode_subscribe_ok(<<0, 7, 2, 8, 0x43, 0x84, 0x1A, 2, 0x3E, 4>>)

    assert {:error, :invalid_subscribe_ok} = Codec.decode_subscribe_ok(<<0, 7, 0, 1>>)
  end

  test "decodes publish done and unified payload/status datagrams" do
    assert {:ok, %{request_id: 2, status_code: 2, stream_count: 1, reason: "ended"}} =
             Codec.decode_publish_done(<<2, 2, 1, 5, "ended">>)

    assert {:ok,
            %{
              track_alias: 7,
              group_id: 9,
              object_id: 3,
              priority: 17,
              status: nil,
              end_of_group?: true,
              payload: "media"
            }} = Codec.decode_datagram(<<0x02, 7, 9, 3, 17, "media">>)

    assert {:ok,
            %{
              track_alias: 7,
              group_id: 9,
              object_id: 0,
              priority: nil,
              status: :end_of_track,
              end_of_group?: false,
              payload: ""
            }} = Codec.decode_datagram(<<0x2C, 7, 9, 4>>)

    assert {:error, :invalid_datagram} = Codec.decode_datagram(<<0x22, 7, 9, 0>>)
    assert {:error, :invalid_datagram} = Codec.decode_datagram(<<0x10, 7, 9>>)
  end

  test "encodes request update and decodes its acknowledgement" do
    filter = %MOQX.SubscriptionFilter{
      type: :absolute_start,
      start_location: {12, 4}
    }

    assert Codec.request_update(2, 0, filter: filter, priority: 9) ==
             <<2, 0, 10, 2, 0, 2, 0x20, 9, 1, 3, 3, 12, 4>>

    assert {:ok, %{request_id: 2, parameters: []}} = Codec.decode_request_ok(<<2, 0>>)
    assert {:error, :invalid_request_ok} = Codec.decode_request_ok(<<2>>)
  end

  test "derives subgroup IDs and maps draft-16 object statuses" do
    assert {:ok, _decoder, [object]} =
             SubgroupDecoder.push(%SubgroupDecoder{}, <<0x12, 1, 2, 9, 4, 1, "x">>)

    assert %{subgroup_id: 4, object_id: 4, priority: 9, payload: "x"} = object

    assert {:ok, _decoder, [status]} =
             SubgroupDecoder.push(%SubgroupDecoder{}, <<0x30, 1, 2, 0, 0, 3>>)

    assert %{subgroup_id: 0, status: :end_of_group, payload: ""} = status
  end

  test "preserves subgroup extensions/end-of-group and detects truncated streams" do
    assert {:ok, decoder, [object]} =
             SubgroupDecoder.push(
               %SubgroupDecoder{},
               <<0x39, 7, 9, 0, 2, 0x3E, 4, 1, "x">>
             )

    assert object.end_of_group?

    assert object.extensions == [
             %MOQX.Extension{
               protocol: :draft_16,
               identifier: 0x3E,
               value: 4
             }
           ]

    assert :ok = SubgroupDecoder.complete(decoder)

    assert {:ok, _decoder, [%{extensions: [], payload: "relay"}]} =
             SubgroupDecoder.push(
               %SubgroupDecoder{},
               <<0x39, 7, 9, 0, 0, 5, "relay">>
             )

    assert {:ok, truncated, []} =
             SubgroupDecoder.push(%SubgroupDecoder{}, <<0x34, 7, 9, 3, 0, 5, "hi">>)

    assert {:error, {:incomplete_subgroup_stream, %{header_decoded?: true, buffered_bytes: 4}}} =
             SubgroupDecoder.complete(truncated)
  end
end
