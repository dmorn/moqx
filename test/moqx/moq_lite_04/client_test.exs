defmodule MOQX.MOQLite04.ClientTest do
  use ExUnit.Case, async: true

  alias MOQX.MOQLite04
  alias MOQX.MOQLite04.{Client, Session}
  alias MOQX.MOQLite04.StreamCodec
  alias MOQX.Testing.Transport, as: Support
  alias MOQX.Transport

  test "connects with a URI string over the support transport" do
    %{network: network, listener: listener, listener_ctx: listener_ctx, port: port} =
      start_support_listener()

    uri = "moq-lite://localhost:#{port}/live?track=video"

    assert {:ok, %Client{} = client} =
             MOQLite04.connect(uri,
               transport: {Support, network: network, profile: :moq_lite_04},
               timeout: 100
             )

    assert %URI{
             scheme: "moq-lite",
             host: "localhost",
             port: ^port,
             path: "/live",
             query: "track=video"
           } = client.uri

    assert %Session{alpn: "moq-lite-04", streams: %{}} = client.session
    assert %MOQX.Transport.Context{} = client.context
    assert %MOQX.Transport.Conn{local_role: :client} = client.connection

    assert %MOQX.Transport.Capabilities{alpn: "moq-lite-04"} =
             Transport.capabilities(client.context, client.connection)

    assert client.context.backend.data.streams == %{}

    assert {:ok, server, listener_ctx} = Transport.accept(listener_ctx, listener, [], 100)
    assert {:ok, _server, _listener_ctx} = Transport.handshake(listener_ctx, server, 100)
  end

  test "connects with a parsed URI struct" do
    %{network: network, listener: listener, listener_ctx: listener_ctx, port: port} =
      start_support_listener()

    uri = URI.parse("moq-lite://localhost:#{port}/live")

    assert {:ok, %Client{uri: ^uri}} =
             MOQLite04.connect(uri,
               transport: {Support, network: network, profile: :moq_lite_04},
               timeout: 100
             )

    assert {:ok, server, listener_ctx} = Transport.accept(listener_ctx, listener, [], 100)
    assert {:ok, _server, _listener_ctx} = Transport.handshake(listener_ctx, server, 100)
  end

  test "command sends protocol bytes through transport actions" do
    %{client: client, server: server} = connected_pair()

    assert {:ok, stream, context} = Transport.open_stream(client.context, client.connection)
    client = %{client | context: context}
    listener_ctx = context

    assert {:ok, peer_stream, listener_ctx} =
             Transport.accept_stream(listener_ctx, server, [], 100)

    subscribe = subscribe_message()
    expected_bytes = encode_stream(:subscribe, [subscribe])

    assert {:ok, %Client{} = client, []} =
             MOQLite04.command(client, {:send, stream, :subscribe, [subscribe]})

    assert client.session.streams != %{}

    assert {:ok, ^expected_bytes, _listener_ctx} =
             Transport.recv_stream(listener_ctx, peer_stream, byte_size(expected_bytes))
  end

  test "recv returns protocol events from normalized stream data" do
    %{client: client, server: server} = connected_pair()

    assert {:ok, stream, context} = Transport.open_stream(client.context, client.connection)
    assert {:ok, context} = Transport.set_active(context, stream, true)
    assert {:ok, peer_stream, context} = Transport.accept_stream(context, server, [], 100)
    client = %{client | context: context}

    subscribe = subscribe_message()
    subscribe_ok = subscribe_ok_message()

    assert {:ok, client, []} = MOQLite04.command(client, {:send, stream, :subscribe, [subscribe]})

    assert {:ok, _send, context} =
             Transport.send_stream(
               client.context,
               peer_stream,
               encode_stream(:subscribe, [subscribe_ok], :responder)
             )

    client = %{client | context: context}

    assert {:ok, %Client{} = client, [{:message, 0, ^stream, ^subscribe_ok}]} =
             recv_until_protocol_event(client)

    assert client.session.streams != %{}
  end

  test "recv returns stream lifecycle events from normalized transport events" do
    %{client: client, server: server} = connected_pair()

    assert {:ok, stream, context} = Transport.open_stream(client.context, client.connection)
    assert {:ok, context} = Transport.set_active(context, stream, true)
    assert {:ok, peer_stream, context} = Transport.accept_stream(context, server, [], 100)
    client = %{client | context: context}

    assert {:ok, client, []} =
             MOQLite04.command(client, {:send, stream, :subscribe, [subscribe_message()]})

    assert {:ok, context} = Transport.finish_sending(client.context, peer_stream)
    client = %{client | context: context}

    assert {:ok, %Client{}, [{:stream_finished, 0, ^stream}]} =
             recv_until_protocol_event(client)
  end

  test "recv applies transport actions returned by handle_transport errors" do
    %{client: client, server: server} = connected_pair()

    assert {:ok, peer_stream, context} = Transport.open_stream(client.context, server)
    assert {:ok, stream, context} = Transport.accept_stream(context, client.connection, [], 100)
    assert {:ok, context} = Transport.set_active(context, stream, true)
    client = %{client | context: context}

    assert {:ok, _send, context} = Transport.send_stream(client.context, peer_stream, <<63>>)
    client = %{client | context: context}

    assert {:error, %Client{} = client, %MOQLite04.Error{reason: :unexpected_stream}, []} =
             recv_until_protocol_event(client)

    assert {:ok, {:stream_event, ^peer_stream, :peer_aborted_receiving, %{error_code: 10}},
            context} =
             receive_transport_event(client.context, fn
               {:stream_event, ^peer_stream, :peer_aborted_receiving, %{error_code: 10}} -> true
               _event -> false
             end)

    assert {:ok, {:stream_event, ^peer_stream, :peer_aborted_sending, %{error_code: 10}},
            _context} =
             receive_transport_event(context, fn
               {:stream_event, ^peer_stream, :peer_aborted_sending, %{error_code: 10}} -> true
               _event -> false
             end)
  end

  test "recv ignores unknown mailbox messages" do
    %{client: client} = connected_pair()
    flush_mailbox()

    send(self(), :not_a_transport_message)

    assert MOQLite04.recv(client, 100) == {:ok, client, []}
  end

  test "recv returns timeout without a transport message" do
    %{client: client} = connected_pair()
    flush_mailbox()

    assert MOQLite04.recv(client, 0) == {:timeout, client}
  end

  test "command applies finish sending actions" do
    %{client: client, server: server} = connected_pair()

    assert {:ok, stream, context} = Transport.open_stream(client.context, client.connection)
    assert {:ok, peer_stream, context} = Transport.accept_stream(context, server, [], 100)
    client = %{client | context: context}

    assert {:ok, %Client{} = client, []} = MOQLite04.command(client, {:finish_sending, stream})

    assert {:ok, {:stream_event, ^peer_stream, :peer_finished_sending, %{}}, _context} =
             receive_transport_event(client.context, fn
               {:stream_event, ^peer_stream, :peer_finished_sending, %{}} -> true
               _event -> false
             end)
  end

  test "command applies abort sending actions" do
    %{client: client, server: server} = connected_pair()

    assert {:ok, stream, context} = Transport.open_stream(client.context, client.connection)
    assert {:ok, peer_stream, context} = Transport.accept_stream(context, server, [], 100)
    client = %{client | context: context}

    assert {:ok, %Client{} = client, []} =
             MOQLite04.command(client, {:abort_sending, stream, :not_found})

    assert {:ok, {:stream_event, ^peer_stream, :peer_aborted_sending, %{error_code: 13}},
            _context} =
             receive_transport_event(client.context, fn
               {:stream_event, ^peer_stream, :peer_aborted_sending, %{error_code: 13}} -> true
               _event -> false
             end)
  end

  test "command applies abort receiving actions" do
    %{client: client, server: server} = connected_pair()

    assert {:ok, stream, context} = Transport.open_stream(client.context, client.connection)
    assert {:ok, peer_stream, context} = Transport.accept_stream(context, server, [], 100)
    client = %{client | context: context}

    assert {:ok, %Client{} = client, []} =
             MOQLite04.command(client, {:abort_receiving, stream, :protocol_violation})

    assert {:ok, {:stream_event, ^peer_stream, :peer_aborted_receiving, %{error_code: 15}},
            _context} =
             receive_transport_event(client.context, fn
               {:stream_event, ^peer_stream, :peer_aborted_receiving, %{error_code: 15}} -> true
               _event -> false
             end)
  end

  test "command applies connection close actions" do
    %{client: client, server: server} = connected_pair()

    assert {:ok, %Client{} = client, []} =
             MOQLite04.command(client, {:close_connection, client.connection, :closed})

    assert {:ok, {:connection_event, ^server, :closed, %{error_code: 25, initiator: :peer}},
            _context} =
             receive_transport_event(client.context, fn
               {:connection_event, ^server, :closed, %{error_code: 25, initiator: :peer}} -> true
               _event -> false
             end)
  end

  test "command returns structured client errors when action application fails" do
    %{client: client, server: server} = connected_pair()

    assert {:ok, stream, context} = Transport.open_stream(client.context, client.connection)
    assert {:ok, _peer_stream, context} = Transport.accept_stream(context, server, [], 100)
    client = %{client | context: context}

    assert {:ok, client, []} = MOQLite04.command(client, {:finish_sending, stream})
    session = client.session

    assert {:error, %Client{session: ^session}, %Client.Error{} = error, []} =
             MOQLite04.command(client, {:finish_sending, stream})

    assert %Client.Error{
             reason: :transport_action_failed,
             action: {:finish_sending, ^stream},
             details: %{transport_reason: :send_side_finished}
           } = error
  end

  test "rejects unsupported URI schemes" do
    assert MOQLite04.connect("https://localhost:4433/live") ==
             {:error, {:invalid_uri, {:unsupported_scheme, "https"}}}
  end

  test "rejects URI inputs without a host" do
    assert MOQLite04.connect("moq-lite:/live") == {:error, {:invalid_uri, :missing_host}}
  end

  test "rejects URI inputs without a port" do
    assert MOQLite04.connect("moq-lite://localhost/live") ==
             {:error, {:invalid_uri, :missing_port}}
  end

  test "rejects URI inputs with userinfo" do
    assert MOQLite04.connect("moq-lite://user@localhost:4433/live") ==
             {:error, {:invalid_uri, :userinfo_not_supported}}
  end

  test "rejects URI inputs with fragments" do
    assert MOQLite04.connect("moq-lite://localhost:4433/live#track") ==
             {:error, {:invalid_uri, :fragment_not_supported}}
  end

  test "requires explicit transport selection" do
    assert MOQLite04.connect("moq-lite://localhost:4433/live") == {:error, :missing_transport}
  end

  test "rejects invalid transport option shapes" do
    assert MOQLite04.connect("moq-lite://localhost:4433/live", transport: Support) ==
             {:error, {:invalid_transport, Support}}

    assert MOQLite04.connect("moq-lite://localhost:4433/live", transport: {Support, :bad_opts}) ==
             {:error, {:invalid_transport, {Support, :bad_opts}}}
  end

  test "rejects publisher or subscriber connection modes" do
    for mode <- [:publisher, :subscriber] do
      assert MOQLite04.connect("moq-lite://localhost:4433/live", mode: mode) ==
               {:error, {:unsupported_option, :mode}}
    end
  end

  defp start_support_listener do
    {:ok, network} = Support.start_network()
    {:ok, listener_ctx} = Transport.new(Support, network: network)
    {:ok, listener, listener_ctx} = Transport.listen(listener_ctx, 0, profile: :moq_lite_04)
    {:ok, {_ip, port}} = Transport.local_address(listener_ctx, listener)

    %{network: network, listener: listener, listener_ctx: listener_ctx, port: port}
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

    %{client: client, server: server, listener_ctx: context}
  end

  defp encode_stream(stream_type, messages, side \\ :opener) do
    {:ok, _codec, bytes} =
      stream_type
      |> then(&StreamCodec.new(side: side, stream_type: &1))
      |> StreamCodec.encode_next(messages)

    bytes
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

  defp subscribe_ok_message do
    %MOQLite04.SubscribeOk{
      publisher_priority: 192,
      publisher_ordered: :ascending,
      publisher_max_latency: 250,
      start_group: 0,
      end_group: 10
    }
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

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp receive_transport_event(context, matcher, attempts \\ 10)

  defp receive_transport_event(context, _matcher, 0), do: {:error, :not_received, context}

  defp receive_transport_event(context, matcher, attempts) do
    case Transport.receive_event(context, 100) do
      {:ok, event, context} ->
        if matcher.(event) do
          {:ok, event, context}
        else
          receive_transport_event(context, matcher, attempts - 1)
        end

      {:unknown, _message, context} ->
        receive_transport_event(context, matcher, attempts - 1)

      {:timeout, context} ->
        {:error, :timeout, context}
    end
  end
end
