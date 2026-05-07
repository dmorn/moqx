defmodule MOQX.TransportContract do
  @moduledoc false

  defmacro __using__(opts) do
    parameterize = eval_option!(opts, :parameterize, __CALLER__)
    contracts = eval_option(opts, :contracts, [:self_pair], __CALLER__)
    tags = eval_option(opts, :tags, [], __CALLER__)
    async = eval_option(opts, :async, true, __CALLER__)
    exunit_opts = [async: async, parameterize: parameterize]

    quote do
      use ExUnit.Case, unquote(Macro.escape(exunit_opts))

      unquote_splicing(
        Enum.map(tags, fn tag ->
          quote do
            @moduletag unquote(tag)
          end
        end)
      )

      unquote(client_echo_tests(contracts))
      unquote(self_pair_tests(contracts))

      defp connect_pair(fixture, profile) do
        {:ok, pair} = fixture.connect_pair(profile)
        pair
      end

      defp flush_transport_events(transport) do
        case MOQX.Transport.receive_event(transport, 0) do
          :timeout -> :ok
          _event -> flush_transport_events(transport)
        end
      end
    end
  end

  defp eval_option!(opts, key, caller) do
    opts
    |> Keyword.fetch!(key)
    |> eval_quoted(caller)
  end

  defp eval_option(opts, key, default, caller) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> eval_quoted(value, caller)
      :error -> default
    end
  end

  defp eval_quoted(value, caller) do
    {evaluated, _binding} = Code.eval_quoted(value, [], caller)
    evaluated
  end

  defp client_echo_tests(contracts) do
    if :client_echo in contracts do
      quote do
        test "connects to an echo peer over a bidirectional stream", %{fixture: fixture} do
          payload = "moqx transport echo"

          assert {:ok, echo_peer} =
                   fixture.connect_client_echo_peer(payload),
                 fixture.unavailable_message()

          try do
            transport = echo_peer.transport
            connection = echo_peer.connection
            expected_alpn = echo_peer.expected_alpn

            assert %MOQX.Transport.Capabilities{alpn: ^expected_alpn} =
                     transport.capabilities(connection)

            assert {:ok, stream} = transport.open_stream(connection, active: false)
            assert :ok = transport.send_stream(stream, payload, [])
            assert {:ok, ^payload} = transport.recv_stream(stream, byte_size(payload))
          after
            echo_peer.cleanup.()
          end
        end
      end
    end
  end

  defp self_pair_tests(contracts) do
    if :self_pair in contracts do
      quote do
        test "opens and accepts a bidirectional stream with metadata", %{fixture: fixture} do
          %{transport: transport, client: client, server: server} =
            connect_pair(fixture, :moq_lite)

          assert {:ok, client_stream} = transport.open_stream(client, direction: :bidirectional)
          assert {:ok, server_stream} = transport.accept_stream(server, [], 100)

          assert {:stream_event, ^client_stream, :start_completed,
                  %{direction: :bidirectional, initiator: :local}} =
                   MOQX.Transport.receive_event(transport, 0)

          assert {:stream_event, ^server_stream, :new_stream,
                  %{direction: :bidirectional, initiator: :peer}} =
                   MOQX.Transport.receive_event(transport, 0)
        end

        test "opens and accepts a unidirectional stream with metadata", %{fixture: fixture} do
          %{transport: transport, client: client, server: server} =
            connect_pair(fixture, :draft14)

          assert {:ok, client_stream} = transport.open_stream(client, direction: :unidirectional)
          assert {:ok, server_stream} = transport.accept_stream(server, [], 100)

          assert {:stream_event, ^client_stream, :start_completed,
                  %{direction: :unidirectional, initiator: :local}} =
                   MOQX.Transport.receive_event(transport, 0)

          assert {:stream_event, ^server_stream, :new_stream,
                  %{direction: :unidirectional, initiator: :peer}} =
                   MOQX.Transport.receive_event(transport, 0)
        end

        test "supports many concurrent bidirectional streams", %{fixture: fixture} do
          %{transport: transport, client: client, server: server} =
            connect_pair(fixture, :moq_lite)

          client_streams =
            for _index <- 1..5 do
              assert {:ok, stream} = transport.open_stream(client, direction: :bidirectional)
              stream
            end

          server_streams =
            for _index <- 1..5 do
              assert {:ok, stream} = transport.accept_stream(server, [], 100)
              stream
            end

          assert length(Enum.uniq(client_streams)) == 5
          assert length(Enum.uniq(server_streams)) == 5
        end

        test "sends stream data to passive receive in order", %{fixture: fixture} do
          %{transport: transport, client: client, server: server} =
            connect_pair(fixture, :moq_lite)

          assert {:ok, client_stream} = transport.open_stream(client, direction: :bidirectional)
          assert {:ok, server_stream} = transport.accept_stream(server, [], 100)
          flush_transport_events(transport)

          assert :ok = transport.send_stream(client_stream, ["one", "two"], [])
          assert :ok = transport.send_stream(client_stream, "three", [])

          assert {:ok, "onetwo"} = transport.recv_stream(server_stream, 6)
          assert {:ok, "three"} = transport.recv_stream(server_stream, 5)
        end

        test "delivers active stream data as normalized events", %{fixture: fixture} do
          %{transport: transport, client: client, server: server} =
            connect_pair(fixture, :moq_lite)

          assert {:ok, client_stream} = transport.open_stream(client, direction: :bidirectional)
          assert {:ok, server_stream} = transport.accept_stream(server, [], 100)
          flush_transport_events(transport)

          assert :ok = transport.set_active(server_stream, true)
          assert :ok = transport.send_stream(client_stream, "active-data", [])

          assert {:stream_data, ^server_stream, "active-data", %{}} =
                   MOQX.Transport.receive_event(transport, 100)
        end
      end
    end
  end
