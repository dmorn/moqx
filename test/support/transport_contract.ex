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
      unquote(listener_echo_tests(contracts))
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

      defp cleanup_pair(%{cleanup: cleanup}) when is_function(cleanup, 0), do: cleanup.()
      defp cleanup_pair(_pair), do: :ok
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

  defp listener_echo_tests(contracts) do
    if :listener_echo in contracts do
      quote do
        test "accepts an echo client over a bidirectional stream", %{fixture: fixture} do
          payload = "moqx listener echo"

          assert {:ok, ^payload} = fixture.run_listener_echo(payload),
                 fixture.unavailable_message()
        end
      end
    end
  end

  defp self_pair_tests(contracts) do
    if :self_pair in contracts do
      quote do
        test "opens and accepts a bidirectional stream with metadata", %{fixture: fixture} do
          pair = connect_pair(fixture, :moq_lite)

          try do
            %{transport: transport, client: client, server: server} = pair

            assert {:ok, client_stream} = transport.open_stream(client, direction: :bidirectional)
            assert {:ok, server_stream} = transport.accept_stream(server, [], 100)

            assert {:stream_event, ^client_stream, :start_completed,
                    %{direction: :bidirectional, initiator: :local}} =
                     MOQX.Transport.receive_event(transport, 0)

            assert {:stream_event, ^server_stream, :new_stream,
                    %{direction: :bidirectional, initiator: :peer}} =
                     MOQX.Transport.receive_event(transport, 0)
          after
            cleanup_pair(pair)
          end
        end

        test "opens and accepts a unidirectional stream with metadata", %{fixture: fixture} do
          pair = connect_pair(fixture, :draft14)

          try do
            %{transport: transport, client: client, server: server} = pair

            assert {:ok, client_stream} =
                     transport.open_stream(client, direction: :unidirectional)

            assert {:ok, server_stream} = transport.accept_stream(server, [], 100)

            assert {:stream_event, ^client_stream, :start_completed,
                    %{direction: :unidirectional, initiator: :local}} =
                     MOQX.Transport.receive_event(transport, 0)

            assert {:stream_event, ^server_stream, :new_stream,
                    %{direction: :unidirectional, initiator: :peer}} =
                     MOQX.Transport.receive_event(transport, 0)
          after
            cleanup_pair(pair)
          end
        end

        test "supports many concurrent bidirectional streams", %{fixture: fixture} do
          pair = connect_pair(fixture, :moq_lite)

          try do
            %{transport: transport, client: client, server: server} = pair

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
          after
            cleanup_pair(pair)
          end
        end

        test "sends stream data to passive receive in order", %{fixture: fixture} do
          pair = connect_pair(fixture, :moq_lite)

          try do
            %{transport: transport, client: client, server: server} = pair

            assert {:ok, client_stream} = transport.open_stream(client, direction: :bidirectional)
            assert {:ok, server_stream} = transport.accept_stream(server, [], 100)
            flush_transport_events(transport)

            assert :ok = transport.send_stream(client_stream, ["one", "two"], [])
            assert :ok = transport.send_stream(client_stream, "three", [])

            assert {:ok, "onetwo"} = transport.recv_stream(server_stream, 6)
            assert {:ok, "three"} = transport.recv_stream(server_stream, 5)
          after
            cleanup_pair(pair)
          end
        end

        test "delivers active stream data as normalized events", %{fixture: fixture} do
          pair = connect_pair(fixture, :moq_lite)

          try do
            %{transport: transport, client: client, server: server} = pair

            assert {:ok, client_stream} = transport.open_stream(client, direction: :bidirectional)
            assert {:ok, server_stream} = transport.accept_stream(server, [], 100)
            flush_transport_events(transport)

            assert :ok = transport.set_active(server_stream, true)
            assert :ok = transport.send_stream(client_stream, "active-data", [])

            assert {:stream_data, ^server_stream, "active-data", %{}} =
                     MOQX.Transport.receive_event(transport, 100)
          after
            cleanup_pair(pair)
          end
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

