defmodule MOQX.LiteCancelledGroupTest do
  use ExUnit.Case, async: true
  alias MOQX.Protocol.MOQLite05.Codec
  alias MOQX.Protocol.MOQLite05.Messages.TrackInfo
  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  for terminal <- [:fin, :data_fin, :reset, :new_group, :unknown_group] do
    test "handles #{terminal} after unsubscribe without treating never-issued IDs as stale" do
      terminal = Function.identity(unquote(terminal))
      {:ok, network} = Support.start_network()
      parent = self()

      peer =
        Task.async(fn ->
          {:ok, ctx} = Transport.new(Support, network: network, profile: :moq_lite_05)
          {:ok, listener, ctx} = Transport.listen(ctx, 0)
          {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
          send(parent, {:ready, port})
          {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1000)
          {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1000)
          {:ok, setup, ctx} = Transport.accept_stream(ctx, conn, [], 1000)
          {:ok, _, ctx} = Transport.recv_stream(ctx, setup, 9)

          ctx =
            Enum.reduce(0..1, ctx, fn _, ctx ->
              {:ok, track, ctx} = Transport.accept_stream(ctx, conn, [], 1000)
              {:ok, sub, ctx} = Transport.accept_stream(ctx, conn, [], 1000)

              info =
                Codec.encode_track_info(%TrackInfo{
                  publisher_priority: 128,
                  publisher_ordered: false,
                  publisher_max_latency: 0,
                  timescale: 1000
                })

              {:ok, _, ctx} = Transport.send_stream(ctx, track, info, finish: true)
              {:ok, _, ctx} = Transport.send_stream(ctx, sub, <<0, 1, 0>>)
              ctx
            end)

          {:ok, init, ctx} = Transport.open_stream(ctx, conn, direction: :unidirectional)
          {:ok, _, ctx} = Transport.send_stream(ctx, init, <<0, 2, 0, 0, 0, 4, "init">>)
          receive do: (:cancelled -> :ok)

          ctx =
            case terminal do
              :fin ->
                {:ok, ctx} = Transport.finish_sending(ctx, init)
                ctx

              :data_fin ->
                {:ok, _, ctx} = Transport.send_stream(ctx, init, <<0, 1, "x">>, finish: true)
                ctx

              :reset ->
                {:ok, ctx} = Transport.abort_sending(ctx, init, 17)
                ctx

              :new_group ->
                {:ok, late, ctx} = Transport.open_stream(ctx, conn, direction: :unidirectional)

                {:ok, _, ctx} =
                  Transport.send_stream(ctx, late, <<0, 2, 0, 1, 0, 1, "x">>, finish: true)

                ctx

              :unknown_group ->
                {:ok, late, ctx} = Transport.open_stream(ctx, conn, direction: :unidirectional)

                {:ok, _, ctx} =
                  Transport.send_stream(ctx, late, <<0, 2, 2, 1, 0, 1, "x">>, finish: true)

                ctx
            end

          {:ok, catalog, ctx} = Transport.open_stream(ctx, conn, direction: :unidirectional)

          {:ok, _, ctx} =
            Transport.send_stream(ctx, catalog, <<0, 2, 1, 0, 0, 7, "catalog">>, finish: true)

          receive do: (:observed -> :ok)
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
      {:ok, init} = MOQX.subscribe(client, %MOQX.TrackRef{namespace: ["live"], track: "init"})

      {:ok, catalog} =
        MOQX.subscribe(client, %MOQX.TrackRef{namespace: ["live"], track: "catalog"})

      assert_receive {:moqx, ^client,
                      %MOQX.Event.ObjectReceived{
                        object: %MOQX.Object{subscription: ^init, payload: "init"}
                      }},
                     1000

      assert :ok = MOQX.unsubscribe(client, init)
      send(peer.pid, :cancelled)

      if terminal == :unknown_group do
        assert_receive {:moqx, ^client,
                        %MOQX.Event.ProtocolFailed{reason: :unknown_group_subscription}},
                       1000
      else
        assert_receive {:moqx, ^client,
                        %MOQX.Event.ObjectReceived{
                          object: %MOQX.Object{subscription: ^catalog, payload: "catalog"}
                        }},
                       1000

        assert_receive {:moqx, ^client,
                        %MOQX.Event.SubgroupEnded{subscription: ^catalog, outcome: :complete}},
                       1000

        refute_receive {:moqx, ^client, %MOQX.Event.ProtocolFailed{}}

        refute_receive {:moqx, ^client,
                        %MOQX.Event.ObjectReceived{object: %MOQX.Object{subscription: ^init}}}
      end

      send(peer.pid, :observed)
      assert :ok = Task.await(peer, 1000)
    end
  end
end
