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

  defp await_connect_result!(connect_ref) do
    receive do
      {:moqx_connect_ok, %MOQX.ConnectOk{ref: ^connect_ref, session: session}} ->
        {:ok, session}

      {:moqx_request_error, %MOQX.RequestError{op: :connect, ref: ^connect_ref, message: reason}} ->
        {:error, reason}

      {:moqx_transport_error,
       %MOQX.TransportError{op: :connect, ref: ^connect_ref, message: reason}} ->
        {:error, reason}
    after
      @timeout -> raise "connect timeout"
    end
  end

  defp connect_subscriber! do
    {:ok, connect_ref} = MOQX.connect_subscriber(relay_url())

    case await_connect_result!(connect_ref) do
      {:ok, session} -> session
      {:error, reason} -> raise "subscriber connect failed: #{inspect(reason)}"
    end
  end

  defp connect_publisher! do
    {:ok, connect_ref} = MOQX.connect_publisher(relay_url())

    case await_connect_result!(connect_ref) do
      {:ok, session} -> session
      {:error, reason} -> raise "publisher connect failed: #{inspect(reason)}"
    end
  end

  defp await_subscribed!(sub_ref, namespace, track_name) do
    receive do
      {:moqx_subscribe_ok,
       %MOQX.SubscribeOk{handle: ^sub_ref, namespace: ^namespace, track_name: ^track_name}} ->
        :ok

      {:moqx_request_error, %MOQX.RequestError{op: :subscribe, handle: ^sub_ref, message: reason}} ->
        flunk("subscribe failed: #{inspect(reason)}")

      {:moqx_transport_error,
       %MOQX.TransportError{op: :subscribe, handle: ^sub_ref, message: reason}} ->
        flunk("subscribe transport failed: #{inspect(reason)}")
    after
      @timeout -> flunk("subscribe timeout for #{namespace}/#{track_name}")
    end
  end

  defp await_publish_ok!(publish_ref, namespace, timeout) do
    receive do
      {:moqx_publish_ok,
       %MOQX.PublishOk{ref: ^publish_ref, broadcast: broadcast, namespace: ^namespace}} ->
        broadcast

      {:moqx_request_error, %MOQX.RequestError{op: :publish, ref: ^publish_ref, message: reason}} ->
        flunk("publish failed: #{inspect(reason)}")

      {:moqx_transport_error,
       %MOQX.TransportError{op: :publish, ref: ^publish_ref, message: reason}} ->
        flunk("publish transport failed: #{inspect(reason)}")
    after
      timeout -> flunk("publish timeout for namespace #{namespace}")
    end
  end

  defp publish_and_await_broadcast!(publisher, namespace, timeout \\ @timeout) do
    {:ok, publish_ref} = MOQX.publish(publisher, namespace)
    await_publish_ok!(publish_ref, namespace, timeout)
  end

  defp subscribe_and_await!(subscriber, namespace, track_name) do
    {:ok, handle} = MOQX.subscribe(subscriber, namespace, track_name)
    await_subscribed!(handle, namespace, track_name)
    :ok
  end

  defp subscribe_and_await_handle!(subscriber, namespace, track_name) do
    {:ok, handle} = MOQX.subscribe(subscriber, namespace, track_name)
    await_subscribed!(handle, namespace, track_name)
    handle
  end

  defp await_frame! do
    receive do
      {:moqx_object,
       %MOQX.ObjectReceived{object: %MOQX.Object{group_id: group_id, payload: payload}}} ->
        {group_id, payload}

      {:moqx_end_of_group, %MOQX.EndOfGroup{}} ->
        await_frame!()

      {:moqx_transport_error, %MOQX.TransportError{message: reason}} ->
        flunk("frame receive failed: #{inspect(reason)}")
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

        broadcast = publish_and_await_broadcast!(publisher, ns)
        {:ok, track} = MOQX.create_track(broadcast, track_name)

        subscribe_and_await!(subscriber, ns, track_name)

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

        broadcast = publish_and_await_broadcast!(publisher, ns)
        {:ok, catalog_track} = MOQX.publish_catalog(broadcast, catalog_payload)
        {:ok, media_track} = MOQX.create_track(broadcast, media_track_name)

        subscribe_and_await!(subscriber, ns, "catalog")
        subscribe_and_await!(subscriber, ns, media_track_name)

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

    @tag :integration
    test "unsubscribe/1 stops frame delivery and emits moqx_publish_done" do
      publisher = connect_publisher!()
      subscriber = connect_subscriber!()

      try do
        ns = "moqx-e2e-unsub-#{System.system_time(:millisecond)}"
        track_name = "demo"
        payload1 = "before-unsub"
        payload2 = "after-unsub"

        broadcast = publish_and_await_broadcast!(publisher, ns)
        {:ok, track} = MOQX.create_track(broadcast, track_name)

        handle = subscribe_and_await_handle!(subscriber, ns, track_name)

        :ok = MOQX.write_frame(track, payload1)
        {_gid, got} = await_matching_payload_frame!(payload1)
        assert got == payload1

        assert :ok = MOQX.unsubscribe(handle)

        assert_receive {:moqx_publish_done, %MOQX.PublishDone{handle: ^handle}}, @timeout

        # Publisher keeps writing; subscriber must not see the new frame.
        :ok = MOQX.write_frame(track, payload2)

        refute_receive {:moqx_object, %MOQX.ObjectReceived{handle: ^handle}}, 1_500
      after
        :ok = MOQX.close(subscriber)
        :ok = MOQX.close(publisher)
      end
    end

    @tag :integration
    test "unsubscribe/1 is idempotent" do
      publisher = connect_publisher!()
      subscriber = connect_subscriber!()

      try do
        ns = "moqx-e2e-unsub-idem-#{System.system_time(:millisecond)}"
        track_name = "demo"

        broadcast = publish_and_await_broadcast!(publisher, ns)
        {:ok, _track} = MOQX.create_track(broadcast, track_name)

        handle = subscribe_and_await_handle!(subscriber, ns, track_name)

        assert :ok = MOQX.unsubscribe(handle)
        assert_receive {:moqx_publish_done, %MOQX.PublishDone{handle: ^handle}}, @timeout

        # Second call must be a silent no-op and emit no further messages.
        assert :ok = MOQX.unsubscribe(handle)

        refute_receive {:moqx_publish_done, %MOQX.PublishDone{handle: ^handle}}, 500

        refute_receive {:moqx_transport_error,
                        %MOQX.TransportError{op: :subscribe, handle: ^handle}},
                       500
      after
        :ok = MOQX.close(subscriber)
        :ok = MOQX.close(publisher)
      end
    end

    @tag :integration
    test "two subgroups on the same group deliver in parallel with distinct priorities" do
      publisher = connect_publisher!()
      subscriber = connect_subscriber!()

      try do
        ns = "moqx-e2e-parallel-#{System.system_time(:millisecond)}"
        track_name = "demo"
        payload_a = "subgroup-A-payload"
        payload_b = "subgroup-B-payload"

        broadcast = publish_and_await_broadcast!(publisher, ns)
        {:ok, track} = MOQX.create_track(broadcast, track_name)

        subscribe_and_await!(subscriber, ns, track_name)

        group_id = 42

        {:ok, sg_a} =
          MOQX.open_subgroup(track, group_id, subgroup_id: 0, priority: 200)

        {:ok, sg_b} =
          MOQX.open_subgroup(track, group_id, subgroup_id: 7, priority: 10)

        :ok = MOQX.write_object(sg_a, 0, payload_a)
        :ok = MOQX.write_object(sg_b, 0, payload_b)
        :ok = MOQX.close_subgroup(sg_a)
        :ok = MOQX.close_subgroup(sg_b)

        objects = collect_objects_until_both_seen([payload_a, payload_b], @timeout)

        obj_a = Enum.find(objects, &(&1.payload == payload_a))
        obj_b = Enum.find(objects, &(&1.payload == payload_b))

        assert %MOQX.Object{} = obj_a
        assert %MOQX.Object{} = obj_b

        assert obj_a.group_id == group_id
        assert obj_b.group_id == group_id
        assert obj_a.subgroup_id == 0
        assert obj_b.subgroup_id == 7
        assert obj_a.priority == 200
        assert obj_b.priority == 10
        assert obj_a.status == :normal
        assert obj_b.status == :normal

        :ok = MOQX.finish_track(track)
      after
        :ok = MOQX.close(subscriber)
        :ok = MOQX.close(publisher)
      end
    end

    @tag :integration
    test "subgroup extensions round-trip varint and bytes values" do
      publisher = connect_publisher!()
      subscriber = connect_subscriber!()

      try do
        ns = "moqx-e2e-ext-#{System.system_time(:millisecond)}"
        track_name = "demo"
        payload = "payload-with-extensions"

        varint_ext = {2, 123_456}
        bytes_ext = {13, <<0xCA, 0xFE, 0xBA, 0xBE>>}

        broadcast = publish_and_await_broadcast!(publisher, ns)
        {:ok, track} = MOQX.create_track(broadcast, track_name)

        subscribe_and_await!(subscriber, ns, track_name)

        {:ok, sg} =
          MOQX.open_subgroup(track, 0,
            subgroup_id: 0,
            priority: 42,
            extensions_present: true
          )

        :ok =
          MOQX.write_object(sg, 0, payload, extensions: [varint_ext, bytes_ext])

        :ok = MOQX.close_subgroup(sg)

        obj =
          receive do
            {:moqx_object, %MOQX.ObjectReceived{object: %MOQX.Object{payload: ^payload} = obj}} ->
              obj

            {:moqx_transport_error, %MOQX.TransportError{message: reason}} ->
              flunk("receive failed: #{inspect(reason)}")
          after
            @timeout -> flunk("timeout waiting for extension-bearing object")
          end

        assert obj.priority == 42
        assert obj.extensions == [varint_ext, bytes_ext]

        :ok = MOQX.finish_track(track)
      after
        :ok = MOQX.close(subscriber)
        :ok = MOQX.close(publisher)
      end
    end

    @tag :integration
    test "open_subgroup rejects extensions with mismatched type parity" do
      publisher = connect_publisher!()

      try do
        broadcast = publish_and_await_broadcast!(publisher, "moqx-ext-reject")
        {:ok, track} = MOQX.create_track(broadcast, "demo")

        # open_subgroup itself no longer takes :extensions, so parity checks live
        # on write_object. But first open a subgroup so we have a handle.
        {:ok, sg} = MOQX.open_subgroup(track, 0, extensions_present: true)

        # Even-type with binary value: invalid (even types are varints).
        assert_raise ArgumentError, ~r/type 2 is even/, fn ->
          MOQX.write_object(sg, 0, "p", extensions: [{2, <<1, 2>>}])
        end

        # Odd-type with integer value: invalid (odd types are bytes).
        assert_raise ArgumentError, ~r/type 13 is odd/, fn ->
          MOQX.write_object(sg, 0, "p", extensions: [{13, 42}])
        end

        :ok = MOQX.close_subgroup(sg)
      after
        :ok = MOQX.close(publisher)
      end
    end

    @tag :integration
    test "end-of-group signalled via header flag + marker yields exactly one :moqx_end_of_group" do
      publisher = connect_publisher!()
      subscriber = connect_subscriber!()

      try do
        ns = "moqx-e2e-eog-#{System.system_time(:millisecond)}"
        track_name = "demo"
        payload = "data-in-eog-subgroup"

        broadcast = publish_and_await_broadcast!(publisher, ns)
        {:ok, track} = MOQX.create_track(broadcast, track_name)

        handle = subscribe_and_await_handle!(subscriber, ns, track_name)

        # end_of_group: true selects the 0x18–0x1D header family AND enables
        # close_subgroup/emit_end_of_group_marker, which writes a Status=EndOfGroup
        # marker object before finishing. The publisher signals EoG via *both*
        # paths; the subscriber should see exactly one :moqx_end_of_group.
        {:ok, sg} =
          MOQX.open_subgroup(track, 0, subgroup_id: 0, priority: 10, end_of_group: true)

        :ok = MOQX.write_object(sg, 0, payload)
        :ok = MOQX.close_subgroup(sg, end_of_group: true)

        # First: exactly one data object, then exactly one :moqx_end_of_group, then nothing.
        assert_receive {:moqx_object,
                        %MOQX.ObjectReceived{
                          handle: ^handle,
                          object: %MOQX.Object{
                            group_id: 0,
                            subgroup_id: 0,
                            object_id: 0,
                            status: :normal,
                            payload: ^payload
                          }
                        }},
                       @timeout

        assert_receive {:moqx_end_of_group,
                        %MOQX.EndOfGroup{handle: ^handle, group_id: 0, subgroup_id: 0}},
                       @timeout

        # No duplicate :moqx_end_of_group even though the publisher signalled via
        # both the header flag and the marker object.
        refute_receive {:moqx_end_of_group, %MOQX.EndOfGroup{handle: ^handle}}, 500

        # The marker object itself should NOT leak through as a :moqx_object with
        # status :end_of_group — that would force every subscriber to filter it.
        refute_receive {:moqx_object,
                        %MOQX.ObjectReceived{
                          handle: ^handle,
                          object: %MOQX.Object{status: :end_of_group}
                        }},
                       500

        :ok = MOQX.finish_track(track)
      after
        :ok = MOQX.close(subscriber)
        :ok = MOQX.close(publisher)
      end
    end

    @tag :integration
    test "write_object without extensions_present errors when :extensions is non-empty" do
      publisher = connect_publisher!()
      subscriber = connect_subscriber!()

      try do
        ns = "moqx-e2e-ext-missing-#{System.system_time(:millisecond)}"
        track_name = "demo"

        broadcast = publish_and_await_broadcast!(publisher, ns)
        {:ok, track} = MOQX.create_track(broadcast, track_name)

        handle = subscribe_and_await_handle!(subscriber, ns, track_name)

        {:ok, sg} = MOQX.open_subgroup(track, 0, subgroup_id: 0, extensions_present: false)
        :ok = MOQX.write_object(sg, 0, "p", extensions: [{2, 100}])

        assert_receive {:moqx_transport_error,
                        %MOQX.TransportError{op: :write_object, handle: ^sg, message: reason}},
                       @timeout

        assert reason =~ "extensions_present"

        :ok = MOQX.close_subgroup(sg)
        :ok = MOQX.unsubscribe(handle)
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
        assert {:error,
                %MOQX.RequestError{
                  op: :publish,
                  message: "publish requires a publisher session; use MOQX.connect_publisher/1"
                }} = MOQX.publish(subscriber, "test")
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
        assert {:error,
                %MOQX.RequestError{op: :fetch, message: "fetch requires a subscriber session"}} =
                 MOQX.fetch(publisher, "moqtail", "catalog", [])
      after
        :ok = MOQX.close(publisher)
      end
    end

    @tag :integration
    test "fetch_catalog rejects publisher sessions" do
      publisher = connect_publisher!()

      try do
        assert {:error,
                %MOQX.RequestError{op: :fetch, message: "fetch requires a subscriber session"}} =
                 MOQX.fetch_catalog(publisher)
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
        {:moqx_object,
         %MOQX.ObjectReceived{
           object: %MOQX.Object{group_id: group_id, payload: ^expected_payload}
         }} ->
          {group_id, expected_payload}

        {:moqx_object, %MOQX.ObjectReceived{}} ->
          await_matching_payload_frame_loop(expected_payload, deadline)

        {:moqx_end_of_group, %MOQX.EndOfGroup{}} ->
          await_matching_payload_frame_loop(expected_payload, deadline)

        {:moqx_transport_error, %MOQX.TransportError{message: reason}} ->
          flunk("frame receive failed: #{inspect(reason)}")
      after
        remaining ->
          flunk("frame timeout waiting for payload #{inspect(expected_payload)}")
      end
    end
  end

  defp collect_objects_until_both_seen(expected_payloads, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_objects_until_both_seen_loop(expected_payloads, deadline, [])
  end

  defp collect_objects_until_both_seen_loop(expected_payloads, deadline, acc) do
    if Enum.all?(expected_payloads, fn p -> Enum.any?(acc, &(&1.payload == p)) end) do
      acc
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        flunk(
          "timeout waiting for payloads #{inspect(expected_payloads)}, got payloads: #{inspect(Enum.map(acc, & &1.payload))}"
        )
      else
        receive do
          {:moqx_object, %MOQX.ObjectReceived{object: %MOQX.Object{} = obj}} ->
            collect_objects_until_both_seen_loop(expected_payloads, deadline, [obj | acc])

          {:moqx_end_of_group, %MOQX.EndOfGroup{}} ->
            collect_objects_until_both_seen_loop(expected_payloads, deadline, acc)

          {:moqx_transport_error, %MOQX.TransportError{message: reason}} ->
            flunk("receive failed: #{inspect(reason)}")
        after
          remaining ->
            flunk(
              "timeout waiting for payloads #{inspect(expected_payloads)}, got payloads: #{inspect(Enum.map(acc, & &1.payload))}"
            )
        end
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
        {:moqx_object,
         %MOQX.ObjectReceived{object: %MOQX.Object{group_id: group_id, payload: payload}}} ->
          collect_frames_loop(deadline, [{group_id, payload} | acc])

        {:moqx_subscribe_ok, _} ->
          collect_frames_loop(deadline, acc)

        _ ->
          collect_frames_loop(deadline, acc)
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end
end