defmodule MOQX.TransportContract.QuicerListenerFixture do
  @moduledoc false

  alias MOQX.Transport.Quicer

  def run_listener_echo(payload) do
    config = Application.fetch_env!(:moqx, :integration)
    listener_config = Keyword.fetch!(config, :local_listener)
    probe_cli = Keyword.fetch!(config, :probe_cli)

    with {:ok, listener} <- start_listener(listener_config),
         {:ok, {_ip, port}} <- Quicer.local_address(listener) do
      client_task = start_probe_client(probe_cli, listener_config, port, payload)

      try do
        with {:ok, connection} <- accept_probe_client(listener, client_task),
             {:ok, stream} <- accept_probe_stream(connection),
             {:ok, ^payload} <- receive_stream_data(Quicer, stream, payload),
             :ok <- Quicer.send_stream(stream, payload, []),
             {:ok, ^payload} <- await_probe_client(client_task) do
          {:ok, payload}
        end
      after
        cleanup(listener, client_task)
      end
    end
  end

  def unavailable_message do
    "QUIC listener integration prerequisites are missing. Ensure Go is installed " <>
      "and Docker Compose has provisioned .tmp/integration-certs/."
  end

  defp start_listener(listener_config) do
    host = Keyword.fetch!(listener_config, :host)

    Quicer.listen("#{host}:0",
      alpn: Keyword.fetch!(listener_config, :alpn),
      certfile: Keyword.fetch!(listener_config, :certfile),
      keyfile: Keyword.fetch!(listener_config, :keyfile),
      peer_bidi_stream_count: 10
    )
  end

  defp start_probe_client(probe_cli, listener_config, port, payload) do
    host = Keyword.fetch!(listener_config, :host)

    Task.async(fn ->
      run_probe_client(probe_cli, listener_config, host, port, payload)
    end)
  end

  defp accept_probe_client(listener, client_task) do
    case Quicer.accept(listener, [], 30_000) do
      {:ok, connection} ->
        Quicer.handshake(connection, 5_000)

      {:error, reason} ->
        with {:ok, client_result} <- completed_task_result(client_task) do
          {:error,
           "listener did not accept quicprobe client: #{inspect(reason)}; #{format_result(client_result)}"}
        end
    end
  end

  defp completed_task_result(task) do
    case Task.yield(task, 0) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, "listener did not accept quicprobe client before timeout"}
    end
  end

  defp accept_probe_stream(connection) do
    Quicer.accept_stream(connection, [], 5_000)
  end

  defp receive_stream_data(transport, stream, payload) do
    case transport.recv_stream(stream, byte_size(payload)) do
      {:ok, data} ->
        {:ok, data}

      {:error, :einval} ->
        receive_active_stream_data(transport, stream)

      {:error, _reason} = error ->
        error
    end
  end

  defp receive_active_stream_data(transport, stream) do
    case MOQX.Transport.receive_event(transport, 5_000) do
      {:stream_data, ^stream, data, _metadata} -> {:ok, data}
      :timeout -> {:error, :timeout}
      event -> {:error, {:unexpected_transport_event, event}}
    end
  end

  defp await_probe_client(task) do
    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, "quicprobe client timed out waiting for echo"}
    end
  end

  defp run_probe_client(probe_cli, listener_config, host, port, payload) do
    command = Keyword.fetch!(probe_cli, :command)

    args =
      Keyword.fetch!(probe_cli, :args_prefix) ++
        [
          "client",
          "--addr",
          "#{host}:#{port}",
          "--ca",
          Keyword.fetch!(listener_config, :cacertfile),
          "--servername",
          "localhost",
          "--alpn",
          Keyword.fetch!(listener_config, :alpn),
          "--bidi-echo",
          payload
        ]

    case System.cmd(command, args, stderr_to_stdout: true) do
      {^payload, 0} -> {:ok, payload}
      {output, status} -> {:error, "quicprobe client exited #{status}: #{output}"}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp cleanup(listener, task) do
    _result = Quicer.close_listener(listener, 0)

    if Process.alive?(task.pid) do
      Task.shutdown(task, :brutal_kill)
    end

    :ok
  end

  defp format_result(result), do: inspect(result)
