defmodule MOQX.TransportTest do
  use ExUnit.Case, async: true

  describe "context API" do
    test "creates caller-owned context and opens support transport connection pair through facade" do
      {_ctx, _client, _server} = support_pair(:moq_lite)
    end

    test "returns capabilities through context connection" do
      {ctx, client, _server} = support_pair(:draft14)

      assert %MOQX.Transport.Capabilities{
               alpn: "moq-00",
               datagrams: true,
               max_datagram_size: 1200,
               stream_directions: [:bidirectional, :unidirectional],
               stream_priority: :supported,
               transport_stats: :unsupported
             } = MOQX.Transport.capabilities(ctx, client)
    end

    test "returns exact stream info for support bidirectional streams" do
      {ctx, client, server} = support_pair(:moq_lite)

      assert {:ok, client_stream, ctx} =
               MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

      assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)

      assert {:ok,
              %MOQX.Transport.StreamInfo{
                stream_id: 0,
                direction: :bidirectional,
                initiator: :local,
                initiator_role: :client,
                local_role: :client,
                send_side?: true,
                receive_side?: true
              }, ctx} = MOQX.Transport.stream_info(ctx, client_stream)

      assert {:ok,
              %MOQX.Transport.StreamInfo{
                stream_id: 0,
                direction: :bidirectional,
                initiator: :peer,
                initiator_role: :client,
                local_role: :server,
                send_side?: true,
                receive_side?: true
              }, _ctx} = MOQX.Transport.stream_info(ctx, server_stream)
    end

    test "finish_sending emits normalized peer event with wrapped stream" do
      {ctx, client, server} = support_pair(:moq_lite)

      assert {:ok, client_stream, ctx} =
               MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

      assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
      ctx = flush_context_events(ctx)

      assert {:ok, ctx} = MOQX.Transport.finish_sending(ctx, client_stream)

      assert {:ok, {:stream_event, ^server_stream, :peer_finished_sending, %{}}, _ctx} =
               MOQX.Transport.receive_event(ctx, 100)
    end

    test "abort_sending and abort_receiving preserve app error codes in peer events" do
      {ctx, client, server} = support_pair(:moq_lite)

      assert {:ok, client_stream, ctx} =
               MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

      assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
      ctx = flush_context_events(ctx)

      assert {:ok, ctx} = MOQX.Transport.abort_sending(ctx, client_stream, 42)

      assert {:ok, {:stream_event, ^server_stream, :peer_aborted_sending, %{error_code: 42}}, ctx} =
               MOQX.Transport.receive_event(ctx, 100)

      assert {:ok, ctx} = MOQX.Transport.abort_receiving(ctx, server_stream, 7)

      assert {:ok, {:stream_event, ^client_stream, :peer_aborted_receiving, %{error_code: 7}},
              _ctx} =
               MOQX.Transport.receive_event(ctx, 100)
    end

    test "unidirectional streams reject unavailable side operations" do
      {ctx, client, server} = support_pair(:draft14)

      assert {:ok, client_stream, ctx} =
               MOQX.Transport.open_stream(ctx, client, direction: :unidirectional)

      assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)

      assert {:error, :receive_side_unavailable, ^ctx} =
               MOQX.Transport.abort_receiving(ctx, client_stream, 1)

      assert {:error, :send_side_unavailable, ^ctx} =
               MOQX.Transport.finish_sending(ctx, server_stream)

      assert {:error, :send_side_unavailable, ^ctx} =
               MOQX.Transport.abort_sending(ctx, server_stream, 1)
    end

    test "sends stream data through facade and wraps active receive event" do
      {ctx, client, server} = support_pair(:moq_lite)

      assert {:ok, client_stream, ctx} =
               MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

      assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
      ctx = flush_context_events(ctx)

      assert {:ok, ctx} = MOQX.Transport.set_active(ctx, server_stream, true)
      assert {:ok, ctx} = MOQX.Transport.send_stream(ctx, client_stream, "hello", [])

      assert {:ok, {:stream_data, ^server_stream, "hello", %{}}, _ctx} =
               MOQX.Transport.receive_event(ctx, 100)
    end

    test "controlling_process transfers whole context handles" do
      {ctx, _client, _server} = support_pair(:moq_lite)

      assert {:ok, ^ctx} = MOQX.Transport.controlling_process(ctx, self())
    end

    test "close_connection emits normalized peer close event" do
      {ctx, client, server} = support_pair(:moq_lite)
      ctx = flush_context_events(ctx)

      assert {:ok, ctx} = MOQX.Transport.close_connection(ctx, client, 3)

      assert {:ok, {:connection_event, ^server, :closed, %{error_code: 3, initiator: :peer}},
              _ctx} =
               MOQX.Transport.receive_event(ctx, 100)
    end

    test "receive_event distinguishes unknown messages and timeout" do
      {:ok, ctx} = MOQX.Transport.new(MOQX.Transport.Support)
      send(self(), {:not_transport, :message})

      assert {:unknown, {:not_transport, :message}, ctx} == MOQX.Transport.receive_event(ctx, 0)
      assert {:timeout, ctx} == MOQX.Transport.receive_event(ctx, 0)
    end
  end

  defp flush_context_events(ctx) do
    case MOQX.Transport.receive_event(ctx, 0) do
      {:timeout, ctx} -> ctx
      {:ok, _event, ctx} -> flush_context_events(ctx)
      {:unknown, _message, ctx} -> flush_context_events(ctx)
    end
  end

  defp support_pair(profile) do
    assert {:ok, ctx} = MOQX.Transport.new(MOQX.Transport.Support)

    assert %MOQX.Transport.Context{
             backend: %MOQX.Transport.BackendRef{module: MOQX.Transport.Support}
           } = ctx

    assert {:ok, listener, ctx} = MOQX.Transport.listen(ctx, 0, profile: profile)

    assert %MOQX.Transport.Listener{
             backend: %MOQX.Transport.BackendRef{module: MOQX.Transport.Support},
             local_role: :server
           } = listener

    assert {:ok, client, ctx} =
             MOQX.Transport.connect(ctx, "localhost", listener.port, [profile: profile], 100)

    assert %MOQX.Transport.Connection{local_role: :client} = client
    assert {:ok, server, ctx} = MOQX.Transport.accept(ctx, listener, [], 100)
    assert %MOQX.Transport.Connection{local_role: :server} = server
    assert {:ok, client, ctx} = MOQX.Transport.handshake(ctx, client, 100)
    assert {:ok, server, ctx} = MOQX.Transport.handshake(ctx, server, 100)
    {ctx, client, server}
  end
end
