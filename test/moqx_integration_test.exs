defmodule MOQXIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @timeout 10_000

  setup_all do
    relay = MOQX.Test.Relay.start()
    on_exit(fn -> MOQX.Test.Relay.stop(relay) end)

    %{
      relay_url: MOQX.Test.Relay.url(),
      relay_websocket_url: MOQX.Test.Relay.websocket_url()
    }
  end

  defp connect_publisher!(url, opts \\ []) do
    :ok = MOQX.connect_publisher(url, opts)

    receive do
      {:moqx_connected, session} -> session
      {:error, reason} -> raise "publisher connect failed: #{inspect(reason)}"
    after
      @timeout -> raise "publisher connect timeout"
    end
  end

  defp connect_subscriber!(url, opts \\ []) do
    :ok = MOQX.connect_subscriber(url, opts)

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

  defp with_sessions(url, opts \\ [], fun) do
    publisher = connect_publisher!(url, opts)
    subscriber = connect_subscriber!(url, opts)

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

  describe "upstream parity: backend, transport, and version matrix" do
    test "reports compiled native support" do
      assert MOQX.supported_backends() == [:quinn]
      assert :raw_quic in MOQX.supported_transports()
      assert :webtransport in MOQX.supported_transports()
      assert :websocket in MOQX.supported_transports()
    end

    test "quinn_raw_quic", %{relay_url: url} do
      with_sessions(url, [backend: :quinn, transport: :raw_quic], fn publisher, subscriber ->
        assert MOQX.session_version(publisher) == "moq-lite-03"
        assert MOQX.session_version(subscriber) == "moq-lite-03"

        broadcast_path = "anon/quinn-raw-quic"
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

    test "websocket_connect", %{relay_websocket_url: url} do
      with_sessions(url, [transport: :websocket], fn publisher, subscriber ->
        assert MOQX.session_version(publisher) == "moq-lite-02"
        assert MOQX.session_version(subscriber) == "moq-lite-02"
      end)
    end

    for version <- [
          "moq-lite-01",
          "moq-lite-02",
          "moq-lite-03",
          "moq-transport-14",
          "moq-transport-15",
          "moq-transport-16"
        ] do
      @version version

      test "version_#{version}", %{relay_url: url} do
        with_sessions(url, [transport: :raw_quic, version: @version], fn publisher, subscriber ->
          assert MOQX.session_version(publisher) == @version
          assert MOQX.session_version(subscriber) == @version
        end)
      end

      test "webtransport_#{version}", %{relay_url: url} do
        with_sessions(url, [transport: :webtransport, version: @version], fn publisher,
                                                                             subscriber ->
          assert MOQX.session_version(publisher) == @version
          assert MOQX.session_version(subscriber) == @version
        end)
      end
    end
  end

  describe "websocket version support is relay-compatible where upstream allows it" do
    for version <- ["moq-lite-01", "moq-lite-02", "moq-transport-14"] do
      @version version

      test "websocket_#{version}", %{relay_websocket_url: url} do
        with_sessions(url, [transport: :websocket, version: @version], fn publisher, subscriber ->
          assert MOQX.session_version(publisher) == @version
          assert MOQX.session_version(subscriber) == @version
        end)
      end
    end
  end

  describe "not planned upstream matrix cases" do
    for name <- [
          "quiche_raw_quic",
          "quiche_webtransport",
          "iroh_connect",
          "noq_raw_quic",
          "noq_webtransport"
        ] do
      @tag skip: "not planned: moqx intentionally supports the quinn backend only"
      test name do
        :ok
      end
    end

    @tag skip:
           "not planned yet: relay-backed direct WebSocket data-path parity is still incomplete"
    test "broadcast_websocket" do
      :ok
    end

    @tag skip:
           "not planned yet: direct WebSocket fallback racing is not covered by the relay-backed test harness"
    test "broadcast_websocket_fallback" do
      :ok
    end
  end
end