end

defmodule MOQX.TransportContract.QuicerSelfPairFixture do
  @moduledoc false

  alias MOQX.Transport.Quicer

  @stream_limit 10

  def connect_pair(_profile) do
    config = Application.fetch_env!(:moqx, :integration)
    listener_config = Keyword.fetch!(config, :local_listener)

    case start_listener(listener_config) do
      {:ok, listener} -> connect_pair_with_cleanup(listener, listener_config)
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect_pair_with_cleanup(listener, listener_config) do
    case connect_pair(listener, listener_config) do
      {:ok, client, server} ->
        flush_transport_events()

        {:ok,
         %{
           transport: Quicer,
           client: client,
           server: server,
           cleanup: fn -> cleanup(listener, client, server) end
         }}

      {:error, reason} ->
        _result = Quicer.close_listener(listener, 0)
        {:error, reason}
    end
  end

  defp start_listener(listener_config) do
    host = Keyword.fetch!(listener_config, :host)

    Quicer.listen("#{host}:0",
      alpn: Keyword.fetch!(listener_config, :alpn),
      certfile: Keyword.fetch!(listener_config, :certfile),
      keyfile: Keyword.fetch!(listener_config, :keyfile),
      peer_bidi_stream_count: @stream_limit,
      peer_unidi_stream_count: @stream_limit
    )
  end

  defp connect_pair(listener, listener_config) do
    with {:ok, {_ip, port}} <- Quicer.local_address(listener) do
      owner = self()
      accept_task = Task.async(fn -> accept_server(listener, owner) end)
      connect_client_and_await_server(listener_config, port, accept_task)
    end
  end

  defp connect_client_and_await_server(listener_config, port, accept_task) do
    case connect_client(listener_config, port) do
      {:ok, client} -> await_server_for_client(client, accept_task)
      {:error, reason} -> stop_accept_task(accept_task, reason)
    end
  end

  defp await_server_for_client(client, accept_task) do
    case await_accept_server(accept_task) do
      {:ok, server} ->
        {:ok, client, server}

      {:error, reason} ->
        _result = Quicer.close_connection(client, :normal)
        {:error, reason}
    end
  end

  defp stop_accept_task(accept_task, reason) do
    Task.shutdown(accept_task, :brutal_kill)
    {:error, reason}
  end

  defp accept_server(listener, owner) do
    with {:ok, server} <- Quicer.accept(listener, [], 5_000),
         {:ok, server} <- Quicer.handshake(server, 5_000),
         :ok <- Quicer.controlling_process(server, owner) do
      {:ok, server}
    end
  end

  defp connect_client(listener_config, port) do
    host = Keyword.fetch!(listener_config, :host)

    Quicer.connect(host, port,
      alpn: Keyword.fetch!(listener_config, :alpn),
      cacertfile: Keyword.fetch!(listener_config, :cacertfile),
      verify: :verify_peer,
      server_name: "localhost",
      peer_bidi_stream_count: @stream_limit,
      peer_unidi_stream_count: @stream_limit
    )
  end

  defp await_accept_server(task) do
    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :accept_timeout}
    end
  end

  defp cleanup(listener, client, server) do
    _client_result = Quicer.close_connection(client, :normal)
    _server_result = Quicer.close_connection(server, :normal)
    _listener_result = Quicer.close_listener(listener, 0)
    :ok
  end

  defp flush_transport_events do
    case MOQX.Transport.receive_event(Quicer, 0) do
      :timeout -> :ok
      _event -> flush_transport_events()
    end
  end
end
