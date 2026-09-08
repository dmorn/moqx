defmodule MOQX.EmptyGroupReceiverTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQLite05.Codec
  alias MOQX.Protocol.MOQLite05.Messages.TrackInfo
  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  test "public boundaries distinguish empty groups, empty payload objects, and reset groups" do
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
        {:ok, _, ctx} = Transport.recv_stream(ctx, setup, 9)
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
        {:ok, empty, ctx} = Transport.open_stream(ctx, conn, direction: :unidirectional)
        {:ok, _, ctx} = Transport.send_stream(ctx, empty, <<0, 2, 0, 0>>, finish: true)
        {:ok, object, ctx} = Transport.open_stream(ctx, conn, direction: :unidirectional)
        {:ok, _, ctx} = Transport.send_stream(ctx, object, <<0, 2, 0, 1, 0, 0>>, finish: true)
        {:ok, reset, ctx} = Transport.open_stream(ctx, conn, direction: :unidirectional)
        {:ok, _, ctx} = Transport.send_stream(ctx, reset, <<0, 2, 0, 2, 0, 1, "x">>)
        receive do: (:reset -> :ok)
        {:ok, ctx} = Transport.abort_sending(ctx, reset, 17)
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
    {:ok, sub} = MOQX.subscribe(client, %MOQX.TrackRef{namespace: ["live"], track: "data"})

    assert_receive {:moqx, ^client,
                    %MOQX.Event.SubgroupEnded{subscription: ^sub, group_id: 0, outcome: :complete} =
                      empty},
                   1000

    assert Map.get(empty, :object_count) == 0

    assert_receive {:moqx, ^client,
                    %MOQX.Event.ObjectReceived{
                      object: %MOQX.Object{subscription: ^sub, group_id: 1, payload: <<>>}
                    }},
                   1000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.SubgroupEnded{subscription: ^sub, group_id: 1, outcome: :complete} =
                      object},
                   1000

    assert Map.get(object, :object_count) == 1

    assert_receive {:moqx, ^client,
                    %MOQX.Event.ObjectReceived{object: %MOQX.Object{group_id: 2, payload: "x"}}},
                   1000

    send(relay.pid, :reset)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.SubgroupEnded{
                      subscription: ^sub,
                      group_id: 2,
                      outcome: :reset,
                      error_code: 17
                    } = reset},
                   1000

    assert Map.get(reset, :object_count) == 1
    send(relay.pid, :observed)
    assert :ok = Task.await(relay, 1000)
  end
end
