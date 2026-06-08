defmodule MOQX.MOQLite04.PayloadCodecTest do
  use ExUnit.Case, async: true

  alias MOQX.Codec.Encoder
  alias MOQX.MOQLite04

  describe "AnnounceInterest payload" do
    test "encodes and decodes a complete payload" do
      message = %MOQLite04.AnnounceInterest{
        broadcast_path_prefix: "/live",
        exclude_hop: 7
      }

      payload = <<5, "/live", 7>>

      assert Encoder.encode(message) == payload
      assert MOQLite04.AnnounceInterest.decode(payload, %{}) == {:ok, message}
    end

    test "rejects trailing bytes" do
      assert MOQLite04.AnnounceInterest.decode(<<5, "/live", 7, 0>>, %{}) ==
               {:error, :trailing_bytes}
    end
  end

  describe "Announce payload" do
    test "encodes and decodes a complete payload" do
      message = %MOQLite04.Announce{
        status: :active,
        broadcast_path_suffix: "/cam",
        hop_ids: [7, 8]
      }

      payload = <<1, 4, "/cam", 2, 7, 8>>

      assert Encoder.encode(message) == payload
      assert MOQLite04.Announce.decode(payload, %{}) == {:ok, message}
    end

    test "rejects invalid announce status values" do
      assert MOQLite04.Announce.decode(<<2, 0, 0>>, %{}) == {:error, :invalid_announce_status}
    end
  end

  describe "subscription payloads" do
    test "encodes and decodes Subscribe" do
      message = %MOQLite04.Subscribe{
        subscribe_id: 9,
        broadcast_path: "/live",
        track_name: "video",
        subscriber_priority: 128,
        subscriber_ordered: :ascending,
        subscriber_max_latency: 500,
        start_group: 11,
        end_group: 0
      }

      payload =
        IO.iodata_to_binary([9, 5, "/live", 5, "video", 128, 1, <<0b01::2, 500::14>>, 11, 0])

      assert Encoder.encode(message) == payload
      assert MOQLite04.Subscribe.decode(payload, %{}) == {:ok, message}
    end

    test "encodes and decodes SubscribeUpdate" do
      message = %MOQLite04.SubscribeUpdate{
        subscriber_priority: 64,
        subscriber_ordered: :descending,
        subscriber_max_latency: 1_000,
        start_group: 11,
        end_group: 20
      }

      payload = IO.iodata_to_binary([64, 0, <<0b01::2, 1_000::14>>, 11, 20])

      assert Encoder.encode(message) == payload
      assert MOQLite04.SubscribeUpdate.decode(payload, %{}) == {:ok, message}
    end

    test "encodes and decodes SubscribeOk" do
      message = %MOQLite04.SubscribeOk{
        publisher_priority: 192,
        publisher_ordered: :ascending,
        publisher_max_latency: 250,
        start_group: 11,
        end_group: 0
      }

      payload = IO.iodata_to_binary([192, 1, <<0b01::2, 250::14>>, 11, 0])

      assert Encoder.encode(message) == payload
      assert MOQLite04.SubscribeOk.decode(payload, %{}) == {:ok, message}
    end

    test "encodes and decodes SubscribeDrop" do
      message = %MOQLite04.SubscribeDrop{
        start_group: 11,
        end_group: 12,
        error_code: 99
      }

      payload = <<11, 12, 0b01::2, 99::14>>

      assert Encoder.encode(message) == payload
      assert MOQLite04.SubscribeDrop.decode(payload, %{}) == {:ok, message}
    end

    test "rejects invalid group order values" do
      assert MOQLite04.SubscribeUpdate.decode(<<64, 2, 0, 0, 0>>, %{}) ==
               {:error, :invalid_group_order}
    end
  end

  describe "fetch, probe, goaway, group, and frame payloads" do
    test "encodes and decodes Fetch" do
      message = %MOQLite04.Fetch{
        broadcast_path: "/live",
        track_name: "audio",
        subscriber_priority: 255,
        group_sequence: 42
      }

      payload = <<5, "/live", 5, "audio", 255, 42>>

      assert Encoder.encode(message) == payload
      assert MOQLite04.Fetch.decode(payload, %{}) == {:ok, message}
    end

    test "encodes and decodes Probe" do
      message = %MOQLite04.Probe{bitrate: 1_000_000, rtt: 25}
      payload = <<0b10::2, 1_000_000::30, 25>>

      assert Encoder.encode(message) == payload
      assert MOQLite04.Probe.decode(payload, %{}) == {:ok, message}
    end

    test "encodes and decodes Goaway" do
      message = %MOQLite04.Goaway{new_session_uri: "moql://edge.example/live"}
      payload = <<24, "moql://edge.example/live">>

      assert Encoder.encode(message) == payload
      assert MOQLite04.Goaway.decode(payload, %{}) == {:ok, message}
    end

    test "encodes and decodes Group" do
      message = %MOQLite04.Group{subscribe_id: 1, group_sequence: 42}
      payload = <<1, 42>>

      assert Encoder.encode(message) == payload
      assert MOQLite04.Group.decode(payload, %{}) == {:ok, message}
    end

    test "encodes and decodes Frame" do
      message = %MOQLite04.Frame{payload: <<0, 1, "media">>}
      payload = <<7, 0, 1, "media">>

      assert Encoder.encode(message) == payload
      assert MOQLite04.Frame.decode(payload, %{}) == {:ok, message}
    end
  end
end
