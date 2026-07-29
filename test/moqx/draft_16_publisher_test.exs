defmodule MOQX.Draft16PublisherTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQTDraft16.Codec
  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  test "publishes a namespace, a ready track, and one subgroup through the public API" do
    {:ok, network} = Support.start_network()
    parent = self()

    relay =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Support, network: network, profile: :draft_16)
        {:ok, listener, ctx} = Transport.listen(ctx, 0)
        {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
        send(parent, {:relay_ready, port})

        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1_000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1_000)
        {:ok, control, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)

        setup = Codec.client_setup(URI.parse("moqt://localhost:#{port}"))
        assert {:ok, ^setup, ctx} = Transport.recv_stream(ctx, control, byte_size(setup))

        {:ok, _send, ctx} =
          Transport.send_stream(ctx, control, <<0x21, 0, 3, 1, 2, 4>>)

        publish_namespace = Codec.publish_namespace(0, ["live", "camera"])

        assert {:ok, ^publish_namespace, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_namespace))

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x07, 0, 2, 0, 0>>)

        publish_track =
          Codec.publish_track(
            2,
            %MOQX.TrackRef{namespace: ["live", "camera"], track: "video"},
            0
          )

        assert {:ok, ^publish_track, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_track))

        send(parent, :track_pending)

        receive do
          :accept_track -> :ok
        after
          1_000 -> flunk("client never exercised the pending track boundary")
        end

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x1E, 0, 2, 2, 0>>)
        {:ok, subgroup, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)

        expected = <<0x14, 0, 7, 3, 10, 0, 8, "fragment">>

        assert {:ok, ^expected, _ctx} =
                 Transport.recv_stream(ctx, subgroup, byte_size(expected))

        publish_done = Codec.publish_done(2, 2, 1, "track ended")

        assert {:ok, ^publish_done, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_done))

        namespace_done = Codec.publish_namespace_done(0)

        assert {:ok, ^namespace_done, _ctx} =
                 Transport.recv_stream(ctx, control, byte_size(namespace_done))

        :ok
      end)

    assert_receive {:relay_ready, port}, 1_000

    assert {:ok, client} =
             MOQX.connect("moqt://localhost:#{port}",
               protocol: :draft_16,
               transport: {Support, network: network, profile: :draft_16},
               timeout: 1_000
             )

    assert {:ok, publication} = MOQX.publish(client, ["live", "camera"])

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationReady{publication: ^publication}},
                   1_000

    assert {:ok, track} = MOQX.add_track(client, publication, "video")
    assert_receive :track_pending, 1_000

    object = %MOQX.Object{
      group_id: 7,
      subgroup_id: 3,
      object_id: 0,
      publisher_priority: 10,
      payload: "fragment"
    }

    assert {:error, :published_track_not_ready} = MOQX.publish_object(client, track, object)
    send(relay.pid, :accept_track)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriberJoined{
                      track: ^track,
                      subscription: nil,
                      request_id: 2
                    }},
                   1_000

    assert :ok = MOQX.publish_object(client, track, object)
    assert :ok = MOQX.finish_publication(client, publication)

    assert {:error, :unknown_publication} = MOQX.publish_object(client, track, object)
    assert :ok = Task.await(relay, 1_000)
  end

  test "publishes a datagram track through the public API and reports zero streams" do
    {:ok, network} = Support.start_network()
    parent = self()

    relay =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Support, network: network, profile: :draft_16)
        {:ok, listener, ctx} = Transport.listen(ctx, 0)
        {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
        send(parent, {:relay_ready, port})

        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1_000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1_000)
        {:ok, control, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)

        setup = Codec.client_setup(URI.parse("moqt://localhost:#{port}"))
        assert {:ok, ^setup, ctx} = Transport.recv_stream(ctx, control, byte_size(setup))

        {:ok, _send, ctx} =
          Transport.send_stream(ctx, control, <<0x21, 0, 3, 1, 2, 4>>)

        publish_namespace = Codec.publish_namespace(0, ["live", "camera"])

        assert {:ok, ^publish_namespace, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_namespace))

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x07, 0, 2, 0, 0>>)

        publish_track =
          Codec.publish_track(
            2,
            %MOQX.TrackRef{namespace: ["live", "camera"], track: "audio"},
            0
          )

        assert {:ok, ^publish_track, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_track))

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x1E, 0, 2, 2, 0>>)

        assert {:ok, {:datagram, ^conn, <<0x06, 0, 9, 17, "media">>, %{}}, ctx} =
                 receive_datagram(ctx)

        publish_done = Codec.publish_done(2, 2, 0, "track ended")

        assert {:ok, ^publish_done, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_done))

        namespace_done = Codec.publish_namespace_done(0)

        assert {:ok, ^namespace_done, _ctx} =
                 Transport.recv_stream(ctx, control, byte_size(namespace_done))

        :ok
      end)

    assert_receive {:relay_ready, port}, 1_000

    assert {:ok, client} =
             MOQX.connect("moqt://localhost:#{port}",
               protocol: :draft_16,
               transport: {Support, network: network, profile: :draft_16},
               timeout: 1_000
             )

    assert {:ok, publication} = MOQX.publish(client, ["live", "camera"])

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationReady{publication: ^publication}},
                   1_000

    assert {:ok, track} =
             MOQX.add_track(client, publication, "audio", delivery: :datagram)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriberJoined{track: ^track, request_id: 2}},
                   1_000

    object = %MOQX.Object{
      group_id: 9,
      object_id: 0,
      publisher_priority: 17,
      end_of_group?: true,
      payload: "media"
    }

    assert :ok = MOQX.publish_object(client, track, object)
    assert :ok = MOQX.finish_publication(client, publication)
    assert :ok = Task.await(relay, 1_000)
  end

  test "finishes pending and active controlled subscriptions through the public API" do
    {:ok, network} = Support.start_network()
    parent = self()

    relay =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Support, network: network, profile: :draft_16)
        {:ok, listener, ctx} = Transport.listen(ctx, 0)
        {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
        send(parent, {:relay_ready, port})

        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1_000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1_000)
        {:ok, control, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)

        setup = Codec.client_setup(URI.parse("moqt://localhost:#{port}"))
        assert {:ok, ^setup, ctx} = Transport.recv_stream(ctx, control, byte_size(setup))

        {:ok, _send, ctx} =
          Transport.send_stream(ctx, control, <<0x21, 0, 3, 1, 2, 4>>)

        namespace = ["live", "cleanup"]
        publish_namespace = Codec.publish_namespace(0, namespace)

        assert {:ok, ^publish_namespace, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_namespace))

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x07, 0, 2, 0, 0>>)

        track_ref = %MOQX.TrackRef{namespace: namespace, track: "video"}
        publish_track = Codec.publish_track(2, track_ref, 0)

        assert {:ok, ^publish_track, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_track))

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x1E, 0, 2, 2, 0>>)
        {:ok, _send, ctx} = Transport.send_stream(ctx, control, Codec.subscribe(1, track_ref, []))

        subscribe_ok = Codec.subscribe_ok(1, 1, group_order: :ascending)

        assert {:ok, ^subscribe_ok, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(subscribe_ok))

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, Codec.subscribe(3, track_ref, []))

        pending_error = Codec.request_error(3, 0x10, "publication finished")

        assert {:ok, ^pending_error, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(pending_error))

        active_done = Codec.publish_done(1, 2, 0, "complete")

        assert {:ok, ^active_done, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(active_done))

        primary_done = Codec.publish_done(2, 2, 0, "complete")

        assert {:ok, ^primary_done, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(primary_done))

        namespace_done = Codec.publish_namespace_done(0)

        assert {:ok, ^namespace_done, _ctx} =
                 Transport.recv_stream(ctx, control, byte_size(namespace_done))

        :ok
      end)

    assert_receive {:relay_ready, port}, 1_000

    assert {:ok, client} =
             MOQX.connect("moqt://localhost:#{port}",
               protocol: :draft_16,
               transport: {Support, network: network, profile: :draft_16},
               timeout: 1_000
             )

    assert {:ok, publication} =
             MOQX.publish(client, ["live", "cleanup"],
               inbound_subscriptions: :controlled,
               subscription_decision_timeout: 1_000
             )

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationReady{publication: ^publication}},
                   1_000

    assert {:ok, track} = MOQX.add_track(client, publication, "video")

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriberJoined{track: ^track, request_id: 2}},
                   1_000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriptionRequested{request: first_request}},
                   1_000

    assert {:ok, %MOQX.PublishedSubscription{} = first_subscription} =
             MOQX.accept_subscription(client, first_request, track)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriberJoined{
                      track: ^track,
                      subscription: ^first_subscription
                    }},
                   1_000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriptionRequested{request: second_request}},
                   1_000

    assert :ok =
             MOQX.finish_publication(client, publication, status: 2, reason: "complete")

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriptionCancelled{
                      request: ^second_request,
                      reason: :publication_finished
                    }},
                   1_000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriberLeft{
                      track: ^track,
                      subscription: ^first_subscription
                    }},
                   1_000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriberLeft{track: ^track, request_id: 2}},
                   1_000

    assert {:error, :stale_subscription_request} =
             MOQX.accept_subscription(client, second_request, track)

    assert :ok = Task.await(relay, 1_000)
  end

  test "accepts a namespace-routed subscription without sending PUBLISH" do
    {:ok, network} = Support.start_network()
    parent = self()

    relay =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Support, network: network, profile: :draft_16)
        {:ok, listener, ctx} = Transport.listen(ctx, 0)
        {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
        send(parent, {:relay_ready, port})

        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1_000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1_000)
        {:ok, control, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)

        setup = Codec.client_setup(URI.parse("moqt://localhost:#{port}"))
        assert {:ok, ^setup, ctx} = Transport.recv_stream(ctx, control, byte_size(setup))

        {:ok, _send, ctx} =
          Transport.send_stream(ctx, control, <<0x21, 0, 3, 1, 2, 4>>)

        namespace = ["live", "reactive"]
        publish_namespace = Codec.publish_namespace(0, namespace)

        assert {:ok, ^publish_namespace, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_namespace))

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x07, 0, 2, 0, 0>>)

        track_ref = %MOQX.TrackRef{namespace: namespace, track: "audio.it.opus"}
        {:ok, _send, ctx} = Transport.send_stream(ctx, control, Codec.subscribe(1, track_ref, []))

        subscribe_ok = Codec.subscribe_ok(1, 0, group_order: :ascending)

        assert {:ok, ^subscribe_ok, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(subscribe_ok))

        assert {:ok, {:datagram, ^conn, <<0x04, 0, 0, 127, "opus">>, %{}}, ctx} =
                 receive_datagram(ctx)

        publish_done = Codec.publish_done(1, 3, 0, "source unavailable")

        assert {:ok, ^publish_done, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_done))

        namespace_done = Codec.publish_namespace_done(0)

        assert {:ok, ^namespace_done, _ctx} =
                 Transport.recv_stream(ctx, control, byte_size(namespace_done))

        :ok
      end)

    assert_receive {:relay_ready, port}, 1_000

    assert {:ok, client} =
             MOQX.connect("moqt://localhost:#{port}",
               protocol: :draft_16,
               transport: {Support, network: network, profile: :draft_16},
               timeout: 1_000
             )

    assert {:ok, publication} =
             MOQX.publish(client, ["live", "reactive"], inbound_subscriptions: :controlled)

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationReady{publication: ^publication}},
                   1_000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriptionRequested{request: request}},
                   1_000

    assert {:ok, track, %MOQX.PublishedSubscription{} = published_subscription} =
             MOQX.accept_subscription(client, request,
               retention: :live,
               delivery: :datagram
             )

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriberJoined{
                      track: ^track,
                      subscription: ^published_subscription
                    }},
                   1_000

    assert :ok =
             MOQX.publish_object(client, track, %MOQX.Object{
               group_id: 0,
               subgroup_id: 0,
               object_id: 0,
               publisher_priority: 127,
               payload: "opus"
             })

    assert :ok =
             MOQX.finish_subscription(client, published_subscription,
               status: :subscription_ended,
               reason: "source unavailable"
             )

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriberLeft{
                      track: ^track,
                      subscription: ^published_subscription
                    }},
                   1_000

    assert {:error, :stale_published_subscription} =
             MOQX.finish_subscription(client, published_subscription)

    assert :ok = MOQX.finish_publication(client, publication)
    assert :ok = Task.await(relay, 1_000)
  end

  defp receive_datagram(ctx) do
    case Transport.receive_event(ctx, 1_000) do
      {:ok, {:datagram, _conn, _data, _metadata} = event, ctx} ->
        {:ok, event, ctx}

      {:ok, _event, ctx} ->
        receive_datagram(ctx)

      other ->
        other
    end
  end
end
