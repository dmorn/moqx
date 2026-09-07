defmodule MOQX.ProfilePeer do
  @moduledoc false
  import ExUnit.Assertions
  alias MOQX.Protocol.MOQLite05.{Codec, Messages}
  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  def start(options \\ []) do
    {module, transport_options, listen_options, connect_options} = transport(options)
    parent = self()

    task =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(module, transport_options)
        {:ok, listener, ctx} = Transport.listen(ctx, 0, listen_options)
        {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
        send(parent, {:listening, port})
        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1_000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1_000)
        {:ok, setup, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)
        {:ok, _setup, ctx} = Transport.recv_stream(ctx, setup, 9)
        peer_loop(ctx, conn)
      end)

    assert_receive {:listening, port}, 1_000

    {:ok, client} =
      MOQX.connect("moql://localhost:#{port}",
        protocol: :moq_lite_05,
        role: :subscriber,
        transport: {module, transport_options},
        connect_options: connect_options
      )

    {client, task}
  end

  defp transport(options) do
    if Keyword.get(options, :native, false) do
      certs = Keyword.fetch!(options, :certs)

      {MOQX.Transport.Quicer, [],
       [
         alpn: ["moq-lite-05"],
         certfile: certs <> "/server.pem",
         keyfile: certs <> "/server-key.pem",
         peer_bidi_stream_count: 100,
         peer_unidi_stream_count: 100
       ], [cacertfile: certs <> "/ca.pem"]}
    else
      {:ok, network} = Support.start_network()
      {Support, [network: network, profile: :moq_lite_05], [], []}
    end
  end

  defp peer_loop(ctx, conn, announce \\ nil, subscriptions \\ %{}) do
    receive do
      {:accept, id} ->
        {:ok, track, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)
        {:ok, subscribe, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)
        ctx = read_request(ctx, track)
        ctx = read_request(ctx, subscribe)

        info = %Messages.TrackInfo{
          publisher_priority: 0,
          publisher_ordered: false,
          publisher_max_latency: 0,
          timescale: 1000
        }

        {:ok, _, ctx} =
          Transport.send_stream(ctx, track, Codec.encode_track_info(info), finish: true)

        {:ok, _, ctx} =
          Transport.send_stream(
            ctx,
            subscribe,
            Codec.encode_subscribe_response(%Messages.SubscribeOk{group: 0})
          )

        peer_loop(ctx, conn, announce, Map.put(subscriptions, id, subscribe))

      {:object, id, group, payload} ->
        {:ok, stream, ctx} = Transport.open_stream(ctx, conn, direction: :unidirectional)

        bytes =
          [
            <<0>>,
            Codec.encode_group(%Messages.Group{subscribe_id: id, group_sequence: group}),
            Codec.encode_frame(%Messages.Frame{timestamp_delta: 0, payload: payload})
          ]
          |> IO.iodata_to_binary()

        {:ok, _, ctx} = Transport.send_stream(ctx, stream, bytes, finish: true)
        peer_loop(ctx, conn, announce, subscriptions)

      {:discovery, _handle} ->
        {:ok, stream, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)
        ctx = read_request(ctx, stream)
        ok = Codec.encode_announce_ok(%Messages.AnnounceOk{hop_id: 7, active_count: 1})

        broadcast =
          Codec.encode_announce_broadcast(%Messages.AnnounceBroadcast{
            status: :active,
            path_suffix: "alice",
            hop_ids: []
          })

        <<first, rest::binary>> = ok <> broadcast
        {:ok, _, ctx} = Transport.send_stream(ctx, stream, <<first>>)
        {:ok, _, ctx} = Transport.send_stream(ctx, stream, rest)
        peer_loop(ctx, conn, stream, subscriptions)

      {:broadcast, status, suffix} ->
        broadcast =
          Codec.encode_announce_broadcast(%Messages.AnnounceBroadcast{
            status: status,
            path_suffix: suffix,
            hop_ids: []
          })

        {:ok, _, ctx} = Transport.send_stream(ctx, announce, broadcast)
        peer_loop(ctx, conn, announce, subscriptions)

      :withdraw_broadcast ->
        broadcast =
          Codec.encode_announce_broadcast(%Messages.AnnounceBroadcast{
            status: :ended,
            path_suffix: "alice",
            hop_ids: []
          })

        {:ok, _, ctx} = Transport.send_stream(ctx, announce, broadcast)
        peer_loop(ctx, conn, announce, subscriptions)

      {:finish_subscription, id, last} ->
        response = Codec.encode_subscribe_response(%Messages.SubscribeEnd{group: last})
        {:ok, _, ctx} = Transport.send_stream(ctx, subscriptions[id], response, finish: true)

        peer_loop(ctx, conn, announce, subscriptions)

      :close_connection ->
        {:ok, ctx} = Transport.close_connection(ctx, conn, 0)
        peer_loop(ctx, conn, announce, subscriptions)

      :done ->
        :ok
    after
      5_000 -> flunk("peer timed out")
    end
  end

  defp read_request(ctx, stream) do
    {:ok, <<_type, length>>, ctx} = Transport.recv_stream(ctx, stream, 2)
    {:ok, _bytes, ctx} = Transport.recv_stream(ctx, stream, length)
    ctx
  end
end
