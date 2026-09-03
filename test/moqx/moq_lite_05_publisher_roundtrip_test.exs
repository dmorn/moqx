defmodule MOQX.MOQLite05PublisherRoundtripTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQLite05.Codec
  alias MOQX.Protocol.MOQLite05.Messages.{AnnounceRequest, Subscribe, Track}
  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  test "publishes to an automatic subscriber through the public API" do
    {:ok, network} = Support.start_network()
    parent = self()

    relay =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Support, network: network, profile: :moq_lite_05)
        {:ok, listener, ctx} = Transport.listen(ctx, 0)
        {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
        send(parent, {:relay_ready, port})

        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1_000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1_000)
        {:ok, setup, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)
        assert {:ok, <<1, 7, 2, 2, 1, "/", 3, 1, 1>>, ctx} = Transport.recv_stream(ctx, setup, 9)

        receive do
          :publication_ready -> :ok
        after
          1_000 -> flunk("publisher did not prepare the publication")
        end

        {:ok, announce, ctx} = Transport.open_stream(ctx, conn, direction: :bidirectional)

        announce_request =
          <<1,
            Codec.encode_announce_request(%AnnounceRequest{broadcast_path_prefix: ""})::binary>>

        {:ok, _send, ctx} = Transport.send_stream(ctx, announce, announce_request)

        assert {:ok, <<2, 0, 1, 7, 1, 4, "live", 0>>, ctx} =
                 Transport.recv_stream(ctx, announce, 11)

        {:ok, track, ctx} = Transport.open_stream(ctx, conn, direction: :bidirectional)

        track_request =
          <<6, Codec.encode_track(%Track{broadcast_path: "live", track_name: "video"})::binary>>

        {:ok, _send, ctx} = Transport.send_stream(ctx, track, track_request)

        assert {:ok, <<8, 17, 0, 0x43, 0xE8, 0x80, 0x01, 0x5F, 0x90>>, ctx} =
                 Transport.recv_stream(ctx, track, 9)

        {:ok, subscribe, ctx} = Transport.open_stream(ctx, conn, direction: :bidirectional)

        request = %Subscribe{
          subscribe_id: 42,
          broadcast_path: "live",
          track_name: "video",
          subscriber_priority: 9
        }

        {:ok, _send, ctx} =
          Transport.send_stream(ctx, subscribe, <<2, Codec.encode_subscribe(request)::binary>>)

        send(parent, :subscriber_joined)
        assert {:ok, <<0, 1, 7>>, ctx} = Transport.recv_stream(ctx, subscribe, 3)

        {:ok, group, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)
        expected_group = <<0, 2, 42, 7, 0x80, 0x02, 0xBF, 0x20, 1, "x">>

        assert {:ok, ^expected_group, ctx} =
                 Transport.recv_stream(ctx, group, byte_size(expected_group))

        {:ok, ctx} = Transport.finish_sending(ctx, subscribe)

        receive do
          :subscriber_left -> :ok
        after
          1_000 -> flunk("publisher did not release subscriber demand")
        end

        {:ok, _ctx} = Transport.close_connection(ctx, conn, 0)
        :ok
      end)

    assert_receive {:relay_ready, port}, 1_000

    assert {:ok, client} =
             MOQX.connect("moqt://localhost:#{port}",
               protocol: :moq_lite_05,
               role: :publisher,
               transport: {Support, network: network, profile: :moq_lite_05},
               timeout: 1_000
             )

    assert {:ok, publication} = MOQX.publish(client, ["live"])

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationReady{publication: ^publication}},
                   1_000

    assert {:ok, track} =
             MOQX.add_track(client, publication, "video",
               timescale: 90_000,
               publisher_priority: 17,
               publisher_max_latency: 1_000
             )

    send(relay.pid, :publication_ready)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriberJoined{
                      track: ^track,
                      subscription: subscription,
                      request_id: 42
                    }},
                   1_000

    assert_receive :subscriber_joined, 1_000

    object = %MOQX.Object{
      group_id: 7,
      object_id: 0,
      timestamp: 90_000,
      end_of_group?: true,
      payload: "x"
    }

    assert :ok = MOQX.publish_object(client, track, object)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriberLeft{
                      track: ^track,
                      subscription: ^subscription,
                      request_id: 42
                    }},
                   1_000

    send(relay.pid, :subscriber_left)
    assert :ok = Task.await(relay, 1_000)
  end
end
