defmodule MOQXIntegrationTest do
  use ExUnit.Case, async: false

  alias MOQX.Debug

  @timeout 15_000

  # Integration relay tests can use MOQX_EXTERNAL_RELAY_URL,
  # or default to https://ord.abr.moqtail.dev.

  defp relay_url do
    System.get_env("MOQX_EXTERNAL_RELAY_URL", "https://ord.abr.moqtail.dev")
  end

  defp relay_namespace do
    System.get_env("MOQX_EXTERNAL_RELAY_NAMESPACE", "moqtail")
  end

  defp await_connect_result! do
    receive do
      {:moqx_connected, session} -> {:ok, session}
      {:error, reason} -> {:error, reason}
    after
      @timeout -> raise "connect timeout"
    end
  end

  defp connect_subscriber! do
    :ok = MOQX.connect_subscriber(relay_url())

    case await_connect_result!() do
      {:ok, session} -> session
      {:error, reason} -> raise "subscriber connect failed: #{inspect(reason)}"
    end
  end

  defp connect_publisher! do
    :ok = MOQX.connect_publisher(relay_url())

    case await_connect_result!() do
      {:ok, session} -> session
      {:error, reason} -> raise "publisher connect failed: #{inspect(reason)}"
    end
  end

  defp await_subscribed!(sub_ref, namespace, track_name) do
    receive do
      {:moqx_subscribed, ^sub_ref, ^namespace, ^track_name} -> :ok
      {:moqx_error, ^sub_ref, reason} -> flunk("subscribe failed: #{inspect(reason)}")
    after
      @timeout -> flunk("subscribe timeout for #{namespace}/#{track_name}")
    end
  end

  defp subscribe_with_retry!(subscriber, namespace, track_name, timeout \\ @timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    subscribe_with_retry_loop(subscriber, namespace, track_name, deadline)
  end

  defp subscribe_with_retry_loop(subscriber, namespace, track_name, deadline) do
    {:ok, sub_ref} = MOQX.subscribe(subscriber, namespace, track_name)

    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("subscribe timeout for #{namespace}/#{track_name}")
    else
      receive do
        {:moqx_subscribed, ^sub_ref, ^namespace, ^track_name} ->
          :ok

        {:moqx_error, ^sub_ref, reason} ->
          if String.contains?(reason, "Unknown track namespace") do
            Process.sleep(100)
            subscribe_with_retry_loop(subscriber, namespace, track_name, deadline)
          else
            flunk("subscribe failed: #{inspect(reason)}")
          end
      after
        min(1_000, remaining) ->
          subscribe_with_retry_loop(subscriber, namespace, track_name, deadline)
      end
    end
  end

  defp await_frame! do
    receive do
      {:moqx_frame, _sub_ref, group_id, payload} -> {group_id, payload}
      {:moqx_error, _sub_ref, reason} -> flunk("frame receive failed: #{inspect(reason)}")
    after
      @timeout -> flunk("frame timeout")
    end
  end

  describe "integration relay: connect" do
    @tag :integration
    test "subscriber connects and reports draft-14 version" do
      subscriber = connect_subscriber!()

      try do
        assert MOQX.session_version(subscriber) =~ "moq-transport-14"
        assert MOQX.session_role(subscriber) == :subscriber
      after
        :ok = MOQX.close(subscriber)
      end
    end

    @tag :integration
    test "publisher connects" do
      publisher = connect_publisher!()

      try do
        assert MOQX.session_role(publisher) == :publisher
      after
        :ok = MOQX.close(publisher)
      end
    end
  end

  describe "integration relay: subscribe" do
    @tag :public_relay_live
    test "subscribe to catalog track delivers a valid CMSF catalog" do
      subscriber = connect_subscriber!()

      try do
        ns = relay_namespace()
        {:ok, sub_ref} = MOQX.subscribe(subscriber, ns, "catalog")
        await_subscribed!(sub_ref, ns, "catalog")

        {_group_id, payload} = await_frame!()
        assert byte_size(payload) > 0

        assert {:ok, catalog} = MOQX.Catalog.decode(payload)
        assert MOQX.Catalog.tracks(catalog) != []
      after
        :ok = MOQX.close(subscriber)
      end
    end

    @tag :public_relay_live
    test "subscribe/4 accepts delivery_timeout_ms and still receives catalog" do
      subscriber = connect_subscriber!()

      try do
        ns = relay_namespace()

        {:ok, sub_ref} = MOQX.subscribe(subscriber, ns, "catalog", delivery_timeout_ms: 1_500)
        await_subscribed!(sub_ref, ns, "catalog")

        {_group_id, payload} = await_frame!()
        assert byte_size(payload) > 0

        assert {:ok, catalog} = MOQX.Catalog.decode(payload)
        assert MOQX.Catalog.tracks(catalog) != []
      after
        :ok = MOQX.close(subscriber)
      end
    end

    @tag :public_relay_live
    test "subscribe to a video track delivers live frames" do
      subscriber = connect_subscriber!()

      try do
        ns = relay_namespace()

        # First get the catalog to discover tracks
        {:ok, sub_ref} = MOQX.subscribe(subscriber, ns, "catalog")
        await_subscribed!(sub_ref, ns, "catalog")

        {_gid, catalog_payload} = await_frame!()
        {:ok, catalog} = MOQX.Catalog.decode(catalog_payload)

        video = MOQX.Catalog.video_tracks(catalog) |> List.first()
        assert video, "expected at least one video track in catalog"

        # Subscribe to the video track
        {:ok, sub_ref} = MOQX.subscribe(subscriber, ns, video.name)
        await_subscribed!(sub_ref, ns, video.name)

        # Receive at least 3 video frames
        for _ <- 1..3 do
          {group_id, payload} = await_frame!()
          assert is_integer(group_id)
          assert byte_size(payload) > 0
        end
      after
        :ok = MOQX.close(subscriber)
      end
    end

    @tag :public_relay_live
    test "video frames expose PRFT for latency estimation" do
      subscriber = connect_subscriber!()

      try do
        ns = relay_namespace()

        # Discover one video track from the catalog
        {:ok, sub_ref} = MOQX.subscribe(subscriber, ns, "catalog")
        await_subscribed!(sub_ref, ns, "catalog")

        {_gid, catalog_payload} = await_frame!()
        {:ok, catalog} = MOQX.Catalog.decode(catalog_payload)

        video = MOQX.Catalog.video_tracks(catalog) |> List.first()
        assert video, "expected at least one video track in catalog"

        {:ok, sub_ref} = MOQX.subscribe(subscriber, ns, video.name)
        await_subscribed!(sub_ref, ns, video.name)

        {_group_id, payload} = await_frame!()

        boxes = Debug.top_level_boxes(payload)
        assert Enum.any?(boxes, &(&1.type == "prft"))

        assert {:ok, prft} = Debug.parse_prft(payload)
        assert prft.version in [0, 1]

        assert {:ok, age_ms} = Debug.publisher_age_ms(payload)
        assert age_ms >= 0
        assert age_ms < 60_000
      after
        :ok = MOQX.close(subscriber)
      end
    end

    @tag :public_relay_live
    test "multiple concurrent subscriptions deliver interleaved frames" do
      subscriber = connect_subscriber!()

      try do
        ns = relay_namespace()

        # Subscribe to catalog
        {:ok, sub_ref} = MOQX.subscribe(subscriber, ns, "catalog")
        await_subscribed!(sub_ref, ns, "catalog")
        {_gid, catalog_payload} = await_frame!()
        {:ok, catalog} = MOQX.Catalog.decode(catalog_payload)

        video = MOQX.Catalog.video_tracks(catalog) |> List.first()
        assert video

        # Subscribe to video (catalog subscription is still active)
        {:ok, sub_ref} = MOQX.subscribe(subscriber, ns, video.name)
        await_subscribed!(sub_ref, ns, video.name)

        # Collect frames for a few seconds — we should see frames from
        # both subscriptions (catalog updates + video)
        frames = collect_frames(3_000)
        frame_count = length(frames)

        assert frame_count > 3,
               "expected multiple frames from concurrent subscriptions, got #{frame_count}"
      after
        :ok = MOQX.close(subscriber)
      end
    end
  end

  describe "integration relay: pub/sub e2e" do
    @tag :integration
    test "publisher frame is received by subscriber on same relay" do
      publisher = connect_publisher!()
      subscriber = connect_subscriber!()

      try do
        ns = "moqx-e2e-#{System.system_time(:millisecond)}"
        track_name = "demo"
        payload = "hello-from-moqx-integration"

        {:ok, broadcast} = MOQX.publish(publisher, ns)
        {:ok, track} = MOQX.create_track(broadcast, track_name)

        subscribe_with_retry!(subscriber, ns, track_name)

        :ok = MOQX.write_frame(track, payload)

        {group_id, got_payload} = await_matching_payload_frame!(payload)
        assert is_integer(group_id)
        assert got_payload == payload

        :ok = MOQX.finish_track(track)
      after
        :ok = MOQX.close(subscriber)
        :ok = MOQX.close(publisher)
      end
    end

    @tag :integration
    test "publisher catalog helper is relayed downstream" do
      publisher = connect_publisher!()
      subscriber = connect_subscriber!()

      try do
        ns = "moqx-e2e-catalog-#{System.system_time(:millisecond)}"
        media_track_name = "demo"
        media_payload = "hello-media"

        catalog_payload =
          ~s({"version":1,"supportsDeltaUpdates":false,"tracks":[{"name":"#{media_track_name}","role":"video","codec":"avc1.42C01F","packaging":"cmaf"}]})

        {:ok, broadcast} = MOQX.publish(publisher, ns)
        {:ok, catalog_track} = MOQX.publish_catalog(broadcast, catalog_payload)
        {:ok, media_track} = MOQX.create_track(broadcast, media_track_name)

        subscribe_with_retry!(subscriber, ns, "catalog")
        subscribe_with_retry!(subscriber, ns, media_track_name)

        :ok = MOQX.update_catalog(catalog_track, catalog_payload)
        :ok = MOQX.write_frame(media_track, media_payload)

        {_catalog_group_id, got_catalog_payload} = await_matching_payload_frame!(catalog_payload)
        assert {:ok, catalog} = MOQX.Catalog.decode(got_catalog_payload)

        assert %MOQX.Catalog.Track{name: ^media_track_name} =
                 MOQX.Catalog.get_track(catalog, media_track_name)

        {_media_group_id, got_media_payload} = await_matching_payload_frame!(media_payload)
        assert got_media_payload == media_payload

        :ok = MOQX.finish_track(media_track)
      after
        :ok = MOQX.close(subscriber)
        :ok = MOQX.close(publisher)
      end
    end
  end

  describe "integration relay: role guardrails" do
    @tag :integration
    test "publish rejects subscriber sessions" do
      subscriber = connect_subscriber!()

      try do
        assert {:error, reason} = MOQX.publish(subscriber, "test")
        assert reason =~ "publish requires a publisher session"
      after
        :ok = MOQX.close(subscriber)
      end
    end

    @tag :integration
    test "subscribe rejects publisher sessions" do
      publisher = connect_publisher!()

      try do
        assert {:error, reason} = MOQX.subscribe(publisher, "test", "track")
        assert reason =~ "subscribe requires a subscriber session"
      after
        :ok = MOQX.close(publisher)
      end
    end

    @tag :integration
    test "fetch rejects publisher sessions" do
      publisher = connect_publisher!()

      try do
        assert {:error, "fetch requires a subscriber session"} =
                 MOQX.fetch(publisher, "moqtail", "catalog", [])
      after
        :ok = MOQX.close(publisher)
      end
    end

    @tag :integration
    test "fetch_catalog rejects publisher sessions" do
      publisher = connect_publisher!()

      try do
        assert {:error, "fetch requires a subscriber session"} = MOQX.fetch_catalog(publisher)
      after
        :ok = MOQX.close(publisher)
      end
    end
  end

  describe "integration relay: catalog-driven flow" do
    @tag :public_relay_live
    test "full catalog-driven subscribe: connect, catalog, decode, subscribe video" do
      subscriber = connect_subscriber!()

      try do
        ns = relay_namespace()

        # Subscribe to catalog
        {:ok, sub_ref} = MOQX.subscribe(subscriber, ns, "catalog")
        await_subscribed!(sub_ref, ns, "catalog")

        # Get and decode catalog
        {_gid, payload} = await_frame!()
        {:ok, catalog} = MOQX.Catalog.decode(payload)

        # Verify catalog structure
        tracks = MOQX.Catalog.tracks(catalog)
        assert tracks != []

        video_tracks = MOQX.Catalog.video_tracks(catalog)
        assert video_tracks != []

        video = List.first(video_tracks)
        assert video.name
        assert video.role == "video"
        assert video.codec

        # Subscribe to discovered video track
        {:ok, sub_ref} = MOQX.subscribe(subscriber, ns, video.name)
        await_subscribed!(sub_ref, ns, video.name)

        # Verify we get actual video data
        {group_id, frame} = await_frame!()
        assert is_integer(group_id)
        # First frame in a group is typically a keyframe (large)
        assert byte_size(frame) > 100
      after
        :ok = MOQX.close(subscriber)
      end
    end
  end

  # -- Helpers ----------------------------------------------------------------

  defp await_matching_payload_frame!(expected_payload, timeout \\ @timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_matching_payload_frame_loop(expected_payload, deadline)
  end

  defp await_matching_payload_frame_loop(expected_payload, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("frame timeout waiting for payload #{inspect(expected_payload)}")
    else
      receive do
        {:moqx_frame, _sub_ref, group_id, payload} when payload == expected_payload ->
          {group_id, payload}

        {:moqx_frame, _sub_ref, _group_id, _payload} ->
          await_matching_payload_frame_loop(expected_payload, deadline)

        {:moqx_error, _sub_ref, reason} ->
          flunk("frame receive failed: #{inspect(reason)}")
      after
        remaining ->
          flunk("frame timeout waiting for payload #{inspect(expected_payload)}")
      end
    end
  end

  defp collect_frames(duration_ms) do
    deadline = System.monotonic_time(:millisecond) + duration_ms
    collect_frames_loop(deadline, [])
  end

  defp collect_frames_loop(deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {:moqx_frame, _sub_ref, group_id, payload} ->
          collect_frames_loop(deadline, [{group_id, payload} | acc])

        {:moqx_subscribed, _sub_ref, _, _} ->
          collect_frames_loop(deadline, acc)

        _ ->
          collect_frames_loop(deadline, acc)
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end
end
