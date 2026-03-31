defmodule MOQXIntegrationTest do
  use ExUnit.Case, async: false

  alias MOQX.Test.{Auth, Relay}

  @moduletag :integration
  @timeout 10_000

  setup_all do
    relay = Relay.start()
    on_exit(fn -> Relay.stop(relay) end)

    %{
      relay_url: Relay.url(),
      relay_websocket_url: Relay.websocket_url(),
      local_dev_tls: [tls: [verify: :insecure]]
    }
  end

  defp await_connect_result! do
    receive do
      {:moqx_connected, session} -> {:ok, session}
      {:error, reason} -> {:error, reason}
    after
      @timeout -> raise "connect timeout"
    end
  end

  defp connect_publisher!(url, opts) do
    :ok = MOQX.connect_publisher(url, opts)

    case await_connect_result!() do
      {:ok, session} -> session
      {:error, reason} -> raise "publisher connect failed: #{inspect(reason)}"
    end
  end

  defp connect_subscriber!(url, opts) do
    :ok = MOQX.connect_subscriber(url, opts)

    case await_connect_result!() do
      {:ok, session} -> session
      {:error, reason} -> raise "subscriber connect failed: #{inspect(reason)}"
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
      {port, _message} when is_port(port) -> await_subscribed!(broadcast_path, track_name)
    after
      @timeout -> flunk("subscribe timeout")
    end
  end

  defp await_frame!(expected_group_seq, expected_payload) do
    receive do
      {:moqx_frame, ^expected_group_seq, ^expected_payload} -> :ok
      {:moqx_error, reason} -> flunk("frame receive failed: #{inspect(reason)}")
      {port, _message} when is_port(port) -> await_frame!(expected_group_seq, expected_payload)
      other -> flunk("unexpected message while waiting for frame: #{inspect(other)}")
    after
      @timeout -> flunk("frame timeout")
    end
  end

  defp await_track_ended! do
    receive do
      :moqx_track_ended -> :ok
      {:moqx_error, reason} -> flunk("track ended with error: #{inspect(reason)}")
      {port, _message} when is_port(port) -> await_track_ended!()
      other -> flunk("unexpected message while waiting for track end: #{inspect(other)}")
    after
      @timeout -> flunk("track end timeout")
    end
  end

  defp with_sessions(url, opts, fun) do
    publisher = connect_publisher!(url, opts)
    subscriber = connect_subscriber!(url, opts)

    try do
      fun.(publisher, subscriber)
    after
      :ok = MOQX.close(publisher)
      :ok = MOQX.close(subscriber)
    end
  end

  defp with_isolated_fallback_relay(fun) do
    relay = Relay.start_isolated(4544, 4545)
    drain_port_messages(relay)

    try do
      fun.(Relay.websocket_fallback_url())
    after
      Relay.stop(relay)
    end
  end

  defp with_isolated_trusted_relay(fun) do
    relay = Relay.start_isolated_trusted(4546, 4547)
    drain_port_messages(relay)

    try do
      fun.("https://localhost:4546", Relay.trusted_root_ca())
    after
      Relay.stop(relay)
    end
  end

  defp with_isolated_trusted_auth_relay(fun) do
    relay = Relay.start_isolated_trusted_auth(4548, 4549)
    drain_port_messages(relay)

    try do
      fun.("https://localhost:4548", Relay.trusted_root_ca())
    after
      Relay.stop(relay)
    end
  end

  defp drain_port_messages(port) do
    receive do
      {^port, _message} -> drain_port_messages(port)
    after
      0 -> :ok
    end
  end

  defp auth_url(base_url, root, claims) do
    jwt = Auth.token(Keyword.put(claims, :root, root))
    Auth.connect_url(base_url, root, jwt)
  end

  defp await_error!(timeout \\ @timeout) do
    receive do
      {:error, reason} -> reason
      {:moqx_error, reason} -> reason
      {port, _message} when is_port(port) -> await_error!(timeout)
      other -> flunk("unexpected message while waiting for error: #{inspect(other)}")
    after
      timeout -> flunk("error timeout")
    end
  end

  describe "current supported architecture" do
    test "single-frame relay-backed round trip", %{relay_url: url, local_dev_tls: tls_opts} do
      with_sessions(url, tls_opts, fn publisher, subscriber ->
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

    test "multiple frames on one track increment group sequence", %{
      relay_url: url,
      local_dev_tls: tls_opts
    } do
      with_sessions(url, tls_opts, fn publisher, subscriber ->
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

    test "multiple tracks can be published within one broadcast", %{
      relay_url: url,
      local_dev_tls: tls_opts
    } do
      with_sessions(url, tls_opts, fn publisher, subscriber ->
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

    test "subscriber can subscribe before publisher writes the first frame", %{
      relay_url: url,
      local_dev_tls: tls_opts
    } do
      with_sessions(url, tls_opts, fn publisher, subscriber ->
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
    test "session roles are explicit and split by architecture", %{
      relay_url: url,
      local_dev_tls: tls_opts
    } do
      publisher = connect_publisher!(url, tls_opts)
      subscriber = connect_subscriber!(url, tls_opts)

      assert MOQX.session_role(publisher) == :publisher
      assert MOQX.session_role(subscriber) == :subscriber

      :ok = MOQX.close(publisher)
      :ok = MOQX.close(subscriber)
    end

    test "publish rejects subscriber sessions", %{relay_url: url, local_dev_tls: tls_opts} do
      subscriber = connect_subscriber!(url, tls_opts)

      assert {:error, reason} = MOQX.publish(subscriber, "anon/wrong-role")
      assert reason =~ "publish requires a publisher session"

      :ok = MOQX.close(subscriber)
    end

    test "subscribe rejects publisher sessions", %{relay_url: url, local_dev_tls: tls_opts} do
      publisher = connect_publisher!(url, tls_opts)

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

    test "quinn_raw_quic", %{relay_url: url, local_dev_tls: tls_opts} do
      with_sessions(url, tls_opts ++ [backend: :quinn, transport: :raw_quic], fn publisher,
                                                                                 subscriber ->
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

    test "websocket_connect", %{relay_websocket_url: url, local_dev_tls: tls_opts} do
      with_sessions(url, tls_opts ++ [transport: :websocket], fn publisher, subscriber ->
        assert MOQX.session_version(publisher) == "moq-lite-02"
        assert MOQX.session_version(subscriber) == "moq-lite-02"
      end)
    end

    test "broadcast_websocket", %{relay_websocket_url: url, local_dev_tls: tls_opts} do
      with_sessions(url, tls_opts ++ [transport: :websocket], fn publisher, subscriber ->
        assert MOQX.session_version(publisher) == "moq-lite-02"
        assert MOQX.session_version(subscriber) == "moq-lite-02"

        broadcast_path = "anon/broadcast-websocket"
        track_name = "video"

        {:ok, broadcast} = MOQX.publish(publisher, broadcast_path)
        {:ok, track} = MOQX.create_track(broadcast, track_name)

        :ok = MOQX.subscribe(subscriber, broadcast_path, track_name)
        :ok = MOQX.write_frame(track, "hello")
        Process.sleep(300)
        :ok = MOQX.finish_track(track)

        await_subscribed!(broadcast_path, track_name)
        await_frame!(0, "hello")
        await_track_ended!()
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

      test "version_#{version}", %{relay_url: url, local_dev_tls: tls_opts} do
        with_sessions(url, tls_opts ++ [transport: :raw_quic, version: @version], fn publisher,
                                                                                     subscriber ->
          assert MOQX.session_version(publisher) == @version
          assert MOQX.session_version(subscriber) == @version
        end)
      end

      test "webtransport_#{version}", %{relay_url: url, local_dev_tls: tls_opts} do
        with_sessions(
          url,
          tls_opts ++ [transport: :webtransport, version: @version],
          fn publisher, subscriber ->
            assert MOQX.session_version(publisher) == @version
            assert MOQX.session_version(subscriber) == @version
          end
        )
      end
    end
  end

  describe "websocket version support is relay-compatible where upstream allows it" do
    for version <- ["moq-lite-01", "moq-lite-02", "moq-transport-14"] do
      @version version

      test "websocket_#{version}", %{relay_websocket_url: url, local_dev_tls: tls_opts} do
        with_sessions(url, tls_opts ++ [transport: :websocket, version: @version], fn publisher,
                                                                                      subscriber ->
          assert MOQX.session_version(publisher) == @version
          assert MOQX.session_version(subscriber) == @version
        end)
      end
    end
  end

  describe "websocket fallback parity" do
    test "broadcast_websocket_fallback" do
      with_isolated_fallback_relay(fn url ->
        with_sessions(url, [], fn publisher, subscriber ->
          broadcast_path = "anon/broadcast-websocket-fallback"
          track_name = "video"

          {:ok, broadcast} = MOQX.publish(publisher, broadcast_path)
          {:ok, track} = MOQX.create_track(broadcast, track_name)

          :ok = MOQX.subscribe(subscriber, broadcast_path, track_name)
          :ok = MOQX.write_frame(track, "hello")
          Process.sleep(300)
          :ok = MOQX.finish_track(track)

          await_subscribed!(broadcast_path, track_name)
          await_frame!(0, "hello")
          await_track_ended!()
        end)
      end)
    end
  end

  describe "tls hardening" do
    test "verification is enabled by default against self-signed local relay", %{relay_url: url} do
      :ok = MOQX.connect_publisher(url, [])

      assert {:error, reason} = await_connect_result!()
      assert is_binary(reason)
      refute reason == ""
    end

    test "explicit insecure mode preserves local self-signed development flow", %{relay_url: url} do
      publisher = connect_publisher!(url, tls: [verify: :insecure])
      subscriber = connect_subscriber!(url, tls: [verify: :insecure])

      :ok = MOQX.close(publisher)
      :ok = MOQX.close(subscriber)
    end

    test "custom root verification succeeds with a trusted local relay" do
      with_isolated_trusted_relay(fn url, root_ca ->
        with_sessions(url, [tls: [cacertfile: root_ca]], fn publisher, subscriber ->
          assert MOQX.session_version(publisher) == "moq-lite-03"
          assert MOQX.session_version(subscriber) == "moq-lite-03"
        end)
      end)
    end
  end

  describe "authenticated relay client flows" do
    test "authenticated publisher succeeds" do
      with_isolated_trusted_auth_relay(fn base_url, root_ca ->
        url = auth_url(base_url, "room/auth-publisher", put: [""], get: [])
        publisher = connect_publisher!(url, tls: [cacertfile: root_ca])

        assert MOQX.session_role(publisher) == :publisher
        assert {:ok, broadcast} = MOQX.publish(publisher, "stream")
        assert {:ok, track} = MOQX.create_track(broadcast, "video")
        assert :ok = MOQX.write_frame(track, "hello")
        assert :ok = MOQX.finish_track(track)

        :ok = MOQX.close(publisher)
      end)
    end

    test "authenticated subscriber succeeds" do
      with_isolated_trusted_auth_relay(fn base_url, root_ca ->
        tls_opts = [tls: [cacertfile: root_ca]]
        root = "room/auth-subscriber"
        publisher_url = auth_url(base_url, root, put: [""], get: [])
        subscriber_url = auth_url(base_url, root, put: [], get: [""])

        publisher = connect_publisher!(publisher_url, tls_opts)
        subscriber = connect_subscriber!(subscriber_url, tls_opts)

        try do
          assert MOQX.session_role(subscriber) == :subscriber

          {:ok, broadcast} = MOQX.publish(publisher, "stream")
          {:ok, track} = MOQX.create_track(broadcast, "video")

          :ok = MOQX.subscribe(subscriber, "stream", "video")
          :ok = MOQX.write_frame(track, "hello")
          :ok = MOQX.finish_track(track)

          await_subscribed!("stream", "video")
          await_frame!(0, "hello")
          await_track_ended!()
        after
          :ok = MOQX.close(publisher)
          :ok = MOQX.close(subscriber)
        end
      end)
    end

    test "authenticated end-to-end pub/sub succeeds" do
      with_isolated_trusted_auth_relay(fn base_url, root_ca ->
        tls_opts = [tls: [cacertfile: root_ca]]
        root = "room/end-to-end"
        publisher_url = auth_url(base_url, root, put: [""], get: [])
        subscriber_url = auth_url(base_url, root, put: [], get: [""])

        publisher = connect_publisher!(publisher_url, tls_opts)
        subscriber = connect_subscriber!(subscriber_url, tls_opts)

        try do
          {:ok, broadcast} = MOQX.publish(publisher, "stream")
          {:ok, track} = MOQX.create_track(broadcast, "video")

          :ok = MOQX.subscribe(subscriber, "stream", "video")
          :ok = MOQX.write_frame(track, "frame-1")
          await_subscribed!("stream", "video")
          await_frame!(0, "frame-1")

          :ok = MOQX.write_frame(track, "frame-2")
          await_frame!(1, "frame-2")

          :ok = MOQX.finish_track(track)
          await_track_ended!()
        after
          :ok = MOQX.close(publisher)
          :ok = MOQX.close(subscriber)
        end
      end)
    end

    test "missing token fails" do
      with_isolated_trusted_auth_relay(fn base_url, root_ca ->
        url = Auth.connect_url(base_url, "room/missing-token")

        :ok = MOQX.connect_publisher(url, tls: [cacertfile: root_ca])
        reason = await_error!()

        assert is_binary(reason)
        refute reason == ""
      end)
    end

    test "publish-only token cannot subscribe" do
      with_isolated_trusted_auth_relay(fn base_url, root_ca ->
        tls_opts = [tls: [cacertfile: root_ca]]
        root = "room/publish-only"
        publisher_url = auth_url(base_url, root, put: [""], get: [])
        subscriber_url = auth_url(base_url, root, put: [""], get: [])

        publisher = connect_publisher!(publisher_url, tls_opts)

        try do
          :ok = MOQX.connect_subscriber(subscriber_url, tls_opts)

          case await_connect_result!() do
            {:error, reason} ->
              assert is_binary(reason)
              refute reason == ""

            {:ok, subscriber} ->
              try do
                {:ok, broadcast} = MOQX.publish(publisher, "stream")
                {:ok, track} = MOQX.create_track(broadcast, "video")

                :ok = MOQX.subscribe(subscriber, "stream", "video")
                :ok = MOQX.write_frame(track, "hello")
                :ok = MOQX.finish_track(track)

                refute_receive {:moqx_subscribed, "stream", "video"}, 1_000
                refute_receive {:moqx_frame, _, _}, 200
                refute_receive :moqx_track_ended, 200
              after
                :ok = MOQX.close(subscriber)
              end
          end
        after
          :ok = MOQX.close(publisher)
        end
      end)
    end

    test "subscribe-only token cannot publish" do
      with_isolated_trusted_auth_relay(fn base_url, root_ca ->
        tls_opts = [tls: [cacertfile: root_ca]]
        root = "room/subscribe-only"
        publisher_url = auth_url(base_url, root, put: [], get: [""])
        subscriber_url = auth_url(base_url, root, put: [], get: [""])

        subscriber = connect_subscriber!(subscriber_url, tls_opts)

        try do
          :ok = MOQX.subscribe(subscriber, "stream", "video")
          :ok = MOQX.connect_publisher(publisher_url, tls_opts)

          case await_connect_result!() do
            {:error, reason} ->
              assert is_binary(reason)
              refute reason == ""

            {:ok, publisher} ->
              try do
                {:ok, broadcast} = MOQX.publish(publisher, "stream")
                {:ok, track} = MOQX.create_track(broadcast, "video")
                :ok = MOQX.write_frame(track, "hello")
                :ok = MOQX.finish_track(track)

                refute_receive {:moqx_subscribed, "stream", "video"}, 1_000
                refute_receive {:moqx_frame, _, _}, 200
                refute_receive :moqx_track_ended, 200
              after
                :ok = MOQX.close(publisher)
              end
          end
        after
          :ok = MOQX.close(subscriber)
        end
      end)
    end

    test "rooted auth normalizes publish paths that repeat the connect root" do
      with_isolated_trusted_auth_relay(fn base_url, root_ca ->
        tls_opts = [tls: [cacertfile: root_ca]]
        root = "room/rooted-publish"
        publisher_url = auth_url(base_url, root, put: [""], get: [])
        subscriber_url = auth_url(base_url, root, put: [], get: [""])

        publisher = connect_publisher!(publisher_url, tls_opts)
        subscriber = connect_subscriber!(subscriber_url, tls_opts)

        try do
          {:ok, broadcast} = MOQX.publish(publisher, "/room/rooted-publish/stream/")
          {:ok, track} = MOQX.create_track(broadcast, "video")

          :ok = MOQX.subscribe(subscriber, "stream", "video")
          :ok = MOQX.write_frame(track, "hello")
          :ok = MOQX.finish_track(track)

          await_subscribed!("stream", "video")
          await_frame!(0, "hello")
          await_track_ended!()
        after
          :ok = MOQX.close(publisher)
          :ok = MOQX.close(subscriber)
        end
      end)
    end

    test "rooted auth normalizes subscribe paths that repeat the connect root" do
      with_isolated_trusted_auth_relay(fn base_url, root_ca ->
        tls_opts = [tls: [cacertfile: root_ca]]
        root = "room/rooted-subscribe"
        publisher_url = auth_url(base_url, root, put: [""], get: [])
        subscriber_url = auth_url(base_url, root, put: [], get: [""])

        publisher = connect_publisher!(publisher_url, tls_opts)
        subscriber = connect_subscriber!(subscriber_url, tls_opts)

        try do
          {:ok, broadcast} = MOQX.publish(publisher, "stream")
          {:ok, track} = MOQX.create_track(broadcast, "video")

          :ok = MOQX.subscribe(subscriber, "/room/rooted-subscribe/stream/", "video")
          :ok = MOQX.write_frame(track, "hello")
          :ok = MOQX.finish_track(track)

          await_subscribed!("/room/rooted-subscribe/stream/", "video")
          await_frame!(0, "hello")
          await_track_ended!()
        after
          :ok = MOQX.close(publisher)
          :ok = MOQX.close(subscriber)
        end
      end)
    end

    test "wrong-root token fails" do
      with_isolated_trusted_auth_relay(fn base_url, root_ca ->
        jwt = Auth.token(root: "room/correct-root", put: [""], get: [""])
        url = Auth.connect_url(base_url, "room/wrong-root", jwt)

        :ok = MOQX.connect_subscriber(url, tls: [cacertfile: root_ca])
        reason = await_error!()

        assert is_binary(reason)
        refute reason == ""
      end)
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
  end
end
