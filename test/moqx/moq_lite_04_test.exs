defmodule MOQX.MOQLite04Test do
  use ExUnit.Case, async: true

  alias MOQX.MOQLite04

  describe "stream types" do
    test "maps known stream types to draft-04 numeric IDs" do
      assert MOQLite04.stream_type_id(:group) == {:ok, 0x0}
      assert MOQLite04.stream_type_id(:announce) == {:ok, 0x1}
      assert MOQLite04.stream_type_id(:subscribe) == {:ok, 0x2}
      assert MOQLite04.stream_type_id(:fetch) == {:ok, 0x3}
      assert MOQLite04.stream_type_id(:probe) == {:ok, 0x4}
      assert MOQLite04.stream_type_id(:goaway) == {:ok, 0x5}
    end

    test "maps draft-04 numeric IDs to known stream types" do
      assert MOQLite04.stream_type(0x0) == {:ok, :group}
      assert MOQLite04.stream_type(0x1) == {:ok, :announce}
      assert MOQLite04.stream_type(0x2) == {:ok, :subscribe}
      assert MOQLite04.stream_type(0x3) == {:ok, :fetch}
      assert MOQLite04.stream_type(0x4) == {:ok, :probe}
      assert MOQLite04.stream_type(0x5) == {:ok, :goaway}
    end

    test "rejects unknown stream types" do
      assert MOQLite04.stream_type_id(:unknown) == {:error, :unknown_stream_type}
      assert MOQLite04.stream_type(0x6) == {:error, :unknown_stream_type}
    end
  end

  describe "message structs" do
    test "defines announcement messages" do
      assert %MOQLite04.AnnounceInterest{
               broadcast_path_prefix: "/live",
               exclude_hop: 0
             } = %MOQLite04.AnnounceInterest{broadcast_path_prefix: "/live"}

      assert %MOQLite04.Announce{
               status: :active,
               broadcast_path_suffix: "/camera-a",
               hop_ids: [7, 8]
             } = %MOQLite04.Announce{
               status: :active,
               broadcast_path_suffix: "/camera-a",
               hop_ids: [7, 8]
             }
    end

    test "defines subscription messages" do
      assert %MOQLite04.Subscribe{
        subscribe_id: 1,
        broadcast_path: "/live",
        track_name: "video",
        subscriber_priority: 128,
        subscriber_ordered: :descending,
        subscriber_max_latency: 500,
        start_group: 0,
        end_group: 0
      }

      assert %MOQLite04.SubscribeUpdate{
        subscriber_priority: 64,
        subscriber_ordered: :ascending,
        subscriber_max_latency: 1_000,
        start_group: 11,
        end_group: 20
      }

      assert %MOQLite04.SubscribeOk{
        publisher_priority: 192,
        publisher_ordered: :descending,
        publisher_max_latency: 250,
        start_group: 11,
        end_group: 0
      }

      assert %MOQLite04.SubscribeDrop{
        start_group: 11,
        end_group: 12,
        error_code: 0
      }
    end

    test "defines fetch, probe, goaway, group, and frame messages" do
      assert %MOQLite04.Fetch{
        broadcast_path: "/live",
        track_name: "audio",
        subscriber_priority: 255,
        group_sequence: 42
      }

      assert %MOQLite04.Probe{bitrate: 1_000_000, rtt: 25}
      assert %MOQLite04.Goaway{new_session_uri: "moql://edge.example/live"}
      assert %MOQLite04.Group{subscribe_id: 1, group_sequence: 42}
      assert %MOQLite04.Frame{payload: "opaque"}
    end
  end
end
