defmodule MOQX.TransportBench.MoqxListener do
  @moduledoc false

  alias MOQX.Transport
  alias MOQX.TransportBench.DatagramPayload

  @default_script "moqx-transport-bench moqx-listener"
  @default_timeout_seconds 30
  @datagram_header_size DatagramPayload.header_size()
  @stream_pressure_workload "stream_pressure"
  @datagram_pressure_workload "datagram_pressure"

  def main(argv, opts \\ []) do
    script = Keyword.get(opts, :script, @default_script)

    case parse(argv, script) do
      {:help, message} ->
        IO.puts(message)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(2)

      {:ok, config} ->
        run(config)
    end
  end

  defp parse(argv, script) do
    {opts, _args, invalid} =
      OptionParser.parse(argv,
        strict: [
          host: :string,
          port: :integer,
          certfile: :string,
          keyfile: :string,
          alpn: :string,
          workload: :string,
          stream_direction: :string,
          stream_count: :integer,
          payload_size: :integer,
          payload_count: :integer,
          datagram_size: :integer,
          datagram_count: :integer,
          datagram_rate: :integer,
          duration_seconds: :integer,
          connection_count: :integer,
          timeout_seconds: :integer,
          help: :boolean
        ],
        aliases: [
          h: :help,
          p: :port
        ]
      )

    cond do
      opts[:help] ->
        {:help, usage(script)}

      invalid != [] ->
        {:error, "Invalid options: #{inspect(invalid)}\n\n#{usage(script)}"}

      is_nil(opts[:certfile]) ->
        {:error, "Missing required --certfile PATH.\n\n#{usage(script)}"}

      is_nil(opts[:keyfile]) ->
        {:error, "Missing required --keyfile PATH.\n\n#{usage(script)}"}

      true ->
        build_config(opts)
    end
  end

  defp build_config(opts) do
    config = %{
      host: Keyword.get(opts, :host, "0.0.0.0"),
      port: Keyword.get(opts, :port, 4433),
      certfile: opts[:certfile],
      keyfile: opts[:keyfile],
      alpn: Keyword.get(opts, :alpn, "moqx-test"),
      workload: Keyword.get(opts, :workload, @stream_pressure_workload),
      stream_direction: Keyword.get(opts, :stream_direction, "bidirectional"),
      stream_count: Keyword.get(opts, :stream_count, 1),
      payload_size: Keyword.get(opts, :payload_size, 1200),
      payload_count: Keyword.get(opts, :payload_count, 1),
      datagram_size: Keyword.get(opts, :datagram_size, 1200),
      datagram_count: Keyword.get(opts, :datagram_count, 1000),
      datagram_rate: opts[:datagram_rate],
      duration_seconds: opts[:duration_seconds],
      connection_count: Keyword.get(opts, :connection_count, 1),
      timeout_ms: Keyword.get(opts, :timeout_seconds, @default_timeout_seconds) * 1000
    }

    with :ok <- validate_positive(config.port, "--port"),
         :ok <- validate_workload(config.workload),
         :ok <- validate_positive(config.stream_count, "--stream-count"),
         :ok <- validate_positive(config.payload_size, "--payload-size"),
         :ok <- validate_positive(config.payload_count, "--payload-count"),
         :ok <- validate_datagram_size(config),
         :ok <- validate_positive(config.datagram_count, "--datagram-count"),
         :ok <- validate_paced_datagrams(config),
         :ok <- validate_non_negative(config.connection_count, "--connection-count"),
         :ok <- validate_stream_direction(config.stream_direction),
         :ok <- validate_file(config.certfile, "--certfile"),
         :ok <- validate_file(config.keyfile, "--keyfile") do
      {:ok, config}
    end
  end

  defp validate_positive(value, _name) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(_value, name), do: {:error, "#{name} must be greater than 0."}

  defp validate_optional_positive(nil, _name), do: :ok
  defp validate_optional_positive(value, name), do: validate_positive(value, name)

  defp validate_non_negative(value, _name) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(_value, name), do: {:error, "#{name} must be 0 or greater."}

  defp validate_workload(workload)
       when workload in [@stream_pressure_workload, @datagram_pressure_workload],
       do: :ok

  defp validate_workload(_workload),
    do: {:error, "--workload must be stream_pressure or datagram_pressure."}

  defp validate_datagram_size(%{workload: @datagram_pressure_workload, datagram_size: size})
       when is_integer(size) and size >= @datagram_header_size,
       do: :ok

  defp validate_datagram_size(%{workload: @datagram_pressure_workload}) do
    {:error, "--datagram-size must be at least #{@datagram_header_size} bytes."}
  end

  defp validate_datagram_size(_config), do: :ok

  defp validate_paced_datagrams(%{
         workload: @datagram_pressure_workload,
         datagram_rate: rate,
         duration_seconds: duration
       }) do
    with :ok <- validate_optional_positive(rate, "--datagram-rate"),
         :ok <- validate_optional_positive(duration, "--duration-seconds") do
      cond do
        is_integer(rate) and is_nil(duration) ->
          {:error, "--duration-seconds is required when --datagram-rate is set."}

        is_nil(rate) and is_integer(duration) ->
          {:error, "--datagram-rate is required when --duration-seconds is set."}

        true ->
          :ok
      end
    end
  end

  defp validate_paced_datagrams(_config), do: :ok

  defp validate_stream_direction(direction)
       when direction in ["bidirectional", "unidirectional"],
       do: :ok

  defp validate_stream_direction(_direction),
    do: {:error, "--stream-direction must be bidirectional or unidirectional."}

  defp validate_file(path, name) do
    if File.exists?(path), do: :ok, else: {:error, "#{name} does not exist: #{path}"}
  end

  defp run(config) do
    with {:ok, _apps} <- Application.ensure_all_started(:quicer),
         {:ok, ctx} <- Transport.new(MOQX.Transport.Quicer),
         {:ok, listener, ctx} <- start_listener(ctx, config),
         {:ok, {_ip, port}} <- Transport.local_address(ctx, listener),
         :ok <- print_ready(config, port),
         {:ok, ctx} <- serve_connections(ctx, listener, config),
         {:ok, _ctx} <- Transport.close_listener(ctx, listener, 0) do
      :ok
    else
      {:error, message} when is_binary(message) ->
        IO.puts(:stderr, message)
        System.halt(1)

      {:error, reason, _ctx} ->
        IO.puts(:stderr, inspect(reason))
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, inspect(reason))
        System.halt(1)
    end
  end

  defp start_listener(ctx, config) do
    opts =
      [
        alpn: config.alpn,
        certfile: config.certfile,
        keyfile: config.keyfile,
        peer_bidi_stream_count: max(config.stream_count + 2, 10),
        peer_unidi_stream_count: max(config.stream_count + 2, 10)
      ] ++ datagram_opts(config)

    Transport.listen(ctx, "#{config.host}:#{config.port}", opts)
  end

  defp datagram_opts(%{workload: @datagram_pressure_workload}), do: [datagram_receive_enabled: 1]
  defp datagram_opts(_config), do: []

  defp print_ready(config, port) do
    IO.puts("moqx-listener ready host=#{config.host} port=#{port} alpn=#{config.alpn}")
    :ok
  end

  defp serve_connections(ctx, listener, config) do
    serve_connections(ctx, listener, config, 0)
  end

  defp serve_connections(ctx, _listener, %{connection_count: limit}, served)
       when limit > 0 and served >= limit,
       do: {:ok, ctx}

  defp serve_connections(ctx, listener, config, served) do
    with {:ok, connection, ctx} <- Transport.accept(ctx, listener, [], config.timeout_ms),
         {:ok, connection, ctx} <- Transport.handshake(ctx, connection, config.timeout_ms),
         {:ok, ctx} <- serve_connection_workload(ctx, connection, config),
         {:ok, close_mode, ctx} <- wait_for_peer_connection_close(ctx, connection, config),
         {:ok, ctx} <- close_connection_if_needed(ctx, connection, close_mode) do
      serve_connections(ctx, listener, config, served + 1)
    end
  end

  defp serve_connection_workload(ctx, connection, %{workload: @stream_pressure_workload} = config) do
    with {:ok, streams, ctx} <- accept_streams(ctx, connection, config) do
      serve_streams(ctx, streams, config)
    end
  end

  defp serve_connection_workload(
         ctx,
         connection,
         %{workload: @datagram_pressure_workload} = config
       ) do
    receive_datagrams(ctx, connection, config, MapSet.new())
  end

  defp accept_streams(ctx, connection, config) do
    Enum.reduce_while(1..config.stream_count, {:ok, [], ctx}, fn _index, {:ok, streams, ctx} ->
      case Transport.accept_stream(ctx, connection, [], config.timeout_ms) do
        {:ok, stream, ctx} ->
          stream_state = %{
            stream: stream,
            received: 0,
            expected_bytes: config.payload_size * config.payload_count
          }

          {:cont, {:ok, [stream_state | streams], ctx}}

        {:error, reason, ctx} ->
          {:halt, {:error, reason, ctx}}
      end
    end)
    |> case do
      {:ok, streams, ctx} -> {:ok, Map.new(streams, &{stream_id(&1.stream), &1}), ctx}
      error -> error
    end
  end

  defp serve_streams(ctx, streams, config) do
    streams
    |> Map.values()
    |> Enum.sort_by(&stream_id(&1.stream))
    |> Enum.reduce_while({:ok, ctx}, fn stream_state, {:ok, ctx} ->
      case serve_stream(ctx, stream_state, config) do
        {:ok, ctx} -> {:cont, {:ok, ctx}}
        {:error, reason, ctx} -> {:halt, {:error, reason, ctx}}
      end
    end)
  end

  defp serve_stream(ctx, stream_state, config) do
    receive_stream_chunks(ctx, stream_state, config, 0)
  end

  defp receive_stream_chunks(ctx, stream_state, config, pending_sends) do
    if stream_complete?(stream_state) do
      drain_send_completions(ctx, stream_state.stream, pending_sends, config.timeout_ms)
    else
      recv_echo_and_continue(ctx, stream_state, config, pending_sends)
    end
  end

  defp recv_echo_and_continue(ctx, stream_state, config, pending_sends) do
    with {:ok, data, ctx} <- recv_stream_chunk(ctx, stream_state, config),
         stream_state = %{stream_state | received: stream_state.received + byte_size(data)},
         {:ok, echoed?, ctx} <- maybe_echo_stream_data(stream_state, data, ctx) do
      pending_sends = if echoed?, do: pending_sends + 1, else: pending_sends
      receive_stream_chunks(ctx, stream_state, config, pending_sends)
    end
  end

  defp recv_stream_chunk(ctx, stream_state, config) do
    remaining = stream_state.expected_bytes - stream_state.received
    chunk_size = min(config.payload_size, remaining)

    Transport.recv_stream(ctx, stream_state.stream, chunk_size)
  end

  defp stream_complete?(stream_state) do
    stream_state.received == stream_state.expected_bytes
  end

  defp maybe_echo_stream_data(%{stream: %{info: %{send_side?: false}}}, _data, ctx) do
    {:ok, false, ctx}
  end

  defp maybe_echo_stream_data(stream_state, data, ctx) do
    opts =
      if stream_state.received == stream_state.expected_bytes,
        do: [finish: true],
        else: []

    case Transport.send_stream(ctx, stream_state.stream, data, opts) do
      {:ok, _send, ctx} ->
        {:ok, true, ctx}

      {:error, reason, ctx} ->
        {:error, reason, ctx}
    end
  end

  defp drain_send_completions(ctx, _stream, 0, _timeout_ms), do: {:ok, ctx}

  defp drain_send_completions(ctx, stream, pending_sends, timeout_ms) do
    case Transport.receive_event(ctx, timeout_ms) do
      {:ok, {:stream_event, ^stream, :send_completed, _metadata}, ctx} ->
        drain_send_completions(ctx, stream, pending_sends - 1, timeout_ms)

      {:ok, {:stream_event, ^stream, :send_cancelled, metadata}, ctx} ->
        {:error, {:stream_send_cancelled, stream_id(stream), metadata}, ctx}

      {:ok, _event, ctx} ->
        drain_send_completions(ctx, stream, pending_sends, timeout_ms)

      {:unknown, _message, ctx} ->
        drain_send_completions(ctx, stream, pending_sends, timeout_ms)

      {:timeout, ctx} ->
        {:error, "moqx-listener timed out waiting for stream send completions", ctx}

      {:error, reason, ctx} ->
        {:error, reason, ctx}
    end
  end

  defp wait_for_peer_connection_close(ctx, connection, config) do
    case Transport.receive_event(ctx, config.timeout_ms) do
      {:ok, {:connection_event, ^connection, :closed, _metadata}, ctx} ->
        {:ok, :peer_closed, ctx}

      {:ok, _event, ctx} ->
        wait_for_peer_connection_close(ctx, connection, config)

      {:unknown, _message, ctx} ->
        wait_for_peer_connection_close(ctx, connection, config)

      {:timeout, ctx} ->
        {:ok, :timeout, ctx}

      {:error, reason, ctx} ->
        {:error, reason, ctx}
    end
  end

  defp close_connection_if_needed(ctx, _connection, :peer_closed), do: {:ok, ctx}

  defp close_connection_if_needed(ctx, connection, :timeout) do
    Transport.close_connection(ctx, connection, 0)
  end

  defp receive_datagrams(ctx, connection, config, received) do
    if MapSet.size(received) >= expected_datagram_count(config) do
      {:ok, ctx}
    else
      receive_datagram(ctx, connection, config, received)
    end
  end

  defp receive_datagram(ctx, connection, config, received) do
    case Transport.receive_event(ctx, config.timeout_ms) do
      {:ok, {:datagram, ^connection, payload, _metadata}, ctx} ->
        echo_datagram(ctx, connection, config, received, payload)

      {:ok, _event, ctx} ->
        receive_datagrams(ctx, connection, config, received)

      {:timeout, ctx} ->
        {:error, "moqx-listener timed out waiting for reference client datagrams", ctx}

      {:unknown, _message, ctx} ->
        receive_datagrams(ctx, connection, config, received)

      {:error, reason, ctx} ->
        {:error, reason, ctx}
    end
  end

  defp echo_datagram(ctx, connection, config, received, payload) do
    with {:ok, ctx} <- Transport.send_datagram(ctx, connection, payload) do
      receive_datagrams(ctx, connection, config, record_datagram(received, payload))
    end
  end

  defp record_datagram(received, payload) do
    case DatagramPayload.sequence(payload) do
      {:ok, sequence} -> MapSet.put(received, sequence)
      :error -> received
    end
  end

  defp stream_id(stream), do: stream.info.stream_id

  defp expected_datagram_count(%{datagram_rate: rate, duration_seconds: duration})
       when is_integer(rate) and is_integer(duration) do
    rate * duration
  end

  defp expected_datagram_count(config), do: config.datagram_count

  defp usage(script) do
    """
    Usage:
      #{script} --certfile PATH --keyfile PATH [options]

    Runs a MOQX.Transport.Quicer echo/drain listener for reference-client
    comparison runs. It serves one connection by default, then exits.

    Required:
      --certfile PATH                TLS certificate PEM file
      --keyfile PATH                 TLS private key PEM file

    Common options:
      --host HOST                    listen host (default: 0.0.0.0)
      --port PORT                    UDP listen port (default: 4433)
      --alpn VALUE                   QUIC ALPN (default: moqx-test)
      --workload VALUE               stream_pressure or datagram_pressure (default: stream_pressure)
      --stream-direction VALUE       bidirectional or unidirectional (default: bidirectional)
      --stream-count N               streams expected from the reference client (default: 1)
      --payload-size BYTES           bytes per payload write (default: 1200)
      --payload-count N              payload writes per stream (default: 1)
      --datagram-size BYTES          bytes per datagram for datagram_pressure (default: 1200)
      --datagram-count N             datagrams expected for datagram_pressure (default: 1000)
      --datagram-rate N              target datagrams/sec expected for paced datagram_pressure
      --duration-seconds N           paced datagram_pressure duration; expected datagrams = rate * duration
      --connection-count N           accepted connections before exit; 0 means unlimited (default: 1)
      --timeout-seconds N            accept/read timeout per operation (default: #{@default_timeout_seconds})

    Remote reference-client-to-MOQX-listener shape:
      server$ #{script} --host 0.0.0.0 --port 4433 \\
        --certfile /opt/moqx-bench/certs/server.pem \\
        --keyfile /opt/moqx-bench/certs/server-key.pem \\
        --stream-count 4 --payload-size 1200 --payload-count 100

      client$ moqx-transport-bench reference-comparison \\
        --topology reference-client-to-moqx-listener \\
        --server SERVER_PRIVATE_IP --port 4433 \\
        --ca /opt/moqx-bench/certs/ca.pem \\
        --quicprobe-command /opt/moqx-bench/quicprobe/current/bin/quicprobe
    """
  end
end