end

defmodule MOQX.TransportContract.SupportFixture do
  @moduledoc false

  alias MOQX.Transport.Support

  def connect_pair(profile) do
    {:ok, network} = Support.start_network()
    {:ok, listener} = Support.listen(0, network: network, profile: profile)

    {:ok, client} =
      Support.connect(
        "localhost",
        Support.port(listener),
        [network: network, profile: profile],
        100
      )

    {:ok, server} = Support.accept(listener, [], 100)
    {:ok, client} = Support.handshake(client, 100)
    {:ok, server} = Support.handshake(server, 100)

    flush_transport_events()

    {:ok, %{transport: Support, client: client, server: server}}
  end

  def connect_client_echo_peer(payload) do
    {:ok, %{transport: transport, client: client, server: server}} = connect_pair(:moq_lite)
    owner = self()

    echo_pid =
      spawn_link(fn ->
        {:ok, stream} = transport.accept_stream(server, [], 1_000)
        {:ok, data} = transport.recv_stream(stream, byte_size(payload))
        :ok = transport.send_stream(stream, data, [])
        send(owner, {self(), :echoed})
      end)

    {:ok,
     %{
       transport: transport,
       connection: client,
       expected_alpn: "moq-lite-04",
       cleanup: fn -> stop_echo_process(echo_pid) end
     }}
  end

  def unavailable_message, do: "support transport echo peer should always be available"

  defp flush_transport_events do
    case MOQX.Transport.receive_event(Support, 0) do
      :timeout -> :ok
      _event -> flush_transport_events()
    end
  end

  defp stop_echo_process(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end
  end
end

defmodule MOQX.TransportContract.QuicerReferenceServerFixture do
  @moduledoc false

  alias MOQX.Transport.Quicer

  def connect_client_echo_peer(_payload) do
    config = Application.fetch_env!(:moqx, :integration)
    server = Keyword.fetch!(config, :quic_ref_server)

    host = Keyword.fetch!(server, :host)
    port = Keyword.fetch!(server, :port)
    alpn = Keyword.fetch!(server, :alpn)

    opts = [
      alpn: alpn,
      cacertfile: Keyword.fetch!(server, :cacertfile),
      verify: :verify_peer
    ]

    case Quicer.connect(host, port, opts, 5_000) do
      {:ok, connection} ->
        {:ok,
         %{
           transport: Quicer,
           connection: connection,
           expected_alpn: alpn,
           cleanup: fn -> Quicer.close_connection(connection, :normal) end
         }}

      {:error, reason} ->
        {:error, reason}

      {:error, reason, details} ->
        {:error, {reason, details}}
    end
  end

  def unavailable_message do
    "Docker Compose QUIC integration harness must be running: " <>
      "docker compose -f docker-compose.integration.yml up -d --wait"
  end
end
