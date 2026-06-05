defmodule MOQX.MOQLite04.StreamCodecTest do
  use ExUnit.Case, async: true

  alias MOQX.MOQLite04
  alias MOQX.MOQLite04.StreamCodec

  describe "opener stream round trip" do
    test "encodes and receives a group stream as the original message structs" do
      messages = [
        %MOQLite04.Group{subscribe_id: 7, group_sequence: 42},
        %MOQLite04.Frame{payload: "first"},
        %MOQLite04.Frame{payload: "second"}
      ]

      assert {:ok, bytes} = StreamCodec.encode(:group, messages)
      assert {:ok, codec, decoded} = StreamCodec.recv(StreamCodec.new(), bytes)

      assert codec.stream_type == :group
      assert decoded == messages
    end

    test "encodes and receives opener-side transaction streams" do
      cases = [
        {:announce,
         [
           %MOQLite04.AnnounceInterest{broadcast_path_prefix: "/live", exclude_hop: 0}
         ]},
        {:subscribe,
         [
           %MOQLite04.Subscribe{
             subscribe_id: 9,
             broadcast_path: "/live",
             track_name: "video",
             subscriber_priority: 128,
             subscriber_ordered: :ascending,
             subscriber_max_latency: 500,
             start_group: 11,
             end_group: 0
           },
           %MOQLite04.SubscribeUpdate{
             subscriber_priority: 64,
             subscriber_ordered: :descending,
             subscriber_max_latency: 1_000,
             start_group: 12,
             end_group: 0
           }
         ]},
        {:fetch,
         [
           %MOQLite04.Fetch{
             broadcast_path: "/live",
             track_name: "audio",
             subscriber_priority: 255,
             group_sequence: 42
           }
         ]},
        {:probe,
         [
           %MOQLite04.Probe{bitrate: 1_000_000, rtt: 0},
           %MOQLite04.Probe{bitrate: 2_000_000, rtt: 25}
         ]},
        {:goaway,
         [
           %MOQLite04.Goaway{new_session_uri: ""}
         ]}
      ]

      for {stream_type, messages} <- cases do
        assert {:ok, bytes} = StreamCodec.encode(stream_type, messages)
        assert {:ok, codec, decoded} = StreamCodec.recv(StreamCodec.new(), bytes)

        assert codec.stream_type == stream_type
        assert decoded == messages
      end
    end
  end

  describe "incremental receive" do
    test "buffers incomplete stream and message bytes until enough input arrives" do
      messages = [
        %MOQLite04.Group{subscribe_id: 7, group_sequence: 42},
        %MOQLite04.Frame{payload: "first"}
      ]

      assert {:ok, bytes} = StreamCodec.encode(:group, messages)
      <<first::binary-size(1), second::binary-size(1), rest::binary>> = bytes

      assert {:ok, codec, []} = StreamCodec.recv(StreamCodec.new(), first)
      assert codec.stream_type == :group

      assert {:ok, codec, []} = StreamCodec.recv(codec, second)
      assert codec.stream_type == :group

      assert {:ok, codec, decoded} = StreamCodec.recv(codec, rest)
      assert codec.buffer == <<>>
      assert decoded == messages
    end

    test "reports unknown stream types without decoding messages" do
      assert {:error, :unknown_stream_type, codec} =
               StreamCodec.recv(StreamCodec.new(), <<0x06, 0x00>>)

      assert codec.stream_type == nil
      assert codec.buffer == <<0x06, 0x00>>
    end
  end

  describe "responder stream round trip" do
    test "encodes and receives subscribe responses with response discriminators" do
      messages = [
        %MOQLite04.SubscribeOk{
          publisher_priority: 192,
          publisher_ordered: :ascending,
          publisher_max_latency: 250,
          start_group: 11,
          end_group: 0
        },
        %MOQLite04.SubscribeDrop{
          start_group: 12,
          end_group: 12,
          error_code: 99
        }
      ]

      assert {:ok, bytes} = StreamCodec.encode(:subscribe, messages, side: :responder)
      assert <<0, _rest::binary>> = bytes

      codec = StreamCodec.new(side: :responder, stream_type: :subscribe)
      assert {:ok, codec, decoded} = StreamCodec.recv(codec, bytes)

      assert codec.stream_type == :subscribe
      assert decoded == messages
    end

    test "encodes and receives responder-side transaction streams" do
      cases = [
        {:announce,
         [
           %MOQLite04.Announce{status: :active, broadcast_path_suffix: "/camera-a", hop_ids: [7]},
           %MOQLite04.Announce{status: :ended, broadcast_path_suffix: "/camera-a", hop_ids: [7]}
         ]},
        {:fetch,
         [
           %MOQLite04.Frame{payload: "first"},
           %MOQLite04.Frame{payload: "second"}
         ]},
        {:probe,
         [
           %MOQLite04.Probe{bitrate: 1_500_000, rtt: 25}
         ]},
        {:goaway,
         [
           %MOQLite04.Goaway{new_session_uri: "moql://edge.example/live"}
         ]}
      ]

      for {stream_type, messages} <- cases do
        assert {:ok, bytes} = StreamCodec.encode(stream_type, messages, side: :responder)

        codec = StreamCodec.new(side: :responder, stream_type: stream_type)
        assert {:ok, codec, decoded} = StreamCodec.recv(codec, bytes)

        assert codec.stream_type == stream_type
        assert decoded == messages
      end
    end
  end
end
