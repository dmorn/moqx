defmodule MOQX.EventRoutingTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQTDraft18.Codec
  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  test "events_to routes typed events to an explicit process" do
    {:ok, network} = Support.start_network()
    parent = self()
    router = spawn(fn -> route_events(parent) end)

    relay =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Support, network: network, profile: :draft_18)
        {:ok, listener, ctx} = Transport.listen(ctx, 0)
        {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
        send(parent, {:relay_ready, port})

        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1_000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1_000)
        {:ok, client_control, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)

        setup = Codec.client_setup(URI.parse("moqt://localhost:#{port}"))

        {:ok, ^setup, ctx} =
          Transport.recv_stream(ctx, client_control, byte_size(setup))

        {:ok, server_control, ctx} =
          Transport.open_stream(ctx, conn, direction: :unidirectional)

        {:ok, _send, ctx} = Transport.send_stream(ctx, server_control, server_setup())
        send(parent, :setup_complete)

        receive do
          :close_relay -> :ok
        end

        {:ok, _ctx} = Transport.close_connection(ctx, conn, 77)
      end)

    assert_receive {:relay_ready, port}, 1_000

    assert {:ok, client} =
             MOQX.connect("moqt://localhost:#{port}",
               protocol: :draft_18,
               transport: {Support, network: network, profile: :draft_18},
               events_to: router,
               timeout: 1_000
             )

    assert_receive :setup_complete, 1_000
    send(relay.pid, :close_relay)

    assert_receive {:routed, {:moqx, ^client, %MOQX.Event.ConnectionClosed{metadata: metadata}}},
                   1_000

    assert metadata.error_code == 77
    assert {:ok, %Transport.Context{}} = Task.await(relay, 1_000)
    send(router, :stop)
  end

  test "events_to must be a pid" do
    assert {:error, :events_to_must_be_a_pid} =
             MOQX.connect("moqt://relay.example",
               protocol: :draft_18,
               events_to: :registered_name
             )
  end

  defp route_events(parent) do
    receive do
      :stop ->
        :ok

      event ->
        send(parent, {:routed, event})
        route_events(parent)
    end
  end

  defp server_setup, do: <<0xAF, 0, 0, 0>>
end
