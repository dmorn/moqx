defmodule MOQX.MOQLite05RoundtripTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQLite05.Codec
  alias MOQX.Protocol.MOQLite05.Messages.{SubscribeOk, TrackInfo}
  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  test "subscribes through the public API over native QUIC streams" do
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
        expected_setup = <<1, 7, 2, 2, 1, "/", 3, 1, 2>>

        assert {:ok, ^expected_setup, ctx} =
                 Transport.recv_stream(ctx, setup, byte_size(expected_setup))

        {:ok, track_stream, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)
        {:ok, subscribe_stream, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)

        expected_track = <<6, 11, 4, "live", 5, "video">>

        assert {:ok, ^expected_track, ctx} =
                 Transport.recv_stream(ctx, track_stream, byte_size(expected_track))

        expected_subscribe = <<2, 17, 0, 4, "live", 5, "video", 128, 0, 0, 0, 0>>

        assert {:ok, ^expected_subscribe, ctx} =
                 Transport.recv_stream(ctx, subscribe_stream, byte_size(expected_subscribe))

        track_info =
          Codec.encode_track_info(%TrackInfo{
            publisher_priority: 17,
            publisher_ordered: false,
            publisher_max_latency: 1_000,
            timescale: 90_000
          })

        {:ok, _send, ctx} = Transport.send_stream(ctx, track_stream, track_info)

        {:ok, _send, ctx} =
          Transport.send_stream(
            ctx,
            subscribe_stream,
            Codec.encode_subscribe_response(%SubscribeOk{group: 7})
          )

        receive do
          :roundtrip_complete -> :ok
        after
          1_000 -> flunk("client did not observe the accepted subscription")
        end

        {:ok, _ctx} = Transport.close_connection(ctx, conn, 0)
        :ok
      end)

    assert_receive {:relay_ready, port}, 1_000

    assert {:ok, client} =
             MOQX.connect("moqt://localhost:#{port}",
               protocol: :moq_lite_05,
               role: :subscriber,
               transport: {Support, network: network, profile: :moq_lite_05},
               timeout: 1_000
             )

    assert {:ok, subscription} =
             MOQX.subscribe(client, %MOQX.TrackRef{namespace: ["live"], track: "video"})

    assert_receive {:moqx, ^client,
                    %MOQX.Event.SubscriptionAccepted{
                      subscription: ^subscription,
                      track_info: %MOQX.TrackInfo{timescale: 90_000}
                    }},
                   1_000

    send(relay.pid, :roundtrip_complete)
    assert :ok = Task.await(relay, 1_000)
  end
end
