defmodule MOQX.Integration.MOQLite05TrackWithdrawalTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias MOQX.Protocol.MOQLite05.Codec
  alias MOQX.Protocol.MOQLite05.Messages.Subscribe
  alias MOQX.Transport
  alias MOQX.Transport.Quicer

  @cert_dir ".tmp/integration-certs"

  test "a withdrawn track is refused over native QUIC while its sibling remains operational" do
    parent = self()

    relay =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Quicer)

        {:ok, listener, ctx} =
          Transport.listen(ctx, "127.0.0.1:0",
            alpn: "moq-lite-05",
            certfile: Path.join(@cert_dir, "server.pem"),
            keyfile: Path.join(@cert_dir, "server-key.pem"),
            peer_bidi_stream_count: 128,
            peer_unidi_stream_count: 128
          )

        {:ok, {_ip, port}} = Transport.local_address(ctx, listener)
        send(parent, {:relay_ready, port})

        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 5_000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 5_000)
        {:ok, setup, ctx} = Transport.accept_stream(ctx, conn, [], 5_000)
        assert {:ok, <<1, 7, 2, 2, 1, "/", 3, 1, 1>>, ctx} = Transport.recv_stream(ctx, setup, 9)

        receive do
          :tracks_ready -> :ok
        after
          5_000 -> flunk("publisher did not register the tracks")
        end

        send(parent, :withdraw_now)

        receive do
          :track_withdrawn -> :ok
        after
          5_000 -> flunk("publisher did not withdraw the video track")
        end

        {:ok, video, ctx} = Transport.open_stream(ctx, conn, direction: :bidirectional)

        video_request = %Subscribe{
          subscribe_id: 41,
          broadcast_path: "live",
          track_name: "video",
          subscriber_priority: 9
        }

        {:ok, _send, ctx} =
          Transport.send_stream(ctx, video, <<2, Codec.encode_subscribe(video_request)::binary>>)

        {:ok, ctx} = Transport.set_active(ctx, video, true)
        {:ok, ctx} = await_stream_abort(ctx, video, 0x10)
        send(parent, :video_refused)

        {:ok, audio, ctx} = Transport.open_stream(ctx, conn, direction: :bidirectional)

        audio_request = %Subscribe{
          subscribe_id: 43,
          broadcast_path: "live",
          track_name: "audio",
          subscriber_priority: 9
        }

        {:ok, _send, ctx} =
          Transport.send_stream(ctx, audio, <<2, Codec.encode_subscribe(audio_request)::binary>>)

        send(parent, :audio_subscribed)
        assert {:ok, <<0, 1, 1>>, ctx} = Transport.recv_stream(ctx, audio, 3)

        {:ok, group, ctx} = Transport.accept_stream(ctx, conn, [], 5_000)
        expected_group = <<0, 2, 43, 1, 2, 1, "a">>
        {:ok, ctx} = Transport.set_active(ctx, group, true)
        {:ok, ^expected_group, ctx} = await_stream_data(ctx, group)

        {:ok, _ctx} = Transport.close_connection(ctx, conn, 0)
        :ok
      end)

    assert_receive {:relay_ready, port}, 5_000

    assert {:ok, client} =
             MOQX.connect("moqt://127.0.0.1:#{port}",
               protocol: :moq_lite_05,
               role: :publisher,
               connect_options: [
                 cacertfile: Path.join(@cert_dir, "ca.pem"),
                 server_name: "localhost"
               ],
               timeout: 5_000
             )

    assert {:ok, publication} = MOQX.publish(client, ["live"])

    assert {:ok, video} = MOQX.add_track(client, publication, "video", timescale: 90_000)
    assert {:ok, audio} = MOQX.add_track(client, publication, "audio", timescale: 48_000)
    send(relay.pid, :tracks_ready)

    assert_receive :withdraw_now, 5_000
    assert :ok = MOQX.withdraw_track(client, video)
    send(relay.pid, :track_withdrawn)

    assert_receive :video_refused, 5_000
    assert_receive :audio_subscribed, 5_000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriberJoined{track: ^audio, request_id: 43}},
                   5_000

    assert :ok =
             MOQX.publish_object(client, audio, %MOQX.Object{
               group_id: 1,
               object_id: 0,
               timestamp: 1,
               end_of_group?: true,
               payload: "a"
             })

    assert :ok = Task.await(relay, 5_000)
  end

  defp await_stream_abort(ctx, stream, error_code) do
    case Transport.receive_event(ctx, 5_000) do
      {:ok, {:stream_event, ^stream, :peer_aborted_sending, %{error_code: ^error_code}}, ctx} ->
        {:ok, ctx}

      {:ok, _event, ctx} ->
        await_stream_abort(ctx, stream, error_code)

      {:unknown, _message, ctx} ->
        await_stream_abort(ctx, stream, error_code)

      {:timeout, ctx} ->
        {:error, :timeout, ctx}

      {:error, reason, ctx} ->
        {:error, reason, ctx}
    end
  end

  defp await_stream_data(ctx, stream) do
    case Transport.receive_event(ctx, 5_000) do
      {:ok, {:stream_data, ^stream, data, _metadata}, ctx} ->
        {:ok, data, ctx}

      {:ok, _event, ctx} ->
        await_stream_data(ctx, stream)

      {:unknown, _message, ctx} ->
        await_stream_data(ctx, stream)

      {:timeout, ctx} ->
        {:error, :timeout, ctx}

      {:error, reason, ctx} ->
        {:error, reason, ctx}
    end
  end
end
