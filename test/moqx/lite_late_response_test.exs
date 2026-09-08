defmodule MOQX.LiteLateResponseTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQLite05.Codec
  alias MOQX.Protocol.MOQLite05.Messages.{Frame, Group, Subscribe, SubscribeOk, Track, TrackInfo}
  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  test "a rejected subscription's delayed TRACK_INFO cannot poison its live catalog sibling" do
    exercise_late_response(:track_info)
  end

  test "a rejected TRACK request's delayed SUBSCRIBE response cannot poison its live catalog sibling" do
    exercise_late_response(:subscribe_response)
  end

  test "local cancellation tolerates delayed TRACK_INFO while the catalog remains live" do
    exercise_late_response(:track_info, :cancel)
  end

  test "local cancellation tolerates delayed SUBSCRIBE responses while the catalog remains live" do
    exercise_late_response(:subscribe_response, :cancel)
  end

  defp exercise_late_response(response, terminal \\ :reject) do
    {:ok, network} = Support.start_network()
    parent = self()

    peer =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Support, network: network, profile: :moq_lite_05)
        {:ok, listener, ctx} = Transport.listen(ctx, 0)
        {:ok, {_, port}} = Transport.local_address(ctx, listener)
        send(parent, {:ready, port})
        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1000)
        {:ok, setup, ctx} = Transport.accept_stream(ctx, conn, [], 1000)
        {:ok, <<1, 7, 2, 2, 1, "/", 3, 1, 2>>, ctx} = Transport.recv_stream(ctx, setup, 9)
        {catalog_info, catalog_sub, ctx} = requests(ctx, conn, "catalog.json", 0)
        ctx = info(ctx, catalog_info)

        {:ok, _, ctx} =
          Transport.send_stream(
            ctx,
            catalog_sub,
            Codec.encode_subscribe_response(%SubscribeOk{group: 0})
          )

        ctx = catalog(ctx, conn, 0)
        {media_info, media_sub, ctx} = requests(ctx, conn, "video", 1)

        ctx = prepare_terminal(ctx, terminal, response, {media_info, media_sub}, parent)

        await(:failure_observed)

        ctx =
          if response == :track_info do
            info(ctx, media_info)
          else
            {:ok, _, ctx} =
              Transport.send_stream(
                ctx,
                media_sub,
                Codec.encode_subscribe_response(%SubscribeOk{group: 0})
              )

            ctx
          end

        ctx = catalog(ctx, conn, 1)
        await(:stop)
        {:ok, _ctx} = Transport.close_connection(ctx, conn, 0)
        :ok
      end)

    assert_receive {:ready, port}, 1000

    {:ok, client} =
      MOQX.connect("moql://localhost:#{port}/",
        protocol: :moq_lite_05,
        role: :subscriber,
        transport: {Support, network: network, profile: :moq_lite_05}
      )

    on_exit(fn -> MOQX.close(client) end)

    {:ok, catalog} =
      MOQX.subscribe(client, %MOQX.TrackRef{namespace: ["live"], track: "catalog.json"},
        profile: :hang
      )

    assert_receive {:moqx, ^client,
                    %MOQX.Event.CatalogReceived{subscription: ^catalog, group_id: 0}},
                   1000

    {:ok, media} = MOQX.subscribe(client, %MOQX.TrackRef{namespace: ["live"], track: "video"})

    if terminal == :reject do
      assert_receive {:moqx, ^client,
                      %MOQX.Event.SubscriptionFailed{subscription: ^media, error: %{code: 0x10}}},
                     1000
    else
      assert_receive :requests_pending, 1000
      assert :ok = MOQX.unsubscribe(client, media)
    end

    send(peer.pid, :failure_observed)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.CatalogReceived{subscription: ^catalog, group_id: 1}},
                   1000

    refute_receive {:moqx, ^client, %MOQX.Event.ProtocolFailed{}}
    refute_receive {:moqx, ^client, %MOQX.Event.SubscriptionAccepted{subscription: ^media}}
    refute_receive {:moqx, ^client, %MOQX.Event.SubscriptionFailed{subscription: ^media}}
    send(peer.pid, :stop)
    assert :ok = Task.await(peer, 1000)
  end

  defp requests(ctx, conn, name, id) do
    {:ok, track, ctx} = Transport.accept_stream(ctx, conn, [], 1000)
    {:ok, subscribe, ctx} = Transport.accept_stream(ctx, conn, [], 1000)

    track_bytes =
      <<6, Codec.encode_track(%Track{broadcast_path: "live", track_name: name})::binary>>

    sub_bytes =
      <<2,
        Codec.encode_subscribe(%Subscribe{
          subscribe_id: id,
          broadcast_path: "live",
          track_name: name,
          subscriber_priority: 128
        })::binary>>

    {:ok, ^track_bytes, ctx} = Transport.recv_stream(ctx, track, byte_size(track_bytes))
    {:ok, ^sub_bytes, ctx} = Transport.recv_stream(ctx, subscribe, byte_size(sub_bytes))
    {track, subscribe, ctx}
  end

  defp prepare_terminal(ctx, :reject, response, {media_info, media_sub}, _parent) do
    rejected_stream = if response == :track_info, do: media_sub, else: media_info
    {:ok, ctx} = Transport.abort_sending(ctx, rejected_stream, 0x10)
    ctx
  end

  defp prepare_terminal(ctx, :cancel, _response, _streams, parent) do
    send(parent, :requests_pending)
    ctx
  end

  defp info(ctx, stream) do
    bytes =
      Codec.encode_track_info(%TrackInfo{
        publisher_priority: 17,
        publisher_ordered: false,
        publisher_max_latency: 0,
        timescale: 1_000_000
      })

    {:ok, _, ctx} = Transport.send_stream(ctx, stream, bytes, finish: true)
    ctx
  end

  defp catalog(ctx, conn, sequence) do
    {:ok, stream, ctx} = Transport.open_stream(ctx, conn, direction: :unidirectional)

    bytes =
      <<0, Codec.encode_group(%Group{subscribe_id: 0, group_sequence: sequence})::binary,
        Codec.encode_frame(%Frame{timestamp_delta: 0, payload: "{}"})::binary>>

    {:ok, _, ctx} = Transport.send_stream(ctx, stream, bytes, finish: true)
    ctx
  end

  defp await(message) do
    receive do
      ^message -> :ok
    after
      3000 -> flunk("missing fixture barrier #{inspect(message)}")
    end
  end
end
