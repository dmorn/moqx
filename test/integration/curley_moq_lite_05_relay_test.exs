defmodule MOQX.Integration.CurleyMOQLite05RelayTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :curley_moq_lite_05

  @relay "moql://curley-moq-lite-05-relay:443/"
  @ca_file "/certs/ca.pem"
  @curley "/usr/local/bin/moq"
  @curley_timestamp_probe "/usr/local/bin/moqx-curley-timestamp-probe"
  @h264_delimiter <<0, 0, 0, 1, 9, 0xF0, 0, 0, 0, 1, 12, 0x80>>
  @h264 Base.decode64!(
          "AAAAAWdCwAraewEQAAADABAAAAMAKPEiagAAAAFozg/IAAABBgX//0/cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MSBkZWJsb2NrPTA6MDowIGFuYWx5c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTI1MCBrZXlpbnRfbWluPTEgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTAAgAAAAWWIhDomKAAJAuA="
        )

  test "public APIs preserve one timestamped payload through the pinned relay" do
    namespace = ["integration", Integer.to_string(System.unique_integer([:positive]))]
    track_ref = %MOQX.TrackRef{namespace: namespace, track: "data"}

    assert {:ok, publisher} = connect(:publisher)

    try do
      assert {:ok, publication} = MOQX.publish(publisher, namespace)

      assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationReady{publication: ^publication}},
                     5_000

      assert {:ok, published_track} =
               MOQX.add_track(publisher, publication, "data",
                 timescale: 1_000,
                 publisher_priority: 127,
                 publisher_max_latency: 45_000
               )

      assert {:ok, subscriber} = connect(:subscriber)

      try do
        assert {:ok, subscription} = MOQX.subscribe(subscriber, track_ref)

        assert_receive {:moqx, ^publisher,
                        %MOQX.Event.PublicationSubscriberJoined{track: ^published_track}},
                       5_000

        assert :ok =
                 MOQX.publish_object(publisher, published_track, %MOQX.Object{
                   group_id: 0,
                   object_id: 0,
                   timestamp: 12_345,
                   end_of_group?: true,
                   payload: "curley-moq-lite-05"
                 })

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.SubscriptionAccepted{subscription: ^subscription}},
                       5_000

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.ObjectReceived{
                          object: %MOQX.Object{
                            subscription: ^subscription,
                            timestamp: 12_345,
                            payload: "curley-moq-lite-05"
                          }
                        }},
                       5_000
      after
        _result = MOQX.close(subscriber)
      end
    after
      _result = MOQX.close(publisher)
    end
  end

  test "official Curley publisher delivers its exact timestamped frame to MOQX" do
    namespace = unique_namespace("curley-publisher")
    track_ref = %MOQX.TrackRef{namespace: namespace, track: "0.avc3"}
    curley = open_curley(["--broadcast", Enum.join(namespace, "/"), "import", "avc3"])

    try do
      true = Port.command(curley, @h264)
      true = Port.command(curley, @h264_delimiter)

      {subscriber, subscription, object} =
        receive_curley_frame_when_routable(track_ref, 5_000)

      try do
        assert %MOQX.Object{subscription: ^subscription, timestamp: timestamp, payload: payload} =
                 object

        assert object.group_id == 0
        assert {:ok, ^timestamp, encoded_h264} = MOQX.Codec.decode_varint(payload)
        assert encoded_h264 == normalize_annex_b(@h264)
      after
        _result = MOQX.close(subscriber)
      end
    after
      Port.close(curley)
    end
  end

  test "official Curley subscriber exports the exact MOQX H264 frame" do
    namespace = unique_namespace("curley-subscriber")
    assert {:ok, publisher} = connect(:publisher)

    try do
      assert {:ok, publication} = MOQX.publish(publisher, namespace)

      assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationReady{publication: ^publication}},
                     5_000

      assert {:ok, catalog} = add_track(publisher, publication, "catalog.json")
      assert {:ok, video} = add_track(publisher, publication, ".avc3")

      curley = open_curley(["--broadcast", Enum.join(namespace, "/"), "export", "h264"])

      try do
        assert_receive {:moqx, ^publisher,
                        %MOQX.Event.PublicationSubscriberJoined{track: ^catalog}},
                       5_000

        assert :ok = publish(publisher, catalog, 0, catalog_payload())

        assert_receive {:moqx, ^publisher,
                        %MOQX.Event.PublicationSubscriberJoined{track: ^video}},
                       5_000

        assert :ok = publish(publisher, video, 456_000, legacy_frame(456_000, @h264))
        assert receive_port_bytes(curley, byte_size(@h264), 5_000) == @h264
      after
        Port.close(curley)
      end
    after
      _result = MOQX.close(publisher)
    end
  end

  test "Curley probe observes the MoQ Lite frame timestamp independently" do
    namespace = unique_namespace("curley-timestamp-probe")
    assert {:ok, publisher} = connect(:publisher)

    try do
      assert {:ok, publication} = MOQX.publish(publisher, namespace)

      assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationReady{publication: ^publication}},
                     5_000

      assert {:ok, track} = add_track(publisher, publication, "data")

      probe =
        open_curley_executable(@curley_timestamp_probe, [
          "--broadcast",
          Enum.join(namespace, "/"),
          "--track",
          "data"
        ])

      try do
        assert_receive {:moqx, ^publisher,
                        %MOQX.Event.PublicationSubscriberJoined{track: ^track}},
                       5_000

        payload = legacy_frame(123, "independent-timestamp-sentinel")
        assert :ok = publish(publisher, track, 456_000, payload)

        expected =
          "group=0 timestamp_us=456000 payload_hex=#{Base.encode16(payload, case: :lower)}\n"

        assert receive_port_bytes(probe, byte_size(expected), 5_000) == expected
        assert_receive {^probe, {:exit_status, 0}}, 5_000
      after
        close_port(probe)
      end
    after
      _result = MOQX.close(publisher)
    end
  end

  test "the publisher survives explicit and abrupt final-subscriber departures" do
    namespace = unique_namespace("subscriber-lifecycle")
    track_ref = %MOQX.TrackRef{namespace: namespace, track: "data"}
    assert {:ok, publisher} = connect(:publisher)

    try do
      assert {:ok, publication} = MOQX.publish(publisher, namespace)

      assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationReady{publication: ^publication}},
                     5_000

      assert {:ok, track} = add_track(publisher, publication, "data")
      assert {:ok, subscriber_a} = connect(:subscriber)
      close_on_exit(subscriber_a)
      assert {:ok, subscriber_b} = connect(:subscriber)
      close_on_exit(subscriber_b)
      assert {:ok, subscription_a} = MOQX.subscribe(subscriber_a, track_ref)
      assert {:ok, subscription_b} = MOQX.subscribe(subscriber_b, track_ref)

      assert_receive {:moqx, ^publisher,
                      %MOQX.Event.PublicationSubscriberJoined{
                        track: ^track,
                        subscription: published_subscription
                      }},
                     5_000

      publish_group(publisher, track, 0)
      assert_subscription_group(subscriber_a, subscription_a, 0)
      assert_subscription_group(subscriber_b, subscription_b, 0)

      assert :ok = MOQX.unsubscribe(subscriber_a, subscription_a)
      refute_receive {:moqx, ^publisher, %MOQX.Event.PublicationSubscriberLeft{}}, 100

      publish_group(publisher, track, 1)
      assert_object_group(subscriber_b, subscription_b, 1)
      refute_receive {:moqx, ^publisher, %MOQX.Event.PublicationSubscriberLeft{}}, 100

      explicit_leave_started = System.monotonic_time(:millisecond)
      assert :ok = MOQX.unsubscribe(subscriber_b, subscription_b)

      assert_receive {:moqx, ^publisher,
                      %MOQX.Event.PublicationSubscriberLeft{
                        track: ^track,
                        subscription: ^published_subscription
                      }},
                     5_000

      assert System.monotonic_time(:millisecond) - explicit_leave_started < 5_000

      refute_receive {:moqx, ^publisher,
                      %MOQX.Event.PublicationSubscriberLeft{
                        track: ^track,
                        subscription: ^published_subscription
                      }},
                     250

      assert {:ok, subscriber_abrupt} = connect(:subscriber)
      close_on_exit(subscriber_abrupt)
      assert {:ok, subscription_abrupt} = MOQX.subscribe(subscriber_abrupt, track_ref)

      assert_receive {:moqx, ^publisher,
                      %MOQX.Event.PublicationSubscriberJoined{
                        track: ^track,
                        subscription: published_abrupt
                      }},
                     5_000

      publish_group(publisher, track, 2)
      assert_subscription_group(subscriber_abrupt, subscription_abrupt, 2)
      assert :ok = MOQX.close(subscriber_abrupt)

      assert_receive {:moqx, ^publisher,
                      %MOQX.Event.PublicationSubscriberLeft{
                        track: ^track,
                        subscription: ^published_abrupt
                      }},
                     5_000

      refute_receive {:moqx, ^publisher,
                      %MOQX.Event.PublicationSubscriberLeft{
                        track: ^track,
                        subscription: ^published_abrupt
                      }},
                     250

      assert {:ok, subscriber_c} = connect(:subscriber)
      close_on_exit(subscriber_c)
      assert {:ok, subscription_c} = MOQX.subscribe(subscriber_c, track_ref)

      assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationSubscriberJoined{track: ^track}},
                     5_000

      publish_group(publisher, track, 3)
      assert_subscription_group(subscriber_c, subscription_c, 3)
    after
      _result = MOQX.close(publisher)
    end
  end

  defp connect(role) do
    MOQX.connect(@relay,
      protocol: :moq_lite_05,
      role: role,
      connect_options: [cacertfile: @ca_file],
      timeout: 5_000
    )
  end

  defp unique_namespace(prefix) do
    ["integration", "#{prefix}-#{System.unique_integer([:positive])}.hang"]
  end

  defp add_track(publisher, publication, name) do
    MOQX.add_track(publisher, publication, name,
      timescale: 1_000_000,
      publisher_priority: 127,
      publisher_max_latency: 45_000
    )
  end

  defp publish(publisher, track, timestamp, payload) do
    MOQX.publish_object(publisher, track, %MOQX.Object{
      group_id: 0,
      object_id: 0,
      timestamp: timestamp,
      end_of_group?: true,
      payload: payload
    })
  end

  defp publish_group(publisher, track, group_id) do
    assert :ok =
             MOQX.publish_object(publisher, track, %MOQX.Object{
               group_id: group_id,
               object_id: 0,
               timestamp: group_id * 1_000,
               end_of_group?: true,
               payload: "group-#{group_id}"
             })
  end

  defp assert_subscription_group(subscriber, subscription, group_id) do
    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.SubscriptionAccepted{subscription: ^subscription}},
                   5_000

    assert_object_group(subscriber, subscription, group_id)
  end

  defp assert_object_group(subscriber, subscription, group_id) do
    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.ObjectReceived{
                      object: %MOQX.Object{
                        subscription: ^subscription,
                        group_id: ^group_id,
                        payload: payload
                      }
                    }},
                   5_000

    assert payload == "group-#{group_id}"
  end

  defp close_on_exit(client), do: on_exit(fn -> MOQX.close(client) end)

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  end

  defp catalog_payload do
    ~s({"video":{"renditions":{".avc3":{"codec":"avc3.42c00a","codedWidth":16,"codedHeight":16,"container":{"kind":"legacy"}}}},"audio":{"renditions":{}}})
  end

  defp open_curley(arguments) do
    open_curley_executable(@curley, arguments)
  end

  defp open_curley_executable(executable, arguments) do
    args =
      [
        "--log-level",
        "error",
        "--client-connect",
        @relay,
        "--client-version",
        "moq-lite-05",
        "--client-tls-root",
        @ca_file,
        "--client-tls-host-name",
        "localhost"
      ] ++ arguments

    Port.open({:spawn_executable, executable}, [:binary, :exit_status, :use_stdio, args: args])
  end

  defp receive_curley_frame_when_routable(track, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    try_curley_subscription(track, deadline)
  end

  defp try_curley_subscription(track, deadline) do
    assert {:ok, subscriber} = connect(:subscriber)
    assert {:ok, subscription} = MOQX.subscribe(subscriber, track)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:moqx, ^subscriber, %MOQX.Event.SubscriptionFailed{subscription: ^subscription}} ->
        retry_curley_subscription(subscriber, track, deadline)

      {:moqx, ^subscriber, %MOQX.Event.SubscriptionAccepted{subscription: ^subscription}} ->
        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.ObjectReceived{
                          object: %MOQX.Object{subscription: ^subscription} = object
                        }},
                       remaining

        {subscriber, subscription, object}
    after
      remaining -> retry_curley_subscription(subscriber, track, deadline)
    end
  end

  defp retry_curley_subscription(subscriber, track, deadline) do
    _result = MOQX.close(subscriber)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      flunk("Curley publication did not become routable with a retained frame")
    else
      Process.sleep(min(10, remaining))
      try_curley_subscription(track, deadline)
    end
  end

  defp legacy_frame(timestamp, payload) do
    MOQX.Codec.encode_varint(timestamp) <> payload
  end

  defp normalize_annex_b(payload), do: normalize_annex_b(payload, [])

  defp normalize_annex_b(<<0, 0, 0, 1, rest::binary>>, chunks) do
    normalize_annex_b(rest, [<<0, 0, 0, 1>> | chunks])
  end

  defp normalize_annex_b(<<0, 0, 1, rest::binary>>, chunks) do
    normalize_annex_b(rest, [<<0, 0, 0, 1>> | chunks])
  end

  defp normalize_annex_b(<<byte, rest::binary>>, chunks) do
    normalize_annex_b(rest, [<<byte>> | chunks])
  end

  defp normalize_annex_b(<<>>, chunks) do
    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp receive_port_bytes(port, expected_size, timeout, chunks \\ []) do
    receive do
      {^port, {:data, data}} ->
        bytes = chunks |> Enum.reverse([data]) |> IO.iodata_to_binary()

        if byte_size(bytes) >= expected_size do
          bytes
        else
          receive_port_bytes(port, expected_size, timeout, [data | chunks])
        end

      {^port, {:exit_status, status}} ->
        flunk("Curley exited with status #{status}")
    after
      timeout -> flunk("Curley produced no output within #{timeout}ms")
    end
  end
end
