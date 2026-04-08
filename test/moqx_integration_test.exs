defmodule MOQXIntegrationTest do
  use ExUnit.Case, async: false

  alias MOQX.Debug

  @moduletag :integration
  @timeout 15_000

  # External relay tests require MOQX_EXTERNAL_RELAY_URL to be set,
  # or default to https://ord.abr.moqtail.dev.
  # These tests are excluded by default (tagged :external_relay).

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

  defp await_subscribed!(namespace, track_name) do
    receive do
      {:moqx_subscribed, ^namespace, ^track_name} -> :ok
      {:moqx_error, reason} -> flunk("subscribe failed: #{inspect(reason)}")
    after
      @timeout -> flunk("subscribe timeout for #{namespace}/#{track_name}")
    end
  end

  defp await_frame! do
    receive do
      {:moqx_frame, group_id, payload} -> {group_id, payload}
      {:moqx_error, reason} -> flunk("frame receive failed: #{inspect(reason)}")
    after
      @timeout -> flunk("frame timeout")
    end
  end

  describe "external relay: connect" do
    @describetag :external_relay

    test "subscriber connects and reports draft-14 version" do
      subscriber = connect_subscriber!()

      try do
        assert MOQX.session_version(subscriber) =~ "moq-transport-14"
        assert MOQX.session_role(subscriber) == :subscriber
      after
        :ok = MOQX.close(subscriber)
      end
    end

    test "publisher connects" do
      publisher = connect_publisher!()

      try do
        assert MOQX.session_role(publisher) == :publisher
      after
        :ok = MOQX.close(publisher)
      end
    end
  end

  describe "external relay: subscribe" do
    @describetag :external_relay

    test "subscribe to catalog track delivers a valid CMSF catalog" do
      subscriber = connect_subscriber!()

      try do
        ns = relay_namespace()
        :ok = MOQX.subscribe(subscriber, ns, "catalog")
        await_subscribed!(ns, "catalog")

        {_group_id, payload} = await_frame!()
        assert byte_size(payload) > 0

        assert {:ok, catalog} = MOQX.Catalog.decode(payload)
        assert MOQX.Catalog.tracks(catalog) != []
      after
        :ok = MOQX.close(subscriber)
      end
    end

    test "subscribe/4 accepts delivery_timeout_ms and still receives catalog" do
      subscriber = connect_subscriber!()

      try do
        ns = relay_namespace()

        :ok = MOQX.subscribe(subscriber, ns, "catalog", delivery_timeout_ms: 1_500)
        await_subscribed!(ns, "catalog")

        {_group_id, payload} = await_frame!()
        assert byte_size(payload) > 0

        assert {:ok, catalog} = MOQX.Catalog.decode(payload)
        assert MOQX.Catalog.tracks(catalog) != []
      after
        :ok = MOQX.close(subscriber)
      end
    end

    test "subscribe to a video track delivers live frames" do
      subscriber = connect_subscriber!()

      try do
        ns = relay_namespace()

        # First get the catalog to discover tracks
        :ok = MOQX.subscribe(subscriber, ns, "catalog")
        await_subscribed!(ns, "catalog")

        {_gid, catalog_payload} = await_frame!()
        {:ok, catalog} = MOQX.Catalog.decode(catalog_payload)

        video = MOQX.Catalog.video_tracks(catalog) |> List.first()
        assert video, "expected at least one video track in catalog"

        # Subscribe to the video track
        :ok = MOQX.subscribe(subscriber, ns, video.name)
        await_subscribed!(ns, video.name)

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

    test "video frames expose PRFT for latency estimation" do
      subscriber = connect_subscriber!()

      try do
        ns = relay_namespace()

        # Discover one video track from the catalog
        :ok = MOQX.subscribe(subscriber, ns, "catalog")
        await_subscribed!(ns, "catalog")

        {_gid, catalog_payload} = await_frame!()
        {:ok, catalog} = MOQX.Catalog.decode(catalog_payload)

        video = MOQX.Catalog.video_tracks(catalog) |> List.first()
        assert video, "expected at least one video track in catalog"

        :ok = MOQX.subscribe(subscriber, ns, video.name)
        await_subscribed!(ns, video.name)

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

    test "multiple concurrent subscriptions deliver interleaved frames" do
      subscriber = connect_subscriber!()

      try do
        ns = relay_namespace()

        # Subscribe to catalog
        :ok = MOQX.subscribe(subscriber, ns, "catalog")
        await_subscribed!(ns, "catalog")
        {_gid, catalog_payload} = await_frame!()
        {:ok, catalog} = MOQX.Catalog.decode(catalog_payload)

        video = MOQX.Catalog.video_tracks(catalog) |> List.first()
        assert video

        # Subscribe to video (catalog subscription is still active)
        :ok = MOQX.subscribe(subscriber, ns, video.name)
        await_subscribed!(ns, video.name)

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

  describe "external relay: role guardrails" do
    @describetag :external_relay

    test "publish rejects subscriber sessions" do
      subscriber = connect_subscriber!()

      try do
        assert {:error, reason} = MOQX.publish(subscriber, "test")
        assert reason =~ "publish requires a publisher session"
      after
        :ok = MOQX.close(subscriber)
      end
    end

    test "subscribe rejects publisher sessions" do
      publisher = connect_publisher!()

      try do
        assert {:error, reason} = MOQX.subscribe(publisher, "test", "track")
        assert reason =~ "subscribe requires a subscriber session"
      after
        :ok = MOQX.close(publisher)
      end
    end

    test "fetch rejects publisher sessions" do
      publisher = connect_publisher!()

      try do
        assert {:error, "fetch requires a subscriber session"} =
                 MOQX.fetch(publisher, "moqtail", "catalog", [])
      after
        :ok = MOQX.close(publisher)
      end
    end

    test "fetch_catalog rejects publisher sessions" do
      publisher = connect_publisher!()

      try do
        assert {:error, "fetch requires a subscriber session"} = MOQX.fetch_catalog(publisher)
      after
        :ok = MOQX.close(publisher)
      end
    end
  end

  describe "external relay: catalog-driven flow" do
    @describetag :external_relay

    test "full catalog-driven subscribe: connect, catalog, decode, subscribe video" do
      subscriber = connect_subscriber!()

      try do
        ns = relay_namespace()

        # Subscribe to catalog
        :ok = MOQX.subscribe(subscriber, ns, "catalog")
        await_subscribed!(ns, "catalog")

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
        :ok = MOQX.subscribe(subscriber, ns, video.name)
        await_subscribed!(ns, video.name)

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
        {:moqx_frame, group_id, payload} ->
          collect_frames_loop(deadline, [{group_id, payload} | acc])

        {:moqx_subscribed, _, _} ->
          collect_frames_loop(deadline, acc)

        _ ->
          collect_frames_loop(deadline, acc)
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end
end
