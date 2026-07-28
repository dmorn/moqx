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
                    %MOQX.Event.PublicationSubscriberJoined{track: ^track, request_id: 2}},
                   1_000

    assert :ok = MOQX.publish_object(client, track, object)
    assert :ok = Task.await(relay, 1_000)
  end
end
