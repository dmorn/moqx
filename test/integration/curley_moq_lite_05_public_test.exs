defmodule MOQX.Integration.CurleyMOQLite05PublicTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :curley_moq_lite_05_public

  @relay "moql://cdn.moq.dev:443/anon"
  @ca_file "/etc/ssl/certs/ca-certificates.crt"

  test "public anonymous relay preserves an exact payload on a unique path" do
    record_resolution()

    namespace = [
      "moqx",
      "issue-27-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    ]

    track_ref = %MOQX.TrackRef{namespace: namespace, track: "data"}
    payload = "moqx-public-#{System.unique_integer([:positive])}"
    assert {:ok, publisher} = connect(:publisher)

    try do
      assert {:ok, publication} = MOQX.publish(publisher, namespace)

      assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationReady{publication: ^publication}},
                     10_000

      assert {:ok, track} =
               MOQX.add_track(publisher, publication, "data",
                 timescale: 1_000,
                 publisher_priority: 127,
                 publisher_max_latency: 45_000
               )

      {subscriber, subscription, published_subscription} =
        connect_and_subscribe_when_routable(publisher, track, track_ref, 30_000)

      try do
        assert :ok =
                 MOQX.publish_object(publisher, track, %MOQX.Object{
                   group_id: 0,
                   object_id: 0,
                   timestamp: 0,
                   end_of_group?: true,
                   payload: "subscription-ready"
                 })

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.SubscriptionAccepted{subscription: ^subscription}},
                       10_000

        assert :ok =
                 MOQX.publish_object(publisher, track, %MOQX.Object{
                   group_id: 1,
                   object_id: 0,
                   timestamp: 27_000,
                   end_of_group?: true,
                   payload: payload
                 })

        assert_receive {:moqx, ^subscriber,
                        %MOQX.Event.ObjectReceived{
                          object: %MOQX.Object{
                            subscription: ^subscription,
                            timestamp: 27_000,
                            payload: ^payload
                          }
                        }},
                       10_000

        leave_started = System.monotonic_time(:millisecond)
        assert :ok = MOQX.unsubscribe(subscriber, subscription)

        assert_receive {:moqx, ^publisher,
                        %MOQX.Event.PublicationSubscriberLeft{
                          track: ^track,
                          subscription: ^published_subscription
                        }},
                       45_000

        assert System.monotonic_time(:millisecond) - leave_started < 45_000

        {subscriber_after_leave, subscription_after_leave, published_after_leave} =
          connect_and_subscribe_when_routable(publisher, track, track_ref, 30_000)

        try do
          assert :ok =
                   MOQX.publish_object(publisher, track, %MOQX.Object{
                     group_id: 2,
                     object_id: 0,
                     timestamp: 28_000,
                     end_of_group?: true,
                     payload: "subscription-ready-after-leave"
                   })

          assert_receive {:moqx, ^subscriber_after_leave,
                          %MOQX.Event.SubscriptionAccepted{
                            subscription: ^subscription_after_leave
                          }},
                         10_000

          payload_after_leave = payload <> "-after-leave"

          assert :ok =
                   MOQX.publish_object(publisher, track, %MOQX.Object{
                     group_id: 3,
                     object_id: 0,
                     timestamp: 29_000,
                     end_of_group?: true,
                     payload: payload_after_leave
                   })

          assert_receive {:moqx, ^subscriber_after_leave,
                          %MOQX.Event.ObjectReceived{
                            object: %MOQX.Object{
                              subscription: ^subscription_after_leave,
                              group_id: 3,
                              timestamp: 29_000,
                              payload: ^payload_after_leave
                            }
                          }},
                         10_000
        after
          _result = MOQX.close(subscriber_after_leave)
        end

        assert_receive {:moqx, ^publisher,
                        %MOQX.Event.PublicationSubscriberLeft{
                          track: ^track,
                          subscription: ^published_after_leave
                        }},
                       45_000
      after
        _result = MOQX.close(subscriber)
      end
    after
      _result = MOQX.close(publisher)
    end
  end

  defp connect(role) do
    MOQX.connect(@relay,
      protocol: :moq_lite_05,
      role: role,
      connect_options: [cacertfile: @ca_file],
      timeout: 10_000
    )
  end

  defp record_resolution do
    ipv4 = resolved_addresses(:inet)
    ipv6 = resolved_addresses(:inet6)

    IO.puts(
      "cdn.moq.dev resolution: IPv4=#{inspect(ipv4)} IPv6=#{inspect(ipv6)}; " <>
        "MOQX passes the hostname to Quicer/MsQuic, which owns address selection and fallback"
    )
  end

  defp connect_and_subscribe_when_routable(publisher, published_track, track_ref, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    try_public_subscription(publisher, published_track, track_ref, deadline)
  end

  defp try_public_subscription(publisher, published_track, track_ref, deadline) do
    assert {:ok, subscriber} = connect(:subscriber)
    assert {:ok, subscription} = MOQX.subscribe(subscriber, track_ref)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:moqx, ^publisher,
       %MOQX.Event.PublicationSubscriberJoined{
         track: ^published_track,
         subscription: published_subscription
       }} ->
        {subscriber, subscription, published_subscription}

      {:moqx, ^subscriber, %MOQX.Event.SubscriptionFailed{subscription: ^subscription}} ->
        retry_public_subscription(subscriber, publisher, published_track, track_ref, deadline)
    after
      remaining ->
        retry_public_subscription(subscriber, publisher, published_track, track_ref, deadline)
    end
  end

  defp retry_public_subscription(subscriber, publisher, published_track, track_ref, deadline) do
    _result = MOQX.close(subscriber)

    if System.monotonic_time(:millisecond) >= deadline do
      flunk("public relay did not route the unique anonymous publication")
    else
      try_public_subscription(publisher, published_track, track_ref, deadline)
    end
  end

  defp resolved_addresses(family) do
    case :inet.getaddrs(~c"cdn.moq.dev", family) do
      {:ok, addresses} -> addresses
      {:error, reason} -> {:error, reason}
    end
  end
end
