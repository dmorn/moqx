defmodule MOQX.TrackMetadataDemandTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQLite05.Codec
  alias MOQX.Protocol.MOQLite05.Messages.{Subscribe, Track}
  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  test "registering an absent track answers its metadata demand without subscribing" do
    {client, relay} = connect()
    {:ok, publication} = MOQX.publish(client, ["live"], missing_track_metadata: :controlled)
    send(relay.pid, {:request, :video, "video"})

    assert_receive {:moqx, ^client,
                    %{__struct__: MOQX.Event.PublicationTrackRequested, request: request}},
                   1_000

    assert request.publication == publication
    assert request.track == %MOQX.TrackRef{namespace: ["live"], track: "video"}
    assert request.timeout_ms == 5_000

    {:ok, _track} =
      MOQX.add_track(client, publication, "video",
        timescale: 90_000,
        publisher_priority: 17,
        publisher_max_latency: 1_000
      )

    send(relay.pid, {:read, :video, 9})
    assert_receive {:bytes, :video, <<8, 17, 0, 0x43, 0xE8, 0x80, 0x01, 0x5F, 0x90>>}, 1_000

    assert_receive {:moqx, ^client,
                    %{
                      __struct__: MOQX.Event.PublicationTrackRequestDone,
                      request: ^request,
                      reason: :registered
                    }},
                   1_000

    refute_receive {:moqx, ^client, %MOQX.Event.PublicationSubscriberJoined{}}, 50
    :ok = MOQX.close(client)
    send(relay.pid, :stop)
    Task.await(relay)
  end

  test "reactive subscription acceptance resolves concurrent track metadata demand" do
    {client, relay} = connect()

    {:ok, _} =
      MOQX.publish(client, ["live"],
        missing_track_metadata: :controlled,
        inbound_subscriptions: :controlled
      )

    send(relay.pid, {:request, :video, "video"})

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: metadata}},
                   1_000

    send(relay.pid, {:subscribe, "video"})

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationSubscriptionRequested{request: admission}},
                   1_000

    assert {:ok, _, _} =
             MOQX.accept_subscription(client, admission, timescale: 1, publisher_priority: 17)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationTrackRequestDone{
                      request: ^metadata,
                      reason: :registered
                    }},
                   1_000

    send(relay.pid, {:read, :video, 5})
    assert_receive {:bytes, :video, <<4, 17, 0, 0, 1>>}, 1_000
    :ok = MOQX.close(client)
    send(relay.pid, :stop)
    Task.await(relay)
  end

  test "default missing-track policy rejects without creating application demand" do
    {client, relay} = connect()
    {:ok, _} = MOQX.publish(client, ["live"])
    send(relay.pid, {:request, :missing, "video"})
    send(relay.pid, {:abort, :missing, 0x10})
    assert_receive {:aborted, :missing}, 1_000
    refute_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{}}, 20
    :ok = MOQX.close(client)
    send(relay.pid, :stop)
    Task.await(relay)
  end

  defp connect(options \\ []) do
    {:ok, network} = Support.start_network()
    parent = self()

    relay =
      Task.async(fn ->
        {:ok, ctx} = Transport.new(Support, network: network, profile: :moq_lite_05)
        {:ok, listener, ctx} = Transport.listen(ctx, 0)
        {:ok, {_, port}} = Transport.local_address(ctx, listener)
        send(parent, {:ready, port})
        {:ok, conn, ctx} = Transport.accept(ctx, listener, [], 1_000)
        {:ok, conn, ctx} = Transport.handshake(ctx, conn, 1_000)
        {:ok, setup, ctx} = Transport.accept_stream(ctx, conn, [], 1_000)
        {:ok, _, ctx} = Transport.recv_stream(ctx, setup, 9)
        relay_loop(ctx, conn, parent, %{})
      end)

    assert_receive {:ready, port}, 1_000

    {:ok, client} =
      MOQX.connect("moqt://localhost:#{port}",
        protocol: :moq_lite_05,
        role: :publisher,
        transport: {Support, network: network, profile: :moq_lite_05},
        events_to: Keyword.get(options, :events_to, self())
      )

    {client, relay}
  end

  test "rejection and publication withdrawal release an unfinished request's receiving half" do
    for outcome <- [:reject, :withdraw] do
      {client, relay} = connect()
      {:ok, publication} = MOQX.publish(client, ["live"], missing_track_metadata: :controlled)
      send(relay.pid, {:request_open, :video, "video"})

      assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: request}},
                     1_000

      code =
        case outcome do
          :reject ->
            :ok =
              MOQX.reject_track_request(client, request, %MOQX.SubscriptionRejection{
                code: :unauthorized
              })

            1

          :withdraw ->
            :ok = MOQX.finish_publication(client, publication)
            0x10
        end

      send(relay.pid, {:stopped, :video, code})
      assert_receive {:stopped, :video}, 1_000
      :ok = MOQX.close(client)
      send(relay.pid, :stop)
      Task.await(relay)
    end
  end

  test "a timed-out request closes both stream halves even if the peer never sends FIN" do
    {client, relay} = connect()

    {:ok, _} =
      MOQX.publish(client, ["live"],
        missing_track_metadata: :controlled,
        track_metadata_timeout: 30
      )

    send(relay.pid, {:request_open, :video, "video"})

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: request}},
                   1_000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationTrackRequestDone{request: ^request, reason: :timed_out}},
                   1_000

    send(relay.pid, {:stopped, :video, 2})
    assert_receive {:stopped, :video}, 1_000
    :ok = MOQX.close(client)
    send(relay.pid, :stop)
    Task.await(relay)
  end

  test "registration resolves all concurrent demands once and cancels their deadlines" do
    {client, relay} = connect()

    {:ok, publication} =
      MOQX.publish(client, ["live"],
        missing_track_metadata: :controlled,
        track_metadata_timeout: 200
      )

    send(relay.pid, {:request, :one, "video"})
    send(relay.pid, {:request, :two, "video"})
    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: one}}, 1_000
    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: two}}, 1_000
    {:ok, _} = MOQX.add_track(client, publication, "video", timescale: 1, publisher_priority: 17)

    for {key, request} <- [one: one, two: two] do
      assert_receive {:moqx, ^client,
                      %MOQX.Event.PublicationTrackRequestDone{
                        request: ^request,
                        reason: :registered
                      }},
                     1_000

      send(relay.pid, {:read, key, 5})
      assert_receive {:bytes, ^key, <<4, 17, 0, 0, 1>>}, 1_000
    end

    send(relay.pid, {:request, :barrier, "missing"})

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: barrier}},
                   1_000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationTrackRequestDone{request: ^barrier, reason: :timed_out}},
                   1_000

    refute_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequestDone{}}, 20
    :ok = MOQX.close(client)
    send(relay.pid, :stop)
    Task.await(relay)
  end

  test "extra data on a pending Track stream terminates that request once" do
    {client, relay} = connect()
    {:ok, _} = MOQX.publish(client, ["live"], missing_track_metadata: :controlled)
    send(relay.pid, {:request_open, :video, "video"})

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: request}},
                   1_000

    send(relay.pid, {:extra, :video})

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationTrackRequestDone{
                      request: ^request,
                      reason: :invalid_request
                    }},
                   1_000

    send(relay.pid, {:abort, :video, 2})
    assert_receive {:aborted, :video}, 1_000
    refute_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{}}, 20
    :ok = MOQX.close(client)
    send(relay.pid, :stop)
    Task.await(relay)
  end

  test "a foreign connection cannot decide or invalidate another connection's demand" do
    {first, relay1} = connect()
    {second, relay2} = connect()
    {:ok, publication} = MOQX.publish(first, ["live"], missing_track_metadata: :controlled)
    send(relay1.pid, {:request, :video, "video"})
    assert_receive {:moqx, ^first, %MOQX.Event.PublicationTrackRequested{request: request}}, 1_000

    assert {:error, :stale_track_request} =
             MOQX.reject_track_request(second, request, %MOQX.SubscriptionRejection{
               code: :unauthorized
             })

    {:ok, _} = MOQX.add_track(first, publication, "video", timescale: 1)

    assert_receive {:moqx, ^first,
                    %MOQX.Event.PublicationTrackRequestDone{
                      request: ^request,
                      reason: :registered
                    }},
                   1_000

    for {client, relay} <- [{first, relay1}, {second, relay2}] do
      :ok = MOQX.close(client)
      send(relay.pid, :stop)
      Task.await(relay)
    end
  end

  test "connection event owner exit closes the transport and releases its pending work" do
    parent = self()
    owner = spawn(fn -> forward_events(parent) end)
    {client, relay} = connect(events_to: owner)
    monitor = Process.monitor(client.pid)
    {:ok, _} = MOQX.publish(client, ["live"], missing_track_metadata: :controlled)
    send(relay.pid, {:request, :video, "video"})
    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{}}, 1_000
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
    send(relay.pid, :await_close)
    assert_receive :connection_closed, 1_000
    send(relay.pid, :stop)
    Task.await(relay)
  end

  defp forward_events(parent) do
    receive do
      :stop ->
        :ok

      message ->
        send(parent, message)
        forward_events(parent)
    end
  end

  test "pending metadata limit rejects overflow and releases capacity after cancellation" do
    {client, relay} = connect()

    {:ok, publication} =
      MOQX.publish(client, ["live"],
        missing_track_metadata: :controlled,
        max_pending_track_metadata: 1
      )

    send(relay.pid, {:request, :first, "video"})
    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: first}}, 1_000
    send(relay.pid, {:request, :overflow, "audio"})
    send(relay.pid, {:abort, :overflow, 0x10})
    assert_receive {:aborted, :overflow}, 1_000
    refute_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{}}, 20
    send(relay.pid, {:cancel, :first})

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequestDone{request: ^first}},
                   1_000

    send(relay.pid, {:request, :new, "audio"})
    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: next}}, 1_000
    {:ok, _} = MOQX.add_track(client, publication, "audio", timescale: 1)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationTrackRequestDone{request: ^next, reason: :registered}},
                   1_000

    :ok = MOQX.close(client)
    send(relay.pid, :stop)
    Task.await(relay)
  end

  test "publication rejects invalid metadata policy and resource bounds before advertising" do
    {client, relay} = connect()

    for options <- [
          [missing_track_metadata: :unknown],
          [missing_track_metadata: :controlled, track_metadata_timeout: -1],
          [missing_track_metadata: :controlled, track_metadata_timeout: :infinity],
          [missing_track_metadata: :controlled, max_pending_track_metadata: 0],
          [missing_track_metadata: :reject, track_metadata_timeout: -1]
        ] do
      assert {:error, :invalid_track_metadata_options} = MOQX.publish(client, ["live"], options)
    end

    assert {:ok, _} = MOQX.publish(client, ["live"], missing_track_metadata: :controlled)
    :ok = MOQX.close(client)
    send(relay.pid, :stop)
    Task.await(relay)
  end

  test "peer connection close terminates metadata demand before the connection event" do
    {client, relay} = connect()
    {:ok, _} = MOQX.publish(client, ["live"], missing_track_metadata: :controlled)
    send(relay.pid, {:request, :video, "video"})

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: request}},
                   1_000

    send(relay.pid, :close)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationTrackRequestDone{
                      request: ^request,
                      reason: :connection_closed
                    }},
                   1_000

    assert_receive {:moqx, ^client, %MOQX.Event.ConnectionClosed{}}, 1_000
    send(relay.pid, :stop)
    Task.await(relay)
  end

  test "local connection close ends each pending demand" do
    {client, relay} = connect()
    {:ok, _} = MOQX.publish(client, ["live"], missing_track_metadata: :controlled)
    send(relay.pid, {:request, :video, "video"})

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: request}},
                   1_000

    assert :ok = MOQX.close(client)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationTrackRequestDone{
                      request: ^request,
                      reason: :connection_closed
                    }},
                   1_000

    send(relay.pid, :stop)
    Task.await(relay)
  end

  test "publication withdrawal cancels its demands and allows namespace reuse" do
    {client, relay} = connect()
    {:ok, publication} = MOQX.publish(client, ["live"], missing_track_metadata: :controlled)
    send(relay.pid, {:request, :old, "video"})

    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: request}},
                   1_000

    assert :ok = MOQX.finish_publication(client, publication)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationTrackRequestDone{
                      request: ^request,
                      reason: :publication_finished
                    }},
                   1_000

    assert {:error, :stale_track_request} =
             MOQX.reject_track_request(client, request, %MOQX.SubscriptionRejection{
               code: :unauthorized
             })

    {:ok, replacement} = MOQX.publish(client, ["live"], missing_track_metadata: :controlled)
    send(relay.pid, {:request, :new, "video"})
    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: next}}, 1_000
    assert next.publication == replacement
    {:ok, _} = MOQX.add_track(client, replacement, "video", timescale: 1)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationTrackRequestDone{request: ^next, reason: :registered}},
                   1_000

    :ok = MOQX.close(client)
    send(relay.pid, :stop)
    Task.await(relay)
  end

  test "peer cancellation releases its pending slot without cancelling another request" do
    {client, relay} = connect()
    {:ok, publication} = MOQX.publish(client, ["live"], missing_track_metadata: :controlled)
    send(relay.pid, {:request, :cancelled, "video"})
    send(relay.pid, {:request, :survivor, "video"})
    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: first}}, 1_000
    assert_receive {:moqx, ^client, %MOQX.Event.PublicationTrackRequested{request: second}}, 1_000
    send(relay.pid, {:cancel, :cancelled})

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationTrackRequestDone{
                      request: ^first,
                      reason: :peer_cancelled
                    }},
                   1_000

    assert {:error, :stale_track_request} =
             MOQX.reject_track_request(client, first, %MOQX.SubscriptionRejection{
               code: :unauthorized
             })

    {:ok, _} = MOQX.add_track(client, publication, "video", timescale: 1)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.PublicationTrackRequestDone{request: ^second, reason: :registered}},
                   1_000

    :ok = MOQX.close(client)
    send(relay.pid, :stop)
    Task.await(relay)
  end

  test "rejects one concurrent metadata request without cancelling its sibling" do
    {client, relay} = connect()
    {:ok, publication} = MOQX.publish(client, ["live"], missing_track_metadata: :controlled)
    send(relay.pid, {:request, :first, "video"})
    send(relay.pid, {:request, :second, "video"})

    assert_receive {:moqx, ^client,
                    %{__struct__: MOQX.Event.PublicationTrackRequested, request: first}},
                   1_000

    assert_receive {:moqx, ^client,
                    %{__struct__: MOQX.Event.PublicationTrackRequested, request: second}},
                   1_000

    rejection = %MOQX.SubscriptionRejection{code: :unauthorized, reason: "not allowed"}
    assert :ok = MOQX.reject_track_request(client, first, rejection)

    assert_receive {:moqx, ^client,
                    %{
                      __struct__: MOQX.Event.PublicationTrackRequestDone,
                      request: ^first,
                      reason: :rejected
                    }},
                   1_000

    assert {:error, :stale_track_request} = MOQX.reject_track_request(client, first, rejection)
    send(relay.pid, {:abort, :first, 1})
    assert_receive {:aborted, :first}, 1_000
    {:ok, _} = MOQX.add_track(client, publication, "video", timescale: 1)

    assert_receive {:moqx, ^client,
                    %{
                      __struct__: MOQX.Event.PublicationTrackRequestDone,
                      request: ^second,
                      reason: :registered
                    }},
                   1_000

    refute_receive {:moqx, ^client,
                    %{__struct__: MOQX.Event.PublicationTrackRequestDone, request: ^first}},
                   50

    :ok = MOQX.close(client)
    send(relay.pid, :stop)
    Task.await(relay)
  end

  test "metadata demand expires and a fresh request can provision the same track" do
    {client, relay} = connect()

    {:ok, publication} =
      MOQX.publish(client, ["live"],
        missing_track_metadata: :controlled,
        track_metadata_timeout: 30
      )

    send(relay.pid, {:request, :old, "video"})

    assert_receive {:moqx, ^client,
                    %{__struct__: MOQX.Event.PublicationTrackRequested, request: request}},
                   1_000

    assert_receive {:moqx, ^client,
                    %{
                      __struct__: MOQX.Event.PublicationTrackRequestDone,
                      request: ^request,
                      reason: :timed_out
                    }},
                   1_000

    send(relay.pid, {:abort, :old, 2})
    assert_receive {:aborted, :old}, 1_000
    send(relay.pid, {:request, :new, "video"})

    assert_receive {:moqx, ^client,
                    %{__struct__: MOQX.Event.PublicationTrackRequested, request: next}},
                   1_000

    refute next.handle == request.handle
    {:ok, _} = MOQX.add_track(client, publication, "video", timescale: 1)

    assert_receive {:moqx, ^client,
                    %{
                      __struct__: MOQX.Event.PublicationTrackRequestDone,
                      request: ^next,
                      reason: :registered
                    }},
                   1_000

    :ok = MOQX.close(client)
    send(relay.pid, :stop)
    Task.await(relay)
  end

  defp relay_loop(ctx, conn, parent, streams) do
    receive do
      {:request, key, name} ->
        {:ok, stream, ctx} = Transport.open_stream(ctx, conn, direction: :bidirectional)

        bytes =
          <<6, Codec.encode_track(%Track{broadcast_path: "live", track_name: name})::binary>>

        {:ok, _, ctx} = Transport.send_stream(ctx, stream, bytes, finish: true)
        relay_loop(ctx, conn, parent, Map.put(streams, key, stream))

      {:subscribe, name} ->
        {:ok, stream, ctx} = Transport.open_stream(ctx, conn, direction: :bidirectional)

        request = %Subscribe{
          subscribe_id: 42,
          broadcast_path: "live",
          track_name: name,
          subscriber_priority: 9
        }

        {:ok, _, ctx} =
          Transport.send_stream(ctx, stream, <<2, Codec.encode_subscribe(request)::binary>>)

        relay_loop(ctx, conn, parent, streams)

      {:request_open, key, name} ->
        {:ok, stream, ctx} = Transport.open_stream(ctx, conn, direction: :bidirectional)

        bytes =
          <<6, Codec.encode_track(%Track{broadcast_path: "live", track_name: name})::binary>>

        {:ok, _, ctx} = Transport.send_stream(ctx, stream, bytes)
        relay_loop(ctx, conn, parent, Map.put(streams, key, stream))

      {:extra, key} ->
        {:ok, _, ctx} = Transport.send_stream(ctx, Map.fetch!(streams, key), <<0>>)
        relay_loop(ctx, conn, parent, streams)

      {:read, key, size} ->
        {:ok, bytes, ctx} = Transport.recv_stream(ctx, Map.fetch!(streams, key), size)
        send(parent, {:bytes, key, bytes})
        relay_loop(ctx, conn, parent, streams)

      {:abort, key, code} ->
        stream = Map.fetch!(streams, key)
        {:ok, ctx} = Transport.set_active(ctx, stream, true)
        ctx = await_abort(ctx, stream, code)
        send(parent, {:aborted, key})
        relay_loop(ctx, conn, parent, streams)

      {:stopped, key, code} ->
        stream = Map.fetch!(streams, key)
        {:ok, ctx} = Transport.set_active(ctx, stream, true)
        ctx = await_stopped(ctx, stream, code)
        send(parent, {:stopped, key})
        relay_loop(ctx, conn, parent, streams)

      {:cancel, key} ->
        {:ok, ctx} = Transport.abort_receiving(ctx, Map.fetch!(streams, key), 0)
        relay_loop(ctx, conn, parent, streams)

      :close ->
        {:ok, ctx} = Transport.close_connection(ctx, conn, 99)
        relay_loop(ctx, conn, parent, streams)

      :await_close ->
        ctx = await_close(ctx, conn)
        send(parent, :connection_closed)
        relay_loop(ctx, conn, parent, streams)

      :stop ->
        :ok
    after
      5_000 -> flunk("relay command timeout")
    end
  end

  defp await_abort(ctx, stream, code) do
    case Transport.receive_event(ctx, 1_000) do
      {:ok, {:stream_event, ^stream, :peer_aborted_sending, %{error_code: ^code}}, ctx} -> ctx
      {:ok, _, ctx} -> await_abort(ctx, stream, code)
      {:unknown, _, ctx} -> await_abort(ctx, stream, code)
      other -> flunk("expected stream reset, got #{inspect(other)}")
    end
  end

  defp await_stopped(ctx, stream, code) do
    case Transport.receive_event(ctx, 1_000) do
      {:ok, {:stream_event, ^stream, :peer_aborted_receiving, %{error_code: ^code}}, ctx} -> ctx
      {:ok, _, ctx} -> await_stopped(ctx, stream, code)
      {:unknown, _, ctx} -> await_stopped(ctx, stream, code)
      other -> flunk("expected STOP_SENDING, got #{inspect(other)}")
    end
  end

  defp await_close(ctx, conn) do
    case Transport.receive_event(ctx, 1_000) do
      {:ok, {:connection_event, ^conn, :closed, _}, ctx} -> ctx
      {:ok, _, ctx} -> await_close(ctx, conn)
      {:unknown, _, ctx} -> await_close(ctx, conn)
      other -> flunk("expected connection close, got #{inspect(other)}")
    end
  end
end
