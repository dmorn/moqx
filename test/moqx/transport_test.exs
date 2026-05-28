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

    test "emits telemetry for stream sends and normalized receive events" do
      {ctx, client, server} = support_pair(:moq_lite_04)

      assert {:ok, client_stream, ctx} =
               MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

      assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
      ctx = flush_context_events(ctx)

      attach_test_telemetry([
        [:moqx, :transport, :stream, :send, :stop],
        [:moqx, :transport, :event, :receive, :stop]
      ])

      assert {:ok, ctx} = MOQX.Transport.set_active(ctx, server_stream, true)
      assert {:ok, _send, ctx} = MOQX.Transport.send_stream(ctx, client_stream, "hello", [])

      assert_receive {:test_telemetry, [:moqx, :transport, :stream, :send, :stop],
                      stream_measurements, stream_metadata}

      assert stream_measurements.byte_size == 5
      assert is_integer(stream_measurements.duration_us)
      assert stream_measurements.duration_us >= 0
      assert stream_metadata.backend == Support
      assert stream_metadata.result == :ok
      assert stream_metadata.reason == nil
      assert stream_metadata.finish? == false
      assert stream_metadata.stream_id == 0
      assert stream_metadata.stream_direction == :bidirectional
      assert stream_metadata.stream_initiator == :local
      assert stream_metadata.local_role == :client

      assert {:ok, {:stream_data, ^server_stream, "hello", %{}}, _ctx} =
               receive_context_stream_data(ctx, server_stream, "hello", 100)

      {receive_measurements, receive_metadata} =
        assert_receive_test_telemetry(
          [:moqx, :transport, :event, :receive, :stop],
          fn _measurements, metadata -> metadata.event_kind == :stream_data end
        )

      assert receive_measurements.byte_size == 5
      assert is_integer(receive_measurements.duration_us)
      assert receive_measurements.duration_us >= 0
      assert receive_measurements.timeout_ms in [0, 100]
      assert receive_metadata.backend == Support
      assert receive_metadata.result == :ok
      assert receive_metadata.event_kind == :stream_data
      assert receive_metadata.event_name == nil
      assert receive_metadata.stream_id == 0
      assert receive_metadata.stream_direction == :bidirectional
      assert receive_metadata.stream_initiator == :peer
      assert receive_metadata.local_role == :server
    end

    test "emits telemetry for datagram send admission and receive timeouts" do
      {ctx, client, _server} = support_pair(:draft_14)
      ctx = flush_context_events(ctx)

      attach_test_telemetry([
        [:moqx, :transport, :datagram, :send, :stop],
        [:moqx, :transport, :event, :receive, :stop]
      ])

      assert {:ok, ctx} = MOQX.Transport.send_datagram(ctx, client, "dgram")

      assert_receive {:test_telemetry, [:moqx, :transport, :datagram, :send, :stop],
                      datagram_measurements, datagram_metadata}

      assert datagram_measurements.byte_size == 5
      assert is_integer(datagram_measurements.duration_us)
      assert datagram_metadata.backend == Support
      assert datagram_metadata.result == :ok
      assert datagram_metadata.reason == nil
      assert datagram_metadata.local_role == :client

      assert {:ok, {:datagram, _connection, "dgram", %{}}, ctx} =
               MOQX.Transport.receive_event(ctx, 100)

      {receive_measurements, receive_metadata} =
        assert_receive_test_telemetry(
          [:moqx, :transport, :event, :receive, :stop],
          fn _measurements, metadata -> metadata.event_kind == :datagram end
        )

      assert receive_measurements.byte_size == 5
      assert receive_metadata.backend == Support
      assert receive_metadata.result == :ok
      assert receive_metadata.event_kind == :datagram
      assert receive_metadata.local_role == :server

      assert {:timeout, ^ctx} = MOQX.Transport.receive_event(ctx, 0)

      assert_receive {:test_telemetry, [:moqx, :transport, :event, :receive, :stop],
                      timeout_measurements, timeout_metadata}

      assert timeout_measurements.timeout_ms == 0
      assert is_integer(timeout_measurements.duration_us)
      assert timeout_metadata.backend == Support
      assert timeout_metadata.result == :timeout
      assert timeout_metadata.event_kind == :timeout
      assert timeout_metadata.event_name == nil
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

  defp attach_test_telemetry(events) do
    test_pid = self()
    handler_id = {__MODULE__, test_pid, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.telemetry_test_handler/4,
        {test_pid, test_pid}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp assert_receive_test_telemetry(event, predicate, remaining \\ 8)

  defp assert_receive_test_telemetry(event, predicate, remaining) when remaining > 0 do
    receive do
      {:test_telemetry, ^event, measurements, metadata} ->
        if predicate.(measurements, metadata) do
          {measurements, metadata}
        else
          assert_receive_test_telemetry(event, predicate, remaining - 1)
        end
    after
      100 ->
        flunk("expected telemetry event #{inspect(event)}")
    end
  end

  defp assert_receive_test_telemetry(event, _predicate, 0) do
    flunk("expected telemetry event #{inspect(event)}")
  end

  def telemetry_test_handler(event, measurements, metadata, {target_pid, emitter_pid}) do
    if self() == emitter_pid do
      send(target_pid, {:test_telemetry, event, measurements, metadata})
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
