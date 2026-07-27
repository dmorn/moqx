defmodule MOQX.Draft16CatalogTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  test "emits draft-16 objects in transport arrival order with subgroup boundaries" do
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

        authority = "localhost:#{port}"

        client_setup =
          frame(0x20, [
            encode_varint(3),
            encode_bytes_parameter(1, ""),
            encode_integer_parameter(1, 100),
            encode_bytes_parameter(3, authority)
          ])

        assert {:ok, ^client_setup, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(client_setup))

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x21, 0, 1, 0>>)

        subscribe =
          frame(0x03, [
            encode_varint(0),
            encode_tuple(["moqtail", "testsrc"]),
            encode_bytes("catalog"),
            encode_varint(2),
            encode_integer_parameter(0x20, 127),
            encode_bytes_parameter(1, encode_varint(1))
          ])

        assert {:ok, ^subscribe, ctx} =
                 Transport.recv_stream(ctx, control, byte_size(subscribe))

        {:ok, _send, ctx} = Transport.send_stream(ctx, control, <<0x04, 0, 3, 0, 7, 0>>)
        {:ok, ctx} = Transport.send_datagram(ctx, conn, <<0x06, 7, 8, 17, "dgram">>)

        assert_receive :send_subgroups, 1_000

        {:ok, later, ctx} = Transport.open_stream(ctx, conn, direction: :unidirectional)

        {:ok, _send, ctx} =
          Transport.send_stream(ctx, later, <<0x34, 7, 10, 1, 0, 5, "later">>)

        assert_receive :send_earlier_subgroup, 1_000

        {:ok, earlier, ctx} = Transport.open_stream(ctx, conn, direction: :unidirectional)

        {:ok, _send, ctx} =
          Transport.send_stream(ctx, earlier, <<0x34, 7, 9, 3, 0, 7, "earlier">>)

        assert_receive :finish_earlier_subgroup, 1_000
        {:ok, ctx} = Transport.finish_sending(ctx, earlier)

        assert_receive :finish_later_subgroup, 1_000
        {:ok, _ctx} = Transport.finish_sending(ctx, later)
        :ok
      end)

    assert_receive {:relay_ready, port}, 1_000

    assert {:ok, client} =
             MOQX.connect("moqt://localhost:#{port}",
               protocol: :draft_16,
               transport: {Support, network: network, profile: :draft_16},
               timeout: 1_000
             )

    track = %MOQX.TrackRef{namespace: ["moqtail", "testsrc"], track: "catalog"}

    assert {:ok, %MOQX.Subscription{} = subscription} =
             MOQX.subscribe(client, track, start: :next_group, priority: 127)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.SubscriptionAccepted{subscription: ^subscription}},
                   1_000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.ObjectReceived{
                      object: %MOQX.Object{
                        subscription: ^subscription,
                        group_id: 8,
                        object_id: 0,
                        publisher_priority: 17,
                        end_of_group?: true,
                        payload: "dgram"
                      }
                    }},
                   1_000

    send(relay.pid, :send_subgroups)

    assert_receive {:moqx, ^client, %MOQX.Event.ObjectReceived{object: first}}, 1_000

    assert %MOQX.Object{
             subscription: ^subscription,
             group_id: 10,
             subgroup_id: 1,
             object_id: 0,
             publisher_priority: nil,
             payload: "later"
           } = first

    send(relay.pid, :send_earlier_subgroup)

    assert_receive {:moqx, ^client, %MOQX.Event.ObjectReceived{object: second}}, 1_000

    assert %MOQX.Object{
             subscription: ^subscription,
             group_id: 9,
             subgroup_id: 3,
             object_id: 0,
             publisher_priority: nil,
             payload: "earlier"
           } = second

    send(relay.pid, :finish_earlier_subgroup)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.SubgroupEnded{
                      subscription: ^subscription,
                      group_id: 9,
                      subgroup_id: 3,
                      outcome: :complete,
                      end_of_group?: false
                    }},
                   1_000

    send(relay.pid, :finish_later_subgroup)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.SubgroupEnded{
                      subscription: ^subscription,
                      group_id: 10,
                      subgroup_id: 1,
                      outcome: :complete,
                      end_of_group?: false
                    }},
                   1_000

    assert :ok = Task.await(relay, 1_000)
  end

  defp frame(type, payload) do
    payload = IO.iodata_to_binary(payload)
    IO.iodata_to_binary([encode_varint(type), <<byte_size(payload)::16>>, payload])
  end

  defp encode_tuple(fields),
    do: [encode_varint(length(fields)) | Enum.map(fields, &encode_bytes/1)]

  defp encode_bytes(value), do: [encode_varint(byte_size(value)), value]
  defp encode_integer_parameter(delta, value), do: [encode_varint(delta), encode_varint(value)]
  defp encode_bytes_parameter(delta, value), do: [encode_varint(delta), encode_bytes(value)]
  defp encode_varint(value) when value < 64, do: <<value>>
  defp encode_varint(value) when value < 16_384, do: <<value ||| 0x4000::16>>
end
