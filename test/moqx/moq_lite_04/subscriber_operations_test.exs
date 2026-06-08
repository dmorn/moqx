defmodule MOQX.MOQLite04.SubscriberOperationsTest do
  use ExUnit.Case, async: true

  alias MOQX.MOQLite04
  alias MOQX.MOQLite04.Client
  alias MOQX.MOQLite04.Session
  alias MOQX.MOQLite04.StreamCodec
  alias MOQX.Transport
  alias MOQX.Transport.Support

  test "subscribe opens a subscriber transaction stream and receives SubscribeOk" do
    %{client: client, server: server} = connected_pair()
    subscribe = subscribe_message()
    subscribe_ok = subscribe_ok_message()
    subscribe_bytes = encode_stream(:subscribe, [subscribe])

    assert {:ok, %Client{} = client, stream, []} = MOQLite04.subscribe(client, subscribe)
    assert stream.info.direction == :bidirectional
    assert stream.info.initiator == :local

    assert {:ok, peer_stream, context} = Transport.accept_stream(client.context, server, [], 100)

    assert {:ok, ^subscribe_bytes, context} =
             Transport.recv_stream(context, peer_stream, byte_size(subscribe_bytes))

    assert subscribe_bytes == encode_stream(:subscribe, [subscribe])

    assert {:ok, _send, context} =
             Transport.send_stream(
               context,
               peer_stream,
               encode_stream(:subscribe, [subscribe_ok], :responder)
             )

    client = %{client | context: context}

    assert {:ok, %Client{}, [{:message, 0, ^stream, ^subscribe_ok}]} =
             recv_until_protocol_event(client)
  end

  test "subscribe_update reuses the existing Subscribe stream encoder state" do
    %{client: client, server: server} = connected_pair()
    subscribe = subscribe_message()
    update = subscribe_update_message()
    {first_bytes, update_bytes} = incremental_stream_bytes(:subscribe, [subscribe], [update])

    assert {:ok, client, stream, []} = MOQLite04.subscribe(client, subscribe)
    assert {:ok, peer_stream, context} = Transport.accept_stream(client.context, server, [], 100)

    assert {:ok, ^first_bytes, context} =
             Transport.recv_stream(context, peer_stream, byte_size(first_bytes))

    client = %{client | context: context}

    assert {:ok, %Client{} = client, ^stream, []} =
             MOQLite04.subscribe_update(client, stream, update)

    assert {:ok, ^update_bytes, _context} =
             Transport.recv_stream(client.context, peer_stream, byte_size(update_bytes))
  end

  test "fetch receives Frame messages directly on the same bidirectional stream" do
    %{client: client, server: server} = connected_pair()
    fetch = fetch_message()
    frame = frame_message()

    assert {:ok, %Client{} = client, stream, []} = MOQLite04.fetch(client, fetch)
    assert {:ok, peer_stream, context} = Transport.accept_stream(client.context, server, [], 100)

    expected_fetch_bytes = encode_stream(:fetch, [fetch])

    assert {:ok, ^expected_fetch_bytes, context} =
             Transport.recv_stream(context, peer_stream, byte_size(expected_fetch_bytes))

    assert {:ok, _send, context} =
             Transport.send_stream(
               context,
               peer_stream,
               encode_stream(:fetch, [frame], :responder)
             )

    client = %{client | context: context}

    assert {:ok, %Client{}, [{:message, 0, ^stream, ^frame}]} =
             recv_until_protocol_event(client)
  end

  test "probe can send repeated Probe messages on one stream" do
    %{client: client, server: server} = connected_pair()
    first_probe = %MOQLite04.Probe{bitrate: 750_000, rtt: 0}
    second_probe = %MOQLite04.Probe{bitrate: 1_250_000, rtt: 0}
    response_probe = %MOQLite04.Probe{bitrate: 900_000, rtt: 23}
    {first_bytes, second_bytes} = incremental_stream_bytes(:probe, [first_probe], [second_probe])

    assert {:ok, client, stream, []} = MOQLite04.probe(client, first_probe)
    assert {:ok, peer_stream, context} = Transport.accept_stream(client.context, server, [], 100)

    assert {:ok, ^first_bytes, context} =
             Transport.recv_stream(context, peer_stream, byte_size(first_bytes))

    client = %{client | context: context}

    assert {:ok, %Client{} = client, ^stream, []} = MOQLite04.probe(client, stream, second_probe)

    assert {:ok, ^second_bytes, context} =
             Transport.recv_stream(client.context, peer_stream, byte_size(second_bytes))

    assert {:ok, _send, context} =
             Transport.send_stream(
               context,
               peer_stream,
               encode_stream(:probe, [response_probe], :responder)
             )

    client = %{client | context: context}

    assert {:ok, %Client{}, [{:message, 0, ^stream, ^response_probe}]} =
             recv_until_protocol_event(client)
  end

  test "announce_interest opens an Announce transaction stream" do
    %{client: client, server: server} = connected_pair()
    interest = %MOQLite04.AnnounceInterest{broadcast_path_prefix: "broadcast/", exclude_hop: 7}
    announce = %MOQLite04.Announce{status: :active, broadcast_path_suffix: "live", hop_ids: [1]}

    assert {:ok, %Client{} = client, stream, []} = MOQLite04.announce_interest(client, interest)
    assert {:ok, peer_stream, context} = Transport.accept_stream(client.context, server, [], 100)

    expected_interest_bytes = encode_stream(:announce, [interest])

    assert {:ok, ^expected_interest_bytes, context} =
             Transport.recv_stream(context, peer_stream, byte_size(expected_interest_bytes))

    assert {:ok, _send, context} =
             Transport.send_stream(
               context,
               peer_stream,
               encode_stream(:announce, [announce], :responder)
             )

    client = %{client | context: context}

    assert {:ok, %Client{}, [{:message, 0, ^stream, ^announce}]} =
             recv_until_protocol_event(client)
  end

  test "goaway opens a Goaway transaction stream" do
    %{client: client, server: server} = connected_pair()
    goaway = %MOQLite04.Goaway{new_session_uri: "moq-lite://relay.example:4433/live"}

    assert {:ok, %Client{} = client, stream, []} = MOQLite04.goaway(client, goaway)
    assert stream.info.direction == :bidirectional

    assert {:ok, peer_stream, context} = Transport.accept_stream(client.context, server, [], 100)
    expected_goaway_bytes = encode_stream(:goaway, [goaway])

    assert {:ok, ^expected_goaway_bytes, _context} =
             Transport.recv_stream(context, peer_stream, byte_size(expected_goaway_bytes))
  end

  defp connected_pair do
    {:ok, network} = Support.start_network()
    {:ok, context} = Transport.new(Support, network: network, profile: :moq_lite_04)
    assert {:ok, listener, context} = Transport.listen(context, 0)
    assert {:ok, {_ip, port}} = Transport.local_address(context, listener)
    uri = URI.parse("moq-lite://localhost:#{port}/live")

    assert {:ok, connection, context} = Transport.connect(context, "localhost", port, [], 100)
    assert {:ok, server, context} = Transport.accept(context, listener, [], 100)
    assert {:ok, connection, context} = Transport.handshake(context, connection, 100)
    assert {:ok, server, context} = Transport.handshake(context, server, 100)

    client = %Client{
      uri: uri,
      context: context,
      connection: connection,
      session: Session.new()
    }

    %{client: client, server: server}
  end

  defp encode_stream(stream_type, messages, side \\ :opener) do
    {:ok, _codec, bytes} =
      stream_type
      |> then(&StreamCodec.new(side: side, stream_type: &1))
      |> StreamCodec.encode_next(messages)

    bytes
  end

  defp incremental_stream_bytes(stream_type, first_messages, next_messages) do
    codec = StreamCodec.new(side: :opener, stream_type: stream_type)
    {:ok, codec, first_bytes} = StreamCodec.encode_next(codec, first_messages)
    {:ok, _codec, next_bytes} = StreamCodec.encode_next(codec, next_messages)

    {first_bytes, next_bytes}
  end

  defp recv_until_protocol_event(client, attempts \\ 10)

  defp recv_until_protocol_event(client, 0), do: {:error, client, :not_received, []}

  defp recv_until_protocol_event(client, attempts) do
    case MOQLite04.recv(client, 100) do
      {:ok, client, []} -> recv_until_protocol_event(client, attempts - 1)
      {:ok, _client, _events} = result -> result
      {:timeout, client} -> {:error, client, :timeout, []}
      {:error, client, reason, events} -> {:error, client, reason, events}
    end
  end

  defp subscribe_message do
    %MOQLite04.Subscribe{
      subscribe_id: 42,
      broadcast_path: "broadcast/live",
      track_name: "video",
      subscriber_priority: 128,
      subscriber_ordered: :ascending,
      subscriber_max_latency: 500,
      start_group: 0,
      end_group: 10
    }
  end

  defp subscribe_update_message do
    %MOQLite04.SubscribeUpdate{
      subscriber_priority: 64,
      subscriber_ordered: :descending,
      subscriber_max_latency: 250,
      start_group: 3,
      end_group: 10
    }
  end

  defp subscribe_ok_message do
    %MOQLite04.SubscribeOk{
      publisher_priority: 192,
      publisher_ordered: :ascending,
      publisher_max_latency: 250,
      start_group: 0,
      end_group: 10
    }
  end

  defp fetch_message do
    %MOQLite04.Fetch{
      broadcast_path: "broadcast/live",
      track_name: "video",
      subscriber_priority: 128,
      group_sequence: 3
    }
  end

  defp frame_message do
    %MOQLite04.Frame{
      payload: "frame"
    }
  end
end
