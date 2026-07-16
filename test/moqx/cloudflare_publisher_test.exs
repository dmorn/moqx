defmodule MOQX.CloudflarePublisherTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQTDraft14.Codec
  alias MOQX.Protocol.MOQTDraft14.Messages
  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  test "publishes retained subgroup data and completes the Cloudflare lifecycle" do
    {:ok, network} = Support.start_network()
    parent = self()
    authorization = MOQX.Secret.new("managed-relay-token")

    relay =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Support, network: network, profile: :draft_14)
        {:ok, listener, ctx} = Transport.listen(ctx, 0)
        {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
        send(parent, {:relay_ready, port})

        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1_000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1_000)
        {:ok, control, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)

        auth_param = Codec.authorization_token("managed-relay-token")
        setup = Codec.client_setup(%{3 => auth_param})
        assert {:ok, ^setup, ctx} = Transport.recv_stream(ctx, control, byte_size(setup))

        server_setup = <<0x21, 0, 9, 0xC0000000FF00000E::64, 0>>
        {:ok, _send, ctx} = Transport.send_stream(ctx, control, server_setup)

        publish_namespace = %Messages.PublishNamespace{
          request_id: 0,
          track_namespace: ["live", "camera-1"],
          params: %{3 => auth_param}
        }

        publish_namespace = Codec.encode(publish_namespace)

        assert {:ok, ^publish_namespace, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_namespace))

        send(parent, :namespace_seen)

        receive do
          :track_ready -> :ok
        after
          1_000 -> flunk("track was not prepared")
        end

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x07, 0, 1, 0>>)

        subscribe = %Messages.Subscribe{
          request_id: 1,
          track_namespace: ["live", "camera-1"],
          track_name: "video.m4s",
          subscriber_priority: 127,
          group_order: :publisher,
          filter_type: :largest_object
        }

        subscribe = Codec.encode(subscribe)
        {:ok, _send, ctx} = Transport.send_stream(ctx, control, subscribe)

        subscribe_ok = %Messages.SubscribeOk{
          request_id: 1,
          track_alias: 1,
          expires: 0,
          group_order: :ascending,
          largest_location: {7, 0},
          params: %{}
        }

        subscribe_ok = Codec.encode(subscribe_ok)

        assert {:ok, ^subscribe_ok, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(subscribe_ok))

        {:ok, subgroup, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)

        object = %MOQX.Object{
          group_id: 7,
          subgroup_id: 0,
          object_id: 0,
          publisher_priority: 10,
          payload: "h264-fragment"
        }

        subgroup_bytes = Codec.encode_subgroup(1, object)

        assert {:ok, ^subgroup_bytes, ctx} =
                 Transport.recv_stream(ctx, subgroup, byte_size(subgroup_bytes))

        unsubscribe = Codec.encode(%Messages.Unsubscribe{request_id: 1})
        {:ok, _send, ctx} = Transport.send_stream(ctx, control, unsubscribe)

        publish_done = %Messages.PublishDone{
          request_id: 1,
          status_code: 3,
          stream_count: 1,
          reason_phrase: "subscription ended"
        }

        publish_done = Codec.encode(publish_done)

        assert {:ok, ^publish_done, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_done))

        send(parent, :subscriber_finished)

        namespace_done =
          Codec.encode(%Messages.PublishNamespaceDone{
            track_namespace: ["live", "camera-1"]
          })

        assert {:ok, ^namespace_done, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(namespace_done))

        assert {:ok, {:connection_event, ^conn, :closed, %{error_code: 0}}, _ctx} =
                 receive_closed(ctx, conn, 1_000)

        :ok
      end)

    assert_receive {:relay_ready, port}, 1_000

    assert inspect(authorization) == "#MOQX.Secret<REDACTED>"
    refute inspect(authorization) =~ "managed-relay-token"

    assert {:ok, client} =
             MOQX.connect("moqt://localhost:#{port}",
               protocol: :cloudflare_draft_14,
               transport: {Support, network: network, profile: :draft_14},
               authorization: authorization,
               timeout: 1_000
             )

    assert {:ok, publication} = MOQX.publish(client, ["live", "camera-1"])
    assert_receive :namespace_seen, 1_000

    assert {:ok, track} =
             MOQX.add_track(client, publication, "video.m4s", retention: :latest)

    object = %MOQX.Object{
      group_id: 7,
      subgroup_id: 0,
      object_id: 0,
      publisher_priority: 10,
      payload: "h264-fragment"
    }

    assert :ok = MOQX.publish_object(client, track, object)
    send(relay.pid, :track_ready)

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationReady{publication: ^publication}},
                   1_000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriberJoined{track: ^track, request_id: 1}},
                   1_000

    assert_receive :subscriber_finished, 1_000

    assert :ok = MOQX.finish_publication(client, publication)
    assert :ok = MOQX.close(client)
    assert :ok = Task.await(relay, 1_000)
  end

  test "application accepts an inbound subscription after provisioning its track" do
    {:ok, network} = Support.start_network()
    parent = self()

    relay =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Support, network: network, profile: :draft_14)
        {:ok, listener, ctx} = Transport.listen(ctx, 0)
        {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
        send(parent, {:controlled_relay_ready, port})

        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1_000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1_000)
        {:ok, control, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)

        setup = Codec.client_setup()
        assert {:ok, ^setup, ctx} = Transport.recv_stream(ctx, control, byte_size(setup))

        server_setup = <<0x21, 0, 9, 0xC0000000FF00000E::64, 0>>
        {:ok, _send, ctx} = Transport.send_stream(ctx, control, server_setup)

        publish_namespace =
          Codec.encode(%Messages.PublishNamespace{
            request_id: 0,
            track_namespace: ["live", "controlled"]
          })

        assert {:ok, ^publish_namespace, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(publish_namespace))

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x07, 0, 1, 0>>)

        subscribe =
          Codec.encode(%Messages.Subscribe{
            request_id: 1,
            track_namespace: ["live", "controlled"],
            track_name: "video",
            group_order: :ascending
          })

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, subscribe)

        subscribe_ok =
          Codec.encode(%Messages.SubscribeOk{
            request_id: 1,
            track_alias: 1,
            expires: 0,
            group_order: :ascending,
            largest_location: nil,
            params: %{}
          })

        assert {:ok, ^subscribe_ok, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(subscribe_ok))

        {:ok, subgroup, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)

        object = %MOQX.Object{
          group_id: 1,
          object_id: 0,
          publisher_priority: 10,
          payload: "controlled-object"
        }

        subgroup_bytes = Codec.encode_subgroup(1, object)

        assert {:ok, ^subgroup_bytes, _ctx} =
                 Transport.recv_stream(ctx, subgroup, byte_size(subgroup_bytes))

        :ok
      end)

    assert_receive {:controlled_relay_ready, port}, 1_000

    assert {:ok, client} =
             MOQX.connect("moqt://localhost:#{port}",
               protocol: :cloudflare_draft_14,
               transport: {Support, network: network, profile: :draft_14},
               timeout: 1_000
             )

    assert {:ok, publication} =
             MOQX.publish(client, ["live", "controlled"],
               inbound_subscriptions: :controlled,
               subscription_decision_timeout: 1_000
             )

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriptionRequested{request: request}},
                   1_000

    assert {:ok, track} = MOQX.add_track(client, publication, "video")
    assert :ok = MOQX.accept_subscription(client, request, track)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriberJoined{track: ^track, request_id: 1}},
                   1_000

    assert :ok =
             MOQX.publish_object(client, track, %MOQX.Object{
               group_id: 1,
               object_id: 0,
               publisher_priority: 10,
               payload: "controlled-object"
             })

    assert :ok = Task.await(relay, 1_000)
    assert :ok = MOQX.close(client)
  end

  defp receive_closed(ctx, conn, timeout) do
    case Transport.receive_event(ctx, timeout) do
      {:ok, {:connection_event, ^conn, :closed, _metadata} = event, ctx} ->
        {:ok, event, ctx}

      {:ok, _event, ctx} ->
        receive_closed(ctx, conn, timeout)

      {:unknown, _message, ctx} ->
        receive_closed(ctx, conn, timeout)

      other ->
        other
    end
  end
end
