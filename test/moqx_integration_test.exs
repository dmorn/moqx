defmodule MOQXIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :ported_upstream
  @timeout 10_000

  setup_all do
    relay = MOQX.Test.Relay.start()
    on_exit(fn -> MOQX.Test.Relay.stop(relay) end)
    %{relay_url: MOQX.Test.Relay.url()}
  end

  defp connect!(url, opts \\ []) do
    :ok = MOQX.connect(url, opts)

    receive do
      {:moqx_connected, session} -> session
      {:error, reason} -> raise "connect failed: #{inspect(reason)}"
    after
      @timeout -> raise "connect timeout"
    end
  end

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  defp canonical_roundtrip!(url, opts \\ []) do
    drain_mailbox()

    broadcast_path = Keyword.get(opts, :broadcast_path, "anon/test")
    track_name = Keyword.get(opts, :track_name, "video")
    payload = Keyword.get(opts, :payload, "hello")
    finish_track? = Keyword.get(opts, :finish_track?, true)

    :ok = MOQX.connect_publisher(url)

    pub_session =
      receive do
        {:moqx_connected, session} -> session
        {:error, reason} -> raise "connect failed: #{inspect(reason)}"
      after
        @timeout -> raise "connect timeout"
      end

    {:ok, broadcast} = MOQX.publish(pub_session, broadcast_path)
    {:ok, track} = MOQX.create_track(broadcast, track_name)
    :ok = MOQX.write_frame(track, payload)

    :ok = MOQX.connect_subscriber(url)

    sub_session =
      receive do
        {:moqx_connected, session} -> session
        {:error, reason} -> raise "connect failed: #{inspect(reason)}"
      after
        @timeout -> raise "connect timeout"
      end

    :ok = MOQX.subscribe(sub_session, broadcast_path, track_name)

    result =
      receive do
        {:moqx_subscribed, ^broadcast_path, ^track_name} ->
          receive do
            {:moqx_frame, 0, ^payload} = msg -> {:ok, msg}
            {:moqx_error, _} = msg -> {:error, msg}
          after
            @timeout -> {:timeout, :frame}
          end

        {:moqx_error, _} = msg ->
          {:error, msg}
      after
        @timeout -> {:timeout, :subscribe}
      end

    if finish_track? do
      _ = MOQX.finish_track(track)
    end

    _ = MOQX.Native.session_close(pub_session)
    _ = MOQX.Native.session_close(sub_session)

    {result, %{broadcast: broadcast, track: track}}
  end

  defp unsupported!(feature, upstream_test) do
    flunk(
      "upstream test #{upstream_test} ported as placeholder: missing MOQX public API support for #{feature}"
    )
  end

  describe "ported from rs/moq-native/tests/backend.rs" do
    test "quinn_raw_quic", _ctx do
      unsupported!("raw QUIC / moqt:// transport selection", "quinn_raw_quic")
    end

    test "quinn_webtransport", %{relay_url: url} do
      assert match?({:ok, {:moqx_frame, 0, "hello"}}, elem(canonical_roundtrip!(url), 0))
    end

    test "quiche_raw_quic", _ctx do
      unsupported!("backend + raw QUIC selection", "quiche_raw_quic")
    end

    test "quiche_webtransport", _ctx do
      unsupported!("backend selection", "quiche_webtransport")
    end

    test "iroh_connect", _ctx do
      unsupported!("iroh endpoint configuration", "iroh_connect")
    end

    test "noq_raw_quic", _ctx do
      unsupported!("backend + raw QUIC selection", "noq_raw_quic")
    end

    test "noq_webtransport", _ctx do
      unsupported!("backend selection", "noq_webtransport")
    end
  end

  describe "session role guardrails" do
    test "session_role reports the configured role", %{relay_url: url} do
      pub_session = connect!(url, role: :publish)
      sub_session = connect!(url, role: :consume)
      both_session = connect!(url)

      assert MOQX.session_role(pub_session) == "publish"
      assert MOQX.session_role(sub_session) == "consume"
      assert MOQX.session_role(both_session) == "both"

      :ok = MOQX.Native.session_close(pub_session)
      :ok = MOQX.Native.session_close(sub_session)
      :ok = MOQX.Native.session_close(both_session)
    end

    test "publish rejects consume-only sessions", %{relay_url: url} do
      sub_session = connect!(url, role: :consume)

      assert {:error, reason} = MOQX.publish(sub_session, "anon/wrong-role")
      assert reason =~ "publish requires a publisher-capable session"

      :ok = MOQX.Native.session_close(sub_session)
    end

    test "subscribe rejects publish-only sessions", %{relay_url: url} do
      pub_session = connect!(url, role: :publish)

      assert {:error, reason} = MOQX.subscribe(pub_session, "anon/wrong-role", "video")
      assert reason =~ "subscribe requires a subscriber-capable session"

      :ok = MOQX.Native.session_close(pub_session)
    end
  end

  describe "ported from rs/moq-native/tests/broadcast.rs - cases expressible via current MOQX API" do
    test "broadcast_webtransport", %{relay_url: url} do
      assert match?({:ok, {:moqx_frame, 0, "hello"}}, elem(canonical_roundtrip!(url), 0))
    end

    test "single frame round-trip, publish-first like upstream canonical flow", %{relay_url: url} do
      assert match?({:ok, {:moqx_frame, 0, "hello"}}, elem(canonical_roundtrip!(url), 0))
    end

    test "broadcast lifetime is held until teardown", %{relay_url: url} do
      {result, refs} = canonical_roundtrip!(url, broadcast_path: "anon/test-lifetime")
      assert refs.broadcast != nil
      assert refs.track != nil
      assert match?({:ok, {:moqx_frame, 0, "hello"}}, result)
    end
  end

  describe "ported from rs/moq-native/tests/broadcast.rs - version-matrix placeholders" do
    for name <- [
          "broadcast_moq_lite_01",
          "broadcast_moq_lite_02",
          "broadcast_moq_lite_03",
          "broadcast_moq_transport_14",
          "broadcast_moq_transport_15",
          "broadcast_moq_transport_16",
          "broadcast_negotiate_server_all_client_lite_01",
          "broadcast_negotiate_server_all_client_lite_02",
          "broadcast_negotiate_server_all_client_lite_03",
          "broadcast_negotiate_server_all_client_transport_14",
          "broadcast_negotiate_server_all_client_transport_15",
          "broadcast_negotiate_server_all_client_transport_16",
          "broadcast_negotiate_client_all_server_lite_01",
          "broadcast_negotiate_client_all_server_lite_02",
          "broadcast_negotiate_client_all_server_lite_03",
          "broadcast_negotiate_client_all_server_transport_14",
          "broadcast_negotiate_client_all_server_transport_15",
          "broadcast_negotiate_client_all_server_transport_16",
          "broadcast_webtransport_moq_lite_01",
          "broadcast_webtransport_moq_lite_02",
          "broadcast_webtransport_moq_lite_03",
          "broadcast_webtransport_moq_transport_14",
          "broadcast_webtransport_moq_transport_15",
          "broadcast_webtransport_moq_transport_16",
          "broadcast_webtransport_negotiate_server_all_client_lite_01",
          "broadcast_webtransport_negotiate_server_all_client_lite_02",
          "broadcast_webtransport_negotiate_server_all_client_lite_03",
          "broadcast_webtransport_negotiate_server_all_client_transport_14",
          "broadcast_webtransport_negotiate_server_all_client_transport_15",
          "broadcast_webtransport_negotiate_server_all_client_transport_16",
          "broadcast_webtransport_negotiate_client_all_server_lite_01",
          "broadcast_webtransport_negotiate_client_all_server_lite_02",
          "broadcast_webtransport_negotiate_client_all_server_lite_03",
          "broadcast_webtransport_negotiate_client_all_server_transport_14",
          "broadcast_webtransport_negotiate_client_all_server_transport_15",
          "broadcast_webtransport_negotiate_client_all_server_transport_16"
        ] do
      test name, _ctx do
        unsupported!("client/server version pinning + negotiation controls", unquote(name))
      end
    end
  end

  describe "ported from rs/moq-native/tests/broadcast.rs - websocket placeholders" do
    test "broadcast_websocket", _ctx do
      unsupported!("websocket listener/transport selection", "broadcast_websocket")
    end

    test "broadcast_websocket_fallback", _ctx do
      unsupported!("websocket fallback controls", "broadcast_websocket_fallback")
    end
  end

  describe "ported from rs/moq-native/tests/alpn.rs" do
    for name <- [
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
      test name, _ctx do
        unsupported!("ALPN/subprotocol version forcing in public connect API", unquote(name))
      end
    end

    test "webtransport", %{relay_url: url} do
      # Closest current-API analogue: default WebTransport connection succeeds.
      session = connect!(url)
      assert is_binary(MOQX.Native.session_version(session))
      :ok = MOQX.Native.session_close(session)
    end
  end
end
