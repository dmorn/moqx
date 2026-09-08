defmodule MOQX.EmptyGroupTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQLite05.Codec
  alias MOQX.Protocol.MOQLite05.Messages.Subscribe
  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  test "publishes a header-only group and accounts for it in the exclusive completion bound" do
    {client, relay} = publisher()
    on_exit(fn -> MOQX.close(client) end)
    {:ok, publication} = MOQX.publish(client, ["live"])
    {:ok, track} = MOQX.add_track(client, publication, "data", timescale: 1000)
    send(relay.pid, :subscribe)

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationSubscriberJoined{subscription: sub}},
                   1000

    assert :ok = MOQX.publish_empty_group(client, track, 7)
    assert :ok = MOQX.finish_subscription(client, sub)
    assert :ok = Task.await(relay, 1000)
  end

  defp publisher(options \\ []) do
    {:ok, network} = Support.start_network()
    parent = self()

    relay =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Support, network: network, profile: :moq_lite_05)
        {:ok, listener, ctx} = Transport.listen(ctx, 0)
        {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
        send(parent, {:ready, port})
        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1000)
        {:ok, setup, ctx} = Transport.accept_stream(ctx, conn, [], 1000)
        {:ok, _setup, ctx} = Transport.recv_stream(ctx, setup, 9)
        receive do: (:subscribe -> :ok)
        {:ok, stream, ctx} = Transport.open_stream(ctx, conn, direction: :bidirectional)
        # SUBSCRIBE 42, broadcast "live", track "data", default priority, no range.
        request = %Subscribe{
          subscribe_id: 42,
          broadcast_path: "live",
          track_name: "data",
          subscriber_priority: 0,
          group_start: options[:group_start],
          group_end: options[:group_end]
        }

        bytes = <<2, Codec.encode_subscribe(request)::binary>>
        {:ok, _, ctx} = Transport.send_stream(ctx, stream, bytes)
        # Independent literal wire expectation: OK(group 7), END(exclusive 8).
        assert {:ok, <<0, 1, 7, 1, 1, 8>>, ctx} = Transport.recv_stream(ctx, stream, 6)
        {:ok, group, ctx} = Transport.accept_stream(ctx, conn, [], 1000)
        assert {:ok, <<0, 2, 42, 7>>, ctx} = Transport.recv_stream(ctx, group, 4)
        {:ok, ctx} = Transport.set_active(ctx, group, true)
        ctx = await_fin(ctx, group)
        assert {:error, :timeout, ctx} = Transport.accept_stream(ctx, conn, [], 20)
        {:ok, _ctx} = Transport.close_connection(ctx, conn, 0)
        :ok
      end)

    assert_receive {:ready, port}, 1000

    {:ok, client} =
      MOQX.connect("moql://localhost:#{port}/",
        protocol: :moq_lite_05,
        role: :publisher,
        transport: {Support, network: network, profile: :moq_lite_05},
        timeout: 1000
      )

    {client, relay}
  end

  test "latest retention replaces old media with an empty group for a late subscriber" do
    {client, relay} = publisher()
    on_exit(fn -> MOQX.close(client) end)
    {:ok, publication} = MOQX.publish(client, ["live"])

    {:ok, track} =
      MOQX.add_track(client, publication, "data", timescale: 1000, retention: :latest)

    assert :ok =
             MOQX.publish_object(client, track, %MOQX.Object{
               group_id: 0,
               object_id: 0,
               timestamp: 100,
               payload: "old",
               end_of_group?: true
             })

    assert :ok = MOQX.publish_empty_group(client, track, 7)
    send(relay.pid, :subscribe)

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationSubscriberJoined{subscription: sub}},
                   1000

    assert :ok = MOQX.finish_subscription(client, sub)
    assert :ok = Task.await(relay, 1000)
  end

  test "empty groups outside the subscriber range do not change its END bound" do
    {client, relay} = publisher(group_start: 7, group_end: 7)
    on_exit(fn -> MOQX.close(client) end)
    {:ok, publication} = MOQX.publish(client, ["live"])
    {:ok, track} = MOQX.add_track(client, publication, "data", timescale: 1000)
    send(relay.pid, :subscribe)

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationSubscriberJoined{subscription: sub}},
                   1000

    assert :ok = MOQX.publish_empty_group(client, track, 6)
    assert :ok = MOQX.publish_empty_group(client, track, 7)
    assert :ok = MOQX.publish_empty_group(client, track, 8)
    assert :ok = MOQX.finish_subscription(client, sub)
    assert :ok = Task.await(relay, 1000)
  end

  test "track-wide group ordering is validated without subscribers and permits backward epoch timestamps" do
    {client, relay} = publisher()
    on_exit(fn -> MOQX.close(client) end)
    {:ok, publication} = MOQX.publish(client, ["live"])
    {:ok, track} = MOQX.add_track(client, publication, "data", timescale: 1000)
    first = %MOQX.Object{group_id: 0, object_id: 0, timestamp: 100, payload: "media"}
    assert :ok = MOQX.publish_object(client, track, first)
    assert {:error, :unfinished_group} = MOQX.publish_empty_group(client, track, 1)
    assert :ok = MOQX.publish_object(client, track, %{first | object_id: 1, end_of_group?: true})
    assert :ok = MOQX.publish_empty_group(client, track, 1)
    assert {:error, :invalid_group_sequence} = MOQX.publish_empty_group(client, track, 1)

    assert {:error, :invalid_group_sequence} =
             MOQX.publish_object(client, track, %{first | end_of_group?: true})

    assert :ok =
             MOQX.publish_object(client, track, %{
               first
               | group_id: 2,
                 timestamp: 10,
                 end_of_group?: true
             })

    assert {:error, :invalid_group_id} = MOQX.publish_empty_group(client, track, -1)

    assert {:error, :invalid_group_id} =
             MOQX.publish_empty_group(client, track, 4_611_686_018_427_387_903)

    assert :ok = MOQX.withdraw_track(client, track)
    assert {:error, :unknown_published_track} = MOQX.publish_empty_group(client, track, 3)
    {:ok, replacement} = MOQX.add_track(client, publication, "data", timescale: 1000)
    assert :ok = MOQX.publish_empty_group(client, replacement, 0)
    assert {:error, :unknown_published_track} = MOQX.publish_empty_group(client, track, 3)
    Task.shutdown(relay)
  end

  test "foreign-client handles and ended publications cannot publish empty groups" do
    {client, peer} = publisher()
    {other, other_peer} = publisher()

    on_exit(fn ->
      MOQX.close(client)
      MOQX.close(other)
    end)

    {:ok, publication} = MOQX.publish(client, ["live"])
    {:ok, track} = MOQX.add_track(client, publication, "data", timescale: 1000)
    assert {:error, :wrong_client_published_track} = MOQX.publish_empty_group(other, track, 0)
    assert :ok = MOQX.publish_empty_group(client, track, 0)
    assert :ok = MOQX.finish_publication(client, publication)
    assert {:error, :unknown_publication} = MOQX.publish_empty_group(client, track, 1)
    Task.shutdown(peer)
    Task.shutdown(other_peer)
  end

  defp await_fin(ctx, group) do
    case Transport.receive_event(ctx, 1000) do
      {:ok, {:stream_event, ^group, :peer_finished_sending, _}, ctx} -> ctx
      {:ok, _event, ctx} -> await_fin(ctx, group)
      {:unknown, _message, ctx} -> await_fin(ctx, group)
      other -> flunk("header-only group never finished: #{inspect(other)}")
    end
  end
end
