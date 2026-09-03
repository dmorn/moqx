defmodule MOQX.Protocol.MOQLite05.CodecTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQLite05.Codec

  alias MOQX.Protocol.MOQLite05.Messages.{
    AnnounceBroadcast,
    AnnounceOk,
    AnnounceRequest,
    Frame,
    Group,
    Setup,
    Subscribe,
    SubscribeDrop,
    SubscribeEnd,
    SubscribeOk,
    SubscribeUpdate,
    Track,
    TrackInfo
  }

  alias MOQX.Protocol.MOQLite05.StreamType

  test "maps every draft-05 stream type by direction" do
    assert StreamType.bidirectional() == %{
             0x1 => :announce,
             0x2 => :subscribe,
             0x3 => :fetch,
             0x4 => :probe,
             0x5 => :goaway,
             0x6 => :track
           }

    assert StreamType.unidirectional() == %{0x0 => :group, 0x1 => :setup}
  end

  test "encodes SETUP path, probe capability, and subscriber role" do
    setup = %Setup{path: "/live?token=one", probe: :report, role: :subscriber}

    assert Codec.encode_setup(setup) ==
             <<24, 3, 1, 1, 1, 2, 15, "/live?token=one", 3, 1, 2>>
  end

  test "decodes SETUP path, probe capability, and publisher role" do
    encoded = <<20, 3, 1, 1, 2, 2, 11, "/ingest?x=1", 3, 1, 1>>

    assert Codec.decode_setup(encoded) ==
             {:ok, %Setup{path: "/ingest?x=1", probe: :increase, role: :publisher}}
  end

  test "encodes immutable TRACK_INFO timing and delivery properties" do
    info = %TrackInfo{
      publisher_priority: 17,
      publisher_ordered: true,
      publisher_max_latency: 2_000,
      timescale: 90_000
    }

    assert Codec.encode_track_info(info) ==
             <<8, 17, 1, 0x47, 0xD0, 0x80, 0x01, 0x5F, 0x90>>
  end

  test "decodes immutable TRACK_INFO timing and delivery properties" do
    encoded = <<8, 17, 0, 0x43, 0xE8, 0x80, 0x0F, 0x42, 0x40>>

    assert Codec.decode_track_info(encoded) ==
             {:ok,
              %TrackInfo{
                publisher_priority: 17,
                publisher_ordered: false,
                publisher_max_latency: 1_000,
                timescale: 1_000_000
              }}
  end

  test "encodes and decodes a TRACK address" do
    track = %Track{broadcast_path: "live/cam", track_name: "video"}
    encoded = <<15, 8, "live/cam", 5, "video">>

    assert Codec.encode_track(track) == encoded
    assert Codec.decode_track(encoded) == {:ok, track}
  end

  test "encodes and decodes a SUBSCRIBE transaction request" do
    subscribe = %Subscribe{
      subscribe_id: 9,
      broadcast_path: "live/cam",
      track_name: "video",
      subscriber_priority: 200,
      subscriber_ordered: true,
      subscriber_max_latency: 1_000,
      group_start: 4,
      group_end: 9
    }

    encoded = <<22, 9, 8, "live/cam", 5, "video", 200, 1, 0x43, 0xE8, 5, 10>>

    assert Codec.encode_subscribe(subscribe) == encoded
    assert Codec.decode_subscribe(encoded) == {:ok, subscribe}
  end

  test "encodes and decodes a SUBSCRIBE_UPDATE on an existing stream" do
    update = %SubscribeUpdate{
      subscriber_priority: 150,
      subscriber_ordered: false,
      subscriber_max_latency: 250,
      group_start: nil,
      group_end: 5
    }

    encoded = <<6, 150, 0, 0x40, 0xFA, 0, 6>>

    assert Codec.encode_subscribe_update(update) == encoded
    assert Codec.decode_subscribe_update(encoded) == {:ok, update}
  end

  test "encodes the draft-05 Subscribe Stream response variants" do
    assert Codec.encode_subscribe_response(%SubscribeOk{group: 7}) == <<0, 1, 7>>
    assert Codec.encode_subscribe_response(%SubscribeEnd{group: 9}) == <<1, 1, 9>>

    assert Codec.encode_subscribe_response(%SubscribeDrop{
             group_start: 3,
             group_end: 5,
             error_code: 42
           }) == <<2, 3, 3, 5, 42>>
  end

  test "incrementally decodes Subscribe Stream responses without consuming a partial message" do
    trailing = <<2, 3, 3>>
    encoded = <<0, 1, 7, 1, 1, 9, 2, 3, 3, 5, 42, trailing::binary>>

    assert Codec.decode_subscribe_responses(encoded) ==
             {:ok,
              [
                %SubscribeOk{group: 7},
                %SubscribeEnd{group: 9},
                %SubscribeDrop{group_start: 3, group_end: 5, error_code: 42}
              ], trailing}
  end

  test "encodes and decodes a FRAME timestamp delta independently of its payload" do
    frame = %Frame{timestamp_delta: 90_000, payload: "hello"}
    encoded = <<0x80, 0x02, 0xBF, 0x20, 5, "hello">>

    assert Codec.encode_frame(frame) == encoded
    assert Codec.decode_frame(encoded) == {:ok, frame, <<>>}
  end

  test "encodes and decodes a GROUP subscription coordinate" do
    group = %Group{subscribe_id: 4, group_sequence: 7}
    encoded = <<2, 4, 7>>

    assert Codec.encode_group(group) == encoded
    assert Codec.decode_group(encoded) == {:ok, group}
  end

  test "encodes and decodes the Announce Stream message family" do
    request = %AnnounceRequest{broadcast_path_prefix: "live/", exclude_hop: 42}
    ok = %AnnounceOk{hop_id: 70, active_count: 2}
    broadcast = %AnnounceBroadcast{status: :active, path_suffix: "cam", hop_ids: [4, 5]}

    assert Codec.encode_announce_request(request) == <<7, 5, "live/", 42>>
    assert Codec.decode_announce_request(<<7, 5, "live/", 42>>) == {:ok, request}
    assert Codec.encode_announce_ok(ok) == <<3, 0x40, 0x46, 2>>
    assert Codec.decode_announce_ok(<<3, 0x40, 0x46, 2>>) == {:ok, ok}
    assert Codec.encode_announce_broadcast(broadcast) == <<8, 1, 3, "cam", 2, 4, 5>>
    assert Codec.decode_announce_broadcast(<<8, 1, 3, "cam", 2, 4, 5>>) == {:ok, broadcast}
  end
end
