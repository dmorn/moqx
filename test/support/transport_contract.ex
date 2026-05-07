defmodule MOQX.TransportContract do
  @moduledoc false

  defmacro __using__(transport: transport) do
    quote bind_quoted: [transport: transport] do
      use ExUnit.Case, async: true

      @transport transport

      test "opens and accepts a bidirectional stream with metadata" do
        %{client: client, server: server} = connect_pair(@transport, :moq_lite)

        assert {:ok, client_stream} = @transport.open_stream(client, direction: :bidirectional)
        assert {:ok, server_stream} = @transport.accept_stream(server, [], 100)

        assert {:stream_event, ^client_stream, :start_completed,
                %{direction: :bidirectional, initiator: :local}} =
                 MOQX.Transport.receive_event(@transport, 0)

        assert {:stream_event, ^server_stream, :new_stream,
                %{direction: :bidirectional, initiator: :peer}} =
                 MOQX.Transport.receive_event(@transport, 0)
      end

      test "opens and accepts a unidirectional stream with metadata" do
        %{client: client, server: server} = connect_pair(@transport, :draft14)

        assert {:ok, client_stream} = @transport.open_stream(client, direction: :unidirectional)
        assert {:ok, server_stream} = @transport.accept_stream(server, [], 100)

        assert {:stream_event, ^client_stream, :start_completed,
                %{direction: :unidirectional, initiator: :local}} =
                 MOQX.Transport.receive_event(@transport, 0)

        assert {:stream_event, ^server_stream, :new_stream,
                %{direction: :unidirectional, initiator: :peer}} =
                 MOQX.Transport.receive_event(@transport, 0)
      end

      test "supports many concurrent bidirectional streams" do
        %{client: client, server: server} = connect_pair(@transport, :moq_lite)

        client_streams =
          for _index <- 1..5 do
            assert {:ok, stream} = @transport.open_stream(client, direction: :bidirectional)
            stream
          end

        server_streams =
          for _index <- 1..5 do
            assert {:ok, stream} = @transport.accept_stream(server, [], 100)
            stream
          end

        assert length(Enum.uniq(client_streams)) == 5
        assert length(Enum.uniq(server_streams)) == 5
      end

      test "sends stream data to passive receive in order" do
        %{client: client, server: server} = connect_pair(@transport, :moq_lite)

        assert {:ok, client_stream} = @transport.open_stream(client, direction: :bidirectional)
        assert {:ok, server_stream} = @transport.accept_stream(server, [], 100)
        flush_transport_events(@transport)

        assert :ok = @transport.send_stream(client_stream, ["one", "two"], [])
        assert :ok = @transport.send_stream(client_stream, "three", [])

        assert {:ok, "onetwo"} = @transport.recv_stream(server_stream, 6)
        assert {:ok, "three"} = @transport.recv_stream(server_stream, 5)
      end

      test "delivers active stream data as normalized events" do
        %{client: client, server: server} = connect_pair(@transport, :moq_lite)

        assert {:ok, client_stream} = @transport.open_stream(client, direction: :bidirectional)
        assert {:ok, server_stream} = @transport.accept_stream(server, [], 100)
        flush_transport_events(@transport)

        assert :ok = @transport.set_active(server_stream, true)
        assert :ok = @transport.send_stream(client_stream, "active-data", [])

        assert {:stream_data, ^server_stream, "active-data", %{}} =
                 MOQX.Transport.receive_event(@transport, 0)
      end

      defp connect_pair(transport, profile) do
        {:ok, network} = transport.start_network()
        {:ok, listener} = transport.listen(0, network: network, profile: profile)

        {:ok, client} =
          transport.connect(
            "localhost",
            transport.port(listener),
            [network: network, profile: profile],
            100
          )

        {:ok, server} = transport.accept(listener, [], 100)
        {:ok, client} = transport.handshake(client, 100)
        {:ok, server} = transport.handshake(server, 100)

        flush_transport_events(transport)

        %{client: client, server: server}
      end

      defp flush_transport_events(transport) do
        case MOQX.Transport.receive_event(transport, 0) do
          :timeout -> :ok
          _event -> flush_transport_events(transport)
        end
      end
    end
  end
end
