defmodule MOQX.TransportTest do
  use ExUnit.Case, async: true

  alias MOQX.Transport.Profile
  alias MOQX.Transport.Support

  describe "context API" do
    test "creates caller-owned context and opens support transport connection pair through facade" do
      {_ctx, _client, _server} = support_pair(:moq_lite_04)
    end

    test "returns capabilities through context connection" do
      {ctx, client, _server} = support_pair(:draft_14)

      assert Profile.capabilities!(:draft_14) == MOQX.Transport.capabilities(ctx, client)
    end

    test "applies backend defaults from context to listener and client calls" do
      {ctx, client, server} = support_pair_from_defaults(:moq_lite_04)

      assert Profile.capabilities!(:moq_lite_04) == MOQX.Transport.capabilities(ctx, client)
      assert Profile.capabilities!(:moq_lite_04) == MOQX.Transport.capabilities(ctx, server)
    end

    test "per-call backend options override context defaults" do
      assert {:ok, network} = Support.start_network()
      assert {:ok, ctx} = MOQX.Transport.new(Support, network: network, profile: :draft_14)

      assert {:ok, listener, ctx} = MOQX.Transport.listen(ctx, 0, profile: :moq_lite_04)
      assert {:ok, {_ip, port}} = MOQX.Transport.local_address(ctx, listener)

      assert {:error, :alpn_mismatch, ^ctx} =
               MOQX.Transport.connect(ctx, "localhost", port, [], 100)

      assert {:ok, client, ctx} =
               MOQX.Transport.connect(ctx, "localhost", port, [profile: :moq_lite_04], 100)

      assert {:ok, server, ctx} = MOQX.Transport.accept(ctx, listener, [], 100)
      assert {:ok, client, ctx} = MOQX.Transport.handshake(ctx, client, 100)
      assert {:ok, server, ctx} = MOQX.Transport.handshake(ctx, server, 100)

      assert Profile.capabilities!(:moq_lite_04) == MOQX.Transport.capabilities(ctx, client)
      assert Profile.capabilities!(:moq_lite_04) == MOQX.Transport.capabilities(ctx, server)
    end

    test "does not enforce draft-14 control-stream count in the transport layer" do
      {ctx, client, server} = support_pair(:draft_14)

      {client_streams, ctx} =
        Enum.map_reduce(1..2, ctx, fn _index, ctx ->
          assert {:ok, stream, ctx} =
                   MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

          {stream, ctx}
        end)

      {server_streams, _ctx} =
        Enum.map_reduce(1..2, ctx, fn _index, ctx ->
          assert {:ok, stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
          {stream, ctx}
        end)

      assert length(Enum.uniq(client_streams)) == 2
      assert length(Enum.uniq(server_streams)) == 2
    end

    test "returns exact stream info for support bidirectional streams" do
      {ctx, client, server} = support_pair(:moq_lite_04)

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
      {ctx, client, server} = support_pair(:moq_lite_04)

      assert {:ok, client_stream, ctx} =
               MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

      assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
      ctx = flush_context_events(ctx)

      assert {:ok, ctx} = MOQX.Transport.finish_sending(ctx, client_stream)

      assert {:ok, {:stream_event, ^server_stream, :peer_finished_sending, %{}}, _ctx} =
               MOQX.Transport.receive_event(ctx, 100)
    end

    test "abort_sending and abort_receiving preserve app error codes in peer events" do
      {ctx, client, server} = support_pair(:moq_lite_04)

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
      {ctx, client, server} = support_pair(:draft_14)

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
      {ctx, client, server} = support_pair(:moq_lite_04)

      assert {:ok, client_stream, ctx} =
               MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

      assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
      ctx = flush_context_events(ctx)

      assert {:ok, ctx} = MOQX.Transport.set_active(ctx, server_stream, true)
      assert {:ok, _send, ctx} = MOQX.Transport.send_stream(ctx, client_stream, "hello", [])

      assert {:ok, {:stream_data, ^server_stream, "hello", %{}}, _ctx} =
               receive_context_stream_data(ctx, server_stream, "hello", 100)
    end

    test "controlling_process transfers whole context handles" do
      {ctx, _client, _server} = support_pair(:moq_lite_04)

      assert {:ok, ^ctx} = MOQX.Transport.controlling_process(ctx, self())
    end

    test "close_connection emits normalized peer close event" do
      {ctx, client, server} = support_pair(:moq_lite_04)
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

    test "receive_event fails loudly for transport event with unknown handle" do
      {:ok, ctx} = MOQX.Transport.new(MOQX.Transport.Support)
      unknown_stream = %MOQX.Transport.Support.Stream{pid: self()}

      send(
        self(),
        {:moqx_transport, {:stream_event, unknown_stream, :peer_finished_sending, %{}}}
      )

      assert {:error, {:unknown_transport_handle, ^unknown_stream}, ^ctx} =
               MOQX.Transport.receive_event(ctx, 0)
    end
  end

  defp flush_context_events(ctx) do
    case MOQX.Transport.receive_event(ctx, 0) do
      {:timeout, ctx} -> ctx
      {:ok, _event, ctx} -> flush_context_events(ctx)
      {:unknown, _message, ctx} -> flush_context_events(ctx)
    end
  end

  defp receive_context_stream_data(ctx, stream, payload, timeout) do
    case MOQX.Transport.receive_event(ctx, timeout) do
      {:ok, {:stream_data, ^stream, ^payload, _metadata} = event, ctx} -> {:ok, event, ctx}
      {:ok, _event, ctx} -> receive_context_stream_data(ctx, stream, payload, 0)
      {:unknown, _message, ctx} -> receive_context_stream_data(ctx, stream, payload, 0)
      {:timeout, ctx} -> {:timeout, ctx}
    end
  end

  defp support_pair(profile) do
    assert {:ok, network} = Support.start_network()
    assert {:ok, ctx} = MOQX.Transport.new(Support, network: network)

    assert %MOQX.Transport.Context{
             backend: %MOQX.Transport.BackendRef{module: Support}
           } = ctx

    assert {:ok, listener, ctx} = MOQX.Transport.listen(ctx, 0, profile: profile)

    assert %MOQX.Transport.Listener{
             backend: %MOQX.Transport.BackendRef{module: Support},
             local_role: :server
           } = listener

    assert {:ok, {_ip, port}} = MOQX.Transport.local_address(ctx, listener)

    assert {:ok, client, ctx} =
             MOQX.Transport.connect(ctx, "localhost", port, [profile: profile], 100)

    assert %MOQX.Transport.Connection{local_role: :client} = client
    assert {:ok, server, ctx} = MOQX.Transport.accept(ctx, listener, [], 100)
    assert %MOQX.Transport.Connection{local_role: :server} = server
    assert {:ok, client, ctx} = MOQX.Transport.handshake(ctx, client, 100)
    assert {:ok, server, ctx} = MOQX.Transport.handshake(ctx, server, 100)
    {ctx, client, server}
  end

  defp support_pair_from_defaults(profile) do
    assert {:ok, network} = Support.start_network()
    assert {:ok, ctx} = MOQX.Transport.new(Support, network: network, profile: profile)
    assert {:ok, listener, ctx} = MOQX.Transport.listen(ctx, 0)
    assert {:ok, {_ip, port}} = MOQX.Transport.local_address(ctx, listener)
    assert {:ok, client, ctx} = MOQX.Transport.connect(ctx, "localhost", port, [], 100)
    assert {:ok, server, ctx} = MOQX.Transport.accept(ctx, listener, [], 100)
    assert {:ok, client, ctx} = MOQX.Transport.handshake(ctx, client, 100)
    assert {:ok, server, ctx} = MOQX.Transport.handshake(ctx, server, 100)
    {ctx, client, server}
  end
end
