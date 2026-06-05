defmodule MOQX.MOQLite04.SessionTest do
  use ExUnit.Case, async: true

  alias MOQX.MOQLite04
  alias MOQX.MOQLite04.Error
  alias MOQX.MOQLite04.Session
  alias MOQX.MOQLite04.StreamCodec
  alias MOQX.Transport.{BackendRef, Connection, Stream, StreamInfo, Support}

  describe "session start" do
    test "starts active without emitting setup work" do
      session = Session.new()

      assert %Session{alpn: "moq-lite-04"} = session

      assert Session.handle_transport(session, {:datagram, :connection, "ignored", %{}}) ==
               :unknown
    end
  end

  describe "incoming stream classification" do
    test "aborts unknown stream types without closing the session" do
      stream = stream(0)

      assert {:error, session, %Error{reason: :unexpected_stream, code: 10}, [], actions} =
               Session.handle_transport(
                 Session.new(),
                 {:stream_data, stream, <<0x06, 0x00>>, %{}}
               )

      assert session.streams == %{}

      assert actions == [
               {:abort_receiving, stream, 10},
               {:abort_sending, stream, 10}
             ]

      refute Enum.any?(actions, &match?({:close_connection, _, _}, &1))
    end

    test "classifies peer streams and emits decoded messages with a stream ref" do
      stream = stream(4)
      subscribe = subscribe_message()

      assert {:ok, bytes} = StreamCodec.encode(:subscribe, [subscribe])

      assert {:ok, _session, events, []} =
               Session.handle_transport(Session.new(), {:stream_data, stream, bytes, %{}})

      assert events == [
               {:stream_started, 0, stream, :subscribe},
               {:message, 0, stream, subscribe}
             ]
    end

    test "keeps later bytes on the same stream under the existing stream ref" do
      stream = stream(8)
      subscribe = subscribe_message()

      update = %MOQLite04.SubscribeUpdate{
        subscriber_priority: 64,
        subscriber_ordered: :descending,
        subscriber_max_latency: 1_000,
        start_group: 12,
        end_group: 0
      }

      codec = StreamCodec.new(side: :opener, stream_type: :subscribe)
      assert {:ok, codec, first_bytes} = StreamCodec.encode_next(codec, [subscribe])
      assert {:ok, _codec, second_bytes} = StreamCodec.encode_next(codec, [update])

      assert {:ok, session, _events, []} =
               Session.handle_transport(Session.new(), {:stream_data, stream, first_bytes, %{}})

      assert {:ok, _session, events, []} =
               Session.handle_transport(session, {:stream_data, stream, second_bytes, %{}})

      assert events == [
               {:message, 0, stream, update}
             ]
    end
  end

  describe "local commands" do
    test "encodes opener messages as send-stream transport actions" do
      local_stream = stream(12, initiator: :local)
      peer_stream = stream(12, initiator: :peer)
      subscribe = subscribe_message()

      assert {:ok, _session, [], [{:send_stream, ^local_stream, bytes, []}]} =
               Session.handle_command(
                 Session.new(),
                 {:send, local_stream, :subscribe, [subscribe]}
               )

      assert {:ok, _peer_session, events, []} =
               Session.handle_transport(Session.new(), {:stream_data, peer_stream, bytes, %{}})

      assert events == [
               {:stream_started, 0, peer_stream, :subscribe},
               {:message, 0, peer_stream, subscribe}
             ]
    end

    test "encodes later opener messages on the same stream incrementally" do
      local_stream = stream(16, initiator: :local)
      peer_stream = stream(16, initiator: :peer)
      subscribe = subscribe_message()

      update = %MOQLite04.SubscribeUpdate{
        subscriber_priority: 64,
        subscriber_ordered: :descending,
        subscriber_max_latency: 1_000,
        start_group: 12,
        end_group: 0
      }

      assert {:ok, local_session, [], [{:send_stream, ^local_stream, first_bytes, []}]} =
               Session.handle_command(
                 Session.new(),
                 {:send, local_stream, :subscribe, [subscribe]}
               )

      assert {:ok, _local_session, [], [{:send_stream, ^local_stream, second_bytes, []}]} =
               Session.handle_command(local_session, {:send, local_stream, :subscribe, [update]})

      assert {:ok, peer_session, _events, []} =
               Session.handle_transport(
                 Session.new(),
                 {:stream_data, peer_stream, first_bytes, %{}}
               )

      assert {:ok, _peer_session, events, []} =
               Session.handle_transport(
                 peer_session,
                 {:stream_data, peer_stream, second_bytes, %{}}
               )

      assert events == [
               {:message, 0, peer_stream, update}
             ]
    end

    test "returns stream shutdown transport actions as data" do
      stream = stream(18, initiator: :local)
      session = Session.new()

      assert {:ok, ^session, [], [{:finish_sending, ^stream}]} =
               Session.handle_command(session, {:finish_sending, stream})

      assert {:ok, ^session, [], [{:abort_sending, ^stream, 13}]} =
               Session.handle_command(session, {:abort_sending, stream, :not_found})

      assert {:ok, ^session, [], [{:abort_receiving, ^stream, 15}]} =
               Session.handle_command(
                 session,
                 {:abort_receiving, stream, Error.new(:protocol_violation)}
               )
    end

    test "returns connection-close transport actions as data" do
      connection = %Connection{
        backend: %BackendRef{module: __MODULE__, data: :connection},
        local_role: :client
      }

      session = Session.new()

      assert {:ok, ^session, [], [{:close_connection, ^connection, 25}]} =
               Session.handle_command(session, {:close_connection, connection, :closed})
    end
  end

  describe "subscribe state" do
    test "rejects SubscribeDrop before the first SubscribeOk on a subscribe stream" do
      stream = stream(20, initiator: :local)
      subscribe = subscribe_message()
      drop = %MOQLite04.SubscribeDrop{start_group: 12, end_group: 12, error_code: 99}

      assert {:ok, session, [], [{:send_stream, ^stream, _bytes, []}]} =
               Session.handle_command(Session.new(), {:send, stream, :subscribe, [subscribe]})

      assert {:ok, drop_bytes} = StreamCodec.encode(:subscribe, [drop], side: :responder)

      assert {:error, _session, %Error{reason: :protocol_violation, code: 15}, [], actions} =
               Session.handle_transport(session, {:stream_data, stream, drop_bytes, %{}})

      assert actions == [
               {:abort_receiving, stream, 15},
               {:abort_sending, stream, 15}
             ]
    end

    test "accepts SubscribeDrop after SubscribeOk on the same stream" do
      stream = stream(24, initiator: :local)
      subscribe = subscribe_message()

      ok = %MOQLite04.SubscribeOk{
        publisher_priority: 192,
        publisher_ordered: :ascending,
        publisher_max_latency: 250,
        start_group: 11,
        end_group: 0
      }

      drop = %MOQLite04.SubscribeDrop{start_group: 12, end_group: 12, error_code: 99}

      assert {:ok, session, [], [{:send_stream, ^stream, _bytes, []}]} =
               Session.handle_command(Session.new(), {:send, stream, :subscribe, [subscribe]})

      assert {:ok, ok_bytes} = StreamCodec.encode(:subscribe, [ok], side: :responder)
      assert {:ok, drop_bytes} = StreamCodec.encode(:subscribe, [drop], side: :responder)

      assert {:ok, session, [{:message, 0, ^stream, ^ok}], []} =
               Session.handle_transport(session, {:stream_data, stream, ok_bytes, %{}})

      assert {:ok, _session, [{:message, 0, ^stream, ^drop}], []} =
               Session.handle_transport(session, {:stream_data, stream, drop_bytes, %{}})
    end

    test "rejects sending SubscribeDrop before SubscribeOk" do
      publisher_stream = stream(60, initiator: :peer, local_role: :server)
      drop = %MOQLite04.SubscribeDrop{start_group: 12, end_group: 12, error_code: 99}

      assert {:ok, subscribe_bytes} = StreamCodec.encode(:subscribe, [subscribe_message()])

      assert {:ok, publisher, _events, []} =
               Session.handle_transport(
                 Session.new(),
                 {:stream_data, publisher_stream, subscribe_bytes, %{}}
               )

      assert {:error, ^publisher, %Error{reason: :protocol_violation, code: 15}, [], []} =
               Session.handle_command(publisher, {:send, publisher_stream, :subscribe, [drop]})
    end
  end

  describe "announce state" do
    test "rejects duplicate announce status for the same suffix" do
      stream = stream(32, initiator: :local)

      interest = %MOQLite04.AnnounceInterest{
        broadcast_path_prefix: "/live",
        exclude_hop: 0
      }

      active = %MOQLite04.Announce{
        status: :active,
        broadcast_path_suffix: "/camera-a",
        hop_ids: []
      }

      assert {:ok, session, [], [{:send_stream, ^stream, _bytes, []}]} =
               Session.handle_command(Session.new(), {:send, stream, :announce, [interest]})

      assert {:ok, active_bytes} = StreamCodec.encode(:announce, [active], side: :responder)

      assert {:ok, session, [{:message, 0, ^stream, ^active}], []} =
               Session.handle_transport(session, {:stream_data, stream, active_bytes, %{}})

      assert {:error, _session, %Error{reason: :protocol_violation, code: 15}, [], actions} =
               Session.handle_transport(session, {:stream_data, stream, active_bytes, %{}})

      assert actions == [
               {:abort_receiving, stream, 15},
               {:abort_sending, stream, 15}
             ]
    end

    test "rejects sending duplicate announce status for the same suffix" do
      stream = stream(34, initiator: :peer)

      interest = %MOQLite04.AnnounceInterest{
        broadcast_path_prefix: "/live",
        exclude_hop: 0
      }

      active = %MOQLite04.Announce{
        status: :active,
        broadcast_path_suffix: "/camera-a",
        hop_ids: []
      }

      assert {:ok, interest_bytes} = StreamCodec.encode(:announce, [interest])

      assert {:ok, session, _events, []} =
               Session.handle_transport(
                 Session.new(),
                 {:stream_data, stream, interest_bytes, %{}}
               )

      assert {:ok, session, [], [{:send_stream, ^stream, _active_bytes, []}]} =
               Session.handle_command(session, {:send, stream, :announce, [active]})

      assert {:error, ^session, %Error{reason: :protocol_violation, code: 15}, [], []} =
               Session.handle_command(session, {:send, stream, :announce, [active]})
    end
  end

  describe "goaway" do
    test "records draining state and rejects new local streams" do
      goaway_stream = stream(36, initiator: :peer)
      new_stream = stream(40, initiator: :local)
      goaway = %MOQLite04.Goaway{new_session_uri: "moql://edge.example/live"}

      assert {:ok, bytes} = StreamCodec.encode(:goaway, [goaway])

      assert {:ok, session, events, []} =
               Session.handle_transport(Session.new(), {:stream_data, goaway_stream, bytes, %{}})

      assert session.draining?

      assert events == [
               {:stream_started, 0, goaway_stream, :goaway},
               {:goaway, 0, goaway_stream, "moql://edge.example/live"}
             ]

      assert {:error, ^session, %Error{reason: :closed, code: 25}, [], []} =
               Session.handle_command(
                 session,
                 {:send, new_stream, :subscribe, [subscribe_message()]}
               )
    end
  end

  describe "fetch streams" do
    test "receives fetch frames on the same bidirectional stream without a group header" do
      stream = stream(44, initiator: :local)

      fetch = %MOQLite04.Fetch{
        broadcast_path: "/live",
        track_name: "video",
        subscriber_priority: 128,
        group_sequence: 7
      }

      frames = [
        %MOQLite04.Frame{payload: "first"},
        %MOQLite04.Frame{payload: "second"}
      ]

      assert {:ok, session, [], [{:send_stream, ^stream, _fetch_bytes, []}]} =
               Session.handle_command(Session.new(), {:send, stream, :fetch, [fetch]})

      assert {:ok, frame_bytes} = StreamCodec.encode(:fetch, frames, side: :responder)

      assert {:ok, _session, events, []} =
               Session.handle_transport(session, {:stream_data, stream, frame_bytes, %{}})

      assert events == [
               {:message, 0, stream, Enum.at(frames, 0)},
               {:message, 0, stream, Enum.at(frames, 1)}
             ]
    end
  end

  describe "probe streams" do
    test "supports repeated probes and peer responses on one stream" do
      stream = stream(48, initiator: :local)
      probe = %MOQLite04.Probe{bitrate: 1_000_000, rtt: 0}
      second_probe = %MOQLite04.Probe{bitrate: 1_500_000, rtt: 10}
      response = %MOQLite04.Probe{bitrate: 2_000_000, rtt: 25}

      assert {:ok, session, [], [{:send_stream, ^stream, first_probe_bytes, []}]} =
               Session.handle_command(Session.new(), {:send, stream, :probe, [probe]})

      assert first_probe_bytes != <<>>

      assert {:ok, session, [], [{:send_stream, ^stream, second_probe_bytes, []}]} =
               Session.handle_command(session, {:send, stream, :probe, [second_probe]})

      assert second_probe_bytes != <<>>
      assert second_probe_bytes != first_probe_bytes

      assert {:ok, response_bytes} = StreamCodec.encode(:probe, [response], side: :responder)

      assert {:ok, _session, [{:message, 0, ^stream, ^response}], []} =
               Session.handle_transport(session, {:stream_data, stream, response_bytes, %{}})
    end
  end

  describe "stream lifecycle events" do
    test "maps peer finish-sending to a stream-finished protocol event" do
      stream = stream(52)

      assert {:ok, bytes} = StreamCodec.encode(:subscribe, [subscribe_message()])

      assert {:ok, session, _events, []} =
               Session.handle_transport(Session.new(), {:stream_data, stream, bytes, %{}})

      assert {:ok, _session, [{:stream_finished, 0, ^stream}], []} =
               Session.handle_transport(
                 session,
                 {:stream_event, stream, :peer_finished_sending, %{}}
               )
    end

    test "maps peer stream aborts to remote protocol errors" do
      stream = stream(56)

      assert {:ok, bytes} = StreamCodec.encode(:subscribe, [subscribe_message()])

      assert {:ok, session, _events, []} =
               Session.handle_transport(Session.new(), {:stream_data, stream, bytes, %{}})

      assert {:ok, _session,
              [{:stream_aborted, 0, ^stream, %Error{reason: :not_found, code: 13}}], []} =
               Session.handle_transport(
                 session,
                 {:stream_event, stream, :peer_aborted_sending, %{error_code: 13}}
               )
    end
  end

  describe "support transport integration" do
    test "handles normalized stream data emitted by MOQX.Transport.Support" do
      {ctx, client, server} = support_pair()

      assert {:ok, client_stream, ctx} =
               MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

      assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
      assert {:ok, ctx} = MOQX.Transport.set_active(ctx, server_stream, true)
      assert {:ok, subscribe_bytes} = StreamCodec.encode(:subscribe, [subscribe_message()])

      assert {:ok, _send, ctx} =
               MOQX.Transport.send_stream(ctx, client_stream, subscribe_bytes, [])

      assert {:ok, {:stream_data, ^server_stream, ^subscribe_bytes, %{}} = event, _ctx} =
               receive_stream_data(ctx, server_stream, subscribe_bytes, 100)

      assert {:ok, _session, events, []} = Session.handle_transport(Session.new(), event)

      assert [
               {:stream_started, 0, ^server_stream, :subscribe},
               {:message, 0, ^server_stream, %MOQLite04.Subscribe{}}
             ] = events
    end
  end

  describe "group streams" do
    test "rejects sending group streams for unknown peer subscriptions" do
      stream = stream(25, direction: :unidirectional, initiator: :local)

      messages = [
        %MOQLite04.Group{subscribe_id: 123, group_sequence: 7},
        %MOQLite04.Frame{payload: "frame"}
      ]

      assert {:error, _session, %Error{reason: :not_found, code: 13}, [], []} =
               Session.handle_command(Session.new(), {:send, stream, :group, messages})
    end

    test "aborts group streams with an unknown subscribe id" do
      stream = stream(26, direction: :unidirectional, initiator: :peer)

      messages = [
        %MOQLite04.Group{subscribe_id: 123, group_sequence: 7},
        %MOQLite04.Frame{payload: "frame"}
      ]

      assert {:ok, bytes} = StreamCodec.encode(:group, messages)

      assert {:error, _session, %Error{reason: :not_found, code: 13}, [], actions} =
               Session.handle_transport(Session.new(), {:stream_data, stream, bytes, %{}})

      assert actions == [
               {:abort_receiving, stream, 13}
             ]
    end

    test "delivers a subscribed group frame across session reducers" do
      subscribe_stream = stream(28, initiator: :local, local_role: :client)
      publisher_subscribe_stream = stream(28, initiator: :peer, local_role: :server)

      group_stream =
        stream(30, direction: :unidirectional, initiator: :local, local_role: :server)

      subscriber_group_stream =
        stream(30, direction: :unidirectional, initiator: :peer, local_role: :client)

      subscribe = subscribe_message()
      subscribe_ok = subscribe_ok_message()

      assert {:ok, subscriber, [], [{:send_stream, ^subscribe_stream, subscribe_bytes, []}]} =
               Session.handle_command(
                 Session.new(),
                 {:send, subscribe_stream, :subscribe, [subscribe]}
               )

      assert {:ok, publisher, publisher_events, []} =
               Session.handle_transport(
                 Session.new(),
                 {:stream_data, publisher_subscribe_stream, subscribe_bytes, %{}}
               )

      assert publisher_events == [
               {:stream_started, 0, publisher_subscribe_stream, :subscribe},
               {:message, 0, publisher_subscribe_stream, subscribe}
             ]

      assert {:ok, publisher, [], [{:send_stream, ^publisher_subscribe_stream, ok_bytes, []}]} =
               Session.handle_command(
                 publisher,
                 {:send, publisher_subscribe_stream, :subscribe, [subscribe_ok]}
               )

      assert {:ok, subscriber, [{:message, 0, ^subscribe_stream, ^subscribe_ok}], []} =
               Session.handle_transport(
                 subscriber,
                 {:stream_data, subscribe_stream, ok_bytes, %{}}
               )

      messages = [
        %MOQLite04.Group{subscribe_id: subscribe.subscribe_id, group_sequence: 7},
        %MOQLite04.Frame{payload: "original payload"}
      ]

      assert {:ok, _publisher, [], [{:send_stream, ^group_stream, group_bytes, []}]} =
               Session.handle_command(publisher, {:send, group_stream, :group, messages})

      assert {:ok, _subscriber, subscriber_events, []} =
               Session.handle_transport(
                 subscriber,
                 {:stream_data, subscriber_group_stream, group_bytes, %{}}
               )

      assert subscriber_events == [
               {:stream_started, 1, subscriber_group_stream, :group},
               {:message, 1, subscriber_group_stream, Enum.at(messages, 0)},
               {:message, 1, subscriber_group_stream, Enum.at(messages, 1)}
             ]
    end
  end

  defp subscribe_message do
    %MOQLite04.Subscribe{
      subscribe_id: 9,
      broadcast_path: "/live",
      track_name: "video",
      subscriber_priority: 128,
      subscriber_ordered: :ascending,
      subscriber_max_latency: 500,
      start_group: 11,
      end_group: 0
    }
  end

  defp subscribe_ok_message do
    %MOQLite04.SubscribeOk{
      publisher_priority: 192,
      publisher_ordered: :ascending,
      publisher_max_latency: 250,
      start_group: 11,
      end_group: 0
    }
  end

  defp support_pair do
    assert {:ok, network} = Support.start_network()
    assert {:ok, ctx} = MOQX.Transport.new(Support, network: network, profile: :moq_lite_04)
    assert {:ok, listener, ctx} = MOQX.Transport.listen(ctx, 0)
    assert {:ok, {_ip, port}} = MOQX.Transport.local_address(ctx, listener)
    assert {:ok, client, ctx} = MOQX.Transport.connect(ctx, "localhost", port, [], 100)
    assert {:ok, server, ctx} = MOQX.Transport.accept(ctx, listener, [], 100)
    assert {:ok, client, ctx} = MOQX.Transport.handshake(ctx, client, 100)
    assert {:ok, server, ctx} = MOQX.Transport.handshake(ctx, server, 100)

    {ctx, client, server}
  end

  defp receive_stream_data(ctx, stream, payload, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    receive_stream_data_until(ctx, stream, payload, deadline)
  end

  defp receive_stream_data_until(ctx, stream, payload, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    case MOQX.Transport.receive_event(ctx, timeout) do
      {:ok, {:stream_data, ^stream, ^payload, _metadata}, _ctx} = result ->
        result

      {:ok, _event, ctx} when timeout > 0 ->
        receive_stream_data_until(ctx, stream, payload, deadline)

      result ->
        result
    end
  end

  defp stream(id, opts \\ []) do
    direction = Keyword.get(opts, :direction, :bidirectional)
    initiator = Keyword.get(opts, :initiator, :peer)
    local_role = Keyword.get(opts, :local_role, :server)

    %Stream{
      backend: %BackendRef{module: __MODULE__, data: {:stream, id}},
      info: %StreamInfo{
        stream_id: id,
        direction: direction,
        initiator: initiator,
        initiator_role: initiator_role(initiator, local_role),
        local_role: local_role,
        send_side?: send_side?(direction, initiator),
        receive_side?: receive_side?(direction, initiator)
      }
    }
  end

  defp initiator_role(:local, local_role), do: local_role
  defp initiator_role(:peer, :client), do: :server
  defp initiator_role(:peer, :server), do: :client

  defp send_side?(:bidirectional, _initiator), do: true
  defp send_side?(:unidirectional, :local), do: true
  defp send_side?(:unidirectional, :peer), do: false

  defp receive_side?(:bidirectional, _initiator), do: true
  defp receive_side?(:unidirectional, :local), do: false
  defp receive_side?(:unidirectional, :peer), do: true
end
