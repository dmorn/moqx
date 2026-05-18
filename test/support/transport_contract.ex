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
      unquote(datagram_tests(contracts))
      unquote(shutdown_tests(contracts))

      defp connect_pair(fixture, profile) do
        {:ok, pair} = fixture.connect_pair(profile)
        pair
      end

      defp flush_transport_events(ctx) do
        case MOQX.Transport.receive_event(ctx, 0) do
          {:timeout, ctx} -> ctx
          {:ok, _event, ctx} -> flush_transport_events(ctx)
          {:unknown, _message, ctx} -> flush_transport_events(ctx)
          {:error, _reason, ctx} -> flush_transport_events(ctx)
        end
      end

      defp cleanup_pair(%{cleanup: cleanup}) when is_function(cleanup, 0), do: cleanup.()
      defp cleanup_pair(_pair), do: :ok

      defp await_stream_event(ctx, stream, event, timeout) do
        case MOQX.Transport.receive_event(ctx, timeout) do
          {:ok, {:stream_event, ^stream, ^event, metadata}, ctx} -> {metadata, ctx}
          {:timeout, ctx} -> {:timeout, ctx}
          {:ok, _event, ctx} -> await_stream_event(ctx, stream, event, 0)
          {:unknown, _message, ctx} -> await_stream_event(ctx, stream, event, 0)
        end
      end

      defp await_datagram(ctx, connection, payload, timeout) do
        case MOQX.Transport.receive_event(ctx, timeout) do
          {:ok, {:datagram, ^connection, ^payload, metadata}, ctx} when is_map(metadata) ->
            {metadata, ctx}

          {:timeout, ctx} ->
            {:timeout, ctx}

          {:ok, _event, ctx} ->
            await_datagram(ctx, connection, payload, 0)

          {:unknown, _message, ctx} ->
            await_datagram(ctx, connection, payload, 0)
        end
      end

      defp await_shutdown_event(ctx, stream, event, expected_metadata, timeout) do
        case MOQX.Transport.receive_event(ctx, timeout) do
          {:ok, {:stream_event, ^stream, ^event, metadata}, ctx} ->
            if Map.merge(metadata, expected_metadata) == metadata do
              {metadata, ctx}
            else
              await_shutdown_event(ctx, stream, event, expected_metadata, 0)
            end

          {:timeout, ctx} ->
            {:timeout, ctx}

          {:ok, _event, ctx} ->
            await_shutdown_event(ctx, stream, event, expected_metadata, 0)

          {:unknown, _message, ctx} ->
            await_shutdown_event(ctx, stream, event, expected_metadata, 0)
        end
      end

      defp await_connection_close(ctx, connection, timeout) do
        case MOQX.Transport.receive_event(ctx, timeout) do
          {:ok, {:connection_event, ^connection, :closed, _metadata} = event, ctx} ->
            {:ok, event, ctx}

          {:timeout, ctx} ->
            {:timeout, ctx}

          {:ok, _event, ctx} ->
            await_connection_close(ctx, connection, 0)

          {:unknown, _message, ctx} ->
            await_connection_close(ctx, connection, 0)
        end
      end

      defp maybe_accept_support_echo_stream(%{server: server}, ctx, client_stream) do
        {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 1_000)
        ctx = flush_transport_events(ctx)
        {ctx, client_stream, server_stream}
      end

      defp maybe_accept_support_echo_stream(_echo_peer, ctx, stream), do: {ctx, stream, nil}

      defp maybe_echo_support_payload(_echo_peer, ctx, _payload, nil), do: ctx

      defp maybe_echo_support_payload(_echo_peer, ctx, payload, server_stream) do
        {:ok, ^payload, ctx} = MOQX.Transport.recv_stream(ctx, server_stream, byte_size(payload))
        {:ok, ctx} = MOQX.Transport.send_stream(ctx, server_stream, payload, [])
        ctx
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
            ctx = echo_peer.ctx
            connection = echo_peer.connection
            expected_alpn = echo_peer.expected_alpn

            assert %MOQX.Transport.Capabilities{alpn: ^expected_alpn} =
                     MOQX.Transport.capabilities(ctx, connection)

            assert {:ok, stream, ctx} = MOQX.Transport.open_stream(ctx, connection, active: false)
            {ctx, stream, echo_stream} = maybe_accept_support_echo_stream(echo_peer, ctx, stream)
            assert {:ok, ctx} = MOQX.Transport.send_stream(ctx, stream, payload, [])
            ctx = maybe_echo_support_payload(echo_peer, ctx, payload, echo_stream)

            assert {:ok, ^payload, _ctx} =
                     MOQX.Transport.recv_stream(ctx, stream, byte_size(payload))
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

  defp datagram_tests(contracts) do
    if :datagram in contracts do
      quote do
        test "reports datagram capability by transport profile", %{fixture: fixture} do
          draft14_pair = connect_pair(fixture, :draft14)

          try do
            %{ctx: ctx, client: client} = draft14_pair

            assert %MOQX.Transport.Capabilities{datagrams: true, max_datagram_size: max_size} =
                     MOQX.Transport.capabilities(ctx, client)

            assert is_integer(max_size) or max_size in [:unknown, :unsupported]
          after
            cleanup_pair(draft14_pair)
          end

          moq_lite_pair = connect_pair(fixture, :moq_lite)

          try do
            %{ctx: ctx, client: client} = moq_lite_pair

            assert %MOQX.Transport.Capabilities{datagrams: false, max_datagram_size: max_size} =
                     MOQX.Transport.capabilities(ctx, client)

            assert max_size in [:unknown, :unsupported]
          after
            cleanup_pair(moq_lite_pair)
          end
        end

        test "sends a binary datagram as a normalized peer event when available", %{
          fixture: fixture
        } do
          pair = connect_pair(fixture, :draft14)

          try do
            %{ctx: ctx, client: client, server: server} = pair
            payload = <<"draft14 datagram">>

            assert {:ok, ctx} = MOQX.Transport.send_datagram(ctx, client, payload)
            assert {%{}, _ctx} = await_datagram(ctx, server, payload, 100)
          after
            cleanup_pair(pair)
          end
        end

        test "rejects datagrams when profile disables them", %{fixture: fixture} do
          pair = connect_pair(fixture, :moq_lite)

          try do
            %{ctx: ctx, client: client} = pair

            assert {:error, :datagrams_unavailable, ctx} =
                     MOQX.Transport.send_datagram(ctx, client, "moq-lite")

            assert {:timeout, _ctx} = MOQX.Transport.receive_event(ctx, 0)
          after
            cleanup_pair(pair)
          end
        end
      end
    end
  end

  defp shutdown_tests(contracts) do
    if :shutdown in contracts do
      quote do
        test "finish_sending emits normalized peer event", %{fixture: fixture} do
          pair = connect_pair(fixture, :moq_lite)

          try do
            %{ctx: ctx, client: client, server: server} = pair

            assert {:ok, client_stream, ctx} =
                     MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

            assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
            ctx = flush_transport_events(ctx)

            assert {:ok, ctx} = MOQX.Transport.finish_sending(ctx, client_stream)

            assert {%{}, _ctx} =
                     await_shutdown_event(ctx, server_stream, :peer_finished_sending, %{}, 100)
          after
            cleanup_pair(pair)
          end
        end

        test "abort_sending preserves application error code in peer event", %{fixture: fixture} do
          pair = connect_pair(fixture, :moq_lite)

          try do
            %{ctx: ctx, client: client, server: server} = pair

            assert {:ok, client_stream, ctx} =
                     MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

            assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
            ctx = flush_transport_events(ctx)

            assert {:ok, ctx} = MOQX.Transport.abort_sending(ctx, client_stream, 42)

            assert {%{error_code: 42}, _ctx} =
                     await_shutdown_event(
                       ctx,
                       server_stream,
                       :peer_aborted_sending,
                       %{error_code: 42},
                       100
                     )
          after
            cleanup_pair(pair)
          end
        end

        test "abort_receiving preserves application error code in peer event", %{fixture: fixture} do
          pair = connect_pair(fixture, :moq_lite)

          try do
            %{ctx: ctx, client: client, server: server} = pair

            assert {:ok, client_stream, ctx} =
                     MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

            assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
            ctx = flush_transport_events(ctx)

            assert {:ok, ctx} = MOQX.Transport.abort_receiving(ctx, server_stream, 7)

            assert {%{error_code: 7}, _ctx} =
                     await_shutdown_event(
                       ctx,
                       client_stream,
                       :peer_aborted_receiving,
                       %{error_code: 7},
                       100
                     )
          after
            cleanup_pair(pair)
          end
        end

        test "close_connection emits normalized peer close event", %{fixture: fixture} do
          pair = connect_pair(fixture, :moq_lite)

          try do
            %{ctx: ctx, client: client, server: server} = pair
            ctx = flush_transport_events(ctx)

            assert {:ok, ctx} = MOQX.Transport.close_connection(ctx, client, 3)

            assert {:ok, {:connection_event, ^server, :closed, %{error_code: 3}}, _ctx} =
                     await_connection_close(ctx, server, 100)
          after
            cleanup_pair(pair)
          end
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
            %{ctx: ctx, client: client, server: server} = pair

            assert {:ok, client_stream, ctx} =
                     MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

            assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)

            assert {:ok, %{direction: :bidirectional, initiator: :local}, ctx} =
                     MOQX.Transport.stream_info(ctx, client_stream)

            assert {:ok, %{direction: :bidirectional, initiator: :peer}, _ctx} =
                     MOQX.Transport.stream_info(ctx, server_stream)
          after
            cleanup_pair(pair)
          end
        end

        test "opens and accepts a unidirectional stream with metadata", %{fixture: fixture} do
          pair = connect_pair(fixture, :draft14)

          try do
            %{ctx: ctx, client: client, server: server} = pair

            assert {:ok, client_stream, ctx} =
                     MOQX.Transport.open_stream(ctx, client, direction: :unidirectional)

            assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)

            assert {:ok, %{direction: :unidirectional, initiator: :local}, ctx} =
                     MOQX.Transport.stream_info(ctx, client_stream)

            assert {:ok, %{direction: :unidirectional, initiator: :peer}, _ctx} =
                     MOQX.Transport.stream_info(ctx, server_stream)
          after
            cleanup_pair(pair)
          end
        end

        test "supports many concurrent bidirectional streams", %{fixture: fixture} do
          pair = connect_pair(fixture, :moq_lite)

          try do
            %{ctx: ctx, client: client, server: server} = pair

            {client_streams, ctx} =
              Enum.map_reduce(1..5, ctx, fn _index, ctx ->
                assert {:ok, stream, ctx} =
                         MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

                {stream, ctx}
              end)

            {server_streams, _ctx} =
              Enum.map_reduce(1..5, ctx, fn _index, ctx ->
                assert {:ok, stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
                {stream, ctx}
              end)

            assert length(Enum.uniq(client_streams)) == 5
            assert length(Enum.uniq(server_streams)) == 5
          after
            cleanup_pair(pair)
          end
        end

        test "sends stream data to passive receive in order", %{fixture: fixture} do
          pair = connect_pair(fixture, :moq_lite)

          try do
            %{ctx: ctx, client: client, server: server} = pair

            assert {:ok, client_stream, ctx} =
                     MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

            assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
            ctx = flush_transport_events(ctx)

            assert {:ok, ctx} = MOQX.Transport.send_stream(ctx, client_stream, ["one", "two"], [])
            assert {:ok, ctx} = MOQX.Transport.send_stream(ctx, client_stream, "three", [])

            assert {:ok, "onetwo", ctx} = MOQX.Transport.recv_stream(ctx, server_stream, 6)
            assert {:ok, "three", _ctx} = MOQX.Transport.recv_stream(ctx, server_stream, 5)
          after
            cleanup_pair(pair)
          end
        end

        test "delivers active stream data as normalized events", %{fixture: fixture} do
          pair = connect_pair(fixture, :moq_lite)

          try do
            %{ctx: ctx, client: client, server: server} = pair

            assert {:ok, client_stream, ctx} =
                     MOQX.Transport.open_stream(ctx, client, direction: :bidirectional)

            assert {:ok, server_stream, ctx} = MOQX.Transport.accept_stream(ctx, server, [], 100)
            ctx = flush_transport_events(ctx)

            assert {:ok, ctx} = MOQX.Transport.set_active(ctx, server_stream, true)
            assert {:ok, ctx} = MOQX.Transport.send_stream(ctx, client_stream, "active-data", [])

            assert {:ok, {:stream_data, ^server_stream, "active-data", %{}}, _ctx} =
                     MOQX.Transport.receive_event(ctx, 100)
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

  def connect_pair(profile) do
    {:ok, ctx} = MOQX.Transport.new(MOQX.Transport.Support)
    {:ok, listener, ctx} = MOQX.Transport.listen(ctx, 0, profile: profile)

    {:ok, client, ctx} =
      MOQX.Transport.connect(ctx, "localhost", listener.port, [profile: profile], 100)

    {:ok, server, ctx} = MOQX.Transport.accept(ctx, listener, [], 100)
    {:ok, client, ctx} = MOQX.Transport.handshake(ctx, client, 100)
    {:ok, server, ctx} = MOQX.Transport.handshake(ctx, server, 100)

    ctx = flush_transport_events(ctx)

    {:ok, %{ctx: ctx, client: client, server: server}}
  end

  def connect_client_echo_peer(_payload) do
    {:ok, %{ctx: ctx, client: client, server: server}} = connect_pair(:moq_lite)

    {:ok,
     %{
       ctx: ctx,
       connection: client,
       server: server,
       expected_alpn: "moq-lite-04",
       cleanup: fn -> :ok end
     }}
  end

  def unavailable_message, do: "support transport echo peer should always be available"

  defp flush_transport_events(ctx) do
    case MOQX.Transport.receive_event(ctx, 0) do
      {:timeout, ctx} -> ctx
      {:ok, _event, ctx} -> flush_transport_events(ctx)
      {:unknown, _message, ctx} -> flush_transport_events(ctx)
      {:error, _reason, ctx} -> flush_transport_events(ctx)
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

    with {:ok, ctx} <- MOQX.Transport.new(Quicer),
         {:ok, connection, ctx} <- MOQX.Transport.connect(ctx, host, port, opts, 5_000) do
      {:ok,
       %{
         ctx: ctx,
         connection: connection,
         expected_alpn: alpn,
         cleanup: fn -> MOQX.Transport.close_connection(ctx, connection, 0) end
       }}
    else
      {:error, reason, _ctx} -> {:error, reason}
      {:error, reason} -> {:error, reason}
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

    with {:ok, ctx} <- MOQX.Transport.new(Quicer),
         {:ok, listener, ctx} <- start_listener(ctx, listener_config),
         {:ok, {_ip, port}} <- MOQX.Transport.local_address(ctx, listener) do
      client_task = start_probe_client(probe_cli, listener_config, port, payload)

      try do
        with {:ok, connection, ctx} <- accept_probe_client(ctx, listener, client_task),
             {:ok, stream, ctx} <- MOQX.Transport.accept_stream(ctx, connection, [], 5_000),
             {:ok, ^payload, ctx} <- receive_stream_data(ctx, stream, payload),
             {:ok, _ctx} <- MOQX.Transport.send_stream(ctx, stream, payload, []),
             {:ok, ^payload} <- await_probe_client(client_task) do
          {:ok, payload}
        end
      after
        cleanup(ctx, listener, client_task)
      end
    end
  end

  def unavailable_message do
    "QUIC listener integration prerequisites are missing. Ensure Go is installed " <>
      "and Docker Compose has provisioned .tmp/integration-certs/."
  end

  defp start_listener(ctx, listener_config) do
    host = Keyword.fetch!(listener_config, :host)

    MOQX.Transport.listen(ctx, "#{host}:0",
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

  defp accept_probe_client(ctx, listener, client_task) do
    case MOQX.Transport.accept(ctx, listener, [], 30_000) do
      {:ok, connection, ctx} ->
        MOQX.Transport.handshake(ctx, connection, 5_000)

      {:error, reason, _ctx} ->
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

  defp receive_stream_data(ctx, stream, payload) do
    case MOQX.Transport.recv_stream(ctx, stream, byte_size(payload)) do
      {:ok, data, ctx} ->
        {:ok, data, ctx}

      {:error, :einval, ctx} ->
        receive_active_stream_data(ctx, stream)

      {:error, _reason, _ctx} = error ->
        error
    end
  end

  defp receive_active_stream_data(ctx, stream) do
    case MOQX.Transport.receive_event(ctx, 5_000) do
      {:ok, {:stream_data, ^stream, data, _metadata}, ctx} -> {:ok, data, ctx}
      {:timeout, ctx} -> {:error, :timeout, ctx}
      {:ok, event, ctx} -> {:error, {:unexpected_transport_event, event}, ctx}
      {:unknown, message, ctx} -> {:error, {:unexpected_transport_message, message}, ctx}
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

  defp cleanup(ctx, listener, task) do
    _result = MOQX.Transport.close_listener(ctx, listener, 0)

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

  def connect_pair(profile) do
    config = Application.fetch_env!(:moqx, :integration)
    listener_config = Keyword.fetch!(config, :local_listener)

    {:ok, ctx} = MOQX.Transport.new(Quicer)

    case start_listener(ctx, listener_config, profile) do
      {:ok, listener, ctx} -> connect_pair_with_cleanup(ctx, listener, listener_config, profile)
      {:error, reason, _ctx} -> {:error, reason}
    end
  end

  defp connect_pair_with_cleanup(ctx, listener, listener_config, profile) do
    case connect_pair(ctx, listener, listener_config, profile) do
      {:ok, ctx, client, server} ->
        ctx = flush_transport_events(ctx)

        {:ok,
         %{
           ctx: ctx,
           client: client,
           server: server,
           cleanup: fn -> cleanup(ctx, listener, client, server) end
         }}

      {:error, reason} ->
        _result = MOQX.Transport.close_listener(ctx, listener, 0)
        {:error, reason}
    end
  end

  defp start_listener(ctx, listener_config, profile) do
    host = Keyword.fetch!(listener_config, :host)

    MOQX.Transport.listen(
      ctx,
      "#{host}:0",
      datagram_opts(profile) ++
        [
          alpn: Keyword.fetch!(listener_config, :alpn),
          certfile: Keyword.fetch!(listener_config, :certfile),
          keyfile: Keyword.fetch!(listener_config, :keyfile),
          peer_bidi_stream_count: @stream_limit,
          peer_unidi_stream_count: @stream_limit
        ]
    )
  end

  defp connect_pair(ctx, listener, listener_config, profile) do
    with {:ok, {_ip, port}} <- MOQX.Transport.local_address(ctx, listener) do
      owner = self()
      accept_ctx = drop_listeners(ctx)
      accept_task = Task.async(fn -> accept_server(accept_ctx, listener, owner) end)
      connect_client_and_await_server(ctx, listener_config, port, accept_task, profile)
    end
  end

  defp connect_client_and_await_server(ctx, listener_config, port, accept_task, profile) do
    case connect_client(ctx, listener_config, port, profile) do
      {:ok, client, ctx} -> await_server_for_client(ctx, client, accept_task)
      {:error, reason, _ctx} -> stop_accept_task(accept_task, reason)
    end
  end

  defp await_server_for_client(ctx, client, accept_task) do
    case await_accept_server(accept_task) do
      {:ok, server, accept_ctx} ->
        ctx = merge_contexts(ctx, accept_ctx)
        {:ok, ctx, client, server}

      {:error, reason} ->
        _result = MOQX.Transport.close_connection(ctx, client, 0)
        {:error, reason}
    end
  end

  defp drop_listeners(ctx) do
    update_in(ctx.backend.data.listeners, fn _listeners -> %{} end)
  end

  defp stop_accept_task(accept_task, reason) do
    Task.shutdown(accept_task, :brutal_kill)
    {:error, reason}
  end

  defp accept_server(ctx, listener, owner) do
    with {:ok, server, ctx} <- MOQX.Transport.accept(ctx, listener, [], 5_000),
         {:ok, server, ctx} <- MOQX.Transport.handshake(ctx, server, 5_000),
         {:ok, ctx} <- MOQX.Transport.controlling_process(ctx, owner) do
      {:ok, server, ctx}
    end
  end

  defp connect_client(ctx, listener_config, port, profile) do
    host = Keyword.fetch!(listener_config, :host)

    MOQX.Transport.connect(
      ctx,
      host,
      port,
      datagram_opts(profile) ++
        [
          alpn: Keyword.fetch!(listener_config, :alpn),
          cacertfile: Keyword.fetch!(listener_config, :cacertfile),
          verify: :verify_peer,
          server_name: "localhost",
          peer_bidi_stream_count: @stream_limit,
          peer_unidi_stream_count: @stream_limit
        ]
    )
  end

  defp datagram_opts(:draft14), do: [datagram_receive_enabled: 1]
  defp datagram_opts(_profile), do: []

  defp await_accept_server(task) do
    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :accept_timeout}
    end
  end

  defp merge_contexts(ctx, accepted_ctx) do
    update_in(ctx.backend.data, fn data ->
      data
      |> Map.update!(:listeners, &Map.merge(&1, accepted_ctx.backend.data.listeners))
      |> Map.update!(:connections, &Map.merge(&1, accepted_ctx.backend.data.connections))
      |> Map.update!(:streams, &Map.merge(&1, accepted_ctx.backend.data.streams))
    end)
  end

  defp cleanup(ctx, listener, client, server) do
    _client_result = MOQX.Transport.close_connection(ctx, client, 0)
    _server_result = MOQX.Transport.close_connection(ctx, server, 0)
    _listener_result = MOQX.Transport.close_listener(ctx, listener, 0)
    :ok
  end

  defp flush_transport_events(ctx) do
    case MOQX.Transport.receive_event(ctx, 0) do
      {:timeout, ctx} -> ctx
      {:ok, _event, ctx} -> flush_transport_events(ctx)
      {:unknown, _message, ctx} -> flush_transport_events(ctx)
      {:error, _reason, ctx} -> flush_transport_events(ctx)
    end
  end
end
