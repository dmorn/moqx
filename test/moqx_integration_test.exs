defmodule MOQXIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @timeout 10_000

  setup_all do
    relay = MOQX.Test.Relay.start()
    on_exit(fn -> MOQX.Test.Relay.stop(relay) end)
    %{relay_url: MOQX.Test.Relay.url()}
  end

  defp connect_publisher!(url) do
    :ok = MOQX.connect_publisher(url)

    receive do
      {:moqx_connected, session} -> session
      {:error, reason} -> raise "publisher connect failed: #{inspect(reason)}"
    after
      @timeout -> raise "publisher connect timeout"
    end
  end

  defp connect_subscriber!(url) do
    :ok = MOQX.connect_subscriber(url)

    receive do
      {:moqx_connected, session} -> session
      {:error, reason} -> raise "subscriber connect failed: #{inspect(reason)}"
    after
      @timeout -> raise "subscriber connect timeout"
    end
  end

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  defp await_subscribed!(broadcast_path, track_name) do
    receive do
      {:moqx_subscribed, ^broadcast_path, ^track_name} -> :ok
      {:moqx_error, reason} -> flunk("subscribe failed: #{inspect(reason)}")
    after
      @timeout -> flunk("subscribe timeout")
    end
  end

  defp await_frame!(expected_group_seq, expected_payload) do
    receive do
      {:moqx_frame, ^expected_group_seq, ^expected_payload} -> :ok
      {:moqx_error, reason} -> flunk("frame receive failed: #{inspect(reason)}")
      other -> flunk("unexpected message while waiting for frame: #{inspect(other)}")
    after
      @timeout -> flunk("frame timeout")
    end
  end

  defp await_track_ended! do
    receive do
      :moqx_track_ended -> :ok
      {:moqx_error, reason} -> flunk("track ended with error: #{inspect(reason)}")
      other -> flunk("unexpected message while waiting for track end: #{inspect(other)}")
    after
      @timeout -> flunk("track end timeout")
    end
  end

  defp with_sessions(url, fun) do
    publisher = connect_publisher!(url)
    subscriber = connect_subscriber!(url)

    try do
      fun.(publisher, subscriber)
    after
      :ok = MOQX.close(publisher)
      :ok = MOQX.close(subscriber)
    end
  end

  describe "current supported architecture" do
    test "single-frame relay-backed round trip", %{relay_url: url} do
      with_sessions(url, fn publisher, subscriber ->
        broadcast_path = "anon/single-frame"
        track_name = "video"

        {:ok, broadcast} = MOQX.publish(publisher, broadcast_path)
        {:ok, track} = MOQX.create_track(broadcast, track_name)

        :ok = MOQX.subscribe(subscriber, broadcast_path, track_name)
        :ok = MOQX.write_frame(track, "hello")
        :ok = MOQX.finish_track(track)

        await_subscribed!(broadcast_path, track_name)
        await_frame!(0, "hello")
        await_track_ended!()
      end)
    end

    test "multiple frames on one track increment group sequence", %{relay_url: url} do
      with_sessions(url, fn publisher, subscriber ->
        broadcast_path = "anon/multi-frame"
        track_name = "video"

        {:ok, broadcast} = MOQX.publish(publisher, broadcast_path)
        {:ok, track} = MOQX.create_track(broadcast, track_name)

        :ok = MOQX.subscribe(subscriber, broadcast_path, track_name)
        :ok = MOQX.write_frame(track, "frame-1")

        await_subscribed!(broadcast_path, track_name)
        await_frame!(0, "frame-1")

        :ok = MOQX.write_frame(track, "frame-2")
        await_frame!(1, "frame-2")

        :ok = MOQX.write_frame(track, "frame-3")
        await_frame!(2, "frame-3")

        :ok = MOQX.finish_track(track)
        await_track_ended!()
      end)
    end

    test "multiple tracks can be published within one broadcast", %{relay_url: url} do
      with_sessions(url, fn publisher, subscriber ->
        broadcast_path = "anon/multi-track"

        {:ok, broadcast} = MOQX.publish(publisher, broadcast_path)
        {:ok, audio_track} = MOQX.create_track(broadcast, "audio")
        {:ok, video_track} = MOQX.create_track(broadcast, "video")

        :ok = MOQX.subscribe(subscriber, broadcast_path, "audio")
        :ok = MOQX.write_frame(audio_track, "audio-1")
        :ok = MOQX.finish_track(audio_track)

        await_subscribed!(broadcast_path, "audio")
        await_frame!(0, "audio-1")
        await_track_ended!()

        drain_mailbox()

        :ok = MOQX.subscribe(subscriber, broadcast_path, "video")
        :ok = MOQX.write_frame(video_track, "video-1")
        :ok = MOQX.finish_track(video_track)

        await_subscribed!(broadcast_path, "video")
        await_frame!(0, "video-1")
        await_track_ended!()
      end)
    end

    test "subscriber can subscribe before publisher writes the first frame", %{relay_url: url} do
      with_sessions(url, fn publisher, subscriber ->
        broadcast_path = "anon/subscribe-first"
        track_name = "video"

        {:ok, broadcast} = MOQX.publish(publisher, broadcast_path)
        {:ok, track} = MOQX.create_track(broadcast, track_name)

        :ok = MOQX.subscribe(subscriber, broadcast_path, track_name)
        Process.sleep(100)
        :ok = MOQX.write_frame(track, "hello")
        :ok = MOQX.finish_track(track)

        await_subscribed!(broadcast_path, track_name)
        await_frame!(0, "hello")
        await_track_ended!()
      end)
    end
  end

  describe "public API guardrails" do
    test "session roles are explicit and split by architecture", %{relay_url: url} do
      publisher = connect_publisher!(url)
      subscriber = connect_subscriber!(url)

      assert MOQX.session_role(publisher) == :publisher
      assert MOQX.session_role(subscriber) == :subscriber

      :ok = MOQX.close(publisher)
      :ok = MOQX.close(subscriber)
    end

    test "publish rejects subscriber sessions", %{relay_url: url} do
      subscriber = connect_subscriber!(url)

      assert {:error, reason} = MOQX.publish(subscriber, "anon/wrong-role")
      assert reason =~ "publish requires a publisher session"

      :ok = MOQX.close(subscriber)
    end

    test "subscribe rejects publisher sessions", %{relay_url: url} do
      publisher = connect_publisher!(url)

      assert {:error, reason} = MOQX.subscribe(publisher, "anon/wrong-role", "video")
      assert reason =~ "subscribe requires a subscriber session"

      :ok = MOQX.close(publisher)
    end
  end

  describe "out-of-scope upstream cases remain placeholders" do
    for name <- [
          "quinn_raw_quic",
          "quiche_raw_quic",
          "quiche_webtransport",
          "iroh_connect",
          "noq_raw_quic",
          "noq_webtransport",
          "broadcast_websocket",
          "broadcast_websocket_fallback",
          "version_moq_lite_01",
          "version_moq_lite_02",
          "version_moq_lite_03",
          "version_moq_transport_14",
          "version_moq_transport_15",
          "version_moq_transport_16",
          "webtransport_moq_lite_01",
          "webtransport_moq_lite_02",
          "webtransport_moq_lite_03",
          "webtransport_moq_transport_14",
          "webtransport_moq_transport_15",
          "webtransport_moq_transport_16"
        ] do
      @tag skip: "placeholder for unsupported Bucket 2+ transport/backend/version work"
      test name do
        :ok
      end
    end
  end
end
